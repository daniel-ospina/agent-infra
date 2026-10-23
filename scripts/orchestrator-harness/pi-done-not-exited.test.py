#!/usr/bin/env python3
"""pi-done-not-exited.test.py — nineteen real process trees, plus the controls the review demanded.

WHY PROCESS FIXTURES AND NOT MOCKS
The bug is a property of REAL PROCESSES — a `pi` whose launcher is blocked on it, a log on its fd 1,
a transcript whose last turn ended. A mocked `ps` would prove the parser, not the detector, and the
measured failure this pattern exists for (a first dry run that would have reaped a 7-minute-old lane)
came from a bad fixture, not from bad code. Every case here is a live tree: a script named `pi` (the
kernel's `comm` is "pi", and it can hold a child), a real launcher script, a real log on fd 1, and a
transcript named the way pi names one.

THE CASES — each guards a different way to be wrong
  1. DONE        completion line + turn-ended transcript + frozen CPU → DONE-NOT-EXITED, reaped, and
                 its launcher writes `.rc` (proof it COMPLETED, not crashed).
  2. LIVE        identical, but its log GROWS inside the sample window → LIVE, survives. The brief's
                 non-vacuity case: a reap-everything detector passes a one-case test.
  3. HUNG        a SUCCESSFUL completion line, but its transcript's last turn is OPEN → HUNG,
                 survives. The folk rule ("completion marker + frozen CPU") would kill it.
  4. ABSTAIN     a completion-shaped log but a `compaction` tail — the canon's ABSTENTION, which
                 carries `stalled=False`. Reading `stalled` alone would kill it (cycle-1 P0).
  5. NOSESSION   NO transcript at all (a `--no-session` lane): the log channel is the ONLY evidence ⇒
                 it must be able to decide on its own, and only when it holds the log exclusively.
  6. SHARED      two `pi` appending to ONE log, no transcripts ⇒ neither may be reaped on that log.
  7. CHILD       DONE-shaped but holding a live child ⇒ LIVE (a child may be real work).
  8. SURVIVE     DONE-shaped but ignores SIGTERM ⇒ the run exits 1 and says `survived 1`.
  9. NO-OWNER    a `pi` under a plain `bash -c` ⇒ UNATTRIBUTABLE `no-owner`, survives.
 10. WEAK        a launcher that INTERPOLATES (`TAG="$N"`, `lane-$N.log` — the shipped shape) names
                 the tag by no basis ⇒ `weak-owner`, report-only.
 11. FRESHLOG    no transcript, a log YOUNGER than `--min-idle` ⇒ not DONE (the bound covers the
                 log-only arm too).
 12. ARGV        the tag ONLY on the launcher's argv (`bash lane-argytag.sh argytag` — `lane.sh <N>`)
                 ⇒ rung `tag`, reaped: the basis that matches every shipped launcher.
 13. INTERACTIVE a lane-shaped `pi` whose launcher does NOT invoke print mode ⇒ refused: an agent at a
                 human's prompt also reaches turn-ended and frozen CPU.
 14. BOUND       a control lane the first pass never reaps (the `--min-idle` bound, both directions).
 15. PEER (×2)   two `pi`, ONE cwd, ONE transcript, started inside the canon's fence ⇒ both are
                 `peer-claimed` and neither may use that boundary — including under `--pid`.
 16. COMMENT     a launcher that mentions print mode ONLY in a whole-line comment ⇒ refused.
 17. TRAILCOMMENT the same mention as a TRAILING comment ⇒ refused too (a trailing comment is not
                 code); this is what pins the `code_only()` increment.

THREE SEQUENTIAL CONTROLS (not fixtures):
  * BOUND      a DONE-shaped lane that the first pass never reaps: not reaped at `--min-idle 100000`,
               reaped at `--min-idle 0` — so the silence bound is enforced in BOTH directions.
  * REPORT-ONLY without `--authorise-hostless` the same row must be left alone and the pass must exit
               4 (a complete pass that found work it was not authorised to do — #2391 is open).
  * REFUSED    the pre-signal re-check must REFUSE a target whose incarnation moved, and the summary
               must say `refused 1` with exit 1 (cycle-1 P1: a refused target was counted as reaped).

`--mutations` re-runs this suite against ELEVEN mutated copies of the tool and requires each to go RED
(fold `abstain` into `stalled`, drop the growth veto, drop the open-turn veto, drop the log-only
arm's silence bound, stop re-asking the log at signal time, grant `tag` for any TAG). Prose cannot prove a
suite has teeth; this can, in CI, which is why the repo's other zero-dep suites carry the same mode.

THE FIXTURES ARE INSULATED FROM THE AMBIENT ANCESTRY. `setsid --fork` makes each launcher a session
leader reparented to init, so the chain is `pi → launcher → init` (`hostless`) whether the suite runs
in a terminal, tmux, or CI; cases are staggered past the canon's ±3 s fence so no two can bind one
transcript. Without either guard this suite is a false RED for a developer inside tmux.

Exit 0 = every assertion held. Non-zero = the first failure printed with its expectation.
"""
from __future__ import annotations

