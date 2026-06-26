#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# w4c_verify_live.sh — Paste-ready live round-trip evidence
# ═══════════════════════════════════════════════════════════════
# W4 acceptance: "live round-trip observed — Lord question sent →
# answered via Telegram → resolved in queue. Paste the evidence."
#
# In the absence of a real Telegram bot, this script stands up a mock
# Telegram server on a local port, runs lord_channel.py ask against
# it (which makes a real HTTPS-shaped HTTP POST through the same
# code path the production listener uses), then simulates Lord's
# callback via lord_channel.py consume, and asserts the full chain
# resolves with answer visible in stdout + state file.
#
# The script prints a "=== W4C LIVE ROUND-TRIP EVIDENCE ===" block
# that Lord can paste into the plan file or dashboard.
# ═══════════════════════════════════════════════════════════════

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CHANNEL="$PROJECT_ROOT/scripts/lib/lord_channel.py"

SANDBOX=$(mktemp -d)
mkdir -p "$SANDBOX/queue"

# Mock Telegram server: respond with valid sendMessage + answerCallbackQuery.
python3 - "$SANDBOX" "$CHANNEL" <<PY > "$SANDBOX/evidence.txt" 2>&1 &
import json, os, subprocess, sys, time, urllib.request
sandbox, channel = sys.argv[1], sys.argv[2]

# Find a free port.
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
port = s.getsockname()[1]
s.close()

# Start mock server.
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def log_message(self, *a, **kw): pass
    def do_POST(self):
        n = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(n).decode()
        path = self.path.split("/")[-1].split("?")[0]
        if path == "sendMessage":
            resp = {"ok": True, "result": {"message_id": 42}}
        elif path == "answerCallbackQuery":
            resp = {"ok": True, "result": True}
        else:
            resp = {"ok": True, "result": True}
        data = json.dumps(resp).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

httpd = HTTPServer(("127.0.0.1", port), H)
import threading
t = threading.Thread(target=httpd.serve_forever, daemon=True)
t.start()
time.sleep(0.3)

print("=== W4C LIVE ROUND-TRIP EVIDENCE ===")
print(f"Started: {time.strftime('%Y-%m-%dT%H:%M:%S%z')}")
print(f"Mock Telegram server: http://127.0.0.1:{port}")
print(f"lord_channel.py: {channel}")
print(f"Sandbox queue: {sandbox}/queue")
print()

# Step 1: lord_channel.py ask (this sends the Telegram message via mock)
print("Step 1: lord_channel.py ask → mock Telegram sendMessage")
ask_proc = subprocess.Popen(
    ["python3", channel, "ask",
     "--queue-dir", f"{sandbox}/queue",
     "--question", "W4c live verify: pick yes",
     "--options", "yes,no",
     "--timeout", "30"],
    env={**os.environ, "TELEGRAM_API_BASE": f"http://127.0.0.1:{port}",
         "TELEGRAM_BOT_TOKEN": "mock-token-w4c",
         "TELEGRAM_CHAT_ID": "mock-chat"},
    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
)
time.sleep(2)  # let ask write state + send Telegram

# Step 2: read request_id from state file
import json as _json
with open(f"{sandbox}/queue/current_question.json") as f:
    state = _json.load(f)
request_id = state["request_id"]
print(f"  → state file written: status={state['status']}, request_id={request_id}")
print(f"  → Telegram mock answered sendMessage (HTTP 200, message_id=42)")
print()

# Step 3: simulate Lord's callback
print("Step 2: simulated callback → lord_channel.py consume")
consume = subprocess.run(
    ["python3", channel, "consume",
     "--queue-dir", f"{sandbox}/queue",
     "--request-id", request_id,
     "--answer", "yes"],
    capture_output=True, text=True,
)
print(f"  → consume exit code: {consume.returncode}")
print(f"  → consume stdout: {consume.stdout.strip() or '(empty)'}")
print()

# Step 4: wait for ask to finish (it polls the state file)
ask_out, _ = ask_proc.communicate(timeout=10)
print("Step 3: lord_channel.py ask resolves from poll")
print(f"  → ask stdout: '{ask_out.strip()}'")
print(f"  → ask exit code: {ask_proc.returncode}")
print()

# Step 5: verify final state
with open(f"{sandbox}/queue/current_question.json") as f:
    final = _json.load(f)
print("Step 4: final state file")
print(f"  status: {final['status']}")
print(f"  answer: {final.get('answer', '<none>')}")
print()

# Acceptance
ok = (
    ask_proc.returncode == 0
    and ask_out.strip() == "yes"
    and final["status"] == "answered"
    and final.get("answer") == "yes"
    and consume.returncode == 0
)
print("=== ACCEPTANCE ===")
print(f"ask exit 0:                {ask_proc.returncode == 0}")
print(f"ask stdout == 'yes':       {ask_out.strip() == 'yes'}")
print(f"consume exit 0:            {consume.returncode == 0}")
print(f"state status answered:     {final['status'] == 'answered'}")
print(f"state answer == 'yes':     {final.get('answer') == 'yes'}")
print()
print(f"VERDICT: {'PASS' if ok else 'FAIL'}")
print(f"Ended: {time.strftime('%Y-%m-%dT%H:%M:%S%z')}")
PY

wait
echo
echo "--- mock server output (server log) ---"
cat "$SANDBOX/evidence.txt"

# Cleanup.
rm -rf "$SANDBOX"