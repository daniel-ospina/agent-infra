#!/usr/bin/env python3
"""tools/fleet/dispatch_preflight.test.py — hermetic suite for the dispatch preflight.

WHAT THIS PINS
--------------
``dispatch_preflight.py`` refuses to dispatch a lane into a worktree that has
nothing to land. The measured failure it prevents (2026-10-18): 12 of 15
dispatched worktrees sat on a HEAD that ``origin/main`` already contained, and
ALL 12 produced +0 commits — a whole lane's context spent discovering there was
nothing to do, then up to 9 h parked at 0.00 % CPU.

The cases below are the whole contract, and the middle ones exist because a
simpler tool gets them WRONG in the dangerous direction:

  * **contained HEAD** -> NO-WORK. The "sitting on main's tip" incident case.
  * **squash-merged branch** -> NO-WORK. This one carries ``ahead > 0`` with an
    EMPTY own delta. A tool keying on the commit COUNT reports HAS-WORK here and
    re-creates the wasted lane with a bigger number to make it look productive.
  * **squash-merged, then the base ADVANCED** -> NO-WORK. The most common
    lifecycle shape of all, and the one a tree-identity test gets wrong: the
    base moved, so ``tree(HEAD) != tree(base)`` even though every byte HEAD
    carries is already in the base. A three-way merge is the only read that
    answers it (see the module header for the measured falsification).
  * **dirty worktree** -> HAS-WORK, even when the base cannot be resolved.
    Uncommitted/untracked changes ARE work to land (measured: ``retire-fork``).
    A false refusal here destroys real work; a false allow only costs an
    untouched worktree. The asymmetry is deliberate and these legs are the ones
    that must never flip.
  * **the target is not its own work-tree root** -> UNREADABLE. ``git -C`` walks
    upward, so a stale ``.worktrees/x/`` would otherwise be answered from the
    MAIN checkout — a confident verdict about a tree nobody asked about.
  * **a conflicting branch** -> HAS-WORK. git answered; a branch that will not
    merge cleanly certainly has something that still has to land.

Unreadable states (missing path, non-git dir, unborn HEAD, unresolvable base,
and a FAILED ``status`` / ``merge-base`` / ``diff`` / ``merge-tree`` read) exit
with their OWN code and never report HAS-WORK: a probe that cannot answer must
not answer "yes". Every one of those paths has a leg here and a mutation in
``--red-control`` — an unpinned fail-closed branch is prose, not a pin.

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
REAL_GIT = shutil.which("git") or "/usr/bin/git"

# The environment keys `_git_env()` pins or CLEARS, so tearDownModule can restore
# exactly what it changed instead of guessing.
_ENV_KEYS = (
    "GIT_CONFIG_GLOBAL",
    "GIT_CONFIG_SYSTEM",
    "GIT_CONFIG_NOSYSTEM",
    "GIT_AUTHOR_NAME",
    "GIT_COMMITTER_NAME",
    "GIT_AUTHOR_EMAIL",
    "GIT_COMMITTER_EMAIL",
    "GIT_AUTHOR_DATE",
    "GIT_COMMITTER_DATE",
    "PATH",
    "GIT_DIR",
    "GIT_WORK_TREE",
    "GIT_INDEX_FILE",
    "GIT_OBJECT_DIRECTORY",
    "GIT_COMMON_DIR",
    "GIT_ALTERNATE_OBJECT_DIRECTORIES",
)

# A LEAKED GIT_DIR/GIT_WORK_TREE/GIT_INDEX_FILE redirects EVERY fixture git call
# into whatever repo the caller had exported. Measured before this was cleared:
# `GIT_DIR=$PWD/.git python3 tools/fleet/dispatch_preflight.test.py` errored 26
# setUps AND wrote into the AMBIENT repo — a commit parented on the PR head and
# an index containing only the fixture's file. A suite must not be able to mutate
# a checkout, so these are CLEARED, not merely inherited.
_GIT_LEAKS = (
    "GIT_DIR",
    "GIT_WORK_TREE",
    "GIT_INDEX_FILE",
    "GIT_OBJECT_DIRECTORY",
    "GIT_COMMON_DIR",
    "GIT_ALTERNATE_OBJECT_DIRECTORIES",
)


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
    for leak in _GIT_LEAKS:
        env.pop(leak, None)
    env["GIT_CONFIG_GLOBAL"] = os.devnull
    env["GIT_CONFIG_SYSTEM"] = os.devnull
    env["GIT_CONFIG_NOSYSTEM"] = "1"
    env["GIT_AUTHOR_NAME"] = env["GIT_COMMITTER_NAME"] = "t"
    env["GIT_AUTHOR_EMAIL"] = env["GIT_COMMITTER_EMAIL"] = "t@t"
    env["GIT_AUTHOR_DATE"] = env["GIT_COMMITTER_DATE"] = "2026-01-01T00:00:00 +0000"
    return env


_SAVED_ENV: dict = {}


def setUpModule() -> None:  # noqa: N802 (unittest's own name)
    """Pin the git environment for THIS PROCESS, not only for the fixture helpers.

    Every verdict is computed by ``evaluate()`` IN THIS PROCESS, and the tool's
    ``_git()`` shells out with no ``env=``, so it inherits whatever this process
    carries. Pinning only the fixtures' own git calls left the verdicts computed
    under the developer's ambient config — measured: a global
    ``core.excludesFile`` matching ``*.md`` reddened
    ``test_untracked_file_at_base_tip_is_has_work`` on one box and greened it on
    another. So the pin is applied to ``os.environ`` here, which covers the
    in-process legs AND every subprocess spawned without an explicit ``env=``
    (including the mutants ``--red-control`` runs).
    """
    global _SAVED_ENV
    _SAVED_ENV = {k: os.environ.get(k) for k in _ENV_KEYS}
    # `os.environ.update()` cannot REMOVE a key, so clearing the GIT_* leaks is an
    # explicit POP first: a leaked GIT_DIR/GIT_WORK_TREE/GIT_INDEX_FILE redirects
    # every fixture git call into the caller's repo (measured: an exported
    # `GIT_DIR` errored 26 setUps AND wrote a commit + an index into the ambient
    # checkout).
    for leak in _GIT_LEAKS:
        os.environ.pop(leak, None)
    os.environ.update(_git_env())


def tearDownModule() -> None:  # noqa: N802 (unittest's own name)
    for key, value in _SAVED_ENV.items():
        if value is None:
            os.environ.pop(key, None)
        else:
            os.environ[key] = value


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


def _git_shim(root: Path, fail_subcommands: tuple, code: int = 128) -> Path:
    """A ``git`` on PATH that FAILS for the named subcommands, delegating the rest.

    The fail-closed branches are only pinned if something can MAKE the read fail;
    a shim is the only way to force one probe to fail while the rest of the
    worktree stays readable. ``code`` carries the failure's SHAPE: 128 is a read
    error, 129 is git's usage error (what an old git answers to an option it does
    not have).
    """
    bindir = root / "bindir"
    bindir.mkdir(parents=True, exist_ok=True)
    shim = bindir / "git"
    shim.write_text(
        "#!/bin/sh\n"
        'case " $* " in\n'
        + "".join(f'  *" {c} "*) echo "shim: refusing {c}" >&2; exit {code};;\n'
                  for c in fail_subcommands)
        + f'esac\nexec "{REAL_GIT}" "$@"\n'
    )
    shim.chmod(0o755)
    return bindir


def _merge_driver_shape(repo: Path) -> tuple:
    """A branch whose content a MERGE DRIVER would DISCARD: (feature_sha, main_sha).

    ``.gitattributes: *.lock merge=ours`` + a true driver makes the three-way
    merge keep the BASE side, so ``merged == tree(base)`` for a branch that
    really does carry unlanded work. Nothing else in the tool can see that, which
    is why the contained-delta read exists: without it this shape is a false
    NO-WORK, the direction the module header calls unflippable.
    """
    _write(repo, ".gitattributes", "*.lock merge=ours\n")
    _write(repo, "a.lock", "base-content\n")
    _commit(repo, "attributes + base lock")
    _git(repo, "config", "merge.ours.driver", "true")
    _git(repo, "checkout", "-q", "-b", "feat")
    _write(repo, "a.lock", "branch-content\n")
    feature = _commit(repo, "branch lock content")
    _git(repo, "checkout", "-q", "main")
    _write(repo, "a.lock", "main-content\n")
    main = _commit(repo, "main lock content")
    _git(repo, "update-ref", "refs/remotes/origin/main", main)
    _git(repo, "checkout", "-q", "--detach", feature)
    return feature, main


def _squash_then_same_path_fixup(repo: Path) -> tuple:
    """Squash-merged, then the base edited the SAME path: (feature_sha, main_sha).

    THE DOCUMENTED BOUNDARY. Here the branch's content really IS landed, but the
    base then rewrote that path, so HEAD's bytes are not the base's bytes and a
    three-way merge CONFLICTS. Every read available to the tool answers "this
    path differs from the base", so the verdict is HAS-WORK — conservative, and
    the case is recorded as a boundary rather than guessed at.
    """
    base = _git(repo, "rev-parse", "HEAD")
    _write(repo, "feat.txt", "feat\n")
    feature = _commit(repo, "feat work")
    squash = _git(repo, "commit-tree", f"{feature}^{{tree}}", "-p", base, "-m", "squash of feat")
    _git(repo, "checkout", "-q", "--detach", squash)
    _write(repo, "feat.txt", "feat+FIXUP\n")
    fixup = _commit(repo, "main fixes the same path up")
    _git(repo, "update-ref", "refs/remotes/origin/main", fixup)
    _git(repo, "checkout", "-q", "--detach", feature)
    return feature, fixup


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


def _squash_then_advance(repo: Path) -> tuple:
    """A squash-merged branch, with the base then moving ON: (feature_sha, main_sha).

    This is the falsifying fixture for a tree-identity predicate. ``tree(feature)``
    equals the squash commit's tree, and main's tip has since changed, so
    ``tree(feature) != tree(main)`` holds for a branch carrying NOTHING unlanded.
    The feature's file is byte-identical in main — asserted in the leg.
    """
    base = _git(repo, "rev-parse", "HEAD")
    _write(repo, "feat.txt", "feat\n")
    feature = _commit(repo, "feat work")
    squash = _git(repo, "commit-tree", f"{feature}^{{tree}}", "-p", base, "-m", "squash of feat")
    # main ADVANCES past the squash: the squash commit is checked out, so the new
    # commit is parented on it and carries the feature tree plus one new file.
    _git(repo, "checkout", "-q", "--detach", squash)
    _write(repo, "later.txt", "later\n")
    advance = _commit(repo, "main moves on")
    _git(repo, "update-ref", "refs/remotes/origin/main", advance)
    _git(repo, "checkout", "-q", "--detach", feature)
    return feature, advance


def _conflicting_branch(repo: Path) -> tuple:
    """main and the branch edit the SAME line differently: (feature_sha, main_sha)."""
    _write(repo, "base.txt", "one\n")
    _commit(repo, "base line")
    _git(repo, "checkout", "-q", "-b", "feat")
    _write(repo, "base.txt", "two\n")
    feature = _commit(repo, "feat edit")
    _git(repo, "checkout", "-q", "main")
    _write(repo, "base.txt", "three\n")
    main = _commit(repo, "main edit")
    _git(repo, "update-ref", "refs/remotes/origin/main", main)
    _git(repo, "checkout", "-q", "--detach", feature)
    return feature, main


def _fixture(root: Path) -> Path:
    """A repo whose ``origin/main`` is a real remote-tracking ref, like the fleet.

    The base is materialised as ``refs/remotes/origin/main`` rather than a local
    ``main`` branch because that is the token every caller passes, and resolving
    the caller's token verbatim is part of the contract.
    """
    repo = root / "repo"
    repo.mkdir()
    _git(repo, "init", "-q", "-b", "main")
    # A LEAK GUARD, before the first commit: if a GIT_DIR/GIT_WORK_TREE ever
    # survives into this process, every command below would run against that
    # repo instead of the fixture. Assert the identity FIRST so a leak aborts
    # loudly rather than writing into somebody's checkout.
    toplevel = _git(repo, "rev-parse", "--show-toplevel")
    if os.path.realpath(toplevel) != os.path.realpath(repo):
        raise AssertionError(
            f"fixture git calls did not land in the fixture: git says {toplevel!r}, "
            f"fixture is {str(repo)!r} — a GIT_* variable leaked into this process")
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

    def with_git_shim(self, *fail_subcommands: str, code: int = 128):
        """Context manager: run this leg with a `git` that fails for those reads."""
        import contextlib

        @contextlib.contextmanager
        def _cm():
            bindir = _git_shim(self.tmp, tuple(fail_subcommands), code=code)
            previous = os.environ.get("PATH", "")
            os.environ["PATH"] = f"{bindir}{os.pathsep}{previous}"
            try:
                yield
            finally:
                os.environ["PATH"] = previous

        return _cm()


class ContainedHeadIsNoWork(_PreflightTest):
    """The incident case: HEAD is already in the base, nothing is dirty."""

    def test_clean_worktree_at_base_tip_is_no_work(self):
        res = self.verdict()
        self.assertEqual(res["verdict"], "NO-WORK", res)
        self.assertEqual(res["ahead"], 0)
        self.assertFalse(res["own_delta"])
        self.assertFalse(res["would_change_base"])
        self.assertEqual(res["dirty"], 0)

    def test_exit_code_is_its_own_three(self):
        rc = self.mod.main(["--quiet", str(self.repo)])
        self.assertEqual(rc, 3)

    def test_detached_head_at_the_base_tip_is_still_no_work(self):
        # A worktree parked on a detached base commit has no branch, but the
        # question is about CONTENT, so the verdict must not change.
        _git(self.repo, "checkout", "-q", "--detach", "origin/main")
        self.assertEqual(self.verdict()["verdict"], "NO-WORK")

    def test_head_behind_the_base_is_no_work(self):
        # HEAD strictly behind the base: own_delta=0 but the trees DIFFER, so
        # this is the one shape where `own_delta` and `would_change_base` point
        # in different directions. Nothing to land: the branch is contained.
        old = _git(self.repo, "rev-parse", "HEAD")
        _write(self.repo, "later.txt", "later\n")
        _commit(self.repo, "base moves on")
        _git(self.repo, "update-ref", "refs/remotes/origin/main", "HEAD")
        _git(self.repo, "checkout", "-q", "--detach", old)
        res = self.verdict()
        self.assertFalse(res["own_delta"], res)
        self.assertFalse(res["would_change_base"], res)
        self.assertEqual(res["verdict"], "NO-WORK", res)


class SquashMergedIsNoWork(_PreflightTest):
    """``ahead > 0`` with the branch's whole delta already landed."""

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
        self.assertFalse(res["would_change_base"], res)
        self.assertEqual(res["verdict"], "NO-WORK", res)
        self.assertEqual(self.mod.main(["--quiet", str(self.repo)]), 3)

    def test_noop_commits_are_also_no_work(self):
        # The other way to be ahead with no content: commits that change nothing.
        _commit(self.repo, "no-op", allow_empty=True)
        res = self.verdict()
        self.assertGreater(res["ahead"], 0)
        self.assertEqual(res["verdict"], "NO-WORK", res)

    def test_squash_landed_then_the_base_advanced_is_no_work(self):
        # THE FALSIFYING SHAPE for a tree-identity predicate: the base moved after
        # the squash, so tree(HEAD) != tree(base) while every byte HEAD carries is
        # already in the base. A tree comparison says HAS-WORK here and the reason
        # it prints is the opposite of the truth.
        feature, main = _squash_then_advance(self.repo)
        self.assertEqual(_git(self.repo, "show", f"{main}:feat.txt"), "feat",
                         "fixture must already carry the branch's content")
        res = self.verdict()
        self.assertTrue(res["own_delta"], res)
        self.assertFalse(res["would_change_base"], res)
        self.assertEqual(res["verdict"], "NO-WORK", res)
        self.assertEqual(self.mod.main(["--quiet", str(self.repo)]), 3)


