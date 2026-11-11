#!/usr/bin/env bash
# gh-auth.test.sh — the LANE's `gh` credential: resolved, named, and never confused with the PR ratio
# (agent-infra#2509, the "never PROVIDED" arm).
#
# WHAT WAS BROKEN, and how each section is RED on the pre-change tree.
#
#   A lane runs with `HOME` redirected to the operational home (`/tmp/cell-home` on a cell) because
#   `record-review.sh`, the gh shim and the extensions live under `$CELL_HOME/.pi/agent`. `gh`'s
#   `hosts.yml` lives in the ACCOUNT home. Nothing SET `GH_CONFIG_DIR` on the
#   `nonblocking-dispatch.sh` → `spawn-gate.sh` path — ⛔ not "nothing in the tree": `git grep -n
#   'GH_CONFIG_DIR' origin/main -- scripts/` returns `worker-terminal.sh`, `objective.py` and
#   `beta-progress.py` as READERS (cited by SYMBOL — the line numbers a prior draft carried were rotted by
#   a rebase; re-derive with that grep), and not one
#   provider on the dispatch path — so `gh` inside the lane was unauthenticated, and the land-backlog gate
#   reported a MISSING CREDENTIAL as a PR-RATIO problem:
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
#     reason naming the cause (§B2 — `#2210`);
#   * a token name's precedence over the OTHER token name is gh's, not "first non-blank wins" (§A7e-A7h,
#     §B2h): a blank-but-set `GH_TOKEN` shadows a REAL `GITHUB_TOKEN` and every call fails, so the lane is
#     HELD and the refusal names the blank name — while a ZERO-LENGTH `GH_TOKEN` really does fall through
#     to `GITHUB_TOKEN` and must still RESOLVE, so the fix cannot buy its green by refusing a credential
#     gh would have used;
#   * WHICH NAME the blank value lands on, and WHERE the token block sits, are pinned too (§A7i-A7k, §B2i):
#     a blank `GITHUB_TOKEN` behind a real `GH_TOKEN` shadows NOTHING, and a blank token still outranks an
#     ambient store — two orderings that were unpinned at the head that introduced the ordered read, each
#     with a mutant that kept the suite at `passed: 61 failed: 0`.
#
# ⛔ HERMETIC: every arm runs `env -u GH_CONFIG_DIR -u XDG_CONFIG_HOME -u GH_TOKEN -u GITHUB_TOKEN` — the
# resolver/cause arms through `u()` (the `env -u … bash -c` helper above the `pi` stub — cited by SYMBOL,
# because a line number here is a claim that rots the moment this header grows a line), the end-to-end
# `run_lane` arms through the `env -u` it builds
# itself — so a runner that exports one of those (this fleet's cells DO) cannot move an arm in EITHER
# direction: the failure #2138 records in `test_objective.py`, one suite over, and the false BLOCK four
# `gh_auth_cause` arms produced before review round 14 put them under `u()` too. The passwd record is the
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
PASS=0; FAIL=0; SKIPPED=0
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
# LANE_STORE is a lane HOME that HOLDS the store, and XDG_EMPTY is a set-but-empty XDG dir: the shape
# where gh reads `<XDG>/gh` and never `$HOME/.config/gh` (below, A5b-A5d and B8).
LANE_STORE="$TMP/lane-store"; XDG_EMPTY="$TMP/xdg-empty"
mkdir -p "$LANE_STORE/.config/gh" "$XDG_EMPTY"
printf 'github.com:\n    user: fixture\n    oauth_token: gho_fixture\n' > "$ACCT/.config/gh/hosts.yml"
cp "$ACCT/.config/gh/hosts.yml" "$TMP/cfg-a/hosts.yml"
cp "$ACCT/.config/gh/hosts.yml" "$LANE_STORE/.config/gh/hosts.yml"
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
# It implements gh's order (GH_CONFIG_DIR → $XDG_CONFIG_HOME/gh → $HOME/.config/gh, behind a token), and
# when nothing resolves, prints gh's own two lines and exits 4.
# ⛔ AND THE TOKEN HALF IS gh's ORDER BETWEEN THE TWO NAMES, MEASURED (2.103.3), NOT "first NON-BLANK
# wins": the FIRST name holding a NON-EMPTY value decides, and an all-blank value IS the token gh sends
# (the API then answers 401) — the store is never read.
#     GH_TOKEN='   ' GITHUB_TOKEN=realtok gh auth token -> [three spaces]  GITHUB_TOKEN is never read
#     GH_TOKEN=''    GITHUB_TOKEN=realtok gh auth token -> realtok         a zero-length value falls through
# A fixture that answered "first NON-BLANK wins" SHARES THE MODULE'S OWN WRONG RULE, so no arm in this
# suite could see the bug the module had (`token|` for the first line above, and the gate then asserted
# the lane's gh IS credentialed). A7e-A7h and B2h exist to keep these two models apart.
gh_install() { # <open1> <lands24> <labels> <title> <mode: ok|evidence-fail|all-fail>
  mkdir -p "$O/gh-rest"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'OPEN1=%q\nLANDS=%q\nLAB=%q\nTITLE=%q\nMODE=%q\n' "$1" "$2" "$3" "$4" "$5"
    cat <<'STUB'
set -u
tok=""
if [ -n "${GH_TOKEN-}" ]; then tok="${GH_TOKEN}"
elif [ -n "${GITHUB_TOKEN-}" ]; then tok="${GITHUB_TOKEN}"; fi
case "$tok" in
  '')
    if [ -n "${GH_CONFIG_DIR:-}" ]; then cfg="$GH_CONFIG_DIR"
    elif [ -n "${XDG_CONFIG_HOME:-}" ]; then cfg="$XDG_CONFIG_HOME/gh"
    else cfg="$HOME/.config/gh"; fi
    if [ ! -f "$cfg/hosts.yml" ]; then
      printf 'To get started with GitHub CLI, please run:  gh auth login\n' >&2
      printf 'Alternatively, populate the GH_TOKEN environment variable with a GitHub API authentication token.\n' >&2
      exit 4
    fi ;;
  *[![:space:]]*) : ;;                                        # a real token: authenticated
  *) printf 'gh: HTTP 401: Bad credentials\n' >&2; exit 1 ;;  # blank-but-set: gh sends the whitespace
