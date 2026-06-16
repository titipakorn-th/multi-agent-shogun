# Sub-Project D: Shogun V2 Config Schema Design

**Date:** 2026-06-16
**Sub-project:** D of 4 in the Specialist Agent Team Revamp
**Status:** Approved (pending spec self-review)
**Depends on:** Sub-A (topology)
**Enables:** Sub-B (orchestrator), Sub-C (specialists)

## Goal

Extend `config/settings.yaml` with a per-role schema covering the new 9-agent topology (shogun, orchestrator, and 7 specialists). Define validation, defaults, and migration path. Replace the role-based read/write matrices in `config/opencode-permissions.yaml` with inline `permissions_override` blocks in settings.yaml. Hard cutover — no legacy aliases.

## Schema Overview

The new `config/settings.yaml` adds a top-level `roles:` block. Each role entry has the full schema.

```yaml
# Existing fields stay at top
language: en
shell: bash
topology: v2          # NEW: controls which shutsurin script runs (v1|v2)
skill:
  save_path: "~/.claude/skills/"
  local_path: "./skills/"
logging:
  level: info
  path: "./logs/"
cli:
  default: claude     # Default CLI binary

# NEW: per-role configuration
roles:
  shogun:
    model: opus
    cli_variant: claude
    pane_target: "shogun:main.0"
    color: "#002b36"
    title: "shogun"
    prompt_path: "instructions/shogun.md"
    temperature: 0.1
    skills: [shogun-zoom-out, shogun-grill-with-docs]
    permissions_override: {}

  orchestrator:
    model: opus
    cli_variant: claude
    pane_target: "multiagent:ops.0"
    color: "#501515"
    title: "orchestrator"
    prompt_path: "instructions/orchestrator.md"
    temperature: 0.1
    skills: []
    permissions_override:
      read_allow:
        - "queue/inbox/orchestrator.yaml"
        - "queue/tasks/*.yaml"
        - "queue/reports/*.yaml"
        - "context/*"
        - "dashboard.md"
      edit_allow:
        - "queue/tasks/*.yaml"
        - "queue/tasks/pending.yaml"
        - "dashboard.md"
      edit_deny:
        - "queue/reports/*.yaml"   # orchestrator never overwrites specialist reports

  explorer:
    model: haiku
    cli_variant: claude
    pane_target: "multiagent:research.0"
    color: "#454510"
    title: "explorer"
    prompt_path: "instructions/explorer.md"
    temperature: 0.1
    skills: [codemap]
    permissions_override:
      read_allow: ["context/*"]
      edit_deny: ["**/*"]   # explorer is read-only

  librarian:
    model: sonnet
    cli_variant: claude
    pane_target: "multiagent:research.1"
    color: "#503515"
    title: "librarian"
    prompt_path: "instructions/librarian.md"
    temperature: 0.2
    skills: [web-search, doc-fetch]
    permissions_override:
      edit_deny: ["**/*"]   # librarian is read-only

  oracle:
    model: opus
    cli_variant: claude
    pane_target: "multiagent:research.2"
    color: "#9e7c0a"
    title: "oracle"
    prompt_path: "instructions/oracle.md"
    temperature: 0.1
    skills: [shogun-grill-with-docs]
    permissions_override:
      edit_deny: ["**/*"]   # oracle is read-only

  designer:
    model: sonnet
    cli_variant: claude
    pane_target: "multiagent:ops.2"
    color: "#3a1e3a"
    title: "designer"
    prompt_path: "instructions/designer.md"
    temperature: 0.3
    skills: [frontend-design]
    permissions_override: {}   # designer can edit, but only its lane

  fixer:
    model: sonnet
    cli_variant: claude
    pane_target: "multiagent:ops.1"
    color: "#1e3a1e"
    title: "fixer"
    prompt_path: "instructions/fixer.md"
    temperature: 0.2
    skills: [shogun-subagent-driven-development]
    permissions_override: {}   # fixer can edit, but only its lane

  observer:
    model: sonnet
    cli_variant: claude
    pane_target: "multiagent:ops.3"
    color: "#1e3a3a"
    title: "observer"
    prompt_path: "instructions/observer.md"
    temperature: 0.2
    skills: []
    permissions_override:
      edit_deny: ["**/*"]   # observer is read-only (visual analysis only)

  council:
    model: opus
    cli_variant: claude
    pane_target: "multiagent:research.3"
    color: "#353535"
    title: "council"
    prompt_path: "instructions/council.md"
    temperature: 0.1
    skills: []
    permissions_override:
      edit_deny: ["**/*"]   # council is read-only
```

