# Plan — #1512: a balance WARNING must not switch providers

**Level:** task · **Complexity:** standard · **PR:** #1513 · **Trigger half of:** #1508

## Confirmed problem

The DeepSeek balance poller treated a low balance as a **hard exhaustion**: at/below
`DBW_LOW_USD` it SET the shared provider-exhaustion latch, which advanced the failover chain and
routed every dispatched child to a hop leg. On 2026-09-28 that fired at `balance USD 2.9000 <= low 5`
and the chain advanced to `openrouter`, which has **no API key**, so every `task` dispatch died at
model resolution for 30 minutes (03:17–03:47Z).

Nothing had failed: DeepSeek rejects only at **≤ $0**, and the same account answered HTTP 200 inside
that window. The outage ended on a top-up to $201.58 — the window closed for balance reasons, not for
a fix.

## Approaches considered

| # | Approach | Verdict |
|---|---|---|
| A | Delete the threshold; rely on DeepSeek's 402 markers | Rejected — loses the early warning, which has real value |
| B | Keep the latch, raise the threshold (e.g. $30) | Rejected — the defect is the **switch**, not the number; this only makes the outage rarer |
| **C** | **Threshold becomes a WARN; latch-SET on a balance verdict removed entirely** | **Chosen** |

C is the only option that removes the failure mode. A warning that stops work is an ability-to-pay
heuristic masquerading as a hard failure; the honest hard stop is the provider's own 402, which still
hops — on **observed** failure.

## Design decisions

1. `DBW_WARN_USD` (default **30**) replaces `DBW_LOW_USD`. The old name is retained as an inert
   back-compat shim, documented as no-longer-driving-a-latch so nobody "restores" it.
2. **Clear-eligibility is keyed on the latch, not on the band.** The two thresholds OVERLAP
   (warn 30 > clear 20), so ordering alone cannot serve both questions: a warn-first chain makes the
   clear branch unreachable for 20–30, and a latched provider recovering to $25 could never clear —
   the outage made permanent. Latch presence is resolved once, and the warn branch yields to the
   latched-and-above-clear case.
3. **Deliberately not `ALERTED=1`.** A low balance is a known, actionable state, not the "balance
   state unknown" degraded signal `ALERTED` drives; setting it would inflate the consecutive-degraded
   streak and force exit 1 for a warning.
4. **Fail closed on inverted thresholds.** `warn < clear` is a misconfiguration under which a balance
   between them matches no branch and is reported healthy while a latch is retained — a false PASS.
   It now exits 2 at startup.
5. **The latch read must be non-fatal.** A non-canonical status payload must not abort the run; a
   silent no-op is worse than a wrong verdict.

## Truth table (post-fix, total and non-overlapping)

|  | < 20 | 20–30 | > 30 |
|---|---|---|---|
| **latched** | WARN (latch preserved) | **CLEAR** | **CLEAR** |
| **unlatched** | WARN | WARN | PASS |

## Acceptance criteria

1. A balance at/below the warn threshold logs `WARN` and writes **no** latch record.
2. A low balance exits **0**.
3. `== 30.00` warns (at/below semantics).
4. A balance in the $20–30 band warns **when unlatched** and **clears when latched**.
5. An existing latch is never cleared by the warn path.
6. No `latch set` verb on any balance verdict remains.
7. `warn < clear` is refused (exit 2), not silently mis-graded.
8. A non-canonical latch status payload still reaches a verdict.

## Review history

| Cycle | Result |
|---|---|
| 1 — bug scan + infra/safety (2 reviewers) | **P0** — the overlap band could not clear (both reviewers, independently, reproduced by running). Also P1 deployment-revert hazard, P1 ordering-vs-#1508, P2 no delivery channel, P3/P4 |
| 2 — fresh reviewer | **P2** the hoisted latch read aborts the poller under `set -e` (silent no-op); **P3** inverted thresholds reported a retained latch as healthy; **P4** dead inner branch + a self-contradicting commit message |
| VGATE round 5 | **FAIL** — the new P2 regression test was **vacuous** (a failing helper is sanitised by the line above); required a non-canonical *payload* |
| VGATE round 6 | **PASS** — non-vacuity proven by a differential run across revisions |

## Integration surface

| Surface | Covered by | Status |
|---|---|---|
| `deepseek-balance-watch.sh` verdict chain | this issue | ✅ |
| `deepseek-balance-watch.test.sh` policy cases | this issue | ✅ 83/0 |
| `docs/providers.md` poller contract | this issue | ✅ |
| `templates/launchd/*.plist` job comment | this issue | ✅ |
| `docs/research/2026-09-05-…-s6-balance-endpoints.md` | this issue | ✅ marked PARTLY SUPERSEDED |
| `~/.pi/agent/scripts/checkout-hygiene/` (deployed copy the armed job runs) | hand-deploy | ✅ deployed + hash-verified |
| `~/Library/LaunchAgents/*.plist` comment | `install-launchd.sh` | ⚠️ cosmetic; regenerates on install |

## Known residuals (disclosed, not hidden)

1. **The WARN has no delivery channel.** It is a line in `/tmp/deepseek-balance-watch.log` that
   nothing reads, and `ALERTED` is deliberately not set, so the 3-consecutive escalation never fires
   for it. "Warn" is currently close to silence — this needs a recipient.
2. **The deployment is not durable.** `pi-bootstrap/setup.sh` copies from the hub checkout, which does
   not yet contain this change; `AGENT_SYNC_MODE=auto` can overwrite the hand-deploy on a session
   start. Merging this PR is the fix.
3. **This does not close the #1508 outage class.** The hop predicate is still credential-blind, so a
   genuine exhaustion still advances onto the keyless leg. #1508 must land; until then the outage
   class is open, only no longer self-inflicted by a warning.
4. `latch_status()` in the script is now defined and never called (leftover from this change).
