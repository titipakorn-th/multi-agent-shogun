#!/usr/bin/env python3
import sys
import os
import time
import json
import re
import urllib.request
import urllib.error
import subprocess

def load_env(env_path):
    env_vars = {}
    if os.path.exists(env_path):
        with open(env_path, 'r', encoding='utf-8') as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith('#'):
                    continue
                if '=' in line:
                    key, val = line.split('=', 1)
                    env_vars[key.strip()] = val.strip()
    return env_vars

def get_telegram_model(script_dir):
    try:
        import yaml
        settings_path = os.path.join(script_dir, "../config/settings.yaml")
        if os.path.exists(settings_path):
            with open(settings_path, "r", encoding="utf-8") as f:
                cfg = yaml.safe_load(f) or {}
            model = cfg.get("cli", {}).get("agents", {}).get("telegram", {}).get("model")
            if model:
                return str(model)
    except Exception:
        pass
    return "haiku"

def get_system_language(script_dir):
    try:
        import yaml
        settings_path = os.path.join(script_dir, "../config/settings.yaml")
        if os.path.exists(settings_path):
            with open(settings_path, "r", encoding="utf-8") as f:
                cfg = yaml.safe_load(f) or {}
            return cfg.get("language", "en")
    except Exception:
        pass
    return "en"

def make_telegram_request(token, method, payload=None):
    url = f"https://api.telegram.org/bot{token}/{method}"
    headers = {"Content-Type": "application/json"}
    data = json.dumps(payload).encode('utf-8') if payload else None
    req = urllib.request.Request(url, data=data, headers=headers, method="POST" if payload else "GET")
    try:
        with urllib.request.urlopen(req, timeout=15) as res:
            return json.loads(res.read().decode('utf-8'))
    except Exception as e:
        return {"ok": False, "description": str(e)}

def append_to_inbox(inbox_path, msg_id, msg_text):
    import yaml
    
    entry = {
        "id": str(msg_id),
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "message": msg_text,
        "status": "pending"
    }
    
    data = {"inbox": []}
    if os.path.exists(inbox_path):
        try:
            with open(inbox_path, "r", encoding="utf-8") as f:
                loaded = yaml.safe_load(f)
                if isinstance(loaded, dict) and "inbox" in loaded:
                    data = loaded
        except Exception:
            pass
            
    if not isinstance(data.get("inbox"), list):
        data["inbox"] = []
        
    data["inbox"].append(entry)
    
    # Write atomically
    temp_path = inbox_path + ".tmp"
    with open(temp_path, "w", encoding="utf-8") as f:
        yaml.safe_dump(data, f, default_flow_style=False, allow_unicode=True, sort_keys=False)
    os.replace(temp_path, inbox_path)

def fire_due_pings(script_dir):
    """
    Check queue/pending_pings.yaml for any pings whose fire_at has passed, and
    deliver them to Telegram via scripts/ntfy.sh.

    - Entries with fire_at more than 30 min in the past are treated as orphaned
      (e.g., Shogun forgot to clean them up after completion) and skipped silently.
    - Atomic read/write: we never delete entries we did not understand, so a
      transient parse error never loses pings.
    - 5s dedup in scripts/ntfy.sh protects against accidental double-fires.

    Returns silently if the file does not exist or is empty.
    """
    try:
        import yaml
        import tempfile
        pings_path = os.path.join(script_dir, "../queue/pending_pings.yaml")
        if not os.path.exists(pings_path):
            return

        with open(pings_path, "r", encoding="utf-8") as f:
            data = yaml.safe_load(f)
        if not isinstance(data, dict):
            return
        pings = data.get("pings")
        if not isinstance(pings, list) or not pings:
            return

        now = time.time()
        ORPHAN_GRACE_SEC = 30 * 60  # 30 minutes
        fired_count = 0
        for entry in pings:
            if not isinstance(entry, dict):
                continue
            if entry.get("sent"):
                continue
            fire_at_str = entry.get("fire_at")
            message = entry.get("message", "")
            if not fire_at_str or not message:
                continue

            # Parse ISO 8601 fire_at. Tolerate '+00:00' and 'Z' suffixes.
            try:
                fire_at_ts = time.mktime(time.strptime(fire_at_str[:19], "%Y-%m-%dT%H:%M:%S"))
            except Exception:
                continue

            if fire_at_ts > now:
                continue  # Not yet due.

            age = now - fire_at_ts
            if age > ORPHAN_GRACE_SEC:
                # Orphaned — mark sent so we stop seeing it on every loop.
                entry["sent"] = True
                entry["orphan_skipped"] = True
                continue

            # Fire the ping via ntfy.sh (which auto-routes to Telegram if configured).
            try:
                subprocess.run(
                    ["bash", os.path.join(script_dir, "ntfy.sh"), message],
                    check=False,
                    timeout=10,
                )
                entry["sent"] = True
                entry["fired_at"] = time.strftime("%Y-%m-%dT%H:%M:%S%z")
                fired_count += 1
            except Exception as e:
                print(f"[telegram_listener] Ping fire error: {e}", file=sys.stderr)

        if fired_count > 0:
            print(f"[telegram_listener] Fired {fired_count} progress ping(s)")

        # Persist updated pings back to disk atomically.
        try:
            tmp_fd, tmp_path = tempfile.mkstemp(
                dir=os.path.dirname(pings_path), suffix=".tmp"
            )
            with os.fdopen(tmp_fd, "w", encoding="utf-8") as f:
                yaml.safe_dump(
                    data, f,
                    default_flow_style=False,
                    allow_unicode=True,
                    sort_keys=False,
                )
            os.replace(tmp_path, pings_path)
        except Exception as e:
            print(f"[telegram_listener] pending_pings.yaml write error: {e}", file=sys.stderr)
    except Exception as e:
        print(f"[telegram_listener] fire_due_pings error: {e}", file=sys.stderr)


