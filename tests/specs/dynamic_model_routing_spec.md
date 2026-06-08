# Dynamic Model Routing Test Specification

| Item | Content |
|---|---|
| Document ID | DMR-SPEC-001 |
| Issue | #53 |
| Creation Date | 2026-02-17 |
| Reference Requirements | reports/requirements_dynamic_model_routing.md |
| Target | Phase 1-4 (TDD: Test-driven) |

---

## 1. Purpose

This specification decomposes the FR/NFR defined in `reports/requirements_dynamic_model_routing.md` into test cases verifiable before implementation.

Goal:
- Repeat test -> implement iteratively starting from Phase 1
- Proceed to the next Phase only after all tests for the current Phase PASS
- Guarantee no regressions with existing tests (`test_cli_adapter.bats`)

---

## 2. Test Levels and Roles

| Level | Name | Primary Owner | Execution Environment | Purpose |
|---|---|---|---|---|
| L1 | Unit | Ashigaru | bats + bash + python3 | Function / logic verification |
| L2 | Integration | Karo | L1 + tmux + inbox_write | Integration verification of model_switch coordination |
| L3 | E2E | Lord | Production tmux environment | Final confirmation of Bloom analysis -> switch -> execution |

Notes:
- `SKIP=0` is mandatory. If SKIP is 1 or more, it is treated as "incomplete".
- Phase 1 only has L1 tests. L2 is added from Phase 2 onwards.

---

## 3. Phase 1 Test Cases — capability_tier definition

### 3.1 FR-01: settings.yaml capability_tiers section

| TC ID | Requirement | Level | Input | Expected Value |
|---|---|---|---|---|
| TC-DMR-001 | FR-01 Basic Read | L1 | YAML with capability_tiers defined | No parsing errors, max_bloom of each model can be read |
| TC-DMR-002 | FR-01 Section Missing | L1 | YAML without capability_tiers defined | No errors, backward compatible behavior |
| TC-DMR-003 | FR-01 cost_group Read | L1 | YAML with capability_tiers defined | cost_group of each model can be read |

### 3.2 FR-02: get_capability_tier()

| TC ID | Requirement | Level | Input | Expected Value |
|---|---|---|---|---|
| TC-DMR-010 | FR-02 Spark -> 3 | L1 | model="gpt-5.3-codex-spark" | "3" |
| TC-DMR-011 | FR-02 Codex 5.3 -> 4 | L1 | model="gpt-5.3" | "4" |
| TC-DMR-012 | FR-02 Sonnet -> 5 | L1 | model="claude-sonnet-4-5-20250929" | "5" |
| TC-DMR-013 | FR-02 Opus -> 6 | L1 | model="claude-opus-4-6" | "6" |
| TC-DMR-014 | FR-02 Undefined Model -> 6 | L1 | model="unknown-model" | "6" |
| TC-DMR-015 | FR-02 Section Missing -> 6 | L1 | capability_tiers undefined | "6" |
| TC-DMR-016 | FR-02 Broken YAML -> 6 | L1 | Broken YAML | "6" |
| TC-DMR-017 | FR-02 Empty String -> 6 | L1 | model="" | "6" |

### 3.3 FR-03: get_recommended_model()

| TC ID | Requirement | Level | Input | Expected Value |
|---|---|---|---|---|
| TC-DMR-020 | FR-03 L1 -> Spark | L1 | bloom_level=1 | "gpt-5.3-codex-spark" |
| TC-DMR-021 | FR-03 L2 -> Spark | L1 | bloom_level=2 | "gpt-5.3-codex-spark" |
| TC-DMR-022 | FR-03 L3 -> Spark | L1 | bloom_level=3 | "gpt-5.3-codex-spark" |
| TC-DMR-023 | FR-03 L4 -> Codex 5.3 | L1 | bloom_level=4 | "gpt-5.3" |
| TC-DMR-024 | FR-03 L5 -> Sonnet | L1 | bloom_level=5 | "claude-sonnet-4-5-20250929" |
| TC-DMR-025 | FR-03 L6 -> Opus | L1 | bloom_level=6 | "claude-opus-4-6" |
| TC-DMR-026 | FR-03 Section Missing -> Empty | L1 | capability_tiers undefined | "" (empty string) |
| TC-DMR-027 | FR-03 Out of Range (0) -> exit 1 | L1 | bloom_level=0 | exit code 1 |
| TC-DMR-028 | FR-03 Out of Range (7) -> exit 1 | L1 | bloom_level=7 | exit code 1 |
| TC-DMR-029 | FR-03 Cost Priority | L1 | chatgpt_pro and claude_max same bloom | Model in chatgpt_pro group takes priority |