import atexit
import importlib.util
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.realpath(__file__))
TOOL = os.path.join(HERE, "pi-done-not-exited.py")
SCRIPTS = os.path.abspath(os.path.join(HERE, os.pardir))
UUID = "01a1%010x" % os.getpid()
LEADERS: dict = {}          # tag -> launcher pid (a session leader); cleaned up on EVERY exit path
ROOT: list = []             # the temp root, so cleanup() removes it on failure/SIGTERM too (cycle 4)


def cleanup() -> None:
    """Kill each fixture's process group AND remove the temp root. Runs on success, on a failed
    assertion, and on SIGTERM: cycle 1 leaked fixtures because `fail()` exited before the cleanup
    loop, and cycle 4 measured `--mutations` leaving six `/tmp/pi-dne-*` roots behind, because the
    root was only removed on the success path."""
    for pid in list(LEADERS.values()):
        try:
            os.killpg(int(pid), signal.SIGKILL)
        except OSError:
            pass
    LEADERS.clear()
    while ROOT:
        shutil.rmtree(ROOT.pop(), ignore_errors=True)


atexit.register(cleanup)


def _on_signal(signum, _frame) -> None:
    cleanup()
    os._exit(128 + signum)


for _sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
    try:
        signal.signal(_sig, _on_signal)
    except (ValueError, OSError, AttributeError):
        pass


def fail(msg: str) -> None:
    print("FAIL: %s" % msg)
    cleanup()
    sys.exit(1)


def check(cond: bool, msg: str) -> None:
    if not cond:
        fail(msg)
    print("ok   %s" % msg)


def stamp(t: float) -> str:
    """pi's session-file name stamp: `YYYY-MM-DDTHH-MM-SS-mmmZ` (UTC, ms)."""
    return time.strftime("%Y-%m-%dT%H-%M-%S", time.gmtime(t)) + "-%03dZ" % int((t % 1) * 1000)


def write_session(sessions: str, cwd: str, started: float, last_entry: dict) -> str:
    """A transcript named the way pi names one, whose first line carries the cwd the fence checks."""
    d = os.path.join(sessions, "--%s--" % cwd.strip("/").replace("/", "-"))
    os.makedirs(d, exist_ok=True)
    path = os.path.join(d, "%s_%s.jsonl" % (stamp(started), UUID))
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(json.dumps({"type": "session", "cwd": cwd}) + "\n")
        fh.write(json.dumps(last_entry) + "\n")
    return path


TURN_ENDED = {"type": "message", "message": {"role": "assistant", "stopReason": "stop",
                                             "content": [{"type": "text", "text": "done"}]}}
TURN_OPEN = {"type": "message", "message": {"role": "assistant", "stopReason": "toolUse",
                                            "content": [{"type": "toolCall", "id": "call_00_x",
                                                         "name": "bash", "arguments": {}}]}}
TURN_ABSTAIN = {"type": "compaction"}
MARKER = ("[reflect-hook] Hosted tortoise capture OFF (cloud-not-enabled) — session saved instead "
          "of being captured.\n")


def launcher_script(root: str, tag: str, cwd: str, logname: str, *, append: bool = False,
                    ignore_term: bool = False, child: bool = False,
                    no_print: bool = False, comment_mentions: bool = False) -> str:
    """A real lane launcher: TAG exported AND ASSIGNED, `pi` on fd 1, `.rc` written AFTER it exits."""
    log = os.path.join(root, "logs", logname + ".log")
    rc = os.path.join(root, "logs", tag + ".rc")
    trap = "trap '' TERM\n" if ignore_term else ""
    redirect = ">>" if append else ">"
    arg = " child" if child else ""
    pm = "" if no_print else "-p "
    # ⛔ A COMMENT IS NOT PRINT MODE (cycle 5/6). `lane.sh` and `merge-one.sh` both mention print
    # mode in prose, so a launcher that only DOCUMENTS it must not pass the predicate that decides
    # whether an idle interactive agent may be signalled.
    note = ""
    if comment_mentions == "trailing":
        # the increment cycle 6 shipped: a TRAILING comment is not code (cycle 7, P2-1)
        note = ""
    elif comment_mentions:
        note = "# this lane runs pi -p, see run_agent in spawn-gate.sh\n"
    path = os.path.join(root, "lane-%s.sh" % tag)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("#!/bin/bash\n"
                 + note +
                 "export TAG=%s%s\n"
                 "cd %s || exit 4\n"
                 "%s"
                 "%s/pi %s300%s %s %s 2>&1\n"
                 "rc=$?\n"
                 "printf 'EXIT rc=%%s\\n' \"$rc\" >> %s\n"
                 "printf '%%s %%s\\n' \"$rc\" \"$(date -u +%%FT%%TZ)\" > %s\n"
                 % (tag, ("  # this lane runs pi -p here" if comment_mentions == "trailing" else ""),
                    cwd, trap, root, pm, arg, redirect, log, log, rc))
    return path