esac
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
# ⛔ A SET `XDG_CONFIG_HOME` IS A CHAIN WITH NO FALLBACK PAST IT, so `$HOME/.config/gh` is NOT gh's default
# in that shape — the manual's condition is that XDG is SET, not that a store exists under it, and Go's
# `os.UserConfigDir` answers a non-empty XDG unconditionally. Pre-fix the `home` arm was unguarded, so this
# shape answered `home` ("nothing to export") over a `gh` that reads `<XDG>/gh`, and the refusal then
# asserted "the lane's gh IS credentialed". The store IS a real credential gh will not find on its own, so
# it is exported under its OWN state (A5b/A5c), and the XDG-unset arm still resolves to plain `home` with
# nothing exported (A5d) so the fix cannot buy its green by exporting everywhere.
r="$(u ". '$GH_AUTH'; XDG_CONFIG_HOME='$XDG_EMPTY' gh_auth_resolve '$LANE_STORE' '$ENVF' '$ACCT_EMPTY'")"
[ "$r" = "home-xdg|$LANE_STORE/.config/gh" ]; rc=$?
ck "A5b XDG SET with no store under it does NOT make \$HOME/.config/gh gh's default, and the store there is named as its own state ('$r')" $rc
r="$(u ". '$GH_AUTH'; XDG_CONFIG_HOME='$XDG_EMPTY' gh_auth_ensure '$LANE_STORE' '$ENVF' '$ACCT_EMPTY' >/dev/null; printf '%s' \"\${GH_CONFIG_DIR:-<unset>}\"")"
[ "$r" = "$LANE_STORE/.config/gh" ]; rc=$?
ck "A5c …and it is EXPORTED, because gh would never read it while XDG is set ('$r')" $rc
r="$(u ". '$GH_AUTH'; gh_auth_ensure '$LANE_STORE' '$ENVF' '$ACCT_EMPTY' >/dev/null; printf '%s|%s' \"\$(gh_auth_resolve '$LANE_STORE' '$ENVF' '$ACCT_EMPTY')\" \"\${GH_CONFIG_DIR:-<unset>}\"")"
[ "$r" = "home|$LANE_STORE/.config/gh|<unset>" ]; rc=$?
ck "A5d …while with XDG UNSET it is still gh's own default: state=home and NOTHING exported (the export is not blanket) ('$r')" $rc
r="$(u ". '$GH_AUTH'; GH_TOKEN=fixture-token gh_auth_resolve '$LANE_HOME' '$ENVF' '$ACCT'")"
[ "$r" = "token|" ]; rc=$?
ck "A6 a non-blank token NAME outranks every config dir, so the read cannot be blamed on one ('$r')" $rc
# ⛔ A BLANK-BUT-SET TOKEN NAME IS ITS OWN STATE, MEASURED (gh 2.103.3, fixture store):
#     $ GH_TOKEN='   ' GH_CONFIG_DIR=<store> gh auth token   ->  [three spaces], rc 0 — the store is NEVER read
#     $ GH_TOKEN=''    GH_CONFIG_DIR=<store> gh auth token   ->  the store's token
# so reporting `account|<dir>` for a blank-but-set token claimed a store gh will not consult, and the gate
# then printed "the lane's gh IS credentialed" over a lane whose every gh call fails. A7-A7d pin the state;
# B2g pins what the REFUSAL says when it is the cause.
r="$(u ". '$GH_AUTH'; GH_TOKEN='   ' gh_auth_resolve '$LANE_HOME' '$ENVF' '$ACCT'")"
[ "$r" = "token-blank|GH_TOKEN" ]; rc=$?
ck "A7 …and a BLANK-but-SET one is its own state, never papered over with a store gh will not read ('$r')" $rc
r="$(u ". '$GH_AUTH'; GITHUB_TOKEN='  ' gh_auth_resolve '$LANE_HOME' '$ENVF' '$ACCT'")"
[ "$r" = "token-blank|GITHUB_TOKEN" ]; rc=$?
ck "A7b …the same for GITHUB_TOKEN, and the state names WHICH name is shadowing ('$r')" $rc
r="$(u ". '$GH_AUTH'; GH_TOKEN='' gh_auth_resolve '$LANE_HOME' '$ENVF' '$ACCT'")"
[ "$r" = "account|$ACCT/.config/gh" ]; rc=$?
ck "A7c …while a ZERO-LENGTH value is NOT a shadow: gh falls through to the store (measured) and it must resolve ('$r')" $rc
r="$(u ". '$GH_AUTH'; GH_TOKEN='   ' gh_auth_ensure '$LANE_HOME' '$ENVF' '$ACCT' >/dev/null; printf '%s' \"\${GH_CONFIG_DIR:-<unset>}\"")"
[ "$r" = "<unset>" ]; rc=$?
ck "A7d …and NOTHING is exported for it — an export gh ignores reads as a fix ('$r')" $rc
# ⛔ AND THE TWO NAMES HAVE AN ORDER, WHICH IS NOT "FIRST NON-BLANK WINS". Measured (gh 2.103.3, no store
# reachable):
#     $ GH_TOKEN='   ' GITHUB_TOKEN=realtok gh auth token   ->  [three spaces]   GITHUB_TOKEN never read
#     $ GH_TOKEN=''    GITHUB_TOKEN=realtok gh auth token   ->  realtok          a zero-length value falls through
# so gh takes the FIRST name holding a NON-EMPTY value and uses it EVEN WHEN IT IS BLANK — a blank-but-SET
# `GH_TOKEN` shadows a REAL `GITHUB_TOKEN` exactly as it shadows a store. Asking the two names INDEPENDENTLY
# (`present`, then `blank`) answered `token|` for that shape while `gh_auth_cause` stayed silent, so the gate
# printed "the lane's gh IS credentialed (state=token)" over a lane whose every call fails — the same false
# claim `token-blank` was added to remove, one shape over. A7e-A7h pin the precedence, in BOTH directions:
# the shadowed arm, and the arm where gh really does fall through (so the fix cannot buy its green by
# refusing a credential gh would have used).
r="$(u ". '$GH_AUTH'; GH_TOKEN='   ' GITHUB_TOKEN=fixture-token gh_auth_resolve '$LANE_HOME' '$ENVF' '$ACCT'")"
[ "$r" = "token-blank|GH_TOKEN" ]; rc=$?
ck "A7e a BLANK-but-SET GH_TOKEN SHADOWS a real GITHUB_TOKEN — gh reads the whitespace, never the other name ('$r')" $rc
r="$(u ". '$GH_AUTH'; GH_TOKEN='' GITHUB_TOKEN=fixture-token gh_auth_resolve '$LANE_HOME' '$ENVF' '$ACCT'")"
[ "$r" = "token|" ]; rc=$?
ck "A7f …while a ZERO-LENGTH GH_TOKEN DOES fall through to a real GITHUB_TOKEN: the precedence must not become a refusal ('$r')" $rc
r="$(u ". '$GH_AUTH'; GH_TOKEN='   ' GITHUB_TOKEN=fixture-token gh_auth_ensure '$LANE_HOME' '$ENVF' '$ACCT' >/dev/null; printf '%s' \"\${GH_CONFIG_DIR:-<unset>}\"")"
[ "$r" = "<unset>" ]; rc=$?
ck "A7g …and NOTHING is exported for the shadowed shape, even with a usable-looking GITHUB_TOKEN beside it ('$r')" $rc
c="$(u ". '$GH_AUTH'; GH_TOKEN='   ' GITHUB_TOKEN=fixture-token gh_auth_cause '$LANE_HOME' '$ENVF' '$ACCT'")"
{ case "$c" in *'GH_TOKEN is set but BLANK'*) ck "A7h …and the cause names GH_TOKEN, so no refusal can assert the lane IS credentialed ('$c')" 0 ;;
             *) ck "A7h …and the cause names GH_TOKEN (got '$c')" 1 ;; esac; }
# ⛔ THE MIRROR DIRECTION, AND THE POSITION OF THE WHOLE BLOCK, ARE THE OTHER HALF OF "ONE ORDERED READ" —
# and a suite that pins only the shape it was written for cannot tell an ordering from a mirror rule. Both
# mutants below kept this suite at 61/61 before A7i-A7k existed (measured at `f3adab923`, the head that
# introduced the ordered read and where this file had 61 arms; the same two mutants were re-run at 75 arms
# and are reported with the arms that kill them):
#   M4 — "ANY set-but-all-blank name shadows the other" (the model `worker-terminal.sh`'s blank-token clear
#        states verbatim, "a blank one in either hides a valid one") answers `token-blank|GITHUB_TOKEN` where
#        gh answers `realtok`;
#   M6 — the token block moved AFTER the `ambient` arm answers `ambient|<dir>` where gh reads the whitespace.
# A6 could not see M4 (it leaves `GITHUB_TOKEN` unset) and no arm could see M6 (every token arm runs through
# `u()`, which unsets `GH_CONFIG_DIR`). Each mutant restores the exact false claim this PR removes: the gate
# then prints "the lane's gh IS credentialed" over a lane whose every call fails.
r="$(u ". '$GH_AUTH'; GH_TOKEN=realtok GITHUB_TOKEN='   ' gh_auth_resolve '$LANE_HOME' '$ENVF' '$ACCT'")"
[ "$r" = "token|" ]; rc=$?
ck "A7i a BLANK GITHUB_TOKEN behind a REAL GH_TOKEN shadows NOTHING: a blank value matters only on the name gh RESOLVES ('$r')" $rc
c="$(u ". '$GH_AUTH'; GH_TOKEN=realtok GITHUB_TOKEN='   ' gh_auth_cause '$LANE_HOME' '$ENVF' '$ACCT'")"
[ -z "$c" ]; rc=$?
ck "A7j …and the cause stays SILENT for it, so the gate cannot blame a credential gh is using ('$c')" $rc
r="$(u ". '$GH_AUTH'; GH_CONFIG_DIR='$TMP/cfg-a' GH_TOKEN='   ' gh_auth_resolve '$LANE_HOME' '$ENVF' '$ACCT'")"
[ "$r" = "token-blank|GH_TOKEN" ]; rc=$?
ck "A7k …and a blank token OUTRANKS an ambient store that really holds hosts.yml — the token block comes before every store arm ('$r')" $rc

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
# ⛔ A10 PINS THE STATE, NOT THE EXPORT (review round 18, P2): deleting `keys-xdg` from `gh_auth_ensure`'s
# export case left the suite at 116/0, while the three sibling arms of the same decision all redden when
# dropped (`keys` → A9, `home-xdg` → A5c, `account` → B1/B4b/B5/B7). It is load-bearing: the env file's
# `XDG_CONFIG_HOME=` is parsed statically and never exported, so without this the store resolves and the
# lane is handed no credential at all — and `gh_auth_log`'s `keys-xdg)` text claims "…and exported as
# GH_CONFIG_DIR", a claim nothing verified until this arm.
r="$(u ". '$GH_AUTH'; gh_auth_ensure '$LANE_HOME' '$ENVF' '$ACCT' >/dev/null; printf '%s' \"\${GH_CONFIG_DIR:-<unset>}\"")"
[ "$r" = "$ACCT/.config/gh" ]; rc=$?
ck "A10b …and gh_auth_ensure EXPORTS it, so a statically-parsed XDG store reaches the lane at all ('$r')" $rc
printf 'export GH_CONFIG_DIR=%s   # a trailing comment\n' "$TMP/cfg-a" > "$ENVF"
r="$(u ". '$GH_AUTH'; gh_auth_resolve '$LANE_HOME' '$ENVF' '$ACCT'")"
[ "$r" = "keys|$TMP/cfg-a" ]; rc=$?
ck "A11 a trailing comment and quotes are stripped, not swallowed into the path ('$r')" $rc
# ⛔ THE PAYLOAD MUST BE OBSERVABLE FROM THE SHELL THAT WOULD EXECUTE IT. `u()` is `env -u … bash -c`, where
# `TMP` is NOT set (the suite's `TMP` is an unexported shell variable), so a payload written with `\"$TMP/PWNED\"`
# via single-quoted printf expanded to `/PWNED` — a path nothing could ever touch as non-root — while the
# assertion below read `$TMP/PWNED` in the OUTER shell. The arm then passed whether the file was parsed or
# executed (verified: the `. \"$f\"` mutant kept it green). Baking the ABSOLUTE path at fixture time makes the
# same assertion bite, and the resolve is asserted too so the arm cannot pass by failing to parse the file.
printf 'touch %s/PWNED\nexport GH_CONFIG_DIR=%s\n' "$TMP" "$TMP/cfg-a" > "$ENVF"
r="$(u ". '$GH_AUTH'; gh_auth_resolve '$LANE_HOME' '$ENVF' '$ACCT'")"
{ [ "$r" = "keys|$TMP/cfg-a" ] && [ ! -e "$TMP/PWNED" ]; }; rc=$?
ck "A12 the env file is PARSED, not executed (a shebang-less 'touch' line never ran)" $rc
rm -f "$TMP/PWNED"   # so no later arm can inherit the marker
printf 'export GH_CONFIG_DIR=relative/dir\n' > "$ENVF"
# ⛔ THE FIXTURE HAS TO MAKE THE RELATIVE PATH RESOLVE, OR THE ARM CANNOT FAIL (review round 20, P3):
# measured, `case "$val" in *)` (accept ANY value) left the suite at 122/0, because the suite's cwd holds
# no `relative/dir` and BOTH parsers therefore fell through to `account`. It is not cosmetic: in a cwd
# that DOES hold one, the shipped parser answers `none` while such a mutant answers `keys|relative/dir`
# and `gh_auth_ensure` exports it — a repo-relative store becoming the lane's credential, which is the
# reason the absolute-only rule exists. So the resolve runs from a cwd built to contain exactly that path.
RELCWD="$TMP/relcwd"; mkdir -p "$RELCWD/relative/dir"; cp "$ACCT/.config/gh/hosts.yml" "$RELCWD/relative/dir/hosts.yml"
r="$(u "cd '$RELCWD' && . '$GH_AUTH'; gh_auth_resolve '$LANE_HOME' '$ENVF' '$ACCT'")"
[ "$r" = "account|$ACCT/.config/gh" ]; rc=$?
ck "A13 a non-absolute value is treated as ABSENT rather than used as a relative path — even when it RESOLVES from the cwd ('$r')" $rc
rm -f "$ENVF"

