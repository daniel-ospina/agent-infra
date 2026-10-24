#!/usr/bin/env python3
"""tools/fleet/dispatch_preflight.py — refuse a lane dispatch into a worktree that
has NOTHING TO LAND.

WHY THIS EXISTS (the measurement, not a hunch)
----------------------------------------------
On 2026-10-18 the Mac fleet was measured directly: 14 live ``pi`` lanes, 12 of them
with **+0 commits**, and the fleet read as "busy but unproductive". The cause was
not model behaviour — the previous day's hypothesis ("lanes stall after 15-20
minutes") does not survive the transcripts. Every zero-commit lane had run to
completion and written a final report.

The discriminator is a property of the WORKTREE, and it is perfectly predictive
over the measured set:

    worktree HEAD already contained in origin/main  ->  12 lanes, 12 with +0 commits
    worktree HEAD NOT contained in origin/main      ->   3 lanes,  3 with commits (+7)

Twelve of fifteen dispatched worktrees sat on a commit that ``origin/main``
already contained — the owner's own reading, "everything else +0 (sitting on
main's tip)". A lane spawned there cannot land anything: there is no diff to
commit. It spends its whole run discovering that, reports a stand-down, and in
the measured set then hung at 0.00 % CPU for up to 9 hours (the process outlived
its own transcript, because the turn had ended and nothing exited).

So the expensive thing is the DISPATCH, not the lane. The check is local,
deterministic and needs no network: if the worktree has no content to land and
no uncommitted changes, do not spawn a lane into it.

WHAT "NOTHING TO LAND" MEANS — THREE CASES, NOT ONE
----------------------------------------------------
A naive read of the incident would check only ``HEAD == origin/main``, and that
read is WRONG in both directions:

1. **HEAD is an ancestor of the base.** The branch is fully contained; classic
   "sitting on main's tip". No content.
2. **HEAD carries commits, but ships exactly the base's tree.** A SQUASH-merged
   branch looks *ahead* by commit count while shipping exactly the same tree as
   the base. Refusing on "ahead == 0" alone would let this case through and
   re-create the same wasted lane with a larger ``ahead=`` number to make it
   look productive.
3. **The working tree is dirty.** Uncommitted or untracked changes ARE work to
   land even when HEAD is the base tip — this is a lane that was interrupted
   mid-edit (measured: ``retire-fork``, +0 commits with tests edited and a new
   doc untracked, blocked by the working-tree-discard guard #709). Refusing here
   would destroy real work, so dirty worktrees are ALLOWED. That asymmetry is
   deliberate: a false refusal costs a delay, a false allow costs an untouched
   worktree, and only one of those loses work.

THE PREDICATE IS TWO DIFFS, AND BOTH MUST BE NON-EMPTY
------------------------------------------------------
Case 2 is why a single diff is not enough, and the measured shape of it is
precise: for a squash merge, ``tree(HEAD) == tree(base)`` while HEAD is NOT an
ancestor of the base, so ``merge-base`` is the FORK POINT and
``diff(merge-base, HEAD)`` is the branch's own delta — NON-EMPTY. Diffing only
against the merge-base therefore reports HAS-WORK for exactly the case this
tool exists to refuse (verified against a real squash: ahead=1, identical trees,
``diff(merge-base,HEAD)=1``).

So there are two distinct questions and a worktree must answer YES to both:

    own_delta             = diff(merge-base, HEAD) is non-empty   (I changed something)
    tree_differs_from_base = diff(base, HEAD)      is non-empty   (it would still change base)

    contained HEAD       -> own_delta=0                     -> NO-WORK
    squash-merged        -> tree_differs_from_base=0        -> NO-WORK
    real work            -> both 1                          -> HAS-WORK

``tree_differs_from_base`` alone would also be wrong: a branch whose change was
ALREADY applied upstream in a different form shows an empty base diff while
carrying no own delta, and either read on its own admits one of the two cases.

UNREADABLE IS A REFUSAL, NOT AN ALLOW
-------------------------------------
A probe that cannot read the git state cannot answer the question, so it must not
report "there is work" (the repo's own "a failed probe is UNKNOWN, not ample"
rule). Unreadable exits with its OWN code so a caller can tell "nothing to do"
from "I could not read it" — those need different operator responses.

EXIT CODES
----------
    0  HAS-WORK      dispatch may proceed
    3  NO-WORK       refuse: nothing to land (no diff, no dirty files)
    4  UNREADABLE   refuse: could not read the git state (fail closed)

USAGE
-----
    python3 tools/fleet/dispatch_preflight.py .worktrees/wt-1856
    python3 tools/fleet/dispatch_preflight.py --base origin/main --json <worktree>
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from typing import List, Optional, Sequence, Tuple

EXIT_HAS_WORK = 0
EXIT_NO_WORK = 3
EXIT_UNREADABLE = 4

VERDICT_HAS_WORK = "HAS-WORK"
VERDICT_NO_WORK = "NO-WORK"
VERDICT_UNREADABLE = "UNREADABLE"


def _git(worktree: str, args: Sequence[str], timeout: int = 60) -> Tuple[int, str]:
    """Run one git command in the worktree. Returns (rc, stdout-stripped).

    rc is the REAL exit status; a missing ``git`` binary surfaces as rc != 0
    with the OSError text, so no caller mistakes "could not run" for "ran and
    said no".
    """
    try:
        p = subprocess.run(
            ["git", "-C", worktree, *args],
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except (OSError, subprocess.SubprocessError) as exc:  # pragma: no cover - env fault
        return 127, str(exc)
    return p.returncode, p.stdout.strip()


def _resolve_base(worktree: str, base: str) -> Optional[str]:
    """Resolve ``base`` to a commit sha, preferring the remote-tracking ref.

    A caller may pass a bare ``main``; the fleet always dispatches against
    ``origin/main``. Resolving the caller's token VERBATIM first keeps the tool
    honest when a test supplies its own base, and the ``origin/`` fallback is
    only used when the token itself does not resolve.
    """
    for candidate in (base, f"origin/{base}"):
        rc, sha = _git(worktree, ["rev-parse", "--verify", "--quiet", f"{candidate}^{{commit}}"])
        if rc == 0 and sha:
            return sha
    return None


def _diff_is_nonempty(worktree: str, a: str, b: str) -> Optional[bool]:
    """True if ``a`` and ``b`` have different trees; None if git could not say.

    ``git diff --quiet`` exits 0 for "identical", 1 for "differs", and >1 for
    an ERROR — so 1 must not be conflated with a failure, and a failure must
    not be read as either answer.
    """
    rc, _ = _git(worktree, ["diff", "--quiet", a, b])
    if rc == 0:
        return False
    if rc == 1:
        return True
    return None


def evaluate(worktree: str, base: str = "origin/main") -> dict:
    """Classify a worktree as HAS-WORK / NO-WORK / UNREADABLE.

    Pure-ish: reads git state only, never writes and never touches the network.
    """
    result = {
        "worktree": os.path.realpath(worktree),
        "base_token": base,
        "verdict": VERDICT_UNREADABLE,
        "why": [],
        "head": None,
        "base_sha": None,
        "ahead": None,
        "own_delta": None,
        "tree_differs_from_base": None,
        "dirty": None,
    }
    why: List[str] = result["why"]

    if not os.path.isdir(worktree):
        why.append(f"worktree path does not exist: {worktree}")
        return result

    rc, inside = _git(worktree, ["rev-parse", "--is-inside-work-tree"])
    if rc != 0 or inside != "true":
        why.append(f"not a git work tree (git said rc={rc} {inside!r})")
        return result

    rc, head = _git(worktree, ["rev-parse", "--verify", "--quiet", "HEAD^{commit}"])
    if rc != 0 or not head:
        # An empty repo / unborn HEAD. There is no content to land, but this is
        # also not a state a lane should be dispatched into.
        why.append("HEAD does not resolve (unborn or detached-empty worktree)")
        return result
    result["head"] = head

    base_sha = _resolve_base(worktree, base)
    if base_sha is None:
        # We cannot see the base, so we cannot answer the question. Fail closed.
        why.append(f"base {base!r} does not resolve in this worktree (no origin/{base} either)")
        return result
    result["base_sha"] = base_sha

    # `--untracked-files=normal` is passed EXPLICITLY: `git status --porcelain`
    # honours the ambient `status.showUntrackedFiles`, and a config value of `no`
    # (set in any global/system config file) hides untracked files entirely,
    # silently turning an untracked-only worktree into NO-WORK — the false
    # refusal in the one direction this tool must never flip (verified: with the
    # config set, plain --porcelain returned empty for a worktree holding a new
    # file; with the flag it reported `?? new.md`).
    rc, status = _git(worktree, ["status", "--porcelain", "--untracked-files=normal"])
    if rc != 0:
        why.append(f"git status failed (rc={rc}) — cannot tell dirty from clean")
        return result
    dirty_lines = [ln for ln in status.splitlines() if ln.strip()]
    result["dirty"] = len(dirty_lines)

    rc, merge_base = _git(worktree, ["merge-base", head, base_sha])
    if rc != 0 or not merge_base:
        why.append(f"no merge-base between HEAD {head[:12]} and {base} {base_sha[:12]} "
                   "(unrelated histories?) — cannot compute a diff")
        return result

    rc, ahead_s = _git(worktree, ["rev-list", "--count", f"{base_sha}..{head}"])
    result["ahead"] = int(ahead_s) if rc == 0 and ahead_s.isdigit() else None

    # THE PREDICATE: two diffs, and BOTH must be non-empty. See the module header
    # for why one is not enough (the squash-merge trap) and why neither alone is
    # sufficient (a change already applied upstream).
    own_delta = _diff_is_nonempty(worktree, merge_base, head)
    differs = _diff_is_nonempty(worktree, base_sha, head)
    if own_delta is None or differs is None:
        why.append("git diff failed to report a verdict — cannot tell whether a diff exists")
        return result
    result["own_delta"] = own_delta
    result["tree_differs_from_base"] = differs

    if result["dirty"]:
        result["verdict"] = VERDICT_HAS_WORK
        why.append(f"the working tree has {result['dirty']} uncommitted/untracked path(s) — "
                   "that IS work to land")
        for ln in dirty_lines[:5]:
            why.append(f"    {ln}")
    elif own_delta and differs:
        result["verdict"] = VERDICT_HAS_WORK
        why.append(f"HEAD {head[:12]} carries content not in {base} (ahead={result['ahead']})")
    else:
        result["verdict"] = VERDICT_NO_WORK
        if not own_delta:
            why.append(f"HEAD {head[:12]} is already contained in {base} "
                       f"(ahead={result['ahead']}, no own delta)")
        else:
            why.append(f"HEAD {head[:12]} is ahead={result['ahead']} but ships the SAME TREE as "
                       f"{base} — the change is already landed (squash-merged or re-applied)")
        why.append("a lane dispatched here has nothing to land: it can only stand down")

    return result


def render_block(res: dict) -> str:
    icon = {VERDICT_HAS_WORK: "✅", VERDICT_NO_WORK: "⛔", VERDICT_UNREADABLE: "⚠️ "}[res["verdict"]]
    lines = [
        f"{icon} dispatch preflight — {res['verdict']}",
        f"   worktree: {res['worktree']}",
        f"   base:     {res['base_token']}"
        + (f" ({str(res['base_sha'])[:12]})" if res["base_sha"] else ""),
    ]
    for w in res["why"]:
        lines.append(f"   {w}" if not w.startswith("    ") else f"   {w}")
    if res["verdict"] == VERDICT_NO_WORK:
        lines.append("")
        lines.append("   → Do NOT spawn a lane here. Point the dispatch at work that is still open,")
        lines.append("     or let the lane that owns the change keep it. Re-check with:")
        lines.append(f"       python3 tools/fleet/dispatch_preflight.py {res['worktree']}")
    return "\n".join(lines)


def parse_args(argv: Optional[Sequence[str]] = None) -> argparse.Namespace:
    ap = argparse.ArgumentParser(
        description="Refuse a lane dispatch into a worktree that has nothing to land.",
    )
    ap.add_argument("worktree", help="path to the worktree a lane would be dispatched into")
    ap.add_argument("--base", default="origin/main",
                    help="base ref the dispatch targets (default: origin/main)")
    ap.add_argument("--json", action="store_true", help="emit the structured verdict as JSON")
    ap.add_argument("--quiet", action="store_true", help="no block output; exit code only")
    return ap.parse_args(argv)


def main(argv: Optional[Sequence[str]] = None) -> int:
    ns = parse_args(argv)
    res = evaluate(ns.worktree, ns.base)
    if ns.json:
        print(json.dumps(res, indent=2, sort_keys=True))
    elif not ns.quiet:
        print(render_block(res))
    if res["verdict"] == VERDICT_HAS_WORK:
        return EXIT_HAS_WORK
    if res["verdict"] == VERDICT_NO_WORK:
        return EXIT_NO_WORK
    return EXIT_UNREADABLE


if __name__ == "__main__":
    sys.exit(main())
