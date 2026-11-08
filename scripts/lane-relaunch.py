#!/usr/bin/env python3
"""lane-relaunch.py — restart a dead lane's `pi` in its EXISTING cmux workspace. Never destructively.

WHY THIS EXISTS (issue #942, measured 2026-09-26 twice in one session)
    `cmux respawn-pane` is the *correct* tool for unwedging a session — it restarts the pane's
    process without discarding the workspace — and that is exactly what makes it dangerous: if the
    command it launches FAILS (a binary missing from the respawn PATH, a wrapper that cannot find
    `node`), the pane's process terminates, the surface closes, and because it was the workspace's
    only surface **the workspace is removed**. The failure then presents one step later as
    `not_found: Workspace not found`, which does not point back at the respawn. Two workspaces were
    destroyed that way, and a later controlled repro destroyed a scratch workspace with
    `--command "pi --help"`.

    ⛔ SO THIS TOOL DOES NOT CALL IT — not on any path, not even on a failure path. It relaunches the
    way the fleet's own recovery procedure did when it recovered 14 lanes: it types the launch line
    into the pane's OWN login shell, where the user's PATH and exported environment are present (the
    respawn environment is `login -flp … /bin/bash --noprofile --norc`, i.e. no profile, no user
    PATH, no exported keys — the second aggravating factor in #942). If the launch line fails there,
    you get a shell prompt back — and because pi runs as a CHILD of that shell (never `exec`, see the
    payload comment), the same holds when the lane's pi exits later: the shell survives, the pane
    stays, and the lane returns to the bare-shell state a relaunch can act on again.

    That is also the convention of the multiplexer this one is modelled on: tmux makes pane
    destruction on child exit OPT-IN (`remain-on-exit` keeps a "dead pane"), and an application is
    started in an existing pane by `send-keys` into the pane's shell — `respawn-pane` after a
    `send-keys` restart would restart the SHELL, not the application (tmux wiki, tmux(1),
    tmuxp#139). We cannot give cmux `remain-on-exit`; we can stop depending on the destructive verb.

WHY IT REFUSES SO MUCH
    Typing a command into a pane is only safe when the pane is demonstrably at a shell. The refusals
    are the design, and each one is a state this fleet has actually been burned by:

      * pane unreadable            -> UNKNOWN. Never act on an unknown (exit 3).
      * `Working` in the pane      -> a turn is in flight; typing injects text into a RUNNING MODEL
                                      (the same class as sending into a busy lane, #1187/#941).
      * no shell prompt visible    -> the pane is not at a bare shell (a pi footer, a pager, an editor).
                                      Requires a POSITIVE prompt match: a negative list fails open.
      * no transcript for the id   -> the stored resume target can point at a session file that does
                                      not exist (#942's aggravating factor 2). Resuming from it would
                                      start an EMPTY session that LOOKS like a restore. `--new` is the
                                      explicit way to say "yes, a fresh session".
      * no cwd / no `pi` binary    -> a launch line that cannot work is the failure mode we are
                                      avoiding; refuse here instead of after the send.

    And the confirmation is the fleet's own proof standard (`docs/ops/outcome-canary.md:102`): the
    session transcript must ADVANCE, not merely look alive. A relaunch that restarted nothing reads
    UNCONFIRMED (exit 4), never OK.

USAGE
    lane-relaunch.py --ws <workspace-uuid> [--label <lane-label>] [--cwd <dir>]
                     [--session <id>] [--new] [--pi <path>] [--wait 45] [--dry-run] [--json]

EXIT
    0  CONFIRMED    the launch line was sent AND the session transcript advanced
    3  REFUSED      a guard refused; nothing was sent (the message names the guard)
    4  UNCONFIRMED  the line was sent (or the send failed) and no advance was observed
    5  DRY-RUN      --dry-run: NOTHING was sent, so 0 (CONFIRMED) would be a false PASS
    1  ERROR        the tool itself raised (never reported as DRY-RUN or UNCONFIRMED)
    2  usage error
"""
from __future__ import annotations

