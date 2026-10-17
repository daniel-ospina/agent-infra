#!/usr/bin/env bash
# daily-backup.test.sh — self-check for scripts/daily-backup.sh's backup TARGET contract (#907)
# and for restore-smoke.sh's "newest RESTORABLE backup" selection.
#
# Run: bash scripts/daily-backup.test.sh
# Exits 0 when ALL assertions pass, 1 on any failure.
#
# Hermetic: a `docker` shim on PATH, a throwaway HOME, and a throwaway copy of the script
# under its own "repo" root (the script derives BACKUP_ROOT from its own location, so this
# is what keeps ~1,263-node RDB snapshots — and the deletion trap — out of the checkout).
# No real container, no network, no node/load-gate (LOAD_GATE_FORCE=1 skips the gate).
#
# WHY THIS SUITE EXISTS
#   The script used to default `CONTAINER=falkordb-personal` — a container that does not
#   exist on the machine, so the RPO ≤ 24h guarantee it advertised was not in force and the
#   drift was invisible (#907). And a failed run left an EMPTY `backups/<timestamp>/`
#   behind, which restore-smoke.sh then picked as "the newest backup" and refused to restore
#   from — one failed backup disabled the verification of the last GOOD one. Coverage:
#   resolve      the target is resolved from the PUBLISHED port, not a literal name; no
#                `falkordb-personal` is ever named; the resolved name lands in the manifest
#   ambiguity    >1 publisher on the port is a refusal naming every candidate (the ::1
#                decoy class, tortoise#6666) — never a coin flip
#   override     CONTAINER=<name> still wins and skips resolution
#   no publisher exit 1 with a diagnostic naming the port, and NOTHING written
#   unverifiable a container that never answers PING is refused before any state exists;
#                a container that is not running is refused too
#   partial      a failure AFTER the directory exists leaves no incomplete directory behind
#                (the trap), so it can never become "the newest backup"
#   polarity     the exit-2 "source looked wrong" artifact IS kept (it carries its manifest)
#   usage        --keep still validates to a positive integer
#   gitignore    the shipped .gitignore ignores the backup root, and is not a blanket '*'
#   selection    restore-smoke.sh's newest-backup pick skips a directory with no dump.rdb

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$SCRIPT_DIR/daily-backup.sh"
SRC_SMOKE="$SCRIPT_DIR/restore-smoke.sh"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }
assert_eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got: $1, want: $2)"; fi }
assert_contains() { if grep -qF -- "$2" <<<"$1"; then ok "$3"; else bad "$3 (missing: $2)"; fi }
assert_not_contains() { if grep -qF -- "$2" <<<"$1"; then bad "$3 (unexpected: $2)"; else ok "$3"; fi }
exists() { if [ -n "$1" ] && [ -e "$1" ]; then ok "$2"; else bad "$2 (missing: ${1:-<empty path>})"; fi }
absent() { if [ -e "$1" ]; then bad "$2 (still present: $1)"; else ok "$2"; fi }

T="$(mktemp -d "${TMPDIR:-/tmp}/daily-backup-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT

