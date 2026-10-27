#!/usr/bin/env python3
"""tools/fleet/pr_state.py — THE PR STATE ROUTER (agent-infra #2866).

ONE command. ONE row per open PR. ONE action per row, with a machine-readable reason.

    python3 tools/fleet/pr_state.py --repo owner/name                  # the table
    python3 tools/fleet/pr_state.py --repo owner/name --json           # the same rows
    python3 tools/fleet/pr_state.py --repo owner/name --only 1234      # one row (actor seam)
    python3 tools/fleet/pr_state.py --repo owner/name --suppress       # cancel queued CI on
    python3 tools/fleet/pr_state.py --repo owner/name --cancelled      # what was cancelled + re-trigger
    python3 tools/fleet/pr_state.py --repo owner/name --suppress --dry-run

WHY IT EXISTS (#2866, measured 2026-10-26 on daniel-ospina/tortoise)
--------------------------------------------------------------------
A 30-PR backlog was triaged BY HAND into ready / needs-review / conflicting / red. That
classification decides what the whole fleet does next, and it was a throwaway script:

    100 queued CI runs, ~19 of them on PRs that could not merge (unreviewed or conflicting);
    7 fully merge-ready PRs idle behind them; 5 runners online of 16 advertised.

Each actor already knows a slice — `admin-merge.sh` merges one PR safely, `pr-doctor.py` pushes a
fix, `refresh-candidates.sh` picks issues, `record-review.sh` binds an attestation to a sha,
`pr-sickness.sh` selects red PRs, `collision_preflight.py` says who holds an issue — and NONE of
them answers "what does this PR need next, and should anything be running for it right now". So
"do not spend CI on a head that cannot merge" has no home, and the fleet substitutes volume: run
everything, cancel later.

WHAT IT IS NOT
--------------
* It never merges. `LAND` means "the rail may run", never "merge unseen".
* It never calls `record-review.sh` to write a record (it calls `--print-diff-hash`, the READ-ONLY
  seam `record-review.sh` documents for exactly this comparison).
* It never cancels a RUNNING job. Suppression cancels only runs whose status is re-read as
  `queued` at the moment of the cancel; every cancelled id is recorded so re-trigger is mechanical.
* It is not a second landing path: `admin-merge.sh` is the only merge path and is untouched.

THE VERDICT IS BY POLARITY, ON THE NEWEST ATTEMPT PER GROUP (#2866 non-negotiable)
---------------------------------------------------------------------------------
Groups are `(app.slug, workflow, job name)`. The workflow is NOT in a check-run payload, so it is
resolved from `details_url` (`…/actions/runs/<run>/job/<job>`) through the head's run listing; a run
the listing cannot name becomes its OWN group (`?unknown:<run>`) — an unresolvable workflow must
never merge two workflows into one group. Newest attempt wins by check-run **id** (GitHub keeps every
attempt and a re-run ADDS a row, so one commit can carry the same job both `failure` and `success`):

    green      success | neutral | skipped
    non-red    cancelled | stale          ← ⛔ NOT failures. Most "red PRs" measured on 2026-10-26
                                            were cancelled runs; treating one as a failure spends a
                                            fixer and a fresh CI pass on a healthy head.
    in flight  queued | in_progress | waiting | requested | pending
    RED        everything else — including a conclusion GitHub has not documented and a null one

An EMPTY surface is `NOREAD`, never green: a missing check is not a passing one.

THE ONE ACTION PER ROW, IN PRECEDENCE ORDER
-------------------------------------------
    CLOSE-STALE          changed_files == 0 — the diff is gone; nothing to run, nothing to merge
    WAIT:draft           a draft PR cannot merge, so nothing it runs can make it mergeable
    REPAIR-CONFLICT      mergeable == CONFLICTING — no CI result can matter until the branch has main
    FIX-RED              a real red attributable to this tree — run the FAILING job, not the suite
    RERUN-FLAKE          the same group passed on an EARLIER attempt at this SAME head — `rerun --failed`
    WAIT:inherited-red   the same (app, workflow, job) is red at main's head — a fixer cannot fix it
    REVIEW               nothing at this head to approve (see FIDELITY)
    WAIT:attested-elsewhere  an attestation is on the PR body but not in this box's store
    WAIT:owes-review     the record is at another head and the reviewed DIFF changed
    WAIT:diff-unreadable the record is at another head and the live diff could not be READ (retry)
    WAIT:in-flight       no red, ≥1 group running — it becomes an answer on its own; do not touch it
    WAIT:no-check-surface  the surface could not be read or carries no groups — never "green"
    WAIT:mergeable-unknown  GitHub has not computed mergeability yet
    WAIT:authority-unreadable  branch protection unreadable, so "is review required" is unknown
    LAND                 attested at this head (or carried — below) + mergeable + no real red

FIDELITY: `attested_sha == head_sha`, AND THE CONTRADICTION TEST THAT RESHAPED IT
---------------------------------------------------------------------------------
The issue's literal rule is "LAND requires attested_sha == head_sha; a mismatch is a refusal".
Taken literally it CONTRADICTS A RECORDED DECISION: the review gate deliberately CARRIES a record
across a moved head when the reviewed diff is byte-identical (`extensions/review-enforcer/index.ts`
— the `carried` arm; `record-review.sh --check-carry`; issues #1351/#1690/#2982/#2349). A rule that
refused every moved head would false-block every legitimate carry and reopen that decision through
a side door, so this module implements the DECISION, not the literal wording:

    at-head        attested_sha == head_sha                          → LAND eligible
    carried        head moved, record.diff_sha256 == the live diff    → LAND eligible (as the gate does)
    owes-review    head moved, the diff differs (or has no digest)    → WAIT, the two shas printed
    diff-unreadable  the comparison could not be made                 → WAIT: RETRY, never re-review

`owes-review` is #10104 exactly: PR tortoise #10104 merged at `f66d56949` while its review was
written at `f46cc23ee`. Benign there (the diff carried), and the same row would have shown the
mismatch BEFORE anyone spent a merge attempt on it.

SUPPRESSION (the policy that actually saves the CI)
---------------------------------------------------
A row in `REVIEW`, `REPAIR-CONFLICT` or `FIX-RED` has a head that is ABOUT TO CHANGE, so its queued
runs are cancelled before they are spent: `--suppress` (dry-run by default off; `--dry-run` to
preview). Nothing in flight is ever cancelled (`status == queued` re-read per run, immediately before
the cancel — a stale reading must not cancel a job that has started). Every cancelled run is written
to an append-only JSONL ledger with repo, PR, head, run id, workflow and the action that justified it,
and `--cancelled` prints those rows WITH the re-trigger command for each. Re-trigger is otherwise
automatic: a push starts the new head's runs.

Exit codes: 0 the table was produced (whatever it decided); 2 the pass could not be made (the PR
listing, the queue, or the authority could not be read — an unreadable read is never "nothing to
do"). `--suppress` returns 2 when the cancel pass could not be completed.

Environment seams (all optional; tests drive them):
    PR_STATE_GH        the gh binary (default `gh`)
    PR_STATE_REVIEWS   the review store (default `~/.pi/agent/reviews`)
    PR_STATE_RECORD_SH record-review.sh, for `--print-diff-hash` (default: resolved beside this tree)
    PR_STATE_LEDGER    the suppression ledger (default `${O:-$HOME/orchestrator}/state/pr-state-suppressed.jsonl`)
    REVIEW_GATE        the review-gate check name (default `ai-review-gate`)
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor

# ── the ONE polarity (#2866). Nothing below may re-decide a conclusion. ───────────────────────
GREEN = frozenset({"success", "neutral", "skipped"})
NONRED = GREEN | {"cancelled", "stale"}
IN_FLIGHT = frozenset({"queued", "in_progress", "waiting", "requested", "pending"})

# The three actions whose head is about to change, so their queued CI is spent for nothing.
SUPPRESS_ACTIONS = frozenset({"REVIEW", "REPAIR-CONFLICT", "FIX-RED"})

FULL_SHA = re.compile(r"^[0-9a-f]{40}$")
HEX64 = re.compile(r"^[0-9a-f]{64}$")
DETAILS_RUN = re.compile(r"/actions/runs/(\d+)")
MARKER = re.compile(
    r"review recorded: reviews/(\d+)\.json verdict=(?P<verdict>[a-z][a-z-]*) @ "
    r"(?P<sha>[0-9a-f]{7,40})(?: diff=(?P<diff>[0-9a-f]{64}))?"
)

DEFAULT_REVIEW_GATE = "ai-review-gate"


def env(name: str) -> str:
    return (os.environ.get(name) or "").strip()


def gh_bin() -> str:
    return env("PR_STATE_GH") or "gh"


# ══════════════════════════════════════════════════════════════════════════════════════════════
# PURE CORE — every function here is a decision over evidence, and every one is mutation-pinned in
# pr_state.test.py. No network, no filesystem, no clock.
# ══════════════════════════════════════════════════════════════════════════════════════════════


def verdict(rows):
    """The check-run verdict: RED | WAIT | GREEN | NOREAD, plus the groups behind it.

    `rows` are dicts with app / workflow / job / status / conclusion / id / run. Grouping is
    (app, workflow, job) — a workflow that cannot be resolved keeps its own group via its run id —
    and the newest attempt per group wins by check-run id.
    """
    groups = {}
    for r in rows:
        run = str(r.get("run") or "")
        workflow = (r.get("workflow") or "").strip() or ("?unknown:%s" % run if run else "?unknown")
        key = ((r.get("app") or "").strip(), workflow, (r.get("job") or "").strip())
        try:
            cid = int(r.get("id") or 0)
        except (TypeError, ValueError):
            cid = 0
        g = groups.get(key)
        if g is None:
            groups[key] = {"key": key, "id": cid, "status": (r.get("status") or "").strip().lower(),
                           "conclusion": (r.get("conclusion") or "").strip().lower(),
                           "run": run, "attempts": 1,
                           "passing_attempt": (r.get("conclusion") or "").strip().lower() in GREEN,
                           "passing_status": (r.get("status") or "").strip().lower() in IN_FLIGHT}
        else:
            g["attempts"] += 1
            concl = (r.get("conclusion") or "").strip().lower()
            # ⛔ GREEN, NOT NONRED. `passing_attempt` is the evidence RERUN-FLAKE spends CI on, and
            # the claim it prints is "PASSED on an earlier attempt at this same head". A cancelled or
            # stale attempt is non-red for the VERDICT (it must never count as a failure) but it is
            # not a pass: a group whose only other attempt was cancelled has never been shown to
            # work, so re-running it is a guess dressed as evidence — and both consumers act on that
            # answer (the fixer declines the head, the lander exits 11 instead of spending a FIX).
            if concl in GREEN:
                g["passing_attempt"] = True
            if cid >= g["id"]:
                g.update({"id": cid, "status": (r.get("status") or "").strip().lower(),
                          "conclusion": concl, "run": run})

    if not groups:
        return {"verdict": "NOREAD", "groups": 0, "red": [], "in_flight": 0,
                "reason": "empty surface (no check groups) — a missing check is not green"}

    red, in_flight = [], 0
    for g in groups.values():
        if g["status"] in IN_FLIGHT:
            in_flight += 1
            continue
        if g["conclusion"] in NONRED:
            continue
        # ⛔ ANY OTHER CONCLUSION IS RED — including a null one and one GitHub has not documented.
        red.append({
            "group": "/".join(p for p in g["key"][1:] if p),
            "app": g["key"][0], "workflow": g["key"][1], "job": g["key"][2],
            "run": g["run"], "conclusion": g["conclusion"] or "null",
            "attempts": g["attempts"], "passing_attempt": g["passing_attempt"],
        })

    if red:
        return {"verdict": "RED", "groups": len(groups), "red": red, "in_flight": in_flight,
                "reason": "%d of %d groups red" % (len(red), len(groups))}
    if in_flight:
        return {"verdict": "WAIT", "groups": len(groups), "red": [], "in_flight": in_flight,
                "reason": "%d of %d groups in flight" % (in_flight, len(groups))}
    return {"verdict": "GREEN", "groups": len(groups), "red": [], "in_flight": 0,
            "reason": "%d groups, none red" % len(groups)}


def parse_markers(body):
    """Every attestation marker on a PR body, in body order.

    `record-review.sh` writes `review recorded: reviews/<pr>.json verdict=<v> @ <sha> diff=<hash>
    (<owner>/<repo>)`. Several may stand on one body (a record re-minted at a new head); the caller
    picks by head, and never invents one from a partial match.
    """
    out = []
    for m in MARKER.finditer(body or ""):
        out.append({"verdict": m.group("verdict"), "head_sha": m.group("sha").lower(),
                    "diff_sha256": (m.group("diff") or "").lower(), "source": "marker"})
    return out


def choose_marker(body, head):
    """The marker that speaks for THIS head, else the last one written. None when there is none."""
    marks = parse_markers(body)
    if not marks:
        return None
    for m in marks:
        if m["head_sha"] == (head or "").lower():
            return m
    return marks[-1]


def fidelity(record, head, diff_read):
    """`attested_sha == head_sha`, in the shape the review gate itself decides it.

    `diff_read` is called ONLY when the head moved and the record carries a digest; it returns
    `(True, hash)` or `(False, reason)`.
    """
    if not record or not record.get("head_sha"):
        return {"state": "absent", "detail": "no attestation record"}
    attested = (record.get("head_sha") or "").lower()
    live_head = (head or "").lower()
    if attested == live_head:
        return {"state": "at-head", "detail": "attested at this head"}
    # A PREFIX IS NOT AN IDENTITY, in either direction: a record written with a short sha does not
    # bind a full head (the gate compares exactly), so it can never make LAND eligible.
    if not FULL_SHA.match(attested):
        return {"state": "owes-review",
                "detail": "attested at %s (not a full sha, so it cannot bind) → head %s" % (attested, live_head)}
    digest = (record.get("diff_sha256") or "").lower()
    if not HEX64.match(digest):
        # ABSENCE IS NOT IDENTITY: a record with no usable digest falls through to a fresh review,
        # exactly as the gate's own `head_advanced` arm does. It is decided WITHOUT reading the live
        # diff — a comparison whose left side does not exist is not a comparison.
        return {"state": "owes-review",
                "detail": "attested at %s, head is %s, record carries no diff digest" % (attested[:12], live_head[:12])}
    ok, got = diff_read()
    if not ok:
        return {"state": "diff-unreadable",
                "detail": "attested at %s, head is %s, live diff unreadable: %s" % (attested[:12], live_head[:12], got)}
    if got == digest:
        return {"state": "carried",
                "detail": "attested at %s, head moved to %s, reviewed diff unchanged (%s)" % (attested[:12], live_head[:12], digest[:12])}
    return {"state": "owes-review",
            "detail": "attested at %s, head is %s, the reviewed diff CHANGED (%s → %s)" % (attested[:12], live_head[:12], digest[:12], (got or "-")[:12])}


def inherited_reds(pr_reds, main_reds):
    """The red groups this PR shares with main's head — a fixer cannot fix those, and must not try."""
    if not main_reds:
        return []
    return [r for r in pr_reds if (r["app"], r["workflow"], r["job"]) in main_reds]


