#!/usr/bin/env python3
"""fleet-health.py — liveness scan for the lanes and their task children.

This is a SUSPECT FINDER, not a verdict. A session can work for minutes without writing
to its transcript, so mtime alone proves nothing — confirm any suspect with
`cmux read-screen --workspace <ws> --surface surface:N`.

Strongest cheap "is it actually running" signal: **CPU-time delta** for the pid since the
previous run of this script (state kept in fleet-health-prev.json). CPU time only advances
while the process does work, so a live pid with ~0 delta AND a stale transcript is a wedge.

A pid is **dead only under the fleet's ONE process-identity rule** (#1178). `_alive()` used
to be a bare `os.kill(pid, 0)` — no start-time fence, no zombie exclusion — which was wrong
in BOTH directions, and the directions were MEASURED, not assumed. A pid that a replacement
process had reused, and a ZOMBIE (on which `kill(pid, 0)` also succeeds), read as a LIVING
lane — an empty flag, a FAIL-OPEN that reported a dead lane healthy by silence. The opposite
false `PID DEAD` came from `os.kill` raising for a process that IS alive (`EPERM` on a
foreign-user pid). A failed `ps` read is a shape `_alive()` never had: the promoted path
maps it to `PID ? (unreadable)` — an abstention, never absence (the library's C3 split). The read now goes through
`scripts/lib/pid-identity.sh`, the same library the kill-path reaper sources and the liveness
classifier shells out to. An **unresolvable read ABSTAINS** (`PID ? (...)`) instead of
reporting a death it cannot witness — and an abstention never SUPPRESSES the quiet/CPU
suspect ladder, so an unreadable identity can never turn a stale lane into "no suspects".
"""
import json, os, shutil, subprocess, sys, time, glob

# ── the fleet's ONE process-identity rule (#1178) ────────────────────────
# This module does NOT decide liveness. A Python file cannot source a Bash library, so the
# read goes through the SAME probe boundary the classifier uses:
#     tools/fleet/liveness.py -> scripts/lib/pid-identity.sh probe <pid> <startSeconds>
# Importing the sibling classifier (rather than re-implementing the CLI call) keeps ONE
# rc->status mapping and ONE library-path resolution; a second copy here would recreate
# exactly the two-contracts-for-one-safety-rule defect this replaces.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
try:
    import liveness as _liveness
except Exception:
    # No sibling classifier: abstain rather than guess. NEVER fall back to a bare
    # existence check — that is the defect, not the fallback.
    _liveness = None

# The probe vocabulary (the library's CLI contract). Only `absent` and `zombie` are death
# witnesses; `off-fence` (a live but UNMATCHED incarnation — pid reuse) and `unreadable`
# (a failed read) are ABSTENTIONS.
DEAD_OBSERVED = ("absent", "zombie")
HOLDER_OBSERVED = "holder"


def _observed(pid, start_seconds):
    """The canonical identity read for a lane's recorded incarnation (#1178).

    Returns one of holder | absent | zombie | off-fence | unreadable. EVERY failure — a
    missing sibling classifier, a missing or unrunnable identity library, a failed `ps`,
    an unusable recorded start — returns `unreadable`, which the caller renders as an
    abstention. It must never be collapsed into `absent`: that would manufacture
    "PID DEAD" out of a read that did not happen (#1178 C3).
    """
    if _liveness is None:
        return "unreadable"
    try:
        res = _liveness.probe_pid(pid, start_seconds)
        return _liveness.observed_from_probe(res.rc, res.status)
    except Exception:
        return "unreadable"


STATE = os.path.expanduser("~/.pi/agent/state/fleet-health-prev.json")
HOOK = os.path.expanduser("~/.cmuxterm/pi-hook-sessions.json")
SESS = os.path.expanduser("~/.pi/agent/sessions")
TASK = os.path.expanduser("~/.pi/agent/task-sessions")

LANES = [
    ("B1",  "01a08ca6-3539-71ed-a0d7-7cee52feee03"),
    ("B2c", "01a07161-5816-7a0d-9e2d-a42f769f9da6"),
    ("B3",  "01a093d5-a154-766d-8cdd-1bbdc0a7c033"),
    ("B4",  "01a0a7f1-7783-777e-b3e3-81d47714024b"),
    ("B5",  "01a0a5c9-59ff-7463-8ba8-b297b06fd092"),
    ("B6",  "01a0a05f-21ea-7041-ab73-6af91b651710"),
    ("B7",  "01a093de-2870-7525-988e-c9a8ba78d18d"),
]

# A lane with a stale transcript older than this is worth a screen check.
SUSPECT_AGE = 300      # 5 min
CHILD_SUSPECT_AGE = 600  # 10 min

# ── the lane census gets a SECOND population to disagree with ─────────────
# ⛔ A FROZEN ROSTER IS NOT A CENSUS (measured 2026-11-03). `LANES` above is a fixed list of
# seven session ids. On a box where none of them is present -- a fresh cell, a reboot, a
# renamed lane -- the table still prints seven rows, each one `pid None / life ?`, and because
# every row is UNMEASURED rather than FLAGGED nothing lands in `suspects`; with a readable
# hook store the summary underneath then reads `✅ no suspects`. That is a false PASS from a
# liveness instrument: a clean result over ZERO measured lanes, while pi processes were
# demonstrably running on the box. Reproduced with a readable store containing no rostered
# session: seven unmeasured rows and `✅ no suspects`, no mention of the running processes.
#
# The cure is not a bigger roster (a hardcoded list can always fall behind). It is to count a
# population the roster does not control -- the process table -- and DISAGREE LOUDLY when the
# two cannot be reconciled. `lanes=<N> pi=<M>` both unmeasured is a fact worth an alarm; it is
# never a clean scan.
PI_PS_ARGV = ["ps", "-Ao", "pid=,command="]


def pi_process_count():
    """How many `pi` processes are running on THIS box, or None when unreadable.

    `None` is the abstention and is NOT interchangeable with `0`: a failed `ps` must never
    manufacture the "no processes, so no mismatch" clean result this reconciliation exists to
    prevent (the same unknown-vs-zero rule the identity probe follows).

    ⛔ EXACT BASENAME, NOT A PREFIX (review cycle 1, finding 4). The matcher was
    `base == "pi" or base.startswith("pi-")`, which counts every `pi-*` HELPER --
    `pi-cache-reap`, `pi-reap-orphans.sh`, `pi-task-session-prune.sh` -- as a lane-bearing pi.
    Measured: `exec -a pi-cache-reap sleep` is counted by the prefix form. That over-count feeds
    the census a population the fleet does not have, and on a box whose roster is current it
    fabricates a MISMATCH out of a reaper. The fleet's own binary is exactly `pi` (measured: 18
    processes, argv0 `pi`), so an exact basename is both correct and narrower.

    ⛔ AN EMPTY TABLE IS AN UNREADABLE READ, NOT A MEASURED ZERO (review cycle 3, finding 3).
    A `ps` that exits 0 and prints no rows fell through the loop as `0`, which the census maps to
    its silent arm — the pre-fix false PASS reached through the gate's own input, on any host where
    `ps` degrades. That is also the contract this repo ALREADY pins one level down:
    `scripts/lib/pid-identity.sh` `pid_table_nonempty` -- "a read that 'succeeds' but prints no
    table is not 'no such process' ... an empty table is an UNREADABLE read, never absence"
    (#1178 C3). The probing process itself must appear in any real table, so zero parsed rows is
    reported as None here rather than as a second, contradicting ps contract.

    ⛔ "PARSED" MEANS A ROW WITH A NUMERIC PID, NOT MERELY TWO FIELDS (review cycle 10, finding 2).
    The guard counted any line with two whitespace-separated fields, so a `ps` that printed a
    HEADER (`PID COMMAND` -- which is what a `ps` that does not honour the trailing `=` on
    `pid=,command=` emits) counted as a row while contributing no pid: `rows=1, n=0`, which returns
    a MEASURED ZERO and takes the census's silent arm. Measured: a header-only table yielded
    `pi_process_count()==0` and `lane_census(0,0,0,7)==None`, i.e. `✅ no suspects` and exit 0 --
    the exact fail-open this guard was added to close, reached through a read the format did not
    match. Requiring `parts[0].isdigit()` makes the guard test what the comment claims it tests.
    """
    try:
        cp = subprocess.run(PI_PS_ARGV, capture_output=True, text=True, timeout=20)
    except Exception:
        return None
    if cp.returncode != 0:
        return None
    n = 0
    rows = 0
    for line in cp.stdout.splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) < 2 or not parts[0].isdigit() or not parts[1].strip():
            continue
        rows += 1
        argv0 = parts[1].split()[0]
        if os.path.basename(argv0) == "pi":
            n += 1
    if rows == 0:
        return None      # empty table = unreadable, never "zero pi processes"
    return n


