#!/usr/bin/env python3
"""pr-doctor — drive every open PR toward `merged`, automatically.

WHY THIS EXISTS (2026-10-10). The objective is `BE ABLE TO MERGE` and `waiting` went 10 -> 25
in one day while the fleet worked hard the whole time. The work was never missing: the LAST
MILE had no automation. A failing check was reported as a "blocker" instead of being repaired,
so every CI failure -- which is a NORMAL step of merging -- became a line in a report.

    "whenever our tests discover something that needs fixing before running CI again, you label
     it as blocked instead of doing the work that is needed and continuing with the merge
     process (having to fix things is a natural part of the CI process)" -- owner, 2026-10-10

So this closes the loop. Each pass, for every open non-draft PR, it classifies the PR from
BRANCH-PROTECTION REALITY (never from a queue row) and DISPATCHES the work:

    ready        all required checks green + clean attestation at the current head
                 -> dispatch: call the rail
    no-checks    no required check has EVER run at this head
                 -> dispatch: re-trigger the workflows
    failing      a required check failed
                 -> dispatch: FIX it, then re-review, then rail -- in ONE run
    unreviewed   ai-review-gate is the only red and there is no attestation
                 -> dispatch: review, record, rail -- in ONE run
    running      a required check is still in flight -> skip (next pass)
    surface      the diff touches the SDK/MCP surface -> raise a USER QUESTION

THE FIVE HARD RULES (each one earned the hard way today):
  1. THE FIX AND THE RAIL CALL GO IN THE SAME BRIEF. The gap between "review recorded" and
     "rail called" cost #7906 35 min, #7922 25, #7904 90+, and produced 2 attestations in 2
     hours while 25 PRs waited. A brief that stops at "record" is a bug.
  2. NEVER DOUBLE-DISPATCH. One worker per PR; a cooldown; and a PR already in flight is skipped.
     Two workers fixing one PR is worse than one being slow.
  3. BOUNDED CONCURRENCY, FROM THE MACHINE. The box cannot take unbounded workers: its own CI
     fails under load (#5049, the load-dependent-timeout class). The cap is the machine's own
     MAX_FIX/MAX_REVIEW, and every spawn is load-gated inside `spawn-gate.sh` at the moment it
     starts -- never a private literal (#1873).
  4. IDEMPOTENT AND RESUMABLE. State lives on disk; a restart does not re-dispatch everything.
  5. LOG WHAT IT DID. The point is that work was DISPATCHED, not that a count was printed.

Usage:
    pr-doctor.py                 # one pass
    pr-doctor.py --dry-run       # show what it WOULD dispatch, send nothing
    pr-doctor.py --max 3         # cap concurrent dispatches this pass
    pr-doctor.py --status        # show state
"""
from __future__ import annotations

import argparse
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone

HOME = os.path.expanduser("~")
STATE_DIR = os.path.join(HOME, ".pi", "agent", "state")
STATE = os.path.join(STATE_DIR, "pr-doctor.json")
LOG = os.path.join(STATE_DIR, "pr-doctor.log")
REVIEWS = os.path.join(HOME, ".pi", "agent", "reviews")

REPO = "daniel-ospina/tortoise"
REPO_DIR = os.path.join(HOME, "Documents", "GitHub", "tortoise")
REPO_SLUG = "daniel-ospina-tortoise"

# ⛔ USE THE REAL gh BINARY, NOT THE `gh` ON PATH. On this box `~/.pi/agent/shims/gh` is a
# SYMLINK into ~/Documents (agent-infra/scripts/gh-shim/gh). macOS TCC protects ~/Documents
# and a launchd agent has no Full Disk Access to it, so executing the shim fails with
# "Operation not permitted" (verified rc=126) -- the job ran twice doing NOTHING while
# printing a plausible "no open PRs" line. ~/bin/gh is a real Mach-O binary outside the
# protected tree. The shim is the admin-merge GUARD (#984); this job only READS, so it does
# not need the guard. Landing still goes through the rail, in a lane.
GH = os.path.join(HOME, "bin", "gh")

# The 7 contexts that gate a merge (branch protection). NOTHING else counts as a blocker.
REQUIRED = ("pricing-artifact", "docs", "test-isolation", "license-surface",
            "legal-e2e", "python-ci-gate", "ai-review-gate")
GATE = "ai-review-gate"
GREEN = {"success", "neutral", "skipped"}
NONRED = {"cancelled", "stale"}

# Guards
COOLDOWN_S = 45 * 60          # do not re-dispatch the same PR inside this window
STALE_DISPATCH_S = 90 * 60    # a dispatch with no state change this old is retryable
SURFACE_FILES = ("tool_registry.py", "sdk.py", "surface-manifest")

# ── CAPACITY: the machine's own thresholds, never a private literal ─────────────────────
# ⛔ THIS FILE USED TO HARDCODE `MAX_INFLIGHT = 4` "fleet-wide". The box is configured for
# MAX_FIX=16 / MAX_REVIEW=12, so the PR chain -- the backlog drain -- was throttled to 4 while
# the rest of the fleet ran at the machine's real capacity, and neither the plist nor an
# operator could override it (the launch job passes no `--max`). The thresholds have ONE home:
# the orchestrator launchd plist that `install.sh` renders (README §4). launchd feeds its
# EnvironmentVariables to `orch-loop.sh`; pr-doctor reads the SAME block out of that file, so
# the two readers share one model and neither duplicates the values. The environment wins when
# present, so a cell's `keys.env`, a manual run or a test can supply them without a plist; the
# shipped defaults are `orch-loop.sh`'s `${VAR:-…}` fallbacks (pinned equal by
# `scripts/test_pr_doctor.py`) and are the last resort only.
ORCH_PLIST = os.path.join(HOME, "Library", "LaunchAgents", "com.eldato.orchestrator-loop.plist")
DEFAULT_MAX_FIX = 3
DEFAULT_MAX_REVIEW = 4

# ── SPAWN: the background dispatcher, and the worktree each worker gets ─────────────────
# ⛔ THIS REPLACES THE LANE TABLE. This job used to pick an EXISTING idle lane out of a roster
# and hand it the brief; when every lane was busy it logged "no idle lanes -- nothing dispatched"
# and gave up, so classified work sat unfixed while there was budget. The harness already ships
# the correct primitive: `nonblocking-dispatch.sh` launches a headless worker in the BACKGROUND
# and returns immediately, routing through `spawn-gate.sh`'s `run_agent()` so the worker gets the
# SAME load gate (and disk gate, wall-clock watchdog and walltime row) as every lane. This job
# CONSULTS it; it never spawns `pi` itself -- a second spawn path would diverge from that gate,
# and spawn-gate.test.sh's invoker census exists to refuse exactly that.
ORCH_DIR = os.environ.get("O") or os.path.join(HOME, "orchestrator")
NONBLOCKING_DISPATCH = os.path.join(ORCH_DIR, "nonblocking-dispatch.sh")
WORKTREE_ROOT = os.path.join(REPO_DIR, ".worktrees")
SPAWN_TIMEOUT_S = 2400        # wall-clock cap handed to the background worker
# ⛔ THE SPAWN CALL MUST NOT WAIT FOR THE WORKER -- AND A CAPTURED CALL DOES. `subprocess.run`
# blocks until EOF on the capture PIPE, not until the child exits; `nonblocking-dispatch.sh`
# backgrounds the worker with `( … ) <&- &`, which closes STDIN only, so the worker subshell
# INHERITED this process's stdout/stderr pipe and held it open for its entire life. MEASURED with
# the shipped script and a stub `run_agent`: capture=True took 5.02 s for a 5 s worker, capture=
# False 0.03 s. Every real brief is a fix->review->record->merge run, so the captured call always
# hit the timeout and returned rc=-1 (TimeoutExpired) about a spawn that HAD launched -- 120 s of
# dead time per PR, a false FAIL, and no state row, so every later pass re-spawned every
# actionable PR.
#
# ⚠️ THE PIPE-SHAPE ABOVE IS NOT GONE EVERYWHERE, WHICH IS WHY THE CALLER FIXES IT TOO. This file
# reaches the dispatcher at `$O/nonblocking-dispatch.sh`, a copy installed by hand (README §2) that
# can be OLDER than the shipped one; the shipped script now closes stdout/stderr in the worker
# subshell (`exec >/dev/null 2>&1`), and that is belt-and-braces for every OTHER captured caller.
# Neither half depends on the other: the call below runs non-captured, so it returns in
# milliseconds even against a stale deployed copy, and the harness closes the pipe so a stale
# CALLER cannot be held either. Do not delete one as "redundant" with the other standing.
#
# The verdict comes from the worker's own artifacts under `$O/bg` (see `_confirm`), never from the
# pipe. The timeout below is a guard on the DISPATCHER, which returns in well under a second -- not
# on the worker.
SPAWN_CALL_TIMEOUT_S = 120
# A gate refusal (AGENT_DISK_REFUSED=77 / AGENT_LOAD_REFUSED=75) consumed nothing, so it must not
# be recorded. `nonblocking-dispatch.sh` backgrounds `run_agent()` and returns 0 the moment the
# worker is launched, so the refusal code only ever lands in `$O/bg/<name>.rc`; this is the bound
# dispatch() gives it to appear before concluding that the worker launched.
# MEASURED on this box (4 cores, load 0.15) with the REAL spawn-gate.sh and MAX_LOAD=0, 8 runs:
# 32-36 ms from invocation to a newline-terminated code in `.rc` -- this window is ~28x that.
# It is a LATENCY OPTIMISATION, NOT THE AUTHORITY. On a box slow enough to outrun it the refusal
# lands after the row is written; `void_refused_rows()` re-reads the same durable artifact on the
# next pass and drops such a row, so the cooldown and the class slot are not burnt for 90 minutes.
CONFIRM_WINDOW_S = 1.0
# A worker's `.rc` is a verdict ONLY when the write is COMPLETE. `echo "$?" > "$RC"` writes e.g.
# `75\n`; a reader that lands mid-write sees `7`, and the old `int(fh.read().strip())` ACCEPTED it,
# `7` is not a refusal code, so dispatch() recorded as launched a spawn the gate had REFUSED.
# Require the trailing newline, so a partial write is never a verdict.
_RC_RE = re.compile(r"([0-9]{1,3})\n\Z")
GATE_REFUSALS = (75, 77)
# The gate's OWN refusal lines in the worker log (`spawn-gate.sh` writes them to `$log` BEFORE
# run_agent returns, and the harness writes `.rc` only after that). They are what separates "the
# gate refused, nothing consumed" from "a `pi` exited 75 for its own reason" -- the ambiguity
# spawn-gate.sh itself warns about. A test pins these literals against that file, so a reworded
# marker reddens the suite instead of silently making every refusal look like a dispatch.
REFUSAL_MARKERS = ("[load-gate] REFUSED", "[disk-gate] REFUSED")
# `run_agent` appends this line only AFTER `pi` has been waited on (spawn-gate.sh starts `pi >> $LOG`
# and writes this line after `wait`), so its presence in a log PROVES an agent ran -- and a gate
# refusal is written strictly BEFORE any agent starts. That makes it a one-way discriminator: agent
# output sits ABOVE this line, not below it, so nothing about the split matters -- presence is the
# whole test.
AGENT_RAN_MARKER = "[timeout] agent pid="
# The gate writes a line or two and refuses; only an agent can produce a large log. A log past this
# bound is therefore evidence of a run, and reading no further is what keeps this cheap.
REFUSAL_LOG_WINDOW = 64 * 1024
# A worker cannot outlive its own wall-clock cap (SPAWN_TIMEOUT_S) by more than the watchdog's
# grace, so a pid still `running` long after its `.started` stamp is a RECYCLED pid, not a worker.
WORKER_STALE_SLACK_S = 15 * 60

