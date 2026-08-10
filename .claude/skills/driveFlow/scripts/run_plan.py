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
still use it. The runtime context (api.*/flow.*/derived.* — see
context_store.py) is likewise persisted to `.plan_context.json` next to the
session state and reloaded whenever a `--from-step N` call reuses that same
session, so a resumed/recovery run sees the same values a single unbroken
process would have — not an empty context past the resume point.

`${...}` tokens anywhere in a step's strings are resolved against the runtime
context (see .claude/skills/apiCall/scripts/context_store.py) at the moment
that step runs — **not** in one pass before the flow starts. That change is
what makes API-driven execution possible: `${mobileNumber}` is known up front,
but `api.running` only exists once a `call-api` step earlier in the same run
has fetched it. Credentials are seeded into the context before step 1 and are
also mirrored at the top level, so every plan compiled before the context
existed keeps resolving exactly as it did.

A step may also carry a `when` predicate. It is evaluated against the context
before the step's actions run; a false predicate marks the step SKIP (with the
reason recorded) and execution continues with the next step. Predicates are
evaluated here, in code — no model call — so conditional flows keep the
zero-LLM guarantee this file exists to provide.

Not meant to be invoked directly — always via:
    appium_action.sh run-plan <plan.json> [--from-step N] [--environment <Staging|Production>] [--test-user <name>]
