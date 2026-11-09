#!/usr/bin/env bash
# repo-slug.test.sh — `REPO` IS SET ONCE PER BOX AND READ THROUGH ONE RESOLVER (this PR).
#
# THE MEASURED DEFECT. `OR` got a single source in #2040 (`repo-slug.sh`'s `derive_or`, called once by
# `orch-loop.sh`). `REPO` — the CHECKOUT PATH every script grades — got none, so each script carried a
# private default and THREE of them were wrong on every box but the one they were written on:
#     report.sh               REPO="${REPO:-$HOME/eldato/tortoise}"  ONE DEVELOPER'S HOME DIRECTORY
#     deploy-crossbox.sh      REPO="${REPO:-/tmp/cell-ai}"          a CELL path, wrong on every laptop
#     pi-reap-worktrees.sh    REPO="${REPO:-$PWD}"                  under launchd `$PWD` is `/`, a REAL
#                             directory that is not a repo, so the pass died several probes later and
#                             far from the cause as "not a git repository: /"
# A wrong-but-plausible path is WORSE than a refusal: the report reads "nothing to report" on a busy
# box, and the reaper looks like it found no worktrees. So the property this suite pins is a REFUSAL,
# not a better guess.
#
# WHAT IS PINNED — behaviour, not prose:
#   A  `resolve_repo`'s contract: absent / set-but-empty / nonexistent / a plain `mkdir` directory /
#      `/` (the launchd `$PWD` shape) all REFUSE with rc 2, an EMPTY STDOUT (a caller must never be
#      able to parse a message as a path) and a message naming BOTH supported ways to set REPO; a real
#      checkout resolves to its canonicalized path; a SUBDIRECTORY is returned as named (never
#      silently widened to the toplevel); a symlinked checkout is ONE path. Plus the git-env scrub:
#      an ambient `GIT_DIR`/`GIT_WORK_TREE` cannot forge a checkout — with the premise that raw
#      `git -C` DOES accept that forgery asserted alongside, so the arm cannot pass vacuously.
#   A′ the DERIVATION arm (`$REPO_CANDIDATES`): a candidate is used only if it PROVES itself, the value
#      derived is ANNOUNCED, two candidates that both prove are REFUSED by name, and the candidate
#      list is NEWLINE-delimited so a checkout whose path contains a SPACE survives transport (it
#      used to be word-split, which refused a box standing in a real checkout — #3833 review F1).
#   B  the three call sites resolve through it: report.sh, pi-reap-worktrees.sh (both the `--repo` arm
#      AND the box's inherited `$REPO`) and deploy-crossbox.sh each REFUSE a bogus/absent repo in
#      their own loud words, none falls back to `$HOME/eldato/tortoise`, `/tmp/cell-ai` or `$PWD`, and
#      report.sh still exits 0 read-only on a real fixture (the property that made it safe to run
#      while the loop is working is preserved, not traded away).
#   M  `--mutation-proof`: the anti-vacuity gate. Six mutations are applied to a THROWAWAY copy of
#      this tree and each must make the arms above go RED. A suite that stays green when the resolver
#      is reverted is a finding against the suite, so the proof ships with it.
#
# HERMETIC: every repo is a throwaway `git init` under a temp dir, no network, no gh, no HOME writes.
# Bash 3.2 (macOS) and 5.2 (cells) both: no `mapfile`, no `${x^^}`, no `timeout`, no `setsid`.
# Run: bash repo-slug.test.sh
#      bash repo-slug.test.sh --mutation-proof    (adds ~4x the runtime; run it when touching this)
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$HERE/repo-slug.sh"
REPORT="$HERE/report.sh"
REAPER="$HERE/../pi-reap-worktrees.sh"
CROSSBOX="$HERE/../deploy-crossbox.sh"
SLUGDIR="$HERE/../"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ❌ $1"; }
ck()  { if [ "$2" -eq 0 ]; then ok "$1"; else bad "$1"; fi; }

