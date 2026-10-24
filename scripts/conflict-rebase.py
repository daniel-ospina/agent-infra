#!/usr/bin/env python3
"""conflict-rebase — keep a CONFLICTING PR mergeable WITHOUT a lane per PR.

THE DEFECT THIS CLOSES (agent-infra#2698). The queue is not short of labour, it is
on a treadmill. Measured 2026-10-24 on `daniel-ospina/agent-infra`: 72 open PRs,
**48 CONFLICTING**, and the count went 41 -> 33 -> 48 while **17 PRs merged** the
same day. Every merge to `main` re-conflicts a batch of the rest, and `main` has
`required_status_checks.strict: true` (the ONLY required context is
`pipeline-compliance`), so a PR that goes behind is pushed to update, and updating
is where the conflicts are. A crew that rebases and walks away produces branches
that conflict again before they land — which is why the number keeps coming back
and why one lane per PR cannot outrun it.

So this is a *mechanism*, not a lane: each run it rebases the PRs whose ONLY
blocker is CONFLICTING, and refuses the rest.

WHAT IT MAY TOUCH. A PR is a candidate only when ALL of these hold:
  * `mergeable == CONFLICTING`      (not merely BEHIND — behind is not a conflict)
  * not a draft
  * not on the duplicate/contradictory deny list (--deny)
  * not already labelled `needs-human-conflict` (a previous refusal is respected)
  * not in per-PR backoff (see CAPS)
  * the head is older than --min-age-min (a lane that pushed 2 minutes ago is
    still on it; rebasing under it steals the head)
  * no live lane names its branch (`fleet-state.json`, local worktrees)
  * `git ls-remote` returns the SAME sha twice, --interval-s apart, and it is the
    PR's own head. A moving head means a peer is pushing -> SKIP. (The polite
    check. The ENFORCEMENT is `--force-with-lease=<branch>:<observed-sha>` on the
    push: if anything moved after this read, git refuses and the branch is
    untouched. Two mechanisms, because the 30-second window is real.)

WHAT IT MUST NEVER DO — THE REFUSAL IS THE DELIVERABLE. It never resolves a
content conflict. A conflict means two intents disagree; taking one side is how a
bot lands a compiling-but-wrong tree, and the resulting commit exists in NEITHER
parent (the same shape #1276 describes as an ungated write path). So the rebase is
attempted in a scratch worktree, and if ANY commit conflicts the rebase is
aborted, the PR gets the `needs-human-conflict` label plus a comment naming the
commit, and **nothing is pushed**. `rerere` is explicitly DISABLED on the replay
(`-c rerere.enabled=false -c rerere.autoUpdate=false --no-rerere-autoupdate`)
because a rerere resolution is a *recorded content decision* replayed by a robot —
and relying on the ambient config being off is not a guarantee, it is a hope.

CONTENT PRESERVATION, CHECKED — AND WHAT "CHECKED" CANNOT MEAN. A conflict-free
replay applies patches and makes no content decision, so it cannot invent content;
the property worth enforcing is COMMIT ECONOMY: the rebased branch may carry FEWER
commits than `git cherry` says are not already upstream (a commit whose change is
already in `main` becomes empty and is dropped — the desirable shrink) and must never
carry MORE (refused as `rebase-changed-content`). Patch-id equality is deliberately
NOT used: it false-refused a legitimate rebase (#2639) because a replayed commit
sits in new context, so its hunks — and therefore its patch-id — differ although the
change is identical. "Is what would merge still what was reviewed" is answered AFTER
the push, by the gate's own diff hash, which is the only authority for it.

A RECORD IS BOUND TO A HEAD (and this bot must not launder that). The fleet's
review record is a local file (`~/.pi/agent/reviews/…json`) bound to `head_sha`
AND `diff_sha256`; the merge gate (extensions/review-enforcer) already fails
closed when the head moved, EXCEPT when the reviewed DIFF is byte-identical — that
is a recorded decision (the #2982 carry arm), not a loophole, and deleting a
record the gate can still verify would send an unchanged diff back through a paid
review. So after a push this bot:
  * recomputes the PR's diff hash with `record-review.sh --print-diff-hash`
    (READ-ONLY, the same implementation the gate uses) and
  * if it is UNCHANGED, keeps the record and says so in the comment, naming the
    hash — the attestation is still true of the same diff;
  * if it CHANGED, moves the record aside (`…json.superseded-<oldhead>`) and says
    so — a record must never outlive the diff it attests;
  * removes any label that asserts a review (`reviewed`, `attested`, …);
  * never edits the PR body (#1224) — a comment is not a body edit.
New commits mean new checks; the comment always states the new head so no reader
can mistake it for the reviewed one.

CAPS — NO FORCE-PUSH STORM. At most --max PRs per run (default 3), never the same
branch twice in a run, per-PR backoff (a refusal doubles: 1d, 2d, 4d … capped at
14d; a success rests 6h), one run at a time (flock), and nothing at all when a
global brake file exists.

WHERE IT RUNS — the cell, not a GitHub Action, and the deciding constraint is what
a credential may do:
  1. GITHUB_TOKEN pushes do NOT create new workflow runs (GitHub documents the
     exception as `workflow_dispatch`/`repository_dispatch`), so a bot-rebased head
     would carry NO check runs. `scripts/admin-merge.sh` precondition 1 requires
     the head to have been TESTED, so every PR this bot touched would become
     unrunnable by the rail — strictly worse than leaving it conflicted.
  2. The record store is a LOCAL file store. A runner cannot invalidate it, so an
     Actions bot would leave a record attesting a diff it never saw.
The cell's own credential (`gho_`, push+admin, verified) pushes as the owner,
triggers `pull_request: synchronize`, and can see the record store.

MERGE QUEUE (checked, not assumed): NOT available for these repos and it would not
have dissolved the class anyway. docs.github.com (Managing a merge queue) scopes it
to "any public repository owned by an ORGANIZATION, or private repositories owned by
organizations using GitHub Enterprise Cloud"; `daniel-ospina` is a **User**
(`gh api users/daniel-ospina --jq .type` -> User), `mergeQueue` is null, there are
zero rulesets and the branch protection carries no merge-queue setting. And even
where it exists, a merge queue does not resolve a CONTENT conflict — it removes the
PR from the queue. What it removes is the *up-to-date* cost, i.e. the `strict: true`
half of this treadmill; that is a capability finding recorded on the issue.

USAGE
  scripts/conflict-rebase.py --dry-run              # the whole census, pushes nothing
  scripts/conflict-rebase.py --max 3                # the real thing
  scripts/conflict-rebase.py --pr 2599 --dry-run    # one PR, explained
EXIT  0 = a clean pass (including "nothing to do"); 2 = a surface could not be
      read (a failed read is never reported as "nothing to do"); 3 = usage.
"""
from __future__ import annotations

import argparse
import fcntl
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HOME = Path(os.environ.get("HOME") or "~").expanduser()
STATE = Path(os.environ.get("CONFLICT_REBASE_STATE") or HOME / ".pi/agent/state/conflict-rebase")
REVIEWS = Path(os.environ.get("CONFLICT_REBASE_REVIEWS") or HOME / ".pi/agent/reviews")
RECORD_SH = os.environ.get("CONFLICT_REBASE_RECORD_SH") or str(HOME / ".pi/agent/scripts/record-review.sh")
# The origin template exists so the suite can point the scratch repo at a LOCAL
# bare repo. It is a test seam, not a deployment knob: the default is the repo URL.
ORIGIN_TMPL = os.environ.get("CONFLICT_REBASE_ORIGIN") or "https://github.com/{repo}.git"
FLEET_STATE = Path(os.environ.get("CONFLICT_REBASE_FLEET_STATE") or HOME / ".pi/agent/state/fleet-state.json")