# ⛔ THE OTHER DOCUMENTED SHAPES (review rounds 20-21, P3): `_gh_auth_file_value`'s doc lists `NAME=`,
# `export NAME=`, `declare -x NAME=`, `readonly NAME=` and one layer of quotes, and NONE of the non-`export`
# forms had an arm that could fail — deleting the single-quote arm left 122/0, dropping `readonly` from the
# keyword alternation left 122/0, and `typeset` (in the same alternation, so a live branch) left 124/0
# one round later. One fixture per shape, and the comment now names exactly what is pinned rather than
# implying the family is covered.
printf "export GH_CONFIG_DIR='%s'\n" "$TMP/cfg-a" > "$ENVF"
r="$(u ". '$GH_AUTH'; gh_auth_resolve '$LANE_HOME' '$ENVF' '$ACCT'")"
[ "$r" = "keys|$TMP/cfg-a" ]; rc=$?
ck "A11b …and a SINGLE-quoted value is unquoted, not swallowed ('$r')" $rc
printf 'readonly GH_CONFIG_DIR=%s\n' "$TMP/cfg-a" > "$ENVF"
r="$(u ". '$GH_AUTH'; gh_auth_resolve '$LANE_HOME' '$ENVF' '$ACCT'")"
[ "$r" = "keys|$TMP/cfg-a" ]; rc=$?
ck "A11c …and the \`readonly\` keyword is honoured, not only \`declare -x\`/\`export\` ('$r')" $rc
printf 'typeset GH_CONFIG_DIR=%s\n' "$TMP/cfg-a" > "$ENVF"
r="$(u ". '$GH_AUTH'; gh_auth_resolve '$LANE_HOME' '$ENVF' '$ACCT'")"
[ "$r" = "keys|$TMP/cfg-a" ]; rc=$?
ck "A11d …and \`typeset\`, the third keyword in that alternation ('$r')" $rc
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
# ⛔ THE CAUSE HAS TO SPEAK FOR `token-blank`, or the refusal falls through to the arm that asserts the lane
# "IS credentialed" — a confident false statement about the exact datum this change exists to measure.
c="$(u ". '$GH_AUTH'; GH_TOKEN='   ' gh_auth_cause '$LANE_HOME' '$ENVF' '$ACCT'")"
{ case "$c" in *'GH_TOKEN is set but BLANK'*) ck "A17 …and a BLANK-but-SET token is named as the CREDENTIAL cause, by its own name ('$c')" 0 ;;
             *) ck "A17 …and a BLANK-but-SET token is named as the CREDENTIAL cause (got '$c')" 1 ;; esac; }
c="$(u ". '$GH_AUTH'; GH_TOKEN='   ' gh_auth_cause '$LANE_HOME' '$ENVF' '$ACCT_EMPTY'")"
{ case "$c" in *'GH_TOKEN is set but BLANK'*) ck "A17b …and it stays the cause with no store anywhere: the shadow is not a directory question" 0 ;;
             *) ck "A17b …and it stays the cause with no store anywhere (got '$c')" 1 ;; esac; }

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
grep -q "THIS IS NOT THE LANDING RATIO: GH_CONFIG_DIR=$TMP/nothing-else is set but holds no hosts.yml" "$TMP/b2.log"; rc=$?
ck "B2c …and the refusal says so IN CAPITALS, AND names the credential it checked (the ambient dir, which holds nothing)" $rc
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
# ⛔ THE `THIS IS NOT THE LANDING RATIO:` PREFIX IS LOAD-BEARING, exactly as in B2g2/B2h2/B2i2 — and here
# it is the ONLY thing that separates the two producers: on this path `land_backlog_exempt_note` ALSO
# interpolates `gh_auth_cause` (`spawn-gate.sh`'s NOTE arm prints "the … read FAILED (%s)"), so the bare
# sentence is in the log whether or not the REFUSAL carried it. Measured: with the refusal's `%s` replaced
# by a fixed phrase this arm stayed GREEN while the REFUSED line no longer named the cause at all.
grep -q 'THIS IS NOT THE LANDING RATIO: no gh credential for the lane' "$TMP/b2f.log"; rc=$?
ck "B2f2 …and the REFUSAL names the credential with the dirs it checked (the NOTE prints the same cause, so the prefix is what makes this the refusal's)" $rc
grep -q '\[gh-auth\] state=none' "$TMP/b2f.log"; rc=$?
ck "B2f3 …and the lane log carries state=none, so the land-backlog line is not the only evidence" $rc
# ⛔ AND THE NOTE'S OWN CREDENTIAL-CAUSE BRANCH NEEDS AN ARM OF ITS OWN, or its "⛔ AND IT SEPARATES THE
# TWO CAUSES IT CAN SEE" is a claim with no assertion: `B6b`/`B7b` only assert the `EXEMPTION-UNREADABLE`
# token, which BOTH NOTE arms print. Measured before this arm existed: deleting the NOTE's
# `cause="$(gh_auth_cause …)"` (so the branch can never fire) left the suite at 75/0 with nothing red.
# This is the shape that reaches it — the evidence read fails AND no credential resolves, so `gh_auth_cause`
# is non-empty and the NOTE must carry it, while B2f2 pins the REFUSAL carrying the same cause.
grep -q 'read FAILED (no gh credential for the lane' "$TMP/b2f.log"; rc=$?   # B2f4
ck "B2f4 …and the NOTE interpolates the CAUSE it read, not just the verdict token (deleting the NOTE's gh_auth_cause call reddens exactly this)" $rc