class RealWorkIsHasWork(_PreflightTest):
    """The control for the legs above: a REAL diff must still be dispatched."""

    def test_a_real_commit_in_the_branch_is_has_work(self):
        _write(self.repo, "new.txt", "content\n")
        _commit(self.repo, "real change")
        _git(self.repo, "update-ref", "refs/remotes/origin/main", "HEAD~1")
        res = self.verdict()
        self.assertTrue(res["own_delta"])
        self.assertTrue(res["would_change_base"])
        self.assertEqual(res["verdict"], "HAS-WORK", res)
        self.assertEqual(self.mod.main(["--quiet", str(self.repo)]), 0)

    def test_a_conflicting_branch_is_has_work_not_unreadable(self):
        # git ANSWERED (merge-tree exits 1 on conflict); a branch that cannot
        # merge cleanly certainly has unlanded work. Treating the conflict as an
        # error would refuse a lane that has the most work of all.
        _conflicting_branch(self.repo)
        res = self.verdict()
        self.assertTrue(res["would_change_base"], res)
        self.assertEqual(res["verdict"], "HAS-WORK", res)
        self.assertEqual(self.mod.main(["--quiet", str(self.repo)]), 0)

    def test_squash_landed_then_a_same_path_fixup_is_the_documented_boundary(self):
        # Recorded, not pretended away: the branch's content IS landed, but the
        # base rewrote the same path, so every read available here says "this
        # path differs from the base". HAS-WORK is the conservative answer; the
        # module header and docs/ops/fleet-liveness.md §10.4 name it as a
        # boundary so nobody reads the NO-WORK rule as unconditional.
        _squash_then_same_path_fixup(self.repo)
        res = self.verdict()
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

    def test_dirty_work_survives_an_unresolvable_base(self):
        # THE DIRECTION THE HEADER CALLS UNFLIPPABLE. A fork/interrupted worktree
        # may have no `origin/main` at all; its uncommitted work is still work, so
        # the dirty read must short-circuit BEFORE anything that needs the base.
        _write(self.repo, "kept.txt", "real uncommitted work\n")
        res = self.verdict(base="origin/does-not-exist")
        self.assertEqual(res["verdict"], "HAS-WORK", res)
        self.assertEqual(res["dirty"], 1)
        self.assertEqual(self.mod.main(["--quiet", "--base", "origin/does-not-exist",
                                        str(self.repo)]), 0)


