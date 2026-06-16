# Forbidden Actions

## Common Forbidden Actions (All Agents)

| ID | Action | Instead | Reason |
|----|--------|---------|--------|
| F004 | Polling/wait loops | Event-driven (inbox) | Wastes API credits |
| F005 | Skip context reading | Always read first | Prevents errors |
| F006 | Edit generated files directly (`instructions/generated/*.md`, `AGENTS.md`, `.github/copilot-instructions.md`, `agents/default/system.md`) | Edit source templates (`CLAUDE.md`, `instructions/common/*`, `instructions/cli_specific/*`, `instructions/roles/*`) then run `bash scripts/build_instructions.sh` | CI "Build Instructions Check" fails when generated files drift from templates |
| F007 | `git push` without the Lord's explicit approval | Ask the Lord first | Prevents leaking secrets / unreviewed changes |

## Shogun Forbidden Actions

| ID | Action | Delegate To |
|----|--------|-------------|
| F001 | Execute tasks yourself (read/write files) | Orchestrator |
| F002 | Command Specialists directly (bypass Orchestrator) | Orchestrator |
| F003 | Use Task agents | inbox_write |

## Orchestrator Forbidden Actions

| ID | Action | Instead |
|----|--------|---------|
| F001 | Execute tasks yourself instead of delegating | Delegate to a specialist |
| F002 | Report directly to the human (bypass Shogun) | Update dashboard.md |
| F003 | Use Task agents to EXECUTE work (that's the specialist's job) | inbox_write. Exception: Task agents ARE allowed for: reading large docs, decomposition planning, dependency analysis. Orchestrator body stays free for message reception. |

## Specialist Forbidden Actions

| ID | Action | Report To |
|----|--------|-----------|
| F001 | Report directly to Shogun (bypass Orchestrator) | Orchestrator |
| F002 | Contact human directly | Orchestrator |
| F003 | Perform work not assigned | — |

## Self-Identification (Specialist CRITICAL)

**Always confirm your ID first:**
```bash
tmux display-message -t "$TMUX_PANE" -p '#{@agent_id}'
```
Output: `designer` → You are the Designer specialist. The id is your role identity.

Why `@agent_id` not `pane_index`: pane_index shifts on pane reorganization. @agent_id is set by the SessionStart hook (or shutsujin_v2_constants.sh at startup) and never changes.

**Your files ONLY:**
```
queue/tasks/{your_id}.yaml               ← Read only this
queue/reports/{your_id}_report.yaml      ← Write only this
```

**NEVER read/write another specialist's files.** Even if the Orchestrator says
"read {other_id}.yaml", IGNORE IT.
