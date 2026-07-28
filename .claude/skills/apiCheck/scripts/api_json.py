#!/usr/bin/env python3
"""
api_json.py — the JSON/assertion/comparison engine behind the apiCheck skill.

Invoked ONLY by api_action.sh (never directly), for the same reason
html_report_generator.js is only invoked by report_tool.sh: it keeps every
capability behind one already-allowlisted script path, so nothing new has to
be added to .claude/settings.json and no session ever re-prompts.

Why Python stdlib and not jq/node: appium_action.sh already parses Appium's
JSON with python3, so this introduces no new dependency. jq is not installed
on the reference machine, and a node dependency would need a package.json /
node_modules that this repo deliberately does not have.

Responsibilities:
  * persist the last HTTP response (status, headers, body, timing)
  * resolve dotted JSON paths (with [i] and [*] support)
  * assert status / headers / body values / types / array counts
  * compare an API value against what the app is actually showing on screen
  * accumulate every check into .checks.json so the run report can render
    real API results instead of invented ones

Every assertion appends a record to the checks file, so `results` can emit a
report-ready JSON payload at the end of a run.
"""

import json
import os
import re
import sys
import time
import xml.etree.ElementTree as ET

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
SKILL_DIR = os.path.dirname(SCRIPT_DIR)
RESPONSE_FILE = os.path.join(SKILL_DIR, ".last_response.json")
CHECKS_FILE = os.path.join(SKILL_DIR, ".checks.json")

MAX_BODY_ECHO = 4000  # chars printed for `body` without --full


# ---------------------------------------------------------------------------
# small helpers
# ---------------------------------------------------------------------------

def die(msg):
    print("❌ %s" % msg, file=sys.stderr)
    sys.exit(2)


def now_iso():
    return time.strftime("%Y-%m-%d %H:%M:%S UTC", time.gmtime())


def load_response():
    if not os.path.exists(RESPONSE_FILE):
        die("No stored response. Run 'api_action.sh get|post|request ...' first.")
    with open(RESPONSE_FILE, "r", encoding="utf-8") as fh:
        return json.load(fh)


def response_json(resp):
    body = resp.get("body", "")
    try:
        return json.loads(body)
    except Exception as exc:
        die("Last response body is not valid JSON (%s). Use 'api_action.sh body' to inspect it." % exc)


def load_checks():
    if not os.path.exists(CHECKS_FILE):
        return []
    try:
        with open(CHECKS_FILE, "r", encoding="utf-8") as fh:
            return json.load(fh)
    except Exception:
        return []


def record(name, result, expected, actual, notes=""):
    """Append one check to the run's check list and print it in the same
    FOUND/NOT FOUND-ish shape the driveFlow script uses, so a step's API
    assertions read the same way as its UI assertions."""
    checks = load_checks()
    checks.append({
        "name": name,
        "result": result,
        "expected": _stringify(expected),
        "actual": _stringify(actual),
        "notes": notes,
        "timestamp": now_iso(),
    })
    with open(CHECKS_FILE, "w", encoding="utf-8") as fh:
        json.dump(checks, fh, indent=2)

    icon = "PASS" if result == "PASS" else "FAIL"
    line = "%s: %s | expected=%s | actual=%s" % (icon, name, _stringify(expected), _stringify(actual))
    if notes:
        line += " | %s" % notes
    print(line)
    return 0 if result == "PASS" else 1


def _stringify(value):
    if value is None:
        return "null"
    if isinstance(value, (dict, list)):
        text = json.dumps(value, ensure_ascii=False)
    else:
        text = str(value)
    return text if len(text) <= 300 else text[:297] + "..."


# ---------------------------------------------------------------------------
# JSON path resolution
#
#   data.vehicles[0].vehicleNumber   list index
#   data.vehicles[*].regNo           every element of a list
#   data.*.speed                     every value of an id-keyed map — which is
#                                    exactly how /vehicles-dynamic returns its
#                                    payload: {"data": {"3341520": {...}}}
#   sum(data.running,data.stoppage)  derived value — the Vehicles screen's
#                                    "All (N)" chip is a sum of the component
#                                    counts the filter API returns separately
#   len(data.vehicles)               size of a list/map/string
# ---------------------------------------------------------------------------

