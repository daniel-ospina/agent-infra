---
title: "Idle pi REPL reaper policy — provably-idle interactive sessions >24h (#469)"
type: engineering
domain: operations
doc_status: live
subjects.team: organisation-design-team
created: 2026-09-05
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, issue-469, pi-session-hygiene, cmux, pi-config
---

# Idle pi REPL reaper policy (#469)

One place that pins the **pi session hygiene contract**: how and when the
org's fleet reaps interactive pi REPL sessions that are provably idle, why
false-positive reaping is structurally impossible, and the ops contract for
the hourly launchd job (`com.eldato.pi-session-reaper`). Delivered by issue
#469; scope/plan: `docs/scoping/2026-09-05-issue-469-pi-session-hygiene.md` +
`docs/plans/2026-09-05-issue-469-pi-session-hygiene-plan.md`. Implementation:
`scripts/pi-reap-idle.sh` (farmed to `~/.pi/agent/scripts/` by
`pi-bootstrap/setup.sh`), driven by `templates/launchd/com.eldato.pi-session-reaper.plist`
(`REAP_DRY_RUN=0`, StartInterval 3600).

## Problem class

Interactive pi REPL sessions (tty'd, launched in cmux panes) whose work has
finished have **no exit contract**: pi has no idle-exit flag (verified against
the installed CLI + bundle, 2026-09-05), cmux `agent-hibernation` cannot serve
pi (live `fork_unavailable_reason: pi_version_unverified`; count-gated >12
terminals, not age-gated; global opt-in), and nothing reaped them — finished
sessions held RSS indefinitely (live: 22 tty'd REPLs ≈ 3.5–4.0GB; 6 provably
idle >24h ≈ 305MB). A failing session that "just sits there" still reserves a
tty, a cmux slot, and a pi config-refresh slot, and inflates every fleet-wide
RSS/process measurement.

## Idle semantics + fail-closed rule

- **Idle proof is pi session JSONL only.** A session is idle when its JSONL's
  **last parseable entry** is strictly older than `REAP_IDLE_HOURS` (default
  24h — falsification history: 12h rejected on live churn; the ≥2GB yield
  indicator was rejected on live RSS data, real yield is ~250–400MB/pass).
  Strict `>`: a session idle exactly 24h survives to the next hourly pass
  (exposure ceiling ~25h).
- **No proof ⇒ not idle ⇒ never kill.** Missing/garbage/unparseable/empty
  JSONL, a lone ghost cmux record with no session file, or an incarnation
  mismatch all abstain. cmux lifecycle fields are a **veto-only** signal,
  never proof.
- **Falsification note:** the 24h threshold is diurnal-safe (a session that
  was used yesterday morning and again this morning is never falsely flagged);
  the boundary and the ±3s incarnation fence are hermetic-tested via
  `REAP_NOW_EPOCH`.

## Allowlist gates (every reap passes ALL of them)

1. tty'd pi candidate only (never headless `??`; never non-pi).
2. Not the reaper's own pid/tty/ancestor chain; not its own `PI_SESSION_ID`.
3. Not an orchestrating marathon: no live non-zombie pi descendant.
4. ≥1 incarnation-matched cmux record: `pidStartSeconds` within ±3s of the ps
   lstart (second-granularity rounding differs up to ~1s live). Stale siblings
   beyond the fence neither prove nor veto.
5. **ALLOWLIST union veto:** EVERY incarnation-matched record must be
   `agentLifecycle==idle` AND `runtimeStatus==idle`. Any value on either key —
   running / needsInput / unknown / error / None / absent — vetoes the pid.
   Records with no `pidStartSeconds` abstain.
6. JSONL proves idle > threshold (youngest voting record wins; a no-JSONL
   twin abstains but does NOT veto).
7. **Settle re-verify immediately before each signal:** a FRESH per-pid ps
   probe (lstart changed ⇒ pid died+reused ⇒ suppress) and a fresh JSONL
   re-probe (activity advanced ⇒ suppress). The re-probed file is the
   age-setting (max-epoch) record's file. Post-TERM survivor re-check is the
   same fresh probe (`kill -0` is never the oracle) WITH the incarnation fence
   re-applied: a pid recycled in the grace window suppresses the SIGKILL;
   zombies skip it. Survivors (same lstart) get SIGKILL
   after `REAP_GRACE_SECONDS` (5).

Signals always go through `${KILL_BIN:-/bin/kill}` (never the bare shell
builtin). Group TERM/KILL `-pgid` when pgid==pid (all tty'd REPLs are pgid
leaders); per-pid fallback otherwise — documented limitation below.

## Safety gates + never-touch list

- Fail-closed store: a missing/corrupt cmux store **with candidates** aborts
  (exit 3) after one retry — the pass never reaps from an unreadable
  registry. Zero tty'd pi candidates skip the store read entirely (exit 0,
  footer written) so cmux-less machines never emit hourly ⚠️ noise.
