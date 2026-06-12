import sys
import os
import time
import subprocess
import unittest
from unittest.mock import patch, MagicMock

# Add scripts directory to path to import telegram_listener
sys.path.append(os.path.join(os.path.dirname(__file__), '../../scripts'))
import telegram_listener

class TestTelegramListener(unittest.TestCase):
    @patch('telegram_listener.make_telegram_request')
    @patch('telegram_listener.append_to_inbox')
    @patch('subprocess.run')
    @patch('time.sleep')
    @patch('time.time')
    def test_message_buffering_and_concatenation(self, mock_time, mock_sleep, mock_subprocess, mock_append, mock_request):
        # Setup environment variables
        os.environ["TELEGRAM_BOT_TOKEN"] = "123456:mock_token"
        os.environ["TELEGRAM_CHAT_ID"] = "12345"

        # Mock time sequence to simulate debounce timeout
        # 1. Start: 1000.0
        # 2. First update poll: 1000.0
        # 3. Second update poll (simulated idle): 1002.0 (1.5s passed, triggers flush)
        time_values = [1000.0, 1000.0, 1000.0, 1002.0, 1002.0, 1002.0]
        mock_time.side_effect = lambda: time_values.pop(0) if time_values else 1005.0

        # Mock request responses
        responses = [
            {"ok": True, "result": []}, # Initial getUpdates call (offset check)
            {"ok": True}, # setMyCommands call
            # Second getUpdates call (returns 2 chunked updates)
            {"ok": True, "result": [
                {
                    "update_id": 100,
                    "message": {
                        "message_id": 2001,
                        "chat": {"id": 12345},
                        "text": "Hello, this is the first chunk of a long message."
                    }
                },
                {
                    "update_id": 101,
                    "message": {
                        "message_id": 2002,
                        "chat": {"id": 12345},
                        "text": "And this is the second chunk of the message."
                    }
                }
            ]},
            # Third getUpdates call (empty updates, triggers poll timeout check and flush)
            {"ok": True, "result": []},
            # sendMessage feedback response
            {"ok": True, "result": {}}
        ]
        mock_request.side_effect = lambda token, method, payload=None: responses.pop(0) if responses else {"ok": True}

        # We want to exit the infinite loop during sleep after append_to_inbox is called
        def side_effect_sleep(*args, **kwargs):
            if mock_append.call_count > 0:
                raise KeyboardInterrupt("Stop loop")
        mock_sleep.side_effect = side_effect_sleep

        # Run main and expect it to exit with KeyboardInterrupt
        try:
            telegram_listener.main()
        except KeyboardInterrupt:
            pass

        # Verify that append_to_inbox was called with concatenated message
        mock_append.assert_called_once()
        args, _ = mock_append.call_args
        # args[0] is inbox_path
        self.assertEqual(args[1], 2001) # First message ID
        self.assertEqual(args[2], "Hello, this is the first chunk of a long message.\nAnd this is the second chunk of the message.")

        # Verify that a feedback message was sent via sendMessage
        sent_messages = [call for call in mock_request.call_args_list if call[0][1] == "sendMessage"]
        self.assertEqual(len(sent_messages), 1)
        payload = sent_messages[0][0][2]
        self.assertEqual(payload["chat_id"], "12345")
        self.assertIn("🏯", payload["text"])


class TestBuildProgressSummary(unittest.TestCase):
    """Tests for the priority-2 'Awaiting Shogun' state when ntfy_inbox.yaml
    contains a pending entry."""

    def setUp(self):
        self.script_dir = os.path.dirname(os.path.abspath(telegram_listener.__file__))
        self.qa = os.path.join(self.script_dir, "../queue/ntfy_inbox.yaml")
        self.dash = os.path.join(self.script_dir, "../queue/dashboard.md")
        self._cleanup()

    def tearDown(self):
        self._cleanup()

    def _cleanup(self):
        for p in (self.qa, self.dash):
            if os.path.exists(p):
                os.remove(p)

    def _write_inbox(self, entries):
        import yaml
        with open(self.qa, "w", encoding="utf-8") as f:
            yaml.safe_dump({"inbox": entries}, f, default_flow_style=False,
                           allow_unicode=True, sort_keys=False)

    def test_pending_entry_returns_awaiting_shogun(self):
        ts = time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime())
        self._write_inbox([
            {"id": "111", "timestamp": ts, "message": "deploy now", "status": "pending"}
        ])
        out = telegram_listener.build_progress_summary(self.script_dir)
        self.assertIn("Awaiting Shogun", out)
        self.assertIn("deploy now", out)

    def test_read_entry_falls_through_to_quiet(self):
        ts = time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime())
        self._write_inbox([
            {"id": "112", "timestamp": ts, "message": "done", "status": "read"}
        ])
        out = telegram_listener.build_progress_summary(self.script_dir)
        self.assertIn("All quiet", out)

    def test_missing_inbox_file_falls_through(self):
        out = telegram_listener.build_progress_summary(self.script_dir)
        self.assertIn("All quiet", out)

    def test_pending_overrides_dashboard(self):
        ts = time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime())
        self._write_inbox([
            {"id": "113", "timestamp": ts, "message": "stuck", "status": "pending"}
        ])
        with open(self.dash, "w", encoding="utf-8") as f:
            f.write("# Dashboard\n\nMission complete\n")
        out = telegram_listener.build_progress_summary(self.script_dir)
        self.assertIn("Awaiting Shogun", out)