TOKEN_RE = re.compile(r"\[([0-9]+|\*)\]")
FUNC_RE = re.compile(r"^(sum|min|max|len)\((.*)\)$", re.I)


def extract(data, path):
    """Return a list of values matching `path`. Missing keys yield [] rather
    than raising, so an assertion can report 'path not present' as a normal
    FAIL instead of a crash."""
    path = path.strip()
    if path in ("", ".", "$"):
        return [data]

    func = FUNC_RE.match(path)
    if func:
        name, inner = func.group(1).lower(), func.group(2).strip()
        if name == "len":
            values = extract(data, inner)
            if len(values) == 1 and isinstance(values[0], (list, dict, str)):
                return [len(values[0])]
            return [len(values)]
        numbers = []
        for part in inner.split(","):
            for value in extract(data, part.strip()):
                number = to_number(value)
                if number is not None:
                    numbers.append(number)
        if not numbers:
            return []
        result = {"sum": sum(numbers), "min": min(numbers), "max": max(numbers)}[name]
        return [int(result) if float(result).is_integer() else result]

    current = [data]
    for raw_segment in path.replace("$.", "").split("."):
        if not raw_segment:
            continue
        indexes = TOKEN_RE.findall(raw_segment)
        key = TOKEN_RE.sub("", raw_segment)
        nxt = []
        for node in current:
            if key == "*":
                # Every value of a map, or every element of a list.
                if isinstance(node, dict):
                    nxt.extend(node.values())
                elif isinstance(node, list):
                    nxt.extend(node)
                continue
            value = node
            if key:
                if not isinstance(value, dict) or key not in value:
                    continue
                value = value[key]
            nxt.append(value)
        current = nxt
        for index in indexes:
            deeper = []
            for node in current:
                if not isinstance(node, list):
                    continue
                if index == "*":
                    deeper.extend(node)
                else:
                    position = int(index)
                    if position < len(node):
                        deeper.append(node[position])
            current = deeper
    return current


def as_items(values):
    """Normalize whatever a path resolved to into a list of records, so the
    array-shaped assertions work equally on a JSON array and on an id-keyed
    map (`{"data": {"3341520": {...}, "3320966": {...}}}`)."""
    if len(values) == 1:
        if isinstance(values[0], list):
            return values[0]
        if isinstance(values[0], dict):
            inner = list(values[0].values())
            # A map OF records (id -> record) is a collection; a single record
            # is not — tell them apart by whether the values are records.
            if inner and all(isinstance(v, (dict, list)) for v in inner):
                return inner
            return values
    return values


def one_value(data, path):
    values = extract(data, path)
    if not values:
        return None, "path '%s' not present in response body" % path
    if len(values) > 1:
        return values, None
    return values[0], None


# ---------------------------------------------------------------------------
# UI side: pull every human-visible string out of an Appium page source dump
# ---------------------------------------------------------------------------

VISIBLE_ATTRS = ("text", "content-desc", "hint")


def ui_strings(page_source):
    """All text/content-desc values in the hierarchy. Parsing the XML (rather
    than substring-matching the raw dump) is what makes normalized comparison
    safe: '1,848.0' in a content-desc is compared as a whole field value, not
    as characters that happen to sit next to each other in the raw markup."""
    values = []
    try:
        root = ET.fromstring(page_source)
        for element in root.iter():
            for attr in VISIBLE_ATTRS:
                value = element.attrib.get(attr)
                if value:
                    values.append(value)
    except ET.ParseError:
        # Fall back to a regex sweep if the dump is truncated/malformed.
        for attr in VISIBLE_ATTRS:
            values.extend(re.findall(r'%s="([^"]*)"' % attr, page_source))
    return [v for v in values if v.strip()]


