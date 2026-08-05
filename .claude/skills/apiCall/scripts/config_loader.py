#!/usr/bin/env python3
"""
config_loader.py — parses the markdown configuration under api/environments/.

Config lives in markdown so it can be documented in place, but only fenced
code blocks are read; all surrounding prose is ignored. That split is
deliberate: explaining a setting can never break the loader.

    ```properties      key = value pairs (base_url.md, paths.md, static headers)
    ```runtime         header name = ${runtime.x} references (headers.md)

Standard library only — this repo has no third-party dependencies, which rules
out YAML.

Every failure raises ConfigError carrying a message that names the file and
what to do about it, because a config mistake surfaces as a wrong URL or a
missing header much later otherwise.
"""
import os
import re

FENCE_RE = re.compile(r"^```([A-Za-z0-9_-]*)\s*$")
TOKEN_RE = re.compile(r"\$\{([^}]+)\}")

REQUIRED_BASE_KEYS = ("environment", "base_url")


class ConfigError(Exception):
    """A configuration problem with an actionable message."""


def _read(path):
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except FileNotFoundError:
        raise ConfigError(f"Missing configuration file: {path}")
    except OSError as e:
        raise ConfigError(f"Cannot read configuration file {path}: {e}")


def parse_fenced_blocks(text, path):
    """Returns {fence_language: [raw_line, ...]} for every fenced block.

    An unterminated fence is an error rather than a silent truncation — it
    would otherwise drop every setting after it.
    """
    blocks = {}
    lang = None
    lines = []
    open_line = None
    for lineno, line in enumerate(text.splitlines(), 1):
        m = FENCE_RE.match(line)
        if m:
            if lang is None:
                lang = m.group(1) or "text"
                lines = []
                open_line = lineno
            else:
                blocks.setdefault(lang, []).extend(lines)
                lang = None
        elif lang is not None:
            lines.append(line)
    if lang is not None:
        raise ConfigError(
            f"Unterminated ``` block opened at {path}:{open_line} — "
            "every fenced block must be closed, or the settings after it are lost."
        )
    return blocks


def parse_pairs(lines, path, fence):
    """`key = value`, split on the first `=`. Blank lines and #-comments skipped.

    Values keep inner `=` and `:` intact so URLs survive unharmed.
    """
    out = {}
    for line in lines:
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if "=" not in stripped:
            raise ConfigError(
                f"Malformed line in {path} (```{fence} block): {stripped!r} — "
                "expected `key = value`."
            )
        key, value = stripped.split("=", 1)
        key = key.strip()
        if not key:
            raise ConfigError(f"Empty key in {path} (```{fence} block): {stripped!r}")
        out[key] = value.strip()
    return out


def _load_pairs_file(path, fence="properties"):
    blocks = parse_fenced_blocks(_read(path), path)
    if fence not in blocks:
        raise ConfigError(
            f"No ```{fence} block found in {path} — configuration must live "
            f"inside a fenced ```{fence} block, not in prose."
        )
    return parse_pairs(blocks[fence], path, fence)


def available_environments(api_root):
    env_dir = os.path.join(api_root, "environments")
    if not os.path.isdir(env_dir):
        return []
    return sorted(
        d for d in os.listdir(env_dir) if os.path.isdir(os.path.join(env_dir, d))
    )


