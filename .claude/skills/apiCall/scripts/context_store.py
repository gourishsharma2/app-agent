#!/usr/bin/env python3
"""
context_store.py — the runtime context shared by the API layer and run_plan.py.

Why this exists
---------------
Before this module, the only variable mechanism was
`run_plan.py::substitute_credentials()`: a recursive string replace of
`${mobileNumber}` / `${password}` / `${userCode}` across the whole plan,
performed **once before step 1**. That works for credentials, which are known
up front, and cannot work for an API response, which only exists partway
through a run. Conditional execution (`IF api.running > 0`) needs a value that
was fetched three steps earlier, so resolution has to become lazy and
per-step — that is what this class provides.

Namespaces
----------
    runtime.*   inputs supplied on the /run line (token, userCode, deviceName…)
    env.*       resolved environment config (name, base_url, timeout)
    api.*       API responses, envelope unwrapped  → api.running
    flow.*      values set by a SET_CONTEXT step
    derived.*   values computed by the framework

Credential keys are additionally seeded at the top level (`mobileNumber`,
`password`, `userCode`) so every `${mobileNumber}` in an already-compiled plan
keeps resolving exactly as before. This module is backward compatible by
construction.

Persistence
-----------
`run_plan.py` runs the whole flow in one process and keeps the context in
memory. Standalone `api_action.sh` calls cannot: the repo's allowlist forbids
`$(...)` capture, so a response can never live in a shell variable. Those calls
therefore save/load this context as JSON, the same pattern the Appium session
id already uses.

Standard library only.
"""
import json
import os
import re

TOKEN_RE = re.compile(r"\$\{([^}]+)\}")

# Redacted in every log line, dump and report. Matched against the final
# segment of a dotted path, case-insensitively.
SECRET_LEAVES = {
    "token",
    "accesstoken",
    "access_token",
    "refreshtoken",
    "password",
    "mobilenumber",
    "authorization",
    "secret",
    "apikey",
}
REDACTED = "***redacted***"

# Envelope fields lifted alongside unwrapped `data` when binding a response.
ENVELOPE_FIELDS = ("message", "success", "serverTime")


def is_secret(path):
    return path.split(".")[-1].strip().lower() in SECRET_LEAVES