### 3.4 FR-04: get_cost_group()

| TC ID | Requirement | Level | Input | Expected Value |
|---|---|---|---|---|
| TC-DMR-030 | FR-04 Spark -> chatgpt_pro | L1 | model="gpt-5.3-codex-spark" | "chatgpt_pro" |
| TC-DMR-031 | FR-04 Opus -> claude_max | L1 | model="claude-opus-4-6" | "claude_max" |
| TC-DMR-032 | FR-04 Undefined -> unknown | L1 | model="unknown" | "unknown" |
| TC-DMR-033 | FR-04 Section Missing -> unknown | L1 | capability_tiers undefined | "unknown" |

### 3.5 NFR-01: Backward Compatibility

| TC ID | Requirement | Level | Perspective | Expected Value |
|---|---|---|---|---|
| TC-DMR-040 | NFR-01 No Regression in Existing Tests | L1 | test_cli_adapter.bats | All tests PASS after adding Phase 1 code |
| TC-DMR-041 | NFR-01 Old settings.yaml Compatibility | L1 | Both cli/capability_tiers missing | get_cli_type, get_agent_model, etc., return same results as before |

### 3.6 NFR-05: Testability

| TC ID | Requirement | Level | Perspective | Expected Value |
|---|---|---|---|---|
| TC-DMR-050 | NFR-05 Settings Injection | L1 | CLI_ADAPTER_SETTINGS | Test YAML can be injected |

### 3.7 NFR-06: Idempotency

| TC ID | Requirement | Level | Perspective | Expected Value |
|---|---|---|---|---|
| TC-DMR-055 | NFR-06 Consistent Sequential Calls | L1 | 2 calls with same input | get_recommended_model() returns same result |

---

## 4. Phase 2 Test Cases — Karo manual model_switch

### 4.1 FR-05: Karo manual model_switch

| TC ID | Requirement | Level | Perspective | Expected Value |
|---|---|---|---|---|
| TC-DMR-100 | FR-05 Switch Unnecessary Check | L1 | bloom=3, model=spark | Determined that switch is unnecessary |
| TC-DMR-101 | FR-05 Switch Necessary Check | L1 | bloom=4, model=spark | Determined that switch is necessary |
| TC-DMR-102 | FR-05 capability_tiers Missing | L1 | No section | Skip determination |
| TC-DMR-103 | FR-05 No bloom Field | L1 | No bloom_level in task YAML | Skip determination |

### 4.2 FR-06: Karo model_switch Decision Logic

| TC ID | Requirement | Level | Perspective | Expected Value |
|---|---|---|---|---|
| TC-DMR-110 | FR-06 Switch Within Same CLI | L2 | codex spark -> codex 5.3 | model_switch sent to inbox |
| TC-DMR-111 | FR-06 Switch Across CLI | L2 | bloom=5, Codex Ashigaru | Reassigned to Claude Ashigaru |
| TC-DMR-112 | FR-06 Skip Codex Ashigaru Switch | L2 | model_switch on Codex Ashigaru | Silent skip |
| TC-DMR-113 | FR-06 No Transmission if Switch Unnecessary | L2 | bloom=3, Spark Ashigaru | No inbox transmission |

### 4.3 NFR-02: Model Switch Latency

| TC ID | Requirement | Level | Perspective | Expected Value |
|---|---|---|---|---|
| TC-DMR-120 | NFR-02 Function Response Speed | L1 | get_capability_tier() | Within 500ms |
| TC-DMR-121 | NFR-02 Recommended Model Response Speed | L1 | get_recommended_model() | Within 500ms |

