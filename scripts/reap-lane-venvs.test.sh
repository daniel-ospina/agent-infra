#!/usr/bin/env bash
# reap-lane-venvs.test.sh — self-check for scripts/reap-lane-venvs.sh and its wiring (#1932).
#
# Run: bash scripts/reap-lane-venvs.test.sh
# Exits 0 when ALL assertions pass, 1 on any failure.
#
# ⛔ WHAT THIS SUITE EXISTS TO PROVE, and why its shape is what it is: the defect (#1932) is not "we
# forgot to delete a directory" — it is that NOTHING could tell a live lane from a dead one, so the
# only two behaviours available were "leak 7.3 GB" and "delete the env of a lane that is mid-test".
# A test that only shows a removal is therefore NOT a test of this fix. Every removal case here is
# paired with a REFUSAL case built from the SAME fixture, and the two load-bearing sections use the
# REAL `ps`/`lsof`/`tmux` against REAL processes — a shim can only prove the matcher agrees with the
# shim.
#
# COVERAGE
#   A. exit mode (the runner's teardown): dead → reaped (and only `.venv`); live tmux pane / live cwd
#      / live argv → KEPT with the deciding evidence named; dry-run removes nothing; the main checkout
#      is never touched; a symlinked `.venv` is never followed.
#   B. GC mode: ONE pass reaps the dead and keeps the live (both directions in the same fixture set);
#      the age floor keeps a freshly synced env and `--min-age` is the only way past it; a GC run from
#      INSIDE a worktree keeps that worktree's env.
#   C. fail-closed: an unreadable/empty `ps`, an unavailable cwd probe, a tmux that is installed but
#      cannot list → exit 3 and NOTHING removed. "No tmux server" is a known zero and proceeds. The
#      degraded-cwd override is explicit and announces itself.
#   D. TOCTOU: a lane that goes live between classification and removal keeps its env (recheck_kept).
#   E. REAL tools: a real process cwd'd into a real linked worktree keeps that env; the same fixture
#      reaps once it is gone; the reaper is excluded from its own ancestry (so `--worktree` can reap
#      at all); and a REAL private tmux server proves the pane witness both ways.
#   F. wiring pins: lane.sh reaps in its EXIT trap, fix-one.sh reaps AFTER the merge chain, the cell
#      supervisor no longer blind-`rm`s a `.venv` and delegates to the reaper instead, setup.sh farms
#      the reaper so a cell can find it.
#   G. the `uv` download cache is never referenced — a venv hardlinks into it, and deleting it is the
#      measured regression (#1932) that turned "6.1 GB freed" into duplicated venvs.
#
# Hermetic apart from §E, which is REAL by design and uses only fixtures under $T (plus a private
# `tmux -L` server killed by the EXIT trap). Each section gets its OWN throwaway repo, so a fixture
# from one section can never satisfy (or spoil) an assertion in another.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAPER="$HERE/reap-lane-venvs.sh"
HARNESS="$HERE/orchestrator-harness"
SUP="$HERE/cloud-cell-supervisor.sh"
GATE="$HARNESS/spawn-gate.sh"
SETUP="$HERE/../pi-bootstrap/setup.sh"
# The declared-surface registry: a liveness/retention bound in a NEW script is invisible to the
# reverse scan until it is registered, and `verify`'s #1068 step goes red on the PR that adds it.
REGISTRY="$HERE/../extensions/shared/heartbeat-progress-edges.ts"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }
assert_eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got: $1, want: $2)"; fi }
assert_contains() { if grep -qF -- "$2" <<<"$1"; then ok "$3"; else bad "$3 (missing: $2)"; fi }
assert_not_contains() { if grep -qF -- "$2" <<<"$1"; then bad "$3 (unexpected: $2)"; else ok "$3"; fi }
exists() { if [ -e "$1" ] || [ -L "$1" ]; then ok "$2"; else bad "$2 (missing: $1)"; fi }
absent() { if [ -e "$1" ] || [ -L "$1" ]; then bad "$2 (still present: $1)"; else ok "$2"; fi }

T="$(mktemp -d "${TMPDIR:-/tmp}/reap-lane-venvs-test.XXXXXX")"
TMUX_SOCKS=""
cleanup() {
  local s
  for s in $TMUX_SOCKS; do tmux -L "$s" kill-server >/dev/null 2>&1 || true; done
  rm -rf "$T"
}
trap cleanup EXIT

[ -f "$REAPER" ] || { echo "FATAL: $REAPER missing"; exit 1; }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

