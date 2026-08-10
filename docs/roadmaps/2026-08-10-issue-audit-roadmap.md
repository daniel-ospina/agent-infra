# Issue Audit & Roadmap — 2026-08-10

Method: full issue data dump (65 open) audited by 3 parallel subagents, every issue
verified against current code (file:line evidence). Audit data: `/tmp/audit-batch-{1,2,3}.json`.

## Result

| Bucket | Count | Action |
|---|---|---|
| Verifiably fixed in code | 46 | Close with evidence comment |
| Stale / noise | 2 (#1, #42) | Close |
| Wrong repo | 1 (#43) | ✅ Moved → tortoise#857 |
| Genuinely valid | 16 | Roadmap below |

## Close list (48)

**Fixed — bootstrap/portability sweep (#2–25):** 2, 3, 4, 5, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 20, 21, 22, 23, 24, 25
(shipped in `62097ad`, `0a8ea8c` + later path sweeps; dual AGENT_*/ELDATO_* env support verified)

**Fixed — skills/pipeline:** 27+28 (post-deploy-verify skill wired), 29+49 (heartbeat 30min + retry, commit `87cc3e0`), 44 (Qwen3.8-Max Phase 4.5 in 4 skills), 50 (vgate batching), 52 (auto-sync.ts + version pins)

**Fixed — extraction epic (all 7 done):** 53, 54, 55, 56, 57, 58, 59
(repo structure, `bin/agent-infra.js` CLI, templates/, scripts/, 97 skills, 10 extensions, manifest v0.1.0)

**Fixed — gates & code-review v3.2:** 62, 63, 64, 66 (duplicate of #63), 67, 68, 69, 70, 71

**Fixed — recent bugs:** 129 (silence timeout), 132 (extractJson schema-gated, `67bf761`)

**Stale:** 1 (throwaway test), 42 (skill doesn't exist; premise references dead path)

**Total: 46 fixed + 2 stale = 48 issues to close** (#43 handled separately — moved and closed).

## Dependency map (valid issues)

- **#137 → #92** (orphan reaping needed for clean abort recovery)
- **#133 / #134 / #135** — one bug class: stderr contaminating JSON parse/transport (defensive fix #132 already landed; shared `json-scan.ts` seam is the proper fix)
- **#48 + #40** — complementary (wiring vs channel), both depend on `approval.py` in **swarm** repo
- **#51 ⊂ #41** (Good>EASY is Gap 5 of the test-design wiring)
- **#6 ⊂ #45** partially (google-slides residual refs vs extension placement decision)
- **#60 → #65** (bypass semantics need the compliance gate first)
- **#61 umbrella** — items 1–5 shipped; remaining = #65 (CI compliance) + .gitignore item

## Roadmap

### Wave 1 — Quick wins (all S effort; clears 7 issues)
| # | Issue | Value |
|---|---|---|
| 133 | review-enforcer: guard gate_bypass console.log | M |
| 135 | loop-enforcer: verdict-shape validation | M |
| 46 | remove ~/eldato fallbacks (3 literals: tortoise-capture:608, skill-registry:26, sequence-enforcer:204) | M |
| 47 | de-brand OpenRouter headers (4 literals) | M |
| 6 | google-slides residual operations/skills refs | M |
| 92 | kill orphaned MCP transports on disconnectAll | M |
| 45 | decide home for carousel extensions (decision + execute) | M |

### Wave 2 — Sub-agent transport reliability (one epic: #134+#137, builds on #92)
| # | Issue | Value | Effort |
|---|---|---|---|
| 134 | builtin-tools: don't append stderr on clean exit | M | M |
| 137 | completion signal + Escape preserves finished result | H | M |

Shared `json-scan.ts` seam also closes out #135's class permanently.

### Wave 3 — Pipeline integrity (H value, closes #61 umbrella)
| # | Issue | Value | Effort |
|---|---|---|---|
| 65 | CI process compliance gate (+ branch protection) | H | M |
| 60 | bypass semantics: audit trail + dispatchCount persistence | M | M |
| 41 | wire test-design + capstone gates into epic pipeline (absorbs #51) | H | M |

### Wave 4 — Approval routing (cross-repo, depends on swarm)
| # | Issue | Value | Effort |
|---|---|---|---|
| 48 | request_approval in 6 remaining skills | H | M |
| 40 | re-enable Slack bridge as primary channel | H | M |

## Next actions
1. ✅ #43 → tortoise#857
2. ✅ Closed 48 fixed/stale issues with evidence comments (2026-08-10)
3. ✅ Updated #61 scope; links recorded (#51→#41, #6→#45, #137→#92)
4. ✅ Waves 1–4 executed same-day

## Execution record (all merged 2026-08-10)
| PR | Wave | Issues closed |
|---|---|---|
| #139 | 1 + priority | #133 #135 #46 #47 #45 #6 #92 #138 |
| #140 | 2 | #134 #137 |
| #141 | 3 | #65 #60 #41 #51 |
| #142 | 4 + #61 completion | #40 #48 #61 |

**End state: 65 open → 0 open** (48 closed as fixed/stale, 1 transferred, 16 shipped).
Model routing per user directive: scope+plan by pro/Qwen-class for complex (#137),
all implementation by deepseek-v4-flash. Qwen unreachable via task provider
(deepseek-only endpoint) — deepseek-v4-pro substituted for the #137 plan.

Known residuals (not blocking): slack-bridge button-callback receiver needs
Socket Mode (#40 follow-up, user-side env setup); PRs #136/#130 still in review.

## Second pass (2026-08-10, full issue workflow)
Residual gaps closed via proper issues (#143-146): scoping comments with
markers → implementation → verification → review → PR → merge.
- #143 (micro, direct): branches pruned, leftovers filed, gh rate-limit runbook
- #144: compliance gate check (e) test-coverage evidence
- #145: gate wired into agent-infra CI + **branch protection on main**
  (`pipeline-compliance` required) — PR #147 passed its own gate, PR #148 was
  the first merge enforced by protection
- #146: Socket Mode receiver (plan-first via pro model, flash implementation,
  187 tests green) — approval buttons now resolve verdicts
- tortoise product doc re-homed → tortoise#870; PRs #136/#130 merged/closed
  via commit-workflow pass (#130 superseded by 87cc3e0)

**User-side remaining:** `SLACK_APPROVAL_CHANNEL` (notifications) and optional
`SLACK_APP_TOKEN` xapp- (button callbacks).
