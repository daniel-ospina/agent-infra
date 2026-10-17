#!/usr/bin/env python3
"""landability.py — for ONE pull request: does the RECORDED review still bind the
current head, and are the head's checks clear?

VERDICTS (exactly these four words; a parenthetical names the reason when the
word alone is not the answer):

    AT             the review record names the CURRENT head
    CARRY          the record is from an older head but its `diff_sha256` equals
                   today's normalized diff — i.e. the reviewed CONTENT is
                   unchanged by the head move (see "What CARRY does not prove")
    NEEDS-REVIEW   no record, an unaccepted verdict, or the reviewed content
                   changed
    BLOCKED        the PR cannot be driven through the rail right now: not open,
                   draft, merge conflict, base repointed, or the head's checks
                   are not all clear

`BLOCKED` wins the VERDICT line when it applies, but the record answer is always
printed on the `record-binding:` line — so a blocked PR still reports whether a
fresh review is needed. Precedence, in order: not-open/draft, merge conflict,
base repointed, checks unmeasured (no check-run at all), checks failed, checks in
flight, checks untested, then the record binding.

WHAT `CARRY` DOES NOT PROVE — the producer's carry-forward needs TWO conditions,
and this tool can only see one of them.
    This tool compares the LOCAL record file's `diff_sha256` against the live
    normalized diff: that is the content-unchanged condition. `record-review.sh`'s
    carry-forward additionally requires VERIFIABLE SIGNED EVIDENCE in the PR BODY
    (an HMAC-signed `review recorded: … diff=<hash> … sig=<hash>` marker whose
    digest matches), and it refuses when the marker is absent, edited away, or
    signed with a different key. Those two conditions can disagree in both
    directions: a record whose `diff_sha256` still matches but whose body marker
    is gone reads `CARRY` here and is REFUSED by the producer; and a pre-#1362
    marker carrying the legacy raw digest is ACCEPTED by the producer (its
    `PRIOR_DIFF_ALT` alternation) but reads `NEEDS-REVIEW(no-diff-identity)` here.
    `CARRY` therefore means "the reviewed content is unchanged", NOT "the rail's
    carry-forward will fire". Read the rail's step [3/4] output for that.

WHY IT IS NOT CALLED `preflight.py` — read this before renaming it
-----------------------------------------------------------------
The fleet already mandates a tool called `collision_preflight.py` (it lives in the
`tortoise` repo at `tools/collision_preflight.py`): the DISPATCH-side gate that
answers a DIFFERENT question ("is issue N already being worked?") from DIFFERENT
inputs (an issue number; open/closed PRs by title and head ref, branches, `git
worktree list`, assignee/claims) and with DIFFERENT verdicts (`CLEAN` /
`COLLISION` / `INCOMPLETE`). It is referenced BY NAME in `tortoise`'s `AGENTS.md`
and in four of this repo's skills. This script is a LANDING-side, advisory check,
and a shared name invites a future lane to substitute one for the other — an
advisory landability check standing in for the mandated collision gate, or a
dispatch gate's `CLEAN` read as a landing verdict. It is named for the question
it answers, as the collision gate is.

WHAT IT DOES NOT DO: review, record, merge or dispatch. Its answer is an input
to a decision, never the decision.

Usage:
  landability.py <pr> [--repo owner/name] [--repo-dir PATH]

  --repo owner/name   repo for the gh calls. Default: resolved with
                      `gh repo view` in --repo-dir.
  --repo-dir PATH     the checkout the normalizer is read from and gh runs in.
                      Default: the current directory.

Exit: 0 = a verdict was printed; 2 = the question could not be answered (gh
      failure, no repo, no normalizer) — never a guess.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys

# Mirrors ACCEPTED_VERDICTS in atomic-land.sh and
# extensions/review-enforcer/index.ts. If that list widens, widen this one too.
ACCEPTED_VERDICTS = ("clean", "clean-micro", "clean-low")

# The green allow-list AGENTS.md's "Reading verification state" rule defines:
# only these are green. Anything completed that is not green and not UNTESTED is
# RED — including a conclusion GitHub has not documented yet, and a null one.
GREEN = ("success", "neutral", "skipped")
# Non-red, but NOT green: the job ran and exercised nothing, so it cannot count
# as the head having been TESTED.
UNTESTED = ("cancelled", "stale")
# Green for the tree-health question, but NOT "tested" for the rail's: the rail's
# own vacuity guard credits only success|failure|timed_out
# (`scripts/check-lane-tested.sh`, `admin-merge.sh`). Reported, never used to
# block — see the note in check_state().
NOT_TESTED = ("neutral", "skipped")


class Failure(Exception):
    """A condition the tool can name and must not guess past."""


def gh_bytes(args, cwd):
    """Run gh, returning the CompletedProcess with stdout/stderr as BYTES.

    Bytes matter for the diff: the review digest is sha256 over the normalizer's
    byte output, and a text decode/replace would change it.

    An exec failure (gh absent from PATH) is raised as a `Failure`, not an
    `OSError`: the documented contract is "2 = it could not answer", and an
    uncaught exception here would exit 1 with a traceback — and would kill a whole
    bulk.py batch, since its per-row handler catches only this type.
    """
    try:
        return subprocess.run(["gh", *args], capture_output=True, cwd=cwd, input=None)
    except OSError as exc:
        raise Failure(
            f"could not execute gh ({exc}) — is the GitHub CLI installed and on PATH?"
        )


def gh_text(args, cwd):
    r = gh_bytes(args, cwd)
    return (
        r.returncode,
        (r.stdout or b"").decode("utf-8", "replace"),
        (r.stderr or b"").decode("utf-8", "replace"),
    )


def resolve_repo(explicit, repo_dir):
    if explicit:
        return explicit
    rc, out, err = gh_text(
        ["repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"], repo_dir
    )
    name = out.strip()
    if rc != 0 or "/" not in name:
        raise Failure(
            "could not resolve the repo — pass --repo owner/name "
            f"(gh repo view failed in {repo_dir}: {err.strip()[:200] or 'no stderr'})"
        )
    return name


def resolve_normalizer(repo_dir):
    path = os.path.join(repo_dir, "scripts", "lib", "diff-normalize.py")
    if not os.path.isfile(path):
        raise Failure(
            f"the review-evidence diff normalizer is missing: {path}. The CARRY "
            "answer is unprovable without it — the digest is sha256 over its "
            "output, and it is the ONE implementation of that normalization "
            "(agent-infra #1362 D1). Point --repo-dir at a checkout that carries "
            "scripts/lib/diff-normalize.py."
        )
    return path


def normalize(raw, normalizer):
    try:
        r = subprocess.run(
            [sys.executable, normalizer], input=raw, capture_output=True
        )
    except OSError as exc:
        raise Failure(f"could not execute {sys.executable} on {normalizer}: {exc}")
    if r.returncode != 0:
        raise Failure(
            f"{normalizer} exited {r.returncode}: "
            f"{(r.stderr or b'').decode('utf-8', 'replace').strip()[:200]}"
        )
    return r.stdout


def parse_ndjson(text):
    out = []
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            out.append(json.loads(line))
        except ValueError:
            continue
    return out


def read_record(repo, pr):
    """The review record, repo-qualified first — mirrors atomic-land.sh read_record.

    `<owner>-<repo>-<PR>.json` wins; the legacy `<PR>.json` is accepted only when
    it names no repo, or names THIS one.
    """
    owner, _, name = repo.partition("/")
    reviews = os.path.expanduser("~/.pi/agent/reviews")
    qualified = os.path.join(reviews, f"{owner}-{name}-{pr}.json")
    legacy = os.path.join(reviews, f"{pr}.json")
    candidate = None
    if os.path.isfile(qualified):
        candidate = qualified
    elif os.path.isfile(legacy):
        try:
            with open(legacy, "rb") as fh:
                rec_repo = json.load(fh).get("repo", "")
        except Exception:
            rec_repo = ""
        if not rec_repo or rec_repo == repo:
            candidate = legacy
    if candidate is None:
        return None, None
    try:
        with open(candidate, "rb") as fh:
            return json.load(fh), candidate
    except Exception:
        return None, candidate


def head_matches(record_sha, head):
    """True when the record names exactly this head.

    Recorded shas are full 40-hex (record-review.sh writes git rev-parse), but a
    short sha is accepted as a prefix rather than treated as a changed head.
    """
    if not record_sha or not head:
        return False
    a, b = record_sha.lower(), head.lower()
    if a == b:
        return True
    n = min(len(a), len(b))
    if n < 7:
        return False
    return a[:n] == b[:n] and (len(a) == n or len(b) == n)


def record_binding(record, head, live_diff):
    """The record's binding to the head. Reads the LOCAL record file only —
    see "WHAT `CARRY` DOES NOT PROVE" in the module docstring for what that means
    and what the rail checks on top of it."""
    if record is None:
        return "NEEDS-REVIEW(no-record)"
    verdict = record.get("verdict")
    if verdict not in ACCEPTED_VERDICTS:
        return f"NEEDS-REVIEW(verdict={verdict or 'none'})"
    if head_matches(record.get("head_sha"), head):
        return "AT"
    diff = record.get("diff_sha256") or ""
    if diff and live_diff and diff == live_diff:
        return "CARRY"
    if not diff:
        return "NEEDS-REVIEW(no-diff-identity)"
    return "NEEDS-REVIEW(diff-changed)"


def merge_base_of(repo, base, head, repo_dir):
    """The merge base of base...head — the commit that identifies the certified
    content. INVARIANT under a base that merely ADVANCES; it moves exactly when
    the base is repointed or rewritten. Mirrors atomic-land.sh's `merge_base_of`."""
    rc, out, _err = gh_text(
        ["api", f"repos/{repo}/compare/{base}...{head}", "--jq", ".merge_base_commit.sha"],
        repo_dir,
    )
    return out.strip() if rc == 0 else ""


