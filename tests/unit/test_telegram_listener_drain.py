# test_telegram_listener_drain.py — Regression test for the C1 race in
# _drain_pending_lord_questions.
#
# Background: the original drain did
#     content = f.read()
#     ...
#     remaining = content[match.end():]
#     f.write(remaining)
# which is NOT atomic. If a second lord_ask.sh enqueue appended to the
# pending file between the read and the write, the new entry was
# clobbered (it was neither in `content` nor in `remaining`, and the
# write overwrote the file with the stale `remaining` snapshot).
#
# This test reproduces that race: seed the file with one entry, spawn a
# thread that appends a second entry, then call the drain. The
# critical invariant is that the second entry is NEVER silently lost
# (it must either be processed by the drain or still be in the file
# when the drain returns).

import importlib.util
import json
import os
import sys
import tempfile
import threading
import time

# Import telegram_listener via importlib so we control the module
# loading (avoids surprises with module-level side effects when
# multiple pytest files in tests/unit/ might both try to import it
# via sys.path-based loading). We patch make_telegram_request before
# exec_module so the module's body — and the drain's call to
# make_telegram_request — uses the no-op stub.
SCRIPTS_DIR = os.path.abspath(
    os.path.join(os.path.dirname(__file__), "..", "..", "scripts")
)
SPEC = importlib.util.spec_from_file_location(
    "telegram_listener", os.path.join(SCRIPTS_DIR, "telegram_listener.py")
)
telegram_listener = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(telegram_listener)

# After exec_module, monkey-patch the module-level function. This
# must happen after import (the module's body doesn't call it, so
# the exec order doesn't matter for the body — but the drain calls
# make_telegram_request via module-level lookup, so we patch the
# module's attribute).
telegram_listener.make_telegram_request = (
    lambda *a, **kw: {"ok": True, "result": {"message_id": 1}}
)


def _seed_pending(path, request_id, question):
    """Write a single 4-line YAML mapping to the pending file."""
    content = (
        f'- request_id: "{request_id}"\n'
        f'  question: "{question}"\n'
        f'  options: []\n'
        f'  timestamp: "2026-06-13T00:00:00+00:00"\n'
    )
    with open(path, "w", encoding="utf-8") as f:
        f.write(content)


def _append_pending(path, request_id, question):
    """Append a second 4-line YAML mapping to the pending file."""
    content = (
        f'- request_id: "{request_id}"\n'
        f'  question: "{question}"\n'
        f'  options: []\n'
        f'  timestamp: "2026-06-13T00:00:01+00:00"\n'
    )
    with open(path, "a", encoding="utf-8") as f:
        f.write(content)


def test_drain_does_not_lose_concurrent_enqueue(tmp_path):
    """When a second enqueue lands during the drain, the new entry
    must survive (either be popped or remain in the pending file)."""
    # The drain resolves the pending file relative to script_dir's
    # parent. We pass tmp_path as script_dir and create the queue
    # structure under it so os.path.abspath resolves to tmp_path/queue/.
    script_dir = tmp_path / "scripts"
    script_dir.mkdir()
    queue_dir = script_dir.parent / "queue"
    queue_dir.mkdir()
    pending = queue_dir / "pending_lord_questions.yaml"
    current = queue_dir / "current_question.json"
    # current_question.json may be written by the drain — pre-create
    # parent only; the drain will create the file.

    # Seed with one entry
    _seed_pending(pending, "rid-1", "first")

    # Spawn a thread that appends a second entry after a short delay
    append_done = threading.Event()
    append_started = threading.Event()

    def append_second():
        append_started.set()
        # Small delay so the drain has time to begin its read
        time.sleep(0.05)
        _append_pending(pending, "rid-2", "second")
        append_done.set()

    t = threading.Thread(target=append_second)
    t.start()
    append_started.wait(timeout=1.0)

    # Call the drain. The mocked make_telegram_request must NOT race
    # — the drain only does a small amount of I/O before returning.
    try:
        telegram_listener._drain_pending_lord_questions(
            str(script_dir), "fake-token", "fake-chat"
        )
    finally:
        t.join(timeout=2.0)

    assert append_done.is_set(), "append thread did not complete"

    # Read the pending file (if it still exists) and the current
    # question file. The critical assertion: rid-2 must NOT be lost.
    pending_text = ""
    if pending.exists():
        pending_text = pending.read_text(encoding="utf-8")

    current_text = ""
    if current.exists():
        current_text = current.read_text(encoding="utf-8")

    rid2_in_pending = "rid-2" in pending_text
    rid2_in_current = "rid-2" in current_text

    assert rid2_in_pending or rid2_in_current, (
        f"rid-2 was silently dropped by the drain! "
        f"pending={pending_text!r} current={current_text!r}"
    )

    # Cleanup: remove the pending file so subsequent tests start fresh.
    if pending.exists():
        pending.unlink()


def test_drain_pops_single_entry_with_no_concurrent_enqueue(tmp_path):
    """Sanity check: the new tmp+os.replace path still works for the
    simple single-pop case (no race)."""
    script_dir = tmp_path / "scripts"
    script_dir.mkdir()
    queue_dir = script_dir.parent / "queue"
    queue_dir.mkdir()
    pending = queue_dir / "pending_lord_questions.yaml"

    _seed_pending(pending, "rid-A", "alpha")

    result = telegram_listener._drain_pending_lord_questions(
        str(script_dir), "fake-token", "fake-chat"
    )
    assert result is True

    # After drain, the pending file should be empty (we wrote
    # remaining="" and the file is left as a zero-byte file).
    assert pending.exists() is True
    assert pending.read_text(encoding="utf-8") == ""

    # current_question.json should have rid-A
    current = queue_dir / "current_question.json"
    assert current.exists() is True
    data = __import__("json").loads(current.read_text(encoding="utf-8"))
    assert data["request_id"] == "rid-A"
    assert data["question"] == "alpha"
    # The drain file should be cleaned up by the test fixture.


def test_drain_unescapes_newlines_in_question(tmp_path):
    """C2 regression: a question with the literal escape sequence \\n
    in the pending file (placed there by enqueue_pending's escape
    logic) must be unescaped to a real newline before being written
    to current_question.json."""
    script_dir = tmp_path / "scripts"
    script_dir.mkdir()
    queue_dir = script_dir.parent / "queue"
    queue_dir.mkdir()
    pending = queue_dir / "pending_lord_questions.yaml"

    # Write a mapping where the question contains the two-character
    # sequence \n (backslash + n), the form enqueue_pending emits.
    with open(pending, "w", encoding="utf-8") as f:
        f.write(
            '- request_id: "rid-N"\n'
            '  question: "line1\\nline2"\n'
            '  options: []\n'
            '  timestamp: "2026-06-13T00:00:00+00:00"\n'
        )

    telegram_listener._drain_pending_lord_questions(
        str(script_dir), "fake-token", "fake-chat"
    )

    current = queue_dir / "current_question.json"
    assert current.exists() is True
    data = __import__("json").loads(current.read_text(encoding="utf-8"))
    # The escape should have been turned back into a real LF
    assert data["question"] == "line1\nline2", (
        f"newline unescape failed: got {data['question']!r}"
    )