LABEL = "needs-human-conflict"
# Labels that assert a review. There are none on this repo today (checked: 39
# labels, no reviewed/attested); the list exists so that the day one is added it
# cannot be left standing over a bot-moved head.
REVIEW_ASSERTING_LABELS = ("reviewed", "attested", "clean-review", "reviewed-clean")

# The duplicate/contradictory PRs: work on these is wasted or harmful, so the bot
# never touches them (agent-infra#2698 brief).
DEFAULT_DENY = (2172, 2314, 2317, 2241, 2247, 2237, 2336, 2597, 2608, 2551, 2430)

BACKOFF_REFUSE_BASE = 24 * 3600
BACKOFF_REFUSE_CAP = 14 * 24 * 3600
BACKOFF_OK = 6 * 3600


class Unreadable(Exception):
    """A surface could not be read. NEVER the same as an empty surface."""


def log(msg: str) -> None:
    # Diagnostics go to STDERR: stdout carries the machine-readable report (--json),
    # and a caller that parses stdout must not have to skip log lines.
    print(f"[conflict-rebase] {msg}", file=sys.stderr, flush=True)


def run(cmd: list[str], **kw) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def git(repo: Path | str, *args: str, check: bool = True, stdin: str | None = None) -> str:
    p = run(["git", "-C", str(repo), *args], input=stdin)
    if check and p.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)} failed ({p.returncode}): {p.stderr.strip()[:400]}")
    return p.stdout


def gh(*args: str, check: bool = True) -> str:
    p = run(["gh", *args])
    if check and p.returncode != 0:
        raise Unreadable(f"gh {' '.join(args[:3])}… failed ({p.returncode}): {p.stderr.strip()[:300]}")
    return p.stdout


# ─────────────────────────── state ────────────────────────────────────────────
def state_path(name: str) -> Path:
    STATE.mkdir(parents=True, exist_ok=True)
    return STATE / name


def backoff_get(pr: int) -> float:
    f = state_path(f"backoff-{pr}.json")
    try:
        d = json.loads(f.read_text())
    except (OSError, ValueError):
        return 0.0
    try:
        return float(d.get("next_at") or 0.0)
    except (TypeError, ValueError):
        return 0.0


def backoff_set(pr: int, seconds: float, reason: str, strikes: int) -> None:
    f = state_path(f"backoff-{pr}.json")
    f.write_text(
        json.dumps(
            {"pr": pr, "next_at": time.time() + seconds, "reason": reason, "strikes": strikes},
            indent=1,
        )
        + "\n"
    )


def strikes_get(pr: int) -> int:
    try:
        return int(json.loads(state_path(f"backoff-{pr}.json").read_text()).get("strikes") or 0)
    except (OSError, ValueError, TypeError):
        return 0


# ─────────────────────────── live lane / head stability ───────────────────────
def worktree_states(checkout: str) -> list[tuple[str, str, str]]:
    """(path, branch, head_sha) for every worktree of `checkout`. Raises on failure.

    ⛔ A DETACHED WORKTREE HAS NO BRANCH, AND THAT IS EXACTLY HOW THE SIBLING LANE
    HOLDS A PR (`/tmp/rcwt/2027` — one directory per PR, detached). A branch-only
    test therefore reported "no live lane" for the PR the conflict lane was working
    at that moment. So the SHA counts too, and so does a directory named for the PR.
    A failed read RAISES: "no worktrees" is the one interpretation that licenses a push.
    """
    out = run(["git", "-C", checkout, "worktree", "list", "--porcelain"])
    if out.returncode != 0:
        raise Unreadable(f"git worktree list failed in {checkout}: {out.stderr.strip()[:200]}")
    states, path, branch, sha = [], "", "", ""
    for line in out.stdout.splitlines() + [""]:
        if line.startswith("worktree "):
            path, branch, sha = line.split(" ", 1)[1], "", ""
        elif line.startswith("branch "):
            branch = line.split(" ", 1)[1].replace("refs/heads/", "")
        elif line.startswith("HEAD "):
            sha = line.split(" ", 1)[1]
        elif not line.strip() and path:
            states.append((path, branch, sha))
            path = ""
    return states


def remote_claims(scratch: Path) -> list[str]:
    """Every `refs/claims/*` ref, in ONE call — the fleet's designed 'a lane holds
    this' signal (claims.sh: a ref-create IS the CAS). Raises on a failed read."""
    out = run(["git", "-C", str(scratch), "ls-remote", "origin", "refs/claims/*"])
    if out.returncode != 0:
        raise Unreadable(f"refs/claims unreadable: {out.stderr.strip()[:200]}")
    return [ln.split("\t")[-1].strip() for ln in out.stdout.splitlines() if ln.strip()]


def branch_has_live_lane(pr: dict, worktrees: list[tuple[str, str, str]], claims: list[str],
                         repo: str = "") -> str | None:
    """Return a human reason when another lane is (or may be) on this PR.

    ⛔ THE THREE SHAPES THAT ACTUALLY OCCUR, each of which this arm missed at first:
    the fleet board reports `branch: "(detached)"` for most lanes (so a branch-only
    match is structurally unable to fire); lane worktrees are named for WORKSPACES
    (`ws_…`), not PR numbers (so a name-shaped match misses them); and a fork PR's
    branch name can also exist in `origin` (so a fork must never reach the push).
    """
    branch = pr["headRefName"]
    head = str(pr.get("headRefOid") or "")
    try:
        fleet = json.loads(FLEET_STATE.read_text())
    except FileNotFoundError:
        fleet = None
    except ValueError as e:
        # A HALF-WRITTEN fleet-state is not "nobody is on this PR" — the orchestrator
        # rewrites that file every pass.
        raise Unreadable(f"fleet-state unreadable: {e}") from e
    except OSError as e:
        # Permission/IO errors are NOT absence. Only absence is absence.
        raise Unreadable(f"fleet-state unreadable: {e}") from e
    if isinstance(fleet, dict):
        board_repo = str(fleet.get("repo") or "")
        if board_repo and repo and board_repo != repo:
            # The board is a per-CELL snapshot of ONE repo; a board for another repo
            # says nothing about this one. Ignored, and said out loud.
            log(f"fleet-state speaks for {board_repo}, not {repo} — board arm ignored")
            fleet = None
    if isinstance(fleet, dict):
        lanes = fleet.get("lanes") or []
        if not isinstance(lanes, list):
            raise Unreadable("fleet-state lanes is not a list")
        for lane in lanes:
            if not isinstance(lane, dict):
                raise Unreadable("fleet-state carries a non-object lane entry")
            ident = lane.get("identity") if isinstance(lane.get("identity"), dict) else {}
            lb = str(ident.get("branch") or "")
            ls = str(ident.get("head_sha") or "")
            who = ident.get("lane") or ident.get("workspace") or "?"
            if lb and lb not in ("(detached)", "HEAD") and lb == branch:
                return f"fleet-state lane {who}"
            if head and ls and ls == head:
                return f"fleet-state lane {who} sits at this PR's head (detached)"
    n = str(pr["number"])
    for path, wt_branch, wt_sha in worktrees:
        base = Path(path).name
        if base.isdigit() and base == n:
            return f"worktree {path} is named for PR #{n}"
        if wt_branch and wt_branch == branch:
            return f"worktree {path} has the branch checked out"
        # ⛔ SHA ALONE, whatever the directory is called: a worktree detached at exactly
        # this commit IS a lane on it.
        if head and wt_sha == head:
            return f"worktree {path} sits at this PR's head (detached)"
    for ref in claims:
        tail = ref.rsplit("/", 1)[-1]
        if tail == f"pr-{n}" or tail.startswith(f"{n}-"):
            return f"held by the claim registry ({ref})"
    return None


