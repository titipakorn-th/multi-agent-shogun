"""Tests for telegram_ask.py race-condition + argument compatibility.

Bug A: telegram_ask.py wrote current_question.json TWICE:
  - first write (before Telegram send): {question, options, timestamp, status:pending}
  - second write (after Telegram returns message_id): adds message_id

Listener polls current_question.json for each Telegram update. If it reads
between the two writes, active_question has message_id=None. callback_query
handler at line 1526 (`cb_msg.message_id == active_question.message_id`)
returns False → falls to else branch → clears keyboard but does NOT mark
answered → Lord button taps silently lost → askQuestion never completes.

Bug B: lord_ask.sh passes `--question-file --chat-id --token` to telegram_ask.py,
which argparse rejects as unknown → exit 2 → lord_ask.sh never reaches Telegram.

Fix:
  - telegram_ask.py writes current_question.json exactly ONCE, AFTER Telegram
    returns message_id. Race window eliminated.
  - lord_ask.sh stops passing telegram_ask.py's env-only flags; telegram_ask.py
    already reads them from TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID env vars or
    config/telegram.env.
"""
import json
import os
import sys
import unittest
from unittest.mock import patch  # noqa: F401

SCRIPTS_DIR = os.path.join(os.path.dirname(__file__), '..', '..', 'scripts')
sys.path.insert(0, SCRIPTS_DIR)
import telegram_ask  # noqa: E402


class TestTelegramAskSingleWrite(unittest.TestCase):
    """Regression: telegram_ask.py must write current_question.json exactly
    once, and that single write must include message_id. Listener reads the
    file mid-send; a no-message_id intermediate write caused callback_query
    matches to fail."""

    def setUp(self):
        self.tmpdir = self._mk_tmp()

    def tearDown(self):
        import shutil
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def _mk_tmp(self):
        import tempfile
        return tempfile.mkdtemp(prefix="telegram_ask_test_")

    def _patch_script_dir(self):
        """Place a config/telegram.env under a tmp project root so that
        telegram_ask.main()'s load_env("<script_dir>/../config/telegram.env")
        finds our test token."""
        project_root = os.path.join(self.tmpdir, "project")
        os.makedirs(os.path.join(project_root, "config"))
        os.makedirs(os.path.join(project_root, "queue"))
        real_env = os.path.join(project_root, "config", "telegram.env")
        with open(real_env, "w") as f:
            f.write("TELEGRAM_BOT_TOKEN=test_token\n")
            f.write("TELEGRAM_CHAT_ID=12345\n")
        return project_root

    def test_question_file_written_exactly_once(self):
        """telegram_ask.py must write current_question.json exactly ONCE,
        AFTER Telegram returns message_id. Buggy code wrote twice — once
        before send (no message_id), once after — opening a race window
        where listener loaded the no-message-id version and callback_query
        matching silently failed."""
        project_root = self._patch_script_dir()
        scripts_dir = os.path.join(project_root, "scripts")
        os.makedirs(scripts_dir, exist_ok=True)
        qfile = os.path.join(project_root, "queue", "current_question.json")

        fake_send_res = {"ok": True, "result": {"message_id": 4242}}

        # Wrap json.dump to count writes to the question file.
        # When the file is opened in 'w' mode for json.dump, count it.
        real_open = open
        write_log = []

        def counting_open(path, mode="r", *args, **kwargs):
            # Normalize path for comparison
            is_target = os.path.abspath(str(path)) == os.path.abspath(qfile)
            is_write = "w" in mode
            if is_target and is_write:
                write_log.append({"path": str(path), "mode": mode})
            return real_open(path, mode, *args, **kwargs)

        with patch.object(telegram_ask, "make_telegram_request",
                          return_value=fake_send_res), \
             patch.object(telegram_ask.sys, "argv", [
                 "telegram_ask.py",
                 "--question", "Pick one",
                 "--options", "A", "B",
                 "--no-wait",
             ]), \
             patch.object(telegram_ask, "__file__",
                          os.path.join(scripts_dir, "telegram_ask.py")), \
             patch("builtins.open", counting_open):
            try:
                telegram_ask.main()
            except SystemExit as e:
                self.assertIn(e.code, (0, None))

        # Final file must have message_id (sanity check).
        self.assertTrue(os.path.exists(qfile))
        with real_open(qfile) as f:
            data = json.load(f)
        self.assertEqual(data.get("message_id"), 4242)

        # Race-free: the question file is written exactly ONCE (after Telegram
        # returns message_id), so listeners can never observe a no-message-id
        # intermediate state.
        self.assertEqual(
            len(write_log), 1,
            f"current_question.json must be written exactly ONCE, "
            f"but observed {len(write_log)} writes: {write_log}. "
            f"Multiple writes cause the listener to race the intermediate "
            f"no-message-id state and silently drop Lord button taps."
        )


class TestLordAskNoUnknownFlags(unittest.TestCase):
    """Regression: lord_ask.sh must not pass telegram_ask.py flags that
    telegram_ask.py's argparse does not accept. argparse exits 2 on unknown
    flags, lord_ask.sh fails, the Lord's question never reaches Telegram."""

    def test_lord_ask_does_not_pass_unknown_flags(self):
        lord_ask = os.path.join(SCRIPTS_DIR, "lord_ask.sh")
        with open(lord_ask) as f:
            lines = f.readlines()

        # Strip comment-only lines so we only check actual flag usage.
        code_lines = [ln for ln in lines if not ln.lstrip().startswith("#")]
        code = "".join(code_lines)

        # These flags don't exist in telegram_ask.py argparse.
        for bad_flag in ("--question-file", "--chat-id", "--token"):
            self.assertNotIn(
                bad_flag, code,
                f"lord_ask.sh passes {bad_flag} in non-comment code, but "
                f"telegram_ask.py argparse does not accept it. telegram_ask.py "
                f"reads TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID from env or "
                f"config/telegram.env instead."
            )


if __name__ == "__main__":
    unittest.main()