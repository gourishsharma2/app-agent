#!/usr/bin/env python3
"""
run_plan.py — the deterministic executor behind `appium_action.sh run-plan`.

Reads a compiled execution plan (see .claude/skills/compilePlan/SKILL.md for
the schema) and drives the whole flow in this ONE process: opens/reuses an
Appium session, dispatches every step's action(s) (tap/type/scroll/etc, the
same verbs appium_action.sh already exposes as subcommands), checks each
step's screenMarker + assertions against ONE page-source fetch, and stops the
instant something doesn't match reality instead of guessing. No LLM calls
happen anywhere in this file — that's the entire point of it. It prints
exactly one `PLAN_RESULT_JSON=<...>` line so the calling agent can parse the
outcome without re-deriving it, and leaves the Appium session open on exit
(divergence or clean finish) so a recovery pass or a `close-session` call can
still use it.

Before executing, `${mobileNumber}`/`${password}`/`${userCode}` tokens
anywhere in the plan's strings are substituted with values resolved by
`appium_action.sh` from `test-data/<environment>.properties` — this is what
lets one compiled plan serve every test user/environment without
recompiling.

Not meant to be invoked directly — always via:
    appium_action.sh run-plan <plan.json> [--from-step N] [--environment <Staging|Production>] [--test-user <name>]
"""
import json
import re
import subprocess
import sys
import time
import urllib.request
import urllib.error

SETTLE_SECONDS = 1.0
MARKER_POLL_TIMEOUT = 10
MARKER_POLL_INTERVAL = 1.0
RETRY_SETTLE_SECONDS = 1.5
MAX_TYPE_ATTEMPTS = 3
TYPE_VERIFY_SETTLE_SECONDS = 0.5
BOUNDS_RE = re.compile(r'bounds="(\[-?\d+,-?\d+\]\[-?\d+,-?\d+\])"')


def log(msg):
    print(msg, file=sys.stderr)


def http(method, url, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method,
                                  headers={"Content-Type": "application/json"} if data else {})
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read().decode())


