#!/usr/bin/env python3
"""tools/fleet/fleet_health.test.py — hermetic suite for the REAPER table in fleet-health.py (#1862).

`tools/fleet/fleet-health.py`'s `reaper_section()` is the repo's only instrument for the class
*"a scheduled reaper that fails SILENTLY"* — its own measured evidence is `com.eldato.pi-cache-reap`
at exit 5 for days, `com.tortoise.worktree-reaper` loaded-and-inert, and three cloud cells at a
disk-full. It reads a HARD-CODED tuple, so a newly scheduled reaper that is not in that tuple is
never read at all: the section prints its rows and exits 0 over a job that may be `NOT INSTALLED`,
loaded-and-inert, or aborting fail-closed on every pass. That is a false PASS from a liveness
instrument, which is why the panel is pinned here rather than left to a reader's memory.

Restored by #1862 and pinned by this suite:
  * `REAPERS` carries `("com.eldato.pi-reap-orphans", "orphan")`;
  * `REQUIRED_LABELS` carries the label (its plist has NO `{{TORTOISE_REPO}}` placeholder, so
    `install-launchd.sh` installs it unconditionally — absence is a missing clock, not a skip);
  * `REAPER_CODES["orphan"]` is the script's OWN vocabulary `{0, 2, 3, 4}`, and its `4` is
    "a kill FAILED", deliberately NOT `worktree`'s `4` ("a removal FAILED") — the conflation the
    table's own comment forbids. `3` is fail-closed (*nothing was signalled*) and therefore an
    ALARM, unlike `cache`'s benign `4` (another pass holds the lock).

    python3 tools/fleet/fleet_health.test.py
    python3 tools/fleet/fleet_health.test.py --red-control

RED CONTROL — four mutations of the shipped module, each written to a TEMP copy and re-imported
(a mutation the suite does not catch is reported as a suite FAILURE). The first one is the
pre-fix state of this very change, so the suite is proved non-vacuous against it:

  * drop the orphan row from REAPERS            -> REGISTERED red  (the pre-#1862 module)
  * re-file "orphan" as "worktree"              -> REGISTERED red + DRIFT red + MEANING-IV red
  * drop the label from REQUIRED_LABELS         -> REQUIRED red + ABSENT red
  * flatten orphan exit 4 to benign ("ok")      -> DRIFT red + MEANING-IV red

⛔ A paired check counts as RED only when it printed the `❌` MARKER. `check()` prints the same
message text for pass and fail, so "the message appears in the mutant's output" is satisfied by a
GREEN leg as well — a text-presence control reports REDs that never happened (measured: the
`orphan`->`worktree` mutation left the whole MEANING-III (exit 3) leg green, because worktree's
exit-3 text also contains "fail-closed", yet the control printed it as red). Membership in
`MUTATIONS[i][2]` is therefore matched against `RED_MARK + msg`, never the bare message.

`leg_drift` carries its own non-vacuity probe: it scans the script through `scan_exits()` and that
scanner is checked against a synthetic snippet in the INDENTED standalone shape the script writes
its fail-closed aborts in (`        exit 3`), which a column-0-only `^` anchor does not match.

Zero-dep by construction: python3 only. The module is loaded by path (its filename has a hyphen),
`launchctl` is never executed (a fake `subprocess.run` returns a table), and `sys.platform` is
patched for the duration of a leg and restored in a `finally`, so nothing touches the real fleet,
the real launchd, or the real process table.
"""

from __future__ import annotations

import importlib.util
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
MODULE_PATH = os.path.normpath(os.path.join(HERE, "fleet-health.py"))
REAPER_PATH = os.path.normpath(os.path.join(HERE, "..", "..", "scripts", "pi-reap-orphans.sh"))
LABEL = "com.eldato.pi-reap-orphans"

PASS = 0
FAIL = 0

