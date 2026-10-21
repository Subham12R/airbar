# AirBar

**Your Hitachi air conditioner, from the Mac menu bar.**

AirBar is a small, native macOS menu bar app (plus a command-line tool) for air conditioners connected to **Hitachi airCloud Go**. Turn the AC on or off and change temperature, mode, fan speed and swing with one click, without picking up your phone.

[![CI](https://github.com/Subham12R/airbar/actions/workflows/ci.yml/badge.svg)](https://github.com/Subham12R/airbar/actions/workflows/ci.yml)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue)
![License: MIT](https://img.shields.io/badge/license-MIT-green)

<p align="center">
  <img src="docs/images/panel-dark.png" width="380" alt="AirBar panel in dark mode">
  <img src="docs/images/panel-light.png" width="380" alt="AirBar panel in light mode">
</p>

> AirBar is an independent project. It is not affiliated with, endorsed by, or supported by Hitachi, Johnson Controls-Hitachi Air Conditioning, or airCloud. It uses the same cloud service as the official app, which may change without notice.

## Features

- **One-click control** of power, temperature (in your unit's steps, e.g. 0.5°), mode, fan speed and swing.
- **Model-aware.** Only the modes, fan levels, swing options and temperature range your unit supports are shown, read from airCloud's model data. Commands are fitted to those rules, so no more "400 Bad Request".
- **Reliable commands.** airCloud only accepts one command at a time. AirBar merges rapid taps into one command and sends them in order, so nothing gets rejected or undone.
- **At a glance.** The menu bar icon fills in while a unit runs and can show the set temperature. The panel draws a live model of the unit: the louver swings, and airflow follows mode and fan speed.
- **Phone or email sign-in**, matching however you sign in to airCloud Go. Your password stays in the macOS Keychain.
- **Multiple units** and **light/dark mode** supported.
- **`airbar` CLI** for scripts, Shortcuts, Raycast or Alfred.
- **Native and small.** SwiftUI, no Electron, no Python, no third-party dependencies, no telemetry.

## Requirements

- macOS 14 Sonoma or later (Apple silicon or Intel)
- A Hitachi air conditioner set up in the **airCloud Go** app (Wi-Fi adapter such as SPX-WFG02)

## Install

1. Download `AirBar-<version>.zip` from the [latest release](https://github.com/Subham12R/airbar/releases/latest) and unzip it.
2. Move **AirBar.app** to your **Applications** folder.
3. Open it. The release isn't notarized yet, so the first time macOS may refuse to open it. **Right-click AirBar.app → Open → Open**, or run:

   ```bash
   xattr -dr com.apple.quarantine /Applications/AirBar.app
   ```

4. Click the AC icon in the menu bar, then **Sign in**.

**Optional CLI:** copy `airbar` from the zip somewhere on your `PATH`:

```bash
sudo install -m 755 airbar /usr/local/bin/airbar
```

### Build from source

```bash
git clone https://github.com/Subham12R/airbar.git
cd airbar
scripts/build-app.sh --native      # or without --native for a universal build
open dist/AirBar.app
```

Requires Xcode 16 or later (or the matching Swift toolchain).

## Using AirBar

Click the icon in the menu bar to open the panel. Each unit gets a card:

| Control | What it does |
|---|---|
| Power button | On / off |
| − / + | Target temperature, in your model's steps and range |
| Mode | Cool, Heat, Dry, Fan, Auto (only the ones your unit has) |
| Fan | Auto or levels 1–5 (only the ones allowed in the current mode) |
| Swing | Fixed, Up–Down, Side, All (only the axes your unit has) |

**Updating…** appears on the card while a change is being sent.

Open **Settings** (gear icon) to sign in or out, start AirBar at login, show or hide the temperature in the menu bar, and set how often it refreshes.

<p align="center"><img src="docs/images/settings-account.png" width="420" alt="Sign-in settings"></p>

### Command line

```bash
airbar login --phone 9XXXXXXXXX            # or: airbar login --email you@example.com
airbar status                              # Living Room: on, cooling 24.5°, fan 2, swing vertical
airbar on                                  # with several units, add --unit "Living Room"
airbar set --temp 24.5 --mode cool --fan 2 --swing vertical
airbar off
airbar status --json                       # full state including model capabilities
```

The CLI and the app share the sign-in (Keychain), configuration and command queue.

## Configuration

Most settings are in **Settings → General**. The full set is in a JSON file at
`~/Library/Application Support/AirBar/config.json` (created on first launch; **Settings → General → Open config file**). Set `AIRBAR_CONFIG` to use a different file.

| Key | Default | Meaning |
|---|---|---|
| `apiBaseURL` | `https://api-global-prod.aircloudhome.com/` | airCloud REST server |
| `notificationURL` | `wss://notification-global-prod.aircloudhome.com/rac-notifications/websocket` | airCloud state websocket |
| `userAgent` | `okhttp/4.9.1` | Sent with every request (the API needs an app-like value) |
| `refreshIntervalSeconds` | `45` | How often the app re-reads unit state |
| `coalesceMilliseconds` | `450` | Taps within this window become one command |
| `settleSeconds` | `1.2` | Pause after each accepted command before the next |
| `showTemperatureInMenuBar` | `true` | Show the set temperature next to the icon |
| `defaultCountryCode` | `91` | Pre-filled country code for phone sign-in |

Restart AirBar after editing the file.

## Privacy and security

- AirBar talks only to airCloud's servers. There are no analytics, crash reporters or third-party services.
- Your sign-in and session tokens are stored in the macOS Keychain (service `io.github.subham12r.airbar`), available only on this Mac.
- Model data is cached in `~/Library/Application Support/AirBar/models.json`, which contains no personal data.

See [SECURITY.md](SECURITY.md) to report a vulnerability.

## Troubleshooting

| Problem | Fix |
|---|---|
| "airCloud didn't recognise that account and password" | Pick **Phone** or **Email** to match how you sign in to airCloud Go. For phone, enter the number without the country code (it goes in the small field). |
| You sign in to airCloud Go with Google or Apple | Those accounts have no password. Use **Forgot password** in airCloud Go to set one. |
| "No air conditioners yet" | The airCloud home for that login is empty. Add the unit in airCloud Go, or sign in with the account that owns it. |
| "The AC is still busy…" | The unit was still handling a previous command. Wait a second and try again. |
| macOS says AirBar can't be opened | See step 3 of [Install](#install). |

More help: [SUPPORT.md](SUPPORT.md).

## How it works

AirBar calls the same cloud endpoints as the official airCloud Go app: sign-in, a STOMP websocket for unit state, the model-configuration endpoint, and the control command. Protocol notes are in [docs/API.md](docs/API.md).

```
Sources/
  AirCloudKit/   API client, model rules, command fitting, Keychain, config (shared)
  AirBar/        SwiftUI menu bar app
  airbar-cli/    airbar command-line tool
Tests/           unit tests for parsing and command fitting
scripts/         build-app.sh (app bundle + zip), make-icon.swift
```

## Roadmap

- Notarized, signed releases and a Homebrew cask
- Schedules and timers
- Energy usage
- Other smart-home brands (HomeMate/Tuya lights and switches were prototyped and may return)

Ideas and requests are welcome in [issues](https://github.com/Subham12R/airbar/issues).

## Contributing

Contributions are very welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) to get set up. Please follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## Acknowledgements

Earlier community work on the airCloud API helped a lot:
[svmironov/aircloud_ha](https://github.com/svmironov/aircloud_ha),
[mdlnvere/AircloudGo-Homey-module](https://github.com/mdlnvere/AircloudGo-Homey-module),
[lb544/ha-aircloud](https://github.com/lb544/ha-aircloud) and
[nogic1008/ha_aircloudhome](https://github.com/nogic1008/ha_aircloudhome).

## License

[MIT](LICENSE) © 2026 Subham Karmakar
