#!/usr/bin/env bash
# spawn-gate.sh — the harness's load gate, the ONE `pi` invocation of the ported callers, and
# (since agent-infra#1884) the EXECUTABLE `pi` that gates the spawn point itself.
#
# SOURCED by the two worker launch paths this port routes through it: `lane.sh` and `fix-one.sh`
# (`adopt-fix.sh` reaches it by calling fix-one.sh) — and ALSO EXECUTED as `pi`, installed at
# `$HOME/.pi/agent/bin/pi`, which is first on PATH on both surfaces. See "THE SPAWN POINT" at the
# end of this file: that mode is what makes the gate independent of the caller's cooperation, and
# it is one artifact on purpose — an installed copy cannot drift from the primitives below.
#
# ⛔ WHAT THIS FILE DOES NOT YET COVER — the header must not imply otherwise, because a comment
# claiming a guard that does not exist reads exactly like one that does. The SPAWN-POINT mode at the
# end of this file closes #1884's hole for every caller that resolves `pi` through PATH; these are
# the residues it does NOT reach, each named where it is decided. On the current tree:
#   * `merge-one.sh` still carries its OWN copy of `run_agent()` with NO gate of its own. That is the
#     `chain-<N>` first-review path for every own-lane PR — and the one path the controller
#     deliberately stands down for, because the chain holds the claim — plus fix-one.sh's
#     re-review. The LOAD gate now reaches it anyway, at the spawn point (that is what #1884 bought);
#     what it lacks is the DISK gate, so a reviewer can still be started onto a full worktree volume. #1769 MERGED on 2026-10-16 without closing it; it is held by the still-open
#     #1730 / #1812, so it is BLOCKED, not declined — and it is UNGATED today, which means the disk
#     gate below does NOT reach it.
#   * `orch-loop.sh` does NOT source this file: it defines its own `is_num`/`is_limit`/`can_spawn`
#     and gates its four DECISION sites with them. Folding those into this file is a separate
#     change with its own review.
#   * `install.sh` renders MAX_LOAD into the plist; it does not source this file.
#   ⇒ in THIS DIRECTORY the shipped `pi -p` invokers are exactly {merge-one.sh, spawn-gate.sh}, and
#     while `scripts/` as a whole also contains {cloud-cell-bringup.sh, retired/refix.sh,
#     retired/watch-one.sh}. spawn-gate.test.sh asserts BOTH sets as EQUALITIES — a fourth launch
#     path added tomorrow fails that suite loudly instead of drifting in ungated — because a
#     directory-scoped census silently says nothing about the tree outside it. (cloud-cell-bringup.sh
#     is a 120 s provider reachability probe, not a lane dispatch, and is NOT load-gated: a named,
#     asserted residual.)
#
# Why this file exists (agent-infra#1720): the gate used to be a one-liner inside orch-loop.sh plus
# a copy-pasted `run_agent()` in three workers, and only the controller's decision sites consulted
# it — the `pi` calls themselves carried no gate at all. So `chain-<N>` (the primary first-review
# path for every own-lane PR, and the one path the controller deliberately stands down for because
# the chain holds the claim), `fix-one.sh` and `adopt-fix.sh` launched their agent onto whatever
# load existed when they got there: a lane dispatched on a quiet box opened its PR up to 90 minutes
# later and its reviewer landed on the spike the gate was written to prevent. README §4 states that
# gap precisely, and names all three paths; it is the document of record for the residual.
#
# ⛔ THIS PORT IS A MERGE, NOT A COPY. The tortoise original of this file (#8521) carries only the
# gate; the agent-infra copies of `run_agent` had meanwhile gained the #1709 wall-clock telemetry
# (the `elapsed=` field and the durable `walltime.tsv` time series). Adopting the tortoise file
# verbatim would have DELETED that measurement from three shipped scripts, so run_agent() here is
# the canonical one plus the gate. A port that silently regresses the receiving tree is not a port.
set -u

# `is_num` is shared by every numeric coercion below AND by orch-loop.sh's own coercions (which are
# a SEPARATE copy: orch-loop.sh does NOT source this file — see the header). It lives here because the
# ceiling is derived at SOURCE time, below, and a guard that runs after the arithmetic it protects is
# not a guard (#1702).
#
# ⛔ LEADING ZEROS ARE REJECTED — but NOT for the reason an earlier version of this comment gave
# (corrected, review round 2026-10-15). `[ 5 -lt 08 ]` does **not** error: `[`'s numeric comparison
# parses DECIMAL (measured rc=0 on this tree's /bin/bash 3.2.57), so a leading-zero MAX_LOAD would
# compare correctly HERE. The zeros are rejected because the predicate is SHARED: the same `is_num`
# guards bare `$(( ))` sites — fix-one.sh's `FIX_LEASE=$(( FIX_TIMEOUT + 1200 ))`, merge-one.sh's
# review lease — where `$(( ))` DOES parse base 0, `08` is an invalid octal, and on bash 3.2 the
# failed arithmetic ABORTS the enclosing block with status 0 (measured: `if true; then x=$(( 08 ));
# echo REACHED; fi` never prints REACHED), silently disabling a cross-box claim. One predicate, one
# shape: a caller's later redefinition cannot loosen this file's coercion.
is_num() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; 0) return 0 ;; 0*) return 1 ;; *) return 0 ;; esac; }

