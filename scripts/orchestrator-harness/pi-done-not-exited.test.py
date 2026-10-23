#!/usr/bin/env python3
"""pi-done-not-exited.test.py — six fixtures, and the directions that matter (#2163).

WHY PROCESS FIXTURES AND NOT MOCKS
The bug is a property of REAL PROCESSES — a `pi` whose launcher is blocked on it, a log on its
fd 1, a transcript whose last turn ended. A mocked `ps` would prove the parser, not the detector, and
the measured failure this pattern exists for (a first dry run that would have reaped a 7-minute-old
lane) came from a bad fixture, not from bad code. So every case is a live tree: a symlink named `pi`
(kernel `comm` = "pi"), a real launcher script, a real log on fd 1, and a transcript named the way pi
names one.

THE CASES — each one guards a different way to be wrong
  1. DONE        launcher + completion line + turn-ended transcript + frozen CPU
                 → DONE-NOT-EXITED, and `--apply` reaps it (the detector DOES something).
  2. LIVE        identical, but its log GROWS inside the sample window → LIVE, survives `--apply`.
                 This is the brief's non-vacuity case: a reap-everything detector passes a one-case
                 test.
  3. HUNG        its log ends with a SUCCESSFUL completion line, but its transcript's last turn is
                 OPEN (`stopReason: toolUse` + a tool call, no result) → HUNG, survives. This is the
                 shape where the folk rule ("a completion marker plus frozen CPU") would kill a `pi`
                 mid-turn, and it really occurs (measured: a lane held a completion line in a shared
                 log while its own transcript was `turn-open:pending-tool-call`).
  4. ABSTAIN     its log ends with a completion line and its CPU is frozen, but its transcript's last
                 entry is a `compaction` — the canon's `tail-after-compaction` ABSTENTION, which
                 carries `stalled=False`. Reading `stalled` alone would turn that abstention into a
                 kill licence; this fixture fails if anyone does (review cycle 1, P0).
  5. SURVIVE     a DONE-shaped lane whose `pi` IGNORES SIGTERM → the run must exit 1 and say
                 `survived 1`; a tool that counts this as a reap (or exits 0) fails here.
  6. NO-OWNER    a `pi` under a plain `bash -c`, not a launcher script → UNATTRIBUTABLE `no-owner`,
                 survives: an unmeasured ownership is not freedom.

A SEVENTH, SEQUENTIAL CHECK pins the `--min-idle` bound: the same DONE fixture with `--min-idle`
above its silence window must NOT be reaped (otherwise the bound is decorative).

THE FIXTURES ARE INSULATED FROM THE AMBIENT ANCESTRY. `setsid --fork` makes each launcher a session
leader reparented to init, so the chain is `pi → launcher → init` (`hostless`) whether the suite runs
in a terminal, tmux, or CI. Without it the same suite is a false RED for any developer inside tmux,
because gate 2 classifies a tmux ancestor as KEEP-HUMAN.

Exit 0 = every assertion held. Non-zero = the first failure printed with its expectation.
"""
from __future__ import annotations

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
UUID = "01a1%010x" % os.getpid()


LEADERS: dict = {}          # tag -> launcher pid (a session leader); cleaned up on EVERY exit path


def cleanup() -> None:
    """Kill each fixture's whole process group. Runs on success AND on a failed assertion (#2163
    review cycle 1: the mutation runs leaked six fixtures because `fail()` exited first)."""
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


def launcher_script(root: str, tag: str, cwd: str, ignore_term: bool = False) -> str:
    """A real lane launcher: TAG exported, `pi` on fd 1, `.rc` written AFTER it returns."""
    log = os.path.join(root, "logs", tag + ".log")
    rc = os.path.join(root, "logs", tag + ".rc")
    trap = "trap '' TERM\n" if ignore_term else ""
    path = os.path.join(root, "lane-%s.sh" % tag)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("#!/bin/bash\n"
                 "export TAG=%s\n"
                 "cd %s || exit 4\n"
                 "%s"
                 "%s/pi 300 > %s 2>&1\n"
                 "rc=$?\n"
                 "printf 'EXIT rc=%%s\\n' \"$rc\" >> %s\n"
                 "printf '%%s %%s\\n' \"$rc\" \"$(date -u +%%FT%%TZ)\" > %s\n"
                 % (tag, cwd, trap, root, log, log, rc))
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