class TestWatchStaleInbox(unittest.TestCase):
    """Tests for the 90s watchdog that warns the Lord when an inbox entry
    has been sitting in 'pending' state too long."""

    def setUp(self):
        self.script_dir = os.path.dirname(os.path.abspath(telegram_listener.__file__))
        self.qa = os.path.join(self.script_dir, "../queue/ntfy_inbox.yaml")
        self._cleanup()

    def tearDown(self):
        self._cleanup()

    def _cleanup(self):
        if os.path.exists(self.qa):
            os.remove(self.qa)

    def _write_inbox(self, entries):
        import yaml
        with open(self.qa, "w", encoding="utf-8") as f:
            yaml.safe_dump({"inbox": entries}, f, default_flow_style=False,
                           allow_unicode=True, sort_keys=False)

    def _ts(self, seconds_ago, base):
        return time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(base - seconds_ago))

    @patch("subprocess.run")
    def test_fresh_entry_no_warning(self, mock_run):
        now = time.time()
        self._write_inbox([
            {"id": "300", "timestamp": self._ts(30, now), "message": "x", "status": "pending"}
        ])
        warned = set()
        telegram_listener.watch_stale_inbox(self.script_dir, warned, now=now)
        mock_run.assert_not_called()
        self.assertEqual(warned, set())

    @patch("subprocess.run")
    def test_stale_entry_warns_once(self, mock_run):
        now = time.time()
        ts = self._ts(200, now)
        self._write_inbox([
            {"id": "301", "timestamp": ts, "message": "stuck", "status": "pending"}
        ])
        warned = set()
        telegram_listener.watch_stale_inbox(self.script_dir, warned, now=now)
        self.assertEqual(mock_run.call_count, 1)
        self.assertIn(("301", ts), warned)
        # Verify warning message content
        warning_msg = mock_run.call_args[0][0][2]
        self.assertIn("hasn't been processed", warning_msg)
        self.assertIn("/progress", warning_msg)

    @patch("subprocess.run")
    def test_idempotent_no_spam(self, mock_run):
        now = time.time()
        ts = self._ts(200, now)
        self._write_inbox([
            {"id": "302", "timestamp": ts, "message": "x", "status": "pending"}
        ])
        warned = set()
        # Call 100 times in a tight loop — must warn exactly once
        for _ in range(100):
            telegram_listener.watch_stale_inbox(self.script_dir, warned, now=now)
        self.assertEqual(mock_run.call_count, 1)

    @patch("subprocess.run")
    def test_read_entry_pruned_from_warned(self, mock_run):
        now = time.time()
        ts = self._ts(200, now)
        # Start with the entry pending — adds to warned
        self._write_inbox([
            {"id": "303", "timestamp": ts, "message": "x", "status": "pending"}
        ])
        warned = set()
        telegram_listener.watch_stale_inbox(self.script_dir, warned, now=now)
        self.assertIn(("303", ts), warned)
        # Shogun marks it read — must be pruned
        self._write_inbox([
            {"id": "303", "timestamp": ts, "message": "x", "status": "read"}
        ])
        telegram_listener.watch_stale_inbox(self.script_dir, warned, now=now)
        self.assertEqual(warned, set())

    @patch("subprocess.run")
    def test_orphan_silently_skipped(self, mock_run):
        now = time.time()
        orphan_ts = self._ts(40 * 60, now)  # > 30 min
        self._write_inbox([
            {"id": "304", "timestamp": orphan_ts, "message": "x", "status": "pending"}
        ])
        warned = set()
        telegram_listener.watch_stale_inbox(self.script_dir, warned, now=now)
        mock_run.assert_not_called()
        self.assertNotIn(("304", orphan_ts), warned)
        # File must NOT be auto-deleted
        self.assertTrue(os.path.exists(self.qa))

    @patch("subprocess.run")
    def test_malformed_timestamp_skipped(self, mock_run):
        now = time.time()
        self._write_inbox([
            {"id": "305", "timestamp": "GARBAGE", "message": "x", "status": "pending"}
        ])
        warned = set()
        telegram_listener.watch_stale_inbox(self.script_dir, warned, now=now)
        mock_run.assert_not_called()
        self.assertNotIn(("305", "GARBAGE"), warned)


