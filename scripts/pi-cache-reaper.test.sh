#!/usr/bin/env bash
# pi-cache-reaper.test.sh — the regression contract for agent-infra#1987.
#
# THE INCIDENT. Cell `pi-cell-3` sat at 258 MB free and refused every dispatch while its controller
# kept beating and its queue read fine. `~/.cache/uv` held 7.1 GB — the machine-global package cache
# that EVERY lane's `uv sync`/`uv run` on that box feeds, and that nothing bounded (#1949 reaps a
# lane's own `.venv`; #1851/#1858 bound worktree weight; #1745 sweeps worktree-root caches).
# Clearing it freed 7.1 GB and the same box launched a lane immediately.
#
# WHAT THIS SUITE PINS (all against the SHIPPED script — a re-implementation would pass on the
# broken copy too):
#
#   A. the over-bound fixture is MEASURED as over the bound (the case cannot pass vacuously), and a
#      dry-run changes nothing — the pre-fix state is "nothing bounds this cache".
#   B. the ladder RUNS: the sink's own prune is invoked, and what remains over the bound is refused
#      with a NON-ZERO exit rather than reported as success.
#   C. escalation is for EXCLUSIVELY cache-owned entries only: the largest exclusive entry is
#      reclaimed and the entry a live venv HARDLINKS into is left alone — the exact mistake the first
#      version made on the live box (4.1 GB "removed", `df` +5 MB, 174/266 entries alive in venvs).
#   D. the HOLDER gate: with `uv`'s own `.lock` held, nothing is deleted and the pass refuses.
#   E. REFUSE-TO-ACT: a ladder that frees nothing on an over-bound sink exits non-zero and says so.
#   F. a live npm process blocks the escalation, and a `ps` probe that cannot run counts as BUSY.
#   G. absent / within-bound sinks are NOT failures and invoke no tool (non-vacuity).
#   H. WIRING (issue point 3): the timed job exists on BOTH surfaces (launchd template + the cell's
#      controller cadence), `pi-bootstrap/setup.sh` farms the script the plist names, bringup reports
#      the cache size, and this suite is in the one shard list both lanes run. A reaper nothing
#      invokes is the bug, not the fix.
#   I. a SYMLINKED sink is measured, not read as 0 MB (`ln -s /data/uv ~/.cache/uv` is the standard
#      small-root-disk workaround — the layout most likely to need the bound).
#   J. DRY-RUN IS THE DEFAULT: no mode flag deletes nothing; `--apply` acts.
#   K. an out-of-range `--max-mb` is REFUSED (exit 2), never silently repaired into a different bound.
#   L. npm/pip act on the sink that was MEASURED (npm needs `--cache <root>`, pip `--cache-dir <dir>`),
#      not on their own defaults.
#   M. the uv lock is HELD for the whole escalation (a competing acquire fails while it is held), and
#      the holder cleans up after itself.
#   N. the lock holder leaves NOTHING behind — no marker dir on the normal path, and none after the
#      shell holding it is KILLED (the flock is released by the holder's parent check).
#   O. an unset HOME with every sink named refuses with the documented exit 3 and a message, rather
#      than dying on an unbound `HOME` inside the log default (exit 1, bare bash error).
#
# Hermetic: temp HOME with fixture cache trees, stub `uv`/`npm`/`pip3`/`ps` on PATH, no network, no
# real cache touched. Run: bash scripts/pi-cache-reaper.test.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
REAPER="$HERE/pi-cache-reaper.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }
say_case() { echo; echo "── $1 ──"; }

T="$(mktemp -d "${TMPDIR:-/tmp}/cache-reaper-1987.XXXXXX")"
trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT

TBIN="$T/bin"
mkdir -p "$TBIN"
export PATH="$TBIN:$PATH"

# ── fixtures ─────────────────────────────────────────────────────────────────
# mk_uv_cache <name> <home> <exclusive_mb> <shared_mb> — an `archive-v0` holding one EXCLUSIVE entry
# (nothing else references it) and one SHARED entry whose only file is hardlinked into a fake
# worktree venv, so its link count is 2 — exactly what a real lane's `.venv` does.
mk_uv_cache() {
    local name="$1" home="$2" ex="$3" sh="$4" root venv
    root="$home/.cache/uv"; venv="$T/worktree-$name/.venv/lib/python3.12/site-packages"
    mkdir -p "$root/archive-v0/exclusive-entry/pkg" "$root/archive-v0/shared-entry/pkg" "$venv"
    printf 'x' > "$root/.lock"
    dd if=/dev/zero of="$root/archive-v0/exclusive-entry/pkg/big.bin" bs=1048576 count="$ex" 2>/dev/null
    dd if=/dev/zero of="$root/archive-v0/shared-entry/pkg/pkg.bin" bs=1048576 count="$sh" 2>/dev/null
    ln "$root/archive-v0/shared-entry/pkg/pkg.bin" "$venv/pkg.bin"
}

