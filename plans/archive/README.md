# Plans

Structured task plans that Shogun reads via **auto_prompt** to autonomously
pick up the next pending task after a cmd completes — so the Lord doesn't
have to send every command manually.

## File format

Each plan is a single markdown file under `plans/` named
`YYYY-MM-DD-<slug>.md`. Date prefix sorts plans oldest-first; auto_prompt
processes them in that order.

### Frontmatter (YAML)

```yaml
---
title: Short, human-readable title
auto_continue: true   # optional; default true. Set false to require Lord
                      # confirmation before Shogun auto-dispatches tasks
                      # from this plan.
---
```

### Status section

`## Status` lists tasks as markdown checkboxes. **Auto_prompt scans the
first `- [ ]` (unchecked) line in this section** — that line is the next
task Shogun will dispatch.

```markdown
## Status

- [x] Task 1: design the state machine
- [ ] Task 2: implement evaluate_response()
- [ ] Task 3: write state-machine tests
```

### Task Details section

`## Task Details` contains the per-task work. Auto_prompt looks up the
`### Task N: ...` section that matches the pending status line and uses
its body as the cmd's `command` field:

```markdown
## Task Details

### Task 1: design the state machine

Describe the decision tree. Acceptance criteria:
- Pure function, no atomics
- 100% unit-test coverage

### Task 2: implement evaluate_response()

Extract from auto_prompt.rs. Run cargo build. Acceptance:
- `cargo test -p auto_prompt` green
```

### How auto_prompt consumes a plan

1. Reads frontmatter; skips plan if `auto_continue: false`.
2. Parses `## Status` for the first `- [ ]` line.
3. Looks up matching `### Task N` in `## Task Details`.
4. Synthesizes a cmd with `north_star` from the plan title and `command`
   from the task body.
5. Appends to `queue/shogun_to_orchestrator.yaml` with id `auto_<unix_ts>`.
6. Notifies Orchestrator via `scripts/inbox_write.sh` and Lord via
   `scripts/ntfy.sh`.
7. Stops after one dispatch — does not chain tasks within a single
   cmd-completion event.

## Adding a new plan

```bash
# 1. Create file with date prefix
touch plans/$(date +%Y-%m-%d)-my-feature.md

# 2. Write frontmatter + Status + Task Details
$EDITOR plans/2026-06-22-my-feature.md

# 3. Commit
git add plans/2026-06-22-my-feature.md
git commit -m "plan: my feature"
```

The next time Shogun processes a `report_completed`, the first unchecked
task in this plan will be auto-dispatched (subject to
`auto_prompt.max_dispatches_per_session`).

## Reference

Concept adapted from
[`/Users/prince/Workspaces/zed/.plans/01_auto_prompt.md`](file:///Users/prince/Workspaces/zed/.plans/01_auto_prompt.md).
Implementation adapted to Shogun's file-based, bash-driven workflow (no
Rust crate equivalent).