# A dispatch draws on the budget of the work it starts. `failing` needs code/CI repair (MAX_FIX);
# `no-checks` re-triggers the workflows and then runs the review+merge chain, so it is fix work;
# `unreviewed` is review work (MAX_REVIEW); `ready` is the terminal merge of an already-reviewed
# PR, so it rides the review chain. `running` never dispatches.
ACTION_CLASS = {"failing": "fix", "no-checks": "fix", "unreviewed": "review", "ready": "review"}


def now() -> float:
    return time.time()


def ts() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _orchestrator_env() -> dict:
    """The orchestrator's EnvironmentVariables -- the machine's capacity model, one home.

    `install.sh` renders this plist and launchd feeds the block to `orch-loop.sh`; reading the
    file is reading the SAME block, so this source never carries a private copy of the limits.
    An unreadable or absent plist is NOT an error here: the environment and then the shipped
    defaults still apply, and every read below is total.
    """
    try:
        with open(ORCH_PLIST, "rb") as f:
            pl = plistlib.load(f)
    except Exception:
        return {}
    # The ROOT shape is guarded too: `plistlib.load` happily returns a list/str/int for a
    # well-formed plist whose top level is not a mapping, and `pl.get` would then raise OUTSIDE
    # the try -- aborting the whole pass instead of falling back. Shape-guard the root, then the
    # EnvironmentVariables value.
    if not isinstance(pl, dict):
        return {}
    env = pl.get("EnvironmentVariables")
    return env if isinstance(env, dict) else {}


def capacity() -> dict:
    """MAX_FIX / MAX_REVIEW for THIS machine -- env first, then the orchestrator plist then
    the shipped defaults. The returned numbers are the same source `orch-loop.sh` reads."""
    cfg = _orchestrator_env()
    cfg.update(os.environ)

    def _limit(key, default):
        # ⛔ MATCH orch-loop.sh's is_num/is_limit EXACTLY: `0`, or a non-zero-leading
        # run of at most 9 digits. Do NOT use bare int(): it accepts `010`, `1_000`,
        # `+12` and ` 12`, all of which the loop's guards REJECT and coerce to the
        # default -- so int() would let pr-doctor read 10/1000/12/12 where the loop
        # runs 3, a fail-open divergence on the documented env-override path.
        raw = cfg.get(key)
        s = "" if raw is None else str(raw)
        if not re.fullmatch(r"0|[1-9][0-9]{0,8}", s):
            return default
        return int(s)

    return {"max_fix": _limit("MAX_FIX", DEFAULT_MAX_FIX),
            "max_review": _limit("MAX_REVIEW", DEFAULT_MAX_REVIEW)}


def pass_budgets(st: dict, cap: dict, total_override=None, now_epoch=None) -> dict:
    """Available dispatches this pass, per work class and in total.

    The machine's own MAX_FIX / MAX_REVIEW (see `capacity()`) set the per-class ceilings. A
    state row still inside STALE_DISPATCH_S consumes one slot of its class. `total_override`
    (the CLI `--max`) is an optional extra hard ceiling on the whole pass. Pure, so the cap
    can be asserted without a fleet.
    """
    if now_epoch is None:
        now_epoch = now()
    used = {"fix": 0, "review": 0}
    for k, v in st.items():
        if k.startswith("_") or v.get("action") == "closed":
            continue
        if now_epoch - v.get("at_epoch", 0) >= STALE_DISPATCH_S:
            continue
        used[ACTION_CLASS.get(v.get("action", ""), "fix")] += 1
    out = {c: max(0, cap["max_" + c] - used[c]) for c in ("fix", "review")}
    out["used"] = used["fix"] + used["review"]
    out["total"] = out["fix"] + out["review"]
    if total_override is not None:
        out["total"] = min(out["total"], max(0, total_override))
    return out


def log(msg: str) -> None:
    line = "[%s] pr-doctor: %s" % (ts(), msg)
    print(line, flush=True)
    try:
        os.makedirs(STATE_DIR, exist_ok=True)
        with open(LOG, "a") as f:
            f.write(line + "\n")
    except Exception:
        pass


def sh(args, timeout=180, cwd=None, env=None):
    try:
        r = subprocess.run(args, capture_output=True, text=True, timeout=timeout, cwd=cwd, env=env)
        return r.stdout
    except Exception as e:
        log("EXEC FAILED %s: %s" % (args[0], e))
        return ""


def sh_err(args, timeout=180, cwd=None, env=None, capture=True):
    """Same, but returns (stdout, stderr, rc) -- so a failed read is REPORTED, never empty.

    `capture=False` sends the child's STDOUT to DEVNULL and its STDERR to a temporary FILE, and
    returns ("", stderr, rc). Use it for a child that hands its real work to a BACKGROUND
    process: with `capture=True`, `subprocess.run` waits for EOF on the pipe -- i.e. for every
    background descendant that inherited it -- so the call lasts as long as the work it was
    supposed to start (SPAWN_CALL_TIMEOUT_S carries the measurement).

    ⛔ STDERR GOES TO A FILE, NEVER TO A PIPE **OR** TO DEVNULL. A pipe is what blocks; DEVNULL is
    what loses the dispatcher's own diagnosis (`spawn-gate.sh not found -- refusing to start an
    ungated worker`, `no worktree …`), which is the only thing that tells an operator why a
    permanent failure keeps happening. A regular file has neither problem: no EOF to wait for, and
    the text is still there when the call returns.
    """
    try:
        if not capture:
            with tempfile.TemporaryFile() as errf:
                r = subprocess.run(args, stdout=subprocess.DEVNULL, stderr=errf,
                                   timeout=timeout, cwd=cwd, env=env)
                errf.seek(0)
                return "", errf.read().decode("utf-8", "replace"), r.returncode
        r = subprocess.run(args, capture_output=True, text=True, timeout=timeout, cwd=cwd, env=env)
        return r.stdout, r.stderr, r.returncode
    except Exception as e:
        return "", "%s: %s" % (type(e).__name__, e), -1


# ---------------------------------------------------------------------------
# 1. READ THE WORLD — from GitHub, never from a queue row
# ---------------------------------------------------------------------------

def open_prs() -> list[dict]:
    out, err, rc = sh_err([GH, "pr", "list", "--repo", REPO, "--state", "open", "--limit", "60",
                           "--json", "number,title,isDraft,mergeStateStatus,headRefOid,headRefName,isCrossRepository,files"])
    try:
        prs = json.loads(out or "[]")
    except Exception:
        prs = []
    if not prs:
        # ⛔ A FAILED READ MUST NEVER BE REPORTED AS "no open PRs". That is how this job ran
        # twice under launchd doing NOTHING while printing a plausible, reassuring line --
        # the same silent-failure class this whole file exists to remove.
        log("GITHUB READ FAILED (rc=%s): %s | PATH=%s" %
            (rc, (err or "").strip()[:220] or "(empty stderr)", os.environ.get("PATH", "")[:120]))
    return prs


