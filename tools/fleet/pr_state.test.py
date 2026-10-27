#!/usr/bin/env python3
"""tools/fleet/pr_state.test.py — the #2866 acceptance suite (HERMETIC: a stub `gh`, no network).

    python3 tools/fleet/pr_state.test.py              # the tests
    python3 tools/fleet/pr_state.test.py --mutations  # every rule, REVERTED (each must redden)
    python3 tools/fleet/pr_state.test.py --list       # what is pinned

WHY THE MUTATIONS RUN
---------------------
"Every rule gets a test that reddens when the rule is reverted" is a claim about the SUITE, and an
asserted claim is worth nothing (this repo has already shipped two artifacts that claimed mutation
evidence they did not have). `--mutations` writes a mutated copy of the module to a temp dir, runs
the paired test against it IN A SUBPROCESS, and reports a FAILURE when the test still passes: a
test that cannot catch its own defect is decoration. The real file is never modified.

WHAT IS PINNED, AND THE DEFECT EACH RULE PREVENTS
------------------------------------------------
  cancelled-not-red     a cancelled/stale check is NOT a failure. Most "red PRs" measured on
                        2026-10-26 were cancelled runs; calling one a failure spends a fixer and a
                        fresh CI pass on a healthy head.
  unknown-is-red        an undocumented — or null — conclusion is RED. An allow-list of known-bad
                        conclusions is the failure mode AGENTS.md names: an unnamed value must
                        never fall through a gap.
  newest-attempt        the newest attempt per group wins by check-run id, never by payload order
                        (a re-run ADDS a row; GitHub keeps both).
  group-by-workflow     two workflows sharing a job name are TWO groups, so one cannot mask the
                        other (measured in this repo: two `packaging-smoke` runs).
  empty-is-not-green    no check groups is NOREAD, never green.
  conflict-first        CONFLICTING outranks every check verdict.
  draft-first           a draft cannot merge, so nothing it runs can make it mergeable.
  close-stale           changed_files == 0.
  authority             the review requirement comes from the repo's own required checks; an
                        unreadable protection endpoint is an ABSTENTION, never "no review needed".
  attest-scopes         no record → REVIEW in a gate repo, and NOT a defect in a rail repo.
  at-head               attested at head + mergeable + no red → LAND.
  carry                 head moved, reviewed DIFF unchanged → LAND (the gate's own carried arm;
                        a rule that refused this would reverse a recorded decision).
  owes-review           head moved, diff CHANGED → WAIT with both shas, never LAND (#10104).
  diff-unreadable       a diff that could not be READ is a RETRY, not a re-review.
  short-sha             a short/partial recorded sha never binds a full head.
  marker-only           an attestation on the PR body but not in this box's store is NOT ready: the
                        rail's gate reads the store, so LAND here would be a false ready.
  flake-evidence        RERUN-FLAKE only on positive evidence — the same group PASSING on an earlier
                        attempt at the SAME head. `cancelled`/`stale` are non-red for the verdict but
                        are not passes, so they are not evidence (a "passed on an earlier attempt"
                        claim withholds a real red from repair: the fixer declines, the lander
                        waits). This arm used to accept them.
  flake-bound           a group that has already been retried is a defect, not another re-run.
  inherited-red         a red that main's head also carries is not this tree's to fix.
  suppress-in-flight    ONLY `queued` runs are cancelled; a run re-read as in_progress is never
                        cancelled (the measurement-artifact rule: re-measure at the moment of action).
  suppress-scope        only REVIEW / REPAIR-CONFLICT / FIX-RED rows are suppressed.
  suppress-ledger       every cancelled run id is recorded, and `--cancelled` prints its re-trigger.
  unreadable-board      an unreadable listing exits 2 — an unreadable board is never "no open PRs".
  pagination            `--paginate` emits one JSON object per PAGE; a two-page answer must not be
                        read as half a surface.
  no-check-surface      an empty (but READ) check surface is WAIT:no-check-surface and never LAND — and
                        it carries the empty surface's own reason, not "could not be read".
  in-flight             a surface with anything still running is WAIT:in-flight, never LAND. Together
                        with the arm above this is the last thing between "nothing read yet" and a
                        merge; neither was pinned when the reviewer found them.
  mergeable-unknown     a mergeability GitHub has not computed is a WAIT, never a guessed MERGEABLE.
  queued-unreadable     an unreadable queued-run inventory renders `?`, never `0` (the code's comment
                        claimed this; the code printed 0, which is also `--suppress`'s before= figure).
  action-needs-only     `--action` without `--only` REFUSES (exit 2): the row it would print belongs
                        to whichever PR sorts first in the whole table.
  empty-body-is-a-read-error
                        an EMPTY or TRUNCATED API body is a failed READ, never an empty surface (and
                        never an uncaught JSONDecodeError): `gh` exits 0 with no body when a token or
                        proxy eats the answer, which used to arrive as `[]` — the same reason a
                        genuinely check-free PR gets.
  suppress-unknown-queue
                        a `--suppress` pass that could enumerate NOTHING exits 2 and says so; it used
                        to report `cancelled=0` and exit 0 — a success signal for a pass that never
                        ran.
  workflow-listing-unreadable
                        a failed read of the head's RUN LISTING is a failed SURFACE read, never "no
                        workflow names": `{}` is the "nothing is named" answer, which puts every
                        attempt in its own `?unknown:<run>` group, so a job whose newest attempt
                        PASSED is reddened by an older failing one and a fixer is sent at a green head.
  authority-not-a-list  a branch-protection answer that is not a LIST is an ABSTENTION, never "no
                        required checks": `null`/a bare string parsed as an empty context list
                        classifies a review-GATED repo as `rail` and lets an unattested PR land. `[]`
                        stays `rail` (a legitimate "no required checks").
"""

from __future__ import annotations

import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
MODULE = os.path.join(HERE, "pr_state.py")
REPO = "daniel-ospina/tortoise"


def load_module():
    path = os.environ.get("PR_STATE_MODULE") or MODULE
    spec = importlib.util.spec_from_file_location("pr_state_under_test", path)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


# ── the harness ───────────────────────────────────────────────────────────────────────────────
TESTS = []


def test(name):
    def deco(fn):
        TESTS.append((name, fn))
        return fn
    return deco


