# ><(((º> ServerFish

Keep any number of local servers running and back them up to your MEGA account, automatically at startup.

- **Your servers, your names.** Add as many as you like, each with its own folder and start command.
- **One MEGA folder per server.** Everything in a server's directory is backed up to `ServerFish/<server name>/`.
- **Nothing is hard-coded.** Everything lives in a small config folder (`~/.config/serverfish`).

## Requirements

- [fish shell](https://fishshell.com) 3.0+
- [rclone](https://rclone.org/install/) (used for MEGA)
- Whatever your servers need (node, python, …)

On Windows, run fish through WSL or MSYS2. Windows paths like `F:\Sites\shop` are converted automatically.

## Quick start

```fish
fish serverfish.fish setup                          # connect MEGA (once)
fish serverfish.fish add "My Shop" ~/projects/shop  # start command is auto-detected
fish serverfish.fish add "API" /srv/api --cmd "python3 app.py"
fish serverfish.fish run                            # start everything + back up
fish serverfish.fish autostart                      # prints how to run it at boot
```

Running `fish serverfish.fish` with no command does the same as `run`.

## Commands

| Command | What it does |
|---|---|
| `setup` | Connect your MEGA account and choose the backup folder |
| `add NAME PATH [--cmd "…"] [--no-backup]` | Add a server |
| `edit NAME [--cmd …] [--path …] [--backup yes\|no]` | Change a server |
| `remove NAME` | Remove a server from ServerFish (files are untouched) |
| `list` | Show configured servers |
| `start / stop / restart / status [NAME…]` | Control all servers, or only the ones named |
| `logs NAME` | Follow a server's log |
| `backup [NAME…]` | Back up now |
| `run` | Start everything, then back up (use this at boot) |
| `config [set KEY VALUE]` | Show or change settings |
| `autostart` | Print the setup for your system (Windows, Linux, macOS) |

Names with spaces need quotes: `add "My Shop" ~/shop`.

### Auto-detected start commands

If you leave out `--cmd`, ServerFish picks one in this order: `npm start` (if `package.json` has a start script), then `node server.js` / `index.js` / `app.js` / `main.js`, then `python3 server.py` / `app.py` / `main.py`. Otherwise it asks.

## Backups

Backups land in MEGA like this:

```
ServerFish/
├── My Shop/            ← live copy of the server folder
├── API/
└── _versions/
    └── My Shop/2026-11-22_19-45-00/   ← files that were changed or deleted
```

Two modes (`config set mode …`):

- **`mirror`** (default): keeps `ServerFish/<name>/` identical to your folder. Files that get changed or deleted are moved to `_versions/` instead of being lost.
- **`archive`**: uploads a timestamped `.tar.gz` into `ServerFish/<name>/` on every backup.

Other settings: `remote`, `folder`, `keep` (versions or archives kept, default 14), `excludes` (default `node_modules,.cache,*.log,.tmp`), `net_timeout`.

## Notes

- Start commands run in the server's folder as a single command (for example `node server.js`). Put multi-step startup in a script and point `--cmd` at it.
- Server output goes to `~/.config/serverfish/logs/`.
- `setup` needs your MEGA password once to create the rclone remote. If your account uses two-factor login, configure the remote with `rclone config` instead (type `mega`).
