# Production — Base URL

Connection settings for the **production** backend.

Only the fenced ```properties block is parsed by
`.claude/skills/apiCall/scripts/config_loader.py`.

`environment` must match the value passed as `environment=` to `/run` and the
app's own in-app Staging/Production toggle (see `application/environments.md`).

```properties
environment = production
base_url    = https://wheelseye.com
timeout     = 30
retry_count = 2
```

| Key | Required | Meaning |
|---|---|---|
| `environment` | yes | Canonical name of this environment. |
| `base_url` | yes | Scheme + host. No trailing slash. |
| `timeout` | yes | Per-attempt socket timeout, seconds. |
| `retry_count` | no (default `0`) | Extra attempts after the first, for timeouts / network errors / 5xx only. A 4xx is never retried. |

## This is production data

Runs against this environment read a real operator account's live fleet. The
counts move as vehicles move, which is exactly why a flow should compare
against this API rather than assert a number written into a doc weeks ago.

`retry_count` applies only to reads. It stays safe here because the one
endpoint currently registered is a `GET`; if a non-idempotent `POST` is added
to `paths.md`, set `retry_count = 0` or the retry could submit twice.
