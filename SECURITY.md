# Security policy

## Supported versions

Security fixes go into the latest release.

## Reporting a vulnerability

Please **don't open a public issue** for security problems. Report them privately with [GitHub's private vulnerability reporting](https://github.com/Subham12R/airbar/security/advisories/new).

Include what you found, how to reproduce it, and its impact. You'll get a reply within a few days, and credit in the release notes if you'd like.

## How AirBar handles your data

- Your airCloud sign-in (phone number or email, and password) and session tokens are stored in the macOS Keychain, readable only on this Mac.
- AirBar sends them only to airCloud's servers over HTTPS, to sign in and refresh the session.
- There is no telemetry, analytics or third-party service.
- Never paste tokens, passwords or `airbar status --json` output containing personal details into public issues.
