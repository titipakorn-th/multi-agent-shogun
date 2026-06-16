---
name: shogun-bloom-config
description: >
  Interactive wizard: guided questions with multiple-choice options about subscriptions,
  then outputs a ready-to-paste capability_tiers YAML + fixed agent model assignments.
  Trigger: "capability_tiers", "bloom config", "routing setup", "set up model routing",
  "routing config", "capability_tiers config", "model config", "subscription config", "model routing"
---

# /shogun-bloom-config — Bloom Routing Wizard

## Overview

Generates the optimal `capability_tiers` configuration in a ready-to-paste format by answering just two questions in a guided interview.

**Output:**
1. `capability_tiers` YAML → Can be pasted directly into `config/settings.yaml`
2. `available_cost_groups` declaration
3. Recommended models for fixed agents (Karo / Gunshi)
4. Coverage gap warning (e.g., when Bloom L6 cannot be processed)

## When to Use

- Initial setup of `config/settings.yaml`
- Reconfiguration after adding/changing subscriptions
- "How should capability_tiers be configured?"
- After checking the model list with `/shogun-model-list`

---

## Instructions

**IMPORTANT: Do NOT output the pattern tables directly. Always ask questions first using AskUserQuestion.**

### Step 1: Q1 — Claude plan (AskUserQuestion)

Call AskUserQuestion with the following:

```
question: "Please tell me your Claude plan."
header: "Claude Plan"
options:
  - label: "Max 20x ($200/month)"
    description: "All Opus, Sonnet, and Haiku models available. 20x usage limit. Recommended for Spark Dual operations (Recommended)"
  - label: "Max 5x ($100/month)"
    description: "Same as above, 5x usage limit. For cost-conscious users if the volume is sufficient."
  - label: "Pro ($20/month)"
    description: "Opus, Sonnet, and Haiku available. Standard usage limits. Sufficient for personal use."
  - label: "Free / None"
    description: "Sonnet and Haiku only (Opus unavailable). Gaps will occur for L6 tasks."
```

### Step 2: Q2 — ChatGPT plan (AskUserQuestion)

Call AskUserQuestion with the following:

```
question: "Please tell me your ChatGPT (OpenAI) plan."
header: "ChatGPT Plan"
options:
  - label: "None (Claude only operation)"
    description: "Claude quota only. Simple configuration. Ashigaru primarily use Haiku 4.5."
  - label: "Plus ($20/month)"
    description: "gpt-5.3-codex available (Spark unavailable). Can cover up to L4."
  - label: "Pro ($200/month)"
    description: "Spark (1000 tok/s, Terminal-Bench 58.4%) + gpt-5.3 (77.3%) available. Strongest formation with 7 Ashigaru (Recommended)"
```

### Step 2.5: Q3 — Rate limit preference (Only when both are subscribed)

**Only ask when Q1=Pro/Max AND Q2=Plus or Pro.**
If both subscriptions are available, confirm which quota should process the same Bloom level.

#### Q3a: Priority quota for L3 tasks (mass code generation & template application)

Call AskUserQuestion with:

```
question: "Which quota should be prioritized for L1-L3 tasks (mass production, templates, simple implementation)?"
header: "L3 Quota Priority"
options:
  - label: "Prioritize ChatGPT Pro (Spark / gpt-5.3) (Recommended)"
    description: "Lightning-fast processing with Spark at 1000 tok/s. Conserves Claude Max quota to focus on L5-L6."
  - label: "Prioritize Claude Max (Haiku 4.5)"
    description: "Uses Claude quota evenly. Saves ChatGPT Pro quota to leave room for L4."
```

#### Q3b: Priority quota for L4 tasks (analysis, code review, debugging) — Only when Q2=Pro

Call AskUserQuestion with:

```
question: "Which quota should be prioritized for L4 tasks (analysis, debugging, code review)?"
header: "L4 Quota Priority"
options:
  - label: "Prioritize ChatGPT Pro (gpt-5.3-codex) (Recommended)"
    description: "Terminal-Bench 77.3%. Utilizes Codex Pro quota and conserves Claude quota."
  - label: "Prioritize Claude Max (Sonnet 4.6)"
    description: "SWE-bench 79.6%. Processes L4 at Claude quality. Focuses ChatGPT Pro quota on Spark."
```

Adjust the max_bloom value of capability_tiers based on these answers (refer to the custom sections of the patterns below).

### Step 3: Map answers to pattern

| Claude | ChatGPT | Pattern |
|--------|---------|---------|
| None/Free | None | A-Free |
| Pro/Max | None | A |
| None/Free | Plus | B |
| None/Free | Pro | C |
| Pro/Max | Plus | D |
| Pro/Max | Pro | **E (Full Power)** |

### Step 4: Output the matching pattern below

