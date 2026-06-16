---
name: model-switch
description: |
  Live-switch agent CLI and models. Automates settings.yaml update → /exit → starting new CLI →
  pane metadata update in one shot. Also controls Thinking ON/OFF.
  Triggered by: "switch model", "change to Sonnet", "change to Opus", "switch all Ashigaru", "disable Thinking".
argument-hint: "[agent-name target-model e.g. explorer sonnet]"
allowed-tools: Bash(bash scripts/switch_cli.sh *), Read, Edit
---

# /model-switch - Agent CLI Live Switcher

## Overview

Live-switches CLI type, model, and Thinking settings of active agents.
Executes a seamless pipeline: `settings.yaml` update → `build_cli_command()` → `/exit` → start new CLI → pane metadata update.

## When to Use

- "Change designer to Opus", "Switch all Ashigaru to Sonnet"
- "Switch model", "Change model", "Change CLI"
- "Disable Thinking", "Enable Thinking"
- "Restore to Claude from Codex", "Switch to Spark"
- When you want to switch models depending on the nature of the task

## Architecture

```
settings.yaml (source of truth)
    │
    ├─ cli.agents.{id}.type      → claude | codex | copilot | kimi
    ├─ cli.agents.{id}.model     → claude-sonnet-4-6 | claude-opus-4-6 | ...
    └─ cli.agents.{id}.thinking  → true | false
         │
         ├── build_cli_command()
         │   └─ thinking: false → "MAX_THINKING_TOKENS=0 claude --model ..."
         │   └─ thinking: true  → "claude --model ..."
         │
         └── get_model_display_name()
             └─ thinking: true  → "Sonnet+T" / "Opus+T"
             └─ thinking: false → "Sonnet" / "Opus"
```

## Display Name Mapping

| model (settings.yaml) | Display Name | +Thinking |
|---|---|---|
| claude-sonnet-4-6 | Sonnet | Sonnet+T |
| claude-opus-4-6 | Opus | Opus+T |
| claude-haiku-4-5-20251001 | Haiku | Haiku+T |
| gpt-5.3-codex | Codex | — |
| gpt-5.3-codex-spark | Spark | — |

## Instructions

### Individual Switch

```bash
# Restart with current settings.yaml value (when only resetting the CLI)
bash scripts/switch_cli.sh designer

# Change model (settings.yaml automatically updated)
bash scripts/switch_cli.sh designer --model claude-opus-4-6

# Change CLI type as well (Codex → Claude)
bash scripts/switch_cli.sh designer --type claude --model claude-sonnet-4-6

# Claude → Codex Spark
bash scripts/switch_cli.sh observer --type codex --model gpt-5.3-codex-spark
```

### Bulk Switch

```bash
# Switch all Ashigaru to Sonnet
for i in $(seq 1 7); do
    bash scripts/switch_cli.sh specialist$i --type claude --model claude-sonnet-4-6
done

# Switch all Ashigaru to Spark
for i in $(seq 1 7); do
    bash scripts/switch_cli.sh specialist$i --type codex --model gpt-5.3-codex-spark
done

# Restart all agents (including Karo & Gunshi)
for agent in orchestrator explorer librarian designer fixer observer oracle council oracle; do
    bash scripts/switch_cli.sh "$agent"
done
```

### Thinking Control

Edit the `thinking` field in `settings.yaml` first, then run `switch_cli.sh`:

```yaml
# config/settings.yaml
cli:
  agents:
    designer:
      type: claude
      model: claude-opus-4-6
      thinking: false  # ← Starts with MAX_THINKING_TOKENS=0
```

```bash
# Restart after editing settings.yaml
bash scripts/switch_cli.sh designer
```

Steps for switching Thinking ON/OFF:
1. Change the targeted agent's `thinking:` to `true`/`false` in `config/settings.yaml`
2. Restart via `bash scripts/switch_cli.sh <agent_id>`
3. The presence/absence of `+T` is reflected in the pane border

### Via Inbox (Switching from Karo)

```bash
# When Karo switches an Ashigaru's CLI
bash scripts/inbox_write.sh designer "--type claude --model claude-opus-4-6" cli_restart orchestrator
```

`inbox_watcher` detects the `cli_restart` type and automatically executes `switch_cli.sh`.

## What switch_cli.sh Does (internal)

1. Updates `settings.yaml` (only when `--type`/`--model` is specified)
2. Detects the current CLI type (using tmux pane metadata `@agent_cli`)
3. Sends the appropriate exit command per CLI type
   - Claude: `/exit` + Enter
   - Codex: Escape → Ctrl-C → `/exit` + Enter
   - Copilot/Kimi: Ctrl-C → `/exit` + Enter
4. Waits for returning to the shell prompt (max 15 seconds, captured every second)
5. Builds the new command via `build_cli_command()`
   - thinking: false → Appends `MAX_THINKING_TOKENS=0` prefix
6. Starts the new CLI via `tmux send-keys` (sending text and Enter separately)
7. Updates pane metadata: `@agent_cli`, `@model_name`

## Files

| File | Role |
|---|---|
| `scripts/switch_cli.sh` | Main script |
| `lib/cli_adapter.sh` | `build_cli_command()`, `get_model_display_name()` |
| `config/settings.yaml` | Agent configuration (type, model, thinking) |
| `scripts/inbox_watcher.sh` | `cli_restart` type handling |
| `logs/switch_cli.log` | Execution log |

## Constraints

- **Do not send to the Shogun pane**: `switch_cli.sh` only targets panes in the `multiagent` session.
- **Beware of running agents**: Switching while a task is running can cause data loss. Execute after confirming they are idle.
- **Codex → Claude transition**: Codex's `/exit` might be unstable. Ensure termination with Escape + Ctrl-C.
- **Integration with inbox_watcher**: After a `cli_restart`, `inbox_watcher`'s `CLI_TYPE` variable is automatically updated.