def launcher_interpolating(root: str, tag: str, cwd: str, logname: str, *,
                           child: bool = False, inherit_tag: bool = False,
                           positional: bool = False) -> str:
    """A launcher shaped like the SHIPPED ones: `TAG="$N"`, redirect `lane-$N.log`.

    ⛔ This is the fixture cycle 3 was missing. `lane.sh` and `nonblocking-dispatch.sh` INTERPOLATE,
    so their text contains neither the tag nor the log's real name — every text basis in
    `ownership()` misses, and the row is `weak` (report-only). The suite's other launchers write the
    tag literally, which is why the rung looked healthy while matching no shipped launcher.
    """
    log = os.path.join(root, "logs", "lane-%s.log" % logname)
    rc = os.path.join(root, "logs", "lane-%s.rc" % logname)
    arg = " child" if child else ""
    path = os.path.join(root, "lane-%s.sh" % tag)
    lines = ["#!/bin/bash"]
    if positional:
        # `lane.sh`'s own shape: the tag arrives as `$1` and everything else interpolates.
        lines += ['N="$1"', 'TAG="$N"', "export TAG"]
    elif not inherit_tag:
        lines += ["N=%s" % logname, 'TAG="$N"', "export TAG"]
    lines += ["cd %s || exit 4" % cwd,
              # ⛔ EVERY redirection interpolates: `lane-$N.log`, `lane-$N.rc`. That is the shipped
              # shape, and it is why no text basis in `ownership()` can name the tag.
              "%s/pi -p 300%s >> %s/logs/lane-$N.log 2>&1" % (root, arg, root),
              "rc=$?",
              "echo \"$rc\" > %s/logs/lane-$N.rc" % root]
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")
    return path


def launch_detached(script: str, cwd: str, pidfile: str, env=None, arg: str = None) -> int:
    """Run the launcher as a session leader reparented to init (ambient ancestry insulation).

    `arg` is passed as the launcher's `$1` — the shipped `lane.sh <N>` shape, where the tag reaches
    the launcher ONLY on its argv.
    """
    subprocess.run(["setsid", "--fork", "bash", "-c",
                    "echo $$ > %s; exec bash %s%s" % (pidfile, script, (" " + arg) if arg else "")],
                   cwd=cwd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False,
                   env=env)
    end = time.time() + 10
    while time.time() < end:
        try:
            pid = int(open(pidfile).read().strip())
            if pid > 1:
                return pid
        except (OSError, ValueError):
            pass
        time.sleep(0.05)
    fail("the detached launcher for %s never recorded its pid" % script)


def child_pi(parent: int, timeout: float = 10.0) -> int:
    """The `pi` that launcher is blocked on — found from the kernel, never from the script text."""
    end = time.time() + timeout
    while time.time() < end:
        for e in os.listdir("/proc"):
            if not e.isdigit():
                continue
            try:
                if open("/proc/%s/comm" % e).read().strip() != "pi":
                    continue
                for line in open("/proc/%s/status" % e):
                    if line.startswith("PPid:") and int(line.split()[1]) == parent:
                        return int(e)
            except (OSError, ValueError):
                continue
        time.sleep(0.05)
    fail("no `pi` child appeared under pid %d within %gs" % (parent, timeout))
    return 0


def run_tool(sessions: str, pids, extra, apply: bool = True):
    cmd = [sys.executable, TOOL, "--json", "--sample", "4", "--min-idle", "60",
           "--sessions-dir", sessions] + extra
    if apply:
        cmd.append("--apply")
    for pid in pids:
        cmd += ["--pid", str(pid)]
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=600)
    rows = {}
    for line in proc.stdout.splitlines():
        line = line.strip()
        if line.startswith("{"):
            r = json.loads(line)
            rows[r["pid"]] = r
    return proc, rows


