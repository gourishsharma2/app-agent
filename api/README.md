# API layer

Backend contracts for the WheelsEye Operator app, and how the data they
return is checked against what the app displays.

This directory is to APIs what `flow/` is to screens: **the documented
contract is the source of truth**, and the `apiCheck` skill drives it live.
Nothing here is test code — same as the rest of the repo.

## Files

| File | Purpose |
|---|---|
| `endpoints.properties` | endpoint key → path. Docs and commands reference `vehicleFilterCount`, never a raw URL. |
| `headers.properties` | the static headers the app sends on every call (app version, platform, `user-code`, device ids). |
| `<endpoint>.md` | one contract doc per endpoint: request, expected response, and a **UI Mapping** table. |

Base URL, auth header shape, timeouts and login settings live in
`config.properties` at the project root, under the `apiCheck` block.

## The contract doc format

Each `api/<endpoint>.md` has three sections, and the third is the one that
matters most:

1. **Request** — method, endpoint key, body (if any), what auth it needs.
2. **Response validation** — the `assert-*` calls that must pass on the
   response itself: status, headers, envelope fields, types, counts.
3. **UI Mapping** — a table of `JSON path → what the user sees → normalizer →
   anchor`. This is the declarative bridge between backend and screen, and it
   is deliberately a table rather than code so it reads like the
   **Assertions** lists already used throughout `flow/*.md`.

A flow or test doc then references the contract instead of restating it:

```markdown
### Step 1: Open the Vehicles tab

**API Validations:** see `api/vehicleFilterCount.md` — all rows of its UI
Mapping table must pass against this screen.
```

## Why the expected values come from the API, not the doc

The existing UI assertions hardcode data: `contains "All (94)"`,
`contains "Running (1)"`. Those numbers were true the day the screenshot was
taken. The fleet now reports 85 / 2 / 2, so those assertions fail — and they'd
fail identically whether the app is broken or the fleet simply changed. The
test can't tell the difference.

Sourcing the expected value from the API separates the two questions:

- **Is the app rendering the backend's data correctly?** → `compare-ui`
- **Is the backend's data itself sane?** → `assert-*` on the response

A count that changes daily is no longer a broken test; a count that disagrees
with the backend is a real bug. Keep hardcoded `contains` assertions for
static chrome (labels, button text, tab names) and use API comparison for
anything data-driven.

## Auth

Every call except `login` needs a session token. Preferred route — reuse the
token the app itself is logged in with, so the UI and the API are provably the
same session and account:

```bash
.claude/skills/apiCheck/scripts/api_action.sh token-from-device com.wheelseyeoperator.debug
```

Alternatives are `set-token <token>` and `login` (rate-limited — see below).
Tokens are stored in `.claude/skills/apiCheck/.auth_state`, chmod 600 and
gitignored. **No credential or token belongs in any committed file.**

`user-code` in `headers.properties` selects the operator account. It must
match the account the app is logged in as, or you are comparing two different
fleets.

## Known backend behaviors

- **Login is rate-limited.** After a handful of attempts
  `/shield/admin/v3/login` returns `401` with
  `"You have reached maximum login attempts, wait till 15 minutes before
  trying again"` — a real response observed during setup, not a bad
  credential. This is why runs should reuse the app's token rather than
  logging in each time.
- **Responses use a common envelope**: `{ message, success, serverTime, data }`.
  `success: false` can accompany a non-2xx status, so assert both.
- **`vehicles-dynamic` returns a map keyed by vehicle id**, not an array —
  use `data.*.<field>` or `data.<id>.<field>` in JSON paths.
- **`getAllFilterCount` has no "all" field.** The **All (N)** chip is
  `running + stoppage + noInfo`; express that as
  `sum(data.running,data.stoppage,data.noInfo)` rather than hardcoding it.
- **`x-app-state` / `x-app-reason` response headers** report whether the
  calling `X-APP-VERSION` is considered current (`LATEST`). Worth asserting
  when testing version-gated behavior.

## Adding a new endpoint

1. Capture it — `api_action.sh sniff com.wheelseyeoperator.debug` prints the
   URLs the running app has actually hit. (If the build's HTTP client doesn't
   log URLs, capture with an HTTPS proxy such as mitmproxy/Charles, with the
   emulator's proxy pointed at it and the CA cert installed.)
2. Add the key to `endpoints.properties`.
3. Call it once and inspect: `api_action.sh get <key>` then
   `api_action.sh body --pretty`.
4. Write `api/<key>.md` with the three sections above.
5. Reference it from the flow/test doc's **API Validations** section.

Never add a new raw `curl` command to do any of this — extend
`api_action.sh` instead. See `.claude/skills/apiCheck/SKILL.md` for why.