def newest_per_app_and_name(runs):
    """One attempt per check, newest by id.

    Grouping key: `(app slug, job name)`, with the run's OWN id joining the key
    when the name is empty. Two deliberate decisions:

    * NOT `check_suite.id` — every re-run gets its own suite, so grouping by suite
      would shatter one check into one group per attempt and "newest" would stop
      meaning anything.
    * The run id joins the key for an UNNAMED run, mirroring the rail's own fix
      (#1353): "a newer unnamed non-red" must not "SUPERSEDE an older unnamed red
      and discard it before classification". Two unnamed runs would otherwise
      collapse into one group and the newer would hide the older.

    DECLARED RESIDUAL — accepted, not fixed: this key cannot separate two
    DIFFERENT workflows that publish the same job name (every Actions check-run
    carries the same app slug, so the slug does not separate them), and the newest
    of one can mask the other. `scripts/admin-merge.sh` keys the same way and
    AGENTS.md records this as that rail's accepted residual; this instrument
    adopts it deliberately to stay within ~3 API calls, because separating them
    needs a per-run workflow resolution — one extra API call per check-run.
    """
    groups = {}
    for r in runs:
        name = r.get("name")
        key = ((r.get("app") or {}).get("slug"), name or f"\x00unnamed:{r.get('id')}")
        if key not in groups or r.get("id", 0) > groups[key].get("id", 0):
            groups[key] = r
    return list(groups.values())


