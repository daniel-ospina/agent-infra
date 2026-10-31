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
#   G. the `uv` download cache is never referenced — deleting it re-spends the space whether or not
#      this box shares blocks with it, and that is the measured regression (#1932) that turned
#      "6.1 GB freed" into duplicated venvs.
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
[ -n "${FAKE_PS_SLEEP:-}" ] && sleep "$FAKE_PS_SLEEP"
[ -n "${FAKE_PS_EMPTY:-}" ] && exit 0
# ⛔ ARG-AWARE, because the sandbox's OTHER consumer is `proc_start_epoch` (review round 1): it asks
# `ps -o etimes=` first and falls back to the BSD-style `ps -o etime=`. A shim that answered EVERY
# invocation with the process table made that fallback unreachable — the zero-padded-`etime` parse
# could not be driven at all, so its bug was invisible to this suite. These arms are matched before
# the table output for exactly that reason.
case " $* " in
  *" -o etimes="*) [ -n "${FAKE_ETIMES:-}" ] && { printf '%s\n' "$FAKE_ETIMES"; exit 0; }; exit 1 ;;
  *" -o etime="*)  [ -n "${FAKE_ETIME:-}" ]  && { printf '%s\n' "$FAKE_ETIME";  exit 0; }; exit 1 ;;
esac
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
# A per-path size TABLE is what makes "the LARGEST env, never the mean" DISCRIMINATING (review of
# PR #1949): with one size for every path, a largest-of / first-seen / last-seen / mean
# implementation all print the same number. Table lines are `<path-substring><TAB><KB>`; the first
# match wins, otherwise FAKE_DU_KB applies to every path.
if [ -n "${FAKE_DU_TABLE:-}" ] && [ -f "$FAKE_DU_TABLE" ]; then
    while IFS="$(printf '\t')" read -r pat kb; do
        [ -n "$pat" ] || continue
        case "$last" in *"$pat"*) printf '%s\t%s\n' "$kb" "$last"; exit 0 ;; esac
    done < "$FAKE_DU_TABLE"
fi
printf '%s\t%s\n' "${FAKE_DU_KB:-2097152}" "$last"
SHIM
chmod +x "$T/bin/df" "$T/bin/du"

# `PYTHON_BIN` shim — stands in for the hard-link-aware probe (#2159) so the capacity line is asserted
# rather than measured. It is invoked as `$PYTHON_BIN $VENV_REAL_BIN --tsv <path>`, so it ignores the
# script argument and answers from a table exactly like the `du` shim above: `<path-substring><TAB>
# <private_kb><TAB><fair_kb><TAB><total_kb><TAB><dedupe>`. A table is what makes "the LARGEST private
# count, never the last or the mean" DISCRIMINATING — with one value for every path, largest-of,
# first-seen, last-seen and mean all print the same number and the suite cannot tell them apart.
# `FAKE_VENV_COST_FAIL` models a box with no python: the probe must then read UNKNOWN, never 0.
cat > "$T/bin/venv-cost" <<'SHIM'
#!/usr/bin/env bash
echo "fake-python $*" >/dev/null
[ -n "${FAKE_VENV_COST_FAIL:-}" ] && { echo "fake-python: no such helper" >&2; exit 1; }
# A probe that HANGS is the only way to prove the call site is bounded at all (#2159 review, P2):
# success and immediate-failure both take the same `|| return 1` path with or without run_bounded.
[ -n "${FAKE_VENV_COST_SLEEP:-}" ] && sleep "$FAKE_VENV_COST_SLEEP"
for a in "$@"; do last="$a"; done
if [ -n "${FAKE_VENV_COST_TABLE:-}" ] && [ -f "$FAKE_VENV_COST_TABLE" ]; then
    while IFS="$(printf '\t')" read -r pat priv fair total dedupe; do
        [ -n "$pat" ] || continue
        case "$last" in *"$pat"*) printf '%s\t%s\t%s\t%s\n' "$priv" "$fair" "$total" "$dedupe"; exit 0 ;; esac
    done < "$FAKE_VENV_COST_TABLE"
fi
printf '%s\t%s\t%s\t%s\n' "${FAKE_VENV_PRIV:-102400}" "${FAKE_VENV_FAIR:-825364}" "${FAKE_VENV_TOTAL:-5940900}" "${FAKE_VENV_DEDUPE:-ok}"
SHIM
chmod +x "$T/bin/venv-cost"

