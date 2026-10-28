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

THE PREDICATE: WOULD LANDING HEAD STILL CHANGE THE BASE?
--------------------------------------------------------
The question is not "is HEAD different from the base" — it is "does HEAD still
add something to the base". Those are different questions, and the first one
answers WRONGLY in the most common lifecycle shape of all.

``would_change_base`` is a THREE-WAY MERGE, not a tree comparison:

    merged = git merge-tree --write-tree <base> <head>
    would_change_base = merged_tree != tree(base)

Why a tree comparison (``diff --quiet base head``) is not enough — the measured
falsification, on this repo's git 2.43: branch F adds ``feat.txt``, main takes F
as a SQUASH commit S (so ``tree(F) == tree(S)``), and main then ADVANCES to M.
Now ``tree(F) != tree(M)`` only because M moved, not because F carries anything
unlanded — ``feat.txt`` is byte-identical in ``origin/main``. A tree comparison
reports HAS-WORK, exit 0, and the reason string states the OPPOSITE of the
truth ("HEAD carries content not in origin/main"), for exactly the lane this
tool exists to refuse. The three-way merge yields ``tree(M)`` itself, so the
answer is NO-WORK — and the reason can say "already landed".

Symmetrically, ``diff(merge-base, HEAD)`` is NOT the answer either: for a squash
merge ``merge-base`` sits at the FORK POINT, so the branch's own delta is
non-empty for a branch whose whole content is already in the base. It is kept
here as ``own_delta`` EVIDENCE — it is what lets the tool tell an operator
"already contained" apart from "ahead, but already landed" — but it does not
decide the verdict on its own.

    contained HEAD                  -> merged == tree(base)   -> NO-WORK
    squash-merged                   -> merged == tree(base)   -> NO-WORK
    squash-merged, base then moved  -> merged == tree(base)   -> NO-WORK
    real unlanded work              -> merged != tree(base)   -> HAS-WORK
    a CONFLICTING branch            -> merge-tree exits 1     -> HAS-WORK
    a merge DRIVER discarded HEAD   -> merged == tree(base)
                                       but HEAD's paths differ -> UNREADABLE

A conflict is HAS-WORK, not UNREADABLE: git answered, and a branch that cannot
merge cleanly certainly carries something that still has to land. Requires
git >= 2.38 (``merge-tree --write-tree``); an older git answers rc 129 and the
reason NAMES that, rather than reporting a generic "cannot tell" — the verdict is
then UNREADABLE, never a guess.

AND THE MERGE IS NOT TRUSTED ON ITS OWN — the contained-delta read
---------------------------------------------------------------
A repo-declared MERGE DRIVER (``.gitattributes: *.lock merge=ours``) makes the
merge KEEP THE BASE SIDE, so ``merged == tree(base)`` for a branch that really
does carry unlanded work: a false NO-WORK, the direction this tool must never
flip (measured with a `true` driver: base `main-content`, branch
`branch-content`, merge returns the base tree). So whenever the merge says
"nothing changes", the tool also asks the path-level question — for every path
HEAD changed relative to the fork point, is the base's content IDENTICAL? If the
merge discarded HEAD's change, the two reads disagree and the answer is
UNREADABLE ("already landed" cannot be certified), never NO-WORK.

The same read decides a CONFLICT the merge cannot: a branch whose whole delta is
already in the base can still conflict with a LATER edit to the same path.

    BOUNDARY, stated: squash-merged and then the base REWROTE THE SAME PATH.
    HEAD's bytes are not the base's bytes, so every read available here says
    "this path differs" — the verdict is HAS-WORK. Conservative (a wasted lane
    at worst), and recorded rather than papered over: the NO-WORK rule is about
    an advance on OTHER paths.

