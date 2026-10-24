#!/usr/bin/env python3
"""nochk-resolve.py — THE ARM FOR THE `NOCHECKS` CLASS (agent-infra #2719).

THE DEFECT THIS REPLACES. `orch-loop.sh` classifies every candidate PR with one core-bucket read and
discards that read's stderr (`gh pr checks … 2>/dev/null | py …`). Three different events therefore
arrive as the same token — `NOCHECKS` — and the class had NO acting arm: the sweep printed
"no acting arm for class 'NOCHECKS' — nothing spawned (re-read next cycle)" and re-read the same PR
for ever. "Re-read next cycle" is not a plan.

MEASURED over every occurrence in the controller's own log (5 days, 2026-10-20 → 2026-10-24:
77 occurrences, 42 cycles, 47 distinct PRs), classifying each against the AUTHORITY
(`/commits/<sha>/check-runs?filter=all`) at the head that existed at that cycle's timestamp:

    63  READ-FAILED     the surface EXISTED; the read returned nothing        (82%)
     6  NEVER-STARTED   zero check-runs AND zero workflow runs at the head      (8%)
     4  NOT-YET         the surface appeared minutes AFTER the cycle            (5%)
     4  UNKNOWN         the head at that time could not be resolved            (5%)

So the class is NOT mostly an empty surface — it is mostly a FAILED READ, and the failure is the one
the log shows verbatim (`error connecting to api.github.com / check your internet connection or
https://githubstatus.com`) whenever the transport is unhealthy for a few seconds: it hits BURSTS of
PRs in one sweep (14 of 26 swept in the 2026-10-23 02:45 cycle). The causes need OPPOSITE remedies and
must never share one token.

WHAT THIS FILE WILL NOT DO. It never merges, never invents a green, never records at a head, and it
does not re-trigger anything by itself. `NOCHECKS` is a NON-ANSWER: a missing check is not a pass and
not a pending one, so every verdict here leaves the PR exactly as unmergeable as it was. The sanctioned
repair for a head with no run is the repo's OWN (tortoise: the scheduled `ci-check-repair` workflow,
which re-runs a held run or close/reopens the PR); this file NAMES that owner instead of duplicating it.

VERDICT VOCABULARY (one line on stdout: `<TOKEN>\t<detail>`; every token is TERMINAL for the cycle):

  RECOVERED:<class>   the re-read (after retry, or via the check-runs authority) produced a real
                      class — GREEN | PENDING:… | FAILED:… — and the PR LEAVES the class this cycle
  BUDGET:<detail>     the gh budget layer refused the read LOCALLY (exit 75, gh-limit's own
                      "refused, retry later" signal) — a WINDOW, never a statement about the repo
  READ-FAILED:<detail> the read failed after retries (transport/auth/other) — retried next cycle
  WAIT:<detail>       the absence is real but a run at this head is executing and young enough to
                      still report: wait, and say so
  DEFERRED-REPAIR:<detail>  no run can report at this head and the absence has NOT yet outlived the
                      bound (or the bound cannot be counted); counted, and escalated at the bound
  UNRESOLVABLE:<detail>     TERMINAL: the absence outlived the bound at one head. The caller posts
                      this on the PR once and parks the head, so no further cycle is spent on it.

⛔ THE BOUND IS NEVER SHORT-CIRCUITED (review P0, agent-infra#2719). An earlier revision went TERMINAL
on the FIRST cycle when the repo declared no repair workflow — which is exactly the measured NOT-YET
cohort (a head pushed 2–9 minutes ago has zero check-runs and zero runs, because the runs have not been
created yet). That published a false claim on the PR and parked a head that would have gone green
minutes later. EVERY terminal verdict now waits out the bound at that head; "no repair declared" only
changes the DETAIL, never the bound.

BOUND. The counter is per (PR, head) — a push re-arms it, exactly like every other bound in the
harness. Default 3 cycles; `--attempt-bound` moves it. If the counter cannot be written, the verdict
says the bound is INERT instead of pretending to count (a bound that cannot advance must never read as
one that is advancing).

EXIT. 0 a verdict was produced (of ANY polarity — polarity is the token, not the status);
      2 usage/argument error.
"""
from __future__ import annotations

import argparse
import calendar
import json
import os
import subprocess
import sys
import time
from typing import Any

HERE = os.path.dirname(os.path.abspath(__file__))
CLASSIFIER = os.path.join(HERE, "check-class.py")

# The controller's own read. Kept IDENTICAL to `orch-loop.sh`'s `V=` pipeline on purpose: the arm's
# whole job is to re-ask the same question better, not a different one.
GH_CHECKS_ARGV = ["gh", "pr", "checks", "{pr}", "--repo", "{repo}", "--json", "name,state,workflow"]

