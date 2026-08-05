# Stage — API Paths

Path registry for the **stage** backend: a key that flows reference, mapped to
a path appended to `base_url` from `base_url.md`.

Flows and plans reference the **key** (`getAllFilterCount`), never a URL. When
a path moves, it moves here and nowhere else.

Only the fenced ```properties block is parsed.

```properties
fetchUserDetail   = http://ums.prod-we.com/ums/v2/user/fetchDetail
login             = /shield/admin/v3/login
getAllFilterCount = /argus/app/vehicles/getAllFilterCount
```

Kept in step with `../production/paths.md`, since a key defined for only one
environment makes a flow that works in production fail at load in stage.

A value starting with `http://`/`https://` is used verbatim and `base_url` is
ignored — that is how `fetchUserDetail` reaches UMS on a different host.

**`fetchUserDetail` points at the production UMS host here too.** That is not an
oversight but it is not verified either: no stage UMS host is known, and stage
`base_url` is itself a placeholder (see `base_url.md`). Confirm both before
trusting a stage run — a stage login against production-sourced credentials
would fail confusingly.

## Adding an endpoint

1. Add one `key = /path` line above.
2. Optionally add a contract doc at `api/contracts/<key>.md` describing the
   response shape and which UI element each field backs.
3. Reference it from a flow doc with `CALL_API <key>`.

No change to any script is needed — this is the extension point. A key that a
flow references but that is missing here fails at load time with the list of
keys that *are* defined, rather than issuing a request to a malformed URL.

Query strings are appended at call time (`CALL_API getAllFilterCount?x=1`),
so they don't belong in this file.
