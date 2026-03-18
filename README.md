# gdrive-sync

Two-way sync between a local Linux folder and Google Drive — managed from a single interactive bash script.

Uses [rclone bisync](https://rclone.org/bisync/) + [inotify-tools](https://github.com/inotify-tools/inotify-tools) + systemd + cron to keep a local directory and a Google Drive folder in continuous sync. Local changes push up within seconds; remote changes pull down on a schedule you choose.

```
Local file saved  ──►  inotify detects  ──►  debounce (5s)  ──►  rclone bisync  ──►  Drive updated

Cron fires (N min) ──►  rclone bisync  ──►  Local folder updated
```

---

## Features

- **Single file, zero dependencies** — one `.sh` file; installs rclone + inotify-tools automatically
- **Interactive menu** — add, list, edit, remove, and monitor syncs without memorizing commands
- **Bidirectional sync** — local ↔ Drive via `rclone bisync`
- **Instant local → Drive** — `inotifywait` watches for changes, debounces (5 s), then syncs
- **Scheduled Drive → local** — cron pulls remote changes at your chosen interval
- **Conflict resolution** — newer file wins (`--conflict-resolve newer`); losers are renamed, not lost
- **Lock & debounce** — prevents overlapping syncs and Google API rate-limit floods
- **Auto log rotation** — logs rotate at 50 MB
- **Systemd managed** — watcher survives reboots; start/stop with standard `systemctl` commands
- **Multi-sync** — manage multiple independent Drive ↔ folder pairs
- **Safe** — never runs as root; per-remote cache cleanup (never wipes other syncs); systemd hardening

---

## Requirements

| Requirement | Notes |
|---|---|
| **OS** | Ubuntu 20.04+, Debian 11+, or any systemd-based Linux |
| **Bash** | 4.4+ (ships with all supported distros) |
| **Internet** | Required for Google Drive API access |
| **Google Account** | With access to the target Drive folder |
| **Google Cloud Project** | Free tier — see [setup guide below](#google-api-credentials-setup) |

Everything else (`rclone`, `inotify-tools`, `curl`) is installed automatically on first run.

---

## Quick Start

```bash
# Clone the repo
git clone https://github.com/wahidlahlou/gdrive-sync.git
cd gdrive-sync

# Make executable
chmod +x gdrive-sync.sh

# Run
./gdrive-sync.sh
```

Before adding your first sync, you'll need Google API credentials. Follow the guide below — it takes about 5 minutes.

---

## Google API Credentials Setup

You need a **Client ID** and **Client Secret** from a Google Cloud "Desktop app" OAuth client. This is what rclone uses to authenticate with your Google account. You do this once; the credentials work for all your syncs.

### Step 1 — Create a Google Cloud Project

1. Go to **[Google Cloud Console](https://console.cloud.google.com/)**
2. Sign in with the Google account that has access to the Drive folder
3. Click the project dropdown at the top-left (next to "Google Cloud"):

   ![project dropdown](https://img.shields.io/badge/▾_Select_a_project-4285F4?style=flat-square&logo=googlecloud&logoColor=white)

4. Click **New Project**
5. Enter a name (e.g. `gdrive-sync`) — organization and location can stay as defaults
6. Click **Create**
7. Make sure your new project is now selected in the dropdown

### Step 2 — Enable the Google Drive API

1. In the left sidebar, navigate to **APIs & Services → Library**

   > Direct link: https://console.cloud.google.com/apis/library

2. Search for **Google Drive API**
3. Click on the result, then click the blue **Enable** button
4. Wait a few seconds for it to activate

### Step 3 — Configure the OAuth Consent Screen

Before you can create credentials, Google requires a consent screen configuration:

1. Go to **APIs & Services → OAuth consent screen**

   > Direct link: https://console.cloud.google.com/apis/credentials/consent

2. Select **External** as the User Type, then click **Create**

   > (If you're in a Google Workspace org and only you will use it, you can choose "Internal" instead — this skips the test-user step.)

3. Fill in the required fields:

   | Field | Value |
   |---|---|
   | App name | `gdrive-sync` |
   | User support email | *your email* |
   | Developer contact email | *your email* |

   Leave everything else blank/default.

4. Click **Save and Continue**

5. **Scopes page** — click **Add or Remove Scopes**
   - In the filter box, type `drive`
   - Check the box for **`.../auth/drive`** (described as "See, edit, create, and delete all of your Google Drive files")
   - Click **Update**
   - Click **Save and Continue**

6. **Test users page** — click **+ Add Users**
   - Enter your own Gmail / Google Workspace email address
   - Click **Add**
   - Click **Save and Continue**

7. Click **Back to Dashboard**

> **About "Testing" mode:** Your app will stay in "Testing" status — this is fine. It means only the test users you added (yourself) can authenticate. You do **not** need to publish the app or go through Google's verification process. The only limitation is that tokens expire after 7 days, but rclone handles automatic refresh.

### Step 4 — Create OAuth Client ID & Secret

1. Go to **APIs & Services → Credentials**

   > Direct link: https://console.cloud.google.com/apis/credentials

2. Click **+ Create Credentials** at the top, then choose **OAuth client ID**

3. Set the fields:

   | Field | Value |
   |---|---|
   | Application type | **Desktop app** |
   | Name | `gdrive-sync` (or anything you like) |

4. Click **Create**

5. A dialog appears with your credentials:

   ```
   Client ID:     123456789-xxxxxxxxx.apps.googleusercontent.com
   Client Secret:  GOCSPX-xxxxxxxxxxxxxxxxxxxxxxx
   ```

6. **Copy both values** — you'll paste them into the script when adding a sync

> **Security note:** Treat the Client Secret like a password. Don't commit it to Git, don't share it publicly. It's stored locally in `~/.config/rclone/rclone.conf` on your server.

### Step 5 — Get Your Google Drive Folder ID

1. Open [Google Drive](https://drive.google.com) in your browser
2. Navigate to the folder you want to sync
3. Look at the URL bar:

   ```
   https://drive.google.com/drive/folders/1aBcDeFgHiJkLmNoPqRsTuVwXyZ012345
                                          └───────────── Folder ID ─────────────┘
   ```

4. Copy the string after `/folders/` — that's your Folder ID

> **Tip:** If you want to sync a subfolder, navigate to that subfolder and copy its ID. If you want to sync your entire Drive, leave the Folder ID field empty when the script asks (rclone will use the Drive root).

### Step 6 — Run the Script

```bash
./gdrive-sync.sh
```

Choose **1) Add new sync** and paste your Client ID, Client Secret, and Folder ID when prompted. A browser window will open (or a URL will be printed for headless servers) for you to authorize access.

---

## Usage

### Interactive Menu

```bash
./gdrive-sync.sh
```

```
  ┌─────────────────────────────────────────────┐
  │   Google Drive Sync Manager  v0.2.0         │
  │   rclone bisync + inotify-tools             │
  └─────────────────────────────────────────────┘

  Active syncs:
    ● my-documents
    ● project-backups

  Menu
     1) Add new sync          2) List configurations
     3) Show status            4) Edit a configuration
     5) Remove a configuration 6) View logs
     7) Manual sync now        8) Test Drive connection
     9) Settings              10) Run tests
     0) Exit
```

### Non-Interactive

```bash
# Quick status check (scriptable)
./gdrive-sync.sh --status

# Test that a sync's Drive connection is healthy
./gdrive-sync.sh --test-drive my-documents

# Dry run — walk through setup without writing anything
./gdrive-sync.sh --dry-run

# Verbose mode (extra rclone output + diagnostics)
./gdrive-sync.sh -v

# Combine flags
./gdrive-sync.sh -v --dry-run

# Run the test suite
./gdrive-sync.sh --test

# Help / version
./gdrive-sync.sh --help
./gdrive-sync.sh --version
```

### Managing Services Directly

Each sync creates a systemd service. You can manage them with standard tools:

```bash
# Check status
sudo systemctl status gdrive-sync-my-documents

# Stop syncing
sudo systemctl stop gdrive-sync-my-documents

# Restart
sudo systemctl restart gdrive-sync-my-documents

# View logs with journalctl
journalctl -u gdrive-sync-my-documents -f
```

---

## How It Works

### Architecture

```
┌──────────────────────────────────────────────────────────────┐
│  gdrive-sync.sh (interactive manager)                        │
│                                                              │
│  Sets up:                                                    │
│    ├── rclone remote  (OAuth + folder config)                │
│    ├── systemd service (runs the inotify watcher)            │
│    └── cron job (periodic Drive → local pull)                │
└──────────────────────────────────────────────────────────────┘

┌─ systemd service ──────────────────────────────────────────┐
│                                                             │
│  inotifywait -m -r (watches local folder)                   │
│       │                                                     │
│       ├── file change detected                              │
│       ├── debounce (5 seconds)                              │
│       ├── acquire lock (skip if another sync is running)    │
│       └── rclone bisync local ↔ remote                      │
│                                                             │
└─────────────────────────────────────────────────────────────┘

┌─ cron job ──────────────────────────────────────────────────┐
│                                                             │
│  Every N minutes:                                           │
│    rclone bisync local ↔ remote                             │
│    (catches Drive-side changes: web edits, mobile, etc.)    │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### Sync Direction

| Change made on | Detected by | Delay | Mechanism |
|---|---|---|---|
| **Local filesystem** | `inotifywait` | ~5 seconds (debounce) | systemd service |
| **Google Drive** (web/mobile/API) | Cron schedule | 1–15 min (configurable) | cron job |

### Conflict Resolution

When the same file is modified on both sides between syncs:

- **The newer file wins** (`--conflict-resolve newer`)
- **The older version is kept** as a renamed copy with a numeric suffix (`--conflict-loser num`), e.g. `report.docx` → `report.docx.conflict1`
- No data is ever silently lost

### Files Created

For each sync named `<name>`:

| File | Purpose |
|---|---|
| `~/.config/gdrive-sync/<name>.env` | Config (folder, remote, schedule) |
| `~/.config/gdrive-sync/<name>-watcher.sh` | inotify watcher script |
| `~/gdrive-sync-<name>.log` | Sync log (auto-rotated at 50 MB) |
| `/etc/systemd/system/gdrive-sync-<name>.service` | Systemd unit |
| `~/.config/rclone/rclone.conf` | rclone remote entry (shared file) |

---

## Configuration

### Global Settings

Global defaults are stored in `~/.config/gdrive-sync/settings.conf` and can be edited via menu option 9 (Settings) or by hand:

```bash
# ~/.config/gdrive-sync/settings.conf
DEBOUNCE_SEC="5"           # Seconds before syncing after local change
LOG_MAX_SIZE_MB="50"       # Rotate log above this size
MIN_RCLONE_VERSION="1.62.0"
DEFAULT_CRON="*/5 * * * *" # Default schedule for new syncs
LOG_LINES="50"             # Default lines shown in log viewer
```

These values are used when creating new syncs and by the watcher scripts. Changes take effect on the next sync event or next run.

### Environment Variables

| Variable | Default | Description |
|---|---|---|
| `RCLONE_CONF` | `~/.config/rclone/rclone.conf` | Path to rclone config |
| `GDRIVE_SYNC_DIR` | `~/.config/gdrive-sync` | Where sync configs are stored |

---

## Headless Servers (No Browser)

If your server doesn't have a desktop/browser, rclone will print a URL during OAuth setup:

```
If your browser doesn't open automatically go to the following link:
    https://accounts.google.com/o/oauth2/auth?client_id=...

Log in and authorize rclone for access.
Enter verification code>
```

1. Copy the URL and open it in a browser on any machine
2. Sign in and authorize
3. Copy the verification code and paste it back into the terminal

Alternatively, you can run `rclone authorize "drive"` on a machine with a browser, then copy the token to your server. See [rclone remote setup docs](https://rclone.org/remote_setup/).

---

## Troubleshooting

### "Bisync critical error"

This means the bisync tracking files are out of date. Run a manual sync from the menu (option 7) — the script will offer to re-establish the baseline with `--resync`.

### Token expired / "403 Forbidden"

Google OAuth tokens from apps in "Testing" mode expire after 7 days. rclone handles auto-refresh, but if it fails:

```bash
# Re-authorize the remote
rclone config reconnect <remote-name>:
```

### Changes on Drive aren't syncing down

Check that the cron job is running:

```bash
crontab -l | grep gdrive-sync
```

Check the log for errors:

```bash
tail -50 ~/gdrive-sync-<name>.log
```

### inotify watch limit reached

If you get `Failed to watch /path; upper limit on inotify watches reached!`:

```bash
# Check current limit
cat /proc/sys/fs/inotify/max_user_watches

# Increase it (temporary)
sudo sysctl fs.inotify.max_user_watches=524288

# Make it permanent
echo "fs.inotify.max_user_watches=524288" | sudo tee -a /etc/sysctl.conf
sudo sysctl -p
```

### Service won't start

```bash
# Check service logs
journalctl -u gdrive-sync-<name> -e --no-pager

# Verify the watcher script is executable
ls -la ~/.config/gdrive-sync/<name>-watcher.sh
```

---

## Uninstalling

Use the interactive menu to remove individual syncs (option 5). To fully clean up:

```bash
# Remove all services
for svc in /etc/systemd/system/gdrive-sync-*.service; do
  name=$(basename "$svc" .service)
  sudo systemctl stop "$name" 2>/dev/null
  sudo systemctl disable "$name" 2>/dev/null
  sudo rm -f "$svc"
done
sudo systemctl daemon-reload

# Remove cron jobs
crontab -l 2>/dev/null | grep -v 'gdrive-sync' | crontab -

# Remove configs and logs
rm -rf ~/.config/gdrive-sync
rm -f ~/gdrive-sync-*.log

# Optionally remove rclone remotes
rclone config show  # review first
# rclone config delete <remote-name>
```

---

## Security Considerations

- The script **never runs as root** — it uses `sudo` only for systemd operations
- OAuth credentials are stored in `~/.config/rclone/rclone.conf` (file permissions: `0600`)
- Systemd services run with `NoNewPrivileges=true` and `ProtectSystem=strict`
- Client Secret is only entered once during setup and never logged
- No data leaves your server except to Google Drive via rclone's encrypted HTTPS connection

---

## Limitations

- **Linux only** — requires `inotifywait` and `systemd`
- **Not real-time for Drive → local** — remote changes are detected by polling (cron), not push
- **Google API quotas** — free tier allows 12,000 queries per day; very active folders with 1-minute cron may approach this
- **Large files** — very large files (multi-GB) may time out on slow connections; consider increasing the debounce
- **Symbolic links** — rclone does not follow symlinks by default
- **Google Docs/Sheets/Slides** — these are not real files on Drive; rclone can export them (see `rclone --drive-export-formats`) but bisync of exported formats can be tricky

---

## Contributing

Pull requests welcome! See [CONTRIBUTING.md](CONTRIBUTING.md) for the full guide — how to fork, branch, test, and submit a PR.

To report a bug or request a feature, [open an issue](https://github.com/wahidlahlou/gdrive-sync/issues/new/choose).

---

## License

MIT — see [LICENSE](LICENSE).
