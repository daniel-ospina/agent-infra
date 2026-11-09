#!/usr/bin/env bash
# gh-auth.test.sh — the LANE's `gh` credential: resolved, named, and never confused with the PR ratio
# (agent-infra#2509, the "never PROVIDED" arm).
#
# WHAT WAS BROKEN, and how each section is RED on the pre-change tree.
#
#   A lane runs with `HOME` redirected to the operational home (`/tmp/cell-home` on a cell) because
#   `record-review.sh`, the gh shim and the extensions live under `$CELL_HOME/.pi/agent`. `gh`'s
#   `hosts.yml` lives in the ACCOUNT home. Nothing set `GH_CONFIG_DIR` on the
#   `nonblocking-dispatch.sh` → `spawn-gate.sh` path — `rg -n 'GH_CONFIG_DIR' scripts/` found only test
#   files — so `gh` inside the lane was unauthenticated, and the land-backlog gate reported a MISSING
#   CREDENTIAL as a PR-RATIO problem:
#
#       [land-backlog] REFUSED bg issue-11086: UNREADABLE open-PR count for daniel-ospina/tortoise
#         (the gh read failed) … Remedy: land/fix the open PRs (this is the drain) …
#
#   Measured 2026-11-09 on `pi-cell-4` and `pi-cell-5`; both boxes read the queue fine from a shell,
#   and BOTH refused identically — so the documented "a re-dispatch to a healthy box clears it" was
#   false for this cause (`skills/cmux-cells/SKILL.md` now says so).
#
#   §A (the resolver) is RED pre-change for the plainest reason: `gh-auth.sh` does not exist, so the
#   module cannot be sourced at all. §B drives the SHIPPED `run_agent` end to end with a `gh` stub that
#   fails EXACTLY the way `gh` fails when no credential resolves (`please run: gh auth login`, exit 4),
#   so every arm below is a measurement of the gate rather than of a fixture's goodwill.
#
# ⛔ THE FALSIFIERS THIS SUITE PINS, because the fix must not buy its green by weakening them:
#   * a genuinely exceeded ratio still HOLDS creation (§B4 — the credential is present and the remedy is
#     the RATIO one, which is the direction the pre-change tree got wrong in reverse);
#   * a P0-blocker is exempt ONLY when the evidence read SUCCEEDED — an unreadable exemption HOLDS it
#     over the ceiling (§B6), which is the fail-closed direction `#2409` declares;
#   * a refusal starts NO session (§B2/B4/B6 assert the `pi` stub never ran) and leaves a READABLE
#     reason naming the cause (§B2 — `#2210`).
#
# ⛔ HERMETIC: every arm runs `env -u GH_CONFIG_DIR -u XDG_CONFIG_HOME -u GH_TOKEN -u GITHUB_TOKEN`, so a
# runner that exports one of those (this fleet's cells DO) cannot turn a credential arm green by
# accident — the failure #2138 records in `test_objective.py`, one suite over. The passwd record is the
# ONE non-hermetic read in `gh-auth.sh` (the account home), and §A/§B replace it with a fixture through
# `gh_auth_account_home`'s own name — a function override, not an env switch, so nothing a `keys.env`
# sets can move it.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GH_AUTH="$HERE/gh-auth.sh"
SG="$HERE/spawn-gate.sh"
# The capability gate costs two bounded `pi` probes per arm and this suite only tests credentials; the
# documented operator escape, declared where it applies (see capacity-transfer.test.sh's header).
export LANE_PREFLIGHT=0
export MEM_MIN_AVAIL_MB=1
PASS=0; FAIL=0
ck() { # ck <name> <0|1>
  if [ "$2" -eq 0 ]; then printf '  ✅ %s\n' "$1"; PASS=$((PASS+1));
  else printf '  ❌ %s\n' "$1"; FAIL=$((FAIL+1)); fi
}
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
O="$TMP/O"; mkdir -p "$O/state" "$O/logs" "$TMP/bin"
for f in "$GH_AUTH" "$SG"; do [ -s "$f" ] || { echo "❌ missing $f"; exit 2; }; done
echo "==> gh-auth self-test ($HERE)"

