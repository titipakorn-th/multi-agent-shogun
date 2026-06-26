#!/usr/bin/env python3
"""
check_batch_gates.py — Task 11 gap-closure

Turns the batch-processing protocol (CLAUDE.md / AGENTS.md) into executable
checklist data for commands with 30+ items.

Workflow per the protocol:
    ① Strategy → Oracle review → incorporate feedback
    ② Execute batch1 ONLY → Shogun QC
    ③ QC NG → Stop all agents → Root cause analysis → Oracle review
       → Fix instructions → Restore clean state → Go to ②
    ④ QC OK → Execute batch2+ (no per-batch QC needed)
    ⑤ All batches complete → Final QC
    ⑥ QC OK → Next phase (go to ①) or Done

Required task YAML fields for batch cmds:
    batch:
      item_count: 50
      batch_size: 30
      strategy_reviewed_by: oracle
      strategy_reviewed_at: "2026-06-26T..."
      batches:
        - batch_id: batch1
          status: dispatched | qc_pending | qc_passed | qc_failed
          dispatched_at: "2026-06-26T..."
          qc_reviewed_at: null
          qc_reviewed_by: null
          qc_outcome: null
        - batch_id: batch2
          status: pending
      unprocessed_detection_pattern: "status: pending"
      quality_template_present: true
      checkpoint_state: qc_pending | qc_passed | qc_failed

Exit codes:
  0  — all gates passed, batch2+ dispatch allowed
  1  — usage error
  2  — strategy review missing
  3  — batch1 not yet QC'd (block batch2+ dispatch)
  4  — batch1 QC failed (block all further batches)
  5  — quality template missing
  6  — unprocessed detection pattern missing
  7  — item_count mismatch (declared vs batch sum)
"""

import argparse
import sys
from pathlib import Path

import yaml


def load_yaml(path: Path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return yaml.safe_load(f) or {}
    except FileNotFoundError:
        return None
    except yaml.YAMLError as e:
        print(f"FAIL: cannot parse {path}: {e}", file=sys.stderr)
        sys.exit(1)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("task_yaml", help="path to specialist task YAML")
    parser.add_argument("--phase", choices=["dispatch-batch2", "dispatch-all"],
                        default="dispatch-batch2",
                        help="which dispatch gate to check")
    args = parser.parse_args()

    task_path = Path(args.task_yaml)
    if not task_path.is_file():
        print(f"FAIL: task YAML not found: {task_path}", file=sys.stderr)
        sys.exit(1)

    data = load_yaml(task_path)
    if not isinstance(data, dict):
        print(f"FAIL: task YAML is not a mapping", file=sys.stderr)
        sys.exit(1)

    batch = data.get("batch")
    if not batch:
        print(f"FAIL: task YAML missing 'batch' block (only batch cmds require this)", file=sys.stderr)
        sys.exit(1)

    item_count = batch.get("item_count", 0)
    if item_count < 30:
        print(f"FAIL: item_count={item_count} (< 30) — batch gates only apply to 30+ items", file=sys.stderr)
        sys.exit(1)

    failures = []

    # Gate 1: strategy review required
    if not batch.get("strategy_reviewed_by"):
        failures.append("strategy_reviewed_by is missing (oracle must review first)")

    # Gate 2: quality template
    if not batch.get("quality_template_present"):
        failures.append("quality_template_present is false (must include web search, no-fabrication, fallback rules)")

    # Gate 3: unprocessed-item detection pattern
    if not batch.get("unprocessed_detection_pattern"):
        failures.append("unprocessed_detection_pattern missing (required so /clear recovery can skip completed items)")

    # Gate 4: at least one batch declared
    batches = batch.get("batches") or []
    if not batches:
        failures.append("batches list is empty — at least batch1 must be declared")

    # Gate 5: batch1 QC outcome determines whether batch2+ may dispatch
    batch1 = batches[0] if batches else None
    if batch1:
        status = batch1.get("status")
        if args.phase == "dispatch-batch2":
            if status == "qc_failed":
                print(f"BLOCKED: batch1 QC failed at {batch1.get('qc_reviewed_at')} — root cause analysis required before retry", file=sys.stderr)
                sys.exit(4)
            if status not in ("qc_passed",):
                print(f"BLOCKED: batch1 status='{status}' — must reach qc_passed before batch2 dispatch", file=sys.stderr)
                sys.exit(3)

    # Gate 6: item_count vs batch sum sanity check
    declared_total = sum(b.get("item_count", 0) for b in batches if isinstance(b, dict))
    if declared_total and declared_total != item_count:
        failures.append(f"item_count mismatch: declared={item_count}, batches sum={declared_total}")

    if failures:
        print(f"FAIL: batch gates not satisfied ({len(failures)} issue(s)):", file=sys.stderr)
        for f in failures:
            print(f"  - {f}", file=sys.stderr)
        sys.exit(2)

    print(f"OK: batch gates pass ({item_count} items, {len(batches)} batch(es), batch1={batch1.get('status') if batch1 else 'n/a'})")
    sys.exit(0)


if __name__ == "__main__":
    main()