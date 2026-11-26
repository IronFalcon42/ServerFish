#!/usr/bin/env fish
#   ><(((º>   S E R V E R F I S H
#   Keep your local servers running and back them up to MEGA — automatically.
#
#  QUICK START
#     fish serverfish.fish setup                       # connect your MEGA account
#     fish serverfish.fish add "My Shop" ~/projects/shop
#     fish serverfish.fish add "API" /srv/api --cmd "python3 app.py"
#     fish serverfish.fish run                         # start all + back up all
#     fish serverfish.fish autostart                   # how to run it at boot
#
#  Run  fish serverfish.fish help  for every command.
#
#  Requirements: fish (3.0+), rclone (for MEGA backups) — plus whatever your
#  servers need (node, python, …).


set -g SF_VERSION 1.0.0

# WHERE SERVERFISH KEEPS ITS DATA
if set -q SERVERFISH_HOME
    set -g SF_HOME $SERVERFISH_HOME
else if set -q XDG_CONFIG_HOME
    set -g SF_HOME $XDG_CONFIG_HOME/serverfish
else
    set -g SF_HOME $HOME/.config/serverfish
end
set -g SF_SERVERS  $SF_HOME/servers.tsv      # name <TAB> path <TAB> command <TAB> backup
set -g SF_SETTINGS $SF_HOME/settings.conf
set -g SF_LOGS     $SF_HOME/logs
set -g SF_PIDS     $SF_HOME/pids
mkdir -p $SF_HOME $SF_LOGS $SF_PIDS


# Outputs
function _banner
    echo
    set_color -o cyan;  echo -n "   ><(((º>"; set_color normal
    set_color -o white; echo "   S E R V E R F I S H"; set_color normal
    set_color brblack;  echo "             keep servers running · back them up to MEGA · v$SF_VERSION"; set_color normal
    echo
end

function _line
    set_color brblack
    echo "  ────────────────────────────────────────────────────────────"
    set_color normal
end

function _section
    echo
    set_color -o brcyan; echo "  ◆ $argv"; set_color normal
    _line
end

function _ok;   set_color green;  echo -n "  ✔ "; set_color normal; echo $argv; end
function _warn; set_color yellow; echo -n "  ▲ "; set_color normal; echo $argv; end
function _fail; set_color red;    echo -n "  ✘ "; set_color normal; echo $argv; end
function _info; set_color blue;   echo -n "  • "; set_color normal; echo $argv; end
function _dim;  set_color brblack; echo -n $argv; set_color normal; end

function _pad --argument-names text width
    test -n "$width"; or set width 22
    printf "%-"$width"s" $text
end



#  SETTINGS
#  remote       rclone remote that points to MEGA              (default: mega)
#  folder       top-level folder in MEGA                       (default: ServerFish)
#  mode         mirror  = live copy of the server folder + old versions kept
#               archive = a timestamped .tar.gz per backup
#  keep         how many old versions / archives to keep       (default: 14)
#  excludes     comma-separated patterns never backed up
#  net_timeout  seconds to wait for internet before backing up (default: 90)

function _load_settings
    set -g CFG_remote      mega
    set -g CFG_folder      ServerFish
    set -g CFG_mode        mirror
    set -g CFG_keep        14
    set -g CFG_excludes    "node_modules,.cache,*.log,.tmp"
    set -g CFG_net_timeout 90

    test -f $SF_SETTINGS; or return 0
    for line in (cat $SF_SETTINGS)
        string match -qr '^\s*(#|$)' -- $line; and continue
        set -l kv (string split -m1 '=' -- $line)
        test (count $kv) -eq 2; or continue
        set -l k (string trim -- $kv[1])
        set -l v (string trim -- $kv[2])
        switch $k
            case remote folder mode keep excludes net_timeout
                set -g CFG_$k $v
        end
    end
end

function _save_settings
    printf '%s\n' \
        "# ServerFish settings" \
        "remote=$CFG_remote" \
        "folder=$CFG_folder" \
        "mode=$CFG_mode" \
        "keep=$CFG_keep" \
        "excludes=$CFG_excludes" \
        "net_timeout=$CFG_net_timeout" > $SF_SETTINGS
