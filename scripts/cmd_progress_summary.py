#!/usr/bin/env python3
"""
cmd_progress_summary.py — Task 10 gap-closure

Machine-readable command progress summary. Reads live YAML state and
produces a single JSON object describing each in-progress cmd:

    {
      "generated_at": "2026-06-26T...",
      "commands": [
        {
          "id": "cmd_001",
          "status": "in_progress",
          "purpose": "...",
          "active_specialists": [
            {"role": "fixer", "task_id": "cmd_001_a", "status": "assigned", "age_seconds": 120}
          ],
          "last_checkpoint": {"phase": "dispatched", "age_seconds": 60},
          "unread_reports": 0,
          "validation": {
            "required": [{"role": "oracle", "subtask_id": "cmd_001_b"}],
            "passed": 0,
            "missing": 1,
            "failed": 0
          },
          "blocker": "waiting on specialist",
          "delivery_suspected_stuck": false
        }
      ]
    }

Output modes:
  --format json  (default — machine-readable for Telegram/dashboard)
  --format text  (human-readable for terminal)

Blocker classification (one of):
  - "waiting on specialist"  — task assigned, no report yet
  - "waiting on validation"  — implementation done, validation missing
  - "waiting on Lord"        — action_required raised
  - "delivery suspected stuck" — checkpoint stale > 30 min OR assigned > 1h no report
"""

import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

import yaml

QUEUE_DIR_DEFAULT = "queue"
PROJECT_ROOT = Path(__file__).resolve().parent.parent