def action_for(ev):
    """THE ROW. One action, first match wins, and the reason is part of the answer.

    Precedence is "what must happen FIRST in time": an action that would be thrown away by the next
    one (reviewing a tree that is about to be rebased, running CI on a conflicting head) is not the
    next action.
    """
    checks = ev["checks"]
    att = ev.get("attest")
    fid = ev.get("fidelity") or {"state": "absent", "detail": "no attestation record"}

    if ev.get("authority") in (None, "unreadable"):
        # ⛔ FAIL CLOSED. "Is a review required here?" decides REPORT vs LAND, so an unreadable
        # protection endpoint must not answer it — the repo-authority.sh precedent (#1764).
        return "WAIT:authority-unreadable", "branch protection could not be read: %s" % (ev.get("authority_reason") or "no reason recorded")

    if ev.get("changed_files") == 0:
        return "CLOSE-STALE", "the PR carries no changed files — superseded, nothing to run or merge"

    if ev.get("is_draft"):
        # A draft cannot merge, so NOTHING it runs can make it mergeable. Not suppressed: marking a
        # draft ready does not move the head, so a cancelled run would not come back by itself.
        return "WAIT:draft", "draft PR — a draft cannot merge, so its CI cannot make it mergeable"

    if ev.get("mergeable") == "CONFLICTING":
        return "REPAIR-CONFLICT", "mergeable == CONFLICTING — no CI result matters until the branch has main"

    if ev.get("mergeable") in (None, "", "UNKNOWN"):
        return "WAIT:mergeable-unknown", "GitHub has not computed mergeability yet (mergeable=%s)" % (ev.get("mergeable") or "null")

    if checks["verdict"] == "RED":
        reds = checks["red"]
        inherited = inherited_reds(reds, ev.get("main_reds") or set())
        if inherited and len(inherited) == len(reds):
            r = inherited[0]
            return "WAIT:inherited-red", "%s is also red at main's head — not this tree's to fix" % r["group"]
        # RERUN-FLAKE needs POSITIVE evidence that this exact tree passed this exact job: an earlier
        # attempt of the SAME group, at THIS head, whose conclusion is a PASS (GREEN — `cancelled` and
        # `stale` are non-red for the verdict but are not passes, so they are not evidence). A red with
        # only a green at an OLDER head is not that evidence (the tree changed), and "it looks flaky"
        # is not
        # evidence at all. The bound is GitHub's own arithmetic: a re-run re-executes the SAME sha, so
        # the loop is finite only because we stop recommending it.
        flaked = [r for r in reds if r["passing_attempt"] and r["attempts"] < 3]
        if flaked:
            r = flaked[0]
            ev["_rerun_run"] = r["run"]          # the seam prints `gh run rerun <id> --failed`
            return "RERUN-FLAKE", "%s passed on an earlier attempt at this same head (attempts=%d) — rerun the FAILED jobs of run %s once" % (r["group"], r["attempts"], r["run"] or "?")
        retried = [r for r in reds if r["passing_attempt"]]
        if retried:
            r = retried[0]
            return "FIX-RED", "%s flaked on %d attempts at this head — a job that has flaked more than once is a defect, not a re-run" % (r["group"], r["attempts"])
        r = reds[0]
        more = "" if len(reds) == 1 else " (+%d more red)" % (len(reds) - 1)
        return "FIX-RED", "%s is %s%s — run the failing job of run %s, not the suite" % (r["group"], r["conclusion"], more, r["run"] or "?")

    review_required = ev.get("review_required")
    if att is None:
        if review_required:
            return "REVIEW", "no attestation at this head (store: %s)" % (ev.get("store") or "absent")
        # A repo whose merge contract does not consume a review record (the rail posts its own
        # head-bound evidence — repo-authority.sh `rail`): absence is not a defect there.
        fid = {"state": "n/a", "detail": "review not required by this repo's contract"}

    if fid["state"] == "absent" and att is not None:      # a record object that carried no head
        fid = {"state": "owes-review", "detail": "attestation record carries no readable head"}
    if fid["state"] == "owes-review":
        return "WAIT:owes-review", fid["detail"]
    if fid["state"] == "diff-unreadable":
        return "WAIT:diff-unreadable", fid["detail"] + " — RETRY the comparison; an unread diff is not a changed diff"
    if review_required and att is not None and att.get("source") == "marker" \
       and fid["state"] in ("at-head", "carried"):
        # The gate reads THIS BOX's store, not the PR body: an attestation recorded elsewhere would
        # be refused by the rail, so reporting LAND here would be a false ready.
        return "WAIT:attested-elsewhere", "attested at %s on the PR body only — not in this box's store (%s)" % ((att.get("head_sha") or "?")[:12], ev.get("store") or "absent")

    if checks["verdict"] == "NOREAD":
        return "WAIT:no-check-surface", checks["reason"]
    if checks["verdict"] == "WAIT":
        return "WAIT:in-flight", checks["reason"] + " — it becomes an answer on its own; touching it is the waste"

    state = fid["state"]
    return "LAND", "attested %s + mergeable + no real red on %d groups" % (state, checks["groups"])