# B2g: a BLANK-BUT-SET GH_TOKEN, with the account home HOLDING a store — the exact shape pre-fix printed
# `state=account at …`, exported an inert config dir, and then asserted "the lane's gh IS credentialed" over
# a lane whose every gh call fails (measured: gh resolves the whitespace INSTEAD of any store). The account
# home is REALly populated here on purpose: the arm's job is that the store is NOT claimed.
# ⛔ THE GREP MUST MATCH A STRING ONLY THE REFUSAL PRINTS. TWO producers emit these words, and only one of
# them is the refusal: `gh_auth_log`'s `token-blank)` arm builds `why="${d} is set but BLANK, …"` and prints
# it on the `[gh-auth] state=…` line, and `gh_auth_cause`'s `token-blank)` arm prints the same opening
# words — so a bare `grep -q 'GH_TOKEN is set but BLANK'` matched the LOG LINE and could not see a refusal
# that dropped the cause entirely. Measured: replacing the refusal's `%s` with a fixed phrase in
# `spawn-gate.sh` left the suite at 75/0 with no arm red. The `THIS IS NOT THE LANDING RATIO:` prefix
# exists only on the refusal, so the arm now measures the sentence the operator reads.
# ⛔ CITED BY SYMBOL, NOT BY LINE: the first cut of this comment cited `gh-auth.sh:302`/`:318`, and the
# header edit in the SAME commit shifted them to 304/320 before the comment was even committed (caught at
# review). A line number in a comment about claim-accuracy is itself a claim that rots; the arm names and
# the quoting above do not. B2g2/B2h2/B2i2 (token-blank) and B2f2 (none) carry the prefix.
run_lane 81 15 "P0-blocker,harness" "crash on boot" ok 2518 b2g "$ACCT" GH_TOKEN='   '
{ [ "$LANE_RC" -eq 74 ] && [ ! -s "$PI_LOG" ]; }; rc=$?
ck "B2g a blank-but-set GH_TOKEN is HELD (rc=$LANE_RC) even though the account home HAS a store, and no session ran" $rc
grep -q 'THIS IS NOT THE LANDING RATIO: GH_TOKEN is set but BLANK' "$TMP/b2g.log"; rc=$?
ck "B2g2 …and the refusal names the blank token as the credential cause" $rc
grep -q 'IS credentialed' "$TMP/b2g.log" && rc=1 || rc=0
ck "B2g3 …and never asserts the lane's gh IS credentialed (the false claim this arm exists to remove)" $rc
grep -q '\[gh-auth\] state=token-blank dir=- ' "$TMP/b2g.log"; rc=$?
ck "B2g4 …and the lane log says state=token-blank with NO dir=, so nothing reads as a store that was exported ('$(grep -o 'state=[^ ]* dir=[^ ]*' "$TMP/b2g.log" | head -1)')" $rc

# B2h: THE PRECEDENCE SHAPE, END TO END — a blank-but-SET GH_TOKEN beside a REAL GITHUB_TOKEN, with the
# account home holding a store. gh resolves GH_TOKEN's whitespace and the first API call is rejected (401),
# so the lane has no usable credential at all; asking the two names independently reported `token|`, and the
# refusal then asserted "the lane's gh IS credentialed (state=token)" over a lane whose every gh call fails.
# The store is REALly populated here for B2g's reason, and the neighbouring token is real for A7f's: the
# arm's job is that NEITHER the store NOR the usable-looking GITHUB_TOKEN is claimed.
run_lane 81 15 "P0-blocker,harness" "crash on boot" ok 2519 b2h "$ACCT" GH_TOKEN='   ' GITHUB_TOKEN=fixture-token
{ [ "$LANE_RC" -eq 74 ] && [ ! -s "$PI_LOG" ]; }; rc=$?
ck "B2h a blank-but-set GH_TOKEN beside a REAL GITHUB_TOKEN is HELD (rc=$LANE_RC), and no session ran" $rc
grep -q 'THIS IS NOT THE LANDING RATIO: GH_TOKEN is set but BLANK' "$TMP/b2h.log"; rc=$?
ck "B2h2 …and the refusal names GH_TOKEN as the cause, not the neighbouring token" $rc
grep -q 'IS credentialed' "$TMP/b2h.log" && rc=1 || rc=0
ck "B2h3 …and never asserts the lane's gh IS credentialed (the exact false claim this arm exists to remove)" $rc
grep -q '\[gh-auth\] state=token-blank dir=- ' "$TMP/b2h.log"; rc=$?
ck "B2h4 …and the lane log says state=token-blank with no dir= ('$(grep -o 'state=[^ ]* dir=[^ ]*' "$TMP/b2h.log" | head -1)')" $rc

# B2i: THE OTHER PLACE THE TOKEN BLOCK COULD SIT — a blank-but-SET GH_TOKEN with an AMBIENT `GH_CONFIG_DIR`
# that really holds a hosts.yml. `gh_auth_resolve` must still answer `token-blank`, because a token outranks a
# store in gh's order too; moving the token block after the `ambient` arm answers `ambient|<dir>` instead and
# `gh_auth_cause` goes silent, so the refusal prints "the lane's gh IS credentialed (state=ambient at …)" over
# a lane whose every call fails (measured: gh resolves the whitespace and never reads the store). That mutant
# kept this suite green before B2i; A7k pins the unit truth, this pins the sentence the operator reads.
run_lane 81 15 "P0-blocker,harness" "crash on boot" ok 2520 b2i "$ACCT" GH_CONFIG_DIR="$TMP/cfg-a" GH_TOKEN='   '
{ [ "$LANE_RC" -eq 74 ] && [ ! -s "$PI_LOG" ]; }; rc=$?
ck "B2i a blank GH_TOKEN over an AMBIENT store that holds hosts.yml is HELD (rc=$LANE_RC), and no session ran" $rc
grep -q 'THIS IS NOT THE LANDING RATIO: GH_TOKEN is set but BLANK' "$TMP/b2i.log"; rc=$?
ck "B2i2 …and the refusal names the blank token, not the store gh was pointed at" $rc
grep -q 'IS credentialed' "$TMP/b2i.log" && rc=1 || rc=0
ck "B2i3 …and never asserts the lane's gh IS credentialed (state=ambient would be that false claim)" $rc
grep -q '\[gh-auth\] state=token-blank dir=- ' "$TMP/b2i.log"; rc=$?
ck "B2i4 …and the lane log says state=token-blank with no dir= ('$(grep -o 'state=[^ ]* dir=[^ ]*' "$TMP/b2i.log" | head -1)')" $rc

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
# ⛔ TWO PRODUCERS PRINT THIS SENTENCE ON THIS PATH, so the bare words cannot tell them apart — the same
# class `B2f2`/`B2g2`/`B2h2`/`B2i2` were re-pointed for, left un-fixed here on the THIRD outcome. On B3c the
# EVIDENCE read fails too (`all-fail` mode), so `land_backlog_exempt_note` fires as well and its unresolved
# arm prints "this lane's gh credential could NOT be resolved either" — so the refusal's own clause could be
# deleted and the arm stayed green. MEASURED at `364c3042d` before this fix: rewording ONLY the refusal's
# clause (to "could not be READ either", printf arity kept) left the suite at `passed: 76 failed: 0`.
# Each producer now greps a string only IT emits: the refusal's own `⛔ BUT FIRST:` marker (the NOTE never
# prints it), and the NOTE's own "so the CAUSE MAY BE THE CREDENTIAL" (the refusal says "CREDENTIAL fault").
grep -q '⛔ BUT FIRST: this lane' "$TMP/b3c.log"; rc=$?
ck "B3c3 …the REFUSAL names the unresolved state and points at the lane's own gh, rather than guessing" $rc
grep -q 'Remedy: land/fix the open PRs.*⛔ BUT FIRST: this lane' "$TMP/b3c.log"; rc=$?
ck "B3c4 …and it still prints the RATIO remedy on that same line WITH the caveat — the documented third outcome, not the silence #2210 forbids" $rc
grep -q 'so the CAUSE MAY BE THE CREDENTIAL' "$TMP/b3c.log"; rc=$?
ck "B3c5 …while the NOTE's own unresolved arm says the cause MAY BE the credential (its words, not the refusal's)" $rc

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
ck "B6c …and says the P0 is HELD rather than judged non-urgent (the refusal's own clause, distinct from the NOTE line B6b pins)" $rc
grep -q 'EXEMPT .*P0 work' "$TMP/b6.log" && rc=1 || rc=0
ck "B6d …and nothing claims the exemption was granted" $rc

# B7: the same failed evidence read UNDER the ceiling — the lane runs (the ratio allows it), and the log
# STILL says the evidence read failed. ⛔ PRE-CHANGE SOMETHING *WAS* SAID, and saying otherwise is the
# false premise review round 12 caught: `origin/main` appended a bracketed clause to the VERDICT line —
# its two `land_backlog_verdict` call sites appended it to `lb_line` and echoed `[land-backlog] $lb_line`
# on both the OK and the REFUSED paths (CITED BY SYMBOL: the line numbers a prior draft carried were rotted
# by a rebase — review round 19) — so under the ceiling it read
# `[land-backlog] OK … [the <TAG> exemption read ALSO failed: …]`. The gain this suite pins is the
# DEDICATED line — greppable by its own token, printed whatever the verdict said, naming WHICH fault —
# not the invention of a trace that existed.
run_lane 3 40 "P0-blocker,harness" "crash on boot" evidence-fail 2516 b7 "$ACCT"
{ [ "$LANE_RC" -eq 0 ] && [ -s "$PI_LOG" ]; }; rc=$?
ck "B7 under the ceiling an unreadable exemption still starts the lane (rc=$LANE_RC) — it is measured, not held" $rc
grep -q 'EXEMPTION-UNREADABLE' "$TMP/b7.log"; rc=$?
ck "B7b …and the log still carries the failure, so 'OK' can no longer imply the issue was judged" $rc

