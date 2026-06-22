# Onboarding Design Spec — SafePay

**Date:** 2026-06-22
**Scope:** cmd_035 (single surface: first-time user onboarding)
**Status:** Approved by Lord
**Project:** safepay

## Background

SafePay has shipped cmd_027 v2 (calm trust-forward visual system), cmd_030/031/032
(Phase 1.5 seller loop + Phase 2 admin wiring), and cmd_034 (§6 transaction-initiation
in flight). Existing routes `/`, `/dashboard`, `/admin` are functional but assume
returning users. There is no first-time user experience.

## Goal

First-time visitors complete a 5-step mandatory educational onboarding that establishes
mental model and trust, then land on the main app ready to use SafePay.

## Non-Goals

- No real money movement during onboarding.
- No actual KYC submission (deferred to first payout / first sell).
- No real bank linking (deferred to first payout).
- No recipient_id creation (assumed existing or generated on first action).

## Design — 5 Mandatory Steps

### Step 1: Welcome (3-slide carousel)

| Field | Content |
|-------|---------|
| Slide A | "What is SafePay?" + shield icon + "Thailand's regulated escrow utility" |
| Slide B | "Why escrow?" + 3-card row: Buyer protected / Seller guaranteed / Funds in BBL custody |
| Slide C | "How it works" + 5-stage stepper visual: Pending → Held → Shipped → Delivered → Settled |
| CTA | "Get started" |
| Footer | "Step 1 of 5" + "Skip tour" link |

### Step 2: KYC Intro

| Field | Content |
|-------|---------|
| Header | "Know Your Customer (KYC)" |
| Body | "SafePay uses 4 KYC tiers to protect both sides of every transaction" |
| Tier ladder | T1: ฿0–฿10k/mo (default) / T2: ฿10k–฿50k (verified email) / T3: ฿50k–฿500k (verified ID) / T4: ฿500k+ (verified ID + bank) |
| Footer | "You'll complete KYC when you're ready to sell or withdraw. For now, just buying is fully enabled." |
| CTA | "Next" |
| Footer | "Step 2 of 5" |

### Step 3: Bank Linking Walkthrough

| Field | Content |
|-------|---------|
| Header | "Bank linking is one-tap" |
| Cards | (1) Link your bank (BBL, KBank, SCB, KTB) / (2) Funds held in BBL Sponsor Bank custody / (3) Released on delivery confirmation |
| Footer | "Bank linking happens on your first payout or first sell. We never store credentials — PromptPay instant verification." |
| CTA | "Next" |
| Footer | "Step 3 of 5" |

### Step 4: Test Transaction Primer

| Field | Content |
|-------|---------|
| Header | "Here's what a ฿10 charge looks like" |
| Visual | Mock QR + countdown (0:30 → 0:00) + settlement stepper + "✓ Settled" terminal state with ฿10.00 disbursement |
| Footer | "Both parties see the same stepper update in real time. This is a preview — no charge was created." |
| CTA | "Got it" |
| Footer | "Step 4 of 5" |

### Step 5: Done

| Field | Content |
|-------|---------|
| Header | Shield icon + "You're ready" |
| Summary | ✓ Escrow model understood / ✓ 4 KYC tiers known / ✓ Transaction visualised |
| CTA | "Go to dashboard" |
| Footer | "Step 5 of 5" |

### Completion State

```js
localStorage.setItem('safepay.onboarded', 'true');
localStorage.setItem('safepay.onboarded_at', new Date().toISOString());
navigate('/dashboard');
```

### Redirect Logic — `frontend/src/routes/+layout.svelte`

```
onMount:
  if (localStorage.getItem('safepay.onboarded') !== 'true'
      && $page.url.pathname !== '/onboarding') {
    goto('/onboarding');
  }
```

### Back / Skip Behaviour

- Steps 1–2: back button enabled
- Steps 3–5: back button **disabled** (lord strict flow)
- Skip button: ONLY on step 1 — sets flag, jumps to step 5

## File Territory

| File | Change | Lines (est.) |
|------|--------|--------------|
| `design.md` §7 | NEW section "Onboarding" | ~120 lines |
| `frontend/src/routes/onboarding/+page.svelte` | NEW | ~280 lines |
| `frontend/src/routes/+layout.svelte` | onMount redirect only | +15 lines |
| `frontend/src/lib/onboarding.ts` | NEW state machine + localStorage helpers | ~50 lines |
| `frontend/src/app.css` | new design tokens if needed | +20 lines |

### Files NOT Modified (cmd_035 boundary)

- `backend/**` — zero backend changes
- `frontend/src/routes/+page.svelte` — unchanged
- `frontend/src/routes/dashboard/+page.svelte` — unchanged
- `frontend/src/routes/admin/+page.svelte` — unchanged
- `design.md` §1–§6 — preserved verbatim

## File Isolation vs cmd_034

| Concern | cmd_034 owns | cmd_035 owns | Overlap |
|---------|--------------|--------------|---------|
| design.md | §6 | §7 | None — separate sections |
| backend | api/wanted.rs + wanted table | none | None |
| frontend | +page.svelte §6.1–§6.5 + dashboard §6.5 | onboarding/+page.svelte + layout redirect | None |

## Acceptance Criteria

1. design.md §7 covers all 5 steps with mobile-first 375px coverage, Thai-first bilingual copy, WCAG 2.1 AA contrast, cmd_027 v2 visual tokens, and empty states per design.md §4.1.
2. `onboarding/+page.svelte` implements all 5 steps as described.
3. `+layout.svelte` redirect logic: `!onboarded → /onboarding` (except for `/onboarding` itself).
4. `lib/onboarding.ts` exports: `isOnboarded()`, `markOnboarded()`, `resetOnboarding()`.
5. localStorage flag `safepay.onboarded = 'true'` set on step 5 completion.
6. Skip button on step 1 sets flag and jumps to step 5.
7. Back button enabled on steps 1–2, disabled on steps 3–5.
8. No backend code changes; cargo test (current count) still passes.
9. `vite build` clean; `svelte-check` 0 errors.
10. cmd_034 §6 territory preserved untouched.

## Success Criteria

- First-time visitor lands on `/` → redirected to `/onboarding`.
- Completes 5 steps → `/dashboard` reachable.
- Returning user with `localStorage['safepay.onboarded'] === 'true'` → no redirect.
- `resetOnboarding()` callable from dev tools for re-testing.

## Visual / UX Bar

- cmd_027 v2 calm trust-forward tokens (no glassmorphism, solid surfaces, thin #2c2c2e borders).
- Thai font stack: IBM Plex Sans Thai / Noto Sans Thai / Sarabun.
- `tabular-nums` on numeric fields (step counter, amounts).
- ฿X,XXX.XX currency format.
- WCAG 2.1 AA contrast (≥4.5:1 text/background).
- 44x44px touch targets.
- State indicators combine color + icon + text label.
- Skeleton loading on async data fetches (n/a here, all static).
- Mobile-first 375px coverage.
- Thai-first bilingual copy on every user-facing string.
- Light + dark theme parity.

## Out of Scope — Follow-up Cmds

These 6 surfaces are deferred to cmd_035b/c:

- Settings / Profile (KYC, bank mgmt)
- Notification Center (in-app inbox)
- Help Center (FAQ + Thai-first)
- Dispute Chat (live buyer↔seller↔operator)
- Transaction History Detail
- Receipts / Invoices (PDF/print)

Each will be its own design + impl cmd with file isolation.

## Open Questions

None. All decisions resolved.