#!/usr/bin/env bash
# refresh-scout.test.sh — the regression contract for agent-infra#1736.
#
# THE DEFECT. `refresh-candidates.sh` — the step that provisions the dispatch scout and refills the
# dispatch backlog — hardcoded a TORTOISE-shaped repo: `uv sync --extra embeddings --extra parity`
# (`embeddings`/`parity` are tortoise extras, and the target may have no `pyproject.toml` at all)
# and tortoise's `tools/collision_preflight.py` (which agent-infra does not carry). A cell pointed
# at a non-Python repo therefore aborted EVERY cycle, and because orch-loop.sh runs this script in a
# BACKGROUNDED subshell the non-zero exit could not fail the loop: the controller reported RUNNING
# with `lanes: 0` forever — a cell that looks alive and can only merge. Measured 2026-10-14 on the
# first cmux cloud cell pointed at agent-infra: `No 'pyproject.toml' found`.
#
# HOW THESE CHECKS ARE WRITTEN. Every check drives the SHIPPED script (or the shipped orch-loop.sh
# block, extracted verbatim) — never a re-implementation, which would pass on the broken copy too.
# The scout worktree is pre-created as a plain directory, so no real `git worktree`, network, uv or
# gh is touched: `gh` is a stub, `uv` is a stub pinned through SCOUT_UV, and `HOME` is a sandbox so
# the real tortoise checkout is never discovered by the fallback resolver.
#
# ⛔ WHY SCOUT_UV, NOT JUST A PATH STUB (agent-infra#1748 review). The shipped script used to
# hard-prepend /opt/homebrew/bin:/usr/local/bin, so a stub merely placed first in the CALLER's PATH
# was outranked by a real `uv` in those dirs — on the cmux cell (`/usr/local/bin/uv`) and on any
# Homebrew macOS box this suite silently ran the REAL `uv sync --extra …` (network, `.venv`
# writes), failed 4 checks, and reported a false "33 PASS". The script now appends those dirs and
# resolves `uv` through `${SCOUT_UV:-uv}`, so the stub below is authoritative regardless of what
# the host has installed.
#
# Run:  bash scripts/orchestrator-harness/refresh-scout.test.sh

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REFRESH="$HERE/refresh-candidates.sh"
LOOP="$HERE/orch-loop.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ❌ $1"; }
T="$(mktemp -d "${TMPDIR:-/tmp}/refresh-scout.XXXXXX")"
trap 'rm -rf "$T"' EXIT
echo "==> refresh-candidates scout-provisioning contract ($HERE)"

[ -f "$REFRESH" ] || { echo "  ❌ missing $REFRESH"; exit 1; }

