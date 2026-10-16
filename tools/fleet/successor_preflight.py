#!/usr/bin/env python3
"""tools/fleet/successor_preflight.py — prove a predecessor is GONE before a
successor lane is dispatched, and put the proof in the dispatch file (#1317).

WHY THIS EXISTS
---------------
On 2026-09-21 the fleet dispatched a **successor lane** to a unit whose
predecessor was still alive and mid-cycle-3 of the PR's own review loop. The
successor was told *"a fresh session replacing the previous B4 which is out of
context"* — a STATE assertion nobody had read from an artifact. The predecessor
was a live ``pi`` process whose ``cwd`` was the very worktree the successor was
told to land, and the branch moved under the successor mid-review.

The cost was an entire lane's context on a unit it could not touch, and a real
risk of two lanes writing one branch. Nothing was corrupted only because the
successor stood down on its own.

The rule the incident violates is already stated: **idle is not available**. A
lane that is sitting at a prompt is still the owner of its worktree and may be
mid-issue. A dispatch that says "the predecessor is gone" must therefore carry
the reading that shows it, so a reader can tell *"the predecessor is gone"* from
*"the predecessor was assumed gone"*.

TWO READS, AND WHICH ONE DECIDES
--------------------------------
The issue proposed both of these as liveness evidence. They are NOT equally
strong, and this tool encodes the difference rather than treating them alike:

1. **A live ``pi`` process whose ``cwd`` is the target worktree** — AUTHORITATIVE.
   A ``pi`` is the agent process; if one is rooted in the worktree, the worktree
   has an owner, whether it is mid-tool or at a prompt. Read with ``pgrep`` +
   ``lsof`` (``/proc/<pid>/cwd`` as the Linux fallback).

2. **Every LANE RECORD whose ``cwd`` is the target worktree** — AUTHORITATIVE for
   the same question, via the fleet's ONE liveness predicate
   (``liveness.gather`` + ``liveness.evaluate``, the #1178 rule; see
   ``docs/ops/fleet-liveness.md``). This is what catches a predecessor whose
   transcript has stopped growing (``dead`` vs ``running-quiet``/``wedged``) and
   whose record outlives its process. **No second liveness rule is written here** —
   a local re-implementation is the exact defect #1178 exists to remove.

3. **The cmux workspace's ``latest_submitted_at`` / ``updated_at``** — CORROBORATING,
   and deliberately NOT allowed to be the only reason for a refusal. It is
   **INBOUND** activity (what someone *sent* the lane), which
   ``scripts/lane-status.py`` documents as *"not evidence of liveness and must
   never be read as such"*. It is used here only in the SAFE direction: recent
   inbound activity is a *sufficiency* signal for "do not dispatch a successor",
   never a reason to declare a predecessor alive when the two authoritative reads
   say otherwise. Its unavailability never decides the verdict on its own —
   otherwise a box where the ``cmux`` CLI is unreachable (launchd: *"Access denied
   — only processes started inside cmux can connect"*) would refuse every
   successor dispatch for ever, which is a gate that can never open.

THE DECISION LADDER (order is the safety property)
--------------------------------------------------
Each step is a return; nothing later can override an earlier verdict. The order
below IS the order `decide()` implements:

    0. a live pi rooted in the worktree        -> PREDECESSOR-LIVE
       (a live pid is POSITIVE evidence: it proves an owner whether or not the
       store can be read, so it outranks the store and reports LIVE, not UNKNOWN
       -- both refuse the dispatch)
    1. the STORE is unreadable                 -> UNKNOWN   (fail closed)
    2. any lane record on the worktree that is
       not `dead` (running-quiet/wedged/idle/unknown) -> PREDECESSOR-LIVE
    3. recent cmux activity for the worktree   -> PREDECESSOR-LIVE
    4. the process read could not be completed -> UNKNOWN   (fail closed)
    5. both authoritative reads were readable,
       and neither produced a live witness     -> PREDECESSOR-GONE

A READ IS COMPLETE, OR IT IS NOT A READING. `readable` is not "the command
returned": it means every pid we asked about was ANSWERED. The two ways a read
can fail to cover the list are different facts and only one of them is evidence:

  * a pid the reader could not stat/read (`lsof` exit 1 with a partial output,
    `EACCES`/`EPERM` on `/proc/<pid>/cwd` under `hidepid`, `EINVAL` on a
    non-symlink) -> the read was REFUSED -> UNKNOWN. Scoring a partial read as a
    complete one is how a live predecessor owned by another uid reads as "no
    agent in this worktree" and the tool emits the #1317 failure it exists to
    prevent. **Absence of an answer is never evidence of absence.**
  * a pid that is provably GONE (`ENOENT`, the pid exited between `pgrep` and
    the read) -> that IS an answer: it holds no worktree. This is why the
    `/proc` fallback can complete a partial `lsof` read rather than abstaining.

LIVE beats GONE at every step, and UNKNOWN is not a weaker GONE: a reading we
could not take is never a predecessor we proved absent. That is the same
polarity the fleet's kill path already runs on (*"no proof => not idle => never
kill"*), applied to the dispatch.

The consequence of each failure direction, stated plainly:
  * a false GONE dispatches a second lane onto a live unit (the #1317 incident);
  * a false LIVE delays a legitimate dispatch — friction, recoverable by a human
    reading the proof block that this tool writes.

EXIT CODES
----------
    0  PREDECESSOR-GONE   — dispatch a successor: the proof says the unit is free
    3  PREDECESSOR-LIVE   — do NOT dispatch a successor; nudge the live lane or wait
    4  UNKNOWN            — could not verify; fail closed, do not dispatch
    2  usage / environment error — NOTHING was decided: a bad/missing argument, an
       `--emit` that could not be written, or a `--worktree` that is not a
       readable directory. A target that does not exist is never reported GONE --
       "there is no directory here" and "I proved no predecessor holds it" are
       different facts, and a dispatcher switching on the exit code must be able
       to tell them apart.

USAGE
-----
    python3 tools/fleet/successor_preflight.py --worktree /path/to/.worktrees/3834-x
    python3 tools/fleet/successor_preflight.py --worktree /path --emit "$O/logs/prompt-3834.txt"
    python3 tools/fleet/successor_preflight.py --worktree /path --json

``--emit FILE`` APPENDS the proof block to the dispatch file (the brief that
seeds the successor), so the dispatch carries the reading and its timestamp.
Exit codes are unchanged by ``--emit``.

Env seams (tests + tuning; production uses the defaults):
    SUCCESSOR_PGREP_BIN   pgrep binary (default: pgrep on PATH)
    SUCCESSOR_LSOF_BIN    lsof binary (default: lsof on PATH; /proc fallback)
    SUCCESSOR_CMUX_BIN    cmux binary (default: cmux on PATH)
    SUCCESSOR_PROC_ROOT   the procfs root for the cwd fallback (default: /proc)

The proof block NAMES the readers it used (`readers: pgrep=… lsof=… …`) for the
same reason every read is stated: an inherited `SUCCESSOR_LSOF_BIN`/`--store`
changes what was read, so the artifact must not read as if the default tool had
made the reading.
    LANE_LIVENESS_PS_REAL the real ps for the shared one-read-per-pass cache
    PI_PID_IDENTITY_LIB   probe CLI (default: liveness.lib_path())
"""

