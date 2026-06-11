# Ashigaru Task Guidelines

This reference guides how Karo writes task specifications in `queue/tasks/ashigaru{N}.yaml` and how Ashigaru performs them.

## Designing the Task (Karo's Duty)

When writing the `description` and `context` fields in the task YAML, Karo must ensure the following are included:

1. **Clear Scope:** Explicitly specify which files to create/modify and what patterns to follow.
2. **Acceptance Criteria:** Write a clear list of testable conditions. Every subtask must satisfy at least one acceptance criterion of the parent command.
3. **No Ambiguity:** Provide clear parameters (e.g., suite names, keys, paths). Do not let Ashigaru guess.
4. **Verification Requirements:** Instruct the Ashigaru on how to run tests or build verification commands.

---

## Execution Expectations (Ashigaru's Duty)

Upon receiving a task, the Ashigaru worker must adhere to the following rules:

### 1. Before Starting Work (Context Check)
- Read the entire task description and target files.
- If requirements, dependencies, or paths are unclear, **stop and ask immediately** via an inbox message to Karo. Do not make assumptions.

### 2. Coding Best Practices
- **Single Responsibility:** Ensure any new file created has one clear responsibility.
- **Code Conformity:** Follow existing patterns in the codebase. Write clean, idiomatic code.
- **No Over-Engineering (YAGNI):** Only build what was requested in the task description. Do not add extra features.

### 3. Testing and Verification
- Write comprehensive unit/integration tests for the new code.
- Run the build and test suite to verify everything passes with 0 failures and 0 skips (remember: **SKIP = FAIL**).

### 4. Self-Review Checklist
Before setting status to `done` and writing the report, check:
- **Completeness:** Did I implement every requirement in the description?
- **Quality:** Are variable and function names clear and accurate?
- **Safety:** Did I avoid running any prohibited commands (destructive operations)?

---

## Report Format

Ashigaru must report deliverables in `queue/reports/ashigaru{N}_report.yaml` in this format:
- **status:** `done` (or `done_with_concerns`, `blocked`, `needs_context`)
- **result.summary:** A 1-2 sentence description of what was completed.
- **result.files_modified:** List of absolute file paths modified.
- **result.notes:** Any integration details, compiler settings, or testing flags used.
