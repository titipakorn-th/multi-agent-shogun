---
title: Phase 4 UX Audit — End-to-End User Simulation (cmd_055+)
status: design-spec
date: 2026-06-23
lord_approved: pending
---

# Phase 4 UX Audit — End-to-End User Simulation

## Background

SafePay Thailand is **feature-complete-for-pilot** as of 2026-06-23:
- Phase 1 (cmd_003-006) ✅ — Axum + SvelteKit + TB wiring
- Phase 1.5 (cmd_005/013/028/031) ✅ — seller loop + payout + analytics
- Phase 2 (cmd_032) ✅ — admin compliance UI/UX
- Phase 3 (cmd_021-026) ✅ — MAS-TRM compliance, B2B dual-control, DR warm-standby
- Phase 4 marketplace-ready (cmd_034) ✅ — wanted posts + 2-sided flow
- Onboarding (cmd_035) ✅ — 5-step mandatory educational
- Auto-prompt (cmd_036/039/053) ✅ — daemon + self-heal
- UX Audit + redesign (cmd_037+cmd_040/041/042/044) ✅ — P0 journey redesign
- P1+P2 polish (cmd_046a/b/c/047-052) ✅ — 12 items, 4 NEW components

**Lord directive**: "Phase 4 = post-marketplace production hardening, focus on what's done if it's not oversimplified." Lord selected:
1. **Scope**: End-to-end user simulation (4 buyer + 4 seller + 2 admin + 1 B2B = 11 journeys)
2. **Delivery**: Automated Playwright + screenshots + HTML report
3. **Suite location**: `frontend/e2e/` (SafePay project)
4. **State isolation**: Per-journey backend reset
5. **Externals**: Mock truth_score + AOC + NDID (deterministic)
6. **Report**: HTML with embedded screenshots

## Problem

cmd_037 surfaced 16 pain points and 28 trust signals based on spec review.
cmd_044 shipped P0 + cmd_052 shipped P1+P2 design + implementation.
**No automated proof exists** that the shipped code actually walks the journeys
cmd_037 promised — only Oracle's spec-vs-spec review. Lord wants observable,
reproducible evidence that SafePay actually delivers the promised UX.

## Design

### Suite location

`/Users/prince/SafePay/project/frontend/e2e/` — NEW sibling dir to `src/`,
`package.json`-root co-located with Playwright runner, no impact on app build.

### File territory

```
frontend/e2e/
├── playwright.config.ts        # chromium headless, mobile + desktop viewports
├── journeys/
│   ├── buyer/
│   │   ├── 01_first_time_purchase.spec.ts       # P-α first-time
│   │   ├── 02_returning_purchase_charge_id.spec.ts # P-β returning with charge-ID
│   │   ├── 03_counter_evidence.spec.ts          # counter-evidence file
│   │   └── 04_dispute_open.spec.ts              # dispute-open toast (cmd_044 P0-03)
│   ├── seller/
│   │   ├── 05_first_time_listing.spec.ts        # P-γ first-time
│   │   ├── 06_returning_withdrawal.spec.ts      # P-δ returning + analytics
│   │   ├── 07_register_shipment.spec.ts         # register_tracking
│   │   └── 08_confirm_delivery.spec.ts          # delivery_confirm + release
│   ├── admin/
│   │   ├── 09_audit_report_review.spec.ts       # audit-report + graceful degradation
│   │   └── 10_dr_preflight_failover.spec.ts     # DR pre-flight + dry-run failover
│   └── b2b/
│       └── 11_dual_control_escalation.spec.ts   # one approver → second-approver preview modal
├── helpers/
│   ├── setup.ts               # backend reset, mock seed
│   ├── assertions.ts          # Thai-first bilingual, WCAG, trust signals
│   └── personas.ts            # P-α / P-β / P-γ / P-δ / P-ε / P-ζ fixtures
├── reports/                   # gitignored, generated output
│   ├── index.html
│   └── screenshots/<journey>_<NN>_<state>.png
└── package.json               # NEW sibling to root (Playwright only)
```

