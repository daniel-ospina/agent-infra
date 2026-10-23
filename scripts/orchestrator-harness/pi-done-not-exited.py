#!/usr/bin/env python3
"""pi-done-not-exited.py — find (and, with `--apply`, clear) a print-mode lane `pi` that
FINISHED its turn and never exited, leaving its launcher waiting forever (#2163).

WHY THIS EXISTS — the measured defect
A lane is launched by a script that runs `pi` and then records its status:

    pi -p --model … "$(cat /tmp/task-<tag>.txt)" > $HOME/orchestrator/logs/<tag>.log 2>&1
    rc=$?
    printf 'EXIT rc=%s …' >> …/<tag>.log
    printf '%s %s\\n' "$rc" … > …/<tag>.rc

Readers decide a lane's state from `<tag>.rc`. When a print-mode `pi` finishes its turn and does not
exit, the launcher stays blocked and the `.rc` is never written, so **the lane reads as RUNNING for
hours after it finished**. Measured on one cloud cell at 2026-10-23T18:10Z: 46 bare `pi`, 27 of them
already finished, oldest 6 h 21 m, 6.5 GB RSS resident, load 20.4 on 8 cores, `/tmp` 98 % full, and
11 more wedged by `ENOSPC` at the end of their turn. A missing `.rc` is the state of a lane that has
not REPORTED — never a claim that it is working.

WHAT THIS IS NOT (read before extending it)
Not a sixth liveness verdict. `docs/ops/fleet-liveness.md` records that a second liveness
implementation is the defect #1178 removed, so every liveness fact is IMPORTED, never restated:

  * TURN BOUNDARY — `tools/fleet/liveness.py::turn_from_jsonl` / `jsonl_state` (the functions #1254
    pinned on a 426-transcript measurement). `turn-ended` is the only shape that may authorise an
    exit; `turn-open:*` is HUNG. An ABSTENTION (`tail-after-compaction`, `turn-unknown:<reason>`)
    carries `stalled=False` **and** `abstain=True` — reading `stalled` alone turns the canon's
    fail-closed forms into a kill licence (review cycle 1, P0) — so an abstention authorises nothing
    BY ITSELF: the row falls through to the log channel, which needs an exclusively-held log whose
    last line is a successful completion line, aged past `--min-idle`.
  * SESSION BINDING — `scripts/orphan-reap.py::bind_session`, the canon's name-stamp fence
    (`FENCE_S`, whose bound is `FENCE_TOLERANCE_SECONDS` in `scripts/lib/pid-identity.sh`).
  * CPU GATE + TOLERANCE — `orphan-reap.py`'s gate 1 (`TOLERANCE_S`), read at runtime, not copied.
  * PRE-SIGNAL DISCIPLINE — `is_pi`, `_same_incarnation`, `ancestry`, `gate2_host_decision` from the
    same file, re-run per target immediately before each `os.kill` (the #1696 lesson).

The ONE predicate added is **launcher ownership**, in two named rungs: `tag` — the launcher's own
text ASSIGNS the `TAG` this process carries in `/proc/<pid>/environ` (a kernel fact on both sides);
`launcher` — no usable TAG, but the launcher's text runs `pi`/`run_agent` AND redirects into the log
this process holds. A TAG the launcher does NOT assign is `weak-owner` and is report-only: ownership
then rests on the launcher's text alone, which is not what this paragraph claims. That is a kernel fact about WHO OWNS the process rather than an
inference from an ancestry host — and it is the datum the existing reapers cannot obtain on a cell:

  * `cloud-cell-doctor.sh::run_reap` enumerates TMUX sessions and judges `pane_pid`; a cell lane is a
    bare `pi` under a launcher (often reparented to init), so it is not in that population at all —
    and that pass is dead on its first tick anyway (agent-infra#2424, fix unlanded in #2430).
  * `scripts/orphan-reap.py --pool pi` owns the bare-`pi` population, but authorises only the canon's
    `idle` (24 h retirement proof) and then keeps every hostless chain report-only. This tool does
    not flip that, and does not touch that population's census or authorisation.
  * `lane-reap.sh` (#2172, unlanded, held by another lane) refuses a cell BY DESIGN: its gate 2
    wants positive FLEET ancestry and recognises only `cmux.app`, so a cell lane is
    `ancestry-unknown`. ⚠️ If it lands, the fleet holds two lane reapers; the scoping sentence above
    is the only thing separating them, which is why this file states its population.

⛔ OVERRIDES: `AUTHORISE_HOSTLESS_CHAINS = False` (orphan-reap.py, #1207/#1297 option A) — that
decision keeps a chain whose OWNER cannot be identified report-only, and it is NOT flipped here: the
ARMING paragraph below is why the default pass signals nothing. The chains this file acts on
are not ownerless: the owner is the process's own PARENT, a named launcher script that is blocked on
this exact child (`ownership()`, rung `tag`), which is established from the kernel — `ppid` plus the
child's own `environ` — not from an ancestry host. The seam is `ownership()`; it is the only place
that can authorise a signal here, and it is never wired into orphan-reap's authorisation. Gate 2's
SAFETY INTENT is preserved verbatim: a human terminal / login-shell / ssh ancestor is a hard refusal,
an unreadable ancestry is a hard refusal, and anything unattributable is reported with a name.

THE EVIDENCE, AND WHAT EACH CHANNEL CANNOT SEE
  A. CPU DELTA — cumulative CPU over a real window; FROZEN = delta < `TOLERANCE_S` (0.10 s, the
     imported tolerance).
  B. THE TRANSCRIPT — the bound session's last turn is `turn-ended` AND the file did not grow inside
     the window (growth is positive liveness and beats CPU). An abstention is not an ending.
  C. THE LOG — the file this process holds on fd 1/2, whose last line is a SUCCESSFUL completion
     line and which did not grow inside the window. Three attribution traps, all measured:
       * `[reflect-hook] Failed: …` is a HOOK FAILURE. So are two other shapes the extension writes
         — `Hosted capture FAILED (…)` and `Attribution resolution failed` — so the test is
         case-insensitive `failed|error`, never a `\bFailed\b` match.
       * a launcher path is RE-USED by later dispatches (`> log` truncates the same inode): measured
         5 `pi` on `adv-cipressure.log`, 4 on `adv-reaping.log`. A log held by more than one
         candidate is `shared`, and authorises nothing.
       * a log ending with the launcher's own `EXIT rc=<n> …` line was written by a LATER
         invocation, so it is `reused` and authorises nothing.
     `shared` / `reused` mean the transcript must decide; if it cannot, the row is UNATTRIBUTABLE.
  D. NO LIVE CHILD — a `pi` with a live child (a `task` sub-agent, a tool shell) may be waiting on
     real work: LIVE. Zombie children are not live work and are excluded. Measured: `lane-trebase6`
     held a live `task` child and was left alone.
  E. LAUNCHER STATE — `<tag>.rc` is used for VERIFICATION ONLY (after the signal, it proves the
     launcher left `wait`). It is never the reason to act: a missing `.rc` is the bug's signature.
     When the tag's `.rc` is NEWER than this process, it belongs to another invocation of the same
     tag and the row carries `rc_note: "shared-incarnation: …"`, so nobody reads that `.rc` as this
     lane's status.

CLASSES (printed for every candidate)
  DONE-NOT-EXITED  CPU frozen, no live child, no human, ownership proven (rung `tag`/`launcher`), and
                   EITHER the canon says `turn-ended` OR — when no transcript can be bound — an
                   EXCLUSIVELY-held log whose last line is one of the extension's SHUTDOWN completion
                   lines, aged past `--min-idle`. The row says which channel decided it, so "turn
                   ended" is never claimed for a row its log decided. The only class `--apply`
                   signals, and only under `--authorise-hostless` (see ARMING).
  HUNG             the turn is still OPEN (canon `turn-open:*`) and frozen. Reported, NEVER reaped.
  LIVE             CPU moved, a log/transcript grew, or a live child exists.
  KEEP-HUMAN       a terminal/login-shell/ssh ancestor. Never touched.
  UNATTRIBUTABLE   a NAMED refusal — `no-owner`, `weak-owner` (TAG present but not assigned by the
                   launcher), `task-child`, `proc-unreadable`, `peer-claimed`, `shared`/`reused`/
                   `startup` log with no usable transcript, `ancestry-unreadable`, `cpu-unreadable`.
                   Never reaped. An unmeasured liveness is not freedom.
  CENSUS           this process's own chain. Printed, never a candidate.

⛔ ARMING IS NOT THIS FILE'S TO DECIDE. A cell lane's ancestry reaches init, so every row here is
`hostless` — the class owner-approved option A on #1207/#1297 keeps REPORT-ONLY. Its reopen,
**agent-infra#2391**, is still OPEN and states "No code is proposed for adoption here", so the
DEFAULT pass reports and signals NOTHING (exit 4: a complete pass that was not authorised to act).
`--authorise-hostless` is the named, deliberate operator act #2391 would bless; no supervisor pass
may set it.

PLATFORM: `/proc` is the platform. An unreadable `/proc/<pid>/{environ,fd}` is `proc-unreadable`, an
abstention — so on a box without `/proc` nothing can be classified and the pass exits 3, exactly as
promised below.

USAGE
  pi-done-not-exited.py                     # dry run: classify every candidate, reap nothing
  pi-done-not-exited.py --apply             # SIGTERM every DONE-NOT-EXITED, verify the `.rc`
  pi-done-not-exited.py --sample 20 --json  # longer window / machine-readable rows
  pi-done-not-exited.py --pid 1234 --apply  # one named lane only

Exit: 0 = a complete pass that had nothing to reap · 1 = a target is STILL RESIDENT after `--apply`
(it survived SIGTERM, or it was refused because its evidence changed at signal time) ·
3 = CANNOT-VERIFY (a read did not happen, the imports are missing, every candidate abstained, or
`--pid` names something that is not a `pi` / is this process's own chain) · 4 = REPORT-ONLY (DONE rows
were found and nothing was signalled because `--authorise-hostless` was not passed) — never 0 on a
read that did not happen, and never 0 for a pass that found work it was not allowed to do.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
import re
import signal
import sys
import time
from typing import Dict, List, Optional, Set, Tuple

HERE = os.path.dirname(os.path.realpath(__file__))      # realpath: a symlinked invocation stays here
SCRIPTS = os.path.abspath(os.path.join(HERE, os.pardir))
PROG = "pi-done-not-exited"

MARKER = "[reflect-hook]"         # pi's hook-line prefix
# ⛔ A POSITIVE ALLOW-LIST, because the same prefix is printed at STARTUP (`captureStatusLine`:
# `[reflect-hook] capture ON/OFF — …`) as well as at shutdown. A `startswith(MARKER)` test with a
# `failed|error` exclusion called the startup line a completion (cycle 2, P1) — and on a
# `pi -p --no-session` lane the log channel is the ONLY one, so that was a kill licence.
COMPLETION_OK = (                # written by extensions/reflect-hook.ts AFTER the turn
    "[reflect-hook] Hosted tortoise capture OFF (",
    "[reflect-hook] Captured session ",
    "[reflect-hook] Skipped — empty session",
)
COMPLETION_FAILED = (            # the same extension's three failure shapes
    "[reflect-hook] Failed: ",
    "[reflect-hook] Hosted capture FAILED (",
    "[reflect-hook] Attribution resolution failed",
)
STARTUP = "[reflect-hook] capture "     # captureStatusLine: BEFORE the turn, never completion
# ⛔ PRINT MODE, read from the LAUNCHER's CODE. An interactive `pi` waiting at a human's prompt also
# reaches `turn-ended` + frozen CPU + no child, so without this predicate the tool would signal an
# agent that is simply idle — the one local discriminator between that and "the lane finished and
# never exited" (cycle 4, P2). The CHILD's own argv cannot answer it here: pi rewrites its argv to
# the bare word `pi` on a cell (measured: `/proc/<pid>/cmdline` == "pi"), so the launcher's code is
# the evidence — `pi -p`, `pi --print`, or `run_agent`, whose contract in spawn-gate.sh IS print mode.
# ⚠️ THE CLAIM IS SCOPED TO THE LAUNCHER, NOT TO THE INVOCATION (cycle 7): the check is one search
# over the launcher's code, so a launcher that BOTH runs a print-mode lane and spawns a bare
# interactive `pi` satisfies it for both, and a quoted string (`echo 'usage: pi -p'`) matches. No
# shipped launcher has either shape (the only `pi -p` invokers are spawn-gate.sh/merge-one.sh, and
# none spawns an interactive `pi`), and the remaining gates — ownership rung, no human ancestor, no
# live child, frozen CPU, `--min-idle`, and the explicit `--authorise-hostless` — still stand in
# front of any signal. Narrowing this to an invocation would need the launcher's argv or its
# held-fd topology, which the interpolating launchers do not expose; it is recorded as a residual,
# not papered over.
PRINT_MODE = re.compile(r"(?m)(^|[\s;/])pi\s+(?:[^\n]*?\s)?(?:-p|--print)(?=\s|$)|"
                        r"(^|[\s;])run_agent(\s|$)")


def code_only(text: Optional[str]) -> str:
    """The launcher's CODE, with comment lines dropped.

    ⛔ A FREE-TEXT `search()` OVER THE WHOLE FILE is how a comment satisfies a safety predicate:
    `lane.sh` documents its own `run_agent` in prose and `merge-one.sh` has `pi -p` in a comment, so
    a launcher that only MENTIONS print mode would pass the predicate that exists to keep an
    interactive agent from being signalled (cycle 5, P2).
    ⛔ AND A TRAILING COMMENT IS STILL A COMMENT (cycle 6): `TAG=1  # run_agent does the spawn` and
    `echo 'usage: run_agent [opts]'` both matched. Everything from the first `#` is dropped —
    deliberately OVER-stripping, because every lost match can only produce an ABSTENTION here, never
    a signal, and that is the correct direction for a predicate that permits a kill.
    """
    out = []
    for ln in (text or "").splitlines():
        code = ln.split("#", 1)[0]
        if code.strip():
            out.append(code)
    return "\n".join(out)
MIN_IDLE_S = 120                  # see the derivation in classify()'s guard, and the docstring
LAUNCHER_SCRIPT = r"(?:^|\s)(/\S+\.sh)(?:\s|$)"   # a shell running a SCRIPT, not a `-c` one-liner
RUNNERS = ("lane.sh", "nonblocking-dispatch.sh", "merge-one.sh", "chain-merge.sh", "fix-one.sh")
# ⛔ There is deliberately NO local CPU tolerance: `orphan-reap.TOLERANCE_S` is read at runtime
# (`tol = pool.TOLERANCE_S`), so a retune in the canon reaches this kill path. A constant here would
# be the "one rule, two copies" defect (§3 of docs/ops/fleet-liveness.md) — an earlier draft had one
# and a reviewer was right to call it dead.


# ── the two imports this tool refuses to exist without ─────────────────────────────────────
def _load(name: str, path: str):
    """Load a hyphenated/non-package module by path, registered so its dataclasses resolve."""
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


def _first(*cands: str) -> Optional[str]:
    for c in cands:
        if c and os.path.isfile(c):
            return c
    return None


def imports():
    """(canon, pool-owner). Both REQUIRED: a missing one is cannot-verify, never a local copy.

    ⛔ The LADDER is not decoration. `deploy-harness.sh` deploys this directory FLAT into `$O`, and
    `~/.pi/agent/scripts` farms individual files, so `$HERE/PARENT/tools/fleet/liveness.py` does not
    exist on any box where the tool is actually scheduled. `orphan-reap.py` solves the same problem
    with the same shape (`fleet_liveness()`), and this follows it: env override, the farmed copy
    beside us, the deployed flat layout, then the repo layout.
    """
    fleet = _first(
        os.environ.get("PI_DNE_FLEET_DIR", ""),
        os.path.join(HERE, "fleet", "liveness.py"),
        os.path.join(HERE, os.pardir, "tools", "fleet", "liveness.py"),
        os.path.join(HERE, os.pardir, os.pardir, "tools", "fleet", "liveness.py"),
    )
    pool = _first(os.path.join(HERE, "orphan-reap.py"), os.path.join(SCRIPTS, "orphan-reap.py"))
    if fleet is None or pool is None:
        raise ImportError("cannot locate %s (fleet dirs tried: PI_DNE_FLEET_DIR, <here>/fleet, "
                          "<here>/../tools/fleet, <here>/../../tools/fleet)"
                          % ", ".join(n for n, v in (("liveness.py", fleet), ("orphan-reap.py", pool))
                                      if v is None))
    return _load("fleet_liveness", os.path.realpath(fleet)), _load("orphan_reap", os.path.realpath(pool))


# ── kernel reads (two-valued: a value, or None for "the read did not happen") ───────────────
def _read(path: str, binary: bool = False):
    try:
        with open(path, "rb" if binary else "r", errors=None if binary else "replace") as fh:
            return fh.read()
    except OSError:
        return None


def cmdline(pid: str) -> Optional[str]:
    raw = _read("/proc/%s/cmdline" % pid, binary=True)
    return None if raw is None else raw.replace(b"\0", b" ").decode("utf-8", "replace").strip()


def environ(pid: str) -> Optional[Dict[str, str]]:
    raw = _read("/proc/%s/environ" % pid, binary=True)
    if raw is None:
        return None
    out: Dict[str, str] = {}
    for kv in raw.split(b"\0"):
        if b"=" in kv:
            k, v = kv.split(b"=", 1)
            out[k.decode("utf-8", "replace")] = v.decode("utf-8", "replace")
    return out


def ppid_of(pid: str) -> Optional[int]:
    status = _read("/proc/%s/status" % pid)
    if not status:
        return None
    for line in status.splitlines():
        if line.startswith("PPid:"):
            try:
                return int(line.split()[1])
            except (IndexError, ValueError):
                return None
    return None


def children_of(pid: str, rows: Dict[str, dict]) -> List[int]:
    """Live (non-zombie) children. A zombie is not work anyone is waiting on."""
    out = []
    for p, r in rows.items():
        if p != pid and r.get("ppid") == pid and not str(r.get("stat", "")).startswith("Z"):
            out.append(int(p))
    return sorted(out)


def _size(path: Optional[str]) -> Optional[int]:
    try:
        return os.stat(path).st_size if path else None
    except OSError:
        return None


def _mtime(path: Optional[str]) -> Optional[float]:
    try:
        return os.stat(path).st_mtime_ns if path else None
    except OSError:
        return None


def alive(pid: str) -> bool:
    """EPERM means alive-but-not-ours, ESRCH means gone; a ZOMBIE is not alive.

    Caught by the reviewer on the first cycle: a `/proc`-only check (`os.path.exists`) reports
    "exited" on every macOS box, so a surviving target would print `exited` and the pass would exit
    0. `os.kill(0)` is portable; the zombie read is an ADDITION, not the source of truth.
    """
    try:
        os.kill(int(pid), 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except OSError:
        return os.path.exists("/proc/%s" % pid)
    stat = _read("/proc/%s/stat" % pid)
    if stat and ")" in stat:
        return stat[stat.rfind(")") + 2:][:1] != "Z"
    return True


# ── ownership: the one predicate this file adds ─────────────────────────────────────────────
def launcher_of(pid: str, rows: Dict[str, dict]) -> Tuple[Optional[str], Optional[str], Optional[str]]:
    """(owner-pid, owner-cmdline, launcher-script) — the parent, or one hop above a bare `bash -c`.

    The repo's dispatch path is `pi → bash …/lane.sh <N> …`, and `nonblocking-dispatch.sh` backgrounds
    a SUBSHELL whose argv is `bash …/nonblocking-dispatch.sh <name> …`; both put the script on the
    direct parent. One extra hop exists because `worker-terminal.sh` can wrap the launcher, so the
    walk is bounded at two and names which hop it used.
    """
    pid = str(ppid_of(pid) or "")
    for hop in (0, 1):
        if not pid or pid in ("0", "1"):
            return (pid or None), None, None
        row = rows.get(pid) or {}
        cl = row.get("args") or cmdline(pid)
        if cl:
            m = re.search(LAUNCHER_SCRIPT, cl)
            if m and os.path.basename(m.group(1)) not in ("-c",):
                return pid, cl, m.group(1)
        if hop == 0:
            up = rows.get(pid) or {}
            parent = up.get("ppid") or str(ppid_of(pid) or "")
            # only climb when this hop is a shell with NO script in its argv (a subshell / `-c`)
            if parent and parent not in ("0", "1") and "bash" in (cl or ""):
                pid = parent
                continue
        break
    return (pid or None), None, None


def ownership(pid: str, launcher: Optional[str], log: Optional[str],
              launcher_argv: Optional[str] = None) -> Tuple[Optional[str], str]:
    """(rung, detail) — which KERNEL fact proves this process belongs to that launcher.

    Rung `tag` (strong) — the launcher NAMES the tag this process carries, by one of:
      * the tag is on the launcher's own argv (`bash $O/lane.sh 1234 …`, `bash …/nonblocking-
        dispatch.sh <NAME>`) — a kernel fact on both sides, and interpolation-proof, which is the
        only basis that works for the SHIPPED launchers: `lane.sh` writes `KIND=lane; TAG="$N"` and
        redirects `lane-$N.log`, so its TEXT contains neither the tag nor the log's real name
        (cycle 3, P1: the text-only bases matched no shipped launcher at all);
      * its text assigns `TAG=<tag>` or writes `<tag>.rc` (the generated per-lane wrappers, e.g.
        `/tmp/lane-<tag>.sh`, are literal like this);
      * it redirects into the very log this process holds, by name.
    Rung `launcher` (weaker, no usable `TAG`): the launcher's text runs `pi`/`run_agent` and
    redirects into that log. Anything else is `no-owner`; a TAG that NO basis names is `weak` and
    the row is report-only on BOTH DONE arms (cycle 3, P1: the log-only arm ignored the veto).
    """
    if not launcher:
        return None, "no-owner: the parent is not a shell running a launcher script"
    base = os.path.basename(launcher)
    text = _read(launcher)
    known_runner = base in RUNNERS
    tag = (environ(pid) or {}).get("TAG")
    writes_rc = bool(text) and bool(re.search(r">>?\s*\S+\.rc\b", text or ""))
    redirects_log = bool(log) and bool(text) and any(
        os.path.basename(t.strip("'\"")) == os.path.basename(log)
        for t in re.findall(r">>?\s*(\S+)", text or ""))
    # ⛔ A TAG IS NOT A SUBSTRING: `TAG=1` must not match `lane-12.sh`. Whole-token on both sides.
    # ⛔ `/` IS PART OF THE TOKEN: without it a tag equal to ANY path component (`home`, `tmp`,
    # `orchestrator`) or to `argv[0]` (`bash`) matches, which grants strong ownership on a path
    # fragment (cycle 4, P2). Only a whole ARGUMENT may name the tag.
    tag_on_argv = bool(tag) and bool(re.search(r"(?<![\w./-])%s(?![\w./-])" % re.escape(tag or ""),
                                              launcher_argv or ""))
    if tag:
        if tag_on_argv:
            return "tag", "its launcher %s carries %s on its own argv" % (base, tag)
        if re.search(r"(?m)(^|[\s;])(export[ \t]+)?TAG=['\"]?%s['\"]?(\s|;|$)" % re.escape(tag),
                     text or ""):
            return "tag", "its launcher %s ASSIGNS TAG=%s" % (base, tag)
        if re.search(r">>?\s*\S*%s\.rc\b" % re.escape(tag), text or ""):
            return "tag", "its launcher %s writes %s.rc" % (base, tag)
        if redirects_log:
            return "tag", "its launcher %s redirects into the log this process holds" % base
        if writes_rc or known_runner:
            return "weak", ("TAG=%s is named by no basis of %s (not on its argv, not assigned, not "
                            "its .rc, not its log redirect) — ownership rests on its text alone"
                            % (tag, base))
        return None, ("no-owner: TAG=%r is named by no basis of the launcher %s and it neither "
                      "redirects this log nor writes %s.rc" % (tag, base, tag))
    if not text:
        return None, "no-owner: the launcher %s is unreadable and TAG is absent" % base
    if not re.search(r"(^|\s)(pi|run_agent)(\s|$)", text) or ">" not in text:
        return None, "no-owner: the launcher %s does not invoke pi / redirect a log" % base
    if redirects_log:
        return "launcher", "the launcher %s redirects into the log this process holds" % base
    return None, "no-owner: the launcher's log is not the one this process holds"


def rc_path_for(launcher: Optional[str], tag: Optional[str], log: Optional[str]) -> Optional[str]:
    """The `<tag>.rc` the launcher writes after its `pi` exits (VERIFICATION ONLY, never a reason).

    Order: the launcher's own `> …*.rc` redirect; else `<tag>.rc` beside the log this process holds
    (honours a launcher whose `O` is not `$HOME/orchestrator`); else `$HOME/orchestrator/logs/…`.
    """
    home = os.environ.get("HOME", "")
    if launcher:
        text = _read(launcher) or ""
        found = [t.strip("'\"") for t in re.findall(r">>?\s*(\S+\.rc)(?=\s|$)", text)]
        if found:
            return found[-1].replace("${HOME}", home).replace("$HOME", home)
    if tag and log:
        return os.path.join(os.path.dirname(log), tag + ".rc")
    if tag:
        return os.path.join(home, "orchestrator", "logs", tag + ".rc")
    return None


def held_log(pid: str) -> Tuple[Optional[str], str]:
    for fd in ("1", "2"):
        link = "/proc/%s/fd/%s" % (pid, fd)
        if os.path.exists(link):
            try:
                target = os.readlink(link)
            except OSError:
                continue
            if os.path.isabs(target):
                return target, "fd%s" % fd
    return None, "no absolute file on fd 1/2 (the read may have been refused, or /proc is absent)"


def log_marker(log: Optional[str], holders: int) -> Tuple[str, str]:
    """('ok'|'hook-failed'|'reused'|'shared'|'absent'|'unreadable', detail).

    ATTRIBUTION IS DECIDED BEFORE CONTENT: a shared or reused log can never authorise, whatever its
    last line says. `EXIT rc=` is matched ANCHORED on the last line because only the launcher writes
    it, and only at column 0 (a quoted copy inside a report must not be read as a launcher write).
    """
    if not log:
        return "unreadable", "no log fd (unreadable)"
    text = _read(log)
    if text is None:
        return "absent", "the log this process holds is gone"
    if holders > 1:
        return "shared", "%d candidates hold this same log path; its content is not this pid's" % holders
    lines = [ln for ln in text.splitlines() if ln.strip()]
    if not lines:
        return "unreadable", "the log is empty"
    if re.match(r"^EXIT rc=\d+\b", lines[-1]):
        return "reused", "a later invocation of the same launcher wrote EXIT rc= into this log"
    last = lines[-1]
    if last.startswith(STARTUP):
        return "startup", "the last line is the STARTUP capture status, not a completion: %s" % last[:120]
    if any(last.startswith(f) for f in COMPLETION_FAILED):
        return "hook-failed", last[:160]
    if any(last.startswith(c) for c in COMPLETION_OK):
        return "ok", last[:160]
    if last.startswith(MARKER):
        return "absent", "an unrecognised [reflect-hook] line authorises nothing: %s" % last[:120]
    return "absent", "the last line is not a completion line: %s" % last[:120]


# ── census ──────────────────────────────────────────────────────────────────────────────────
def self_chain(rows: Dict[str, dict]) -> Set[str]:
    """This process, its ancestors and its descendants — never candidates (we are in the pool)."""
    chain: Set[str] = {str(os.getpid())}
    pid = str(os.getpid())
    for _ in range(40):
        ppid = (rows.get(pid) or {}).get("ppid")
        if not ppid or ppid in ("0", "1") or ppid in chain:
            break
        chain.add(ppid)
        pid = ppid
    frontier = [str(os.getpid())]
    while frontier:
        nxt: List[str] = []
        for p in frontier:
            for c, r in rows.items():
                if r.get("ppid") == p and c not in chain:
                    chain.add(c)
                    nxt.append(c)
        frontier = nxt
    return chain


def pool_cpu(pool, rows: Dict[str, dict], pid: str) -> Optional[float]:
    row = rows.get(pid)
    if not row:
        return None
    try:
        val = pool.cpu_seconds(row.get("time", ""))
    except Exception:                                                     # noqa: BLE001
        return None
    return None if val is None or val < 0 else val


def bind_map(pool, rows, pids: List[str], ref_s: float) -> Tuple[Dict[str, Optional[str]], Set[str]]:
    """{pid: transcript} for every candidate, plus the paths MORE THAN ONE candidate fenced onto.

    ⛔ Bound ONCE and shared by `observe` and `classify` — the pool owner's `taken` set protects one
    transcript from two VOTES, but two passes that each bind privately can measure growth on one
    file and then attribute it to another. The peer-claim case is reported symmetrically: when two
    candidates fence onto one transcript, NEITHER may use it (the tie cannot be resolved), so both
    abstain instead of one silently winning by pid order.
    """
    idx = pool.session_index(pool.SESSIONS_DIR)
    out: Dict[str, Optional[str]] = {}
    owners: Dict[str, List[str]] = {}
    for p in pids:
        path, _binding, _detail = pool.bind_session(p, rows[p], ref_s, idx, set())
        out[p] = path
        if path:
            owners.setdefault(path, []).append(p)
    return out, {path for path, held in owners.items() if len(held) > 1}


def observe(pool, rows, pids: List[str], window: float, binds):
    """One real sample window: (cpu delta per pid, pids whose held log grew, paths that grew).

    Two readings only, so a delta is comparable; an unreadable second reading is `None` — an
    ABSTENTION, never "unchanged". `(None, set(), set())` when the second `ps` fails: a failed read
    is not an empty world (the pool owner's own rule).
    """
    cpu0 = {p: pool_cpu(pool, rows, p) for p in pids}
    log0 = {p: _size(held_log(p)[0]) for p in pids}
    j0 = {p: _size(binds.get(p)) for p in pids}
    time.sleep(window)
    after = pool.ps_pi_fields()
    if not after:
        return None, set(), set()
    delta, log_grew, grew_paths = {}, set(), set()
    for p in pids:
        c0, c1 = cpu0[p], pool_cpu(pool, after, p)
        delta[p] = None if (c0 is None or c1 is None or c1 < c0) else round(c1 - c0, 3)
        size = _size(held_log(p)[0])
        if log0[p] is not None and size is not None and size > log0[p]:
            log_grew.add(p)
        jnow = _size(binds.get(p))
        if j0[p] is not None and jnow is not None and jnow > j0[p]:
            grew_paths.add(binds[p])
    return delta, log_grew, grew_paths


def classify(pid: str, rows: Dict[str, dict], canon, pool, binds, peers, obs, opts) -> dict:
    delta, log_grew, grew_paths = obs
    tol = pool.TOLERANCE_S
    row = rows[pid]
    out = {"pid": int(pid), "etime": row.get("etime", ""), "cls": None, "why": "",
           "cpu_delta": delta.get(pid), "launcher": None, "owner": "-", "log": None, "marker": "-",
           "transcript": None, "turn": "-", "jsonl_age_s": None, "log_age_s": None,
           "children": [], "rc": None, "rc_note": None, "tag": None}

    ppid, _lacmd, launcher = launcher_of(pid, rows)
    out["launcher"], out["ppid"] = launcher, ppid

    if pid in self_chain(rows):
        out.update(cls="CENSUS", why="this process's own chain (self/ancestor/descendant)")
        return out

    log, _src = held_log(pid)
    out["log"] = log
    env = environ(pid)
    if env is None or log is None:
        # ⛔ `/proc` is the platform (see the docstring). An unreadable environ or fd is NOT
        # "no tag" and NOT "no log": it is cannot-verify, and the pass says so instead of
        # signalling on a weaker channel (cycle 2, P2-3).
        out.update(cls="UNATTRIBUTABLE",
                   why="proc-unreadable: /proc/%s/%s could not be read, so ownership cannot be "
                       "established (this tool is Linux-only by construction)"
                       % (pid, "environ" if env is None else "fd/1"))
        return out
    tag = env.get("TAG")
    out["tag"] = tag
    out["rc"] = rc_path_for(launcher, tag, log)

    # A `pi` whose parent is another `pi` is a `task` sub-agent: its transcript is its parent's, and
    # its lifetime is its parent's business.
    parent_row = rows.get(str(ppid)) if ppid else None
    if parent_row and pool.is_pi(parent_row):
        out.update(cls="UNATTRIBUTABLE", why="task-child: its parent is a `pi`, not a lane launcher")
        return out

    rung, why = ownership(pid, launcher, log, _lacmd)
    if rung is not None and not PRINT_MODE.search(code_only(_read(launcher))):
        out.update(cls="UNATTRIBUTABLE",
                   why="interactive-or-unknown-mode: the launcher's text does not show a PRINT-mode "
                       "invocation, so this `pi` may be an agent waiting at a prompt — which also "
                       "reaches turn-ended and frozen CPU, and is never ours to signal")
        return out
    if rung is None:
        out.update(cls="UNATTRIBUTABLE", why=why)
        return out
    out["owner"] = rung
    if rung == "weak":
        # ⛔ ONE VETO, ON BOTH DONE ARMS. Cycle 3 measured the log-only arm reaping a row whose owner
        # was `weak`, because the veto below only ran on the transcript arm — and a `--no-session`
        # lane is decided by the log arm, i.e. the veto was absent exactly where it was needed.
        out.update(cls="UNATTRIBUTABLE",
                   why="weak-owner: %s — report only" % why)
        return out

    # ── gate 2's safety intent, unchanged: a human above is a hard refusal ──
    kind, detail = pool.gate2_host_decision(pool.ancestry(pid, rows))
    if kind == "human":
        out.update(cls="KEEP-HUMAN", why="a human host is above this process (%s)" % detail)
        return out
    if kind != "hostless":
        out.update(cls="UNATTRIBUTABLE", why="ancestry-unreadable: %s" % detail)
        return out

    kids = children_of(pid, rows)
    out["children"] = kids
    if kids:
        out.update(cls="LIVE", why="a live child (%s) — it may be waiting on real work"
                   % ", ".join(map(str, kids)))
        return out

    if pid in log_grew:
        out.update(cls="LIVE", why="the log this process holds GREW inside the sample window")
        return out
    if delta.get(pid) is None:
        out.update(cls="UNATTRIBUTABLE", why="cpu-unreadable: the two CPU readings were not comparable")
        return out
    if delta[pid] >= tol:
        out.update(cls="LIVE", why="cpu moving (+%.2fs over %.0fs)" % (delta[pid], opts.sample))
        return out

    # ── channel B: the canon's turn boundary over the bound transcript ──
    path = binds.get(pid)
    out["transcript"] = path
    stalled: Optional[bool] = None
    if path and path in peers:
        out.update(cls="UNATTRIBUTABLE",
                   why="peer-claimed: another candidate fences onto the same transcript, so neither "
                       "can claim its turn boundary")
        return out
    if path:
        turn = canon.turn_from_jsonl(path)
        if turn is not None:
            # ⛔ AN ABSTENTION LICENSES NOTHING. `Turn.abstain` carries `stalled=False`, so reading
            # `stalled` alone would turn the canon's fail-closed forms (`tail-after-compaction`,
            # `turn-unknown:<reason>`) into a kill licence — the exact shape #1254/#1272 removed.
            out["turn"] = turn.reason if not turn.abstain else "abstain:%s" % turn.reason
            stalled = None if turn.abstain else turn.stalled
        _g, age = canon.jsonl_state(path, int(time.time() * 1000))
        out["jsonl_age_s"] = None if age is None else age // 1000
        if age is None:
            out.update(cls="UNATTRIBUTABLE", why="no-transcript: the transcript age could not be read")
            return out
        # MIN_IDLE_S = 120 s = twelve sample windows. A print-mode `pi` must exit when its turn
        # ends, so 120 s of total silence in BOTH its transcript and its log is two orders of
        # magnitude past any exit path — and it is a bound this tool applies in ADDITION to the
        # canon's, never instead of it (the canon's 20 min / 24 h bounds still gate everything the
        # canon decides). It is pinned by the suite's `--min-idle` leg.
        if age // 1000 < opts.min_idle:
            out.update(cls="LIVE", why="the transcript was written %ds ago (under %ds)"
                       % (age // 1000, opts.min_idle))
            return out
        if path in grew_paths:
            out.update(cls="LIVE", why="the transcript GREW inside the sample window")
            return out
    else:
        out["turn"] = "unbound:no-session-file"

    # ── channel C: the log, attributed only when this pid holds it exclusively ──
    holders = sum(1 for q in rows if held_log(q)[0] == log) if log else 0
    marker, mdetail = log_marker(log, holders)
    out["marker"] = marker
    if log and os.path.exists(log):
        out["log_age_s"] = int(max(0, time.time() - os.stat(log).st_mtime))
    # E: the tag's `.rc` is VERIFICATION ONLY. If it is newer than this process it belongs to another
    # invocation of the same tag — say so, so no reader treats it as this lane's status.
    if out["rc"] and _mtime(out["rc"]) is not None:
        started = time.time() - _etime_s(row.get("etime", ""))
        if started and _mtime(out["rc"]) / 1e9 > started:
            out["rc_note"] = "shared-incarnation: this tag's .rc was written after this process started"

    # ── the verdict ────────────────────────────────────────────────────────────────────
    if stalled is True:
        out.update(cls="HUNG",
                   why="the turn is still OPEN (%s) and the process is frozen — mid-turn work is "
                       "not ours to clear" % out["turn"])
        return out

    if stalled is False:
        if marker in ("shared", "reused"):
            out.update(cls="DONE-NOT-EXITED",
                       why="turn ENDED (the transcript is the attribution); log evidence is %s" % marker)
        elif marker == "hook-failed":
            out.update(cls="DONE-NOT-EXITED",
                       why="turn ENDED; the end-of-turn hook FAILED (%s) — nothing left to write"
                       % mdetail)
        elif marker == "ok":
            out.update(cls="DONE-NOT-EXITED",
                       why="turn ENDED; its own log ends with a completion line; cpu frozen")
        else:
            out.update(cls="DONE-NOT-EXITED",
                       why="turn ENDED; cpu frozen; no completion line in its log (%s)" % marker)
        return out

    # No usable turn boundary: an exclusively-held, successful completion line may decide — and the
    # row names the channel, so a reader can see the weaker evidence.
    if marker == "ok" and (out["log_age_s"] or 0) >= opts.min_idle:
        out.update(cls="DONE-NOT-EXITED",
                   why="transcript %s; its own exclusive log ends with a completion line and is %ds "
                       "old" % (out["turn"], out["log_age_s"]))
        return out
    out.update(cls="UNATTRIBUTABLE",
               why="no usable transcript (%s) and the log does not decide (%s)" % (out["turn"], marker))
    return out


def _etime_s(t: str) -> float:
    d = 0.0
    if "-" in t:
        a, t = t.split("-", 1)
        try:
            d = float(a)
        except ValueError:
            return 0.0
    try:
        parts = [float(x) for x in t.split(":")]
    except ValueError:
        return 0.0
    return d * 86400 + sum(v * (60 ** i) for i, v in enumerate(reversed(parts)))


# ── apply ──────────────────────────────────────────────────────────────────────────────────
def verify_target(r: dict, canon, pool, window: float) -> Tuple[bool, str]:
    """Re-verify identity, authorisation AND the liveness channels immediately before the signal.

    ⛔ A per-target `ps` read, not the census's: the loop can spend `window` seconds per target, so a
    snapshot taken once before it is minutes old for the last one. Identity alone is not the
    authorisation (#1696): the turn boundary, the CPU delta and the growth vetoes are all re-asked.
    """
    fresh = pool.ps_pi_fields()
    if not fresh:
        return False, "CANNOT-VERIFY: the pre-signal process read returned nothing"
    pid = str(r["pid"])
    cur = fresh.get(pid)
    if cur is None:
        return False, "vanished before the signal"
    if not pool.is_pi(cur):
        return False, "the pid is no longer a `pi` (recycled)"
    if not pool._same_incarnation(r, cur):                                # noqa: SLF001
        return False, "incarnation changed (etime moved)"
    kind, detail = pool.gate2_host_decision(pool.ancestry(pid, fresh))
    if kind != "hostless":
        return False, "ancestry re-check is %s (%s) at signal time" % (kind, detail)
    if children_of(pid, fresh):
        return False, "a child appeared at signal time — it may be working"
    if r.get("transcript"):
        turn = canon.turn_from_jsonl(r["transcript"])
        # ⛔ `None` means the boundary could not be established — an ABSTENTION, and the tool's own
        # doctrine is that a check against an absent reading is not a check (cycle 2, P2-2).
        if turn is None:
            return False, "the turn boundary could not be re-established at signal time"
        if turn.stalled or turn.abstain:
            return False, "the turn is no longer ended (%s) at signal time" % turn.reason
    # the liveness channels, re-sampled: CPU, the held log, the transcript
    c0 = pool_cpu(pool, fresh, pid)
    log_m0, j_m0 = _size(r.get("log")), _size(r.get("transcript"))
    time.sleep(window)
    again = pool.ps_pi_fields()
    if not again:
        return False, "CANNOT-VERIFY: the verification read returned nothing"
    if not pool.is_pi(again.get(pid) or {}):
        return False, "the pid is no longer a `pi` at the end of the verification window"
    c1 = pool_cpu(pool, again, pid)
    # ⛔ A DECREASE is not "frozen": cumulative CPU cannot shrink for a fixed process, so a lower
    # reading means the pid was RECYCLED (or the read was truncated) — the readings are not
    # comparable, and `classify` already refuses the same shape (cycle 2, P2-1).
    if c0 is None or c1 is None or c1 < c0 or c1 - c0 >= pool.TOLERANCE_S:
        return False, "cpu moved or became incomparable inside the verification window (%s -> %s)" % (c0, c1)
    if _size(r.get("log")) is not None and log_m0 is not None and _size(r.get("log")) != log_m0:
        return False, "the log changed inside the verification window (grew, or was rewritten)"
    if r.get("log"):
        holders = sum(1 for q in again if held_log(q)[0] == r["log"])
        marker_now, _d = log_marker(r["log"], holders)
        if r.get("marker") in ("ok", "hook-failed") and marker_now != r.get("marker"):
            return False, ("the log's deciding line changed at signal time (%s -> %s)"
                           % (r.get("marker"), marker_now))
    if _size(r.get("transcript")) is not None and j_m0 is not None and _size(r["transcript"]) > j_m0:
        return False, "the transcript grew inside the verification window"
    return True, "still done-not-exited"


def apply_done(done: List[dict], canon, pool, opts) -> int:
    """SIGTERM every DONE-NOT-EXITED; report reaped / refused / survived as THREE buckets.

    ⛔ A cell lane's ancestry reaches init, so every row here is `hostless` — the class owner-approved
    option A on #1207/#1297 keeps REPORT-ONLY, and whose reopen (**agent-infra#2391**, still OPEN) says
    "No code is proposed for adoption here". This file therefore signals nothing on that class unless
    the operator passes `--authorise-hostless`, whose help text names the decision. The census still
    reports every row; only the ACT is gated. Exit 4 is the repo's existing token for a complete pass
    that judged finish-ness and was not authorised to act (the shape `lane-reap.sh` uses for a
    policy-inert reap) — never 0, and never confused with a failed read (3).
    """
    if not opts.authorise_hostless:
        print("REPORT-ONLY: %d DONE-NOT-EXITED row(s) not signalled — a cell lane's chain is "
              "`hostless`, which #1207/#1297 option A keeps report-only and whose reopen "
              "(agent-infra#2391) is still open. Re-run with --authorise-hostless once the owner "
              "has ruled." % len(done))
        print("\nreaped 0, refused 0, survived 0, report-only %d" % len(done))
        return 4
    reaped = refused = survived = 0
    for r in done:
        pid = str(r["pid"])
        ok, why = verify_target(r, canon, pool, opts.verify_sample)
        if not ok:
            if why.startswith("CANNOT-VERIFY"):
                print("%s: %s; NOTHING signalled (a check against an absent reading is not a check)"
                      % (PROG, why), file=sys.stderr)
                return 3
            print("  %s REFUSED: %s — nothing done" % (pid, why))
            refused += 1
            continue
        rc_mtime = _mtime(r.get("rc"))
        try:
            os.kill(int(pid), signal.SIGTERM)
        except OSError as exc:
            print("  %s FAILED to signal: %s" % (pid, exc))
            survived += 1
            continue
        deadline = time.time() + 20
        while time.time() < deadline and alive(pid):
            time.sleep(0.25)
        gone = not alive(pid)
        wrote = _mtime(r.get("rc")) is not None and _mtime(r.get("rc")) != rc_mtime
        print("  %s TERM → %s%s" % (pid, "exited" if gone else "SURVIVED",
                                    "; launcher wrote its .rc" if wrote else ""))
        if gone:
            reaped += 1
        else:
            survived += 1
    print("\nreaped %d, refused %d, survived %d" % (reaped, refused, survived))
    if refused:
        print("⚠️ %d target(s) were refused at signal time: the census verdict was wrong by then, and "
              "those lanes are STILL resident (still reading as RUNNING)" % refused)
    return 1 if (survived or refused) else 0


def main(argv: Optional[List[str]] = None) -> int:
    ap = argparse.ArgumentParser(prog=PROG, description=__doc__.split("\n")[0])
    ap.add_argument("--apply", action="store_true",
                    help="SIGTERM every DONE-NOT-EXITED (default: dry run, classify only)")
    ap.add_argument("--sample", type=float, default=10.0, help="CPU/log sample window in seconds")
    ap.add_argument("--verify-sample", type=float, default=2.0,
                    help="per-target re-check window immediately before the signal")
    ap.add_argument("--min-idle", type=float, default=MIN_IDLE_S,
                    help="the lane must have been silent this long (transcript and log)")
    ap.add_argument("--json", action="store_true", help="print one JSON row per candidate")
    ap.add_argument("--quiet", action="store_true", help="summary only")
    ap.add_argument("--authorise-hostless", action="store_true",
                    help="signal rows whose ancestry is `hostless` (a cell lane always is). This is "
                         "the act #1207/#1297 option A reserves for an owner ruling, and the reopen "
                         "agent-infra#2391 is still OPEN with 'no code proposed' — so it is a named, "
                         "deliberate operator act, never a default and never set by a supervisor pass")
    ap.add_argument("--pid", action="append", type=int, default=None,
                    help="judge ONLY this pid (repeatable) — for one named lane, and for a test that "
                         "must not touch the box's real population")
    ap.add_argument("--sessions-dir", default=None,
                    help="override the transcript store (default: the pool owner's SESSIONS_DIR)")
    opts = ap.parse_args(argv)

    try:
        canon, pool = imports()
    except Exception as exc:                                              # noqa: BLE001
        print("%s: CANNOT-VERIFY — %s" % (PROG, exc), file=sys.stderr)
        return 3

    # ⛔ `ref_s` is read WITH the `ps` snapshot, not after the session-dir glob: the fence is ±
    # FENCE_S against `ref_s - etime`, and a reference taken after a large glob slides every
    # candidate out of it (the pool owner's own warning) — which would silently disable channel B.
    opts.ref_s = time.time()
    rows = pool.ps_pi_fields()
    if not rows:
        print("%s: CANNOT-VERIFY — the process table could not be read; nothing was judged"
              % PROG, file=sys.stderr)
        return 3
    pool.SESSIONS_DIR = opts.sessions_dir or pool.SESSIONS_DIR

    all_pids = sorted([p for p, r in rows.items() if pool.is_pi(r)], key=int)
    pids = all_pids
    if opts.pid:
        foreign = [str(p) for p in opts.pid if str(p) not in rows or not pool.is_pi(rows[str(p)])]
        if foreign:
            print("%s: CANNOT-VERIFY — --pid %s is not a live `pi`; nothing was judged"
                  % (PROG, ", ".join(foreign)), file=sys.stderr)
            return 3
        pids = [str(p) for p in opts.pid]

    # ⛔ OVER THE WHOLE POPULATION, not the selected subset: `--pid` must not silently disable the
    # peer-claimed guard (cycle 4, P2), which is the mirror of the `holders` check that already reads
    # the full snapshot.
    binds, peers = bind_map(pool, rows, all_pids, opts.ref_s)
    obs = observe(pool, rows, pids, opts.sample, binds)
    if obs[0] is None:
        print("%s: CANNOT-VERIFY — a sample reading failed; nothing was judged" % PROG,
              file=sys.stderr)
        return 3

    out = [classify(p, rows, canon, pool, binds, peers, obs, opts) for p in pids]
    after = pool.ps_pi_fields() or {}
    for r in out:
        r["etime_after"] = (after.get(str(r["pid"])) or {}).get("etime", r["etime"])
    census = [r for r in out if r["cls"] == "CENSUS"]
    out = [r for r in out if r["cls"] != "CENSUS"]
    if census:
        # ⛔ Never silently dropped (cycle 2, P2-4): a named `--pid` that happens to be this process's
        # own chain must be distinguishable from "there was nothing to do".
        print("· %d candidate(s) are this process's own chain and are never candidates: %s"
              % (len(census), ", ".join(str(r["pid"]) for r in census)))
    if opts.pid and not out:
        print("%s: CANNOT-VERIFY — every --pid given is this process's own chain; nothing was judged"
              % PROG, file=sys.stderr)
        return 3

    if opts.json:
        for r in out:
            print(json.dumps(r, sort_keys=True))
    elif not opts.quiet:
        print("%-8s %-11s %-16s %-7s %-8s %-11s %s"
              % ("pid", "etime", "class", "cpu_d", "owner", "turn", "why  [launcher]"))
        for r in out:
            print("%-8d %-11s %-16s %-7s %-8s %-11s %s%s"
                  % (r["pid"], r["etime"], r["cls"],
                     "-" if r["cpu_delta"] is None else "%.2f" % r["cpu_delta"],
                     r["owner"], r["turn"][:11],
                     r["why"],
                     "  [%s]" % os.path.basename(r["launcher"]) if r["launcher"] else ""))

    counts: Dict[str, int] = {}
    for r in out:
        counts[r["cls"]] = counts.get(r["cls"], 0) + 1
    done = [r for r in out if r["cls"] == "DONE-NOT-EXITED"]
    print("\n==== %d candidate(s): %s ===="
          % (len(out), " · ".join("%s=%d" % kv for kv in sorted(counts.items()))))
    if done:
        print("DONE-NOT-EXITED: %s" % ", ".join(str(r["pid"]) for r in done))

    # ⛔ An ABSTENTION over the whole population is cannot-verify, never a clean pass: a supervisor
    # that reads exit 0 here would conclude the fleet is clean while the tool was blind on the box.
    if out and counts.get("UNATTRIBUTABLE", 0) == len(out):
        print("%s: CANNOT-VERIFY — every one of %d candidate(s) was UNATTRIBUTABLE; this pass judged "
              "nothing" % (PROG, len(out)), file=sys.stderr)
        return 3

    if not opts.apply:
        if done:
            print("dry run — %d DONE-NOT-EXITED found; re-run with --apply --authorise-hostless to "
                  "SIGTERM them." % len(done))
            # ⛔ 4, not 0: the same token as an unarmed `--apply`, because the meaning is the same —
            # work was found and this pass was not authorised to act. A dry run that exits 0 here
            # tells a supervisor the fleet is clean (cycle 3, P2).
            return 4
        else:
            print("nothing to reap: %d live, %d hung, %d refused."
                  % (counts.get("LIVE", 0), counts.get("HUNG", 0), counts.get("UNATTRIBUTABLE", 0)))
        return 0
    if not done:
        print("apply: nothing to reap — %d live, %d hung, %d refused (each named above)."
              % (counts.get("LIVE", 0), counts.get("HUNG", 0), counts.get("UNATTRIBUTABLE", 0)))
        return 0
    return apply_done(done, canon, pool, opts)


if __name__ == "__main__":
    sys.exit(main())