# B8: THE SHAPE FINDING 1 NAMED, END TO END — `XDG_CONFIG_HOME` set with no store under it, and the store
# in the LANE home. `gh` reads `<XDG>/gh` and nothing else while XDG is set, so pre-fix the resolver answered
# `home` ("nothing to export"), the export never happened, the stub `gh` refused the way real gh does, and
# the refusal asserted "the lane's gh IS credentialed (state=home …)" — over a lane whose every call fails.
# Post-fix the store is exported under `home-xdg` and the P0 evidence READ. The account home is EMPTY here on
# purpose: the only credential in the fixture is the lane home's, so nothing else can rescue the arm.
run_lane 81 15 "P0-blocker,harness" "crash on boot" ok 2520 b8 "$ACCT_EMPTY" \
  HOME="$LANE_STORE" XDG_CONFIG_HOME="$XDG_EMPTY"
{ [ "$LANE_RC" -eq 0 ] && [ -s "$PI_LOG" ]; }; rc=$?
ck "B8 XDG set, store only in the LANE home ⇒ the credential RESOLVES and the lane RUNS (rc=$LANE_RC)" $rc
grep -q '\[gh-auth\] state=home-xdg' "$TMP/b8.log"; rc=$?
ck "B8b …the lane log says state=home-xdg, so it cannot read as gh's own default ('$(grep -o 'state=[^ ]*' "$TMP/b8.log" | head -1)')" $rc
grep -q 'EXEMPT .*P0 work' "$TMP/b8.log"; rc=$?
ck "B8c …and the P0 evidence was READ, not assumed" $rc
grep -q 'IS credentialed' "$TMP/b8.log" && rc=1 || rc=0
ck "B8d …and nothing claims a credential the module never provided" $rc

# ── B9: THE PLACEMENT COMMENT MUST NOT CLAIM COVERAGE THE TREE DOES NOT HAVE (review round 9, P3) ─────
# The block in `run_agent` that says WHY the credential is resolved there used to call this `run_agent`
# "the single invocation every worker goes through". The tree falsifies it: `merge-one.sh` carries its OWN
# `run_agent()` (#2208's declared residual) and its chain-reviewer spawn — the one whose record the merge
# gate reads — resolves NO credential at all (`grep -c gh_auth merge-one.sh` = 0). That is the same defect
# class as A12 and the B2f2 arm: a comment claiming a guard it does not have reads exactly like one that
# has it. It is worse than an ordinary stale comment because it sits on the block a lane reads to learn why
# the resolution is here AND a previous review round concluded "no claim here overreaches it", so a reader
# got two independent-sounding confirmations that the review path was covered.
# Each arm measures the TREE against the TEXT, so a red here means the two have diverged — in EITHER
# direction, which is the point: if `merge-one.sh` ever GAINS the resolution, B9b reddens until the comment
# stops calling it un-fixed. Pre-fix, B9c and B9d are RED (the block names no second implementation and
# carries the false universal claim), so the fix cannot buy its green by deleting the block.
_place="$(sed -n '/LANE.S gh CREDENTIAL (agent-infra#2509)/,/⛔ A MISSING MODULE/p' "$SG")"
[ -n "$_place" ]; rc=$?
ck "B9 the placement block is still extractable from the shipped spawn-gate.sh (a rename must redden this, never silently empty the arms below)" $rc
{ [ -n "$(sed -n '/^run_agent() {/p' "$HERE/merge-one.sh")" ] && [ "$(grep -c 'gh_auth' "$HERE/merge-one.sh")" -eq 0 ]; }; rc=$?
ck "B9b merge-one.sh carries its OWN run_agent() and resolves NO gh credential — the fact the block has to disclose" $rc
# ⛔ HERE-STRINGS, NOT PIPES (#841/#864). `run-bash-shards.sh:147` runs every shard under `set -uo
# pipefail`, and `grep -q` exits at the first match — so the `printf` on the left of a pipe can take an
# EPIPE and the PIPELINE's status becomes 141. On the two asserting arms that reads as a false FAIL of
# a true claim; on the three INVERTED arms below (`&& rc=1 || rc=0`) 141 falls into the `||` branch and
# the arm PASSES on text it was written to forbid — a false PASS in the direction that matters. A
# here-string has no reader to lose, so grep's 0/1 is the arm's status by construction.
grep -q 'merge-one\.sh' <<<"$_place"; rc=$?
ck "B9c …so the block NAMES merge-one.sh as a path this resolution does not reach" $rc
grep -q 'single invocation every worker goes through' <<<"$_place" && rc=1 || rc=0
ck "B9d …and no longer calls this run_agent the single invocation every worker goes through" $rc
# B9e-B9h: THE OTHER HALF OF THE SAME BOUNDARY (review round 10, P3). The block ALSO claimed the export was
# "INHERITED … by `wt_spawn`'s launch line", and the tree falsifies it in the STRONGEST direction: that
# launch line is composed in the CONTROLLER's process before `run_agent` exists, and its default arm
# ACTIVELY UNSETS both variables. Every B9 arm above stayed GREEN while that sentence was false — which is
# why the round that rewrote the sentence beside it did not catch this one. So the boundary gets its own
# arms: one on the TEXT, one on the FALSE clause's absence, one on the TREE fact the text rests on, and one
# on the second place the same overreach was written (`gh-auth.sh`'s export rationale).
# ⛔ THE BLOCK IS WRAPPED, SO LINE-ANCHORED GREPS CANNOT SEE A CLAUSE. Flatten it first (`#` markers
# stripped, newlines folded) — a per-line grep here would be an arm that cannot fail on the very sentence
# it is written to pin, which is the class A12 and B10d are on this suite's record for.
_place_flat="$(printf '%s\n' "$_place" | sed -e 's/^[[:space:]]*#[[:space:]]*//' | tr '\n' ' ' | tr -s ' ')"
grep -q 'DIFFERENT MECHANISM' <<<"$_place_flat"; rc=$?
ck "B9e …and NAMES wt_spawn's launch line as a DIFFERENT mechanism, not one this export can reach" $rc
grep -q 'INHERITED by the `pi` this function starts and by' <<<"$_place_flat" && rc=1 || rc=0
ck "B9f …and no longer claims the export is INHERITED by that launch line (the round-10 false clause)" $rc
# The tree fact the paragraph rests on, asserted in BOTH halves: nothing in spawn-gate.sh CALLS wt_spawn (so
# the export cannot travel up into a launch line), and `wt_launcher_env`'s default arm still CLEARS both
# variables (so a reader can verify the "different mechanism" claim without leaving the repo). If either
# changes, this reddens until the comment stops saying it.
{ [ -z "$(grep -nE '^[[:space:]]*wt_spawn[[:space:]]' "$SG")" ] \
  && grep -q '; unset GH_CONFIG_DIR XDG_CONFIG_HOME' "$HERE/worker-terminal.sh"; }; rc=$?
ck "B9g …because the tree agrees: spawn-gate.sh makes no wt_spawn CALL, and wt_launcher_env's default arm still CLEARS both variables" $rc
_gha_flat="$(sed -e 's/^[[:space:]]*#[[:space:]]*//' "$GH_AUTH" | tr '\n' ' ' | tr -s ' ')"
grep -q 'launch line reads `GH_CONFIG_DIR`' <<<"$_gha_flat" && rc=1 || rc=0
ck "B9h …and gh-auth.sh's own export rationale does not repeat the overreach (its chain is run_agent → pi, not wt_spawn)" $rc
# B12: WHERE THE `EXEMPTION-UNREADABLE` TOKEN ACTUALLY LANDS (review round 11, P3). `README.md` §7.2g said
# "the refusal line says `EXEMPTION-UNREADABLE`"; at this head the token is printed by the separate
# `[land-backlog] NOTE` line (three arms, one per credential outcome) and the REFUSAL prints a different
# sentence. A whole-file grep cannot tell the two producers apart — which is exactly what let the sentence
# stand — so pin each half where it is produced: the NOTE carries the token, and the refusal carries its
# own "HELD, not judged non-urgent" clause. Either half changing reddens this rather than silently
# re-blurring the two lines a reader is told to distinguish.
# ⛔ B12'S TITLE USED TO CLAIM BOTH DIRECTIONS WHILE MEASURING ONE (review round 12, P3): a count over
# the NOTE producers cannot see the refusal, so appending the token to the refusal's HELD clause left B12
# at 3 AND B12b green — the exact re-blurring this family exists to stop. Each half now has its own arm.
_notes="$(grep -c '\[land-backlog\] NOTE .*EXEMPTION-UNREADABLE' "$SG")"
[ "$_notes" -eq 3 ]; rc=$?
ck "B12 the EXEMPTION-UNREADABLE token is printed by the three NOTE arms ($_notes), one per credential outcome" $rc
grep -q 'is HELD, not judged non-urgent' "$SG"; rc=$?
ck "B12b …and the refusal says the exemption was HELD, not that the issue was judged non-urgent" $rc
# The OTHER direction, and it needs its own producer: the refusal must not start printing that token.
# Measured shape this prevents — add `EXEMPTION-UNREADABLE` to the refusal's HELD clause and B12 stays 3
# while B12b stays green, i.e. the two lines a reader is told to distinguish become one again.
_refuse_tok="$(sed -n '/^land_backlog_refuse()/,/^}/p' "$SG" | grep -c 'printf.*EXEMPTION-UNREADABLE')"
[ "${_refuse_tok:-0}" -eq 0 ]; rc=$?
ck "B12c …and the REFUSAL prints no EXEMPTION-UNREADABLE token of its own ($_refuse_tok), so the two producers stay separable" $rc
# B11: THE THIRD OUTCOME OF THE REFUSAL HAS AN ARM — the state where the lane's gh IS credentialed and the
# read failed for some other reason (`state=ambient` here). ⛔ MEASURED at 47ec2e2d7 before this arm: deleting
# that outcome's `printf` entirely (its words, arity kept) left the suite at `passed: 82 failed: 0` — five
# arms (`B2g3 B2h3 B2i3 B3c2 B8d`) pin only its ABSENCE, so the documented shape was asserted in one
# direction only, and `skills/cmux-cells/SKILL.md` calls it outcome "(a)" with a remedy of its own.
run_lane 81 15 "bug" "a normal issue" all-fail 2522 b11 "$ACCT" GH_CONFIG_DIR="$ACCT/.config/gh"
{ [ "$LANE_RC" -eq 74 ] && [ ! -s "$PI_LOG" ]; }; rc=$?
ck "B11 a credentialed lane whose read failed is HELD for the read, not the credential (rc=$LANE_RC)" $rc
# ⛔ `IS credentialed (state=ambient` IS NOT REFUSAL-UNIQUE: `land_backlog_exempt_note` prints the same
# words with `(state=%s)`. MEASURED under the mutant that deletes the refusal's outcome: B11 and B11b stayed
# GREEN and only B11c reddened, because the NOTE's line satisfied this grep. The refusal is the only producer
# that appends the DIR (`(state=%s%s)`, the second being ` at $d`), so that is what this arm now pins.
grep -q 'IS credentialed (state=ambient at ' "$TMP/b11.log"; rc=$?
ck "B11b …and the REFUSAL (not the NOTE) says the credential resolved with the dir it read, naming the state" $rc
grep -q 'check the gh/network chain' "$TMP/b11.log"; rc=$?
ck "B11c …and points the operator at the READ (the gh/network chain), which is the actual cause here" $rc
grep -q '⛔ BUT FIRST' "$TMP/b11.log" && rc=1 || rc=0
ck "B11d …and does NOT carry the credential caveat, which on this state would be the wrong cause" $rc