end



# Server registry  (servers.tsv)

function _srv_names
    test -f $SF_SERVERS; and cut -f1 $SF_SERVERS
    return 0
end

function _srv_find --argument-names name
    test -f $SF_SERVERS; or return 1
    for line in (cat $SF_SERVERS)
        set -l f (string split \t -- $line)
        if test "$f[1]" = "$name"
            printf '%s\n' $line
            return 0
        end
    end
    return 1
end

# _srv_field NAME INDEX   (2 = path, 3 = command, 4 = backup yes/no)
function _srv_field --argument-names name idx
    set -l line (_srv_find $name)
    set -l f (string split \t -- $line)
    echo $f[$idx]
end

function _srv_write --argument-names name path cmd backup
    printf '%s\t%s\t%s\t%s\n' $name $path $cmd $backup >> $SF_SERVERS
end

function _srv_delete --argument-names name
    test -f $SF_SERVERS; or return 0
    set -l tmp (mktemp)
    for line in (cat $SF_SERVERS)
        set -l f (string split \t -- $line)
        test "$f[1]" = "$name"; or printf '%s\n' $line >> $tmp
    end
    touch $tmp
    mv $tmp $SF_SERVERS
end

function _slug --argument-names name
    set -l s (string lower -- $name | string replace -ra '[^a-z0-9._-]+' '-' | string trim -c '-')
    if test -z "$s"
        set s srv-(printf '%s' $name | cksum | string split ' ')[1]
    end
    echo $s
end

# Name used as the MEGA folder (removes characters MEGA does not allow)
function _safe_name --argument-names name
    string replace -ra '[\\\\/:*?"<>|]+' '-' -- $name | string trim
end

# Accepts Windows paths (F:\x\y), ~, relative paths — returns a POSIX path
function _norm_path --argument-names p
    set p (string replace -a '\\' '/' -- $p)
    if string match -qr '^[A-Za-z]:' -- $p
        set -l drive (string lower (string sub -l 1 -- $p))
        set -l rest (string replace -r '^[A-Za-z]:/*' '' -- $p)
        for base in /mnt/$drive /$drive /cygdrive/$drive
            if test -d $base
                set p $base/$rest
                break
            end
        end
    end
    set p (string replace -r '^~' $HOME -- $p)
    string match -q '/*' -- $p; or set p (pwd)/$p
    string replace -r '(.)/+$' '$1' -- $p
end

# Path as the rclone binary expects it (Windows-native under MSYS/Cygwin)
function _native_path --argument-names p
    if command -q cygpath
        cygpath -w $p
    else
        echo $p
    end
end

# Guess how to start a project from its files
function _detect_cmd --argument-names dir
    if test -f $dir/package.json
        if string match -qr '"start"\s*:' -- (cat $dir/package.json)
            echo "npm start"
            return 0
        end
    end
    for f in server.js index.js app.js main.js
        test -f $dir/$f; and echo "node $f"; and return 0
    end
    for f in server.py app.py main.py
        test -f $dir/$f; and echo "python3 $f"; and return 0
    end
    return 1
end


function _resolve_targets
    if test (count $argv) -eq 0
        _srv_names
        return 0
    end
    set -l bad 0
    for n in $argv
        if _srv_find $n >/dev/null
            echo $n
        else
            _fail "Unknown server: $n" >&2
            set bad 1
        end
    end
    return $bad
end

function _need_servers
    if test (count $argv) -eq 0
        _warn "No servers configured yet."
        _info "Add one with:  fish serverfish.fish add \"My Server\" /path/to/server"
        return 1
    end
end



# Process controll


function _proc_start --argument-names pid
    ps -p $pid -o lstart= 2>/dev/null | string trim
end

