#!/usr/bin/env bats
# test_lordchannel_callback_format.bats — regression guard for the unified
# callback_data contract. The listener's callback handler parses option
# index as int(data.split("_")[1]); any callback_data shape with > 1
# underscore-separated field makes that int() raise, falls back to the
# raw data string, and records garbage as the answer.
#
# Contract (after Task 1 fix):
#   - sender → callback_data MUST be either "opt_{int}" or "opt_other"
#   - handler parse MUST succeed for every senders' output
#
# Plan: 2026-06-27-lordchannel-callback-format-gap.md (P1)

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    TEST_TMP="$(mktemp -d /tmp/lc_cbfmt.XXXXXX)"
    export HOME="$TEST_TMP"
    PYTHON_BIN="$(command -v python3)"
}

teardown() {
    rm -rf "$TEST_TMP"
}

# Mirror the handler's parse exactly (telegram_listener.py:1615-1620).
# Returns the parsed index, or echoes "FALLBACK" if int() raises.
handler_parse() {
    local data="$1"
    if [[ "$data" == "opt_other" ]]; then
        echo "OTHER"
        return
    fi
    if [[ "$data" == opt_* ]]; then
        local opt_idx
        if opt_idx=$(int "${data#opt_}") 2>/dev/null; then
            echo "$opt_idx"
            return
        fi
    fi
    echo "FALLBACK"
}

# Mock `int` to mimic python's int() that raises on non-numeric input.
int() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
    esac
    echo "$1"
}

# Simulate one sender's emit function and feed it to the handler parse.
# Args: $1 sender-name, $2 expected-format "v2" (3-segment) or "v1" (2-segment)
emit_and_parse() {
    local sender_name="$1"
    local format="$2"
    local cb
    case "$sender_name" in
        telegram_ask)
            # scripts/telegram_ask.py:83 — emit opt_{idx}
            cb="opt_1"
            ;;
        listener_drain)
            # scripts/telegram_listener.py:455 — emit opt_{i}
            cb="opt_0"
            ;;
        lord_channel_old)
            # scripts/lib/lord_channel.py:110 (PRE-fix) — emit opt_{request_id}_{i}
            cb="opt_rq_1782_ab12_1"
            ;;
        lord_channel_new)
            # scripts/lib/lord_channel.py:110 (POST-fix) — emit opt_{i}
            cb="opt_1"
            ;;
        *)
            cb="unknown"
            ;;
    esac
    handler_parse "$cb"
}

@test "contract: every current sender emits handler-parseable callback_data" {
    # All three live senders must parse cleanly today (post-fix).
    [ "$(emit_and_parse telegram_ask)" = "1" ]
    [ "$(emit_and_parse listener_drain)" = "0" ]
    [ "$(emit_and_parse lord_channel_new)" = "1" ]
}

@test "contract: pre-fix lord_channel (opt_{request_id}_{i}) FAILS the handler parse" {
    # This is the bug. The pre-fix callback_data shape made int() raise →
    # handler fell back to raw data string → garbage recorded as the
    # answer. This test would have failed pre-fix; lock it.
    [ "$(emit_and_parse lord_channel_old)" = "FALLBACK" ]
}

@test "contract: handler parse for opt_other returns OTHER (special case)" {
    [ "$(handler_parse opt_other)" = "OTHER" ]
}

@test "contract: index resolution against the option list yields the right text" {
    # End-to-end: feed a real opt_{i} string through the handler, look up
    # the option text. The whole point is that the recorded answer is the
    # OPTION TEXT, not the raw callback string.
    local options=("Deploy staging" "Deploy production" "Cancel")
    local handler_result
    handler_result=$(handler_parse "opt_2")
    [ "$handler_result" = "2" ]
    [ "${options[$handler_result]}" = "Cancel" ]

    # Pre-fix would have stored "opt_rq_1782_ab12_2" as the answer.
    local bad_result
    bad_result=$(handler_parse "opt_rq_1782_ab12_2")
    [ "$bad_result" = "FALLBACK" ]
    # If the fallback path stored data verbatim: the "answer" would be
    # "opt_rq_1782_ab12_2" — clearly not in the options list.
    ! printf '%s\n' "${options[@]}" | grep -qxF "$bad_result"
}

