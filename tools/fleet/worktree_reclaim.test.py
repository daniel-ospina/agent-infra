#!/usr/bin/env python3
"""worktree_reclaim.test.py — the five evidence cases, plus mutations that prove
each predicate is load-bearing.

Every fixture is a THROWAWAY repo built in a temp dir: `git init`, one commit,
then real `git worktree add`s. Nothing here touches a live checkout, so a
mutation that turns a gate off cannot destroy a lane's work — which is the whole
reason the mutations are run here and not against the estate.

  python3 tools/fleet/worktree_reclaim.test.py              # cases
  python3 tools/fleet/worktree_reclaim.test.py --mutations   # every mutant must go RED

The mutations are the point. A gate with no mutation that reddens it is a gate
nobody has shown can fail, and this tool's whole defect class is "reported
success while reclaiming nothing".
"""
from __future__ import annotations

import io
import os
import shutil
import subprocess
import sys
import tempfile
import time
import traceback
from contextlib import redirect_stdout
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import worktree_reclaim as m  # noqa: E402

#: canned global probes — `lsof`/`ps` are per-pass facts, not per-test facts.
_PS = subprocess.run(["ps", "-Ao", "pid=,ppid=,command="], capture_output=True, text=True).stdout
m.load_ps = lambda: f"PID PPID COMMAND\n{_PS}"  # noqa: SLF001
m.load_cwds = lambda: {}  # noqa: SLF001

OLD = 30 * 24 * 3600  # seconds; a commit old enough to clear any idle bound


# --------------------------------------------------------------------------- #
# fixture
# --------------------------------------------------------------------------- #
def _git(*args: str, cwd: Path, env: dict | None = None, check: bool = True) -> str:
    e = {**os.environ, **(env or {})}
    cp = subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True, env=e)
    if check and cp.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)} failed: {cp.stderr}")
    return cp.stdout.strip()


class Repo:
    """A throwaway repo whose `origin/main` is a local ref (no network)."""

    def __init__(self, root: Path):
        self.root = root
        self.path = root / "repo"
        self.path.mkdir(parents=True)
        old = {"GIT_COMMITTER_DATE": "@%d +0000" % int(time.time() - OLD),
               "GIT_AUTHOR_DATE": "@%d +0000" % int(time.time() - OLD)}
        _git("init", "-q", "-b", "main", cwd=self.path)
        _git("config", "user.email", "t@example.invalid", cwd=self.path)
        _git("config", "user.name", "t", cwd=self.path)
        (self.path / "seed.txt").write_text("seed\n")
        _git("add", "seed.txt", cwd=self.path)
        _git("commit", "-q", "-m", "seed", cwd=self.path, env=old)
        self.base_sha = _git("rev-parse", "HEAD", cwd=self.path)
        _git("update-ref", "refs/remotes/origin/main", self.base_sha, cwd=self.path)
        self.commit_env = old

    # -- worktree builders -------------------------------------------------
    def worktree(self, name: str, *, branch: str | None = None, at: str | None = None) -> Path:
        wt = self.root / name
        args = ["worktree", "add", "-q"]
        if branch:
            args += ["-b", branch]
        if at is None:
            args.append(str(wt))
        else:
            args += [str(wt), at]
        if not branch and at is None:
            args += ["--detach"]
        _git(*args, cwd=self.path)
        self.backdate(wt)
        return wt

    def advance_base(self, to: str) -> None:
        """Simulate a merge: the base now contains `to`."""
        _git("update-ref", "refs/remotes/origin/main", to, cwd=self.path)

    def commit_in(self, wt: Path, fname: str, body: str = "x\n") -> str:
        (wt / fname).write_text(body)
        _git("add", fname, cwd=wt)
        _git("commit", "-q", "-m", f"commit {fname}", cwd=wt, env=self.commit_env)
        return _git("rev-parse", "HEAD", cwd=wt)

    def backdate(self, wt: Path) -> None:
        """Make the checkout look 30 days idle (dir, .git file, admin dir)."""
        stamp = time.time() - OLD
        for p in (wt, wt / ".git"):
            try:
                os.utime(p, (stamp, stamp))
            except OSError:
                pass
        admin = Path(_git("rev-parse", "--git-common-dir", cwd=wt))
        if not admin.is_absolute():
            admin = (wt / admin).resolve()
        for entry in (admin / "worktrees").iterdir():
            try:
                if (entry / "gitdir").read_text().strip().rstrip("/.git").endswith(str(wt)):
                    os.utime(entry, (stamp, stamp))
                    for f in entry.iterdir():
                        os.utime(f, (stamp, stamp))
            except OSError:
                pass


