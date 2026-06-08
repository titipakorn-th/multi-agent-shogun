# Agent Self-Watch Test Specification

| Item | Content |
|---|---|
| Document ID | ASW-SPEC-001 |
| parent_cmd | cmd_107 |
| task_id | subtask_107b |
| Creation Date | 2026-02-09 |
| Reference Requirements | reports/requirements_agent_selfwatch.md |
| Target | Agent self-watch Phase 1-3 (TDD Step 2) |

---

## 1. Purpose

This specification decomposes the FR/NFR defined in `reports/requirements_agent_selfwatch.md` into test cases verifiable before implementation.

Goal:
- Define test case IDs and expected values for each FR/NFR
- Clarify unit test scope (inbox processing, monitoring, concurrency control, escalation)
- Isolate E2E scope as "Lord's responsibility"

---

## 2. Test Levels and Roles

| Level | Name | Primary Owner | Execution Environment | Purpose |
|---|---|---|---|---|
| L1 | Unit | Ashigaru (This task) | bats + bash + python3 | Function / logic verification |
| L2 | Integration | Karo | L1 + tmux + inotify-tools | Integration verification of watcher/CLI boundary |
| L3 | E2E | Lord | Production tmux environment | Final confirmation including the command hierarchy |

Notes:
- `SKIP=0` is mandatory. If SKIP is 1 or more, it is treated as "incomplete".
- This specification targets Step 2. Implementation and execution occur in Step 3 and later.

---

## 3. FR Test Cases

### 3.1 Phase 1

| TC ID | Requirement | Level | Perspective | Expected Value |
|---|---|---|---|---|
| TC-FR-001 | FR-001 Startup Unread Recovery | L1 | Startup behavior | `process_unread_once` runs once immediately after startup, processing all unread messages with 0 missed |
| TC-FR-002 | FR-002 self-watch Monitoring | L1/L2 | inotify+timeout | Unread messages are detected via timeout fallback even if inotify fails |
| TC-FR-003 | FR-003 Type-specific Processing | L1 | Message type routing | `task_assigned`/`clear_command`/`model_switch` route to the correct processing lanes |
| TC-FR-004 | FR-004 Concurrency & Integrity | L1/L2 | flock+atomic | YAML does not corrupt and read updates do not roll back during concurrency |
| TC-FR-005 | FR-005 post-task inbox check | L1/L3 | Post-completion behavior | Unread messages are checked immediately after completion; does not transition to idle if unread exist |
| TC-FR-006 | FR-006 Observability Metrics | L1 | Metrics logging | `unread_latency_sec`/`read_count`/`estimated_tokens` can be calculated |
| TC-FR-007 | FR-007 Feature Flag Migration | L1/L2 | Flag switching | Phase switching is functional; reverts to legacy compatibility mode when OFF |

### 3.2 Phase 2

| TC ID | Requirement | Level | Perspective | Expected Value |
|---|---|---|---|---|
| TC-FR-008 | FR-008 Stop Normal Nudges | L2 | Suppress send-keys | `send-keys inboxN` is not executed for normal messages |
| TC-FR-009 | FR-009 Special Command Compatibility | L1/L2 | Compatibility | Preserves legacy behavior for `clear_command`/`model_switch` |
| TC-FR-010 | FR-010 summary-first | L1 | Fast-path | Avoids full read when unread_count=0; only performs full read when necessary |

### 3.3 Phase 3

| TC ID | Requirement | Level | Perspective | Expected Value |
|---|---|---|---|---|
| TC-FR-011 | FR-011 send-keys as Last Resort | L2/L3 | Recovery only | Zero send-keys usage during normal operations; triggers only during anomalies |
| TC-FR-012 | FR-012 Redefining Thresholds | L1/L2 | Escalation | Excessive recovery loops do not occur according to thresholds/cooldown |
| TC-FR-013 | FR-013 Alternative IPC Hook | L1 | Extensibility | PoC can be introduced/withdrawn without breaking the authoritative YAML |

### 3.4 Common