def lane_census(alive, dead, pi_count, roster_size):
    """The census note, or None when the census is RECONCILED.

    ⛔ THE OLD SUMMARY LINE WAS FALSE IN BOTH DIRECTIONS (review cycle 13, finding 1). It read
    "or None when every rostered lane carries a CONCLUSIVE verdict", and the code contradicts it
    both ways: `lane_census(0, 0, 0, 7)` is silent with NO lane conclusive (a MEASURED-EMPTY
    population cannot mislead about anything), and `lane_census(5, 2, None, 7)` returns a note with
    EVERY lane conclusive (a complete roster over an UNREADABLE table is UNVERIFIED, never clean).
    Silence is about whether the roster and the population AGREE, not about how many lanes resolved
    — see SILENT ARMS, EXHAUSTIVELY below, which is the authority this line summarises.

    ⛔ SILENCE REQUIRES A CONCLUSION PER LANE, NOT A RECORD PER LANE (review cycle 2, finding 1).
    The previous form keyed silence on "the store has a record for some rostered lane", which
    let a SINGLE pid-less or abstaining record silence a census in which nothing was established
    while 18 pi processes ran — `✅ no suspects`, exit 0, the original defect one input over.

    * `alive` -- lanes the ONE verdict function positively bound to a live incarnation (`holder`).
    * `dead` -- lanes POSITIVELY dead (`absent` / `zombie`). An ABSTENTION (unreadable / off-fence)
      is neither, which is the whole point: an identity read that did not happen must never be
      counted as an established one.
    * `pi_count` -- the independent population, or None when unreadable.

    ⛔ "A CONCLUSIVE VERDICT" IS NOT "THE ROSTER ACCOUNTS FOR THE BOX" (review cycle 7, finding 1).
    Silence was keyed on `alive + dead >= roster_size` alone, so seven `PID DEAD` lanes silenced the
    census while the box's pi processes were demonstrably running — the roster names NONE of that
    population, which is the original defect, reached through the all-dead arm. A `dead` verdict is
    conclusive about the RECORDED PID only; it says nothing about the processes the roster has never
    heard of. Reproduced end-to-end (readable store, a record for every rostered session carrying an
    ended pid): seven `PID DEAD` rows, NO census line, `✅ no suspects`, exit 0 from the lane section
    — while `ps` showed ~18 live `pi` processes. So the population decides, not the dead count.

    ⛔ SILENT ARMS, EXHAUSTIVELY: `alive >= roster_size` (every lane is a live bound incarnation,
    whatever the process table says); or every lane conclusive with at least one attributed alive
    AND a MEASURED population (the roster accounts for at least one running process, so it is not
    contradicted); or every lane conclusive over a MEASURED-EMPTY population (the population can
    CONTRADICT nothing, and no lane is live — see the argv0 note in that arm); or a MEASURED-EMPTY
    population on an inconclusive roster (a MISMATCH needs at least one pi process the roster does
    not account for, so an empty population has nothing to object to). ⛔ THAT SILENT ARM IS
    `pi_count == 0`, NOT `pi_count <= 0` (review cycle 18, finding 4): `None` is not a small number,
    it is a population that WAS NOT READ, and it returns UNRECONCILED immediately above — the same
    `None`/`0` collapse this file exists to keep apart, which the old wording reproduced in prose
    while the code got it right. Nothing else is silent — in particular a
    conclusive-with-a-live-lane roster over an UNREADABLE table is UNVERIFIED, not silent (see the
    arm below).

    ⛔ AN ABSTENTION IS NAMED, NOT SWALLOWED. When a lane's verdict is missing AND the process
    table cannot be read, returning None would render that state identically to `pi_count == 0`
    -- "reconciled, nothing running" -- and the summary would print `✅ no suspects` with exit 0.
    That is the pre-fix false PASS arriving through the new gate's own input, so it gets its own
    UNRECONCILED note instead.

    ⛔ AN UNREADABLE TABLE IS NOT A MEASURED ZERO, NOT EVEN ON AN ALL-DEAD ROSTER (review cycle 8,
    finding 1). The all-dead arm collapsed `pi_count is None` into `<= 0`, so on a host whose `ps`
    degrades (an EMPTY `-Ao` table is `None` — see `pi_process_count`) a fully DEAD roster printed
    `✅ no suspects` with no census line, while the same box with a working `ps` printed STALE
    ROSTER. The read FAILING flipped the verdict from ALARM to CLEAN — the fail-open direction, and
    a direct violation of R2 ("`pi_count is None` ⇒ abstain: no mismatch, no clean claim, never
    `0`") FOR ANY ROSTER THAT IS NOT FULLY LIVE. An all-dead roster over an unreadable table
    genuinely cannot be distinguished from an idle fleet, so it now says exactly that instead of
    claiming the clean one.

    ⛔ R2 IS SCOPED, AND THE SCOPING IS THE POINT (review cycle 12, finding 1). Above, R2 is
    ONTOLOGICALLY about a population that WAS NOT READ. `alive >= roster_size` is the one state whose
    silence rests on a POSITIVE PER-LANE measurement instead: every rostered lane was bound to a live
    incarnation, so the box is accounted for without the table. Quoting R2 unscoped here would tell
    a reader to add `if pi_count is None: return UNVERIFIED` ABOVE the first arm — which would make
    every healthy box with a degraded `ps` alarm forever, the un-clearable false alarm review cycle
    10 exists to prevent. `alive >= roster_size` is therefore the ONE exemption from R2, and it is
    the only arm whose silence does not depend on the population at all.

    ⛔ …AND THE DIAGNOSIS MUST NOT CONTRADICT THE ROWS IT SITS BENEATH (review cycle 9, finding 1).
    That arm was gated on `established >= roster_size`, so it also fired when SOME lanes were ALIVE
    and printed "all 7 rostered lanes are DEAD/absent … an idle fleet and a stale roster are
    indistinguishable" directly under a `life running` row — naming the two causes the state
    excludes. The alarm was right; the sentence was false. There are two shapes of UNVERIFIED and
    each names its own.
    """
    established = alive + dead
    if alive >= roster_size:
        # Every rostered lane is positively bound to a live incarnation: the roster IS the box, and
        # any remaining pi processes are task children the roster does not claim to cover.
        return None
    if established >= roster_size:
        # Every rostered lane has a conclusive verdict, so nothing here is UNMEASURED. What is left
        # to decide is whether that roster still describes the box — the population does that:
        #   * UNREADABLE table (`None`)  -> undecidable: an idle fleet and a stale roster look the
        #                                  same, so it is named, NOT rendered as the clean one;
        #   * MEASURED empty table       -> the population has NOTHING TO CONTRADICT: with no lane
        #                                  live (tested FIRST, below) the resolved roster is the
        #                                  whole picture and there is nothing to reconcile against;
        #   * some lane alive            -> the roster accounts for at least one running process;
        #   * every lane DEAD while pi runs -> a STALE ROSTER (this is the branch cycle 6 lacked).
        if pi_count is None:
            if not alive:
                return ("LANE CENSUS UNVERIFIED: all %d rostered lanes are DEAD/absent and the "
                        "process table could not be read — an idle fleet and a stale roster are "
                        "indistinguishable here, so this is NOT a clean result" % roster_size)
            return ("LANE CENSUS UNVERIFIED: %d of the %d rostered lanes is alive and %d are "
                    "DEAD/absent, but the process table could not be read — the population "
                    "cannot be reconciled against the roster, so this is NOT a clean result"
                    % (alive, roster_size, dead))
        # ⛔ THE EXEMPTION IS TESTED BEFORE THE EMPTY-POPULATION ARM, AND IT IS BEHAVIOUR-NEUTRAL
        # (review cycle 17, finding 1 — the earlier wording here claimed this reorder was "the fix"
        # and that a pin "stops the exemption being split from its arm". Both claims were FALSE: BOTH
        # arms `return None`, so the ORDER IS UNOBSERVABLE through the verdict, and a verdict-level
        # pin cannot see it. Measured against the pre-fix MODULE on a box whose identity probe
        # resolves (the shipped base — a DIFFERENT thing from this ordering): `71 passed, 42 failed`
        # = 36 `CENSUS` + 5 `EXITLINE` + 1 ambient `HARNESS`, i.e. 41 census checks red (the 42nd
        # `❌` is the ambient HARNESS failure, red on the UNMUTATED module too — quoting 42 as a
        # CENSUS count is the same two-populations conflation this file exists to keep apart). So
        # the pins are sensitive to the FIX and blind to the ORDER. ⛔ THESE INTEGERS TRACK THE
        # SUITE'S SIZE (this round's five new checks moved them from 37/36 to 42/41), so they are a
        # measurement to RE-RUN, never a constant to quote. This is stated for what it is —
        # the comment now matches the code it sits on, and the exemption sits adjacent to the arm it
        # governs so the two cannot drift apart unnoticed. The value is the HONEST REASON and the
        # PINS below, not an ordering guarantee.
        #
        # The reason the two reads may disagree is NOT a wrapper/interpreter argv0 — the fleet's own
        # `pi` presents argv0 exactly `pi` (measured: 20 `ps` rows, all basename `pi`; the
        # process-title rewrite means no interpreter prefix appears). It is that the two reads are
        # DIFFERENT PREDICATES over DIFFERENT things: `alive` is an identity check on the RECORDED
        # incarnation — the hook store's `pid` + `pidStartSeconds`, fenced by `liveness.probe_pid` —
        # and NOTHING requires that process to be the `pi` binary; `pi_count` counts only `ps` rows
        # whose argv0 basename is exactly `pi`. A lane whose recorded pid is a wrapper, a tmux
        # client, or any other non-`pi` incarnation is therefore legitimately `alive` while adding
        # nothing to `pi_count`. `alive > 0` beside a MEASURED-EMPTY population is that state, not a
        # contradiction — and the previous ordering answered it with a comment ("nothing is
        # running") that is provably FALSE whenever a lane is live: a lane positively bound to a
        # live incarnation IS a running process. Measured before this: `lane_census(2, 5, 0, 7)` and
        # `lane_census(2, 1, 0, 7)` both returned None through that arm.
        if alive:
            return None
        if pi_count <= 0:
            return None
        return ("LANE CENSUS STALE ROSTER: all %d rostered lanes are DEAD/absent but %d pi "
                "process(es) are running — the roster names NONE of them, so it no longer "
                "describes this box (not an idle fleet, and NOT a clean result)"
                % (roster_size, pi_count))
    if pi_count is None:
        return ("LANE CENSUS UNRECONCILED: only %d of the %d rostered lanes has a conclusive "
                "verdict (%d alive, %d dead) and the process table could not be read — the scan "
                "is UNMEASURED, not clean" % (established, roster_size, alive, dead))
    if pi_count <= 0:
        # The population is MEASURED EMPTY, so it can CONTRADICT nothing — a MISMATCH needs at least
        # one pi process the roster does not account for. ⛔ NOT "nothing is running at all" (review
        # cycle 16, finding 1): `alive` may be non-zero here (e.g. `lane_census(2, 1, 0, 7)`), for the
        # argv0 reason documented in the complete-roster arm above. An inconclusive roster cannot
        # mislead about a box whose population contradicts nothing.
        return None
    return ("LANE CENSUS MISMATCH: %d pi process(es) running but only %d of the %d rostered lanes "
            "has a conclusive verdict (%d alive, %d dead) — the roster is stale on this box or "
            "its lanes are unattributable, so every row without a verdict is UNMEASURED "
            "(not dead, and NOT a clean result)"
            % (pi_count, established, roster_size, alive, dead))



