# Stage — Authentication chain

How a **user code** becomes a **session token**. Same structure and the same
keys as `../production/auth.md` — read that file for what each key means and
why the paths are what they are.

```bash
.claude/skills/apiCall/scripts/api_action.sh auth stage <userCode>
```

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

## Unverified

This chain is a copy of the production one and **has never been executed against
stage**. Two things are unknown:

- stage's `base_url` is a placeholder (`base_url.md`), so `login` has no
  confirmed host;
- no stage UMS host is known, so `fetchUserDetail` in `paths.md` still points at
  the production UMS.

As written, this would look up a production user and try to log in on stage.
Verify both hosts before relying on it. `api_action.sh doctor stage` shows what
is resolved; the first `auth stage` attempt is what proves it.

The response paths (`data.0.phoneNumber`, `data.accessToken`) were confirmed
against the live production endpoints and are expected to hold on stage, but
that too is an assumption until a call succeeds.
