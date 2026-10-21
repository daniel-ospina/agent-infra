#!/usr/bin/env bash
# refresh-spend.test.sh — the SHIPPED refresh pass's own core-request spend (#1984).
#
# WHAT THIS PINS, AND WHY A CEILING IS NOT ENOUGH. #2050's `refresh-quota.test.sh` pins the cost of
# the fleet BOARD (rebuilt once per pass, not once per candidate). This one pins the other half:
# every FLEET-WIDE read the per-candidate pre-flight makes must be paid ONCE PER PASS, and a pass
# whose inputs have not moved must not re-run the pre-flight at all.
#
# MEASURED (counting shim over the shipped script, agent-infra, 24 candidates):
#     identity (`gh api user`) ................ 24   <- fleet-wide, per candidate
#     open PRs ................................ 24   <- fleet-wide, per candidate
#     recently-closed PR sample ............... 24   <- fleet-wide, per candidate
#     issue state + `issue landed` timeline ... 24   <- genuinely per candidate
#     the two listings + three priority tiers . 14   <- once per pass, by construction
# With the per-pass read memo (#1984 cause 1) the three fleet reads are 1 each and the pass goes
# 134 -> 67 core requests; with the unchanged-listing skip (#1984 cause 2) an idle pass costs the
# 14 listings and nothing else.
#
# ⛔ THE CHAIN UNDER TEST IS THE REAL ONE. The `gh` on PATH is a shim that execs the REAL
# `../gh-limit.py` with a STUB real-gh behind it — so the memoisation, the conditional path and the
# export that enables them are all exercised, not re-implemented here. Only `gh` itself is a stub,
# which is what makes the whole suite offline.
#
# Run:  bash scripts/orchestrator-harness/refresh-spend.test.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REFRESH="$HERE/refresh-candidates.sh"
HELPER="$HERE/gh-limit.py"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
echo "==> refresh-candidates per-pass spend contract ($HERE)"
T="$(mktemp -d "${TMPDIR:-/tmp}/refresh-spend.XXXXXX")"
trap 'rm -rf "$T"' EXIT
[ -f "$REFRESH" ] && [ -f "$HELPER" ] || { echo "  FAIL missing $REFRESH or $HELPER"; exit 1; }

CEILING=26          # 6 candidates: 5 listing pages + 4 fleet reads + 6*2 per-candidate + slack

# mk_case <name> <budget> <rows> — sandbox: repo, an EXISTING scout worktree (so the shipped script
# never runs `git worktree add`), a sandbox HOME, $O, and a counting `gh` chain.
# ⛔ THE PRE-FLIGHT TOOL IS SUPPLIED VIA `TORTOISE_REPO`, NOT FROM THE SCOUT DIRECTORY (agent-infra#2174):
# the shipped refresh now REFUSES to judge when the tool resolves INSIDE a `$SC` that is not a LINKED
# worktree, because such a tree cannot be fetched and the gate in it is frozen. That refusal is correct
# and this fixture has no git at all, so the tool comes from the documented `TORTOISE_REPO` knob. What
# this suite measures — fleet-wide reads paid once per pass — does not depend on who supplies it.
D=""
mk_case() {
  D="$T/$1"; rm -rf "$D"
  mkdir -p "$D/home" "$D/bin" "$D/o" "$D/calls" "$D/ghlimit" \
           "$D/repo/.worktrees/dispatch-scout/tools" "$D/tort/tools"
  printf '%s' "${2:-9000}" > "$D/core"
  printf '%s' "${3:-[]}" > "$D/rows"
  # THE CHAIN: PATH `gh` -> the real helper -> a counting stub as the "real" gh.
  # ⛔ BOTH SCRIPTS ARE WRITTEN WITH A QUOTED HEREDOC AND TAKE THEIR PATHS FROM THE ENVIRONMENT.
  # An interpolating heredoc put the TEST's `$*` inside the stub's `frame()` — every framed answer
  # came back empty and the suite tested nothing (measured: `HTTP ? with an EMPTY body` for every
  # listing). A quoted heredoc has no expansion to get wrong.
  cat > "$D/bin/gh" <<'SH'
#!/usr/bin/env bash
exec python3 "$SPEND_HELPER" --real-gh "$SPEND_STUB" -- "$@"
SH
  cat > "$D/bin/gh-stub" <<'SH'
#!/usr/bin/env bash
# The counting "real gh": one charged core call per request, recorded by SURFACE under $SPEND_CASE.
D="${SPEND_CASE:?}"
ARGV="$*"
charge() {  # <surface> [cost]
  local c; c="$(cat "$D/core")"; c=$(( c - ${2:-1} )); [ "$c" -lt 0 ] && c=0
  printf '%s' "$c" > "$D/core"
  printf '%s\n' "$1" >> "$D/calls/$1"
}
frame() {  # `gh api --include` / `-i` are FRAMED; everything else prints the bare body
  case " $ARGV " in
    *" --include "*|*" -i "*) printf 'HTTP/2.0 200 OK\r\ncontent-type: application/json\r\n\r\n%s\n' "$1" ;;
    *) printf '%s\n' "$1" ;;
  esac
}
case "$ARGV" in
  "auth token") exit 0 ;;
  *rate_limit*) frame "{\"resources\":{\"core\":{\"remaining\":$(cat "$D/core")},\"graphql\":{\"remaining\":4999}}}" ;;
  *"user -q .login"*|*"user --jq .login"*|*"user"*) charge identity; frame '{"login":"spend-meter"}' ;;
  "pr list"*|*" pr list "*)  charge open_prs; frame '[]' ;;
  *"/pulls?state=closed"*) charge closed_pr_sample; frame '[]' ;;
  *"/pulls?state=all"*)    charge pr_branches; frame '[]' ;;
  *"/pulls?"*)             charge open_prs; frame '[]' ;;
  *labels=P0-blocker*|*labels=P1-severe*|*labels=P2-moderate*)
                           charge tier; frame "$(cat "$D/rows")" ;;
  *"/issues?"*)            charge issue_listing; frame '[]' ;;
  *"issue view"*)          charge per_candidate; printf '%s\n' "${VERDICT:-CLEAN}" ;;
  *"pr view"*)             charge per_candidate; printf '{}' ;;
  *) printf '[]\n' ;;