# mk_case <name> — a sandbox whose scout worktree already EXISTS as a plain dir (so the shipped
# script skips `git worktree add` and does not need a repo/remote). Sets $D.
D=""
mk_case() {
  D="$T/$1"; mkdir -p "$D/home" "$D/bin" "$D/o" "$D/repo/.worktrees/dispatch-scout"
  # `gh` succeeds and lists NOTHING: the reaper then sees a readable, empty answer (which it is
  # entitled to reap against) and the pool comes out empty unless a case stubs otherwise.
  printf '#!/bin/bash\nexit 0\n' > "$D/bin/gh"; chmod +x "$D/bin/gh"
}
# rf <dir> <refresh|check> [KEY=VAL ...] — runs the SHIPPED script hermetically; $OUT/$RC.
# RF_PATH overrides the constructed PATH for the one case that must have no `uv` on it. The ambient
# provisioning knobs are CLEARED every run, so a case's own values are the only ones in play and an
# operator's exported TORTOISE_REPO/TORTOISE/SCOUT_UV cannot leak into the sandbox.
OUT=""; RC=0
rf() {
  local dir="$1" mode="$2"; shift 2
  local args=(6); [ "$mode" = check ] && args=(--check)
  local paths="${RF_PATH:-$dir/bin:$PATH}"
  OUT="$(env -u TORTOISE_REPO -u TORTOISE -u SCOUT_UV \
          HOME="$dir/home" PATH="$paths" REPO="$dir/repo" O="$dir/o" "$@" \
          bash "$REFRESH" "${args[@]}" 2>&1)"
  RC=$?
}
# mk_tool <path> — a stand-in pre-flight tool that answers CLEAN. Records argv + cwd when
# $TOOL_LOG is exported, so precedence and the `--repo .` cwd can be asserted.
mk_tool() {
  mkdir -p "$(dirname "$1")"
  cat > "$1" <<'PY'
#!/usr/bin/env python3
import os, sys
log = os.environ.get("TOOL_LOG")
if log:
    with open(log, "a") as fh:
        fh.write("%s|%s\n" % (os.getcwd(), " ".join(sys.argv[1:])))
print("VERDICT: CLEAN")
PY
  chmod +x "$1"
}
# mk_uv_ok <dir> — a `uv` stub that RECORDS its argv and produces a runnable interpreter.
mk_uv_ok() {
  cat > "$1/bin/uv" <<EOF
#!/bin/bash
echo "\$*" >> "$1/uv-args"
mkdir -p .venv/bin
printf '#!/bin/bash\\nprintf "VERDICT: CLEAN\\\\n"\\n' > .venv/bin/python
chmod +x .venv/bin/python
exit 0
EOF
  chmod +x "$1/bin/uv"
}
# mk_old_python <path> — a python SHIM standing in for an interpreter OLDER than the pre-flight
# tool's minimum (3.12). It answers the version probe with a <3.12 answer and reproduces the tool's
# own guard (exit 3, NO `VERDICT`) for anything else — exactly what tortoise's
# tools/collision_preflight.py does under a 3.9/3.10 interpreter (tortoise #5128). Pinned through
# SCOUT_PY, so the case is deterministic even on a host whose /usr/local/bin/python3 is >=3.12.
mk_old_python() {
  cat > "$1" <<'SH'
#!/bin/bash
case "$1" in
  -c) case "${2:-}" in *version_info*) exit 1 ;; *) exit 0 ;; esac ;;
esac
echo "collision-preflight: requires Python >= 3.12 (got 3.9) — run it as \`uv run python tools/collision_preflight.py\`" >&2
exit 3
SH
  chmod +x "$1"
}

# ── 1) a repo with NO pyproject.toml must PROCEED, not abort (the measured defect) ──────────────
# Tortoise's tool is resolved through the fallback, and the venv step is skipped because it is
# genuinely NOT APPLICABLE — not because a failure was swallowed. The `uv` stub exits 99 and
# records, so "skipped" is proven by uv never being invoked.
mk_case no-pyproject
mk_tool "$D/tort/tools/collision_preflight.py"
printf '#!/bin/bash\necho "UV-WAS-CALLED $*" >> "%s/uv-args"\nexit 99\n' "$D" > "$D/bin/uv"; chmod +x "$D/bin/uv"
rf "$D" refresh TORTOISE_REPO="$D/tort" SCOUT_UV="$D/bin/uv"
[ "$RC" -eq 0 ] && ok "no pyproject.toml: the refresh PROCEEDS (rc=0, was an abort every cycle)" \
                || bad "no pyproject.toml: rc=$RC (want 0) — output: $OUT"
case "$OUT" in
  *"no pyproject.toml"*"skipping"*) ok "no pyproject.toml: the skip is NAMED as not-applicable" ;;
  *) bad "no pyproject.toml: the not-applicable skip is not reported — output: $OUT" ;;
esac
case "$OUT" in
  *"ABORT"*) bad "no pyproject.toml: still ABORTS — output: $OUT" ;;
  *) ok "no pyproject.toml: no ABORT (the silent-loop defect is gone)" ;;
esac
[ ! -e "$D/uv-args" ] && ok "no pyproject.toml: the venv step was NOT RUN (uv never invoked)" \
                      || bad "no pyproject.toml: uv was invoked — $(cat "$D/uv-args")"