mk_npm_cache() { # <home> <mb>
    mkdir -p "$1/.npm/_cacache/content-v2"
    dd if=/dev/zero of="$1/.npm/_cacache/content-v2/blob.bin" bs=1048576 count="$2" 2>/dev/null
}

# ── stubs ────────────────────────────────────────────────────────────────────
# `uv` records every invocation and models `cache prune` as a NO-OP that succeeds — what the real tool
# does to a cache whose entries are all still referenced, and the state a refuse-to-act check must
# survive.
cat > "$TBIN/uv" <<'SHIM'
#!/usr/bin/env bash
echo "uv $*" >> "${STUB_LOG:?}"
exit "${UV_PRUNE_RC:-0}"
SHIM
cat > "$TBIN/npm" <<'SHIM'
#!/usr/bin/env bash
echo "npm $*" >> "${STUB_LOG:?}"
exit "${NPM_RC:-0}"
SHIM
cat > "$TBIN/pip3" <<'SHIM'
#!/usr/bin/env bash
echo "pip3 $*" >> "${STUB_LOG:?}"
exit "${PIP_RC:-0}"
SHIM
chmod +x "$TBIN/uv" "$TBIN/npm" "$TBIN/pip3"

# `ps` stub: a live-process line, or a FAILING probe (PS_FAIL=1) — the reaper asks for
# `-axo pid=,command=`, and a probe that cannot run must count as BUSY.
cat > "$TBIN/ps" <<'SHIM'
#!/usr/bin/env bash
if [ "${PS_FAIL:-0}" = 1 ]; then echo "ps: cannot run" >&2; exit 1; fi
printf '%s\n' "${PS_OUT:- 1 /usr/bin/init}"
exit 0
SHIM
chmod +x "$TBIN/ps"

REAPER_ARGS=()
# run_reaper <home> [ENV=VAL ...] — drive the SHIPPED script against a fixture HOME.
run_reaper() {
    local home="$1"; shift
    (
        export HOME="$home"
        export STUB_LOG="$T/stub.log"
        export CACHE_REAPER_LOG="$home/.pi/agent/state/pi-cache-reaper.log"
        export UV_CACHE_DIR="$home/.cache/uv"
        export NPM_CACHE_DIR="$home/.npm/_cacache"
        export PIP_CACHE_DIR="$home/.cache/pip"
        export PS_BIN="$TBIN/ps"
        export PYTHON_BIN="$(command -v python3)"
        local kv
        for kv in "$@"; do export "$kv"; done
        # stderr is merged in: the refuse-to-act verdict goes to stderr by design, and a case
        # that reads only stdout would miss the very line it is asserting on.
        bash "$REAPER" "${REAPER_ARGS[@]}" 2>&1
    )
}

sink_mb() { du -sk "$1" 2>/dev/null | awk '{print int($1/1024)}'; }
stub_calls() { wc -l < "$T/stub.log" 2>/dev/null | tr -d ' '; }

say_case "0. the fix exists, is executable, and parses"
[ -x "$REAPER" ] && ok "scripts/pi-cache-reaper.sh is present and executable" \
                 || bad "scripts/pi-cache-reaper.sh is missing or not executable"
bash -n "$REAPER" && ok "the shipped script parses (bash -n)" || bad "the shipped script does not parse"

say_case "A. an over-bound fixture IS over the bound (no vacuous pass), and dry-run changes nothing"
H="$T/homeA"; mkdir -p "$H"
mk_uv_cache A "$H" 40 30
BEFORE="$(sink_mb "$H/.cache/uv")"
[ "$BEFORE" -gt 10 ] && ok "fixture measures ${BEFORE}MB against a 10MB bound — the #1987 state (a cache nothing bounds)" \
                     || bad "fixture measures only ${BEFORE}MB — the case would be vacuous"
