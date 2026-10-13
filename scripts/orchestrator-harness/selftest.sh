#!/usr/bin/env bash
# selftest.sh — offline checks for the shipped harness. No network, no tmux server, no git writes.
#
# IMPORTANT — how these checks are written.
# Several defects found in review were "the logic looks fixed but nothing calls it". So a check that
# RE-IMPLEMENTS the fixed logic proves nothing: it passes on the broken copy too. Every check below
# therefore EXTRACTS the real code from the shipped script (the classifier, sess(), esc(), the
# claim block, the reaper) or runs the real script, and asserts on its behaviour. Verified the hard
# way: dropping this file into the pre-fix tree fails these checks.
#
#   ./selftest.sh
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pass=0; fail=0
ck() { # ck <name> <0|1>
  if [ "$2" -eq 0 ]; then printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1));
  else printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); fi
}
LOOP="$HERE/orch-loop.sh"; MERGE="$HERE/merge-one.sh"; INST="$HERE/install.sh"; REFRESH="$HERE/refresh-candidates.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
# A missing extraction must FAIL, not warn: if the shipped script lacks the code under test the
# dependent checks would pass on an empty file — the exact vacuity this file was rewritten to fix.
need() { if [ -s "$1" ]; then return 0; else ck "$2" 1; return 1; fi; }
# OFFLINE: install.sh probes the REAL `gh` (`gh auth status`) and dies without a live authenticated
# session, so the install/render checks below would need network. A `gh` stub that reports success
# is FIRST on PATH for that reason — the header's "no network" contract is then true. Checks that
# need the real resolution build their own PATH explicitly (§17 daemon-PATH, §6c) and are unaffected.
GSTUB="$TMP/stub-bin"; mkdir -p "$GSTUB"
printf '#!/bin/bash\n[ -n "${GH_HOME_RECORD:-}" ] && printf "%%s\\n" "$HOME" >> "$GH_HOME_RECORD"\nexit 0\n' > "$GSTUB/gh"; chmod +x "$GSTUB/gh"
PATH="$GSTUB:$PATH"; export PATH
echo "==> offline self-test ($HERE)"