from __future__ import annotations

import argparse
import datetime
import json
import os
import shutil
import subprocess
import sys
from typing import Dict, List, Optional, Sequence, Tuple

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

try:  # the farm promise: the classifier + its driver land beside this tool.
    import lane_liveness  # noqa: E402
    import liveness  # noqa: E402
except ImportError as _exc:  # pragma: no cover - env dependent
    sys.stderr.write(
        "successor-preflight: FATAL: cannot import the liveness classifier beside this "
        "tool (%s). Farm/ship liveness.py and lane_liveness.py with it.\n" % _exc
    )
    raise SystemExit(2)

GONE = "PREDECESSOR-GONE"
LIVE = "PREDECESSOR-LIVE"
UNKNOWN = "UNKNOWN"

# The recency window for the corroborating cmux reading, in SECONDS. The issue
# says "within the last few minutes"; 15 min is the fleet's cooldown unit
# (`queue-dispatch.py`'s tick), so an inbound turn inside it means someone was
# interacting with that lane recently enough that displacing it is wrong.
DEFAULT_RECENT_S = 900

# The kernel's spelling for a cwd whose directory has been unlinked. See `_real`.
DELETED_SUFFIX = " (deleted)"

# procfs root for the cwd fallback (a test seam: the suite drives a fake root).
DEFAULT_PROC_ROOT = "/proc"


