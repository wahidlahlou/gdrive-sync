#!/usr/bin/env bash

# ============================================================
#  tests/test-gdrive-sync.sh
#  Test suite for gdrive-sync.sh
#
#  Run:  bash tests/test-gdrive-sync.sh
#        bash tests/test-gdrive-sync.sh -v          (verbose)
#        bash tests/test-gdrive-sync.sh test_name    (single test)
#
#  Tests are self-contained — they create temp directories,
#  mock external commands, and clean up after themselves.
#  No Google account or network access required.
# ============================================================

set -o pipefail

# ----- Test framework ------------------------------------------------------
PASS=0
FAIL=0
SKIP=0
ERRORS=()
VERBOSE="${VERBOSE:-0}"
[[ "${1:-}" == "-v" ]] && { VERBOSE=1; shift; }
FILTER="${1:-}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# Temp workspace — cleaned up on exit
TEST_TMPDIR=""

setup_tmpdir() {
  TEST_TMPDIR="$(mktemp -d /tmp/gdrive-sync-test.XXXXXX)"
  export GDRIVE_SYNC_DIR="${TEST_TMPDIR}/config"
  export RCLONE_CONF="${TEST_TMPDIR}/rclone.conf"
  export HOME="${TEST_TMPDIR}/fakehome"
  mkdir -p "$GDRIVE_SYNC_DIR" "$HOME/.config/rclone" "$HOME/.cache/rclone/bisync"
  touch "$RCLONE_CONF"
}

teardown_tmpdir() {
  [[ -n "$TEST_TMPDIR" && -d "$TEST_TMPDIR" ]] && rm -rf "$TEST_TMPDIR"
}

# Source the script in test mode
source_script() {
  export GDRIVE_SYNC_TESTING=1
  # shellcheck source=/dev/null
  source "$(script_path)"
}

script_path() {
  local dir
  dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  echo "${dir}/gdrive-sync.sh"
}

run_test() {
  local name="$1"
  # Filter support
  [[ -n "$FILTER" && "$name" != *"$FILTER"* ]] && return

  setup_tmpdir

  local output rc
  output=$( "$name" 2>&1 )
  rc=$?

  teardown_tmpdir

  if [[ $rc -eq 0 ]]; then
    ((PASS++))
    echo -e "  ${GREEN}✓${NC} $name"
    [[ "$VERBOSE" == "1" && -n "$output" ]] && echo -e "    ${DIM}${output}${NC}"
  elif [[ $rc -eq 77 ]]; then
    ((SKIP++))
    echo -e "  ${YELLOW}○${NC} $name ${DIM}(skipped)${NC}"
  else
    ((FAIL++))
    ERRORS+=("$name")
    echo -e "  ${RED}✗${NC} $name"
    echo -e "    ${DIM}${output}${NC}"
  fi
}

assert_eq() {
  local expected="$1" actual="$2" msg="${3:-}"
  if [[ "$expected" != "$actual" ]]; then
    echo "ASSERT FAILED${msg:+: $msg}"
    echo "  expected: '$expected'"
    echo "  actual:   '$actual'"
    return 1
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" msg="${3:-}"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo "ASSERT FAILED${msg:+: $msg}"
    echo "  expected to contain: '$needle'"
    echo "  in: '${haystack:0:200}'"
    return 1
  fi
}

assert_not_contains() {
  local haystack="$1" needle="$2" msg="${3:-}"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo "ASSERT FAILED${msg:+: $msg}"
    echo "  expected NOT to contain: '$needle'"
    echo "  in: '${haystack:0:200}'"
    return 1
  fi
}

assert_file_exists() {
  local path="$1" msg="${2:-}"
  if [[ ! -f "$path" ]]; then
    echo "ASSERT FAILED${msg:+: $msg}"
    echo "  file does not exist: '$path'"
    return 1
  fi
}

assert_file_not_exists() {
  local path="$1" msg="${2:-}"
  if [[ -f "$path" ]]; then
    echo "ASSERT FAILED${msg:+: $msg}"
    echo "  file should not exist: '$path'"
    return 1
  fi
}

