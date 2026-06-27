---
title: Skill wiring gap closure — reconcile the three disjoint skill layers
auto_continue: false
---

_Authored 2026-06-27 after a wiring audit. The repo declares per-agent skills in
three places that don't agree, and the place that looks authoritative
(`config/settings.yaml roles.*.skills`) is read by no code. This plan closes the
gap: make declared skills resolve to invocable skills, or delete the declaration._

`auto_continue: false` — Task 3 deletes/symlinks files and edits shared config;
Lord should confirm the direction (Task 2 decision) before execution dispatches.

## Background — the three layers and how they diverge

| Layer | What | Wired today? |
|------|------|--------------|
| `config/settings.yaml` → `roles.<role>.skills` | per-role skill name list | **DEAD** — `grep -rn skills scripts/` = 0 hits. No launcher, hook, or depart step reads it. |
| `skills/<role>/*/SKILL.md` | ~30 authored role skill folders | **UNREACHABLE** — not in `~/.claude/skills`, not in `.claude/skills/`, no install step. Docs only; not invocable as `/name`. |
| `instructions/<role>.md` → "Mandatory Skills Protocol" | `superpowers:*` triggers | **WORKS** — resolves to actually-available skills. The only functioning layer. |

Actual invocable skills for any pane = `~/.claude/skills/` global symlinks + plugins
(superpowers, ponytail, design, …). The project's `skills/` tree feeds none of it.
All panes share the same repo cwd, so any project-level skill dir is shared by every
agent — role scoping is advisory (via instructions), not enforceable by discovery path.

### Confirmed defects (audit evidence)

- **Phantom names in `settings.yaml`** — resolve to nothing:
  - explorer: `codemap`
  - librarian: `web-search`, `doc-fetch`
  - designer: `frontend-design`
  - fixer: `subagent-driven-development` (only exists as `superpowers:subagent-driven-development`, not bare)
- **Only shogun's two skills resolve**: `zoom-out`, `grill-with-docs` (global symlinks). ✅
- **oracle self-contradiction**: `settings.yaml` assigns oracle `grill-with-docs`, but
  `instructions/oracle.md:57-64` lists grill-class interactive skills as **Shogun-only,
  "Do NOT invoke under any circumstance."**
- **Stale "Available Skills" sections** in instructions claim role folders are empty when
  they aren't, e.g. `oracle.md:222` ("skills/oracle/ … currently empty") vs disk
  `skills/oracle/doubt-driven-development/`; same pattern in explorer.md, designer.md.
- `orchestrator/`, `observer/`, `council/` have on-disk skill folders but `settings.yaml`
  lists `skills: []` — folders never referenced anywhere.

## Recommended direction (Task 2 decides; this is the default)

**Wire what's real, delete what's phantom. No custom loader.**

1. Keep authored `skills/<role>/` content that is NOT redundant with a superpowers/global
   skill; make it invocable by symlinking into `.claude/skills/`.
2. Delete `skills/<role>/` folders that merely duplicate a superpowers/global skill
   (e.g. `fixer/test-driven-development` vs `superpowers:test-driven-development`,
   `fixer/debugging-and-error-recovery` vs `superpowers:systematic-debugging`).
3. Reconcile `config/settings.yaml roles.*.skills` to list ONLY resolvable names, or
   delete the field entirely (it's unread — deletion is the honest move unless Task 2
   chooses to add a loader). Fix the oracle contradiction.
4. Fix the stale "Available Skills" prose in `instructions/*.md` to match disk.

Building a launcher that reads `settings.yaml roles.*.skills` and per-pane scopes skills
is rejected as over-engineering: panes share cwd so per-pane scoping isn't achievable
without real plumbing, and the instructions layer already gates role usage.

## Status

- [x] Task 1: explorer — recon, classify every `skills/<role>/` SKILL.md keep-vs-redundant
- [x] Task 2: oracle — review recon + ratify direction (wire/delete/loader); Lord gate
- [x] Task 3: fixer — execute reconciliation (config + symlinks + deletions + instruction prose) — commit a8e2815
- [ ] Task 4: oracle — verify every declared skill resolves; no phantoms; docs match disk

## Task Details

### Task 1: explorer — recon, classify every skills/<role>/ SKILL.md keep-vs-redundant