def check_state(runs):
    groups = newest_per_app_and_name(runs)
    in_flight = sorted({r.get("name") for r in groups if r.get("status") != "completed"})
    failed = sorted(
        {
            r.get("name")
            for r in groups
            if r.get("status") == "completed"
            and r.get("conclusion") not in GREEN + UNTESTED
        }
    )
    untested = sorted(
        {
            r.get("name")
            for r in groups
            if r.get("status") == "completed" and r.get("conclusion") in UNTESTED
        }
    )
    # `neutral`/`skipped` are green for the tree-health question but credit nothing
    # in the rail's own `tested` vocabulary. Reported so the lane can see it; NOT a
    # blocking reason, because conditional jobs are routinely skipped on every PR
    # and blocking on them would refuse every PR rather than the vacuous ones. The
    # rail's per-lane vacuity guard is what actually decides "was THIS lane tested".
    not_tested = sorted(
        {
            r.get("name")
            for r in groups
            if r.get("status") == "completed" and r.get("conclusion") in NOT_TESTED
        }
    )
    return groups, in_flight, failed, untested, not_tested


def check(pr, repo, repo_dir, normalizer):
    """Answer for one PR. Returns a dict; raises Failure when it cannot answer."""
    rc, out, err = gh_text(
        [
            "pr", "view", str(pr), "--repo", repo,
            "--json", "state,isDraft,headRefOid,mergeable,mergeStateStatus,headRefName,baseRefName",
        ],
        repo_dir,
    )
    if rc != 0:
        raise Failure(f"gh pr view {pr} failed: {err.strip()[:200] or out.strip()[:200]}")
    try:
        d = json.loads(out)
    except ValueError:
        raise Failure(f"gh pr view {pr} returned unparseable JSON: {out.strip()[:200]}")

    head = d.get("headRefOid") or ""
    base = d.get("baseRefName") or ""
    record, record_file = read_record(repo, pr)

    state = d.get("state")
    draft = bool(d.get("isDraft"))
    in_flight = failed = untested = not_tested = []
    runs = []
    live_diff = ""
    base_repointed = False
    if state == "OPEN" and not draft:
        r = gh_bytes(
            ["api", f"repos/{repo}/pulls/{pr}",
             "-H", "Accept: application/vnd.github.v3.diff"],
            repo_dir,
        )
        if r.returncode != 0:
            raise Failure(
                f"could not read the diff of {repo}#{pr}: "
                f"{(r.stderr or b'').decode('utf-8', 'replace').strip()[:200]}"
            )
        raw = r.stdout or b""
        normalized = normalize(raw, normalizer)
        live_diff = hashlib.sha256(normalized).hexdigest() if normalized else ""
        # `filter=all` is required: the default is not all, and it has returned
        # 26 of 40 on a real commit. `--paginate` merges every page (gh applies
        # --jq per page, so this is NDJSON); a truncated page reads as absent
        # checks, which is how "are the checks terminal?" becomes a false yes.
        rc, out, err = gh_text(
            ["api", f"repos/{repo}/commits/{head}/check-runs?per_page=100&filter=all",
             "--paginate", "--jq", ".check_runs[]"],
            repo_dir,
        )
        if rc != 0:
            raise Failure(
                f"could not read the check-runs at {head[:12]}: "
                f"{err.strip()[:200] or 'no stderr'}"
            )
        runs = parse_ndjson(out)
        _groups, in_flight, failed, untested, not_tested = check_state(runs)
        # A record that NAMES its merge base (clean-low, #1348) must be bound to
        # the SAME merge base the PR has now: a base repoint leaves every
        # head-bound check passing while the certified diff is no longer the diff
        # that would merge. This mirrors the rail's own pre-unit arm (B10). A
        # `clean`/`clean-micro` record carries no base field, so this cannot fire
        # for it — the same declared residual the rail documents.
        rec_mb = (record or {}).get("merge_base_sha")
        if rec_mb and head_matches((record or {}).get("head_sha"), head):
            live_mb = merge_base_of(repo, base, head, repo_dir)
            base_repointed = not live_mb or live_mb != rec_mb

    binding = record_binding(record, head, live_diff)
    if state != "OPEN":
        verdict = f"BLOCKED(not-open:{state})"
    elif draft:
        verdict = "BLOCKED(draft)"
    elif d.get("mergeable") == "CONFLICTING" or d.get("mergeStateStatus") == "DIRTY":
        # A conflict is a definite blocker: `gh pr update-branch` refuses and the
        # merge cannot happen. `UNKNOWN` is transient (GitHub computes
        # mergeability lazily), so it is deliberately NOT read as a conflict.
        verdict = "BLOCKED(merge-conflict)"
    elif base_repointed:
        verdict = "BLOCKED(base-repointed)"
    elif not runs:
        # AN EMPTY SURFACE IS UNMEASURED, NOT GREEN — the same rule
        # `admin-merge.sh` applies. Nothing ran at this head, so nothing about it
        # has been checked and no green can be read from the absence.
        verdict = "BLOCKED(checks-unmeasured)"
    elif failed:
        verdict = "BLOCKED(checks-failed)"
    elif in_flight:
        verdict = "BLOCKED(checks-in-flight)"
    elif untested:
        verdict = "BLOCKED(checks-untested)"
    else:
        verdict = binding

    return {
        "pr": str(pr),
        "repo": repo,
        "state": state,
        "draft": draft,
        "head": head,
        "branch": d.get("headRefName") or "",
        "base": base,
        "mergeable": d.get("mergeable"),
        "merge_state": d.get("mergeStateStatus"),
        "record": record,
        "record_file": record_file,
        "live_diff": live_diff,
        "checks_total": len(runs),
        "in_flight": in_flight,
        "failed": failed,
        "untested": untested,
        "not_tested": not_tested,
        "base_repointed": base_repointed,
        "binding": binding,
        "verdict": verdict,
    }


