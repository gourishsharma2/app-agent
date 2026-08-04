#!/usr/bin/env python3
"""
api_cli.py — the engine behind `api_action.sh`.

Not meant to be invoked directly; `api_action.sh` is the allowlisted entry
point (see .claude/settings.json and the SKILL.md for why that matters).

Every subcommand persists the runtime context to `.context.json` and reads it
back on the next call, because the repo's allowlist forbids `$(...)` capture —
a response can never be held in a shell variable, so it has to live in a file.
That is the same pattern `appium_action.sh` already uses for the session id.
"""
import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import config_loader  # noqa: E402
import context_store  # noqa: E402
import http_executor  # noqa: E402

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, "..", "..", "..", ".."))
API_ROOT = os.path.join(PROJECT_ROOT, "api")
CONTEXT_FILE = os.path.join(SCRIPT_DIR, "..", ".context.json")

RUNTIME_KEYS = (
    "token", "userCode", "deviceName", "deviceId", "androidVersion",
)


def log(msg):
    print(msg, file=sys.stderr)


def fail(msg, code=1):
    print(f"API_ERROR={msg}", file=sys.stderr)
    sys.exit(code)


def _ctx():
    return context_store.RuntimeContext.load(os.path.abspath(CONTEXT_FILE))


def _save(ctx):
    ctx.save(os.path.abspath(CONTEXT_FILE))


def cmd_doctor(args):
    ctx = _ctx()
    try:
        env = config_loader.load_environment(args.environment, API_ROOT)
    except config_loader.ConfigError as e:
        fail(str(e))

    print(f"ENVIRONMENT={env['name']}")
    print(f"BASE_URL={env['base_url']}")
    print(f"TIMEOUT={env['timeout']}")
    print(f"RETRY_COUNT={env['retry_count']}")
    print(f"CONFIG_DIR={os.path.relpath(env['dir'], PROJECT_ROOT)}")
    print(f"PATH_KEYS={','.join(sorted(env['paths']))}")

    print("STATIC_HEADERS=" + ",".join(sorted(env["static_headers"])))
    print("RUNTIME_HEADERS=" + ",".join(sorted(env["runtime_headers"])))

    missing = []
    for key in RUNTIME_KEYS:
        found, value = ctx.get(f"runtime.{key}")
        present = found and value not in (None, "")
        shown = context_store.REDACTED if (present and context_store.is_secret(key)) \
            else (value if present else "<not set>")
        print(f"RUNTIME_{key}={shown}")
        if not present:
            missing.append(key)

    try:
        config_loader.build_headers(env, ctx)
        print("HEADERS_RESOLVABLE=yes")
    except config_loader.ConfigError as e:
        print("HEADERS_RESOLVABLE=no")
        print(f"HEADERS_BLOCKED_BY={e}")

    if missing:
        print("MISSING_RUNTIME_INPUTS=" + ",".join(missing))


def cmd_set_runtime(args):
    ctx = _ctx()
    applied = []
    for pair in args.pairs:
        if "=" not in pair:
            fail(f"Expected key=value, got {pair!r}")
        key, value = pair.split("=", 1)
        key = key.strip()
        value = value.strip()
        if not key:
            fail(f"Empty key in {pair!r}")
        ctx.set(f"runtime.{key}", value)
        applied.append(key)
    _save(ctx)
    print("SET_RUNTIME=" + ",".join(applied))