def run_tool(root: str, sessions: str, pids, extra, apply: bool = True):
    cmd = [sys.executable, TOOL, "--json", "--sample", "4", "--min-idle", "60",
           "--sessions-dir", sessions] + extra
    if apply:
        cmd.append("--apply")
    for pid in pids:
        cmd += ["--pid", str(pid)]
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=240)
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
    # the fake `pi`: a symlink, so the kernel's `comm` is exactly "pi"
    os.symlink("/bin/sleep", os.path.join(root, "pi"))
    procs, paths = {}, {}
    leaders = LEADERS

    def case(tag: str, entry: dict, marker: bool = True, ignore_term: bool = False) -> int:
        cwd = os.path.join(root, "wt-" + tag)
        os.makedirs(cwd)
        started = time.time()
        script = launcher_script(root, tag, cwd, ignore_term)
        pidfile = os.path.join(root, tag + ".leader")
        leaders[tag] = launch_detached(script, cwd, pidfile)
        pi_pid = child_pi(leaders[tag])
        procs[tag] = pi_pid
        logged = os.path.join(root, "logs", tag + ".log")
        with open(logged, "w", encoding="utf-8") as fh:
            fh.write("the lane's report\n")
            if marker:
                fh.write(MARKER)
        paths[tag] = write_session(sessions, cwd, started, entry)
        # backdate both files past --min-idle: the census must not be fooled by "just written"
        old = time.time() - 600
        os.utime(logged, (old, old))
        os.utime(paths[tag], (old, old))
        return pi_pid

    case("done", TURN_ENDED)
    case("live", TURN_ENDED)
    case("hung", TURN_OPEN)                    # completion line + OPEN turn = the trap
    case("abstain", TURN_ABSTAIN, marker=False)   # ABSTAINING boundary, no other evidence
    case("survive", TURN_ENDED, ignore_term=True)
    case("bound", TURN_ENDED)                # DONE-shaped; reaped only if --min-idle is decorative

    # no-owner: a `pi` under a plain `bash -c`, no launcher script anywhere in the chain
    cwd6 = os.path.join(root, "wt-noowner")
    os.makedirs(cwd6)
    started = time.time()
    leader6 = os.path.join(root, "noowner.leader")
    subprocess.run(["setsid", "--fork", "bash", "-c",
                    "echo $$ > %s; exec bash -c '%s/pi 300 > %s/logs/noowner.log 2>&1'"
                    % (leader6, root, root)],
                   cwd=cwd6, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    end = time.time() + 10
    while time.time() < end:
        try:
            leaders["noowner"] = int(open(leader6).read().strip())
            break
        except (OSError, ValueError):
            time.sleep(0.05)
    procs["noowner"] = child_pi(leaders["noowner"])
    with open(os.path.join(root, "logs", "noowner.log"), "w", encoding="utf-8") as fh:
        fh.write("report\n" + MARKER)
    paths["noowner"] = write_session(sessions, cwd6, started, TURN_ENDED)
    old = time.time() - 600
    os.utime(os.path.join(root, "logs", "noowner.log"), (old, old))
    os.utime(paths["noowner"], (old, old))

    time.sleep(1.2)                                   # let each tree settle into its shape
    check(all(os.path.exists("/proc/%d/comm" % pid) and
              open("/proc/%d/comm" % pid).read().strip() == "pi" for pid in procs.values()),
          "every fixture's kernel `comm` is exactly `pi`")

    # the LIVE lane writes to its log INSIDE the sample window — positive liveness evidence
    def keep_writing() -> None:
        for _ in range(3):
            time.sleep(0.8)
            with open(os.path.join(root, "logs", "live.log"), "a", encoding="utf-8") as fh:
                fh.write("still working: tool output\n")

    writer = threading.Thread(target=keep_writing, daemon=True)
    writer.start()

    tags = ["done", "live", "hung", "abstain", "survive", "noowner"]   # "bound" stays out
    pids = [procs[t] for t in tags]
    proc, rows = run_tool(root, sessions, pids, [])
    writer.join(timeout=5)
    if proc.returncode not in (0, 1):
        print(proc.stdout[-4000:], proc.stderr[-2000:])
        fail("the tool exited %d (expected 0/1 with one SURVIVOR) — output above" % proc.returncode)

    def cls(tag: str) -> str:
        return rows.get(procs[tag], {}).get("cls", "<missing>")

    def why(tag: str) -> str:
        return rows.get(procs[tag], {}).get("why", "")

    check(cls("done") == "DONE-NOT-EXITED",
          "1/6 DONE: completion line + turn-ended transcript + frozen CPU → DONE-NOT-EXITED "
          "(got %r: %r)" % (cls("done"), why("done")))
    check("turn ENDED" in why("done"), "1/6 DONE: the row names the transcript channel")
    time.sleep(0.5)
    check(not os.path.exists("/proc/%d" % procs["done"]), "1/6 DONE: --apply removed the process")
    rc = os.path.join(root, "logs", "done.rc")
    check(os.path.exists(rc) and open(rc).read().strip(),
          "1/6 DONE: the launcher left `wait` and wrote its .rc (it completed, it did not crash)")

    check(cls("live") != "DONE-NOT-EXITED",
          "2/6 LIVE: a log growing inside the window is NOT DONE-NOT-EXITED (got %r)" % cls("live"))
    check("GREW" in why("live"), "2/6 LIVE: the row names the growth veto that saved it")
    check(os.path.exists("/proc/%d" % procs["live"]),
          "2/6 LIVE: --apply did NOT touch it — a reap-everything detector fails here")

    check(cls("hung") == "HUNG",
          "3/6 HUNG: a completion line does not override an OPEN turn (got %r)" % cls("hung"))
    check(os.path.exists("/proc/%d" % procs["hung"]),
          "3/6 HUNG: --apply did NOT touch a `pi` that is mid-turn")

    check(cls("abstain") == "UNATTRIBUTABLE",
          "4/6 ABSTAIN: an ABSTAINING turn boundary (tail-after-compaction) with no other evidence is "
          "UNATTRIBUTABLE — `stalled=False` on an abstention is NOT `turn-ended` (got %r)" % cls("abstain"))
    check(os.path.exists("/proc/%d" % procs["abstain"]),
          "4/6 ABSTAIN: --apply did NOT touch it (the canon's abstention is not a kill licence)")

    check(proc.returncode == 1, "5/6 SURVIVE: a target that ignored SIGTERM makes the run exit 1 "
                                "(got %d)" % proc.returncode)
    check("survived 1" in proc.stdout, "5/6 SURVIVE: the summary says `survived 1` (not `reaped 2`)")
    check(os.path.exists("/proc/%d" % procs["survive"]),
          "5/6 SURVIVE: the process that ignored SIGTERM is still there (as reported)")

    check(cls("noowner") == "UNATTRIBUTABLE",
          "6/6 REFUSE: a `pi` under no launcher script is UNATTRIBUTABLE (got %r)" % cls("noowner"))
    check("no-owner" in why("noowner"), "6/6 REFUSE: the refusal names its reason (`no-owner`)")
    check(os.path.exists("/proc/%d" % procs["noowner"]), "6/6 REFUSE: --apply did NOT touch it")

    check(sum(1 for r in rows.values() if r["cls"] == "DONE-NOT-EXITED") == 2,
          "exactly 2 of the 6 fixtures were DONE-NOT-EXITED (DONE + SURVIVE; a detector that reaped "
          "all six, or none, fails here)")

    # ── the --min-idle bound is real, not decorative: a DONE-shaped lane that is younger than the
    #    bound must NOT be reaped (the same fixture IS reaped at the default bound). ──
    proc2, rows2 = run_tool(root, sessions, [procs["bound"]], ["--min-idle", "100000"])
    check(proc2.returncode in (0, 1)
          and rows2.get(procs["bound"], {}).get("cls") != "DONE-NOT-EXITED",
          "7/7 BOUND: --min-idle 100000 leaves a DONE-shaped lane un-reaped, so the silence bound is "
          "enforced (got %r)" % rows2.get(procs["bound"], {}).get("cls"))
    check(os.path.exists("/proc/%d" % procs["bound"]), "7/7 BOUND: and the process is still there")
    proc3, rows3 = run_tool(root, sessions, [procs["bound"]], ["--min-idle", "0"], apply=False)
    check(rows3.get(procs["bound"], {}).get("cls") == "DONE-NOT-EXITED",
          "7/7 BOUND: the SAME fixture is DONE-NOT-EXITED at --min-idle 0, so the leg above is "
          "measuring the bound and not a mis-built fixture")

    cleanup()                                           # kill every fixture's process group
    shutil.rmtree(root, ignore_errors=True)
    print("\nALL ASSERTIONS HELD (6 fixtures: 2 reaped, 4 refused for four different reasons; a 7th "
          "pins the --min-idle bound in both directions)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
