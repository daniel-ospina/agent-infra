#!/usr/bin/env python3
"""pr-doctor-trigger — event-driven front end for pr-doctor.

WHY THIS EXISTS
---------------
`pr-doctor` was scheduled. A scheduled doctor only sees the fleet at the moment the timer
fires, so a PR that turns red ten seconds after a pass waits up to a full interval with no
worker on it. The lead was therefore not the repair — it was the timer. Measured on the Mac:
`com.tortoise.pr-doctor` ran `StartInterval` **1800 s**, so the expected wait for a worker was
900 s and the worst case 1800 s, for a repair whose own cost is one pass.

This is the trigger, not a second doctor. It does the cheapest possible read of the PR
surface (one `gh pr list`, no per-PR calls), derives a fingerprint, and runs the EXISTING
`pr-doctor.py` only when that fingerprint changes:

  * a PR appears / disappears            (opened, merged, closed)
  * a PR's `mergeStateStatus` changes    (CONFLICTING -> MERGEABLE, BEHIND, BLOCKED ...)
  * a PR is updated                      (push, review, label — `updatedAt` moves)
  * a PR is marked ready / drafted       (`isDraft`)

A timer is still kept, deliberately: some work is only visible on a clock (a check that
never reports, a worker that dies silently, a stale claim). But the timer is now the
BACKSTOP, not the front end — `--backstop 1800` runs a pass even when nothing changed.

PROPERTIES THIS DELIBERATELY HAS
--------------------------------
* **One doctor at a time.** A lock file; a second instance exits 0 rather than piling up
  (the fleet has had three `auto-rail` instances and a `max=2` in the plist that the log
  never showed — concurrency must be visible and exclusive, not inferred).
* **Every decision is logged**, including `no change` and `throttled`, with the reason.
  A trigger that is silent when it does nothing is indistinguishable from a dead one.
* **It never invents work.** It runs the doctor; the doctor owns every repair decision.
* **Coalescing.** Rapid changes are debounced (`--debounce`) so a push that fires five
  events, or a wave of check completions, produces ONE pass.
* **Fail visible.** A doctor exit that is neither 0 nor 2 (2 = "refused with a reason")
  is logged as `DOCTOR-FAILED` and does not consume the backstop window, so a later tick
  retries instead of waiting half an hour on a crash. A doctor that is not there at all is
  `DOCTOR-MISSING` — never a clean window (CPython exits 2 for "can't open file", and 2 is
  the code this file treats as clean).
* **AN UNREADABLE SURFACE IS NOT A QUIET ONE.** A failed `gh pr list` is never folded into
  "no PRs need work" (#2271: an empty check surface read as green). It is logged as
  `PR-SURFACE-UNREADABLE`, the previous fingerprint is KEPT (so the surface cannot read as
  "changed" by going blind), and it is never treated as evidence of anything. The same holds
  for an answer that ARRIVES but is not a PR list — empty stdout, `{}`, `null`, `[1,2]` are
  `PR-SURFACE-UNPARSEABLE`, and the ONLY spelling of a genuinely empty surface is `[]`.
  Under `--once` a degraded read exits 2 rather than reporting "nothing to do".
* **A PENDING CHANGE SURVIVES A RESTART.** The debounce timestamp is persisted with the
  fingerprint and cleared only when a pass completes, so a `Restart=always` restart inside the
  coalescing window resumes the change instead of comparing the new surface against a fingerprint
  already saved and concluding "no change" (which silently dropped it).

WHY A RETRY FLOOR AND NOT "RETRY NEXT TICK"
-------------------------------------------
The spec shape is `last_pass = 0` on a failed pass, so the next tick retries — right, because a
crash must not buy 30 minutes of silence. But `pr-doctor` has a THIRD non-clean exit that is not
a crash: `EXIT_UNDELIVERED = 3` ("I read the world, I placed the work, no worker took it") — that
is the live verdict on this box right now (`pr-doctor.status.json`: `rc: 3`,
`reason: "live-unreadable=3; 3 order(s) no worker accepted"`). Treating 3 like a crash retries a
FULL pass — every open PR read, up to `--max` load-gated spawns — every `--poll` (60 s) for as
long as the condition lasts. That is not "retrying soon", it is a hot loop of the most expensive
read the fleet has. `--retry-min` (default 300 s) keeps the intent ("retry, do not wait for the
backstop") while bounding the spend. A crashed pass is still retried within five minutes instead
of half an hour, which is the whole point of not consuming the backstop window.

USAGE
    pr-doctor-trigger.py --repo daniel-ospina/agent-infra --repo-dir ~/src/agent-infra
    (defaults: --poll 60 --debounce 90 --backstop 1800 --max 8 --retry-min 300)

    --once           one poll, one decision, exit — what a `Restart=always` unit's ExecStart
                     wants when the supervisor restarts the process, and what a test drives
    --dry-run-print  print the fingerprint and exit 0 (debugging; no doctor, no lock)
"""
from __future__ import annotations

