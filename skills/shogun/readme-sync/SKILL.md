---
name: readme-sync
description: |
  Checks and executes synchronization between README.md (English) and README_ja.md (Japanese).
  Used to ensure both language versions are updated simultaneously when the README is modified.
  Triggered by: "README update", "README sync", "readme sync".
---

# /readme-sync - README English/Japanese Sync

## Overview

Detects differences between README.md (English) and README_ja.md (Japanese), adding missing sections and correcting numbered sequence offsets.

Workflow when modifying README:
1. Difference detection (automatically determines which version is newer)
2. Listing missing sections
3. Executing translation and additions
4. Consistency check of section numbers

## When to Use

- After editing the README (adding features, sections, changing structure)
- When asked to "update README", "sync README", or "readme sync"
- When asked to update the Japanese version after writing new features in the English README
- Consistency check of README before creating a PR

## Instructions

### Step 1: Difference Detection

Read both files and detect differences based on the following aspects:

```bash
# Read both files
Read README.md
Read README_ja.md
```

**Checklist Items:**

| Item | Verification Method |
|------|----------|
| Section Count | Do the number of `###` headers match? |
| Section Numbers | Are the serial numbers for numbered sections (e.g. `### ... 1.`, `### ... 2.`) correct? |
| File Structure | Do the file lists in the File Structure sections match? |
| Version Section | Do the `What's New` / `Shin-kinou` sections exist in both? |
| Collapse Content | Do the existences of `<details>` blocks match? |

### Step 2: Difference Report

Report the detected differences:

```
README Sync Check Results:

Missing from EN → JA:
- Section "Agent Status Check" is missing from the Japanese version
- lib/agent_status.sh is not listed in the File Structure
- v3.3.2 section is missing

Missing from JA → EN:
- (None)

Section Number Discrepancy:
- JA: Screenshot is number 5, but EN is number 6
```

### Step 3: Execution of Synchronization

Correct the differences. Translation rules:

| EN | JA (in README_ja.md) |
|----|-----|
| Agent Status Check | Eejento Kadou Kakunin |
| Screenshot Integration | Sukuriinshotto Renkei |
| Context Management | Kontekisuto Kanri |
| Phone Notifications | Sumaho Tsuuchi |
| Pane Border Task Display | Pein Boodaa Tasuku Hyouji |
| Shout Mode | Shauto Moodo (Sengoku Echo) |
| Event-Driven Communication | Ibento Kudou Tsuushin |
| Parallel Execution | Heiretsu Jikkou |
| Non-Blocking Workflow | Non Burokkingu Waakufuroo |
| Cross-Session Memory | Sesshon-kan Kioku |
| Bottom-Up Skill Discovery | Botomu Appu Sukiru Hakken |

**Translation Policy:**
- Keep technical terms as is (tmux, YAML, CLI, MCP, inotifywait, etc.)
- Do not translate commands inside code blocks
- Align output examples with the Japanese version (e.g., "Running" / "Idle" equivalents)
- Use the same emojis as the EN version

### Step 4: Final Consistency Check

After correction, verify the following:
1. Section counts in both files match
2. Serial numbers for numbered sections are correct
3. Entries in the file structure section match
4. Version sections exist in both

## Guidelines

- **EN is Authoritative**: New features are basically written in English first. Have the Japanese version follow it.
- **Preserve Japanese Custom Expressions**: Keep unique Japanese expressions like "Sengoku Echo" intact.
- **Do Not Make It One-Way**: Detect changes from EN to JA as well as JA to EN.
- **Automatic Section Renumbering**: If a section is inserted in the middle, increment all subsequent numbers.
- **Do Not Modify Inside Code Blocks**: Do not translate text inside code blocks of bash/yaml/markdown.