import argparse
import json
import os
import shlex
import shutil
import subprocess
import sys
import time

SCRIPTS = os.path.dirname(os.path.abspath(__file__))

# ⛔ THE VERBS THIS TOOL MUST NEVER EMIT. `respawn-pane` deletes the workspace when its command
# fails (#942); `close-workspace`/`terminal close` are the explicit versions of the same loss; and a
# "kill the process first" step (`kill-pane`, or a `pkill` on the pane's pid) is the same idea by
# another name. Kept as ONE list because it is checked on EVERY argv the tool builds, on every path
# including refusals, and pinned by a test — a tool that can grow a destructive arm silently is the
# defect it was written to remove.
FORBIDDEN_VERBS = (
    "respawn-pane", "respawn_pane", "respawnpane",
    "close-workspace", "close_workspace", "workspace close",
    "kill-pane", "kill_pane", "terminal close",
)

# cmux's response deadline. Measured (safe-send.sh): `cmux workspace list` takes 0.2-2s on a quiet
# box and 13.4-15.1s at load 130+, against a fixed 15s CLI deadline — so a slow answer is
# indistinguishable from a hang. 60s removes the ambiguity for our send/read.
os.environ.setdefault("CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC", "60")

# A shell prompt is POSITIVE evidence and it is the LAST line that carries it. pi's TUI footer
# (`… /800k  -flash • high`) does not end in any of these, which is what makes this discriminator
# work without duplicating the fleet's footer vocabulary (orchestrator-heartbeat.sh owns that).
# ⛔ `>` IS DELIBERATELY ABSENT: pi draws `> ` as its INPUT line, so accepting it would read a live
# pi as a bare shell and type the launch line into a running session. Each tail below is one a
# login shell draws and pi does not.
PROMPT_TAILS = ("$", "%", "#", "❯", "»")