# The AUTHORITY (the research rule this file implements): check-runs, `filter=all` as a QUERY STRING,
# newest attempt per (app, name). `statusCheckRollup` is NOT the authority — the repo has a recorded
# case of the rollup omitting an existing green check.
AUTHORITY_PAGE = "repos/{repo}/commits/{sha}/check-runs?per_page=100&filter=all"
RUNS_AT_HEAD = "repos/{repo}/actions/runs?head_sha={sha}&per_page=30"

# gh-limit's local-refusal exit code (EX_TEMPFAIL). Its stderr says "refused LOCALLY, retry later" —
# the caller reads the VERDICT from this code, so a text match is never needed.
RC_LOCAL_REFUSAL = 75
# Text fallbacks for the same refusal (an older gh-limit that predates the exit-code contract) and for
# a true primary/secondary rate limit arriving from GitHub itself.
BUDGET_MARKERS = (
    "gh-limit:", "budget is exhausted", "rate limit exceeded", "secondary rate limit",
    "gh-core-floor", "gh-core-exhausted",
)
AUTH_MARKERS = ("authentication", "bad credentials", "gh auth login", "401", "requires authentication")
# The measured transport failure (verbatim from the controller's log).
TRANSPORT_MARKERS = (
    "error connecting", "internet connection", "githubstatus", "timeout", "timed out",
    "connection reset", "connection refused", "tls", "eof", "502", "503", "504", "no such host",
)
# ⛔ `gh pr checks` ON A HEAD WITH NO CHECKS EXITS 1 AND SAYS SO ON STDERR. That is an EMPTY SURFACE,
# not a failed read — folding it into the retry/READ-FAILED path would send every genuinely unchecked
# head to the wrong branch (and would have made this arm unable to reach its own terminal verdict).
EMPTY_SURFACE_MARKERS = ("no checks reported", "no checks")
# A check-run status the API names as in flight — the same five the classifier and the rail use.
INFLIGHT = ("queued", "in_progress", "waiting", "requested", "pending")


def die(msg: str) -> "NoReturn":  # type: ignore[name-defined]
    sys.stderr.write(f"nochk-resolve: {msg}\n")
    sys.exit(2)


def gh(argv: list[str], timeout: float = 120.0) -> tuple[int, str, str]:
    """Run gh (through the shim chain on PATH, so the budget layer still applies)."""
    try:
        p = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return 124, "", "timeout: gh did not answer within %ds" % int(timeout)
    except FileNotFoundError:
        return 127, "", "gh: not found on PATH"
    return p.returncode, p.stdout, p.stderr


def one_line(text: str, limit: int = 220) -> str:
    """A detail field must never carry a tab or a newline: the ledger is TAB-delimited."""
    s = " ".join((text or "").split())
    return s[:limit]


def classify(rows: Any, req: str, rgate: str) -> str:
    """THE classifier — `check-class.py`, the same file the sweep's `V=` pipeline runs.

    ⛔ A FAILED CLASSIFICATION IS NOT `NOCHECKS` (review P1, agent-infra#2719). Four different failures
    — the sibling file absent (the `$O`-one-file-behind deploy state), an exception, a non-zero rc, or
    no output line — all used to return the token `NOCHECKS`, which the caller reads as "the classifier
    graded this and found nothing". Reproduced: with `check-class.py` absent and a GREEN surface on the
    wire, the arm answered `RECOVERED NOCHECKS` and the sweep turned that into a TERMINAL verdict on
    cycle 1 — no bound, no post, and a false cause ("the repo declares no required check"). So a
    failure returns its own token, and every caller treats it as a read failure, never as a class.
    """
    if not os.path.isfile(CLASSIFIER):
        return f"UNCLASSIFIABLE:check-class.py is not at {CLASSIFIER}"
    env = dict(os.environ, REQ=req, REVIEW_GATE=rgate)
    try:
        p = subprocess.run(
            [sys.executable, CLASSIFIER], input=json.dumps(rows), capture_output=True,
            text=True, timeout=60, env=env,
        )
    except Exception as e:  # noqa: BLE001
        return f"UNCLASSIFIABLE:the classifier did not run ({e!r})"
    if p.returncode != 0:
        return f"UNCLASSIFIABLE:the classifier exited {p.returncode}: {one_line(p.stderr, 80)}"
    line = (p.stdout.strip().splitlines() or [""])[0]
    if not line:
        return "UNCLASSIFIABLE:the classifier printed nothing"
    return line


def graded(label: str) -> bool:
    """Did the classifier actually grade this surface? A failure token is not a class."""
    return bool(label) and not label.startswith("UNCLASSIFIABLE:") and label != "NOCHECKS"


