#!/usr/bin/env bash
# mac-pin-parity.test.sh — the MAC runs the same pinned harness as the cells, and a divergence is RED.
#
# WHY THIS SUITE EXISTS (agent-infra#2231, mac pin parity)
# ------------------------------------------------------
# MEASURED. The Mac's launchd controller ran `$O/orch-loop.sh` — a COPY of a script the repo carries,
# in a directory that is not a git checkout (`git rev-parse --show-toplevel` there says "not a git
# repository"). Three fixes made on that box in one evening (a bounded `gh` probe, the worklist wiring,
# three cell bring-up traps) existed ONLY in copies of that shape, so any re-deploy would have erased
# them, and nothing on the box could answer "which commit am I running?". The cells never had this
# defect: they exec `<pin root>/<sha12>/scripts/orchestrator-harness/orch-loop.sh`, a detached worktree
# AT THE PINNED COMMIT recorded in `HARNESS-PIN`. The Mac was the one machine with no pin — and it was
# the machine whose divergence was invisible, because it had no such record to read.
#
# ⛔ THIS IS A TEST, NOT A CHECKER. `scripts/orchestrator-harness/check-deployed-drift.sh --surface`
# already answers "does the deployed dir match origin/main", and `scripts/harness-up` composes it. The
# question HERE is different and narrower: is the path the Mac's JOB is configured to exec the path the
# PIN names — and does the installer REFUSE when it is not? That is the pair whose disagreement is
# silent in every direction, so it gets an assertion of its own rather than a paragraph in a README.
#
# THE ARMS
#   A. the rendered job's program IS the pinned tree (never a home-dir copy, never `$O`)
#   B. the FIRST pin is materialised by the cells' own materialiser (`apply --force --pin-only`)
#   C. the installer REFUSES, naming both paths, when: the resolved dir is a copy; the pin's sha and
#      the resolved tree disagree; the pin record cannot be read; the pin record cannot be examined;
#      no pin is recorded AND no materialiser exists; a LIVE-ONLY entrypoint the pin does not carry
#   D. the LIVE arm (macOS, when installed plists exist): every installed job whose program is a script
#      the repo carries must run it from the pin's tree. THIS is the arm that turns tonight's drift
#      into a red.
#   E. the home-dir-only fixes are not lost: each named fix's carrier AND its witness test are present
#      in this tree and wired into the ONE shard list (so a revert, or a de-listed suite, reds here)
#   F. portability: nothing here or in the changed scripts reaches for `timeout`/`gtimeout`/`pgrep -c`
#      (absent or incompatible on macOS — the reason the launcher uses perl's alarm and `ps`)
#
# ⛔ MACOS-SAFE BY CONSTRUCTION: no `timeout`/`gtimeout` (bounds are `perl -e 'alarm …'`, and there is
# nothing here that needs a bound at all), no `pgrep -c` (BSD pgrep has no `-c`; process reads use `ps`
# or nothing), no GNU-only `sed -i`/`readlink -f`, no `date -d`. Every arm is hermetic: a fixture git
# repo, a sandbox HOME, and stub binaries — no network, no launchd, no real `$O`.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
HARNESS="$HERE/orchestrator-harness"
INSTALL="$HARNESS/install.sh"
TEMPLATE="$HARNESS/launchd.plist.template"
PLATFORM="$(uname -s)"
PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m  %s\n' "$*"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m  %s\n' "$*"; }
skip() { SKIP=$((SKIP+1)); printf '  \033[33mSKIP\033[0m  %s\n' "$*"; }
sec()  { printf '\n-- %s\n' "$*"; }
ck()   { if [ "$1" -eq 0 ]; then ok "$2"; else bad "$2"; fi; }
# `has <haystack> <needle>` as a status, so every assertion reads the same way.
has()  { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }
need() { [ -e "$1" ] || { bad "missing fixture: $1"; return 1; }; }

T="$(mktemp -d "${TMPDIR:-/tmp}/macpin.XXXXXX")" || { echo "mac-pin-parity: cannot create a temp dir" >&2; exit 2; }
trap 'rm -rf "$T"' EXIT

sec "A. the rendered job's program is the PINNED tree"
# ── fixture: a real git repo carrying a harness, so "is a worktree at a commit" is TRUE for it and
# FALSE for a copy. That difference is the whole point — a copy has no answer to `rev-parse HEAD`.
FX="$T/repo"
mkdir -p "$FX/scripts/orchestrator-harness"
( cd "$FX" || exit 1
  git init -q -b main . >/dev/null 2>&1
  printf '.worktrees/\n' > .gitignore
  printf '#!/bin/bash\necho loop\n' > scripts/orchestrator-harness/orch-loop.sh
  printf '#!/bin/bash\necho claims\n' > scripts/orchestrator-harness/claims.sh
  git add -A >/dev/null 2>&1
  git -c user.email=t@t -c user.name=t commit -qm base >/dev/null 2>&1
  git update-ref refs/remotes/origin/main HEAD
) || { bad "the fixture git repo could not be created (git is required by this suite AND by the installer)"; }
FXH="$FX/scripts/orchestrator-harness"
need "$FXH/orch-loop.sh" || true
FX_SHA="$(git -C "$FX" rev-parse HEAD 2>/dev/null)"

# The installer is driven from a STAGE copy, so nothing it does can reach this checkout's neighbours
# and its own `bash -n` sweep sees only what is under test.
STAGE="$T/stage"; mkdir -p "$STAGE"
# ⛔ `merge-reminder.py` IS STAGED, NOT STUBBED (main's install.sh gates on it, 2026-10-24). The
# installer parses `$HERE/merge-reminder.py` with `ast.parse` and DIES when it is absent — deliberately
# unguarded, because a `[ -f ]` guard once let a MISSING file read as "parses fine" while the timer had
# no script. Without it in the stage, every arm stops at that gate instead of at its own assertion; the
# file is a shipped companion of install.sh (see install.sh's own drift list), so the stage carries the
# REAL one rather than a stub — a stub would pass the parse gate while proving nothing about the ship set.
cp "$INSTALL" "$HARNESS/launchd-cycle.sh" "$TEMPLATE" "$HARNESS/refresh-candidates.sh" \
   "$HARNESS/merge-reminder.py" "$STAGE/" 2>/dev/null
BIN="$T/bin"; mkdir -p "$BIN"
# install.sh probes the real binaries (gh/network, tmux, pi, jq) and lints the plist with plutil. ALL of
# them are stubbed IN $BIN: the assertions below are about the RENDERED PROGRAM, not the host's toolchain.
# ⛔ `pi` AND `jq` BELONG IN THIS LOOP, NOT ONLY IN $SHOME (the arms' Linux-CI red, 2026-10-24). `RUN()`
# prepends $SHOME/…/pi-node/current/bin, but most arms invoke the installer directly with
# `PATH="$BIN:$PATH"`, so a `pi` that existed ONLY under $SHOME left those arms reading the HOST's
# toolchain: green on a dev Mac (where `pi` is on the ambient PATH), and ~20 arms RED on the runner with
# `✓ gh ❌ pi not on PATH` — install.sh's hard-dependency probe (tmux gh pi jq) died before the arm's own
# assertion could run. jq is in that same probe (#1962) and is used by install.sh ONLY to test presence,
# so a no-op stub is faithful. Stub the DEPENDENCY; never the host.
for b in gh tmux plutil pi jq; do printf '#!/bin/sh\nexit 0\n' > "$BIN/$b"; chmod +x "$BIN/$b"; done
SHOME="$T/home"; mkdir -p "$SHOME/Library/LaunchAgents" "$SHOME/.local/share/pi-node/current/bin"
printf '#!/bin/bash\nexit 0\n' > "$SHOME/.local/share/pi-node/current/bin/pi"
chmod +x "$SHOME/.local/share/pi-node/current/bin/pi"
PLIST="$SHOME/Library/LaunchAgents/com.eldato.orchestrator-loop.plist"
O="$T/o"; mkdir -p "$O"

