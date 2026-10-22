#!/usr/bin/env bash
# harness-cohesion.test.sh — hermetic tests for the ONE launcher (scripts/harness-up/-down/-status)
# and for the per-box divergence pass it schedules (check-deployed-drift.sh --surface).
#
# No network, no tmux, no git writes outside a throwaway fixture: every assertion drives the SHIPPED
# scripts (and the SHIPPED helper block, extracted by its own `>>> helpers` markers) rather than
# re-implementing them — a re-implementation passes on the broken copy too.
#
# COVERED (the three the #2231 brief names, then the divergence classes):
#   (i)   a FAILING self-test blocks startup, names the failing test, and starts nothing;
#   (ii)  an UNREAD pin dir is refused — the #2216 "worktree nobody reads" shape, both spellings
#         (the pin's tree is not materialised, and the read dir is a DIFFERENT tree than the pin);
#   (iii) PORTABILITY — the three helpers behave IDENTICALLY with and without the commands one
#         platform lacks (`timeout`/`gtimeout`, a `pgrep` with no `-c`), using shims that RECORD any
#         use: the assertion is not "it worked here" but "it never reached for the missing tool".
#   (iv)  the divergence pass: a home-only script, a differing script, a MISSING script, a component
#         dir the RUNNING controller executes that main does not carry, and — fail-closed — an
#         unreadable one is BROKEN (exit 2), never OK. Plus: no candidate dir at all is exit 2.
set -u
# ⛔ HERMETIC INCLUDES THE SHELL THE SUITE RUNS IN. A cell's shell exports `REPO` (its TARGET checkout,
# from keys.env) and `harness-refresh.sh:223` tells operators to "set HARNESS_REPO". `harness-up` reads
# an ambient `REPO` as the TARGET and probes THAT repo's `refs/claims/*`, so an inherited value from a
# shell whose target origin is unreadable (offline, unauthenticated) stops the walk before `loop` and
# reddens this shard on a CORRECT tree — measured on this head: `REPO=<target with unreadable origin>`
# → 2 failures (`:517`, `:586`), while the same shard on origin/main's launcher stayed green. Every arm
# here passes `--repo` explicitly; the arms that need a TARGET name it on their own line.
unset REPO HARNESS_REPO
# ⛔ AS ROOT THIS SUITE CANNOT PROVE MOST OF WHAT IT ASSERTS, SO IT REFUSES TO RUN RATHER THAN REPORT A
# GREEN IT DID NOT EARN. A third of the assertions are permission DENIALS (an unreadable file, an
# unlistable dir, an unsearchable ancestor, a mode-000 pin record): root's CAP_DAC_OVERRIDE makes every
# `chmod 000/600/111` deny nothing, so those arms cannot fail there — and a per-arm skip is only honest
# if every paired evidence assertion is skipped with it, which was measured to be incomplete (12 arms
# red under `unshare -r`). Fail closed: no pass from a run that cannot exercise its own assertions.
if [ "$(id -u)" -eq 0 ]; then
  printf 'harness-cohesion: ⛔ REFUSING to run as root — the chmod-denial arms cannot fail as root,\n'
  printf '  so a green pass here would be a claim this run did not test. Run as a non-root user.\n' >&2
  exit 2
fi
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UP="$HERE/harness-up"
DRIFT="$HERE/orchestrator-harness/check-deployed-drift.sh"
fails=0
assertions=0
ck() { # <name> <0|1>
  assertions=$((assertions + 1))
  if [ "$2" -eq 0 ]; then printf '  PASS  %s\n' "$1"; else printf '  FAIL  %s\n' "$1"; fails=$((fails + 1)); fi
}
TMP="$(mktemp -d)"; trap 'chmod -R u+rwX "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT

# ── the entry point surface ────────────────────────────────────────────────────────────────────
# A launcher nobody can execute is not a launcher; and the three names the operator types must all
# exist (harness-down/-status are thin names over ONE implementation, so they cannot drift apart).
for f in "$UP" "$HERE/harness-down" "$HERE/harness-status"; do
  [ -f "$f" ] && bash -n "$f" 2>/dev/null
  ck "entry point exists and parses: ${f#"$HERE"/}" $?
done
[ -x "$UP" ]; ck "harness-up is executable" $?

# ── a fixture git repo that carries a harness at origin/main ──────────────────────────────────
# The comparison side is REAL git (blob shas from a ref tree), because that is what the shipped
# instrument uses; stubbing it would test a different tool.
REPO_FIX="$TMP/repo"
mkdir -p "$REPO_FIX/scripts/orchestrator-harness"
printf '#!/usr/bin/env bash\necho loop\n' > "$REPO_FIX/scripts/orchestrator-harness/orch-loop.sh"
printf '#!/usr/bin/env bash\necho claims\n' > "$REPO_FIX/scripts/orchestrator-harness/claims.sh"
printf '#!/usr/bin/env bash\necho install\n' > "$REPO_FIX/scripts/orchestrator-harness/install.sh"
( cd "$REPO_FIX" && git init -q -b main . && git add scripts/orchestrator-harness \
  && git -c user.email=t@example.com -c user.name=t commit -qm fixture \
  && git update-ref refs/remotes/origin/main refs/heads/main \
  && git remote add origin "$REPO_FIX" ) >/dev/null 2>&1
ck "fixture repo built (origin/main resolves)" $?