# B10: A DIRECTORY THIS READ CANNOT OPEN IS NOT AN EMPTY ONE. ⛔ `[ -f dir/hosts.yml ]` answers FALSE for
# both facts, so a store directory at `chmod 000` used to be reported as "holds no hosts.yml" — a
# directory the read had never opened. `_gh_auth_store_in` separates them and the cause discloses.
# ⛔ THESE ARMS RUN THROUGH `u()`, LIKE EVERY OTHER RESOLVER/CAUSE ARM (review round 14, P3): they used
# to run in the SUITE'S OWN shell, so an ambient `GH_CONFIG_DIR` or `GH_TOKEN` — which this fleet's cells
# really do export — reached them. Measured before the fix: `GH_CONFIG_DIR=<a store> bash gh-auth.test.sh`
# → 98/1 (B10c red), `GH_TOKEN=x bash gh-auth.test.sh` → 97/2 (B10c and B10e red) — a FALSE BLOCK on a
# correct tree — and B10d stayed green over an empty `CAN_NONE`, i.e. an arm that could not fail in that
# environment. Being hermetic is what lets the header's claim be true; the environment is the suite's own
# subject, so the suite of all things must not judge by it.
UNREAD="$TMP/unread"; mkdir -p "$UNREAD/.config/gh"; : > "$UNREAD/.config/gh/hosts.yml"; chmod 000 "$UNREAD/.config/gh"
u ". '$GH_AUTH' >/dev/null 2>&1; [ \"\$(_gh_auth_store_in '$UNREAD/.config/gh')\" = unreadable ]"; rc=$?
ck "B10 _gh_auth_store_in calls a store directory it cannot open UNREADABLE, not empty" $rc
u ". '$GH_AUTH' >/dev/null 2>&1; case \"\$(_gh_auth_store_in '$ACCT_EMPTY')\" in empty) exit 0 ;; *) exit 1 ;; esac"; rc=$?
ck "B10b …and a readable directory with no hosts.yml is still EMPTY (the discrimination is real, not blanket)" $rc
CAN_NONE="$(u ". '$GH_AUTH' >/dev/null 2>&1; gh_auth_cause '$UNREAD' '$TMP/none.env' '$ACCT_EMPTY'")"
case "$CAN_NONE" in *"<unreadable: $UNREAD/.config/gh>"*) rc=0 ;; *) rc=1 ;; esac
ck "B10c …and on the \`none\` outcome the cause prints <unreadable: …> for it rather than naming it as empty" $rc
# ⛔ THE PATTERN HERE SAID `holds no hosts.yml` AND THE `none` BRANCH SAYS `no hosts.yml` — MEASURED: the arm
# passed in BOTH states, mutant and baseline, i.e. it asserted nothing. It now greps the text that branch
# actually emits for that path, so removing the disclosure reddens it.
case "$CAN_NONE" in *"no hosts.yml under $UNREAD/.config/gh or"*) rc=1 ;; *) rc=0 ;; esac
ck "B10d …so it never names an unopenable dir as one it checked and found empty" $rc
chmod 755 "$UNREAD/.config/gh"
CAN_AMB="$(u ". '$GH_AUTH' >/dev/null 2>&1; chmod 000 '$UNREAD/.config/gh'; GH_CONFIG_DIR='$UNREAD/.config/gh' gh_auth_cause '$ACCT_EMPTY' '$TMP/none.env' '$ACCT_EMPTY'; chmod 755 '$UNREAD/.config/gh'")"
case "$CAN_AMB" in *"is set but this read could not OPEN it"*) rc=0 ;; *) rc=1 ;; esac
ck "B10e …and an unreadable ambient GH_CONFIG_DIR is refused as unopenable, not as 'holds no hosts.yml'" $rc
case "$CAN_AMB" in *"is set but holds no hosts.yml"*) rc=1 ;; *) rc=0 ;; esac
ck "B10f …which is the exact sentence that was false about a store that was right there" $rc

# ── B13: A STORE THAT EXISTS BUT CANNOT BE READ IS NOT A CREDENTIAL EITHER (review round 15, P2) ─────
# `[ -f dir/hosts.yml ]` answers TRUE for a store FILE this process cannot read, so a lane store whose
# `hosts.yml` is `chmod 000` (root-owned, or restored from a backup with its mode) was CLAIMED as a
# credential: resolve said `home`, `gh_auth_cause` stayed silent, and the refusal told the operator "the
# lane's gh IS credentialed … fix the READ", while the real `gh` on that store dies `failed to read
# configuration: … permission denied`. `_gh_auth_store_readable` now decides it for the helper AND for
# every store arm of the resolver, so the two cannot disagree.
# ⛔ THE CONSUMER SHAPE IS INJECTED, NOT RE-CREATED WITH `chmod`: uid 0 bypasses the permission bits, so a
# chmod-based consumer fixture would go GREEN on every root box (this fleet's cells run as root) — an arm
# that cannot fail there. But injection alone leaves the predicate's own `-r` half unpinned, so B13g/B13h
# DO build the real shape on a real file and SKIP LOUDLY when the uid makes that impossible (round 16).
STORE="$TMP/store-r"; mkdir -p "$STORE/.config/gh"; cp "$ACCT/.config/gh/hosts.yml" "$STORE/.config/gh/hosts.yml"
u ". '$GH_AUTH' >/dev/null 2>&1; _gh_auth_store_readable '$STORE/.config/gh/hosts.yml'"; rc=$?
ck "B13 _gh_auth_store_readable answers TRUE for a readable hosts.yml — the predicate's positive direction" $rc
u ". '$GH_AUTH' >/dev/null 2>&1; _gh_auth_store_readable '$TMP/absent/hosts.yml'" && rc=1 || rc=0
ck "B13b …and FALSE for an absent one, so it is a test and not a constant" $rc
# ⛔ THE READABILITY DIMENSION NEEDS A REAL-FILE ARM OF ITS OWN (review round 16, P2): the four arms
# below all move the predicate in the permissive direction, and B13/B13b are satisfied by `[ -f ]` alone —
# MEASURED: deleting `[ -r "$1" ]` from `_gh_auth_store_readable` left the suite at 105/0 while the
# round-5 defect came straight back on a real `chmod 000` lane store. So this arm builds the shape on the
# filesystem, not by injection.
# ⛔ uid 0 BYPASSES THE PERMISSION BITS (`access(R_OK)` succeeds for the superuser), so this shape CANNOT
# be constructed as root — the arm is then a declared RESERVATION, printed as a SKIP and never counted as a
# pass. It is not silently absent: the skip line names the reason, and the suite's count is printed with
# it. Every non-root box — CI's runners, and the lane that found this — measures the real discrimination.
FUNREAD="$TMP/store-unread"; mkdir -p "$FUNREAD/.config/gh"; cp "$ACCT/.config/gh/hosts.yml" "$FUNREAD/.config/gh/hosts.yml"
chmod 000 "$FUNREAD/.config/gh/hosts.yml"
# ⛔ ONE RESERVATION LINE PER SKIPPED ARM (review round 17, P3): the first cut incremented once and printed
# one line for TWO skipped assertions, so B13h vanished from the output entirely while the count said
# SKIPPED: 1 — a reservation that under-counts itself is a silent skip wearing a label.
if [ "$(id -u)" = 0 ]; then
  SKIPPED=$((SKIPPED+2))
  printf '  ⏭️  B13g SKIPPED (uid 0 bypasses permission bits, so an unreadable FILE cannot be built here) — this run leaves the -r half UNMEASURED\n'
  printf '  ⏭️  B13h SKIPPED (same reservation: the helper arm needs that same unreadable FILE) — UNMEASURED in this run\n'