class RuntimeContext:
    def __init__(self, data=None):
        self.data = dict(data or {})
        self.unresolved = []

    # ---------------------------------------------------------------- access
    def get(self, path):
        """Looks up a dotted path. Returns (found, value).

        Traverses dicts by key and lists by integer index, so
        `api._raw.data.running` and `api.items.0.name` both work.
        """
        node = self.data
        for part in str(path).split("."):
            part = part.strip()
            if isinstance(node, dict):
                if part not in node:
                    return False, None
                node = node[part]
            elif isinstance(node, list):
                try:
                    idx = int(part)
                except ValueError:
                    return False, None
                if idx < 0 or idx >= len(node):
                    return False, None
                node = node[idx]
            else:
                return False, None
        return True, node

    def set(self, path, value):
        parts = [p.strip() for p in str(path).split(".")]
        node = self.data
        for part in parts[:-1]:
            nxt = node.get(part)
            if not isinstance(nxt, dict):
                nxt = {}
                node[part] = nxt
            node = nxt
        node[parts[-1]] = value

    # ------------------------------------------------------------- response
    def bind_response(self, namespace, result):
        """Binds an HTTP result into `namespace`, unwrapping the common
        `{message, success, serverTime, data}` envelope.

        `data`'s fields land directly on the namespace (`api.running`) because
        that is what flows read. The untouched response stays at
        `<namespace>._raw` so nothing is lost when a payload doesn't match the
        envelope shape.

        A `data` field name colliding with an envelope field wins — `data` is
        the payload under test.

        Merges into whatever is already bound at `namespace`, rather than
        replacing it outright. Two `CALL_API` steps that deliberately share a
        bind namespace (e.g. a flow's `getAllFilterCount` followed later by a
        conditional `vehiclesStatic` call, both bound to `api`) are a common,
        correct pattern — a flow reads `api.running` from the first call and
        `api.list` from the second in the same expression. A full replace
        would silently erase `api.running` the moment the second call landed,
        breaking any later step (including a sibling `IF`/`ENDIF` branch's own
        guard) that still needs it. `_raw`/`_status`/`_elapsedMs`/`_url` and
        any same-named field are overwritten with the newest call's value, as
        expected; only fields unique to the earlier call survive untouched.
        """
        body = result.get("json")
        bound = {
            "_raw": body,
            "_status": result.get("status"),
            "_elapsedMs": result.get("elapsedMs"),
            "_url": result.get("url"),
        }

        if isinstance(body, dict):
            for field in ENVELOPE_FIELDS:
                if field in body:
                    bound[field] = body[field]
            data = body.get("data")
            if isinstance(data, dict):
                for key, value in data.items():
                    bound[key] = value
            elif data is not None:
                bound["data"] = data

        existing = self.data.get(namespace)
        merged = dict(existing) if isinstance(existing, dict) else {}
        merged.update(bound)
        self.data[namespace] = merged
        return bound

    # ---------------------------------------------------------- substitution
    def resolve_tokens(self, obj):
        """Recursively replaces `${dotted.path}` in every string leaf.

        An unresolved token is left verbatim and recorded in `self.unresolved`
        rather than replaced with an empty string: silently blanking a selector
        turns a typo into a confusing 'selector-not-found' several steps later,
        whereas leaving it visible names the token in the failure.
        """
        if isinstance(obj, str):
            def repl(m):
                path = m.group(1).strip()
                found, value = self.get(path)
                if not found or value is None:
                    if path not in self.unresolved:
                        self.unresolved.append(path)
                    return m.group(0)
                return str(value)
            return TOKEN_RE.sub(repl, obj)
        if isinstance(obj, list):
            return [self.resolve_tokens(v) for v in obj]
        if isinstance(obj, dict):
            return {k: self.resolve_tokens(v) for k, v in obj.items()}
        return obj

    # -------------------------------------------------------------- logging
    def public(self):
        """A deep copy with every secret leaf replaced, safe to log or report."""
        def walk(node, prefix):
            if isinstance(node, dict):
                return {
                    k: (REDACTED if is_secret(k) else walk(v, f"{prefix}.{k}"))
                    for k, v in node.items()
                }
            if isinstance(node, list):
                return [walk(v, prefix) for v in node]
            return node
        return walk(self.data, "")

    def describe(self, path):
        """`path = value` for a log line, redacted if the path is a secret."""
        found, value = self.get(path)
        if not found:
            return f"{path} = <not set>"
        if is_secret(path):
            return f"{path} = {REDACTED}"
        return f"{path} = {json.dumps(value) if not isinstance(value, str) else value}"

    # ----------------------------------------------------------------- merge
    def merge(self, other):
        """Merges another `RuntimeContext`'s data into this one, namespace by
        namespace — `other` wins on conflicts, but a namespace absent from
        `other` survives untouched (the same "merge, don't replace" rule
        `bind_response` follows, applied one level up).

        Used to combine a freshly-seeded context (this invocation's explicit
        `--mobile`/`--environment`/... inputs) with one loaded from a
        persisted file (an earlier invocation's `call-api`/`set-context`
        bindings on a resumed `--from-step` run) — a plain top-level replace
        would let whichever context loads second erase the other's namespaces
        outright, the exact bug `bind_response` had before it was fixed to
        merge internally instead of replacing.
        """
        for key, value in other.data.items():
            existing = self.data.get(key)
            if isinstance(existing, dict) and isinstance(value, dict):
                existing.update(value)
            else:
                self.data[key] = value

    # ---------------------------------------------------------- persistence
    def save(self, path):
        directory = os.path.dirname(path)
        if directory:
            os.makedirs(directory, exist_ok=True)
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(self.data, f, indent=2)
        os.replace(tmp, path)
        try:
            os.chmod(path, 0o600)  # may hold a session token
        except OSError:
            pass

    @classmethod
    def load(cls, path):
        try:
            with open(path, encoding="utf-8") as f:
                return cls(json.load(f))
        except (FileNotFoundError, json.JSONDecodeError, OSError):
            return cls()


def seed(runtime_inputs=None, credentials=None, env_config=None):
    """Builds a context from a run's inputs.

    Credentials are placed under `runtime.*` **and** at the top level, so
    plans compiled before this module existed keep resolving `${mobileNumber}`
    unchanged.
    """
    ctx = RuntimeContext()
    for key, value in (runtime_inputs or {}).items():
        if value not in (None, ""):
            ctx.set(f"runtime.{key}", value)
    for key, value in (credentials or {}).items():
        if value not in (None, ""):
            ctx.set(f"runtime.{key}", value)
            ctx.set(key, value)
    if env_config:
        ctx.set("env.name", env_config.get("name"))
        ctx.set("env.base_url", env_config.get("base_url"))
        ctx.set("env.timeout", env_config.get("timeout"))
        ctx.set("env.retry_count", env_config.get("retry_count"))
    return ctx
