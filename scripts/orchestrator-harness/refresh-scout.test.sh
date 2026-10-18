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

# mk_gh_wrapper <case-dir> — present a stub's answer in the shape `gh api -i` REALLY produces (#1962).
# The shipped helper reads response HEADERS (`Link`, which is how it tells "the collection ended on a
# page boundary" from "the body vanished") as well as the body, so a stub that printed a bare JSON
# array would exercise nothing: the helper would split at a separator that is not there and read an
# empty body — measured, every listing came back with 0 rows. The case-specific answer stays in
# `gh.body`, untouched; this wrapper only adds the header block and passes stdout/stderr/rc through.
mk_gh_wrapper() {
  cat > "$1/bin/gh" <<'SH'
#!/bin/bash
d="$(cd "$(dirname "$0")" && pwd)"
if [ "$1" = api ] && [ "$2" = -i ]; then
  shift 2
  out="$("$d/gh.body" api "$@" 2>"$d/.gh.err")"; rc=$?
  [ -s "$d/.gh.err" ] && cat "$d/.gh.err" >&2
  rm -f "$d/.gh.err"
  [ "$rc" -eq 0 ] || exit "$rc"
  # An EMPTY answer emits headers and NO body — exactly what a 204 looks like. Appending a newline to
  # an empty answer would make a 1-byte body that the helper must read as "not a JSON array".
  if [ -n "$out" ]; then
    printf 'HTTP/2.0 200 OK\r\ncontent-type: application/json\r\n\r\n%s\n' "$out"
  else
    printf 'HTTP/2.0 204 No Content\r\ncontent-type: application/json\r\n\r\n'
  fi
  exit 0
fi
exec "$d/gh.body" "$@"
SH
  chmod +x "$1/bin/gh"
}

# mk_case <name> — a sandbox whose scout worktree already EXISTS as a plain dir (so the shipped
# script skips `git worktree add` and does not need a repo/remote). Sets $D.
D=""
mk_case() {
  D="$T/$1"; mkdir -p "$D/home" "$D/bin" "$D/o" "$D/repo/.worktrees/dispatch-scout"
  # `gh` succeeds and lists NOTHING: the reaper then sees a readable, empty answer (which it is
  # entitled to reap against) and the pool comes out empty unless a case stubs otherwise.
  printf '#!/bin/bash\nexit 0\n' > "$D/bin/gh.body"; chmod +x "$D/bin/gh.body"
  mk_gh_wrapper "$D"
  # ── a REAL git repo with a REAL (local, bare) origin, and the running registry (agent-infra#1850) ─
  # The pre-flight now reads `refs/claims/*` from the TARGET repo's origin before it certifies an
  # issue CLEAN, so the sandbox has to be a repo with an origin or every case would take the
  # "registry not installed" fallback and the gate below would never be exercised. The origin is a
  # bare dir in the sandbox: real git semantics (refs, fetch, ls-remote exit codes) and no network.
  # `$D/o/claims.sh` is the RUNNING copy — install.sh seeds it into $O — so the gate reads the same
  # file the daemon would.
  git init -q --bare "$D/origin.git"
  git init -q "$D/repo"
  git -C "$D/repo" remote add origin "$D/origin.git"
  cp "$HERE/claims.sh" "$D/o/claims.sh"
}
# mk_issue_claim <dir> <issue> <lease-seconds-from-now> — push a live issue claim to the sandbox
# origin, minted by the SHIPPED claims.sh (so the sandbox cannot drift from the real claim format).
# ⛔ NOT `CLAIM_REPO=… . claims.sh`: a variable assignment PREFIXING the `.` builtin is a TEMPORARY
# environment for that one command and bash RESTORES the variable afterwards, so the functions the
# sourced file defined see CLAIM_REPO UNSET — `_git` then dies with `CLAIM_REPO: unbound variable`
# under `set -u`, `_claim_commit` returns empty (its stderr is swallowed), and an empty commit in a
# `"$c:refs/…"` refspec is a DELETE, not a create. Assign in a SEPARATE statement.
mk_issue_claim() {
  local d="$1" n="$2" ttl="$3" c
  c="$( cd "$d/repo" || exit 1
        CLAIM_REPO="$d/repo"; CLAIM_OWNER_ID=peerbox; export CLAIM_REPO CLAIM_OWNER_ID
        . "$HERE/claims.sh"
        _claim_commit peerbox "$(( $(date +%s) + ttl ))" )"
  [ -n "$c" ] || return 1
  git -C "$d/repo" push -q origin "$c:refs/claims/issue-$n"
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
  OUT="$(env -u TORTOISE_REPO -u TORTOISE -u SCOUT_UV -u GH_HOST -u CELL_HOME -u SCOUT_PY \
          -u SCOUT_UV_EXTRAS -u GH_CONFIG_DIR \
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
# mk_gh_rest <case-dir> [issue-number] — the `gh` stub the SHIPPED refresh now talks to (#1962).
#   * The listings are REST: `gh api repos/…/issues…` / `…/pulls…` answer with REST objects, because
#     that is what the shipped script asks for. The GraphQL VERB forms (`gh issue list`, `gh pr list`)
#     are REFUSED with the cell's own message — a stub that still answered those would pass on the
#     PRE-FIX script too, so it could not tell the two transports apart at all.
#   * <issue-number> puts ONE unassigned, non-epic P0-blocker row in the pool; with no argument the
#     pool is genuinely EMPTY (a readable answer, not a failed read).
#   * `auth token` answers (a credential is stored) and `gh api rate_limit` reports a HEALTHY REST
#     bucket against a STARVED GraphQL one — the exact asymmetry the fix exists for.
mk_gh_rest() {
  local d="$1" n="${2:-}" rows='[]'
  [ -n "$n" ] && rows="[{\"number\":$n,\"title\":\"a pool candidate\",\"assignees\":[]}]"
  cat > "$d/bin/gh.body" <<SH
#!/bin/bash
case "\$1 \$2" in
  "auth token") exit 0 ;;
  *" rate_limit"*) printf '%s\n' '{"resources":{"core":{"remaining":4321},"graphql":{"remaining":0}}}' ;;
  *"/pulls?"*) printf '[]\n' ;;                 # the reaper's branch list: readable, none
  *"labels=P0-blocker"*) printf '%s\n' '$rows' ;;
  *"/issues?"*) printf '[]\n' ;;
  *) case "\$*" in
       "issue list"*|'pr list'*) echo 'GraphQL: API rate limit already exceeded for user ID 81560491.' >&2; exit 1 ;;
     esac
     printf '[]\n' ;;
esac
SH
  # ⛔ THE FILE JUST WRITTEN IS `gh.body`, NOT `gh` (review, measured): `chmod +x "$d/bin/gh"` here is
  # a no-op on a file `mk_gh_wrapper` immediately OVERWRITES (and then chmods itself), so the stub
  # escaped only by inheriting `mk_case`'s mode through `cat >`.
  chmod +x "$d/bin/gh.body"
  mk_gh_wrapper "$1"
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
# mk_home_tool <path> — a pre-flight stand-in that answers CLEAN and RECORDS the HOME it ran under
# ($HOMELOG). "Which home did the pre-flight actually see?" is a property of the environment, and a
# suite that only inspects the script's own text cannot answer it.
mk_home_tool() {
  mkdir -p "$(dirname "$1")"
  cat > "$1" <<'PY'
#!/usr/bin/env python3
import os
if os.environ.get("HOMELOG"):
    with open(os.environ["HOMELOG"], "a") as fh:
        fh.write("%s\n" % os.environ.get("HOME", ""))
print("VERDICT: CLEAN")
PY
  chmod +x "$1"
}
# mk_gh_noauth <case-dir> — a `gh` that answers the pool queries but is NOT authenticated. The
# gh-backed ISSUE/PR surfaces DECIDE a verdict; the git-read branches/worktrees are BLOCKING (a ref
# naming the issue forces a COLLISION) and the local-branch terminal lookup is itself a gh call that
# fails closed — so an unauthenticated gh is the environment the live cells actually had
# (measured 2026-10-16: `gh auth status` fails under HOME=/home/ubuntu and succeeds under
# HOME=/tmp/cell-home, on the same cell).
mk_gh_noauth() {
  cat > "$1/bin/gh.body" <<'SH'
#!/bin/bash
case "$*" in
  "auth status") echo "To get started with GitHub CLI, please run: gh auth login" >&2; exit 1 ;;
  "auth token") echo "no oauth token found for github.com" >&2; exit 1 ;;
esac
# #1962: the pool query is a REST call now, so the row is answered on the REST URL.
case "$*" in *"labels=P0-blocker"*) printf '[{"number":42,"title":"a pool candidate","assignees":[]}]\n' ;; esac
exit 0
SH
  chmod +x "$1/bin/gh"
  mk_gh_wrapper "$1"
}
# mk_gh_stale_token <case-dir> — a gh with a STORED-BUT-UNVALIDATABLE credential: `auth status`
# exits 1 with the REAL output gh 2.97.0 prints behind a dead proxy (measured: `HTTPS_PROXY=
# http://127.0.0.1:1 gh auth status --hostname github.com` → "The token in ~/.config/gh/hosts.yml is
# invalid."), while `auth token` — an OFFLINE lookup of the stored credential — succeeds, and the API
# call fails with the SAME transport error (no HTTP status). This is the TRANSIENT case: the prose is
# exactly what a rejected credential prints, so a text-match discriminator cannot tell them apart —
# only the API's own answer can, and an unreachable API answers with no status at all.
mk_gh_stale_token() {
  cat > "$1/bin/gh.body" <<'SH'
#!/bin/bash
case "$*" in
  "auth status")
    cat >&2 <<'EOM'
  X Failed to log in to github.com account nobody (~/.config/gh/hosts.yml)
  - Active account: true
  - The token in ~/.config/gh/hosts.yml is invalid.
EOM
    exit 1 ;;
  "auth token") exit 0 ;; # OFFLINE lookup succeeds: a credential IS stored
  *"api "*) echo 'Get "https://api.github.com/rate_limit": proxyconnect tcp: dial tcp 127.0.0.1:1: connect: connection refused' >&2; exit 1 ;;
esac
case "$*" in *"labels=P0-blocker"*) printf '[{"number":42,"title":"a pool candidate","assignees":[]}]\n' ;; esac
exit 0
SH
  chmod +x "$1/bin/gh"
  mk_gh_wrapper "$1"
}
# mk_gh_rejected <case-dir> — a gh with a STORED-BUT-REJECTED credential: `auth status` exits 1 with
# the SAME prose a dead proxy prints (so a prose matcher cannot tell them apart), `auth token` — an
# OFFLINE lookup — SUCCEEDS, and the ONLY thing separating it from an outage is the API's own answer:
# `gh api … rate_limit` prints `gh: Bad credentials (HTTP 401)` and exits 1 (measured on gh 2.97.0).
# A rejected credential is permanent — a retry cannot change it — so it MUST latch the marker rather
# than stay a silent transient, which is how a cell stays MERGE-ONLY while reporting RUNNING (#1736).
mk_gh_rejected() {
  cat > "$1/bin/gh.body" <<'SH'
#!/bin/bash
case "$*" in
  "auth status")
    cat >&2 <<'EOM'
  X Failed to log in to github.com account nobody (~/.config/gh/hosts.yml)
  - Active account: true
  - The token in ~/.config/gh/hosts.yml is invalid.
EOM
    exit 1 ;;
  "auth token") exit 0 ;; # OFFLINE lookup succeeds: a credential IS stored
  *"api "*) echo 'gh: Bad credentials (HTTP 401)' >&2; exit 1 ;;
esac
case "$*" in *"labels=P0-blocker"*) printf '[{"number":42,"title":"a pool candidate","assignees":[]}]\n' ;; esac
exit 0
SH
  chmod +x "$1/bin/gh"
  mk_gh_wrapper "$1"
}
# mk_degraded_tool <path> — what the REAL pre-flight answers when its gh surfaces are unreadable:
# `VERDICT: COLLISION` (measured on the cells — a LANDED issue came back as a COLLISION under
# HOME=/home/ubuntu). The caller cannot tell that apart from a real collision, which is the whole
# reason an unreadable environment has to be refused BEFORE the tool is asked. Records argv.
mk_degraded_tool() {
  mkdir -p "$(dirname "$1")"
  cat > "$1" <<'PY'
#!/usr/bin/env python3
import os, sys
if os.environ.get("TOOL_LOG"):
    with open(os.environ["TOOL_LOG"], "a") as fh:
        fh.write("%s|%s\n" % (os.getcwd(), " ".join(sys.argv[1:])))
print("VERDICT: COLLISION")
PY
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

# ── 1c) `--check` must REFUSE a box with NO jq (agent-infra#1962) ────────────────────────────────
# The listings are assembled with jq, so its absence is PERMANENT and LOCAL: `--check` used to print
# CHECK OK, cloud-cell-bringup.sh started the cell, and every refresh then reported
# `queue=UNREADABLE` forever — the "a cell that can only merge, and looks healthy" shape this check
# exists to refuse. One of the two guards this change added that had no assertion at all (measured:
# deleting it left the suite GREEN (measured), which is why the case exists).
# ⛔ DRIVEN AS AN EXTRACTED BLOCK, NOT through `--check`, because a fixture CANNOT build a jq-less
# box for the shipped entrypoint: the script re-appends `/opt/homebrew/bin:/usr/local/bin` to
# whatever PATH it is given (refresh-candidates.sh:88), and on a Homebrew Mac that is where jq lives.
# The two host-shaped alternatives were measured and BOTH fail: a PATH farm plus the raw `/bin` finds
# `/bin/jq` on any usrmerged distro (`/bin -> usr/bin`, so the exclusion is defeated by the second
# segment and the CI runner is RED), and a farm alone is still outranked by the appended dirs. The
# `uv` lens already paid for this exact trap — see SCOUT_UV / agent-infra#1748 just above. The block
# below is the shipped guard VERBATIM, so deleting the guard fails this case; a missing extraction is
# a FAILURE, never a skip.
# ⛔ THE END ANCHOR IS THE *NEXT SECTION*, not the guard's own output line: an anchor inside the
# block makes a harmless reword of that line run the extraction to EOF, where `command -v jq` matches
# `rest_list`'s own probe far below — the "guard present" branch then executes the whole script and
# the case fails for a reason that has nothing to do with jq (measured: 3 red assertions reading
# `MODE: unbound variable`). The independent marker cannot be moved by editing the guard, the size
# bound refuses an over-run, and the discriminator is the guard's own verdict text.
awk '/^  # ⛔ jq IS A PREREQUISITE OF THE LISTING READ/{f=1} f{print} f&&/^  # ── the CROSS-BOX CLAIM REGISTRY/{exit}' "$REFRESH" \
  | sed '$d' > "$T/jqguard.sh"
if [ -s "$T/jqguard.sh" ] && [ "$(wc -l < "$T/jqguard.sh")" -le 20 ] \
   && grep -q 'NOT PROVISIONABLE' "$T/jqguard.sh"; then
  # A wrapper, because the block ends in `return` and names the script's own exit code.
  { printf 'set -u\nEXIT_NOT_PROVISIONABLE=3\ncmd_check_jq() {\n'; cat "$T/jqguard.sh"; printf '}\ncmd_check_jq\n'; } > "$T/jqguard-run.sh"
  # An EMPTY PATH dir: `command -v jq` is unsatisfiable for real, with nothing host-dependent in it.
  # bash itself is invoked by absolute path, so an empty PATH cannot stop the driver running.
  NOJQ="$T/nojq-path"; mkdir -p "$NOJQ"
  OUTJ="$(PATH="$NOJQ" "$(command -v bash)" "$T/jqguard-run.sh" 2>&1)"; rcj=$?
  [ "$rcj" -eq 3 ] && ok "--check: a box WITHOUT jq is REFUSED by the guard (rc=3, not the transient retry code)" \
                  || bad "--check: the jq guard returned rc=$rcj (want 3) on a jq-less PATH — output: $OUTJ"
  case "$OUTJ" in
    *"NOT PROVISIONABLE"*jq*) ok "--check: the no-jq refusal is NOT PROVISIONABLE and names jq" ;;
    *) bad "--check: no NOT-PROVISIONABLE/jq verdict on a box with no jq — output: $OUTJ" ;;
  esac
  case "$OUTJ" in
    *"install jq"*) ok "--check: the no-jq refusal prescribes the fix (install jq)" ;;
    *) bad "--check: the no-jq refusal names no remedy — output: $OUTJ" ;;
  esac
  # ⛔ A jq THAT RESOLVES BUT DOES NOT RUN IS REFUSED TOO (#1962 review, MEASURED). The probe is by
  # EXECUTION, so a passing `command -v` is not a verdict: driven here with a jq that exits 1 — the
  # shape of a shim whose tool is missing (exit 127) or a wrong-architecture binary. This case exists
  # because the PRESENCE form read green against exactly this fixture: it printed `CHECK OK` rc=0 and
  # the helper then refused every page. Reverting the probe to `command -v` fails THIS assertion and
  # leaves the no-jq case above green, so the two cases pin different questions.
  BJ="$T/jqbroken"; mkdir -p "$BJ"
  printf '#!/bin/bash\nexit 1\n' > "$BJ/jq"; chmod +x "$BJ/jq"
  OUTB="$(PATH="$BJ" "$(command -v bash)" "$T/jqguard-run.sh" 2>&1)"; rcb=$?
  [ "$rcb" -eq 3 ] && ok "--check: a jq that RESOLVES but cannot RUN is REFUSED (rc=3, not a transient retry) — the probe is by execution, not presence" \
                  || bad "--check: a jq that cannot run returned rc=$rcb (want 3) — output: $OUTB"
else
  bad "the --check jq guard could not be extracted from the shipped refresh-candidates.sh (deleted, or its anchor moved)"
fi
# (run) the same interpreter on the refresh path must be PERMANENT (rc=3), so orch-loop.sh writes
# the merge-only marker instead of the script exiting 0 with an empty backlog.
mk_case old-python-run
mk_tool "$D/repo/.worktrees/dispatch-scout/tools/collision_preflight.py"
mk_old_python "$D/bin/oldpy"
# Seed a sentinel so "nothing queued" is DISCRIMINATING — an empty file cannot distinguish "nothing
# was queued" from "the backlog was clobbered" (the pattern used by the LANDED case below).
echo 99 > "$D/o/candidates.txt"
rf "$D" refresh SCOUT_PY="$D/bin/oldpy"
[ "$RC" -eq 3 ] && ok "old interpreter (run): rc=3 (PERMANENT — a marker, not a silent 0)" \
               || bad "old interpreter (run): rc=$RC (want 3) — output: $OUT"
