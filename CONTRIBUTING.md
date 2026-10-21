# Contributing to AirBar

Thanks for helping! Bug reports, feature ideas, docs fixes and code are all welcome.

## Ways to help

- **Report a bug** with the [bug report form](https://github.com/Subham12R/airbar/issues/new?template=bug_report.yml). Include your macOS version, AirBar version and AC model.
- **Test on your unit.** Hitachi makes many models with different modes and fan levels. Reporting the output of `airbar status --json` (remove your unit names if you like) helps AirBar support more of them.
- **Suggest a feature** with the [feature request form](https://github.com/Subham12R/airbar/issues/new?template=feature_request.yml).
- **Send a pull request.** For anything bigger than a small fix, open an issue first so we can agree on the approach.

## Development setup

You need macOS 14 or later and Xcode 16 or later.

```bash
git clone https://github.com/Subham12R/airbar.git
cd airbar
swift build                         # build everything
swift test                          # run the unit tests
scripts/build-app.sh --native       # build dist/AirBar.app
open dist/AirBar.app
```

You can also open `Package.swift` in Xcode.

The app has a demo mode that needs no account, useful for UI work and screenshots:

```bash
dist/AirBar.app/Contents/MacOS/AirBar --demo --preview /tmp/panel.png --dark
```

## Project layout

| Path | What's there |
|---|---|
| `Sources/AirCloudKit` | API client (`AirCloudClient`), model rules (`Capabilities`), command fitting, STOMP parsing, Keychain, config |
| `Sources/AirBar` | SwiftUI menu bar app: panel, AC card, illustration, settings |
| `Sources/airbar-cli` | `airbar` command-line tool |
| `Tests/AirCloudKitTests` | Unit tests (no network) |
| `docs/API.md` | What we know about the airCloud API |

## Guidelines

- **Keep it dependency-free.** AirBar uses only Apple frameworks. Please discuss before adding a package.
- **Test the logic.** Changes to command fitting, parsing or sign-in need unit tests. Tests must not hit the network.
- **Be gentle with the API.** It's the same service the official app uses. Don't add tight polling loops or bursts of commands; go through the existing queue.
- **Never commit personal data.** No real account IDs, phone numbers, tokens, home IDs or unit IDs in code, tests, fixtures or screenshots. Use demo mode for screenshots.
- **Match the style.** Swift API Design Guidelines, 4-space indent, short doc comments where the "why" isn't obvious. UI text uses sentence case.
- **Small, focused PRs** with a clear description and before/after screenshots for UI changes.

## Commit messages

Use the imperative mood ("Add swing support for …", "Fix temperature step on …"). Reference issues with `Fixes #123` when relevant.

## Releasing (maintainers)

1. Update `VERSION` and `CHANGELOG.md`.
2. Commit, then tag: `git tag v$(cat VERSION) && git push --tags`.
3. The release workflow builds the universal app and attaches `AirBar-<version>.zip` to a GitHub release.

## Code of Conduct

By taking part you agree to follow our [Code of Conduct](CODE_OF_CONDUCT.md).
