---
title: "Fleet session liveness — the five states, the identity rule, and the abstention doctrine (#1178)"
type: engineering
domain: operations
doc_status: live
subjects.team: organisation-design-team
created: 2026-09-20
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, issue-1178, issue-1254, issue-1317, session-liveness, pid-identity, lane-liveness, successor-dispatch, pi-idle-repl-reaper-policy, fleet-inventory, orchestrator-bringup
---

# Fleet session liveness (#1178)

One place that says **how the fleet decides whether a lane is alive**, so the answer does not
have to be reconstructed from five scripts. Delivered by #1178; the open-turn rule inside it was
fixed on #1254 (merged as #1271).

The verdict is a pure function, `evaluate(Evidence) -> Verdict`, in
[`tools/fleet/liveness.py`](../../tools/fleet/liveness.py). It emits **exactly one** of five
states and always names the evidence that decided it:

```
dead | running-quiet | wedged | idle | unknown
```

The artifacts, one authority:

| surface | role |
|---|---|
| `tools/fleet/liveness.py` | the verdict function (pure over evidence) and the evidence acquisition (`gather`) |
| `tools/fleet/lane_liveness.py` | the **scheduled** driver: enumerates lanes, calls `gather`+`evaluate`, escalates a `dead` lane to a deduped issue. A driver, never a second opinion |
| `scripts/lib/pid-identity.sh` | the one **process-identity rule** — sourced by the kill-path reaper (Bash), forked as a CLI by the classifier (Python) |

The kill path (`scripts/pi-reap-idle.sh`) is a *consumer of the same identity rule*, not a second
liveness rule: it is documented in `docs/ops/pi-idle-repl-reaper-policy.md`. **A wrong verdict here
cannot kill anything** — `lane_liveness.py` never calls `os.kill`.

---

## 1. The five states and what each rests on

Every state is read from the same three inputs — the **cmux hook store**
(`~/.cmuxterm/pi-hook-sessions.json`), the **session JSONL** (`~/.pi/agent/sessions/…`), and a
**fresh `ps` read** (through the probe CLI). The whole point of #1178 is that a frozen
session-file `mtime` alone renders *dead*, *running-quiet* and *wedged* identical, so the doc
states per state what is actually being read.

