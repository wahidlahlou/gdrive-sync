#!/usr/bin/env bash

# ============================================================
#  gdrive-sync.sh  —  Google Drive <-> Local Folder Sync Manager
#  https://github.com/wahidlahlou/gdrive-sync
#
#  Uses rclone bisync + inotify-tools + systemd + cron
#  Designed for Ubuntu/Debian servers
#
#  License: MIT
# ============================================================

VERSION="0.2.0"

# ----- Strict mode (without errexit — we handle errors ourselves) ----------
set -o pipefail
shopt -s nullglob

# ----- Colors & helpers ----------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $1"; }
success() { echo -e "${GREEN}[ OK ]${NC}  $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $1"; }
err()     { echo -e "${RED}[ERR ]${NC}  $1" >&2; }
die()     { err "$1"; exit 1; }
header()  { echo -e "\n${BOLD}${BLUE}══ $1${NC}"; }
debug()   { [[ "$VERBOSE" == "1" ]] && echo -e "${DIM}[DBG ]  $1${NC}"; }

confirm() {
  local prompt="${1:-Continue?}"
  local ans
  read -rp "$(echo -e "${BOLD}${prompt}${NC} [y/N] ")" ans
  [[ "$ans" =~ ^[Yy]$ ]]
}

step_header() { echo -e "\n${BOLD}${BLUE}══ Step $1 — $2${NC}\n"; }

pause() { echo ""; read -rp "Press Enter to continue..."; }

# Run a command with a spinner. Usage: spin "message" command [args...]
spin() {
  local msg="$1"; shift
  local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  local tmp; tmp=$(mktemp)

  "$@" &>"$tmp" &
  local pid=$!
  local i=0

  # Hide cursor
  tput civis 2>/dev/null || true
  while kill -0 "$pid" 2>/dev/null; do
    printf "\r  ${CYAN}%s${NC} %s" "${frames[i++ % ${#frames[@]}]}" "$msg"
    sleep 0.1
  done

  wait "$pid"
  local rc=$?
  # Show cursor, clear line
  tput cnorm 2>/dev/null || true
  printf "\r\033[K"

  # On failure, show captured output
  if [[ $rc -ne 0 ]]; then
    cat "$tmp"
  fi
  rm -f "$tmp"
  return $rc
}

# ----- Mask a string: show first N and last M chars, middle is dots --------
mask_value() {
  local val="$1" show_start="${2:-8}" show_end="${3:-6}"
  local len=${#val}
  if [[ $len -le $((show_start + show_end + 3)) ]]; then
    echo "$val"
  else
    echo "${val:0:$show_start}...${val: -$show_end}"
  fi
}

need_cmd() {
  command -v "$1" &>/dev/null || die "Required command '$1' not found. Install it and retry."
}

# ----- Validate Google OAuth credential format --------------------------------
validate_google_credentials() {
  local client_id="$1" client_secret="$2"
  local ok=true

  # Client ID: should end with .apps.googleusercontent.com
  if [[ "$client_id" =~ \.apps\.googleusercontent\.com$ ]]; then
    echo -e "  ${GREEN}✓${NC} Client ID format looks valid."
  else
    echo -e "  ${YELLOW}⚠${NC} Client ID does not end with .apps.googleusercontent.com"
    echo -e "    Expected format: ${DIM}NNNNN-XXXXX.apps.googleusercontent.com${NC}"
    ok=false
  fi

  # Client Secret: should start with GOCSPX-
  if [[ "$client_secret" =~ ^GOCSPX- ]]; then
    echo -e "  ${GREEN}✓${NC} Client Secret format looks valid."
  else
    echo -e "  ${YELLOW}⚠${NC} Client Secret does not start with GOCSPX-"
    echo -e "    Expected format: ${DIM}GOCSPX-XXXXXXXXX${NC}"
    ok=false
  fi

  if [[ "$ok" == "false" ]]; then
    echo ""
    echo -e "  The credentials may still work, but double-check them."
    confirm "  Continue anyway?" || return 1
  fi
  return 0
}

# ----- Global flags (set by CLI parsing) -----------------------------------
VERBOSE="${VERBOSE:-0}"
DRY_RUN="${DRY_RUN:-0}"

# ----- Directories & defaults ----------------------------------------------
RCLONE_CONF="${RCLONE_CONF:-$HOME/.config/rclone/rclone.conf}"
SYNC_DIR="${GDRIVE_SYNC_DIR:-$HOME/.config/gdrive-sync}"
SETTINGS_FILE="${SYNC_DIR}/settings.conf"

# Defaults (overridden by settings.conf if present)
DEBOUNCE_SEC=5
LOG_MAX_SIZE_MB=50
MIN_RCLONE_VERSION="1.62.0"
DEFAULT_CRON="*/5 * * * *"
LOG_LINES=50

# ----- Pre-flight ----------------------------------------------------------
if [[ "${GDRIVE_SYNC_TESTING:-}" != "1" ]]; then
  [[ "$(uname -s)" == "Linux" ]] || die "This tool is designed for Linux only."
fi

# Use sudo only when not already root
if [[ "$EUID" -eq 0 ]]; then
  SUDO=""
else
  SUDO="sudo"
fi

mkdir -p "$SYNC_DIR"

# ----- Load / save global settings -----------------------------------------
load_settings() {
  if [[ -f "$SETTINGS_FILE" ]]; then
    debug "Loading settings from $SETTINGS_FILE"
    # shellcheck source=/dev/null
    source "$SETTINGS_FILE"
  fi
}

save_settings() {
  cat > "$SETTINGS_FILE" <<EOF
# gdrive-sync global settings
# Edit these values or use menu option 9 to change them.
# Changes take effect on next run / next sync event.

DEBOUNCE_SEC="${DEBOUNCE_SEC}"
LOG_MAX_SIZE_MB="${LOG_MAX_SIZE_MB}"
MIN_RCLONE_VERSION="${MIN_RCLONE_VERSION}"
DEFAULT_CRON="${DEFAULT_CRON}"
LOG_LINES="${LOG_LINES}"
EOF
}

[[ -f "$SETTINGS_FILE" ]] || save_settings
load_settings

# ===================================================================
#  CLI PARSING
# ===================================================================

show_help() {
  cat <<HELP

  gdrive-sync v${VERSION} — Google Drive <-> Local Folder Sync Manager

  USAGE
    ./gdrive-sync.sh                     Interactive menu
    ./gdrive-sync.sh -v                  Verbose mode
    ./gdrive-sync.sh -n, --dry-run       Walk through add without writing anything
    ./gdrive-sync.sh --status            Quick status of all syncs
    ./gdrive-sync.sh --test              Run the test suite
    ./gdrive-sync.sh --test-drive [name] Test Google Drive API connection
    ./gdrive-sync.sh --help              This help
    ./gdrive-sync.sh --version           Version

  FLAGS (combinable)
    -v, --verbose   Extra diagnostics and rclone output
    -n, --dry-run   Validate inputs and test Drive connection only;
                    does not create services, cron jobs, or sync files

  MENU OPTIONS
     1  Add new sync           2  List configurations
     3  Status                 4  Edit configuration
     5  Remove configuration   6  View logs
     7  Manual sync            8  Test Drive connection
     9  Settings              10  Run tests
     0  Exit

  FILES
    ~/.config/gdrive-sync/settings.conf   Global defaults
    ~/.config/gdrive-sync/<name>.env      Per-sync config
    ~/gdrive-sync-<name>.log              Sync log (auto-rotated)

HELP
  exit 0
}

CLI_ACTION=""
CLI_ARG=""
for arg in "$@"; do
  case "$arg" in
    --help|-h)       show_help ;;
    --version)       echo "gdrive-sync $VERSION"; exit 0 ;;
    -v|--verbose)    VERBOSE=1 ;;
    -n|--dry-run)    DRY_RUN=1 ;;
    --status)        CLI_ACTION="status" ;;
    --test)          CLI_ACTION="test" ;;
    --test-drive)    CLI_ACTION="test-drive" ;;
    --test-drive=*)  CLI_ACTION="test-drive"; CLI_ARG="${arg#*=}" ;;
    *)               [[ "$CLI_ACTION" == "test-drive" && -z "$CLI_ARG" ]] && CLI_ARG="$arg" ;;
  esac