def watch_stale_inbox(script_dir, warned_entries, now=None):
    """
    Watch queue/inbox/shogun.yaml for entries that the Lord sent via Telegram
    but that Shogun has not yet read. When an unread entry crosses
    STALE_THRESHOLD_SEC (90s), send a one-shot Telegram warning to the Lord so
    they know the system appears unresponsive.

    Source of truth: queue/inbox/shogun.yaml. This is the file that
    scripts/inbox_write.sh writes to when the Telegram listener forwards a
    Lord message, and that Shogun flips `read: True` on when it picks the
    message up. Both transitions are script-driven and deterministic — unlike
    queue/ntfy_inbox.yaml (a shadow log that requires LLM cooperation to
    maintain), so we can rely on the inbox file's read state for paging.

    Idempotent: each (id, timestamp) pair warns at most once per listener
    lifetime. The `warned_entries` set (caller-owned) tracks what we've
    already paged about. Entries that disappear from the file or that flip
    to read: True are pruned from the set so the memory doesn't grow
    unboundedly across long uptimes.

    Orphan handling: entries unread > ORPHAN_GRACE_SEC (30 min) are no longer
    warned about — the Lord has been paged plenty, and the entry itself is
    the user's problem to clean up. We don't auto-delete it.
    """
    STALE_THRESHOLD_SEC = 90
    ORPHAN_GRACE_SEC = 30 * 60  # 30 minutes

    if now is None:
        now = time.time()

    try:
        import yaml
        shogun_inbox_path = os.path.join(script_dir, "../queue/inbox/shogun.yaml")
        if not os.path.exists(shogun_inbox_path):
            # File was removed entirely — prune every warning we've ever sent.
            warned_entries.clear()
            return

        with open(shogun_inbox_path, "r", encoding="utf-8") as f:
            data = yaml.safe_load(f) or {}
        entries = data.get("messages")
        if not isinstance(entries, list):
            warned_entries.clear()
            return

        # Build a set of (id, timestamp) tuples still present AND unread.
        # Any tracked entry not in this set is no longer something we should
        # remember warning about, so we drop it.
        live_keys = set()
        for entry in entries:
            if not isinstance(entry, dict):
                continue
            if not entry.get("read", False):
                eid = str(entry.get("id", ""))
                ets = str(entry.get("timestamp", ""))
                if eid:
                    live_keys.add((eid, ets))

        # Prune warned_entries for entries that no longer exist or are
        # already read. This bounds memory across long uptimes and means a
        # restart + re-process → re-warn (not double-warn within the same
        # session).
        stale_keys = [k for k in warned_entries if k not in live_keys]
        for k in stale_keys:
            warned_entries.discard(k)

        for entry in entries:
            if not isinstance(entry, dict):
                continue
            if entry.get("read", False):
                continue  # Shogun has it.

            eid = str(entry.get("id", ""))
            ets = str(entry.get("timestamp", ""))
            if not eid:
                continue

            ts_str = entry.get("timestamp", "")
            if not ts_str:
                continue

            # Parse ISO 8601. inbox_write.sh writes naive ("2026-06-13T10:30:00")
            # timestamps without a timezone suffix; strptime handles them
            # directly in the listener's local timezone.
            try:
                normalized = ts_str[:19]
                ts_epoch = time.mktime(time.strptime(normalized, "%Y-%m-%dT%H:%M:%S"))
            except Exception:
                # Malformed timestamp — skip without warning. Better to be
                # silent than to spam the Lord on every loop.
                continue

            age = now - ts_epoch

            # Orphaned — Lord has been warned plenty; stop tracking this one.
            # We DON'T add to warned_entries here so a manual cleanup +
            # re-addition will be picked up as fresh.
            if age > ORPHAN_GRACE_SEC:
                continue

            if age < STALE_THRESHOLD_SEC:
                continue  # Still fresh; give Shogun a fair window.

            key = (eid, ets)
            if key in warned_entries:
                continue  # Already paged the Lord once about this one.

            warned_entries.add(key)

            # Build the warning message. Multi-line so it's readable on the
            # phone; Telegram renders \n correctly in sendMessage.
            age_int = int(age)
            preview = (entry.get("content") or "").strip().splitlines()
            preview_line = preview[0][:60] if preview else "(empty message)"
            warning = (
                f"⚠️ Your message from {ets} hasn't been processed in {age_int}s.\n"
                f"   Shogun may be unresponsive. Type /progress to investigate, "
                f"or /help for commands.\n"
                f"   Message: {preview_line}"
            )

            try:
                subprocess.run(
                    ["bash", os.path.join(script_dir, "ntfy.sh"), warning],
                    check=False,
                    timeout=10,
                )
                print(f"[telegram_listener] Stale-inbox warning fired for id={eid} age={age_int}s")
            except Exception as e:
                print(f"[telegram_listener] watch_stale_inbox fire error: {e}", file=sys.stderr)
    except Exception as e:
        print(f"[telegram_listener] watch_stale_inbox error: {e}", file=sys.stderr)


TELEGRAM_MAX_CHARS = 4000  # Hard cap per message; Telegram's limit is 4096.


def _strip_markdown_for_telegram(text):
    """
    Convert markdown to a plain-text shape Telegram's strict parser won't choke
    on. The script output (agent_status.sh, dashboard.md) uses backticks,
    asterisks, and headings that can be unbalanced. Telegram's Markdown parser
    silently 400s on unbalanced delimiters and the Lord sees nothing.
    Strategy: keep content but neutralize the markers that cause parser errors.
      - Strip leading '#' chars from headings (turn them into plain labels)
      - Strip '**' (bold) and '__' (underline) pairs
      - Leave backticks alone (Telegram's parser tolerates them when balanced,
        and a single backtick run is usually intentional)
    Caller is responsible for truncation before sendMessage.
    """
    if not text:
        return ""
    out_lines = []
    for line in text.splitlines():
        # Drop leading '## ' / '# ' markers so headings read as plain text
        stripped = line.lstrip("#").rstrip()
        if line.lstrip().startswith("#"):
            # Preserve the original wording as a label
            out_lines.append(stripped)
        else:
            # Strip '**' and '__' (paired bold/underline markers)
            cleaned = stripped.replace("**", "").replace("__", "")
            out_lines.append(cleaned)
    return "\n".join(out_lines)


def _truncate_for_telegram(text, max_chars=TELEGRAM_MAX_CHARS, suffix=None):
    """Hard-cap a string to max_chars. If truncated, append a footer so the
    Lord knows where to look for the full content."""
    if not text:
        return text or ""
    if len(text) <= max_chars:
        return text
    if suffix is None:
        suffix = "\n…\n(truncated, full content on dashboard.md)"
    keep = max_chars - len(suffix)
    if keep < 0:
        keep = max_chars
    return text[:keep] + suffix


# Map agent_status.sh Status column to phone emoji.
_STATUS_EMOJI = {
    # Healthy
    "idle": "🟢",
    "done": "🟢",
    "ready": "🟢",
    # Active
    "working": "🟡",
    "in_progress": "🟡",
    "busy": "🟡",
    "active": "🟡",
    # Problems
    "error": "🔴",
    "failed": "🔴",
    "blocked": "🔴",
    "stuck": "🔴",
}


def _status_emoji(status_str):
    """Map a status string to emoji. Unknown -> neutral."""
    if not status_str or status_str in ("---", "N/A", "?"):
        return "⚪"
    return _STATUS_EMOJI.get(status_str.lower(), "⚪")


def _parse_agent_status_table(output):
    """Parse agent_status.sh table output. Expected columns:
       Agent | CLI | State | Task ID | Status | Inbox
    The State column is always 'N/A' in current output and the CLI column
    is always 'antigravity', so the columns collapse to: agent | cli_state
    (space-separated) | task_id | status | inbox. We split on 2+ spaces
    and handle the 'cli state' collapse by reading task_id from parts[2]
    onward if the row has fewer than 5 wide-spaced parts.
    Skips header + separator rows. Returns list of dicts, or None on parse
    failure (caller falls back to raw output)."""
    rows = []
    for line in output.splitlines():
        s = line.strip()
        if not s:
            continue
        # Skip the dashed separator row
        if s.startswith("---") or set(s.replace(" ", "")) <= {"-"}:
            continue
        # Skip the header row (column names)
        if s.lower().startswith("agent") and "cli" in s.lower():
            continue
        parts = re.split(r"\s{2,}", s)
        if len(parts) < 4:
            return None  # Format drift — let caller fall back
        agent = parts[0].strip()
        # CLI + State are often collapsed because State is always "N/A"
        # and columns are narrow. If parts[1] contains a space, split it.
        cli_state = parts[1]
        if " " in cli_state:
            cli, state = cli_state.split(" ", 1)
        else:
            cli = cli_state
            state = parts[2] if len(parts) > 2 else ""
            # Shift indices: agent | cli | state | task | status | inbox
            task_id = parts[3].strip() if len(parts) > 3 else ""
            status = parts[4].strip() if len(parts) > 4 else ""
            inbox = parts[5].strip() if len(parts) > 5 else ""
            rows.append({
                "agent": agent,
                "cli": cli,
                "state": state,
                "task_id": task_id,
                "status": status,
                "inbox": inbox,
            })
            continue
        # agent | cli_state | task | status | inbox
        task_id = parts[2].strip() if len(parts) > 2 else ""
        status = parts[3].strip() if len(parts) > 3 else ""
        inbox = parts[4].strip() if len(parts) > 4 else ""
        rows.append({
            "agent": agent,
            "cli": cli,
            "state": state,
            "task_id": task_id,
            "status": status,
            "inbox": inbox,
        })
    return rows


