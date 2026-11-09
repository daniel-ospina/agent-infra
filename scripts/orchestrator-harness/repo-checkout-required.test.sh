#!/usr/bin/env bash
# repo-checkout-required.test.sh — NO SHIPPED SCRIPT INVENTS ITS TARGET CHECKOUT (agent-infra#1974).
#
# THE MEASURED DEFECT. `REPO` is a DEPLOYMENT FACT: the box declares it (the launchd plist's
# EnvironmentVariables on a Mac, `keys.env` on a cell). Five shipped scripts defaulted it anyway, and
# every one of those defaults was wrong on some machine the fleet actually runs:
#
#     cloud-cell-doctor.sh       REPO="${REPO:-/tmp/cell}"                      exists on NO machine
#     worktree-hygiene-sweep.sh  REPO="${TORTOISE_REPO:-$HOME/eldato/tortoise}" ONE developer's home
#     lane-container-reap.sh     REPO="${LANE_CONTAINER_REPO:-…-$PWD}"          $PWD
#     stale-main-triage.sh       REPO="${1:-$PWD}"
#     stale-worktrees.sh         REPO="$PWD"
#
# `$PWD` is the worst of them for a reason that is easy to miss: under launchd `$PWD` is `/`, which IS a
# real directory and is NOT a repo — so the pass gets past every "does the path exist" check and dies
# several probes later as `not a git repository: /`, nowhere near the cause. `/tmp/cell` is worse still:
# a cell's doctor ran its `merge` and `hygiene` roles against a path nobody chose and nothing creates.
#
# WHAT IS PINNED — behaviour, not prose:
#   A  the five scripts carry NO path default at all (the gate's own population, read directly), and
#      `check-single-source.sh`'s debt list is EMPTY, so a re-introduced default REDS rather than being
#      excused by name.
#   B  with nothing declared and a cwd that is NOT a checkout, each refuses — non-zero, ONE line naming
#      REPO, and it does not silently proceed (the pass that ran against `/` is the failure).
#   C  with nothing declared and a cwd that IS a checkout, each DERIVES it and SAYS SO — a value the
#      operator did not type must be visible. This is the difference between a derivation and a guess.
#   D  a DECLARED value is never replaced by a derived one (#1974 point 3): `--repo ""` — what a
#      renderer produces when its variable is unset — is a REFUSAL, not a licence to use the cwd.
#   N  NON-VACUITY: the gate reds when a default is planted back into a copy of the tree.
#
# HERMETIC: a throwaway `git init` under a temp dir; no network, no gh, no docker, no HOME writes.
# Bash 3.2 (macOS) and 5.2 (cells): no `mapfile`, no `${x^^}`, no `timeout`.
# Run: bash scripts/orchestrator-harness/repo-checkout-required.test.sh
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SELF="$HERE/$(basename "$0")"
REPO_SLUG_LIB="$HERE/repo-slug.sh"
GATE="$HERE/check-single-source.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ✅ %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  ❌ %s\n' "$1"; }

