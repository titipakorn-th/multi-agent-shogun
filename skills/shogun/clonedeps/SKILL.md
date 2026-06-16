---
name: clonedeps
description: Clone important project dependency source code into an ignored local workspace so agents can inspect library internals. Use when you need to clone dependencies, inspect library/SDK source internals, debug package implementation details, or make dependency codebases readable in the Shogun system. Do not use for general documentation lookup where the Librarian can just search the web.
---

# Shogun Clonedeps Skill

You help users make a small, focused set of important dependency source repositories locally readable to the Shogun multi-agent team. This is useful when documentation is sparse, outdated, or incomplete, allowing specialists to inspect real library behavior.

This is an orchestrator/shogun workflow skill. Discovery and recommendation are delegated to `@librarian`, while cloning and metadata management are handled by the Orchestrator.

All cloned repositories reside under the path:

```text
.shogun/clonedeps/repos/<safe-repo-name>/
```

---

## 1. State Tracking (`.shogun/clonedeps.json`)

To track cloned repositories and prevent redundant clones, maintain a metadata manifest file at `.shogun/clonedeps.json`:

```json
{
  "version": "1.0.0",
  "updatedAt": "2026-06-16T22:59:48.000Z",
  "dependencies": [
    {
      "name": "@opencode-ai/sdk",
      "resolvedVersion": "1.3.17",
      "repoUrl": "https://github.com/opencode-ai/opencode.git",
      "ref": "v1.3.17",
      "path": ".shogun/clonedeps/repos/opencode-ai__opencode",
      "packagePath": "packages/sdk/js",
      "reason": "Core SDK source used to inspect runtime behavior"
    }
  ]
}
```

Do not add `.shogun/clonedeps.json` to `.gitignore`. It is lightweight metadata that can be committed to the project repository. Only ignore the cloned repo contents under `.shogun/clonedeps/repos/`.

---

## 2. Safety Guards & Confirmation Gates

- Check whether `.shogun/clonedeps.json` already satisfies the request before asking the Librarian.
- Reject non-HTTPS repository URLs (e.g. `file://`, SSH URLs, or URLs with embedded credentials) unless explicitly instructed otherwise.
- Never execute dependency build, install, test, or lifecycle scripts from the cloned repositories.
- Seek Lord's confirmation before performing network clone operations unless requested to clone immediately:
  ```bash
  bash scripts/lord_ask.sh "Clone dependency source <repo> at ref <ref>?" "Yes" "No"
  ```

---

## 3. Workflow Guide

### Step 1: Query the Librarian
Ask `@librarian` to discover dependencies and recommend source repositories. Use the following prompt format:
```md
Analyze this project first, then recommend remote source repositories that would help a developer debug or extend it.
Include repo name, repo URL, recommended ref/tag/commit, and why cloning it would help.
Keep it small (0-3 recommendations).
```

### Step 2: Verification
1. Verify refs using `git ls-remote` where practical.
2. Prefer pinned tags or specific commit SHAs.

### Step 3: Clone Sources
1. Derive a safe directory name from the repository owner and name. For example, `https://github.com/opencode-ai/opencode.git` becomes `opencode-ai__opencode`.
2. Clone without submodules, using shallow clone where practical:
   ```bash
   git clone --depth 1 --branch <ref> <repoUrl> .shogun/clonedeps/repos/<safe-repo-name>
   ```
3. Update `.shogun/clonedeps.json`.

### Step 4: Update AGENTS.md
After successful cloning, update the `AGENTS.md` file in the repository root to document the cloned dependencies:

```markdown
## Cloned Dependency Source

Read-only dependency source repositories are available under
`.shogun/clonedeps/repos/` for inspection. Do not edit these clones.

- `.shogun/clonedeps/repos/<safe-name>/` — `<repo>` at `<ref>`; <one sentence on why this source is useful>.
```

---

## 4. Cleanup

When the user asks to clean cloned dependencies, remove:
- `.shogun/clonedeps/repos/`
- The managed ignore blocks from `.gitignore`

Seek approval before removing `.shogun/clonedeps.json` or editing `AGENTS.md` contents.