| TC ID | Requirement | Level | Perspective | Expected Value |
|---|---|---|---|---|
| TC-FR-014 | FR-014 Backward Compatibility IF | L1/L2 | Interface | Preserves inbox YAML schema / inbox_write IF / message type compatibility |
| TC-FR-015 | FR-015 Impl / CI Link | L1/L2 | CI Integration | spec -> bats -> CI are traceable with the same IDs |

---

## 4. NFR Test Cases

| TC ID | Requirement | Level | Perspective | Expected Value |
|---|---|---|---|---|
| TC-NFR-001 | NFR-001 Reliability | L2/L3 | Prevent unread loss | Zero loss of unread messages; reprocessing is idempotent |
| TC-NFR-002 | NFR-002 Backward Compatibility | L1/L2 | Regression | No regressions with existing inbox_write/existing YAML |
| TC-NFR-003 | NFR-003 Token Efficiency | L1/L2 | No Idle Read | Zero full read when idle; estimated tokens/day is within threshold |
| TC-NFR-004 | NFR-004 Operability | L2 | Disaster Recovery | Recovery is possible using only the runbook; 100% reproducibility |
| TC-NFR-005 | NFR-005 Portability | L2/L3 | Env differences | No contradictions in WSL2/Linux/Docker/SSH strategies |
| TC-NFR-006 | NFR-006 Observability | L1 | Logs / metrics | Primary metrics are continuously collected |
| TC-NFR-007 | NFR-007 Maintainability | L1 | Responsibility separation | Watcher responsibilities do not bloat; normal and recovery paths are separated |
| TC-NFR-008 | NFR-008 Testability | L1 | Traceability | No missing mappings in FR/NFR -> TC -> bats lookup table |

---

## 5. Unit Test Scope (Step 3 Target)

## 5.1 inbox Processing

- UT-INBOX-001: unread_count calculation (empty / read-only / mixed)
- UT-INBOX-002: Type-specific routing (task_assigned / clear / model / unknown)
- UT-INBOX-003: Idempotency of read status updates (no corruption on reprocessing same message)
- UT-INBOX-004: Mandatory execution of `process_unread_once` on startup

Expected Values:
- 0 unread calculation error
- Does not terminate abnormally on unknown types
- YAML structure remains valid after read status updates

## 5.2 Monitoring (self-watch)

- UT-WATCH-001: Process startup triggered by inotify events
- UT-WATCH-002: Fallback recovery via timeout
- UT-WATCH-003: No Idle Read rule (full read prohibited when idle)

Expected Values:
- Recover unread messages via timeout even when event is lost
- Do not perform unnecessary full read when idle

## 5.3 Concurrency Control

- UT-LOCK-001: Safe retry on flock conflict
- UT-LOCK-002: No YAML corruption after atomic replace
- UT-LOCK-003: Consistency during simultaneous updates (no rollbacks)

Expected Values:
- Maintain consistency even on lock conflict
- Do not generate corrupt YAML files

## 5.4 Escalation

- UT-ESC-001: Phase 1/2/3 transitions based on unread age
- UT-ESC-002: Suppress `/clear` hammer via cooldown
- UT-ESC-003: Defer nudge when busy
- UT-ESC-004: Skip nudge transmission when self-watch is active

Expected Values:
- Trigger only expected actions based on temporal conditions
- No misdirected transmissions under busy/self-watch conditions

---

## 6. Integration Test Scope (managed by Karo)

- IT-001: Coordination of watcher + agent + inbox_write
- IT-002: Routing by CLI type (claude / codex / copilot)
- IT-003: Eliminating send-keys on normal path (Phase 2)
- IT-004: Final recovery during fault injection (Phase 3)

Expected Values:
- Resolve boundary inconsistencies not visible in unit tests
- Reproducible behavior during inter-agent operations

---

## 7. E2E Scope (managed by Lord)

E2E in this specification is owned by **the Lord**; Karo and Ashigaru will not perform it.

Targets:
- E2E-001: Complete flow: Shogun -> Karo -> Ashigaru
- E2E-002: Long-term operation including redo/clear
- E2E-003: Stability and unread congestion under 9-agent parallel execution

Expected Values:
- Operational feasibility within organizational hierarchy
- No excessive increase in /clear dependency
- Primary metrics remain within acceptable bounds