def row_action(ev):
    """`action_for`, with the WAIT reason made machine-readable (the colon form the issue names)."""
    action, reason = action_for(ev)
    return action, reason


# ══════════════════════════════════════════════════════════════════════════════════════════════
# THE READ LAYER. Every read is a subprocess; none of it decides anything.
# ══════════════════════════════════════════════════════════════════════════════════════════════


class ReadError(Exception):
    """A read that failed. NEVER converted into "nothing there" by a caller."""


def gh(args, timeout=60):
    """One `gh` call. Returns stdout; raises ReadError on a NON-ZERO answer.

    An EMPTY body is deliberately NOT checked here: `cancel_run`'s `POST …/cancel` answers 202 with no
    body, so a global emptiness rule would report a successful cancel as failed. The JSON readers
    (`gh_json`, `gh_stream`) own that check, and both raise ReadError on an empty body.
    """
    cmd = [gh_bin()] + list(args)
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.SubprocessError) as e:
        raise ReadError("%s: %s" % (" ".join(cmd[:3]), e))
    if p.returncode != 0:
        msg = (p.stderr or p.stdout or "").strip().splitlines()
        raise ReadError("%s exited %d: %s" % (" ".join(cmd[:4]), p.returncode, (msg[0] if msg else "no output")[:200]))
    return p.stdout


