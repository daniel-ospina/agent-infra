---
title: "Fleet session liveness — the five states, the identity rule, and the abstention doctrine (#1178)"
type: engineering
domain: operations
doc_status: live
subjects.team: organisation-design-team
created: 2026-09-20
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, issue-1178, issue-1254, session-liveness, pid-identity, lane-liveness, pi-idle-repl-reaper-policy
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
| `turn-open:no-terminal-stop` | the last assistant message carries no `stopReason` |

A transcript whose last turn ended with a terminal `stopReason` on a message carrying **no** tool
calls (`stop` / `length` / `error` / `aborted`), or with `error` / `aborted` on a message
**carrying** tool calls, is **RESTING**: it reads `running-quiet` (`turn-ended`) however long it
is quiet short of the 24 h retirement proof.

> **pi behaviour, and how it was established.** The stop-reason rule rests on pi's own semantics,
> measured by the #1254 unit over **426 live session files** (the measurements are recorded in
> `liveness.py`): of assistant messages carrying tool calls, `toolUse` 147,466 with 147,431
> answered; `error` 115 with **0** answered; `length` 78 with **78** answered; `aborted` 16 with
> **0** answered. pi **suspends on `length`** to execute the calls, so `length`+calls is an OPEN
> turn, while `error`/`aborted` **discard** their calls. This is third-party behaviour, not our
> contract — if pi changes it, the measurement is what must be re-run.

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

The shared rule, in the reaper's own vocabulary (`scripts/lib/pid-identity.sh`,
`scripts/pi-reap-idle.sh`):

1. **Candidates are a UNION.** The candidate set for a session id is the current store record,
   **every** `priorProcessGenerations` entry, and every pid whose **argv names the session** in a
   resume form (`pi --session <id>`, `-r <id>`, `--resume <id>`, or `--session=<id>`). The union —
   not the newest, not the first — is what stops a resumed session's stale tag from calling a live
   lane dead. Without the argv source, "the record's incarnation is gone" would be silently
   equated with "the lane is dead".

2. **A pid HOLDS a session only if the fence matches.** A fresh `ps` read must show it present,
   **not a zombie**, and its `lstart` must be within **±`FENCE_TOLERANCE_SECONDS`** (default 3 s) of
   the recorded `pidStartSeconds`. The fence exists because second-granularity rounding differs by
   up to ~1 s; its whole purpose is to make an identity *uncertainty* fail safe. An unrelated
   process that inherits a dead session's pid fails the fence and is **not** its holder.

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
> all pinned by `tools/fleet/liveness.test.py` (T1–T19 with 23 paired mutations) and by the
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
   rests on JSONL freeze + no un-expired tool veto + no fresh record** — nothing more. This was
   flagged, not hidden, by the unit-1 report.

2. **The tool-veto layer is inert in the CLI path.** `_tool_from_record` builds a `Tool` from the
   store record's `toolsInFlight` / `toolAgeMaxMs` / `streamAgeMs` / `toolUpdates` fields — and **no
   record in the fleet store carries them** (measured 2026-09-20: **0 of 1409** records; the unit
   report recorded 0 of 701). `gather` therefore leaves `ev.tool = None` for every lane, the veto
   never fires, and **the transcript tail is the only open-turn signal**. The layer is live and
   tested for a consumer that injects a `Tool` (tests T9/T11); it simply has no fleet input today.
   A consumer supplying the fields from a `ps` child scan or a heartbeat would make it live — that
   is a wiring change, not a new rule.

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

---

## 7. Where it runs, and how to run it

**Scheduled.** `templates/launchd/com.eldato.lane-liveness.plist` installs the job
`com.eldato.lane-liveness` (`StartInterval` **1800 s**). It runs with no orchestrator alive —
which is the point: a pull tool is silent in exactly the scenario the owner requirement names
("a way to check which lanes are stuck, independent of the orchestrator being dead"). Farmed
copies live under `~/.pi/agent/tools/fleet/` and `~/.pi/agent/scripts/lib/`, outside launchd's
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

# the whole fleet, no side effects
python3 tools/fleet/lane_liveness.py --dry-run
```

**After any change to the rule, re-run the pinned suites** (the mutation suite proves each test
fails without its fix):

```bash
python3 tools/fleet/liveness.test.py               # 19 tests
python3 tools/fleet/liveness.test.py --mutations   # every mutation must go RED
bash scripts/pi-reap-idle.test.sh                  # the reaper's regression gate
```

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
- **pi behaviour (third-party)** — the meaning of `stopReason` (`length` executes calls;
  `error`/`aborted` discard them), where pi writes a compaction entry, the session JSONL layout,
  and the `--session <id>` resume form. These are established by the measurements named above and
  by the classifier's own parsing tests, **not** by a documented pi contract. If pi changes them,
  the measurement is what must be re-run.

**Not claimed here:** anything about how the reaper decides to kill (see
`docs/ops/pi-idle-repl-reaper-policy.md`), the merge rail's wait bound (#1167, a different
target), or the compaction clamp (#1213 / #1214 / #1215).
