#!/usr/bin/env python3
"""fleet-health.py — liveness scan for the lanes and their task children.

This is a SUSPECT FINDER, not a verdict. A session can work for minutes without writing
to its transcript, so mtime alone proves nothing — confirm any suspect with
`cmux read-screen --workspace <ws> --surface surface:N`.

Strongest cheap "is it actually running" signal: **CPU-time delta** for the pid since the
previous run of this script (state kept in fleet-health-prev.json). CPU time only advances
while the process does work, so a live pid with ~0 delta AND a stale transcript is a wedge.

A pid is **dead only under the fleet's ONE process-identity rule** (#1178). `_alive()` used
to be a bare `os.kill(pid, 0)` — no start-time fence, no zombie exclusion — which was wrong
in BOTH directions, and the directions were MEASURED, not assumed. A pid that a replacement
process had reused, and a ZOMBIE (on which `kill(pid, 0)` also succeeds), read as a LIVING
lane — an empty flag, a FAIL-OPEN that reported a dead lane healthy by silence. The opposite
false `PID DEAD` came from `os.kill` raising for a process that IS alive (`EPERM` on a
foreign-user pid). A failed `ps` read is a shape `_alive()` never had: the promoted path
maps it to `PID ? (unreadable)` — an abstention, never absence (the library's C3 split). The read now goes through
`scripts/lib/pid-identity.sh`, the same library the kill-path reaper sources and the liveness
classifier shells out to. An **unresolvable read ABSTAINS** (`PID ? (...)`) instead of
reporting a death it cannot witness — and an abstention never SUPPRESSES the quiet/CPU
suspect ladder, so an unreadable identity can never turn a stale lane into "no suspects".
"""
import json, os, shutil, subprocess, sys, time, glob

# ── the fleet's ONE process-identity rule (#1178) ────────────────────────
# This module does NOT decide liveness. A Python file cannot source a Bash library, so the
# read goes through the SAME probe boundary the classifier uses:
#     tools/fleet/liveness.py -> scripts/lib/pid-identity.sh probe <pid> <startSeconds>
# Importing the sibling classifier (rather than re-implementing the CLI call) keeps ONE
# rc->status mapping and ONE library-path resolution; a second copy here would recreate
# exactly the two-contracts-for-one-safety-rule defect this replaces.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
try:
    import liveness as _liveness
except Exception:
    # No sibling classifier: abstain rather than guess. NEVER fall back to a bare
    # existence check — that is the defect, not the fallback.
    _liveness = None

# The probe vocabulary (the library's CLI contract). Only `absent` and `zombie` are death
# witnesses; `off-fence` (a live but UNMATCHED incarnation — pid reuse) and `unreadable`
# (a failed read) are ABSTENTIONS.
DEAD_OBSERVED = ("absent", "zombie")
HOLDER_OBSERVED = "holder"


def _observed(pid, start_seconds):
    """The canonical identity read for a lane's recorded incarnation (#1178).

    Returns one of holder | absent | zombie | off-fence | unreadable. EVERY failure — a
    missing sibling classifier, a missing or unrunnable identity library, a failed `ps`,
    an unusable recorded start — returns `unreadable`, which the caller renders as an
    abstention. It must never be collapsed into `absent`: that would manufacture
    "PID DEAD" out of a read that did not happen (#1178 C3).
    """
    if _liveness is None:
        return "unreadable"
    try:
        res = _liveness.probe_pid(pid, start_seconds)
        return _liveness.observed_from_probe(res.rc, res.status)
    except Exception:
        return "unreadable"


STATE = os.path.expanduser("~/.pi/agent/state/fleet-health-prev.json")
HOOK = os.path.expanduser("~/.cmuxterm/pi-hook-sessions.json")
SESS = os.path.expanduser("~/.pi/agent/sessions")
TASK = os.path.expanduser("~/.pi/agent/task-sessions")

LANES = [
    ("B1",  "01a08ca6-3539-71ed-a0d7-7cee52feee03"),
    ("B2c", "01a07161-5816-7a0d-9e2d-a42f769f9da6"),
    ("B3",  "01a093d5-a154-766d-8cdd-1bbdc0a7c033"),
    ("B4",  "01a0a7f1-7783-777e-b3e3-81d47714024b"),
    ("B5",  "01a0a5c9-59ff-7463-8ba8-b297b06fd092"),
    ("B6",  "01a0a05f-21ea-7041-ab73-6af91b651710"),
    ("B7",  "01a093de-2870-7525-988e-c9a8ba78d18d"),
]