def cmd_call(args):
    ctx = _ctx()
    try:
        env = config_loader.load_environment(args.environment, API_ROOT)
    except config_loader.ConfigError as e:
        fail(str(e))

    ctx.set("env.name", env["name"])
    ctx.set("env.base_url", env["base_url"])

    log(f"Loading environment '{env['name']}'...")
    log(f"Loading markdown configuration from {os.path.relpath(env['dir'], PROJECT_ROOT)}...")

    try:
        url = config_loader.resolve_path_key(env, args.endpoint)
        headers = config_loader.build_headers(
            env, ctx, include_runtime=not args.no_auth)
    except config_loader.ConfigError as e:
        fail(str(e))

    body = None
    if args.body:
        try:
            body = json.loads(args.body)
        except json.JSONDecodeError as e:
            fail(f"--body is not valid JSON: {e}")

    log(f"Executing API: {args.method.upper()} {url}")
    try:
        result = http_executor.execute(
            args.method, url, headers, body=body,
            timeout=env["timeout"], retries=env["retry_count"], log=log,
        )
    except http_executor.ApiError as e:
        fail(str(e))

    log(f"Response received: {result['status']} in {result['elapsedMs']}ms "
        f"(attempts: {result['attempts']})")
    if result["note"]:
        log(f"Note: {result['note']}")

    bound = ctx.bind_response(args.bind, result)
    _save(ctx)

    variables = sorted(k for k in bound if not k.startswith("_"))
    log(f"Creating flow variables: {', '.join(f'{args.bind}.{v}' for v in variables)}")

    print(f"API_STATUS={result['status']}")
    print(f"API_ELAPSED_MS={result['elapsedMs']}")
    print(f"API_BIND={args.bind}")
    print("API_VARIABLES=" + ",".join(f"{args.bind}.{v}" for v in variables))
    if result["note"]:
        print(f"API_NOTE={result['note']}")
    if args.print_body:
        print("API_BODY=" + json.dumps(result["json"]
                                      if result["json"] is not None else result["text"]))

    sys.exit(0 if 200 <= result["status"] < 300 else 1)


AUTH_REQUIRED_KEYS = (
    "user_lookup_path", "username_path", "password_path",
    "login_path", "login_body", "token_path",
)


def cmd_auth(args):
    """Runs the environment's declared credential chain:
    userCode -> user lookup -> username+password -> login -> session token.

    The chain lives in api/environments/<env>/auth.md, so a different backend's
    auth flow is a configuration change rather than a code change. Nothing
    secret is printed at any point.
    """
    ctx = _ctx()
    try:
        env = config_loader.load_environment(args.environment, API_ROOT)
        auth = config_loader.load_auth(env)
    except config_loader.ConfigError as e:
        fail(str(e))

    missing = [k for k in AUTH_REQUIRED_KEYS if not auth.get(k)]
    if missing:
        fail(f"auth.md for {env['name']} is missing required key(s): "
             f"{', '.join(missing)}")

    static_only = config_loader.build_headers(env, ctx, include_runtime=False)

    # ---- Step 1: look the user up by code -------------------------------
    lookup = auth["user_lookup_path"]
    query = auth.get("user_lookup_query", "")
    if query:
        query = query.replace("${userCode}", args.user_code)
        lookup = f"{lookup}?{query}"

    log(f"Resolving credentials for {args.user_code}...")
    try:
        url = config_loader.resolve_path_key(env, lookup)
        result = http_executor.execute(
            "GET", url, static_only,
            timeout=env["timeout"], retries=env["retry_count"], log=log)
    except (config_loader.ConfigError, http_executor.ApiError) as e:
        fail(str(e))

    if not 200 <= result["status"] < 300:
        fail(f"User lookup failed: {result['note'] or result['status']}")

    ctx.bind_response("userLookup", result)
    # Paths in auth.md are paths into the *raw* response, so they read exactly
    # as they appear in a curl output. `_raw` bypasses the envelope unwrapping
    # that turns `data.running` into `api.running` for flow variables.
    found_user, username = ctx.get(f"userLookup._raw.{auth['username_path']}")
    found_pass, password = ctx.get(f"userLookup._raw.{auth['password_path']}")
    if not found_user or not found_pass:
        fail(f"User {args.user_code!r} was found but the response has no "
             f"{auth['username_path']}/{auth['password_path']}. "
             "Check those paths in auth.md against the live response shape.")

    found_name, display_name = ctx.get("userLookup._raw.data.0.name")
    log(f"Credentials resolved for {display_name if found_name else args.user_code} "
        "(password not shown).")

    # ---- Step 2: exchange them for a session token ----------------------
    body_raw = (auth["login_body"]
                .replace("${userName}", str(username))
                .replace("${password}", str(password)))
    try:
        body = json.loads(body_raw)
    except json.JSONDecodeError as e:
        fail(f"login_body in auth.md is not valid JSON after substitution: {e}")

    log("Requesting session token...")
    try:
        login_url = config_loader.resolve_path_key(env, auth["login_path"])
        login_result = http_executor.execute(
            auth.get("login_method", "POST"), login_url, static_only,
            body=body, timeout=env["timeout"],
            retries=0,  # never retry a login: it is rate-limited
            log=log)
    except (config_loader.ConfigError, http_executor.ApiError) as e:
        fail(str(e))

    if not 200 <= login_result["status"] < 300:
        fail(f"Login failed: {login_result['note'] or login_result['status']}")

    ctx.bind_response("login", login_result)
    found_token, token = ctx.get(f"login._raw.{auth['token_path']}")
    if not found_token or not token:
        fail(f"Login returned {login_result['status']} but no token at "
             f"{auth['token_path']}. Check token_path in auth.md.")

    ctx.set("runtime.token", token)

    resolved_code = args.user_code
    uc_path = auth.get("token_user_code_path")
    if uc_path:
        found_uc, value = ctx.get(f"login._raw.{uc_path}")
        if found_uc and value:
            resolved_code = value
    ctx.set("runtime.userCode", resolved_code)

    # Drop the intermediate responses before persisting. Redaction only applies
    # to printed output, so leaving these bound would write the looked-up
    # plaintext password (and a duplicate of the token) into .context.json.
    # Neither has any purpose once runtime.token exists.
    for namespace in ("userLookup", "login"):
        ctx.data.pop(namespace, None)

    _save(ctx)

    log("Session token stored in the runtime context (not shown).")
    print(f"AUTH_USER_CODE={resolved_code}")
    print(f"AUTH_LOGIN_STATUS={login_result['status']}")
    print(f"AUTH_TOKEN_LENGTH={len(str(token))}")
    print("AUTH_TOKEN_STORED=yes")
    if resolved_code != args.user_code:
        print(f"AUTH_NOTE=login returned user code {resolved_code}, "
              f"requested {args.user_code} — user-code header will use "
              f"{resolved_code} to match the token's account")