# ── fixtures ────────────────────────────────────────────────────────────────────────────────────
# LANE_HOME is the LANE's HOME (redirected, as on a cell) and ACCT is the ACCOUNT home. ACCT carries a
# `hosts.yml` in exactly one fixture so "the account fallback" is a measurement and not an assumption.
LANE_HOME="$TMP/lane-home"; ACCT="$TMP/acct"; ACCT_EMPTY="$TMP/acct-empty"
mkdir -p "$LANE_HOME" "$ACCT_EMPTY" "$ACCT/.config/gh" "$TMP/cfg-a"
printf 'github.com:\n    user: fixture\n    oauth_token: gho_fixture\n' > "$ACCT/.config/gh/hosts.yml"
cp "$ACCT/.config/gh/hosts.yml" "$TMP/cfg-a/hosts.yml"
ENVF="$TMP/keys.env"

# `gh_auth_resolve` reads ambient GH_CONFIG_DIR / XDG_CONFIG_HOME / GH_TOKEN, so every unit arm runs in
# a clean environment. `$1` is the shell body.
u() { env -u GH_CONFIG_DIR -u XDG_CONFIG_HOME -u GH_TOKEN -u GITHUB_TOKEN bash -c "$1"; }

# ── the `pi` stub: an arm that starts a session is visible, and an arm that must refuse proves it ──
PI_LOG="$TMP/pi.log"; : > "$PI_LOG"; export PI_LOG
cat > "$TMP/bin/pi" <<'STUB'
#!/usr/bin/env bash
echo "RAN $*" >> "$PI_LOG"
exit 0
STUB
chmod +x "$TMP/bin/pi"

# ── the `gh` stub: gh's OWN credential rule, then the API answers each arm supplies ────────────────
# ⛔ THE CREDENTIAL CHECK IS THE POINT OF THIS STUB. A stub that answered unconditionally would make
# every arm below pass on a box that never resolved anything — it would test the fixture, not the gate.
# It implements gh's documented order (GH_CONFIG_DIR → $XDG_CONFIG_HOME/gh → $HOME/.config/gh, and a
# non-blank GH_TOKEN/GITHUB_TOKEN outranking all three) and, when nothing resolves, prints gh's own
# two lines and exits 4.
gh_install() { # <open1> <lands24> <labels> <title> <mode: ok|evidence-fail|all-fail>
  mkdir -p "$O/gh-rest"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'OPEN1=%q\nLANDS=%q\nLAB=%q\nTITLE=%q\nMODE=%q\n' "$1" "$2" "$3" "$4" "$5"
    cat <<'STUB'
set -u
case "${GH_TOKEN:-}" in *[![:space:]]*) has=1 ;; *) case "${GITHUB_TOKEN:-}" in *[![:space:]]*) has=1 ;; *) has=0 ;; esac ;; esac
if [ "$has" = "0" ]; then
  if [ -n "${GH_CONFIG_DIR:-}" ]; then cfg="$GH_CONFIG_DIR"
  elif [ -n "${XDG_CONFIG_HOME:-}" ]; then cfg="$XDG_CONFIG_HOME/gh"
  else cfg="$HOME/.config/gh"; fi
  if [ ! -f "$cfg/hosts.yml" ]; then
    printf 'To get started with GitHub CLI, please run:  gh auth login\n' >&2
    printf 'Alternatively, populate the GH_TOKEN environment variable with a GitHub API authentication token.\n' >&2
    exit 4
  fi
fi
[ "$MODE" = "all-fail" ] && exit 1
jqf() { local a prev=""; for a in "$@"; do if [ "$prev" = "--jq" ]; then printf '%s' "$a"; return 0; fi; prev="$a"; done; return 1; }
jqexpr="$(jqf "$@")" || jqexpr=""
now="$(date +%s)"
case "$*" in
  *"pulls?state=open"*)
    if [ "$jqexpr" = "length" ]; then
      case "$*" in *page=2*) printf '0\n' ;; *) printf '%s\n' "$OPEN1" ;; esac
    else printf '[]\n'; fi
    exit 0 ;;
  *"pulls?state=closed"*)
    case "$*" in *page=2*) exit 0 ;; esac
    i=0; while [ "$i" -lt "$LANDS" ]; do printf '%s\n' "$(( now - 600 - i * 600 ))"; i=$(( i + 1 )); done
    exit 0 ;;
  *"/issues/"*)
    [ "$MODE" = "evidence-fail" ] && exit 1
    printf '%s\001%s\n' "$LAB" "$TITLE"
    exit 0 ;;
