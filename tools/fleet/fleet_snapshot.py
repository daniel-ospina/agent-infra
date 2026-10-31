#!/usr/bin/env python3
"""tools/fleet/fleet_snapshot.py — ONE command, every box: capacity + lanes.

WHY THIS EXISTS (and what it is NOT)
------------------------------------
A coordinator measured "live lanes / load / free slots" with a DIFFERENT
hand-rolled probe per box: `ps -Ao pid,command` argv-matching on the mac,
`ps -eo args | grep -cE '[l]ane\\.sh|pi -p'` on the cells, a bare
`ps | grep 'pi .*--print'` that returned **0 on a box running 9 lanes**, and
log-mtime as a liveness signal — which read a lane **83 minutes deep in one bash
call** as dead (it was alive and bisecting). The numbers were therefore not
comparable between boxes, and two of them were simply wrong.

That is the defect this file closes, and it closes it in ONE direction only:

* **it is NOT a second opinion.** Every per-lane state comes from
  ``liveness.evaluate`` — the SAME predicate the kill-path reaper sources
  (``scripts/lib/pid-identity.sh``) — fed by ``liveness.gather`` (cmux
  population) or ``liveness.gather_dispatch`` (dispatch population, which is
  *acquisition*, not classification). This file decides no state, forks no
  `os.kill`-adjacent probe, and never re-implements "wedged".
* **it does NOT read load/memory/disk with its own probe.** That is
  ``scripts/orchestrator-harness/capacity.sh probe`` — the reviewed cross-box
  capacity probe that already has both platform branches. Re-using it is the
  same rule as re-using the predicate: one reading per question. This file adds
  exactly two things capacity.sh does not carry: **swap used %** (a metric, not
  an opinion about lanes) and **the box's own derived ``MAX_LANES``**, mirrored
  from ``ai-drainer.sh``/``orch-loop.sh`` (``_NCPU * 5 / 2`` floored, fallback
  10, bounded 1..100) rather than invented.

TWO POPULATIONS, ONE PREDICATE (the #1178 contradiction test)
-------------------------------------------------------------
#1178's rule is about **predicates**: "two contracts for one safety rule" is the
defect. It is NOT a rule that the fleet may have only one population, and reading
it that way is what produced a report that could not see a live lane. So:

    population (which lanes exist)   ->  per population, ONE durable source
    predicate  (what state a lane is) ->  liveness.evaluate, for ALL populations

  cmux      the cmux hook store (``~/.cmuxterm/pi-hook-sessions.json``), one lane
            per workspace. Durable: a lane whose process is gone stays
            enumerated. Unchanged behaviour, via ``liveness.gather``.
  dispatch  a lane the orchestrator dispatched as ``pi -p`` — no cmux workspace,
            no hook-store record, so it is in NO population the cmux report can
            build BY CONSTRUCTION. Enumerated from its **durable session
            transcript** (the same durability property the store supplies: the
            JSONL outlives the process), and its incarnation — when one is bound
            — is read with the SAME probe CLI.

The population decision, stated as the thing it buys and the thing it costs:

* **Which durable source, and why.** The transcript, not the process table. A
  live-process population makes a dead lane *disappear*, which is the exact hole
  #1178 exists to remove; a transcript does not, so an exited lane is still
  REPORTED. The claim registry (``refs/claims/<pr>-<sha12>``) is the other
  durable candidate and is already read by ``claim_lanes.py``; it is not used
  here because every claim verdict is a declared ABSTENTION (no probeable
  incarnation) and it only names PR-scoped lanes.
* **How a lane that has exited is still reported.** Its row survives (the
  transcript is on disk) and reads ``unknown/no-bound-incarnation`` with the
  transcript's last-write age in the detail. **``dead`` is NOT reachable for this
  population** and that is deliberate: ``dead`` requires a fenced incarnation
  positively observed absent (#1178 C1), and a dispatch lane has no durable pid
  to fence — the same position the ref-claim registry is in. The invariant is
  held by an ARM in ``liveness.evaluate`` (a borrowed incarnation that reads
  ``absent`` is the same abstention), not by there being no case that reaches
  ``dead``: a lane whose bound process exits between the pass's ``/proc`` read
  and its own probe is ordinary fleet life, and it too reads
  ``unknown/no-bound-incarnation``.
* **The bounded staleness, named.** A transcript row is kept while its last
  write is inside the reaper's own idle proof (``liveness.IDLE_MS`` = 24 h) or a
  live process is bound to it. Beyond 24 h the lane is retirement, not a stuck
  lane (the same window ``lane_liveness.py`` uses to withhold escalation), so the
  report is bounded at 24 h of history — that is the declared staleness.

THE BINDING, AND WHY macOS CANNOT DO IT (measured, not assumed)
--------------------------------------------------------------
A dispatch lane's transcript does not name its process, and its process does not
name its session: pi rewrites its own process title, so a ``pi -p`` run appears
in the process table as plain ``pi`` — while the ``-p`` survives only on the
shell wrapper that spawned it (measured 2026-10-30: pid 77233
``/bin/zsh -ic … exec …/bin/pi --no-extensions -p "$(cat /tmp/brief-…)"`` whose
child 77980 is ``pi``). So the ONE deterministic binding is the environment the
dispatcher hands the process:

  * **Linux (/ cells):** ``/proc/<pid>/environ`` carries ``PI_SESSION_FILE`` /
    ``PI_SESSION_ID``. Read per candidate pid only (never all ~2000 of them).
  * **macOS:** there is no ``/proc``, and ``ps -Eww -p <pid>`` reports **no
    environment** for a pi process (measured on the box's own live lane: the
    output is 61 bytes, ``77980 ttys024 0:05.01 pi``) — ``setproctitle``
    overwrites the argv/env area. The mac therefore reports
    ``UNMEASURED(<why>)`` for the binding and every dispatch row abstains.

⛔ No fallback identity rule was added to make the mac look complete. A
content-match (matching a live wrapper's brief text to a transcript's first user
message) would be a SECOND identity rule and could attach a live pid to the wrong
transcript — a false WORKING on a wedged lane, which is the fail-open direction
#1178 forbids. ``UNMEASURED`` is the correct answer.

⚠️ THE FIX, IF THE MAC MATTERS: have the dispatcher name the session
(``pi --session <uuid>`` or ``PI_SESSION_ID=<uuid>`` in the wrapper), which is a
dispatcher change and not this file's to make.

DEGRADATION CONTRACT: a datum that cannot be read is ``UNMEASURED(<why>)`` —
never ``0``, never an empty list rendered as "nothing is running". Measured
2026-10-30: macOS has no ``free``, no ``/proc``, and ``ps -eo etimes`` is absent.

USAGE (identical on both platforms; the box is an ARGUMENT, not a shape)
-----------------------------------------------------------------------
    python3 tools/fleet/fleet_snapshot.py                       # text
    python3 tools/fleet/fleet_snapshot.py --json                # identical shape
    python3 tools/fleet/fleet_snapshot.py --box cell-3 --json    # label the row

Exit codes: 0 = measured (whatever the states), 2 = usage error. NEVER 1: this
is a report, not a gate, and a red exit for "one lane is wedged" would make the
caller read a state as an error.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import time
from typing import Dict, List, Optional, Sequence, Tuple

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

try:
    import liveness  # noqa: E402
except ImportError as _exc:  # pragma: no cover - env dependent
    sys.stderr.write("fleet-snapshot: FATAL: cannot import liveness.py next to this file (%s)\n" % _exc)
    raise SystemExit(2)

HOME = os.path.expanduser("~")
DEFAULT_SESSIONS_DIR = os.path.join(HOME, ".pi", "agent", "sessions")
DEFAULT_STORE = os.path.join(HOME, ".cmuxterm", "pi-hook-sessions.json")
DEFAULT_TASK_SESSIONS = os.path.join(HOME, ".pi", "agent", "task-sessions")
# The reviewed box-metrics probe (both platform branches live there). Relative to
# this file so a farmed copy resolves inside the TCC wall, exactly as
# `liveness.lib_path()` does for the identity library.
CAPACITY_SH = os.path.normpath(
    os.path.join(HERE, "..", "..", "scripts", "orchestrator-harness", "capacity.sh")
)

U = "UNMEASURED"


def unmeasured(why: str) -> str:
    return "%s(%s)" % (U, why)


# ── box metrics (capacity.sh reuse + two mirrored derivations) ────────────
def capacity_probe(path: Optional[str] = None, timeout: int = 60) -> Tuple[Optional[Dict[str, str]], str]:
    """``capacity.sh probe`` as a dict, or ``(None, why)`` — never a guess."""
    sh = path or os.environ.get("FLEET_CAPACITY_SH") or CAPACITY_SH
    if not os.path.isfile(sh):
        return None, unmeasured("capacity.sh not installed at %s" % sh)
    try:
        proc = subprocess.run(["bash", sh, "probe"], stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, timeout=timeout, check=False)
    except (OSError, subprocess.SubprocessError) as exc:
        return None, unmeasured("capacity.sh probe could not run: %s" % exc.__class__.__name__)
    out = proc.stdout.decode("utf-8", "replace").strip()
    fields: Dict[str, str] = {}
    for token in out.split():
        if "=" in token:
            k, v = token.split("=", 1)
            fields[k] = v
    if not fields or "host" not in fields:
        return None, unmeasured("capacity.sh probe returned no fields (rc=%d)" % proc.returncode)
    return fields, ""


def swap_used_pct(meminfo: str = "/proc/meminfo", sysctl: Optional[str] = None) -> Tuple[Optional[int], str]:
    """Swap used, as a percentage of swap total. Both platform branches, no shell.

    Linux: ``/proc/meminfo`` ``SwapTotal``/``SwapFree`` (kB). macOS: ``sysctl -n
    vm.swapusage`` → ``total = 2048.00M  used = 1000.00M  free = …``. A box with
    NO swap configured has no percentage to report and says so — ``0`` would read
    as "no pressure", which is the opposite claim.
    """
    try:
        with open(meminfo, "r", encoding="utf-8") as fh:
            text = fh.read()
    except OSError:
        text = ""
    if text:
        total = free = None
        for line in text.splitlines():
            m = re.match(r"^SwapTotal:\s+(\d+)\s*kB", line)
            if m:
                total = int(m.group(1))
            m = re.match(r"^SwapFree:\s+(\d+)\s*kB", line)
            if m:
                free = int(m.group(1))
        if total is None or free is None:
            return None, unmeasured("meminfo has no swap fields")
        if total == 0:
            return None, unmeasured("no swap configured")
        return int(round((total - free) * 100.0 / total)), ""
    cmd = [sysctl or "/usr/sbin/sysctl", "-n", "vm.swapusage"]
    try:
        proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              timeout=20, check=False)
    except (OSError, subprocess.SubprocessError) as exc:
        return None, unmeasured("no /proc/meminfo and sysctl unusable: %s" % exc.__class__.__name__)
    out = proc.stdout.decode("utf-8", "replace").strip()
    total_m = re.search(r"total\s*=\s*([\d.]+)M", out)
    used_m = re.search(r"used\s*=\s*([\d.]+)M", out)
    if not (total_m and used_m):
        return None, unmeasured("vm.swapusage unparseable: %r" % out[:60])
    total_v, used_v = float(total_m.group(1)), float(used_m.group(1))
    if total_v <= 0:
        return None, unmeasured("no swap configured")
    return int(round(used_v * 100.0 / total_v)), ""


def max_lanes(ncpu_raw) -> Tuple[Optional[int], str]:
    """The box's OWN lane ceiling: ``_NCPU * 5 / 2`` floored, fallback 10, 1..100.

    Mirrored from ``ai-drainer.sh`` (whose comment cites ``orch-loop.sh`` /
    ``install.sh``): the drainer and the controller must agree about what a box of
    N cores may run, so this file copies the derivation instead of inventing one.
    ⛔ The product is BOUNDED, not just the probe: a 9-digit core count would turn
    ``× 5 / 2`` into a ten-digit lane count, so an out-of-range product falls back
    to the same 10 the shell falls back to.
    """
    try:
        ncpu = int(str(ncpu_raw).strip())
    except (TypeError, ValueError):
        return 10, "ncpu unreadable — the shell's own fallback (10)"
    if ncpu < 1:
        return 10, "ncpu=%d out of range — the shell's own fallback (10)" % ncpu
    derived = ncpu * 5 // 2
    if derived < 1 or derived > 100:
        return 10, "derived %d out of range — the shell's own fallback (10)" % derived
    return derived, ""


def box_report(box: Optional[str], capacity_path: Optional[str] = None) -> Dict[str, object]:
    fields, why = capacity_probe(capacity_path)
    pct, pct_why = swap_used_pct()
    out: Dict[str, object] = {"box": box or None}
    if fields is None:
        out["metrics"] = {"state": why}
        out["max_lanes"] = {"value": None, "why": why}
        out["swap_used_pct"] = {"value": None, "why": pct_why}
        return out
    host = fields.get("host") or box or "?"
    def num(key):
        val = fields.get(key)
        try:
            return int(val)
        except (TypeError, ValueError):
            return None
    ml, ml_why = max_lanes(fields.get("ncpu"))
    out["box"] = box or host
    out["host"] = host
    out["metrics"] = {
        "ncpu": num("ncpu"),
        "load1": None if num("load1") is None else num("load1") / 100.0,
        "load_per_cpu": None if num("lpc") is None else num("lpc") / 100.0,
        "mem_free_mb": num("mem_free_mb"),
        "disk_free_mb": num("disk_free_mb"),
        "procs": num("procs"),
        "fork_ok": num("fork"),
        "src": fields.get("src") or None,
    }
    out["swap_used_pct"] = {"value": pct, "why": pct_why}
    out["max_lanes"] = {"value": ml, "why": ml_why, "source": "ai-drainer.sh _NCPU*5/2 (floored)"}
    return out


# ── the dispatch population (durable, transcript-enumerated) ──────────────
SID_RE = re.compile(r"_([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jsonl$")


def transcript_sids(sessions_dir: str = DEFAULT_SESSIONS_DIR) -> Dict[str, Tuple[str, float]]:
    """sid -> (path, mtime) for every session transcript on this box.

    A directory listing, not a walk of the tree's contents: ``sessions/`` is one
    directory per cwd, each holding ``<ts>_<sid>.jsonl``.
    """
    found: Dict[str, Tuple[str, float]] = {}
    try:
        dirs = os.listdir(sessions_dir)
    except OSError:
        return found
    for d in dirs:
        full = os.path.join(sessions_dir, d)
        try:
            names = os.listdir(full)
        except OSError:
            continue
        for name in names:
            m = SID_RE.search(name)
            if not m:
                continue
            path = os.path.join(full, name)
            try:
                mtime = os.stat(path).st_mtime
            except OSError:
                continue
            sid = m.group(1)
            prev = found.get(sid)
            if prev is None or mtime > prev[1]:
                found[sid] = (path, mtime)
    return found


def proc_bindings(root: str = "/proc") -> Tuple[Dict[str, int], str]:
    """pid -> sid, from the environment the dispatcher handed each pi process.

    Read ONLY for pids that look like pi (``/proc/<pid>/comm``), so this costs a
    handful of reads on a box with thousands of processes — the 8 GB cell budget
    in the PR -- and returns ``({}, UNMEASURED(...))`` when the platform has no
    ``/proc`` rather than guessing from a process title pi itself rewrote.
    """
    if not os.path.isdir(root):
        return {}, unmeasured(
            "no /proc on this platform, and pi rewrites its process title so `ps -E` "
            "reports no environment for it (measured 2026-10-30)"
        )
    bindings: Dict[str, int] = {}
    try:
        entries = os.listdir(root)
    except OSError as exc:
        return {}, unmeasured("/proc unreadable: %s" % exc.__class__.__name__)
    for entry in entries:
        if not entry.isdigit():
            continue
        pid = int(entry)
        base = os.path.join(root, entry)
        try:
            with open(os.path.join(base, "comm"), "r", encoding="utf-8", errors="replace") as fh:
                comm = fh.read().strip()
        except OSError:
            continue
        # `pi` (title-rewritten) and `node` (a pi launched before the title write)
        # are the two shapes measured on this fleet; anything else is not a lane.
        if comm not in ("pi", "node", "Pi"):
            continue
        try:
            with open(os.path.join(base, "environ"), "rb") as fh:
                blob = fh.read(131072)
        except OSError:
            continue
        for chunk in blob.split(b"\0"):
            if chunk.startswith(b"PI_SESSION_ID="):
                sid = chunk.split(b"=", 1)[1].decode("utf-8", "replace").strip()
                if sid:
                    bindings[sid] = pid
                break
    return bindings, ""


def dispatch_lanes(
    *,
    sessions_dir: str = DEFAULT_SESSIONS_DIR,
    store_path: str = DEFAULT_STORE,
    task_sessions: str = DEFAULT_TASK_SESSIONS,
    within_ms: int = liveness.IDLE_MS,
    now_ms: Optional[int] = None,
    bindings: Optional[Dict[str, int]] = None,
    lib: Optional[str] = None,
    limit: int = 60,
) -> Tuple[List[Dict[str, object]], Dict[str, object]]:
    """The dispatch population + the declaration of what it could not see.

    Enumerated from DURABLE transcripts (a lane that exited stays enumerated),
    excluding everything the cmux population already owns and every task child.
    """
    now = int(now_ms if now_ms is not None else time.time() * 1000)
    store_ok, sessions = liveness.load_store(store_path)
    try:
        children = frozenset(n for n in os.listdir(task_sessions)
                             if os.path.isdir(os.path.join(task_sessions, n)))
    except OSError:
        children = frozenset()
    if bindings is None:
        bindings, bind_why = proc_bindings()
    else:
        bind_why = ""
    sids = transcript_sids(sessions_dir)

    rows: List[Dict[str, object]] = []
    considered = stale = claimed = 0
    for sid, (path, mtime) in sids.items():
        if sid in children:
            continue
        if store_ok and sid in sessions:
            claimed += 1
            continue
        considered += 1
        age_ms = max(0, int(now - mtime * 1000))
        pid = bindings.get(sid)
        if pid is None and age_ms > within_ms:
            stale += 1
            continue
        ev = liveness.gather_dispatch(sid, pid=pid, transcript=path, sessions_dir=sessions_dir,
                                      lib=lib, now_ms=now)
        v = liveness.evaluate(ev)
        rows.append({
            "population": liveness.DISPATCH_POPULATION,
            "lane": os.path.basename(os.path.dirname(path)),
            "sid": sid,
            "pid": pid,
            "transcript_age_s": age_ms // 1000,
            "state": v.state,
            "reason": v.reason,
            "holder_pid": v.holder_pid,
            "evidence": v.detail or ev.dispatch_detail,
        })
    # `dead` is unreachable for this population by construction (the borrowed-
    # incarnation arm in liveness.evaluate), so this key is an ordering habit, not
    # a reachable case — kept so a future change that DID make `dead` reachable
    # would still sort the false DEAD first rather than bury it.
    rows.sort(key=lambda r: (r["state"] != "dead", r["state"] != "wedged", -int(r["transcript_age_s"])))
    declaration = {
        "population": liveness.DISPATCH_POPULATION,
        "source": "durable session transcripts not claimed by the cmux population, minus task children",
        "binding": bind_why or "pid -> PI_SESSION_ID from /proc/<pid>/environ",
        "considered": considered,
        "reported": len(rows),
        "claim_bound": len([r for r in rows if r["pid"]]),
        "withheld_stale": stale,
        "excluded_cmux_claimed": claimed,
        "dead_reachable": False,
        "dead_note": ("a dispatch lane has no durable fenced incarnation, so `dead` is "
                      "unreachable by design (#1178 C1) — an unbound lane AND a lane whose "
                      "bound process is no longer listed both report "
                      "`unknown/no-bound-incarnation` with their transcript age"),
        "window_h": within_ms / 3_600_000.0,
    }
    if len(rows) > limit:
        declaration["truncated_from"] = len(rows)
        rows = rows[:limit]
    declaration["reported"] = len(rows)
    return rows, declaration


def cmux_lanes(*, store_path: str = DEFAULT_STORE, sessions_dir: str = DEFAULT_SESSIONS_DIR,
               task_sessions: str = DEFAULT_TASK_SESSIONS, lib: Optional[str] = None,
               now_ms: Optional[int] = None) -> Tuple[List[Dict[str, object]], Dict[str, object]]:
    """The cmux population, verdicts from ``liveness.gather`` + ``evaluate``.

    Reuses ``lane_liveness``'s enumeration (never a second copy of it) so this
    report and the scheduled one can never disagree about which lanes exist.
    """
    try:
        import lane_liveness  # noqa: E402
    except ImportError as exc:  # pragma: no cover - farm dependent
        return [], {"population": liveness.CMUX_POPULATION,
                    "state": unmeasured("lane_liveness.py not importable: %s" % exc)}
    store_ok, sessions = liveness.load_store(store_path)
    if not store_ok:
        return [], {"population": liveness.CMUX_POPULATION,
                    "state": unmeasured("hook store unreadable at %s" % store_path)}
    children = lane_liveness.child_sids(task_sessions)
    lanes = lane_liveness.enumerate_lanes(sessions, children)
    open_ids = lane_liveness.open_workspace_ids()
    if open_ids is not None:
        lanes = [l for l in lanes if l.workspace in open_ids]
    now = int(now_ms if now_ms is not None else time.time() * 1000)
    rows: List[Dict[str, object]] = []
    for lane in lanes:
        ev = liveness.gather(lane.sid, store_path=store_path, sessions_dir=sessions_dir,
                            lib=lib, now_ms=now)
        v = liveness.evaluate(ev)
        rows.append({
            "population": liveness.CMUX_POPULATION,
            "lane": lane.name,
            "sid": lane.sid,
            "workspace": lane.workspace,
            "state": v.state,
            "reason": v.reason,
            "holder_pid": v.holder_pid,
            "evidence": v.detail or (", ".join(v.witnesses) if v.witnesses else ""),
        })
    return rows, {"population": liveness.CMUX_POPULATION,
                  "source": "cmux hook store (one lane per open workspace)",
                  "reported": len(rows),
                  "store": store_path}


# ── render ──────────────────────────────────────────────────────────────
def _install_ps_cache() -> None:
    """One `ps` read per pass, not one per probe — the REVIEWED mechanism.

    ``lane_liveness.install_ps_cache()`` points the identity library's ``PS_BIN``
    at a single-snapshot cache in ``$TMPDIR``. This report probes up to 60 lanes,
    and without it each probe forks its own ``ps -axo``: measured on the mac,
    that difference is 2m46s vs ~2s for one pass over 15 cmux + 25 dispatch
    lanes. Reusing the shipped installer (rather than writing a second cache)
    keeps ONE mechanism, and an explicit ``PS_BIN`` still wins.
    """
    try:
        import lane_liveness  # noqa: E402
    except ImportError:
        return
    try:
        lane_liveness.install_ps_cache()
    except Exception:  # pragma: no cover - a cache we cannot install never fails a report
        return


def counts(rows: Sequence[Dict[str, object]]) -> Dict[str, int]:
    out: Dict[str, int] = {}
    for row in rows:
        out[str(row["state"])] = out.get(str(row["state"]), 0) + 1
    return out


def snapshot(box: Optional[str] = None, *, sessions_dir: str = DEFAULT_SESSIONS_DIR,
             store_path: str = DEFAULT_STORE, task_sessions: str = DEFAULT_TASK_SESSIONS,
             now_ms: Optional[int] = None, lib: Optional[str] = None,
             capacity_path: Optional[str] = None) -> Dict[str, object]:
    """The whole reading for ONE box — the `--json` shape, identical everywhere."""
    _install_ps_cache()
    now = int(now_ms if now_ms is not None else time.time() * 1000)
    report = box_report(box, capacity_path)
    cmux_rows, cmux_decl = cmux_lanes(store_path=store_path, sessions_dir=sessions_dir,
                                      task_sessions=task_sessions, lib=lib, now_ms=now)
    disp_rows, disp_decl = dispatch_lanes(sessions_dir=sessions_dir, store_path=store_path,
                                          task_sessions=task_sessions, now_ms=now, lib=lib)
    return {
        "schema": "fleet-snapshot/1",
        "at": now // 1000,
        "box": report,
        "lanes": {
            liveness.CMUX_POPULATION: {"declaration": cmux_decl, "counts": counts(cmux_rows),
                                       "rows": cmux_rows},
            liveness.DISPATCH_POPULATION: {"declaration": disp_decl, "counts": counts(disp_rows),
                                           "rows": disp_rows},
        },
        "predicate": "liveness.evaluate (gather / gather_dispatch acquire)",
    }


def render_text(snap: Dict[str, object]) -> str:
    box = snap["box"]
    lines: List[str] = []
    m = box.get("metrics") or {}
    swap = box.get("swap_used_pct") or {}
    ml = box.get("max_lanes") or {}
    lines.append("== box %s (host=%s)" % (box.get("box"), box.get("host", "?")))
    if "state" in m:
        lines.append("   metrics: %s" % m["state"])
    else:
        lines.append("   cores=%s load1=%s (%.2f/cpu) mem_free=%sMB disk_free=%sMB procs=%s fork_ok=%s"
                     % (m.get("ncpu"), m.get("load1"), m.get("load_per_cpu") or 0,
                        m.get("mem_free_mb"), m.get("disk_free_mb"), m.get("procs"), m.get("fork_ok")))
    lines.append("   swap_used=%s  max_lanes=%s"
                 % ("%s%%" % swap["value"] if swap.get("value") is not None else swap.get("why", U),
                    ml.get("value") if ml.get("value") is not None else ml.get("why", U)))
    for name, block in (snap["lanes"] or {}).items():
        decl = block.get("declaration") or {}
        c = block.get("counts") or {}
        lines.append("-- population %s: %s lane(s)%s"
                     % (name, sum(c.values()),
                        "" if not c else " [" + " ".join("%s=%d" % kv for kv in sorted(c.items())) + "]"))
        if decl.get("state"):
            lines.append("   %s" % decl["state"])
        if decl.get("source"):
            lines.append("   source: %s" % decl["source"])
        if decl.get("binding"):
            lines.append("   binding: %s" % decl["binding"])
        for row in block.get("rows") or []:
            lines.append("   %-10s %-22s %-14s %s"
                         % (row["state"], str(row["lane"])[:22], row["reason"],
                            str(row.get("evidence") or "")[:80]))
    lines.append("predicate: %s" % snap["predicate"])
    return "\n".join(lines)


def main(argv: Optional[Sequence[str]] = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    box = os.environ.get("FLEET_BOX") or None
    as_json = False
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg == "--json":
            as_json = True; i += 1; continue
        if arg == "--box" and i + 1 < len(argv):
            box = argv[i + 1]; i += 2; continue
        print("usage: fleet_snapshot.py [--box NAME] [--json]", file=sys.stderr)
        return 2
    snap = snapshot(box)
    print(json.dumps(snap, sort_keys=True, indent=2) if as_json else render_text(snap))
    return 0


if __name__ == "__main__":
    sys.exit(main())