# ── the ceiling ──────────────────────────────────────────────────────────────────
# Resolved HERE rather than in the caller so a worker started by hand — or by a tmux server whose
# environment predates the plist — still has a live ceiling: the launchd plist supplies MAX_LOAD to
# the daemon, but nothing guarantees it reached the tmux server that starts the workers. The value is
# derived the same way install.sh derives it for the plist (install.sh does not source this file; it
# renders the expression), so the ceiling the gate applies and the ceiling the daemon advertises are
# intended to agree — spawn-gate.test.sh pins the ARITHMETIC this file applies, not install.sh.
#
# The core count is derived PORTABLY. `sysctl -n hw.ncpu` is macOS-only: on a Linux cell sysctl may
# be absent entirely (Debian's procps does not ship it any more) and `hw.ncpu` is a macOS key
# regardless, so the old `|| echo 4` silently pinned _NCPU=4 and MAX_LOAD=40 for EVERY cell (#1702).
_NCPU="$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"
# `is_limit` = is_num AND at most 9 digits. It must NOT reject 0: install.sh validates plist limits
# through it, where 0 is legal, and `MAX_LOAD=0` deliberately means "spawn nothing" (`[ 0 -lt 0 ]`
# is false).
is_limit() { is_num "${1:-}" && [ "${#1}" -le 9 ]; }
# ⛔ `_NCPU` IS GUARDED BY `is_limit`, NOT `is_num`, AND THE REASON IS A WRAP — not a bad comparison
# (P1, review round 2026-10-15). A 19-digit-but-below-2^63 probe does NOT error anywhere: it reaches
# `$(( 10#$_NCPU * 10 ))`, WRAPS, and yields a small, plausible ceiling that every later guard then
# ACCEPTS. Measured before this fix: a probe of 1844674407470955161 gave MAX_LOAD=999999994 on a
# 10-core box — the gate is INERT and every worker launches onto a saturated machine, silently. The
# other wrap direction is the permanent stop: 2^63 wraps to 0, `is_limit 0` is true, and
# `[ "$l" -lt 0 ]` is always false, so the gate CLOSES and the box dispatches nothing, for ever.
# orch-loop.sh:83 and install.sh:45 guard the SAME derivative with `is_limit` for exactly this, and
# README §7.1 records the wrap as already corrected on canonical — so `is_num` here would REGRESS a
# canonical hardening.
# ⛔ THE COMPARISON ITSELF DOES NOT FAIL OPEN — the opposite. `can_spawn` returns `[ -lt ]`'s status
# and every caller tests `if ! can_spawn …`, so an ERRORED comparison is non-zero, `!` makes the
# branch TRUE, and the spawn is REFUSED. Measured: `can_spawn 5` with `MAX_LOAD=abc` returns 2 and
# the caller refuses. So the coercion below defends against the WRAP, the 0-valued probe and the
# 19-digit ceiling — NOT against an open gate, which this shape cannot produce. A reader who takes
# the older rationale ("`[` on a non-number is FALSE and FALSE allows dispatch") at face value will
# mis-reason about which tamper this defends; it is wrong for this one-comparison polarity.
is_limit "${_NCPU:-}"   || _NCPU=4
# A 0-VALUED PROBE IS A FAILED PROBE, NOT "NO CORES": `10 * 0` is 0, `is_limit 0` is true, and
# `[ "$l" -lt 0 ]` is always false — so a 0 probe passes every guard and CLOSES the gate for ever.
# orch-loop.sh:85 and install.sh:47 carry the identical line.
[ "${_NCPU:-0}" -ge 1 ] || _NCPU=4
# `10#` forces base 10 so a value with a leading zero is not re-read as octal.
MAX_LOAD="${MAX_LOAD:-$(( 10#$_NCPU * 10 ))}"
# ⛔ THE FALLBACK MUST BE A TRUE DEFAULT, NOT A RE-DERIVATION. A magnitude guard that falls back to
# `_NCPU * 10` is a NO-OP in the case it exists for: an out-of-range value that came FROM the core
# probe re-derives to the same garbage. The first guard repairs a 10-digit MAX_LOAD derived from a
# 9-digit `_NCPU`; only the literal 40 is genuinely out of range, so it is the final fallback.
is_limit "${MAX_LOAD:-}" || MAX_LOAD=$(( 10#$_NCPU * 10 ))
is_limit "${MAX_LOAD:-}" || MAX_LOAD=40

# ── the disk gate (agent-infra#1765) ─────────────────────────────────────────────
# A cell whose filesystem fills is not a warning, and it is not self-correcting: MEASURED twice on
# pi-lane-1 — 2026-10-15 (`/dev/root 32G, 30G used, 0 avail`; every git op failed, even
# `echo x > /tmp/f` returned `I/O error: No space left on device`) and again 2026-10-16 05:13Z, when
# the controller died writing its own log (`orch-loop.sh: echo: write error: No space left on
# device`). The controller never saw either coming, because its resource probe was macOS-only and
# printed `disk(?)` at 100% used (#1765).
#
# This is the DISPATCH-PATH half of that fix, and it lives here rather than in orch-loop.sh because
# this file is the ONE agent invocation the ported callers use: `pi` has no internal disk limit, so
# the only place the consumption can still be stopped is immediately BEFORE the spawn. Refusing here
# costs a re-dispatch; not refusing costs the venv half-built (`uv sync` dying on `os error 28`), or
# a review that dies mid-write — burning a lease and a MAX_FIX_TRIES attempt for an agent that could
# never have finished.
#
# ⛔ THE POLARITY IS MIXED ON PURPOSE, it is not the load gate's, and it DIVERGES from the tree's
# other disk floor. `cloud-cell-supervisor.sh`'s `cmd_check_disk` fails CLOSED on an unreadable `df`
# ("cannot-verify is never a pass") because it is a PRE-START check: refusing to start a cell costs
# nothing. This gate runs in a LIVE dispatch path, where failing closed on an unreadable probe would
# stop every lane on the box for ever — so an UNREADABLE reading fails OPEN, matching the posture
# #1702 documents for the load and swap probes, and a READABLE reading below the floor fails CLOSED.
# The divergence is deliberate and stated, not an accident; the unreadable case is also logged LOUDLY
# (see run_agent) so a misconfigured probe is visible rather than silently permissive.
#
# The reading is MEBIBYTES, and the probe is POSIX. `df -g /System/Volumes/Data` is macOS-only in
# both its flag and its path — its empty result on Linux is literally how this stayed invisible.
# Scope of the guards below: they repair a DEFAULT or an out-of-range value at SOURCE time. They are
# not a defence against an operator who deliberately exports DISK_MIN_FREE_MB=1 (a legal, tiny floor)
# or who re-assigns the variable AFTER sourcing this file; they defend the shipped callers, which set
# neither.
# ⛔ THE DEFAULT IS 500 ON PURPOSE: IT IS `cloud-cell-supervisor.sh`'s `MIN_FREE_MB`, AND ANY HIGHER
# VALUE HERE IS A FALSE PASS RATHER THAN A SAFER GATE (review round 1, P1). That file's `cmd_check`
# answers "can this cell run a controller?" against its own 500MB floor, so a floor above it opens a
# band where `check` prints `CELL CAN RUN A CONTROLLER` while every lane spawn is refused 77 — an
# instrument reporting healthy about a cell that can do no work, which is the same false-PASS shape
# as this file's own unreadable-`df` divergence. The alternative place to close it is that file's
# floor, and that is the stronger place; it is held by concurrent lanes, so the DEFAULT is aligned
# here instead. A deployment wanting a higher dispatch floor sets DISK_MIN_FREE_MB explicitly, and
# then the two differ BY DECLARATION instead of by accident. ⚠️ THE BAND IS CLOSED IN BOTH DIRECTIONS
# FOR THE DEFAULTS ONLY (review round, P3): `MIN_FREE_MB` is itself a documented tunable, so setting
# it LOWER than this floor re-opens the band from the other side (supervisor 100 / gate 500 → `check`
# healthy, spawns refused 77). The durable fix is to bind the gate to `MIN_FREE_MB` when
# `DISK_MIN_FREE_MB` is unset — or to have `cloud-cell-supervisor.sh` refuse a floor below this one —
# and both of those touch a file held by concurrent lanes, so it is recorded as a residual rather than
# settled here. `spawn-gate.test.sh` pins the EQUALITY of the DEFAULTS against that file's own line, so
# raising one of the two alone reddens it.
DISK_MIN_FREE_MB="${DISK_MIN_FREE_MB:-500}"
is_limit "${DISK_MIN_FREE_MB:-}" || DISK_MIN_FREE_MB=500
# A 0 floor would make `[ "$mb" -ge 0 ]` true for every reading — a gate that can never refuse,
# i.e. the no-op gate this whole file is written against. Same shape as the `_NCPU` zero guard above.
[ "${DISK_MIN_FREE_MB:-0}" -ge 1 ] || DISK_MIN_FREE_MB=500
# ⛔ AND THE FLOOR MUST LEAVE THE BAND HEADROOM (review round 2, P2). `is_limit` accepts 9 digits, so
# it accepts `DISK_MIN_FREE_MB=999999999` — but the band is 4x the floor, and 4 x 999999999 is
# 3999999996: TEN digits, i.e. OUT OF RANGE by the very predicate that guards a PROVIDED warn. Every
# later guard ACCEPTS it (it is `> floor`), so the "repairs an out-of-range value at SOURCE time"
# claim above would be false, and the band would sit above every real device — `disk_low` then returns
# true on EVERY spawn, turning the "a device that fills SILENTLY is the defect" warning into a
# constant, ignorable one. The failure mode is the same as the MAX_LOAD rule below — "the fallback
# must be a true default, NOT a re-derivation": a floor whose derived band cannot be expressed in
# this file's own range is out of range FOR THIS FILE'S PURPOSE and is repaired as one. The widest
# floor that still admits an in-range band is 249999999 (4x it is 999999996).
[ "${DISK_MIN_FREE_MB:-0}" -le 249999999 ] || DISK_MIN_FREE_MB=500
# The WARNING BAND — a device that fills SILENTLY is the defect, so the cell says so while it can
# still act. 4x the floor is `cloud-cell-supervisor.sh`'s `check` warning band; that file's
# UNATTENDED prune trigger is narrower (2x, `cmd_start`), and the two are not interchangeable.
DISK_WARN_FREE_MB="${DISK_WARN_FREE_MB:-$(( 10#$DISK_MIN_FREE_MB * 4 ))}"
is_limit "${DISK_WARN_FREE_MB:-}" || DISK_WARN_FREE_MB=$(( 10#$DISK_MIN_FREE_MB * 4 ))
# ⛔ THE BAND MUST BE NON-EMPTY, AND `>= floor` IS NOT ENOUGH (review round 1, P1). The refusal fires
# on `mb < floor` and the warning on `mb < warn`, so `warn == floor` leaves the interval
# [floor, warn) EMPTY: the warn can never fire, and a repair intended to guarantee a warning would
# ship exactly "no warning" — the failure it exists to prevent. The band must be strictly above the
# floor, so an out-of-range value is doubled rather than clamped to the floor.
[ "${DISK_WARN_FREE_MB:-0}" -gt "$DISK_MIN_FREE_MB" ] || DISK_WARN_FREE_MB=$(( 10#$DISK_MIN_FREE_MB * 2 ))

# Free MEBIBYTES on the filesystem holding <path>, or EMPTY when the probe cannot answer.
# The path is the ARGUMENT because the volume that fills is the one the checkout lives on, not a
# hardcoded label (#1765). `df -Pk` is POSIX and its 4th column is 1KiB blocks on both platforms, so
# the conversion is `/1024` — and the column is VALIDATED (`$4 ~ /^[0-9]+$/`) rather than trusted: a
# locale- or column-shifted `df` would otherwise hand back a string that `[ -lt ]` errors on, and an
# errored comparison is not a measurement.
# ⛔ `printf "%d"`, NEVER `print int(...)` (review round 1, P2). `int()` renders through awk's OFMT,
# so on mawk — the default `awk` on Debian/Ubuntu, i.e. ON THE CELL — an integral value at or above
# 2^31 prints in SCIENTIFIC notation (`2.14748e+09`). That is not a number to any consumer here:
# `[ -lt ]` errors on it, `disk_ok` reads the error as "garbage" and ALLOWS, so the gate fails OPEN
# on a full-enough disk — the exact silent-permissive class this change exists to remove. Unreachable
# on today's disks (needs 2 PiB free), and precisely the kind of thing that is only ever found late.
# `orch-loop.sh`'s sibling probe already uses `printf "%d"`; this is the pair being made to match.
disk_free_mb() { # disk_free_mb <path>
  df -Pk "${1:-.}" 2>/dev/null | awk 'NR==2 && $4 ~ /^[0-9]+$/ {printf "%d\n", $4 / 1024}'
}

# disk_readable <free-mb> — the ONE definition of "we actually got a number", shared by the three
# consumers below. It is `case`-shaped rather than `is_num`-shaped ON PURPOSE (review round, P3):
# `is_num` deliberately REJECTS a leading zero, because its other callers feed `$(( ))` where `08` is
# an invalid octal — but the comparison here parses `0100` as 100 without error. Using `is_num` for the
# announcement while the predicates used `case` made ONE reading "unreadable" to the WARN and "100MB"
# to the verdict the WARN is announcing, and it was a fail-OPEN: measured through the shipped
# run_agent, a `0100` reading at floor 500 REFUSED (77) under the `case` form and ALLOWED under the
# `is_num` form. Unreachable from the shipped probe (`printf "%d"` never emits a leading zero) and
# exactly the kind of divergence this file's "ONE predicate" rule exists to stop.
# ⚠️ STATED LIMIT, DELIBERATELY LEFT AS ONE (review round, P3): an ALL-DIGIT reading whose VALUE is
# too large for bash's numeric comparison is READABLE to this reader, but makes that comparison ERROR
# (rc=2), which `disk_ok`/`disk_low` return as non-zero — so such a reading is REFUSED (fail-CLOSED,
# no agent starts) WITHOUT the "could not read free space" warning. The boundary is the COMPARISON's
# own integer range, NOT a digit count: a long all-digit reading below that boundary compares fine and
# is allowed. (An earlier version of this note stated a digit count and a MiB threshold; both numbers
# were wrong, and they are deleted rather than re-worded — this file's own guard above already draws
# the digit-vs-range distinction, so the note does not need to restate it.) Narrowing this reader to
# reject the class would reclassify it as UNREADABLE = WARN + ALLOW: a real fail-open traded for one
# missing log line. Unreachable from the shipped probe, whose reading is a digit-validated `df` column
# divided by 1024.
disk_readable() { # disk_readable <free-mb>
  case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac
}

# disk_ok <free-mb> — the ONE disk predicate, and the gate's polarity in one place.
# An empty or NON-NUMERIC reading is unreadable, not zero: it returns ALLOWED (the documented
# fail-open). A readable reading is compared against the floor.
disk_ok() { # disk_ok <free-mb>
  local mb="${1:-}"
  disk_readable "$mb" || return 0
  [ "$mb" -ge "$DISK_MIN_FREE_MB" ]
}

# disk_low <free-mb> — inside the warning band (and therefore still ALLOWED). Same unreadable
# polarity as disk_ok: a reading we cannot take is not evidence that the disk is low.
disk_low() { # disk_low <free-mb>
  local mb="${1:-}"
  disk_readable "$mb" || return 1
  [ "$mb" -lt "$DISK_WARN_FREE_MB" ]
}

# 1-min load average, integer. Empty when the probe fails (see can_spawn).
# THE FIELD DIFFERS: /proc field 1 IS the 1-min load, while macOS `sysctl vm.loadavg` prints
# `{ 1.70 1.90 2.00 }`, so field 2 is. One shared awk would therefore read the wrong field on one of
# the two platforms — the bug this function's test pins. The argument is a TEST SEAM (the call site
# passes nothing), the same idiom as orch-loop.sh's mp_reason().
load1() { # [<loadavg-file>]
  local p="${1:-/proc/loadavg}"
  if [ -r "$p" ]; then
    awk '{printf "%d\n", $1}' "$p" 2>/dev/null
  else
    sysctl -n vm.loadavg 2>/dev/null | awk '{print int($2)}'
  fi
}

# can_spawn <load> — the ONE load gate.
#
# The reading is an ARGUMENT, never a global: merge-one.sh and fix-one.sh already use `L` for their
# LOG PATH, so a gate that read a global `$L` would compare "/Users/…/logs/merge-42" against
# MAX_LOAD — a class of mistake the old shape invited and this one cannot express.
#
# Two callers, two readings, one predicate:
#   * orch-loop.sh's four decision sites pass the reading they cached for the cycle, so the `[cap]`
#     log line and the gate always report the same load;
#   * run_agent() below takes a FRESH reading immediately before it starts the agent — that is the
#     point, since a chain-<N> worker may have waited 90 minutes for its PR first.
#
# An empty reading is treated as 0 = allowed. That is the shipped, documented fail-open: if the
# load probe itself fails, the box must not stop merging entirely. It is NOT a licence to call this
# with no argument — spawn-gate.test.sh pins that the ported callers pass their reading rather than
# a global, and pins that the empty/no-argument case is ALLOWED (the fail-open is a decision, so it
# is asserted rather than left to be rediscovered).
can_spawn() { [ "${1:-0}" -lt "$MAX_LOAD" ]; }

# ── the CAP-KILL WORKTREE SNAPSHOT (agent-infra#2045) ───────────────────────────
# THE DEFECT, measured 2026-10-18. Of eight background lanes, three produced nothing at all and one
# of them died MID-WORK: 269,237 characters of transcript, seven MODIFIED files in its worktree,
# no report file, no `.rc`, and the launcher reported `worker finished: … commits=0 PR=none`. The
# work survived only because a human happened to notice a dirty temp worktree. Nothing in the
# harness could tell that lane from one that legitimately had nothing to do — the watchdog's whole
# vocabulary was `kill -TERM; sleep 15; kill -KILL`, and a killed lane's log looks exactly like a
# slow lane's (a SIGTERM mid-turn loses the buffered response).
#
# So when the cap fires, the SPAWN POINT writes a VERIFIED, replayable snapshot of the worktree and
# says so in the log, in a ledger row and in a marker the caller reads. The spawn point is the right
# place and the only one: `run_agent` is the single agent invocation every worker (lane.sh,
# fix-one.sh, nonblocking-dispatch.sh) goes through — a per-caller copy would be exactly the drift
# the #1720 port removed.
#
# WHY THE PARENT AND NOT THE WATCHDOG SUBSHELL. This runs AFTER `wait "$pid"` returns, so the WORKER
# is gone — the case this leg exists for — and it cannot be truncated by the parent's own `kill "$w"`
# (the parent reaps the watchdog the moment the worker exits, so a snapshot in flight inside the
# watchdog would be cut off in the common case: the worker exits on SIGTERM, the parent reaps w, the
# patch stops mid-write).
# ⛔ IT IS NOT A RACE-FREE READ, AND SAYING SO WOULD BE WRONG. `wait` reaps the DIRECT child; a `pi`
# that left orphaned descendants (they are not a killed process group) can still be writing while
# `status`/`diff`/`tar` run, so a capture can be TORN even when it verifies as COMPLETE. That is a
# declared residual, not an assumption — the alternative (a process-group kill before capturing) is a
# change in what the cap kills, which is a different decision. The snapshot is a rescue artifact for a
# worktree that is otherwise unrecoverable; it is not a transaction.
#
# ⛔ WHAT THIS MUST NOT DO. (1) It must not CHANGE what the worker had staged, or its branch, or its
# stash. The reads are `git status`, `git diff HEAD`, `git ls-files --others`, `git apply --numstat`
# (which only PARSES) and `tar`, and none of them rewrites the index — with ONE caveat that has to be
# stated because it is not free: `git status` refreshes the stat cache and takes `.git/index.lock`
# unless told not to, so the read carries `--no-optional-locks`. Without it, a snapshot on a worktree
# with a surviving orphaned writer (declared residual (c)) could make that writer's next git command
# fail on a lock the rescue took (review finding, measured: the index mtime moves on a plain
# `git status` and not on `--no-optional-locks`). Staged CONTENT is identical either way; the flag is
# there so the rescue cannot interpose a lock on somebody else's process. (2) It must not delay the
# HARD KILL: the snapshot is taken after the kill has already landed, never in front of it, so a
# worker that ignores SIGTERM is still killed at its cap — this suite pins that, because a
# checkpoint grace period in front of the kill is the "a hung worker is never killed" failure the
# cap exists to prevent.
# (3) It must not claim a save it did not verify: the patch is re-parsed (`git apply --numstat`) and
# the archive is re-listed before anything is called COMPLETE.
#
# DECLARED RESIDUALS, stated rather than implied. (a) A GITIGNORED file is never captured — the
# artifact contract is "tracked changes + untracked non-ignored files", and a build output or a local
# secret is deliberately out of it, so a dirty-looking tree whose only changes are ignored reads
# COMPLETE (and correctly so under that contract). (b) A lane killed BELOW its cap (a `pi` crash, the
# stale-worker reaper) leaves no snapshot: this leg hangs off the cap, which is the loss the issue
# measured. (c) Orphaned descendants may still be writing during the capture (see below). (d)
# `merge-one.sh` carries its own `run_agent()` copy — see the note at the end of this block.
#
# ⛔ AND IT IS LOUD WHEN THERE IS NOTHING TO SAVE. `the worktree was CLEAN` and `the work was
# preserved` are DIFFERENT FACTS, and their being indistinguishable IS the defect: both used to
# read as `commits=0`. Both get a `[cap]` line; only the first is quiet about artifacts.
#
# DECLARED RESIDUAL: `merge-one.sh` still carries its own `run_agent()` copy and therefore its own
# cap path without this snapshot. That is deliberate, not an oversight — its agent is a REVIEWER,
# which lands its result as a comment + a signed record and never leaves uncommitted worktree work,
# so the loss class here does not apply to it. Uniting the two copies is a separate refactor; do not
# read this as coverage of it.
WIP_SNAPSHOT_KEEP=10   # newest N snapshot directories kept. Bounded ON PURPOSE: a cell's disk is
                       # the first thing that stops dispatch, and nothing else reaps this tree.
WIP_SNAPSHOT_DIR=""    # set by cap_wip_snapshot(); the caller (a launcher) publishes it
WIP_SNAPSHOT_RESULT=""
AGENT_CAP_HIT=0        # like AGENT_STARTED: a callers' signal, never an inference from an exit code

# cap_wip_record <label> <cap> <elapsed> <rc> <result> <dir> — ONE append-only row per cap kill.
# ⛔ ON EVERY RETURN PATH, INCLUDING THE ONES THAT WRITE NO DIRECTORY (review finding, P2). The row
# used to be written only on the fall-through path, so a CLEAN cap kill, a `LOST` snapshot (the
# full-disk case) and an `UNSNAPSHOTABLE` one (a mis-pointed WIP_PATH) left NO ledger trace — and a
# later session reading only `state/capwip.tsv` could not tell "cap kill, nothing lost" from "no cap
# kill", which is the absence-reads-as-fine defect this leg exists to remove.
cap_wip_record() { # cap_wip_record <label> <cap> <elapsed> <rc> <result> <dir>
  local o_root="${O:-${HOME:-$PWD}/orchestrator}"
  mkdir -p "$o_root/state" 2>/dev/null || true
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$1" "$2" "$3" "$4" "$5" "$6" \
    >> "$o_root/state/capwip.tsv" 2>/dev/null
}

# cap_wip_prune <snapshot-root> — keep the newest WIP_SNAPSHOT_KEEP directories. Only names THIS
# leg creates (`capwip-*`) are candidates, and a directory is the only thing removed.
cap_wip_prune() {
  local root="${1:-}" d n=0
  [ -n "$root" ] || return 0
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    # ⛔ CONTAINMENT IS CHECKED ON THE FULL PATH, NOT THE BASENAME (review finding, P2 — reproduced).
    # The list is consumed LINE BY LINE, so a directory whose name contains a NEWLINE arrives as two
    # fragments: the first matches the prefix but is not a directory, and the second (`capwip-victim`)
    # was resolved RELATIVE TO THE CALLER'S CWD because a basename test cannot see that it is not under
    # `$root` — measured: `rm -rf` escaped and deleted an unrelated `capwip-victim` directory in the
    # worker's cwd. This is the only destructive primitive in the leg, so it refuses anything that is
    # not literally `$root/capwip-*`.
    case "$d" in
      "$root"/capwip-*) : ;;
      *) continue ;;
    esac
    # ⛔ COUNT ONLY WHAT WE WOULD REMOVE. A `capwip-*` FILE (a stray, a mis-typed name) is neither a
    # snapshot nor a candidate: counting it burned a keep slot and deleted one extra LIVE snapshot
    # (VGATE cycle 3, reproduced: 12 dirs + 1 stray file → kept=9). The directory test therefore runs
    # BEFORE the budget, not after it.
    [ -d "$d" ] || continue
    n=$((n + 1))
    [ "$n" -le "$WIP_SNAPSHOT_KEEP" ] && continue
    rm -rf -- "$d"
  done <<<"$(ls -1dt "$root"/capwip-* 2>/dev/null)"
}

# cap_wip_snapshot <label> <cap-s> <elapsed-s> <rc> <logfile>
# Returns 0 when nothing was lost or the work was fully captured, 1 when something could NOT be
# captured (or there was no git worktree to read).
# ⛔ WIP_SNAPSHOT_RESULT IS THE VERDICT AND IS SET BY EVERY BRANCH — `COMPLETE`, `PARTIAL`,
# `NOTHING-LOST` (a clean tree), `LOST` (a dirty tree that could not be written) or
# `UNSNAPSHOTABLE` (not a git worktree). An EMPTY value is not a verdict: a launcher that reads
# "no directory" as "nothing to save" reports `the worktree was CLEAN, nothing was lost` over work
# that was in fact still only on disk — which is #2045's own defect one layer up (VGATE cycle 3).
cap_wip_snapshot() {
  local label="$1" cap="$2" elapsed="$3" rc="$4" log="$5"
  local root O_ROOT dir stamp result st_outf st_errf dirtyf capf st_nl
  local st_rc=0 st_noise=0 st_ok=1 n_dirty=0 unmerged=0 sub_dirty=0
  local want_tracked=0 have_tracked=0 want_untracked=0 patch_bytes=0 arch_bytes=0 arch_n=0
  local patch_ok=0 arch_ok=0 diff_rc=0 uncovered="" uncovered_n=0 cmp_ok=1 count_ok=1 leading_dash=0
  root="${WIP_PATH:-$PWD}"
  if ! git -C "$root" rev-parse --git-dir >/dev/null 2>&1; then
    WIP_SNAPSHOT_RESULT=UNSNAPSHOTABLE
    cap_wip_record "$label" "$cap" "$elapsed" "$rc" UNSNAPSHOTABLE ""
    echo "[cap] $label hit the ${cap}s cap (elapsed=${elapsed}s rc=$rc) and $root is NOT a git worktree — there was no worktree to snapshot. If this lane's work lives in another directory, pass WIP_PATH=<worktree>" >> "$log"
    return 1
  fi
  # ── ONE read of the worktree state, and it must be able to FAIL ──────────────────────────────
  # ⛔ A `git status` THAT CANNOT RUN IS CANNOT-VERIFY, NEVER "CLEAN" (VGATE cycle 6, and the repo's
  # own ruling for this exact call: cloud-cell-supervisor.sh's `stamp_write` — "a `git status` that
  # cannot run (corrupt index, ENOSPC, EACCES, safe.directory) is CANNOT-VERIFY, never clean"). The
  # first version discarded BOTH the exit status and stderr, and two measured shapes then took the
  # CLEAN branch while real work sat uncommitted: an unreadable `.git/index` (status exits 128 with
  # empty stdout) and an unreadable UNTRACKED DIRECTORY (status exits 0 with only a
  # `warning: could not open directory` and empty stdout). Both reported NOTHING-LOST — the
  # reassuring verdict that authorises a reaper.
  # ⛔ `--porcelain=v2 -z` FOR THREE REASONS. (i) v2 reports each SUBMODULE's own state in its
  # `<c><m><u>` field (`S.M.` = modified content, `S..U` = untracked content) and is non-fatal on a
  # gitlink with no `.gitmodules` mapping, where `git submodule status` is FATAL — the previous probe
  # was built on that call and was INERT (measured: ` c1fec47 sub (heads/main)` for a submodule holding
  # uncommitted work). (ii) `-z` makes the path fields unambiguous for names containing spaces, which
  # the line-oriented porcelain answers cannot. (iii) `-uall` DEFEATS `status.showUntrackedFiles=no`
  # — a legal repo/global config under which untracked work is invisible, so this read returned
  # "clean" and the whole leg was disabled in the reassuring direction (VGATE cycle 8). One read now
  # answers "is anything dirty", "is anything unmerged", "is a submodule holding work" and "WHICH
  # paths", so the four can never disagree.
  st_outf="$(mktemp "${TMPDIR:-/tmp}/capwip-st.XXXXXX" 2>/dev/null)"
  st_errf="$(mktemp "${TMPDIR:-/tmp}/capwip-se.XXXXXX" 2>/dev/null)"
  dirtyf="$(mktemp "${TMPDIR:-/tmp}/capwip-df.XXXXXX" 2>/dev/null)"
  st_nl="$(mktemp "${TMPDIR:-/tmp}/capwip-nl.XXXXXX" 2>/dev/null)"
  capf="$(mktemp "${TMPDIR:-/tmp}/capwip-cf.XXXXXX" 2>/dev/null)"
  if [ -n "$st_outf" ] && [ -n "$st_errf" ] && [ -n "$dirtyf" ] && [ -n "$capf" ] && [ -n "$st_nl" ]; then
    git -C "$root" --no-optional-locks status --porcelain=v2 -z --ignore-submodules=none -uall > "$st_outf" 2> "$st_errf" || st_rc=$?
    # ⛔ `grep -c` EXITS 1 WHEN IT SELECTS NOTHING — which is the HEALTHY case (git wrote no warnings).
    # Reading that as a failure made `st_ok=0` unconditional, so COMPLETE became unreachable and every
    # clean cap kill produced a spurious snapshot plus a "do NOT reap it" verdict (VGATE cycle 11,
    # reproduced: 7 arms red, `status_stderr_lines=0` beside `status_ok=0`). Only "cannot run" (>=2) or
    # an unparseable count is a failure.
    st_noise="$(grep -c . "$st_errf" 2>/dev/null)"; local _g=$?
    if [ "$_g" -gt 1 ] || [ -z "$st_noise" ]; then st_ok=0; st_noise=0; fi
    # ⛔ EVERY PARSER'S OWN STATUS COUNTS (VGATE cycle 10, F1). `n_dirty` defaults to 0 and 0 is the
    # PERMISSIVE answer here — it short-circuits to NOTHING-LOST before any artifact is written. So a
    # parser that cannot run (no awk, a broken build, `awk` shadowed on PATH) must not read as "the
    # tree is clean": each awk below is checked, and a NUL-stream with BYTES that yields ZERO records
    # is a failed parse, not an empty worktree (measured: broken awk → rc=0 result=NOTHING-LOST over a
    # tree with two dirty paths).
    # ⛔ PARSED AS NEWLINE RECORDS, NOT `awk -v RS='\0'` (VGATE cycle 11, portability). A regex/multi-char
    # RS is not portable — BSD one-true-awk (macOS) does not support it, and this surface ships to
    # macOS — so the NUL stream is converted ONCE and every parser below is plain POSIX awk. The cost
    # is stated: a path containing a NEWLINE is split into two records, which can only ADD an uncovered
    # entry (fail-closed ⇒ PARTIAL), never hide one.
    tr '\0' '\n' < "$st_outf" > "$st_nl" 2>/dev/null || st_ok=0
    n_dirty="$(awk '$0 ~ /^[12u?] /{n++} END{print n+0}' "$st_nl" 2>/dev/null)" || st_ok=0
    unmerged="$(awk '$0 ~ /^u /{n++} END{print n+0}' "$st_nl" 2>/dev/null)" || st_ok=0
    sub_dirty="$(awk '{ n=split($0,f," "); if (f[1]!="1" && f[1]!="2" && f[1]!="u") next; s=f[3]; if (substr(s,1,1)=="S" && (substr(s,3,1)!="." || substr(s,4,1)!=".")) c++ } END{print c+0}' "$st_nl" 2>/dev/null)" || st_ok=0
    if [ -s "$st_outf" ] && [ "${n_dirty:-0}" -eq 0 ]; then st_ok=0; fi
    # The DIRTY PATH SET — field offsets are the v2 grammar (`1`: 8 fields before the path, `2`: 9,
    # `u`: 10, `?`: 1).
    # ⛔ SLICED BY `index`, NEVER split/rejoin (VGATE cycle 9, F1). `split($0, f, " ")` inherits awk's
    # special single-space rule, which COLLAPSES runs of spaces and DROPS leading blanks: a path with a
    # double space or a leading space then differed from its archived form and reported a false PARTIAL
    # over work that was fully preserved. `index`/`substr` is byte-exact.
    awk '{ k = (substr($0,1,2)=="? ") ? 1 : (substr($0,1,2)=="1 ") ? 8 : (substr($0,1,2)=="2 ") ? 9 : (substr($0,1,2)=="u ") ? 10 : 0
           if (k == 0) next
           pos = 1
           for (i = 0; i < k; i++) { sp = index(substr($0, pos), " "); if (sp == 0) { pos = 0; break } pos += sp }
           if (pos == 0) next
           p = substr($0, pos)
           if (p != "") print p }' "$st_nl" > "$dirtyf" 2>/dev/null || st_ok=0
    if [ -s "$st_outf" ] && [ ! -s "$dirtyf" ] && [ "${n_dirty:-0}" -gt 0 ]; then st_ok=0; fi
    rm -f "$st_outf" "$st_errf" "$st_nl"
  else
    st_rc=1                      # no temp file ⇒ the read cannot be checked ⇒ never claim clean
  fi
  [ "$st_rc" -eq 0 ] && [ "${st_noise:-0}" -eq 0 ] || st_ok=0
  if [ "${n_dirty:-0}" -eq 0 ]; then
    if [ "$st_ok" = 1 ]; then
      WIP_SNAPSHOT_RESULT=NOTHING-LOST
      cap_wip_record "$label" "$cap" "$elapsed" "$rc" NOTHING-LOST ""
      rm -f "$dirtyf" "$capf"
      echo "[cap] $label hit the ${cap}s cap (elapsed=${elapsed}s rc=$rc) — the worktree at $root was CLEAN, so NOTHING WAS LOST. The cap still killed it: that is a cap-size problem, not a lost-work problem." >> "$log"
      # A STASH IS A FIFTH DECLARED RESIDUAL (VGATE cycle 10, F4): `git stash push -u` leaves a clean
      # worktree, so this leg correctly sees no work to capture — but the message must not be read as
      # "this repo holds nothing". `refs/stash` lives in the COMMON git dir, so it SURVIVES the worktree
      # being removed (the same fact using-git-worktrees warns about from the other side); say so where
      # an operator might otherwise act on "nothing was lost".
      if git -C "$root" rev-parse --verify -q refs/stash >/dev/null 2>&1; then
        echo "[cap]   note: this repo has a stash (refs/stash). It is NOT part of this snapshot, and it lives in the COMMON git dir, so it survives this worktree being removed." >> "$log"
      fi
      return 0
    fi
    echo "[cap] $label hit the ${cap}s cap (elapsed=${elapsed}s rc=$rc) and the worktree state at $root COULD NOT BE READ (git status rc=$st_rc, ${st_noise:-0} stderr line(s)) — treating it as WORK AT RISK, NOT as clean. Nothing here will claim the tree was clean." >> "$log"
  fi
  O_ROOT="${O:-${HOME:-$root}/orchestrator}"
  stamp="$(date +%Y%m%dT%H%M%S)"
  # $O/wip/ IS THE HARNESS'S EXISTING DIRTY-WORKTREE CAPTURE DIRECTORY (`install.sh` creates it, the
  # README state table documents it). The cap snapshot belongs THERE, with the other dirty-worktree
  # captures, rather than in a second wip location nothing documents — the ledger row goes to
  # state/ beside walltime.tsv and disk.tsv, which is where append-only series live.
  dir="$O_ROOT/wip/capwip-$stamp-$$"
  if ! mkdir -p "$dir" 2>/dev/null; then
    WIP_SNAPSHOT_RESULT=LOST
    cap_wip_record "$label" "$cap" "$elapsed" "$rc" LOST ""
    rm -f "$dirtyf" "$capf"
    echo "[cap] $label KILLED AT ITS ${cap}s CAP (elapsed=${elapsed}s rc=$rc) with $n_dirty uncommitted path(s), and the snapshot directory $dir COULD NOT BE CREATED — that work is on disk ONLY at $root and is LOST if the worktree is reaped. Recover now: git -C \"$root\" diff HEAD --binary > /tmp/capwip-\$\$.patch" >> "$log"
    return 1
  fi
  # TRACKED (staged + unstaged) against HEAD, in one patch `git apply` can replay.
  # ⛔ A FAILED `git diff HEAD` IS NOT "NO TRACKED CHANGES" (VGATE cycle 5, measured). On an UNBORN
  # branch (`git init` + a staged file, no commit yet) it exits 128 with "ambiguous argument 'HEAD'",
  # so `want_tracked` reads 0 while the status read above reports a modification.
  git -C "$root" diff HEAD --binary > "$dir/tracked.patch" 2>/dev/null || diff_rc=$?
  patch_bytes="$(wc -c < "$dir/tracked.patch" 2>/dev/null | tr -d ' ')"
  git -C "$root" diff HEAD --name-only > "$dir/tracked.paths" 2>/dev/null || diff_rc=1
  # ⛔ 0 IS THE PERMISSIVE ANSWER, SO A COUNT THAT COULD NOT RUN IS A FAILURE, NOT A ZERO (VGATE cycle
  # 10, F2). These counts decide COMPLETE and they used to be `grep -c .` with the status discarded: a
  # broken/shadowed grep returned empty → 0 → `want_untracked=0` meant "nothing to archive" and
  # `uncovered_n=0` meant "everything covered", so a snapshot with a dirty path in NO artifact read
  # COMPLETE. `count_lines` reads a FILE that is already on disk (not a pipe) and reports the failure
  # instead of a zero. Measured before this: rc=0 result=COMPLETE over a tree whose only dirty path
  # appeared in no artifact, with the replay line naming a tarball that was never created.
  count_lines() {   # count_lines <file> — print the line count, or fail when it cannot be counted
    local f="$1" n
    [ -f "$f" ] || return 1
    n="$(wc -l < "$f" 2>/dev/null | tr -d ' ')" || return 1
    case "${n:-}" in ''|*[!0-9]*) return 1 ;; esac
    # bytes present but NOTHING counted is a failed count, not an empty set: `wc -l` under-reports a
    # file whose last line has no newline, and every zero here is the PERMISSIVE answer.
    if [ -s "$f" ] && [ "$n" -eq 0 ]; then return 1; fi
    printf '%s\n' "$n"
    return 0
  }
  want_tracked="$(count_lines "$dir/tracked.paths")" || { want_tracked=0; count_ok=0; }
  if [ "${want_tracked:-0}" -gt 0 ] && [ "${patch_bytes:-0}" -gt 0 ] \
     && git -C "$root" apply --numstat "$dir/tracked.patch" > "$dir/tracked.numstat" 2>/dev/null; then
    have_tracked="$(count_lines "$dir/tracked.numstat")" || { have_tracked=0; count_ok=0; }
    [ "${have_tracked:-0}" -ge "${want_tracked:-0}" ] && patch_ok=1
  fi
  # UNTRACKED (non-ignored) as a tarball, so an empty new file and a 200 MB fixture are both kept.
  # ⛔ `-z` + `--null`, AND THE NAMES ARE NEVER RE-QUOTED (VGATE cycle 10, F3). The line-oriented list
  # makes git QUOTE a non-ASCII name (`an\303\241lisis.md`), `tar -T` cannot stat that, and the file is
  # silently MISSING from the archive — ordinary filenames in a Spanish-language repo, not an edge case.
  # Worse, a name beginning with `-` is read by GNU tar as an OPTION from a `-T` file (`-C..` silently
  # redirects tar's directory and the count still "verifies"). NUL-delimited names plus
  # `--verbatim-files-from where the tar supports it` closes both; where it does not (bsdtar), the guard
  # below turns a leading-`-` name into an honest PARTIAL instead of a redirected archive.
  git -C "$root" ls-files --others --exclude-standard -z > "$dir/untracked.list0" 2>/dev/null
  tr '\0' '\n' < "$dir/untracked.list0" > "$dir/untracked.list" 2>/dev/null
  want_untracked="$(count_lines "$dir/untracked.list")" || { want_untracked=0; count_ok=0; }
  if [ "${want_untracked:-0}" -gt 0 ]; then
    local tar_verbatim=""
    # awk, not `| head -1 | grep -q` — a reader that exits early is the SIGPIPE shape the tree bans.
    if tar --version 2>/dev/null | awk 'NR==1 && /GNU tar/ {f=1} END{exit(f?0:1)}'; then tar_verbatim="--verbatim-files-from"; fi
    # ⛔ THE GUARD THE COMMENT ABOVE USED TO CLAIM EXISTS, DOES. A tar without `--verbatim-files-from`
    # (bsdtar) parses a leading-dash name in its -T file as an OPTION, so the archive can be built from
    # a redirected directory and still verify by count. On such a tar, refuse the archive (PARTIAL) and
    # let the operator take the copy by hand rather than ship a wrong one.
    leading_dash="$(grep -c '^-' "$dir/untracked.list" 2>/dev/null)" || leading_dash=0
    if [ "${leading_dash:-0}" -gt 0 ] && [ -z "$tar_verbatim" ]; then
      echo "[cap]   this tar has no --verbatim-files-from and $leading_dash untracked name(s) begin with '-': the tarball is NOT built (a leading-dash name would be read as an option). Copy them by hand from $root." >> "$log"
    # shellcheck disable=SC2086
    elif ( cd "$root" && tar --null $tar_verbatim -czf "$dir/untracked.tgz" -T "$dir/untracked.list0" ) >/dev/null 2>&1; then
      arch_bytes="$(wc -c < "$dir/untracked.tgz" 2>/dev/null | tr -d ' ')"
      arch_n="$(tar -tzf "$dir/untracked.tgz" 2>/dev/null | grep -c . )"
      [ "${arch_n:-0}" -ge "${want_untracked:-0}" ] && arch_ok=1
    fi
  fi
  # ── THE VERDICT IS A SET COMPARISON, NOT A COUNT (VGATE cycle 8) ─────────────────────────────
  # A COUNT of captured paths is masked by aggregates: one captured path from ONE artifact made the
  # old `captured > 0` guard pass for every other dirty path — measured on a real fixture where a
  # staged gitlink (`1 AD S... ghost`) produced a 0-byte patch, one decoy untracked file supplied the
  # count, and the verdict said COMPLETE over a path that is in no artifact. So every dirty path must
  # be COVERED by an artifact, and an uncovered one caps the verdict at PARTIAL. `--no-renames` makes
  # the tracked set a SUPERSET of a rename's porcelain path (delete+add), which can never invent an
  # uncovered path.
  : > "$capf"
  if [ "$patch_ok" = 1 ]; then
    git -C "$root" diff HEAD --name-only -z --no-renames 2>/dev/null | tr '\0' '\n' >> "$capf"
  fi
  if [ "$arch_ok" = 1 ]; then cat "$dir/untracked.list" >> "$capf" 2>/dev/null; fi
  # ⛔ ONE COLLATION ON BOTH SIDES, AND A COMPARATOR THAT CAN FAIL CLOSED (VGATE cycle 9, F2+F3).
  # `sort` here once ran under the AMBIENT locale while `comm` ran under C, so a mixed-case snapshot on
  # a `en_US.UTF-8` box made `comm` answer "file 2 is not in sorted order" — discarded by `2>/dev/null`,
  # leaving five COVERED paths reported as uncovered. And a `comm` that cannot run at all (absent from
  # PATH, a broken build) produced an EMPTY uncovered set, which reads as "fully covered" — the same
  # silent false PASS this leg exists to prevent. So: pinned LC_ALL on every side, and any non-zero
  # status from sort/comm sets `cmp_ok=0`, which caps the verdict at PARTIAL.
  cmp_ok=1
  LC_ALL=C sort -u -o "$capf" "$capf" 2>/dev/null || cmp_ok=0
  if [ -s "$dirtyf" ]; then
    LC_ALL=C sort -u -o "$dirtyf" "$dirtyf" 2>/dev/null || cmp_ok=0
    if [ "$cmp_ok" = 1 ]; then
      LC_ALL=C comm -23 "$dirtyf" "$capf" > "$dirtyf.uncovered" 2>/dev/null || cmp_ok=0
      uncovered_n="$(count_lines "$dirtyf.uncovered")" || { uncovered_n=0; cmp_ok=0; }
    fi
  fi
  [ -n "${uncovered_n:-}" ] || uncovered_n=0
  [ -s "${dirtyf:-}" ] && [ -f "$dirtyf.uncovered" ] && uncovered="$(cat "$dirtyf.uncovered")" || uncovered=""
  if [ "$st_ok" = 0 ]; then
    result=PARTIAL                                   # the tree state could not be read at all
  elif [ "$diff_rc" -ne 0 ]; then
    result=PARTIAL                                   # `git diff HEAD` failed (unborn branch?)
  elif [ "${unmerged:-0}" -gt 0 ]; then
    result=PARTIAL                                   # conflict stages are in no artifact
  elif [ "${sub_dirty:-0}" -gt 0 ]; then
    result=PARTIAL                                   # submodule content is in no artifact
  elif [ "$cmp_ok" = 0 ] || [ "$count_ok" = 0 ]; then
    result=PARTIAL                                   # a count or the comparison could not run
  elif [ "${uncovered_n:-0}" -gt 0 ]; then
    result=PARTIAL                                   # a dirty path no artifact covers
  elif { [ "${want_tracked:-0}" -eq 0 ] || [ "$patch_ok" -eq 1 ]; } \
       && { [ "${want_untracked:-0}" -eq 0 ] || [ "$arch_ok" -eq 1 ]; }; then
    result=COMPLETE
  else
    result=PARTIAL
  fi
  {
    printf 'what=cap-wip-snapshot\n'
    printf 'label=%s\nworktree=%s\nbranch=%s\nhead=%s\n' "$label" "$root" \
      "$(git -C "$root" branch --show-current 2>/dev/null)" "$(git -C "$root" rev-parse HEAD 2>/dev/null)"
    printf 'cap_s=%s\nelapsed_s=%s\nrc=%s\n' "$cap" "$elapsed" "$rc"
    printf 'dirty_paths=%s\ndiff_rc=%s\nstatus_rc=%s\nstatus_stderr_lines=%s\nunmerged_paths=%s\nsubmodule_dirty=%s\nuncovered_paths=%s\ncompare_ok=%s\ncount_ok=%s\n' \
      "${n_dirty:-0}" "$diff_rc" "$st_rc" "${st_noise:-0}" "${unmerged:-0}" "${sub_dirty:-0}" "${uncovered_n:-0}" "$cmp_ok" "$count_ok"
    printf 'tracked_paths=%s\ntracked_in_patch=%s\ntracked_bytes=%s\n' "${want_tracked:-0}" "${have_tracked:-0}" "${patch_bytes:-0}"
    printf 'untracked_paths=%s\nuntracked_in_archive=%s\narchive_bytes=%s\n' "${want_untracked:-0}" "${arch_n:-0}" "${arch_bytes:-0}"
    printf 'result=%s\n' "$result"
  } > "$dir/SNAPSHOT.txt" 2>/dev/null
  if [ "${uncovered_n:-0}" -gt 0 ]; then printf '%s\n' "$uncovered" > "$dir/uncovered.list" 2>/dev/null; fi
  cap_wip_record "$label" "$cap" "$elapsed" "$rc" "$result" "$dir"
  echo "[cap] $label KILLED AT ITS ${cap}s CAP (elapsed=${elapsed}s rc=$rc) with $n_dirty uncommitted path(s) — work PRESERVED ($result): $dir" >> "$log"
  echo "[cap]   tracked=${want_tracked:-0} path(s) -> tracked.patch (${patch_bytes:-0} bytes, verified=$patch_ok); untracked=${want_untracked:-0} -> untracked.tgz (${arch_bytes:-0} bytes, verified=$arch_ok); uncovered=${uncovered_n:-0}" >> "$log"
  # QUOTED, because this line is meant to be PASTED. An unquoted `git -C $root apply $dir/...` breaks
  # on any path containing a space, which turns the recovery instruction into a second failure at the
  # moment somebody is already rescuing work (VGATE finding, cycle 1).
  # THREE CASES, not two: "there was no untracked work" is not "the archive failed", and printing the
  # failed-archive wording over an EMPTY list (VGATE cycle 12) tells an operator to copy nonexistent
  # files by hand.
  # ⛔ AND THE TRACKED CLAUSE IS SELECTED THE SAME WAY (review finding, P3): an untracked-only tree has
  # a 0-byte `tracked.patch`, and `git apply` on that exits 128 ("No valid patches in input") — an
  # instruction that fails at the moment somebody is rescuing work.
  local tracked_clause
  if [ "${patch_bytes:-0}" -gt 0 ] && [ "$patch_ok" = 1 ]; then
    tracked_clause="git -C \"$root\" apply \"$dir/tracked.patch\""
  elif [ "${want_tracked:-0}" -gt 0 ]; then
    tracked_clause="the tracked work was NOT captured (see \"$dir/SNAPSHOT.txt\")"
  else
    tracked_clause="no tracked changes were captured (there is no patch to apply)"
  fi
  if [ "${want_untracked:-0}" -eq 0 ]; then
    echo "[cap]   replay: $tracked_clause (no untracked files were present, so there is no tarball)" >> "$log"
  elif [ "$arch_ok" = 1 ]; then
    echo "[cap]   replay: $tracked_clause ; untracked: tar -xzf \"$dir/untracked.tgz\" -C \"$root\"" >> "$log"
  else
    # No archive exists — naming one would send an operator to a tar invocation that cannot work.
    echo "[cap]   replay: $tracked_clause ; the untracked work is listed in \"$dir/untracked.list\" and was NOT archived (copy it by hand from $root)" >> "$log"
  fi
  if [ "$result" != COMPLETE ]; then
    echo "[cap]   INCOMPLETE SNAPSHOT: dirty=${n_dirty:-0} unmerged=${unmerged:-0} submodule=${sub_dirty:-0} uncovered=${uncovered_n:-0} status_ok=$st_ok — the worktree at $root is still the only FULL copy. Do NOT reap it." >> "$log"
    if [ "${uncovered_n:-0}" -gt 0 ]; then
      echo "[cap]   paths in NO artifact (see $dir/uncovered.list): $(awk 'NR<=5{printf "%s ", $0}' <<<"$uncovered")" >> "$log"
    fi
  fi
  rm -f "$dirtyf" "$capf" "$dirtyf.uncovered"
  WIP_SNAPSHOT_DIR="$dir"
  WIP_SNAPSHOT_RESULT="$result"
  cap_wip_prune "$O_ROOT/wip"
  [ "$result" = COMPLETE ] && return 0
  return 1
}

# ── the ONE agent invocation ─────────────────────────────────────────────────────
# run_agent <seconds> <logfile> <promptfile> [label]
#
# Wall-clock limited: `pi -p` has no internal limit, so one hung model call holds a concurrency slot
# forever, and the caps count SESSIONS, so a single hang silently halves throughput. macOS ships no
# `timeout`/`gtimeout`, so this is done in bash: run the agent in the background with a watchdog
# subshell that kills it after N seconds. The stale-worker reaper in orch-loop.sh is the second line
# of defence.
#
# THE CAP PRESERVES THE WORKTREE (#2045). A kill at the cap used to destroy a lane's uncommitted work
# and report nothing — see cap_wip_snapshot() above for the measurement. On a cap hit this function
# snapshots the worktree (tracked patch + untracked tarball, both verified), writes
# `$O/state/capwip.tsv`, and sets AGENT_CAP_HIT / WIP_SNAPSHOT_DIR / WIP_SNAPSHOT_RESULT so the
# caller can report it. The tree it reads is `WIP_PATH` if the caller sets it — fix-one.sh does,
# exactly as it sets DISK_GATE_PATH, because that worker `cd`s into the MAIN checkout while its work
# lives in the fixer's worktree — and otherwise the agent's own cwd (`$PWD`), which is where a lane
# and a background worker work.
#
# Gated: a refusal does not start the agent at all, and run_agent returns THAT gate's code —
# AGENT_DISK_REFUSED (77, evaluated FIRST: a full filesystem never clears by waiting) or
# AGENT_LOAD_REFUSED (75, which clears when the box quietens). The code selects the REMEDY.
# ⛔ THE SIGNAL THAT NO AGENT RAN IS `AGENT_STARTED=0`, NOT EITHER CODE (review round 2, P2).
# AGENT_STARTED is 0 at function entry — BEFORE either gate — and is set to 1 only once both gates have
# passed and `pi` has actually been launched. A refusal therefore always leaves it 0 (that is exactly
# what makes it the no-agent signal), and it is not shared with `pi`'s own exit statuses; a caller that
# keys on 75 alone will mis-read a disk refusal, and a caller that keys on the exit status alone will
# mis-read a `pi` that exited 75 for its own reason. That is why the early contract here named only the load gate, and
# after #1765 it no longer can. The distinction from "the agent ran and failed" is what matters:
# a review that reached a verdict records a `needsfix-<PR>-<head>` marker only when it found ISSUES;
# a run that never produced a verdict writes NONE (agent-infra#8602's `verdict_kind`, ported into
# merge-one.sh), so it cannot authorise a fixer, burn a MAX_FIX_TRIES attempt or park the PR (the
# #1716/#1720 class). Stated precisely here because this comment used to say the verdict-less case
# DID write the marker — true before #8602, false after, and this file is what a caller reads.
AGENT_LOAD_REFUSED=75
# The disk gate's refusal code, and it is a SEPARATE code on purpose: the remedies are opposite. A
# load refusal clears when the box quietens and the controller re-dispatches next cycle; a disk
# refusal will NEVER clear on its own, so a caller (or an operator reading a lane log) that treats
# the two as one waits for an event that cannot happen.
AGENT_DISK_REFUSED=77
# The SPAWN POINT's refusal code (agent-infra#1884, see the last section of this file). It is a THIRD
# code because it is a third process: run_agent launches `pi`, and the installed `pi` may itself
# refuse. 75 cannot be reused for that — `pi` shares the 0-255 namespace, and the contract below
# depends on a `pi` that exits 75 for its own reason being read as STARTED. 76 is that signal, and
# run_agent below translates it into AGENT_LOAD_REFUSED so no caller has to learn a new code.
PI_GATE_REFUSED=76
# The spawn-point ledger's rotation cap, in bytes (see pi_gate_ledger). A module constant, NOT an env
# knob: the size of the box's own measurement is not something a caller should be able to lift.
PI_GATE_LEDGER_MAX_BYTES=5242880
# Authoritative "an agent ran" flag, set by run_agent() itself. `rc == AGENT_LOAD_REFUSED` alone is
# ambiguous: `pi` shares the 0–255 exit-status namespace, so a pi that exited 75 for its own reason
# would be read as a load refusal — and a caller that acts on that (fix-one.sh skips its merge-chain
# re-run, merge-one.sh skips recording a verdict) would silently do the wrong thing. The flag is set
# only after the gate passed and pi was actually launched, so it cannot be produced by a refusal.
AGENT_STARTED=0
run_agent() { # run_agent <seconds> <logfile> <promptfile> [label]
  local t="$1" log="$2" prompt="$3" label="${4:-agent}" pid w rc l start elapsed
  AGENT_STARTED=0
  # The cap signal is per-invocation state, like AGENT_STARTED: a caller that reads it after a
  # refusal or a clean run must see 0, never a previous lane's answer.
  AGENT_CAP_HIT=0; WIP_SNAPSHOT_DIR=""; WIP_SNAPSHOT_RESULT=""
  # ── the disk gate (#1765). Read FRESH immediately before the spawn, for the load gate's reason plus
  # one of its own: a lane can sit waiting for a claim for 90 minutes, and the filesystem it will
  # fill is not the one that was measured when it was dispatched.
  #
  # ⛔ THIS GATE RUNS BEFORE THE LOAD GATE, AND THAT ORDER IS LOAD-BEARING (review round 1, P1). With
  # the load gate first, a saturated box with a full filesystem reports ONLY the load refusal, and the
  # operator is told to wait for an event that cannot arrive — which is the very failure the
  # caller-side naming exists to remove. A disk refusal never clears on its own; a load refusal does.
  # Both are true at once, so the un-clearable one has to be the one reported.
  #
  # DISK_GATE_PATH names the volume; the default is the caller's OWN CWD — and that is deliberately
  # not claimed to be the agent's worktree (review round 2, P2: the earlier comment said it was, and
  # for fix-one.sh it is not). lane.sh is launched with its cwd inside the worktree, so its default is
  # right; fix-one.sh does `cd "$REPO"` and only NAMES the worktree in the agent's prompt, so it
  # passes the volume explicitly (`DISK_GATE_PATH="$WT"`) instead of silently measuring the main
  # checkout — which is the whole point, because `uv sync` writes its venv in the WORKTREE and that is
  # where the ENOSPC of 2026-10-15 landed. On a cell `$O`, `$REPO` and the worktree share /dev/root,
  # so one reading covers both; the override exists for a box that splits them, and it must be GIVEN
  # there rather than assumed.
  local dfree dpath
  dpath="${DISK_GATE_PATH:-$PWD}"
  dfree="$(disk_free_mb "$dpath")"
  # DURABLE, and written for ALLOWED runs too — a series that only records refusals cannot answer
  # "how close did we get", which is the question that would have caught either incident early.
  # Same append-only shape as walltime.tsv; a refusal writes a row here (unlike walltime, where a
  # refusal would fabricate a zero-duration sample) because "the disk was below the floor" IS the
  # measurement. tab-separated: epoch, kind, tag, free MB, path.
  if [ -n "${O:-}" ]; then
    mkdir -p "$O/state" 2>/dev/null || true
    printf '%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "${KIND:-agent}" "${TAG:-}" "${dfree:-?}" "$dpath" \
      >> "$O/state/disk.tsv" 2>/dev/null || true
  fi
  # ⛔ AN UNREADABLE PROBE IS ANNOUNCED (review round 1, P2). The fail-open above is deliberate, but
  # silent fail-open is how a typo'd DISK_GATE_PATH — or a missing `df` — disarms the gate invisibly.
  # The reading is not a refusal, so this is a WARN; the distinction matters, because the agent is
  # still allowed to start.
  # ⛔ AND "UNREADABLE" IS THE PREDICATES' OWN DEFINITION, NOT A SECOND ONE (review round, P2).
  # `disk_ok` and `disk_low` classify an EMPTY or NON-NUMERIC reading as unreadable and fail open on
  # it; announcing with `-z` meant a NON-EMPTY but non-numeric reading — the shape the OFMT bug above
  # produces — was silently permissive while this comment claimed it was loud. Announcing with
  # `is_num` was still a SECOND definition, and a divergent one: `is_num` rejects `0100` where the
  # predicates accept it, so the same reading was "unreadable" here and "100MB" to the verdict being
  # announced. Both now call `disk_readable`, so agreement is structural rather than maintained.
  if ! disk_readable "$dfree"; then
    echo "[disk-gate] WARN $label: could not read free space on $dpath — the disk floor CANNOT be enforced for this spawn. Check DISK_GATE_PATH, PATH and that 'df' works. Failing OPEN by design." >> "$log"
  elif ! disk_ok "$dfree"; then
    echo "[disk-gate] REFUSED $label: only ${dfree}MB free on $dpath < disk_min_free_mb=$DISK_MIN_FREE_MB — no agent was started, so nothing was consumed; reclaim with 'cloud-cell-supervisor.sh prune' (--caches, and --scratch for /tmp) and the controller re-dispatches" >> "$log"
    return "$AGENT_DISK_REFUSED"
  elif disk_low "$dfree"; then
    echo "[disk-gate] WARN $label: only ${dfree}MB free on $dpath (floor ${DISK_MIN_FREE_MB}MB, warn band ${DISK_WARN_FREE_MB}MB) — a full disk is what breaks a cell first; reclaim with 'cloud-cell-supervisor.sh prune' before it fills" >> "$log"
  fi
  l="$(load1)"
  if ! can_spawn "$l"; then
    echo "[load-gate] REFUSED $label: load=$l >= max_load=$MAX_LOAD — no agent started; the controller re-dispatches when load falls, and nothing was consumed" >> "$log"
    return "$AGENT_LOAD_REFUSED"
  fi
  AGENT_STARTED=1
  start="$(date +%s)"
  pi -p --provider deepseek --model deepseek-v4-flash --no-session "$(cat "$prompt")" >> "$log" 2>&1 &
  pid=$!
  ( sleep "$t"; kill -TERM "$pid" 2>/dev/null; sleep 15; kill -KILL "$pid" 2>/dev/null ) >/dev/null 2>&1 &
  w=$!
  wait "$pid" 2>/dev/null; rc=$?
  kill "$w" 2>/dev/null
  # ⛔ A REFUSAL AT THE SPAWN POINT IS THIS GATE'S OWN REFUSAL (agent-infra#1884). Without this arm
  # the installed `pi`'s 76 is read by every caller as "the agent ran and failed" — and the two
  # consequences are both real: fix-one.sh re-runs the merge chain for a fixer that never ran, and
  # the refusal is mistaken for a review that RAN AND FAILED, which (#1716/#1720) is what burns a
  # MAX_FIX_TRIES attempt and eventually parks the PR. Since #8602 a verdict-less run writes no
  # `needsfix` marker at all, so the marker half is closed in merge-one.sh; this arm keeps the exit
  # code distinct so a caller never has to infer "no agent ran" from a bare 76. The load is read
  # twice on purpose (here, and again in the shim) — the band
  # between them is milliseconds, and closing it by trusting an env marker from the caller would
  # hand the bypass back. So the SECOND refusal is translated into the FIRST: no agent ran
  # (AGENT_STARTED=0), the caller sees AGENT_LOAD_REFUSED, and no walltime row is written.
  if [ "$rc" = "$PI_GATE_REFUSED" ]; then
    AGENT_STARTED=0
    echo "[load-gate] REFUSED $label: the pi spawn point refused the launch (load >= max_load=$MAX_LOAD) — no agent started, nothing consumed; the [pi-gate] line above carries the reading and the caller, and the controller re-dispatches when load falls" >> "$log"
    return "$AGENT_LOAD_REFUSED"
  fi
  # agent-infra#1709 item 3: wall_limit is the CAP, not the cost. elapsed is the measured
  # reviewer/fixer/lane wall-time — the load-bearing number for fleet capacity (it was unmeasured).
  elapsed=$(( $(date +%s) - start ))
  echo "[timeout] agent pid=$pid wall_limit=${t}s elapsed=${elapsed}s rc=$rc" >> "$log"
  # DURABLE time series (agent-infra#1709 item 3). The per-run log above is TRUNCATED whenever
  # the same PR is re-run (`> "$L.log"`), so a single log line erases its own history: measured,
  # three real reviewer samples (885s/963s/1142s) disappeared within minutes. #1709 needs a DAY
  # of data, which is only possible append-only. Tab-separated, one row per agent invocation.
  # ⛔ A REFUSED SPAWN WRITES NO ROW: no agent ran, so a row here would fabricate a zero-duration
  # sample and corrupt exactly the series #1709 exists to read.
  mkdir -p "$O/state"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "${KIND:-agent}" "${TAG:-}" "$t" "$elapsed" "$rc" >> "$O/state/walltime.tsv"
  # ── the CAP path must not destroy the work it interrupts (#2045) ────────────
  # `elapsed >= t` IS the cap firing: the watchdog kills at exactly `t`, so anything that ran to at
  # least `t` was killed (or finished in the same second, in which case the tree is either clean or
  # its work genuinely needs saving — both answers are correct here). It runs AFTER `wait`, so the
  # hard kill has already landed and this can never delay it.
  if [ "$elapsed" -ge "$t" ]; then
    AGENT_CAP_HIT=1
    cap_wip_snapshot "$label" "$t" "$elapsed" "$rc" "$log" || true
  fi
  return "$rc"
}

# ── the lane venv teardown (agent-infra#1932) ─────────────────────────────────────────────────────
# A `.venv` belongs to a RUNNING lane, not to a worktree that outlives it. `run_agent` above is what
# makes the env necessary (`uv sync` writes it inside the worktree, and AGENTS.md's test line tells the
# lane to run it), so the teardown that ends its life belongs HERE, next to the spawn — and the
# RUNNERS call it on their way out.
#
# ⛔ WHY THE RUNNER AND NOT A SCAN: at the runner's exit "this lane is done" is KNOWN, not inferred.
# The GC half of #1932 (`reap-lane-venvs.sh --gc`) exists for the lanes that never reach their exit
# path (killed session, reboot), and it has to prove death from process evidence instead. This path
# declares it and still requires the SAME no-live-holder proof, so a worktree shared with a second
# live lane is never touched.
#
# ⛔ BEST-EFFORT, AND NEVER SILENT: a failed reap must not change a runner's exit status (the lane's
# work is already committed and pushed, and its status is what the controller reads), but a skipped or
# failed teardown is LOGGED with its reason — a teardown that quietly does nothing is the "fix that is
# not live" shape #1932 is about. `REAP_LANE_VENV_DISABLE=1` is the operator escape, and it says so.
#
# The script is resolved rather than assumed, because a cloud cell runs these workers from `$O` (seeded
# by `cloud-cell-supervisor.sh`) while a laptop runs them from the harness directory and, for the
# farmed copy, from `~/.pi/agent/scripts`. A missing reaper KEEPS the venv and says where it looked —
# the one thing that must never happen is falling back to a blind `rm`.
REAP_LANE_VENV_SH=""
reap_lane_venv_path() {
  local c here
  if [ -n "$REAP_LANE_VENV_SH" ]; then printf '%s\n' "$REAP_LANE_VENV_SH"; return 0; fi
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"
  for c in "${O:-}/reap-lane-venvs.sh" "$here/reap-lane-venvs.sh" \
           "${AGENT_INFRA_PATH:-}/scripts/reap-lane-venvs.sh" \
           "${HOME:-}/.pi/agent/scripts/reap-lane-venvs.sh"; do
    [ -n "$c" ] && [ -f "$c" ] || continue
    REAP_LANE_VENV_SH="$c"
    printf '%s\n' "$c"
    return 0
  done
  return 1
}

# reap_lane_venv <worktree> <label> — reclaim that worktree's `.venv` if no live holder remains.
# Callers append the output to their own log (`>> "$log" 2>&1`); nothing here writes to a caller's
# stdout, because lane.sh's stdout is the lane's own report surface.
reap_lane_venv() {
  local wt="${1:-}" label="${2:-lane}" reaper rc
  if [ "${REAP_LANE_VENV_DISABLE:-0}" = "1" ]; then
    echo "[venv-reap] DISABLED by REAP_LANE_VENV_DISABLE=1 — $wt/.venv left in place"
    return 0
  fi
  if [ -z "$wt" ] || [ ! -d "$wt" ]; then
    echo "[venv-reap] SKIP $label: no worktree directory to reap (${wt:-<empty>})"
    return 0
  fi
  if [ ! -e "$wt/.venv" ] && [ ! -L "$wt/.venv" ]; then
    echo "[venv-reap] $label: no .venv in $wt — nothing to reap"
    return 0
  fi
  if ! reaper="$(reap_lane_venv_path)"; then
    echo "[venv-reap] SKIP $label: reap-lane-venvs.sh not found in \$O, the harness dir, \$AGENT_INFRA_PATH/scripts or ~/.pi/agent/scripts — $wt/.venv KEPT (a blind rm could delete a live lane's env)"
    return 0
  fi
  echo "[venv-reap] $label: reaping $wt/.venv via $reaper"
  REAP_VENV_LOG="${REAP_VENV_LOG:-${HOME:-}/.pi/agent/state/reap-lane-venvs.log}" \
    bash "$reaper" --worktree "$wt" --apply
  rc=$?
  case "$rc" in
    0) echo "[venv-reap] $label: done (see the reaper's line above for what was kept, and why)" ;;
    3) echo "[venv-reap] $label: FAIL-CLOSED — the reaper could not prove the lane is dead, so the env was KEPT (rc=3). It will be collected by a later GC." ;;
    5) echo "[venv-reap] $label: done, BUT free disk is below REAP_VENV_FREE_FLOOR_MB (rc=5) — see the reaper's capacity line; a lane starting now can fill the disk" ;;
    *) echo "[venv-reap] $label: reaper exited $rc — $wt/.venv may still be present; a later GC will collect it" ;;
  esac
  return 0
}
# ── THE SPAWN POINT (agent-infra#1884) ─────────────────────────────────────────
# Everything above is a LIBRARY: a caller reaches the gate only if it remembers to source this file
# first. That is the defect #1884 measured. The orchestrator started three lanes by writing a runner
# that did
#
#     tmux new-session -d -s <name> "… pi -p \"$(cat <brief>)\" …"
#
# There is no `lane.sh` in that path, so this file was never sourced and MAX_LOAD was never read.
# The box was already at load 258 on 10 cores (hw.ncpu=10, the plist's ceiling MAX_LOAD=100, i.e.
# ~2.6x its own ceiling) and NOTHING refused, because nothing consulted it. Two of the three lanes
# then died on an auth error and one on a stale config — and the capacity question is independent of
# whether they worked: they should have been refused before they started.
#
# The lesson is not "the orchestrator was careless". It is that a control living at the CALLER is
# exactly as strong as the weakest caller, and a caller that omits it is not merely ungated — it is
# INVISIBLE: no refusal, no log line, no count. So the gate moves to the SPAWN POINT, where `pi` is
# born, and the mechanism is the one this tree already ships for `gh` (scripts/gh-shim/gh, #984):
# the SHIM ON PATH. Installed as $HOME/.pi/agent/bin/pi, a directory that is FIRST on PATH on both
# surfaces (measured: on the laptop and on a cmux cell, and install-launchd.sh keeps it in the
# runner-gate plist PATH so the daemon and the tmux children it starts inherit it), every process
# that runs `pi` resolves THIS file: lane.sh, fix-one.sh, merge-one.sh's ungated copy, orch-loop's
# runners, a hand-written tmux runner, an interactive session, and a future caller nobody has
# thought of. A caller cannot opt out by omission because it is not asked.
#
# ⛔ ONE ARTIFACT, NOT TWO. The load primitives (the portable core probe, the MAX_LOAD derivation,
# `can_spawn`, `load1`) live HERE and the installed `pi` is a COPY OF THIS FILE, so the gate a caller
# sources and the gate the spawn point applies cannot drift apart — the failure a second
# implementation would guarantee. That is also why the installed name is `pi` rather than a wrapper
# script: a wrapper that had to resolve a library by path would dangle when a checkout moves (the
# reapers move worktrees constantly), and a dangling `pi` on PATH breaks every lane on the box.
#
# WHAT IT DOES, in this order: take a FRESH reading (the dispatch-time reading is minutes or hours
# stale by the time a worker spawns); if the reading is at or above the ceiling, REFUSE with a LOUD
# line naming the reading, the ceiling and what was not started, plus a row in a DURABLE ledger and
# a running refusal count; otherwise exec the real pi. A refusal consumes nothing: no model call, no
# session, no lease.
#
# ⛔ STATED LIMITS — what this layer does not cover, each one a DELIBERATE act rather than an
# omission. A reader who takes the paragraph above as "the gate is now total" will be wrong, and
# that is the kind of wrong this file's headers exist to prevent:
#   * An invocation that bypasses PATH: the real binary by ABSOLUTE path (/usr/local/bin/pi), a
#     `PATH=` reset, or `env -i`. This is the same class scripts/gh-shim/gh names for `gh`, and it
#     is also the OPERATOR'S RESCUE: when the box is over its ceiling and the human needs a pi to
#     fix it, the refusal message prints the absolute path to use. Named, not silently trusted.
#   * A caller that EXPORTS MAX_LOAD itself. MAX_LOAD is the operator's ceiling, not a secret —
#     install.sh renders it into the plist, and `orch-loop.sh`/`install.sh` derive it the same way.
#     A process that sets it has stated a ceiling of its own. MAX_LOAD=0 keeps its documented
#     meaning: spawn nothing, for ever (`[ 0 -lt 0 ]` is false, so every reading is refused).
#   * INTERACTIVE sessions are gated too, deliberately. "The gate at the spawn point" is not a claim
#     about print mode, and parsing argv to exempt "interactive" would create a SECOND definition of
#     what a spawn is — the exact shape (`pi --print` vs `-p` vs an alias) a caller could hide
#     behind. The rescue route is the operator's, above.
#   * A box where neither pi-bootstrap/setup.sh nor pi-bootstrap/cell-install.sh has run has no shim.
#     Both install it (`$DEST/bin/pi`) and the cell installer byte-compares it on `--verify`, so the
#     state is checked rather than assumed — but it is a state, and it is stated.
#   * The DISK gate (#1765) is NOT here. Its reading is per-spawn (DISK_GATE_PATH is the worktree the
#     agent will fill), which a shim cannot know: a spawn through the shim is disk-gated only when
#     its caller runs through run_agent() above. Named residual, and it is the reason run_agent keeps
#     its own two gates rather than deferring to this one.
#   * `pi` invocations that never leave the current process — none exist today (there is no in-process
#     API use of the harness's model calls), and if one appeared it would be outside every PATH gate.
#   * ⛔ THE `task`/SUB-AGENT DISPATCH IS ANOTHER SPAWN POINT, AND IT DOES NOT PASS THROUGH PATH.
#     `extensions/subagent/index.ts` (canonical) and `extensions/builtin-tools/index.ts` both resolve
#     the child as `process.execPath` + the ENTRY SCRIPT (`getPiInvocation`), deliberately, so a
#     truncated PATH cannot cause `spawn pi ENOENT` — which means a `task` child is NOT gated here.
#     That is the one fan-out path #1874's per-item dispatcher would use, so it is named rather than
#     glossed: an agent on an over-ceiling box can still spawn sub-agents through `task`. Filed as
#     agent-infra#1920 (a second spawn point is its own change; folding a TS dispatcher gate into
#     this one would have put two unreviewed mechanisms behind one PR).

