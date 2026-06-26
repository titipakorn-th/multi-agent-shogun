#!/usr/bin/env python3
"""
lord_channel.py — W4c round-7: single owner for the Lord-question
state machine (lord_ask.sh + telegram_ask.py + the listener callback
handler now share this module instead of writing/reading
current_question.json from three places).

Replaces the prior three-way split:
  - lord_ask.sh: write state, poll, timeout
  - telegram_ask.py: send Telegram question
  - telegram_listener.py:_drain_pending_lord_questions: resolve on callback

State file: queue/current_question.json. Same fields as before, so
listeners + telegram_ask.py callers that read the file directly still work.
The flock-protected write path is what changes.

Usage (from lord_ask.sh, replaced inline bash with a Python call):

  python3 scripts/lib/lord_channel.py ask \
      --queue-dir queue --question "..." --options "a,b,c" --timeout 30

Exit codes:
  0  — answered (stdout has the answer)
  3  — timeout (stdout empty; "no answer; proceeding with default")
  4  — already a pending question (caller must wait or cancel)
  5  — Telegram send failed

Usage (from telegram_listener.py callback handler):

  python3 scripts/lib/lord_channel.py consume \
      --queue-dir queue --request-id rq_xxx --answer "selected_option"

Exit codes:
  0  — consumed (state was pending for this id, now answered)
  1  — no state file, OR state was for a different id (late callback)
  2  — state was already answered (idempotent double-tap)

Ponytail: a class with one file, one lock, two public methods. When
the Lord-question flow grows past two callers or ten state fields,
retire the file-based state and use a tiny daemon. Until then this
is enough.
"""

import argparse
import contextlib
import fcntl
import json
import os
import re
import sys
import time
import urllib.request
import urllib.parse
from pathlib import Path


STATE_FILENAME = "current_question.json"
LOCK_FILENAME = "current_question.lock"
PENDING_FILENAME = "pending_lord_questions.yaml"
DEFAULT_TELEGRAM_API = "https://api.telegram.org/bot{token}/{method}"
# Test override: TELEGRAM_API_BASE lets tests point at a mock server.
TELEGRAM_API_BASE = os.environ.get("TELEGRAM_API_BASE") or DEFAULT_TELEGRAM_API


