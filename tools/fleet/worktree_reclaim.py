#!/usr/bin/env python3
"""worktree_reclaim — reclaim a git worktree only when it is PROVABLY finished.

WHY THIS EXISTS (measured, 2026-10-22)
--------------------------------------
The Mac hub carried **761 worktrees** (tortoise 561, agent-infra 200) against a
10-vCPU box; `fseventsd` sat at a full core. The scheduled reaper
(`com.tortoise.worktree-reaper`) reported `- 0` in `launchctl list` — installed,
exit 0, reclaiming **nothing** — because it is an *inert enforcer*: the tracked
plist passes `--dry-run` (agent-infra #1678: arming is not representable without
editing a tracked artifact the installer suite asserts ships UNARMED), and even
armed it deferred **422 of 538** records on its 1800s budget (serial `git status`
over 561 checkouts costs ~30 min of system time) while reporting `REMOVE=7`. A
reaper that prints SUCCESS and removes zero is "an instrument that cannot answer
its own question".

THE RULE — one sentence
-----------------------
A worktree is reclaimable when its work is provably IN THE BASE OR NOWHERE:
every commit it holds is an ancestor of the base, `git status --porcelain` is
empty AND nothing on disk is ignored-but-not-regenerable, it holds no commit
absent from every remote branch, the lane-stash register shows nothing pinned to
it, no open PR or claim names it, no process holds it, no merge/rebase/bisect is
stopped in it, and it has been idle past the idle bound.

Evidence only. Each predicate is a separate probe, and the pass PRINTS the
deciding predicate for every record, so a zero-reclaim pass states *why* it
reclaimed zero instead of asserting a success it never measured.

THE TWO THINGS IT MUST NEVER DO
-------------------------------
1. **Never touch a primary checkout.** Worktree index 0 is the shared checkout
   that other lanes' `git` calls resolve against; `git worktree remove` on it
   detaches the whole repo. It is skipped before any probe (and `self-cwd` is
   skipped too, because removing the directory a process is standing in makes
   every later relative path fail).
2. **Never judge "finished" from a branch name alone.** `main`, `fix/*`,
   `feat/*` say nothing about whether the work landed: a branch whose only
   changes are UNCOMMITTED is "merged" by ancestry and holds all the work
   (agent-infra #1393 — a live worktree and its branch were deleted mid-work;
   the recovery needed a hand-made backup). A branch name is also not identity:
   two worktrees can be forced onto one branch. So the verdict comes from
   ancestry + index + object reachability + the stash register, never the name.

STASH IS READ THROUGH `tools/lane_stash.py`, never a bare `git stash`
--------------------------------------------------------------------
`refs/stash` is repo-GLOBAL and shared by every worktree (#8051): a bare
`git stash` in lane A can read, drop or apply lane B's entry, silently. The
lane-scoped register is the only per-worktree answer, so this tool shells out to
`lane_stash.py list` with the worktree as cwd and treats **unreadable** as
STRANDED (fail-closed) — the probe must never answer "no stash" because it
failed. `lane_stash.py` needs Python >= 3.12; the interpreter is resolved here
(see `find_lane_stash_python`).

It never removes a BRANCH. `git worktree remove` deletes a checkout and nothing
else; `git branch -D` is never called, no history is rewritten, and the object
DB is never pruned (`git gc --prune` would make "the commit is on a ref" a claim
about garbage collection rather than about refs).

DELIBERATE KEEPS (a wrong reap costs a night; an orphan costs disk)
------------------------------------------------------------------
* dirty                -> KEEP. The #1393 decision: refuse a dirty worktree,
                          full stop. 192/562 in tortoise were dirty.
* unmerged             -> KEEP. 339/562 in tortoise; 212 of those also held
                          commits on no remote at all.
* unpushed             -> KEEP. A commit on no remote ref survives ONLY in this
                          checkout.
* lane-stash-stranded  -> KEEP. The lane's own pinned/applied register is its
                          only handle on that work.
* open-pr / live-claim -> KEEP. An open PR or `refs/claims/<pr>-<sha12>` names
                          work in flight.
* live-process/live-cwd-> KEEP. `ps` argv + one bounded `lsof -a -d cwd` pass.
* recently-active      -> KEEP. Idle bound (default 24h) measured from the
                          NEWEST of HEAD's commit date, the worktree directory's
                          own mtime, its `.git` link file, and the admin entry's
                          HEAD/locked files. (The admin ENTRY DIRECTORY is
                          deliberately not stat'ed: every `git status` a lane
                          runs creates and removes `index.lock` inside it, so its
                          mtime is "now" for any touched worktree — including one
                          this tool itself just probed.)
* ignored-content      -> KEEP. `git status --porcelain` is SILENT about ignored
                          files and `git worktree remove` DELETES them without
                          refusing (measured), so the ignored half is probed
                          separately. Only exact regenerable-cache basenames are
                          tolerated; a gitignored `.env` is credentials that
                          exist nowhere else, and `.gitignore` does not make them
                          disposable. Extend with `--allow-ignored <basename>`.
* worktree-busy        -> KEEP. A stopped merge/rebase/cherry-pick/bisect is not
                          in `--porcelain`, and a CLEAN bisect on an ancestor
                          commit would otherwise read as finished.
* dir-gone             -> KEEP (not disk). The admin record may be the last
                          durable handle on a detached commit; `git worktree
                          prune` is left to the operator.

SAFE-QUARTILE ORDERING
----------------------
`--apply` removes the OLDEST-idle records first (`--apply` + `--oldest-first`,
the default), so an interrupted or capped sweep has already taken the least
ambiguous rows. `--max N` caps a single sweep.

Usage:
  python3 tools/fleet/worktree_reclaim.py                  # dry-run, both repos of a hub
  python3 tools/fleet/worktree_reclaim.py --repo <path>    # one repo, dry-run
  python3 tools/fleet/worktree_reclaim.py --repo <path> --apply --max 40
  python3 tools/fleet/worktree_reclaim.py --repo <path> --allow-ignored .data --apply
  python3 tools/fleet/worktree_reclaim.py --repo <path> --json
  python3 tools/fleet/worktree_reclaim.test.py --mutations

Exit: 0 pass completed (nothing failed), 2 usage/environment, 3 fail-closed
(nothing removed — a probe that decides a verdict could not be evaluated; use
--allow-degraded to accept a partial pass deliberately), 4 a removal failed.
"""
from __future__ import annotations