class IdentityIsTheTarget(_PreflightTest):
    """A path inside some repo is not the same thing as ITS OWN work tree root."""

    def test_a_nested_directory_is_unreadable_not_the_enclosing_repo(self):
        # `git -C <dir>` walks UPWARD. A stale/pruned `.worktrees/x/` would
        # otherwise be answered from the main checkout: a confident verdict about
        # the wrong tree, and an ALLOWED dispatch whose commits would land on the
        # main checkout's branch.
        stale = self.repo / ".worktrees" / "stale"
        stale.mkdir(parents=True)
        _write(self.repo, ".gitignore", ".worktrees/\n")
        _commit(self.repo, "ignore worktrees")
        _git(self.repo, "update-ref", "refs/remotes/origin/main", "HEAD")
        _write(stale, "NOTES.md", "lane notes\n")
        res = self.mod.evaluate(str(stale), "origin/main")
        self.assertEqual(res["verdict"], "UNREADABLE", res)
        self.assertIsNone(res["head"], "the enclosing repo's HEAD must not be reported")
        self.assertEqual(self.mod.main(["--quiet", str(stale)]), 4)


class UnreadableFailsClosed(_PreflightTest):
    """A probe that cannot answer must never answer 'there is work'."""

    def test_missing_path_is_unreadable(self):
        res = self.mod.evaluate(str(self.tmp / "nope"), "origin/main")
        self.assertEqual(res["verdict"], "UNREADABLE", res)

    def test_non_git_directory_is_unreadable(self):
        plain = self.tmp / "plain"
        plain.mkdir()
        self.assertEqual(self.mod.evaluate(str(plain), "origin/main")["verdict"], "UNREADABLE")

    def test_a_repo_child_directory_is_unreadable(self):
        # Not the same thing as the bare-dir leg above: this one is INSIDE a git
        # work tree, which is the shape a stale `.worktrees/x/` actually has.
        child = self.repo / "subdir"
        child.mkdir()
        self.assertEqual(self.mod.evaluate(str(child), "origin/main")["verdict"], "UNREADABLE")

    def test_unresolvable_base_is_unreadable_not_has_work(self):
        res = self.verdict(base="origin/does-not-exist")
        self.assertEqual(res["verdict"], "UNREADABLE", res)
        self.assertEqual(self.mod.main(["--quiet", "--base", "origin/does-not-exist", str(self.repo)]), 4)

    def test_all_unreadable_paths_exit_four(self):
        plain = self.tmp / "plain2"
        plain.mkdir()
        self.assertEqual(self.mod.main(["--quiet", str(plain)]), 4)

    def test_unborn_head_is_unreadable(self):
        # A repo with commits is required for every question; an unborn HEAD with
        # untracked files is NOT "nothing to land" (we cannot read the state).
        unborn = self.tmp / "unborn"
        unborn.mkdir()
        _git(unborn, "init", "-q", "-b", "main")
        _write(unborn, "scratch.txt", "x\n")
        res = self.mod.evaluate(str(unborn), "origin/main")
        self.assertEqual(res["verdict"], "UNREADABLE", res)
        self.assertEqual(self.mod.main(["--quiet", str(unborn)]), 4)

    def test_a_failed_status_read_is_unreadable(self):
        with self.with_git_shim("status"):
            self.assertEqual(self.verdict()["verdict"], "UNREADABLE")

    def test_a_failed_merge_base_read_is_unreadable(self):
        with self.with_git_shim("merge-base"):
            self.assertEqual(self.verdict()["verdict"], "UNREADABLE")

    def test_a_failed_own_delta_diff_is_unreadable(self):
        with self.with_git_shim("diff"):
            self.assertEqual(self.verdict()["verdict"], "UNREADABLE")

    def test_a_failed_merge_tree_read_is_unreadable(self):
        with self.with_git_shim("merge-tree"):
            self.assertEqual(self.verdict()["verdict"], "UNREADABLE")

    def test_an_old_git_without_write_tree_is_unreadable_and_says_why(self):
        # git < 2.38 answers rc 129 to an option it does not have. That is a
        # blanket UNREADABLE (fail closed), and the reason must NAME the cause —
        # a generic "cannot tell" would send an operator hunting the worktree.
        with self.with_git_shim("merge-tree", code=129):
            res = self.verdict()
        self.assertEqual(res["verdict"], "UNREADABLE", res)
        self.assertTrue(any("2.38" in w for w in res["why"]), res["why"])

    def test_a_merge_driver_that_discards_the_branch_is_unreadable(self):
        # THE FALSE-NO-WORK DIRECTION. With `.gitattributes: *.lock merge=ours`
        # the merge keeps the BASE side, so `merged == tree(base)` for a branch
        # carrying real unlanded content — nothing but the contained-delta read
        # can see it. "Already landed" must never be certified from the merge
        # result alone.
        _merge_driver_shape(self.repo)
        res = self.verdict()
        self.assertEqual(res["verdict"], "UNREADABLE", res)
        self.assertIsNone(res["would_change_base"], res)
        self.assertTrue(any("merge driver" in w for w in res["why"]), res["why"])
        self.assertEqual(self.mod.main(["--quiet", str(self.repo)]), 4)

    def test_a_malformed_invocation_is_a_refusal_not_exit_two(self):
        # The documented contract is 0/3/4. argparse's default exit 2 sits
        # OUTSIDE it, so a caller written as "refuse on 3, escalate on 4,
        # otherwise dispatch" would DISPATCH on its own typo.
        with self.assertRaises(SystemExit) as caught:
            self.mod.main(["--not-a-flag", str(self.repo)])
        self.assertEqual(caught.exception.code, 4)

    def test_help_is_a_refusal_not_has_work(self):
        # argparse exits 0 for `--help`, and 0 IS the contract's HAS-WORK — a
        # caller reading 0 as "dispatch" would dispatch on a help screen, which
        # answered nothing at all.
        import contextlib
        import io

        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit) as caught:
                self.mod.main(["--help"])
        self.assertEqual(caught.exception.code, 4)