# ── 1b) the bare-python3 fallback is VERSION-GATED (agent-infra#1748 review P1) ─────────────────
# The pre-flight tool refuses a <3.12 interpreter with exit 3 and NO `VERDICT` (tortoise #5128).
# Nothing here used to check the version, so a cell whose `python3` was the macOS CLT 3.9 shim (or
# Ubuntu 22.04's 3.10) had `--check` print CHECK OK, the refresh queue nothing and exit 0, and no
# `.refresh-blocked` marker written — merge-only and silent. On the PRE-FIX code SCOUT_PY did not
# exist, so the assertions below fail there (the real interpreter ran and the tool "answered").
mk_case old-python
mk_tool "$D/tort/tools/collision_preflight.py"
mk_old_python "$D/bin/oldpy"
rf "$D" check TORTOISE_REPO="$D/tort" SCOUT_PY="$D/bin/oldpy"
[ "$RC" -eq 3 ] && ok "--check: an interpreter older than the tool's minimum is REFUSED (rc=3)" \
               || bad "--check: accepted an old interpreter — rc=$RC — $OUT"
case "$OUT" in
  *"CHECK OK"*) bad "--check: printed CHECK OK for an old interpreter" ;;
  *) ok "--check: no CHECK OK for an old interpreter" ;;
esac
case "$OUT" in
  *"Python >= 3.12"*) ok "--check: the refusal names the tool's minimum (Python >= 3.12)" ;;
  *) bad "--check: the refusal does not name the minimum — output: $OUT" ;;
esac
# (run) the same interpreter on the refresh path must be PERMANENT (rc=3), so orch-loop.sh writes
# the merge-only marker instead of the script exiting 0 with an empty backlog.
mk_case old-python-run
mk_tool "$D/repo/.worktrees/dispatch-scout/tools/collision_preflight.py"
mk_old_python "$D/bin/oldpy"
rf "$D" refresh SCOUT_PY="$D/bin/oldpy"
[ "$RC" -eq 3 ] && ok "old interpreter (run): rc=3 (PERMANENT — a marker, not a silent 0)" \
               || bad "old interpreter (run): rc=$RC (want 3) — output: $OUT"
case "$OUT" in
  *"NOT PROVISIONABLE"*) ok "old interpreter (run): the refusal is LOUD and named" ;;
  *) bad "old interpreter (run): no NOT PROVISIONABLE verdict — output: $OUT" ;;
esac
[ ! -s "$D/o/candidates.txt" ] && ok "old interpreter (run): nothing is queued" \
                              || bad "old interpreter (run): queued candidates — $(cat "$D/o/candidates.txt" 2>/dev/null)"

# ── 1c) a pre-flight that REFUSES TO RUN is PERMANENT, not a per-issue "no verdict" (#1748 P1) ──
# The tool's EXIT_USAGE (3) reports an unusable environment with NO `VERDICT` line. Absorbing that
# into the `*)` arm left the script exiting 0 and no marker written: RUNNING with `lanes: 0`. The
# stub reproduces exit 3 exactly. On the PRE-FIX code the `*)` arm runs and rc is 0.
mk_case preflight-usage
mkdir -p "$D/repo/.worktrees/dispatch-scout/tools"
cat > "$D/repo/.worktrees/dispatch-scout/tools/collision_preflight.py" <<'PY'
#!/usr/bin/env python3
import sys
print("collision-preflight: simulated usage/environment failure", file=sys.stderr)
raise SystemExit(3)
PY
chmod +x "$D/repo/.worktrees/dispatch-scout/tools/collision_preflight.py"
cat > "$D/bin/gh" <<'SH'
#!/bin/bash
case "$*" in *"--label P0-blocker"*) printf '0 42\n' ;; esac
exit 0
SH
chmod +x "$D/bin/gh"
rf "$D" refresh
[ "$RC" -eq 3 ] && ok "pre-flight exits 3 (no VERDICT): the refresh is PERMANENT rc=3, not a silent 0" \
               || bad "pre-flight exits 3: rc=$RC (want 3) — output: $OUT"
