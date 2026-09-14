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
- **Bounded veto (#947).** `agentLifecycle` is an **event-driven belief**, not
  a measurement: cmux sets it from hooks (a prompt turn started; a
  turn-complete has not arrived), so a lost/never-sent turn-complete leaves
  `lifecycle=running` **forever**. An unbounded veto therefore immunises that
  pid permanently, however long its JSONL sits untouched — measured
  2026-09-13: 45/47 candidates vetoed, 38 by `lifecycle=running`, and two of
  them provably frozen at 98h/128h. A non-idle record is consequently only
  evidence while it is **fresh**: a non-idle record whose OWN `updatedAt` is
  older than `REAP_STUCK_HOURS` (default **3× `REAP_IDLE_HOURS`** = 72h) is no
  longer current, and the pid is classified **STUCK**. STUCK is **reported,
  never signaled by default**; `REAP_REAP_STUCK=1` (`--reap-stuck`) arms it,
  and even then all of these must hold: JSONL ground truth past the same
  bound, **every** non-idle record for that pid stale past it (fence-matched
  or not; any fresh *or* `updatedAt`-less record keeps the veto — fail
  closed), the process not accumulating CPU (`stat` S/I), and **no live
  non-zombie child process** (a tool call in flight). A record that cannot be
  identity-verified (no/off-fence `pidStartSeconds`) abstains from **voting**
  — it still cannot veto the ordinary path — but it CAN withhold a STUCK kill.
  The JSONL proof is computed **before** the veto so
  the stuck population is never invisible: every vetoed row **that has a JSONL
  proof** surfaces its `jsonl idle` age, and its record age too whenever a
  usable `updatedAt` exists (a vetoed row with no proof keeps the fail-closed
  `SKIP <veto>` line and reports no ages, since none exist; a proof-bearing row
  whose sibling non-idle record carries a missing/unparseable `updatedAt`
  reports `record age ?h`), plus a `⚠️ STUCK` audit block and
  `STUCK_HOURS=/STUCK=/STUCK_RSS=/STUCK_ARMED=` footer fields.
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
5. **ALLOWLIST union veto (bounded, #947):** EVERY incarnation-matched record
   must be `agentLifecycle==idle` AND `runtimeStatus==idle`. Any value on
   either key — running / needsInput / unknown / error / None / absent —
   vetoes the pid. Records with no `pidStartSeconds` abstain from voting. The
   veto is **bounded by record freshness** (see *Bounded veto* above): a veto
   whose non-idle records are ALL stale past `REAP_STUCK_HOURS` is
   re-classified STUCK (reported; not signaled unless `REAP_REAP_STUCK=1`). A
   fresh record — or one with no parseable `updatedAt` — keeps the plain
   veto, **including a non-idle record that abstained from voting** (freshness
   is unioned over every non-idle record this pid has, so an unverifiable
   record can still only *withhold* a kill, never cause one).
6. JSONL proves idle > threshold (youngest voting record wins; a no-JSONL
   twin abstains but does NOT veto). The proof is evaluated **before** the
   veto so a vetoed row still reports its idle age.
7. **Settle re-verify immediately before each signal:** a FRESH per-pid ps
   probe (lstart changed ⇒ pid died+reused ⇒ suppress) and a fresh JSONL
   re-probe (activity advanced ⇒ suppress). The re-probed file is the
   age-setting (max-epoch) record's file — **plus, for a STUCK row, the union
   of every matched record's file** — so a twin that advances is not invisible.
   A STUCK row additionally re-reads the cmux store: its deciding record must
   still exist, still be non-idle, and **every** non-idle record for that pid
   must still carry a valid stale stamp (the same union rule as classify). A
   STUCK row also takes a **fresh `ps` enumeration** and re-runs the
   no-live-child / no-live-pi-descendant probe against it, so a tool child
   spawned *after* classify suppresses the kill; if that fresh enumeration
   fails or comes back empty, the row is suppressed (an untrustworthy probe
   is never read as "no child"). So a
   twin that **refreshes** — i.e. starts a turn — suppresses, while a twin that
   merely goes *idle* deliberately does not: an idle record is the reap target
   itself, not work in progress, and any real activity on that twin is still
   caught by the union JSONL re-probe above. Only the DECIDING record **ending**
   suppresses outright (a turn that ended there disproves the premise).
   Post-TERM survivor re-check is the
   same fresh probe (`kill -0` is never the oracle) WITH the incarnation fence
   re-applied: a pid recycled in the grace window suppresses the SIGKILL;
   zombies skip it. Survivors (same lstart) get SIGKILL
   after `REAP_GRACE_SECONDS` (5).

Signals always go through `${KILL_BIN:-/bin/kill}` (never the bare shell
builtin). Group TERM/KILL `-pgid` when pgid==pid (all tty'd REPLs are pgid
leaders); per-pid fallback otherwise — documented limitation below.

## Safety gates + never-touch list

- Fail-closed ps enumeration (added with #947): if the pass-start `ps` (or its
  row parser, or the candidate scan) fails, the pass aborts (exit 3) and
  signals nothing — **whether or not rows came out**, because a partly-failed
  `ps` yields a *truncated* table and a truncated table silently reads as "no
  live child". A broken `ps` must never be mistaken for an idle machine. The
  same rule guards the settle-time re-enumeration for STUCK rows (see gate 7).
  `--list` reports the failure on stderr and exits 3 rather than printing an
  empty list.
- Fail-closed store: a missing/corrupt cmux store **with candidates** aborts
  (exit 3) after one retry — the pass never reaps from an unreadable
  registry. Zero tty'd pi candidates skip the store read entirely (exit 0,
  footer written) so cmux-less machines never emit hourly ⚠️ noise.
- Fail-closed descendant map (added with #947): the map backing the
  orchestrating-skip and the stuck arm's no-live-child guard is rebuilt by
  `python3`; if that build fails **with candidates present**, the pass aborts
  (exit 3) and signals nothing. Without it an unbuildable map made every pid
  answer "no live pi descendant / no live child" — silently disabling the
  skip, i.e. a session running tool or sub-agent work could be reaped. An
  empty ps table (0 candidates) is not a failure and stays a clean no-op, and
  `--list` exits before the build so the diagnostic surface is never blocked.
  Only **interpreter/IO** failure counts as "unavailable": a malformed ps row
  or an undecodable argv byte is skipped row-by-row (`errors="replace"`), so
  one stray byte cannot turn the hourly job into a permanent no-reap.
- Single-instance mkdir-lock (`~/.pi/agent/state/pi-reap-idle.lock`; macOS
  has no flock). Stale rules: a live owner whose lock is younger than
  `REAP_LOCK_STALE_SECONDS` (=1800) blocks the pass (exit 3); a dead owner
  or a lock aged past the threshold is broken and the pass proceeds.
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
classifier) → descendant-map build (**fail-closed**, see above) → cmux store
index (canonical `~/.cmuxterm/pi-hook-sessions.json`
only; stale `.tmp` crash-leftovers ignored) → session_id→JSONL-first join with
fence + allowlist + marathon/own-session gates → settle-verified kill. Driven
hourly by launchd; interactive runs default to **dry-run**; the launchd env
carries `REAP_DRY_RUN=0` (armed). Threshold override: `--idle-hours N` /
`REAP_IDLE_HOURS`. Bounded-veto override: `--stuck-hours N` /
`REAP_STUCK_HOURS` (default 3× the idle threshold). An explicitly supplied
threshold is bounded
by `REAP_MAX_HOURS` (default 1000000); the RAW value is range-checked before
decimal normalization (bash `$(( 10#… ))` wraps mod 2^64) and a bad value —
including a non-numeric `REAP_MAX_HOURS` itself — is a usage error (exit 2).
The **derived** stuck bound (3× the idle threshold) is not capped, but it is
checked after the multiply to be a positive decimal, so an overflowing wrap
cannot make it negative (a negative bound would make every age comparison
true and classify active sessions STUCK).
Stuck arm: `--reap-stuck` /
`REAP_REAP_STUCK=1` — **not** set by the launchd job, so the hourly pass
reports the stuck set and never reaps it.

## Ops contract

- **Log:** `$HOME/.pi/agent/state/pi-reap-idle.log` (per-user; the plist sets no
  StandardOutPath/StandardErrorPath — launchd capture of the same output would
  grow an unbounded twin of the capped log and put session ids in a
  world-readable /tmp file; the capped footer is authoritative).
  Truncation uses a `mktemp`-ed sibling in the log's own directory — never a
  predictable `/tmp` name (a local symlink-truncation surface). Every pass writes a footer
  `MODE=<dry-run|apply> NOW=… THRESHOLD=… STUCK_HOURS=… STUCK=… STUCK_RSS=… STUCK_ARMED=… CANDIDATES=… PRE=… POST=… RESIDUAL=… KILLED=… YIELD=…`
  (the exact field set, in order, of a normal pass). Every abort that runs
  before classification writes a reduced footer carrying `STUCK_HOURS=` and
  `STUCK_ARMED=` — `MODE=disabled … sentinel=`, the **lock** abort (both the
  live-owner and the `LOCK raced` branch), the **ps
  enumeration** abort, the **descendant-map** abort and the **store** abort —
  so a monitor keying on `STUCK_ARMED` never silently reads the previous
  pass's values as current. On those paths `STUCK=0` is a literal "no
  classification ran", never a measured zero. The abort paths `log` their own
  reason line immediately before the footer; the disabled path's reason is on
  **stdout** (`echo`), so its log holds the footer alone (the footer is
  self-describing: `MODE=disabled … sentinel=<path>`). The one footer-less
  exit is the **log-unwritable** abort, which by definition cannot log; the
  non-classifying modes (`--list`, `--probe-jsonl`, `--help`, usage errors)
  write no footer and never reach classification. MODE distinguishes armed vs dry passes (an armed pass with zero kills must
  not read as a disarmed job); zero-candidate runs still write the footer
  (an absent log must never mean "not running"); PRE = tty'd-pi before the
  kill pass; POST + RESIDUAL come from a **fresh post-pass read** — RESIDUAL is
  the post-pass re-classification of the reap-eligible set (same gates; legit
  skips like marathon/running-twin/own-session never appear), so RESIDUAL=0
  after a clean armed pass, and on dry-run RESIDUAL = the would-be-reaped
  count with KILLED=0. If that post-pass `ps` read itself fails, its fields are
  reported as `?` (with a `POST-PASS ps enumeration failed` reason line) rather
  than as a stale count — a degraded diagnostic must not read as a fresh one. YIELD = Σ per-target rss at kill (KB). STUCK =
  candidates classified stuck this pass; STUCK_RSS = Σ their rss; STUCK_ARMED
  = whether `REAP_REAP_STUCK` armed the stuck set (a stuck pass with
  `STUCK>0 STUCK_ARMED=0` is the documented, deliberate non-reap state — it is
  NOT health). Log size-guarded (~200 lines).
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
  `runtimeStatus`/`updatedAt`, session-dir `--<cwd>--` encoding). If pi or
  cmux changes any of these shapes the reaper fails closed (skips), not open
  — a dropped/renamed `updatedAt` makes every non-idle record un-ageable, so
  the stuck set stays empty (the pre-#947 behaviour) rather than reaping.
  Dry-run and the hermetic suite (`bash scripts/pi-reap-idle.test.sh`) before
  trusting a new version.
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
  disarmed (the documented no-trail failure class; the read-only `--list`
  path never takes the lock and never writes the log at all — its verdict
  surface is stdout).

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
- **Stuck arm is off by default and is a deliberate broadening (#947):** with
  `REAP_REAP_STUCK=1` the reaper will TERM a pid whose cmux record says
  `running`. The guards are the dual-signal freshness bound (a `updatedAt`
  that is not a real epoch — digit/dot soup, out of plausible range — is
  never treated as stale; fail closed), the S/I process state at classify
  **and again at settle**, the settle-time fresh `ps` re-enumeration and
  child/descendant re-check (suppressed if that probe fails or is empty), the
  absence of a live child at classify, and the
  settle re-verify: fresh lstart + fresh JSONL (unchanged) **plus, for stuck
  rows only, a fresh store re-read** requiring the deciding record to still
  exist and still be non-idle, every non-idle record for that pid to still be
  stale (union), and the process still sleeping — so a turn starting on any
  of the pid's records rewrites that record and suppresses, and the deciding
  record ending suppresses outright.
  The residual risk is a single tool call that legitimately writes nothing
  for ≥72h, holds no child process, and leaves the cmux record untouched —
  indistinguishable from wedged by any signal the reaper can read. Leave the
  arm off where that class matters; the hourly launchd job does not set it.

## Out of scope / follow-ups

- cmux ghost-registry hoard (`~/.cmuxterm/pi-hook-sessions.json` 3.6K+
  records / disk) → follow-up issue #495.
- Headless `pi -p` sub-agent orphans → `scripts/sweep-orphans.sh` domain
  (#385); no orphan evidence found in scoping.
- Session-file deletion → never (resume substrate; not this policy's surface).
