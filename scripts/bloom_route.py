#!/usr/bin/env python3
"""
bloom_route.py — Task 3 gap-closure: executable Bloom auto-routing.

Reads a subtask list and config-driven `bloom_routing` setting, then emits a
work-graph YAML classifying each subtask into a Bloom level (L1-L6 or EVAL)
and routing it to the documented role:

  L1     → explorer  (recall)
  L2-L3  → orchestrator (apply — orchestrator handles directly)
  L4     → oracle    (analyze)
  L5     → oracle    (evaluate)   | EVAL flag → council
  L6     → oracle    (create)

Modes:
  auto   — classify each subtask (explicit `level` field wins; otherwise
           infer from keywords in title/description) and emit role per task.
  manual — emit a work graph but leave `role: manual` for every task.
  off    — emit an empty work graph (Orchestrator dispatches via prompt text).

Usage:
  python3 bloom_route.py --settings <yaml> --subtasks <yaml> [--out <yaml>]
  python3 bloom_route.py --settings <yaml> --subtasks <yaml> --infer

Exit codes:
  0  — work graph emitted (or empty in 'off' mode)
  1  — settings/subtasks file missing or invalid
  2  — bloom_routing value unsupported
  3  — subtask level is malformed and --strict given
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

import yaml


LEVEL_TO_ROLE = {
    "L1": ("explorer", "recall"),
    "L2": ("orchestrator", "apply"),
    "L3": ("orchestrator", "apply"),
    "L4": ("oracle", "analyze"),
    "L5": ("oracle", "evaluate"),
    "L6": ("oracle", "create"),
}


KEYWORD_HINTS = [
    (re.compile(r"\b(read|list|find|recall|locate|grep|search)\b", re.I), "L1"),
    (re.compile(r"\b(apply|implement|fix|run|use|execute|perform)\b", re.I), "L3"),
    (re.compile(r"\b(analyze|review|compare|examine|inspect)\b", re.I), "L4"),
    (re.compile(r"\b(evaluate|critique|judge|assess|grade|review.*plan)\b", re.I), "L5"),
    (re.compile(r"\b(design|architect|create|invent|synthesize|plan)\b", re.I), "L6"),
]


def classify(subtask: dict) -> tuple[str, str]:
    """Return (level, reason). Uses explicit `level` field if valid; else keyword inference."""
    explicit = (subtask.get("level") or "").strip().upper()
    if explicit in LEVEL_TO_ROLE:
        return explicit, f"explicit level={explicit}"

    text = " ".join(
        str(subtask.get(k, "")) for k in ("title", "description", "purpose")
    )
    for pat, lvl in KEYWORD_HINTS:
        if pat.search(text):
            return lvl, f"inferred from keyword ({lvl})"
    # Default: L3 (apply) — orchestrator handles directly without escalation.
    return "L3", "default fallback (no level/keyword match)"


def route(level: str, eval_flag: bool = False) -> tuple[str, str]:
    """Return (role, action) for a level. EVAL routes L5 to council instead of oracle."""
    if level == "L5" and eval_flag:
        return "council", "evaluate"
    role, action = LEVEL_TO_ROLE.get(level, ("orchestrator", "apply"))
    return role, action


def load_subtasks(path: Path) -> list[dict]:
    with open(path, "r", encoding="utf-8") as f:
        data = yaml.safe_load(f) or {}
    items = data.get("subtasks") or data.get("tasks") or []
    if not isinstance(items, list):
        raise ValueError(f"{path}: 'subtasks' must be a list")
    return items


def emit_work_graph(
    mode: str, subtasks: list[dict], infer: bool, strict: bool
) -> dict:
    graph = {"mode": mode, "tasks": []}
    if mode == "off":
        return graph

    for st in subtasks:
        if not isinstance(st, dict):
            if strict:
                raise ValueError(f"subtask entry is not a mapping: {st!r}")
            continue
        sid = st.get("id") or st.get("name") or "?"
        eval_flag = bool(st.get("eval") or st.get("evaluation"))

        if mode == "manual":
            graph["tasks"].append({
                "id": sid,
                "level": "manual",
                "route": "manual",
                "role": "manual",
                "reason": "bloom_routing=manual; orchestrator dispatches manually",
            })
            continue

        # mode == auto
        if infer and "level" not in st:
            level, reason = classify(st)
        else:
            level, reason = classify(st)
        role, action = route(level, eval_flag)
        graph["tasks"].append({
            "id": sid,
            "level": level,
            "route": f"{action}:{role}",
            "role": role,
            "action": action,
            "reason": reason,
        })
    return graph


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--settings", required=True, help="settings.yaml path")
    parser.add_argument("--subtasks", required=True, help="subtasks YAML path")
    parser.add_argument("--out", help="write work graph to this path (default: stdout)")
    parser.add_argument(
        "--infer",
        action="store_true",
        help="infer level from title/description when no explicit level is set",
    )
    parser.add_argument("--strict", action="store_true", help="fail on malformed entries")
    args = parser.parse_args()

    settings_path = Path(args.settings)
    if not settings_path.is_file():
        print(f"FAIL: settings file not found: {settings_path}", file=sys.stderr)
        return 1
    with open(settings_path, "r", encoding="utf-8") as f:
        settings = yaml.safe_load(f) or {}
    mode = settings.get("bloom_routing") or "off"
    if mode not in ("auto", "manual", "off"):
        print(f"FAIL: unsupported bloom_routing={mode!r}", file=sys.stderr)
        return 2

    try:
        subtasks = load_subtasks(Path(args.subtasks))
    except (ValueError, OSError) as e:
        print(f"FAIL: {e}", file=sys.stderr)
        return 1

    graph = emit_work_graph(mode, subtasks, args.infer, args.strict)

    out_text = yaml.safe_dump(graph, sort_keys=False, allow_unicode=True)
    if args.out:
        Path(args.out).write_text(out_text, encoding="utf-8")
    else:
        sys.stdout.write(out_text)
    return 0


if __name__ == "__main__":
    sys.exit(main())