# Production — API Paths

Path registry for the **production** backend. Flows reference the key, never a
URL.

Only the fenced ```properties block is parsed.

```properties
fetchUserDetail     = http://ums.prod-we.com/ums/v2/user/fetchDetail
login               = /shield/admin/v3/login
getAllFilterCount   = /argus/app/vehicles/getAllFilterCount
vehiclesStatic      = /rest/argus/app/vehicles/static
fastagHomeComponent = /rest/cyborg/app/fastag/home/component
```

`fetchUserDetail` is an absolute URL because UMS lives on a different host from
the app backend. A value starting with `http://` or `https://` is used verbatim
and `base_url` is ignored, which is what makes a multi-host environment
expressible without a second config file.

`fetchUserDetail` and `login` are the two endpoints that **produce**
credentials, so they are called with static headers only (`--no-auth`) — they
cannot depend on a token that does not exist yet. See `auth.md`.

## Adding an endpoint

1. Add one `key = /path` line above.
2. Optionally add `api/contracts/<key>.md`.
3. Reference it from a flow doc with `CALL_API <key>`.

No script changes. A key referenced by a flow but absent here fails at load
time listing the keys that do exist, rather than requesting a malformed URL.

Keep this file and `../stage/paths.md` in step — a key defined for only one
environment makes a flow that works in production fail at load in stage. The
loader reports that as a missing key, naming the environment.