import argparse
import fnmatch
import json
import os
import shutil
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from pathlib import Path

#: Ignored content is DELETEABLE by `git worktree remove` WITHOUT a refusal
#: (measured: a worktree whose only dirt was an ignored `ignored.txt` reported an
#: empty `--porcelain` and the file ceased to exist on removal). So the clean gate
#: has to read the IGNORED half itself. Only pure regenerable caches are tolerated,
#: and only by exact basename: a gitignored `.env` is credentials that exist
#: nowhere else, and `.gitignore` does not make them disposable.
REGENERABLE_IGNORED = frozenset("""
__pycache__ *.pyc *.pyo .pytest_cache .mypy_cache .ruff_cache .tox .DS_Store
node_modules .venv venv .ci-selection .longmemeval_cache .wrangler
.playwright-mcp .ipynb_checkpoints htmlcov .hypothesis .cache dist build target
*.egg-info
""".split())

DEFAULT_IDLE_HOURS = 24.0
DEFAULT_JOBS = 8
GIT_TIMEOUT = 120
GH_TIMEOUT = 120
LANE_STASH_TIMEOUT = 120

#: Mounts whose checkouts are scratch, not lanes. Reported, never special-cased
#: by verdict — the predicates decide.
SCRATCH_PREFIXES = ("/private/tmp/", "/tmp/", str(Path.home() / ".cache") + "/")


# --------------------------------------------------------------------------- #
# small bounded subprocess helper
# --------------------------------------------------------------------------- #
@dataclass
class Proc:
    rc: int
    out: str
    err: str
    timed_out: bool = False


def run(argv: list[str], *, cwd: str | None = None, timeout: int = GIT_TIMEOUT) -> Proc:
    try:
        cp = subprocess.run(argv, cwd=cwd, capture_output=True, text=True, timeout=timeout)
        return Proc(cp.returncode, cp.stdout, cp.stderr)
    except subprocess.TimeoutExpired:
        return Proc(124, "", f"timeout after {timeout}s", True)
    except FileNotFoundError as exc:
        return Proc(127, "", str(exc))


def git(repo: str, *args: str, cwd: str | None = None, timeout: int = GIT_TIMEOUT) -> Proc:
    return run(["git", "-C", cwd or repo, *args], timeout=timeout)


# --------------------------------------------------------------------------- #
# probes — each answers exactly one question, and says when it cannot
# --------------------------------------------------------------------------- #
def probe_ancestry(repo: str, head: str, base: str) -> tuple[bool | None, str]:
    """Is every commit this worktree holds an ancestor of `base`?"""
    cp = git(repo, "merge-base", "--is-ancestor", head, base)
    if cp.rc == 0:
        return True, f"head={head[:12]} is an ancestor of {base}"
    if cp.rc == 1:
        return False, f"head={head[:12]} has commits {base} does not contain"
    return None, f"merge-base failed rc={cp.rc} {cp.err.strip()[:80]}"


def probe_clean(wt: str) -> tuple[int | None, str]:
    """`git status --porcelain` line count. None = unreadable (fail closed)."""
    cp = git(wt, "status", "--porcelain", cwd=wt)
    if cp.rc != 0:
        return None, f"status failed rc={cp.rc} {cp.err.strip()[:80]}"
    lines = [l for l in cp.out.splitlines() if l.strip()]
    return len(lines), (f"{len(lines)} uncommitted path(s)" if lines else "index empty")