def rollup(number: int) -> tuple[dict, list[str], list[str], list[str]]:
    """(per-context newest attempt, failing, running, absent).

    Newest attempt per context by check-run `id` -- GitHub keeps EVERY re-run, and a re-run
    ADDS a red, it does not clear one. `started_at` is nullable so it is not the key.
    """
    raw = sh([GH, "pr", "view", str(number), "--repo", REPO, "--json", "statusCheckRollup"])
    try:
        det = json.loads(raw or "{}")
    except Exception:
        det = {}
    newest: dict[str, dict] = {}
    for c in det.get("statusCheckRollup") or []:
        name = c.get("name") or c.get("context") or "?"
        if name not in REQUIRED:
            continue
        cid = c.get("databaseId") or c.get("id") or 0
        prev = newest.get(name)
        if prev is None or cid > (prev.get("databaseId") or prev.get("id") or 0):
            newest[name] = c
    failing, running, absent = [], [], []
    for ctx in REQUIRED:
        c = newest.get(ctx)
        if c is None:
            absent.append(ctx)
            continue
        status = (c.get("status") or "").lower()
        concl = (c.get("conclusion") or "").lower()
        if status and status != "completed":
            running.append(ctx)
        elif concl in GREEN or concl in NONRED:
            pass
        else:
            failing.append(ctx)
    return newest, failing, running, absent


def attestation(number: int, head: str):
    path = os.path.join(REVIEWS, "%s-%d.json" % (REPO_SLUG, number))
    if not os.path.exists(path):
        return None
    try:
        with open(path) as f:
            rec = json.load(f)
    except Exception:
        return None
    if rec.get("head_sha") != head:
        return None                      # stale: bound to an older head, worth nothing
    if rec.get("verdict") != "clean":
        return None
    return rec


def classify(pr: dict) -> str:
    """One action per PR. First match wins, so no PR can hide in an overlap."""
    _, failing, running, absent = rollup(pr["number"])
    if running:
        return "running"                                  # not ours to act on yet
    if absent and not failing:
        return "no-checks"                                # CI never triggered
    if not failing:
        return "ready" if attestation(pr["number"], pr["headRefOid"]) else "unreviewed"
    others = [c for c in failing if c != GATE]
    if not others and not attestation(pr["number"], pr["headRefOid"]):
        return "unreviewed"                               # only the diff-bound gate is red
    return "failing"


# ---------------------------------------------------------------------------
# 2. MATERIALISE A WORKTREE — a fresh worker needs somewhere to run
# ---------------------------------------------------------------------------

class _Refusal(str):
    """A refusal message that also knows whether WAITING can clear it.

    `materialise_worktree` fails at eight sites and its callers unpack `(path, why)`, as do 25
    tests -- a third tuple element would churn all of them for one boolean. A `str` subclass keeps
    every existing `err == ""` / `"uncommitted" in err` check working while the flag rides along on
    the object, so only the sites that can say "this will not clear by itself" have to say it.
    """

    persistent = False

    def __new__(cls, msg, persistent=False):
        self = super().__new__(cls, msg)
        self.persistent = persistent
        return self


def materialise_worktree(pr: dict, dry: bool = False) -> tuple[str, str]:
    """Ensure a git worktree for the PR's branch at the PR's head; return (path, "") or ("", why).

    The worker must be ON the PR's branch at the PR's CURRENT head so a fixer pushes the right
    commit. Three facts drive the shape:

      * `git worktree list` / the worktree-ROOT test is the liveness authority, never a
        directory's `.git` file (which survives the record being removed) and never
        `--is-inside-work-tree` (which is true for ANY directory inside the main checkout).
      * FAIL-CLOSED, NEVER DESTRUCTIVE. A reused worktree whose head moved is reset to the PR head
        ONLY when it is clean; a DIRTY one is refused, never reset. A dangling directory is never
        deleted unless it holds nothing but a `.git` pointer -- a directory that may contain a
        previous worker's uncommitted work is left for inspection.
      * Only records whose directory is already GONE are cleared, so a live worktree can never be
        removed here. A dangling directory that holds anything is LEFT ALONE and the PR is
        materialised at a `-d` fallback path, so a previous worker's files survive.
      * A base-repo PR whose branch is ALREADY CHECKED OUT somewhere is ADOPTED at that worktree,
        not refused: git will not check one branch out twice, and the case is the normal one -- a
        PR a lane produced has its branch in that lane's own worktree.

    `dry=True` walks the SAME decision tree and returns the worktree it would use WITHOUT creating,
    fetching, checking out or resetting anything -- `--dry-run` used to return before this call and
    so reported "would spawn" precisely when the worktree was what would block.
    """
    branch = pr["headRefName"]
    head = pr["headRefOid"]
    # A fork PR's headRefName can COLLIDE with a base-repo branch (e.g. a fork of `main`), so branch
    # existence is NOT the fork discriminator -- GitHub's `isCrossRepository` is. A fork's head is
    # published in the base repo at refs/pull/<n>/head; a base PR is its own branch.
    fork = bool(pr.get("isCrossRepository"))
    fetch_ref = "refs/pull/%d/head" % pr["number"] if fork else ""
    # Two paths are ours for this PR: `prd-<n>`, and `prd-<n>-d` as a fallback when `prd-<n>` is
    # occupied by a dangling directory we must NOT delete (it may hold a previous worker's work).
    path = os.path.join(WORKTREE_ROOT, "prd-%d" % pr["number"])
    candidates = [path, path + "-d"]

    # A record whose directory is GONE blocks `worktree add` for ever -- "already checked out" for
    # our branch, "missing but already registered" for our own path. Clear ONLY those: stranded
    # records at our two candidate paths (exclusively ours), or for OUR branch anywhere. A record
    # whose directory still exists is never dropped here, so a live worktree is never removed.
    ours = set(candidates)
    for p, b in _worktrees():
        if not os.path.exists(p) and (p in ours or b == "refs/heads/%s" % branch):
            if not dry:
                _drop_worktree_record(p)

    # ADOPT A WORKTREE THE BRANCH IS ALREADY CHECKED OUT IN. A PR a lane produced has its branch
    # checked out in THAT LANE'S worktree (`git worktree list` on the box: `.worktrees/fix-1529
    # [fix/5389-a-fleet-veto]`, …), and `git worktree add <path> <branch>` REFUSES to check the
    # same branch out twice: rc=128 `'fix/x' is already used by worktree at …`. Merging the PR is
    # what frees that worktree, so failing here is a DEADLOCK for the normal case -- and the
    # retired lane-table path could still hand the brief to that lane. So adopt it: the worktree
    # is the lane's own, and the worker must be on the PR's branch anyway. `_ensure_head` still
    # refuses to reset a worktree holding uncommitted work or orphan-able commits, and dispatch()
    # RECORDS that refusal as a state row so the PR reaches a cooldown instead of retrying for ever.
    #
    # ⚠️ STATED RESIDUAL: liveness of the pr-doctor worker itself is checked in dispatch() before
    # this runs; liveness of a LANE worker in the adopted worktree is NOT checked here. The
    # dirty/ahead guards refuse the unsafe cases, and the box-wide lane liveness question has no
    # mechanical answer in this file (it lives in the fleet board, #8175).
    if not fork:
        branch_ref = "refs/heads/%s" % branch
        for p, b in _worktrees():
            if b != branch_ref:
                continue
            live = _live_worktree(p)
            if live is None:
                return "", ("cannot determine whether %s (already on %s) is a worktree (git probe "
                            "failed) -- refusing to adopt or reset it; inspect it" % (p, branch))
            if not live:
                continue      # exists but is not a worktree: not ours to adopt; `add` will report
            log("materialise: adopting %s, already on %s (the lane's own worktree)" % (p, branch))
            err = _ensure_head(p, branch, head, fetch_ref, dry=dry)
            return (p, "") if not err else ("", err)

    # Reuse any candidate that is already a live worktree. UNKNOWN is NOT reuse: `True` would run
    # `_ensure_head` -> `reset --hard` against whatever `git -C <path>` resolves to, which for a
    # non-worktree inside the main checkout is the MAIN repo (the very trap this PR fixes).
    for cand in candidates:
        live = _live_worktree(cand)
        if live is None:
            return "", ("cannot determine whether %s is a worktree (git probe failed) -- refusing "
                        "to reuse or delete it; inspect it" % cand)
        if live:
            err = (_ensure_branch(cand, branch, fork, dry=dry)
                   or _ensure_head(cand, branch, head, fetch_ref, dry=dry))
            return (cand, "") if not err else ("", err)

    # Materialise at the first candidate that is absent, or holds nothing but a dangling `.git`
    # pointer (disposable). A directory that might contain work is left alone for inspection.
    path = ""
    for cand in candidates:
        if os.path.islink(cand):
            # A symlink is never a free path: a DANGLING one fails `os.path.exists`, so without this
            # it would be chosen as "absent" and `worktree add` would fail "already exists" for ever.
            continue
        if not os.path.exists(cand):
            path = cand
            break
        if _disposable_dangling(cand):
            if not dry:
                log("materialise: clearing a dangling non-worktree at %s" % cand)
                shutil.rmtree(cand, ignore_errors=True)
            path = cand
            break
    if not path:
        return "", _Refusal(
            "%s and %s are both unusable (a symlink, a non-worktree directory, or an unremovable "
            "record) -- refusing to delete either; inspect and clean" % (candidates[0], candidates[1]),
            persistent=True)

    # A fork PR's headRefName can COLLIDE with a local branch, so branch existence is NOT the
    # fork discriminator (GitHub's `isCrossRepository` is). Only a base-repo PR checks out a named
    # branch; a fork PR is materialised DETACHED at refs/pull/<n>/head.
    if fork:
        if dry:
            return path, ""     # a real run would fetch refs/pull/<n>/head and add the worktree
        ref = "refs/pull/%d/head" % pr["number"]
        _, ferr, frc = _git(["fetch", "origin", ref, "--quiet"], timeout=300)
        if frc != 0:
            return "", "cannot materialise fork PR %d: %s could not be fetched (%s)" % (
                pr["number"], ref, (ferr or "").strip()[:160])
        argv = ["worktree", "add", "--detach", path, "FETCH_HEAD"]
    else:
        _, _, rc = sh_err(["git", "-C", REPO_DIR, "rev-parse", "--verify", "-q",
                           "refs/heads/%s" % branch], timeout=60)
        if rc == 0:
            argv = ["worktree", "add", path, branch]
        else:
            if dry:
                return path, ""   # a real run would fetch origin/<branch> and create the branch
            _, ferr, frc = _git(["fetch", "origin", branch, "--quiet"], timeout=300)
            if frc != 0:
                return "", "cannot materialise %s: origin/%s could not be fetched (%s)" % (
                    branch, branch, (ferr or "").strip()[:160])
            argv = ["worktree", "add", path, "-b", branch, "origin/%s" % branch]
    if dry:
        log("materialise: DRY-RUN would run `git %s`" % " ".join(argv))
        return path, ""
    _, err, rc = _git(argv, timeout=300)
    if rc != 0:
        return "", "worktree add failed rc=%s: %s" % (rc, (err or "").strip()[:200] or "(no stderr)")
    if not _live_worktree(path):
        return "", "worktree add reported success but %s is not a live worktree" % path
    # A local branch can be BEHIND the PR head; verify and move it, but never over dirty work.
    err = _ensure_branch(path, branch, fork) or _ensure_head(path, branch, head, fetch_ref)
    return (path, "") if not err else ("", err)