done

[[ "$DRY_RUN" == "1" ]] && info "DRY RUN mode — no changes will be written."
[[ "$VERBOSE" == "1" ]] && debug "Verbose mode enabled."

# ===================================================================
#  CREDENTIAL DETECTION
# ===================================================================

# Populates DETECTED_CREDS array: each entry is "source|client_id|client_secret"
# Returns 0 if at least one credential set was found.
detect_drive_credentials() {
  DETECTED_CREDS=()
  local seen=()  # track unique client_id values to avoid duplicates

  # 1) Search gdrive-sync .env config files
  for f in "${SYNC_DIR}"/*.env; do
    [[ -f "$f" ]] || continue
    local cfg_cid="" cfg_csec="" cfg_name=""
    cfg_name="$(basename "$f" .env)"
    while IFS='=' read -r key val; do
      val="${val#\"}" ; val="${val%\"}"
      case "$key" in
        CLIENT_ID)     cfg_cid="$val" ;;
        CLIENT_SECRET) cfg_csec="$val" ;;
      esac
    done < "$f"
    if [[ -n "$cfg_cid" && -n "$cfg_csec" ]]; then
      local dup=false
      for s in "${seen[@]+"${seen[@]}"}"; do [[ "$s" == "$cfg_cid" ]] && dup=true; done
      if [[ "$dup" == "false" ]]; then
        DETECTED_CREDS+=("config:${cfg_name}|${cfg_cid}|${cfg_csec}")
        seen+=("$cfg_cid")
      fi
    fi
  done

  # 2) Fall back to rclone.conf if no config credentials found
  if [[ ${#DETECTED_CREDS[@]} -eq 0 && -f "${RCLONE_CONF:-}" ]]; then
    local current_remote="" found_drive=false cid="" csec=""
    while IFS= read -r line; do
      if [[ "$line" =~ ^\[([^]]+)\]$ ]]; then
        # Save previous remote if complete
        if [[ "$found_drive" == "true" && -n "$cid" && -n "$csec" ]]; then
          local dup=false
          for s in "${seen[@]+"${seen[@]}"}"; do [[ "$s" == "$cid" ]] && dup=true; done
          if [[ "$dup" == "false" ]]; then
            DETECTED_CREDS+=("rclone:${current_remote}|${cid}|${csec}")
            seen+=("$cid")
          fi
        fi
        current_remote="${BASH_REMATCH[1]}"
        found_drive=false; cid=""; csec=""
      elif [[ "$line" =~ ^type\ =\ drive$ ]]; then
        found_drive=true
      elif [[ "$found_drive" == "true" && "$line" =~ ^client_id\ =\ (.+)$ ]]; then
        cid="${BASH_REMATCH[1]}"
      elif [[ "$found_drive" == "true" && "$line" =~ ^client_secret\ =\ (.+)$ ]]; then
        csec="${BASH_REMATCH[1]}"
      fi
    done < "$RCLONE_CONF"
    # Don't forget the last remote
    if [[ "$found_drive" == "true" && -n "$cid" && -n "$csec" ]]; then
      local dup=false
      for s in "${seen[@]+"${seen[@]}"}"; do [[ "$s" == "$cid" ]] && dup=true; done
      if [[ "$dup" == "false" ]]; then
        DETECTED_CREDS+=("rclone:${current_remote}|${cid}|${csec}")
      fi
    fi
  fi

  [[ ${#DETECTED_CREDS[@]} -gt 0 ]]
}

# ===================================================================
#  DEPENDENCY MANAGEMENT
# ===================================================================

version_gte() {
  printf '%s\n%s' "$2" "$1" | sort -V -C
}

check_rclone_version() {
  local ver
  ver=$(rclone version 2>/dev/null | head -1 | grep -oP 'v\K[0-9]+\.[0-9]+\.[0-9]+' || echo "0.0.0")
  if ! version_gte "$ver" "$MIN_RCLONE_VERSION"; then
    warn "rclone $ver found, but >= $MIN_RCLONE_VERSION required for stable bisync."
    return 1
  fi
  return 0
}

install_rclone() {
  header "Installing rclone (latest stable)"
  info "Downloading from rclone.org..."
  if curl -fsSL https://rclone.org/install.sh | $SUDO bash; then
    success "rclone installed: $(rclone version | head -1)"
  else
    warn "Curl install failed, trying apt..."
    $SUDO apt-get update -qq && $SUDO apt-get install -y rclone
  fi
}

check_dependencies_step() {
  step_header "1/7" "Checking Dependencies"

  local pkg_missing=false

  # --- curl ---
  if command -v curl &>/dev/null; then
    echo -e "  curl         ${GREEN}✓${NC} $(curl --version | head -1 | awk '{print $2}')"
  else
    echo -e "  curl         ${RED}✗${NC} not installed"
    pkg_missing=true
  fi

  # --- rclone ---
  if command -v rclone &>/dev/null; then
    local rclone_ver
    rclone_ver=$(rclone version 2>/dev/null | head -1 | grep -oP 'v\K[0-9]+\.[0-9]+\.[0-9]+' || echo "0.0.0")
    if version_gte "$rclone_ver" "$MIN_RCLONE_VERSION"; then
      echo -e "  rclone       ${GREEN}✓${NC} v${rclone_ver} (>= ${MIN_RCLONE_VERSION})"
    else
      echo -e "  rclone       ${YELLOW}⚠${NC} v${rclone_ver} (>= ${MIN_RCLONE_VERSION} required for stable bisync)"
      RCLONE_NEEDS_UPGRADE=1
    fi
  else
    echo -e "  rclone       ${RED}✗${NC} not installed"
    pkg_missing=true
  fi

  # --- inotify-tools ---
  if command -v inotifywait &>/dev/null; then
    echo -e "  inotifywait  ${GREEN}✓${NC} present"
  else
    echo -e "  inotifywait  ${RED}✗${NC} not installed"
    pkg_missing=true
  fi

  # --- systemd ---
  if command -v systemctl &>/dev/null; then
    echo -e "  systemd      ${GREEN}✓${NC} present"
  else
    echo -e "  systemd      ${RED}✗${NC} not found"
    if [[ "$DRY_RUN" != "1" ]]; then
      echo ""
      err "systemd is required but not found."
      return 1
    fi
  fi

  echo ""

  # Handle rclone upgrade offer
  if [[ "${RCLONE_NEEDS_UPGRADE:-}" == "1" && "$DRY_RUN" != "1" ]]; then
    if confirm "  Upgrade rclone to latest?"; then
      install_rclone
    else
      warn "Continuing with older rclone — bisync may be unstable."
    fi
    echo ""
  fi

  # Handle missing packages
  if [[ "$pkg_missing" == "true" ]]; then
    if [[ "$DRY_RUN" == "1" ]]; then
      echo -e "  ${YELLOW}[dry-run]${NC} Missing packages would be installed via apt / rclone.org"
    else
      echo -e "  Missing packages will be installed (requires sudo)."
      echo -e "  You may be prompted for your password."
      echo ""
      confirm "  Continue?" || return 1

      # Install missing packages
      if ! command -v curl &>/dev/null; then
        spin "Installing curl..." bash -c "$SUDO apt-get update -qq && $SUDO apt-get install -y curl"
      fi
      if ! command -v rclone &>/dev/null; then
        install_rclone
      fi
      if ! command -v inotifywait &>/dev/null; then
        spin "Installing inotify-tools..." bash -c "$SUDO apt-get update -qq && $SUDO apt-get install -y inotify-tools"
      fi

      # Verify
      echo ""
      command -v curl &>/dev/null && command -v rclone &>/dev/null && command -v inotifywait &>/dev/null \
        && echo -e "  ${GREEN}All dependencies installed.${NC}" \
        || { err "Some packages failed to install. Check the output above."; return 1; }
    fi
  else
    echo -e "  ${GREEN}All dependencies satisfied.${NC}"
  fi
}

# ===================================================================
#  CONFIG HELPERS
# ===================================================================

save_config() {
  local name="$1" remote="$2" local_dir="$3" folder_id="$4" cron="$5"
  local cid="${6:-}" csec="${7:-}"
  cat > "${SYNC_DIR}/${name}.env" <<EOF
# gdrive-sync config — do not edit manually unless you know what you're doing
REMOTE_NAME="${remote}"
LOCAL_DIR="${local_dir}"
FOLDER_ID="${folder_id}"
CRON_SCHEDULE="${cron}"
CLIENT_ID="${cid}"
CLIENT_SECRET="${csec}"
CREATED="$(date -Iseconds)"
EOF
}

load_config() {
  local name="$1"
  local cfg="${SYNC_DIR}/${name}.env"
  [[ -f "$cfg" ]] || return 1
  # shellcheck source=/dev/null
  source "$cfg"
}

list_config_names() {
  local configs=()
  for f in "${SYNC_DIR}"/*.env; do
    [[ -f "$f" ]] || continue
    configs+=("$(basename "$f" .env)")
  done
  [[ ${#configs[@]} -gt 0 ]] && printf '%s\n' "${configs[@]}"
}

select_config() {
  local configs
  mapfile -t configs < <(list_config_names)
  if [[ ${#configs[@]} -eq 0 ]]; then
    warn "No configurations found."
    return 1
  fi

  if [[ ${#configs[@]} -eq 1 ]]; then
    SELECTED="${configs[0]}"
    info "Auto-selected: $SELECTED"
    return 0
  fi

  echo "Available configurations:"
  local i=1
  for c in "${configs[@]}"; do
    echo "  $i) $c"
    ((i++))
  done

  local choice
  read -rp "Select [1]: " choice
  choice="${choice:-1}"

  if [[ "$choice" -ge 1 && "$choice" -le ${#configs[@]} ]] 2>/dev/null; then
    SELECTED="${configs[$((choice - 1))]}"
    return 0
  else
    warn "Invalid selection."
    return 1
  fi
}

# ===================================================================
#  WATCHER SCRIPT GENERATOR (with debounce)
# ===================================================================

generate_watcher_script() {
  local name="$1" local_dir="$2" remote="$3" log_file="$4"

  cat <<WATCHER
#!/usr/bin/env bash
# ---------------------------------------------------------------
#  Auto-generated by gdrive-sync.sh — do not edit manually
#  Sync: ${remote}: <-> ${local_dir}
# ---------------------------------------------------------------

LOCAL_DIR="${local_dir}"
REMOTE="${remote}:"
LOG_FILE="${log_file}"
DEBOUNCE=${DEBOUNCE_SEC}
LOG_MAX_MB=${LOG_MAX_SIZE_MB}
LOCK_FILE="/tmp/gdrive-sync-${name}.lock"

log() { echo "[\$(date '+%Y-%m-%d %H:%M:%S')] \$1" >> "\$LOG_FILE"; }

rotate_log() {
  local size_kb
  size_kb=\$(du -k "\$LOG_FILE" 2>/dev/null | cut -f1)
  if [[ "\${size_kb:-0}" -gt \$((LOG_MAX_MB * 1024)) ]]; then
    mv "\$LOG_FILE" "\${LOG_FILE}.old"
    log "Log rotated (was \${size_kb}KB)"
  fi
}

do_sync() {
  if [[ -f "\$LOCK_FILE" ]]; then
    local lock_age
    lock_age=\$(( \$(date +%s) - \$(stat -c %Y "\$LOCK_FILE" 2>/dev/null || echo 0) ))
    if [[ \$lock_age -gt 300 ]]; then
      log "WARN: Stale lock (age: \${lock_age}s). Removing."
      rm -f "\$LOCK_FILE"
    else
      log "Sync already in progress (lock age: \${lock_age}s). Skipping."
      return
    fi
  fi

  touch "\$LOCK_FILE"
  log "SYNC START"
  /usr/bin/rclone bisync "\$LOCAL_DIR" "\$REMOTE" \
    --verbose \
    --conflict-resolve newer \
    --conflict-loser num \
    --resilient \
    --recover \
    --log-file="\$LOG_FILE" 2>&1
  local rc=\$?
  rm -f "\$LOCK_FILE"

  if [[ \$rc -eq 0 ]]; then
    log "SYNC OK"
  else
    log "SYNC FAILED (exit code: \$rc)"
  fi

  rotate_log
}

log "Watcher started for \$LOCAL_DIR -> \$REMOTE"
LAST_SYNC=0

inotifywait -m -r -e modify,create,delete,move --format '%T %e %w%f' --timefmt '%s' "\$LOCAL_DIR" |
while read -r timestamp event filepath; do
  NOW=\$(date +%s)
  SINCE_LAST=\$(( NOW - LAST_SYNC ))

  if [[ \$SINCE_LAST -ge \$DEBOUNCE ]]; then
    log "Change detected: \$event \$(basename "\$filepath") — syncing in \${DEBOUNCE}s..."
    sleep \$DEBOUNCE
    do_sync
    LAST_SYNC=\$(date +%s)
  fi
done
WATCHER
}

# ===================================================================
#  DRIVE FOLDER CREATION
# ===================================================================

create_drive_folder() {
  local remote_name="$1" client_id="$2" client_secret="$3"
  local folder_name

  while true; do
    read -rp "$(echo -e "  ${BOLD}New folder name on Google Drive${NC}: ")" folder_name
    [[ -z "$folder_name" ]] && { warn "Cannot be empty."; continue; }
    break
  done

  echo ""

  # Create rclone remote pointing at Drive root (triggers OAuth)
  mkdir -p "$(dirname "$RCLONE_CONF")"
  if rclone listremotes 2>/dev/null | grep -q "^${remote_name}:$"; then
    rclone config delete "$remote_name" 2>/dev/null || true
  fi
  echo -e "  Authenticating with Google Drive..."
  echo -e "  A browser window will open for Google authorization."
  echo ""

  # rclone config create runs an interactive OAuth flow (opens browser).
  # We must NOT capture stdout — rclone needs the terminal for the auth flow.
  # Note: no root_folder_id yet — we need Drive root access to create the folder.
  rclone config create "$remote_name" drive \
    client_id="$client_id" \
    client_secret="$client_secret" \
    scope="drive"
  local rc=$?

  echo ""
  if [[ $rc -ne 0 ]]; then
    echo -e "  ${RED}✗${NC} Authentication failed (exit code: ${rc})."
    echo -e "    Check your Client ID and Secret, then try again."
    echo -e "    If the browser didn't open, try: ${CYAN}rclone config reconnect ${remote_name}:${NC}"
    return 1
  fi

  echo -e "  ${GREEN}✓${NC} Authenticated."

  if ! spin "Creating folder '${folder_name}' on Drive..." rclone mkdir "${remote_name}:${folder_name}"; then
    echo -e "  ${RED}✗${NC} Failed to create folder on Google Drive."
    echo -e "    Check your internet connection and try again."
    rclone config delete "$remote_name" 2>/dev/null || true
    return 1
  fi

  # Retrieve the folder ID via rclone lsf (format: ID<tab>Path/)
  local folder_id
  folder_id=$(rclone lsf "${remote_name}:" --dirs-only --max-depth 1 \
    --format "ip" --separator $'\t' 2>/dev/null \
    | grep -F $'\t'"${folder_name}/" | head -1 | cut -f1)

  if [[ -z "$folder_id" ]]; then
    echo -e "  ${RED}✗${NC} Folder created but could not retrieve its ID."
    echo -e "    Open Google Drive, find the folder, and copy the ID from the URL."
    echo -e "    Then re-run setup and choose \"Enter an existing folder ID\"."
    rclone config delete "$remote_name" 2>/dev/null || true
    return 1
  fi

  echo -e "  ${GREEN}✓${NC} Created '${folder_name}' — Folder ID: ${folder_id}"

  # Scope the remote to the new folder by writing root_folder_id directly
  # into rclone.conf. We avoid "rclone config update" because it triggers
  # a second OAuth flow for Drive remotes.
  if grep -q "^\[${remote_name}\]" "$RCLONE_CONF" 2>/dev/null; then
    sed -i "/^\[${remote_name}\]/a root_folder_id = ${folder_id}" "$RCLONE_CONF"
  fi

  CREATED_FOLDER_ID="$folder_id"
  REMOTE_ALREADY_CONFIGURED=1
  return 0
}

# ===================================================================
#  CORE ACTIONS
# ===================================================================

action_add() {
  header "Add New Sync Configuration"

  [[ "$DRY_RUN" == "1" ]] && echo -e "\n  ${YELLOW}⚠ DRY RUN${NC} — no changes will be written.\n"

  # ── Step 1: Dependencies ──────────────────────────────────────────
  RCLONE_NEEDS_UPGRADE=0
  check_dependencies_step || { echo ""; return; }

  # ── Step 2: OAuth Credentials ─────────────────────────────────────
  step_header "2/7" "Google OAuth Credentials"

  local client_id client_secret

  if detect_drive_credentials; then
    local n_creds=${#DETECTED_CREDS[@]}

    if [[ $n_creds -eq 1 ]]; then
      # Single credential set — simple reuse prompt
      local src cid csec
      IFS='|' read -r src cid csec <<< "${DETECTED_CREDS[0]}"
      echo -e "  Found existing credentials (from ${BOLD}${src}${NC}):"
      echo -e "    Client ID     : ${DIM}$(mask_value "$cid")${NC}"
      echo -e "    Client Secret : ${DIM}$(mask_value "$csec")${NC}"
      echo ""
      echo "  1) Reuse these credentials"
      echo "  2) Enter new credentials"
      echo ""
      local cred_choice
      read -rp "$(echo -e "  ${BOLD}Choice [1]:${NC} ")" cred_choice
      case "${cred_choice:-1}" in
        2) ;;
        *) client_id="$cid"; client_secret="$csec" ;;
      esac
    else
      # Multiple credential sets found
      echo -e "  Found ${BOLD}${n_creds}${NC} existing credential sets:"
      echo ""
      local i=1
      for entry in "${DETECTED_CREDS[@]}"; do
        local src cid csec
        IFS='|' read -r src cid csec <<< "$entry"
        echo -e "  ${i}) ${BOLD}${src}${NC}  —  ID: ${DIM}$(mask_value "$cid")${NC}"
        ((i++))
      done
      echo -e "  ${i}) Enter new credentials"
      echo ""
      local cred_choice
      read -rp "$(echo -e "  ${BOLD}Choice [1]:${NC} ")" cred_choice
      cred_choice="${cred_choice:-1}"

      if [[ "$cred_choice" =~ ^[0-9]+$ && "$cred_choice" -ge 1 && "$cred_choice" -le "$n_creds" ]]; then
        local src cid csec
        IFS='|' read -r src cid csec <<< "${DETECTED_CREDS[$((cred_choice - 1))]}"
        client_id="$cid"; client_secret="$csec"
      fi
    fi
  fi

  if [[ -z "${client_id:-}" ]]; then
    # No credentials detected or user chose to enter new ones
    if [[ ${#DETECTED_CREDS[@]} -eq 0 ]]; then
      echo -e "  No existing Google Drive credentials found."
      echo ""
    fi
    echo -e "  You need a Client ID and Client Secret from Google Cloud Console:"
    echo -e "  ${CYAN}https://console.cloud.google.com/apis/credentials${NC}"
    echo ""
    echo -e "  For step-by-step instructions, see:"
    echo -e "  ${CYAN}https://github.com/wahidlahlou/gdrive-sync#prerequisites${NC}"
    echo ""

    read -rp "$(echo -e "  ${BOLD}Google OAuth Client ID${NC}     : ")" client_id
    [[ -z "$client_id" ]] && { err "Client ID is required."; return; }
    read -rp "$(echo -e "  ${BOLD}Google OAuth Client Secret${NC} : ")" client_secret
    [[ -z "$client_secret" ]] && { err "Client Secret is required."; return; }
  fi

  echo ""
  validate_google_credentials "$client_id" "$client_secret" || return

  # ── Step 3: Config Name ────────────────────────────────────────────
  step_header "3/7" "Config Name"

  echo -e "  This name identifies the sync. Used for service name, log file, and config file."
  echo ""

  local remote_name
  while true; do
    read -rp "$(echo -e "  ${BOLD}Config name${NC} (letters, numbers, hyphens): ")" remote_name
    [[ -z "$remote_name" ]] && { warn "Cannot be empty."; continue; }
    [[ "$remote_name" =~ ^[a-zA-Z0-9_-]+$ ]] || { warn "Invalid characters."; continue; }

    if [[ -f "${SYNC_DIR}/${remote_name}.env" ]]; then
      warn "Config '${remote_name}' already exists."
      echo "  1) Overwrite  2) Choose a different name  3) Abort"
      local dup; read -rp "  Choice [2]: " dup
      case "${dup:-2}" in 1) break ;; 2) continue ;; *) echo ""; info "Aborted."; return ;; esac
    else
      break
    fi
  done

  # ── Step 4: Google Drive Folder ───────────────────────────────────
  step_header "4/7" "Google Drive Folder"

  echo "  1) Enter an existing folder ID"
  echo "  2) Create a new folder on Google Drive"
  echo ""
  local folder_choice
  read -rp "$(echo -e "  ${BOLD}Choice [1]:${NC} ")" folder_choice

  local folder_id
  REMOTE_ALREADY_CONFIGURED=0

  case "${folder_choice:-1}" in
    2)
      if [[ "$DRY_RUN" == "1" ]]; then
        local dry_name
        read -rp "$(echo -e "  ${BOLD}Folder name (for dry-run display)${NC}: ")" dry_name
        folder_id="${dry_name:-new-folder}"
        echo -e "  ${YELLOW}[dry-run]${NC} Would create folder '${folder_id}' on Google Drive."
      else
        echo ""
        create_drive_folder "$remote_name" "$client_id" "$client_secret" || return
        folder_id="$CREATED_FOLDER_ID"
      fi
      ;;
    *)
      echo ""
      echo -e "  Open the target folder in Google Drive and copy the ID from the URL."
      echo -e "  Example: https://drive.google.com/drive/folders/${DIM}1AbCdEf...${NC} → ID is ${BOLD}1AbCdEf...${NC}"
      echo ""
      read -rp "$(echo -e "  ${BOLD}Google Drive Folder ID${NC}: ")" folder_id
      [[ -z "$folder_id" ]] && { err "Folder ID is required."; return; }
      ;;
  esac

  # ── Step 5: Local Folder ──────────────────────────────────────────
  step_header "5/7" "Local Folder"

  local local_dir
  read -rp "$(echo -e "  ${BOLD}Local folder path${NC}: ")" local_dir
  local_dir="${local_dir/#\~/$HOME}"
  [[ -z "$local_dir" ]] && { err "Path cannot be empty."; return; }
  local_dir="$(realpath -m "$local_dir")"

  echo ""
  if [[ -d "$local_dir" ]]; then
    local fc; fc=$(find "$local_dir" -maxdepth 1 -mindepth 1 | wc -l)
    if [[ $fc -gt 0 ]]; then
      echo -e "  ${GREEN}✓${NC} Directory exists (${fc} items — existing files will be included in first sync)."
    else
      echo -e "  ${GREEN}✓${NC} Directory exists and is empty."
    fi
  else
    local parent_dir; parent_dir="$(dirname "$local_dir")"
    if [[ ! -d "$parent_dir" ]]; then
      warn "Neither '${local_dir}' nor its parent directory exist."
      echo -e "  This may indicate a typo in the path."
    else
      echo -e "  ${YELLOW}⚠${NC}  Directory does not exist — it will be created during setup."
    fi
    confirm "  Create '${local_dir}'?" || { echo ""; info "Aborted."; return; }
  fi

  # ── Step 6: Sync Schedule ────────────────────────────────────────
  step_header "6/7" "Sync Schedule (Drive → Local)"

  echo -e "  Local changes push to Drive within ~${DEBOUNCE_SEC} seconds (via file watcher)."
  echo -e "  This schedule controls how often remote Drive changes are pulled down."
  echo ""
  echo "  1) Every 5 min (recommended)"
  echo "  2) Every 10 min"
  echo "  3) Every 15 min"
  echo "  4) Every 1 min (heavy on API quota)"
  echo "  5) Custom cron expression"
  echo ""
  local cron_choice cron_schedule
  read -rp "$(echo -e "  ${BOLD}Choice [1]:${NC} ")" cron_choice
  case "${cron_choice:-1}" in
    1) cron_schedule="*/5 * * * *" ;; 2) cron_schedule="*/10 * * * *" ;;
    3) cron_schedule="*/15 * * * *" ;; 4) cron_schedule="* * * * *" ;;
    5) read -rp "  Cron expression: " cron_schedule ;; *) cron_schedule="$DEFAULT_CRON" ;;
  esac

  # ── Step 7: Summary ──────────────────────────────────────────────
  local log_file="$HOME/gdrive-sync-${remote_name}.log"
  local service_name="gdrive-sync-${remote_name}"
  local watcher_script="${SYNC_DIR}/${remote_name}-watcher.sh"

  # ── Determine initial sync situation ───────────────────────────────
  local local_has_files=false drive_is_new=false
  if [[ -d "$local_dir" ]]; then
    local lfc; lfc=$(find "$local_dir" -maxdepth 1 -mindepth 1 | wc -l)
    [[ $lfc -gt 0 ]] && local_has_files=true
  fi
  [[ "$REMOTE_ALREADY_CONFIGURED" == "1" ]] && drive_is_new=true

  # INITIAL_SYNC values: "download", "upload", "merge"
  local INITIAL_SYNC="download"
  local TOTAL_STEPS=7

  if [[ "$local_has_files" == "true" && "$drive_is_new" == "true" ]]; then
    # Local has files, Drive folder was just created (empty) → upload
    INITIAL_SYNC="upload"
  elif [[ "$local_has_files" == "true" && "$drive_is_new" == "false" ]]; then
    # Both sides may have files — ask the user
    TOTAL_STEPS=8
    step_header "7/${TOTAL_STEPS}" "Initial Sync Strategy"

    echo -e "  ${YELLOW}⚠${NC}  Your local folder already has files, and the Drive folder may too."
    echo -e "  The first sync needs a strategy to avoid data loss."
    echo ""
    echo -e "  1) ${BOLD}Drive wins${NC}  — download Drive files to local, then start syncing"
    echo -e "                   ${DIM}Local files with same name will be overwritten by Drive version${NC}"
    echo -e "  2) ${BOLD}Local wins${NC}  — upload local files to Drive, then start syncing"
    echo -e "                   ${DIM}Drive files with same name will be overwritten by local version${NC}"
    echo -e "  3) ${BOLD}Merge both${NC}  — keep the newer version of each file on both sides"
    echo -e "                   ${DIM}Safest if files were edited on both sides${NC}"
    echo ""
    local sync_choice
    read -rp "$(echo -e "  ${BOLD}Choice [3]:${NC} ")" sync_choice
    case "${sync_choice:-3}" in
      1) INITIAL_SYNC="download" ;;
      2) INITIAL_SYNC="upload" ;;
      *) INITIAL_SYNC="merge" ;;
    esac
  fi
  # else: local is empty → "download" (just pulls Drive files, safe)

  step_header "${TOTAL_STEPS}/${TOTAL_STEPS}" "Review & Confirm"

  echo -e "  Config name      : ${BOLD}${remote_name}${NC}"
  echo -e "  Local folder     : ${local_dir}"
  echo -e "  Drive Folder ID  : ${folder_id}"
  echo -e "  Sync schedule    : ${cron_schedule}"
  echo -e "  Log file         : ${log_file}"

  local sync_desc
  case "$INITIAL_SYNC" in
    download) sync_desc="Drive → Local (download first)" ;;
    upload)   sync_desc="Local → Drive (upload first)" ;;
    merge)    sync_desc="Merge both (newer file wins)" ;;
  esac
  echo -e "  Initial sync     : ${sync_desc}"
  [[ "$DRY_RUN" == "1" ]] && echo -e "  Mode             : ${YELLOW}DRY RUN${NC}"
  echo ""
  echo -e "  This will:"
  echo -e "    ${DIM}•${NC} Configure rclone remote with Google Drive"
  case "$INITIAL_SYNC" in
    download) echo -e "    ${DIM}•${NC} Download Drive files to local folder" ;;
    upload)   echo -e "    ${DIM}•${NC} Upload local files to Drive folder" ;;
    merge)    echo -e "    ${DIM}•${NC} Merge files from both sides (newer wins, conflicts renamed)" ;;
  esac
  echo -e "    ${DIM}•${NC} Establish two-way sync baseline"
  echo -e "    ${DIM}•${NC} Create a systemd service ${DIM}(requires sudo)${NC}"
  echo -e "    ${DIM}•${NC} Set up a cron job for periodic sync"
  echo ""
  confirm "  Proceed?" || { echo ""; info "Aborted."; return; }

  # ── Execution ────────────────────────────────────────────────────
  echo ""

  # [1/6] Local directory
  echo -e "  [1/6] Preparing local directory..."
  if [[ "$DRY_RUN" == "1" ]]; then
    echo -e "        ${YELLOW}[dry-run]${NC} Would create ${local_dir}"
  elif [[ ! -d "$local_dir" ]]; then
    mkdir -p "$local_dir"
    echo -e "        ${GREEN}✓${NC} Created ${local_dir}"
  else
    echo -e "        ${GREEN}✓${NC} ${local_dir} exists."
  fi

  # [2/6] rclone remote
  echo ""
  echo -e "  [2/6] Configuring rclone remote..."
  if [[ "$DRY_RUN" == "1" ]]; then
    echo -e "        ${YELLOW}[dry-run]${NC} Would create rclone remote '${remote_name}'"
  elif [[ "$REMOTE_ALREADY_CONFIGURED" == "1" ]]; then
    echo -e "        ${GREEN}✓${NC} Remote '${remote_name}' already configured."
  else
    mkdir -p "$(dirname "$RCLONE_CONF")"
    if rclone listremotes 2>/dev/null | grep -q "^${remote_name}:$"; then
      rclone config delete "$remote_name" 2>/dev/null || true
    fi
    echo -e "        A browser window will open for Google authorization."

    rclone config create "$remote_name" drive \
      client_id="$client_id" \
      client_secret="$client_secret" \
      scope="drive" \
      root_folder_id="$folder_id"

    echo -e "        ${GREEN}✓${NC} Remote '${remote_name}' configured."
  fi

  # [3/6] Verify connection
  echo ""
  echo -e "  [3/6] Verifying Drive connection..."
  if [[ "$DRY_RUN" == "1" ]]; then
    echo -e "        ${YELLOW}[dry-run]${NC} Skipping Drive verification."
  else
    if spin "Verifying Drive connection..." bash -c "rclone lsd '${remote_name}:' &>/dev/null || rclone ls '${remote_name}:' &>/dev/null"; then
      echo -e "        ${GREEN}✓${NC} Connected to Google Drive."
    else
      echo ""
      echo -e "        ${RED}✗${NC} Cannot access Google Drive folder."
      echo ""
      echo -e "        Possible causes:"
      echo -e "          ${DIM}•${NC} The Folder ID is incorrect"
      echo -e "          ${DIM}•${NC} OAuth token expired — try: ${CYAN}rclone config reconnect ${remote_name}:${NC}"
      echo -e "          ${DIM}•${NC} Network issue — check your internet connection"
      echo ""
      echo -e "        Setup aborted. The rclone remote has been removed."
      rclone config delete "$remote_name" 2>/dev/null || true
      return
    fi
  fi

  # [4/6] Initial sync (direction depends on INITIAL_SYNC)
  echo ""
  local rv=""; [[ "$VERBOSE" == "1" ]] && rv="--verbose"

  case "$INITIAL_SYNC" in
    download)
      echo -e "  [4/6] Initial sync: Drive → Local..."
      if [[ "$DRY_RUN" == "1" ]]; then
        echo -e "        ${YELLOW}[dry-run]${NC} Skipping initial download."
      else
        spin "Downloading Drive files..." rclone copy "${remote_name}:" "$local_dir" $rv --stats-one-line -q
        echo -e "        ${GREEN}✓${NC} Drive files downloaded to local."
      fi
      ;;
    upload)
      echo -e "  [4/6] Initial sync: Local → Drive..."
      if [[ "$DRY_RUN" == "1" ]]; then
        echo -e "        ${YELLOW}[dry-run]${NC} Skipping initial upload."
      else
        spin "Uploading local files..." rclone copy "$local_dir" "${remote_name}:" $rv --stats-one-line -q
        echo -e "        ${GREEN}✓${NC} Local files uploaded to Drive."
      fi
      ;;
    merge)
      echo -e "  [4/6] Initial sync: merging both sides..."
      if [[ "$DRY_RUN" == "1" ]]; then
        echo -e "        ${YELLOW}[dry-run]${NC} Skipping initial merge."
      else
        echo -e "        ${DIM}(newer file wins, conflicts get a numeric suffix)${NC}"
      fi
      ;;
  esac

  # [5/6] Bisync baseline
  echo ""
  echo -e "  [5/6] Establishing bisync baseline..."
  if [[ "$DRY_RUN" == "1" ]]; then
    echo -e "        ${YELLOW}[dry-run]${NC} Skipping bisync baseline."
  else
    rm -rf ~/.cache/rclone/bisync/*"${remote_name}"* 2>/dev/null || true
    spin "Establishing bisync baseline..." rclone bisync "$local_dir" "${remote_name}:" --resync \
      --conflict-resolve newer --conflict-loser num \
      $rv --stats-one-line -q
    echo -e "        ${GREEN}✓${NC} Bisync baseline established."
  fi

  # [6/6] Watcher, systemd, cron, config
  echo ""
  echo -e "  [6/6] Setting up watcher, service, and cron..."
  if [[ "$DRY_RUN" == "1" ]]; then
    echo -e "        ${YELLOW}[dry-run]${NC} Would create watcher, systemd service, and cron job."
  else
    # Watcher script
    generate_watcher_script "$remote_name" "$local_dir" "$remote_name" "$log_file" > "$watcher_script"
    chmod +x "$watcher_script"
    echo -e "        ${GREEN}✓${NC} Watcher script created."

    # Systemd service
    $SUDO tee "/etc/systemd/system/${service_name}.service" > /dev/null <<UNIT
[Unit]
Description=Google Drive Sync Watcher — ${remote_name}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${watcher_script}
Restart=on-failure
RestartSec=10
User=${USER}
Environment=HOME=${HOME}
Environment=PATH=/usr/local/bin:/usr/bin:/bin
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=${local_dir} ${HOME}/.config/rclone ${HOME}/.cache/rclone ${HOME}
ProtectHome=false

[Install]
WantedBy=multi-user.target
UNIT
    spin "Reloading systemd..." $SUDO systemctl daemon-reload
    $SUDO systemctl enable "$service_name" &>/dev/null

    if spin "Starting service..." $SUDO systemctl start "$service_name"; then
      echo -e "        ${GREEN}✓${NC} Service '${service_name}' started and enabled."
    else
      echo -e "        ${YELLOW}⚠${NC} Service '${service_name}' failed to start."
      echo -e "          Check: ${CYAN}sudo journalctl -u ${service_name} -n 20${NC}"
    fi

    # Cron job
    local cron_cmd="${cron_schedule} /usr/bin/rclone bisync ${local_dir} ${remote_name}: --conflict-resolve newer --conflict-loser num --resilient --recover --verbose --log-file=${log_file} 2>&1"
    ( crontab -l 2>/dev/null | grep -v "gdrive-sync.*${remote_name}" | grep -v "${remote_name}:" ; echo "$cron_cmd" ) | crontab -
    echo -e "        ${GREEN}✓${NC} Cron job active: ${cron_schedule}"

    # Save config
    save_config "$remote_name" "$remote_name" "$local_dir" "$folder_id" "$cron_schedule" "$client_id" "$client_secret"
    echo -e "        ${GREEN}✓${NC} Config saved."
  fi

  # ── Final status ─────────────────────────────────────────────────
  echo ""
  echo ""
  echo -e "  ${BOLD}${BLUE}══════════════════════════════════════${NC}"
  echo ""

  if [[ "$DRY_RUN" == "1" ]]; then
    echo -e "  ${BOLD}${YELLOW}DRY RUN COMPLETE${NC} — nothing was written."
    echo -e "  Re-run without --dry-run to apply."
  else
    local all_ok=true
    systemctl is-active --quiet "$service_name" 2>/dev/null || all_ok=false
    crontab -l 2>/dev/null | grep -q "${remote_name}:" || all_ok=false

    if $all_ok; then
      echo -e "  ${BOLD}${GREEN}✓ Setup complete! '${remote_name}' is now syncing.${NC}"
    else
      echo -e "  ${BOLD}${YELLOW}⚠ Setup finished with warnings — sync may not be running.${NC}"
    fi
    echo ""
    echo -e "    Monitor : tail -f ${log_file}"
    echo -e "    Status  : ${SUDO:+sudo }systemctl status ${service_name}"
  fi

  echo ""
  echo -e "  ${BOLD}${BLUE}══════════════════════════════════════${NC}"
  echo ""
}

action_list() {
  header "Sync Configurations"
  local configs; mapfile -t configs < <(list_config_names)
  if [[ ${#configs[@]} -eq 0 ]]; then warn "No configurations found."; return; fi

  printf "\n  %-16s %-35s %-22s %s\n" "NAME" "LOCAL FOLDER" "DRIVE FOLDER ID" "CRON"
  echo "  $(printf '─%.0s' {1..95})"
  for name in "${configs[@]}"; do
    if load_config "$name"; then
      printf "  %-16s %-35s %-22s %s\n" "$REMOTE_NAME" "${LOCAL_DIR:0:33}" "${FOLDER_ID:0:20}..." "$CRON_SCHEDULE"
    fi
  done
  echo ""
}

action_status() {
  header "Sync Status"
  local configs; mapfile -t configs < <(list_config_names)
  if [[ ${#configs[@]} -eq 0 ]]; then warn "No configurations found."; return; fi

  for name in "${configs[@]}"; do
    load_config "$name" || continue
    echo ""
    echo -e "  ${BOLD}$name${NC}"

    systemctl is-active --quiet "gdrive-sync-${name}" 2>/dev/null \
      && echo -e "    Watcher : ${GREEN}● RUNNING${NC}" \
      || echo -e "    Watcher : ${RED}● STOPPED${NC}"

    crontab -l 2>/dev/null | grep -q "${REMOTE_NAME}:" \
      && echo -e "    Cron    : ${GREEN}● ACTIVE${NC} ($CRON_SCHEDULE)" \
      || echo -e "    Cron    : ${RED}● NOT FOUND${NC}"

    local log_file="$HOME/gdrive-sync-${name}.log"
    if [[ -f "$log_file" ]]; then
      local last_line; last_line=$(grep -a '.' "$log_file" 2>/dev/null | tail -1 | head -c 80)
      [[ -n "$last_line" ]] \
        && echo -e "    Last log: ${DIM}${last_line}${NC}" \
        || echo -e "    Last log: ${DIM}(empty)${NC}"
    fi

    spin "Checking Drive..." rclone lsd "${REMOTE_NAME}:" --max-depth 0 \
      && echo -e "    Drive   : ${GREEN}● OK${NC}" \
      || echo -e "    Drive   : ${RED}● UNREACHABLE${NC}"

    if [[ "$VERBOSE" == "1" ]]; then
      echo -e "    Local   : $LOCAL_DIR"
      echo -e "    Folder  : $FOLDER_ID"
      [[ -f "$log_file" ]] && echo -e "    Log size: $(du -h "$log_file" 2>/dev/null | cut -f1)"
    fi
  done
  echo ""
}

action_edit() {
  header "Edit Configuration"
  select_config || return
  local name="$SELECTED"
  load_config "$name" || { err "Cannot load config."; return; }

  echo ""
  echo "  Current: folder=$FOLDER_ID  cron=$CRON_SCHEDULE"
  echo "  1) Drive Folder ID  2) Cron schedule  3) Both"
  local ec; read -rp "  Choice [1]: " ec

  local new_folder="$FOLDER_ID" new_cron="$CRON_SCHEDULE"

  case "${ec:-1}" in
    1|3)
      read -rp "  New Drive Folder ID: " new_folder
      [[ -z "$new_folder" ]] && new_folder="$FOLDER_ID"
      if [[ "$new_folder" != "$FOLDER_ID" ]]; then
        if grep -q "root_folder_id" "$RCLONE_CONF" 2>/dev/null; then
          sed -i "/^\[${REMOTE_NAME}\]/,/^\[/{s/root_folder_id = .*/root_folder_id = ${new_folder}/}" "$RCLONE_CONF"
        else
          sed -i "/^\[${REMOTE_NAME}\]/a root_folder_id = ${new_folder}" "$RCLONE_CONF"
        fi
        rm -rf ~/.cache/rclone/bisync/*"${REMOTE_NAME}"* 2>/dev/null || true
        success "Folder ID updated. Run manual sync (option 7) to re-baseline."
      fi
      ;;&
    2|3)
      echo "  1) */5  2) */10  3) */15  4) */1  5) Custom"
      local cc; read -rp "  Choice [1]: " cc
      case "${cc:-1}" in
        1) new_cron="*/5 * * * *" ;; 2) new_cron="*/10 * * * *" ;;
        3) new_cron="*/15 * * * *" ;; 4) new_cron="* * * * *" ;;
        5) read -rp "  Cron: " new_cron ;;
      esac
      if [[ "$new_cron" != "$CRON_SCHEDULE" ]]; then
        local old_cmd; old_cmd=$(crontab -l 2>/dev/null | grep "${REMOTE_NAME}:" | sed 's/^[^ ]* [^ ]* [^ ]* [^ ]* [^ ]* //')
        if [[ -n "$old_cmd" ]]; then
          ( crontab -l 2>/dev/null | grep -v "${REMOTE_NAME}:" ; echo "$new_cron $old_cmd" ) | crontab -
          success "Cron updated to: $new_cron"
        else warn "Existing cron entry not found."; fi
      fi
      ;;
  esac
  save_config "$name" "$REMOTE_NAME" "$LOCAL_DIR" "$new_folder" "$new_cron" "${CLIENT_ID:-}" "${CLIENT_SECRET:-}"
  success "Configuration saved."
}

