# vehiclesStatic

The paginated list of vehicle cards behind the **Running**/**Stopped** filter
chips on the Vehicles tab (see `flow/gpsListingFlow.md`) — vehicle number, ID,
and the per-card bottom action row (Play Route / Route History / Share /
Parking Alarm). This is a different endpoint from `getAllFilterCount`, which
only returns the chip *counts*, not the vehicles themselves.

## Request

| | |
|---|---|
| Path key | `vehiclesStatic` |
| Method | `GET` |
| Path | `/rest/argus/app/vehicles/static` |
| Query | `filter`, `pageNo`, `pageSize` — appended at call time, e.g. `CALL_API vehiclesStatic?filter=DRIVING&pageNo=0&pageSize=50` |
| Body | none |
| Auth | required — `token` + `user-code` runtime headers |

```
CALL_API vehiclesStatic?filter=DRIVING&pageNo=0&pageSize=50
```

### `filter` values

Discovered live (5 Aug 2026) by tapping each chip and reading the
`v1_veh_filter_cta` analytics event fired alongside the request:

| Chip | `filter` value |
|---|---|
| Running | `DRIVING` |
| Stopped | `STOPPAGE` |

Cross-checked against `getAllFilterCount` at the same moment on account
`WE25622`: `filter=DRIVING` returned `totalCount: 0` matching `api.running: 0`,
and `filter=STOPPAGE` returned `totalCount: 2` matching `api.stoppage: 2`
exactly.

There is no confirmed value for the **All** chip — not needed by any flow yet,
and `getAllFilterCount`'s contract already documents that the All count isn't
a simple sum of the other filters, so a value shouldn't be guessed here.

## Response

The backend double-wraps the envelope — `data` is itself another
`{message, success, serverTime, ...}` envelope carrying the pagination fields
and the list:

```json
{
  "message": "ok",
  "success": true,
  "serverTime": 1785919264,
  "data": {
    "message": "ok",
    "success": true,
    "serverTime": 1785919264,
    "pageNo": 0,
    "pageSize": 10,
    "totalPages": 1,
    "totalCount": 2,
    "list": [
      {
        "vehicleId": 3320966,
        "vehicleNumber": "NL01ACC3479",
        "dummyName": null,
        "modelProductType": "GPS",
        "showVehicleDetails": true,
        "driverName": null,
        "driverNumber": null,
        "bottomMenuListItems": {
          "items": [
            { "key": "PLAY_ROUTE", "status": "ENABLE", "text": "Play route" },
            { "key": "HISTORY", "status": "ENABLE", "text": "Route History" },
            { "key": "SHARE", "status": "ENABLE", "text": "Share" },
            { "key": "PARKING", "status": "ENABLE", "text": "Parking Alarm" }
          ]
        }
      }
    ]
  }
}
```

## Context variables produced

Binding unwraps only the **outer** envelope (same rule as every other
endpoint), so the inner envelope's own `message`/`success`/`serverTime` keys
land directly on `api.*` too, alongside the pagination fields and the list:

| Variable | From | Type |
|---|---|---|
| `api.pageNo` | `data.pageNo` | number |
| `api.pageSize` | `data.pageSize` | number |
| `api.totalPages` | `data.totalPages` | number |
| `api.totalCount` | `data.totalCount` | number — vehicle count for this `filter` |
| `api.list` | `data.list` | array |
| `api.list.0.vehicleNumber` | first vehicle in the list | string |
| `api.list.<N>.vehicleNumber` | `N`th vehicle (integer index only — no negative/last-index support, see below) | string |
| `api.success` | envelope | boolean |
| `api._raw.data.list` | full response, unmodified | array |

## UI mapping

| Variable | UI element | Notes |
|---|---|---|
| `api.list.0.vehicleNumber` | First vehicle card's vehicle number | Anchor comparison here regardless of which chip (Running/Stopped) is active |
| `api.list.<N>.vehicleNumber` | Nth vehicle card's vehicle number | `N` must be a literal integer — see "No dynamic last-index" below |
| `bottomMenuListItems.items[].text` | Play Route / Route History / Share / Parking Alarm button labels on the card | UI almost certainly renders these labels verbatim from the API — still confirm live per `flow/gpsListingFlow.md`'s own convention of never trusting a screenshot/assumption over a live check |

## No dynamic last-index

`context_store.py`'s path resolver (`RuntimeContext.get`) only walks literal,
non-negative integer indices — no `-1`, no `length`, no arithmetic. A "last
card equals last API vehicle" assertion therefore **cannot** be written as
`api.list.<totalCount - 1>.vehicleNumber` generically. `flow/gpsListingFlow.md`
resolves this by having `flow-runner` bake in the literal index observed live
at compile time (e.g. `api.list.1.vehicleNumber` when `totalCount` is 2 for
that filter) — see that doc's Step 11. That index is a snapshot: if the vehicle
count for the active filter changes enough to shift which vehicle is last, the
plan diverges on a future run and needs recompiling, the same as any other
compiled-plan drift in this repo.

## Notes

- Request a `pageSize` comfortably larger than the expected `totalCount` for
  the filter being tested, so the whole result set lands in one `api.list` —
  avoids a second paginated call just to reach the last item. **Verified live
  5 Aug 2026 on account `WE25622`: `pageSize=10` returns the full envelope
  correctly (`totalCount`, `list`, etc.), but `pageSize=15`/`20`/`50` return a
  200 with `{message, success, serverTime}` and no `data` field at all** — a
  silent empty response, not an error. Use `pageSize=10` until this is
  investigated further; do not assume a larger `pageSize` is always safer.
- `dummyName`, `driverName`, `driverNumber`, `vehicleTags` were `null` for
  every vehicle seen in this account's live response; do not assume they're
  always populated.