Output ONLY the matching pattern. Show:
1. Simple explanation (why this configuration)
2. `capability_tiers` YAML (copyable code block)
3. `available_cost_groups`
4. Recommended models for fixed agents (Karo / Gunshi)
5. Gap warning (if any)
6. Next steps

---

## Pattern A-Free — Claude Free Only

> Sonnet 4.6 and Haiku 4.5 can be used, but Opus 4.6 is unavailable. L6 tasks will be processed at L5 quality.

### Fixed Agents

| Agent | Recommended Model | Notes |
|------------|-----------|------|
| Karo | `claude-sonnet-4-6` | Sonnet since Opus is unavailable |
| Gunshi | `claude-sonnet-4-6` | Same as above |

### `config/settings.yaml` snippet

```yaml
available_cost_groups:
  - claude_max

capability_tiers:
  claude-haiku-4-5-20251001:
    max_bloom: 3       # L1-L3: $1/$5/M, SWE-bench 73.3%
    cost_group: claude_max
  claude-sonnet-4-6:
    max_bloom: 5       # L4-L5: $3/$15/M, SWE-bench 79.6%, 1M context
    cost_group: claude_max
```

### Coverage

| Bloom | Model | Notes |
|-------|-------|------|
| L1–L3 | Haiku 4.5 | Fast / Cheap |
| L4–L5 | Sonnet 4.6 | Analysis & Design evaluation |
| **L6** | ⚠️ **GAP** | Opus 4.6 unavailable. Substituted with L5 quality. |

---

## Pattern A — Claude Pro/Max Only ($20–$200/month)

> All models up to Claude Opus are available. Ashigaru are automatically routed: Haiku (L1-L3) → Sonnet (L4-L5) → Opus (L6).

### Fixed Agents

| Agent | Recommended Model | Notes |
|------------|-----------|------|
| Karo | `claude-sonnet-4-6` | L4-L5 Orchestration. Opus is overkill. |
| Gunshi | `claude-opus-4-6` | L5-L6 deep QC & Architecture evaluation |

### `config/settings.yaml` snippet

```yaml
available_cost_groups:
  - claude_max

capability_tiers:
  claude-haiku-4-5-20251001:
    max_bloom: 3       # L1-L3: $1/$5/M, SWE-bench 73.3% — Mainstay for mass-production tasks
    cost_group: claude_max
  claude-sonnet-4-6:
    max_bloom: 5       # L4-L5: $3/$15/M, SWE-bench 79.6%, 1M context
    cost_group: claude_max
  claude-opus-4-6:
    max_bloom: 6       # L6: $5/$25/M, SWE-bench 80.8% — Only for true creative tasks
    cost_group: claude_max
```

### Coverage

| Bloom | Model | Notes |
|-------|-------|------|
| L1–L3 | Haiku 4.5 | SWE-bench 73.3%, -4pp compared to Sonnet 4.5, 1/3 cost |
| L4–L5 | Sonnet 4.6 | SWE-bench 79.6%, Math +27pt (vs Sonnet 4.5) |
| L6 | Opus 4.6 | SWE-bench 80.8%. 1.2pp diff from Sonnet. Only recommended for true L6. |

---

## Pattern B — ChatGPT Plus Only ($20/month)

> Spark is unavailable. gpt-5.3-codex is the mainstay. L6 Gap exists. Configuration without Claude has low cost-performance.

### Fixed Agents

> No Claude subscription → Karo/Gunshi also use Codex models. Beware of the L6 gap.

| Agent | Recommended Model |
|------------|-----------|
| Karo | `gpt-5.3-codex` |
| Gunshi | `gpt-5.1-codex-max` |

### `config/settings.yaml` snippet

```yaml
available_cost_groups:
  - chatgpt_plus

capability_tiers:
  gpt-5-codex-mini:
    max_bloom: 2       # L1-L2: Dedicated to lightweight tasks
    cost_group: chatgpt_plus
  gpt-5.3-codex:
    max_bloom: 4       # L3-L4: Terminal-Bench 77.3%
    cost_group: chatgpt_plus
  gpt-5.1-codex-max:
    max_bloom: 5       # L5: Highest Codex model
    cost_group: chatgpt_plus
```

### Coverage

| Bloom | Model | Notes |
|-------|-------|------|
| L1–L2 | codex-mini | Minimal quota consumption |
| L3–L4 | gpt-5.3-codex | |
| L5 | codex-max | |
| **L6** | ⚠️ **GAP** | Codex is unsuitable for new creative/design tasks. Claude Opus recommended. |

---

## Pattern C — ChatGPT Pro Only ($200/month)

> Spark (1000 tok/s) available. L6 gap remains. Adding Claude achieves full configuration.

### Fixed Agents

| Agent | Recommended Model |
|------------|-----------|
| Karo | `gpt-5.3-codex` |
| Gunshi | `gpt-5.1-codex-max` |