# The two markers are the suite's ONLY machine-checkable polarity signal (see the module docstring):
# the message text is identical for pass and fail, so anything reading the output must key on these.
GREEN_MARK = "  ✅ "
RED_MARK = "  ❌ "


def ok(msg):
    global PASS
    PASS += 1
    print("%s%s" % (GREEN_MARK, msg))


def bad(msg):
    global FAIL
    FAIL += 1
    print("%s%s" % (RED_MARK, msg))


def check(cond, msg):
    ok(msg) if cond else bad(msg)
    return bool(cond)


class _FakeRun:
    """Stand-in for the `subprocess` module name inside fleet-health.py (never spawns anything)."""

    def __init__(self, table):
        self.table = table
        self.calls = 0

    def run(self, argv, **kwargs):  # noqa: D401 - the module's only call is `launchctl list`
        self.calls += 1
        return subprocess.CompletedProcess(argv, 0, stdout=self.table, stderr="")


def load_module(path=MODULE_PATH, name="fleet_health_under_test"):
    """Load `fleet-health.py` by path (the hyphen makes it un-importable by name)."""
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def launchctl_table(rows, extra=""):
    """`launchctl list` output: a header line, then PID<TAB>Status<TAB>Label."""
    lines = ["PID\tStatus\tLabel"]
    if extra:
        lines.append(extra)
    for status, label in rows:
        lines.append("1234\t%s\t%s" % (status, label))
    return "\n".join(lines) + "\n"


def run_section(mod, table, launchctl_available=True):
    """Call reaper_section() as macOS, capturing (text, alarms). Returns (stdout_text, alarms, fake).

    `reaper_section()` PROBES FOR THE TOOL, NOT THE PLATFORM (main's `shutil.which("launchctl")`
    gate): a host whose launchd table cannot be read is an ABSTENTION and must never be reported as
    "every label NOT INSTALLED". A macOS host always answers the probe, so a leg that asserts the
    exit table must model that — with `launchctl` absent (as on a Linux runner) the section would
    otherwise return before exercising anything, and the leg would pass over an unread table.
    `launchctl_available=False` drives the abstention arm itself.
    """
    fake = _FakeRun(table)
    real_platform, real_subprocess = mod.sys.platform, mod.subprocess
    real_which = mod.shutil.which
    import io
    from contextlib import redirect_stdout
    buf = io.StringIO()
    mod.sys.platform = "darwin"
    mod.subprocess = fake
    mod.shutil.which = (lambda name: "/usr/bin/launchctl" if name == "launchctl" else real_which(name)) \
        if launchctl_available else (lambda name: None)
    try:
        with redirect_stdout(buf):
            alarms = mod.reaper_section()
    finally:
        mod.sys.platform = real_platform
        mod.subprocess = real_subprocess
        mod.shutil.which = real_which
    return buf.getvalue(), alarms, fake


def leg_launchctl_abstention(mod):
    """Main's guard: an unreadable launchd table is an ABSTENTION, never "no reapers"."""
    text, alarms, fake = run_section(mod, launchctl_table([]), launchctl_available=False)
    check(fake.calls == 0, "ABSTAIN: no launchctl table is read when the tool is absent")
    check("not applicable on this host" in text,
          "ABSTAIN: the absent tool is reported as not applicable — text: %r" % text.strip())
    check(not [a for a in alarms if LABEL in a],
          "ABSTAIN: the required label is NOT reported NOT INSTALLED on a host without launchd — %r"
          % (alarms[:1],))
    check(not [a for a in alarms if "launchctl unreadable" in a],
          "ABSTAIN: a host that never had launchd is not an unreadable-table alarm — %r" % (alarms[:1],))