case "$OUT" in
  *"NOT PROVISIONABLE"*) ok "pre-flight exits 3: the refusal is LOUD and named" ;;
  *) bad "pre-flight exits 3: no NOT PROVISIONABLE verdict — output: $OUT" ;;
esac
[ ! -s "$D/o/candidates.txt" ] && ok "pre-flight exits 3: nothing is queued" \
                              || bad "pre-flight exits 3: queued candidates — $(cat "$D/o/candidates.txt" 2>/dev/null)"

# ── 2) the tool is resolved PER REPO: the repo's OWN copy wins, run from the scout with --repo . ─
# Structural, not textual: the stub tool records its cwd and argv, and the candidate it cleared must
# reach the backlog — which can only happen if the resolved tool actually ran.
mk_case own-tool
mk_tool "$D/repo/.worktrees/dispatch-scout/tools/collision_preflight.py"
cat > "$D/bin/gh" <<'SH'
#!/bin/bash
case "$*" in *"--label P0-blocker"*) printf '0 42\n' ;; esac
exit 0
SH
chmod +x "$D/bin/gh"
rf "$D" refresh TORTOISE_REPO="$D/tort" TOOL_LOG="$D/tool-log"
[ "$RC" -eq 0 ] && ok "own tool: the refresh proceeds (rc=0)" || bad "own tool: rc=$RC — $OUT"
case "$(tr '\n' ' ' < "$D/o/candidates.txt" 2>/dev/null)" in
  *42*) ok "own tool: the pre-flighted CLEAN candidate reached the backlog" ;;
  *) bad "own tool: #42 was not queued — candidates='$(cat "$D/o/candidates.txt" 2>/dev/null)'" ;;
esac
if [ -s "$D/tool-log" ]; then
  logline="$(head -1 "$D/tool-log")"
  case "$logline" in
    *"dispatch-scout"*) ok "own tool: it ran with the SCOUT as the cwd (cwd=$logline)" ;;
    *) bad "own tool: wrong cwd — $logline" ;;
  esac
  case "$logline" in
    *"42 --repo ."*) ok "own tool: the candidate number and --repo . were passed" ;;
    *) bad "own tool: unexpected argv — $logline" ;;
  esac
else
  bad "own tool: the resolved tool never ran (no tool-log) — output: $OUT"
fi

# ── 2b) TORTOISE_REPO is the CANONICAL knob; the legacy TORTOISE alias still resolves ───────────
# `TORTOISE_REPO` is what the rest of the harness uses (check-port-drift.sh, install-launchd.sh,
# hub-state-check.sh), so an operator who already exported it must not be told to set a variable
# they believe is set (agent-infra#1748 review). When BOTH are set the canonical one wins; the alias
# is exercised on its own so an existing keys.env keeps working.
mk_case canonical-wins
mk_tool "$D/tort-repo/tools/collision_preflight.py"
mk_tool "$D/tort-legacy/tools/collision_preflight.py"
rf "$D" check TORTOISE_REPO="$D/tort-repo" TORTOISE="$D/tort-legacy"
case "$OUT" in
  *"pre-flight tool=$(cd "$D/tort-repo" && pwd -P)/tools/collision_preflight.py"*) ok "TORTOISE_REPO: the canonical knob wins over the legacy alias" ;;
  *) bad "TORTOISE_REPO: did not win over TORTOISE — output: $OUT" ;;
esac
mk_case legacy-alias
mk_tool "$D/tort/tools/collision_preflight.py"
rf "$D" check TORTOISE="$D/tort"
[ "$RC" -eq 0 ] && ok "TORTOISE: the legacy alias still resolves a checkout (rc=0)" \
               || bad "TORTOISE alias: rc=$RC — $OUT"