def _shape_status_rows(rows):
    """Turn parsed rows into a compact phone-friendly status block.
    Includes ALL agents (even idle ones — 'is everyone alive?' is a key
    signal). Appends a summary line."""
    lines = ["🏯 Agent Status", ""]
    busy = idle = 0
    for r in rows:
        emoji = _status_emoji(r["status"])
        status_norm = (r["status"] or "").lower()
        if status_norm in ("done", "idle"):
            idle += 1
        elif status_norm and status_norm not in ("---", "n/a"):
            busy += 1
        # Skip agents with no task and no real status (truly dead) — keep
        # them visible but compact, since absence could be a bug.
        task = r["task_id"]
        task_disp = "" if task in ("---", "N/A", "None", "") else f" [{task}]"
        status_disp = r["status"] if r["status"] and r["status"] not in ("---", "N/A") else "—"
        lines.append(f"{emoji} {r['agent']}: {status_disp}{task_disp}")
    total = len(rows)
    lines.append("")
    lines.append(f"Summary: {busy}/{total} active, {idle}/{total} idle")
    return "\n".join(lines)


def build_status_text(script_dir):
    """
    Build the /status response as a phone-friendly list of agent states.
    Runs scripts/agent_status.sh --lang en and shapes the table output
    into an emoji-led compact list with a summary line at the bottom.
    Hard cap: STATUS_PHONE_CAP (800) chars.

    Failure modes:
      - Script not found / not executable: friendly error message.
      - Script returns non-zero: include stderr excerpt in the message.
      - Empty output: friendly fallback suggesting tmux may be down.
      - Table parse failure: defensive fallback to raw table output.
    This function does NOT call inbox_write.sh.
    """
    script_path = os.path.join(script_dir, "agent_status.sh")
    if not os.path.exists(script_path):
        return _truncate_for_telegram(
            "🏯 agent_status.sh not found — cannot report agent state.",
            max_chars=STATUS_PHONE_CAP,
        )
    try:
        proc = subprocess.run(
            ["bash", script_path, "--lang", "en"],
            capture_output=True,
            text=True,
            timeout=10,
        )
    except subprocess.TimeoutExpired:
        return _truncate_for_telegram(
            "🏯 agent_status.sh timed out after 10s — tmux may be unresponsive.",
            max_chars=STATUS_PHONE_CAP,
        )
    except Exception as e:
        return _truncate_for_telegram(
            f"🏯 Failed to run agent_status.sh: {e}",
            max_chars=STATUS_PHONE_CAP,
        )

    output = (proc.stdout or "").strip()
    if proc.returncode != 0 and not output:
        err = (proc.stderr or "").strip().splitlines()
        detail = err[0] if err else f"exit code {proc.returncode}"
        return _truncate_for_telegram(
            f"🏯 agent_status.sh failed: {detail}\n"
            f"   (is the tmux session running?)",
            max_chars=STATUS_PHONE_CAP,
        )
    if not output:
        return _truncate_for_telegram(
            "🏯 No agent data available — is the tmux session running?",
            max_chars=STATUS_PHONE_CAP,
        )

    # Try to shape it. If parsing fails (format drift), fall back to raw.
    rows = _parse_agent_status_table(output)
    if rows is None or not rows:
        # Parse drift — better to show something than nothing. Surface a
        # stderr warning for the operator (state-tracked so it logs once on
        # the OK->FAILING transition, not once per /status tap).
        first_line = (output.splitlines() or [""])[0][:100]
        _log_status_parse_state(
            failing=True,
            reason=f"unexpected row format: {first_line}",
        )
        return _truncate_for_telegram(
            _strip_markdown_for_telegram(output),
            max_chars=STATUS_PHONE_CAP,
        )
    _log_status_parse_state(failing=False, reason="")
    shaped = _shape_status_rows(rows)
    if len(shaped) > STATUS_PHONE_CAP:
        shaped = _truncate_for_telegram(shaped, max_chars=STATUS_PHONE_CAP)
    return shaped


# Phone-friendly caps. Visible above the fold on a 6-inch screen is ~800
# chars; we set the soft target slightly higher to give the shaping logic
# room to breathe, and the hard ceiling well below Telegram's 4096 limit.
DASHBOARD_PHONE_CAP = 1200
STATUS_PHONE_CAP = 800
SUMMARY_MAX_CHARS = 60  # Truncate summary at this many characters

# /cancel dedup window (seconds). Mirrors the ntfy.sh 5s hash dedup so a
# burst of /cancel taps from the Lord doesn't spam Shogun's inbox or fire
# duplicate Telegram acks. In-memory only — the listener process owns it.
CANCEL_DEDUP_SEC = 5

# Module-level cancel dedup state. Set of (timestamp_floor, cmd_id) so we
# can dedup a /cancel for the same active cmd without blocking the Lord
# from re-cancelling a *different* cmd that's just been registered.
_last_cancel_ts = 0.0
_last_cancel_cmd_id = None

# Parser-failure log state. Track the last observed "OK"/"FAILING" state
# for the dashboard and status parsers so we log a stderr warning only on
# the OK -> FAILING transition (and on FAILING -> OK so operators know it
# recovered). None means "not yet observed".
_dashboard_parse_state = None  # None | "ok" | "failing"
_status_parse_state = None     # None | "ok" | "failing"

# Regex to extract task_id and (Completed: timestamp) from a bullet line like:
#   - [cmd_006] (Completed: 2026-06-09 22:01): Did some things.
_DASH_ITEM_RE = re.compile(
    r"\[(?P<task_id>[^\]]+)\]\s*\(Completed:\s*(?P<ts>[^)]+)\)\s*:?\s*(?P<summary>.*)"
)
_DASH_ITEM_LOOSE_RE = re.compile(
    r"\[(?P<task_id>[^\]]+)\]\s*:?\s*(?P<summary>.*)"
)


def _resolve_dashboard_path(script_dir):
    """Find dashboard.md. Prefer queue/dashboard.md (legacy/tests), but fall
    back to the project root since that's where it actually lives in this
    repo. Returns the first existing path, or the canonical one for error
    messages."""
    candidates = [
        os.path.abspath(os.path.join(script_dir, "../queue/dashboard.md")),
        os.path.abspath(os.path.join(script_dir, "../dashboard.md")),
    ]
    for p in candidates:
        if os.path.exists(p):
            return p
    return candidates[0]


def _log_dashboard_parse_state(failing, reason):
    """Log a stderr warning on OK <-> FAILING transitions for the dashboard
    parser. State-tracked at module level so a consistently-failing dashboard
    produces one warning (not one per /dashboard tap). Output is operator-
    only — never sent to Telegram. Returns the new state."""
    global _dashboard_parse_state
    new_state = "failing" if failing else "ok"
    if _dashboard_parse_state == new_state:
        return _dashboard_parse_state
    _dashboard_parse_state = new_state
    if failing:
        print(
            f"[telegram_listener] dashboard.md parse warning: {reason}",
            file=sys.stderr,
        )
    return _dashboard_parse_state


