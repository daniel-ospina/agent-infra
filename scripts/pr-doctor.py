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
import json
import os
import plistlib
import re
import subprocess
import sys
import time
from datetime import datetime, timezone

HOME = os.path.expanduser("~")
STATE_DIR = os.path.join(HOME, ".pi", "agent", "state")
STATE = os.path.join(STATE_DIR, "pr-doctor.json")
LOG = os.path.join(STATE_DIR, "pr-doctor.log")
REVIEWS = os.path.join(HOME, ".pi", "agent", "reviews")
SCRIPTS = os.path.join(HOME, ".pi", "agent", "scripts")

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

# A dispatch draws on the budget of the work it starts. `failing` needs code/CI repair (MAX_FIX);
# `no-checks` re-triggers the workflows and then runs the review+merge chain, so it is fix work;
# `unreviewed` is review work (MAX_REVIEW); `ready` is the terminal merge of an already-reviewed
# PR, so it rides the review chain. `running` never dispatches.
ACTION_CLASS = {"failing": "fix", "no-checks": "fix", "unreviewed": "review", "ready": "review"}

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
    for p, action in classified:
        if action in ("running",):
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
        if not lanes:
            break
        lane = lanes.pop(0)
        text = brief(p, action)
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
