# Login

Password login. Issues the session token every other endpoint requires.
The UI equivalent is `flow/loginFlow.md` Steps 1–3.

## Request

| | |
|---|---|
| Key | `login` |
| Method | `POST` |
| Path | `/shield/admin/v3/login` |
| Auth | none (`--no-auth`) |

```json
{ "password": "<password>", "type": "OPERATOR", "userName": "<10-digit mobile>", "userConsent": true }
```

Driven through the skill, so credentials come from the environment and the
token is stored automatically:

```bash
export WE_API_MOBILE=...        # never commit these
export WE_API_PASSWORD=...
.claude/skills/apiCheck/scripts/api_action.sh login
```

`userConsent: true` is the API-side equivalent of the WhatsApp/SMS/calls
consent checkbox that is ticked by default on the login screen.

## Response validation

```bash
.claude/skills/apiCheck/scripts/api_action.sh assert-status 200
.claude/skills/apiCheck/scripts/api_action.sh assert-json success true
```

The token path is configurable via `apiLoginTokenPath` in
`config.properties` (default `data.token`). If `login` reports that no token
was found at that path, inspect the body with `api_action.sh body --pretty`
and correct the setting — don't hardcode a token in a doc.

## ⚠️ Rate limited — prefer reusing the app's token

Repeated attempts lock the account out. Observed response during setup:

```
HTTP/2 401
{"message":"You have reached maximum login attempts, wait till 15 minutes before trying again",
 "errorCode":"401","success":false}
```

This is a real backend response, not a bad credential. Because the test
account is shared, a run that logs in every time can lock out everyone else
for 15 minutes. **Default to reusing the token the app already holds:**

```bash
.claude/skills/apiCheck/scripts/api_action.sh token-from-device com.wheelseyeoperator.debug
```

That also guarantees the API and the UI are the same session and the same
account — which is the entire premise of a UI-vs-API comparison.

## UI Mapping

None. Login exchanges credentials for a token; nothing in the response is
rendered directly. Verify the *UI* login flow through `flow/loginFlow.md`,
and use this endpoint only to obtain auth for the checks that follow.

## Notes

- The `x-app-state: LATEST` / `x-app-reason` response headers report whether
  the `X-APP-VERSION` sent in `api/headers.properties` is still considered
  current. A forced-upgrade screen in the app usually traces back to these.
- The 401 above arrives with `success: false` in the body — assert both the
  status and the envelope flag; neither alone is sufficient.