def probe_ignored(wt: str, allow: frozenset[str]) -> tuple[list[str] | None, str]:
    """Ignored entries that `git worktree remove` would delete without refusing.

    Returns the NON-regenerable ones. None = unreadable (fail closed). An empty
    list means "only regenerable caches, or nothing ignored at all".
    """
    cp = git(wt, "status", "--porcelain", "--ignored=traditional",
             "--untracked-files=normal", cwd=wt)
    if cp.rc != 0:
        return None, f"status --ignored failed rc={cp.rc} {cp.err.strip()[:80]}"
    kept: list[str] = []
    for line in cp.out.splitlines():
        if not line.startswith("!! "):
            continue
        path = line[3:].strip().rstrip("/")
        base = os.path.basename(path)
        if base in allow or any(fnmatch.fnmatch(base, pat) for pat in allow if "*" in pat):
            continue
        kept.append(path)
    if kept:
        return kept, f"{len(kept)} ignored non-regenerable path(s): " + ", ".join(kept[:3])
    return [], "no ignored content outside the regenerable-cache allowlist"


def probe_unpushed(repo: str, head: str) -> tuple[int | None, str]:
    """Commits reachable from HEAD but from NO remote ref. None = unreadable."""
    cp = git(repo, "rev-list", "--count", head, "--not", "--remotes")
    if cp.rc != 0:
        return None, f"rev-list failed rc={cp.rc} {cp.err.strip()[:80]}"
    try:
        n = int(cp.out.strip() or "0")
    except ValueError:
        return None, f"rev-list unparseable: {cp.out.strip()[:40]!r}"
    return n, (f"{n} commit(s) on no remote ref" if n else "all commits on a remote")


def find_lane_stash_python(repo: str) -> str | None:
    """A >=3.12 interpreter able to run lane_stash.py, or None.

    `lane_stash.py` refuses a <3.12 interpreter; the system `python3` on this box
    is 3.9, so resolving `sys.executable` would make every stash probe answer
    "cannot run" — which this tool must treat as STRANDED (kept), silently
    protecting everything forever. So the sibling checkout's venv, `uv`, and the
    running interpreter are tried in that order and the winner is verified once.
    """
    here = Path(__file__).resolve()
    candidates: list[list[str]] = []
    for up in (here.parent, *here.parents):
        for name in ("tortoise", "agent-infra"):
            venv = up / name / ".venv" / "bin" / "python"
            if venv.exists():
                candidates.append([str(venv)])
        if up.name in ("tortoise", "agent-infra") and (up / ".venv/bin/python").exists():
            candidates.append([str(up / ".venv/bin/python")])
    candidates.append([sys.executable])
    for argv in candidates:
        cp = run([*argv, "-c", "import sys; raise SystemExit(0 if sys.version_info>=(3,12) else 1)"],
                 timeout=30)
        if cp.rc == 0:
            return argv[0]
    return None


def lane_stash_path(repo: str) -> str | None:
    """The lane_stash.py this repo's lanes use, if any."""
    here = Path(__file__).resolve()
    for up in (here.parent, *here.parents):
        for base in (up, up / "tortoise", up / "agent-infra"):
            p = base / "tools" / "lane_stash.py"
            if p.exists():
                return str(p)
    return None


def probe_stash(wt: str, stash_py: str | None, stash_interp: str | None) -> tuple[bool | None, str]:
    """True = something is stranded for THIS worktree. None = unreadable."""
    if not stash_py or not stash_interp:
        return None, "lane_stash.py or a >=3.12 interpreter not found — cannot verify"
    cp = run([stash_interp, stash_py, "list"], cwd=wt, timeout=LANE_STASH_TIMEOUT)
    if cp.rc != 0:
        return None, f"lane_stash list rc={cp.rc} {cp.err.strip()[:80]}"
    out = cp.out
    lines = out.splitlines()
    # Anchored on the lane BLOCK, not a bare substring: `(no pinned entries)` is
    # prose, and a stash SUBJECT is user-authored text that can contain the phrase.
    lane_line = next((i for i, l in enumerate(lines) if l.startswith("lane ")), None)
    has_pins = lane_line is None or not (
        lane_line + 1 < len(lines) and lines[lane_line + 1].strip() == "(no pinned entries)")
    if has_pins:
        return True, "lane_stash pin(s) held for this worktree"
    # A register row this lane OWNS is stranded only while the lane has NOT
    # applied it. `pop` deliberately moves the pin to
    # `refs/lane/<key>/applied/<sha>` and leaves the shared entry in place, so a
    # successfully restored stash stays marked OWN forever — treating that as
    # stranded would keep the worktree unreapable AND report a falsehood about
    # its own state.
    applied = {l.split()[0] for l in lines
               if l.strip().startswith(tuple("0123456789abcdef")) and "refs/lane/" in l}
    own_rows = [l.split()[1] for l in lines if " OWN" in l and len(l.split()) > 1]
    stranded = [sha for sha in own_rows if not any(a.startswith(sha[:12]) for a in applied)]
    if stranded:
        return True, f"own entry left in the shared stash register ({stranded[0][:12]})"
    return False, "no pin, no unapplied own register entry"