else
  u ". '$GH_AUTH' >/dev/null 2>&1; _gh_auth_store_readable '$FUNREAD/.config/gh/hosts.yml'" && rc=1 || rc=0
  ck "B13g …and a REAL hosts.yml that exists but cannot be read is not one — the -r half, not just -f" $rc
  _ru="$(u ". '$GH_AUTH' >/dev/null 2>&1; _gh_auth_store_in '$FUNREAD/.config/gh'")"
  [ "$_ru" = unreadable ]; rc=$?
  ck "B13h …so the helper calls that real store unreadable, not ok ('$_ru')" $rc
fi
chmod 644 "$FUNREAD/.config/gh/hosts.yml"
_out="$(u ". '$GH_AUTH' >/dev/null 2>&1; _gh_auth_store_readable() { return 1; }; _gh_auth_store_in '$STORE/.config/gh'")"
[ "$_out" = unreadable ]; rc=$?
ck "B13c …with the predicate FALSE over a store that EXISTS, the helper answers unreadable, never 'ok' ('$_out')" $rc
_r="$(u ". '$GH_AUTH' >/dev/null 2>&1; _gh_auth_store_readable() { return 1; }; gh_auth_resolve '$STORE' '$TMP/none.env' '$ACCT_EMPTY'")"
[ "${_r%%|*}" = none ]; rc=$?
ck "B13d …and the RESOLVER does not claim it — the lane whose store it cannot read resolves 'none', not 'home' ('${_r%%|*}')" $rc
_c="$(u ". '$GH_AUTH' >/dev/null 2>&1; _gh_auth_store_readable() { return 1; }; gh_auth_cause '$STORE' '$TMP/none.env' '$ACCT_EMPTY'")"
case "$_c" in *"<unreadable: $STORE/.config/gh>"*) rc=0 ;; *) rc=1 ;; esac
ck "B13e …and the cause DISCLOSES it as unreadable rather than naming it empty" $rc
_r2="$(u ". '$GH_AUTH' >/dev/null 2>&1; _gh_auth_store_readable() { return 1; }; GH_CONFIG_DIR='$STORE/.config/gh' gh_auth_resolve '$LANE_HOME' '$TMP/none.env' '$ACCT_EMPTY'")"
[ "${_r2%%|*}" = ambient-missing ]; rc=$?
ck "B13f …and a set-but-unreadable ambient GH_CONFIG_DIR stays ambient-missing ('${_r2%%|*}'), which is the state whose cause names the fault" $rc