# A home-dir harness dir that starts as a byte-identical copy of the repo's harness.
mkdir -p "$TMP/home/orchestrator"
cp "$REPO_FIX/scripts/orchestrator-harness"/*.sh "$TMP/home/orchestrator/"

# ⛔ HERMETIC: the surface pass reads the LIVE process table, and a box with a running controller
# would put that controller's own dir into the comparison — making every assertion here a statement
# about the developer's machine. `DRIFT_PS` is the seam (the same one the fleet inventory carries as
# `FLEET_PS`); the default stub prints NOTHING, and the running-controller case supplies a table.
printf '#!/bin/sh\ncat "$PS_TABLE" 2>/dev/null\nexit 0\n' > "$TMP/ps-stub"; chmod +x "$TMP/ps-stub"
: > "$TMP/ps-empty"

run_drift() { # <args…> — PATH/HOME isolated so the box's real dirs cannot leak in
  OUT="$( cd "$TMP" && HOME="$TMP/home" CELL_HOME="$TMP/cell" HARNESS_PIN_DIR="$TMP/cell/harness" \
          HARNESS="$TMP/home/orchestrator" DRIFT_PS="$TMP/ps-stub" PS_TABLE="${PS_TABLE:-$TMP/ps-empty}" \
          bash "$DRIFT" --repo "$REPO_FIX" --rel scripts/orchestrator-harness --no-fetch "$@" 2>&1 )"
  RC=$?
}

# ── (iv-a) a CLEAN surface passes ─────────────────────────────────────────────────────────────
run_drift --o "$TMP/none" --surface
ck "surface: a box whose only harness dir matches origin/main passes (rc=$RC)" "$([ "$RC" -eq 0 ] && echo 0 || echo 1)"

# ── (iv-b) a script that exists ONLY in a home dir ────────────────────────────────────────────
printf '#!/usr/bin/env bash\necho local-only\n' > "$TMP/home/orchestrator/stray-launcher.sh"
run_drift --o "$TMP/none" --surface
ck "surface: a script existing ONLY in a home dir is DRIFT (rc=$RC)" "$([ "$RC" -eq 1 ] && echo 0 || echo 1)"
case "$OUT" in *"exists ONLY in"*stray-launcher.sh*) ck "surface: the home-only file is NAMED" 0 ;; *) ck "surface: the home-only file is NAMED" 1 ;; esac
rm -f "$TMP/home/orchestrator/stray-launcher.sh"

# ── (iv-c) a script that DIFFERS from origin/main ─────────────────────────────────────────────
printf '#!/usr/bin/env bash\necho local-edit\n' > "$TMP/home/orchestrator/claims.sh"
run_drift --o "$TMP/none" --surface
ck "surface: a byte difference from origin/main is DRIFT (rc=$RC)" "$([ "$RC" -eq 1 ] && echo 0 || echo 1)"
case "$OUT" in *"claims.sh — DIFFERS in"*) ck "surface: the differing file is NAMED" 0 ;; *) ck "surface: the differing file is NAMED [$OUT]" 1 ;; esac
cp "$REPO_FIX/scripts/orchestrator-harness/claims.sh" "$TMP/home/orchestrator/claims.sh"

# ── (iv-d) a script main ships that the dir does NOT carry ────────────────────────────────────
mv "$TMP/home/orchestrator/install.sh" "$TMP/install.sh.hold"
run_drift --o "$TMP/none" --surface
ck "surface: a script shipped at origin/main but MISSING from the dir is DRIFT (rc=$RC)" "$([ "$RC" -eq 1 ] && echo 0 || echo 1)"
case "$OUT" in *"install.sh — shipped at"*"MISSING from"*) ck "surface: the missing file is NAMED" 0 ;; *) ck "surface: the missing file is NAMED [$OUT]" 1 ;; esac
mv "$TMP/install.sh.hold" "$TMP/home/orchestrator/install.sh"

# ── (iv-e) AN UNREADABLE PATH IS BROKEN, NEVER OK (fail-closed) ───────────────────────────────
chmod 000 "$TMP/home/orchestrator/orchestrator-harness-unreadable-probe.sh" 2>/dev/null
printf '#!/usr/bin/env bash\n:\n' > "$TMP/home/orchestrator/no-read.sh"; chmod 000 "$TMP/home/orchestrator/no-read.sh"
run_drift --o "$TMP/none" --surface
ck "surface: an UNREADABLE script is exit 2 / BROKEN (rc=$RC)" "$([ "$RC" -eq 2 ] && echo 0 || echo 1)"
case "$OUT" in *UNREADABLE*) ck "surface: the unreadable file is NAMED as unreadable" 0 ;; *) ck "surface: the unreadable file is NAMED as unreadable" 1 ;; esac
chmod 644 "$TMP/home/orchestrator/no-read.sh"; rm -f "$TMP/home/orchestrator/no-read.sh"

# ── (iv-f) NOTHING TO COMPARE IS NOT A PASS ──────────────────────────────────────────────────
OUT="$( cd "$TMP" && HOME="$TMP/emptyhome" CELL_HOME="$TMP/emptycell" HARNESS="" HARNESS_PIN_DIR="" \
        DRIFT_PS="$TMP/ps-stub" PS_TABLE="$TMP/ps-empty" \
        bash "$DRIFT" --repo "$REPO_FIX" --rel scripts/orchestrator-harness --no-fetch --surface --o "$TMP/none" 2>&1 )"; RC=$?
ck "surface: no candidate dir at all is exit 2, never a pass (rc=$RC)" "$([ "$RC" -eq 2 ] && echo 0 || echo 1)"

# ── (iv-g) THE RUNNING CONTROLLER's own dir is the one that matters ──────────────────────────
# The process table is supplied through the seam, in the exact shape the read matches —
# `<interp> <dir>/orch-loop.sh` — and the dir's `orch-loop.sh` carries an edit origin/main does not.
RUN_DIR="$TMP/running-harness"
mkdir -p "$RUN_DIR"
cp "$REPO_FIX/scripts/orchestrator-harness"/*.sh "$RUN_DIR/"
printf '#!/usr/bin/env bash\necho local-hotfix\n' > "$RUN_DIR/orch-loop.sh"
printf '4242 bash %s/orch-loop.sh\n' "$RUN_DIR" > "$TMP/ps-running"
PS_TABLE="$TMP/ps-running" run_drift --o "$TMP/none" --surface
ck "surface: a RUNNING component's dir that differs from origin/main refuses the pass (rc=$RC)" "$([ "$RC" -eq 1 ] && echo 0 || echo 1)"
case "$OUT" in *"the RUNNING controller executes this dir"*) ck "surface: the running dir is labelled, not just reported" 0 ;; *) ck "surface: the running dir is labelled, not just reported [$OUT]" 1 ;; esac
# A row/text that MENTIONS a controller is not a controller (the self-match class the fleet
# inventory documents): a shell running TEXT must not become a candidate dir.
printf '4243 bash -c echo-bash-%s/orch-loop.sh\n' "$RUN_DIR" > "$TMP/ps-text"
PS_TABLE="$TMP/ps-text" run_drift --o "$TMP/none" --surface
ck "surface: a process merely MENTIONING a path is not a controller dir (rc=$RC)" "$([ "$RC" -eq 0 ] && echo 0 || echo 1)"

# ── (iv-h) A CENSUS THAT COULD NOT BE READ IS BROKEN, NOT A WARNING ─────────────────────────
# The running controller's dir is the population `--surface` exists for. A `ps` that fails used to be
# a WARNING (`problems` untouched) → "OK" and exit 0 having compared nothing that executes. The stub
# exits 1 with no output, which is what a restricted/BSD-differing `ps` does here.
printf '#!/bin/sh\nexit 1\n' > "$TMP/ps-broken"; chmod +x "$TMP/ps-broken"
OUT="$( cd "$TMP" && HOME="$TMP/home" CELL_HOME="$TMP/cell" HARNESS_PIN_DIR="$TMP/cell/harness" \
        HARNESS="$TMP/home/orchestrator" DRIFT_PS="$TMP/ps-broken" \
        bash "$DRIFT" --repo "$REPO_FIX" --rel scripts/orchestrator-harness --no-fetch --surface --o "$TMP/none" 2>&1 )"; RC=$?
ck "surface: an UNREADABLE process table is exit 2 (rc=$RC), never a warning over a clean pass" "$([ "$RC" -eq 2 ] && echo 0 || echo 1)"
case "$OUT" in *"RUNNING controller"*) ck "surface: the unreadable table is SAID to leave the running dir unverified" 0 ;; *) ck "surface: the unreadable table is SAID to leave the running dir unverified [$OUT]" 1 ;; esac

# ── (iv-i) A BOX WITH NO RECORD STILL GETS THE SURFACE ANSWER ────────────────────────────────
# `$O` exists but carries no `.agent-infra-stamp.json` — the hand-placed-copy class. Before the fix the
# stamp check exited 2 BEFORE the surface pass, so the one population this half was written for got no
# answer at all. The record halves must say SKIPPED (never OK) and the surface pass must still run.
NOSHIM="$TMP/no-record-orch"
mkdir -p "$NOSHIM"
cp "$REPO_FIX/scripts/orchestrator-harness"/*.sh "$NOSHIM/"
printf '#!/usr/bin/env bash\necho hand-placed\n' > "$NOSHIM/orch-loop.sh"
OUT="$( cd "$TMP" && HOME="$TMP/emptyhome2" CELL_HOME="$TMP/emptycell2" HARNESS="" HARNESS_PIN_DIR="" \
        DRIFT_PS="$TMP/ps-stub" PS_TABLE="$TMP/ps-empty" \
        bash "$DRIFT" --repo "$REPO_FIX" --rel scripts/orchestrator-harness --no-fetch --surface --o "$NOSHIM" 2>&1 )"; RC=$?
case "$OUT" in *"no harness record at"*SKIPPED*|*SKIPPED*"no harness record at"*) ck "surface: with NO record the identity half says SKIPPED, not a refusal" 0 ;; *) ck "surface: with NO record the identity half says SKIPPED, not a refusal [$(printf '%s' "$OUT" | tr '\n' ' ' | cut -c1-300)]" 1 ;; esac
ck "surface: with NO record the surface answer is still delivered (rc=$RC, not the 2 of the stamp gate)" "$([ "$RC" -ne 2 ] && echo 0 || echo 1)"
case "$OUT" in *"orch-loop.sh"*) ck "surface: with NO record the diverging script is still NAMED" 0 ;; *) ck "surface: with NO record the diverging script is still NAMED" 1 ;; esac

# ── (iv-j) AN UNLISTABLE CANDIDATE DIR IS BROKEN, NEVER SKIPPED ─────────────────────────────
# `ls *.sh` fails both for "no .sh files at all" and for "cannot read this directory", and treating the
# two alike DROPS the dir: the run prints OK having compared nothing in it. `chmod 111` (traverse, no
# read) is the measured shape — a harness copy carrying a local edit that no verdict ever mentioned.
UNLIS="$TMP/unlistable-harness"
mkdir -p "$UNLIS"
printf '#!/usr/bin/env bash\necho hidden-local-edit\n' > "$UNLIS/claims.sh"
chmod 111 "$UNLIS"
OUT="$( cd "$TMP" && HOME="$TMP/emptyhome3" CELL_HOME="$TMP/emptycell3" HARNESS="$UNLIS" HARNESS_PIN_DIR="" \
        DRIFT_PS="$TMP/ps-stub" PS_TABLE="$TMP/ps-empty" \
        bash "$DRIFT" --repo "$REPO_FIX" --rel scripts/orchestrator-harness --no-fetch --surface --o "$TMP/none" 2>&1 )"; RC=$?
ck "surface: an UNLISTABLE candidate dir is exit 2 (rc=$RC), never silently skipped" "$([ "$RC" -eq 2 ] && echo 0 || echo 1)"
case "$OUT" in *"cannot be LISTED"*) ck "surface: the unlistable dir is NAMED" 0 ;; *) ck "surface: the unlistable dir is NAMED [$OUT]" 1 ;; esac
chmod 755 "$UNLIS" 2>/dev/null

# ── (iv-l) A CANDIDATE BEHIND AN UNSEARCHABLE ANCESTOR IS BROKEN TOO ─────────────────────────
# The same fail-open one level up: `-e` fails both for "absent" and for "cannot be stat'ed because a
# parent is not searchable", and dropping both let a `chmod 600` parent hide a harness copy carrying a
# local edit while the run printed OK (measured by the #2231 verifier).
HID="$TMP/hidden-gate/harness"
mkdir -p "$HID"
printf '#!/usr/bin/env bash\necho hidden-local-edit\n' > "$HID/claims.sh"
chmod 600 "$TMP/hidden-gate"
OUT="$( cd "$TMP" && HOME="$TMP/emptyhome4" CELL_HOME="$TMP/emptycell4" HARNESS="$HID" HARNESS_PIN_DIR="" \
        DRIFT_PS="$TMP/ps-stub" PS_TABLE="$TMP/ps-empty" \
        bash "$DRIFT" --repo "$REPO_FIX" --rel scripts/orchestrator-harness --no-fetch --surface --o "$TMP/none" 2>&1 )"; RC=$?
ck "surface: a candidate behind an unsearchable ancestor is exit 2 (rc=$RC), never skipped" "$([ "$RC" -eq 2 ] && echo 0 || echo 1)"
case "$OUT" in *"not searchable"*) ck "surface: the unsearchable ancestor is NAMED" 0 ;; *) ck "surface: the unsearchable ancestor is NAMED [$(printf '%s' "$OUT" | tr '\n' ' ' | cut -c1-260)]" 1 ;; esac
chmod 755 "$TMP/hidden-gate" 2>/dev/null

# ── (iv-m) TWO LEVELS DEEP, AND AN UNEXAMINABLE `$O` ─────────────────────────────────────────
# `dirname` alone fixed only the one-level case; the class is "the path cannot be examined", at any
# depth, and `$O` itself is subject to it. Both shapes were measured fail-open on the previous round.
DEEP="$TMP/deep-gate/level/harness"
mkdir -p "$DEEP"
printf '#!/usr/bin/env bash\necho deep-local-edit\n' > "$DEEP/claims.sh"
chmod 600 "$TMP/deep-gate"
OUT="$( cd "$TMP" && HOME="$TMP/emptyhome5" CELL_HOME="$TMP/emptycell5" HARNESS="$DEEP" HARNESS_PIN_DIR="" \
        DRIFT_PS="$TMP/ps-stub" PS_TABLE="$TMP/ps-empty" \
        bash "$DRIFT" --repo "$REPO_FIX" --rel scripts/orchestrator-harness --no-fetch --surface --o "$TMP/none" 2>&1 )"; RC=$?
ck "surface: a candidate TWO levels under an unsearchable dir is exit 2 (rc=$RC)" "$([ "$RC" -eq 2 ] && echo 0 || echo 1)"
OUT="$( cd "$TMP" && HOME="$TMP/emptyhome5" CELL_HOME="$TMP/emptycell5" HARNESS="" HARNESS_PIN_DIR="" \
        DRIFT_PS="$TMP/ps-stub" PS_TABLE="$TMP/ps-empty" \
        bash "$DRIFT" --repo "$REPO_FIX" --rel scripts/orchestrator-harness --no-fetch --surface --o "$DEEP" 2>&1 )"; RC=$?
ck "surface: an UNEXAMINABLE \$O is exit 2 (rc=$RC), never reported as 'no deployed harness'" "$([ "$RC" -eq 2 ] && echo 0 || echo 1)"
case "$OUT" in *"cannot be examined"*) ck "surface: the unexaminable \$O is NAMED as such" 0 ;; *) ck "surface: the unexaminable \$O is NAMED as such [$(printf '%s' "$OUT" | tr '\n' ' ' | cut -c1-260)]" 1 ;; esac
chmod 755 "$TMP/deep-gate" 2>/dev/null

# ── (iv-n) THE SYMLINK SPELLING OF THE SAME PATH ─────────────────────────────────────────────
# `-e` follows a link, so a target that cannot be stat'ed (EACCES, ELOOP, a gone volume) is
# indistinguishable from a dangling one — and the run printed OK over a harness copy carrying a local
# edit that this box NAMES as the dir its controller reads (measured, round 4).
mkdir -p "$TMP/linkpriv/harness"
printf '#!/usr/bin/env bash\necho linked-local-edit\n' > "$TMP/linkpriv/harness/claims.sh"
ln -s "$TMP/linkpriv/harness" "$TMP/harness-link"
chmod 600 "$TMP/linkpriv"
OUT="$( cd "$TMP" && HOME="$TMP/emptyhome6" CELL_HOME="$TMP/emptycell6" \
        HARNESS="$TMP/harness-link" HARNESS_PIN_DIR="" \
        DRIFT_PS="$TMP/ps-stub" PS_TABLE="$TMP/ps-empty" \
        bash "$DRIFT" --repo "$REPO_FIX" --rel scripts/orchestrator-harness --no-fetch --surface --o "$TMP/none" 2>&1 )"; RC=$?
ck "surface: a harness named through a link into an unsearchable dir is exit 2 (rc=$RC)" "$([ "$RC" -eq 2 ] && echo 0 || echo 1)"
chmod 755 "$TMP/linkpriv" 2>/dev/null
# A self-referential link is the same class (ELOOP): it must not read as "nothing to report" either.
ln -s "$TMP/loop-b" "$TMP/loop-a"; ln -s "$TMP/loop-a" "$TMP/loop-b"
OUT="$( cd "$TMP" && HOME="$TMP/emptyhome6" CELL_HOME="$TMP/emptycell6" \
        HARNESS="$TMP/loop-a" HARNESS_PIN_DIR="" \
        DRIFT_PS="$TMP/ps-stub" PS_TABLE="$TMP/ps-empty" \
        bash "$DRIFT" --repo "$REPO_FIX" --rel scripts/orchestrator-harness --no-fetch --surface --o "$TMP/none" 2>&1 )"; RC=$?
ck "surface: a self-referential harness link is exit 2 (rc=$RC)" "$([ "$RC" -eq 2 ] && echo 0 || echo 1)"
# …and the SAME rule at depth: a looping component in the MIDDLE of the path (exit 2 at depth 0, exit 0
# one level down, before the walk applied the link rule to every component).
OUT="$( cd "$TMP" && HOME="$TMP/emptyhome6" CELL_HOME="$TMP/emptycell6" \
        HARNESS="$TMP/loop-a/harness" HARNESS_PIN_DIR="" \
        DRIFT_PS="$TMP/ps-stub" PS_TABLE="$TMP/ps-empty" \
        bash "$DRIFT" --repo "$REPO_FIX" --rel scripts/orchestrator-harness --no-fetch --surface --o "$TMP/none" 2>&1 )"; RC=$?
ck "surface: a looping symlink in the MIDDLE of the path is exit 2 (rc=$RC)" "$([ "$RC" -eq 2 ] && echo 0 || echo 1)"
# …and the TRAILING-SLASH spelling of the same path: `-L /x/link` is true, `-L /x/link/` is FALSE, so a
# leaf-only link rule answered "absent" for `O=~/orchestrator/` (tab completion's spelling) and the run
# printed a clean pass. Both spellings must answer the same way.
for _spell in "$TMP/loop-a" "$TMP/loop-a/"; do
  OUT="$( cd "$TMP" && HOME="$TMP/emptyhome6" CELL_HOME="$TMP/emptycell6" HARNESS="" HARNESS_PIN_DIR="" \
          DRIFT_PS="$TMP/ps-stub" PS_TABLE="$TMP/ps-empty" \
          bash "$DRIFT" --repo "$REPO_FIX" --rel scripts/orchestrator-harness --no-fetch --surface --o "$_spell" 2>&1 )"; RC=$?
  ck "surface: the -o spelling '$_spell' is exit 2, never a clean pass (rc=$RC)" "$([ "$RC" -eq 2 ] && echo 0 || echo 1)"
done
# ── (iv-o) A PIN-ROOT CHILD IS A CANDIDATE TOO ───────────────────────────────────────────────
# The pin root is one worktree per pinned commit. A child that cannot be examined (a gone mount, a
# looping link) was filtered out by `[ -d ] || continue` before any verdict, so a pinned commit the box
# cannot read produced a clean pass (round 7). Both shapes below are pin children.
PINS="$TMP/pins"
mkdir -p "$PINS/aaaa1111"
cp "$REPO_FIX/scripts/orchestrator-harness/"*.sh "$PINS/aaaa1111/"
ln -s "$TMP/gone-mount/scripts" "$PINS/bbbb2222"                       # a dangling pin child
mkdir -p "$PINS/cccc3333/scripts"
ln -s "$TMP/gone-mount/orchestrator-harness" "$PINS/cccc3333/scripts/orchestrator-harness"
for _p in bbbb2222 cccc3333; do
  OUT="$( cd "$TMP" && HOME="$TMP/emptyhome7" CELL_HOME="$TMP/emptycell7" HARNESS="" \
          HARNESS_PIN_DIR="$PINS" DRIFT_PS="$TMP/ps-stub" PS_TABLE="$TMP/ps-empty" \
          bash "$DRIFT" --repo "$REPO_FIX" --rel scripts/orchestrator-harness --no-fetch --surface --o "$TMP/none" 2>&1 )"; RC=$?
  ck "surface: pin child $_p that cannot be examined is exit 2 (rc=$RC)" "$([ "$RC" -eq 2 ] && echo 0 || echo 1)"
done
case "$OUT" in *"pin-root child"*) ck "surface: the unexaminable pin child is NAMED" 0 ;; *) ck "surface: the unexaminable pin child is NAMED [$(printf '%s' "$OUT" | tr '\n' ' ' | cut -c1-240)]" 1 ;; esac

# ── (iv-p) THE PIN *FILE* IS A RECORD TOO ────────────────────────────────────────────────────
# It is the only record that names a read dir OUTSIDE the pin root (the #2216 shape), so an unreadable
# or unexaminable one may not read as "no pin record": that dropped the named tree and printed OK.
PF="$TMP/pin-file-unreadable"
printf '%s\n' "$TMP/pin-target" > "$PF"
mkdir -p "$TMP/pin-target" "$TMP/pinpriv"
printf '%s\n' "$TMP/pin-target" > "$TMP/pinpriv/pinfile"
chmod 000 "$PF"; chmod 600 "$TMP/pinpriv"
for _pf in "$PF" "$TMP/pinpriv/pinfile" "$TMP/pin-loop-a"; do
  ln -sfn "$TMP/pin-back" "$TMP/pin-loop-a" 2>/dev/null; ln -sfn "$TMP/pin-loop-a" "$TMP/pin-back" 2>/dev/null
  OUT="$( cd "$TMP" && HOME="$TMP/emptyhome8" CELL_HOME="$TMP/emptycell8" HARNESS="" \
          HARNESS_PIN_DIR="" HARNESS_PIN_FILE="$_pf" \
          DRIFT_PS="$TMP/ps-stub" PS_TABLE="$TMP/ps-empty" \
          bash "$DRIFT" --repo "$REPO_FIX" --rel scripts/orchestrator-harness --no-fetch --surface --o "$TMP/none" 2>&1 )"; RC=$?
  ck "surface: an unexaminable pin DIR record ('$_pf') is exit 2 (rc=$RC)" "$([ "$RC" -eq 2 ] && echo 0 || echo 1)"
done
chmod 644 "$PF" 2>/dev/null; chmod 755 "$TMP/pinpriv" 2>/dev/null

# ── (iii) PORTABILITY of the three helpers ───────────────────────────────────────────────────
# The helpers are EXTRACTED from the shipped file by their own markers — there is exactly one copy of
# them, and this suite drives that copy.
sed -n '/^# >>> helpers$/,/^# <<< helpers$/p' "$UP" > "$TMP/helpers.sh"
ck "the helper block is extractable from the shipped launcher" "$([ -s "$TMP/helpers.sh" ] && echo 0 || echo 1)"

# ── (iv-k) THE FILE AGE HELPER SURVIVES BOTH `stat` DIALECTS ───────────────────────────────
# GNU `stat -f %m <file>` prints the filesystem block to STDOUT and exits 1, so a `||` fallback appends
# its epoch to that block: the age is non-numeric on EVERY file, and a healthy Linux cell reads
# VERDICT: BROKEN right after a successful start (found by the #2231 verifier). The shim reproduces the
# GNU shape exactly; the helper must still answer a number. The file it is asked about is the shim
# itself — present by construction at this point, and stat-able.
mkdir -p "$TMP/gnubin"
cat > "$TMP/gnubin/stat" <<'GNUSTAT'
#!/bin/sh
# GNU as the helper could meet it: `-c %Y` answers the epoch; `-f %m` (BSD syntax) prints the
# filesystem block to STDOUT and exits 1 — the shape that contaminated the fallback's answer.
case "$*" in *"-c %Y"*) exec /usr/bin/stat -c %Y "$3" ;; esac
echo "  File: $3"
echo "    ID: 1234 Namelen: 255 Type: ext2/ext3"
exit 1
GNUSTAT
chmod +x "$TMP/gnubin/stat"
AGE="$( PATH="$TMP/gnubin:$PATH"; . "$TMP/helpers.sh"; hu_file_age "$TMP/gnubin/stat" 2>/dev/null )"
case "$AGE" in ''|*[!0-9]*) ck "portability: hu_file_age reads a GNU-shaped stat (got '${AGE:-nothing}')" 1 ;; *) ck "portability: hu_file_age reads a GNU-shaped stat (got ${AGE}s)" 0 ;; esac

# ⛔ SCAN THE CODE, NOT THE PROSE. The launcher DOCUMENTS the two prohibitions (a `#` comment saying
# never to call `gh auth token`, and the `--timeout` flag in its usage), so a whole-file substring
# scan fails on its own documentation — measured, that is exactly how this assertion first reddened.
# Whole-line comments are dropped; what remains is what would execute.
grep -v '^[[:space:]]*#' "$UP" > "$TMP/up-code.sh"
if grep -q 'gh auth token' "$TMP/up-code.sh"; then
  ck "the launcher never calls \`gh auth token\` (rc=142 hang, and it prints the credential)" 1
else
  ck "the launcher never calls \`gh auth token\` (rc=142 hang, and it prints the credential)" 0
fi
# A SHAPE ASSERTION, and the only hermetic one available: `--heads` restricts `ls-remote` to
# `refs/heads/*`, so `refs/claims/*` can never match and the claims row would report an empty registry
# on every box (measured in review). A behavioural assertion needs a real claim ref on a remote; the
# negative shape is what a regression re-introduces, so it is pinned here, and the verdict path
# (absent/reachable) is asserted through the row.
if grep -q 'ls-remote --heads' "$TMP/up-code.sh"; then
  ck "the claims probe is NOT restricted to refs/heads (it would never see refs/claims/*)" 1
else
  ck "the claims probe is NOT restricted to refs/heads (it would never see refs/claims/*)" 0
fi
# A `timeout`/`gtimeout` in COMMAND POSITION (start of line, or after a separator). `--timeout` is a
# flag name, not an invocation, and conflating them is how this assertion first false-failed.
if grep -Eq '(^|[;&|][[:space:]]*)(timeout|gtimeout)([[:space:]]|$)' "$TMP/up-code.sh"; then
  ck "the launcher carries no \`timeout\`/\`gtimeout\` invocation" 1
else
  ck "the launcher carries no \`timeout\`/\`gtimeout\` invocation" 0
fi

# A "macOS-like" PATH: the two commands macOS lacks are ABSENT (a shim that records being called and
# fails loudly), and `pgrep` exists but has no `-c` — exactly the BSD shape. On this Linux cell those
# real binaries exist, so the shims are what make the two regimes distinguishable.
mkdir -p "$TMP/macbin" "$TMP/linuxbin"
for d in macbin linuxbin; do
  for c in bash sh perl ps sleep date stat sed awk head grep wc tr cut basename dirname mktemp; do
    real="$(command -v "$c" 2>/dev/null)" || continue
    ln -sf "$real" "$TMP/$d/$c"
  done
done
# The absence shims live in the mac regime and in BOTH regimes for `pgrep`: any use is recorded.
printf '#!/bin/sh\n: > "$SHIM_LOG.timeout"\necho "timeout: must not be called" >&2\nexit 99\n' > "$TMP/macbin/timeout"
printf '#!/bin/sh\n: > "$SHIM_LOG.gtimeout"\nexit 99\n' > "$TMP/macbin/gtimeout"
printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = "-c" ] && { : > "$SHIM_LOG.pgrep-c"; echo "pgrep: illegal option -- c" >&2; exit 2; }; done\nexit 3\n' > "$TMP/macbin/pgrep"
cp "$TMP/macbin/pgrep" "$TMP/linuxbin/pgrep"
# Only the SHIMS need the executable bit — the rest of each dir is symlinks to real binaries, and
# `chmod +x` on a symlink targets its TARGET (which is not ours to chmod).
chmod +x "$TMP/macbin/timeout" "$TMP/macbin/gtimeout" "$TMP/macbin/pgrep" "$TMP/linuxbin/pgrep"

# The hanging-`gh` stub is built OUTSIDE the probe: inside it the PATH is the restricted regime under
# test, where `mkdir`/`cp`/`chmod` are deliberately absent (using them there made the stub silently
# not exist, and the probe then answered "gh absent" instead of "gh was bounded").
mkdir -p "$TMP/hangbin"
printf '#!/bin/sh\nsleep 30\n' > "$TMP/hangbin/gh"; chmod +x "$TMP/hangbin/gh"
# The census stub, built here for the same reason: `hu_pids` reads `ps -eo pid=,command=` through the
# `HU_PS` seam, and a suite that reads the BOX's own process table is asserting something about the
# developer's machine (it reddens wherever `ps` is restricted, and it proves nothing about the parse).
mkdir -p "$TMP/psbin"
printf '#!/bin/sh\nprintf "%%s\\n" "4242 bash %s" "4243 sh -c echo %s" "4244 bash /other/script.sh"\n' \
  "$TMP/probe-target.sh" "$TMP/probe-target.sh" > "$TMP/psbin/ps"; chmod +x "$TMP/psbin/ps"

helper_probe() { # <bindir> <shimlog>
  local bin="$1" log="$2"
  (
    PATH="$bin"; export PATH
    SHIM_LOG="$log"; export SHIM_LOG
    HU_BOUND_DEFAULT=5; HU_GH_TIMEOUT=1; HU_PS="$TMP/psbin/ps"; export HU_BOUND_DEFAULT HU_GH_TIMEOUT HU_PS
    . "$TMP/helpers.sh"
    # (1) hu_bounded: a bound that FIRES must be 142, and it must fire without `timeout`.
    hu_bounded 1 sleep 30 >/dev/null 2>&1; printf 'bounded_rc=%s\n' "$?"
    # (2) hu_pids: matches by ARGV SHAPE against a supplied table — process 4242 (the interp+path pair)
    # counts, 4243 (the path inside `sh -c`) must NOT, because a shell whose TEXT mentions the script
    # is not a process running it. That distinction is the whole reason `pgrep -f` is refused.
    printf 'pids=%s\n' "$(hu_pids "$TMP/probe-target.sh" 2>/dev/null | tr '\n' ',')"
    # (3) hu_gh_probe: a HANGING gh is bounded, and the bound is what answers.
    PATH="$TMP/hangbin:$bin"; export PATH
    hu_gh_probe 1 >/dev/null 2>&1; printf 'gh_rc=%s\n' "$?"
  )
}
printf '#!/bin/sh\nsleep 10\n' > "$TMP/probe-target.sh"
MAC_OUT="$(helper_probe "$TMP/macbin" "$TMP/shim-mac")"
LINUX_OUT="$(helper_probe "$TMP/linuxbin" "$TMP/shim-linux")"
# The bound fired on both (142), the census matched the ARGV pair on both, and the hanging gh was cut
# off on both (142) — the SAME answers, which is the property that matters.
case "$MAC_OUT" in *bounded_rc=142*) ck "portability/mac: hu_bounded enforces the bound (142)" 0 ;; *) ck "portability/mac: hu_bounded enforces the bound (142) [$MAC_OUT]" 1 ;; esac
case "$LINUX_OUT" in *bounded_rc=142*) ck "portability/linux: hu_bounded enforces the bound (142)" 0 ;; *) ck "portability/linux: hu_bounded enforces the bound (142) [$LINUX_OUT]" 1 ;; esac
# ⛔ THE NEGATIVE HALF IS THE ASSERTION: 4242 is the `bash <path>` pair and must be reported; 4243 is a
# shell whose TEXT mentions the same path and must NOT be. A census that returned both would be the
# `pgrep -f` bug this helper exists to avoid, and it would still "find a process".
# ⛔ EXACT, not `*pids=4242,*` — that pattern also matches `pids=4242,4243,`, i.e. it passes when the
# text-mention process IS wrongly returned. Measured: a substring-match mutant (the exact `pgrep -f`
# bug the helper exists to avoid) shipped green under the loose pattern.
m_pids="$(printf '%s' "$MAC_OUT" | sed -n 's/^pids=\(.*\)$/\1/p')"
l_pids="$(printf '%s' "$LINUX_OUT" | sed -n 's/^pids=\(.*\)$/\1/p')"
ck "portability/mac: hu_pids returns EXACTLY 4242 (got '$m_pids'), never the text mention" "$([ "$m_pids" = "4242," ] && echo 0 || echo 1)"
ck "portability/linux: hu_pids returns EXACTLY 4242 (got '$l_pids'), never the text mention" "$([ "$l_pids" = "4242," ] && echo 0 || echo 1)"
ck "portability: both regimes answer identically (mac=[$MAC_OUT] linux=[$LINUX_OUT])" "$([ "$MAC_OUT" = "$LINUX_OUT" ] && echo 0 || echo 1)"
for m in timeout gtimeout pgrep-c; do
  if [ -e "$TMP/shim-mac.$m" ] || [ -e "$TMP/shim-linux.$m" ]; then
    ck "portability: the helpers never reached for '$m' (a shim recorded a call)" 1
  else
    ck "portability: the helpers never reached for '$m' (a shim recorded a call)" 0
  fi
done
case "$LINUX_OUT" in *gh_rc=142*) ck "portability: a HANGING gh is bounded (142), never waited on" 0 ;; *) ck "portability: a HANGING gh is bounded (142), never waited on [$LINUX_OUT]" 1 ;; esac

# ── (i) and (ii): the launcher's gate, driven from a fixture "checkout" ───────────────────────
# A fixture layout is the only honest way to drive the launcher: it resolves its SIBLINGS (the
# platform authorities) and its harness dir from its own path, so a stub beside a copy of the shipped
# file exercises the shipping code with the delegation stubbed — and nothing real is started.
mkfix() { # <name> -> prints the fixture root
  local r="$TMP/$1"
  mkdir -p "$r/scripts/orchestrator-harness" "$r/state"
  cp "$UP" "$r/scripts/harness-up"; chmod +x "$r/scripts/harness-up"
  # The platform authority: records that it was called and how (this is what "started nothing" means).
  cat > "$r/scripts/orchestrator-bringup.sh" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  start) printf 'start\n' >> "$FIX_LOG" ;;
  stop)  printf 'stop\n'  >> "$FIX_LOG" ;;
  *)     printf '%s\n' "$*" >> "$FIX_LOG" ;;
esac
exit 0
SH
  chmod +x "$r/scripts/orchestrator-bringup.sh"
  # The harness self-tests, as the launcher names them.
  for t in check-single-source.sh selftest.sh; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$r/scripts/orchestrator-harness/$t"
    chmod +x "$r/scripts/orchestrator-harness/$t"
  done
  # The drift self-test RECORDS the HARNESS it was given: a delegation that cannot see the tree the
  # launcher resolved is silently checking a different (or no) directory.
  cat > "$r/scripts/orchestrator-harness/check-deployed-drift.sh" <<'SH'
#!/usr/bin/env bash
printf 'harness=[%s]\n' "${HARNESS:-EMPTY}" > "$FIX_LOG.drift-env"
exit 0
SH
  printf '#!/usr/bin/env bash\nprintf "harness relation=current running=deadbeef ref=deadbeef pin=deadbeef action=none fetch=ok\\n"\nexit 0\n' \
    > "$r/scripts/orchestrator-harness/harness-refresh.sh"
  printf '#!/usr/bin/env bash\n:\n' > "$r/scripts/orchestrator-harness/orch-loop.sh"
  chmod +x "$r/scripts/orchestrator-harness/"*.sh
  printf '%s\n' "$r"
}
run_up() { # <fixture> <args…>
  local r="$1"; shift
  OUT="$( cd "$TMP" && FIX_LOG="$r/fix.log" HOME="$TMP/home" CELL_HOME="$TMP/cell" \
          DRIFT_PS="$TMP/ps-stub" PS_TABLE="$TMP/ps-empty" \
          HU_PS="$TMP/ps-stub" \
          bash "$r/scripts/harness-up" up --repo "$REPO_FIX" --harness "$r/scripts/orchestrator-harness" \
          "$@" 2>&1 )"
  RC=$?
}

# (i) A FAILING SELF-TEST BLOCKS THE START, names the test, and nothing is started.
F1="$(mkfix f1)"
printf '#!/usr/bin/env bash\necho "1 failed: the red one"\nexit 1\n' > "$F1/scripts/orchestrator-harness/selftest.sh"
chmod +x "$F1/scripts/orchestrator-harness/selftest.sh"
run_up "$F1"
ck "self-test gate: a failing selftest REFUSES the start with the documented rc=3 (rc=$RC)" "$([ "$RC" -eq 3 ] && echo 0 || echo 1)"
case "$OUT" in *"selftest FAILED: selftest.sh"*) ck "self-test gate: the FAILING TEST IS NAMED" 0 ;; *) ck "self-test gate: the FAILING TEST IS NAMED [$OUT]" 1 ;; esac
ck "self-test gate: nothing was started (no authority call)" "$([ ! -s "$F1/fix.log" ] && echo 0 || echo 1)"

# (ii-a) THE PIN IS NOT MATERIALISED — the tree it names does not exist. Refused, nothing started.
F2="$(mkfix f2)"
mkdir -p "$TMP/cell/.pi/agent/state"
( printf '%s\n' "$(cd "$REPO_FIX" && git rev-parse HEAD)" > "$TMP/cell/.pi/agent/state/HARNESS-PIN" )
mkdir -p "$TMP/cell/harness"
OUT="$( cd "$TMP" && FIX_LOG="$F2/fix.log" HOME="$TMP/home" CELL_HOME="$TMP/cell" \
        bash "$F2/scripts/harness-up" up --repo "$REPO_FIX" --harness "$F2/scripts/orchestrator-harness" 2>&1 )"; RC=$?
ck "(ii) an unmaterialised pin dir REFUSES the start with the documented rc=3 (rc=$RC)" "$([ "$RC" -eq 3 ] && echo 0 || echo 1)"
case "$OUT" in *"NOT MATERIALISED"*) ck "(ii) the refusal names the pin dir it expected" 0 ;; *) ck "(ii) the refusal names the pin dir it expected [$OUT]" 1 ;; esac
ck "(ii) nothing was started" "$([ ! -s "$F2/fix.log" ] && echo 0 || echo 1)"

# (ii-b) THE #2216 SHAPE: the pin resolves inside the pin root, but the controller READS a different
# tree (a home-dir copy). A re-pin would create a worktree nobody reads — refused, by name.
F3="$(mkfix f3)"
mkdir -p "$TMP/cell2/.pi/agent/state" "$TMP/cell2/harness"
PINSHA="$(cd "$REPO_FIX" && git rev-parse HEAD)"
printf '%s\n' "$PINSHA" > "$TMP/cell2/.pi/agent/state/HARNESS-PIN"
mkdir -p "$TMP/cell2/harness/${PINSHA:0:12}/scripts/orchestrator-harness"
cp "$F3/scripts/orchestrator-harness/"*.sh "$TMP/cell2/harness/${PINSHA:0:12}/scripts/orchestrator-harness/"
# …while the DIR RECORD names a home-dir copy, which is what the controller would exec.
mkdir -p "$TMP/cell2/home-read-harness"
cp "$F3/scripts/orchestrator-harness/"*.sh "$TMP/cell2/home-read-harness/"
printf '%s\n' "$TMP/cell2/home-read-harness" > "$TMP/cell2/.harness-path"
OUT="$( cd "$TMP" && FIX_LOG="$F3/fix.log" HOME="$TMP/home" CELL_HOME="$TMP/cell2" \
        HARNESS_PIN_DIR="$TMP/cell2/harness" HARNESS_PIN_FILE="$TMP/cell2/.harness-path" \
        bash "$F3/scripts/harness-up" up --repo "$REPO_FIX" 2>&1 )"; RC=$?
ck "(ii) a read dir that is NOT the pin's tree is REFUSED with rc=3 (rc=$RC)" "$([ "$RC" -eq 3 ] && echo 0 || echo 1)"
case "$OUT" in *MISMATCH*) ck "(ii) the refusal says MISMATCH and names both paths" 0 ;; *) ck "(ii) the refusal says MISMATCH and names both paths [$OUT]" 1 ;; esac
ck "(ii) nothing was started in the mismatch case" "$([ ! -s "$F3/fix.log" ] && echo 0 || echo 1)"

# (ii-c) the SAME tree named by both records is accepted, and the components start IN ORDER.
F4="$(mkfix f4)"
CELL4="$TMP/cell4"
mkdir -p "$CELL4/.pi/agent/state" "$CELL4/harness/${PINSHA:0:12}/scripts/orchestrator-harness"
printf '%s\n' "$PINSHA" > "$CELL4/.pi/agent/state/HARNESS-PIN"
cp "$F4/scripts/orchestrator-harness/"*.sh "$CELL4/harness/${PINSHA:0:12}/scripts/orchestrator-harness/"
printf '%s\n' "$CELL4/harness/${PINSHA:0:12}/scripts/orchestrator-harness" > "$CELL4/.harness-path"
OUT="$( cd "$TMP" && FIX_LOG="$F4/fix.log" HOME="$TMP/home" CELL_HOME="$CELL4" \
        HARNESS_PIN_DIR="$CELL4/harness" HARNESS_PIN_FILE="$CELL4/.harness-path" \
        HU_CLAIMS_TIMEOUT=5 \
        bash "$F4/scripts/harness-up" up --repo "$REPO_FIX" 2>&1 )"; RC=$?
# The documented happy-path code, not merely "it did not crash": 0 HEALTHY / 1 DEGRADED / 2 BROKEN.
ck "a matching pin + read dir starts and reports a verdict (rc=$RC, documented 0|1)" "$([ "$RC" -le 1 ] && echo 0 || echo 1)"
case "$OUT" in *"pin: OK"*) ck "(ii) a matching pin + read dir is accepted" 0 ;; *) ck "(ii) a matching pin + read dir is accepted [$OUT]" 1 ;; esac
n4="$(grep -c '^start$' "$F4/fix.log" 2>/dev/null || echo 0)"
ck "start order: the controller authority was invoked exactly once (n=$n4)" "$([ "$n4" -eq 1 ] && echo 0 || echo 1)"
# Diagnostics print ONLY on failure: a suite that always prints its fixtures is a suite whose output
# nobody reads.
[ "$n4" -eq 1 ] || printf '    (F4 authority log: %s)\n' "$(tr '\n' ' ' < "$F4/fix.log" 2>/dev/null)"
# The order is declared in ONE place and the walk follows it: refresh is attempted before the loop.
case "$OUT" in
  # ⛔ THE ASSERTION IS THE ORDER, NOT THE STEP NUMBER: the prefix is `N/M` so that inserting a step cannot
  # silently weaken this check (it was pinned to `3/3` and this change added a capacity step, making the
  # step 4/4 — the ORDER it exists to pin is unchanged).
  *"components, in dependency order: refresh claims loop supervisor"*) # ⛔ THE DELEGATION MUST SEE THE TREE THE LAUNCHER RESOLVED. The self-test gate is the ONLY thing that
# examines the harness before a start, and it used to receive an empty HARNESS on a pin-less box — so it
# compared nothing and still passed (measured, round 5).
# The value must be the SAME harness the launcher printed it resolved (F4 resolves it from the pin's
# DIR record, so it is the pin tree — not the checkout path), and it must never be empty.
want_h="$(printf '%s\n' "$OUT" | sed -n 's/^ *harness *: *\([^ ]*\).*/\1/p' | head -1)"
got_h="$(sed -n 's/^harness=\[\(.*\)\]$/\1/p' "$F4/fix.log.drift-env" 2>/dev/null)"
case "$got_h" in
  ''|EMPTY) ck "the drift self-test received the resolved HARNESS [got '$got_h' want '$want_h']" 1 ;;
  *) if [ "$got_h" = "$want_h" ]; then
       ck "the drift self-test received the SAME harness the launcher resolved" 0
     else
       ck "the drift self-test received the SAME harness the launcher resolved [got '$got_h' want '$want_h']" 1
     fi ;;