def github_slug(repo: str) -> str | None:
    """`owner/name` if origin is a GitHub remote, else None. No remote => no PRs."""
    cp = git(repo, "remote", "get-url", "origin")
    if cp.rc != 0:
        return None
    url = cp.out.strip()
    for marker in ("github.com:", "github.com/"):
        if marker in url:
            tail = url.split(marker, 1)[1]
            return tail[:-4] if tail.endswith(".git") else tail
    return None


def probe_open_prs(repo: str, gh: str) -> tuple[dict[str, int] | None, str]:
    """branch -> PR number for open PRs. None = could not be read (fail closed)."""
    if github_slug(repo) is None:
        # A checkout with no GitHub origin cannot BE a lane's PR head, so the gate
        # is not applicable rather than unreadable (the bash reaper's
        # PR_APPLICABLE=0 arm). This is the one non-fail-closed answer here, and
        # it is decided by the remote, not by the gh result.
        return {}, "no github remote — no open PR can name this checkout"
    limit = 400
    cp = run([gh, "pr", "list", "--state", "open", "--limit", str(limit + 1),
              "--json", "headRefName,number"], cwd=repo, timeout=GH_TIMEOUT)
    if cp.rc != 0:
        return None, f"gh pr list rc={cp.rc} {cp.err.strip()[:80]}"
    try:
        rows = json.loads(cp.out)
    except json.JSONDecodeError:
        return None, "gh pr list output unparseable"
    if len(rows) > limit:
        # A full page means a branch's PR can fall past the cut and read as "no PR",
        # which would be a silent over-reap. Declare it instead of assuming.
        return None, f"open-PR page truncated at {limit} — cannot verify"
    return {r["headRefName"]: r["number"] for r in rows if "headRefName" in r}, f"{len(rows)} open PR(s)"


def probe_claims(repo: str) -> tuple[set[str] | None, str]:
    """sha12 suffixes from refs/claims/<pr>-<sha12> — durable cross-box ownership."""
    cp = git(repo, "for-each-ref", "--format=%(refname)", "refs/claims/")
    if cp.rc != 0:
        return None, f"for-each-ref refs/claims failed rc={cp.rc}"
    shas: set[str] = set()
    for ref in cp.out.split():
        tail = ref.rsplit("/", 1)[-1]
        if "-" in tail:
            shas.add(tail.rsplit("-", 1)[-1])
    return shas, f"{len(shas)} claim ref(s)"


def probe_processes(wt: str, ps_out: str | None, cwd_map: dict[int, str] | None) -> tuple[str | None, str]:
    """A pid whose argv names the path, or whose cwd is inside it.

    An EMPTY or failed `ps`, and a missing/failed `lsof`, are NOT "no process
    holds it": on a loaded box `lsof` is exactly the probe that times out, and
    reading its failure as absence would make the gate inert for a whole sweep.
    Unreadable answers `("unreadable", ...)` and the record is KEPT.
    """
    if not ps_out:
        return "unreadable", "ps enumeration failed or empty — cannot verify"
    if cwd_map is None:
        return "unreadable", "lsof cwd probe unavailable — cannot verify"
    real = os.path.realpath(wt)
    for line in ps_out.splitlines()[1:]:
        parts = line.split(None, 2)
        if len(parts) < 3:
            continue
        pid, _, argv = parts
        if wt in argv or real in argv:
            return f"pid {pid} argv names the checkout", "live-process"
    for pid, cwd in cwd_map.items():
        if cwd == real or cwd.startswith(real + os.sep):
            return f"pid {pid} cwd inside the checkout", "live-cwd"
    return None, "no process holds it"


def load_ps() -> str | None:
    cp = run(["ps", "-Ao", "pid=,ppid=,command="], timeout=60)
    return f"PID PPID COMMAND\n{cp.out}" if cp.rc == 0 and cp.out.strip() else None


def load_cwds() -> dict[int, str] | None:
    """ONE bounded `lsof -a -d cwd` pass (never `lsof +D`, which walks).

    None = the probe could not be evaluated (missing binary, timeout, failure).
    """
    if not shutil.which("lsof"):
        return None
    cp = run(["lsof", "-a", "-d", "cwd", "-Fpn"], timeout=180)
    if not cp.out.strip() and (cp.rc != 0 or cp.timed_out):
        return None
    out, pid = {}, None
    for line in cp.out.splitlines():
        if line.startswith("p"):
            pid = line[1:].strip()
        elif line.startswith("n") and pid:
            try:
                out[int(pid)] = line[1:]
            except ValueError:
                pass
    return out


