#!/usr/bin/env python3
"""
queue_health_check.py — Task 9 gap-closure

Reports queue health metrics before Orchestrator work starts:
  - active command count + total byte size of shogun_to_orchestrator.yaml
  - terminal commands left in active files (status: done/cancelled/paused
    not yet archived)
  - stale tmp files under queue/ (older than 1 hour)
  - corrupt inbox backups (.corrupt suffix)
  - oversized inboxes (>100 unread messages)

Modes:
  --dry-run    report only (default)
  --fix        archive obvious orphans (NEVER touches live unread messages)

Exit codes:
  0  — healthy (no warnings)
  1  — usage error
  2  — warnings present (run --fix or archive manually)
"""

import argparse
import sys
import time
from pathlib import Path

import yaml

# Thresholds.
STALE_TMP_SECONDS = 3600  # 1 hour
INBOX_UNREAD_WARN = 100
CMD_QUEUE_SIZE_WARN = 64 * 1024  # 64KB


def yaml_or_empty(path: Path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return yaml.safe_load(f) or {}
    except FileNotFoundError:
        return {}
    except yaml.YAMLError as e:
        return {"__yaml_error__": str(e)}


def cmd_size_and_count(queue_file: Path) -> tuple:
    """Returns (byte_size, cmd_count, terminal_count)."""
    if not queue_file.exists():
        return 0, 0, 0
    size = queue_file.stat().st_size
    data = yaml_or_empty(queue_file)
    if "orchestration" in data:
        cmds = []  # orchestrator state file is not a queue
    elif isinstance(data, dict):
        key = "commands" if "commands" in data else "queue"
        cmds = data.get(key, []) or []
    else:
        cmds = []
    terminal = 0
    if isinstance(cmds, list):
        for c in cmds:
            if isinstance(c, dict) and (c.get("status") in ("done", "cancelled", "paused")):
                terminal += 1
    return size, len(cmds) if isinstance(cmds, list) else 0, terminal


def find_stale_tmp_files(queue_dir: Path) -> list:
    """Find .tmp.* files older than STALE_TMP_SECONDS."""
    out = []
    now = time.time()
    if not queue_dir.exists():
        return out
    for p in queue_dir.rglob("*.tmp.*"):
        try:
            age = now - p.stat().st_mtime
            if age >= STALE_TMP_SECONDS:
                out.append((str(p), int(age)))
        except FileNotFoundError:
            continue
    return out


def find_corrupt_inbox_backups(queue_dir: Path) -> list:
    """Find *.corrupt backup files (created by inbox_write.sh on parse failure)."""
    out = []
    if not queue_dir.exists():
        return out
    for p in queue_dir.rglob("*.corrupt"):
        out.append(str(p))
    return out


def count_inbox_unread(inbox_file: Path) -> int:
    data = yaml_or_empty(inbox_file)
    if not isinstance(data, dict):
        return 0
    msgs = data.get("messages", []) or []
    if not isinstance(msgs, list):
        return 0
    return sum(1 for m in msgs if isinstance(m, dict) and not m.get("read", False))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--queue-dir", default="queue",
                        help="path to queue directory (default: queue)")
    parser.add_argument("--dry-run", action="store_true", default=True,
                        help="report only (default)")
    parser.add_argument("--fix", action="store_true",
                        help="archive obvious orphans (NEVER touches unread)")
    args = parser.parse_args()

    project_root = Path(__file__).resolve().parent.parent
    queue_dir = Path(args.queue_dir)
    if not queue_dir.is_absolute():
        queue_dir = project_root / queue_dir

    warnings = []
    info = []

    # 1. Active command queue.
    cmd_queue = queue_dir / "shogun_to_orchestrator.yaml"
    size, count, terminal = cmd_size_and_count(cmd_queue)
    info.append(f"cmd_queue: {size} bytes, {count} cmds ({terminal} terminal)")
    if size > CMD_QUEUE_SIZE_WARN:
        warnings.append(f"cmd_queue > {CMD_QUEUE_SIZE_WARN} bytes ({size})")
    if terminal > 0:
        warnings.append(f"cmd_queue has {terminal} terminal cmd(s) still in active file")

    # 2. Stale tmp files.
    stale = find_stale_tmp_files(queue_dir)
    if stale:
        info.append(f"stale tmp files: {len(stale)}")
        for path, age in stale[:5]:
            info.append(f"  - {path} (age {age}s)")
            warnings.append(f"stale tmp file: {path}")

    # 3. Corrupt inbox backups.
    corrupt = find_corrupt_inbox_backups(queue_dir)
    if corrupt:
        info.append(f"corrupt inbox backups: {len(corrupt)}")
        for path in corrupt[:5]:
            info.append(f"  - {path}")
            warnings.append(f"corrupt inbox backup: {path}")

    # 4. Oversized inboxes.
    inbox_dir = queue_dir / "inbox"
    oversized = []
    if inbox_dir.exists():
        for f in sorted(inbox_dir.glob("*.yaml")):
            unread = count_inbox_unread(f)
            if unread > INBOX_UNREAD_WARN:
                oversized.append((f.name, unread))
    if oversized:
        info.append(f"oversized inboxes (> {INBOX_UNREAD_WARN} unread):")
        for name, n in oversized:
            info.append(f"  - {name}: {n} unread")
            warnings.append(f"oversized inbox: {name} ({n} unread)")

    # 5. Optional fix mode: archive stale tmp files.
    if args.fix and stale:
        for path, age in stale:
            try:
                Path(path).unlink()
                print(f"FIX: removed stale tmp file {path} (age {age}s)", file=sys.stderr)
            except OSError as e:
                print(f"FIX FAILED: {path}: {e}", file=sys.stderr)

    # Output report.
    print("Queue health report")
    print("===================")
    for line in info:
        print(f"  {line}")
    if warnings:
        print()
        print(f"WARNINGS ({len(warnings)}):")
        for w in warnings:
            print(f"  - {w}")
        sys.exit(2)

    print()
    print("OK: queue is healthy")
    sys.exit(0)


if __name__ == "__main__":
    main()