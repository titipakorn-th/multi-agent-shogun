---
name: skill-creator
description: |
  Designing, creating, validating, and reviewing Claude Code skills (SKILL.md).
  Adheres to the official Anthropic guide (2026-03). Used for creating new skills,
  improving existing skills, quality checking descriptions, and designing trigger tests.
  Triggered by: "create skill", "design skill", "make SKILL.md", "review skill".
  Do NOT use for: Executing or calling skills (which is handled by the respective skill itself).
argument-hint: "[skill-name or description]"
---

# Skill Creator — Claude Code Skills Design & Generation v2.0

Fully compliant with the official Anthropic "The Complete Guide to Building Skills for Claude" (2026-03).
Also compatible with the Agent Skills Open Standard (agentskills.io) to design skills that function on AI tools other than Claude Code.

## North Star

**Designing and creating high-quality, reusable skills in the shortest time.**
Value of a Skill = Trigger Precision x Output Quality x Maintainability.

## Frontmatter Reference (All Fields)

```yaml
---
# === Required Fields ===
name: skill-name              # kebab-case, max 64 chars. Defaults to directory name if omitted
                               # Names containing "claude" / "anthropic" are forbidden (reserved words)
description: |                 # [Most Critical] The sole basis for trigger judgment. Under 1024 characters
  Specify What + When. Include trigger words.
  Use negative triggers (Do NOT use for...) to prevent false triggers.

# === Optional Fields ===
argument-hint: "[target]"      # Hint displayed during auto-complete. For skills with arguments
disable-model-invocation: false # true = Trigger manually with /name only (for skills with side effects)
user-invocable: true           # false = Hidden from / menu (for background knowledge skills)
allowed-tools: Read, Grep, Bash # Allowed tools. Specifying also restricts them. Omitted = Inherits all tools
model: sonnet                  # Model specification when executing skill (Omitted = Inherit from parent)
context: fork                  # fork = Isolated execution in subagent
agent: general-purpose         # Agent type when forked: Explore, Plan, general-purpose
license: MIT                   # For OSS skills. MIT, Apache-2.0 etc.
compatibility: |               # Environment requirements (1-500 characters)
  Claude Code + tmux + WSL2
metadata:                      # Custom metadata
  author: your-name
  version: 1.0.0
  mcp-server: server-name      # For MCP integration skills
hooks:                         # In-skill hook definition
  PostToolUse:
    - matcher: "Edit|Write"
      hooks:
        - type: command
          command: "./scripts/lint.sh"
---
```

### Frontmatter Security Constraints

- XML angle brackets `< >` are **forbidden** (prevents prompt injection)
- Using "claude" / "anthropic" in `name` is forbidden (reserved words)
- Frontmatter is expanded inside the system prompt → malicious content is dangerous

## Description Design (Most Critical — Determines Trigger Quality)

The description is the **sole basis** Claude Code uses to determine whether to use this skill.
The main body is not used for trigger determination. **Max 1024 characters**.

### Structure: `[What] + [When] + [Negative trigger]`

```yaml
# Good — Specific, triggers included, negative triggers included
description: |
  Analyzes Figma design files and generates developer hand-off documents.
  Triggered when a .fig file is uploaded, or when "design specs", "component docs",
  or "design to code" is requested.
  Do NOT use for: General image processing or UI design (use the interface-design skill instead).

# Bad — Vague, no triggers
description: Document processing
```

### 7-Item Checklist

| # | Check | Bad Example | Good Example |
|---|---------|-------|-------|
| 1 | What: Specify clearly what it does | "Document processing" | "Extract tables from PDF and convert to CSV" |
| 2 | When: Specify clearly when to use | (none) | "Used in data analysis workflow" |
| 3 | Trigger words included | (none) | "Triggered by 'article QC' or 'validation'" |
| 4 | Specific action verbs | "Manage" | "Extract, convert, validate" |
| 5 | Length: Under 1024 chars | 1 word or too long | 2-3 sentences of summary + trigger + exclusion |
| 6 | Differentiate from existing skills | Overlaps with other skills | Clearly define unique scope |
| 7 | Negative triggers | None (risk of false triggers) | "Do NOT use for: ..." |

### Description Debugging Method

If it does not trigger, ask Claude:
> "When would you use the [skill-name] skill?"

Claude will answer by quoting the description. This helps identify missing elements.

## Three Use Case Categories

Identify which category the skill belongs to before designing it:

| Category | Purpose | Example |
|---------|------|-----|
| **1. Document & Asset Creation** | Artifact generation (PDF, code, articles, etc.) | shogun-seo-writer |
| **2. Workflow Automation** | Step-by-step automation | shogun-git-release |
| **3. MCP Enhancement** | MCP tools + workflow knowledge | shogun-github-reviewer |

## Five Design Patterns

### Pattern 1: Sequential Workflow

Dependencies exist between steps. Validation at each step + rollback on failure.

### Pattern 2: Multi-Service Coordination

Phase separation + data hand-off + validation between phases.

### Pattern 3: Iterative Refinement (Quality Loop)

Generation → validation script → improvement → re-validation. Stop at quality threshold.

### Pattern 4: Context-aware Selection (Conditional Branching)

Dynamically select tools/methods based on context. Explain reasoning to user.

### Pattern 5: Domain Intelligence (Embedded Expertise)

Embed domain-specific rules into logic. Compliance & audit trails.

## Dynamic Features

### Argument Substitution