esac
exit 0
STUB
  } > "$O/gh-rest/gh"
  chmod +x "$O/gh-rest/gh"
}

# A worktree whose origin names a GitHub slug — `land_backlog_repo` derives it and there is deliberately
# no env override (an ambient switch that points the gate at an empty repo is a bypass).
WT="$TMP/wt"; mkdir -p "$WT"
git -C "$WT" init -q 2>/dev/null
git -C "$WT" remote add origin https://github.com/daniel-ospina/agent-infra.git 2>/dev/null
BRIEF="$TMP/brief.txt"
{ printf 'RESEARCH FIRST\n'; "$HERE/brief-gate.sh" --section lane; } > "$BRIEF"
[ -s "$BRIEF" ] || { echo "❌ could not render the compliant brief fixture"; exit 2; }

# run_lane <open1> <lands24> <labels> <title> <mode> <tag> <logname> <acct-home> [extra VAR=val …]
# → sets LANE_RC; the log is $TMP/<logname>, the `pi` stub's log is PI_LOG (reset per arm).
# ⛔ THE ACCOUNT HOME IS A FIXTURE, VIA `gh_auth_account_home`'S OWN NAME. The resolver's only
# non-hermetic read is the passwd record, and on CI there is no `~/.config/gh` at all — so a suite that
# used the runner's real account home would be green on a cell that happens to hold a token and red
# everywhere else, which is a measurement of the runner and not of the gate. Replacing the LOOKUP (not
# the resolution, the export, the refusal text or the gate) is the same seam `cell-self-pin.sh` and
# `cloud-cell-bringup.sh` declare for the same read; nothing a `keys.env` sets can reach it.
run_lane() {
  local o1="$1" l24="$2" lab="$3" ti="$4" mode="$5" tag="$6" name="$7" acct="$8"; shift 8
  gh_install "$o1" "$l24" "$lab" "$ti" "$mode"
  : > "$PI_LOG"
  ( cd "$WT" && env -u GH_CONFIG_DIR -u XDG_CONFIG_HOME -u GH_TOKEN -u GITHUB_TOKEN \
      O="$O" KIND=bg TAG="$tag" HOME="$LANE_HOME" \
      PATH="$O/gh-rest:$TMP/bin:$PATH" \
      MAX_LOAD=999999 DISK_MIN_FREE_MB=1 DISK_GATE_PATH="$TMP" LANE_TIMEOUT=5 "$@" \
      bash -c 'ACCT_FIX="$4"; . "$1" >/dev/null 2>&1 || exit 78; gh_auth_account_home() { printf "%s\n" "$ACCT_FIX"; }; run_agent 5 "$2" "$3" "bg ${TAG:-}"' \
      _ "$SG" "$TMP/$name.log" "$BRIEF" "$acct" ) >/dev/null 2>&1
  LANE_RC=$?
}

# ═══ §A THE RESOLVER ═════════════════════════════════════════════════════════════════════════════
echo
echo "=== §A gh_auth_resolve / gh_auth_ensure: gh's own order, plus the account-home fallback ==="
r="$(u ". '$GH_AUTH'; gh_auth_resolve '$LANE_HOME' '$ENVF' '$ACCT'")"
[ "$r" = "account|$ACCT/.config/gh" ]; rc=$?
ck "A1 a redirected HOME with no config of its own resolves to the ACCOUNT home's store ('$r')" $rc
r="$(u ". '$GH_AUTH'; gh_auth_resolve '$LANE_HOME' '$ENVF' '$ACCT_EMPTY'")"
[ "$r" = "none|" ]; rc=$?
ck "A2 …and with no store in EITHER home it says none, never a directory it did not verify ('$r')" $rc
r="$(u ". '$GH_AUTH'; GH_CONFIG_DIR='$TMP/cfg-a' gh_auth_resolve '$LANE_HOME' '$ENVF' '$ACCT'")"
[ "$r" = "ambient|$TMP/cfg-a" ]; rc=$?
ck "A3 an ambient GH_CONFIG_DIR that holds hosts.yml wins and is left alone ('$r')" $rc
r="$(u ". '$GH_AUTH'; GH_CONFIG_DIR='$TMP/absent' gh_auth_resolve '$LANE_HOME' '$ENVF' '$ACCT'")"
[ "$r" = "ambient-missing|$TMP/absent" ]; rc=$?
ck "A4 an ambient GH_CONFIG_DIR that holds NOTHING is reported, never silently overridden ('$r')" $rc
r="$(u ". '$GH_AUTH'; XDG_CONFIG_HOME='$ACCT/.config' gh_auth_resolve '$LANE_HOME' '$ENVF' '$ACCT'")"
[ "$r" = "xdg|$ACCT/.config/gh" ]; rc=$?
ck "A5 \$XDG_CONFIG_HOME/gh is next in gh's order ('$r')" $rc
r="$(u ". '$GH_AUTH'; GH_TOKEN=fixture-token gh_auth_resolve '$LANE_HOME' '$ENVF' '$ACCT'")"
[ "$r" = "token|" ]; rc=$?
ck "A6 a non-blank token NAME outranks every config dir, so the read cannot be blamed on one ('$r')" $rc
r="$(u ". '$GH_AUTH'; GH_TOKEN='   ' gh_auth_resolve '$LANE_HOME' '$ENVF' '$ACCT'")"
[ "$r" = "account|$ACCT/.config/gh" ]; rc=$?
ck "A7 …and a BLANK one is not a credential (gh treats it as set-then-useless) ('$r')" $rc

