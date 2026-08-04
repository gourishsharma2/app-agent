#!/usr/bin/env python3
"""
http_executor.py — issues the HTTP request and normalizes every failure mode.

Standard library only (`urllib`), matching run_plan.py, which already talks to
Appium the same way. No `requests` dependency is introduced.

Design points
-------------
* **A non-2xx is data, not an exception.** 401/403/500 come back as a normal
  result with `status` set, so a flow can assert on them and a report can show
  what the backend actually said. Only failures with no response at all
  (timeout, DNS, refused connection) raise.
* **Retries are narrow.** Only timeouts, network errors and 5xx are retried;
  a 4xx is a definitive answer and retrying it just multiplies the wait — and
  on the login endpoint would burn the shared account's rate limit.
* **Malformed JSON is not fatal here.** `json` is None and `text` holds the
  raw body, so the caller reports "returned HTML, not JSON" rather than dying
  inside a parser.
"""
import json
import time
import urllib.error
import urllib.request

RETRYABLE_STATUS = range(500, 600)
MAX_LOGGED_BODY = 400


class ApiError(Exception):
    """A request that produced no usable response, with an actionable message."""

    def __init__(self, message, kind):
        super().__init__(message)
        self.kind = kind


def _diagnose_urlerror(e, url, timeout):
    reason = getattr(e, "reason", e)
    text = str(reason).lower()
    if "timed out" in text or isinstance(reason, TimeoutError):
        return ApiError(
            f"Timeout after {timeout}s calling {url}. The backend did not "
            "respond in time — check connectivity, or raise `timeout` in the "
            "environment's base_url.md.",
            "timeout",
        )
    if "name or service not known" in text or "nodename nor servname" in text \
            or "getaddrinfo" in text:
        return ApiError(
            f"Cannot resolve the host in {url}. Check `base_url` in the "
            "environment's base_url.md — an unset or placeholder host fails "
            "exactly like this.",
            "dns",
        )
    if "connection refused" in text:
        return ApiError(
            f"Connection refused by {url}. The host resolved but nothing is "
            "listening — check `base_url` and any VPN requirement.",
            "connection-refused",
        )
    if "certificate" in text or "ssl" in text:
        return ApiError(
            f"TLS failure calling {url}: {reason}. Check the scheme and host in "
            "base_url.md.",
            "tls",
        )
    return ApiError(f"Network failure calling {url}: {reason}", "network")


def _explain_status(status, body_text, url):
    """A short, actionable note attached to a non-2xx response."""
    snippet = (body_text or "").strip().replace("\n", " ")[:MAX_LOGGED_BODY]
    if status == 401:
        return ("401 Unauthorized — the `token` runtime input is missing, "
                "expired, or belongs to a different environment. Supply a "
                "fresh token on the /run line. Backend said: " + snippet)
    if status == 403:
        return ("403 Forbidden — the token is valid but this account may not "
                "access this endpoint. Check that `user-code` matches the "
                "account the app is logged in as. Backend said: " + snippet)
    if status == 404:
        return (f"404 Not Found for {url} — check the path in the "
                "environment's paths.md. Backend said: " + snippet)
    if status == 429:
        return ("429 Too Many Requests — this backend rate-limits; wait before "
                "retrying. Backend said: " + snippet)
    if status in RETRYABLE_STATUS:
        return (f"{status} server error — the backend failed, not the app. "
                "Backend said: " + snippet)
    return f"HTTP {status}. Backend said: " + snippet


def execute(method, url, headers, body=None, timeout=30, retries=0, log=None):
    """Performs the request and returns a normalized result dict:

        {method, url, status, headers, json, text, elapsedMs, note, attempts}

    Raises ApiError only when no response was obtained at all.
    """
    method = (method or "GET").upper()
    data = None
    send_headers = dict(headers or {})

    if body is not None:
        if isinstance(body, (dict, list)):
            data = json.dumps(body).encode("utf-8")
        else:
            data = str(body).encode("utf-8")
        send_headers.setdefault("Content-Type", "application/json")

    attempts = 0
    last_error = None
    total_attempts = max(1, retries + 1)

    while attempts < total_attempts:
        attempts += 1
        started = time.monotonic()
        req = urllib.request.Request(url, data=data, method=method,
                                     headers=send_headers)
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                raw = resp.read()
                status = resp.getcode()
                resp_headers = {k.lower(): v for k, v in resp.headers.items()}
        except urllib.error.HTTPError as e:
            # A status-bearing response — real data, not a transport failure.
            raw = e.read() if hasattr(e, "read") else b""
            status = e.code
            resp_headers = {k.lower(): v for k, v in (e.headers or {}).items()}
        except urllib.error.URLError as e:
            last_error = _diagnose_urlerror(e, url, timeout)
            if attempts < total_attempts:
                if log:
                    log(f"api: attempt {attempts} failed ({last_error.kind}) — retrying")
                time.sleep(min(2 * attempts, 5))
                continue
            raise last_error
        except TimeoutError:
            last_error = ApiError(
                f"Timeout after {timeout}s calling {url}.", "timeout")
            if attempts < total_attempts:
                if log:
                    log(f"api: attempt {attempts} timed out — retrying")
                time.sleep(min(2 * attempts, 5))
                continue
            raise last_error

        elapsed_ms = int((time.monotonic() - started) * 1000)
        text = raw.decode("utf-8", errors="replace")

        if status in RETRYABLE_STATUS and attempts < total_attempts:
            if log:
                log(f"api: attempt {attempts} got {status} — retrying")
            time.sleep(min(2 * attempts, 5))
            continue

        parsed = None
        note = None
        if text.strip():
            try:
                parsed = json.loads(text)
            except json.JSONDecodeError as e:
                note = (f"Response body is not valid JSON ({e}). First "
                        f"{MAX_LOGGED_BODY} chars: "
                        + text.strip().replace("\n", " ")[:MAX_LOGGED_BODY])
        else:
            note = "Response body was empty."

        if not (200 <= status < 300):
            status_note = _explain_status(status, text, url)
            note = f"{status_note} | {note}" if note else status_note

        return {
            "method": method,
            "url": url,
            "status": status,
            "headers": resp_headers,
            "json": parsed,
            "text": text,
            "elapsedMs": elapsed_ms,
            "note": note,
            "attempts": attempts,
        }

    raise last_error or ApiError(f"Request to {url} failed.", "unknown")