esac
SH
  chmod +x "$D/bin/gh" "$D/bin/gh-stub"
  # The pre-flight stand-in: the SAME shape of reads the real tool makes — three FLEET-WIDE ones
  # plus one per candidate — so "fleet-wide is read once per pass" is measured on the shipped layer.
  cat > "$D/tort/tools/collision_preflight.py" <<'PY'
import os, subprocess, sys
D = os.environ["SPEND_CASE"]
n_p = os.path.join(D, "preflight-count")
n = int(open(n_p).read()) if os.path.exists(n_p) else 0
open(n_p, "w").write(str(n + 1))
def gh(*a):
    return subprocess.run(["gh"] + list(a), capture_output=True, text=True).stdout
gh("api", "user", "-q", ".login")                       # fleet-wide
gh("pr", "list", "--state", "open", "--limit", "1001")  # fleet-wide
gh("api", "-i", "repos/o/r/pulls?state=closed&per_page=100")   # fleet-wide
gh("issue", "view", sys.argv[1])                        # per candidate
print("VERDICT: %s" % os.environ.get("VERDICT", "CLEAN"))
PY
  chmod +x "$D/tort/tools/collision_preflight.py"
}
rows() {  # <n> — n unassigned P0-blocker rows
  local i out="["
  for i in $(seq 1 "$1"); do
    [ "$i" -gt 1 ] && out="$out,"
    out="$out{\"number\":$((40+i)),\"title\":\"candidate $i\",\"assignees\":[]}"
  done
  printf '%s]' "$out"
}
OUT=""; RC=0
rf() {  # <case-dir> [LIMIT] [KEY=VAL ...]
  local dir="$1"; local lim="${2:-6}"; shift 2 2>/dev/null || shift 1
  OUT="$(env -u TORTOISE -u SCOUT_UV -u GH_HOST -u CELL_HOME -u SCOUT_PY \
            -u SCOUT_UV_EXTRAS -u GH_CONFIG_DIR -u COLLISION_PREFLIGHT_BOARD_CACHE \
            -u COLLISION_PREFLIGHT_CORE_RESERVE -u COLLISION_PREFLIGHT_CORE_PER_CANDIDATE \
            -u COLLISION_PREFLIGHT_CORE_PACING -u GH_PASS_CACHE_DIR -u REFRESH_UNCHANGED_SKIP_TTL \
            TORTOISE_REPO="$dir/tort" HOME="$dir/home" PATH="$dir/bin:$PATH" REPO="$dir/repo" O="$dir/o" \
            GH_LIMIT_DIR="$dir/ghlimit" SPEND_CASE="$dir" SPEND_STUB="$dir/bin/gh-stub" \
            SPEND_HELPER="$HELPER" \
            "$@" bash "$REFRESH" "$lim" 2>&1)"
  RC=$?
}
calls() { wc -l < "$D/calls/$1" 2>/dev/null | tr -d ' ' || true; }
nz() { local v; v="$(calls "$1")"; printf '%s' "${v:-0}"; }