class TestBuildStatusTextShaping(unittest.TestCase):
    """Tests for the phone-shaped /status output. The listener shells out to
    scripts/agent_status.sh --lang en; we mock subprocess.run so tests don't
    require a real tmux session."""

    def setUp(self):
        self.script_dir = os.path.dirname(os.path.abspath(telegram_listener.__file__))

    REAL_TABLE = (
        "Agent      CLI     State     Task ID                                    Status     Inbox\n"
        "---------- ------- --------- ------------------------------------------ ---------- -----\n"
        "karo       antigravity N/A       ---                                        ---        0\n"
        "ashigaru1  antigravity N/A       subtask_006_integration                    done       0\n"
        "ashigaru2  antigravity N/A       subtask_006_model_state                    done       0\n"
        "ashigaru5  antigravity N/A       None                                       idle       0\n"
        "gunshi     antigravity N/A       gunshi_qc_001                              working    2\n"
    )

    def _run(self, stdout, returncode=0, stderr=""):
        with patch("subprocess.run") as mock_run:
            mock_run.return_value = MagicMock(
                returncode=returncode, stdout=stdout, stderr=stderr
            )
            return telegram_listener.build_status_text(self.script_dir), mock_run

    def test_includes_header(self):
        out, _ = self._run(self.REAL_TABLE)
        self.assertIn("Agent Status", out)

    def test_done_maps_to_green(self):
        out, _ = self._run(self.REAL_TABLE)
        self.assertIn("\U0001F7E2 ashigaru1", out)  # green circle
        self.assertIn("done", out)

    def test_idle_maps_to_green(self):
        out, _ = self._run(self.REAL_TABLE)
        self.assertIn("\U0001F7E2 ashigaru5", out)
        self.assertIn("idle", out)

    def test_working_maps_to_yellow(self):
        out, _ = self._run(self.REAL_TABLE)
        self.assertIn("\U0001F7E1 gunshi", out)  # yellow circle

    def test_no_status_uses_neutral_white(self):
        out, _ = self._run(self.REAL_TABLE)
        self.assertIn("⚪ karo", out)  # white circle for "---"

    def test_summary_line_present(self):
        out, _ = self._run(self.REAL_TABLE)
        self.assertIn("Summary:", out)
        # 2 done, 1 idle, 1 working, 1 no-status = 5/5
        self.assertIn("5", out)

    def test_includes_task_id_in_brackets(self):
        out, _ = self._run(self.REAL_TABLE)
        self.assertIn("[subtask_006_integration]", out)

    def test_empty_agent_list_returns_neutral_message(self):
        # Header + sep + 1 line but that line has only 3 cols — parser
        # should treat as drift and fall back. Verify no crash.
        out, _ = self._run(
            "Agent      CLI     State\nkaro       cc      BUSY\n"
        )
        # Should fall back to raw (parse drift detected)
        self.assertIn("karo", out)

    def test_format_drift_falls_back_to_raw_table(self):
        # Garbage output that doesn't match the expected 6-column layout
        out, _ = self._run("totally not a table\n")
        # Either parser returns None and falls back to raw, or returns [].
        # Either way must not crash and must contain the original text.
        self.assertIn("totally not a table", out)

    def test_subprocess_failure_returns_friendly_error(self):
        out, _ = self._run("", returncode=1, stderr="tmux: command not found\n")
        self.assertIn("tmux: command not found", out)
        self.assertIn("agent_status.sh failed", out)

    def test_empty_output_returns_fallback(self):
        out, _ = self._run("   \n")
        self.assertIn("No agent data", out)
        self.assertIn("tmux", out)

    def test_timeout_returns_friendly_error(self):
        with patch("subprocess.run") as mock_run:
            mock_run.side_effect = subprocess.TimeoutExpired(cmd="bash", timeout=10)
            out = telegram_listener.build_status_text(self.script_dir)
        self.assertIn("timed out", out)

    def test_missing_script_returns_friendly_error(self):
        fake_dir = "/nonexistent/xyz"
        out = telegram_listener.build_status_text(fake_dir)
        self.assertIn("not found", out)

    def test_hard_cap_at_phone_limit(self):
        # Build a giant table that would overflow the cap
        rows = []
        rows.append("Agent      CLI     State     Task ID                                    Status     Inbox")
        rows.append("---------- ------- --------- ------------------------------------------ ---------- -----")
        for i in range(200):
            rows.append(
                f"agent{i:<8} antigravity N/A       subtask_{i:03d}_very_long_task_id        working    0"
            )
        out, _ = self._run("\n".join(rows) + "\n")
        self.assertLessEqual(len(out), telegram_listener.STATUS_PHONE_CAP + 50)

    def test_subprocess_invoked_with_lang_en(self):
        _, mock_run = self._run(self.REAL_TABLE)
        args = mock_run.call_args[0][0]
        self.assertIn("--lang", args)
        self.assertIn("en", args)
        self.assertTrue(mock_run.call_args.kwargs.get("capture_output"))
        self.assertEqual(mock_run.call_args.kwargs.get("timeout"), 10)


