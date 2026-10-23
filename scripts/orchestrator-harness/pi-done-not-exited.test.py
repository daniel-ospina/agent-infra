#!/usr/bin/env python3
"""pi-done-not-exited.test.py — nine real process trees, plus the controls the review demanded.

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

THREE SEQUENTIAL CONTROLS (not fixtures):
  * BOUND      a DONE-shaped lane that the first pass never reaps: not reaped at `--min-idle 100000`,
               reaped at `--min-idle 0` — so the silence bound is enforced in BOTH directions.
  * REPORT-ONLY without `--authorise-hostless` the same row must be left alone and the pass must exit
               4 (a complete pass that found work it was not authorised to do — #2391 is open).
  * REFUSED    the pre-signal re-check must REFUSE a target whose incarnation moved, and the summary
               must say `refused 1` with exit 1 (cycle-1 P1: a refused target was counted as reaped).

`--mutations` re-runs this suite against THREE mutated copies of the tool and requires each to go RED
(drop the growth veto, drop the open-turn veto, fold `abstain` into `stalled`). Prose cannot prove a
suite has teeth; this can, in CI, which is why the repo's other zero-dep suites carry the same mode.

THE FIXTURES ARE INSULATED FROM THE AMBIENT ANCESTRY. `setsid --fork` makes each launcher a session
leader reparented to init, so the chain is `pi → launcher → init` (`hostless`) whether the suite runs
in a terminal, tmux, or CI; cases are staggered past the canon's ±3 s fence so no two can bind one
transcript. Without either guard this suite is a false RED for a developer inside tmux.

Exit 0 = every assertion held. Non-zero = the first failure printed with its expectation.
"""
from __future__ import annotations

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


def cleanup() -> None:
    """Kill each fixture's whole process group. Runs on success AND on a failed assertion: the
    cycle-1 mutation runs leaked six fixtures because `fail()` exited before the cleanup loop."""
    for pid in list(LEADERS.values()):
        try:
            os.killpg(int(pid), signal.SIGKILL)
        except OSError:
            pass
    LEADERS.clear()


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
                    ignore_term: bool = False, child: bool = False) -> str:
    """A real lane launcher: TAG exported AND ASSIGNED, `pi` on fd 1, `.rc` written AFTER it exits."""
    log = os.path.join(root, "logs", logname + ".log")
    rc = os.path.join(root, "logs", tag + ".rc")
    trap = "trap '' TERM\n" if ignore_term else ""
    redirect = ">>" if append else ">"
    arg = " child" if child else ""
    path = os.path.join(root, "lane-%s.sh" % tag)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("#!/bin/bash\n"
                 "export TAG=%s\n"
                 "cd %s || exit 4\n"
                 "%s"
                 "%s/pi 300%s %s %s 2>&1\n"
                 "rc=$?\n"
                 "printf 'EXIT rc=%%s\\n' \"$rc\" >> %s\n"
                 "printf '%%s %%s\\n' \"$rc\" \"$(date -u +%%FT%%TZ)\" > %s\n"
                 % (tag, cwd, trap, root, arg, redirect, log, log, rc))
    return path