# The env file, parsed STATICALLY. Both the plain and the `export -p`/`declare -x` shapes keys.env really
# carries, and the arm that proves the file is never executed.
printf 'export GH_CONFIG_DIR=%s\n' "$TMP/cfg-a" > "$ENVF"
r="$(u ". '$GH_AUTH'; gh_auth_resolve '$LANE_HOME' '$ENVF' '$ACCT'")"
[ "$r" = "keys|$TMP/cfg-a" ]; rc=$?
ck "A8 a keys.env 'export GH_CONFIG_DIR=…' is honoured (finding 1's arm, not regressed) ('$r')" $rc
r="$(u ". '$GH_AUTH'; gh_auth_ensure '$LANE_HOME' '$ENVF' '$ACCT' >/dev/null; printf '%s' \"\${GH_CONFIG_DIR:-<unset>}\"")"
[ "$r" = "$TMP/cfg-a" ]; rc=$?
ck "A9 …and gh_auth_ensure EXPORTS it, so the gate, the lane and its workers read one store ('$r')" $rc
printf 'declare -x XDG_CONFIG_HOME="%s"\n' "$ACCT/.config" > "$ENVF"
r="$(u ". '$GH_AUTH'; gh_auth_resolve '$LANE_HOME' '$ENVF' '$ACCT'")"
[ "$r" = "keys-xdg|$ACCT/.config/gh" ]; rc=$?
ck "A10 the declare -x XDG_CONFIG_HOME shape is read too, and becomes <xdg>/gh ('$r')" $rc
printf 'export GH_CONFIG_DIR=%s   # a trailing comment\n' "$TMP/cfg-a" > "$ENVF"
r="$(u ". '$GH_AUTH'; gh_auth_resolve '$LANE_HOME' '$ENVF' '$ACCT'")"
[ "$r" = "keys|$TMP/cfg-a" ]; rc=$?
ck "A11 a trailing comment and quotes are stripped, not swallowed into the path ('$r')" $rc
printf 'touch "$TMP/PWNED"\nexport GH_CONFIG_DIR=%s\n' "$TMP/cfg-a" > "$ENVF"
u ". '$GH_AUTH'; gh_auth_resolve '$LANE_HOME' '$ENVF' '$ACCT' >/dev/null"
[ ! -e "$TMP/PWNED" ]; rc=$?
ck "A12 the env file is PARSED, not executed (a shebang-less 'touch' line never ran)" $rc
printf 'export GH_CONFIG_DIR=relative/dir\n' > "$ENVF"
r="$(u ". '$GH_AUTH'; gh_auth_resolve '$LANE_HOME' '$ENVF' '$ACCT'")"
[ "$r" = "account|$ACCT/.config/gh" ]; rc=$?
ck "A13 a non-absolute value is treated as ABSENT rather than used as a relative path ('$r')" $rc
rm -f "$ENVF"