# ── 1) every script parses ───────────────────────────────────────────────────────
rc=0
for f in "$HERE"/*.sh "$HERE"/retired/*.sh; do
  [ "$(basename "$f")" = "selftest.sh" ] && continue
  bash -n "$f" || { echo "      syntax error: $f"; rc=1; }
done
ck "all shell scripts parse (bash -n)" $rc

# ── 2) the shipped sess() matches session names exactly ──────────────────────────
# Extracted from orch-loop.sh and driven against a fake `tmux`, so this pins the real function.
# `tmux has-session -t fix-82` prefix-matches `fix-820`, which starved PRs whose number prefixes
# a running worker's session name.
# sess() is a one-liner, so extract the single line (a range to /^}/ would swallow the whole loop).
grep -m1 '^sess() {' "$LOOP" > "$TMP/sess.sh"
if need "$TMP/sess.sh" "sess() is extracted from the shipped orch-loop.sh"; then
  tmux() { printf 'fix-820\nmerge-821\nlane-5\n'; }
  # shellcheck disable=SC1090
  . "$TMP/sess.sh"
  sess "fix-82"  && rc=1 || rc=0; ck "shipped sess(): fix-82 does NOT match fix-820" $rc
  sess "fix-820" && rc=0 || rc=1; ck "shipped sess(): fix-820 matches its own name" $rc
  sess "fix-8200" && rc=1 || rc=0; ck "shipped sess(): fix-8200 does NOT match fix-820" $rc
  unset -f tmux
fi

# ── 3) the shipped classifier is fail-closed on ai-review-gate ───────────────────
# Extracted from orch-loop.sh verbatim; only the bash-side $REQ is substituted.
REQ="ai-review-gate python-ci-gate docs test-isolation license-surface legal-e2e pricing-artifact"
awk '/^import sys,json$/,/^" 2>\/dev\/null\)\)$/' "$LOOP" | sed 's/^" 2>\/dev\/null))$//' \
  | sed "s/'\\\$REQ'/'$REQ'/" | sed -n '1,/^print(/p' > "$TMP/classify.py"
cl() { printf '%s' "$1" | python3 "$TMP/classify.py" 2>/dev/null; }
if need "$TMP/classify.py" "the classifier is extracted from the shipped orch-loop.sh"; then
got="$(cl '[{"name":"ai-review-gate","state":"SKIPPED"},{"name":"docs","state":"SKIPPED"}]')"
[ "$got" = "FAILED:ai-review-gate" ] && rc=0 || { rc=1; echo "      got '$got'"; }
ck "shipped classifier: ai-review-gate SKIPPED is not satisfied" $rc
got="$(cl '[{"name":"ai-review-gate","state":"NEUTRAL"}]')"
[ "$got" = "FAILED:ai-review-gate" ] && rc=0 || { rc=1; echo "      got '$got'"; }
ck "shipped classifier: ai-review-gate NEUTRAL is not satisfied" $rc
got="$(cl '[{"name":"docs","state":"SUCCESS"}]')"
[ "$got" = "FAILED:ai-review-gate" ] && rc=0 || { rc=1; echo "      got '$got'"; }
ck "shipped classifier: a missing ai-review-gate row is not satisfied" $rc
got="$(cl '[{"name":"ai-review-gate","state":"SUCCESS"},{"name":"python-ci-gate","state":"SUCCESS"},{"name":"docs","state":"SKIPPED"},{"name":"test-isolation","state":"SUCCESS"},{"name":"license-surface","state":"SUCCESS"},{"name":"legal-e2e","state":"NEUTRAL"},{"name":"pricing-artifact","state":"SUCCESS"}]')"
[ "$got" = "GREEN" ] && rc=0 || { rc=1; echo "      got '$got'"; }
ck "shipped classifier: gate SUCCESS + path-filtered legs skipped = GREEN" $rc
got="$(cl '[{"name":"ai-review-gate","state":"FAILURE"}]')"
[ "$got" = "FAILED:ai-review-gate" ] && rc=0 || { rc=1; echo "      got '$got'"; }
ck "shipped classifier: gate FAILURE is reported failed" $rc
fi

# ── 4) the shipped claim block refuses a second owner ────────────────────────────
# Extracted from merge-one.sh and executed, so this pins the real lock, not a copy of the idiom.
sed -n '/^CLAIM="\$O\/state\/mergeclaim-\$PR.lock"/,/^trap .rm -f "\$CLAIM".*$/p' "$MERGE" > "$TMP/claim.sh"
mkdir -p "$TMP/O/state"
if need "$TMP/claim.sh" "the claim block is extracted from the shipped merge-one.sh"; then
# The claim block logs to "$L.log", so assert on the log, not on stdout.
# (a) a claim held by a LIVE pid must be refused
printf '%s' "$$" > "$TMP/O/state/mergeclaim-900.lock"
out="$( O="$TMP/O" PR=900 L="$TMP/claimtest" bash -c "set -u; . '$TMP/claim.sh'; echo ALIVE" 2>&1 )"
if grep -q 'already owns this PR' "$TMP/claimtest.log" 2>/dev/null; then rc=0; else rc=1; echo "      log: $(cat "$TMP/claimtest.log" 2>/dev/null)"; fi
ck "shipped claim block: a live owner is refused" $rc
case "$out" in *ALIVE*) rc=1;; *) rc=0;; esac
ck "shipped claim block: the refused worker does not proceed" $rc
# (b) a claim held by a DEAD pid must be reclaimed
printf '%s' "999999" > "$TMP/O/state/mergeclaim-901.lock"
out="$( O="$TMP/O" PR=901 L="$TMP/claimtest2" bash -c "set -u; . '$TMP/claim.sh'; echo ALIVE" 2>&1 )"
case "$out" in *ALIVE*) rc=0 ;; *) rc=1; echo "      got '$out'";; esac
ck "shipped claim block: a dead owner's claim is reclaimed" $rc
fi

# ── 5) the shipped reaper un-blacklists only undelivered dispatches ──────────────
# Extracted from refresh-candidates.sh and run against fixtures:
#   4114 = open, no PR, no lane        -> must be REAPED
#   8888 = open, PR exists             -> must be KEPT
#   9999 = not open                    -> must be KEPT
#   7777 = a live lane-7777 session    -> must be KEPT
R="$TMP/reap"; mkdir -p "$R"
printf '4114\n8888\n9999\n7777\n' > "$R/dispatched.txt"
printf '4114\n8888\n9999\n' > "$R/checked.txt"
printf '4114\n8888\n' > "$R/.open_iss"
printf 'feat/8888-tm\n' > "$R/.pr_brs"
tmux() { printf 'lane-7777\nmerge-100\n'; }
# extract the embedded reaper (the heredoc body only)
awk '/^python3 - "\$O" <<.PY.$/{f=1;next} /^PY$/{f=0} f' "$REFRESH" > "$R/reap.py"
if need "$R/reap.py" "the reaper is extracted from the shipped refresh-candidates.sh"; then
# the extracted body shells out to tmux; export the fake so the child sees it
cat > "$R/tmux" <<'SH'
#!/bin/bash
printf 'lane-7777\nmerge-100\n'
SH
chmod +x "$R/tmux"
( PATH="$R:$PATH" python3 "$R/reap.py" "$R" ) > "$TMP/reap.out" 2>&1
kept="$(tr '\n' ' ' < "$R/dispatched.txt")"
case "$kept" in *4114*) rc=1;; *) rc=0;; esac
ck "shipped reaper: open+no-PR+no-lane dispatch is un-blacklisted" $rc
case "$kept" in *8888*) rc=0;; *) rc=1;; esac
ck "shipped reaper: an issue with a PR is kept" $rc
case "$kept" in *9999*) rc=0;; *) rc=1;; esac
ck "shipped reaper: a closed issue is kept" $rc
case "$kept" in *7777*) rc=0;; *) rc=1;; esac
ck "shipped reaper: an issue with a live lane is kept" $rc
case "$(tr '\n' ' ' < "$R/checked.txt")" in *4114*) rc=1;; *) rc=0;; esac
ck "shipped reaper: the reaped entry is removed from checked.txt" $rc
fi
unset -f tmux

# ── 5b) the shipped refresh loop never blacklists a candidate it did not pre-flight ─
# `echo "$N" >> checked.txt` sat BEFORE `n=$((n+1)); [ "$n" -gt "$LIMIT" ] && break`, so the
# (LIMIT+1)-th candidate was recorded as checked and then the loop broke without ever running
# collision_preflight.py for it. checked.txt suppresses that issue forever and the §7.1 reaper
# only un-blacklists dispatched.txt entries — so one dispatchable issue was lost per refresh.
awk '/^n=0$/{f=1} f{print} /^done < /{f=0}' "$REFRESH" > "$TMP/refreshloop.sh"
if need "$TMP/refreshloop.sh" "the refresh loop body is extracted from the shipped refresh-candidates.sh"; then
  RL="$TMP/refresh"; mkdir -p "$RL/fakesc/.venv/bin"
  printf '10\n20\n30\n40\n50\n' > "$RL/.pool"
  : > "$RL/checked.txt"; : > "$RL/candidates.txt"; : > "$RL/dispatched.txt"
  cat > "$RL/fakesc/.venv/bin/python" <<'PY'
#!/bin/bash
# stand-in for the scout's venv python: every candidate pre-flights CLEAN
echo "VERDICT: CLEAN"
PY
  chmod +x "$RL/fakesc/.venv/bin/python"
  O="$RL" LIMIT=3 SC="$RL/fakesc" bash "$TMP/refreshloop.sh" > "$TMP/refreshloop.out" 2>&1
  checked="$(tr '\n' ' ' < "$RL/checked.txt")"
  case "$checked" in *40*) rc=1;; *) rc=0;; esac
  ck "shipped refresh loop: the candidate past LIMIT is NOT marked checked" $rc
  case "$checked" in *10*20*30*) rc=0;; *) rc=1;; esac
  ck "shipped refresh loop: the first LIMIT candidates are marked checked" $rc
  cands="$(tr '\n' ' ' < "$RL/candidates.txt")"
  case "$cands" in *10*20*30*) rc=0;; *) rc=1;; esac
  ck "shipped refresh loop: the pre-flighted CLEAN candidates reach the backlog" $rc
fi

# ── 6) install.sh renders correctly, including values sed/XML would mangle ────────
# Runs the real installer with a hostile-but-LEGAL $O. "Legal" matters: install.sh now applies
# orch-loop.sh's own $O guard, so a quote or shell metacharacter (`&`, `'`, space, …) is refused
# at install time — which is the point, since such a value would crash-loop the daemon under
# KeepAlive. What remains reachable, and is tested here, is XML metacharacter escaping (`<`, `>`,
# a bare one of which makes the plist invalid XML and launchd silently refuses to load it) plus the
# round-trip decode below. (Historical: an unescaped `&` in the sed REPLACEMENT expanded to the
# matched text, rendering `O=/tmp/a&b` as /tmp/a__O__b — a VALID plist pointing at the wrong paths,
# which plutil -lint cannot catch. That path is now unreachable by construction and the guard is
# asserted in 16d.)
SB="$TMP/sb"; mkdir -p "$SB/Library/LaunchAgents" "$SB/.config" "$SB/.pi/agent/scripts"
ln -s "$HOME/.config/gh" "$SB/.config/gh" 2>/dev/null || true
[ -f "$HOME/.pi/agent/scripts/record-review.sh" ] && ln -s "$HOME/.pi/agent/scripts/record-review.sh" "$SB/.pi/agent/scripts/record-review.sh"
# install.sh prefers the version-independent pi-node symlink under $HOME, and the daemon probe now
# EXECUTES pi — so a sandbox HOME must expose a runnable pi, exactly as a real install's HOME does.
mkdir -p "$SB/.local/share/pi-node/current/bin"
printf '#!/bin/bash\nexit 0\n' > "$SB/.local/share/pi-node/current/bin/pi"; chmod +x "$SB/.local/share/pi-node/current/bin/pi"
HOSTILE="$TMP/x<y>z"
HOME="$SB" O="$HOSTILE" REPO="$HERE/../.." OR="acme/widget" bash "$INST" >"$TMP/inst.out" 2>&1
PL="$SB/Library/LaunchAgents/com.eldato.orchestrator-loop.plist"
[ -f "$PL" ] && rc=0 || { rc=1; echo "      install.sh did not render a plist: $(tail -3 "$TMP/inst.out")"; }
ck "install.sh renders a plist" $rc
if [ -f "$PL" ]; then
  grep -q '__[A-Z_]*__' "$PL" && rc=1 || rc=0
  ck "no unsubstituted placeholder survives rendering" $rc
  # The value must appear XML-escaped (a bare < or > is illegal XML); correctness is then proven
  # by the round-trip check below, which decodes it back and compares.
  grep -qF 'x&lt;y&gt;z' "$PL" && rc=0 || { rc=1; echo "      expected XML-escaped '<' '>' in the plist"; }
  ck "a '<'/'>' in a path is XML-escaped in the plist" $rc
  plutil -lint "$PL" >/dev/null 2>&1 && rc=0 || rc=1
  ck "the rendered plist is valid XML" $rc
  # Round-trip: XML-escaping must decode back to the original path, not merely be well-formed.
  decoded="$(plutil -extract EnvironmentVariables.O raw "$PL" 2>/dev/null || echo MISSING)"
  [ "$decoded" = "$HOSTILE" ] && rc=0 || { rc=1; echo "      decoded '$decoded' != '$HOSTILE'"; }
  ck "the hostile path round-trips through the plist unchanged" $rc
fi

# ── 6b) install.sh on a fresh checkout: dir-only gitignore, .worktrees not created yet ─
# install.sh is the FIRST step on a fresh box (README §4) and dispatch-merge.sh creates the
# worktree lazily — but `git check-ignore -q .worktrees` returns non-zero when the path does not
# exist and the repo ignores it with the directory-only pattern `.worktrees/`. The installer then
# died before rendering the plist. Reproduced in a throwaway git repo whose parent is not a repo.
FR="$TMP/freshrepo"; mkdir -p "$FR/repo"
git -C "$FR/repo" init -q >/dev/null 2>&1
printf '.worktrees/\n' > "$FR/repo/.gitignore"
# Non-vacuous: this exact repo really does defeat the pre-fix bare-path form.
( cd "$FR/repo" && git check-ignore -q .worktrees ) && rc=1 || rc=0
ck "non-vacuity: the pre-fix bare .worktrees guard fails on a fresh checkout" $rc
grep -q 'check-ignore -q .worktrees/' "$INST" && rc=0 || rc=1
ck "install.sh's gitignore guard uses the directory form .worktrees/" $rc
SB2="$TMP/sb2"; mkdir -p "$SB2/Library/LaunchAgents" "$SB2/.config" "$SB2/.pi/agent/scripts"
ln -s "$HOME/.config/gh" "$SB2/.config/gh" 2>/dev/null || true
mkdir -p "$SB2/.local/share/pi-node/current/bin"
printf '#!/bin/bash\nexit 0\n' > "$SB2/.local/share/pi-node/current/bin/pi"; chmod +x "$SB2/.local/share/pi-node/current/bin/pi"
HOME="$SB2" O="$TMP/fresh-o" REPO="$FR/repo" OR="acme/widget" bash "$INST" > "$TMP/inst-fresh.out" 2>&1
PL2="$SB2/Library/LaunchAgents/com.eldato.orchestrator-loop.plist"
[ -f "$PL2" ] && rc=0 || { rc=1; echo "      fresh checkout: $(tail -2 "$TMP/inst-fresh.out")"; }
ck "install.sh renders a plist on a fresh checkout (no .worktrees dir yet)" $rc

# ── 6c) the self-test resolves REPO to the checkout, not its parent ─────────────
# It passed `$HERE/../../..` (the PARENT of the repo root) to install.sh, which died
# "not a git checkout" on any fresh clone whose parent is not a git repo — the exact second box
# this harness exists to hand over. `$HERE/../..` is the root (check #13 already uses it).
grep -qE 'REPO="\$HERE/\.\./\.\./\.\."' "$HERE/selftest.sh" && rc=1 || rc=0
ck "selftest.sh does not point install.sh at the repo's parent" $rc
grep -qF 'REPO="$HERE/../.."' "$HERE/selftest.sh" && rc=0 || rc=1
ck "selftest.sh passes the repo root to install.sh" $rc
[ -e "$HERE/../../.git" ] && rc=0 || rc=1
ck "the repo-root path selftest.sh uses resolves to a git working tree" $rc

# ── 6d) the rendered plist PATH IS the resolved daemon PATH (the integration seam) ─────────────
# §17/§18 drive the extracted PATH-builder and probe, but nothing pinned that install.sh actually
# RENDERS $DAEMON_PATH into the plist. Review mutation (H) restored the pre-fix hardcoded base at the
# __PATH__ substitution and left the whole suite green — yet the rendered PATH is the fixed artifact.
# Render in a sandbox with a CONTROLLED PATH whose tools live in one fixture dir: the rendered PATH
# must contain it (so the check is red under the hardcoded base) and no shim/.pi segment. `uv` is
# deliberately absent, which also exercises the documented non-fatal-uv path end to end.
FB="$TMP/pathbin"; mkdir -p "$FB" "$TMP/sb3/Library/LaunchAgents" "$TMP/sb3/.config" "$TMP/sb3/.pi/agent/scripts"
for b in tmux gh pi; do printf '#!/bin/bash\nexit 0\n' > "$FB/$b"; chmod +x "$FB/$b"; done
ln -s "$HOME/.config/gh" "$TMP/sb3/.config/gh" 2>/dev/null || true
HOME="$TMP/sb3" O="$TMP/path-o" REPO="$HERE/../.." OR="acme/widget" PATH="$FB:/usr/bin:/bin" bash "$INST" > "$TMP/inst-path.out" 2>&1
PL3="$TMP/sb3/Library/LaunchAgents/com.eldato.orchestrator-loop.plist"
[ -f "$PL3" ] && rc=0 || { rc=1; echo "      controlled-PATH install did not render: $(tail -3 "$TMP/inst-path.out")"; }
ck "install.sh renders with a controlled PATH (uv absent stays non-fatal)" $rc
PLP="$(plutil -extract EnvironmentVariables.PATH raw "$PL3" 2>/dev/null || echo MISSING)"
case ":$PLP:" in *":$FB:"*) rc=0;; *) rc=1; echo "      rendered PATH=$PLP lacks the resolved tool dir $FB";; esac
ck "the rendered plist PATH is resolved, not the pre-fix hardcoded base" $rc
case ":$PLP:" in *"/shims"*|*"/.pi/"*) rc=1;; *) rc=0;; esac
ck "the rendered plist PATH contains no */shims or */.pi/* segment" $rc

# ── 6e) install.sh CREATES the plist directory ─────────────────────────────────
# Every sandbox above pre-creates $HOME/Library/LaunchAgents, so `mkdir -p "$(dirname "$PLIST")"`
# was pinned by NOTHING: deleting it left the suite fully green, while on the real path — a fresh
# HOME has no such directory — the render died with a raw redirect error after $O's state dirs were
# already created (the pre-fix half-install). Assert the directory is absent first (non-vacuity),
# then that install succeeds and the plist exists.
SB4="$TMP/sb4"; mkdir -p "$SB4/.config" "$SB4/.pi/agent/scripts"
ln -s "$HOME/.config/gh" "$SB4/.config/gh" 2>/dev/null || true
[ -f "$HOME/.pi/agent/scripts/record-review.sh" ] && ln -s "$HOME/.pi/agent/scripts/record-review.sh" "$SB4/.pi/agent/scripts/record-review.sh"
mkdir -p "$SB4/.local/share/pi-node/current/bin"
printf '#!/bin/bash\nexit 0\n' > "$SB4/.local/share/pi-node/current/bin/pi"; chmod +x "$SB4/.local/share/pi-node/current/bin/pi"
[ -e "$SB4/Library/LaunchAgents" ] && rc=1 || rc=0
ck "non-vacuity: the fresh sandbox HOME has no Library/LaunchAgents" $rc
HOME="$SB4" O="$TMP/plistdir-o" REPO="$HERE/../.." OR="acme/widget" bash "$INST" >"$TMP/inst-plistdir.out" 2>&1
inst_rc=$?
[ "$inst_rc" -eq 0 ] && [ -f "$SB4/Library/LaunchAgents/com.eldato.orchestrator-loop.plist" ] && rc=0 \
  || { rc=1; echo "      install.sh rc=$inst_rc did not create the plist dir: $(tail -3 "$TMP/inst-plistdir.out")"; }
ck "install.sh creates the plist directory on a HOME that lacks it" $rc

# ── 7) in-script defaults agree with install.sh's defaults ───────────────────────
# A limit documented in README §4 and rendered by install.sh must not be silently different in
# orch-loop.sh — MAX_REVIEW was 2 in the loop and 4 everywhere else.
rc=0
for v in MAX_LOAD MAX_LANES MAX_REVIEW MERGE_PRIORITY_AT MAX_FIX MAX_FIX_TRIES MIN_SWAP_FREE BATCH CYC; do
  a="$(grep -oE "^$v=\"\\\$\{$v:-[0-9]+\}\"" "$LOOP" | grep -oE '[0-9]+' | head -1)"
  b="$(grep -oE "^$v=\"\\\$\{$v:-[0-9]+\}\"" "$INST" | grep -oE '[0-9]+' | head -1)"
  [ -n "$a" ] && [ "$a" = "$b" ] || { echo "      $v: orch-loop=${a:-?} install=${b:-?}"; rc=1; }
done
ck "orch-loop.sh defaults match install.sh for all 9 limits" $rc

# ── 8) the dispatch gate consults load and names the binding gate ────────────────
# MAX_LOAD was rendered into the plist and documented, but never compared to anything.
grep -qE '\[ "\$L" -ge "\$MAX_LOAD" \]' "$LOOP" && rc=0 || rc=1
ck "dispatch gate compares load against MAX_LOAD" $rc
grep -q 'GATE_WHY=' "$LOOP" && rc=0 || rc=1
ck "dispatch skip message names the binding gate" $rc
grep -q 'merge-priority' "$LOOP" && rc=0 || rc=1
ck "the loop implements merge-priority above the backlog threshold" $rc
grep -q '= "CONFLICTING"' "$LOOP" && rc=0 || rc=1
ck "a CONFLICTING PR is routed to the fixer, not retried as a merge" $rc
grep -q 'CONFLICTING -> fixer attempt' "$LOOP" && rc=0 || rc=1
ck "the conflict fixer is logged and capped like other fix loops" $rc
grep -q 'resolving the conflict IS the task' "$HERE/fix-one.sh" && rc=0 || rc=1
ck "the fixer prompt treats a conflict as the task" $rc
# Drive the shipped rule rather than grepping for a comment: a regression that dropped the
# 'lanes >= 1' exception or the headroom arithmetic must fail here.
sed -n '/^mp_reason() {/,/^}/p;/^review_slots() {/,/^}/p' "$LOOP" > "$TMP/mp.sh"
if need "$TMP/mp.sh" "mp_reason()/review_slots() are extracted from the shipped loop"; then
  MERGE_PRIORITY_AT=10; MAX_REVIEW=4
  # shellcheck disable=SC1090
  . "$TMP/mp.sh"
  [ -n "$(mp_reason 11 1)" ] && rc=0 || rc=1
  ck "shipped mp_reason(): 11 open PRs with a lane running -> drain" $rc
  [ -z "$(mp_reason 11 0)" ] && rc=0 || rc=1
  ck "shipped mp_reason(): 11 open PRs with NO lane -> dispatch still allowed" $rc
  [ -z "$(mp_reason 10 3)" ] && rc=0 || rc=1
  ck "shipped mp_reason(): at the threshold, no drain override" $rc
  [ "$(review_slots 11)" = "6" ] && rc=0 || rc=1
  ck "shipped review_slots(): backlog raises reviewer headroom to MAX_REVIEW+2" $rc
  [ "$(review_slots 10)" = "4" ] && rc=0 || rc=1
  ck "shipped review_slots(): below the threshold, headroom is MAX_REVIEW" $rc
fi
grep -qE 'case "\$\{PR_ST:-\}" in MERGED\|CLOSED\)' "$LOOP" && rc=0 || rc=1
ck "sweep skips CLOSED as well as MERGED" $rc

# ── 9) crash-safety bookkeeping ──────────────────────────────────────────────────
grep -q 'if tmux new-session -d -s "fix-\$PR"' "$LOOP" && rc=0 || rc=1
ck "fixer spawn is attempted before the attempt is recorded" $rc
grep -q 'PARKED after' "$LOOP" && rc=0 || rc=1
ck "reaching MAX_FIX_TRIES parks the PR instead of re-reviewing forever" $rc
grep -q 'claim_live "\$PR"' "$LOOP" && rc=0 || rc=1
ck "controller honours the claim written by the chain path" $rc

# ── 10) template / renderer placeholder parity ───────────────────────────────────
tpl="$(grep -oE '__[A-Z_]+__' "$HERE/launchd.plist.template" | sort -u)"
sedlist="$(sed -n '/^sed \\/,/launchd.plist.template/p' "$INST" | grep -oE '__[A-Z_]+__' | sed 's/^__//; s/__$//' | sed 's/^/__/; s/$/__/' | sort -u)"
[ -n "$tpl" ] && [ "$tpl" = "$sedlist" ] && rc=0 || rc=1
ck "every template placeholder is substituted by install.sh" $rc

# ── 11) no credential material shipped ───────────────────────────────────────────
rc=0
if grep -rqE 'github_pat_[A-Za-z0-9_]{20,}|ghp_[A-Za-z0-9]{20,}|sk-[A-Za-z0-9]{20,}|BEGIN [A-Z ]*PRIVATE KEY' "$HERE" 2>/dev/null; then rc=1; fi
ck "no credential-shaped strings in the shipped tree" $rc

# ── 12) README does not claim more than the code does ────────────────────────────
# Guards the three overclaims found in review. Match the overclaim PHRASINGS, not the words —
# §9 legitimately needs to say "not byte-identical" and §7.4 legitimately quotes the old claim.
grep -q 'so behaviour is byte-identical' "$HERE/README.md" && rc=1 || rc=0
ck "README does not claim the shipped copy is byte-identical" $rc
grep -qE 'selftest.sh. now pins every|pins every fixed defect' "$HERE/README.md" && rc=1 || rc=0
ck "README does not claim the self-test pins every defect" $rc
grep -q 'One owner per PR, per box' "$HERE/README.md" && rc=0 || rc=1
ck "README scopes the claim invariant to one box" $rc
grep -q 'serialises one box only' "$HERE/README.md" && rc=0 || rc=1
ck "README states the cross-box limitation explicitly" $rc
# The README must not state a self-test check COUNT — it drifts the moment a check is added
# (it said 29 while the file had 42, then 46/46 while the file ran 57). The guard matches the
# PHRASINGS that actually drifted and is proved non-vacuous against a fixture of pre-fix text.
OVERC='[0-9]+ checks|[0-9]+ of its checks|measured [0-9]+/[0-9]+|[0-9]+/[0-9]+ shipped'
grep -qE "$OVERC" "$HERE/README.md" && rc=1 || rc=0
ck "README states no self-test check count that can drift" $rc
cat > "$TMP/overclaim.md" <<'MD'
review of this very file, and 19 of its checks fail when it is dropped into the
| measured 7/30 on the pre-fix tree vs 46/46 shipped |
MD
grep -qE "$OVERC" "$TMP/overclaim.md" && rc=0 || rc=1
ck "the drift guard matches the pre-fix phrasings (non-vacuous)" $rc
# The REQUIRED-check count is the page's own invariant, not a drifting number: it is fixed by the
# repo's protection. It must equal REQ and the README must never spell a different count beside
# the list it ships (it said "eight"/"8" against a live set of 7).
nreq="$(sed -n 's/^REQ="\(.*\)"$/\1/p' "$LOOP" | tr ' ' '\n' | grep -c .)"
case "$nreq" in 7) rword=seven;; 8) rword=eight;; *) rword="" ;; esac
[ -n "$rword" ] && grep -qE "($nreq|$rword) required check" "$HERE/README.md" && rc=0 || rc=1
ck "README states the required-check count REQ has ($nreq)" $rc
numerals='([0-9]+|one|two|three|four|five|six|seven|eight|nine|ten) required check'
bad=""
while read -r tok _; do
  [ -z "$tok" ] && continue
  case "$tok" in "$nreq"|"$rword") ;; *) bad="$tok";; esac
done < <(grep -oE "$numerals" "$HERE/README.md")
[ -z "$bad" ] && rc=0 || { rc=1; echo "      README claims '$bad required check'"; }
ck "README never disagrees with REQ on the required-check count" $rc
bad=""
while read -r tok _; do
  [ -z "$tok" ] && continue
  case "$tok" in "$nreq"|"$rword") ;; *) bad="$tok";; esac
done < <(printf 'read the 8 required checks\nand the eight required check names\n' | grep -oE "$numerals")
[ -n "$bad" ] && rc=0 || rc=1
ck "non-vacuity: the required-count guard flags the pre-fix '8'/'eight' (saw '$bad')" $rc
grep -q 'selftest.sh' "$HERE/README.md" && rc=0 || rc=1
ck "README points at the self-test" $rc

# ── 13) a hostile branch name cannot reach a shell ───────────────────────────────
# git PERMITS ' ; $ ` & | ( ) { } " < > # in a ref name — only spaces are forbidden, and ${IFS}
# supplies those. The controller embedded headRefName inside a tmux `sh -c` string, so a fork PR on
# branch `fix/x';touch${IFS}/tmp/VULN;#` got arbitrary command execution on the host that holds the
# merge key. This was reproduced end-to-end before the fix.
sed -n '/^safe_ref() {/,/^}/p' "$LOOP" > "$TMP/saferef.sh"
if need "$TMP/saferef.sh" "safe_ref() is extracted from the shipped orch-loop.sh"; then
  REPO="$HERE/../.."
  # shellcheck disable=SC1090
  . "$TMP/saferef.sh"
  HOSTILE="fix/x';touch\${IFS}/tmp/VULN;#"
  safe_ref "$HOSTILE" && rc=1 || rc=0
  ck "shipped safe_ref() rejects a hostile branch name" $rc
  safe_ref "fix/8246-orchestrator-harness-handover" && rc=0 || rc=1
  ck "shipped safe_ref() accepts a normal branch name" $rc
  safe_ref "feat/1234-tm" && rc=0 || rc=1
  ck "shipped safe_ref() accepts a generated branch name" $rc
fi
is_num() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
grep -q '^is_num() {' "$LOOP" && rc=0 || rc=1
ck "the shipped loop defines is_num() for PR ids" $rc
grep -q -- "--argv" "$LOOP" && rc=0 || rc=1
ck "worker launches pass args via --argv, not string interpolation" $rc
grep -qE "'\\\$OR' \\\$PR '\\\$BR'" "$LOOP" && rc=1 || rc=0
ck "no \$OR/\$PR/\$BR interpolation remains in the spawn commands" $rc
# The retired tree ships next to the live scripts and is executable, so an unsafe interpolation
# there is a re-armable P0 for anyone who reuses it. It must be annotated as such.
grep -q 'RETIRED: unsafe interpolation' "$HERE/retired/auto-loop.sh" && rc=0 || rc=1
ck "the retired copy's unsafe interpolation is annotated in place" $rc
grep -q 'Prefer the live scripts' "$HERE/retired/auto-loop.sh" && rc=0 || rc=1
ck "the retired copy's banner warns against reuse" $rc

# ── 14) the controller does not treat a stale claim as in-flight ────────────────
sed -n '/^claim_live() {/,/^}/p' "$LOOP" > "$TMP/claimlive.sh"
if need "$TMP/claimlive.sh" "claim_live() is extracted from the shipped orch-loop.sh"; then
  mkdir -p "$TMP/CL/state"
  O="$TMP/CL"
  # shellcheck disable=SC1090
  . "$TMP/claimlive.sh"
  printf '%s' "$$" > "$O/state/mergeclaim-1.lock"
  claim_live 1 && rc=0 || rc=1
  ck "shipped claim_live(): a live owner counts as in flight" $rc
  printf '%s' "999999" > "$O/state/mergeclaim-2.lock"
  claim_live 2 && rc=1 || rc=0
  ck "shipped claim_live(): a dead owner is not in flight" $rc
  [ -f "$O/state/mergeclaim-2.lock" ] && rc=1 || rc=0
  ck "shipped claim_live(): the stale claim file is removed" $rc
fi

grep -qE "'docs\|test-isolation\|license-surface\|legal-e2e\|pricing-artifact'" "$LOOP" && rc=0 || rc=1
ck "a non-review required check failure is routed to the fixer" $rc
grep -q 'CI-red (.*fixer attempt' "$LOOP" && rc=0 || rc=1
ck "the CI-red fixer is logged and capped like other fix loops" $rc
grep -q 'FAILING_CHECKS=' "$HERE/fix-one.sh" && rc=0 || rc=1
ck "the fixer is given the failing check" $rc
grep -q 'failing.txt' "$HERE/fix-one.sh" && rc=0 || rc=1
ck "the fixer is given the failing CI log" $rc
# ── 15) a hung worker cannot hold a concurrency slot forever ────────────────────
# `pi -p` has no internal timeout. A hung reviewer occupied a merge slot for 9 hours on
# 2026-10-12 while the caps (which count SESSIONS) reported the slot as busy.
grep -q '^  reap_stale_workers$' "$LOOP" && rc=0 || rc=1
ck "the reaper runs every cycle" $rc
sed -n '/^reap_stale_workers() {/,/^}/p' "$LOOP" > "$TMP/reapw.sh"
if need "$TMP/reapw.sh" "reap_stale_workers() is extracted from the shipped loop"; then
  mkdir -p "$TMP/RW/logs"
  : > "$TMP/RW/logs/merge-999.log"; touch -t 202601010000 "$TMP/RW/logs/merge-999.log"
  : > "$TMP/RW/fresh.log"
  KILLED=0
  tmux() { case "${1:-}" in ls) printf 'merge-999\n' ;; list-panes) echo 4242 ;; kill-session) KILLED=1 ;; esac; }
  kill() { :; }
  LOG="$TMP/RW/rw.log"; O="$TMP/RW"; STALE_MIN=1
  # shellcheck disable=SC1090
  . "$TMP/reapw.sh"
  reap_stale_workers
  [ "$KILLED" = "1" ] && rc=0 || rc=1
  ck "shipped reaper kills a session whose log has gone stale" $rc
  grep -q 'reap-worker' "$LOG" && rc=0 || rc=1
  ck "the reaper logs what it killed" $rc
  # Exact-match targets: a prefix match would let the reaper kill a DIFFERENT, healthy session
  # if the stale one exited between the snapshot and the kill.
  grep -q 'kill-session -t "=\$s"' "$LOOP" && rc=0 || rc=1
  ck "the reaper uses exact session targets (=name), not prefix matches" $rc
  grep -q 'list-panes -t "=\$s"' "$LOOP" && rc=0 || rc=1
  ck "the reaper resolves the pane pid with an exact target" $rc
  unset -f tmux kill
fi
# the agent invocation is wall-clock bounded, portably (macOS has no timeout/gtimeout)
sed -n '/^run_agent() {/,/^}/p' "$MERGE" > "$TMP/runagent.sh"
if need "$TMP/runagent.sh" "run_agent() is extracted from the shipped merge-one.sh"; then
  # NOTE: the heredoc must EXPAND $TMP (unquoted) while leaving the runtime substitutions for the
  # script itself. A quoted heredoc left the source path literal, so run_agent never got defined and
  # the check passed on "command not found" — the exact vacuity this file exists to prevent.
  cat > "$TMP/ra.sh" <<SH
pi() { sleep 60; }
. "$TMP/runagent.sh"
start=\$(date +%s); run_agent 2 "$TMP/ra.log" /dev/null; rc=\$?; end=\$(date +%s)
echo "\$((end-start)) \$rc"
SH
  ra="$(bash "$TMP/ra.sh" 2>/dev/null | tail -1)"
  set -- $ra
  # must have actually run (a real abort, non-zero rc), and been cut off well before the 60s sleep
  ran=0; grep -q 'wall_limit=' "$TMP/ra.log" 2>/dev/null && ran=1
  if [ "$ran" = "1" ] && [ "${1:-0}" -ge 1 ] && [ "${1:-99}" -lt 30 ] && [ "${2:-0}" -ne 0 ]; then rc=0; else rc=1; fi
  ck "shipped run_agent() kills a hung agent at the wall limit (elapsed=${1:-?}s rc=${2:-?} ran=$ran)" $rc
fi

# ── 16) a FAILED open-PR count is never read as zero ─────────────────────────────
# The pre-fix line was OPEN_N="$(gh pr list … 2>/dev/null)"; : "${OPEN_N:=0}" — rc and stderr
# were discarded and the empty result was coerced to 0, so one transient `TLS handshake timeout`
# turned a 25-open-PR queue into `open=0 -> OWN`, dropping the BROAD drain, the reviewer headroom
# and the merge-priority gate at once. Drive the SHIPPED function (extracted, not re-implemented)
# with a stubbed gh, and pin the failure path, the sticky fallback and the success write.
unset -f gh pi uv tmux 2>/dev/null || true   # an exported function would shadow the gh stub below
sed -n '/^open_pr_count() {/,/^}/p' "$LOOP" > "$TMP/opencount.sh"
if need "$TMP/opencount.sh" "open_pr_count() is extracted from the shipped orch-loop.sh"; then
  OC="$TMP/opencount"; mkdir -p "$OC/state"
  { echo 'set -u'; grep -m1 '^is_num() {' "$LOOP"; cat "$TMP/opencount.sh"; echo 'open_pr_count'; } > "$OC/drive.sh"
  # Driver must be non-vacuous: it parses and really defines the shipped function.
  bash -n "$OC/drive.sh" && rc=0 || rc=1
  ck "the open-PR-count driver parses" $rc
  # (a) gh FAILS: TLS handshake timeout on stderr, empty stdout, rc 1
  cat > "$OC/gh" <<'SH'
#!/bin/bash
echo 'Post "https://api.github.com/graphql": net/http: TLS handshake timeout' >&2
exit 1
SH
  chmod +x "$OC/gh"; rm -f "$OC/state/last-open-n"; LOG="$OC/log"; : > "$LOG"
  n="$( PATH="$OC:$PATH" O="$OC" OR="acme/widget" LOG="$LOG" bash "$OC/drive.sh" )"
  [ "$n" != "0" ] && [ -n "$n" ] && rc=0 || { rc=1; echo "      failed gh produced '$n'"; }
  ck "a failed open-PR count is NOT zero (got '$n')" $rc
  [ "$n" = "11" ] && rc=0 || { rc=1; echo "      got '$n'"; }
  ck "a first-ever failure assumes 11 (BROAD, resumes the drain)" $rc
  grep -q 'open=UNKNOWN rc=1' "$LOG" && rc=0 || { rc=1; echo "      log: $(cat "$LOG")"; }
  ck "a failed open-PR count logs an UNKNOWN diagnostic naming the rc" $rc
  grep -q 'TLS handshake timeout' "$LOG" && rc=0 || { rc=1; echo "      log: $(cat "$LOG")"; }
  ck "the diagnostic keeps gh's stderr instead of discarding it" $rc
  # (b) sticky: a later failure reuses the last good count, never resets to 0
  printf '25\n' > "$OC/state/last-open-n"; : > "$LOG"
  n="$( PATH="$OC:$PATH" O="$OC" OR="acme/widget" LOG="$LOG" bash "$OC/drive.sh" )"
  [ "$n" = "25" ] && rc=0 || { rc=1; echo "      sticky produced '$n'"; }
  ck "a later failure reuses the sticky last-known count (25)" $rc
  # (b2) a sticky 0 must NOT be reused: a DRAINED queue is the dangerous case (PRs arrive, then one
  # transient failure) and 0 drives OWN / no headroom / no merge-priority — the exact pre-fix bug.
  printf '0\n' > "$OC/state/last-open-n"; : > "$LOG"
  n="$( PATH="$OC:$PATH" O="$OC" OR="acme/widget" LOG="$LOG" bash "$OC/drive.sh" )"
  [ "$n" != "0" ] && [ -n "$n" ] && rc=0 || { rc=1; echo "      sticky-0 produced '$n'"; }
  ck "a sticky last-known of 0 is not reused (got '$n')" $rc
  [ "$n" = "11" ] && rc=0 || { rc=1; echo "      got '$n'"; }
  ck "a sticky 0 falls back to 11 (BROAD)" $rc
  # (b3) the fallback must clear the SCOPE threshold too, not just the merge-priority tunable:
  # max(MERGE_PRIORITY_AT, 10) + 1. Keying it to the tunable alone left a below-default tunable in
  # OWN — the unsafe direction — on a failed count.
  _mp="$( PATH="$OC:$PATH" O="$OC" OR="acme/widget" LOG="$LOG" MERGE_PRIORITY_AT=4 bash "$OC/drive.sh" )"
  [ "$_mp" = "11" ] && rc=0 || { rc=1; echo "      MERGE_PRIORITY_AT=4 produced '$_mp' (expected 11)"; }
  ck "a below-default MERGE_PRIORITY_AT (4) falls back to 11, above the scope threshold" $rc
  _mp="$( PATH="$OC:$PATH" O="$OC" OR="acme/widget" LOG="$LOG" MERGE_PRIORITY_AT=15 bash "$OC/drive.sh" )"
  [ "$_mp" = "16" ] && rc=0 || { rc=1; echo "      MERGE_PRIORITY_AT=15 produced '$_mp' (expected 16)"; }
  ck "an above-default MERGE_PRIORITY_AT (15) falls back to 16, above the tunable" $rc
  # (b4) a leading-zero tunable must be read as DECIMAL: `[ … -ge 10 ]` parses base 10 but `$(( … ))`
  # parses base 0, in which `010` is octal 8 — so the guard ratified "ten" and the arithmetic
  # returned 9, landing in OWN, the same unsafe direction the tunable-keyed fallback was fixed for.
  _mp="$( PATH="$OC:$PATH" O="$OC" OR="acme/widget" LOG="$LOG" MERGE_PRIORITY_AT=010 bash "$OC/drive.sh" )"
  [ "$_mp" = "11" ] && rc=0 || { rc=1; echo "      MERGE_PRIORITY_AT=010 produced '$_mp' (expected 11)"; }
  ck "a leading-zero MERGE_PRIORITY_AT (010) is decimal 10, falls back to 11" $rc
  _mp="$( PATH="$OC:$PATH" O="$OC" OR="acme/widget" LOG="$LOG" MERGE_PRIORITY_AT=notanum bash "$OC/drive.sh" )"
  [ "$_mp" = "11" ] && rc=0 || { rc=1; echo "      MERGE_PRIORITY_AT=notanum produced '$_mp' (expected 11)"; }
  ck "a non-numeric MERGE_PRIORITY_AT falls back to 11 without aborting" $rc
  # (c) SUCCESS: the count is returned and persisted for the next failure
  cat > "$OC/gh" <<'SH'
#!/bin/bash
printf '25\n'
SH
  chmod +x "$OC/gh"; rm -f "$OC/state/last-open-n"; : > "$LOG"
  n="$( PATH="$OC:$PATH" O="$OC" OR="acme/widget" LOG="$LOG" bash "$OC/drive.sh" )"
  [ "$n" = "25" ] && rc=0 || { rc=1; echo "      success produced '$n'"; }
  ck "a successful open-PR count returns the count" $rc
  [ "$(cat "$OC/state/last-open-n" 2>/dev/null)" = "25" ] && rc=0 || rc=1
  ck "a successful open-PR count is persisted to last-open-n" $rc
  # (c2) a GENUINE 0 (drained queue) must still be returned as 0 and persisted: the `-gt 0` guard
  # lives ONLY in the failure branch. Coercing a real 0 to 11 would make BROAD permanent and the
  # queue would never be treated as drained.
  cat > "$OC/gh" <<'SH'
#!/bin/bash
printf '0\n'
SH
  chmod +x "$OC/gh"; rm -f "$OC/state/last-open-n"; : > "$LOG"
  n="$( PATH="$OC:$PATH" O="$OC" OR="acme/widget" LOG="$LOG" bash "$OC/drive.sh" )"
  [ "$n" = "0" ] && rc=0 || { rc=1; echo "      success-0 produced '$n'"; }
  ck "a genuine 0 (drained queue) is still returned as 0" $rc
  [ "$(cat "$OC/state/last-open-n" 2>/dev/null)" = "0" ] && rc=0 || rc=1
  ck "a genuine 0 is persisted to last-open-n" $rc
fi
# The SEAM, not just the logic: a perfect open_pr_count() is dead code if the loop stops calling it.
# Review mutation (G) restored the pre-fix inline line at the call site — `OPEN_N="$(gh pr list …)";
# : "${OPEN_N:=0}"` — and left the extracted-function checks green because nothing pinned the wiring.
grep -qF 'OPEN_N="$(open_pr_count)"' "$LOOP" && rc=0 || { rc=1; echo "      the loop does not assign OPEN_N from open_pr_count()"; }
ck "the loop actually calls open_pr_count() (not the pre-fix inline gh count)" $rc
# The sweep listing must be captured and rc-checked too: piped straight into `while read` with
# 2>/dev/null, a failed listing is ZERO iterations and no output — a sweep that silently does
# nothing for the whole cycle. These pin the fix's shape; (a) above pins its behavioural sibling.
grep -q 'SWEEP_RC' "$LOOP" && rc=0 || rc=1
ck "the sweep listing captures its rc instead of discarding it" $rc
grep -q 'PR listing FAILED' "$LOOP" && rc=0 || rc=1
ck "a failed sweep listing is logged, not silently empty" $rc
# …and the sweep loop must be fed the CAPTURED listing: a shape that logs the failure but still
# pipes gh directly would sweep an empty list around the captured variable.
grep -qF '${SWEEP_LIST:-}" |' "$LOOP" && rc=0 || rc=1
ck "the sweep loop is fed the captured listing, not gh directly" $rc

# ── 16b) the SCOPE override pins the drain scope, and a bad value fails loudly ───
# Extracted VERBATIM from the shipped orch-loop.sh (the BEGIN/END scope-select markers), driven in
# a subshell with SCOPE/OPEN_N/LOG set. A check that re-implemented the case statement would pass
# on a build with no override at all — the exact vacuity this file exists to prevent.
awk '/^  # BEGIN scope-select/,/^  # END scope-select/' "$LOOP" > "$TMP/scope.sh"
if need "$TMP/scope.sh" "the scope-select block is extracted from the shipped orch-loop.sh"; then
  S_OWN='select(.headRefName|test("-tm$|-cap$|^fix/"))'
  S_BROAD='select(.headRefName|test("^design/|^scope/|^dependabot/")|not)'
  drive_scope() { # <SCOPE> <OPEN_N> -> "<MODE>|<SEL>"; log $TMP/scope.log; err $TMP/scope.err
    : > "$TMP/scope.log"; : > "$TMP/scope.err"
    ( set -u; SCOPE="$1" OPEN_N="$2" LOG="$TMP/scope.log"; . "$TMP/scope.sh"; printf '%s|%s\n' "$SCOPE_MODE" "$SEL" ) 2>"$TMP/scope.err"
  }
  # auto (the default) must preserve the pre-override count rule exactly.
  out="$(drive_scope auto 14)"
  [ "$out" = "BROAD|$S_BROAD" ] && grepp=true || grepp=false
  grep -qF '[scope] open=14 -> BROAD (auto)' "$TMP/scope.log" && grepl=true || grepl=false
  [ "$grepp" = true ] && [ "$grepl" = true ] && rc=0 || { rc=1; echo "      auto/14 got '$out' log=$(cat "$TMP/scope.log")"; }
  ck "shipped scope: auto + 14 open -> BROAD, unchanged" $rc
  # SCOPE UNSET (the real default path — every test above sets SCOPE explicitly) must drive `auto`.
  # Without this, a mutation of the default itself (e.g. ${SCOPE+x} -> ${SCOPE:-own}) stays green.
  drive_scope_unset() { # <OPEN_N> -> "<MODE>|<SEL>" with SCOPE genuinely unset
    : > "$TMP/scope.log"; : > "$TMP/scope.err"
    ( set -u; unset SCOPE; OPEN_N="$1" LOG="$TMP/scope.log"; . "$TMP/scope.sh"; printf '%s|%s\n' "$SCOPE_MODE" "$SEL" ) 2>"$TMP/scope.err"
  }
  out="$(drive_scope_unset 14)"
  grep -qF '[scope] open=14 -> BROAD (auto)' "$TMP/scope.log" && grepl=true || grepl=false
  [ "$out" = "BROAD|$S_BROAD" ] && [ "$grepl" = true ] && rc=0 || { rc=1; echo "      unset/14 got '$out' log=$(cat "$TMP/scope.log")"; }
  ck "shipped scope: SCOPE unset drives the auto default (>10 -> BROAD)" $rc
  out="$(drive_scope_unset 10)"
  # The log line is asserted too: at OPEN_N=10 `auto` and a mutated `own` DEFAULT are
  # indistinguishable from MODE alone, so an unset-default mutation would stay green here.
  grep -qF '[scope] open=10 -> OWN (auto)' "$TMP/scope.log" && grepl=true || grepl=false
  [ "$out" = "OWN|$S_OWN" ] && [ "$grepl" = true ] && rc=0 || { rc=1; echo "      unset/10 got '$out' log=$(cat "$TMP/scope.log")"; }
  ck "shipped scope: SCOPE unset drives the auto default (at the threshold -> OWN)" $rc
  out="$(drive_scope auto 10)"
  [ "$out" = "OWN|$S_OWN" ] && grepp=true || grepp=false
  grep -qF '[scope] open=10 -> OWN (auto)' "$TMP/scope.log" && grepl=true || grepl=false
  [ "$grepp" = true ] && [ "$grepl" = true ] && rc=0 || { rc=1; echo "      auto/10 got '$out' log=$(cat "$TMP/scope.log")"; }
  ck "shipped scope: auto + 10 open (at the threshold) -> OWN, unchanged" $rc
  # own/broad must pin, in BOTH directions across the threshold.
  out="$(drive_scope own 14)"
  [ "$out" = "OWN|$S_OWN" ] && grep -qF '[scope] open=14 -> OWN (pinned SCOPE=own)' "$TMP/scope.log" && rc=0 \
    || { rc=1; echo "      own/14 got '$out' log=$(cat "$TMP/scope.log")"; }
  ck "shipped scope: SCOPE=own pins OWN even above the threshold" $rc
  out="$(drive_scope broad 3)"
  [ "$out" = "BROAD|$S_BROAD" ] && grep -qF '[scope] open=3 -> BROAD (pinned SCOPE=broad)' "$TMP/scope.log" && rc=0 \
    || { rc=1; echo "      broad/3 got '$out' log=$(cat "$TMP/scope.log")"; }
  ck "shipped scope: SCOPE=broad pins BROAD even below the threshold" $rc
  # A typo is FATAL operator config — it must not silently pick a scope.
  drive_scope banana 14 >/dev/null; rc=$?
  [ "$rc" -ne 0 ] && rc=0 || { rc=1; echo "      SCOPE=banana exited 0"; }
  ck "shipped scope: an unknown SCOPE value fails (does not pick a scope)" $rc
  grep -qF 'SCOPE must be auto|own|broad' "$TMP/scope.err" && rc=0 || { rc=1; echo "      stderr: $(cat "$TMP/scope.err")"; }
  ck "shipped scope: the unknown-value failure names the accepted values" $rc
  # Set-but-EMPTY is an operator typo (a blank plist/keys.env entry), not a silent default.
  drive_scope '' 14 >/dev/null; rc=$?
  [ "$rc" -ne 0 ] && rc=0 || { rc=1; echo "      SCOPE= (empty) exited 0 — silently picked a scope"; }
  ck "shipped scope: SCOPE set-but-empty fails instead of defaulting" $rc
  # The SEAM: the sweep must CONSUME the block's $SEL. A build where the jq hardcodes a filter
  # still logs the scope correctly but never changes what is swept — the override is inert.
  grep -qF '|$SEL|' "$LOOP" && rc=0 || { rc=1; echo "      the sweep jq does not interpolate \$SEL"; }
  ck "shipped scope: the sweep actually consumes \$SEL" $rc
  unset -f drive_scope drive_scope_unset
fi

# ── 16c) the launchers can actually SET the scope (else the pin is unreachable) ───
# launchd inherits NO shell env, so a SCOPE that install.sh does not render into the plist cannot
# be pinned on a second Mac — the pin would be documentation only. The template must carry it,
# install.sh must render it, and install.sh must refuse a bad value at install time.
grep -qF '__SCOPE__' "$HERE/launchd.plist.template" && rc=0 || rc=1
ck "the plist template carries a SCOPE key" $rc
grep -qF '__SCOPE__' "$INST" && rc=0 || rc=1
ck "the SCOPE placeholder is present in install.sh (diagnostic; the value is asserted below)" $rc
# Sandboxed, and the refusal REASON is asserted: without HOME/REPO/O overrides, a mutant that
# deletes the validator still exits non-zero (an unrelated preflight failure), so an rc-only check
# would stay green — and on a host where the default REPO exists it would write a plist into the
# operator's REAL ~/Library/LaunchAgents.
( SCOPE=banana HOME="$SB" O="$TMP/sb-o" REPO="$HERE/../.." OR="acme/widget" bash "$INST" >/dev/null 2>"$TMP/inst.err" ); rc=$?
[ "$rc" -ne 0 ] && rc=0 || { rc=1; echo "      install.sh accepted SCOPE=banana (rc=$rc)"; }
ck "install.sh refuses an invalid SCOPE" $rc
grep -qF 'SCOPE must be auto|own|broad' "$TMP/inst.err" && rc=0 || { rc=1; echo "      stderr: $(cat "$TMP/inst.err")"; }
ck "install.sh refuses it for the SCOPE reason, naming the accepted values" $rc

# The rendered VALUE, not just the placeholder. A render that ignores $SCOPE entirely (e.g. a
# hardcoded `s|__SCOPE__|auto|g`) leaves the literal '__SCOPE__' in install.sh's own source, so
# both greps above stay green while the pin silently evaporates at install time. Assert the value
# that actually lands in the plist, through the real installer.
PL2="$SB/Library/LaunchAgents/com.eldato.orchestrator-loop.plist"
render_scope() {   # $1 = a value, or the literal __UNSET__
  if [ "$1" = "__UNSET__" ]; then
    HOME="$SB" O="$TMP/sb-o" REPO="$HERE/../.." OR="acme/widget" env -u SCOPE bash "$INST" >/dev/null 2>&1
  else
    HOME="$SB" O="$TMP/sb-o" REPO="$HERE/../.." OR="acme/widget" SCOPE="$1" bash "$INST" >/dev/null 2>&1
  fi
  plutil -extract EnvironmentVariables.SCOPE raw "$PL2" 2>/dev/null || echo MISSING
}
for want in own broad; do
  got="$(render_scope "$want")"
  [ "$got" = "$want" ] && rc=0 || { rc=1; echo "      rendered SCOPE='$got', wanted '$want'"; }
  ck "the plist renders SCOPE=$want, not a hardcoded default" $rc
done
got="$(render_scope __UNSET__)"
[ "$got" = "auto" ] && rc=0 || { rc=1; echo "      rendered SCOPE='$got', wanted 'auto'"; }
ck "an UNSET SCOPE renders the auto default" $rc

# set-but-EMPTY is FATAL on BOTH launchers — a blank plist / keys.env entry must not become `auto`,
# which is the shared-queue drain the override exists to prevent. install.sh:
( SCOPE= HOME="$SB" O="$TMP/sb-o" REPO="$HERE/../.." OR="acme/widget" bash "$INST" >/dev/null 2>"$TMP/inst.empty.err" ); rc=$?
[ "$rc" -ne 0 ] && rc=0 || { rc=1; echo "      install.sh accepted a set-but-empty SCOPE"; }
ck "install.sh refuses a set-but-empty SCOPE (never coerced to auto)" $rc
# ... and the cell supervisor, which forwards it into the tmux session's command string. Provision
# CELL_HOME and the repo so a non-zero rc cannot come from cmd_check's preflight, require the SCOPE
# message so a neutered validator cannot pass on a preflight rc, and put the tmux stub FIRST on
# PATH — under the very regression this check guards (a validator that passes), the supervisor would
# otherwise create a REAL session and execute the live controller.
mkdir -p "$TMP/cellhome/.pi/agent/scripts" "$TMP/cellrepo/.git"
# #1717: cmd_check now refuses a cell with no record-review.sh, so every fixture that reaches the
# dependency probe needs one. These cases die at validate_scope() first, so the stub is for the
# shapes that do not.
printf '#!/bin/bash\nexit 0\n' > "$TMP/cellhome/.pi/agent/scripts/record-review.sh"
chmod +x "$TMP/cellhome/.pi/agent/scripts/record-review.sh"
STUB_TM="$TMP/stub-tm"; mkdir -p "$STUB_TM"
cat > "$STUB_TM/tmux" <<'STUB'
#!/bin/bash
case "$1" in
  has-session) [ -f "$TM_STATE/up" ] && exit 0 || exit 1 ;;
  new-session) shift; printf '%s\n' "$*" > "$TM_STATE/cmd"; : > "$TM_STATE/up"; exit 0 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$STUB_TM/tmux"
# The stub must be ABLE to record a session: without this the new-session write fails, so the
# session-file clause below could never fire and a mutant that started a real session would surface
# only through the refusal-message clause. Created empty, the stub still reports has-session=absent.
mkdir -p "$TMP/sup-empty"
( SCOPE= PATH="$STUB_TM:$PATH" TM_STATE="$TMP/sup-empty" HOME="$TMP/cellhome" CELL_HOME="$TMP/cellhome" REPO="$TMP/cellrepo" O="$TMP/sb-o" HARNESS="$HERE" \
    bash "$HERE/../cloud-cell-supervisor.sh" start >/dev/null 2>"$TMP/sup.empty.err" ); rc=$?
# ONE conjunction. This was two statements and the second RECOMPUTED rc from its own exit status,
# discarding the first — so a mutant that created the session and only then died with the SCOPE
# message printed the violation and still reported PASS. Each clause must hold for the PASS: a
# non-zero rc, NO session file (the stub above can now truly record one), and the refusal message.
[ "$rc" -ne 0 ] && [ ! -f "$TMP/sup-empty/cmd" ] && grep -qF 'SCOPE must be auto|own|broad' "$TMP/sup.empty.err" && rc=0 \
  || { rc=1; echo "      a session was created, or the SCOPE refusal was not reached; stderr: $(tail -2 "$TMP/sup.empty.err")"; }
ck "the cell supervisor refuses a set-but-empty SCOPE, naming the accepted values" $rc

# ... and `check` must refuse it too. Its verdict is the literal line `CELL CAN RUN A CONTROLLER`, so a
# preflight that certifies a SCOPE its own `start` then dies on is a FALSE PASS on the only question
# that verdict answers. Driven with a value NEITHER subcommand accepts, and both halves asserted: the
# refusal names the accepted values, AND the certification line is absent.
( SCOPE=banana PATH="$STUB_TM:$PATH" TM_STATE="$TMP/sup-chkbad" HOME="$TMP/cellhome" CELL_HOME="$TMP/cellhome" REPO="$TMP/cellrepo" O="$TMP/sb-o" HARNESS="$HERE" \
    bash "$HERE/../cloud-cell-supervisor.sh" check >"$TMP/sup.chkbad.out" 2>"$TMP/sup.chkbad.err" ); rc=$?
[ "$rc" -ne 0 ] && grep -qF 'SCOPE must be auto|own|broad' "$TMP/sup.chkbad.err" \
  && ! grep -qF 'CELL CAN RUN A CONTROLLER' "$TMP/sup.chkbad.out" && rc=0 \
  || { rc=1; echo "      check certified (or failed to refuse) SCOPE=banana; stderr: $(tail -2 "$TMP/sup.chkbad.err")"; }
ck "the cell supervisor's check refuses a bad SCOPE instead of certifying the cell" $rc

# install.sh must refuse the SAME $O its controller refuses: a plist that renders here but is
# rejected there is worse than a refusal — RunAtLoad+KeepAlive relaunches a guaranteed-fatal
# controller forever. BOTH guards are driven over the same eight values — orch-loop.sh's extracted
# here, install.sh's END TO END below — so the two cannot drift apart silently.
# Drive the SHIPPED guard, EXTRACTED — never the live controller: running orch-loop.sh to test it
# would enter its dispatch loop with the DEFAULT OR (daniel-ospina/tortoise) and could merge PRs if
# the guard regressed — the very regression this check exists to catch (the suite must stay
# offline: "No network, no tmux server, no git writes").
awk '/^case "\$O" in/{f=1} f{print} f&&/^esac/{exit}' "$HERE/orch-loop.sh" > "$TMP/oguard.sh"
if need "$TMP/oguard.sh" "the \$O guard is extracted from the shipped orch-loop.sh"; then
  # Every member of the class, not just a space: the guard has eight alternatives and the SPACE is
  # inert — the quote and the metacharacters are the ones that enable the sh -c break-out, so a
  # mutated guard that lost them must not stay green.
  for bad in 'o space' "o'q" 'o"q' 'o`q' 'o$q' 'o;q' 'o|q' 'o&q'; do
    ( O="$TMP/$bad"; . "$TMP/oguard.sh" ) >/dev/null 2>&1; rc=$?
    ck "orch-loop.sh's \$O guard refuses '$bad'" $([ "$rc" -ne 0 ] && echo 0 || echo 1)
  done
  ( O="$TMP/clean-o"; . "$TMP/oguard.sh" ) >/dev/null 2>&1; rc=$?
  ck "orch-loop.sh's \$O guard accepts a clean path (non-vacuity)" $([ "$rc" -eq 0 ] && echo 0 || echo 1)
fi
# install.sh's guard is driven END TO END over the SAME eight values. Driving it for only the space
# (and the quote) left seven alternatives unpinned: narrowing install.sh's list to quote+space alone
# kept the whole suite green, while install.sh would render a plist for an $O the controller refuses
# forever — the exact failure the pair of checks exists to prevent.
SB5="$TMP/sb5"; mkdir -p "$SB5/Library/LaunchAgents" "$SB5/.config" "$SB5/.pi/agent/scripts"
ln -s "$HOME/.config/gh" "$SB5/.config/gh" 2>/dev/null || true
mkdir -p "$SB5/.local/share/pi-node/current/bin"
printf '#!/bin/bash\nexit 0\n' > "$SB5/.local/share/pi-node/current/bin/pi"; chmod +x "$SB5/.local/share/pi-node/current/bin/pi"
( HOME="$SB5" O="$TMP/clean-o" REPO="$HERE/../.." OR="acme/widget" bash "$INST" >/dev/null 2>"$TMP/inst.clean.err" ); rc=$?
[ "$rc" -eq 0 ] && rc=0 || { rc=1; echo "      install.sh refused a clean \$O: $(tail -2 "$TMP/inst.clean.err")"; }
ck "install.sh accepts a clean \$O (non-vacuity for the guard loop below)" $rc
for bad in 'o space' "o'q" 'o"q' 'o`q' 'o$q' 'o;q' 'o|q' 'o&q'; do
  ( HOME="$SB5" O="$TMP/$bad" REPO="$HERE/../.." OR="acme/widget" bash "$INST" >/dev/null 2>"$TMP/inst.og.err" ); rc=$?
  [ "$rc" -ne 0 ] && grep -qF 'metacharacter' "$TMP/inst.og.err" && rc=0 \
    || { rc=1; echo "      install.sh accepted \$O='$bad': $(tail -2 "$TMP/inst.og.err")"; }
  ck "install.sh refuses the same \$O orch-loop.sh refuses: '$bad'" $rc
done

# --uninstall renders nothing, so an unrelated SCOPE typo must not block it: the operator removing
# a misbehaving daemon is exactly who must not be stopped by it.
( HOME="$SB" SCOPE=banana bash "$INST" --uninstall >/dev/null 2>&1 ); rc=$?
[ "$rc" -eq 0 ] && rc=0 || { rc=1; echo "      install.sh --uninstall was blocked by SCOPE=banana"; }
ck "install.sh --uninstall is not blocked by an invalid SCOPE" $rc

# A ZERO-BYTE key file is not a key: `-f` blessed it, and the daemon then recorded reviews
# UNSIGNED and failed ai-review-gate — the env-only failure with the file branch taken (README §7.4).
: > "$SB/.pi/agent/.ai-review-gate-key"
ikout="$(HOME="$SB" O="$TMP/ik-o" REPO="$HERE/../.." OR="acme/widget" bash "$INST" 2>&1)"
case "$ikout" in *'gate key file present'*) rc=1; echo "      install.sh blessed an empty key file" ;; *) rc=0 ;; esac
ck "install.sh does not bless a ZERO-BYTE key file" $rc
printf 'k\n' > "$SB/.pi/agent/.ai-review-gate-key"
ikout="$(HOME="$SB" O="$TMP/ik-o" REPO="$HERE/../.." OR="acme/widget" bash "$INST" 2>&1)"
rm -f "$SB/.pi/agent/.ai-review-gate-key"
case "$ikout" in *'gate key file present'*) rc=0 ;; *) rc=1; echo "      install.sh did not report a non-empty key file" ;; esac
ck "install.sh reports a NON-EMPTY key file present (non-vacuity)" $rc
# The consumer strips whitespace, so a 1-byte newline (what `echo "$KEY" > file` writes for an unset
# variable) is NOT a key — size alone must not bless it.
printf '\n' > "$SB/.pi/agent/.ai-review-gate-key"
ikout="$(HOME="$SB" O="$TMP/ik-o" REPO="$HERE/../.." OR="acme/widget" bash "$INST" 2>&1)"
rm -f "$SB/.pi/agent/.ai-review-gate-key"
case "$ikout" in *'gate key file present'*) rc=1; echo "      install.sh blessed a whitespace-only key file" ;; *) rc=0 ;; esac
ck "install.sh does not bless a WHITESPACE-ONLY key file" $rc
# An EXISTING but UNREADABLE key file is neither missing nor empty. The verdict must name it, or the
# prescribed remedy ("write the key with printf") is given for a file that may already hold one.
printf 'secret\n' > "$SB/.pi/agent/.ai-review-gate-key"; chmod 000 "$SB/.pi/agent/.ai-review-gate-key"
ikout="$(HOME="$SB" O="$TMP/ik-o" REPO="$HERE/../.." OR="acme/widget" bash "$INST" 2>&1)"
chmod 600 "$SB/.pi/agent/.ai-review-gate-key"
rm -f "$SB/.pi/agent/.ai-review-gate-key"
case "$ikout" in *'NOT READABLE'*) rc=0 ;; *) rc=1; echo "      install.sh did not name an unreadable key file: $(printf '%s\n' "$ikout" | grep -i 'key' | head -2)";; esac
ck "install.sh names an EXISTING-BUT-UNREADABLE key file as such, not as empty" $rc

# ── 16e) the cell supervisor FORWARDS the SCOPE it validated ─────────────────
# A tmux server supplies a new session's environment, so an exported SCOPE is silently dropped and
# the cell falls back to `auto` — a pin that is not INLINED into the session's command string is
# documentation, not a setting. Drive the shipped cmd_start with a tmux stub that records the
# command it is handed (this is the only place the forwarding can be observed).
TM="$TMP/tm/bin"; mkdir -p "$TM" "$TMP/tm/repo/.git" "$TMP/tm/home" "$TMP/tm/harness"
cp "$HERE"/*.sh "$TMP/tm/harness/"
# #1717: the recorder must be deliverable two ways — pre-existing in the cell's HOME, and (the
# provision path) as the canonical copy one directory up from the harness. Both are placed so no
# check below depends on the order the others ran in; the provision path itself is covered by
# cloud-cell-record-dep.test.sh.
mkdir -p "$TMP/tm/home/.pi/agent/scripts"
printf '#!/bin/bash\nexit 0\n' > "$TMP/tm/home/.pi/agent/scripts/record-review.sh"
chmod +x "$TMP/tm/home/.pi/agent/scripts/record-review.sh"
printf '#!/bin/bash\nexit 0\n' > "$TMP/tm/record-review.sh"
chmod +x "$TMP/tm/record-review.sh"
cat > "$TM/tmux" <<'STUB'
#!/bin/bash
case "$1" in
  has-session) [ -f "$TM_STATE/up" ] && exit 0 || exit 1 ;;
  new-session) shift; printf '%s\n' "$*" > "$TM_STATE/cmd"; : > "$TM_STATE/up"; exit 0 ;;
  *) exit 0 ;;
esac
STUB
printf '#!/bin/bash\nexit 0\n' > "$TM/gh"
chmod +x "$TM/tmux" "$TM/gh"
sup_start() {  # $1 = the SCOPE value to start with (__UNSET__ omits it)
  rm -f "$TMP/tm/up" "$TMP/tm/cmd"
  if [ "$1" = "__UNSET__" ]; then
    env -u SCOPE PATH="$TM:$PATH" TM_STATE="$TMP/tm" HOME="$TMP/tm/home" CELL_HOME="$TMP/tm/home" \
      REPO="$TMP/tm/repo" O="$TMP/tm/o" HARNESS="$TMP/tm/harness" \
      bash "$HERE/../cloud-cell-supervisor.sh" start >/dev/null 2>&1
  else
    PATH="$TM:$PATH" TM_STATE="$TMP/tm" HOME="$TMP/tm/home" CELL_HOME="$TMP/tm/home" \
      REPO="$TMP/tm/repo" O="$TMP/tm/o" HARNESS="$TMP/tm/harness" SCOPE="$1" \
      bash "$HERE/../cloud-cell-supervisor.sh" start >/dev/null 2>&1
  fi
}
for want in own broad __UNSET__; do
  sup_start "$want"
  wantval="$want"; [ "$want" = "__UNSET__" ] && wantval=auto
  grep -qF "SCOPE='$wantval'" "$TMP/tm/cmd" 2>/dev/null && rc=0 || { rc=1; echo "      forwarded: $(cat "$TMP/tm/cmd" 2>/dev/null)"; }
  ck "the cell supervisor inlines SCOPE=$wantval for '$want' into the session command" $rc
done
# UNSET must reach the controller as the auto default being absent-or-auto — but a typo/blank must
# die BEFORE a session is created (nothing started, no tmux command recorded).
rm -f "$TMP/tm/up" "$TMP/tm/cmd"
( SCOPE= PATH="$TM:$PATH" TM_STATE="$TMP/tm" HOME="$TMP/tm/home" CELL_HOME="$TMP/tm/home" \
    REPO="$TMP/tm/repo" O="$TMP/tm/o" HARNESS="$TMP/tm/harness" \
    bash "$HERE/../cloud-cell-supervisor.sh" start >/dev/null 2>&1 ); rc=$?
[ "$rc" -ne 0 ] && [ ! -f "$TMP/tm/cmd" ] && rc=0 || { rc=1; echo "      rc=$rc; cmd recorded: $([ -f "$TMP/tm/cmd" ] && echo yes || echo no)"; }
ck "a set-but-empty SCOPE is refused BEFORE any session is started" $rc

# Every interpolated value must be metacharacter-free (the session string is handed to tmux, which
# runs it with sh -c), so a quote in $O must be refused BEFORE a session exists — and before any
# injected command could run. The sibling guards in orch-loop.sh and install.sh are asserted above.
# The payload is a quote with NO literal space (${IFS} stands in for it): a guard that kept only the
# space alternative would accept this, so the check pins the quote member — the one that actually
# enables the break-out — not merely the class as a whole.
rm -f "$TMP/tm/up" "$TMP/tm/cmd" "$TMP/tm/INJECTED"
( PATH="$TM:$PATH" TM_STATE="$TMP/tm" HOME="$TMP/tm/home" CELL_HOME="$TMP/tm/home" \
    REPO="$TMP/tm/repo" O="$TMP/tm/it';touch\${IFS}$TMP/tm/INJECTED;#" HARNESS="$TMP/tm/harness" SCOPE=own \
    bash "$HERE/../cloud-cell-supervisor.sh" start >/dev/null 2>"$TMP/sup.meta.err" ); rc=$?
[ "$rc" -ne 0 ] && [ ! -f "$TMP/tm/cmd" ] && [ ! -f "$TMP/tm/INJECTED" ] && rc=0 \
  || { rc=1; echo "      rc=$rc; session recorded: $([ -f "$TMP/tm/cmd" ] && echo yes || echo no); injected: $([ -f "$TMP/tm/INJECTED" ] && echo yes || echo no)"; }
ck "a metacharacter in \$O is refused before any session is created" $rc

# The session string carries OR too, and the guard must cover it — this is the value whose omission
# was a live injection (a quote in OR broke out of the sh -c string and executed a command).
rm -f "$TMP/tm/up" "$TMP/tm/cmd"
( PATH="$TM:$PATH" TM_STATE="$TMP/tm" HOME="$TMP/tm/home" CELL_HOME="$TMP/tm/home" \
    REPO="$TMP/tm/repo" O="$TMP/tm/o" HARNESS="$TMP/tm/harness" SCOPE=own OR="acme/x';touch\${IFS}$TMP/tm/ORPWN;#" \
    bash "$HERE/../cloud-cell-supervisor.sh" start >/dev/null 2>"$TMP/sup.or.err" ); rc=$?
[ "$rc" -ne 0 ] && [ ! -f "$TMP/tm/cmd" ] && [ ! -f "$TMP/tm/ORPWN" ] && rc=0 \
  || { rc=1; echo "      rc=$rc; session recorded: $([ -f "$TMP/tm/cmd" ] && echo yes || echo no)"; }
ck "a metacharacter in \$OR is refused before any session is created" $rc
# The QUOTE is the break-out enabler, so drive it ALONE — no $, ; or # for another alternative to
# match: a guard that lost only the quote alternatives must still go red here.
rm -f "$TMP/tm/up" "$TMP/tm/cmd"
( PATH="$TM:$PATH" TM_STATE="$TMP/tm" HOME="$TMP/tm/home" CELL_HOME="$TMP/tm/home" \
    REPO="$TMP/tm/repo" O="$TMP/tm/it'q" HARNESS="$TMP/tm/harness" SCOPE=own \
    bash "$HERE/../cloud-cell-supervisor.sh" start >/dev/null 2>&1 ); rc=$?
[ "$rc" -ne 0 ] && [ ! -f "$TMP/tm/cmd" ] && rc=0 \
  || { rc=1; echo "      rc=$rc; session recorded: $([ -f "$TMP/tm/cmd" ] && echo yes || echo no)"; }
ck "a QUOTE-ONLY \$O is refused (the quote is the break-out enabler)" $rc
rm -f "$TMP/tm/up" "$TMP/tm/cmd"
( PATH="$TM:$PATH" TM_STATE="$TMP/tm" HOME="$TMP/tm/home" CELL_HOME="$TMP/tm/home" \
    REPO="$TMP/tm/repo" O="$TMP/tm/o" HARNESS="$TMP/tm/harness" SCOPE=own OR="acme/x'q" \
    bash "$HERE/../cloud-cell-supervisor.sh" start >/dev/null 2>&1 ); rc=$?
[ "$rc" -ne 0 ] && [ ! -f "$TMP/tm/cmd" ] && rc=0 \
  || { rc=1; echo "      rc=$rc; session recorded: $([ -f "$TMP/tm/cmd" ] && echo yes || echo no)"; }
ck "a QUOTE-ONLY \$OR is refused (the quote is the break-out enabler)" $rc
# The merge key must NOT be interpolated into the session string at all: a secret in an argv string
# is visible to ps/tmux, and it was the other unguarded member of this same class. It reaches the
# session through \$ENV_FILE (which the session re-sources).
sup_start own
if [ -s "$TMP/tm/cmd" ]; then
  grep -qF 'AI_REVIEW_GATE_KEY' "$TMP/tm/cmd" && rc=1 || rc=0
else
  rc=1; echo "      no session command was recorded to inspect"
fi
ck "the session command string does not carry the merge key" $rc
# The same EXISTING-BUT-UNREADABLE distinction in the preflight: a cell whose key file is mode 000
# must be told so — "no key" is a different fault with a different remedy. Drive `check` itself
# (the verdict a cell trusts), with the ambient key unset so the branch under test is reached.
mkdir -p "$TMP/tm/home/.pi/agent"
printf 'secret\n' > "$TMP/tm/home/.pi/agent/.ai-review-gate-key"
chmod 000 "$TMP/tm/home/.pi/agent/.ai-review-gate-key"
supchk="$( env -u AI_REVIEW_GATE_KEY PATH="$TM:$PATH" TM_STATE="$TMP/tm" HOME="$TMP/tm/home" CELL_HOME="$TMP/tm/home" \
    REPO="$TMP/tm/repo" O="$TMP/tm/o" HARNESS="$TMP/tm/harness" SCOPE=own \
    bash "$HERE/../cloud-cell-supervisor.sh" check 2>&1 )"
chmod 600 "$TMP/tm/home/.pi/agent/.ai-review-gate-key"
rm -f "$TMP/tm/home/.pi/agent/.ai-review-gate-key"
case "$supchk" in *'NOT READABLE'*) rc=0 ;; *) rc=1; echo "      the preflight did not name the unreadable key: $(printf '%s\n' "$supchk" | grep -i 'key' | head -2)";; esac
ck "the cell preflight names an EXISTING-BUT-UNREADABLE key file as such" $rc

# ── 16f) cmd_check judges the merge key by what the SESSION will receive ────────
# The session re-sources $ENV_FILE, so a key in that file reaches the controller while an
# ambient-only export does NOT (tmux serves a new session the server's environment). Reporting the
# ambient one as "present" was a false green on a cell that merges without the key.
KC="$TMP/kc"; mkdir -p "$KC/home" "$KC/repo/.git" "$KC/o" "$KC/harness"
cp "$HERE"/*.sh "$KC/harness/"; cp "$HERE"/*.sh "$KC/o/"
# #1717: cmd_check refuses a cell without the record step, and every check in 16f drives cmd_check.
mkdir -p "$KC/home/.pi/agent/scripts"
printf '#!/bin/bash\nexit 0\n' > "$KC/home/.pi/agent/scripts/record-review.sh"
chmod +x "$KC/home/.pi/agent/scripts/record-review.sh"
printf 'AI_REVIEW_GATE_KEY=FILEKEY\n' > "$KC/home/keys.env"; : > "$KC/home/keys-empty.env"
kc_check() {  # $1 = ENV_FILE, $2 = extra env assignment for the supervisor's own shell ('' = none)
  if [ -n "$2" ]; then
    env "$2" PATH="$STUB_TM:$GSTUB:$PATH" HOME="$KC/home" CELL_HOME="$KC/home" REPO="$KC/repo" \
      O="$KC/o" HARNESS="$KC/harness" ENV_FILE="$1" bash "$HERE/../cloud-cell-supervisor.sh" check 2>&1
  else
    PATH="$STUB_TM:$GSTUB:$PATH" HOME="$KC/home" CELL_HOME="$KC/home" REPO="$KC/repo" \
      O="$KC/o" HARNESS="$KC/harness" ENV_FILE="$1" bash "$HERE/../cloud-cell-supervisor.sh" check 2>&1
  fi
}
out="$( unset AI_REVIEW_GATE_KEY; kc_check "$KC/home/keys.env" '' )"
case "$out" in *'merge authority key present'*) rc=0 ;; *) rc=1; echo "      out: $(printf '%s' "$out" | tail -2)" ;; esac
ck "cmd_check reports the key present when keys.env carries it" $rc
out="$(kc_check "$KC/home/keys-empty.env" 'AI_REVIEW_GATE_KEY=AMBIENT')"
case "$out" in *'will NOT receive it'*) rc=0 ;; *) rc=1; echo "      out: $(printf '%s' "$out" | tail -2)" ;; esac
ck "cmd_check warns that an ambient-only key does not reach the session" $rc
# An EMPTY assignment matches a textual grep but sources to empty, which downstream treats as
# absent — so it must not be reported present (a false green on a cell that cannot merge).
printf 'AI_REVIEW_GATE_KEY=\n' > "$KC/home/keys-empty-key.env"
out="$( unset AI_REVIEW_GATE_KEY; kc_check "$KC/home/keys-empty-key.env" '' )"
case "$out" in *'merge authority key present'*) rc=1; echo "      out: $(printf '%s' "$out" | tail -2)" ;; *) rc=0 ;; esac
ck "an EMPTY key in keys.env is NOT reported present" $rc
# The start path is the ONLY path that starts a cell, so it must not swallow the verdict: an
# operator who exported the key ambiently gets a keyless cell and no signal otherwise.
rm -f "$TMP/tm/up" "$TMP/tm/cmd"
serr="$( AI_REVIEW_GATE_KEY=AMBIENT PATH="$TM:$PATH" TM_STATE="$TMP/tm" HOME="$KC/home" CELL_HOME="$KC/home" \
    REPO="$KC/repo" O="$KC/o" HARNESS="$KC/harness" ENV_FILE="$KC/home/keys-empty.env" SCOPE=own \
    bash "$HERE/../cloud-cell-supervisor.sh" start 2>&1 >/dev/null )"
case "$serr" in *'will NOT receive it'*"$KC/home/.pi/agent/.ai-review-gate-key"*) rc=0 ;; *) rc=1; echo "      stderr: $(printf '%s' "$serr" | tail -2)" ;; esac
ck "the start path surfaces an ambient-only key verdict on stderr" $rc
# ... and the OTHER branch: an empty keys.env with NO ambient key must also reach start's stderr
# (filtering on just the two easy-to-grep verdicts left this one silent).
rm -f "$TMP/tm/up" "$TMP/tm/cmd"
serr2="$( unset AI_REVIEW_GATE_KEY; PATH="$TM:$PATH" TM_STATE="$TMP/tm" HOME="$KC/home" CELL_HOME="$KC/home" \
    REPO="$KC/repo" O="$KC/o" HARNESS="$KC/harness" ENV_FILE="$KC/home/keys-empty-key.env" SCOPE=own \
    bash "$HERE/../cloud-cell-supervisor.sh" start 2>&1 >/dev/null )"
case "$serr2" in *'AI_REVIEW_GATE_KEY'*) rc=0 ;; *) rc=1; echo "      stderr: $(printf '%s' "$serr2" | tail -2)" ;; esac
ck "the start path surfaces the no-key verdict on stderr" $rc
# A whitespace-only key FILE is not a key either (the consumer strips whitespace).
mkdir -p "$KC/home/.pi/agent"; printf '\n' > "$KC/home/.pi/agent/.ai-review-gate-key"
out="$( unset AI_REVIEW_GATE_KEY; kc_check "$KC/home/keys-empty-key.env" '' )"
rm -f "$KC/home/.pi/agent/.ai-review-gate-key"
case "$out" in *'merge authority key present'*) rc=1; echo "      out: $(printf '%s' "$out" | tail -2)" ;; *) rc=0 ;; esac
ck "cmd_check does not bless a WHITESPACE-ONLY key file" $rc
# A WHITESPACE-ONLY value in keys.env is the same false green one step earlier: the consumer
# strips whitespace, and because the raw value is non-empty it never falls back to the key FILE.
# cmd_check must judge it absent (not "present in $ENV_FILE").
printf 'AI_REVIEW_GATE_KEY="   "\n' > "$KC/home/keys-ws-value.env"
out="$( unset AI_REVIEW_GATE_KEY; kc_check "$KC/home/keys-ws-value.env" '' )"
case "$out" in
  *'merge authority key present'*) rc=1; echo "      out: $(printf '%s' "$out" | tail -2)" ;;
  # The verdict must name the path the check ACTUALLY reads: the message is the operator's only
  # instruction, and on a real cell $HOME is not $CELL_HOME, so "~/.pi/..." would send them to a home
  # the session never reads.
  *'WHITESPACE-ONLY'*"$KC/home/.pi/agent/.ai-review-gate-key"*) rc=0 ;;
  *) rc=1; echo "      no whitespace verdict naming the path: $(printf '%s' "$out" | tail -2)" ;;
esac
ck "a WHITESPACE-ONLY key in keys.env is not reported present, and is named" $rc
# …and it SHADOWS a valid key file (the consumer's fallback is on the raw value), so a real file
# must not turn that same verdict green.
printf 'FILEKEY\n' > "$KC/home/.pi/agent/.ai-review-gate-key"
out="$( unset AI_REVIEW_GATE_KEY; kc_check "$KC/home/keys-ws-value.env" '' )"
rm -f "$KC/home/.pi/agent/.ai-review-gate-key"
case "$out" in *'merge authority key present'*) rc=1; echo "      out: $(printf '%s' "$out" | tail -2)" ;; *) rc=0 ;; esac
ck "a WHITESPACE-ONLY key in keys.env shadows a valid key file" $rc
# The start path must surface that verdict too: it starts the cell either way, and it is the only
# signal the operator gets.
rm -f "$TMP/tm/up" "$TMP/tm/cmd"
serr3="$( unset AI_REVIEW_GATE_KEY; PATH="$TM:$PATH" TM_STATE="$TMP/tm" HOME="$KC/home" CELL_HOME="$KC/home" \
    REPO="$KC/repo" O="$KC/o" HARNESS="$KC/harness" ENV_FILE="$KC/home/keys-ws-value.env" SCOPE=own \
    bash "$HERE/../cloud-cell-supervisor.sh" start 2>&1 >/dev/null )"
case "$serr3" in *'WHITESPACE-ONLY'*"$KC/home/.pi/agent/.ai-review-gate-key"*) rc=0 ;; *) rc=1; echo "      stderr: $(printf '%s' "$serr3" | tail -2)" ;; esac
ck "the start path surfaces the whitespace-only key verdict on stderr" $rc
# keys.env may set HOME, and the supervisor re-exports HOME=$CELL_HOME AFTER sourcing — so the key
# verdict must not depend on which home a keys.env HOME= line points at. (Full disclosure: with that
# re-export in place ${HOME} and $CELL_HOME are the same value, so this pins the BEHAVIOUR, not the
# spelling — a mutant that reads ${HOME} is equivalent and stays green, by design.)
KH="$KC/other-home"; mkdir -p "$KH/.pi/agent"; printf 'FILEKEY\n' > "$KH/.pi/agent/.ai-review-gate-key"
printf 'HOME=%s\n' "$KH" > "$KC/home/keys-home.env"
out="$( unset AI_REVIEW_GATE_KEY; kc_check "$KC/home/keys-home.env" '' )"
case "$out" in *'merge authority key present'*) rc=1; echo "      out: $(printf '%s' "$out" | tail -2)" ;; *) rc=0 ;; esac
ck "a keys.env HOME= does not make the key verdict green (it reads \$CELL_HOME)" $rc
# …and the mirror image of the SAME divergence, so the pair discriminates in both directions: a
# keys.env HOME= pointing at a directory WITHOUT a key must not hide the key that IS in $CELL_HOME.
# (Setting HOME in the helper's env cannot discriminate: the supervisor re-exports HOME=$CELL_HOME
# before sourcing, so ONLY a keys.env HOME= can make the two differ — which is why both halves are
# driven through the file. A $HOME passed as an env prefix passes on the pre-fix code too.)
printf 'FILEKEY\n' > "$KC/home/.pi/agent/.ai-review-gate-key"
mkdir -p "$KC/no-key-home"
printf 'HOME=%s\n' "$KC/no-key-home" > "$KC/home/keys-other-home.env"
out="$( unset AI_REVIEW_GATE_KEY; kc_check "$KC/home/keys-other-home.env" '' )"
rm -f "$KC/home/.pi/agent/.ai-review-gate-key"
case "$out" in *'merge authority key present'*) rc=0 ;; *) rc=1; echo "      out: $(printf '%s' "$out" | tail -2)" ;; esac
ck "a keys.env HOME= without a key does not hide the key in \$CELL_HOME" $rc
# A value of exactly ONE NEWLINE is whitespace-only for the consumer (it strips whitespace) but
# NON-EMPTY for its raw test, so the consumer takes the env branch and never reads the key file.
# `$( )` strips trailing newlines, so a capture-based test reads this as "no env value" and the
# file branch answers — the divergence that made a keyless cell read as present.
printf 'AI_REVIEW_GATE_KEY="\n"\n' > "$KC/home/keys-nl.env"
printf 'FILEKEY\n' > "$KC/home/.pi/agent/.ai-review-gate-key"
out="$( unset AI_REVIEW_GATE_KEY; kc_check "$KC/home/keys-nl.env" '' )"
rm -f "$KC/home/.pi/agent/.ai-review-gate-key"
case "$out" in
  *'merge authority key present'*) rc=1; echo "      out: $(printf '%s' "$out" | tail -2)" ;;
  *'WHITESPACE-ONLY'*) rc=0 ;;
  *) rc=1; echo "      no whitespace verdict: $(printf '%s' "$out" | tail -2)" ;;
esac
ck "a NEWLINE-ONLY key in keys.env is judged whitespace-only, not present via the file" $rc
# The gh-credential lookup is HOME-dependent (`gh` reads $HOME/.config/gh), and keys.env may carry
# a HOME= line — so the preflight must ask that question under the SAME home the session will use
# ($CELL_HOME, forced by the session command). Sourcing keys.env last left cmd_check validating a
# home the session never uses: credentials there made it say "ok: gh auth" and the cell started,
# after which every gh call in the session failed.
printf 'HOME=%s\n' "$KH" > "$KC/home/keys-home2.env"
GH_HOME_RECORD="$TMP/gh-home.txt"; rm -f "$GH_HOME_RECORD"; export GH_HOME_RECORD
kc_check "$KC/home/keys-home2.env" '' >/dev/null 2>&1 || true
unset GH_HOME_RECORD
if [ -s "$TMP/gh-home.txt" ]; then
  [ "$(cat "$TMP/gh-home.txt")" = "$KC/home" ] && rc=0 || { rc=1; echo "      gh saw HOME=$(cat "$TMP/gh-home.txt"), cell home is $KC/home"; }
else
  rc=1; echo "      gh was never invoked with a recorded HOME"
fi
ck "cmd_check runs gh under \$CELL_HOME, not a keys.env HOME=" $rc
# The SAME divergence exists in cloud-cell-bringup.sh (it sources keys.env and runs check_gh
# afterwards), and it has no other guard at all — deleting its re-export left the suite green.
# Driven for real: the script's own flow with stub tools, and the gh stub records the HOME that
# `auth status` ran under.
BG="$TMP/bg"; mkdir -p "$BG/stub" "$BG/home/.pi/agent" "$BG/otherhome"
git init -q "$BG/work" 2>/dev/null || true
cat > "$BG/stub/gh" <<'GHSTUB'
#!/bin/bash
case "$*" in
  *"auth status"*) [ -n "${GH_HOME_RECORD:-}" ] && printf '%s\n' "$HOME" >> "$GH_HOME_RECORD"; exit 0 ;;
  *"api user"*) echo tester; exit 0 ;;
  *"api repos/"*) echo true; exit 0 ;;
esac
exit 0
GHSTUB
printf '#!/bin/bash\necho 200\n' > "$BG/stub/curl"
printf '#!/bin/bash\necho LANE_READY\n' > "$BG/stub/pi"
printf '#!/bin/bash\nshift; exec "$@"\n' > "$BG/stub/timeout"
printf '#!/bin/bash\nexit 0\n' > "$BG/stub/docker"
chmod +x "$BG/stub/"*
printf 'HOME=%s\nDEEPSEEK_API_KEY=sk-test\n' "$BG/otherhome" > "$BG/home/keys.env"
GH_HOME_RECORD="$TMP/bg-gh-home.txt"; rm -f "$GH_HOME_RECORD"
GH_HOME_RECORD="$GH_HOME_RECORD" PATH="$BG/stub:$PATH" CELL_HOME="$BG/home" REPO_SLUG=acme/widget \
  WORKDIR="$BG/work" ENV_FILE= bash "$HERE/../cloud-cell-bringup.sh" --check > "$TMP/bg.out" 2>&1 || true
if [ -s "$TMP/bg-gh-home.txt" ]; then
  [ "$(cat "$TMP/bg-gh-home.txt")" = "$BG/home" ] && rc=0 || { rc=1; echo "      bringup's gh saw HOME=$(cat "$TMP/bg-gh-home.txt"), cell home is $BG/home"; }
else
  rc=1; echo "      bringup never ran gh auth status"
fi
ck "cloud-cell-bringup runs gh under \$CELL_HOME, not a keys.env HOME=" $rc
# …and with no ENV_FILE it must resolve the default UNDER $CELL_HOME, not the hard-coded
# /tmp/cell-home path it used to name — otherwise it validates and sources a file the cell never
# reads, and a stale one there would false-green the bring-up.
case "$(cat "$TMP/bg.out")" in
  *"sourced $BG/home/keys.env"*) rc=0 ;;
  *) rc=1; echo "      bringup did not source \$CELL_HOME/keys.env ($(grep -c . "$TMP/bg.out") output lines)" ;;
esac
ck "cloud-cell-bringup resolves the default keys.env under \$CELL_HOME" $rc

# ── 17) the daemon PATH never contains a shim / ~/.pi directory ──────────────────
# macOS TCC blocks LAUNCHD from reading ~/Documents, so ~/.pi/agent/shims/gh (a symlink into
# ~/Documents) is EPERM under the daemon ("Operation not permitted") even though it runs fine in
# this interactive shell — which is why the install.sh probe-by-execution reports a FALSE GREEN.
# The guard is the exclusion in add_dir(), so DRIVE THE SHIPPED PATH CODE (extracted, not
# re-implemented): put a shim FIRST on the driving PATH, render DAEMON_PATH, and assert no shim/
# ~/.pi directory survives while the real binary's directory is kept. A pre-fix add_dir fixture
# proves the scenario is real and that dropping the exclusion would fail this check.
unset -f gh pi uv tmux 2>/dev/null || true   # an exported function would shadow the stubs below
awk '/^add_dir\(\) \{/{f=1} f{ if (/^ok "daemon PATH:/) exit; print }' "$INST" > "$TMP/daemonpath.sh"
if need "$TMP/daemonpath.sh" "the daemon-PATH block is extracted from the shipped install.sh"; then
  DP="$TMP/dp"; mkdir -p "$DP/home/.pi/agent/shims" "$DP/realbin"
  # the shim lives under a ~/.pi/.../shims path (exactly the shape TCC refuses); the REAL binary
  # lives in a plain directory that matches none of the excluded patterns.
  printf '#!/bin/bash\nprintf "gh 9.9.9 (shim)\\n"\n' > "$DP/home/.pi/agent/shims/gh"
  printf '#!/bin/bash\nprintf "gh 9.9.9 (real)\\n"\n' > "$DP/realbin/gh"
  chmod +x "$DP/home/.pi/agent/shims/gh" "$DP/realbin/gh"
  DRIVE_PATH="$DP/home/.pi/agent/shims:$DP/realbin:/usr/bin:/bin"
  pre="$(HOME="$DP/home" PATH="$DRIVE_PATH" command -v gh)"
  [ "$pre" = "$DP/home/.pi/agent/shims/gh" ] && rc=0 || { rc=1; echo "      'gh' resolved to '$pre'"; }
  ck "non-vacuity: 'gh' on the driving PATH resolves through the shim" $rc
  { echo 'set -u'; cat "$TMP/daemonpath.sh"; echo 'printf "%s\\n" "$DAEMON_PATH"'; } > "$DP/drive.sh"
  bash -n "$DP/drive.sh" && rc=0 || rc=1
  ck "the daemon-PATH driver parses" $rc
  out="$(HOME="$DP/home" PATH="$DRIVE_PATH" bash "$DP/drive.sh")"
  case "$out" in *"/shims"*|*"/.pi/"*) rc=1; echo "      daemon PATH: $out";; *) rc=0;; esac
  ck "the daemon PATH contains no */shims or */.pi/* directory" $rc
  case ":$out:" in *":$DP/realbin:"*) rc=0;; *) rc=1; echo "      daemon PATH: $out";; esac
  ck "the daemon PATH keeps the real binary's directory (the shim is dropped, not the tool)" $rc
  res="$(PATH="$out" command -v gh)"
  # The base DAEMON_PATH prefix is hardcoded and may hold a real gh on a brew box, so the invariant
  # is "resolves to a REAL executable, not the shim" — asserting equality with the fixture's realbin
  # over-specifies which of two real binaries wins and false-reds a `brew install gh` box.
  case "$res" in ""|"$DP/home/.pi/agent/shims/gh") rc=1;; *) [ -x "$res" ] && rc=0 || rc=1;; esac
  ck "under the daemon PATH, gh resolves to a real (non-shim) executable" $rc
  # Non-vacuity: the PRE-FIX add_dir (no exclusion) does bake the shim dir into the PATH.
  cat > "$DP/prefix-add_dir.sh" <<'SH'
add_dir() {
  case "$1" in /*) ;; *) return 0 ;; esac
  case ":$DAEMON_PATH:" in *":$1:"*) ;; *) DAEMON_PATH="$DAEMON_PATH:$1" ;; esac
}
DAEMON_PATH="/usr/bin:/bin"
p="$(command -v gh)"; add_dir "$(cd "$(dirname "$p")" && pwd)"
printf '%s\n' "$DAEMON_PATH"
SH
  old="$(HOME="$DP/home" PATH="$DRIVE_PATH" bash "$DP/prefix-add_dir.sh")"
  case "$old" in *"/shims"*) rc=0;; *) rc=1; echo "      pre-fix PATH: $old";; esac
  ck "non-vacuity: the pre-fix add_dir really admitted the shim dir" $rc
  # A PATH entry that is a SYMLINK to the shim directory must not slip past a name-only match,
  # and must not suppress the real binary (the resolve-past loop keys off the same test).
  ln -s "$DP/home/.pi/agent/shims" "$DP/shims-link"
  LINK_PATH="$DP/shims-link:$DP/realbin:/usr/bin:/bin"
  out2="$(HOME="$DP/home" PATH="$LINK_PATH" bash "$DP/drive.sh")"
  case "$out2" in *"/shims"*|*"/.pi/"*) rc=1; echo "      symlinked-shim daemon PATH: $out2";; *) rc=0;; esac
  ck "a symlink TO the shim dir cannot enter the daemon PATH" $rc
  case ":$out2:" in *":$DP/realbin:"*) rc=0;; *) rc=1; echo "      symlinked-shim daemon PATH: $out2";; esac
  ck "a symlinked shim dir does not suppress the real binary's directory" $rc
  # An EXPORTED `gh` function must not hide the real binary's directory: `type -P` ignores functions
  # (a function is not what launchd execs), so resolution still finds realbin.
  fnout="$( unset -f gh; gh() { exit 0; }; export -f gh; HOME="$DP/home" PATH="$DRIVE_PATH" bash "$DP/drive.sh" )"
  case ":$fnout:" in *":$DP/realbin:"*) rc=0;; *) rc=1; echo "      function-perturbed daemon PATH: $fnout";; esac
  ck "an exported 'gh' function does not hide the real binary's directory" $rc
fi

# ── 18) the install-time probe EXECUTES every tool, not just resolves it ────────
# Resolving a name is not running it: a shim/wrapper directory that does NOT match the exclusion
# patterns (cmux's `cmux-cli-shims` is a real one on this box) resolves the tool to a wrapper that
# exits 127, and a resolution-only probe reports install success while every lane spawn then fails.
# Drive the SHIPPED probe block with a fixture whose `pi` resolves but cannot run.
awk '/^for bin in tmux uv pi gh; do$/{f=1} f{print} f&&/^done$/{exit}' "$INST" > "$TMP/probe.sh"
if need "$TMP/probe.sh" "the install-time probe is extracted from the shipped install.sh"; then
  PB="$TMP/probe"; mkdir -p "$PB/bin"
  for b in tmux uv gh; do printf '#!/bin/bash\nexit 0\n' > "$PB/bin/$b"; chmod +x "$PB/bin/$b"; done
  # ⛔ The driver runs under install.sh's OWN shell options (`set -euo pipefail`, line 12), not a
  # weaker `set -u`: `_p="$(… || true)"` is reached only because install.sh runs under errexit, and
  # a `set -u`-only driver cannot see the unguarded-assignment regression it exists to pin.
  { echo 'set -euo pipefail'; echo 'die() { echo "DIED: $*" >&2; exit 9; }'; echo 'warn() { echo "WARN: $*" >&2; }'; cat "$TMP/probe.sh"; } > "$PB/drive.sh"
  bash -n "$PB/drive.sh" && rc=0 || rc=1
  ck "the probe driver parses" $rc
  printf '#!/bin/bash\nexit 127\n' > "$PB/bin/pi"; chmod +x "$PB/bin/pi"
  PATH="$PB/bin:/usr/bin:/bin" DAEMON_PATH="$PB/bin" bash "$PB/drive.sh" >/dev/null 2>&1; rc=$?
  [ "$rc" = "9" ] && rc=0 || { rc=1; echo "      probe rc=$rc (expected 9 — a resolved-but-non-running pi must fail install)"; }
  ck "the probe fails install when a resolved tool cannot RUN (exit 127)" $rc
  printf '#!/bin/bash\nexit 0\n' > "$PB/bin/pi"; chmod +x "$PB/bin/pi"
  PATH="$PB/bin:/usr/bin:/bin" DAEMON_PATH="$PB/bin" bash "$PB/drive.sh" >/dev/null 2>&1; rc=$?
  [ "$rc" = "0" ] && rc=0 || { rc=1; echo "      probe rc=$rc (expected 0 when every resolved tool runs)"; }
  ck "the probe passes when every resolved tool runs" $rc
  # An EXPORTED shell function named `gh` must NOT satisfy the probe: `command -v` reports it, but a
  # function is not what launchd execs and the daemon PATH has no gh binary at all.
  PB2="$PB/bin2"; mkdir -p "$PB2"
  for b in tmux uv pi; do printf '#!/bin/bash\nexit 0\n' > "$PB2/$b"; chmod +x "$PB2/$b"; done
  ( unset -f gh pi uv tmux; gh() { exit 0; }; export -f gh; \
    PATH="$PB2:/usr/bin:/bin" DAEMON_PATH="$PB2" bash "$PB/drive.sh" ) >/dev/null 2>&1; rc=$?
  [ "$rc" = "9" ] && rc=0 || { rc=1; echo "      probe rc=$rc (expected 9 — an exported gh FUNCTION is not a daemon binary)"; }
  ck "an exported shell function does not satisfy the probe" $rc
  # A wrapper that DELEGATES by name must not pass because the AMBIENT PATH can satisfy it: the
  # probe must execute under $DAEMON_PATH, where nothing can (the false green one layer in).
  PB3="$PB/w3"; mkdir -p "$PB3/shared" "$PB3/wrap" "$PB3/real" "$PB3/base"
  for b in tmux uv gh; do printf '#!/bin/bash\nexit 0\n' > "$PB3/shared/$b"; chmod +x "$PB3/shared/$b"; done
  printf '#!/bin/bash\nexit 0\n' > "$PB3/real/pi"; chmod +x "$PB3/real/pi"
  cat > "$PB3/wrap/pi" <<'SH'
#!/bin/bash
self="$(cd "${0%/*}" && pwd)"
found=""
IFS=:
for d in $PATH; do
  d="$(cd "$d" 2>/dev/null && pwd)" || continue
  [ "$d" = "$self" ] && continue
  [ -x "$d/pi" ] && { found="$d/pi"; break; }
done
[ -n "$found" ] && exec "$found" "$@"
exit 127
SH
  chmod +x "$PB3/wrap/pi"
  ( unset -f gh pi uv tmux; \
    PATH="$PB3/shared:$PB3/wrap:$PB3/real:/usr/bin:/bin" DAEMON_PATH="$PB3/base:$PB3/shared:/usr/bin:/bin:$PB3/wrap" bash "$PB/drive.sh" ) >/dev/null 2>&1; rc=$?
  [ "$rc" = "9" ] && rc=0 || { rc=1; echo "      probe rc=$rc (expected 9 — a name-delegating wrapper must fail under the daemon PATH)"; }
  ck "a name-delegating wrapper is probed under the daemon PATH, not the ambient one" $rc
fi

# ── load gate: an agent spawn must not be piled onto a post-boot indexing storm ──
# Driven, not grep'd: a text-presence check passes against a build with the gate neutered to
# `can_spawn() { true; }` — reproduced before this version replaced it.
grep -m1 '^can_spawn() {' "$LOOP" > "$TMP/canspawn.sh"
if need "$TMP/canspawn.sh" "can_spawn() is extracted from the shipped loop"; then
  MAX_LOAD=16
  . "$TMP/canspawn.sh"
  L=0;   can_spawn && rc=0 || rc=1; ck "shipped can_spawn(): load 0 < 16 -> spawn allowed" $rc
  L=15;  can_spawn && rc=0 || rc=1; ck "shipped can_spawn(): load 15 < 16 -> spawn allowed" $rc
  L=16;  can_spawn && rc=1 || rc=0; ck "shipped can_spawn(): load 16 -> spawn held back" $rc
  L=221; can_spawn && rc=1 || rc=0; ck "shipped can_spawn(): load 221 (post-boot storm) -> held back" $rc
  L="";  can_spawn && rc=0 || rc=1; ck "shipped can_spawn(): unset load defaults to 0 (documented fail-open)" $rc
fi
# Assert each of the four spawn SITES, not a count — a count is satisfied by decoy comments,
# which is exactly how an earlier version of this check passed against a stripped build.
fixer_sites=$(grep -F "grep -c '^fix-')" "$LOOP" | grep -cF can_spawn)
merge_site=$(grep -F "grep -c '^merge-')" "$LOOP" | grep -cF can_spawn)
review_site=$(grep -cF '&& can_spawn \' "$LOOP")
[ "$fixer_sites" = "2" ] && rc=0 || rc=1
ck "both fixer spawn sites (conflict + CI-red) carry the load gate" $rc
[ "$merge_site" = "1" ] && rc=0 || rc=1
ck "the merge re-review spawn carries the load gate" $rc
[ "$review_site" = "1" ] && rc=0 || rc=1
ck "the review-fix spawn carries the load gate" $rc
grep -q 'gh pr merge "\$PR" --repo "\$OR" --squash >>"\$LOG"' "$LOOP" && rc=0 || rc=1
ck "the cheap merge path stays ungated" $rc

echo
echo "==> $pass passed, $fail failed"
[ "$fail" -eq 0 ]