assert_exit_code() {
  local expected="$1" actual="$2" msg="${3:-}"
  if [[ "$expected" != "$actual" ]]; then
    echo "ASSERT FAILED${msg:+: $msg}"
    echo "  expected exit code: $expected"
    echo "  actual exit code:   $actual"
    return 1
  fi
}

# ===================================================================
#  TESTS: version_gte (semantic version comparison)
# ===================================================================

test_version_gte_equal() {
  source_script
  version_gte "1.62.0" "1.62.0"
  assert_exit_code 0 $? "equal versions should pass"
}

test_version_gte_newer_patch() {
  source_script
  version_gte "1.62.5" "1.62.0"
  assert_exit_code 0 $? "newer patch should pass"
}

test_version_gte_newer_minor() {
  source_script
  version_gte "1.65.0" "1.62.0"
  assert_exit_code 0 $? "newer minor should pass"
}

test_version_gte_newer_major() {
  source_script
  version_gte "2.0.0" "1.62.0"
  assert_exit_code 0 $? "newer major should pass"
}

test_version_gte_older_patch() {
  source_script
  version_gte "1.61.9" "1.62.0"
  local rc=$?
  assert_exit_code 1 $rc "older patch should fail"
}

test_version_gte_older_minor() {
  source_script
  version_gte "1.50.0" "1.62.0"
  local rc=$?
  assert_exit_code 1 $rc "older minor should fail"
}

test_version_gte_older_major() {
  source_script
  version_gte "0.99.0" "1.62.0"
  local rc=$?
  assert_exit_code 1 $rc "older major should fail"
}

# ===================================================================
#  TESTS: save_config / load_config
# ===================================================================

test_save_config_creates_file() {
  source_script
  save_config "myremote" "myremote" "/home/user/docs" "abc123" "*/5 * * * *"

  assert_file_exists "${GDRIVE_SYNC_DIR}/myremote.env" "config file should exist"
}

test_save_config_contents() {
  source_script
  save_config "test-sync" "test-sync" "/tmp/test-dir" "folder123xyz" "*/10 * * * *"

  local content
  content=$(cat "${GDRIVE_SYNC_DIR}/test-sync.env")

  assert_contains "$content" 'REMOTE_NAME="test-sync"' "should contain remote name"
  assert_contains "$content" 'LOCAL_DIR="/tmp/test-dir"' "should contain local dir"
  assert_contains "$content" 'FOLDER_ID="folder123xyz"' "should contain folder id"
  assert_contains "$content" 'CRON_SCHEDULE="*/10 * * * *"' "should contain cron schedule"
  assert_contains "$content" "CREATED=" "should contain timestamp"
}

test_load_config_sets_variables() {
  source_script
  save_config "loadtest" "loadtest" "/opt/sync" "xyz789" "*/5 * * * *"

  # Clear any existing vars
  unset REMOTE_NAME LOCAL_DIR FOLDER_ID CRON_SCHEDULE

  load_config "loadtest"

  assert_eq "loadtest" "$REMOTE_NAME" "REMOTE_NAME"
  assert_eq "/opt/sync" "$LOCAL_DIR" "LOCAL_DIR"
  assert_eq "xyz789" "$FOLDER_ID" "FOLDER_ID"
  assert_eq "*/5 * * * *" "$CRON_SCHEDULE" "CRON_SCHEDULE"
}

test_load_config_nonexistent_fails() {
  source_script
  load_config "does-not-exist"
  local rc=$?
  assert_exit_code 1 $rc "loading nonexistent config should return 1"
}

test_save_config_overwrites() {
  source_script
  save_config "over" "over" "/dir1" "id1" "*/5 * * * *"
  save_config "over" "over" "/dir2" "id2" "*/10 * * * *"

  load_config "over"

  assert_eq "/dir2" "$LOCAL_DIR" "should have overwritten LOCAL_DIR"
  assert_eq "id2" "$FOLDER_ID" "should have overwritten FOLDER_ID"
}