# ⛔ GIT IS THE INSTRUMENT, NOT A CONVENIENCE. Every arm here asks "is this a checkout"; a host without
# git cannot answer, and a suite that reports 0 failures after measuring nothing is the inert-gate shape
# this repo keeps closing. Refuse loudly instead.
command -v git >/dev/null 2>&1 || { echo "repo-slug.test.sh: git is required (this suite proves a checkout claim)" >&2; exit 2; }
[ -f "$LIB" ] || { echo "repo-slug.test.sh: $LIB is missing — nothing to test" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/repo-slug-test.XXXXXX")" || exit 2
cleanup() { chmod -R u+rwX "$T" 2>/dev/null; rm -rf "$T" 2>/dev/null; }
trap cleanup EXIT INT TERM

REAL="$T/real"; PLAIN="$T/plain"; NOPE="$T/nope-does-not-exist"; LINK="$T/one-checkout"
# ⛔ A CHECKOUT UNDER A DIRECTORY WITH A SPACE IN ITS NAME (fixture for A16). This repo calls that
# shape ORDINARY, and it is the one the space-joined candidate list could not represent.
SPACED="$T/space dir/repo"
mkdir -p "$REAL/sub" "$PLAIN" "$SPACED"
git init -q "$REAL" || { echo "repo-slug.test.sh: cannot git init a fixture" >&2; exit 2; }
git init -q "$SPACED" || { echo "repo-slug.test.sh: cannot git init the space-path fixture" >&2; exit 2; }
ln -s "$REAL" "$LINK"
canon() { ( cd "$1" 2>/dev/null && pwd -P ); }
# The ONE transport for a candidate list: one path per LINE, so a space is part of a path, not a
# separator (#3833 review F1). Every arm that offers two candidates composes them through this.
one_per_line() { printf '%s\n' "$@"; }

# The runner: a separate process, so `resolve_repo` runs in the shell that SOURCED it (the shipped
# calling convention) and the caller's own `REPO` cannot leak into the next arm.
cat > "$T/rr.sh" <<'SH'
#!/usr/bin/env bash
. "$1" || exit 99
resolve_repo
SH
RR_ERR="$T/err"; : > "$RR_ERR"
rr_rc=0; rr_out=""
rr() { # rr <env words...> — REPO is scrubbed first, so an arm sets it explicitly or not at all
  rr_out="$(env -u REPO "$@" bash "$T/rr.sh" "$LIB" 2>"$RR_ERR")"; rr_rc=$?
}
err_has() { grep -q -- "$1" "$RR_ERR" 2>/dev/null; }
one_line() { [ "$(printf '%s\n' "$1" | wc -l | tr -d ' ')" = 1 ]; }

echo "== A. resolve_repo — the ONE resolver: a refusal, never a plausible guess =="

# A1 ABSENT. rc 2 (the configuration-error code `derive_or` already uses), nothing on stdout, and the
# message names BOTH supported surfaces — an operator on a box that never set REPO is exactly who reads
# it, and a message that only says "unset" leaves them to invent a third way.
rr
{ [ "$rr_rc" -eq 2 ] && [ -z "$rr_out" ] && err_has 'REPO is unset' && err_has 'LaunchAgents' && err_has 'keys.env'; }
ck "A1  REPO unset: rc 2, EMPTY stdout, names both supported ways to set it (rc=$rr_rc)" $?

# A2 SET-BUT-EMPTY. A blank line in a plist or a keys.env is an operator typo, not "nothing was set" —
# treating it as unset is how a typo becomes a silent default.
rr REPO=
{ [ "$rr_rc" -eq 2 ] && [ -z "$rr_out" ] && err_has 'REPO is unset'; }
ck "A2  REPO set-but-empty is a refusal, not a licence to fall back (rc=$rr_rc)" $?

# A3 NONEXISTENT — the value the operator named is quoted back, so the message is actionable.
rr REPO="$NOPE"
{ [ "$rr_rc" -eq 2 ] && [ -z "$rr_out" ] && err_has "$NOPE" && err_has 'not a git checkout'; }
ck "A3  REPO=nonexistent refuses by VALUE (rc=$rr_rc)" $?

# A4 A PLAIN `mkdir` DIRECTORY. This is the arm that separates a CHECK from a guess: the path exists,
# so a resolver that only tested `-d` would accept it and every later `git -C` would fail somewhere else.
rr REPO="$PLAIN"
{ [ "$rr_rc" -eq 2 ] && [ -z "$rr_out" ] && err_has 'not a git checkout'; }
ck "A4  REPO is an existing directory but NOT a checkout: refused (rc=$rr_rc)" $?

# A5 `/` — the launchd `$PWD` shape, verbatim. `$PWD` under launchd IS `/`: a real directory, not a
# repo. This is the case that produced "not a git repository: /" far from its cause.
rr REPO=/
{ [ "$rr_rc" -eq 2 ] && [ -z "$rr_out" ] && err_has 'not a git checkout'; }
ck "A5  REPO=/ (the launchd \$PWD shape) is refused AT the resolver, not later (rc=$rr_rc)" $?

# A6 A REAL CHECKOUT: rc 0, exactly one line of stdout, the canonicalized path.
RREAL="$(canon "$REAL")"
rr REPO="$REAL"
{ [ "$rr_rc" -eq 0 ] && one_line "$rr_out" && [ "$rr_out" = "$RREAL" ]; }
ck "A6  a real checkout resolves to one canonical path ($rr_out)" $?

# A7 A SUBDIRECTORY IS RETURNED AS NAMED. Each caller validates what it uses, and a resolver that
# silently widened `$REPO` to the toplevel would rewrite an operator's value behind their back.
rr REPO="$REAL/sub"
{ [ "$rr_rc" -eq 0 ] && [ "$rr_out" = "$(canon "$REAL/sub")" ]; }
# ⛔ `$?` IS CAPTURED BEFORE ANY SUBSTITUTION (#3054 review, P1). Word expansions happen BEFORE the
# command runs and left to right, so a `$(…)` in the message runs FIRST and leaves ITS status in `$?`.
# `ck "… $(…)" $?` therefore reported the substitution's 0 and this arm passed UNCONDITIONALLY.
_a7_st=$?
ck "A7  a subdirectory is kept, never widened to the toplevel ($(basename "${rr_out:-}"))" "$_a7_st"

# A8 A SYMLINKED CHECKOUT IS ONE PATH (the same reason refresh-candidates.sh stores `pwd -P`).
rr REPO="$LINK"
{ [ "$rr_rc" -eq 0 ] && [ "$rr_out" = "$RREAL" ]; }
ck "A8  a symlinked checkout canonicalizes to the one path ($rr_out)" $?

# A9 THE GIT ENV IS SCRUBBED. `GIT_DIR`/`GIT_WORK_TREE` OUTRANK `-C`, so an ambient `GIT_DIR` makes
# `rev-parse --show-toplevel` succeed for a directory that is not a checkout — the validation would
# certify the wrong thing. The PREMISE is asserted too: if raw `git -C` ever stopped accepting that
# forgery, A9 would pass for the wrong reason and this whole arm would be inert.
forged="$(env GIT_DIR="$REAL/.git" git -C "$PLAIN" rev-parse --show-toplevel 2>/dev/null)"; forged_rc=$?
[ "$forged_rc" -eq 0 ] && [ -n "$forged" ]
ck "A9p premise: raw 'git -C' IS fooled by an ambient GIT_DIR (rc=$forged_rc) — so A9 is a real test" $?
rr REPO="$PLAIN" GIT_DIR="$REAL/.git"
{ [ "$rr_rc" -eq 2 ] && err_has 'not a git checkout'; }
ck "A9  an ambient GIT_DIR cannot forge a checkout past the resolver (rc=$rr_rc)" $?
rr REPO="$PLAIN" GIT_WORK_TREE="$REAL"
{ [ "$rr_rc" -eq 2 ] && err_has 'not a git checkout'; }
ck "A9b an ambient GIT_WORK_TREE cannot forge one either (rc=$rr_rc)" $?

echo
echo "== A′. the DERIVATION arm: a candidate is used only if it PROVES itself (agent-infra#1974) =="

# ⛔ THE PROPERTY, NOT A NICER DEFAULT. #1974's resolution order is `environment → derived-with-proof
# → refuse`, and the middle arm is what these arms pin: a plain directory, a path that does not exist
# and a checkout of the WRONG repo are all refused, so "derives" is not a synonym for "guesses".

# A10 ONE candidate that proves: used, canonicalized, ONE line of stdout, and SAID OUT LOUD on stderr
# (a value the operator did not type must be visible in the log the pass writes).
rr -u REPO_CANDIDATES -u OR REPO_CANDIDATES="$REAL"
{ [ "$rr_rc" -eq 0 ] && one_line "$rr_out" && [ "$rr_out" = "$RREAL" ] && err_has 'REPO is unset' && err_has 'using'; }
ck "A10 a candidate that proves is DERIVED and named, never silent (rc=$rr_rc -> $rr_out)" $?

# A11 A DIRECTORY THAT EXISTS BUT IS NOT A CHECKOUT IS NOT A CANDIDATE. This is the `$PWD` defect
# verbatim: `/` (and any plain directory) exists, so a `-d` test alone would adopt it.
# ⛔ "NOT ADOPTED" MEANS NO ANNOUNCEMENT AND AN EMPTY STDOUT — not merely rc 2 (fresh-context review of
# #3833, F2 — measured). Asserting only `rc=2 + empty stdout + 'REPO is unset'` left this arm GREEN with
# PROOF 1 (`rev-parse --show-toplevel`) deleted, because the resolver then ADOPTED the plain directory,
# SAID so (“using /tmp/…/tplain”), and the declared-value validation refused it afterwards: same three
# observables, opposite behaviour. The discriminator is the absence of the announcement, so it is
# asserted here, with A10 keeping the positive control (a real checkout DOES announce).
rr -u REPO_CANDIDATES -u OR REPO_CANDIDATES="$(one_per_line "$NOPE" "$PLAIN")"
{ [ "$rr_rc" -eq 2 ] && [ -z "$rr_out" ] && err_has 'REPO is unset' && ! err_has 'using ' \
  && ! err_has 'is not a git checkout'; }
ck "A11 a non-checkout candidate (a plain dir, a missing path) is NOT adopted, and nothing is announced as derived (rc=$rr_rc)" $?

# A12 THE SAME CHECKOUT OFFERED TWICE IS ONE CANDIDATE (raw path + a symlink to it). Keyed on the raw
# string this was two "hits" and refused a box that had one checkout — a false block, which matters
# even in a fail-closed arm.
rr -u REPO_CANDIDATES -u OR REPO_CANDIDATES="$(one_per_line "$REAL" "$LINK")"
{ [ "$rr_rc" -eq 0 ] && [ "$rr_out" = "$RREAL" ]; }
ck "A12 one checkout reached by two spellings is ONE candidate, not a coin toss (rc=$rr_rc)" $?

# A13 TWO DISTINCT CHECKOUTS THAT BOTH PROVE: refused, and BOTH are named so the operator can pick.
REAL2="$T/real2"; git init -q "$REAL2" || bad "A13 fixture could not be created"
rr -u REPO_CANDIDATES -u OR REPO_CANDIDATES="$(one_per_line "$REAL" "$REAL2")"
{ [ "$rr_rc" -eq 2 ] && [ -z "$rr_out" ] && err_has "$RREAL" && err_has "$(canon "$REAL2")"; }
ck "A13 two checkouts that both prove are REFUSED, with both named (rc=$rr_rc)" $?

# A14 PROOF 2 — a DECLARED queue target decides which checkout this box may adopt (#1901). Without
# it, `$PWD` in the wrong checkout silently queues another repo's work.
git -C "$REAL" remote add origin https://github.com/acme/widget.git 2>/dev/null || true
rr -u REPO_CANDIDATES -u OR REPO_CANDIDATES="$REAL" OR="acme/widget"
{ [ "$rr_rc" -eq 0 ] && [ "$rr_out" = "$RREAL" ]; }
ck "A14 a candidate whose origin NAMES the declared \$OR is adopted (rc=$rr_rc)" $?
rr -u REPO_CANDIDATES -u OR REPO_CANDIDATES="$REAL" OR="acme/gadget"
{ [ "$rr_rc" -eq 2 ] && [ -z "$rr_out" ] && err_has 'REPO is unset'; }
ck "A14b a candidate whose origin names ANOTHER repo is refused, not adopted (rc=$rr_rc)" $?

# A14c THE COMPARISON IS FOLDED, LIKE EVERY OTHER SLUG TEST IN THIS FILE (fresh-context review of
# #3833, F2). GitHub slugs are CASE-INSENSITIVE — this file states it and `repo_identity_fold` exists
# for it — so a raw `=` between the candidate's origin and a `keys.env` pin differing only in letter
# case refused a checkout that is CORRECT. The premise is asserted alongside: the two spellings really
# do differ as strings, so the arm cannot pass on a fixture that happens to match.
_pin="acme/widget"
_pin_up="Acme/Widget"
[ "$_pin_up" != "$_pin" ] && [ "$(printf '%s' "$_pin_up" | tr '[:upper:]' '[:lower:]')" = "$_pin" ]
ck "A14c premise: the two spellings differ ONLY in case, and both fold to the pinned slug" $?
git -C "$REAL" remote set-url origin https://github.com/Acme/Widget.git 2>/dev/null || true
rr -u REPO_CANDIDATES -u OR REPO_CANDIDATES="$REAL" OR="$_pin"
{ [ "$rr_rc" -eq 0 ] && [ "$rr_out" = "$RREAL" ]; }
ck "A14c an origin differing only in CASE from the pinned \$OR still names it (rc=$rr_rc)" $?
# ...and the FOLD must not widen the rule: a different repo at a different case is still not this one.
rr -u REPO_CANDIDATES -u OR REPO_CANDIDATES="$REAL" OR="acme/gadget"
{ [ "$rr_rc" -eq 2 ] && [ -z "$rr_out" ]; }
ck "A14d folding the case does NOT admit a different repo (rc=$rr_rc)" $?
git -C "$REAL" remote set-url origin https://github.com/acme/widget.git 2>/dev/null || true

# A15 THE #1974 RULE ITSELF (point 3): a DECLARED value is never replaced by a derived one. A bogus
# `$REPO` plus a perfectly good candidate is still the operator's refusal, by the value they named.
rr -u REPO_CANDIDATES -u OR REPO="$NOPE" REPO_CANDIDATES="$REAL"
{ [ "$rr_rc" -eq 2 ] && [ -z "$rr_out" ] && err_has "$NOPE" && err_has 'not a git checkout'; }
ck "A15 a DECLARED bogus REPO is refused by value, never swapped for a good candidate (rc=$rr_rc)" $?

# A16 A CHECKOUT WHOSE PATH CONTAINS A SPACE IS DERIVED, NOT SPLIT (#3833 review F1 — a REGRESSION).
# The candidate list used to be iterated unquoted (`for _cand in $REPO_CANDIDATES`), so
# `worktree-hygiene-sweep.sh`'s `"$TORTOISE_REPO $PWD"` turned `/Volumes/My Passport/agent-infra` into
# TWO candidates, neither proved, and the pass refused while the operator stood in a real checkout. The
# old `REPO="$PWD"` was quoted and worked, so that is a regression, not a limitation.
# The premise is asserted alongside: the candidate really does contain a space, so the arm cannot pass
# on a fixture that silently lost it.
case "$SPACED" in *' '*) true ;; *) false ;; esac
ck "A16 premise: the fixture checkout's path contains a SPACE ($SPACED)" $?
rr -u REPO_CANDIDATES -u OR REPO_CANDIDATES="$(one_per_line "$NOPE" "$SPACED")"
{ [ "$rr_rc" -eq 0 ] && [ "$rr_out" = "$(canon "$SPACED")" ] && err_has 'using'; }
ck "A16 a checkout whose path contains a SPACE is derived whole, never word-split (rc=$rr_rc -> $rr_out)" $?

