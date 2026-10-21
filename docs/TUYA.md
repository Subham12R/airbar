# HomeMate / Tuya notes

HomeMate's smart switches and lights are white-label **Tuya** devices. AirBar controls them **locally**, talking to each device on your Wi-Fi. The cloud is used only to obtain each device's local key (once) and to pair new devices.

## Why a Tuya developer project?

Every device encrypts its LAN traffic with a 16-character **local key** that only Tuya's cloud knows. The HomeMate app won't share devices or keys with other apps; scanning another app's QR code shows "please use designated app". Tuya's own developer platform can read the keys for devices in a linked **Smart Life** account:

1. Create a free Cloud project at [iot.tuya.com](https://iot.tuya.com/cloud/) (Smart Home, your region's data center).
2. In the project, **Devices › Link App Account**, and scan the QR code with the Smart Life app.
3. Give AirBar the project's **Access ID** and **Access Secret** (Settings › Devices). They're stored in the macOS Keychain.

AirBar then imports each device's local key and data-point mapping (`GET /v1.0/users/{uid}/devices`, `GET /v1.1/devices/{id}/specifications`). Requests are signed with Tuya's HMAC-SHA256 scheme; see `TuyaCloud.signedHeaders`.

Devices already paired to the HomeMate app are in HomeMate's account, not Smart Life's. To bring them over, add them in Smart Life or pair them with AirBar's wizard. Either way they leave the HomeMate app.

## Local protocol

Devices listen on **TCP 6668**. AirBar supports protocol versions **3.3, 3.4 and 3.5**, the ones current HomeMate hardware uses. Older 3.1 devices aren't supported.

| | 3.3 | 3.4 | 3.5 |
|---|---|---|---|
| Frame | `0x55AA … 0xAA55` | `0x55AA … 0xAA55` | `0x6699 … 0x9966` |
| Encryption | AES-128-ECB, local key | AES-128-ECB, session key | AES-128-GCM, session key (header is authenticated) |
| Integrity | CRC-32 | HMAC-SHA256 | GCM tag |
| Session key | none | nonce exchange, ECB | nonce exchange, GCM |
| Status | command 10 (`DP_QUERY`) | command 16, `{}` | command 16, `{}` |
| Set | command 7 (`CONTROL`) | command 13, `{"protocol":5,"t":…,"data":{"dps":{…}}}` | same as 3.4 |

**Session key (3.4/3.5):** the client sends 16 random bytes; the device answers with its own 16 bytes plus `HMAC-SHA256(local key, client nonce)`; the client replies with `HMAC-SHA256(local key, device nonce)`. The session key is `client ⊕ device`, encrypted with the local key: ECB for 3.4, or GCM with the first 12 bytes of the client nonce as IV for 3.5 (ciphertext only).

Device replies carry a 4-byte return code before the payload; payloads may start with a 15-byte version header (`"3.5"` + 12 zero bytes). JSON must be compact, without spaces.

**Discovery:** devices broadcast their ID, IP and version every few seconds on UDP 6666 (plaintext) and 6667 (encrypted with `MD5("yGAdlopoPVldABfn")`, in the version's frame format).

## Lights

Lights use standard Tuya data points: `switch_led` (20), `work_mode` (21: `white`/`colour`/`scene`), `bright_value_v2` (22, 10–1000), `temp_value_v2` (23, 0–1000) and `colour_data_v2` (24). Many strips report `colour_data` but actually use the 12-character v2 colour format (`HHHH SSSS VVVV`, S and V in 0–1000). AirBar reads the current value to tell which format a device speaks. On colour-only strips, and in colour mode, brightness is the V part of the colour.

## Pairing (EZ mode)

A device in pairing mode (light blinking fast) listens for Wi-Fi details sent as UDP **packet lengths** to `255.255.255.255:30011` and as **multicast addresses** `226.x.y.z:30012`, carrying the SSID, password and a pairing token from `POST /v1.0/device/paring/token`. AirBar polls `GET /v1.0/device/paring/tokens/{token}` until the device registers, then imports its key. The encoding is ported from [tuya-convert](https://github.com/ct-Open-Source/tuya-convert) and checked against it in the tests.

## Credits

Protocol details come from [tinytuya](https://github.com/jasonacox/tinytuya) and [tuya-convert](https://github.com/ct-Open-Source/tuya-convert). The test vectors in `Tests/TuyaKitTests/Vectors.swift` were generated with them.