# run_shimmed <args…> — the reaper with the three liveness shims, the capacity shims and a throwaway
# log; prints stdout+stderr. Extra `VAR=value` words before the flags become the environment of the ONE
# invocation (the shims).
# ⛔ `DF_BIN`/`DU_BIN` ARE PINNED HERE TOO (review of PR #1949): the reaper's new `report_capacity` reads
# free space on EVERY pass, so leaving them unpinned made every §A–§G exit-code assertion depend on the
# HOST's disk — on a cell below `REAP_VENV_FREE_FLOOR_MB` (the fleet's cells run at 0.6–0.8 GB free) a
# plain "the pass completes" assertion would read rc=5 instead of 0. That is the same host-measuring
# class #1987/#2006 closed, reintroduced through the new code path.
run_shimmed() {
    local envs=()
    while [ $# -gt 0 ]; do
        case "$1" in *=*) envs+=("$1"); shift ;; *) break ;; esac
    done
    # ⛔ `REAP_VENV_FREE_FLOOR_MB` IS PINNED HERE TOO (review of PR #1949): the floor is a documented
    # OPERATOR-RESTATABLE value, so an exported one turns every floor assertion in §H (and §A's "the
    # pass completes") red for a non-defect — the same host-measuring class as the `DF_BIN`/`DU_BIN`
    # pin directly above, reintroduced through the fourth capacity input. A caller that means to
    # exercise a floor passes it as a `VAR=value` word, which `env` applies AFTER this default, so
    # H2b's `abc` and H3's `0` still win.
    PS_BIN="$T/bin/ps" LSOF_BIN="$T/bin/lsof" TMUX_BIN="$T/bin/tmux" \
    DF_BIN="$T/bin/df" DU_BIN="$T/bin/du" REAP_VENV_FREE_FLOOR_MB=2048 \
    REAP_VENV_LOG="$T/reap.log" env "${envs[@]}" bash "$REAPER" "$@" 2>&1
}
# run_real <args…> — REAL ps and lsof; tmux pointed at a path that does not exist, so the pass models
# a host with no tmux server (a KNOWN zero) and the live/dead distinction rests on the real probes.
# `df`/`du` stay shimmed: §E is REAL about LIVENESS witnesses, and the capacity line's free-space reading
# is a property of the host that no liveness assertion is entitled to depend on (review of PR #1949).
run_real() {
    local lsof_bin; lsof_bin="$(command -v lsof || true)"
    PS_BIN=/bin/ps LSOF_BIN="$lsof_bin" TMUX_BIN=/nonexistent/tmux \
    DF_BIN="$T/bin/df" DU_BIN="$T/bin/du" REAP_VENV_FREE_FLOOR_MB=2048 \
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
assert_contains "$out" "over-counts only where that sharing exists" "the du figure is labelled a PER-MACHINE over-count, not a universal hardlink claim"

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

# ⛔ NON-VACUITY / P1 REGRESSION (review of PR #1949): the argv matcher tested only the FIRST occurrence
# of the worktree path on a `ps` line. A line that named a string-PREFIX SIBLING first (`<wt>-review`)
# made the boundary check read `-`, drop the whole line, and classify a LIVE lane as dead — after which
# `--apply` deleted its .venv. The venv must survive with only that line in the table, and the witness
# must still name the pid, so the assertion fails on the pre-fix matcher (`REAP lane-exited`, venv gone).
echo " A4b a string-PREFIX sibling named FIRST on the same ps line does not blind the argv witness"
printf '9202 1 /usr/bin/python3 %s-review/copy.py --venv %s/.venv/bin/python -m pytest\n' \
    "$(canon "$W_LIVE")" "$(canon "$W_LIVE")" > "$T/ps-argv-prefix.txt"
out="$(run_shimmed FAKE_PS_TABLE="$T/ps-argv-prefix.txt" --worktree "$W_LIVE" --apply)"
assert_contains "$out" "KEEP live-argv" "the argv witness is found when a prefix-extension sibling is named first"
assert_contains "$out" "pid=9202" "the evidence names the decoy line's pid"
assert_contains "$out" "reaped=0" "nothing was reaped"
exists "$W_LIVE/.venv" "a LIVE lane's .venv is NOT deleted because a prefix-sibling path appeared first"
# The SAME line with the boundary-violating sibling LAST proves the fix is about every occurrence, not
# about a particular order: the first occurrence (the real path) must still match.
printf '9203 1 /usr/bin/python3 %s/.venv/bin/python %s-review/copy.py\n' \
    "$(canon "$W_LIVE")" "$(canon "$W_LIVE")" > "$T/ps-argv-prefix2.txt"
out="$(run_shimmed FAKE_PS_TABLE="$T/ps-argv-prefix2.txt" --worktree "$W_LIVE" --apply)"
assert_contains "$out" "KEEP live-argv" "a trailing prefix-extension sibling leaves the verdict unchanged"
exists "$W_LIVE/.venv" "the lane's .venv is intact"
# ⛔ THE OTHER DIRECTION (review cycle 2 of PR #1949): A4b proves the matcher does not MISS a real path
# hidden behind a prefix sibling. It does NOT prove the matcher still REJECTS a sibling: deleting the
# boundary test entirely (`return index(line, needle) > 0`) left all 146 assertions green, so a future
# loosening of `c == "/" …` would ship — every `<wt>-review` mention becoming a live holder, which stops
# dead envs being reaped at all (the leak #1932 was opened for). A4c pins the rejection.
echo " A4c a prefix-SIBLING path ALONE is not a witness for a dead lane"
W_DECOY="$(mkwt "$RA" decoy)"
printf '9204 1 /usr/bin/python3 %s-review/copy.py\n' "$(canon "$W_DECOY")" > "$T/ps-argv-decoy.txt"
out="$(run_shimmed FAKE_PS_TABLE="$T/ps-argv-decoy.txt" --worktree "$W_DECOY" --apply)"
assert_contains "$out" "REAP lane-exited" "a sibling's path is not a witness for this lane"
assert_contains "$out" "no-tmux-pane,no-proc-cwd,no-proc-argv" "and the verdict still names all three witnesses"
absent "$W_DECOY/.venv" "the dead lane is still reaped"

# ⛔ THE REST OF THE BOUNDARY CLASS (review of PR #1949, P2): `hits()` accepts a match that ends the
# path on `""` (end of line), `"/"`, `" "` or `"\t"`. EVERY fixture above ends it on `/` suffixed by
# `.venv/bin/…`, so the other three members were DEAD WEIGHT — deleting one was a single-token edit
# that reddened nothing — and each is a fail-open in the direction the reaper exists to prevent: `ps`
# separates argv with spaces, so a line naming the worktree as an argument (`python3 --root=<wt> …`)
# or ending on it is one of the COMMONEST shapes on a real cell. With the member gone such a line is
# dropped, the lane reads `no-proc-argv`, and `--apply` deletes a LIVE lane's env.
# ⛔ THE FIXTURE GLUES THE PATH TO A FLAG (`--root=<wt>`) ON PURPOSE: a bare `<wt>` token would be
# rescued by the canonicalized-token arm further down the matcher, so the assertion would stay green on
# the mutant and pin nothing. Glued, only the exact-path arm can see the path — proven by mutation:
# deleting any one member reddens the three assertions for that fixture and the `.venv` is deleted.
# Each member gets its OWN worktree: a mutant deletes the env it mis-reads, so a shared fixture
# would cascade the failure into the NEXT member's assertions and a reader could not tell which
# member's pin failed.
echo " A4d the argv witness matches at EVERY boundary character, not only '/'"
W_BSP="$(mkwt "$RA" bspace)"
printf '9301 1 /usr/bin/python3 --root=%s --flag\n' "$(canon "$W_BSP")" > "$T/ps-argv-space.txt"
out="$(run_shimmed FAKE_PS_TABLE="$T/ps-argv-space.txt" --worktree "$W_BSP" --apply)"
assert_contains "$out" "KEEP live-argv" "a path ending on a SPACE (the next argv) is a witness"
assert_contains "$out" "pid=9301" "the evidence names the space-delimited line's pid"
exists "$W_BSP/.venv" "the SPACE boundary's lane is not reaped"
W_BTAB="$(mkwt "$RA" btab)"
printf '9302 1 /usr/bin/python3 --root=%s\t--flag\n' "$(canon "$W_BTAB")" > "$T/ps-argv-tab.txt"
out="$(run_shimmed FAKE_PS_TABLE="$T/ps-argv-tab.txt" --worktree "$W_BTAB" --apply)"
assert_contains "$out" "KEEP live-argv" "a path ending on a TAB is a witness"
assert_contains "$out" "pid=9302" "the evidence names the tab-delimited line's pid"
exists "$W_BTAB/.venv" "the TAB boundary's lane is not reaped"
W_BEOL="$(mkwt "$RA" beol)"
printf '9303 1 /usr/bin/python3 --root=%s\n' "$(canon "$W_BEOL")" > "$T/ps-argv-eol.txt"
out="$(run_shimmed FAKE_PS_TABLE="$T/ps-argv-eol.txt" --worktree "$W_BEOL" --apply)"
assert_contains "$out" "KEEP live-argv" "a path ending the LINE (end of argv) is a witness"
assert_contains "$out" "pid=9303" "the evidence names the end-of-line pid"
exists "$W_BEOL/.venv" "the END-OF-LINE boundary's lane is not reaped"

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
# P3 (review of PR #1949): the capacity prose promised a `capacity:` line on EVERY pass, but an exit-3
# abort returns before report_capacity. The doc now says a failed-closed pass prints none — pin that, so
# the corrected claim cannot quietly drift back into a promise the abort path breaks.
assert_not_contains "$out" "capacity:" "an exit-3 abort prints NO capacity line (an unmeasurable estate is never summarised)"
assert_not_contains "$out" "floor_ok=" "and therefore asserts no floor verdict it did not measure"

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
  # A scheduling grace for the child to enter its cwd. The load-induced flake this suite shows is
  # UNEXPLAINED (the reaper fails CLOSED on it, so nothing is removed); it is NOT a probing subshell
  # deleting the scratch — that was disproved by execution. 1s is ample for `cd && exec` on an idle box;
  # this is the fixture's only wall-clock dependence and it is a known fragility.
  sleep 1

  out="$(run_real --worktree "$W_R" --apply)"
  assert_contains "$out" "KEEP live-cwd" "the real cwd probe found the real process"
  exists "$W_R/.venv" "the env is intact"
  kill "$SLEEPER" 2>/dev/null
  wait "$SLEEPER" 2>/dev/null

  echo " E2 the SAME fixture reaps once that process is gone — the distinguishing half"
  # `wait` above already blocked until the child was reaped, so there is nothing left to poll here (an
  # earlier version polled `kill -0 "$SLEEPER"` after the `wait` and could never enter its body).
  out="$(run_real --worktree "$W_R" --apply)"
  assert_contains "$out" "REAP lane-exited" "with no holder, the lane reads dead"
  assert_contains "$out" "reaped=1" "the env was reaped"
  absent "$W_R/.venv" "no .venv remains"
  exists "$W_R/f.txt" "the worktree itself is untouched"

  # E1b a holder in a SUBDIRECTORY keeps the env, and a SIBLING PREFIX does not count as inside.
  # `inside()` decides both on a path BOUNDARY, and a regression to a bare prefix match would reap a
  # live lane whose process is one level down (or worse, count `/x/wt-extra` as `/x/wt`). Every other
  # case in this suite puts the holder at the worktree root, so neither shape would be caught.
  echo " E1b a holder one directory DOWN keeps the env, and a sibling prefix does not count as inside"
  RE_S="$(newrepo es)"
  W_S="$(mkwt "$RE_S" sub)"
  mkdir -p "$W_S/pkg"
  ( cd "$W_S/pkg" && exec sleep 60 ) &
  SUB=$!
  sleep 1
  out="$(run_real --worktree "$W_S" --apply)"
  assert_contains "$out" "KEEP live-cwd" "a process cwd'd into a SUBDIRECTORY is a live holder"
  exists "$W_S/.venv" "the env survives"
  kill "$SUB" 2>/dev/null
  wait "$SUB" 2>/dev/null
  # and with that process gone the same worktree is reapable, so the KEEP above was the holder
  sleep 1
  out="$(run_real --worktree "$W_S" --apply)"
  assert_contains "$out" "REAP lane-exited" "with the subdirectory holder gone, the lane reads dead"
  absent "$W_S/.venv" "and the env is reclaimed"

  # E1c SIBLING PREFIX: a process in `<worktree>-extra` must NOT be read as a holder of `<worktree>`.
  # A bare prefix match (`case "$cwd" in "$canon"*`) — the natural way to get `inside()` wrong — would
  # keep this env for ever; a boundary match reaps it. Both directions are asserted, so the case is
  # not vacuous: the same process in the REAL worktree keeps it (E1b above), and one directory over it
  # does not.
  echo " E1c a process one directory OVER (a sibling prefix) is not a holder of this worktree"
  RE_X="$(newrepo ex)"
  W_X="$(mkwt "$RE_X" wt)"
  SIBLING="$W_X-extra"
  mkdir -p "$SIBLING"
  ( cd "$SIBLING" && exec sleep 60 ) &
  SIB=$!
  sleep 1
  out="$(run_real --worktree "$W_X" --apply)"
  assert_contains "$out" "REAP lane-exited" "a holder in the SIBLING directory is not a holder of the worktree"
  absent "$W_X/.venv" "so the env is reclaimed despite a live process one directory over"
  kill "$SIB" 2>/dev/null
  wait "$SIB" 2>/dev/null
  rm -rf "$SIBLING"


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
# The cell supervisor is the OTHER caller the new exit code reaches (review of PR #1949): its one-line
# `||` message described every non-zero as "any env it could not prove dead was kept (it fails closed)",
# which is the OPPOSITE of an rc=5 pass that reaped correctly and merely ended below the floor. Pin that
# rc=5 is named as the floor breach it is, and that the fail-closed wording still covers the rest.
if grep -qF 'free disk is BELOW REAP_VENV_FREE_FLOOR_MB after the lane-venv pass' "$SUP"; then
  ok "cloud-cell-supervisor.sh names a floor breach (rc=5) as over-bound, not as a failed reap"
else
  bad "cloud-cell-supervisor.sh would tell the operator a successful reap 'was kept (it fails closed)' on rc=5"
fi
if grep -qF 'any env it could not prove dead was kept (it fails closed)' "$SUP"; then
  ok "cloud-cell-supervisor.sh keeps the fail-closed wording for the codes it still describes"
else
  bad "cloud-cell-supervisor.sh lost its fail-closed message for genuine aborts"
fi
# ⛔ rc=4 CARRIES TWO OUTCOMES, NOT ONE (review of PR #1949, P2). The reaper exits 4 both when a
# removal was ATTEMPTED and FAILED (REMOVE-FAILED: proven dead, still on disk) and when a removal-time
# re-probe failed CLOSED (`remove_one` returns 1 for `cwd_load`/`tmux_load`/`ps_load` unavailability and
# for a missing scratch dir) so the env was deliberately KEPT. A previous cycle fixed the first reading
# by asserting it and thereby made the message WRONG for the second; pin BOTH halves and forbid the
# one-sided parenthetical that was wrong either way.
if grep -qF 'either it was proven dead and the delete FAILED' "$SUP"; then
  ok "cloud-cell-supervisor.sh names the ATTEMPTED-and-FAILED removal meaning of rc=4"
else
  bad "cloud-cell-supervisor.sh lost the attempted-and-failed removal meaning of rc=4"
fi
if grep -qF 'or a removal-time re-probe failed closed and the env was KEPT' "$SUP"; then
  ok "cloud-cell-supervisor.sh names the failed-closed KEEP meaning of rc=4 too"
else
  bad "cloud-cell-supervisor.sh claims rc=4 always means 'proven dead', which the fail-closed removal path contradicts"
fi
assert_not_contains "$(cat "$SUP")" \
    'it did NOT keep it because it could not prove it dead' \
    "cloud-cell-supervisor.sh no longer asserts rc=4 never keeps an env"

# ── the --help surface (review cycle 2 of PR #1949) ──────────────────────────────────────────────────
# The usage heredoc is UNQUOTED (so $SCRIPT_NAME expands), which makes a backtick in it a COMMAND
# SUBSTITUTION: an unescaped `disk-reaper.sh` made --help print "note that  does not currently propagate
# that code" (word gone) and would have EXECUTED a `disk-reaper.sh` on PATH. It also carried the P3
# promise ("Every pass prints a capacity line") that the exit-3 abort contradicts. `--help` is the one
# surface an operator reads, and nothing pinned it — which is how both defects survived the prose fix.
echo "── F2. --help is honest, and executes nothing it names ────────────────────────────"
HELP_OUT="$(bash "$REAPER" --help 2>&1)"
assert_contains "$HELP_OUT" 'Every pass that COMPLETES prints a capacity line' \
    "--help states the capacity line as the COMPLETED-pass invariant"
assert_not_contains "$HELP_OUT" 'Every pass prints a capacity line' \
    "--help does not repeat the promise an exit-3 abort breaks"
assert_contains "$HELP_OUT" 'A FAIL-CLOSED abort (exit 3) prints NO capacity line' \
    "--help names the abort path's silence explicitly"
# ⛔ the pin holds the RENDERED sentence, so it also detects an unescaped backtick (the substitution
# would delete the word and the match would fail) — and it names the state measured at THIS tree: #2156
# landed on main (#2071), `worst_rc` keeps a delegate's 5 and the apply pass ranks it fail-closed. The
# old "does not currently propagate" sentence is now FALSE and is pinned as absent, so a stale copy of
# it cannot quietly come back.
assert_contains "$HELP_OUT" '`disk-reaper.sh` KEEPS that code and ranks it fail-closed in an apply pass' \
    "--help renders the backticked name LITERALLY (no command substitution ate it)"
assert_not_contains "$HELP_OUT" 'does not currently propagate' \
    "--help does not restate the pre-#2071 claim that disk-reaper.sh drops the 5"
# The hazard itself, not just its symptom: a `disk-reaper.sh` on PATH must never be run by --help.
mkdir -p "$T/help-path"
cat > "$T/help-path/disk-reaper.sh" <<'SH'
#!/usr/bin/env bash
: > "${HELP_EXEC_MARK:?}"
SH
chmod +x "$T/help-path/disk-reaper.sh"
HELP_EXEC_MARK="$T/help-executed" PATH="$T/help-path:$PATH" bash "$REAPER" --help >/dev/null 2>&1 || true
absent "$T/help-executed" "--help never EXECUTES a name it mentions"
# ⛔ the literal, not $SCRIPT_NAME: that variable is not set in THIS shell, and an empty needle makes
# assert_contains match everything — the pin would pass on any output at all (the #1994 class).
assert_contains "$HELP_OUT" "reap-lane-venvs.sh " "--help still expands the script name (the heredoc stays unquoted for a reason)"

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
    DF_BIN="$T/bin/df" DU_BIN="$T/bin/du" PYTHON_BIN="$T/bin/venv-cost" REAP_VENV_FREE_FLOOR_MB=2048 \
    REAP_VENV_LOG="$T/reap-cap.log" \
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
assert_eq "$rc" "5" "the exit code is 5 (the reaper's own over-bound code; disk-reaper KEEPS it and ranks it fail-closed in an apply pass — #2156)"

echo " H2b the over-bound AUDIT ROW carries the floor ACTUALLY asserted, not the raw env value"
# An invalid floor falls back to 2048MB for the comparison, so the incident line an operator greps must
# say 2048 — not the `abc` the environment held. Reporting the raw value is a WRONG NUMBER in the one line
# read during a disk incident (review of PR #1949).
out="$(run_cap FAKE_TMUX_TABLE="$T/tmux-h.tsv" FAKE_DF_FREE_KB=524288 REAP_VENV_FREE_FLOOR_MB=abc --gc --repo "$RH")"; rc=$?
assert_contains "$out" "floor=2048MB floor_ok=no" "an unparseable floor falls back to 2048MB for the comparison"
assert_eq "$rc" "5" "and the pass is still over-bound"
assert_contains "$(cat "$T/reap-cap.log")" "free_below_floor_mb=2048" "the audit row records the floor that was asserted"
assert_not_contains "$(cat "$T/reap-cap.log")" "free_below_floor_mb=abc" "the audit row never records a value that was not used"

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

# H1–H4 all run against ONE uniform `du` size, so they cannot tell a largest-of implementation from a
# first-seen or average one. This pass gives each lane its own size (KILOBYTES — that is what `du -sk`
# reports, and the shim mirrors the real tool): dead=1 GiB, live1=4 GiB, live2=2 GiB. Discovery is by
# path, so DEAD is seen FIRST and is the SMALLEST, while the LARGEST is second — first-seen (1024 MB),
# last-seen (2048 MB) and mean (~2389 MB) therefore all disagree with the LARGEST (4096 MB), and the
# headroom must follow the LARGEST: (10240-2048)/4096 = 2. This MUST run before the `--apply` pass below,
# which removes the dead lane's env and would leave the largest env adjacent to the first one seen.
echo " H5 lane_venv_max is the LARGEST env — not the first, the last, or the mean"
printf 'dead\t1048576\nlive1\t4194304\nlive2\t2097152\n' > "$T/du-h.tsv"
out="$(run_cap FAKE_TMUX_TABLE="$T/tmux-h.tsv" FAKE_DU_TABLE="$T/du-h.tsv" --gc --repo "$RH")"; rc=$?
# Exact full-line pin: a bare `lanes_headroom=2` would be satisfied by `lanes_headroom=2048` (a real
# wrong answer when the units are misread), so assert the whole capacity line instead.
assert_contains "$out" "capacity: lanes_live=2 lane_venv_max=4096MB lane_venv_real=100MB venv_dedupe=ok venv_degraded=0 free_after=10240MB floor=2048MB floor_ok=yes lanes_headroom=2" \
    "the LARGEST env drives the line: 4096MB, not first=1024/last=2048/mean~2389, headroom=(10240-2048)/4096=2"
assert_eq "$rc" "0" "the mixed-size pass exits 0"

echo " H5b ORDER-INDEPENDENCE: the LARGEST lane is found whatever order discovery uses"
# One table cannot prove a largest-of implementation: a first-seen reading coincides with the maximum
# whenever the expensive lane happens to be discovered first, and `git worktree list` order is not a
# contract. The SAME three sizes with the largest on the OTHER live lane is the pair: whichever order the
# reaper uses, one of the two runs has the large lane in a non-first, non-last position, so first-seen
# and last-seen cannot satisfy both.
printf 'dead\t1048576\nlive1\t2097152\nlive2\t4194304\n' > "$T/du-h2.tsv"
out="$(run_cap FAKE_TMUX_TABLE="$T/tmux-h.tsv" FAKE_DU_TABLE="$T/du-h2.tsv" --gc --repo "$RH")"; rc=$?
assert_contains "$out" "capacity: lanes_live=2 lane_venv_max=4096MB lane_venv_real=100MB venv_dedupe=ok venv_degraded=0 free_after=10240MB floor=2048MB floor_ok=yes lanes_headroom=2" \
    "the largest lane is found with the sizes swapped too (same exhaustive line)"
assert_eq "$rc" "0" "the swapped-size pass exits 0"

echo " H5c the REAL (hard-link-aware) cost is the LARGEST private count — not the last, not the mean (#2159)"
# The defect this section exists for: `du` prices a hardlinked env at its full tree size (5.66 GB) and
# a private copy at the SAME number, so the two classes are indistinguishable and the box looks ~20x
# fuller than it is. `lane_venv_real` is the private-block count — the bytes that VANISH on reaping.
# Discriminating table: private sizes 1024/4096/2048-ish KB in an order where largest-of, first-seen,
# last-seen and mean all differ. `git worktree list` order is not a contract, so the pair below (largest
# on the OTHER live lane) makes first-seen/last-seen fail at least one run.
printf 'dead\t1024\t2000\t5940900\tdegraded\nlive1\t4194304\t5000000\t5940900\tok\nlive2\t2048\t3000\t5940900\tok\n' > "$T/vc-h.tsv"
out="$(run_cap FAKE_TMUX_TABLE="$T/tmux-h.tsv" FAKE_VENV_COST_TABLE="$T/vc-h.tsv" --gc --repo "$RH")"; rc=$?
assert_contains "$out" "lane_venv_real=4096MB" "the LARGEST private count drives the line (4096, not last=2 or mean~1367)"
assert_contains "$out" "venv_degraded=1" "the one degraded class is COUNTED, not averaged away"
assert_contains "$out" "venv_dedupe=degraded" "one degraded env makes the pass's dedupe verdict degraded (fail-loud, not 'mostly ok')"
# ⛔ THE `du` DIVISOR MUST NOT MOVE. The real cost is REPORTED beside it and never replaces it: `du` is
# the cold-cache upper bound, and a headroom computed from the warm-cache number would dispatch lanes a
# box cannot hold the first time the cache is missing (a fail-OPEN on the one line that gates dispatch).
assert_contains "$out" "lane_venv_max=2048MB" "the du divisor is unchanged — the real cost is reported, never substituted"
assert_contains "$out" "lanes_headroom=4" "headroom still divides the UPPER BOUND (10240-2048)/2048, so it cannot over-admit"
assert_eq "$rc" "0" "a degraded-dedupe pass still completes"

printf 'dead\t1024\t2000\t5940900\tok\nlive1\t2048\t3000\t5940900\tok\nlive2\t4194304\t5000000\t5940900\tok\n' > "$T/vc-h2.tsv"
out="$(run_cap FAKE_TMUX_TABLE="$T/tmux-h.tsv" FAKE_VENV_COST_TABLE="$T/vc-h2.tsv" --gc --repo "$RH")"; rc=$?
assert_contains "$out" "lane_venv_real=4096MB" "the largest private count is found with the sizes swapped too (order-independent)"
assert_contains "$out" "venv_degraded=0" "no degraded env in this table"

echo " H5c2 a MEASURED zero prints 0MB, not ? — a perfectly-shared env is not a broken probe"
# The ideal box: every byte shared, so private_kb == 0 and dedupe=ok. Printing `?` here would tell a
# reader the probe failed on the box that is working exactly as intended (#2159 review, P2).
out="$(run_cap FAKE_TMUX_TABLE="$T/tmux-h.tsv" FAKE_VENV_PRIV=0 FAKE_VENV_FAIR=0 --gc --repo "$RH")"; rc=$?
assert_contains "$out" "lane_venv_real=0MB" "a measured private cost of 0 is reported as 0MB"
assert_contains "$out" "venv_dedupe=ok" "and the dedupe verdict still says the sharing is in force"
assert_not_contains "$out" "lane_venv_real=?" "a shared env is never reported as an unmeasurable one"
assert_eq "$rc" "0" "the ideal-box pass exits 0"

echo " H5c3 the cost probe is BOUNDED — a hanging probe cannot hang the pass"
# Only a hanging probe can discriminate a bare call from a `run_bounded` one: success and an immediate
# failure are identical on both paths, so replacing the call with an unbounded one stayed green before
# this case existed (#2159 review, P2).
t0=$SECONDS
out="$(run_cap FAKE_TMUX_TABLE="$T/tmux-h.tsv" FAKE_VENV_COST_SLEEP=30 REAP_VENV_VENV_COST_TIMEOUT=1 --gc --repo "$RH")"; rc=$?
elapsed=$((SECONDS - t0))
[ "$elapsed" -lt 20 ] && ok "a 30s probe bounded at 1s let the pass finish in ${elapsed}s" \
    || bad "the probe ran unbounded — the pass took ${elapsed}s (expected < 20s)"
assert_contains "$out" "lane_venv_real=?" "a timed-out probe is UNKNOWN, never a partial number"
assert_eq "$rc" "0" "a timed-out probe does not fail the pass"
# An INVALID bound arms no watchdog at all in run_bounded, so it must be refused loudly, not silently.
out="$(run_cap FAKE_TMUX_TABLE="$T/tmux-h.tsv" FAKE_VENV_COST_SLEEP=2 REAP_VENV_VENV_COST_TIMEOUT=abc --gc --repo "$RH")"; rc=$?
assert_contains "$out" "is not a positive integer" "an invalid timeout is named, not silently unbounded"
# ⛔ AN ALL-DIGIT VALUE ABOVE intmax IS THE FAIL-OPEN CASE (review round 3): `is_pos_int` accepts it and
# `[ <huge> -eq 0 ]` ERRORS rather than returning false, so a "digits and not zero" check let it through
# and armed no watchdog at all. A string-compare + length cap is what makes this reachable-and-refused.
out="$(run_cap FAKE_TMUX_TABLE="$T/tmux-h.tsv" FAKE_VENV_COST_SLEEP=2 REAP_VENV_VENV_COST_TIMEOUT=99999999999999999999999 --gc --repo "$RH")" 2>&1; rc=$?
assert_contains "$out" "is not a positive integer" "an over-range all-digit timeout is refused too, not accepted as a bound"
assert_not_contains "$out" "integer expression expected" "the validation does not itself emit an arithmetic error"

echo " H5d an unmeasurable probe reads UNKNOWN, never 0 (#2159)"
# A `0` here would read as "a lane env is free", which is the exact over-admission this line exists to
# prevent. A box with no python3 is a real host state (a fresh cell before setup), so it is modelled.
out="$(run_cap FAKE_TMUX_TABLE="$T/tmux-h.tsv" FAKE_VENV_COST_FAIL=1 --gc --repo "$RH")"; rc=$?
assert_contains "$out" "lane_venv_real=?" "an unmeasurable real cost is printed as ?, not as 0"
assert_contains "$out" "venv_dedupe=unknown" "and the dedupe verdict is unknown, never 'ok'"
assert_eq "$rc" "0" "an unmeasurable probe does not fail the pass (nothing was mis-deleted)"

 echo " H6 a reaped pass still asserts the floor AND the removal is not undone by it"
out="$(run_cap FAKE_TMUX_TABLE="$T/tmux-h.tsv" --gc --repo "$RH" --apply)"; rc=$?
assert_contains "$out" "reaped=1" "the dead lane's env was reaped"
assert_contains "$out" "capacity: lanes_live=2 " "the capacity line is printed on an ARMED pass too"
assert_eq "$rc" "0" "and the pass still exits 0"
absent "$W_H_DEAD/.venv" "the dead env is gone"
exists "$W_H_LIVE1/.venv" "the live envs are untouched"
exists "$W_H_LIVE2/.venv" "the live envs are untouched"

echo " H7 a FLOOR BREACH is still AUDITED when a removal also failed (exit 4 must not hide it)"
# The severity order (3 abort > 4 removal failed > 5 over-bound) means exit 4 PREEMPTS exit 5. The
# `over-bound` audit row used to live INSIDE the `exit 5` arm (review of PR #1949), so a pass that both
# failed a removal AND ended below the floor wrote NO audit row at all: the one degraded shape had no
# breach record, which is a silent breach. The EXIT CODE order is unchanged — only the record survives.
# Separate fixture repo so the failing rm cannot disturb §H's sizes/assertions.
RH7="$(newrepo h7)"
W_H7_DEAD="$(mkwt "$RH7" dead7)"
: > "$T/tmux-h7.tsv"          # exists and is empty = a KNOWN zero panes, not a probe failure
printf '#!/bin/sh\nexit 1\n' > "$T/bin/rm-fail"; chmod +x "$T/bin/rm-fail"
out="$(run_cap FAKE_TMUX_TABLE="$T/tmux-h7.tsv" FAKE_DF_FREE_KB=524288 RM_BIN="$T/bin/rm-fail" REAP_VENV_DRY_RUN=0 REAP_VENV_LOG="$T/reap-h7.log" --gc --repo "$RH7" --apply)"; rc=$?
assert_eq "$rc" "4" "a FAILED removal still exits 4 — it outranks the breach, and that order is unchanged"
assert_contains "$out" "floor_ok=no" "the breach is still asserted and printed on the degraded pass"
# ⛔ A DEDICATED LOG, because `log()` APPENDS: reading the shared `reap-cap.log` here would find H2's
# `over-bound` row and the pin would pass with the fix reverted — the exact vacuous-pin mode this suite
# refuses (review of PR #1949).
assert_eq "$(grep -c "^over-bound" "$T/reap-h7.log")" "1" "exactly ONE over-bound row — the pin cannot be satisfied by another pass's appended row"
assert_contains "$out" "REMOVE-FAILED" "the removal failure is named, so the two facts are both on the record"

echo "── I. the probe watchdog must not delete the parent's scratch dir ──────────────"
# MEASURED DEFECT (pre-existing, found while re-running this suite on a loaded cell): `cleanup` is an
# EXIT trap and `run_bounded`'s watchdog subshell INHERITS it, so when the parent TERMs the watchdog
# after a probe (which it does after EVERY probe), the CHILD ran `rm -rf "$SCRATCH"` — deleting the
# parent's scratch dir mid-pass. The parent then read an empty/gone file and aborted fail-closed
# (`ps probe unavailable`, `reports no worktrees at all`, exit 3) on a healthy box, ~2 runs in 3 at
# load ~8. A reaper that randomly refuses to reap is the failure mode a fleet can only read as
# "nothing to reap".
# Structural pins (deterministic): cleanup() is owner-guarded, and the child clears the inherited trap.
# ⛔ The guard must be BASH-3.2-SAFE (review of PR #1949). `BASHPID` is bash >= 4.0; macOS `/bin/bash` is
# 3.2.57 and this reaper is invoked PATH-resolved (`bash "$reaper"`), so an UNGUARDED `$BASHPID` is an
# unbound variable under `set -u` — and an unbound expansion inside an EXIT trap aborts the rest of the
# trap (measured), so the kill loop and the scratch removal would silently never run. Pin BOTH halves:
# the `:-`-guarded form present, and the unguarded form absent.
if grep -qF '[ -n "${BASHPID:-}" ] && [ "$BASHPID" != "$$" ]' "$REAPER"; then
  ok "cleanup() only acts in the shell that owns the scratch dir (BASHPID guard, 3.2-safe)"
else
  bad "cleanup() has no owner guard — a subshell can delete the parent's scratch dir"
fi
if grep -qF '[ "$BASHPID" = "$$" ] || return 0' "$REAPER"; then
  bad "cleanup() expands \$BASHPID UNGUARDED — on bash 3.2 that aborts the trap (scratch dir + watchdogs leak)"
else
  ok "cleanup() never expands BASHPID unguarded (a bash-3.2 box still cleans up)"
fi
# ⛔ COMMENT LINES ARE EXCLUDED FROM THE SCAN (review of PR #1949, P1): the plain `/trap - EXIT/` match
# found the COMMENT that names the statement (`# … \`trap - EXIT\` in the watchdog is the other half.`)
# long before the real one, so the pin passed with the actual `trap - EXIT` line DELETED — a false PASS on
# the one pin that still protects a bash-3.2 box, where the BASHPID guard cannot fire (BASHPID is unset,
# so the guarded test is false and cleanup() proceeds in a child). Measured: deleting the real line left
# this pin green. The comment filter is what makes it discriminating.
# ⛔ FIRST-OCCURRENCE, NOT LAST (review of PR #1949): `c=NR` overwrote on EVERY match, so `c` held the
# LAST `trap - EXIT` in the file. That worked only while the file had exactly one — and the removal
# subshell fix added a SECOND one (in `remove_one`, which sorts AFTER the watchdog's kill-trap), so the
# comparison `c < t` went permanently false and this pin read RED on a correct reaper (measured: c=720,
# t=348). A pin whose verdict depends on the file having one instance of a line the codebase is
# encouraged to add more of is measuring file layout, not the watchdog. `&& !c` / `&& !t` scope it to
# the FIRST of each, which is the watchdog block this pin names. The count pin below then keeps that
# scope explicit, so a third site cannot silently re-point it again.
if [ -n "$(awk '!/^[[:space:]]*#/ && /trap - EXIT/ && !c {c=NR} !/^[[:space:]]*#/ && /trap .kill "\$s"/ && !t {t=NR} END{if (c && t && c < t) print "ok"}' "$REAPER")" ]; then
  ok "the watchdog subshell clears the inherited EXIT trap before it arms its own (non-comment line)"
else
  bad "the watchdog subshell inherits cleanup() — it deletes the parent's scratch dir on every probe"
fi
# Two non-comment `trap - EXIT` sites and no more: the watchdog and the removal subshell. Pinned as a
# COUNT so the first-occurrence scoping above cannot be re-pointed by a future third site.
assert_eq "$(awk '!/^[[:space:]]*#/ && /trap - EXIT/{n++} END{print n+0}' "$REAPER")" "2" \
  "exactly TWO non-comment 'trap - EXIT' sites (watchdog + removal subshell) — no more, no fewer"
# ⛔ THE SAME RULE FOR THE REMOVAL SUBSHELL (review of PR #1949): `remove_one` runs its ONE `rm -rf` in a
# `( … )` subshell. On bash 3.2 — exactly the bash where cleanup()'s BASHPID guard is INERT, because
# BASHPID does not exist there — that subshell inherits `cleanup` and deletes the SHARED `$SCRATCH`
# MID-PASS: `$out` vanishes, so every removal AFTER the first reads `REMOVE-FAILED … rc=1` and the pass
# exits 4, reporting a reap that failed on a healthy box. The watchdog's `trap - EXIT` does NOT cover
# this one, so pin the subshell LINE ITSELF rather than any occurrence in the file.
if grep -qE '^[[:space:]]*if \( ?trap - EXIT; ?cd ' "$REAPER"; then
  ok "the removal subshell clears the inherited EXIT trap too (covers bash 3.2, where the guard is inert)"
else
  bad "the removal subshell inherits cleanup() — on bash 3.2 it deletes the parent's scratch dir mid-pass"
fi
# Behavioural smoke check (NOT the discriminator): a SLOW probe arms the watchdog on every pass, which
# is the shape the race was seen in. ⚠️ Honest scope (review of PR #1949): on bash >= 5 a `( … ) &`
# subshell does not run an INHERITED EXIT trap (measured: the child's TERM trap runs, the parent's
# cleanup does not), so this loop does NOT fail against the pre-fix script and cannot be cited as proof
# the flake is gone — the two structural pins above are the proof. The loop is kept as a smoke test that
# an armed watchdog still classifies, and the mechanism's bash-version dependence is recorded here so the
# next reader does not mistake it for evidence. Pre-fix these aborted with exit 3 at random ON THE BASH
# THE FLAKE WAS MEASURED ON (~2 runs in 3 at load ~8).
RI="$(newrepo i)"
W_I_DEAD="$(mkwt "$RI" dead)"
clean_passes=0
for _ in 1 2 3; do
  out="$(run_shimmed FAKE_PS_SLEEP=0.4 REAP_VENV_PS_TIMEOUT=5 --gc --repo "$RI")"; rc=$?
  [ "$rc" = 0 ] && grep -qF "REAP dead-lane" <<<"$out" && clean_passes=$((clean_passes + 1))
done
assert_eq "$clean_passes" "3" "3/3 passes with an armed watchdog classify the dead lane (smoke: no spurious fail-closed)"
echo "── J. the age floor is VALIDATED, never compared into a fall-through (#2158) ────────"
# `--min-age` was validated at parse time; the ENV form was not. With a non-numeric value the
# `[ "$age" -lt "$REAP_VENV_MIN_AGE_SECONDS" ]` test ERRORS and takes the else branch — under
# `set -uo pipefail` (no `-e`) the pass falls straight through to reaping, so ANY typo silently
# disables the floor that covers the window between `git worktree add` and the first process binding
# to the new lane. It failed OPEN, in the direction that deletes a live lane's env.
# ⛔ A FIXTURE NAME OF ITS OWN. §H (main's capacity section) already owns `$T/h`, and `newrepo` RE-INITS
# its directory: the second `git commit -qm init` has nothing to stage, so git's STATUS TEXT lands in the
# command substitution and every later `$W_H` becomes a multi-line path. Measured after the rebase: the
# `exists` assertions passed VACUOUSLY (mkvenv created the dir at the polluted path) and only the final
# `absent` failed — a section that looks half-green for the wrong reason. Hence `j`.
RJ="$(newrepo j)"
W_J="$(mkwt "$RJ" j)"
touch "$W_J/.venv"                        # mtime = now: a freshly synced env, the window the floor covers
out="$(run_shimmed REAP_VENV_MIN_AGE_SECONDS=30m --gc --repo "$RJ" --apply)"; rc=$?
assert_eq "$rc" "2" "a non-numeric REAP_VENV_MIN_AGE_SECONDS is REFUSED (exit 2), never a fall-through"
assert_contains "$out" "REAP_VENV_MIN_AGE_SECONDS" "the refusal names the variable, not a generic error"
assert_contains "$out" "Nothing removed" "and it says the pass removed nothing"
exists "$W_J/.venv" "the refused pass deleted NOTHING (the #2158 fail-open symptom is absent)"
# ⛔ AND BOUNDED, not merely all-digits (#2173 review). `is_pos_int` accepts any digit string, but
# `[ -lt ]` parses with strtoimax: a value above intmax_t makes the COMPARISON ITSELF error and the
# `if` takes the else branch, so a digit-only out-of-range floor silently DISABLES the floor — the same
# fail-open one size class up. The bound lives in parse_args, the one validator, and refuses with 2
# (operator-fixable), never a delegate's 3.
out="$(run_shimmed REAP_VENV_MIN_AGE_SECONDS=99999999999999999999 --gc --repo "$RJ" --apply)"; rc=$?
assert_eq "$rc" "2" "an OUT-OF-RANGE (digit-only) floor is REFUSED (exit 2), never compared into a fall-through"
assert_contains "$out" "out of range" "and the refusal says out of range, not 'not a number'"
assert_contains "$out" "Nothing removed" "and it says the refused pass removed nothing"
exists "$W_J/.venv" "the out-of-range refusal deleted NOTHING"
# ⛔ ONE VALIDATOR FOR ONE SEAM (#2173 merge artifact). This file carried a SECOND validator of the
# same predicate on the same variable (`validate_config`) that exited 3 — unreachable, because
# parse_args is the only path into main and its tail already refuses, and it stated the OPPOSITE
# contract to the reachable one. Pin the count so a dead second rule that reads like policy cannot
# come back: 2 here means "two contracts for one seam", which is the state that must not ship.
assert_eq "$(grep -c 'is_pos_int "${REAP_VENV_MIN_AGE_SECONDS:-}"' "$REAPER")" "1" \
  "the age floor has exactly ONE validator (a second, unreachable one stated exit 3 — deleted)"
# Positive controls, both directions: with a VALID floor the same young env is kept BY THE FLOOR, and
# with the floor lifted the same env reaps — so the KEEP is the floor's doing, not an inability to delete.
out="$(run_shimmed REAP_VENV_MIN_AGE_SECONDS=1800 --gc --repo "$RJ" --apply)"; rc=$?
assert_eq "$rc" "0" "a valid floor from the environment is accepted"
assert_contains "$out" "KEEP too-recent" "and the young env is kept BY the floor"
exists "$W_J/.venv" "the env survives"
out="$(run_shimmed REAP_VENV_MIN_AGE_SECONDS=0 --gc --repo "$RJ" --apply)"; rc=$?
assert_contains "$out" "REAP dead-lane" "with the floor lifted the same env is reapable"
absent "$W_J/.venv" "so the KEEP above was the floor, not an inability to remove"

echo
echo "── K. the idle-shell rule: a shell at a prompt is not a live lane (#2721) ───────────"
# WHY THIS SECTION EXISTS. The cwd/tmux-pane witnesses answer "is a process sitting here?" — and a
# shell that `cd`'d in and never exited answers YES for ever, which is how #2721's wedged cell kept 59
# checkouts (5-6 GB `du` each) while losing its disk. The rule under test is NARROW:
#   live unless it is a SHELL whose start time is BEFORE the worktree's HEAD commit AND which has no
#   child process.
# Every arm below is REAL (a real bash, the real ps, the real /proc) because a shim can only prove the
# matcher agrees with the shim. Both directions are asserted against the SAME fixture shape, so a gate
# that simply stopped reading cwd would fail the control arm.
RK="$(newrepo k)"
W_K="$(mkwt "$RK" idle)"
# An IDLE shell: `bash` blocked opening a fifo for read, no children, cwd inside the worktree. It is a
# shell (is_shell_pid), it has no child (has_child), and it starts NOW — so the HEAD commit below is
# what makes it "started before the last commit".
mkfifo "$T/kfifo"
( cd "$W_K" && exec bash -c 'read -r _x' < "$T/kfifo" ) 2>/dev/null &
IDLE_SHELL_PID=$!
sleep 1
# HEAD AFTER the shell started: that is what "idle since before the worktree's last commit" means, and
# the rule reads the COMMIT's own time — so the fixture stamps it in the future by a stated margin
# rather than lie about the process start (only the kernel sets that).
K_HEAD_TS=$(( $(date +%s) + 600 ))
GIT_AUTHOR_DATE="@$K_HEAD_TS" GIT_COMMITTER_DATE="@$K_HEAD_TS" \
  git -C "$W_K" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "committed after the shell sat down"
idle_cwd="$(readlink "/proc/$IDLE_SHELL_PID/cwd" 2>/dev/null || true)"
if [ "${idle_cwd:-}" = "$(canon "$W_K")" ]; then
  echo " K1 the same fixture reads LIVE when the shell is DOING something (a child)"
  # The control: a shell with a child is a lane doing work — the witness must still decide KEEP.
  ( cd "$W_K" && exec bash -c 'while :; do sleep 3600; done' ) 2>/dev/null &
  BUSY_PID=$!
  sleep 1
  out="$(run_real --worktree "$W_K" --apply)"
  assert_contains "$out" "KEEP live-cwd" "a shell WITH a child is still a live holder (the control)"
  exists "$W_K/.venv" "so its env survives"
  # ⛔ KILL THE WHOLE HOLDER TREE, not just the shell (measured while writing this section): the busy
  # shell's `sleep` child is REPARENTED when its parent dies, keeps `cwd=$W_K` by inheritance, and then
  # the NEXT arm sees a NON-shell holder and reads LIVE — K2 would "fail" for a leftover, not for the
  # rule. `pkill -P` cannot help after the parent is gone, so sweep every pid still cwd'd in the
  # worktree except the idle shell this section deliberately keeps.
  kill -9 "$BUSY_PID" 2>/dev/null; wait "$BUSY_PID" 2>/dev/null
  for _p in $(ls /proc 2>/dev/null | grep -E '^[0-9]+$'); do
    [ "$_p" = "$IDLE_SHELL_PID" ] && continue
    [ "$(readlink "/proc/$_p/cwd" 2>/dev/null)" = "$(canon "$W_K")" ] && kill -9 "$_p" 2>/dev/null
  done
  sleep 1

  echo " K2 an IDLE shell predating HEAD is DEMOTED — the env is reaped, and the demotion is NAMED"
  # The demotion is recorded in the PASS LOG (it is emitted from inside the witness reader, i.e. a
  # command substitution — a `say` there would be captured as the witness string). The log is where an
  # operator reads why a holder stopped counting, so that is what this asserts on.
  : > "$T/reap-real.log"
  out="$(run_real --worktree "$W_K" --apply)"
  logtxt="$(cat "$T/reap-real.log" 2>/dev/null)"
  assert_contains "$logtxt" "stale-shell:" "the demotion is stated in the pass log, not silent"
  assert_contains "$logtxt" "idle shell predating HEAD is not a live lane" "…and it says WHY, in the rule's own words"
  assert_contains "$out" "REAP" "with the idle shell demoted the lane reads dead"
  absent "$W_K/.venv" "the env is reclaimed"
  exists "$W_K/f.txt" "the worktree's TRACKED content is untouched (only .venv was removed)"

  echo " K3 the switch restores the strict reading (an operator can undo this without editing code)"
  # Rebuild the env; the SAME idle shell is still sitting there.
  mkvenv "$W_K"
  out="$(REAP_VENV_IDLE_SHELL=0 run_real --worktree "$W_K" --apply)"
  assert_contains "$out" "KEEP live-cwd" "with REAP_VENV_IDLE_SHELL=0 the idle shell counts as live again"
  exists "$W_K/.venv" "and nothing is removed"

  echo " K4 FAIL CLOSED: a shell that does NOT predate HEAD is not demoted"
  # The other direction of the SAME rule, and it needs its own HEAD: the previous arms' HEAD is stamped
  # in the FUTURE (that is how a fixture makes a holder predate it), so it would also "predate" a shell
  # started now. So the idle shell is put away and HEAD is moved BACK behind the young shell — then the
  # holder does NOT satisfy "predates HEAD" and must keep the env.
  kill "$IDLE_SHELL_PID" 2>/dev/null; wait "$IDLE_SHELL_PID" 2>/dev/null
  OLD_TS=$(( $(date +%s) - 600 ))
  GIT_AUTHOR_DATE="@$OLD_TS" GIT_COMMITTER_DATE="@$OLD_TS" \
    git -C "$W_K" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "committed before the shell sat down"
  rm -rf "$W_K/.venv"; mkvenv "$W_K"
  ( cd "$W_K" && exec bash -c 'read -r _x' < "$T/kfifo" ) 2>/dev/null &
  YOUNG_PID=$!
  sleep 1
  out="$(run_real --worktree "$W_K" --apply)"
  assert_contains "$out" "KEEP live-cwd" "a shell that started AFTER the last commit is still a live holder"
  exists "$W_K/.venv" "so its env survives — the rule is 'predates HEAD', not 'is a shell'"
  kill "$YOUNG_PID" 2>/dev/null; wait "$YOUNG_PID" 2>/dev/null
else
  echo "  ⏭ SKIP K1-K4: could not place a shell with its cwd inside the worktree (got '${idle_cwd:-<none>}')"
  kill "$IDLE_SHELL_PID" 2>/dev/null; wait "$IDLE_SHELL_PID" 2>/dev/null
fi
rm -f "$T/kfifo"

# ── K5: EVERY holder is examined, and the scan TERMINATES (§2721 review round 1, P1+P2) ───────────
# The first version advanced the scan by REWRITING THE PROBE TABLE, which was (a) unbounded — a failed
# write on a full cell left the row in place and the loop never terminated, in the one state this
# reaper exists for — and (b) shared, so a pid inside a nested worktree consumed the evidence another
# worktree needed. Both defects reduce to "the scan must reach holder N+1 without mutating anything",
# which is what this arm pins: THREE holders, the first two idle shells, the third a working one. The
# verdict must be KEEP, it must come from the THIRD pid, and the pass must FINISH (a reintroduced
# mutation loop hangs here instead of returning).
RK5="$(newrepo k5)"
W_K5="$(mkwt "$RK5" idle3)"
mkfifo "$T/k5fifo"
( cd "$W_K5" && exec bash -c 'read -r _x' < "$T/k5fifo" ) 2>/dev/null &
K5A=$!
( cd "$W_K5" && exec bash -c 'read -r _x' < "$T/k5fifo" ) 2>/dev/null &
K5B=$!
sleep 1
K5_HEAD=$(( $(date +%s) + 600 ))
GIT_AUTHOR_DATE="@$K5_HEAD" GIT_COMMITTER_DATE="@$K5_HEAD" \
  git -C "$W_K5" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "two idle shells sat down first"
( cd "$W_K5" && exec bash -c 'while :; do sleep 3600; done' ) 2>/dev/null &
K5C=$!
sleep 1
if [ "$(readlink "/proc/$K5A/cwd" 2>/dev/null || true)" = "$(canon "$W_K5")" ] &&
   [ "$(readlink "/proc/$K5C/cwd" 2>/dev/null || true)" = "$(canon "$W_K5")" ]; then
  echo " K5 two IDLE shells then a WORKING holder: the verdict comes from the third, and the pass ends"
  # The real drive: the FIRST two holders are demoted (named), the THIRD keeps the env, and the pass
  # returns instead of spinning. `timeout` is the assertion that it TERMINATES — a hung pass fails.
  out="$(timeout 300 env PS_BIN=/bin/ps LSOF_BIN="$(command -v lsof || true)" TMUX_BIN=/nonexistent/tmux \
          DF_BIN="$T/bin/df" DU_BIN="$T/bin/du" REAP_VENV_FREE_FLOOR_MB=2048 \
          REAP_VENV_LOG="$T/reap-k5.log" bash "$REAPER" --worktree "$W_K5" --apply 2>&1)"; rc=$?
  assert_eq "$rc" "0" "the pass completes (a reintroduced table-mutation loop would hang and time out)"
  assert_contains "$out" "KEEP live-cwd" "the THIRD holder decides: a working shell still keeps the env"
  exists "$W_K5/.venv" "so the env survives"
  k5log="$(cat "$T/reap-k5.log" 2>/dev/null)"
  assert_contains "$k5log" "stale-shell:" "the demoted holders are still NAMED in the pass log"
  kill -9 "$K5C" 2>/dev/null; wait "$K5C" 2>/dev/null
  for _p in $(ls /proc 2>/dev/null | grep -E '^[0-9]+$'); do
    case "$_p" in "$K5A"|"$K5B") continue ;; esac
    [ "$(readlink "/proc/$_p/cwd" 2>/dev/null)" = "$(canon "$W_K5")" ] && kill -9 "$_p" 2>/dev/null
  done
  sleep 1