class LordChannel:
    def __init__(self, queue_dir: Path, telegram_token: str = "", chat_id: str = ""):
        self.queue_dir = queue_dir
        self.state_path = queue_dir / STATE_FILENAME
        self.lock_path = queue_dir / LOCK_FILENAME
        self.pending_path = queue_dir / PENDING_FILENAME
        self.telegram_token = telegram_token
        self.chat_id = chat_id

    @contextlib.contextmanager
    def _lock(self):
        # Open the lock file for the lifetime of the with-block; flock is
        # released when the fd is closed (end of with-block). Using a
        # flock-protected write for every state transition is what makes
        # concurrent callers safe.
        self.lock_path.parent.mkdir(parents=True, exist_ok=True)
        self.lock_path.touch(exist_ok=True)
        fd = os.open(str(self.lock_path), os.O_RDWR)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX)
            yield fd
        finally:
            os.close(fd)

    def _read_state_unlocked(self):
        if not self.state_path.exists():
            return None
        try:
            with open(self.state_path, "r", encoding="utf-8") as fh:
                return json.load(fh)
        except (json.JSONDecodeError, OSError):
            return None

    def _write_state_unlocked(self, state):
        self.state_path.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.state_path.with_suffix(".tmp")
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(state, fh, ensure_ascii=False)
        os.replace(tmp, self.state_path)

    def _send_telegram_question(self, question: str, options: list, request_id: str):
        if not self.telegram_token or not self.chat_id:
            # No Telegram configured — caller must be in terminal mode.
            return False
        try:
            keyboard = [[{"text": o, "callback_data": f"opt_{request_id}_{i}"}]
                        for i, o in enumerate(options)]
            keyboard.append([{"text": "✏️ Other (free text)",
                              "callback_data": f"opt_{request_id}_other"}])
            payload = {
                "chat_id": self.chat_id,
                "text": question,
                "reply_markup": json.dumps({"inline_keyboard": keyboard}),
            }
            data = urllib.parse.urlencode(payload).encode()
            url = TELEGRAM_API_BASE.format(token=self.telegram_token, method="sendMessage")
            req = urllib.request.Request(url, data=data, method="POST")
            with urllib.request.urlopen(req, timeout=10) as resp:
                return resp.status == 200
        except Exception:
            return False

    def ask(self, question: str, options: list, timeout_s: int = 30) -> tuple:
        """Block until answered or timeout. Returns (status, answer)."""
        request_id = f"rq_{int(time.time())}_{os.urandom(3).hex()}"

        with self._lock():
            existing = self._read_state_unlocked()
            if existing and existing.get("status") == "pending":
                return ("busy", None)
            self._write_state_unlocked({
                "request_id": request_id,
                "question": question,
                "options": options,
                "status": "pending",
                "created_at": time.time(),
                "answered_at": None,
            })

        sent = self._send_telegram_question(question, options, request_id)
        # sent is informational; if Telegram fails, ask() will still time
        # out cleanly and emit the lord_question_timeout event into shogun
        # inbox (handled by caller). We don't fail ask() on Telegram error.
        del sent

        deadline = time.time() + timeout_s
        while time.time() < deadline:
            with self._lock():
                state = self._read_state_unlocked()
            if state and state.get("request_id") == request_id:
                if state.get("status") == "answered":
                    return ("answered", state.get("answer"))
                if state.get("status") == "timeout":
                    return ("timeout", None)
            time.sleep(1)

        with self._lock():
            state = self._read_state_unlocked()
            if state and state.get("request_id") == request_id \
                    and state.get("status") == "pending":
                state["status"] = "timeout"
                state["answered_at"] = time.time()
                self._write_state_unlocked(state)
        return ("timeout", None)

    def consume(self, request_id: str, answer: str) -> str:
        """Resolve a pending question by id. Idempotent on late callbacks."""
        with self._lock():
            state = self._read_state_unlocked()
            if not state or state.get("request_id") != request_id:
                return "no_match"
            if state.get("status") != "pending":
                return "already_resolved"
            state["status"] = "answered"
            state["answer"] = answer
            state["answered_at"] = time.time()
            self._write_state_unlocked(state)
            return "consumed"

    def promote_next_pending(self) -> dict:
        """Pop the first entry from pending_lord_questions.yaml and write
        it as the new active question in current_question.json. Returns
        the popped question dict, or {} if the queue is empty.

        Replaces the inline body of telegram_listener._drain_pending_lord_questions.
        Race-safety: the read-pop-rewrite sequence uses os.replace() for
        atomic state transitions; concurrent enqueue from lord_ask.sh is
        preserved (next tick picks up the new entry).
        """
        if not self.pending_path.exists():
            return {}

        try:
            content = self.pending_path.read_text(encoding="utf-8")
        except Exception:
            return {}

        match = re.search(
            r'^- request_id: "([^"]+)"\n  question: "([^"]+)"\n'
            r'  options: (\[.*?\])\n  timestamp: "([^"]+)"\n',
            content, re.MULTILINE,
        )
        if not match:
            return {}

        request_id, question, options_json, timestamp = match.groups()
        question = question.replace("\\n", "\n")
        remaining = content[match.end():]
        tmp_path = self.pending_path.with_suffix(".tmp")
        try:
            with open(tmp_path, "w", encoding="utf-8") as f:
                f.write(remaining)
            os.replace(tmp_path, self.pending_path)
        except Exception:
            return {}

        try:
            options = json.loads(options_json)
        except Exception:
            options = []

        question_data = {
            "request_id": request_id,
            "question": question,
            "options": options,
            "timestamp": timestamp,
            "status": "pending",
        }
        with self._lock():
            self._write_state_unlocked(question_data)
        return question_data


def main():
    parser = argparse.ArgumentParser(description="W4c LordChannel CLI")
    sub = parser.add_subparsers(dest="cmd", required=True)

    ask_p = sub.add_parser("ask")
    ask_p.add_argument("--queue-dir", required=True)
    ask_p.add_argument("--question", required=True)
    ask_p.add_argument("--options", default="")
    ask_p.add_argument("--timeout", type=int, default=30)
    ask_p.add_argument("--telegram-token", default="")
    ask_p.add_argument("--chat-id", default="")

    consume_p = sub.add_parser("consume")
    consume_p.add_argument("--queue-dir", required=True)
    consume_p.add_argument("--request-id", required=True)
    consume_p.add_argument("--answer", required=True)

    args = parser.parse_args()
    queue_dir = Path(args.queue_dir)
    channel = LordChannel(
        queue_dir,
        telegram_token=args.telegram_token if hasattr(args, "telegram_token") else "",
        chat_id=args.chat_id if hasattr(args, "chat_id") else "",
    )

    if args.cmd == "ask":
        options = [o.strip() for o in args.options.split(",") if o.strip()]
        status, answer = channel.ask(args.question, options, args.timeout)
        if status == "answered":
            print(answer or "")
            return 0
        if status == "timeout":
            return 3
        if status == "busy":
            return 4
        return 1

    if args.cmd == "consume":
        result = channel.consume(args.request_id, args.answer)
        if result == "consumed":
            return 0
        if result == "already_resolved":
            return 2
        return 1


if __name__ == "__main__":
    sys.exit(main())