esac
ck "start order: the declared order is printed, refresh first" 0 ;;
  *) ck "start order: the declared order is printed, refresh first [$OUT]" 1 ;;
esac

# ── (v) AN UNREADABLE PIN RECORD IS NOT AN ABSENT ONE ────────────────────────────────────────
# `head` on a mode-000 record prints nothing, exactly like a record never written — so the pin
# "resolved" from the ref, the read dir was never compared, and the start ran (measured, round 8).
F7="$(mkfix f7)"
mkdir -p "$TMP/cell7/.pi/agent/state"
printf '%s\n' "$PINSHA" > "$TMP/cell7/.pi/agent/state/HARNESS-PIN"
chmod 000 "$TMP/cell7/.pi/agent/state/HARNESS-PIN"
OUT="$( cd "$TMP" && FIX_LOG="$F7/fix.log" HOME="$TMP/home" CELL_HOME="$TMP/cell7" \
        DRIFT_PS="$TMP/ps-stub" PS_TABLE="$TMP/ps-empty" HU_PS="$TMP/ps-stub" \
        bash "$F7/scripts/harness-up" up --repo "$REPO_FIX" --harness "$F7/scripts/orchestrator-harness" 2>&1 )"; RC=$?
ck "an UNREADABLE pin record refuses the start with rc=3 (rc=$RC)" "$([ "$RC" -eq 3 ] && echo 0 || echo 1)"
case "$OUT" in *"pin: UNREADABLE"*) ck "the refusal says the pin record is unreadable, not absent" 0 ;; *) ck "the refusal says the pin record is unreadable, not absent [$OUT]" 1 ;; esac
ck "nothing was started with an unreadable pin record" "$([ ! -s "$F7/fix.log" ] && echo 0 || echo 1)"
# …and the SAME record behind an UNSEARCHABLE ANCESTOR (the round-9 shape): `-e`/`-L` are both false
# there, so a leaf-only guard read it as "never written" and the start proceeded.
F8="$(mkfix f8)"
mkdir -p "$TMP/privrec8/.pi/agent/state"
printf '%s\n' "$PINSHA" > "$TMP/privrec8/.pi/agent/state/HARNESS-PIN"
chmod 600 "$TMP/privrec8/.pi/agent/state"
OUT="$( cd "$TMP" && FIX_LOG="$F8/fix.log" HOME="$TMP/home" CELL_HOME="$TMP/privrec8" \
        DRIFT_PS="$TMP/ps-stub" PS_TABLE="$TMP/ps-empty" HU_PS="$TMP/ps-stub" \
        bash "$F8/scripts/harness-up" up --repo "$REPO_FIX" --harness "$F8/scripts/orchestrator-harness" 2>&1 )"; RC=$?