import argparse
import fcntl
import json
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
DOCTOR = os.path.join(HERE, "pr-doctor.py")


def log(msg: str) -> None:
    print("[%s] trigger: %s" % (time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), msg), flush=True)


def fingerprint(repo: str) -> tuple[str, int] | None:
    """Cheap read of the PR surface. Returns (fingerprint, open_pr_count) or None on failure.

    ONE call, no per-PR data: `statusCheckRollup` would make this O(PRs) requests and defeat
    the point of a 60 s poll. `updatedAt` moves on push/review/label, which is what we need.

    ⛔ AN UNUSABLE ANSWER IS NEVER AN EMPTY ONE (#2271, review cycle 1). `gh` can exit 0 and still
    hand back something that is not a PR list — empty stdout, `{}`, `null`, `{"data": []}`, `[1,2]`.
    Every one of those is a FAILED READ, and the measured consequence of conflating them with `[]`
    is the exact failure class this file exists to avoid: an unusable surface read as "no PRs need
    work". Two of them (`{}` and empty stdout) did exactly that before this was fixed — `{}
    iterates its KEYS, so it produced zero rows and a legitimate-looking empty fingerprint, and
    `r.stdout or "[]"` MANUFACTURED the empty list out of nothing. Three others (`null`, a dict,
    a list of scalars) raised, which under `Restart=always` is a restart loop converging to
    `failed`. So: a real empty surface is the JSON list `[]` and NOTHING ELSE.
    """
    try:
        r = subprocess.run(
            ["gh", "pr", "list", "--repo", repo, "--state", "open", "--limit", "200",
             "--json", "number,mergeStateStatus,updatedAt,isDraft"],
            capture_output=True, text=True, timeout=180,
        )
    except subprocess.TimeoutExpired:
        log("PR-SURFACE-UNREADABLE timeout=180 -- gh did not answer; not treating that as quiet")
        return None
    except OSError as e:
        # A MISSING gh BINARY IS A BROKEN READ, NOT A QUIET QUEUE. Raising here killed the trigger
        # with a traceback (invisible in a journal unless someone reads it) instead of naming it.
        log("PR-SURFACE-UNREADABLE gh is not runnable (%s) -- not treating that as quiet" % e)
        return None
    if r.returncode != 0:
        log("PR-SURFACE-UNREADABLE rc=%d stderr=%s -- not treating an unreadable surface as quiet"
            % (r.returncode, (r.stderr or "").strip()[:200]))
        return None
    raw = (r.stdout or "").strip()
    if not raw:
        log("PR-SURFACE-UNPARSEABLE empty stdout with rc=0 -- a real empty surface prints `[]`")
        return None
    try:
        prs = json.loads(raw)
    except json.JSONDecodeError as e:
        log("PR-SURFACE-UNPARSEABLE %s" % e)
        return None
    if not isinstance(prs, list):
        log("PR-SURFACE-UNPARSEABLE the payload is %s, not a list of PRs" % type(prs).__name__)
        return None
    if any(not isinstance(p, dict) for p in prs):
        log("PR-SURFACE-UNPARSEABLE the payload carries a non-object element -- not a PR list")
        return None
    rows = sorted((p.get("number"), p.get("mergeStateStatus"), p.get("updatedAt"), bool(p.get("isDraft")))
                  for p in prs)
    return ("|".join("%s:%s:%s:%s" % t for t in rows), len(rows))


# `run_doctor` returns this when there is no doctor to run. It is deliberately NOT 2: `pr-doctor`
# reserves 2 for "I could not read the world, or could not deliver" and the pass DID NOT RUN here,
# so the two must not share a code path. Distinct value + its own log line = a distinguishable
# verdict rather than a second meaning for an existing one.
DOCTOR_MISSING = 127