class Fixture:
    def __init__(self):
        self.root = Path(tempfile.mkdtemp(prefix="wtreclaim-"))
        self.repo = Repo(self.root)

    # -- context -----------------------------------------------------------
    def ctx(self, *, idle_hours: float = 0.0, stash_py: Path | None = None,
            base: str = "origin/main") -> m.Context:
        ctx = m.build_context(str(self.repo.path), base, idle_hours)
        ctx.stash_py = str(stash_py) if stash_py else None
        ctx.stash_interp = sys.executable if stash_py else None
        return ctx

    def one(self, path: Path, *, idle_hours: float = 0.0, stash_py: Path | None = None,
            base: str = "origin/main") -> dict:
        recs = m.worktree_records(str(self.repo.path))
        target = next(r for r in recs if Path(r.path).resolve() == path.resolve())
        return m.classify(target, self.ctx(idle_hours=idle_hours, stash_py=stash_py, base=base))

    def close(self):
        shutil.rmtree(self.root, ignore_errors=True)


def fake_lane_stash(text: str, rc: int = 0) -> Path:
    """A stand-in for tools/lane_stash.py: prints `text`, exits `rc`."""
    f = Path(tempfile.mkdtemp(prefix="fakestash-")) / "lane_stash.py"
    f.write_text(
        "import sys\n"
        f"sys.stdout.write({text!r})\n"
        f"raise SystemExit({rc})\n"
    )
    return f


PINNED = ("lane w-1 (linked worktree)\n"
          "    0  abc123def456  ok            2026-10-20 10:00:00 +0000  wip\n"
          "shared register (refs/stash — repo-global, 1 entry)\n"
          "  stash@{{0}}   abc123def456  OWN (pinned)  wip\n")
CLEAN = ("lane w-1 (linked worktree)\n"
         "  (no pinned entries)\n"
         "shared register (refs/stash — repo-global, 0 entries)\n"
         "  (empty)\n")


# --------------------------------------------------------------------------- #
# cases
# --------------------------------------------------------------------------- #
def t1_merged_clean_no_stash_is_reapable():
    """(a) merged + clean + no stash => REAPABLE."""
    fx = Fixture()
    try:
        sha = fx.repo.commit_in(fx.repo.worktree("w1", branch="feat/merged"), "a.txt")
        fx.repo.advance_base(sha)  # the work landed
        r = fx.one(fx.root / "w1", stash_py=fake_lane_stash(CLEAN))
        assert r["verdict"] == "REAP", r
        assert r["reason"] == "finished", r
    finally:
        fx.close()


def t2_merged_but_uncommitted_file_is_kept():
    """(b) merged, but one uncommitted file => KEPT with reason (agent-infra #1393)."""
    fx = Fixture()
    try:
        wt = fx.repo.worktree("w1", branch="feat/merged")
        sha = fx.repo.commit_in(wt, "a.txt")
        fx.repo.advance_base(sha)
        (wt / "scratch.txt").write_text("uncommitted work\n")
        r = fx.one(wt, stash_py=fake_lane_stash(CLEAN))
        assert r["verdict"] == "KEEP", r
        assert r["reason"] == "uncommitted", r
        assert "1 uncommitted path" in r["detail"], r
    finally:
        fx.close()


def t3_unmerged_branch_with_open_pr_is_kept():
    """(c) a branch named by an open PR => KEPT, and the PR is the SOLE decider:
    its commit is merged into the base AND pushed, so with the PR gate off the
    record would be REAPED (that is what makes the mutation load-bearing)."""
    fx = Fixture()
    try:
        wt = fx.repo.worktree("w1", branch="feat/in-flight")
        sha = fx.repo.commit_in(wt, "a.txt")
        fx.repo.advance_base(sha)
        _git("update-ref", "refs/remotes/origin/feat/in-flight", sha, cwd=fx.repo.path)
        ctx = fx.ctx(stash_py=fake_lane_stash(CLEAN))
        ctx.open_prs = {"feat/in-flight": 4242}
        recs = m.worktree_records(str(fx.repo.path))
        rec = next(r for r in recs if Path(r.path).resolve() == wt.resolve())
        r = m.classify(rec, ctx)
        assert r["verdict"] == "KEEP", r
        assert r["reason"] == "open-pr", r
        assert "4242" in r["detail"], r
    finally:
        fx.close()