# newrepo <name> — a throwaway git repo (one main checkout, no worktrees yet). Real git: the reaper
# asks git whether a checkout is the MAIN one (`--git-dir` vs `--git-common-dir`), and a stubbed git
# would only prove the stub.
newrepo() {
    local r="$T/$1"
    mkdir -p "$r"
    git -C "$r" init -q -b main >/dev/null 2>&1 || git -C "$r" init -q >/dev/null 2>&1
    echo hello > "$r/f.txt"
    git -C "$r" add f.txt
    git -C "$r" commit -qm init
    printf '%s\n' "$r"
}

mkvenv() { # mkvenv <worktree> — a `.venv` big enough for `du` to be non-zero
    mkdir -p "$1/.venv/bin" "$1/.venv/lib/python3.11/site-packages"
    printf '#!/bin/sh\necho 3.11.9\n' > "$1/.venv/bin/python"
    chmod +x "$1/.venv/bin/python"
    printf 'home = /usr/bin\n' > "$1/.venv/pyvenv.cfg"
    dd if=/dev/zero of="$1/.venv/lib/python3.11/site-packages/blob.so" bs=1024 count=64 >/dev/null 2>&1
}

age_venv_old() { # moves every path the reaper's BOUNDED age probe reads into 2020
    local v="$1/.venv" p
    for p in "$v" "$v/pyvenv.cfg" "$v/bin" "$v/lib"; do
        [ -e "$p" ] && { touch -t 202001010000 "$p" 2>/dev/null || true; }
    done
}

mkwt() { # mkwt <repo> <name> -> path of a linked worktree carrying an AGED .venv
    local repo="$1" name="$2" p
    p="$repo/.worktrees/$name"
    git -C "$repo" worktree add -q "$p" -b "b-$name" >/dev/null 2>&1
    mkvenv "$p"
    age_venv_old "$p"
    printf '%s\n' "$p"
}

canon() { ( cd "$1" 2>/dev/null && pwd -P ); }

# ── tool shims ─────────────────────────────────────────────────────────────────────────────────────
# Each models ONE contract, the argv the reaper actually passes:
#   ps   -axo pid=,ppid=,command=
#   lsof -a -d cwd -Fpn          (p<pid> / n<path> records)
#   tmux list-panes -a -F …      (<pid><TAB><path>)
mkdir -p "$T/bin"
cat > "$T/bin/ps" <<'SHIM'
#!/usr/bin/env bash
N=0
if [ -n "${FAKE_PS_COUNT:-}" ]; then
  [ -f "$FAKE_PS_COUNT" ] && N="$(cat "$FAKE_PS_COUNT")"
  N=$((N + 1)); printf '%s\n' "$N" >"$FAKE_PS_COUNT"
fi
[ -n "${FAKE_PS_FAIL:-}" ] && exit 1
[ -n "${FAKE_PS_EMPTY:-}" ] && exit 0
if [ -n "${FAKE_PS_SEQ_DIR:-}" ] && [ -f "$FAKE_PS_SEQ_DIR/$N" ]; then cat "$FAKE_PS_SEQ_DIR/$N"; exit 0; fi
if [ -n "${FAKE_PS_TABLE:-}" ] && [ -f "$FAKE_PS_TABLE" ]; then cat "$FAKE_PS_TABLE"; exit 0; fi
# The default is NON-EMPTY and matches nothing: an empty table is a probe FAILURE by design.
printf '4242 1 /usr/libexec/not-a-lane\n'
SHIM
cat > "$T/bin/lsof" <<'SHIM'
#!/usr/bin/env bash
[ -n "${FAKE_LSOF_FAIL:-}" ] && exit 1
if [ -n "${FAKE_LSOF_TABLE:-}" ] && [ -f "$FAKE_LSOF_TABLE" ]; then cat "$FAKE_LSOF_TABLE"; exit 0; fi
printf 'p4242\nn/\n'
SHIM
cat > "$T/bin/tmux" <<'SHIM'
#!/usr/bin/env bash
[ -n "${FAKE_TMUX_FAIL:-}" ] && { echo "error: could not connect to server" >&2; exit 1; }
if [ -n "${FAKE_TMUX_TABLE:-}" ] && [ -f "$FAKE_TMUX_TABLE" ]; then cat "$FAKE_TMUX_TABLE"; exit 0; fi
echo "no server running on /tmp/tmux-0/default" >&2; exit 1
SHIM
chmod +x "$T/bin/ps" "$T/bin/lsof" "$T/bin/tmux"

