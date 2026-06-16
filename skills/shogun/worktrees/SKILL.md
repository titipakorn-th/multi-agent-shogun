---
name: worktrees
description: Manage Git worktrees as safe isolated coding lanes for complex, risky, or parallel work in the Shogun system. Use when you need to run tasks in isolated branches, test package upgrades, or manage parallel developer agents without workspace pollution.
---

# Shogun Worktrees Orchestration Protocol

The `worktrees` skill provides a structured, safe orchestration protocol for managing Git worktrees as isolated coding lanes. This ensures that parallel specialists (`fixer`, `designer`), risky experiments, and package upgrades can proceed without polluting the main repository workspace or causing file write conflicts.

All worktrees reside under the default path:

```text
.shogun/worktrees/<slug>/
```

---

## 1. State Tracking (`.shogun/worktrees.json`)

To prevent conflicts and track active tasks, maintain a metadata manifest file at `.shogun/worktrees.json`:

```json
{
  "version": "1.0.0",
  "updatedAt": "2026-06-16T22:59:48.000Z",
  "lanes": [
    {
      "slug": "feature-auth-v2",
      "branch": "omos/feature-auth-v2",
      "path": ".shogun/worktrees/feature-auth-v2",
      "base": "main",
      "purpose": "refactor token validation flow",
      "owner": "orchestrator",
      "status": "active",
      "areas": ["src/auth"],
      "createdAt": "2026-06-16T22:59:48.000Z"
    }
  ]
}
```

Ensure this file is updated whenever a worktree is created, modified, integrated, or removed.

---

## 2. Safety Guards & Confirmation Gates

Before running any Git mutation commands, the Orchestrator must observe these rules:

### A. Pre-Flight Checklist
- Verify that the current directory is inside a Git repository.
- Ensure `.shogun/worktrees/` and `.shogun/worktrees.json` are excluded from version control in `.gitignore`.
- Run `git worktree list` to avoid path or branch name conflicts.
- Ensure the branch name (e.g. `omos/<slug>`) does not already exist.

### B. Mandatory Confirmation
Ask the user (Lord) for explicit permission before running:
- `git worktree add` or `git worktree remove`
- Merging, rebasing, cherry-picking, or running any destructive commands like `git reset --hard` or `git clean`.
- Use the standard chat interface or call the `scripts/lord_ask.sh` wrapper if you are running asynchronously:
  ```bash
  bash scripts/lord_ask.sh "Create worktree lane for <slug> on branch <branch>?" "Yes" "No"
  ```

---

## 3. Workflow Guide

### Phase 1: Planning & Setup
1. Define a short `<slug>` for the worktree task.
2. Select a branch name (defaults to `omos/<slug>`).
3. Confirm repository safety and seek Lord's approval.
4. Ensure ignore files are configured.
5. Create the worktree:
   ```bash
   git worktree add -b <branch-name> .shogun/worktrees/<slug> <base-commit/branch>
   ```
6. Update `.shogun/worktrees.json`.

### Phase 2: Execution & Delegation
1. When delegating tasks to specialists (e.g., in `queue/tasks/fixer.yaml`), set the task targets or execution paths strictly inside the worktree directory:
   ```yaml
   # Example task configuration
   project: "my-project"
   target_path: ".shogun/worktrees/feature-auth-v2/src/auth/token.py"
   ```
2. Run compilation, linting, and tests inside `.shogun/worktrees/<slug>/`.

### Phase 3: Integration & Validation
1. Verify the changes compile and pass tests inside the worktree.
2. Show a clean diff between the worktree branch and the base branch.
3. Seek Lord's approval to integrate.
4. Perform the merge/integration from the main checkout directory.

### Phase 4: Cleanup & Pruning
1. Ensure all changes are merged or stashed.
2. Ask for approval to clean up the worktree.
3. Run:
   ```bash
   git worktree remove .shogun/worktrees/<slug>
   ```
4. Update `.shogun/worktrees.json` to mark the lane as `archived` or remove it.