def gh_json(args, timeout=60):
    out = gh(args, timeout=timeout)
    try:
        return json.loads(out)
    except ValueError:
        raise ReadError("%s returned a body that is not JSON (%d bytes)" % (" ".join(args[:3]), len(out)))


def gh_stream(args, timeout=180):
    """`gh api --paginate` emits ONE JSON OBJECT PER PAGE. Walk the stream, never just the first.

    ⛔ AN EMPTY OR TRUNCATED BODY IS A FAILED READ, NOT AN EMPTY SURFACE. `gh` exits 0 with no body
    when a token/proxy layer eats the answer, and a body cut mid-object is a truncated read — both
    used to arrive as `[]` (indistinguishable from "this PR has no checks", the exact confusion the
    NOREAD arm exists to prevent) or as an uncaught `JSONDecodeError` (a traceback and exit 1 instead
    of the documented `exit 2` with a named reason). The guard lives HERE and not in `gh()` because
    `cancel_run`'s `POST …/cancel` legitimately answers with an empty 202 body.
    """
    out = gh(args, timeout=timeout)
    if not (out or "").strip():
        raise ReadError("%s returned an EMPTY body — a failed read, not an empty surface" % " ".join(args[:3]))
    dec, i, items = json.JSONDecoder(), 0, []
    while i < len(out):
        while i < len(out) and out[i] in " \n\r\t":
            i += 1
        if i >= len(out):
            break
        try:
            obj, i = dec.raw_decode(out, i)
        except ValueError as e:
            raise ReadError("%s returned a body that is not JSON (%d bytes, %s)" % (" ".join(args[:3]), len(out), e))
        if isinstance(obj, list):
            items.extend(obj)
        elif isinstance(obj, dict) and isinstance(obj.get("items"), list):
            items.extend(obj["items"])
        elif obj is not None:
            items.append(obj)
    return items


def read_prs(repo, limit, only=None):
    """The candidate set. `mergeable` comes from the list read where GitHub has computed it."""
    fields = "number,headRefOid,headRefName,isDraft,mergeable,changedFiles,body"
    if only is not None:
        pr = gh_json(["pr", "view", str(only), "--repo", repo, "--json", fields])
        return [pr]
    prs = gh_json(["pr", "list", "--repo", repo, "--state", "open", "--limit", str(limit), "--json", fields])
    if not isinstance(prs, list):
        raise ReadError("the open-PR listing was not a list")
    return prs


def confirm_mergeable(repo, pr):
    """GitHub computes mergeability lazily; a single-PR read is what triggers it (lander.sh, measured).

    Only called for a row that would otherwise be WAIT:mergeable-unknown, and re-read once: an
    UNKNOWN that persists is reported as UNKNOWN, never guessed into MERGEABLE.
    """
    for _ in range(2):
        try:
            d = gh_json(["pr", "view", str(pr), "--repo", repo, "--json", "mergeable,isDraft"])
        except ReadError:
            return None
        if d.get("mergeable") in ("MERGEABLE", "CONFLICTING"):
            return d["mergeable"]
        time.sleep(1.0)
    return None