def read_checks(repo: str, pr: int) -> tuple[list | None, str]:
    """The controller's read. Returns (rows, "") on a real answer, (None, reason) otherwise.

    ⛔ REAL `gh pr checks` EXITS 1 WHEN A CHECK FAILED AND 8 WHEN CHECKS ARE PENDING. The rc is
    therefore NOT an answer, and `set -o pipefail` in a pipeline makes it look like one — the trap
    `lander.sh` documents at its own check read. The answer is "did stdout parse as check rows".
    """
    rc, out, err = gh([a.format(pr=pr, repo=repo) for a in GH_CHECKS_ARGV])
    if out.strip():
        try:
            d = json.loads(out)
        except Exception:
            d = None
        rows = d.get("check_runs") if isinstance(d, dict) else d
        if isinstance(rows, list):
            return rows, ""
    # No parseable rows. Now the reason matters — and it is on stderr, which the sweep discards.
    blob = f"{err}\n{out}".lower()
    if not out.strip() and any(m in blob for m in EMPTY_SURFACE_MARKERS):
        # gh's own "no checks reported on the '<branch>' branch": the surface is EMPTY, not blind.
        return [], ""
    if rc == RC_LOCAL_REFUSAL or any(m in blob for m in BUDGET_MARKERS):
        return None, "BUDGET:" + one_line(err or out or f"rc={rc}")
    if any(m in blob for m in AUTH_MARKERS):
        return None, "AUTH:" + one_line(err or out or f"rc={rc}")
    if not err.strip() and not out.strip():
        return None, f"EMPTY-OUTPUT:rc={rc}"
    if any(m in blob for m in TRANSPORT_MARKERS):
        return None, "TRANSPORT:" + one_line(err or out)
    return None, "OTHER:" + one_line(err or out or f"rc={rc}")


def _json_objects(blob: str) -> list:
    """Parse CONCATENATED JSON — `gh api --paginate` emits one object PER PAGE, not one array."""
    dec = json.JSONDecoder()
    out, i, n = [], 0, len(blob)
    while i < n:
        while i < n and blob[i] in " \t\r\n":
            i += 1
        if i >= n:
            break
        obj, j = dec.raw_decode(blob, i)
        out.append(obj)
        i = j
    return out


def authority(repo: str, sha: str) -> tuple[list | None, int, str]:
    """(rows, total_count, reason) from the check-runs AUTHORITY, in full (paginated).

    ⛔ AN UNRECOGNISED PAYLOAD IS UNREADABLE, NEVER EMPTY (review P1, agent-infra#2719). A page that is
    not an object, or an object without a `check_runs` list, or a payload with no `total_count` used to
    contribute zero rows and then fall back to `total = len(rows) = 0` — i.e. "the surface is absent",
    which is the input to the TERMINAL verdict. A shape this code does not understand must fail like a
    non-zero rc, not like an empty repo.
    """
    rc, out, err = gh(["gh", "api", "--paginate", AUTHORITY_PAGE.format(repo=repo, sha=sha)])
    if rc != 0:
        return None, -1, one_line(err or f"rc={rc}")
    try:
        pages = _json_objects(out)
    except Exception as e:  # noqa: BLE001
        return None, -1, f"unparseable authority payload: {e!r}"
    if not pages:
        return None, -1, "the authority answered with no pages"
    rows: list = []
    total = -1
    for p in pages:
        if not isinstance(p, dict):
            return None, -1, "an authority page is not an object"
        crs = p.get("check_runs")
        if not isinstance(crs, list):
            return None, -1, "an authority page carries no check_runs list"
        rows.extend(crs)
        if isinstance(p.get("total_count"), int):
            total = p["total_count"]
    if total < 0:
        return None, -1, "the authority payload carries no total_count"
    return rows, total, ""


def runs_at(repo: str, sha: str) -> tuple[list | None, str]:
    rc, out, err = gh(["gh", "api", RUNS_AT_HEAD.format(repo=repo, sha=sha)])
    if rc != 0:
        return None, one_line(err or f"rc={rc}")
    try:
        d = json.loads(out)
    except Exception as e:  # noqa: BLE001
        return None, f"unparseable runs payload: {e!r}"
    # Same rule as the authority: a payload without the list is UNREADABLE, never "no runs".
    if not isinstance(d, dict) or not isinstance(d.get("workflow_runs"), list):
        return None, "the runs payload carries no workflow_runs list"
    return d["workflow_runs"], ""


def repair_owner(repo_dir: str) -> str:
    """The repo's OWN repair for a head with no run — named, never duplicated (see the module doc)."""
    wf = os.path.join(repo_dir or "", ".github", "workflows", "ci-check-repair.yml")
    if repo_dir and os.path.isfile(wf):
        return "ci-check-repair (scheduled workflow + tools/ci-check-repair-local.sh)"
    return ""


def counter_path(state_dir: str, pr: int, sha: str) -> str:
    return os.path.join(state_dir, f"nochk-{pr}-{sha[:12]}")


