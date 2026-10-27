#!/usr/bin/env bash
# no-tts/run.sh — NO TEST MAY MAKE THE MACHINE SPEAK (agent-infra #2910).
#
# THE MEASURED INCIDENT. 2026-10-27, during the owner's live customer call, `install-controller-service
# .test.sh` executed a SLICE of `cloud-cell-supervisor.sh` in a fresh `bash -c`, where that script's own
# print helper did not exist. The helper was called `say`; macOS ships /usr/bin/say (text-to-speech); so
# the shell READ the shipped banner — `controller: FOREGROUND — this process is the controller …` —
# ALOUD through the speaker. `pmset -g assertions` showed `audio-out BuiltInSpeakerDevice` created for
# the say pid. Nothing failed and nothing was logged: the suite read GREEN while it spoke.
#
# THE FIRST REPAIR WAS THE SYMPTOM. #2911 added a stub prelude to that one suite and proved 26 → 0 calls
# to the real binary. ~50 minutes later a live lane ran the SAME suite from ITS OWN pre-fix worktree,
# where the prelude did not exist, and the machine spoke again. A per-file stub list is a CONVENTION,
# and a convention is a thing the next runner forgets.
#
# THE ROOT WAS THE NAME, and the fix has three independently-failing parts. This shard checks the two
# that nothing else can check on every run:
#   1. THE ADOPTION — a suite that executes a shipped fragment must source the ONE shared prelude
#      (`scripts/lib/frag-stubs.sh`), never carry its own inline stub list. That is what makes the
#      population safe BY CONSTRUCTION when a new fragment runner is added.
#   2. THE CAPABILITY — a recorder named `say` first on PATH, proven LIVE on every run: it must record a
#      speaking fixture (red) and record nothing for a quiet one (green). A guard whose failing path is
#      never exercised is a guard that cannot fail.
# The third part — the NAME itself — is checked by the rename this shard ships with: no shipped script
# defines or calls a helper called `say`, so a forgotten definition is `command not found` on stderr
# (loud, local, attributable) instead of a voice on the speaker.
#
# ⛔ DECLARED LIMIT — this shard does NOT re-run the fragment suites under the recorder. They assert the
# recorder themselves on every fragment arm (§B, its second run, §F and §O of install-controller-service
# .test.sh), which is the strong check and costs ~7 minutes; this shard covers the cheap half that those
# arms structurally cannot: a NEW runner's adoption, and the recorder's own liveness. It also does not
# detect every conceivable way to execute a fragment — the predicate below is the shape this repo uses
# (`$(cat "$FRAG")` into a child shell), stated so a runner that extracts a fragment differently is a
# KNOWN gap rather than an assumed pass.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
LIB="$ROOT/scripts/lib/frag-stubs.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ✅ %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf '  ❌ %s\n' "$*"; }

[ -s "$LIB" ] || { printf '❌ %s is missing — the shared fragment prelude IS the fix for #2910; without it nothing here is armed\n' "$LIB" >&2; exit 1; }
# shellcheck source=../scripts/lib/frag-stubs.sh
. "$LIB" || { printf '❌ cannot source %s — refusing to report a guard that is not armed\n' "$LIB" >&2; exit 1; }

T="$(mktemp -d "${TMPDIR:-/tmp}/no-tts.XXXXXX")" || { echo "❌ cannot mktemp" >&2; exit 1; }
trap 'rm -rf "$T"' EXIT

# ── the census: which files EXECUTE a shipped fragment? ─────────────────────────────────────────
# stdin: repo-relative paths. A fragment runner is a file that cats a shell slice into a child shell.
frag_runners() { # <paths on stdin>
  local f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    grep -qF 'cat "$FRAG"' "$f" 2>/dev/null && printf '%s\n' "$f"
  done
}
# stdin: repo-relative paths. Offenders are fragment runners that do NOT source the one shared prelude —
# i.e. the #2911 state, which a pre-fix worktree then ran and which spoke.
frag_unadopted() { # <paths on stdin>
  local f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    grep -qF 'cat "$FRAG"' "$f" 2>/dev/null || continue
    grep -qF 'frag-stubs.sh' "$f" 2>/dev/null || printf '%s\n' "$f"
  done
}

CENSUS="$(cd "$ROOT" && git ls-files -- '*.test.sh' 'scripts/*.sh' 'tests/*/run.sh' 'pi-bootstrap/tests/*.sh' 2>/dev/null \
          | sed "s|^|$ROOT/|" | frag_runners)"