**No backend modifications.** **No frontend source modifications.**
**Read-only against shipped code.** Suite is a pure black-box test consumer.

### State management

**Per-journey backend reset**:
- Pre-suite: docker-compose up (Counterpart simulator + TB + ScyllaDB + Redpanda + Axum)
- Per-spec: `POST /api-sandbox/reset` (or equivalent) at suite start; idempotent reset to known seed state
- Per-spec: `setup.ts` mocks AI Mediator truth_score via test-only env vars
- Per-spec: mocks AOC screening (always-pass) + NDID e-KYC (always-pass T1)
- Post-spec: cleanup `tmp/charge_*` artifacts; keep backend warm for next spec

**Why per-journey reset**: each journey must be hermetic. P-α onboarding must
start with no localStorage flag; P-β returning must start with charge-id
already created in step N. Cross-spec state leaks = false-positive failures.

### Mocked externals (deterministic)

- **AI Mediator** truth_score → env var `E2E_TRUTH_SCORE=0.85` per spec
- **AOC screening** → env var `E2E_AOC_RESULT=clear` per spec
- **NDID e-KYC** → env var `E2E_NDID_RESULT=tier1` per spec
- **Counterpart simulator** → REAL (logistics + bank + AMLO)
- **TigerBeetle** → REAL (full ledger semantics)
- **ScyllaDB** → REAL (full persistence)

Why this mix: Counterpart simulator + TB + ScyllaDB are deterministic-enough
under test seeding. AI Mediator + AOC + NDID are external 3rd-party calls
where nondeterminism would cause flake — mock these for reproducible runs.

### The 11 journeys

#### Buyer (4)

1. **`01_first_time_purchase`** (P-α first-time buyer — cmd_037 §8.3)
   - Pre: no localStorage['safepay.onboarded']
   - Steps: `/` → redirect `/onboarding` → 5-step carousel → `/dashboard` → click "Sell/Buy/Charge-ID" → "Buy have-charge-id" → enter charge-ID → `/charges/:id/pay` → mock QR scan → SLA countdown (P1-05) → release
   - Assertions: onboarding 5 steps with Thai-first bilingual; sell/buy/charge-id cards visible; SLA countdown renders "ปล่อยอัตโนมัติใน ..." with 2 CTAs (P1-05); trust score Tier 1 badge; TRUTH-SCORE gauge with 5-band copy (cmd_044 P0-02)
   - Screenshots: 8 PNGs at key states

2. **`02_returning_purchase_charge_id`** (P-β returning buyer)
   - Pre: localStorage['safepay.onboarded']='true'; 1 prior charge_id in test seed
   - Steps: `/` → straight to `/dashboard` (onboarding skipped) → "Buy have-charge-id" → paste charge-ID → pay → confirm
   - Assertions: onboarding redirect NOT triggered; charge-ID shortcut renders (cmd_044 P0-01)
   - Screenshots: 4 PNGs

3. **`03_counter_evidence`** (P-β returning — counter-evidence file)
   - Pre: charge in `disputed` status; buyer TruthScore = 0.30 (mock)
   - Steps: `/dashboard` → `/charges/:id` (disputed) → counter-evidence panel inline help (P1-04 Thailand Post format) → file upload → operator sign-off
   - Assertions: counter-evidence panel renders with Thai Post format help (P-07); seller-only DOM (cmd_027 v2 §5); truth_score gauge 240° arc visible (cmd_031 PART D)
   - Screenshots: 5 PNGs

4. **`04_dispute_open`** (P-β returning — dispute auto-open)
   - Pre: charge status HELD; weight delta >5% triggered
   - Steps: `/dashboard` → receive state_changed webhook → onMount + 1.5s + 4s toast (cmd_044 P0-03) → click toast → `/dispute_center`
   - Assertions: dispute auto-open toast appears at 1.5s; persists 4s with action button; truthScoreToCopy() 5-band copy renders (cmd_044 P0-02)
   - Screenshots: 4 PNGs