Read every `skills/*/*/SKILL.md` (find them: `find skills -name SKILL.md`). For each,
produce a row: `path | one-line purpose | nearest superpowers/global equivalent (or NONE)
| verdict KEEP-AND-WIRE / DELETE-REDUNDANT`.

Also re-verify the audit defects before any change is dispatched:
- `grep -rn skills scripts/` → confirm 0 reads of the config field.
- `ls ~/.claude/skills .claude/skills 2>/dev/null` → confirm project `skills/` is not in a
  discovery path.
- For each name in `config/settings.yaml roles.*.skills`, check whether it resolves to an
  available skill (global symlink in `~/.claude/skills`, or a `plugin:name` in the session
  skill list). Mark each RESOLVES / PHANTOM.

Output a single markdown table to `reports/explorer_report.yaml` (or inline) — no edits
(explorer is read-only). Acceptance: every SKILL.md classified + every settings skill name
marked RESOLVES/PHANTOM, with the specific equivalent named for each DELETE-REDUNDANT.

### Task 2: oracle — review recon + ratify direction; Lord gate

Review Task 1's classification. Confirm or amend the recommended direction. Decide the
open question explicitly:
- **settings.yaml `skills:` field** — delete it (unread) OR keep + add a loader. Recommend
  delete unless there's a concrete consumer planned. State the call.
- **Deletion blast radius** — if Task 3 will delete >10 files (whole folders count),
  CLAUDE.md Tier-2 requires STOP-and-confirm. List the exact paths to delete so the Lord
  can approve in one shot.

Output: a short decision doc (KEEP list, DELETE list, settings.yaml verdict, oracle.md fix).
Acceptance: every Task-1 row has a ratified verdict; deletion path list is explicit; Lord
has approved the delete set (this is the `auto_continue: false` gate).

### Task 3: fixer — execute reconciliation

Per the ratified Task 2 decision:

1. **Wire KEEP skills**: symlink each kept `skills/<role>/<name>/` into `.claude/skills/`
   (create `.claude/skills/` if absent). Verify each becomes invocable as `/<name>`.
   Prefer symlink over copy so the authored source stays single-owner under `skills/`.
2. **Delete REDUNDANT folders** (only the approved set). Use `git rm` so history is clean.
   Respect Tier-2: if the set exceeds 10 files and Lord approval from Task 2 is missing,
   STOP and report.
3. **Reconcile `config/settings.yaml`**: remove every PHANTOM name. If Task 2 chose delete,
   strip the `skills:` field from all roles; if keep, set each role's `skills:` to only
   resolvable names. Fix oracle: remove `grill-with-docs` (it's Shogun-only per oracle.md)
   or, if Lord wants oracle to have it, remove the contradiction in `oracle.md` instead —
   one or the other, not both.
4. **Fix instruction prose**: in `instructions/*.md` "Available Skills" sections, correct
   every "currently empty" claim that disk contradicts; list the role's actually-wired
   skills. Touch oracle.md, explorer.md, designer.md at minimum.

Acceptance: `git diff --stat` shows config + instructions + `.claude/skills/` changes;
no PHANTOM name remains in `settings.yaml`; oracle contradiction resolved one way.

### Task 4: oracle — verify every declared skill resolves; no phantoms; docs match disk

Runtime verification (per CLAUDE.md U7 — wiring is not running until observed):
- For each role, every name now declared (config and/or instructions) resolves to an
  invocable skill. Prove it: list `.claude/skills/` entries and the session skill list;
  cross-check each declared name appears.
- `grep -rnE 'codemap|web-search|doc-fetch|frontend-design' config/settings.yaml` → 0 hits
  (the known phantoms are gone).
- Every "Available Skills" section in `instructions/*.md` matches `find skills -name SKILL.md`
  reality for that role.
- oracle no longer both-assigns-and-forbids `grill-with-docs`.

Acceptance: a PASS/FAIL line per check with evidence. Any FAIL → redo via fixer, do not
mark the plan done.

---

## Dispatch order

Task 1 → Task 2 (Lord gate) → Task 3 → Task 4. Task 2 is the hard stop:
nothing gets deleted or rewired until the direction and delete-set are Lord-approved.

skipped: a settings.yaml-reading launcher (over-engineering — panes share cwd, no per-pane
scoping payoff; instructions already gate role usage). Add it only if a real consumer
appears.
