#!/usr/bin/env python3
"""lane-actions.py -- the lane classification as a DETERMINISTIC process whose output is two lists.

WHY THIS EXISTS (owner, 2026-10-05)
-----------------------------------
The orchestrator was hand-classifying ~29 lanes every heartbeat by opening panes, which is slow,
non-repeatable, and done by an expensive LLM session. The owner asked for it to be an automatic
process -- "deterministic code + Jev" -- whose OUTPUT is handed to the agent:
  LIST 1 -- idle lanes that need a dispatch, WITH THEIR LAST MESSAGE
  LIST 2 -- wedged lanes to unblock, with WHY
This file is that process. It is the dispatcher's input, not a report about a report.

IT IMPLEMENTS state/LANE-STATE-DECISION-TREE.md, IN ITS ORDER
-----------------------------------------------------------
Step 0 identity -> Step 1 process exists -> Step 2 CPU-TIME DELTA (strongest) -> Step 3 child in
flight -> Step 4 age of the last tool call -> Step 5 read what it said. Only Step 5 yields meaning,
and it is where Jev belongs; Steps 2-4 exist to decide whether Step 5 is even needed.

EVERY MECHANICAL SIGNAL IS TAKEN FROM scripts/lane-status.py, WHICH IS NOT REWRITTEN HERE.
`lane-status.py` already diffs cumulative `ps -o time` (never `ps -o pcpu`, a lifetime average), and
`lane_cpu_busy()` already refuses to attribute a pid unless EXACTLY one lane maps to EXACTLY one
process. This file consumes its JSON and reuses its `session_file()` / `tail()` / `describe()` /
`_pi_cwd_map()` so there is ONE implementation of each mechanic.

WHAT IS DETERMINISTIC AND WHAT IS NOT
-------------------------------------
  deterministic (code): identity, existence, CPU delta, child in flight, tool age, PROTECTED
                        exclusion, BUSY (auto-nudged) suppression, the two lists
  Jev (one call, batched): ONLY the Step-5 words layer -- CONTINUE / BLOCKED_* / DONE_READY /
                        STALLED. One `choice` question per lane, all answered in ONE round trip
                        (the shape state/lane-verdict.py already uses; its key loader and its
                        criteria text are REUSED here rather than re-integrated).
Jev NEVER decides Steps 1-4 and NEVER overrides them: a lane proven WORKING by CPU time is not sent
to it at all.

STEP 0 IDENTITY IS EVIDENCE, NOT A NAME LIST (owner, 2026-10-20)
-----------------------------------------------------------------
A workspace is a FLEET lane only when that is DEMONSTRABLE -- its session cwd resolves inside a
fleet worktree, or the harness's own spawn record names that worktree. Everything else is the
OWNER'S and is PROTECTED by default. `_is_fleet_worktree()` is the predicate; see the comment block
above it for the measured defect a name list produced. UNREADABLE cwd -> PROTECTED, never "idle".

LIST 1 IS EVIDENCED IDLE, NOT "QUIET"
-------------------------------------
`res["dispatch_targets"]` (and therefore LIST 1) is `is_dispatch_target()`: DONE-IDLE with a
COMPLETED last turn and no child in flight, plus a confident Step-5 says-it-is-finished. WORKING /
TOOL-IN-FLIGHT / CHILD-* / UNBOUND / WEDGED are never dispatch targets, whatever their words say.
That is the decision tree's resolution order for a dispatcher, applied as a predicate instead of a
bare `stale_s` comparison.

FAIL-SAFE DIRECTIONS (each one chosen, not defaulted)
----------------------------------------------------
  * Jev unreachable  -> the words layer is UNREAD, so those lanes go to REPORT ONLY as
    UNCLASSIFIED(JEV-DOWN). They are NEVER guessed into "needs dispatch" or "wedged" -- acting on
    an unread word layer is exactly the failure the tree names.
  * process map lossy/empty -> existence is UNKNOWN, never DEAD. A false DEAD prescribes a
    relaunch, which REPLACES the pane command.
  * shared session id -> AMBIGUOUS-IDENT, report only. Two panes bound to one session file means
    neither lane's staleness/CPU reading is demonstrably about it (Step 0).
  * PROTECTED (a workspace that is not demonstrably a fleet lane -- see Step 0) -> never offered as
    work, never nudged; listed with the reason, and an unreadable cwd counts as PROTECTED.
  * BUSY (already auto-nudged, result SENT/QUEUED within the hour) -> never offered as work.

OUTPUT
------
  state/NEEDS-ACTION.md   -- the two lists + a REPORT ONLY section, each entry carrying
                             `- <lane> [<verdict>] (<age>) [<ws-uuid>] -- <last message ~200c>`
  stdout, ONE line        -- the beat's clause, e.g.
      IDLE->2 need dispatch (state/NEEDS-ACTION.md): laneA, laneB | WEDGED->1: laneC
  The beat is ONE line near its display limit, so the detail goes to the FILE and the beat carries
  the short pointer -- names inline, messages in the file. NO embedded newline is ever printed.

Usage:
  lane-actions.py                       # invoke lane-status.py --json (cache-aware), write the file
  lane-status.py --json | lane-actions.py --stdin -
  lane-actions.py --stdin state/lane-status.last.json
  lane-actions.py --json                # machine-readable result on stdout, file still written
  lane-actions.py --no-jev              # deterministic only (words layer marked UNREAD)
"""
import argparse
import glob
import hashlib
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

HOME = os.path.expanduser("~")
STATE = os.path.join(HOME, ".pi", "agent", "state")
SCRIPTS = os.path.join(HOME, ".pi", "agent", "scripts")
LS_PATH = os.path.join(SCRIPTS, "lane-status.py")
LV_PATH = os.path.join(STATE, "lane-verdict.py")
REG_PATH = os.path.join(STATE, "lane-registry.tsv")
OUT_PATH = os.path.join(STATE, "NEEDS-ACTION.md")
BEAT_PATH = os.path.join(STATE, "NEEDS-ACTION.beat")
# Length of the recap digest the beat carries. 12 hex chars is 48 bits: the digest only has to
# distinguish one tick's recap from the PREVIOUS tick's, and the pair it guards is replaced every
# ~10 minutes on one machine -- it is not a security boundary.
MD_SHA_LEN = 12

# ⛔ TWO FACTS A REFUSAL MUST CARRY, AND NEITHER COULD BE DERIVED FROM `rows` (#2227).
# `_SAMPLED_NOTE` is `lane-status.py`'s own "what I sampled" line, lifted off its stderr: it caps
# its walks (task dirs, session files, pids, activity files) rather than relying on a timeout, and a
# capped read that names its cap is usable evidence while a silent one is a lower bound published as
# the fleet. `_last_good_sentence()` answers "but when did we last actually READ this?" -- with the
# AGE of the published snapshot, never a value from it (a stale verdict is not a current one).
_SAMPLED_NOTE = ""


def _last_good_sentence():
    """The last good snapshot is Ns old -- an AGE, never a value, or `none` if there is none.

    A refusal that does not say this cannot be told apart from one that arrived after a blackout: a
    `TimeoutExpired` minutes after a good read is a busy box, and the same exception after six hours
    is a dead monitor. Neither may be reported by printing the old verdicts -- the age is the whole
    of what a refusal is entitled to borrow from the cache.
    """
    for p in (os.path.join(STATE, "lane-status.last.json"),
              os.path.join(STATE, "lane-status.cache")):
        try:
            return "the last good snapshot is %ds old (%s)" % (
                max(0, int(time.time() - os.path.getmtime(p))), display_path(p))
        except OSError:
            continue
    return "there is NO previous snapshot on this box -- nothing has ever been read here"


def display_path(p):
    """A path a reader can act on. The beat is read in a terminal whose cwd is the agent home, so
    `state/NEEDS-ACTION.md` is the useful form -- a bare basename makes the pointer ambiguous."""
    ap = os.path.abspath(p)
    agent_home = os.path.join(HOME, ".pi", "agent")
    return os.path.relpath(ap, agent_home) if ap.startswith(agent_home + os.sep) else ap
TURN_END = os.path.join(STATE, "turn-end")

# Copied from the two files this consumes, as CONSTANTS with the same meaning. Changing one without
# the other is the two-names-for-one-lane defect the registry header warns about, so they are named
# here with their source.
OVERDUE_S = 25 * 60            # lane-status.py OVERDUE_S: the harness's in-flight silence bound
PANE_CHILD_LIVE_S = 25 * 60    # a pane-drawn child younger than this is inside the same bound
TOL_CPU_S = 0.10               # lane-status.py lane_cpu_busy(): the stated CPU-time tolerance
COLD_MIN = 2 * 60              # decision tree Step 4: "< 2 min -> TOOL-IN-FLIGHT"
WARM_MIN = 10 * 60             # decision tree Step 4: "> 10 min -> STEP 5"
NUDGE_SUPPRESS_S = 3600        # orchestrator-heartbeat.sh NUDGE_SUPPRESS_S
REGISTRY_GRACE = 6             # a snapshot with fewer lanes than registry-grace is PARTIAL
# PROTECTED BY A DECLARED LIST, NOT NAMES BURIED IN CODE (owner report 2026-10-20, twice).
# A workspace the owner created or renamed -- "Personal website" -- was classified as an idle
# FLEET LANE and received a lane brief for tortoise PR #9150. Protection that depends on
# remembering which strings are the owner's is the "passes only by remembering" failure the fleet
# forbids -- so the owner declares them in a file instead of in this source.
#
# ⛔ THIS IS A UNION MEMBER ONLY, and Step 0 (below) is the mechanism: a workspace is a fleet lane
# only when that is DEMONSTRABLE, and a declared entry can ADD protection but never make a lane
# FLEET. Both arrivals are kept -- the evidence predicate from this branch and the declared list
# from `main` -- because each protects a case the other does not.
_OWNER_WS_FILE = os.path.join(os.path.expanduser("~"), ".pi", "agent", "state",
                              "owner-workspaces.txt")


def _owner_workspaces() -> tuple:
    # ⛔ A MALFORMED FILE MUST NOT TAKE THE TOOL DOWN. This is read at IMPORT time, so an exception
    # here kills every lane-actions.py invocation -- roster, doctor triage, every classify_row
    # consumer -- instead of degrading to the historical tuple. Two measured shapes (review, P1):
    #   * a non-UTF-8 byte, or the UTF-16LE that a PowerShell `>` redirect produces, raises
    #     UnicodeDecodeError -- whose MRO parent is ValueError, NOT OSError -- so `except OSError`
    #     missed it and the whole triage tool died at import;
    #   * a UTF-8 BOM is not whitespace to str.strip(), so a plain `open()` left the FIRST declared
    #     name as "\ufeffPersonal website", which can never match a lane -- the owner first entry
    #     would stay unprotected while the roster printed it as PROTECTED.
    # `utf-8-sig` strips the BOM, `errors="replace"` turns any remaining bad byte into U+FFFD rather
    # than raising, and ValueError stays caught as the belt to that brace.
    try:
        with open(_OWNER_WS_FILE, encoding="utf-8-sig", errors="replace") as f:
            return tuple(x.strip() for x in f
                         if x.strip() and not x.lstrip().startswith("#"))
    except (OSError, ValueError):
        return ()


MAX_NAMES = 4                  # names inline in the beat clause; the rest live in the file
SUMMARY_MAX = 300
LAST_MSG_CHARS = 200


# ── module loading (reuse, do not rewrite) ────────────────────────────────────────────────
def _load(path, name):
    try:
        spec = importlib.util.spec_from_file_location(name, path)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod
    except Exception:
        return None