command -v git >/dev/null 2>&1 || { printf 'repo-checkout-required.test.sh: git is required\n' >&2; exit 2; }
[ -f "$REPO_SLUG_LIB" ] || { printf 'repo-checkout-required.test.sh: %s is missing\n' "$REPO_SLUG_LIB" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/repo-checkout-req.XXXXXX")" || exit 2
cleanup() { chmod -R u+rwX "$T" 2>/dev/null; rm -rf "$T" 2>/dev/null; }
trap cleanup EXIT INT TERM

CHECKOUT="$T/tortoise"
mkdir -p "$CHECKOUT"
git init -q "$CHECKOUT" || exit 2
git -C "$CHECKOUT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m fixture || exit 2
NOTREPO="$T/not-a-checkout"; mkdir -p "$NOTREPO"
CANON="$(cd "$CHECKOUT" && pwd -P)"

# ⛔ THE RUNTIME BIT: each script is run in its OWN process with REPO, OR and every derivation variable
# REMOVED, so a value inherited from the suite's own environment can never make an arm pass.
# `env -u` is used (not `REPO= `) because set-but-empty is a different case, pinned in section D.
run_bare() { # <cwd> <script> [args…]
  local cwd="$1" scr="$2"; shift 2
  # ⛔ rc 127 IS "NOT FOUND", NOT "REFUSED": an arm whose script path is wrong would otherwise read as a
  # pass on every refusal assertion below. Every caller's path is checked here, once.
  [ -f "$scr" ] || { printf 'run_bare: NO SUCH SCRIPT: %s\n' "$scr"; return 127; }
  # ⛔ EVERY VARIABLE THE SUITE COULD INHERIT IS SCRUBBED, NOT THE ONES THAT BIT SO FAR (fresh-context
  # review of #3833, F1b — measured). This list omitted `ENV_FILE`, which this box exports ambiently and
  # a GitHub runner does not; the suite was therefore 23/0 here and 21/2 on CI, and the two reds were a
  # REAL defect (a `set -u` abort inside the doctor's refusal) that the leak hid. A scrub list is only
  # hermetic when it is the whole class, so CELL_HOME/ENV_FILE/O/OR/HOME are all removed here.
  ( cd "$cwd" && env -u REPO -u OR -u TORTOISE_REPO -u TORTOISE -u LANE_CONTAINER_REPO \
      -u ENV_FILE -u CELL_HOME -u O \
      AGENT_INFRA_PATH= HOME="${TMPDIR:-/tmp}" bash "$scr" "$@" 2>&1 )
}

echo "== A. no shipped script invents its target checkout, and the gate's debt list is empty =="

# A1-A5: the five files the gate named. A `REPO=` path default is the defect; `REPO="${REPO:-}"` (an
# explicit "no default") and `REPO="$(resolve_repo)"` (the one resolver) are the shapes that replace it.
for _f in orchestrator-harness/cloud-cell-doctor.sh \
          worktree-hygiene-sweep.sh \
          orchestrator-harness/lane-container-reap.sh \
          stale-main-triage.sh \
          stale-worktrees.sh; do
  _p="$HERE/../$_f"
  [ -f "$_p" ] || { bad "A  $_f is shipped (absent: $_p)"; continue; }
  # ⛔ THE SAME STRIPS THE GATE APPLIES, because this arm must be neither stricter nor looser than the
  # shipped rule: a trailing comment, a second command after a separator (`REPO="$(resolve_repo)" ||
  # exit $?` is the resolver WITH its error handling, not a default), and one layer of matching quotes.
  _hit="$(awk -v q39="'" '
    function bal(x,  i, n, c) { n = 0
      for (i = 1; i <= length(x); i++) { c = substr(x, i, 1); if (c == "\"" || c == q39) n++ }
      return (n % 2 == 0) }
    { ln = $0; sub(/^[ \t]+/, "", ln)
      if (ln ~ /^#/) next
      while (ln ~ /^(export|local|readonly|declare|typeset)([ \t]+-[A-Za-z]+)*[ \t]+/)
        sub(/^(export|local|readonly|declare|typeset)([ \t]+-[A-Za-z]+)*[ \t]+/, "", ln)
      if (ln !~ /^REPO=/) next
      v = ln; sub(/^REPO=/, "", v); sub(/[ \t]+$/, "", v)
      t = v; if (sub(/[ \t]+#.*$/, "", t) && bal(t)) v = t
      t = v; if (sub(/[ \t]*[;&|]+[^;&|].*$/, "", t) && bal(t)) v = t
      sub(/[ \t]+$/, "", v)
      q = substr(v, 1, 1)
      if ((q == "\"" || q == q39) && length(v) > 1 && substr(v, length(v), 1) == q) v = substr(v, 2, length(v) - 2)
      if (v ~ /^\$\(resolve_repo\)/) next                     # the ONE resolver (with or without || exit)
      e = v; pv = ""
      while (e != pv) { pv = e; sub(/\$\{[A-Za-z_][A-Za-z0-9_]*:?-\}/, "", e) }
      if (e == "") next                                     # an EMPTY default supplies nothing, at any depth
      print FNR ": " $0 }' "$_p")"
  if [ -n "$_hit" ]; then
    bad "A  $_f carries a REPO path default ($_hit)"
  else
    ok "A  $_f declares REPO or resolves it — it invents nothing"
  fi
done

# A6 THE DEBT LIST IS EMPTY. While it has entries, a NEW default in one of those files is excused by
# NAME — the arm is narrowed exactly where the defect lives. Empty is the stricter state.
_debt="$(sed -n 's/^REPO_DEFAULT_KNOWN="\(.*\)"$/\1/p' "$GATE" 2>/dev/null | head -1)"
if [ -z "${_debt:-}" ]; then
  ok "A6 the gate's REPO_DEFAULT_KNOWN debt list is EMPTY — a re-introduced default reds"
else
  bad "A6 the gate still excuses REPO defaults by name:$_debt"
fi

echo
echo "== B. nothing declared + cwd is NOT a checkout ⇒ ONE refusal naming REPO =="

# ⛔ THE REFUSAL IS THE PROPERTY (#1974 indicator (a)). The failure this replaces is a pass that STARTS
# against an absent path and reports its own placeholder as the operator's mistake.
_b() { # <label> <script> [args…]
  local label="$1" scr="$2"; shift 2
  local out rc
  out="$(run_bare "$NOTREPO" "$scr" "$@")"; rc=$?
  if [ "$rc" -ne 0 ] && grep -q 'REPO' <<<"$out"; then
    ok "B  $label: refuses (rc=$rc) and names REPO"
  else
    bad "B  $label: rc=$rc, and the output does not name REPO — $out"
  fi
}

_b "stale-worktrees.sh"      "$HERE/../stale-worktrees.sh"
_b "stale-main-triage.sh"    "$HERE/../stale-main-triage.sh"
_b "worktree-hygiene-sweep.sh (--preflight)" "$HERE/../worktree-hygiene-sweep.sh" --preflight
_b "lane-container-reap.sh"  "$HERE/lane-container-reap.sh" --dry-run
# ⛔ WITH `$OR` DECLARED, so the arm reaches the CHECKOUT precondition: the doctor refuses an unresolvable
# QUEUE TARGET first (its own, unrelated precondition), and an arm that stops there would prove nothing
# about REPO.
_b_or() {
  local out rc
  # ⛔ SAME SCRUB AS `run_bare` (fresh-context review of #3833, F1b): `ENV_FILE` is ambient on the box
  # this was written on and unset on a runner, so leaving it here keeps one arm's message text
  # box-specific — the leak the whole scrub list exists to remove.
  out="$( ( cd "$NOTREPO" && env -u REPO -u ENV_FILE -u CELL_HOME -u O HOME="${TMPDIR:-/tmp}" OR="acme/widget" \
    bash "$HERE/cloud-cell-doctor.sh" merge 2>&1 ) )"; rc=$?
  if [ "$rc" -ne 0 ] && grep -q 'REPO' <<<"$out"; then
    ok "B  cloud-cell-doctor.sh merge (with \$OR set): refuses (rc=$rc) and names REPO"
  else
    bad "B  cloud-cell-doctor.sh merge (with \$OR set): rc=$rc — $out"
  fi
}
_b_or

# B6 THE DOCTOR'S REFUSAL IS rc 3 "cannot-verify", not rc 0 and not a pass: a role that records a green
# state while it read no checkout is the same defect one layer down.
_doc_out="$( ( cd "$NOTREPO" && env -u REPO -u OR -u ENV_FILE -u CELL_HOME -u O HOME="${TMPDIR:-/tmp}" \
  bash "$HERE/cloud-cell-doctor.sh" hygiene 2>&1 ) )"; _doc_rc=$?
if [ "$_doc_rc" -eq 3 ] && grep -qi 'no checkout' <<<"$_doc_out"; then
  ok "B6 cloud-cell-doctor.sh hygiene: rc 3 cannot-verify naming the checkout (rc=$_doc_rc)"
else
  bad "B6 cloud-cell-doctor.sh hygiene: rc=$_doc_rc — expected 3 with 'no checkout' — $_doc_out"
fi

echo
echo "== C. nothing declared + cwd IS a checkout ⇒ it DERIVES it, and says so =="

# ⛔ A DERIVATION THAT PROVES ITSELF, NOT A NICER DEFAULT. The value is announced on stderr, so a path
# the operator never typed is visible in the pass's own log.
_c() { # <label> <script> [args…]
  local label="$1" scr="$2"; shift 2
  local out
  out="$(run_bare "$CHECKOUT" "$scr" "$@")"
  if grep -q "using $CANON" <<<"$out"; then
    ok "C  $label: derived $CANON and said so"
  else
    bad "C  $label: did not derive the cwd checkout — $out"
  fi
}

_c "stale-worktrees.sh"      "$HERE/../stale-worktrees.sh"
_c "stale-main-triage.sh"    "$HERE/../stale-main-triage.sh"
_c "worktree-hygiene-sweep.sh (--preflight)" "$HERE/../worktree-hygiene-sweep.sh" --preflight
_c "lane-container-reap.sh"  "$HERE/lane-container-reap.sh" --dry-run

# C5 A CHECKOUT OF THE WRONG REPO IS NOT ADOPTED. This is the #1901 class the derivation exists to keep
# closed: with a queue target declared, only a checkout whose `origin` NAMES it may be used.
git -C "$CHECKOUT" remote add origin https://github.com/acme/widget.git 2>/dev/null || true
_out="$( ( cd "$CHECKOUT" && env -u REPO HOME="${TMPDIR:-/tmp}" OR="acme/gadget" \
  AGENT_INFRA_PATH= bash "$HERE/../stale-worktrees.sh" 2>&1 ) )"; _rc=$?
if [ "$_rc" -ne 0 ] && ! grep -q "using $CANON" <<<"$_out"; then
  ok "C5 the cwd checkout of ANOTHER repo is refused when \$OR names a different one (rc=$_rc)"
else
  bad "C5 a checkout whose origin is not the declared \$OR was adopted (rc=$_rc) — $_out"
fi
git -C "$CHECKOUT" remote remove origin 2>/dev/null || true

echo
echo "== D. a DECLARED value is never replaced by a derived one (#1974 point 3) =="

# ⛔ `--repo ""` IS WHAT A RENDERER PRODUCES WHEN ITS VARIABLE IS UNSET, and it must be a refusal: the
# alternative is a sweep that silently owns whatever directory the invoker stood in. A declared value
# is an ASSERTION, and quietly substituting for it is how a controller lands on the wrong repo.
_out="$(run_bare "$CHECKOUT" "$HERE/../stale-worktrees.sh" --repo "")"; _rc=$?
if [ "$_rc" -ne 0 ] && ! grep -q "using $CANON" <<<"$_out"; then
  ok "D1 stale-worktrees.sh --repo \"\": REFUSED, cwd not substituted (rc=$_rc)"
else
  bad "D1 stale-worktrees.sh --repo \"\" fell back to the cwd (rc=$_rc) — $_out"
fi

_out="$(run_bare "$CHECKOUT" "$HERE/../worktree-hygiene-sweep.sh" --preflight --repo "")"; _rc=$?
if [ "$_rc" -ne 0 ] && ! grep -q "using $CANON" <<<"$_out"; then
  ok "D2 worktree-hygiene-sweep.sh --repo \"\": REFUSED, cwd not substituted (rc=$_rc)"
else
  bad "D2 worktree-hygiene-sweep.sh --repo \"\" fell back to the cwd (rc=$_rc) — $_out"
fi

_out="$(run_bare "$CHECKOUT" "$HERE/lane-container-reap.sh" --repo "" --dry-run)"; _rc=$?
if [ "$_rc" -ne 0 ] && ! grep -q "using $CANON" <<<"$_out"; then
  ok "D3 lane-container-reap.sh --repo \"\": REFUSED, cwd not substituted (rc=$_rc)"
else
  bad "D3 lane-container-reap.sh --repo \"\" fell back to the cwd (rc=$_rc) — $_out"
fi

# D4 A DECLARED PATH THAT DOES NOT EXIST is the operator's refusal, BY VALUE — never a fallback to the
# (perfectly good) cwd checkout they happen to be standing in.
_out="$(run_bare "$CHECKOUT" "$HERE/../stale-worktrees.sh" --repo "$NOTREPO/x")"; _rc=$?
if [ "$_rc" -ne 0 ] && grep -q 'not a git checkout' <<<"$_out"; then
  ok "D4 a declared-but-bogus --repo is refused by value with the cwd available (rc=$_rc)"
else
  bad "D4 a declared-but-bogus --repo was not refused by value (rc=$_rc) — $_out"
fi

# D5-D6 THE FARM SHAPE: a copy with NO `repo-slug.sh` beside it (what `~/.pi/agent/scripts/` is — a flat
# farm with no orchestrator-harness subtree). A DECLARED value must still work, and only an UNRESOLVED
# REPO may refuse (fresh-context review of #3833, F3 — verified: two of the five scripts refused whenever
# the LIBRARY was missing and then told the operator to `--repo`, an action the absent library could not
# honour). Pinned with a copy, so it is not a claim about this host's layout.
FARM="$T/farm"; mkdir -p "$FARM"
cp "$HERE/../stale-worktrees.sh" "$HERE/../stale-main-triage.sh" "$FARM/" 2>/dev/null
for _s in stale-worktrees.sh stale-main-triage.sh; do
  # no repo-slug.sh anywhere it looks, and AGENT_INFRA_PATH empty
  _out="$( cd "$CHECKOUT" && env -u REPO -u OR -u ENV_FILE -u CELL_HOME -u O AGENT_INFRA_PATH= \
    HOME="${TMPDIR:-/tmp}" bash "$FARM/$_s" 2>&1 )"; _rc=$?
  if [ "$_rc" -ne 0 ] && grep -q 'REPO is unset' <<<"$_out"; then
    ok "D5 $_s (farm copy, no library, nothing declared): refuses naming REPO (rc=$_rc)"
  else
    bad "D5 $_s (farm copy, no library, nothing declared): rc=$_rc — $_out"
  fi
  # A DECLARED value must proceed to the LOCAL validation, not be refused for the absent library.
  _out="$( cd "$NOTREPO" && env -u REPO -u OR -u ENV_FILE -u CELL_HOME -u O AGENT_INFRA_PATH= \
    HOME="${TMPDIR:-/tmp}" bash "$FARM/$_s" --repo "$CHECKOUT" 2>&1 )"; _rc=$?
  if [ "$_rc" -eq 0 ] && ! grep -q 'was not found beside this script' <<<"$_out"; then
    ok "D6 $_s (farm copy, no library, --repo declared): runs, never refused for the absent library"
  else
    bad "D6 $_s (farm copy, no library, --repo declared): rc=$_rc — $_out"
  fi
done

echo
echo "== N. NON-VACUITY: the gate reds when a default is planted back =="

# A suite that stays green because it never asked the question is worse than no suite. The gate is run
# over a COPY of this tree with one default re-introduced, and it must go red.
if [ -f "$GATE" ]; then
  NCOPY="$T/tree"
  mkdir -p "$NCOPY/scripts/orchestrator-harness"
  # canonical is the copy's own directory, so the fork arm compares $HERE with itself and stays green.
  # ⛔ THE WHOLE HARNESS DIR, because the fork arm requires the eleven SHARED files to be present — a
  # partial copy makes the gate answer UNKNOWN ("canonical copy is MISSING orch-loop.sh"), which is a
  # failure for a reason that has nothing to do with the planted default and would prove nothing.
  cp -a "$HERE/." "$NCOPY/scripts/orchestrator-harness/"
  printf '#!/bin/bash\nREPO="${REPO:-/tmp/cell}"\n' > "$NCOPY/scripts/orchestrator-harness/zz-planted.sh"
  _nout="$(env -u O -u CELL_HOME bash "$NCOPY/scripts/orchestrator-harness/check-single-source.sh" 2>&1)"; _nrc=$?
  if [ "$_nrc" -ne 0 ] && grep -q 'zz-planted.sh' <<<"$_nout"; then
    ok "N1 a planted REPO=\${REPO:-/tmp/cell} REDS the gate on a shipped script (rc=$_nrc)"
  else
    bad "N1 the gate did not red a planted default (rc=$_nrc) — $_nout"
  fi
  # N2 the CONTROL: the same copy WITHOUT the planted file is green, so N1 is not just "this copy is
  # always red" (a suite that reds for an unrelated reason proves nothing about the rule).
  rm -f "$NCOPY/scripts/orchestrator-harness/zz-planted.sh"
  printf '#!/bin/bash\nREPO="${REPO:-}"\n' > "$NCOPY/scripts/orchestrator-harness/zz-clean.sh"
  _cout="$(env -u O -u CELL_HOME bash "$NCOPY/scripts/orchestrator-harness/check-single-source.sh" 2>&1)"; _crc=$?
  if [ "$_crc" -eq 0 ]; then
    ok "N2 control: the same copy with an explicit no-default is GREEN (rc=$_crc)"
  else
    bad "N2 control copy is red without a planted default (rc=$_crc) — $_cout"
  fi
else
  bad "N  the gate is shipped (absent: $GATE)"
fi

echo
printf '================ RESULT: %s passed, %s failed ================\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
# shellcheck disable=SC2034
: "$SELF"