ck "a pin record behind an unsearchable ancestor refuses the start (rc=$RC)" "$([ "$RC" -eq 3 ] && echo 0 || echo 1)"
case "$OUT" in *"pin: UNEXAMINABLE"*) ck "the refusal says the pin record cannot be examined" 0 ;; *) ck "the refusal says the pin record cannot be examined [$OUT]" 1 ;; esac
ck "nothing was started when the pin record could not be examined" "$([ ! -s "$F8/fix.log" ] && echo 0 || echo 1)"
chmod 755 "$TMP/privrec8/.pi/agent/state" 2>/dev/null

chmod 644 "$TMP/cell7/.pi/agent/state/HARNESS-PIN" 2>/dev/null

# ── (vi) DRIFT IS REPORTED, NOT REFUSED (the recorded decision) ─────────────────────────────
# `orchestrator-bringup.sh:563-567`: `start` DEPLOYS the harness, so "the deployed copy differs" is the
# state a start repairs; refusing it would false-block the only command that fixes it. Exit 1 is
# reported and the walk continues; exit 2 (cannot-verify) still refuses.
F6="$(mkfix f6)"; CELL6="$TMP/cell6"   # its own CELL_HOME: no pin machinery, so the drift gate is what runs
printf '#!/usr/bin/env bash\necho "DRIFT: something differs"\nexit 1\n' > "$F6/scripts/orchestrator-harness/check-deployed-drift.sh"
chmod +x "$F6/scripts/orchestrator-harness/check-deployed-drift.sh"
OUT="$( cd "$TMP" && FIX_LOG="$F6/fix.log" HOME="$TMP/home" CELL_HOME="$CELL6" \
        DRIFT_PS="$TMP/ps-stub" PS_TABLE="$TMP/ps-empty" HU_PS="$TMP/ps-stub" \
        bash "$F6/scripts/harness-up" up --repo "$REPO_FIX" --harness "$F6/scripts/orchestrator-harness" 2>&1 )"; RC=$?