def probe_idle(wt: str, repo: str, head: str) -> tuple[float | None, str]:
    """Hours since the newest evidence of use. None = unreadable (fail closed)."""
    stamps: list[float] = []
    cp = git(repo, "log", "-1", "--format=%ct", head)
    if cp.rc != 0 or not cp.out.strip():
        return None, f"HEAD date unreadable rc={cp.rc}"
    stamps.append(float(cp.out.strip()))
    # The checkout's own directory moves whenever a lane writes in it. `git status`
    # does not write there, so this probe cannot shadow the signal it is reading.
    for rel in ("", ".git"):
        try:
            stamps.append(os.stat(os.path.join(wt, rel)).st_mtime)
        except OSError:
            pass
    # The admin ENTRY DIRECTORY is deliberately NOT stat'ed: every `git status` a
    # lane runs creates and removes `index.lock` inside it, so its mtime is
    # "now" for any worktree anyone has touched at all — including this tool's own
    # clean probe, which made the idle bound read 0.0h for a 30-day-idle fixture.
    # The entry's HEAD file only moves on checkout/reset, which is real activity.
    common = git(repo, "rev-parse", "--git-common-dir")
    if common.rc == 0:
        gdir = common.out.strip()
        if not os.path.isabs(gdir):
            gdir = os.path.join(repo, gdir)
        admin = Path(gdir) / "worktrees"
        if admin.is_dir():
            for entry in admin.iterdir():
                try:
                    # `<common>/worktrees/<id>/gitdir` holds `<worktree>/.git`.
                    target = (entry / "gitdir").read_text().strip()
                    if target.endswith("/.git"):
                        target = target[: -len("/.git")]
                    if Path(target).resolve() == Path(wt).resolve():
                        for fname in ("HEAD", "locked"):
                            try:
                                stamps.append((entry / fname).stat().st_mtime)
                            except OSError:
                                pass
                        break
                except OSError:
                    continue
    idle_h = (time.time() - max(stamps)) / 3600.0
    return idle_h, f"newest activity {idle_h:.1f}h ago"


# --------------------------------------------------------------------------- #
# enumeration + classification
# --------------------------------------------------------------------------- #
@dataclass
class Record:
    index: int
    path: str
    head: str = ""
    branch: str = ""
    detached: bool = False
    locked: bool = False
    bare: bool = False
    prunable: bool = False


def worktree_records(repo: str) -> list[Record]:
    cp = git(repo, "worktree", "list", "--porcelain", "-z")
    if cp.rc != 0:
        raise SystemExit(f"FAIL-CLOSED: git worktree list failed rc={cp.rc}: {cp.err.strip()}")
    recs: list[Record] = []
    cur: Record | None = None
    for tok in cp.out.split("\0"):
        if not tok.strip():
            continue
        key, _, val = tok.partition(" ")
        if key == "worktree":
            cur = Record(index=len(recs), path=val)
            recs.append(cur)
        elif cur is None:
            continue
        elif key == "HEAD":
            cur.head = val
        elif key == "branch":
            cur.branch = val[len("refs/heads/"):] if val.startswith("refs/heads/") else val
        elif key == "detached":
            cur.detached = True
        elif key == "locked":
            cur.locked = True
        elif key == "bare":
            cur.bare = True
        elif key == "prunable":
            cur.prunable = True
    return recs


@dataclass
class Context:
    repo: str
    base: str
    self_cwd: str
    idle_hours: float
    open_prs: dict[str, int] | None
    pr_detail: str
    claim_shas: set[str] | None
    claim_detail: str
    ps_out: str | None
    cwd_map: dict[int, str] | None
    stash_py: str | None
    stash_interp: str | None
    ignored_allow: frozenset[str]
    notes: list[str] = field(default_factory=list)


def build_context(repo: str, base: str, idle_hours: float,
                  ignored_allow: frozenset[str] = REGENERABLE_IGNORED) -> Context:
    cp = git(repo, "rev-parse", "--abbrev-ref", "--symbolic-full-name", base)
    base_ref = cp.out.strip() if cp.rc == 0 and cp.out.strip() else base
    prs, pr_detail = probe_open_prs(repo, os.environ.get("RECLAIM_GH", "gh"))
    claims, claim_detail = probe_claims(repo)
    stash_py = lane_stash_path(repo)
    stash_interp = find_lane_stash_python(repo) if stash_py else None
    return Context(repo=repo, base=base_ref, self_cwd=os.path.realpath(os.getcwd()),
                   idle_hours=idle_hours, open_prs=prs, pr_detail=pr_detail,
                   claim_shas=claims, claim_detail=claim_detail,
                   ps_out=load_ps(), cwd_map=load_cwds(),
                   stash_py=stash_py, stash_interp=stash_interp,
                   ignored_allow=ignored_allow)


