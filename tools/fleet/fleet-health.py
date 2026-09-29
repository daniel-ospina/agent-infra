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
import json, os, subprocess, sys, time, glob

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
        if observed in DEAD_OBSERVED:
            # A positively absent/zombie incarnation: the process is gone, so the
            # transcript ladder has nothing left to add.
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


if __name__ == "__main__":
    sys.exit(main())