case "$OUT" in
  *"NOT PROVISIONABLE"*) ok "old interpreter (run): the refusal is LOUD and named" ;;
  *) bad "old interpreter (run): no NOT PROVISIONABLE verdict — output: $OUT" ;;
esac
case "$(tr '\n' ' ' < "$D/o/candidates.txt" 2>/dev/null)" in
  *42*) bad "old interpreter (run): queued candidates — $(cat "$D/o/candidates.txt" 2>/dev/null)" ;;
  *99*) ok "old interpreter (run): nothing is queued (seed 99 intact, #42 absent)" ;;
  *) bad "old interpreter (run): the backlog was clobbered — candidates='$(cat "$D/o/candidates.txt" 2>/dev/null)'" ;;
esac

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
cat > "$D/bin/gh.body" <<'SH'
#!/bin/bash
case "$*" in *"labels=P0-blocker"*) printf '[{"number":42,"title":"a pool candidate","assignees":[]}]\n' ;; esac
exit 0
SH
chmod +x "$D/bin/gh"
# Seed a sentinel so "nothing queued" is DISCRIMINATING (see the LANDED case below).
echo 99 > "$D/o/candidates.txt"
rf "$D" refresh
[ "$RC" -eq 3 ] && ok "pre-flight exits 3 (no VERDICT): the refresh is PERMANENT rc=3, not a silent 0" \
               || bad "pre-flight exits 3: rc=$RC (want 3) — output: $OUT"
case "$OUT" in
  *"NOT PROVISIONABLE"*) ok "pre-flight exits 3: the refusal is LOUD and named" ;;
  *) bad "pre-flight exits 3: no NOT PROVISIONABLE verdict — output: $OUT" ;;
esac
case "$(tr '\n' ' ' < "$D/o/candidates.txt" 2>/dev/null)" in
  *42*) bad "pre-flight exits 3: queued candidates — $(cat "$D/o/candidates.txt" 2>/dev/null)" ;;
  *99*) ok "pre-flight exits 3: nothing is queued (seed 99 intact, #42 absent)" ;;
  *) bad "pre-flight exits 3: the backlog was clobbered — candidates='$(cat "$D/o/candidates.txt" 2>/dev/null)'" ;;
esac

# ── 1d) THE PRE-FLIGHT'S ENVIRONMENT IS A PRECONDITION, NOT A PER-CANDIDATE RESULT ─────────────
# The measured defect (2026-10-16, live cells). `cloud-cell-bringup.sh` documents friction #1
# (`cmux vm exec` runs as user `cmux` with HOME=/home/ubuntu, which is NOT created on the image) and
# repairs it IN ITS OWN PROCESS — a repair that cannot cross a process boundary, in a cell whose
# controller is not always started by bring-up. The refresh is what actually runs the pre-flight, so
# the repair belongs here too. Two failures are pinned below, each of which the pre-fix script
# absorbs silently:
#   (1) an UNUSABLE HOME  -> gh is unauthenticated there ($HOME/.config/gh), so the tool answers from
#                            partial evidence: measured on the cells, `VERDICT: COLLISION` ("a peer
#                            owns it") for an issue whose true verdict was `LANDED`. A collision is
#                            an ordinary answer, so the cell logs 309 collisions, ZERO clean verdicts,
#                            an empty backlog and `lanes: 0` — for ever, while reporting RUNNING.
#   (2) gh NOT AUTHENTICATED -> the same degradation, one layer in.
# Both cases fail on the PRE-FIX code for the right reason: it runs the tool anyway and reports an
# empty backlog as a healthy result.
echo; echo "── an unusable HOME is repaired by the refresh itself (the pre-flight's real precondition) ──"
mk_case home-unusable
mk_home_tool "$D/repo/.worktrees/dispatch-scout/tools/collision_preflight.py"
printf '#!/bin/bash\ncase "$*" in *"labels=P0-blocker"*) printf "[{\\"number\\":42,\\"title\\":\\"a pool candidate\\",\\"assignees\\":[]}]\\n" ;; esac\nexit 0\n' > "$D/bin/gh.body"
chmod +x "$D/bin/gh"
rf "$D" refresh HOME="$D/no-such-home" CELL_HOME="$D/cellhome" HOMELOG="$D/homelog"
[ "$RC" -eq 0 ] && ok "unusable HOME: the refresh still proceeds (rc=0)" \
                || bad "unusable HOME: rc=$RC — output: $OUT"
case "$OUT" in
  *"is not a writable directory"*) ok "unusable HOME: the substitution is NAMED, not silent" ;;
  *) bad "unusable HOME: no substitution reported — output: $OUT" ;;
esac
[ -d "$D/cellhome" ] && ok "unusable HOME: the cell home was created (self-heal)" \
                     || bad "unusable HOME: the cell home was never created"
[ "$(cat "$D/homelog" 2>/dev/null)" = "$D/cellhome" ] \
  && ok "unusable HOME: the pre-flight RAN under the writable home (HOME=$D/cellhome)" \
  || bad "unusable HOME: the pre-flight ran under '$(cat "$D/homelog" 2>/dev/null)' — a verdict from an unusable HOME is the defect"

# The other direction, so the repair cannot silently move a HOME that works: a writable HOME is used
# VERBATIM and no substitution is reported.
echo; echo "── a writable HOME is used verbatim (the repair is a no-op on a normal box) ──"
mk_case home-ok
mk_home_tool "$D/repo/.worktrees/dispatch-scout/tools/collision_preflight.py"
printf '#!/bin/bash\ncase "$*" in *"labels=P0-blocker"*) printf "[{\\"number\\":42,\\"title\\":\\"a pool candidate\\",\\"assignees\\":[]}]\\n" ;; esac\nexit 0\n' > "$D/bin/gh.body"
chmod +x "$D/bin/gh"
rf "$D" refresh HOMELOG="$D/homelog"
[ "$(cat "$D/homelog" 2>/dev/null)" = "$D/home" ] \
  && ok "writable HOME: the caller's HOME reached the tool unchanged" \
  || bad "writable HOME: the tool saw '$(cat "$D/homelog" 2>/dev/null)' instead of $D/home"
case "$OUT" in
  *"is not a writable directory"*) bad "writable HOME: a working HOME was reported as unusable" ;;
  *) ok "writable HOME: no substitution line" ;;
esac

echo; echo "── an unauthenticated gh REFUSES the pass instead of degrading every candidate ──"
mk_case gh-noauth
mk_degraded_tool "$D/repo/.worktrees/dispatch-scout/tools/collision_preflight.py"
mk_gh_noauth "$D"
# Seed a sentinel so "nothing queued" is DISCRIMINATING (see the LANDED case below).
echo 99 > "$D/o/candidates.txt"
rf "$D" refresh TOOL_LOG="$D/tool-log"
# The MEASURED symptom is not a crash: an unreadable environment makes every candidate read as
# "a peer owns it", which is an ordinary answer. Pre-fix this case exits 0 having queued nothing and
# having logged a COLLISION for #42 — indistinguishable from a busy queue on a healthy cell.
case "$OUT" in
  *"collision — a peer owns it"*) bad "gh unauthenticated: a DEGRADED collision was reported as a real verdict" ;;
  *) ok "gh unauthenticated: no degraded collision is passed off as a real verdict" ;;
esac
[ "$RC" -eq 3 ] && ok "gh unauthenticated: rc=3 (PERMANENT — a marker, not a silent 0)" \
               || bad "gh unauthenticated: rc=$RC (want 3) — output: $OUT"
case "$OUT" in
  *"NOT PROVISIONABLE"*) ok "gh unauthenticated: the refusal is LOUD and named" ;;
  *) bad "gh unauthenticated: no NOT PROVISIONABLE verdict — output: $OUT" ;;
esac
case "$OUT" in
  *"HOME=$D/home"*) ok "gh unauthenticated: the refusal names the HOME the pre-flight would use" ;;
  *) bad "gh unauthenticated: the refusal does not name HOME — output: $OUT" ;;
esac
[ ! -e "$D/tool-log" ] && ok "gh unauthenticated: refused BEFORE spending on the pre-flight" \
                       || bad "gh unauthenticated: the pre-flight ran anyway — $(cat "$D/tool-log" 2>/dev/null)"
case "$OUT" in
  *"checked "*"backlog now"*) bad "gh unauthenticated: still reported a healthy empty backlog" ;;
  *) ok "gh unauthenticated: no \"checked N; backlog now 0\" over an unjudged pool" ;;
esac
case "$(tr '\n' ' ' < "$D/o/candidates.txt" 2>/dev/null)" in
  *42*) bad "gh unauthenticated: queued candidates — $(cat "$D/o/candidates.txt" 2>/dev/null)" ;;
  *99*) ok "gh unauthenticated: nothing is queued (seed 99 intact, #42 absent)" ;;
  *) bad "gh unauthenticated: the backlog was clobbered — candidates='$(cat "$D/o/candidates.txt" 2>/dev/null)'" ;;
esac

# ── the host is READ from gh, never hardcoded ───────────────────────────────────────
# The pre-flight hands gh a host-LESS repo slug, so gh chooses the host, and the ONLY faithful probe
# is one that names none either. A stub is exactly the right instrument here: this one resolves the
# host the way gh does (GH_HOST, else the ONE configured host, else github.com — measured on gh
# 2.97.0) from the case's own hosts.yml, and refuses any call that names a different one. So the case
# fails the moment the script assumes a host: with a GHES-only config the pre-fix `--hostname
# github.com` finds no credential and latches the PERMANENT marker on an environment that can dispatch
# perfectly well (#1853 review). Reported already once: a `--json hosts`-derived host named the WRONG
# host for a two-GHES config and for a GHES config with GH_TOKEN set.
echo; echo "── the probe lets gh choose the host, rather than assuming github.com ──"
mk_case ghes-host
mk_tool "$D/repo/.worktrees/dispatch-scout/tools/collision_preflight.py"
mkdir -p "$D/home/.config/gh"
printf 'ghe.example.com:\n    oauth_token: x\n    user: n\n' > "$D/home/.config/gh/hosts.yml"
cat > "$D/bin/gh.body" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_LOG"
# This stub's own model of gh's default host: GH_HOST, else the ONE configured host, else github.com.
CFG="${GH_CONFIG_DIR:-$HOME/.config/gh}/hosts.yml"
HOST="${GH_HOST:-}"
if [ -z "$HOST" ]; then
  n=$(grep -cE '^[^[:space:]#][^:]*:' "$CFG" 2>/dev/null || true)
  if [ "${n:-0}" = 1 ]; then HOST=$(grep -E '^[^[:space:]#][^:]*:' "$CFG" | head -1 | tr -d ':')
  else HOST=github.com; fi
fi
# A call that NAMES a host must name the one gh resolves. (The shipped script must name none at all;
# this arm exists so the pre-fix `--hostname github.com` is refused here rather than silently accepted.)
case "$*" in
  *"--hostname "*) named="${*##*--hostname }"; named="${named%% *}"
    if [ "$named" != "$HOST" ]; then printf 'no oauth token found for %s\n' "$named" >&2; exit 1; fi ;;
esac
# Only the configured enterprise host is authenticated in this case.
[ "$HOST" = github.com ] && { printf 'no oauth token found for github.com\n' >&2; exit 1; }
# The listings are REST (#1962). Answer them from the same authenticated host — otherwise the pool
# read fails and this case would be measuring the POOL instead of the host probe it exists for.
case "$*" in *"repos/"*) printf '[]\n'; exit 0 ;; esac
printf '{"resources":{}}\n'
exit 0
SH
chmod +x "$D/bin/gh"
rf "$D" refresh GH_LOG="$D/gh-log"
[ "$RC" -eq 0 ] && ok "GHES host: a cell gh is configured for an enterprise host is NOT refused" \
               || bad "GHES host: rc=$RC (want 0) — the probe assumed a host — output: $OUT"
grep -q -- '--hostname' "$D/gh-log" 2>/dev/null \
  && bad "GHES host: the probe NAMED a host — gh must choose it — '$(tr '\n' ' ' < "$D/gh-log" 2>/dev/null)'" \
  || ok "GHES host: no host is named — gh resolves it, so the probe cannot disagree with the pre-flight"
grep -q 'auth token' "$D/gh-log" 2>/dev/null \
  && ok "GHES host: the credential question is asked of gh" \
  || bad "GHES host: gh was never asked for a credential — '$(tr '\n' ' ' < "$D/gh-log" 2>/dev/null)'"

# ── an unreadable pool listing is NOT an empty backlog ───────────────────────────────────────────
# Each pool query records its OWN failure, so the abort fires whether the pool came out empty or NOT.
# The partial case below is the one a mere emptiness test misses: one tier's query fails while another
# returns rows, leaving a non-empty pool that silently drops a whole priority tier — the #8465
# priority inversion. Both shapes must abort LOUDLY and TRANSIENTLY: nothing here knows which host
# would come back, and a marker only a human can clear must not be latched on a guess (#1853 review).
echo; echo "── an unreadable pool listing is not an empty backlog ──"
mk_case pool-unreadable
mk_tool "$D/repo/.worktrees/dispatch-scout/tools/collision_preflight.py"
cat > "$D/bin/gh.body" <<'SH'
#!/bin/bash
case "$*" in
  "auth token"*) exit 0 ;; # a credential IS stored
  # #1962: the listings are REST, so an unreadable HOST is modelled on `gh api`, not on the GraphQL
  # verb forms. A stub that failed `issue list` would leave every tier READ here and prove nothing.
  *"/issues?"*) echo 'gh: could not resolve host: ghe.example.com' >&2; exit 1 ;;
  *"repos/"*) printf '[]\n'; exit 0 ;;
esac
printf '{"resources":{}}\n'
exit 0
SH
chmod +x "$D/bin/gh"
rf "$D" refresh
[ "$RC" -eq 1 ] && ok "unreadable pool: rc=1 (TRANSIENT — the ambiguous case never latches the permanent marker)" \
               || bad "unreadable pool: rc=$RC (want 1) — output: $OUT"
case "$OUT" in
  *"candidate pool listing FAILED"*) ok "unreadable pool: the abort is LOUD and says the listing failed" ;;
  *) bad "unreadable pool: no refusal — output: $OUT" ;;
esac
case "$OUT" in
  *"P0-blocker"*) ok "unreadable pool: the abort names WHICH tier could not be read" ;;
  *) bad "unreadable pool: the abort does not name the tier — output: $OUT" ;;
esac
case "$OUT" in
  *"checked 0; backlog now"*) bad "unreadable pool: still reported a healthy empty backlog" ;;
  *) ok "unreadable pool: no \"checked N; backlog now 0\" over an unreadable pool" ;;
esac

# The PARTIAL shape: `.pool` is NON-EMPTY, so an emptiness test cannot see it.
echo; echo "── a PARTIALLY read pool is not a backlog (one tier failed, another returned rows) ──"
mk_case pool-partial
mk_tool "$D/repo/.worktrees/dispatch-scout/tools/collision_preflight.py"
cat > "$D/bin/gh.body" <<'SH'
#!/bin/bash
case "$*" in
  "auth token"*) exit 0 ;;
  # #1962: each tier is a REST call carrying its own `labels=` filter, so "one tier failed and another
  # answered" is modelled on the URL the shipped script actually requests.
  *"labels=P0-blocker"*) echo 'gh: jq: error (at <stdin>:1): cannot index string' >&2; exit 1 ;;
  *"labels=P1-severe"*) printf '[{"number":4242,"title":"a pool candidate","assignees":[]}]\n'; exit 0 ;;
  *"repos/"*) printf '[]\n'; exit 0 ;;
esac
printf '{"resources":{}}\n'
exit 0
SH
chmod +x "$D/bin/gh"
rf "$D" refresh
[ "$RC" -eq 1 ] && ok "partial pool: rc=1 (TRANSIENT — a missing tier is not a short backlog)" \
               || bad "partial pool: rc=$RC (want 1) — output: $OUT"
case "$OUT" in
  *"P0-blocker"*) ok "partial pool: the abort names the tier that failed" ;;
  *) bad "partial pool: the abort does not name the failing tier — output: $OUT" ;;
esac
case "$OUT" in
  *"backlog now 1"*|*"+#4242"*) bad "partial pool: acted on a pool it could not read — output: $OUT" ;;
  *) ok "partial pool: the readable tier's issue is NOT queued as if the pool were complete" ;;
esac

# ── THE POOL'S READ STATE: EMPTY, PARTIAL and UNREADABLE are three DIFFERENT readings ────────
# agent-infra#1931. The refusals above were already correct, but the LOG could not tell them apart:
# a cell whose pool listing failed refused on 131 consecutive passes and dispatched nothing while 15
# PRs sat open, and every cycle line still read `backlog=0` — the same line a fleet with nothing to
# do prints. A layer that cannot see must not report an empty queue, so each outcome is now a NAMED
# state, persisted (with the epoch of the read) for the controller's heartbeat line.
# ⛔ NOT ONE of these assertions can pass on the pre-fix script: there is no `queue=` token anywhere
# in its output, it persists no state file, and it reports a PARTIAL read with the identical sentence
# it uses for a TOTAL one — i.e. the distinction these tests exist for does not exist there.
echo; echo "── the pool read state: EMPTY vs PARTIAL vs UNREADABLE, and never EMPTY by accident ──"

# (a) NO tier could be read -> UNREADABLE, and explicitly NOT EMPTY.
mk_case state-unreadable
mk_tool "$D/repo/.worktrees/dispatch-scout/tools/collision_preflight.py"
cat > "$D/bin/gh.body" <<'SH'
#!/bin/bash
case "$*" in
  "auth token"*) exit 0 ;;
  *"/issues?"*) echo 'gh: API rate limit exceeded' >&2; exit 1 ;;
  *"repos/"*) printf '[]\n'; exit 0 ;;
esac
printf '{"resources":{}}\n'
exit 0
SH
chmod +x "$D/bin/gh"
rf "$D" refresh
[ "$RC" -eq 1 ] && ok "state/unreadable: refused TRANSIENT (rc=1) — a failed read is never a green 'nothing to do'" \
               || bad "state/unreadable: rc=$RC (want 1) — output: $OUT"