class TestBuildDashboardTextShaping(unittest.TestCase):
    """Tests for the phone-shaped /dashboard output. Uses temp dirs that
    mirror the queue/ layout the listener expects."""

    def setUp(self):
        import tempfile
        self._tmp = tempfile.mkdtemp()
        self._fake_queue = os.path.join(self._tmp, "queue")
        os.makedirs(self._fake_queue, exist_ok=True)
        self._fake_dash = os.path.join(self._fake_queue, "dashboard.md")
        self._fake_script_dir = os.path.join(self._tmp, "scripts")

    def tearDown(self):
        import shutil
        if os.path.isdir(self._tmp):
            shutil.rmtree(self._tmp, ignore_errors=True)

    def _write_dashboard(self, contents):
        os.makedirs(self._fake_script_dir, exist_ok=True)
        with open(self._fake_dash, "w", encoding="utf-8") as f:
            f.write(contents)

    # ---------- Missing / empty ----------

    def test_missing_file_returns_no_dashboard_message(self):
        out = telegram_listener.build_dashboard_text(self._fake_script_dir)
        self.assertIn("No dashboard yet", out)

    def test_empty_file_returns_no_dashboard_message(self):
        self._write_dashboard("   \n\n")
        out = telegram_listener.build_dashboard_text(self._fake_script_dir)
        self.assertIn("Dashboard is empty", out)

    # ---------- Section parsing ----------

    def test_parses_action_required_section(self):
        self._write_dashboard(
            "# Shogun Command Dashboard\n\n"
            "## 🚨 Action Required\n"
            "- [cmd_010] (Pending: 2026-06-13 09:00): Lord approval needed.\n"
        )
        out = telegram_listener.build_dashboard_text(self._fake_script_dir)
        self.assertIn("Action Required", out)
        self.assertIn("cmd_010", out)
        self.assertIn("Lord approval needed", out)

    def test_parses_in_progress_section(self):
        self._write_dashboard(
            "# Shogun Command Dashboard\n\n"
            "## 🔄 In Progress\n"
            "- [cmd_011] (Started: 2026-06-13 09:30): Build the new pipeline.\n"
        )
        out = telegram_listener.build_dashboard_text(self._fake_script_dir)
        self.assertIn("In Progress", out)
        self.assertIn("cmd_011", out)
        self.assertIn("Build the new pipeline", out)

    def test_none_section_shows_negative_signal(self):
        self._write_dashboard(
            "# Shogun Command Dashboard\n\n"
            "## 🚨 Action Required\n- None\n\n"
            "## 🔄 In Progress\n- None\n"
        )
        out = telegram_listener.build_dashboard_text(self._fake_script_dir)
        self.assertIn("Action Required: None", out)
        self.assertIn("In Progress: None", out)

    def test_includes_dashboard_header(self):
        self._write_dashboard("# X\n\n## 🚨 Action Required\n- None\n")
        out = telegram_listener.build_dashboard_text(self._fake_script_dir)
        self.assertIn("Project Dashboard", out)

    # ---------- Achievements ----------

    def _recent_time(self, seconds_ago=60):
        import datetime
        t = time.time() - seconds_ago
        return datetime.datetime.fromtimestamp(t).strftime("%Y-%m-%d %H:%M")

    def test_truncates_achievements_to_three_most_recent(self):
        # dashboard.md lists newest-first. Build 10 bullets with cmd_009 as
        # the newest (0s ago) and cmd_000 as the oldest (9*60s ago).
        # Use a list comprehension in reverse so cmd_009 is at the top.
        lines = []
        for i in range(10):
            ts = self._recent_time((10 - i) * 60)  # i=0 -> 10m ago; i=9 -> 1m ago
            lines.append(f"- [cmd_{i:03d}] (Completed: {ts}): Did thing {i}.")
        lines.reverse()  # now cmd_009 is first (newest)
        self._write_dashboard(
            "# X\n\n## ✅ Achievements\n" + "\n".join(lines) + "\n"
        )
        out = telegram_listener.build_dashboard_text(self._fake_script_dir)
        # Should contain cmd_009 (most recent), cmd_008, cmd_007 (top 3)
        self.assertIn("cmd_009", out)
        self.assertIn("cmd_008", out)
        self.assertIn("cmd_007", out)
        # Should NOT contain cmd_000 (oldest)
        self.assertNotIn("cmd_000", out)
        # Should mention "+7 more"
        self.assertIn("+7 more", out)

    def test_truncates_summary_to_first_sentence(self):
        self._write_dashboard(
            "# X\n\n## ✅ Achievements\n"
            f"- [cmd_001] (Completed: {self._recent_time()}): "
            "This is the first sentence. This is the second one that should be cut.\n"
        )
        out = telegram_listener.build_dashboard_text(self._fake_script_dir)
        self.assertIn("This is the first sentence.", out)
        self.assertNotIn("second one", out)

    def test_truncates_summary_to_60_chars_max(self):
        long_summary = "x" * 200
        self._write_dashboard(
            "# X\n\n## ✅ Achievements\n"
            f"- [cmd_001] (Completed: {self._recent_time()}): {long_summary}\n"
        )
        out = telegram_listener.build_dashboard_text(self._fake_script_dir)
        # Find the bullet line and assert summary length is bounded
        for line in out.splitlines():
            if "cmd_001" in line:
                # Subtract the prefix "   ✅ cmd_001 (rel): "
                prefix_end = line.find(": ") + 2
                summary = line[prefix_end:]
                self.assertLessEqual(len(summary), 70)  # 60 + ellipsis tolerance
                break
        else:
            self.fail("cmd_001 line not found in output")

    def test_relative_time_format(self):
        self._write_dashboard(
            "# X\n\n## ✅ Achievements\n"
            f"- [cmd_001] (Completed: {self._recent_time(7200)}): Did thing.\n"  # 2h ago
        )
        out = telegram_listener.build_dashboard_text(self._fake_script_dir)
        self.assertIn("2h ago", out)

    def test_just_now_for_recent(self):
        self._write_dashboard(
            "# X\n\n## ✅ Achievements\n"
            f"- [cmd_001] (Completed: {self._recent_time(5)}): Did thing.\n"
        )
        out = telegram_listener.build_dashboard_text(self._fake_script_dir)
        self.assertIn("just now", out)

    # ---------- Malformed entries ----------

    def test_malformed_entry_shows_truncated_raw(self):
        self._write_dashboard(
            "# X\n\n## ✅ Achievements\n"
            "- This entry has no task id and no timestamp at all, just words.\n"
        )
        out = telegram_listener.build_dashboard_text(self._fake_script_dir)
        # The raw text should appear (truncated)
        self.assertIn("This entry", out)

    def test_missing_timestamp_falls_back_gracefully(self):
        self._write_dashboard(
            "# X\n\n## ✅ Achievements\n"
            "- [cmd_001]: A thing without timestamp.\n"
        )
        out = telegram_listener.build_dashboard_text(self._fake_script_dir)
        self.assertIn("cmd_001", out)
        self.assertIn("A thing", out)

    # ---------- Caps ----------

    def test_output_under_phone_cap_for_realistic_dashboard(self):
        # Build a realistic dashboard with many achievements
        bullets = "\n".join(
            f"- [cmd_{i:03d}] (Completed: {self._recent_time(i * 86400)}): "
            + ("Implemented thing X. " * 5) + "\n"
            for i in range(20)
        )
        self._write_dashboard(
            "# Shogun Command Dashboard\n\n"
            "## 🚨 Action Required\n- None\n\n"
            "## 🔄 In Progress\n"
            "- [cmd_099] (Started: 2026-06-13 09:00): Long running task description.\n"
            "- [cmd_098] (Started: 2026-06-13 08:30): Another long task.\n"
            "\n"
            "## ✅ Achievements\n" + bullets
        )
        out = telegram_listener.build_dashboard_text(self._fake_script_dir)
        self.assertLessEqual(
            len(out), telegram_listener.DASHBOARD_PHONE_CAP,
            f"Output exceeded cap: {len(out)} chars"
        )

    def test_extreme_oversize_still_under_cap(self):
        # A pathological dashboard that would be huge unshaped
        bullets = "\n".join(
            f"- [cmd_{i:03d}] (Completed: 2020-01-01 00:00): " + ("word " * 100) + "\n"
            for i in range(500)
        )
        self._write_dashboard(
            "# X\n\n## ✅ Achievements\n" + bullets
        )
        out = telegram_listener.build_dashboard_text(self._fake_script_dir)
        # Hard cap is 1200 but allow a small overflow for the truncation suffix
        self.assertLessEqual(len(out), telegram_listener.DASHBOARD_PHONE_CAP + 100)

    # ---------- Output shape sanity ----------

    def test_no_heading_markers_leaked(self):
        self._write_dashboard(
            "# X\n## 🚨 Action Required\n- None\n"
            "## ✅ Achievements\n- [cmd_001] (Completed: 2026-06-13 09:00): Did thing.\n"
        )
        out = telegram_listener.build_dashboard_text(self._fake_script_dir)
        self.assertNotIn("##", out)
        self.assertNotIn("**", out)

    def test_each_achievement_summary_under_70_chars(self):
        bullets = "\n".join(
            f"- [cmd_{i:03d}] (Completed: {self._recent_time(i * 60)}): "
            + ("Long summary " * 10) + "\n"
            for i in range(5)
        )
        self._write_dashboard(
            "# X\n## ✅ Achievements\n" + bullets
        )
        out = telegram_listener.build_dashboard_text(self._fake_script_dir)
        for line in out.splitlines():
            if line.strip().startswith("✅"):
                # Extract the summary after the timestamp paren
                # Format: ✅ cmd_NNN (rel): summary
                idx = line.find("): ")
                if idx >= 0:
                    summary = line[idx + 3:]
                    self.assertLessEqual(
                        len(summary), 70,
                        f"Summary too long ({len(summary)}): {summary}"
                    )


