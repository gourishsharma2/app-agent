# Stage — Request Headers

Headers sent on every **stage** request. Two fenced blocks are parsed, and the
distinction between them is the point of this file.

## Static headers

Fixed values that describe the calling client. Safe to commit — nothing here
identifies a session or a user.

```properties
X-APP-VERSION   = 24.1.0
X-APP-NAME      = 24.1.0
locale          = en
X-APP-PLATFORM  = android
Cache-Control   = no-cache
service         = OperatorApp
```

## Runtime headers

Values that only exist during a run. Each is declared as a `${...}` reference
into the runtime context — **never a literal**. The loader resolves them at
call time from the values supplied to `/run`; it does not invent defaults.

```runtime
token            = ${runtime.token}
user-code        = ${runtime.userCode}
DEVICE_NAME      = ${runtime.deviceName}
DEVICE-ID        = ${runtime.deviceId}
X-DEVICE-ID      = ${runtime.deviceId}
ANDROID_VERSION  = ${runtime.androidVersion}
```

Adding a runtime header is a one-line change here plus passing the value to
`/run` — no script change.

If a referenced value wasn't supplied, the call fails before any request is
sent, naming the missing input and the header that needed it. It is never sent
as the empty string: an unauthenticated call that returns `401` looks like a
backend problem, whereas a missing-input error says what to actually fix.

## Why `token` and `user-code` are not in the static block

`token` is a session secret and `user-code` selects which operator account the
backend answers for. Committing either would put a credential in git and pin
every run to one account. `user-code` must match the account the app is logged
in as, or the API and the UI are describing two different fleets.