# `df` / `du` shims — the CAPACITY line's two measured inputs, made deterministic. A real filesystem's
# free-space reading is a property of the HOST, so a suite asserting a headroom number against it would
# be asserting the box, not the code; and a real `du` makes the per-lane figure differ per run. The
# reaper's own argv is honoured (df -Pk <path> → NR==2 $4; du -sk <path> → NR==1 $1).
cat > "$T/bin/df" <<'SHIM'
#!/usr/bin/env bash
[ -n "${FAKE_DF_FAIL:-}" ] && { echo "df: cannot read" >&2; exit 1; }
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\nfakefs 100000000 0 %s 0%% /\n' "${FAKE_DF_FREE_KB:-10485760}"
SHIM
cat > "$T/bin/du" <<'SHIM'
#!/usr/bin/env bash
for a in "$@"; do last="$a"; done
printf '%s\t%s\n' "${FAKE_DU_KB:-2097152}" "$last"
SHIM
chmod +x "$T/bin/df" "$T/bin/du"

# run_shimmed <args…> — the reaper with the three shims and a throwaway log; prints stdout+stderr.
# Extra `VAR=value` words before the flags become the environment of the ONE invocation (the shims).
run_shimmed() {
    local envs=()
    while [ $# -gt 0 ]; do
        case "$1" in *=*) envs+=("$1"); shift ;; *) break ;; esac
    done
    PS_BIN="$T/bin/ps" LSOF_BIN="$T/bin/lsof" TMUX_BIN="$T/bin/tmux" \
    REAP_VENV_LOG="$T/reap.log" env "${envs[@]}" bash "$REAPER" "$@" 2>&1
}
# run_real <args…> — REAL ps and lsof; tmux pointed at a path that does not exist, so the pass models
# a host with no tmux server (a KNOWN zero) and the live/dead distinction rests on the real probes.
run_real() {
    local lsof_bin; lsof_bin="$(command -v lsof || true)"
    PS_BIN=/bin/ps LSOF_BIN="$lsof_bin" TMUX_BIN=/nonexistent/tmux \
    REAP_VENV_LOG="$T/reap-real.log" bash "$REAPER" "$@" 2>&1
}

echo "── A. exit mode (the runner's teardown) ──────────────────────────────────────────────"
RA="$(newrepo a)"
W_DEAD="$(mkwt "$RA" dead)"
W_LIVE="$(mkwt "$RA" live)"
printf '9001\t%s\n' "$(canon "$W_LIVE")" > "$T/tmux-live.tsv"

echo " A1 a DEAD lane's venv is reaped — and nothing else in the worktree"
out="$(run_shimmed FAKE_TMUX_TABLE="$T/tmux-live.tsv" --worktree "$W_DEAD" --apply)"
assert_contains "$out" "REAP lane-exited" "the dead worktree is classified reap/lane-exited"
assert_contains "$out" "no-tmux-pane,no-proc-cwd,no-proc-argv" "the verdict names all three witnesses"
assert_contains "$out" "reaped=1" "the footer counts one reaped env"
absent "$W_DEAD/.venv" "the dead lane's .venv is gone"
exists "$W_DEAD/f.txt" "the worktree's TRACKED content is untouched (only .venv was removed)"
assert_contains "$out" "reclaimed_du=" "byte accounting is reported"
assert_contains "$out" "du over-counts hardlinked uv-cache blocks" "the du figure is labelled an over-count"

echo " A2 a LIVE lane (its tmux pane is inside the worktree) is KEPT"
out="$(run_shimmed FAKE_TMUX_TABLE="$T/tmux-live.tsv" --worktree "$W_LIVE" --apply)"
assert_contains "$out" "KEEP live-tmux-pane" "the pane witness decides the verdict"
assert_contains "$out" "pane_path=$(canon "$W_LIVE")" "the evidence names the pane's canonical path"
assert_contains "$out" "reaped=0" "nothing was reaped"
exists "$W_LIVE/.venv/bin/python" "the live lane's .venv is intact"

echo " A3 a lane proven only by a process CWD is KEPT"
printf 'p9101\nn%s/lib\n' "$(canon "$W_LIVE")" > "$T/lsof-cwd.txt"
out="$(run_shimmed FAKE_LSOF_TABLE="$T/lsof-cwd.txt" --worktree "$W_LIVE" --apply)"
assert_contains "$out" "KEEP live-cwd" "the cwd witness decides the verdict"
assert_contains "$out" "pid=9101" "the evidence names the pid"
assert_contains "$out" "reaped=0" "nothing was reaped"
exists "$W_LIVE/.venv" "the lane's .venv is intact"

echo " A4 a lane proven only by ARGV (its interpreter path) is KEPT"
printf '9201 1 /usr/bin/python3 %s/.venv/bin/python -m pytest\n' "$(canon "$W_LIVE")" > "$T/ps-argv.txt"
out="$(run_shimmed FAKE_PS_TABLE="$T/ps-argv.txt" --worktree "$W_LIVE" --apply)"
assert_contains "$out" "KEEP live-argv" "the argv witness decides the verdict"
assert_contains "$out" "pid=9201" "the evidence names the pid"
exists "$W_LIVE/.venv" "the lane's .venv is intact"

