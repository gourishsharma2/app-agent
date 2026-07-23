# Login

Authentication mechanics of the Operator app. For the step-by-step UI flow with screenshots, see `flow/loginFlow.md`.

## Login methods
The login screen ("Login to your account") offers three ways in:
1. **OTP** — enter phone number, tap "Send OTP", enter the OTP on the next screen. Not yet driven/documented step-by-step.
2. **Password** — enter phone number, tap "Continue with password", enter password, tap "Login". This is the path currently documented in `flow/loginFlow.md` (Steps 1–3).
3. **One Tap Login** — a button on the login screen for a passwordless/pre-authenticated shortcut. Not yet explored.

Other elements on the login screen: a WhatsApp/SMS/calls consent checkbox (checked by default), a "Forgot phone number?" link, the Staging/Production environment toggle (see `application/environments.md`), and a "Don't have an account? Signup" link — account creation is out of scope for this project since it automates the Operator app for existing operators, not onboarding.

## Post-login prompts
Immediately after a successful login, two dialogs can appear stacked, both of which must be dismissed before the Home page is usable:
1. A standard Android "Allow WheelsEye to send you notifications?" permission prompt.
2. An "Unauthenticated App Detected" dialog (app-level), warning that the build wasn't installed from the Play Store, with an "Okay" button. Expected for sideloaded/debug builds — see `application/known-behaviors.md`.

## Landing screen
After both prompts are dismissed, the user lands on the Home page, opened by default on the **FasTag** tab. See `application/navigation.md`.

## Test credentials
See `application/test-data.md`.
