---
title: Skill wiring gap closure — CLOSED (verified, no gaps remain)
auto_continue: true
---

_Authored 2026-06-27. Closure record for the skill-wiring gap line (rounds 1–3).
All substantive gaps are closed and empirically verified. This file exists so the
next reader sees the line is done and does not re-open it — and to carry the one
remaining housekeeping task (archive the round plans)._

## Verdict: CLOSED

There are **no remaining skill-wiring gaps**. The original audit found three
disjoint skill layers (dead `settings.yaml` config field, unreachable `skills/`
tree, and a false "loader searches skills/" claim in instructions). All resolved:

| Original gap | Resolution | Round / commit |
|---|---|---|
| Phantom skill names in `settings.yaml` (codemap, web-search, doc-fetch, frontend-design) | Stripped | R1 `a8e2815` |
| `skills/<role>/` tree implied invocable but unreachable | Direction set: reference-only docs, not a discovery path; dup-of-global dirs deleted | R1 `a8e2815` |
| oracle `grill-with-docs` assigned-and-forbidden contradiction | Resolved (FORBIDDEN direction, both sides) | R1 `a8e2815` + `2e1b472` |
| Stale `instructions/generated/*` (57 files) still claiming slash-loader / listing deleted skills | Regenerated from fixed sources | R2 `b9bcfe2` line / cmd_113 |
| Dead `roles.*.skills` config field + 18 files citing it | Field deleted, prose scrubbed, regenerated | R3 `ea2ab92` (cmd_114) |
| No guard against source→generated drift recurring | `build_instructions.sh --check` added + wired into `weekly_health_review.sh:209` | R3 `b9bcfe2` (cmd_115) |

## Verification evidence (2026-06-27, post round-3)

All run against the live tree:

- `grep -cn "skills:" config/settings.yaml` → **0** (field deleted)
- `grep -rl "roles\..*\.skills" instructions/*.md instructions/generated/` → **0**
- generated false-loader / deleted-skill refs / phantom names → **0 / 0 / 0**
- `bash scripts/build_instructions.sh --check` → **"✅ no drift", exit 0** (settles the cmd_113 revert/reapply churn — tree is provably in sync)
- drift guard invoked by `scripts/weekly_health_review.sh:209` (reuses an existing scheduler — no new cron)
- `ls ~/.claude/skills` → `grill-with-docs`, `diagnose`, `improve-codebase-architecture`, `zoom-out` all present (CLAUDE.md Rule #9 skills resolve globally)

Each round was gated by an independent oracle review returning PASS_FULL.

## Status

- [ ] Task 1: librarian — archive the rounds 1–3 plan files [P3, housekeeping]

## Task Details

### Task 1: librarian — archive the rounds 1–3 plan files [P3, housekeeping]

The gap line is closed; its plan files are still loose under `plans/` (untracked on
`main`). Move them into `plans/archive/` so auto_prompt stops scanning a finished
line, and commit.

- `git mv` (or `mv` + `git add`) these into `plans/archive/`:
  - `plans/2026-06-27-skill-wiring-gap-closure.md`
  - `plans/2026-06-27-skill-wiring-gap-closure-followups.md`
  - `plans/2026-06-27-skill-wiring-gap-closure-round3.md`
  - `plans/2026-06-27-skill-wiring-gap-closure-CLOSED.md` (this file)
- Commit: `docs(plans): archive closed skill-wiring gap line (rounds 1–3)`.

**Accept:** `ls plans/*.md` no longer lists the skill-wiring files; they exist under
`plans/archive/`; tree committed clean.

---

## Note for the next reviewer

If asked to "find skill-wiring gaps" again: there are none as of 2026-06-27. Re-run
the six verification commands above before authoring any new round — if they all
return the expected zeros and the drift guard exits 0, the correct output is "closed,
nothing to do," not a new task list. Do not manufacture work to fill a delegation
template.