if [ -n "$CENSUS" ]; then
  ok "the census found $(printf '%s\n' "$CENSUS" | wc -l | tr -d ' ') suite(s) that execute a shipped fragment: $(printf '%s' "$CENSUS" | sed "s|^$ROOT/||" | tr '\n' ' ')"
else
  bad "the census found NO fragment runner — the adoption check below would be vacuous, so the predicate (not the population) is what failed here"
fi

OFFENDERS="$(printf '%s\n' "$CENSUS" | frag_unadopted)"
[ -z "$OFFENDERS" ] \
  && ok 'every fragment runner sources the ONE shared prelude (scripts/lib/frag-stubs.sh) — none carries its own inline stub list' \
  || bad "fragment runner(s) with their own/absent stub list: $(printf '%s' "$OFFENDERS" | sed "s|^$ROOT/||" | tr '\n' ' ') — that is the #2911 state, and a pre-fix worktree running it READ THE BANNER ALOUD (#2910)"

# ── the predicate's own mutation: it must NAME an offender, not just "find nothing" ─────────────
# Two fixtures, identical except for the adoption: the good one sources the shared prelude, the bad one
# keeps an inline `say(){ :; }` stub list and no source. If the predicate cannot tell them apart, the
# arm above is proving nothing.
mkdir -p "$T/fx"
printf '%s\n' '#!/usr/bin/env bash' \
  '. "$(dirname "$0")/lib/frag-stubs.sh"' \
  'bash -c "${FRAG_STUBS}superseded() { return 1; }; $(cat "$FRAG")"' \
  > "$T/fx/good.test.sh"
printf '%s\n' '#!/usr/bin/env bash' \
  "STUBS='say(){ :; }; '" \
  'bash -c "${STUBS}superseded() { return 1; }; $(cat "$FRAG")"' \
  > "$T/fx/bad.test.sh"
MUT_OFF="$(printf '%s\n' "$T/fx/good.test.sh" "$T/fx/bad.test.sh" | frag_unadopted)"
case "$MUT_OFF" in
  "$T/fx/bad.test.sh") ok 'MUTATION: the adoption predicate NAMES the inline-stub fixture and not the adopted one — so the arm above can fail' ;;
  '') bad 'MUTATION: the predicate found no offender in a fixture that keeps an inline stub list — the adoption check above is INERT (#2910)' ;;
  *) bad "MUTATION: the predicate misidentified the fixtures — it reported: $(printf '%s' "$MUT_OFF" | tr '\n' ' ')" ;;
esac

# ── the capability: the recorder is LIVE, and it reddens a speaking suite and stays green on a quiet one ──
mk_quiet_bin "$T/bin" "$T/calls" || { echo "❌ cannot build the recorder — the capability arms would be inert" >&2; exit 1; }
printf '%s\n' '#!/usr/bin/env bash' 'say "this suite must never be heard"' 'exit 0' > "$T/fx/talks.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" quiet' 'exit 0' > "$T/fx/quiet.sh"

PATH="$T/bin:$PATH" bash "$T/fx/talks.sh" >/dev/null 2>&1 || true
N_TALK="$(wc -l < "$T/calls" | tr -d ' ')"
[ "${N_TALK:-0}" -ge 1 ] \
  && ok "the recorder CAPTURES a suite that calls \`say\` (${N_TALK} call(s)) — /usr/bin/say is unreachable and the attempt is evidence" \
  || bad 'the recorder captured nothing for a suite that calls `say` — the guard would pass a SPEAKING test (#2910)'

: > "$T/calls"
PATH="$T/bin:$PATH" bash "$T/fx/quiet.sh" >/dev/null 2>&1 || true
N_QUIET="$(wc -l < "$T/calls" | tr -d ' ')"
[ "${N_QUIET:-0}" -eq 0 ] \
  && ok 'and it records NOTHING for a suite that stays quiet — so a green run is a measurement, not an empty file' \
  || bad "a quiet suite was recorded ${N_QUIET} time(s) — the recorder is recording something other than the named binaries, so every 'no calls' assertion is untrustworthy"

printf '\n────────────────────────────────────────────\n'
printf 'passed=%s failed=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || { printf '❌ FAILURES — fix and re-run\n'; exit 1; }
printf '✅ no test can reach the real `say`\n'