function _is_running --argument-names name
    set -l pidfile $SF_PIDS/(_slug $name).pid
    test -f $pidfile; or return 1
    set -l pid (head -n1 $pidfile)
    test -n "$pid"; or return 1
    kill -0 $pid 2>/dev/null; or return 1
    set -l saved (sed -n 2p $pidfile)
    test "$saved" = (_proc_start $pid)
end

function _pid_of --argument-names name
    head -n1 $SF_PIDS/(_slug $name).pid 2>/dev/null
end

function cmd_start
    set -l targets (_resolve_targets $argv); or return 1
    _need_servers $targets; or return 1

    _section "Starting servers"
    set -l started 0; set -l skipped 0; set -l failed 0

    for name in $targets
        set -l dir (_srv_field $name 2)
        set -l cmd (_srv_field $name 3)
        set -l slug (_slug $name)
        set -l pidfile $SF_PIDS/$slug.pid
        set -l logfile $SF_LOGS/$slug.log

        if not test -d "$dir"
            _fail (_pad $name)"folder not found: $dir"
            set failed (math $failed + 1); continue
        end

        if _is_running $name
            _warn (_pad $name)"already running "(_dim "pid "(_pid_of $name))
            set skipped (math $skipped + 1); continue
        end

        printf '\n=== %s — starting %s ===\n' (date '+%Y-%m-%d %H:%M:%S') $name >> $logfile

        pushd $dir >/dev/null
        nohup sh -c "exec $cmd" >> $logfile 2>&1 &
        set -l pid $last_pid
        disown $pid 2>/dev/null
        popd >/dev/null

        sleep 0.5
        if kill -0 $pid 2>/dev/null
            printf '%s\n%s\n' $pid (_proc_start $pid) > $pidfile
            _ok (_pad $name)(_dim "pid $pid · $cmd")
            set started (math $started + 1)
        else
            rm -f $pidfile
            _fail (_pad $name)"exited immediately — run:  logs \"$name\""
            set failed (math $failed + 1)
        end
    end

    echo
    _info "$started started · $skipped already running · $failed failed"
    test $failed -eq 0
end

function cmd_stop
    set -l targets (_resolve_targets $argv); or return 1
    _need_servers $targets; or return 1

    _section "Stopping servers"
    set -l n 0
    for name in $targets
        set -l pidfile $SF_PIDS/(_slug $name).pid
        if _is_running $name
            set -l pid (_pid_of $name)
            command -q pkill; and pkill -P $pid 2>/dev/null
            kill $pid 2>/dev/null
            for t in (seq 10)
                kill -0 $pid 2>/dev/null; or break
                sleep 0.3
            end
            kill -0 $pid 2>/dev/null; and kill -9 $pid 2>/dev/null
            rm -f $pidfile
            _ok (_pad $name)"stopped"
            set n (math $n + 1)
        else
            rm -f $pidfile
            _info (_pad $name)"not running"
        end
    end
    echo
    _info "$n server(s) stopped"
end

function cmd_restart
    cmd_stop $argv
    cmd_start $argv
end

function cmd_status
    set -l targets (_resolve_targets $argv); or return 1
    _need_servers $targets; or return 1

    _section "Server status"
    for name in $targets
        if _is_running $name
            _ok (_pad $name)(set_color green)"running"(set_color normal)"  "(_dim "pid "(_pid_of $name))
        else
            _fail (_pad $name)(set_color red)"stopped"(set_color normal)
        end
    end
end

function cmd_logs
    if test -z "$argv[1]"
        _fail "Which server?  logs \"Server Name\""
        return 1
    end
    _srv_find $argv[1] >/dev/null; or begin
        _fail "Unknown server: $argv[1]"; return 1
    end
    set -l logfile $SF_LOGS/(_slug $argv[1]).log
    test -f $logfile; or begin
        _fail "No log yet for \"$argv[1]\""; return 1
    end
    tail -n 60 -f $logfile
end



# Managing the server list

