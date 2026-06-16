# Sub-Project C: Shogun V2 Specialist Definitions Design

**Date:** 2026-06-16
**Sub-project:** C of 4 in the Specialist Agent Team Revamp
**Status:** Approved (pending spec self-review)
**Depends on:** Sub-A (topology), Sub-B (orchestrator), Sub-D (config schema)
**Enables:** None (final sub-project)

## Goal

Author the 7 specialist agent prompts (explorer, librarian, oracle, designer, fixer, observer, council), adapted from [oh-my-opencode-slim](https://github.com/alvinunreal/oh-my-opencode-slim) for multi-agent-shogun's YAML-inbox system. Each specialist replaces one of the existing ashigaru{N} slots (per sub-A's mapping) and is a read-only or lane-bounded read-write agent.

## Specialist Architecture Overview

All 7 specialists share a common prompt structure adapted from oh-my-opencode-slim:

### Common prompt sections (per specialist)

1. **Identity** — "You are {Role}, the {lane} specialist"
2. **Lane** — single-sentence scope statement
3. **Permissions** — read-only vs read-write
4. **When to be used** — explicit delegation triggers
5. **When NOT to be used** — guardrails against misrouting
6. **Tools/skills available** — from `roles.{role}.skills` in settings.yaml
7. **Multi-agent-shogun adaptations**:
   - Receive tasks via `queue/inbox/{role}.yaml`
   - Write reports via `queue/reports/{role}_report.yaml`
   - Notify orchestrator via `inbox_write.sh orchestrator ...`
   - No in-process delegation; orchestrator handles routing
   - `/clear` recovery via CLAUDE.md procedure
8. **Output format** — XML-style structured output
9. **Constraints** — read-only when applicable

### File locations

- `instructions/{role}.md` — source of truth for each specialist
- `scripts/build_instructions.sh` — generates per-CLI variants under `instructions/generated/{cli}-{role}.md`

## The 7 Specialists

### 1. Explorer — Fast codebase recon

- **Permissions:** read-only (`edit_deny: ["**/*"]`)
- **Lane:** "Where is X? Find Y. Which file has Z?"
- **Tools:** Grep, glob, AST-grep, file read
- **Behavior:** Fire multiple searches in parallel; return file paths with snippets
- **Output format:**
  ```xml
  <results>
    <files>
      - /path/to/file.ts:42 - brief description
    </files>
    <answer>Concise answer</answer>
  </results>
  ```
- **When to delegate:** Need to discover what exists before planning
- **When NOT:** Know the path; single specific lookup; about to edit the file

### 2. Librarian — External knowledge and library research

- **Permissions:** read-only
- **Lane:** Authoritative source for current library docs, API references, examples
- **Tools:** Web search, doc fetch (via skills), MCP for docs
- **Behavior:** Evidence-based answers; quote snippets; link to official docs
- **Output format:**
  ```xml
  <research>
    <sources>
      - https://docs.example.com/api - official reference
    </sources>
    <findings>Synthesized answer</findings>
  </research>
  ```
- **When to delegate:** Libraries with frequent API changes / unfamiliar library / edge cases
- **When NOT:** Standard usage / built-in language features

### 3. Oracle — Architecture, risk, debugging strategy, review

- **Permissions:** read-only
- **Lane:** Strategic advisor for high-stakes decisions and persistent problems
- **Tools:** All read tools (no web)
- **Behavior:** Direct, concise; provide actionable recommendations; acknowledge uncertainty
- **Output format:**
  ```xml
  <advice>
    <recommendation>Primary recommendation</recommendation>
    <alternatives>
      - Option A: tradeoff description
      - Option B: tradeoff description
    </alternatives>
    <reasoning>Brief rationale</reasoning>
  </advice>
  ```
- **When to delegate:** Major architectural decisions / persistent problems / high-risk refactors / code needs simplification / YAGNI review
- **When NOT:** Routine decisions / first bug fix attempt / tactical how vs strategic should

### 4. Designer — UI/UX design and polish

- **Permissions:** read+write (UI files only via permissions_override)
- **Lane:** Visual and interaction quality: layout, hierarchy, spacing, motion, affordances, responsive behavior
- **Tools:** Read, write, edit (UI files only)
- **Behavior:** Owns visual feel; weak at copywriting (orchestrator reviews copy after)
- **Output format:**
  ```xml
  <design>
    <intent>What the design achieves</intent>
    <changes>
      - file1.tsx: Layout changed from X to Y
      - file2.css: Added spacing token
    </changes>
    <interactions>Microinteraction notes</interactions>
  </design>
  ```
- **When to delegate:** User-facing interfaces needing polish / responsive layouts / design systems / animations
- **When NOT:** Backend/logic with no visual / quick prototypes

### 5. Fixer — Bounded implementation

- **Permissions:** read+write (implementation files via permissions_override)
- **Lane:** Fast execution specialist for well-defined tasks
- **Tools:** Read, write, edit, bash
- **Behavior:** Execute task spec; no research; no architectural decisions; tests when requested
- **Output format:**
  ```xml
  <summary>Brief summary</summary>
  <changes>
    - file1.ts: Changed X to Y
    - file2.ts: Added Z function
  </changes>
  <verification>
    - Tests passed: yes/no/skip
    - Validation: passed/failed/skip
  </verification>
  ```
- **When to delegate:** Non-trivial multi-file implementation / parallelizable work / scoped per folder
- **When NOT:** Needs discovery/research/decisions / single small change / requires design taste

### 6. Observer — Visual/media analysis

- **Permissions:** read-only
- **Lane:** Visual analysis specialist for images, PDFs, diagrams
- **Tools:** Read (for images/PDFs)
- **Behavior:** Isolates large image/PDF bytes from orchestrator context; returns concise structured text
- **Output format:**
  ```xml
  <observation>
    <elements>List of UI elements / text / layout features</elements>
    <relationships>Spatial relationships / hierarchy</relationships>
    <notes>Anything else relevant</notes>
  </observation>
  ```
- **When to delegate:** Need to analyze a multimedia file
- **When NOT:** Plain text files / files that need editing afterward
- **Important:** Always pass full file path in the prompt so observer can read it

### 7. Council — Multi-model consensus

- **Permissions:** read-only
- **Lane:** Multi-LLM consensus engine
- **Tools:** Read (and internal multi-model execution via MCP)
- **Behavior:** Runs multiple models in parallel, compares answers, resolves disagreements, produces final synthesized answer
- **Output format:**
  ```xml
  <council>
    <response>Synthesized final answer</response>
    <councillors>
      - model: sonnet
        answer: ...
      - model: opus
        answer: ...
    </councillors>
    <summary>Confidence level and reasoning</summary>
  </council>
  ```
- **When to delegate:** Critical decisions / high-stakes choices / ambiguous problems where disagreement is useful
- **When NOT:** Routine tasks / single specialist is the right tool
- **Multi-agent-shogun adaptation:** Council internally calls other models via MCP; orchestrator preserves structure when relaying to shogun

## Mapping to Existing Slots

Per sub-A's pane layout, each specialist occupies a specific pane slot:

| Specialist | Pane | Mapped from |
|------------|------|-------------|
| orchestrator | multiagent:ops.0 | (replaces karo) |
| fixer | multiagent:ops.1 | (replaces ashigaru1) |
| designer | multiagent:ops.2 | (replaces ashigaru4) |
| observer | multiagent:ops.3 | (replaces ashigaru6) |
| explorer | multiagent:research.0 | (replaces ashigaru1) |
| librarian | multiagent:research.1 | (replaces ashigaru2) |
| oracle | multiagent:research.2 | (replaces ashigaru3 + gunshi) |
| council | multiagent:research.3 | (replaces ashigaru7) |

Note: gunshi's review/QC role folds into oracle (deep review) + council (multi-model consensus). Ashigaru{N} roles are repurposed entirely.

## Testing

### Unit tests

- `test_specialist_prompts.sh` — verifies each `instructions/{role}.md` exists and has required sections (identity, lane, permissions, output format)
- `test_role_specific_skills.sh` — verifies each role's `skills` array in settings.yaml is referenced in its prompt
- `test_output_format.sh` — feeds sample tasks to each specialist (via fixture); verifies output matches XML schema
- `test_permissions.sh` — verifies read-only specialists cannot write; read-write specialists can edit their lane only

### Integration tests

- `test_specialist_to_orchestrator.sh` — specialist receives task via inbox, completes, writes report, orchestrator receives
- `test_cross_specialist.sh` — orchestrator dispatches explorer → fixer → designer in sequence; verifies data flow
- `test_observer_image.sh` — observer analyzes a fixture image, returns structured observation
- `test_council_consensus.sh` — council runs 3 models on a fixture question, returns synthesized report

### E2E tests

- Real cmd: "Add a new specialist agent named 'planner' between orchestrator and explorer" — exercises: orchestrator dispatch + explorer recon + oracle review + fixer implementation + designer docs
- Real cmd: "Review the design of the dashboard.md layout" — exercises: oracle review + designer critique + council consensus

## Migration

- All 7 `instructions/{role}.md` files created in one PR
- `scripts/build_instructions.sh` updated to generate `{cli}-{role}.md` variants (replacing existing `{cli}-{ashigaru|gunshi|karo}.md`)
- Existing test fixtures that reference ashigaru/karo/gunshi updated to use new role names
- Default `ashigaru{1-7}.md`, `gunshi.md`, `karo.md` are **archived** under `instructions/_archive/` for one release cycle, then removed
- Each specialist prompt ~150-300 lines (Adapted port from oh-my-opencode-slim)

## Out of Scope

- None — this is the final sub-project in the revamp

## Open Questions for Later Phases

1. Should `observer` have a special tool to extract image bytes in a streaming fashion, or rely on standard Read? Confirm during implementation.
2. Does council need a separate `councillor` sub-agent (per oh-my-opencode-slim) or can it call models directly? Confirm in implementation.
3. Should each specialist prompt include a "regression warning" referencing the 2026-02-13 incident? (orchestrator must never confuse roles with specialists).