# ── 3) NOTHING resolvable must be a LOUD refusal with the reason — never an empty backlog ───────
# rc=3 is the PERMANENT code orch-loop.sh keys on; a transient failure would be 1. The reason must
# be the missing tool, NOT the old, misleading "uv sync failed".
mk_case no-tool
rf "$D" refresh TORTOISE_REPO=
[ "$RC" -eq 3 ] && ok "no tool anywhere: rc=3 (PERMANENT — not the transient code)" \
               || bad "no tool anywhere: rc=$RC (want 3) — output: $OUT"
case "$OUT" in
  *"NOT PROVISIONABLE"*) ok "no tool anywhere: the refusal is LOUD and named" ;;
  *) bad "no tool anywhere: no NOT PROVISIONABLE verdict — output: $OUT" ;;
esac
case "$OUT" in
  *"uv sync failed"*) bad "no tool anywhere: misreported as a uv failure" ;;
  *) ok "no tool anywhere: not misreported as a uv/environment failure" ;;
esac
if [ -s "$D/o/candidates.txt" ]; then
  bad "no tool anywhere: candidates were queued — $(cat "$D/o/candidates.txt")"
else
  ok "no tool anywhere: nothing is queued (never a silent empty backlog)"
fi

# ── 4) a REAL pyproject + a failing uv sync is TRANSIENT (rc=1), loud, and not swallowed ────────
# The other half of the distinction: an environment failure is NOT the not-applicable case.
mk_case uv-fails
mk_tool "$D/repo/.worktrees/dispatch-scout/tools/collision_preflight.py"
printf '[project]\nname = "demo"\n' > "$D/repo/.worktrees/dispatch-scout/pyproject.toml"
printf '#!/bin/bash\necho "error: cache is read-only" >&2\nexit 1\n' > "$D/bin/uv"; chmod +x "$D/bin/uv"
rf "$D" refresh SCOUT_UV="$D/bin/uv"
[ "$RC" -eq 1 ] && ok "uv failure: rc=1 (TRANSIENT — distinct from the permanent 3)" \
               || bad "uv failure: rc=$RC (want 1) — output: $OUT"
case "$OUT" in
  *"uv sync failed"*) ok "uv failure: named as a provisioning failure" ;;
  *) bad "uv failure: not reported — output: $OUT" ;;
esac
case "$OUT" in
  *"cache is read-only"*) ok "uv failure: uv's own output is surfaced (not swallowed)" ;;
  *) bad "uv failure: uv output was swallowed — output: $OUT" ;;
esac

# ── 5) the extras are read from the PROJECT, not inherited from tortoise ────────────────────────
# `uv sync --extra X` ERRORS on an extra the pyproject does not declare, so a non-tortoise Python
# repo must not receive tortoise's `embeddings`/`parity`. Both directions are asserted.
mk_case extras-declared
mk_tool "$D/repo/.worktrees/dispatch-scout/tools/collision_preflight.py"
cat > "$D/repo/.worktrees/dispatch-scout/pyproject.toml" <<'TOML'
[project]
name = "demo"
[project.optional-dependencies]
embeddings = ["sentence-transformers>=3"]
parity = ["pyarrow>=17"]
[tool.other]
embeddings = true
TOML
mk_uv_ok "$D"
rf "$D" refresh SCOUT_UV="$D/bin/uv"
case "$(cat "$D/uv-args" 2>/dev/null)" in
  *"--extra embeddings"*"--extra parity"*) ok "extras: declared extras ARE applied" ;;
  *) bad "extras: declared extras not applied — '$(cat "$D/uv-args" 2>/dev/null)'" ;;