def _real(path: str) -> str:
    """One normalisation for every path compared here.

    ``record['cwd']``, a live pid's cwd and cmux's ``current_directory`` are
    written by three different producers, and on macOS ``/var`` vs
    ``/private/var`` (or a symlinked checkout root) makes two spellings of one
    directory. Comparing unnormalised strings would report GONE for a live
    predecessor — the exact false absence this tool exists to prevent.
    """
    try:
        s = os.path.expanduser(path)
        # Linux spells a cwd whose directory has been UNLINKED as
        # "/path/to/dir (deleted)" (`/proc/<pid>/cwd`). That is the same
        # directory as `/path/to/dir`; comparing the two spellings apart would
        # report a live predecessor in a removed worktree as GONE -- the #1317
        # failure. Strip the kernel's suffix (and only that suffix) first.
        if s.endswith(DELETED_SUFFIX):
            s = s[: -len(DELETED_SUFFIX)]
        return os.path.realpath(os.path.normpath(s))
    except Exception:
        return path


def _run(cmd: Sequence[str], timeout: int = 60) -> Tuple[int, str]:
    try:
        proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                              timeout=timeout)
    except (OSError, subprocess.SubprocessError):
        return 127, ""
    return proc.returncode, proc.stdout.decode("utf-8", "replace")


# ── read 1: live pi processes rooted in the worktree (authoritative) ─────
def pi_pids(pgrep_bin: str) -> Tuple[List[str], bool]:
    """``(pids, readable)`` for every live ``pi``.

    ``pgrep -x pi`` matches the executable NAME exactly, so a ``login``/``zsh``
    sitting in the worktree is not mistaken for an agent. An EMPTY result and a
    FAILED read are different facts: a missing ``pgrep`` must not read as "no
    agent anywhere" (that is the absent-vs-empty defect this repo has paid for
    repeatedly).
    """
    rc, out = _run([pgrep_bin, "-x", "pi"])
    if rc not in (0, 1):
        return [], False
    return [p for p in out.split() if p.isdigit()], True


def pi_cwds(pids: Sequence[str], lsof_bin: str,
            proc_root: str = DEFAULT_PROC_ROOT) -> Tuple[Dict[str, str], bool]:
    """``({pid: cwd}, readable)`` for the given pids.

    ``lsof -a -d cwd -Fn`` in ONE call is the fleet's existing mechanic
    (``scripts/lane-status.py``'s ``_pi_cwd_map``) and works on macOS and Linux.
    When ``lsof`` is absent the ``/proc`` fallback covers Linux; if neither can
    answer, ``readable`` is False and the caller abstains rather than concluding
    that no process holds the worktree.
    """
    if not pids:
        return {}, True
    if shutil.which(lsof_bin) or os.path.exists(lsof_bin):
        _rc, out = _run([lsof_bin, "-a", "-d", "cwd", "-Fn", "-p", ",".join(pids)])
        m: Dict[str, str] = {}
        cur = None
        for line in out.splitlines():
            if line.startswith("p"):
                cur = line[1:].strip()
            elif line.startswith("n") and cur:
                m[cur] = line[1:]
                cur = None
        # A reading is COMPLETE only when every pid we asked about is answered.
        # lsof exits 1 when it cannot stat a pid (another uid's process, or a pid
        # that exited mid-read) and simply OMITS it. The cwds it did print are
        # true, but an omission is not an answer: the old `if m: return m, True`
        # scored a REFUSED read as a complete one, so a live pi lsof could not
        # stat read as "no agent in this worktree" -> PREDECESSOR-GONE. That is
        # the #1317 failure, reached through the read side.
        if m:
            if set(m) == set(pids):
                return m, True
            # Ask the /proc fallback for exactly the pids lsof did not answer.
            # `ok` means it ANSWERED all of them: each is either mapped in `rest`
            # or `ENOENT` (proven gone), so the merged read is COMPLETE. A refusal
            # (EACCES/EINVAL) makes the whole read unusable.
            rest, ok = _proc_cwds([p for p in pids if p not in m], proc_root)
            if not ok:
                return {}, False
            m.update(rest)
            return m, True
        # It printed nothing — fall through to the /proc fallback, and if that
        # does not exist either, the caller abstains. That is the difference
        # between an absent read and an empty one: an empty lsof result for a
        # non-empty pid list is NOT "no process holds the worktree".
    return _proc_cwds(pids, proc_root)