def ls_remote(scratch: Path, ref: str) -> str:
    """The remote sha for `ref`, retried once — or raise.

    ⛔ AN EMPTY READ IS NOT "THE BRANCH MOVED". Measured on #2613 (2026-10-24): the
    second `ls-remote` of the stability window came back EMPTY on a transient
    network failure and the run reported `peer-pushing: head moved … -> ` — a
    read failure wearing the costume of a peer push. Both are reasons to skip, so
    nothing unsafe happened, but the RECORD was wrong and would have sent an
    operator hunting a lane that does not exist. Retry, then say UNREADABLE.
    """
    last = ""
    for _ in range(2):
        out = run(["git", "-C", str(scratch), "ls-remote", "origin", ref])
        if out.returncode == 0 and out.stdout.strip():
            return out.stdout.split()[0]
        last = (out.stderr or "").strip()[:200]
    raise Unreadable(f"ls-remote {ref} returned nothing ({last or 'empty output'})")


# ─────────────────────────── content checks ───────────────────────────────────
def cherry_state(repo: Path, upstream: str, head: str) -> tuple[int, int]:
    """(kept, already_upstream) per `git cherry` — patch equivalence, not identity.

    ⛔ `check=True`: this runs AFTER the fetch, so a failure here is a real surface
    failure. Read with `check=False` it returned 0 lines on error, which became
    `Refused("nothing-left")` — a false statement about the branch (0 READ, not 0
    landed) plus a 6-hour backoff that hid the PR.
    """
    out = git(repo, "cherry", upstream, head)
    kept = sum(1 for ln in out.splitlines() if ln.startswith("+ "))
    dropped = sum(1 for ln in out.splitlines() if ln.startswith("- "))
    return kept, dropped


def diff_hash(pr: int, repo: str) -> tuple[str, str]:
    """(status, hash) via the gate's OWN implementation. READ-ONLY (#1351)."""
    if not os.path.exists(RECORD_SH):
        return "unavailable", ""
    p = run(["bash", RECORD_SH, "--print-diff-hash", str(pr), repo])
    if p.returncode != 0 or not p.stdout.strip():
        return "unavailable", ""
    parts = p.stdout.strip().split("\t")
    if len(parts) != 2 or parts[0] != "ok":
        return (parts[0] if parts else "unavailable"), ""
    return "ok", parts[1]


# ─────────────────────────── record integrity ─────────────────────────────────
def record_candidates(pr: int, repo: str) -> list[Path]:
    owner, _, name = repo.partition("/")
    out = []
    for key in (f"{owner}-{name}", repo):
        out.append(REVIEWS / f"{key}-{pr}.json")
    out.append(REVIEWS / f"{pr}.json")
    return out


def _record_for_this_repo(f: Path, repo: str) -> dict | None:
    """The parsed record, or None when it is not usable for THIS repo.

    ⛔ A LEGACY `<pr>.json` IS SHARED ACROSS REPOS (the #426 collision: a stale record
    from another repo sat in `441.json`). Acting on one would either rename ANOTHER
    repo's attestation to `.superseded-<head>` or report "the existing attestation still
    describes what would merge" about a record that does not apply. The enforcer treats
    a repo-mismatched record as inert; so does this.
    """
    try:
        rec = json.loads(f.read_text())
    except (OSError, ValueError):
        return None
    # ⛔ VALID JSON IS NOT NECESSARILY A RECORD. `[]`, `"text"`, `123` and `null` all
    # parse and then raise AttributeError on `.get` — which escaped as a traceback AFTER
    # the push had happened, losing the record handling and the comment.
    if not isinstance(rec, dict):
        return None
    rec_repo = str(rec.get("repo") or "")
    if rec_repo and repo and rec_repo != repo:
        return None
    return rec


def _json_load(f: Path):
    try:
        return json.loads(f.read_text())
    except (OSError, ValueError):
        return None


def _json_parses(f: Path) -> bool:
    try:
        json.loads(f.read_text())
    except (OSError, ValueError):
        return False
    return True


def record_state(pr: int, repo: str, new_diff: str) -> str:
    """Do not let a record outlive the diff it attests. Returns what it did.

    EVERY candidate is inspected (not just the first): a stale legacy `<pr>.json` from
    another repo must not shadow this repo's record — and must not be renamed either.
    """
    found, kept, renamed = False, "", []
    for f in record_candidates(pr, repo):
        if not f.exists():
            continue
        rec = _record_for_this_repo(f, repo)
        if rec is None:
            # ⛔ TWO DIFFERENT ANOMALIES, TWO DIFFERENT ANSWERS (#2698 review, P2). A
            # record for ANOTHER repo is inert to the merge gate, so this head is NOT
            # unreviewed and the comment must not say it is. Only an unparseable object
            # at the canonical path is UNREADABLE. The old `if f.exists()` re-test here
            # was always true (`:409` already proved it) so the log arm was dead code
            # and a foreign record produced a comment with two false claims.
            if not (_json_parses(f) and isinstance(_json_load(f), dict)):
                return f"UNREADABLE record at {f.name} — parses as no record; treat this head as UNREVIEWED"
            log(f"#{pr} ignoring {f.name}: a record for another repo, inert to this gate")
            continue
        found = True
        rec_head = str(rec.get("head_sha") or "?")
        rec_diff = str(rec.get("diff_sha256") or "")
        if not new_diff:
            # The diff could not be read (head never became visible). Say UNAVAILABLE —
            # "the record attests a different diff" would be a claim nobody measured.
            aside = f.with_name(f.name + f".superseded-{rec_head[:12]}")
            try:
                f.rename(aside)
            except OSError as e:  # pragma: no cover
                raise Unreadable(f"record store ({e})") from e
            return (f"superseded-unverified: the diff could not be read at this head, so the record "
                    f"bound to {rec_head[:12]} was moved aside UNVERIFIED")
        if rec_diff and new_diff == rec_diff:
            kept = f"kept: diff unchanged ({new_diff[:12]}), record at {rec_head[:12]} still attests it"
            continue
        aside = f.with_name(f.name + f".superseded-{rec_head[:12]}")
        try:
            f.rename(aside)
        except OSError as e:  # pragma: no cover - disk state, not logic
            raise Unreadable(f"record store ({e}) — the record could not be moved aside") from e
        renamed.append(f"{rec_diff[:12] or '?'} -> {new_diff[:12] or '?'} at {rec_head[:12]}")
    if renamed:
        return f"superseded: diff changed ({'; '.join(renamed)}), record moved aside"
    if kept:
        return kept
    return "none: no review record for this repo existed"


def label_names(pr: int, repo: str) -> list[str]:
    out = gh("pr", "view", str(pr), "--repo", repo, "--json", "labels")
    try:
        return [l["name"] for l in (json.loads(out).get("labels") or [])]
    except (ValueError, KeyError) as e:
        raise Unreadable(f"labels unreadable: {e}") from e