def read_check_rows(repo, sha):
    """The head's check surface, every attempt: (app.slug, workflow, job) rows for `verdict`."""
    items = gh_stream(["api", "--paginate",
                       "repos/%s/commits/%s/check-runs?per_page=100&filter=all" % (repo, sha)])
    runs = []
    for item in items:
        if item.get("total_count") is not None and "check_runs" in item:
            runs.extend(item.get("check_runs") or [])
        elif item.get("name") is not None:
            runs.append(item)
    rows = []
    for r in runs:
        m = DETAILS_RUN.search(r.get("details_url") or "")
        rows.append({
            "app": ((r.get("app") or {}).get("slug") or ""),
            "workflow": "",                      # resolved by resolve_workflows()
            "job": r.get("name") or "",
            "status": r.get("status") or "",
            "conclusion": r.get("conclusion") or "",
            "id": r.get("id") or 0,
            "run": m.group(1) if m else "",
        })
    return rows


def resolve_workflows(repo, sha):
    """run id → workflow name, from the head's own run listing (one call for the whole head).

    A check-run payload carries no workflow, and `details_url` carries only the run id, so this is
    the resolution step the grouping rule needs. A run the listing does not name stays unnamed and
    becomes its own group — never silently merged with another workflow's same-named job.

    ⛔ A FAILED LISTING IS `None`, NOT `{}` — and that is load-bearing. `{}` is the "nothing is named"
    answer, which puts EVERY attempt of a job in its own `?unknown:<run>` group; the newest attempt no
    longer wins, so a job whose newest attempt PASSED is reddened by an older failing one and a fixer
    is dispatched at a green head. Both callers turn `None` into their own read-failure arm.
    """
    out = {}
    try:
        items = gh_stream(["api", "--paginate",
                           "repos/%s/actions/runs?head_sha=%s&per_page=100" % (repo, sha)])
    except ReadError:
        return None
    for run in items:
        runs = run.get("workflow_runs") if isinstance(run.get("workflow_runs"), list) else [run]
        for r in runs:
            if r.get("id") is not None:
                out[str(r["id"])] = (r.get("name") or "").strip()
    return out


def read_queued(repo, page_limit=10):
    """The repo's QUEUED runs, keyed by head sha: one paginated read, not one call per PR."""
    by_head, page = {}, 1
    while page <= page_limit:
        d = gh_json(["api", "repos/%s/actions/runs?status=queued&per_page=100&page=%d" % (repo, page)])
        runs = d.get("workflow_runs") or []
        total = d.get("total_count") or 0
        for r in runs:
            head = r.get("head_sha") or ""
            by_head.setdefault(head, []).append({
                "id": r.get("id"), "name": r.get("name") or "", "workflow_id": r.get("workflow_id"),
                "status": r.get("status") or "", "event": r.get("event") or "",
                "created_at": r.get("created_at") or "",
            })
        if not runs or page * 100 >= total:
            break
        page += 1
    return by_head


def read_main_reds(repo, base="main"):
    """The (app, workflow, job) groups red at main's head — main's newest attempt per group."""
    try:
        ref = gh_json(["api", "repos/%s/git/ref/heads/%s" % (repo, base)])
        sha = ((ref.get("object") or {}).get("sha") or "")
        if not sha:
            return None
        rows = read_check_rows(repo, sha)
        names = resolve_workflows(repo, sha)
        if names is None:
            # Main's workflow names are part of the same read: without them main's own groups are
            # split the same way, so "is this job red at main?" cannot be answered. Unknown main
            # keeps this tree's red (the caller's documented fallback), never "main is green".
            return None
        for r in rows:
            r["workflow"] = names.get(r["run"], "")
        v = verdict(rows)
        return {(x["app"], x["workflow"], x["job"]) for x in v["red"]}
    except ReadError:
        # Unreadable main is NOT "main is green": the caller reports no inherited set and keeps its red.
        return None


def read_authority(repo, base="main"):
    """`gate` | `rail` | `unreadable` — is the review gate part of THIS repo's required checks?

    Not a config file: it is the repo's own branch protection, the same source `repo-authority.sh`
    reads (#1764). Unreadable is a NAMED abstention, never "no review required".
    """
    gate = env("REVIEW_GATE") or DEFAULT_REVIEW_GATE
    try:
        ctx = gh_json(["api", "repos/%s/branches/%s/protection/required_status_checks/contexts" % (repo, base)])
    except ReadError as e:
        return "unreadable", str(e)
    if isinstance(ctx, dict) and isinstance(ctx.get("contexts"), list):
        ctx = ctx["contexts"]
    elif not isinstance(ctx, list):
        # ⛔ A BODY THAT IS NOT A LIST IS AN ABSTENTION, NOT "NO REQUIRED CHECKS". `null`, a bare
        # string or an HTML error page all parse as JSON-or-not yet answer 200; reading them as an
        # empty context list classifies a review-GATED repo as `rail`, which drops `review_required`
        # and lets an unattested PR report LAND — the fail-open this function exists to prevent.
        # `[]` (a legitimate "no required checks") still answers `rail`.
        return "unreadable", "the required-status-checks contexts were not a list (%s)" % type(ctx).__name__
    names = [c if isinstance(c, str) else ((c or {}).get("context") or "") for c in (ctx or [])]
    return ("gate" if gate in names else "rail"), "required: %s" % ", ".join(n for n in names if n)


def read_local_record(repo, pr):
    """The record the RAIL's gate reads: this box's store, qualified name first, then legacy."""
    store = env("PR_STATE_REVIEWS") or os.path.expanduser("~/.pi/agent/reviews")
    owner, _, name = (repo or "").partition("/")
    cands = [os.path.join(store, "%s-%s-%s.json" % (owner.lower(), name.lower(), pr)),
             os.path.join(store, "%s-%s-%s.json" % (owner, name, pr)),
             os.path.join(store, "%s.json" % pr)]
    for path in cands:
        if not os.path.exists(path):
            continue
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as fh:
                rec = json.load(fh)
        except (OSError, ValueError):
            # Exists but unreadable is NOT absent — say so rather than answering "no attestation".
            return {"error": "record exists at %s but could not be read" % path}
        if not isinstance(rec, dict):
            return {"error": "record at %s is not an object" % path}
        rec_repo = (rec.get("repo") or "").strip().lower()
        if rec_repo and rec_repo != (repo or "").lower():
            continue                       # another repo's PR of the same number
        return {"verdict": rec.get("verdict") or "", "head_sha": (rec.get("head_sha") or "").lower(),
                "diff_sha256": (rec.get("diff_sha256") or "").lower(), "source": "file", "path": path}
    return None