# ===================================================================
#  TESTS: list_config_names
# ===================================================================

test_list_config_names_empty() {
  source_script
  local result
  result=$(list_config_names)
  assert_eq "" "$result" "empty dir should list nothing"
}

test_list_config_names_multiple() {
  source_script
  save_config "alpha" "alpha" "/a" "id1" "*/5 * * * *"
  save_config "beta" "beta" "/b" "id2" "*/5 * * * *"
  save_config "gamma" "gamma" "/c" "id3" "*/5 * * * *"

  local result
  result=$(list_config_names)
  local count
  count=$(echo "$result" | wc -l)

  assert_eq "3" "$count" "should list 3 configs"
  assert_contains "$result" "alpha"
  assert_contains "$result" "beta"
  assert_contains "$result" "gamma"
}

test_list_config_names_ignores_non_env() {
  source_script
  save_config "real" "real" "/r" "id1" "*/5 * * * *"
  touch "${GDRIVE_SYNC_DIR}/notes.txt"
  touch "${GDRIVE_SYNC_DIR}/watcher.sh"

  local result
  result=$(list_config_names)
  local count
  count=$(echo "$result" | wc -l)

  assert_eq "1" "$count" "should only list .env files"
  assert_eq "real" "$result"
}

# ===================================================================
#  TESTS: generate_watcher_script
# ===================================================================

test_watcher_script_contains_debounce() {
  source_script
  local output
  output=$(generate_watcher_script "test" "/home/user/sync" "myremote" "/home/user/test.log")

  assert_contains "$output" "DEBOUNCE=" "should set DEBOUNCE"
  assert_contains "$output" "sleep \$DEBOUNCE" "should sleep for debounce"
}

test_watcher_script_contains_lock() {
  source_script
  local output
  output=$(generate_watcher_script "test" "/home/user/sync" "myremote" "/home/user/test.log")

  assert_contains "$output" "LOCK_FILE=" "should define lock file"
  assert_contains "$output" "gdrive-sync-test.lock" "lock file should be per-remote"
  assert_contains "$output" "lock_age" "should check lock age"
}

test_watcher_script_contains_conflict_resolution() {
  source_script
  local output
  output=$(generate_watcher_script "test" "/home/user/sync" "myremote" "/home/user/test.log")

  assert_contains "$output" "--conflict-resolve newer" "should resolve conflicts by newer"
  assert_contains "$output" "--conflict-loser num" "should rename losers"
}

test_watcher_script_contains_log_rotation() {
  source_script
  local output
  output=$(generate_watcher_script "test" "/tmp/sync" "remote" "/tmp/test.log")

  assert_contains "$output" "rotate_log" "should call rotate_log"
  assert_contains "$output" "LOG_MAX_MB=" "should set log max size"
}

test_watcher_script_is_valid_bash() {
  source_script
  local script_file="${TEST_TMPDIR}/test-watcher.sh"
  generate_watcher_script "test" "/tmp/sync" "remote" "/tmp/test.log" > "$script_file"

  bash -n "$script_file"
  assert_exit_code 0 $? "generated watcher should be valid bash"
}

test_watcher_script_uses_correct_paths() {
  source_script
  local output
  output=$(generate_watcher_script "myname" "/opt/data/sync" "gdrive-work" "/var/log/test.log")

  assert_contains "$output" 'LOCAL_DIR="/opt/data/sync"' "should use provided local dir"
  assert_contains "$output" 'REMOTE="gdrive-work:"' "should use provided remote with colon"
  assert_contains "$output" 'LOG_FILE="/var/log/test.log"' "should use provided log file"
}

test_watcher_script_has_resilient_flag() {
  source_script
  local output
  output=$(generate_watcher_script "test" "/tmp/sync" "remote" "/tmp/test.log")

  assert_contains "$output" "--resilient" "should use --resilient"
  assert_contains "$output" "--recover" "should use --recover"
}