def t3b_unmerged_detached_is_kept():
    """(c2) unmerged and DETACHED, so no branch name can protect it: only ancestry does."""
    fx = Fixture()
    try:
        src = fx.repo.worktree("src", branch="feat/in-flight")
        sha = fx.repo.commit_in(src, "a.txt")
        # Pushed (a remote-tracking ref names it), so `unpushed` is 0 and the ONLY
        # predicate standing between this record and removal is ancestry.
        _git("update-ref", "refs/remotes/origin/feat/in-flight", sha, cwd=fx.repo.path)
        wt = fx.repo.worktree("w-det", at=sha)
        r = fx.one(wt, stash_py=fake_lane_stash(CLEAN))
        assert r["verdict"] == "KEEP", r
        assert r["reason"] == "unmerged", r
    finally:
        fx.close()


def t4_unpushed_commit_is_kept():
    """(d) a commit on no remote ref => KEPT, and unpushed is the SOLE decider.

    The base here is the LOCAL `main` branch (which contains the commit), not
    `origin/main`: with a remote base, `unpushed > 0` implies `unmerged`, so the
    gate would only restate the diagnosis instead of being the safety.
    """
    fx = Fixture()
    try:
        wt = fx.repo.worktree("w1", branch="feat/merged")
        sha = fx.repo.commit_in(wt, "b.txt")  # local-only, on no remote branch
        _git("update-ref", "refs/heads/main", sha, cwd=fx.repo.path)
        r = fx.one(wt, stash_py=fake_lane_stash(CLEAN), base="main")
        assert r["verdict"] == "KEEP", r
        assert r["reason"] == "unpushed", r
        assert "1 commit" in r["detail"], r
    finally:
        fx.close()


def t5_stranded_lane_stash_is_kept():
    """(f) merged + clean, but the lane stash register is stranded => KEPT."""
    fx = Fixture()
    try:
        sha = fx.repo.commit_in(fx.repo.worktree("w1", branch="feat/merged"), "a.txt")
        fx.repo.advance_base(sha)
        r = fx.one(fx.root / "w1", stash_py=fake_lane_stash(PINNED))
        assert r["verdict"] == "KEEP", r
        assert r["reason"] == "lane-stash-stranded", r
    finally:
        fx.close()


def t6_unreadable_stash_probe_is_kept():
    """A stash probe that cannot answer is not a pass: KEPT, never REAP."""
    fx = Fixture()
    try:
        sha = fx.repo.commit_in(fx.repo.worktree("w1", branch="feat/merged"), "a.txt")
        fx.repo.advance_base(sha)
        r = fx.one(fx.root / "w1", stash_py=fake_lane_stash("", rc=2))
        assert r["verdict"] == "KEEP", r
        assert r["reason"] == "stash-unreadable", r
    finally:
        fx.close()


def t7_primary_checkout_is_never_a_candidate():
    """The shared checkout is skipped before any probe can decide anything."""
    fx = Fixture()
    try:
        recs = m.worktree_records(str(fx.repo.path))
        assert Path(recs[0].path).resolve() == fx.repo.path.resolve(), recs[0].path
        r = m.classify(recs[0], fx.ctx(stash_py=fake_lane_stash(CLEAN)))
        assert r["verdict"] == "KEEP", r
        assert r["reason"] == "primary-checkout", r
    finally:
        fx.close()


