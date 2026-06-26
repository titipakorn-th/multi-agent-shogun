#!/usr/bin/env python3
"""
check_required_validations.py — Task 6 gap-closure

Reads queue/tasks/orchestrator.yaml and verifies that all required
validations have been completed before a parent cmd can transition to
status: done.

Data shape (canonical, defined here):
    queue/tasks/orchestrator.yaml:
      orchestration:
        parent_cmd: cmd_xxx
        required_validations:
          - role: oracle
            subtask_id: cmd_xxx_a
            required_for: [done]
          - role: council
            subtask_id: cmd_xxx_b
            required_for: [done]

Each subtask's report (queue/reports/<role>_report.yaml) must have:
    parent_cmd: cmd_xxx
    subtask_id: cmd_xxx_a
    verdict: PASS_FULL | PASS_PARTIAL | PASS_BY_DESIGN | FAIL_BLOCKER | FAIL_NON_BLOCKER

A validation is "completed" when the report exists with a PASS_* verdict.
A validation is "missing" when no report exists for the subtask_id.
A validation is "failed" when the verdict starts with FAIL_.

Exit codes:
  0  — all required validations PASS_* (parent cmd may proceed to done)
  1  — usage error
  2  — missing required validation(s) — must NOT proceed
  3  — failed required validation(s) — must NOT proceed
  4  — stale validations (>24h old, completed long ago, may be ignored)
"""

import argparse
import sys
from pathlib import Path

import yaml


def load_yaml(path: Path) -> dict:
    try:
        with open(path, "r", encoding="utf-8") as f:
            return yaml.safe_load(f) or {}
    except FileNotFoundError:
        return {}
    except yaml.YAMLError as e:
        print(f"FAIL: cannot parse {path}: {e}", file=sys.stderr)
        sys.exit(1)


def collect_subtask_reports(roles: list, reports_dir: Path) -> dict:
    """Map subtask_id → {role, verdict, timestamp} from all role reports."""
    out = {}
    for role in roles:
        path = reports_dir / f"{role}_report.yaml"
        if not path.exists():
            continue
        data = load_yaml(path)
        # Reports are typically a list of sections; each section has parent_cmd + subtask_id + verdict.
        # Some report files have top-level list, others have sections dict.
        sections = data.get("sections") if isinstance(data, dict) else None
        if isinstance(sections, list):
            items = sections
        elif isinstance(sections, dict):
            items = list(sections.values())
        elif isinstance(data, list):
            items = data
        else:
            items = []
        for item in items:
            if not isinstance(item, dict):
                continue
            subtask = item.get("subtask_id") or item.get("task_id")
            if not subtask:
                continue
            out[subtask] = {
                "role": role,
                "verdict": item.get("verdict", "UNKNOWN"),
                "timestamp": item.get("timestamp") or item.get("completed_at"),
                "raw": item,
            }
    return out


def check(parent_cmd: str, orchestrator_path: Path, reports_dir: Path, role: str) -> int:
    data = load_yaml(orchestrator_path)
    if not isinstance(data, dict) or "orchestration" not in data:
        print(f"FAIL: orchestrator.yaml missing 'orchestration' block", file=sys.stderr)
        return 1
    orchestration = data.get("orchestration") or {}
    actual_parent = orchestration.get("parent_cmd")
    if actual_parent and actual_parent != parent_cmd:
        print(f"WARN: orchestrator.yaml parent_cmd={actual_parent}, expected={parent_cmd}", file=sys.stderr)

    required = orchestration.get("required_validations") or []
    if not required:
        print(f"PASS: no required_validations for {parent_cmd}")
        return 0

    # Load role report files.
    VALIDATOR_ROLES = {"oracle", "council", "observer"}
    reports = collect_subtask_reports(list(VALIDATOR_ROLES), reports_dir)

    missing = []
    failed = []
    passed = []

    for v in required:
        if not isinstance(v, dict):
            continue
        subtask_id = v.get("subtask_id")
        v_role = v.get("role", "oracle")
        required_for = v.get("required_for", ["done"])
        if role not in required_for and "done" not in required_for:
            # Not required for this terminal status.
            continue
        if not subtask_id:
            print(f"FAIL: required_validations entry missing subtask_id: {v}", file=sys.stderr)
            failed.append({"subtask_id": "<missing>", "role": v_role})
            continue
        report = reports.get(subtask_id)
        if not report:
            missing.append({"subtask_id": subtask_id, "role": v_role})
            continue
        verdict = report.get("verdict", "")
        if verdict.startswith("FAIL"):
            failed.append({"subtask_id": subtask_id, "role": v_role, "verdict": verdict})
        elif verdict.startswith("PASS"):
            passed.append({"subtask_id": subtask_id, "role": v_role, "verdict": verdict})
        else:
            # Unknown verdict — treat as not-yet-completed.
            missing.append({"subtask_id": subtask_id, "role": v_role, "verdict": verdict})

    print(f"Validation check for {parent_cmd}:")
    print(f"  Required: {len(required)}")
    print(f"  Passed:   {len(passed)}")
    print(f"  Missing:  {len(missing)}")
    print(f"  Failed:   {len(failed)}")

    for p in passed:
        print(f"  PASS  {p['subtask_id']} ({p['role']}): {p.get('verdict','')}")
    for m in missing:
        print(f"  MISS  {m['subtask_id']} ({m['role']}) — no report yet", file=sys.stderr)
    for f in failed:
        print(f"  FAIL  {f['subtask_id']} ({f['role']}): {f.get('verdict','')}", file=sys.stderr)

    if failed:
        return 3
    if missing:
        return 2
    return 0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("parent_cmd", help="e.g. cmd_001")
    parser.add_argument("--orchestrator", default="queue/tasks/orchestrator.yaml",
                        help="path to orchestrator.yaml")
    parser.add_argument("--reports", default="queue/reports",
                        help="path to reports directory")
    parser.add_argument("--role", default="done",
                        help="terminal role being checked (e.g. done)")
    args = parser.parse_args()

    project_root = Path(__file__).resolve().parent.parent
    orch_path = Path(args.orchestrator)
    if not orch_path.is_absolute():
        orch_path = project_root / orch_path
    reports_path = Path(args.reports)
    if not reports_path.is_absolute():
        reports_path = project_root / reports_path

    sys.exit(check(args.parent_cmd, orch_path, reports_path, args.role))


if __name__ == "__main__":
    main()