def bump(state_dir: str, pr: int, sha: str) -> tuple[int, bool]:
    """(consecutive cycles at THIS head, was it countable). A push re-arms (new file).

    ⛔ THE SECOND VALUE IS NOT DECORATION (review P1, agent-infra#2719). The `except` used to return
    n=1 every cycle on an unwritable `state/`, so the bound could never advance and the PR was re-read
    for ever while the log claimed a counter that was moving — the same "inert bound" the sweep already
    names out loud for its own review-at-head counter. The caller now says INERT instead.
    """
    path = counter_path(state_dir, pr, sha)
    n = 0
    try:
        with open(path) as f:
            n = int((f.read() or "0").split()[0] or 0)
    except Exception:
        n = 0
    n += 1
    try:
        os.makedirs(state_dir, exist_ok=True)
        with open(path, "w") as f:
            f.write(f"{n}\n")
    except Exception:
        return n, False
    return n, True


def prune_heads(state_dir: str, pr: int, current_sha: str, keep_days: float = 3.0) -> None:
    """Remove THIS PR's counters for heads that are neither current nor recent.

    ⛔ THE PREVIOUS VERSION WAS INERT AND UNSAFE (review P3, agent-infra#2719): it looked for a sibling
    file 60s older than the head's newest, which never exists (a head's counter is written once), so it
    removed nothing — measured 9 files before and after. Had it fired it would also have deleted a
    `.posted` marker, letting a later terminal verdict post a SECOND comment at that head. This version
    is age-based, keeps the CURRENT head unconditionally (its counter and its posted marker), and only
    touches files older than `keep_days`.
    """
    try:
        names = [n for n in os.listdir(state_dir) if n.startswith(f"nochk-{pr}-")]
    except Exception:
        return
    now = time.time()
    for name in names:
        head = name[len(f"nochk-{pr}-"):].replace(".posted", "")
        if head and current_sha[:12].startswith(head):
            continue  # the head being counted — never pruned, in either direction
        path = os.path.join(state_dir, name)
        try:
            if (now - os.path.getmtime(path)) / 86400.0 <= keep_days:
                continue
            os.remove(path)
        except Exception:
            continue


def post_attempts(state_dir: str, pr: int, sha: str) -> tuple[int, bool]:
    """(failed post attempts at this head, was it countable).

    ⛔ THE SAME RULE AS `bump()` (review P2, agent-infra#2719): a counter that cannot be written must not
    read as one that is advancing. This used to swallow the failure and return 1 every cycle, so
    `tries < attempt_bound` was always true and a permanently failing `gh pr comment` was retried for
    ever (measured: 7 terminal cycles -> 7 comment attempts) — an unbounded ACTION loop, silent.
    """
    path = counter_path(state_dir, pr, sha) + ".posttries"
    try:
        with open(path) as f:
            n = int((f.read() or "0").split()[0] or 0)
    except Exception:
        n = 0
    n += 1
    try:
        os.makedirs(state_dir, exist_ok=True)
        with open(path, "w") as f:
            f.write(f"{n}\n")
    except Exception:
        return n, False
    return n, True


def already_posted(state_dir: str, pr: int, sha: str) -> bool:
    return os.path.exists(counter_path(state_dir, pr, sha) + ".posted")


def mark_posted(state_dir: str, pr: int, sha: str) -> bool:
    """Record that this head's verdict was published. False when it could not be.

    ⛔ THIS IS THE ONE WRITE THAT GUARDS AN IRREVERSIBLE PUBLIC ACTION (review P3, agent-infra#2719).
    It used to swallow its failure, and `already_posted()` is the ONLY thing that stops a second
    comment — so a marker that cannot be created re-posted the verdict on EVERY terminal cycle while
    the ledger said `[post=ok]` (measured: 2 terminal cycles -> 2 comments). A failed marker now
    reports `ok-nomarker`, which the sweep treats as terminal-and-parked: the verdict WAS published
    once, and the bounded thing to do is stop, not to publish it again.
    """
    try:
        with open(counter_path(state_dir, pr, sha) + ".posted", "w") as f:
            f.write("1\n")
        return True
    except Exception:
        return False


