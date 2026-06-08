# context Directory

Directory for managing project-specific context.

## Purpose
- Store knowledge and decisions for each project
- Share information across sessions
- Handover instructions to new participants (Ashigaru)

## File Structure
```
context/
  README.md           ← This file
  {project_id}.md     ← Project-specific context file
```

## How to Use

### Adding a New Project
1. Create `context/{project_id}.md`
2. Fill it out according to the template below

### Starting Work
1. Read `memory/global_context.md` (System-wide configuration)
2. Read `context/{project_id}.md` (Project-specific information)

## Template

```markdown
# {project_id} Project Context
Last Updated: YYYY-MM-DD

## Basic Info
- **Project ID**: {project_id}
- **Official Name**: {name}
- **Path**: {path}
- **Notion URL**: {url} (if any)

## Overview
{1-2 sentences summarizing the project}

## Tech Stack
- Language:
- Framework:
- Database:

## Important Decisions
- {Decision 1}
- {Decision 2}

## Milestones
- **Deadline**: YYYY-MM-DD ({Event Name})

## Progress
- [x] Completed tasks
- [ ] Remaining tasks

## Notes
{Project-specific notes/cautions}
```

## Update Rules
- Update immediately when important decisions are made
- Always update the date
- Delete obsolete information (keep it simple)
