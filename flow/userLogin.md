# Login Flow

This document describes the login flow of the WheelsEye Operator app — signing in with a phone number via OTP, or via `Continue with password`, before landing on the Home page (see `flow/homePage.md`).

## Precondition

None

## Step 1: Login screen — initial state

On successful launch, the user lands on the login screen.

![Step 1](<../screenshots or figma Links/loginFlow/Step 1.png>)

**Assertions:**
- `contains "Phone number"`
- `contains "Send OTP"`
- `contains "Continue with password"`

## Step 2: Continue with password — password screen

The user taps "Continue with password" on the login screen. This opens the password screen, which shows a "Phone number" field (pre-filled with the entered phone number), a "Password" field, a "Login" button, and a "Create new password" link.

![Step 5](<../screenshots or figma Links/loginFlow/Step 4.png>)

**Assertions:**
- `contains "Phone number"`
- `contains "Password"`
- `contains "Login"`
- `contains "Create new password"`

## Step 3: Successful login — Home page

The user re-opens the password screen (back → "Continue with password"), enters the correct password, and taps "Login", redirecting to the Home page. The Home page shows the WheelsEye wordmark, a "Help" button, a change-language button, and a tab row with "FasTag", "Vehicles", "Diesel", and "LOADS" tabs ("FasTag" selected by default), along with a bottom navigation bar including a "Home" tab.

![Step 7](<../screenshots or figma Links/loginFlow/Step 6.png>)

**Assertions:**
- `contains "FasTag"`