def load_yaml(path: Path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return yaml.safe_load(f) or {}
    except FileNotFoundError:
        return {}
    except yaml.YAMLError:
        return {}


def age_seconds(ts_str: str | None) -> int | None:
    if not ts_str:
        return None
    try:
        dt = datetime.fromisoformat(ts_str)
        now = datetime.now(dt.tzinfo) if dt.tzinfo else datetime.now()
        return int((now - dt).total_seconds())
    except Exception:
        return None


def classify_blocker(cmd: dict, active_specs: list, validation: dict, last_cp_age: int | None) -> tuple:
    """Return (blocker_label, delivery_suspected_stuck)."""
    # Waiting on Lord: explicit action_required.
    if cmd.get("action_required"):
        return "waiting on Lord", False

    # Waiting on validation: implementation done but validation missing.
    if validation["missing"] > 0:
        return "waiting on validation", False

    # Waiting on specialist: at least one assigned task without a report.
    waiting = [s for s in active_specs if s["status"] == "assigned"]
    if waiting:
        # Stuck heuristic: any waiting specialist > 1h, or last checkpoint > 30m.
        max_age = max((s["age_seconds"] or 0) for s in waiting)
        if max_age > 3600:
            return "waiting on specialist", True
        if last_cp_age and last_cp_age > 1800:
            return "waiting on specialist", True
        return "waiting on specialist", False

    # Default: dispatched, awaiting report.
    if last_cp_age and last_cp_age > 1800:
        return "delivery suspected stuck", True
    return "delivery suspected stuck", False


def gather_command_summary(cmd: dict, queue_dir: Path) -> dict:
    """Build per-cmd summary from cmd entry + related YAML files."""
    cmd_id = cmd.get("id", "<unknown>")
    summary = {
        "id": cmd_id,
        "status": cmd.get("status", "unknown"),
        "purpose": cmd.get("purpose", ""),
        "priority": cmd.get("priority", "P2"),
    }

    # Find active subtasks assigned to specialists.
    active_specs = []
    for role_file in (queue_dir / "tasks").glob("*.yaml"):
        if role_file.stem == "pending" or role_file.stem == "orchestrator":
            continue
        data = load_yaml(role_file)
        if not isinstance(data, dict):
            continue
        parent = data.get("parent_cmd") or (data.get("task") or {}).get("parent_cmd")
        if parent != cmd_id:
            continue
        status = data.get("status") or (data.get("task") or {}).get("status")
        if status not in ("assigned", "blocked"):
            continue
        task_id = data.get("task_id") or (data.get("task") or {}).get("task_id", role_file.stem)
        # Find the report for this task if it exists.
        report_file = queue_dir / "reports" / f"{role_file.stem}_report.yaml"
        report_data = load_yaml(report_file)
        sections = report_data.get("sections", []) if isinstance(report_data, dict) else []
        report_ts = None
        for s in sections if isinstance(sections, list) else []:
            if isinstance(s, dict) and (s.get("task_id") == task_id or s.get("subtask_id") == task_id):
                report_ts = s.get("timestamp") or s.get("completed_at")
                break
        active_specs.append({
            "role": role_file.stem,
            "task_id": task_id,
            "status": status,
            "age_seconds": age_seconds(data.get("timestamp") or data.get("started_at")),
            "report_timestamp": report_ts,
        })
    summary["active_specialists"] = active_specs

    # Unread reports for this cmd.
    unread_reports = 0
    for report_file in (queue_dir / "reports").glob("*_report.yaml"):
        data = load_yaml(report_file)
        sections = data.get("sections", []) if isinstance(data, dict) else []
        for s in sections if isinstance(sections, list) else []:
            if isinstance(s, dict) and s.get("parent_cmd") == cmd_id and not s.get("read"):
                unread_reports += 1
    summary["unread_reports"] = unread_reports

    # Last checkpoint.
    checkpoints_file = queue_dir / "orchestrator_checkpoints.yaml"
    last_cp = None
    last_cp_age = None
    if checkpoints_file.exists():
        data = load_yaml(checkpoints_file)
        for entry in reversed(data.get("checkpoints", []) or []):
            if isinstance(entry, dict) and entry.get("cmd_id") == cmd_id:
                last_cp = {"phase": entry.get("phase"), "status": entry.get("status")}
                last_cp_age = age_seconds(entry.get("timestamp"))
                break
    summary["last_checkpoint"] = {**last_cp, "age_seconds": last_cp_age} if last_cp else None

    # Validation summary.
    validations = cmd.get("required_validations") or []
    val_summary = {"required": [], "passed": 0, "missing": 0, "failed": 0}
    if validations:
        for v in validations:
            if not isinstance(v, dict):
                continue
            subtask_id = v.get("subtask_id")
            v_role = v.get("role", "oracle")
            val_summary["required"].append({"role": v_role, "subtask_id": subtask_id})
            report_file = queue_dir / "reports" / f"{v_role}_report.yaml"
            report_data = load_yaml(report_file)
            sections = report_data.get("sections", []) if isinstance(report_data, dict) else []
            found = False
            for s in sections if isinstance(sections, list) else []:
                if isinstance(s, dict) and (s.get("task_id") == subtask_id or s.get("subtask_id") == subtask_id):
                    verdict = s.get("verdict", "")
                    if verdict.startswith("FAIL"):
                        val_summary["failed"] += 1
                    elif verdict.startswith("PASS"):
                        val_summary["passed"] += 1
                    else:
                        val_summary["missing"] += 1
                    found = True
                    break
            if not found:
                val_summary["missing"] += 1
    summary["validation"] = val_summary

    blocker, stuck = classify_blocker(cmd, active_specs, val_summary, last_cp_age)
    summary["blocker"] = blocker
    summary["delivery_suspected_stuck"] = stuck

    return summary


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--queue-dir", default=QUEUE_DIR_DEFAULT)
    parser.add_argument("--format", choices=["json", "text"], default="json")
    args = parser.parse_args()

    queue_dir = PROJECT_ROOT / args.queue_dir
    if not queue_dir.is_absolute():
        queue_dir = PROJECT_ROOT / queue_dir

    cmd_queue_file = queue_dir / "shogun_to_orchestrator.yaml"
    data = load_yaml(cmd_queue_file)
    if not data:
        print(json.dumps({"generated_at": datetime.now(timezone.utc).isoformat(), "commands": []}))
        return 0

    key = "commands" if "commands" in data else "queue"
    items = data.get(key, []) or []
    in_progress_cmds = [c for c in items if isinstance(c, dict) and c.get("status") in ("in_progress", "pending")]

    summaries = [gather_command_summary(c, queue_dir) for c in in_progress_cmds]
    out = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "commands": summaries,
    }

    if args.format == "json":
        print(json.dumps(out, indent=2, sort_keys=False, default=str))
    else:
        for cmd in summaries:
            print(f"\n[{cmd['id']}] {cmd['status']} — {cmd['blocker']}")
            if cmd.get("delivery_suspected_stuck"):
                print("  ⚠️  delivery suspected stuck")
            print(f"  purpose: {cmd.get('purpose', '')[:80]}")
            for s in cmd.get("active_specialists", []):
                age = s.get("age_seconds") or 0
                print(f"  • {s['role']} ({s['task_id']}): {s['status']} (age {age}s)")
            if cmd.get("validation", {}).get("required"):
                v = cmd["validation"]
                print(f"  validation: passed={v['passed']} missing={v['missing']} failed={v['failed']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())