def census_exit_verdict(note, attributed, established, roster_size):
    """The exit line's `(word, tail)` for a census note.

    ⛔ THE LABEL MUST BE DERIVED FROM THE NOTE, NOT FROM A COUNT THAT HAPPENS TO CORRELATE WITH IT
    (review cycles 7, 8 and 9 — three consecutive rounds found a word or a tail that described a
    state the note did not). `attributed + dead >= roster_size` was such a correlation: STALE ROSTER
    was the only note reachable with a complete roster *until* UNVERIFIED became a second one. A
    pure function is used so the pairing is PINNED directly, instead of only being reachable through
    a live-pid fixture.

    ⛔ AND THAT RULE APPLIES TO THE TAIL TOO (review cycle 13, finding 2). The two UNVERIFIED arms
    were split by the `attributed` COUNT, so `census_exit_verdict()` could emit a tail its own note
    excluded: handed the all-dead note
    ("all 7 rostered lanes are DEAD/absent … an idle fleet and a stale roster are indistinguishable")
    with a non-zero `attributed`, it printed "the population cannot be reconciled", which that note
    explicitly is not. `main()` passes consistent arguments today, so this was latent, not yet a
    wrong line — but it is the exact defect this function exists to prevent, so the discriminator is
    now the NOTE's own words. `attributed`/`established`/`roster_size` are kept for the callers that
    pass them and are deliberately NOT consulted here.
    """
    if note.startswith("LANE CENSUS STALE ROSTER"):
        return ("STALE ROSTER", "no rostered lane is a running pi process")
    if note.startswith("LANE CENSUS UNVERIFIED"):
        # The note says which of the two shapes it is; the count cannot. "is alive and" appears only
        # in the PARTLY-live note ("N of the M rostered lanes is alive and K are DEAD/absent").
        if "is alive and" in note:
            # Some lanes ARE live: do not claim the box is dark, and do not claim it is idle.
            return ("UNVERIFIED", "the process table could not be read, so the population cannot "
                                  "be reconciled against the roster")
        return ("UNVERIFIED", "the process table could not be read, so an idle fleet and a stale "
                              "roster are indistinguishable here")
    # MISMATCH (partial census) and UNRECONCILED (inconclusive roster, unreadable table) both leave
    # rows without a verdict, which is exactly what INCOMPLETE says.
    return ("INCOMPLETE", "rows without a verdict are not a verdict")


def walk_records(obj, out):
    """Collect every dict that looks like a session record, whatever the hook file's shape."""
    if isinstance(obj, dict):
        if any(k in obj for k in ("sessionId", "pid", "agentLifecycle", "cwd")):
            out.append(obj)
        for v in obj.values():
            walk_records(v, out)
    elif isinstance(obj, list):
        for v in obj:
            walk_records(v, out)


def load_hook():
    """Read the cmux hook store. Returns (ok, sid-keyed records).

    `ok` is False when the store could not be read, or when records WERE found but none
    carried a session id — a store-shape drift. Either way the lane lookup is unusable,
    so the caller reports the scan INCOMPLETE instead of a clean result: a read that did
    not happen must abstain here exactly as the identity probe does (the same fail-closed
    direction as `PID ? (...)`), or a dead lane is reported healthy by silence.
    """
    recs = []
    ok = True
    try:
        walk_records(json.load(open(HOOK)), recs)
    except Exception as e:
        print(f"  (hook file unreadable: {e})")
        ok = False
    by_sid = {}
    for r in recs:
        sid = r.get("sessionId") or r.get("session_id")
        if sid:
            by_sid.setdefault(sid, {}).update(r)
    if recs and not by_sid:
        print("  (hook store shape drifted: records carry no session id)")
        ok = False
    return ok, by_sid


