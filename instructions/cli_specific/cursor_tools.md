# Cursor Agent CLI — Specific Operation Rules

These are operation rules applied only in the Cursor Agent CLI environment.
Use them in combination with the shared protocols (CLAUDE.md / AGENTS.md) and role instructions.

## Overview

- `CLAUDE.md`, `AGENTS.md`, and `.cursor/rules/` are automatically loaded at the start of a session.
- Runs in `--yolo` mode (Auto-run), so no additional approval is required for tool execution.
- Inter-agent communication is performed via the `inbox-write` skill.

## Session Reset

```
/new-chat
```

## Exit

```
/quit
```

(Text and Enter are sent with a 0.3s delay in between.)

## Inter-Agent Communication

Always use the `inbox-write` skill to send messages to other agents.
Direct manipulation of tmux is prohibited.

```bash
bash scripts/inbox_write.sh <target_agent> "<message>" <type> <from>
```

## Model Switching

```
/model <model-name>
```

Running it without arguments displays the list of available models.

## Auto-Loaded Files

| File | Contents |
|------|----------|
| `CLAUDE.md` | Session procedures, communication protocols, and forbidden actions |
| `AGENTS.md` | Agent configuration |
| `.cursor/rules/` | Additional rules (Always Apply type) |
| `.cursor/skills/` | Skill definitions (auto-loaded at startup) |

## Available Tools

Cursor Agent provides the following tools:

- **File Operations**: Read, write, and edit files
- **Shell Commands**: Execute terminal commands
- **Web Search**: Built-in search functionality