def _git(args, timeout=120):
    return sh_err(["git", "-C", REPO_DIR] + list(args), timeout=timeout)


def _live_worktree(path: str):
    """True iff git proves <path> is a DISTINCT worktree rooted at <path>; False if it proves not;
    None if a probe could not answer.

    Two checks, because `--show-toplevel == path` alone is not proof:
      * toplevel must equal realpath(path) -- rejects a subdirectory of the main checkout; and
      * the worktree's git dir must DIFFER from its common git dir (a linked worktree has
        `<repo>/.git/worktrees/<name>` vs `<repo>/.git`). A SYMLINK to the main checkout, or a
        `.git` FILE pointing at the main git dir, both satisfy the toplevel check but have the
        two EQUAL -- and acting on them resets the MAIN checkout.

    UNKNOWN (rc < 0) returns None, and the caller REFUSES: treating it as live selects the
    reuse/reset branch (destructive against the main checkout); treating it as dead enters the
    delete branch. Neither is safe.
    """
    if os.path.islink(path):
        return False        # a symlink is an alias to somewhere else -- never a worktree we own
    out, _, rc = sh_err(["git", "-C", path, "rev-parse", "--show-toplevel",
                         "--absolute-git-dir"], timeout=30)
    if rc < 0:
        return None
    if rc != 0:
        return False
    lines = (out or "").splitlines()
    if len(lines) < 2:
        return False
    if os.path.realpath(lines[0].strip()) != os.path.realpath(path):
        return False
    gd = os.path.realpath(lines[1].strip())
    cd, _, crc = sh_err(["git", "-C", path, "rev-parse", "--git-common-dir"], timeout=30)
    if crc < 0:
        return None
    if crc != 0:
        return False
    cdp = (cd or "").strip()
    if not os.path.isabs(cdp):
        cdp = os.path.join(path, cdp)
    if gd == os.path.realpath(cdp):
        return False                                # main checkout (or an alias of it)
    # IDENTITY: the worktree record must point back at THIS path. A `.git` FILE pointing at
    # ANOTHER worktree's git dir has git-dir != common-dir too, so without this it would be
    # accepted and we would switch that other worktree's branch out from under it.
    try:
        with open(os.path.join(gd, "gitdir")) as fh:
            back = fh.read().strip()
    except OSError:
        return False
    if not back:
        return False
    if not os.path.isabs(back):
        back = os.path.join(gd, back)
    return os.path.dirname(os.path.realpath(back)) == os.path.realpath(path)


def _disposable_dangling(path: str) -> bool:
    """A directory we own that holds NOTHING, or only a dangling `.git` pointer FILE.

    ⛔ A `.git` DIRECTORY is a repository's object store, not a worktree pointer; deleting it can
    destroy recoverable commits, so it is never disposable. A SYMLINK is never disposable either:
    `os.listdir` follows it (so an empty target looks empty) while `shutil.rmtree` refuses it, and
    `git worktree add` would then follow the symlink and materialise the worktree in the TARGET.
    """
    if os.path.islink(path):
        return False
    try:
        entries = os.listdir(path)
    except OSError:
        return False
    if not entries:
        return True
    if set(entries) != {".git"}:
        return False
    return os.path.isfile(os.path.join(path, ".git"))


def _ensure_branch(path: str, branch: str, fork: bool = False, dry: bool = False) -> str:
    """Ensure a reused worktree is on the PR branch (base-repo PR) or DETACHED (fork PR); "" on
    success, else why.

    The reuse path used to reset whatever HEAD it found, so a worktree left on another branch (or
    detached) was silently reused and the worker's `git push` landed on the wrong branch. `fork`
    comes from GitHub's `isCrossRepository`, NOT from branch-name existence -- a fork's headRefName
    can collide with a local branch (e.g. a fork of `main`). A base-repo worktree is attached to
    its branch; a fork worktree is detached. Work that moving HEAD would lose (tracked changes,
    orphaned detached commits, colliding untracked/ignored files) is refused.
    """
    out, _, rc = sh_err(["git", "-C", path, "symbolic-ref", "--short", "HEAD"], timeout=30)
    cur = (out or "").strip()
    detached = rc != 0
    if fork:
        if detached:
            return ""
        if dry:
            return ""            # a real run would `checkout --detach`; a dry run touches nothing
        # Detaching keeps the tree, so no file is touched and the foreign branch keeps its commits.
        _, err, xrc = sh_err(["git", "-C", path, "checkout", "--detach"], timeout=180)
        if xrc != 0:
            return "worktree %s is on foreign branch %s and could not be detached: %s" % (
                path, cur, (err or "").strip()[:160])
        return ""
    if not detached and cur == branch:
        return ""
    dirty, _, drc = sh_err(["git", "-C", path, "status", "--porcelain",
                            "--untracked-files=no"], timeout=60)
    if drc != 0:
        return ("cannot determine whether worktree %s is clean (git status rc=%s) -- refusing to "
                "switch branch; inspect and clean it" % (path, drc))
    if (dirty or "").strip():
        return _Refusal("worktree %s is on a different branch/HEAD and has uncommitted tracked "
                        "changes -- refusing to switch it to %s; inspect and clean it"
                        % (path, branch), persistent=True)
    if detached:
        # Moving off a DETACHED commit no ref holds would orphan it.
        holders, _, hrc = sh_err(["git", "-C", path, "for-each-ref", "--contains", "HEAD",
                                  "--format=%(refname)", "refs/heads", "refs/remotes"], timeout=60)
        if hrc != 0:
            return "cannot determine which refs hold worktree %s commits -- refusing to switch it" % path
        if not (holders or "").strip():
            return _Refusal("worktree %s is detached with commit(s) held by no branch -- refusing "
                            "to switch it and orphan them; create a branch or inspect it" % path,
                            persistent=True)
    # `checkout <branch>` changes the tree; git protects non-ignored untracked files but SILENTLY
    # OVERWRITES ignored ones (verified), so probe the target branch for both.
    clobber = _untracked_clobber(path, branch)
    if clobber is None:
        return ("cannot determine whether switching worktree %s to %s would overwrite untracked "
                "files -- refusing; inspect it" % (path, branch))
    if clobber:
        return _Refusal("worktree %s has untracked file(s) that %s would overwrite (%s) -- "
                        "refusing to switch it; move or remove them"
                        % (path, branch, ", ".join(clobber[:3])), persistent=True)
    if dry:
        return ""                # a real run would `checkout`; a dry run touches nothing
    _, err, xrc = sh_err(["git", "-C", path, "checkout", branch], timeout=180)
    if xrc != 0:
        return "worktree %s could not be switched to %s: %s" % (
            path, branch, (err or "").strip()[:160])
    return ""


