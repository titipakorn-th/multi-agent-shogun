---
name: shogun-feature-spec
description: |
  Guides the Shogun in gathering project scope, core features, and constraints from the Lord (user),
  and generating a comprehensive feature specification and development roadmap document.
  Triggered when starting a new software development project, defining scope/requirements,
  or when the user requests "create feature spec", "define project scope", "ask about project requirements",
  "gather feature specs", or "build project roadmap".
  Do NOT use for: Writing application code directly, executing task queues without scope definition, or running build checks.
---

# /shogun-feature-spec - Software Development Project Scope Elicitation & Roadmap

## North Star
**To establish a clear, structured, and agreed-upon project scope and roadmap before executing development, avoiding scope creep and optimizing model routing.**

## When to Use
- When the Lord requests to start a new software project or scope a feature.
- When requirements are vague, underspecified, or lack concrete technical parameters.
- Prior to writing commands for Karo in `queue/shogun_to_karo.yaml`.
- When asked to "create feature spec", "define project scope", "gather feature specs", or "build project roadmap".

## The Process

### Step 1: Check Telegram Configuration
Read `config/telegram.env` to check if Telegram bot credentials are configured:
- **Telegram Enabled**: Use `scripts/telegram_ask.py --question "<Q>" --options "<Opts>"` to ask the Lord interactive, multiple-choice or free-text questions.
- **Telegram Disabled**: List the questions clearly in the terminal and write them to the `🚨 Action Required` section of `dashboard.md`.

### Step 2: Elicit Project Scope
Query the Lord (user) on the following key areas. For interactive questions, ask them sequentially or as a single clear checklist depending on urgency:
1. **Basic Info**: Project ID (short slug, e.g. `voice_app`) and Official Name.
2. **North Star**: The core business goal or problem the software solves.
3. **Core Features (MVP)**: Top 3-5 critical features required for the first release.
4. **Tech Stack & Platform**: Preferred language, frameworks, target OS/platforms, databases, and dependencies.
5. **Key Constraints**: Security, offline support, API limits, performance, or memory constraints.
6. **Milestones**: Breakdown of phases (e.g. Phase 1: MVP Foundation, Phase 2: Core Logic, Phase 3: UX & QA).

### Step 3: Generate the Feature Spec & Roadmap Document
Create a new project context file at `context/{project_id}.md` using the following standardized layout:

```markdown
# {project_id} Project Context & Roadmap
Last Updated: YYYY-MM-DD

## Basic Info
- **Project ID**: {project_id}
- **Official Name**: {official_name}
- **Path**: {workspace_path}
- **Priority**: {High/Medium/Low}
- **Status**: Planning

## Overview
{1-2 sentence description of the app}

## North Star
{The core business/user goal}

## Tech Stack
- Platform: {iOS/Web/Android/etc.}
- Language: {Swift/Rust/JS/etc.}
- Framework: {SwiftUI/React/etc.}
- Database/Storage: {SQLite/AppGroup/etc.}

## Key Features & Requirements
1. **Feature 1**: Description and success criteria
2. **Feature 2**: Description and success criteria
3. **Feature 3**: Description and success criteria

## Architecture & Constraints
- **Constraint/Optimization 1**: Detail how to handle it
- **Constraint/Optimization 2**: Detail how to handle it

## Roadmap & Progress
- [ ] **Phase 1: Foundation (MVP)**
  - [ ] Task 1.1: Setup and scaffolding
  - [ ] Task 1.2: Core implementation of Feature 1
- [ ] **Phase 2: Core Features & Logic**
  - [ ] Task 2.1: Implement Feature 2
  - [ ] Task 2.2: Implement Feature 3
- [ ] **Phase 3: Integration & QA**
  - [ ] Task 3.1: Unit/Integration tests
  - [ ] Task 3.2: Final verification and build checks
```

### Step 4: Record for Final Approval
Add a notification under `dashboard.md` `🚨 Action Required` pointing to the newly generated `context/{project_id}.md` file.
Once the Lord gives the final approval, the Shogun will decompose the Phase 1 tasks and begin feeding them to Karo in `queue/shogun_to_karo.yaml`.
