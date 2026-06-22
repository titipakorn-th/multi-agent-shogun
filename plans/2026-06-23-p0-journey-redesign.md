---
title: P0 Journey Redesign Implementation (cmd_037 §8.7)
auto_continue: true
---

# Plan: P0 Journey Redesign Implementation

## Status

- [x] Task 1: cmd_040 — Designer drafts §9 (P0 implementation spec with concrete wireframes + component-level changes for P0-01, P0-02, P0-03, P0-04)
- [x] Task 2: cmd_041 — Fixer implements P0-01 + P0-02 + P0-03 (frontend `/+page.svelte` §6.1 + §2.2 Step 4 — charge-ID contextual primary, plain-language truth_score, dispute auto-open + toast)
- [x] Task 3: cmd_042 — Fixer implements P0-04 (frontend `/admin` §3.1 DR failover pre-flight checklist + new `GET /admin/compliance/dr/preflight` backend endpoint)
- [x] Task 4: cmd_043 — Oracle 1/4 docs review + Observer E2E verification on dev sandbox
- [x] Task 5: cmd_044 — Commit + push, write end-of-phase status to `design.md §8.10 changelog`, mark plan complete

## Problem

cmd_037 produced a UX audit + journey redesign proposal with 16 items mapped to pain points, phased P0 (4 items, critical) / P1 (8, important) / P2 (4, defer beyond pilot). The proposal is docs-only — no implementation yet. P0 items block the next cmd cluster because they address:
- **P-03** (charge-ID contextual primary on `/`): first-impression confusion for buyers arriving via shared link
- **P-08** (truth_score plain-language): sellers misreading 0.87 as "I lost" — dispute-trust risk
- **P-07** (dispute panel auto-open + toast): sellers navigating away miss entry — dispute-trust risk
- **P-11** (DR failover pre-flight checklist): compliance-trust C-severity gap, MAS §7.1 SoD

Lord chose path (b) — draft this plan now so auto_prompt picks it up after cmd_038 + cmd_039 close, no Lord re-prompt needed.

## Design

### Scope

Per cmd_037 §8.8 (P0 = 4 items):

| # | Item | Surface | Pain | Dependency |
|---|------|---------|------|------------|
| P0-01 | Contextual charge-ID primary on `/` when `?charge_id` is present | `/` §6.1 | P-03 | Frontend-only |
| P0-02 | Plain-language truth_score interpretation on seller dispute panel | `/+page.svelte` §2.2 Step 4 | P-08 | Frontend-only (string lookup table) |
| P0-03 | Auto-open + toast on dispute landing | `/+page.svelte` §2.2 Step 4 | P-07 | Frontend-only (`onMount` hook) |
| P0-04 | DR failover pre-flight checklist | `/admin` §3.1 (cmd_032) | P-11 | Frontend + new `GET /admin/compliance/dr/preflight` endpoint |

**Optional bonus**: P-16 (5-stage escrow stepper pastel gradient → cmd_027 v2 tokens) is tagged P0 in §8.4 but not in §8.8's 4-item list. Flag for §9 to either consolidate into P0-01 implementation OR defer to P2 as polish.

### File territory (RACE-001 style)