echo " A5 dry-run (the default) removes nothing, and says so"
W_DRY="$(mkwt "$RA" dry)"
out="$(run_shimmed --worktree "$W_DRY")"
assert_contains "$out" "REAP lane-exited" "the verdict is reported"
assert_contains "$out" "DRY-RUN — nothing was removed" "the dry run is announced"
exists "$W_DRY/.venv" "the .venv survives the dry run"

echo " A6 the MAIN checkout's .venv is KEPT (it is the controller's, not a lane's)"
mkvenv "$RA"
out="$(run_shimmed --worktree "$RA" --apply)"
assert_contains "$out" "KEEP main-checkout" "the main checkout is refused"
exists "$RA/.venv" "the main checkout's .venv is intact"

echo " A7 a SYMLINKED .venv is never followed"
W_SYM="$(mkwt "$RA" sym)"
rm -rf "$W_SYM/.venv"
mkdir -p "$T/uv-cache-stand-in"; echo keep > "$T/uv-cache-stand-in/entry"
ln -s "$T/uv-cache-stand-in" "$W_SYM/.venv"
out="$(run_shimmed --worktree "$W_SYM" --apply)"
assert_contains "$out" "KEEP symlinked-venv" "the symlink is refused"
exists "$T/uv-cache-stand-in/entry" "the symlink's TARGET (a cache stand-in) is untouched"
exists "$W_SYM/.venv" "the symlink itself is still there"

echo " A8 a worktree with NO .venv is a no-op, not a row"
W_NOV="$(mkwt "$RA" novenv)"; rm -rf "$W_NOV/.venv"
out="$(run_shimmed --worktree "$W_NOV" --apply)"
assert_contains "$out" "no .venv in" "the absence is reported"
assert_contains "$out" "venvs_found=0" "nothing is counted as found"

echo "── B. GC over a repo's worktrees ─────────────────────────────────────────────────────"
RB="$(newrepo b)"
W_G_DEAD="$(mkwt "$RB" dead)"
W_G_LIVE="$(mkwt "$RB" live)"
printf '9301\t%s\n' "$(canon "$W_G_LIVE")" > "$T/tmux-glive.tsv"

echo " B1 ONE pass reaps the dead and keeps the live — the both-directions proof"
out="$(run_shimmed FAKE_TMUX_TABLE="$T/tmux-glive.tsv" --gc --repo "$RB" --apply)"
assert_contains "$out" "REAP dead-lane" "the dead lane is classified reap"
assert_contains "$out" "KEEP live-tmux-pane" "the live lane is classified keep"
assert_contains "$out" "reaped=1" "exactly one env was reaped"
assert_contains "$out" "kept=1" "exactly one env was kept"
absent "$W_G_DEAD/.venv" "the dead lane's .venv is gone"
exists "$W_G_LIVE/.venv" "the live lane's .venv survives"

echo " B2 the age floor keeps a freshly synced env (the window before a lane binds)"
W_YOUNG="$(mkwt "$RB" young)"
touch "$W_YOUNG/.venv"                       # mtime = now; the default floor is 1800s
out="$(run_shimmed --gc --repo "$RB" --apply)"
assert_contains "$out" "KEEP too-recent" "a young env is kept by the floor"
assert_contains "$out" "floor 1800s" "the floor that decided is named"
exists "$W_YOUNG/.venv" "the young .venv is intact"

echo " B3 --min-age 0 is the only way past the floor, and lifting it reaps"
out="$(run_shimmed --gc --repo "$RB" --apply --min-age 0)"
assert_contains "$out" "REAP dead-lane" "the same env is reapable with the floor lifted"
absent "$W_YOUNG/.venv" "it is gone"

echo " B4 a GC run from INSIDE a worktree keeps THAT worktree's env (self-exclusion)"
W_SELF="$(mkwt "$RB" self)"
out="$( cd "$W_SELF" && run_shimmed --gc --repo "$RB" --apply )"
assert_contains "$out" "KEEP self-ancestor" "the reaper's own worktree is refused"
exists "$W_SELF/.venv" "its .venv survives the pass it launched"

echo "── C. fail-closed: unprovable means KEPT ────────────────────────────────────────────"
RC="$(newrepo c)"
W_FC="$(mkwt "$RC" fc)"

