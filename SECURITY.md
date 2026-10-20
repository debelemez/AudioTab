# Security Policy

## Supported versions

Only the latest release gets security fixes. The app updates itself from GitHub Releases, so staying current takes no effort.

## Reporting a vulnerability

Please **don't open a public issue** for security problems. Use GitHub's private reporting instead: **Security → Report a vulnerability** on this repository.

Include what you found, the affected version, and steps to reproduce if you have them. You'll get a reply as soon as possible, and credit in the release notes if you'd like.

## How releases are protected

- Every release is built by GitHub Actions and signed with a single certificate. The public part is in [`signing/AudioTab.pem`](signing/AudioTab.pem).
- The signing key is unlocked only for builds of `main`. Pull-request builds are never signed, and the key can't be exported from the build machine.
- The in-app updater installs a release only if all of these hold:
  - the bundle identifier is `com.firewallstudio.audiotab`;
  - it is signed with that exact certificate (pinned by its SHA-1 fingerprint);
  - its version matches the release and is newer than the installed one (no downgrades).
- `install.sh` runs the same signature check before it replaces anything in `/Applications`.
- The app has no server, no account and no telemetry. Its only network access is the update check against GitHub.

## Audits

- **October 2026: v2.3.0**, source review using [Cloudflare's security-audit skill](https://github.com/cloudflare/security-audit-skill). No vulnerabilities were found. Hardening was shipped in v2.3.1. → [Full report](docs/security-audit.md)
