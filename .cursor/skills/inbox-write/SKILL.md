---
name: inbox-write
description: Send a message to another agent's inbox. This is the sole method for agent-to-agent communication.
---

Always use this skill to send messages to other agents.
Directly sending messages via tmux send-keys is prohibited.

## Usage

```bash
bash scripts/inbox_write.sh <target_agent> "<message>" <type> <from>
```

### Types List

| type | Purpose |
|------|------|
| `cmd_new` | New command (shogun → orchestrator) |
| `task_assigned` | Task assignment (orchestrator → specialist) |
| `report_received` | Task completion report (specialist → orchestrator) |
| `clear_command` | Session reset directive |
| `model_switch` | Model switch directive |

### Examples

```bash
bash scripts/inbox_write.sh orchestrator "Wrote cmd_048. Please execute." cmd_new shogun
bash scripts/inbox_write.sh fixer "Read the task YAML and start work." task_assigned orchestrator
bash scripts/inbox_write.sh oracle "Mission complete. Requesting strategic review." report_received fixer
```
