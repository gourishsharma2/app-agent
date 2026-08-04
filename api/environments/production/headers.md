# Production — Request Headers

Headers sent on every **production** request. Two fenced blocks are parsed.

## Static headers

Fixed values describing the calling client. Safe to commit — none identifies a
session or an account.

```properties
X-APP-VERSION   = 24.1.0
X-APP-NAME      = 24.1.0
locale          = en
X-APP-PLATFORM  = android
Cache-Control   = no-cache
service         = OperatorApp
```

## Runtime headers

Supplied per run, declared as `${...}` references into the runtime context —
never literals.

```runtime
token            = ${runtime.token}
user-code        = ${runtime.userCode}
DEVICE_NAME      = ${runtime.deviceName}
DEVICE-ID        = ${runtime.deviceId}
X-DEVICE-ID      = ${runtime.deviceId}
ANDROID_VERSION  = ${runtime.androidVersion}
```

A missing input fails the call before any request is sent, naming both the
input and the header that needed it — never substituted with an empty string,
because the resulting `401` would look like a backend fault instead of a
missing argument.

## `X-DEVICE-ID` and `DEVICE-ID` are mapped to the same input

The real client sends two *different* values for these: `DEVICE-ID` is a device
UUID, while `X-DEVICE-ID` carries an OS build fingerprint (e.g.
`BP4A.251205.006`). Both are mapped to `${runtime.deviceId}` here because
`/run` takes a single `deviceId=`, which is enough for the endpoint currently
registered.

If an endpoint is added that gates on the build fingerprint, split them: add a
distinct runtime input and point `X-DEVICE-ID` at it. That is a one-line change
in this file — no script change — which is the reason runtime headers are
declared rather than hardcoded.

## Why `token` and `user-code` are never static

`token` is a session secret; `user-code` selects the operator account the
backend answers for. Committing either would place a credential in git and pin
every run to one account. `user-code` must match the account the app is logged
in as, or the API and the UI describe two different fleets and every comparison
is meaningless.