RUN() { # <extra-env…> -- <install.sh args…>
  env HOME="$SHOME" O="$O" REPO="$FX" OR="acme/widget" HARNESS_REPO="$FX" \
      ELDATO_ALLOW_NON_DARWIN=1 ELDATO_ALLOW_TEST_HOME=1 LC_SETTLE=1 START_TIMEOUT=2 \
      PATH="$SHOME/.local/share/pi-node/current/bin:$BIN:$PATH" \
      "$@" 2>&1
}
# The same parser `install.sh` uses to read the program back out of its own render. Duplicated on
# purpose: a suite that re-implemented the check with a DIFFERENT parse would pass while the shipped
# assertion was broken, and the shipped one is the thing that must fire.
# ⛔ THE SUITE'S COPY OF THE SHIPPED RULE, AND IT MUST BE THE SAME RULE (review finding): `install.sh`
# flattens the file, matches each `<string>` ELEMENT, and takes the FIRST token that is not a flag and not
# an interpreter. A copy that took the LAST `<string>` would keep passing while the shipped parser
# regressed — the witness would vouch for a rule the installer no longer implements.
plist_program() { # <plist>
  local flat args
  [ -f "$1" ] || return 0
  flat="$(tr '\n' ' ' < "$1" 2>/dev/null || true)"
  args="$(printf '%s' "$flat" | sed -n 's:.*<key>ProgramArguments</key>[[:space:]]*<array>\(.*\)</array>.*:\1:p')"
  printf '%s' "$args" | awk '
    { s = $0
      while (match(s, /<string>[^<]*<\/string>/)) {
        v = substr(s, RSTART + 8, RLENGTH - 17)
        print v
        s = substr(s, RSTART + RLENGTH)
      } }' \
    | awk '!(/^-/) && !/(^|\/)(ba|z|k)?sh$/ && !/\/env$/ { print; exit }'
}