: > "$T/stub.log"
REAPER_ARGS=(--dry-run --max-mb 10)
OUT="$(run_reaper "$H")"; RC=$?
# A dry run attempts nothing, but its rc is a statement about the SINKS: an over-bound sink must not
# read as green just because the reaper was disarmed (that would make the disarm a false "check").
[ "$RC" -eq 3 ] && ok "dry-run exits 3 while a sink is over the bound (nothing attempted, bound not met)" \
                || bad "dry-run exited $RC — an over-bound sink must not be a green verdict"
grep -qF "DRY-RUN: nothing was attempted" <<<"$OUT" && ok "the dry-run refusal says nothing was attempted and names --apply" \
                                                || bad "the dry-run refusal did not distinguish 'nothing attempted'"
grep -qF "OVER max=10MB" <<<"$OUT" && ok "dry-run REPORTS the fixture as over the bound" \
                                     || bad "dry-run did not report the fixture as over the bound"
AFTER="$(sink_mb "$H/.cache/uv")"
[ "$AFTER" -ge "$BEFORE" ] && ok "dry-run deleted nothing (${BEFORE}MB -> ${AFTER}MB)" \
                           || bad "dry-run deleted bytes (${BEFORE}MB -> ${AFTER}MB)"
[ "$(stub_calls)" -eq 0 ] && ok "dry-run invoked no tool" || bad "dry-run invoked a tool"

say_case "B. the ladder RUNS: the sink's own prune is invoked, and the residue is REFUSED"
H="$T/homeB"; mkdir -p "$H"
mk_uv_cache B "$H" 40 30
: > "$T/stub.log"
REAPER_ARGS=(--apply --max-mb 10)
OUT="$(run_reaper "$H")"; RC=$?
grep -qF "uv cache prune" "$T/stub.log" && ok "the sink's OWN prune was invoked (uv cache prune)" \
                                        || bad "uv cache prune was never invoked — the ladder skipped its first rung"
[ "$RC" -eq 3 ] && ok "exit 3 while the fixture is still over the bound after the ladder" \
                || bad "expected exit 3 (still over bound), got $RC"
grep -qF "STILL OVER" <<<"$OUT" && ok "the refusal NAMES the state (STILL OVER)" \
                                || bad "the refusal did not say the sink is still over the bound"
[ -e "$H/.cache/uv/archive-v0/shared-entry/pkg/pkg.bin" ] && ok "the HARDLINKED entry survived (a live venv still holds its inodes)" \
                                                         || bad "the hardlinked entry was deleted — a live venv's bytes were sacrificed for nothing"

say_case "C. escalation reclaims the largest EXCLUSIVE entry and never a venv-held one"
H="$T/homeC"; mkdir -p "$H"
mk_uv_cache C "$H" 40 30     # 70MB total: 40MB exclusive + 30MB shared
: > "$T/stub.log"
REAPER_ARGS=(--apply --max-mb 10)
OUT="$(run_reaper "$H")"; RC=$?
[ -d "$H/.cache/uv/archive-v0/exclusive-entry" ] && bad "the largest EXCLUSIVE entry was not reclaimed (nothing freed)" \
                                                || ok "the largest exclusive entry was reclaimed"
[ -e "$H/.cache/uv/archive-v0/shared-entry/pkg/pkg.bin" ] && ok "the venv-held entry was left alone" \
                                                         || bad "the venv-held entry was deleted"
grep -qF "HARDLINKED into live venvs" <<<"$OUT" && ok "the residue is explained in the output (hardlinked into venvs)" \
                                                || bad "the output did not explain the shared-inode residue"
[ "$RC" -eq 3 ] && ok "still over the bound (the shared residue) -> exit 3" || bad "expected exit 3, got $RC"
grep -qF " -> " <<<"$OUT" && ok "one line carries before -> after" || bad "no before -> after line"

say_case "D. the HOLDER gate: a held uv lock means NO deletion and a refusal"
H="$T/homeD"; mkdir -p "$H"
mk_uv_cache D "$H" 40 30
: > "$T/stub.log"
REAPER_ARGS=(--apply --max-mb 10)
OUT="$(
    python3 - "$H/.cache/uv/.lock" <<'PY' &
import fcntl, sys, time
h = open(sys.argv[1], "r+b")
fcntl.flock(h.fileno(), fcntl.LOCK_EX)
time.sleep(10)
PY
    holder=$!
    sleep 1
    run_reaper "$H"
    rc=$?
    kill "$holder" 2>/dev/null
    exit "$rc"
)"; RC=$?
[ -d "$H/.cache/uv/archive-v0/exclusive-entry" ] && ok "nothing was deleted while a lane held the cache lock" \
                                                || bad "the reaper deleted entries while the lock was HELD"