#### Seller (4)

5. **`05_first_time_listing`** (P-γ first-time seller)
   - Pre: no localStorage['safepay.onboarded']
   - Steps: `/onboarding` 5 steps → `/dashboard` → click "Sell/Buy/Charge-ID" → "Sell" → manual entry (§6.2) → paste-URL+photo_url (§6.3) → submit
   - Assertions: 3 landing cards (Sell/Buy/Have Charge ID) at top of /+page.svelte; manual entry form validates (item_name required, amount ≥ ฿1); paste-URL max 2048 chars; PDPA §28 jurisdiction badge in footer (P1-07 cmd_048)
   - Screenshots: 7 PNGs

6. **`06_returning_withdrawal`** (P-δ returning merchant)
   - Pre: KYC Tier 2 verified; transferable balance = ฿5,000
   - Steps: `/dashboard` → withdrawal flow → 3-tier card (transferable/escrow_pending/pending_withdraw) → click "Withdraw" → confirmation sheet → submit → Simulate Bank Processing helper → success-flash
   - Assertions: 3-tier balance card with distinct typography (cmd_031 PART B); confirmation sheet shows BBL Sponsor Bank custody + PDPA custodian + gross+fees+net (cmd_027 v2); payout pill lifecycle pending→sent→paid; failure-UX banner if bank returns error
   - Screenshots: 6 PNGs

7. **`07_register_shipment`** (P-δ — register_tracking)
   - Pre: charge status HELD with seller as current actor
   - Steps: `/charges/:id` → "Register Shipment" → modal → tracking_number + carrier → submit
   - Assertions: register_tracking endpoint hits `/charges/:id/register_tracking` (api/charges.rs:379); Held stage advances to Shipped on success; 5-stage stepper reflects state
   - Screenshots: 4 PNGs

8. **`08_confirm_delivery`** (P-δ — delivery_confirm + release)
   - Pre: charge status SHIPPED with tracking_number
   - Steps: `/charges/:id` → "Confirm Delivery" → modal → confirm → release_escrow flow
   - Assertions: delivery_confirm endpoint (api/charges.rs:423) triggers TigerBeetle ledger split; release endpoint (api/charges.rs:622) advances to Settled; 3-way disbursement receipt renders (merchant net + platform fee + WHT + total)
   - Screenshots: 5 PNGs

#### Admin (2)

9. **`09_audit_report_review`** (P-ζ admin)
   - Pre: backend UP; one TB account rate-limited (degraded mode)
   - Steps: `/admin` → audit-report section → 4 sections render → trigger TB-down → graceful degradation
   - Assertions: 4 sections (system_security / ledger_integrity / admin_actions / str_reports) render with per-section as_of + top-level degraded flag; never 5xx (cmd_022 graceful degradation); per-section try-block survives TB failure
   - Screenshots: 6 PNGs

10. **`10_dr_preflight_failover`** (P-ζ admin)
    - Pre: dr_promoted=false; pending_transfers=0
    - Steps: `/admin` → DR Failover pre-flight panel → 4 fields (region_from/region_to/platform_mode/merchant_count/pending_transfers/last_failover_at/ready_to_promote) → click "Promote Singapore" → confirmation dialog (audit reason ≥10 chars) → dry-run
    - Assertions: pre-flight panel renders 4 fields + Ready badge when pending_transfers=0; DR Failover button DISABLED with aria-describedby gate-help when !ready_to_promote (cmd_044 P0-04); confirmation dialog requires audit reason ≥10 chars; PDPA §28 sign-offs required copy if not all obtained
    - Screenshots: 5 PNGs

#### B2B (1)