def _proc_cwds(pids: Sequence[str], proc_root: str) -> Tuple[Dict[str, str], bool]:
    """Linux fallback: ``/proc/<pid>/cwd`` is a symlink to the process cwd.

    The two failure modes here must NOT be conflated, and the old
    ``except OSError: continue`` did exactly that:

      * ``ENOENT`` — the pid is GONE. An answer: it holds no worktree.
      * any other ``OSError`` — ``EACCES``/``EPERM`` (another uid's process under
        ``hidepid``) or ``EINVAL`` (a non-symlink): the read was REFUSED. That is
        NOT evidence of absence, and silently skipping it made a live
        predecessor read as GONE while the caller still reported
        ``readable=True``. Refuse the whole read so ``decide`` abstains.

    The return contract the caller relies on: ``ok=True`` means EVERY pid in
    ``pids`` was ANSWERED — mapped in the returned dict, or proven gone by
    ``ENOENT``. That is what lets a partial ``lsof`` be completed by this
    fallback instead of abstaining: an omitted pid that /proc does not know is a
    pid that is genuinely gone, not a gap in the reading.
    """
    if not os.path.isdir(proc_root):
        return {}, False
    m: Dict[str, str] = {}
    for pid in pids:
        try:
            m[pid] = os.readlink(os.path.join(proc_root, pid, "cwd"))
        except FileNotFoundError:
            continue          # proven gone — an answer, not a gap in the read
        except OSError:
            return {}, False  # refused — never evidence of absence
    return m, True


def live_pids_in_worktree(target: str, pgrep_bin: str, lsof_bin: str,
                          proc_root: str = DEFAULT_PROC_ROOT) -> Tuple[List[int], bool]:
    """``(pids, readable)`` — live pi processes whose cwd IS ``target``.

    ``readable`` is False unless EVERY live pid was answered (see `pi_cwds`): a
    partial read must abstain, never conclude that no process holds the worktree.
    """
    pids, ok = pi_pids(pgrep_bin)
    if not ok:
        return [], False
    cwds, ok = pi_cwds(pids, lsof_bin, proc_root)
    if not ok:
        return [], False
    hits = [int(p) for p, cwd in cwds.items() if _real(cwd) == target]
    return sorted(hits), True


# ── read 3: the cmux workspace record (corroborating, INBOUND) ───────────
def read_cmux(cmux_bin: str) -> Tuple[Optional[List[dict]], bool]:
    """``(rows, readable)`` from ``cmux list-workspaces --json``.

    A failed or unparseable read is ``readable=False`` — never an empty roster.
    The CLI is unusable from launchd (see the module docstring); this read is
    therefore best-effort and its absence is stated in the proof, not treated as
    evidence.
    """
    if not (shutil.which(cmux_bin) or os.path.exists(cmux_bin)):
        return None, False
    rc, out = _run([cmux_bin, "list-workspaces", "--json"], timeout=45)
    if rc != 0 or not out.strip():
        return None, False
    try:
        data = json.loads(out)
    except ValueError:
        return None, False
    rows = data if isinstance(data, list) else data.get("workspaces") if isinstance(data, dict) else None
    if not isinstance(rows, list) or not rows:
        return None, False
    return [r for r in rows if isinstance(r, dict)], True


def _epoch(val) -> Optional[float]:
    """A timestamp from epoch seconds, epoch millis, or an ISO-8601 string.

    Never 0: an unparsed stamp must not read as "1970", which every recency test
    would reject — the same trap `scripts/lane-status.py`'s `_submitted_epoch`
    documents. ``None`` means "not established".
    """
    if val is None or isinstance(val, bool):
        return None
    if isinstance(val, (int, float)):
        v = float(val)
        if v <= 0:
            return None
        return v / 1000.0 if v > 1e11 else v
    if isinstance(val, str):
        s = val.strip()
        if not s:
            return None
        try:
            v = float(s)
            return (v / 1000.0 if v > 1e11 else v) if v > 0 else None
        except ValueError:
            pass
        try:
            dt = datetime.datetime.fromisoformat(s.replace("Z", "+00:00"))
        except ValueError:
            return None
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=datetime.timezone.utc)
        return dt.timestamp()
    return None