class TestNoInboxWriteForStatusAndDashboard(unittest.TestCase):
    """End-to-end: send /status and /dashboard through the listener message
    branch and verify that NO call is made to inbox_write.sh (i.e. the
    Telegram agent is never woken up for these commands)."""

    def setUp(self):
        os.environ["TELEGRAM_BOT_TOKEN"] = "123456:mock_token"
        os.environ["TELEGRAM_CHAT_ID"] = "12345"

    @patch("subprocess.run")
    @patch("telegram_listener.append_to_inbox")
    @patch("telegram_listener.make_telegram_request")
    @patch("time.sleep")
    @patch("time.time")
    def test_status_does_not_call_inbox_write(
        self, mock_time, mock_sleep, mock_request, mock_append, mock_subprocess
    ):
        # First time call: initial getUpdates returns nothing
        # setMyCommands: ok
        # Then: a /status update
        # Then: sendMessage for /status response
        responses = [
            {"ok": True, "result": []},  # initial getUpdates
            {"ok": True},                 # setMyCommands
            {"ok": True, "result": [
                {
                    "update_id": 500,
                    "message": {
                        "message_id": 9001,
                        "chat": {"id": 12345},
                        "text": "/status"
                    }
                }
            ]},
            {"ok": True, "result": {}},  # sendMessage
        ]
        mock_request.side_effect = lambda *a, **kw: responses.pop(0) if responses else {"ok": True}

        # Force a quick exit after the first /status handler runs
        call_count = {"n": 0}
        original_subprocess = mock_subprocess.side_effect

        def sleep_then_stop(*args, **kwargs):
            call_count["n"] += 1
            if call_count["n"] >= 2:
                raise KeyboardInterrupt("stop")

        mock_sleep.side_effect = sleep_then_stop

        # Make subprocess.run return a fake agent_status result
        mock_subprocess.return_value = MagicMock(
            returncode=0, stdout="karo BUSY\n", stderr=""
        )

        try:
            telegram_listener.main()
        except KeyboardInterrupt:
            pass

        # Inspect every subprocess.run call: NONE of them should target
        # inbox_write.sh (that would wake the Telegram agent).
        for call in mock_subprocess.call_args_list:
            argv = call[0][0] if call[0] else []
            if not argv:
                continue
            argv_str = " ".join(str(x) for x in argv)
            self.assertNotIn(
                "inbox_write.sh", argv_str,
                f"/status should not call inbox_write.sh, got: {argv}"
            )

        # And at least one sendMessage was called for the /status response
        send_msg_calls = [c for c in mock_request.call_args_list if c[0][1] == "sendMessage"]
        self.assertGreaterEqual(len(send_msg_calls), 1)
        # The text should contain the script output (or at least not the routing message)
        last_send = send_msg_calls[-1]
        sent_text = last_send[0][2].get("text", "")
        self.assertIn("karo BUSY", sent_text)

    @patch("subprocess.run")
    @patch("telegram_listener.append_to_inbox")
    @patch("telegram_listener.make_telegram_request")
    @patch("time.sleep")
    @patch("time.time")
    def test_dashboard_does_not_call_inbox_write(
        self, mock_time, mock_sleep, mock_request, mock_append, mock_subprocess
    ):
        # Stage a dashboard.md under the real script_dir so the function finds it
        script_dir = os.path.dirname(os.path.abspath(telegram_listener.__file__))
        real_dash = os.path.abspath(os.path.join(script_dir, "../queue/dashboard.md"))
        wrote = False
        original = None
        if not os.path.exists(real_dash):
            with open(real_dash, "w", encoding="utf-8") as f:
                f.write(
                    "# Test Dashboard\n\n"
                    "## 🚨 Action Required\n- None\n\n"
                    "## ✅ Achievements\n"
                    "- [cmd_999] (Completed: 2026-06-13 09:00): Frog shipped.\n"
                )
            wrote = True
        else:
            with open(real_dash, "r", encoding="utf-8") as f:
                original = f.read()
            with open(real_dash, "w", encoding="utf-8") as f:
                f.write(
                    "# Test Dashboard\n\n"
                    "## 🚨 Action Required\n- None\n\n"
                    "## ✅ Achievements\n"
                    "- [cmd_999] (Completed: 2026-06-13 09:00): Frog shipped.\n"
                )

        try:
            responses = [
                {"ok": True, "result": []},
                {"ok": True},
                {"ok": True, "result": [
                    {
                        "update_id": 600,
                        "message": {
                            "message_id": 9002,
                            "chat": {"id": 12345},
                            "text": "/dashboard"
                        }
                    }
                ]},
                {"ok": True, "result": {}},
            ]
            mock_request.side_effect = lambda *a, **kw: responses.pop(0) if responses else {"ok": True}

            call_count = {"n": 0}
            def sleep_then_stop(*args, **kwargs):
                call_count["n"] += 1
                if call_count["n"] >= 2:
                    raise KeyboardInterrupt("stop")
            mock_sleep.side_effect = sleep_then_stop

            try:
                telegram_listener.main()
            except KeyboardInterrupt:
                pass

            # No inbox_write.sh call
            for call in mock_subprocess.call_args_list:
                argv = call[0][0] if call[0] else []
                if not argv:
                    continue
                argv_str = " ".join(str(x) for x in argv)
                self.assertNotIn("inbox_write.sh", argv_str)

            # sendMessage was called with dashboard content
            send_msg_calls = [c for c in mock_request.call_args_list if c[0][1] == "sendMessage"]
            self.assertGreaterEqual(len(send_msg_calls), 1)
            sent_text = send_msg_calls[-1][0][2].get("text", "")
            self.assertIn("cmd_999", sent_text)
            self.assertIn("Frog shipped", sent_text)
        finally:
            if wrote:
                if os.path.exists(real_dash):
                    os.remove(real_dash)
            elif original is not None:
                with open(real_dash, "w", encoding="utf-8") as f:
                    f.write(original)


