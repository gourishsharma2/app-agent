# API layer

Backend contracts for the WheelsEye Operator app, plus the per-environment
configuration that the `apiCall` skill loads at run time.

This directory is to APIs what `flow/` is to screens: the **markdown is the
source of truth**, and a script drives it. Nothing here is test code.

## Layout

```
api/
├── environments/
│   ├── stage/
│   │   ├── base_url.md      environment name, base URL, timeout, retry count
│   │   ├── headers.md       static headers + runtime header declarations
│   │   ├── paths.md          path key → path
│   │   └── auth.md           userCode → username/password → session token
│   └── production/
│       ├── base_url.md
│       ├── headers.md
│       ├── paths.md
│       └── auth.md
├── contracts/
│   └── getAllFilterCount.md  response shape, context variables, UI mapping
├── curl-reference.md         one cURL per endpoint, named by endpoint
└── README.md
```

`environments/` is deliberately a level down rather than `api/stage/`: config,
contracts and (in `.claude/skills/apiCall/`) executor code are three different
kinds of thing, and flattening them into one directory makes it unclear which
files a new endpoint needs to touch.

## The markdown config format

Config files are markdown with fenced blocks. **Only fenced blocks are
parsed** — all prose is documentation, and adding explanation can never break
the loader.

````markdown
```properties
base_url = https://wheelseye.com
timeout  = 30
```
````

`key = value`, split on the first `=`. Blank lines and `#` comments ignored.
There is no YAML dependency anywhere — this repo's scripts use the Python
standard library only.

`headers.md` uses two fence languages:

| Fence | Meaning |
|---|---|
| ```` ```properties ```` | static headers, committed, same on every run |
| ```` ```runtime ```` | headers whose values come from `/run`, declared as `${runtime.x}` references |

## Runtime inputs

Supplied on the `/run` line, never committed:

```
/run environment=stage token=xxxx userCode=WE12345 deviceName=Samsung deviceId=xxxx androidVersion=16
```

They land in the runtime context under `runtime.*`, where `headers.md`'s
`${runtime.token}` style references resolve them. A referenced input that
wasn't supplied fails the call **before any request is sent**, naming the
missing input and the header that needed it — it is never sent as an empty
string, because the resulting `401` would look like a backend fault rather than
a missing argument.

## Adding an endpoint

1. Add `key = /path` to `environments/<env>/paths.md` (both environments).
2. Optionally add `contracts/<key>.md`.
3. Call it from a flow doc: `CALL_API <key>`.

No script change is required. That is the whole point of the layout.

## Auth

A `token` is obtained from a user code in one step:

```bash
.claude/skills/apiCall/scripts/api_action.sh auth production WE25622
```

That runs the chain declared in `environments/<env>/auth.md`: look the user up
in UMS by code, take the phone number and password it returns, exchange them at
`login` for an `accessToken`, and store it as `runtime.token`. The `user-code`
header is taken from the **login response**, so it always matches the account
the token belongs to — a mismatch would compare two different fleets and look
like an app bug.

`token` must also belong to the account the *app* is logged in as, for the same
reason. Tokens and passwords are never written to a plan, a report, or any
committed file; they live only in `.claude/skills/apiCall/.context.json`
(`chmod 600`, gitignored) and are redacted from all output.

`fetchUserDetail` and `login` are called with static headers only — they produce
the credentials, so they cannot present a token that does not exist yet.

## Known backend behaviors

- Responses share the envelope `{ message, success, serverTime, data }`.
  `success: false` can accompany a non-2xx status, so check both.
- `getAllFilterCount` has **no `all` field**, and the All chip is *not* the sum
  of the three counts — verified live, see `contracts/getAllFilterCount.md`.
- Login is rate-limited on this backend: repeated attempts return `401 "You
  have reached maximum login attempts, wait till 15 minutes"`, which locks out
  the shared test account. Reuse the app's existing session token instead of
  authenticating per run.