def _log_status_parse_state(failing, reason):
    """Log a stderr warning on OK <-> FAILING transitions for the
    agent_status.sh parser. Same idempotency contract as
    _log_dashboard_parse_state."""
    global _status_parse_state
    new_state = "failing" if failing else "ok"
    if _status_parse_state == new_state:
        return _status_parse_state
    _status_parse_state = new_state
    if failing:
        print(
            f"[telegram_listener] agent_status.sh table parse warning: {reason}",
            file=sys.stderr,
        )
    return _status_parse_state


def _truncate_summary(text, max_chars=SUMMARY_MAX_CHARS):
    """Truncate to first sentence, or max_chars, whichever is shorter.
    Returns text with trailing period + ellipsis on hard truncate."""
    if not text:
        return ""
    text = text.strip()
    # First sentence: split on '.', '!', '?' followed by space or end.
    for i, ch in enumerate(text):
        if ch in ".!?" and (i == len(text) - 1 or text[i + 1] == " "):
            sentence = text[: i + 1].strip()
            if 4 <= len(sentence) <= max_chars:
                return sentence
            break
    if len(text) <= max_chars:
        return text
    return text[: max_chars - 1].rstrip() + "…"


def _parse_dashboard_sections(text):
    """Parse dashboard.md into {section_name: [bullet_lines]}. Sections are
    marked by '## ' headings (e.g., '## 🚨 Action Required'). Each bullet
    line is preserved as the raw text including the leading '- '."""
    sections = {}
    current = None
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith("## "):
            current = stripped[3:].strip()
            sections.setdefault(current, [])
        elif current is not None and stripped.startswith("- "):
            sections[current].append(stripped[2:])
    return sections


def _shape_dashboard_section(section_name, bullet_lines, max_items=2):
    """Turn a section's bullets into a compact phone-friendly block.
    Returns a list of formatted lines (header + bullets) ready to join.
    Handles 'None' and empty cases explicitly to surface negative signal."""
    if not bullet_lines:
        return [f"{section_name}: None"]

    # "None" bullet -> just show the negative signal
    meaningful = [b for b in bullet_lines if b.strip().lower() != "none"]
    if not meaningful:
        return [f"{section_name}: None"]

    total = len(meaningful)
    header = f"{section_name}: {total} item(s)" if total > max_items else f"{section_name}:"
    lines = [header]
    for raw in meaningful[:max_items]:
        m = _DASH_ITEM_RE.match(raw)
        if m:
            task_id = m.group("task_id")
            summary = _truncate_summary(m.group("summary"))
            lines.append(f"   • {task_id}: {summary}")
        else:
            m2 = _DASH_ITEM_LOOSE_RE.match(raw)
            if m2:
                task_id = m2.group("task_id")
                summary = _truncate_summary(m2.group("summary"))
                lines.append(f"   • {task_id}: {summary}")
            else:
                # Malformed entry — show truncated raw line
                lines.append(f"   • {_truncate_summary(raw, SUMMARY_MAX_CHARS)}")
    if total > max_items:
        lines.append(f"   (+{total - max_items} more)")
    return lines


def _shape_achievements(bullet_lines, max_items=3, summary_cap=SUMMARY_MAX_CHARS):
    """Achievements: take the most recent N (listed newest-first), compute
    relative time, format as '✅ task_id (rel): summary'."""
    if not bullet_lines:
        return ["Recent Completions: None"]
    meaningful = [b for b in bullet_lines if b.strip().lower() != "none"]
    if not meaningful:
        return ["Recent Completions: None"]
    total = len(meaningful)
    lines = [f"Recent Completions ({total}):"]
    for raw in meaningful[:max_items]:
        m = _DASH_ITEM_RE.match(raw)
        if m:
            task_id = m.group("task_id")
            ts_str = m.group("ts").strip()
            summary = _truncate_summary(m.group("summary"), summary_cap)
            rel = _relative_time(ts_str)
            lines.append(f"   ✅ {task_id} ({rel}): {summary}")
        else:
            # Malformed — show truncated raw line
            lines.append(f"   ✅ {_truncate_summary(raw, summary_cap)}")
    if total > max_items:
        lines.append(f"   (+{total - max_items} more)")
    return lines


def _relative_time(ts_str, now=None):
    """Best-effort relative time like '3h ago', '1d ago'. Falls back to
    raw string on parse failure. Tolerates 'YYYY-MM-DD HH:MM' and
    'YYYY-MM-DDTHH:MM:SS' formats."""
    if now is None:
        now = time.time()
    candidates = [
        "%Y-%m-%d %H:%M:%S",
        "%Y-%m-%d %H:%M",
        "%Y-%m-%dT%H:%M:%S",
        "%Y-%m-%dT%H:%M",
    ]
    for fmt in candidates:
        try:
            ts = time.mktime(time.strptime(ts_str, fmt))
            break
        except Exception:
            continue
    else:
        return ts_str  # Unparseable — show as-is
    delta = int(now - ts)
    if delta < 0:
        return "just now"
    if delta < 60:
        return "just now"
    if delta < 3600:
        return f"{delta // 60}m ago"
    if delta < 86400:
        return f"{delta // 3600}h ago"
    if delta < 86400 * 30:
        return f"{delta // 86400}d ago"
    if delta < 86400 * 365:
        return f"{delta // (86400 * 30)}mo ago"
    return f"{delta // (86400 * 365)}y ago"