def in_progress_operation(wt: str, repo: str) -> str:
    """A stopped merge/rebase/cherry-pick/bisect, or "".

    `--porcelain` does not report one, and a CLEAN `git bisect` sitting on an
    ancestor commit would otherwise read as finished.
    """
    markers = ("MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "BISECT_LOG",
               "rebase-merge", "rebase-apply", "sequencer")
    common = git(repo, "rev-parse", "--git-common-dir")
    if common.rc != 0:
        return ""
    gdir = common.out.strip()
    if not os.path.isabs(gdir):
        gdir = os.path.join(repo, gdir)
    admin = Path(gdir) / "worktrees"
    for entry in (admin.iterdir() if admin.is_dir() else []):
        try:
            target = (entry / "gitdir").read_text().removesuffix("\n")
            if target.endswith("/.git"):
                target = target[: -len("/.git")]
            if Path(target).resolve() != Path(wt).resolve():
                continue
            for name in markers:
                if (entry / name).exists():
                    return f"{name} present in the worktree admin dir"
        except OSError:
            continue
    return ""


def is_primary(rec: "Record") -> bool:
    """The shared checkout other lanes' git calls resolve against. Never a candidate."""
    return rec.index == 0


def claim_gate(rec: "Record", ctx: Context) -> tuple[str | None, str]:
    """(reason, detail) when a durable claim names this head, else (None, "").

    `refs/claims/<pr>-<sha12>` is the cross-box ownership register
    (`scripts/orchestrator-harness/claims.sh`); it survives the session that made
    it, so it outranks any liveness read. Unreadable => the record is KEPT.
    """
    if ctx.claim_shas is None:
        return "claims-unreadable", ctx.claim_detail
    if rec.head[:12] in ctx.claim_shas:
        return "live-claim", f"refs/claims/*-{rec.head[:12]} names this head"
    return None, ""


def pr_gate(rec: "Record", ctx: Context) -> tuple[str | None, str]:
    """(reason, detail) when an OPEN PR heads this worktree's branch, else (None, "").

    A by-branch gate only: two worktrees can share a branch, so this can over-keep
    but never over-reap. Unreadable => KEPT.
    """
    if ctx.open_prs is None:
        return "open-pr-unreadable", ctx.pr_detail
    if rec.branch and rec.branch in ctx.open_prs:
        return "open-pr", f"open PR #{ctx.open_prs[rec.branch]} heads {rec.branch}"
    return None, ""


def classify(rec: Record, ctx: Context) -> dict:
    """Return {verdict, reason, detail, idle_h}. First failing predicate wins."""
    row = {"index": rec.index, "path": rec.path, "head": rec.head, "branch": rec.branch,
           "detached": rec.detached, "verdict": "KEEP", "reason": "", "detail": "",
           "idle_h": None, "scratch": rec.path.startswith(SCRATCH_PREFIXES)}

    def keep(reason: str, detail: str = "") -> dict:
        row["reason"], row["detail"] = reason, detail
        return row

    # ---- structural guards: never a removal candidate at all --------------
    if is_primary(rec):
        return keep("primary-checkout", "worktree list index 0 — the shared checkout")
    if rec.bare:
        return keep("bare", "no working tree")
    real = os.path.realpath(rec.path)
    if ctx.self_cwd == real or ctx.self_cwd.startswith(real + os.sep):
        return keep("self-checkout", "contains this process's cwd")
    if rec.locked:
        return keep("worktree-locked", "`git worktree lock` is set")
    if not os.path.isdir(rec.path):
        return keep("dir-gone", "checkout directory already absent (admin record only, no disk)")

    # ---- the four evidence predicates ------------------------------------
    dirty, dirty_detail = probe_clean(rec.path)
    if dirty is None:
        return keep("clean-unreadable", dirty_detail)
    if dirty:
        return keep("uncommitted", dirty_detail)

    ignored, ignored_detail = probe_ignored(rec.path, ctx.ignored_allow)
    if ignored is None:
        return keep("ignored-unreadable", ignored_detail)
    if ignored:
        return keep("ignored-content", ignored_detail)

    busy = in_progress_operation(rec.path, ctx.repo)
    if busy:
        return keep("worktree-busy", busy)

    stranded, stash_detail = probe_stash(rec.path, ctx.stash_py, ctx.stash_interp)
    if stranded is None:
        return keep("stash-unreadable", stash_detail)
    if stranded:
        return keep("lane-stash-stranded", stash_detail)

    if ctx.claim_shas is None:
        return keep(*claim_gate(rec, ctx))
    reason, detail = claim_gate(rec, ctx)
    if reason:
        return keep(reason, detail)

    reason, detail = pr_gate(rec, ctx)
    if reason:
        return keep(reason, detail)

    held, held_why = probe_processes(rec.path, ctx.ps_out, ctx.cwd_map)
    if held == "unreadable":
        return keep("processes-unreadable", held_why)
    if held:
        return keep(held_why, held)

    unpushed, unpushed_detail = probe_unpushed(ctx.repo, rec.head)
    if unpushed is None:
        return keep("unpushed-unreadable", unpushed_detail)
    if unpushed:
        return keep("unpushed", unpushed_detail)

    merged, merged_detail = probe_ancestry(ctx.repo, rec.head, ctx.base)
    if merged is None:
        return keep("ancestry-unreadable", merged_detail)
    if not merged:
        return keep("unmerged", merged_detail)

    idle_h, idle_detail = probe_idle(rec.path, ctx.repo, rec.head)
    if idle_h is None:
        return keep("idle-unreadable", idle_detail)
    row["idle_h"] = round(idle_h, 1)
    if idle_h < ctx.idle_hours:
        return keep("recently-active", f"{idle_detail} < {ctx.idle_hours:g}h bound")

    row["verdict"] = "REAP"
    row["reason"] = "finished"
    row["detail"] = f"merged-into:{ctx.base} clean unpushed=0 stash=0 idle={idle_h:.1f}h"
    return row