else
  echo "  ⏭ SKIP K5: could not place the holders inside the worktree"
fi
kill "$K5A" "$K5B" 2>/dev/null; wait "$K5A" "$K5B" 2>/dev/null
rm -f "$T/k5fifo"

# ── K6: a ZERO-PADDED `ps -o etime` parses as DECIMAL, so the BSD fallback can demote at all ───────
# `ps -o etime` prints zero-padded fields (`1:08:30`), and bash rejects `08` as a bad OCTAL constant:
# the arithmetic ERRORED, the start time came back EMPTY, and the holder stayed live for ever — the
# rule silently never fired on any host that reaches the fallback. The arm pins the HOURS component
# specifically: HEAD is 1,000s in the past and the elapsed time is 1:08:30, so a parse that DROPS the
# hours (start = now-510) reads the shell as YOUNGER than HEAD and keeps it — the mutant fails here.
RK6="$(newrepo k6)"
W_K6="$(mkwt "$RK6" etime)"
mkvenv "$W_K6"
K6_TS=$(( $(date +%s) - 1000 ))
GIT_AUTHOR_DATE="@$K6_TS" GIT_COMMITTER_DATE="@$K6_TS" \
  git -C "$W_K6" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "HEAD 1000s before this pass"
printf '1 0 /sbin/launchd\n4242 1 /bin/bash\n' > "$T/k6-ps.txt"
printf 'p4242\nn%s\n' "$(canon "$W_K6")" > "$T/k6-lsof.txt"
out="$(run_shimmed FAKE_PS_TABLE="$T/k6-ps.txt" FAKE_LSOF_TABLE="$T/k6-lsof.txt" \
        FAKE_ETIME='1:08:30' REAP_VENV_PROC_ROOT="$T/no-proc" \
        --worktree "$W_K6" --apply)"