echo " C1 an unreadable ps removes NOTHING (exit 3)"
out="$(run_shimmed FAKE_PS_FAIL=1 --gc --repo "$RC" --apply)"; rc=$?
assert_eq "$rc" "3" "exit code is 3"
assert_contains "$out" "FAIL-CLOSED abort: ps probe unavailable" "the abort is named"
exists "$W_FC/.venv" "nothing was removed"

echo " C2 an EMPTY ps table is a probe failure, not 'no processes'"
out="$(run_shimmed FAKE_PS_EMPTY=1 --gc --repo "$RC" --apply)"; rc=$?
assert_eq "$rc" "3" "exit code is 3"
assert_contains "$out" "FAIL-CLOSED abort" "the abort is named"
exists "$W_FC/.venv" "nothing was removed"

echo " C3 an unavailable cwd probe removes NOTHING — a lane could be mid-test invisibly"
out="$(run_shimmed FAKE_LSOF_FAIL=1 REAP_VENV_PROC_ROOT="$T/no-proc" --gc --repo "$RC" --apply)"; rc=$?
assert_eq "$rc" "3" "exit code is 3"
assert_contains "$out" "cannot read any process cwd" "the abort is named"
exists "$W_FC/.venv" "nothing was removed"

echo " C4 the degraded-cwd override is EXPLICIT and announces itself"
out="$(run_shimmed FAKE_LSOF_FAIL=1 REAP_VENV_PROC_ROOT="$T/no-proc" REAP_VENV_ALLOW_DEGRADED_CWD=1 --gc --repo "$RC")"; rc=$?
assert_eq "$rc" "0" "the pass completes"
assert_contains "$out" "cwd witness DEGRADED" "the degradation is on the report"
assert_contains "$out" "REAP dead-lane" "it still classifies (tmux+argv evidence)"
exists "$W_FC/.venv" "a dry run removes nothing"

echo " C5 a tmux that is INSTALLED but cannot list panes removes NOTHING"
out="$(run_shimmed FAKE_TMUX_FAIL=1 --gc --repo "$RC" --apply)"; rc=$?
assert_eq "$rc" "3" "exit code is 3"
assert_contains "$out" "could be hiding a live lane" "the abort names the reason"
exists "$W_FC/.venv" "nothing was removed"

echo " C6 'no tmux server' is a KNOWN ZERO, not a failed probe"
out="$(run_shimmed --gc --repo "$RC")"; rc=$?
assert_eq "$rc" "0" "the pass completes"
assert_contains "$out" "no tmux server on this host" "the witness set is stated"
assert_contains "$out" "REAP dead-lane" "classification proceeds"

echo " C7 a repo git cannot enumerate removes NOTHING (exit 3, never 'no worktrees')"
out="$(run_shimmed --gc --repo "$T" --apply)"; rc=$?
assert_eq "$rc" "3" "exit code is 3"
assert_contains "$out" "not a git checkout" "the abort is named"

echo "── D. TOCTOU: a lane that goes live between classify and remove keeps its env ───────"
RD="$(newrepo d)"
W_TOU="$(mkwt "$RD" tou)"
mkdir -p "$T/ps-seq"
printf '4242 1 /usr/libexec/not-a-lane\n' > "$T/ps-seq/1"
printf '9401 1 /usr/bin/python3 %s/.venv/bin/python\n' "$(canon "$W_TOU")" > "$T/ps-seq/2"
out="$(run_shimmed FAKE_PS_SEQ_DIR="$T/ps-seq" FAKE_PS_COUNT="$T/ps-count" \
        FAKE_LSOF_FAIL=1 REAP_VENV_PROC_ROOT="$T/no-proc" REAP_VENV_ALLOW_DEGRADED_CWD=1 \
        --worktree "$W_TOU" --apply)"
assert_contains "$out" "REAP lane-exited" "classification said reap"
assert_contains "$out" "went live before removal" "the fresh re-probe caught the new holder"
assert_contains "$out" "recheck_kept=1" "the TOCTOU skip is counted, not swallowed"
exists "$W_TOU/.venv" "the env survived"

echo "── E. REAL ps / REAL lsof / REAL process (a shim cannot prove the matcher) ───────────"
LSOF_REAL="$(command -v lsof || true)"
if [ -z "$LSOF_REAL" ] && [ ! -d /proc ]; then
  echo "  ⏭ SKIP: neither lsof nor /proc — this host cannot take a cwd reading at all"
