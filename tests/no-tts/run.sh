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
#   3. THE NAME — no shipped script may DEFINE a helper called `say`, so a forgotten definition is
#      `command not found` on stderr (loud, local, attributable) instead of a voice on the speaker.
#      This arm is the one the rename itself needed and did not have: the rename was counted against a
#      stale base, and two files that landed afterwards still defined `say` for as long as it took a
#      reviewer to find them. A line-start scan cannot see a file that arrives after the scan; this
#      arm reads the tree on every run.
#
# ⛔ DECLARED LIMIT — this shard does NOT re-run the fragment suites under the recorder. They assert the
# recorder themselves on every fragment arm (§B, its second run, §F and §O of install-controller-service
# .test.sh), which is the strong check and costs ~7 minutes; this shard covers the cheap half that those
# arms structurally cannot: a NEW runner's adoption, and the recorder's own liveness.
#
# ⛔ IT ALSO DOES NOT DETECT EVERY WAY TO EXECUTE A FRAGMENT, AND THE POPULATION IS STATED HERE SO THE
# GAP IS NOT MISTAKEN FOR A PASS. The adoption predicate below matches ONE shape — a slice cat'd in as a
# variable (`cat "$FRAG"` into a child shell). MEASURED on 2026-10-27 against this tree: exactly ONE
# suite uses that shape (install-controller-service.test.sh). NINE suites execute shipped FUNCTIONS
# another way — `awk '/^fn(){/,/^}/'` into a file, then `bash -c` — and NONE of them sources the prelude,
# so the adoption arm does not see them at all. (THE COUNT DEPENDS ON THE PREDICATE, THE GAP DOES NOT:
# nine when the `awk` program must actually select a function definition, fifteen on a looser "any awk
# plus any `bash -c`", and #2925's reviewer counted fourteen. Every version of the count is uncovered.)
# An earlier version of this comment called the predicate "the shape this repo uses"; that was false,
# and a guard that overstates its reach is worse than one that names it.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
LIB="$ROOT/scripts/lib/frag-stubs.sh"
# This shard's own repo-relative path, so the census can exclude it. Its fixtures EMBED the fragment
# shape inside quoted strings, so a text predicate matches it — but it executes no shipped fragment, and
# reporting it as a "fragment runner" would inflate the population it is measuring.
SELF_REL="${BASH_SOURCE[0]#"$ROOT"/}"; SELF_REL="${SELF_REL#./}"

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ✅ %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf '  ❌ %s\n' "$*"; }

[ -s "$LIB" ] || { printf '❌ %s is missing — the shared fragment prelude IS the fix for #2910; without it nothing here is armed\n' "$LIB" >&2; exit 1; }
# shellcheck source=../scripts/lib/frag-stubs.sh
. "$LIB" || { printf '❌ cannot source %s — refusing to report a guard that is not armed\n' "$LIB" >&2; exit 1; }

T="$(mktemp -d "${TMPDIR:-/tmp}/no-tts.XXXXXX")" || { echo "❌ cannot mktemp" >&2; exit 1; }
trap 'rm -rf "$T"' EXIT

# ── code, not prose ─────────────────────────────────────────────────────────────────────────────
# A text predicate that reads whole-line COMMENTS reports prose as an offender, and the first census
# did exactly that: of 3 files it called "fragment runners", ONE was a fragment runner — the shared
# prelude matched its own usage example, and this shard matched its own fixture strings. A guard that
# reports prose teaches its reader to ignore it, so every predicate below reads code lines only.
code() { grep -v -E '^[[:space:]]*#' -- "$@" 2>/dev/null; }

# ── the census: which files EXECUTE a shipped fragment? ─────────────────────────────────────────
# stdin: repo-relative paths. A fragment runner is a file that cats a shell slice into a child shell.
frag_runners() { # <paths on stdin>
  local f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    code "$f" | grep -qF 'cat "$FRAG"' && printf '%s\n' "$f"
  done
}
# stdin: repo-relative paths. Offenders are fragment runners that do NOT source the one shared prelude —
# i.e. the #2911 state, which a pre-fix worktree then ran and which spoke.
frag_unadopted() { # <paths on stdin>
  local f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    code "$f" | grep -qF 'cat "$FRAG"' || continue
    code "$f" | grep -qF 'frag-stubs.sh' || printf '%s\n' "$f"
  done
}
# stdin: repo-relative paths. A shipped script that DEFINES a helper called `say` — the name layer. This
# covers DEFINITIONS only; a stub inside a quoted `bash -c` payload is not a line-start token at all and
# is a different blind spot (the census in pi-cache-reap.test.sh 10b is what finds that shape).
say_defs() { # <paths on stdin>
  local f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    code "$f" | grep -qE '^[[:space:]]*say[[:space:]]*\(\)' && printf '%s\n' "$f"
  done
}

CENSUS="$(cd "$ROOT" && git ls-files -- '*.test.sh' 'scripts/*.sh' 'tests/*/run.sh' 'pi-bootstrap/tests/*.sh' 2>/dev/null \
          | grep -vxF "$SELF_REL" \
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

# ── the NAME: no shipped script may define a helper called `say` ───────────────────────────────
# This is the arm the rename itself needed. The rename was counted against a stale base, so two files
# that landed on main afterwards still defined `say` — 2 definitions and 29 call sites were sitting in
# the tree while the change read as complete. A line-start scan cannot see a file that arrives after
# the scan; this arm re-reads the tree on every run, so the NEXT such file is red here instead.
SAY_DEFS="$(cd "$ROOT" && git ls-files -- '*.sh' '*.bash' 2>/dev/null | say_defs)"
[ -z "$SAY_DEFS" ] \
  && ok 'no shipped shell script DEFINES a helper called `say` — the name that resolves to /usr/bin/say on macOS is gone from the tree, not just from the files the rename happened to visit' \
  || bad "shipped script(s) still defining \`say\`: $(printf '%s' "$SAY_DEFS" | tr '\n' ' ') — on macOS this name is /usr/bin/say, so a missed definition is a voice on the speaker, not a log line (#2910)"

# ── that arm's own mutation: it must NAME a defining fixture, and pass the renamed one ──────────
mkdir -p "$T/fxn"
printf '%s\n' '#!/usr/bin/env bash' 'say() { printf "%s\n" "$*"; }' > "$T/fxn/bad.sh"
printf '%s\n' '#!/usr/bin/env bash' 'log_line() { printf "%s\n" "$*"; }' > "$T/fxn/good.sh"
printf '%s\n' '#!/usr/bin/env bash' '# say() in a comment is prose, never a definition' > "$T/fxn/prose.sh"
MUT_SAY="$(printf '%s\n' "$T/fxn/bad.sh" "$T/fxn/good.sh" "$T/fxn/prose.sh" | say_defs)"
case "$MUT_SAY" in
  "$T/fxn/bad.sh") ok 'MUTATION: the name arm NAMES the fixture that defines `say`, and not the renamed one or the one that only mentions it in a comment — so the arm above can fail, and prose cannot make it fail' ;;
  '') bad 'MUTATION: the name arm found no definition in a fixture that defines `say` — the check above is INERT (#2910)' ;;
  *) bad "MUTATION: the name arm misidentified the fixtures — it reported: $(printf '%s' "$MUT_SAY" | tr '\n' ' ')" ;;
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