echo
echo "== B. the three wrong call sites resolve through it, and still refuse loudly =="

# report.sh needs a harness-shaped `$O` and REAL is a checkout (it was `$HOME/eldato/tortoise` before,
# which meant nothing ever checked that the path existed at all).
RO="$T/report-o"; mkdir -p "$RO/state" "$RO/logs"; printf '1\n' > "$RO/candidates.txt"

if [ -f "$REPORT" ]; then
  # B1 ABSENT: the old default is GONE, and nothing plausible is substituted for it.
  rout="$(env -u REPO O="$RO" bash "$REPORT" 1 2>&1)"; rrc=$?
  { [ "$rrc" -eq 2 ] && grep -q 'REPO is unset' <<<"$rout" && ! grep -q 'eldato/tortoise' <<<"$rout"; }
  ck "B1  report.sh, REPO unset: rc 2, refuses — never \$HOME/eldato/tortoise (rc=$rrc)" $?
  # B2 BOGUS: refused by value. (The grep is for the OLD DEFAULT PATH, not the word `eldato` — the
  # refusal's own remedy names `com.eldato.orchestrator-loop.plist`, so the loose form would red a
  # correct run: measured while writing this arm.)
  rout="$(env REPO="$NOPE" O="$RO" bash "$REPORT" 1 2>&1)"; rrc=$?
  { [ "$rrc" -eq 2 ] && grep -q 'not a git checkout' <<<"$rout" && ! grep -q 'eldato/tortoise' <<<"$rout"; }
  ck "B2  report.sh, REPO bogus: rc 2, names it (rc=$rrc)" $?
  # B3 AND THE READ-ONLY CONTRACT SURVIVES: on a real checkout it still exits 0 while the loop works.
  rout="$(env REPO="$REAL" O="$RO" bash "$REPORT" 1 2>&1)"; rrc=$?
  { [ "$rrc" -eq 0 ] && grep -q 'sessions:' <<<"$rout"; }
  ck "B3  report.sh on a real checkout still runs read-only, rc 0 (rc=$rrc)" $?