class TestBuildCancelText(unittest.TestCase):
    """Tests for the /cancel direct handler. The function scans
    queue/shogun_to_karo.yaml for the most recent non-done/non-cancelled
    cmd and (if found) writes a cancel_request inbox message to Shogun."""

    def setUp(self):
        import tempfile
        import shutil
        self._tmp = tempfile.mkdtemp()
        self._fake_queue = os.path.join(self._tmp, "queue")
        os.makedirs(self._fake_queue, exist_ok=True)
        self._fake_script_dir = os.path.join(self._tmp, "scripts")
        os.makedirs(self._fake_script_dir, exist_ok=True)
        # Reset module-level dedup state so each test starts clean.
        telegram_listener._last_cancel_ts = 0.0
        telegram_listener._last_cancel_cmd_id = None

    def tearDown(self):
        import shutil
        if os.path.isdir(self._tmp):
            shutil.rmtree(self._tmp, ignore_errors=True)
        # Reset again so the next test class starts clean.
        telegram_listener._last_cancel_ts = 0.0
        telegram_listener._last_cancel_cmd_id = None

    def _write_cmd_yaml(self, cmds):
        import yaml
        path = os.path.join(self._fake_queue, "shogun_to_karo.yaml")
        with open(path, "w", encoding="utf-8") as f:
            yaml.safe_dump(cmds, f, default_flow_style=False,
                           allow_unicode=True, sort_keys=False)

    @patch("subprocess.run")
    def test_no_active_cmd_returns_friendly_message(self, mock_run):
        # No YAML at all — no active cmd
        out = telegram_listener.build_cancel_text(self._fake_script_dir)
        self.assertIn("No active command", out)
        # No inbox_write should have been issued
        for call in mock_run.call_args_list:
            argv = call[0][0] if call[0] else []
            argv_str = " ".join(str(x) for x in argv)
            self.assertNotIn("inbox_write.sh", argv_str)

    @patch("subprocess.run")
    def test_all_cmds_done_returns_friendly_message(self, mock_run):
        self._write_cmd_yaml([
            {"id": "cmd_001", "status": "done"},
            {"id": "cmd_002", "status": "cancelled"},
        ])
        out = telegram_listener.build_cancel_text(self._fake_script_dir)
        self.assertIn("No active command", out)
        mock_run.assert_not_called()

    @patch("subprocess.run")
    def test_active_cmd_triggers_inbox_write(self, mock_run):
        self._write_cmd_yaml([
            {"id": "cmd_010", "status": "done"},
            {"id": "cmd_011", "status": "pending"},
        ])
        out = telegram_listener.build_cancel_text(self._fake_script_dir)
        self.assertIn("cmd_011", out)
        self.assertIn("Cancel request sent", out)
        # One subprocess.run call to inbox_write.sh
        inbox_calls = [
            c for c in mock_run.call_args_list
            if c[0] and "inbox_write.sh" in " ".join(str(x) for x in c[0][0])
        ]
        self.assertEqual(len(inbox_calls), 1)
        argv = inbox_calls[0][0][0]
        # Target should be shogun
        self.assertIn("shogun", argv)
        # Type should be cancel_request
        self.assertIn("cancel_request", argv)
        # Content should mention the cmd id
        content_idx = next(
            i for i, x in enumerate(argv) if "CANCEL_REQUEST" in str(x)
        )
        self.assertIn("cmd_011", argv[content_idx])

    @patch("subprocess.run")
    def test_most_recent_active_cmd_wins(self, mock_run):
        # Two active cmds: cmd_020 is newer (active) and cmd_015 is older (active)
        self._write_cmd_yaml([
            {"id": "cmd_015", "status": "in_progress"},
            {"id": "cmd_020", "status": "pending"},
        ])
        out = telegram_listener.build_cancel_text(self._fake_script_dir)
        self.assertIn("cmd_020", out)
        self.assertNotIn("cmd_015", out)

    @patch("subprocess.run")
    def test_dedup_within_5s_skips_inbox_write(self, mock_run):
        self._write_cmd_yaml([
            {"id": "cmd_030", "status": "pending"},
        ])
        # First call writes
        out1 = telegram_listener.build_cancel_text(self._fake_script_dir)
        self.assertIn("Cancel request sent", out1)
        # Second call within 5s should NOT write again
        out2 = telegram_listener.build_cancel_text(self._fake_script_dir)
        self.assertIn("already sent", out2)
        inbox_calls = [
            c for c in mock_run.call_args_list
            if c[0] and "inbox_write.sh" in " ".join(str(x) for x in c[0][0])
        ]
        self.assertEqual(len(inbox_calls), 1)

    @patch("subprocess.run")
    @patch("time.time")
    def test_dedup_window_expires_after_5s(self, mock_time, mock_run):
        self._write_cmd_yaml([
            {"id": "cmd_040", "status": "pending"},
        ])
        mock_time.return_value = 1000.0
        out1 = telegram_listener.build_cancel_text(self._fake_script_dir)
        self.assertIn("Cancel request sent", out1)
        # Advance time past the dedup window
        mock_time.return_value = 1006.0
        out2 = telegram_listener.build_cancel_text(self._fake_script_dir)
        self.assertIn("Cancel request sent", out2)
        inbox_calls = [
            c for c in mock_run.call_args_list
            if c[0] and "inbox_write.sh" in " ".join(str(x) for x in c[0][0])
        ]
        self.assertEqual(len(inbox_calls), 2)

    @patch("subprocess.run")
    @patch("time.time")
    def test_different_cmd_id_resets_dedup(self, mock_time, mock_run):
        # Start with cmd_050 active
        self._write_cmd_yaml([
            {"id": "cmd_050", "status": "pending"},
        ])
        mock_time.return_value = 1000.0
        telegram_listener.build_cancel_text(self._fake_script_dir)
        # cmd_050 completes; cmd_051 becomes active
        self._write_cmd_yaml([
            {"id": "cmd_050", "status": "done"},
            {"id": "cmd_051", "status": "pending"},
        ])
        # Time hasn't moved much but cmd_id is different — must write
        mock_time.return_value = 1001.0
        out = telegram_listener.build_cancel_text(self._fake_script_dir)
        self.assertIn("cmd_051", out)
        self.assertIn("Cancel request sent", out)
        inbox_calls = [
            c for c in mock_run.call_args_list
            if c[0] and "inbox_write.sh" in " ".join(str(x) for x in c[0][0])
        ]
        self.assertEqual(len(inbox_calls), 2)

    @patch("subprocess.run", side_effect=subprocess.TimeoutExpired(cmd="bash", timeout=10))
    def test_inbox_write_timeout_returns_friendly_error(self, mock_run):
        self._write_cmd_yaml([
            {"id": "cmd_060", "status": "pending"},
        ])
        out = telegram_listener.build_cancel_text(self._fake_script_dir)
        self.assertIn("timed out", out)