assert_contains "$out" "REAP" "a 1:08:30 idle shell that predates HEAD is demoted, so the env is reaped"
absent "$W_K6/.venv" "the env was actually removed"
assert_contains "$(cat "$T/reap.log" 2>/dev/null)" "stale-shell:" "…and the demotion is named"

# ── K7: the store cap may not TRUNCATE the scan into "no live holder" (#2721 review round 2, P2) ──
# The cap is a runaway guard, and its first version counted only the cwd+tmux tables — so on a host
# with no lsof (`REAP_VENV_ALLOW_DEGRADED_CWD=1`) and no tmux server it collapsed to 4, and a worktree
# with five holders was truncated at the fourth and read as UNHELD, reaping a live lane's env. The
# fifth holder here is a `python3` (never demotable), so the verdict must be KEEP: reaching it is the
# property, and the pre-fix tree stops one row short and prints REAP.
RK7="$(newrepo k7)"
W_K7="$(mkwt "$RK7" five)"
mkvenv "$W_K7"
K7_TS=$(( $(date +%s) + 600 ))
GIT_AUTHOR_DATE="@$K7_TS" GIT_COMMITTER_DATE="@$K7_TS" \
  git -C "$W_K7" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "HEAD after the holders sat down"
K7_CANON="$(canon "$W_K7")"
{
  printf '1 0 /sbin/launchd\n'
  i=0
  while [ "$i" -lt 4 ]; do
    i=$((i + 1)); printf '%s 1 /bin/bash -c cd %s idle-%s\n' "$((5000 + i))" "$K7_CANON" "$i"
  done
  printf '5100 1 /usr/bin/python3 %s/.venv/bin/python\n' "$K7_CANON"
} > "$T/k7-ps.txt"
: > "$T/reap.log"   # the log is APPEND-ONLY across the whole suite: read only THIS pass
out="$(run_shimmed FAKE_PS_TABLE="$T/k7-ps.txt" FAKE_LSOF_FAIL=1 \
        REAP_VENV_PROC_ROOT="$T/no-proc" REAP_VENV_ALLOW_DEGRADED_CWD=1 FAKE_ETIMES=600 \
        --worktree "$W_K7" --apply)"