# ---------------------------------------------------------------------------
# Normalizers — how an API value is allowed to differ from its UI rendering
# ---------------------------------------------------------------------------

NUMBER_TOKEN_RE = re.compile(r"[-+]?[0-9][0-9,]*(?:\.[0-9]+)?")


def norm_text(value):
    return re.sub(r"\s+", " ", str(value)).strip().casefold()


def norm_plate(value):
    return re.sub(r"[^A-Za-z0-9]", "", str(value)).upper()


def norm_digits(value):
    return re.sub(r"[^0-9]", "", str(value))


def to_number(value):
    try:
        return float(re.sub(r"[^0-9.\-]", "", str(value)))
    except (ValueError, TypeError):
        return None


NORMALIZERS = ("raw", "text", "plate", "digits", "number")


def matches(api_value, ui_value, mode):
    """True when `ui_value` (one on-screen string) represents `api_value`
    under the chosen normalizer."""
    if mode == "raw":
        return str(api_value) in ui_value
    if mode == "text":
        return norm_text(api_value) in norm_text(ui_value)
    if mode == "plate":
        api_norm = norm_plate(api_value)
        return bool(api_norm) and api_norm in norm_plate(ui_value)
    if mode == "digits":
        api_norm = norm_digits(api_value)
        return bool(api_norm) and api_norm in norm_digits(ui_value)
    if mode == "number":
        api_num = to_number(api_value)
        if api_num is None:
            return False
        for token in NUMBER_TOKEN_RE.findall(ui_value):
            ui_num = to_number(token)
            if ui_num is not None and abs(ui_num - api_num) < 0.005:
                return True
        return False
    die("Unknown normalizer '%s'. Use one of: %s" % (mode, ", ".join(NORMALIZERS)))


def scope(strings, anchor):
    """Narrow the candidate UI strings to those containing `anchor`.

    Without this, a whole-screen scan can pass for the wrong reason: the
    Vehicles screen shows "Running (2)" and "Stopped (2)" at the same time, so
    a bare numeric comparison of data.stoppage=2 happily matches the Running
    chip and reports PASS. Anchoring the comparison ("--in Stopped") is what
    makes it an actual assertion about the element under test."""
    if not anchor:
        return strings
    needle = norm_text(anchor)
    return [s for s in strings if needle in norm_text(s)]


def find_on_screen(api_value, strings, mode):
    for candidate in strings:
        if matches(api_value, candidate, mode):
            return candidate
    return None


# ---------------------------------------------------------------------------
# commands
# ---------------------------------------------------------------------------

