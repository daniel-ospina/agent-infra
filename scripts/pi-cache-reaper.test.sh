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
[ "$RC" -eq 0 ] && ok "dry-run exits 0 (nothing attempted)" || bad "dry-run exited $RC"
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

say_case "H. WIRING — a timed job on BOTH surfaces, and bringup reports the size"
TPL="$REPO_ROOT/templates/launchd/com.eldato.pi-cache-reaper.plist"
if [ -f "$TPL" ]; then
    ok "launchd template exists (the Mac timed job)"
    grep -qF '{{HOME}}/.pi/agent/scripts/pi-cache-reaper.sh' "$TPL" \
        && ok "the template runs the FARMED script path (launchd cannot read ~/Documents, #427)" \
        || bad "the template does not point at the farmed script path"
    grep -qF 'CACHE_REAPER_MAX_MB' "$TPL" && ok "the template carries the size bound" \
                                          || bad "the template does not carry CACHE_REAPER_MAX_MB"
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