def adb(serial, *args):
    subprocess.run(["adb", "-s", serial, "shell", *args], check=False,
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


class Divergence(Exception):
    def __init__(self, reason, detail):
        self.reason = reason
        self.detail = detail


class PlanExecutor:
    def __init__(self, appium_url, device_serial, session_id):
        self.appium_url = appium_url
        self.device_serial = device_serial
        self.session_id = session_id
        self._width = None
        self._height = None

    def source(self):
        return http("GET", f"{self.appium_url}/session/{self.session_id}/source")["value"]

    def window_rect(self):
        if self._width is None:
            v = http("GET", f"{self.appium_url}/session/{self.session_id}/window/rect")["value"]
            self._width, self._height = v["width"], v["height"]
        return self._width, self._height

    def bounds_center(self, bounds_str):
        (x1, y1), (x2, y2) = (
            tuple(int(n) for n in part.split(","))
            for part in re.findall(r"\[(-?\d+,-?\d+)\]", bounds_str)
        )
        return (x1 + x2) // 2, (y1 + y2) // 2

    def find_selector(self, page, selector):
        for line in page.splitlines():
            if selector in line:
                m = BOUNDS_RE.search(line)
                if m:
                    return self.bounds_center(m.group(1))
        return None

    def tap_xy(self, x, y):
        http("POST", f"{self.appium_url}/session/{self.session_id}/actions", {
            "actions": [{"type": "pointer", "id": "finger1", "parameters": {"pointerType": "touch"},
                         "actions": [
                             {"type": "pointerMove", "duration": 0, "x": x, "y": y},
                             {"type": "pointerDown", "button": 0},
                             {"type": "pause", "duration": 100},
                             {"type": "pointerUp", "button": 0},
                         ]}]
        })

    def swipe(self, x1, y1, x2, y2, duration=450):
        adb(self.device_serial, "input", "swipe", str(x1), str(y1), str(x2), str(y2), str(duration))

    def type_verified(self, text):
        """adb shell input text fires immediately with no guarantee the
        target field is actually focus-ready yet (e.g. right after a
        screen-navigation tap) — a slow transition can drop the first
        keystroke. Read back the live accessibility tree after typing and
        retry (clearing first) rather than trusting the injection blindly."""
        for attempt in range(1, MAX_TYPE_ATTEMPTS + 1):
            adb(self.device_serial, "input", "text", text)
            time.sleep(TYPE_VERIFY_SETTLE_SECONDS)
            if self._typed_text_landed(self.source(), text):
                return
            if attempt == MAX_TYPE_ATTEMPTS:
                raise Divergence("type-verify-failed", text)
            clear_count = max(30, len(text) * 2)
            adb(self.device_serial, "input", "keyevent", "123", *(["67"] * clear_count))
            time.sleep(0.3)

    def _typed_text_landed(self, page, text):
        if text in page:
            return True
        # A masked (password) field never exposes its literal text to the
        # accessibility tree, even when typing worked correctly — the node
        # is marked password="true" and its text is rendered as asterisks.
        # Fall back to comparing that masked value's character count against
        # the intended text's length instead of an exact match.
        for line in page.splitlines():
            if 'password="true"' in line:
                m = re.search(r'text="([^"]*)"', line)
                if m and len(m.group(1)) == len(text):
                    return True
        return False

    def directional_swipe(self, direction):
        w, h = self.window_rect()
        cx, cy = w // 2, h // 2
        table = {
            "down":  (cx, h * 82 // 100, cx, h * 22 // 100),
            "up":    (cx, h * 22 // 100, cx, h * 82 // 100),
            "left":  (w * 82 // 100, cy, w * 18 // 100, cy),
            "right": (w * 18 // 100, cy, w * 82 // 100, cy),
        }
        self.swipe(*table[direction])

    def run_action(self, action, page_hint):
        """Executes one action dict. Returns a fresh page source if it fetched
        one (scroll-to/wait-* do), else None — callers refetch as needed."""
        a_type = action["type"]

        if a_type == "tap":
            page = page_hint or self.source()
            xy = self.find_selector(page, action["selector"])
            if xy is None:
                raise Divergence("selector-not-found", action["selector"])
            self.tap_xy(*xy)

        elif a_type in ("double-tap", "long-press"):
            page = page_hint or self.source()
            xy = self.find_selector(page, action["selector"])
            if xy is None:
                raise Divergence("selector-not-found", action["selector"])
            x, y = xy
            if a_type == "long-press":
                duration = action.get("durationMs", 800)
                http("POST", f"{self.appium_url}/session/{self.session_id}/actions", {
                    "actions": [{"type": "pointer", "id": "finger1", "parameters": {"pointerType": "touch"},
                                 "actions": [
                                     {"type": "pointerMove", "duration": 0, "x": x, "y": y},
                                     {"type": "pointerDown", "button": 0},
                                     {"type": "pause", "duration": duration},
                                     {"type": "pointerUp", "button": 0},
                                 ]}]
                })
            else:
                self.tap_xy(x, y)
                time.sleep(0.08)
                self.tap_xy(x, y)

        elif a_type == "type":
            self.type_verified(action["text"])

        elif a_type == "back":
            adb(self.device_serial, "input", "keyevent", "4")

        elif a_type == "scroll":
            self.directional_swipe(action.get("direction", "down"))

        elif a_type == "scroll-to":
            return self._scroll_to(action)

        elif a_type == "wait-for":
            return self._wait(action["text"], action.get("timeoutSeconds", 30), want_present=True)

        elif a_type == "wait-until-gone":
            return self._wait(action["text"], action.get("timeoutSeconds", 30), want_present=False)

        else:
            raise Divergence("unknown-action-type", a_type)
        return None

    def _wait(self, text, timeout, want_present):
        elapsed = 0
        page = self.source()
        while elapsed < timeout:
            present = text in page
            if present == want_present:
                return page
            time.sleep(2)
            elapsed += 2
            page = self.source()
        raise Divergence("wait-timeout", text)

    def _scroll_to(self, action):
        selector = action["selector"]
        direction = action.get("direction", "down")
        max_scrolls = action.get("maxScrolls", 10)
        start_hint = action.get("startHint", 0)

        for _ in range(start_hint):
            self.directional_swipe(direction)
        page = self.source()
        if selector in page:
            action["_scrollsUsed"] = start_hint
            return page

        stuck = 0
        for i in range(1, max_scrolls + 1):
            self.directional_swipe(direction)
            time.sleep(1)
            new_page = self.source()
            if selector in new_page:
                action["_scrollsUsed"] = start_hint + i
                return new_page
            if new_page == page:
                stuck += 1
                if stuck >= 2:
                    raise Divergence("scroll-stuck", selector)
            else:
                stuck = 0
            page = new_page
        raise Divergence("scroll-not-found", selector)


def substitute_credentials(obj, creds):
    """Recursively replaces ${mobileNumber}/${password}/${userCode} tokens
    (see .claude/skills/compilePlan/SKILL.md) in every string leaf of a
    plan's dict/list tree with resolved values, so one compiled plan works
    for every test user/environment without recompiling."""
    if isinstance(obj, str):
        for key, val in creds.items():
            obj = obj.replace("${" + key + "}", val)
        return obj
    if isinstance(obj, list):
        return [substitute_credentials(item, creds) for item in obj]
    if isinstance(obj, dict):
        return {k: substitute_credentials(v, creds) for k, v in obj.items()}
    return obj


def check_assertions(page, assertions):
    return [{"text": a, "found": a in page} for a in assertions]


def run(plan, from_step, executor):
    steps = sorted(plan.get("steps", []), key=lambda s: s["id"])
    steps_run = []
    diverged_at = None

    for step in steps:
        if step["id"] < from_step:
            continue

        retries = step.get("retries", 1)
        actions = step.get("action")
        actions = [] if actions is None else (actions if isinstance(actions, list) else [actions])
        assertions = step.get("assertions", [])
        marker = step.get("screenMarker")
        known_non_bug = step.get("knownNonBug", False)

        attempt = 0
        last_error = None
        page_after_action = None
        while attempt < max(1, retries):
            attempt += 1
            try:
                for action in actions:
                    page_after_action = executor.run_action(action, page_after_action) or page_after_action
                if actions:
                    time.sleep(SETTLE_SECONDS)

                page = None
                if marker:
                    elapsed = 0.0
                    page = executor.source()
                    while marker not in page and elapsed < MARKER_POLL_TIMEOUT:
                        time.sleep(MARKER_POLL_INTERVAL)
                        elapsed += MARKER_POLL_INTERVAL
                        page = executor.source()
                    if marker not in page:
                        raise Divergence("screen-marker-not-found", marker)

                page = page or page_after_action or executor.source()
                results = check_assertions(page, assertions)
                missing = [r["text"] for r in results if not r["found"]]

                if missing and not known_non_bug:
                    raise Divergence("assertion-failed", ", ".join(missing))

                scrolls_used = None
                for action in actions:
                    if isinstance(action, dict) and "_scrollsUsed" in action:
                        scrolls_used = action["_scrollsUsed"]

                steps_run.append({
                    "id": step["id"], "status": "WARN" if missing else "PASS",
                    "assertions": results, "scrollsUsed": scrolls_used,
                })
                last_error = None
                break

            except Divergence as d:
                last_error = d
                if attempt < max(1, retries):
                    log(f"run-plan: step {step['id']} attempt {attempt} — {d.reason}: {d.detail} (retrying)")
                    time.sleep(RETRY_SETTLE_SECONDS)

        if last_error is not None:
            steps_run.append({"id": step["id"], "status": "FAIL",
                               "reason": last_error.reason, "detail": last_error.detail})
            diverged_at = {"stepId": step["id"], "reason": last_error.reason, "detail": last_error.detail}
            break

    overall = "DIVERGED" if diverged_at else "PASS"
    return {"flow": plan.get("flowName"), "overallStatus": overall,
            "stepsRun": steps_run, "divergedAt": diverged_at}


def open_session(appium_url, device_serial, app_package, app_activity):
    resp = http("POST", f"{appium_url}/session", {
        "capabilities": {"alwaysMatch": {
            "platformName": "Android",
            "appium:automationName": "UiAutomator2",
            "appium:deviceName": device_serial,
            "appium:udid": device_serial,
            "appium:appPackage": app_package,
            "appium:appActivity": app_activity,
            "appium:noReset": True,
            "appium:autoGrantPermissions": True,
            "appium:newCommandTimeout": 3600,
        }}
    })
    return resp["value"]["sessionId"] if isinstance(resp.get("value"), dict) else resp["sessionId"]


def main():
    (plan_path, from_step_str, appium_url, state_file, device_serial,
     mobile_number, password, user_code) = sys.argv[1:9]
    from_step = int(from_step_str)

    with open(plan_path) as f:
        plan = json.load(f)
    plan = substitute_credentials(plan, {
        "mobileNumber": mobile_number,
        "password": password,
        "userCode": user_code,
    })

    try:
        with open(state_file) as f:
            session_id = f.read().strip()
    except FileNotFoundError:
        session_id = open_session(appium_url, device_serial, plan["appPackage"], plan["appActivity"])
        with open(state_file, "w") as f:
            f.write(session_id)
        log(f"run-plan: opened session {session_id}")

    executor = PlanExecutor(appium_url, device_serial, session_id)

    try:
        result = run(plan, from_step, executor)
    except urllib.error.URLError as e:
        result = {"flow": plan.get("flowName"), "overallStatus": "DIVERGED",
                  "stepsRun": [], "divergedAt": {"stepId": from_step, "reason": "appium-unreachable", "detail": str(e)}}

    print("PLAN_RESULT_JSON=" + json.dumps(result))
    sys.exit(0 if result["overallStatus"] == "PASS" else 1)


if __name__ == "__main__":
    main()