assert_contains "$out" "KEEP" "the scan reaches the FIFTH holder and keeps the env (the cap does not truncate)"
assert_contains "$out" "live-argv" "…and the verdict names the argv witness that decided it"
exists "$W_K7/.venv" "the env survives — an idle shell and a working lane share the worktree"
# ⛔ AND THE SCAN WAS NOT TRUNCATED (review round 3, P2). Mutation-verified: reverting the cap to the
# round-2 form (cwd+tmux only) left this arm GREEN, because a truncation prints `live-argv` for the
# fifth holder too — byte-identical to reaching it. The pass log's `TRUNCATED` line is the ONLY
# observable that separates "the cap holds" from "the cap cut the scan short and we got lucky", so the
# assertion has to read it, and its ABSENCE is the claim.
if grep -q 'stale-shell-scan TRUNCATED' "$T/reap.log" 2>/dev/null; then
  bad "…but the scan WAS truncated (reap.log names it) — the cap cut the witness list short"
else
  ok "…and the scan was NOT truncated, so the cap cannot hide a holder behind a lucky witness (log clean)"
fi

# ── K8/K9: the per-record EXCLUDE LIST is what makes the CWD and TMUX arms terminate ─────────────
# The idle-shell rule demotes a holder and adds its pid to the exclude list, so the next probe call
# advances instead of re-reporting the pid it just demoted. K7 pins that for the ARGV table, and the two
# remaining sites were UNEVEN in coverage — measured on the 207-assertion tree: deleting the skip from
# `cwd_witness_for` left it at 203/207 (FOUR red: K2's `k/idle` pair and K6's `1:08:30` pair already
# reached that site), while deleting the skip from `tmux_witness_for` left 207/207 GREEN. So K9 is the arm that closed a real gap
# and K8 makes the cwd site explicit rather than incidental — stated that way round because the failure
# mode of a lost skip is the same at both sites: the scan re-reads the pid it just demoted until the
# runaway cap, then fails closed, i.e. the KEEP rule silently stops firing for the exact cell-4 shape
# (#2721: 59 checkouts held by idle shells) with every arm green. Each fixture has ONE holder, in ONE
# table, so the arm is only green when the scan advances past it and reaps.
RK8="$(newrepo k8)"
W_K8="$(mkwt "$RK8" cwdskip)"
K8_TS=$(( $(date +%s) - 1000 ))
GIT_AUTHOR_DATE="@$K8_TS" GIT_COMMITTER_DATE="@$K8_TS" \
  git -C "$W_K8" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "HEAD 1000s before this pass"