case "$OUT" in *"reports DRIFT"*) ck "a DRIFT self-test is REPORTED, not swallowed" 0 ;; *) ck "a DRIFT self-test is REPORTED, not swallowed [$(printf '%s' "$OUT" | tr '\n' ' ' | cut -c1-200)]" 1 ;; esac
ck "a DRIFT self-test does not refuse the start (rc=$RC, not 3)" "$([ "$RC" -ne 3 ] && echo 0 || echo 1)"
ck "the walk continued past the DRIFT self-test (authority invoked)" "$([ -s "$F6/fix.log" ] && echo 0 || echo 1)"
printf '#!/usr/bin/env bash\necho "UNKNOWN: cannot verify"\nexit 2\n' > "$F6/scripts/orchestrator-harness/check-deployed-drift.sh"
OUT="$( cd "$TMP" && FIX_LOG="$F6/fix2.log" HOME="$TMP/home" CELL_HOME="$CELL6" \
        DRIFT_PS="$TMP/ps-stub" PS_TABLE="$TMP/ps-empty" HU_PS="$TMP/ps-stub" \
        bash "$F6/scripts/harness-up" up --repo "$REPO_FIX" --harness "$F6/scripts/orchestrator-harness" 2>&1 )"; RC=$?
ck "a CANNOT-VERIFY drift self-test still refuses the start (rc=$RC)" "$([ "$RC" -eq 3 ] && echo 0 || echo 1)"
ck "nothing was started when the drift check could not verify" "$([ ! -s "$F6/fix2.log" ] && echo 0 || echo 1)"