case "$OUT" in
  *"queue=UNREADABLE"*) ok "state/unreadable: the output SAYS queue=UNREADABLE" ;;
  *) bad "state/unreadable: the output never names the state — output: $OUT" ;;
esac
case "$OUT" in
  *"queue=EMPTY"*) bad "state/unreadable: a read that FAILED was reported as EMPTY — output: $OUT" ;;
  *) ok "state/unreadable: a failed read is NOT collapsed into EMPTY" ;;
esac
case "$(head -1 "$D/o/state/queue-state" 2>/dev/null)" in
  "UNREADABLE "*) ok "state/unreadable: the state is persisted for the heartbeat (state/queue-state)" ;;
  *) bad "state/unreadable: no state persisted — '$(head -1 "$D/o/state/queue-state" 2>/dev/null)'" ;;
esac

# (b) SOME tiers read, others not -> PARTIAL, naming what could not be read. It is a SUBSET, so it is
#     NOT the same reading as (a), and it still queues nothing.
mk_case state-partial
mk_tool "$D/repo/.worktrees/dispatch-scout/tools/collision_preflight.py"
cat > "$D/bin/gh.body" <<'SH'
#!/bin/bash
case "$*" in
  "auth token"*) exit 0 ;;
  *"labels=P0-blocker"*) echo 'gh: server error' >&2; exit 1 ;;
  *"labels=P1-severe"*) printf '[{"number":4242,"title":"a pool candidate","assignees":[]}]\n'; exit 0 ;;
  *"repos/"*) printf '[]\n'; exit 0 ;;
esac
printf '{"resources":{}}\n'
exit 0
SH
chmod +x "$D/bin/gh"
rf "$D" refresh
[ "$RC" -eq 1 ] && ok "state/partial: refused TRANSIENT (rc=1)" || bad "state/partial: rc=$RC (want 1) — output: $OUT"
case "$OUT" in
  *"queue=PARTIAL(P0-blocker)"*) ok "state/partial: the output names the state AND the tiers it could not read" ;;
  *) bad "state/partial: the state does not name the unread tiers — output: $OUT" ;;
esac
case "$OUT" in
  *"queue=UNREADABLE"*) bad "state/partial: a PARTIAL read was reported as UNREADABLE — the two are different readings" ;;
  *) ok "state/partial: PARTIAL is not collapsed into UNREADABLE" ;;
esac
case "$(head -1 "$D/o/state/queue-state" 2>/dev/null)" in
  "PARTIAL(P0-blocker) "*) ok "state/partial: the persisted state names the unread tiers too" ;;
  *) bad "state/partial: persisted '$(head -1 "$D/o/state/queue-state" 2>/dev/null)' (want PARTIAL(P0-blocker) <epoch>)" ;;
esac
case "$(tr '\n' ' ' < "$D/o/candidates.txt" 2>/dev/null)" in
  *4242*) bad "state/partial: queued a survivor of a partial read as if the pool were complete" ;;
  *) ok "state/partial: a partial read still queues NOTHING (#1736's rule, kept)" ;;
esac

# (c) EVERY tier read and genuinely empty -> EMPTY. This is the only answer that may mean "no work",
#     and it must still report the empty backlog (a successful empty read IS an empty backlog).
mk_case state-empty
mk_tool "$D/repo/.worktrees/dispatch-scout/tools/collision_preflight.py"
rf "$D" refresh     # the default gh stub answers every listing with nothing
[ "$RC" -eq 0 ] && ok "state/empty: a successful empty read succeeds (rc=0)" \
               || bad "state/empty: rc=$RC (want 0) — output: $OUT"
case "$OUT" in
  *"queue=EMPTY"*) ok "state/empty: a read that succeeded and listed nothing says queue=EMPTY" ;;
  *) bad "state/empty: EMPTY is never named — output: $OUT" ;;
esac
case "$OUT" in
  *"checked 0; backlog now 0"*) ok "state/empty: EMPTY may report an empty backlog (it measured one)" ;;
  *) bad "state/empty: the successful empty read lost its backlog report — output: $OUT" ;;
esac
case "$(head -1 "$D/o/state/queue-state" 2>/dev/null)" in
  "EMPTY "*) ok "state/empty: the persisted state is EMPTY" ;;
  *) bad "state/empty: persisted '$(head -1 "$D/o/state/queue-state" 2>/dev/null)'" ;;
esac

# (d) EVERY tier read and NON-empty -> READ(n). A third readable answer, so a non-empty pool can never
#     be labelled EMPTY by a later code path that only tests emptiness.
mk_case state-read
mk_tool "$D/repo/.worktrees/dispatch-scout/tools/collision_preflight.py"
cat > "$D/bin/gh.body" <<'SH'
#!/bin/bash
case "$*" in
  "auth token"*) exit 0 ;;
  *"labels=P1-severe"*) printf '[{"number":4242,"title":"a pool candidate","assignees":[]}]\n'; exit 0 ;;
  *"repos/"*) printf '[]\n'; exit 0 ;;
esac
printf '{"resources":{}}\n'
exit 0
SH
chmod +x "$D/bin/gh"
rf "$D" refresh
[ "$RC" -eq 0 ] && ok "state/read: a fully readable pool succeeds (rc=0)" || bad "state/read: rc=$RC (want 0) — output: $OUT"
case "$OUT" in
  *"queue=READ(1)"*) ok "state/read: a readable NON-empty pool is READ(n), not EMPTY" ;;
  *) bad "state/read: the readable non-empty pool is not named READ(n) — output: $OUT" ;;
esac
case "$OUT" in
  *"queue=EMPTY"*) bad "state/read: a non-empty pool was labelled EMPTY" ;;
  *) ok "state/read: a non-empty pool is never EMPTY" ;;
esac

# (e) THE HEARTBEAT CARRIES IT. The controller is where a human reads a cell's queue, so the cycle
#     line must carry the state — and the state must be READ BACK, with the age of the reading, by ONE
#     reader (a second vocabulary for the same fact is the defect this issue names). The shipped
#     reader is extracted and driven; a re-implementation would pass on a broken copy too.
echo; echo "── the heartbeat line carries the state (orch-loop.sh) ──"
awk '/^is_num\(\) \{/{print; exit}' "$LOOP" > "$T/isnum.sh"
awk '/^queue_state_token\(\) \{/{f=1} f{print} f&&/^}$/{exit}' "$LOOP" > "$T/qstate.sh"
if [ -s "$T/qstate.sh" ] && [ -s "$T/isnum.sh" ]; then
  ok "orch-loop: the pool-state reader is extractable from the shipped loop"
  QD="$T/qstate"; mkdir -p "$QD/state"
  # qs — the SHIPPED reader, over a state dir the case writes; no re-implementation of the format.
  qs() { ( O="$QD"; . "$T/isnum.sh"; . "$T/qstate.sh"; queue_state_token ); }
  rm -f "$QD/state/queue-state"
  [ "$(qs)" = "UNKNOWN" ] && ok "heartbeat: no recorded read is UNKNOWN — never EMPTY (absence is not a measurement of emptiness)" \
                          || bad "heartbeat: an absent state file read as '$(qs)' (want UNKNOWN)"
  for want in UNREADABLE "PARTIAL(P0-blocker)" EMPTY "READ(7)"; do
    printf '%s %s\n' "$want" "$(date +%s)" > "$QD/state/queue-state"
    case "$(qs)" in
      "$want""("*) ok "heartbeat: a recorded $want is carried, with the age of the reading" ;;
      *) bad "heartbeat: $want read as '$(qs)'" ;;
    esac
  done
  # A torn / foreign / hand-edited file must not be printed as a state: an unparseable record is
  # UNKNOWN, not evidence of an empty queue.
  printf 'garbage here\n' > "$QD/state/queue-state"
  [ "$(qs)" = "UNKNOWN" ] && ok "heartbeat: a torn/foreign state file is UNKNOWN, never a fabricated reading" \
                          || bad "heartbeat: a garbage state file read as '$(qs)'"
else
  bad "orch-loop: could not extract queue_state_token (or is_num) from the shipped loop"
fi
# The two lines a human actually reads beside `backlog=`: the per-cycle heartbeat line, and the
# 'backlog empty' claim that used to read as "nothing to do" even when the pool was unreadable.
grep -q 'backlog=\$(wc -l.*queue=\$(queue_state_token)' "$LOOP" \
  && ok "orch-loop: the per-cycle heartbeat line carries the state beside the backlog" \
  || bad "orch-loop: the cycle line does not carry the pool state"
grep -q '\[dispatch\] backlog empty queue=\$(queue_state_token)' "$LOOP" \
  && ok "orch-loop: the 'backlog empty' claim carries the state, so blindness cannot read as stillness" \
  || bad "orch-loop: 'backlog empty' is still printed without the state"

# ── an unwritable state dir REFUSES, it is not absorbed ───────────────────────────────────────
# `mkdir -p "$O"` was unchecked and every write below it was too, so a non-directory `$O` finished with
# `checked 0; backlog now` at rc 0 having persisted NOTHING: no marker for orch-loop, no candidates, a
# cell RUNNING with `lanes: 0`. That is the merge-only shape this change exists to remove, so it must
# refuse loudly rather than report a healthy empty queue (#1853 review).
echo; echo "── an unwritable state dir is refused, not absorbed ──"
mk_case unwritable-o
mk_tool "$D/repo/.worktrees/dispatch-scout/tools/collision_preflight.py"
printf '#' > "$D/state-file" # a REGULAR FILE where $O must be a directory
OUT="$(env -u GH_HOST -u CELL_HOME HOME="$D/home" PATH="$D/bin:$PATH" REPO="$D/repo" \
        O="$D/state-file" bash "$REFRESH" 2>&1)"; RC=$?
[ "$RC" -eq 1 ] && ok "unwritable \$O: rc=1 (TRANSIENT — loud, and no permanent marker)" \
               || bad "unwritable \$O: rc=$RC (want 1) — output: $OUT"
case "$OUT" in
  *"cannot create the state directory"*) ok "unwritable \$O: the abort names the state directory" ;;
  *) bad "unwritable \$O: no refusal — output: $OUT" ;;
esac
case "$OUT" in
  *"checked 0; backlog now"*) bad "unwritable \$O: still reported a healthy empty backlog" ;;
  *) ok "unwritable \$O: no \"checked N; backlog now 0\" over a state dir that was never written" ;;
esac

# The shape a FILE-existence test cannot see: `mkdir -p` SUCCEEDS on an existing read-only directory,
# and a STALE `.pool` from the previous run then satisfies `[ -f "$O/.pool" ]` — so the pass read the
# stale pool, reported `checked N; backlog now M` at rc 0, and persisted nothing (the writes to
# checked.txt / candidates.txt failed silently). Only a WRITE can tell a writable dir from a present
# one (#1853 review).
echo; echo "── a READ-ONLY state dir with a stale pool is refused, not reported as a backlog ──"
mk_case readonly-o
mk_tool "$D/repo/.worktrees/dispatch-scout/tools/collision_preflight.py"
mk_gh_rest "$D" 77
RF_PATH="$D/bin:$PATH" rf "$D" refresh               # a first, healthy run, so the stale state is real
printf '99\n' > "$D/o/.pool"                         # a STALE pool the next run must not inherit
chmod -R a-w "$D/o"
rf "$D" refresh
chmod -R u+w "$D/o" 2>/dev/null || true              # so the case's temp dir can be cleaned up
[ "$RC" -eq 1 ] && ok "read-only \$O: rc=1 (TRANSIENT — loud, and no permanent marker)" \
               || bad "read-only \$O: rc=$RC (want 1) — output: $OUT"
case "$OUT" in
  *"not WRITABLE"*) ok "read-only \$O: the abort says the state dir is not writable" ;;
  *) bad "read-only \$O: no refusal — output: $OUT" ;;
esac
case "$OUT" in
  *"backlog now 1"*|*"+#99"*) bad "read-only \$O: read the STALE pool as this run's backlog — output: $OUT" ;;
  *) ok "read-only \$O: the stale pool is not reported as this run's backlog" ;;
esac

# ── a CLEAN issue is not SUPPRESSED when its queue entry cannot be written ────────────────────
# `checked.txt` is the permanent suppression — reclaimed only for numbers that reached
# `dispatched.txt` — so writing it before the queue entry made a failed queue append an unrecoverable
# loss: the issue is never pre-flighted again, is never queued, and the pass still logs
# `+#N CLEAN -> backlog` and exits 0. Measured with `candidates.txt` unwritable: two consecutive
# passes reported success and the pre-flight ran once, ever (#1853 review). Every state write is now
# checked, and the recoverable one lands FIRST.
echo; echo "── a CLEAN issue is not suppressed when it was never queued ──"
mk_case queue-unwritable
mk_tool "$D/repo/.worktrees/dispatch-scout/tools/collision_preflight.py"
mk_gh_rest "$D" 42
mkdir -p "$D/o/candidates.txt" # a DIRECTORY where the queue file must be
rf "$D" refresh
[ "$RC" -eq 1 ] && ok "queue unwritable: rc=1 (TRANSIENT — loud, and no permanent marker)" \
               || bad "queue unwritable: rc=$RC (want 1) — output: $OUT"
case "$OUT" in
  *"cannot queue #42"*) ok "queue unwritable: the abort names the write that failed AND the issue" ;;
  *) bad "queue unwritable: no refusal — output: $OUT" ;;
esac
case "$OUT" in
  *"+#42"*) bad "queue unwritable: logged a queue entry that never landed" ;;
  *) ok "queue unwritable: no \"+#42 CLEAN -> backlog\" over an issue it did not queue" ;;
esac
if grep -qx 42 "$D/o/checked.txt" 2>/dev/null; then
  bad "queue unwritable: #42 was SUPPRESSED although it was never queued — it can never be dispatched again"
else
  ok "queue unwritable: #42 is NOT suppressed, so the next pass retries it"
fi

# `--check` is deliberately NOT where the gh precondition is judged. cloud-cell-supervisor.sh's
# cmd_check and cloud-cell-bringup.sh's check_gh (which its check_dispatch calls) each ALREADY run
# `gh auth status` themselves (under $CELL_HOME), and orchestrator-harness's selftest pins exactly
# one `gh auth status` call under `$CELL_HOME` for each of them — so a second `gh auth status` from
# here would redden an owned suite AND ask the question in the wrong layer: those
# checks run in the OPERATOR's shell, while the pre-flight inherits the HOME of whatever process
# actually started the controller. The run path is the enforcement point. This case pins that
# `--check` did not quietly acquire a second gh call or a new refusal.
echo; echo "── --check keeps its own verdict (the gh precondition belongs to the RUN path) ──"
mk_case gh-noauth-check
mk_tool "$D/tort/tools/collision_preflight.py"
mk_gh_noauth "$D"
rf "$D" check TORTOISE_REPO="$D/tort"
[ "$RC" -eq 0 ] && ok "--check: still answers its own question (rc=0) — the gh precondition is the run path's" \
               || bad "--check: rc=$RC — the operator-side gate must not acquire a second gh probe (selftest pins one gh call each)"

# ── 1e) ASSERT THE PROPERTY: A PASS THAT JUDGED NOTHING MUST SAY SO ──────────────────────────────
# `checked N; backlog now 0` over a non-empty pool is the reading the fleet has been stuck in — it
# looks like a healthy empty queue, and each `?no verdict` line is a per-candidate MASK of one
# environment failure. The assertion is the TRANSIENT code on purpose: a permanent environment
# failure has already refused above with the reason, so reaching here is a per-cycle anomaly that
# the next cycle should retry (orch-loop.sh logs `FAILED rc=1`). The second half of the case is the
# false-block guard: an EMPTY pool is a legitimate answer and must still exit 0.
echo; echo "── a pass that judged NOTHING does not report an empty backlog ──"
mk_case no-usable-verdict
mkdir -p "$D/repo/.worktrees/dispatch-scout/tools"
cat > "$D/repo/.worktrees/dispatch-scout/tools/collision_preflight.py" <<'PY'
#!/usr/bin/env python3
print("VERDICT: INCOMPLETE (exit 2) — 1 surface(s) could not be queried (issue assignee/holder)")
raise SystemExit(2)
PY
chmod +x "$D/repo/.worktrees/dispatch-scout/tools/collision_preflight.py"
mk_gh_rest "$D" 42
# Seed a sentinel so "nothing queued" is DISCRIMINATING (see the LANDED case below).
echo 99 > "$D/o/candidates.txt"
rf "$D" refresh
[ "$RC" -ne 0 ] && ok "no usable verdict: the pass is NOT reported as success (rc=$RC)" \
               || bad "no usable verdict: rc=0 — an unjudged pool was reported as a healthy empty backlog"
case "$OUT" in
  *"judged NOTHING"*) ok "no usable verdict: the abort names what happened" ;;
  *) bad "no usable verdict: no explanation of the pass — output: $OUT" ;;
esac
case "$OUT" in
  *"checked "*"backlog now"*) bad "no usable verdict: still printed \"checked N; backlog now 0\"" ;;
  *) ok "no usable verdict: the false empty-backlog report is suppressed" ;;
esac
case "$(tr '\n' ' ' < "$D/o/candidates.txt" 2>/dev/null)" in
  *42*) bad "no usable verdict: queued candidates — $(cat "$D/o/candidates.txt" 2>/dev/null)" ;;
  *99*) ok "no usable verdict: nothing is queued (seed 99 intact, #42 absent)" ;;
  *) bad "no usable verdict: the backlog was clobbered — candidates='$(cat "$D/o/candidates.txt" 2>/dev/null)'" ;;
esac
# ...and the same script with an EMPTY pool must still exit 0 (the assertion is not a blanket refusal).
printf '#!/bin/bash\nexit 0\n' > "$D/bin/gh.body"
chmod +x "$D/bin/gh"
rf "$D" refresh
[ "$RC" -eq 0 ] && ok "no usable verdict: an EMPTY pool still exits 0 (no false block)" \
               || bad "no usable verdict: false block on an empty pool — rc=$RC — output: $OUT"