# The cause text is what the refusal prints, so it must speak only on a POSITIVE absence.
c="$(u ". '$GH_AUTH'; gh_auth_cause '$LANE_HOME' /nonexistent '$ACCT_EMPTY'")"
{ case "$c" in *'no gh credential for the lane'*) ck "A14 the cause names a MISSING credential when every dir gh would read was checked" 0 ;;
             *) ck "A14 the cause names a MISSING credential (got '$c')" 1 ;; esac; }
c="$(u ". '$GH_AUTH'; GH_CONFIG_DIR='$TMP/absent' gh_auth_cause '$LANE_HOME' /nonexistent '$ACCT_EMPTY'")"
{ case "$c" in *"GH_CONFIG_DIR=$TMP/absent is set but holds no hosts.yml"*) ck "A15 …and names an ambient dir that holds nothing, which is a DIFFERENT remedy" 0 ;;
             *) ck "A15 …and names an ambient dir that holds nothing (got '$c')" 1 ;; esac; }
c="$(u ". '$GH_AUTH'; gh_auth_cause '$LANE_HOME' /nonexistent '$ACCT'")"
[ -z "$c" ]; rc=$?
ck "A16 …and says NOTHING when a credential resolves (the caller must not blame it)" $rc

# ═══ §B THE GATE, END TO END ═════════════════════════════════════════════════════════════════════
echo
echo "=== §B run_agent: the lane's gh is credentialed, and the refusal names the right cause ==="
# B1 is the definition of done: redirected HOME, no ambient GH_CONFIG_DIR, the account home holding the
# store → the gate READS the P0 evidence and the lane starts. Pre-change this refused with 74 and the
# log blamed the PR queue.
run_lane 81 15 "P0-blocker,harness" "crash on boot" ok 2509 b1 "$ACCT"
{ [ "$LANE_RC" -eq 0 ] && [ -s "$PI_LOG" ]; }; rc=$?
ck "B1 redirected HOME + the account store ⇒ a P0-blocker is EXEMPT and the lane RUNS (rc=$LANE_RC)" $rc
grep -q '\[gh-auth\] state=account' "$TMP/b1.log"; rc=$?
ck "B1b …and the lane log says which store it resolved, not just that it worked" $rc
grep -q 'EXEMPT .*P0 work' "$TMP/b1.log"; rc=$?
ck "B1c …and the exemption was READ, not assumed" $rc

# B2: no credential anywhere → HELD, no session, and the remedy is the CREDENTIAL one.
run_lane 81 15 "P0-blocker,harness" "crash on boot" ok 2510 b2 "$ACCT" \
  XDG_CONFIG_HOME="$TMP/nothing" GH_CONFIG_DIR="$TMP/nothing-else"
# (a redirected HOME plus an ambient GH_CONFIG_DIR that holds nothing is the shape the gate must NAME)
{ [ "$LANE_RC" -eq 74 ] && [ ! -s "$PI_LOG" ]; }; rc=$?
ck "B2 a lane whose gh has no credential is HELD with 74 and NO session started (rc=$LANE_RC)" $rc
grep -q 'UNREADABLE open-PR count' "$TMP/b2.log"; rc=$?
ck "B2b …the verdict is still the three-state UNREADABLE, not a fake OK" $rc
grep -q 'THIS IS NOT THE LANDING RATIO' "$TMP/b2.log"; rc=$?
ck "B2c …and the refusal says so IN CAPITALS, naming the credential" $rc
grep -q 'Remedy: land/fix the open PRs' "$TMP/b2.log" && rc=1 || rc=0
ck "B2d …and does NOT print the ratio remedy (acting on that meant landing PRs to fix a hosts.yml)" $rc
grep -q 'No agent started, nothing consumed' "$TMP/b2.log"; rc=$?
ck "B2e …and still leaves the refusal readable (#2210), rather than nothing consumable" $rc