def report(res):
    rec = res["record"] or {}
    print(
        f"PR {res['pr']}  repo={res['repo']}  state={res['state']}  "
        f"draft={str(res['draft']).lower()}  mergeable={res['mergeable']}  "
        f"mergeState={res['merge_state']}  head={res['head'][:12]}  "
        f"branch={res['branch']}  base={res['base']}"
    )
    if res["record"] is None:
        print(f"record: NONE ({res['record_file'] or 'no record file'})")
    else:
        print(
            f"record: verdict={rec.get('verdict')} head={(rec.get('head_sha') or '')[:12]} "
            f"diff={(rec.get('diff_sha256') or '')[:12] or 'none'} "
            f"merge_base={(rec.get('merge_base_sha') or '')[:12] or 'none'} "
            f"reviewed={rec.get('reviewed_at')} file={res['record_file']}"
        )
    print(f"live diff: {res['live_diff'][:12] or 'none'}")
    if res["state"] == "OPEN" and not res["draft"]:
        print(
            f"checks: total={res['checks_total']} in-flight={res['in_flight']} "
            f"failed(newest)={res['failed']} untested(newest)={res['untested']} "
            f"not-tested(newest)={len(res['not_tested'])}"
        )
        if res["base_repointed"]:
            print("base: the record's merge base is not this PR's merge base (repointed or rewritten)")
    else:
        print("checks: not read (PR is not an open, non-draft pull request)")
    print(f"record-binding: {res['binding']}")
    print(f"VERDICT: {res['verdict']}")


def build_parser():
    p = argparse.ArgumentParser(
        prog="landability.py",
        description=(
            "Does this PR's recorded review still bind its head, and are its "
            "checks clear? Prints record-binding + VERDICT."
        ),
        epilog="VERDICT words: " + " / ".join(("AT", "CARRY", "NEEDS-REVIEW", "BLOCKED")),
    )
    p.add_argument("pr", help="pull request number")
    p.add_argument("--repo", default=None, help="owner/name (default: gh repo view in --repo-dir)")
    p.add_argument("--repo-dir", default=".", help="checkout to read the normalizer from (default: .)")
    return p


def main(argv=None):
    args = build_parser().parse_args(argv)
    if not str(args.pr).isdigit():
        print(f"landability: PR must be numeric (got {args.pr!r})", file=sys.stderr)
        return 2
    repo_dir = os.path.abspath(os.path.expanduser(args.repo_dir))
    try:
        if not os.path.isdir(repo_dir):
            raise Failure(f"--repo-dir is not a directory: {repo_dir}")
        repo = resolve_repo(args.repo, repo_dir)
        normalizer = resolve_normalizer(repo_dir)
        report(check(args.pr, repo, repo_dir, normalizer))
    except Failure as exc:
        print(f"GH-FAIL {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