# ── small helpers ─────────────────────────────────────────────────────────────────────────
def _age(s):
    if s is None:
        return "-"
    s = int(s)
    if s >= 3600:
        return "%dh%02dm" % (s // 3600, (s % 3600) // 60)
    if s >= 60:
        return "%dm" % (s // 60)
    return "%ds" % s


def _oneline(t):
    return " ".join((t or "").replace("\n", " ").split())


def _clip(t, n):
    t = _oneline(t)
    return t if len(t) <= n else t[: n - 1].rstrip() + "\u2026"


DEGRADED_MSG = (
    "lane-actions: REFUSING a DEGRADED snapshot -- lane-status could not read the cmux fleet "
    "roster, so it covers the hand-written TSV only and every live-only lane is INVISIBLE. "
    "Acting on it would report a blind fleet as a healthy one; re-run lane-status against a "
    "reachable cmux.")


def _refuse_if_degraded(rows, where):
    """⛔ ONE GUARD, BOTH PATHS — and both have been guarded from the start.

    ⚠️ CORRECTED 2026-10-13. This docstring opened with "The refusal used to live INSIDE the
    `--stdin` branch only, so the OTHER path accepted a degraded snapshot and acted on a fleet read
    missing every live-only lane." That lineage claim is FALSE: at this PR's base NEITHER path had
    any degraded refusal (`git show 42f0b14:scripts/lane-actions.py | grep -c degraded` -> 0), so
    both arrived together and nothing was ever "left" unguarded. ⚠️ AND THIS CORRECTION'S FIRST
    DRAFT INTRODUCED A NEW FALSEHOOD (caught by review cycle 3), which is the worst class here: it
    claimed "the deployed copy that predated this branch asserted the same claim about the OTHER
    direction". Both halves are wrong. The deployed
    `~/.pi/agent/scripts/lane-actions.py` carries this SAME sentence about the SAME path — a second
    copy of the falsehood, not a different direction — and it did NOT predate this branch: it
    contains `def offerable` / `CONF_MIN`, and `git log -S 'def offerable' --all --
    scripts/lane-actions.py` shows those enter history only in this branch's own commit. It is a
    snapshot of this branch's IN-PROGRESS work, so it is evidence about nothing else. The core
    correction above stands on the base-lineage check; only the comparison to the deployed copy was
    invented. The correction matters because a
    reader who believes one path was historically the hole will guard that one — which is the
    failure this docstring already warns about one paragraph below.

    ⛔ WHICH PATH IS PRODUCTION: `--stdin`. heartbeat-loop.sh invokes this tool as
    `lane-actions.py --stdin "$SNAP"`, and `lane-scan-fallback.sh` is a second `--stdin` caller.
    ⚠️ CORRECTED 2026-10-13: this named `queue-dispatch` as the invoke-path consumer, which is
    FALSE — `queue-dispatch.py` never references `lane-actions.py` at all (it drives
    `lane-status.py` / `lane-guard.py`).
    ⛔ CORRECTED AGAIN 2026-10-20: this then named `pr-doctor.py` as "the one `lane-actions.py
    --json` call". THAT IS NOW FALSE TOO, and it is a co-deployment trap: `pr-doctor.py` retired
    the lane-table path (#1874) and spawns background workers instead, so `rg -n 'lane-actions'
    scripts/pr-doctor.py` matches COMMENTS only. The `--stdin` callers above are the whole
    invoke-path population; `--json` has NO live in-repo caller and exists for manual reads and
    tests. Do not restore a consumer claim without running that grep against the CODE.
    ⛔ NAMED, NOT NUMBERED (#1872 review round 10): the line number that used to be here was already
    wrong on `origin/main` by the time anyone read it, and it is not the call today -- a number in a
    co-deployment pointer rots the moment either file is edited. Both paths are guarded; the tests
    that pin them live in test_lane_actions.py."""
    if any(r.get("degraded") for r in rows if isinstance(r, dict)):
        raise SystemExit(DEGRADED_MSG + " (%s)" % where)


def _live_want(LS=None):
    """The fleet size the scan is SUPPOSED to return, or None when it cannot be known.

    ⛔ NONE IS NOT ZERO. This returned 0 on failure, and the guard is `if not want or ...` -- so an
    UNREADABLE roster DISABLED the partial-snapshot guard entirely, accepting a truncated snapshot on
    the first attempt with no re-scan and no warning. "Guard disabled" and "guard needed" were the
    same event, which is the fail-open direction: a partial fleet read published as a healthy one.
    Callers must treat None as UNKNOWN and take the strongest read available.

    The fleet size the scan is SUPPOSED to return: the LIVE roster, never the hand-written TSV.

    ⛔ MEASURED 2026-10-12: this was `len(_registry_labels())` -- the TSV, 27 rows -- while
    `registry()` had just become live-only (16 workspaces). `16 >= 27 - REGISTRY_GRACE` is FALSE, so
    the partial-snapshot guard declared a HEALTHY snapshot PARTIAL and re-ran the entire scan with
    `--no-cache` on every pass, up to ~300s per tick, forever. A guard against a truncated snapshot
    must be measured against what a complete one contains.
    """
    try:
        mod = LS or _load(LS_PATH, "lane_status_livewant")
        n = len(mod._live_workspaces() or [])
        return n or None
    except Exception:
        return None


def _registry_labels():
    out = []
    try:
        with open(REG_PATH, errors="ignore") as fh:
            for ln in fh:
                if not ln.strip() or ln.startswith("#") or "\t" not in ln:
                    continue
                out.append(ln.split("\t")[0].strip())
    except OSError:
        pass
    return out


def _busy_sids():
    """Session ids whose turn was already auto-nudged (SENT/QUEUED within the hour).

    Same rule and same shared marker directory as orchestrator-heartbeat.sh: a lane the nudger has
    already told to continue is WORKING, so it must not be offered again.
    """
    out = set()
    try:
        for f in os.listdir(TURN_END):
            if not f.endswith(".json"):
                continue
            p = os.path.join(TURN_END, f)
            try:
                if time.time() - os.path.getmtime(p) > NUDGE_SUPPRESS_S:
                    continue
                d = json.load(open(p))
            except Exception:
                continue
            if str(d.get("result") or "").upper().startswith(("SENT", "QUEUED")):
                out.add(d.get("sid"))
    except OSError:
        pass
    return out


# ── STEP 0: IDENTITY IS EVIDENCE, NEVER A NAME LIST (owner, 2026-10-20) ────────────────────
# ⛔ THE DEFECT THIS REPLACES, STATED WITH ITS EVIDENCE. Protection used to be
# `PROTECTED = ("DMeer", "DMer", "HANG")` matched by SUBSTRING against the lane's NAME. The
# owner's own workspace is titled **"Personal website"**, which matches none of those, so the
# roster classified it as an idle fleet lane and the PR doctor dispatched a tortoise PR brief INTO
# IT -- twice, reported by the owner. A name list can only protect the names somebody remembered,
# and every name it misses fails toward "idle: dispatch it", which is the one direction that types
# into the owner's own work.
#
# ⛔ SO THE PREDICATE IS INVERTED: a workspace is a FLEET lane only when that is DEMONSTRABLE, and
# everything else belongs to the owner. There are exactly two demonstrable forms, and each is an
# ARTIFACT THE HARNESS WROTE rather than a string a human chose:
#   * its session cwd resolves inside a fleet WORKTREE -- `.../.worktrees/<name>`,
#     `/tmp/cell-home/wt-<n>`, `.../wt-<n>`. The cwd is what the lane is actually editing, and it
#     is published on the snapshot row by `lane-status.py` from cmux's `current_directory`;
#   * or it carries a FLEET SPAWN MARKER -- `$O/bg/<name>.started`, written by
#     `nonblocking-dispatch.sh`, which records the `worktree=` path the harness itself created.
# ⛔ UNREADABLE IS PROTECTED. An absent cwd is not evidence of an idle lane; it is the ABSENCE OF
# EVIDENCE, and for "may I type into this?" the fail-closed direction is NO.
#
# The historical names survive ONLY as an additional UNION: they can ADD protection and are never the
# reason a lane is FLEET. Leaving them in keeps a DMeer lane protected even if someone later gives it
# a worktree-shaped cwd, which is exactly what a union member is for.
PROTECTED_LEGACY_NAMES = ("DMeer", "DMer", "HANG")


def _declared_owner_hit(lane):
    """True when the lane title matches an entry DECLARED in `state/owner-workspaces.txt`.

    The owner-declared list, not a tuple in this source: the failure it answers is precisely
    "a name nobody remembered", and a file the owner can edit is the only form that does not
    require a code change to protect their own workspace. A read failure yields `()` (see
    `_owner_workspaces`), which means NO declared protection -- and Step 0 still protects every
    cwd that is not demonstrably a fleet worktree, so a lost list cannot make the fleet unsafe;
    it only loses the belt over that brace.
    """
    name = (lane or "").lower()
    return any(w in name for w in (n.lower() for n in _owner_workspaces()) if w)


def _legacy_name_hit(lane):
    """True when the lane title carries a historical owner-lane name as a WORD.

    ⛔ A WORD, NOT A SUBSTRING (review round 9, P3). The union has to keep matching titles like
    `DMeer - linkedin outreach`, which is why it cannot be an exact-title test -- but a raw
    `p in lane` also demotes a demonstrably-fleet lane whose title merely CONTAINS one of these
    (`CHANGELOG sweep`, `SHANGHAI rollout` both contain `HANG`), removing it from LIST 1. Matching
    whole alphanumeric tokens keeps the protection the names were remembered for and drops the
    accidental class.
    """
    wanted = set(n.lower() for n in PROTECTED_LEGACY_NAMES)
    tok, toks = [], set()
    for ch in lane or "":
        if ch.isalnum():
            tok.append(ch)
        elif tok:
            toks.add("".join(tok).lower())
            tok = []
    if tok:
        toks.add("".join(tok).lower())
    return any(w in toks for w in wanted)

# The worktree shapes, matched after `realpath` so a path that only SPELLS like a lane
# (`/x/wt-1/../../owner/project`, or a symlink named `wt-9`) is resolved before it is judged.
# ⛔ THE `wt-<slug>` BRANCH IS ANCHORED TO THE FLEET HOME, NOT TO ANY SEGMENT (review round 1,
# P2, MEASURED). It used to require a DIGIT (`^wt-[0-9]`), so `/tmp/cell-home/wt-4529-ai` was a
# fleet lane while `/tmp/cell-home/wt-lane-identity` -- this very lane's own linked worktree -- read
# as the OWNER's, and was permanently excluded from dispatch. The box's own recipe is
# `git worktree add $HOME/wt-<slug> -b <branch>`, so the evidence is "a direct child of the fleet
# home named `wt-*`", which keeps every slug AND still rejects `/Users/owner/repo/wt-1-final-draft`
# (a name inside somebody's project, not a lane root).
FLEET_WORKTREE_DIR = ".worktrees"
# THE ROOTS the fleet creates lanes in. `$FLEET_HOME` / `$CELL_HOME` / `$FLEET_CELL_HOME` when the
# fleet sets them (scripts/lib/fleet-inventory.sh uses the same names), `$HOME`, this box's cell
# home, and the TEMP ROOT.
#
# ⛔ THE TEMP ROOT IS NOT A CONVENIENCE -- IT IS MEASURED (review round 3, P1). The first version
# listed only `$HOME` and `/tmp/cell-home`, and on the box the directive was written on the fleet's
# OWN recipe is `git worktree add /tmp/wt-<slug>`: of 38 worktree paths in
# `state/pi-reap-worktrees.log`, 15 were real linked worktrees under `/tmp` (`.git` ->
# `/tmp/cell-t3/.git/worktrees/wt-9204`) and EVERY ONE was classed the owner's, i.e. permanently
# excluded from dispatch -- the exact defect the `wt-` shape was introduced to fix, re-created one
# level up as a home whitelist. A list of homes is a list; the anchor has to include where the fleet
# actually writes.
FLEET_ROOTS = tuple(dict.fromkeys(
    _h for _h in (
        os.environ.get("FLEET_HOME"), os.environ.get("CELL_HOME"),
        os.environ.get("FLEET_CELL_HOME"), os.path.expanduser("~"),
        "/tmp/cell-home", tempfile.gettempdir(), "/tmp", "/private/tmp") if _h))
_WT_PREFIX = "wt-"


def _is_fleet_wt_dir(path):
    """True when `path` is `<$FLEET_ROOT>/wt-<slug>` (or below) AND is a REAL linked git worktree.

    ⛔ THE NAME ALONE IS NOT EVIDENCE (review round 4, P2). Root anchoring plus a `wt-` name made
    this a name test: `/tmp` is world-writable, so ANY `/tmp/wt-anything` directory read as a fleet
    lane and could reach `dispatch_targets` -- acceptance WITHOUT evidence, in the one direction the
    directive forbids. It costs nothing to demand the artifact: measured on the box, the fleet's
    `/tmp/wt-*` lanes are real linked worktrees (`.git` as a FILE), so they still pass, and only a
    directory no `git worktree add` created stops being a lane -- correctly: it is nobody's lane.
    """
    for root in FLEET_ROOTS:
        r = _real(root)
        if not r or r == os.sep or path == r or not path.startswith(r + os.sep):
            continue
        first = path[len(r) + 1:].split(os.sep)[0]
        if first.startswith(_WT_PREFIX) and len(first) > len(_WT_PREFIX):
            return _is_linked_worktree(path)
    return False


# ⛔ STATED BOUNDARY, AND IT IS FAIL-CLOSED ON PURPOSE (review round 11, P1, MEASURED). A REAL linked
# worktree directly under a fleet root whose name is not `wt-<slug>` (`/tmp/w9516`, `/tmp/p9660-resid`,
# `/tmp/l9400`) does NOT match the arm above, so it reads PROTECTED — the owner's. Measured on this box:
# 25 of the 33 real linked `/tmp` worktrees in `state/pi-reap-worktrees.log` are classified that way.
#
# The tempting fix is to drop the name and accept any real linked worktree at depth 1. DO NOT: that is
# the reverse failure, and it is the one this PR exists to prevent. `git worktree add ~/tortoise-wip
# fix/x` produces exactly that shape, so the owner's own scratch work would become a dispatch target,
# a pr-doctor `reset --hard` target, and a heartbeat typing target — the `Personal website` incident
# re-created. The pin is `test_a_real_worktree_in_a_fleet_root_is_still_not_a_lane_without_the_NAME`.
#
# Neither spelling is the real question. Both directions need PROVENANCE — a durable record of which
# worktrees the fleet itself created — which is agent-infra#2213 (`_spawn_marker_worktrees` is the only
# such record today, and measurement shows it names only `<repo>/.worktrees/prd-*`, so it cannot yet
# adjudicate these). Until that registry exists, unknown provenance resolves to the owner: refusing to
# type into someone's work is the cheap error, dispatching into it is not. Filed, not forgotten.


def _real(path):
    """The resolved absolute path, or **None** when it cannot be resolved. NEVER raises.

    ⛔ CATCH `ValueError` TOO (review round 2, P3, MEASURED). `realpath` raises ValueError (not
    OSError) for an embedded NUL, and only OSError was caught -- so a cwd containing `\x00` escaped
    this function, escaped `_is_fleet_worktree`, and killed the WHOLE beat with a traceback instead
    of classifying one lane PROTECTED. The docstring's own promise is fail-closed; a guard that
    turns one unreadable row into a dead instrument is not that.

    It returns None rather than a best-effort path on purpose: an unresolvable path is EVIDENCE
    THAT COULD NOT BE READ, and fabricating a normalised spelling of it would let a poisoned cwd
    decide its own classification (measured: `/tmp/cell-home/wt-1\x00bad` came back with a
    `wt-` first segment and read as FLEET). Every caller turns None into "no evidence".
    """
    if not isinstance(path, str) or not path:
        return None
    # ⛔ REJECT AN EMBEDDED NUL EXPLICITLY, DO NOT CATCH IT (review round 11, P2, MEASURED).
    # `posixpath.realpath` only RAISES `ValueError` for a NUL from 3.10; on **3.9** it goes through
    # `islink()`, which swallows it, and returns the string unchanged. `/usr/bin/python3` here is
    # 3.9.6 and it is what `heartbeat-loop.sh` / `orchestrator-heartbeat.sh` run these files with, so
    # the `except ValueError` below pinned a 3.12-only behaviour: measured, `_real('/tmp/cell-home/
    # wt-1\x00bad')` returned the poisoned spelling on 3.9, and `_is_fleet_wt_dir` then read its
    # `wt-` first segment as FLEET — the exact "poisoned cwd decides its own classification" failure
    # this docstring says it prevents. CI pins 3.12, so the suite was green while the deployed
    # runtime was unguarded. A NUL can never appear in a real path, so testing for it is sound on
    # every interpreter and does not depend on which one is running.
    if "\x00" in path:
        return None
    try:
        return os.path.realpath(path)
    except (OSError, ValueError):
        return None


def _is_linked_worktree(path):
    """True when `path` sits inside a REAL linked git worktree.

    ⛔ A `.git` FILE IS NOT ENOUGH (review round 8, P3): `git submodule` and `git init
    --separate-git-dir` write one too, and the docstrings used to present the file itself as proof
    of a worktree. What `git worktree add` writes is a POINTER TO `<main>/.git/worktrees/<name>`, so
    that is what is required -- a submodule module dir or a custom git dir does not match. The walk
    is bounded and stops at a `.git` DIR, which means a main checkout: a path inside a normal
    repository is not a lane.
    """
    cur = _real(path)
    if not cur:
        return False
    for _ in range(64):
        g = os.path.join(cur, ".git")
        try:
            if os.path.isdir(g):
                return False       # the main checkout, not a worktree
            if os.path.isfile(g):
                with open(g, errors="ignore") as fh:
                    head = fh.read(512)
                up = head.strip().splitlines()[0] if head.strip() else ""
                if not up.startswith("gitdir:"):
                    return False
                target = up.split(":", 1)[1].strip().replace(os.sep, "/")
                return "/worktrees/" in (target + "/")
        except (OSError, IndexError):
            return False
        parent = os.path.dirname(cur)
        if parent == cur:
            return False
        cur = parent
    return False


def _is_fleet_worktree(cwd):
    """True ONLY when `cwd` is DEMONSTRABLY a fleet worktree.

    Fail-closed by construction: None, "", a non-absolute path, or anything that does not carry a
    fleet worktree shape returns False, and every caller turns False into PROTECTED. There is no
    third answer and no default-to-lane.

    The path is RESOLVED first (`realpath`: `..` collapsed, symlinks followed), so identity is a
    fact about where the lane really is, never about how its cwd happens to be spelled.

    Matches:
      /Users/x/Documents/GitHub/tortoise/.worktrees/prd-12   a repo's LINKED worktree (has a .git file)
      /tmp/cell-home/wt-123, .../wt-lane-identity           the box's own lane shape ($FLEET_HOME/wt-*)
    Rejects:
      /Users/x/Personal website                             the owner's project (the defect)
      /Users/x/Documents/GitHub/tortoise                    the shared checkout, not a worktree
      /Users/x/repo/wt-1-final-draft                        a NAME inside a project, not a lane root
      /Users/x/wt-1/../../../Users/x/Personal website       a path that only SPELLS like a lane
      /x/.worktrees/b                                       a plain directory that only SPELLS like one
      None / "" / "repo/wt-1"                               unreadable or unrooted

    ⛔ REVIEW ROUND 2 (P2): `.worktrees` used to be accepted on its SPELLING, so ANY directory of
    that name -- including one the owner made inside their own project -- was a dispatch target, and
    pr-doctor's adopt arm could `reset --hard` in it. It now requires a REAL linked worktree: a
    `.git` FILE somewhere at-or-above the path whose `gitdir:` points at `<main>/.git/worktrees/<name>`
    -- the pointer `git worktree add` writes. A main checkout (`.git` as a DIR) is not one, and
    neither is a `.git` file written by `git submodule` (`.../.git/modules/<name>`) or by
    `git init --separate-git-dir` (a custom directory).

    ⛔ STATED BOUNDARY: an owner's own REAL git worktree still reads as fleet
    (`/Users/x/Personal website/.worktrees/preview`, once `git worktree add` has made it). The
    `wt-` shape is anchored to a fleet home instead, but `.worktrees` is the standard git worktree
    location and the directive names it as the fleet's own shape, so narrowing further needs a
    fleet-repo REGISTRY -- which, on a box with no spawn record yet, would empty the dispatch list
    (the silent failure this file legislates against elsewhere). The boundary is pinned by
    `test_an_owners_own_real_worktree_is_the_documented_boundary` so it stays visible, and closing
    it is its own issue (agent-infra#2213), not a guess here.
    """
    if not cwd or not isinstance(cwd, str):
        return False
    p = cwd.strip()
    if not p.startswith("/"):
        return False          # a relative path is not a cwd anything can be resolved against
    p = _real(p)
    if not p:
        return False          # unreadable (poisoned bytes, an I/O error): no evidence, so PROTECTED
    parts = [x for x in p.split("/") if x]
    if not parts:
        return False          # "/" itself is not a worktree
    if FLEET_WORKTREE_DIR in parts and _is_linked_worktree(p):
        return True
    return _is_fleet_wt_dir(p)


def _spawn_marker_worktrees(bg_dir=None):
    """Worktree paths the HARNESS recorded spawning into: `$O/bg/<name>.started`.

    `nonblocking-dispatch.sh` writes `name= / worktree= / branch= / prompt= / started= / cap=` when
    it backgrounds a worker, so this is the fleet's own record of a worktree IT created -- the
    second demonstrable form of identity, and the one that covers a worktree outside the standard
    shapes. Bounded to ONE directory, read tolerantly, and an ABSENT directory is the NORMAL case
    (a box with no background worker has written no marker), so it yields an empty set, never an
    error and never a guess.
    """
    d = bg_dir or os.path.join(os.environ.get("O") or os.path.join(HOME, "orchestrator"), "bg")
    out = set()
    try:
        names = glob.glob(os.path.join(d, "*.started"))
    except OSError:
        return out
    for f in names:
        try:
            with open(f, errors="ignore") as fh:
                for ln in fh:
                    k, _, v = ln.partition("=")
                    if k.strip() != "worktree" or not v.strip():
                        continue
                    wt = v.strip()
                    # ⛔ A MARKER GOES STALE WHEN ITS WORKTREE IS GONE (review round 1, P3). Nothing
                    # removes `$O/bg/*.started`, so a marker written once is read for ever -- and
                    # nothing in the harness reaps them. A path that no longer exists cannot be a
                    # lane the fleet is running in, so it is dropped; a marker whose directory still
                    # exists is kept, because a worker's worktree outlives its `.rc` file.
                    #
                    # ⛔ AND THE MARKER EDGE IS ALSO EVIDENCE-TESTED (review round 5, P2, MEASURED).
                    # Its writer validates only `[ -d "$WT" ]`, and `lane_identity` matches a marker
                    # as an ANCESTOR, so one dispatch whose worktree argument was `$HOME` or `/tmp`
                    # would have blanketed every workspace below it -- permanently, since markers are
                    # never reaped and `$HOME` never disappears. A real linked worktree is required,
                    # which also rejects a marker equal to a fleet root or to `/`.
                    rp = _real(wt)
                    if rp and os.path.isdir(rp) and _is_linked_worktree(rp):
                        out.add(rp)
        except OSError:
            continue          # one unreadable marker never invalidates the others
    return out


def _under(path, parent):
    p, q = _real(path), _real(parent)
    if not p or not q:
        return False
    return p == q or p.startswith(q + os.sep)


def lane_cwd(row):
    """The lane's session cwd, or None when it is UNREADABLE.

    ONE source, deliberately: the snapshot row. `lane-status.py` publishes it from cmux's
    `current_directory` (the value cmux itself holds for the workspace), so it is evidence about
    THIS lane rather than a path guessed from a pid->cwd map (where sibling lanes collide) or from
    the session-directory name (which is LOSSY: the mangling turns "/" and "." into "-", so
    `/x/.worktrees/y` and `/x/-worktrees/y` encode identically -- a guess that reads a fleet lane as
    the owner's, or the owner's as a fleet lane, is worse than no answer).

    None is a REAL answer here: the caller turns it into PROTECTED.
    """
    cwd = row.get("cwd") if isinstance(row, dict) else None
    return cwd.strip() if isinstance(cwd, str) and cwd.strip() else None


def lane_identity(row, markers=None):
    """(identity, evidence) for ONE row -- `"FLEET"` or `"OWNER"`, never a third value.

    OWNER is the DEFAULT and covers everything not demonstrably the fleet's, including an
    unreadable cwd. `evidence` is the sentence the report prints, so a reader can audit the
    classification instead of trusting it.
    """
    cwd = lane_cwd(row)
    marks = _spawn_marker_worktrees() if markers is None else markers
    if cwd is None:
        return "OWNER", ("its session cwd is UNREADABLE, so no fleet worktree can be demonstrated "
                         "-- PROTECTED by default (fail-closed), never treated as an idle lane")
    if _is_fleet_worktree(cwd):
        return "FLEET", "its session cwd %s is a fleet worktree" % cwd
    # A marker names a WORKTREE the harness created, so it is matched as that worktree or a path
    # below it -- never as a container: `_under` is directional and the marker side must be the
    # PARENT (the `_is_linked_worktree` requirement above is what keeps that honest).
    for m in sorted(marks):
        if _under(cwd, m):
            return "FLEET", ("its session cwd %s carries a fleet spawn marker (%s)" % (cwd, m))
    return "OWNER", ("its session cwd %s is NOT a demonstrable fleet worktree -- PROTECTED "
                     "(fail-closed). This asserts the RULE, not ownership: a real linked worktree "
                     "outside the `wt-<slug>` shape lands here too, because unknown provenance "
                     "resolves to the owner (agent-infra#2213) -- refusing costs a dispatch cycle, "
                     "accepting types into someone's uncommitted work" % cwd)


# ── STEP 1: does the process exist? (strict attribution or NO SIGNAL) ──────────────────────
def dead_lanes(rows, LS):
    """(set of lane labels with no live pi, reason string).

    The tree's Step 1 is the ONLY place a lane is called DEAD, and a false DEAD prescribes a
    relaunch that REPLACES the pane command -- so this refuses to answer unless attribution is
    EXACTLY one lane <-> EXACTLY one process, and it refuses to answer at all when the process map
    itself looks lossy. Two independent reads of the same universe (lsof cwds vs pgrep/ps pids) are
    cross-checked; when they disagree the answer is UNKNOWN, never DEAD.
    """
    files = {}
    for r in rows:
        try:
            files[r["lane"]] = LS.session_file(r.get("sid")) if r.get("sid") else None
        except Exception:
            files[r["lane"]] = None
    try:
        pid_cwds = LS._pi_cwd_map() or {}
    except Exception as e:
        return set(), files, "pid-map unavailable (%s) -- existence UNKNOWN" % type(e).__name__
    if not pid_cwds:
        return set(), files, ("pid-map EMPTY -- existence UNKNOWN for every lane "
                              "(absence of a signal is not evidence of death)")
    dirl, dirp = {}, {}
    for lane, p in files.items():
        if p:
            dirl.setdefault(os.path.basename(os.path.dirname(p)), []).append(lane)
    for pid, cwd in pid_cwds.items():
        try:
            dirl_key = "--" + cwd.strip("/").replace("/", "-") + "--"
        except Exception:
            continue
        dirp.setdefault(dirl_key, []).append(pid)
    cand = []
    for r in rows:
        lane = r.get("lane")
        p = files.get(lane)
        if not p:
            continue
        # Two guards before a lane may be called DEAD, because a false DEAD prescribes a RELAUNCH
        # that replaces the pane command:
        #  * a non-None `cpu` read PROVES a live process for this session dir (lane_cpu_busy only
        #    answers when exactly one lane maps to exactly one pid), so existence is settled and the
        #    map is not consulted. Only unattributable lanes are candidates.
        #  * a transcript written in the last 10 minutes was written by a live process.
        # Both make the verdict strictly weaker than the evidence the tree ranks above it.
        if r.get("cpu") is not None:
            continue
        st = r.get("stale_s")
        if st is not None and st <= 600:
            continue
        d = os.path.basename(os.path.dirname(p))
        if len(dirl.get(d, [])) != 1:
            continue                       # two lanes share this cwd -> unattributable
        if len(dirp.get(d, [])) == 0:
            cand.append(lane)
    if not cand:
        # No lane looks dead, so the SECOND process read -- bought only to detect a LOSSY cwd map --
        # is not needed. It costs ~2s and this check runs inside a bounded heartbeat step.
        return set(), files, ("pid-map %d cwds, every lane attributable to a live pi "
                              "(strict one-lane-one-process)" % len(pid_cwds))
    # A candidate exists, so the answer MATTERS and the lossy-map cross-check must be paid for: two
    # independent reads of the same universe disagreeing means UNKNOWN, never DEAD.
    try:
        cpu_map = LS._pi_cpu_map() or {}
    except Exception:
        cpu_map = {}
    if len(cpu_map) and len(pid_cwds) < 0.6 * len(cpu_map):
        return set(), files, ("pid-map LOSSY (%d cwds vs %d live pi) -- existence UNKNOWN"
                              % (len(pid_cwds), len(cpu_map)))
    return set(cand), files, "pid-map %d cwds / %d pi, strict one-lane-one-process" % (
        len(pid_cwds), len(cpu_map))


# ── the decision tree, in order ───────────────────────────────────────────────────────────
def child_evidence(row):
    """(evidence_strings, live_bool) for a child in flight.

    A `task` child persists NO session file, so the ONLY facts about it are: its own transcript (if
    one was found), its on-disk effect, and the pane line. None of them is decisive; together they
    answer "is the child demonstrably moving".
    """
    ev, live = [], False
    c = row.get("child") or {}
    if c:
        ev.append("child dispatched %s ago" % _age(c.get("age")))
        # A child the CURRENT scan can see, dispatched inside the harness in-flight bound, IS
        # evidence of life -- the record itself is the observation. Without this line the branch
        # below reads "no evidence of life on any signal" for a child that started 40s ago and
        # marks it CHILD-OVERDUE. MEASURED 2026-10-05 on `tortoise-sweep`.
        if c.get("age") is not None and c["age"] < OVERDUE_S:
            live = True
    if row.get("child_grew"):
        ev.append("child transcript grew in the sample window")
        live = True
    cs = row.get("child_stale")
    if cs is not None:
        if cs <= 900:
            ev.append("child wrote %s ago" % _age(cs))
            live = True
        else:
            ev.append("child transcript quiet %s" % _age(cs))
    ca = row.get("child_activity")
    if ca is not None:
        if ca <= 900:
            ev.append("child wrote a file %s ago" % _age(ca))
            live = True
        else:
            ev.append("child file activity stale %s" % _age(ca))
    pk = row.get("pane_children") or []
    if pk:
        youngest = min((k.get("age") or 0) for k in pk)
        ev.append("pane shows %d child session(s), youngest %s old" % (len(pk), _age(youngest)))
        if youngest < PANE_CHILD_LIVE_S:
            live = True
    dec = row.get("declared") or []
    if dec:
        ev.append("%d declared pi child process(es) alive" % len(dec))
        live = True
    return ev, live


def dispatch_result(parent_file, LS):
    """Did this lane's newest `task`/`subagent` dispatch RETURN?

    True = returned (a `toolResult` for its call id is recorded in the lane's OWN transcript),
    False = still open (no result recorded), None = cannot tell.

    WHY THIS EXISTS. A dispatch that RETURNED and a dispatch that was CUT are INDISTINGUISHABLE
    by the "is there a child transcript to recurse into" test: neither leaves a child behind, so
    both read as "no child". They have OPPOSITE actions -- a cut child needs intervention, a
    returned one means the lane has moved on. The difference is not in the child, it is in the
    PARENT: a returned dispatch HAS a toolResult, keyed by its call id. `lane-status.py` already
    pairs calls to results for its own purposes; this reuses that pairing rather than writing a
    new one, and it is asked here only of the dispatch the classifier believes is unmatched.
    """
    if not parent_file or LS is None:
        return None
    try:
        calls, results = {}, set()
        for rec in LS.records(parent_file):
            m = rec.get("message") or {}
            if m.get("role") == "assistant":
                for c in (m.get("content") or []):
                    if isinstance(c, dict) and c.get("type") in ("toolCall", "tool_use") \
                            and c.get("name") in ("task", "subagent"):
                        calls[c.get("id")] = rec.get("timestamp") or ""
            elif m.get("role") == "toolResult":
                results.add(m.get("toolCallId"))
        if not calls:
            return None
        newest_id = max(calls.items(), key=lambda kv: kv[1])[0]
        return newest_id in results
    except Exception:
        return None


def told_but_silent(inbound_age, stale_s):
    """True when the lane was TOLD something AFTER it last produced output.

    ⛔ THIS IS THE **ACTION** SURFACE'S RULE, AND IT IS NOT `inbound_discounts_idle`. That one is
    the **CLAIM** surface's rule: a PRIOR, scoped to the IDLE family, never `WEDGED`, because an
    input event cannot prove a wedge resolved. This one is a **VETO** and it is verdict-INDEPENDENT:
    a lane that received work and has produced nothing since is not free capacity, whatever anyone
    believes about its state. A claim and an instruction are different speech acts.

    DELEGATED, WITH A LOCAL FALLBACK -- and the fallback is not redundancy.
    `LS_PATH` resolves to the DEPLOYED `~/.pi/agent/scripts/lane-status.py`, not to the copy beside
    this file, and the two are deployed INDEPENDENTLY. A hard `LS.told_but_silent(...)` therefore
    crashed the live beat with `AttributeError: module 'lane_status' has no attribute
    'told_but_silent'` as soon as this file landed ahead of its sibling (reproduced 2026-10-12).
    A triage instrument that cannot run is worse than one with a duplicated predicate, so the rule
    is stated here as well and the two are pinned equal by the check
    `the local fallback agrees with the canonical rule on every input` in `test_lane_actions.py`.
    (An earlier draft cited a test function name that does not exist -- the pin is an inline
    `check(...)` inside `main()`, not a `test_*` function, which is why the citation must name the
    check string.) The sibling is still preferred when present, so a future change to the canonical
    rule takes effect without touching this file.
    """
    if inbound_age is None or stale_s is None:
        return False
    return inbound_age < stale_s


def told_but_silent_via(LS):
    """`LS`'s own `told_but_silent` when the loaded module provides it, else the local fallback.

    Never raises: an older deployed sibling must degrade to the same rule, not to a traceback.
    """
    fn = getattr(LS, "told_but_silent", None)
    return fn if callable(fn) else told_but_silent


def classify_row(row, dead, files, LS):
    """Return a dict: step, verdict, why, action_class. Deterministic; no Jev here."""
    lane = row["lane"]
    sid = row.get("sid")
    r = {"lane": lane, "ws": row.get("ws") or "", "stale": row.get("stale_s"),
         # ── THE EVIDENCE `is_dispatch_target()` READS, CARRIED THROUGH VERBATIM ────────────────
         # `mech` is lane-status.py's OWN verdict (DONE-IDLE / WIP-IDLE / WEDGED / WORKING / …),
         # `last` is the kind of the last transcript record ("assistant" = a COMPLETED turn;
         # "tool" = a call whose turn has not finished), and `tool_in_flight` / `has_child` say
         # whether anything is running under this lane. They are copied, not re-derived: a second
         # derivation of the same fact is the two-answers defect this file already warns about.
         "mech": row.get("verdict"), "last": row.get("last"),
         "tool_in_flight": bool(row.get("tool")),
         "has_child": bool(row.get("child") or row.get("declared")
                           or row.get("pane_children")),
         "verdict": None, "step": None, "why": [], "action": None,
         # The INBOUND evidence is carried through so the BUCKET decision can consult it. It is not
         # used here: this function decides what the lane's state LOOKS like, and the bucket loop
         # decides whether a human may be told to ACT on it. Those are different questions and the
         # inbound prior answers only the second (see `told_but_silent`).
         "inbound_age": row.get("inbound_age"), "inbound_msg": row.get("inbound_msg")}

    # -- STEP 2 CPU-TIME DELTA -- PROVEN PROGRESS OUTRANKS THE BINDING (#1867) ----------------
    # ⛔ WHY THIS IS ASKED BEFORE STEP 0, WHEN THE TREE LISTS IDENTITY FIRST. Step 0 abstains when
    # the session id cannot be attributed to the lane; Step 2 answering TRUE means the lane's own
    # directory holds exactly one lane and at least one pi that consumed CPU in the sample window.
    # That evidence does not depend on which session file the pane was launched with, so a lane
    # PROVEN to be working must not be reported as an identity problem -- and, critically, must not
    # be free to fall through this file to the words layer, which is where the measured
    # `DONE_READY`-on-a-working-lane came from. It can only ever move a lane OUT of the action
    # lists (WORKING is not offered as work and prescribes no action).
    if row.get("cpu") is True:
        r.update(verdict="WORKING", step="2", action=None)
        r["why"].append("cumulative CPU time advanced by more than the stated %.2fs tolerance over "
                        "the sample window -- decisive on its own, whatever the session binding "
                        "says" % TOL_CPU_S)
        return r

    # -- STEP 0 identity ----------------------------------------------------------------
    if not sid:
        r.update(verdict="UNBOUND", step="0", action="report")
        r["why"].append("the pane advertises no session binding, so nothing below can be "
                        "attributed to this lane (NEVER dead, NEVER idle)")
        return r
    if row.get("_dup_sid"):
        r.update(verdict="AMBIGUOUS-IDENT", step="0", action="report")
        r["why"].append("session %s is claimed by %s -- neither panel's staleness or CPU reading "
                        "is demonstrably about this lane" % (sid[:8], ", ".join(row["_dup_sid"])))
        return r
    if row.get("session_verified") is False:
        # ⛔ THE SAME ABSTENTION AS `not sid`, ONE STEP LATER (2026-10-12). The row HAS an id, but
        # lane-status could not confirm it is the one being written -- so `stale_s`, the transcript
        # and the CPU reading below may all describe a DIFFERENT, dead session. MEASURED: two lanes
        # were bound to sessions last written 64h18m and 12h30m earlier and both rendered
        # `DONE-IDLE`; a `DONE-IDLE` here invites dispatching a lane that is already running work.
        r.update(verdict="UNVERIFIED-SESSION", step="0", action="report")
        r["why"].append("the session id under this lane could not be confirmed as the one being "
                        "written (no fresh write, no content match), so nothing below is "
                        "attributable to it (NEVER dead, NEVER idle)")
        return r

    # -- STEP 1 does the process exist? -------------------------------------------------
    if lane in dead:
        r.update(verdict="DEAD", step="1", action="wedged")
        r["why"].append("no live pi process for this lane's session dir (strict one-lane-one-process "
                        "attribution; transcript last written %s ago)" % _age(row.get("stale_s")))
        return r

    # -- STEP 2, continued: transcript GROWTH is the same family, but read off the BOUND file ----
    # (the CPU read that precedes identity is the binding-independent half -- #1867)
    if row.get("grew") is True:
        r.update(verdict="WORKING", step="2", action=None)
        r["why"].append("its transcript grew during the sample window")
        return r

    # -- STEP 3 is a child in flight? ---------------------------------------------------
    # An unmatched `task`/`subagent` tool call IS a child dispatch: it lives in THIS lane's own
    # transcript (so it is ATTRIBUTABLE -- unlike a cwd-guessed pid), and the harness's in-flight
    # bound applies to it. lane-status.py's `child` field only carries a child when a child SESSION
    # FILE was found, and past its own 30m ABANDON_S it drops the record as stale -- correct for a
    # file probe, WRONG for a dispatcher, because an unmatched dispatch is exactly the CHILD-OVERDUE
    # case the tree's Step 6 exists for.
    # MEASURED 2026-10-05: `4a Retrieval and traversal` dispatched `subagent([VGATE] verify files)`
    # 2h50m earlier and never got a result, while its last words (4h10m old) said the work was DONE
    # -- so the words layer returned DONE_READY(0.55) and would have re-tasked a lane stuck on a cut
    # child. This is the trap the tree names ("a lane inside a long tool call has a stale last
    # turn"); deterministic code settles it, and Jev never sees the question.
    disp = row.get("tool") or {}
    if disp.get("name") in ("task", "subagent"):
        age = disp.get("age") or 0
        tmo = disp.get("timeout")
        if not (tmo and age < tmo):
            if age > OVERDUE_S:
                # ⛔ Before calling this OVERDUE, disambiguate the two states that look identical
                # from a missing child: RETURNED vs UNMATCHED. Both leave no child transcript, so
                # the child test alone cannot tell them apart, and their actions are opposite.
                returned = dispatch_result(files.get(lane), LS)
                if returned is True:
                    # It RETURNED. Not overdue, not cut. Fall through to the rest of the tree
                    # (Step 3 child / Step 4 tool age / Step 5 words) on the lane's OWN evidence.
                    r["why"].append(
                        "the %s dispatch %s old RETURNED -- its `toolResult` is recorded in this "
                        "lane's own transcript, so it is NOT overdue and NOT cut; a returned "
                        "dispatch leaves no child behind either, which is why the child test "
                        "cannot see the difference" % (disp.get("name"), _age(age)))
                    row = dict(row)
                    row["tool"] = None      # do not re-read the settled dispatch in Step 4/5
                    # ⛔ AND CLEAR THE FLAG ALREADY CARRIED INTO `r` (review round 5, P3, MEASURED):
                    # `r["tool_in_flight"]` was copied from the row BEFORE this branch, so clearing
                    # only the local `row` left `dispatch_refusal()` printing "a tool call is in
                    # flight -- provisionally WORKING" directly under this branch's own "the
                    # dispatch RETURNED". The snapshot's cache can be minutes behind the transcript
                    # (TTL 420s, unbounded on the STALE-SNAPSHOT path), so the disagreement is the
                    # normal case, and it silently dropped an evidenced-idle lane from LIST 1.
                    r["tool_in_flight"] = False
                    # Recorded for `dispatch_refusal()`: the snapshot's `mech` may still say
                    # WAITING-OVERDUE, and this transcript fact is the DISPROOF (round 10, P2).
                    r["dispatch_returned"] = True
                else:
                    # STEP 6 RECURSION: the child, not the parent, decides whether quiet is
                    # correct. A child past the bound is frequently legitimate, and the parent's
                    # quiet is then CORRECT rather than a wedge.
                    ev, child_live = child_evidence(row)
                    if child_live:
                        r.update(verdict="WAITING_ON_CHILD", step="3", action=None)
                        r["why"].append(
                            "%s dispatch %s old, past the %dm bound, but a child IS demonstrably "
                            "in flight -- the parent's quiet is CORRECT, not a wedge"
                            % (disp.get("name"), _age(age), OVERDUE_S // 60))
                        r["why"] += ev
                        return r
                    # ⛔ NOT ACTIONABLE. CHILD-OVERDUE = the dispatch is UNMATCHED and no child
                    # is reachable to recurse into -- the classifier's own words are "we know the
                    # dispatch is UNMATCHED; we do NOT know it was cut". That is UNKNOWN, and
                    # unknown is not evidence of a stall. It was action="wedged", which made the
                    # beat's ONE actionable line read `WEDGED->1 unblock: 5&9 MCP and SDK surface`
                    # while that lane held a LIVE child (task in flight 89m): following it
                    # interrupts live work. A `task` child legitimately runs 35-65m (a merge rail
                    # measured 119m), so "past the ~20m bound" does not separate a stall from a
                    # long job. Same polarity as the child-count fix: SUPPRESS over mislabel. The
                    # EVIDENCE is kept -- the lane still appears, in REPORT-ONLY, with its why.
                    r.update(verdict="CHILD-OVERDUE", step="6", action=None)
                    r["why"].append(
                        "an UNMATCHED %s dispatch is %s old, past the %dm harness in-flight "
                        "bound: no result is recorded for its call id and no child is reachable "
                        "to recurse into. We know the dispatch is UNMATCHED -- we do NOT know it "
                        "was cut; nothing readable from here can see a cut"
                        % (disp.get("name"), _age(age), OVERDUE_S // 60))
                    if ev:
                        r["why"] += ev
                    else:
                        r["why"].append(
                            "no child signal is readable from here (no pane child line, no child "
                            "session file, no declared process) -- reporting the THIRD possibility "
                            "is not open to us: a returned dispatch would have shown a result")
                    return r
            else:
                r.update(verdict="WAITING_ON_CHILD", step="3", action=None)
                r["why"].append("%s dispatch in flight %s, inside the %dm harness bound -- quiet "
                                "here is CORRECT"
                                % (disp.get("name"), _age(age), OVERDUE_S // 60))
                return r

    ev, child_live = child_evidence(row)
    has_child = bool(row.get("child") or row.get("declared") or row.get("pane_children"))
    if has_child:
        overdue = (row.get("verdict") in ("CHILD-OVERDUE", "CHILD-STUCK")) or not child_live
        if child_live:
            r.update(verdict="WAITING_ON_CHILD", step="3", action=None)
            r["why"] += ev
            return r
        if row.get("verdict") in ("WAITING-CHILD", "CHILD-OVERDUE", "CHILD-STUCK"):
            # STEP 6: recursion. The parent's quiet is CORRECT only while the child is alive;
            # with no evidence of life it is a real candidate -- but a child past the ~20m bound is
            # FREQUENTLY legitimate (measured: a 119m merge rail, a 35-65m deploy).
            #
            # ⛔ DO NOT COLLAPSE CHILD-STUCK INTO CHILD-OVERDUE, and do not make EITHER actionable
            # from this branch. `child_live` is False here BY CONSTRUCTION (the branch above returns
            # whenever it is True), so the original ternary always yielded CHILD-OVERDUE and always
            # set action="wedged" -- every "a child signal exists but nothing about it is readable"
            # became an ACTION, which is why `5&9` was advertised for an unblock while its child was
            # live. The two verdicts are not interchangeable: CHILD-STUCK means a child transcript
            # EXISTS and went quiet past the bound (evidence, so it stays a candidate -- still
            # "confirm before acting", never reap on it alone), while CHILD-OVERDUE means no child is
            # reachable at all (unknown, so it is report-only and NOT an action). Distinguishing them
            # is the entire reason there are two verdicts.
            _row_v = row.get("verdict")
            r.update(verdict=("CHILD-STUCK" if _row_v == "CHILD-STUCK" else "CHILD-OVERDUE"),
                     step="6",
                     # CHILD-STUCK KEEPS its place in the unblock list: its transcript EXISTS and went
                     # quiet past the bound, which is evidence (still "confirm before acting", never
                     # reap on it alone). CHILD-OVERDUE prescribes NO action -- it is an unknown, and
                     # the bucket loop below sends it to REPORT-ONLY rather than the unblock list.
                     action=("wedged" if _row_v == "CHILD-STUCK" else None))
            r["why"] += ev or ["a child is in flight but nothing about it can be read from here"]
            # THE ROW'S VERDICT IS A SUSPICION, AND THE EVIDENCE JUST PRINTED CAN CONTRADICT IT.
            # MEASURED 2026-10-05: `tortoise-sweep` carried verdict CHILD-OVERDUE from the scan
            # while every readable child signal was 40s old. Repeating "past the 25m bound" as a
            # fact next to "child dispatched 40s ago" gives an unblocker two flat contradictions
            # and no way to choose -- so when the readable signal sits INSIDE the bound, say that it
            # is the RECORD that is overdue and mark it for re-measurement instead.
            ages = []
            if (row.get("child") or {}).get("age") is not None:
                ages.append(row["child"]["age"])
            if row.get("child_stale") is not None:
                ages.append(row["child_stale"])
            for k in (row.get("pane_children") or []):
                if k.get("age") is not None:
                    ages.append(k["age"])
            youngest = min(ages) if ages else None
            if youngest is not None and youngest < OVERDUE_S:
                r["why"].append(
                    "lane-status recorded %s at scan time, but the youngest child signal readable "
                    "from here is %s old -- inside the %dm bound. The RECORD is what is overdue, "
                    "not the child: re-measure before unblocking."
                    % (row.get("verdict"), _age(youngest), OVERDUE_S // 60))
            else:
                r["why"].append("child past the %dm harness bound with no evidence of life on any "
                                "signal -- a long merge rail or deploy looks identical from here"
                                % (OVERDUE_S // 60))
            return r

    # -- STEP 4 how recent was the last tool call? --------------------------------------
    tool = row.get("tool") or {}
    if tool:
        age = tool.get("age")
        tmo = tool.get("timeout")
        if age is not None and tmo and age < tmo:
            r.update(verdict="TOOL-IN-FLIGHT", step="4", action=None)
            r["why"].append("%s in flight %s, inside its OWN declared budget of %ss"
                            % (tool.get("name"), _age(age), tmo))
            return r
        if age is not None and age < COLD_MIN:
            r.update(verdict="TOOL-IN-FLIGHT", step="4", action=None)
            r["why"].append("%s in flight %s (< %dm) -- provisional WORKING, re-check next tick"
                            % (tool.get("name"), _age(age), COLD_MIN // 60))
            return r

    stale = row.get("stale_s")
    if stale is not None and stale < COLD_MIN:
        r.update(verdict="TOOL-IN-FLIGHT", step="4", action=None)
        r["why"].append("last output %s ago (< %dm)" % (_age(stale), COLD_MIN // 60))
        return r

    # -- STEP 2 SAW PROGRESS BUT COULD NOT NAME THE PID (#1867) ---------------------------
    # ⛔ THIS IS THE BRANCH THE MEASURED FALSE CAPACITY WENT THROUGH. A lane with a `task` CHILD pi
    # in the same directory has TWO pids on one cwd, so the strict read above answers None -- and
    # every step below then judged a lane that was consuming CPU by its transcript mtime. MEASURED
    # 2026-10-16 20:47Z: `cmux cloud` -> `DONE_READY, no session write for 13h34m`, published to the
    # beat as `CAPACITY: 1 lane(s) idle >=20m -- hand each the next unheld item`, while its CPU time
    # moved +4.93s in 25s and its pane showed an active spinner. Following that line would have
    # injected a second work order into a lane at 85% context, mid-turn.
    #
    # So: IDLE IS REACHABLE ONLY THROUGH STEP 2. Positive progress in this lane's own directory
    # makes the idle family UNREACHABLE BY CONSTRUCTION -- not "less likely", not "weighted" --
    # whatever the binding resolved to and whatever the mtime says. The lane is REPORTED, because a
    # reader needs to see it, and prescribes nothing, because which pid was working cannot be said
    # from here. `WORKING` is deliberately NOT used: that would short-circuit a real WEDGED or
    # CHILD-STUCK verdict on a lane whose child is spinning under a stalled parent.
    if row.get("cpu_any") is True:
        r.update(verdict="UNATTRIBUTED-WORKING", step="2", action="report")
        r["why"].append("a pi in this lane's own directory consumed CPU during the sample window, "
                        "so this lane is NOT free capacity -- but more than one pi runs in that "
                        "directory (typically the lane plus a live `task` child), so which one was "
                        "working cannot be attributed. Reported only: no dispatch, no unblock")
        return r

    # -- STEP 5 the only step that yields meaning: read what it actually said -----------
    r.update(verdict="STEP5", step="5", action="words")
    if tool:
        r["why"].append("%s in flight %s with no declared budget" % (tool.get("name"), _age(tool.get("age"))))
    if row.get("verdict") in ("DONE-IDLE", "WIP-IDLE"):
        r["why"].append("no session write for %s, no spinner contradiction" % _age(stale))
    elif row.get("verdict") == "WEDGED":
        r["why"].append("no session write for %s with a spinner on screen -- two flat samples "
                        "cannot distinguish a wedge from a long tool call, so its words decide"
                        % _age(stale))
    else:
        r["why"].append("mechanical verdict %s at %s quiet" % (row.get("verdict"), _age(stale)))
    return r


# ── STEP 5: ONE batched Jev call for the whole fleet's words layer ────────────────────────
STEP5_OUTCOMES = ("CONTINUE", "BLOCKED_EXTERNAL", "BLOCKED_HUMAN", "DONE_READY", "STALLED",
                  "CONTEXT-MISBELIEF")

# ⛔ AN ACTION IS A CLAIM ABOUT THE LANE, AND A CLAIM NEEDS CONFIDENCE. `conf` was carried all the
# way from the model (`:690`) to the report and GATED NOWHERE -- `:1130` only formats it. So the
# label alone decided, and a coin-flip carried exactly the weight of a certainty.
CONF_MIN = 0.7

# The labels that may become an INSTRUCTION. `BLOCKED_HUMAN` (waiting on the owner) and
# `BLOCKED_EXTERNAL` (CI / rail / another lane) are absent deliberately: neither is work the lane
# should be told to resume, and one is a live conversation.
OFFERABLE = ("DONE_READY", "CONTINUE", "CONTEXT-MISBELIEF", "STALLED", "DEAD", "CHILD-OVERDUE")

# ⛔ THE CONFIDENCE FLOOR APPLIES TO THE WORDS LAYER ONLY -- NOT TO EVERY `OFFERABLE` LABEL.
# `conf` is produced by the Step-5 Jev call and exists for NO other step, while `DEAD` (Step 1, the
# process is not alive) and `CHILD-OVERDUE` (Step 6, the child record's age) are MECHANICAL: their
# evidence is the process table and the child record, and neither carries -- or needs -- a
# confidence. Applying the floor to them was a reproduced crash: `c["conf"]` raised `KeyError`,
# and because `main()` calls `build()` unguarded, ONE such lane aborted the entire fleet
# classification and wrote no verdict file at all. A gate that cannot read its input must not
# silently stop classifying the fleet.
WORDS_LABELS = frozenset(STEP5_OUTCOMES)


def offerable(v, conf):
    """Whether `v` may become an INSTRUCTION to a lane at this confidence.

    ⛔ MEASURED 2026-10-12, `NEEDS-ACTION.md:27`:

        - 3 Onboarding [CONTINUE 0.44] (2h58m)
            - WHY: last words said -55s ago | no session write for 2h58m, no spinner contradiction

    A 44%-confident label, on a lane that had written nothing for ~3h, became `say CONTINUE, not a
    new task`. The classifier was not missing and the resolution table was not wrong -- the label was
    simply allowed to act on its own. This is the one place that decides, so the rule cannot be
    bypassed by a later branch.

    `BLOCKED_HUMAN` is never offerable whatever its confidence: a lane waiting on the OWNER must not
    be told to continue -- that is the conversation, and typing into it corrupts the thing the lane
    is for. It is absent from `OFFERABLE` for exactly that reason.

    UNKNOWN CONFIDENCE IS NOT HIGH CONFIDENCE (fail closed): `None` is refused rather than treated as
    "no objection", the same polarity as every other unclear read in this fleet. But that rule is for
    the WORDS LAYER -- a mechanical label carries no confidence to be unknown.
    """
    if v not in OFFERABLE:
        return False
    if v not in WORDS_LABELS:
        # Mechanical verdict (DEAD / CHILD-OVERDUE): no confidence is carried and none is required.
        return True
    if conf is None:
        return False
    return conf >= CONF_MIN


# ── THE DISPATCH TARGET: EVIDENCED IDLE, per the decision tree's resolution order ──────────
# ⛔ THIS REPLACES A BARE "QUIET" TEST WITH THE TREE'S OWN VERDICT (owner, 2026-10-20):
# "we use a decision tree that was designed to know what lane has WIP and which not". The tree
# (`state/LANE-STATE-DECISION-TREE.md`) resolves a lane identity -> CPU delta -> child in flight ->
# tool age -> words, and only ONE of those outcomes means free capacity. Its "resolution order for a
# dispatcher" is implemented here as a PREDICATE rather than re-derived per caller, so every
# consumer of LIST 1 (`res["dispatch_targets"]`) gets the same answer to the same question.
#
# Only a lane that is ALL of the following is a dispatch target:
#   * FLEET              -- demonstrably ours (Step 0; see `lane_identity()`), never the owner's;
#   * not already nudged -- BUSY means the auto-nudger already spoke this hour;
#   * DONE-IDLE          -- lane-status.py's own verdict for "finished and holding nothing";
#   * a COMPLETED turn   -- `last == "assistant"`; a trailing tool call is a turn still in progress,
#                          whose quiet is the harness's in-flight bound, not idleness;
#   * no child in flight -- `CHILD-*` / `WAITING-CHILD` mean a dispatch here duplicates live work;
#   * no tool in flight  -- `TOOL-IN-FLIGHT` is provisional WORKING and re-measures next tick;
#   * step 5 + confident DONE_READY -- the words layer must actually say it is finished, at or above
#                          `CONF_MIN`. An UNREAD words layer (Jev down) is never "free".
# WORKING / TOOL-IN-FLIGHT / CHILD-* / UNBOUND / WEDGED fail at least one clause, so they can never
# be offered as capacity however quiet they look.
IDLE_MECH = ("DONE-IDLE",)     # lane-status.py's vocabulary; see its `DONE_IDLE` constant


def dispatch_refusal(c):
    """WHY this row is not a dispatch target, or "" when it is one.

    A refusal that cannot name its evidence is indistinguishable from a bug, so every negative is
    returned as a sentence the report prints next to the lane.
    """
    if c.get("protected") or c.get("identity") == "OWNER":
        return c.get("identity_why") or "not a demonstrable fleet lane -- the owner's workspace"
    if c.get("busy"):
        return "already auto-nudged this hour (result SENT/QUEUED)"
    mech = c.get("mech")
    # ⛔ A VERDICT THE TRANSCRIPT HAS DISPROVED IS NOT A REFUSAL (review round 10, P2, MEASURED).
    # `mech` is the SNAPSHOT's verdict; on the state that actually occurs -- an unmatched `task` call
    # older than 600s with no spinner -- lane-status says `WAITING-OVERDUE`, while this file reads the
    # SAME transcript, finds the `toolResult`, takes the RETURNED branch and prints "the dispatch
    # RETURNED -- NOT overdue". Refusing on `mech` anyway printed two contradictory sentences about
    # one lane and kept an evidenced-idle lane out of LIST 1 until the snapshot refreshed (which is
    # unbounded on the STALE-SNAPSHOT path). `dispatch_returned` is the DISPROOF, recorded where it
    # was established; every other clause below still applies.
    if mech not in IDLE_MECH and not c.get("dispatch_returned"):
        return ("mechanical verdict %s is not DONE-IDLE -- WORKING / TOOL-IN-FLIGHT / CHILD-* / "
                "UNBOUND / WEDGED are not free capacity" % (mech or "UNREAD"))
    # ⛔ THE MACHINE OUTRANKS THE WORDS, AND `step` IS WHERE IT STOPPED (the tree's own order):
    # 0 identity, 1 process, 2 CPU delta, 3 child, 4 tool age, 6 child recursion. Only 5 means
    # "nothing is in flight and the lane is quiet enough for its words to be worth reading".
    if c.get("step") != "5":
        return ("the decision tree stopped it at step %s (%s) -- WORKING / TOOL-IN-FLIGHT / "
                "CHILD-* / UNBOUND / WEDGED are never free capacity"
                % (c.get("step") or "?", c.get("verdict") or "UNREAD"))
    if c.get("last") != "assistant":
        return ("its last transcript record is %s, so the turn did not COMPLETE -- a quiet lane "
                "mid-turn is working, not idle" % (c.get("last") or "UNREAD"))
    if c.get("has_child"):
        return "a child is in flight -- dispatching here duplicates live work"
    if c.get("tool_in_flight"):
        return "a tool call is in flight -- provisionally WORKING, re-measure next tick"
    v = c.get("verdict")
    if v != "DONE_READY":
        return ("the words layer did not say it is finished (%s) -- an unread or unsure word "
                "layer is never free capacity" % (v or "UNREAD"))
    if not offerable(v, c.get("conf")):
        return ("DONE_READY at %s confidence (needs >= %.2f) -- the words layer is guessing"
                % ("%.2f" % c["conf"] if c.get("conf") is not None else "no", CONF_MIN))
    return ""


def is_dispatch_target(c):
    """True ONLY for EVIDENCED idle: see the clause list above `dispatch_refusal()`."""
    return dispatch_refusal(c) == ""

CONTEXT_CRITERION = (
    "Its last words say it is running out of context / must stop / must hand off to preserve room. "
    "THIS IS NOT A STATE AND THE BELIEF IS FALSE: this harness AUTO-COMPACTS, so context is not a "
    "reason to stop and stopping throws away work for nothing. Choose this only for that belief; "
    "the action is to tell it plainly to CONTINUE the task in hand, NOT to give it a handoff brief "
    "and NOT to treat it as done."
)

STEP5_INSTRUCTIONS = (
    "This state describes ONE coding-agent lane that is QUIET RIGHT NOW: it is not consuming CPU "
    "time, it has no live child in flight, and its last output is older than two minutes. Read its "
    "own last words and decide ONE outcome. The single most important distinction is that IDLE IS "
    "NOT ONE STATE: a lane whose last words name a next step is CONTINUE (mid-task -- it must be "
    "told to continue, NOT given a new task, and NOT counted as capacity); one waiting on CI / the "
    "merge rail / a queue / another lane's PR is BLOCKED_EXTERNAL (report only); one that cannot "
    "advance without a decision only the OWNER can make is BLOCKED_HUMAN (route it to the owner -- "
    "repeating the work will not help); and one that reported a finished result with nothing held "
    "is DONE_READY (hand it the next item for its lane). Reserve STALLED for a lane whose words "
    "name no next step, await nothing external, and report no finished result. The last words are "
    "the strongest evidence available; a spinner or a quiet transcript is not."
)


def jev_step5(rows, LV, enabled=True):
    """(answers {lane: (choice, conf)}, meta). One call, one `choice` question per lane."""
    meta = {"source": "JEV", "model": None, "usage": None, "error": None, "asked": len(rows)}
    if not rows:
        return {}, dict(meta, source="none")
    if not enabled:
        return {}, dict(meta, source="OFF", error="--no-jev")
    if LV is None:
        return {}, dict(meta, source="RULE", error="lane-verdict.py not importable (no key loader)")
    key = None
    try:
        key = LV.jev_key()
    except Exception:
        key = None
    if not key:
        # The key lives in the 0600 config file or the TYPESAFE_API_KEY / JEV_API_KEY
        # env names (lane-verdict.py's loader decides). Never printed, never logged.
        return {}, dict(meta, source="RULE", error="no TypeSafe key "
                        "(env TYPESAFE_API_KEY / JEV_API_KEY, or ~/.pi/agent/jev-config.json)")

    base = dict(getattr(LV, "CRITERIA", None) or {})
    criteria = {}
    for k in STEP5_OUTCOMES:
        criteria[k] = base.get(k) or CONTEXT_CRITERION
    criteria["CONTEXT-MISBELIEF"] = CONTEXT_CRITERION

    state = ["FLEET WORDS LAYER -- %d lane(s) reached Step 5 of the decision tree." % len(rows),
             "Each lane below is NOT consuming CPU, has NO live child, and is past 2 minutes quiet.",
             ""]
    questions = {}
    for i, r in enumerate(rows):
        qk = "lane_%02d" % i
        lm = r.get("last_message") or "(no assistant text found in the bounded window)"
        said = ("said %s ago" % _age(r.get("said_age"))) if r.get("said_age") is not None \
            else "age unknown"
        state += ["LANE %r" % r["lane"],
                  "  quiet_for=%s  spinner=%s  in_flight_tool=%s"
                  % (_age(r.get("stale")), r.get("spinner"), r.get("tool_desc") or "none"),
                  "  LAST_WORDS (%s): %s" % (said, _clip(lm, 600)),
                  ""]
        questions[qk] = {
            "type": "choice",
            "instructions": "Judge LANE %r specifically. %s" % (r["lane"], STEP5_INSTRUCTIONS),
            "criteria": criteria,
        }
    req = urllib.request.Request(
        LV.JEV_URL,
        data=json.dumps({"model": LV.JEV_MODEL, "state": "\n".join(state),
                         "questions": questions}).encode(),
        headers={"Authorization": "Bearer %s" % key, "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=90) as resp:
            d = json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        return {}, dict(meta, source="RULE", error="jev http %s: %s"
                        % (e.code, e.read().decode()[:200]))
    except Exception as e:                                            # noqa: BLE001
        return {}, dict(meta, source="RULE", error="jev call failed: %s" % e)
    answers = d.get("answers") or {}
    out = {}
    for i, r in enumerate(rows):
        a = answers.get("lane_%02d" % i) or {}
        if a.get("type") == "choice" and a.get("choice") in STEP5_OUTCOMES:
            out[r["lane"]] = (a["choice"], a.get("confidence"))
    meta["model"] = d.get("model")
    meta["usage"] = d.get("usage")
    meta["answered"] = len(out)
    if len(out) < len(rows):
        meta["error"] = "jev answered %d of %d" % (len(out), len(rows))
    return out, meta


# ── assembly ─────────────────────────────────────────────────────────────────────────────
def _wide_last_text(path, LS, ref, budget_bytes=2_000_000, max_lines=6000):
    """Last assistant text in a wider bounded window, when the 300KB tail held none.

    MEASURED 2026-10-05: `5&9 MCP and SDK surface` had been tool-calling long enough that its last
    300KB of transcript (44 records) contained NO assistant text at all -- so the lane's words, the
    only thing that can explain it, were outside the window. The widened read is still bounded (2MB
    and 6000 lines) and still uses lane-status.py DESCRIBE to parse a record, so there is one
    parser. Reached only for a lane whose narrow window came back empty.
    """
    try:
        sz = os.path.getsize(path)
        with open(path, "rb") as fh:
            fh.seek(max(0, sz - budget_bytes))
            chunk = fh.read().decode("utf-8", "ignore")
    except OSError:
        return "", None
    n = 0
    for line in reversed([l for l in chunk.split("\n") if l.strip()]):
        n += 1
        if n > max_lines:
            break
        try:
            rec = json.loads(line)
        except Exception:
            continue
        m = rec.get("message") or {}
        if m.get("role") != "assistant":
            continue
        kind, txt = LS.describe(rec)
        if kind == "assistant" and txt:
            age = None
            try:
                e = LS.ts_epoch(rec.get("timestamp") or "")
                age = int(ref - e) if e else None
            except Exception:
                age = None
            return _clip(txt, LAST_MSG_CHARS), age
    return "", None


def _last_message(lane, files, LS, ref):
    """(last assistant TEXT, its age in seconds).

    The tree's Step 5 reads "the lane's last assistant message AND its last tool call". They are two
    different records, and the window has to be wide enough to find the first: MEASURED 2026-10-05,
    three lanes (`1 Capture write doors`, `5&9 MCP and SDK surface`, `4a Retrieval and traversal`)
    had SIXTEEN consecutive records with no assistant text at all -- a pure tool loop -- so a
    16-record window reported "no message" for lanes whose last words were the only thing that
    explained them. The read stays bounded (lane-status.tail caps the file window at 300KB) and the
    age is returned WITH the text so a stale last turn cannot be mistaken for current intent.
    """
    p = files.get(lane)
    if p and LS is not None:
        try:
            for rec in reversed(LS.tail(p, 200)):
                m = rec.get("message") or {}
                if m.get("role") != "assistant":
                    continue
                kind, txt = LS.describe(rec)
                if kind == "assistant" and txt:
                    age = None
                    try:
                        e = LS.ts_epoch(rec.get("timestamp") or "")
                        age = int(ref - e) if e else None
                    except Exception:
                        age = None
                    return _clip(txt, LAST_MSG_CHARS), age
        except Exception:
            pass
    if p and LS is not None:
        return _wide_last_text(p, LS, ref)          # wider window, same parser
    return "", None


def _tool_desc(row):
    t = row.get("tool") or {}
    if not t:
        return ""
    d = "%s in flight %s" % (t.get("name"), _age(t.get("age")))
    if t.get("timeout"):
        d += " (declared %ss)" % t["timeout"]
    return d


# The ONLY failures that may fail `live_workspaces()` open. Evaluated ONCE, at import, so a
# monkeypatched test double can never change which errors are swallowed -- and so a programming error
# (NameError / AttributeError / TypeError) always PROPAGATES instead of reading as "cmux unreadable".
# The first version of this function caught bare `Exception` and hid exactly that bug: a NameError
# made the live set empty and turned this filter into a silent no-op that looked like it worked.
_SUBPROC_ERRORS = (OSError, ValueError, subprocess.SubprocessError)

# ⛔ cmux MUST BE RESOLVED BY ABSOLUTE PATH. The beat runs under launchd, whose job has no
# `EnvironmentVariables` block, so it inherits the default PATH `/usr/gnu/bin:/usr/local/bin:/bin:
# /usr/bin:.` -- and cmux is NOT on it (it lives in /Applications/cmux.app/Contents/Resources/bin/).
# A bare `subprocess.run(["cmux", ...])` therefore raises FileNotFoundError, which the fail-open
# polarity correctly treats as "cmux unreadable" -- so the whole workspace-existence filter silently
# did NOTHING in production while passing its tests and working in an interactive shell. Measured
# 2026-10-09: the beat kept emitting `IDLE->11 ... NEEDS-OWNER->2c Pack compile` while the same code
# run by hand emitted `IDLE->7`, which is how the bug was caught.
CMUX_CANDIDATES = (
    "/Applications/cmux.app/Contents/Resources/bin/cmux",
    "/usr/local/bin/cmux",
    "/opt/homebrew/bin/cmux",
    os.path.expanduser("~/bin/cmux"),
)


# ⛔ THE BEAT CANNOT QUERY cmux AT ALL. MEASURED 2026-10-09 from a real launchd context:
# `cmux workspace list` exits 1 with EMPTY stdout and
#   "ERROR: Access denied - only processes started inside cmux can connect".
# Only processes started INSIDE cmux (any lane's pi, or the orchestrator) can query it. TWO earlier
# "fixes" of this filter were verified WRONG for exactly this reason: an interactive shell and an
# `env -i` shell BOTH sit inside cmux, so both reported 22 workspaces while the beat saw none.
# The shell you test from cannot tell you what launchd sees.
# THEREFORE the primary source is a PUBLISHED file that any cmux-resident process can write; cmux is
# only a fallback. When BOTH are unavailable the failure is reported LOUDLY, because an inert filter
# that looks like a working one is precisely the hazard this function exists to remove.
LIVE_WS_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), os.pardir,
                            "state", "live-workspaces.txt")
LIVE_WS_MAX_AGE_S = 900   # a published list older than this is not evidence about the live fleet


def cmux_bin():
    """An ABSOLUTE path to cmux, falling back to a PATH lookup only as a last resort."""
    for p in CMUX_CANDIDATES:
        if os.path.isfile(p) and os.access(p, os.X_OK):
            return p
    return "cmux"


def live_workspaces():
    """{UPPERCASED UUID: current cmux workspace TITLE} for the workspaces that exist now.

    An EMPTY return means the list could not be read, and callers MUST treat empty as "do not
    filter" -- a failed read must never silently drop a live lane.

    \u26d4 THE TITLE IS LOAD-BEARING, NOT DECORATION (2026-10-10, #7957 H4). A workspace UUID
    OUTLIVES the NAME it was created for, so **UUID existence does not prove the lane exists.**
    Measured 2026-10-10: three of the six lanes the beat offered as IDLE had a live UUID under a
    DIFFERENT title -- `land-6260` was `P1 data-loss`, `Merigng PR` was `PR 2`,
    `\u03c0 - land-lane-1` was `5285 Decision`. A caller that only tests membership therefore offers
    dead lanes as work, and a dispatch is spent on a lane that is not there.

    A title of "" means **UNKNOWN** (a legacy UUID-only published list) and callers MUST NOT filter
    on it -- only a KNOWN, DIFFERING title proves the lane is gone.
    """
    # Source 1 -- the PUBLISHED list. Any process INSIDE cmux can write it (the beat cannot query
    # cmux, so it must not depend on cmux being reachable from launchd).
    reasons = []
    try:
        age = time.time() - os.path.getmtime(LIVE_WS_FILE)
        if age <= LIVE_WS_MAX_AGE_S:
            ids = {}
            with open(LIVE_WS_FILE) as fh:
                for line in fh:
                    line = line.rstrip("\n")
                    if not line.strip() or line.lstrip().startswith("#"):
                        continue
                    # New format is `UUID<TAB>title`. A legacy UUID-only line is still accepted but
                    # yields title "" == UNKNOWN, which the filter refuses to act on.
                    if "\t" in line:
                        uid, _, title = line.partition("\t")
                    else:
                        # Legacy line: `UUID` optionally followed by a whitespace-separated title.
                        parts = line.split(None, 1)
                        uid = parts[0] if parts else ""
                        title = parts[1] if len(parts) > 1 else ""
                    uid = uid.strip().upper()
                    if uid:
                        ids[uid] = title.strip()
            if ids:
                return ids
            reasons.append("published list is empty")
        else:
            reasons.append("published list is %dm old (>%dm)"
                           % (age / 60, LIVE_WS_MAX_AGE_S / 60))
    except OSError:
        reasons.append("no published list at %s" % LIVE_WS_FILE)

    # Source 2 -- cmux directly. Works ONLY when this process is inside cmux.
    # ⛔ CATCH ONLY I/O FAILURES. A blanket `except Exception` here silently converted a NameError
    # (subprocess was imported INSIDE main(), so it was undefined at module scope) into "cmux is
    # unreadable" -- and this filter became a silent NO-OP that returned 0 workspaces while looking
    # like it worked. A programming error must raise loudly; only a genuinely unreadable cmux may
    # fail open. The first version of this function had exactly that bug.
    try:
        p = subprocess.run([cmux_bin(), "workspace", "list", "--json", "--id-format", "both"],
                           capture_output=True, text=True, timeout=20)
        if p.returncode != 0 or not (p.stdout or "").strip():
            # ⛔ rc != 0 OR empty stdout is a FAILURE, not "no workspaces". MEASURED 2026-10-09 from a
            # real launchd context: `cmux workspace list` exits 1 with EMPTY stdout and stderr
            # "ERROR: Access denied - only processes started inside cmux can connect". The empty
            # stdout parsed as `{}` -> no workspaces -> `set()`, so this returned WITHOUT RAISING, the
            # `except` below never ran, and the filter silently did NOTHING in the beat while working
            # in every shell started INSIDE cmux. That produced two rounds of false "verified"
            # (an interactive run and an `env -i` run -- neither reproduces launchd's session, so
            # neither could show it). LOUD from now on: an inert filter must never look like a working
            # one, because the whole point of this function is to stop wrong dispatch instructions.
            reasons.append("cmux rc=%s with %d bytes stdout: %r"
                           % (p.returncode, len(p.stdout or ""), (p.stderr or "").strip()[:120]))
            p = None
        if p is None:
            raise OSError("; ".join(reasons))
        d = json.loads(p.stdout)
        ws = d if isinstance(d, list) else d.get("workspaces", [])
        return {(w.get("id") or "").strip().upper(): (w.get("title") or "").strip()
                for w in ws if w.get("id")}
    except _SUBPROC_ERRORS as e:
        sys.stderr.write(
            "live_workspaces: UNREADABLE -- the workspace-existence filter is INERT this run. "
            "Publish %s from a process INSIDE cmux. (%s)\n" % (LIVE_WS_FILE, e))
        return {}


def build(rows, LS, LV, use_jev=True, ref=None, live=None, spawn_markers=None):
    ref = ref or time.time()          # the SNAPSHOT's clock, so ages agree with stale_s and a
                                     # re-run of the same snapshot is byte-identical
    # ⛔ READ THE SPAWN MARKERS ONCE PER BUILD, not once per lane: they are one directory of small
    # files, but 30 lanes x glob is 30 wasted walks. An empty set is the NORMAL case and simply
    # means no lane's identity is demonstrable through a spawn record -- the worktree-shape test
    # still decides.
    markers = _spawn_marker_worktrees() if spawn_markers is None else set(spawn_markers)
    labels = _registry_labels()
    dup = {}
    for r in rows:
        if r.get("sid"):
            dup.setdefault(r["sid"], []).append(r["lane"])
    for r in rows:
        sib = [x for x in dup.get(r.get("sid") or "", []) if x != r["lane"]]
        r["_dup_sid"] = sib

    dead, files, procmap_note = dead_lanes(rows, LS) if LS is not None else (set(), {}, "lane-status.py not importable")
    busy = _busy_sids()

    classified = []
    for r in rows:
        c = classify_row(r, dead, files, LS)
        # ── IDENTITY, FROM EVIDENCE (Step 0) ────────────────────────────────────────────────
        # ⛔ NO NAME LIST DECIDES THIS ANY MORE. See the comment block above
        # `_is_fleet_worktree()`: the owner's "Personal website" workspace was not in
        # `("DMeer", "DMer", "HANG")`, so it was classified as an idle fleet lane and the PR
        # doctor dispatched a tortoise PR brief into it -- twice. The legacy names are kept as an
        # additional UNION only, so they can still add protection but never be the mechanism.
        ident, ident_why = lane_identity(r, markers)
        c["identity"], c["identity_why"], c["cwd"] = ident, ident_why, lane_cwd(r)
        legacy = _legacy_name_hit(c["lane"])
        # The DECLARED list (`state/owner-workspaces.txt`, from `main`) is the second union member.
        # Matched by SUBSTRING on the title, deliberately: the owner writes whole titles there
        # ("Personal website"), and for "may I type into this?" a wider match is the safe direction.
        declared = _declared_owner_hit(c["lane"])
        c["protected"] = (ident != "FLEET") or legacy or declared
        if legacy and ident == "FLEET":
            c["identity_why"] = ("%s; also matched a historical owner lane name (%s) -- the name "
                                 "list is an ADDITIONAL union, not the mechanism"
                                 % (ident_why, "/".join(PROTECTED_LEGACY_NAMES)))
        elif declared and ident == "FLEET":
            c["identity_why"] = ("%s; also DECLARED as the owner's in %s -- a union member, never "
                                 "the mechanism" % (ident_why, display_path(_OWNER_WS_FILE)))
        c["busy"] = bool(r.get("sid") and r["sid"] in busy)
        # Messages are read ONLY where they can change an outcome: a lane proven WORKING by CPU
        # time, or waiting on a live child, or inside a declarable tool budget needs no report at
        # all, and reading 30 session tails to print none of them is cost without evidence.
        if c["step"] in ("5", "1", "6"):
            c["last_message"], c["said_age"] = _last_message(c["lane"], files, LS, ref)
        else:
            c["last_message"], c["said_age"] = "", None
        c["spinner"] = bool(r.get("spinner"))
        c["tool_desc"] = _tool_desc(r)
        c["issue_label"] = r.get("issue_label") or ""
        classified.append(c)

    # STEP 5 -- only the lanes that reached it, in ONE batched call. PROTECTED lanes are excluded
    # from the call itself, not just from the lists: they are the OWNER's own work (anything not
    # demonstrably a fleet lane -- Step 0) and their text does not belong in a third-party API
    # request for a fleet triage.
    step5 = [c for c in classified if c["step"] == "5" and not c["protected"]]
    step5.sort(key=lambda c: -(c["stale"] or 0))
    answers, meta = jev_step5(step5, LV, enabled=use_jev)
    jev_down = bool(step5) and not answers and meta.get("source") not in ("none",)
    for c in classified:
        if c["step"] != "5":
            continue
        got = answers.get(c["lane"])
        if got:
            c["verdict"], c["conf"] = got
            c["step"] = "5"
        elif c["protected"]:
            c["verdict"], c["conf"] = "PROTECTED", None
            # ⛔ NO `identity_why` HERE. The bucket loop puts the EVIDENCE sentence first on every
            # protected entry; repeating it here printed the same clause twice in one WHY line.
            # This one says only what happened to the row: its words were not read.
            c["why"].append("its words are not read here -- an owner workspace is never offered "
                            "as work")
        else:
            c["verdict"] = "UNCLASSIFIED"
            c["conf"] = None
            c["why"].append("words layer UNREAD (Jev: %s) -- reported, never guessed into an action"
                            % (meta.get("error") or meta.get("source")))

    # -- buckets. The tree's resolution table, applied verbatim ---------------------------
    idle, wip, wedged, report, quiet = [], [], [], [], []
    for c in classified:
        v = c["verdict"]        # Steps 2-4 resolved the lane to a NO-ACTION verdict (WORKING / WAITING_ON_CHILD /
        # TOOL-IN-FLIGHT). It needs neither an action nor a report, so it appears in neither
        # section -- it is counted in the summary line instead, so the reader can see the whole
        # fleet was classified rather than just the lanes that needed something.
        # ⛔ EXCEPT WHEN THE STEP SAYS `report` (#1867). `UNATTRIBUTED-WORKING` is a STEP-2 verdict
        # (evidence of progress, no pid attribution) and it MUST be visible: it says "this lane is
        # not free capacity" about a lane whose record looks idle, which is the one thing a reader
        # cannot reconstruct. Routing it into `quiet` is how it was silently dropped -- the same
        # class of defect as a failed read rendering as `dispatched 0`.
        if (c["step"] in ("2", "3", "4") or v == "WORKING") and c.get("action") != "report":
            quiet.append(c)
            continue
        # PROTECTED covers EVERY verdict, not only the offerable ones: an owner lane is never an
        # action target whatever the classifier thought of it, and the reason must lead the entry so
        # a reader cannot mistake it for capacity.
        if c["protected"]:
            # The EVIDENCE leads, not the word PROTECTED: a reader must be able to audit WHY this
            # workspace was called the owner's, and an unreadable cwd must SAY it is unreadable
            # rather than borrow the authority of a positive claim.
            c["why"].insert(0, "PROTECTED lane (the OWNER's, not demonstrably the fleet's) -- NEVER "
                               "offered as work: %s" % (c.get("identity_why") or "no evidence"))
            report.append(c)
            continue
        if v in OFFERABLE and c["busy"]:
            c["why"].insert(0, "already auto-nudged this hour (result SENT/QUEUED) -- do NOT "
                               "message again; it is working")
            report.append(c)
            continue
        # ⛔ A LOW-CONFIDENCE LABEL IS NOT AN INSTRUCTION -- see `offerable()`. MEASURED
        # 2026-10-12 (`NEEDS-ACTION.md:27`): `- 3 Onboarding [CONTINUE 0.44] (2h58m)` became
        # "say CONTINUE, not a new task", typed at a lane inert for ~3h. Nothing gated the
        # confidence, so a coin-flip label carried the same weight as a certain one.
        if v in OFFERABLE and not offerable(v, c.get("conf")):
            c["why"].insert(0, "label %s at %s confidence (needs >= %.2f) -- REPORT ONLY, never an "
                               "instruction: the words layer is guessing"
                            % (v, "%.2f" % c["conf"] if c.get("conf") is not None else "no", CONF_MIN))
            report.append(c)
            continue
        if v == "DONE_READY":
            # ⛔ FAIL-CLOSED: `DONE_READY` is read from the lane's own last WORDS, which cannot know
            # that a work order landed AFTER they were written -- so a lane told something and silent
            # since would be offered as free capacity. This list is an INSTRUCTION TO A HUMAN, so a
            # guess reaches a person as a deed. Owner, verbatim: "Both of those were in the DO list
            # telling me to act. Acting would have interrupted live work."
            #
            # The fully-PAIRED measured instance (`Merigng PR`, 2026-10-11, read live from
            # `lane-status.py --json`): inbound_age=1210s, stale_s=18858s -- told 20m ago, silent for
            # 5h14m, with a `task` still in flight. It read `WEDGED` before this change and
            # `RECENT-INBOUND` after it.
            #
            # The finding that prompted this (`state/FINDING-actuator-gap-concrete-2026-10-11.md:43`)
            # records `2a Projection keys` as `IDLE->1 WITHHELD` with `latest_submitted 0.03h ago`
            # (108s). That reading did NOT record the lane's output age, so 108s is NOT paired with
            # any `stale_s` and no fixture claims it is -- an earlier draft of this comment paired
            # them and asserted a `stale` the source never carried.
            #
            # ⛔ ABSTENTION IS DELIBERATE AND IS NOT A HOLE. When `inbound_age` is None the predicate
            # returns False, so the lane IS still offered. That is fail-OPEN on an UNREAD signal --
            # deliberately, and it is a different fact from "inferred from an absence": it is the
            # same rule the rest of this instrument follows, where an unread value is never turned
            # into a positive claim in either direction. It is NOT "idleness is proven": where the
            # evidence exists it must show the lane answered after it was told.
            if told_but_silent_via(LS)(c.get("inbound_age"), c.get("stale")):
                c["why"].insert(0, "was given work %s ago and has produced NOTHING since (last "
                                   "output %s ago) -- NOT free capacity; dispatching would "
                                   "double up on work already assigned it"
                                % (_age(c.get("inbound_age")), _age(c.get("stale"))))
                report.append(c)
            elif not is_dispatch_target(c):
                # ⛔ THE TREE'S RESOLUTION ORDER, APPLIED AT THE DECISION (owner, 2026-10-20).
                # A confident `DONE_READY` is the WORDS layer; the tree ranks the mechanical
                # evidence above it. So a lane that says it is finished but is mechanically
                # WORKING / TOOL-IN-FLIGHT / CHILD-* / not-DONE-IDLE / mid-turn is NOT capacity,
                # and the refusal names which clause failed. Before this, LIST 1 was whatever the
                # words layer called finished plus a bare staleness comparison -- which is how a
                # lane that had just been told something became a dispatch instruction.
                c["why"].insert(0, "NOT a dispatch target -- %s" % dispatch_refusal(c))
                report.append(c)
            else:
                idle.append(c)
        elif v == "CONTINUE":
            wip.append(c)
        elif v == "CONTEXT-MISBELIEF":
            c["why"].insert(0, "says it must stop to preserve context -- FALSE: this harness "
                               "auto-compacts. Tell it plainly to CONTINUE the task in hand; it is "
                               "NOT finished and NOT free capacity.")
            wip.append(c)
        elif v in ("STALLED", "DEAD", "CHILD-STUCK"):
            wedged.append(c)
        elif v == "CHILD-OVERDUE":
            # ⛔ CHILD-OVERDUE IS NOT AN ACTION. See the CHILD-STUCK/CHILD-OVERDUE note in
            # `classify()`: this verdict means no child is reachable from here, i.e. UNKNOWN -- and
            # unknown must not be turned into an instruction. Bucketing it as `wedged` is what made
            # the beat read `WEDGED->1 unblock: 5&9 MCP and SDK surface` while that lane held a live
            # child (task in flight 89m); acting on it would have interrupted live work. It moves to
            # REPORT-ONLY, which keeps the lane and its why visible without inviting the interrupt --
            # the same SUPPRESS-rather-than-mislabel polarity as the child-count fix.
            c["why"].insert(0, "NOT an action: the child is unverifiable from here (no reachable "
                               "child), and a task child legitimately runs past this bound -- "
                               "unknown, not evidence of a stall")
            report.append(c)
        else:                                           # BLOCKED_* / UNBOUND / AMBIGUOUS / UNCLASSIFIED
            report.append(c)

    for b in (idle, wip, wedged, report, quiet):
        b.sort(key=lambda c: (c["lane"].lower(),))
    # `words_read` is what the floor keys on before it lets this clause SUPERSEDE the previous
    # clauses: it is true only when EVERY lane that needed Step 5 actually got an answer. A partial
    # answer (or any Jev error) leaves the older clauses standing, so an outage cannot silently
    # shrink the action set.
    words_read = (not step5) or (meta.get("source") == "JEV" and not meta.get("error")
                                 and meta.get("answered") == meta.get("asked"))
    # ── WORKSPACE-EXISTENCE FILTER ─────────────────────────────────────────────────────────────
    # ⛔ A lane whose cmux workspace no longer exists cannot be dispatched to, unblocked or
    # relaunched, and its recorded "words" are a position from a lane that is GONE -- not a live
    # one. So it must not populate an actionable list, and must NEVER be routed to the owner as a
    # decision. Measured 2026-10-09 (tortoise#7738): five roster rows with no workspace (2c Pack
    # compile, 4a Retrieval and traversal, 6 Durability core, 8 Hosted reliability, land-lane-4) were
    # offered simultaneously as `IDLE->need dispatch`, `WEDGED->unblock` AND `NEEDS-OWNER->route it`.
    # The last is the serious one: it would have carried a DECISION to the owner from a lane that
    # does not exist. They move to REPORT ONLY, which keeps the evidence without acting on it.
    # POLARITY: an unreadable workspace list filters NOTHING -- the same fail-open rule the DEAD
    # classifier uses above, so a cmux hiccup can never hide a real lane.
    # `live` is injectable so the test is DETERMINISTIC: without it every test inherits whatever
    # cmux happens to be running, which is how the first version of this filter passed its own test
    # for the wrong reason. Passing live=set() disables the filter entirely.
    # Normalised to a DICT in every case (uuid -> title). `live=set()` therefore still disables the
    # filter entirely, which is what the tests rely on; `live={uuid: title}` carries real titles.
    if live is None:
        _live = live_workspaces()
    elif isinstance(live, dict):
        _live = {str(k).strip().upper(): str(v) for k, v in live.items()}
    else:
        _live = {str(x).strip().upper(): "" for x in live}
    if _live:
        def _norm(s):
            return " ".join((s or "").split()).casefold()

        def _keep_if_live(bucket):
            out = []
            for c in bucket:
                ws = (c.get("ws") or "").strip().upper()
                title = _live.get(ws, "")
                if ws and ws not in _live:
                    c["why"].insert(0, "cmux workspace %s no longer exists -- not dispatchable, not "
                                        "unblockable, not routeable; its words are a recording from "
                                        "a lane that is gone (workspace-existence filter, #7738)"
                                    % (c.get("ws") or "?"))
                    report.append(c)
                elif title and _norm(title) != _norm(c.get("lane")):
                    # ⛔ THE UUID SURVIVED; THE LANE DID NOT (2026-10-10, #7957 H4). Measured: three of
                    # six lanes offered as IDLE had a live UUID under a different title -- `land-6260`
                    # was `P1 data-loss`, `Merigng PR` was `PR 2`, `\u03c0 - land-lane-1` was
                    # `5285 Decision`. A UUID-existence check passed all three, so the beat spent
                    # dispatches on lanes that had been renamed out from under it. Only a KNOWN,
                    # DIFFERING title demotes -- an unknown title (legacy list) never does, so a
                    # format downgrade can never hide a real lane.
                    c["why"].insert(0, "cmux workspace %s is now titled %r, NOT %r -- this lane no "
                                        "longer exists under that name, so its words are a recording "
                                        "from a lane that is gone (workspace-NAME filter, #7957 H4)"
                                    % (ws or "?", title, c.get("lane") or "?"))
                    report.append(c)
                else:
                    out.append(c)
            return out
        idle, wip, wedged = _keep_if_live(idle), _keep_if_live(wip), _keep_if_live(wedged)

    # ⛔ THE DISPATCHER'S TARGET LIST, PUBLISHED AS ITS OWN FIELD. `idle` is LIST 1 (what a human
    # reads); `dispatch_targets` is the SAME set as lane names, for a mechanical caller. It is
    # computed AFTER the workspace-existence filter, so a lane whose cmux workspace is gone (or was
    # renamed out from under it) can never appear here, and every member passed
    # `is_dispatch_target()`. Empty is a real answer: it means NO lane is evidenced idle, which is a
    # different fact from "the fleet is quiet" and must be read as such.
    # ⛔ A FLEET-WIDE LOSS OF EVIDENCE MUST NOT LOOK LIKE A QUIET FLEET (review round 2, P2). Identity
    # is fail-closed, so if NOTHING reads a cwd every lane becomes PROTECTED and `idle` is empty --
    # which is the same line as "no lane has work". The counters travel with the answer so the beat
    # can say WHICH of the two it is, the way `jev_down` already does for the words layer.
    _all = idle + wip + wedged + report + quiet
    n_protected = sum(1 for c in _all if c.get("protected"))
    n_identity_unread = sum(1 for c in _all
                            if c.get("cwd") is None and c.get("identity") != "FLEET")
    return {"idle": idle, "wip": wip, "wedged": wedged, "report": report, "quiet": quiet,
            "dispatch_targets": [c["lane"] for c in idle],
            "meta": meta, "jev_down": jev_down, "words_read": bool(words_read),
            "procmap": procmap_note,
            # `lane-status`'s SAMPLED note, when its bounded walk truncated (#2227). Carried here
            # so `render_md` can say it in the artifact a human reads, not only on stderr.
            "sampled": _SAMPLED_NOTE,
            "n_lanes": len(rows), "n_registry": len(labels), "files": files,
            "n_protected": n_protected, "n_identity_unread": n_identity_unread,
            # the rows that actually reached a bucket: `n_lanes` is the PRE-filter count, so a lane
            # whose cmux workspace is gone shrinks this one but not that one -- comparing the unread
            # count against `n_lanes` would let a fleet-wide blind read read as a partial loss
            # (review round 10, P3)
            "n_classified": len(_all)}


# ── the FILE ─────────────────────────────────────────────────────────────────────────────
def render_md(res, snapshot_age, source):
    ts = time.strftime("%Y-%m-%dT%H:%M:%S%z")
    m = res["meta"]
    words = ("READ (Jev %s: %s of %s lanes answered)"
             % (m.get("model") or "?", m.get("answered"), m.get("asked"))
             if m.get("source") == "JEV" and not m.get("error")
             else "NOT READ (%s)" % (m.get("error") or m.get("source") or "off"))
    L = []
    L.append("# NEEDS-ACTION -- automatic lane classification")
    L.append("")
    L.append("_Generated %s by `scripts/lane-actions.py` from `lane-status.py --json` "
             "(snapshot %ss old, %d lanes). Tree: `state/LANE-STATE-DECISION-TREE.md`._"
             % (ts, snapshot_age, res["n_lanes"]))
    L.append("")
    # ⛔ A CAPPED SCAN SAYS SO IN THE ARTIFACT, NOT ONLY ON STDERR (#2227). `lane-status` bounds its
    # walks and reports what it sampled; a reader of this file is deciding whether to dispatch, so
    # "the roster was truncated" belongs where the verdicts are, not in a log the reader does not
    # see. `res["sampled"]` is empty on an uncapped scan, so the ordinary document is unchanged.
    if res.get("sampled"):
        L.append("> **PARTIAL SCAN.** `%s` -- lanes beyond the cap were NOT read, so a lane"
                 " missing from these lists is not proof that nothing is wrong with it."
                 % res["sampled"])
        L.append("")
    # A SNAPSHOT OLDER THAN THE TICK'S OWN BOUND IS NORMAL, NOT AN ERROR -- but every age below is
    # measured against the SNAPSHOT, so a reader who does not know its age will read a 12-minute-old
    # verdict as a live one. The tick is bounded at 390s and its scan is the LAST thing it does, so
    # a scan that does not finish inside the bound leaves the PREVIOUS completed scan in place.
    if snapshot_age > 600:
        L.append("> **STALE SNAPSHOT (%s old).** The tick's scan did not complete inside its own "
                 "bound, so this is the last COMPLETED scan. The verdicts, ages and last messages "
                 "below are all measured at that snapshot: re-read a lane before acting on it."
                 % _age(snapshot_age))
        L.append("")
    L.append("- Steps 1-4 (identity, process, **CPU-time delta**, child, tool age): deterministic code.")
    L.append("- Step 5 (read what it said): %s. Jev decides ONLY this layer." % words)
    L.append("- Existence check: %s." % res["procmap"])
    L.append("- No action needed (%d): Steps 2-4 resolved them to WORKING / WAITING_ON_CHILD / "
             "TOOL-IN-FLIGHT -- %s."
             % (len(res["quiet"]), ", ".join("%s[%s]" % (c["lane"], c["verdict"])
                                              for c in res["quiet"]) or "none"))
    L.append("- PROTECTED lanes (not demonstrably the fleet's -- the owner's own workspaces, and any "
             "lane whose cwd is UNREADABLE) and auto-nudged (BUSY) lanes are never offered as work. "
             "Protection is the EVIDENCE predicate; the historical names (%s) and any entry in %s "
             "are ADDITIONAL union members only, never the mechanism."
             % ("/".join(PROTECTED_LEGACY_NAMES), display_path(_OWNER_WS_FILE)))
    L.append("- Entry format: `- <lane> [<verdict> <confidence>] (<how long since its last output>) "
             "[<cmux-workspace-uuid>] \u2014 <last message>` -- the WHY line below carries every other "
             "age (the words, the child, the tool) so no number here has to be guessed at.")
    L.append("")

    def entry(c):
        return "- %s [%s%s] (%s) [%s] \u2014 %s" % (
            c["lane"], c["verdict"],
            (" %.2f" % c["conf"]) if c.get("conf") is not None else "",
            _age(c["stale"]), (c["ws"] or "?").upper(),
            _clip(c["last_message"], LAST_MSG_CHARS) or "(no assistant text)")

    def whyline(c):
        extra = ""
        if c.get("said_age") is not None:
            extra = "last words said %s ago" % _age(c["said_age"])
        body = " | ".join(c["why"])
        return "    - WHY: " + " | ".join(x for x in (extra, body) if x)

    L.append("## LIST 1 -- IDLE, NEEDS A DISPATCH  (%d)" % len(res["idle"]))
    L.append("")
    L.append("Action: hand each of these the next unheld item for its lane. Its last words said it "
             "finished and holds nothing.")
    L.append("")
    L.append("_Every entry is EVIDENCED idle: DONE-IDLE, a COMPLETED last turn, no child and no "
             "tool in flight, and a confident DONE_READY from the words layer. WORKING / "
             "TOOL-IN-FLIGHT / CHILD-* / UNBOUND / WEDGED are never here (see "
             "`state/LANE-STATE-DECISION-TREE.md` and `is_dispatch_target()`)._")
    L.append("")
    if res["idle"]:
        for c in res["idle"]:
            L.append(entry(c))
            L.append(whyline(c))
    else:
        L.append("(none -- do NOT read that as all-idle; check the REPORT ONLY section)")
    L.append("")

    L.append("## LIST 1b -- MID-TASK, SAY **CONTINUE**  (%d)" % len(res["wip"]))
    L.append("")
    L.append("Action: ONE instruction -- continue. These are mid-task, NOT free capacity, and a new "
             "task here re-tasks work in hand. (Listed separately from LIST 1 because the "
             "instruction is different.)")
    L.append("")
    if res["wip"]:
        for c in res["wip"]:
            L.append(entry(c))
            L.append(whyline(c))
    else:
        L.append("(none)")
    L.append("")

    L.append("## LIST 2 -- WEDGED, TO UNBLOCK  (%d)" % len(res["wedged"]))
    L.append("")
    L.append("Action: investigate and unblock. NOT a reap list -- two flat samples cannot "
             "distinguish a wedge from a long tool call, and a child past 20m is frequently a "
             "legitimate merge rail or deploy.")
    L.append("")
    if res["wedged"]:
        for c in res["wedged"]:
            L.append(entry(c))
            L.append(whyline(c))
    else:
        L.append("(none)")
    L.append("")

    L.append("## REPORT ONLY -- DO NOT ACT  (%d)" % len(res["report"]))
    L.append("")
    L.append("The tree forbids acting on these: a false DONE_READY re-tasks a mid-work lane, and a "
             "false STALLED wakes an expensive session for nothing. Reporting costs nothing.")
    L.append("")
    if res["report"]:
        for c in res["report"]:
            L.append(entry(c))
            L.append(whyline(c))
    else:
        L.append("(none)")
    L.append("")
    return "\n".join(L) + "\n"


# ── the BEAT clause (ONE line, short: names inline, messages in the file) ─────────────────
def render_beat(res, path_for_beat):
    """The beat's clause: NAMES inline (short), MESSAGES in the file.

    HARD CONSTRAINT -- ONE LINE, NO EMBEDDED NEWLINE: `cmux send "$MSG\\n"` submits EACH newline as
    its own turn, which the owner reported as "a mess... massive noise". The other constraint is
    length: the beat is already near its display limit, so every clause here is a COUNT + a few
    names + a pointer, and the rest is in the file.
    """
    note = " [JEV-DOWN: words layer UNREAD -- reported, not guessed]" if res["jev_down"] else ""

    def names(lst):
        got = [c["lane"] for c in lst[:MAX_NAMES]]
        extra = len(lst) - len(got)
        return ", ".join(got) + (" (+%d more)" % extra if extra else "")

    parts = []
    if res["idle"]:
        parts.append("IDLE->%d need dispatch (see %s): %s"
                     % (len(res["idle"]), path_for_beat, names(res["idle"])))
    elif res["wip"]:
        parts.append("WIP->%d say CONTINUE, not a new task (see %s): %s"
                     % (len(res["wip"]), path_for_beat, names(res["wip"])))
    elif res["wedged"]:
        parts.append("WEDGED->%d unblock (see %s): %s"
                     % (len(res["wedged"]), path_for_beat, names(res["wedged"])))
    else:
        parts.append("NOTHING-ACTIONABLE (see %s)" % path_for_beat)
    if res["idle"] and res["wip"]:
        parts.append("WIP->%d say CONTINUE, not a new task: %s"
                     % (len(res["wip"]), names(res["wip"])))
    if (res["idle"] or res["wip"]) and res["wedged"]:
        parts.append("WEDGED->%d unblock: %s" % (len(res["wedged"]), names(res["wedged"])))
    if res["report"]:
        parts.append("REPORT-ONLY->%d (do NOT act)" % len(res["report"]))
    # ⛔ SILENCE IS NOT EVIDENCE (review round 2, P2). When the fleet cannot read ANY lane's cwd, every
    # lane is PROTECTED by the fail-closed rule and the first clause reads NOTHING-ACTIONABLE -- the
    # same line as a quiet fleet, from an instrument that is blind rather than satisfied. Say which.
    n_unread = res.get("n_identity_unread") or 0
    n_lanes = res.get("n_classified") or res.get("n_lanes") or 0
    n_prot = res.get("n_protected") or 0
    # ⛔ A PROTECTED LANE IS INVISIBLE OTHERWISE (review round 3, P1): the lanes lost to a wrong
    # identity rule have READABLE cwds, so they raise no `n_identity_unread` -- 26 lanes read as the
    # owner's on the box behind this change, and the beat said only NOTHING-ACTIONABLE. The count is
    # therefore emitted whenever no lane is offered, whichever rule produced it.
    if not res["idle"] and (n_unread or n_prot):
        if n_unread and n_unread >= n_lanes:
            parts.append("IDENTITY-UNREAD->%d (no lane's cwd was readable -- NOT a quiet fleet)"
                         % n_unread)
        else:
            parts.append("PROTECTED->%d (owner/unreadable -- never offered as work, see %s)"
                         % (n_prot, path_for_beat))
    line = " ".join((" | ".join(parts) + note).split())
    return line if len(line) <= SUMMARY_MAX else line[:SUMMARY_MAX - 1].rstrip() + "\u2026"


# ── input ────────────────────────────────────────────────────────────────────────────────
def load_snapshot(args, LS=None):
    """(rows, snapshot_age_s, reference_clock).

    Rejects a DEGRADED snapshot outright (both paths) and re-scans a PARTIAL one. ⛔ AND WHEN THE
    RE-SCAN ITSELF FAILS it returns the newest roster it DID read, with `COMPLETENESS UNMEASURED` on
    stderr -- the strongest read obtainable, never a claim of a complete fleet. That is the rule now;
    see the deadline block at the end of the invoke path for why it changed (#1788, #1774).
    """
    if args.stdin:
        try:
            if args.stdin == "-":
                raw, ref = sys.stdin.read(), time.time()
            else:
                raw = open(args.stdin, errors="ignore").read()
                try:
                    ref = os.path.getmtime(args.stdin)
                except OSError:
                    ref = time.time()
            rows = json.loads(raw)
        except Exception as e:
            raise SystemExit("lane-actions: cannot read snapshot %s: %r" % (args.stdin, e))
        # ── A DEGRADED SNAPSHOT IS NOT A FLEET READ ────────────────────────────────────
        # ⛔ THE `--stdin` PATH HAD NO GUARD. Every row carries `degraded` when lane-status
        # could not read the cmux fleet roster, and on that path the roster is the hand-written
        # TSV alone -- every live-only lane INVISIBLE. MEASURED 2026-10-12: the snapshot the
        # heartbeat publishes carried 26 workspaces, ALL of them TSV and ZERO of the 13 live-only
        # ones, while four lanes were stalled; `WEDGED (0)` was printed off it. The re-scan guard
        # below (`len(rows) >= want - REGISTRY_GRACE`) is bypassed entirely when --stdin is used,
        # which is exactly how heartbeat-loop.sh calls this tool. So the refusal lives HERE too.
        _refuse_if_degraded(rows, args.stdin)
        # The header must state the DATA's age, not the run time: a snapshot published by an earlier
        # pass (a killed tick leaves the last good one in place) is still usable, but the reader has
        # to be able to see how old it is.
        age = int(max(0, time.time() - ref)) if args.stdin != "-" else 0
        return rows, age, ref
    # Invoke lane-status.py. Its cache is ONE file keyed by --only, so a caller that scanned a
    # SUBSET (the retired queue-dispatch's two-read guard did exactly this, #1874) OVERWRITES the
    # fleet-wide snapshot
    # and every later consumer in the same pass silently reads 4 lanes instead of 30. Detected and
    # refused here: a partial snapshot is re-scanned for real rather than classified as the fleet.
    sys.path.insert(0, SCRIPTS)
    import subprocess
    want = _live_want(LS)
    # ⛔ ONE DEADLINE FOR THE WHOLE READ, NOT A FRESH `args.budget` PER ATTEMPT (2026-10-18,
    # MEASURED). This loop used to hand EACH attempt its own full `args.budget`, so the worst case
    # was 2 x budget -- and every caller's OUTER bound was smaller than that sum, which made the
    # outer timeout fire FIRST on exactly the path that needed the time. Measured on the live box:
    # `pr-doctor.py` allowed this tool 600s while the two scans below each got 300s, and a real
    # `--no-cache` scan costs **147s on a quiet box** (measured 183s and 200s on 2026-10-18; the
    # module's own note records 250-300s under load). So 2 x 147s = 294s sat right against the 300s
    # inner bound and BEYOND the outer one: the pass died with `TimeoutExpired` and `pr-doctor`
    # refused (rc 2). MEASURED over `state/pr-doctor.launchd.log` (the SCHEDULED half only), first
    # line 2026-10-10T22:49 -> 2026-10-18T21:32: 382 passes, 320 `LANE READ FAILED`, 241 carrying
    # `TimeoutExpired`, and TWO passes that ever dispatched (both 2026-10-11). Nested bounds must
    # COMPOSE: the attempts share one budget, so this tool can never outlive its caller.
    budget = max(1.0, float(args.budget))
    deadline = time.monotonic() + budget
    _read_t0 = time.monotonic()      # for the refusal's "how long it waited" (#2227)
    _sampled = ""                    # lane-status's SAMPLED note, carried into the header
    # ⛔ THE RETRY MUST NOT BE STARVED BY THE ATTEMPT IT IS FIXING (#1788, #1774). A shared
    # deadline alone subtracts attempt 0's cost from the retry's allowance, so on a loaded box
    # (measured: 250-300s per scan) a 200s first attempt left the `--no-cache` scan ~220s -- the
    # retry existed to fix a partial read and was systematically too short to finish one. The
    # FIRST attempt gets a bounded slice; the retry gets whatever is left, which is never less than
    # the majority of the budget.
    FIRST_SHARE = 0.4
    first = None          # (rows, age, ref, complete) from attempt 0, kept as the FALLBACK
    best = None           # the newest SUCCESSFUL read; a successful retry must WIN over attempt 0
    for attempt in (0, 1):
        remaining = deadline - time.monotonic()
        if remaining <= 1.0:
            sys.stderr.write("lane-actions: the %ss budget was spent before "
                             "%s -- no further scan attempt\n"
                             % (args.budget, "the first scan finished" if first is None
                                else "the --no-cache re-scan could start"))
            break
        allowance = min(remaining, budget * FIRST_SHARE) if attempt == 0 else remaining
        cmd = ["/usr/bin/python3", LS_PATH, "--json", "--sample", str(args.sample)]
        if attempt:
            cmd.append("--no-cache")
        # ⛔ THE SCAN'S OWN SAMPLING NOTE COMES BACK ON STDERR, AND IT MUST NOT BE DROPPED (#2227).
        # lane-status caps its walks and says what it sampled; a consumer that reads only stdout
        # would republish a truncated roster as the fleet -- the exact silent lower bound the cap
        # exists to avoid. Captured here and carried into the generated header below.
        _sampled = ""
        _attempt_t0 = time.monotonic()
        try:
            _r = subprocess.run(cmd, capture_output=True, text=True, timeout=allowance)
            raw = _r.stdout
            _sampled = next((ln.strip() for ln in (_r.stderr or "").splitlines()
                             if ln.startswith("lane-status: SAMPLED")), "")
            globals()["_SAMPLED_NOTE"] = _sampled
            rows = json.loads(raw)
            # ⛔ `_refuse_if_degraded` RAISES `SystemExit`, WHICH IS A `BaseException` (2026-10-18,
            # review). `except Exception` therefore did NOT catch it, so a DEGRADED re-scan escaped
            # the fallback below entirely and discarded a non-degraded roster attempt 0 had already
            # read -- the exact false red this block exists to prevent, alive on the one path the
            # suite did not exercise (its test used `TimeoutExpired`, an ordinary `Exception`).
            _refuse_if_degraded(rows, "lane-status.py invoke path")
        except (Exception, SystemExit) as e:
            # ⛔ A FAILED ATTEMPT MUST NOT DISCARD A ROSTER WE ALREADY READ. The old code let the
            # retry's exception propagate, so a 25-row, non-degraded, freshly-read snapshot was
            # thrown away because the SECOND read of the same data timed out -- an unreadable
            # attempt invalidating a readable datum. A degraded RESULT on the retry is the same
            # case: attempt 0's non-degraded roster is complete enough to act on, and refusing
            # there is a false red (only attempt 0 keeps the hard refusal).
            if first is not None:
                sys.stderr.write(
                    "lane-actions: the --no-cache re-scan did not produce a usable read "
                    "(%s: %s) -- using the %d-row roster already read; "
                    "COMPLETENESS UNMEASURED (%s)\n"
                    % (type(e).__name__, str(e)[:120], len(first[0]),
                       "the fleet size is unknown" if want is None
                       else "wanted >= %d" % max(0, want - REGISTRY_GRACE)))
                return first[:3]
            # ⛔ A REFUSAL NAMES ITSELF (#2227): WHAT IT TRIED, HOW LONG IT WAITED, AND THE AGE OF
            # THE LAST GOOD SAMPLE. `lane-status.py failed: TimeoutExpired` was the whole message
            # pr-doctor surfaced for a fleet read that had actually happened minutes earlier --
            # the reader could not tell a hung tool from a busy box, and the age of the last real
            # snapshot (the thing that decides whether to act) was not printed at all.
            # `last_good` is an AGE from the published snapshot's mtime, never a value from it.
            raise SystemExit(
                "lane-actions: lane-status.py failed after %.1fs of a %ss budget "
                "(tried: lane-status.py --json --sample %s%s; %s: %s); %s"
                % (time.monotonic() - _attempt_t0, args.budget, args.sample,
                   "" if attempt else ", then --no-cache", type(e).__name__, str(e)[:120],
                   _last_good_sentence()))
        try:
            age = int(time.time() - os.path.getmtime(
                os.path.join(STATE, "lane-status.cache")))
            ref = os.path.getmtime(os.path.join(STATE, "lane-status.cache"))
        except OSError:
            age, ref = 0, time.time()
        complete = want is not None and len(rows) >= want - REGISTRY_GRACE
        rec = (rows, age, ref, complete)
        best = rec                                   # a SUCCESSFUL read always supersedes
        if first is None:
            first = rec
        if complete:
            return rows, age, ref
        # Unknown fleet size -> we cannot measure completeness, so take the STRONGEST read we can
        # rather than accept this one. `attempt` is 0 on the cached pass and 1 on the --no-cache
        # pass; after the second there is nothing better to try.
        sys.stderr.write("lane-actions: snapshot %s (%s of %s) -- re-scanning without the cache\n"
                         % ("PARTIAL" if want is not None else "UNVERIFIABLE",
                            len(rows), want if want is not None else "an unknown fleet size"))
    if best is None:
        raise SystemExit("lane-actions: no snapshot could be read within the %ss budget "
                         "(waited %.1fs across both attempts); %s"
                         % (args.budget, time.monotonic() - _read_t0,
                            _last_good_sentence()))
    # ⛔ WHAT IS RETURNED HERE IS THE NEWEST READ, NOT THE FIRST ONE -- AND IT IS NOT COMPLETE.
    # The recorded rule ("None means UNKNOWN, so take the strongest read available") still holds:
    # this returns the strongest read that could be OBTAINED, and says on stderr that its
    # completeness could not be measured. It is not a claim of a full fleet, and the caller is
    # expected to carry the caveat (pr-doctor logs it).
    return best[:3]


def write_pair(out_path, md, beat, words_read, beat_path=None):
    """Publish the recap and its sidecar as a BOUND pair; return the process exit code.

    ⛔ THE TWO FILES ARE SEPARATE ATOMIC WRITES, SO THEY MUST NOT BE ALLOWED TO DIVERGE SILENTLY
    (#7957 H3). A failure between them leaves a FRESH recap beside a STALE beat -- two numbers, one
    tick -- and the beat is the half the floor actually reads, so the reader would publish the
    PREVIOUS tick's action list as this tick's. `md=` binds them: it is the digest of the recap THIS
    beat was rendered from, so a reader can tell a current pair from a torn one instead of trusting
    the sidecar's own mtime. ABSENCE IS NOT A PASS -- a beat written before this key existed cannot
    be verified, so the reader suppresses it rather than publishing a number it cannot vouch for.

    0  both halves published and bound
    3  the RECAP could not be written: NOTHING was published, so the previous pair still stands and
       is still consistent -- that is why this is not the torn case.
    4  the recap WAS published and the beat was NOT: the pair is TORN RIGHT NOW. Never 0 -- a caller
       reading 0 would report a successful tick whose two halves describe different states.
    """
    if beat_path is None:
        beat_path = BEAT_PATH
    # ⛔ WRITE THE BYTES WE HASH (and only publish a beat a reader can actually verify).
    # (a) The digest below is over `md.encode("utf-8")`, so the file must hold exactly those bytes.
    #     Writing in TEXT mode would use the interpreter's locale encoding; under any deployment whose
    #     default encoding is not UTF-8, writer and reader would disagree on the digest for any
    #     non-ASCII recap -- and `render_md` always emits an em dash -- so EVERY pair would fail
    #     closed forever with both suites still green. Pin the encoding rather than assume it.
    md_bytes = md.encode("utf-8")
    md_sha = hashlib.sha256(md_bytes).hexdigest()[:MD_SHA_LEN]
    # (b) The reader hashes `$STATE/NEEDS-ACTION.md` -- a FIXED path -- while the beat path is fixed
    #     too. A run with `--out <elsewhere>` therefore produces a beat bound to a file no reader
    #     reads, and overwrites the canonical beat while doing it. That is a LATENT inconsistency (no
    #     caller passes `--out` today), so it is REPORTED rather than silently absorbed: the run's
    #     clause will read as torn and be withheld, and this line is the only place that says why.
    if os.path.abspath(out_path) != os.path.abspath(OUT_PATH):
        sys.stderr.write("lane-actions: --out %s is not %s; every reader hashes %s, so this run's "
                         "beat will read as TORN and the act clause will be withheld.\n"
                         % (out_path, OUT_PATH, OUT_PATH))
    try:
        tmp = out_path + ".tmp"
        with open(tmp, "wb") as fh:
            fh.write(md_bytes)
        os.replace(tmp, out_path)              # atomic: a reader never sees a half-written file
    except OSError as e:
        sys.stderr.write("lane-actions: cannot write %s: %s\n" % (out_path, e))
        return 3
    try:
        tmp = beat_path + ".tmp"
        with open(tmp, "w") as fh:
            fh.write("act=%s\nactfull=%d\nmd=%s\n" % (beat.replace("\n", " "),
                                                      1 if words_read else 0,
                                                      md_sha))
        os.replace(tmp, beat_path)
    except OSError as e:
        sys.stderr.write("lane-actions: cannot write %s: %s\n" % (beat_path, e))
        sys.stderr.write("lane-actions: the recap/beat pair is TORN -- %s was updated and the beat "
                         "was NOT; a reader must treat the beat as stale.\n" % display_path(out_path))
        return 4
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--stdin", metavar="FILE", default=None,
                    help="read the lane-status JSON from FILE ('-' = stdin) instead of invoking it")
    ap.add_argument("--out", default=OUT_PATH)
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--no-jev", action="store_true", help="deterministic only; words layer UNREAD")
    ap.add_argument("--sample", type=float, default=12.0)
    ap.add_argument("--budget", type=float, default=300.0,
                    help="bound for the lane-status invocation when this file invokes it")
    a = ap.parse_args()

    LS = _load(LS_PATH, "lane_status")
    LV = _load(LV_PATH, "lane_verdict")
    rows, snap_age, ref = load_snapshot(a, LS)
    if not isinstance(rows, list) or not rows:
        sys.stderr.write("lane-actions: empty snapshot -- refusing to write a verdict\n")
        return 2

    res = build(rows, LS, LV, use_jev=not a.no_jev, ref=ref)
    md = render_md(res, snap_age, "lane-status.py")
    # The tick reads the sidecar rather than parsing stdout: the beat clause is ONE line with no
    # quoting hazards, and `actfull` is what lets the floor know whether the classifier words layer
    # was actually read -- so a Jev outage degrades to the previous beat instead of publishing an
    # empty action list as if the fleet were clean. write_pair owns the pair's coherence.
    beat = render_beat(res, display_path(a.out))
    rc = write_pair(a.out, md, beat, res["words_read"])
    # ⛔ KEEP THE EARLY RETURN — EMPTY STDOUT **IS** A CALLER'S FAIL-CLOSED DETECTOR (#1897 review).
    # A review raised the coupling as a P3: "a read API must not be gated on a write". Measured, the
    # coupling is load-bearing for a caller of the shape `if not (out or "").strip(): refuse` — it
    # does NOT compare rc, so rc 3/4 has to produce NO document, or such a caller parses a torn tick
    # as a good read and acts on it. Printing before `return rc` and leaving the direction to "the
    # caller checks rc" would be a claim about a guard that does not exist: measured, rc=4 with a
    # document in stdout is read as a GOOD READ. Decoupling is therefore a change to any such
    # caller (gate on rc first, with its own proof), NOT a change here — and not worth trading the
    # fail-closed direction for a tidier read API on the exact path this branch exists to contain.
    # ⚠️ CORRECTED 2026-10-20: this used to name `pr-doctor.py` as that caller. It is not one any
    # more — it retired the lane-table path (#1874) and spawns background workers instead, so it
    # has no `lane-actions.py` call to gate. The invariant is kept for the `--stdin`/`--json`
    # callers that do exist (heartbeat-loop.sh, lane-scan-fallback.sh, tests, a manual read);
    # the point here is the published document, not one retired reader.
    if rc:
        return rc
    if a.json:
        print(json.dumps({
            "beat": beat, "jev": res["meta"], "jev_down": res["jev_down"],
            "words_read": res["words_read"],
            "counts": {k: len(res[k]) for k in ("idle", "wip", "wedged", "report", "quiet")},
            # ⛔ THE COUNTERS TRAVEL WITH THE LIST (review round 3, P3). A mechanical caller that
            # reads only `dispatch_targets` sees `[]` and cannot tell "no lane is evidenced idle"
            # from "identity evidence was lost, so EVERY lane is PROTECTED" -- which is the whole
            # reason the counters exist. Without them here, the distinction lived only in the human
            # beat string, which is suppressed whenever `idle` is non-empty.
            "n_protected": res["n_protected"],
            "n_identity_unread": res["n_identity_unread"],
            "n_classified": res["n_classified"],
            # the dispatcher's target list, and the reason each offered lane qualifies
            "dispatch_targets": res["dispatch_targets"],
            "idle": res["idle"], "wip": res["wip"], "wedged": res["wedged"],
            "report": res["report"], "quiet": res["quiet"],
        }, indent=1))
    else:
        print(beat)
    return 0


if __name__ == "__main__":
    sys.exit(main())