class RenderBlock(_PreflightTest):
    def test_the_dirty_evidence_is_indented_once_not_twice(self):
        # The dirty file lines arrive already prefixed; the renderer adds ONE
        # margin for every reason. A ternary with two identical arms (the shape
        # this leg exists to catch) emitted them seven spaces deep.
        _write(self.repo, "brand-new.md", "doc\n")
        rendered = self.mod.render_block(self.verdict()).splitlines()
        detail = [ln for ln in rendered if "?? brand-new.md" in ln]
        self.assertEqual(detail, ["     ?? brand-new.md"], rendered)


class JsonSurface(_PreflightTest):
    def test_json_carries_the_evidence_not_just_the_verdict(self):
        out = subprocess.run(
            [sys.executable, str(_module_path()), "--json", str(self.repo)],
            capture_output=True, text=True,
        )
        payload = json.loads(out.stdout)
        for key in ("worktree", "verdict", "head", "base_sha", "ahead",
                    "own_delta", "would_change_base", "dirty", "why"):
            self.assertIn(key, payload)
        self.assertEqual(payload["verdict"], "NO-WORK")
        # The refusal must be readable: a verdict with no reason is unactionable.
        self.assertTrue(any("nothing to land" in w for w in payload["why"]), payload["why"])


MUTATIONS = [
    # (name, [(before, after), ...], the leg name that MUST go red)
    (
        # NB: "own_delta = bool(ahead)" was tried here and REMOVED — under this
        # predicate `own_delta` does not decide the verdict, so it is
        # behaviourally EQUIVALENT on every shape the suite builds. An equivalent
        # mutation changes no verdict, and calling it "unpinned" would be a false
        # alarm.
        "the contained-delta read is skipped (the squash-then-advance trap comes back)",
        [('    if contained:\n        return False, ""',
          '    if False:\n        return False, ""')],
        "SquashMergedIsNoWork",
    ),
    (
        "the merge result is trusted on its own (a merge driver discards the branch and it reads as landed)",
        [('    differing = {p for p in out.split("\\0") if p}\n'
          '    return not any(p in differing for p in paths)',
          '    return True')],
        "UnreadableFailsClosed",
    ),
    (
        "a merge CONFLICT is treated as a read error (the branch with the most work is refused)",
        [('    if rc == 1:\n        return "conflict", ""',
          '    if rc == 1:\n        return "error", "conflict"')],
        "RealWorkIsHasWork",
    ),
    (
        "an unsupported merge-tree loses its name (an operator cannot tell an old git from a read fault)",
        [('    if rc == 129:', '    if False:')],
        "UnreadableFailsClosed",
    ),
    (
        "a --help exit is reported as HAS-WORK (argparse's status 0 leaks into the contract)",
        [('            raise SystemExit(EXIT_UNREADABLE if status == 0 else status)',
          '            raise SystemExit(status)')],
        "UnreadableFailsClosed",
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
        "dirty only wins when the base resolves (real work is refused on a worktree with no base)",
        [('    if result["dirty"]:',
          '    if result["dirty"] and _resolve_base(worktree, base) is not None:')],
        "DirtyWorktreeIsHasWork",
    ),
    (
        "the target is accepted inside ANY repo (a stale .worktrees/x is answered from the main checkout)",
        [('    if rc != 0 or not toplevel or os.path.realpath(toplevel) != os.path.realpath(worktree):',
          '    if rc != 0:')],
        "IdentityIsTheTarget",
    ),
    (
        "a missing path becomes HAS-WORK (a failed probe answers yes)",
        [('        why.append(f"worktree path does not exist: {worktree}")\n        return result',
          '        result["verdict"] = VERDICT_HAS_WORK\n        return result')],
        "UnreadableFailsClosed",
    ),
    (
        "an unresolvable base becomes HAS-WORK",
        [('        why.append(f"base {base!r} does not resolve in this worktree (no origin/{base} either)")\n        return result',
          '        result["verdict"] = VERDICT_HAS_WORK\n        return result')],
        "UnreadableFailsClosed",
    ),
    (
        "an unborn HEAD becomes HAS-WORK",
        [('        why.append("HEAD does not resolve (unborn or detached-empty worktree)")\n        return result',
          '        result["verdict"] = VERDICT_HAS_WORK\n        return result')],
        "UnreadableFailsClosed",
    ),
    (
        "a failed status read becomes HAS-WORK",
        [('        why.append(f"git status failed (rc={rc}) — cannot tell dirty from clean")\n        return result',
          '        result["verdict"] = VERDICT_HAS_WORK\n        return result')],
        "UnreadableFailsClosed",
    ),
    (
        "a missing merge-base becomes HAS-WORK",
        [('        why.append(f"no merge-base between HEAD {head[:12]} and {base} {base_sha[:12]} "\n'
          '                   "(unrelated histories?) — cannot compute a diff")\n        return result',
          '        result["verdict"] = VERDICT_HAS_WORK\n        return result')],
        "UnreadableFailsClosed",
    ),
    (
        "a failed own-delta diff becomes HAS-WORK",
        [('        why.append("git could not report a diff verdict — cannot tell whether a diff exists")\n        return result',
          '        result["verdict"] = VERDICT_HAS_WORK\n        return result')],
        "UnreadableFailsClosed",
    ),
    (
        "an unreadable merge verdict becomes HAS-WORK",
        [('    if would_change is None:\n        why.append(reason)\n        return result',
          '    if would_change is None:\n        result["verdict"] = VERDICT_HAS_WORK\n        return result')],
        "UnreadableFailsClosed",
    ),
]