---

## 8. Prerequisites (Preflight)

- `bash`, `python3`, `bats` are available
- For L2+, `tmux` and `inotifywait` are available
- Read/write access to test directories under `queue/tests`

When prerequisites are not met:
- Do not run the test; record the reason for unmet prerequisites
- Reporting as SKIP is prohibited (treated as incomplete)

---

## 9. FR/NFR Trace Operational Rules

- Embed TC IDs in bats test names (e.g. `TC-FR-001`)
- Record PASS/FAIL by TC ID in test reports
- Maintain at least 1 TC per requirement (no omissions)

---

## 10. E2E Execution Runbook (For Lord, Sequential)

This section contains execution procedures to satisfy requirements for `cmd_117` "Lord's preparation to execute E2E tests".
The order of steps is fixed. If any step fails, diagnose and recover according to the failure diagnostics before resuming.

| Prerequisites | Steps | Expected Results | Failure Diagnostics | Artifacts |
|---|---|---|---|---|
| Step 1: tmux foundation started | Run `tmux ls` and check for `shogun` and `multiagent` sessions. | The 2 sessions exist and have not terminated. | If sessions are missing, run `bash scripts/shohou/start_or_resume.sh` and check again. | `tests/results/e2e_cmd117_step01_tmux_sessions.txt` |
| Step 2: Karo/Ashigaru monitoring processes running | Run `pgrep -af \"inbox_watcher.sh\|inotifywait\"`. | Monitoring processes are confirmed. | If monitoring is not found, check recent errors in `logs/` after restarting watcher. | `tests/results/e2e_cmd117_step02_watchers.txt` |
| Step 3: Unread messages are not congested before starting E2E | Run `for f in queue/inbox/*.yaml; do c=$(awk '/read: false/{n++} END{print n+0}' \"$f\"); echo \"$(basename \"$f\"):$c\"; done`. | Unread messages for target agents are within acceptable limits (ideally 0). | If unread > 0, complete normal processing first, then repeat Step 3. | `tests/results/e2e_cmd117_step03_unread_baseline.txt` |
| Step 4: Launch E2E-001 (Shogun -> Karo -> Ashigaru flow) | Send `bash scripts/inbox_write.sh karo \"cmd117_e2e_probe: chain test\" cmd_new shogun` and confirm Karo processes it and deploys Ashigaru tasks. | Karo inbox is processed, and tasks are distributed to at least one Ashigaru. | If no change for 2+ minutes, check `queue/inbox/karo.yaml` and `logs/inbox_watcher/` and verify Phase 2/3 escalation conditions. | `tests/results/e2e_cmd117_step04_chain.md` |
| Step 5: Verify E2E-002 (redo/clear) | Send `clear_command` to target Ashigaru (e.g. `bash scripts/inbox_write.sh ashigaru6 \"cmd117_e2e_probe redo\" clear_command karo`) and verify recovery flow. | After `/clear`, target Ashigaru reloads task YAML and recovers without stopping. | If recovery fails, check `read` status update in `queue/inbox/ashigaru6.yaml` and task status to diagnose potential race conditions. | `tests/results/e2e_cmd117_step05_redo_clear.md` |
| Step 6: Verify E2E-003 (9-agent parallel stability) | Run `tmux list-panes -t multiagent -F '#{pane_index}:#{pane_current_command}'` and repeat Step 3 to check unread congestion. | Unread messages do not continuously accumulate even during high concurrency. | If congestion increases, check for misconfigured busy-skip/cooldown conditions and collect relevant agent logs. | `tests/results/e2e_cmd117_step06_parallel_health.txt` |
| Step 7: Record E2E completion status | Document PASS/FAIL, blockers, and retry plans for E2E-001/002/003 in `tests/results/e2e_cmd117_readiness.md`. | Record complete evaluation log so that Lord can immediately decide next actions. | If logic is insufficient, collect missing proof first before finalizing the record. | `tests/results/e2e_cmd117_readiness.md` |

---

This satisfies `cmd_107` AC-2 (Test specification completion) and `cmd_117` (E2E executable procedure preparation).