def cputime_secs(pid):
    try:
        out = subprocess.run(["ps", "-o", "cputime=", "-p", str(pid)],
                             capture_output=True, text=True, timeout=5).stdout.strip()
    except Exception:
        return None
    if not out:
        return None
    parts = out.split(":")
    try:
        parts = [float(p) for p in parts]
    except ValueError:
        return None
    secs = 0.0
    for p in parts:
        secs = secs * 60 + p
    return secs


def find_transcript(sid):
    hits = glob.glob(os.path.join(SESS, "**", f"*{sid}*.jsonl"), recursive=True)
    if not hits:
        return None
    return max(hits, key=os.path.getmtime)


# ── scheduled reapers: a maintainer that fails SILENTLY ───────────────────
# A reaper's whole point is to run unattended, so its exit status is the ONLY thing that can
# tell anyone it stopped working. `launchctl list` reports that status and NOTHING read it:
# the measured estate carried `com.eldato.pi-cache-reap` at exit 5 for days while the caches it
# exists to bound sat at 8745MB/9479MB, `com.tortoise.worktree-reaper` loaded-and-inert, and
# the three cloud cells hit a disk-full at 94-96%. A silent failure IS the bug (the same
# rule as the pr-doctor exit-2 defect), so the scan reports every reaper's last exit.
#
# ⛔ THE EXIT VOCABULARY IS NOT PORTABLE AND MUST NOT BE FLATTENED. Per the scripts' own exit
# contracts: pi-cache-reap.sh 5 = "a cache is OVER its bound and nothing was done (dry-run —
# the shipped stance)" — an ACTIONABLE ALARM, never a crash; 3 = fail-closed (real breakage);
# 4 = did not run (lock held / benign skip); 7 = DEFERRED (a live tool holds the cache — routine on a
# busy box, not a failure). pi-reap-worktrees.sh uses 4 for "a removal FAILED" and 3 for
# "fail-closed" — which there covers a missing library, an unlistable git, an unreachable gh, an
# unwritable log AND (one path of seven) a held lock, so its 3 is NOT a benign skip. So each family
# gets its own table, and an UNRECOGNISED code is reported as an alarm rather than assumed benign
# (allow-list polarity).
#
# ⛔ THIS SECTION IS macOS-ONLY, AND SAYING SO IS PART OF THE INSTRUMENT. `launchctl` does not exist on
# the Linux cells — the boxes this fleet's reaper is actually scheduled on — so the old unconditional
# call raised FileNotFoundError there, which the `except` turned into "an alarm", which made
# fleet-health exit 1 on every healthy Linux cell, on every run, before it looked at a single reaper.
# A cross-platform scanner must report an inapplicable probe as inapplicable, never as a failure.
REAPERS = [
    ("com.eldato.pi-cache-reap",       "cache"),
    ("com.eldato.pi-session-reaper",   "failclosed-only"),
    ("com.eldato.pi-task-session-prune", "failclosed-only"),
    # #1862 — the ORPHAN REAPER. It was restored to the fleet (script + plist + farm entry) while
    # this tuple still held five labels, so the one instrument built for "a reaper that fails
    # silently" would have printed `reapers (launchd, last exit)` with five rows and exited 0 over a
    # job that could be NOT INSTALLED, loaded-and-inert, or exiting 3 (fail-closed: NOTHING
    # SIGNALLED) on every hourly pass. A liveness instrument that reports a clean bill over an
    # unread reaper is the false PASS this section exists to prevent — and unlike the
    # `com.tortoise.*` rows below, its plist carries no `{{TORTOISE_REPO}}` placeholder, so
    # `install-launchd.sh` installs it unconditionally.
    ("com.eldato.pi-reap-orphans",     "orphan"),
    ("com.tortoise.worktree-reaper",   "worktree"),
    ("com.tortoise.branch-reaper",     "other"),
]
# ⛔ 'NOT INSTALLED' IS ONLY AN ALARM WHEN THE INSTALLER WOULD HAVE INSTALLED IT. The two
# `com.tortoise.*` plists carry `{{TORTOISE_REPO}}`, and install-launchd.sh deliberately SKIPS a job
# whose placeholder does not resolve (no tortoise checkout on this box) — so their absence is a
# legitimate provisioning outcome, not a missing clock. Alarm only for the labels this repo installs
# unconditionally; the others print as an abstention with the reason. (This is the same manufactured
# fatigue as the `com.tortoise.embedded-reaper` row that was dropped for having no plist at all — the
# difference is that these plists exist and are conditionally skipped, so they must be REPORTED, just
# not alarmed on.)
REQUIRED_LABELS = {"com.eldato.pi-cache-reap", "com.eldato.pi-session-reaper",
                   "com.eldato.pi-task-session-prune", "com.eldato.pi-reap-orphans"}
# Labels this repo does NOT install are deliberately absent. `com.tortoise.embedded-reaper` used to be
# listed here; templates/launchd/ has no plist for it (install-launchd.sh installs $TEMPLATES_DIR/*.plist),
# so on every box provisioned from this repo the row was a guaranteed `NOT INSTALLED` alarm and a
# non-zero exit for ever — alarm fatigue manufactured by the very instrument meant to cure it. A label
# that only one hand-built box ever carried is not this repo's alarm to raise.
#
# ⛔ ONE TABLE PER OWNER, NOT PER SINK. `cache` is pi-cache-reap.sh's vocabulary. The two session
# reapers run DIFFERENT scripts (pi-reap-idle.sh, pi-task-session-prune.sh) whose whole contract is
# `0 ok / 2 usage / 3 fail-closed` — filing them under `cache` would read their future `4` as "another
# pass holds the lock, benign" and hide a real failure. That is the same conflation this PR removed
# from disk-reaper.sh, so it is not repeated here.
# family -> {code: (meaning, alarm?)}
REAPER_CODES = {
    "cache":    {0: ("ok", False),
                 2: ("usage error", True),
                 3: ("fail-closed (a cache could not be measured or verified, or the audit log is unwritable)", True),
                 4: ("did not run (another pass holds the lock)", False),
                 5: ("OVER BOUND and nothing reclaimed — dry-run; arming is the owner's decision (#1678)", True),
                 7: ("DEFERRED — a live tool holds the cache; nothing acted on, nothing claimed", False)},
    "failclosed-only": {0: ("ok", False),
                        2: ("usage error", True),
                        3: ("fail-closed (a probe, lock or log the pass needed was unavailable)", True)},
    # ⛔ `4` HERE IS NOT `worktree`'s `4`. pi-reap-orphans.sh's contract is
    # 0 ok / 2 usage / 3 fail-closed (ps, lsof, identity or the launchctl registration probe was
    # unusable, the lock was held, or the log was unwritable — NOTHING was signalled) / 4 "a kill
    # FAILED", which the script reaches by TWO paths: `TERM-FAILED` (the SIGTERM was not delivered,
    # and it deliberately does NOT escalate) and `KILL-FAILED` (the process survived SIGKILL, or its
    # death could not be proven). Naming only one of them would be a half-truth about the code.
    # Filing this label under `worktree` would read its 4 as "a removal FAILED" (a different fact)
    # and its 3 as "library/git/gh/log **or a held lock**" — the conflation the table comment above
    # forbids. It has no deferral code: a truncated pass prints `deferred=N` and still exits 0, so a
    # routine budget deferral is NOT an alarm; 3 is the only "nothing acted on" code and it is real
    # breakage.
    "orphan":   {0: ("ok", False),
                 2: ("usage error", True),
                 3: ("fail-closed (ps/lsof/identity/launchctl probe, the lock or the log was unavailable — nothing was signalled)", True),
                 4: ("a kill FAILED (the TERM was not delivered, or the process survived SIGKILL / its death could not be proven)", True)},
    "worktree": {0: ("ok", False),
                 2: ("usage error", True),
                 3: ("fail-closed (library/git/gh/log, or a held lock — this code does not distinguish them)", True),
                 4: ("a removal FAILED", True)},
    # cleanup-stale-branches.sh's contract is 0 ok / 1 a pass FAILED, and a usage error is ALSO 1 (the
    # script has no `exit 2` path — so no `2` row exists here: an arm that can never be indexed is the
    # "dead arm nobody re-reads" class). 1 is a NAMED failure, so it is not reported as UNRECOGNISED.
    "other":    {0: ("ok", False), 1: ("a pass FAILED (or a usage error — this script has no exit 2)", True)},
}