STUB = r'''#!/usr/bin/env python3
import json, os, re, sys
D = os.environ["PR_STATE_STUB_DIR"]
def jload(name, default=None):
    p = os.path.join(D, name)
    if not os.path.exists(p):
        if default is not None:
            return default
        sys.stderr.write("stub gh: no fixture %s\n" % name); sys.exit(1)
    with open(p) as f:
        return json.load(f)
def emit(obj):
    sys.stdout.write(obj if isinstance(obj, str) else json.dumps(obj)); sys.exit(0)
a = sys.argv[1:]
if a[:2] == ["pr", "list"]:
    limit = 100
    if "--limit" in a:
        limit = int(a[a.index("--limit") + 1])
    emit(jload("prs.json")[:limit])
if a[:2] == ["pr", "view"]:
    n = a[2]
    p = os.path.join(D, "view-%s.json" % n)
    emit(jload("view-%s.json" % n) if os.path.exists(p) else jload("view.json"))
if a and a[0] == "api":
    rest = [x for x in a[1:] if not x.startswith("-") and "/" in x]
    path = rest[-1] if rest else ""
    if "check-runs" in path:
        sha = re.search(r"/commits/([0-9a-f]+)/", path).group(1)
        pages = [x for x in os.listdir(D) if x.startswith("checks-%s." % sha)]
        if not pages:
            sys.stderr.write("stub gh: no check surface for %s\n" % sha); sys.exit(1)
        # one JSON object per page, exactly like `gh api --paginate`
        emit("".join(json.dumps(jload(p)) for p in sorted(pages)))
    if "actions/runs" in path and "status=queued" in path:
        page = re.search(r"page=(\d+)", path)
        page = page.group(1) if page else "1"
        p = "queued-%s.json" % page
        emit(jload(p) if os.path.exists(os.path.join(D, p)) else jload("queued-1.json"))
    if "actions/runs" in path and "head_sha=" in path:
        sha = re.search(r"head_sha=([0-9a-f]+)", path).group(1)
        emit(jload("runs-%s.json" % sha, {"total_count": 0, "workflow_runs": []}))
    m = re.search(r"actions/runs/(\d+)$", path)
    if m:
        emit(jload("run-%s.json" % m.group(1)))
    m = re.search(r"actions/runs/(\d+)/cancel$", path)
    if m:
        with open(os.path.join(D, "cancelled.log"), "a") as f:
            f.write(m.group(1) + "\n")
        emit({})
    if "git/ref/heads" in path:
        emit(jload("ref.json"))
    if "protection/required_status_checks" in path:
        emit(jload("contexts.json"))
    sys.stderr.write("stub gh: unhandled %r\n" % path); sys.exit(1)
sys.stderr.write("stub gh: unhandled argv %r\n" % a); sys.exit(1)
'''

RECORD_STUB = r'''#!/usr/bin/env bash
# stands in for `record-review.sh --print-diff-hash` (the ONE diff-identity implementation)
v="${PR_STATE_STUB_DIFF:-}"
if [ -z "$v" ] || [ "$v" = "FAIL" ]; then
  echo "record-review: the diff could not be read" >&2
  exit 3
fi
printf 'ok\t%s\n' "$v"
'''