def main() -> int:
    root = tempfile.mkdtemp(prefix="pi-dne-")
    ROOT.append(root)
    sessions = os.path.join(root, "sessions")
    os.makedirs(os.path.join(root, "logs"))
    os.makedirs(sessions)
    # the fake `pi`: a SCRIPT, so the kernel's `comm` is "pi" AND it can hold a child. It blocks on
    # a FIFO with NO writer, because `sleep` would be a CHILD process and the live-child veto would
    # (correctly) call every fixture LIVE — a real idle `pi` has no children.
    os.mkfifo(os.path.join(root, "fifo"))
    with open(os.path.join(root, "pi"), "w", encoding="utf-8") as fh:
        fh.write("#!/bin/bash\n"
                 "case \"$*\" in *child*) sleep 300 & ;; esac\n"
                 "read -r x < %s/fifo\n" % root)
    os.chmod(os.path.join(root, "pi"), 0o755)
    procs, paths = {}, {}
    leaders = LEADERS

    def case(tag: str, entry, marker: bool = True, transcript: bool = True, logname: str = None,
             append: bool = False, ignore_term: bool = False, child: bool = False,
             fresh_log: bool = False, interpolate: bool = False, positional: bool = False,
             no_print: bool = False, comment_mentions: bool = False) -> int:
        cwd = os.path.join(root, "wt-" + tag)
        os.makedirs(cwd)
        started = time.time()
        ln = tag if logname is None else logname
        script = (launcher_interpolating(root, tag, cwd, ln, child=child, inherit_tag=interpolate,
                                         positional=positional) if interpolate
                  else launcher_script(root, tag, cwd, ln, append=append, ignore_term=ignore_term,
                                       child=child, no_print=no_print,
                                       comment_mentions=comment_mentions))
        # ⛔ WEAK: the TAG is INHERITED from this process, never named by the launcher — the shape
        # cycle 2 measured (`TAG=zombiepi` on a `lane-railprobe.sh` row). A launcher that names the
        # tag (argv, `TAG=`, `<tag>.rc`, or the log it redirects) is `tag`, and correctly so.
        # `N` comes from the environment too, so the launcher's own text interpolates the log's
        # name and never contains it — the shape `lane.sh` has when its worktree slug is not the tag.
        menv = dict(os.environ, TAG=tag, N=ln) if (interpolate and not positional) else None
        leaders[tag] = launch_detached(script, cwd, os.path.join(root, tag + ".leader"), menv,
                                       ln if positional else None)
        pi_pid = child_pi(leaders[tag])
        procs[tag] = pi_pid
        # the interpolating shape writes `lane-<name>.log`, so the marker must land THERE
        logged = os.path.join(root, "logs",
                              ("lane-%s.log" % ln) if interpolate else (ln + ".log"))
        with open(logged, "w", encoding="utf-8") as fh:
            fh.write("the lane's report\n")
            if marker:
                fh.write(MARKER)
        if transcript:
            paths[tag] = write_session(sessions, cwd, started, entry)
            old = time.time() - 600
            os.utime(paths[tag], (old, old))
        if not fresh_log:                     # FRESHLOG keeps a fresh mtime: under --min-idle
            old = time.time() - 600
            os.utime(logged, (old, old))
        time.sleep(3.2)          # stagger past the canon's ±3 s fence: no two cases can share one
        return pi_pid

    case("done", TURN_ENDED)
    case("live", TURN_ENDED)
    case("hung", TURN_OPEN)                                  # completion line + OPEN turn = the trap
    case("abstain", TURN_ABSTAIN, marker=False)              # ABSTAINING boundary, nothing else
    case("nosession", TURN_ENDED, transcript=False)          # --no-session: the log is the only channel
    case("shared", TURN_ENDED, transcript=False, logname="shared")   # two pi on ONE log, appended
    case("shared2", TURN_ENDED, transcript=False, logname="shared", append=True)
    case("child", TURN_ENDED, child=True)                    # DONE-shaped + a live child
    case("survive", TURN_ENDED, ignore_term=True)            # ignores SIGTERM
    case("bound", TURN_ENDED)                                # control: never reaped by pass 1
    weak_pid = case("weak", TURN_ENDED, transcript=False, interpolate=True)   # interpolating launcher ⇒ weak owner
    # ARGV: the ONLY basis is the tag on the launcher's own argv (`bash lane-argv.sh argvtag`),
    # which is the shipped `lane.sh <N>` shape and the basis cycle 3 added.
    argv_pid = case("argvtag", TURN_ENDED, transcript=False, interpolate=True, positional=True)
    case("interactive", TURN_ENDED, transcript=False, no_print=True)   # `pi` with no -p: refused
    case("commentonly", TURN_ENDED, transcript=False, no_print=True, comment_mentions=True)
    case("trailcomment", TURN_ENDED, transcript=False, no_print=True, comment_mentions="trailing")
    case("freshlog", TURN_ENDED, transcript=False, fresh_log=True)

    # ── PEER: two `pi`, ONE cwd, ONE transcript, started inside the canon's fence (cycle 5, P2-2:
    # the stagger that keeps every other case clean is exactly what kept `peer-claimed` unexercised).
    shared_cwd = os.path.join(root, "wt-peer")
    os.makedirs(shared_cwd)
    peer_started = time.time()
    peer_paths = write_session(sessions, shared_cwd, peer_started, TURN_ENDED)
    for tag in ("peerA", "peerB"):
        sp = launcher_script(root, tag, shared_cwd, tag)
        leaders[tag] = launch_detached(sp, shared_cwd, os.path.join(root, tag + ".leader"))
        procs[tag] = child_pi(leaders[tag])
        logged = os.path.join(root, "logs", tag + ".log")
        with open(logged, "w", encoding="utf-8") as fh:
            fh.write("the lane's report\n" + MARKER)
        old = time.time() - 600
        os.utime(logged, (old, old))
    os.utime(peer_paths, (old, old))
    time.sleep(0.6)

    # no-owner: a `pi` under a plain `bash -c`, no launcher script anywhere in the chain
    cwd = os.path.join(root, "wt-noowner")
    os.makedirs(cwd)
    started = time.time()
    leaderfile = os.path.join(root, "noowner.leader")
    subprocess.run(["setsid", "--fork", "bash", "-c",
                    "echo $$ > %s; exec bash -c '%s/pi -p 300 > %s/logs/noowner.log 2>&1'"
                    % (leaderfile, root, root)],
                   cwd=cwd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    end = time.time() + 10
    while time.time() < end:
        try:
            leaders["noowner"] = int(open(leaderfile).read().strip())
            break
        except (OSError, ValueError):
            time.sleep(0.05)
    procs["noowner"] = child_pi(leaders["noowner"])
    with open(os.path.join(root, "logs", "noowner.log"), "w", encoding="utf-8") as fh:
        fh.write("report\n" + MARKER)
    paths["noowner"] = write_session(sessions, cwd, started, TURN_ENDED)
    old = time.time() - 600
    os.utime(os.path.join(root, "logs", "noowner.log"), (old, old))
    os.utime(paths["noowner"], (old, old))
    time.sleep(0.6)

    check(all(open("/proc/%d/comm" % pid).read().strip() == "pi" for pid in procs.values()),
          "every fixture's kernel `comm` is exactly `pi`")

    # the LIVE lane writes to its log INSIDE the sample window — positive liveness evidence
    def keep_writing() -> None:
        # ⛔ SLOW ENOUGH TO SPAN THE TOOL'S OWN STARTUP. Three appends at 0.8/1.6/2.4 s all landed
        # BEFORE the census took its first reading on a loaded box (python + `ps` + a 395-file
        # session index), so the growth veto saw nothing and the fixture read DONE.
        for _ in range(200):
            time.sleep(0.5)
            with open(os.path.join(root, "logs", "live.log"), "a", encoding="utf-8") as fh:
                fh.write("still working: tool output\n")

    writer = threading.Thread(target=keep_writing, daemon=True)
    writer.start()

    tags = ["done", "live", "hung", "abstain", "nosession", "shared", "shared2", "child", "survive",
            "noowner", "weak", "freshlog", "argvtag", "interactive", "peerA", "peerB",
            "commentonly", "trailcomment"]
    pids = [procs[t] for t in tags]
    proc, rows = run_tool(sessions, pids, ["--authorise-hostless"])
    writer.join(timeout=5)
    if proc.returncode not in (0, 1):
        print(proc.stdout[-4000:], proc.stderr[-2000:])
        fail("the tool exited %d (expected 0/1 with one SURVIVOR) — output above" % proc.returncode)

    def cls(tag: str) -> str:
        return rows.get(procs[tag], {}).get("cls", "<missing>")

    def why(tag: str) -> str:
        return rows.get(procs[tag], {}).get("why", "")

    check(cls("done") == "DONE-NOT-EXITED",
          "1/14 DONE: completion line + turn-ended transcript + frozen CPU → DONE-NOT-EXITED "
          "(got %r: %r)" % (cls("done"), why("done")))
    check("turn ENDED" in why("done"), "1/14 DONE: the row names the transcript channel")
    time.sleep(0.5)
    check(not os.path.exists("/proc/%d" % procs["done"]), "1/14 DONE: --apply removed the process")
    rc = os.path.join(root, "logs", "done.rc")
    check(os.path.exists(rc) and open(rc).read().strip(),
          "1/14 DONE: the launcher left `wait` and wrote its .rc (it completed, it did not crash)")

    check(cls("live") == "LIVE" and "GREW" in why("live"),
          "2/14 LIVE: a log growing inside the window is LIVE and says why (got %r: %r)"
          % (cls("live"), why("live")))
    check(os.path.exists("/proc/%d" % procs["live"]),
          "2/14 LIVE: --apply did NOT touch it — a reap-everything detector fails here")

    check(cls("hung") == "HUNG",
          "3/14 HUNG: a completion line does not override an OPEN turn (got %r)" % cls("hung"))
    check(os.path.exists("/proc/%d" % procs["hung"]),
          "3/14 HUNG: --apply did NOT touch a `pi` that is mid-turn")

    check(cls("abstain") == "UNATTRIBUTABLE",
          "4/14 ABSTAIN: an ABSTAINING boundary (tail-after-compaction) is NOT `turn-ended` "
          "(got %r)" % cls("abstain"))
    check(os.path.exists("/proc/%d" % procs["abstain"]),
          "4/14 ABSTAIN: --apply did NOT touch it (the canon's abstention is not a kill licence)")

    check(cls("nosession") == "DONE-NOT-EXITED" and "exclusive log" in why("nosession"),
          "5/14 NOSESSION: with NO transcript, an exclusively-held completion log decides — and the "
          "row says so (got %r: %r)" % (cls("nosession"), why("nosession")))

    check(cls("shared") != "DONE-NOT-EXITED" and cls("shared2") != "DONE-NOT-EXITED",
          "6/14 SHARED: two `pi` on one log authorise nothing, both ways round (got %r/%r)"
          % (cls("shared"), cls("shared2")))
    check(os.path.exists("/proc/%d" % procs["shared"]) and
          os.path.exists("/proc/%d" % procs["shared2"]),
          "6/14 SHARED: neither was reaped")

    check(cls("child") == "LIVE",
          "7/14 CHILD: a `pi` holding a live child is LIVE (got %r)" % cls("child"))
    check(os.path.exists("/proc/%d" % procs["child"]),
          "7/14 CHILD: --apply did NOT touch it")

    check(proc.returncode == 1, "8/14 SURVIVE: a target that ignored SIGTERM makes the run exit 1 "
                                "(got %d)" % proc.returncode)
    check("survived 1" in proc.stdout, "8/14 SURVIVE: the summary says `survived 1`, not `reaped N`")
    check(os.path.exists("/proc/%d" % procs["survive"]), "8/14 SURVIVE: it is still there (as reported)")

    check(cls("noowner") == "UNATTRIBUTABLE" and "no-owner" in why("noowner"),
          "9/14 REFUSE: a `pi` under no launcher script is UNATTRIBUTABLE `no-owner` (got %r)"
          % cls("noowner"))
    check(os.path.exists("/proc/%d" % procs["noowner"]), "9/14 REFUSE: --apply did NOT touch it")

    check(cls("weak") == "UNATTRIBUTABLE" and "weak-owner" in why("weak"),
          "10/14 WEAK: a launcher that INTERPOLATES (`TAG=\"$N\"`, `lane-$N.log` — the shipped "
          "shape) leaves no basis naming the tag, so ownership is `weak-owner` and the row is "
          "report-only on BOTH DONE arms (got %r: %r)" % (cls("weak"), why("weak")))
    check(os.path.exists("/proc/%d" % procs["weak"]), "10/14 WEAK: --apply did NOT touch it")

    check(cls("freshlog") != "DONE-NOT-EXITED",
          "11/14 FRESHLOG: no transcript + a log YOUNGER than --min-idle is not DONE — the silence "
          "bound applies to the log-only arm too (got %r)" % cls("freshlog"))
    check(os.path.exists("/proc/%d" % procs["freshlog"]), "11/14 FRESHLOG: --apply did NOT touch it")

    check(cls("interactive") == "UNATTRIBUTABLE" and "interactive-or-unknown-mode" in why("interactive"),
          "13/14 PRINT-MODE: a lane-shaped `pi` whose launcher does NOT invoke print mode is refused — "
          "an agent waiting at a human's prompt also reaches turn-ended and frozen CPU (got %r)"
          % cls("interactive"))
    check(os.path.exists("/proc/%d" % procs["interactive"]),
          "13/14 PRINT-MODE: --apply did NOT touch it")

    check(cls("peerA") == "UNATTRIBUTABLE" and "peer-claimed" in why("peerA")
          and cls("peerB") == "UNATTRIBUTABLE" and "peer-claimed" in why("peerB"),
          "14/15 PEER: two `pi` fenced onto ONE transcript BOTH abstain (got %r/%r)"
          % (cls("peerA"), cls("peerB")))
    check(os.path.exists("/proc/%d" % procs["peerA"]) and os.path.exists("/proc/%d" % procs["peerB"]),
          "14/15 PEER: neither was reaped")
    pproc, prows = run_tool(sessions, [procs["peerA"]], ["--authorise-hostless"], apply=False)
    check(prows.get(procs["peerA"], {}).get("cls") == "UNATTRIBUTABLE"
          and "peer-claimed" in prows.get(procs["peerA"], {}).get("why", ""),
          "14/15 PEER: and a --pid-narrowed pass STILL abstains — the binding is over the whole "
          "population, not the requested subset (got %r)"
          % prows.get(procs["peerA"], {}).get("cls"))

    check(cls("commentonly") == "UNATTRIBUTABLE"
          and "interactive-or-unknown-mode" in why("commentonly"),
          "15/16 COMMENT: a launcher that mentions print mode ONLY IN A COMMENT does not satisfy the "
          "predicate (got %r)" % cls("commentonly"))
    check(os.path.exists("/proc/%d" % procs["commentonly"]),
          "15/16 COMMENT: --apply did NOT touch it")

    check(cls("trailcomment") == "UNATTRIBUTABLE"
          and "interactive-or-unknown-mode" in why("trailcomment"),
          "16/17 TRAILING-COMMENT: `export TAG=x  # this lane runs pi -p here` does not satisfy the "
          "print-mode predicate — a trailing comment is not code (got %r)" % cls("trailcomment"))
    check(os.path.exists("/proc/%d" % procs["trailcomment"]),
          "16/17 TRAILING-COMMENT: --apply did NOT touch it")

    check(rows.get(procs["argvtag"], {}).get("owner") == "tag"
          and cls("argvtag") == "DONE-NOT-EXITED",
          "12/14 ARGV: a launcher whose ONLY basis is the tag on its own argv (`bash lane-argvtag.sh "
          "argvtag` — the shipped `lane.sh <N>` shape) is ownership rung `tag` and is reaped "
          "(got %r: %r)" % (rows.get(procs["argvtag"], {}).get("owner"), cls("argvtag")))

    check(sum(1 for r in rows.values() if r["cls"] == "DONE-NOT-EXITED") == 4,
          "exactly 4 of the 18 judged fixtures were DONE-NOT-EXITED (done + nosession + argvtag + "
          "survive, and the last of those ignored SIGTERM): a detector that reaped all, or none, "
          "fails here")

    # ── CONTROL: the --min-idle bound is real, in BOTH directions ──
    proc2, rows2 = run_tool(sessions, [procs["bound"]],
                            ["--authorise-hostless", "--min-idle", "100000"])
    check(rows2.get(procs["bound"], {}).get("cls") != "DONE-NOT-EXITED",
          "C1 BOUND: --min-idle 100000 leaves a DONE-shaped lane un-reaped (got %r)"
          % rows2.get(procs["bound"], {}).get("cls"))
    check(os.path.exists("/proc/%d" % procs["bound"]), "C1 BOUND: and it is still there")
    proc3, rows3 = run_tool(sessions, [procs["bound"]], ["--authorise-hostless", "--min-idle", "0"],
                            apply=False)
    check(rows3.get(procs["bound"], {}).get("cls") == "DONE-NOT-EXITED",
          "C2 BOUND: the SAME fixture IS DONE-NOT-EXITED at --min-idle 0, so C1 measures the bound "
          "and not a mis-built fixture")

    # ── CONTROL: arming is not the tool's to decide (#2391 is an OPEN owner reopen) ──
    proc4, rows4 = run_tool(sessions, [procs["bound"]], ["--min-idle", "0"])       # no authorisation
    check(proc4.returncode == 4, "C3 REPORT-ONLY: without --authorise-hostless the pass exits 4 "
                                 "(got %d)" % proc4.returncode)
    check("REPORT-ONLY" in proc4.stdout, "C3 REPORT-ONLY: and says so")
    check(os.path.exists("/proc/%d" % procs["bound"]),
          "C3 REPORT-ONLY: nothing was signalled")

    # ── CONTROL: the pre-signal re-check must REFUSE a moved incarnation, and count it as refused ──
    tool = load_tool()
    canon, pool = tool.imports()
    fake = {"pid": procs["bound"], "etime": "9-00:00:00", "etime_after": "9-00:00:00",
            "transcript": None, "log": os.path.join(root, "logs", "bound.log"), "rc": None}

    class O:
        authorise_hostless = True
        verify_sample = 0.1

    import contextlib
    import io
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        rcret = tool.apply_done([fake], canon, pool, O())
    out = buf.getvalue()
    check(rcret == 1, "C4 REFUSED: a target whose incarnation moved makes the pass exit 1 (got %d)"
          % rcret)
    check("refused 1" in out and "reaped 0" in out,
          "C4 REFUSED: the summary counts it as `refused 1` / `reaped 0` — not as a reap")
    check(os.path.exists("/proc/%d" % procs["bound"]), "C4 REFUSED: nothing was signalled")

    # ── CONTROL: `verify_target` re-asks the LOG channel, not only its size (cycle 3, P2-3: a
    # truncating reuse makes the file SMALLER, so a size-only test passes) ──
    probe = os.path.join(root, "logs", "verifyprobe.log")
    with open(probe, "w", encoding="utf-8") as fh:
        fh.write("report\n" + MARKER)
    # the incarnation must be read from a LIVE `ps`, not from pass 1's JSON (which never included
    # this pid): an unparseable etime is an abstention in the tool, so the control would pass for
    # the wrong reason — the same "absent reading" class the tool itself guards.
    live_row = (pool.ps_pi_fields() or {}).get(str(procs["bound"])) or {}
    prow = {"pid": procs["bound"], "etime": live_row.get("etime", ""),
            "etime_after": live_row.get("etime", ""),
            "transcript": None, "log": probe, "marker": "ok", "rc": None}

    def touch_log_soon() -> None:
        time.sleep(0.15)
        with open(probe, "a", encoding="utf-8") as fh:
            fh.write("<a later launcher invocation rewrote this>\n")

    th = threading.Thread(target=touch_log_soon, daemon=True)
    th.start()
    ok_quiet, why_quiet = tool.verify_target(prow, canon, pool, 0.6)
    th.join(timeout=5)
    check(not ok_quiet and ("log changed" in why_quiet or "deciding line changed" in why_quiet),
          "C6 VERIFY: a log that changes inside the verification window REFUSES the signal (got %r: "
          "%r)" % (ok_quiet, why_quiet))

    with open(probe, "w", encoding="utf-8") as fh:      # a genuinely QUIET log, back to its marker
        fh.write("report\n" + MARKER)
    ok_still, why_still = tool.verify_target(prow, canon, pool, 0.2)
    check(ok_still, "C6 VERIFY: the same row with a QUIET log still verifies (%r) — so C6 is not "
                    "always-false" % why_still)

    cleanup()                     # kills the groups AND removes the root
    print("\nALL ASSERTIONS HELD (18 judged fixtures + a control lane: 4 DONE-NOT-EXITED, one of "
          "which ignored SIGTERM; 10 refused for ten different reasons; plus the bound in both "
          "directions, the arming gate, the refusal bucket and the verify-time log re-read)")
    return 0


def load_tool():
    """Import the tool itself, for the controls that must drive its REAL internal functions."""
    spec = importlib.util.spec_from_file_location("pi_dne_tool", TOOL)
    mod = importlib.util.module_from_spec(spec)
    sys.modules["pi_dne_tool"] = mod
    spec.loader.exec_module(mod)
    return mod


def run_mutations() -> int:
    """Re-run this suite against each mutated copy of the tool; each MUST go RED."""
    mutations = [
        ("abstain folded into stalled (the cycle-1 P0)",
         "            stalled = None if turn.abstain else turn.stalled",
         "            stalled = turn.stalled"),
        ("the log-growth veto deleted",
         '    if pid in log_grew:\n        out.update(cls="LIVE", why="the log this process holds '
         'GREW inside the sample window")\n        return out\n',
         "    if False:\n        return out\n"),
        ("the open-turn veto deleted",
         "    if stalled is True:", "    if False:"),
        # cycle 3 measured these three staying GREEN on the shipped suite:
        ("the log-only arm loses the silence bound",
         '    if marker == "ok" and (out["log_age_s"] or 0) >= opts.min_idle:',
         '    if marker == "ok":'),
        # the whole log re-read (size AND marker), because either check alone still refuses the
        # probing log — a one-branch mutation is a partial change, not a defect (cycle 7)
        ("verify_target stops re-asking the log channel",
         '    if _size(r.get("log")) is not None and log_m0 is not None and '
         '_size(r.get("log")) != log_m0:\n'
         '        return False, "the log changed inside the verification window (grew, or was rewritten)"\n'
         '    if r.get("log"):\n'
         '        holders = sum(1 for q in again if held_log(q)[0] == r["log"])\n'
         '        marker_now, _d = log_marker(r["log"], holders)\n'
         '        if r.get("marker") in ("ok", "hook-failed") and marker_now != r.get("marker"):\n'
         "            return False, (\"the log's deciding line changed at signal time (%s -> %s)\"\n"
         '                           % (r.get("marker"), marker_now))',
         "    pass"),
        ("ownership grants `tag` for ANY tag",
         "        if tag_on_argv:",
         '        if True:'),
        # cycle 4 measured this one staying GREEN: the argv basis is the only one a shipped
        # `lane.sh <N>` lane satisfies, and no fixture used it.
        ("the argv ownership rung deleted",
         "        if tag_on_argv:",
         "        if False:"),
        # cycle 4: the only local discriminator between "lane finished" and "agent at a prompt".
        ("the print-mode predicate deleted",
         "    if rung is not None and not PRINT_MODE.search(code_only(_read(launcher))):",
         "    if False:"),
        ("the peer-claimed guard disabled", "    if path and path in peers:", "    if False:"),
        ("code_only() reverted to the cycle-5 body (whole-line comments only, TRAILING ones count)",
         '        code = ln.split("#", 1)[0]',
         '        code = "" if ln.lstrip().startswith("#") else ln'),
        ("--pid binds only the requested subset",
         "    binds, peers = bind_map(pool, rows, all_pids, opts.ref_s)",
         "    binds, peers = bind_map(pool, rows, pids, opts.ref_s)"),
    ]
    def one(label_old_new):
        label, old, new = label_old_new
        tmp = tempfile.mkdtemp(prefix="pi-dne-mut-")
        ROOT.append(tmp)                     # removed by cleanup() even if this run is killed
        try:
            shutil.copytree(os.path.join(SCRIPTS, "..", "tools", "fleet"),
                            os.path.join(tmp, "tools", "fleet"))
            os.makedirs(os.path.join(tmp, "scripts", "orchestrator-harness"))
            for f in ("orphan-reap.py",):
                shutil.copy(os.path.join(SCRIPTS, f), os.path.join(tmp, "scripts", f))
            shutil.copy(TOOL, os.path.join(tmp, "scripts", "orchestrator-harness",
                                           "pi-done-not-exited.py"))
            shutil.copy(os.path.abspath(__file__), os.path.join(tmp, "scripts",
                                                                "orchestrator-harness",
                                                                "pi-done-not-exited.test.py"))
            target = os.path.join(tmp, "scripts", "orchestrator-harness", "pi-done-not-exited.py")
            text = open(target).read()
            if old not in text:
                fail("mutation %r: its anchor no longer matches the tool — the control is INERT"
                     % label)
            open(target, "w").write(text.replace(old, new, 1))
            proc = subprocess.run([sys.executable, os.path.join(tmp, "scripts", "orchestrator-harness",
                                                                "pi-done-not-exited.test.py")],
                                  capture_output=True, text=True, timeout=900)
            # ⛔ A CATCH IS AN ASSERTION HIT, not any non-zero exit: a traceback, an OOM kill or a
            # flake would otherwise be reported as "the suite caught it" (cycle 7, P2-2) — the
            # anti-inertness control manufacturing the teeth it exists to prove.
            hit = proc.returncode != 0 and "FAIL:" in proc.stdout
            return (label, hit, proc.returncode, proc.stdout[-400:])
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
            if tmp in ROOT:
                ROOT.remove(tmp)

    # ⛔ THREE AT A TIME. Sequentially the control is ~11 x 90 s of wall clock; a control that
    # cannot finish inside a CI step is a control that gets disabled. Each run owns its temp root and
    # its own fixtures, so they do not interact.
    from concurrent.futures import ThreadPoolExecutor
    results = []
    with ThreadPoolExecutor(max_workers=3) as pool:
        for res in pool.map(one, mutations):
            results.append(res)
    missed = [r[0] for r in results if not r[1]]
    for label, caught, rc, tail in results:
        if caught:
            print("ok   mutation caught: %s → suite RED (rc=%d, assertion hit)" % (label, rc))
        else:
            print("   NOT a catch: %s (rc=%d, no FAIL: line) tail: %r" % (label, rc, tail))
    if missed:
        fail("NOT caught (the suite stayed green, so the assertion that should guard them is inert): "
             + "; ".join(missed))
    print("\nALL MUTATIONS CAUGHT (%d/%d): the suite can go RED for each defect it claims to guard"
          % (len(results), len(mutations)))
    return 0


if __name__ == "__main__":
    if "--mutations" in sys.argv:
        sys.exit(run_mutations())
    sys.exit(main())