def classify_all(recs: list[Record], ctx: Context, jobs: int) -> list[dict]:
    with ThreadPoolExecutor(max_workers=max(1, jobs)) as ex:
        return list(ex.map(lambda r: classify(r, ctx), recs))


# --------------------------------------------------------------------------- #
# removal
# --------------------------------------------------------------------------- #
def remove_one(row: dict, ctx: Context) -> tuple[bool, str]:
    """`git worktree remove` (never --force), then RE-CLASSIFY once.

    The re-check exists because classification and removal are separated by the
    whole pass: whatever moved in between takes the KEEP arm. Removal is refused
    by git itself if the checkout acquired changes, so the second gate is a
    second opinion on the same question, not a substitute.
    """
    rec = Record(index=row["index"], path=row["path"], head=row["head"],
                 branch=row["branch"], detached=row["detached"])
    # `locked`/`bare` come from the record captured at enumeration (git itself also
    # refuses a locked removal, so that arm is a second gate, not the only one);
    # `open_prs`/`claim_shas` are deliberately the per-sweep snapshot — a PR opened
    # inside a sweep is accepted staleness, stated here rather than implied away.
    again = classify(rec, Context(**{**ctx.__dict__, "ps_out": load_ps(),
                                     "cwd_map": load_cwds()}))
    if again["verdict"] != "REAP":
        return False, f"re-check said {again['reason']}: {again['detail']}"
    cp = git(ctx.repo, "worktree", "remove", "--", row["path"], timeout=600)
    if cp.rc != 0:
        if cp.rc == 124:
            return False, "git worktree remove timed out"
        return False, f"git worktree remove rc={cp.rc}: {cp.err.strip()[:120]}"
    return True, "removed"


def dir_size_bytes(path: str, cap_entries: int = 20000) -> int:
    """Best-effort apparent size, BOUNDED (no unbounded walk)."""
    total, seen = 0, 0
    try:
        for root, dirs, files in os.walk(path):
            dirs[:] = [d for d in dirs if d != ".git"]
            for f in files:
                seen += 1
                if seen > cap_entries:
                    return total
                try:
                    total += os.lstat(os.path.join(root, f)).st_size
                except OSError:
                    pass
    except OSError:
        pass
    return total