def _untracked_clobber(path: str, head: str):
    """UNTRACKED or IGNORED paths that a `reset --hard <head>` (or a `checkout <head>` of the
    tree) would overwrite/delete, or None if UNKNOWN.

    `reset --hard`/`checkout` leave NON-colliding untracked files alone, but DELETE one that
    occupies a path the target tree tracks -- INCLUDING an IGNORED one, which git overwrites
    silently (verified). Guarding on tracked changes only would lose such a file; guarding on
    every scratch file is a false block. This checks the exact set, ignored files included
    (`--ignored=matching` lists an ignored directory as one `!! dir/` entry, so this stays cheap).
    """
    out, _, rc = sh_err(["git", "-C", path, "status", "--porcelain", "-z",
                         "--ignored=matching", "--untracked-files=all"], timeout=60)
    if rc != 0:
        return None
    untracked = []
    for f in (out or "").split("\0"):
        if f.startswith("?? "):
            untracked.append(f[3:])
        elif f.startswith("!! "):
            untracked.append(f[3:].rstrip("/"))
    if not untracked:
        return []
    tree, _, trc = sh_err(["git", "-C", path, "ls-tree", "-r", "--name-only", "-z", head], timeout=60)
    if trc != 0:
        return None
    tracked = set((tree or "").split("\0"))

    # Conflict is by PATH COMPONENT, not string equality: an untracked `dir/precious` collides with
    # a tracked FILE `dir` (and a tracked `dir/file` with an untracked FILE `dir`). Equality alone
    # misses both, and `reset --hard` deletes the untracked side (verified).
    def _conflicts(u):
        for t in tracked:
            if u == t or u.startswith(t + "/") or t.startswith(u + "/"):
                return True
        return False

    return sorted(u for u in untracked if _conflicts(u))


def _ensure_head(path: str, branch: str, head: str, fetch_ref: str = "", dry: bool = False) -> str:
    """Move <path> to <head>; "" on success, else why. NEVER resets a DIRTY worktree."""
    out, _, rc = sh_err(["git", "-C", path, "rev-parse", "HEAD"], timeout=30)
    if rc == 0 and (out or "").strip() == head:
        return ""
    _, _, have = sh_err(["git", "-C", path, "cat-file", "-e", "%s^{commit}" % head], timeout=30)
    if have != 0:
        if dry:
            return ""        # a real run would fetch `fetch_ref`/`branch` first -- nothing to prove
        # A fork PR's head lives at refs/pull/<n>/head, NOT origin/<branch> (which does not exist
        # for a fork). Fetching the WRONG ref leaves the object absent and every later probe fails
        # with a misleading error, so fetch the right one and name a persistent absence clearly.
        sh_err(["git", "-C", path, "fetch", "origin", fetch_ref or branch, "--quiet"], timeout=300)
        _, _, have = sh_err(["git", "-C", path, "cat-file", "-e", "%s^{commit}" % head], timeout=30)
        if have != 0:
            return ("PR head %s is not present locally and could not be fetched -- refusing to "
                    "reset worktree %s" % (head[:12], path))
    # ⛔ An unanswerable cleanliness probe is NOT "clean": `dirty` is empty on rc != 0, so the
    # old `if dirty.strip()` fell through to `reset --hard` and destroyed uncommitted work.
    dirty, _, drc = sh_err(["git", "-C", path, "status", "--porcelain",
                            "--untracked-files=no"], timeout=60)
    if drc != 0:
        return ("cannot determine whether worktree %s is clean (git status rc=%s) -- refusing to "
                "reset it; inspect and clean it" % (path, drc))
    if (dirty or "").strip():
        return _Refusal("worktree %s is at a different head and has uncommitted tracked changes "
                        "-- refusing to reset it; inspect and clean it" % path, persistent=True)
    clobber = _untracked_clobber(path, head)
    if clobber is None:
        return ("cannot determine whether resetting worktree %s would overwrite untracked files "
                "-- refusing; inspect it" % path)
    if clobber:
        return _Refusal("worktree %s has untracked file(s) that the PR head would overwrite (%s) "
                        "-- refusing to reset it; move or remove them"
                        % (path, ", ".join(clobber[:3])), persistent=True)
    # ⛔ A CLEAN worktree can still hold LOCAL COMMITS the PR head does not (a worker committed but
    # had not pushed, or the state row went stale). `reset --hard` would rewind the branch and
    # ORPHAN them. Only a fast-forward (HEAD an ancestor of head) may reset.
    ahead, _, arc = sh_err(["git", "-C", path, "rev-list", "--count", "%s..HEAD" % head], timeout=60)
    if arc != 0:
        return ("cannot determine whether worktree %s has commits the PR head does not "
                "(git rev-list rc=%s) -- refusing to reset it; inspect it" % (path, arc))
    try:
        n_ahead = int((ahead or "0").strip() or "0")
    except ValueError:
        return "cannot parse the commit count for worktree %s -- refusing to reset it" % path
    if n_ahead > 0:
        cur, _, curc = sh_err(["git", "-C", path, "symbolic-ref", "--short", "-q", "HEAD"], timeout=30)
        if curc == 0:
            return _Refusal("worktree %s is on %s and has %d commit(s) not on the PR head -- "
                            "refusing to reset it and orphan them; push or inspect the worktree"
                            % (path, (cur or "").strip(), n_ahead), persistent=True)
        # Detached: safe only when some OTHER ref still holds the commits.
        holders, _, hrc = sh_err(["git", "-C", path, "for-each-ref", "--contains", "HEAD",
                                  "--format=%(refname)", "refs/heads", "refs/remotes"], timeout=60)
        if hrc != 0:
            return "cannot determine which refs hold worktree %s commits -- refusing to reset it" % path
        if not (holders or "").strip():
            return _Refusal("worktree %s is detached and has %d commit(s) held by no branch -- "
                            "refusing to reset it and orphan them; create a branch or inspect it"
                            % (path, n_ahead), persistent=True)
    if dry:
        return ""                    # a real run would `reset --hard`; a dry run touches nothing
    _, err, rc = sh_err(["git", "-C", path, "reset", "--hard", head], timeout=120)
    if rc != 0:
        return "worktree %s reset to %s failed rc=%s: %s" % (path, head[:12], rc, (err or "").strip()[:160])
    return ""


def _worktrees() -> list[tuple[str, str]]:
    """[(path, branch-ref)] from `git worktree list --porcelain`; [] if it cannot be read.

    A DETACHED worktree (the fork-PR path creates one) has no `branch ` line; its ref is "". It
    must still be listed, or a stranded detached record at one of our paths can never be cleared
    and `worktree add` fails with "missing but already registered" for ever.
    """
    out, _, rc = _git(["worktree", "list", "--porcelain"], timeout=60)
    if rc != 0:
        return []
    rows, cur, ref = [], None, ""
    for line in (out or "").splitlines():
        if line.startswith("worktree "):
            if cur is not None:
                rows.append((cur, ref))
            cur, ref = line[len("worktree "):], ""
        elif line.startswith("branch "):
            ref = line[len("branch "):].strip()
        # `detached` / `bare` leave ref="" -- still a record we may need to clear.
    if cur is not None:
        rows.append((cur, ref))
    return rows


def _drop_worktree_record(path: str) -> None:
    """Targeted removal of one record. NEVER a bare `git worktree prune` (#1141).

    DOUBLE `--force`: a single force does NOT remove a LOCKED record, so a locked stranded record
    would survive and `worktree add` would fail with "missing but locked" for ever.
    """
    _, err, rc = _git(["worktree", "remove", "--force", "--force", path], timeout=120)
    if rc != 0:
        log("worktree remove of stranded record %s failed rc=%s: %s"
            % (path, rc, (err or "").strip()[:160]))


# ---------------------------------------------------------------------------
# 3. THE BRIEF — fix -> review -> record -> rail, ONE RUN, no gap
# ---------------------------------------------------------------------------

