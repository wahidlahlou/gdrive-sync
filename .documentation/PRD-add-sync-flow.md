# PRD: "Add New Sync" User Flow

## Goal

Redesign the `action_add()` flow so that every step gives the user clear feedback:
what we checked, what we found, what we need, what comes next, and how to fix problems.

---

## Principles

1. **Show, don't ask** — if we can detect something (credentials, packages), show it and let the user confirm rather than asking if they have it
2. **No dead-end surprises** — check prerequisites before collecting input that depends on them
3. **Progress visibility** — numbered steps, result indicators (✓/✗), clear transitions
4. **Reuse what exists** — detect existing OAuth credentials from rclone.conf
5. **Graceful errors** — every failure explains what went wrong and how to fix it
6. **Minimal confirms** — only confirm when action is destructive, costs money, or requires sudo

---

## Step-by-step Flow

### Step 1: Dependencies

Check each dependency and show result inline. Only prompt if something needs installing.

**All present:**
```
══ Step 1/7 — Checking Dependencies

  curl         ✓ 8.5.0
  rclone       ✓ v1.68.2 (>= 1.62.0)
  inotifywait  ✓ present
  systemd      ✓ present

  All dependencies satisfied.
```
*(no confirm — move on)*

**Some missing:**
```
══ Step 1/7 — Checking Dependencies

  curl         ✓ 8.5.0
  rclone       ✗ not installed
  inotifywait  ✗ not installed
  systemd      ✓ present

  Missing packages will be installed (requires sudo).
  You may be prompted for your password.

  Continue? [y/N]
```

**rclone too old:**
```
  rclone       ⚠ v1.58.0 (>= 1.62.0 required for stable bisync)

  Upgrade rclone to latest? [y/N]
```

---

### Step 2: Google OAuth Credentials

Check `rclone.conf` for any existing Google Drive remote that has `client_id` + `client_secret`.

**Case A — Found existing credentials:**
```
══ Step 2/7 — Google OAuth Credentials

  Found existing Google Drive credentials (from remote "my-drive"):
    Client ID     : 1069449091950-mef0p1...r8j.apps.googleusercontent.com
    Client Secret : GOCSPX-...F5Q83

  1) Reuse these credentials
  2) Enter new credentials

  Choice [1]:
```

If reuse → skip input, move on.
If new → fall through to Case B input.

**Case B — No existing credentials:**
```
══ Step 2/7 — Google OAuth Credentials

  No existing Google Drive credentials found.

  You need a Client ID and Client Secret from Google Cloud Console:
  https://console.cloud.google.com/apis/credentials

  For step-by-step instructions, see:
  https://github.com/wahidlahlou/gdrive-sync#prerequisites

  Google OAuth Client ID     : ___
  Google OAuth Client Secret : ___
```

**Validation:**
- Neither field can be empty → `"Client ID is required."` / `"Client Secret is required."`

---

### Step 3: Google Drive Folder

```
══ Step 3/7 — Google Drive Folder

  1) Enter an existing folder ID
  2) Create a new folder on Google Drive

  Choice [1]:
```

**Option 1 — Enter existing ID:**
```
  Open the target folder in Google Drive and copy the ID from the URL.
  Example: https://drive.google.com/drive/folders/1AbCdEf... → ID is 1AbCdEf...

  Google Drive Folder ID : ___
```

**Option 2 — Create new folder:**

This sub-flow authenticates early (creates the rclone remote without `root_folder_id`), creates the folder, retrieves the ID, then scopes the remote. Sets `REMOTE_ALREADY_CONFIGURED=1` so Step 8 skips re-creating the remote.

```
  New folder name on Google Drive : ___

  Authenticating with Google Drive...
  A browser window will open for Google authorization.

  ✓ Authenticated.
  Creating folder 'MyProject' on Google Drive...
  ✓ Created 'MyProject' — Folder ID: 1zHhqlwzdNxn9ItusU_Zft4KpkVR72ipE
```