def _load_lane_status():
    """Import lane-status.py by path (its filename has a dash, so not a normal import).

    REUSED, never re-implemented: `session_file`, `resolve_session`, `read_screen`, `ui_working`
    and `workspace_cwds` are the fleet's own resolution and probe primitives. Two copies of
    "which session is this lane on" is how the last two liveness defects were born.
    """
    import importlib.util
    path = os.path.join(SCRIPTS, "lane-status.py")
    spec = importlib.util.spec_from_file_location("lane_status", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _runner(argv, timeout=60):
    """`(rc, stdout, stderr)`. Module-level so tests inject a fake cmux instead of driving one."""
    try:
        p = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout or "", p.stderr or ""
    except Exception as exc:                                    # noqa: BLE001
        return None, "", "%s: %s" % (type(exc).__name__, exc)


RUNNER = _runner


def _has_prompt(screen: str) -> bool:
    """True only if the LAST non-empty line of the pane ends with a shell-prompt character."""
    lines = [ln.rstrip() for ln in (screen or "").splitlines() if ln.strip()]
    if not lines:
        return False
    return lines[-1].endswith(PROMPT_TAILS)


def _live_pi_record(ws, runner, timeout=45):
    """True/False/None — is there a LIVE pi session record bound to this workspace?

    The SECOND, orthogonal half of the fleet's own DEAD definition: `orchestrator-heartbeat.sh`
    calls a lane DEAD only when it has BOTH `pid_exists=no` in `cmux sessions list` AND a bare shell
    in the pane. A relaunch is safe under exactly that conjunction, so this tool asks for both — a
    pane-only read can be fooled by output whose last line happens to end in `$`.

    None is UNREADABLE, and an empty list is not an answer (the fleet's own rule): a roster we could
    not read must never be quoted as "no live pi".

    ⛔ A READ ROSTER WHOSE ROWS WE CANNOT PARSE IS UNREADABLE TOO (review round 2, P1). `rc=0` with
    output is not the same fact as "we understood the output": if a cmux bump renames `pid_exists`
    or `workspace`, every row stops matching and the old code fell through to `False` — "no live pi"
    — which is quoted downstream as the licence to type into the pane. So absence is only an answer
    when at least one row was in the shape we can read and no row naming this workspace was
    unreadable.
    """
    rc, out, err = runner(["cmux", "sessions", "list"], timeout)
    if rc != 0 or not (out or "").strip():
        return None
    want = str(ws).strip().upper()
    recognised = 0
    our_row_unreadable = False
    for ln in out.splitlines():
        if "pid_exists=" not in ln or "workspace=" not in ln:
            # A line that names OUR workspace but not in the shape we read: we cannot say whether it
            # is live, and UNKNOWN is not a licence.
            if want and want in ln.upper():
                our_row_unreadable = True
            continue
        recognised += 1
        # ⛔ A ROW WE CANNOT PARSE IS UNKNOWN, NOT "NO LIVE pi" (review round 5, P2). An empty
        # `workspace=` value made `.split()[0]` raise IndexError, which escaped `relaunch()` and was
        # reported as ERROR (exit 1) — contradicting this function's own contract, and unlike the
        # fleet's parser of the same roster (`orchestrator-heartbeat.sh:639-645`), which guards it.
        try:
            got = ln.split("workspace=")[1].split()[0].strip().strip(',').upper()
        except IndexError:
            our_row_unreadable = True
            continue
        if not got:
            # `workspace=,` strips to empty: a row whose id we cannot read is a row we cannot rule
            # out, so it is UNKNOWN rather than a "not ours".
            our_row_unreadable = True
            continue
        if got != want:
            continue
        # OUR row, in a shape we understand: its pid_exists value is the answer — but only the two
        # values we recognise. Anything else (`true`, `1`, empty) is UNKNOWN, not "dead".
        if "pid_exists=yes" in ln:
            return True
        if "pid_exists=no" not in ln:
            our_row_unreadable = True
    if recognised == 0 or our_row_unreadable:
        return None
    return False


def _transcripts(ls):
    """{path} of every session transcript on the box — the pre-send BASELINE, taken by GLOB only.

    ⛔ NEVER KEYED ON A DIRECTORY-NAME MANGLING (review round 5, P1 — and it is the same
    lossy-encode-as-exact-key class this file keeps meeting). `lane-status.mangled()` replaces BOTH
    `/` and `.` with `-`; pi's own session dir replaces only `/`, `\\` and `:` and KEEPS the dot
    (`dist/core/session-manager.js:293`). Measured: for `/home/cmux/agent-infra/.worktrees/tm-942`
    the mangled form is `--home-cmux-agent-infra--worktrees-tm-942--`, and pi's real directory is
    `--home-cmux-agent-infra-.worktrees-tm-942--`. Every fleet lane lives in a dotted path, so the
    derived directory NEVER exists, `glob` returns `[]` (it does not raise), and the appearance
    proof was DEAD rather than merely unlucky — silently, because the empty set reads as "nothing
    appeared".

    So the baseline is a cheap walk of the session root, and the cwd of a CANDIDATE is read from the
    transcript's OWN first record (`lane-status.parent_cwd`, compared by EXACT cwd identity — see
    `_records_cwd`; ⛔ never `_same_dir`, which is ancestor-tolerant and reopens the false CONFIRM
    that function's own note closes). That is encoding-independent: it survives pi changing its
    naming scheme.

    None means the root could not be READ — no signal, never a false CONFIRM.

    ⛔ `glob.glob` CANNOT DETECT THAT (review round 3, P1): it returns `[]` rather than raising on an
    unreadable or absent directory, so a `try/except` around it is DEAD CODE and this function could
    only ever return a set. An unreadable root then produced an EMPTY baseline instead of `None`,
    and if the root became readable before the post-send read, EVERY pre-existing transcript counted
    as "appeared" — a pre-existing session reported as a transition, exit 0 CONFIRMED. `os.scandir`
    raises, so the distinction is real; an ABSENT root is still an empty set (no transcripts can
    pre-exist a directory that does not exist).
    """
    # ⛔ AN ABSENT ROOT IS NOT THE SAME AS ONE WE COULD NOT REACH (review round 4, P2). `os.path.isdir`
    # swallows EVERY `OSError` — EACCES on an untraversable parent, ESTALE/EIO on a network mount,
    # ELOOP — not just ENOENT, so those read as a valid EMPTY baseline and re-opened the very
    # false-CONFIRM this function exists to prevent. Only ENOENT is an absence; anything else is
    # UNKNOWN.
    try:
        os.stat(ls.SD)
    except FileNotFoundError:
        return set()
    except OSError:
        return None
    try:
        if not os.path.isdir(ls.SD):
            return set()
        out = set()
        with os.scandir(ls.SD) as ents:
            for ent in ents:
                try:
                    if not ent.is_dir():
                        continue
                    names = os.listdir(ent.path)
                except OSError:
                    return None
                for name in names:
                    if name.endswith(".jsonl"):
                        out.add(os.path.join(ent.path, name))
        return out
    except OSError:
        return None


def _records_cwd(ls, path, cwd):
    """True when this transcript's first record says it was started in EXACTLY `cwd`.

    ⛔ IDENTITY, NOT CONTAINMENT (review round 6, P2). The first version reused
    `lane-status._same_dir`, which is a TOLERANT matcher:
        ra == rb or ra.startswith(rb + os.sep) or rb.startswith(ra + os.sep)
    Those prefix arms answer a DIFFERENT question (`find_child_session`'s "the child may live in a
    subdirectory") and they are wrong here: a pi session starting in the repo root, in `$HOME`, or in
    a subdirectory of the lane's own worktree — all of them normal, all of them likely inside a
    45-second window — would confirm a `--new` relaunch that started nothing. `lane-status.py:1743`
    answers this same identity question strictly, and so does this.
    """
    try:
        rec = ls.parent_cwd(path)
        return bool(rec) and os.path.realpath(rec) == os.path.realpath(cwd)
    except Exception:                                            # noqa: BLE001
        return False


def _forbidden_in(argv) -> str:
    blob = " ".join(str(a) for a in argv)
    for v in FORBIDDEN_VERBS:
        if v in blob:
            return v
    return ""


def _stat(path):
    try:
        s = os.stat(path)
        return (s.st_mtime, s.st_size)
    except Exception:                                            # noqa: BLE001
        return None


def _newest_first(paths, limit):
    """The `limit` most recently written of `paths`, newest first.

    Why not `sorted(paths)[:limit]`: a transcript filename is a session uuid, so a lexicographic
    sort is arbitrary with respect to time — it kept the five that happen to sort first and dropped
    the one the relaunch just created. A file that vanished between the glob and the stat is not a
    candidate, and must not raise: this runs inside an error path.
    """
    def _key(p):
        try:
            return os.path.getmtime(p)
        except Exception:                                        # noqa: BLE001
            return float("-inf")
    return sorted(paths, key=_key, reverse=True)[:limit]


def relaunch(ws, label="", cwd=None, session=None, pi=None, new=False, wait=45.0,
             dry_run=False, ls=None, runner=None, sleep=time.sleep, clock=time.time):
    """Return an observation dict. Every field is measured; nothing here infers success."""
    runner = runner or RUNNER
    obs = {"ws": ws, "label": label, "action": None, "sent": False, "confirmed": False,
           "refused": False, "reason": "", "argv": None, "line": None, "elapsed_s": 0.0}
    t0 = clock()

    def refuse(reason):
        obs["refused"] = True
        obs["reason"] = reason
        obs["elapsed_s"] = round(clock() - t0, 1)
        return obs

    # ⛔ A MISSING `lane-status.py` IS A NAMED REFUSAL, NOT A CRASH (review, P2). `pi-bootstrap`'s
    # farm withholds `lane-status.py` deliberately (#1553), so dropping this tool beside the farmed
    # heartbeat is a natural install that leaves the imported primitives absent — and the old code
    # raised out of `main()`, which then printed "DRY-RUN" and exited 4: two false statements about a
    # run that read nothing and sent nothing.
    if ls is None:
        try:
            ls = _load_lane_status()
        except Exception as exc:                                  # noqa: BLE001
            return refuse("no lane-status.py beside this tool (%s) — the fleet's resolution "
                          "primitives are not installed here; nothing sent" % exc.__class__.__name__)

    # ── 1. the pane must be READABLE. Unreadable is UNKNOWN, and UNKNOWN never gets a keystroke.
    try:
        screen = ls.read_screen(ws, lines=14) or ""
    except Exception as exc:                                     # noqa: BLE001
        return refuse("pane read RAISED (%s) — state UNKNOWN; nothing sent" % exc.__class__.__name__)
    if not screen.strip():
        return refuse("pane UNREADABLE (empty read) — state UNKNOWN; nothing sent")

    # ── 2. a turn in flight takes the text as STEERING into a live model, not as a command.
    try:
        if ls.ui_working(ws):
            return refuse("pane shows `Working` — a turn is in flight; a launch line typed now "
                          "would be injected into the running session")
    except Exception:                                            # noqa: BLE001
        return refuse("spinner probe RAISED — busy/idle UNKNOWN; nothing sent")

    # ── 3. POSITIVE evidence that the pane is at a shell. A negative test fails open.
    if not _has_prompt(screen):
        return refuse("no shell prompt at the last pane line — the pane is not at a bare shell "
                      "(a pi footer, a pager or a full-screen tool would take the text); nothing sent")

    # ── 3b. ...and NO live pi session record for this workspace. The pane read alone can be fooled
    # by any output whose last line ends in a prompt character; this is the orthogonal half of the
    # fleet's own DEAD definition (heartbeat: record AND pane). Unreadable is UNKNOWN -> refuse.
    live = _live_pi_record(ws, runner)
    if live is None:
        return refuse("`cmux sessions list` unreadable — cannot rule out a LIVE pi in this pane; "
                      "an unread read is not a licence to type into it; nothing sent")
    if live:
        return refuse("a LIVE pi session record is bound to this workspace — it is not dead; "
                      "relaunching would inject text into the running session")

    # ── 4. the session must RESOLVE TO AN EXISTING TRANSCRIPT (#942 aggravating factor 2).
    sid, fresh = session, False
    # ⛔ `--new` NEEDS NO RESUME TARGET, SO IT MUST NOT BE BLOCKED BY ONE (review round 3, P2).
    # `--new` is the documented escape hatch for "the stored resume target is broken"; refusing it
    # BECAUSE that target is broken blocks the remedy with the defect it remedies.
    # ⛔ BEST-EFFORT ON THE `--new` ARM (review rounds 3+4). `--new` needs no resume target, so a
    # resolver that RAISES must not block it — that would refuse the remedy with the defect it
    # remedies. But we still want the pre-launch identity as a SENTINEL, to recognise the stale id
    # the resolver falls back to after the send (see `pre_sid` below). So: always try, refuse only on
    # the resume arm.
    if not sid:
        try:
            sid = ls.resolve_session(ws) or None
        except Exception as exc:                                 # noqa: BLE001
            if not new:
                return refuse("session resolve RAISED (%s) — UNKNOWN; nothing sent"
                              % exc.__class__.__name__)
            sid = None                                           # --new proceeds without a baseline
    path = None
    if sid:
        try:
            path = ls.session_file(sid)
        except Exception:                                        # noqa: BLE001
            path = None
    if not new and not path:
        return refuse("session %r has NO transcript on disk — the stored resume target can be stale, "
                      "and resuming from it would start an EMPTY session that looks like a restore. "
                      "Pass --new to start a fresh session deliberately." % (sid,))
    # ⛔ THE PRE-SEND BINDING IS THE BASELINE — KEEP IT (review round 2, P1). `--new` used to null
    # `sid`/`path` here and then treat "a resolved session HAS a transcript" as proof, which is a
    # STATE, not a transition: a dead lane whose recorded id still has a transcript on disk (the
    # COMMON case — #942's aggravating factor 2 is that it sometimes does not) confirmed on the FIRST
    # loop iteration, before any wait, from a binding that existed BEFORE the relaunch. Exit 0 is the
    # operator's strongest signal, and it was saying "came back" about a session nothing had started.
    # The nulling below is therefore what makes the fresh arm measure a TRANSITION — and the id it
    # discards is deliberately NOT carried into the result: reporting it would name a session the
    # operator asked to abandon (review round 3, P2).
    # ⛔ `pre_sid` IS KEPT AS A SENTINEL, NOT AS A FALLBACK (review round 4, P1). `lane-status`'s
    # real `resolve_session` falls back to the RECORDED id in `lane-sessions.json` — which this tool
    # never writes — whenever the pane carries no cmux resume record, and that is exactly the state a
    # manual relaunch leaves behind (`lane-status.py:957-961` says so). So `sid_after` alone can come
    # back equal to the id `--new` was asked to abandon; the fresh arm must compare against it.
    pre_sid = sid
    if new:
        sid, path, fresh = None, None, True

    # ── 5. the launch cwd. A relaunch into the WRONG cwd is a silent side effect.
    if not cwd:
        try:
            cwd = (ls.workspace_cwds() or {}).get(str(ws).upper())
        except Exception:                                        # noqa: BLE001
            cwd = None
    if not cwd or not os.path.isdir(cwd):
        return refuse("launch cwd unresolved (%r) — refusing to start a lane somewhere unintended"
                      % (cwd,))

    # ── 6. the binary. Typing a command that cannot resolve is the exact failure #942 is about.
    # ⛔ EXECUTABLE, NOT MERELY PRESENT (review round 3, P2): `os.path.exists` accepts a 0644 file
    # and a DIRECTORY, and the launch line it then sends provably cannot run. Same standard this
    # change's own R6 test holds the prescribed remedy to.
    pi = pi or shutil.which("pi")
    if not pi or not os.path.isfile(pi) or not os.access(pi, os.X_OK):
        return refuse("`pi` not found as an executable file on this PATH (%r) — provide --pi <abs "
                      "path>; a launch line that cannot resolve is the failure this tool exists to "
                      "avoid" % (pi,))

    # ⛔ NO `exec` (review round 3, P1 — and it is #942's own defect one process away). `exec` REPLACES
    # the pane's shell with pi, so when pi later exits (turn ends, /quit, crash) there is no shell left:
    # the pane's process terminates, the surface closes, and on the only-surface case cmux removes the
    # workspace — the exact chain this tool exists to avoid, reached hours later and looking like a
    # different bug. pi as a CHILD of the shell is what makes "nothing is destroyed" true for a pi
    # exit too, not merely for a bad launch line, and it preserves the bare-shell state the guard-1
    # read depends on (the DEAD-LANES class this tool is for). It is also literally the line #942
    # records as having recovered 14 lanes.
    line = "cd %s && %s%s" % (shlex.quote(cwd), shlex.quote(pi),
                                   (" --session %s" % shlex.quote(sid)) if sid else "")
    obs.update(action="relaunch-fresh" if fresh else "relaunch-session", line=line,
               cwd=cwd, sid=sid, session_file=path, pi=pi)
    argv = ["cmux", "send", "--workspace", ws, line + "\n"]
    bad = _forbidden_in(argv)
    if bad:                                                      # pragma: no cover — a build-time tripwire
        return refuse("REFUSING to emit a destructive verb (%s)" % bad)
    obs["argv"] = argv

    if dry_run:
        obs["reason"] = "dry run — nothing sent"
        obs["elapsed_s"] = round(clock() - t0, 1)
        return obs

    # ── 7. ONE send, with the trailing newline: `cmux send` without it TYPES BUT NEVER SUBMITS
    # (#941), which is a silent dispatch no-op. The newline is part of the payload on purpose.
    before = _stat(path) if path else None
    pre_files = _transcripts(ls) if fresh else None
    non_prompt_reads = 0
    rc, out, err = runner(argv)
    obs["sent"] = True
    if rc != 0:
        obs["reason"] = ("cmux send rc=%r (%s) — nothing confirmed; argv was: %s"
                         % (rc, (err or out or "").strip()[:300], " ".join(argv[:-1])))
        obs["elapsed_s"] = round(clock() - t0, 1)
        return obs

    # ── 8. CONFIRMATION IS AN ADVANCE, not a screenshot that looks alive (`outcome-canary.md:102`).
    deadline = clock() + max(0.0, wait)
    while True:
        if fresh:
            # A fresh session has no transcript to ADVANCE, so the proof is an APPEARANCE — measured
            # against a baseline taken BEFORE the send, in the two forms that can actually occur.
            try:
                sid_after = ls.resolve_session(ws)
            except Exception:                                    # noqa: BLE001
                sid_after = None
            now_files = _transcripts(ls)
            new_files = sorted(now_files - pre_files) if (now_files is not None
                                                          and pre_files is not None) else []
            # (i) a transcript that was NOT there before the send, for THIS cwd. Bounded: only the
            # candidates are opened, and only their first record.
            # ⛔ NEWEST FIRST, and the bound applies to the NEWEST (review finding 4, 2026-11-08):
            # `sorted(...)[:5]` kept the five that sort FIRST lexicographically, and a filename is a
            # uuid — so on a box where five other lanes appear inside the window, OUR transcript (the
            # one that would prove the relaunch) was the file dropped. Newest-first is what "appeared
            # after the send" actually means; the bound still caps how many files are opened.
            cands = _newest_first(new_files, 5)
            hit = next((p for p in cands if _records_cwd(ls, p, cwd)), None)
            if hit:
                # ⛔ ONLY AN ID THAT IS GENUINELY NEW (review rounds 3+4, P2 then P1). `pre_sid` is
                # the id `--new` exists to ABANDON, and the real resolver FALLS BACK to it — so
                # neither `sid_after or pre_sid` nor a bare `sid_after` is correct: the id must be
                # reported only when it differs from the one we were told to discard. Unknown is
                # `None`, which is honest.
                obs.update(confirmed=True,
                           sid=(sid_after if sid_after and sid_after != pre_sid else None),
                           reason="fresh session appeared (%s)" % os.path.basename(hit))
                break
            if cands and not hit:
                obs["stray_new_sessions"] = len(new_files)
            # (ii) the pane LEFT the shell prompt — a transition the pane itself proves, and the one
            # signal that needs no transcript at all (pi creates its file lazily: `newSession` only
            # assigns the path, `session-manager.js:691-715`; the first write comes with the first
            # entry). Two CONSECUTIVE reads, so a redraw cannot confirm on its own.
            try:
                scr = ls.read_screen(ws, lines=14) or ""
            except Exception:                                    # noqa: BLE001
                scr = ""
            if scr.strip() and not _has_prompt(scr):
                non_prompt_reads += 1
            else:
                non_prompt_reads = 0
            if non_prompt_reads >= 2:
                # ⛔ ONLY AN ID THAT IS GENUINELY NEW (review rounds 3+4, P2 then P1). `pre_sid` is
                # the id `--new` exists to ABANDON, and the real resolver FALLS BACK to it — so
                # neither `sid_after or pre_sid` nor a bare `sid_after` is correct: the id must be
                # reported only when it differs from the one we were told to discard. Unknown is
                # `None`, which is honest.
                obs.update(confirmed=True,
                           sid=(sid_after if sid_after and sid_after != pre_sid else None),
                           reason="the pane left the shell prompt (pi took the pane)")
                break
        else:
            now = _stat(path)
            if now and now != before:
                obs.update(confirmed=True, reason="session transcript ADVANCED")
                break
        if clock() >= deadline:
            try:
                tail = "\n".join((ls.read_screen(ws, lines=6) or "").splitlines()[-6:])
            except Exception:                                    # noqa: BLE001
                tail = "(pane unreadable)"
            # ⛔ THE FRESH ARM DOES NOT MEASURE AN ADVANCE (review finding 4): it measures an
            # APPEARANCE and a prompt TRANSITION. A timeout message naming an advance sends the
            # operator to read a signal this arm never looked at.
            if fresh:
                obs["reason"] = ("sent, but no fresh session appeared and the pane did not leave the "
                                 "shell prompt within %ss — UNCONFIRMED. Pane now:\n%s" % (wait, tail))
            else:
                obs["reason"] = ("sent, but no transcript advance within %ss — UNCONFIRMED. Pane now:\n%s"
                                 % (wait, tail))
            break
        sleep(3.0)

    obs["elapsed_s"] = round(clock() - t0, 1)
    return obs


def main() -> int:
    ap = argparse.ArgumentParser(description="Relaunch a dead lane in its existing cmux workspace "
                                             "(never `respawn-pane`: #942).")
    ap.add_argument("--ws", required=True, help="cmux workspace uuid")
    ap.add_argument("--label", default="", help="lane label (diagnostics only)")
    ap.add_argument("--cwd", default=None, help="launch cwd (default: cmux's current_directory)")
    ap.add_argument("--session", default=None, help="session id (default: the pane's own record)")
    ap.add_argument("--new", action="store_true", help="start a FRESH session (no --session)")
    ap.add_argument("--pi", default=None, help="absolute path to the pi binary")
    ap.add_argument("--wait", type=float, default=45.0, help="confirmation window, seconds")
    ap.add_argument("--dry-run", action="store_true", help="print the launch line; send nothing")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()
    if a.new and a.session:
        ap.error("--new and --session are mutually exclusive")

    try:
        obs = relaunch(a.ws, a.label, a.cwd, a.session, a.pi, a.new, a.wait, a.dry_run)
    except Exception as exc:                                     # noqa: BLE001
        # ⛔ A CRASH IS NOT A DRY RUN AND NOT AN UNCONFIRMED SEND. It must never inherit either
        # label or exit 4, because the operator's next move is chosen on this line.
        obs = {"ws": a.ws, "error": True, "confirmed": False, "refused": False, "sent": False,
               "elapsed_s": 0.0,
               "reason": "relaunch RAISED %s: %s" % (exc.__class__.__name__, exc)}

    if a.json:
        print(json.dumps(obs, indent=2))
    else:
        if obs.get("error"):
            label = "ERROR"
        elif obs.get("refused"):
            label = "REFUSED"
        elif obs.get("confirmed"):
            label = "CONFIRMED"
        elif a.dry_run:
            label = "DRY-RUN"
        else:
            label = "UNCONFIRMED"
        print("%s %s [%ss] %s" % (label, obs.get("ws", a.ws), obs.get("elapsed_s"), obs.get("reason", "")))
        if a.dry_run and obs.get("line"):
            print("would send: " + obs["line"])

    if obs.get("error"):
        return 1
    if obs.get("refused"):
        return 3
    if obs.get("confirmed"):
        return 0
    if a.dry_run:
        # ⛔ NOT 0 (review round 4, P2). 0 means CONFIRMED — "sent AND advanced" — and this run sent
        # nothing. A caller that reads `$?` as the EXIT table says it should would be told the lane
        # came back. Dry-run is its own answer.
        return 5
    return 4


if __name__ == "__main__":
    sys.exit(main())