# ── the consolidated reaper's PASS RECORD (disk-reaper.sh) ────────────────────────────────
# It writes ONE record per pass, on BOTH platforms, and it is the ONLY place that says whether the box
# was actually reaped when the job exits 5 or 6 (both are success to the scheduler); an unreadable or
# absent record is reported as such, and never read as "the pass was fine".
#
# ⛔ THE SEAM, NOT A HARDCODED PATH. Both artifacts render DISK_REAPER_STATE_DIR into the job's
# environment and both other readers honour it (`disk-reaper.sh --print-status`,
# `cloud-cell-supervisor.sh`); reading ~/.pi/agent/state regardless made fleet-health alarm on a box
# whose state dir is elsewhere while the other two said ok — one record, two verdicts.
def _disk_reaper_status_path():
    base = os.environ.get("DISK_REAPER_STATE_DIR") or os.path.join(
        os.path.expanduser("~"), ".pi", "agent", "state")
    return os.path.join(base, "disk-reaper.status")


def _reaper_is_scheduled():
    """Is a disk-reaper job installed on this box (either platform), or a state dir pinned by env?

    `DISK_REAPER_SCHEDULE_ASSERT` is a TEST SEAM (nothing in production sets it): `0`/`1` pins the
    answer so a suite can prove BOTH branches hermetically. Without it the probe reads the machine it
    runs on, so a test's expectation would depend on whether the CI runner happens to carry a reaper
    unit — the assertion would pass on a dev box and fail on `ubuntu-latest`.
    """
    override = os.environ.get("DISK_REAPER_SCHEDULE_ASSERT")
    if override in ("0", "1"):
        return override == "1"
    if os.environ.get("DISK_REAPER_STATE_DIR"):
        return True
    home = os.path.expanduser("~")
    for p in ("/etc/systemd/system/eldato-disk-reaper.timer",
              os.path.join(home, ".config", "systemd", "user", "eldato-disk-reaper.timer"),
              os.path.join(home, "Library", "LaunchAgents", "com.eldato.disk-reaper.plist")):
        if os.path.exists(p):
            return True
    return False


def disk_reaper_record():
    """Return (detail, alarm) from the pass record. Absence/unreadability/staleness is an alarm."""
    try:
        with open(_disk_reaper_status_path(), encoding="utf-8", errors="replace") as fh:
            kv = dict(ln.split("=", 1) for ln in (x.strip() for x in fh) if "=" in ln)
    except OSError as exc:                                      # noqa: BLE001
        # ⛔ AN ABSENT RECORD IS ONLY AN ALARM WHERE A REAPER IS SUPPOSED TO BE. If the STATE DIR itself
        # does not exist, no pass has ever been configured on this box and alarming would be an alarm that
        # can never be cleared (fleet-health runs on every lane box, including ones with no reaper). A
        # state dir that EXISTS with no record, or a record that exists and cannot be read, is the real
        # signal and still alarms.
        import errno as _errno
        if exc.errno == _errno.ENOENT and not _reaper_is_scheduled():
            return ("no pass record yet, and no disk-reaper schedule on this box", False)
        return (f"pass record UNREADABLE at {_disk_reaper_status_path()} ({exc}) — this is NOT 'the pass was fine'",
                True)
    ok = kv.get("ok", "")
    # ⛔ ok=1 IS NOT ENOUGH ON ITS OWN. A job that is loaded but has stopped writing its record keeps
    # whatever `ok` the last pass wrote, so a dead maintainer would read healthy for ever. The pass's
    # own reader applies the staleness bound (`disk-reaper.sh --print-status` ⇒ status=stale, exit 3)
    # and so does cloud-cell-supervisor.sh; fleet-health must not be the one reader that does not.
    # ⛔ AN UNREADABLE SEAM MUST NOT KILL THE SCAN. `int("30m")` raised ValueError and the whole
    # fleet-health run died with a traceback instead of reporting — the opposite of an alarm.
    try:
        stale = int(os.environ.get("DISK_REAPER_STALE_SECONDS", "7200") or 7200)
    except ValueError:
        return (f"DISK_REAPER_STALE_SECONDS={os.environ.get('DISK_REAPER_STALE_SECONDS')!r} is not a whole number — cannot judge staleness", True)
    age = ""
    try:
        epoch = int(kv.get("epoch", ""))
        age = int(time.time()) - epoch
    except (TypeError, ValueError):
        epoch = None
    if epoch is None:
        return (f"record has no readable epoch (rc={kv.get('rc', '?')}) — cannot tell whether this box is still being reaped",
                True)
    # ⛔ THE SAME PREDICATE AS `disk-reaper.sh --print-status`, in ONE form: a FUTURE-dated epoch (age < 0)
    # is as unprovable as an ancient one, and the two readers must not disagree about it (measured:
    # --print-status said stale/rc 3 for `epoch=now+3600` while this said healthy, no alarm).
    if age < 0 or age > stale:
        return (f"record is STALE: last pass {age}s ago (bound {stale}s) — the job is scheduled but is not running",
                True)
    if ok == "1":
        unm = kv.get("freed_mb_unmeasured", "")
        return (f"record ok=1 rc={kv.get('rc', '?')} freed_mb={kv.get('freed_mb', '?')}"
                f"{f' (df could not measure: {unm})' if unm else ''} age={age}s", False)
    # ⛔ A ROUTINE OUTCOME IS NOT A FLEET ALARM. rc 6 (a delegate DEFERRED the pass because the box is
    # busy — the lock was held, or a live tool holds the cache) and rc 5 (a DRY RUN that found work it
    # would do) are the states the runbook tells operators to EXPECT on a healthy busy cell; alarming on
    # them here made every busy cell red at the fleet level and forced nine call sites to swallow the
    # exit status. They are reported IN FULL, without an alarm; rc 3 (a class FAILED CLOSED / a
    # misconfiguration), rc 4 (a removal FAILED, or a lock dir that could not be created) and an
    # unreadable record still alarm — those are the ones a human must act on.
    rc_field = kv.get("rc", "?")
    if rc_field in ("5", "6"):
        return (f"record ok=0 rc={rc_field} (expected on a busy cell) detail={kv.get('detail', '?')} age={age}s",
                False)
    return (f"record ok={ok or 'MISSING'} rc={rc_field} detail={kv.get('detail', '?')} age={age}s", True)


def _tortoise_repo_resolved():
    """EXACTLY install-launchd.sh's resolve_env(): TORTOISE_REPO if it is a dir, else, in order,

        $HOME/Documents/GitHub/tortoise  ·  $INFRA_ROOT/../tortoise  ·  $HOME/tortoise

    each accepted only when it is a dir AND has a .git (the installer's own test). Mirroring matters in
    both directions: a resolver that MISSES a candidate says "no checkout on this box" on a box that has
    one — so a missing reaper reads as a legitimate skip, which is the delivery defect this row exists
    to catch — and one that accepts a stray non-checkout directory flips to a false alarm. Measured
    divergence in the first version: `$HOME/tortoise` was not checked at all, and the sibling was rooted
    at `<repo>/../../tortoise` instead of `<repo>/../tortoise`.
    """
    env = os.environ.get("TORTOISE_REPO", "").strip()
    if env and os.path.isdir(env):
        return True
    home = os.environ.get("HOME", "")
    infra = os.environ.get("AGENT_INFRA_PATH", "") or os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "..", "..")
    cands = []
    if home:
        cands.append(os.path.join(home, "Documents", "GitHub", "tortoise"))
    cands.append(os.path.abspath(os.path.join(infra, "..", "tortoise")))
    if home:
        cands.append(os.path.join(home, "tortoise"))
    return any(os.path.isdir(c) and os.path.isdir(os.path.join(c, ".git")) for c in cands)