def brief(pr: dict, action: str) -> str:
    n = pr["number"]
    head = pr["headRefOid"]
    title = pr["title"][:80]
    _, failing, _, absent = rollup(n)

    # ⛔ A FORK PR HAS NO BRANCH HERE TO PUSH AT ALL, AND THE BRIEF USED TO SAY "push". Its head is
    # `refs/pull/<n>/head`, which is READ-ONLY from this repo: the head branch lives in the
    # contributor's fork and is not a branch here, so a push from the fork worktree has nowhere to
    # go. The fixer's commits stay unpublishable, and `_ensure_head` then refuses that worktree for
    # ever (commits no branch holds) -- a silent dead end for the PR. So the fork contract states
    # the truth and asks for the patch instead. A base-repo PR gets the explicit refspec, which is
    # the form that works from an ATTACHED *or* a DETACHED worktree (the fork path is detached, and
    # an adopted lane worktree may be detached too).
    if pr.get("isCrossRepository"):
        push = """## THIS IS A FORK PR — THERE IS NO BRANCH HERE TO PUSH
Your worktree is **DETACHED** at `refs/pull/{n}/head`, which is READ-ONLY from this repo: the head
branch lives in the contributor's fork and is not a branch here. So do NOT push and do NOT create a
branch -- the commits would have nowhere to go, and a committed-but-unpushable worktree makes every
later pass refuse this PR. Instead: make the change, verify it, and put the exact patch
(`git diff`) plus your reasoning in your FINAL MESSAGE for a maintainer to apply. Report
`patch ready` (or the blocker), NOT `fixed`.
""".format(n=n)
    else:
        push = """## PUSHING — works from an ATTACHED or a DETACHED worktree
```
git push origin HEAD:refs/heads/{branch}
```
Use that explicit refspec, never a bare `git push`.
""".format(branch=pr["headRefName"])

    common = """
## The loop — do all of it in ONE run, never stop in between
1. Resolve what this PR needs (below).
2. Get it REVIEWED in a fresh context: dispatch a `task` sub-agent (NEVER review your own work).
   Only a verbatim `NO ISSUES FOUND` is clean. Issues found -> fix -> RE-REVIEW.
3. RECORD at the CURRENT head:
   `scripts/record-review.sh {n} <HEAD_SHA> clean daniel-ospina/tortoise --evidence comment:<ID>`
4. MERGE it: `scripts/admin-merge.sh {n}`

⛔ Recording a review is NOT merging. Stopping between step 3 and 4 is what left PRs sitting for
   35-90 minutes today. **The merge is part of this job, not a separate one.**
⛔ NEVER edit a PR's description after recording -- it WIPES the attestation.
⛔ Do NOT open a new PR. Do NOT start unrelated work.
⛔ If a check fails AFTER your fix: fix it again and continue. **Fixing is the normal path, not a blocker.**
⛔ `ai-review-gate=failure` is EXPECTED on a fresh PR and clears only by recording.
   `BLOCKED` / `UNSTABLE` merge states on a ready PR are NORMAL and are not reasons to hold.
{push}""".format(n=n, push=push)

    if action == "ready":
        return """# MERGE #{n} — nothing else is needed

**#{n}** {title}
Head `{head}`. All required checks are green and a `clean` attestation is already recorded at
this head. **Everything is done except the last step.**

```
scripts/admin-merge.sh {n}
```

⛔ **Do NOT re-record** -- re-attesting an unchanged head dilutes the evidence.
⛔ **Do NOT edit the PR description.**
Report: `merged`, or the rail's exact refusal text.
""".format(n=n, title=title, head=head[:12])

    if action == "no-checks":
        return """# #{n} — ITS CI NEVER RAN. Start it, then merge it.

**#{n}** {title}
Head `{head}`. **No required check has ever run at this head** -- these are absent, not failing
and not pending: {absent}

**A missing check is not a green check, and no amount of waiting will clear it.** So:
1. Re-trigger the required workflows for this head (workflow re-run / an empty commit if the
   workflows are path-filtered and are not firing).
2. Confirm the 7 required contexts appear: `pricing-artifact docs test-isolation
   license-surface legal-e2e python-ci-gate ai-review-gate`
3. Then run the loop below.
{common}""".format(n=n, title=title, head=head[:12], absent=", ".join(absent), common=common)

    if action == "failing":
        return """# FIX #{n}, THEN MERGE IT — fixing is a normal step, not a blocker

**#{n}** {title}
Head `{head}`. **Failing required check(s): {failing}**

**This PR is in progress, not blocked.** A failing check under branch protection is the ordinary
next step of merging. Do the work:

1. Read the ACTUAL failure (not the job name):
   `gh pr checks {n}` and `gh run view <runId> --log-failed`
2. Invoke the **`debug-workflow`** skill and root-cause it. **Do not guess at a fix.**
   **If the failure is a timeout that passes on retry at an unchanged commit, it is the
   load-dependent class (#5049) -- say so and retry rather than changing code that is not broken.**
3. Fix it, then get the change back onto the PR (see PUSHING / the fork note below) and let the
   checks re-run.
4. **Then carry straight on into the loop below -- do not report back and wait.**
{common}""".format(n=n, title=title, head=head[:12], failing=", ".join(failing), common=common)

    if action == "unreviewed":
        return """# REVIEW #{n}, THEN MERGE IT — one run

**#{n}** {title}
Head `{head}`. `ai-review-gate` is the only red and there is **no attestation at this head**.
**No code work is needed** -- this is a review away from being merged.
{common}""".format(n=n, title=title, head=head[:12], common=common)

    return ""


# ---------------------------------------------------------------------------
# 4. WHAT HAPPENED TO A WORKER — the harness's own artifacts, never a guess
# ---------------------------------------------------------------------------

def bg_path(name: str, suffix: str) -> str:
    return os.path.join(ORCH_DIR, "bg", "%s.%s" % (name, suffix))


def _orch_env() -> dict:
    """The environment the harness must run in. `O` is the harness's OWN root for `$O/bg`, so it
    is `ORCH_DIR` here: pr-doctor's `<name>.rc`/`.pid` reads and `nonblocking-dispatch.sh`'s
    writes can then never land in two different directories, which would make every status read
    report `lost` and hide every refusal."""
    return dict(os.environ, O=ORCH_DIR)


def read_rc(path: str):
    """The worker's exit status, or None when the file does not hold a COMPLETE verdict.

    A partial write is NOT a verdict (see `_RC_RE`): `7` may be the first byte of `75\n`.
    """
    try:
        with open(path) as fh:
            data = fh.read()
    except OSError:
        return None
    m = _RC_RE.match(data)
    return int(m.group(1)) if m else None


def gate_refused(name: str, code) -> bool:
    """True iff a 75/77 `.rc` was written by the GATE, not by a `pi` that exited 75 itself.

    Both codes share the 0-255 exit namespace with `pi`, so the code alone is ambiguous -- and the
    two meanings have OPPOSITE consequences here ("nothing consumed, do not record" vs "an agent
    ran, record it"). The discriminator is durable and already on disk: `spawn-gate.sh` appends
    `[load-gate] REFUSED` / `[disk-gate] REFUSED` to the worker log BEFORE run_agent returns, and
    the harness writes `.rc` only after that -- so at the instant the code is readable the marker
    is too. A `pi` that failed on its own writes no gate line.

    The READ is bounded to the first REFUSAL_LOG_WINDOW bytes: a refusal verdict is written at the
    head of a freshly truncated log, so a short read answers the question and a log big enough to
    exceed it is itself evidence that an agent ran.

    Every ambiguous input errs toward "an agent ran" -- i.e. toward KEEPING the cooldown. The
    opposite error (a real refusal read as a dispatch) is the one this method exists to prevent.
    """
    if code not in GATE_REFUSALS:
        return False
    try:
        with open(bg_path(name, "log"), "rb") as fh:
            data = fh.read(REFUSAL_LOG_WINDOW + 1)
    except OSError:
        return False
    if len(data) > REFUSAL_LOG_WINDOW:
        return False          # only an agent writes that much; the gate refuses in one line
    text = data.decode("utf-8", "replace")
    # ⛔ THE AGENT'S OWN OUTPUT IS NOT EVIDENCE. `pi` writes into the SAME log, so an agent that
    # QUOTES the marker (it is reading this repo) and then exits 75 itself must not be read as a
    # gate refusal -- that would release a cooldown and a class slot for work that really ran.
    # Presence of AGENT_RAN_MARKER settles it: the gate writes its verdict BEFORE starting an
    # agent, and that line is written only after `pi` has returned, so both cannot be true of one
    # run. Note the polarity is deliberately the COOLDOWN-KEEPING side: an ambiguity reads as
    # "an agent ran", never as "nothing consumed".
    if AGENT_RAN_MARKER in text:
        return False
    return any(m in text for m in REFUSAL_MARKERS)


def worker_status(name: str):
    """`running` | `done` | `failed` | `lost`, exactly as `nonblocking-dispatch.sh --status`
    reports it; None when the harness cannot answer."""
    out, _, rc = sh_err(["bash", NONBLOCKING_DISPATCH, "--status", name], timeout=60,
                        cwd=HOME, env=_orch_env())
    if rc != 0:
        return None
    line = (out or "").strip()
    head = name + " "
    if not line.startswith(head):
        return None
    return line[len(head):].split(" ", 1)[0] or None


def worker_live(name: str):
    """True if the worker is still running, False if it provably is not, None if unanswerable.

    The HARNESS owns this question (`--status` reads the `.rc` verdict first, then `kill -0` on
    the `.pid`), so it is asked rather than re-derived: a second reader over the same files can
    disagree with the writer, and the caller then spawns a second worker into the same directory.

    ⛔ THREE-VALUED, AND `None` MEANS DO NOT SPAWN. Both callers act on the value, so a two-valued
    reading here would turn "I could not tell" into "free slot" -- and `--status` cannot answer
    while `sh_err` is timing out or the harness copy is missing, which are exactly the conditions
    where a blind second spawn destroys a live worker's log/.rc/.pid.

    ⛔ `running` IS BOUNDED BY THE ARTIFACT'S OWN AGE. `--status` answers `running` from `kill -0`
    on a `.pid` file nothing prunes: a worker SIGKILLed before it wrote `.rc` leaves that file, and
    once the pid is RECYCLED by an unrelated process the status reads `running` for ever -- which
    would skip that PR with no cooldown and no STALE_DISPATCH_S escape. The harness already writes
    `$O/bg/<name>.started`, and a worker cannot outlive its own wall-clock cap.
    """
    st = worker_status(name)
    if st in ("done", "failed", "lost"):
        return False
    if st != "running":
        return None
    try:
        age = time.time() - os.path.getmtime(bg_path(name, "started"))
    except OSError:
        return True                      # nothing to bound it with: believe the pid
    if age > SPAWN_TIMEOUT_S + WORKER_STALE_SLACK_S:
        log("worker %s claims pid running but its start stamp is %.0f min old (cap=%ds + %ds) -- "
            "a recycled pid, treating it as gone"
            % (name, age / 60, SPAWN_TIMEOUT_S, WORKER_STALE_SLACK_S))
        return False
    return True