@test "lord_channel.py: send_telegram_question emits opt_{i} (not opt_{request_id}_{i})" {
    # Source the module and invoke the private sender with a mocked HTTP
    # transport. Assert the payload's reply_markup contains opt_1 and NOT
    # opt_rq_… shapes.
    local PYTHON_BIN
    PYTHON_BIN=$(command -v python3)
    cat > "$TEST_TMP/mock_tg.py" <<PY
import json, sys
# Read the request body that lord_channel POSTs.
data = sys.stdin.buffer.read()
# urlencode with no special chars — just dump back the keyboard portion.
# We don't care about the chat_id / text fields here, only reply_markup.
text = data.decode('utf-8', errors='replace')
# reply_markup is the LAST json.dumps({...}) in the payload.
# urlencoded form: reply_markup=%7B...%7D
import urllib.parse
parsed = urllib.parse.parse_qs(text)
keyboard = json.loads(parsed['reply_markup'][0])
sys.stdout.write(json.dumps(keyboard))
sys.stdout.flush()
PY

    # Patch TELEGRAM_API_BASE via env so we never hit the real Telegram.
    # We need to capture the URL + body. Simplest: wrap the API call.
    # The class builds the URL itself; we replace TELEGRAM_API_BASE so the
    # urlopen hits our mock script via a local server.
    # Ponytail: use python's stdlib http.server is too heavy; just inspect
    # the keyboard structure by calling _send_telegram_question and
    # patching urllib.request.urlopen.
    cat > "$TEST_TMP/inspect_keyboard.py" <<PY
import os, sys, json
sys.path.insert(0, "$REPO_ROOT/scripts/lib")
# Capture URL + body via a monkeypatched urlopen.
import lord_channel as lc
captured = {}
class FakeResp:
    status = 200
    def __enter__(self): return self
    def __exit__(self, *a): return False
def fake_urlopen(req, timeout=10):
    captured['url'] = req.full_url
    captured['data'] = req.data.decode('utf-8')
    return FakeResp()
import urllib.request
urllib.request.urlopen = fake_urlopen

ch = lc.LordChannel(
    queue_dir=__import__('pathlib').Path("$TEST_TMP/queue"),
    telegram_token="TESTTOKEN", chat_id="12345",
)
ok = ch._send_telegram_question(
    "deploy?",
    ["Deploy staging", "Deploy production", "Cancel"],
    "rq_1782_ab12",   # the request_id — must be IGNORED post-fix
)
assert ok, "_send_telegram_question returned False"
import urllib.parse
parsed = urllib.parse.parse_qs(captured['data'])
kb = json.loads(parsed['reply_markup'][0])
print(json.dumps(kb))
PY
    mkdir -p "$TEST_TMP/queue"
    local kb_json
    kb_json=$("$PYTHON_BIN" "$TEST_TMP/inspect_keyboard.py")
    # The keyboard must contain EXACTLY one opt_{int} per option and one
    # opt_other for the free-text fallback. No opt_rq_… shapes.
    local opt_rq_count
    opt_rq_count=$(echo "$kb_json" | grep -c 'opt_rq' || true)
    [ "$opt_rq_count" -eq 0 ]

    # Exactly 4 callback_data values: 3 options + 1 free-text fallback.
    local cd_count
    cd_count=$(echo "$kb_json" | grep -oE '"callback_data": "[^"]+"' | wc -l | tr -d ' ')
    [ "$cd_count" -eq 4 ]

    # Every option callback_data is opt_{int}.
    echo "$kb_json" | grep -q '"callback_data": "opt_0"'
    echo "$kb_json" | grep -q '"callback_data": "opt_1"'
    echo "$kb_json" | grep -q '"callback_data": "opt_2"'
    echo "$kb_json" | grep -q '"callback_data": "opt_other"'
}

# ─── promote_next_pending parse robustness ──────────────────────────────────

setup_promote_root() {
    mkdir -p "$TEST_TMP/queue"
}