# ── (vii) THE CLAIMS ROW, AND THE REFRESH RECORD'S SHAPE ─────────────────────────────────────
# Both were asserted only by their own comments in the first revision. The claims row must answer for a
# box started by ANY path (probe when there is no record; LATE when the record is old), and the refresh
# record must be written in the CONTROLLER's canonical shape — the `fetch=` field is what makes a
# `--no-fetch` comparison cannot-verify rather than fresh.
F9="$(mkfix f9)"; CELL9="$TMP/cell9"
OUT="$( cd "$TMP" && FIX_LOG="$F9/fix.log" HOME="$TMP/home" CELL_HOME="$CELL9" HU_PS="$TMP/ps-stub" \
        DRIFT_PS="$TMP/ps-stub" PS_TABLE="$TMP/ps-empty" REPO="$REPO_FIX" \
        bash "$F9/scripts/harness-up" status --repo "$REPO_FIX" --harness "$F9/scripts/orchestrator-harness" 2>&1 )"; RC=$?
# ⛔ THE ASSERTION IS ANCHORED TO THE CLAIMS ROW. `*"claims"*"OK ("*` matches anywhere in the output, so
# the capacity row's `OK (lanes=…)` kept it green while the claims row itself read `UNKNOWN` — a masked
# false green (measured in review). The row is extracted first and matched alone.
claims_row9="$(printf '%s\n' "$OUT" | grep -E '^claims[[:space:]]' | head -1)"
case "$claims_row9" in
  *"OK ("*) ck "claims row: with NO record it PROBES and answers (not BROKEN)" 0 ;;
  *) ck "claims row: with NO record it PROBES and answers (not BROKEN) [$claims_row9]" 1 ;;