# A1 — the FIRST pin, materialised by the cells' own materialiser.
out="$(RUN HARNESS_MATERIALISER="$REPO_ROOT/scripts/cloud-cell-supervisor.sh" bash "$STAGE/install.sh")"
rc=$?
ck "$([ "$rc" -eq 0 ] && echo 0 || echo 1)" "install.sh pins and renders on a box with NO pin record (rc=$rc; out=$(printf %s "$out" | tail -2 | tr "\n" " "))"
[ -f "$PLIST" ] && ok "the plist was rendered" || bad "no plist was rendered"
PIN_DIR_REC="$(head -1 "$SHOME/.harness-path" 2>/dev/null)"
PIN_SHA_REC="$(head -1 "$SHOME/.pi/agent/state/HARNESS-PIN" 2>/dev/null)"
ck "$(has "$PIN_DIR_REC" "/harness/" && echo 0 || echo 1)" "the dir record names a per-commit worktree under the pin root ($PIN_DIR_REC)"
ck "$([ "$PIN_SHA_REC" = "$FX_SHA" ] && echo 0 || echo 1)" "the sha record names the pinned commit ($PIN_SHA_REC)"
ck "$(git -C "$PIN_DIR_REC" rev-parse --git-dir >/dev/null 2>&1 && echo 0 || echo 1)" "the pinned dir IS a git worktree (a copy would fail here)"
PROG="$(plist_program "$PLIST")"
ck "$(has "$PROG" "$PIN_DIR_REC" && echo 0 || echo 1)" "the job's program is the PINNED tree ($PROG)"
case "$PROG" in
  "$O"/*|"$HOME"/orchestrator/*|*/.cache/orc/*|*/.pi/agent/scripts/*)
    bad "the job's program is a HOME-DIR copy of a repo script ($PROG) — this is the divergence the suite exists for" ;;
  *) ok "the job's program is NOT a home-dir copy (not \$O, not ~/orchestrator, not ~/.cache/orc, not ~/.pi/agent/scripts)" ;;
esac
# ⛔ THE POSITIVE FORM OF THE SAME RULE, which is what a reviewer needs: no PROGRAM path in the rendered
# plist belongs to a directory that is not a git worktree at the pin.
if [ -n "$PROG" ] && git -C "$(dirname "$PROG")" rev-parse --verify --quiet 'HEAD^{commit}' >/dev/null 2>&1; then
  ok "the program lives in a directory with a commit identity (re-pin can be checked against it)"
else
  bad "the program's directory has no commit identity — the job would run code nothing can name ($PROG)"
fi
# The pin records ride in the daemon's ENVIRONMENT too, or `harness-refresh.sh` (which runs INSIDE the
# controller's cycle) cannot compare this box to the ref, and the spawn lines lose the harness token.
for k in HARNESS_PIN_FILE HARNESS_PIN_DIR HARNESS_REPO; do
  case "$(cat "$PLIST" 2>/dev/null)" in
    *"<key>$k</key>"*) ok "the plist exports $k to the daemon" ;;
    *) bad "the plist does NOT export $k — the controller's own refresh cannot see the pin" ;;
  esac
done

# A2 — an EXPLICIT checkout (the documented first-pin route) mends the records instead of materialising.
SHOME2="$T/home2"; mkdir -p "$SHOME2/Library/LaunchAgents"
out="$(env HOME="$SHOME2" O="$T/o2" REPO="$FX" OR="acme/widget" HARNESS="$FXH" \
        ELDATO_ALLOW_NON_DARWIN=1 ELDATO_ALLOW_TEST_HOME=1 \
        PATH="$SHOME2/.local/share/pi-node/current/bin:$BIN:$PATH" bash "$STAGE/install.sh" 2>&1)"
rc=$?
ck "$([ "$rc" -eq 0 ] && echo 0 || echo 1)" "an explicit HARNESS=<checkout harness> installs (rc=$rc; out=$(printf %s "$out" | tail -2 | tr "\n" " "))"
P2="$SHOME2/Library/LaunchAgents/com.eldato.orchestrator-loop.plist"
ck "$([ "$(plist_program "$P2" 2>/dev/null)" = "$FXH/orch-loop.sh" ] && echo 0 || echo 1)" "…and the program is that checkout's orch-loop.sh"
ck "$([ -f "$SHOME2/.harness-path" ] && [ -f "$SHOME2/.pi/agent/state/HARNESS-PIN" ] && echo 0 || echo 1)" \
   "…and it MENDED both pin records, so the next reader resolves the same tree"

sec "B. the installer REFUSES (and names both paths) when the pin and the job disagree"
# B1 — a COPY is not a pin. This is the exact shape of `~/orchestrator` and `~/.cache/orc`.
COPY="$T/copy-harness"; mkdir -p "$COPY"; cp "$FXH"/*.sh "$COPY/"
out="$(RUN HARNESS="$COPY" bash "$STAGE/install.sh")"; rc=$?
ck "$([ "$rc" -eq 78 ] && echo 0 || echo 1)" "a COPY as the harness is REFUSED with rc=78 (got $rc)"
ck "$(has "$out" "NOT a git worktree" && echo 0 || echo 1)" "…the refusal says it is not a git worktree"
ck "$(has "$out" "$COPY" && echo 0 || echo 1)" "…and names the copy's path"

# B2 — the pin names one commit, the resolved dir is another. #2216's shape: a re-pin nobody reads.
OTHER="$T/other"; git -C "$FX" worktree add --detach "$OTHER" "$FX_SHA" >/dev/null 2>&1
# A REAL second commit, so the record names a commit that IS in the repo but is NOT the tree resolved
# below — the only way to reach the DISAGREE arm. A junk sha would refuse one step earlier (it cannot be
# resolved at all), and a suite that accepted either message would not be testing this arm.
printf 'second\n' > "$FX/scripts/orchestrator-harness/claims.sh"
git -C "$FX" -c user.email=t@t -c user.name=t commit -qam second >/dev/null 2>&1
FX_SHA2="$(git -C "$FX" rev-parse HEAD 2>/dev/null)"
SHOME3="$T/home3"; mkdir -p "$SHOME3/Library/LaunchAgents" "$SHOME3/.pi/agent/state"
printf '%s\n' "$FX_SHA2" > "$SHOME3/.pi/agent/state/HARNESS-PIN"
out="$(env HOME="$SHOME3" O="$T/o3" REPO="$FX" OR="acme/widget" HARNESS="$OTHER/scripts/orchestrator-harness" \
        ELDATO_ALLOW_NON_DARWIN=1 ELDATO_ALLOW_TEST_HOME=1 \
        PATH="$BIN:$PATH" bash "$STAGE/install.sh" 2>&1)"; rc=$?
ck "$([ "$rc" -eq 78 ] && echo 0 || echo 1)" "a pin sha that is NOT the resolved tree's commit is REFUSED (rc=$rc; out=$(printf %s "$out" | tail -2 | tr "\n" " "))"
ck "$(has "$out" "DISAGREE" && echo 0 || echo 1)" "…the refusal says the pin and the tree disagree"

# B3 — the pin record exists but cannot be READ: unknown is never a pass.
SHOME4="$T/home4"; mkdir -p "$SHOME4/Library/LaunchAgents" "$SHOME4/.pi/agent/state"
printf '%s\n' "$FX_SHA" > "$SHOME4/.pi/agent/state/HARNESS-PIN"; chmod 000 "$SHOME4/.pi/agent/state/HARNESS-PIN"
out="$(env HOME="$SHOME4" O="$T/o4" REPO="$FX" OR="acme/widget" HARNESS="$FXH" \
        ELDATO_ALLOW_NON_DARWIN=1 ELDATO_ALLOW_TEST_HOME=1 \
        PATH="$BIN:$PATH" bash "$STAGE/install.sh" 2>&1)"; rc=$?
if [ "$(id -u)" -eq 0 ]; then
  skip "an unreadable pin record is untestable as root (root reads a mode-000 file)"
else
  ck "$([ "$rc" -eq 78 ] && echo 0 || echo 1)" "an UNREADABLE pin sha record is REFUSED (rc=$rc; out=$(printf %s "$out" | tail -2 | tr "\n" " "))"
  ck "$(has "$out" "cannot be READ" && echo 0 || echo 1)" "…and the refusal distinguishes unreadable from absent"
fi
chmod 644 "$SHOME4/.pi/agent/state/HARNESS-PIN" 2>/dev/null

# B4 — the record is behind an unsearchable ancestor: unexaminable, not absent.
SHOME5="$T/home5"; mkdir -p "$SHOME5/Library/LaunchAgents" "$SHOME5/priv/state"
printf '%s\n' "$FX_SHA" > "$SHOME5/priv/state/HARNESS-PIN"
chmod 000 "$SHOME5/priv"
out="$(env HOME="$SHOME5" O="$T/o5" REPO="$FX" OR="acme/widget" HARNESS="$FXH" \
        HARNESS_PIN="$SHOME5/priv/state/HARNESS-PIN" \
        ELDATO_ALLOW_NON_DARWIN=1 ELDATO_ALLOW_TEST_HOME=1 \
        PATH="$BIN:$PATH" bash "$STAGE/install.sh" 2>&1)"; rc=$?
if [ "$(id -u)" -eq 0 ]; then
  skip "an unexaminable pin record is untestable as root"
else
  ck "$([ "$rc" -eq 78 ] && echo 0 || echo 1)" "a pin record behind an unsearchable ancestor is REFUSED (rc=$rc; out=$(printf %s "$out" | tail -2 | tr "\n" " "))"
  ck "$(has "$out" "cannot be EXAMINED" && echo 0 || echo 1)" "…and says it cannot be examined (never 'absent')"
fi
chmod 755 "$SHOME5/priv" 2>/dev/null

# B5 — no pin, no materialiser: refuse rather than copy. The forbidding case is the whole design.
SHOME6="$T/home6"; mkdir -p "$SHOME6/Library/LaunchAgents"
out="$(env HOME="$SHOME6" O="$T/o6" REPO="$FX" OR="acme/widget" HARNESS_REPO="$FX" \
        HARNESS_MATERIALISER="$T/does-not-exist" \
        ELDATO_ALLOW_NON_DARWIN=1 ELDATO_ALLOW_TEST_HOME=1 \
        PATH="$BIN:$PATH" bash "$STAGE/install.sh" 2>&1)"; rc=$?
ck "$([ "$rc" -eq 78 ] && echo 0 || echo 1)" "no pin + no materialiser is REFUSED (rc=$rc; out=$(printf %s "$out" | tail -2 | tr "\n" " "))"
ck "$(has "$out" "will not fall back to copying" && echo 0 || echo 1)" "…and says it will not fall back to copying"

# A3 — THE FIRST PIN ON A CHECKOUT THAT *IS* THE REF (review P1) — AND WHY IT MUST NOT BE RECORDED AS THE
# PIN (review N1). The materialiser answers `unchanged` and writes NO record when its resolved tree is
# already at the ref, and the installer used to refuse with "reported success but … is empty" — so the
# fresher the checkout, the more certain the refusal. The fix must NOT simply adopt that tree: on this
# fleet every clone lives under `~/Documents/GitHub`, which macOS TCC protects from a launchd-born bash,
# so a job whose program is the checkout cannot open it (a silent KeepAlive crash-loop) while every
# install-time check — run as the installing user — passes. The pin is therefore materialised INTO the
# TCC-safe pin root: `$HARNESS` is named as the per-commit child, which forces the `changed` branch.
FX3="$T/repo3"; mkdir -p "$FX3/scripts/orchestrator-harness"
( cd "$FX3" || exit 1
  git init -q -b main . >/dev/null 2>&1
  printf '.worktrees/\n' > .gitignore
  printf '#!/bin/bash\necho loop\n' > scripts/orchestrator-harness/orch-loop.sh
  printf '#!/bin/bash\necho claims\n' > scripts/orchestrator-harness/claims.sh
  cp "$REPO_ROOT/scripts/cloud-cell-supervisor.sh" "$REPO_ROOT/scripts/repo-slug.sh" scripts/ 2>/dev/null
  git add -A >/dev/null 2>&1
  git -c user.email=t@t -c user.name=t commit -qm base >/dev/null 2>&1
  git update-ref refs/remotes/origin/main HEAD
) >/dev/null 2>&1
FX3H="$FX3/scripts/orchestrator-harness"
FX3_SHA="$(git -C "$FX3" rev-parse HEAD 2>/dev/null)"
SHOME3P="$T/home-a3"; mkdir -p "$SHOME3P/Library/LaunchAgents"
O3P="$T/o-a3"; mkdir -p "$O3P"
out="$(env HOME="$SHOME3P" O="$O3P" REPO="$FX3" OR="acme/widget" HARNESS_REPO="$FX3" \
        ELDATO_ALLOW_NON_DARWIN=1 ELDATO_ALLOW_TEST_HOME=1 LC_SETTLE=1 START_TIMEOUT=2 \
        PATH="$SHOME3P/.local/share/pi-node/current/bin:$BIN:$PATH" \
        bash "$STAGE/install.sh" 2>&1)"; rc=$?
ck "$([ "$rc" -eq 0 ] && echo 0 || echo 1)" "a FIRST pin on a checkout that IS the ref installs (rc=$rc; out=$(printf %s "$out" | tail -2 | tr "\n" " "))"
PIN_DIR_A3="$(head -1 "$SHOME3P/.harness-path" 2>/dev/null)"
ck "$(has "$PIN_DIR_A3" "$SHOME3P/harness/" && echo 0 || echo 1)" \
   "…and the dir record names a per-commit tree under the PIN ROOT ($PIN_DIR_A3)"
ck "$([ "$(git -C "$PIN_DIR_A3" rev-parse HEAD 2>/dev/null)" = "$FX3_SHA" ] && echo 0 || echo 1)" \
   "…at the ref commit"
ck "$([ "$PIN_DIR_A3" != "$FX3H" ] && echo 0 || echo 1)" \
   "…and NOT the operator's checkout (a TCC-protected tree a launchd job cannot read)"
ck "$([ "$(head -1 "$SHOME3P/.pi/agent/state/HARNESS-PIN" 2>/dev/null)" = "$FX3_SHA" ] && echo 0 || echo 1)" \
   "…and the sha record names that commit"
P3P="$SHOME3P/Library/LaunchAgents/com.eldato.orchestrator-loop.plist"
ck "$([ "$(plist_program "$P3P" 2>/dev/null)" = "$PIN_DIR_A3/orch-loop.sh" ] && echo 0 || echo 1)" "…and the job execs that tree"
# The launcher's verdict on the SAME two records: it must not call the box BROKEN.
# ⛔ `HARNESS_REPO` IS PART OF THE FIXTURE, NOT DECORATION. `harness-up` resolves the repo whose object
# DB the pin commit is read in from `HARNESS_REPO`, then this machine's config file, then ITS OWN
# checkout — so without it these arms silently ask the INSTALLER'S checkout (whose object DB does not
# contain a `git init`'d fixture commit) and the pin row reads `UNRESOLVABLE`, reding every arm here on
# a tree that is correct. Measured: 100 passed / 3 failed on this suite before this line, with
# `pin: UNRESOLVABLE — the commit … is not an object in the harness repo <checkout>`.
hs_out="$(CELL_HOME="$SHOME3P" HOME="$SHOME3P" O="$O3P" REPO="$FX3" HARNESS_REPO="$FX3" HARNESS_PIN_DIR="$SHOME3P/harness" \
          HARNESS_PIN_FILE="$SHOME3P/.harness-path" HARNESS="$PIN_DIR_A3" \
          bash "$REPO_ROOT/scripts/harness-up" status 2>&1)"; hs_rc=$?
ck "$(has "$hs_out" "NOT MATERIALISED" && echo 1 || echo 0)" "harness-up does NOT report the installed pin NOT MATERIALISED"
ck "$(has "$hs_out" "pin: OK" && echo 0 || echo 1)" "…and its pin row reads OK (rc=$hs_rc; other rows are fixture-incomplete)"
# ⛔ AND THE TCC HAZARD IS NOW UNREACHABLE ON THE DEFAULT ROUTE: with the pin root in place the operator's
# checkout is never what launchd is told to exec.
ck "$(has "$out" "MAIN WORKTREE" && echo 1 || echo 0)" "…and the install does not warn about a mutable checkout pin (none was recorded)"

# A3b — an EXPLICIT HARNESS (the documented 'pin a deliberate checkout' route) still records THAT tree, and
# the install says out loud that it is a mutable main worktree (review K5/N2): the weakened claim is
# disclosed where the operator acts on it.
SHOME3Q="$T/home-a3b"; mkdir -p "$SHOME3Q/Library/LaunchAgents"
out="$(env HOME="$SHOME3Q" O="$T/o-a3b" REPO="$FX3" OR="acme/widget" HARNESS="$FX3H" \
        ELDATO_ALLOW_NON_DARWIN=1 ELDATO_ALLOW_TEST_HOME=1 \
        PATH="$BIN:$PATH" bash "$STAGE/install.sh" 2>&1)"; rc=$?
ck "$([ "$rc" -eq 0 ] && echo 0 || echo 1)" "an EXPLICIT HARNESS installs (rc=$rc; out=$(printf %s "$out" | tail -2 | tr "\n" " "))"
ck "$([ "$(head -1 "$SHOME3Q/.harness-path" 2>/dev/null)" = "$FX3H" ] && echo 0 || echo 1)" \
   "…and records exactly the tree the operator named"
ck "$(has "$out" "MAIN WORKTREE" && echo 0 || echo 1)" "…and DISCLOSES that the pin names a mutable main worktree"
ck "$(has "$out" "rm -f" && has "$out" ".harness-path" && echo 0 || echo 1)" \
   "…with the STEP that clears it (remove the dir record), not a re-run that re-reads it"
# ⛔ AND THE REMEDY MUST WORK (review M2): run 1 recorded the checkout, so a bare re-run re-reads that
# record; the printed step is what reaches the materialise path. Verified by EXECUTING it.
out2="$(env HOME="$SHOME3Q" O="$T/o-a3b" REPO="$FX3" OR="acme/widget" \
        ELDATO_ALLOW_NON_DARWIN=1 ELDATO_ALLOW_TEST_HOME=1 \
        PATH="$BIN:$PATH" bash "$STAGE/install.sh" 2>&1)"; rc2=$?
ck "$([ "$rc2" -eq 0 ] && [ "$(head -1 "$SHOME3Q/.harness-path" 2>/dev/null)" = "$FX3H" ] && echo 0 || echo 1)" \
   "…and a BARE re-run records the same checkout (which is why the step is named, not just 're-run')"
# (The printed step's EFFECT — a bare re-run after the record is removed reaching the materialise path —
# is what arm A3 already asserts end to end on a clean HOME; re-driving it here as well would only re-test
# A3 through a box whose records A3b has already touched.)

# A4 — K4's mend: a sha record with NO dir record that the materialiser SUPERSEDES must be MENDED, not
# refused DISAGREE (the false block this change removes). Deleting only the dir record is the ordinary
# state install.sh itself describes (harness-refresh writes sha then dir; an interrupted first install).
SHOME4P="$T/home-a4"; mkdir -p "$SHOME4P/Library/LaunchAgents" "$SHOME4P/.pi/agent/state"
_prog4() { env HOME="$SHOME4P" O="$T/o-a4" REPO="$FX3" OR="acme/widget" HARNESS_REPO="$FX3" \
             ELDATO_ALLOW_NON_DARWIN=1 ELDATO_ALLOW_TEST_HOME=1 LC_SETTLE=1 START_TIMEOUT=2 \
             PATH="$SHOME4P/.local/share/pi-node/current/bin:$BIN:$PATH" bash "$STAGE/install.sh" 2>&1; }
out="$(_prog4)"; rc=$?
S4_OLD="$(head -1 "$SHOME4P/.pi/agent/state/HARNESS-PIN" 2>/dev/null)"
ck "$([ "$rc" -eq 0 ] && [ -n "$S4_OLD" ] && echo 0 || echo 1)" "A4 setup: the first pin records a sha ($S4_OLD)"
# Advance the ref by one commit, then drop ONLY the dir record.
( cd "$FX3" || exit 1
  printf 'advance\n' >> scripts/orchestrator-harness/claims.sh
  git -c user.email=t@t -c user.name=t commit -qam advance >/dev/null 2>&1
  git update-ref refs/remotes/origin/main HEAD ) >/dev/null 2>&1
S4_NEW="$(git -C "$FX3" rev-parse HEAD 2>/dev/null)"
rm -f "$SHOME4P/.harness-path"
out="$(_prog4)"; rc=$?
ck "$([ "$rc" -eq 0 ] && echo 0 || echo 1)" "A4: a superseded sha + no dir record INSTALLS (rc=$rc, was a post-materialise DISAGREE; out=$(printf %s "$out" | tail -2 | tr "\n" " "))"
ck "$([ "$(head -1 "$SHOME4P/.pi/agent/state/HARNESS-PIN" 2>/dev/null)" = "$S4_NEW" ] && echo 0 || echo 1)" \
   "…and the sha record was MENDED to the commit the materialiser pinned"
ck "$(has "$out" "MENDED after the materialise" && echo 0 || echo 1)" "…and the mend is SAID, not silent"

# A4b — the P3 relaxation at the LAUNCHER (review M4): a dir record that names a worktree at the pinned
# commit OUTSIDE the pin root is OK; the same tree with a sha record naming another commit is MISMATCH.
SHOME4Q="$T/home-a4b"; mkdir -p "$SHOME4Q/Library/LaunchAgents" "$SHOME4Q/.pi/agent/state"
printf '%s\n' "$S4_NEW" > "$SHOME4Q/.pi/agent/state/HARNESS-PIN"
# ⛔ `HARNESS_REPO="$FX3"` for the reason A3's `hs_out` names: without it the launcher resolves the pin
# in its own checkout and both arms below red with `pin: UNRESOLVABLE` (measured).
_hs4() { CELL_HOME="$SHOME4Q" HOME="$SHOME4Q" O="$T/o-a4b" REPO="$FX3" HARNESS_REPO="$FX3" HARNESS_PIN_DIR="$SHOME4Q/harness" \
           HARNESS_PIN_FILE="$T/a4-path" HARNESS="$1" bash "$REPO_ROOT/scripts/harness-up" status 2>&1; }
printf '%s\n' "$FX3H" > "$T/a4-path"
ck "$(has "$(_hs4 "$FX3H")" "pin: OK" && echo 0 || echo 1)" "a worktree at the pinned commit OUTSIDE the pin root reads pin: OK"
printf '%s\n' "$S4_OLD" > "$SHOME4Q/.pi/agent/state/HARNESS-PIN"
mkdir -p "$SHOME4Q/harness"
ck "$(has "$(_hs4 "$FX3H")" "NOT MATERIALISED" && echo 0 || echo 1)" "…and the same tree with a sha record naming another commit is NOT MATERIALISED (a refusal, not OK)"
printf '%s\n' "$S4_NEW" > "$SHOME4Q/.pi/agent/state/HARNESS-PIN"

# A3c — THE `unchanged` + NO-DIR-RECORD STATE MUST NOT RECORD THE CHECKOUT (review F1). Run 1 pins into the
# pin root; then ONLY the dir record is deleted (the state install.sh itself calls ordinary), and the
# operator's checkout is made DIRTY. Re-running must still record the PIN-ROOT tree — never the checkout
# (a TCC-unreadable tree a launchd job cannot open, and carrying bytes no commit describes).
SHOME3R="$T/home-a3c"; mkdir -p "$SHOME3R/Library/LaunchAgents"
_prog3r() { env HOME="$SHOME3R" O="$T/o-a3c" REPO="$FX3" OR="acme/widget" HARNESS_REPO="$FX3" \
              ELDATO_ALLOW_NON_DARWIN=1 ELDATO_ALLOW_TEST_HOME=1 LC_SETTLE=1 START_TIMEOUT=2 \
              PATH="$SHOME3R/.local/share/pi-node/current/bin:$BIN:$PATH" bash "$STAGE/install.sh" 2>&1; }
out="$(_prog3r)"; rc=$?
ck "$([ "$rc" -eq 0 ] && echo 0 || echo 1)" "A3c run 1: the shipped route pins into the pin root (rc=$rc)"
PIN_DIR_3R="$(head -1 "$SHOME3R/.harness-path" 2>/dev/null)"
rm -f "$SHOME3R/.harness-path"
printf '# hand edit\n' >> "$FX3/scripts/orchestrator-harness/orch-loop.sh"     # the checkout is now DIRTY
out="$(_prog3r)"; rc=$?
ck "$([ "$rc" -eq 0 ] && echo 0 || echo 1)" "A3c run 2: a missing dir record still installs (rc=$rc; out=$(printf %s "$out" | tail -2 | tr "\n" " "))"
ck "$([ "$(head -1 "$SHOME3R/.harness-path" 2>/dev/null)" = "$PIN_DIR_3R" ] && echo 0 || echo 1)" \
   "…and records the PIN-ROOT tree, not the (now dirty) checkout"
ck "$([ "$(head -1 "$SHOME3R/.harness-path" 2>/dev/null)" != "$FX3H" ] && echo 0 || echo 1)" \
   "…NEVER the operator's checkout"
git -C "$FX3" checkout -q -- scripts/orchestrator-harness/orch-loop.sh 2>/dev/null || true

# B6 — THE HOME-DIR-ONLY ENTRYPOINT. A box that is LIVE on `launchd-controller.sh` (the tmux/Full-Disk-
# Access wrapper that exists in NO commit — PR #2020 lifts it) must not be silently moved onto the
# pin's `orch-loop.sh`: that would drop the wrapper and every candidate would be refused with
# "could not build claim commit" (docs/ops/fleet-harness-baseline.md §3.1). Refuse, name it.
SHOME7="$T/home7"; mkdir -p "$SHOME7/Library/LaunchAgents"; O7="$T/o7"; mkdir -p "$O7"
printf '#!/bin/bash\necho wrapper\n' > "$O7/launchd-controller.sh"
# ⛔ THE EVIDENCE IS THE INSTALLED JOB, NOT A FILE IN `$O`. `$O` is the worker seed, so a leftover copy
# there is NOT proof that anything runs it — a box whose plist already names the pin's `orch-loop.sh`
# must NOT be blocked by it (review finding, P1: the first form of this refusal was a permanent false
# block on exactly that box). So the arm writes the plist the box is actually running.
P7="$SHOME7/Library/LaunchAgents/com.eldato.orchestrator-loop.plist"
cat > "$P7" <<PLIST7
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>Label</key><string>com.eldato.orchestrator-loop</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$O7/launchd-controller.sh</string>
  </array>
</dict></plist>
PLIST7
out="$(env HOME="$SHOME7" O="$O7" REPO="$FX" OR="acme/widget" HARNESS="$FXH" \
        ELDATO_ALLOW_NON_DARWIN=1 ELDATO_ALLOW_TEST_HOME=1 \
        PATH="$BIN:$PATH" bash "$STAGE/install.sh" 2>&1)"; rc=$?
ck "$([ "$rc" -eq 78 ] && echo 0 || echo 1)" "a LIVE-ONLY entrypoint the pin does not carry is REFUSED (rc=$rc; out=$(printf %s "$out" | tail -2 | tr "\n" " "))"
ck "$(has "$out" "LIVE-ONLY entrypoint" && echo 0 || echo 1)" "…and the refusal names the class"
ck "$(has "$out" "$O7/launchd-controller.sh" && echo 0 || echo 1)" "…and names the installed program that would have been lost"
# The false-block companion: the SAME leftover `$O/launchd-controller.sh`, but the installed job already
# runs the pin's `orch-loop.sh` — nothing is lost, so nothing may be refused.
SHOME9="$T/home9"; mkdir -p "$SHOME9/Library/LaunchAgents"
P9="$SHOME9/Library/LaunchAgents/com.eldato.orchestrator-loop.plist"
cat > "$P9" <<PLIST9
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>Label</key><string>com.eldato.orchestrator-loop</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$FXH/orch-loop.sh</string>
  </array>
</dict></plist>
PLIST9
out="$(env HOME="$SHOME9" O="$O7" REPO="$FX" OR="acme/widget" HARNESS="$FXH" \
        ELDATO_ALLOW_NON_DARWIN=1 ELDATO_ALLOW_TEST_HOME=1 \
        PATH="$BIN:$PATH" bash "$STAGE/install.sh" 2>&1)"; rc=$?
ck "$([ "$rc" -eq 0 ] && echo 0 || echo 1)" "a leftover \$O entrypoint does NOT block a box whose installed job already runs the pin (rc=$rc; out=$(printf %s "$out" | tail -2 | tr "\n" " "))"
# …and once the pin CARRIES an entrypoint, that entrypoint is what the job runs (so #2020's landing is
# effective without a second change here).
FXH2="$T/repo2/scripts/orchestrator-harness"
mkdir -p "$FXH2"
( cd "$T/repo2" && git init -q -b main . >/dev/null 2>&1 && printf '.worktrees/\n' > .gitignore \
  && cp "$FXH"/*.sh "$FXH2/" && printf '#!/bin/bash\necho wrapper\n' > "$FXH2/launchd-controller.sh" \
  && git add -A >/dev/null 2>&1 && git -c user.email=t@t -c user.name=t commit -qm base >/dev/null 2>&1 \
  && git update-ref refs/remotes/origin/main HEAD ) >/dev/null 2>&1
SHOME8="$T/home8"; mkdir -p "$SHOME8/Library/LaunchAgents"
out="$(env HOME="$SHOME8" O="$O7" REPO="$T/repo2" OR="acme/widget" HARNESS="$FXH2" \
        ELDATO_ALLOW_NON_DARWIN=1 ELDATO_ALLOW_TEST_HOME=1 \
        PATH="$BIN:$PATH" bash "$STAGE/install.sh" 2>&1)"; rc=$?
P8="$SHOME8/Library/LaunchAgents/com.eldato.orchestrator-loop.plist"
ck "$([ "$rc" -eq 0 ] && echo 0 || echo 1)" "a pin that CARRIES the entrypoint installs (rc=$rc; out=$(printf %s "$out" | tail -2 | tr "\n" " "))"
ck "$([ "$(plist_program "$P8" 2>/dev/null)" = "$FXH2/launchd-controller.sh" ] && echo 0 || echo 1)" \
   "…and the job runs the PINNED entrypoint, not \$O's copy"
# ⛔ ONE PROGRAM LINE, AND IT NAMES THE PROGRAM THE JOB WILL EXEC (review P5). The installer used to print
# `harness pinned … the job will exec <pin>/orch-loop.sh` BEFORE `HARNESS_ENTRY` was chosen, so a pin
# carrying the entrypoint printed two contradictory programs; and the documented recovery `pkill` still
# matched `$O/orch-loop.sh`, which after this change is not the daemon's argv.
_prog_lines="$(printf '%s\n' "$out" | grep -c 'job will exec\|^  ✓ program:' || true)"
ck "$([ "${_prog_lines:-0}" -eq 1 ] && echo 0 || echo 1)" "exactly ONE program line is printed (got $_prog_lines)"
ck "$(has "$out" "job will exec" && echo 1 || echo 0)" "…and it no longer names a program before the entrypoint is chosen"
ck "$(has "$out" "program: $FXH2/launchd-controller.sh" && echo 0 || echo 1)" "…and the named program is the PINNED entrypoint"
ck "$(has "$out" "pkill -f \"[b]ash $FXH2/launchd-controller.sh\"" && echo 0 || echo 1)" \
   "…and the recovery pkill pattern is the program the daemon actually has"

# B6b — A JOB THAT DECLARES ITS PROGRAM WITH THE `Program` KEY (review P2, fail-open). launchd accepts
# that spelling; the parser read only ProgramArguments, so the job parsed as EMPTY and the gate read
# "nothing is running" — silently dropping the very wrapper it exists to protect.
SHOME7b="$T/home7b"; mkdir -p "$SHOME7b/Library/LaunchAgents"
P7b="$SHOME7b/Library/LaunchAgents/com.eldato.orchestrator-loop.plist"
cat > "$P7b" <<PLIST7B
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>Label</key><string>com.eldato.orchestrator-loop</string>
  <key>Program</key>
  <string>$O7/launchd-controller.sh</string>
</dict></plist>
PLIST7B
out="$(env HOME="$SHOME7b" O="$O7" REPO="$FX" OR="acme/widget" HARNESS="$FXH" \
        ELDATO_ALLOW_NON_DARWIN=1 ELDATO_ALLOW_TEST_HOME=1 \
        PATH="$BIN:$PATH" bash "$STAGE/install.sh" 2>&1)"; rc=$?
ck "$([ "$rc" -eq 78 ] && echo 0 || echo 1)" "a \`Program\`-key job running the live-only entrypoint is REFUSED (rc=$rc; out=$(printf %s "$out" | tail -2 | tr "\n" " "))"
ck "$(has "$out" "LIVE-ONLY entrypoint" && echo 0 || echo 1)" "…and names the class (the Program key is READ, not skipped)"
# …and a plist whose program cannot be parsed at all is CANNOT-VERIFY, never "nothing to lose".
SHOME7c="$T/home7c"; mkdir -p "$SHOME7c/Library/LaunchAgents"
P7c="$SHOME7c/Library/LaunchAgents/com.eldato.orchestrator-loop.plist"
printf 'binary-plist-junk' > "$P7c"
out="$(env HOME="$SHOME7c" O="$T/o7c" REPO="$FX" OR="acme/widget" HARNESS="$FXH" \
        ELDATO_ALLOW_NON_DARWIN=1 ELDATO_ALLOW_TEST_HOME=1 \
        PATH="$BIN:$PATH" bash "$STAGE/install.sh" 2>&1)"; rc=$?
ck "$([ "$rc" -eq 78 ] && echo 0 || echo 1)" "an INSTALLED job whose program cannot be parsed is REFUSED (cannot-verify), not read as 'nothing running' (rc=$rc; out=$(printf %s "$out" | tail -2 | tr "\n" " "))"
ck "$(has "$out" "cannot be READ" && echo 0 || echo 1)" "…and the refusal says the program could not be read"

# B6d — A JOB THAT PASSES AN ARGUMENT (review P2/P3). The program is the first non-interpreter token,
# not the LAST <string>: taking the last read `status` as the program, concluded "no live-only
# entrypoint", and OVERWROTE the wrapper. And a token beginning with `-` made `basename` abort the whole
# installer with its own stderr and no refusal at all.
for _arg in status --keep; do
  SHOME7e="$T/home7e$(printf '%s' "$_arg" | tr -d '-')"; mkdir -p "$SHOME7e/Library/LaunchAgents"
  P7e="$SHOME7e/Library/LaunchAgents/com.eldato.orchestrator-loop.plist"
  cat > "$P7e" <<PLIST7E
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>Label</key><string>com.eldato.orchestrator-loop</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$O7/launchd-controller.sh</string>
    <string>$_arg</string>
  </array>
</dict></plist>
PLIST7E
  out="$(env HOME="$SHOME7e" O="$O7" REPO="$FX" OR="acme/widget" HARNESS="$FXH" \
          ELDATO_ALLOW_NON_DARWIN=1 ELDATO_ALLOW_TEST_HOME=1 \
          PATH="$BIN:$PATH" bash "$STAGE/install.sh" 2>&1)"; rc=$?
  ck "$([ "$rc" -eq 78 ] && echo 0 || echo 1)" "a job running the live-only entrypoint WITH the argument '$_arg' is REFUSED (rc=$rc; out=$(printf %s "$out" | tail -2 | tr "\n" " "))"
  ck "$(has "$out" "LIVE-ONLY entrypoint" && echo 0 || echo 1)" "…and the refusal names the class (the program is the script, not '$_arg')"
done

# B6f — LAYOUT AND WHITESPACE (review finding, P1): the program parser must read a ONE-LINE plist (what a
# hand-edited install looks like) and a program path containing a SPACE. Both were lost by the earlier
# parsers — the gate failed OPEN on a one-line `Program` key and the post-render assertion refused a
# correct render.
SHOME7g="$T/home7g"; mkdir -p "$SHOME7g/Library/LaunchAgents"
P7g="$SHOME7g/Library/LaunchAgents/com.eldato.orchestrator-loop.plist"
printf '%s' "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>Label</key><string>com.eldato.orchestrator-loop</string><key>Program</key><string>$O7/launchd-controller.sh</string></dict></plist>" > "$P7g"
out="$(env HOME="$SHOME7g" O="$O7" REPO="$FX" OR="acme/widget" HARNESS="$FXH" \
        ELDATO_ALLOW_NON_DARWIN=1 ELDATO_ALLOW_TEST_HOME=1 \
        PATH="$BIN:$PATH" bash "$STAGE/install.sh" 2>&1)"; rc=$?
ck "$([ "$rc" -eq 78 ] && echo 0 || echo 1)" "a ONE-LINE \`Program\` plist is still read (rc=$rc, the gate does not fail open)"
ck "$(has "$out" "LIVE-ONLY entrypoint" && echo 0 || echo 1)" "…and the live-only entrypoint is named"
# A pin whose path contains a SPACE: the rendered program must survive the post-render assertion.
FXSP="$T/pin dir"; mkdir -p "$FXSP"; cp -r "$FX"/. "$FXSP"/ 2>/dev/null
SHOME7h="$T/home7h"; mkdir -p "$SHOME7h/Library/LaunchAgents"
out="$(env HOME="$SHOME7h" O="$T/o7h" REPO="$FXSP" OR="acme/widget" HARNESS_REPO="$FXSP" \
        HARNESS="$FXSP/scripts/orchestrator-harness" \
        ELDATO_ALLOW_NON_DARWIN=1 ELDATO_ALLOW_TEST_HOME=1 LC_SETTLE=1 START_TIMEOUT=2 \
        PATH="$SHOME7h/.local/share/pi-node/current/bin:$BIN:$PATH" \
        bash "$STAGE/install.sh" 2>&1)"; rc=$?
ck "$([ "$rc" -eq 0 ] && echo 0 || echo 1)" "a pin path containing a SPACE installs (rc=$rc, the post-render assertion accepts the correct program)"
ck "$(has "$(plist_program "$SHOME7h/Library/LaunchAgents/com.eldato.orchestrator-loop.plist" 2>/dev/null)" "$FXSP/scripts/orchestrator-harness/orch-loop.sh" && echo 0 || echo 1)" \
   "…and the rendered program IS that path, space and all"

# B6c — `set -e` HAZARDS IN THE RECORD CAPTURES (review P4). A pin RECORD that is a directory used to
# abort the installer with `head`'s status and NO message; the block promises a named rc=78 refusal.
SHOME7d="$T/home7d"; mkdir -p "$SHOME7d/Library/LaunchAgents" "$SHOME7d/.pi/agent/state/HARNESS-PIN"
out="$(env HOME="$SHOME7d" O="$T/o7d" REPO="$FX" OR="acme/widget" HARNESS="$FXH" \
        ELDATO_ALLOW_NON_DARWIN=1 ELDATO_ALLOW_TEST_HOME=1 \
        PATH="$BIN:$PATH" bash "$STAGE/install.sh" 2>&1)"; rc=$?
ck "$([ "$rc" -eq 78 ] && echo 0 || echo 1)" "a pin sha record that is a DIRECTORY is refused by NAME (rc=$rc, not a silent exit 1)"
ck "$(has "$out" "REFUSED (pin)" && echo 0 || echo 1)" "…and the refusal is the installer's own, with a message"

# B7 — THE POST-RENDER BACKSTOP. `install.sh` parses the program back OUT of the file it just rendered and
# refuses when it is not `<pin>/<entry>`. Nothing else exercises that refusal: every other fixture renders
# the CURRENT template, whose token already agrees with the pin — so a stale/deviant template (a staging
# copy from an older checkout, the exact "which copy you run decides the effect" hazard in
# docs/ops/fleet-harness-baseline.md §3.1) would sail through with the suite green (review finding, P2).
# The mutation below IS that deviant template: one rule rewritten to the pre-change `__O__` program.
STAGE_OLD="$T/stage-old"; mkdir -p "$STAGE_OLD"
cp "$STAGE/install.sh" "$STAGE/launchd-cycle.sh" "$STAGE/refresh-candidates.sh" "$STAGE/merge-reminder.py" "$STAGE_OLD/" 2>/dev/null
sed 's|<string>__HARNESS__/__ENTRY__</string>|<string>__O__/orch-loop.sh</string>|' "$TEMPLATE" > "$STAGE_OLD/launchd.plist.template"
SHOME10="$T/home10"; mkdir -p "$SHOME10/Library/LaunchAgents"
out="$(env HOME="$SHOME10" O="$T/o10" REPO="$FX" OR="acme/widget" HARNESS_REPO="$FX" HARNESS="$FXH" \
        ELDATO_ALLOW_NON_DARWIN=1 ELDATO_ALLOW_TEST_HOME=1 \
        PATH="$BIN:$PATH" bash "$STAGE_OLD/install.sh" 2>&1)"; rc=$?
ck "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" "a template that renders the OLD \`\$O\` program is REFUSED (rc=$rc; out=$(printf %s "$out" | tail -2 | tr "\n" " "))"
ck "$(has "$out" "the plist and the pin disagree" && echo 0 || echo 1)" "…and the refusal says the plist and the pin disagree"
ck "$(has "$out" "$FXH/orch-loop.sh" && echo 0 || echo 1)" "…and names the program the pin resolved"
ck "$([ ! -f "$SHOME10/Library/LaunchAgents/com.eldato.orchestrator-loop.plist" ] && echo 0 || echo 1)" \
   "…and NOTHING was installed (the refusal is atomic: the previous plist is untouched)"

# B6e — a `HARNESS-PIN` that is a DIRECTORY is NOT an absent pin (review finding, pre-existing fail-open in
# the function this PR changes): `-e` is true for a directory and `head -1 <dir>` yields nothing, which
# `hu_verify_pin` read as "ABSENT, the first start records it" (rc=0).
SHOME7f="$T/home7f"; mkdir -p "$SHOME7f/Library/LaunchAgents" "$SHOME7f/.pi/agent/state/HARNESS-PIN"
_hs="$(CELL_HOME="$SHOME7f" HOME="$SHOME7f" O="$T/o7f" REPO="$FX" HARNESS_PIN_DIR="$SHOME7f/harness" HARNESS="$FXH" \
       bash "$REPO_ROOT/scripts/harness-up" status 2>&1)"
ck "$(has "$_hs" "ABSENT" && echo 1 || echo 0)" "a directory-shaped HARNESS-PIN is NOT read as an absent pin"
ck "$(has "$_hs" "NOT A REGULAR FILE" && echo 0 || echo 1)" "…it is named for what it is"

sec "C. the LIVE arm: every installed job runs its program from the PIN (macOS)"
# ⛔ THIS IS THE ARM THAT WOULD HAVE CAUGHT TONIGHT'S STATE. It reads the plists launchd will actually
# load — not a fixture — and for every job whose program is a script THIS REPO CARRIES it asserts the
# configured path is inside the pinned tree. A box still pointing at `~/orchestrator/…` or
# `~/.cache/orc/…` is RED here, by name, with both paths, instead of drifting silently for a week.
# SKIPPED-with-a-reason where there is nothing to read (a Linux CI runner has no LaunchAgents); a skip
# is never a pass, and the reason is printed.
LG="${MAC_PIN_LAUNCHAGENTS:-$HOME/Library/LaunchAgents}"
case "$PLATFORM" in
  Darwin) ;;
  *) skip "not macOS ($PLATFORM) — the installed-plist arm has nothing to read here; the hermetic arms above still ran" ;;
esac
if [ "$PLATFORM" = "Darwin" ]; then
  if [ ! -d "$LG" ]; then
    skip "no $LG on this box — nothing is installed to compare (NOT a pass)"
  else
    PIN_TREE=""
    for f in "${HARNESS_PIN_FILE:-$HOME/.harness-path}" "$HOME/.harness-path" "${CELL_HOME:-$HOME}/.harness-path"; do
      [ -f "$f" ] && { PIN_TREE="$(head -1 "$f" 2>/dev/null)"; break; }
    done
    if [ -z "$PIN_TREE" ]; then
      bad "no .harness-path on this Mac — the controller has no pin, which is exactly the divergence this suite exists for (fix: bash scripts/harness-up up)"
    else
      ok "this Mac's pin dir record names $PIN_TREE"
      n_jobs=0; n_bad=0
      for pl in "$LG"/*.plist; do
        [ -f "$pl" ] || continue
        n_jobs=$((n_jobs+1))
        prog="$(plist_program "$pl")"
        [ -n "$prog" ] || continue
        base="$(basename "$prog")"
        # Only jobs whose program is a script THIS REPO CARRIES are in scope: a job running something
        # else entirely (a node daemon, a vendor binary) is not a harness divergence.
        if [ ! -f "$REPO_ROOT/scripts/$base" ] && [ ! -f "$REPO_ROOT/scripts/orchestrator-harness/$base" ] \
           && [ ! -f "$REPO_ROOT/tools/fleet/$base" ]; then
          continue
        fi
        case "$prog" in
          "$PIN_TREE"/*) ok "$(basename "$pl" .plist): program is inside the pin ($prog)" ;;
          *) n_bad=$((n_bad+1))
             bad "$(basename "$pl" .plist): program is NOT in the pinned tree — configured $prog, pin names $PIN_TREE (this job runs a copy the repo does not pin)" ;;
        esac
      done
      ck "$([ "$n_jobs" -gt 0 ] && echo 0 || echo 1)" "at least one launchd job was examined (n=$n_jobs)"
      [ "$n_bad" -eq 0 ] && ok "no installed job runs a repo script from outside the pin" || true
    fi
  fi
fi

sec "D. no fix that lived only in a home directory is lost"
# ⛔ A REGISTER, NOT A CHANGELOG. Each entry is a fix that existed ONLY in a Mac's home-dir copy and now
# lives in the repo, with the file that CARRIES it and the suite that WITNESSES it. The witness is the
# half that matters: a revert of the carrier leaves the suite red, and a carrier whose suite is dropped
# from the one shard list stops being run at all (which is how a fix dies quietly). Both are asserted.
# ⚠️ SHAPE: "<name>|<carrier path>|<witness suite>"
FIX_REGISTER="
bounded gh presence probe (no bare \`gh auth token\`)|scripts/orchestrator-harness/refresh-candidates.sh|scripts/orchestrator-harness/origination-funnel.test.sh
the owner's worklist rides the FLEET ADVANCE order|scripts/orchestrator-heartbeat.sh|tests/heartbeat-fleet-advance/run.sh
cell bring-up traps (born-pinned worktree, global GH_REPO, tmux env)|scripts/cloud-cell-bringup.sh|scripts/cloud-cell-bringup.test.sh
the Mac's controller runs its launchd program from the pin|scripts/orchestrator-harness/install.sh|scripts/mac-pin-parity.test.sh
"
SHARD_LIST="$REPO_ROOT/scripts/run-bash-shards.sh"
while IFS='|' read -r name carrier witness; do
  [ -n "${name// /}" ] || continue
  need "$REPO_ROOT/$carrier" >/dev/null 2>&1 && ok "carrier present: $carrier" || bad "carrier MISSING for '$name': $carrier"
  need "$REPO_ROOT/$witness" >/dev/null 2>&1 && ok "witness present: $witness" || bad "witness MISSING for '$name': $witness"
  if grep -q "$(basename "$witness")" "$SHARD_LIST" 2>/dev/null; then
    ok "witness is WIRED into the one shard list: $(basename "$witness")"
  else
    bad "witness $(basename "$witness") is NOT in scripts/run-bash-shards.sh — a suite nothing runs is not a witness"
  fi
done <<REG
$FIX_REGISTER
REG

sec "E. portability: nothing reaches for a tool macOS does not have"
# `timeout`/`gtimeout` are GNU coreutils (macOS ships neither); BSD `pgrep` has no `-c`. The launcher
# and the refresh use perl's alarm and `ps` instead — and those habits are worthless if a new arm
# quietly reintroduces the shortcuts, so the gate covers the files this change touches.
# ⛔ THE NEEDLES ARE ASSEMBLED AT RUNTIME ON PURPOSE. A gate that greps for a literal it also contains
# reports itself: the first draft of this section was RED on this very file, because the forbidden word
# appears in its own refusal message. Splitting the token keeps the SCAN honest (it still finds the
# word in code) while the suite's own text cannot satisfy it.
GTO="gtime""out"; TMO="time""out"; PGC="pgrep"" -c"
portability_scan() { # <file>
  local f="$1" code rc=0
  [ -f "$f" ] || { bad "portability target missing: $f"; return 1; }
  # Strip comments before the scan: these files NAME the forbidden tools in prose, repeatedly, to
  # explain why they are absent. A scan that counted the explanation would be red on a correct file.
  code="$(sed -e 's/[[:space:]]#.*$//' -e '/^[[:space:]]*#/d' "$f")"
  case "$code" in *"$GTO"*) bad "$(basename "$f") uses $GTO (absent on macOS without Homebrew coreutils)"; rc=1 ;; *) ok "$(basename "$f") does not reach for $GTO" ;; esac
  case "$code" in *"$PGC"*) bad "$(basename "$f") uses '$PGC' (BSD pgrep has no -c)"; rc=1 ;; *) ok "$(basename "$f") does not reach for '$PGC'" ;; esac
  # `timeout <secs>` as a COMMAND (not the word in a sentence): the shape that is rc=127 on the Mac half.
  # A here-string, NOT a pipe: `grep -q` exits on the first match, and under the pipeline the writer
  # takes SIGPIPE — the repo-wide `check-no-sigpipe-grep.sh` gate exists for exactly this shape.
  if grep -Eq '(^|[^[:alnum:]_.-])'"$TMO"'[[:space:]]+[0-9]' <<<"$code"; then
    bad "$(basename "$f") calls \`$TMO\` as a command (rc=127 on macOS)"; rc=1
  else
    ok "$(basename "$f") does not call \`$TMO\` as a command"
  fi
  return "$rc"
}
for f in "$HERE/harness-up" "$HERE/orchestrator-bringup.sh" "$INSTALL" "$HERE/mac-pin-parity.test.sh"; do
  portability_scan "$f" || true
done

sec "summary"
printf '\n==> %d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
if [ "$PASS" -lt 25 ]; then
  # Non-vacuity floor: an early `exit` or a broken fixture must not read as a clean run.
  bad "non-vacuity floor: only $PASS assertions ran (expected at least 25) — the suite did not exercise its arms"
fi
[ "$FAIL" -eq 0 ] || { printf 'ALL FAIL\n'; exit 1; }
printf 'ALL PASS\n'
