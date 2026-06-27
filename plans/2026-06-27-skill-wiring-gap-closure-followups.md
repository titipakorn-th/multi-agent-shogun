---
title: Skill wiring gap closure — round 2 (regenerate stale artifacts + verify)
auto_continue: true
---

_Authored 2026-06-27 after re-audit of commits `a8e2815` + `2e1b472`. Round 1
(Option A) fixed the **source** layer correctly — phantom config names stripped,
7 dup skill dirs deleted, oracle contradiction resolved, and every
`instructions/*.md` source now states the honest fact: "skills/ tree is reference
documentation, not a discovery path." But the fix stopped at the source. The live
artifact agents load — `instructions/generated/*`, produced by
`scripts/build_instructions.sh` — was never regenerated. It is stale and still
tells specialists that `skills/` folders are `/slash`-invocable, and still lists
deleted skills + stripped phantom names._

This is the U7 / cmd_108 "wiring is not running" failure: the source is right, the
artifact the running system reads is wrong. Done = the generated prompts agents
actually load match the fixed sources, observed — not a green source diff.

## Re-audit evidence (2026-06-27)

- **Direction confirmed by round 1**: `skills/` is reference-only, NOT a discovery
  path. Source `instructions/fixer.md` now reads: *"Skills resolve from
  `~/.claude/skills/` (global symlinks) + plugins … The project's `skills/` tree is
  reference documentation, not a discovery path."* No symlink wiring is wanted.
- **`grep -rln "loader searches\|slash-command mechanism" instructions/*.md`** → 0
  source files (fixed). **Same grep over `instructions/generated/`** → **57 files**
  still carry the false-loader claim.
- **8 generated `*-fixer.md` files** still list deleted skills
  (`skills/fixer/test-driven-development`, `code-simplification`,
  `debugging-and-error-recovery`) and the self-contradictory "currently empty for
  this role" bullet.
- **explorer/librarian generated files** still carry stripped phantom names
  (`codemap`, `web-search`, `doc-fetch`); designer generated likely carries
  `frontend-design`.
- **`config/settings.yaml roles.*.skills`** still read by zero scripts
  (`grep -rn skills scripts/` = 0 functional hits). shogun=`zoom-out`, rest=`[]`.
  Decorative; `zoom-out` "works" only because it is a global symlink, not because
  the field does anything.

## Status

- [x] Task 1: fixer — regenerate `instructions/generated/*` from fixed sources [P0] — DONE @ 18:52 (commit 8059f23 on branch cmd_113_regen_generated_instructions)
- [x] Task 2: oracle — full verification gate (artifact == source == disk) [P1] — DONE @ 18:55 (PASS_FULL, 3 grep checks=0, reversibility clean)
- [ ] Task 3: fixer — settle the dead `settings.yaml skills:` field [P2]
- [ ] Task 4: fixer — add a source→generated drift guard so this can't recur [P2]

## Task Details

### Task 1: fixer — regenerate instructions/generated/* from fixed sources [P0]

The sources are correct; the generated artifacts are stale. Regenerate them.

1. Run `bash scripts/build_instructions.sh` (it discovers roles from
   `config/settings.yaml` and renders per-role × per-CLI variants, plus
   `.opencode/agents/*.md`). Read the script's own `--check`/dry-run flag first if
   present (CHANGELOG notes it "checks generated instruction files together") and
   prefer a check→apply flow.
2. Confirm the regenerated output picked up the round-1 source fixes:
   - false-loader claim gone, replaced by the "reference documentation, not a
     discovery path" wording from the sources.
   - deleted fixer skills no longer listed; no "currently empty" contradiction.
   - no phantom names (`codemap`/`web-search`/`doc-fetch`/`frontend-design`).
3. If `build_instructions.sh` does NOT propagate the Available-Skills prose (i.e.
   that block is hand-maintained per generated file rather than rendered from
   source), STOP and report — that means the generator can't fix it and Task 1
   becomes a per-file edit; escalate the scope change before mass-editing 57 files
   (Tier-2 awareness: >10 files).