# ── 1) THE FLEET-WIDE READS ARE PAID ONCE PER PASS, NOT ONCE PER CANDIDATE ────────────────────
mk_case once 9000 "$(rows 6)"
rf "$D" 6
[ "$RC" -eq 0 ] && ok "once: the pass succeeds (rc=0)" || bad "once: rc=$RC — output: $OUT"
[ "$(cat "$D/preflight-count" 2>/dev/null)" = "6" ] \
  && ok "once: all 6 candidates were judged (the fixture really runs the pre-flight 6x)" \
  || bad "once: the pre-flight ran $(cat "$D/preflight-count" 2>/dev/null)x (want 6) — the ceiling below would be vacuous"
for surf in identity open_prs closed_pr_sample; do
  c="$(nz "$surf")"
  [ "$c" = "1" ] \
    && ok "once: $surf was requested ONCE for 6 candidates (a per-candidate regression would make it 6)" \
    || bad "once: $surf was requested ${c:-0} time(s) for 6 candidates — it is being re-read PER CANDIDATE (#1984 cause 1)"
done
[ "$(nz per_candidate)" = "6" ] && ok "once: the per-candidate reads are still per candidate (6 for 6)" \
                                || bad "once: per-candidate reads = $(nz per_candidate) (want 6) — the memo is over-sharing"
spent=$(( 9000 - $(cat "$D/core") ))
[ "$spent" -le "$CEILING" ] \
  && ok "once: the 6-candidate pass spent $spent core requests (ceiling $CEILING)" \
  || bad "once: the pass spent $spent core requests, over the $CEILING ceiling — fleet reads are being re-paid per candidate"
[ "$spent" -gt 0 ] && ok "once: the spend is measured, not zero ($spent)" \
                   || bad "once: the fixture charged nothing — every check above would pass vacuously"

# ── 2) THE MEMO IS SCOPED TO THE PASS, AND THE SCOPE IS THE SCRIPT'S ─────────────────────────
# The pre-flight records the seam it was handed. It must be a directory INSIDE $O (so a box cannot be
# pointed at another box's cache), and it must not survive the pass (the entries hold issue bodies).
mk_case seam 9000 "$(rows 2)"
seamf="$D/seam.log"
cat > "$D/tort/tools/collision_preflight.py" <<'PYS'
import os
open(os.environ["SEAM_LOG"], "a").write("%s|%s\n" % (os.environ.get("GH_LIMIT_PASS_CACHE", "<unset>"),
                                                  os.environ.get("COLLISION_PREFLIGHT_BOARD_CACHE", "<unset>")))
print("VERDICT: COLLISION")
PYS
chmod +x "$D/tort/tools/collision_preflight.py"
rf "$D" 2 SEAM_LOG="$seamf"
seam="$(head -1 "$seamf" 2>/dev/null)"
case "$seam" in
  "$D/o/state/.gh-pass-cache|1") ok "seam: the pre-flight is handed GH_LIMIT_PASS_CACHE=<O>/state/.gh-pass-cache and the board cache" ;;
  *) bad "seam: the pre-flight got '${seam:-<nothing>}' (want '<O>/state/.gh-pass-cache|1') — the per-pass memo is NOT wired" ;;
esac
[ -d "$D/o/state/.gh-pass-cache" ] \
  && bad "seam: the per-pass cache directory SURVIVED the pass — it holds issue/PR bodies and is on the box's disk budget" \
  || ok "seam: the per-pass cache directory is removed when the pass exits"

# ── 3) AN UNCHANGED LISTING SKIPS THE EXPENSIVE WORK — AND SAYS SO ───────────────────────────
# Pre-flight answers COLLISION for everything, so the pass queues nothing and every input the next
# pass reads is byte-identical. That is the measured stall: the same 24 candidates re-judged every
# five minutes. The second pass must skip, cost the listings and nothing else, and leave the backlog
# and the blacklist untouched.
mk_case skip 9000 "$(rows 4)"
before_pre=""
# COLLISION: usable verdicts that write NOTHING (checked.txt is written only for CLEAN), so the next
# pass's inputs are byte-identical. A CLEAN here would change checked.txt and correctly defeat the skip.
rf "$D" 4 VERDICT=COLLISION
first_rc=$RC; first_pre="$(cat "$D/preflight-count" 2>/dev/null)"
first_spent=$(( 9000 - $(cat "$D/core") ))
[ "$first_rc" -eq 0 ] && ok "skip: pass 1 runs normally (rc=0, $first_pre pre-flight run(s))" \
                      || bad "skip: pass 1 rc=$first_rc — output: $OUT"
