---
title: "#469 — pi session hygiene (idle pi REPL reaper) — Implementation Plan"
type: engineering
domain: operations
doc_status: draft
subjects.team: organisation-design-team
created: 2026-09-05
aboutSubjects: pi, cmux, organisation-design-team
aboutObjects: agent-infra, issue-469
---

<!-- research-path: docs/research/2026-09-05-issue-469-pi-session-hygiene.md -->

# #469 — pi-session-hygiene (idle pi REPL reaper) Implementation Plan

> **For Pi:** implement this plan task-by-task after plan-review passes clean.

**Goal:** Ship a fail-closed, age-gated, org-owned reaper (`scripts/pi-reap-idle.sh` + launchd `com.eldato.pi-session-reaper`) that terminates provably-idle interactive pi REPL sessions (pi session JSONL last-activity > `REAP_IDLE_HOURS`=24h) without false positives, preserving recent-session resumability.

**Team:** organisation-design-team
**Architecture:** bash reaper (4 passes: ps tty'd-pi enumeration → cmux store index → session_id→JSONL-first join with incarnation fence + ALLOWLIST per-pid union veto + marathon-child skip + own-session veto → settle-verified kill) farmed to `~/.pi/agent/scripts/` (TCC #427) and driven hourly by a launchd plist (StartInterval 3600, `REAP_DRY_RUN=0` armed). Interactive default = dry-run. Idle proof is JSONL-only; cmux lifecycle = veto only. Full design + rationale: `docs/scoping/2026-09-05-issue-469-pi-session-hygiene.md` (converged clean through all gates).

**Task graph & dependencies** (tasks 1–4 are one strictly-serial chain over the single script file; leaves declared):

| Task | Depends on | Parallel note |
|---|---|---|
| T1 scaffolding/enumeration | — | — |
| T2 JSONL parser + suite start | T1 | — |
| T3 cmux join + vetoes | T1, T2 | — |
| T4 kill pass + lock + log | T3 | — |
| T5 full-suite sweep | T4 | — |
| T6 plist + farm + installer tests | T1 (file must exist for mkfakehome copy) — sequenced after T5 in practice | leaf once the chain ≥T1 lands |
| T7 ci-main explicit line | T5 | leaf |
| T8 policy doc + affiliation | — | fully independent leaf (can dispatch parallel with any other task) |

**TDD interleave intent:** the suite file is created in T2 with parser fixtures and grows in T3/T4 with join/veto/kill fixtures; T5 is the full-sweep run + CI-safe subset definition. Tasks 2–4 each run their accumulated suite at the end of the task.

**Scope-doc amendments (review cycles 2–3, applied to the plan AND docs/scoping/2026-09-05-issue-469-pi-session-hygiene.md):** (a) pinned ps contract gains `rss=` (yield/I2 source); (b) settle re-verify is a FRESH per-candidate ${PS_BIN} probe — the retained snapshot cannot observe pid-reuse; (c) `DATE_BIN` seam added to the env list for deterministic macOS/GNU date-branch testing; (d) RESIDUAL defined as post-pass re-classification of the reap-eligible set.

### Pattern Research

> **Findings date:** 2026-09-05

**Library docs (preflight)** — no third-party deps in plan — skipped.

**Library version & API surface** — skipped: zero third-party libraries/SDKs; interfaces are machine-local data shapes (pi JSONL, cmux hook-store) + macOS ps + launchd, all pinned in the research/scoping artifacts with live schema drift.

**Idiomatic usage patterns** — skipped: the plan follows in-repo patterns exclusively (session-postmortem.sh inline-python3 JSONL parsing; sweep-orphans.sh kill primitive; install-launchd.sh plist templates; fleet .test.sh harnesses).

**Library/framework pitfalls** — skipped: no third-party dep. Platform pitfalls pinned in the scope doc: flock absent on macOS (mkdir-lock), bash 3.2.57 (no `declare -A`/`mapfile`), `kill` builtin shadowing (KILL_BIN), macOS vs GNU `date` lstart parsing (seam + LC_ALL=C), launchd cannot read `~/Documents` (#427 → farmed copy), auto-sync arms merged plists on pi start (T6/Verification sequencing).

> Gate skipped: plan touches zero third-party deps and uses only in-repo patterns — documented per writing-plans skip rules.

### Integration Surface Map

| Surface | Boundary | Test layer | Failure modes |
|---|---|---|---|
| pi session JSONL (`~/.pi/agent/sessions/--<cwd>--/*.jsonl`) | read-only data | parser fixtures via `--probe-jsonl` + e2e | giant ~149KB single lines; trailing partial write; empty/garbage/missing; timestamp variants (`.228Z`, `+00:00`); file absent → fail-closed not-idle; entry appended during settle (activity veto) |
| cmux hook store (`~/.cmuxterm/pi-hook-sessions.json`) | read-only data | e2e fixture store | 1:many pid→records (75+ pids; idle+running twins); no `storedPidExists` in file; `updatedAt` float-epoch; camelCase; missing store + candidates → ⚠️+abort; missing store + ZERO candidates → exit 0 before store read (cmux-less machines must not noise exit-3); corrupt → retry-once then ⚠️+abort; stale `.tmp` siblings ignored (canonical file only) |
| ps (macOS) | OS | PS_BIN shim (CI-safe) + local real-tty | pid reuse/incarnation (fence pidStartSeconds±3s vs lstart — positive AND negative side); pgid≠pid fallback (per-pid TERM, documented + fixture); own tty/ancestry; zombie descendants (STAT!=Z filter); headless `??` pi excluded; full-table retention = walks-only (settle probes are fresh per-candidate reads); `rss=` column in the pinned contract (yield source — without it YIELD is uncomputable) |
| kill signals | OS | KILL_BIN shim records signals | bare-builtin shadowing (must use ${KILL_BIN}); ESRCH; settle-gate activity veto (JSONL advanced → suppress); settle-gate pid-reuse veto (lstart changed between classify and settle → suppress); group TERM only pgid==pid |
| launchd + farm | infra | install-launchd.test.sh bumps + rollout step | broken-target guard (farmed copy must resolve); rendered plist content asserts (`REAP_DRY_RUN=0`, StartInterval 3600); farm ↔ mkfakehome lockstep; auto-sync arming on pi start (post-merge) — sequencing contract in Verification; retirement rule |
| CI (ci-main) | infra | explicit test line (post-merge; family precedent) | bash 5.x on ubuntu masks 3.2-isms; real-tty asserts self-skip (env-detected) |
| docs | docs | check-doc-affiliation.cjs | frontmatter fields; no "session-lifecycle" naming (#341/#365 cost family) |

**Bug pattern flags:** silent-disarmed-job (MODE footer + plist asserts); silent zero-candidate clean-exit on store failure (fail-closed abort only when candidates exist); pid-reuse stale-age misapplication (fence + JSONL-first); marathon-parent kill (pi-descendant skip); double-run overlap (mkdir-lock); log growth (size guard).

**Tech Stack:** bash 3.2-safe, inline python3 (JSONL reverse-scan), launchd plist, macOS ps. Zero third-party deps.

---

## Task 1: Reaper scaffolding — ps enumeration, pi classifier, self-exclusion

**Intent:** Enumerate the candidate universe (tty'd pi processes) with a pinned ps contract; exclude the reaper's own process/tty/ancestry from the very first pass.
**Acceptance:** `scripts/pi-reap-idle.sh --list` prints tty'd pi rows `{pid ppid pgid tty stat lstart_epoch rss}` from `${PS_BIN:-ps}`; argv-based pi classifier matches runner-path basename `pi`/`/pi` suffix (not comm); own pid + own tty + ancestor rows excluded; headless (`??`) pi and non-pi tty rows never listed.
**Files:**
- Create: `scripts/pi-reap-idle.sh`
- No suite file yet (T2 creates it; ci-main is post-merge-only so mid-branch absence cannot break CI)

Steps:
1. Write the script skeleton: `set -uo pipefail`, header comment (issue ref, policy contract, bash-3.2 note, version-sensitivity note), usage `[--dry-run] [--apply] [--idle-hours N] [--list] [--probe-jsonl FILE...] [--help]`, env seams (`PS_BIN KILL_BIN DATE_BIN CMUX_STATE_DIR PI_SESSIONS_DIR REAP_IDLE_HOURS REAP_DRY_RUN REAP_GRACE_SECONDS REAP_NOW_EPOCH REAP_LOCK_STALE_SECONDS REAP_LOG`), `log()` to `REAP_LOG` (default `$HOME/.pi/agent/state/pi-reap-idle.log` — per-user dir, never a predictable world-writable `/tmp` sibling (symlink-truncation surface); the truncation temp is `mktemp`-ed in the log's own directory).
2. Implement `list_candidates()`: **pinned ps contract (amended):** `ps -axo pid=,ppid=,pgid=,tty=,lstart=,stat=,rss=,command=` via `${PS_BIN:-ps}` (macOS + GNU both support `rss=`; the yield/I2 contract needs per-target RSS so the canonical invocation MUST carry it). **Retain the FULL parsed ps table** (all rows — every pid/ppid/pgid/tty/stat/lstart/rss, not only pi rows) — **walks-only invariant: the retained snapshot serves the ancestor/descendant walks (T1 step 3, T3) and NEVER the settle re-verify (T4 probes are fresh per-candidate ${PS_BIN} reads — a static snapshot cannot observe pid-reuse)**; produce the filtered tty'd-pi candidate list from it; lstart→epoch via a `${DATE_BIN:-date}` seam — **branch selection is a CAPABILITY PROBE of `${DATE_BIN}`, never `uname`: feed a known BSD `-j -f '%a %b %e %H:%M:%S %Y'` invocation; exit 0 → macOS branch, else GNU `-d` fallback (both `LC_ALL=C`) — so a macOS-shape-only stub forces the macOS parse branch on ANY platform (ubuntu CI included), making the CI coverage of the ONLY production branch real and deterministic**; the ±3s incarnation fence and settle re-verify depend on this conversion.
3. Implement self-exclusion from the retained table: reaper's own pid (`$$`), its tty (`ps -o tty= -p $$`), ancestor pids (walk ppid→1). Skip any candidate on own tty or in the ancestor chain. (The `PI_SESSION_ID` session-id veto is a join-level gate in T3 — NOT deferred-dangling here; T3 owns it.)
4. `--list` mode prints candidates; `--help`; exit 0.

## Task 2: JSONL last-entry parser (`--probe-jsonl`) + suite start

**Intent:** Ground-truth idle proof: last parseable pi JSONL entry timestamp, reverse-scanned (giant lines), fail-closed on unparseable. (Runs BEFORE the cmux join so T3 can consume idle age.) Pure file-path interface — session-file RESOLUTION (needs cmux record cwd/sessionId) lives in T3 where its consumer sits.
**Acceptance (amended round 5 — parser-only semantics):** `--probe-jsonl FILE...` prints one JSON row per file `{path, last_timestamp, idle_proven, reason}`; **`idle_proven` = a parseable last entry EXISTS (parser ground truth, NOT threshold-relative — age is computed at classify time; the strict-`>` boundary incl. exact-24h survives lives at classify (T4/C15), never in the probe**; giant single complete lines (≥150KB) parse; trailing partial/garbage (unparseable JSON) line → previous parseable line; a newest COMPLETE line with an undatable/missing `timestamp` → `idle_proven:false, reason:unparseable` (fail-closed — an undatable write cannot be aged, never falls back to an older entry); empty/whitespace/all-garbage/missing → `idle_proven:false`; ISO `.228Z` and `+00:00` micro timestamps both parse; numeric (float-epoch) top-level `timestamp` parses. Fixtures (below) green: `bash scripts/pi-reap-idle.test.sh`.
**Files:**
- Modify: `scripts/pi-reap-idle.sh`
- Create: `scripts/pi-reap-idle.test.sh` (fleet harness model: mktemp, ok/bad counters, assert helpers, python3 fixture writers, PS_BIN/KILL_BIN/DATE_BIN shims)

Steps:
1. Implement `probe_jsonl()` as an inline `python3 -` heredoc (session-postmortem.sh precedent): binary reverse-chunk read, split lines, `json.loads` each complete line from the tail, return the last with a parseable top-level `timestamp` (str ISO or numeric).
2. Age = `REAP_NOW_EPOCH` (default `date +%s`) − parsed epoch.
3. **Fixture pack A (parser; harness start):** giant complete line ≥150KB mid-file + at tail; trailing partial/garbage line; empty file; whitespace-only; all-garbage; missing file; `.228Z`; `+00:00` micro; **numeric float-epoch top-level timestamp**; undatable-newest-complete-line abstain (A5); `--probe-jsonl` JSON shape asserts (fresh/threshold-boundary fixtures live at the classify level — C15, where REAP_NOW_EPOCH is threaded). Run suite.

## Task 3: cmux store join + vetoes (fence, allowlist, marathon, own-session)

**Intent:** The correctness crux — map each candidate pid to its cmux records, prove idleness only via JSONL through the incarnation fence, veto on any non-idle record, skip orchestrating marathons and the reaper's own session.
**Acceptance:** For each candidate with ≥1 tty'd-pi candidate existing (zero candidates → the store read is SKIPPED ENTIRELY — the pass proceeds straight to the standard footer path + exit 0, NO ⚠️ noise and NO bare early exit; cmux-less machines never noise the exit-3 path and the log still proves the job ran): records from `${CMUX_STATE_DIR:-$HOME/.cmuxterm}/pi-hook-sessions.json` indexed by pid (ALL records for the pid; stale `*.tmp` crash-leftovers in the dir ignored — canonical file only); store missing/corrupt WITH candidates → single retry (~1s) then ⚠️ + exit 3 (fail-closed); incarnation-matched = `pidStartSeconds` within ±3s of ps lstart (tolerance is intentional: live second-granularity rounding differs up to ~1s — exact-equality implementations silently fail closed); **union-exclusion rule: only incarnation-matched records vote — stale (offset > ±3s) siblings neither prove NOR veto (any record beyond the fence is excluded from the ALLOWLIST union entirely)**; ALLOWLIST per-pid union veto (every incarnation-matched record must have `agentLifecycle==idle` AND `runtimeStatus==idle`; any other value on EITHER key — running/needsInput/unknown/error/None/absent → skip w/ reason); no-JSONL record abstains (absent file → not idle on its own AND not a veto — a JSONL-backed idle twin with a no-JSONL sibling is still reaped); live non-zombie pi descendant (recursive ppid walk over the RETAINED full ps table, STAT!=Z) → skip `orchestrating`; **own-session veto: any candidate whose cmux session_id == `$PI_SESSION_ID` → skip (hard gate)**; JSONL idle age per T2 (youngest voting JSONL = idle age). Verdict rows printed in `--dry-run`.
**Files:**
- Modify: `scripts/pi-reap-idle.sh`, `scripts/pi-reap-idle.test.sh` (append)

Steps:
1. Store read via inline python3 (camelCase keys; tolerant of `updatedAt` str/float); guard: candidates==0 → skip store read (never ⚠️/exit-3; the run continues to the footer path and exits 0 — asserted in fixtures + policy doc ops contract); **missing-file and parse-error share ONE retry/abort path: any read failure → retry once after ~1s → if the retry read succeeds the pass proceeds; if it fails again (missing, persistent corrupt) → ⚠️ exit 3 (pack B's read-count==2 assert covers both)**.
2. Per-pid record index; incarnation match (±3s inclusive, fence applies per record); **union-exclusion over the fence: stale siblings dropped from the ALLOWLIST union**; union veto with explicit reason strings over the FULL six-value × two-key vocabulary (agentLifecycle AND runtimeStatus each: idle/running/needsInput/unknown/error/None/absent).
3. Session-file resolution helper (record cwd/sessionId → `~/.pi/agent/sessions/--<cwd with /→->-->/` dir, `*<sessionId>*.jsonl` glob, uuid-suffix find fallback) + probe each voting record's file via T2 `probe_jsonl()`; no-JSONL → abstain.
4. Marathon-child walk (non-zombie) over the retained ps table (walks-only invariant per T1).
5. Own-session `PI_SESSION_ID` veto; wire verdict rows for `--dry-run`.
6. **Fixture pack B (join/veto/resolution; append):** fake-ps row sets (full table incl. reaper own pid/tty/ancestors, non-pi rows, and a headless `??`-tty pi row → never listed/never candidate); `--list` output-contract assert under a fake PS (columns incl. rss, exclusions, exit 0); cmux stores: 2-records-per-pid (idle+running twins same pidStartSeconds); parametrized veto over the full vocabulary — each value on each key (runtimeStatus-only-running; agentLifecycle-only-running; needsInput; unknown; error; None; absent field) each asserting never-reaped + reason; **stale-sibling union-exclusion BOTH directions (matching idle record + stale >±3s non-idle sibling → REAPED; matching non-idle + stale idle sibling → SKIPPED for the matching record's reason, never for the stale one)**; **neutral no-JSONL twin composition (JSONL-backed idle-30h twin + sibling with absent session file → REAPED, sibling reason = abstain not veto)**; incarnation positive-side (lstart↔pidStartSeconds offset 2s → reaped; exactly ±3s → matched; 4s → skipped); no-JSONL lone abstain; marathon-child skip (non-zombie pi descendant); zombie-not-a-skip; own-tty/ancestor rows; `PI_SESSION_ID` match → skip; sub-threshold (fresh JSONL → not reaped); **resolution fixtures (nested-slash cwd → encoded dir name; `<startedAt>_<sessionId>.jsonl` glob hit vs uuid-suffix find fallback; missing session dir → abstain reason)**; stale `.tmp` sibling ignored (canonical file read); **DATE_BIN stub fixture lands here in T5 step-1 reconciliation (appended to this fake-ps section; pack A cannot host it — pure probe path)**; store missing-with-candidates AND persistent-corrupt (canonical file present, unparseable on BOTH reads, WITH candidates) share ONE retry/abort path** (T3 step 1 states the merge) → retry-once then ⚠️ exit 3 (read-count==2 assert via the python3 seam) + transient-corruption fixture (retry read succeeds → pass proceeds); store missing-with-ZERO-candidates → exit 0. Run suite.

## Task 4: Kill pass, lock, log contract (PRE/POST/RESIDUAL)

**Intent:** Act only on verified-idle candidates with settle re-verify; single-instance; legible per-pass log — armed vs dry-run distinguishable; operational evidence for acceptance I2 (pre/post counts + residual sweep).
**Acceptance:** `--apply` (or `REAP_DRY_RUN=0`) sends `${KILL_BIN:-/bin/kill}` group TERM `-pgid` when pgid==pid else per-pid TERM (fallback documented + fixture-exercised); settle re-verify before each signal performs a **FRESH per-candidate ${PS_BIN} probe of the target pid** (never the retained snapshot — a static table cannot observe reuse) re-resolving pid→lstart, AND re-probes JSONL last-entry: lstart differs from classification time (pid died+reused) OR activity advanced → suppress with reason; **the re-probed file is the MAX-epoch (age-setting) record's file — sid/sfile travel in lockstep with the max, so a resumed session whose file set the age is the file re-verified (round-5 hardening for the supported 2+-records-per-pid shape)**; **post-TERM survivor re-check is the SAME fresh ${PS_BIN} probe, WITH the incarnation fence re-applied before SIGKILL (round-5 hardening: a pid recycled during the grace window shows a fresh lstart ≠ classification lstart → the group is NOT provably the reaped session → suppress the KILL and count the TERM as the reap; STAT==Z survivors likewise skip the KILL; kill -0 is never the survivor oracle — fake pids always ESRCH, which would silently dead-code the escalation)**; **POST count and the RESIDUAL re-classification sweep read a FRESH post-pass full ${PS_BIN} table — the walks-only invariant extends here: killed pids are absent from that read, so RESIDUAL=0 after a clean armed pass BY CONSTRUCTION (re-classifying the pass-start snapshot would re-list killed pids as reap-eligible and falsely read RESIDUAL>0)**; **dry-run RESIDUAL semantics: a dry-run pass kills nothing, so RESIDUAL = the would-be-reaped reap-eligible count (nonzero + informative: RESIDUAL=N, KILLED=0) — the "RESIDUAL=0 after a good pass" contract applies to armed passes only**; **threshold comparison is strict `>` (exactly-24h idle survives — matches T2/Target)**; ESRCH swallowed; a corrupted candidate row (non-numeric class fields — e.g. a store value containing the field separator) suppresses, never proceeds (fail-closed); SIGTERM→`REAP_GRACE_SECONDS`(5)→SIGKILL survivors (fence-checked); mkdir-lock at `~/.pi/agent/state/pi-reap-idle.lock` (owner-pid file; stale: owner dead via `kill -0` or age > `REAP_LOCK_STALE_SECONDS`=1800 → break); log footer `MODE=<dry-run|apply> NOW=… THRESHOLD=… CANDIDATES=… PRE=… POST=… RESIDUAL=… KILLED=… YIELD=…` where PRE/POST = tty'd-pi counts before/after the kill pass and **RESIDUAL = post-pass RE-CLASSIFICATION of the reap-eligible set (the same gates as the kill pass: JSONL-idle>threshold AND no vetoes) — legitimately-skipped >24h candidates (marathon-orchestrating, running-twin veto, own-session) are NOT provably idle and MUST NOT appear in RESIDUAL; 0 after a good pass feeds the 0-provably-idle>24h target**; dry-run emits `DRY-RUN — no signals sent`; log size-guarded (~200 lines); exit 0 completed passes, 2 usage, 3 fail-closed store/lock-abort.
**Files:**
- Modify: `scripts/pi-reap-idle.sh`, `scripts/pi-reap-idle.test.sh` (append)

Steps:
1. mkdir-lock acquire/release (fail-closed: cannot acquire → ⚠️ + exit 3 after stale checks).
2. Kill pass with settle re-verify (BOTH vectors: fresh ${PS_BIN} probe lstart-change AND JSONL re-probe activity-advance) + group/per-pid semantics + ESRCH + grace→SIGKILL (survivor oracle = fresh ${PS_BIN} probe, never kill -0).
3. Log contract: per-candidate lines (pid tty rss sessionId jsonl idle_h action reason), PRE count from the pass-start table + POST count from a **FRESH post-pass full ${PS_BIN} read** + RESIDUAL re-classification sweep over that same fresh read (reap-eligible gates only; killed pids are gone → RESIDUAL=0 after a clean armed pass; **dry-run: RESIDUAL = would-be-reaped reap-eligible count, KILLED=0**), yield = Σ per-target RSS at kill, MODE footer, size-guard truncation. **Zero-candidate runs (no tty'd-pi at all AND none reap-eligible) still write the standard footer (CANDIDATES=0, PRE/POST/RESIDUAL) to REAP_LOG before exit 0 — an absent log must never be mistaken for a disarmed/never-run job.**
4. Thread `--dry-run`/`--apply`/`REAP_DRY_RUN` default-1 into the pass.
5. **Fixture pack C (kill/lock/log; append; REAP_GRACE_SECONDS=0 convention for ALL armed fixtures so none sleep the 5s grace):** dry-run MODE footer + zero signals; armed TERM + MODE=apply + KILL log sequence (group `-pgid` shape); pgid≠pid row → per-pid TERM shape (NOT `-pgid`); **SIGKILL survivor escalation: fake pid STILL listed in the fake-ps source after TERM → SIGKILL recorded with the same group/per-pid shape; fake pid removed from source → NO SIGKILL recorded (deterministic via the fake-ps source, contractually the same fresh-probe seam)**; **RESIDUAL value fixtures (fresh post-pass read semantics — the fake-ps source is advanced between passes): (a) armed pass, one killable 30h candidate → KILLED=1, POST==PRE−1, RESIDUAL=0; (b) dry-run with one reap-eligible candidate → KILLED=0, RESIDUAL=1 (would-be-reaped)**; ESRCH swallowed; settle-gate activity veto (DETERMINISTIC: KILL_BIN shim, invoked during candidate A's settle, appends a fresh JSONL entry for candidate B → B's settle re-verify sees advanced activity and suppresses — no wall-clock race); **settle-gate pid-reuse veto (DETERMINISTIC: KILL_BIN shim rewrites the fake-ps source so the settle FRESH probe returns a new lstart for the target pid → lstart differs from classification → suppressed; the shim rewrite is only observable because settle re-queries ${PS_BIN}, not the snapshot)**; lock second-pass block + stale-break (dead owner / age>stale) paths; zero-candidates exit 0 WITH footer content asserted (both case i — no tty'd-pi rows at all — and case ii — candidates present, none reap-eligible); threshold override flips a 20h fixture; **RESIDUAL semantics fixture: a >24h marathon-skipped/status-vetoed candidate present post-pass must NOT appear in RESIDUAL (reap-eligible re-classification only)**; PRE/POST/RESIDUAL footer fields present. Run suite.

## Task 5: Full-suite sweep + CI-safe subset

**Intent:** Prove the false-positive classes are structurally impossible and the parser is correct, in one legible green run; define what CI may run.
**Acceptance:** `bash scripts/pi-reap-idle.test.sh` fully green on macOS (all fixture packs A/B/C + local real-tty asserts). CI-safe subset identified (fixture/shim-driven only; real-tty asserts self-skip via env detection) and run green under a bash-5-ish check (`bash -n` both new scripts; ubuntu-style env sim on the subset).
**Files:**
- Modify: `scripts/pi-reap-idle.test.sh` (sweep order + skip guards)

Steps:
1. Reconcile fixture packs into one deterministic order; assert counters summary line.
2. Real-tty section self-skipping unless interactive macOS (env-detected; #385 precedent) — CI-safe subset = everything else.
3. **DATE_BIN seam fixture (appended to pack B's fake-ps fixture section during the step-1 reconciliation — pack A never invokes ps or ${DATE_BIN} (pure `--probe-jsonl`), so it cannot host a date stub; pack B's fake-lstart rows are where `list_candidates()`' conversion runs; T3 pack B carries a note that this fixture lands in T5):** stub date accepting only the macOS `-j -f '%a %b %e %H:%M:%S %Y'` invocation shape → known lstart string → exact epoch (LC_ALL=C, TZ-pinned); the capability-probe branch selection (T1 step 2) makes the stub force the macOS parse branch deterministically on ubuntu CI too; **two-branch epoch-agreement assert (same lstart → same epoch): runs in the CI-safe subset when a GNU date binary is available (e.g. `gdate`); otherwise the agreement is explicitly deferred to the post-merge ci-main ubuntu run (GNU branch only — documented residual)**.
4. Full local run green; `bash -n` clean.

## Task 6: plist + farm + installer-test bumps

**Intent:** Ship the hourly carrier with the farmed-copy + armed-by-default contract, and keep the installer suite truthful.
**Acceptance:** `templates/launchd/com.eldato.pi-session-reaper.plist` renders `{{HOME}}/.pi/agent/scripts/pi-reap-idle.sh` with `REAP_DRY_RUN=0` + `{{PATH}}` env + StartInterval 3600 + StandardOut/Err → `/tmp/pi-reap-idle.out.log`; `pi-bootstrap/setup.sh` farm list gains `pi-reap-idle.sh` (re-commented); `scripts/install-launchd.test.sh`: mkfakehome farmed list +1, bootstrap count 3→4 (all sites), per-job installed+loaded assert, rendered-plist content asserts (`REAP_DRY_RUN` = `0`, `StartInterval` 3600, farmed path). `bash scripts/install-launchd.test.sh` green.
**Files:**
- Create: `templates/launchd/com.eldato.pi-session-reaper.plist`
- Modify: `pi-bootstrap/setup.sh`, `scripts/install-launchd.test.sh`

Steps:
1. Write the plist (clone fleet-cost-weekly shape; header comment: issue, canonical script, naming rationale, armed-by-default note; **sequencing warning: this plist auto-installs on ANY pi session start after it lands on main (setup.sh + sync.sh both call install-launchd.sh; auto-sync) — the sacrificial real-signal test MUST run pre-merge, see Verification**).
2. setup.sh: add to farm list + re-comment the list purpose.
3. install-launchd.test.sh: mkfakehome +1; count 3→4 at every assertion site; per-job asserts; rendered-content asserts.
4. Run installer suite green.

## Task 7: CI wiring

**Intent:** The suite runs post-merge in ci-main (family precedent) — explicitly, not by glob.
**Acceptance:** `.github/workflows/ci-main.yml` script-validate job runs `bash scripts/pi-reap-idle.test.sh` (explicit line); `bash -n` glob already covers both new scripts; comment notes post-merge-only is deliberate (family precedent) + real-tty asserts self-skip.
**Files:**
- Modify: `.github/workflows/ci-main.yml`

Steps:
1. Locate the script-validate job step that runs install-launchd.test.sh; add the reaper line beside it.
2. Note in the step comment the deliberate post-merge-only placement.

## Task 8: Policy doc + docs registration

**Intent:** The org policy contract + ops runbook in the docs home, with valid frontmatter; no "session-lifecycle" naming.
**Acceptance:** `docs/ops/pi-idle-repl-reaper-policy.md` exists with frontmatter (title/type:engineering/domain:operations/doc_status:live/subjects.team:organisation-design-team/created/aboutSubjects/aboutObjects) and content per scope doc Files #7 list (problem class; idle semantics + fail-closed rule; **strict-`>` threshold semantics (exactly-24h idle survives; target stays 0-idle->24h)**; allowlist gates; threshold + falsification note; cadence/mechanism; safety gates; never-touch list; **lifecycle-observation results recorded during Verification step 2 (allowlist catch of orchestrating sessions; cmux atomic-rename confirmed/refuted — the live validation of the corrupt-store retry-once design)**; ops contract incl. MODE-footer log (incl. zero-candidate runs still writing CANDIDATES=0 footers), dry-run→apply procedure, resume = `pi -r`, cmux-restore-broken note, pi-version-sensitivity, retirement rule; policy scope + consent sentence; pgid≠pid limitation; permanent-hung-pi-descendant residual; store rules: zero-candidates-skip-store + missing-with-candidates→exit-3 so hourly exit-3 noise is never mistaken for corruption; out-of-scope + follow-up #495). `node scripts/check-doc-affiliation.cjs --files <doc>` clean.
**Files:**
- Create: `docs/ops/pi-idle-repl-reaper-policy.md`

Steps:
1. Draft the policy doc from the scope doc content list.
2. Run the affiliation checker; fix frontmatter until clean.

## Verification (dev box — sequencing contract; per scope doc steps 1–8)

**⚠️ Sequencing contract (mandatory):** steps 1–7 run **PRE-merge from the branch** (checkout `.worktrees/469`), on an UNARMED box (no plist installed), in the already-open pi session. The armed plist exists ONLY on the branch until merge; sync.sh/auto-sync pull **main** (sync.sh also #265-guards against non-main checkouts), so a `pi -r` resume check (step 3) or any pi start during pre-merge verification CANNOT arm the box — the branch plist is invisible to sync. Post-merge CI green is an async check and must NOT be a precondition of step 8. **Step-8 execution vehicle (pinned):** run step 8 in the SAME pre-merge pi session or from a plain terminal (no new pi session) — a fresh pi session between merge and step 8 would fire session_start auto-sync (fetch → behind → sync.sh → setup.sh farms the merged script → install-launchd.sh arms the plist) BEFORE step 8's explicit command, i.e. auto-arm ahead of the deliberate trigger. If a fresh pi session is genuinely unavoidable, treat its session_start auto-arm AS the trigger and convert step 8 into verification of the auto-armed state (farmed copy == merged script via checksum, rendered asserts, launchctl loaded) + the `launchctl start` kick — or bootout and re-run the installer deliberately. Between merge and step 8 the box is unprotected by design (documented).

1. `bash scripts/pi-reap-idle.sh --dry-run` → ≥5 candidates ≈300MB; own-session absent; MODE=dry-run footer (PRE/POST/RESIDUAL fields present).
2. Lifecycle-during-tool-exec observation + cmux atomic-rename confirmation — **record results (allowlist catch of orchestrating sessions; atomic-rename confirmed/refuted) into the policy doc ON THE BRANCH before merge** (pre-merge amendments are the only way the observation lands before arming).
3. Sacrificial real-signal SIGTERM test (JSONL integrity + `pi -r` resume clean).
4. One-shot `--apply` → RESIDUAL=0 provably-idle >24h (reap-eligible re-classification — legit skips excluded); yield footer ≈250–400MB.
5. Sub-threshold survivors alive; `cmux sessions list pid_exists=yes`; reaped files intact; `pi -r` clean.
6. Idempotence + lock paths (second pass while running → block).
7. **PRE-merge gate (UNARMED):** full suite `bash scripts/pi-reap-idle.test.sh` + `bash scripts/install-launchd.test.sh` (count 4) + `bash -n` both new scripts green; CI green on the branch (reaper line is post-merge-only by Task 7 — branch CI is the existing family coverage). Only after steps 1–7 pass AND review gates clear may rollout proceed.
8. **Rollout (POST-merge, same day, per the execution vehicle above):** refresh the farm FIRST (`./pi-bootstrap/setup.sh` — the plist's ProgramArguments target must resolve or install-launchd.sh hard-fails by design; verify the farmed copy matches the merged script via checksum), then run `scripts/install-launchd.sh` (real — do not wait on auto-sync); verify launchctl loaded + rendered plist asserts; first hourly pass log footer MODE=apply; kick one pass via `launchctl start` if not yet elapsed.

## Follow-ups

- #495 (cmux registry/disk hoard — filed during scoping).
- PR-time (ci.yml) coverage for the reaper suite = deliberate deviation from family precedent if ever wanted (documented in ci-main step comment).

## Plan Review Cycle Log

- cycle 1 (2 parallel fresh reviewers): 1 P1 + 1 P1 (task-ordering contradiction / dangling own-session veto; verification-vs-auto-sync arming) + 9 P2 → all fixed in revision (parser T2 before join T3; PI_SESSION_ID owned by T3; suite interleave; dep map; PRE/POST/RESIDUAL footer; walks-only retention; rss=; fresh-probe settle; RESIDUAL re-classification; abstain≠veto; stale-sibling both directions; DATE_BIN seam; headless/--list fixtures; policy-doc observation slot; step-7 vehicle).
- cycle 2 (2 fresh): 1 P1 (settle re-verify over retained snapshot = dead pid-reuse gate — converged by both reviewers) + 10 P2 → fixed (fresh ${PS_BIN} probe + pack C deterministic fixtures; capability probe note deferred to cycle-3 #4 fix; persistent-corrupt merge).
- cycle 3 (2 fresh): 1 P2 (DATE_BIN stub placement "pack A/B" untestable — pack A is pure probe) + 1 P1 (POST/RESIDUAL source unspecified — pass-start snapshot would falsely read RESIDUAL>0; dry-run RESIDUAL semantics unpinned) + 1 P2 (persistent-corrupt fixture orphaned) → all three fixed directly post-cap (see below).
- cycle 4 (2 fresh, HARD CAP): verified cycles 1–3 fully resolved; found 1 P1 (POST/RESIDUAL fresh-read source + dry-run RESIDUAL=N/KILLED=0 semantics — same class as cycle-3 #2, surfaced independently) + 1 P2 (persistent-corrupt fixture orphaned from pack B) + 1 P2 (DATE_BIN stub home ambiguous between pack A [untestable] and pack B). Cap reached → per AGENTS.md hard-cap rule, remaining issues documented and fixed in-place post-cap (all three were unambiguous correctness gaps; fixes applied directly to plan + scope docs, verified by grep/cross-read, NOT by a further fresh reviewer):
  - POST/RESIDUAL: plan T4 acceptance/step 3 + pack C value fixtures (a: armed → KILLED=1 POST==PRE−1 RESIDUAL=0; b: dry-run → KILLED=0 RESIDUAL=1) + scope mechanism bullet mirror.
  - Persistent-corrupt: pack B fixture enumerated (read-count==2 assert; missing-file and parse-error share ONE retry/abort path — stated in T3 step 1).
  - DATE_BIN stub: home pinned = pack B fake-ps section, appended during T5 step-1 reconciliation (pack A cannot host it — pure probe path); T3 pack B carries the forward note.
- ⚠️ capped at 4 cycles — 0 issues remain (all three post-cap fixes applied and cross-checked plan↔scope consistent).

<!-- plan-review: status=clean — 4 cycles to hard cap; cycles 1–3 clean passes on all prior issues; cycle-4 residuals (1 P1 + 2 P2) fixed directly post-cap per AGENTS.md hard-cap rule and documented in the Review Cycle Log above; plan↔scope cross-checked consistent after fixes -->