4. Commit the regenerated artifacts on a branch.

**Accept (runtime, not source):**
`grep -rl "loader searches" instructions/generated/` → 0;
`grep -rlE "skills/fixer/(test-driven-development|code-simplification|debugging-and-error-recovery)" instructions/generated/` → 0;
`grep -rlE "codemap|web-search|doc-fetch|frontend-design" instructions/generated/` → 0.

### Task 2: oracle — full verification gate (artifact == source == disk) [P1]

This is the round-1 Task 4 plus the round-2 artifact checks. PASS/FAIL line per
check, with the command output as evidence (U7: observed runtime state).

- `grep -rl "loader searches\|slash-command mechanism" instructions/generated/` → 0
- `grep -rlE "skills/fixer/(test-driven-development|code-simplification|debugging-and-error-recovery)|skills/shogun/(diagnose|grill-with-docs|zoom-out|improve-codebase-architecture)" instructions/generated/` → 0
- `grep -rlE "codemap|web-search|doc-fetch|frontend-design" instructions/generated/ config/settings.yaml` → 0
- For each role, the generated "Available Skills" block matches `find skills/<role> -name SKILL.md` on disk (no listed-but-deleted, no on-disk-but-unlisted).
- oracle generated files do not both assign and forbid `grill-with-docs`.
- CLAUDE.md Shogun Rule #9 names `grill-with-docs`/`diagnose`/`improve-codebase-architecture`/`zoom-out`: confirm each still resolves via `~/.claude/skills/` (their local `skills/shogun/` dirs were deleted in round 1 but the global symlinks remain). `ls ~/.claude/skills` → all four present.

Any FAIL → bounce to fixer; do not check the plan done.

### Task 3: fixer — settle the dead settings.yaml skills: field [P2]

`config/settings.yaml roles.*.skills` is read by no script. Two honest options —
pick and apply (recommend A):

- **A (recommended): delete the field** from every role. It does nothing; leaving
  it invites the next reader to believe it's wired. shogun's `zoom-out` keeps
  working (it's a global skill, independent of this field). Update any prose that
  references "skills listed under `roles.<role>.skills`".
- **B: wire it** — make `build_instructions.sh` render each role's `skills:` into
  that role's generated Available-Skills block. Only do this if there's a real
  reason to drive skill docs from config rather than the source prose.

First verify which is true today: `grep -n "skills" scripts/build_instructions.sh`
and read around any hit to confirm the field is genuinely unused. If A, also remove
the now-stale "If a skill is listed under `roles.<role>.skills`…" sentences that
round 1 left in some source instructions, then re-run Task 1's regen.

**Accept:** either the field is gone everywhere (A) or `build_instructions.sh`
provably consumes it and the generated docs reflect it (B); no role's instructions
reference a config field that does nothing.

### Task 4: fixer — add a source→generated drift guard [P2]

Round 1 fixed sources and forgot to regenerate; nothing caught it. Close the loop
so it can't recur silently.

- Add a `--check` path (or reuse the existing one) to `scripts/build_instructions.sh`
  that regenerates to a temp dir and `diff`s against the committed
  `instructions/generated/*`, exiting non-zero on drift.
- Wire that check into the existing `scripts/weekly_health_review.sh` (it already
  runs periodic audits) OR a pre-commit hook — whichever the team already uses.
  Do not invent a new scheduler; reuse what runs.
- **Accept (U7 — wiring is not running):** demonstrate the guard fires — make a
  trivial source edit, run the check, show it exits non-zero; regenerate, show it
  exits zero. Paste both runs.

---

## Dispatch order & priority

P0 Task 1 first — it's the live-artifact fix; until it lands, every specialist
loads a prompt that lies about skill invocation. P1 Task 2 gates it. P2 Tasks 3–4
are cleanup + recurrence-prevention and can follow once the artifact is correct.

skipped: symlink-wiring `skills/` into a discovery path — round 1 deliberately chose
reference-only docs, so there's nothing to wire. A settings-driven skill loader
(Task 3 option B) is over-engineering unless a concrete consumer appears; default
to deleting the dead field.
