# airCloud Go API notes

AirBar uses the same cloud API as the official airCloud Go app. These notes cover what AirBar needs and were put together from observing the app's own traffic and from earlier community projects (see the README's acknowledgements). The API is undocumented and may change.

All REST calls go to `https://api-global-prod.aircloudhome.com/` and need an app-like `User-Agent` (AirBar sends `okhttp/4.9.1`). Japanese "AirCloud Home" accounts live on a different server (`api-kuma.aircloudhome.com`); point `apiBaseURL` in the config there to try it.

## Sign-in

`POST iam/auth/sign-in`

| Account type | Body |
|---|---|
| Email | `{"email": "you@example.com", "password": "…"}` |
| Phone | `{"mobileNumber": "+<country code><number>", "password": "…"}` |

Phone accounts must use `mobileNumber`. Sending a phone number in the `email` field always fails. Both forms return `401 {"errorState":"UNKNOWN_USER_OR_PASSWORD"}` on bad credentials, and `200` with `token` and `refreshToken` (JWTs) on success.

`POST iam/auth/refresh-token` with `Authorization: Bearer <refreshToken>` and `isRefreshToken: true` returns new tokens.

`GET iam/user/v2/who-am-i` returns the account, including the `familyId` of its home.

Unauthenticated requests to most other paths return `401`, whether or not the path exists.

## Reading units

**Websocket (preferred):** `wss://notification-global-prod.aircloudhome.com/rac-notifications/websocket`, speaking STOMP 1.2. Send one message containing a `CONNECT` frame with `Authorization:Bearer <token>` and a `SUBSCRIBE` frame for `/notification/<familyId>/<familyId>`. The server answers `CONNECTED` (it includes a `user-name` header only if the token was accepted), then a `MESSAGE` whose JSON body is `{"notificationType": "...", "data": [ ...units ]}`. An empty `data` array means the home has no units.

**REST (fallback):** `GET rac/ownership/groups/<familyId>/idu-list` returns the same unit objects.

Useful unit fields: `id`, `name`, `power` (`ON`/`OFF`), `mode`, `iduTemperature` (target), `roomTemperature`, `fanSpeed`, `fanSwing`, `online`, `cloudId` (model key), `humidity`, `relativeTemperature`, `SysType`.

## Model rules

`POST rac/model-wise/rac-configuration` with a JSON array of `cloudId`s returns, per model:

- `swing`: which axes exist, e.g. `{"VERTICAL": true, "HORIZONTAL": false}`
- `racOperationModes`: one entry per supported mode with `minTemperature`, `maxTemperature`, `temperatureSettingPitchType` (step, e.g. `0.5`), `enableSettings` (whether temperature, humidity, fan and swing apply), `enableFanSpeed` (allowed levels: `AUTO`, `LV1`…`LV5`) and `defaultFanSpeed`

A mode missing from the list (for example `HEATING` on a cooling-only unit) isn't supported.

## Control

`PUT rac/basic-idu-control/general-control-command/<unitId>?familyId=<familyId>`

```json
{"power": "ON", "mode": "COOLING", "iduTemperature": 24.5, "fanSpeed": "LV2", "fanSwing": "VERTICAL",
 "humidity": "0", "relativeTemperature": 0}
```

- Send the full state every time. Leave out `iduTemperature` in modes without temperature (such as `FAN`).
- Residential units (`SysType` 1) accept `humidity` set to the model's default (`"0"` when humidity isn't adjustable).
- `400` (empty body) means a value the model doesn't allow: a fan level the mode doesn't support, a swing axis the unit lacks, or a temperature outside the range or off the step. AirBar fits every command to the model rules first.
- `429 {"type":"command_in_progress"}` means the unit is still handling the previous command. Wait about a second and retry. AirBar queues commands so this rarely happens.
- `200 {"commandId": "...", "thingId": "..."}` means accepted. The unit applies it asynchronously, so re-read state a moment later.