# ── the docker shim ────────────────────────────────────────────────────
# Every call is appended to $SHIM_LOG, so a test can assert WHICH container was addressed.
BIN="$T/bin"
mkdir -p "$BIN"
cat > "$BIN/docker" <<'SHIM'
#!/usr/bin/env bash
# Test shim. SHIM_MODE selects the fake machine; SHIM_LOG records every call.
set -u
printf '%s\n' "$*" >> "${SHIM_LOG:-/dev/null}"
sub="$1"; shift || true
case "$sub" in
  ps)
    case "${SHIM_MODE:-one}" in
      none)   : ;;
      two)    printf 'falkordb-16379\nfalkordb-decoy\n' ;;
      *)      printf 'falkordb-16379\n' ;;
    esac
    ;;
  inspect)
    if [ "${SHIM_MODE:-one}" = "stopped" ]; then echo false; else echo true; fi
    ;;
  cp)
    if [ "${SHIM_MODE:-one}" = "cpfail" ]; then
      echo "Error response from daemon: Could not find the file /var/lib/falkordb/data/dump.rdb" >&2
      exit 1
    fi
    dest=""
    for a in "$@"; do dest="$a"; done
    mkdir -p "$(dirname "$dest")"
    { printf 'REDIS0009'; printf '%0.sx' $(seq 1 200); } > "$dest"
    echo "Successfully copied"
    ;;
  exec)
    case "$*" in
      *PING*)               if [ "${SHIM_MODE:-one}" = "pingfail" ]; then :; else echo PONG; fi ;;
      *BGSAVE*)             echo "Background saving started" ;;
      *LASTSAVE*)           echo 1700000000 ;;
      *"INFO persistence"*) echo "rdb_bgsave_in_progress:0" ;;
      *GRAPH.LIST*)         printf 'tortoise\ntest_proj125_alpha\n' ;;
      *GRAPH.QUERY*)
        graph=""; prev=""
        for a in "$@"; do [ "$prev" = "GRAPH.QUERY" ] && graph="$a"; prev="$a"; done
        if [ "${SHIM_MODE:-one}" = "lowcount" ]; then
          echo 1
        elif [ "$graph" = "tortoise" ]; then
          echo 1263
        else
          echo 42
        fi ;;
      *"stat -c%s"*)        echo 4096 ;;
      *) echo "shim: unhandled exec: $*" >&2; exit 90 ;;
    esac
    ;;
  *)
    echo "shim: unhandled subcommand: $sub" >&2
    exit 90
    ;;
esac
SHIM
chmod +x "$BIN/docker"

SHIM_LOG="$T/docker.log"
OUT=""
RC=0
CASE=""
FAKE_HOME=""
RUN_REPO=""
# Passed to the script as a bare env assignment (EXTRA_ENV="CONTAINER=name"). Kept as one
# unquoted word on purpose: every value this suite uses is whitespace-free.
EXTRA_ENV=""

# Each case gets its OWN home + own repo root, so a case can assert "nothing was written"
# without another case's artifacts in the way.
new_case() {
  CASE="$1"
  FAKE_HOME="$T/home-$CASE"
  RUN_REPO="$T/repo-$CASE"
  mkdir -p "$FAKE_HOME" "$RUN_REPO/scripts"
  cp "$SRC" "$RUN_REPO/scripts/daily-backup.sh"
  EXTRA_ENV=""
  : > "$SHIM_LOG"
}

run_backup() {   # run_backup <shim-mode> [script args...]
  local mode="$1"; shift
  : > "$SHIM_LOG"
  RC=0
  OUT="$( cd "$RUN_REPO" && env HOME="$FAKE_HOME" PATH="$BIN:$PATH" SHIM_MODE="$mode" SHIM_LOG="$SHIM_LOG" \
      LOAD_GATE_FORCE=1 ${EXTRA_ENV} bash scripts/daily-backup.sh "$@" 2>&1 )" || RC=$?
}