# ── 1f) LANDED IS A USABLE VERDICT (agent-infra#1853 review P1) ─────────────────────────────────
# The tool's fourth verdict is `VERDICT: LANDED (exit 4)` — an issue closed between the pool listing
# and the pre-flight. The parser matched only CLEAN|COLLISION, so a LANDED fell into the `*)` arm, was
# not counted by `usable`, and a pass of LANDEDs then tripped the "judged NOTHING" abort (rc=1). A
# LANDED is terminal and real, so it must count as a usable verdict — while never being queued.
mk_case landed-usable
mkdir -p "$D/repo/.worktrees/dispatch-scout/tools"
cat > "$D/repo/.worktrees/dispatch-scout/tools/collision_preflight.py" <<'PY'
#!/usr/bin/env python3
print("VERDICT: LANDED (exit 4) — the issue's own state is CLOSED")
raise SystemExit(4)
PY
chmod +x "$D/repo/.worktrees/dispatch-scout/tools/collision_preflight.py"
mk_gh_rest "$D" 42
# A sentinel makes the "not queued" assertion DISCRIMINATING: an empty candidates.txt is equally
# consistent with "nothing was queued" and "the backlog was clobbered", and it is empty on the
# pre-fix revision too. Seeding 99 proves #42 was neither added nor the file rewritten away.
echo 99 > "$D/o/candidates.txt"
rf "$D" refresh
[ "$RC" -eq 0 ] && ok "LANDED: a pass of LANDEDs exits 0 (not the rc=1 abort)" \
               || bad "LANDED: rc=$RC (want 0 — LANDED must count as usable) — output: $OUT"
case "$OUT" in
  *"judged NOTHING"*) bad "LANDED: the abort fired on a usable LANDED verdict" ;;
  *) ok "LANDED: no \"judged NOTHING\" abort" ;;
esac
case "$OUT" in
  *"LANDED"*) ok "LANDED: the verdict is reported" ;;
  *) bad "LANDED: the verdict was not reported — output: $OUT" ;;
esac
case "$(tr '\n' ' ' < "$D/o/candidates.txt" 2>/dev/null)" in
  *42*) bad "LANDED: a landed issue was queued (it must not enter candidates.txt)" ;;
  *99*) ok "LANDED: a landed issue is NOT queued (seed 99 intact, #42 absent)" ;;
  *) bad "LANDED: the backlog was clobbered — candidates='$(cat "$D/o/candidates.txt" 2>/dev/null)'" ;;
esac

# ── 1g) A DEGRADED COLLISION IS NOT A VERDICT (agent-infra#1853 review P2, #1328) ───────────────
# Measured on the live cells: an issue whose true verdict was LANDED came back as
# `VERDICT: COLLISION ... ALSO INCOMPLETE: 3 surface(s) could not be queried`. Counting that as usable
# would let a broken environment report a healthy `checked N; backlog now 0` — the exact reading this
# gate exists to refuse. Degraded collisions must NOT count, so the pass must abort (rc=1) instead.
mk_case degraded-collision
mkdir -p "$D/repo/.worktrees/dispatch-scout/tools"
cat > "$D/repo/.worktrees/dispatch-scout/tools/collision_preflight.py" <<'PY'
#!/usr/bin/env python3
print("VERDICT: COLLISION (exit 1) — the pre-flight could not name a holder")
print("  ALSO INCOMPLETE: 3 surface(s) could not be queried")
raise SystemExit(1)
PY
chmod +x "$D/repo/.worktrees/dispatch-scout/tools/collision_preflight.py"
mk_gh_rest "$D" 42
# A sentinel makes the "nothing queued" assertion DISCRIMINATING (see the LANDED case): an empty
# file cannot distinguish "the degraded answer was not queued" from "the backlog was clobbered".
echo 99 > "$D/o/candidates.txt"
rf "$D" refresh
[ "$RC" -eq 1 ] && ok "degraded COLLISION: the pass aborts TRANSIENT (rc=1) instead of passing" \
               || bad "degraded COLLISION: rc=$RC (want 1) — output: $OUT"
case "$OUT" in
  *"checked "*"backlog now"*) bad "degraded COLLISION: still reported a healthy empty backlog" ;;
  *) ok "degraded COLLISION: no \"checked N; backlog now 0\" over a degraded answer" ;;
esac
case "$OUT" in
  *"DEGRADED"*) ok "degraded COLLISION: the degradation is NAMED" ;;
  *) bad "degraded COLLISION: the degradation is not reported — output: $OUT" ;;
esac
case "$(tr '\n' ' ' < "$D/o/candidates.txt" 2>/dev/null)" in
  *42*) bad "degraded COLLISION: queued candidates — $(cat "$D/o/candidates.txt" 2>/dev/null)" ;;
  *99*) ok "degraded COLLISION: nothing is queued (seed 99 intact, #42 absent)" ;;
  *) bad "degraded COLLISION: the backlog was clobbered — candidates='$(cat "$D/o/candidates.txt" 2>/dev/null)'" ;;
esac

# ── 1h) A NETWORK FAULT IS TRANSIENT, NOT PERMANENT (agent-infra#1853 review P1) ────────────────
# The discriminator is the PRESENCE OF A STORED CREDENTIAL, not gh's prose. MEASURED on gh 2.97.0
# behind a dead proxy (`HTTPS_PROXY=http://127.0.0.1:1`): a PURE transport fault still prints "The
# token in ~/.config/gh/hosts.yml is invalid.", so any text match on `invalid` classes an outage as
# a credential failure — while `gh auth token` (an OFFLINE lookup of the stored credential) succeeds.
# The stub below reproduces that exact prose, so this case FAILS on any text-matching discriminator.
mk_case gh-stale-token
mk_tool "$D/repo/.worktrees/dispatch-scout/tools/collision_preflight.py"
mk_gh_stale_token "$D"
rf "$D" refresh
[ "$RC" -eq 1 ] && ok "stale token: rc=1 (TRANSIENT — not the permanent 3)" \
               || bad "stale token: rc=$RC (want 1) — output: $OUT"
case "$OUT" in
  *"TRANSIENT"*) ok "stale token: reported TRANSIENT (a stored credential is not a missing one)" ;;
  *) bad "stale token: no TRANSIENT verdict — output: $OUT" ;;
esac
case "$OUT" in
  *"NOT PROVISIONABLE"*) bad "stale token: the outage-shaped prose was called NOT PROVISIONABLE" ;;
  *) ok "stale token: not reported as NOT PROVISIONABLE" ;;
esac

# The other arm: NO credential is STORED (both `auth status` and the offline `auth token` fail) —
# the broken-HOME defect (#1328), which retrying cannot fix, so it is PERMANENT (rc=3).
mk_case gh-no-stored-token
mk_tool "$D/repo/.worktrees/dispatch-scout/tools/collision_preflight.py"
mk_gh_noauth "$D"
rf "$D" refresh
[ "$RC" -eq 3 ] && ok "no stored credential: rc=3 (PERMANENT — retrying cannot conjure one)" \
               || bad "no stored credential: rc=$RC (want 3) — output: $OUT"
case "$OUT" in
  *"NOT PROVISIONABLE"*) ok "no stored credential: the refusal is LOUD and named" ;;
  *) bad "no stored credential: no NOT PROVISIONABLE verdict — output: $OUT" ;;
esac

# ── 1i) A STORED-BUT-REJECTED CREDENTIAL IS PERMANENT (agent-infra#1853 review P1) ──────────────
# The most common real credential failure: a stale/revoked token is STORED (`auth token` succeeds)
# but the API REJECTS it (HTTP 401). Returning TRANSIENT for ever leaves no marker and no escalation
# while the cell reports RUNNING with `lanes: 0` — the exact #1328/#1736 shape this PR removes. The
# API layer is the only signal that separates a rejected credential from an unreachable one
# (measured on gh 2.97.0: a bogus stored token prints `gh: Bad credentials (HTTP 401)`; a dead proxy
# prints no HTTP status at all).
mk_case gh-rejected
mk_tool "$D/repo/.worktrees/dispatch-scout/tools/collision_preflight.py"
mk_gh_rejected "$D"
rf "$D" refresh
[ "$RC" -eq 3 ] && ok "rejected credential: rc=3 (PERMANENT — a retry cannot change a 401)" \
               || bad "rejected credential: rc=$RC (want 3) — output: $OUT"
case "$OUT" in
  *"NOT PROVISIONABLE"*) ok "rejected credential: the refusal is LOUD and named" ;;
  *) bad "rejected credential: no NOT PROVISIONABLE verdict — output: $OUT" ;;
esac
case "$OUT" in
  *"HTTP 401"*) ok "rejected credential: the refusal names the 401 (the discriminating signal)" ;;
  *) bad "rejected credential: the refusal does not name the 401 — output: $OUT" ;;
esac

# ── 1j) A CLEAN THAT IS DEGRADED IS NOT A VERDICT (agent-infra#1853 review P2) ──────────────────
# The canonical producer never pairs `ALSO INCOMPLETE` with CLEAN, but `resolve_preflight` prefers
# the repo's OWN copy — so a VENDORED producer could, and a degraded CLEAN counted as usable would
# let a broken environment queue an issue it could not actually judge. The guard must drop it.
# ⛔ The report echoes the candidate's own `title:` line, so the marker match must be ANCHORED: an
# unanchored search would let an issue TITLE containing the phrase set the flag. Pinned by case 1k.
mk_case clean-degraded
mkdir -p "$D/repo/.worktrees/dispatch-scout/tools"
cat > "$D/repo/.worktrees/dispatch-scout/tools/collision_preflight.py" <<'PY'
#!/usr/bin/env python3
print("VERDICT: CLEAN (exit 0) — the pre-flight could not query every surface")
print("  ALSO INCOMPLETE: 3 surface(s) could not be queried")
raise SystemExit(0)
PY
chmod +x "$D/repo/.worktrees/dispatch-scout/tools/collision_preflight.py"
mk_gh_rest "$D" 42
# A sentinel makes "nothing queued" DISCRIMINATING: an empty file cannot distinguish "the degraded
# CLEAN was not queued" from "the backlog was clobbered".
echo 99 > "$D/o/candidates.txt"
rf "$D" refresh
[ "$RC" -eq 1 ] && ok "CLEAN is DEGRADED: the pass aborts TRANSIENT (rc=1) — no usable verdict" \
               || bad "CLEAN is DEGRADED: rc=$RC (want 1) — output: $OUT"
case "$OUT" in
  *"CLEAN is DEGRADED"*) ok "CLEAN is DEGRADED: the degradation is NAMED" ;;
  *) bad "CLEAN is DEGRADED: the degradation is not reported — output: $OUT" ;;
esac
case "$OUT" in
  *"checked "*"backlog now"*) bad "CLEAN is DEGRADED: still reported a healthy backlog" ;;
  *) ok "CLEAN is DEGRADED: no \"checked N; backlog now M\" over a degraded CLEAN" ;;
esac
case "$(tr '\n' ' ' < "$D/o/candidates.txt" 2>/dev/null)" in
  *42*) bad "CLEAN is DEGRADED: the degraded CLEAN was queued — $(cat "$D/o/candidates.txt" 2>/dev/null)" ;;
  *99*) ok "CLEAN is DEGRADED: not queued (seed 99 intact, #42 absent from candidates.txt)" ;;
  *) bad "CLEAN is DEGRADED: the backlog was clobbered — candidates='$(cat "$D/o/candidates.txt" 2>/dev/null)'" ;;
esac
case "$(tr '\n' ' ' < "$D/o/checked.txt" 2>/dev/null)" in
  *42*) bad "CLEAN is DEGRADED: the degraded CLEAN was written to checked.txt (blacklisted)" ;;
  *) ok "CLEAN is DEGRADED: not written to checked.txt (left unchecked for the next pass)" ;;
esac

# ── 1k) A TITLE THAT QUOTES THE MARKER DOES NOT DEGRADE A CLEAN (agent-infra#1853 review P2) ─────
# The anchor on the `ALSO INCOMPLETE` match is LOAD-BEARING, not stylistic: the pre-flight report
# echoes the candidate's own `title:` line, so an unanchored search would let an ISSUE TITLE that
# contains the phrase set the degraded flag and silently drop a genuine CLEAN. This case FAILS on
# the unanchored form (`grep -q 'ALSO INCOMPLETE'`): the issue is left unchecked and never queued.
mk_case title-quotes-marker
mkdir -p "$D/repo/.worktrees/dispatch-scout/tools"
cat > "$D/repo/.worktrees/dispatch-scout/tools/collision_preflight.py" <<'PY'
#!/usr/bin/env python3
print("title: fix the ALSO INCOMPLETE: reporting path")
print("VERDICT: CLEAN")
raise SystemExit(0)
PY
chmod +x "$D/repo/.worktrees/dispatch-scout/tools/collision_preflight.py"
mk_gh_rest "$D" 42
rf "$D" refresh
[ "$RC" -eq 0 ] && ok "title quotes the marker: rc=0 (no \"judged NOTHING\" abort over a genuine CLEAN)" \
               || bad "title quotes the marker: rc=$RC (want 0) — output: $OUT"
case "$OUT" in
  *"DEGRADED"*) bad "title quotes the marker: a TITLE set the degraded flag — output: $OUT" ;;
  *) ok "title quotes the marker: the CLEAN is NOT read as DEGRADED" ;;
esac
case "$(tr '\n' ' ' < "$D/o/candidates.txt" 2>/dev/null)" in
  *42*) ok "title quotes the marker: the genuinely-CLEAN candidate IS queued" ;;
  *) bad "title quotes the marker: the CLEAN was dropped — candidates='$(cat "$D/o/candidates.txt" 2>/dev/null)'" ;;
esac

# ── 2) the tool is resolved PER REPO: the repo's OWN copy wins, run from the scout with --repo . ─
# Structural, not textual: the stub tool records its cwd and argv, and the candidate it cleared must
# reach the backlog — which can only happen if the resolved tool actually ran.
mk_case own-tool
mk_tool "$D/repo/.worktrees/dispatch-scout/tools/collision_preflight.py"
mk_gh_rest "$D" 42
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
# A sentinel makes "nothing queued" DISCRIMINATING (see the LANDED case): an empty file cannot
# distinguish "nothing was queued" from "the backlog was clobbered".
echo 99 > "$D/o/candidates.txt"
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
case "$(tr '\n' ' ' < "$D/o/candidates.txt" 2>/dev/null)" in
  *42*) bad "no tool anywhere: candidates were queued — $(cat "$D/o/candidates.txt" 2>/dev/null)" ;;
  *99*) ok "no tool anywhere: nothing is queued (seed 99 intact, #42 absent)" ;;
  *) bad "no tool anywhere: the backlog was clobbered — candidates='$(cat "$D/o/candidates.txt" 2>/dev/null)'" ;;
esac

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
  # (c) BOUND THE MARKER'S EVIDENCE TO THE CURRENT RUN (agent-infra#1853 review P2). $LOG is
  # append-only and never rotated, so a bare `grep 'NOT PROVISIONABLE' "$LOG"` would quote a
  # PREVIOUS cycle's refusal as this run's reason — presenting a cause that no longer fired. The
  # marker must quote the CURRENT run's line only. Stubs write NOTHING to the log on the pre-fix
  # code, so the evidence region is empty and only `[ -s marker ]` is ever asserted; the stale seed
  # below makes the bound TESTABLE — on the unbounded grep it appears in the marker.
  BL3="$T/block3"; mkdir -p "$BL3"; : > "$BL3/candidates.txt"
  printf '[refresh] NOT PROVISIONABLE: STALE PREVIOUS CYCLE REFUSAL\n' > "$BL3/log"
  printf '#!/bin/bash\necho "[refresh] NOT PROVISIONABLE: CURRENT CYCLE REFUSAL" >> "%s/log"\nexit 3\n' "$BL3" > "$BL3/refresh-candidates.sh"
  chmod +x "$BL3/refresh-candidates.sh"
  O="$BL3" LOG="$BL3/log" bash "$T/refreshblock.sh" >/dev/null 2>&1
  grep -q 'CURRENT CYCLE REFUSAL' "$BL3/.refresh-blocked" 2>/dev/null \
    && ok "orch-loop: the marker quotes the CURRENT run's refusal" \
    || bad "orch-loop: the marker does not quote the current refusal — $(cat "$BL3/.refresh-blocked" 2>/dev/null)"
  grep -q 'STALE PREVIOUS CYCLE REFUSAL' "$BL3/.refresh-blocked" 2>/dev/null \
    && bad "orch-loop: the marker quoted a PREVIOUS cycle's refusal as this run's reason" \
    || ok "orch-loop: a previous cycle's refusal is NOT presented as this run's reason"
else
  bad "orch-loop: could not extract the refresh block"
fi

# ── 8) the pre-flight CONSULTS THE ISSUE-CLAIM REGISTRY, and fails CLOSED (#1850) ──────────────
# The defect this section exists for: the pre-flight tool enumerates immutable history (PRs,
# branches, worktrees, assignee) — and branches/worktrees are PER-MACHINE, so a PEER's lane is
# invisible until it first pushes. Nothing assigns the issue on dispatch, so both boxes read CLEAN
# and both dispatch. The registry read is the surface that closes it, and these cases drive the
# SHIPPED refresh with a REAL claim ref on a REAL (local) origin.
#
# NON-VACUITY, MEASURED: on the pre-change refresh-candidates.sh all three cases fail — (a) and (b)
# because the candidate IS queued (nothing reads the registry), (c) because the warning line does not
# exist. Reproduce against the pre-change tree by checking out the base revision of the script.
mk_gh_one_issue() {   # <dir> — the REST `gh` stub with issue 42 in the pool (#1962: see mk_gh_rest)
  mk_gh_rest "$1" 42
  mk_gh_wrapper "$1"
}

# (a) A LIVE claim from another box: the issue is a COLLISION, not CLEAN. It must not be queued
#     (nothing is dispatched on a guess) and must NOT be blacklisted (a claim is a window, not a
#     verdict), so the next pass re-attempts it.
mk_case claim-collision
mk_tool "$D/repo/.worktrees/dispatch-scout/tools/collision_preflight.py"
mk_gh_one_issue "$D"
mk_issue_claim "$D" 42 600 || bad "claim-collision: could not seed the peer's issue claim"
rf "$D" refresh
case "$(tr '\n' ' ' < "$D/o/candidates.txt" 2>/dev/null)" in
  *42*) bad "claim-collision: #42 was QUEUED although a peer holds the issue claim — candidates='$(cat "$D/o/candidates.txt" 2>/dev/null)'" ;;
  *) ok "claim-collision: a peer's LIVE issue claim keeps #42 OUT of the backlog" ;;