esac
mk_case extras-absent
mk_tool "$D/repo/.worktrees/dispatch-scout/tools/collision_preflight.py"
printf '[project]\nname = "demo"\n' > "$D/repo/.worktrees/dispatch-scout/pyproject.toml"
mk_uv_ok "$D"
rf "$D" refresh SCOUT_UV="$D/bin/uv"
case "$(cat "$D/uv-args" 2>/dev/null)" in
  *"--extra"*) bad "extras: an undeclared extra was passed — '$(cat "$D/uv-args" 2>/dev/null)'" ;;
  *) ok "extras: no extras are invented for a project that declares none" ;;
esac

# ── 5b) SCOUT_UV PINS THE BINARY: a decoy `uv` earlier in PATH must NOT be the one executed ─────
# The shipped script used to hard-prepend the macOS dirs, so a caller's PATH could not pin `uv` and
# a real one shadowed the suite's stub (agent-infra#1748). SCOUT_UV is that pin, so the decoy — the
# FIRST `uv` on PATH — must be ignored. On the PRE-FIX code this fails: SCOUT_UV did not exist, the
# decoy (or the system `uv`) ran, and no `--extra` argv was ever recorded.
mk_case uv-override
mk_tool "$D/repo/.worktrees/dispatch-scout/tools/collision_preflight.py"
printf '[project]\nname = "demo"\n[project.optional-dependencies]\nembeddings = ["sentence-transformers>=3"]\n' > "$D/repo/.worktrees/dispatch-scout/pyproject.toml"
mkdir -p "$D/decoybin"
printf '#!/bin/bash\necho "DECOY $*" >> "%s/decoy-args"\nexit 7\n' "$D" > "$D/decoybin/uv"; chmod +x "$D/decoybin/uv"
mk_uv_ok "$D"
RF_PATH="$D/decoybin:$D/bin:$PATH" rf "$D" refresh SCOUT_UV="$D/bin/uv"
case "$(cat "$D/uv-args" 2>/dev/null)" in
  *"--extra embeddings"*) ok "SCOUT_UV: the pinned stub ran — PATH order did not override it" ;;
  *) bad "SCOUT_UV: the pinned stub did not run — uv-args='$(cat "$D/uv-args" 2>/dev/null)'" ;;
esac
[ ! -e "$D/decoy-args" ] && ok "SCOUT_UV: the earlier-PATH decoy uv was never executed" \
                        || bad "SCOUT_UV: the PATH decoy ran — $(cat "$D/decoy-args" 2>/dev/null)"
RF_PATH=""

# ── 6) `--check`: the READ-ONLY verdict the cell's `start` gate uses ────────────────────────────
# (a) provisionable → rc 0, names the tool and the not-applicable venv, and writes NOTHING.
mk_case check-ok
mk_tool "$D/tort/tools/collision_preflight.py"
rf "$D" check TORTOISE_REPO="$D/tort"
[ "$RC" -eq 0 ] && ok "--check: a provisionable repo passes (rc=0)" || bad "--check: rc=$RC — $OUT"
WANT_TOOL="$(cd "$D/tort" && pwd -P)/tools/collision_preflight.py"
case "$OUT" in
  *"pre-flight tool=$WANT_TOOL"*) ok "--check: names the resolved tool" ;;
  *) bad "--check: does not name the resolved tool (want $WANT_TOOL) — output: $OUT" ;;
esac
case "$OUT" in
  *"NOT APPLICABLE"*) ok "--check: reports the venv step as not-applicable, not failed" ;;
  *) bad "--check: does not report the venv applicability — output: $OUT" ;;
esac
[ ! -e "$D/uv-args" ] && [ ! -e "$D/repo/.worktrees/dispatch-scout/.venv" ] \
  && ok "--check: read-only (no uv run, no .venv created)" \
  || bad "--check: mutated the tree — uv-args='$(cat "$D/uv-args" 2>/dev/null)'"

# (b) not provisionable → rc 3, with the reason and the fix.
mk_case check-bad
rf "$D" check TORTOISE_REPO=
[ "$RC" -eq 3 ] && ok "--check: a non-provisionable repo is REFUSED (rc=3)" || bad "--check: rc=$RC — $OUT"
case "$OUT" in
  *"NOT PROVISIONABLE"*"set TORTOISE_REPO="*) ok "--check: the refusal carries the reason AND the fix" ;;
  *) bad "--check: refusal lacks reason/fix — output: $OUT" ;;