K8_CANON="$(canon "$W_K8")"
printf '1 0 /sbin/launchd\n65002 1 /bin/bash\n' > "$T/k8-ps.txt"
printf 'p65002\nn%s\n' "$K8_CANON" > "$T/k8-lsof.txt"
: > "$T/reap.log"
out="$(run_shimmed FAKE_PS_TABLE="$T/k8-ps.txt" FAKE_LSOF_TABLE="$T/k8-lsof.txt" \
        FAKE_ETIME='10:00:00' REAP_VENV_PROC_ROOT="$T/no-proc" \
        --worktree "$W_K8" --apply)"
assert_contains "$out" "REAP" "K8 a lone CWD holder that is an idle shell is demoted and the env reaped"
absent "$W_K8/.venv" "K8 the env was actually removed"
assert_contains "$(cat "$T/reap.log" 2>/dev/null)" "stale-shell: pid=65002(cwd)" \
    "K8 ...and the CWD demotion is named with its witness"
if grep -q 'TRUNCATED' "$T/reap.log" 2>/dev/null; then
  bad "K8 the scan was TRUNCATED - the cwd witness did not advance past the demoted pid"
else
  ok "K8 and the scan advanced (no TRUNCATED line): the exclude list is consulted by the cwd probe"
fi

RK9="$(newrepo k9)"
W_K9="$(mkwt "$RK9" tmuxskip)"
K9_TS=$(( $(date +%s) - 1000 ))
GIT_AUTHOR_DATE="@$K9_TS" GIT_COMMITTER_DATE="@$K9_TS" \
  git -C "$W_K9" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "HEAD 1000s before this pass"