# A lane with a stale transcript older than this is worth a screen check.
SUSPECT_AGE = 300      # 5 min
CHILD_SUSPECT_AGE = 600  # 10 min


def walk_records(obj, out):
    """Collect every dict that looks like a session record, whatever the hook file's shape."""
    if isinstance(obj, dict):
        if any(k in obj for k in ("sessionId", "pid", "agentLifecycle", "cwd")):
            out.append(obj)
        for v in obj.values():
            walk_records(v, out)
    elif isinstance(obj, list):
        for v in obj:
            walk_records(v, out)


def load_hook():
    """Read the cmux hook store. Returns (ok, sid-keyed records).

    `ok` is False when the store could not be read, or when records WERE found but none
    carried a session id — a store-shape drift. Either way the lane lookup is unusable,
    so the caller reports the scan INCOMPLETE instead of a clean result: a read that did
    not happen must abstain here exactly as the identity probe does (the same fail-closed
    direction as `PID ? (...)`), or a dead lane is reported healthy by silence.
    """
    recs = []
    ok = True
    try:
        walk_records(json.load(open(HOOK)), recs)
    except Exception as e:
        print(f"  (hook file unreadable: {e})")
        ok = False
    by_sid = {}
    for r in recs:
        sid = r.get("sessionId") or r.get("session_id")
        if sid:
            by_sid.setdefault(sid, {}).update(r)
    if recs and not by_sid:
        print("  (hook store shape drifted: records carry no session id)")
        ok = False
    return ok, by_sid


def cputime_secs(pid):
    try:
        out = subprocess.run(["ps", "-o", "cputime=", "-p", str(pid)],
                             capture_output=True, text=True, timeout=5).stdout.strip()
    except Exception:
        return None
    if not out:
        return None
    parts = out.split(":")
    try:
        parts = [float(p) for p in parts]
    except ValueError:
        return None
    secs = 0.0
    for p in parts:
        secs = secs * 60 + p
    return secs


def find_transcript(sid):
    hits = glob.glob(os.path.join(SESS, "**", f"*{sid}*.jsonl"), recursive=True)
    if not hits:
        return None
    return max(hits, key=os.path.getmtime)


# ── scheduled reapers: a maintainer that fails SILENTLY ───────────────────
# A reaper's whole point is to run unattended, so its exit status is the ONLY thing that can
# tell anyone it stopped working. `launchctl list` reports that status and NOTHING read it:
# the measured estate carried `com.eldato.pi-cache-reap` at exit 5 for days while the caches it
# exists to bound sat at 8745MB/9479MB, `com.tortoise.worktree-reaper` loaded-and-inert, and
# the three cloud cells died of a disk-full at 94-96%. A silent failure IS the bug (the same
# rule as the pr-doctor exit-2 defect), so the scan reports every reaper's last exit.
#
# ⛔ THE EXIT VOCABULARY IS NOT PORTABLE AND MUST NOT BE FLATTENED. Per the scripts' own exit
# contracts: pi-cache-reap.sh 5 = "a cache is OVER its bound and nothing was done (dry-run —
# the shipped stance)" — an ACTIONABLE ALARM, never a crash; 3 = fail-closed (real breakage);
# 4 = did not run (lock held / benign skip). pi-reap-worktrees.sh uses 4 for "a removal FAILED"
# and 3 for "lock held" — the OPPOSITE mapping. So each family gets its own table, and an
# UNRECOGNISED code is reported as an alarm rather than assumed benign (allow-list polarity).
REAPERS = [
    ("com.eldato.disk-reaper",         "disk"),
    ("com.eldato.pi-cache-reap",       "cache"),
    # ⛔ THESE TWO ARE NOT THE CACHE OWNER'S VOCABULARY. pi-reap-idle.sh (and the prune it shares) exit 3
    # for "lock held" as well as for fail-closed, and never emit 4 — so inheriting the cache map printed
    # "fail-closed (real breakage)" and raised an alarm for a routine overlapping pass.
    ("com.eldato.pi-session-reaper",   "idle"),
    ("com.eldato.pi-task-session-prune", "idle"),
    ("com.tortoise.embedded-reaper",   "other"),
    ("com.tortoise.worktree-reaper",   "worktree"),
    ("com.tortoise.branch-reaper",     "other"),
]
# family -> {code: (meaning, alarm?)}
REAPER_CODES = {
    # The consolidated pass (disk-reaper.sh). Its contract is in docs/ops/disk-reaper.md: the UNIT is
    # green for 5 and 6, because those are expected states on a healthy busy cell (#2036) — so the
    # pass RECORD is the alarm channel, and it is read below rather than inferred from this code.
    "disk":     {0: ("ok", False),
                 5: ("informational (dry-run work found, or apply: a class below its floor)", False),
                 6: ("a delegate refused (busy box) — the record carries ok=0", False),
                 3: ("MISCONFIGURED — a delegate missing, no repo to scan, unusable bound", True),
                 4: ("a removal FAILED, or a lock directory that could not be created", True)},
    "idle":     {0: ("ok", False), 3: ("fail-closed OR lock held — see its log", True)},
    "cache":    {0: ("ok", False), 3: ("fail-closed (real breakage)", True),
                 4: ("did not run (lock held)", False),
                 5: ("OVER BOUND and nothing reclaimed — dry-run; arming is the owner's decision (#1678)", True)},
    # ⛔ 3 IS NOT BENIGN HERE. scripts/pi-reap-worktrees.sh's own header lists lock held, git
    # enumeration failed, ps failed or empty, gh unavailable with candidates, and an unwritable log as
    # ALL exiting 3 — only one of them is the lock. disk-reaper.sh deliberately refuses to special-case
    # that family for the same reason, so a worktree reaper that has failed closed for days must alarm.
    "worktree": {0: ("ok", False), 3: ("fail-closed (lock held, or a probe could not answer)", True),
                 4: ("a removal FAILED", True)},
    "other":    {0: ("ok", False)},
}