function cmd_add
    argparse 'c/cmd=' 'n/no-backup' -- $argv; or return 1
    set -l name $argv[1]
    set -l path $argv[2]
    set -l cmd  $_flag_cmd
    set -l backup yes
    set -q _flag_no_backup; and set backup no

    if test -z "$name"
        read -P "  Server name: " name; or return 1
    end
    if test -z "$path"
        read -P "  Server folder (e.g. ~/projects/shop or F:\\sites\\shop): " path; or return 1
    end

    set name (string trim -- $name)
    set -l safe (_safe_name $name)
    if test -z "$name" -o -z "$safe"; or string match -q "*"\t"*" -- $name
        _fail "Invalid server name."; return 1
    end
    if test "$safe" = "_versions"
        _fail "\"_versions\" is a reserved name."; return 1
    end
    for existing in (_srv_names)
        if test "$existing" = "$name" -o (_slug $existing) = (_slug $name) -o (_safe_name $existing) = "$safe"
            _fail "A server named \"$existing\" already exists (names must be unique)."
            return 1
        end
    end

    set path (_norm_path $path)
    if not test -d "$path"
        _fail "Folder does not exist: $path"; return 1
    end

    if test -z "$cmd"
        set cmd (_detect_cmd $path)
        if test -n "$cmd"
            _info "Detected start command: $cmd"
        else
            read -P "  Start command (e.g. node server.js): " cmd; or return 1
        end
    end
    if test -z "$cmd"
        _fail "A start command is required (use --cmd \"...\")."; return 1
    end

    _srv_write $name $path $cmd $backup
    echo
    _ok "Added "(set_color -o)"$name"(set_color normal)
    _dim "      folder   $path"; echo
    _dim "      command  $cmd"; echo
    _dim "      backup   $backup"
    test "$backup" = yes; and _dim "  →  $CFG_remote:$CFG_folder/$safe"
    echo
end

function cmd_remove
    if test -z "$argv[1]"
        _fail "Which server?  remove \"Server Name\""; return 1
    end
    _srv_find $argv[1] >/dev/null; or begin
        _fail "Unknown server: $argv[1]"; return 1
    end
    _is_running $argv[1]; and cmd_stop $argv[1]
    _srv_delete $argv[1]
    _ok "Removed \"$argv[1]\"  "(_dim "(files on disk and in MEGA are untouched)")
end

function cmd_edit
    argparse 'c/cmd=' 'p/path=' 'b/backup=' -- $argv; or return 1
    set -l name $argv[1]
    if test -z "$name"
        _fail "Which server?  edit \"Server Name\" [--cmd ...] [--path ...] [--backup yes|no]"; return 1
    end
    _srv_find $name >/dev/null; or begin
        _fail "Unknown server: $name"; return 1
    end

    set -l path   (_srv_field $name 2)
    set -l cmd    (_srv_field $name 3)
    set -l backup (_srv_field $name 4)

    set -q _flag_path;   and set path (_norm_path $_flag_path)
    set -q _flag_cmd;    and set cmd $_flag_cmd
    if set -q _flag_backup
        string match -qr '^(yes|no)$' -- $_flag_backup; or begin
            _fail "--backup must be yes or no"; return 1
        end
        set backup $_flag_backup
    end
    test -d "$path"; or begin
        _fail "Folder does not exist: $path"; return 1
    end

    _srv_delete $name
    _srv_write $name $path $cmd $backup
    _ok "Updated \"$name\""
end

function cmd_list
    _section "Configured servers"
    set -l names (_srv_names)
    _need_servers $names; or return 1

    for name in $names
        set -l dir    (_srv_field $name 2)
        set -l cmd    (_srv_field $name 3)
        set -l backup (_srv_field $name 4)
        set -l safe   (_safe_name $name)

        if _is_running $name
            set_color green; echo -n "  ● "
        else
            set_color brblack; echo -n "  ○ "
        end
        set_color -o white; echo $name; set_color normal

        _dim "      folder   $dir"; echo
        _dim "      command  $cmd"; echo
        if test "$backup" = yes
            _dim "      backup   $CFG_remote:$CFG_folder/$safe"; echo
        else
            _dim "      backup   off"; echo
        end
    end
    echo
    _info (count $names)" server(s)"
end



# Beckup


