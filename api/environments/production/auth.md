# Production — Authentication chain

How a **user code** becomes a **session token**, declared as configuration
rather than coded into a script.

```
userCode ──▶ fetchUserDetail ──▶ phoneNumber + password ──▶ login ──▶ accessToken
                                                                          │
                                                            runtime.token ◀┘
```

Run it with:

```bash
.claude/skills/apiCall/scripts/api_action.sh auth production WE7713033
```

That stores `runtime.token` and `runtime.userCode` in the context, so every
later `call` and every `call-api` plan step is authenticated. Neither the
password nor the token is printed, logged, or written to a report.

Only the fenced ```properties block is parsed.

```properties
user_lookup_path     = fetchUserDetail
user_lookup_query    = userCodes=${userCode}
username_path        = data.0.phoneNumber
password_path        = data.0.password
login_path           = login
login_method         = POST
login_body           = {"password":"${password}","type":"OPERATOR","userName":"${userName}","userConsent":true}
token_path           = data.accessToken
token_user_code_path = data.userCode
```

| Key | Meaning |
|---|---|
| `user_lookup_path` | path key for the user-detail lookup |
| `user_lookup_query` | query string appended to it; `${userCode}` is the argument passed to `auth` |
| `username_path` | JSON path to the login username in the lookup response |
| `password_path` | JSON path to the password in the lookup response |
| `login_path` | path key for the login call |
| `login_method` | HTTP method for login |
| `login_body` | request body template; `${userName}` / `${password}` come from the lookup |
| `token_path` | JSON path to the session token in the login response |
| `token_user_code_path` | JSON path to the account's own user code — used for the `user-code` header, so it always matches the account actually logged in |

## Why `data.0.` and not `data.`

`fetchUserDetail` returns `data` as an **array** (it accepts `userCodes`,
plural), so the first element is indexed explicitly. This was confirmed against
the live endpoint — the response is:

```json
{ "message": "OK", "success": true,
  "data": [ { "name": "...", "code": "WE7713033",
              "phoneNumber": "...", "password": "...",
              "userTypes": ["OPERATOR"], "active": true } ] }
```

`getAllFilterCount`, by contrast, returns `data` as an object, which is why
that response's fields unwrap to `api.running` while these need an index.

## Both calls are unauthenticated by design

`fetchUserDetail` and `login` are the endpoints that *produce* credentials, so
they are sent with static headers only. They cannot carry a token that does not
exist yet. This is the `--no-auth` path in `api_action.sh call`.

## `user-code` is taken from the login response, not from config

`token_user_code_path` reads the account's user code back out of the login
response rather than trusting the argument or a committed default. If the
`user-code` header ever disagreed with the token's account, every UI-vs-API
comparison would silently compare two different fleets — the failure would look
like an app bug.

## Login is rate-limited

Repeated attempts return `401 "You have reached maximum login attempts, wait
till 15 minutes before trying again"`, which locks out the account for everyone.
Authenticate once per run and reuse `runtime.token`; the context persists
between `api_action.sh` calls precisely so that re-login isn't needed.

## Secrets

The looked-up password and the returned token live only in the runtime context
(`.context.json`, `chmod 600`, gitignored). Both are redacted from `context`
dumps, all log output, and reports. Nothing in this file is a credential — it
only says *where to find* them.