# The consolidated reaper writes one record per pass. It is the ONLY place that says whether the box
# was actually reaped when the job exits 5 or 6 (both are success to the scheduler); an unreadable or
# absent record is reported as such, and never read as "the pass was fine".
# ⛔ THE SEAM, NOT A HARDCODED PATH. Both artifacts render DISK_REAPER_STATE_DIR into the job's
# environment and both other readers honour it (`disk-reaper.sh --print-status`,
# `cloud-cell-supervisor.sh`); reading ~/.pi/agent/state regardless made fleet-health alarm on a box
# whose state dir is elsewhere while the other two said ok — one record, two verdicts.
def _disk_reaper_status_path():
    base = os.environ.get("DISK_REAPER_STATE_DIR") or os.path.join(
        os.path.expanduser("~"), ".pi", "agent", "state")
    return os.path.join(base, "disk-reaper.status")





def _reaper_is_scheduled():
    """Is a disk-reaper job installed on this box (either platform), or a state dir pinned by env?

    `DISK_REAPER_SCHEDULE_ASSERT` is a TEST SEAM (nothing in production sets it): `0`/`1` pins the
    answer so a suite can prove BOTH branches hermetically. Without it the probe reads the machine it
    runs on, so a test's expectation would depend on whether the CI runner happens to carry a reaper
    unit — the assertion would pass on a dev box and fail on `ubuntu-latest`.
    """
    override = os.environ.get("DISK_REAPER_SCHEDULE_ASSERT")
    if override in ("0", "1"):
        return override == "1"
    if os.environ.get("DISK_REAPER_STATE_DIR"):
        return True
    home = os.path.expanduser("~")
    for p in ("/etc/systemd/system/eldato-disk-reaper.timer",
              os.path.join(home, ".config", "systemd", "user", "eldato-disk-reaper.timer"),
              os.path.join(home, "Library", "LaunchAgents", "com.eldato.disk-reaper.plist")):
        if os.path.exists(p):
            return True
    return False