# --------------------------------------------------------------------------- #
# report
# --------------------------------------------------------------------------- #
def summarise(rows: list[dict]) -> dict:
    counts: dict[str, int] = {}
    for r in rows:
        counts[r["reason"]] = counts.get(r["reason"], 0) + 1
    return counts


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Reclaim provably-finished git worktrees.")
    ap.add_argument("--repo", action="append", help="repo path (repeatable; default: hub checkouts)")
    ap.add_argument("--base", default="origin/main", help="base ref (default origin/main)")
    ap.add_argument("--idle-hours", type=float, default=DEFAULT_IDLE_HOURS)
    ap.add_argument("--jobs", type=int, default=DEFAULT_JOBS)
    ap.add_argument("--apply", action="store_true", help="actually remove (default: dry-run)")
    ap.add_argument("--max", type=int, default=0, help="cap removals in one pass (0 = all; must be >= 0)")
    ap.add_argument("--allow-ignored", action="append", default=[], metavar="BASENAME",
                    help="extend the regenerable-cache allowlist with one ignored basename")
    ap.add_argument("--allow-degraded", action="store_true",
                    help="exit 0 even when a deciding probe was unreadable (default: exit 3)")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--quiet", action="store_true", help="counts only, no per-record rows")
    args = ap.parse_args(argv)
    if args.max < 0:
        ap.error("--max must be >= 0 (`--max -1` would mean 'all but the newest row')")
    allow = REGENERABLE_IGNORED | frozenset(args.allow_ignored)

    repos = args.repo or default_repos()
    if not repos:
        print("no repo given and no hub checkout found", file=sys.stderr)
        return 2

    rows: list[dict] = []
    notes: list[str] = []
    fail_closed = False
    unreadable = 0
    for repo in repos:
        if not os.path.isdir(repo):
            print(f"skip (not a directory): {repo}", file=sys.stderr)
            continue
        try:
            recs = worktree_records(repo)
        except SystemExit as exc:
            print(exc, file=sys.stderr)
            fail_closed = True
            continue
        ctx = build_context(repo, args.base, args.idle_hours, allow)
        for label, value in (("gh", ctx.open_prs), ("claims", ctx.claim_shas)):
            if value is None:
                notes.append(f"{repo}: {label} unreadable -> every record it decides is KEPT")
        if ctx.stash_py is None or ctx.stash_interp is None:
            notes.append(f"{repo}: lane_stash unreadable (py={ctx.stash_interp}) -> stash gate KEEPS all")
        if not ctx.ps_out:
            notes.append(f"{repo}: ps enumeration empty -> every record KEPT (processes-unreadable)")
        if ctx.cwd_map is None:
            notes.append(f"{repo}: lsof cwd probe unavailable -> every record KEPT (processes-unreadable)")
        got = classify_all(recs, ctx, args.jobs)
        unreadable += sum(1 for r in got if r["reason"].endswith("-unreadable"))
        for r in got:
            r["repo"] = repo
        rows.extend(got)

    # Oldest idle first, so a capped sweep takes the least ambiguous rows.
    reap = [r for r in rows if r["verdict"] == "REAP"]
    reap.sort(key=lambda r: (-(r["idle_h"] or 0.0), r["path"]))
    reapable = reap if not args.max else reap[: args.max]

    removed, failed, freed = 0, 0, 0
    if args.apply:
        # ONE refreshed context per repo for the whole removal loop: `gh`, `ps` and
        # `lsof` are per-pass facts, and re-reading them per record would make the
        # removal loop cost more than the classification it acts on.
        fresh: dict[str, Context] = {}
        for r in reapable:
            if r["repo"] not in fresh:
                fresh[r["repo"]] = build_context(r["repo"], args.base, args.idle_hours, allow)
            ctx = fresh[r["repo"]]
            size = dir_size_bytes(r["path"])
            ok, why = remove_one(r, ctx)
            r["removed"] = ok
            r["remove_detail"] = why
            if ok:
                removed += 1
                freed += size
                print(f"REMOVED  {r['path']}  ({size/1e6:.0f} MB apparent, idle {r['idle_h']}h)")
            else:
                failed += 1
                print(f"FAILED   {r['path']}  {why}")

    if args.json:
        print(json.dumps({"rows": rows, "counts": summarise(rows),
                          "removed": removed, "failed": failed, "apparent_bytes_freed": freed,
                          "notes": notes}, indent=2))
    else:
        if not args.quiet:
            print(f"{'VERDICT':8s} {'REASON':22s} {'IDLE':>6s}  PATH")
            for r in rows:
                idle = f"{r['idle_h']:.0f}h" if r["idle_h"] is not None else "-"
                tag = " (scratch)" if r["scratch"] else ""
                print(f"{r['verdict']:8s} {r['reason']:22s} {idle:>6s}  {r['path']}{tag}")
            print()
        counts = summarise(rows)
        total = len(rows)
        print(f"WORKTREES={total} REAPABLE={len(reap)} "
              + " ".join(f"{k}={v}" for k, v in sorted(counts.items(), key=lambda kv: -kv[1])))
        if args.max:
            print(f"SWEEP_CAP={args.max} (of {len(reap)} reapable, oldest-idle first)")
        if args.apply:
            print(f"MODE=apply REMOVED={removed} FAILED={failed} "
                  f"APPARENT_MB_FREED={freed/1e6:.0f}")
        else:
            print("MODE=dry-run — nothing removed. Re-run with --apply.")
        for n in notes:
            print(f"NOTE {n}")
        if unreadable:
            print(f"UNREADABLE_PROBES={unreadable} — those records were KEPT; "
                  "a pass that could not evaluate a deciding probe is NOT a pass")
    if unreadable and not args.allow_degraded:
        # The defect this tool exists to fix is a pass that prints SUCCESS having
        # measured nothing. An unusable deciding probe therefore exits 3, not 0.
        return 3
    if args.apply and failed:
        return 4
    return 3 if fail_closed else 0


def default_repos() -> list[str]:
    """The hub's two checkouts, if this is that hub."""
    hub = Path.home() / "Documents" / "GitHub"
    return [str(hub / n) for n in ("tortoise", "agent-infra") if (hub / n / ".git").exists()]


if __name__ == "__main__":
    raise SystemExit(main())
