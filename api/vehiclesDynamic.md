# Vehicles — Dynamic (live telemetry)

Live per-vehicle data behind each card on the **Vehicles** tab: speed,
ignition state, last known address, distance covered, last-updated time
(see `flow/gpsListingFlow.md` Steps 2–4).

## Request

| | |
|---|---|
| Key | `vehiclesDynamic` |
| Method | `POST` |
| Path | `/rest/argus/app/vehicles-dynamic` |
| Body | `{"vehicleIds":[3320966,3341520]}` |
| Auth | required (`token:` header + `user-code`) |

```bash
.claude/skills/apiCheck/scripts/api_action.sh post vehiclesDynamic '{"vehicleIds":[3320966,3341520]}'
```

Vehicle ids are inputs, not outputs of this call — take them from whichever
listing call populated the screen, or reuse known ids for the test account.

## Response

`data` is a **map keyed by vehicle id**, not an array — use `data.*.<field>`
for all vehicles or `data.<id>.<field>` for one:

```json
{
  "message": "ok",
  "success": true,
  "data": {
    "3341520": {
      "displayTime": "Today, 11:38 AM",
      "sanitizedDistance": 1.0,
      "speed": 86.0,
      "ignitionState": "On",
      "mode": "DRIVING",
      "addr": "SERVICE ROAD, SIDHRAWALI, GURGAON, HARYANA, 122413, INDIA",
      "latitude": 28.2557, "longitude": 76.8238,
      "gsm": "64%", "volt": "2%",
      "moving": false, "parkLockActive": false
    }
  }
}
```

## Response validation

```bash
.claude/skills/apiCheck/scripts/api_action.sh assert-status 200
.claude/skills/apiCheck/scripts/api_action.sh assert-json success true
.claude/skills/apiCheck/scripts/api_action.sh assert-fields data speed ignitionState addr displayTime
.claude/skills/apiCheck/scripts/api_action.sh assert-count data "=2"
.claude/skills/apiCheck/scripts/api_action.sh assert-type data.3341520.speed number
```

`assert-fields data ...` checks every vehicle in the map carries those fields
non-null — the cheapest guard against a partially-populated payload rendering
as a blank card.

## UI Mapping

Checked against a **single vehicle card**. Scroll that card into view first
(`appium_action.sh scroll-to "<plate>"`), then anchor each comparison so it
can't match a neighbouring card:

| JSON path | UI element | `--normalize` | `--in` anchor |
|---|---|---|---|
| `data.<id>.speed` | speed on the card, e.g. `86 kmph` | `number` | `kmph` |
| `data.<id>.ignitionState` | `Ignition ON` / `OFF` | `text` | `Ignition` |
| `data.<id>.addr` | last known address line | `text` | *(unique enough)* |
| `data.<id>.displayTime` | timestamp under the plate | `raw` | *(unique enough)* |
| `data.<id>.sanitizedDistance` | `N km today` | `number` | `today` |

```bash
.claude/skills/apiCheck/scripts/api_action.sh compare-ui data.3341520.speed --normalize number --in "kmph" --label "Card speed == API speed"
.claude/skills/apiCheck/scripts/api_action.sh compare-ui data.3341520.ignitionState --normalize text --in "Ignition" --label "Card ignition == API ignitionState"
.claude/skills/apiCheck/scripts/api_action.sh compare-ui data.3341520.addr --normalize text --label "Card address == API addr"
```

## Notes

- **Only the rendered card can be compared.** Compose keeps roughly the
  visible window of a `LazyColumn` in the hierarchy, so comparing all ~85
  vehicles against one screen fails by design. Scroll to the vehicle, or use
  `compare-ui-list ... --limit 3`.
- **`speed` is a float** (`86.0`) while the card shows `86` — `--normalize
  number` handles that; `raw` will not.
- **`ignitionState` is `"On"`/`"Off"`** while the card renders `ON`/`OFF`
  inside a merged Compose node such as `Ignition ON` — `--normalize text`
  does the case-insensitive substring match.
- **Live data moves between the call and the read.** A vehicle doing 86 kmph
  can legitimately report a different speed seconds later. Call the API
  immediately before reading the screen, and treat a near-miss on `speed`
  as staleness rather than a defect — `addr`, `ignitionState` and
  `displayTime` are the stabler comparisons.
- **Masked balances** (FASTag/diesel) on these cards are blurred in the UI by
  design — assert on the labels/links, never the numbers. See
  `application/known-behaviors.md`.