esac
case "$OUT" in
  *"COLLISION (cross-box issue claim)"*) ok "claim-collision: the verdict NAMES the cross-box claim (not the tool's own surface)" ;;
  *) bad "claim-collision: the collision is not attributed to the claim registry — output: $OUT" ;;
esac
case "$(tr '\n' ' ' < "$D/o/checked.txt" 2>/dev/null)" in
  *42*) bad "claim-collision: #42 was BLACKLISTED — a transient claim must be re-attempted, not suppressed" ;;
  *) ok "claim-collision: #42 is left UNCHECKED for the next pass" ;;
esac
# ⛔ AND the pass must still SUCCEED. A claim collision is a COLLISION — one of the three verdicts the
# `usable` contract counts — so an all-claim-held pool must not be read as "judged NOTHING". Without
# this the cell logged `FAILED rc=1` every cycle in exactly the cross-box-collision state this check
# exists for, while having printed a verdict per candidate (#1853 review).
[ "$RC" -eq 0 ] && ok "claim-collision: the pass SUCCEEDS (rc=0 — a claim collision is a usable verdict)" \
               || bad "claim-collision: rc=$RC (want 0) — a pool of peer-held issues was reported as judging NOTHING — output: $OUT"
case "$OUT" in
  *"judged NOTHING"*) bad "claim-collision: the pass aborted as if it had no verdict — output: $OUT" ;;
  *) ok "claim-collision: no \"judged NOTHING\" abort over a pool of peer-held issues" ;;
esac

# (b) The registry is UNREACHABLE (origin removed): INCOMPLETE — never CLEAN. A registry outage must
#     not become a duplicate dispatch, so nothing is queued and nothing is blacklisted either.
mk_case claim-unreachable
mk_tool "$D/repo/.worktrees/dispatch-scout/tools/collision_preflight.py"
mk_gh_one_issue "$D"
git -C "$D/repo" remote set-url origin "$D/no-such-origin-anywhere.git"
rf "$D" refresh
case "$(tr '\n' ' ' < "$D/o/candidates.txt" 2>/dev/null)" in
  *42*) bad "claim-unreachable: #42 was queued on an UNREADABLE registry — a false CLEAN" ;;
  *) ok "claim-unreachable: an unreadable registry queues NOTHING (INCOMPLETE, never CLEAN)" ;;
esac
case "$OUT" in
  *"INCOMPLETE"*) ok "claim-unreachable: the refusal is named INCOMPLETE" ;;
  *) bad "claim-unreachable: no INCOMPLETE verdict — output: $OUT" ;;
esac
case "$(tr '\n' ' ' < "$D/o/checked.txt" 2>/dev/null)" in
  *42*) bad "claim-unreachable: #42 was blacklisted on an unreadable registry" ;;
  *) ok "claim-unreachable: #42 is left unchecked, so an outage does not consume an issue" ;;
esac
# ⛔ A PASS THE REGISTRY ANSWERED NOTHING FOR IS NOT A HEALTHY PASS (2026-10-16 review). The per-issue
# lines scroll away and `lanes: 0` + `backlog=0` is exactly what a quiet box looks like, so an
# unreadable registry used to be indistinguishable from "no work available". The pass must exit
# TRANSIENT, and it must say the registry (not the pool) was the reason.
[ "$RC" = "1" ] && ok "claim-unreachable: the pass exits TRANSIENT (1), not 0 — an outage is not 'no work'" \
               || bad "claim-unreachable: rc=$RC — a pass that queued nothing on an unreadable registry read as healthy"
case "$OUT" in
  *"of 1 pre-flighted issues INCOMPLETE"*) ok "claim-unreachable: the aggregate names how many the registry could not answer for" ;;
  *) bad "claim-unreachable: no aggregate INCOMPLETE line — output: $OUT" ;;
esac

# (c) The registry is NOT INSTALLED: the documented FALLBACK. The candidate IS queued (a missing FILE
#     is not an unreachable registry — refusing here would make the box merge-only), and the box says
#     so every time. This pins the limit the code comment states, so it cannot go quiet.
mk_case claim-absent
mk_tool "$D/repo/.worktrees/dispatch-scout/tools/collision_preflight.py"
mk_gh_one_issue "$D"
# A genuinely MISSING file — not a bogus path in the environment. `CLAIMS_SH` was a test seam that
# three production callers had begun to honour, which let an ambient value disable the gate in one
# of them and not the others; the path is `$O/claims.sh` everywhere now, so the absence is staged by
# removing the file (2026-10-16 review).
rm -f "$D/o/claims.sh"
rf "$D" refresh
case "$(tr '\n' ' ' < "$D/o/candidates.txt" 2>/dev/null)" in
  *42*) ok "claim-absent: a candidate is still queued (the fallback is not a false block)" ;;
  *) bad "claim-absent: nothing was queued — candidates='$(cat "$D/o/candidates.txt" 2>/dev/null)'" ;;
esac
case "$OUT" in
  *"no claim registry at"*"cross-box issue-claim check is OFF"*) ok "claim-absent: the missing registry is ANNOUNCED (never silent)" ;;
  *) bad "claim-absent: the missing registry is silent — output: $OUT" ;;
esac

# (e) A REGISTRY THAT CANNOT ANSWER THE QUESTION IS NOT EVIDENCE OF FREEDOM. `$O/claims.sh` exists
#     but predates the issue key (install.sh reports that drift; the daemon executes the $O copy), so
#     the reader has nothing to call. Calling the missing function would return 127 — a value the
#     CLEAN arm's `case` would read as neither 1 nor 2 and therefore QUEUE. It must read INCOMPLETE.
#     The stub is written explicitly (rather than taken from git) so the case cannot silently become
#     "the current file" on a branch where the functions exist. ⛔ It must stay free of any
#     `git … "$@"` delegation shape: an unresolved git VERB is what the checkout guard fails closed
#     on (`unverifiable-verb`), and it refused to run this suite when the stub carried one.
mk_case claim-stale-registry
mk_tool "$D/repo/.worktrees/dispatch-scout/tools/collision_preflight.py"
mk_gh_one_issue "$D"
printf '# a registry that predates the issue key: sourceable, no claim_issue_* functions\nCLAIM_TTL=1800\n' > "$D/o/claims.sh"
rf "$D" refresh
case "$(tr '\n' ' ' < "$D/o/candidates.txt" 2>/dev/null)" in
  *42*) bad "claim-stale-registry: #42 was queued by a registry that cannot answer the issue-claim question" ;;
  *) ok "claim-stale-registry: a registry that cannot answer queues NOTHING (INCOMPLETE)" ;;
esac
case "$OUT" in
  *"predates the issue-claim reader"*) ok "claim-stale-registry: the refusal NAMES the stale registry" ;;
  *) bad "claim-stale-registry: the reason is not named — output: $OUT" ;;
esac
# ⛔ AND IT IS A PROVISIONING FAILURE, NOT A PER-ISSUE ONE (2026-10-16 review). A stale $O/claims.sh is
# LOCAL and PERMANENT, so answering INCOMPLETE per issue queues nothing FOREVER while the cell still
# reports RUNNING — the "looks alive and can only merge" defect this script has been fixed for twice
# (#1748, #1736). rc=3 is what orch-loop.sh turns into `.refresh-blocked` (stop retrying, name it).
[ "$RC" = "3" ] && ok "claim-stale-registry: the pass exits NOT-PROVISIONABLE (3) so the cell is not read as healthy" \
                 || bad "claim-stale-registry: rc=$RC — a permanent local drift exited 0 and would be retried forever"
case "$OUT" in
  *"NOT PROVISIONABLE"*) ok "claim-stale-registry: the permanent drift is reported on the provisioning channel" ;;
  *) bad "claim-stale-registry: no NOT PROVISIONABLE line — output: $OUT" ;;
esac

# (g) ⛔ AN UNRECOGNISED VERDICT CODE IS NOT A LICENCE TO DISPATCH (2026-10-16 review). The CLEAN arm
#     was `case 1) … 2) … *) CLEAN`, so ANY other code — 127 from a missing function, or whatever a
#     foreign/newer/older registry returns — was read as CLEAN and QUEUED the issue: fail-OPEN in the
#     one place the block declares it never fails open. Only an explicit 0 may queue.
#     The stub is a sourceable registry whose reader answers 7, the shape a future/foreign copy has.
mk_case claim-unrecognised
mk_tool "$D/repo/.worktrees/dispatch-scout/tools/collision_preflight.py"
mk_gh_one_issue "$D"
printf '# a registry whose verdict code this caller does not know\nclaim_issue_preflight() { return 7; }\n' > "$D/o/claims.sh"
rf "$D" refresh
case "$(tr '\n' ' ' < "$D/o/candidates.txt" 2>/dev/null)" in
  *42*) bad "claim-unrecognised: #42 was QUEUED on an unrecognised verdict code — fail-OPEN" ;;
  *) ok "claim-unrecognised: an unrecognised verdict code queues NOTHING (INCOMPLETE, never CLEAN)" ;;
esac
case "$OUT" in
  *"UNRECOGNISED verdict"*) ok "claim-unrecognised: the reason names the unrecognised code" ;;
  *) bad "claim-unrecognised: the unrecognised verdict is not named — output: $OUT" ;;
esac
[ "$RC" = "1" ] && ok "claim-unrecognised: the pass exits TRANSIENT so it is not read as 'no work'" \
                 || bad "claim-unrecognised: rc=$RC (want 1)"

# (f) And the CLEAN path still works WITH the registry installed and NO claim: the gate must not be a
#     blanket refusal. (Case 2 above already covers this shape, but it now runs with a real origin and
#     the registry present — this makes the "no claim => CLEAN" half explicit.)
mk_case claim-free
mk_tool "$D/repo/.worktrees/dispatch-scout/tools/collision_preflight.py"
mk_gh_one_issue "$D"
rf "$D" refresh
case "$(tr '\n' ' ' < "$D/o/candidates.txt" 2>/dev/null)" in
  *42*) ok "claim-free: with the registry readable and no claim, #42 IS queued (no false block)" ;;
  *) bad "claim-free: #42 was not queued although nothing holds it — output: $OUT" ;;
esac

# ── 9) orch-loop.sh's DISPATCH claims the issue, and a REFUSED claim does not dispatch ───────
# The registry read above only stops a PEER from QUEUEING the issue; the claim itself is taken when
# the controller forms its batch, and that CAS is what makes two simultaneous boxes safe (both can
# read CLEAN before either claims). The shipped batch block is extracted VERBATIM and driven against
# a real local origin with a real claims.sh, so the assertion is about the shipped code, not a
# re-implementation.
awk '/if \[ -z/ && /GATE_WHY/ {f=1} f{print} f&&/^    done < /{exit}' \
  "$LOOP" > "$T/dispatchblock.sh"
printf '\nfi\n' >> "$T/dispatchblock.sh"
if [ -s "$T/dispatchblock.sh" ] && grep -q 'claim_issue_acquire' "$T/dispatchblock.sh"; then
  ok "orch-loop: the dispatch block (with the issue claim) is extractable from the shipped loop"
  # db <sandbox> — run the shipped block with $O/candidates.txt = 42 and $BATCH=1. The registry is
  # the SHIPPED claims.sh, sourced from $O with CLAIM_REPO set exactly as the loop's own cycle does
  # (sourcing it here is what makes `declare -f claim_issue_acquire` true, as it is in the daemon).
  db() {
    local d="$1"
    ( O="$d/o" LOG="$d/log" BATCH=1 OR="acme/widget" REPO="$d/repo" GATE_WHY="" \
      bash -c 'CLAIM_REPO="$REPO"; . "$O/claims.sh"; . "$1"' _ "$T/dispatchblock.sh" ) >/dev/null 2>&1
  }
  # (i) NO claim exists: the issue is claimed, recorded in .batch/dispatched.txt, and the commit this
  #     box pushed is written to state/issueclaim-42 for chain-merge.sh's FENCED release.
  DB1="$T/db-ok"; mkdir -p "$DB1/o/state" "$DB1/repo"
  git init -q --bare "$DB1/origin.git"; git init -q "$DB1/repo"
  git -C "$DB1/repo" remote add origin "$DB1/origin.git"
  cp "$HERE/claims.sh" "$DB1/o/claims.sh"
  printf '42\n' > "$DB1/o/candidates.txt"; : > "$DB1/o/dispatched.txt"
  db "$DB1"
  case "$(tr '\n' ' ' < "$DB1/o/.batch" 2>/dev/null)" in
    *42*) ok "orch-loop dispatch: the issue IS batched once it holds the claim" ;;
    *) bad "orch-loop dispatch: nothing was batched — log: $(cat "$DB1/log" 2>/dev/null)" ;;
  esac
  case "$(tr '\n' ' ' < "$DB1/o/dispatched.txt" 2>/dev/null)" in
    *42*) ok "orch-loop dispatch: the cleared issue is recorded in dispatched.txt" ;;
    *) bad "orch-loop dispatch: dispatched.txt was not written" ;;
  esac
  [ -s "$DB1/o/state/issueclaim-42" ] && ok "orch-loop dispatch: the claimed commit is recorded for the fenced release" \
                                      || bad "orch-loop dispatch: state/issueclaim-42 is missing (no fenced release possible)"
  one_left="$(git -C "$DB1/repo" ls-remote origin 'refs/claims/*' | wc -l | tr -d ' ')"
  [ "$one_left" = "1" ] && ok "orch-loop dispatch: the claim ref IS on origin (one box can now see it)" \
                         || bad "orch-loop dispatch: expected 1 claim ref on origin, found $one_left"
  # (ii) a PEER already holds it: NOT batched, NOT in dispatched.txt (so the issue stays in
  #      candidates.txt for the next cycle), and no lane can be spawned for work another box owns.
  DB2="$T/db-held"; mkdir -p "$DB2/o/state" "$DB2/repo"
  git init -q --bare "$DB2/origin.git"; git init -q "$DB2/repo"
  git -C "$DB2/repo" remote add origin "$DB2/origin.git"
  cp "$HERE/claims.sh" "$DB2/o/claims.sh"
  mk_issue_claim "$DB2" 42 600 || bad "orch-loop dispatch: could not seed the peer's claim"
  printf '42\n' > "$DB2/o/candidates.txt"; : > "$DB2/o/dispatched.txt"
  db "$DB2"
  case "$(tr '\n' ' ' < "$DB2/o/.batch" 2>/dev/null)" in
    *42*) bad "orch-loop dispatch: a HELD issue was batched anyway" ;;
    *) ok "orch-loop dispatch: a claim held by a peer leaves the issue OUT of the batch" ;;
  esac
  case "$(tr '\n' ' ' < "$DB2/o/dispatched.txt" 2>/dev/null)" in
    *42*) bad "orch-loop dispatch: a HELD issue was blacklisted in dispatched.txt" ;;
    *) ok "orch-loop dispatch: a held issue is NOT blacklisted (it returns next cycle)" ;;
  esac
  [ ! -e "$DB2/o/state/issueclaim-42" ] && ok "orch-loop dispatch: no release record was written for a refused claim" \
                                        || bad "orch-loop dispatch: a release record exists for a claim this box never took"
  # (iii) ⛔ A REGISTRY TOO OLD TO TAKE A CLAIM MUST NOT DISPATCH UNCLAIMED (2026-10-16 review). The
  #       pre-flight refuses every issue on such a box (case (e): rc=3 NOT PROVISIONABLE), so
  #       dispatching here is the fail-open half of that same condition — an issue a peer may already
  #       own goes out with no claim at all, while the box's own reader calls the registry unusable.
  DB3="$T/db-stale"; mkdir -p "$DB3/o/state" "$DB3/repo"
  git init -q --bare "$DB3/origin.git"; git init -q "$DB3/repo"
  git -C "$DB3/repo" remote add origin "$DB3/origin.git"
  printf '# a registry that predates the issue key: sourceable, no claim_issue_* functions\nCLAIM_TTL=1800\n' > "$DB3/o/claims.sh"
  printf '42\n' > "$DB3/o/candidates.txt"; : > "$DB3/o/dispatched.txt"
  db "$DB3"
  case "$(tr '\n' ' ' < "$DB3/o/.batch" 2>/dev/null)" in
    *42*) bad "orch-loop dispatch: a STALE registry dispatched the issue UNCLAIMED (fail-open)" ;;
    *) ok "orch-loop dispatch: a stale registry stops the dispatch (no claim is possible on this box)" ;;
  esac
  case "$(cat "$DB3/log" 2>/dev/null)" in
    *"predates the issue key"*) ok "orch-loop dispatch: the stale registry is NAMED in the log, with the fix" ;;
    *) bad "orch-loop dispatch: the stale-registry stop is not explained — log: $(cat "$DB3/log" 2>/dev/null)" ;;
  esac
else
  bad "orch-loop: could not extract the dispatch block carrying claim_issue_acquire"
fi