# ── legs ─────────────────────────────────────────────────────────────────
def leg_registered(mod):
    families = dict(mod.REAPERS)
    check(LABEL in families,
          "REGISTERED: %s is in REAPERS (a label absent from that tuple is never read at all)" % LABEL)
    check(families.get(LABEL) == "orphan",
          "REGISTERED: its family is 'orphan' (got %r)" % (families.get(LABEL),))
    check("orphan" in mod.REAPER_CODES,
          "REGISTERED: REAPER_CODES has an 'orphan' table")
    check(LABEL in mod.REQUIRED_LABELS,
          "REQUIRED: %s is in REQUIRED_LABELS (its plist has no {{TORTOISE_REPO}}, so it installs unconditionally)" % LABEL)
    # No duplicate label: two rows for one label would print the same job twice and index one family.
    labels = [lbl for lbl, _ in mod.REAPERS]
    check(len(labels) == len(set(labels)), "REGISTERED: no duplicate label in REAPERS")


def leg_meaning(mod, code, expect_substr, forbid=(), expect_alarm=True, tag=""):
    text, alarms, fake = run_section(mod, launchctl_table([(str(code), LABEL)]))
    check(fake.calls == 1, "  %s: read `launchctl list` exactly once" % tag)
    check(LABEL in text, "MEANING %s: exit %d is REPORTED (the label has a row)" % (tag, code))
    row = next((ln for ln in text.splitlines() if LABEL in ln), "")
    check(expect_substr.lower() in row.lower(),
          "MEANING %s: exit %d says %r — row: %s" % (tag, code, expect_substr, row.strip()))
    for f in forbid:
        check(f.lower() not in row.lower(),
              "MEANING %s: exit %d does NOT borrow %r — row: %s" % (tag, code, f, row.strip()))
    if expect_alarm:
        hit = [a for a in alarms if LABEL in a]
        check(bool(hit), "MEANING %s: exit %d raises an ALARM — %r" % (tag, code, hit[:1]))
    else:
        check(not [a for a in alarms if LABEL in a],
              "MEANING %s: exit %d raises NO alarm" % (tag, code))


# `^` MUST be free to be followed by indentation: this script writes its fail-closed aborts as an
# indented STANDALONE statement (`        exit 3`, 12 such lines at this head), which a column-0-only
# anchor never matches — the vocabulary then reads a smaller set than the file can produce, so a new
# `        exit 5` abort would leave DRIFT green. The `[;&{|]` arm covers the one-liner forms
# (`… || exit 2`, `x; exit 0`, `*) usage; exit 2 ;;`).
EXIT_RE = re.compile(r"(?:^|[;&{|])\s*exit\s+(\d+)\b")


def scan_exit_lines(src):
    """[(line number, code)] for every statement-position `exit N` in a script's SOURCE."""
    hits = []
    for lineno, line in enumerate(src.splitlines(), 1):
        if line.lstrip().startswith("#"):
            continue
        for m in EXIT_RE.finditer(line):
            hits.append((lineno, int(m.group(1))))
    return hits


def scan_exits(src):
    """Statement-position `exit N` codes in a shell script's SOURCE (comments excluded)."""
    return {code for _, code in scan_exit_lines(src)}


