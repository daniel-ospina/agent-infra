#!/usr/bin/env python3
"""pr-doctor — drive every open PR toward `merged`, automatically.

WHY THIS EXISTS (2026-10-10). The objective is `BE ABLE TO MERGE` and `waiting` went 10 -> 25
in one day while the fleet worked hard the whole time. The work was never missing: the LAST
MILE had no automation. A failing check was reported as a "blocker" instead of being repaired,
so every CI failure -- which is a NORMAL step of merging -- became a line in a report.

    "whenever our tests discover something that needs fixing before running CI again, you label
     it as blocked instead of doing the work that is needed and continuing with the merge
     process (having to fix things is a natural part of the CI process)" -- owner, 2026-10-10

So this closes the loop. Each pass, for every open non-draft PR, it asks `objective.py` -- the
fleet's ONE classifier -- what the PR needs, and DISPATCHES that work:

    call-rail        all required checks green + clean attestation at the current head, and the
                     rail itself would take it -> dispatch: call the rail
    blocked-by-rail  ...the same, but a gate `admin-merge.sh` enforces is refusing it
                     (`flip-gate`/`drift-guard`/`provenance`) -> dispatch: repair that gate
    rerun-checks     a required check never ran at this head (absence is not green)
                     -> dispatch: re-trigger the workflows
    resolve-conflict GitHub says DIRTY -> dispatch: rebase on main, then record + rail
    record-review    everything green, no clean attestation at this head
                     -> dispatch: review, record, rail -- in ONE run
    fix-ci           a required check is RED -> dispatch: FIX it, then re-review, then rail
    running          the head is still EXECUTING -> skip (next pass). NOT only "a required
                     check is in flight": a required gate that has NOT YET REPORTED counts when
                     ANY check at the head is in flight (`python-ci-gate` is created only after
                     its matrix children run), and a RED required check is never `running` --
                     it is work. Reading this row as "only a mid-run required check" is how a
                     correct `running` gets "fixed" back into `fix-ci`.
    (None)           the checks could not be READ -> skip, and say so: a miss is never work

⛔ THOSE CLASSES ARE NOT THIS FILE'S. They are `objective.classify_one()`'s (#1872), the same
function that produces the beat's per-class counts. This file used to carry a SECOND predicate
under its own vocabulary (ready / failing / unreviewed / no-checks / running), sharing no code
with the monitor: MEASURED on the live fleet 2026-10-16, the two DISAGREED on 4 of 11 open
non-draft PRs (36%), and on 5 of 12 in a later pass (41%) -- one beat said `fix-ci` (go repair
the code) while the chain said `running` (wait) or `unreviewed` (review it) about the SAME PR.
Two readers of one queue cannot be allowed to disagree about what to do with it,
so the classifier lives in ONE place and both consumers call it. The reasons a class was chosen
come from it too, so a brief renders the same evidence the beat counted.

THE FIVE HARD RULES (each one earned the hard way today):
  1. THE FIX AND THE RAIL CALL GO IN THE SAME BRIEF. The gap between "review recorded" and
     "rail called" cost #7906 35 min, #7922 25, #7904 90+, and produced 2 attestations in 2
     hours while 25 PRs waited. A brief that stops at "record" is a bug.
  2. NEVER DOUBLE-DISPATCH. One lane per PR; a cooldown; and a PR already in flight is skipped.
     Two lanes fixing one PR is worse than one lane being slow.
  3. BOUNDED CONCURRENCY. The box cannot take unbounded lanes: its own CI fails under load
     (#5049, the load-dependent-timeout class). Cap it, and back off when the box is loaded.
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
import importlib.util
import json
import os
import plistlib
import re
import subprocess
import sys
import time
from datetime import datetime, timezone

HOME = os.path.expanduser("~")
HERE = os.path.dirname(os.path.realpath(__file__))
STATE_DIR = os.path.join(HOME, ".pi", "agent", "state")
STATE = os.path.join(STATE_DIR, "pr-doctor.json")
LOG = os.path.join(STATE_DIR, "pr-doctor.log")
SCRIPTS = os.path.join(HOME, ".pi", "agent", "scripts")

REPO = "daniel-ospina/tortoise"
REPO_DIR = os.path.join(HOME, "Documents", "GitHub", "tortoise")


# ⛔ USE THE REAL gh BINARY, NOT THE `gh` ON PATH. On this box `~/.pi/agent/shims/gh` is a
# SYMLINK into ~/Documents (agent-infra/scripts/gh-shim/gh). macOS TCC protects ~/Documents
# and a launchd agent has no Full Disk Access to it, so executing the shim fails with
# "Operation not permitted" (verified rc=126) -- the job ran twice doing NOTHING while
# printing a plausible "no open PRs" line. ~/bin/gh is a real Mach-O binary outside the
# protected tree. The shim is the admin-merge GUARD (#984); this job only READS, so it does
# not need the guard. Landing still goes through the rail, in a lane.
GH = os.path.join(HOME, "bin", "gh")

# ⛔ THE CLASSIFIER IS NOT OURS TO OWN (#1872). `objective.py` owns the class vocabulary, the
# check-run read, the attestation read and the predicate; this file owns the DISPATCH. Loading
# it from beside this file (rather than copying a predicate, or importing a second copy of the
# required-context set) is what makes the beat's counts and this job's plan the same answer to
# the same question.
def _objective():
    spec = importlib.util.spec_from_file_location(
        "pr_doctor_objective", os.path.join(HERE, "objective.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)          # the `__main__` guard keeps this side-effect free
    return mod


CLASSIFIER = _objective()

# ⛔ THE SEAM IS ASSERTED, NOT ASSUMED (#1872). This file and `objective.py` are farmed into
# `~/.pi/agent/scripts/` as TWO INDIVIDUAL files (`pi-bootstrap/setup.sh` `fleet_srcs`), and that
# farm SKIPS a source that is missing (`[ -f "$f" ] || continue`) -- so a newer pr-doctor.py can
# sit beside an older objective.py. Without this check the import still succeeds, every PR then
# fails INSIDE the per-PR swallow below, and the pass ends `dispatched 0` with exit 0 -- a dead
# drain that reports success, which is the worst outcome this file can produce.
_SEAM = ("classify_one", "touches_surface", "CLASS_ORDER", "REQUIRED", "RAIL_GATES")
_missing = [n for n in _SEAM if not hasattr(CLASSIFIER, n)]
if _missing:
    raise SystemExit(
        "pr-doctor: %s is missing %s -- it is an older copy than this driver expects. "
        "Refusing to run rather than report an empty dispatch as success."
        % (getattr(CLASSIFIER, "__file__", "objective.py"), ", ".join(_missing)))

# Guards
COOLDOWN_S = 45 * 60          # do not re-dispatch the same PR inside this window
STALE_DISPATCH_S = 90 * 60    # a dispatch with no state change this old is retryable
MAX_LANE_ATTEMPTS = 3     # a refused dispatch tries the next idle lane, bounded

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

# A dispatch draws on the budget of the work it starts. `fix-ci` needs code/CI repair (MAX_FIX);
# `rerun-checks` re-triggers the workflows and then runs the review+merge chain, so it is fix
# work; `resolve-conflict` and `blocked-by-rail` are repairs (MAX_FIX); `record-review` is review
# work (MAX_REVIEW); `call-rail` is the terminal merge of an already-reviewed PR, so it rides the
# review chain. `running` never dispatches.
ACTION_CLASS = {"fix-ci": "fix", "rerun-checks": "fix", "resolve-conflict": "fix",
                "blocked-by-rail": "fix", "record-review": "review", "call-rail": "review",
                # ⛔ THE PRE-#1872 VOCABULARY, KEPT FOR THE STATE FILE ONLY. `~/.pi/agent/state/
                # pr-doctor.json` still holds rows written by the old classifier; the pass below
                # reads them for `STALE_DISPATCH_S` (90 min) after deploy. Without these keys an
                # unknown class falls back to "fix", so a live review dispatch would silently
                # over-charge the fix budget and under-charge the review one.
                "failing": "fix", "no-checks": "fix",
                "ready": "review", "unreviewed": "review"}

# ⛔ `tools/cmux_dispatch.py` REQUIRES PYTHON >= 3.12 and REFUSES to run under the system
# `python3` (3.9.6 on this box) -- it exits 0 with a one-line complaint, so a caller that only
# checks the exit code sees "success" while nothing was sent. Always use the repo venv.
VENV_PY = os.path.join(REPO_DIR, ".venv", "bin", "python")


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

# Why the last PR-list read failed, or None. Module-level because `[]` is ALSO the
# legitimate answer for an empty queue -- the old `if not prs` could not tell the two apart.
OPEN_PRS_ERROR = None


def open_prs() -> list[dict]:
    """The open-PR list, and WHY it failed -- kept out of band, never folded into "[]".

    ⛔ A FAILED READ MUST NEVER BE REPORTED AS "no open PRs". That is how this job ran twice
    under launchd doing NOTHING while printing a plausible, reassuring line -- the same silent-
    failure class this whole file exists to remove. It is also why the failure is a MODULE
    GLOBAL rather than `if not prs`: an empty list is the legitimate answer for an empty queue,
    and the old test could not tell the two apart (it logged GITHUB READ FAILED on a healthy
    repo with nothing open, and exited 0 on a genuine read failure).
    """
    global OPEN_PRS_ERROR
    OPEN_PRS_ERROR = None
    out, err, rc = sh_err([GH, "pr", "list", "--repo", REPO, "--state", "open", "--limit", "60",
                           "--json", "number,title,isDraft,mergeStateStatus,headRefOid,headRefName,files"])
    parsed = True
    try:
        prs = json.loads(out or "[]")
    except Exception:
        prs, parsed = [], False
    if rc != 0 or not parsed:
        OPEN_PRS_ERROR = "rc=%s %s" % (rc, (err or "").strip()[:200] or "(no stderr)")
        log("GITHUB READ FAILED (%s) | PATH=%s"
            % (OPEN_PRS_ERROR, os.environ.get("PATH", "")[:120]))
    return prs


# ⛔ THERE IS NO SECOND CLASSIFIER HERE (#1872). This file used to read each PR's checks a
# second way -- `gh pr view --json statusCheckRollup` -- and judge them with its own predicate
# under its own vocabulary (ready / failing / unreviewed / no-checks / running). Two problems,
# one root: a second reader of the same evidence.
#
#   * `objective.per_pr_checks()` reads the REST check-run surface with `filter=all` and groups
#     by (app, workflow, job), newest attempt by `id` -- and its own docstring records why the
#     GraphQL rollup is NOT trusted for this (#8009: an ABSENT gate read as a FAILING one,
#     because the rollup had not returned the green attempt that existed).
#   * the two predicates diverged on live data: 4 of 11 non-draft PRs got a different answer
#     here than from the beat (measured 2026-10-16).
#
# So the read AND the predicate both live in `objective.py`, behind `classify_one()`, and the
# fleet has exactly one of each.

def evaluate(pr: dict) -> tuple:
    """(class, why, cr) for ONE PR -- `objective.classify_one()`, never a copy (#1872).

    `class` is one of objective's CLASS_ORDER, or None when the checks could not be read. `why`
    names what the class is about (the refusing rail gate, the red required checks); `cr` is the
    evidence it was decided on, so a brief never has to read the world a second time.
    """
    return CLASSIFIER.classify_one(pr)


# The dispatcher's old name for the same question. Kept as the seam the suite and `main()` use,
# so a future reader cannot reintroduce a second predicate under a different name without this
# call site changing with it.
classify = evaluate


# ---------------------------------------------------------------------------
# 2. PICK A LANE — idle only, never a lane already holding a PR
# ---------------------------------------------------------------------------

def idle_lanes() -> tuple[list[dict], str]:
    """Returns (lanes, status). `status` is "" on a good read, else WHY it failed.

    ⛔ A FAILED READ MUST NEVER LOOK LIKE "NO IDLE LANES". Both print as zero lanes, but one
    means "the fleet is busy" and the other means "I could not see the fleet" -- and the
    second one, unseen, silently turns this whole job into a no-op that reports success.
    That is exactly how it behaved on its first live launchd pass (verified):
        EXEC FAILED ... lane-actions.py --json timed out after 240 seconds
        no idle lanes -- nothing dispatched this pass
    """
    # 240s is too tight for a box under load: `lane-actions.py` makes many gh calls over 26
    # lanes, and it was measured timing out at runq=64/cpu=88%. Under load every external
    # read is slower, so the bound scales -- this must not be the thing that stops the drain.
    out, err, rc = sh_err([sys.executable or "python3",
                           os.path.join(SCRIPTS, "lane-actions.py"), "--json"], timeout=600)
    if not (out or "").strip():
        return [], "lane-actions read failed rc=%s: %s" % (rc, (err or "").strip()[:160] or "no output")
    try:
        d = json.loads(out)
    except Exception as e:
        return [], "lane-actions output unparseable: %s" % e
    lanes = []
    for c in d.get("idle") or []:
        ws = c.get("ws")
        if not ws or c.get("protected"):
            continue
        lanes.append({"lane": c.get("lane"), "ws": ws, "verdict": c.get("verdict")})
    return lanes, ""


# ---------------------------------------------------------------------------
# 3. THE BRIEF — fix -> review -> record -> rail, ONE RUN, no gap
# ---------------------------------------------------------------------------

def brief(pr: dict, action: str, why: str | None = None, cr=None) -> str:
    """The order text for ONE PR. `action`/`why`/`cr` come from `evaluate()` -- the SAME
    classification and the SAME evidence the beat counts (#1872), so a brief cannot describe a
    PR differently from the line the fleet read."""
    n = pr["number"]
    head = pr["headRefOid"]
    title = pr["title"][:80]
    req = list(CLASSIFIER.REQUIRED)
    seen = {c.get("name") for c in (cr or []) if c.get("name")}
    absent = [c for c in req if c not in seen]

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

    if action == "call-rail":
        return """# MERGE #{n} — nothing else is needed

**#{n}** {title}
Head `{head}`. All required checks are green and a `clean` attestation is already recorded at
this head, and the rail's own gates would take it. **Everything is done except the last step.**

```
scripts/admin-merge.sh {n}
```

⛔ **Do NOT re-record** -- re-attesting an unchanged head dilutes the evidence.
⛔ **Do NOT edit the PR description.**
Report: `merged`, or the rail's exact refusal text.
""".format(n=n, title=title, head=head[:12])

    if action == "blocked-by-rail":
        return """# #{n} — THE RAIL REFUSES IT ON `{why}`. REPAIR THAT, THEN MERGE.

**#{n}** {title}
Head `{head}`. Every required check this predicate waits on is green and a `clean` attestation
is recorded at this head — so this is **not "not ready"**: it is a NAMED defect in a gate
`scripts/admin-merge.sh` enforces (`{why}`).

1. Read the failing `{why}` gate on this head (its own check-run / attestation log).
2. Repair the CAUSE — do not re-record your way past it; a re-recorded head does not open a
   gate that is judging the tree.
3. Then run the loop below.
{common}""".format(n=n, title=title, head=head[:12], why=why or "?", common=common)

    if action == "rerun-checks":
        return """# #{n} — REQUIRED CHECK(S) NEVER RAN. Start them, then merge it.

**#{n}** {title}
Head `{head}`. **These required checks never ran at this head** -- absent, not failing and not
pending: {absent}
(Nothing is in flight, so this is not a wait: the job that was never created has to be STARTED.)

**A missing check is not a green check, and no amount of waiting will clear it.** So:
1. Re-trigger the required workflows for this head (workflow re-run / an empty commit if the
   workflows are path-filtered and are not firing).
2. Confirm the 7 required contexts appear: `pricing-artifact docs test-isolation
   license-surface legal-e2e python-ci-gate ai-review-gate`
3. Then run the loop below.
{common}""".format(n=n, title=title, head=head[:12], absent=", ".join(absent), common=common)

    if action == "resolve-conflict":
        return """# #{n} — CONFLICTED WITH MAIN. Rebase, then merge it.

**#{n}** {title}
Head `{head}`. GitHub reports this PR **DIRTY** (a real conflict, not a failing gate).
**A rebase CHANGES THE HEAD, so any attestation recorded before it is worth nothing -- record
again at the new head.**

1. Rebase on `origin/main` and resolve the conflict properly (never force a resolution you did
   not verify).
2. Then run the loop below — review, record at the NEW head, rail.
{common}""".format(n=n, title=title, head=head[:12], common=common)

    if action == "record-review":
        return """# REVIEW #{n}, THEN MERGE IT — one run

**#{n}** {title}
Head `{head}`. Every required check this predicate waits on is green and there is **no
attestation at this head**. `ai-review-gate` itself is not the blocker and must not be argued
with: it is DIFF-BOUND and clears only when a clean review is RECORDED.
**No code work is needed** -- this is a review away from being merged.
{common}""".format(n=n, title=title, head=head[:12], common=common)

    if action == "fix-ci":
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
{common}""".format(n=n, title=title, head=head[:12], failing=why or "?", common=common)

    return ""


# ---------------------------------------------------------------------------
# 4. DISPATCH — one lane, one PR, logged
# ---------------------------------------------------------------------------

def dispatcher_py() -> str:
    """The interpreter that can actually run tools/cmux_dispatch.py (needs >= 3.12)."""
    if os.path.exists(VENV_PY):
        return VENV_PY
    return "uv"   # fallback: `uv run` resolves the project interpreter from pyproject


def dispatch(lane_ws: str, label: str, text: str, dry: bool) -> bool:
    if dry:
        log("DRY-RUN would dispatch %s -> %s (%d bytes)" % (label, lane_ws[:8], len(text)))
        return True
    path = os.path.join(STATE_DIR, "pr-doctor-brief-%s.txt" % label)
    os.makedirs(STATE_DIR, exist_ok=True)
    with open(path, "w") as f:
        f.write(text)
    py = dispatcher_py()
    # ⛔ ABSOLUTE, because cwd is HOME (see below). A relative "tools/..." resolves to
    # ~/tools/... and yields an empty result -- which is exactly the "FAIL (no output)"
    # this job logged on its first live dispatch.
    argv = ([py] if py != "uv" else ["uv", "run", "python"]) + [
        os.path.join(REPO_DIR, "tools", "cmux_dispatch.py"),
        "send", "--workspace", lane_ws, "--label", label, "--file", path]
    # ⛔ NOT cwd=REPO_DIR. A cwd under ~/Documents is TCC-protected and a launchd agent has no
    # Full Disk Access, so getcwd fails and the whole call dies with "Operation not permitted"
    # (verified rc=126). The dispatcher is invoked by absolute path and needs no repo cwd.
    out = sh(argv, timeout=420, cwd=HOME)
    # ⛔ "DELIVERED VIA THE DURABLE INBOX" IS **NOT** A DELIVERY TO THE LANE.
    #
    # I got this wrong once: the dispatcher's own documentation says the inbox is *the
    # ORCHESTRATOR inbox* -- it is where the notice is parked so the ORCHESTRATOR can retry it,
    # and `channel: none` means "not recorded anywhere". Nothing consumes it: only a compaction
    # watchdog even references the file, and nothing drains it. Scoring it as success makes this
    # job silently drop orders while reporting progress -- the exact failure class it exists to
    # remove. So: inbox => RETRY (not success), and say so.
    low = out.lower()
    ok = out.strip().startswith(("OK", "QUEUED"))
    if not ok and "durable inbox" in low:
        log("dispatch %s -> %s: NOT DELIVERED (parked in the orchestrator inbox for retry) "
            "-- the lane did NOT get it" % (label, lane_ws[:8]))
        return False
    log("dispatch %s -> %s: %s" % (label, lane_ws[:8],
                                    "OK" if ok else "FAIL (%s)" % (out.strip()[:110] or "no output")))
    return ok


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
            print("%-8s %-11s lane=%-10s %s" % (k, v.get("action"), (v.get("lane") or "?")[:10],
                                                v.get("at")))
        return 0

    prs = open_prs()
    # ⛔ AN UNREADABLE QUEUE IS NOT AN EMPTY ONE, AND THE TWO MUST NOT SHARE AN EXIT CODE. A
    # blind read that returns 0 is indistinguishable to the launcher from a clean pass -- the
    # exact shape the classifier half is now fail-closed against, so the queue half cannot be
    # allowed to stay fail-open.
    if OPEN_PRS_ERROR:
        log("REFUSING: the open-PR read FAILED (%s) -- nothing dispatched" % OPEN_PRS_ERROR[:160])
        return 2
    prs = [p for p in prs if not p.get("isDraft")]
    if args.only:
        prs = [p for p in prs if p["number"] == args.only]
    if not prs:
        log("no open non-draft PRs")
        return 0

    # classify everything first, then dispatch highest-value first
    classified = []
    skipped = {}
    for p in prs:
        try:
            k, why, cr = classify(p)
        except Exception as e:
            log("#%s classify failed: %s" % (p["number"], e))
            continue
        # ⛔ A MISS IS NEVER WORK. `None` means the checks could not be READ; rendering that as
        # any action (especially `fix-ci`) manufactures a queue out of a blind read.
        if k is None:
            skipped["unreadable"] = skipped.get("unreadable", 0) + 1
            continue
        # A required check is still IN FLIGHT: nothing to do this pass. It is a class, not a gap
        # (#1872) -- and `objective.py`'s arm is deliberately BROADER than the old predicate here:
        # it also covers a required gate that has NOT YET REPORTED (`python-ci-gate` is absent
        # while its matrix children run) and it yields to a RED required check, which IS work.
        if k == "running":
            skipped["running"] = skipped.get("running", 0) + 1
            continue
        # ⛔ THE ONLY HUMAN GATE. A diff that touches the SDK/MCP surface may not be landed by an
        # automatic chain: the surface is a contract, and changing it needs the owner's approval
        # first. `objective.py` already computes this overlay for the beat's `ASK-USER:` count;
        # the dispatcher reads the SAME predicate instead of carrying its own file list.
        if CLASSIFIER.touches_surface(p):
            log("ASK-USER #%s (%s) -- the diff touches the SDK/MCP surface; a human decides"
                % (p["number"], k))
            skipped["surface"] = skipped.get("surface", 0) + 1
            continue
        classified.append((p, k, why, cr))

    # ⛔ A BLIND CHECK-RUN READ MUST SAY WHY (#1872, reviewer E). `objective` records the last
    # `gh` failure in `GH_LAST_ERROR`; a pass that skipped PRs as unreadable and printed only
    # "dispatched 0" left the operator with a bare number and no cause -- the reassuring-line
    # failure mode this file's `GH` constant was written against.
    if skipped.get("unreadable"):
        log("%d PR(s) had UNREADABLE checks -- the cause: %s"
            % (skipped["unreadable"],
               (getattr(CLASSIFIER, "GH_LAST_ERROR", "") or "(no gh error recorded)").strip()[:240]))

    # Cheapest-and-highest-payoff FIRST: a landable PR costs one rail call, a repair costs lane-
    # hours. ⛔ THIS IS THIS FILE'S OWN POLICY, NOT `objective.CLASS_ORDER` -- the two differ
    # deliberately: CLASS_ORDER puts `blocked-by-rail` SECOND (the beat reports it as the cheapest
    # landing) and `resolve-conflict` ABOVE `record-review` (a rebase stales an attestation),
    # while dispatch ranks review work above both, because review and rail are what this pass can
    # actually spend a budget on. Writing "the same order" here was wrong in a way that would
    # send a reader tuning the wrong list. `running` is absent by construction (skipped above).
    ranked = {"call-rail": 0, "rerun-checks": 1, "record-review": 2,
              "resolve-conflict": 3, "blocked-by-rail": 4, "fix-ci": 5}
    classified.sort(key=lambda t: (ranked.get(t[1], 8), t[0]["number"]))

    # ⛔ THE CAP COMES FROM THE MACHINE, NOT FROM THIS SOURCE. `capacity()` reads MAX_FIX /
    # MAX_REVIEW from the environment or the orchestrator plist that `install.sh` renders (the
    # SAME block `orch-loop.sh` gets from launchd). `--max` is an optional extra ceiling.
    cap = capacity()
    budgets = pass_budgets(st, cap, args.max)

    counts: dict[str, int] = {}
    for _, a, _w, _cr in classified:
        counts[a] = counts.get(a, 0) + 1
    for a, c in skipped.items():
        counts["skipped-" + a] = c
    log("pass: %d open PRs :: %s (capacity fix=%d review=%d, inflight=%d, budget fix=%d review=%d total=%d)" %
        (len(prs), " ".join("%s=%d" % kv for kv in sorted(counts.items())),
         cap["max_fix"], cap["max_review"], budgets["used"],
         budgets["fix"], budgets["review"], budgets["total"]))

    lanes, lane_err = idle_lanes()
    if lane_err:
        # NOT the same as "no idle lanes". Say which one it is.
        log("LANE READ FAILED -- cannot dispatch this pass: %s" % lane_err)
        return 0
    if budgets["total"] and not lanes:
        log("no idle lanes -- nothing dispatched this pass")
        return 0

    dispatched = 0
    spent = {"fix": 0, "review": 0}
    for p, action, why, cr in classified:
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
        if not lanes:
            break
        lane = lanes.pop(0)
        text = brief(p, action, why, cr)
        if not text:
            continue
        # ⛔ A REFUSAL IS NOT A DEAD END. The dispatcher refuses for two reasons: a genuine
        # dead/shell pane (respect it -- the bytes would be EXECUTED), and the KNOWN FALSE
        # POSITIVE where an extension banner scrolls the footer out of the read window (#7941).
        # A loop that drops the PR on the first refusal reproduces the exact behaviour this
        # script exists to remove. So: try the next idle lane, bounded, and give the lane back.
        sent = None
        attempts = [lane] + [l for l in lanes]
        for cand in attempts[:MAX_LANE_ATTEMPTS]:
            if dispatch(cand["ws"], "prd-%s" % key, text, args.dry_run):
                sent = cand
                break
            if cand in lanes:
                lanes.remove(cand)
        if sent is None:
            log("#%s (%s): no lane accepted the order in %d attempts -- leaving for next pass"
                % (key, action, min(len(attempts), MAX_LANE_ATTEMPTS)))
            continue
        lanes = [l for l in lanes if l["ws"] != sent["ws"]]   # keep it free for the next PR
        if not args.dry_run:
            st[key] = {"action": action, "lane": sent["lane"], "ws": sent["ws"],
                       "head": p["headRefOid"], "at": ts(), "at_epoch": now()}
        spent[cls] += 1
        dispatched += 1

    if not args.dry_run:
        save_state(st)
    log("dispatched %d this pass" % dispatched)
    return 0


if __name__ == "__main__":
    sys.exit(main())