esac
# an AGED record is LATE, not OK: a stale "reachable" speaks about a probe nobody repeated
mkdir -p "$CELL9/orchestrator/state"; printf 'claims=reachable at=1\n' > "$CELL9/orchestrator/state/harness-claims"
# the AGE is the file's mtime (that is what the row measures), so backdate it portably
touch -t 202001010000 "$CELL9/orchestrator/state/harness-claims" 2>/dev/null
OUT="$( cd "$TMP" && FIX_LOG="$F9/fix.log" HOME="$TMP/home" CELL_HOME="$CELL9" HU_PS="$TMP/ps-stub" \
        DRIFT_PS="$TMP/ps-stub" PS_TABLE="$TMP/ps-empty" HARNESS_UP_CLAIMS_STALE=1 REPO="$REPO_FIX" \
        bash "$F9/scripts/harness-up" status --repo "$REPO_FIX" --harness "$F9/scripts/orchestrator-harness" 2>&1 )"; RC=$?
claims_row9b="$(printf '%s\n' "$OUT" | grep -E '^claims[[:space:]]' | head -1)"
case "$claims_row9b" in *LATE*) ck "claims row: an AGED record is LATE, never OK" 0 ;; *) ck "claims row: an AGED record is LATE, never OK [$claims_row9b]" 1 ;; esac
# ⛔ AND A `notprobed` RECORD NEVER AGES INTO `LATE`. "No target here" is NOT-APPLICABLE: there is no
# probe whose age could mean anything, so the row must say SKIPPED/4 at any age — the age gate sits below
# that arm precisely because a targetless box with every other row OK was rendered DEGRADED once this
# record passed `HU_CLAIMS_STALE` (measured in review).
printf 'claims=notprobed at=1\n' > "$CELL9/orchestrator/state/harness-claims"
touch -t 202001010000 "$CELL9/orchestrator/state/harness-claims" 2>/dev/null
OUT="$( cd "$TMP" && FIX_LOG="$F9/fix.log" HOME="$TMP/home" CELL_HOME="$CELL9" HU_PS="$TMP/ps-stub" \
        DRIFT_PS="$TMP/ps-stub" PS_TABLE="$TMP/ps-empty" HARNESS_UP_CLAIMS_STALE=1 REPO="$REPO_FIX" \
        bash "$F9/scripts/harness-up" status --repo "$REPO_FIX" --harness "$F9/scripts/orchestrator-harness" 2>&1 )"; RC=$?
claims_row9c="$(printf '%s\n' "$OUT" | grep -E '^claims[[:space:]]' | head -1)"
case "$claims_row9c" in
  *SKIPPED*) ck "claims row: an AGED notprobed record stays SKIPPED, never LATE [$claims_row9c]" 0 ;;
  *) ck "claims row: an AGED notprobed record stays SKIPPED, never LATE [$claims_row9c]" 1 ;;
esac
# the refresh RECORD shape: canonical keys, and `fetch=` present (a `--no-fetch` run must not read fresh)
rm -f "$CELL9/orchestrator/state/harness-refresh"
OUT="$( cd "$TMP" && FIX_LOG="$F9/fix.log" HOME="$TMP/home" CELL_HOME="$CELL9" HU_PS="$TMP/ps-stub" \
        DRIFT_PS="$TMP/ps-stub" PS_TABLE="$TMP/ps-empty" \
        bash "$F9/scripts/harness-up" up --repo "$REPO_FIX" --harness "$F9/scripts/orchestrator-harness" --no-fetch 2>&1 )"; RC=$?