**Error — folder creation failed:**
```
  ✗ Failed to create folder on Google Drive.
    Check your internet connection and try again.
    If the problem persists, verify your OAuth credentials.
```

**Error — could not retrieve folder ID:**
```
  ✗ Folder created but could not retrieve its ID.
    Open Google Drive, find the folder, and copy the ID from the URL.
    Then re-run setup and choose "Enter an existing folder ID".
```

---

### Step 4: Local Folder

```
══ Step 4/7 — Local Folder

  Local folder path : ___
```

After input, immediate feedback:
```
  ✓ Directory exists (12 items — existing files will be included in first sync).
```
or:
```
  Directory does not exist — it will be created during setup.
```

**Validation:**
- Cannot be empty → `"Path cannot be empty."`

---

### Step 5: Config Name

```
══ Step 5/7 — Config Name

  This name identifies the sync. Used for service name, log file, and config file.

  Config name (letters, numbers, hyphens) : ___
```

**Already exists:**
```
  ⚠ Config 'my-sync' already exists.
  1) Overwrite  2) Choose a different name  3) Abort

  Choice [2]:
```

**Validation:**
- Cannot be empty
- Must match `^[a-zA-Z0-9_-]+$`

---

### Step 6: Sync Schedule

```
══ Step 6/7 — Sync Schedule (Drive → Local)

  Local changes push to Drive within ~5 seconds (via file watcher).
  This schedule controls how often remote Drive changes are pulled down.

  1) Every 5 min (recommended)
  2) Every 10 min
  3) Every 15 min
  4) Every 1 min (heavy on API quota)
  5) Custom cron expression

  Choice [1]:
```

---

### Step 7: Summary + Confirm

```
══ Step 7/7 — Review & Confirm

  Config name      : my-sync
  Local folder     : /home/user/Documents/drive-sync
  Drive Folder ID  : 1zHhqlwzdNxn9ItusU_Zft4KpkVR72ipE
  Sync schedule    : */5 * * * * (every 5 min)
  Log file         : /home/user/gdrive-sync-my-sync.log

  This will:
    - Configure rclone remote with Google Drive
    - Download existing files from Drive to local folder
    - Create a systemd service (requires sudo)
    - Set up a cron job for periodic sync

  Proceed? [y/N]
```

---

### Step 8: Execution

Each sub-step prints what it is doing and the result. Numbered progress.

```
  [1/6] Preparing local directory...
        ✓ Created /home/user/Documents/drive-sync

  [2/6] Configuring rclone remote...
        A browser window will open for Google authorization.
        ✓ Remote 'my-sync' configured.

  [3/6] Verifying Drive connection...
        ✓ Connected to Google Drive.

  [4/6] Initial sync: Drive → Local...
        ✓ Initial download complete.

  [5/6] Establishing bisync baseline...
        ✓ Bisync baseline established.

  [6/6] Setting up watcher, service, and cron...
        ✓ Watcher script created.
        ✓ Service 'gdrive-sync-my-sync' started and enabled.
        ✓ Cron job active: */5 * * * *
        ✓ Config saved.

  ────────────────────────────────────

  ✓ Setup complete! 'my-sync' is now syncing.

    Monitor : tail -f /home/user/gdrive-sync-my-sync.log
    Status  : sudo systemctl status gdrive-sync-my-sync
```

**If remote already configured (folder was created in Step 3):**
Step [2/6] shows `✓ Remote 'my-sync' already configured.` and skips OAuth.

**Error — Drive connection failed:**
```
  [3/6] Verifying Drive connection...
        ✗ Cannot access Google Drive folder.

        Possible causes:
          - The Folder ID is incorrect
          - OAuth token expired — try: rclone config reconnect my-sync:
          - Network issue — check your internet connection

        Setup aborted. The rclone remote has been removed.
```

