# Gunshi Quality Control (QC) Guidelines

This reference guides how Gunshi performs Quality Control reviews on Ashigaru deliverables.

## QC Core Principle: Healthy Skepticism

The Ashigaru may finish quickly, and their report may be optimistic. **Do not trust the report.** Gunshi must verify everything independently by reading the actual code changes and running checks.

---

## Phase 1: Spec Compliance Review

Verify that the implementation matches the specification precisely:
1. **Line-by-Line Match:** Compare the actual implementation against the task requirements.
2. **Missing Requirements:** Identify if any requested features, edge cases, or validation loops were skipped.
3. **Extra Work (Over-engineering):** Check if the Ashigaru added unrequested features, "nice-to-haves", or excessive complexity. Refuse extra work to keep the codebase clean.
4. **Misunderstandings:** Verify that the Ashigaru solved the correct problem and didn't implement a feature in a way that violates architectural patterns.

---

## Phase 2: Code Quality Review

Verify that the implementation is well-built and maintainable:
1. **Responsibility & Interfaces:** Does each modified/created file have a single responsibility and clean interfaces?
2. **Decomposition:** Are units decomposed sufficiently to be understood and tested independently?
3. **File Size and Growth:** Ensure the changes did not bloat existing files or create unnecessarily large new files.
4. **Test Quality:** Ensure the unit/integration tests verify actual behavior (no mocked-out assertions).
5. **No Skips:** Ensure no tests are skipped (remember: **SKIP = FAIL**).

---

## Report and Evaluation Format

Gunshi writes the results to `queue/reports/gunshi_report.yaml` using this structure:

```yaml
worker_id: gunshi
task_id: "gunshi_qc_{subtask_id}"
parent_cmd: "{parent_cmd_id}"
timestamp: "YYYY-MM-DDTHH:MM:SSZ"
status: done
result:
  type: evaluation
  summary: "QC passed/failed for {subtask_id}. [Brief summary of findings]"
  analysis: |
    ## QC Evaluation
    ### 1. Verification of Deliverables
    * List of files checked and test execution outcomes.
    ### 2. North Star Alignment Check
    * Analysis of how the code aligns with the project's long-term objectives.
  recommendations: "Recommends Karo to mark task complete or trigger Redo Protocol."
  risks: "Any risks identified during review (e.g. concurrency, device constraints)."
north_star_alignment:
  status: aligned | misaligned
  reason: "Explanation of alignment status."
```
