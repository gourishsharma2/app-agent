# Vehicle Filter Count

Backs the filter chips at the top of the **Vehicles** tab — **All (N)**,
**Running (N)**, **Stopped (N)** (see `flow/gpsListingFlow.md` Step 1).

## Request

| | |
|---|---|
| Key | `vehicleFilterCount` |
| Method | `GET` |
| Path | `/argus/app/vehicles/getAllFilterCount` |
| Body | none |
| Auth | required (`token:` header + `user-code`) |

```bash
.claude/skills/apiCheck/scripts/api_action.sh get vehicleFilterCount
```

## Response

```json
{
  "message": "ok",
  "success": true,
  "serverTime": 1785263129,
  "data": { "running": 2, "stoppage": 2, "noInfo": 81 }
}
```

There is **no `all` field** — the All chip is the sum of the three.
`noInfo` is the "Non Wheelseye GPS" / no-recent-data population described in
`application/known-behaviors.md`, which is why it dominates the total.

## Response validation

```bash
.claude/skills/apiCheck/scripts/api_action.sh assert-status 200
.claude/skills/apiCheck/scripts/api_action.sh assert-header content-type application/json
.claude/skills/apiCheck/scripts/api_action.sh assert-json success true
.claude/skills/apiCheck/scripts/api_action.sh assert-type data.running number
.claude/skills/apiCheck/scripts/api_action.sh assert-type data.stoppage number
.claude/skills/apiCheck/scripts/api_action.sh assert-type data.noInfo number
```

## UI Mapping

Checked against the Vehicles tab. Every numeric comparison is anchored — the
chips can legitimately share a number (`Running (2)` and `Stopped (2)` were
both 2 when this doc was written), and an unanchored check would pass against
the wrong chip.

| JSON path | UI element | `--normalize` | `--in` anchor | Status |
|---|---|---|---|---|
| `data.running` | **Running (N)** chip | `number` | `Running` | ✅ verified live 29 Jul 2026 |
| `data.stoppage` | **Stopped (N)** chip | `number` | `Stopped` | ✅ verified live 29 Jul 2026 |
| — | **All (N)** chip | — | — | ❌ **source unknown** — see below |

```bash
.claude/skills/apiCheck/scripts/api_action.sh compare-ui data.running --normalize number --in "Running" --label "Running chip == API running count"
.claude/skills/apiCheck/scripts/api_action.sh compare-ui data.stoppage --normalize number --in "Stopped" --label "Stopped chip == API stoppage count"
```

### The All chip does NOT come from this endpoint

The obvious assumption — that **All** is `running + stoppage + noInfo` — was
tested against the live app on 29 Jul 2026 and **is wrong**:

| | Value |
|---|---|
| API `data.running` | 2 |
| API `data.stoppage` | 2 |
| API `data.noInfo` | 81 |
| Sum of the three | **85** |
| **All** chip on screen | **95** |

Running and Stopped matched exactly at the same moment, so this is not a
staleness or account mismatch — the app sources the total from somewhere
else, and ~10 vehicles fall outside all three categories (plausibly ones with
no WheelsEye device at all; see "Non Wheelseye GPS" in
`application/known-behaviors.md`).

`api_action.sh sniff com.wheelseyeoperator` did not reveal the endpoint —
this build's HTTP client doesn't log request URLs — so identifying it needs
either a proxy capture (mitmproxy/Charles) or a pointer from the backend
team. **Until then, do not assert the All count against this endpoint.**
Asserting it with a `sum()` produces a red run that blames the app for a
wrong mapping in this doc.

Once the real source is known, add it to `endpoints.properties`, give it its
own contract doc, and map the All chip there.

## Notes

- The counts move as the fleet moves. That is exactly why they should never be
  asserted as literals in a flow doc — compare them to this endpoint instead.
- If the **All** comparison fails while Running and Stopped pass, the app is
  probably composing the total from a different source than these three
  fields; confirm against a fresh `sniff` before filing it as a bug.
