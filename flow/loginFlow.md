# Login Flow

This document describes the step-by-step application login flow for the WheelsEye ("operator") mobile app.

## Step 1: App launch / login screen

Once the application is installed and launched, the "Login to your account" screen is displayed with a phone number field (pre-filled with the `+91` country code), a "Send OTP" button, and a "Continue with password" option below it. The screen also shows a WhatsApp/SMS/calls consent checkbox (checked by default), a "Forgot phone number?" link, a Staging/Production environment toggle, a "One Tap Login" option, and a "Don't have an account? Signup" link at the bottom.

![Step 1](<../screenshots or figma Links/loginFlow/Step 1.png>)

**Assertions:**
- `contains "Login to your account"`
- `contains "Phone number"`
- `contains "Send OTP"`
- `contains "Continue with password"`

## Step 2: Enter mobile number

The user enters his 10 digit mobile number in the phone number field (after the fixed `+91` prefix). Both "Send OTP" and "Continue with password" remain available below the field.

![Step 2](<../screenshots or figma Links/loginFlow/Step 2.png>)

**Assertions:**
- After typing the number, `source` shows the typed digits in the phone number field
- `contains "Send OTP"`
- `contains "Continue with password"`

## Step 3: Enter password

After entering the mobile number and tapping "Continue with password", the app navigates to a screen showing the phone number (read-only, with a back arrow to return to Step 1) and a "Password" field with a show/hide (eye) toggle, followed by a "Login" button and a "Create new password" link.

![Step 3](<../screenshots or figma Links/loginFlow/Step 3.png>)

**Assertions:**
- `contains "Phone number"`
- `contains "Password"`
- `contains "Login"` (the submit button)
- `contains "Create new password"`

## Step 4: Post-login prompts

After entering the correct password and tapping "Login", the app lands on the Home screen but immediately shows a system "Allow WheelsEye to send you notifications?" permission dialog (Allow / Don't allow), stacked on top of an "Unauthenticated App Detected" dialog warning that the app was not installed from the Play Store (with an "Okay" button). This second dialog is expected when the build is sideloaded (installed via APK) rather than from the Play Store — see `application/known-behaviors.md`.

![Step 4](<../screenshots or figma Links/loginFlow/Step 4.png>)

**Assertions:**
- `contains "Allow WheelsEye to send you notifications?"`
- `contains "Unauthenticated App Detected"`

## Step 5: Home page

After dismissing the notification permission dialog (Allow/Don't allow) and the "Unauthenticated App Detected" dialog (Okay), the user lands on the Home page, opened by default on the "FasTag" tab (other tabs: Vehicles, Diesel, LOADS). The screen shows the wallet balance, the user's FASTags list, and a bottom navigation bar with Wallet, Learn, Home, Notification, and Help.

![Step 5](<../screenshots or figma Links/loginFlow/Step 5.png>)

**Assertions:**
- `contains "FasTag"`
- `contains "Wallet Balance"`
- `contains "Home"` (bottom nav)
