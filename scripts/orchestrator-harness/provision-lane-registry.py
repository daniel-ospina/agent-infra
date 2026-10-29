#!/usr/bin/env python3
"""provision-lane-registry.py — derive this box's LANE ROSTER from its own lane population.

WHY THIS EXISTS (agent-infra#1935, measured 2026-10-28 on cell 1 vm-efa6cc8f)
----------------------------------------------------------------------------
The dispatch pre-flight's holder surface asks the FLEET BOARD "who is working this issue?".
The board is built FROM `$HOME/.pi/agent/state/lane-registry.tsv` (tortoise
`tools/fleet_state.py`), and that file was written only by the RETIRED cmux dispatcher. A box
that never ran it has no roster, so `fleet_state.load_registry` reports `measured=False`, so
`collision_preflight._board_can_answer` refuses, so EVERY candidate is INCOMPLETE and the
cell dispatches nothing — while the controller keeps reporting RUNNING:

    issue assignee/holder  INCOMPLETE  claim gate: the FLEET BOARD could not answer — the
      board's lane registry could not be read (FileNotFoundError: … lane-registry.tsv) —
      the roster was NEVER PROVISIONED in this cell
    [refresh] ABORT: none of the 12 candidate(s) … judged NOTHING

Read on cell 1 the same day (verbatim):

    $ cmux list-workspaces --json
    cmux: cmux-tui daemon binary not found at /root/.cmux/bin/cmux-tui
    $ .venv/bin/python -c 'import fleet_state as fs; print(fs.live_sessions().measured)'
    True                      # the PROCESS store answers: 2 lanes published as PROC:<pid>
    $ ls "$HOME/Library/Application Support/cmux/session-com.cmuxterm.app.json"
    (absent — this box has never persisted a cmux workspace layout)

⛔ SO THE ROSTER IS NOT UNKNOWN — IT IS EMPTY, AND THE TOOL'S OWN REMEDY CANNOT BE FOLLOWED.
`fleet_state.registry_remedy` tells the reader to take each lane's workspace uuid from the
cell's own `cmux list-workspaces --json`; on a Linux cell that command cannot answer at all
(worker-terminal.sh records the same measurement — agent-infra#2368), so the prescribed
population is unobtainable there. What IS true on such a box is that NO cmux-workspace lane
exists, because no cmux workspace was ever created — a reading this file MEASURES (see
`cmux_layout_store`), never infers from the producer's prose.

WHAT THIS SCRIPT IS, AND IS NOT
-------------------------------
It is a PROVISIONER, not a reader and not a repair for a failed read. It writes the roster the
reader will later consume, and it has exactly three arms — each decided by a MEASUREMENT:

  derive          the cmux daemon answers AND `cmux list-workspaces --json` parses. One row per
                  workspace whose cwd is a DEMONSTRABLE fleet worktree. Everything else is
                  excluded BY NAME (an owner's project, the shared checkout, a workspace whose
                  cwd could not be resolved), because a roster row is an ATTRIBUTION: a row for
                  the owner's own window reports a holder that does not exist (#8177/#2213).
  not-applicable  the daemon does not answer, and this box has never persisted a cmux workspace
                  layout ⇒ it has no cmux-workspace lanes at all. The roster's truthful content
                  is ZERO rows, and it is WRITTEN — an absent file is read by the board as
                  "never provisioned" and refuses every candidate, which is the defect.
  refused         the daemon answers but the list could not be READ, or the daemon answers with
                  ZERO workspaces (a live daemon's zero is an unread population, not an empty
                  fleet), or the box HAS a persisted layout it cannot read, or there is no lane
                  surface at all (no cmux, no tmux). NOTHING is written. An unreadable read must
                  never become an empty roster: that is the false-CLEAN #8175 exists to prevent,
                  and it is the one direction a provisioning tool must never fail in.

⛔ A HAND-MAINTAINED ROSTER IS NEVER REPLACED. Provenance decides: a file carrying this script's
own marker is ours to refresh; a file without it (the Mac's curated roster, 96 rows of human
labels) is reported as drift and left alone unless `--force` is given. The Mac's roster is
better than anything derivable from workspace cwds, and a bring-up step that overwrote it would
be destroying the fleet's own attribution to satisfy a form.

Usage
-----
    provision-lane-registry.py                     # report only (same as --check)
    provision-lane-registry.py --check             # report; exit 2 when the box is not provisioned
    provision-lane-registry.py --apply             # write the roster (idempotent, atomic)
    provision-lane-registry.py --apply --force     # replace even a hand-maintained roster
    provision-lane-registry.py --print             # print the rows that would be written
    provision-lane-registry.py --roster PATH       # seam for tests (never an operator knob)

Exit codes
----------
    0  provisioned — the roster states this box's truth: written, already current, or a
       HAND-MAINTAINED roster LEFT IN PLACE (another box's curation, not this tool's to
       replace — a bring-up is not failed over it, because the file exists and is usable)
    2  ACTION NEEDED — the roster is absent or stale and this invocation was not allowed to
       write it (`--check`, i.e. no `--apply`). ALSO a USAGE error: `--force` without `--apply`
       (argparse's own exit code for bad arguments)
    3  REFUSED — the population could not be MEASURED; the roster EXISTS and the read of it
       failed; or this run would have SHRUNK a derived roster on an arm that measured NOTHING.
       Nothing was written, and the reason is printed (the caller must not read this as
       "provisioned")
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile

try:
    import fcntl
except ImportError:  # pragma: no cover — Windows has no flock; the lock is a courtesy there
    fcntl = None  # type: ignore[assignment]

#: The marker that says "this file was derived by this script", so a refresh can tell its own
#: output from a hand-maintained roster. It is a COMMENT in the reader's grammar
#: (`fleet_state.load_registry` skips `#`), so carrying it cannot change what the board reads.
MARKER = "# provisioned-by: provision-lane-registry.py"

#: Where the readers look (`tortoise tools/fleet_state.py: REGISTRY`, `scripts/lane-status.py: REG`).
ROSTER_REL = os.path.join(".pi", "agent", "state", "lane-registry.tsv")

#: Where cmux persists its live workspace layout. Its PRESENCE is the measurement that decides
#: `refused` from `not-applicable` when the CLI cannot answer: a box that has persisted a layout
#: HAS cmux workspaces, so an unreadable list is a failed read, never an empty fleet. Every
#: candidate is checked, because the path is platform-shaped and the fleet runs both platforms.
LAYOUT_CANDIDATES = (
    ("Library", "Application Support", "cmux", "session-com.cmuxterm.app.json"),
    (".config", "cmux", "session-com.cmuxterm.app.json"),
    (".cmux", "session-com.cmuxterm.app.json"),
)


def home() -> str:
    return os.environ.get("HOME") or os.path.expanduser("~")


def roster_path(override: str | None) -> str:
    return override or os.path.join(home(), ROSTER_REL)


def cmux_layout_store() -> str | None:
    """The persisted cmux workspace layout, or None when this box has none.

    ⛔ THIS IS THE MEASUREMENT, NOT A GUESS. It answers "has this box ever had cmux
    workspaces?" — which is the question that separates a FAILED READ (the layout exists and
    the CLI could not read it) from an EMPTY POPULATION (no layout was ever written here). The
    two have opposite remedies and opposite polarities: the first must refuse, the second must
    provision a zero-row roster. Matching the CLI's error text instead would repeat the
    phrase-pin class that silently removed the holder re-route (#2848).
    """
    for parts in LAYOUT_CANDIDATES:
        p = os.path.join(home(), *parts)
        if os.path.isfile(p):
            return p
    return None


def run(argv: list[str], timeout: int = 45) -> tuple[int, str, str]:
    try:
        p = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout, p.stderr
    except (OSError, subprocess.SubprocessError) as exc:
        return 127, "", f"{type(exc).__name__}: {exc}"


def cmux_answers() -> bool:
    """Does the cmux DAEMON answer on this box?

    ⛔ THE SAME PROBE `worker-terminal.sh:wt_launcher` USES (`cmux tree --json`), deliberately:
    one definition of "this box has a cmux surface". A second, differently-shaped probe would
    let the roster claim lanes on a box whose launcher says there are none — the disagreement
    the launcher's OWN comment warns about, one subsystem over.
    """
    if not _which("cmux"):
        return False
    rc, _out, _err = run(["cmux", "tree", "--json"], timeout=45)
    return rc == 0


def _which(binary: str) -> str | None:
    for d in (os.environ.get("PATH") or "").split(os.pathsep):
        if not d:
            continue
        cand = os.path.join(d, binary)
        if os.path.isfile(cand) and os.access(cand, os.X_OK):
            return cand
    return None


def parse_workspaces(payload: str) -> list[dict] | None:
    """The workspace objects in a `cmux list-workspaces --json` answer, or None if unreadable.

    Both shapes the CLI has shipped are accepted (a bare list, and `{"workspaces": [...]}`),
    and anything else is UNREADABLE — never an empty list, because "0 workspaces" and "I could
    not read this" are the two facts this script exists to keep apart.
    """
    try:
        data = json.loads(payload)
    except ValueError:
        return None
    if isinstance(data, dict):
        data = data.get("workspaces")
    if not isinstance(data, list):
        return None
    return [w for w in data if isinstance(w, dict)]


def is_absolute(path: object) -> bool:
    """True when `path` is the CALLER'S OWN absolute POSIX path.

    ⛔ JUDGED BEFORE `real()`, ON PURPOSE. `os.path.realpath` ABSOLUTISES a relative argument
    against the provisioner's own CWD, so resolving first makes every relative spelling look
    absolute and the fail-closed rule below unreachable — the identity decision would then rest
    on whatever directory the caller happened to be in (the bring-up's cwd, an operator's
    shell). `scripts/lane-actions.py:569-574` rejects the spelling before resolving for exactly
    this reason; the two must not disagree about what a lane is.
    """
    if not isinstance(path, str) or not path or "\x00" in path:
        return False
    return path.startswith("/")


def real(path: str) -> str | None:
    if not path or not isinstance(path, str) or "\x00" in path:
        return None
    try:
        return os.path.realpath(path)
    except (OSError, ValueError):
        return None


def linked_worktree(path: str) -> bool:
    """True when `path` sits inside a REAL linked git worktree (the `.git` FILE `git worktree
    add` writes at or above it, pointing into `<main>/.git/worktrees/<name>`).

    A `.git` DIRECTORY means a main checkout, which is not a lane. A `.git` file that points
    anywhere else (`git submodule`, `--separate-git-dir`) is not one either — the pointer is
    what is required. This mirrors `scripts/lane-actions.py:_is_linked_worktree`, whose
    documented cases are re-driven in the suite so the two cannot drift silently.
    """
    cur = path
    for _ in range(64):
        g = os.path.join(cur, ".git")
        try:
            if os.path.isdir(g):
                return False
            if os.path.isfile(g):
                with open(g, errors="ignore") as fh:
                    head = fh.read(512)
                line = head.strip().splitlines()[0] if head.strip() else ""
                if not line.startswith("gitdir:"):
                    return False
                target = line.split(":", 1)[1].strip().replace(os.sep, "/")
                return "/worktrees/" in (target + "/")
        except (OSError, IndexError):
            return False
        parent = os.path.dirname(cur)
        if parent == cur:
            return False
        cur = parent
    return False


def fleet_roots() -> tuple[str, ...]:
    """The roots a `wt-<slug>` lane root may live under.

    ⛔ THE SAME ANCHOR `scripts/lane-actions.py::FLEET_ROOTS` USES, deliberately: that file's
    round-4 review established that root anchoring plus a `wt-` NAME is a name test, because a
    world-writable root such as /tmp makes ANY `/tmp/wt-anything` read as a fleet lane. Two
    differently-shaped anchors would let one subsystem accept a lane the other refuses, which is
    the disagreement `lane-actions.py`'s own comment warns about. `tempfile.gettempdir()` is
    included for the reason recorded there: the fleet's own recipe writes `/tmp/wt-<slug>` lanes.
    """
    out: list[str] = []
    for cand in (os.environ.get("FLEET_HOME"), os.environ.get("CELL_HOME"),
                 os.environ.get("FLEET_CELL_HOME"), home(),
                 "/tmp/cell-home", tempfile.gettempdir(), "/tmp", "/private/tmp"):
        if not cand:
            continue
        r = real(cand) or cand
        if r not in out:
            out.append(r)
    return tuple(out)


def is_fleet_worktree(cwd: str) -> bool:
    """True ONLY when `cwd` is DEMONSTRABLY a fleet lane's worktree.

    Fail-closed: an unreadable path, a non-absolute path and anything that is not a linked
    worktree under `.worktrees/` or a `wt-<slug>` lane root is NOT a lane, so it gets no row. The
    non-absolute case is decided on the CALLER'S spelling (`is_absolute`) BEFORE any resolution,
    because `realpath` would otherwise absolutise it against this process's own directory and
    make the guard inert (review finding 3). The cost of a wrong FALSE here is one fewer derived
    row on a box whose roster we are deriving because it has none; the cost of a wrong TRUE is a
    roster row attributing an issue to the OWNER's window — a manufactured holder, which is a
    blocking false COLLISION (#8177).

    ⛔ THE NAME ALONE IS NOT EVIDENCE. The first version accepted any path whose basename began
    with `wt-`, so `~/wt-notes`, a `wt-draft` directory, or any plain `wt-*` folder became a
    roster row carrying a derived `lane:<N>` label — acceptance WITHOUT evidence, in the one
    direction this script must never fail in. A `wt-` root must now satisfy BOTH the fleet-root
    anchor and `linked_worktree` (the same two-of-three `_is_fleet_wt_dir` requires, plus the
    name), so only a directory `git worktree add` actually created can be rostered.
    """
    if not is_absolute(cwd):
        return False
    p = real(cwd)
    if not p or not p.startswith("/"):
        return False
    parts = [x for x in p.split("/") if x]
    if not parts:
        return False
    if ".worktrees" in parts and linked_worktree(p):
        return True
    for root in fleet_roots():
        rp = root.rstrip("/")
        if not (p == rp or p.startswith(rp + "/")):
            continue
        # ⛔ `<$FLEET_ROOT>/wt-<slug>` — the `wt-` component must be the FIRST one under the root,
        # exactly as `lane-actions.py::_is_fleet_wt_dir` requires ("`<$FLEET_ROOT>/wt-<slug>` (or
        # below)"). Accepting a `wt-` basename anywhere BELOW a fleet root would roster
        # `$HOME/fleet/wt-notes`, a shape that file classifies as the OWNER's, so the two
        # subsystems would disagree about what a lane is.
        rel = p[len(rp):].strip("/").split("/")
        if rel and rel[0].startswith("wt-"):
            return linked_worktree(p)
    return False


def lane_label(cwd: str) -> str:
    """The row's label: the lane worktree's own name, minus the `wt-` spelling prefix.

    The reader uses this as the lane's NAME, so it must be the name a human and the harness
    already use for that worktree (`lane-1935`, `w-review10143`, `fix-1935-tests`), not a
    synthesised id. A path that yields nothing usable falls back to nothing, and the row is
    skipped rather than labelled with a placeholder.
    """
    base = os.path.basename((cwd or "").rstrip("/"))
    if base.startswith("wt-") and len(base) > 3:
        base = base[3:]
    return base


def issue_label(label: str) -> str:
    """The row's third column: the lane's own `lane:` annotation, or EMPTY.

    ⛔ THE THIRD COLUMN IS WRITTEN EMPTY, DELIBERATELY (#3032 review F4). This used to publish
    `lane:<the first digit run in the lane's name>`, and that is a MANUFACTURED label, not an
    annotation. The fleet's real grammar is a SLUG — `lane:c1-capture`, `lane:c5-9-mcp-sdk`,
    `lane:w0-test-substrate` — and a `gh label list` over both repos holds ZERO `lane:<digits>`
    labels. A worktree named `docs-2026-10-17` produced `lane:2026`, which is a REAL (closed)
    issue number; `scripts/turn-end.py` then hands this column to the lane as "Your lane label is
    `lane:2026` — its open issues are `gh issue list --label lane:2026`", i.e. an empty set. A
    date or a PR number published as the lane's work-item attribution is the #8177
    fabricated-holder class, in the one file whose whole purpose is attribution.

    Nothing in a workspace's cwd knows its GitHub label, so this column says exactly that: EMPTY.
    That is also what the sanctioned writer does (`scripts/turn-classify.py` writes `""` when it
    does not know), so the two writers agree instead of one of them guessing.
    """
    return ""


def derive_rows(workspaces: list[dict]) -> tuple[list[tuple[str, str, str]], list[str]]:
    """(rows, excluded) — one row per DEMONSTRABLE fleet workspace.

    `excluded` names every workspace that was NOT rostered, with its reason, so a derived
    roster can never quietly hide the box's other windows: reading "8 windows, 3 rostered"
    is a measurement; reading "3 rows" alone is not.
    """
    rows: list[tuple[str, str, str]] = []
    excluded: list[str] = []
    seen: set[str] = set()
    seen_labels: set[str] = set()
    for ws in workspaces:
        wsid = ws.get("id") or ws.get("workspaceId") or ws.get("uuid")
        cwd = ws.get("current_directory") or ws.get("currentDirectory") or ws.get("cwd")
        title = (ws.get("custom_title") or ws.get("customTitle") or ws.get("title")
                 or ws.get("name") or "")
        if not isinstance(wsid, str) or not wsid.strip():
            excluded.append(f"{title or '?'}: no workspace id in the answer")
            continue
        if not isinstance(cwd, str) or not cwd.strip():
            # ⛔ A WORKSPACE WITH NO CWD IS NOT ROSTERED, and the reason is PROVENANCE, not
            # tidiness: a row is an attribution, and the reader attributes a lane from its cwd /
            # branch / session text. Measured on cell 3 (2026-10-28): `cmux list-workspaces --json`
            # there answers `{"id":…, "name":"wt-lane-7", "session_id":…}` and nothing else — the
            # lane's identity would rest on a NAME, which #8177 refuses in code. Its lanes are
            # still enumerated for the board by the process store; only the roster declines to
            # claim them.
            excluded.append(
                f"{title or wsid[:8]}: no cwd in the answer (unplaceable, so unattributable)")
            continue
        if not is_absolute(cwd):
            # ⛔ NAMED, not merely excluded: a relative spelling's identity depends on the
            # CALLER's directory, so it is unplaceable for a reason no other exclusion shares.
            excluded.append(
                f"{title or wsid[:8]} ({cwd}): the cwd is RELATIVE — its identity would come from "
                "the caller's own directory, so it is unplaceable and unattributable")
            continue
        if not is_fleet_worktree(cwd):
            excluded.append(f"{title or wsid[:8]} ({cwd}): not a fleet worktree")
            continue
        label = lane_label(cwd)
        if not label:
            excluded.append(f"{title or wsid[:8]} ({cwd}): no usable lane name")
            continue
        key = wsid.upper()
        if key in seen:
            excluded.append(f"{label}: duplicate row for workspace {wsid[:8]}")
            continue
        # ⛔ THE SAME LANE FROM TWO CHECKOUTS IS ONE LANE (#3032 review F5). Deduping only on the
        # workspace uuid rostered TWO rows for one LABEL, and a duplicated label is the one shape
        # the board's own reader refuses to adjudicate: `fleet_state.load_registry` gives it its
        # own arms (`duplicate` / `other-row-binds` / `second-unbound`) precisely because one label
        # enumerating two lane records makes the claim gate read that label as unreadable
        # (`collision_preflight._holders_from_board` → HOLDER_UNMEASURED, INCOMPLETE/exit 2
        # fleet-wide — queued by tortoise tools/fleet_state.py:2382-2385). That is the silent-idle
        # defect this whole change exists to remove, so the writer must not manufacture it.
        if label.lower() in seen_labels:
            excluded.append(
                f"{label}: duplicate row for lane {label!r} (workspace {wsid[:8]}) — one label "
                "must not enumerate two lane records, or the claim gate reads the label as "
                "unreadable (HOLDER_UNMEASURED) and refuses every candidate")
            continue
        seen.add(key)
        seen_labels.add(label.lower())
        rows.append((label, wsid.upper(), issue_label(label)))
    rows.sort(key=lambda r: (r[0].lower(), r[1]))
    return rows, excluded


def render(rows: list[tuple[str, str, str]], arm: str, note: str) -> str:
    """The roster file this script writes: the marker, the arm it was derived under, the rows.

    Layout follows the reader's grammar exactly (`label<TAB>workspace<TAB>issue-label`, `#`
    comments ignored, blank lines ignored), and the format line is printed in the file because
    a human who opens it is the next person to edit it.
    """
    out = [
        MARKER,
        f"# arm: {arm}",
        f"# {note}",
        "#",
        "# label<TAB>workspace-uuid<TAB>issue-label — one row per cmux-workspace lane. Derived from",
        "# this box's own lane population. A hand edit that REMOVES the marker line above makes",
        "# this file hand-maintained and this script will never replace it. APPENDING a row does",
        "# NOT lose the marker, so an appended row is NOT lost either: a run that cannot reproduce",
        "# it REFUSES (rc 3) and names it, and `--apply --force` drops it with the drop reported.",
    ]
    for label, wsid, lane in rows:
        out.append("\t".join([label, wsid, lane]))
    return "\n".join(out) + "\n"


class RosterUnreadable(Exception):
    """The roster EXISTS and the READ failed — never the same fact as "absent".

    ⛔ TWO CAUSES WEAR THE SAME `present=False` AND THEY ARE NOT THE SAME PROBLEM (review finding
    5). An absent file means the roster was never provisioned, so `--apply` may write one. Any
    other `OSError` means the file is THERE and this script could not see it — a root-owned 0600
    in a shared cell home, `EACCES`, `EISDIR` — and writing over it would destroy a roster whose
    content this process never read. The reader (`fleet_state.registry_never_provisioned`) makes
    this distinction explicitly; the WRITER is the one place that must not collapse it, because
    the writer is the one that acts on it.
    """


def existing(path: str) -> tuple[bool, bool, list[str]]:
    """(present, ours, rows) — whether the roster exists, whether WE wrote it, and its rows.

    Provenance is the marker LINE, never a heuristic on the content: a hand-curated roster may
    contain anything, and guessing at "looks derived" would eventually overwrite it.

    Raises `RosterUnreadable` when the path exists but cannot be read, so "absent" can only ever
    mean ABSENT.
    """
    try:
        with open(path, errors="ignore") as fh:
            text = fh.read()
    except FileNotFoundError:
        return False, False, []
    except OSError as exc:
        raise RosterUnreadable(f"{type(exc).__name__}: {exc}") from exc
    rows = [ln for ln in text.splitlines()
            if ln.strip() and not ln.startswith("#") and "\t" in ln]
    ours = any(ln.strip() == MARKER for ln in text.splitlines())
    return True, ours, rows


def write_atomic(path: str, text: str) -> None:
    """Write via a sibling temp file + rename, so a reader never sees a half roster."""
    d = os.path.dirname(path) or "."
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".lane-registry.", dir=d)
    try:
        with os.fdopen(fd, "w") as fh:
            fh.write(text)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(add_help=True, description=__doc__.splitlines()[0])
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument("--check", action="store_true", help="report only (the default)")
    mode.add_argument("--apply", action="store_true", help="write the roster")
    ap.add_argument("--force", action="store_true",
                    help="MODIFIER of --apply: allow replacing a HAND-MAINTAINED roster, and allow "
                         "a derived roster to shrink. NEVER implies --apply")
    ap.add_argument("--print", dest="print_rows", action="store_true",
                    help="print the rows that would be written")
    ap.add_argument("--roster", default=None, help="roster path (test seam)")
    args = ap.parse_args(argv)
    # ⛔ `--force` IS A MODIFIER, NEVER A SUBSTITUTE FOR `--apply` (#3032 review F2). It used to
    # set `apply = True`, so a bare `--force` — or `--check --force`, the "report, but with force
    # armed" an operator reaches for — REPLACED a hand-maintained roster and returned 0. The
    # documented usage is `--apply --force`; the file's central promise is that a roster it has
    # never seen is never replaced; and an invocation that never said "write" must not write.
    if args.force and not args.apply:
        print("REFUSED: --force is a MODIFIER of --apply, never a substitute — this invocation did "
              "not ask to write, so nothing was written. Re-run as `--apply --force`.")
        return 2

    path = roster_path(args.roster)
    try:
        present, ours, rows_now = existing(path)
    except RosterUnreadable as exc:
        print(f"REFUSED: the roster EXISTS and could not be READ ({exc}) — so this script does not "
              "know what is in it, and a file it has never seen is never replaced")
        print(f"  roster: {path} (present — left untouched)")
        return 3

    # ── MEASURE ────────────────────────────────────────────────────────────────────────────
    measured = False
    workspaces: list[dict] = []
    refusal = ""
    if cmux_answers():
        rc, out, err = run(["cmux", "list-workspaces", "--json"], timeout=45)
        parsed = parse_workspaces(out) if rc == 0 else None
        if parsed is None:
            detail = (err or out or "").strip().splitlines()
            refusal = (
                "the cmux daemon answers, but its workspace list could not be READ"
                + (f" (`cmux list-workspaces --json` exit {rc}: {detail[-1][:160]})" if detail else "")
            )
        elif not parsed:
            # ⛔ "SAW ZERO" IS NOT "THERE ARE NONE" (review finding 4). A daemon that ANSWERS with
            # an empty workspace list is an UNREAD population, not an empty fleet — the workspace
            # list is per-window, so zero rows here does not prove the box has no cmux lanes.
            # Writing the zero-row roster on this measurement would be exactly the false-CLEAN
            # #8175 exists to prevent, and the `not-applicable` arm is deliberately required to
            # justify the same write with TWO measurements (no daemon AND no persisted layout).
            # The reader takes the same view of this datum (`fleet_state`: "could not confirm a
            # single cmux window (saw 0) … absence is not evidence"), so the writer must not
            # disagree with it.
            refusal = (
                "the cmux daemon answers but reported ZERO workspaces — a live daemon's zero is "
                "an UNREAD population, not an empty fleet (the workspace list is per-window, so "
                "absence is not evidence); the roster's truthful content cannot be measured here"
            )
        else:
            measured = True
            workspaces = parsed
            arm = "derive"
    if not measured and not refusal:
        # The daemon does not answer. WHICH FACT IS THAT? A box with a persisted layout HAS
        # cmux workspaces and its list could not be read (refuse); a box with no layout has
        # none at all (a truthful zero-row roster).
        layout = cmux_layout_store()
        if layout:
            refusal = (
                "the cmux daemon does not answer and this box HAS a persisted workspace layout "
                f"({layout}) — so it has cmux-workspace lanes its roster could not enumerate. "
                "An unreadable population is not an empty one"
            )
        elif _which("tmux"):
            arm = "not-applicable"
            measured = True
        else:
            refusal = (
                "no lane surface at all: the cmux daemon does not answer, this box has no "
                "persisted cmux layout, and tmux is not on PATH — there is no lane population "
                "to provision from"
            )
    if not measured:
        print(f"REFUSED: {refusal}")
        print(f"  roster: {path} ({'present' if present else 'absent'} — left untouched)")
        return 3

    if arm == "derive":
        rows, excluded = derive_rows(workspaces)
        note = (f"derived from {len(workspaces)} live cmux workspace(s); "
                f"{len(rows)} rostered, {len(excluded)} excluded")
        text = render(rows, arm, note)
        for why in excluded:
            print(f"  excluded: {why}")
    else:
        note = ("this box has NO cmux-workspace lanes: the cmux daemon does not answer here and "
                "no workspace layout has ever been persisted"
                + (f" (looked for {', '.join(os.path.join(home(), *p) for p in LAYOUT_CANDIDATES)})"
                   ) + " — its lanes are enumerated from the process store instead, so the "
                "roster's truthful content is ZERO rows (an ABSENT file would be read as "
                "'never provisioned' and would refuse every candidate)")
        rows: list[tuple[str, str, str]] = []
        text = render(rows, arm, note)

    if args.print_rows:
        for label, wsid, lane in rows:
            print("\t".join([label, wsid, lane]))

    # ── THE EXISTING ROWS, READ UNDER THE LOCK THE OTHER WRITERS HONOUR ──────────────────────
    # `scripts/turn-classify.py` APPENDS rows to this exact file under `fcntl.flock`, and its own
    # comment says it is "a read-modify-write on a file shared with lane-status.py /
    # lane-actions.py". So the file is read HERE, under that same lock, and THIS read governs both
    # the shrink guard below and the drop report. `rows_now` — the snapshot `existing()` took BEFORE
    # `MEASURE`, up to 90 s earlier (two 45 s timeouts) — cannot govern a decision about what the
    # write will destroy: a row appended inside that window would be invisible to the guard and
    # then deleted by it (#3032 cycle 2).
    # RESIDUAL, stated rather than hidden: `write_atomic` ends in `os.replace`, which swaps the
    # inode, so an `a+` holder cannot follow it — the exposure is the instant between this read and
    # the replace, and `turn-classify` re-adopts its own rows on its next pass.
    current = ""
    if present:
        try:
            with open(path, errors="ignore") as fh:
                if fcntl is not None:
                    try:
                        fcntl.flock(fh, fcntl.LOCK_EX)
                    except OSError:
                        pass
                try:
                    current = fh.read()
                finally:
                    if fcntl is not None:
                        try:
                            fcntl.flock(fh, fcntl.LOCK_UN)
                        except OSError:
                            pass
        except OSError:
            current = ""
    existing_rows = [ln for ln in current.splitlines()
                     if ln.strip() and not ln.startswith("#") and "\t" in ln]

    # ── DECIDE WHAT MAY BE WRITTEN ────────────────────────────────────────────────────────
    if present and not ours and not args.force:
        print(f"HAND-MAINTAINED roster left in place: {path} ({len(rows_now)} row(s))")
        if rows:
            print(f"  derivation offers {len(rows)} row(s); a hand-curated roster is not "
                  "replaced without --force")
        print("  (this is a deliberate non-destructive rule: the file is another box-wide "
              "attribution, and a bring-up must not overwrite it to satisfy a form)")
        return 0

    # ── NEVER SHRINK A DERIVED ROSTER WITHOUT SAYING SO (#3032 review F1, cycle 2) ────────────
    # This applies to BOTH arms, because the argument is the same on both and the roster is the
    # board's only source of lane rows (`fleet_state.load_registry`): a row this run does not
    # reproduce makes a LIVE lane read as unheld, which is the false-COLLISION direction.
    #   * `not-applicable` MEASURES NOTHING — the daemon is silent and no layout was ever
    #     persisted, so its zero rows are an UNREAD population, the same datum the file already
    #     calls "not an empty fleet" when the list comes back empty. One 45 s timeout lands here.
    #   * `derive` reads ONE WINDOW. The file's own zero-list refusal says so: "the workspace list
    #     is per-window, so absence is not evidence". If absence is not evidence for an EMPTY list,
    #     it is not evidence for a MISSING ROW either — a partial answer must not delete rows.
    # `--force` is the operator's statement that the vanished rows are stale.
    new_keys = {(r[1].upper(), r[0].lower()) for r in rows}
    vanished: list[tuple[str, str]] = []
    for ln in existing_rows:
        parts = ln.split("\t")
        lbl = parts[0]
        w = parts[1].upper() if len(parts) > 1 else ""
        if (w, lbl.lower()) not in new_keys:
            vanished.append((lbl, w))

    if present and ours and vanished and not args.force:
        print(f"REFUSED: {len(vanished)} row(s) in {path} are NOT reproduced by this run "
              f"(arm={arm}, {len(rows)} row(s) would replace {len(existing_rows)})")
        for lbl, w in vanished:
            print(f"  would REMOVE: {lbl} ({w[:8] if w else 'no workspace uuid'})")
        if arm == "not-applicable":
            print("  arm=not-applicable MEASURES NOTHING: the cmux daemon does not answer and no "
                  "workspace layout was ever persisted, so a zero-row result is an UNREAD "
                  "population, not an empty one")
        else:
            print("  arm=derive read ONE cmux window: the workspace list is per-window, so a lane "
                  "absent from this answer is not proof that it ended")
        print("  nothing was written — re-run when the population reads fully, or say "
              "`--apply --force` to declare those rows stale")
        return 3

    # ── A ROW THIS RUN DOES NOT PRODUCE IS NAMED, NEVER DROPPED IN SILENCE ────────────────
    # The comment this replaced claimed "a hand-edited file loses the marker, and this script will
    # then never replace it". APPENDING A ROW is the common hand edit and it KEEPS the marker, so
    # that promise was false and the row vanished without a word. Every existing row this run does
    # not reproduce is reported on BOTH arms — gating this on `arm == "derive"` left the
    # `not-applicable` arm deleting the whole file with no report at all (#3032 cycle 2).
    # ⛔ NO CAUSE IS INVENTED: this run knows only that it produced no row for the (label,
    # workspace) pair. Whether that is because the workspace is gone, or because `derive_rows`
    # EXCLUDED it (a duplicate label, a relative cwd, an owner window) is one line up in the
    # exclusions — inventing "the lane is no longer a fleet worktree" printed both halves of a
    # contradiction on the duplicate-label case.
    for lbl, w in vanished:
        print(f"  dropped: {lbl} ({w[:8] if w else 'no workspace uuid'}) — this run produced no "
              "row for it; if it was excluded rather than unmeasured, the exclusion above names why")

    if present and ours and current == text:
        print(f"CURRENT: {path} ({len(rows)} row(s), arm={arm})")
        return 0

    if not args.apply:
        state = "present" if present else "absent"
        print(f"ACTION NEEDED: {path} is {state} and does not state this box's truth "
              f"(arm={arm}, {len(rows)} row(s)) — re-run with --apply")
        return 2

    write_atomic(path, text)
    print(f"PROVISIONED: {path} ({len(rows)} row(s), arm={arm})")
    if arm == "not-applicable":
        print("  the roster is EMPTY on purpose: this box has NO cmux-workspace lanes (the cmux "
              "daemon does not answer here and no workspace layout was ever persisted — its "
              "lanes are enumerated from the process store), and an ABSENT file is what the "
              "board refuses as 'never provisioned'")
    return 0


if __name__ == "__main__":
    sys.exit(main())