**Error — systemd start failed:**
```
  [6/6] Setting up watcher, service, and cron...
        ✓ Watcher script created.
        ⚠ Service 'gdrive-sync-my-sync' failed to start.
          Check: sudo journalctl -u gdrive-sync-my-sync -n 20
        ✓ Cron job active: */5 * * * *

  ⚠ Setup finished with warnings — sync may not be running.
```

---

## Credential Detection Logic

```
detect_existing_credentials():
  1. Check if rclone is installed — if not, return empty (no credentials possible)
  2. Check if rclone.conf exists — if not, return empty
  3. Parse rclone.conf for sections with type = drive
  4. For the first drive section that has client_id set:
     - Extract client_id, client_secret, and the remote name (section header)
  5. Return (remote_name, client_id, client_secret) or empty
```

Note: we only reuse the OAuth **app credentials** (client_id/secret), not the token.
The new remote gets its own token via a fresh browser authorization flow.
This means reuse works even if the original remote's token has expired.

Implementation (bash, no jq):
```bash
detect_drive_credentials() {
  command -v rclone &>/dev/null || return 1
  [[ -f "$RCLONE_CONF" ]] || return 1

  local current_remote="" found_drive=false
  DETECTED_CLIENT_ID=""
  DETECTED_CLIENT_SECRET=""
  DETECTED_REMOTE_NAME=""

  while IFS= read -r line; do
    # Section header: [remote-name] — reset state for new section
    if [[ "$line" =~ ^\[([^]]+)\]$ ]]; then
      current_remote="${BASH_REMATCH[1]}"
      found_drive=false
      DETECTED_CLIENT_ID=""
      DETECTED_CLIENT_SECRET=""
    elif [[ "$line" =~ ^type\ =\ drive$ ]]; then
      found_drive=true
    elif [[ "$found_drive" == "true" && "$line" =~ ^client_id\ =\ (.+)$ ]]; then
      DETECTED_CLIENT_ID="${BASH_REMATCH[1]}"
    elif [[ "$found_drive" == "true" && "$line" =~ ^client_secret\ =\ (.+)$ ]]; then
      DETECTED_CLIENT_SECRET="${BASH_REMATCH[1]}"
    fi

    if [[ "$found_drive" == "true" && -n "$DETECTED_CLIENT_ID" && -n "$DETECTED_CLIENT_SECRET" ]]; then
      DETECTED_REMOTE_NAME="$current_remote"
      return 0
    fi
  done < "$RCLONE_CONF"
  return 1
}
```

---

## Dry-Run Behavior

In dry-run mode, a banner is shown at the top:
```
  ⚠ DRY RUN — no changes will be written.
```

Input collection (Steps 1-7) works normally so the user can validate the full setup.

**Step 3 — folder creation in dry-run:**
If the user picks "Create new folder", we ask for the folder name but don't actually
create it. Show `[dry-run] Would create folder 'X' on Google Drive` and use the
folder name as a placeholder in the summary.

**Step 8 — execution in dry-run:**
Each sub-step shows what *would* happen:
```
  [1/6] [dry-run] Would create /home/user/Documents/drive-sync
  [2/6] [dry-run] Would create rclone remote 'my-sync'
  [3/6] [dry-run] Skipping Drive verification
  [4/6] [dry-run] Skipping initial sync
  [5/6] [dry-run] Skipping bisync baseline
  [6/6] [dry-run] Would create watcher, systemd service, and cron job

  DRY RUN COMPLETE — nothing was written. Re-run without --dry-run to apply.
```

---

## Edge Cases

| Scenario | Handling |
|----------|----------|
| rclone not installed, user picks "Create folder" | Step 1 installs rclone first; folder creation works |
| Same client_id/secret for multiple syncs | Detected and reused; each sync gets its own remote name + root_folder_id |
| Folder name with spaces | Supported — rclone handles them; quoted in all commands |
| Config name collision | Prompt: overwrite / rename / abort |
| rclone token expired during setup | Error in Step 8 [3/6] with reconnect instructions |
| Network down during folder creation | Error with retry/debug guidance |
| User cancels OAuth browser flow | rclone config create fails → error + cleanup |