action_remove() {
  header "Remove Sync Configuration"
  select_config || return
  local name="$SELECTED"
  load_config "$name" || { err "Cannot load config."; return; }

  local service="gdrive-sync-${name}" log_file="$HOME/gdrive-sync-${name}.log"

  echo ""
  warn "This will remove: service, cron, watcher, rclone remote, config for '${name}'"
  [[ -n "$SUDO" ]] && info "Stopping the systemd service requires sudo."
  echo ""
  echo "  1) Keep local folder and log (default)  2) Delete log only  3) Delete log + local folder"
  local fc; read -rp "  Choice [1]: " fc

  confirm "Confirm removal of '${name}'?" || { info "Aborted."; return; }

  $SUDO systemctl stop "$service" 2>/dev/null || true
  $SUDO systemctl disable "$service" 2>/dev/null || true
  $SUDO rm -f "/etc/systemd/system/${service}.service"
  $SUDO systemctl daemon-reload
  success "Service removed."

  ( crontab -l 2>/dev/null | grep -v "${REMOTE_NAME}:" ) | crontab -
  success "Cron removed."

  rm -f "${SYNC_DIR}/${name}-watcher.sh"
  success "Watcher removed."

  rclone config delete "$REMOTE_NAME" 2>/dev/null || true
  success "rclone remote removed."

  rm -rf ~/.cache/rclone/bisync/*"${REMOTE_NAME}"* 2>/dev/null || true
  rm -f "${SYNC_DIR}/${name}.env"
  success "Config removed."

  case "${fc:-1}" in
    2) rm -f "$log_file" "${log_file}.old"; success "Log deleted." ;;
    3) rm -f "$log_file" "${log_file}.old"; success "Log deleted."
       [[ -n "$LOCAL_DIR" && -d "$LOCAL_DIR" ]] && confirm "  Delete '$LOCAL_DIR'?" && { rm -rf "$LOCAL_DIR"; success "Local folder deleted."; } ;;
  esac
  echo ""; success "'${name}' fully removed."
}

action_logs() {
  header "View Logs"
  select_config || return
  local log_file="$HOME/gdrive-sync-${SELECTED}.log"
  [[ -f "$log_file" ]] || { warn "Log not found: $log_file"; return; }

  local log_size; log_size=$(du -h "$log_file" 2>/dev/null | cut -f1)
  local log_total; log_total=$(wc -l < "$log_file" 2>/dev/null)

  echo ""
  echo "  Log: $log_file ($log_size, ${log_total} lines)"
  echo ""
  echo "  1) Last ${LOG_LINES} lines (default)"
  echo "  2) Follow (tail -f)"
  echo "  3) Full log (cat)"
  echo "  4) Custom number of lines"
  echo "  5) Search (grep)"

  local lc; read -rp "  Choice [1]: " lc
  case "${lc:-1}" in
    1) echo ""; tail -n "$LOG_LINES" "$log_file" ;;
    2) info "Following — Ctrl+C to stop"; tail -f "$log_file" ;;
    3) echo ""; cat "$log_file" ;;
    4) local n; read -rp "  Lines: " n; [[ "$n" =~ ^[0-9]+$ ]] && { echo ""; tail -n "$n" "$log_file"; } || warn "Invalid." ;;
    5) local pat; read -rp "  Pattern: " pat; [[ -n "$pat" ]] && { echo ""; grep --color=auto -i "$pat" "$log_file" | tail -n "$LOG_LINES" || warn "No matches."; } || warn "Empty." ;;
    *) warn "Invalid." ;;
  esac
}

action_manual_sync() {
  header "Manual Sync"
  select_config || return
  load_config "$SELECTED" || { err "Cannot load config."; return; }

  info "Running bisync: $LOCAL_DIR <-> ${REMOTE_NAME}:"
  echo ""

  local rv=""; [[ "$VERBOSE" == "1" ]] && rv="--verbose"
  rclone bisync "$LOCAL_DIR" "${REMOTE_NAME}:" \
    $rv --progress --conflict-resolve newer --conflict-loser num --resilient --recover

  local rc=$?; echo ""
  if [[ $rc -eq 0 ]]; then
    success "Manual sync complete."
  else
    err "Sync exited with code $rc."
    if [[ $rc -eq 2 ]]; then
      warn "Bisync tracking files are out of date."
      if confirm "Run --resync to re-establish baseline?"; then
        rm -rf ~/.cache/rclone/bisync/*"${REMOTE_NAME}"* 2>/dev/null || true
        rclone bisync "$LOCAL_DIR" "${REMOTE_NAME}:" --resync --verbose --progress
        success "Resync complete."
      fi
    fi
  fi
}

action_test_drive() {
  local name="${1:-}"
  if [[ -z "$name" ]]; then
    header "Test Google Drive Connection"
    select_config || return
    name="$SELECTED"
  fi

  load_config "$name" || { err "Cannot load config '$name'."; return 1; }
  echo ""
  info "Testing Drive connection for '${name}'..."
  echo ""

  local all_ok=true

  # rclone present?
  command -v rclone &>/dev/null \
    && success "rclone: $(rclone version 2>/dev/null | head -1)" \
    || { err "rclone not installed."; return 1; }

  # Remote configured?
  rclone listremotes 2>/dev/null | grep -q "^${REMOTE_NAME}:$" \
    && success "Remote '${REMOTE_NAME}' exists." \
    || { err "Remote '${REMOTE_NAME}' not found."; return 1; }

  # Auth + list
  local list_out list_tmp; list_tmp=$(mktemp)
  if spin "Checking authentication..." bash -c "rclone lsd '${REMOTE_NAME}:' >'$list_tmp' 2>&1"; then
    list_out=$(<"$list_tmp"); rm -f "$list_tmp"
    success "Authentication OK — folder is accessible."
    if [[ "$VERBOSE" == "1" && -n "$list_out" ]]; then
      echo -e "  ${DIM}Subdirectories:${NC}"
      echo "$list_out" | head -10 | sed 's/^/    /'
    fi
  elif spin "Trying file listing..." rclone ls "${REMOTE_NAME}:" --max-depth 1; then
    rm -f "$list_tmp"
    success "Authentication OK — folder has files (no subdirs)."
  else
    rm -f "$list_tmp"
    err "Cannot access Drive folder. Token may be expired."
    echo -e "  ${DIM}Try: rclone config reconnect ${REMOTE_NAME}:${NC}"
    all_ok=false
  fi

  # Write test
  local tf="/tmp/gdrive-sync-writetest-$$.txt"
  echo "gdrive-sync write test $(date -Iseconds)" > "$tf"
  if spin "Testing write access..." rclone copyto "$tf" "${REMOTE_NAME}:.gdrive-sync-test"; then
    success "Write access OK."
    spin "Cleaning up test file..." rclone deletefile "${REMOTE_NAME}:.gdrive-sync-test"
  else
    warn "Write test failed — folder may be read-only."
    all_ok=false
  fi
  rm -f "$tf"

  # Verbose: quota
  if [[ "$VERBOSE" == "1" ]]; then
    info "Drive usage:"
    rclone about "${REMOTE_NAME}:" 2>/dev/null | sed 's/^/    /' || debug "About not available."
  fi

  echo ""
  $all_ok && echo -e "  ${BOLD}${GREEN}✓ Drive connection for '${name}' is healthy.${NC}" \
          || echo -e "  ${BOLD}${YELLOW}⚠ Some checks failed.${NC}"
  echo ""
}

action_settings() {
  header "Global Settings"
  echo ""
  echo "  File: $SETTINGS_FILE"
  echo ""
  echo "  DEBOUNCE_SEC       = $DEBOUNCE_SEC"
  echo "  LOG_MAX_SIZE_MB    = $LOG_MAX_SIZE_MB"
  echo "  MIN_RCLONE_VERSION = $MIN_RCLONE_VERSION"
  echo "  DEFAULT_CRON       = $DEFAULT_CRON"
  echo "  LOG_LINES          = $LOG_LINES"
  echo ""
  echo "  1) Edit a setting  2) Reset to defaults  3) Back"
  local sc; read -rp "  Choice [3]: " sc

  case "${sc:-3}" in
    1)
      echo "  1) DEBOUNCE_SEC  2) LOG_MAX_SIZE_MB  3) DEFAULT_CRON  4) LOG_LINES"
      local wc; read -rp "  Setting: " wc
      local nv
      case "$wc" in
        1) read -rp "  DEBOUNCE_SEC [$DEBOUNCE_SEC]: " nv; [[ "$nv" =~ ^[0-9]+$ ]] && DEBOUNCE_SEC="$nv" ;;
        2) read -rp "  LOG_MAX_SIZE_MB [$LOG_MAX_SIZE_MB]: " nv; [[ "$nv" =~ ^[0-9]+$ ]] && LOG_MAX_SIZE_MB="$nv" ;;
        3) read -rp "  DEFAULT_CRON [$DEFAULT_CRON]: " nv; [[ -n "$nv" ]] && DEFAULT_CRON="$nv" ;;
        4) read -rp "  LOG_LINES [$LOG_LINES]: " nv; [[ "$nv" =~ ^[0-9]+$ ]] && LOG_LINES="$nv" ;;
        *) warn "Invalid."; return ;;
      esac
      save_settings; success "Saved."
      ;;
    2) DEBOUNCE_SEC=5; LOG_MAX_SIZE_MB=50; MIN_RCLONE_VERSION="1.62.0"
       DEFAULT_CRON="*/5 * * * *"; LOG_LINES=50; save_settings; success "Reset to defaults." ;;
  esac
}