def strip_review_labels(pr: int, repo: str) -> list[str]:
    present = label_names(pr, repo)
    drop = [n for n in present if n in REVIEW_ASSERTING_LABELS]
    for n in drop:
        # ⛔ NO `check=False` HERE. A review-asserting label that survives a superseded
        # record is exactly what REVIEW_ASSERTING_LABELS exists to prevent, and
        # ignoring the failure made that silent. It raises -> the pass reports
        # UNREADABLE and the post-push state is recorded as INCOMPLETE.
        gh("pr", "edit", str(pr), "--repo", repo, "--remove-label", n)
    return drop


def add_label(pr: int, repo: str, name: str) -> None:
    # Creating the label may legitimately fail (it may already exist); APPLYING it may
    # not — if the add fails, the refusal comment's instructions are a lie and the PR
    # hides behind a backoff, so it must surface.
    gh("label", "create", name, "--repo", repo, "--force",
       "--description", "A rebase conflicts on CONTENT — the bot refused; a human decides",
       "--color", "B60205", check=False)
    gh("pr", "edit", str(pr), "--repo", repo, "--add-label", name)


def comment(pr: int, repo: str, body: str) -> None:
    with tempfile.NamedTemporaryFile("w", suffix=".md", delete=False) as fh:
        fh.write(body)
        path = fh.name
    try:
        gh("pr", "comment", str(pr), "--repo", repo, "--body-file", path)
    finally:
        try:
            os.unlink(path)
        except OSError:
            pass


# ─────────────────────────── candidates ───────────────────────────────────────
def list_open_prs(repo: str) -> list[dict]:
    out = gh(
        "pr", "list", "--repo", repo, "--state", "open", "--limit", "500",
        "--json", "number,isDraft,mergeable,mergeStateStatus,headRefName,headRefOid,updatedAt,labels,title,baseRefName,statusCheckRollup,headRepository,isCrossRepository",
    )
    try:
        data = json.loads(out)
    except ValueError as e:
        raise Unreadable(f"PR list unreadable: {e}") from e
    if not isinstance(data, list):
        raise Unreadable("PR list was not a list")
    return data


GREEN_CONCLUSIONS = {"SUCCESS", "NEUTRAL", "SKIPPED"}


def required_contexts(repo: str) -> list[str]:
    """main's REQUIRED status contexts, read from the repo's own protection.

    ⛔ NOT hardcoded and NOT every check. "Otherwise landable" is the rail's
    question, and the rail's answer is the required set (agent-infra requires
    exactly ONE context, `pipeline-compliance`); a red NON-required check does not
    mean a fixer is coming, and treating it as one made the BEHIND arm inert while
    20 PRs sat behind (measured 2026-10-24).
    """
    out = run(["gh", "api", f"repos/{repo}/branches/main/protection", "--jq",
               ".required_status_checks.contexts // []"])
    if out.returncode != 0:
        raise Unreadable(f"branch protection unreadable: {out.stderr.strip()[:200]}")
    try:
        ctxs = json.loads(out.stdout or "[]")
    except ValueError as e:
        raise Unreadable(f"required contexts unreadable: {e}") from e
    return [str(c) for c in ctxs if str(c).strip()]


def checks_green(pr: dict, required: list[str]) -> bool:
    """Every REQUIRED context reported at this head, and its NEWEST attempt is green.

    ⛔ THE NEWEST ATTEMPT DECIDES — BUT ONLY WHEN "NEWEST" IS KNOWABLE (#2698 review,
    cycle 2, P2). Requiring EVERY attempt to be green made a PR retried once ineligible
    forever (a re-run ADDS a check-run and does not clear the red one), so the BEHIND arm
    was inert for exactly the population it serves. But a last-wins dict is only correct
    if the ordering is TOTAL: `statusCheckRollup` carries `startedAt`/`completedAt` on
    `CheckRun` and NOT on legacy `StatusContext` entries, so an ordinal of
    `startedAt or ""` makes the verdict a function of rollup ORDER for the legacy path —
    a newer red masked by an older green, i.e. a false green that force-pushes a rebase
    under a red required gate. The fleet has already paid for this once (objective.py
    records that with no database id "every check-run compared equal at 0 … the
    newest-attempt rule was silently defeated").

    So: order by timestamp where a timestamp exists; where it does not (a context whose
    attempts carry no ordering at all, or a tie on the newest timestamp with disagreeing
    conclusions) the answer is AMBIGUOUS and this FAILS CLOSED — every attempt at that
    context must be green. `statusCheckRollup` also carries no app slug, so two workflows
    publishing one job name are conflated — the rail's own stated residual, named here.
    """
    if not required:
        return False
    attempts: dict[str, list[tuple[str, str]]] = {}
    for c in pr.get("statusCheckRollup") or []:
        name = str(c.get("name") or c.get("context") or "")
        conclusion = str(c.get("conclusion") or c.get("state") or "").upper()
        when = str(c.get("startedAt") or c.get("completedAt") or "")
        attempts.setdefault(name, []).append((when, conclusion))
    for ctx in required:
        rows = attempts.get(ctx)
        if not rows:
            return False
        stamped = [(w, k) for w, k in rows if w]
        if len(stamped) == len(rows):
            newest = max(w for w, _ in stamped)
            top = {k for w, k in stamped if w == newest}
            # ⛔ A TIE IS AMBIGUOUS ONLY WHEN IT DISAGREES (#2698 review, cycle 3, P2).
            # Rejecting every tie made an all-green tie a FALSE RED — the arm went inert
            # for a legitimately green PR and the skip text blamed "a fixer who will move
            # it" when no fixer was needed. The contract above is "every attempt at an
            # ambiguous context must be green", and a green-only tie satisfies it.
            if not GREEN_CONCLUSIONS >= top:
                return False
            continue
        # At least one attempt cannot be ordered at all — the legacy-status shape.
        # Do not let list position decide; require agreement, which is fail-closed.
        if len({k for _, k in rows}) != 1 or not GREEN_CONCLUSIONS >= {k for _, k in rows}:
            return False
    return True


def clean_record_at_head(pr: int, repo: str, head: str) -> bool:
    for f in record_candidates(pr, repo):
        rec = _record_for_this_repo(f, repo)
        if rec is None:
            continue
        if str(rec.get("head_sha") or "") == head and str(rec.get("verdict") or "").startswith("clean"):
            return True
    return False


def too_young(p: dict, min_age_min: int) -> str | None:
    """Reason when the head is too fresh to touch — or when its age CANNOT be read.

    ⛔ `updatedAt` is the PR's edit time, not the head commit date, so a missing or
    unparsable value is NOT "old enough": that reading is how the age guard became a
    no-op (measured: a 20-second-old head was selected and force-pushed). Fail closed —
    the cost of skipping is one pass; the cost of taking a lane's head is its review.
    """
    if min_age_min <= 0:
        return None
    ts = p.get("updatedAt")
    if not ts:
        return "head age unreadable (updatedAt missing) — fail closed"
    try:
        from datetime import datetime, timezone

        when = datetime.fromisoformat(str(ts).replace("Z", "+00:00"))
        age = (datetime.now(timezone.utc) - when).total_seconds()
    except ValueError:
        return f"head age unreadable ({ts!r}) — fail closed"
    if age < min_age_min * 60:
        return f"head younger than {min_age_min}m (a lane may still be on it)"
    return None