def run_suite() -> "unittest.result.TestResult":
    loader = unittest.TestLoader()
    suite = loader.loadTestsFromModule(sys.modules[__name__])
    return unittest.TextTestRunner(verbosity=1, stream=sys.stdout).run(suite)


def _hermeticity_probe() -> list:
    """Run the suite ONCE under a HOSTILE git environment; it must stay green.

    The suite's fixture git calls land in whatever `GIT_DIR` says, so a leaked
    one turns a test run into a WRITE against the caller's checkout (measured:
    a commit parented on the PR head, and an index holding only the fixture's
    file). `setUpModule` clears it; this probe is what makes that removal
    visible — without it the pop could be deleted and every run would still be
    green on a clean box.
    """
    tmp = Path(tempfile.mkdtemp(prefix="dp-hermetic-"))
    try:
        scratch = tmp / "scratch"
        subprocess.run(["git", "init", "-q", str(scratch)], capture_output=True, check=False)
        env = dict(os.environ)
        env.update({
            "GIT_DIR": str(scratch / ".git"),
            "GIT_WORK_TREE": str(scratch),
            "GIT_INDEX_FILE": str(tmp / "leak-index"),
        })
        p = subprocess.run([sys.executable, str(Path(__file__).resolve())],
                           capture_output=True, text=True, env=env)
        if p.returncode != 0:
            combined = (p.stdout + p.stderr).splitlines()
            # Name the FIRST leg that failed, not the last line printed: the
            # `--help` leg writes argparse's message to stderr, and quoting that
            # would send an operator looking in the wrong place.
            first = next((ln.strip() for ln in combined
                          if ln.startswith("FAIL:") or ln.startswith("ERROR:")), None)
            detail = first or (combined[-1].strip() if combined else "no output")
            return [f"hermeticity: the suite FAILS (or writes) under a leaked GIT_DIR — "
                    f"it is not pinned to this process ({detail})"]
        return []
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def red_control() -> int:
    src = HERE / "dispatch_preflight.py"
    original = src.read_text()
    failures = _hermeticity_probe()
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


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--red-control", action="store_true")
    ns = ap.parse_args(argv)
    if ns.red_control:
        # THE BASELINE COMES FIRST. Without it, a suite that is red for its own
        # reasons still prints "RED CONTROL OK": the paired leg's class name is
        # already in the FAIL/ERROR headers, so every mutation looks "caught by
        # its paired leg". A red control that certifies a broken suite is a
        # false PASS.
        baseline = run_suite()
        if not baseline.wasSuccessful():
            print("\nRED CONTROL REFUSED — the suite is RED before any mutation is applied; "
                  "fix the baseline first (a mutation cannot be judged against a broken one).")
            return 1
        return red_control()
    result = run_suite()
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    raise SystemExit(main())