REC="$CELL9/orchestrator/state/harness-refresh"
if [ -f "$REC" ]; then
  case "$(cat "$REC")" in
    relation=*running=*ref=*pin=*action=*fetch=*rc=*at=*) ck "the refresh record carries the canonical keys (fetch= included)" 0 ;;
    *) ck "the refresh record carries the canonical keys (fetch= included) [$(cat "$REC")]" 1 ;;
  esac
  # The `fetch=` field must be the CHILD's report, verbatim: this fixture's refresh stub reports
  # `fetch=ok`, and the point of the field is that a `notfetched` comparison is carried through rather
  # than defaulted. A second box whose stub says `notfetched` pins the other direction.
  case "$(cat "$REC")" in *"fetch=ok"*) ck "the record carries the child's own fetch= state" 0 ;; *) ck "the record carries the child's own fetch= state [$(cat "$REC")]" 1 ;; esac
  printf '#!/usr/bin/env bash\nprintf "harness relation=current running=deadbeef ref=deadbeef pin=deadbeef action=none fetch=notfetched\\n"\nexit 0\n' \
    > "$F9/scripts/orchestrator-harness/harness-refresh.sh"; chmod +x "$F9/scripts/orchestrator-harness/harness-refresh.sh"
  OUT="$( cd "$TMP" && FIX_LOG="$F9/fix.log" HOME="$TMP/home" CELL_HOME="$CELL9" HU_PS="$TMP/ps-stub" \
          DRIFT_PS="$TMP/ps-stub" PS_TABLE="$TMP/ps-empty" \
          bash "$F9/scripts/harness-up" up --repo "$REPO_FIX" --harness "$F9/scripts/orchestrator-harness" --no-fetch 2>&1 )"; RC=$?
  case "$(cat "$REC")" in
    *"fetch=notfetched"*) ck "a NOT-FRESH comparison is recorded as fetch=notfetched, not defaulted to ok" 0 ;;
    *) ck "a NOT-FRESH comparison is recorded as fetch=notfetched, not defaulted to ok [$(cat "$REC")]" 1 ;;
  esac
  # ⛔ THE READER MUST RUN. `cat`-ing the record proves the WRITE; only a `status` that parses it proves
  # the read — and the canonical-first parse is exactly what a regression removes (the old single-spelling
  # parse gave "UNKNOWN (no relation= record)" → BROKEN on a healthy box).
  # a FRESH comparison first (the canonical shape with fetch=ok), so the read is tested without the
  # not-fresh rule firing
  printf 'relation=current running=x ref=y pin=z action=none fetch=ok rc=0 at=%s\n' "$(date +%s)" > "$REC"
  OUT="$( cd "$TMP" && FIX_LOG="$F9/fix.log" HOME="$TMP/home" CELL_HOME="$CELL9" HU_PS="$TMP/ps-stub" \
          DRIFT_PS="$TMP/ps-stub" PS_TABLE="$TMP/ps-empty" \
          bash "$F9/scripts/harness-up" status --repo "$REPO_FIX" --harness "$F9/scripts/orchestrator-harness" 2>&1 )"; RC=$?
  case "$OUT" in
    *"OK (relation=current"*) ck "the refresh row READS the controller-shaped record (OK, not UNKNOWN)" 0 ;;
    *) ck "the refresh row READS the controller-shaped record (OK, not UNKNOWN) [$(printf '%s' "$OUT" | grep -i '^refresh' | tr '\n' ' ')]" 1 ;;
  esac
  # …and a NOT-FRESH comparison in that record is cannot-verify, the same rule the other two readers apply
  printf 'relation=current running=x ref=y pin=z action=none fetch=notfetched rc=0 at=%s\n' "$(date +%s)" > "$REC"
  OUT="$( cd "$TMP" && FIX_LOG="$F9/fix.log" HOME="$TMP/home" CELL_HOME="$CELL9" HU_PS="$TMP/ps-stub" \
          DRIFT_PS="$TMP/ps-stub" PS_TABLE="$TMP/ps-empty" \
          bash "$F9/scripts/harness-up" status --repo "$REPO_FIX" --harness "$F9/scripts/orchestrator-harness" 2>&1 )"; RC=$?
  case "$OUT" in
    *"UNVERIFIED"*) ck "a NOT-FRESH comparison is UNVERIFIED in the row (never OK)" 0 ;;
    *) ck "a NOT-FRESH comparison is UNVERIFIED in the row (never OK) [$(printf '%s' "$OUT" | grep -i '^refresh' | tr '\n' ' ')]" 1 ;;
  esac
else
  ck "the refresh record was written at all [$REC missing]" 1
fi

# ── the two thin names delegate to the ONE implementation ─────────────────────────────────────
F5="$(mkfix f5)"; cp "$HERE/harness-status" "$F5/scripts/harness-status"; cp "$HERE/harness-down" "$F5/scripts/harness-down"
chmod +x "$F5/scripts/harness-status" "$F5/scripts/harness-down"
OUT="$( cd "$TMP" && FIX_LOG="$F5/fix.log" HOME="$TMP/home" CELL_HOME="$TMP/cell" \
        DRIFT_PS="$TMP/ps-stub" PS_TABLE="$TMP/ps-empty" HU_PS="$TMP/ps-stub" \
        bash "$F5/scripts/harness-status" --repo "$REPO_FIX" --harness "$F5/scripts/orchestrator-harness" 2>&1 )"; RC=$?
n_v="$(printf '%s\n' "$OUT" | grep -c '^VERDICT:')"
ck "harness-status prints exactly ONE verdict line (n=$n_v)" "$([ "$n_v" -eq 1 ] && echo 0 || echo 1)"
# …and it is a VERDICT, in the documented vocabulary: a line that says something else is not a verdict.
case "$OUT" in
  *"VERDICT: HEALTHY"*|*"VERDICT: DEGRADED"*|*"VERDICT: BROKEN"*) ck "the verdict uses the documented word (HEALTHY|DEGRADED|BROKEN)" 0 ;;
  *) ck "the verdict uses the documented word (HEALTHY|DEGRADED|BROKEN) [$(printf '%s' "$OUT" | grep '^VERDICT:' | tr '\n' ' ')]" 1 ;;
esac
case "$OUT" in *COMPONENT*) ck "harness-status prints one line per component" 0 ;; *) ck "harness-status prints one line per component [$OUT]" 1 ;; esac
OUT="$( cd "$TMP" && FIX_LOG="$F5/fix.log" HOME="$TMP/home" CELL_HOME="$TMP/cell" \
        DRIFT_PS="$TMP/ps-stub" PS_TABLE="$TMP/ps-empty" HU_PS="$TMP/ps-stub" \
        bash "$F5/scripts/harness-down" --repo "$REPO_FIX" 2>&1 )"; RC=$?
n5="$(grep -c '^stop$' "$F5/fix.log" 2>/dev/null || echo 0)"
ck "harness-down delegates the stop to the platform authority (n=$n5)" "$([ "$n5" -ge 1 ] && echo 0 || echo 1)"
[ "$n5" -ge 1 ] || printf '    (F5 authority log: %s)\n' "$(tr '\n' ' ' < "$F5/fix.log" 2>/dev/null)"
case "$OUT" in *"down: ok"*|*"stop"*) ck "harness-down reports what it did" 0 ;; *) ck "harness-down reports what it did [$OUT]" 1 ;; esac
# ⛔ THE WRAPPER'S VERB IS NOT OVERRIDABLE: `harness-down up` would start the box under the name of
# the stop verb. Refused (rc=2), and the refusal names the entry point.
OUT="$( cd "$TMP" && HOME="$TMP/home" CELL_HOME="$TMP/cell" \
        DRIFT_PS="$TMP/ps-stub" PS_TABLE="$TMP/ps-empty" HU_PS="$TMP/ps-stub" \
        bash "$F5/scripts/harness-down" up --repo "$REPO_FIX" 2>&1 )"; RC=$?
ck "harness-down refuses a positional verb that contradicts its own name (rc=$RC)" "$([ "$RC" -eq 2 ] && echo 0 || echo 1)"
case "$OUT" in *"is down"*) ck "the refusal names the entry point's own verb" 0 ;; *) ck "the refusal names the entry point's own verb [$OUT]" 1 ;; esac

# ── the suite's own non-vacuity floor ─────────────────────────────────────────────────────────
# A suite that silently ran nothing must not report success (the #1890 class). This is a FLOOR, not
# `-ge 0`: the assertion count is real, so neutering the body (or losing a block to an unbalanced
# quote — the #2216 review's own P1) reddens here instead of printing ALL PASS.
ck "non-vacuity: at least 25 assertions ran (ran: $assertions)" "$([ "$assertions" -ge 25 ] && echo 0 || echo 1)"
printf '\n%s\n' "harness-cohesion.test.sh: $assertions assertions, $fails failed"
if [ "$fails" -ne 0 ]; then printf 'FAILED: %s assertion(s)\n' "$fails"; exit 1; fi
printf 'ALL PASS\n'
exit 0