grep -qF "IN USE" <<<"$OUT" && ok "the deferral is named (IN USE)" || bad "the deferral was not named"
[ "$RC" -eq 3 ] && ok "the held-lock pass is a REFUSAL (exit 3), not a claim of success" \
                || bad "expected exit 3 on a held lock, got $RC"

say_case "E. REFUSE-TO-ACT: a ladder that frees nothing is not reported as success"
H="$T/homeE"; mkdir -p "$H"
mk_uv_cache E "$H" 1 40
rm -rf "$H/.cache/uv/archive-v0/exclusive-entry"   # nothing left that the cache exclusively owns
BEFORE="$(sink_mb "$H/.cache/uv")"
: > "$T/stub.log"
REAPER_ARGS=(--apply --max-mb 10)
OUT="$(run_reaper "$H")"; RC=$?
AFTER="$(sink_mb "$H/.cache/uv")"
[ "$AFTER" -ge "$BEFORE" ] && ok "nothing was freed (${BEFORE}MB -> ${AFTER}MB) — the honest outcome" \
                           || bad "bytes changed unexpectedly (${BEFORE}MB -> ${AFTER}MB)"
[ "$RC" -ne 0 ] && ok "a no-op ladder exits NON-ZERO (exit $RC)" \
                || bad "a no-op ladder exited 0 — the exact failure mode #1987 forbids"
grep -qF "NOT brought under it" <<<"$OUT" && ok "the refusal says the bound was not met" \
                                          || bad "the refusal did not say the bound was not met"
grep -qF "freed NOTHING" <<<"$OUT" && ok "the refusal says it freed NOTHING (not just 'over bound')" \
                                  || bad "the refusal did not distinguish 'freed nothing'"

say_case "F. a live npm process blocks escalation; a dead ps probe counts as BUSY (fail closed)"
H="$T/homeF"; mkdir -p "$H"
mk_uv_cache F "$H" 1 1
mk_npm_cache "$H" 40
: > "$T/stub.log"
REAPER_ARGS=(--apply --max-mb 10)
OUT="$(run_reaper "$H" PS_OUT=' 42 /usr/bin/npm install')"; RC=$?
grep -qF "npm cache clean" "$T/stub.log" && bad "npm cache was cleaned while an npm process was LIVE" \
                                         || ok "no npm cache clean while an npm process was live"
[ "$RC" -eq 3 ] && ok "the deferred npm sink is a refusal (exit 3), not a pass" \
                || bad "expected exit 3, got $RC"
: > "$T/stub.log"
# ⛔ THE SHAPE THAT MATTERS: npm's bin is a node script (npm-cli.js), so a real install appears as
#   node /usr/lib/node_modules/npm/bin/npm-cli.js install
# — no space after the tool name. A probe requiring a space there answered CLEAR and the cache was
# wiped under a live npm ci (agent-infra#1987 review, P1).
OUT="$(run_reaper "$H" PS_OUT=' 1234 node /usr/lib/node_modules/npm/bin/npm-cli.js install')"; RC=$?
grep -qF "npm cache clean" "$T/stub.log" && bad "npm cache was cleaned under a LIVE npm-cli.js process (the argv shape real npm has)" \
                                         || ok "a live \"node <path>/npm-cli.js install\" process blocks the npm escalation"
[ "$RC" -eq 3 ] && ok "the deferred npm sink is a refusal (exit 3), not a pass" \
                || bad "expected exit 3, got $RC"
: > "$T/stub.log"
OUT="$(run_reaper "$H" PS_OUT=' 42 python3 -m pip install six')"; RC=$?
grep -qF "pip3 cache purge" "$T/stub.log" && bad "the pip cache was purged under a LIVE \"python3 -m pip install\" process" \
                                          || ok "a live \"python3 -m pip install\" process blocks the pip escalation"
: > "$T/stub.log"
OUT="$(run_reaper "$H" PS_FAIL=1)"; RC=$?
grep -qF "npm cache clean" "$T/stub.log" && bad "npm cache was cleaned on a FAILED ps probe (fail-open)" \
                                         || ok "a ps probe that cannot run is treated as BUSY (fail closed)"
