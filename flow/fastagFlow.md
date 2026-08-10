# FasTag Flow

This document describes the FasTag tab on the Home page (see `flow/homePage.md`) in the WheelsEye Operator app — the all-bank recharge shortcut, buy/replace/refunds/debit shortcuts, wallet balance, and the IDFC/Other FASTag listing, with the first listed vehicle validated against the backend rather than hardcoded.

## Precondition

User must be logged in first — complete `flow/userLogin.md` before this flow's steps.

The API step below needs a session token for the **same account** the app is logged in as. `testUserOne` is `WE25622`, so:

```
.claude/skills/apiCall/scripts/api_action.sh auth production WE25622
```

## Step 1: FasTag tab

The user taps the "FasTag" tab (next to "Vehicles" in the Home page tab row). This opens the FasTag home screen.

![Step 1](<../screenshots or figma Links/fastagFlow/Step 1.png>)

**Assertions:**
- `contains "FasTag"`
- `contains "Vehicles"`

## Step 2: All bank FASTag recharge section

The "All bank FASTag recharge" section is displayed, with a vehicle-number input field and a "Recharge" button. Same screen as Step 1 — no new action. Note the section header itself reads "FASTag" in all-caps, distinct from the "FasTag" tab label.

**Assertions:**
- `contains "All bank FASTag recharge"`
- `contains "Recharge"`

## Step 3: Buy new Tag / status chip / My Refunds / monthly Debit chip

Below the recharge section, "Buy new Tag", a second status chip, "My Refunds", and a monthly-debit chip (a calendar-icon chip, shown in the screenshot as "Aug Debit" — this label is month-dependent since it's tied to the current month, so it's documented generically here as "the current month's Debit chip, e.g. \"Aug Debit\"" rather than asserting the literal current month text as static) are displayed. Same screen as Step 1 — no new action.

**The second chip's own text is not asserted — confirmed live to be unstable within minutes on the same account.** The original narrative called it "Replace"; a live pass on 10 Aug 2026 (account `WE25622`) found "Activate" (with a pending-count badge, e.g. "Activate 94") and **no** "Replace" text anywhere. A second live pass minutes later found the opposite: "Replace" present, "Activate" gone. Both are real, reproducible observations on the same account in the same short window — this looks like a badge that flips based on some account/queue state this doc doesn't have visibility into, not a stale screenshot or selector drift. Asserting either specific label would make this step flaky, so only the two stable chips ("Buy new Tag", "My Refunds") are asserted; a future pass that identifies the actual toggling condition should replace this note with a real explanation.

**Assertions:**
- `contains "Buy new Tag"`
- `contains "My Refunds"`

## Step 4: Wallet Balance row

A "Wallet Balance" row with an "Add" button is displayed. Same screen as Step 1 — no new action. The screenshot shows "Wallet Balance: ₹2239.0" with a "+ Add" button; the balance is account data that changes, so only the label and button are asserted, not the numeric value.

**Assertions:**
- `contains "Wallet Balance"`
- `contains "Add"`

## Step 5: IDFC / Other tabs and IDFC FASTags list

"IDFC" and "Other" tabs/chips are displayed (shown in the screenshot as "IDFC (50)" and "Other (16)" — only the label prefix is asserted, not the count, since the count is fleet data that changes). Below them, an "IDFC FASTags" section lists the vehicles under that tab. Same screen as Step 1 — no new action.

**Assertions:**
- `contains "IDFC ("`
- `contains "Other ("`
- `contains "IDFC FASTags"`

## Step 6: Fetch the FasTag vehicle listing from the backend

```
CALL_API fastagHomeComponent
```

No UI interaction beyond what's already on screen from Step 5. Binds the response into the runtime context — see `api/contracts/fastagHomeComponent.md` for the exact variable names and response shape.

**Assertions:** none — checked as part of the call itself (a non-2xx/non-success response fails this step directly, same convention as `flow/gpsListingFlow.md`'s `CALL_API getAllFilterCount` step).

## Step 7: The API's first vehicle is present somewhere in the IDFC list

The vehicle number is dynamic fleet data, not a fixed on-screen string — the check is whether the vehicle the backend returns as `list[0]` is present *anywhere* in the "IDFC FASTags" section, scrolling down through the list if it isn't visible without scrolling. It is **not** required to be the first-rendered card.

Scroll down through the "IDFC FASTags" section (if needed) to find `${api.componentData.list.0.vehicleNumber}`.

**Assertions:**
- `contains "${api.componentData.list.0.vehicleNumber}"` (found anywhere in the IDFC section, scrolling as needed)

**Verified live 10 Aug 2026 (account `WE25622`):** `api.componentData.list.0.vehicleNumber` resolved to `UP11Q1112`. The screen's first-rendered IDFC card (no scrolling) was a different vehicle, `UP44AS4444` — the backend's `pageNo=1` list order does not match the UI's render order (which may sort by a different key, e.g. balance/urgency). `UP11Q1112` **was found** after scrolling down through the IDFC section — confirming the backend's first vehicle genuinely is present in the list, just not in first position. This step's assertion is written to match that reality (presence, not position).