def void_refused_rows(st: dict) -> list[str]:
    """Drop state rows whose worker turned out to be a GATE REFUSAL; return their keys.

    A refusal consumed nothing, so it must not hold a cooldown and a budget slot for
    STALE_DISPATCH_S. dispatch() catches the refusal inside CONFIRM_WINDOW_S (measured 32-36 ms),
    and this is the DURABLE backstop for a box slow enough to outrun that window: the row was
    written by a caller that could not yet see the verdict, and a later pass reads the same
    artifact and undoes it.

    ⛔ ONLY `kind: spawn` ROWS ARE ELIGIBLE. A row recorded for a WORKTREE refusal represents an
    attempt that never spawned, so `$O/bg/<name>.rc` is by construction whatever an EARLIER
    attempt left behind -- and that earlier refusal would void this row on every pass, re-opening
    the "same line for ever" loop the record exists to close. Rows written before this field
    existed carry no `kind` and are treated as spawn rows (the backstop still applies to them).

    The gate marker (not the bare code) is what confirms the refusal -- see `gate_refused`, which
    also keeps this from dropping the row of a worker that RAN and exited 75 on its own.
    """
    voided = []
    for k in list(st):
        if k.startswith("_"):
            continue
        row = st.get(k) or {}
        if (row.get("kind") or "spawn") != "spawn":
            continue
        name = row.get("worker") or ""
        if not name:
            continue
        if gate_refused(name, read_rc(bg_path(name, "rc"))):
            del st[k]
            voided.append(k)
    return voided


# ---------------------------------------------------------------------------
# 5. DISPATCH — one worker, one PR, logged
# ---------------------------------------------------------------------------

def spawn_argv(name: str, worktree: str, brief_path: str) -> list[str]:
    """The ONE spawn command. A test asserts this is the background dispatcher, not cmux."""
    return ["bash", NONBLOCKING_DISPATCH, name, worktree, brief_path, str(SPAWN_TIMEOUT_S)]


def _confirm(name: str) -> tuple[str, str]:
    """('launched' | 'refused' | 'unconfirmed', detail) for a just-spawned worker -- BOUNDED.

    Two steps, in order of authority:

      1. poll `$O/bg/<name>.rc` for a COMPLETE code inside CONFIRM_WINDOW_S. A gate refusal lands
         there in ~35 ms (measured), so a refusal is caught without waiting for an agent that may
         run for 40 minutes;
      2. if nothing landed, ASK THE HARNESS (`--status`): a refusal written just after the window
         is still caught, a live pid is positive proof of a launch, and `lost` means the worker
         vanished without a verdict -- neither a launch nor a refusal, and never a row.

    A partial `.rc` is never a verdict (see `_RC_RE`): `7` may be the first byte of `75\n`.
    """
    rc_file = bg_path(name, "rc")
    deadline = time.monotonic() + CONFIRM_WINDOW_S
    while time.monotonic() < deadline:
        code = read_rc(rc_file)
        if code is not None:
            if gate_refused(name, code):
                return "refused", "gate REFUSED rc=%d" % code
            return "launched", "worker exited rc=%d" % code
        time.sleep(0.05)
    st = worker_status(name)
    code = read_rc(rc_file)
    if gate_refused(name, code):
        return "refused", "gate REFUSED rc=%d" % code
    if st == "running":
        return "launched", "launched, running"
    if code is not None:
        return "launched", "worker exited rc=%d" % code
    if st in ("done", "failed"):
        return "launched", "worker exited (%s)" % st
    if st == "lost":
        return "unconfirmed", "the worker recorded no exit status and no live pid"
    return "unconfirmed", "`--status` could not be read (the harness is missing or broken)"


def dispatch(pr: dict, action: str, text: str, dry: bool) -> tuple[bool, str, bool]:
    """Spawn a background worker for one PR. Returns (launched, detail, record).

    ⛔ THIS IS THE ONLY DISPATCH PATH. The lane-table path (`idle_lanes()` + a cmux send to a
    workspace) is GONE, not merely unused: a replacement that is added but not switched on is
    indistinguishable from no replacement, and it hides the old path's flaws. The new path does
    not need a pre-existing idle lane -- `nonblocking-dispatch.sh` starts a fresh worker in the
    PR's own worktree and returns immediately.

    `record` says whether the ATTEMPT belongs in the state file even though nothing was launched.
    Two of the three refusal classes differ in exactly that:

      * a GATE refusal (load 75 / disk 77) consumed nothing and CLEARS BY ITSELF -> not recorded;
        a row would burn a 45-min cooldown and a 90-min budget slot for work that never ran;
      * a WORKTREE refusal that is a verdict about the tree (uncommitted work, commits the PR
        head does not have, a file the next checkout would overwrite, a path we may not delete)
        does NOT clear by waiting -> recorded, so the PR reaches a cooldown instead of logging the
        same line on every pass for ever. A transient worktree failure (a failed fetch, a probe
        that timed out, `worktree add` losing a race) is NOT recorded: the next pass retries it.

    ⛔ THE THIRD CLASS IS NOT RECORDED, DELIBERATELY: a dispatcher failure (`rc != 0` -- rc=78
    "spawn-gate.sh not found", rc=2 "no worktree", rc=127 "dispatcher missing") is persistent but
    it is ONE shared cause, not a fact about one PR. Recording it would put every open PR under a
    45-min cooldown for a single broken install; the fix is the install, and the loud `FAIL` line
    naming the dispatcher's own stderr is what says so.
    """
    n = pr["number"]
    name = "prd-%d" % n
    if dry:
        # ⛔ A DRY RUN THAT SKIPS THE WORKTREE LIES ABOUT THE ONE STEP THAT BLOCKS. It used to
        # return here, so it reported "would spawn" precisely when the worktree was what would
        # refuse. Walk the SAME tree READ-ONLY: nothing is created, fetched, checked out or reset.
        wt, werr = materialise_worktree(pr, dry=True)
        if not wt:
            log("DRY-RUN %s would NOT spawn: %s" % (name, werr[:160]))
            return False, werr, False
        live = worker_live(name)
        if live is not False:
            log("DRY-RUN %s would NOT spawn: %s"
                % (name, "worker still running" if live else "worker liveness unreadable"))
            return (False, "worker %s is %s -- one worker per PR"
                    % (name, "still running" if live else "of unknown liveness"), False)
        log("DRY-RUN would spawn %s in %s for %s (%d bytes)"
            % (name, wt, pr["headRefName"], len(text)))
        return True, "dry-run", False
    # ⛔ ONE WORKER PER PR, EVEN ACROSS A HEAD CHANGE. main()'s cooldown is keyed on the head, so a
    # worker that PUSHES re-arms dispatch while it is still running -- and the worker name and its
    # worktree are both deterministic, so the second spawn lands ON TOP of the live one in the same
    # directory. Two agent processes then share one git index and one branch, and
    # `nonblocking-dispatch.sh` starts by `rm -f "$RC"`, `: > "$LOG"`, `echo … > "$PIDF"`, which
    # deterministically destroys the live worker's log, exit status and pid. So liveness is asked
    # (the harness owns the question), never inferred from the state row.
    live = worker_live(name)
    if live:
        return False, "worker %s is still running -- one worker per PR" % name, False
    if live is None:
        # ⛔ UNANSWERABLE IS NOT "FREE". Spawning on an unreadable status would re-create the exact
        # defect this guard exists for -- two workers in one deterministic directory, the second
        # destroying the first's log/.rc/.pid. It clears by itself as soon as `--status` answers.
        return (False, "worker liveness could not be read (`%s --status` failed) -- refusing to "
                       "spawn blind: a live worker would be destroyed" % NONBLOCKING_DISPATCH,
                False)
    path = os.path.join(STATE_DIR, "pr-doctor-brief-%s.txt" % name)
    os.makedirs(STATE_DIR, exist_ok=True)
    with open(path, "w") as f:
        f.write(text)
    wt, err = materialise_worktree(pr)
    if not wt:
        return False, err, bool(getattr(err, "persistent", False))
    # ⛔ THE GUARD IS CHECK-THEN-ACT, AND THE ACT IS MINUTES LATER. `materialise_worktree` can fetch
    # (300 s timeouts) and add a worktree; another pr-doctor invocation (a manual `--only`, which
    # the heartbeat lock does not cover) can pass the same guard inside that window. Re-asking here
    # costs one `--status` on the only path that spawns anything.
    again = worker_live(name)
    if again is not False:
        return (False, "worker %s appeared (or its liveness became unreadable) while the worktree "
                       "was being prepared -- refusing to spawn a second one" % name, False)
    # cwd is HOME for the same TCC reason the old cmux path used it: a cwd under ~/Documents is
    # protected and a launchd-spawned caller has no Full Disk Access. The dispatcher takes absolute
    # paths and does its own `cd "$WT"` internally.
    # ⛔ capture=False: this child exists to BACKGROUND a worker, and a captured call would wait for
    # that worker's entire life (SPAWN_CALL_TIMEOUT_S carries the measurement). The verdict comes
    # from `$O/bg` -- `_confirm` -- never from the pipe; stderr still comes back (a temp file), so
    # the dispatcher's own refusal text reaches the log.
    _, errout, rc = sh_err(spawn_argv(name, wt, path), timeout=SPAWN_CALL_TIMEOUT_S,
                           cwd=HOME, env=_orch_env(), capture=False)
    if rc != 0:
        # ⛔ carry the CODE and the dispatcher's OWN words. rc=78 (no/stale spawn-gate.sh), rc=2 (no
        # worktree / no brief) and rc=127 (dispatcher missing) are permanent, fleet-wide causes, and
        # the message is the only thing that names which one it is.
        detail = "rc=%s: %s" % (rc, (errout or "").strip()
                                or "the dispatcher exited non-zero with no stderr")
        log("spawn %s -> %s: FAIL %s" % (name, wt, detail[:200]))
        return False, detail, False
    verdict, detail = _confirm(name)
    if verdict == "refused":
        log("spawn %s: %s -- no agent started, nothing consumed" % (name, detail))
        return False, detail, False
    if verdict == "unconfirmed":
        # Nothing durable says either way. NOT recorded, and that is safe BECAUSE liveness is
        # checked before every spawn: if the worker did start, the next pass sees it running.
        log("spawn %s -> %s: UNCONFIRMED (%s) -- no state row; liveness is re-checked next pass"
            % (name, wt, detail))
        return False, detail, False
    log("spawn %s -> %s: %s" % (name, wt, detail))
    return True, detail, True