def disk_reaper_record():
    """Return (detail, alarm) from the pass record. Absence/unreadability/staleness is an alarm."""
    try:
        with open(_disk_reaper_status_path(), encoding="utf-8", errors="replace") as fh:
            kv = dict(ln.split("=", 1) for ln in (x.strip() for x in fh) if "=" in ln)
    except OSError as exc:                                      # noqa: BLE001
        # ⛔ AN ABSENT RECORD IS ONLY AN ALARM WHERE A REAPER IS SUPPOSED TO BE. If the STATE DIR itself
        # does not exist, no pass has ever been configured on this box and alarming would be an alarm that
        # can never be cleared (fleet-health runs on every lane box, including ones with no reaper). A
        # state dir that EXISTS with no record, or a record that exists and cannot be read, is the real
        # signal and still alarms.
        import errno as _errno
        if exc.errno == _errno.ENOENT and not _reaper_is_scheduled():
            # ⛔ NO SCHEDULE, NO ALARM. fleet-health runs on every lane box; most have no reaper on a
            # clock at all, and an alarm that fires where nothing was ever configured is an alarm that
            # can never be cleared — the wallpaper failure this section was written to avoid. A box that
            # DOES carry a schedule and has no record IS an alarm (it was installed and has never once
            # succeeded).
            return ("no pass record yet, and no disk-reaper schedule on this box", False)
        return (f"pass record UNREADABLE at {_disk_reaper_status_path()} ({exc}) — this is NOT 'the pass was fine'",
                True)
    ok = kv.get("ok", "")
    # ⛔ ok=1 IS NOT ENOUGH ON ITS OWN. A job that is loaded but has stopped writing its record keeps
    # whatever `ok` the last pass wrote, so a dead maintainer would read healthy for ever. The pass's
    # own reader applies the staleness bound (`disk-reaper.sh --print-status` ⇒ status=stale, exit 3)
    # and so does cloud-cell-supervisor.sh; fleet-health must not be the one reader that does not.
    # ⛔ AN UNREADABLE SEAM MUST NOT KILL THE SCAN. `int("30m")` raised ValueError and the whole
    # fleet-health run died with a traceback instead of reporting — the opposite of an alarm.
    try:
        stale = int(os.environ.get("DISK_REAPER_STALE_SECONDS", "7200") or 7200)
    except ValueError:
        return (f"DISK_REAPER_STALE_SECONDS={os.environ.get('DISK_REAPER_STALE_SECONDS')!r} is not a whole number — cannot judge staleness", True)
    age = ""
    try:
        epoch = int(kv.get("epoch", ""))
        age = int(time.time()) - epoch
    except (TypeError, ValueError):
        epoch = None
    if epoch is None:
        return (f"record has no readable epoch (rc={kv.get('rc', '?')}) — cannot tell whether this box is still being reaped",
                True)
    # ⛔ THE SAME PREDICATE AS `disk-reaper.sh --print-status`, in ONE form: a FUTURE-dated epoch (age < 0)
    # is as unprovable as an ancient one, and the two readers must not disagree about it (measured:
    # --print-status said stale/rc 3 for `epoch=now+3600` while this said healthy, no alarm).
    if age < 0 or age > stale:
        return (f"record is STALE: last pass {age}s ago (bound {stale}s) — the job is scheduled but is not running",
                True)
    if ok == "1":
        unm = kv.get("freed_mb_unmeasured", "")
        return (f"record ok=1 rc={kv.get('rc', '?')} freed_mb={kv.get('freed_mb', '?')}"
                f"{f' (df could not measure: {unm})' if unm else ''} age={age}s", False)
    # ⛔ A ROUTINE REFUSAL IS NOT A FLEET ALARM. rc 6 (a delegate refused because the box is busy) and
    # rc 5 (a class below its floor, or the lock was held) are the states the runbook tells operators to
    # EXPECT on a healthy busy cell; alarming on them here made every busy cell red at the fleet level
    # and forced nine call sites to swallow the exit status. They are reported IN FULL, without an
    # alarm; rc 3 (MISCONFIGURED), rc 4 (a removal FAILED / no lock dir) and an unreadable record still
    # alarm — those are the ones a human must act on.
    rc_field = kv.get("rc", "?")
    if rc_field in ("5", "6"):
        return (f"record ok=0 rc={rc_field} (expected on a busy cell) detail={kv.get('detail', '?')} age={age}s",
                False)
    return (f"record ok={ok or 'MISSING'} rc={rc_field} detail={kv.get('detail', '?')} age={age}s", True)