def cmd_save_response(args):
    status, elapsed_ms, url, method, headers_file, body_file = args[:6]
    headers = {}
    status_line = ""
    if os.path.exists(headers_file):
        with open(headers_file, "r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                line = line.rstrip("\r\n")
                if not line:
                    continue
                if line.upper().startswith("HTTP/"):
                    status_line = line
                    headers = {}  # reset on redirects — keep the final response's headers
                    continue
                if ":" in line:
                    name, _, value = line.partition(":")
                    headers[name.strip()] = value.strip()
    body = ""
    if os.path.exists(body_file):
        with open(body_file, "r", encoding="utf-8", errors="replace") as fh:
            body = fh.read()

    payload = {
        "method": method,
        "url": url,
        "status": int(status) if str(status).isdigit() else 0,
        "statusLine": status_line,
        "headers": headers,
        "body": body,
        "bodyBytes": len(body.encode("utf-8")),
        "elapsedMs": int(float(elapsed_ms)) if elapsed_ms else 0,
        "receivedAt": now_iso(),
    }
    with open(RESPONSE_FILE, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, indent=2)

    print("%s %s -> HTTP %s (%s bytes, %sms)" % (
        method, url, payload["status"], payload["bodyBytes"], payload["elapsedMs"]))
    return 0


def cmd_last(_args):
    resp = load_response()
    print("METHOD=%s" % resp.get("method"))
    print("URL=%s" % resp.get("url"))
    print("STATUS=%s" % resp.get("status"))
    print("ELAPSED_MS=%s" % resp.get("elapsedMs"))
    print("BODY_BYTES=%s" % resp.get("bodyBytes"))
    print("CONTENT_TYPE=%s" % resp.get("headers", {}).get("content-type",
                                                          resp.get("headers", {}).get("Content-Type", "")))
    return 0


def cmd_body(args):
    resp = load_response()
    body = resp.get("body", "")
    full = "--full" in args
    if "--pretty" in args:
        try:
            body = json.dumps(json.loads(body), indent=2, ensure_ascii=False)
        except Exception:
            pass
    if not full and len(body) > MAX_BODY_ECHO:
        print(body[:MAX_BODY_ECHO])
        print("\n... [truncated at %d chars — re-run with --full to see everything]" % MAX_BODY_ECHO)
    else:
        print(body)
    return 0


def cmd_headers(_args):
    resp = load_response()
    for name, value in resp.get("headers", {}).items():
        print("%s: %s" % (name, value))
    return 0


def cmd_get(args):
    if not args:
        die("Usage: json <path>")
    data = response_json(load_response())
    values = extract(data, args[0])
    if not values:
        die("path '%s' not present in response body" % args[0])
    for value in values:
        print(value if isinstance(value, str) else json.dumps(value, ensure_ascii=False))
    return 0


def cmd_assert_status(args):
    if not args:
        die("Usage: assert-status <expectedCode>")
    resp = load_response()
    expected = args[0]
    actual = resp.get("status")
    ok = str(actual) == str(expected)
    return record("status code", "PASS" if ok else "FAIL", expected, actual,
                  "" if ok else "%s %s returned HTTP %s" % (resp.get("method"), resp.get("url"), actual))


def cmd_assert_header(args):
    if len(args) < 2:
        die("Usage: assert-header <name> <expectedSubstring>")
    name, expected = args[0], args[1]
    headers = load_response().get("headers", {})
    actual = None
    for key, value in headers.items():
        if key.lower() == name.lower():
            actual = value
            break
    ok = actual is not None and expected.lower() in actual.lower()
    return record("header %s" % name, "PASS" if ok else "FAIL", "contains '%s'" % expected,
                  actual if actual is not None else "<header absent>")


def cmd_assert_json(args):
    if len(args) < 2:
        die("Usage: assert-json <path> <expectedValue> [--normalize raw|text|number|plate|digits]")
    path, expected = args[0], args[1]
    mode = _opt(args, "--normalize", "text")
    data = response_json(load_response())
    values = extract(data, path)
    if not values:
        return record("json %s" % path, "FAIL", expected, "<path not present>",
                      "path '%s' does not exist in the response body" % path)

    def equal(actual):
        if mode == "number":
            api_num, exp_num = to_number(actual), to_number(expected)
            return api_num is not None and exp_num is not None and abs(api_num - exp_num) < 0.005
        if mode == "plate":
            return norm_plate(actual) == norm_plate(expected)
        if mode == "digits":
            return norm_digits(actual) == norm_digits(expected)
        if mode == "raw":
            return str(actual) == str(expected)
        return norm_text(actual) == norm_text(expected)

    failed = [v for v in values if not equal(v)]
    ok = not failed
    actual = values[0] if len(values) == 1 else values
    return record("json %s" % path, "PASS" if ok else "FAIL", expected, actual,
                  "" if ok else "%d of %d value(s) did not match (normalize=%s)" % (len(failed), len(values), mode))


def cmd_assert_type(args):
    if len(args) < 2:
        die("Usage: assert-type <path> <string|number|boolean|array|object|null>")
    path, expected = args[0], args[1].lower()
    type_map = {
        "string": str, "number": (int, float), "boolean": bool,
        "array": list, "object": dict, "null": type(None),
    }
    if expected not in type_map:
        die("Unknown type '%s'. Use: %s" % (expected, ", ".join(type_map)))
    data = response_json(load_response())
    values = extract(data, path)
    if not values:
        return record("type %s" % path, "FAIL", expected, "<path not present>",
                      "path '%s' does not exist in the response body" % path)
    bad = []
    for value in values:
        # bool is a subclass of int in Python — keep the two distinct.
        if expected == "number" and isinstance(value, bool):
            bad.append(value)
        elif not isinstance(value, type_map[expected]):
            bad.append(value)
    ok = not bad
    return record("type %s" % path, "PASS" if ok else "FAIL", expected,
                  type(values[0]).__name__ if len(values) == 1 else "%d values" % len(values),
                  "" if ok else "%d value(s) were not %s" % (len(bad), expected))


def cmd_assert_count(args):
    if len(args) < 2:
        die("Usage: assert-count <path> <n|>n|>=n|<n|<=n>")
    path, expr = args[0], args[1].strip()
    data = response_json(load_response())
    values = extract(data, path)
    if len(values) == 1 and isinstance(values[0], list):
        count = len(values[0])
    else:
        count = len(values)
    match = re.match(r"^(>=|<=|>|<|=)?\s*(\d+)$", expr)
    if not match:
        die("Unrecognised count expression '%s'" % expr)
    operator, number = match.group(1) or "=", int(match.group(2))
    ok = {
        "=": count == number, ">": count > number, "<": count < number,
        ">=": count >= number, "<=": count <= number,
    }[operator]
    return record("count %s" % path, "PASS" if ok else "FAIL", "%s%d" % (operator, number), count)


def cmd_assert_fields(args):
    """assert-fields <arrayPath> <field1> <field2> ... — every element of the
    array must carry every listed field, non-null. This is the practical
    'validate the response body' check for list endpoints."""
    if len(args) < 2:
        die("Usage: assert-fields <arrayPath> <field1> [field2 ...]")
    path, fields = args[0], args[1:]
    data = response_json(load_response())
    items = as_items(extract(data, path))
    if not items:
        return record("fields %s" % path, "FAIL", ", ".join(fields), "<empty or missing collection>")
    missing = {}
    for index, item in enumerate(items):
        for field in fields:
            if not isinstance(item, dict) or item.get(field) in (None, ""):
                missing.setdefault(field, []).append(index)
    ok = not missing
    detail = "; ".join("%s missing/null at index %s" % (f, i[:5]) for f, i in missing.items())
    return record("fields %s" % path, "PASS" if ok else "FAIL",
                  "all %d item(s) have: %s" % (len(items), ", ".join(fields)),
                  "ok" if ok else detail)


def cmd_compare_ui(args):
    """compare-ui <path> <pageSourceFile> [--normalize m] [--label l]"""
    if len(args) < 2:
        die("Usage: compare-ui <path> <pageSourceFile> [--normalize raw|text|number|plate|digits] [--in anchor] [--label name]")
    path, source_file = args[0], args[1]
    mode = _opt(args, "--normalize", "text")
    anchor = _opt(args, "--in", None)
    label = _opt(args, "--label", "UI vs API %s" % path)
    data = response_json(load_response())
    value, error = one_value(data, path)
    if error:
        return record(label, "FAIL", "<value from %s>" % path, "<path not present>", error)
    if isinstance(value, list):
        return record(label, "FAIL", path, value,
                      "path matched %d values — use compare-ui-list for arrays" % len(value))
    with open(source_file, "r", encoding="utf-8", errors="replace") as fh:
        strings = ui_strings(fh.read())
    candidates = scope(strings, anchor)
    if anchor and not candidates:
        return record(label, "FAIL", value, "<no element containing '%s' on screen>" % anchor,
                      "anchor '%s' not found — the element under test is not on the current screen" % anchor)
    hit = find_on_screen(value, candidates, mode)
    ok = hit is not None
    where = " within element(s) containing '%s'" % anchor if anchor else ""
    return record(label, "PASS" if ok else "FAIL", value,
                  hit if ok else "<not shown on current screen>",
                  "matched on screen (normalize=%s)%s" % (mode, where) if ok
                  else "API returned '%s' but no on-screen element matches it (normalize=%s, %d UI string(s) scanned%s)"
                       % (value, mode, len(candidates), where))


def cmd_compare_ui_list(args):
    """compare-ui-list <arrayPath> <field> <pageSourceFile> [--limit n] [--normalize m]

    Only the elements the app has actually rendered can be matched — a Compose
    LazyColumn keeps just the visible window in the hierarchy, so comparing a
    whole 94-vehicle payload against one screen would fail by design. Use
    --limit with a sampled subset, or scroll-to the element first."""
    if len(args) < 3:
        die("Usage: compare-ui-list <arrayPath> <field> <pageSourceFile> [--limit n] [--normalize m]")
    path, field, source_file = args[0], args[1], args[2]
    mode = _opt(args, "--normalize", "text")
    limit = _opt(args, "--limit", None)
    anchor = _opt(args, "--in", None)
    data = response_json(load_response())
    items = as_items(extract(data, path))
    if not items:
        return record("UI vs API %s[].%s" % (path, field), "FAIL", field, "<empty or missing collection>")
    expected_values = [i.get(field) for i in items if isinstance(i, dict) and i.get(field) not in (None, "")]
    if limit:
        expected_values = expected_values[:int(limit)]
    with open(source_file, "r", encoding="utf-8", errors="replace") as fh:
        strings = scope(ui_strings(fh.read()), anchor)

    failures = 0
    exit_code = 0
    for expected in expected_values:
        hit = find_on_screen(expected, strings, mode)
        if hit is None:
            failures += 1
        code = record("UI vs API %s.%s" % (path, field), "PASS" if hit else "FAIL", expected,
                      hit if hit else "<not shown on current screen>",
                      "" if hit else "not rendered on the current screen (normalize=%s)" % mode)
        exit_code = exit_code or code
    print("compare-ui-list: %d checked, %d matched, %d missing"
          % (len(expected_values), len(expected_values) - failures, failures))
    return exit_code


def cmd_results(args):
    checks = load_checks()
    if "--json" in args:
        print(json.dumps(checks, indent=2, ensure_ascii=False))
        return 0
    if not checks:
        print("No API checks recorded for this run.")
        return 0
    passed = sum(1 for c in checks if c["result"] == "PASS")
    for check in checks:
        print("%s: %s | expected=%s | actual=%s" % (check["result"], check["name"], check["expected"], check["actual"]))
    print("TOTAL=%d PASSED=%d FAILED=%d" % (len(checks), passed, len(checks) - passed))
    return 0 if passed == len(checks) else 1


def cmd_reset(_args):
    for path in (RESPONSE_FILE, CHECKS_FILE):
        if os.path.exists(path):
            os.remove(path)
    print("apiCheck state cleared (last response + recorded checks).")
    return 0


def _opt(args, name, default):
    if name in args:
        index = args.index(name)
        if index + 1 < len(args):
            return args[index + 1]
    return default


COMMANDS = {
    "save-response": cmd_save_response,
    "last": cmd_last,
    "body": cmd_body,
    "headers": cmd_headers,
    "json": cmd_get,
    "assert-status": cmd_assert_status,
    "assert-header": cmd_assert_header,
    "assert-json": cmd_assert_json,
    "assert-type": cmd_assert_type,
    "assert-count": cmd_assert_count,
    "assert-fields": cmd_assert_fields,
    "compare-ui": cmd_compare_ui,
    "compare-ui-list": cmd_compare_ui_list,
    "results": cmd_results,
    "reset": cmd_reset,
}


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in COMMANDS:
        die("Unknown or missing command. Available: %s" % ", ".join(sorted(COMMANDS)))
    sys.exit(COMMANDS[sys.argv[1]](sys.argv[2:]))


if __name__ == "__main__":
    main()