else
  RE="$(newrepo e)"
  W_R="$(mkwt "$RE" real)"

  echo " E1 a REAL process whose cwd is the worktree keeps its env"
  ( cd "$W_R" && exec sleep 60 ) &
  SLEEPER=$!
  sleep 1
  out="$(run_real --worktree "$W_R" --apply)"
  assert_contains "$out" "KEEP live-cwd" "the real cwd probe found the real process"
  exists "$W_R/.venv" "the env is intact"
  kill "$SLEEPER" 2>/dev/null
  wait "$SLEEPER" 2>/dev/null

  echo " E2 the SAME fixture reaps once that process is gone — the distinguishing half"
  sleep 1
  out="$(run_real --worktree "$W_R" --apply)"
  assert_contains "$out" "REAP lane-exited" "with no holder, the lane reads dead"
  assert_contains "$out" "reaped=1" "the env was reaped"
  absent "$W_R/.venv" "no .venv remains"
  exists "$W_R/f.txt" "the worktree itself is untouched"

  echo " E3 the reaper EXCLUDES its own ancestry — otherwise --worktree mode could never reap"
  W_R2="$(mkwt "$RE" self)"
  out="$( cd "$W_R2" && run_real --worktree "$W_R2" --apply )"
  assert_contains "$out" "REAP lane-exited" "the caller's own cwd (the worktree) is not read as a holder"
  absent "$W_R2/.venv" "the env is reaped from inside the lane"
fi

if command -v tmux >/dev/null 2>&1; then
  echo " E4 a REAL tmux pane inside the worktree keeps the env; ending the server reaps it"
  RE_T="$(newrepo et)"
  W_TM="$(mkwt "$RE_T" tmux)"
  SOCK="rlv-$$-$RANDOM"
  TMUX_SOCKS="$TMUX_SOCKS $SOCK"
  cat > "$T/bin/tmux-real" <<EOF
#!/usr/bin/env bash
exec "$(command -v tmux)" -L "$SOCK" -f /dev/null "\$@"
EOF
  chmod +x "$T/bin/tmux-real"
  "$T/bin/tmux-real" new-session -d -c "$W_TM" "sleep 300" >/dev/null 2>&1
  # ⛔ POLL, never a fixed sleep. A `new-session` returns before the server has published its pane
  # table, so a loaded host (the cell runs a controller beside this suite) makes the pane invisible
  # to the reaper's probe: it then falls through to `live-cwd` (the pane's `sleep` IS a real holder),
  # keeps the env for a DIFFERENT reason, and the assertion below fails on a healthy system.
  # Measured on cell-3 while rebasing this suite (2 of 90 red, green on every re-run). The poll is
  # bounded so a genuinely absent pane still fails the assertion rather than hanging the suite.
  wait_for_pane() { # wait_for_pane <present|absent> <socket>
    local want="$1" i
    for i in $(seq 1 100); do
      if [ "$want" = present ]; then
        "$T/bin/tmux-real" list-panes -a >/dev/null 2>&1 && return 0
      else
        "$T/bin/tmux-real" list-panes -a >/dev/null 2>&1 || return 0
      fi
      sleep 0.1
    done
    return 1
  }
  wait_for_pane present || bad "the private tmux server never published a pane"
  out="$(PS_BIN=/bin/ps LSOF_BIN="$LSOF_REAL" TMUX_BIN="$T/bin/tmux-real" REAP_VENV_LOG="$T/reap-real.log" bash "$REAPER" --worktree "$W_TM" --apply 2>&1)"
  assert_contains "$out" "KEEP live-tmux-pane" "the real pane is the deciding witness"
  exists "$W_TM/.venv" "the env survives while the lane's pane lives"
  "$T/bin/tmux-real" kill-server >/dev/null 2>&1
  wait_for_pane absent || bad "the private tmux server did not stop"
  out="$(PS_BIN=/bin/ps LSOF_BIN="$LSOF_REAL" TMUX_BIN="$T/bin/tmux-real" REAP_VENV_LOG="$T/reap-real.log" bash "$REAPER" --worktree "$W_TM" --apply 2>&1)"
  assert_contains "$out" "REAP lane-exited" "with the pane gone the lane reads dead"
  absent "$W_TM/.venv" "and the env is reclaimed"
else
  echo "  ⏭ SKIP E4: no tmux on this host"
fi

echo "── F. wiring pins ───────────────────────────────────────────────────────────────────"
if grep -qF 'trap '"'"'reap_lane_venv "$PWD" "lane $N"'"'"' EXIT' "$HARNESS/lane.sh"; then
  ok "lane.sh reaps its own worktree from an EXIT trap (a TERM'd session included)"
else
  bad "lane.sh has no EXIT-trap reap — an exiting lane leaves its venv behind"
fi
if grep -qF 'reap_lane_venv "$WT" "fix $PR"' "$HARNESS/fix-one.sh"; then
  ok "fix-one.sh reaps its worktree"