def reaper_section():
    """Report the consolidated reaper's PASS RECORD on every host, plus launchd exit statuses on a Mac.

    ⛔ TWO CHANNELS, TWO RULES. The pass record is written on both platforms and is always read; the
    `launchctl` exit table exists only on macOS and reports "not applicable" elsewhere — a section that
    exits 1 on every Linux cell for a table it cannot read is an alarm that can never be cleared
    (measured: fleet-health exited 1 with healthy lanes, printing "CANNOT READ launchctl").
    """
    # ⛔ THE PASS RECORD IS READ ON EVERY HOST, NOT ONLY ON macOS. The consolidated reaper writes it on
    # Linux too, and returning early when the host is not a Mac meant the record was never read on the
    # cells this feature exists for — a failed or deferred pass read as nothing at all.
    alarms = []
    print("\ndisk reaper (pass record)")
    rec_detail, rec_alarm = disk_reaper_record()
    print(f"  {rec_detail}")
    if rec_alarm:
        alarms.append(f"disk reaper: {rec_detail}")

    # ⛔ PROBE FOR THE TOOL, NOT FOR THE PLATFORM. `sys.platform != "darwin"` is the obvious test and it
    # is the wrong one: a `launchctl` that EXISTS but cannot answer (a shim on a CI box, a broken domain
    # on a headless Mac) is the case this section must report as an ABSTENTION, and a platform gate
    # skips it entirely — the section then prints nothing and raises nothing. `shutil.which` asks the
    # question actually being answered: can this host's launchd table be read at all?
    if not shutil.which("launchctl"):
        # Only the launchd EXIT TABLE is inapplicable here; the record above is the real channel.
        print("reapers (launchd, last exit): not applicable on this host (no launchd — Linux cells are scheduled by systemd)")
        return alarms
    try:
        cp = subprocess.run(["launchctl", "list"], capture_output=True, text=True,
                            timeout=20)
    except Exception as exc:                                    # noqa: BLE001
        print(f"\nreapers: CANNOT READ launchctl ({exc}) — this is NOT 'no reapers'")
        return alarms + ["reapers: launchctl unreadable (abstention, not absence)"]
    # ⛔ A `launchctl` THAT EXISTS BUT CANNOT ANSWER IS AN ABSTENTION, NOT "NO REAPERS". Without this
    # check a non-zero exit (e.g. `Could not find domain` on a headless box) left `rows` empty, printed
    # every label as NOT INSTALLED and returned NO alarm — the section abstaining silently on a box it
    # could not see, which is the one thing an alarm channel must never do.
    if cp.returncode != 0 or not cp.stdout.startswith("PID"):
        print(f"\nreapers: CANNOT READ launchctl (rc={cp.returncode}) — this is NOT 'no reapers'")
        return alarms + [f"reapers: launchctl unreadable (rc={cp.returncode}, abstention not absence)"]
    out = cp.stdout
    rows = {}
    for line in out.splitlines()[1:]:
        f = line.split("\t")
        if len(f) >= 3:
            rows[f[2].strip()] = f[1].strip()          # label -> last exit status
    print("\nreapers (launchd, last exit)")
    for label, family in REAPERS:
        if label not in rows:
            if label in REQUIRED_LABELS:
                print(f"  {label:<36} NOT INSTALLED")
                alarms.append(f"{label}: NOT INSTALLED (a box with no clock has no reaper)")
            else:
                # ⛔ DO NOT ASSERT A CAUSE THIS SCANNER NEVER CHECKED. The abstention used to claim the
                # install was "skipped because {{TORTOISE_REPO}} does not resolve" — a claim nothing here
                # verified. `install-launchd.sh` resolves it from TORTOISE_REPO (if a dir), then
                # ~/Documents/GitHub/tortoise, then <infra>/../tortoise, then ~/tortoise — the SAME FOUR
                # NAMES, each of the last three accepted only when it has a .git; on a Mac that HAS a
                # checkout the jobs are installed, so a missing label there is the delivery defect this
                # row exists to catch — not a legitimate skip. So resolve the same four candidates.
                if _tortoise_repo_resolved():
                    print(f"  {label:<36} NOT INSTALLED (a tortoise checkout IS resolvable, so install-launchd.sh would have installed it)")
                    alarms.append(f"{label}: NOT INSTALLED although a tortoise checkout resolves")
                else:
                    print(f"  {label:<36} not applicable (no tortoise checkout: install-launchd.sh's own candidates — TORTOISE_REPO, ~/Documents/GitHub/tortoise, <infra>/../tortoise, ~/tortoise — do not resolve)")
            continue
        raw = rows[label]
        # ⛔ `-` IS NOT AN ERROR — IT IS "NO EXIT SINCE LOAD" (a job loaded this login that has not
        # exited yet, or is running now). It is a NORMAL `launchctl list` Status value, and this repo
        # already says so (scripts/lib/fleet-inventory.sh maps `-` to the empty string, "unknown").
        # Treating it as unreadable would fire a reaper alarm and a non-zero exit on a healthy Mac for
        # every freshly-loaded job — the same manufactured fatigue this section just removed one label
        # over. Abstention, not alarm: there is no verdict to read yet.
        if raw == "-":
            print(f"  {label:<36} exit=-  (no exit since load — no verdict yet)")
            continue
        code = int(raw) if raw.lstrip("-").isdigit() else None
        if code is None:
            print(f"  {label:<36} exit={raw}  (not a status — run it in the foreground)")
            alarms.append(f"{label}: unreadable exit status {raw!r}")
            continue
        meaning, is_alarm = REAPER_CODES[family].get(
            code, (f"UNRECOGNISED exit {code} — treated as broken", True))
        print(f"  {label:<36} exit={code}  {meaning}")
        if is_alarm:
            alarms.append(f"{label}: {meaning}")
    return alarms


# ── the harness-apply pass record (#2416) ────────────────────────────────────────────────────────
# `scripts/harness-apply-pass.sh` runs on a schedule (systemd timer / launchd agent) and writes ONE
# record per pass: the readings it decided from (head, ref, behind, ahead, dirty), the pin records,
# and the verdict. It exists because the measured failure was SILENT: the Mac's `sync.sh` aborted on
# a one-file dirty tree and the orchestrator aged 91 commits behind `main` while every signal said
# "auto", and nothing anywhere reported a behind-by-N. This is the fleet's reader for that number.
#
# ⛔ THE SAME RULES AS THE REAPER RECORD ABOVE, deliberately, because it is the same kind of artifact:
# a SEAM rather than a hardcoded path, an absent record is an alarm only where a schedule is supposed
# to exist, an unreadable or future-dated record is never "fine", and the pass's own success
# vocabulary (0 current / 10 advanced / 11 mended) is the only green set — every refusal is an alarm,
# because a refusal means a HUMAN must resolve something (an ahead box may be a lane's only copy).
def _harness_apply_status_path():
    base = os.environ.get("HARNESS_APPLY_STATE_DIR") or os.path.join(
        os.path.expanduser("~"), ".pi", "agent", "state")
    return os.path.join(base, "harness-apply.status")


def _harness_apply_is_scheduled():
    """Is a harness-apply job installed on this box, or a state dir pinned by env?

    `HARNESS_APPLY_SCHEDULE_ASSERT` is a TEST SEAM (nothing in production sets it) for the same
    reason as `DISK_REAPER_SCHEDULE_ASSERT`: without it a suite's expectation would depend on whether
    the runner carries the unit.
    """
    override = os.environ.get("HARNESS_APPLY_SCHEDULE_ASSERT")
    if override in ("0", "1"):
        return override == "1"
    if os.environ.get("HARNESS_APPLY_STATE_DIR"):
        return True
    home = os.path.expanduser("~")
    for p in ("/etc/systemd/system/eldato-harness-apply.timer",
              os.path.join(home, ".config", "systemd", "user", "eldato-harness-apply.timer"),
              os.path.join(home, "Library", "LaunchAgents", "com.eldato.harness-apply.plist")):
        if os.path.exists(p):
            return True
    return False