function _wait_for_network
    set -l waited 0
    while test $waited -lt $CFG_net_timeout
        if command -q curl
            curl -fsS --max-time 4 -o /dev/null https://mega.nz 2>/dev/null; and return 0
        else if ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1
            return 0
        end
        sleep 3
        set waited (math $waited + 3)
    end
    return 1
end

function _backup_ready
    if not command -q rclone
        _fail "rclone is not installed — get it at https://rclone.org/install/"
        _info "Then run:  fish serverfish.fish setup"
        return 1
    end
    if not rclone listremotes 2>/dev/null | string match -q "$CFG_remote:"
        _fail "rclone remote \"$CFG_remote\" not found"
        _info "Run:  fish serverfish.fish setup"
        return 1
    end
    _info "Checking internet connection…"
    if not _wait_for_network
        _fail "No internet after $CFG_net_timeout s — backup skipped"
        return 1
    end
    _ok "Online"
end

function _exclude_args
    for p in (string split ',' -- $CFG_excludes)
        set p (string trim -- $p)
        test -n "$p"; or continue
        echo "--exclude=$p"
        echo "--exclude=$p/**"
    end
end

function _backup_one --argument-names name
    set -l dir  (_srv_field $name 2)
    set -l safe (_safe_name $name)
    set -l dest "$CFG_remote:$CFG_folder/$safe"
    set -l stamp (date +%Y-%m-%d_%H-%M-%S)
    set -l logfile $SF_LOGS/backup.log

    if not test -d "$dir"
        _fail (_pad $name)"folder not found: $dir"; return 1
    end

    switch $CFG_mode
        case mirror
            set -l vroot "$CFG_remote:$CFG_folder/_versions/$safe"
            if rclone sync (_native_path $dir) $dest (_exclude_args) \
                    --create-empty-src-dirs --retries 3 \
                    --backup-dir "$vroot/$stamp" \
                    --log-file $logfile --log-level NOTICE
                _ok (_pad $name)(_dim "→ $dest")

                # prune old versions
                set -l snaps (rclone lsf --dirs-only $vroot 2>/dev/null | string trim -c '/' | sort)
                set -l n (count $snaps)
                if test $n -gt $CFG_keep
                    for s in $snaps[1..(math $n - $CFG_keep)]
                        rclone purge "$vroot/$s" 2>/dev/null
                    end
                end
            else
                _fail (_pad $name)"upload failed — see $logfile"; return 1
            end

        case archive
            set -l fname "$safe-$stamp.tar.gz"
            set -l tmp (mktemp -d)
            set -l tar_ex
            for p in (string split ',' -- $CFG_excludes)
                set p (string trim -- $p)
                test -n "$p"; and set -a tar_ex "--exclude=$p"
            end

            if not tar -C (dirname $dir) -czf $tmp/$fname $tar_ex (basename $dir) 2>/dev/null
                _fail (_pad $name)"could not create archive"; rm -rf $tmp; return 1
            end
            if rclone copyto (_native_path $tmp/$fname) "$dest/$fname" --retries 3 \
                    --log-file $logfile --log-level NOTICE
                _ok (_pad $name)(_dim "→ $dest/$fname  ("(du -h $tmp/$fname | cut -f1)")")

                set -l old (rclone lsf --files-only $dest 2>/dev/null | string match '*.tar.gz' | sort)
                set -l n (count $old)
                if test $n -gt $CFG_keep
                    for f in $old[1..(math $n - $CFG_keep)]
                        rclone deletefile "$dest/$f" 2>/dev/null
                    end
                end
            else
                _fail (_pad $name)"upload failed — see $logfile"; rm -rf $tmp; return 1
            end
            rm -rf $tmp

        case '*'
            _fail "Unknown backup mode \"$CFG_mode\" (use mirror or archive)"; return 1
    end
end