def select(prs: list[dict], args, required: list[str]) -> tuple[list[dict], list[tuple[int, str]]]:
    chos, skipped = [], []
    deny = set(args.deny)
    repo = args.repo
    for p in sorted(prs, key=lambda x: x.get("updatedAt") or ""):
        n = p["number"]
        why = None
        if args.pr and n not in args.pr:
            continue
        # ⛔ EVERY CLASS-INDEPENDENT EXCLUSION RUNS FOR BOTH ARMS, FIRST. They were
        # previously woven into the elif chain AFTER the class test, and a `CONFLICTING`
        # PR took that arm's `pass` all the way past the deny/label/backoff/base/age
        # checks — dead code, proven by probe: a 20-second-old head and a PR targeting
        # `release-1.x` were both selected and force-pushed.
        if n in deny:
            why = "deny-list"
        elif p.get("isDraft"):
            why = "draft"
        elif LABEL in [l["name"] for l in p.get("labels") or []]:
            why = f"labelled {LABEL} (previous refusal)"
        elif backoff_get(n) > time.time():
            why = "backoff"
        elif p.get("isCrossRepository") or (
                (p.get("headRepository") or {}).get("nameWithOwner") not in (None, "", repo)):
            # ⛔ A FORK PR'S HEAD IS NOT `origin`'s BRANCH. `ls-remote <headRefName>` would
            # match origin's unrelated branch of the same name, and the push would move THAT
            # branch while the comment claims this PR's head moved. Absent fields mean
            # "unknown", which is not "foreign".
            why = f"head repo is not {repo} (fork PR) — its branch is not ours to push"
        elif (p.get("baseRefName") or "") != "main":
            # ⛔ A MISSING base is not `main` — same fail-open shape `too_young` closes
            # one line below.
            why = f"base {p.get('baseRefName') or '?'} (not main)"
        elif (young := too_young(p, args.min_age_min)):
            why = young
        elif (p.get("mergeable") or "").upper() == "CONFLICTING":
            pass
        elif args.include_behind and (p.get("mergeStateStatus") or "").upper() == "BEHIND":
            # The BEHIND arm: the rail's ONLY remaining blocker is staleness. It is
            # gated on the PR being otherwise landable — green AND already recorded at
            # THIS head — so a rebase cannot move a head out from under a live
            # reviewer, and it cannot disturb a branch that a fixer will push anyway.
            if not checks_green(p, required):
                why = "behind but not green (a fixer will move it; not ours to rebase)"
            elif args.operator_assert_idle:
                pass  # the operator asserted nobody is reviewing; the diff guard still holds
            elif not clean_record_at_head(n, args.repo, p.get("headRefOid") or ""):
                why = "behind but not recorded at this head (a reviewer owns it)"
        else:
            why = f"mergeable={p.get('mergeable')}"
        if why:
            skipped.append((n, why))
        else:
            chos.append(p)
    return chos, skipped


# ─────────────────────────── rebase ───────────────────────────────────────────
class Refused(Exception):
    def __init__(self, kind: str, detail: str):
        super().__init__(detail)
        self.kind = kind
        self.detail = detail


def scratch_repo(repo: str) -> Path:
    path = STATE / "scratch.git"
    url = ORIGIN_TMPL.format(repo=repo)
    if not (path / "HEAD").exists():
        path.parent.mkdir(parents=True, exist_ok=True)
        run(["git", "init", "--bare", str(path)])
        run(["git", "-C", str(path), "remote", "add", "origin", url])
    else:
        # Always re-point: the URL is derived, so a stale one (a moved repo, or a
        # test fixture) must never silently serve a different history.
        run(["git", "-C", str(path), "remote", "set-url", "origin", url])
    return path


def rebase_pr(scratch: Path, pr: dict, args) -> dict:
    """Do the whole safe thing for ONE PR. Raises Refused with a kind + detail.

    Any git/gh RuntimeError is translated to Unreadable at this boundary so the caller
    reports exit 2 rather than crashing with a traceback (the documented contract)."""
    try:
        return _rebase_pr(scratch, pr, args)
    except (Refused, Unreadable):
        raise
    except RuntimeError as e:
        raise Unreadable(str(e)) from e


def _rebase_pr(scratch: Path, pr: dict, args) -> dict:
    branch = pr["headRefName"]
    want = pr["headRefOid"]
    ref = f"refs/heads/{branch}"

    # 1. stability: the same head twice, and it is the PR's head.
    try:
        first = ls_remote(scratch, ref)
    except Unreadable as e:
        raise Refused("unreadable", str(e)) from e
    if first != want:
        raise Refused("head-moved", f"PR head {want[:12]} but origin has {first[:12]}")
    time.sleep(args.interval_s)
    try:
        second = ls_remote(scratch, ref)
    except Unreadable as e:
        raise Refused("unreadable", str(e)) from e
    if second != first:
        raise Refused("peer-pushing", f"head moved during the {args.interval_s}s window: {first[:12]} -> {second[:12]}")

    # 2. fetch exactly two refs into the scratch repo.
    git(scratch, "fetch", "--no-tags", "--prune", "origin",
        "+refs/heads/main:refs/remotes/origin/main", f"+{ref}:refs/remotes/origin/{branch}")
    base = git(scratch, "rev-parse", "refs/remotes/origin/main").strip()
    head = git(scratch, "rev-parse", f"refs/remotes/origin/{branch}").strip()
    if head != second:
        raise Refused("head-moved", f"fetched {head[:12]}, ls-remote said {second[:12]}")

    mb = git(scratch, "merge-base", base, head).strip()
    if mb == base:
        raise Refused("already-current", "merge-base is main's tip — nothing to replay")

    kept, dropped = cherry_state(scratch, base, head)
    if kept == 0:
        raise Refused("nothing-left", f"all {dropped} commit(s) are already patch-equivalent in main")

    # 3. the rebase, in a throwaway worktree of the scratch repo.
    wt = Path(tempfile.mkdtemp(prefix="cr-wt-"))
    shutil.rmtree(wt)
    try:
        git(scratch, "worktree", "add", "--detach", str(wt), head)
        rb = run(["git", "-c", "rerere.enabled=false", "-c", "rerere.autoUpdate=false",
                  "-c", "rebase.autoSquash=false", "-C", str(wt),
                  "rebase", "--no-rerere-autoupdate", "--onto", "refs/remotes/origin/main", mb])
        if rb.returncode != 0:
            # ⛔ A FAILED REPLAY IS NOT AUTOMATICALLY A CONTENT CONFLICT. Reporting
            # every non-zero exit as one labels someone's PR `needs-human-conflict`,
            # tells them to resolve a conflict that may not exist, and hides the real
            # fault (a signing hook, a full disk, an unreadable object) behind a
            # diagnosis the operator never sees. Classify on EVIDENCE: unmerged index
            # entries are a conflict; anything else is a replay FAILURE.
            # ⛔ A FAILED READ IS NOT "NO CONFLICT" (#2698 review, P2). Without this
            # check a git failure here reads as an empty unmerged set, so a REAL content
            # conflict is reported as `rebase-failed`, gets no label and no comment — the
            # deliverable never fires and the PR re-enters the queue every pass.
            ev = run(["git", "-C", str(wt), "diff", "--name-only", "--diff-filter=U"])
            if ev.returncode != 0:
                raise Unreadable(f"could not read the unmerged index: {ev.stderr.strip()[:300]}")
            unmerged = sorted({ln.split("\t")[-1] for ln in ev.stdout.splitlines() if ln.strip()})
            run(["git", "-C", str(wt), "rebase", "--abort"])
            blob = rb.stdout + rb.stderr
            if not unmerged:
                first = next((ln for ln in blob.splitlines() if ln.strip()), "no output")
                raise Refused("rebase-failed", f"the replay failed without a conflict: {first[:300]}")
            # The conflicting commit is the one the rebase stopped on; name it.
            m = re.search(r"could not apply ([0-9a-f]{7,40})", blob)
            stuck = m.group(1) if m else ""
            paths = unmerged[:5]
            raise Refused("content-conflict",
                          f"rebase stopped on {stuck or 'a commit'}; conflicting paths: {', '.join(paths) or 'unreported'}")
        new_head = git(wt, "rev-parse", "HEAD").strip()

        # 4. content preservation: NOTHING INVENTED, nothing silently lost.
        # ⛔ PATCH-ID EQUALITY IS THE WRONG TEST ACROSS A MOVED BASE (measured: it
        # false-refused #2639 with "2 patches appear in no original commit"). A
        # replayed commit sits in new context, so `git log -p` emits different
        # hunks and `git patch-id --stable` hashes differ although the change is
        # identical. The property that actually matters is COMMIT ECONOMY:
        #  * a conflict-free replay applies patches and makes NO content decision,
        #    so it cannot invent content — "invented" is not a thing to detect here;
        #  * a commit that becomes EMPTY (its change is already in main) IS dropped,
        #    which is the legitimate, desirable shrink — so the count may fall, and
        #    it may never rise.
        # The attestation question ("is what would merge still what was reviewed")
        # is answered AFTER the push by the gate's own diff hash, the only authority
        # for it (see record_state).
        new_count = int(git(scratch, "rev-list", "--count", f"{base}..{new_head}").strip() or 0)
        if new_count > kept:
            raise Refused("rebase-changed-content",
                          f"rebase carries {new_count} commit(s) but only {kept} were not already in main")
        if new_count == 0:
            raise Refused("nothing-left", "every commit became empty against main — nothing to re-land")
        return {"branch": branch, "old_head": head, "new_head": new_head, "base": base,
                "kept": kept, "dropped": dropped, "replayed": new_count, "wt": wt}
    finally:
        run(["git", "-C", str(scratch), "worktree", "remove", "--force", str(wt)])
        shutil.rmtree(wt, ignore_errors=True)