rm -f "$D/calls"/*; printf '%s' 9000 > "$D/core"
rf "$D" 4 VERDICT=COLLISION
second_pre="$(cat "$D/preflight-count" 2>/dev/null)"
second_spent=$(( 9000 - $(cat "$D/core") ))
[ "$RC" -eq 0 ] && ok "skip: pass 2 exits 0 (a skip is not a failure)" || bad "skip: pass 2 rc=$RC — output: $OUT"
[ "$second_pre" = "$first_pre" ] \
  && ok "skip: pass 2 ran NO pre-flight (count still $first_pre) — the expensive work was skipped" \
  || bad "skip: pass 2 ran $second_pre pre-flight(s), was $first_pre — a byte-identical listing re-ran the whole sweep"
case "$OUT" in
  *"queue=READ(4) unchanged"*) ok "skip: the skip is NAMED, with the read state and the age, and states it is not \"no work\"" ;;
  *) bad "skip: no 'queue=READ(4) unchanged' line — an operator cannot tell a skip from a pass — output: $OUT" ;;
esac
case "$OUT" in
  *"backlog now"*) bad "skip: a skipped pass printed a backlog count (it produced none) — the #1736 false-report shape" ;;
  *) ok "skip: no 'backlog now' line on a skipped pass" ;;
esac
[ "$second_spent" -lt "$first_spent" ] \
  && ok "skip: pass 2 spent $second_spent core vs $first_spent — the skip is a real saving" \
  || bad "skip: pass 2 spent $second_spent, the same as pass 1's $first_spent — nothing was saved"
[ -s "$D/o/candidates.txt" ] && bad "skip: a skipped pass WROTE candidates.txt" \
                             || ok "skip: candidates.txt untouched by the skip"

# ── 4) AN UNREADABLE LISTING IS NEVER \"UNCHANGED\" ────────────────────────────────────────────
# #1931's false green: a pass that could not read the pool must never be indistinguishable from one
# that read it and found nothing. Here the TIERS fail, so the pass must abort UNREADABLE — and it
# must not have written an `unchanged` token on the way.
mk_case unreadable 9000 "$(rows 4)"
rf "$D" 4                                   # pass 1: a normal, swept pass
rm -f "$D/calls"/*; printf '%s' 9000 > "$D/core"
# now break the tier listings only (same quoted-heredoc rule as the main stub)
cat > "$D/bin/gh-stub" <<'SH'
#!/usr/bin/env bash
D="${SPEND_CASE:?}"
ARGV="$*"
case "$ARGV" in
  "auth token") exit 0 ;;
  *rate_limit*) printf '{"resources":{"core":{"remaining":%s},"graphql":{"remaining":4999}}}' "$(cat "$D/core")" ;;
  *labels=P*) echo "the tier listing is broken" >&2; exit 1 ;;
  *) printf '[]\n' ;;
esac
SH
chmod +x "$D/bin/gh-stub"
rf "$D" 4
case "$OUT" in
  *"queue=UNREADABLE"*|*"queue=PARTIAL"*) ok "unreadable: the pass names the unreadable pool and refuses" ;;
  *) bad "unreadable: an unreadable tier listing did not produce UNREADABLE/PARTIAL — output: $OUT" ;;
esac
case "$OUT" in
  *unchanged*) bad "unreadable: an unreadable listing was reported as UNCHANGED — #1931's false green" ;;
  *) ok "unreadable: an unreadable listing is never reported as unchanged" ;;
esac
[ "$RC" -ne 0 ] && ok "unreadable: refused with a non-zero status (rc=$RC)" \
                || bad "unreadable: exited 0 over an unreadable pool"

# ── 5) LIMIT IS STILL AN HONEST UPPER BOUND ──────────────────────────────────────────────────
mk_case limit 9000 "$(rows 6)"
rf "$D" 3
n_pre="$(cat "$D/preflight-count" 2>/dev/null)"
[ "$n_pre" = "3" ] && ok "limit: LIMIT=3 over a 6-row pool judged exactly 3 (no over-run)" \
                   || bad "limit: LIMIT=3 judged ${n_pre:-0} candidate(s) — LIMIT is not an upper bound"

echo
printf 'refresh-spend: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