def t8_recently_active_is_kept():
    """A checkout created minutes ago at the base is vacuously 'merged' — the idle
    bound is what keeps it. Measured case: `feat/9660-tm` at 0.0d."""
    fx = Fixture()
    try:
        wt = fx.repo.worktree("w-new", branch="feat/brand-new", at=fx.repo.base_sha)
        os.utime(wt, None)  # touched just now
        r = fx.one(wt, idle_hours=24.0, stash_py=fake_lane_stash(CLEAN))
        assert r["verdict"] == "KEEP", r
        assert r["reason"] == "recently-active", r
        # ...and with the bound relaxed it IS reapable, so the bound is the decider.
        r2 = fx.one(wt, idle_hours=0.0, stash_py=fake_lane_stash(CLEAN))
        assert r2["verdict"] == "REAP", r2
    finally:
        fx.close()


def t9_apply_removes_checkout_but_never_the_branch():
    """`--apply` reclaims the checkout and leaves `refs/heads/*` untouched."""
    fx = Fixture()
    try:
        wt = fx.repo.worktree("w1", branch="feat/merged")
        sha = fx.repo.commit_in(wt, "a.txt")
        fx.repo.advance_base(sha)
        rc = m.main(["--repo", str(fx.repo.path), "--idle-hours", "0", "--apply",
                     "--json", "--quiet"])
        assert rc == 0, rc
        assert not wt.exists(), "checkout should be gone"
        branches = _git("for-each-ref", "--format=%(refname)", "refs/heads/", cwd=fx.repo.path)
        assert "refs/heads/feat/merged" in branches, branches
        listed = _git("worktree", "list", "--porcelain", cwd=fx.repo.path)
        assert str(wt) not in listed, listed
    finally:
        fx.close()


def t10_max_caps_the_sweep_oldest_first():
    """A capped sweep takes the OLDEST-idle rows — the safest quartile."""
    fx = Fixture()
    try:
        for name in ("w-old", "w-new"):
            wt = fx.repo.worktree(name, branch=f"feat/{name}", at=fx.repo.base_sha)
            if name == "w-new":
                os.utime(wt, None)
            else:
                fx.repo.backdate(wt)
        rc = m.main(["--repo", str(fx.repo.path), "--idle-hours", "0", "--apply",
                     "--max", "1", "--quiet"])
        assert rc == 0, rc
        assert not (fx.root / "w-old").exists(), "the oldest-idle row should be taken"
        assert (fx.root / "w-new").exists(), "the newer row must survive the cap"
    finally:
        fx.close()


def t11_gh_unreadable_on_a_github_remote_fails_closed():
    """With a GitHub origin and a broken `gh`, nothing is classified reapable."""
    fx = Fixture()
    try:
        _git("remote", "add", "origin", "https://github.com/example/nope.git", cwd=fx.repo.path)
        sha = fx.repo.commit_in(fx.repo.worktree("w1", branch="feat/merged"), "a.txt")
        fx.repo.advance_base(sha)
        # A stub, never the real `gh`: this suite is zero-dep and must not make a
        # network call (`RECLAIM_GH` is the documented seam).
        old = os.environ.get("RECLAIM_GH")
        os.environ["RECLAIM_GH"] = "/nonexistent/gh-for-tests"
        try:
            prs, detail = m.probe_open_prs(str(fx.repo.path), os.environ["RECLAIM_GH"])
            assert prs is None, (prs, detail)
            ctx = fx.ctx(stash_py=fake_lane_stash(CLEAN))
        finally:
            if old is None:
                os.environ.pop("RECLAIM_GH", None)
            else:
                os.environ["RECLAIM_GH"] = old
        ctx.open_prs = None
        recs = m.worktree_records(str(fx.repo.path))
        rec = next(r for r in recs if Path(r.path).name == "w1")
        r = m.classify(rec, ctx)
        assert r["verdict"] == "KEEP" and r["reason"] == "open-pr-unreadable", r
    finally:
        fx.close()