def leg_drift(mod):
    """The table must be the SCRIPT's vocabulary, not a plausible-looking guess.

    Every statement-position `exit N` in scripts/pi-reap-orphans.sh must be a registered key of
    the orphan family: an unregistered code prints `UNRECOGNISED exit N — treated as broken`,
    which is the safe direction but means the drift was never reviewed. Comments/echo strings
    (`… (exit 3)`) are not statement position, so they cannot make this leg misfire.
    """
    # Non-vacuity probe of the SCANNER (not of the table): the snippet carries the indented
    # standalone shape and the two one-liner shapes the script actually uses. Pre-fix the
    # column-0-only anchor measured {} here.
    probe = "if x; then\n        exit 5\nfi\ny || exit 7\nz; exit 8\n"
    check(scan_exits(probe) == {5, 7, 8},
          "DRIFT: the exit scanner sees an INDENTED standalone `exit N` as well as the one-liners "
          "(measured %s)" % sorted(scan_exits(probe)))
    if not os.path.exists(REAPER_PATH):
        bad("DRIFT: %s is missing — cannot check the exit vocabulary" % REAPER_PATH)
        return
    src = open(REAPER_PATH, encoding="utf-8").read()
    # …and the same property ON THE REAL FILE, which is where the blind spot bit: this script writes
    # its fail-closed aborts as an indented standalone statement, so a scanner that only sees the
    # one-liner forms reads 11 lines here and misses 12 (every `exit 3` abort + the `--list` exit 0).
    # A code-set equality cannot catch that (the missed 3/0 are already in the set), so the pin is
    # LINE IDENTITY: every standalone-abort line must be one the scanner actually visited.
    standalone = {i for i, ln in enumerate(src.splitlines(), 1)
                  if re.match(r"^\s+exit\s+\d+\s*$", ln)}
    seen = {i for i, _ in scan_exit_lines(src)}
    check(bool(standalone) and standalone <= seen,
          "DRIFT: every indented standalone abort in the script is counted (%d line(s); missed %s)"
          % (len(standalone), sorted(standalone - seen) or "none"))
    codes = scan_exits(src)
    check(codes == {0, 2, 3, 4},
          "DRIFT: the script's statement-position exits are {0,2,3,4} (measured %s)" % sorted(codes))
    table = mod.REAPER_CODES.get("orphan", {})
    missing = sorted(codes - set(table))
    check(not missing,
          "DRIFT: every exit the script can produce is registered in REAPER_CODES['orphan']"
          + ("" if not missing else " — unregistered: %s" % missing))
    extra = sorted(set(table) - codes)
    check(not extra,
          "DRIFT: no registered code is unreachable (dead arm the script never returns)"
          + ("" if not extra else " — unreachable: %s" % extra))
    # `orphan`'s 3 is fail-closed on its OWN probes; `worktree`'s 3 blends library/git/gh/log with a
    # held lock and says so. The rows a monitor reads for this label must not BE worktree's blended
    # sentence — that is the family discriminator exit 3 CAN carry, and it is resolved through the
    # label's own family mapping (so re-filing the label under another family reds it). Its TEXT,
    # not the phrase "fail-closed": both families carry that phrase, which is why the MEANING-III leg
    # stays green on a re-file and is NOT listed as a paired red.
    family = dict(mod.REAPERS).get(LABEL)
    fam3 = mod.REAPER_CODES.get(family, {}).get(3, ("", False))[0]
    worktree3 = mod.REAPER_CODES.get("worktree", {}).get(3, ("", False))[0]
    check(family is not None and bool(fam3) and fam3 != worktree3,
          "DRIFT: %s is filed under a family whose exit 3 is its own fact, not worktree's blended one"
          % LABEL)
    # The script reaches `exit 4` by TWO paths — `TERM-FAILED` (the SIGTERM was not delivered, and it
    # deliberately does not escalate) and `KILL-FAILED` (survived SIGKILL / death unprovable) — both
    # incrementing FAILED (:1315, :1357). A meaning that names only one of them is a half-truth about
    # the code, so it is derived from the script rather than pinned as prose.
    if "TERM-FAILED" in src and "KILL-FAILED" in src:
        meaning = table.get(4, ("", False))[0].lower()
        check("term" in meaning and "kill" in meaning,
              "DRIFT: exit 4's meaning names BOTH counted failure modes (TERM-FAILED + KILL-FAILED) — got %r"
              % table.get(4, ("", False))[0])