# pi_gate_real <self> — the real pi: the first `pi` on PATH that is not this file.
# The exclusion is `-ef` (device+inode THROUGH symlinks), not a path comparison: the harness already
# installs a NEUTRAL directory holding a SYMLINK back to a shim (that is how ~/.pi/agent/shims/gh is
# wired), and skipping only $SELF_DIR let `-x` accept the shim itself, so `exec` re-entered forever
# and EVERY call hung — measured on the gh shim, VGATE cycle 3. `-ef` catches a link, a link chain
# and a hardlink alike.
pi_gate_real() { # pi_gate_real <self-path>
  local self="$1" d old_ifs="$IFS"
  IFS=:
  for d in $PATH; do
    case "$d" in ''|.) continue ;; esac
    # `-f` AND `-x`: `[ -x ]` is TRUE for a DIRECTORY, so a `pi/` directory on PATH would be chosen
    # and `exec` would die "Is a directory" — a box-wide pi outage from a stray mkdir (#1884 review
    # reasoning). `-f` follows symlinks, so a linked real binary still passes.
    [ -f "$d/pi" ] && [ -x "$d/pi" ] || continue
    [ "$d/pi" -ef "$self" ] && continue
    printf '%s' "$d/pi"; IFS="$old_ifs"; return 0
  done
  IFS="$old_ifs"
  return 1
}