class TestParserFailureLogging(unittest.TestCase):
    """Tests for the stderr warning emitted when dashboard.md or
    agent_status.sh output can't be parsed. State-tracked at module level
    so the warning fires once on OK->FAILING (and on FAILING->OK), not on
    every call."""

    def setUp(self):
        import tempfile
        import shutil
        self._tmp = tempfile.mkdtemp()
        self._fake_queue = os.path.join(self._tmp, "queue")
        os.makedirs(self._fake_queue, exist_ok=True)
        self._fake_dash = os.path.join(self._fake_queue, "dashboard.md")
        self._fake_script_dir = os.path.join(self._tmp, "scripts")
        os.makedirs(self._fake_script_dir, exist_ok=True)
        # Create a stub agent_status.sh so build_status_text's os.path.exists
        # check passes (the function shells out to it; the test patches
        # subprocess.run so the stub never actually runs).
        with open(os.path.join(self._fake_script_dir, "agent_status.sh"), "w") as f:
            f.write("#!/bin/bash\nexit 0\n")
        # Reset module-level parser state.
        telegram_listener._dashboard_parse_state = None
        telegram_listener._status_parse_state = None

    def tearDown(self):
        import shutil
        if os.path.isdir(self._tmp):
            shutil.rmtree(self._tmp, ignore_errors=True)
        telegram_listener._dashboard_parse_state = None
        telegram_listener._status_parse_state = None

    def _write_dashboard(self, contents):
        with open(self._fake_dash, "w", encoding="utf-8") as f:
            f.write(contents)

    def test_dashboard_missing_achievements_logs_stderr(self):
        # No Achievements section
        self._write_dashboard(
            "# X\n\n## 🚨 Action Required\n- None\n"
        )
        with patch("sys.stderr") as mock_stderr:
            telegram_listener.build_dashboard_text(self._fake_script_dir)
        # Collect all write() calls
        all_writes = []
        for call in mock_stderr.write.call_args_list:
            all_writes.append(str(call[0][0]))
        joined = "".join(all_writes)
        self.assertIn("dashboard.md parse warning", joined)
        self.assertIn("Achievements", joined)
        # State must now be "failing"
        self.assertEqual(telegram_listener._dashboard_parse_state, "failing")

    def test_dashboard_success_no_stderr_warning(self):
        # Well-formed dashboard with a parseable Achievements bullet
        import time
        recent_ts = time.strftime("%Y-%m-%d %H:%M", time.localtime(time.time() - 60))
        self._write_dashboard(
            f"# X\n\n## 🚨 Action Required\n- None\n\n"
            f"## ✅ Achievements\n"
            f"- [cmd_001] (Completed: {recent_ts}): Did a thing.\n"
        )
        with patch("sys.stderr") as mock_stderr:
            telegram_listener.build_dashboard_text(self._fake_script_dir)
        all_writes = []
        for call in mock_stderr.write.call_args_list:
            all_writes.append(str(call[0][0]))
        joined = "".join(all_writes)
        self.assertNotIn("dashboard.md parse warning", joined)
        # State must now be "ok"
        self.assertEqual(telegram_listener._dashboard_parse_state, "ok")

    def test_dashboard_failure_logged_only_once_on_repeated_calls(self):
        # No Achievements section — first call logs, second doesn't
        self._write_dashboard("# X\n\n## 🚨 Action Required\n- None\n")
        with patch("sys.stderr") as mock_stderr:
            telegram_listener.build_dashboard_text(self._fake_script_dir)
            first_writes = sum(
                len(str(c[0][0])) for c in mock_stderr.write.call_args_list
            )
            # Second call: state is already "failing" — no new warning
            mock_stderr.reset_mock()
            telegram_listener.build_dashboard_text(self._fake_script_dir)
            second_writes = sum(
                len(str(c[0][0])) for c in mock_stderr.write.call_args_list
            )
        self.assertGreater(first_writes, 0, "First call should log")
        self.assertEqual(second_writes, 0, "Second call must NOT log again")

    def test_dashboard_recovery_logs_nothing(self):
        # Start in failing state
        self._write_dashboard("# X\n\n## 🚨 Action Required\n- None\n")
        with patch("sys.stderr"):
            telegram_listener.build_dashboard_text(self._fake_script_dir)
        self.assertEqual(telegram_listener._dashboard_parse_state, "failing")
        # Repair the dashboard — must transition cleanly with no warning
        import time
        recent_ts = time.strftime("%Y-%m-%d %H:%M", time.localtime(time.time() - 60))
        self._write_dashboard(
            f"# X\n\n## 🚨 Action Required\n- None\n\n"
            f"## ✅ Achievements\n"
            f"- [cmd_001] (Completed: {recent_ts}): Recovered.\n"
        )
        with patch("sys.stderr") as mock_stderr:
            telegram_listener.build_dashboard_text(self._fake_script_dir)
        all_writes = "".join(
            str(c[0][0]) for c in mock_stderr.write.call_args_list
        )
        self.assertNotIn("dashboard.md parse warning", all_writes)
        self.assertEqual(telegram_listener._dashboard_parse_state, "ok")

    def test_status_parse_failure_logs_stderr(self):
        # Format drift — parser returns None
        with patch("subprocess.run") as mock_run:
            mock_run.return_value = MagicMock(
                returncode=0,
                stdout="totally not a table\n",
                stderr="",
            )
            with patch("sys.stderr") as mock_stderr:
                telegram_listener.build_status_text(self._fake_script_dir)
        all_writes = "".join(
            str(c[0][0]) for c in mock_stderr.write.call_args_list
        )
        self.assertIn("agent_status.sh table parse warning", all_writes)
        self.assertIn("unexpected row format", all_writes)
        self.assertIn("totally not a table", all_writes)
        self.assertEqual(telegram_listener._status_parse_state, "failing")

    def test_status_parse_success_no_stderr_warning(self):
        REAL_TABLE = (
            "Agent      CLI     State     Task ID                                    Status     Inbox\n"
            "---------- ------- --------- ------------------------------------------ ---------- -----\n"
            "karo       antigravity N/A       ---                                        ---        0\n"
            "ashigaru1  antigravity N/A       subtask_006_integration                    done       0\n"
        )
        with patch("subprocess.run") as mock_run:
            mock_run.return_value = MagicMock(
                returncode=0, stdout=REAL_TABLE, stderr=""
            )
            with patch("sys.stderr") as mock_stderr:
                telegram_listener.build_status_text(self._fake_script_dir)
        all_writes = "".join(
            str(c[0][0]) for c in mock_stderr.write.call_args_list
        )
        self.assertNotIn("agent_status.sh table parse warning", all_writes)
        self.assertEqual(telegram_listener._status_parse_state, "ok")

    def test_status_failure_logged_only_once_on_repeated_calls(self):
        with patch("subprocess.run") as mock_run:
            mock_run.return_value = MagicMock(
                returncode=0,
                stdout="garbage output that won't parse\n",
                stderr="",
            )
            with patch("sys.stderr") as mock_stderr:
                telegram_listener.build_status_text(self._fake_script_dir)
                first_count = sum(
                    "agent_status.sh table parse warning" in str(c[0][0])
                    for c in mock_stderr.write.call_args_list
                )
                mock_stderr.reset_mock()
                telegram_listener.build_status_text(self._fake_script_dir)
                second_count = sum(
                    "agent_status.sh table parse warning" in str(c[0][0])
                    for c in mock_stderr.write.call_args_list
                )
        self.assertGreaterEqual(first_count, 1)
        self.assertEqual(second_count, 0)