| state | what is read | evidence required |
|---|---|---|
| **`dead`** | process identity **+** transcript mtime | a **non-empty** candidate set **and** every candidate positively `absent` or `zombie` in a fresh `ps` read **and** the JSONL did not grow inside the window — non-growth **positively known** |
| **`running-quiet`** | transcript growth / record freshness / turn boundary / (tool veto) | any of: JSONL **grew** inside the window (even with no fenced holder), a fresh non-idle record, an in-flight tool whose watchdog bound has not expired, JSONL frozen *within* the stream bound, or a transcript whose last turn **ended** |
| **`wedged`** | fenced holder **+** frozen transcript **+** a **positively OPEN turn** | JSONL frozen **past the stream bound** (`STREAM_STALL_MS`, 20 min; strict `>`) **and** the transcript's last message-bearing entry shows an **unfinished** turn **and** no un-expired tool veto **and** no fresh non-idle record |
| **`idle`** | fenced holder **+** JSONL age | a fenced holder, no vetoes, and JSONL age **past the retirement proof** (`IDLE_MS`, 24 h — the reaper's own idle proof) |
| **`unknown`** | — | a **named abstention**. Never a dumping ground, never a weaker `wedged` (see §4) |

### Ordering is the safety property

`evaluate` decides in this order (each step is a return; nothing later can override an earlier
verdict):

0. **Evidence availability** — a failed `ps` or an unreadable store abstains (`ps-unreadable` /
   `store-unreadable`). A failed read is never `dead`.
1. **Growth** — a JSONL that grew inside the window is **positive liveness evidence**, decided
   *before* identity, so a growing lane can never read `dead` (`jsonl-grew`, reporting
   `writer-unidentified` when there is no fenced holder).
2. **Identity** — the **only** source of `dead`. Non-empty candidate set, every candidate a
   positive `absent`/`zombie` witness (`is_dead_evidence`), non-growth positively known (the
   separate `jsonl_grew is False` guard).
3. **The vetoes** — a fenced holder exists; every "still working" signal is a **veto against
   `wedged`**, never a reason to escalate: un-expired tool veto, then fresh non-idle record.
4. **Age** — past the `IDLE_MS` proof (24 h) ⇒ `idle`; within the `STREAM_STALL_MS` bound (20 min)
   ⇒ `running-quiet`.
5. **The turn boundary** — frozen past the bound and short of the proof: `wedged` only on a
   positively open turn, else `running-quiet` (turn ended) or a named abstention.

### `wedged` requires POSITIVE evidence of an OPEN turn

Before the #1254 fix, `wedged` fired on *any* frozen transcript — and a merely-idle interactive
lane read `wedged` 47 minutes after its turn had completed (the incident is recorded in
`lane_liveness.py`'s header). A session file stops growing for two opposite reasons: the lane is
**at a prompt**, or it is **stuck mid-turn**. "Quiet for 20 minutes" is the fleet's normal resting
state, so a frozen file alone is not a stall.

`wedged` therefore requires one of these shapes in the transcript's **last message-bearing
entry** (read backwards from EOF; the boundary is always at the end):

| open shape | transcript evidence |
|---|---|
| `turn-open:pending-tool-call` | an assistant message **carrying tool calls** whose `stopReason` is not one under which pi discards them (`error` / `aborted`); or `stopReason: toolUse` |
| `turn-open:awaiting-assistant` | a `toolResult` with no assistant reply after it |
| `turn-open:awaiting-response` | a user prompt with no assistant reply after it |
| `turn-open:no-terminal-stop` | the last assistant message carries no `stopReason` **and no tool calls** (a call-carrying message with no `stopReason` is `turn-open:pending-tool-call`) |

A transcript whose last turn ended with a terminal `stopReason` on a message carrying **no** tool
calls (`stop` / `length` / `error` / `aborted`), or with `error` / `aborted` on a message
**carrying** tool calls, is **RESTING**: it reads `running-quiet`, never `wedged`, short of the
24 h retirement proof — and the `reason` names the path that returned that state
(`quiet-within-bound` inside the 20 min bound, `turn-ended` past it, `record-non-idle-fresh` or
`tool-in-flight` while those vetoes hold).

Terminality is an **explicit set**, never a fall-through: on a message carrying **no** tool calls, a
`stopReason` outside it — including one pi has not emitted yet — **abstains** (`unknown` /
`turn-unknown:<stopReason>`) rather than asserting the lane is resting. A message **carrying**
calls is decided by the rule above first, so an unrecognized reason with calls is an OPEN turn,
not an abstention. `turn-ended` is RESTING (unescalatable, never `wedged`), so a
default that lands there would read a genuinely suspended lane as merely quiet — the fail-open
direction this classifier exists to remove (#1272).

> **pi behaviour, and how it was established.** The stop-reason rule rests on pi's own semantics.
> Measured by the #1254 unit over **426 live session files**: of assistant messages carrying tool
> calls, `toolUse` 147,466 with 147,431 `resultFollows`; `error` 115 with **0**; `length` 78 with
> **78**; `aborted` 16 with **0**. `resultFollows` is **not** `executed`: pi's own source
> (`pi-agent-core` `dist/agent-loop.js`, `failToolCallsFromTruncatedMessage`) routes a `length`
> message's calls to a failure path — every result after a `length`+calls message carries
> `isError: true` ("Tool call … was not executed") — and then **continues the turn**. So
> `length`+calls is an OPEN turn awaiting the turn's next step, while `error` / `aborted`
> **discard** their calls and end the turn. (An earlier reading of the same 78/78 count called
> those calls "executed"; a count of results is not evidence of work.) This is third-party
> behaviour, not our contract — if pi changes it, the measurement and the source are what must be
> re-checked. The classifier's verdict is unaffected either way: `length`+calls is OPEN.

---

## 2. Why `dead` needs a process check

This is the core finding. `dead` is not a state any of the fleet's older detectors could emit,
and the failure mode is worse than a wrong label:

| detector | population | can it say `dead`? |
|---|---|---|
| `~/.pi/agent/state/map-sessions.py` | session files (`glob` + `st_mtime`); **no process read at all** | **no** — a dead lane and a quiet lane are the **same row** |
| `~/.pi/agent/state/stall-sweep.py` | `cmux top --processes` → chats with a **live pi pid** | **no** — a dead lane is **absent from the report**, not reported as dead |
| `~/.pi/agent/state/stale-stuck.py` | cmux process rows, then `if not pis: continue` | **no** — also **absent** from the population |

So a lane whose process is gone either reads as an ordinary quiet row (the file-derived detector)
or **disappears** (the two process-derived detectors). **Absence is the one failure mode a report
cannot show** — and it is the five-hour loss on #1178: nothing reported the lane as gone, so
nothing prompted anyone to look, and the lane had to be respawned rather than nudged.

The scheduled driver closes this by deriving its **population from the durable store**, which
outlives the process: a lane whose process is gone stays *enumerated* and can be *reported* as
`dead`. The store answers *which lanes exist and what incarnation they had*, the session JSONL
answers *whether it is still growing*, and the probe CLI answers *whether that incarnation is
still alive*.

The mirror failure is real too: a working child was once declared `wedged` with
`toolsInFlight=1` / `toolAgeMaxMs ≈ 1.19M ms` while it was still working. That is why every
"still working" signal is a veto (§1).

> **Tracked vs untracked.** None of the three detectors above is in this repository, and nothing
> tracked installs them — they live in `~/.pi/agent/state/` on the host. The thing that decides
> liveness must therefore be the tracked, tested, reviewed artifact
> (`tools/fleet/liveness.py`), not a lone state-directory script. Unit 4 (rewiring the three
> consumers) is blocked on a decision about their repo home and is **not** done.

---

## 3. The identity ordering

> **One rule, two languages, one process boundary.** The rule is
> `scripts/lib/pid-identity.sh`; the Python classifier cannot source a Bash function, so the
> library exposes a guarded-main **CLI** (`probe` / `probe-argv` / `argv-candidates`) and the
> classifier forks it. Adding a second identity probe anywhere is the "two contracts for one
> safety rule" defect #1178 exists to remove.

**Four consumers, still one rule.** `scripts/lane-watchdog.py` (the wedge reaper) forks the same
CLI **at signal time**, immediately before each `os.kill`: it supplies the incarnation it recorded
when it measured the subtree, and signals only on `holder`. It derives no identity of its own — an
earlier version signalled by pid alone, which is the superseded form recorded in §6.

**A fourth consumer: the `pi` POOL's owner** (`scripts/orphan-reap.py --pool pi`, 2026-10-22). The
`ppid=1` orphan class above could not see a lane's `pi` at all — bare argv, reparented to launchd
or sitting under tmux — so the session pool had no owner and grew without bound. That reaper
derives the session **from the pid** (the JSONL whose name-stamp is within the canon's
`FENCE_TOLERANCE_SECONDS` of `now - etime`; an argv `--session` form is left to
`scripts/lib/pid-identity.sh`, never re-parsed), then calls **`liveness.gather`** — so the store is
read and its vetoes apply — appends the live pid it is holding as a `HOLDER` candidate (the C2
direction), and acts **only** when `evaluate` returns `idle`. ⛔ **And in the shipped default it
does not act AT ALL**: the canon verdict is necessary, not sufficient. The chain must also pass the
recorded HOST DECISION (§`#1207`, owner-approved as option A on `#1297`): a human terminal or
login shell is `KEEP-HUMAN`, and a chain that is **unparseable OR carries no host app at all** is
`unknown` — *report only, never reap*. A `pi` reparented to launchd has no ancestry left to show a
host, which is exactly this pool's target population, so its reapable set is **empty by decision**:
the census ships, arming it is a reopen (one named constant), never a flag flip. Three process
gates sit in front of
that verdict — CPU delta < 0.10 s over the printed window, ancestry walked to the top (a
Terminal/iTerm/login-shell/tmux ancestor is `KEEP-HUMAN`), and progress judged against the
process's **own** median inter-entry gap (age ≥ max(`IDLE_MS`, 100× the gap)) — and the four
reported states are `LIVE`, `PARKED-REAPABLE`, `KEEP-HUMAN`, `UNVERIFIABLE`. Its declared blind
spots are the ones §1 leaves it: a `pi` that leaves no bindable session file (a print-mode / `task`
child, or a resumed session keeping its original name-stamp) has **no progress channel**, so one
of the three gates cannot be evaluated on it — a PARKED one abstains as `UNVERIFIABLE`
(`no-progress-channel:<binding>`), never as "nothing to reap", while a BUSY one still reads `LIVE`
off gate 1 (the CPU delta). That asymmetry is deliberate, not a gap: `PARKED-REAPABLE` is only
reachable by a row that HAS a transcript (the abstention on a missing one sits on the same path),
so nothing is reaped either way, and collapsing a busy unbound lane into an abstention would
destroy the census's one diagnostic job — telling progress from parked. The guarantee is the
abstention on the PARKED row, not a promise that an unbound row can never read `LIVE`. A **second**
declared blind spot is the SWITCHED session (`/new`, `/fork`, `/clone`): pi writes a fresh stamped
file and leaves the abandoned one behind, so the fence binds the dead transcript and the row can
read `PARKED-REAPABLE` for a lane that was writing seconds ago — masked to `UNVERIFIABLE` under the
shipped host decision, and a wrong kill only where that decision is reopened (#2475). On a box
where the hook store is unreadable every
row that **reaches** the canon abstains as `store-unreadable`, because that is what §1 requires of
the verdict it consumes — a row under a terminal/login-shell/tmux ancestor is `KEEP-HUMAN` from
gate 2 **before** the canon verdict is consulted and so does not abstain (the canon is still read;
gate 2 supersedes its answer). The safe property holds either way — nothing is reaped — but
`counts.UNVERIFIABLE == pool size` is **not** a store-health probe, and 0 UNVERIFIABLE does not
mean the store was readable.

The shared rule, in the reaper's own vocabulary (`scripts/lib/pid-identity.sh`,
`scripts/pi-reap-idle.sh`):

1. **Candidates are a UNION.** The candidate set for a session id is the current store record,
   **every** `priorProcessGenerations` entry, every pid whose **argv names the session** in a
   resume form (`pi --session <id>`, `-r <id>`, `--resume <id>`, or `--session=<id>`), and — for
   the `pi` pool below — the pid that pool's reaper is itself holding (a *positive* observation
   from a fresh `ps` read; a bare-argv `pi` is invisible to the argv source). The union —
   not the newest, not the first — is what stops a resumed session's stale tag from calling a live
   lane dead. Without the argv source, "the record's incarnation is gone" would be silently
   equated with "the lane is dead".

2. **A pid holds the session its store record names only if the fence matches.** A fresh `ps`
   read must show it present, **not a zombie**, and its `lstart` must be within
   **±`FENCE_TOLERANCE_SECONDS`** (default 3 s) of the recorded `pidStartSeconds`. ⚠️ The `pi`
   pool below fences against a DIFFERENT datum on the SAME bound: the session JSONL's
   **name-stamp** (UTC, ms) against `now - etime`. Same tolerance, different evidence — stated
   here so the two are not read as one reading. The fence
   exists because second-granularity rounding differs by up to ~1 s; its whole purpose is to make
   an identity *uncertainty* fail safe. An unrelated process that inherits a dead session's pid
   fails the fence and is **not** its holder. A pid whose **argv** names the session is a *direct*
   identity claim instead (`probe-argv`): a live, non-zombie argv-claiming pid is the holder with
   **no fence applied** — there is no recorded start to fence against.

3. **A zombie is a corpse, not a holder.** `stat` `Z*` (`<defunct>`) is excluded from the holder
   set: the probe returns `zombie` at exit 1, and the reaper's classify loop skips it. Without
   this rule a zombie pi would satisfy a naive existence probe, `dead` would become unreachable,
   and a dead lane would be reported `wedged` — a dead lane called alive.

4. **Non-vacuity is load-bearing.** Two guards keep "every candidate is gone" from being
   *vacuously* true:
   - `is_dead_evidence` requires a **NON-EMPTY** candidate set. An empty set is `unknown`
     (`no-holder-record`) — exactly where the reviewed kill path abstains
     (`SKIP incarnation-unmatched`); a live lane with a session file and no store record must never
     read `dead`.
   - `pid_table_nonempty` treats a read that *succeeds* but prints no table as **UNREADABLE**
     (exit 2), never as "no such process": the probing process itself must appear in any real
     table.

5. **An unresolvable read ABSTAINS.** Exit codes are the contract: **1** = positively `absent` or
   `zombie` (the only shapes that may witness `dead`); **2** = `unknown`/`unreadable`/`off-fence`
   (**never** a death witness); **0** = `holder`. A **live process whose recorded start is
   off-fence** (stale, wrong, or unparseable) is `unknown`, never `dead` — this is the direction
   the reaper already takes (`stale sibling: no vote`; `SKIP incarnation-unmatched`). A read that
   failed, or a missing/unrunnable probe CLI, is exit 2 and must never be collapsed into exit 1 —
   a probe that did would manufacture `dead` out of a failed `ps` invocation.

6. **Fail-closed abort.** The reaper aborts with exit 3 rather than acting on an unverified
   premise: identity library missing, `ps` enumeration failed, descendant map unavailable, store
   missing/corrupt with candidates present, lock held, log unwritable. The classifier's CLI
   returns **3** for `unknown` and **2** for a usage error — an env/usage failure decides nothing.

> The fence, the zombie rule, non-vacuity, incarnation matching, and the abstention direction are
> all pinned by `tools/fleet/liveness.test.py` (T1–T24 with 31 paired mutations) and by the
> reaper's own suite (`scripts/pi-reap-idle.test.sh`).

---

## 4. The abstention doctrine

**`unknown` is a first-class answer.** It always carries a **named reason** — never a bare
`unknown`, never a weaker `wedged` — and exit code 3 marks it at the CLI. Absence of evidence is
not a stall.

| reason | meaning |
|---|---|
| `ps-unreadable` | the `ps` read failed; nothing was decided |
| `store-unreadable` | the hook store is missing, corrupt, or shape-drifted |
| `jsonl-age-unknown` | the session file could not be aged, so non-growth cannot be proven |
| `no-holder-record` | the candidate set is empty (the non-vacuity guard) |
| `off-fence` | a live process whose recorded start could not be matched |
| `incarnation-unmatched` | no fenced holder and at least one candidate abstained (not all abstainers `off-fence`) |
| `turn-state-unknown` | the transcript tail could not be read as a turn boundary |
| `turn-unknown:<stopReason>` | on a message carrying **no** tool calls, the last assistant message's `stopReason` is outside `TERMINAL_STOP_REASONS` — unrecognized is not terminal (#1272) |
| `tail-after-compaction` | a compaction entry is the last entry (see below) |

**A trailing compaction tail abstains rather than asserting `wedged`.** pi writes a
`compaction` entry **between** turns and immediately starts the next call — measured by the #1254
unit over the same 426 live session files: 483 compaction entries exist, 477 are followed by a
message entry, and 357 of those are an open `assistant/toolUse`. A frozen transcript whose last
entry is a compaction is therefore **not** evidence that the turn before it ended, and reading it
that way would classify an OPEN turn as resting. The classifier returns
`unknown`/`tail-after-compaction` instead — a **deliberate, disclosed under-report**: the cost is a
lane left unnamed in the diagnostic band rather than one mislabelled. The decision and its revisit
condition are documented in `liveness.py` (`turn_from_jsonl`).

---

## 5. Known boundaries — stated as boundaries

These are **limits of the mechanism**, not bugs. Each is stated so a reader does not over-read a
verdict.

1. **The CPU-provenance field is inert for fleet (interactive) sessions.** `cpu_advanced` /
   `cpu_stall_ms` are tick fields produced by `extensions/task-heartbeat.ts`, which is gated to
   **task children** (`TASK_HEARTBEAT=1 AND PI_MODE=print`; silent in interactive sessions). The
   cmux hook store does not carry them. So the `CPU_LIVENESS_TOOL_NAMES = {"bash"}` refinement
   (`task` deliberately absent, so a CPU-flat nested sub-agent is not mislabelled) is correct and
   tested, but **unreachable for a fleet lane today**. Consequence: **for fleet sessions `wedged`
   rests on JSONL freeze + no un-expired tool veto + no fresh record + a positively OPEN turn in
   the transcript tail** (the only open-turn signal — boundary 2 below) — nothing more. This was
   flagged, not hidden, by the unit-1 report. Since #5389 the tool veto IS fed from the transcript
   (item 2), but the CPU pair is still absent there, so a fleet lane's in-flight tool reads
   `"unknown"` and is bounded by the AGE backstop rather than by `tool-silence`'s 20 min. The
   attribution refinement remains correct — and remains unfed.

2. **The tool-veto layer is LIVE for fleet lanes, fed from the lane's own transcript (#5389).**
   `_tool_from_record` builds a `Tool` from the store record's `toolsInFlight` / `toolAgeMaxMs` /
   `streamAgeMs` / `toolUpdates` fields — and **no record in the fleet store carries them**
   (measured 2026-09-20: **0 of 1409**; re-measured 2026-09-29: **0 of 1011**; the unit report
   recorded 0 of 701). That route is still inert, and **no `ps` child scan was added to make it
   live**. Instead `gather` falls back to `tool_from_jsonl`, which derives the in-flight tool from
   the transcript this module **already reads** for its turn boundary: an assistant message carrying
   tool calls with no `toolResult` after it **is** a tool in flight, and its entry timestamp dates
   the call. The one OPEN shape that is NOT in flight is a `length`-truncated message: pi FAILS
   its calls (`failToolCallsFromTruncatedMessage`, all 78 measured results `isError: true`), so
   the derivation abstains there and the lane keeps the honest `wedged` verdict rather than being
   held quiet to the 4 h backstop by a phantom tool (#5389 review P2). Positive control over the
   **300 most recently modified** lane transcripts: **31–37
   carried a derivable in-flight tool** across repeated runs (`bash` and `task` dominate; `write`
   and `subagent` appear occasionally) where the record path supplies nothing. The corpus is live
   and written to continuously, so the exact integer moves run to run — the durable claim is the
   one that reproduces: the check FIRES, on real transcripts, in the tens.
   The store route stays authoritative when a producer supplies it — it carries two fields the
   transcript cannot (`toolUpdates`, and the `cpuAdvanced`/`cpuStallMs` pair from the task-child
   heartbeat, gated to `TASK_HEARTBEAT=1 AND PI_MODE=print`).

   **What is disclosed rather than implied:** because a derived tool HAS no CPU channel, its
   `in_flight_progress` is `"unknown"` by construction, so on today's fleet inputs the
   `progressing` / `no-progress` arms of the mirrored tri-state do no production work. The live
   behaviour change is (a) itself plus the `unknown` fall-through — the classifier no longer lets an
   unreadable channel expire the veto at S. The tri-state is mirrored so the rule has ONE definition
   for the day a producer supplies the fields, which is what §6 requires; it is not claimed to be
   exercised by fleet lanes today.

   **The derived tool leaves both of those at their fail-closed default**, so `tool_veto_expired`
   takes the AGE backstop (4 h; the derived tool sets `turn_active=True`, the fail-closed choice, so
   the 30 min branch is not reachable from it) rather than `tool-silence`'s 20 min. That is a
   reprieve from S, not an exemption from the ceiling: the watchdog's own `tool-stall` backstop is
   **progress-blind** (no CPU conjunct), so for a tool with no readable CPU channel the watchdog's
   cut and this veto land on the SAME bound. The classifier therefore does not stand quiet where
   the watchdog had already cut — it holds LONGER than `tool-silence` would, and exactly as long as
   `tool-stall` does — and every shape with a readable tool age is bounded (T9: never forever), because a clause that does not fire falls through to the backstop rather than holding the veto open. §5 item 2's
   pre-authorisation ("a consumer supplying the fields ... would make it live — that is a wiring
   change, not a new rule") is discharged by a READER change, not a new writer; the other clause it
   offered — "a `ps` child scan" — was not needed and was not built.

3. **The turn boundary is a bounded, backwards read.** The scan reads at most 256 KiB from EOF
   (growing to a 16 MiB cap only if no message entry is found — a shape pi does not write). The
   bound is safe because the boundary is always at the end; over the 426 live session files every
   one had a message entry inside the first 256 KiB.

4. **The population comes from the durable store; closed panes are filtered out when the cmux
   layout is readable.** The store retains workspaces whose pane has since been closed (measured
   on this host: 8 of 34), so they can appear only on the fallback path. The driver filters
   to the set of workspace ids cmux currently has open (read from cmux's persisted layout — the
   `cmux` CLI is **unusable from launchd**, which refuses non-cmux callers), and falls back to the
   store's own workspace set, **saying so in the report**, if that file is unreadable. It never
   falls back to an empty population.

5. **Escalation is `dead`-only, and only for a still-active lane.** `wedged` / `idle` /
   `running-quiet` / `unknown` are **reported** with their evidence but do not file an issue — a
   reporting fix is not a licence to escalate a diagnostic state. A `dead` lane files only while
   its last activity is within the reaper's 24 h idle proof; older ones are still *listed* as dead
   but withheld from escalation (retirement, not a stuck lane).

6. **No liveness input is read from a PR or issue body.** The verdict's inputs are the store, the
   session JSONL, and a fresh `ps` read. Other tooling on the merge rail does read PR bodies — the
   compliance gate (`scripts/check-pipeline-compliance.sh`) and `scripts/record-review.sh` — but
   none of that output is an input to a liveness verdict. Where this doc cites an
   issue or PR number, the citation is a **pointer**; the substantive claim is cited to code, a
   test, or a stated measurement.

---

## 6. What is superseded

A reader must not trust two contracts for one rule. Concretely:

- **The pre-#1254 rule "a frozen transcript ⇒ `wedged`" is retired.** `wedged` now requires
  positive per-case evidence of an **open turn** (§1). The retired rule mislabelled the fleet's
  normal resting state as a stall.
- **The pre-#5389 rule "silence alone expires the tool veto" is retired.** `tool_veto_expired`'s
  `tool_updates` branch required only `silence_age_ms > S`, while the watchdog's `tool-silence`
  clause now requires output silence **AND** positive no-progress evidence
  (`inFlightProgress === "no-progress"`, `extensions/builtin-tools/index.ts`). Two contracts for
  one rule — the defect this section exists to name — so the classifier was updated in the SAME
  change: `progressing` SUPPRESSES the expiry, `no-progress` expires it at S, and `unknown` falls
  through to the AGE backstop. A streamed-then-silent tool with no CPU channel reads
  `running-quiet` until that backstop, never `wedged` on silence alone.
- **The three `~/.pi/agent/state/` detectors are not the liveness authority** and never were a
  tracked one: `map-sessions.py` reads no process, and `stall-sweep.py` / `stale-stuck.py` derive
  their population from live processes, so none can emit `dead`. They also **disagree with each
  other** — `stale-stuck.py` vetoes `STALE-STUCK` behind a live tool child, while
  `stall-sweep.py`'s tool-child branch sits **after** two `STUCK` branches — the same evidence,
  opposite effect. That divergence is the "two contracts for one rule" defect; the fix is to route
  them through this verdict (unit 4), not to trust their output.
- **A bare existence check is not an identity rule.** `os.kill(pid, 0)` (the `kill -0` class)
  cannot distinguish a reused pid from a live holder and has no zombie rule. The #1178 amendment
  required promoting the existing `PID DEAD` predicate (`fleet-health.py`'s `_alive()`) through the
  shared library rather than adding a fourth opinion. **What shipped is the tracked, scheduled
  driver** (`lane_liveness.py`) using the **fenced** probe; `fleet-health.py` itself lives in an
  untracked state directory and was **not** rewired (unit 4 is blocked on its repo-home decision).
  It remains a second, weaker opinion on this host — treat its `PID DEAD` as a weaker form of
  `unknown`, not as this verdict.
- **`lane-watchdog.py` signalling by pid alone — retired (#1696).** The wedge reaper derived
  identity from its own `ps` table and never re-checked it between the measurement and the
  `os.kill`, so a pid recycled inside that window received a SIGTERM meant for a corpse. It now
  forks the rule above at signal time and withholds the signal on anything but `holder` — including
  a victim it cannot fence at all, because an unrunnable rule is `unknown` and `unknown` never
  authorises a kill.

---

## 7. Where it runs, and how to run it

**Scheduled.** `templates/launchd/com.eldato.lane-liveness.plist` installs the job
`com.eldato.lane-liveness` (`StartInterval` **1800 s**). It runs with no orchestrator alive —
which is the point: a pull tool is silent in exactly the scenario the owner requirement names
("a way to check which lanes are stuck, independent of the orchestrator being dead"). Farmed
copies live under `~/.pi/agent/scripts/fleet/` and `~/.pi/agent/scripts/lib/`, outside launchd's
`~/Documents` wall; the plist pins `PI_PID_IDENTITY_LIB` explicitly so the resolution is
auditable.

**Exit discipline** (mirrors `scripts/fleet-cost-weekly.sh`): `0` clean · `1` escalation (a dead
lane; a deduped issue unless `--dry-run`) · `2` env/usage error, nothing decided, no issue filed.
The report is appended to a capped durable log (`~/.pi/agent/state/lane-liveness.log`).

**Ad hoc:**

```bash
# one session, one verdict (exit 0 for a named state, 3 for a named abstention)
python3 tools/fleet/liveness.py --sid <session-id>
python3 tools/fleet/liveness.py --sid <session-id> --json

# the whole fleet; no GitHub side effects (it still appends to the durable log)
python3 tools/fleet/lane_liveness.py --dry-run
```

**After any change to the rule, re-run the pinned suites** (the mutation suite proves each test
fails without its fix):

```bash
python3 tools/fleet/liveness.test.py               # 24 tests
python3 tools/fleet/liveness.test.py --mutations   # every mutation must go RED
bash scripts/pi-reap-idle.test.sh                  # the reaper's regression gate
python3 scripts/orphan-reap.test.py --mutations    # the `pi` pool's gates + the fence-default pin
```

The last suite is also the only place the fence default is pinned against
`scripts/lib/pid-identity.sh` (`fence_matches_canon`), so a change to the identity rule that skips
it leaves that divergence unpinned.

---

## 8. Claim provenance

This doc's value is being **true**. Claims are labelled by how they were established:

- **Code-verified** — file/symbol references above (`tools/fleet/liveness.py`,
  `tools/fleet/lane_liveness.py`, `scripts/lib/pid-identity.sh`, `scripts/pi-reap-idle.sh`,
  `extensions/task-heartbeat.ts`). Line numbers were current at `origin/main` `7b8335e`; cite
  symbols on drift.
- **Measured, and where** — the stop-reason table and the compaction-tail statistic (426 live
  session files, recorded in `liveness.py` by the #1254 unit); the store field count (**0 of 1409**
  records carry any heartbeat/tool field, this host, 2026-09-20); closed-pane count (8 of 34);
  every session file having a message entry within 256 KiB.
- **pi behaviour (third-party)** — the meaning of `stopReason` (`length` **fails** the truncated
  calls and continues the turn; `error` / `aborted` discard them), where pi writes a compaction entry, the session JSONL layout,
  and the `--session <id>` resume form. These are established by the measurements named above and
  by the classifier's own parsing tests, **not** by a documented pi contract. If pi changes them,
  the measurement is what must be re-run.

**Not claimed here:** anything about how the reaper decides to kill (see
`docs/ops/pi-idle-repl-reaper-policy.md`), the merge rail's wait bound (#1167, a different
target), or the compaction clamp (#1213 / #1214 / #1215).

---

## 9. Successor dispatch must carry a liveness proof (#1317)

Everything above answers *"is this lane alive?"* for a lane you already know about. This section
answers the dispatch-time question that the 2026-09-21 incident turned on: **may a successor lane be
sent to this worktree?**

**The rule.** A dispatch that says *"the predecessor is gone / is out of context"* is a **state
assertion**, and it must carry the reading that shows it. Before a successor is written, run:

```bash
python3 tools/fleet/successor_preflight.py --worktree <the successor's worktree> \
    --emit "$O/logs/prompt-<N>.txt"      # appends the proof to the dispatch file
```

and put the proof block in the dispatch file. Its exit code is the dispatch decision:

| exit | verdict | action |
|---|---|---|
| 0 | `PREDECESSOR-GONE` | dispatch the successor — the unit is free |
| 3 | `PREDECESSOR-LIVE` | do **not** dispatch a successor; **nudge the live lane, or wait** |
| 4 | `UNKNOWN` | could not verify — fail closed, do not dispatch |
| 2 | usage / environment error | **nothing was decided** — a bad argument, an `--emit` that could not be written, or a `--worktree` that is not a readable directory. A target that does not exist is **never** reported `GONE`: *"there is no directory here"* and *"I proved no predecessor holds it"* are different facts, and a dispatcher switching on the exit code must be able to tell them apart |

**Why the proof goes in the dispatch file.** The incident's defect was not a wrong reading — there
was **no reading**. A brief that carries `verdict: PREDECESSOR-LIVE` and its `read-at` timestamp lets
a later reader (and the successor itself) tell *"the predecessor is gone"* from *"the predecessor was
assumed gone"*. `--emit` **appends**, so the proof sits beside the brief it justifies and re-running
never rewrites history.

### 9.1 The three reads, and which two decide

The issue proposed two inexpensive reads plus a cmux reading. They are not equally strong, and the
tool encodes the difference rather than treating them alike:

| # | read | weight |
|---|---|---|
| 1 | a live `pi` whose **cwd is the target worktree** (`pgrep -x pi` + `lsof -a -d cwd -Fn`, `/proc/<pid>/cwd` on Linux) | **authoritative** — a `pi` rooted in the worktree is its owner, whether it is mid-tool or at a prompt (*idle is not available*) |
| 2 | every **lane record** whose `cwd` is the worktree, verdicted by the ONE predicate (§1–§4: `liveness.gather` + `liveness.evaluate`) | **authoritative** — catches a predecessor whose transcript stopped growing (a record outlives its process) |
| 3 | the cmux workspace's `latest_submitted_at` / `updated_at` | **corroborating only** — see below |

⛔ **Read 3 is `INBOUND` activity, not liveness.** `scripts/lane-status.py` states this in
`_inbound_message`: `latest_submitted_at` is what someone *sent* the lane, and it *"is not evidence
of liveness and must never be read as such"*. The preflight therefore uses it in the **safe**
direction only — recent activity is a *sufficiency* signal for "do not dispatch a successor" (the
issue's intent), never a reason to call a predecessor alive against reads 1 and 2. Its
**unavailability never decides the verdict alone**: on a box where the `cmux` CLI is unreachable
(launchd: *"Access denied — only processes started inside cmux can connect"*) a gate that required
it could never open, which is the no-op-gate class this fleet has already paid for. An unreadable
cmux is stated in the proof (`cmux: unread (corroborating only …)`); it does not force `UNKNOWN`.

**No second liveness rule.** The preflight imports `lane_liveness` and calls
`lane_liveness.verdict_for` — the same predicate the scheduled report and the kill-path reaper
consume. A local re-implementation of "is the lane alive" is the exact defect #1178 exists to
remove. The preflight adds only the **worktree-scoped question** (which lanes/processes are rooted
*here*) and the decision ladder.

⛔ **A read is complete, or it is not a reading.** `readable` does not mean "the command returned" —
it means **every pid we asked about was answered**. The two ways a read can fail to cover the list
are different facts, and only one of them is evidence:

- a pid the reader could not stat/read — `lsof` exits `1` and **omits** it (another uid's process);
  `EACCES`/`EPERM` on `/proc/<pid>/cwd` under `hidepid`; `EINVAL` on a non-symlink — is a
  **refused** read → `UNKNOWN`;
- a pid that is provably **gone** (`ENOENT`: it exited between `pgrep` and the read) **is** an
  answer — it holds no worktree — which is why the `/proc` fallback can *complete* a partial `lsof`
  read rather than abstaining. That reading holds **only against a root that is a procfs**
  (`<root>/self` exists): against a path that is merely some directory, `ENOENT` says nothing about
  the process table, so the read is refused instead.

**Absence of an answer is never evidence of absence.** Scoring a partial read as a complete one is
how a live predecessor owned by another uid reads as *"no agent in this worktree"* and the tool
emits the very `PREDECESSOR-GONE` the incident is about.

**The proof names its readers.** The block carries `readers: pgrep=… lsof=… cmux=… proc-root=…
store=…`, because an inherited `SUCCESSOR_LSOF_BIN` or a non-default `--store` changes what was read
— and a proof that reads as though the default tool had answered is exactly the *"was assumed gone"*
shape this section exists to eliminate.

**The target is never rewritten.** ` (deleted)` is the *kernel's* spelling of a cwd, so it is
unwrapped where the kernel emits it (the cwd comparison, `live_pids_in_worktree`), never inside the
path normaliser: a `--worktree` that itself ends in ` (deleted)` must stay byte-identical to what the
caller asked about, or the tool decides about a directory nobody named. (Same class as the read-side
bug: one path silently acquiring another's identity.)

### 9.2 The decision ladder — order is the safety property

Each step is a return; nothing later can override an earlier verdict:

```
0. a live pi rooted in the worktree                          -> PREDECESSOR-LIVE
1. the lane store is unreadable                              -> UNKNOWN
2. any lane record on the worktree that is not `dead`        -> PREDECESSOR-LIVE
3. recent cmux activity on the worktree                      -> PREDECESSOR-LIVE
4. the process read could not be COMPLETED                    -> UNKNOWN
5. both authoritative reads ran and found no live witness    -> PREDECESSOR-GONE
```

**LIVE beats GONE at every step, and `UNKNOWN` is not a weaker `GONE`** — a reading we could not take
is never a predecessor we proved absent. This is the same direction the kill path already runs on
(*"no proof ⇒ not idle ⇒ never kill"*, `pi-idle-repl-reaper-policy.md`), applied to dispatch. The
failure directions are deliberately asymmetric:

- a false `PREDECESSOR-GONE` puts a **second lane on a live unit** — the #1317 incident;
- a false `PREDECESSOR-LIVE` **delays** a dispatch, and the proof block says why — friction a human
  can read past.

⛔ **No open-workspace filter.** The scheduled report drops closed cmux panes from its population so
a retired workspace is not reported on. The preflight does **not** use that filter to shrink the set
of lanes it will refuse for: a lane record for this worktree that is not provably `dead` blocks the
dispatch whether or not cmux still lists the pane. Over-blocking is friction; under-blocking is the
incident.

### 9.3 What is NOT wired, stated plainly

There is no automated successor-dispatch hook point today: a successor is dispatched by an
orchestrator session writing a brief, not by a script. `successor_preflight.py` therefore ships
**standalone + documented**, exactly like `scripts/check-handoff-size.sh`
(`session-lifecycle-contract.md` §2) — the check is the enforcement, the rule is this section.

The neighbourhood was checked before leaving it unwired: `dispatch-merge.sh` starts a lane and a
chain for an issue but its `tmux new-session -s lane-<N>` already refuses a duplicate session name;
`scripts/orch-send.sh` dispatches to a **live** lane (its guards are about the *target*), not to a
successor; and `scripts/queue-dispatch.py` fed idle lanes — **retired 2026-10-17** (agent-infra#1874):
the beat's only dispatch entry point is now `scripts/pr-doctor.py`, and the retired source is kept at
`scripts/orchestrator-harness/retired/queue-dispatch.py`, wired to nothing. None of them is the
successor path.
The ported `scripts/orchestrator-harness/` is held by concurrent lanes and pinned to a tortoise sync
point (`port-provenance.txt`), so wiring a new hard gate into it is a separate change with its own
review.

⚠️ **The existing PR-rail idempotence check would NOT have caught the incident.** `scripts/pr-loop.py`
skips a PR whose lane id still appears in `cmux list-workspaces` output — but in the incident the
predecessor's workspace `D77AC55C` **did** exist (it had a submitted message at 22:01:58Z). Workspace
*presence* is not worktree *occupancy*; the worktree-scoped process read is the missing piece.

The lane store path defaults to the fleet's canonical `~/.cmuxterm/pi-hook-sessions.json` (#1178) and
is overridable with `--store` (as are the sessions, task-session and cmux-state roots); a dispatcher
on a non-standard home names them explicitly, and an unreadable store is `UNKNOWN` — never `GONE`.

Run the pinned suites after any change to the preflight (the red control proves each leg fails
without its fix):

```bash
python3 tools/fleet/successor_preflight.test.py               # 22 legs
python3 tools/fleet/successor_preflight.test.py --red-control # 15 mutations, each must go RED
python3 tools/fleet/liveness.test.py                          # the predicate it consumes
```

The procfs is a **hermetic fixture** in the suite (`--proc-root`), so the `/proc` fallback is
exercised by a leg rather than assumed — including the two shapes that must abstain (a refused
`cwd`) and the one that is a real answer (a pid that is gone).

---

## 10. `idle` must pass through Step 2, and a stale binding is never verified (#1867)

§9's rule — *liveness must be proven from an artifact, not from a record* — has a second surface: the
**lane classifier** (`scripts/lane-status.py` → `scripts/lane-actions.py`), whose verdicts and
`NEEDS-ACTION.md` lists the beat, `queue-dispatch.py` and a human act on. Measured 2026-10-16 20:47Z: a
lane whose `ps -o time` advanced **+4.93s over 25s** (pane showing an active spinner, transcript mtime
current) was published as `DONE_READY` (the words-layer label, over the mechanical
`DONE-IDLE — no session write for 13h34m`), and the beat prescribed *"hand each the next unheld
item"* — into a lane at 85% context, mid-turn. Two independent causes, both of them **a record
standing in for a proof**:

**Scope, stated so this section is not read as closing more than it does.** It covers the
`lane-status.py` verdict, the `lane-actions.py` lists, and one in-repo consumer of the verdict that
the first draft of this section left out: `scripts/turn-classify.py` reads `lane-status.py --json`
and its busy guard was a BLACKLIST, so the new label arrived there as *not busy* — a lane proven to be
consuming CPU was still messageable, falsifying the "never dispatched" property the label is minted
for. That guard is now the explicit pair `BUSY_VERDICTS` / `PROCEEDS_VERDICTS` (re-review,
2026-10-20), asserted to partition `lane-status.PUBLISHED_VERDICTS`, so a verdict this section has
not thought of cannot arrive as "not busy" either. It does **not** cover the beat's `CAPACITY`
clause, which `orchestrator-heartbeat.sh` takes from `lane-triage.py` (a `$HOME/.pi/agent/state/` tool,
not a repo file), nor `queue-dispatch.py`'s own `DONE-IDLE` gate, nor `pr-doctor`: all read
`lane-status.py --json` **directly** and none was changed here, so a false-capacity line from those
paths is not closed by this section.

| # | cause | rule now enforced |
|---|---|---|
| **a** | `lane_cpu_busy()` answers only with **exactly one lane ↔ exactly one pid**. A `task` **child is a second pi in the lane's own cwd**, so every lane waiting on a child got `None` from Step 2 — and `None` is *unread*, not *parked*. Step 2 was then skipped, and the verdict was taken from the transcript mtime alone. | `lane_cpu_progress()` answers the weaker question — *did a pi in this lane's own directory consume CPU?* — and returns **only `True` or `None`, never `False`** ("no pid I could see moved" is not "parked"). In a one-lane directory the work counted is this lane's or its child's. It yields `UNATTRIBUTED-WORKING`: **reported, never dispatched, never unblocked**. Deliberately not `WORKING`, which would short-circuit a real `WEDGED`/`CHILD-STUCK` on a child spinning under a stalled parent. It vetoes **only the idle family**: it is asked *below* the child branches (a `cpu_any` read cannot say WHICH pi burned the CPU, so it may not overrule a diagnosis of the child) and *above* every idle proxy. |
| **b** | the pane's resume record was **stale**. `resolve_session_ex()` treated a pane-provided id as authoritative even when the bound file had been quiet for 13h while *another* session file in the same directory was written in the same minute — a hand relaunch (`pi --session <id>`) leaves cmux carrying the old id. | a quiet bound file **plus a fresh sibling writer in the same directory that names no other registered lane** is an *unconfirmed* binding: `verified=False`, which makes the consumer abstain (`UNVERIFIED-SESSION`) — never `idle`, never `dead`. **"NAMES" MEANS THE WHOLE NAME** (re-review, 2026-10-20): a writer whose first user message names a co-located lane is that lane working, not evidence about this one, and the exclusion requires **every** token of the label (`need="all"`); a match landing only on ordinary words — or a label built only from them — is not a name at all (`GENERIC_LABEL_TOKENS`). The half-token rule was inert for the writer shape this rule exists for: a `task` child shares the lane's cwd, so its transcript *is* the fresh sibling, and its prompt is prose containing "test", "compile", "cloud" — measured lane names `Test substrate`, `2c Pack compile`, `cmux cloud` were all "named" by one ordinary word, which left the 13h binding `verified` and `DONE-IDLE` dispatchable. |

**How narrow that exclusion is, stated because an earlier draft of this row over-claimed it.** It
fires only for a writer whose transcript carries *every distinctive token* of *some roster label*. It
therefore does **not** rescue the measured nine-lanes-one-cwd case in general: a co-located lane
relaunched by hand writes whatever the operator typed, so a writer that names nobody (this section's
own premise for the stale-binding case), one that names only its label's ordinary words, or one whose
label is built only from ordinary words (`2c Pack compile`, `1 Capture`) is an UNEXPLAINED writer —
and every quiet lane sharing that directory then reads `UNVERIFIED-SESSION` for as long as the
writer's file stays fresh. The consequence is concrete: `lane-actions.py` returns
`UNVERIFIED-SESSION` with `action="report"` at Step 0, *before* the `DEAD` test (`:496`) and before
the child branches, so for those lanes `DEAD` / `WEDGED` / `CHILD-STUCK` are withdrawn and the lane
is never offered. That is the fail-closed direction this rule already chooses (report-only: no
dispatch and no relaunch), and it is recorded as a residual below rather than left implicit.

**Ordering — the two halves rank differently, and that is the rule.** Only the **strict** `cpu` read
(exactly one lane ↔ exactly one pid) is asked *before* the Step-0 identity abstentions: it names the
lane's own pi, so it is evidence about the **lane**, not about which session file the pane was
launched with, and it settles the question the binding was going to answer. The **weaker** `cpu_any`
read ranks *below* identity, existence and child evidence — it cannot say WHICH pi advanced, so
ranking it higher would short-circuit a real `CHILD-STUCK`/`WAITING-CHILD` (a lost unblock, and one
this change reproduced before the ordering was fixed) — and it vetoes only the **idle family**.
Consequence, stated so it is not mistaken for a gap: on the measured lane (stale binding **and**
unattributed progress) `lane-actions` publishes `UNVERIFIED-SESSION`, not `UNATTRIBUTED-WORKING`;
both are report-only, and neither dispatches nor unblocks. Every one of these rankings can only move
a lane *out* of an action list.

**Polarity.** Both answers fail toward `UNKNOWN`/report-only. Positive progress can only *suppress* an
offer of work; it never invents one, and it never prescribes a relaunch. `UNATTRIBUTED-WORKING` is
printed by `lane-status.py` (the human table's VERDICT column is sized for its 20 characters),
carried in `--json`, listed in `lane-actions`' **report** section, treated as **busy** by
`scripts/turn-classify.py` (no classifier call, no CONTINUE), and — since it *is* proven CPU
progress — counted as **active** by `orchestrator-heartbeat.sh`, which deliberately neither alerts on
it (it prescribes nothing) nor, before this change, counted it at all.

The suites that pin it: `python3 -m pytest scripts/test_lane_status.py scripts/test_lane_actions.py
scripts/test_turn_classify_state.py` (all three are in the `python-ci` `test-command` in
`.github/workflows/ci-main.yml`; no new test file is added, so there is no surface to register).
Measured non-vacuity, on both baselines: **23 of the 27 added pytest legs fail on `origin/main`**
(pre-feature) and **10 fail on this change's earlier reviewed head `a5a66d8ee`**. The re-review's
five, all of them matching the fail-open direction the strictness closes: a child's prompt containing
one ordinary token of another lane's label; a match landing only on ordinary words; a label built
only from ordinary words; the same looseness in `_content_session` (the lane bound to its CHILD's
transcript); and the sibling transcript re-parsed once per excluded label instead of once per file.
Two earlier five-leg groups are also in that set: the veto's reach over `CHILD-STUCK`, a writer that
names nobody, the v3 session-envelope parse, the table's verdict width, and the CPU veto's rank.
This round added six: two that pin the **narrowness** of the exclusion as behaviour (a co-located lane
whose label is built only from ordinary words still does not explain a writer, and such a label has no
`_content_session` recovery), and four that close the consumer gap — a lane published
`UNATTRIBUTED-WORKING` must never reach `turn-classify.py`'s classifier, its control proves that gate
is otherwise live by letting `WEDGED` through, every `BUSY_VERDICTS` member must be wired to it, and
the busy/proceeds pair must partition `lane-status.PUBLISHED_VERDICTS` so the next new verdict cannot
arrive as "not busy".

Four legs pass on every baseline **by design**, each paired with a leg that fails on `origin/main`:
the controls `test_a_stale_binding_with_no_live_writer_stays_verified`,
`test_a_fresh_writer_that_names_another_lane_does_not_unverify_this_binding` and
`test_the_classifier_gate_still_lets_a_stopped_lane_through` (the `control:` assertions inside the
new legs — a writer that really names the lane still explains itself — are of the same kind), plus
`test_the_cpu_veto_is_consulted_at_the_decision_not_only_in_a_comment`, which replaces a
source-substring assertion with a behavioural one over behaviour no round changed.

**Residual, stated rather than implied:** the exclusion list is the whole roster, not the roster's
lanes on this cwd, because `registry()` carries no cwd (label, workspace uuid, issue label) and the
sessions dir name is a mangling, not a reversible path. A distant lane's FULL distinctive name still
explains a writer here; that can only suppress an abstention, never invent one, and it is bounded by
the whole-name requirement above.

**Residual 2 — the exclusion is narrower than "a shared dir is handled", and the narrowing costs a
diagnosis.** A writer is excluded only when its transcript carries every distinctive token of a
roster label, so a shared sessions dir can still go `UNVERIFIED-SESSION` for every quiet lane in it
(see *How narrow that exclusion is* above), and the same requirement is what `_content_session`
uses — so a label built only from ordinary words (`2c Pack compile`, `1 Capture`) has **no**
manual-relaunch recovery at all: its relaunched session is never adopted and the lane stays bound to
the stale file it was bound to before. Both are fail-closed (`report`-only, never a dispatch, never
a relaunch) and both are pinned by tests rather than asserted. The discriminator that would close
them is an identity signal stronger than the first user message — e.g. skipping sibling files that
resolve to this lane's own `task` child (`pending_children` / `find_child_session` ids) so the
abstention is aimed at writers that are demonstrably a child of *this* lane rather than at writers
nobody can name. Deliberately not attempted here: it swaps a proven-safe over-block for a new
fail-open surface, which is not a trade this section makes without measurement.

---

## 11. Process-level liveness — the fleet's COMPONENTS

§§1-10 answer "is this LANE alive". They deliberately cannot answer *"is every fleet PROCESS alive,
exactly once, and on this box at all"* — the question the owner asked on 2026-10-18 after four silent
failures in one night: a second controller running beside launchd's, controllers absent on two of
three cells, `pr-doctor` exiting 2 on every run for hours, `cmux-tui` OOM-killed with the boxes
reporting "no controller", and landers expiring so green PRs waited for a human.

That question has its own inventory, and it is a DECLARATION, not a discovery: `start` can only bring
up what is declared, so an undeclared component can never be started OR checked — which is why the
boundary below is stated rather than implied. It lives in **`scripts/lib/fleet-inventory.sh`**, and it is reached through the fleet's ONE entry
point — `scripts/orchestrator-bringup.sh` (`check | start | stop | restart | status`), the same script
that owns the per-`(machine, repo)` redundancy guard. No fourth launcher.

**`status` prints one table and its exit code is the worst row:**

```
COMPONENT   EXPECTED   ACTUAL   STATE
```

| state | meaning | exit |
|---|---|---|
| `OK` | the component's own signal says alive + fresh | 0 |
| `LATE` | alive, its own freshness signal is older than its own bound | 1 |
| `MISSING` | expected here and absent | 1 |
| `DUPLICATE` | more than one live instance | 1 |
| `FAILING` | present but reporting failure (non-zero last exit, a pidfile naming the wrong process) | 1 |
| `SKIPPED` | NOT APPLICABLE here — always with a reason; never rendered as `OK` | 0 |
| `UNKNOWN` | the check itself could not run (unreadable `ps`, unparseable job) | 2 |

`SKIPPED` is a PASS for the exit code *and* a distinct state, because "not checked" and "checked and
healthy" are different answers, and a Mac is not broken for having no cell supervisor. `UNKNOWN` is
the abstention doctrine of §4 applied to this surface: an unreadable read is never a pass.

**Each predicate is derived from the component's OWN behaviour** — never "pid exists":

| component | predicate |
|---|---|
| `controller` | lock owner cross-checked against an `orch-loop.sh` invocation, plus `$O/heartbeat` age (a live pid with a frozen heartbeat is *wedged*, not healthy) |
| `controller-watchdog` | at least one of the launchd watchdog job / `watchdog-loop.sh` is live, and if the JOB is present its last exit is still read: a failing job is `FAILING` ("the plain loop is still covering, which is why this is not fatal") even though the pair is fine. **The pair is NOT a duplicate**: both invoke the same idempotent `watchdog.sh` (check → load → log → exit), so they cannot disagree about the desired state, and the plain loop is the deliberate stopgap that survives the launchctl being defeated (`watchdog-loop.sh`'s own header; #1976). The row says so in its ACTUAL column ("redundant by design"). `DUPLICATE` is reserved for the same mechanism twice — two `watchdog-loop.sh` processes, which really do run every action twice |
| `heartbeat-loop`, `cadence-timer` | the pid its OWN pidfile names, cross-checked against a process whose argv is that script (a recycled pid is `FAILING`, not alive), plus that loop's **own** freshness signal — and "own" is load-bearing: the cadence timer used to be judged by `orchestrator-heartbeat.log`, which the *heartbeat loop* appends to every pass, so its `LATE` branch could only fire if BOTH loops stopped. It now writes `cadence-timer.beat` per tick, and that beacon is what the row reads. A copy of the script installed **before** the beacon (farmed copies lag the repo) logs `CADENCE-TIMER started pid=…` and no beacon, and the row says so — `LATE`, with the stale copy named and the re-sync named, rather than a permanent red whose reason blames a healthy loop |
| `pr-doctor`, the reapers | **loaded** in the domain + **last exit 0** + a freshness file within 2× their OWN `StartInterval` (a 6 h reaper is not judged by a 20-min reaper's clock). Between runs `pid` is legitimately `-`, so "pid exists" is the wrong predicate — and "last exit status" is the readable datum nobody was reading. The freshness file is the job's declared `StandardOutPath`/`StandardErrorPath` when it declares one, otherwise **the log the component's own script writes** (the four reaper templates deliberately declare no output path, so for them it is always the own-log) (`pi-reap-worktrees.sh:190`, `cleanup-stale-branches.sh:2411`, and the session reaper's/lane-liveness's own logs). A job with NEITHER is `UNKNOWN`, never `OK` — a job launchd stops scheduling is otherwise indistinguishable from a healthy one |
| `cell-supervisor` | applicable on a cell ONLY (`SKIPPED` on a Mac with the reason; `UNKNOWN` when the platform is *unset*, because "cannot answer" is not a pass); the process plus its tmux session, because an OOM-killed `cmux-tui` leaves a live supervisor with a gone session. A **cell** is a box that carries a cell's identity that was **provisioned**, not defaulted: an explicit `$STATE/.cell` marker, or a cell home that actually holds one (`keys.env`, `.harness-path`). `bringup` defaults `CELL_HOME=/tmp/cell-home`, so "the variable is set" is not evidence — and the kernel alone certainly is not, since `uname -s = Linux` is what `bringup` maps to `PLATFORM=cell`; keying on either would make every Linux dev box and CI runner permanently red for a supervisor it does not have |
| `landers` | demand-driven, so 0 live is normal — the failure is a waiter OLDER than its own bound (90 min wait plus the rail), which is the "expired silently" state |

**Three states, and "not installed" is not one of them when the code is here.** A component whose
**job definition is absent** has two very different causes, and rendering both as `SKIPPED` (a pass) is
how the component that motivated this file stayed green by absence: `com.tortoise.pr-doctor` and
`com.eldato.orchestrator-watchdog` are installed by **no surface in this repo** (they are
hand-provisioned), so on a box built by the repo's own installers both rows hit `SKIPPED` *and* `start`
could not act on them (`fleet_component_has_start` needs the plist). The rule is now: **if the
component's own code exists on the box, something is expected to run it**, and a missing job is
`MISSING` (actionable, and it fails the table). `SKIPPED` is reserved for a component whose code is
absent too — it genuinely does not exist here — and it always carries its reason.

**Two scopes, one verdict (the controller row).** The controller is counted from THIS state dir's own
`orch-loop.sh` plus the pid `$O/.orch.lock` names (verified alive AND an `orch-loop.sh` invocation, so
a recycled pid contributes nobody). Processes matching the **shared harness** path are reported and
never counted: that path is one directory per cell home, so on a box running two repos it returns repo
A's controller to repo B — counting it would report `DUPLICATE` for a healthy two-repo box (#1761
supports exactly that) and tell an operator to stop the other repo's live controller. When a
harness-path controller exists and no lock owner attributes it, the row is `UNKNOWN` ("declaring the
population it could not consult") rather than a false `MISSING`.

**Self-match safety is structural.** A component matches only when a process's argv is
`<interpreter> <EXACT path>`; descendants of a match are excluded (`orch-loop.sh` spawns children that
match too), and the checker's own pid is excluded (`q == self`). **Ancestors are deliberately KEPT** —
a health read that runs beneath the controller (a tick added to `orch-loop.sh`, a lane child) must
still count it; excluding ancestors was measured to read a live, fresh controller as `MISSING`. That is what makes
`bash -c 'pkill -f pr-doctor.py'`, a `tail -f …/orch-loop.log`, and the checking script itself
non-matches — the `pgrep -f` self-match that "bit us repeatedly".

**The verbs, and what each exit code means.**

- `start` brings up the controller through the platform verb (with the per-`(machine, repo)` redundancy
  guard), then every `MISSING` component **this box has a mechanism for**, and `kickstart`s a
  `FAILING` launchd job (a job that ran and failed is repaired by a re-run). A component with no
  mechanism here is NAMED and not attempted. An unreadable process table makes `start` return **2**
  ("cannot determine") — it never reports "every component is already OK" from a read it could not
  perform.
- `stop` stops the controller through the platform verb, then every other present component, with
  `bootout` for launchd jobs (never `unload -w`/`enable`: **no persistent disable is written**, so
  `start` always puts them back) and a bounded wait + a domain re-read after each stop — a stop that
  did not happen is reported as not stopped. `landers` and the `cell-supervisor` are deliberately left
  running (one is per-change work in flight; the other owns the controller's session).
  ⛔ **`stop` is MACHINE-WIDE**, while this entry point's identity is the pair `(machine, repo)`: the
  heartbeat loop, the cadence timer, `pr-doctor` and the reapers are shared by every repo on the box,
  so stopping from repo B also silences them for repo A. The controller's own agent is still stopped
  by the pre-existing platform path (`launchctl unload -w` in `stop_mac`), which is NOT covered by the
  inventory's `bootout` discipline — `orchestrator-harness/launchd-cycle.sh` is the repo's one
  implementation that never writes a disable (#1975), and routing the controller through it is open.
- **One answer per question.** When a read the operator's controller line depends on abstains (an
  undatable lock owner, an unreadable process table), `status` says `CANNOT DETERMINE` **once**, still
  prints the fleet table, and exits 2. It does not fall through to a confident `RUNNING` line built from
  the same unreadable data — that line is where a healthy box's own controller got reported as
  "another repo's" (#1856's misattribution class).
- **A row it diagnoses, it can repair.** A pidfile loop whose pidfile names a live pid that is not the
  loop is `FAILING`, and `start` clears that record (the row has already proven it stale by the same
  argv-shape predicate) before launching — otherwise the shipped launcher's own pidfile guard refuses,
  the verb reports a failure, and the operator is pointed at the launcher instead of the pidfile.
- `start` reports **what it did** (`started`, or `already running — … left alone`), so a caller can never
  print "started" for a no-op.
- `restart` is stop → **bounded wait for the stopped processes to actually go** → start → verify.
- A `DUPLICATE` is never resolved automatically: a kill driven by a process read is how a healthy
  peer's work is destroyed.

**Two other surfaces write the same launchd domain, and this file does not replace them.** `scripts/
install-launchd.sh` is the installer (it owns `templates/launchd/`), and `scripts/orchestrator-harness/
launchd-cycle.sh` is the repo's one implementation of stop/enable/(re)start that never writes a
disable (#1975). The inventory's `start` deliberately writes **nothing durable** (`bootstrap` /
`kickstart` / `bootout` only), so it is not a convergence trigger: after a `stop`, the installer's
byte-identical-plist skip means a re-install will NOT reload the jobs — **`start` is the undo**.
Neither surface is downgraded by this one; both remain the authority for their own verbs.

**The declaration is hand-maintained, and that is a stated boundary.** A component that is not
declared here is invisible to the table — measured on the box that built this: `com.tortoise.
embedded-reaper` and `com.tortoise.queue-reconcile` are loaded and have no row. Nothing yet compares
the declaration against the launchd domain; adding that comparison is the obvious next seam.

Regression contract: `bash scripts/fleet-inventory.test.sh` (its header carries the mutation
recipe that proves each arm goes red when its predicate is neutered — including the read paths, the
`stop`/`start` verb paths, and the exit-code contract). It is registered in
`scripts/run-bash-shards.sh`, so both CI lanes run it.
