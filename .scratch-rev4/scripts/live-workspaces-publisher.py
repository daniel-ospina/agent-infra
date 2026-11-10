#!/usr/bin/env python3
"""Keep state/live-workspaces.txt fresh for the heartbeat, which CANNOT query cmux itself.

    cmux: "Access denied - only processes started inside cmux can connect"

Usage (idempotent -- safe to call on every turn):
    live-workspaces-publisher.py            # start the loop if it is not already running
    live-workspaces-publisher.py --status
    live-workspaces-publisher.py --stop

WHY THIS SHAPE (measured 2026-10-09):
  * cmux authorizes by the RESPONSIBLE process, and macOS keeps that across reparenting, so a
    detached child of a cmux-resident process still has access (verified: rc=0, 53 KB of output).
    That is why this needs no daemon and no launchd job -- launchd is the ONE context that can never
    be authorized.
  * `nohup ... &` + `disown` is NOT enough: the loop still dies with the caller's PROCESS GROUP.
    `start_new_session=True` performs setsid(2), which is what actually detaches it.
  * It does not survive a reboot, so this is SELF-HEALING: the loop writes a pid file and any later
    call restarts it if the pid is gone. Any lane or the orchestrator calling this is enough.
  * If it does lapse, lane-actions.py's filter goes INERT and SAYS SO on stderr. The failure is
    visible, never silent.
"""
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
STATE = os.path.join(HERE, os.pardir, "state")
PIDF = os.path.join(STATE, "live-workspaces-publisher.pid")
PUBLISH = os.path.join(HERE, "publish-live-workspaces.py")
FILE = os.path.join(STATE, "live-workspaces.txt")
INTERVAL = int(os.environ.get("LIVE_WS_INTERVAL", "240"))
DEVNULL = subprocess.DEVNULL


def _pid_alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except (OSError, ProcessLookupError):
        return False


def running():
    """The loop's pid, or None. A stale pid file (recycled or dead pid) reads as not running."""
    try:
        with open(PIDF) as fh:
            pid = int(fh.read().strip())
    except (OSError, ValueError):
        return None
    return pid if _pid_alive(pid) else None


def loop():
    with open(PIDF, "w") as fh:
        fh.write(str(os.getpid()))
    try:
        while True:
            subprocess.run([sys.executable, PUBLISH, "--quiet"],
                           stdout=DEVNULL, stderr=DEVNULL)
            time.sleep(INTERVAL)
    finally:
        try:
            os.remove(PIDF)
        except OSError:
            pass


def status():
    pid = running()
    if pid:
        try:
            age = int(time.time() - os.path.getmtime(FILE))
            detail = "file age %dm" % (age // 60)
        except OSError:
            detail = "NO FILE -- the filter will be INERT"
        print("running (pid %s) -- %s" % (pid, detail))
    else:
        print("NOT running -- launch-actions.py's workspace filter is INERT until it is restarted")
    return 0


def ensure():
    if running():
        return 0
    # start_new_session=True == setsid(2): detaches from the caller's process group, which a bare
    # `nohup &` does not, so the loop survives the shell that started it.
    subprocess.Popen([sys.executable, os.path.abspath(__file__), "--loop"],
                     stdout=DEVNULL, stderr=DEVNULL, stdin=DEVNULL,
                     start_new_session=True)
    time.sleep(1.5)
    pid = running()
    if pid:
        print("started (pid %s, every %ss)" % (pid, INTERVAL))
        return 0
    sys.stderr.write(
        "FAILED to start. Either this process is OUTSIDE cmux (cmux refuses those), or the loop died\n"
        "immediately. Check: %s\n" % PIDF)
    return 1


def main():
    arg = sys.argv[1] if len(sys.argv) > 1 else "ensure"
    if arg == "--loop":
        loop()
        return 0
    if arg == "--status":
        return status()
    if arg == "--stop":
        pid = running()
        if pid:
            os.kill(pid, 15)
            time.sleep(0.5)
        try:
            os.remove(PIDF)
        except OSError:
            pass
        print("stopped")
        return 0
    return ensure()


if __name__ == "__main__":
    sys.exit(main())