THE PROBE MUST BE ABOUT THE TARGET, NOT ABOUT WHATEVER REPO ENCLOSES IT
----------------------------------------------------------------------
``git -C <dir>`` WALKS UPWARD. Every ``.worktrees/<name>`` lives inside the
superproject, so a stale or half-pruned worktree — its ``.git`` link gone, its
notes still inside — makes every read land in the MAIN CHECKOUT and the tool
reports a confident verdict about a tree nobody asked about (measured: a nested
``.worktrees/stale/`` answered NO-WORK with the superproject's HEAD, and
HAS-WORK when the superproject was one commit ahead — i.e. a lane dispatched
into a plain directory whose commits would go onto the main checkout's branch).
So the target's own root is asserted: ``rev-parse --show-toplevel`` must be the
realpath of the worktree passed in, else UNREADABLE.

UNREADABLE IS A REFUSAL, NOT AN ALLOW
-------------------------------------
A probe that cannot read the git state cannot answer the question, so it must not
report "there is work" (the repo's own "a failed probe is UNKNOWN, not ample"
rule). Unreadable exits with its OWN code so a caller can tell "nothing to do"
from "I could not read it" — those need different operator responses.

EXIT CODES
----------
    0  HAS-WORK      dispatch may proceed
    3  NO-WORK       refuse: nothing to land (would not change the base, nothing dirty)
    4  UNREADABLE   refuse: the git state could not be read, OR the invocation was
                     malformed (a usage error is a refusal too — a caller that
                     writes "0 -> dispatch, anything else -> refuse" must not
                     dispatch on a typo in its own argv, and `--help` must not
                     read as HAS-WORK either)

ONE SIDE EFFECT, STATED
-----------------------
A three-way merge has to materialise its result, so ``merge-tree --write-tree``
writes ONE loose tree object into the worktree's object database (no ref, no
commit, nothing reachable). The tool writes nothing else, moves no ref, and
touches no network.

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


MERGE_TREE_TIMEOUT = 300