def cmd_context(args):
    ctx = _ctx()
    if args.path:
        found, value = ctx.get(args.path)
        if not found:
            fail(f"Context path {args.path!r} is not set. "
                 "Run `context` with no arguments to see what is.")
        if context_store.is_secret(args.path):
            print(context_store.REDACTED)
        else:
            print(value if isinstance(value, str) else json.dumps(value))
        return
    print(json.dumps(ctx.public(), indent=2))


def cmd_context_set(args):
    ctx = _ctx()
    raw = args.value
    try:
        value = json.loads(raw)
    except json.JSONDecodeError:
        value = raw
    ctx.set(args.path, value)
    _save(ctx)
    print(f"CONTEXT_SET={args.path}")


def cmd_reset(args):
    path = os.path.abspath(CONTEXT_FILE)
    existed = os.path.exists(path)
    if existed:
        os.remove(path)
    print(f"CONTEXT_RESET={'yes' if existed else 'nothing-to-reset'}")


def main():
    parser = argparse.ArgumentParser(prog="api_action.sh", add_help=True)
    sub = parser.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("doctor", help="show resolved configuration for an environment")
    p.add_argument("environment")
    p.set_defaults(func=cmd_doctor)

    p = sub.add_parser("set-runtime", help="store runtime inputs (key=value ...)")
    p.add_argument("pairs", nargs="+")
    p.set_defaults(func=cmd_set_runtime)

    p = sub.add_parser("call", help="call an endpoint and bind the response")
    p.add_argument("environment")
    p.add_argument("endpoint")
    p.add_argument("--method", default="GET")
    p.add_argument("--bind", default="api")
    p.add_argument("--body", default=None)
    p.add_argument("--print-body", action="store_true")
    p.add_argument("--no-auth", action="store_true",
                   help="send only static headers (for endpoints that produce credentials)")
    p.set_defaults(func=cmd_call)

    p = sub.add_parser("auth", help="resolve credentials for a user code and store a session token")
    p.add_argument("environment")
    p.add_argument("user_code")
    p.set_defaults(func=cmd_auth)

    p = sub.add_parser("context", help="dump the runtime context (secrets redacted)")
    p.add_argument("path", nargs="?", default=None)
    p.set_defaults(func=cmd_context)

    p = sub.add_parser("context-set", help="set one context value")
    p.add_argument("path")
    p.add_argument("value")
    p.set_defaults(func=cmd_context_set)

    p = sub.add_parser("reset", help="clear the stored runtime context")
    p.set_defaults(func=cmd_reset)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