esac
# A repo whose pyproject is present but whose `uv` is missing must also refuse, and say so. `uv`
# is pinned through SCOUT_UV to a path that does not exist, so the case is deterministic on ANY
# host: stripping PATH alone could not work because the shipped script re-added /usr/local/bin,
# where a real `uv` lives on the cmux cell (`/usr/local/bin/uv`) — the case then read CHECK OK.
mk_case check-no-uv
mk_tool "$D/tort/tools/collision_preflight.py"
printf '[project]\nname = "demo"\n' > "$D/repo/.worktrees/dispatch-scout/pyproject.toml"
RF_PATH="$D/bin:/usr/bin:/bin:/usr/sbin:/sbin" rf "$D" check TORTOISE_REPO="$D/tort" SCOUT_UV="$D/bin/no-such-uv"
RF_PATH=""
[ "$RC" -ne 0 ] && ok "--check: a pyproject with no uv on PATH is refused" \
                || bad "--check: passed with no uv — output: $OUT"
case "$OUT" in
  *"'uv' is not runnable"*"SCOUT_UV="*) ok "--check: the refusal names uv and the resolution that failed" ;;
  *) bad "--check: the refusal does not name uv — output: $OUT" ;;
esac

# (c) a scout that does not exist yet: `--check` must judge the venv the REFRESH will use, not the
# main checkout's (agent-infra#1748 review P2). `--check` must not create the worktree, but reading
# `$REPO/.venv/bin/python` as evidence was a FALSE PASS: the refresh uses `$SC/.venv/bin/python`, so
# a repo with a main-checkout venv and a broken `uv` passed the probe, then failed `uv sync` and
# exited the TRANSIENT 1 — no marker, nothing in `status`, retried forever.
mk_case check-no-scout
mk_tool "$D/tort/tools/collision_preflight.py"
rm -rf "$D/repo/.worktrees/dispatch-scout"
mkdir -p "$D/repo/.venv/bin"
printf '#!/bin/bash\nexit 0\n' > "$D/repo/.venv/bin/python"; chmod +x "$D/repo/.venv/bin/python"
printf '[project]\nname = "demo"\n' > "$D/repo/pyproject.toml"
rf "$D" check TORTOISE_REPO="$D/tort" SCOUT_UV="$D/bin/no-such-uv"
[ "$RC" -ne 0 ] && ok "--check: no scout yet + a repo pyproject + no uv is REFUSED" \
                || bad "--check: FALSE PASS — the main checkout's .venv read as the scout venv"
case "$OUT" in
  *"CHECK OK"*) bad "--check: printed CHECK OK without ever probing uv" ;;
  *) ok "--check: no CHECK OK when the scout venv cannot be provisioned" ;;
esac
# The same shape with `uv` runnable must pass — a probe that only ever refuses is a false block.
printf '#!/bin/bash\nprintf "ok\\n"; exit 0\n' > "$D/bin/uv"; chmod +x "$D/bin/uv"
rf "$D" check TORTOISE_REPO="$D/tort" SCOUT_UV="$D/bin/uv"
[ "$RC" -eq 0 ] && ok "--check: a no-scout repo with uv runnable still passes (no false block)" \
               || bad "--check: false block — rc=$RC — $OUT"
case "$OUT" in
  *"to be provisioned"*) ok "--check: names the venv as to-be-provisioned (not the main checkout's)" ;;
  *) bad "--check: does not name the venv provisioning — output: $OUT" ;;
esac