def leg_absent(mod):
    """A REQUIRED label that launchd does not list is an alarm, not silence."""
    text, alarms, _ = run_section(mod, launchctl_table([], extra="-\t0\tcom.apple.something"))
    check(LABEL + " " in text and "NOT INSTALLED" in text,
          "ABSENT: an uninstalled REQUIRED label prints NOT INSTALLED — row: %s"
          % next((ln.strip() for ln in text.splitlines() if LABEL in ln), "(missing)"))
    # The alarm must be the ORPHAN label's own: the fixture's table carries other com.* rows and
    # every absent REQUIRED label raises its own alarm, so an `any(...)` without the label is
    # satisfied by a sibling's alarm — it would stay green even with the label dropped from
    # REQUIRED_LABELS (measured: that mutation reddened exactly one check before this was pinned).
    check(any(LABEL in a and "NOT INSTALLED" in a for a in alarms),
          "ABSENT: an uninstalled REQUIRED label raises an alarm")


def leg_no_verdict(mod):
    """`-` is 'no exit since load' — an abstention, never an alarm (a fresh login must not red)."""
    text, alarms, _ = run_section(mod, launchctl_table([("-", LABEL)]))
    check("no exit since load" in text,
          "NO-VERDICT: a `-` status prints as an abstention")
    check(not [a for a in alarms if LABEL in a],
          "NO-VERDICT: a `-` status raises no alarm")


def leg_unrecognised(mod):
    text, alarms, _ = run_section(mod, launchctl_table([("9", LABEL)]))
    check("UNRECOGNISED exit 9" in text,
          "UNRECOGNISED: an unregistered code is reported, not assumed benign")
    check(any(LABEL in a and "UNRECOGNISED" in a for a in alarms),
          "UNRECOGNISED: an unregistered code alarms")


def run_legs(mod):
    leg_registered(mod)
    leg_launchctl_abstention(mod)
    # 0 ok — the shipped dry-run stance, and a pass that never had a candidate.
    leg_meaning(mod, 0, "ok", expect_alarm=False, tag="OK")
    # 3 fail-closed: ps/lsof/identity/launchctl unusable, or the lock held — NOTHING signalled.
    leg_meaning(mod, 3, "fail-closed",
                forbid=("holds the lock", "benign", "removal FAILED"), tag="FAILCLOSED")
    # 4 "the pass completed but a kill FAILED" — NOT worktree's "a removal FAILED".
    leg_meaning(mod, 4, "kill FAILED", forbid=("removal FAILED",), tag="KILLFAILED")
    leg_meaning(mod, 2, "usage", expect_alarm=True, tag="USAGE")
    leg_drift(mod)
    leg_absent(mod)
    leg_no_verdict(mod)
    leg_unrecognised(mod)


# ── red control ─────────────────────────────────────────────────────────
def _sub(old, new):
    """A mutation that rewrites one anchor string (inert if the anchor is gone -> RED, visibly)."""
    return lambda src: (src.replace(old, new, 1), old in src)


def _flatten_exit4(src):
    """Flatten the ORPHAN table's exit-4 row to a benign `ok` — located by the family key, not by the
    row's prose, so a wording change cannot make this mutation silently inert."""
    m = re.search(r'"orphan":\s*\{.*?\n\s*4: \("([^"]*)", True\)\}', src, re.S)
    if not m:
        return src, False
    return src[:m.start(1)] + "ok" + src[m.end(1):], True


MUTATIONS = [
    ("drop the orphan row from REAPERS (the pre-#1862 module)",
     _sub('    ("com.eldato.pi-reap-orphans",     "orphan"),\n', ""),
     ["REGISTERED: %s is in REAPERS" % LABEL]),
    # exit 3 CANNOT be a paired red here: worktree's exit-3 text contains "fail-closed" too, so the
    # MEANING-III leg stays green under this mutation. The family discriminator that does fire is the
    # exit-3 DISTINCTNESS check (two families must not read the same sentence).
    ('re-file "orphan" as "worktree"',
     _sub('("com.eldato.pi-reap-orphans",     "orphan")', '("com.eldato.pi-reap-orphans",     "worktree")'),
     ["REGISTERED: its family is 'orphan'",
      "DRIFT: %s is filed under a family whose exit 3 is its own fact" % LABEL,
      "MEANING KILLFAILED: exit 4 says"]),
    ("drop the label from REQUIRED_LABELS",
     _sub(', "com.eldato.pi-reap-orphans"}', '}'),
     ["REQUIRED: %s is in REQUIRED_LABELS" % LABEL, "ABSENT: an uninstalled REQUIRED label raises an alarm"]),
    ("flatten orphan exit 4 to a benign ok",
     _flatten_exit4,
     ["MEANING KILLFAILED: exit 4 says", "DRIFT: exit 4's meaning names BOTH"]),
]