[ "$RC" -eq 3 ] && ok "fail-closed probe -> exit 3" || bad "expected exit 3 on probe failure, got $RC"

say_case "G. absent and within-bound sinks are not failures, and invoke no tool"
H="$T/homeG"; mkdir -p "$H"
mk_uv_cache G "$H" 5 5
: > "$T/stub.log"
REAPER_ARGS=(--apply --max-mb 2048)
OUT="$(run_reaper "$H")"; RC=$?
[ "$RC" -eq 0 ] && ok "within-bound + absent sinks exit 0" || bad "expected exit 0, got $RC"
grep -qF "(absent)" <<<"$OUT" && ok "absent sinks are named, not silently skipped" \
                              || bad "absent sinks were not reported"
[ "$(stub_calls)" -eq 0 ] && ok "no tool was invoked when nothing was over the bound" \
                          || bad "a tool was invoked while every sink was within the bound"

say_case "I. a SYMLINKED sink is measured (not a 0MB false pass) and bounded"
H="$T/homeI"; mkdir -p "$H/.cache" "$T/sym-real"
# The sink is a symlink onto another volume — the standard small-root-disk workaround, and an
# unmeasured sink reports "within the bound" while it is the thing filling the disk.
mk_uv_cache Ireal "$T/sym-real-home" 40 0
ln -s "$T/sym-real-home/.cache/uv" "$H/.cache/uv"
BEFORE="$(sink_mb "$T/sym-real-home/.cache/uv")"
[ "$BEFORE" -gt 10 ] && ok "the symlinked fixture really holds ${BEFORE}MB" || bad "the symlink fixture is vacuous (${BEFORE}MB)"
: > "$T/stub.log"
REAPER_ARGS=(--apply --max-mb 10)
OUT="$(run_reaper "$H")"; RC=$?
case "$OUT" in
  *"uv  $H/.cache/uv  0MB"*) bad "the symlinked sink was measured as 0MB — a false PASS on the layout this reaper exists for" ;;
  *) ok "the symlinked sink is not reported as 0MB" ;;
esac
[ -d "$T/sym-real-home/.cache/uv/archive-v0/exclusive-entry" ] && bad "the symlinked sink was not reclaimed (measured as empty)" \
                                                              || ok "the symlinked sink's exclusive entry was reclaimed through the link"
[ "$RC" -eq 0 ] && ok "the symlinked fixture ends within the bound (exit 0)" || bad "expected exit 0 on the symlinked fixture, got $RC"

say_case "J. DRY-RUN is the default; --apply is what acts"
H="$T/homeJ"; mkdir -p "$H"
mk_uv_cache J "$H" 40 0
BEFORE="$(sink_mb "$H/.cache/uv")"
: > "$T/stub.log"
REAPER_ARGS=(--max-mb 10)          # NO mode flag
OUT="$(run_reaper "$H")"; RC=$?
AFTER="$(sink_mb "$H/.cache/uv")"
[ "$AFTER" -ge "$BEFORE" ] && ok "a bare invocation deleted nothing (${BEFORE}MB -> ${AFTER}MB)" \
                           || bad "a bare invocation DELETED bytes — the fleet reaper convention is dry-run by default"
[ "$RC" -eq 3 ] && ok "a bare pass over the bound exits 3 (a report, not a pass)" || bad "bare dry-run exited $RC (expected 3)"
grep -qF "DRY-RUN" <<<"$OUT" && ok "the pass SAYS it was a dry run" || bad "the pass did not name the dry run"
grep -qF "start mode=dry-run" "$H/.pi/agent/state/pi-cache-reaper.log" 2>/dev/null && ok "the LOG records mode=dry-run (a record claiming act would make a later reader believe a reclaim happened)" \
                                                                          || bad "the log claims the wrong mode: $(cat "$H/.pi/agent/state/pi-cache-reaper.log" 2>/dev/null | head -2)"
[ "$(stub_calls)" -eq 0 ] && ok "a bare dry-run invoked no tool" || bad "a bare dry-run invoked a tool"
REAPER_ARGS=(--apply --max-mb 10)
OUT="$(run_reaper "$H")"
[ "$(sink_mb "$H/.cache/uv")" -lt "$BEFORE" ] && ok "--apply is what reclaims (non-vacuity: the default really is the discriminator)" \
                                             || bad "--apply did not reclaim either"

