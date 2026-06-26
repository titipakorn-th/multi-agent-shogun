# Next Tasks — Delegation (rev 5)

_Updated 2026-06-27 after review of commit `c3992f0`. The drain migration genuinely landed this time — the diff proves it._

## Review result

| Task | Actual |
|------|--------|
| W4c-finish (drain path) | ✅ **done, diff-verified** — `git show --numstat HEAD` = `33/103` (**−70 LoC**); listener 2127→2057; `_drain_pending_lord_questions` is now a ~50-LoC thin wrapper over `LordChannel.promote_next_pending()`; the inline YAML-parse + `json.dump` duplicate state machine is gone. |
| W4c-verify (mock) | ✅ mock-HTTP round-trip green (`VERIFY-003`) |
| W4c-verify-live | ⏳ still Lord-pending |
| W5 | ✅ parked |
| OPS | ✅ done |

This is real. The structural consolidation — the part that's recurred for several rounds — is complete: the read/promote path and `lord_ask.sh` both go through `LordChannel`, and the listener lost net lines.

### Residual: 3 inline `current_question.json` writes remain — classified

`grep json.dump` still finds three sites in `telegram_listener.py`. I read each:

| Line | What it is | Verdict |
|------|-----------|---------|
| 1641 | explicit **legacy fallback** ("so existing tests/behavior don't regress on legacy data") | ✅ sanctioned, commented — leave it |
| 1601 | in-place status flip → `waiting_for_free_text` | ⚠️ small dup — still writes the state file directly |
| 1744 | in-place status flip → `answered` (free-text reply path) | ⚠️ small dup — still writes the state file directly |

So it's not a structural gap anymore — it's **two small status-write sites** that bypass `LordChannel`. Tidy-up, not surgery.

---

## W4c-polish · Route the two status writes through `LordChannel`  **(P2 — optional finishing touch)**

- Add `LordChannel.set_status(status, response=None)` (one method, one flock'd write) and call it at lines 1601 and 1744 instead of the inline `open(question_file,"w") + json.dump`.
- Leave 1641 as-is — it's the documented legacy fallback; just confirm the comment is clear.
- **Accept:** `grep -nE 'json\.dump.*active_question' scripts/telegram_listener.py` → only the legacy-fallback hit (1641) remains; every other `current_question.json` write lives in `LordChannel`. Tests green.

> This is genuinely optional polish. If you'd rather stop, W4 is structurally done; these two lines are cosmetic single-owner purity, not a behavior risk.

## W4c-verify-live · Lord-driven round-trip  **(P1 — needs Lord)**

- Lord runs `tests/manual/test_round_trip_live.sh` with real Telegram creds; pastes output. The mock-HTTP test covers the path in CI — this is the real-credential confirmation.
- **Accept:** Lord-pasted evidence, or keep the explicit "blocked on token" note.

---

## W5 · `inbox_watcher.sh` monolith  **(P3 — still parked)**

No change. `# ponytail: leave it until it breaks twice.`

## OPS · Crontab runbook  **(done)**

`docs/crontab-survival.md` landed.

---

## Dispatch order

`W4c-verify-live` (Lord) is the only thing on the critical path to calling W4 fully closed. `W4c-polish` is optional. W5 parked, OPS done.

skipped: nothing structural — the consolidation is done. We're at the finishing-touch terminus: one Lord-run live check + two optional status-write cleanups. After several rounds of "claimed but not in the diff," this round the diff backs the claim. If the polish isn't worth the effort, say so and W4 closes on the live round-trip alone.