def push(scratch: Path, res: dict) -> None:
    """force-with-lease is the ENFORCEMENT of 'no peer pushed': it fails closed."""
    p = run(["git", "-C", str(scratch), "push",
             f"--force-with-lease=refs/heads/{res['branch']}:{res['old_head']}",
             "origin", f"{res['new_head']}:refs/heads/{res['branch']}"])
    if p.returncode != 0:
        raise Refused("lease-refused",
                      f"force-with-lease refused (a peer moved the branch): {p.stderr.strip()[:300]}")


def wait_mergeable(pr: int, repo: str, seconds: int = 30) -> str:
    deadline = time.time() + seconds
    last = "UNKNOWN"
    while time.time() < deadline:
        out = gh("pr", "view", str(pr), "--repo", repo, "--json", "mergeable,headRefOid")
        try:
            d = json.loads(out)
        except ValueError:
            return "UNKNOWN"
        last = (d.get("mergeable") or "UNKNOWN").upper()
        if last != "UNKNOWN":
            return last
        time.sleep(3)
    return last


def wait_head(pr: int, repo: str, want: str, seconds: int = 60) -> bool:
    """Poll until the PR's head is the sha we pushed.

    ⛔ THE DIFF HASH CARRIES NO HEAD. Reading it while the API still reports the OLD
    head compares the OLD diff against the record and yields a confident "the reviewed
    diff is unchanged" about a head nobody measured — a laundered attestation produced
    by a lag, not by a bug in the comparison. So the head is the precondition.
    """
    deadline = time.time() + seconds
    while time.time() < deadline:
        out = gh("pr", "view", str(pr), "--repo", repo, "--json", "headRefOid")
        try:
            if (json.loads(out).get("headRefOid") or "") == want:
                return True
        except ValueError:
            pass
        time.sleep(3)
    return False


