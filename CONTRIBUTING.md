# Contributing to gdrive-sync

Thanks for your interest! Here's how to contribute.

## Reporting Bugs

[Open an issue](https://github.com/wahidlahlou/gdrive-sync/issues/new?template=bug_report.md) and include:

- `./gdrive-sync.sh --version`
- `rclone version | head -1`
- Your OS (`lsb_release -a`)
- Relevant lines from `~/gdrive-sync-<name>.log`

## Suggesting Features

[Open a feature request](https://github.com/wahidlahlou/gdrive-sync/issues/new?template=feature_request.md) describing the problem you'd like solved.

## Submitting Code

### 1. Fork & clone

```bash
# Fork via GitHub UI, then:
git clone https://github.com/YOUR-USERNAME/gdrive-sync.git
cd gdrive-sync
```

### 2. Create a branch

```bash
git checkout -b feature/my-change    # new feature
git checkout -b fix/some-bug         # bug fix
git checkout -b docs/update-readme   # docs only
```

### 3. Make your changes

- Edit `gdrive-sync.sh` (single-file design — everything lives here)
- Add tests in `test_gdrive_sync.sh` if applicable

### 4. Test locally

```bash
# Syntax check
bash -n gdrive-sync.sh

# Run test suite
mkdir -p tests && cp test_gdrive_sync.sh tests/
bash tests/test_gdrive_sync.sh

# Optional: shellcheck
shellcheck gdrive-sync.sh
```

### 5. Commit & push

```bash
git add gdrive-sync.sh test_gdrive_sync.sh
git commit -m "Short description of what and why"
git push origin feature/my-change
```

### 6. Open a Pull Request

Go to your fork on GitHub and click **"Compare & pull request"**. Target the `main` branch.

CI will automatically run syntax check, shellcheck, and the test suite on your PR.

## Code Style

- Bash 4.4+ — no external languages (Python, Perl, etc.)
- `set -o pipefail`, `shopt -s nullglob`, no `set -e`
- Quote all variables, use `[[ ]]` for conditionals
- Functions for menu actions: `action_*()` pattern
- User-facing messages: use `echo -e` with color variables, not `info()`/`success()` in the setup wizard
- Tests: define `test_*()` functions in `test_gdrive_sync.sh`

## Versioning

We use [Semantic Versioning](https://semver.org/) (currently pre-1.0 beta):

- Version is in `VERSION="X.Y.Z"` at the top of `gdrive-sync.sh`
- Update `CHANGELOG.md` with your changes under `## [Unreleased]`
- The maintainer handles version bumps and releases

## License

By contributing, you agree that your contributions will be licensed under the [MIT License](LICENSE).
