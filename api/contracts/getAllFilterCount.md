# getAllFilterCount

Counts behind the filter chips at the top of the **Vehicles** tab — Running,
Stopped, No Info (see `flow/gpsListingFlow.md`).

## Request

| | |
|---|---|
| Path key | `getAllFilterCount` |
| Method | `GET` |
| Path | `/argus/app/vehicles/getAllFilterCount` |
| Body | none |
| Auth | required — `token` + `user-code` runtime headers |

```
CALL_API getAllFilterCount
```

## Response

```json
{
  "message": "ok",
  "success": true,
  "serverTime": 1785740487,
  "data": {
    "running": 0,
    "stoppage": 2,
    "noInfo": 79
  }
}
```

## Context variables produced

Binding to the default `api` namespace unwraps `data`, so a flow references the
counts directly:

| Variable | From | Type |
|---|---|---|
| `api.running` | `data.running` | number |
| `api.stoppage` | `data.stoppage` | number |
| `api.noInfo` | `data.noInfo` | number |
| `api.success` | envelope | boolean |
| `api.message` | envelope | string |
| `api.serverTime` | envelope | number |
| `api._status` | HTTP status | number |
| `api._elapsedMs` | round trip | number |
| `api._raw.data.running` | full response, unmodified | number |

## UI mapping

| Variable | UI element | Notes |
|---|---|---|
| `api.running` | **Running (N)** chip | Anchor any comparison on `Running` — chips can share a number |
| `api.stoppage` | **Stopped (N)** chip | Anchor on `Stopped` |
| `api.noInfo` | No-info population | `noInfo` dominates the fleet; see `application/known-behaviors.md` |

## There is no `all` field — and the All chip is not the sum

The obvious assumption is that **All (N)** equals `running + stoppage + noInfo`.
That was tested against the live app on 29 Jul 2026 and it is **wrong**:

| | Value |
|---|---|
| `data.running` | 2 |
| `data.stoppage` | 2 |
| `data.noInfo` | 81 |
| Sum | **85** |
| **All** chip on screen | **95** |

Running and Stopped matched exactly at that same moment, so this is not
staleness or an account mismatch — the app sources the total elsewhere, and
about ten vehicles fall outside all three categories.

**Do not assert the All chip against this endpoint.** Doing so produces a red
run that blames the app for a wrong mapping in this file. Once the real source
is identified, register it in `paths.md` and give it its own contract doc.

## Notes

- The counts move as the fleet moves. That is the reason to compare against
  this endpoint rather than hardcode `contains "Running (2)"` in a flow doc: a
  count that changes daily is not a broken test, but a count that disagrees
  with the backend is a real bug.
- `running` can legitimately be `0`. A flow must therefore *skip* rather than
  fail its Running validation when there is nothing running — which is what
  the `IF api.running > 0` guard is for.