function cmd_backup
    set -l targets
    if test (count $argv) -eq 0
        # no names given: every server that has backup switched on
        for n in (_srv_names)
            test (_srv_field $n 4) = yes; and set -a targets $n
        end
    else
        set targets (_resolve_targets $argv); or return 1
    end
    _need_servers $targets; or return 1

    _section "Backup  "(_dim "mode: $CFG_mode · target: $CFG_remote:$CFG_folder")
    _backup_ready; or return 1
    echo

    set -l ok 0; set -l failed 0
    for name in $targets
        if _backup_one $name
            set ok (math $ok + 1)
        else
            set failed (math $failed + 1)
        end
    end
    echo
    _info "$ok backed up · $failed failed"
    test $failed -eq 0
end



# Setup, config, autostart xdd


function cmd_setup
    _section "Setup"

    if command -q rclone
        _ok "rclone found  "(_dim (rclone version | head -n1))
    else
        _fail "rclone is not installed."
        _info "Install it from https://rclone.org/install/ and run setup again."
        return 1
    end

    read -P "  rclone remote name for MEGA [$CFG_remote]: " r
    test -n "$r"; and set -g CFG_remote $r
    read -P "  Top-level MEGA folder for backups [$CFG_folder]: " f
    test -n "$f"; and set -g CFG_folder $f

    if rclone listremotes 2>/dev/null | string match -q "$CFG_remote:"
        _ok "Remote \"$CFG_remote\" already exists"
    else
        echo
        _info "Remote \"$CFG_remote\" does not exist yet — let's connect your MEGA account."
        read -P "  MEGA e-mail: " email
        read -s -P "  MEGA password (hidden): " pass
        echo
        if test -z "$email" -o -z "$pass"
            _fail "E-mail and password are required (or run:  rclone config)"; return 1
        end
        if rclone config create $CFG_remote mega user $email pass $pass --obscure >/dev/null 2>&1
            _ok "Remote \"$CFG_remote\" created"
        else
            _fail "Could not create the remote."
            _info "Use the interactive tool instead:  rclone config  (type: mega)"
            _info "Accounts with 2-factor login must be set up that way."
            return 1
        end
    end

    _info "Testing connection…"
    if rclone lsd "$CFG_remote:" >/dev/null 2>&1
        _ok "Connected to MEGA"
    else
        _warn "Could not reach MEGA — check your login with:  rclone config"
    end

    _save_settings
    _ok "Settings saved  "(_dim $SF_SETTINGS)
    echo
    _info "Next:  fish serverfish.fish add \"My Server\" /path/to/server"
end

function cmd_config
    switch $argv[1]
        case set
            set -l key $argv[2]
            set -l val $argv[3..-1]
            set val (string join ' ' -- $val)
            switch $key
                case remote folder excludes
                    test -n "$val"; or begin; _fail "Value required"; return 1; end
                case mode
                    string match -qr '^(mirror|archive)$' -- $val; or begin
                        _fail "mode must be mirror or archive"; return 1
                    end
                case keep net_timeout
                    string match -qr '^[0-9]+$' -- $val; or begin
                        _fail "$key must be a number"; return 1
                    end
                case '*'
                    _fail "Unknown setting \"$key\"  (remote, folder, mode, keep, excludes, net_timeout)"
                    return 1
            end
            set -g CFG_$key $val
            _save_settings
            _ok "$key = $val"
        case path
            echo $SF_HOME
        case '*'
            _section "Settings"
            for k in remote folder mode keep excludes net_timeout
                set -l v CFG_$k
                printf "  %-14s %s\n" $k $$v
            end
            echo
            _dim "  change with:  config set KEY VALUE"; echo
            _dim "  data folder:  $SF_HOME"; echo
    end
end