def reaper_section():
    """Report the consolidated reaper's PASS RECORD on every host, plus launchd exit statuses on a Mac.

    ⛔ TWO CHANNELS, TWO RULES. The pass record is written on both platforms and is always read; the
    `launchctl` exit table exists only on macOS and reports "not applicable" elsewhere — a section that
    exits 1 on every Linux cell for a table it cannot read is an alarm that can never be cleared
    (measured: fleet-health exited 1 with healthy lanes, printing "CANNOT READ launchctl").
    """
    # ⛔ THE PASS RECORD IS READ ON EVERY HOST, NOT ONLY ON macOS. The consolidated reaper writes it on
    # Linux too, and returning early when `launchctl` is absent meant the record was never read on the
    # cells this feature exists for — a refused or below-floor pass read as nothing at all.
    alarms = []
    print("\ndisk reaper (pass record)")
    rec_detail, rec_alarm = disk_reaper_record()
    print(f"  {rec_detail}")
    if rec_alarm:
        alarms.append(f"disk reaper: {rec_detail}")

    if not shutil.which("launchctl"):
        # Only the launchd EXIT TABLE is inapplicable here; the record above is the real channel.
        print("reapers (launchd, last exit): not applicable on this host (no launchd — Linux cells are scheduled by systemd)")
        return alarms
    try:
        cp = subprocess.run(["launchctl", "list"], capture_output=True, text=True,
                            timeout=20)
    except Exception as exc:                                    # noqa: BLE001
        print(f"\nreapers: CANNOT READ launchctl ({exc}) — this is NOT 'no reapers'")
        return ["reapers: launchctl unreadable (abstention, not absence)"]
    # ⛔ A `launchctl` THAT EXISTS BUT CANNOT ANSWER IS AN ABSTENTION, NOT "NO REAPERS". Without this
    # check a non-zero exit (e.g. `Could not find domain` on a headless box) left `rows` empty, printed
    # every label as NOT INSTALLED and returned NO alarm — the section abstaining silently on a box it
    # could not see, which is the one thing an alarm channel must never do.
    if cp.returncode != 0 or not cp.stdout.startswith("PID"):
        print(f"\nreapers: CANNOT READ launchctl (rc={cp.returncode}) — this is NOT 'no reapers'")
        return [f"reapers: launchctl unreadable (rc={cp.returncode}, abstention not absence)"]
    out = cp.stdout
    rows = {}
    for line in out.splitlines()[1:]:
        f = line.split("\t")
        if len(f) >= 3:
            rows[f[2].strip()] = f[1].strip()          # label -> last exit status
    print("reapers (launchd, last exit)")
    for label, family in REAPERS:
        if label not in rows:
            # ⛔ NOT INSTALLED IS REPORTED, NOT ALARMED. Which launchd jobs a given Mac carries is a
            # per-box fact (a box with no tortoise checkout has none of the com.tortoise ones; several
            # are armed elsewhere by design) — inventing an alarm for each absent label would fire on
            # every run of a healthy Mac and train the reader to ignore the section.
            print(f"  {label:<36} NOT INSTALLED")
            continue
        raw = rows[label]
        code = int(raw) if raw.lstrip("-").isdigit() else None
        if code is None:
            print(f"  {label:<36} exit={raw}  (not a status — run it in the foreground)")
            alarms.append(f"{label}: unreadable exit status {raw!r}")
            continue
        meaning, is_alarm = REAPER_CODES[family].get(
            code, (f"UNRECOGNISED exit {code} — treated as broken", True))
        print(f"  {label:<36} exit={code}  {meaning}")
        if is_alarm:
            alarms.append(f"{label}: {meaning}")
        if family == "disk":
            # ⛔ THE RECORD WAS ALREADY READ ABOVE (it is platform-independent). Reading it again here
            # printed it twice and counted its alarm twice in "N REAPER alarm(s)". The record has already
            # been printed and its alarm appended above, so this branch only prints the LABEL's line —
            # no second read, no second alarm.
            print(f"  {'':<36} (pass record reported above)")
    return alarms