"""
import json
import os
import re
import subprocess
import sys
import time
import urllib.request
import urllib.error

# The API layer lives in its own skill; import it rather than duplicating the
# context/config/HTTP logic here.
_API_SCRIPTS = os.path.abspath(os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
    "..", "..", "apiCall", "scripts",
))
if _API_SCRIPTS not in sys.path:
    sys.path.insert(0, _API_SCRIPTS)

try:
    import config_loader
    import context_store
    import http_executor
    API_AVAILABLE = True
    API_IMPORT_ERROR = None
except ImportError as _e:  # apiCall skill absent — UI-only plans still run
    config_loader = context_store = http_executor = None
    API_AVAILABLE = False
    API_IMPORT_ERROR = str(_e)

PROJECT_ROOT = os.path.abspath(os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", ".."))
API_ROOT = os.path.join(PROJECT_ROOT, "api")
# Written by `api_action.sh auth` / `set-runtime`. Reading it here is what lets
# an out-of-band `auth` call supply the token for a plan run, instead of the
# token having to travel on a command line where `ps` would expose it.
API_CONTEXT_FILE = os.path.join(
    PROJECT_ROOT, ".claude", "skills", "apiCall", ".context.json")

# Written/read by THIS script only, next to the Appium session-id state file
# it already shares across invocations of the same run. `run()` executes in
# one process per invocation, so a plan driven straight through in one call
# never needs this — the context stays in memory the whole time. It only
# matters for a **resumed** `--from-step N` call (a local-recovery pass, or a
# divergence retry) reusing an already-open session in a fresh process: that
# process would otherwise start from an empty api.*/flow.*/derived.*
# namespace, so any `when` guard or `${api...}` token past the resume point
# fails as "not in context" even though the earlier call-api/set-context steps
# genuinely bound it moments ago in the prior process. Deleted alongside the
# session state file on `close-session` — see appium_action.sh — so a brand
# new session never inherits a stale one.
PLAN_CONTEXT_FILE = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", ".plan_context.json")

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
    def __init__(self, appium_url, device_serial, session_id,
                 context=None, api_env_name=None):
        self.appium_url = appium_url
        self.device_serial = device_serial
        self.session_id = session_id
        self.context = context
        self.api_env_name = api_env_name
        self._api_env = None
        self.api_calls = []
        self._width = None
        self._height = None

    def api_env(self):
        """Loads the API environment config once, on first use.

        Deliberately lazy: a UI-only plan must not fail because api/ is
        missing or an environment wasn't passed.
        """
        if self._api_env is None:
            if not API_AVAILABLE:
                raise Divergence(
                    "api-unavailable",
                    f"the apiCall skill could not be imported ({API_IMPORT_ERROR}); "
                    "a call-api step needs .claude/skills/apiCall/scripts/")
            if not self.api_env_name:
                raise Divergence(
                    "api-environment-missing",
                    "a call-api step needs an environment — pass environment=<name> "
                    "to /run (or --api-env to run-plan)")
            try:
                self._api_env = config_loader.load_environment(
                    self.api_env_name, API_ROOT)
            except config_loader.ConfigError as e:
                raise Divergence("api-config-error", str(e))
        return self._api_env

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

    def _resolve_tap_xy(self, action, page_hint):
        """Resolves a tap/double-tap/long-press action to (x, y).

        Most actions carry a text `selector`, resolved against the live
        accessibility tree. A coordinate action (`x`/`y` given directly, no
        `selector`) is the documented fallback for an element with no
        accessible label at all — see flow/gpsListingFlow.md's Step 10 notes
        on the Share sheet's close button — and must be tapped as-is, with no
        selector lookup. Raises a clear Divergence for a genuinely malformed
        action instead of the unhandled KeyError this used to throw when
        `action["selector"]` was accessed unconditionally.
        """
        if "x" in action and "y" in action:
            return action["x"], action["y"]
        selector = action.get("selector")
        if not selector:
            raise Divergence(
                "tap-malformed",
                "action needs either `selector` or both `x` and `y`")
        page = page_hint or self.source()
        xy = self.find_selector(page, selector)
        if xy is None:
            raise Divergence("selector-not-found", selector)
        return xy

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
        one (scroll-to/wait-* do), else None — callers refetch as needed.

        An action may carry `settleMs` to pause after it completes. This is not
        cosmetic: tapping a Compose text field and immediately running
        `adb input text` drops the first character, because the field has not
        taken focus yet. Verified live — a 10-digit number arrived as 9 digits,
        which still reached the next screen and so passed every assertion while
        silently logging in as the wrong user.
        """
        result = self._dispatch(action, page_hint)
        settle_ms = action.get("settleMs")
        if settle_ms:
            time.sleep(settle_ms / 1000.0)
        return result

    def _dispatch(self, action, page_hint):
        a_type = action["type"]

        if a_type == "tap":
            xy = self._resolve_tap_xy(action, page_hint)
            self.tap_xy(*xy)

        elif a_type in ("double-tap", "long-press"):
            x, y = self._resolve_tap_xy(action, page_hint)
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

        elif a_type == "call-api":
            self._call_api(action)
            return page_hint  # no UI change; keep whatever page we had

        elif a_type == "set-context":
            if "key" not in action:
                raise Divergence("set-context-malformed", "`key` is required")
            self.context.set(action["key"], action.get("value"))
            log(f"run-plan: set-context {self.context.describe(action['key'])}")
            return page_hint

        else:
            raise Divergence("unknown-action-type", a_type)
        return None

    def _call_api(self, action):
        """Executes one API call and binds its response into the context."""
        env = self.api_env()
        endpoint = action.get("endpoint")
        if not endpoint:
            raise Divergence("call-api-malformed", "`endpoint` is required")
        bind = action.get("bind", "api")
        method = action.get("method", "GET")

        try:
            url = config_loader.resolve_path_key(env, endpoint)
            headers = config_loader.build_headers(env, self.context)
        except config_loader.ConfigError as e:
            raise Divergence("api-config-error", str(e))

        log(f"run-plan: executing API {method.upper()} {url}")
        try:
            result = http_executor.execute(
                method, url, headers, body=action.get("body"),
                timeout=env["timeout"], retries=env["retry_count"], log=log)
        except http_executor.ApiError as e:
            raise Divergence(f"api-{e.kind}", str(e))

        expect = action.get("expectStatus")
        status_ok = (result["status"] == expect) if expect is not None \
            else (200 <= result["status"] < 300)

        self.api_calls.append({
            "endpoint": endpoint,
            "method": result["method"],
            "status": result["status"],
            "elapsedMs": result["elapsedMs"],
            "bind": bind,
            "note": result["note"],
            "ok": status_ok,
        })

        if not status_ok:
            detail = result["note"] or f"expected {expect}, got {result['status']}"
            raise Divergence("api-status", detail)

        bound = self.context.bind_response(bind, result)
        variables = sorted(k for k in bound if not k.startswith("_"))
        log(f"run-plan: response {result['status']} in {result['elapsedMs']}ms — "
            f"created {', '.join(f'{bind}.{v}' for v in variables) or '(no fields)'}")

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


COMPARISONS = {
    ">":  lambda a, b: a > b,
    ">=": lambda a, b: a >= b,
    "<":  lambda a, b: a < b,
    "<=": lambda a, b: a <= b,
    "==": lambda a, b: a == b,
    "!=": lambda a, b: a != b,
}
PRESENCE_OPS = ("exists", "not-exists")


def _as_number(value):
    if isinstance(value, bool):
        return None  # don't let True compare as 1
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        try:
            return float(value.strip())
        except ValueError:
            return None
    return None