function cmd_autostart
    set -l me (realpath (status filename))
    _section "Run ServerFish at startup"

    if test -n "$WSL_DISTRO_NAME"
        _info "Windows + WSL detected. Run this once in a Windows terminal (cmd or PowerShell):"
        echo
        set_color -o white
        echo "  schtasks /Create /TN \"ServerFish\" /SC ONLOGON /TR \"wsl.exe -d $WSL_DISTRO_NAME -- fish $me run\""
        set_color normal
        echo
        _dim "  remove later with:  schtasks /Delete /TN \"ServerFish\" /F"; echo
    else if string match -qr 'Msys|Cygwin' -- (uname -o 2>/dev/null)
        set -l fishwin (cygpath -w (command -s fish) 2>/dev/null)
        set -l mewin   (cygpath -w $me 2>/dev/null)
        _info "Windows (MSYS2/Cygwin) detected. Run this once in cmd or PowerShell:"
        echo
        set_color -o white
        echo "  schtasks /Create /TN \"ServerFish\" /SC ONLOGON /TR \"$fishwin $mewin run\""
        set_color normal
        echo
    else if test (uname) = Darwin
        _info "macOS: create ~/Library/LaunchAgents/com.serverfish.plist with RunAtLoad = true"
        _info "and ProgramArguments:  "(command -s fish)" $me run"
    else
        _info "Linux: save this as ~/.config/systemd/user/serverfish.service"
        echo
        set_color -o white
        printf '  %s\n' \
            "[Unit]" \
            "Description=ServerFish" \
            "After=network-online.target" \
            "" \
            "[Service]" \
            "Type=oneshot" \
            "RemainAfterExit=yes" \
            "KillMode=process" \
            "ExecStart="(command -s fish)" $me run" \
            "" \
            "[Install]" \
            "WantedBy=default.target"
        set_color normal
        echo
        _info "then enable it:   systemctl --user enable --now serverfish"
        _dim "  (to start before login: loginctl enable-linger \$USER)"; echo
    end
end

function cmd_run
    set -l names (_srv_names)
    _need_servers $names; or return 1
    cmd_start
    cmd_backup
end

function cmd_help
    printf '  %s\n' "" >/dev/null
    _section "Commands"
    set -l rows \
        "setup|Connect your MEGA account (run this first)" \
        "add NAME PATH|Add a server   [--cmd \"start command\"] [--no-backup]" \
        "edit NAME|Change a server    [--cmd ..] [--path ..] [--backup yes|no]" \
        "remove NAME|Remove a server from ServerFish" \
        "list|Show all configured servers" \
        "start [NAME…]|Start all servers (or the ones named)" \
        "stop [NAME…]|Stop them" \
        "restart [NAME…]|Stop, then start" \
        "status [NAME…]|Show what is running" \
        "logs NAME|Follow a server's log output" \
        "backup [NAME…]|Back up to MEGA now" \
        "run|Start everything, then back up  (default / boot)" \
        "config [set K V]|Show or change settings" \
        "autostart|How to launch ServerFish when your PC starts" \
        "help|This screen"
    for r in $rows
        set -l p (string split '|' -- $r)
        set_color -o cyan; printf "  %-18s" $p[1]; set_color normal
        echo $p[2]
    end
    echo
    _dim "  Names with spaces need quotes:  add \"My Shop\" ~/shop"; echo
    _dim "  Backups go to  $CFG_remote:$CFG_folder/<server name>/"; echo
end



# Main

_load_settings
_banner

set -l command $argv[1]
test -z "$command"; and set command run
set -e argv[1]

switch $command
    case setup;                      cmd_setup $argv
    case add;                        cmd_add $argv
    case edit;                       cmd_edit $argv
    case remove rm delete;           cmd_remove $argv
    case list ls;                    cmd_list
    case start;                      cmd_start $argv
    case stop;                       cmd_stop $argv
    case restart;                    cmd_restart $argv
    case status;                     cmd_status $argv
    case logs log;                   cmd_logs $argv
    case backup;                     cmd_backup $argv
    case run boot;                   cmd_run
    case config settings;            cmd_config $argv
    case autostart;                  cmd_autostart
    case help -h --help;             cmd_help
    case version -v --version;       echo "  ServerFish $SF_VERSION"
    case '*'
        _fail "Unknown command: $command"
        cmd_help
        exit 1
end

set -l code $status
echo
_line
_dim "  "(date '+%Y-%m-%d %H:%M:%S')"  ·  data: $SF_HOME"; echo
echo
exit $code