def load_state() -> dict:
    try:
        with open(STATE) as f:
            return json.load(f)
    except Exception:
        return {}


def save_state(st: dict) -> None:
    st["_updated"] = ts()
    try:
        os.makedirs(STATE_DIR, exist_ok=True)
        tmp = STATE + ".tmp"
        with open(tmp, "w") as f:
            json.dump(st, f, indent=1)
        os.replace(tmp, STATE)
    except Exception as e:
        log("state save failed: %s" % e)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--max", type=int, default=None,
                    help="hard ceiling on dispatches this pass; default is the machine's "
                         "MAX_FIX+MAX_REVIEW (see capacity())")
    ap.add_argument("--status", action="store_true")
    ap.add_argument("--only", type=int, default=0, help="limit to one PR number")
    args = ap.parse_args()

    st = load_state()
    if args.status:
        for k, v in sorted(st.items()):
            if k.startswith("_"):
                continue
            # `kind` is shown only when it is NOT "spawn", so a real dispatch prints exactly what
            # it always did -- and a row that exists because the PR was REFUSED can no longer be
            # read as "a worker was dispatched for this".
            kind = v.get("kind") or "spawn"
            print("%-8s %-11s worker=%-12s %s%s" % (k, v.get("action"),
                                                    (v.get("worker") or v.get("lane") or "?")[:12],
                                                    v.get("at"),
                                                    "" if kind == "spawn" else "  kind=" + kind))
        return 0

    # ⛔ A ROW LEFT BY A REFUSED SPAWN IS NOT A DISPATCH. dispatch() sees the refusal inside
    # CONFIRM_WINDOW_S (measured 32-36 ms), but a box slow enough to outrun that window leaves a
    # row behind for work that never started -- which would hold a 45-min cooldown and a 90-min
    # budget slot. Re-read the durable artifact and drop such rows (and PERSIST the drop BEFORE any
    # early return, so the log line does not claim a change that was never written).
    voided = void_refused_rows(st)
    for key in voided:
        log("#%s: the recorded dispatch was a GATE REFUSAL (no agent ran) -- row dropped; it "
            "consumed no cooldown and no budget slot" % key)
    if voided and not args.dry_run:
        save_state(st)

    prs = [p for p in open_prs() if not p.get("isDraft")]
    if args.only:
        prs = [p for p in prs if p["number"] == args.only]
    if not prs:
        log("no open non-draft PRs (or GitHub read failed)")
        return 0

    # classify everything first, then dispatch highest-value first
    classified = []
    for p in prs:
        try:
            classified.append((p, classify(p)))
        except Exception as e:
            log("#%s classify failed: %s" % (p["number"], e))

    ranked = {"ready": 0, "no-checks": 1, "unreviewed": 2, "failing": 3, "running": 9}
    classified.sort(key=lambda t: ranked.get(t[1], 8))

    # ⛔ THE CAP COMES FROM THE MACHINE, NOT FROM THIS SOURCE. `capacity()` reads MAX_FIX /
    # MAX_REVIEW from the environment or the orchestrator plist that `install.sh` renders (the
    # SAME block `orch-loop.sh` gets from launchd). `--max` is an optional extra ceiling.
    cap = capacity()
    budgets = pass_budgets(st, cap, args.max)

    counts: dict[str, int] = {}
    for _, a in classified:
        counts[a] = counts.get(a, 0) + 1
    log("pass: %d open PRs :: %s (capacity fix=%d review=%d, inflight=%d, budget fix=%d review=%d total=%d)" %
        (len(classified), " ".join("%s=%d" % kv for kv in sorted(counts.items())),
         cap["max_fix"], cap["max_review"], budgets["used"],
         budgets["fix"], budgets["review"], budgets["total"]))

    # ⛔ NO LANE-TABLE GATE. The old path read `lane-actions.py` and dispatched only to an idle
    # lane; with the fleet busy it printed "no idle lanes -- nothing dispatched this pass" and
    # gave up while classified work and budget sat unused. That path is RETIRED. A worker is
    # spawned for the PR instead, and `nonblocking-dispatch.sh` -> `run_agent()` applies the load
    # and disk gates at the moment of the spawn.
    if not budgets["total"]:
        log("no dispatch budget this pass (capacity fix=%d review=%d, inflight=%d)"
            % (cap["max_fix"], cap["max_review"], budgets["used"]))
        return 0

    dispatched = 0
    spent = {"fix": 0, "review": 0}
    for p, action in classified:
        if action == "running":
            continue
        if dispatched >= budgets["total"]:
            break
        cls = ACTION_CLASS.get(action, "fix")
        if spent[cls] >= budgets[cls]:
            continue
        key = str(p["number"])
        prev = st.get(key) or {}
        # GUARD: cooldown, and never re-dispatch while the last one may still be live
        if prev and now() - prev.get("at_epoch", 0) < COOLDOWN_S and prev.get("head") == p["headRefOid"]:
            continue
        # ⛔ A LIVE WORKER IS IN FLIGHT, NOT A FREE SLOT -- REGARDLESS OF HEAD MOVEMENT. The
        # cooldown above is keyed on the head, so a worker that pushes re-arms dispatch at T+2min
        # while it is still running; the worker name and the worktree are deterministic, so the
        # second spawn lands on top of the live one and destroys its log/.rc/.pid (see dispatch()).
        # This is checked even with NO state row, because a lost state file is not a dead worker.
        live = worker_live("prd-%s" % key)
        if live:
            log("#%s (%s): worker prd-%s is still running -- not spawning a second one"
                % (key, action, key))
            continue
        if live is None:
            # ⛔ UNANSWERABLE IS NOT "FREE" (see worker_live): skip, loudly. It clears as soon as
            # `--status` answers again, and it costs nothing, because a spawn would fail too.
            log("#%s (%s): worker prd-%s liveness could not be read -- skipping rather than "
                "spawning blind over a possibly live worker" % (key, action, key))
            continue
        text = brief(p, action)
        if not text:
            continue
        ok, detail, record = dispatch(p, action, text, args.dry_run)
        if not ok:
            if record and not args.dry_run:
                # RECORDED ANYWAY: a refusal that does not clear by waiting (uncommitted work in
                # the PR's own worktree, commits the head does not have) must reach a cooldown, or
                # the pass logs the same line for ever and the PR is never dispatched and never
                # visible in `--status`. NOTE the row consumes the class slot on the NEXT pass via
                # pass_budgets(), so it must not also be charged to this pass's `spent`.
                st[key] = {"action": action, "worker": "prd-%s" % key, "kind": "refused",
                           "head": p["headRefOid"], "at": ts(), "at_epoch": now()}
                log("#%s (%s): REFUSED and RECORDED -- this will not clear by waiting, so the row "
                    "holds a %d-min cooldown; fix the cause: %s"
                    % (key, action, COOLDOWN_S // 60, detail[:160]))
            else:
                log("#%s (%s): not dispatched -- retried on the next pass: %s"
                    % (key, action, detail[:160]))
            continue
        if not args.dry_run:
            st[key] = {"action": action, "worker": "prd-%s" % key, "kind": "spawn",
                       "head": p["headRefOid"], "at": ts(), "at_epoch": now()}
        spent[cls] += 1
        dispatched += 1

    if not args.dry_run:
        save_state(st)
    log("dispatched %d this pass" % dispatched)
    return 0


if __name__ == "__main__":
    sys.exit(main())