class World:
    """One fixture world: a fake repo, a fake store, a fake ledger, a stub gh."""

    def __init__(self):
        self.dir = tempfile.mkdtemp(prefix="prstate-test-")
        self.store = os.path.join(self.dir, "reviews")
        self.ledger = os.path.join(self.dir, "state", "suppressed.jsonl")
        os.makedirs(self.store, exist_ok=True)
        self.stub = os.path.join(self.dir, "bin")
        os.makedirs(self.stub, exist_ok=True)
        gh = os.path.join(self.stub, "gh")
        with open(gh, "w") as f:
            f.write(STUB)
        os.chmod(gh, 0o755)
        rec = os.path.join(self.dir, "record-review.sh")
        with open(rec, "w") as f:
            f.write(RECORD_STUB)
        os.chmod(rec, 0o755)
        self.record_sh = rec
        self.main_sha = "a" * 40
        self.ref(self.main_sha)
        self.contexts(["ai-review-gate", "python-ci-gate"])
        self.queued([])
        self.diff("b" * 64)
        self.write("runs-%s.json" % self.main_sha, {"total_count": 0, "workflow_runs": []})

    # fixtures
    def write(self, name, obj):
        with open(os.path.join(self.dir, name), "w") as f:
            json.dump(obj, f)

    def prs(self, rows):
        self.write("prs.json", rows)

    def pr(self, number, head, mergeable="MERGEABLE", draft=False, files=3, body=""):
        return {"number": number, "headRefOid": head, "headRefName": "b-%d" % number,
                "isDraft": draft, "mergeable": mergeable, "changedFiles": files, "body": body}

    def view(self, obj):
        self.write("view.json", obj)

    def checks(self, sha, rows, split=False):
        """rows: (app, job, status, conclusion, id, run). `split` writes them as TWO pages."""
        runs = [{"name": job, "status": st, "conclusion": cc, "id": cid,
                 "app": {"slug": app},
                 "details_url": "https://github.com/x/actions/runs/%s/job/%s" % (run, cid)}
                for (app, job, st, cc, cid, run) in rows]
        if not split:
            self.write("checks-%s.1.json" % sha, {"total_count": len(runs), "check_runs": runs})
            return
        half = max(1, len(runs) // 2)
        self.write("checks-%s.1.json" % sha, {"total_count": len(runs), "check_runs": runs[:half]})
        self.write("checks-%s.2.json" % sha, {"total_count": len(runs), "check_runs": runs[half:]})

    def workflows(self, sha, mapping):
        self.write("runs-%s.json" % sha,
                   {"total_count": len(mapping),
                    "workflow_runs": [{"id": int(k), "name": v} for k, v in mapping.items()]})

    def queued(self, rows):
        """rows: (head_sha, run_id, workflow name)"""
        self.write("queued-1.json",
                   {"total_count": len(rows),
                    "workflow_runs": [{"id": rid, "head_sha": head, "name": name,
                                       "status": "queued", "event": "pull_request"}
                                      for (head, rid, name) in rows]})

    def run_status(self, run_id, status):
        self.write("run-%s.json" % run_id, {"id": int(run_id), "status": status})

    def ref(self, sha):
        self.write("ref.json", {"object": {"sha": sha}})

    def contexts(self, names):
        self.write("contexts.json", names)

    def no_contexts(self):
        p = os.path.join(self.dir, "contexts.json")
        if os.path.exists(p):
            os.unlink(p)

    def diff(self, value):
        self.stub_diff = value

    def record(self, pr, head, diff=None, repo=REPO, short=False):
        name = "%s-%s.json" % (repo.replace("/", "-"), pr)
        with open(os.path.join(self.store, name), "w") as f:
            json.dump({"pr": pr, "repo": repo, "head_sha": head,
                       "diff_sha256": self.stub_diff if diff is None else diff,
                       "verdict": "clean"}, f)

    # run
    def env(self):
        e = dict(os.environ)
        e.update({
            "PR_STATE_GH": os.path.join(self.stub, "gh"),
            "PR_STATE_STUB_DIR": self.dir,
            "PR_STATE_STUB_DIFF": self.stub_diff,
            "PR_STATE_REVIEWS": self.store,
            "PR_STATE_LEDGER": self.ledger,
            "PR_STATE_RECORD_SH": self.record_sh,
            "O": self.dir,
            "REVIEW_GATE": "ai-review-gate",
        })
        e.pop("PR_STATE_MODULE", None)
        return e

    def use(self):
        """Point the IN-PROCESS module at this world."""
        os.environ.update(self.env())

    def cli(self, *args):
        mod = os.environ.get("PR_STATE_MODULE") or MODULE
        env = self.env()                 # THIS world's fixtures, never a previous test's leftovers
        if os.environ.get("PR_STATE_MODULE"):
            env["PR_STATE_MODULE"] = os.environ["PR_STATE_MODULE"]
        p = subprocess.run([sys.executable, mod] + list(args), capture_output=True, text=True, env=env)
        return p.returncode, p.stdout, p.stderr

    def cancelled_ids(self):
        p = os.path.join(self.dir, "cancelled.log")
        if not os.path.exists(p):
            return []
        return [l.strip() for l in open(p) if l.strip()]

    def cleanup(self):
        shutil.rmtree(self.dir, ignore_errors=True)


def rows_of(w, *a, **k):
    w.use()
    return load_module().build_rows(REPO, **k if k else {"limit": 100})


def by_pr(rows):
    return {r["pr"]: r for r in rows}


def one(w, pr=7, **kw):
    w.prs([w.pr(pr, kw.pop("head", "1" * 40), **kw)])
    return by_pr(rows_of(w))[pr]


# ── the green surface: one green check group, resolvable workflow ─────────────────────────────
def green(w, sha="1" * 40, run="900", job="unit", app="github-actions", wf="Python CI"):
    w.checks(sha, [(app, job, "completed", "success", 11, run)])
    w.workflows(sha, {run: wf})


# ══════════════════════════════════════════════════════════════════════════════════════════════
@test("cancelled-not-red")
def _(M):
    """A cancelled check is NOT a failure — the measured 2026-10-26 misreading."""
    r = M.verdict([{"app": "a", "workflow": "W", "job": "j", "status": "completed",
                    "conclusion": "cancelled", "id": 1, "run": "9"}])
    assert r["verdict"] != "RED", r
    r2 = M.verdict([{"app": "a", "workflow": "W", "job": "j", "status": "completed",
                     "conclusion": "stale", "id": 1, "run": "9"}])
    assert r2["verdict"] != "RED", r2


@test("unknown-is-red")
def _(M):
    """Every conclusion outside the allow-list is RED — undocumented and null included."""
    for concl in ("weird-new-value", "", None):
        r = M.verdict([{"app": "a", "workflow": "W", "job": "j", "status": "completed",
                        "conclusion": concl, "id": 1, "run": "9"}])
        assert r["verdict"] == "RED", (concl, r)


@test("newest-attempt")
def _(M):
    """Newest attempt per group by id, not by payload order."""
    rows = [{"app": "a", "workflow": "W", "job": "j", "status": "completed",
             "conclusion": "success", "id": 99, "run": "9"},
            {"app": "a", "workflow": "W", "job": "j", "status": "completed",
             "conclusion": "failure", "id": 1, "run": "9"}]
    assert M.verdict(rows)["verdict"] == "GREEN", M.verdict(rows)
    rows.reverse()
    assert M.verdict(rows)["verdict"] == "GREEN", M.verdict(rows)


@test("group-by-workflow")
def _(M):
    """One workflow's green cannot mask another workflow's red on the same job name."""
    rows = [{"app": "a", "workflow": "one", "job": "packaging-smoke", "status": "completed",
             "conclusion": "success", "id": 50, "run": "1"},
            {"app": "a", "workflow": "two", "job": "packaging-smoke", "status": "completed",
             "conclusion": "failure", "id": 40, "run": "2"}]
    assert M.verdict(rows)["verdict"] == "RED", M.verdict(rows)


@test("empty-is-not-green")
def _(M):
    assert M.verdict([])["verdict"] == "NOREAD"


@test("conflict-first")
def _(M):
    w = World()
    try:
        w.prs([w.pr(7, "1" * 40, mergeable="CONFLICTING")])
        w.checks("1" * 40, [("github-actions", "unit", "completed", "failure", 1, "9")])
        w.workflows("1" * 40, {"9": "CI"})
        assert by_pr(rows_of(w))[7]["action"] == "REPAIR-CONFLICT"
    finally:
        w.cleanup()


@test("draft-first")
def _(M):
    w = World()
    try:
        w.prs([w.pr(7, "1" * 40, draft=True)])
        green(w, "1" * 40)
        r = by_pr(rows_of(w))[7]
        assert r["action"] == "WAIT:draft", r
    finally:
        w.cleanup()


@test("close-stale")
def _(M):
    w = World()
    try:
        w.prs([w.pr(7, "1" * 40, files=0)])
        green(w, "1" * 40)
        assert by_pr(rows_of(w))[7]["action"] == "CLOSE-STALE"
    finally:
        w.cleanup()


@test("authority")
def _(M):
    """An unreadable protection endpoint is an ABSTENTION — never 'no review needed'."""
    w = World()
    try:
        w.prs([w.pr(7, "1" * 40)])
        green(w, "1" * 40)
        w.no_contexts()
        r = by_pr(rows_of(w))[7]
        assert r["action"] == "WAIT:authority-unreadable", r
    finally:
        w.cleanup()


@test("attest-scopes")
def _(M):
    """Gate repo: no record is REVIEW. Rail repo: no record is not a defect."""
    w = World()
    try:
        w.prs([w.pr(7, "1" * 40)])
        green(w, "1" * 40)
        assert by_pr(rows_of(w))[7]["action"] == "REVIEW"
        w.contexts(["pipeline-compliance"])          # a rail repo
        assert by_pr(rows_of(w))[7]["action"] == "LAND"
    finally:
        w.cleanup()


@test("at-head")
def _(M):
    w = World()
    try:
        w.prs([w.pr(7, "1" * 40)])
        green(w, "1" * 40)
        w.record(7, "1" * 40)
        r = by_pr(rows_of(w))[7]
        assert r["action"] == "LAND" and r["fidelity"] == "at-head", r
    finally:
        w.cleanup()


@test("carry")
def _(M):
    """Head moved, reviewed DIFF unchanged → LAND. The gate's own carried arm (recorded decision)."""
    w = World()
    try:
        w.prs([w.pr(7, "2" * 40)])
        green(w, "2" * 40)
        w.diff("c" * 64)
        w.record(7, "1" * 40, diff="c" * 64)
        r = by_pr(rows_of(w))[7]
        assert r["action"] == "LAND" and r["fidelity"] == "carried", r
    finally:
        w.cleanup()


@test("owes-review")
def _(M):
    """Head moved, diff CHANGED → WAIT with both shas, never LAND (#10104)."""
    w = World()
    try:
        w.prs([w.pr(7, "2" * 40)])
        green(w, "2" * 40)
        w.diff("d" * 64)
        w.record(7, "1" * 40, diff="c" * 64)
        r = by_pr(rows_of(w))[7]
        assert r["action"] == "WAIT:owes-review", r
        assert "111111111111" in r["reason"] and "222222222222" in r["reason"], r["reason"]
    finally:
        w.cleanup()


@test("no-digest")
def _(M):
    """ABSENCE IS NOT IDENTITY: a record with no usable digest cannot bind a moved head."""
    f = M.fidelity({"head_sha": "1" * 40, "diff_sha256": ""}, "2" * 40, lambda: (True, "c" * 64))
    assert f["state"] == "owes-review", f
    f = M.fidelity({"head_sha": "1" * 40, "diff_sha256": "not-a-digest"}, "2" * 40,
                   lambda: (True, "c" * 64))
    assert f["state"] == "owes-review", f

    def must_not_read():
        raise AssertionError("the live diff was read for a record that carries no digest")
    assert M.fidelity({"head_sha": "1" * 40, "diff_sha256": ""}, "2" * 40, must_not_read)["state"] == "owes-review"


@test("diff-unreadable")
def _(M):
    """A diff that could not be READ is a RETRY — not a re-review."""
    w = World()
    try:
        w.prs([w.pr(7, "2" * 40)])
        green(w, "2" * 40)
        w.diff("FAIL")
        w.record(7, "1" * 40, diff="c" * 64)
        r = by_pr(rows_of(w))[7]
        assert r["action"] == "WAIT:diff-unreadable", r
    finally:
        w.cleanup()


@test("short-sha")
def _(M):
    """A short recorded sha cannot bind a full head, in either direction."""
    rec = {"head_sha": "abc1234", "diff_sha256": "c" * 64}
    f = M.fidelity(rec, "abc1234" + "f" * 33, lambda: (True, "c" * 64))
    assert f["state"] == "owes-review", f


@test("marker-only")
def _(M):
    """An attestation on the PR body is not in this box's store → never LAND."""
    w = World()
    try:
        head = "1" * 40
        body = "review recorded: reviews/7.json verdict=clean @ %s diff=%s (daniel-ospina/tortoise)" % (head, "c" * 64)
        w.prs([w.pr(7, head, body=body)])
        green(w, head)
        r = by_pr(rows_of(w))[7]
        assert r["action"] == "WAIT:attested-elsewhere", r
    finally:
        w.cleanup()


@test("marker-rail")
def _(M):
    """In a RAIL repo the review marker is informational: it must not block a green, mergeable PR.

    The rail posts its own head-bound evidence and its gate does not consume a review record, so an
    attestation that lives only on another box's store is not a reason to withhold LAND there.
    """
    w = World()
    try:
        head = "1" * 40
        body = "review recorded: reviews/7.json verdict=clean @ %s diff=%s (daniel-ospina/tortoise)" % (head, "c" * 64)
        w.prs([w.pr(7, head, body=body)])
        green(w, head)
        w.contexts(["pipeline-compliance"])          # rail authority: no review gate required
        r = by_pr(rows_of(w))[7]
        assert r["action"] == "LAND", r
    finally:
        w.cleanup()


@test("flake-evidence")
def _(M):
    """RERUN-FLAKE needs the same group passing on an EARLIER attempt at the SAME head."""
    w = World()
    try:
        head = "1" * 40
        w.prs([w.pr(7, head)])
        w.record(7, head)
        w.workflows(head, {"900": "CI"})
        # attempt 1 PASSED, attempt 2 failed → flake
        w.checks(head, [("github-actions", "unit", "completed", "failure", 22, "900"),
                        ("github-actions", "unit", "completed", "success", 11, "900")])
        r = by_pr(rows_of(w))[7]
        assert r["action"] == "RERUN-FLAKE", r
        # no earlier pass → an ordinary red, and a fixer is the right action
        w.checks(head, [("github-actions", "unit", "completed", "failure", 22, "900"),
                        ("github-actions", "unit", "completed", "failure", 11, "900")])
        r = by_pr(rows_of(w))[7]
        assert r["action"] == "FIX-RED", r
        # ⛔ A CANCELLED EARLIER ATTEMPT IS NOT A PASS. `cancelled`/`stale` are non-red for the
        # VERDICT — that rule is untouched — but the claim RERUN-FLAKE prints is "PASSED on an
        # earlier attempt at this same head", and a group whose only other attempt was cancelled has
        # never been shown to work. Spending a re-run on it is a guess dressed as evidence, and both
        # consumers act on the answer: the fixer declines the head (pr-sickness.sh) and the lander
        # exits 11 WAITING instead of spending a FIX — a real red withheld from repair.
        w.checks(head, [("github-actions", "unit", "completed", "failure", 22, "900"),
                        ("github-actions", "unit", "completed", "cancelled", 11, "900")])
        r = by_pr(rows_of(w))[7]
        assert r["action"] == "FIX-RED", r
        assert "passed on an earlier attempt" not in r["reason"], r
        w.checks(head, [("github-actions", "unit", "completed", "failure", 22, "900"),
                        ("github-actions", "unit", "completed", "stale", 11, "900")])
        r = by_pr(rows_of(w))[7]
        assert r["action"] == "FIX-RED", r
        # ⛔ BOTH DIRECTIONS OF THE PAIR. `passing_attempt` is computed twice — on the row that opens
        # the group and on every later attempt — and `read_check_rows` preserves stream order, so an
        # earlier CANCELLED row can arrive FIRST. Pinning only the red-first order left the opening
        # arm unpinned (revert it alone and the suite stayed green while the action flipped to
        # RERUN-FLAKE), which is the same defect wearing the other row order.
        w.checks(head, [("github-actions", "unit", "completed", "cancelled", 11, "900"),
                        ("github-actions", "unit", "completed", "failure", 22, "900")])
        r = by_pr(rows_of(w))[7]
        assert r["action"] == "FIX-RED", r
        assert "passed on an earlier attempt" not in r["reason"], r
    finally:
        w.cleanup()


@test("no-check-surface")
def _(M):
    """An empty — but successfully READ — check surface is WAIT:no-check-surface, never LAND.

    ⛔ This arm and `in-flight` are the two answers that stand between "nothing was read yet" and
    LAND. Deleting either used to leave the suite 26/26 green, so the PR's own claim ("every rule,
    reverted, must redden") did not cover them.
    """
    w = World()
    try:
        head = "1" * 40
        w.prs([w.pr(7, head)])
        w.record(7, head)
        w.checks(head, [])
        w.workflows(head, {})
        r = by_pr(rows_of(w))[7]
        assert r["action"] == "WAIT:no-check-surface", r
        # …and the reason is the EMPTY SURFACE's own, not the "could not be read" one: a surface that
        # was read and is empty must not be reported as unread (the reader would go looking for a
        # permissions problem that does not exist).
        assert "empty surface" in r["reason"], r
        # ⛔ THE OTHER DIRECTION, which is the one that costs a diagnosis: a surface that could NOT be
        # read must never borrow the empty-surface reason. Deleting `read_ok = False` used to leave
        # the suite green while the failed read was relabelled "empty surface" — a permissions/token
        # problem hidden behind "there is nothing there".
        os.remove(os.path.join(w.dir, "checks-%s.1.json" % head))
        r = by_pr(rows_of(w))[7]
        assert r["action"] == "WAIT:no-check-surface", r
        assert "could not be read" in r["reason"], r
        assert "empty surface" not in r["reason"], r
    finally:
        w.cleanup()


@test("in-flight")
def _(M):
    """A check surface with something still running is WAIT:in-flight, never LAND."""
    w = World()
    try:
        head = "1" * 40
        w.prs([w.pr(7, head)])
        w.record(7, head)
        w.checks(head, [("github-actions", "unit", "in_progress", "", 11, "900")])
        w.workflows(head, {"900": "CI"})
        r = by_pr(rows_of(w))[7]
        assert r["action"] == "WAIT:in-flight", r
        assert "in flight" in r["reason"], r
    finally:
        w.cleanup()


@test("mergeable-unknown")
def _(M):
    """A mergeability GitHub has not computed yet is a WAIT, never a guessed MERGEABLE."""
    ev = {"changed_files": 3, "is_draft": False, "mergeable": "UNKNOWN",
          "checks": {"verdict": "GREEN", "groups": 1, "red": [], "in_flight": 0, "reason": ""},
          "authority": "gate", "review_required": True, "attest": None,
          "fidelity": {"state": "absent", "detail": ""}}
    assert M.action_for(ev)[0] == "WAIT:mergeable-unknown", M.action_for(ev)
    # `null` is the same answer — the endpoint has not computed it, which is not "mergeable".
    ev["mergeable"] = None
    assert M.action_for(ev)[0] == "WAIT:mergeable-unknown", M.action_for(ev)


@test("queued-unreadable")
def _(M):
    """An UNREADABLE queue renders `?`, never `0` — the difference the code's own comment claims.

    The `0` is indistinguishable from a genuinely empty queue, and this table is the operator's only
    queue reading (its count is also `--suppress`'s `before=` figure).
    """
    w = World()
    try:
        head = "1" * 40
        w.prs([w.pr(7, head)])
        green(w, head)
        w.record(7, head)
        os.remove(os.path.join(w.dir, "queued-1.json"))     # the inventory read now fails
        rows = rows_of(w)
        assert rows and rows[0]["queued_known"] is False, rows
        table = M.render_table(rows, REPO)
        assert "? queued runs on ? PRs" in table, table
        assert "Q is UNKNOWN on every row, not 0" in table, table
        assert "\t0\t" not in table.splitlines()[-1], table
        # CONTROL: a queue that was READ and is empty still renders 0 (the arm is not "never count").
        w.queued([])
        rows = rows_of(w)
        assert rows[0]["queued_known"] is True, rows
        assert " 0 queued runs on 0 PRs" in M.render_table(rows, REPO), M.render_table(rows, REPO)
    finally:
        w.cleanup()


@test("empty-body-is-a-read-error")
def _(M):
    """An EMPTY or TRUNCATED body is a FAILED READ — never "this surface is empty".

    `gh` exits 0 with no body when a token/proxy layer eats the answer, and a body cut mid-object is a
    truncated read. Both used to arrive as `[]` (the same `empty surface` reason a genuinely
    check-free PR gets — a failed read dressed as "no checks configured") or as an uncaught
    `JSONDecodeError` (a traceback and exit 1 instead of the documented exit 2 + named reason).
    """
    d = tempfile.mkdtemp(prefix="prstate-body-")
    try:
        gh = os.path.join(d, "gh")
        body = os.path.join(d, "body")
        with open(gh, "w") as f:
            f.write('#!/usr/bin/env bash\ncat "$(dirname "$0")/body"\nexit 0\n')
        os.chmod(gh, 0o755)
        prev = os.environ.get("PR_STATE_GH")
        os.environ["PR_STATE_GH"] = gh
        try:
            for content, why in (("", "an EMPTY body"),
                                 ('{"total_count": 1, "check_runs": [{"id": 5', "a TRUNCATED body")):
                with open(body, "w") as f:
                    f.write(content)
                try:
                    got = M.gh_stream(["api", "repos/o/r/commits/abc/check-runs"])
                except M.ReadError as e:
                    assert "not JSON" in str(e) or "EMPTY" in str(e), e
                else:
                    raise AssertionError("%s was read as %r — a failed read must not look like an "
                                         "empty surface" % (why, got))
            # CONTROL: a readable page still returns its object (the arm is not "always raise").
            with open(body, "w") as f:
                f.write('{"total_count": 0, "check_runs": []}')
            assert M.gh_stream(["api", "repos/o/r/commits/abc/check-runs"]) == [
                {"total_count": 0, "check_runs": []}], "a readable page must still be read"
        finally:
            if prev is None:
                os.environ.pop("PR_STATE_GH", None)
            else:
                os.environ["PR_STATE_GH"] = prev
    finally:
        shutil.rmtree(d, ignore_errors=True)


@test("suppress-unknown-queue")
def _(M):
    """`--suppress` over an unreadable queue cancels nothing and SAYS SO (exit 2) — never `cancelled=0`, exit 0."""
    w = World()
    try:
        head = "1" * 40
        w.prs([w.pr(7, head)])
        w.checks(head, [("github-actions", "unit", "completed", "failure", 11, "900")])
        w.workflows(head, {"900": "CI"})
        os.remove(os.path.join(w.dir, "queued-1.json"))      # the inventory cannot be read
        rc, out, err = w.cli("--repo", REPO, "--suppress")
        assert rc == 2, (rc, out, err)
        assert "NOTHING was cancelled" in err, err
        assert w.cancelled_ids() == [], w.cancelled_ids()
        # CONTROL: with a readable inventory the pass still runs and still exits 0.
        w.queued([(head, 4242, "CI")])
        rc, out, err = w.cli("--repo", REPO, "--suppress", "--dry-run")
        assert rc == 0, (rc, out, err)
        assert "suppress (dry-run): PR #7" in out, out
    finally:
        w.cleanup()


@test("workflow-listing-unreadable")
def _(M):
    """A failed read of the head's RUN LISTING is a failed surface read, not "no workflow names".

    `resolve_workflows` used to answer `{}` on a read failure. `{}` is the "nothing is named" answer,
    which puts every ATTEMPT of a job in its own `?unknown:<run>` group — the newest attempt stops
    winning, so a job whose newest attempt PASSED is reddened by an older failing one and a fixer is
    dispatched at a green head (FIX-RED, a burned FIX round), while the reason attributes the newest
    verdict to the older run.
    """
    w = World()
    try:
        head = "1" * 40
        w.prs([w.pr(7, head)])
        green(w, head)
        w.record(7, head)
        # the run listing is the ONE read that fails (the stub cannot parse the fixture → rc 1)
        with open(os.path.join(w.dir, "runs-%s.json" % head), "w") as f:
            f.write("not json")
        r = by_pr(rows_of(w))[7]
        assert r["action"] == "WAIT:no-check-surface", r
        assert "could not be read" in r["reason"], r
    finally:
        w.cleanup()


@test("authority-not-a-list")
def _(M):
    """A protection answer that is not a LIST is an ABSTENTION, never "no required checks".

    `null`, a bare string, an HTML error page — all answer 200 and none of them is the documented
    payload. Reading them as an empty context list classifies a review-GATED repo as `rail`, drops
    `review_required`, and lets an unattested PR report LAND. `[]` is a legitimate "no required
    checks" and must keep answering `rail`.
    """
    for body in (None, "oops", {"unexpected": 1}):
        w = World()
        try:
            head = "1" * 40
            w.write("contexts.json", body)
            w.prs([w.pr(7, head)])
            green(w, head)
            r = by_pr(rows_of(w))[7]
            assert r["action"] == "WAIT:authority-unreadable", (body, r)
        finally:
            w.cleanup()
    # CONTROL: an empty LIST is "no required checks" — a rail repo, and no review record is owed.
    w = World()
    try:
        head = "1" * 40
        w.write("contexts.json", [])
        w.prs([w.pr(7, head)])
        green(w, head)
        r = by_pr(rows_of(w))[7]
        assert r["action"] == "LAND", r
    finally:
        w.cleanup()


@test("action-needs-only")
def _(M):
    """`--action` without `--only` REFUSES: the row it would print is another PR's answer."""
    w = World()
    try:
        head = "1" * 40
        w.prs([w.pr(7, head)])
        green(w, head)
        w.record(7, head)
        rc, out, err = w.cli("--repo", REPO, "--action")
        assert rc == 2, (rc, out, err)
        assert "--only" in err, err
        assert out.strip() == "", out
        # CONTROL: with `--only` the seam still answers its one TSV row on exit 0. (`--only` reads the
        # PR with `gh pr view`, so that is the fixture this arm needs.)
        w.view(w.pr(7, head))
        rc, out, err = w.cli("--repo", REPO, "--action", "--only", "7")
        assert rc == 0, (rc, out, err)
        assert out.split("\t")[0] in ("LAND", "REVIEW"), out
    finally:
        w.cleanup()


@test("flake-bound")
def _(M):
    """A group already retried is a defect, not another re-run."""
    w = World()
    try:
        head = "1" * 40
        w.prs([w.pr(7, head)])
        w.record(7, head)
        w.workflows(head, {"900": "CI"})
        w.checks(head, [("github-actions", "unit", "completed", "failure", 33, "900"),
                        ("github-actions", "unit", "completed", "success", 22, "900"),
                        ("github-actions", "unit", "completed", "failure", 11, "900")])
        r = by_pr(rows_of(w))[7]
        assert r["action"] == "FIX-RED" and "flaked" in r["reason"], r
    finally:
        w.cleanup()


@test("inherited-red")
def _(M):
    """A red that main's head also carries is not this tree's to fix."""
    w = World()
    try:
        head = "1" * 40
        w.prs([w.pr(7, head)])
        w.record(7, head)
        w.workflows(head, {"900": "drift-guard"})
        w.checks(head, [("github-actions", "drift-guard", "completed", "failure", 11, "900")])
        w.checks(w.main_sha, [("github-actions", "drift-guard", "completed", "failure", 5, "77")])
        w.workflows(w.main_sha, {"77": "drift-guard"})
        r = by_pr(rows_of(w))[7]
        assert r["action"] == "WAIT:inherited-red", r
    finally:
        w.cleanup()


@test("suppress-in-flight")
def _(M):
    """Only `queued` runs are cancelled: a run re-read as in_progress is NEVER cancelled."""
    w = World()
    try:
        head = "1" * 40
        w.prs([w.pr(7, head)])
        w.checks(head, [("github-actions", "unit", "completed", "success", 11, "900")])
        w.workflows(head, {"900": "CI"})
        w.queued([(head, "501", "CI"), (head, "502", "CI")])
        w.run_status("501", "queued")
        w.run_status("502", "in_progress")          # it started between the read and the cancel
        rc, out, err = w.cli("--repo", REPO, "--suppress")
        assert rc == 0, (rc, err)
        assert w.cancelled_ids() == ["501"], w.cancelled_ids()
        assert "502" in out and "NOT cancelled" in out, out
    finally:
        w.cleanup()


@test("suppress-scope")
def _(M):
    """Only REVIEW / REPAIR-CONFLICT / FIX-RED heads are suppressed; a WAIT row keeps its CI."""
    w = World()
    try:
        h1, h2 = "1" * 40, "2" * 40
        w.prs([w.pr(7, h1), w.pr(8, h2)])
        green(w, h1)
        w.checks(h2, [("github-actions", "unit", "in_progress", None, 12, "901")])
        w.workflows(h2, {"901": "CI"})
        w.queued([(h1, "601", "CI"), (h2, "602", "CI")])
        w.run_status("601", "queued")
        w.run_status("602", "queued")
        w.diff("e" * 64)
        w.record(7, "3" * 40, diff="c" * 64)        # PR 7 is attested at another head → WAIT
        rows = by_pr(rows_of(w))
        assert rows[7]["action"] == "WAIT:owes-review", rows[7]
        assert rows[8]["action"] == "REVIEW", rows[8]
        rc, out, err = w.cli("--repo", REPO, "--suppress")
        assert rc == 0, (rc, err)
        assert w.cancelled_ids() == ["602"], w.cancelled_ids()
    finally:
        w.cleanup()


@test("suppress-ledger")
def _(M):
    """Every cancelled run is recorded, and `--cancelled` prints its re-trigger command."""
    w = World()
    try:
        head = "1" * 40
        w.prs([w.pr(7, head)])
        green(w, head)
        w.queued([(head, "701", "CI")])
        w.run_status("701", "queued")
        rc, out, err = w.cli("--repo", REPO, "--suppress")
        assert rc == 0, (rc, err)
        with open(w.ledger) as f:
            led = [json.loads(l) for l in f if l.strip()]
        assert led and led[0]["run_id"] == "701" and led[0]["pr"] == 7, led
        rc, out, err = w.cli("--cancelled")
        assert rc == 0 and "gh run rerun 701" in out, out
    finally:
        w.cleanup()


@test("unreadable-board")
def _(M):
    """An unreadable listing exits 2 and prints NO table — never 'no open PRs'."""
    w = World()
    try:
        w.write("prs.json", [])                  # the stub answers `pr list` from this fixture…
        os.unlink(os.path.join(w.dir, "prs.json"))   # …and a MISSING fixture is a FAILED read
        rc, out, err = w.cli("--repo", REPO)
        assert rc == 2, (rc, out)
        assert "could not be made" in err, err
        assert "open PRs" not in out, out
    finally:
        w.cleanup()


@test("pagination")
def _(M):
    """`--paginate` emits one object per PAGE; two pages must be read as one surface."""
    w = World()
    try:
        head = "1" * 40
        w.prs([w.pr(7, head)])
        w.record(7, head)
        w.workflows(head, {"900": "CI", "901": "CI"})
        w.checks(head, [("github-actions", "a", "completed", "success", 11, "900"),
                        ("github-actions", "b", "completed", "failure", 12, "901")], split=True)
        r = by_pr(rows_of(w))[7]
        assert r["groups"] == 2, r
        assert r["action"] == "FIX-RED" and r["red_groups"] == ["CI/b"], r
    finally:
        w.cleanup()


# ── the mutations: (test, exact old text, exact new text, what reverting the rule looks like) ──
MUTATIONS = [
    ("cancelled-not-red",
     'NONRED = GREEN | {"cancelled", "stale"}', 'NONRED = GREEN',
     "a cancelled run is treated as a failure again"),
    ("unknown-is-red",
     'if g["conclusion"] in NONRED:\n            continue',
     'if g["conclusion"] in NONRED or g["conclusion"] not in ("failure", "timed_out", "action_required"):\n            continue',
     "conclusions become a known-bad allow-list, so an unnamed one falls through"),
    ("newest-attempt",
     'if cid >= g["id"]:', 'if False:',
     "the first row seen wins instead of the newest attempt by id"),
    ("group-by-workflow",
     'key = ((r.get("app") or "").strip(), workflow, (r.get("job") or "").strip())',
     'key = ((r.get("app") or "").strip(), "", (r.get("job") or "").strip())',
     "groups are keyed without the workflow, so one workflow masks another"),
    ("empty-is-not-green",
     'return {"verdict": "NOREAD", "groups": 0, "red": [], "in_flight": 0,',
     'return {"verdict": "GREEN", "groups": 0, "red": [], "in_flight": 0,',
     "an empty surface reads as green"),
    ("conflict-first",
     'if ev.get("mergeable") == "CONFLICTING":',
     'if ev.get("mergeable") == "CONFLICTING" and checks["verdict"] == "GREEN":',
     "a conflicting PR is only reported when its stale checks happen to be green"),
    ("draft-first",
     'if ev.get("is_draft"):', 'if False:',
     "a draft is routed to REVIEW/FIX-RED work that cannot make it mergeable"),
    ("close-stale",
     'if ev.get("changed_files") == 0:', 'if False:',
     "an empty diff is routed to review and CI"),
    ("authority",
     'if ev.get("authority") in (None, "unreadable"):', 'if False:',
     "an unreadable protection endpoint answers 'no review required'"),
    ("attest-scopes",
     'if review_required:', 'if False:',
     "a gate repo with no record is called ready"),
    ("at-head",
     'return "LAND", "attested %s + mergeable + no real red on %d groups" % (state, checks["groups"])',
     'return "WAIT:owes-review", "never land a ready PR"',
     "a fully attested, green, mergeable PR is refused (the over-block direction)"),
    ("carry", 'if got == digest:', 'if False:',
     "a moved head with an unchanged diff is refused (reverses the recorded carry decision)"),
    ("no-digest", '''    if not HEX64.match(digest):
        # ABSENCE IS NOT IDENTITY''', '''    if not HEX64.match(digest):
        return {"state": "at-head", "detail": "no digest, so assumed bound"}
    if False:
        # ABSENCE IS NOT IDENTITY''',
     "a record with no diff digest is assumed to bind the moved head"),
    ("diff-unreadable",
     'if fid["state"] == "diff-unreadable":', 'if False:',
     "an unreadable diff is reported as a changed diff (sends a lane to re-review)"),
    ("short-sha",
     'if not FULL_SHA.match(attested):', 'if False:',
     "a short recorded sha is allowed to bind a full head"),
    ("marker-only",
     'if review_required and att is not None and att.get("source") == "marker" \\',
     'if False and att.get("source") == "marker" \\',
     "an attestation recorded on another box reads as ready here"),
    ("marker-rail", 'if review_required and att is not None and att.get("source") == "marker" \\',
     'if att is not None and att.get("source") == "marker" \\',
     "a marker-only attestation blocks a rail repo that does not consume records at all"),
    ("flake-evidence",
     'flaked = [r for r in reds if r["passing_attempt"] and r["attempts"] < 3]',
     'flaked = [r for r in reds if r["attempts"] > 1]',
     "any red with more than one attempt is called a flake, with no evidence it ever passed"),
    ("flake-bound",
     'and r["attempts"] < 3', '',
     "a group that has already been retried gets another re-run, forever"),
    ("inherited-red",
     'if inherited and len(inherited) == len(reds):', 'if False:',
     "a fixer is dispatched at a red that main also carries"),
    ("suppress-in-flight",
     'if status != "queued":', 'if False:',
     "a run that has already STARTED is cancelled"),
    ("suppress-scope",
     'todo = [r for r in rows if r["action"] in SUPPRESS_ACTIONS]',
     'todo = [r for r in rows if True]',
     "every queued run is cancelled, including heads that are not about to change"),
    ("suppress-ledger",
     'fh.write(json.dumps(dict(c, repo=repo, ts=int(time.time()),',
     'fh.write(json.dumps(dict(ts=int(time.time()),',
     "the cancelled run id is not recorded, so re-trigger stops being mechanical"),
    ("unreadable-board",
     '''    except ReadError as e:
        # ⛔ AN UNREADABLE BOARD IS NOT AN EMPTY BOARD. Nothing is reported as "no open PRs".
        print("pr-state: the pass could not be made — %s" % e, file=sys.stderr)
        return 2''',
     '''    except ReadError as e:
        rows = []''',
     "an unreadable board is reported as a table with no PRs (exit 0)"),
    ("pagination",
     'obj, i = dec.raw_decode(out, i)',
     'obj, i = dec.raw_decode(out, i); items = [] if not items else items; break',
     "only the first page of a paginated read is used"),
    ("flake-evidence",
     '            if concl in GREEN:\n                g["passing_attempt"] = True',
     '            if concl in NONRED:\n                g["passing_attempt"] = True',
     "a CANCELLED earlier attempt counts as a pass, so a never-passing red is called a flake"),
    ("no-check-surface",
     '    if checks["verdict"] == "NOREAD":\n        return "WAIT:no-check-surface", checks["reason"]',
     '    if False:\n        return "WAIT:no-check-surface", checks["reason"]',
     "an empty check surface falls through to LAND (a missing check read as green)"),
    ("in-flight",
     '    if checks["verdict"] == "WAIT":',
     '    if False:',
     "a still-running check surface falls through to LAND"),
    ("mergeable-unknown",
     '    if ev.get("mergeable") in (None, "", "UNKNOWN"):',
     '    if False:',
     "an uncomputed mergeability is guessed into the merge path"),
    ("queued-unreadable",
     '        queued_by_head = None',
     '        queued_by_head = {}',
     "an unreadable queue renders as 0 queued runs (indistinguishable from an empty one)"),
    ("action-needs-only",
     '        if only is None:',
     '        if False:',
     "`--action` without `--only` answers with another PR's row"),
    ("no-check-surface",
     '    if read_ok:\n        # ⛔ A SURFACE THAT WAS READ AND IS EMPTY IS STILL `verdict([])`',
     '    if rows:\n        # ⛔ A SURFACE THAT WAS READ AND IS EMPTY IS STILL `verdict([])`',
     "an empty surface is reported as unread, so the reader chases a permissions problem"),
    ("flake-evidence",
     '"passing_attempt": (r.get("conclusion") or "").strip().lower() in GREEN,',
     '"passing_attempt": (r.get("conclusion") or "").strip().lower() in NONRED,',
     "the row that OPENS a group counts a cancelled attempt as a pass (same defect, other row order)"),
    ("no-check-surface",
     '            read_ok = False',
     '            read_ok = True',
     "a surface that could not be read is relabelled 'empty surface'"),
    ("queued-unreadable",
     '("%d" % len(with_q)) if queued_known else "?"',
     '("%d" % len(with_q))',
     "an unreadable inventory renders the PR count as a definite 0"),
    ("empty-body-is-a-read-error",
     '    if not (out or "").strip():\n        raise ReadError(',
     '    if False:\n        raise ReadError(',
     "an empty body is read as an empty surface (a failed read dressed as 'no checks configured')"),
    ("empty-body-is-a-read-error",
     '        except ValueError as e:',
     '        except ZeroDivisionError as e:',
     "a truncated body escapes as a JSONDecodeError traceback instead of a named ReadError"),
    ("suppress-unknown-queue",
     '    if rows and not all(r.get("queued_known", True) for r in rows):',
     '    if False:',
     "a suppression pass that could enumerate NOTHING reports success (cancelled=0, exit 0)"),
    ("workflow-listing-unreadable",
     '"repos/%s/actions/runs?head_sha=%s&per_page=100" % (repo, sha)])\n    except ReadError:\n        return None',
     '"repos/%s/actions/runs?head_sha=%s&per_page=100" % (repo, sha)])\n    except ReadError:\n        return {}',
     "a failed run listing is read as 'nothing is named', so every attempt becomes its own group"),
    ("authority-not-a-list",
     '    elif not isinstance(ctx, list):',
     '    elif False:',
     "a non-list protection answer is read as 'no required checks', so a gated repo lands unattested"),
    ("workflow-listing-unreadable",
     '            if names is None:',
     '            if False:',
     "the evidence_for guard lets an unresolved workflow map through to the grouping"),
]


def run_selected(names=None):
    M = load_module()
    failures = 0
    for name, fn in TESTS:
        if names and name not in names:
            continue
        try:
            fn(M)
            print("ok   %s" % name)
        except AssertionError as e:
            failures += 1
            print("FAIL %s — %s" % (name, e))
        except Exception as e:                                   # noqa: BLE001
            failures += 1
            print("ERROR %s — %s: %s" % (name, type(e).__name__, e))
    return failures


def run_mutations():
    src = open(MODULE).read()
    bad = 0
    for (name, old, new, why) in MUTATIONS:
        if src.count(old) != 1:
            print("BAD MUTATION %-18s — the anchor appears %d times (must be exactly 1)" % (name, src.count(old)))
            bad += 1
            continue
        tmp = tempfile.mkdtemp(prefix="prstate-mut-")
        path = os.path.join(tmp, "pr_state.py")
        with open(path, "w") as f:
            f.write(src.replace(old, new, 1))
        env = dict(os.environ)
        env["PR_STATE_MODULE"] = path
        p = subprocess.run([sys.executable, os.path.abspath(__file__), "--only", name],
                           capture_output=True, text=True, env=env)
        if p.returncode == 0:
            print("FAIL mutation %-18s — the paired test still PASSED with the rule reverted (%s)" % (name, why))
            bad += 1
        else:
            print("ok   mutation %-18s — red, as it must be (%s)" % (name, why))
        shutil.rmtree(tmp, ignore_errors=True)
    return bad


def main(argv):
    args = argv[1:]
    if "--list" in args:
        for name, _ in TESTS:
            print(name)
        return 0
    if "--only" in args:
        return 1 if run_selected({args[args.index("--only") + 1]}) else 0
    failures = run_selected()
    print("\n%d test(s), %d failure(s)" % (len(TESTS), failures))
    if "--mutations" in args:
        print("\n── mutations ──")
        muts = run_mutations()
        total = len(MUTATIONS)
        print("\n%d mutation(s), %d not caught" % (total, muts))
        failures += muts
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
