# Changelog

All notable changes to AirBar are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

## [1.1.0] - 2026-10-21

### Added
- **HomeMate / Tuya lights and switches**, controlled locally over your Wi-Fi (no cloud round trip). Supports Tuya LAN protocol 3.3, 3.4 and 3.5, including the session-key handshake.
- Panel section with a tile per switch and a card per light: brightness, white tone and colour swatches. Works without an airCloud account.
- **Pairing wizard** (Settings › Devices › Add a device): a radar of nearby devices, Wi-Fi details, then EZ-mode pairing through a Tuya developer project, saving each new device's local key.
- Tuya Cloud link (once) to import existing devices with their local keys and data-point mappings.
- Add a device by hand with its ID and local key; devices that move to a new IP are found again automatically.
- CLI: `airbar devices`, `light`, `switch`, `scan`, `tuya connect|import|add|remove` and `pair`.
- `TuyaKit` library with protocol tests checked byte for byte against tinytuya and tuya-convert.

### Changed
- "Turn off all lights and switches" button in the panel footer.
- The menu bar icon shows a bulb when only lights are set up.

## [1.0.0] - 2026-10-21

### Added
- Menu bar app for Hitachi airCloud Go air conditioners: power, temperature, mode, fan and swing.
- Phone (`mobileNumber`) and email sign-in, stored in the macOS Keychain.
- Model-aware controls from airCloud's model configuration; commands are fitted to each model's rules.
- Command queue that merges rapid taps and sends one command at a time, with retry while the unit is busy.
- Live illustration of the unit (louver swing, airflow by mode and fan speed).
- Settings: launch at login, temperature in menu bar, refresh interval, JSON config file.
- `airbar` command-line tool sharing the app's sign-in, config and queue.
- Universal (Apple silicon + Intel) release build.
