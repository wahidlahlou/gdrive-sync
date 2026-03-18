# Changelog

All notable changes to this project will be documented in this file.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versions follow [Semantic Versioning](https://semver.org/). Pre-1.0 = beta.

## [0.2.0] - 2026-03-18

### Added
- Spinner animation for background operations (sync, Drive checks, systemd, installs)
- Prompt to install shellcheck before running tests if not found
- Confirmation prompt when local folder does not exist, with typo detection for missing parent dirs

### Changed
- Moved test file to `tests/test-gdrive-sync.sh` (dashed naming, proper subdirectory)
- OAuth credentials (Client ID / Secret) now saved per-sync in `.env` config files
- Credential reuse on new setup: detects all unique credential sets from existing configs
  and lets the user pick which to reuse (supports multiple Google Cloud projects)
- CI no longer needs to copy test file into tests/ directory

### Fixed
- Empty folder incorrectly reported as having 1 item (find counted the directory itself)
- Status view showing blank "Last log" line when log file ends with empty lines

## [0.1.0] - 2026-03-17

### Added
- Interactive setup wizard with 7-step guided flow
- Bidirectional sync using rclone bisync + inotifywait + systemd + cron
- Create new Google Drive folders directly from the setup wizard
- Detect and reuse existing OAuth credentials from rclone.conf
- Google credential format validation (Client ID / Secret patterns)
- Initial sync strategy choice when both local and Drive folders have files
  (Drive wins / Local wins / Merge with conflict resolution)
- Dependency checking with inline ✓/✗ status per package
- Multi-sync support: manage multiple independent sync pairs
- Systemd service per sync with auto-restart on failure
- Cron-based polling for Drive → Local changes
- inotifywait-based watcher for near-instant Local → Drive sync (~5s debounce)
- Conflict resolution: newer file wins, loser renamed with numeric suffix
- Auto log rotation (default 50 MB)
- Lock file mechanism to prevent overlapping syncs
- Dry-run mode (`--dry-run`) to validate setup without writing anything
- Verbose mode (`-v`) for extra diagnostics
- CLI flags: `--status`, `--test-drive`, `--test`, `--help`, `--version`
- Manual sync option from the menu
- Log viewer with tail/follow/grep/custom line count
- Global settings management (debounce, log size, cron defaults)
- Test suite with 60+ tests (custom bash test framework)