## Defaults & Validation

### Required fields

Validation fails if any of these are missing:

- `model`
- `pane_target`
- `prompt_path`

### Optional fields with defaults

- `cli_variant` → defaults to `cli.default`
- `color` → auto-assigned from a palette hash if absent
- `title` → defaults to role name
- `temperature` → defaults to 0.2
- `skills` → defaults to `[]`
- `permissions_override` → defaults to `{}`

### Validation rules

Enforced by `scripts/validate_settings.sh`:

- All `pane_target` values must be unique
- `prompt_path` file must exist on disk
- `model` must be one of the supported models list (config-driven)
- `cli_variant` must be one of: `claude`, `codex`, `copilot`, `kimi`, `opencode`, `antigravity`
- For read-only roles (explorer, librarian, oracle, council, observer), `edit_deny: ["**/*"]` is auto-injected if not present
- When `topology: v2` is set, exactly 9 roles must be defined (shogun + orchestrator + 7 specialists). Extra roles trigger warning, not error.
- `topology` field must be one of: `v1`, `v2`. Defaults to `v1` for backwards compat.

### Validation script

`scripts/validate_settings.sh` — run during `first_setup.sh` and on every `shutsujin_departure.sh` startup. Fails fast with clear error messages pointing to the offending role/field.

## Migration Path (clean cutover)

Per user direction, no backwards-compat aliases. Hard cutover when `topology: v2` is set in settings.yaml.

### Pre-cutover checklist (in `scripts/migrate_to_v2.sh`)

1. Detect running v1 session via `tmux list-sessions`
2. Run `validate_settings.sh` against the new schema
3. Back up `queue/`, `reports/`, `dashboard.md` to `logs/migration/v1-to-v2-{timestamp}/`
4. Map existing task YAMLs to new roles (see mapping table)
5. Map report YAMLs the same way
6. Map inbox files the same way
7. Spawn v2 topology in parallel (do not tear down v1 yet)
8. Smoke-test: orchestrator receives a wakeup, dispatches to fixer, fixer reports back
9. If smoke-test passes → tear down v1
10. If smoke-test fails → roll back to v1, keep v2 scripts dormant, alert via dashboard 🚨

### Mapping table (hardcoded in migration script)

| Old | New |
|-----|-----|
| karo | orchestrator |
| ashigaru1 | explorer |
| ashigaru2 | librarian |
| ashigaru3 | oracle |
| ashigaru4 | designer |
| ashigaru5 | fixer |
| ashigaru6 | observer |
| ashigaru7 | council |
| gunshi | oracle |

### Scripts that need updating (no aliases — must be rewritten)

- `scripts/inbox_write.sh` (role validation)
- `scripts/inbox_watcher.sh` (read role → pane target from settings.yaml)
- `scripts/slim_yaml.sh` (per-role compression)
- `scripts/validate_settings.sh` (new)
- `scripts/migrate_to_v2.sh` (new)
- `instructions/karo.md` → `instructions/orchestrator.md` (renamed)
- `instructions/ashigaru.md` → `instructions/{role}.md` (one per role)
- `instructions/gunshi.md` → `instructions/oracle.md` (reused)
- `instructions/generated/*.md` (regenerated by build_instructions.sh)

## Script Integration

### `scripts/inbox_write.sh` — new role validator