### 4.4 NFR-03: CLI Compatibility

| TC ID | Requirement | Level | Perspective | Expected Value |
|---|---|---|---|---|
| TC-DMR-130 | NFR-03 Codex Skip | L1 | CLI=codex, model_switch | No errors, processing skipped |
| TC-DMR-131 | NFR-03 Copilot Skip | L1 | CLI=copilot, model_switch | No errors, processing skipped |

### 4.5 NFR-04: Cost Optimization

| TC ID | Requirement | Level | Perspective | Expected Value |
|---|---|---|---|---|
| TC-DMR-140 | NFR-04 Opus Not Used for L3 | L1 | bloom=3 | Opus is not selected |
| TC-DMR-141 | NFR-04 chatgpt_pro Prioritized | L1 | Multiple models for same bloom | chatgpt_pro group is prioritized |
| TC-DMR-142 | NFR-04 Suppress Unnecessary Switch | L1 | current model = recommended model | Switch does not occur |

---

## 5. Phase 3 Test Cases — Gunshi Bloom analysis layer

### 5.1 FR-07: gunshi_analysis.yaml Schema

| TC ID | Requirement | Level | Perspective | Expected Value |
|---|---|---|---|---|
| TC-DMR-200 | FR-07 Valid YAML | L1 | All fields defined | yaml.safe_load() succeeds, all fields readable |
| TC-DMR-201 | FR-07 #48 Fields Omitted | L1 | No quality_criteria etc. | No parsing errors |
| TC-DMR-202 | FR-07 bloom_level Range | L1 | bloom_level=0,7 etc. | Validation error |
| TC-DMR-203 | FR-07 confidence Range | L1 | confidence=-1, 2.0 etc. | Validation error |

### 5.2 FR-08: Gunshi Bloom Analysis Trigger

| TC ID | Requirement | Level | Perspective | Expected Value |
|---|---|---|---|---|
| TC-DMR-210 | FR-08 auto -> Analyze All Tasks | L2 | bloom_routing=auto | Sent to Gunshi inbox |
| TC-DMR-211 | FR-08 manual -> Explicit Request Only | L2 | bloom_routing=manual | Only for tasks with bloom_analysis_required=true |
| TC-DMR-212 | FR-08 off -> No Analysis | L2 | bloom_routing=off | Not sent to Gunshi inbox |
| TC-DMR-213 | FR-08 Undefined -> off | L2 | bloom_routing undefined | Not sent to Gunshi inbox |
| TC-DMR-214 | FR-08 Gunshi Inactive Fallback | L2 | Gunshi pane missing | Fallback to Phase 2 behavior |

### 5.3 FR-09: bloom_routing Settings

| TC ID | Requirement | Level | Perspective | Expected Value |
|---|---|---|---|---|
| TC-DMR-220 | FR-09 auto Read | L1 | bloom_routing: auto | "auto" |
| TC-DMR-221 | FR-09 manual Read | L1 | bloom_routing: manual | "manual" |
| TC-DMR-222 | FR-09 off Read | L1 | bloom_routing: off | "off" |
| TC-DMR-223 | FR-09 Undefined -> off | L1 | bloom_routing undefined | "off" |
| TC-DMR-224 | FR-09 Invalid -> off | L1 | bloom_routing: invalid | "off" + stderr warning |

---

## 6. Phase 4 Test Cases — Full auto-selection

### 6.1 FR-10: Quality Feedback

| TC ID | Requirement | Level | Perspective | Expected Value |
|---|---|---|---|---|
| TC-DMR-300 | FR-10 History Append | L1 | Task completion | Append 1 line to model_performance.yaml |
| TC-DMR-301 | FR-10 History Read | L1 | Read past 10 entries | Summary by task_type x bloom_level is possible |
| TC-DMR-302 | FR-10 Empty File | L1 | model_performance.yaml missing | No errors |
| TC-DMR-303 | FR-10 Suitability Calculation | L1 | pass/fail stats under same conditions | pass rate can be calculated |

---

