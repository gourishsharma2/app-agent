# Stage — Base URL

Connection settings for the **stage** backend.

This file is parsed by `.claude/skills/apiCall/scripts/config_loader.py`. Only
the fenced ```properties block below is read — everything outside it is
documentation for humans and is ignored by the loader.

`environment` must match the value passed as `environment=` to `/run`, and it
must also match the app's own in-app Staging/Production toggle on the login
screen (see `application/environments.md`). If the two disagree, an API value
is being compared against a different backend's data and any mismatch blames
the wrong thing.

```properties
environment = stage
base_url    = https://stage.wheelseye.com
timeout     = 30
retry_count = 2
```

| Key | Required | Meaning |
|---|---|---|
| `environment` | yes | Canonical name of this environment. |
| `base_url` | yes | Scheme + host. No trailing slash; paths from `paths.md` are appended verbatim. |
| `timeout` | yes | Per-attempt socket timeout, seconds. |
| `retry_count` | no (default `0`) | Extra attempts after the first. Only timeouts, network failures and 5xx are retried — a 4xx is a definitive answer and is never retried. |

## Unverified

`base_url` here is a placeholder. The API branch reviewed during design left
`apiBaseUrl.stage` empty, so the stage host has never been confirmed against a
live call from this repo. Verify it before relying on a stage run; a wrong host
surfaces as a DNS/connection error from `api_action.sh doctor stage`, not as a
silent pass.