```
/my-skill marriage kekkon
```
- `$ARGUMENTS` → `marriage kekkon` (all arguments)
- `$0` → `marriage` (1st argument)
- `$1` → `kekkon` (2nd argument)

If `$ARGUMENTS` is not used in the main body, it is automatically appended to the end.

### Dynamic Context `!`command``

Execute a shell command before the skill is loaded and embed the results:

```markdown
## Current Branch
!`git branch --show-current`

## Recent Commits
!`git log --oneline -5`
```

## Execution Patterns

### Pattern A: Inline Execution (Default)

Executed directly within the main conversation. For guideline-oriented or short tasks.

### Pattern B: Fork Execution (Isolation)

Runs a subagent via `context: fork`. For heavy processing or large output.
**Note**: Do not use fork for skills that only contain guidelines. Subagents require explicit tasks.

### Pattern C: Manual Only (With Side Effects)

Disable Claude's automatic trigger via `disable-model-invocation: true`. Only launchable via /name.

## File Structure

```
~/.claude/skills/skill-name/
├── SKILL.md              # Required. Max 5,000 words (~500 lines). Case-sensitive
├── scripts/              # Optional. Validation or execution scripts
├── references/           # Optional. Detailed API specifications and rules
├── assets/               # Optional. Templates, fonts, icons
└── examples/             # Optional. Input/output samples
```

### Naming Rules
- Folder name: **kebab-case** (`notion-project-setup` ✅ / `Notion_Setup` ❌)
- `SKILL.md` is strictly case-sensitive (`skill.md` ❌ / `SKILL.MD` ❌)
- **README.md is Forbidden** (inside the skill folder). Place documentation in SKILL.md or references/

### Progressive Disclosure (Three-Layer Structure)

| Layer | Content | Loading Trigger |
|---|------|-----------------|
| L1 | YAML frontmatter | **Always** (Inside the system prompt) |
| L2 | SKILL.md body | When judged relevant to the skill |
| L3 | references/, scripts/ | Referenced by Claude as needed |

The main SKILL.md body must be **under 5,000 words**. Move details into references/.

## Testing Strategy (Three Areas)

### 1. Triggering Test

Should trigger:
- "I want to make a new skill"
- "Review of SKILL.md"
- "Design a skill"

Should NOT trigger:
- "Run the skill"
- "Tell me the weather"
- "Write some code"

### 2. Functional Test
- Whether correct output is generated
- Whether error handling works
- Whether edge cases are handled

### 3. Performance Test
Comparison with/without the skill:
- Number of tool calls
- Token consumption
- Number of user rework cycles

**Pro Tip**: Iterate on one difficult task first. Convert the successful approach into a skill.
Expand test cases afterward.

## Creation Workflow

When creating a skill, perform the following in sequence:

1. **Identify Use Case**: Define 2-3 concrete scenarios
2. **Determine Category**: Document / Workflow / MCP Enhancement
3. **Design Description**: 7-item check + negative trigger + under 1024 characters
4. **Check Duplication with Existing Skills**: Verify with `ls ~/.claude/skills/`
5. **Choose Execution Pattern**: Inline / fork / manual only
6. **Design allowed-tools**: Restrict to absolute minimum necessary
7. **Design Arguments**: Document `$0`, `$1` in `argument-hint`
8. **Dynamic Context**: Plan data to pre-fetch via `!`command``
9. **Write SKILL.md**: Under 5,000 words. Place critical instructions at the top
10. **Script Validation**: Place critical checks in scripts/ (code is deterministic, language is non-deterministic)
11. **Testing**: 3 areas of Triggering / Functional / Performance
12. **Installation**: Place at `~/.claude/skills/skill-name/`

## Validation Script Recommendation

**Most Critical Tip from Official Guide**: Implement critical validation via scripts.
Code is deterministic, whereas language interpretation is non-deterministic.

```bash
# Example of scripts/validate.sh
#!/bin/bash
# Quality check output file
if [ $(wc -w < "$1") -lt 100 ]; then
  echo "ERROR: Output too short (min 100 words)"
  exit 1
fi
```

## Sengoku Shogun System Rules

- Save destination: `~/.claude/skills/shogun-{skill-name}/`
- Skill candidates are discovered by Ashigaru → reported to Shogun via Karo → designed by Shogun → approved by Lord → created by Karo
- Skills requiring integration with the Shogun System (such as inbox_write, task YAML) must include Bash in allowed-tools
- Specify north_star in the **main body**, not in frontmatter (custom fields in frontmatter are ignored by Claude Code)

## Anti-Patterns

| Anti-Pattern (NG) | Reason | Alternative |
|----|------|---------|
| SKILL.md exceeds 5,000 words | Explodes loading costs, degrades response quality | Extract into references/ |
| Vague description | Fails to trigger or triggers falsely | What + When + Negative trigger |
| description exceeds 1024 characters | Exceeds frontmatter limits | Keep concise, under 3 sentences |
| `< >` in description | Security violation | Do not use angle brackets |
| No negative triggers | False triggers among similar skills | Add "Do NOT use for: ..." |
| `context: fork` + guidelines only | Subagent will lose its way | Inline execution |
| both `disable-model-invocation` and `user-invocable: false` | No one can trigger the skill | Set only one of them |
| allowed-tools unspecified for heavy tasks | Unintended tool usage | List only required tools |
| Custom fields in frontmatter | Ignored by Claude Code | Describe in main body Markdown |
| README.md in skill folder | Violation of specifications | SKILL.md or references/ |
| More than 50 active skills simultaneously | Standard context bloat | Selectively enable skills |