# ── 10) chain-merge.sh releases the issue claim on EVERY exit path, and the release is FENCED ────
# Kept OUT of the block above on purpose: nested there, a failure to extract the DISPATCH block
# silently SKIPPED these assertions — coverage that disappears exactly when something else broke is
# not coverage. Both blocks now fail independently.
# The shipped function is extracted (not re-implemented) and driven directly; the 90-minute PR wait
# that follows it in the real script is not part of it.
awk '/^release_issue_claim\(\) \{/{f=1} f{print} f&&/^}$/{exit}' "$HERE/chain-merge.sh" > "$T/release.sh"
if [ -s "$T/release.sh" ] && grep -q 'claim_issue_release' "$T/release.sh"; then
    ok "chain-merge: the issue-claim release is extractable from the shipped script"
    RL1="$T/rl-ok"; mkdir -p "$RL1/o/state" "$RL1/repo"
    git init -q --bare "$RL1/origin.git"; git init -q "$RL1/repo"
    git -C "$RL1/repo" remote add origin "$RL1/origin.git"
    cp "$HERE/claims.sh" "$RL1/o/claims.sh"
    # The box's own claim, minted and pushed the way orch-loop.sh does it; its commit is the fence.
    # (Separate assignments, NOT a prefix on `.` — see mk_issue_claim's note.)
    own="$( cd "$RL1/repo" || exit 1
            CLAIM_REPO="$RL1/repo"; CLAIM_OWNER_ID=selfbox; export CLAIM_REPO CLAIM_OWNER_ID
            . "$HERE/claims.sh"
            _claim_commit selfbox "$(( $(date +%s) + 600 ))" )"
    [ -n "$own" ] || bad "chain-merge: could not mint the box's own issue claim"
    git -C "$RL1/repo" push -q origin "$own:refs/claims/issue-42"
    printf '%s\n' "$own" > "$RL1/o/state/issueclaim-42"
    # ⛔ Separate ASSIGNMENTS, not a variable prefix on `.` — a prefix is a temporary environment for
    # that one command and bash RESTORES it afterwards, so the extracted function would read O/N/REPO
    # UNSET and abort under `set -u` (measured: the release silently did nothing). claims.sh is
    # sourced first because the record/fence convention (`claim_issue_release_record`) lives THERE,
    # not in this function — one implementation, one writer convention (see its comment).
    ( O="$RL1/o"; LOG="$RL1/o/log"; N=42; REPO="$RL1/repo"; CLAIM_REPO="$RL1/repo"
      export O LOG N REPO CLAIM_REPO
      . "$RL1/o/claims.sh"; . "$T/release.sh"; release_issue_claim ) >/dev/null 2>&1
    rl_left="$(git -C "$RL1/repo" ls-remote origin 'refs/claims/*' | wc -l | tr -d ' ')"
    [ "$rl_left" = "0" ] && ok "chain-merge: the issue claim IS released on the exit path" \
                          || bad "chain-merge: the issue claim survived the release ($rl_left refs)"
    [ ! -e "$RL1/o/state/issueclaim-42" ] && ok "chain-merge: the release record is cleaned up" \
                                          || bad "chain-merge: the release record was left behind"
    # FENCING: a peer reclaimed the ref (its commit is the tip); OUR stale record must not delete it.
    RL2="$T/rl-stale"; mkdir -p "$RL2/o/state" "$RL2/repo"
    git init -q --bare "$RL2/origin.git"; git init -q "$RL2/repo"
    git -C "$RL2/repo" remote add origin "$RL2/origin.git"
    cp "$HERE/claims.sh" "$RL2/o/claims.sh"
    stale="$( cd "$RL2/repo" || exit 1
              CLAIM_REPO="$RL2/repo"; CLAIM_OWNER_ID=selfbox; export CLAIM_REPO CLAIM_OWNER_ID
              . "$HERE/claims.sh"
              _claim_commit selfbox "$(( $(date +%s) - 5 ))" )"
    peerc="$( cd "$RL2/repo" || exit 1
              CLAIM_REPO="$RL2/repo"; CLAIM_OWNER_ID=peerbox; export CLAIM_REPO CLAIM_OWNER_ID
              . "$HERE/claims.sh"
              _claim_commit peerbox "$(( $(date +%s) + 600 ))" )"
    [ -n "$peerc" ] || bad "chain-merge: could not mint the peer's claim for the fencing case"
    git -C "$RL2/repo" push -q origin "$peerc:refs/claims/issue-42"
    printf '%s\n' "$stale" > "$RL2/o/state/issueclaim-42"
    ( O="$RL2/o"; LOG="$RL2/o/log"; N=42; REPO="$RL2/repo"; CLAIM_REPO="$RL2/repo"
      export O LOG N REPO CLAIM_REPO
      . "$RL2/o/claims.sh"; . "$T/release.sh"; release_issue_claim ) >/dev/null 2>&1
    after_stale="$(git -C "$RL2/repo" ls-remote origin refs/claims/issue-42 | awk '{print $1}')"
    [ "$after_stale" = "$peerc" ] && ok "chain-merge: a STALE holder cannot delete the WINNER's issue claim (fenced)" \
                                   || bad "chain-merge: the fenced release deleted a peer's claim (${after_stale:-<gone>} vs $peerc)"
    # ⛔ GENERATION GUARD (2026-10-16 review). The handover record is keyed on the ISSUE, so the SAME
    # box can become the holder again while this chain is still alive (its lease lapsed; the chain is
    # still waiting on a PR) — and the re-acquire OVERWRITES the record with the new commit. A trap
    # that read the file when it FIRED would then fence on that NEWER commit, which IS the ref tip, so
    # the OLD chain would delete the claim of the chain that legitimately holds it and a peer would
    # read the issue as free: the duplicate this registry exists to prevent, and a fail-OPEN.
    # The chain captured ITS OWN commit at start; the mismatch must refuse the release AND leave the
    # newer generation's record alone (that chain still has to release its own claim).
    RL3="$T/rl-generation"; mkdir -p "$RL3/o/state" "$RL3/repo"
    git init -q --bare "$RL3/origin.git"; git init -q "$RL3/repo"
    git -C "$RL3/repo" remote add origin "$RL3/origin.git"
    cp "$HERE/claims.sh" "$RL3/o/claims.sh"
    older="$( cd "$RL3/repo" || exit 1
              CLAIM_REPO="$RL3/repo"; CLAIM_OWNER_ID=selfbox; export CLAIM_REPO CLAIM_OWNER_ID
              . "$HERE/claims.sh"
              _claim_commit selfbox "$(( $(date +%s) - 60 ))" )"
    newer="$( cd "$RL3/repo" || exit 1
              CLAIM_REPO="$RL3/repo"; CLAIM_OWNER_ID=selfbox; export CLAIM_REPO CLAIM_OWNER_ID
              . "$HERE/claims.sh"
              _claim_commit selfbox "$(( $(date +%s) + 600 ))" )"
    [ -n "$older" ] && [ -n "$newer" ] || bad "chain-merge: could not mint both generations for the guard case"
    git -C "$RL3/repo" push -q origin "$newer:refs/claims/issue-42"
    printf '%s\n' "$newer" > "$RL3/o/state/issueclaim-42"
    ( O="$RL3/o"; LOG="$RL3/o/log"; N=42; REPO="$RL3/repo"; CLAIM_REPO="$RL3/repo"
      CHAIN_CLAIM_COMMIT="$older"; export O LOG N REPO CLAIM_REPO CHAIN_CLAIM_COMMIT
      . "$RL3/o/claims.sh"; . "$T/release.sh"; release_issue_claim ) >/dev/null 2>&1
    gen_left="$(git -C "$RL3/repo" ls-remote origin refs/claims/issue-42 | awk '{print $1}')"
    [ "$gen_left" = "$newer" ] && ok "chain-merge: an OLDER chain cannot release the NEWER generation's claim (generation guard)" \
                               || bad "chain-merge: the older chain deleted the newer generation's claim (${gen_left:-<gone>} vs $newer)"
    [ -e "$RL3/o/state/issueclaim-42" ] && ok "chain-merge: the newer generation's record is left for ITS own release" \
                                        || bad "chain-merge: the generation-refused release consumed the newer generation's record"
    # ⛔ THE CAPTURE IS WIRED, NOT JUST THE GUARD (cycle-2 adversarial review). Every case above
    # INJECTS CHAIN_CLAIM_COMMIT, so deleting chain-merge.sh's capture line would leave them all GREEN
    # while the guard went INERT in production: the trap would pass an empty expectation, so the
    # release would fence on the record's CURRENT value — the live holder's own commit, which IS the
    # ref tip — and delete it. Drive the SHIPPED capture statement itself, with the record present.
    cap_line="$(sed -n '/^CHAIN_CLAIM_COMMIT=/p' "$HERE/chain-merge.sh" | head -1)"
    if [ -z "$cap_line" ]; then
      bad "chain-merge: the generation CAPTURE is GONE from the shipped script — the guard would be inert in production"
    else
      cap_val="$( cd / && O="$RL3/o" N=42 REPO="$RL3/repo" CLAIM_REPO="$RL3/repo"
                  eval "$cap_line" >/dev/null 2>&1
                  printf '%s' "${CHAIN_CLAIM_COMMIT:-}" )"
      [ "$cap_val" = "$newer" ] \
        && ok "chain-merge: the shipped capture reads THIS box's recorded generation (the guard is WIRED)" \
        || bad "chain-merge: the shipped capture returned '${cap_val:-<empty>}' (want $newer) — the generation guard is inert in production"
    fi
else
    bad "chain-merge: could not extract release_issue_claim from the shipped script"
fi

# ── 11) dispatch-merge.sh releases the claim on the NO-CHAIN path (#1850) ─────────────────────
# The worktree could not be created, so no lane and no chain are spawned — and `chain-merge.sh`'s
# EXIT trap, the NORMAL release path, never runs. Nothing else would ever release the claim, so a
# single failed `git worktree add` would hold a FREE issue across every box for the whole lease
# (CLAIM_ISSUE_TTL, 3h) while the reaper returned the issue to a pool every box then reads as
# another box's live claim. The shipped helper is extracted and driven directly.
awk '/^release_issue_claim_unspawned\(\) \{/{f=1} f{print} f&&/^}$/{exit}' "$HERE/dispatch-merge.sh" > "$T/unspawned.sh"
if [ -s "$T/unspawned.sh" ] && grep -q 'claim_issue_release_record' "$T/unspawned.sh"; then
  ok "dispatch-merge: the no-chain release helper is extractable from the shipped script"
  NS="$T/ns"; mkdir -p "$NS/o/state" "$NS/repo"
  git init -q --bare "$NS/origin.git"; git init -q "$NS/repo"
  git -C "$NS/repo" remote add origin "$NS/origin.git"
  cp "$HERE/claims.sh" "$NS/o/claims.sh"
  nsown="$( cd "$NS/repo" || exit 1
             CLAIM_REPO="$NS/repo"; CLAIM_OWNER_ID=selfbox; export CLAIM_REPO CLAIM_OWNER_ID
             . "$HERE/claims.sh"
             _claim_commit selfbox "$(( $(date +%s) + 600 ))" )"
  git -C "$NS/repo" push -q origin "$nsown:refs/claims/issue-77"
  printf '%s\n' "$nsown" > "$NS/o/state/issueclaim-77"
  ( O="$NS/o"; REPO="$NS/repo"; CLAIM_REPO="$NS/repo"; export O REPO CLAIM_REPO
    . "$NS/o/claims.sh"; . "$T/unspawned.sh"; release_issue_claim_unspawned 77 ) >/dev/null 2>&1
  ns_left="$(git -C "$NS/repo" ls-remote origin 'refs/claims/*' | wc -l | tr -d ' ')"
  [ "$ns_left" = "0" ] && ok "dispatch-merge: the no-chain path RELEASES the issue claim" \
                       || bad "dispatch-merge: the issue claim survived the no-chain path ($ns_left refs)"
  [ ! -e "$NS/o/state/issueclaim-77" ] && ok "dispatch-merge: the release record is consumed" \
                                       || bad "dispatch-merge: the release record was left behind"
  # An EMPTY record must delete NOTHING: it cannot fence, and an unfenced delete would remove a
  # peer's claim, which is the one thing the fence exists to prevent.
  NS2="$T/ns-empty"; mkdir -p "$NS2/o/state" "$NS2/repo"
  git init -q --bare "$NS2/origin.git"; git init -q "$NS2/repo"
  git -C "$NS2/repo" remote add origin "$NS2/origin.git"
  cp "$HERE/claims.sh" "$NS2/o/claims.sh"
  peer2="$( cd "$NS2/repo" || exit 1
            CLAIM_REPO="$NS2/repo"; CLAIM_OWNER_ID=peerbox; export CLAIM_REPO CLAIM_OWNER_ID
            . "$HERE/claims.sh"
            _claim_commit peerbox "$(( $(date +%s) + 600 ))" )"
  git -C "$NS2/repo" push -q origin "$peer2:refs/claims/issue-78"
  : > "$NS2/o/state/issueclaim-78"
  ( O="$NS2/o"; REPO="$NS2/repo"; CLAIM_REPO="$NS2/repo"; export O REPO CLAIM_REPO
    . "$NS2/o/claims.sh"; . "$T/unspawned.sh"; release_issue_claim_unspawned 78 ) >/dev/null 2>&1
  keep="$(git -C "$NS2/repo" ls-remote origin refs/claims/issue-78 | awk '{print $1}')"
  [ "$keep" = "$peer2" ] && ok "dispatch-merge: an EMPTY record cannot delete a peer's claim (no unfenced delete)" \
                         || bad "dispatch-merge: an empty record deleted or changed the claim (${keep:-<gone>} vs $peer2)"
else
  bad "dispatch-merge: could not extract release_issue_claim_unspawned from the shipped script"
fi

# ⛔ THE CHAIN-FAILURE BRANCH MUST NOT RELEASE A LANE THAT IS STILL RUNNING (cycle-2 adversarial
# review). The lane is spawned BEFORE the chain in the same loop body, so "no chain will ever run" is
# true while "nothing is running" is not: releasing there declares an issue this box is ACTIVELY
# implementing free, a peer claims it and duplicates the work, and this box still opens a PR nothing
# will merge. The branch must stop the lane first and release only once it is confirmed gone (if it
# cannot be stopped, KEEP the claim — the lease expiring it is the safe direction). The shipped
# branch is extracted and driven with a stubbed `tmux`, once for each outcome.
DM="$T/dm-branch.sh"
sed -n '/if tmux new-session -d -s "chain-/,/^  fi$/p' "$HERE/dispatch-merge.sh" > "$DM"
if [ -s "$DM" ] && grep -q 'release_issue_claim_unspawned' "$DM"; then
  ok "dispatch-merge: the chain-failure branch is extractable from the shipped script"
  # <lane alive> <kill succeeds> -> how many times the release ran
  run_branch() {
    ( N=42; O="$T/dm/o"; REPO="$T/dm/repo"; OR="owner/repo"; BR="feat/42-x"
      LANE_ALIVE="$1"; KILLABLE="$2"; released=0
      tmux() {
        case "${1:-}" in
          new-session) return 1 ;;                                  # the chain cannot start
          ls) [ "$LANE_ALIVE" = 1 ] && printf 'lane-42\n'; return 0 ;;
          kill-session) [ "$KILLABLE" = 1 ] && { LANE_ALIVE=0; return 0; }; return 1 ;;
          *) return 0 ;;
        esac
      }
      release_issue_claim_unspawned() { released=$(( released + 1 )); }
      . "$DM" >/dev/null 2>&1
      printf '%s' "$released" )
  }
  [ "$(run_branch 1 1)" = "1" ] \
    && ok "dispatch-merge: a chain that cannot start releases the claim AFTER stopping its lane" \
    || bad "dispatch-merge: the stopped-lane path did not release exactly once (got '$(run_branch 1 1)')"
  [ "$(run_branch 1 0)" = "0" ] \
    && ok "dispatch-merge: a chain that cannot start KEEPS the claim while its lane is still alive" \
    || bad "dispatch-merge: released the claim while lane-42 was STILL RUNNING — a peer would duplicate the work"
else
  bad "dispatch-merge: could not extract the chain-failure branch (or it no longer releases)"
fi

# ── 12) THE LISTINGS DRAW ON THE REST BUCKET, so a starved GraphQL bucket no longer starves the
#        READ — and a failed REST listing must FAIL, not write a short one (#1962) ────────
# THE MEASURED DEFECT. On all three cloud cells, for hours: `gh issue list` / `gh pr list` (GraphQL)
# answered `GraphQL: API rate limit already exceeded for user ID 81560491.` — one account, four boxes,
# one bucket — so every priority tier FAILED, the pass aborted UNREADABLE, and `candidates.txt` stayed
# at 0 lines. REST is a SEPARATE bucket, so the same box can list while GraphQL is exhausted. (a)
# proves that; (b) proves the other half — when REST fails too, the pass must FAIL rather than hand the
# reaper an empty `.open_iss`/`.pr_brs` or a pool that silently drops a tier.
# ⛔ WHAT IT DOES **NOT** PROVE: the
# per-candidate PRE-FLIGHT (`tools/collision_preflight.py`) still reads `gh issue view` / `gh pr list`
# and is fail-closed, so on a box where GraphQL is refused this change turns "the pool could not be
# READ" into "the pool was read and the pre-flight could not CERTIFY" — a named, later failure, NOT
# dispatch. Restoring dispatch there needs the `gh-rest` adapter on PATH (#1959/#1962), which is not
# deployed on the cells. A heading that said "no longer stops dispatch" would assert, in prose, the
# exact claim the shipped script's own comment (refresh-candidates.sh, the "WHAT THIS DOES NOT FIX"
# block) exists to deny — and no test would go red for it, because prose is not behaviour.
echo; echo "── the listings use the REST bucket: a starved GraphQL bucket no longer starves the READ ──"

# (0) THE HELPER'S OWN REFUSALS AND ITS PAGINATION ARE DRIVEN, NOT ASSUMED. `rest_list` carries five
#     fail-closed guards — an unmodelled flag, a flag with no value, a non-numeric limit, an unknown
#     listing kind, and a page that is SHORT or EMPTY while the LINK header still advertises a next
#     page. Every one is category A (each prevents a WRONG answer being read as a complete one) and
#     NONE is reachable from the five call sites, so a test that only drove the call sites would never
#     execute them. The SHIPPED helper is extracted and called directly; `run_bounded` turns "it
#     hangs" into a failure instead of wedging the suite (the pre-fix form spun for ever on a flag
#     with no value — measured). The last case is the MULTI-PAGE SUCCESS path: ten full pages, whose
#     page files are only concatenated in order if they are zero-padded (`p010` sorts before `p2`
#     otherwise), so the ordering claim is measured rather than asserted.
echo; echo "── the REST helper's own refusals ──"
run_bounded() {  # <seconds> <cmd...> — 124 means it did not finish. Output is the CALLER's business:
                 # it must not be swallowed here, or every assertion that reads a message or a row
                 # count passes vacuously (measured — that is how three of these assertions first
                 # "passed").
  local secs="$1"; shift
  "$@" & local pid=$!
  local i=0 max=$((secs * 10))
  while [ "$i" -lt "$max" ]; do
    kill -0 "$pid" 2>/dev/null || { wait "$pid" 2>/dev/null; return $?; }
    sleep 0.1; i=$((i + 1))
  done
  kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  return 124
}
{ awk '/^rest_fail\(\) \{/{f=1} f{print} f&&/^\}$/{f=0}' "$REFRESH"
  awk '/^rest_list\(\) \{/{f=1} f{print} f&&/^\}$/{f=0}' "$REFRESH"; } > "$T/rest.sh"
# the two shipped functions, extracted verbatim. A missing extraction is a FAILURE, never a skip.
if [ -s "$T/rest.sh" ]; then
  HD="$T/restcase"; mkdir -p "$HD"
  cat > "$HD/gh" <<'SH'