def run_doctor(repo: str, repo_dir: str, max_n: int) -> int:
    # ⛔ THE DOCTOR MUST EXIST BEFORE IT IS COUNTED AS A PASS (review cycle 1, reproducced). CPython
    # exits **2** for "can't open file", and 2 is the code this trigger treats as a CLEAN window —
    # so a trigger whose doctor was never farmed (or was deleted) reported `DOCTOR-END rc=2`, saved
    # `last_pass = now`, consumed the whole 1800 s backstop window and exited 0 under `--once`.
    # That is byte for byte the state `pi-bootstrap/setup.sh`'s farm order exists to prevent ("a
    # trigger with no doctor ... would look like a running repair service and start nothing"), and
    # the farm order cannot prevent it outside the farm (a hand copy, a deleted file).
    if not os.path.isfile(DOCTOR):
        log("DOCTOR-MISSING %s -- nothing was attempted; NOT a clean window" % DOCTOR)
        return DOCTOR_MISSING
    env = dict(os.environ)
    env["GH_REPO"] = repo
    env["PR_DOCTOR_REPO"] = repo
    env["PR_DOCTOR_REPO_DIR"] = repo_dir
    env["OBJECTIVE_REPO"] = repo          # the classifier defaults to tortoise; a worker must never be
    log("DOCTOR-START repo=%s dir=%s max=%d" % (repo, repo_dir, max_n))
    try:
        r = subprocess.run([sys.executable, DOCTOR, "--max", str(max_n)], env=env, timeout=3600)
    except subprocess.TimeoutExpired:
        log("DOCTOR-FAILED timeout=3600 -- the pass did not finish; not counting it as a clean window")
        return 124
    log("DOCTOR-END rc=%d" % r.returncode)
    return r.returncode


def load_state(path: str) -> dict:
    """The last fingerprint and the two clocks. An unreadable/unparseable state file is COLD, not
    quiet: `{}` means "no memory", which runs a pass rather than skipping one."""
    try:
        with open(path) as fh:
            d = json.load(fh)
        return d if isinstance(d, dict) else {}
    except (OSError, json.JSONDecodeError):
        return {}


