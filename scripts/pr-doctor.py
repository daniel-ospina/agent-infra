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
# `nonblocking-dispatch.sh` backgrounds `run_agent()` and returns 0 the moment the worker is
# launched, so a GATE REFUSAL (AGENT_DISK_REFUSED=77 / AGENT_LOAD_REFUSED=75) only lands in
# `$O/bg/<name>.rc`. A refusal is written within milliseconds (the gate is the first thing
# run_agent does) and consumed nothing, so dispatch() gives it a brief window to land before
# recording a dispatch. A launched worker writes NO `.rc` until it exits, so a normal dispatch
# pays only the window and then proceeds.
REFUSAL_WINDOW_S = 1.0

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


def sh(args, timeout=180, cwd=None):
    try:
        r = subprocess.run(args, capture_output=True, text=True, timeout=timeout, cwd=cwd)
        return r.stdout
    except Exception as e:
        log("EXEC FAILED %s: %s" % (args[0], e))
        return ""


def sh_err(args, timeout=180, cwd=None):
    """Same, but returns (stdout, stderr, rc) -- so a failed read is REPORTED, never empty."""
    try:
        r = subprocess.run(args, capture_output=True, text=True, timeout=timeout, cwd=cwd)
        return r.stdout, r.stderr, r.returncode
    except Exception as e:
        return "", "%s: %s" % (type(e).__name__, e), -1


# ---------------------------------------------------------------------------
# 1. READ THE WORLD — from GitHub, never from a queue row
# ---------------------------------------------------------------------------

def open_prs() -> list[dict]:
    out, err, rc = sh_err([GH, "pr", "list", "--repo", REPO, "--state", "open", "--limit", "60",
                           "--json", "number,title,isDraft,mergeStateStatus,headRefOid,headRefName,files"])
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

def materialise_worktree(pr: dict) -> tuple[str, str]:
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
    """
    branch = pr["headRefName"]
    head = pr["headRefOid"]
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
            _drop_worktree_record(p)

    # Reuse any candidate that is already a live worktree. UNKNOWN is NOT reuse: `True` would run
    # `_ensure_head` -> `reset --hard` against whatever `git -C <path>` resolves to, which for a
    # non-worktree inside the main checkout is the MAIN repo (the very trap this PR fixes).
    for cand in candidates:
        live = _live_worktree(cand)
        if live is None:
            return "", ("cannot determine whether %s is a worktree (git probe failed) -- refusing "
                        "to reuse or delete it; inspect it" % cand)
        if live:
            err = _ensure_branch(cand, branch) or _ensure_head(cand, branch, head)
            return (cand, "") if not err else ("", err)

    # Materialise at the first candidate that is absent, or holds nothing but a dangling `.git`
    # pointer (disposable). A directory that might contain work is left alone for inspection.
    path = ""
    for cand in candidates:
        if not os.path.exists(cand):
            path = cand
            break
        if _disposable_dangling(cand):
            log("materialise: clearing a dangling non-worktree at %s" % cand)
            shutil.rmtree(cand, ignore_errors=True)
            path = cand
            break
    if not path:
        return "", ("%s and %s both exist but neither is a live worktree, and neither is "
                    "disposable -- refusing to delete either; inspect and clean"
                    % (candidates[0], candidates[1]))

    _, _, rc = sh_err(["git", "-C", REPO_DIR, "rev-parse", "--verify", "-q",
                       "refs/heads/%s" % branch], timeout=60)
    if rc == 0:
        argv = ["worktree", "add", path, branch]
    else:
        _, _, frc = _git(["fetch", "origin", branch, "--quiet"], timeout=300)
        if frc == 0:
            argv = ["worktree", "add", path, "-b", branch, "origin/%s" % branch]
        else:
            # A fork PR: its head is published in the BASE repo at refs/pull/<n>/head. Detached,
            # because there is no branch in origin to push to -- the worker can review and merge,
            # and a push is refused loudly rather than silently landing nowhere.
            ref = "refs/pull/%d/head" % pr["number"]
            _, ferr, frc = _git(["fetch", "origin", ref, "--quiet"], timeout=300)
            if frc != 0:
                return "", "cannot materialise %s: neither origin/%s nor %s could be fetched (%s)" % (
                    branch, branch, ref, (ferr or "").strip()[:160])
            argv = ["worktree", "add", "--detach", path, "FETCH_HEAD"]
    _, err, rc = _git(argv, timeout=300)
    if rc != 0:
        return "", "worktree add failed rc=%s: %s" % (rc, (err or "").strip()[:200] or "(no stderr)")
    if not _live_worktree(path):
        return "", "worktree add reported success but %s is not a live worktree" % path
    # A local branch can be BEHIND the PR head; verify and move it, but never over dirty work.
    err = _ensure_branch(path, branch) or _ensure_head(path, branch, head)
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
    destroy recoverable commits, so it is never disposable.
    """
    try:
        entries = os.listdir(path)
    except OSError:
        return False
    if not entries:
        return True
    if set(entries) != {".git"}:
        return False
    return os.path.isfile(os.path.join(path, ".git"))