local_backups() { local n=0 d; for d in "$RUN_REPO"/backups/*/; do [ -d "$d" ] && n=$((n + 1)); done; echo "$n"; }
offbox_backups() { local n=0 d; for d in "$FAKE_HOME"/backups/tortoise/*/; do [ -d "$d" ] && n=$((n + 1)); done; echo "$n"; }
only_local_backup() { ls -1d "$RUN_REPO"/backups/*/ 2>/dev/null | head -1; }

echo "── the target is RESOLVED from the published port, and used ──────────────"
new_case resolve
run_backup one
assert_eq "$RC" "0" "happy path exits 0"
assert_not_contains "$OUT" "unbound variable" "the LOAD_GATE_FORCE=1 path runs (a bypass that aborts is not a bypass)"
assert_contains "$OUT" "Backup complete" "summary printed"
assert_eq "$(local_backups)" "1" "exactly one local backup directory"
BD="$(only_local_backup)"
exists "${BD}dump.rdb" "dump.rdb written"
exists "${BD}manifest.json" "manifest.json written"
assert_contains "$(cat "${BD}manifest.json" 2>/dev/null)" '"container": "falkordb-16379"' "manifest records the RESOLVED container"
assert_contains "$(cat "${BD}manifest.json" 2>/dev/null)" '"redis_host_port": "16379"' "manifest records the port that resolved it"
assert_contains "$(cat "${BD}manifest.json" 2>/dev/null)" '"total_points": 1305' "manifest counts points (1263 + 42)"
assert_eq "$(offbox_backups)" "1" "off-box copy made"
exists "$FAKE_HOME/backups/tortoise/$(basename "$BD")/dump.rdb" "off-box copy holds the RDB"
assert_contains "$(cat "$SHIM_LOG")" "exec falkordb-16379 redis-cli -p 6379 BGSAVE" "BGSAVE addressed the RESOLVED container"
assert_not_contains "$(cat "$SHIM_LOG")" "falkordb-personal" "no call ever names the drifted literal (#907)"

echo "── a port with NO publisher is a loud refusal that writes NOTHING ────────"
new_case nopublisher
run_backup none
assert_eq "$RC" "1" "no publisher exits 1"
assert_contains "$OUT" "no running container publishes host port 16379" "diagnostic names the port"
assert_eq "$(local_backups)" "0" "no local backup directory created"
absent "$FAKE_HOME/backups/tortoise" "off-box root not even created"
assert_not_contains "$(cat "$SHIM_LOG")" "BGSAVE" "BGSAVE never dispatched"

echo "── >1 publisher on the port is AMBIGUOUS (the ::1 decoy class), not a coin flip ──"
new_case ambiguous
run_backup two
assert_eq "$RC" "1" "two publishers exit 1"
assert_contains "$OUT" "2 containers publish host port 16379" "diagnostic counts the candidates"
assert_contains "$OUT" "falkordb-16379" "diagnostic names candidate 1"
assert_contains "$OUT" "falkordb-decoy" "diagnostic names candidate 2"
assert_contains "$OUT" "CONTAINER=" "diagnostic points at the override"
assert_eq "$(local_backups)" "0" "no local backup directory created"
assert_eq "$(offbox_backups)" "0" "no off-box backup directory created"
assert_not_contains "$(cat "$SHIM_LOG")" "BGSAVE" "BGSAVE never dispatched"

echo "── CONTAINER=<name> still overrides resolution ───────────────────────────"
new_case override
EXTRA_ENV="CONTAINER=fdb-pinned"
run_backup none
assert_eq "$RC" "0" "override runs even with no publisher on the port"
assert_contains "$(cat "$SHIM_LOG")" "exec fdb-pinned redis-cli -p 6379 BGSAVE" "BGSAVE addressed the OVERRIDE container"
assert_contains "$(cat "$(only_local_backup)manifest.json" 2>/dev/null)" '"container": "fdb-pinned"' "manifest records the OVERRIDE container"

echo "── an unverifiable target is refused BEFORE any state exists ─────────────"
new_case pingfail
run_backup pingfail
assert_eq "$RC" "1" "a container that never answers PING exits 1"
assert_contains "$OUT" "did not answer PING on port 6379" "diagnostic names the failed probe"
assert_eq "$(local_backups)" "0" "no local backup directory created"
absent "$FAKE_HOME/backups/tortoise" "off-box root not even created"
assert_not_contains "$(cat "$SHIM_LOG")" "BGSAVE" "BGSAVE never dispatched"

new_case stopped
EXTRA_ENV="CONTAINER=fdb-pinned"
run_backup stopped
assert_eq "$RC" "1" "a container that is not running exits 1"
assert_contains "$OUT" "is not a running Docker container" "diagnostic names the container state"
assert_eq "$(local_backups)" "0" "no local backup directory created"

echo "── a failure leaves no INCOMPLETE backup behind (the trap) ───────────────"
new_case partial
run_backup cpfail
assert_eq "$RC" "1" "a failed RDB copy exits 1"
assert_eq "$(local_backups)" "0" "the incomplete local directory was removed"
assert_eq "$(offbox_backups)" "0" "no incomplete off-box directory was left"

echo "── an exit-2 artifact is KEPT (it carries its manifest) ─────────────────"
new_case lowcount
run_backup lowcount
assert_eq "$RC" "2" "suspiciously low point count exits 2"
assert_eq "$(local_backups)" "1" "the exit-2 artifact is kept, not deleted by the trap"
assert_contains "$OUT" "suspiciously low" "diagnostic warns about the low count"

echo "── --keep still validates ───────────────────────────────────────────────"
new_case badkeep
run_backup one --keep abc
assert_eq "$RC" "1" "--keep with a non-integer exits 1"
assert_contains "$OUT" "must be a positive integer" "diagnostic is the usage error"
assert_eq "$(local_backups)" "0" "nothing written"

echo "── the shipped .gitignore covers the backup root ─────────────────────────"
GITPROBE="$T/gitignore-probe"
mkdir -p "$GITPROBE/backups"
cp "$REPO_ROOT/.gitignore" "$GITPROBE/"
if git -C "$GITPROBE" init -q >/dev/null 2>&1; then
  # A trailing-slash rule matches DIRECTORIES only, so the probe path must exist as one.
  if git -C "$GITPROBE" check-ignore -q backups/dump.rdb 2>/dev/null; then
    ok "the backup root is gitignored (an RDB dump can never be committed)"
  else
    bad "the backup root is NOT gitignored"
  fi
  if git -C "$GITPROBE" check-ignore -q scripts/daily-backup.sh 2>/dev/null; then
    bad "the .gitignore is a blanket rule (it also ignores source)"
  else
    ok "the .gitignore is not a blanket rule (source is not ignored)"
  fi
else
  bad "git init failed — the .gitignore rule could not be verified"
fi

echo "── restore-smoke.sh picks the newest RESTORABLE backup ───────────────────"
# The function is extracted from the SHIPPED file (never re-implemented here), so the test
# cannot drift from the guard it is testing.
SEL_SH="$T/newest_backup_dir.sh"
sed -n '/^newest_backup_dir() {$/,/^}$/p' "$SRC_SMOKE" > "$SEL_SH"
if [ -s "$SEL_SH" ]; then
  ok "newest_backup_dir extracted from scripts/restore-smoke.sh"
  # shellcheck disable=SC1090
  source "$SEL_SH"
  ROOT="$T/sel"
  mkdir -p "$ROOT/20260101T000000Z" "$ROOT/20261016T213639Z" "$ROOT/20251231T000000Z"
  printf 'REDIS0009' > "$ROOT/20251231T000000Z/dump.rdb"
  printf 'REDIS0009' > "$ROOT/20260101T000000Z/dump.rdb"
  touch -t 202512310000 "$ROOT/20251231T000000Z"
  touch -t 202601010000 "$ROOT/20260101T000000Z"
  touch -t 202610162136 "$ROOT/20261016T213639Z"   # newest, and EMPTY — the #907 shape
  assert_eq "$(basename "$(newest_backup_dir "$ROOT")")" "20260101T000000Z" "an empty newest dir is skipped for the newest one that holds dump.rdb"
  mkdir -p "$T/only-empty/20261016T213639Z"
  if newest_backup_dir "$T/only-empty" >/dev/null 2>&1; then
    bad "a root holding no complete backup must not resolve"
  else
    ok "a root holding no complete backup does not resolve"
  fi
  if newest_backup_dir "$T/does-not-exist" >/dev/null 2>&1; then
    bad "a missing root must not resolve"
  else
    ok "a missing root does not resolve"
  fi
  printf 'REDIS0009' > "$ROOT/20261016T213639Z/dump.rdb"
  assert_eq "$(basename "$(newest_backup_dir "$ROOT")")" "20261016T213639Z" "with both complete, the newest complete one wins"
else
  bad "newest_backup_dir could not be extracted from scripts/restore-smoke.sh"
fi

echo ""
echo "───────────────────────────────────────────────────────────────────"
echo "daily-backup: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
echo "✅ all assertions passed"