test_watcher_script_stale_lock_timeout() {
  source_script
  local output
  output=$(generate_watcher_script "test" "/tmp/sync" "remote" "/tmp/test.log")

  assert_contains "$output" "300" "should have 5-minute stale lock timeout"
}

# ===================================================================
#  TESTS: config file isolation
# ===================================================================

test_configs_are_isolated() {
  source_script
  save_config "sync-a" "sync-a" "/dir-a" "id-a" "*/5 * * * *"
  save_config "sync-b" "sync-b" "/dir-b" "id-b" "*/10 * * * *"

  load_config "sync-a"
  assert_eq "/dir-a" "$LOCAL_DIR" "sync-a LOCAL_DIR"
  assert_eq "id-a" "$FOLDER_ID" "sync-a FOLDER_ID"

  load_config "sync-b"
  assert_eq "/dir-b" "$LOCAL_DIR" "sync-b LOCAL_DIR"
  assert_eq "id-b" "$FOLDER_ID" "sync-b FOLDER_ID"
}

# ===================================================================
#  TESTS: config names with special characters
# ===================================================================

test_config_name_with_hyphens() {
  source_script
  save_config "my-drive-sync" "my-drive-sync" "/tmp/test" "abc" "*/5 * * * *"

  assert_file_exists "${GDRIVE_SYNC_DIR}/my-drive-sync.env"

  load_config "my-drive-sync"
  assert_eq "my-drive-sync" "$REMOTE_NAME"
}

test_config_name_with_underscores() {
  source_script
  save_config "my_drive" "my_drive" "/tmp/test" "abc" "*/5 * * * *"

  assert_file_exists "${GDRIVE_SYNC_DIR}/my_drive.env"

  load_config "my_drive"
  assert_eq "my_drive" "$REMOTE_NAME"
}

# ===================================================================
#  TESTS: folder ID with real-world formats
# ===================================================================

test_long_folder_id() {
  source_script
  local long_id="1aBcDeFgHiJkLmNoPqRsTuVwXyZ0123456789_AB"
  save_config "longid" "longid" "/tmp/test" "$long_id" "*/5 * * * *"

  load_config "longid"
  assert_eq "$long_id" "$FOLDER_ID" "should preserve full folder ID"
}

# ===================================================================
#  TESTS: cron schedule formats
# ===================================================================

test_cron_with_every_5_min() {
  source_script
  save_config "cron5" "cron5" "/tmp" "id" "*/5 * * * *"
  load_config "cron5"
  assert_eq "*/5 * * * *" "$CRON_SCHEDULE"
}

test_cron_with_every_1_min() {
  source_script
  save_config "cron1" "cron1" "/tmp" "id" "* * * * *"
  load_config "cron1"
  assert_eq "* * * * *" "$CRON_SCHEDULE"
}

test_cron_with_custom_schedule() {
  source_script
  save_config "cronc" "cronc" "/tmp" "id" "0 */2 * * 1-5"
  load_config "cronc"
  assert_eq "0 */2 * * 1-5" "$CRON_SCHEDULE"
}

# ===================================================================
#  TESTS: VERSION constant
# ===================================================================

test_version_is_set() {
  source_script
  assert_contains "$VERSION" "." "VERSION should contain a dot (semver)"
}

test_version_flag_output() {
  local output
  output=$(GDRIVE_SYNC_TESTING=1 bash "$(script_path)" --version 2>&1)
  assert_contains "$output" "gdrive-sync" "should print tool name"
  assert_contains "$output" "." "should contain version number"
}

# ===================================================================
#  TESTS: help flag
# ===================================================================

test_help_flag() {
  local output
  output=$(GDRIVE_SYNC_TESTING=1 bash "$(script_path)" --help 2>&1)
  local rc=$?
  assert_exit_code 0 $rc "help should exit 0"
  assert_contains "$output" "USAGE" "help should show USAGE"
  assert_contains "$output" "Add new sync" "help should describe menu options"
  assert_contains "$output" "MENU OPTIONS" "help should list menu options"
}