say_case "K. an out-of-range bound is REFUSED, never silently repaired"
H="$T/homeK"; mkdir -p "$H"
mk_uv_cache K "$H" 40 0
BEFORE="$(sink_mb "$H/.cache/uv")"
: > "$T/stub.log"
REAPER_ARGS=(--apply --max-mb 0)
OUT="$(run_reaper "$H")"; RC=$?
[ "$RC" -eq 2 ] && ok "--max-mb 0 is refused with exit 2" || bad "--max-mb 0 exited $RC (expected 2)"
grep -qF "at least 1 MiB" <<<"$OUT" && ok "the refusal names why a 0 bound is refused" || bad "the refusal did not explain the 0 bound"
REAPER_ARGS=(--apply --max-mb 2000000)
OUT="$(run_reaper "$H")"; RC=$?
[ "$RC" -eq 2 ] && ok "an implausible --max-mb is refused with exit 2" || bad "--max-mb 2000000 exited $RC (expected 2)"
[ "$(stub_calls)" -eq 0 ] && ok "a refused bound acted on nothing" || bad "a refused bound still invoked a tool"
# ⛔ 64-bit WRAPAROUND: bash arithmetic turns this into 1 (`$((10#18446744073709551617))` == 1), so a
# guard applied AFTER the conversion would accept the most destructive bound there is while the value
# looked implausible. The digit count is checked on the STRING, so no arithmetic can reach it.
REAPER_ARGS=(--apply --max-mb 18446744073709551617)
OUT="$(run_reaper "$H")"; RC=$?
[ "$RC" -eq 2 ] && ok "a 20-digit bound is refused (no arithmetic wraparound to 1 MiB)" \
                || bad "a 20-digit bound exited $RC — it wrapped into a real bound"
grep -qF "not a plausible" <<<"$OUT" && ok "the wraparound refusal names the bound as implausible" || bad "the refusal did not name the bound"
[ "$(sink_mb "$H/.cache/uv")" -ge "$BEFORE" ] && ok "a wrapped bound deleted nothing" || bad "a wrapped bound deleted bytes"

say_case "L. npm/pip act on the sink that was MEASURED, not on their own defaults"
H="$T/homeL"; mkdir -p "$H"
mk_uv_cache L "$H" 1 0              # uv within the bound: isolate the npm/pip rungs
mk_npm_cache "$H" 40
mkdir -p "$H/.cache/pip/wheels"; dd if=/dev/zero of="$H/.cache/pip/wheels/blob.bin" bs=1048576 count=40 2>/dev/null
: > "$T/stub.log"
REAPER_ARGS=(--apply --max-mb 10)
OUT="$(run_reaper "$H")"; RC=$?
grep -qF "npm cache clean --force --cache $H/.npm" "$T/stub.log" && ok "npm is told the measured --cache root (npm's own layout is <root>/_cacache)" \
                                                                    || bad "npm was invoked without --cache, so it would act on the DEFAULT cache it never measured: $(cat "$T/stub.log")"
grep -qF "pip3 cache purge --cache-dir $H/.cache/pip" "$T/stub.log" && ok "pip is told the measured --cache-dir sink" \
                                                                     || bad "pip was invoked without --cache-dir: $(cat "$T/stub.log")"
[ "$RC" -eq 3 ] && ok "still over the bound after prune-only sinks -> exit 3" || bad "expected exit 3, got $RC"

say_case "M. the uv lock is HELD across the escalation, and the holder cleans up"
# A private TMPDIR for every holder in this suite, so "no crumbs left behind" is ASSERTED rather than
# trusted: an hourly job that leaks a dir per abnormal exit has no bound of its own.
HOLD_TMP="$T/locktmp"; mkdir -p "$HOLD_TMP"
LOCKROOT="$T/lockcase"; mkdir -p "$LOCKROOT"; : > "$LOCKROOT/.lock"
OUT="$(
    ( set +u
      export TMPDIR="$HOLD_TMP"
      . "$REAPER"
      PYTHON_BIN="$(command -v python3)"
      # ⛔ The holder must have NO self-expiry: a deadline would DROP the flock while the caller is
      # still deleting (measured at 600 s in review round 2), which is the check-then-act window the
      # hold exists to close. Pinned at the source, because waiting out a deadline is not a test.
      echo "holder_expiry_lines=$(sed -n '/uv_lock_hold() {/,/^}/p' "$REAPER" | grep -c 'time\.time() +')"
      uv_lock_hold "$LOCKROOT"; echo "hold_rc=$?"
      python3 - "$LOCKROOT/.lock" <<'PY'
import fcntl, sys
try:
    handle = open(sys.argv[1], "r+b")
    fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
except OSError:
    sys.exit(1)     # still held by the reaper: the answer we require
sys.exit(0)
PY
      echo "compete_while_held=$?"
      d="$UV_LOCK_DIR"
      uv_lock_release
      echo "leftover=$([ -e "$d" ] && echo yes || echo no)"
      python3 - "$LOCKROOT/.lock" <<'PY'
import fcntl, sys
try:
    handle = open(sys.argv[1], "r+b")
    fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
except OSError:
    sys.exit(1)
sys.exit(0)
PY
      echo "compete_after_release=$?"
    ) 2>&1
)"
grep -qF "hold_rc=0" <<<"$OUT" && ok "uv_lock_hold acquires a free uv lock" || bad "uv_lock_hold did not acquire: $OUT"
grep -qF "compete_while_held=1" <<<"$OUT" && ok "a competing acquire FAILS while the reaper holds it (the deletes run under the lock)" \
                                       || bad "the lock was NOT held during the escalation window: $OUT"