def post_unresolvable(repo: str, pr: int, sha: str, detail: str, evidence: str,
                      inflight: bool = False) -> bool:
    # ⛔ THE PUBLIC CLAIM MUST MATCH THE STATE (review P2, agent-infra#2719). "nothing available to it
    # can produce one" was published even when a run at the head was still EXECUTING — a statement the
    # controller could not know, about a run the wedge bound exists to say is not a wedge yet.
    if inflight:
        claim = ("a workflow run at this head has not produced a check-run and the controller has\n"
                 "stopped waiting for it (its state is in the reason below).\n\n")
    else:
        claim = ("nothing available to the controller can produce a check surface at this head.\n\n")
    body = (
        f"<!-- nochk-unresolvable:{sha} -->\n"
        "**NOCHECKS-UNRESOLVABLE** — the controller cannot obtain a check surface for this head:\n"
        + claim +
        f"- head: `{sha}`\n"
        f"- reason: {detail}\n"
        f"- evidence: {evidence}\n\n"
        "A missing check is not a pass and not a pending: the merge rail refuses a head with no\n"
        "evidence, so this PR is not waiting on CI latency — no check has reported here across the\n"
        "cycles above. The controller has PARKED this head and will not spend further cycles on it.\n\n"
        "**To lift the park** (any of these): push a commit (the park is head-bound, so a new head\n"
        "re-arms it automatically), or clear it on the controller's side with\n"
        f"`rm -f <controller-state>/parked-{pr} <controller-state>/parkreason-{pr}`\n"
        "(the state dir is the orchestrator's `state/`), or close/reopen the PR and then clear it.\n"
    )
    rc, _, err = gh(["gh", "pr", "comment", str(pr), "--repo", repo, "--body", body], timeout=120.0)
    if rc != 0:
        sys.stderr.write(f"nochk-resolve: the verdict could not be posted: {one_line(err)}\n")
        return False
    return True


def head_sha(repo: str, pr: int) -> str:
    rc, out, err = gh(["gh", "pr", "view", str(pr), "--repo", repo, "--json", "headRefOid"])
    if rc != 0 or not out.strip():
        return ""
    try:
        return str(json.loads(out).get("headRefOid") or "")
    except Exception:
        return ""


def run_age_min(run: dict) -> float | None:
    """Minutes since the run was created, or None when the API did not say.

    ⛔ UTC, NOT LOCAL (review P1, agent-infra#2719). The stamp ends in `Z`, and `time.mktime` reads the
    struct as LOCAL while `time.timezone` is the STANDARD-time offset — so on any box in DST the age is
    an hour too large. MEASURED under TZ=Europe/Madrid: a genuinely 3-minute-old run read as **63m**,
    i.e. past the 40m wedge bound, which turned a starting CI run into a "wedge" and then into a public
    terminal verdict and a park. The repo already recorded this exact gotcha in `scripts/orphan-reap.py`
    ("⛔ UTC, not local: the stamp ends in `Z`"). `calendar.timegm` is the UTC reader.
    """
    stamp = run.get("run_started_at") or run.get("created_at")
    if not isinstance(stamp, str):
        return None
    try:
        t = calendar.timegm(time.strptime(stamp, "%Y-%m-%dT%H:%M:%SZ"))
    except Exception:
        return None
    return max(0.0, (time.time() - t) / 60.0)


def resolve(args: argparse.Namespace) -> str:
    req = os.environ.get("REQ") or ""
    rgate = os.environ.get("REVIEW_GATE") or "ai-review-gate"
    repo, pr = args.repo, args.pr

    # ── 0. THE CYCLE-WIDE BREAKER ────────────────────────────────────────────────────────────────
    # ⛔ A TRANSPORT OUTAGE HITS THE WHOLE SWEEP, NOT ONE PR. MEASURED: the 2026-10-23 02:45 cycle read
    # NOCHECKS for 14 of 26 swept PRs — the connection to api.github.com was down for the whole sweep.
    # Retrying per PR through that would multiply the retry budget by the sweep size and stall the
    # cycle for minutes. So the FIRST PR to exhaust its retries records the cause here, and the rest
    # of the cycle is NAMED from that evidence without another call. The breaker is truncated at the
    # top of every cycle, AND it is honoured only while FRESH: a truncate that failed on a read-only
    # `state/` would otherwise leave a stale breaker that silences the re-read for every PR for ever —
    # the "past state, never revalidated" trap this harness has already paid for.
    if args.breaker and os.path.isfile(args.breaker):
        try:
            age_min = (time.time() - os.path.getmtime(args.breaker)) / 60.0
            first = open(args.breaker).read().strip()
        except Exception:
            age_min, first = 1e9, ""
        if first and age_min <= args.breaker_ttl_min:
            return (f"READ-FAILED:transport (cycle-wide breaker open; first failure: "
                    f"{one_line(first, 140)})")

    # ── 1. THE RE-READ, WITH RETRIES ─────────────────────────────────────────────────────────────
    # The dominant cause (82% measured) is a transient transport failure. One or two retries inside
    # the cycle turn that from "a cycle spent doing nothing" into "no cost at all", which is the
    # whole reason the class dragged: a burst of failed reads used to idles the sweep for a cycle.
    rows = None
    reason = ""
    for attempt in range(args.retries + 1):
        rows, reason = read_checks(repo, pr)
        if rows is not None:
            break
        if reason.startswith(("BUDGET:", "AUTH:")):
            break  # a window / a credential problem — retrying inside the cycle cannot fix either
        if attempt < args.retries:
            time.sleep(args.backoff * (attempt + 1))
    if rows is not None:
        if rows:
            label = classify(rows, req, rgate)
            if not graded(label):
                # The read ANSWERED and we still could not grade it. That is a reader/arm fault, so it
                # is named as one — and it is NEVER handed to an arm as if it were a class.
                return f"READ-FAILED:the re-read answered but could not be graded ({label})"
            return "RECOVERED:" + label
        return absent(repo, pr, args, req, rgate)
    if reason.startswith("BUDGET:"):
        return "BUDGET:" + reason.split(":", 1)[1]
    if reason.startswith("AUTH:"):
        return "READ-FAILED:credentials " + reason.split(":", 1)[1]
    if reason.startswith("TRANSPORT:") and args.breaker:
        try:
            with open(args.breaker, "w") as f:
                f.write(reason.split(":", 1)[1] + "\n")
        except Exception:
            pass
    # ONE SHAPE FOR THE DETAIL: `READ-FAILED:<cause>: <what gh said>`. The cause is lower-cased so a
    # ledger reader matches on one spelling, and the evidence keeps gh's own words verbatim.
    cause, _, rest = reason.partition(":")
    return (f"READ-FAILED:{cause.lower()}: {rest}".rstrip()).rstrip(":")