else
  bad "B1-B3 report.sh is shipped (absent: $REPORT)"
fi

if [ -f "$REAPER" ]; then
  # B4 ABSENT, cwd=/. `$PWD` here is `/` — the launchd shape. The OLD code took it, canonicalized it
  # (it IS a directory) and died later with "not a git repository: /"; this arm fails if that message
  # is what we get, so it cannot pass by the refusal merely happening somewhere.
  reaper_out="$(cd / && env -u REPO -u AGENT_INFRA_PATH REAP_WT_REPO_SLUG_LIB="$LIB" bash "$REAPER" --list 2>&1)"; reaper_rc=$?
  { [ "$reaper_rc" -eq 2 ] && grep -q 'REPO is unset' <<<"$reaper_out" \
    && ! grep -q 'not a git repository' <<<"$reaper_out"; }
  ck "B4  pi-reap-worktrees.sh, REPO unset with PWD=/ (launchd): REFUSES, no \$PWD default (rc=$reaper_rc)" $?
  # B5 THE BOX'S REPO. The documented fallback is the inherited environment value, so a bogus one must
  # be refused BY VALUE — this is the arm that reddens if a top-level `REPO=""` clobbers the operator's
  # value before the resolver reads it (measured: that assignment made this answer "REPO is unset").
  reaper_out="$(env -u REPO -u AGENT_INFRA_PATH REPO="$NOPE" REAP_WT_REPO_SLUG_LIB="$LIB" bash "$REAPER" --list 2>&1)"; reaper_rc=$?
  { [ "$reaper_rc" -eq 2 ] && grep -q "$NOPE" <<<"$reaper_out" && grep -q 'not a git checkout' <<<"$reaper_out"; }
  ck "B5  pi-reap-worktrees.sh, a bogus BOX \$REPO is refused by value (rc=$reaper_rc)" $?
  # B6 --repo BOGUS. The flag arm goes through the SAME resolver (a second path would be a second source).
  reaper_out="$(env -u REPO -u AGENT_INFRA_PATH REAP_WT_REPO_SLUG_LIB="$LIB" bash "$REAPER" --repo "$PLAIN" --list 2>&1)"; reaper_rc=$?
  { [ "$reaper_rc" -eq 2 ] && grep -q 'not a git checkout' <<<"$reaper_out"; }
  ck "B6  pi-reap-worktrees.sh --repo <non-checkout> is refused by the same resolver (rc=$reaper_rc)" $?
  # B7 AND IT STILL WORKS: a named real checkout lists its worktrees, rc 0. (Compared against the
  # CANONICAL path: macOS `mktemp` hands out `/var/...` while `pwd -P` — and therefore the reaper's own
  # `$REPO_CANON` — says `/private/var/...`, so the raw `$T` prefix would never match.)
  reaper_out="$(env -u REPO -u AGENT_INFRA_PATH REAP_WT_REPO_SLUG_LIB="$LIB" bash "$REAPER" --repo "$REAL" --list 2>&1)"; reaper_rc=$?
  { [ "$reaper_rc" -eq 0 ] && grep -q "$RREAL" <<<"$reaper_out"; }
  ck "B7  pi-reap-worktrees.sh --repo <real checkout> still lists, rc 0 (rc=$reaper_rc)" $?
