#!/bin/bash
# beat-pair.sh -- the recap/beat PAIR rule, in ONE place, sourced by every reader.
#
# WHY THIS IS A SHARED FILE AND NOT INLINE IN EACH READER (#7957 H3)
#   `lane-actions.py` publishes TWO files: state/NEEDS-ACTION.md (the recap) and
#   state/NEEDS-ACTION.beat (the one-line sidecar the floor reads). They are two INDEPENDENT atomic
#   writes, so any failure between them leaves a FRESH recap beside a STALE beat -- two numbers, one
#   tick -- and the beat is the half that gets published. The sidecar's own mtime cannot detect this:
#   it is only ever the mtime of the last SUCCESSFUL beat write, which is exactly the write that
#   failed. So the beat carries `md=<sha256(recap)[:12]>` -- the digest of the recap it was rendered
#   from -- and every reader compares it against the recap actually on disk.
#   Two readers need this rule (cadence-nudge.sh, which PUBLISHES the clause, and heartbeat-loop.sh,
#   which logs it). A rule implemented twice is how one contract becomes two, so it lives here -- and
#   each reader calls `beat_clause_verified` rather than repeating "verify, then read": that
#   repetition is what let the guard be inverted with the tests still green (#1897 review, P2).
#
# ABSENCE IS NOT A PASS.
#   A beat written before `md=` existed cannot be verified. It is SUPPRESSED, never trusted: an
#   unverifiable number published as current is precisely the false-fresh signal this guards.
#   Suppression is the reader's EXISTING degradation -- actfull=0 leaves the older mechanical/Jev
#   clauses standing, exactly as a Jev outage does -- so a torn pair falls back to the previous beat
#   rather than publishing a count that describes a different state.
#
# NOT SOURCED FOR ITS SIDE EFFECTS: this file defines functions only and runs nothing.

# _mdsha <file> -- first 12 hex of the file's sha256, or EMPTY if it cannot be computed.
# Portability: `shasum` on macOS, `sha256sum` on Linux. An empty result is read by beat_pair_ok as a
# MISMATCH (fail closed) -- if neither tool exists, an unverifiable pair must be suppressed rather
# than published. Note the failure direction: a WRONG-WIDTH digest would still be self-consistent,
# so the width is pinned by tests/beat-pair/run.sh against an independently computed sha256[:12].
_mdsha(){
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" 2>/dev/null | cut -c1-12
  else sha256sum "$1" 2>/dev/null | cut -c1-12; fi
}

# beat_pair_ok <state_dir> -- 0 only when the recap on disk is the one this beat was rendered from.
# Prints the reason on stderr for every refusal, so a suppressed clause is never silent.
beat_pair_ok(){
  local st="$1" bmd amd
  bmd=$(sed -n 's/^md=//p' "$st/NEEDS-ACTION.beat" 2>/dev/null | head -1)
  if [ -z "$bmd" ]; then
    echo "beat_pair_ok: beat carries no md= digest -- recap/beat pair UNVERIFIABLE" >&2; return 1
  fi
  amd=$(_mdsha "$st/NEEDS-ACTION.md")
  if [ -z "$amd" ]; then
    echo "beat_pair_ok: cannot digest $st/NEEDS-ACTION.md -- recap/beat pair UNVERIFIABLE" >&2; return 1
  fi
  if [ "$amd" != "$bmd" ]; then
    echo "beat_pair_ok: recap/beat pair is TORN (beat md=$bmd, recap md=$amd)" >&2; return 1
  fi
  return 0
}

# beat_clause_verified <state_dir> [<max_chars>] -- the act clause, but ONLY if the pair verifies.
# stdout: the clause and rc 0 when it verifies; NOTHING (rc 1) otherwise, with beat_pair_ok's reason
# on stderr. Readers call THIS instead of doing "verify, then read" by hand: the hand-rolled form can
# be INVERTED, and an inverted guard still matches every string a text-based wiring test looks for
# (#1897 review, P2 -- the check stayed green with the guard deleted). One call cannot be inverted.
beat_clause_verified(){
  local st="$1" cap="${2:-420}"
  beat_pair_ok "$st" || return 1
  sed -n 's/^act=//p' "$st/NEEDS-ACTION.beat" 2>/dev/null | head -1 | cut -c"1-$cap"
}