def absent(repo: str, pr: int, args: argparse.Namespace, req: str, rgate: str) -> str:
    """The read answered, and the answer is EMPTY. Is the surface absent, or is the READ blind?"""
    # ⛔ THE HEAD IS RE-READ, NOT TRUSTED FROM THE CYCLE (measured while building this: a probe that
    # passed an OLD head while the PR had moved queried the authority at a sha nobody was looking at,
    # so a head WITH a surface read as absent). The read above answered for the PR's CURRENT head —
    # whatever `--head` says — so that is the sha every following question must be asked about. The
    # observed head is only a FALLBACK, and a divergence is DISCLOSED on the verdict rather than
    # silently resolved in either direction. ⛔ EXCEPT ON `RECOVERED`: that token IS the class and the
    # sweep acts on it, so a suffix would corrupt it — the class describes the LIVE head, which is the
    # head the rail will read, so the polarity is safe. Every other verdict carries the disclosure.
    live = head_sha(repo, pr)
    sha = live or args.head
    if not sha:
        return "READ-FAILED:empty surface and the head could not be read"
    moved = ""
    if args.head and live and live != args.head:
        moved = f" (head moved since this cycle read it: saw {args.head[:12]}, now {live[:12]})"

    # ── 2. THE AUTHORITY TELLS "EMPTY" FROM "BLIND" ──────────────────────────────────────────────
    arows, total, areason = authority(repo, sha)
    if arows is None:
        return f"READ-FAILED:authority unreadable at {sha[:12]} ({areason}){moved}"
    if total > 0:
        if len(arows) != total:
            # A TRUNCATED surface is not a class (#2704): never classify from part of the evidence.
            return (f"READ-FAILED:authority truncated at {sha[:12]} "
                    f"({len(arows)} of {total} runs){moved}")
        # The controller's read is blind, the authority is not: use the working read.
        label = classify(arows, req, rgate)
        if not graded(label):
            return f"READ-FAILED:the authority answered but could not be graded ({label}){moved}"
        return "RECOVERED:" + label

    # ── 3. THE SURFACE IS GENUINELY ABSENT AT THIS HEAD ──────────────────────────────────────────
    runs, rreason = runs_at(repo, sha)
    if runs is None:
        return f"READ-FAILED:runs unreadable at {sha[:12]} ({rreason}){moved}"
    owner = args.repair_owner if args.repair_owner is not None else repair_owner(args.repo_dir)
    if not owner:
        owner_text = "this repo declares no repair for it"
    else:
        owner_text = f"{owner} owns the re-trigger"
    wait_cycles = 2 * args.attempt_bound
    inflight = [r for r in runs if str(r.get("status") or "").lower() in INFLIGHT]
    # The bound, computed BEFORE any branch: a repo whose repair exists gets twice as long, because a
    # repair that re-runs CI at the SAME sha (close/reopen, re-run) can still make the surface report.
    # ⛔ AND A HEAD WITH A RUN STILL IN FLIGHT GETS LONGER STILL (review P2, agent-infra#2719): the
    # cycle bound exists to end a repair that keeps STARTING fresh runs, but expiring it while a run is
    # demonstrably executing published "nothing available can produce one" — a FALSE claim — and parked
    # a head whose run then could never be read (the park guard runs before the check read). So the
    # in-flight case buys one more wait window before it can be called a dead end.
    terminal_at = (args.attempt_bound if not owner else (2 * args.attempt_bound)) + (
        wait_cycles if inflight else 0)
    # ⛔ THE COUNTER IS TAKEN BEFORE THE WAIT, NOT AFTER (review P2, agent-infra#2719). The WAIT branch
    # returned before `bump()`, so a head whose repair kept creating FRESH runs (a re-run every few
    # minutes keeps the newest run under the age bound) read WAIT for ever with no counter — the
    # unbounded re-read this arm exists to remove, wearing the reassuring name. Now every cycle at this
    # head advances the counter, and the WAIT is allowed only while the bound is unspent.
    n, counted = bump(args.state_dir, pr, sha)
    if inflight:
        # ANY in-flight run past the age bound is a wedge — checking only the NEWEST one (the API is
        # newest-first) let a brand-new re-run mask a run stuck since yesterday.
        aged = [(run_age_min(r), r) for r in inflight]
        old = [(a, r) for a, r in aged if a is not None and a > args.inflight_bound_min]
        r = (old[0][1] if old else inflight[0])
        age = run_age_min(r)
        # ⛔ A WAIT NEEDS A BOUND TOO (review P1, agent-infra#2719). A run stuck in `queued`/`waiting`
        # — approval-gated, a full concurrency group, a billing block — never leaves INFLIGHT, so an
        # unbounded WAIT would re-read this PR for ever under a reassuring name: the exact defect this
        # arm removes. Past the bound it is a WEDGE, and the wedge is the repair's work, not a wait's.
        # ⛔ AN UNREADABLE AGE IS NOT "YOUNG" (review P2, agent-infra#2719). Absence of the stamp used to
        # take the WAIT branch for ever, which is the unbounded wait this bound exists to end. Absence
        # of evidence takes the COUNTED path, which still needs `attempt_bound` cycles before anything
        # terminal can happen.
        # ⛔ AN INERT COUNTER MUST NOT WAIT FOR EVER (review P3, agent-infra#2719): with `state/`
        # unwritable, `n` is 1 on every cycle, so `n <= wait_cycles` is permanently true and the WAIT
        # branch returned before the INERT disclosure — measured, 8 consecutive WAITs with no name for
        # the broken bound. The WAIT is therefore allowed only when the counter actually advanced.
        if (counted and not old and n <= wait_cycles
                and (age is None or age <= args.inflight_bound_min)):
            return (
                f"WAIT:{moved} a run is executing and has produced no check-run yet "
                f"({r.get('name')} run {r.get('id')} {r.get('status')}"
                + (f", {age:.0f}m old)" if age is not None else ", age unreadable)")
            )
        # fall through: the in-flight run is past the bound and is not going to report by itself
        if old:
            inflight_note = (
                f" (run {r.get('id')} {r.get('status')} for {age:.0f}m — past the "
                f"{args.inflight_bound_min:g}m bound)" if age is not None else
                f" (run {r.get('id')} {r.get('status')}, age unreadable — counted as past the "
                f"{args.inflight_bound_min:g}m bound rather than assumed young)"
            )
        else:
            inflight_note = (
                f" (a run at this head is still {r.get('status')} after {n} cycles — a repair that "
                f"keeps starting a fresh run cannot make the age bound fire, so the CYCLES bound "
                f"({wait_cycles}) is what ends the wait)"
            )
    else:
        inflight_note = ""

    evidence = (
        f"check-runs at {sha[:12]}: 0 (the authority) · workflow runs at the head: {len(runs)}"
        + (f" ({', '.join(str(r.get('name')) + '/' + str(r.get('status')) + '/' + str(r.get('conclusion')) for r in runs[:4])})" if runs else " (none)")
        + f" · consecutive cycles at this head: {n}/{terminal_at}"
    )
    # ── 4. A BOUND THAT CANNOT BE COUNTED MUST NEVER READ AS ONE THAT IS ADVANCING ──────────────
    if not counted:
        return (
            f"DEFERRED-REPAIR:{moved} {owner_text}; the bound is INERT (state dir unwritable, so the "
            f"absence can never outlive it) — {evidence}{inflight_note}"
        )

    # ── 5. THE TERMINAL VERDICT — ONLY AT THE BOUND ─────────────────────────────────────────────
    # ⛔ THE BOUND IS NEVER SHORT-CIRCUITED (review P0, agent-infra#2719). "This repo declares no
    # repair" changes the DETAIL, never the bound: a head pushed 2–9 minutes ago legitimately has zero
    # check-runs and zero runs (the measured NOT-YET cohort), and going terminal on cycle 1 would
    # publish a false claim and park a head that was about to go green.
    # ⛔ AND A PARK FIGHTS A REPAIR THAT DOES NOT MOVE THE HEAD (review P2, agent-infra#2719). The
    # sweep's park guard `continue`s BEFORE the check read, so a close/reopen or a re-run — both of
    # which put check-runs at the SAME sha — would be invisible for ever. So a head whose repair owner
    # exists is NOT parked at the first bound: it is re-checked each cycle up to TWICE the bound, and
    # only then does it become a named dead end (whose posted verdict names the lift).
    if n >= terminal_at:
        # ⛔ THE DETAIL MUST NOT LIE ABOUT WHAT IS RUNNING (review P2, agent-infra#2719). "no workflow
        # run can report a check" was emitted whenever `runs` was non-empty — including for a run that
        # was still `in_progress` and far under the wedge bound. Each of the three states now says what
        # it is, because this sentence is published verbatim on the PR.
        if inflight:
            _st = str(inflight[0].get("status") or "")
            _how = "is still executing" if _st == "in_progress" else f"is still {_st} (not started)"
            detail = (f"a workflow run at this head {_how} and has not produced a check-run "
                      f"after {n} cycles (run {inflight[0].get('id')} {_st})")
        elif runs:
            detail = ("a workflow run at this head completed without producing a check-run")
        else:
            detail = "no workflow run exists at this head"
        detail += f"; {owner_text} (head {sha[:12]})"
        # ⛔ THE DIVERGENCE GOES FIRST, NOT LAST: the detail is capped (one line, ~220 chars) and a
        # disclosure appended after the evidence was TRUNCATED AWAY in the first run of this suite —
        # a note that only survives when the message happens to be short is not a disclosure.
        detail = f"{moved} {detail}" if moved else detail
        post = "off"
        if args.post:
            if already_posted(args.state_dir, pr, sha):
                post = "already-posted"
            elif post_unresolvable(repo, pr, sha, detail, evidence, inflight=bool(inflight)):
                # The verdict IS published; the marker only records that. If the marker cannot be
                # written we must still not publish it again, so the sweep parks on this token.
                post = "ok" if mark_posted(args.state_dir, pr, sha) else "ok-nomarker"
                prune_heads(args.state_dir, pr, sha)
            else:
                # ⛔ A FAILED POST IS BOUNDED TOO (review P2, agent-infra#2719). `[post=failed]` refuses
                # to park (the park would make the miss permanent and silent), but without a counter the
                # RETRY was the unbounded loop: measured 8 comment attempts and 172 gh calls over 9
                # cycles at one head. After `attempt_bound` failed attempts the head is parked ANYWAY,
                # with the failure recorded in `[post=failed-parked]` — the arm then retries the comment
                # once more from the log on the next cycle that is not parked... and it names the
                # failure instead of spinning.
                tries, counted_tries = post_attempts(args.state_dir, pr, sha)
                if not counted_tries:
                    # Cannot count the attempts, so cannot bound them. Name it and let the sweep park
                    # (a named dead end beats an unbounded comment loop; the state dir is the fault).
                    post = "failed-inert"
                else:
                    post = "failed" if tries < args.attempt_bound else "failed-parked"
        # ⛔ THE MARKER DECIDES A BRANCH, SO IT CANNOT LIVE AT THE TAIL (review P2, agent-infra#2719).
        # `main()` truncates the detail, and the sweep parks-or-retries by LITERALLY matching
        # `[post=failed…]` on the truncated string. At the tail a long detail (a repair owner + an
        # in-flight run + a moved head = 310 chars against a 320 cap) cut the marker, all three literal
        # branches fell through to the generic park, and a head whose verdict was never published was
        # parked for ever — measured end to end. First, like the moved-head disclosure.
        return f"UNRESOLVABLE:[post={post}] {detail}{inflight_note}"
    if owner:
        extra = (f"; the repair does not move the head, so this is re-read until "
                 f"{terminal_at}/{args.attempt_bound} cycles before it is called a dead end")
    else:
        extra = ""
    return f"DEFERRED-REPAIR:{moved} {owner_text}; {evidence}{inflight_note}{extra}"


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--repo", required=True, help="owner/name")
    ap.add_argument("--pr", required=True, type=int)
    ap.add_argument("--head", default="",
                    help="the head this cycle observed (a hint only — the arm re-reads the live head)")
    ap.add_argument("--state-dir", required=True)
    ap.add_argument("--repo-dir", default="", help="the target checkout (auto-detects its repair)")
    ap.add_argument("--repair-owner", default=None, help="override the repo's declared repair owner")
    ap.add_argument("--attempt-bound", type=int, default=3)
    ap.add_argument("--inflight-bound-min", type=float, default=40.0,
                    help="a run still non-completed after this long is a wedge, not a wait")
    ap.add_argument("--retries", type=int, default=2)
    ap.add_argument("--backoff", type=float, default=2.0)
    ap.add_argument("--post", action="store_true", help="post a terminal verdict on the PR, once")
    ap.add_argument("--breaker", default="", help="cycle-wide transport breaker file (emptied per cycle)")
    ap.add_argument("--breaker-ttl-min", type=float, default=20.0,
                    help="a breaker older than this is stale and is ignored")
    a = ap.parse_args(argv)
    if "/" not in a.repo:
        die(f"--repo must be owner/name (got {a.repo!r})")
    token = resolve(a)
    # ONE line, TAB-separated: the ledger splits on the tab and refuses a forged row.
    tok, _, detail = token.partition(":")
    print(f"{tok}\t{one_line(detail, 320)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