grep -qF "leftover=no" <<<"$OUT" && ok "the holder cleans up its markers" || bad "the holder leaked its marker dir: $OUT"
grep -qF "holder_expiry_lines=0" <<<"$OUT" && ok "the holder has NO self-expiry (a deadline drops the flock mid-delete)" \
                                           || bad "the holder carries an expiry, so the lock can be released while the caller still deletes: $OUT"
grep -qF "compete_after_release=0" <<<"$OUT" && ok "the lock is free again after release (no wedged uv)" \
                                           || bad "the lock stayed held after release: $OUT"

# held by a live holder: a second uv_lock_hold must REFUSE (1), not steal it. The holder here is the
# reaper's own hold path in a background subshell that simply does not release until it exits.
OUT="$(
    ( set +u
      export TMPDIR="$HOLD_TMP"
      . "$REAPER"
      PYTHON_BIN="$(command -v python3)"
      ( uv_lock_hold "$LOCKROOT"; sleep 2 ) >/dev/null 2>&1 &
      sleep 1
      uv_lock_hold "$LOCKROOT"; echo "second_hold_rc=$?"
      wait
      i=0
      while [ "$i" -lt 60 ]; do [ -z "$(ls -1 "$HOLD_TMP" 2>/dev/null)" ] && break; sleep 0.05; i=$(( i + 1 )); done
      echo "m_leftovers=$(ls -1 "$HOLD_TMP" 2>/dev/null | wc -l | tr -d ' ')"
    ) 2>&1
)"
grep -qF "second_hold_rc=1" <<<"$OUT" && ok "a lock already held by a live process is REFUSED (not stolen)" \
                                     || bad "a held lock was not refused: $OUT"
grep -qF "m_leftovers=0" <<<"$OUT" && ok "the held-lock case leaves no marker dir either" \
                                   || bad "the held-lock case leaked a marker dir: $OUT"

say_case "N. the lock holder leaves nothing behind (normal path, and after a KILL)"
LOCKROOT2="$T/lockcase2"; mkdir -p "$LOCKROOT2"; : > "$LOCKROOT2/.lock"
# (i) normal path: an armed pass over an over-bound fixture leaves no marker dir
H="$T/homeN"; mkdir -p "$H"
mk_uv_cache N "$H" 40 0
: > "$T/stub.log"
REAPER_ARGS=(--apply --max-mb 10)
OUT="$(run_reaper "$H" TMPDIR="$HOLD_TMP")"; RC=$?
[ -z "$(ls -1 "$HOLD_TMP" 2>/dev/null)" ] && ok "a completed escalation leaves no pi-cache-reaper-lock.* dir" \
                                          || bad "leaked marker dir(s): $(ls -1 "$HOLD_TMP")"