def _ensure_branch(path: str, branch: str) -> str:
    """Ensure a reused worktree is attached to the PR branch (or DETACHED for a fork PR); "" on
    success, else why.

    The reuse path used to reset whatever HEAD it found, so a worktree left on another branch (or
    detached) was silently reused and the worker's `git push` landed on the wrong branch. When the
    PR branch exists locally the worktree must be attached to it; when it does NOT (a fork PR)
    the worktree must be DETACHED -- never left on a foreign local branch, whose pointer
    `_ensure_head` would otherwise move. A worktree with TRACKED modifications is refused
    (checkout could carry them); untracked scratch neither blocks checkout nor is destroyed by
    `reset --hard`, so it is left alone.
    """
    out, _, rc = sh_err(["git", "-C", path, "symbolic-ref", "--short", "HEAD"], timeout=30)
    cur = (out or "").strip()
    detached = rc != 0
    if not detached and cur == branch:
        return ""
    _, _, exists = _git(["rev-parse", "--verify", "-q", "refs/heads/%s" % branch], timeout=60)
    dirty, _, drc = sh_err(["git", "-C", path, "status", "--porcelain",
                            "--untracked-files=no"], timeout=60)
    if drc != 0:
        return ("cannot determine whether worktree %s is clean (git status rc=%s) -- refusing to "
                "switch branch; inspect and clean it" % (path, drc))
    if (dirty or "").strip():
        return ("worktree %s is on a different branch/HEAD and has uncommitted tracked changes -- "
                "refusing to switch it to %s; inspect and clean it" % (path, branch))
    if exists != 0:
        if detached:
            return ""                              # fork PR: already detached
        _, err, xrc = sh_err(["git", "-C", path, "checkout", "--detach"], timeout=180)
        if xrc != 0:
            return "worktree %s is on foreign branch %s and could not be detached: %s" % (
                path, cur, (err or "").strip()[:160])
        return ""
    _, err, xrc = sh_err(["git", "-C", path, "checkout", branch], timeout=180)
    if xrc != 0:
        return "worktree %s could not be switched to %s: %s" % (
            path, branch, (err or "").strip()[:160])
    return ""


def _untracked_clobber(path: str, head: str):
    """Untracked paths that a `reset --hard <head>` would overwrite/delete, or None if UNKNOWN.

    `reset --hard` leaves NON-colliding untracked files alone, but DELETES one that occupies a
    path the target tree tracks (verified). Guarding on tracked changes only would lose such a
    file; guarding on the full `status` (every scratch file) is a false block. This checks the
    exact set.
    """
    out, _, rc = sh_err(["git", "-C", path, "status", "--porcelain", "-z",
                         "--untracked-files=all"], timeout=60)
    if rc != 0:
        return None
    untracked = [f[3:] for f in (out or "").split("\0") if f.startswith("?? ")]
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


