#!/usr/bin/env python3
"""
multi-agent-shogun operator smoke test.

Verifies the Telegram infrastructure is wired up correctly. Run after any
change to the Telegram stack (env, scripts, daemons) to catch things like
ntfy.sh left as a mock or a stale bot token.

Usage:
    python3 scripts/smoke_test.py

Exit codes:
    0  all checks PASS
    1  at least one check FAIL
    2  all PASS but at least one WARN (still operator-actionable, but not broken)
"""
import datetime
import json
import os
import re
import socket
import subprocess
import sys
import urllib.error
import urllib.request

# ---------------------------------------------------------------------------
# Constants & helpers
# ---------------------------------------------------------------------------

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.dirname(SCRIPT_DIR)

NTFY_SH = os.path.join(PROJECT_ROOT, "scripts", "ntfy.sh")
TELEGRAM_ENV = os.path.join(PROJECT_ROOT, "config", "telegram.env")
CURRENT_QUESTION = os.path.join(PROJECT_ROOT, "queue", "current_question.json")
TELEGRAM_ASK_PY = os.path.join(PROJECT_ROOT, "scripts", "telegram_ask.py")
TELEGRAM_LISTENER_PY = os.path.join(PROJECT_ROOT, "scripts", "telegram_listener.py")
DASHBOARD_MD = os.path.join(PROJECT_ROOT, "dashboard.md")

VALID_STATUSES = {"pending", "waiting_for_free_text", "answered"}
TOKEN_PATTERN = re.compile(r"^[0-9]+:[A-Za-z0-9_-]+$")
HTTP_TIMEOUT = 5  # seconds


def redact_token(token):
    """Show first 8 chars + *** for a Telegram bot token."""
    if not token:
        return ""
    if len(token) <= 8:
        return token[:3] + "***"
    return token[:8] + "***"


def redact_chat(chat_id):
    """Show only last 3 digits of a chat id."""
    if not chat_id:
        return ""
    if len(chat_id) <= 3:
        return "***"
    return "***" + chat_id[-3:]


def load_telegram_env(path):
    """Parse a KEY=VALUE env file into a dict (no shell)."""
    env = {}
    if not os.path.isfile(path):
        return env
    with open(path, "r", encoding="utf-8") as fh:
        for raw in fh:
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, val = line.split("=", 1)
            env[key.strip()] = val.strip()
    return env


def telegram_get(token, method, payload=None):
    """Tiny GET/POST wrapper for api.telegram.org with short timeout."""
    url = f"https://api.telegram.org/bot{token}/{method}"
    headers = {"Content-Type": "application/json"}
    data = json.dumps(payload).encode("utf-8") if payload is not None else None
    req = urllib.request.Request(url, data=data, headers=headers,
                                 method="POST" if data is not None else "GET")
    try:
        with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as res:
            body = res.read().decode("utf-8")
            return json.loads(body), None
    except urllib.error.HTTPError as e:
        try:
            err_body = e.read().decode("utf-8")
            err_json = json.loads(err_body)
            return None, f"HTTP {e.code} {e.reason}: {err_json.get('description', '')}".strip()
        except Exception:
            return None, f"HTTP {e.code} {e.reason}"
    except urllib.error.URLError as e:
        return None, f"URL error: {e.reason}"
    except Exception as e:
        return None, f"{type(e).__name__}: {e}"


# ---------------------------------------------------------------------------
# Individual checks
# ---------------------------------------------------------------------------

def check_1_ntfy_real():
    try:
        with open(NTFY_SH, "r", encoding="utf-8") as fh:
            first_lines = [next(fh, "").rstrip("\n") for _ in range(3)]
        # Mock signature: shebang + 'echo "MOCK_NTFY"'
        is_mock = (
            len(first_lines) <= 2
            and first_lines[0].startswith("#!/bin/bash")
            and any("MOCK_NTFY" in line for line in first_lines[1:])
        )
        if is_mock:
            return "FAIL", "ntfy.sh appears to be a mock — restore from git"
        # Real signature: first line is shebang, second is the SayTask notification header
        if "SayTask Notification" in (first_lines[1] if len(first_lines) > 1 else ""):
            return "PASS", ""
        # If we got here, the file is neither the mock nor the known-real header.
        return "FAIL", "ntfy.sh is not the expected real script (header not found)"
    except FileNotFoundError:
        return "FAIL", f"ntfy.sh not found at {NTFY_SH}"
    except Exception as e:
        return "FAIL", f"{type(e).__name__}: {e}"