def _git(worktree: str, args: Sequence[str], timeout: int = 60,
         stdin: Optional[str] = None) -> Tuple[int, str]:
    """Run one git command in the worktree. Returns (rc, stdout-stripped).

    rc is the REAL exit status; a missing ``git`` binary surfaces as rc != 0
    with the OSError text, so no caller mistakes "could not run" for "ran and
    said no". A TIMEOUT surfaces the same way, and its text names the bound —
    an operator must be able to tell a slow read from a broken one.
    """
    try:
        p = subprocess.run(
            ["git", "-C", worktree, *args],
            capture_output=True,
            text=True,
            timeout=timeout,
            input=stdin,
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


def _head_delta_paths(worktree: str, merge_base: str, head: str) -> Optional[List[str]]:
    """The paths HEAD changed relative to the fork point; None if unreadable."""
    rc, out = _git(worktree, ["diff", "--name-only", "-z", merge_base, head])
    if rc != 0:
        return None
    return [p for p in out.split("\0") if p]


def _delta_is_contained(worktree: str, base_sha: str, head: str,
                        paths: Sequence[str]) -> Optional[bool]:
    """True if every path HEAD changed already has the SAME content in the base.

    This is the path-level answer to "is the branch's own delta already landed",
    and it is the half a three-way merge cannot be trusted for on its own: a
    repo-declared MERGE DRIVER (``.gitattributes: *.lock merge=ours``) makes the
    merge discard HEAD's content, so ``merged == tree(base)`` for a branch that
    really does carry unlanded work — a false NO-WORK, the direction this tool
    must never flip.

    Implemented as a SET INTERSECTION rather than a per-path fetch or a
    pathspec argument: ``git diff --quiet <base> <head> -- <paths...>`` has no
    ``--pathspec-from-file`` (measured: `git diff` answers rc 129 for it, unlike
    `git add`/`git commit`), and a branch that touched thousands of files would
    otherwise hit the argv limit. Both sides are read with ``-z`` and
    ``--no-renames``, so the path strings compare exactly and a rename shows up
    as two differences rather than one.
    """
    if not paths:
        return True
    rc, out = _git(worktree, ["diff", "--no-renames", "--name-only", "-z", base_sha, head])
    if rc != 0:
        return None
    differing = {p for p in out.split("\0") if p}
    return not any(p in differing for p in paths)


def _merge_tree(worktree: str, base_sha: str, head: str) -> Tuple[str, str]:
    """The three-way merge, as (status, payload).

    status is ``clean`` (payload = the merged tree oid), ``conflict`` (payload
    empty — git answered, the branch has work that cannot merge unattended) or
    ``error`` (payload = the reason, named for an operator: an unsupported git, a
    timeout, a failed read).

    ``--write-tree`` needs git >= 2.38; on anything older git answers rc 129 and
    the reason below says so, rather than reporting a generic "cannot tell" —
    the verdict is then UNREADABLE (fail closed), never a guess.
    """
    rc, out = _git(worktree, ["merge-tree", "--write-tree", base_sha, head],
                   timeout=MERGE_TREE_TIMEOUT)
    if rc == 1:
        return "conflict", ""
    if rc == 129:
        return "error", ("this git has no `merge-tree --write-tree` (git >= 2.38 is required) — "
                          "the three-way merge verdict is unavailable")
    if rc != 0:
        detail = out.splitlines()[0].strip() if out.strip() else f"rc={rc}"
        return "error", f"git merge-tree failed ({detail}) — cannot tell what would land"
    merged = out.splitlines()[0].strip() if out.strip() else ""
    if not merged:
        return "error", "git merge-tree printed no merged tree — cannot tell what would land"
    return "clean", merged


def _would_change_base(worktree: str, merge_base: str, base_sha: str,
                       head: str) -> Tuple[Optional[bool], str]:
    """(True if landing ``head`` on ``base_sha`` would still change the base, reason).

    THE THREE-WAY MERGE, not a tree comparison (see the module header for the
    measured falsification of the tree comparison: a squash-merged branch whose
    base has since advanced compares UNEQUAL while carrying nothing unlanded).

    And not the merge ALONE, in either direction:

    * a merge driver can make the merge discard HEAD's change, so a
      clean-but-identical result is only trusted when HEAD's own paths are ALSO
      already identical in the base;
    * a CONFLICT is not decided by either read on its own — a branch whose whole
      delta is already in the base can still conflict with a LATER edit to the
      same path (the squash-then-fixup shape), so the contained-delta read is
      consulted first.
    """
    status, payload = _merge_tree(worktree, base_sha, head)
    if status == "error":
        return None, payload

    if status == "clean":
        rc, base_tree = _git(worktree, ["rev-parse", f"{base_sha}^{{tree}}"])
        if rc != 0 or not base_tree:
            return None, "could not read the base's tree — cannot tell what would land"
        if payload != base_tree:
            return True, ""

    # The merge says "nothing changes" (clean-and-identical) or could not say
    # (conflict). Either way the deciding read is HEAD's OWN delta against the
    # base, path by path.
    paths = _head_delta_paths(worktree, merge_base, head)
    if paths is None:
        return None, "could not list the paths HEAD changed — cannot tell what would land"
    contained = _delta_is_contained(worktree, base_sha, head, paths)
    if contained is None:
        return None, "could not compare HEAD's own paths against the base"
    if contained:
        return False, ""
    if status == "conflict":
        return True, ""
    return None, ("the merge discarded HEAD's own change (a merge driver, or an equivalent "
                  "rewrite upstream) — 'already landed' cannot be certified")



def evaluate(worktree: str, base: str = "origin/main") -> dict:
    """Classify a worktree as HAS-WORK / NO-WORK / UNREADABLE.

    Reads git state only: no ref is moved, nothing is committed, no network, and
    the only write is the one loose tree object a three-way merge materialises
    (``merge-tree --write-tree``).
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
        "would_change_base": None,
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

    # THE TARGET MUST BE ITS OWN ROOT. `git -C <dir>` walks UPWARD, so a stale
    # or half-pruned directory under `.worktrees/` would otherwise be answered
    # from the superproject — a confident verdict, and an allowed dispatch whose
    # commits would land on the MAIN checkout's branch.
    rc, toplevel = _git(worktree, ["rev-parse", "--show-toplevel"])
    if rc != 0 or not toplevel or os.path.realpath(toplevel) != os.path.realpath(worktree):
        why.append(f"the path is not its own work tree root (git reports {toplevel or 'nothing'!r}) — "
                   "git -C would answer about the ENCLOSING repo, not the target")
        return result

    rc, head = _git(worktree, ["rev-parse", "--verify", "--quiet", "HEAD^{commit}"])
    if rc != 0 or not head:
        # An empty repo / unborn HEAD. There is no content to land, but this is
        # also not a state a lane should be dispatched into.
        why.append("HEAD does not resolve (unborn or detached-empty worktree)")
        return result
    result["head"] = head

    # DIRTY IS PROBED FIRST, AND IT SHORT-CIRCUITS. It is the one answer that
    # never needs the base: uncommitted/untracked changes ARE work to land even
    # when the base cannot even be resolved (a fork worktree with no
    # `origin/main`, a shallow checkout, unrelated histories). Probing it after
    # base resolution would refuse real work — the direction the header
    # documents as unflippable — so the short-circuit is the contract, not an
    # optimisation.
    #
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
    if result["dirty"]:
        result["verdict"] = VERDICT_HAS_WORK
        why.append(f"the working tree has {result['dirty']} uncommitted/untracked path(s) — "
                   "that IS work to land")
        for ln in dirty_lines[:5]:
            why.append(f"  {ln}")
        return result

    base_sha = _resolve_base(worktree, base)
    if base_sha is None:
        # We cannot see the base, so we cannot answer the question. Fail closed.
        why.append(f"base {base!r} does not resolve in this worktree (no origin/{base} either)")
        return result
    result["base_sha"] = base_sha
    rc, merge_base = _git(worktree, ["merge-base", head, base_sha])
    if rc != 0 or not merge_base:
        why.append(f"no merge-base between HEAD {head[:12]} and {base} {base_sha[:12]} "
                   "(unrelated histories?) — cannot compute a diff")
        return result

    rc, ahead_s = _git(worktree, ["rev-list", "--count", f"{base_sha}..{head}"])
    result["ahead"] = int(ahead_s) if rc == 0 and ahead_s.isdigit() else None

    # own_delta is EVIDENCE, not the verdict: it is what lets the reason below
    # tell "already contained" apart from "ahead, but already landed".
    own_delta = _diff_is_nonempty(worktree, merge_base, head)
    if own_delta is None:
        why.append("git could not report a diff verdict — cannot tell whether a diff exists")
        return result
    result["own_delta"] = own_delta

    would_change, reason = _would_change_base(worktree, merge_base, base_sha, head)
    if would_change is None:
        why.append(reason)
        return result
    result["would_change_base"] = would_change

    if would_change:
        result["verdict"] = VERDICT_HAS_WORK
        why.append(f"HEAD {head[:12]} still adds content to {base} "
                   f"(ahead={result['ahead']})")
    else:
        result["verdict"] = VERDICT_NO_WORK
        if not own_delta:
            why.append(f"HEAD {head[:12]} is already contained in {base} "
                       f"(ahead={result['ahead']}, no own delta)")
        else:
            why.append(f"HEAD {head[:12]} is ahead={result['ahead']} but adds nothing to {base} — "
                       "the change is already landed (squash-merged or re-applied)")
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
        lines.append(f"   {w}")
    if res["verdict"] == VERDICT_NO_WORK:
        lines.append("")
        lines.append("   → Do NOT spawn a lane here. Point the dispatch at work that is still open,")
        lines.append("     or let the lane that owns the change keep it. Re-check with:")
        lines.append(f"       python3 tools/fleet/dispatch_preflight.py {res['worktree']}")
    return "\n".join(lines)


def parse_args(argv: Optional[Sequence[str]] = None) -> argparse.Namespace:
    class _RefusingParser(argparse.ArgumentParser):
        """A usage error is a REFUSAL, never a silent pass-through.

        argparse exits 2 on a malformed invocation, which sits OUTSIDE the
        0/3/4 contract a caller switches on — a caller written as "refuse on 3,
        escalate on 4, otherwise dispatch" would DISPATCH on its own typo.
        Mapping it onto the refusal code makes every non-0 outcome a refusal.
        """

        def error(self, message: str) -> "None":  # type: ignore[override]
            self.print_usage(sys.stderr)
            print(f"dispatch-preflight: {message} — a malformed invocation is a refusal "
                  f"(exit {EXIT_UNREADABLE})", file=sys.stderr)
            raise SystemExit(EXIT_UNREADABLE)

        def exit(self, status: int = 0, message: "Optional[str]" = None) -> "None":  # type: ignore[override]
            if message:
                self._print_message(message, sys.stderr)
            # argparse exits 0 for `--help`, and 0 IS the contract's HAS-WORK —
            # so a caller that reads 0 as "dispatch" would dispatch on a help
            # screen, which answered nothing. Only a real verdict may exit 0.
            raise SystemExit(EXIT_UNREADABLE if status == 0 else status)

    ap = _RefusingParser(
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