action_run_tests() {
  local test_script
  test_script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/tests/test-gdrive-sync.sh"

  if [[ ! -f "$test_script" ]]; then
    err "Test script not found: $test_script"
    info "Ensure the tests/ directory is next to gdrive-sync.sh"
    return 1
  fi

  local flags=""; [[ "$VERBOSE" == "1" ]] && flags="-v"
  bash "$test_script" $flags
}

# ===================================================================
#  BELOW THIS POINT: only runs when executed, not sourced for tests
# ===================================================================

if [[ "${GDRIVE_SYNC_TESTING:-}" == "1" ]]; then
  return 0 2>/dev/null || true
fi

case "$CLI_ACTION" in
  status)     action_status; exit 0 ;;
  test)       action_run_tests; exit $? ;;
  test-drive) action_test_drive "$CLI_ARG"; exit $? ;;
esac

# ===================================================================
#  MAIN MENU
# ===================================================================

show_banner() {
  clear
  echo -e "${BOLD}${BLUE}"
  echo "  ┌─────────────────────────────────────────────┐"
  echo "  │   Google Drive Sync Manager  v${VERSION}        │"
  echo "  │   rclone bisync + inotify-tools             │"
  echo "  └─────────────────────────────────────────────┘"
  echo -e "${NC}"

  [[ "$DRY_RUN" == "1" ]] && echo -e "  ${YELLOW}⚠  DRY RUN MODE${NC}\n"
  [[ "$VERBOSE" == "1" ]] && echo -e "  ${DIM}verbose mode${NC}\n"

  local configs; mapfile -t configs < <(list_config_names)
  if [[ ${#configs[@]} -gt 0 ]]; then
    echo -e "  ${BOLD}Active syncs:${NC}"
    for name in "${configs[@]}"; do
      systemctl is-active --quiet "gdrive-sync-${name}" 2>/dev/null \
        && echo -e "    ${GREEN}●${NC} $name" \
        || echo -e "    ${RED}●${NC} $name"
    done
    echo ""
  else
    echo -e "  ${DIM}No syncs configured yet.${NC}\n"
  fi
}

while true; do
  show_banner

  echo -e "  ${BOLD}Menu${NC}"
  echo "     1) Add new sync          2) List configurations"
  echo "     3) Show status            4) Edit a configuration"
  echo "     5) Remove a configuration 6) View logs"
  echo "     7) Manual sync now        8) Test Drive connection"
  echo "     9) Settings              10) Run tests"
  echo "     0) Exit"
  echo ""
  read -rp "  Choice [0]: " menu_choice

  case "${menu_choice:-0}" in
    1)  action_add; pause ;;
    2)  action_list; pause ;;
    3)  action_status; pause ;;
    4)  action_edit; pause ;;
    5)  action_remove; pause ;;
    6)  action_logs; pause ;;
    7)  action_manual_sync; pause ;;
    8)  action_test_drive; pause ;;
    9)  action_settings; pause ;;
    10) action_run_tests; pause ;;
    0)  echo ""; info "Goodbye!"; exit 0 ;;
    *)  warn "Invalid choice."; sleep 1 ;;
  esac
done