def build_dashboard_text(script_dir):
    """
    Build the /dashboard response as a phone-friendly summary.
    Reads dashboard.md (checks queue/ first, then project root) and surfaces:
      - Action Required items (top 2)
      - In Progress items (top 2)
      - Recent completions (top 3, newest first) with relative time
    Negative signals ('None') are surfaced explicitly.
    Hard cap: DASHBOARD_PHONE_CAP (1200) chars.

    Failure modes:
      - File missing or empty: friendly "no dashboard" message.
      - File unreadable: short error.
    Does NOT call inbox_write.sh.
    """
    dashboard_path = _resolve_dashboard_path(script_dir)
    if not os.path.exists(dashboard_path):
        return _truncate_for_telegram(
            "🏯 No dashboard yet — no tasks have been registered.",
            max_chars=DASHBOARD_PHONE_CAP,
        )
    try:
        with open(dashboard_path, "r", encoding="utf-8") as f:
            raw = f.read()
    except Exception as e:
        return _truncate_for_telegram(
            f"🏯 Could not read dashboard.md: {e}",
            max_chars=DASHBOARD_PHONE_CAP,
        )
    if not raw.strip():
        return _truncate_for_telegram(
            "🏯 Dashboard is empty — no tasks have been registered.",
            max_chars=DASHBOARD_PHONE_CAP,
        )

    sections = _parse_dashboard_sections(raw)

    # Find sections by emoji prefix or by known heading name. The exact
    # wording in dashboard.md is emoji-led, but we match loosely.
    def _find_section(*needles):
        for name, bullets in sections.items():
            for needle in needles:
                if needle in name:
                    return name, bullets
        return None, []

    action_name, action_bullets = _find_section("Action Required")
    inprog_name, inprog_bullets = _find_section("In Progress")
    achieve_name, achieve_bullets = _find_section("Achievements")

    # Parser-failure observability: log a stderr warning when the dashboard
    # is missing the Achievements section OR when the section exists but
    # every bullet is malformed. Both indicate format drift the operator
    # should know about. State-tracked so we only log on OK <-> FAILING
    # transitions, not on every call.
    global _dashboard_parse_state
    if achieve_name is None:
        _log_dashboard_parse_state(
            failing=True,
            reason=f"no Achievements section found at {dashboard_path}",
        )
    else:
        meaningful_ach = [b for b in achieve_bullets if b.strip().lower() != "none"]
        if meaningful_ach and not any(
            _DASH_ITEM_RE.match(b) or _DASH_ITEM_LOOSE_RE.match(b)
            for b in meaningful_ach
        ):
            _log_dashboard_parse_state(
                failing=True,
                reason=(
                    f"all {len(meaningful_ach)} Achievements bullet(s) malformed "
                    f"at {dashboard_path}"
                ),
            )
        else:
            _log_dashboard_parse_state(failing=False, reason="")

    lines = ["🏯 Project Dashboard", ""]

    # Strip emoji prefix from heading names so we don't double-emojify.
    def _strip_emoji(name):
        # Drop leading emoji + space. Common emojis in dashboard.md:
        for prefix in ("🚨 ", "🔄 ", "✅ ", "🔥 ", "⚠️ ", "📊 "):
            if name.startswith(prefix):
                return name[len(prefix):]
        return name

    if action_name is not None:
        clean = _strip_emoji(action_name)
        lines.extend(_shape_dashboard_section(f"🚨 {clean}", action_bullets, max_items=2))
    else:
        lines.append("🚨 Action Required: None")
    lines.append("")

    if inprog_name is not None:
        clean = _strip_emoji(inprog_name)
        lines.extend(_shape_dashboard_section(f"🔄 {clean}", inprog_bullets, max_items=2))
    else:
        lines.append("🔄 In Progress: None")
    lines.append("")

    if achieve_name is not None:
        lines.extend(_shape_achievements(achieve_bullets, max_items=3))
    else:
        lines.append("Recent Completions (0):")

    text = "\n".join(lines)

    # Hard-cap with graceful degradation: trim achievements, then summaries.
    if len(text) > DASHBOARD_PHONE_CAP:
        if achieve_name is not None:
            lines_reduced = lines[:]
            # Replace achievements block with 2-item version
            # Find where the achievements section starts.
            cut = None
            for i, ln in enumerate(lines_reduced):
                if ln.startswith("Recent Completions"):
                    cut = i
                    break
            if cut is not None:
                lines_reduced = lines_reduced[:cut]
                lines_reduced.extend(_shape_achievements(achieve_bullets, max_items=2))
                text = "\n".join(lines_reduced)

    if len(text) > DASHBOARD_PHONE_CAP:
        # Final fallback: tighter summary cap
        if achieve_name is not None:
            lines_tight = ["🏯 Project Dashboard", "",
                           "🚨 Action Required: None" if not action_bullets else
                           "\n".join(_shape_dashboard_section(f"🚨 Action Required", action_bullets, max_items=2)),
                           "",
                           "🔄 In Progress: None" if not inprog_bullets else
                           "\n".join(_shape_dashboard_section(f"🔄 In Progress", inprog_bullets, max_items=2)),
                           ""]
            lines_tight.extend(_shape_achievements(achieve_bullets, max_items=2, summary_cap=30))
            text = "\n".join(lines_tight)

    if len(text) > DASHBOARD_PHONE_CAP:
        text = _truncate_for_telegram(text, max_chars=DASHBOARD_PHONE_CAP)

    return text


def _find_active_cmd_id(script_dir):
    """Find the most recent cmd in queue/shogun_to_karo.yaml whose status
    is not 'done' and not 'cancelled'. Returns the cmd id string, or None
    if no active command exists. The active command is the one Karo is
    currently working on (or the one the Lord just issued that Shogun has
    not yet delegated). Status check matches the YAML schema used by
    queue/shogun_to_karo.yaml (status field per cmd entry)."""
    cmd_path = os.path.abspath(
        os.path.join(script_dir, "../queue/shogun_to_karo.yaml")
    )
    if not os.path.exists(cmd_path):
        return None
    try:
        import yaml
        with open(cmd_path, "r", encoding="utf-8") as f:
            data = yaml.safe_load(f)
    except Exception:
        return None
    if not isinstance(data, list):
        return None
    # Walk the list in REVERSE so we return the most recent active cmd.
    # Archive is intentionally not scanned — the active queue is the
    # source of truth.
    for entry in reversed(data):
        if not isinstance(entry, dict):
            continue
        cid = entry.get("id")
        if not cid:
            continue
        status = (entry.get("status") or "").lower()
        if status in ("done", "cancelled"):
            continue
        return str(cid)
    return None


def build_cancel_text(script_dir):
    """
    Build the /cancel response. Looks for the most recent active cmd in
    queue/shogun_to_karo.yaml and, if one exists, writes a cancel_request
    inbox message to Shogun so it can set the cmd's status to 'cancelled'
    at the next safe checkpoint. Phone-friendly: response is always
    < 200 chars.

    Dedup: a second /cancel for the same active cmd within CANCEL_DEDUP_SEC
    is a no-op (returns the same ack, no inbox write). A /cancel after
    the cmd has actually been marked done/cancelled returns a friendly
    "Last command already completed" message and does NOT wake Shogun.

    Returns a string suitable for direct sendMessage.
    """
    global _last_cancel_ts, _last_cancel_cmd_id

    active_cmd_id = _find_active_cmd_id(script_dir)
    if active_cmd_id is None:
        # No active command — nothing to cancel. Reset dedup state so a
        # future /cancel isn't suppressed by a stale entry.
        _last_cancel_ts = 0.0
        _last_cancel_cmd_id = None
        return "🏯 No active command to cancel."

    now = time.time()
    # Dedup: same active cmd within CANCEL_DEDUP_SEC = no-op.
    if (
        active_cmd_id == _last_cancel_cmd_id
        and (now - _last_cancel_ts) < CANCEL_DEDUP_SEC
    ):
        return (
            f"🏯 Cancel request already sent for {active_cmd_id}. "
            f"It will abort at the next safe checkpoint."
        )

    inbox_write_path = os.path.join(script_dir, "inbox_write.sh")
    msg = (
        f"CANCEL_REQUEST: cancel the current command "
        f"({active_cmd_id}) at the next safe checkpoint"
    )
    try:
        subprocess.run(
            [
                "bash", inbox_write_path, "shogun",
                msg, "cancel_request", "telegram_listener",
            ],
            check=True,
            timeout=10,
        )
        _last_cancel_ts = now
        _last_cancel_cmd_id = active_cmd_id
        return (
            f"🏯 Cancel request sent. {active_cmd_id} will abort at the "
            f"next safe checkpoint. You'll see a confirmation when complete."
        )
    except subprocess.TimeoutExpired:
        return "🏯 Cancel request timed out — inbox_write.sh did not respond."
    except Exception as e:
        return f"🏯 Cancel request failed: {e}"