def evaluate_when(cond, context):
    """Evaluates a step's `when` predicate. Returns (should_run, reason).

    A missing path is a **divergence, not a skip**. A typo'd path that silently
    skipped its step would produce a green run that validated nothing — the
    exact failure mode this repo's docs warn about repeatedly. Use the explicit
    `exists` / `not-exists` operators when absence is the thing being tested.
    """
    if not isinstance(cond, dict):
        raise Divergence("condition-malformed", f"`when` must be an object, got {type(cond).__name__}")

    path = cond.get("path")
    op = (cond.get("op") or "").strip()
    if not path or not op:
        raise Divergence("condition-malformed",
                         "`when` requires both `path` and `op`")
    if op not in COMPARISONS and op not in PRESENCE_OPS:
        allowed = ", ".join(list(COMPARISONS) + list(PRESENCE_OPS))
        raise Divergence("condition-unknown-op", f"{op!r} (allowed: {allowed})")

    found, actual = context.get(path)

    if op in PRESENCE_OPS:
        present = found and actual is not None
        should_run = present if op == "exists" else not present
        return should_run, f"{path} {'is set' if present else 'is not set'} (op {op})"

    if not found:
        raise Divergence(
            "condition-path-missing",
            f"{path} is not in the runtime context (op {op}). Check that an "
            f"earlier call-api step bound it and that the path matches the "
            f"contract doc under api/contracts/.")

    expected = cond.get("value")
    actual_num, expected_num = _as_number(actual), _as_number(expected)

    if actual_num is not None and expected_num is not None:
        result = COMPARISONS[op](actual_num, expected_num)
        return result, f"{path} = {actual} {op} {expected} -> {result}"

    if op in ("==", "!="):
        result = COMPARISONS[op](str(actual), str(expected))
        return result, f"{path} = {actual!r} {op} {expected!r} -> {result}"

    raise Divergence(
        "condition-type-mismatch",
        f"cannot compare {path} = {actual!r} with {expected!r} using {op} — "
        f"numeric comparison needs numbers on both sides")


def check_assertions(page, assertions):
    return [{"text": a, "found": a in page} for a in assertions]


def run(plan, from_step, executor):
    steps = sorted(plan.get("steps", []), key=lambda s: s["id"])
    steps_run = []
    diverged_at = None
    context = executor.context

    for raw_step in steps:
        if raw_step["id"] < from_step:
            continue

        # Resolve ${...} now, not before step 1 — a value bound by an earlier
        # call-api step is only in the context by this point.
        try:
            step = context.resolve_tokens(raw_step)
        except Exception as e:  # noqa: BLE001 — never let resolution kill the run silently
            steps_run.append({"id": raw_step["id"], "status": "FAIL",
                              "reason": "token-resolution-failed", "detail": str(e)})
            diverged_at = {"stepId": raw_step["id"],
                           "reason": "token-resolution-failed", "detail": str(e)}
            break

        # Conditional execution: a false predicate skips this step and records
        # why, rather than failing the flow.
        if step.get("when") is not None:
            try:
                should_run, reason = evaluate_when(step["when"], context)
            except Divergence as d:
                log(f"run-plan: step {step['id']} condition error — {d.reason}: {d.detail}")
                steps_run.append({"id": step["id"], "status": "FAIL",
                                  "reason": d.reason, "detail": d.detail})
                diverged_at = {"stepId": step["id"], "reason": d.reason,
                               "detail": d.detail}
                break
            if not should_run:
                log(f"run-plan: SKIP step {step['id']} — condition false: {reason}")
                steps_run.append({"id": step["id"], "status": "SKIP",
                                  "skipReason": reason,
                                  "condition": step["when"]})
                continue
            log(f"run-plan: step {step['id']} condition true: {reason}")

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
            # Reset per attempt, not per step. Carrying the previous attempt's
            # page into a retry makes `tap` resolve its selector against the
            # screen as it was *before* the failed attempt acted on it, so the
            # retry taps stale coordinates on a screen that has since changed —
            # observed live as a tap landing on an unrelated tab.
            page_after_action = None
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
    result = {"flow": plan.get("flowName"), "overallStatus": overall,
              "stepsRun": steps_run, "divergedAt": diverged_at}

    skipped = [s for s in steps_run if s["status"] == "SKIP"]
    if skipped:
        result["skipped"] = [{"id": s["id"], "reason": s["skipReason"]} for s in skipped]
    if executor.api_calls:
        result["apiCalls"] = executor.api_calls
    if context.unresolved:
        # Surfaced rather than swallowed: an unresolved token stayed literal in
        # whatever selector/assertion used it, which usually explains a
        # downstream failure.
        result["unresolvedTokens"] = list(context.unresolved)
        log("run-plan: WARNING unresolved ${} tokens: " + ", ".join(context.unresolved))
    return result