11. **`11_dual_control_escalation`** (P-ε B2B operator)
    - Pre: 1 dispute with truth_score=0.88 (≥0.85 → ESCALATE_FOR_DUAL_CONTROL); actor=admin_1
    - Steps: `/admin` → B2B Disputes Dual-Control Review → list filter shows ESCALATE_FOR_DUAL_CONTROL disputes → click dispute → AuditLogModal renders (P1-08 cmd_049) showing actor/action/timestamp/second-approver → click "Approve Refund" as admin_1 → status changes to ESCALATED (first-approver locked) → re-login as admin_2 → click "Approve Refund" → status → AUTO_REFUNDED
    - Assertions: AuditLogModal a11y (ESC/click-outside/aria-modal/focus first-focusable/tabindex=-1) per cmd_049; cmd_025c dual-control first-approver tracking prevents same-operator guard; truth_score components visible (cmd_049 P1-08); Thai-first bilingual all strings
    - Screenshots: 7 PNGs

### Per-journey YAML contract

Each journey ships with a co-located YAML declaring preconditions + assertions
+ screenshots. Playwright reads it for setup + teardown; humans read it for
review. Format:

```yaml
journey: buyer_first_time_purchase
persona: P-α first-time buyer (cmd_037 §8.3)
cmd037_pain_points_verified:
  - P-01 onboarding skip-tour placement
  - P-06 trust_score delta chart
  - P-09 SLA auto-release countdown
cmd037_trust_signals_verified:
  - TRUST-Tier1-badge
  - 5-band truth_score copy
preconditions:
  - no_localStorage_onboarded
  - no_existing_charges
steps:
  - navigate("/")
  - assert_onboarding_redirect
  - screenshot(01_onboarding_step1.png)
  - ...
assertions:
  - "Trust score Tier 1 badge visible on completion"
  - "SLA countdown renders 2 CTAs (P1-05)"
screenshots:
  - 01_onboarding_step1.png
  - 02_onboarding_step2_kyc.png
  - ...
regresses_if:
  - "P-01 onboarding skip-tour placement broken"
  - "Truth score gauge fails to render"
```

### Report format

Playwright HTML reporter with embedded screenshots, click-through per journey.
Standard `@playwright/test`'s built-in HTML reporter — no extra deps.

Report path: `frontend/e2e/reports/index.html` (gitignored, generated).
Screenshots: `frontend/e2e/reports/screenshots/<journey>_<NN>_<state>.png` (gitignored, retained 7 days).

### Quality bar

- 11/11 Playwright specs green on first run
- Total runtime < 15 min (parallel: 4 buyer parallel + 4 seller parallel + 2 admin parallel + 1 B2B = max 4 concurrent, total ~14 min worst case)
- HTML report generated, links to screenshot artifacts
- 0 false-positive failures (mock-deterministic seeds)
- Oracle round 1/4 verdict=approved on the spec
- Observer round 1/4 verdict=approved on the suite

### Estimated effort

- Task 1 (designer 11 journeys): ~3-4 hours
- Task 3 (observer Playwright suite): ~4-6 hours
- Task 5 (fixer gap fixes): ~1-3 hours (TBD based on findings)
- Total: **~10-15 hours wall-clock** = 1-2 working days

### Rollback

- Suite is in `frontend/e2e/` (NEW dir, no existing files touched)
- `package.json` root: NO change (Playwright already installed at ^1.61.0 per cmd_004d)
- `frontend/e2e/package.json` is NEW sibling — no impact on root install
- Zero risk to production path. Suite is purely additive.

## Plan Outline

7-task plan following the established P0/P1+P2 pattern (Designer → Oracle → Observer → Fixer → Observer → Commit):