## 7. Unit Test Scope (Phase 1 Implementation Target)

### 7.1 capability_tier Read

- UT-DMR-001: Get max_bloom of defined models
- UT-DMR-002: Get default value (6) for undefined models
- UT-DMR-003: Get default value (6) when section is missing
- UT-DMR-004: Get default value (6) when YAML is broken

### 7.2 Recommended Model Selection

- UT-DMR-010: L1-L3 -> Select Spark
- UT-DMR-011: L4 -> Select Codex 5.3
- UT-DMR-012: L5 -> Select Sonnet Thinking
- UT-DMR-013: L6 -> Select Opus Thinking
- UT-DMR-014: chatgpt_pro group prioritized
- UT-DMR-015: Error handling of out-of-range input
- UT-DMR-016: Idempotency (same result on consecutive calls)

### 7.3 Cost Groups

- UT-DMR-020: Get cost_group of each model
- UT-DMR-021: Get "unknown" for undefined models

---

## 8. Integration Test Scope (Phase 2 and onwards, managed by Karo)

- IT-DMR-001: model_switch inbox -> Confirm Ashigaru model change
- IT-DMR-002: Ashigaru reassignment on CLI cross-over
- IT-DMR-003: Skip model_switch to Codex/Copilot Ashigaru
- IT-DMR-004: Coordination of Gunshi Bloom analysis -> Karo model_switch -> Ashigaru execution
- IT-DMR-005: Control Gunshi analysis via bloom_routing flag

---

## 9. E2E Scope (managed by Lord)

- E2E-DMR-001: Run entire flow: Lord -> Shogun -> Gunshi (Bloom analysis) -> Karo (switch) -> Ashigaru (execution)
- E2E-DMR-002: Ensure different models are used when L3 and L5 tasks coexist
- E2E-DMR-003: Verify shutsuijin starts successfully before and after adding capability_tiers

---

## 10. Prerequisites (Preflight)

- `bash`, `python3`, `bats` are available
- `.venv/bin/python3` can import PyYAML
- For L2+, `tmux` and `inotifywait` are available
- Test settings.yaml can be injected (via CLI_ADAPTER_SETTINGS environment variable)

When prerequisites are not met:
- Do not run the test; record the reason for unmet prerequisites
- Reporting as SKIP is prohibited (treated as incomplete)

---

## 11. Test Case ID Summary

| Phase | TC ID Range | Count | Level |
|-------|----------|------|--------|
| Phase 1 | TC-DMR-001–055 | 23 | L1 |
| Phase 2 | TC-DMR-100–142 | 15 | L1/L2 |
| Phase 3 | TC-DMR-200–224 | 14 | L1/L2 |
| Phase 4 | TC-DMR-300–303 | 4 | L1 |
| **Total** | | **56** | |

---

## 12. FR/NFR Trace

| Req ID | TC ID(s) | Phase |
|--------|----------|-------|
| FR-01 | TC-DMR-001–003 | 1 |
| FR-02 | TC-DMR-010–017 | 1 |
| FR-03 | TC-DMR-020–029 | 1 |
| FR-04 | TC-DMR-030–033 | 1 |
| FR-05 | TC-DMR-100–103 | 2 |
| FR-06 | TC-DMR-110–113 | 2 |
| FR-07 | TC-DMR-200–203 | 3 |
| FR-08 | TC-DMR-210–214 | 3 |
| FR-09 | TC-DMR-220–224 | 3 |
| FR-10 | TC-DMR-300–303 | 4 |
| NFR-01 | TC-DMR-040–041 | 1 |
| NFR-02 | TC-DMR-120–121 | 2 |
| NFR-03 | TC-DMR-130–131 | 2 |
| NFR-04 | TC-DMR-140–142 | 2 |
| NFR-05 | TC-DMR-050 | 1 |
| NFR-06 | TC-DMR-055 | 1 |

At least one TC exists for each FR/NFR (16 total). No omissions.

---

**Test Specification Completed**: 2026-02-17
**Next Actions**: Implement bats tests for Phase 1 -> add FR-01 to FR-04 functions in `cli_adapter.sh`