def t13_ignored_content_is_kept_and_a_cache_is_not():
    """P0: `--porcelain` is silent about IGNORED files and `git worktree remove`
    deletes them without refusing. Only regenerable caches may be tolerated."""
    fx = Fixture()
    try:
        (fx.repo.path / ".gitignore").write_text(".env\n__pycache__/\n")
        _git("add", ".gitignore", cwd=fx.repo.path)
        _git("commit", "-q", "-m", "ignore", cwd=fx.repo.path, env=fx.repo.commit_env)
        fx.repo.base_sha = _git("rev-parse", "HEAD", cwd=fx.repo.path)
        fx.repo.advance_base(fx.repo.base_sha)

        wt = fx.repo.worktree("w1", branch="feat/merged")
        (wt / ".env").write_text("SECRET=xyz\n")
        r = fx.one(wt, stash_py=fake_lane_stash(CLEAN))
        assert r["verdict"] == "KEEP", r
        assert r["reason"] == "ignored-content", r
        assert ".env" in r["detail"], r

        # ...and a pure regenerable cache does NOT block reclamation.
        (wt / ".env").unlink()
        cache = wt / "__pycache__"
        cache.mkdir()
        (cache / "x.pyc").write_bytes(b"\x00")
        r2 = fx.one(wt, stash_py=fake_lane_stash(CLEAN))
        assert r2["verdict"] == "REAP", r2
    finally:
        fx.close()


def t14_live_claim_is_kept():
    """A `refs/claims/<pr>-<sha12>` entry naming this head => KEPT."""
    fx = Fixture()
    try:
        wt = fx.repo.worktree("w1", branch="feat/merged")
        sha = fx.repo.commit_in(wt, "a.txt")
        fx.repo.advance_base(sha)
        _git("update-ref", f"refs/claims/4242-{sha[:12]}", sha, cwd=fx.repo.path)
        r = fx.one(wt, stash_py=fake_lane_stash(CLEAN))
        assert r["verdict"] == "KEEP", r
        assert r["reason"] == "live-claim", r
    finally:
        fx.close()


def t15_apply_refuses_a_worktree_dirtied_after_classification():
    """The second gate on the destructive path: remove_one re-classifies."""
    fx = Fixture()
    try:
        wt = fx.repo.worktree("w1", branch="feat/merged")
        sha = fx.repo.commit_in(wt, "a.txt")
        fx.repo.advance_base(sha)
        row = fx.one(wt, stash_py=fake_lane_stash(CLEAN))
        assert row["verdict"] == "REAP", row
        (wt / "appeared-just-now.txt").write_text("work\n")
        ctx = fx.ctx(stash_py=fake_lane_stash(CLEAN))
        ctx.cwd_map = {}
        ok, why = m.remove_one(row, ctx)
        assert not ok, why
        assert "uncommitted" in why, why
        assert wt.exists() and (wt / "appeared-just-now.txt").exists()
    finally:
        fx.close()


def t12_a_zero_pass_reports_why_not_a_bare_success():
    """The instrument answers its own question: a pass that reaps nothing names
    the deciding predicate for every row instead of printing 'ok'."""
    fx = Fixture()
    try:
        wt = fx.repo.worktree("w-dirty", branch="feat/x")
        fx.repo.commit_in(wt, "a.txt")
        (wt / "dirty.txt").write_text("x\n")
        buf = io.StringIO()
        with redirect_stdout(buf):
            rc = m.main(["--repo", str(fx.repo.path), "--idle-hours", "0"])
        out = buf.getvalue()
        assert rc == 0, rc
        assert "REAPABLE=0" in out, out
        assert "uncommitted=1" in out, out
        assert "MODE=dry-run" in out, out
    finally:
        fx.close()


CASES = [
    ("T1", "merged+clean+no-stash => REAPABLE", t1_merged_clean_no_stash_is_reapable),
    ("T2", "merged but 1 uncommitted file => KEPT", t2_merged_but_uncommitted_file_is_kept),
    ("T3", "merged+pushed but an open PR heads it => KEPT", t3_unmerged_branch_with_open_pr_is_kept),
    ("T3b", "unmerged detached (no name to protect it) => KEPT", t3b_unmerged_detached_is_kept),
    ("T4", "commit on no remote ref => KEPT", t4_unpushed_commit_is_kept),
    ("T5", "stranded lane stash => KEPT", t5_stranded_lane_stash_is_kept),
    ("T6", "unreadable stash probe => KEPT (fail-closed)", t6_unreadable_stash_probe_is_kept),
    ("T7", "primary checkout => never a candidate", t7_primary_checkout_is_never_a_candidate),
    ("T8", "recently active => KEPT (idle bound is load-bearing)", t8_recently_active_is_kept),
    ("T9", "--apply removes checkout, never the branch", t9_apply_removes_checkout_but_never_the_branch),
    ("T10", "--max caps the sweep, oldest-idle first", t10_max_caps_the_sweep_oldest_first),
    ("T11", "gh unreadable on a GitHub origin => fail-closed", t11_gh_unreadable_on_a_github_remote_fails_closed),
    ("T12", "a zero pass reports the failing predicate", t12_a_zero_pass_reports_why_not_a_bare_success),
    ("T13", "ignored content => KEPT, a regenerable cache => REAP", t13_ignored_content_is_kept_and_a_cache_is_not),
    ("T14", "a live refs/claims entry => KEPT", t14_live_claim_is_kept),
    ("T15", "--apply re-check refuses a worktree dirtied afterwards",
     t15_apply_refuses_a_worktree_dirtied_after_classification),
]


