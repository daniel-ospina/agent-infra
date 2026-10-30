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
#   B  the three call sites resolve through it: report.sh, pi-reap-worktrees.sh (both the `--repo` arm
#      AND the box's inherited `$REPO`) and deploy-crossbox.sh each REFUSE a bogus/absent repo in
#      their own loud words, none falls back to `$HOME/eldato/tortoise`, `/tmp/cell-ai` or `$PWD`, and
#      report.sh still exits 0 read-only on a real fixture (the property that made it safe to run
#      while the loop is working is preserved, not traded away).
#   M  `--mutation-proof`: the anti-vacuity gate. Four mutations are applied to a THROWAWAY copy of
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
mkdir -p "$REAL/sub" "$PLAIN"
git init -q "$REAL" || { echo "repo-slug.test.sh: cannot git init a fixture" >&2; exit 2; }
ln -s "$REAL" "$LINK"
canon() { ( cd "$1" 2>/dev/null && pwd -P ); }

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
ck "A7  a subdirectory is kept, never widened to the toplevel ("$(basename "$rr_out")")" $?

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
    { [ "$mut_rc" -ne 0 ] && [ -n "$mut_red" ] && grep -q -- "$mut_expect" <<<"$mut_out"; }
    ck "M $mut_name REDDENS (rc=$mut_rc): $(printf '%s' "$mut_red" | head -1 | sed 's/^ *//')" $?
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
  ck "M4 a planted private REPO default in scripts/ reddens check-single-source.sh (rc=$mut_rc): $(printf '%s' "$mut_red" | head -1 | cut -c1-100)" $?
  rm -rf "$T/mut"
elif [ "${1:-}" = "--mutation-proof" ]; then
  echo
  echo "  (nested mutation run — proof skipped: RR_TEST_NO_MUT=1)"
fi

echo
echo "================ RESULT: $PASS passed, $FAIL failed ================"
[ "$FAIL" -eq 0 ]