### `config/settings.yaml` snippet

```yaml
available_cost_groups:
  - chatgpt_pro

capability_tiers:
  gpt-5.3-codex-spark:
    max_bloom: 3       # L1-L3: 1000+ tok/s — Comfortable throughput even for 7 Ashigaru
    cost_group: chatgpt_pro
  gpt-5.3-codex:
    max_bloom: 4       # L4: Terminal-Bench 77.3%, 400K+ context
    cost_group: chatgpt_pro
  gpt-5.1-codex-max:
    max_bloom: 5       # L5: Highest Codex capability
    cost_group: chatgpt_pro
```

### Coverage

| Bloom | Model | Notes |
|-------|-------|------|
| L1–L3 | **Spark** | Made by Cerebras. Independent quota from Codex. |
| L4 | gpt-5.3-codex | |
| L5 | codex-max | |
| **L6** | ⚠️ **GAP** | L6 requires Claude Opus 4.6. |

---

## Pattern D — Claude Pro/Max + ChatGPT Plus ($40–$220/month)

> Claude handles high quality (L4+). Codex Plus covers L1-L4 mass production. Spark unavailable.

### Fixed Agents

| Agent | Recommended Model |
|------------|-----------|
| Karo | `claude-sonnet-4-6` |
| Gunshi | `claude-opus-4-6` |

### `config/settings.yaml` snippet

```yaml
available_cost_groups:
  - claude_max
  - chatgpt_plus

capability_tiers:
  gpt-5-codex-mini:
    max_bloom: 2       # L1-L2: Conserves Claude quota. Consumes Codex Plus quota.
    cost_group: chatgpt_plus
  gpt-5.3-codex:
    max_bloom: 4       # L3-L4: Terminal-Bench 77.3%
    cost_group: chatgpt_plus
  claude-sonnet-4-6:
    max_bloom: 5       # L5: Claude-quality architecture evaluation
    cost_group: claude_max
  claude-opus-4-6:
    max_bloom: 6       # L6: Creative/Strategic tasks
    cost_group: claude_max
```

### Coverage

| Bloom | Model | Notes |
|-------|-------|------|
| L1–L2 | codex-mini | Consumes Codex Plus quota, saving Claude Max |
| L3–L4 | gpt-5.3-codex | |
| L5 | Sonnet 4.6 | Switches to Claude quality |
| L6 | Opus 4.6 | |

---

## Pattern E — Claude Pro/Max + ChatGPT Pro ($220–$400/month) ⭐ Full Power

> **Strongest formation**. Fast processing of L1-L3 via Spark, high quality processing of L4-L6 via Claude.
> Full coverage of all Bloom levels at $400/month (Claude Max 20x + ChatGPT Pro).

### Fixed Agents

| Agent | Recommended Model | Reason |
|------------|-----------|------|
| Karo | `claude-sonnet-4-6` | L4-L5 Orchestration. SWE-bench 79.6% |
| Gunshi | `claude-opus-4-6` | L5-L6 deep QC. SWE-bench 80.8% |

### config by Q3a x Q3b answers

#### E-1: Prioritize Spark (L3) x Prioritize Codex (L4) ← **Default Recommended**

> Focus Claude Max quota on L5-L6. High-speed processing of L1-L4 using ChatGPT Pro quota.

```yaml
available_cost_groups:
  - claude_max
  - chatgpt_pro

capability_tiers:
  gpt-5.3-codex-spark:
    max_bloom: 3       # L1-L3: 1000+ tok/s — High-speed processing of L1-L3 with ChatGPT Pro quota
    cost_group: chatgpt_pro
  claude-haiku-4-5-20251001:
    max_bloom: 3       # L1-L3: Claude quota fallback (automatic switch when Spark quota is exhausted)
    cost_group: claude_max
  gpt-5.3-codex:
    max_bloom: 4       # L4: Terminal-Bench 77.3% — Also utilizes Codex Pro quota for L4
    cost_group: chatgpt_pro
  claude-sonnet-4-6:
    max_bloom: 5       # L5: SWE-bench 79.6%, 1M context
    cost_group: claude_max
  claude-opus-4-6:
    max_bloom: 6       # L6: SWE-bench 80.8%
    cost_group: claude_max
```

#### E-2: Prioritize Spark (L3) x Prioritize Sonnet (L4)

> L4 is also processed at Claude quality. Focuses ChatGPT Pro quota on Spark.