else
  bad "B4-B7 pi-reap-worktrees.sh is shipped (absent: $REAPER)"
fi

if [ -f "$CROSSBOX" ]; then
  # A CELL-SHAPED AI: deploy-crossbox.sh sources the resolver from the cell's OWN harness copy, so the
  # fixture carries `scripts/orchestrator-harness/repo-slug.sh` and nothing else it needs to get that far.
  CELL="$T/cell"; mkdir -p "$CELL/cell-ai/scripts/orchestrator-harness" "$CELL/cell-home"
  cp "$LIB" "$CELL/cell-ai/scripts/orchestrator-harness/repo-slug.sh"
  cbrun() { # cbrun <env words...>
    cb_out="$(env AI="$CELL/cell-ai" CELL_HOME="$CELL/cell-home" "$@" bash "$CROSSBOX" 2>&1)"; cb_rc=$?
  }
  cbrun REPO="$NOPE"
  { [ "$cb_rc" -eq 2 ] && grep -q "$NOPE" <<<"$cb_out" && grep -q 'not a git checkout' <<<"$cb_out"; }
  ck "B8  deploy-crossbox.sh refuses a bogus REPO by value, never /tmp/cell-ai (rc=$cb_rc)" $?
  # A CELL WHOSE HARNESS PREDATES THE RESOLVER: refused BY NAME. The alternative — falling back to a
  # path default — is the defect, so a stale cell must stop the deploy rather than guess.
  rm -f "$CELL/cell-ai/scripts/orchestrator-harness/repo-slug.sh"
  cbrun REPO="$REAL"
  { [ "$cb_rc" -eq 1 ] && grep -q 'repo-slug.sh missing' <<<"$cb_out"; }
  ck "B9  deploy-crossbox.sh: a cell with no repo-slug.sh dies BY NAME instead of guessing (rc=$cb_rc)" $?
  # ⛔ THE SHAPE EVERY EXISTING CELL IS IN AT MERGE TIME (#3054 review, P1-2): `repo-slug.sh` PRESENT
  # but WITHOUT `resolve_repo`. `$H` is `$AI/scripts/orchestrator-harness` — INSIDE the clone step 2
  # fast-forwards — so refusing here refuses before the one step that supplies the resolver, and the
  # remedy the old message printed (`deploy-harness.sh --o $O`) re-seeds `$O` FROM `$H`, so it cannot
  # put the resolver INTO `$H`. It must be DEFERRED, and the run must reach the fast-forward instead.
  # `tmux` IS STUBBED because the script kills the `orch` session — a test must never reach a live one
  # — and the fixture is deliberately not a git repo, so the run stops at `git fetch` (before any cp).
  mkdir -p "$CELL/bin"
  printf '#!/bin/bash\nexit 0\n' > "$CELL/bin/tmux"; chmod +x "$CELL/bin/tmux"
  printf '#!/bin/bash\nrepo_slug_from_remote() { :; }\n' > "$CELL/cell-ai/scripts/orchestrator-harness/repo-slug.sh"
  cbrun PATH="$CELL/bin:$PATH" REPO="$REAL"
  { [ "$cb_rc" -ne 0 ] && ! grep -q 'resolve_repo' <<<"$cb_out" && grep -q 'git fetch failed' <<<"$cb_out"; }
  ck "B10 deploy-crossbox.sh: a STALE harness is DEFERRED, not refused — it reaches the fast-forward (rc=$cb_rc)" $?
  # ⛔ AND THE ONE CASE THAT CAN NEVER WORK IS REFUSED *BEFORE* THE CONTROLLER IS STOPPED (#3054 review,
  # P2). An UNSET `$REPO` on a stale harness cannot succeed: the fast-forward supplies the resolver and
  # the resolver then refuses an unset REPO — so the controller would be stopped and the run would die
  # with the cell's loop DOWN. `tmux` RECORDS its verbs, so the arm can see that nothing was killed;
  # asserting only the exit code would pass on a run that stopped the loop first and refused second.
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s"\nexit 0\n' "$CELL/tmux.verbs" > "$CELL/bin/tmux"; chmod +x "$CELL/bin/tmux"
  # ⛔ THE RECORD FILE IS CREATED FIRST: an ABSENT file would satisfy `[ ! -s ]` and the arm would pass
  # without ever proving that tmux was not asked to do anything.
  : > "$CELL/tmux.verbs"
  cb_out="$(cd / && env -u REPO AI="$CELL/cell-ai" CELL_HOME="$CELL/cell-home" PATH="$CELL/bin:$PATH" bash "$CROSSBOX" 2>&1)"; cb_rc=$?
  { [ "$cb_rc" -ne 0 ] && grep -q 'REPO is unset' <<<"$cb_out" && [ ! -s "$CELL/tmux.verbs" ]; } && rc13=0 || rc13=1
  ck "B13 deploy-crossbox.sh: REPO unset on a STALE harness refuses BEFORE killing the controller (rc=$cb_rc, tmux verbs=$(wc -l < "$CELL/tmux.verbs" 2>/dev/null || echo 0))" "$rc13"
  # ⛔ AND A WRONG `$REPO` ON THAT SAME STALE HARNESS IS THE NAMED RESIDUAL, pinned so it cannot change
  # silently: it is judgment the deferred pass owes, so the controller IS stopped and the refusal comes
  # after the fast-forward. Pinned positively (the run reaches the fetch/ff rather than dying in the
  # pre-flight) so that a LATER fix moving the refusal earlier reds here and the disclosure is updated.
  : > "$CELL/tmux.verbs"
  cb_out="$(cd / && env REPO="$NOPE" AI="$CELL/cell-ai" CELL_HOME="$CELL/cell-home" PATH="$CELL/bin:$PATH" bash "$CROSSBOX" 2>&1)"; cb_rc=$?
  { [ "$cb_rc" -ne 0 ] && ! grep -q 'predates resolve_repo' <<<"$cb_out" && grep -q 'git fetch failed' <<<"$cb_out"; } && rc14=0 || rc14=1
  ck "B14 deploy-crossbox.sh: a WRONG REPO on a stale harness is DEFERRED (the disclosed residual), not judged early (rc=$cb_rc)" "$rc14"
  : > "$CELL/tmux.verbs"
  # ⛔ `--repo PATH` IS THE ONE INPUT AN SSH CALLER HAS ON A CELL (#3054 review, P1-2): the two
  # documented surfaces reach the CONTROLLER, not the pushing shell. It is still PROVEN — but only if
  # it actually REACHES the resolver, so both directions are pinned, with `REPO` UNSET (`env -u`) so
  # the value can only have come from the flag.
  cp "$LIB" "$CELL/cell-ai/scripts/orchestrator-harness/repo-slug.sh"
  cb_out="$(env -u REPO AI="$CELL/cell-ai" CELL_HOME="$CELL/cell-home" PATH="$CELL/bin:$PATH" \
    bash "$CROSSBOX" --repo "$NOPE" 2>&1)"; cb_rc=$?
  { [ "$cb_rc" -eq 2 ] && grep -q "$NOPE" <<<"$cb_out"; }
  ck "B11 deploy-crossbox.sh: --repo <bogus> is refused BY VALUE with REPO unset (rc=$cb_rc)" $?
  cb_out="$(env -u REPO AI="$CELL/cell-ai" CELL_HOME="$CELL/cell-home" PATH="$CELL/bin:$PATH" \
    bash "$CROSSBOX" --repo "$REAL" 2>&1)"; cb_rc=$?
  { [ "$cb_rc" -ne 0 ] && ! grep -q 'REPO is unset' <<<"$cb_out" && grep -q 'git fetch failed' <<<"$cb_out"; }
  ck "B12 deploy-crossbox.sh: --repo <real checkout> is ACCEPTED with REPO unset — it reaches the fast-forward (rc=$cb_rc)" $?
  rm -rf "$CELL/bin" $?