- Single-instance mkdir-lock (`~/.pi/agent/state/pi-reap-idle.lock`; macOS
  has no flock). Stale rules: live owner older than
  `REAP_LOCK_STALE_SECONDS` blocks the pass; dead owner / aged lock breaks.
- **Never touch:** the caller's own session or tty; any active session
  (sub-threshold or JSONL-moving); orchestrating marathons; headless pi;
  ghost records with no JSONL proof; session **files** (only processes are
  signaled — JSONL is the resume substrate and is never deleted); any other
  OS user's sessions (separate HOME — unreachable by design).
- Consent scope: the installing OS user's pi fleet (`~/.pi` + `~/.cmuxterm`),
  including sessions in other org contexts under that user (premise-labs /
  tortoise sessions are in scope); approval basis: this issue's
  org-design-team policy + review gates.

## Mechanism + cadence

`scripts/pi-reap-idle.sh` 4 passes: ps tty'd-pi enumeration (pinned contract
`ps -axo pid=,ppid=,pgid=,tty=,lstart=,stat=,rss=,command=`; argv-based pi
classifier) → cmux store index (canonical `~/.cmuxterm/pi-hook-sessions.json`
only; stale `.tmp` crash-leftovers ignored) → session_id→JSONL-first join with
fence + allowlist + marathon/own-session gates → settle-verified kill. Driven
hourly by launchd; interactive runs default to **dry-run**; the launchd env
carries `REAP_DRY_RUN=0` (armed). Threshold override: `--idle-hours N` /
`REAP_IDLE_HOURS`.

## Ops contract

- **Log:** `$HOME/.pi/agent/state/pi-reap-idle.log` (per-user; the plist sets no
  StandardOutPath/StandardErrorPath — launchd capture of the same output would
  grow an unbounded twin of the capped log and put session ids in a
  world-readable /tmp file; the capped footer is authoritative).
  Truncation uses a `mktemp`-ed sibling in the log's own directory — never a
  predictable `/tmp` name (a local symlink-truncation surface). Every pass writes a footer
  `MODE=<dry-run|apply> NOW=… THRESHOLD=… CANDIDATES=… PRE=… POST=… RESIDUAL=… KILLED=… YIELD=…`:
  MODE distinguishes armed vs dry passes (an armed pass with zero kills must
  not read as a disarmed job); zero-candidate runs still write the footer
  (an absent log must never mean "not running"); PRE = tty'd-pi before the
  kill pass; POST + RESIDUAL come from a **fresh post-pass read** — RESIDUAL is
  the post-pass re-classification of the reap-eligible set (same gates; legit
  skips like marathon/running-twin/own-session never appear), so RESIDUAL=0
  after a clean armed pass, and on dry-run RESIDUAL = the would-be-reaped
  count with KILLED=0. YIELD = Σ per-target rss at kill (KB). Log
  size-guarded (~200 lines).
- **Dry-run → apply procedure:** `bash ~/.pi/agent/scripts/pi-reap-idle.sh`
  (dry-run; inspect verdict rows + MODE=dry-run footer) → one-shot
  `--apply` → confirm footer KILLED/RESIDUAL/YIELD → the hourly launchd pass
  then runs armed by itself. Never run two armed passes concurrently (lock
  aborts the second with exit 3).
- **Recovery / resume:** a reaped session resumes with `pi -r <uuid>` (or
  `--session`) — the JSONL survives by design (files are never deleted) and
  the session replays from its last entry. cmux's own pi-restore is currently
  broken upstream (`pi_version_unverified`) — do not rely on it; `pi -r` is
  the recovery path.
- **Version sensitivity:** the reaper pins live schema (pi JSONL timestamps,
  cmux hook-store keys incl. `pidStartSeconds`/`agentLifecycle`/
  `runtimeStatus`, session-dir `--<cwd>--` encoding). If pi or cmux changes
  any of these shapes the reaper fails closed (skips), not open — dry-run and
  the hermetic suite (`bash scripts/pi-reap-idle.test.sh`) before trusting a
  new version.