```yaml
available_cost_groups:
  - claude_max
  - chatgpt_pro

capability_tiers:
  gpt-5.3-codex-spark:
    max_bloom: 3       # L1-L3: 1000+ tok/s — Focuses ChatGPT Pro quota on Spark
    cost_group: chatgpt_pro
  claude-haiku-4-5-20251001:
    max_bloom: 3       # L1-L3: Claude quota fallback
    cost_group: claude_max
  claude-sonnet-4-6:
    max_bloom: 5       # L4-L5: SWE-bench 79.6% — L4 also at Claude quality
    cost_group: claude_max
  claude-opus-4-6:
    max_bloom: 6       # L6: SWE-bench 80.8%
    cost_group: claude_max
```

#### E-3: Prioritize Haiku (L3) x Prioritize Codex (L4)

> L3 is processed with Claude quota, conserving ChatGPT Pro quota for gpt-5.3 at L4.

```yaml
available_cost_groups:
  - claude_max
  - chatgpt_pro

capability_tiers:
  claude-haiku-4-5-20251001:
    max_bloom: 3       # L1-L3: SWE-bench 73.3% — Processes L3 with Claude quota
    cost_group: claude_max
  gpt-5.3-codex-spark:
    max_bloom: 2       # L1-L2 only: Spark used auxiliary (L3 goes to Haiku)
    cost_group: chatgpt_pro
  gpt-5.3-codex:
    max_bloom: 4       # L4: Terminal-Bench 77.3% — Focuses ChatGPT Pro quota on L4
    cost_group: chatgpt_pro
  claude-sonnet-4-6:
    max_bloom: 5       # L5
    cost_group: claude_max
  claude-opus-4-6:
    max_bloom: 6       # L6
    cost_group: claude_max
```

#### E-4: Prioritize Haiku (L3) x Prioritize Sonnet (L4)

> Processes L1-L5 entirely with Claude quota. ChatGPT Pro quota is saved (only auxiliary Spark usage).

```yaml
available_cost_groups:
  - claude_max
  - chatgpt_pro

capability_tiers:
  gpt-5.3-codex-spark:
    max_bloom: 2       # L1-L2 auxiliary: Processes only ultra-lightweight tasks with Spark
    cost_group: chatgpt_pro
  claude-haiku-4-5-20251001:
    max_bloom: 3       # L1-L3: Unified processing with Claude quota
    cost_group: claude_max
  claude-sonnet-4-6:
    max_bloom: 5       # L4-L5: Processes L4 at Claude quality as well
    cost_group: claude_max
  claude-opus-4-6:
    max_bloom: 6       # L6
    cost_group: claude_max
```

### Coverage (E-1 standard)

| Bloom | Model | Speed/Quality |
|-------|-------|----------|
| L1–L3 | **Spark** → Haiku (Fallback) | 1000 tok/s. Automatic switch when quota is exhausted. |
| L4 | gpt-5.3-codex | Full utilization of Codex Pro quota |
| L5 | Sonnet 4.6 | Claude quality. 1.2pt diff from Opus at 1/5 the price |
| L6 | Opus 4.6 | Only deployed for true creative tasks |

> **Cost Optimization Point**: Spark and gpt-5.3 have independent quotas. Both can be utilized at maximum capacity simultaneously.
> Sonnet 4.6 is sufficient instead of Opus for L5 (SWE-bench diff of 1.2%, price diff of approx 1.7x: $3/$15 vs $5/$25/M).

---

## Step 5: Configuration Application Steps

Be sure to provide the following application steps after outputting the YAML:

**1. Open `config/settings.yaml`**

```yaml
# Paste available_cost_groups and capability_tiers
available_cost_groups:
  - ...   ← Paste here

capability_tiers:
  ...:    ← Paste here
```

**2. Update fixed agent models**

```yaml
cli:
  agents:
    orchestrator:
      type: claude
      model: claude-sonnet-4-6     # ← Change to Karo recommended model
    oracle:
      type: claude
      model: opus                  # ← Change to Gunshi recommended model
    explorer:                     # ← Ashigaru are automatically routed according to capability_tiers
      type: codex                  #    Configure the CLI type according to the subscription
      model: gpt-5.3-codex-spark
```

**3. Enable bloom_routing (optional)**

```yaml
bloom_routing: "manual"   # "off"(disabled) → "manual"(manual) → "auto"(fully automatic)
```

**4. Verify configuration (in terminal)**

```bash
# subscription coverage check (detects uncovered Bloom levels)
source lib/cli_adapter.sh && validate_subscription_coverage
```

---

## Quick Decision Tree

```
Are you subscribed to Claude Pro or higher?
  Yes → Claude is available for fixed agents (Shogun/Karo/Gunshi) ✓
  No  → Codex only. Beware of L6 gap ⚠️

Are you subscribed to ChatGPT Pro ($200)?
  Yes → Spark (L1-L3, 1000 tok/s) + gpt-5.3 (L4) can be used ✓
  Plus ($20) → gpt-5.3 (L3-L4) only. Spark unavailable.
  None → Claude Haiku handles L1-L3 for Ashigaru
```