def check_2_telegram_env():
    env = load_telegram_env(TELEGRAM_ENV)
    if not env:
        return "FAIL", f"{TELEGRAM_ENV} missing or empty"
    token = env.get("TELEGRAM_BOT_TOKEN", "")
    chat_id = env.get("TELEGRAM_CHAT_ID", "")
    if not token or token == "your_bot_token_here":
        return "FAIL", "TELEGRAM_BOT_TOKEN is unset or still the placeholder"
    if not chat_id or chat_id == "your_chat_id_here":
        return "FAIL", "TELEGRAM_CHAT_ID is unset or still the placeholder"
    if not TOKEN_PATTERN.match(token):
        return "FAIL", f"TELEGRAM_BOT_TOKEN does not look like a valid token (expected <digits>:<alphanum>)"
    if not chat_id.lstrip("-").isdigit():
        return "FAIL", f"TELEGRAM_CHAT_ID is not numeric (got {chat_id!r})"
    return "PASS", f"token={redact_token(token)}, chat={redact_chat(chat_id)}"


def check_3_api_reachable(token, _chat_id):
    body, err = telegram_get(token, "getMe")
    if err is not None:
        return "FAIL", err
    if not body or not body.get("ok"):
        return "FAIL", body.get("description", "Telegram getMe returned ok=false")
    username = (body.get("result") or {}).get("username", "")
    if not username:
        return "FAIL", "Telegram getMe returned no username"
    return "PASS", f"bot=@{username}"


def check_4_send_message(token, chat_id):
    payload = {
        "chat_id": chat_id,
        "text": (
            f"\U0001f527 smoke test from {socket.gethostname()} at "
            f"{datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')} — please ignore"
        ),
    }
    body, err = telegram_get(token, "sendMessage", payload)
    if err is not None:
        return "FAIL", err
    if not body or not body.get("ok"):
        return "FAIL", body.get("description", "sendMessage returned ok=false")
    msg_id = (body.get("result") or {}).get("message_id", "?")
    return "PASS", f"message_id={msg_id}"


def check_5_ntfy_end_to_end():
    if not os.path.isfile(NTFY_SH):
        return "FAIL", f"ntfy.sh not found at {NTFY_SH}"
    try:
        proc = subprocess.run(
            ["bash", NTFY_SH, "\U0001f527 smoke test via ntfy.sh — please ignore"],
            capture_output=True, text=True, timeout=HTTP_TIMEOUT,
        )
    except subprocess.TimeoutExpired:
        return "FAIL", "ntfy.sh timed out"
    except Exception as e:
        return "FAIL", f"{type(e).__name__}: {e}"
    if proc.returncode != 0:
        stderr = (proc.stderr or "").strip()
        return "FAIL", f"exit code {proc.returncode}" + (f", stderr={stderr}" if stderr else "")
    return "PASS", ""