class TestCancelCommandRouting(unittest.TestCase):
    """End-to-end: send /cancel through the listener message branch and
    verify routing, response, and that no LLM agent is woken up."""

    def setUp(self):
        os.environ["TELEGRAM_BOT_TOKEN"] = "123456:mock_token"
        os.environ["TELEGRAM_CHAT_ID"] = "12345"
        # Reset module-level state for clean tests
        telegram_listener._last_cancel_ts = 0.0
        telegram_listener._last_cancel_cmd_id = None

    def tearDown(self):
        telegram_listener._last_cancel_ts = 0.0
        telegram_listener._last_cancel_cmd_id = None

    @patch("subprocess.run")
    @patch("telegram_listener.append_to_inbox")
    @patch("telegram_listener.make_telegram_request")
    @patch("time.sleep")
    @patch("time.time")
    def test_cancel_routes_through_listener_directly(
        self, mock_time, mock_sleep, mock_request, mock_append, mock_subprocess
    ):
        # No active cmd on disk -> friendly message
        responses = [
            {"ok": True, "result": []},  # initial getUpdates
            {"ok": True},                 # setMyCommands
            {"ok": True, "result": [
                {
                    "update_id": 700,
                    "message": {
                        "message_id": 9003,
                        "chat": {"id": 12345},
                        "text": "/cancel"
                    }
                }
            ]},
            {"ok": True, "result": {}},  # sendMessage
        ]
        mock_request.side_effect = lambda *a, **kw: responses.pop(0) if responses else {"ok": True}

        call_count = {"n": 0}
        def sleep_then_stop(*args, **kwargs):
            call_count["n"] += 1
            if call_count["n"] >= 2:
                raise KeyboardInterrupt("stop")
        mock_sleep.side_effect = sleep_then_stop

        try:
            telegram_listener.main()
        except KeyboardInterrupt:
            pass

        # No inbox_write.sh should have been invoked (no active cmd)
        for call in mock_subprocess.call_args_list:
            argv = call[0][0] if call[0] else []
            if not argv:
                continue
            argv_str = " ".join(str(x) for x in argv)
            self.assertNotIn("inbox_write.sh", argv_str)

        # One sendMessage with the friendly "no active command" text
        send_msg_calls = [c for c in mock_request.call_args_list if c[0][1] == "sendMessage"]
        self.assertGreaterEqual(len(send_msg_calls), 1)
        last_send = send_msg_calls[-1]
        sent_text = last_send[0][2].get("text", "")
        self.assertIn("No active command", sent_text)


if __name__ == '__main__':
    unittest.main()