#!/bin/bash
# page 1: a FULL page that advertises a next page. page 2: no rows, but STILL advertises one — the
# vanished-page shape, which must be refused rather than read as the end of the collection.
case "$*" in
  # ANCHORED on `&page=1`, not `page=1`: the URL also carries `per_page=100`, whose `page=1` is a
  # PREFIX of `page=100` — an unanchored pattern answers every page with page 1's full answer and the
  # vanished-page check can then never fire (measured: n=100 on every page).
  *"&page=1"*) printf 'HTTP/2.0 200 OK\r\nLink: <x?page=2>; rel="next"\r\n\r\n'
               jq -n '[range(100)|{number:.}]' ;;
  *) printf 'HTTP/2.0 200 OK\r\nLink: <x?page=3>; rel="next"\r\n\r\n[]\n' ;;
esac
SH
  chmod +x "$HD/gh"
  # ⛔ `set -u` IS PART OF WHAT IS UNDER TEST: the shipped script sets it (refresh-candidates.sh:16),
  # so a `set -u` regression inside `rest_list` (an unguarded expansion) would be invisible to a driver
  # running with default options. Same class the install-probe driver pins for install.sh.
  cat > "$T/rr.sh" <<'RS'
set -u
. "$1"; shift
OR=acme/widget
rest_list "$@"
RS
  drv() { run_bounded 5 bash "$T/rr.sh" "$T/rest.sh" "$@"; }
  # drv_out — the same call WITHOUT the bound. `run_bounded` no longer swallows output, so both
  # preserve it; the unbounded form is used where the stub is deterministic (the risk is a wrong
  # ANSWER, not a hang), and the bounded one where the pre-fix code HUNG (a flag with no value).
  drv_out() { bash "$T/rr.sh" "$T/rest.sh" "$@"; }
  PATH="$HD:$PATH"; export PATH
  drv issues --repo acme/widget --json number > /dev/null 2>"$HD/err"; rc=$?
  [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ] && ok "rest_list refuses an UNMODELLED flag (rc=$rc, no hang) — a dropped filter is a wrong answer" \
                  || bad "rest_list accepted/dropped an unmodelled flag (rc=$rc)"
  drv issues --repo acme/widget --limit > /dev/null 2>"$HD/err"; rc=$?
  # ⛔ THE MESSAGE, NOT THE STATUS. Under this driver's `set -u` the UNGUARDED form also exits non-zero
  # (`$2: unbound variable` — measured), so an rc-only assertion stays green with the guard deleted,
  # while a caller that does NOT run `set -u` spins for ever (measured: still running after 6 s). The
  # guard's own words are the only thing that separates "the helper refused" from "the shell aborted".
  grep -q "listing flag '--limit' needs a value" "$HD/err" 2>/dev/null && noval=1 || noval=0
  [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ] && [ "$noval" -eq 1 ] \
    && ok "rest_list refuses a flag with NO VALUE AT THE GUARD (rc=$rc, 'needs a value') instead of spinning for ever" \
    || bad "rest_list did not refuse a value-less flag at the guard (rc=$rc; 124 = it hung; message='$(head -1 "$HD/err")')"
  drv issues --repo acme/widget --limit abc > /dev/null 2>"$HD/err"; rc=$?
  # ⛔ THE MESSAGE, NOT JUST THE STATUS: without the guard the helper pages and then dies inside the
  # final `jq --argjson limit abc` (measured rc=2, "invalid JSON text passed to --argjson") — a
  # non-zero rc that has nothing to do with a limit being unbounded.
  grep -q 'is not a number' "$HD/err" 2>/dev/null && lim_msg=1 || lim_msg=0
  [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ] && [ "$lim_msg" -eq 1 ] \
    && ok "rest_list refuses a NON-NUMERIC limit AT THE GUARD (rc=$rc, 'is not a number') rather than paging unbounded" \
    || bad "rest_list did not refuse a non-numeric limit at the guard (rc=$rc, message='$(head -1 "$HD/err")')"
  drv widgets > /dev/null 2>"$HD/err"; rc=$?
  [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ] && ok "rest_list refuses an UNKNOWN listing kind (rc=$rc)" \
                  || bad "rest_list accepted an unknown listing kind (rc=$rc)"
  drv_out issues --repo acme/widget --limit 500 --jq '.[].number' > "$HD/out" 2>"$HD/err"; rc=$?
  [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ] && ok "rest_list REFUSES a vanished page (LINK still advertises a next page, body has none)" \
                  || bad "rest_list read a vanished page as the end of the collection (rc=$rc) — a truncated listing at rc 0"
  # ⛔ WHICH GUARD FIRED, because two of them cover this shape on a middle page: the short-page guard
  # (`n < 100`) also catches `n == 0`, so an assertion on rc alone stays green if the VANISH half is
  # deleted. The `page == pages` case below is the one only the vanish guard can catch.
  grep -q 'answered with 0 rows' "$HD/err" 2>/dev/null && ok "the refusal is the VANISHED-PAGE one ('answered with 0 rows'), not the short-page one" \
                                                        || bad "the vanished-page case was refused by another guard: '$(head -1 "$HD/err")'"
  # ── the LAST requested page vanishing: the short-page guard is gated out here (`page < pages`), so
  # only the vanish guard stands between the caller and 400 of 500 rows at rc 0 (measured on the
  # pre-fix helper: rc=0, rows=400).
  HDL="$T/restcase-lastvanish"; mkdir -p "$HDL"
  cat > "$HDL/gh" <<'SH'
#!/bin/bash
pg="$(printf '%s' "$*" | sed -n 's/.*&page=\([0-9]*\).*/\1/p')"; [ -n "$pg" ] || pg=1
if [ "$pg" -lt 5 ]; then
  printf 'HTTP/2.0 200 OK\r\nLink: <x?page=%s>; rel="next"\r\n\r\n' "$((pg+1))"
  jq -n --argjson p "$pg" '[range(100)|{number: (($p-1)*100 + .)}]'
else
  # the last page requested (limit 500 -> 5 pages) answers EMPTY while still advertising a next page
  printf 'HTTP/2.0 200 OK\r\nLink: <x?page=6>; rel="next"\r\n\r\n[]\n'
fi
SH
  chmod +x "$HDL/gh"
  PATH="$HDL:$PATH"; export PATH
  drv_out issues --repo acme/widget --limit 500 --jq '.[].number' > "$HDL/out" 2>"$HDL/err"; rc=$?
  PATH="${PATH#$HDL:}"; export PATH
  [ "$rc" -ne 0 ] && [ ! -s "$HDL/out" ] \
    && ok "rest_list refuses a VANISHED LAST PAGE instead of returning the 400 rows it had (rc=$rc, 0 rows emitted)" \
    || bad "a vanished last page returned $(wc -l < "$HDL/out") row(s) at rc=$rc — a 500-row listing truncated to 400 ($(head -1 "$HDL/err"))"
  # ⛔ The LAST PAGE case must also be refused BY THE VANISH GUARD, not by a transport error: with the
  # stub's `[]`+next answer a broken stub (measured, while the stub itself was malformed) returned
  # rc=1 with an empty body and the assertion above passed for the wrong reason.
  grep -q 'answered with 0 rows' "$HDL/err" 2>/dev/null && ok "the last-page refusal is the VANISHED-PAGE one, with the 400 rows already read" \
                                                        || bad "the last-page case was refused by another path: '$(head -1 "$HDL/err")'"
  PATH="${PATH#$HD:}"; export PATH
  [ ! -s "$HD/out" ] && ok "rest_list emits NO rows for a refused listing (nothing for a caller to mistake for an answer)" \
                     || bad "rest_list emitted rows while refusing: $(head -2 "$HD/out" | tr '\n' ' ')"

  # ── a SHORT page that still advertises a next page is a stripped page, not the end ─────────────
  # GitHub returns exactly per_page rows on every page but the last, so 40 rows + `rel="next"` is the
  # shape a filtering intermediary produces. Read as a complete listing it returns a SHORT `.pr_brs`
  # at rc 0, which makes `has_pr` false for issues that DO have a PR (#1705) — the same hazard as an
  # empty one, just quieter.
  HD2="$T/restcase-short"; mkdir -p "$HD2"
  cat > "$HD2/gh" <<'SH'
#!/bin/bash
printf 'HTTP/2.0 200 OK\r\nLink: <x?page=2>; rel="next"\r\n\r\n'
jq -n '[range(40)|{number:.}]'
SH
  chmod +x "$HD2/gh"
  PATH="$HD2:$PATH"; export PATH
  drv_out issues --repo acme/widget --limit 500 --jq '.[].number' > "$HD2/out" 2>"$HD2/err"; rc=$?
  PATH="${PATH#$HD2:}"; export PATH
  # ⛔ BY MESSAGE, like the vanish cases: a stub that simply FAILS also yields rc≠0, and that false
  # PASS was measured (a broken stub answered nothing and both this and the empty-body case went green).
  grep -q 'a short page is not a complete listing' "$HD2/err" 2>/dev/null && short_msg=1 || short_msg=0
  [ "$rc" -ne 0 ] && [ "$short_msg" -eq 1 ] \
    && ok "rest_list REFUSES a SHORT page that still advertises a next page (rc=$rc, 'not a complete listing')" \
    || bad "rest_list did not refuse a short page at the guard (rc=$rc, message='$(head -1 "$HD2/err")', rows=$(wc -l < "$HD2/out"))"
  [ ! -s "$HD2/out" ] && ok "the short-page refusal emits NO rows either" \
                      || bad "the short-page refusal still emitted $(wc -l < "$HD2/out") row(s)"

  # ── the `--label` is URL-ENCODED: an unencoded `&` INJECTS a query parameter ────────────────────
  # ⛔ PINNED BY NOTHING BEFORE THIS CASE (review, MEASURED): replacing the `jq -Rr @uri` encoding
  # with the raw value left the suite GREEN, while the request became a DIFFERENT question —
  # `--label 'a&b c'` sends `labels=a&b c=` and the tier reads as EMPTY, which is the #8465 priority
  # inversion the guard's own comment names. The assertion reads the WIRE (the argv the stub received),
  # not the flag, so it cannot pass on a label that merely looks encoded.
  HDQ="$T/restcase-label"; mkdir -p "$HDQ"
  cat > "$HDQ/gh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$(dirname "$0")/url"
printf 'HTTP/2.0 200 OK\r\n\r\n[]\n'
SH
  chmod +x "$HDQ/gh"
  PATH="$HDQ:$PATH"; export PATH
  drv_out issues --repo acme/widget --limit 10 --label 'a&b c' > /dev/null 2>"$HDQ/err"; rc=$?
  PATH="${PATH#$HDQ:}"; export PATH
  url="$(head -1 "$HDQ/url" 2>/dev/null)"
  case "$url" in
    *'labels=a%26b%20c'*) ok "the --label is URL-ENCODED on the wire (an '&' cannot inject a parameter)" ;;
    *) bad "the label reached the API UNENCODED — a label with '&' changes the query: '$url' (rc=$rc)" ;;
  esac

  # ── an EMPTY body on a 200 is a vanished body, not 'no rows' ────────────────────────────────
  # Real `gh api -i` answers an empty collection with headers + `[]`. Only 204/304 may carry no body,
  # so a 200 with nothing after the headers must be refused: read as 'no rows' it writes an EMPTY
  # `.pr_brs` at rc 0 — the #1705 trigger the reaper's absence-vs-empty rule exists to shut.
  HD3="$T/restcase-empty"; mkdir -p "$HD3"
  printf '#!/bin/bash\nprintf "HTTP/2.0 200 OK\\r\\ncontent-type: application/json\\r\\n\\r\\n"\n' > "$HD3/gh"
  chmod +x "$HD3/gh"
  PATH="$HD3:$PATH"; export PATH
  drv_out pulls --repo acme/widget --limit 10 --jq '.[]|.head.ref' > "$HD3/out" 2>"$HD3/err"; rc=$?
  PATH="${PATH#$HD3:}"; export PATH
  grep -q 'with an EMPTY body' "$HD3/err" 2>/dev/null && empty_msg=1 || empty_msg=0
  [ "$rc" -ne 0 ] && [ "$empty_msg" -eq 1 ] \
    && ok "rest_list REFUSES a 200 with an EMPTY body (rc=$rc, 'EMPTY body') — 'no content' is 204, not an empty 200" \
    || bad "rest_list did not refuse a bodyless 200 at the guard (rc=$rc, message='$(head -1 "$HD3/err")') — that writes an empty .pr_brs"
  # …and the legitimate no-content shape is still a valid empty answer
  HD4="$T/restcase-204"; mkdir -p "$HD4"
  printf '#!/bin/bash\nprintf "HTTP/2.0 204 No Content\\r\\n\\r\\n"\n' > "$HD4/gh"
  chmod +x "$HD4/gh"
  PATH="$HD4:$PATH"; export PATH
  drv_out pulls --repo acme/widget --limit 10 --jq '.[]|.head.ref' > "$HD4/out" 2>"$HD4/err"; rc=$?
  PATH="${PATH#$HD4:}"; export PATH
  [ "$rc" -eq 0 ] && [ ! -s "$HD4/out" ] && ok "rest_list accepts a 204 as a real empty answer (rc=0, no rows)" \
                                      || bad "rest_list did not accept a 204 (rc=$rc, out=$(wc -l < "$HD4/out") rows)"

  # ── A 403 IS NOT NECESSARILY A RATE LIMIT (rest_fail has three branches; the whole-script case
  #    only ever reaches the rate-limit one, because its stub says "rate limit"). Deleting the
  #    permission branch would silently collapse two different diagnoses into the generic message,
  #    and the suite would stay green — measured.
  HD403="$T/restcase-403"; mkdir -p "$HD403"
  printf '#!/bin/bash\necho "gh: Resource not accessible by integration (HTTP 403)" >&2\nexit 1\n' > "$HD403/gh"
  chmod +x "$HD403/gh"
  PATH="$HD403:$PATH"; export PATH
  drv_out issues --repo acme/widget --limit 10 > /dev/null 2>"$HD403/err"; rc=$?
  PATH="${PATH#$HD403:}"; export PATH
  grep -q 'HTTP 403 with no rate-limit wording' "$HD403/err" 2>/dev/null && perm_msg=1 || perm_msg=0
  [ "$rc" -ne 0 ] && [ "$perm_msg" -eq 1 ] \
    && ok "rest_fail names a PERMISSION 403 as such, and does not call it a rate limit" \
    || bad "rest_fail mis-diagnosed a permission 403: '$(head -1 "$HD403/err")'"
  # ── A RATE LIMIT IS NOT ALWAYS A 403, AND THE LOG MUST NOT INVENT ONE. GitHub answers secondary
  #    limits with 429; the branch used to print a hardcoded "HTTP 403" and drop the provider's text,
  #    which is the only evidence of the real status. Both halves are asserted: the status comes from
  #    the message, and the message is carried.
  # ⛔ THE BODY IS LONGER THAN THE LOG'S 240-CHAR CUT ON PURPOSE. GitHub's secondary-limit text carries
  # a variable-length request-ID/timestamp tail, so on the real thing the "(HTTP 429)" sits past the
  # truncation — parsing the status out of the truncated copy reads `HTTP ?` and this case is the only
  # one that can see it (a short body passes either way).
  HD429="$T/restcase-429"; mkdir -p "$HD429"
  cat > "$HD429/gh" <<'GH429'
#!/bin/bash
echo "gh: You have exceeded a secondary rate limit. Please wait a few minutes before you try again. For more information on scraping GitHub and how it may affect your use of GitHub's features, please see https://docs.github.com/get-started/using-github/githubs-terms-of-service . request ID 5A1B:2C3D:4E5F:6789:ABCD:EF01 and timestamp 2026-10-17T22:27:11.123Z. (HTTP 429)" >&2
exit 1
GH429
  chmod +x "$HD429/gh"
  PATH="$HD429:$PATH"; export PATH
  drv_out issues --repo acme/widget --limit 10 > /dev/null 2>"$HD429/err"; rc=$?
  PATH="${PATH#$HD429:}"; export PATH
  [ "$rc" -ne 0 ] && grep -q 'RATE-LIMITED (HTTP 429' "$HD429/err" 2>/dev/null \
    && ok "rest_fail reads a 429 rate limit AS a 429 (not a hardcoded 403)" \
    || bad "rest_fail mis-stated a 429 rate limit: '$(head -1 "$HD429/err")'"
  grep -q 'HTTP 403' "$HD429/err" 2>/dev/null \
    && bad "rest_fail claimed HTTP 403 for a 429 — the log now names a cause the provider never gave" \
    || ok "rest_fail does not claim HTTP 403 for a 429"
  grep -q 'secondary rate limit' "$HD429/err" 2>/dev/null \
    && ok "rest_fail carries the provider's own words through the rate-limit branch" \
    || bad "rest_fail dropped the provider's message in the rate-limit branch: '$(head -1 "$HD429/err")'"
  HD404="$T/restcase-generic"; mkdir -p "$HD404"
  printf '#!/bin/bash\necho "gh: something else went wrong" >&2\nexit 1\n' > "$HD404/gh"
  chmod +x "$HD404/gh"
  PATH="$HD404:$PATH"; export PATH
  drv_out issues --repo acme/widget --limit 10 > /dev/null 2>"$HD404/err"; rc=$?
  PATH="${PATH#$HD404:}"; export PATH
  grep -q 'listing FAILED (page 1)' "$HD404/err" 2>/dev/null && gen_msg=1 || gen_msg=0
  [ "$rc" -ne 0 ] && [ "$gen_msg" -eq 1 ] \
    && ok "rest_fail falls back to the generic PAGE-naming refusal for anything else" \
    || bad "rest_fail did not fall back to the generic refusal: '$(head -1 "$HD404/err")'"

  # ── A SHORT LAST PAGE WITH A NEXT PAGE IS A TRUNCATION, not the end of the collection ────────
  # The shape a PAGE-POSITION exemption misses: `--limit 500` reads 5 pages, pages 1-4 are full, page 5
  # returns 40 rows and STILL advertises page 6. Measured on the position-gated helper: rc=0 with 440
  # rows — a truncated `.pr_brs`, which makes `has_pr` false for issues that DO have a PR (#1705). The
  # exemption must be a FILLED WINDOW, not "we happen to be on the last page".
  HDS="$T/restcase-shortlast"; mkdir -p "$HDS"
  cat > "$HDS/gh" <<'SH'