def check_6_current_question():
    if not os.path.exists(CURRENT_QUESTION):
        return "SKIP", "file does not exist"
    try:
        with open(CURRENT_QUESTION, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except json.JSONDecodeError as e:
        return "FAIL", f"invalid JSON: {e}"
    except Exception as e:
        return "FAIL", f"{type(e).__name__}: {e}"
    status = data.get("status")
    if status not in VALID_STATUSES:
        return "FAIL", f"unexpected status {status!r} (expected one of {sorted(VALID_STATUSES)})"
    return "PASS", f"status={status}"


def _syntax_check(path):
    if not os.path.isfile(path):
        return "FAIL", f"file not found: {path}"
    try:
        import ast
        with open(path, "r", encoding="utf-8") as fh:
            ast.parse(fh.read())
        return "PASS", ""
    except SyntaxError as e:
        return "FAIL", f"SyntaxError: {e}"
    except Exception as e:
        return "FAIL", f"{type(e).__name__}: {e}"


def check_7_ask_syntax():
    return _syntax_check(TELEGRAM_ASK_PY)


def check_8_listener_syntax():
    return _syntax_check(TELEGRAM_LISTENER_PY)


def check_9_listener_running():
    try:
        out = subprocess.run(
            ["pgrep", "-f", "telegram_listener"],
            capture_output=True, text=True, timeout=HTTP_TIMEOUT,
        )
    except Exception as e:
        return "WARN", f"pgrep failed: {e}"
    pids = [line.strip() for line in out.stdout.splitlines() if line.strip()]
    if pids:
        return "PASS", f"PID(s)={','.join(pids)}"
    return "WARN", "telegram_listener is not running (it may be intentionally stopped)"


def check_10_dashboard():
    if not os.path.isfile(DASHBOARD_MD):
        return "WARN", "dashboard.md does not exist"
    try:
        with open(DASHBOARD_MD, "r", encoding="utf-8") as fh:
            content = fh.read()
    except Exception as e:
        return "WARN", f"could not read dashboard.md: {e}"
    if "## " not in content:
        return "WARN", "dashboard.md has no second-level heading (file may be empty)"
    return "PASS", ""


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

CHECKS = [
    ("ntfy.sh is real",                 check_1_ntfy_real),
    ("telegram.env credentials",        check_2_telegram_env),
    ("Telegram API reachable",          None),  # filled after we know the token
    ("Telegram sendMessage",            None),
    ("ntfy.sh end-to-end",              check_5_ntfy_end_to_end),
    ("current_question.json",           check_6_current_question),
    ("telegram_ask.py syntax",          check_7_ask_syntax),
    ("telegram_listener.py syntax",     check_8_listener_syntax),
    ("listener process running",        check_9_listener_running),
    ("dashboard.md parseable",          check_10_dashboard),
]


def _pad(s, width):
    return s + ("." * max(1, width - len(s)))


def run():
    env = load_telegram_env(TELEGRAM_ENV)
    token = env.get("TELEGRAM_BOT_TOKEN", "")
    chat_id = env.get("TELEGRAM_CHAT_ID", "")

    def c3():
        return check_3_api_reachable(token, chat_id)

    def c4():
        return check_4_send_message(token, chat_id)

    # Patch the deferred slots.
    CHECKS[2] = (CHECKS[2][0], c3)
    CHECKS[3] = (CHECKS[3][0], c4)

    name_width = max(len(name) for name, _ in CHECKS) + 2

    print("=== multi-agent-shogun Smoke Test ===")
    print(f"Date: {datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print(f"Host: {socket.gethostname()}")
    print()

    results = []  # list of (index, name, status, message)
    for i, (name, fn) in enumerate(CHECKS, start=1):
        try:
            status, message = fn() or ("FAIL", "check returned None")
        except Exception as e:
            status, message = "FAIL", f"{type(e).__name__}: {e}"
        results.append((i, name, status, message))

    total = len(results)
    for i, name, status, message in results:
        suffix = f" ({message})" if message else ""
        print(f"[{i:>{len(str(total))}}/{total}] {_pad(name, name_width)} {status}{suffix}")

    print()
    n_pass = sum(1 for _, _, s, _ in results if s == "PASS")
    n_fail = sum(1 for _, _, s, _ in results if s == "FAIL")
    n_warn = sum(1 for _, _, s, _ in results if s == "WARN")
    n_skip = sum(1 for _, _, s, _ in results if s == "SKIP")
    print(f"Result: {n_pass} PASS, {n_fail} FAIL, {n_warn} WARN, {n_skip} SKIP")

    if n_fail == 0 and n_warn == 0:
        print("✓ Ready for Lord to use")
        return 0
    if n_fail == 0:
        print("⚠ Ready for Lord to use (with warnings)")
        return 2

    print("✗ NOT ready — fix the failing checks before going live")
    print()
    print("Failures:")
    for i, name, status, message in results:
        if status == "FAIL":
            extra = f": {message}" if message else ""
            print(f"  [{i:>{len(str(total))}}/{total}] {name}{extra}")
    return 1


if __name__ == "__main__":
    sys.exit(run())