def record_sh():
    if env("PR_STATE_RECORD_SH"):
        return env("PR_STATE_RECORD_SH")
    here = os.path.dirname(os.path.abspath(__file__))
    for cand in (os.path.join(here, "..", "..", "scripts", "record-review.sh"),
                 os.path.join(env("O") or os.path.expanduser("~/orchestrator"), "record-review.sh")):
        if os.path.isfile(cand):
            return os.path.normpath(cand)
    return ""


def live_diff_hash(pr, repo):
    """The ONE diff-identity implementation (record-review.sh's documented read seam)."""
    sh = record_sh()
    if not sh:
        return False, "record-review.sh not found for the live diff read"
    try:
        p = subprocess.run(["bash", sh, "--print-diff-hash", str(pr), repo],
                           capture_output=True, text=True, timeout=180)
    except (OSError, subprocess.SubprocessError) as e:
        return False, "the diff read did not run: %s" % e
    line = (p.stdout or "").strip().splitlines()
    if p.returncode != 0 or not line:
        return False, (p.stderr or p.stdout or "no output").strip().splitlines()[0][:160]
    parts = line[-1].split("\t")
    status = parts[0] if parts else ""
    digest = (parts[1] if len(parts) > 1 else "").lower()
    if status != "ok" or not HEX64.match(digest):
        return False, "status=%s digest=%s" % (status or "?", (digest or "-")[:12])
    return True, digest


# ══════════════════════════════════════════════════════════════════════════════════════════════
# THE PASS — evidence per PR, then the one action.
# ══════════════════════════════════════════════════════════════════════════════════════════════


def evidence_for(repo, pr, authority, queued_by_head, main_reds_getter):
    """Everything one row needs, read once. Returns the `ev` dict `action_for` consumes."""
    number = pr.get("number")
    head = (pr.get("headRefOid") or "").lower()
    ev = {
        "number": number, "head": head, "branch": pr.get("headRefName") or "",
        "mergeable": pr.get("mergeable"), "is_draft": bool(pr.get("isDraft")),
        "changed_files": pr.get("changedFiles"),
        "authority": (authority or (None, ""))[0],
        "authority_reason": (authority or (None, ""))[1],
        "review_required": (authority or (None, ""))[0] == "gate",
        "attest": None, "fidelity": {"state": "absent", "detail": "no attestation record"},
        "main_reds": set(), "queued": [], "queued_known": queued_by_head is not None,
        "store": env("PR_STATE_REVIEWS") or os.path.expanduser("~/.pi/agent/reviews"),
        "checks": {"verdict": "NOREAD", "groups": 0, "red": [], "in_flight": 0, "reason": "not read"},
    }
    if ev["mergeable"] in (None, "", "UNKNOWN"):
        got = confirm_mergeable(repo, number)
        if got:
            ev["mergeable"] = got

    rows, names, read_ok = [], {}, True
    if head:
        try:
            rows = read_check_rows(repo, head)
            names = resolve_workflows(repo, head)
            if names is None:
                # The workflow names are what STOP one workflow's same-named job masking another; a
                # failed read of them does not degrade to "unnamed", it fails the surface read.
                raise ReadError("the head's run listing could not be read — the workflow that owns "
                                "each check cannot be resolved, so the groups cannot be trusted")
        except ReadError as e:
            read_ok = False
            rows = []                  # a failed surface read keeps NO rows (there is no evidence)
            ev["checks"] = {"verdict": "NOREAD", "groups": 0, "red": [], "in_flight": 0,
                            "reason": "the check surface could not be read: %s" % e}
    for r in rows:
        r["workflow"] = names.get(r["run"], "")
    if read_ok:
        # ⛔ A SURFACE THAT WAS READ AND IS EMPTY IS STILL `verdict([])` — NOREAD with its own
        # reason ("empty surface (no check groups) — a missing check is not green"). Gating this on
        # `rows` reported an empty surface as "not read" and left the NOREAD arm's own reason
        # unreachable, so the one row a reader sees was wrong about WHY it was waiting.
        ev["checks"] = verdict(rows)

    ev["queued"] = [q for q in ((queued_by_head or {}).get(head) or [])]

    rec = read_local_record(repo, number)
    if isinstance(rec, dict) and rec.get("error"):
        ev["attest"] = {"source": "file-unreadable", "head_sha": "", "verdict": ""}
        ev["fidelity"] = {"state": "owes-review",
                          "detail": "a review record exists and could not be read — %s" % rec["error"]}
    else:
        if rec is None:
            rec = choose_marker(pr.get("body") or "", head)
        if rec is not None:
            ev["attest"] = rec
            ev["fidelity"] = fidelity(rec, head, lambda: live_diff_hash(number, repo))

    if ev["checks"]["verdict"] == "RED":
        # ONE main read per pass, lazily: main's head is the same question for every row, and
        # re-reading it per red PR is how a triage tool becomes the load it is meant to remove.
        ev["main_reds"] = main_reds_getter() or set()
    return ev


