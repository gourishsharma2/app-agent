# Services Info

Feature flags and tab configuration the app fetches at startup. Determines
which tabs the Home screen shows and in what order (see `flow/homePage.md`).

## Request

| | |
|---|---|
| Key | `servicesInfo` |
| Method | `GET` |
| Path | `/rest/shield/app/services/info` |
| Body | none |
| Auth | required (`token:` header + `user-code`) |

```bash
.claude/skills/apiCheck/scripts/api_action.sh get servicesInfo
```

## Response (abridged)

```json
{
  "message": "Ok",
  "success": true,
  "data": {
    "tabSequence": ["FASTAG", "GPS", "FUEL", "LOAD"],
    "gps": false, "fastag": true, "rgps": true,
    "showDemand": true, "showDriverScore": true, "renewalDue": true,
    "notificationRefreshTime": 900, "locUpdateFreq": 300,
    "tabInfo": [{ "tab": "FASTAG", "displayName": "FASTag", "imageUrl": null }],
    "configurableContentDTO": { "accTab": "Account", "gpsPayNowCta": "Pay now" }
  }
}
```

## Response validation

```bash
.claude/skills/apiCheck/scripts/api_action.sh assert-status 200
.claude/skills/apiCheck/scripts/api_action.sh assert-json success true
.claude/skills/apiCheck/scripts/api_action.sh assert-type data.tabSequence array
.claude/skills/apiCheck/scripts/api_action.sh assert-count data.tabSequence "=4"
.claude/skills/apiCheck/scripts/api_action.sh assert-json "data.tabSequence[0]" FASTAG
```

## UI Mapping

The backend's tab codes are **not** the labels rendered on screen — the
mapping is `tabInfo[].displayName`, and the Home tab row reads
FasTag / Vehicles / Diesel / LOADS:

| JSON path | UI element | `--normalize` | `--in` anchor |
|---|---|---|---|
| `data.tabInfo[*].displayName` | Home tab row labels | `text` | — |
| `data.configurableContentDTO.accTab` | side-menu **Account** entry | `text` | — |
| `data.configurableContentDTO.gpsPayNowCta` | GPS renewal CTA button | `text` | — |

```bash
.claude/skills/apiCheck/scripts/api_action.sh compare-ui-list data.tabInfo displayName --normalize text --label "Home tabs match services/info"
```

## Notes

- `tabSequence` codes (`FASTAG`, `GPS`, `FUEL`, `LOAD`) map to the visible
  labels FasTag, **Vehicles**, **Diesel**, LOADS. Comparing the raw codes
  against the screen will fail — compare `tabInfo[].displayName` instead.
- `configurableContentDTO` is server-driven copy. Any flow doc that hardcodes
  one of these strings in a `contains` assertion will break the day marketing
  changes it — compare against this endpoint instead.
- `gps: false` alongside `rgps: true` for the test account: these are distinct
  entitlement flags, not a contradiction. Don't infer tab visibility from
  `gps` alone.