# ===================================================================
#  TESTS: helper functions
# ===================================================================

test_info_output() {
  source_script
  local output
  output=$(info "hello world")
  assert_contains "$output" "INFO" "info should contain INFO tag"
  assert_contains "$output" "hello world" "info should contain message"
}

test_success_output() {
  source_script
  local output
  output=$(success "done")
  assert_contains "$output" "OK" "success should contain OK tag"
  assert_contains "$output" "done" "success should contain message"
}

test_warn_output() {
  source_script
  local output
  output=$(warn "careful")
  assert_contains "$output" "WARN" "warn should contain WARN tag"
  assert_contains "$output" "careful" "warn should contain message"
}

test_err_output() {
  source_script
  local output
  output=$(err "bad" 2>&1)
  assert_contains "$output" "ERR" "err should contain ERR tag"
  assert_contains "$output" "bad" "err should contain message"
}

# ===================================================================
#  TESTS: watcher script — multiple remotes don't collide
# ===================================================================

test_watcher_scripts_independent_locks() {
  source_script

  local watcher_a watcher_b
  watcher_a=$(generate_watcher_script "alpha" "/a" "remote-a" "/tmp/a.log")
  watcher_b=$(generate_watcher_script "beta" "/b" "remote-b" "/tmp/b.log")

  assert_contains "$watcher_a" "gdrive-sync-alpha.lock" "alpha should have its own lock"
  assert_contains "$watcher_b" "gdrive-sync-beta.lock" "beta should have its own lock"
  assert_not_contains "$watcher_a" "gdrive-sync-beta.lock" "alpha should not reference beta lock"
}

# ===================================================================
#  TESTS: SYNC_DIR and RCLONE_CONF env overrides
# ===================================================================

test_sync_dir_override() {
  local custom_dir="${TEST_TMPDIR}/custom-config"
  mkdir -p "$custom_dir"
  export GDRIVE_SYNC_DIR="$custom_dir"

  source_script
  save_config "envtest" "envtest" "/tmp" "id" "*/5 * * * *"

  assert_file_exists "${custom_dir}/envtest.env" "should respect GDRIVE_SYNC_DIR override"
}

# ===================================================================
#  TESTS: watcher script — generated script handles edge cases
# ===================================================================

test_watcher_handles_spaces_in_paths() {
  source_script
  local output
  output=$(generate_watcher_script "spacey" "/home/user/my documents/sync folder" "remote" "/home/user/my logs/sync.log")

  assert_contains "$output" '/home/user/my documents/sync folder' "should preserve path with spaces"
  assert_contains "$output" '/home/user/my logs/sync.log' "should preserve log path with spaces"

  # Save to file and syntax-check
  local script_file="${TEST_TMPDIR}/spacey-watcher.sh"
  echo "$output" > "$script_file"
  bash -n "$script_file"
  assert_exit_code 0 $? "watcher with spaces should be valid bash"
}

# ===================================================================
#  TESTS: list after remove simulates full lifecycle
# ===================================================================

test_config_lifecycle_add_list_remove() {
  source_script

  # Add
  save_config "lifecycle" "lifecycle" "/tmp/lc" "lcid" "*/5 * * * *"

  local names
  names=$(list_config_names)
  assert_contains "$names" "lifecycle" "should be listed after add"

  # Remove
  rm -f "${GDRIVE_SYNC_DIR}/lifecycle.env"

  names=$(list_config_names)
  assert_not_contains "$names" "lifecycle" "should not be listed after remove"
}

# ===================================================================
#  TESTS: config does not leak between loads
# ===================================================================

test_load_config_replaces_previous() {
  source_script

  save_config "first" "first" "/path/first" "id-first" "*/5 * * * *"
  save_config "second" "second" "/path/second" "id-second" "*/10 * * * *"

  load_config "first"
  assert_eq "id-first" "$FOLDER_ID"

  load_config "second"
  assert_eq "id-second" "$FOLDER_ID"
  assert_eq "/path/second" "$LOCAL_DIR"
  # Verify first config values are gone
  assert_eq "second" "$REMOTE_NAME"
}