else
  bad "B8-B9 deploy-crossbox.sh is shipped (absent: $CROSSBOX)"
fi

# ── M. THE ANTI-VACUITY GATE ────────────────────────────────────────────────────────────────────
# Every arm above passes on the shipped tree. That is only evidence if the arms can FAIL, so each
# mutation reverts a specific piece of this change in a THROWAWAY copy and this suite must go red
# there. `RR_TEST_NO_MUT=1` stops the copy from recursing into its own proof run.
if [ "${1:-}" = "--mutation-proof" ] && [ "${RR_TEST_NO_MUT:-}" != 1 ]; then
  echo
  echo "== M. mutation proof — each revert must make the arms above go RED =="
  # python3 is only needed to edit a copy precisely; a missing interpreter must not turn the proof
  # into a silent pass, so it is required here rather than degraded around.
  command -v python3 >/dev/null 2>&1 || { bad "M  python3 is required for --mutation-proof"; }
  mut_edit() { # mut_edit <file> <old> <new> — exactly-one occurrence, or the proof is invalid
    python3 -c '
import sys
p, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read()
if s.count(old) != 1:
    sys.exit("mutation target appears %d times, not 1" % s.count(old))
open(p, "w").write(s.replace(old, new))
' "$1" "$2" "$3"
  }
  mut_run() { # mut_run <name> <substring that must appear in a red arm>
    mut_name="$1"; mut_expect="$2"
    mut_out="$(env RR_TEST_NO_MUT=1 bash "$MUTDIR/orchestrator-harness/repo-slug.test.sh" 2>&1)"; mut_rc=$?
    mut_red="$(printf '%s\n' "$mut_out" | grep '❌' | head -3)"
    { [ "$mut_rc" -ne 0 ] && [ -n "$mut_red" ] && grep -q -- "$mut_expect" <<<"$mut_red"; }
    # ⛔ CAPTURE THE VERDICT FIRST — see A7 (#3054 review, P1). Passing `$?` beside a `$(…)` in the
    # message made the substitution's status the verdict, so M1–M3 passed whether or not the mutation
    # reddened anything. This is the anti-vacuity gate; an inert one is worse than none.
    mut_st=$?
    ck "M $mut_name REDDENS (rc=$mut_rc): $(printf '%s' "$mut_red" | head -1 | sed 's/^ *//')" "$mut_st"
  }
  mut_copy() { rm -rf "$T/mut"; mkdir -p "$T/mut"; cp -a "${SLUGDIR}." "$T/mut/"; MUTDIR="$T/mut"; }

  # M1 — `resolve_repo` reverted to the AD-HOC behaviour it replaced: no validation, a silent `$PWD`
  # fallback. Appended, so bash's last-definition-wins overrides the shipped body exactly as an
  # operator's edited copy would. This is the mutation the whole PR is about.
  mut_copy
  printf '\nresolve_repo() { printf "%%s\\n" "${REPO:-$PWD}"; }\n' >> "$MUTDIR/orchestrator-harness/repo-slug.sh"
  mut_run "M1 resolve_repo reverted to \${REPO:-\$PWD} (no validation, silent fallback)" "REPO unset: rc 2"

  # M2 — report.sh reverted to ONE DEVELOPER'S HOME DIRECTORY.
  mut_copy
  mut_edit "$MUTDIR/orchestrator-harness/report.sh" 'REPO="$(resolve_repo)" || exit $?' 'REPO="${REPO:-$HOME/eldato/tortoise}"'
  mut_run "M2 report.sh reverted to \$HOME/eldato/tortoise" "report.sh, REPO unset"

  # M3 — the reaper's cleared `REPO`: re-introduced, the box's value is clobbered before the resolver
  # sees it, so a bogus env REPO answers "REPO is unset" and the fallback is documented but dead.
  mut_copy
  mut_edit "$MUTDIR/pi-reap-worktrees.sh" 'REPO="${REPO:-}"' 'REPO=""'
  mut_run "M3 reaper clears \$REPO again (the box fallback goes dead)" "bogus BOX"

  # M4 — THE GATE ITSELF: a future caller that rolls its own answer must fail, so a private path
  # default is planted in `scripts/` and `check-single-source.sh` must refuse it. This is the coupling
  # between "the behaviour is right today" and "it cannot silently drift tomorrow".
  mut_copy
  printf 'REPO="${REPO:-$PWD}"\n' >> "$MUTDIR/pi-reap-worktrees.sh"
  mut_out="$(bash "$MUTDIR/orchestrator-harness/check-single-source.sh" 2>&1)"; mut_rc=$?
  mut_red="$(printf '%s\n' "$mut_out" | grep -i 'PRIVATE' | head -2)"
  { [ "$mut_rc" -eq 1 ] && [ -n "$mut_red" ]; }
  m4_st=$?   # captured before the `$(…)` below — see A7 (#3054 review, P1)
  ck "M4 a planted private REPO default in scripts/ reddens check-single-source.sh (rc=$mut_rc): $(printf '%s' "$mut_red" | head -1 | cut -c1-100)" "$m4_st"

  # M5 — THE SAME GATE, THE SPELLINGS IT USED TO MISS (#3054 review, P1): a default spelled as
  # ANOTHER VARIABLE (`$AI` — which IS `/tmp/cell-ai` through the default deploy-crossbox.sh used to
  # carry, i.e. this defect one variable over) and as a COMMAND SUBSTITUTION (`$(pwd)` — the exact
  # form the arm's own comment named as covered). MEASURED against the pre-fix script at 637c21c19:
  # both passed GREEN (rc 0, "scanned 63+94") beside a `${REPO:-$PWD}` that reddened. An arm that
  # cannot fail is decoration, so this one is run against that pre-fix script too and FAILS there.
  # ⛔ AND THE BACKTICK SPELLING OF THE SAME SUBSTITUTION (#3054 review, P2 — a FAIL-OPEN): the test
  # asked only about `$(`, so `REPO=` + a backticked `pwd` passed the gate while `REPO="$(pwd)"`
  # reddened. Closing one spelling of a command substitution and not the other is the
  # "a PR or an agent can defeat it" class, so it is a mutant here beside `$(pwd)`.
  for _m5 in '$AI' '$(pwd)' '`pwd`'; do
    mut_copy
    printf 'REPO="%s"\n' "$_m5" >> "$MUTDIR/pi-reap-worktrees.sh"
    mut_out="$(bash "$MUTDIR/orchestrator-harness/check-single-source.sh" 2>&1)"; mut_rc=$?
    mut_red="$(printf '%s\n' "$mut_out" | grep -i 'PRIVATE' | head -2)"
    { [ "$mut_rc" -eq 1 ] && grep -q 'pi-reap-worktrees.sh:[0-9]' <<<"$mut_red"; }
    m5_st=$?   # captured before the `$(…)` in the message — see A7 (#3054 review, P1)
    ck "M5 a REPO default spelled REPO=\"$_m5\" reddens check-single-source.sh (rc=$mut_rc): $(printf '%s' "$mut_red" | head -1 | cut -c1-100)" "$m5_st"
  done
  # M6 — THE CANDIDATE TRANSPORT REVERTED TO WORD SPLITTING (#3833 review F1). This is the shipped
  # pre-fix shape, so A16 must red: it is the arm that exists to keep a space in a path representable.
  mut_copy
  mut_edit "$MUTDIR/orchestrator-harness/repo-slug.sh" 'while IFS= read -r _cand; do' 'for _cand in $REPO_CANDIDATES; do'
  mut_edit "$MUTDIR/orchestrator-harness/repo-slug.sh" 'done <<<"$REPO_CANDIDATES"' 'done'
  mut_run "M6 the candidate list is word-split again (a space in a path refuses a real checkout)" "A16"

  rm -rf "$T/mut"
elif [ "${1:-}" = "--mutation-proof" ]; then
  echo
  echo "  (nested mutation run — proof skipped: RR_TEST_NO_MUT=1)"
fi

echo
echo "================ RESULT: $PASS passed, $FAIL failed ================"
[ "$FAIL" -eq 0 ]