def build_rows(repo, limit=100, only=None, threads=6):
    """The table. Raises ReadError when the pass cannot be made — never an empty table."""
    prs = read_prs(repo, limit, only=only)
    authority = read_authority(repo)
    try:
        queued_by_head = read_queued(repo)
    except ReadError:
        # ⛔ AN UNREADABLE QUEUE IS NOT AN EMPTY QUEUE. `None` (not `{}`) is what carries that
        # difference to the renderer, which prints `?` — a `0` here would be indistinguishable from
        # a genuinely empty queue and would silently understate the operator's only queue reading
        # (and `--suppress`'s `before=` figure). It also disables suppression, which CANCELS NOTHING
        # in that state — and says so with exit 2 rather than reporting an empty pass as success.
        queued_by_head = None
    cache = {}
    lock = threading.Lock()

    def main_reds_once():
        with lock:
            if "v" not in cache:
                cache["v"] = read_main_reds(repo)
            return cache["v"]

    with ThreadPoolExecutor(max_workers=max(1, threads)) as pool:
        evs = list(pool.map(lambda p: evidence_for(repo, p, authority, queued_by_head, main_reds_once), prs))
    rows = []
    for ev in evs:
        action, reason = row_action(ev)
        rows.append({
            "pr": ev["number"], "head_sha": ev["head"], "branch": ev["branch"],
            "mergeable": ev["mergeable"], "is_draft": ev["is_draft"],
            "changed_files": ev["changed_files"],
            "attested_sha": (ev["attest"] or {}).get("head_sha") or None,
            "attestation_source": (ev["attest"] or {}).get("source"),
            "fidelity": ev["fidelity"]["state"], "fidelity_detail": ev["fidelity"]["detail"],
            "checks_verdict": ev["checks"]["verdict"],
            "red_groups": [r["group"] for r in ev["checks"]["red"]],
            "in_flight": ev["checks"]["in_flight"], "groups": ev["checks"]["groups"],
            "queued_runs": [q["id"] for q in ev["queued"]],
            "queued_known": ev["queued_known"],
            "rerun_run": ev.get("_rerun_run") or "",
            "action": action, "reason": reason,
        })
    rows.sort(key=lambda r: (r["action"], r["pr"]))
    return rows


# ══════════════════════════════════════════════════════════════════════════════════════════════
# POLICY 1 — SUPPRESSION. Cancels QUEUED runs on heads whose row says the head is about to change.
# ══════════════════════════════════════════════════════════════════════════════════════════════


def ledger_path():
    if env("PR_STATE_LEDGER"):
        return env("PR_STATE_LEDGER")
    state = os.path.join(env("O") or os.path.expanduser("~/orchestrator"), "state")
    return os.path.join(state, "pr-state-suppressed.jsonl")


def cancel_run(repo, run_id):
    """Cancel ONE run, after re-reading it. A run that is no longer `queued` is NEVER cancelled."""
    cur = gh_json(["api", "repos/%s/actions/runs/%s" % (repo, run_id)])
    status = (cur.get("status") or "").strip().lower()
    if status != "queued":
        return False, "status is %r now, not queued — not cancelled" % (status or "?")
    gh(["api", "-X", "POST", "repos/%s/actions/runs/%s/cancel" % (repo, run_id)])
    return True, "cancelled while queued"


def suppress(repo, rows, dry_run=False):
    """Cancel queued runs for rows whose head is about to change. Returns (cancelled, skipped, error).

    ⛔ A PASS THAT COULD NOT ENUMERATE ANYTHING IS NOT A PASS THAT FOUND NOTHING. With an unreadable
    queued-run inventory every row's `queued_runs` is empty, so the loop below would cancel nothing,
    report `cancelled=0` and exit 0 — a success signal for a pass that never ran, against this
    module's own contract ("`--suppress` returns 2 when the cancel pass could not be completed").
    """
    if rows and not all(r.get("queued_known", True) for r in rows):
        return [], [], ("the queued-run inventory could not be read, so no queued run could be "
                        "enumerated and NOTHING was cancelled — re-run --suppress when the read succeeds")
    todo = [r for r in rows if r["action"] in SUPPRESS_ACTIONS]
    cancelled, skipped, error = [], [], None
    if not todo:
        return cancelled, skipped, error
    for r in todo:
        for run_id in r["queued_runs"]:
            if dry_run:
                cancelled.append({"dry_run": True, "pr": r["pr"], "head_sha": r["head_sha"],
                                  "run_id": run_id, "action": r["action"], "reason": r["reason"]})
                continue
            try:
                ok, why = cancel_run(repo, run_id)
            except ReadError as e:
                error = str(e)
                continue
            if ok:
                cancelled.append({"pr": r["pr"], "head_sha": r["head_sha"], "run_id": run_id,
                                  "action": r["action"], "reason": r["reason"], "why": why})
            else:
                skipped.append({"pr": r["pr"], "run_id": run_id, "why": why})
    if cancelled and not dry_run:
        path = ledger_path()
        try:
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "a", encoding="utf-8") as fh:
                for c in cancelled:
                    fh.write(json.dumps(dict(c, repo=repo, ts=int(time.time()),
                                             event="ci-suppressed"), sort_keys=True) + "\n")
        except OSError as e:
            # ⛔ A CANCEL THAT WAS NOT RECORDED IS A LOST GATE, not a cosmetic gap: refuse to call
            # the pass complete (the caller turns this into exit 2) and say exactly what was lost.
            error = "cancelled %d run(s) but the ledger could not be written (%s): %s" % (
                len(cancelled), path, e)
    return cancelled, skipped, error


def print_cancelled(limit=200):
    """What was cancelled, and the command that re-triggers each — mechanically, one line per run."""
    path = ledger_path()
    if not os.path.isfile(path):
        print("no suppression ledger at %s — nothing has been cancelled on this box" % path)
        return 0
    rows = []
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except ValueError:
                continue
    if not rows:
        print("ledger %s is empty" % path)
        return 0
    print("# %d suppressed run(s) — re-trigger one with the printed command (same sha, same event)" % len(rows))
    print("# PR\tHEAD\tRUN\tACTION\tRETRIGGER")
    for r in rows[-limit:]:
        print("%s\t%s\t%s\t%s\tgh run rerun %s" % (
            r.get("pr", "?"), (r.get("head_sha") or "?")[:12], r.get("run_id", "?"),
            r.get("action", "?"), r.get("run_id", "?")))
    return 0


# ══════════════════════════════════════════════════════════════════════════════════════════════
# RENDER + CLI
# ══════════════════════════════════════════════════════════════════════════════════════════════

TABLE_COLS = ("PR", "HEAD", "ATTESTED", "FIDELITY", "MERGEABLE", "CHECKS", "Q", "ACTION", "REASON")


