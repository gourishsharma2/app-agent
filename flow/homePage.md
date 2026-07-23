# Home Page

This document describes the Home page of the WheelsEye ("operator") mobile app, the screen the user lands on after logging in (see `flow/loginFlow.md`).

## Step 1: Home page (FasTag tab)

The Home page opens by default on the **FasTag** tab. The top bar shows a hamburger menu icon, the WheelsEye logo/name, a "Help" button, and a language toggle icon. Below it is a tab row: **FasTag** (selected), **Vehicles**, **Diesel**, **LOADS**.

The FasTag tab body contains, top to bottom:
- An "All bank FASTag recharge" card with a vehicle-number input field, a "Recharge" button, and a row of bank logos.
- Two quick-action rows: "Buy new Tag" / "Replace" (with a pending-count badge), and "My Refunds: ₹0" / "Jul Debit: ₹0".
- A "Wallet Balance" card showing the current balance (e.g. ₹1848.0) and an "Add" button.
- A FASTag-list section with sub-tabs for grouping by issuing bank, e.g. "IDFC (50)" / "Other (16)", followed by the list itself ("IDFC FASTags") showing each tag's vehicle number, balance, and a "Recharge" button.
- A sticky bottom summary bar showing total pending payment (e.g. "₹467,278 / 5 Pending Payment") with a "View & pay" button.

The bottom navigation bar has five tabs: Wallet, Learn, **Home** (selected), Notification, Help.

![Step 1](<../screenshots or figma Links/homePage/Step 1.png>)

**Assertions:**
- `contains "FasTag"`
- `contains "Vehicles"`
- `contains "Diesel"`
- `contains "LOADS"`
- `contains "Wallet Balance"`
- `contains "IDFC FASTags"`
- `contains "View & pay"`
- `contains "Home"` (bottom nav, selected tab)
