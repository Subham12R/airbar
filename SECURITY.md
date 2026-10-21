# Security policy

## Supported versions

Security fixes go into the latest release.

## Reporting a vulnerability

Please **don't open a public issue** for security problems. Report them privately with [GitHub's private vulnerability reporting](https://github.com/Subham12R/airbar/security/advisories/new).

Include what you found, how to reproduce it, and its impact. You'll get a reply within a few days, and credit in the release notes if you'd like.

## How AirBar handles your data

- Your airCloud sign-in (phone number or email, and password) and session tokens, your Tuya project credentials, and each device's local key are stored in the macOS Keychain, readable only on this Mac.
- airCloud credentials go only to airCloud's servers; Tuya project credentials only to Tuya's OpenAPI; local keys never leave your Mac (they encrypt traffic to the device on your network).
- Your Wi-Fi password is used only while pairing, sent to the device in Tuya's EZ-mode encoding, and never stored.
- There is no telemetry, analytics or third-party service.
- Never paste tokens, passwords, local keys or Access Secrets into public issues.
