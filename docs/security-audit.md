# Security audit: AudioTab v2.3.0

| | |
|---|---|
| **Date** | October 2026 |
| **Method** | [Cloudflare security-audit skill](https://github.com/cloudflare/security-audit-skill), *quick* profile |
| **Source** | v2.3.0 (`f6d86ec`) |
| **Scope** | `Sources/`, `build.sh`, `install.sh`, `.github/workflows/release.yml`, `signing/`, `.gitignore`, `VERSION` |
| **Result** | **No confirmed vulnerabilities.** Hardening shipped in **v2.3.1** |

## How it was done

The audit was a source review only. The code wasn't run, because the audit host had no macOS toolchain. It worked in these steps:

1. **Mapping.** The app's trust boundaries were mapped: the update channel, the CI signing key, the installer, the global keyboard tap, screen capture files, migrated preferences, and private window-server APIs.
2. **Review.** The code was split into 10 coverage units, and four reviewers worked through them in parallel, each against specific attack classes.
3. **Critic pass.** Every candidate issue then went to an independent critic who hadn't seen how it was found.

The quick profile is a partial pass. It doesn't cover macOS runtime behaviour, such as how permissions carry across re-signed apps or how `ditto` handles symlinks. It also doesn't cover GitHub repository settings.

## What it found

Reviewers raised six candidate issues. The critic decided none of them crosses a real trust boundary. Each one needs either **write access to this repository** (which already allows changing the installer or workflow directly) or **the same macOS user account**.

They are still worth closing. The goal is that a leaked GitHub token *without* the signing key can't ship code to users. All six were fixed in v2.3.1:

| Area | Issue | Fix in v2.3.1 |
|---|---|---|
| Updater | A copy built from source and ad-hoc signed accepted any update with the right bundle ID, whatever its signer | Fixed rule for every copy: bundle ID plus the certificate's SHA-1 fingerprint |
| Updater | The version inside the downloaded app wasn't checked, so an older signed build could be served as "new" | The bundle version must equal the release version and be newer than the installed one |
| Updater | The download URL host wasn't restricted, and temporary files were left behind after a failed install | Downloads are limited to GitHub hosts, and the temp folder is always removed |
| `install.sh` | Installed whatever the latest release zip contained, with no signature check | `codesign --verify` against the pinned certificate before anything is replaced |
| CI | The signing key was unlocked on pull-request and manual runs, imported as exportable, and protected by a fixed keychain password; the checkout token was persisted; `VERSION` was interpolated into a shell command | Key unlocked only on pushes to `main`, imported non-exportable, random keychain password, `persist-credentials: false`, `VERSION` validated and passed through `env` |
| Audio devices | Per-app and cycle assignments silently moved to *any* new device with the same name | Assignments move only when that name is unique among known devices |

**Smaller items:**
- Recording FPS read from preferences is now clamped to 1–120.
- A stale code comment about network access was corrected.

## Positive findings

- No secrets have ever been committed. Only the public certificate is in the repository, and signing material is covered by `.gitignore`.
- Helper processes (`ditto`, `xattr`, `screencapture`) run with fixed argument lists, and no external data reaches a shell.
- All network traffic is HTTPS, to GitHub only. Release notes are shown as plain text.
- The keyboard tap swallows only AudioTab's own shortcuts. It never logs, stores or forwards keystrokes.
- Window previews stay in memory. All overlay panels are excluded from screenshots and recordings.
- Private API calls use constant sizes and offsets, with no externally controlled buffers.

## Coverage

10 of 10 units were covered. The final critic pass ran: 6 candidates were raised and all 6 were rejected as findings and turned into hardening.