def harness_apply_record():
    """Return (detail, alarm) from the harness-apply pass record.

    ⛔ `behind` IS THE HEADLINE, not the exit code. The measured defect was a box 91 commits behind
    while every verdict it could produce read "auto"; a record that says `rc=0 behind=91` must alarm
    on the NUMBER even though the pass exited cleanly (the number is a reading, the code is about the
    pass). Conversely `behind` is read from the record and never re-derived here — one record, one
    measurement.
    """
    path = _harness_apply_status_path()
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            kv = dict(ln.split("=", 1) for ln in (x.strip() for x in fh) if "=" in ln)
    except OSError as exc:                                      # noqa: BLE001
        import errno as _errno
        if exc.errno == _errno.ENOENT:
            if not _harness_apply_is_scheduled():
                return ("no pass record yet, and no harness-apply schedule on this box", False)
            return (f"no pass record at {path} although a harness-apply schedule IS installed — the job is not writing its record", True)
        return (f"pass record UNREADABLE at {path} ({exc}) — this is NOT 'the harness is current'", True)
    try:
        stale = int(os.environ.get("HARNESS_APPLY_STALE_SECONDS", "3600") or 3600)
    except ValueError:
        return (f"HARNESS_APPLY_STALE_SECONDS={os.environ.get('HARNESS_APPLY_STALE_SECONDS')!r} is not a whole number — cannot judge staleness", True)
    try:
        epoch = int(kv.get("epoch", ""))
        age = int(time.time()) - epoch
    except (TypeError, ValueError):
        return (f"record has no readable epoch (rc={kv.get('rc', '?')}) — cannot tell whether the harness is still being applied",
                True)
    if age < 0 or age > stale:
        return (f"record is STALE: last pass {age}s ago (bound {stale}s) — the job is scheduled but is not running",
                True)
    behind = kv.get("behind", "?")
    try:
        behind_n = int(behind)
    except (TypeError, ValueError):
        behind_n = None
    rc = kv.get("rc", "?")
    # ⛔ `deployed` IS THE COMMIT THE BOX RUNS (the pin tree on a cell, the checkout on a Mac), and
    # `behind` is measured from it. On a pin-per-commit cell the checkout is NEVER moved by the advance,
    # so reporting `head` here would name a commit that legitimately stays behind while the box runs
    # main — the alarm would be un-clearable. `head` is printed beside it as the checkout reading.
    deployed = kv.get("deployed", kv.get("head", "?"))
    head = kv.get("head", "?")
    ref = kv.get("ref", "?")
    # ⛔ A COMPARISON THAT WAS NOT FRESH IS NOT A GREEN. `--print-status` (the readiness gate) refuses a
    # record whose `fetch=` is neither `ok` nor absent; this reader ignored the field entirely, so
    # `rc=0 behind=0 fetch=failed` was RED at the gate and CLEAN on the fleet instrument — the same
    # two-readers-one-record shape this PR already fixed twice, pointing the other way. Same allow-list,
    # so neither side grows a second rule.
    fetch_state = kv.get("fetch", "")
    if fetch_state not in ("ok", ""):
        return (f"record rc={rc} was written from a comparison that was NOT fresh (fetch={fetch_state}) — "
                f"deployed={deployed} ref={ref} — cannot-verify is not current", True)
    # ⛔ THE DEPLOYED-DRIFT READING MUST BE READ, OR WRITING IT CHANGES NOTHING (review round 10, P2).
    # `harness-apply-pass.sh` records `drift=` so an instrument can see whether the box actually runs
    # this repo's code; this reader ignored the key, so `drift=not-run:absent` (the checker was NOT
    # FOUND — the arm is inert) printed as `record ok rc=0 … action=current` and the operator-facing
    # instrument CERTIFIED a box whose executing-tree question was never answered. That is the same
    # silent green this whole change exists to end, one level up: the pass is honest, and the reader
    # above it threw the honesty away.
    drift = kv.get("drift", "")
    # ⛔ THE FIELD IS `<state>:<token>`, SO MATCH THE TOKEN, NOT THE WHOLE FIELD (review round 11, P1
    # — the round-10 fix was DEAD because of this). `harness-apply-pass.sh` writes
    # `${DRIFT_STATE}${DRIFT_TOKEN:+:$DRIFT_TOKEN}`, and on the red arm the state IS `drift`, so the
    # record reads `drift=drift:executes:/gone/…` — `startswith("executes:")` therefore NEVER matched
    # and the alarm that exists to stop this instrument certifying a box whose executing tree is gone
    # could not fire. The `not-run` half happened to work, which is exactly why the asymmetry was
    # invisible.
    token = drift.split(":", 1)[1] if ":" in drift else drift
    # ⛔ AND THE ABSENT-CHECKER ALARM MUST KEY ON THE TOKEN TOO (review round 11, P2). The pre-flow
    # refusals that run AFTER a successful fetch (`action=unresolvable-ref`, `action=unresolvable-head`)
    # write a BARE `drift=not-run` — the token half is EMPTY, because `DRIFT_TOKEN` is unset at that point
    # (`write_record`'s pre-init callers run before the drift read) — so a `startswith("not-run")` test
    # names a MISSING CHECKER on a box whose real fault is an unresolvable ref, and printed neither
    # `action=` nor `detail=`, so the true refusal appeared nowhere. Only `absent` means the checker was
    # not found. (Round 14, P2: this comment used to say those refusals write `not-run:not-run`, which
    # nothing can produce — the changed `fleet_health.test.py` asserts the bare form, so the reader and
    # its own test contradicted each other inside one change.)
    if token.startswith("executes:"):
        return (f"THE BOX EXECUTES A HARNESS TREE IT DOES NOT HAVE ({drift}) — deployed={deployed} "
                f"ref={ref} rc={rc} action={kv.get('action', '?')}; redeploying the copy at rest does "
                f"not clear it", True)
    if token == "absent":
        return (f"record rc={rc} deployed={deployed} ref={ref} behind={behind} drift={drift} "
                f"action={kv.get('action', '?')} — the deployed-drift check was NEVER RUN (no "
                f"check-deployed-drift.sh was found), so nothing here measured whether the box runs "
                f"this repo's code", True)
    # An EMPTY key is a record written before this field existed. NAMED, not alarmed: the next cadence
    # writes it, and alarming on the upgrade would red every box once for a field it is about to gain.
    drift_note = f"drift={drift}" if drift else "drift=<not recorded by this pass>"
    if rc in ("0", "10", "11") and behind_n == 0:
        return (f"record ok rc={rc} deployed={deployed} head={head} ref={ref} behind=0 age={age}s "
                f"action={kv.get('action', '?')} {drift_note}", False)
    if behind_n is not None and behind_n > 0:
        return (f"BEHIND origin/{ref}: {behind_n} commit(s) — deployed={deployed} (rc={rc}, "
                f"action={kv.get('action', '?')}, {drift_note}) — the box is not being moved", True)
    return (f"record rc={rc} deployed={deployed} head={head} ref={ref} behind={behind} "
            f"action={kv.get('action', '?')} detail={kv.get('detail', '?')} age={age}s — a human must look "
            f"(an ahead box may hold work that exists nowhere else)", True)


def harness_apply_section():
    """Report the harness-apply PASS RECORD. A separate section, not a row in `reaper_section()`:
    that function is the disk-maintainer table and its suite pins its rows; this is a second, distinct
    scheduled pass and it carries its own record."""
    print("\nharness apply (pass record)")
    detail, alarm = harness_apply_record()
    print(f"  {detail}")
    return [f"harness apply: {detail}"] if alarm else []