# ── 7) orch-loop.sh: a permanent failure STOPS the retry loop and is loud (was silent, forever) ─
# The shipped refresh block is extracted VERBATIM (not re-implemented) and driven with stub scripts.
# The pre-fix block discarded the exit status (`( … ) &`), so both cases below were indistinguishable
# and the block re-spawned forever. `wait` is appended so the backgrounded subshell settles.
awk '/---- 3\) background backlog refresh/{f=1} f{print} f&&/^  fi$/{exit}' "$LOOP" > "$T/refreshblock.sh"
printf '\nwait\n' >> "$T/refreshblock.sh"
if [ -s "$T/refreshblock.sh" ] && grep -q 'refresh-candidates.sh' "$T/refreshblock.sh"; then
  ok "orch-loop: the refresh block is extracted from the shipped loop"
  BL="$T/block"
  mkdir -p "$BL"
  : > "$BL/candidates.txt"
  # (a) PERMANENT (rc=3): a marker is written, the log names it, and the next cycle does NOT retry.
  printf '#!/bin/bash\nprintf "x" >> "%s/invoked"\nexit 3\n' "$BL" > "$BL/refresh-candidates.sh"
  O="$BL" LOG="$BL/log" bash "$T/refreshblock.sh" >/dev/null 2>&1
  [ -s "$BL/.refresh-blocked" ] && ok "orch-loop: rc=3 writes the MERGE-ONLY marker" \
                                || bad "orch-loop: rc=3 wrote no marker"
  grep -q 'BLOCKED (permanent)' "$BL/log" 2>/dev/null \
    && ok "orch-loop: rc=3 is logged as a PERMANENT block" \
    || bad "orch-loop: rc=3 is not logged loudly — $(cat "$BL/log" 2>/dev/null)"
  invoked_before="$(wc -c < "$BL/invoked" | tr -d ' ')"
  O="$BL" LOG="$BL/log" bash "$T/refreshblock.sh" >/dev/null 2>&1
  invoked_after="$(wc -c < "$BL/invoked" | tr -d ' ')"
  [ "$invoked_before" = "$invoked_after" ] \
    && ok "orch-loop: a blocked refresh is NOT retried on the next cycle (the silent loop is killed)" \
    || bad "orch-loop: retried a permanently blocked refresh ($invoked_before -> $invoked_after)"
  grep -q 'blocked (not retrying)' "$BL/log" 2>/dev/null \
    && ok "orch-loop: the skip is visible (each cycle logs why)" \
    || bad "orch-loop: the skip is silent"
  # (b) TRANSIENT (rc=1): no marker, logged as transient, and the next cycle DOES retry.
  BL2="$T/block2"; mkdir -p "$BL2"; : > "$BL2/candidates.txt"
  printf '#!/bin/bash\nprintf "x" >> "%s/invoked"\nexit 1\n' "$BL2" > "$BL2/refresh-candidates.sh"
  O="$BL2" LOG="$BL2/log" bash "$T/refreshblock.sh" >/dev/null 2>&1
  [ ! -e "$BL2/.refresh-blocked" ] && ok "orch-loop: rc=1 (transient) writes no permanent marker" \
                                   || bad "orch-loop: rc=1 wrongly marked permanent"
  grep -q 'FAILED rc=1 (transient' "$BL2/log" 2>/dev/null \
    && ok "orch-loop: rc=1 is logged as transient" \
    || bad "orch-loop: rc=1 is not distinguished — $(cat "$BL2/log" 2>/dev/null)"
  before="$(wc -c < "$BL2/invoked" | tr -d ' ')"
  O="$BL2" LOG="$BL2/log" bash "$T/refreshblock.sh" >/dev/null 2>&1
  after="$(wc -c < "$BL2/invoked" | tr -d ' ')"
  [ "$before" != "$after" ] && ok "orch-loop: a transient failure IS retried next cycle" \
                            || bad "orch-loop: a transient failure was not retried"
else
  bad "orch-loop: could not extract the refresh block"
fi

echo
echo "── Summary ───────────────────────────────────────────────────────"
echo "  PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || { echo "  ❌ FAILURES — fix and re-run"; exit 1; }
echo "  ✅ all checks passed"
exit 0