# ===================================================================
#  TESTS: settings.conf
# ===================================================================

test_settings_file_created_on_source() {
  source_script
  assert_file_exists "$SETTINGS_FILE" "settings.conf should be auto-created"
}

test_settings_default_values() {
  source_script
  assert_eq "5" "$DEBOUNCE_SEC" "default DEBOUNCE_SEC"
  assert_eq "50" "$LOG_MAX_SIZE_MB" "default LOG_MAX_SIZE_MB"
  assert_eq "*/5 * * * *" "$DEFAULT_CRON" "default DEFAULT_CRON"
  assert_eq "50" "$LOG_LINES" "default LOG_LINES"
}

test_settings_save_and_reload() {
  source_script
  DEBOUNCE_SEC=10
  LOG_LINES=100
  save_settings

  # Reset and reload
  DEBOUNCE_SEC=0
  LOG_LINES=0
  load_settings

  assert_eq "10" "$DEBOUNCE_SEC" "DEBOUNCE_SEC after reload"
  assert_eq "100" "$LOG_LINES" "LOG_LINES after reload"
}

test_settings_file_contents_quoted() {
  source_script
  save_settings
  local content
  content=$(cat "$SETTINGS_FILE")
  # Values with * should be quoted to avoid glob
  assert_contains "$content" 'DEFAULT_CRON="*/5 * * * *"' "cron should be quoted"
}

test_settings_not_overwritten_on_reload() {
  source_script
  # Modify a value and save
  DEBOUNCE_SEC=20
  save_settings

  # Source again — should load existing file, not overwrite
  source_script
  assert_eq "20" "$DEBOUNCE_SEC" "should preserve user setting"
}

# ===================================================================
#  TESTS: verbose / debug
# ===================================================================

test_debug_silent_when_not_verbose() {
  source_script
  VERBOSE=0
  local output
  output=$(debug "secret message")
  assert_eq "" "$output" "debug should be silent when VERBOSE=0"
}

test_debug_visible_when_verbose() {
  source_script
  VERBOSE=1
  local output
  output=$(debug "visible message")
  assert_contains "$output" "visible message" "debug should output when VERBOSE=1"
  assert_contains "$output" "DBG" "debug should have DBG tag"
}

# ===================================================================
#  TESTS: DRY_RUN flag
# ===================================================================

test_dry_run_flag_default() {
  source_script
  assert_eq "0" "$DRY_RUN" "DRY_RUN should default to 0"
}

test_dry_run_flag_settable() {
  export DRY_RUN=1
  source_script
  assert_eq "1" "$DRY_RUN" "DRY_RUN should be settable via env"
}

# ===================================================================
#  TESTS: help includes new features
# ===================================================================

test_help_mentions_dry_run() {
  local output
  output=$(GDRIVE_SYNC_TESTING=1 bash "$(script_path)" --help 2>&1)
  assert_contains "$output" "dry-run" "help should mention --dry-run"
}

test_help_mentions_verbose() {
  local output
  output=$(GDRIVE_SYNC_TESTING=1 bash "$(script_path)" --help 2>&1)
  assert_contains "$output" "verbose" "help should mention verbose"
}

test_help_mentions_test() {
  local output
  output=$(GDRIVE_SYNC_TESTING=1 bash "$(script_path)" --help 2>&1)
  assert_contains "$output" "--test" "help should mention --test"
}

test_help_mentions_test_drive() {
  local output
  output=$(GDRIVE_SYNC_TESTING=1 bash "$(script_path)" --help 2>&1)
  assert_contains "$output" "test-drive" "help should mention --test-drive"
}

test_help_mentions_settings() {
  local output
  output=$(GDRIVE_SYNC_TESTING=1 bash "$(script_path)" --help 2>&1)
  assert_contains "$output" "Settings" "help should mention Settings"
}

