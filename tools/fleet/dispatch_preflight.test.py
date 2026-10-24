#!/usr/bin/env python3
"""tools/fleet/dispatch_preflight.test.py — hermetic suite for the dispatch preflight.

WHAT THIS PINS
--------------
``dispatch_preflight.py`` refuses to dispatch a lane into a worktree that has
nothing to land. The measured failure it prevents (2026-10-18): 12 of 15
dispatched worktrees sat on a HEAD that ``origin/main`` already contained, and
ALL 12 produced +0 commits — a whole lane's context spent discovering there was
nothing to do, then up to 9 h parked at 0.00 % CPU.

The three cases below are the whole contract, and the second and third exist
because a simpler tool gets them WRONG in the dangerous direction:

  * **contained HEAD** -> NO-WORK. The "sitting on main's tip" incident case.
  * **squash-merged branch** -> NO-WORK. This one carries ``ahead > 0`` with an
    EMPTY tree diff. A tool keying on the commit COUNT reports HAS-WORK here and
    re-creates the wasted lane with a bigger number to make it look productive —
    so there is a leg whose only job is to hold that distinction.
  * **dirty worktree at the base tip** -> HAS-WORK. Uncommitted/untracked
    changes ARE work to land (measured: ``retire-fork``). A false refusal here
    destroys real work; a false allow only costs an untouched worktree. The
    asymmetry is deliberate and this leg is the one that must never flip.

Unreadable states (no git, missing path, unresolvable base) exit with their OWN
code and never report HAS-WORK: a probe that cannot answer must not answer "yes".

RUN
---
    python3 tools/fleet/dispatch_preflight.test.py
    python3 tools/fleet/dispatch_preflight.test.py --red-control

RED CONTROL
-----------
A suite that cannot go red is not a pin. ``--red-control`` copies the SHIPPED
module to a temp dir, applies one textual mutation per leg, and runs the same
suite against the mutant; every mutation MUST turn its paired leg red. A
mutation the suite still passes is reported as a suite FAILURE.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent


def _module_path() -> Path:
    """The module under test — the shipped one, or a mutant (``DP_MODULE``)."""
    env = os.environ.get("DP_MODULE", "").strip()
    return Path(env) if env else HERE / "dispatch_preflight.py"


def _load():
    path = _module_path()
    import importlib.util

    spec = importlib.util.spec_from_file_location("dispatch_preflight_under_test", path)
    mod = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    spec.loader.exec_module(mod)
    return mod


def _git_env() -> dict:
    """A hermetic git environment — never the developer's global/system config.

    Without this, ``commit.gpgsign=true`` (a common local/runner setting) turns
    every fixture commit into ``rc 128 / cannot run gpg``, so all legs ERROR
    instead of reporting a verdict: a suite whose result depends on the box it
    runs on is not a pin. Dates are pinned so fixtures are reproducible.
    """
    env = dict(os.environ)
    env["GIT_CONFIG_GLOBAL"] = os.devnull
    env["GIT_CONFIG_SYSTEM"] = os.devnull
    env["GIT_CONFIG_NOSYSTEM"] = "1"
    env["GIT_AUTHOR_NAME"] = env["GIT_COMMITTER_NAME"] = "t"
    env["GIT_AUTHOR_EMAIL"] = env["GIT_COMMITTER_EMAIL"] = "t@t"
    env["GIT_AUTHOR_DATE"] = env["GIT_COMMITTER_DATE"] = "2026-01-01T00:00:00 +0000"
    return env


def _git(repo: Path, *args: str) -> str:
    p = subprocess.run(
        ["git", "-C", str(repo), *args], capture_output=True, text=True, env=_git_env()
    )
    if p.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)} failed in {repo}: {p.stderr}")
    return p.stdout.strip()


def _write(repo: Path, rel: str, body: str) -> None:
    f = repo / rel
    f.parent.mkdir(parents=True, exist_ok=True)
    f.write_text(body)


def _commit(repo: Path, msg: str, allow_empty: bool = False) -> str:
    _git(repo, "add", "-A")
    extra = ["--allow-empty"] if allow_empty else []
    _git(repo, "commit", "-qm", msg, *extra)
    return _git(repo, "rev-parse", "HEAD")


def _squash_shape(repo: Path) -> tuple:
    """Build a REAL squash-merge shape; returns (feature_sha, squash_sha).

    The naive fixture — two ``--allow-empty`` commits — yields ``ahead > 0`` with
    an EMPTY merge-base diff, which is NOT what a squash merge leaves behind. A
    squash merge puts ``merge-base`` at the FORK POINT, so the branch's own delta
    is NON-EMPTY while ``tree(HEAD) == tree(base)``. A fixture built the naive
    way therefore PASSES against a tool that diffs only against the merge-base —
    which is precisely the defect it was supposed to pin.

    Built with plumbing (``commit-tree``) so it needs no branch switching and
    holds on any git version.
    """
    base = _git(repo, "rev-parse", "HEAD")
    _write(repo, "work.txt", "real work\n")
    feature = _commit(repo, "real work")            # HEAD = the unsquashed branch
    tree = _git(repo, "rev-parse", f"{feature}^{{tree}}")
    # The same tree as a commit on base — what `git merge --squash` leaves.
    p = subprocess.run(
        ["git", "-C", str(repo), "commit-tree", tree, "-p", base, "-m", "squash of feature"],
        capture_output=True, text=True, env=_git_env(),
    )
    if p.returncode != 0:
        raise RuntimeError(f"commit-tree failed: {p.stderr}")
    squash = p.stdout.strip()
    _git(repo, "update-ref", "refs/remotes/origin/main", squash)
    return feature, squash


def _fixture(root: Path) -> Path:
    """A repo whose ``origin/main`` is a real remote-tracking ref, like the fleet.

    The base is materialised as ``refs/remotes/origin/main`` rather than a local
    ``main`` branch because that is the token every caller passes, and resolving
    the caller's token verbatim is part of the contract.
    """
    repo = root / "repo"
    repo.mkdir()
    _git(repo, "init", "-q", "-b", "main")
    _write(repo, "base.txt", "base\n")
    _commit(repo, "base")
    base = _git(repo, "rev-parse", "HEAD")
    _git(repo, "update-ref", "refs/remotes/origin/main", base)
    return repo


class _PreflightTest(unittest.TestCase):
    def setUp(self) -> None:
        self.mod = _load()
        self.tmp = Path(tempfile.mkdtemp(prefix="dp-test-"))
        self.repo = _fixture(self.tmp)

    def tearDown(self) -> None:
        shutil.rmtree(self.tmp, ignore_errors=True)

    def verdict(self, base: str = "origin/main") -> dict:
        return self.mod.evaluate(str(self.repo), base)


class ContainedHeadIsNoWork(_PreflightTest):
    """The incident case: HEAD is already in the base, nothing is dirty."""

    def test_clean_worktree_at_base_tip_is_no_work(self):
        res = self.verdict()
        self.assertEqual(res["verdict"], "NO-WORK", res)
        self.assertEqual(res["ahead"], 0)
        self.assertFalse(res["own_delta"])
        self.assertFalse(res["tree_differs_from_base"])
        self.assertEqual(res["dirty"], 0)

    def test_exit_code_is_its_own_three(self):
        rc = self.mod.main(["--quiet", str(self.repo)])
        self.assertEqual(rc, 3)

    def test_detached_head_at_the_base_tip_is_still_no_work(self):
        # A worktree parked on a detached base commit has no branch, but the
        # question is about CONTENT, so the verdict must not change.
        _git(self.repo, "checkout", "-q", "--detach", "origin/main")
        self.assertEqual(self.verdict()["verdict"], "NO-WORK")


class SquashMergedIsNoWork(_PreflightTest):
    """``ahead > 0`` with an IDENTICAL tree to the base — a real squash merge."""

    def test_real_squash_merge_is_no_work(self):
        feature, squash = _squash_shape(self.repo)
        self.assertEqual(_git(self.repo, "rev-parse", f"{feature}^{{tree}}"),
                         _git(self.repo, "rev-parse", f"{squash}^{{tree}}"),
                         "fixture must ship the same tree as the base")
        res = self.verdict()
        self.assertGreater(res["ahead"], 0, "fixture must be ahead to exercise the trap")
        # The property that makes this a REAL squash and not a no-op commit:
        # merge-base sits at the fork point, so the branch's own delta exists.
        self.assertTrue(res["own_delta"], res)
        self.assertFalse(res["tree_differs_from_base"], res)
        self.assertEqual(res["verdict"], "NO-WORK", res)
        self.assertEqual(self.mod.main(["--quiet", str(self.repo)]), 3)

    def test_noop_commits_are_also_no_work(self):
        # The other way to be ahead with no content: commits that change nothing.
        _commit(self.repo, "no-op", allow_empty=True)
        res = self.verdict()
        self.assertGreater(res["ahead"], 0)
        self.assertEqual(res["verdict"], "NO-WORK", res)

    def test_a_real_commit_in_the_branch_is_has_work(self):
        # The control for the legs above: same shape (ahead > 0) but a REAL diff.
        _write(self.repo, "new.txt", "content\n")
        _commit(self.repo, "real change")
        res = self.verdict()
        self.assertTrue(res["own_delta"])
        self.assertTrue(res["tree_differs_from_base"])
        self.assertEqual(res["verdict"], "HAS-WORK", res)
        self.assertEqual(self.mod.main(["--quiet", str(self.repo)]), 0)


class DirtyWorktreeIsHasWork(_PreflightTest):
    """Never refuse work that exists only as uncommitted changes."""

    def test_modified_tracked_file_at_base_tip_is_has_work(self):
        _write(self.repo, "base.txt", "changed but not committed\n")
        res = self.verdict()
        self.assertEqual(res["dirty"], 1)
        self.assertEqual(res["verdict"], "HAS-WORK", res)
        self.assertEqual(self.mod.main(["--quiet", str(self.repo)]), 0)

    def test_untracked_file_at_base_tip_is_has_work(self):
        _write(self.repo, "brand-new.md", "doc\n")
        res = self.verdict()
        self.assertEqual(res["dirty"], 1)
        self.assertEqual(res["verdict"], "HAS-WORK", res)

    def test_untracked_file_survives_status_showuntrackedfiles_no(self):
        # `git status --porcelain` honours status.showUntrackedFiles; a value of
        # `no` hides untracked files and would silently flip this to NO-WORK —
        # the false refusal that destroys real work. The tool must pass
        # --untracked-files=normal explicitly to override an ambient config.
        _write(self.repo, "brand-new.md", "doc\n")
        env = _git_env()
        cfg = self.tmp / "gitconfig"
        cfg.write_text("[status]\n\tshowUntrackedFiles = no\n")
        env["GIT_CONFIG_GLOBAL"] = str(cfg)
        p = subprocess.run(
            [sys.executable, str(_module_path()), "--json", str(self.repo)],
            capture_output=True, text=True, env=env,
        )
        payload = json.loads(p.stdout)
        self.assertEqual(payload["dirty"], 1, payload)
        self.assertEqual(payload["verdict"], "HAS-WORK", payload)


class UnreadableFailsClosed(_PreflightTest):
    """A probe that cannot answer must never answer 'there is work'."""

    def test_missing_path_is_unreadable(self):
        res = self.mod.evaluate(str(self.tmp / "nope"), "origin/main")
        self.assertEqual(res["verdict"], "UNREADABLE", res)

    def test_non_git_directory_is_unreadable(self):
        plain = self.tmp / "plain"
        plain.mkdir()
        self.assertEqual(self.mod.evaluate(str(plain), "origin/main")["verdict"], "UNREADABLE")

    def test_unresolvable_base_is_unreadable_not_has_work(self):
        res = self.verdict(base="origin/does-not-exist")
        self.assertEqual(res["verdict"], "UNREADABLE", res)
        self.assertEqual(self.mod.main(["--quiet", "--base", "origin/does-not-exist", str(self.repo)]), 4)

    def test_all_unreadable_paths_exit_four(self):
        plain = self.tmp / "plain2"
        plain.mkdir()
        self.assertEqual(self.mod.main(["--quiet", str(plain)]), 4)


class JsonSurface(_PreflightTest):
    def test_json_carries_the_evidence_not_just_the_verdict(self):
        out = subprocess.run(
            [sys.executable, str(_module_path()), "--json", str(self.repo)],
            capture_output=True, text=True,
        )
        payload = json.loads(out.stdout)
        for key in ("worktree", "verdict", "head", "base_sha", "ahead",
                    "own_delta", "tree_differs_from_base", "dirty", "why"):
            self.assertIn(key, payload)
        self.assertEqual(payload["verdict"], "NO-WORK")
        # The refusal must be readable: a verdict with no reason is unactionable.
        self.assertTrue(any("nothing to land" in w for w in payload["why"]), payload["why"])


MUTATIONS = [
    # (name, [(before, after), ...], the leg name that MUST go red)
    (
        # NB: "own_delta = bool(ahead)" was tried here and REMOVED — with the two-diff
        # predicate it is behaviourally EQUIVALENT (ahead > 0 implies a non-empty
        # own delta once the tree check is also present), so it changed no verdict
        # and the red control correctly refused to call it pinned. An equivalent
        # mutation is a false alarm, not a missing pin.
        "conflate diff rc=1 with an error (every diff becomes UNREADABLE)",
        [
            ('    if rc == 1:\n        return True\n    return None',
             '    if rc == 1:\n        return None\n    return None'),
        ],
        "SquashMergedIsNoWork",
    ),
    (
        "diff only against the merge-base (a real squash reads as HAS-WORK)",
        [('differs = _diff_is_nonempty(worktree, base_sha, head)', 'differs = True')],
        "SquashMergedIsNoWork",
    ),
    (
        "drop the own-delta check (every contained HEAD looks like work)",
        [('own_delta = _diff_is_nonempty(worktree, merge_base, head)', 'own_delta = True')],
        "ContainedHeadIsNoWork",
    ),
    (
        "ignore dirty files (refuses work that only exists uncommitted)",
        [('dirty_lines = [ln for ln in status.splitlines() if ln.strip()]', 'dirty_lines = []')],
        "DirtyWorktreeIsHasWork",
    ),
    (
        "drop --untracked-files=normal (an ambient config hides untracked work)",
        [('["status", "--porcelain", "--untracked-files=normal"]', '["status", "--porcelain"]')],
        "DirtyWorktreeIsHasWork",
    ),
    (
        "unreadable becomes HAS-WORK (a failed probe answers yes)",
        [
            ('        why.append(f"worktree path does not exist: {worktree}")\n        return result',
             '        result["verdict"] = VERDICT_HAS_WORK\n        return result'),
        ],
        "UnreadableFailsClosed",
    ),
    (
        "unresolvable base becomes HAS-WORK",
        [
            ('        why.append(f"base {base!r} does not resolve in this worktree (no origin/{base} either)")\n        return result',
             '        result["verdict"] = VERDICT_HAS_WORK\n        return result'),
        ],
        "UnreadableFailsClosed",
    ),
]


def run_suite() -> "unittest.result.TestResult":
    loader = unittest.TestLoader()
    suite = loader.loadTestsFromModule(sys.modules[__name__])
    return unittest.TextTestRunner(verbosity=1, stream=sys.stdout).run(suite)


def red_control() -> int:
    src = HERE / "dispatch_preflight.py"
    original = src.read_text()
    failures = []
    for name, subs, leg in MUTATIONS:
        mutant_text = original
        applied = 0
        for before, after in subs:
            if before in mutant_text:
                mutant_text = mutant_text.replace(before, after, 1)
                applied += 1
        if applied != len(subs):
            failures.append(f"{name}: substitution did not apply ({applied}/{len(subs)}) — "
                            f"the shipped source moved under this mutation")
            continue
        tmpdir = Path(tempfile.mkdtemp(prefix="dp-mutant-"))
        try:
            mutant = tmpdir / "dispatch_preflight.py"
            mutant.write_text(mutant_text)
            env = dict(os.environ, DP_MODULE=str(mutant))
            p = subprocess.run(
                [sys.executable, str(Path(__file__).resolve())],
                capture_output=True, text=True, env=env,
            )
            caught = p.returncode != 0
            # "Caught" is not enough: it must be the LEG that caught it. unittest
            # renders a leg as `FAIL: test_name (module.ClassName)`, so the class
            # name never appears immediately after the colon — match it anywhere
            # in a FAIL/ERROR header line rather than assuming a layout.
            combined = p.stdout + p.stderr
            headers = [ln for ln in combined.splitlines()
                       if ln.startswith("FAIL:") or ln.startswith("ERROR:")]
            leg_red = any(leg in ln for ln in headers)
            if not caught:
                failures.append(f"{name}: suite PASSED against the mutant — leg {leg} is not pinned")
            elif not leg_red:
                failures.append(f"{name}: suite failed, but not via leg {leg} — the mutation "
                                f"was caught by something else, so {leg} itself is unpinned")
            else:
                print(f"  ✅ caught by {leg}: {name}")
                for ln in headers:
                    if leg in ln:
                        print(f"       {ln.strip()}")
        finally:
            shutil.rmtree(tmpdir, ignore_errors=True)
    if failures:
        print("\nRED CONTROL FAILED:")
        for f in failures:
            print(f"  ⛔ {f}")
        return 1
    print(f"\nRED CONTROL OK — {len(MUTATIONS)} mutations, each caught by its paired leg.")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--red-control", action="store_true")
    ns = ap.parse_args()
    if ns.red_control:
        return red_control()
    result = run_suite()
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    sys.exit(main())
