# Login Flow

This document describes the login flow of the WheelsEye Operator app — signing in with a phone number via OTP, or via `Continue with password`, before landing on the Home page (see `flow/homePage.md`).

## Precondition

None

## Step 1: Login screen — initial state

On successful launch, the user lands on the login screen. It shows the WheelsEye logo/wordmark at top-left with a "Call us" button and a change-language button at top-right, a "Login to your account" heading, a "Phone number" field (pre-filled with the "+91" country code), a "Send OTP" button, a "Continue with password" button, an "I agree to receive updates via WhatsApp, SMS, and calls." checkbox (checked by default), a "Forgot phone number?" link, a Staging/Production toggle, a "One Tap Login" option, and at the bottom "Dont have an account? Signup" text plus "By continuing, I agree to the terms & conditions and privacy policy." text.

![Step 1](<../screenshots or figma Links/loginFlow/Step 1.png>)

**Assertions:**
- `contains "Login to your account"`
- `contains "Phone number"`
- `contains "Send OTP"`
- `contains "Continue with password"`
- `contains "I agree to receive updates via WhatsApp, SMS, and calls."`
- `contains "Signup"`
- `contains "terms & conditions"`

(Note: the WheelsEye wordmark is a plain image with no `content-desc` — it's not present in the live accessibility tree, so it's not assertable and was dropped; confirmed live.)

## Step 2: Send OTP without entering a phone number

Without entering a phone number, the user taps the "Send OTP" button. Error messages are displayed in red — one for the phone number field and one general "please enter the details" style message. No screenshot captures this transient validation-error state; confirmed live during the compile pass.

**Assertions:**
- `contains "Phone number"`
- `contains "Please enter the details"`

## Step 3: OTP verification screen

After entering the phone number and tapping "Send OTP", the user is redirected to the OTP screen. It shows a back arrow at top-left, "Call us" and a change-language button at top-right, a "Verify your phone number" heading, a line of text indicating the OTP was sent to the entered phone number, 4 individual OTP entry boxes, a "Login" button, and a "Didn't receive OTP? Resend in ...s" option.

![Step 3](<../screenshots or figma Links/loginFlow/Step 3.png>)

**Assertions:**
- `contains "Call us"`
- `contains "Verify your phone number"`
- `contains "Enter the OTP sent to"`
- `contains "Login"`
- `contains "Didn't receive OTP?"` (live text uses a curly right single quote, U+2019)

## Step 4: Incorrect OTP entered

The user enters "1234" into the OTP boxes and taps the "Login" button. An error message is displayed in red. No screenshot captures this transient error state; confirmed live during the compile pass.

**Assertions:**
- `contains "Please enter the correct OTP"`

## Step 5: Continue with password — password screen

The user taps the back button, then taps "Continue with password" on the login screen. This opens the password screen, which shows a "Phone number" field (pre-filled with the entered phone number), a "Password" field, a "Login" button, and a "Create new password" link.

![Step 5](<../screenshots or figma Links/loginFlow/Step 4.png>)

**Assertions:**
- `contains "Phone number"`
- `contains "Password"`
- `contains "Login"`
- `contains "Create new password"`

## Step 6: Incorrect password entered

The user enters "qwerty" into the password field and taps "Login". An error message is displayed in red for the incorrect password; no screenshot captures that transient error state, but it was confirmed live during the compile pass.

**Assertions:**
- `contains "Incorrect UserName or Password"` (shown twice on screen, once per field)

## Step 7: Successful login — Home page

The user re-opens the password screen (back → "Continue with password"), enters the correct password, and taps "Login", redirecting to the Home page. The Home page shows the WheelsEye wordmark, a "Help" button, a change-language button, and a tab row with "FasTag", "Vehicles", "Diesel", and "LOADS" tabs ("FasTag" selected by default), along with a bottom navigation bar including a "Home" tab.

![Step 7](<../screenshots or figma Links/loginFlow/Step 6.png>)

**Assertions:**
- `contains "FasTag"`
- `contains "Vehicles"`
- `contains "Diesel"`
- `contains "Loads"` (all-caps "LOADS" rendering is CSS text-transform only; the real accessible string is title case)
- `contains "Home"`