- **Retirement rule:** renaming/removing the farmed script requires retiring
  the plist too (broken-target guard cannot catch a stale extra job).
- **Lifecycle-observation results (recorded pre-merge, Verification step 2 of
  the plan):** orchestrating marathon sessions read non-idle in the live cmux
  store, validating the allowlist catch. **Store write mechanism (2026-09-05
  pre-merge observation):** the current pi hook writes `pi-hook-sessions.json`
  IN-PLACE (truncate+rewrite — inode constant across observed 19:43/19:44
  writes; the `.tmp` files in `~/.cmuxterm/` are stale 12–30 Aug leftovers
  from an older rename-based hook version, not current crash leftovers). The
  reaper is unaffected: a torn in-place read fails JSON parse ⇒ fail-closed
  retry-once ⇒ exit 3, and no kill ever rides on a torn read. Re-verify if
  pi/cmux versions drift.

- **Live pre-merge verification record (2026-09-05, all steps unarmed until
  explicitly armed — one-shot apply on the machine owner's own abandoned
  sessions):** dry-run classified 25 tty'd pi sessions: 6 REAP-ELIGIBLE
  (idle 32.6–101.2h; sum RSS 339,456KB ≈ 331MB), own running session
  self-skipped (self-tty/ancestor), 8 allowlist-vetoed (running twins), 10
  sub-threshold active. Armed `--apply`: KILLED=6 YIELD_RSS=339456KB
  RESIDUAL=0 (in-band 250–400MB); all 6 gone (no zombies); victim JSONLs
  fully parseable to their last entries afterward; `pi -r` re-indexes the
  session catalog read-only (JSONL byte-unchanged). Sub-threshold survivors
  untouched; immediate re-run idempotent (KILLED=0 RESIDUAL=0); held
  live-owner lock aborts exit-3 and a released lock passes. Per-pass runtime
  ~6–9s dry / ~44s armed (6 × 5s grace serialized) — the single-pass-awk +
  precomputed descendant-map rewrite (was >100s on the real 814-row ps
  table).

- **Disarm valve:** `touch $HOME/.pi/agent/state/pi-reap-idle.disabled` makes
  every pass (even `--apply`) log a `MODE=disabled` footer and exit without
  signaling — survives the re-syncs that re-install the launchd job after an
  operator deliberately disarms it. Precedence: the ARMED log-writable probe
  runs before the sentinel check — an unwritable log aborts exit 3 even when
  disarmed (the documented no-trail failure class; dry-run — and `--list`
  when mode resolves to dry-run — keep best-effort logging since their
  verdict surfaces are stdout).

- **Framing-byte fail-closed (round 4):** the `|` cand-row delimiter and
  the 0x1f settle tie-separator are APFS-legal in names. `esc()` strips
  them (plus tab/newline) from store-derived values; a matched record
  whose REAL on-disk session file still carries `|` or 0x1f (surfaced by
  the find fallback, not the store) abstains at classify — no-jsonl-proof,
  never eligible, never signaled. (Tab-carrying real paths round-trip
  safely and stay eligible; newline-carrying paths never resolve — find's
  line framing truncates them, so the truncated path fails `-s` and
  abstains.) Deciding-file re-probe failure at settle (deleted/truncated/
  undatable since classify) suppresses the kill — what cannot be
  re-verified is never signaled.

## Limitations + residuals

- **pgid ≠ pid fallback:** when a candidate is not its own process-group
  leader, the reaper signals the pid alone (documented per-pid TERM). Live
  fleet data shows all tty'd REPLs are pgid leaders, so group semantics hold;
  the per-pid path is tested and logged but not live-observed.
- **Permanent hung pi descendant:** a live non-zombie pi descendant
  permanently protects its parent from reaping (`orchestrating` skip). That is
  the safe failure — resolve the hung child manually; the parent then becomes
  reap-eligible on the next pass.
- **Store rules recap:** zero candidates ⇒ store skipped ⇒ exit 0; candidates
  + store missing/persistently corrupt ⇒ ⚠️ retry-once ⇒ exit 3 (never
  mistaken for a disarmed job — the footer documents the abort).

## Out of scope / follow-ups

- cmux ghost-registry hoard (`~/.cmuxterm/pi-hook-sessions.json` 3.6K+
  records / disk) → follow-up issue #495.
- Headless `pi -p` sub-agent orphans → `scripts/sweep-orphans.sh` domain
  (#385); no orphan evidence found in scoping.
- Session-file deletion → never (resume substrate; not this policy's surface).