K9_CANON="$(canon "$W_K9")"
printf '1 0 /sbin/launchd\n65003 1 /bin/bash\n' > "$T/k9-ps.txt"
printf '65003\t%s\n' "$K9_CANON" > "$T/k9-tmux.txt"
: > "$T/reap.log"
out="$(run_shimmed FAKE_PS_TABLE="$T/k9-ps.txt" FAKE_TMUX_TABLE="$T/k9-tmux.txt" \
        FAKE_ETIME='10:00:00' REAP_VENV_PROC_ROOT="$T/no-proc" \
        --worktree "$W_K9" --apply)"
assert_contains "$out" "REAP" "K9 a lone TMUX-PANE holder that is an idle shell is demoted too (the pane witness has the same rule)"
absent "$W_K9/.venv" "K9 the env was actually removed"
assert_contains "$(cat "$T/reap.log" 2>/dev/null)" "stale-shell: pid=65003(tmux-pane)" \
    "K9 ...and the pane demotion is named with its witness"
if grep -q 'TRUNCATED' "$T/reap.log" 2>/dev/null; then
  bad "K9 the scan was TRUNCATED - the tmux witness did not advance past the demoted pid"
else
  ok "K9 and the scan advanced (no TRUNCATED line): the exclude list is consulted by the tmux probe"