- `design.md §9` (NEW additive section, doesn't touch §1–§8)
- `frontend/src/routes/+page.svelte` (P0-01/02/03)
- `frontend/src/routes/admin/+page.svelte` (P0-04 frontend)
- `backend/src/api/admin_compliance.rs` (P0-04 new endpoint)
- `tests/unit/*.bats` (P0-04 endpoint regression tests)

### Quality bar

- cmd_027 v2 calm trust-forward tokens (no new palette)
- Thai-first bilingual copy on every user-facing string
- WCAG 2.1 AA contrast (≥4.5:1)
- 44x44px touch targets; focus rings
- vite build clean; svelte-check 0 errors
- cargo test 100+/0/0 green; main.rs stable
- Oracle round 1/4 minimum

## Task Details

### Task 1: cmd_040 — Designer drafts §9 (P0 implementation spec)

Designer reads cmd_037 §8.5 (3 ASCII wireframes — Journey 1 charge-ID, Journey 2 dispute panel, Journey 3 DR failover) and produces concrete component-level implementation spec. File: `design.md §9` (NEW additive section). Cover P0-01, P0-02, P0-03, P0-04 with:
- Exact Svelte component tree changes
- Exact copy (Thai-first bilingual) for every new string
- Exact backend endpoint shape for P0-04 `GET /admin/compliance/dr/preflight` (response schema: `{ region_from, region_to, merchant_count, pending_transfers, last_failover_at, ready_to_promote: bool }`)
- §9.1: P0-01 charge-ID contextual primary
- §9.2: P0-02 truth_score lookup table (≥0.85 / 0.70–0.85 / 0.40–0.70 / <0.40 / AI_MEDIATOR_DOWN)
- §9.3: P0-03 dispute auto-open + toast (timer: 1.5s; toast: "คุณมีข้อพิพาทใหม่ / New dispute opened")
- §9.4: P0-04 DR failover pre-flight (5 fields + "Ready" green / "Not ready" red badge)
- §9.5: P-16 stepper gradient resolution (consolidate or defer)

Acceptance: §9 renders cleanly with all 4 P0 items specified; Oracle 1/4 docs review approves.

### Task 2: cmd_041 — Fixer implements P0-01 + P0-02 + P0-03

Single component tree on `/+page.svelte` — all 3 items touch §6.1 + §2.2 Step 4. Fixer ships in one cmd (file-isolated from P0-04 admin work).

P0-01 implementation:
- Add `?charge_id` URL param detection in `onMount`
- When present, replace the 3-card pathway toggle with a single "Pay Charge [ID]" primary CTA
- Secondary "Sell something else" link below for users who landed on wrong page

P0-02 implementation:
- New string lookup table `truthScoreToCopy(score: number, lang: 'th'|'en'): string`
- ≥0.85 → "คุณชนะข้อพิพาท / You won the dispute"
- 0.70–0.85 → "หลักฐานชัดเจน / Strong evidence"
- 0.40–0.70 → "ความเห็นเจ้าหน้าที่ / Officer review needed"
- <0.40 → "คุณแพ้ข้อพิพาท / You lost the dispute"
- AI_MEDIATOR_DOWN → "ระบบ AI ขัดข้อง กำลังส่งต่อเจ้าหน้าที่ / AI offline — escalating to officer"

P0-03 implementation:
- `onMount` hook on `/?charge_id=...&status=disputed` URL: auto-open counter-evidence panel after 1.5s
- Show toast for 4s: "คุณมีข้อพิพาทใหม่ / New dispute opened"

File territory: `frontend/src/routes/+page.svelte` only (or split into components if cleaner).

Acceptance: vite build clean, svelte-check 0 errors, no cargo test changes, cmd_034 §6 + cmd_035 §7 baselines preserved.

### Task 3: cmd_042 — Fixer implements P0-04

Two-file scope: backend endpoint + admin frontend wiring.

Backend: new `GET /admin/compliance/dr/preflight` in `backend/src/api/admin_compliance.rs`:
- Admin-key gated (existing `admin_key_middleware`)
- Reads: current region, opposite region, merchant count from ScyllaDB, pending transfers count from TigerBeetle read-only, last_failover_at from app_state.dr_promoted history
- Returns JSON `{ region_from, region_to, merchant_count, pending_transfers, last_failover_at, ready_to_promote }`
- 5 #[serial] regression tests covering: standby state, primary state, >0 pending transfers (not ready), 0 pending transfers (ready), admin_key missing (401)

Frontend: `/admin/+page.svelte` DR Failover Test button area:
- Pre-flight panel above the button: 5 fields + Ready/Not-ready badge
- Disabled button state when not ready (red badge with reason)
- Click "Run pre-flight" calls new endpoint, refreshes fields
- Existing cmd_032 dual-control first-approver pattern preserved

Acceptance: cargo test 100+/0/0 (5 new #[serial] tests), vite build clean, svelte-check 0 errors, main.rs +1 line.

### Task 4: cmd_043 — Oracle + Observer full review

Oracle 1/4 round review of cmd_041 + cmd_042 deliverables:
- Verify cmd_027 v2 tokens preserved (no new palette)
- Verify Thai-first bilingual copy on every new string
- Verify WCAG 2.1 AA contrast (≥4.5:1) on truth_score lookup table colors
- Verify P-16 stepper gradient resolved (consolidated or deferred)
- Verify file isolation (no cross-imports with cmd_038/cmd_039)

Observer E2E verification on dev sandbox:
- Smoke test P0-01: visit `/?charge_id=abc123` → see contextual primary
- Smoke test P0-02: trigger dispute with truth_score 0.87 → see "คุณชนะข้อพิพาท"
- Smoke test P0-03: visit disputed charge → panel auto-opens + toast appears
- Smoke test P0-04: hit `/admin` → pre-flight shows 5 fields + Ready badge when pending_transfers=0

Acceptance: Oracle verdict=approved, Observer verdict=passed, 0 critical/high/medium/low findings.

### Task 5: cmd_044 — Commit + push + changelog

- Commit P0 implementation work (cmd_041 + cmd_042 + Oracle validation)
- Push to origin/main
- Append `design.md §8.10 changelog` with P0 implementation summary + before/after screenshots (optional, ASCII only)
- Update `design_phase_1_plan.md §3.5` with P0-done row
- Write `docs/superpowers/specs/2026-06-23-p0-redesign-implementation.md` (Lord-facing spec doc, mirrors cmd_035 pattern)
- Mark all 5 tasks `[x]` in this plan
- Send strategic Telegram to Lord: "🏯 P0 complete. 4 critical UX gaps closed. SafePay is now P0-ready for pilot."

Acceptance: working tree clean, origin/main ahead of local, plan marked complete.

## Dependencies

- cmd_038 (format gap fix) must close before Task 2 starts (no file overlap, but sequential for clarity)
- cmd_039 (self-healing guard) must close before Task 1 starts (auto_prompt loop hygiene)
- cmd_037 (UX audit) — already closed; this plan implements its P0 subset

## Estimated Effort

- Task 1 (designer §9): ~30–45 min
- Task 2 (P0-01/02/03 frontend): ~45–60 min
- Task 3 (P0-04 backend + frontend): ~45–60 min
- Task 4 (Oracle + Observer): ~15–20 min
- Task 5 (commit + changelog): ~10 min
- Total: ~2.5–3.5 hours wall-clock

## Rollback

If Lord or Oracle finds P0-01/02/03/04 introduce regressions:
- Each implementation cmd (cmd_041, cmd_042) is independently revertible via `git revert <commit>`
- §9 spec is additive; reverting implementation leaves §9 intact for future retry
- Pre-deploy: SafePay is in pilot-pending state; rollback is a non-event (no production traffic)