# B2f: the same cause with NOTHING ambient at all — the account home has no store either. This is the
# arm that must not degrade into "the credential is fine": gh_auth_account_home is replaced by a fixture
# (a function override, not an env switch), so the answer does not depend on the runner's own home.
: > "$PI_LOG"; gh_install 81 15 "P0-blocker,harness" "crash on boot" ok
( cd "$WT" && env -u GH_CONFIG_DIR -u XDG_CONFIG_HOME -u GH_TOKEN -u GITHUB_TOKEN \
    O="$O" KIND=bg TAG=2511 HOME="$LANE_HOME" PATH="$O/gh-rest:$TMP/bin:$PATH" \
    MAX_LOAD=999999 DISK_MIN_FREE_MB=1 DISK_GATE_PATH="$TMP" LANE_TIMEOUT=5 \
    bash -c 'ACCT_FIX="$2"; . "$1" >/dev/null 2>&1 || exit 78
             gh_auth_account_home() { printf "%s\n" "$ACCT_FIX"; }
             run_agent 5 "$3" "$4" "bg ${TAG:-}"' \
    _ "$SG" "$ACCT_EMPTY" "$TMP/b2f.log" "$BRIEF" ) >/dev/null 2>&1
rc2f=$?
{ [ "$rc2f" -eq 74 ] && [ ! -s "$PI_LOG" ]; }; rc=$?
ck "B2f no store in EITHER home ⇒ HELD (rc=$rc2f), and the pi stub never ran" $rc
grep -q 'no gh credential for the lane' "$TMP/b2f.log"; rc=$?
ck "B2f2 …and the refusal names the credential with the dirs it checked" $rc
grep -q '\[gh-auth\] state=none' "$TMP/b2f.log"; rc=$?
ck "B2f3 …and the lane log carries state=none, so the land-backlog line is not the only evidence" $rc

# B3: the module absent (a $O half-synced by a commit that predates it) changes NOTHING but the log.
# ⛔ THE CREDENTIAL IS GIVEN AMBIENTLY HERE ON PURPOSE, so this arm tests the ONE thing it claims: an
# absent instrument does not itself refuse a lane. (Without the resolver AND without an ambient store the
# lane is held for the honest reason — gh has no credential — which is B2f's arm, not this one.)
: > "$PI_LOG"; gh_install 0 40 "bug" "a normal issue" ok
( cd "$WT" && env -u XDG_CONFIG_HOME -u GH_TOKEN -u GITHUB_TOKEN \
    O="$O" KIND=bg TAG=2512 HOME="$LANE_HOME" GH_CONFIG_DIR="$ACCT/.config/gh" \
    PATH="$O/gh-rest:$TMP/bin:$PATH" \
    MAX_LOAD=999999 DISK_MIN_FREE_MB=1 DISK_GATE_PATH="$TMP" LANE_TIMEOUT=5 \
    bash -c 'ACCT_FIX="$4"; . "$1" >/dev/null 2>&1 || exit 78; gh_auth_account_home() { printf "%s\n" "$ACCT_FIX"; }; unset -f gh_auth_log; run_agent 5 "$2" "$3" "bg ${TAG:-}"' \
    _ "$SG" "$TMP/b3.log" "$BRIEF" "$ACCT" ) >/dev/null 2>&1
rc3=$?
{ [ "$rc3" -eq 0 ] && [ -s "$PI_LOG" ]; }; rc=$?
ck "B3 an ABSENT resolver is reported and never refuses the lane (rc=$rc3) — an instrument is not a gate" $rc
grep -q '\[gh-auth\] UNAVAILABLE' "$TMP/b3.log"; rc=$?
ck "B3b …and the log names it, rather than leaving the lane to discover it at its first gh call" $rc

# B3c: with the module ABSENT and the read failing, the refusal must not claim a credential it never
# resolved. Pre-change this arm could not exist; it exists because the first cut of this change printed
# "the lane's gh IS credentialed (state=unknown)" whenever `gh_auth_cause` could not speak.
: > "$PI_LOG"; gh_install 81 15 "bug" "a normal issue" all-fail
( cd "$WT" && env -u GH_CONFIG_DIR -u XDG_CONFIG_HOME -u GH_TOKEN -u GITHUB_TOKEN \
    O="$O" KIND=bg TAG=2517 HOME="$LANE_HOME" PATH="$O/gh-rest:$TMP/bin:$PATH" \
    MAX_LOAD=999999 DISK_MIN_FREE_MB=1 DISK_GATE_PATH="$TMP" LANE_TIMEOUT=5 \
    bash -c '. "$1" >/dev/null 2>&1 || exit 78; unset -f gh_auth_log gh_auth_cause gh_auth_resolve gh_auth_ensure; run_agent 5 "$2" "$3" "bg ${TAG:-}"' \
    _ "$SG" "$TMP/b3c.log" "$BRIEF" ) >/dev/null 2>&1
rc3c=$?
[ "$rc3c" -eq 74 ]; rc=$?
ck "B3c an absent resolver + a failed read is still HELD (rc=$rc3c), so the gate keeps its teeth" $rc
grep -q 'IS credentialed' "$TMP/b3c.log" && rc=1 || rc=0
ck "B3c2 …and the refusal does NOT claim a credential it never resolved (no 'IS credentialed')" $rc
grep -q 'could NOT be resolved either' "$TMP/b3c.log"; rc=$?
ck "B3c3 …it names the unresolved state and points at the lane's own gh, rather than guessing" $rc

# B4: the falsifier in the ratio direction — a credential present and a genuine overshoot still HOLDS,
# with the RATIO remedy (the pre-change tree printed that remedy on the wrong arm, so both arms are
# asserted separately here).
run_lane 81 15 "bug" "a normal issue" ok 2513 b4 "$ACCT"
{ [ "$LANE_RC" -eq 74 ] && [ ! -s "$PI_LOG" ]; }; rc=$?
ck "B4 a genuinely exceeded ratio still HOLDS creation (rc=$LANE_RC), credential or not" $rc
grep -q 'LAND-BACKLOG 81 open' "$TMP/b4.log"; rc=$?
ck "B4b …naming the two measured numbers" $rc
grep -q 'Remedy: land/fix the open PRs' "$TMP/b4.log"; rc=$?
ck "B4c …and it DOES print the ratio remedy, because this read resolved" $rc
grep -q 'THIS IS NOT THE LANDING RATIO' "$TMP/b4.log" && rc=1 || rc=0
ck "B4d …and does not carry the credential clause, which would be a wrong cause in the other direction" $rc

# B5: the control — under the ceiling the same lane runs (the gate still allows what it should).
run_lane 3 40 "bug" "a normal issue" ok 2514 b5 "$ACCT"
{ [ "$LANE_RC" -eq 0 ] && [ -s "$PI_LOG" ]; }; rc=$?
ck "B5 under the ceiling the lane RUNS (rc=$LANE_RC) — the fix did not turn a hold into a blanket refusal" $rc
grep -q 'land-backlog\] OK' "$TMP/b5.log"; rc=$?
ck "B5b …and the log records the OK verdict" $rc

# B6: the exemption read fails (labels/title unreadable) while the ratio reads fine, OVER the ceiling: a
# P0 cannot exempt itself on an unreadable read, so it is HELD, and the log says WHICH read failed.
run_lane 81 15 "P0-blocker,harness" "crash on boot" evidence-fail 2515 b6 "$ACCT"
{ [ "$LANE_RC" -eq 74 ] && [ ! -s "$PI_LOG" ]; }; rc=$?
ck "B6 an UNREADABLE exemption does NOT exempt: the P0 is held over the ceiling (rc=$LANE_RC)" $rc
grep -q 'EXEMPTION-UNREADABLE' "$TMP/b6.log"; rc=$?
ck "B6b …the log names the EVIDENCE read as the failure, not the ratio (the documented token)" $rc
grep -q 'HELD, not judged non-urgent' "$TMP/b6.log"; rc=$?
ck "B6c …and says the P0 is HELD rather than judged non-urgent (the sentence the pre-change line lacked)" $rc
grep -q 'EXEMPT .*P0 work' "$TMP/b6.log" && rc=1 || rc=0
ck "B6d …and nothing claims the exemption was granted" $rc

# B7: the same failed evidence read UNDER the ceiling — the lane runs (the ratio allows it), and the log
# STILL says the evidence read failed. Pre-change nothing was said at all on this path, which is how an
# unreadable exemption came to read as "this issue is not urgent".
run_lane 3 40 "P0-blocker,harness" "crash on boot" evidence-fail 2516 b7 "$ACCT"
{ [ "$LANE_RC" -eq 0 ] && [ -s "$PI_LOG" ]; }; rc=$?
ck "B7 under the ceiling an unreadable exemption still starts the lane (rc=$LANE_RC) — it is measured, not held" $rc
grep -q 'EXEMPTION-UNREADABLE' "$TMP/b7.log"; rc=$?
ck "B7b …and the log still carries the failure, so 'OK' can no longer imply the issue was judged" $rc

echo
echo "───────────────────────────────────────"
echo "  passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