def save_state(path: str, st: dict) -> None:
    try:
        tmp = path + ".tmp"
        with open(tmp, "w") as fh:
            json.dump(st, fh, sort_keys=True)
        os.replace(tmp, path)
    except OSError as e:
        # A state write we could not make is a trigger that will re-run the pass next start.
        # Loud, because "the trigger keeps running a cold pass" is otherwise unexplainable.
        log("STATE-UNWRITABLE %s: %s" % (path, e))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", required=True)
    ap.add_argument("--repo-dir", required=True)
    ap.add_argument("--poll", type=int, default=60)
    ap.add_argument("--debounce", type=int, default=90)
    ap.add_argument("--backstop", type=int, default=1800)
    ap.add_argument("--max", type=int, default=8, dest="max_n")
    ap.add_argument("--retry-min", type=int, default=300, dest="retry_min",
                    help="floor between retries of a FAILED pass (see WHY A RETRY FLOOR)")
    ap.add_argument("--state-dir", default="/tmp",
                    help="where the lock and the remembered fingerprint live (default /tmp; "
                         "tests point this at a temp dir so a real trigger is never disturbed)")
    ap.add_argument("--once", action="store_true",
                    help="one poll, one decision, exit — a supervisor's ExecStart")
    ap.add_argument("--dry-run-print", action="store_true",
                    help="print the fingerprint and exit; no lock, no doctor")
    a = ap.parse_args()

    if a.dry_run_print:
        res = fingerprint(a.repo)
        if res is None:
            print("UNREADABLE")
            return 2
        print(res[0])
        print("prs=%d" % res[1], file=sys.stderr)
        return 0

    os.makedirs(a.state_dir, exist_ok=True)
    base = a.repo.split("/")[-1]
    lock_path = os.path.join(a.state_dir, "pr-doctor-trigger-%s.lock" % base)
    state_path = os.path.join(a.state_dir, "pr-doctor-trigger-%s.state.json" % base)
    lock = open(lock_path, "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        log("ALREADY-RUNNING (%s held) -- exiting rather than running a second doctor" % lock_path)
        return 0

    st = load_state(state_path)
    log("START repo=%s poll=%ds debounce=%ds backstop=%ds max=%d retry_min=%ds once=%s state=%s"
        % (a.repo, a.poll, a.debounce, a.backstop, a.max_n, a.retry_min, a.once, state_path))

    # In LOOP mode a change must SURVIVE `--debounce` before it runs: a push fires several
    # `updatedAt` moves and a wave of check completions fires several more, and each is a real
    # surface change. In `--once` mode there is no later tick to coalesce with, so the change runs
    # immediately — a supervisor restart must not add 90 s of sleep before the first pass.
    # ⛔ THE PENDING CHANGE IS PERSISTED, NOT JUST REMEMBERED (review cycle 1, reproduced). It lived
    # only in this process while the FINGERPRINT was written to disk immediately, so a restart
    # inside the debounce window compared the new surface against the already-saved fingerprint,
    # found "no change", and the change was NEVER RUN — silently, forever. With `Restart=always`
    # and `RestartSec=15` a restart inside the window is ordinary (deploy, `systemctl restart`, OOM,
    # a crash between the save and the pass). `pending_since` is cleared only when a pass completes.
    changed_at: float | None = float(st["pending_since"]) if st.get("pending_since") else None
    if changed_at is not None:
        log("RESUMING a pending change from %s (a restart inside the debounce window)"
            % time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(changed_at)))

    while True:
        res = fingerprint(a.repo)
        fp, count = (None, 0) if res is None else res
        now = time.time()
        last_fp = st.get("fingerprint")

        # ── 1. OBSERVE ───────────────────────────────────────────────────────────────────────
        cold = change_seen = False
        if fp is not None and fp != last_fp:
            if last_fp is None:
                cold = True                      # no memory at all: a fresh process owes one pass
            else:
                change_seen = True
                changed_at = now
                st["pending_since"] = now
            st["fingerprint"] = fp
            save_state(state_path, st)
            if change_seen:
                log("CHANGE prs=%d -- %s" % (count, "no coalescing in --once mode" if a.once
                                             else "debouncing %ds" % a.debounce))
            else:
                log("COLD prs=%d -- first read, one pass owed" % count)
        elif fp is None and last_fp is not None:
            # KEEP the old fingerprint: going blind is not a change. If the surface comes back
            # with the same content, nothing happened and no pass is owed — and if it comes back
            # DIFFERENT, that difference is real and does run.
            log("SURFACE-DEGRADED (keeping the last fingerprint) -- unreadable is not a change")

        # ── 2. DECIDE ────────────────────────────────────────────────────────────────────────
        last_pass = float(st.get("last_pass") or 0.0)
        last_attempt = float(st.get("last_attempt") or 0.0)
        due_backstop = (now - last_pass) >= a.backstop and (now - last_attempt) >= a.retry_min
        # ⛔ THE PENDING CHANGE LIVES ACROSS TICKS (`changed_at`), NOT ACROSS ITERATIONS
        # (`change_seen`). A change is observed on ONE tick and must be acted on after the
        # debounce, which is by definition a LATER tick — reading the per-iteration flag here made
        # every coalesced change expire unseen (measured: five rapid changes produced ZERO passes
        # while the log said `CHANGE`).
        pending_change = changed_at is not None
        settled = pending_change and (now - changed_at) >= a.debounce
        due_change = cold or (pending_change and (a.once or settled))
        run = due_change or due_backstop
        why = "cold" if cold else ("change" if due_change else ("backstop" if due_backstop else "none"))

        # ⛔ A CHANGE THAT IS STILL SETTLING IS CHECKED BEFORE THE "nothing to do" BRANCH, because on
        # the tick where the change is first OBSERVED `run` is legitimately False (it is not settled
        # yet). Handling it after that branch made every coalescing window fall through to a full
        # `--poll` sleep, and the real lead therefore became `poll + ceil(debounce/poll)*poll` —
        # MEASURED at 180 s with the shipped `--poll 60 --debounce 90`, i.e. 30 s of pure
        # quantisation on top of the 150 s those two knobs name. The debounce is a DEADLINE: wake at
        # it (bounded by `poll`, so a clock jump cannot park the loop).
        if pending_change and not a.once and not settled:
            remaining = changed_at + a.debounce - now
            log("CHANGE settling %ds/%ds -- not running yet" % (int(now - changed_at), a.debounce))
            time.sleep(max(1.0, min(a.poll, remaining)))
            continue

        if not run:
            if a.once:
                if fp is None:
                    # ⛔ THE "UNREADABLE IS NOT QUIET" RULE HOLDS IN `--once` TOO (review cycle 1).
                    # This branch said `no change ... nothing to do` over a FAILED read, so a
                    # supervisor running `--once` reported a clean no-op on a surface it could not
                    # read — the #2271 conflation, in the one mode the unit's ExecStart uses.
                    log("SURFACE-DEGRADED -- unreadable; NOTHING attempted (this is not a quiet "
                        "surface)")
                    return 2
                log("no change prs=%d reason=%s -- nothing to do" % (count, why))
                return 0
            if fp is None:
                log("SURFACE-DEGRADED -- unreadable; would run the backstop, not a pass")
            else:
                log("no change prs=%d next_backstop=%ds" % (count, int(a.backstop - (now - last_pass))))
            time.sleep(a.poll)
            continue

        # ── 3. ACT — the doctor owns every repair decision; this only starts it ─────────────
        log("PASS-BEGIN reason=%s prs=%d" % (why, count))
        rc = run_doctor(a.repo, a.repo_dir, a.max_n)
        now = time.time()
        st["last_attempt"] = now
        changed_at = None
        st.pop("pending_since", None)      # the change has been ACTED on; nothing is pending
        if rc in (0, 2):
            st["last_pass"] = now
        else:
            log("DOCTOR-FAILED rc=%d -- backstop window NOT consumed, next attempt after %ds"
                % (rc, a.retry_min))
            st["last_pass"] = 0.0
        save_state(state_path, st)
        if a.once:
            return 0 if rc in (0, 2) else 1
        continue


if __name__ == "__main__":
    sys.exit(main())
