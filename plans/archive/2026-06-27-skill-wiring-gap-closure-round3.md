---
title: Skill wiring gap closure — round 3 (kill the dead config field + drift guard)
auto_continue: true
---

_Authored 2026-06-27 after re-audit of the round-2 follow-ups. Rounds 1–2 fixed
the source honesty and regenerated the live `instructions/generated/*` artifacts —
those checks now pass clean (false-loader 0, deleted-skill refs 0, phantom names 0,
verified by oracle PASS_FULL). What remains are the two P2 items the round-2 plan
listed but that were **not** executed, plus their fallout._

Honest status: round-2 Tasks 1–2 are done and verified. Round-2 Tasks 3–4 were
left open — this round carries them to completion and adds the regen + verification
they imply.

## Re-audit evidence (2026-06-27, post round-2)

- **Generated artifacts clean** ✅:
  `grep -rl "loader searches\|slash-command mechanism" instructions/generated/` = 0;
  deleted-fixer-skill refs = 0; `codemap|web-search|doc-fetch|frontend-design` = 0.
- **Dead config field still live** ❌: `config/settings.yaml` still declares
  `roles.<role>.skills` on all 9 roles (shogun=`zoom-out`, rest=`[]`).
  `grep -rn skills scripts/` = 0 functional reads — no launcher, hook, generator,
  or depart step consumes it. `zoom-out` "works" only as a global symlink,
  independent of this field.
- **Source prose still cites the dead field** ❌: `instructions/explorer.md:96`
  ("If a skill is listed under `roles.explorer.skills` … you may invoke it") and
  `instructions/librarian.md:79` ("If skills are listed under
  `roles.librarian.skills` … invoke those"). Both point at a field that does nothing.
- **That prose leaked into 16 generated files** ❌:
  `grep -rl "roles\..*\.skills" instructions/generated/` = 16. Specialists load
  prompts telling them to consult a config field that is never read.
- **No drift guard** ❌: `build_instructions.sh` has no `--check`/dry-diff path;
  nothing in `weekly_health_review.sh` or git hooks compares committed generated
  output against a fresh render. The round-2 failure (source fixed, artifact stale)
  remains structurally possible.
- **cmd_113 history churn** ⚠️: merge `9123b47` was reverted (`4e18893`) then
  reapplied; net greps pass, but "generated is in sync with current sources" has
  never been mechanically proven — exactly what the drift guard would establish.

## Status

- [x] Task 1: fixer — delete dead `settings.yaml skills:` field + scrub source prose + regenerate [P1] — DONE @ 20:56 (commit d2187f3 + merge ea2ab92, oracle PASS_FULL)
- [x] Task 2: fixer — add a source→generated drift guard and wire it into what already runs [P2] — DONE @ 21:19 (commit 4705987 + merge b9bcfe2, oracle PASS_FULL)
- [x] Task 3: oracle — final verification gate (field gone, prose gone, guard fires, in-sync) [P1] — DONE @ 21:25 (section_cmd_115_oracle_review, PASS_FULL)

## Task Details

### Task 1: fixer — delete dead settings.yaml skills: field + scrub prose + regenerate [P1]

Round 2 chose Option A (delete the unread field) but it was never applied. Apply it.

1. **Confirm unused first**: `grep -n "skills" scripts/build_instructions.sh` and read
   around any hit. The Available-Skills block is rendered from source prose, not from
   `roles.*.skills` — confirm that holds. If anything actually consumes the field,
   STOP and report (the delete premise is wrong) before editing.
2. **Delete the field** from every role in `config/settings.yaml` (all 9
   `skills:` lines). shogun's `zoom-out` keeps working via the global symlink.
3. **Scrub the source prose** that references it:
   - `instructions/explorer.md:96` — remove the "If a skill is listed under
     `roles.explorer.skills` …" sentence.
   - `instructions/librarian.md:79` — remove the "If skills are listed under
     `roles.librarian.skills` …" sentence.
   - Sweep the rest: `grep -rn "roles\..*\.skills" instructions/*.md` → 0 after.
4. **Regenerate** `instructions/generated/*` (`bash scripts/build_instructions.sh`)
   so the 16 leaked files drop the dead-field prose. Commit on a branch.

**Accept (runtime):**
`grep -n "skills:" config/settings.yaml` → 0;
`grep -rn "roles\..*\.skills" instructions/*.md` → 0;
`grep -rl "roles\..*\.skills" instructions/generated/` → 0.

### Task 2: fixer — add a source→generated drift guard [P2]

Close the loop that let rounds 1→2 ship a stale artifact silently.

1. Add a `--check` mode to `scripts/build_instructions.sh`: render to a temp dir,
   `diff` against the committed `instructions/generated/*` (and `.opencode/agents/*`
   if it generates those), exit non-zero on any drift. Reuse the existing
   line-ending normalization (script line ~39) so diffs aren't false positives.
2. Wire `build_instructions.sh --check` into something that already runs — prefer
   `scripts/weekly_health_review.sh` (it already does periodic audits) or a
   pre-commit hook if the repo uses one. Do NOT add a new scheduler/cron.
3. Run `--check` now against the current tree to settle the cmd_113 churn question:
   it must exit zero (generated already in sync). If it exits non-zero, regenerate
   and commit, then report what was out of sync.

**Accept (U7 — wiring is not running):** paste two runs — (a) trivial source edit →
`--check` exits non-zero; (b) regenerate → `--check` exits zero. Plus the current-tree
run from step 3 showing zero drift.

### Task 3: oracle — final verification gate [P1]

PASS/FAIL line per check with command output (U7: observed state, not source diff).

- `grep -n "skills:" config/settings.yaml` → 0 (field deleted)
- `grep -rn "roles\..*\.skills" instructions/*.md instructions/generated/` → 0 (no dangling refs anywhere)
- Round-2 invariants still hold: false-loader 0, deleted-skill refs 0,
  `codemap|web-search|doc-fetch|frontend-design` 0 across `instructions/generated/`.
- Drift guard exists and fires: `build_instructions.sh --check` present, exits
  non-zero on injected drift, zero on clean tree, and is invoked by
  `weekly_health_review.sh` (or the chosen hook).
- shogun skills named in CLAUDE.md Rule #9 still resolve:
  `ls ~/.claude/skills` shows `grill-with-docs`, `diagnose`,
  `improve-codebase-architecture`, `zoom-out`.

Any FAIL → bounce to fixer; do not check the plan done. On full PASS, this closes
the skill-wiring gap line — archive rounds 1–3 plans.

---

## Dispatch order & priority

Task 1 (P1) first — it removes the last live lie (16 prompts pointing at a dead
field). Task 2 (P2) prevents recurrence and settles the churn question. Task 3 (P1)
is the closing gate. After PASS, there are no known skill-wiring gaps left; this
plan line can be archived.

skipped: nothing new — the reference-only direction (round 1) and clean generated
artifacts (round 2) stand. This round is deletion + a guard, not new mechanism.