1. **cmd_055 (designer)**: draft 11 journey YAMLs (preconditions, steps, assertions, screenshots, pain points verified, trust signals verified). ~3-4 hours.
2. **cmd_056 (oracle round 1/4)**: docs/spec review. Verifies cmd_037 §8.4 pain points coverage + cmd_037 §8.6 trust signals coverage + file territory + plan alignment.
3. **cmd_057 (observer)**: build Playwright suite per journey YAMLs. 11 spec files + 1 config + 3 helpers + per-journey YAML + `scripts/run_e2e.sh` + minimal `/api-sandbox/reset` test endpoint (if not exists; test-only, gated by `E2E_RESET_ENABLED=true` env var). ~4-6 hours.
4. **cmd_058 (oracle round 1/4)**: suite review. Verifies file territory honored, mock externals wired, per-journey reset pattern works, HTML report renders.
5. **cmd_059 (fixer, conditional)**: gap fixes. TBD based on first suite run. **Skip if 11/11 green on first run.** Estimated ~1-3 hours if invoked.
6. **cmd_060 (observer)**: re-run suite (3× for stability check), verify all 11 green × 3 runs, generate HTML report + screenshot artifacts, write summary to dashboard.md.
7. **cmd_061 (fixer)**: commit suite + spec + dashboard.md update + strategic Telegram to Lord.

### Dependencies

- cmd_054 (auth_middleware direct-curl 401 fix) — INDEPENDENT. Playwright uses frontend proxy; admin paths go through proxy with both Basic + Admin-Key headers, no direct-curl needed.
- cmd_035 onboarding — already shipped, journeys 1+5 depend on this code being live
- cmd_044 P0 journey redesign — already shipped, journeys 1+4+10 depend on this code
- cmd_052 P1+P2 polish — already shipped, journeys 1+5+11 depend on this code

### Out of Phase 4.0 scope

- **CI integration**: deferred. Phase 4.0 ships manual-trigger script `scripts/run_e2e.sh`. CI hookup is a future cmd.
- **Performance regression suite**: deferred. Phase 4.0 ships functional E2E only. Lighthouse / k6 performance = future phase.
- **Cross-browser testing**: deferred to chromium-only in Phase 4.0. Safari + Firefox = future.
- **Visual regression**: deferred. HTML report shows current state; pixel-diff regression = future.
- **Accessibility automated audit (axe)**: deferred. Phase 4.0 ships manual WCAG checks via assertions.ts. axe-core integration = future.

## File Territory (cumulative, RACE-001 style — non-overlapping)

- `docs/superpowers/specs/2026-06-23-phase4-ux-audit.md` (NEW, this file)
- `plans/2026-06-23-phase4-ux-audit.md` (NEW, written by writing-plans skill)
- `frontend/e2e/` (NEW directory + all subdirs)
- `scripts/run_e2e.sh` (NEW, manual-trigger runner)
- `dashboard.md` (UPDATE: Phase 4 audit section appended)
- **No backend modifications. No frontend source modifications.**

## Acceptance Criteria

1. Spec written + committed (this file)
2. Plan written + committed (via writing-plans skill after Lord approval)
3. 11 journey YAMLs ship
4. Playwright suite runs 11/11 green on first attempt
5. HTML report generated with screenshots
6. 0 false-positive failures across 3 consecutive runs (stability check)
7. cmd_054 in flight state: doesn't block Phase 4 (Playwright uses proxy path)
8. cmd_055 cmd_056 cmd_057 cmd_058 cmd_059 cmd_060 cmd_061 all closed cleanly
9. Lord-facing Telegram with report link delivered

## Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| AI Mediator truth_score flakiness | Med | High | Mock via env var |
| Per-journey reset endpoint doesn't exist | Low | Med | cmd_057 implements minimal `/api-sandbox/reset` test-only endpoint, gated by `E2E_RESET_ENABLED=true` env var (refuses to run in production) |
| Counterpart simulator flakiness | Low | Med | Use real simulator; add 3-strike retry in setup |
| Onboarding localStorage state leaks | Med | High | Force localStorage clear in setup before each spec |
| Thai font rendering differs headless vs headed | Low | Low | Playwright config sets `locale: 'th-TH'` + use system Thai fonts (`Noto Sans Thai`, `IBM Plex Sans Thai`) — install via `playwright install --with-deps` if missing |
| Playwright version drift | Low | Low | Pin `^1.61.0` per cmd_004d precedent |

## Sign-off

- Designer (cmd_055): pending
- Oracle (cmd_056): pending
- Observer (cmd_057): pending
- Lord approval: pending