# pi_gate_ledger <verdict> <load> <max> <cwd> <caller> — one append-only row per pi invocation.
# ALLOWED runs are recorded too, for the reason the disk ledger states: a series that records only
# refusals cannot answer "how close did we get", which is the question that would have caught both
# incidents early. Fields: epoch, verdict, load, max_load, pid, ppid, KIND, TAG, cwd, caller.
# It writes to $HOME/.pi/agent/state (the durable per-box state dir that already holds locks/,
# reviews/ and audit/) rather than to `$O`, because a hand-written runner — the exact caller this
# mode exists for — is under no obligation to have `$O` set.
pi_gate_ledger() { # pi_gate_ledger <verdict> <load> <max> <cwd> <caller>
  local dir f
  [ -n "${HOME:-}" ] || return 0
  dir="$HOME/.pi/agent/state"
  mkdir -p "$dir" 2>/dev/null || return 0
  f="$dir/spawn-gate.tsv"
  # ⛔ BOUNDED. This is the highest-volume sink in the tree — one row per `pi` invocation on the box,
  # interactive sessions and sub-agents included — and a device that fills silently is the defect
  # #1765 exists for (measured twice on a cell, the second time killing the controller mid-log).
  # One-generation rotation keeps the total bounded at ~2x the cap with no timer, no reaper
  # dependency and no cross-process state; the previous generation is kept because the series an
  # operator reads after an incident is usually the last two. Cost of rotation: the "refusal #N"
  # counter restarts, which is a line decoration, not a decision.
  if [ -f "$f" ] && [ "$(wc -c < "$f" 2>/dev/null || printf '0')" -ge "$PI_GATE_LEDGER_MAX_BYTES" ]; then
    mv -f "$f" "$f.1" 2>/dev/null || :
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(date +%s)" "${1:-}" "${2:-}" "${3:-}" "$$" "${PPID:-0}" "${KIND:-}" "${TAG:-}" "${4:-}" "${5:-}" \
    >> "$f" 2>/dev/null || return 0
}