#!/bin/bash
pg="$(printf '%s' "$*" | sed -n 's/.*&page=\([0-9]*\).*/\1/p')"; [ -n "$pg" ] || pg=1
printf 'HTTP/2.0 200 OK\r\nLink: <x?page=%s>; rel="next"\r\n\r\n' "$((pg+1))"
if [ "$pg" -lt 5 ]; then jq -n --argjson p "$pg" '[range(100)|{number: (($p-1)*100 + .)}]'
else jq -n '[range(40)|{number: (400 + .)}]'; fi
SH
  chmod +x "$HDS/gh"
  PATH="$HDS:$PATH"; export PATH
  drv_out issues --repo acme/widget --limit 500 --jq '.[].number' > "$HDS/out" 2>"$HDS/err"; rc=$?
  PATH="${PATH#$HDS:}"; export PATH
  grep -q 'a short page is not a complete listing' "$HDS/err" 2>/dev/null && sl_msg=1 || sl_msg=0
  [ "$rc" -ne 0 ] && [ "$sl_msg" -eq 1 ] \
    && ok "rest_list REFUSES a short LAST page that still advertises a next page (rc=$rc, window not filled)" \
    || bad "a short last page returned $(wc -l < "$HDS/out") row(s) at rc=$rc — a 500-row window truncated to 440"

  # ── …while a FULL last page that advertises a next page is FINE (the window is filled) ───────
  # The other side of the same branch: refusing here would break every multi-page listing whose window
  # ends exactly on a page boundary — the common case, since all five shipped limits are multiples of
  # 100. Without this case, over-tightening the guard to "any next link on the last page" stays green.
  HDF="$T/restcase-fullwindow"; mkdir -p "$HDF"
  cat > "$HDF/gh" <<'SH'
#!/bin/bash
pg="$(printf '%s' "$*" | sed -n 's/.*&page=\([0-9]*\).*/\1/p')"; [ -n "$pg" ] || pg=1
printf 'HTTP/2.0 200 OK\r\nLink: <x?page=%s>; rel="next"\r\n\r\n' "$((pg+1))"
jq -n --argjson p "$pg" '[range(100)|{number: (($p-1)*100 + .)}]'
SH
  chmod +x "$HDF/gh"
  PATH="$HDF:$PATH"; export PATH
  drv_out issues --repo acme/widget --limit 500 --jq '.[].number' > "$HDF/out" 2>"$HDF/err"; rc=$?
  PATH="${PATH#$HDF:}"; export PATH
  [ "$rc" -eq 0 ] && [ "$(wc -l < "$HDF/out")" -eq 500 ] \
    && ok "a FULL last page that advertises a next page is ACCEPTED (rc=0, 500 rows — the window is filled)" \
    || bad "a full last page was refused/miscounted: rc=$rc, rows=$(wc -l < "$HDF/out") — $(head -1 "$HDF/err")"

  # ── THE SMALL-LIMIT EXEMPTION: a `--limit 10` caller must not be refused over a next page ────────────────────
  # A one-page caller (`--limit 10`) that gets 40 rows and a `rel="next"` must NOT be refused: the
  # next page is one it never asked for. Without the exemption the short-page guard would refuse every
  # small-limit listing on a busy repo; nothing else in this block exercises that branch (the 40-row
  # case above asks for 500, so it refuses on the short-page rule regardless).
  HD10="$T/restcase-limit10"; mkdir -p "$HD10"
  cat > "$HD10/gh" <<'SH'
#!/bin/bash
printf 'HTTP/2.0 200 OK\r\nLink: <x?page=2>; rel="next"\r\n\r\n'
jq -n '[range(40)|{number:.}]'
SH
  chmod +x "$HD10/gh"
  PATH="$HD10:$PATH"; export PATH
  drv_out issues --repo acme/widget --limit 10 --jq '.[].number' > "$HD10/out" 2>"$HD10/err"; rc=$?
  PATH="${PATH#$HD10:}"; export PATH
  [ "$rc" -eq 0 ] && [ "$(wc -l < "$HD10/out")" -eq 10 ] \
    && ok "a --limit 10 caller is NOT refused over a next page it never asked for (rc=0, 10 rows)" \
    || bad "the page<pages exemption is broken: rc=$rc, rows=$(wc -l < "$HD10/out") — $(head -1 "$HD10/err")"

  # ── /issues RETURNS PULL REQUESTS: they must not become DISPATCH CANDIDATES ─────────────────────
  # Both kinds, because the rule is ASYMMETRIC and deleting it stayed green before these cases: the
  # `map(select(has("pull_request") | not))` filter had no assertion of its own (measured: replacing
  # it with `(.)` left the suite GREEN). The hazard is the POOL, not
  # the reaper — a labelled PR passes the tier programs (`no assignee, non-epic title`), is queued as
  # `0 <PR#>`, enters `dispatched.txt`, and a lane is spawned for a PR number. `kind=pulls` must keep
  # every row: `.pr_brs` feeds the #1705 `has_pr` check.
  HDP="$T/restcase-prrows"; mkdir -p "$HDP"
  cat > "$HDP/gh" <<'SH'
#!/bin/bash
printf 'HTTP/2.0 200 OK\r\n\r\n'
case "$*" in
  *"/pulls"*) jq -n '[{"number":900,"pull_request":{"url":"u"},"head":{"ref":"pr-branch"}},{"number":901,"head":{"ref":"pr-branch-2"}}]' ;;
  *)          jq -n '[{"number":41,"title":"a real issue"},{"number":900,"title":"a PR","pull_request":{"url":"u"}}]' ;;
esac
SH
  chmod +x "$HDP/gh"
  PATH="$HDP:$PATH"; export PATH
  drv_out issues --repo acme/widget --limit 10 --jq '.[].number' > "$HDP/out" 2>"$HDP/err"; rc=$?
  [ "$rc" -eq 0 ] && [ "$(cat "$HDP/out")" = "41" ] \
    && ok "kind=issues DROPS the pull_request row and keeps the real issue (out=$(tr '\n' ' ' < "$HDP/out"))" \
    || bad "kind=issues did not drop the PR row: rc=$rc, out=$(tr '\n' ' ' < "$HDP/out") — $(head -1 "$HDP/err")"
  drv_out pulls --repo acme/widget --limit 10 --jq '.[]|.head.ref' > "$HDP/out2" 2>"$HDP/err"; rc=$?
  PATH="${PATH#$HDP:}"; export PATH
  [ "$rc" -eq 0 ] && [ "$(wc -l < "$HDP/out2")" -eq 2 ] \
    && ok "kind=pulls KEEPS every row (2 head refs — .pr_brs is deliberately unfiltered)" \
    || bad "kind=pulls dropped a row: rc=$rc, out=$(tr '\n' ' ' < "$HDP/out2") — $(head -1 "$HDP/err")"

  # ── THE MULTI-PAGE SUCCESS PATH, in order ──────────────────────────────────────────────────
  # Ten full pages. The page files are concatenated by a GLOB, so this only comes back in order if
  # they are ZERO-PADDED — plain `p*.json` sorts `p10` BEFORE `p2`, and `.[0:$limit]` would then
  # truncate rows from the wrong pages. The numbers are page-continuous, so a mis-ordered
  # concatenation is visible in the sequence, not just in the count.
  HD5="$T/restcase-pages"; mkdir -p "$HD5"
  cat > "$HD5/gh" <<'SH'
#!/bin/bash
pg="$(printf '%s' "$*" | sed -n 's/.*&page=\([0-9]*\).*/\1/p')"
[ -n "$pg" ] || pg=1
if [ "$pg" -lt 10 ]; then nxt="Link: <x?page=$((pg+1))>; rel=\"next\"\r\n"; else nxt=""; fi
printf "HTTP/2.0 200 OK\r\n$nxt\r\n"
jq -n --argjson p "$pg" '[range(100)|{number: (($p-1)*100 + .)}]'
SH
  chmod +x "$HD5/gh"
  PATH="$HD5:$PATH"; export PATH
  drv_out issues --repo acme/widget --limit 1000 --jq '.[].number' > "$HD5/out" 2>"$HD5/err"; rc=$?
  PATH="${PATH#$HD5:}"; export PATH
  [ "$rc" -eq 0 ] && [ "$(wc -l < "$HD5/out")" -eq 1000 ] && ok "rest_list reads 10 pages and returns all 1000 rows (rc=0)" \
                  || bad "multi-page read: rc=$rc, rows=$(wc -l < "$HD5/out") (want 1000) — $(head -2 "$HD5/err" | tr '\n' ' ')"
  [ "$(head -1 "$HD5/out")" = "0" ] && [ "$(tail -1 "$HD5/out")" = "999" ] && ok "the pages are concatenated IN ORDER (first=0, last=999)" \
                  || bad "page order is wrong: first='$(head -1 "$HD5/out")' last='$(tail -1 "$HD5/out")' (want 0 and 999) — a plain p*.json glob sorts p010 before p2"
  # sorted -n -c: 0 when the file is already numerically ascending; uniq -d catches a duplicate page.
  sort -n -c "$HD5/out" 2>/dev/null; mono=$?
  dup="$(sort -n "$HD5/out" | uniq -d | head -1)"
  [ "$mono" -eq 0 ] && [ -z "$dup" ] && ok "the 1000 rows are strictly monotonic (no page duplicated, dropped or reordered)" \
                                     || bad "rows are not monotonic across pages (sorted-check=$mono, first dup='$dup')"
else
  bad "the REST helper could not be extracted from refresh-candidates.sh — the refusals are untested"
fi

# (a) GraphQL EXHAUSTED, REST healthy -> the backlog is built anyway, and NOT ONE GraphQL call is
#     made. The stub records every gh invocation, so "the transport changed" is asserted structurally
#     rather than by reading a log line the script could print while still calling GraphQL.
mk_case rest-carries-a-starved-graphql
mk_tool "$D/repo/.worktrees/dispatch-scout/tools/collision_preflight.py"
cat > "$D/bin/gh.body" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_LOG"
case "$*" in
  "auth token") exit 0 ;;
  *" rate_limit"*) printf '%s\n' '{"resources":{"core":{"remaining":4321},"graphql":{"remaining":0}}}'; exit 0 ;;
  *"/pulls?"*) printf '[]\n'; exit 0 ;;
  *"labels=P0-blocker"*) printf '[{"number":42,"title":"a pool candidate","assignees":[]}]\n'; exit 0 ;;
  *"/issues?"*) printf '[]\n'; exit 0 ;;
esac
# Every GraphQL VERB FORM (what the pre-fix script used) answers the cells' own refusal.
echo 'GraphQL: API rate limit already exceeded for user ID 81560491.' >&2
exit 1
SH
chmod +x "$D/bin/gh"
rf "$D" refresh GH_LOG="$D/gh-calls"
[ "$RC" -eq 0 ] && ok "starved-graphql: the pass SUCCEEDS on REST (rc=0) — a starved bucket is not a broken box" \
               || bad "starved-graphql: rc=$RC (want 0) — REST answered and the pass still refused — output: $OUT"
case "$(tr '\n' ' ' < "$D/o/candidates.txt" 2>/dev/null)" in
  *42*) ok "starved-graphql: the candidate list IS built from the REST listing (#42 queued)" ;;
  *) bad "starved-graphql: no candidate was queued — candidates='$(cat "$D/o/candidates.txt" 2>/dev/null)'" ;;
esac
case "$OUT" in
  *"transport=REST"*) ok "starved-graphql: the log NAMES the transport it used" ;;
  *) bad "starved-graphql: the log does not say which transport ran — output: $OUT" ;;
esac
case "$OUT" in
  *"GraphQL remaining=0"*) ok "starved-graphql: the log reports the EXHAUSTED GraphQL bucket next to the working one" ;;
  *) bad "starved-graphql: the bucket state is not reported (a reader cannot tell starved from broken) — output: $OUT" ;;
esac
gql_calls="$(grep -cE '^(issue list|pr list)' "$D/gh-calls" 2>/dev/null | tr -d ' ')"
[ "${gql_calls:-1}" = "0" ] && ok "starved-graphql: ZERO GraphQL listings were attempted (the transport really changed)" \
                          || bad "starved-graphql: $gql_calls GraphQL listing call(s) were still made — $(tr '\n' ' ' < "$D/gh-calls" 2>/dev/null)"
grep -qE '^api repos/.*/issues\?.*labels=P0-blocker' "$D/gh-calls" 2>/dev/null \
  && ok "starved-graphql: the tier query is a REST call carrying its --label filter" \
  || bad "starved-graphql: the tier query is not a filtered REST call — $(tr '\n' ' ' < "$D/gh-calls" 2>/dev/null)"
# ⛔ THE `--state` IS PART OF THE QUESTION AND WAS PINNED BY NOTHING (review, MEASURED): deleting
# `--state all` from the `.pr_brs` call left the whole suite GREEN, and `GET /repos/{o}/{r}/pulls`
# DEFAULTS to `state=open` — so a PR closed WITHOUT merging loses its head branch from `.pr_brs`,
# `has_pr` reads false for an issue that always had a PR, and the reaper UN-blacklists it: the
# duplicate-dispatch class (#1705) this listing exists to prevent, at rc 0. The issue listings' own
# `state=open` is pinned for the mirror reason — a wider window is a different pool, not a bigger one.
grep -qE '^api repos/[^ ]*/pulls\?state=all(&|$)' "$D/gh-calls" 2>/dev/null \
  && ok "starved-graphql: .pr_brs asks for state=all — a CLOSED PR still carries the branch has_pr needs" \
  || bad "the pulls listing does not ask state=all — .pr_brs would silently lose closed-PR branches (got: $(grep -oE 'pulls\?[^ ]*' "$D/gh-calls" 2>/dev/null | head -1))"
# ⛔ EVERY issue listing, not the FIRST one (review, MEASURED). A pattern on `issues?state=open` alone
# is satisfied by the three tier calls, so widening the reaper's `.open_iss` window to `state=all`
# printed ✅ and shipped green (measured: `PASS=229 FAIL=0` with the wider call site) — the assertion
# then pins a question it does not ask. Both halves matter and neither is a superset: the unlabelled
# `.open_iss` window and the labelled tiers all narrow the pool, so a wider one puts closed issues in
# front of dispatch and the reaper (#1705, #8465). Order-independent, so a harmless reorder of the
# query string does not red it.
issues_not_open="$(grep -E '^api repos/[^ ]*/issues\?' "$D/gh-calls" 2>/dev/null | grep -v 'state=open' | head -2 | tr '\n' ' ')"
[ -z "$issues_not_open" ] \
  && ok "starved-graphql: EVERY issue listing asks state=open (the unlabelled reaper window AND the three tiers)" \
  || bad "an issue listing does not ask state=open — a wider window lists closed issues for dispatch (#1705/#8465): $issues_not_open"

# (b) REST ALSO FAILING (HTTP 403, rate limited) -> TRANSIENT, and NOTHING written: no `.open_iss`, no
#     `.pr_brs`, and the seeded backlog untouched. A truncated or empty listing here is the #1705 bug
#     (an empty `.open_iss`/`.pr_brs` un-blacklists issues that DO have a PR) and the #8465 inversion.
mk_case rest-fails-too
mk_tool "$D/repo/.worktrees/dispatch-scout/tools/collision_preflight.py"
cat > "$D/bin/gh.body" <<'SH'
#!/bin/bash
case "$*" in
  "auth token") exit 0 ;;
  *" rate_limit"*) printf '%s\n' '{"resources":{"core":{"remaining":0},"graphql":{"remaining":0}}}'; exit 0 ;;
  *"api "*) echo 'gh: API rate limit exceeded for user ID 81560491. (HTTP 403)' >&2; exit 1 ;;
esac
exit 1
SH
chmod +x "$D/bin/gh"
# A sentinel makes "nothing written" DISCRIMINATING: an empty file cannot distinguish "the pass
# refused" from "the backlog was clobbered".
echo 99 > "$D/o/candidates.txt"
rf "$D" refresh
[ "$RC" -eq 1 ] && ok "rest-403: the pass exits TRANSIENT (rc=1) — a starved REST bucket is an outage, not 'no work'" \
               || bad "rest-403: rc=$RC (want 1) — output: $OUT"
[ ! -e "$D/o/.open_iss" ] && ok "rest-403: a FAILED issue listing leaves NO .open_iss (absence, not an empty answer)" \
                          || bad "rest-403: a failed issue listing was written as an empty/partial .open_iss"
[ ! -e "$D/o/.pr_brs" ] && ok "rest-403: a FAILED PR listing leaves NO .pr_brs" \
                         || bad "rest-403: a failed PR listing was written as an empty/partial .pr_brs"
case "$(tr '\n' ' ' < "$D/o/candidates.txt" 2>/dev/null)" in
  *42*) bad "rest-403: candidates were queued from a listing that failed" ;;
  *99*) ok "rest-403: the backlog was NOT touched (seed 99 intact)" ;;
  *) bad "rest-403: the backlog was clobbered — candidates='$(cat "$D/o/candidates.txt" 2>/dev/null)'" ;;
esac
case "$OUT" in
  # ⛔ THE LABEL AND THE STATUS MUST BE ADJACENT IN ONE WORDING, because a two-needle glob let this
  # assertion pass on the ECHOED provider text: `*"HTTP 403"*"REST bucket"*` matched across lines off
  # the `… (HTTP 403)` inside the quoted stderr, so forcing the status parse to yield nothing
  # (`HTTP ?`) left it green — a false PASS on exactly the regression it is named for (measured). The
  # old glob was also order-sensitive in the wrong direction: it demanded `HTTP 403` BEFORE
  # `REST bucket`, while the shipped line puts the label first, which is why it only ever passed through
  # this fixture's TWO refusal lines. One refusal line alone failed it, and a reordered line passed it.
  *"REST bucket refused it as RATE-LIMITED (HTTP 403"*) ok "rest-403: the refusal NAMES the HTTP 403 on the REST bucket (starved vs broken)" ;;
  *) bad "rest-403: the 403 is not named in the log — output: $OUT" ;;
esac
case "$OUT" in
  *"queue=UNREADABLE"*) ok "rest-403: the queue state is UNREADABLE, not EMPTY" ;;
  *) bad "rest-403: a blind pass was not reported as UNREADABLE — output: $OUT" ;;
esac

echo
echo "── Summary ───────────────────────────────────────────────────────"
echo "  PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || { echo "  ❌ FAILURES — fix and re-run"; exit 1; }
echo "  ✅ all checks passed"
exit 0
