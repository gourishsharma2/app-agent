# fastagHomeComponent

The vehicle list behind the **FasTag** tab's IDFC/Others recharge sections (see
`flow/fastagFlow.md`) — one row per vehicle with a FASTag, its balance state,
and which bank issued the tag (`bi` icon URL). Requested with a fixed
`VEHICLE_LISTING`/`HAS_FASTAG` component/userType pair — this same endpoint
likely backs other FasTag-home components too, not modelled here.

## Request

| | |
|---|---|
| Path key | `fastagHomeComponent` |
| Method | `POST` |
| Path | `/rest/cyborg/app/fastag/home/component` |
| Body | fixed JSON (below) — `spId`/`pageNo`/`pageSize` are the only fields expected to vary per call |
| Auth | required — `token` + `user-code` runtime headers |

```
CALL_API fastagHomeComponent
```

```json
{
  "component": "VEHICLE_LISTING",
  "userType": "HAS_FASTAG",
  "params": {
    "spId": 13,
    "pageNo": 1,
    "pageSize": 5,
    "searchText": "",
    "service": null
  }
}
```

`spId: 13` was captured live alongside every vehicle in the response also
carrying `spId: 13` — not yet confirmed whether this is a fixed service-provider
id or one that must be read from elsewhere per account; treat as fixed until
disproven.

## Response

The backend double-wraps the envelope exactly like `vehiclesStatic` — `data`
is itself another `{message, success, serverTime, ...}` envelope, one level
deeper than usual because it's nested under `componentData`:

```json
{
  "message": "OK",
  "success": true,
  "serverTime": 1786359774,
  "data": {
    "componentName": "VEHICLE_LISTING",
    "componentData": {
      "message": "OK",
      "success": true,
      "serverTime": 1786359774,
      "pageNo": 1,
      "pageSize": 5,
      "totalPages": 10,
      "totalCount": 50,
      "list": [
        {
          "vehicleId": 1283043,
          "vehicleNumber": "UP11Q1112",
          "fastagAmount": 728.0,
          "tagId": 1480151,
          "fastagColor": "PINK",
          "tagClass": 12,
          "autoRecharge": false,
          "minBalance": 1000.0,
          "highlight": false,
          "isSmartEligible": false,
          "ctaText": "Recharge",
          "ts": "LOW_BALANCE",
          "tsText": "Low Balance",
          "bi": "https://wheelseye.com/static-content/new_structure/operator/fastag/img/FT_bbpsBank_IDFC.png",
          "spid": 13,
          "spId": 13,
          "fcsv": false,
          "tagBalMsg": "Balance",
          "ib": false,
          "lb": false
        }
      ]
    }
  }
}
```

Verified live 10 Aug 2026 on account `WE25622` (production): `totalCount: 50`
across the fleet, `pageSize=5` returned 5 vehicles, first vehicle's `bi` icon
URL ends in `FT_bbpsBank_IDFC.png` — an IDFC-issued tag.

## Context variables produced

Binding unwraps only the **outer** envelope (same rule as every other
endpoint) — `componentData` is *not* auto-unwrapped a second level, so the
inner envelope's own fields (`pageNo`, `totalCount`, `list`, ...) sit under
`api.componentData.*`, not directly on `api.*`:

| Variable | From | Type |
|---|---|---|
| `api.componentName` | `data.componentName` | string — `"VEHICLE_LISTING"` |
| `api.componentData.totalCount` | `data.componentData.totalCount` | number |
| `api.componentData.pageNo` / `.pageSize` / `.totalPages` | pagination | number |
| `api.componentData.list` | `data.componentData.list` | array |
| `api.componentData.list.0.vehicleNumber` | first vehicle in the list | string |
| `api.componentData.list.<N>.vehicleNumber` | `N`th vehicle (literal integer index only — see `vehiclesStatic.md`'s "No dynamic last-index") | string |
| `api.componentData.list.0.bi` | first vehicle's bank icon URL | string — ends `FT_bbpsBank_IDFC.png` for an IDFC tag |
| `api.success` | envelope | boolean |
| `api._raw.data.componentData.list` | full response, unmodified | array |

## UI mapping

| Variable | UI element | Notes |
|---|---|---|
| `api.componentData.list.0.vehicleNumber` | First vehicle card under the **IDFC** fastags section | Anchor comparison here — matches `flow/fastagFlow.md` Step 6 |
| `api.componentData.list.0.bi` containing `IDFC` | Which bank tab (**IDFC** vs **Others**) the vehicle should render under | Not yet confirmed whether every vehicle in this response is IDFC, or the UI itself splits by bank from a single combined list — confirm live per `flow/fastagFlow.md`'s own convention of never trusting an assumption over a live check |

## Notes

- `pageSize=5` was requested and returned exactly 5 rows out of `totalCount: 50`
  — unlike `vehiclesStatic`, this endpoint paginates normally rather than
  silently dropping the `data` field at larger page sizes; not yet tested
  above `pageSize=5`.
- `fastagAmount`/`minBalance` are masked/blurred on the vehicle card in the UI
  (see `application/known-behaviors.md`'s masked-balance note) — assert on
  labels/links from this response (`vehicleNumber`, `bi`, `ctaText`), never on
  the numeric balance values themselves.