else
  bad "fix-one.sh does not reap its worktree"
fi
# ORDER matters: reaping before the re-review would make the reviewer re-sync a fresh env.
if [ -n "$(awk '/^bash "\$O\/merge-one.sh"/{m=NR} /reap_lane_venv "\$WT"/{r=NR} END{if (m && r && r > m) print "ok"}' "$HARNESS/fix-one.sh")" ]; then
  ok "fix-one.sh reaps AFTER the merge chain (the re-review costs nothing then)"
else
  bad "fix-one.sh reaps before the merge chain — the re-review would re-sync the env"
fi
if grep -qF 'reap_lane_venv_path' "$GATE" && grep -qF 'reap-lane-venvs.sh' "$GATE"; then
  ok "spawn-gate.sh resolves the reaper from \$O / the harness dir / \$AGENT_INFRA_PATH / the farm"
else
  bad "spawn-gate.sh cannot resolve the reaper"
fi
if grep -qF 'rm_cache "$root/.venv"' "$SUP"; then
  bad "cloud-cell-supervisor.sh still blind-rm's a worktree .venv (the #1932 defect)"
else
  ok "cloud-cell-supervisor.sh no longer blind-rm's a worktree .venv"
fi
if grep -qF 'reclaim_lane_venvs "$r"' "$SUP"; then
  ok "cloud-cell-supervisor.sh prune delegates venv reclaim to the reaper"
else
  bad "cloud-cell-supervisor.sh prune does not reclaim venvs through the reaper"
fi
if grep -qF 'reap-lane-venvs.sh' "$SETUP"; then
  ok "pi-bootstrap/setup.sh farms the reaper (a cell resolves it at ~/.pi/agent/scripts)"
else
  bad "the reaper is not farmed — a cell could not find it"
fi
# The age floor is a retention bound, so the #1068 declared-surface gate requires it in the
# registry — and the registry's own reverse scan is what caught its absence (#1932 CI).
if grep -qF 'name: "REAP_VENV_MIN_AGE_SECONDS"' "$REGISTRY"; then
  ok "the GC age floor is registered in the declared-surface registry (#1068), not just declared"
else
  bad "REAP_VENV_MIN_AGE_SECONDS is not in extensions/shared/heartbeat-progress-edges.ts"
fi
# Same rule for the free-disk FLOOR (review of PR #1949): it is a bound on how much of the box the
# fleet may consume, and a bound only the reaper knows about is exactly what the audit exists to see.
if grep -qF 'name: "REAP_VENV_FREE_FLOOR_MB"' "$REGISTRY"; then
  ok "the stated free-disk floor is registered in the declared-surface registry (#1068)"
else
  bad "REAP_VENV_FREE_FLOOR_MB is not in extensions/shared/heartbeat-progress-edges.ts"
fi
# The lane-exit helper must not mis-describe a FLOOR breach as "the env may still be present": the
# reaper reaped, and the box is short of space — different facts, and the wrong one buries the breach.
if grep -qF 'REAP_VENV_FREE_FLOOR_MB (rc=5' "$GATE"; then
  ok "spawn-gate.sh reports a floor breach (rc=5) as over-bound, not as a failed reap"
else
  bad "spawn-gate.sh would report rc=5 as '.venv may still be present' — a misleading message"
fi

echo "── G. the uv download cache is untouchable ──────────────────────────────────────────"
assert_not_contains "$(cat "$REAPER")" ".cache/uv" "the reaper names no uv cache path"
assert_not_contains "$(cat "$REAPER")" "uv cache clean" "the reaper never cleans the uv cache"
assert_eq "$(grep -cF '"$RM_BIN" -rf -- .venv' "$REAPER")" "1" "there is exactly ONE rm -rf, on the .venv basename"
assert_eq "$(grep -cF 'rm -rf -- ' "$REAPER")" "1" "and no second rm -rf exists anywhere in the reaper"

echo "── H. capacity: N measured, floor asserted, both printed (#1932 acceptance) ───────────"
# The review of PR #1949 added the acceptance clause: "after a lane exits, its .venv is gone
# automatically ... and a box can run N lanes without free disk falling below a stated floor — N
# measured, floor asserted, both printed by the reaper". Section A proves the first half; this section
# proves the second. Both inputs are PINNED (fake df/du) so the arithmetic is asserted rather than the
# host: free = 10 GiB, floor = 2048 MB, one lane env = 2048 MB ⇒ 4 more lanes fit.
RH="$(newrepo h)"
W_H_LIVE1="$(mkwt "$RH" live1)"
W_H_LIVE2="$(mkwt "$RH" live2)"
W_H_DEAD="$(mkwt "$RH" dead)"
printf '9501\t%s\n9502\t%s\n' "$(canon "$W_H_LIVE1")" "$(canon "$W_H_LIVE2")" > "$T/tmux-h.tsv"