# ─────────────────────────── main ─────────────────────────────────────────────
def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description="Rebase CONFLICTING PRs that are conflict-free; refuse the rest.")
    ap.add_argument("--repo", default=os.environ.get("GH_REPO") or "daniel-ospina/agent-infra")
    ap.add_argument("--dry-run", action="store_true", help="analyse everything, push/comment/label nothing")
    ap.add_argument("--max", type=int, default=3, help="PRs per run (default 3)")
    ap.add_argument("--pr", type=int, action="append", default=[], help="only these PR(s)")
    ap.add_argument("--deny", type=lambda s: tuple(int(x) for x in s.split(",") if x.strip()), default=DEFAULT_DENY)
    ap.add_argument("--interval-s", type=int, default=30, help="the ls-remote stability window (default 30s)")
    ap.add_argument("--checkout", default=os.environ.get("CONFLICT_REBASE_CHECKOUT") or "",
                    help="a local checkout to also inspect for a lane holding the branch (optional)")
    ap.add_argument("--include-behind", action="store_true",
                    help="ALSO rebase MERGEABLE+BEHIND PRs that are green AND recorded at their head "
                         "(the rail's only remaining blocker is staleness). Off by default: the "
                         "brief's class is CONFLICTING.")
    ap.add_argument("--min-age-min", type=int, default=15, help="skip PRs whose head is younger (default 15m)")
    ap.add_argument("--operator-assert-idle", action="store_true",
                    help="OPERATOR ASSERTION: skip the 'clean record at this head' condition of the "
                         "BEHIND arm, i.e. assert that no reviewer is working on the PR. The scheduled "
                         "mode NEVER sets this: the record gate exists so a rebase cannot move a head "
                         "out from under a review, and a record store is per-machine, so on a box that "
                         "did not mint the record the gate cannot see it.")
    ap.add_argument("--report", default="", help="write a markdown census of this pass to this path")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args(argv)

    if not re.fullmatch(r"[^/]+/[^/]+", args.repo):
        print(f"conflict-rebase: --repo must be owner/name, got {args.repo!r}", file=sys.stderr)
        return 3

    STATE.mkdir(parents=True, exist_ok=True)
    brake = STATE / "PAUSED"
    if brake.exists() and not args.dry_run:
        log(f"brake file present ({brake}) — refusing to act")
        return 0
    lock_fh = open(state_path("run.lock"), "w")
    try:
        fcntl.flock(lock_fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        log("another run holds the lock — exiting")
        return 0

    try:
        prs = list_open_prs(args.repo)
    except Unreadable as e:
        log(f"UNREADABLE open-PR list: {e}")
        return 2

    conflicting = [p["number"] for p in prs if (p.get("mergeable") or "").upper() == "CONFLICTING"]
    required: list[str] = []
    if args.include_behind:
        try:
            required = required_contexts(args.repo)
        except Unreadable as e:
            # ⛔ A PASS THAT COULD NOT READ THE REQUIRED CONTEXTS IS NOT A CLEAN PASS.
            # Skipping the arm and exiting 0 makes the timer log "rc=0" for a pass that
            # did nothing, which is the same fail-open shape as an empty failing set.
            log(f"UNREADABLE required contexts ({e}) — refusing to act this pass")
            return 2
    chos, skipped = select(prs, args, required)
    log(f"census: open={len(prs)} conflicting={len(conflicting)} candidates={len(chos)} "
        f"max={args.max} dry_run={args.dry_run}")

    worktrees: list[tuple[str, str, str]] = []
    checkout = args.checkout
    if checkout:
        if (Path(checkout) / ".git").exists():
            try:
                worktrees = worktree_states(checkout)
            except Unreadable as e:
                log(f"UNREADABLE live-lane surface ({e}) — refusing to act this pass")
                return 2
        else:
            log(f"UNREADABLE live-lane surface: --checkout {checkout} is not a git checkout — refusing to act")
            return 2
    else:
        # ⛔ NOT A SILENT HANDBRAKE. With no checkout the detached-worktree half of the
        # hold check cannot run (and the sibling conflict lane holds its PRs in
        # DETACHED worktrees, which have no branch). Say so, loudly, every pass — the
        # claim registry, the two ls-remote reads and the lease still hold.
        log("live-lane surface: worktrees DISABLED (no --checkout / CONFLICT_REBASE_CHECKOUT) "
            "— claim registry + head stability + force-with-lease remain")

    # ⛔ THE CAP BOUNDS ATTEMPTS, NOT SUCCESSES. Counting only successes let ONE run
    # walk all 36 candidates and label every one of them `needs-human-conflict` —
    # a 36-PR label storm from a mechanism whose own rule is "cap per run".
    results, acted, failed, attempted = [], 0, 0, 0
    scratch = scratch_repo(args.repo)
    try:
        claims = remote_claims(scratch)
    except Unreadable as e:
        log(f"UNREADABLE claim registry ({e}) — a held PR cannot be ruled out; refusing to act")
        return 2
    unreadable = False
    for pr in chos:
        n = pr["number"]
        try:
            lane = branch_has_live_lane(pr, worktrees, claims, args.repo)
        except Unreadable as e:
            unreadable = True
            log(f"#{n} SKIP unreadable lane surface ({e})")
            results.append({"pr": n, "action": "skip", "detail": f"unreadable lane surface: {e}"})
            continue
        if lane:
            log(f"#{n} SKIP {pr['headRefName']}: live lane ({lane})")
            results.append({"pr": n, "action": "skip", "detail": f"live lane: {lane}"})
            continue
        if attempted >= args.max:
            results.append({"pr": n, "action": "deferred", "detail": f"cap --max {args.max}"})
            continue
        attempted += 1
        try:
            res = rebase_pr(scratch, pr, args)
        except (Refused, Unreadable) as r:
            if isinstance(r, Unreadable):
                # ⛔ A SURFACE FAILURE IS EXIT 2, NOT A TRACEBACK. `rebase_pr` calls
                # git() which raises RuntimeError on a failed fetch; uncaught, that
                # crashed the pass with exit 1, lost the report, and abandoned every
                # remaining candidate — while the documented contract says 2.
                unreadable = True
                log(f"#{n} UNREADABLE while preparing ({r})")
                results.append({"pr": n, "action": "skip", "detail": f"unreadable: {r}"})
                continue
            r = r  # Refused
            failed += 1
            log(f"#{n} REFUSED[{r.kind}] {r.detail}")
            results.append({"pr": n, "branch": pr["headRefName"], "action": "refused",
                            "kind": r.kind, "detail": r.detail})
            if args.dry_run:
                continue
            if r.kind == "content-conflict":
                try:
                    add_label(n, args.repo, LABEL)
                except Unreadable as e:
                    unreadable = True
                    log(f"#{n} UNREADABLE label surface ({e}) — the refusal is NOT published")
                    results[-1]["detail"] += f" | label failed: {e}"
                try:
                    comment(n, args.repo, _refusal_body(n, pr, r))
                except Unreadable as e:
                    unreadable = True
                    log(f"#{n} UNREADABLE comment surface ({e}) — the refusal is NOT published")
                    results[-1]["detail"] += f" | comment failed: {e}"
                strikes = strikes_get(n) + 1
                backoff_set(n, min(BACKOFF_REFUSE_BASE * (2 ** (strikes - 1)), BACKOFF_REFUSE_CAP), r.kind, strikes)
            elif r.kind == "unreadable":
                unreadable = True
            elif r.kind == "rebase-failed":
                # Not a content conflict (no label), but a deterministic mechanical
                # failure will repeat: a SHORT backoff keeps it from re-occupying a cap
                # slot every 30-minute pass forever.
                backoff_set(n, BACKOFF_OK, r.kind, strikes_get(n))
            elif r.kind in ("rebase-changed-content", "nothing-left"):
                # A property of the BRANCH: retrying it changes nothing.
                backoff_set(n, BACKOFF_OK, r.kind, strikes_get(n))
            # ⛔ A TRANSIENT REFUSAL (unreadable / peer-pushing / head-moved /
            # lease-refused / already-current) gets NO backoff. It is a fact about
            # this MINUTE, and a 6-hour backoff for a dropped ls-remote is how one
            # network blip hides a PR from the mechanism for the rest of the day
            # (measured: a transient empty read put #2613 into backoff).
            continue

        if args.dry_run:
            h0 = diff_hash(n, args.repo)
            acted += 1
            results.append({"pr": n, "branch": res["branch"], "action": "would-rebase",
                            "old_head": res["old_head"], "new_head": res["new_head"],
                            "kept": res["kept"], "dropped": res["dropped"],
                            "diff_before": h0[1][:12], "diff_status": h0[0]})
            log(f"#{n} WOULD REBASE {res['branch']} {res['old_head'][:12]} -> {res['new_head'][:12]} "
                f"(replayed={res.get('replayed', res['kept'])} already-landed-dropped={res['dropped']}, diff={h0[1][:12]})")
            continue

        diff_before = diff_hash(n, args.repo)
        try:
            push(scratch, res)
        except Refused as r:
            failed += 1
            log(f"#{n} REFUSED[{r.kind}] {r.detail}")
            results.append({"pr": n, "action": "refused", "kind": r.kind, "detail": r.detail})
            continue
        acted += 1
        # ⛔ THE PUSHED HEAD MUST BE VISIBLE BEFORE ANY ATTESTATION CLAIM IS MADE. The
        # diff hash carries no head sha, so reading it while the API still reports the
        # OLD head would compare the OLD diff with the record and report "kept" over a
        # head it never measured. Wait for the head to equal what we pushed; if it never
        # does, the hash is UNUSABLE and the record is superseded (fail closed).
        try:
            head_ok = wait_head(n, args.repo, res["new_head"])
        except Unreadable as e:
            # ⛔ THIS READ SITS OUTSIDE THE POST-PUSH try BELOW. When it raised, the pass
            # died with a traceback AFTER a successful push: no comment, no record
            # handling, no report, remaining candidates abandoned — exit 1 where the
            # contract says 2.
            head_ok = False
            log(f"#{n} UNREADABLE head read ({e}) — treating the diff as unverified")
        diff_after = diff_hash(n, args.repo) if head_ok else ("unavailable", "")
        if not head_ok:
            unreadable = True
            log(f"#{n} UNREADABLE pushed head did not become visible — treating the diff as unverified")
        try:
            rec = record_state(n, args.repo, diff_after[1])
            dropped_labels = strip_review_labels(n, args.repo)
            mergeable = wait_mergeable(n, args.repo)
            body = _success_body(n, res, diff_before, diff_after, rec, dropped_labels, mergeable)
            comment(n, args.repo, body)
        except Unreadable as e:
            unreadable = True
            log(f"#{n} UNREADABLE post-push surface ({e}) — the branch WAS pushed; the record/comment state is INCOMPLETE")
            results.append({"pr": n, "branch": res["branch"], "action": "rebased-post-step-unreadable",
                            "old_head": res["old_head"], "new_head": res["new_head"], "detail": str(e)})
            backoff_set(n, BACKOFF_OK, "rebased-unverified", 0)
            continue
        backoff_set(n, BACKOFF_OK, "rebased", 0)
        log(f"#{n} REBASED {res['branch']} {res['old_head'][:12]} -> {res['new_head'][:12]} "
            f"mergeable={mergeable} diff {diff_before[0]}:{diff_before[1][:12]} -> {diff_after[0]}:{diff_after[1][:12]} | {rec}")
        results.append({"pr": n, "branch": res["branch"], "action": "rebased",
                        "old_head": res["old_head"], "new_head": res["new_head"],
                        "mergeable": mergeable, "diff_before": diff_before[1], "diff_after": diff_after[1],
                        "record": rec, "labels_removed": dropped_labels})

    if args.report:
        write_report(args.report, args, prs, conflicting, results, skipped)

    if args.json:
        print(json.dumps({"census": {"open": len(prs), "conflicting": len(conflicting)},
                          "results": results,
                          "skipped": [{"pr": n, "why": w} for n, w in skipped]}, indent=1))
    log(f"done: acted={acted} refused={failed} skipped={len(skipped)} conflicting_before={len(conflicting)}")
    return 2 if unreadable else 0


def write_report(path: str, args, prs: list[dict], conflicting: list[int],
                 results: list[dict], skipped: list[tuple[int, str]]) -> None:
    """A census an operator can read BEFORE trusting the bot (and the scheduler's record)."""
    from collections import Counter

    hotspots = Counter()
    # ⛔ PARSE WHAT THIS CODE ACTUALLY EMITS. The old regex looked for git's
    # `Merge conflict in <path>` line, but the refusal detail has carried
    # `…; conflicting paths: a, b` since before the first commit — so the report's
    # headline table was always empty (a false negative on the finding that matters).
    for r in results:
        if r.get("kind") == "content-conflict":
            # `detail` can carry a " | label failed: …" suffix appended by the post-push
            # handler; the hotspot table is the operator's finding surface and must not
            # absorb it.
            core = (r.get("detail") or "").split(" | ")[0]
            m = re.search(r"conflicting paths: ([^|]+)$", core, re.M)
            if m:
                for pth in m.group(1).split(", "):
                    if pth.strip():
                        hotspots[pth.strip()] += 1
    lines = [
        f"# conflict-rebase census — {args.repo}",
        "",
        f"_generated {time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())} "
        f"(mode: {'dry-run' if args.dry_run else 'live'}, cap --max {args.max})_",
        "",
        f"- open PRs: **{len(prs)}**",
        f"- `CONFLICTING`: **{len(conflicting)}**",
        f"- examined this pass: {len([r for r in results if r.get('action') != 'deferred'])} "
        f"(cap --max {args.max})",
        f"- rebased: **{len([r for r in results if r.get('action') == 'rebased'])}**",
        f"- refused (content conflict): "
        f"**{len([r for r in results if r.get('kind') == 'content-conflict'])}**",
        "",
        "## Conflict hotspots (files, across the refusals in this pass)",
        "",
    ]
    if hotspots:
        lines += ["| file | PRs blocked on it |", "|---|---|"]
        lines += [f"| `{f}` | {n} |" for f, n in hotspots.most_common(15)]
    else:
        lines.append("_(none in this pass)_")
    lines += ["", "## Disposition", ""]
    for r in results:
        what = r.get("action")
        if what == "refused":
            what = f"REFUSED ({r.get('kind')})"
        lines.append(f"- #{r['pr']} — {what}" + (f" — {r.get('detail')}" if r.get("detail") else ""))
    if skipped:
        lines += ["", "## Not considered", ""]
        lines += [f"- #{n} — {w}" for n, w in skipped]
    Path(path).write_text("\n".join(lines) + "\n")


def _success_body(n: int, res: dict, before: tuple[str, str], after: tuple[str, str], rec: str,
                  dropped_labels: list[str], mergeable: str) -> str:
    # ⛔ THE ATTESTATION CLAIM IS MADE BY ONE AUTHORITY: the RECORD decision, never
    # `before == after`. Those are different questions — "did this push change the
    # diff" vs "does the record on file still describe what would merge" — and
    # conflating them is how a comment ends up saying "unchanged" beside a record
    # that was just moved aside as stale (measured: §3b of the suite).
    lines = [
        "## 🤖 conflict-rebase — rebased, conflict-free, no content decisions",
        "",
        f"- branch `{res['branch']}` rebased onto `main@{res['base'][:12]}`",
        f"- head `{res['old_head'][:12]}` → **`{res['new_head']}`**",
        f"- commits replayed: {res.get('replayed', res['kept'])}"
        + (f"; {res['dropped']} commit(s) dropped because their patch is already in `main`" if res["dropped"] else ""),
        f"- GitHub now reports `mergeable={mergeable}`",
        f"- diff_sha256 before `{before[1][:16] or before[0]}` → after `{after[1][:16] or after[0]}`",
        "",
        f"**Review record**: {rec}.",
    ]
    if rec.startswith("UNREADABLE"):
        lines += [
            "",
            "A review record EXISTS at the canonical path and **could not be moved aside**, so this "
            "head must be treated as UNREVIEWED until a human removes or re-records it. The head "
            "above is not what that record attests.",
        ]
    elif rec.startswith("superseded-unverified"):
        # ⛔ `superseded-unverified` MUST be tested BEFORE `superseded` — it starts with
        # it, so the generic arm claimed the diff CHANGED when the diff was never read.
        # That is the same "a claim nobody measured" this function's own header forbids,
        # and it costs a paid re-review of an unchanged diff (#2698 review, P2).
        lines += [
            "",
            "The diff at this head **could not be read**, so the record's relation to it is "
            "UNKNOWN — not 'different'. The record was moved aside because a record must never "
            "stand for a head nobody verified. Treat this head as UNREVIEWED and re-record once "
            "the diff is readable.",
        ]
    elif rec.startswith("superseded"):
        lines += [
            "",
            "The record on file attests a DIFFERENT diff than the one this head now carries, so it no "
            "longer covers what would merge and was moved aside. **Re-review is required** before the "
            "rail will take this PR.",
        ]
    elif rec.startswith("kept"):
        lines += [
            "",
            "The reviewed DIFF is byte-identical, so the existing attestation still describes exactly what "
            "would merge — the merge gate verifies that itself and carries a record by diff (the #2982 "
            "carry arm). Nothing is blocked by this comment; if you want a review of the new head anyway, "
            "record one.",
        ]
    else:
        lines += [
            "",
            "No review record existed for this PR, so none was invalidated. New commits mean new checks: "
            "the head above is UNREVIEWED.",
        ]
    if dropped_labels:
        lines.append(f"Removed review-asserting label(s): {', '.join('`%s`' % x for x in dropped_labels)}.")
    lines += ["", "CI re-runs on the new head automatically. No conflict was resolved by this bot."]
    return "\n".join(lines) + "\n"


def _refusal_body(n: int, pr: dict, r: Refused) -> str:
    return "\n".join([
        "## 🤖 conflict-rebase — REFUSED (`needs-human-conflict`)",
        "",
        f"The rebase of `{pr['headRefName']}` onto `main` hits a **content conflict**, so this bot stops.",
        "",
        f"- {r.detail}",
        f"- head left untouched at `{pr['headRefOid'][:12]}` — nothing was pushed.",
        "",
        "A conflict means two intents disagree. Picking a side mechanically is how a tree lands that "
        "compiles and is wrong, so the resolution is a human decision. Please resolve it, push, and "
        f"remove the `{LABEL}` label (this bot will not touch the PR again while it is set).",
        "",
    ]) + "\n"


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