def cmux_worktree_activity(rows: List[dict], target: str, now_s: float,
                           recent_s: float) -> List[dict]:
    """Workspaces rooted at ``target`` with their newest recorded activity.

    ``latest_submitted_at`` is INBOUND (something was sent to the lane) and
    ``updated_at`` is the workspace record's own write time; EITHER inside
    ``recent_s`` counts as recent activity. Both are reported so a reader can
    see which one fired.
    """
    out = []
    for row in rows:
        cwd = row.get("current_directory") or row.get("cwd") or row.get("directory")
        if not isinstance(cwd, str) or _real(cwd) != target:
            continue
        sub = _epoch(row.get("latest_submitted_at"))
        upd = _epoch(row.get("updated_at"))
        newest = max([t for t in (sub, upd) if t is not None], default=None)
        msg = row.get("latest_submitted_message")
        out.append({
            "workspace": str(row.get("id") or row.get("uuid") or ""),
            "title": str(row.get("title") or row.get("name") or ""),
            "latest_submitted_at": sub,
            "updated_at": upd,
            "recent": bool(newest is not None and (now_s - newest) <= recent_s),
            "latest_submitted_message": (msg.strip()[:120] if isinstance(msg, str) else None),
        })
    return out


# ── read 2: the fleet's ONE liveness predicate, per lane on the worktree ─
def lanes_on_worktree(store: str, sessions_dir: str, task_sessions: str,
                      cmux_state: str, target: str, now_ms: int) -> Tuple[List[dict], bool]:
    """``(lanes, store_readable)`` — every lane record whose cwd is ``target``.

    The population comes from ``lane_liveness.enumerate_lanes`` (the durable
    hook store, one lane per workspace, newest NON-CHILD record) and the verdict
    from ``lane_liveness.verdict_for`` — the SAME predicate the scheduled report
    and the kill-path reaper consume. Nothing about liveness is re-derived here.
    """
    store_ok, sessions = liveness.load_store(store)
    if not store_ok:
        return [], False
    lib = os.environ.get("PI_PID_IDENTITY_LIB") or liveness.lib_path()
    children = lane_liveness.child_sids(task_sessions)
    lanes = lane_liveness.enumerate_lanes(sessions, children)
    # ⛔ NO open-workspace FILTER HERE, AND THAT IS THE FAIL-CLOSED DIRECTION.
    # The scheduled report drops closed panes so a retired workspace is not
    # reported on; a successor preflight must not USE that filter to shrink the
    # set of lanes it will refuse for. A lane record for this worktree that is
    # not provably `dead` blocks the dispatch whether or not cmux still lists
    # the pane — over-blocking is friction, under-blocking is a second lane on a
    # live unit. The filter is reported per lane as `workspace_open` instead.
    open_ids = lane_liveness.open_workspace_ids(cmux_state)
    out = []
    for lane in lanes:
        cwd = lane.record.get("cwd")
        if not isinstance(cwd, str) or _real(cwd) != target:
            continue
        verdict, ev = lane_liveness.verdict_for(
            lane, store_path=store, sessions_dir=sessions_dir, lib=lib, now_ms=now_ms,
        )
        age = lane_liveness.last_activity_age_ms(ev)
        out.append({
            "workspace": lane.workspace,
            "sid": lane.sid,
            "name": lane.name,
            "state": verdict.state,
            "reason": verdict.reason,
            "holder_pid": verdict.holder_pid,
            "age_ms": age,
            "workspace_open": (None if open_ids is None else lane.workspace in open_ids),
        })
    return out, True


def decide(process_pids: List[int], process_readable: bool,
           lanes: List[dict], store_readable: bool,
           cmux_rows: Optional[List[dict]], cmux_activity: List[dict]) -> Tuple[str, List[str]]:
    """The ladder in the module docstring. Returns ``(verdict, why)``."""
    why: List[str] = []
    # A live process is POSITIVE evidence and is reported first: it proves an
    # owner whether or not the store can be read.
    if process_pids:
        why.append("live-pi-cwd:" + ",".join(str(p) for p in process_pids))
        return LIVE, why
    if not store_readable:
        return UNKNOWN, ["store-unreadable"]
    live_lanes = [l for l in lanes if l["state"] != "dead"]
    if live_lanes:
        why.append("live-lane-record:" + ",".join(
            "%s=%s" % (l["sid"][:8], l["state"]) for l in live_lanes))
        return LIVE, why
    recent = [a for a in cmux_activity if a.get("recent")]
    if recent:
        why.append("recent-cmux-inbound:" + ",".join(a["workspace"][:8] for a in recent))
        return LIVE, why
    if not process_readable:
        # The worktree read could not be taken; lanes alone cannot prove absence
        # of a process whose record the store never had.
        return UNKNOWN, ["process-read-unreadable"]
    why.append("no-live-witness:%s" % (
        "%d-lane-record(s),all-dead" % len(lanes) if lanes else "no-lane-record"))
    if cmux_rows is None:
        why.append("cmux-unread:corroborating-only")
    return GONE, why