```bash
# Validates target_role is one of the 9 defined roles
ROLE_LIST=$(yq '.roles | keys | .[]' config/settings.yaml)
if ! echo "$ROLE_LIST" | grep -qx "$TARGET"; then
    echo "Error: unknown role '$TARGET'. Defined roles: $ROLE_LIST" >&2
    exit 1
fi
```

### `scripts/inbox_watcher.sh` — reads pane target from config

```bash
# Reads pane_target from settings.yaml
PANE_TARGET=$(yq ".roles.$AGENT_ID.pane_target" config/settings.yaml)
CLI_VARIANT=$(yq ".roles.$AGENT_ID.cli_variant // .cli.default" config/settings.yaml)
```

### `shutsujin_departure.sh` (sub-A) — iterates roles from config

```bash
# Loop over roles in settings.yaml, spawn each pane
for role in $(yq '.roles | keys | .[]' config/settings.yaml); do
    pane_target=$(yq ".roles.$role.pane_target" config/settings.yaml)
    model=$(yq ".roles.$role.model" config/settings.yaml)
    color=$(yq ".roles.$role.color" config/settings.yaml)
    title=$(yq ".roles.$role.title" config/settings.yaml)
    cli=$(yq ".roles.$role.cli_variant // .cli.default" config/settings.yaml)

    start_specialist_pane "$role" "$pane_target" "$model" "$color" "$title" "$cli"
done
```

### `scripts/build_instructions.sh` (existing)

Generates per-role instructions from `config/settings.yaml` + `instructions/{role}.md` templates. Output: `instructions/generated/{cli}-{role}.md` (current pattern preserved).

### Permissions source of truth

`config/settings.yaml` → `roles.{role}.permissions_override` is the single source of truth for v2. The separate `config/opencode-permissions.yaml` file is **deprecated** for v2 (kept in repo for v1 reference but not loaded when `topology: v2`).

## Out of Scope (handled by later sub-projects)

- Sub-B: Orchestrator agent prompt with lane rules and dispatch decision flow
- Sub-C: The 7 specialist prompts (explorer, librarian, oracle, designer, fixer, observer, council)
- Sub-A: `shutsujin_departure.sh` rewrite (only the role iteration loop in Section 4 is specified here; the full script rewrite is in sub-A)

## Open Questions for Later Phases

1. Should the validator enforce a maximum number of roles? Currently warns but doesn't error on extras. Confirm in sub-B testing.
2. Does the yq dependency need to be added to `first_setup.sh`? yq is a Go binary; check existing `requirements.txt`.
3. For the `permissions_override` field, should we use a glob syntax (e.g., `queue/tasks/*.yaml`) or a list of exact paths? Currently mixed; needs sub-D implementation decision.

## Testing & Validation

### Unit tests

- `test_validate_settings.sh` — feeds valid and invalid settings.yaml files through the validator; checks exit codes and error messages
- `test_role_list.sh` — verifies exactly 9 roles defined when `topology: v2`
- `test_pane_targets_unique.sh` — verifies all pane targets in roles block are unique
- `test_default_injection.sh` — verifies optional fields get auto-injected when missing

### Integration tests

- `test_inbox_write_role_validation.sh` — sends to valid and invalid roles; expects success/failure
- `test_migration_mapping.sh` — runs the migration script on a sample v1 layout; verifies mapping is correct
- `test_smoke_migration.sh` — full v1 → v2 dry run on a test sandbox

### E2E validation

- After running `migrate_to_v2.sh` on a real v1 setup, all 9 panes spawn with correct configs
- inbox_write to each role reaches the correct pane
- existing scripts (slim_yaml, etc.) work with new role-based file naming

## Migration Notes

- The existing `config/opencode-permissions.yaml` stays in the repo for v1 reference (the file is whitelisted in `.gitignore`)
- `config/settings.yaml` is gitignored (per current behavior) — only the sample template is committed
- New sample template at `config/settings.yaml.sample` shows the v2 schema with placeholder values