def build_progress_summary(script_dir):
    """
    Build a one-line summary of what the system is doing right now.
    Order of preference:
      1. Active question (blocks everything else)
      2. Unread entry in queue/inbox/shogun.yaml (Lord sent, Shogun hasn't picked up)
      3. Active task in queue/tasks/*.yaml (status != done/idle)
      4. Fallback to dashboard.md first non-empty line
      5. Static 'all quiet' message
    Output is truncated to 200 chars for a phone screen.
    """
    # 1. Is the Lord being waited on?
    question_file = os.path.join(script_dir, "../queue/current_question.json")
    if os.path.exists(question_file):
        try:
            with open(question_file, "r", encoding="utf-8") as qf:
                q = json.load(qf)
            if q.get("status") in ("pending", "waiting_for_free_text"):
                return f"⏳ Blocked on Lord: {q.get('question', '?')}"[:200]
        except Exception:
            pass

    # 2. Has the Lord sent a message that Shogun hasn't picked up yet?
    #    This distinguishes "genuine idle" from "lost/dropped message" — a
    #    critical visibility gap when the Lord lives on Telegram. We read the
    #    script-maintained queue/inbox/shogun.yaml (read: true/false flag)
    #    rather than the ntfy_inbox.yaml shadow log, because the inbox is
    #    the actual system of record and is updated deterministically by
    #    inbox_write.sh and the agent that processes the message.
    try:
        import yaml
        shogun_inbox_path = os.path.join(script_dir, "../queue/inbox/shogun.yaml")
        if os.path.exists(shogun_inbox_path):
            with open(shogun_inbox_path, "r", encoding="utf-8") as f:
                shogun_data = yaml.safe_load(f) or {}
            shogun_entries = shogun_data.get("messages")
            if isinstance(shogun_entries, list):
                for entry in shogun_entries:
                    if not isinstance(entry, dict):
                        continue
                    if not entry.get("read", False):
                        ts = entry.get("timestamp", "?")
                        content = (entry.get("content") or "").strip()
                        preview = content.splitlines()[0][:60] if content else ""
                        if not preview:
                            preview = entry.get("id", "(empty)")
                        return f"📨 Awaiting Shogun (since {ts}): {preview}"[:200]
    except Exception:
        pass

    # 3. Scan queue/tasks/ for any in-progress work
    tasks_dir = os.path.join(script_dir, "../queue/tasks")
    if os.path.isdir(tasks_dir):
        try:
            import yaml
            active = []
            idle_count = 0
            for fname in sorted(os.listdir(tasks_dir)):
                if not fname.endswith(".yaml"):
                    continue
                fpath = os.path.join(tasks_dir, fname)
                try:
                    with open(fpath, "r", encoding="utf-8") as f:
                        data = yaml.safe_load(f)
                except Exception:
                    continue
                task = data.get("task") if isinstance(data, dict) else None
                if not isinstance(task, dict):
                    continue
                status = task.get("status")
                if status in (None, "", "done"):
                    continue
                if status == "idle":
                    idle_count += 1
                    continue
                # status indicates an active task
                desc = (task.get("description") or "").strip().splitlines()
                short = desc[0][:60] if desc else task.get("task_id", fname)
                active.append(f"{fname.replace('.yaml','')}: {short}")
            if active:
                first = active[0]
                extra = f" (+{len(active)-1} more)" if len(active) > 1 else ""
                return f"🔨 {first}{extra}"[:200]
        except Exception:
            pass

    # 4. Fall back to dashboard.md
    dashboard_path = os.path.join(script_dir, "../queue/dashboard.md")
    if os.path.exists(dashboard_path):
        try:
            with open(dashboard_path, "r", encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if not line or line.startswith("#"):
                        continue
                    return f"📊 {line}"[:200]
        except Exception:
            pass

    return "🏯 All quiet on the army — no active tasks."


def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    env_path = os.path.join(script_dir, "../config/telegram.env")
    env = load_env(env_path)

    token = os.environ.get("TELEGRAM_BOT_TOKEN") or env.get("TELEGRAM_BOT_TOKEN")
    chat_id = os.environ.get("TELEGRAM_CHAT_ID") or env.get("TELEGRAM_CHAT_ID")

    if not token or not chat_id or "your_bot_token_here" in token or "your_chat_id_here" in chat_id:
        print("[telegram_listener] Telegram credentials not configured. Exiting.", file=sys.stderr)
        sys.exit(1)

    print(f"[telegram_listener] Starting Telegram listener (Chat ID: {chat_id})...")

    # Register slash commands with Telegram.
    # Order = frequency-of-use (cheapest first), so the autocomplete list lines
    # up with the cost hierarchy:
    #   progress  -> one-line, listener direct
    #   dashboard -> markdown read, listener direct
    #   status    -> shells out to agent_status.sh, listener direct
    #   btw / run -> wake the Telegram agent (LLM)
    commands_payload = {
        "commands": [
            {"command": "progress", "description": "One-line: what is the system doing right now? (free, instant)"},
            {"command": "dashboard", "description": "Project summary: Frog, streak, completion %"},
            {"command": "status", "description": "Live state of all agent tmux panes (where is it stuck?)"},
            {"command": "cancel", "description": "Cancel the currently-active command (no LLM cost)"},
            {"command": "btw", "description": "Ask a side question about the Shogun's context cheaply"},
            {"command": "help", "description": "Show usage instructions and routing help"},
            {"command": "run", "description": "Run a side task command in workspace shell"}
        ]
    }
    register_res = make_telegram_request(token, "setMyCommands", commands_payload)
    if register_res.get("ok"):
        print("[telegram_listener] Successfully registered slash commands with Telegram.")
    else:
        print(f"[telegram_listener] Warning: Failed to register slash commands: {register_res.get('description')}")

    # Get current offset
    offset_file = os.path.join(script_dir, "../config/telegram_offset.txt")
    offset = 0
    if os.path.exists(offset_file):
        try:
            with open(offset_file, "r") as f:
                offset = int(f.read().strip())
        except Exception:
            pass

    if offset == 0:
        updates_res = make_telegram_request(token, "getUpdates", {"limit": 1})
        if updates_res.get("ok") and updates_res.get("result"):
            offset = updates_res["result"][-1]["update_id"] + 1

    # Shadow-log writer: append every Lord message to queue/ntfy_inbox.yaml
    # for human audit. The watchdog does NOT read this file (it reads
    # queue/inbox/shogun.yaml instead, where read state is script-managed).
    # Kept for forensics — ntfy_inbox.yaml gives a per-message history that
    # the per-agent inboxes do not.
    shadow_log_path = os.path.join(script_dir, "../queue/ntfy_inbox.yaml")
    message_buffers = {}

    # Throttle map for active-blocker "still waiting" edits.
    # Key: message_id (int). Value: last edit timestamp (float).
    last_blinker_edit = {}
    BLINKER_INTERVAL_SEC = 30

    # Stale-inbox watchdog: tracks (id, timestamp) tuples we've already warned
    # the Lord about so the same entry doesn't get re-paged every loop.
    # Pruned by watch_stale_inbox() once an entry is read or removed, so the
    # set stays bounded across long uptimes.
    warned_entries = set()

    while True:
        try:
            # Save offset periodically
            if offset > 0:
                try:
                    with open(offset_file, "w") as f:
                        f.write(str(offset))
                except Exception:
                    pass

            # Determine timeout based on whether any buffers have chunks
            has_buffered = any(len(buf["chunks"]) > 0 for buf in message_buffers.values())
            poll_timeout = 1 if has_buffered else 30

            poll_payload = {
                "offset": offset,
                "timeout": poll_timeout,
                "allowed_updates": ["message", "callback_query"]
            }
            poll_res = make_telegram_request(token, "getUpdates", poll_payload)

            # Hoist question_file binding outside the per-update loop so the
            # blinker block below stays valid even when Telegram returns an
            # empty result set (the common case between Lord interactions).
            question_file = os.path.join(script_dir, "../queue/current_question.json")

            if poll_res.get("ok"):
                for update in poll_res.get("result", []):
                    offset = update["update_id"] + 1

                    # Check if there is an active telegram question
                    active_question = None
                    if os.path.exists(question_file):
                        try:
                            with open(question_file, "r", encoding="utf-8") as qf:
                                active_question = json.load(qf)
                        except Exception:
                            pass
                    
                    # A. Handle Callback Query (Button taps on Telegram dialogs)
                    if "callback_query" in update:
                        cb = update["callback_query"]
                        cb_msg = cb.get("message", {})
                        cb_chat_id = cb_msg.get("chat", {}).get("id")
                        
                        if str(cb_chat_id) != str(chat_id):
                            continue
                            
                        if active_question and active_question.get("status") != "answered" and cb_msg.get("message_id") == active_question.get("message_id"):
                            data = cb.get("data", "")
                            
                            if data == "opt_other":
                                # Acknowledge callback query
                                make_telegram_request(token, "answerCallbackQuery", {"callback_query_id": cb["id"], "text": "Please type your response."})
                                
                                # Edit original message to remove buttons and prompt for text input
                                new_text = f"❓ *Question:*\n{active_question.get('question')}\n\n✏️ *Please type your custom reply below:*"
                                make_telegram_request(token, "editMessageText", {
                                    "chat_id": chat_id,
                                    "message_id": active_question.get("message_id"),
                                    "text": new_text,
                                    "parse_mode": "Markdown"
                                })
                                
                                # Update JSON to waiting_for_free_text
                                active_question["status"] = "waiting_for_free_text"
                                try:
                                    with open(question_file, "w", encoding="utf-8") as qf:
                                        json.dump(active_question, qf, indent=2, ensure_ascii=False)
                                except Exception:
                                    pass
                                    
                            elif data.startswith("opt_"):
                                try:
                                    opt_idx = int(data.split("_")[1])
                                    selected_option = active_question.get("options", [])[opt_idx]
                                except Exception:
                                    selected_option = data
                                    
                                # Acknowledge callback query
                                make_telegram_request(token, "answerCallbackQuery", {"callback_query_id": cb["id"], "text": f"Selected: {selected_option}"})
                                
                                # Edit original message to show selection
                                new_text = f"❓ *Question:*\n{active_question.get('question')}\n\n✅ *Selected:* {selected_option}"
                                make_telegram_request(token, "editMessageText", {
                                    "chat_id": chat_id,
                                    "message_id": active_question.get("message_id"),
                                    "text": new_text,
                                    "parse_mode": "Markdown"
                                })
                                
                                # Update JSON to answered
                                active_question["status"] = "answered"
                                active_question["response"] = selected_option
                                try:
                                    with open(question_file, "w", encoding="utf-8") as qf:
                                        json.dump(active_question, qf, indent=2, ensure_ascii=False)
                                except Exception:
                                    pass
                                
                                # Wake up Karo via inbox
                                try:
                                    inbox_write_path = os.path.join(script_dir, "inbox_write.sh")
                                    subprocess.run([
                                        "bash", inbox_write_path, "karo",
                                        f"Telegram question answered: {selected_option}",
                                        "telegram_answer", "telegram_listener"
                                    ], check=True)
                                except Exception as e:
                                    print(f"[telegram_listener] Error nudging Karo: {e}", file=sys.stderr)
                        else:
                            # Clear loading spinner for informational callback queries
                            make_telegram_request(token, "answerCallbackQuery", {"callback_query_id": cb["id"], "text": "Acknowledged"})
                            
                            # Remove inline keyboard from the informational message
                            make_telegram_request(token, "editMessageReplyMarkup", {
                                "chat_id": chat_id,
                                "message_id": cb_msg.get("message_id"),
                                "reply_markup": {"inline_keyboard": []}
                            })
                        continue
                    
                    # B. Handle Messages
                    if "message" in update:
                        msg = update["message"]
                        msg_chat_id = msg.get("chat", {}).get("id")
                        
                        if str(msg_chat_id) != str(chat_id):
                            continue
                            
                        # Check if this message is a reply/answer to the active question
                        is_reply_to_question = False
                        reply_to = msg.get("reply_to_message", {})
                        if active_question and active_question.get("status") != "answered":
                            is_reply = reply_to.get("message_id") == active_question.get("message_id")
                            is_waiting = active_question.get("status") == "waiting_for_free_text"
                            if is_reply or is_waiting:
                                is_reply_to_question = True
                                
                        if is_reply_to_question:
                            reply_text = msg.get("text", "").strip()
                            if reply_text:
                                # Confirm receipt by editing the original message to show the reply
                                new_text = f"❓ *Question:*\n{active_question.get('question')}\n\n✅ *Reply:* {reply_text}"
                                make_telegram_request(token, "editMessageText", {
                                    "chat_id": chat_id,
                                    "message_id": active_question.get("message_id"),
                                    "text": new_text,
                                    "parse_mode": "Markdown"
                                })
                                
                                # Update JSON to answered
                                active_question["status"] = "answered"
                                active_question["response"] = reply_text
                                try:
                                    with open(question_file, "w", encoding="utf-8") as qf:
                                        json.dump(active_question, qf, indent=2, ensure_ascii=False)
                                except Exception:
                                    pass
                                
                                # Wake up Karo via inbox
                                try:
                                    inbox_write_path = os.path.join(script_dir, "inbox_write.sh")
                                    subprocess.run([
                                        "bash", inbox_write_path, "karo",
                                        f"Telegram question answered: {reply_text}",
                                        "telegram_answer", "telegram_listener"
                                    ], check=True)
                                except Exception as e:
                                    print(f"[telegram_listener] Error nudging Karo: {e}", file=sys.stderr)
                            continue
                            
                        # Ignore replies (handled by reply check above)
                        if "reply_to_message" in msg:
                            continue
                            
                        msg_text = msg.get("text", "").strip()
                        if not msg_text:
                            continue
                            
                        msg_id = msg.get("message_id")
                        print(f"[telegram_listener] Received command: {msg_text}")
                        
                        # Check if it is a slash command or status/dashboard/help/btw keywords
                        lower_msg = msg_text.lower()
                        if lower_msg == "/progress":
                            progress_text = build_progress_summary(script_dir)
                            res = make_telegram_request(token, "sendMessage", {
                                "chat_id": chat_id,
                                "text": progress_text,
                                "parse_mode": "Markdown"
                            })
                            print(f"[telegram_listener] sendMessage (/progress) response: {res}")
                            continue

                        # /status -> listener direct: shell out to scripts/agent_status.sh.
                        # No LLM cost, no inbox_write. Bare "status" / "status?" are
                        # also handled here so behavior matches /progress.
                        if lower_msg in ("/status", "status", "status?"):
                            status_text = build_status_text(script_dir)
                            res = make_telegram_request(token, "sendMessage", {
                                "chat_id": chat_id,
                                "text": status_text,
                            })
                            print(f"[telegram_listener] sendMessage (/status) response: {res}")
                            continue

                        # /dashboard -> listener direct: read queue/dashboard.md.
                        # No LLM cost, no inbox_write. Bare "dashboard" is also
                        # handled here for consistency with /progress and /status.
                        if lower_msg in ("/dashboard", "dashboard"):
                            dash_text = build_dashboard_text(script_dir)
                            res = make_telegram_request(token, "sendMessage", {
                                "chat_id": chat_id,
                                "text": dash_text,
                            })
                            print(f"[telegram_listener] sendMessage (/dashboard) response: {res}")
                            continue

                        # /cancel -> listener direct: scan queue/shogun_to_karo.yaml
                        # for the most recent active cmd, write a cancel_request
                        # to Shogun's inbox (with 5s in-memory dedup), and ack
                        # the Lord. Bare "cancel" follows the same pattern.
                        if lower_msg in ("/cancel", "cancel"):
                            cancel_text = build_cancel_text(script_dir)
                            res = make_telegram_request(token, "sendMessage", {
                                "chat_id": chat_id,
                                "text": cancel_text,
                            })
                            print(f"[telegram_listener] sendMessage (/cancel) response: {res}")
                            continue

                        if lower_msg == "/help" or lower_msg == "help":
                            help_text = (
                                "🏯 *multi-agent-shogun Command Help* ⚔️\n\n"
                                "You can control your Shogun AI team directly from this chat.\n\n"
                                "*Slash Commands:*\n"
                                "• `/status` - Query the live status of all active agent panes.\n"
                                "• `/dashboard` - Show a summary of the current project tasks.\n"
                                "• `/cancel` - Cancel the currently-active command at the next safe checkpoint.\n"
                                "• `/help` - Display this help guide.\n\n"
                                "*How to order your Shogun:*\n"
                                "Simply send any natural language command here. Shogun will receive it, decompose it, and delegate it to the Karo and Ashigaru workers in the background.\n\n"
                                "Example:\n"
                                "`Implement a user authentication endpoint in python`"
                            )
                            res = make_telegram_request(token, "sendMessage", {
                                "chat_id": chat_id,
                                "text": help_text,
                                "parse_mode": "Markdown"
                            })
                            print(f"[telegram_listener] sendMessage (/help) response: {res}")
                            continue

                        # Anything starting with "/" is treated as a slash
                        # command, but /progress, /status, /dashboard, /help
                        # are all handled above as direct (no-LLM) handlers.
                        # The remaining slash commands and the bare "btw"
                        # keyword (or "btw ..." prefix) are routed to the
                        # Telegram agent — that's the only category that
                        # still incurs LLM cost by design.
                        if msg_text.startswith("/") or lower_msg in ["btw"] or lower_msg.startswith("btw "):
                            print(f"[telegram_listener] Routing side command to Telegram agent: {msg_text}")
                            # Signal Telegram agent to wake up
                            inbox_write_path = os.path.join(script_dir, "inbox_write.sh")
                            subprocess.run([
                                "bash", inbox_write_path, "telegram",
                                msg_text,
                                "telegram_cmd", "telegram_listener"
                            ], check=True)
                        else:
                            print(f"[telegram_listener] Buffering normal command/message: {msg_text}")
                            cid_str = str(chat_id)
                            if cid_str not in message_buffers:
                                message_buffers[cid_str] = {
                                    "last_received": time.time(),
                                    "chunks": []
                                }
                            message_buffers[cid_str]["chunks"].append({
                                "id": msg_id,
                                "text": msg_text
                            })
                            message_buffers[cid_str]["last_received"] = time.time()
            else:
                time.sleep(2)

            # Flush expired buffers
            current_time = time.time()
            chats_to_flush = []
            for cid, buf in message_buffers.items():
                if buf["chunks"] and (current_time - buf["last_received"] >= 1.5):
                    chats_to_flush.append(cid)

            for cid in chats_to_flush:
                buf = message_buffers[cid]
                # Sort chunks by message ID to ensure correct order
                sorted_chunks = sorted(buf["chunks"], key=lambda x: x["id"])
                concatenated_text = "\n".join(chunk["text"] for chunk in sorted_chunks)
                first_msg_id = sorted_chunks[0]["id"]

                print(f"[telegram_listener] Flushing buffer for chat {cid}. Concatenated text length: {len(concatenated_text)}")

                # Forward to Shogun
                append_to_inbox(shadow_log_path, first_msg_id, concatenated_text)

                # Send instant feedback to user (Minimal ACK to prevent double-reporting noise)
                # Instead of a full message, we send a single emoji to acknowledge reception.
                # The Shogun will follow up with the actual strategic confirmation.
                feedback_text = "🏯"

                make_telegram_request(token, "sendMessage", {
                    "chat_id": cid,
                    "text": feedback_text,
                    "parse_mode": "Markdown"
                })


                # Signal Shogun to wake up
                inbox_write_path = os.path.join(script_dir, "inbox_write.sh")
                try:
                    subprocess.run([
                        "bash", inbox_write_path, "shogun",
                        f"Received new command from Telegram: {concatenated_text}",
                        "ntfy_received", "telegram_listener"
                    ], check=True)
                except Exception as e:
                    print(f"[telegram_listener] Error nudging Shogun: {e}", file=sys.stderr)

                # Clear buffer for this chat
                message_buffers[cid]["chunks"] = []

            # Active-Blocker Feedback: if a question is still pending, periodically
            # edit the original question message to remind the Lord we are waiting.
            # Throttled to BLINKER_INTERVAL_SEC per message_id to respect Telegram
            # rate limits and avoid edit-storming the API.
            try:
                if os.path.exists(question_file):
                    with open(question_file, "r", encoding="utf-8") as qf:
                        blinker_question = json.load(qf)
                else:
                    blinker_question = None

                if blinker_question and blinker_question.get("status") in ("pending", "waiting_for_free_text"):
                    blinker_msg_id = blinker_question.get("message_id")
                    if blinker_msg_id is not None:
                        now = time.time()
                        last_edit = last_blinker_edit.get(blinker_msg_id, 0)
                        if now - last_edit >= BLINKER_INTERVAL_SEC:
                            status_label = (
                                "waiting for your text reply"
                                if blinker_question.get("status") == "waiting_for_free_text"
                                else "waiting on you to respond"
                            )
                            blinker_text = (
                                f"❓ *Question:*\n{blinker_question.get('question')}\n\n"
                                f"⏳ _{status_label}..._"
                            )
                            edit_res = make_telegram_request(token, "editMessageText", {
                                "chat_id": chat_id,
                                "message_id": blinker_msg_id,
                                "text": blinker_text,
                                "parse_mode": "Markdown"
                            })
                            # Only update throttle timestamp if the edit succeeded;
                            # a failed edit (e.g. message not modified) shouldn't
                            # block future retries, but a successful one resets the
                            # window so we don't spam the API.
                            if edit_res.get("ok"):
                                last_blinker_edit[blinker_msg_id] = now
                            else:
                                # If Telegram says the message is identical, the
                                # throttle window is effectively not advanced but
                                # we still want to avoid hot-looping: nudge forward
                                # by half the interval.
                                last_blinker_edit[blinker_msg_id] = now - (BLINKER_INTERVAL_SEC / 2)
                elif blinker_question is None:
                    # Question file was removed (answered and cleaned up) — drop
                    # any throttle entries for completed questions.
                    last_blinker_edit.clear()
            except Exception as e:
                print(f"[telegram_listener] Blinker edit error: {e}", file=sys.stderr)

            # Progress Pings: deliver any due entries from queue/pending_pings.yaml
            # via scripts/ntfy.sh. Shogun schedules these when delegating multi-stage
            # commands and clears them on completion. Cheap (one small YAML read per
            # loop) and bounded by an orphan-grace of 30 min.
            fire_due_pings(script_dir)

            # Stale-Inbox Watchdog: warn the Lord once if a Telegram message
            # has been sitting in queue/inbox/shogun.yaml as unread for more
            # than 90s. Distinguishes "system is working" from "system lost
            # your message". Source of truth is the script-maintained Shogun
            # inbox, not the ntfy_inbox.yaml shadow log (which the watchdog
            # used to read but which requires LLM cooperation to maintain).
            # Idempotent and bounded — see watch_stale_inbox.
            watch_stale_inbox(script_dir, warned_entries)

            time.sleep(0.5)
        except Exception as e:
            print(f"[telegram_listener] Error: {e}", file=sys.stderr)
            time.sleep(5)

if __name__ == "__main__":
    main()