def run_mutation(desc, mutate, must_red, tmp):
    """Run one mutant in a subprocess. Returns (returncode, missed) — `missed` is polarity-keyed.

    ⛔ POLARITY, not text presence — see the module docstring. A paired check counts as red only
    under its `❌` marker; the identical message text under `✅` is a GREEN leg and must be reported
    as a missed pair, never as evidence.
    """
    src = open(MODULE_PATH, encoding="utf-8").read()
    mutated, found = mutate(src)
    if not found:
        return None, None
    # A stable (not hash-randomised) filename per mutation, so a leftover temp copy is identifiable.
    path = os.path.join(tmp, "fleet-health-mut-%s.py" % re.sub(r"\W+", "_", desc)[:40].strip("_"))
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(mutated)
    out = subprocess.run([sys.executable, os.path.abspath(__file__), "--_mutant", path],
                         capture_output=True, text=True)
    return out.returncode, [m for m in must_red if (RED_MARK + m) not in out.stdout]


# A pairing whose paired check stays GREEN on the mutant: `worktree`'s exit-3 text contains
# "fail-closed" too, so the MEANING-III leg passes. A control that reads the message TEXT calls this
# a successful red (measured at the previous head, which is the whole of finding #1863/P1); a control
# that keys on the marker must report it as MISSED. This is the control's own falsifier.
BLIND_PAIRING = ('re-file "orphan" as "worktree" (its exit-3 leg stays green)',
                 _sub('("com.eldato.pi-reap-orphans",     "orphan")',
                      '("com.eldato.pi-reap-orphans",     "worktree")'),
                 ["MEANING FAILCLOSED: exit 3 says"])


def red_control():
    print("\n── RED CONTROL: each mutation must turn its paired leg red ──")
    tmp = tempfile.mkdtemp(prefix="fleet-health-mut-")
    try:
        for desc, mutate, must_red in MUTATIONS:
            rc, missed = run_mutation(desc, mutate, must_red, tmp)
            if rc is None:
                bad("MUTATION %r: anchor not found in the module — the mutation is inert" % desc)
                continue
            if rc == 0:
                bad("MUTATION %r: suite stayed GREEN on the mutated module" % desc)
            elif missed:
                bad("MUTATION %r: paired check(s) did NOT go red (message seen without the ❌ "
                    "marker, or absent entirely): %s" % (desc, missed))
            else:
                ok("MUTATION %r -> RED (%s)" % (desc, ", ".join(m.split(":")[0] for m in must_red)))
        rc, missed = run_mutation(*BLIND_PAIRING, tmp=tmp)
        check(rc not in (None, 0) and bool(missed),
              "RED CONTROL: a pairing whose check stays GREEN is reported as MISSED, not as a red "
              "— the control keys on the ❌ marker, not on the message text")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def main(argv):
    mutant = None
    if "--_mutant" in argv:
        mutant = argv[argv.index("--_mutant") + 1]
    red = "--red-control" in argv and mutant is None

    print("fleet-health REAPER table suite (#1862)%s" % ("  [MUTANT]" if mutant else ""))
    try:
        mod = load_module(mutant or MODULE_PATH, "fleet_health_%s" % ("mut" if mutant else "live"))
    except Exception as exc:                                     # noqa: BLE001
        bad("MODULE LOAD: %s" % exc)
        return 1
    run_legs(mod)

    if red:
        red_control()

    print("\n%d passed, %d failed" % (PASS, FAIL))
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
