#!/usr/bin/env python3
"""
build_specialist_variants.py — Task 13 gap-closure

Single source of truth for emitting per-CLI variants of every specialist role
defined in config/settings.yaml. Replaces the prior two redundant paths in
scripts/build_instructions.sh:
  - discover_v2_role_cli_pairs (yq-based; silently no-op'd when yq missing)
  - V2_SPECIALIST_ROLES loop (hard-coded list)

Reads roles + cli_variant from settings.yaml, then emits:
    {output_dir}/{role}.md           (canonical copy)
    {output_dir}/{cli}-{role}.md     (per-CLI variant)

Exit codes:
  0  — success (emitted ≥ 1 file)
  1  — settings file missing or invalid
  2  — no roles found
"""

import os
import sys
from pathlib import Path

import yaml


def main() -> int:
    if len(sys.argv) < 2:
        print("Usage: build_specialist_variants.py <settings.yaml>", file=sys.stderr)
        return 1

    settings_path = Path(sys.argv[1])
    if not settings_path.is_file():
        print(f"FAIL: settings file not found: {settings_path}", file=sys.stderr)
        return 1

    root_dir = Path(os.environ["ROOT_DIR"])
    output_dir = Path(os.environ["OUTPUT_DIR"])
    output_dir.mkdir(parents=True, exist_ok=True)

    with open(settings_path, "r", encoding="utf-8") as f:
        settings = yaml.safe_load(f) or {}

    roles_block = settings.get("roles") or {}
    if not isinstance(roles_block, dict):
        print("  ⚠️  settings.roles is not a mapping; skipping specialist variant generation", file=sys.stderr)
        return 2

    # CLI variant set: union of all per-role cli_variant, falling back to cli.default.
    default_cli = (settings.get("cli") or {}).get("default", "claude")
    all_clis = set()
    for cfg in roles_block.values():
        if isinstance(cfg, dict):
            cv = cfg.get("cli_variant") or default_cli
            all_clis.add(cv)

    if not all_clis:
        print("  ⚠️  No CLI variants found in settings.yaml roles", file=sys.stderr)
        return 2

    # Emit {role}.md and {cli}-{role}.md for every (role, cli) combination.
    # Shogun / orchestrator / telegram are command-layer roles built by
    # build_instruction_file (YAML front matter + role template + common sections
    # + CLI-specific tools). Specialist roles below are emitted here as plain
    # copies so adding a role in settings.yaml auto-emits its variants.
    COMMAND_LAYER_ROLES = {"shogun", "orchestrator", "telegram"}
    emitted = 0
    for role in roles_block.keys():
        if role in COMMAND_LAYER_ROLES:
            continue
        src = root_dir / "instructions" / f"{role}.md"
        if not src.is_file():
            print(f"  ⚠️  instructions/{role}.md not found; skipping", file=sys.stderr)
            continue
        body = src.read_text(encoding="utf-8")
        # Plain canonical role file.
        dst_canonical = output_dir / f"{role}.md"
        dst_canonical.write_text(body, encoding="utf-8")
        emitted += 1
        # Per-CLI variants.
        for cli in sorted(all_clis):
            dst = output_dir / f"{cli}-{role}.md"
            dst.write_text(body, encoding="utf-8")
            emitted += 1

    print(f"  ✅ Generated {emitted} specialist variant file(s) across {len(all_clis)} CLI(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())