def load_environment(env_name, api_root):
    """Loads and validates one environment's complete configuration.

    Returns a dict:
        {name, base_url, timeout, retry_count, static_headers,
         runtime_headers, paths, dir}
    """
    if not env_name:
        raise ConfigError(
            "No environment given. Pass environment=<name> — available: "
            + (", ".join(available_environments(api_root)) or "none found")
        )

    env_key = env_name.strip().lower()
    # Accept the app-facing spellings used elsewhere in the repo
    # (application/environments.md and /run's Staging|Production).
    aliases = {"prod": "production", "staging": "stage"}
    env_key = aliases.get(env_key, env_key)

    env_dir = os.path.join(api_root, "environments", env_key)
    if not os.path.isdir(env_dir):
        known = available_environments(api_root)
        raise ConfigError(
            f"Unknown environment {env_name!r} (looked for {env_dir}). "
            f"Available: {', '.join(known) if known else 'none found'}"
        )

    base = _load_pairs_file(os.path.join(env_dir, "base_url.md"))
    for key in REQUIRED_BASE_KEYS:
        if not base.get(key):
            raise ConfigError(
                f"{os.path.join(env_dir, 'base_url.md')} is missing required key "
                f"{key!r} (or it is empty)."
            )

    def _int(key, default):
        raw = base.get(key, "").strip()
        if not raw:
            return default
        try:
            val = int(raw)
        except ValueError:
            raise ConfigError(
                f"{key} in {os.path.join(env_dir, 'base_url.md')} must be an "
                f"integer, got {raw!r}."
            )
        if val < 0:
            raise ConfigError(f"{key} must not be negative, got {val}.")
        return val

    timeout = _int("timeout", 30)
    if timeout == 0:
        raise ConfigError("timeout must be greater than 0.")

    headers_path = os.path.join(env_dir, "headers.md")
    header_blocks = parse_fenced_blocks(_read(headers_path), headers_path)
    static_headers = parse_pairs(
        header_blocks.get("properties", []), headers_path, "properties"
    )
    runtime_headers = parse_pairs(
        header_blocks.get("runtime", []), headers_path, "runtime"
    )
    for name, ref in runtime_headers.items():
        if not TOKEN_RE.search(ref):
            raise ConfigError(
                f"Runtime header {name!r} in {headers_path} is set to a literal "
                f"({ref!r}). Runtime headers must be ${{...}} references so no "
                "session value is ever committed."
            )

    paths_path = os.path.join(env_dir, "paths.md")
    paths = _load_pairs_file(paths_path)
    if not paths:
        raise ConfigError(f"No paths defined in {paths_path}.")

    return {
        "name": base["environment"],
        "base_url": base["base_url"].rstrip("/"),
        "timeout": timeout,
        "retry_count": _int("retry_count", 0),
        "static_headers": static_headers,
        "runtime_headers": runtime_headers,
        "paths": paths,
        "dir": env_dir,
    }


def load_auth(env_config):
    """Loads the environment's credential chain from auth.md.

    Kept separate from load_environment() so an environment without an auth
    chain (or a run that already has a token) never pays for it or fails on it.
    """
    path = os.path.join(env_config["dir"], "auth.md")
    if not os.path.isfile(path):
        raise ConfigError(
            f"No auth.md for environment {env_config['name']!r} (expected "
            f"{path}). Supply a token directly with `set-runtime token=...` "
            "instead, or add the chain — see api/environments/production/auth.md.")
    return _load_pairs_file(path)


def resolve_path_key(env_config, key):
    """Maps a path key (optionally carrying a query string) to a full URL.

    A full http(s):// value passes through, so a one-off absolute URL doesn't
    need a registry entry.
    """
    raw = (key or "").strip()
    if not raw:
        raise ConfigError("No endpoint given.")
    if raw.startswith("http://") or raw.startswith("https://"):
        return raw

    base_key, _, query = raw.partition("?")
    base_key = base_key.strip()

    path = env_config["paths"].get(base_key)
    if path is None:
        if base_key.startswith("/"):
            path = base_key  # explicit path, not a registry key
        else:
            known = ", ".join(sorted(env_config["paths"])) or "none"
            raise ConfigError(
                f"Unknown endpoint key {base_key!r} for environment "
                f"{env_config['name']!r}. Defined keys: {known}. "
                f"Add it to {os.path.join(env_config['dir'], 'paths.md')}."
            )

    # A registry value may itself be an absolute URL — UMS lives on a different
    # host from the app backend. Check the *resolved* value, not just the key
    # the caller passed, or base_url gets prepended to a full URL.
    if path.startswith("http://") or path.startswith("https://"):
        url = path
    else:
        if not path.startswith("/"):
            path = "/" + path
        url = env_config["base_url"] + path

    if not query:
        return url
    return f"{url}{'&' if '?' in url else '?'}{query}"


def build_headers(env_config, context, include_runtime=True):
    """Merges static headers with runtime headers resolved from the context.

    A runtime reference with no value raises rather than sending an empty
    header: a 401 from a blank token reads as a backend fault, while this names
    the input that is actually missing.

    `include_runtime=False` sends only the static headers — required by the
    endpoints that *produce* credentials (user lookup, login), which cannot
    depend on a token that does not exist yet.
    """
    headers = dict(env_config["static_headers"])
    if not include_runtime:
        return headers
    missing = []
    for name, ref in env_config["runtime_headers"].items():
        value = ref
        for token in TOKEN_RE.findall(ref):
            found, resolved = context.get(token)
            if not found or resolved is None or resolved == "":
                missing.append((name, token))
                break
            value = value.replace("${" + token + "}", str(resolved))
        else:
            headers[name] = value
    if missing:
        detail = "; ".join(f"header {h!r} needs {t}" for h, t in missing)
        inputs = ", ".join(sorted({t.split(".")[-1] for _, t in missing}))
        raise ConfigError(
            f"Missing runtime input(s): {inputs}. {detail}. "
            "Supply them on the /run line, e.g. "
            "`/run environment=production token=... userCode=...`."
        )
    return headers