def _iso(now_s: float) -> str:
    return datetime.datetime.fromtimestamp(now_s, datetime.timezone.utc) \
        .strftime("%Y-%m-%dT%H:%M:%SZ")


def render_block(target: str, now_s: float, verdict: str, why: List[str],
                 process_pids: List[int], process_readable: bool,
                 lanes: List[dict], store_readable: bool, cmux_readable: bool,
                 cmux_activity: List[dict], recent_s: float,
                 readers: Optional[Dict[str, str]] = None) -> str:
    """The proof block a dispatch file must carry (#1317)."""
    lines = [
        "--- successor-preflight (#1317) ---",
        "verdict: %s" % verdict,
        "target-worktree: %s" % target,
        "read-at: %s" % _iso(now_s),
        "why: %s" % " ".join(why),
    ]
    if readers:
        # Name the READERS, not just the reading: an inherited env seam (or a
        # non-default flag) changes what was read, and the proof is worthless if
        # it reads as though the default tool had answered.
        lines.append("readers: %s" % " ".join(
            "%s=%s" % (k, readers[k]) for k in sorted(readers)))
    if not process_readable:
        labels = "process-read: UNREADABLE (pgrep/lsof could not answer)"
    elif process_pids:
        labels = "process-read: live pi pid(s) %s" % ",".join(str(p) for p in process_pids)
    else:
        labels = "process-read: no live pi rooted in this worktree"
    lines.append(labels)
    if not store_readable:
        lines.append("lanes: store UNREADABLE")
    elif not lanes:
        lines.append("lanes: no lane record for this worktree")
    else:
        lines.append("lanes: %d record(s), states %s" % (
            len(lanes), ",".join("%s:%s" % (l["sid"][:8], l["state"]) for l in lanes)))
        for l in lanes:
            age = "?" if l["age_ms"] is None else "%ds" % (l["age_ms"] // 1000)
            lines.append("  - ws=%s sid=%s name=%r state=%s reason=%s holder=%s age=%s" % (
                l["workspace"], l["sid"], l["name"], l["state"], l["reason"],
                l["holder_pid"], age))
    if not cmux_readable:
        lines.append("cmux: unread (corroborating only — never decides the verdict)")
    elif not cmux_activity:
        lines.append("cmux: read ok, no workspace rooted at this worktree")
    else:
        lines.append("cmux: read ok, %d workspace(s) rooted here (recent window %ds)" % (
            len(cmux_activity), int(recent_s)))
        for a in cmux_activity:
            lines.append("  - ws=%s title=%r recent=%s latest_submitted_at=%s updated_at=%s" % (
                a["workspace"], a["title"], a["recent"],
                a["latest_submitted_at"], a["updated_at"]))
    lines.append("decision: %s" % {
        GONE: "dispatch a successor — the unit is free",
        LIVE: "do NOT dispatch a successor — nudge the live lane, or wait",
        UNKNOWN: "could not verify — fail closed, do not dispatch",
    }[verdict])
    lines.append("--- end successor-preflight ---")
    return "\n".join(lines) + "\n"


def parse_args(argv: Optional[Sequence[str]] = None) -> argparse.Namespace:
    ap = argparse.ArgumentParser(
        prog="successor_preflight.py",
        description="Prove a predecessor lane is gone before a successor is dispatched (#1317).",
    )
    ap.add_argument("--worktree", required=True,
                    help="the target worktree the successor would be sent to")
    ap.add_argument("--emit", default=None,
                    help="APPEND the proof block to this file (the dispatch file)")
    ap.add_argument("--json", action="store_true", help="emit the proof as JSON on stdout")
    ap.add_argument("--now", type=float, default=None, help="pin the clock (epoch seconds) — tests only")
    ap.add_argument("--recent-s", type=float, default=DEFAULT_RECENT_S,
                    help="cmux recency window in seconds (default %d)" % DEFAULT_RECENT_S)
    ap.add_argument("--store", default=os.environ.get("LANE_LIVENESS_STORE", lane_liveness.DEFAULT_STORE))
    ap.add_argument("--sessions-dir",
                    default=os.environ.get("LANE_LIVENESS_SESSIONS_DIR", lane_liveness.DEFAULT_SESSIONS_DIR))
    ap.add_argument("--task-sessions",
                    default=os.environ.get("LANE_LIVENESS_TASK_SESSIONS", lane_liveness.DEFAULT_TASK_SESSIONS))
    ap.add_argument("--cmux-state",
                    default=os.environ.get("LANE_LIVENESS_CMUX_STATE", lane_liveness.DEFAULT_CMUX_STATE))
    ap.add_argument("--pgrep-bin", default=os.environ.get("SUCCESSOR_PGREP_BIN", "pgrep"))
    ap.add_argument("--lsof-bin", default=os.environ.get("SUCCESSOR_LSOF_BIN", "lsof"))
    ap.add_argument("--cmux-bin", default=os.environ.get("SUCCESSOR_CMUX_BIN", "cmux"))
    ap.add_argument("--proc-root", default=os.environ.get("SUCCESSOR_PROC_ROOT", DEFAULT_PROC_ROOT),
                    help="procfs root for the cwd fallback (default %s)" % DEFAULT_PROC_ROOT)
    return ap.parse_args(argv)


def main(argv: Optional[Sequence[str]] = None) -> int:
    ns = parse_args(argv)
    if not str(ns.worktree).strip():
        print("successor-preflight: --worktree is required", file=sys.stderr)
        return 2
    target = _real(ns.worktree)
    # NOTHING WAS DECIDED if the target is not a readable directory. A path that
    # does not exist is not a predecessor proven gone: reporting GONE (exit 0)
    # for it makes "no such directory" indistinguishable from a proof, inside the
    # artifact that exists to make exactly that distinction. Documented as exit 2
    # ("nothing was decided").
    if not os.path.isdir(target):
        print("successor-preflight: --worktree %s is not a readable directory — "
              "nothing was decided, do not dispatch on this reading" % ns.worktree,
              file=sys.stderr)
        return 2
    now_s = ns.now if ns.now is not None else datetime.datetime.now().timestamp()
    now_ms = int(now_s * 1000)

    lane_liveness.install_ps_cache()   # one `ps` read per pass, as the report uses

    process_pids, process_readable = live_pids_in_worktree(
        target, ns.pgrep_bin, ns.lsof_bin, ns.proc_root)
    lanes, store_readable = lanes_on_worktree(
        ns.store, ns.sessions_dir, ns.task_sessions, ns.cmux_state, target, now_ms)
    cmux_rows, cmux_readable = read_cmux(ns.cmux_bin)
    cmux_activity = (cmux_worktree_activity(cmux_rows, target, now_s, ns.recent_s)
                     if cmux_rows is not None else [])
    verdict, why = decide(process_pids, process_readable, lanes, store_readable,
                          cmux_rows, cmux_activity)

    readers = {
        "pgrep": ns.pgrep_bin,
        "lsof": ns.lsof_bin,
        "cmux": ns.cmux_bin,
        "proc-root": ns.proc_root,
        "store": ns.store,
    }

    if ns.json:
        print(json.dumps({
            "verdict": verdict,
            "target_worktree": target,
            "read_at": _iso(now_s),
            "why": why,
            "readers": readers,
            "process_readable": process_readable,
            "live_pids": process_pids,
            "store_readable": store_readable,
            "lanes": lanes,
            "cmux_readable": cmux_readable,
            "cmux_activity": cmux_activity,
            "recent_s": ns.recent_s,
        }, sort_keys=True))
    else:
        print(render_block(target, now_s, verdict, why, process_pids, process_readable,
                           lanes, store_readable, cmux_readable, cmux_activity,
                           ns.recent_s, readers), end="")

    if ns.emit:
        block = render_block(target, now_s, verdict, why, process_pids, process_readable,
                             lanes, store_readable, cmux_readable, cmux_activity,
                             ns.recent_s, readers)
        try:
            with open(ns.emit, "a", encoding="utf-8") as fh:
                fh.write("\n" + block)
        except OSError as exc:
            print("successor-preflight: cannot emit to %s: %s" % (ns.emit, exc), file=sys.stderr)
            return 2

    return {GONE: 0, LIVE: 3, UNKNOWN: 4}[verdict]


if __name__ == "__main__":
    sys.exit(main())