# ⛔ THE OTHER HALF OF THE PREDICATE (review round 17, P2): `-r` ALONE is not the test — a DIRECTORY named
# `hosts.yml` is readable, so a predicate that dropped `-f` would call it a store, the helper `ok`, the
# resolver `home`, the cause silent and the refusal "IS credentialed" over a path `gh` cannot read as
# config. This shape needs NO uid reservation (`mkdir` works at any uid), which is exactly why it is the
# cheap mirror of B13g/B13h.
# ⛔ THE ACCOUNT-HOME SEAM HAD NO ARM AT ALL (review round 18, P3): every arm passed an explicit account
# home, so (i) deleting `[ -z "$acct" ]` made the `none` cause print "/.config/gh" — a directory it never
# checked, which the POLARITY block says it never does — and (ii) a regression in the passwd parse would
# answer `none` for every cell lane with a cause naming a path that does not exist, and nothing reddened.
# ⛔ THE LOOKUP MUST NOT BE `$HOME` (a lane's HOME is REDIRECTED to the operational home — that is the
# whole reason this module exists), so the arm redirects HOME and requires a different, absolute answer.
_ah="$(u "HOME='$TMP/redirected-home'; . '$GH_AUTH' >/dev/null 2>&1; gh_auth_account_home")"
{ [ -n "$_ah" ] && [ "$_ah" != "$TMP/redirected-home" ]; } && case "$_ah" in /*) rc=0 ;; *) rc=1 ;; esac || rc=1
ck "B14 gh_auth_account_home answers the PASSWD home, not the redirected HOME ('$_ah')" $rc
# ⛔ THE OTHER TWO ARMS OF THE LOOKUP (review round 19, P3): B14 pins only the `getent` path, so deleting
# the `~user` fallback (or the `dscl` parse) left the suite green — a silent false BLOCK on a getent-less
# host, where the lane resolves `none` and is HELD. Both are exercised with a `getent` that FAILS, which
# is the shape that makes them reachable on any host.
mkdir -p "$TMP/bin-nogetent"
printf '#!/bin/sh\nexit 1\n' > "$TMP/bin-nogetent/getent"; chmod +x "$TMP/bin-nogetent/getent"
# ⛔ AND THE SAME CLIFF FOR `dscl`, OR THIS ARM IS HOST-DEPENDENT (review round 20, P3): on a macOS host a
# real `dscl` answers first, so deleting the `~user` block would leave the suite green — the "reachable on
# any host" claim in the comment above was false there. A FAILING `dscl` is written beside the failing
# `getent`; B15b then overwrites that same path with its own working stub.
printf '#!/bin/sh\nexit 1\n' > "$TMP/bin-nogetent/dscl"; chmod +x "$TMP/bin-nogetent/dscl"
_ahf="$(u "PATH='$TMP/bin-nogetent':\$PATH; HOME='$TMP/redirected-home'; . '$GH_AUTH' >/dev/null 2>&1; gh_auth_account_home")"
{ [ -n "$_ahf" ] && [ "$_ahf" != "$TMP/redirected-home" ]; } && case "$_ahf" in /*) rc=0 ;; *) rc=1 ;; esac || rc=1
ck "B15 …and with \`getent\` failing the \`~user\` fallback still answers a PASSWD home, not \$HOME ('$_ahf')" $rc
# ⛔ THE STUB IS BUILT WITH THE PATH BAKED IN (review round 19): the first cut passed a `%s` through the
# OUTER printf with no argument, so the stub on disk printed `NFSHomeDirectory: ` with no path at all — an
# arm that could not see its own mutant — and it also referenced `$TMP`, which is never exported to a child.
printf '#!/bin/sh\necho "NFSHomeDirectory: %s"\n' "$TMP/dscl-acct" > "$TMP/bin-nogetent/dscl"
chmod +x "$TMP/bin-nogetent/dscl"
_ahd="$(u "PATH='$TMP/bin-nogetent':\$PATH; HOME='$TMP/redirected-home'; . '$GH_AUTH' >/dev/null 2>&1; gh_auth_account_home")"
[ "$_ahd" = "$TMP/dscl-acct" ]; rc=$?
ck "B15b …and the \`dscl\` arm parses NFSHomeDirectory when that is the only source (got '$_ahd')" $rc
_uc="$(u ". '$GH_AUTH' >/dev/null 2>&1; gh_auth_account_home() { :; }; gh_auth_cause '$LANE_HOME' '$TMP/none.env' ''")"
case "$_uc" in *"<unresolved account home>/.config/gh"*) rc=0 ;; *) rc=1 ;; esac
ck "B14b …and when the lookup answers nothing the cause discloses <unresolved account home> instead of naming /.config/gh" $rc
case "$_uc" in *"or /.config/gh"*) rc=1 ;; *) rc=0 ;; esac
ck "B14c …which is the exact sentence a missing lookup check produced: it never claims to have checked /.config/gh" $rc
# ⛔ AND THE LANE-HOME HALF OF THE SAME DISCLOSURE (review round 24, P3): `gh_auth_resolve`'s home arm is
# guarded by `[ -n "$home" ]`, so an EMPTY lane home examined nothing there — yet this sentence named
# `/.config/gh` as if it had, and did so even over a store that was READABLE. Both shipped call sites pass
# `${HOME:-}`, so this is the shape a process with no HOME produces.
_uh="$(u ". '$GH_AUTH' >/dev/null 2>&1; gh_auth_account_home() { :; }; HOME=; gh_auth_cause '' '$TMP/none.env' ''")"
case "$_uh" in *"<unresolved lane home>/.config/gh"*) rc=0 ;; *) rc=1 ;; esac
ck "B14d …and an EMPTY lane home is disclosed as <unresolved lane home>, not rendered as /.config/gh" $rc
case "$_uh" in *"under /.config/gh"*) rc=1 ;; *) rc=0 ;; esac
ck "B14e …because that path was never examined by the resolver, so the cause must not name it as checked" $rc

DUNREAD="$TMP/store-dirfile"; mkdir -p "$DUNREAD/.config/gh/hosts.yml"
u ". '$GH_AUTH' >/dev/null 2>&1; _gh_auth_store_readable '$DUNREAD/.config/gh/hosts.yml'" && rc=1 || rc=0
ck "B13i …a DIRECTORY named hosts.yml is not a store either — the -f half, at any uid" $rc
_di="$(u ". '$GH_AUTH' >/dev/null 2>&1; _gh_auth_store_in '$DUNREAD/.config/gh'")"
[ "$_di" = unreadable ]; rc=$?
ck "B13j …and the helper calls that dirent UNREADABLE, not absent ('$_di')" $rc
# A DANGLING SYMLINK is the same class (a store symlinked into a volume that is not mounted): absent to
# `-e`, present to `ls -ld`, and reporting it as "no hosts.yml" sends the operator to create a store over
# a path that is already there.
SUNREAD="$TMP/store-symlink"; mkdir -p "$SUNREAD/.config/gh"; ln -sf /nonexistent-volume/hosts.yml "$SUNREAD/.config/gh/hosts.yml"
_si="$(u ". '$GH_AUTH' >/dev/null 2>&1; _gh_auth_store_in '$SUNREAD/.config/gh'")"
[ "$_si" = unreadable ]; rc=$?
ck "B13k …and a hosts.yml symlinked to something that is not mounted is UNREADABLE, not absent ('$_si')" $rc
_sc="$(u ". '$GH_AUTH' >/dev/null 2>&1; gh_auth_cause '$SUNREAD' '$TMP/none.env' '$ACCT_EMPTY'")"
case "$_sc" in *"<unreadable: $SUNREAD/.config/gh>"*) rc=0 ;; *) rc=1 ;; esac
ck "B13l …and the cause discloses it rather than saying 'no hosts.yml under' a path the operator can see" $rc
# ⛔ AND THE STORE DIRECTORY ITSELF CAN BE THE UNREACHABLE PART (review round 22, P2): when `$d` is a
# DANGLING SYMLINK — a store pointed at a volume that is not mounted — or is not a directory this read can
# SEARCH, every test on `$d/hosts.yml` is false and the helper used to answer `empty`, i.e. "absent", over
# a store that is there. Both shapes below are constructible at ANY uid (unlike a `chmod` shape), so these
# arms also run as root.
DLINK="$TMP/store-dangling"; mkdir -p "$DLINK/.config"; ln -sfn /nonexistent-volume/gh "$DLINK/.config/gh"
_dl="$(u ". '$GH_AUTH' >/dev/null 2>&1; _gh_auth_store_in '$DLINK/.config/gh'")"
[ "$_dl" = unreadable ]; rc=$?
ck "B13r …and a store DIRECTORY that is a dangling symlink is UNREADABLE, not empty ('$_dl')" $rc
_dc="$(u ". '$GH_AUTH' >/dev/null 2>&1; gh_auth_cause '$DLINK' '$TMP/none.env' '$ACCT_EMPTY'")"
case "$_dc" in *"<unreadable: $DLINK/.config/gh>"*) rc=0 ;; *) rc=1 ;; esac
ck "B13s …and the cause discloses it rather than telling the operator to create a store that exists" $rc
_FDIR="$TMP/store-as-file"; mkdir -p "$_FDIR/.config"; : > "$_FDIR/.config/gh"
_ff="$(u ". '$GH_AUTH' >/dev/null 2>&1; _gh_auth_store_in '$_FDIR/.config/gh'")"
[ "$_ff" = unreadable ]; rc=$?
ck "B13t …and a store path that is a regular FILE is UNREADABLE, not empty ('$_ff')" $rc

# ⛔ READABILITY IS PINNED ON **EVERY** STORE ARM, NOT JUST `home` AND `ambient` (review round 17, P2):
# flipping the predicate back to `[ -f ]` in the `keys` arm ALONE left the suite green, and on a
# `keys.env`-declared store whose `hosts.yml` cannot be read the resolver then answered `keys|…` with a
# SILENT cause while `_gh_auth_store_in` on the same directory answered `unreadable` — the two disagreeing
# is exactly what `_gh_auth_store_readable` exists to prevent. The positive direction of each of these
# four arms is already pinned by the A-arms (A5/A6/A8/A10), so each arm below only has to prove the arm
# is NOT claimed when the store cannot be read.
# ⛔ THE `keys` FIXTURE MUST LAND WHERE THAT ARM PROBES (measured, review round 18): the arm tests
# `$v/hosts.yml` where `$v` IS the env file's `GH_CONFIG_DIR` value — so the store file sits DIRECTLY in
# that directory, not under `.config/gh`. The first cut wrote it one level too deep, so the arm answered
# "not keys" because there was no store at all, and the mutant that reverts the arm stayed GREEN.
KSTORE="$TMP/store-keys"; mkdir -p "$KSTORE"; cp "$ACCT/.config/gh/hosts.yml" "$KSTORE/hosts.yml"
printf 'GH_CONFIG_DIR=%s\n' "$KSTORE" > "$TMP/keys-store.env"
XSTORE="$TMP/store-xdg"; mkdir -p "$XSTORE/gh"; cp "$ACCT/.config/gh/hosts.yml" "$XSTORE/gh/hosts.yml"
printf 'XDG_CONFIG_HOME=%s\n' "$XSTORE" > "$TMP/keys-xdg.env"
ASTORE="$TMP/acct-store"; mkdir -p "$ASTORE/.config/gh"; cp "$ACCT/.config/gh/hosts.yml" "$ASTORE/.config/gh/hosts.yml"
_c1="$(u ". '$GH_AUTH' >/dev/null 2>&1; gh_auth_resolve '$LANE_HOME' '$TMP/keys-store.env' '$ACCT_EMPTY'")"
_c2="$(u ". '$GH_AUTH' >/dev/null 2>&1; gh_auth_resolve '$LANE_HOME' '$TMP/keys-xdg.env' '$ACCT_EMPTY'")"
_c3="$(u ". '$GH_AUTH' >/dev/null 2>&1; XDG_CONFIG_HOME='$XSTORE' gh_auth_resolve '$LANE_HOME' '$TMP/none.env' '$ACCT_EMPTY'")"
_c4="$(u ". '$GH_AUTH' >/dev/null 2>&1; gh_auth_resolve '$LANE_HOME' '$TMP/none.env' '$ASTORE'")"
_ctrl=0
[ "${_c1%%|*}" = keys ] || _ctrl=1
[ "${_c2%%|*}" = keys-xdg ] || _ctrl=1
[ "${_c3%%|*}" = xdg ] || _ctrl=1
[ "${_c4%%|*}" = account ] || _ctrl=1
ck "B13q …CONTROL: with the predicate intact each of those fixtures IS the store its arm claims (keys/keys-xdg/xdg/account) — so the four arms above fail for the RIGHT reason" $_ctrl
_k="$(u ". '$GH_AUTH' >/dev/null 2>&1; _gh_auth_store_readable() { return 1; }; gh_auth_resolve '$LANE_HOME' '$TMP/keys-store.env' '$ACCT_EMPTY'")"
[ "${_k%%|*}" != keys ]; rc=$?
ck "B13m …the env-file \`keys\` arm is not claimed for an unreadable store (got '${_k%%|*}')" $rc
_kx="$(u ". '$GH_AUTH' >/dev/null 2>&1; _gh_auth_store_readable() { return 1; }; gh_auth_resolve '$LANE_HOME' '$TMP/keys-xdg.env' '$ACCT_EMPTY'")"
[ "${_kx%%|*}" != keys-xdg ]; rc=$?
ck "B13n …nor the \`keys-xdg\` arm (got '${_kx%%|*}')" $rc
_xd="$(u ". '$GH_AUTH' >/dev/null 2>&1; _gh_auth_store_readable() { return 1; }; XDG_CONFIG_HOME='$XSTORE' gh_auth_resolve '$LANE_HOME' '$TMP/none.env' '$ACCT_EMPTY'")"
[ "${_xd%%|*}" != xdg ]; rc=$?
ck "B13o …nor the ambient \`xdg\` arm (got '${_xd%%|*}')" $rc
_ac="$(u ". '$GH_AUTH' >/dev/null 2>&1; _gh_auth_store_readable() { return 1; }; gh_auth_resolve '$LANE_HOME' '$TMP/none.env' '$ASTORE'")"
[ "${_ac%%|*}" = none ]; rc=$?
ck "B13p …nor the \`account\` arm: with no readable store anywhere the lane resolves 'none' (got '${_ac%%|*}')" $rc

echo
echo "───────────────────────────────────────"
echo "  passed: $PASS   failed: $FAIL$([ "$SKIPPED" -gt 0 ] && printf '   SKIPPED: %s (uid 0 — see the ⏭️ line)' "$SKIPPED")"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
