# Changelog

All notable changes to AirBar are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

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