def main():
    now = time.time()
    prev = {}
    if os.path.exists(STATE):
        try:
            prev = json.load(open(STATE))
        except Exception:
            prev = {}
    hook_ok, hook = load_hook()
    snap = {}
    suspects = []

    print(f"fleet health — {time.strftime('%H:%M:%S', time.localtime(now))}\n")
    print(f"{'lane':4} {'pid':>7} {'life':9} {'q':>2} {'ctx-age':>8} {'cpu-delta':>10}  flag")
    print("-" * 62)
    attributed = 0
    dead = 0          # lanes POSITIVELY absent/zombie; every other non-holder is UNESTABLISHED
    for lane, sid in LANES:
        rec = hook.get(sid, {})
        pid = rec.get("pid")
        life = rec.get("agentLifecycle") or "?"
        depth = rec.get("activePromptDepth")
        tf = find_transcript(sid)
        age = (now - os.path.getmtime(tf)) if tf else None
        cpu = cputime_secs(pid) if pid else None

        p = prev.get(str(pid), {}) if pid else {}
        delta = None
        if cpu is not None and "cpu" in p:
            elapsed = now - p.get("at", now)
            delta = cpu - p["cpu"]
            delta_txt = f"{delta:+.1f}s/{elapsed:.0f}s"
        else:
            delta_txt = "(first)"

        flag = ""
        quiet = ""
        observed = _observed(pid, rec.get("pidStartSeconds")) if pid else None
        if observed == HOLDER_OBSERVED:
            attributed += 1      # positively bound to a live incarnation — see lane_census()
        if observed in DEAD_OBSERVED:
            # A positively absent/zombie incarnation: the process is gone, so the
            # transcript ladder has nothing left to add.
            dead += 1
            flag = "PID DEAD"
        else:
            # An ABSTENTION is NOT a clean bill of health. Name it, and STILL run the
            # quiet/CPU ladder — an unresolvable identity read must never SUPPRESS the
            # suspect signal, or a stale lane reads as "no suspects" precisely when the
            # identity subsystem (or the whole store) is unavailable.
            if observed is not None and observed != HOLDER_OBSERVED:
                flag = "PID ? (%s)" % observed
            if age is not None and age > SUSPECT_AGE:
                if delta is None:
                    quiet = f"** CHECK: quiet {age:.0f}s, no CPU delta yet **"
                elif delta < 0.5:
                    quiet = f"** SUSPECT: quiet {age:.0f}s AND no CPU consumed **"
                elif observed == HOLDER_OBSERVED:
                    quiet = f"quiet {age:.0f}s, CPU +{delta:.1f}s -> working"
                else:
                    # The CPU delta belongs to a pid the identity rule REFUSED to
                    # attribute to this session (reused / unreadable start). Report the
                    # raw evidence, never a "working" verdict — an unmatched pid's CPU is
                    # not admissible positive evidence (mirrors liveness.py, which reads
                    # such a candidate as `unknown`).
                    quiet = f"quiet {age:.0f}s, CPU +{delta:.1f}s (identity unmatched — not attributable)"
                flag = f"{flag} | {quiet}" if flag else quiet
        if quiet.startswith("**"):
            suspects.append((lane, flag))

        age_txt = f"{age:.0f}s" if age is not None else "-"
        print(f"{lane:4} {str(pid):>7} {life[:9]:9} {str(depth):>2} {age_txt:>8} {delta_txt:>10}  {flag}")

    # ── lane census reconciliation (see lane_census) ────────────────────
    # The roster above is a frozen list; the process table is not. When the roster accounts
    # for NONE of the running pi processes, the table is not a census and must say so rather
    # than let the summary below read as a clean scan.
    # ⛔ NO CENSUS VERDICT WITHOUT A STORE READ (review cycle 2, finding 3). With `hook_ok` False
    # no lane has a record at all, so the census would report "the roster is stale on this box"
    # beside "hook store unreadable" — asserting a cause it never established, and pointing an
    # operator at editing the roster when the STORE READ is the fault. The store failure already
    # has its own INCOMPLETE path below; the census simply has nothing to say about a roster it
    # could not read.
    census_note = (lane_census(attributed, dead, pi_process_count(), len(LANES))
                   if hook_ok else None)
    if census_note:
        print()
        print(f"⚠️  {census_note}")
        suspects.append(("census", census_note))

    # --- task children -------------------------------------------------
    kids = []
    if os.path.isdir(TASK):
        for d in os.listdir(TASK):
            full = os.path.join(TASK, d)
            try:
                newest = max((os.path.getmtime(os.path.join(full, f))
                              for f in os.listdir(full)), default=None)
            except Exception:
                continue
            if newest:
                kids.append((d, now - newest))
    kids.sort(key=lambda k: k[1])
    active = [k for k in kids if k[1] < 3600]
    print(f"\ntask children (last hour): {len(active)} of {len(kids)} on disk")
    for cid, age in active[:12]:
        flag = "  ** SUSPECT: silent >10 min **" if age > CHILD_SUSPECT_AGE else ""
        print(f"  {cid[:8]}  quiet {age:>6.0f}s{flag}")
        if flag:
            suspects.append((cid[:8], "child silent"))

    with open(STATE, "w") as fh:
        json.dump({str(r.get("pid")): {"cpu": cputime_secs(r.get("pid")), "at": now}
                   for r in hook.values() if r.get("pid")}, fh)

    sched_alarms = reaper_section()
    # ⛔ THE HARNESS APPLY RECORD JOINS THE SAME ALARM LIST, so it rides the same non-zero exit: an
    # instrument that printed a drift warning while exiting 0 would be unreadable to a scheduler —
    # which is exactly how the Mac sat 91 commits behind with every signal reading "auto".
    sched_alarms += harness_apply_section()
    if sched_alarms:
        print(f"\n⚠️  {len(sched_alarms)} SCHEDULED-MAINTAINER alarm(s) — a job this box relies on is not doing its work:")
        for a in sched_alarms:
            print(f"   - {a}")

    print()
    if suspects:
        print(f"⚠️  {len(suspects)} suspect(s) — confirm with cmux read-screen before acting:")
        for name, why in suspects:
            print(f"   - {name}: {why}")
    elif hook_ok:
        print("✅ no suspects")
    if not hook_ok:
        # The lane lookup was unusable, so the rows above are NOT a verdict about the
        # lanes they name — hence the non-zero exit and the explicit marker. But this
        # branch runs AFTER the enumeration on purpose: a failed store read must not
        # SUPPRESS a suspect the ladder did find, which is the same defect one level up
        # from where the identity abstention was fixed.
        print("⚠️  hook store unreadable or shape-drifted — scan INCOMPLETE (lane identity not established)")
        return 1
    if census_note:
        # ⛔ REPORTED, NOT DEGRADED TO A WARNING: a census note means the scan is NOT a clean result,
        # and it must reach a scheduler the same way the unreadable store above does — a census that
        # prints rows and exits 0 is exactly the false PASS this guards.
        # ⛔ THIS BRANCH DELIBERATELY CHARACTERISES NOTHING. What KIND of note it is, and what that
        # kind says about the rows, is `lane_census`'s own docstring; the word and tail printed below
        # come from `census_exit_verdict`. Every attempt to summarise those states here in one
        # sentence has been false for at least one of them ("some lanes did not reach a conclusive
        # verdict" — untrue of STALE ROSTER; "contradicted by the population" — untrue of UNVERIFIED,
        # whose population was never read), so the summary is gone rather than re-worded.
        # ⛔ AND IT NAMES THE NUMBER IT ACTUALLY HAS (review cycle 3, finding 2): the line used to
        # read "0 rostered lanes measured" for EVERY note, including a partial mismatch where 1-6
        # lanes WERE established — telling an operator the census established nothing when it had.
        # ⛔ AND IT MUST NOT SAY "INCOMPLETE" ABOUT A COMPLETE ROSTER (review cycle 7, finding 1):
        # the all-dead arm reaches here with EVERY lane conclusive, so "INCOMPLETE — rows without a
        # verdict" was false twice over. The word and the tail come from `census_exit_verdict`, which
        # derives them from the NOTE rather than from `established` — a count that only correlated
        # with the note while STALE ROSTER was the sole complete-roster arm (review cycle 9).
        established = attributed + dead
        word, tail = census_exit_verdict(census_note, attributed, established, len(LANES))
        print("⚠️  lane census %s (%d of %d rostered lanes conclusive, %d attributed alive) — %s"
              % (word, established, len(LANES), attributed, tail))
        return 1
    if sched_alarms:
        # A reaper alarm does not make the LANE rows wrong, so it is reported after them — but it
        # must still be a non-zero exit, or a scheduler calling this script cannot see it either.
        return 1


if __name__ == "__main__":
    sys.exit(main())