fi

# ── K10: the CAP-EXHAUSTION branch keeps the env (a truncated scan is never "no holder") ───────
# The cap is a runaway guard, and its exhaustion branch is otherwise unreachable (the default exceeds any
# holder count, and each iteration consumes a distinct pid) — so its POLARITY was unpinned: reverting it to
# "give up" kept this suite green while a truncated scan would read as "every holder was demoted" and the
# lane's env deleted (review round 8, P2). `REAP_VENV_SCAN_CAP` (a test seam; production never sets it)
# makes the branch reachable: three demotable idle shells and a cap of two.
RK10="$(newrepo k10)"
W_K10="$(mkwt "$RK10" caps)"
K10_TS=$(( $(date +%s) - 1000 ))
GIT_AUTHOR_DATE="@$K10_TS" GIT_COMMITTER_DATE="@$K10_TS" \
  git -C "$W_K10" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "HEAD 1000s before this pass"
K10_CANON="$(canon "$W_K10")"
{
  printf '1 0 /sbin/launchd\n'
  i=0
  while [ "$i" -lt 3 ]; do
    i=$((i + 1))
    printf '%s 1 /bin/bash\n' "$((64000 + i))"
  done
} > "$T/k10-ps.txt"
# The cwd table carries the same three pids (lsof's `p<pid>` / `n<path>` records), so the cwd witness
# alone can exhaust the cap and the demotions never drain it.
{
  i=0
  while [ "$i" -lt 3 ]; do i=$((i + 1)); printf 'p%s\nn%s\n' "$((64000 + i))" "$K10_CANON"; done
} > "$T/k10-lsof.txt"
: > "$T/reap.log"
out="$(run_shimmed FAKE_PS_TABLE="$T/k10-ps.txt" FAKE_LSOF_TABLE="$T/k10-lsof.txt" \
        FAKE_ETIME='10:00:00' REAP_VENV_PROC_ROOT="$T/no-proc" REAP_VENV_SCAN_CAP=2 \
        --worktree "$W_K10" --apply)"
assert_contains "$out" "KEEP" "K10 a TRUNCATED scan keeps the env (it is never read as 'no live holder')"
exists "$W_K10/.venv" "K10 ...the env is still there"
assert_contains "$(cat "$T/reap.log" 2>/dev/null)" "TRUNCATED" \
    "K10 ...and the pass says the scan was truncated, so the keeper is explainable"

echo
echo "──────────────────────────────────────────────────────────────────────────────────────"
if [ "$FAIL" -eq 0 ]; then
  echo "ALL PASS ($PASS assertions)"
  exit 0
fi
echo "FAILURES: $FAIL of $((PASS + FAIL)) assertions"
exit 1