# (ii) the shell holding the lock is KILLED: the flock must be released and the dir removed, or an
# hourly job accumulates one per abnormal exit with nothing to bound it.
OUT="$(
    ( set +u
      export TMPDIR="$HOLD_TMP"
      . "$REAPER"
      PYTHON_BIN="$(command -v python3)"
      ( uv_lock_hold "$LOCKROOT2"; sleep 30 ) &
      holder_sub=$!
      sleep 1
      echo "dirs_during=$(ls -1 "$HOLD_TMP" 2>/dev/null | wc -l | tr -d ' ')"
      kill -9 "$holder_sub" 2>/dev/null
      i=0
      while [ "$i" -lt 60 ]; do [ -z "$(ls -1 "$HOLD_TMP" 2>/dev/null)" ] && break; sleep 0.05; i=$(( i + 1 )); done
      python3 - "$LOCKROOT2/.lock" <<'PY'
import fcntl, sys
try:
    handle = open(sys.argv[1], "r+b")
    fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
except OSError:
    sys.exit(1)
sys.exit(0)
PY
      echo "lock_after_kill=$?"
      echo "dirs_after=$(ls -1 "$HOLD_TMP" 2>/dev/null | wc -l | tr -d ' ')"
    ) 2>&1
)"
grep -qF "dirs_during=1" <<<"$OUT" && ok "the holder creates exactly one marker dir while it holds" || bad "no marker dir while holding: $OUT"
grep -qF "lock_after_kill=0" <<<"$OUT" && ok "a KILLED shell's lock is released (the holder exits on parent death, so uv is never wedged)" \
                                      || bad "the lock stayed held after the shell was killed: $OUT"
grep -qF "dirs_after=0" <<<"$OUT" && ok "the killed holder's marker dir is removed too (no unbounded leak)" \
                                  || bad "marker dir leaked after a kill: $OUT"

say_case "O. an unset HOME refuses with the documented exit 3 (not a bare unbound-variable error)"
mkdir -p "$T/homeO"
OUT="$(env -u HOME UV_CACHE_DIR="$T/homeO/uv" NPM_CACHE_DIR="$T/homeO/npm" PIP_CACHE_DIR="$T/homeO/pip" CACHE_REAPER_LOG="" bash "$REAPER" --dry-run 2>&1)"; RC=$?
[ "$RC" -eq 3 ] && ok "unset HOME + unset log path exits 3 (the documented fail-closed code)" \
                || bad "unset HOME exited $RC (expected 3, a bare unbound-variable death is exit 1)"
grep -qF "refusing to guess a cache or log path" <<<"$OUT" && ok "the refusal explains what is unset" \
                                                      || bad "no refusal message: $OUT"

say_case "H. WIRING — a timed job on BOTH surfaces, and bringup reports the size"
TPL="$REPO_ROOT/templates/launchd/com.eldato.pi-cache-reaper.plist"
if [ -f "$TPL" ]; then
    ok "launchd template exists (the Mac timed job)"
    grep -qF '{{HOME}}/.pi/agent/scripts/pi-cache-reaper.sh' "$TPL" \
        && ok "the template runs the FARMED script path (launchd cannot read ~/Documents, #427)" \
        || bad "the template does not point at the farmed script path"
    grep -qF 'CACHE_REAPER_MAX_MB' "$TPL" && ok "the template carries the size bound" \
                                          || bad "the template does not carry CACHE_REAPER_MAX_MB"
    grep -qF '<string>--apply</string>' "$TPL" && ok "the job is ARMED explicitly (--apply) while the script itself ships dry-run" \
                                              || bad "the plist does not pass --apply, so the timed job would be a no-op"
    grep -qF '<key>StartInterval</key>' "$TPL" && ok "the template is scheduled (StartInterval)" \
                                               || bad "the template has no StartInterval"
else
    bad "no launchd template — the Mac surface has no timed job"
fi
grep -qF 'pi-cache-reaper.sh' "$REPO_ROOT/pi-bootstrap/setup.sh" \
    && ok "pi-bootstrap/setup.sh farms it (else install-launchd's broken-target guard refuses the job)" \
    || bad "pi-bootstrap/setup.sh does not farm the script the plist names"
grep -qF 'pi-cache-reaper.sh' "$REPO_ROOT/scripts/orchestrator-harness/orch-loop.sh" \
    && ok "the cell's controller runs it on a cadence (a Linux cell has no launchd)" \
    || bad "nothing on a Linux cell invokes the reaper — the measured box would still die"
grep -qF 'check_caches' "$REPO_ROOT/scripts/cloud-cell-bringup.sh" \
    && ok "bringup --check reports the cache size" || bad "bringup --check does not report cache size"
grep -qF 'pi-cache-reaper.test.sh' "$REPO_ROOT/scripts/run-bash-shards.sh" \
    && ok "this suite is registered in the one shard list both lanes run" \
    || bad "this suite is not in scripts/run-bash-shards.sh — CI would never run it"

echo
echo "── RESULT ──"
echo "  pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