def render_table(rows, repo):
    out = []
    with_q = [r for r in rows if r["queued_runs"]]
    # ⛔ A QUEUE READ THAT FAILED RENDERS AS `?`, NEVER `0`. Every row carries the same flag (it is a
    # property of the one inventory read), so it is stated once in the header and once in the Q
    # column; `0` is reserved for a queue that was actually READ and is empty.
    queued_known = all(r.get("queued_known", True) for r in rows)
    green = sum(1 for r in rows if r["checks_verdict"] == "GREEN")
    red = sum(1 for r in rows if r["checks_verdict"] == "RED")
    hist = {}
    for r in rows:
        hist[r["action"]] = hist.get(r["action"], 0) + 1
    out.append("# pr-state %s — %d open PRs: %d MERGEABLE, %d CONFLICTING, %d checks GREEN, %d RED, %s queued runs on %s PRs" % (
        repo, len(rows),
        sum(1 for r in rows if r["mergeable"] == "MERGEABLE"),
        sum(1 for r in rows if r["mergeable"] == "CONFLICTING"),
        green, red,
        ("%d" % sum(len(r["queued_runs"]) for r in rows)) if queued_known else "?",
        ("%d" % len(with_q)) if queued_known else "?"))
    if not queued_known:
        out.append("# the queued-run inventory could not be read — Q is UNKNOWN on every row, not 0 "
                   "(an unreadable queue is not an empty queue); no queued run can be enumerated, so "
                   "a --suppress pass cancels nothing and says so (exit 2)")
    out.append("# actions: " + " ".join("%s=%d" % (k, hist[k]) for k in sorted(hist)))
    out.append("")
    out.append("\t".join(TABLE_COLS))
    for r in rows:
        out.append("\t".join([
            str(r["pr"]),
            (r["head_sha"] or "?")[:12],
            (r["attested_sha"] or "-")[:12],
            r["fidelity"],
            str(r["mergeable"] or "null"),
            r["checks_verdict"] + ("" if r["checks_verdict"] != "RED" else "(%d)" % len(r["red_groups"])),
            str(len(r["queued_runs"])) if r.get("queued_known", True) else "?",
            r["action"],
            r["reason"],
        ]))
    return "\n".join(out)


def main(argv):
    args = list(argv[1:])
    repo, limit, only = env("PR_STATE_REPO"), 100, None
    as_json = suppress_flag = dry_run = show_cancelled = action_only = False
    i = 0
    while i < len(args):
        a = args[i]
        if a in ("-h", "--help"):
            print(__doc__)
            return 0
        elif a == "--repo":
            i += 1
            repo = args[i] if i < len(args) else None
        elif a == "--limit":
            i += 1
            try:
                limit = max(1, int(args[i]))
            except (IndexError, ValueError):
                print("pr-state: --limit needs an integer", file=sys.stderr)
                return 2
        elif a == "--only":
            i += 1
            try:
                only = int(args[i])
            except (IndexError, ValueError):
                print("pr-state: --only needs a PR number", file=sys.stderr)
                return 2
        elif a == "--json":
            as_json = True
        elif a == "--action":
            # The ACTOR SEAM (agent-infra #2866): one TSV row — `ACTION<TAB>rerun_run<TAB>reason` —
            # so a bash consumer needs no JSON parser and cannot disagree with this module about
            # the action. Exit 0 when a row was produced, 2 when the pass could not be made.
            action_only = True
        elif a == "--suppress":
            suppress_flag = True
        elif a == "--dry-run":
            dry_run = True
        elif a == "--cancelled":
            show_cancelled = True
        elif a == "--ledger":
            i += 1
            if i < len(args):
                os.environ["PR_STATE_LEDGER"] = args[i]
        else:
            print("pr-state: unknown argument %r (see --help)" % a, file=sys.stderr)
            return 2
        i += 1

    if show_cancelled:
        return print_cancelled()
    if not repo or "/" not in repo:
        print("pr-state: --repo owner/name is required (or PR_STATE_REPO)", file=sys.stderr)
        return 2

    try:
        rows = build_rows(repo, limit=limit, only=only)
    except ReadError as e:
        # ⛔ AN UNREADABLE BOARD IS NOT AN EMPTY BOARD. Nothing is reported as "no open PRs".
        print("pr-state: the pass could not be made — %s" % e, file=sys.stderr)
        return 2

    if action_only:
        if only is None:
            # ⛔ `--action` ANSWERS FOR ONE PR. Without `--only` the row printed would be whichever
            # sorts first in the whole table — another PR's action, with exit 0, in the shape an
            # actor cannot tell apart from the one it asked about.
            print("pr-state: --action needs --only <pr> (one row, one PR)", file=sys.stderr)
            return 2
        if not rows:
            print("pr-state: no row for that PR (it is not in the open set) — nothing to act on",
                  file=sys.stderr)
            return 2
        r = rows[0]
        print("%s\t%s\t%s" % (r["action"], r["rerun_run"], r["reason"]))
        return 0

    rc = 0
    cancelled, skipped, err = [], [], None
    if suppress_flag:
        cancelled, skipped, err = suppress(repo, rows, dry_run=dry_run)
        for c in cancelled:
            print("suppress%s: PR #%s %s run %s (%s)" % (
                " (dry-run)" if c.get("dry_run") else "", c["pr"], c["head_sha"][:12], c["run_id"], c["action"]))
        for s in skipped:
            print("suppress: PR #%s run %s NOT cancelled — %s" % (s["pr"], s["run_id"], s["why"]))
        if not dry_run:
            # The measurement the issue asks for: the queue BEFORE and AFTER, re-read — never the
            # arithmetic from what we think we cancelled.
            try:
                after = sum(len(v) for v in read_queued(repo).values())
            except ReadError as e:
                after = None
                print("suppress: the queue could not be re-read after the pass (%s)" % e, file=sys.stderr)
            before = ("%d" % sum(len(r["queued_runs"]) for r in rows)) \
                if all(r.get("queued_known", True) for r in rows) else "?"
            print("suppress: queued runs before=%s after=%s (cancelled=%d, not_cancelled=%d)" % (
                before, "?" if after is None else after, len(cancelled), len(skipped)))
        if err:
            print("suppress: %s" % err, file=sys.stderr)
            rc = 2

    if as_json:
        print(json.dumps({"repo": repo, "rows": rows,
                          "suppressed": cancelled, "not_cancelled": skipped,
                          "suppression_error": err}, indent=2, sort_keys=True))
    else:
        print(render_table(rows, repo))
        if suppress_flag:
            print("")
            print("# suppressed %d queued run(s); ledger: %s" % (len(cancelled), ledger_path()))
    return rc


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except ReadError as e:                      # a read failed outside a handled arm
        print("pr-state: %s" % e, file=sys.stderr)
        sys.exit(2)
