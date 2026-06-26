#!/usr/bin/env python3
"""
check_role_permissions.py — Task 8 gap-closure

Cross-CLI permission-enforcement matrix for Claude, Codex, OpenCode, Copilot,
Kimi, and Antigravity. Where a CLI cannot enforce filesystem permissions,
this script provides a runtime guard that detects forbidden file edits
BEFORE the change lands.

Permission enforcement by CLI:
  Claude   — enforced via settings.local.json (read_allow/edit_allow/edit_deny)
             Permissions CAN enforce filesystem access.
  Codex    — enforced via ~/.codex/config.toml (limited; mostly prompt-based)
             Permissions CANNOT reliably enforce filesystem access.
  Copilot  — enforced via .copilot/config.json (limited)
             Permissions CANNOT reliably enforce filesystem access.
  Kimi     — enforced via .kimi config (limited)
             Permissions CANNOT reliably enforce filesystem access.
  OpenCode — enforced via opencode-permissions.yaml (per-role)
             Permissions CAN enforce filesystem access.
  Antigravity — enforced via settings (similar to Claude)
             Permissions CAN enforce filesystem access.

Usage:
  python3 scripts/check_role_permissions.py <agent_id> --path <file_path> --op read|write|edit
  python3 scripts/check_role_permissions.py --matrix     # print matrix

Exit codes:
  0  — allowed (or permission not enforceable — caller should treat as warning)
  1  — usage error
  2  — forbidden by role permissions
  3  — role not configured
"""

import argparse
import sys
from pathlib import Path

import yaml

PROJECT_ROOT = Path(__file__).resolve().parent.parent
SETTINGS_FILE = PROJECT_ROOT / "config" / "settings.yaml"
OPENCODE_PERMS = PROJECT_ROOT / "config" / "opencode-permissions.yaml"

# CLI matrix: which CLIs can enforce filesystem permissions.
CLI_ENFORCES_FS = {
    "claude": True,
    "codex": False,
    "copilot": False,
    "kimi": False,
    "opencode": True,
    "antigravity": True,
}


def load_settings() -> dict:
    if not SETTINGS_FILE.is_file():
        return {}
    try:
        with open(SETTINGS_FILE, "r", encoding="utf-8") as f:
            return yaml.safe_load(f) or {}
    except yaml.YAMLError as e:
        print(f"FAIL: cannot parse settings.yaml: {e}", file=sys.stderr)
        sys.exit(1)


def load_opencode_perms() -> dict:
    if not OPENCODE_PERMS.is_file():
        return {}
    try:
        with open(OPENCODE_PERMS, "r", encoding="utf-8") as f:
            return yaml.safe_load(f) or {}
    except yaml.YAMLError:
        return {}


def get_role_config(agent_id: str) -> dict | None:
    settings = load_settings()
    roles = settings.get("roles") or {}
    role = roles.get(agent_id)
    if not role:
        return None
    # Permissions are nested under permissions_override. Flatten for the
    # permission check (also accepts legacy top-level edit_allow / edit_deny).
    override = role.get("permissions_override") or {}
    for key in ("read_allow", "read_deny", "edit_allow", "edit_deny"):
        if key not in role and key in override:
            role[key] = override[key]
    return role


def path_matches(path: str, patterns: list) -> bool:
    """Return True if path matches any of the glob-like patterns."""
    import fnmatch
    p = Path(path)
    for pat in patterns:
        if fnmatch.fnmatch(str(p), pat):
            return True
        # Also try matching against the absolute path.
        if fnmatch.fnmatch(str(p.resolve()), pat):
            return True
        # Also try matching against the basename.
        if fnmatch.fnmatch(p.name, pat):
            return True
    return False


def check_permission(agent_id: str, target_path: str, op: str) -> tuple:
    """
    Return (allowed: bool, reason: str).

    Logic:
      - If role config has explicit edit_allow → path must match.
      - If role config has explicit edit_deny → path must NOT match.
      - read_allow / read_deny apply similarly for read.
      - For ops other than the configured one (e.g., reading a denied-edit path),
        fall back to read rules.
      - If role has no config → return (False, "role not configured").
    """
    role_cfg = get_role_config(agent_id)
    if not role_cfg:
        return False, f"role '{agent_id}' not configured in settings.yaml"

    if op == "edit" or op == "write":
        allow = role_cfg.get("edit_allow") or []
        deny = role_cfg.get("edit_deny") or []
        # Also include common edit_deny.
        settings = load_settings()
        common_deny = list((settings.get("common") or {}).get("edit_deny") or [])
        deny = list(deny) + common_deny
    elif op == "read":
        allow = role_cfg.get("read_allow") or []
        deny = role_cfg.get("read_deny") or []
    else:
        return False, f"unknown op: {op}"

    if path_matches(target_path, deny):
        return False, f"{target_path} matches deny pattern in {op}"
    if allow and not path_matches(target_path, allow):
        return False, f"{target_path} not in {op}_allow for role '{agent_id}'"

    return True, "allowed"


def print_matrix() -> None:
    """Print the CLI permission-enforcement matrix."""
    print("CLI permission-enforcement matrix")
    print("=" * 60)
    print(f"{'CLI':<14} {'Enforces FS':<14} {'Config File':<32}")
    print("-" * 60)
    rows = [
        ("claude", "~/.claude/settings.local.json"),
        ("codex", "~/.codex/config.toml (limited)"),
        ("copilot", "~/.copilot/config.json (limited)"),
        ("kimi", "~/.kimi/config (limited)"),
        ("opencode", "config/opencode-permissions.yaml"),
        ("antigravity", "~/.config/antigravity/settings.json"),
    ]
    for cli, cfg in rows:
        enforces = "YES" if CLI_ENFORCES_FS.get(cli, False) else "no (prompt-only)"
        print(f"{cli:<14} {enforces:<14} {cfg:<32}")
    print()
    print("For CLIs marked 'no (prompt-only)', the role prompt must")
    print("explicitly state edit_deny / edit_allow rules and rely on")
    print("agent compliance. Use scripts/check_role_permissions.py")
    print("as a runtime preflight guard when dispatching to those CLIs.")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("agent_id", nargs="?", help="agent role (e.g. fixer, designer)")
    parser.add_argument("--path", help="file path being accessed")
    parser.add_argument("--op", choices=["read", "write", "edit"], help="operation")
    parser.add_argument("--matrix", action="store_true",
                        help="print the CLI permission matrix and exit")
    args = parser.parse_args()

    if args.matrix:
        print_matrix()
        return 0

    if not args.agent_id or not args.path or not args.op:
        print("Usage: check_role_permissions.py <agent_id> --path <path> --op <op>", file=sys.stderr)
        print("       check_role_permissions.py --matrix", file=sys.stderr)
        return 1

    allowed, reason = check_permission(args.agent_id, args.path, args.op)
    if allowed:
        print(f"ALLOW: {args.agent_id} {args.op} {args.path} ({reason})")
        return 0
    print(f"DENY: {args.agent_id} {args.op} {args.path} ({reason})", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())