class _FallbackContext:
    """Minimal stand-in used only when the apiCall skill can't be imported.

    Keeps a UI-only plan running with exactly the old credential-substitution
    behavior, so deleting or breaking api/ never takes the existing UI suite
    down with it. A call-api step still fails loudly via api_env().
    """

    def __init__(self, values):
        self.data = {k: v for k, v in values.items() if v not in (None, "")}
        self.unresolved = []

    def get(self, path):
        if path in self.data:
            return True, self.data[path]
        return False, None

    def set(self, path, value):
        self.data[path] = value

    def describe(self, path):
        return f"{path} = {self.data.get(path, '<not set>')}"

    def resolve_tokens(self, obj):
        if isinstance(obj, str):
            for key, val in self.data.items():
                obj = obj.replace("${" + key + "}", str(val))
            return obj
        if isinstance(obj, list):
            return [self.resolve_tokens(v) for v in obj]
        if isinstance(obj, dict):
            return {k: self.resolve_tokens(v) for k, v in obj.items()}
        return obj


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

    # Optional 9th arg: JSON of API runtime inputs + environment name. Absent
    # for a UI-only run, which is why it's optional rather than positional —
    # existing callers keep working untouched.
    api_env_name = None
    runtime_inputs = {}
    if len(sys.argv) > 9 and sys.argv[9].strip():
        try:
            extra = json.loads(sys.argv[9])
            api_env_name = extra.get("environment")
            runtime_inputs = {k: v for k, v in extra.items() if k != "environment"}
        except json.JSONDecodeError as e:
            log(f"run-plan: ignoring malformed API runtime JSON ({e})")

    with open(plan_path) as f:
        plan = json.load(f)

    # Whether this invocation is continuing an already-open session (a
    # resumed --from-step call) rather than starting a fresh one — decides
    # below whether PLAN_CONTEXT_FILE's api.*/flow.*/derived.* namespaces
    # should be carried in. Checked before the open/reuse block further down
    # touches state_file, so it reflects what was true when this process
    # started, not whatever this same call does to it a few lines later.
    session_reused = os.path.exists(state_file)

    if API_AVAILABLE:
        context = context_store.seed(
            runtime_inputs=runtime_inputs,
            credentials={"mobileNumber": mobile_number,
                         "password": password,
                         "userCode": user_code},
        )
        # Fill in any runtime input this invocation didn't supply from the
        # persisted context. Values passed on the command line win, so an
        # explicit flag always overrides a stale stored one.
        persisted = context_store.RuntimeContext.load(API_CONTEXT_FILE)
        carried = []
        for key, value in (persisted.data.get("runtime") or {}).items():
            already, _ = context.get(f"runtime.{key}")
            if not already and value not in (None, ""):
                context.set(f"runtime.{key}", value)
                carried.append(key)
        if carried:
            log("run-plan: carried runtime input(s) from the apiCall context: "
                + ", ".join(sorted(carried)))

        # A resumed run reuses the earlier invocation's whole context — every
        # namespace a call-api/set-context step bound, not just runtime.* —
        # so a `when` guard or `${api...}` token past the resume point sees
        # the same values it would have if the flow had never left one
        # process. This invocation's own explicit inputs (already applied to
        # `context` above) still win on conflict, via merge()'s "other wins"
        # rule with `context` passed as `other`.
        if session_reused:
            carried_over = context_store.RuntimeContext.load(PLAN_CONTEXT_FILE)
            carried_over.merge(context)
            context = carried_over
    else:
        context = _FallbackContext({"mobileNumber": mobile_number,
                                    "password": password,
                                    "userCode": user_code})

    try:
        with open(state_file) as f:
            session_id = f.read().strip()
    except FileNotFoundError:
        session_id = open_session(appium_url, device_serial, plan["appPackage"], plan["appActivity"])
        with open(state_file, "w") as f:
            f.write(session_id)
        log(f"run-plan: opened session {session_id}")

    executor = PlanExecutor(appium_url, device_serial, session_id,
                            context=context, api_env_name=api_env_name)

    try:
        result = run(plan, from_step, executor)
    except urllib.error.URLError as e:
        result = {"flow": plan.get("flowName"), "overallStatus": "DIVERGED",
                  "stepsRun": [], "divergedAt": {"stepId": from_step, "reason": "appium-unreachable", "detail": str(e)}}

    # Persist regardless of pass/diverge/error — a divergence is exactly when
    # a recovery pass is about to resume with --from-step and needs this.
    if API_AVAILABLE:
        context.save(PLAN_CONTEXT_FILE)

    print("PLAN_RESULT_JSON=" + json.dumps(result))
    sys.exit(0 if result["overallStatus"] == "PASS" else 1)


if __name__ == "__main__":
    main()