# pi_gate_refusal_count — refusals recorded so far, so the loud line can say WHICH refusal this is
# ("counted" is the half that was missing: an ungated spawn left no count at all). Unreadable ledger
# reads as 0 — it is a message decoration, not a decision. `PI_GATE_LEDGER_MAX_BYTES` is the rotation
# cap (5 MiB ≈ 25k rows); it is a module constant rather than an env knob because the ledger's size
# is not a policy a caller should be able to lift.
pi_gate_refusal_count() {
  local f="${HOME:-}/.pi/agent/state/spawn-gate.tsv"
  if [ -n "${HOME:-}" ] && [ -r "$f" ]; then
    awk -F'\t' '$2 == "refused" { n++ } END { printf "%d", n + 0 }' "$f" 2>/dev/null && return 0
  fi
  printf '0'
}

# pi_shim_main <argv…> — `pi`, as the spawn point sees it.
# It never returns: the allow path `exec`s (so this process IS the agent, with no extra shell in the
# tree and the caller's own signals/fds intact), and the refusal path exits PI_GATE_REFUSED.
pi_shim_main() {
  local self real load cwd caller n item
  self="${BASH_SOURCE[0]}"
  real="$(pi_gate_real "$self")" || {
    # FAIL CLOSED on an unresolvable pi, LOUD: running *some* pi we cannot identify is worse than
    # refusing to run one, and 127 is the shell's own "cannot execute" so a caller quoting the error
    # sees a familiar code. (Contrast the probe polarity below, which fails OPEN: an unreadable
    # READING must not stop the box, but an unidentifiable BINARY must not run.)
    printf 'pi-gate: cannot find a real pi on PATH (searched every entry except %s)\n' "$self" >&2
    printf 'pi-gate: refusing to start a pi that cannot be identified — fix PATH, or run the real binary by absolute path\n' >&2
    exit 127
  }
  load="$(load1)"
  cwd="$(pwd 2>/dev/null || printf '?')"
  # The parent's command line is the only general answer to "what was not started": the harness's
  # own callers pass a label to run_agent, but the caller THIS mode exists for is a hand-written
  # runner that never heard of run_agent. Truncated so a long prompt cannot fill the ledger.
  caller="$(ps -o command= -p "${PPID:-0}" 2>/dev/null | cut -c1-200)"
  [ -n "$caller" ] || caller='<unreadable>'
  if ! can_spawn "$load"; then
    n="$(pi_gate_refusal_count)"
    item="${TAG:-${KIND:-untagged}}"
    # ONE line carries the three facts the issue requires — the load, the ceiling, and the item that
    # was not started — because that is the line an operator greps for.
    printf '[pi-gate] REFUSED load=%s >= max_load=%s — item NOT started: %s (cwd=%s, caller=%s)\n' \
      "${load:-?}" "$MAX_LOAD" "$item" "$cwd" "$caller" >&2
    printf '[pi-gate]   refusal #%s, recorded durably in %s/.pi/agent/state/spawn-gate.tsv — nothing was consumed: no model call, no session\n' \
      "$(( n + 1 ))" "${HOME:-<no HOME>}" >&2
    # The remedy line names BOTH routes, and the second one is deliberate: the operator must be able
    # to start a pi on a box this gate is refusing, or the gate becomes the thing that prevents the
    # fix. See STATED LIMITS.
    printf '[pi-gate]   remedy: re-dispatch when the 1-min load falls below %s; operator rescue is the real pi by absolute path (%s) or an explicit MAX_LOAD\n' \
      "$MAX_LOAD" "$real" >&2
    pi_gate_ledger refused "$load" "$MAX_LOAD" "$cwd" "$caller"
    exit "$PI_GATE_REFUSED"
  fi
  pi_gate_ledger allowed "$load" "$MAX_LOAD" "$cwd" "$caller"
  exec "$real" "$@"
}

# ── executed, not sourced ────────────────────────────────────────────────────────
# `BASH_SOURCE[0] == $0` means the kernel ran THIS file (the installed `pi`) rather than a caller
# sourcing the library above. Note there is NO name-based exemption: a shim that behaved differently
# when invoked under another name would be a one-word bypass (`ln -s …/spawn-gate.sh pilib`), and a
# copy invoked that way would then sit ungated on PATH. Any executed invocation is the spawn point,
# and any refused one is loud about it.
if [ "${BASH_SOURCE[0]:-}" = "$0" ]; then
  pi_shim_main "$@"
fi