def _ensure_head(path: str, branch: str, head: str) -> str:
    """Move <path> to <head>; "" on success, else why. NEVER resets a DIRTY worktree."""
    out, _, rc = sh_err(["git", "-C", path, "rev-parse", "HEAD"], timeout=30)
    if rc == 0 and (out or "").strip() == head:
        return ""
    _, _, have = sh_err(["git", "-C", path, "cat-file", "-e", "%s^{commit}" % head], timeout=30)
    if have != 0:
        sh_err(["git", "-C", path, "fetch", "origin", branch, "--quiet"], timeout=300)
    # ⛔ An unanswerable cleanliness probe is NOT "clean": `dirty` is empty on rc != 0, so the
    # old `if dirty.strip()` fell through to `reset --hard` and destroyed uncommitted work.
    dirty, _, drc = sh_err(["git", "-C", path, "status", "--porcelain",
                            "--untracked-files=no"], timeout=60)
    if drc != 0:
        return ("cannot determine whether worktree %s is clean (git status rc=%s) -- refusing to "
                "reset it; inspect and clean it" % (path, drc))
    if (dirty or "").strip():
        return ("worktree %s is at a different head and has uncommitted tracked changes -- "
                "refusing to reset it; inspect and clean it" % path)
    clobber = _untracked_clobber(path, head)
    if clobber is None:
        return ("cannot determine whether resetting worktree %s would overwrite untracked files "
                "-- refusing; inspect it" % path)
    if clobber:
        return ("worktree %s has untracked file(s) that the PR head would overwrite (%s) -- "
                "refusing to reset it; move or remove them" % (path, ", ".join(clobber[:3])))
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
""".format(n=n)

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
3. Fix, push, and let the checks re-run.
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
# 4. DISPATCH — one worker, one PR, logged
# ---------------------------------------------------------------------------

def spawn_argv(name: str, worktree: str, brief_path: str) -> list[str]:
    """The ONE spawn command. A test asserts this is the background dispatcher, not cmux."""
    return ["bash", NONBLOCKING_DISPATCH, name, worktree, brief_path, str(SPAWN_TIMEOUT_S)]


def dispatch(pr: dict, action: str, text: str, dry: bool) -> tuple[bool, str]:
    """Spawn a background worker for one PR. Returns (launched, detail).

    ⛔ THIS IS THE ONLY DISPATCH PATH. The lane-table path (`idle_lanes()` + a cmux send to a
    workspace) is GONE, not merely unused: a replacement that is added but not switched on is
    indistinguishable from no replacement, and it hides the old path's flaws. The new path does
    not need a pre-existing idle lane -- `nonblocking-dispatch.sh` starts a fresh worker in the
    PR's own worktree and returns immediately.
    """
    n = pr["number"]
    name = "prd-%d" % n
    if dry:
        log("DRY-RUN would spawn %s in a fresh worktree for %s (%d bytes)"
            % (name, pr["headRefName"], len(text)))
        return True, "dry-run"
    path = os.path.join(STATE_DIR, "pr-doctor-brief-%s.txt" % name)
    os.makedirs(STATE_DIR, exist_ok=True)
    with open(path, "w") as f:
        f.write(text)
    wt, err = materialise_worktree(pr)
    if not wt:
        return False, err
    # cwd is HOME for the same TCC reason the old cmux path used it: a cwd under ~/Documents is
    # protected and a launchd-spawned caller has no Full Disk Access. The dispatcher takes absolute
    # paths and does its own `cd "$WT"` internally.
    out, errout, rc = sh_err(spawn_argv(name, wt, path), timeout=120, cwd=HOME)
    detail = (out or "").strip() or (errout or "").strip()
    if rc != 0:
        log("spawn %s -> %s: FAIL rc=%s (%s)" % (name, wt, rc, detail[:120] or "no output"))
        return False, detail
    # ⛔ A GATE REFUSAL IS NOT A DISPATCH. `nonblocking-dispatch.sh` backgrounds `run_agent()` and
    # returns 0 as soon as the worker is launched, so the refusal code (75/77) lands only in
    # `$O/bg/<name>.rc`. A refused spawn consumed NOTHING, so it must not be recorded: a state row
    # would burn a 45-min cooldown and a 90-min budget slot for work that never ran, and the pass
    # log would claim a dispatch that did not happen.
    rc_file = os.path.join(ORCH_DIR, "bg", "%s.rc" % name)
    deadline = time.monotonic() + REFUSAL_WINDOW_S
    while time.monotonic() < deadline:
        if os.path.exists(rc_file):
            try:
                with open(rc_file) as fh:
                    code = int(fh.read().strip())
            except Exception:
                # A PARTIAL write is not a verdict: keep polling rather than conclude success.
                time.sleep(0.05)
                continue
            if code in (75, 77):
                log("spawn %s: gate REFUSED rc=%s -- no agent started, nothing consumed" % (name, code))
                return False, "gate refused rc=%s" % code
            break
        time.sleep(0.05)
    log("spawn %s -> %s: %s" % (name, wt, detail[:120] or "launched"))
    return True, detail


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
            print("%-8s %-11s worker=%-12s %s" % (k, v.get("action"),
                                                  (v.get("worker") or v.get("lane") or "?")[:12],
                                                  v.get("at")))
        return 0

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
        text = brief(p, action)
        if not text:
            continue
        ok, detail = dispatch(p, action, text, args.dry_run)
        if not ok:
            log("#%s (%s): not spawned -- starts on the next pass if it was transient: %s"
                % (key, action, detail[:160]))
            continue
        if not args.dry_run:
            st[key] = {"action": action, "worker": "prd-%s" % key,
                       "head": p["headRefOid"], "at": ts(), "at_epoch": now()}
        spent[cls] += 1
        dispatched += 1

    if not args.dry_run:
        save_state(st)
    log("dispatched %d this pass" % dispatched)
    return 0


if __name__ == "__main__":
    sys.exit(main())