def launch_detached(script: str, cwd: str, pidfile: str) -> int:
    """Run the launcher as a session leader reparented to init (ambient ancestry insulation)."""
    subprocess.run(["setsid", "--fork", "bash", "-c",
                    "echo $$ > %s; exec bash %s" % (pidfile, script)],
                   cwd=cwd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
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
             append: bool = False, ignore_term: bool = False, child: bool = False) -> int:
        cwd = os.path.join(root, "wt-" + tag)
        os.makedirs(cwd)
        started = time.time()
        script = launcher_script(root, tag, cwd, tag if logname is None else logname,
                                 append=append, ignore_term=ignore_term, child=child)
        leaders[tag] = launch_detached(script, cwd, os.path.join(root, tag + ".leader"))
        pi_pid = child_pi(leaders[tag])
        procs[tag] = pi_pid
        logged = os.path.join(root, "logs", (tag if logname is None else logname) + ".log")
        with open(logged, "w", encoding="utf-8") as fh:
            fh.write("the lane's report\n")
            if marker:
                fh.write(MARKER)
        if transcript:
            paths[tag] = write_session(sessions, cwd, started, entry)
            old = time.time() - 600
            os.utime(paths[tag], (old, old))
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

    # no-owner: a `pi` under a plain `bash -c`, no launcher script anywhere in the chain
    cwd = os.path.join(root, "wt-noowner")
    os.makedirs(cwd)
    started = time.time()
    leaderfile = os.path.join(root, "noowner.leader")
    subprocess.run(["setsid", "--fork", "bash", "-c",
                    "echo $$ > %s; exec bash -c '%s/pi 300 > %s/logs/noowner.log 2>&1'"
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
        for _ in range(3):
            time.sleep(0.8)
            with open(os.path.join(root, "logs", "live.log"), "a", encoding="utf-8") as fh:
                fh.write("still working: tool output\n")

    writer = threading.Thread(target=keep_writing, daemon=True)
    writer.start()

    tags = ["done", "live", "hung", "abstain", "nosession", "shared", "shared2", "child", "survive",
            "noowner"]
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
          "1/9 DONE: completion line + turn-ended transcript + frozen CPU → DONE-NOT-EXITED "
          "(got %r: %r)" % (cls("done"), why("done")))
    check("turn ENDED" in why("done"), "1/9 DONE: the row names the transcript channel")
    time.sleep(0.5)
    check(not os.path.exists("/proc/%d" % procs["done"]), "1/9 DONE: --apply removed the process")
    rc = os.path.join(root, "logs", "done.rc")
    check(os.path.exists(rc) and open(rc).read().strip(),
          "1/9 DONE: the launcher left `wait` and wrote its .rc (it completed, it did not crash)")

    check(cls("live") == "LIVE" and "GREW" in why("live"),
          "2/9 LIVE: a log growing inside the window is LIVE and says why (got %r)" % cls("live"))
    check(os.path.exists("/proc/%d" % procs["live"]),
          "2/9 LIVE: --apply did NOT touch it — a reap-everything detector fails here")

    check(cls("hung") == "HUNG",
          "3/9 HUNG: a completion line does not override an OPEN turn (got %r)" % cls("hung"))
    check(os.path.exists("/proc/%d" % procs["hung"]),
          "3/9 HUNG: --apply did NOT touch a `pi` that is mid-turn")

    check(cls("abstain") == "UNATTRIBUTABLE",
          "4/9 ABSTAIN: an ABSTAINING boundary (tail-after-compaction) is NOT `turn-ended` "
          "(got %r)" % cls("abstain"))
    check(os.path.exists("/proc/%d" % procs["abstain"]),
          "4/9 ABSTAIN: --apply did NOT touch it (the canon's abstention is not a kill licence)")

    check(cls("nosession") == "DONE-NOT-EXITED" and "exclusive log" in why("nosession"),
          "5/9 NOSESSION: with NO transcript, an exclusively-held completion log decides — and the "
          "row says so (got %r: %r)" % (cls("nosession"), why("nosession")))

    check(cls("shared") != "DONE-NOT-EXITED" and cls("shared2") != "DONE-NOT-EXITED",
          "6/9 SHARED: two `pi` on one log authorise nothing, both ways round (got %r/%r)"
          % (cls("shared"), cls("shared2")))
    check(os.path.exists("/proc/%d" % procs["shared"]) and
          os.path.exists("/proc/%d" % procs["shared2"]),
          "6/9 SHARED: neither was reaped")

    check(cls("child") == "LIVE",
          "7/9 CHILD: a `pi` holding a live child is LIVE (got %r)" % cls("child"))
    check(os.path.exists("/proc/%d" % procs["child"]),
          "7/9 CHILD: --apply did NOT touch it")

    check(proc.returncode == 1, "8/9 SURVIVE: a target that ignored SIGTERM makes the run exit 1 "
                                "(got %d)" % proc.returncode)
    check("survived 1" in proc.stdout, "8/9 SURVIVE: the summary says `survived 1`, not `reaped N`")
    check(os.path.exists("/proc/%d" % procs["survive"]), "8/9 SURVIVE: it is still there (as reported)")

    check(cls("noowner") == "UNATTRIBUTABLE" and "no-owner" in why("noowner"),
          "9/9 REFUSE: a `pi` under no launcher script is UNATTRIBUTABLE `no-owner` (got %r)"
          % cls("noowner"))
    check(os.path.exists("/proc/%d" % procs["noowner"]), "9/9 REFUSE: --apply did NOT touch it")

    check(sum(1 for r in rows.values() if r["cls"] == "DONE-NOT-EXITED") == 3,
          "exactly 3 of the 10 fixtures were DONE-NOT-EXITED (done + nosession + survive): a "
          "detector that reaped all, or none, fails here")

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

    cleanup()
    shutil.rmtree(root, ignore_errors=True)
    print("\nALL ASSERTIONS HELD (9 fixtures + a control lane: 3 reaped, 6 refused for six different "
          "reasons; plus the bound, the arming gate and the refusal bucket)")
    return 0


def load_tool():
    """Import the tool itself, for the controls that must drive its REAL internal functions."""
    spec = importlib.util.spec_from_file_location("pi_dne_tool", TOOL)
    mod = importlib.util.module_from_spec(spec)
    sys.modules["pi_dne_tool"] = mod
    spec.loader.exec_module(mod)
    return mod


def run_mutations() -> int:
    """Re-run this suite against three mutated copies of the tool; each MUST go RED."""
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
    ]
    for label, old, new in mutations:
        tmp = tempfile.mkdtemp(prefix="pi-dne-mut-")
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
            env = dict(os.environ, PI_DNE_NO_MUTATIONS="1")
            proc = subprocess.run([sys.executable, os.path.join(tmp, "scripts", "orchestrator-harness",
                                                                "pi-done-not-exited.test.py")],
                                  capture_output=True, text=True, timeout=900, env=env)
            if proc.returncode == 0:
                fail("mutation %r was NOT caught — the suite stayed green, so the assertion that "
                     "should guard it is inert" % label)
            print("ok   mutation caught: %s → suite RED (rc=%d)" % (label, proc.returncode))
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
    print("\nALL MUTATIONS CAUGHT (3/3): the suite can go RED for each defect it claims to guard")
    return 0


if __name__ == "__main__":
    if "--mutations" in sys.argv and not os.environ.get("PI_DNE_NO_MUTATIONS"):
        sys.exit(run_mutations())
    sys.exit(main())