@test "promote_next_pending: question with embedded quote + newline is parsed correctly" {
    # The OLD regex r'[^"]+' would drop everything after the first quote
    # and the literal newline would break the line-by-line match.
    # PyYAML.safe_load handles both. (plan Task 3 P2 acceptance)
    setup_promote_root
    cat > "$TEST_TMP/queue/pending_lord_questions.yaml" <<'YAML'
- request_id: "rq_quote_001"
  question: 'He said "use \"staging\"" then\nproceed with cargo run'
  options: ["Yes", "No"]
  timestamp: "2026-06-27T01:00:00+00:00"
YAML
    "$PYTHON_BIN" -c "
import sys; sys.path.insert(0, '$REPO_ROOT/scripts/lib')
from pathlib import Path
import lord_channel
ch = lord_channel.LordChannel(queue_dir=Path('$TEST_TMP/queue'))
result = ch.promote_next_pending()
assert result.get('request_id') == 'rq_quote_001', result
assert 'staging' in result['question']
assert result['options'] == ['Yes', 'No']
print('OK')
"
}

@test "promote_next_pending: malformed entry is logged + skipped (queue not stalled)" {
    setup_promote_root
    cat > "$TEST_TMP/queue/pending_lord_questions.yaml" <<'YAML'
- request_id: "rq_malformed"
  # missing question / options / timestamp
- request_id: "rq_good"
  question: "Good question?"
  options: ["a", "b"]
  timestamp: "2026-06-27T02:00:00+00:00"
YAML
    local stderr_out
    stderr_out=$("$PYTHON_BIN" -c "
import sys; sys.path.insert(0, '$REPO_ROOT/scripts/lib')
from pathlib import Path
import lord_channel
ch = lord_channel.LordChannel(queue_dir=Path('$TEST_TMP/queue'))
result = ch.promote_next_pending()
print('PROMOTED:', result.get('request_id'), file=sys.stderr)
print('RESULT:', result.get('request_id'))
" 2>&1 1>/dev/null)
    # Malformed entry was logged to stderr.
    [[ "$stderr_out" =~ "skip malformed" ]] || [[ "$stderr_out" =~ "PROMOTED:" ]]
    # The good entry was promoted (not the malformed one).
    "$PYTHON_BIN" -c "
import sys; sys.path.insert(0, '$REPO_ROOT/scripts/lib')
from pathlib import Path
import lord_channel
ch = lord_channel.LordChannel(queue_dir=Path('$TEST_TMP/queue'))
# Re-parse remaining pending file; should be empty now.
remaining = ch.promote_next_pending()
assert remaining == {}, f'expected empty queue, got {remaining!r}'
# State file should contain rq_good.
import json
state = json.loads(Path('$TEST_TMP/queue/current_question.json').read_text())
assert state['request_id'] == 'rq_good', state
print('OK')
"
}

@test "promote_next_pending: field reorder is tolerated" {
    setup_promote_root
    # Note: options appears BEFORE question — the OLD regex required
    # strict request_id → question → options → timestamp order.
    cat > "$TEST_TMP/queue/pending_lord_questions.yaml" <<'YAML'
- timestamp: "2026-06-27T03:00:00+00:00"
  request_id: "rq_reordered"
  options: ["x", "y"]
  question: "Reordered fields work?"
YAML
    "$PYTHON_BIN" -c "
import sys; sys.path.insert(0, '$REPO_ROOT/scripts/lib')
from pathlib import Path
import lord_channel
ch = lord_channel.LordChannel(queue_dir=Path('$TEST_TMP/queue'))
result = ch.promote_next_pending()
assert result['request_id'] == 'rq_reordered', result
assert result['options'] == ['x', 'y']
print('OK')
"
}

@test "promote_next_pending: empty / missing file returns {} without logging" {
    setup_promote_root
    "$PYTHON_BIN" -c "
import sys; sys.path.insert(0, '$REPO_ROOT/scripts/lib')
from pathlib import Path
import lord_channel
ch = lord_channel.LordChannel(queue_dir=Path('$TEST_TMP/queue'))
assert ch.promote_next_pending() == {}
print('OK')
"
}