# ===================================================================
#  TESTS: select_config auto-selects single config
# ===================================================================

test_select_config_auto_selects_single() {
  source_script
  save_config "only-one" "only-one" "/tmp/only" "id" "*/5 * * * *"

  # select_config sets SELECTED in current shell; test via output message
  local output
  output=$(select_config < /dev/null 2>&1)
  assert_contains "$output" "Auto-selected" "should auto-select the only config"
  assert_contains "$output" "only-one" "should show the config name"
}

# ===================================================================
#  TESTS: watcher uses settings values
# ===================================================================

test_watcher_uses_custom_debounce() {
  source_script
  DEBOUNCE_SEC=15
  local output
  output=$(generate_watcher_script "test" "/tmp/s" "rem" "/tmp/l.log")
  assert_contains "$output" "DEBOUNCE=15" "should use custom debounce"
}

test_watcher_uses_custom_log_max() {
  source_script
  LOG_MAX_SIZE_MB=200
  local output
  output=$(generate_watcher_script "test" "/tmp/s" "rem" "/tmp/l.log")
  assert_contains "$output" "LOG_MAX_MB=200" "should use custom log max"
}

# ===================================================================
#  TESTS: main script syntax & lint
# ===================================================================

test_main_script_valid_bash() {
  bash -n "$(script_path)"
  assert_exit_code 0 $? "main script should be valid bash"
}

test_main_script_shellcheck() {
  if ! command -v shellcheck &>/dev/null; then
    echo "shellcheck not installed, skipping"
    return 77
  fi
  shellcheck -s bash -S warning "$(script_path)"
  assert_exit_code 0 $? "shellcheck should report no warnings"
}

# ===================================================================
#  RUN ALL TESTS
# ===================================================================

main() {
  echo ""
  echo -e "${BOLD}gdrive-sync test suite${NC}"
  echo -e "${DIM}$(date)${NC}"
  echo ""

  # Verify script exists
  if [[ ! -f "$(script_path)" ]]; then
    echo -e "${RED}ERROR: gdrive-sync.sh not found at $(script_path)${NC}"
    echo "Run tests from the repo root: bash tests/test-gdrive-sync.sh"
    exit 1
  fi

  # Offer to install shellcheck if missing
  if ! command -v shellcheck &>/dev/null; then
    echo -e "${YELLOW}shellcheck is not installed.${NC}"
    echo "  It's a static analysis tool that catches common bugs in shell scripts"
    echo "  (unquoted variables, incorrect redirections, etc.)."
    echo "  Without it, the shellcheck test will be skipped."
    echo ""
    read -rp "  Install shellcheck now? [y/N] " answer
    if [[ "${answer,,}" == "y" ]]; then
      echo ""
      sudo apt-get install -y shellcheck && echo -e "${GREEN}shellcheck installed.${NC}" \
        || echo -e "${RED}Installation failed — shellcheck test will be skipped.${NC}"
      echo ""
    fi
  fi

  # Collect all test functions
  local tests
  tests=$(declare -F | awk '{print $3}' | grep '^test_' | sort)

  local total
  total=$(echo "$tests" | wc -l)
  echo -e "  Running ${total} tests...\n"

  while IFS= read -r test_fn; do
    run_test "$test_fn"
  done <<< "$tests"

  # Summary
  echo ""
  echo -e "${DIM}──────────────────────────────────────────${NC}"
  local total_ran=$((PASS + FAIL + SKIP))
  echo -e "  ${GREEN}${PASS} passed${NC}  ${RED}${FAIL} failed${NC}  ${YELLOW}${SKIP} skipped${NC}  (${total_ran} total)"

  if [[ ${#ERRORS[@]} -gt 0 ]]; then
    echo ""
    echo -e "  ${RED}Failed tests:${NC}"
    for e in "${ERRORS[@]}"; do
      echo -e "    ${RED}✗${NC} $e"
    done
  fi

  echo ""

  [[ $FAIL -eq 0 ]]
}

main
