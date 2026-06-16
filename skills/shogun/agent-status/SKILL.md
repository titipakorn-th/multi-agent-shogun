---
name: agent-status
description: |
  Skill to display the status list of all agents (Karo, Ashigaru 1-7, Gunshi).
  Integrates tmux pane status (Active/Idle/Absent), task YAML status (task_id, status),
  and unread inbox counts.
  Triggered by: "agent status", "agent check", "battle formation check", "check battle readiness".
---

# /agent-status - Agent Status Check

## Overview

Displays the status list of all agents by integrating and evaluating two data sources:

1. **Pane Status**: Detects CLI-specific idle/busy patterns from the last 5 lines of tmux capture-pane
2. **Task YAML**: `task_id` and `status` in `queue/tasks/{agent}.yaml`
3. **Unread Inbox**: Number of unprocessed messages in `queue/inbox/{agent}.yaml`

Supports both Claude Code and Codex CLI.

## When to Use

- When asked to "check agent status", "show agent status", or "check battle formation"
- When you want to check if any Ashigaru are idle
- When looking for free agents before allocating tasks
- When checking if someone is stuck

## Instructions

Execute the following command:

```bash
bash scripts/agent_status.sh
```

## How to Read the Output

| Column | Meaning |
|--------|------|
| Agent | Agent Name |
| CLI | CLI Type (claude/codex) |
| Pane | tmux pane status: Active/Idle/Absent |
| Task ID | `task_id` in task YAML (--- = Unassigned) |
| Status | Task YAML status: assigned/done/idle, etc. |
| Inbox | Unread inbox message count |

## Interpretation of Statuses

- **Pane=Idle + Status=done**: Completed, waiting for next task. Ready for new task allocation.
- **Pane=Active + Status=assigned**: Executing task normally. Can be left alone.
- **Pane=Idle + Status=assigned**: Task allocated but CLI is stopped. Investigation required.
- **Pane=Active + Status=done**: Post-task execution (processing inbox, etc.) after task completion.
- **Inbox > 0**: Unread messages exist. Possibility that the agent has not processed them yet.
- **Pane=Absent**: tmux pane does not exist (depart_for_battle/shutsujin not executed, or pane was killed).