# --------------------------------------------------------------------------- #
# mutations — each disables ONE gate and must redden its paired case
# --------------------------------------------------------------------------- #
MUTANTS = [
    ("M1 drop-clean-check", "T2",
     lambda: setattr(m, "probe_clean", lambda wt: (0, "mutant: always clean"))),
    ("M2 drop-ancestry-check", "T3b",
     lambda: setattr(m, "probe_ancestry", lambda *a: (True, "mutant: always merged"))),
    ("M3 drop-unpushed-check", "T4",
     lambda: setattr(m, "probe_unpushed", lambda *a: (0, "mutant: always pushed"))),
    ("M4 drop-open-pr-gate", "T3",
     lambda: setattr(m, "pr_gate", lambda rec, ctx: (None, ""))),
    ("M5 drop-stash-gate", "T5",
     lambda: setattr(m, "probe_stash", lambda *a: (False, "mutant: nothing stranded"))),
    ("M6 drop-idle-bound", "T8",
     lambda: setattr(m, "probe_idle", lambda *a: (999.0, "mutant: ancient"))),
    ("M7 drop-primary-guard", "T7",
     lambda: setattr(m, "is_primary", lambda rec: False)),
    ("M8 drop-ignored-gate", "T13",
     lambda: setattr(m, "probe_ignored", lambda *a: ([], "mutant: nothing ignored"))),
    ("M9 drop-claim-gate", "T14",
     lambda: setattr(m, "claim_gate", lambda rec, ctx: (None, ""))),
]

_ORIG = {name: getattr(m, name) for name in
         ("probe_clean", "probe_ancestry", "probe_unpushed", "pr_gate",
          "probe_stash", "probe_idle", "is_primary", "probe_ignored", "claim_gate")}


def restore():
    for k, v in _ORIG.items():
        setattr(m, k, v)


def run_case(fn) -> tuple[bool, str]:
    try:
        fn()
        return True, "ok"
    except AssertionError as exc:
        return False, str(exc) or "assertion"
    except Exception:  # noqa: BLE001 — a fixture error is a red case, not a crash
        return False, traceback.format_exc(limit=2).strip().splitlines()[-1]


def main(argv: list[str]) -> int:
    mutations = "--mutations" in argv
    only = [a for a in argv if a.startswith("T")]
    ran = [c for c in CASES if not only or c[0] in only]
    if not ran:
        print(f"no case matches {only} — a filtered run that runs NOTHING is not a pass")
        return 2
    failures = 0
    print("== cases ==")
    for tid, label, fn in ran:
        ok, why = run_case(fn)
        failures += 0 if ok else 1
        print(f"{'ok  ' if ok else 'RED '} {tid:4s} {label}" + ("" if ok else f"\n       {why}"))

    if not mutations:
        print(f"\n{len(ran) - failures}/{len(ran)} cases green")
        return 1 if failures else 0

    print("\n== mutations (each MUST go red) ==")
    mut_fail = 0
    for name, target, apply_mutation in MUTANTS:
        restore()
        apply_mutation()
        fn = next(f for t, _, f in CASES if t == target)
        ok, why = run_case(fn)
        restore()
        red = not ok
        mut_fail += 0 if red else 1
        print(f"{'RED ' if red else 'MISS'} {name:26s} -> {target:4s} "
              + (f"({why.splitlines()[0][:70]})" if red else "(mutation survived: gate not load-bearing)"))
    print(f"\n{len(MUTANTS) - mut_fail}/{len(MUTANTS)} mutations went red")
    return 1 if (failures or mut_fail) else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