# run_cap <env…> — the reaper with the pinned df/du AND the liveness shims, so nothing reads the host.
run_cap() {
    local envs=()
    while [ $# -gt 0 ]; do
        case "$1" in *=*) envs+=("$1"); shift ;; *) break ;; esac
    done
    PS_BIN="$T/bin/ps" LSOF_BIN="$T/bin/lsof" TMUX_BIN="$T/bin/tmux" \
    DF_BIN="$T/bin/df" DU_BIN="$T/bin/du" REAP_VENV_LOG="$T/reap-cap.log" \
    env "${envs[@]}" bash "$REAPER" "$@" 2>&1
}

echo " H1 lanes_live is MEASURED from the live witnesses (2 live, 1 dead)"
out="$(run_cap FAKE_TMUX_TABLE="$T/tmux-h.tsv" --gc --repo "$RH")"; rc=$?
assert_contains "$out" "capacity: lanes_live=2 " "the live-lane count is measured, not assumed"
assert_contains "$out" "lane_venv_max=2048MB" "the per-lane figure is the LARGEST env the pass saw"
assert_contains "$out" "free_after=10240MB" "the free-space reading is printed"
assert_contains "$out" "floor=2048MB floor_ok=yes" "the STATED floor and its verdict are printed"
assert_contains "$out" "lanes_headroom=4" "4 more lane envs fit above the floor ((10240-2048)/2048)"
assert_eq "$rc" "0" "a pass above the floor exits 0"

echo " H2 BELOW the floor the pass is loud (floor_ok=no) and exits 5 — a dry run still reports it"
out="$(run_cap FAKE_TMUX_TABLE="$T/tmux-h.tsv" FAKE_DF_FREE_KB=524288 --gc --repo "$RH")"; rc=$?
assert_contains "$out" "free_after=512MB floor=2048MB floor_ok=no" "512MB is below the stated floor"
assert_contains "$out" "lanes_headroom=0" "no lane headroom is reported when the floor is already breached"
assert_contains "$out" "BELOW the stated floor" "the breach is named, not buried in a green summary"
assert_eq "$rc" "5" "the exit code is 5 (over-bound at the disk-reaper entry point)"

echo " H3 the floor is STATED, so it can be restated — and the headroom follows it"
out="$(run_cap FAKE_TMUX_TABLE="$T/tmux-h.tsv" FAKE_DF_FREE_KB=524288 REAP_VENV_FREE_FLOOR_MB=0 --gc --repo "$RH")"; rc=$?
assert_contains "$out" "floor=0MB floor_ok=yes" "floor 0 says 'no floor stated', not 'unknown'"
assert_contains "$out" "lanes_headroom=0" "512MB still fits no 2GB lane env"
assert_eq "$rc" "0" "a satisfied floor exits 0"

echo " H4 a df that cannot answer is UNKNOWN, never 'enough' (and never a fabricated headroom)"
out="$(run_cap FAKE_TMUX_TABLE="$T/tmux-h.tsv" FAKE_DF_FAIL=1 --gc --repo "$RH")"; rc=$?
assert_contains "$out" "floor_ok=unknown" "an unreadable free-space probe is not claimed as satisfied"
assert_contains "$out" "free space is UNKNOWN" "the line says why it cannot assert"
assert_contains "$out" "lanes_headroom=?" "no headroom number is invented from a missing input"
assert_eq "$rc" "0" "an unmeasurable floor does not fail the pass (nothing was mis-deleted)"

echo " H5 a reaped pass still asserts the floor AND the removal is not undone by it"
out="$(run_cap FAKE_TMUX_TABLE="$T/tmux-h.tsv" --gc --repo "$RH" --apply)"; rc=$?
assert_contains "$out" "reaped=1" "the dead lane's env was reaped"
assert_contains "$out" "capacity: lanes_live=2 " "the capacity line is printed on an ARMED pass too"
assert_eq "$rc" "0" "and the pass still exits 0"
absent "$W_H_DEAD/.venv" "the dead env is gone"
exists "$W_H_LIVE1/.venv" "the live envs are untouched"
exists "$W_H_LIVE2/.venv" "the live envs are untouched"
echo
echo "──────────────────────────────────────────────────────────────────────────────────────"
if [ "$FAIL" -eq 0 ]; then
  echo "ALL PASS ($PASS assertions)"
  exit 0
fi
echo "FAILURES: $FAIL of $((PASS + FAIL)) assertions"
exit 1
