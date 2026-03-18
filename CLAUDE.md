# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**gdrive-sync** is a single-file Bash script (`gdrive-sync.sh`, ~1000 lines) for bidirectional Google Drive ↔ local folder sync on Linux. It uses `rclone bisync`, `inotifywait`, systemd services, and cron jobs. No build system — just an executable bash script.

## Commands

```bash
# Run interactively (main menu)
./gdrive-sync.sh

# CLI flags
./gdrive-sync.sh --status       # Quick status check (scriptable)
./gdrive-sync.sh --test-drive   # Test Drive connection
./gdrive-sync.sh --dry-run      # Validate without writing
./gdrive-sync.sh -v             # Verbose mode

# Tests
bash tests/test-gdrive-sync.sh            # Run full test suite (60+ tests)
bash tests/test-gdrive-sync.sh -v         # Verbose test output
bash tests/test-gdrive-sync.sh test_name  # Run single test by name filter
./gdrive-sync.sh --test             # Run tests via main script
```

There is no build, lint, or format step. The test suite will offer to install `shellcheck` if it's not found.

## Architecture

### Single-file design

Everything lives in `gdrive-sync.sh`. The only other source file is `tests/test-gdrive-sync.sh`.

### Sync mechanism

- **Local → Drive:** `inotifywait` detects file changes → debounce (5s default) → `rclone bisync`
- **Drive → Local:** Cron job (default every 5 min) → `rclone bisync`
- **Conflicts:** Newer file wins; loser renamed with numeric suffix

### Runtime-generated files

The script generates files at runtime, not checked into the repo:
- `~/.config/gdrive-sync/<name>.env` — per-sync config (folder ID, cron schedule, OAuth credentials)
- `~/.config/gdrive-sync/<name>-watcher.sh` — generated inotify watcher script
- `~/.config/gdrive-sync/settings.conf` — global defaults (debounce, log size, etc.)
- `/etc/systemd/system/gdrive-sync-<name>.service` — systemd unit per sync
- Cron entries for periodic remote polling

### Key code organization (all in gdrive-sync.sh)

- **`action_*()`** functions — Each menu option (add/list/status/edit/remove/logs/manual-sync/test-drive/settings/run-tests)
- **`generate_watcher_script()`** — Factory that creates the inotify watcher with debounce, lock file, conflict resolution, and log rotation
- **`save_config()` / `load_config()`** — Per-sync `.env` persistence
- **`load_settings()` / `save_settings()`** — Global settings persistence
- **CLI parsing section** — Handles `--status`, `--test-drive`, `--dry-run`, `-v`, `--test`, `--help`, `--version`
- **Helper functions** — `info()`, `success()`, `warn()`, `err()`, `die()`, `confirm()`, `need_cmd()`, `version_gte()`

### How to extend

- **New action:** Create `action_foo()` + add case to the menu
- **New CLI flag:** Add to CLI parsing section + `show_help()`
- **New test:** Define `test_foo()` in `tests/test-gdrive-sync.sh`
- **Modify watcher behavior:** Edit the heredoc in `generate_watcher_script()`

## Test framework

Custom test framework in `tests/test-gdrive-sync.sh` with:
- Assertion functions: `assert_eq`, `assert_contains`, `assert_file_exists`, etc.
- Per-test temp workspace via `setup_tmpdir()` / `teardown_tmpdir()`
- Tests source `gdrive-sync.sh` with `GDRIVE_SYNC_TESTING=1` to avoid side effects
- No external dependencies; rclone/Google account not needed for tests

## Bash conventions

- `set -o pipefail` and `shopt -s nullglob` (no `set -e`; errors handled explicitly)
- All variables quoted, `[[ ]]` conditionals throughout
- Never runs as root; uses `sudo` only for systemd operations
- Lock file mechanism prevents overlapping syncs (5-min stale timeout)

## Dependencies

- **rclone** >= 1.62.0 (for stable bisync support)
- **inotify-tools** (inotifywait)
- **curl**, **systemd**, **cron**
- Linux only (inotify + systemd required)

## Versioning & Releases

We use [Semantic Versioning](https://semver.org/): `MAJOR.MINOR.PATCH`

- **Pre-1.0** (current): beta. Breaking changes bump MINOR, fixes bump PATCH.
- **Post-1.0**: MAJOR = breaking changes, MINOR = new features, PATCH = bug fixes.

The version lives in one place: `VERSION="X.Y.Z"` near the top of `gdrive-sync.sh`.

### Release checklist

1. Update `VERSION` in `gdrive-sync.sh`
2. Add a section in `CHANGELOG.md` (move items from `[Unreleased]` to `[X.Y.Z] - YYYY-MM-DD`)
3. Commit: `git commit -m "Release vX.Y.Z"`
4. Tag: `git tag vX.Y.Z`
5. Push: `git push origin main --tags`
6. Create GitHub release: `gh release create vX.Y.Z --notes-from-tag`

### CHANGELOG.md format

Follow [Keep a Changelog](https://keepachangelog.com/). Categories:
- **Added** — new features
- **Changed** — changes to existing features
- **Fixed** — bug fixes
- **Removed** — removed features

During development, add entries under `## [Unreleased]` at the top. On release, rename it to the version number with the date.

## Git Workflow

- **`main`** branch = stable, release-ready code
- **Feature branches** for new work: `feature/description` or `fix/description`
- **Pull requests** to merge into `main` — CI runs tests automatically
- **Never commit directly to `main`** for non-trivial changes

### Branch naming

- `feature/create-drive-folder` — new functionality
- `fix/empty-config-crash` — bug fix
- `docs/update-readme` — documentation only
- `chore/ci-setup` — tooling, config, infrastructure

### CI

GitHub Actions runs on every push/PR to `main`:
- `bash -n gdrive-sync.sh` (syntax check)
- `shellcheck` (lint)
- `bash tests/test-gdrive-sync.sh` (test suite)