def main():
    now = time.time()
    prev = {}
    if os.path.exists(STATE):
        try:
            prev = json.load(open(STATE))
        except Exception:
            prev = {}
    hook_ok, hook = load_hook()
    snap = {}
    suspects = []

    print(f"fleet health — {time.strftime('%H:%M:%S', time.localtime(now))}\n")
    print(f"{'lane':4} {'pid':>7} {'life':9} {'q':>2} {'ctx-age':>8} {'cpu-delta':>10}  flag")
    print("-" * 62)
    for lane, sid in LANES:
        rec = hook.get(sid, {})
        pid = rec.get("pid")
        life = rec.get("agentLifecycle") or "?"
        depth = rec.get("activePromptDepth")
        tf = find_transcript(sid)
        age = (now - os.path.getmtime(tf)) if tf else None
        cpu = cputime_secs(pid) if pid else None

        p = prev.get(str(pid), {}) if pid else {}
        delta = None
        if cpu is not None and "cpu" in p:
            elapsed = now - p.get("at", now)
            delta = cpu - p["cpu"]
            delta_txt = f"{delta:+.1f}s/{elapsed:.0f}s"
        else:
            delta_txt = "(first)"

        flag = ""
        quiet = ""
        observed = _observed(pid, rec.get("pidStartSeconds")) if pid else None
        if observed in DEAD_OBSERVED:
            # A positively absent/zombie incarnation: the process is gone, so the
            # transcript ladder has nothing left to add.
            flag = "PID DEAD"
        else:
            # An ABSTENTION is NOT a clean bill of health. Name it, and STILL run the
            # quiet/CPU ladder — an unresolvable identity read must never SUPPRESS the
            # suspect signal, or a stale lane reads as "no suspects" precisely when the
            # identity subsystem (or the whole store) is unavailable.
            if observed is not None and observed != HOLDER_OBSERVED:
                flag = "PID ? (%s)" % observed
            if age is not None and age > SUSPECT_AGE:
                if delta is None:
                    quiet = f"** CHECK: quiet {age:.0f}s, no CPU delta yet **"
                elif delta < 0.5:
                    quiet = f"** SUSPECT: quiet {age:.0f}s AND no CPU consumed **"
                elif observed == HOLDER_OBSERVED:
                    quiet = f"quiet {age:.0f}s, CPU +{delta:.1f}s -> working"
                else:
                    # The CPU delta belongs to a pid the identity rule REFUSED to
                    # attribute to this session (reused / unreadable start). Report the
                    # raw evidence, never a "working" verdict — an unmatched pid's CPU is
                    # not admissible positive evidence (mirrors liveness.py, which reads
                    # such a candidate as `unknown`).
                    quiet = f"quiet {age:.0f}s, CPU +{delta:.1f}s (identity unmatched — not attributable)"
                flag = f"{flag} | {quiet}" if flag else quiet
        if quiet.startswith("**"):
            suspects.append((lane, flag))

        age_txt = f"{age:.0f}s" if age is not None else "-"
        print(f"{lane:4} {str(pid):>7} {life[:9]:9} {str(depth):>2} {age_txt:>8} {delta_txt:>10}  {flag}")

    # --- task children -------------------------------------------------
    kids = []
    if os.path.isdir(TASK):
        for d in os.listdir(TASK):
            full = os.path.join(TASK, d)
            try:
                newest = max((os.path.getmtime(os.path.join(full, f))
                              for f in os.listdir(full)), default=None)
            except Exception:
                continue
            if newest:
                kids.append((d, now - newest))
    kids.sort(key=lambda k: k[1])
    active = [k for k in kids if k[1] < 3600]
    print(f"\ntask children (last hour): {len(active)} of {len(kids)} on disk")
    for cid, age in active[:12]:
        flag = "  ** SUSPECT: silent >10 min **" if age > CHILD_SUSPECT_AGE else ""
        print(f"  {cid[:8]}  quiet {age:>6.0f}s{flag}")
        if flag:
            suspects.append((cid[:8], "child silent"))

    with open(STATE, "w") as fh:
        json.dump({str(r.get("pid")): {"cpu": cputime_secs(r.get("pid")), "at": now}
                   for r in hook.values() if r.get("pid")}, fh)

    reaper_alarms = reaper_section()
    if reaper_alarms:
        print(f"\n⚠️  {len(reaper_alarms)} REAPER alarm(s) — a scheduled maintainer is not protecting this box:")
        for a in reaper_alarms:
            print(f"   - {a}")

    print()
    if suspects:
        print(f"⚠️  {len(suspects)} suspect(s) — confirm with cmux read-screen before acting:")
        for name, why in suspects:
            print(f"   - {name}: {why}")
    elif hook_ok:
        print("✅ no suspects")
    if not hook_ok:
        # The lane lookup was unusable, so the rows above are NOT a verdict about the
        # lanes they name — hence the non-zero exit and the explicit marker. But this
        # branch runs AFTER the enumeration on purpose: a failed store read must not
        # SUPPRESS a suspect the ladder did find, which is the same defect one level up
        # from where the identity abstention was fixed.
        print("⚠️  hook store unreadable or shape-drifted — scan INCOMPLETE (lane identity not established)")
        return 1
    if reaper_alarms:
        # A reaper alarm does not make the LANE rows wrong, so it is reported after them — but it
        # must still be a non-zero exit, or a scheduler calling this script cannot see it either.
        return 1


if __name__ == "__main__":
    sys.exit(main())
