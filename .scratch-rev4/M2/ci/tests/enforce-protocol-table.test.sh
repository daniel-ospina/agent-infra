#!/bin/bash
# Fixture harness for scripts/ci/enforce-protocol-table.sh (issue #239)
set -u
SCRIPT="$(pwd)/scripts/ci/enforce-protocol-table.sh"
FAIL=0
run() { # name, expected_rc, fixture_dir, [agent_infra_path]
  # AGENT_INFRA_PATH is pinned per-fixture (#3462): it is now a manifest-resolution
  # input, so inheriting it from the caller's environment would let a fixture pass for
  # the wrong reason (e.g. H resolving a global manifest and failing on missing skill
  # files instead of on the absent-manifest path it exists to pin). Absent 4th arg = unset.
  local name="$1" exp="$2" fix="$3" rc=0
  if [ $# -ge 4 ]; then
    AGENT_INFRA_PATH="$4" ROOT="$fix" bash "$SCRIPT" >/dev/null 2>&1 || rc=$?
  else
    env -u AGENT_INFRA_PATH ROOT="$fix" bash "$SCRIPT" >/dev/null 2>&1 || rc=$?
  fi
  if [ "$rc" -eq "$exp" ]; then echo "✅ $name (rc=$rc)"; else echo "❌ $name: expected rc=$exp got $rc"; FAIL=1; fi
}
trap 'rm -rf /tmp/239-fix-*' EXIT

# Fixture A: populated table, all-in-manifest -> 0
A=$(mktemp -d /tmp/239-fix-A.XXXX); mkdir -p $A/enforcement $A/skills/commit-workflow $A/skills/supabase
printf 'commit-workflow # pat # hard # msg\nsupabase # pat2 # hard # msg2\n' > $A/enforcement/dangerous-ops.txt
printf '# AGENTS.md\n\n| Trigger | Must invoke |\n|---|---|\n| any | `skills/commit-workflow/SKILL.md` |\n| any | `skills/supabase/SKILL.md` |\n' > $A/AGENTS.md
mkdir -p $A/skills/commit-workflow $A/skills/supabase
touch $A/skills/commit-workflow/SKILL.md $A/skills/supabase/SKILL.md
run "A-populated-clean" 0 "$A"

# Fixture B: populated table missing one manifest skill ROW -> 1 (Pass 2 forward)
B=$(mktemp -d /tmp/239-fix-B.XXXX); cp -r $A/. $B/ 2>/dev/null; mkdir -p $B/enforcement $B/skills
printf 'commit-workflow # p # h # m\nsupabase # p2 # h # m2\n' > $B/enforcement/dangerous-ops.txt
printf '# AGENTS.md\n\n| Trigger | Must invoke |\n|---|---|\n| any | `skills/commit-workflow/SKILL.md` |\n' > $B/AGENTS.md
run "B-missing-table-row" 1 "$B"

# Fixture C: populated with extra ghost row not in manifest -> 1 (reverse)
C=$(mktemp -d /tmp/239-fix-C.XXXX); cp -r $A/. $C/ 2>/dev/null; mkdir -p $C/enforcement
printf '# AGENTS.md\n\n| Trigger | Must invoke |\n|---|---|\n| any | `skills/commit-workflow/SKILL.md` |\n| any | `skills/supabase/SKILL.md` |\n| any | `skills/ghost-skill/SKILL.md` |\n' > $C/AGENTS.md
run "C-reverse-ghost" 1 "$C"

# Fixture D: placeholder table -> 0 (skip)
D=$(mktemp -d /tmp/239-fix-D.XXXX); cp -r $A/. $D/ 2>/dev/null; mkdir -p $D/enforcement
printf '# AGENTS.md\n\n| Trigger | Must invoke | Consequence |\n|---|---|---|\n| Any git op | `skills/commit-workflow/SKILL.md` | ... |\n| ... | ... | ... |\n' > $D/AGENTS.md
run "D-placeholder-skip" 0 "$D"

# Fixture E: missing AGENTS.md -> 0 (skip, Pass 1 gates)
E=$(mktemp -d /tmp/239-fix-E.XXXX); cp -r $A/. $E/ 2>/dev/null; rm -f $E/AGENTS.md
run "E-missing-agents-skip" 0 "$E"

# Fixture F: missing skill file -> 1 (Pass 1)
F=$(mktemp -d /tmp/239-fix-F.XXXX); cp -r $A/. $F/ 2>/dev/null; rm -f $F/skills/supabase/SKILL.md
printf 'commit-workflow # p # h # m\nsupabase # p2 # h # m2\n' > $F/enforcement/dangerous-ops.txt
run "F-missing-skill-file" 1 "$F"

# Fixture G: consumer layout (operations/) -> 0, + missing variant -> 1
G=$(mktemp -d /tmp/239-fix-G.XXXX); mkdir -p $G/operations/skills/{commit-workflow,supabase} $G/operations/enforcement
printf 'commit-workflow # p # h # m\nsupabase # p2 # h # m2\n' > $G/operations/enforcement/dangerous-ops.txt
printf '# AGENTS.md\n\n| Trigger | Must invoke |\n|---|---|\n| any | `operations/skills/commit-workflow/SKILL.md` |\n| any | `operations/skills/supabase/SKILL.md` |\n' > $G/AGENTS.md
touch $G/operations/skills/commit-workflow/SKILL.md $G/operations/skills/supabase/SKILL.md
run "G-consumer-layout-clean" 0 "$G"
rm -rf $G/operations/skills/supabase
printf 'commit-workflow # p # h # m\nsupabase # p2 # h # m2\n' > $G/operations/enforcement/dangerous-ops.txt
run "G-consumer-layout-missing" 1 "$G"

# Fixture H: no manifest anywhere -> 1 (fail-closed)
H=$(mktemp -d /tmp/239-fix-H.XXXX); mkdir -p $H/skills
run "H-no-manifest-failclosed" 1 "$H"

# Fixture I: empty manifest -> exit 0 with warning (no silent death)
I=$(mktemp -d /tmp/239-fix-I.XXXX); mkdir -p $I/enforcement $I/skills
printf '# comments only\n' > $I/enforcement/dangerous-ops.txt
run "I-empty-manifest-warn" 0 "$I"

# Fixture J: regex metachar skill name (dot) must NOT match a different table entry (fixed-string)
J=$(mktemp -d /tmp/239-fix-J.XXXX); mkdir -p $J/enforcement $J/skills/foo.bar
printf 'foo.bar # p # h # m\n' > $J/enforcement/dangerous-ops.txt
printf '# AGENTS.md\n\n| Trigger | Must invoke |\n|---|---|\n| any | `skills/fooXbar/SKILL.md` |\n' > $J/AGENTS.md
touch $J/skills/foo.bar/SKILL.md
run "J-regex-fixed-string" 1 "$J"

# Fixture K: multi-skill row (both refs) -> reverse catches the ghost
K=$(mktemp -d /tmp/239-fix-K.XXXX); mkdir -p $K/enforcement $K/skills/commit-workflow
printf 'commit-workflow # p # h # m\n' > $K/enforcement/dangerous-ops.txt
printf '# AGENTS.md\n\n| Trigger | Must invoke |\n|---|---|\n| any | `skills/ghost-skill/SKILL.md` and `skills/commit-workflow/SKILL.md` |\n' > $K/AGENTS.md
touch $K/skills/commit-workflow/SKILL.md
run "K-multi-skill-row-reverse" 1 "$K"

# Fixture L: consumer with NO repo-local manifest, but ${AGENT_INFRA_PATH} carries the
# manifest actually in force -> 0. This is the #3462 case: skill-enforcer resolves its gate map
# from the extension's own install location, so a repo without a local manifest is enforced by
# the global one and must be audited against it, not failed closed. The manifest is deliberately
# MULTI-ENTRY and the consumer resolves ALL of it (the standard `skills/` symlink layout, which
# is how tortoise/premise-labs are set up). A 1-entry manifest would not exercise the multi-skill
# resolution the real agent-infra manifest performs, and would give false confidence
# (#3462 review, P2).
L=$(mktemp -d /tmp/239-fix-L.XXXX)
mkdir -p $L/skills/commit-workflow $L/skills/supabase $L/skills/using-git-worktrees
LINFRA=$(mktemp -d /tmp/239-fix-Linfra.XXXX); mkdir -p $LINFRA/enforcement
printf 'commit-workflow # p # h # m\nsupabase # p2 # h # m2\nusing-git-worktrees # p3 # h # m3\n' > $LINFRA/enforcement/dangerous-ops.txt
touch $L/skills/commit-workflow/SKILL.md $L/skills/supabase/SKILL.md $L/skills/using-git-worktrees/SKILL.md
run "L-inforce-manifest-fallback" 0 "$L" "$LINFRA"

# Fixture M: same consumer, but AGENT_INFRA_PATH has no enforcement/ -> 1. Pins that the
# fallback did not turn the fail-closed branch into a silent pass (#3462 review).
MINFRA=$(mktemp -d /tmp/239-fix-Minfra.XXXX)
run "M-fallback-exhausted-failclosed" 1 "$L" "$MINFRA"

# Fixture N: repo-local manifest WINS over the in-force fallback -> 0. The local manifest names
# exactly the one skill this fixture ships, so local-precedence PASSES (rc=0) while
# fallback-precedence FAILS (rc=1 — LINFRA's supabase/using-git-worktrees are absent here).
# Asserting rc=0 is what makes the ordering observable. The original version of this fixture
# used a 2-entry local manifest and expected rc=1 — which the fallback-ordering also produces,
# so it pinned nothing: cycle-2 review built a fallback-FIRST mutant that passed the entire
# suite. With rc=0 expected, that mutant now fails this fixture (#3462 review, P2).
N=$(mktemp -d /tmp/239-fix-N.XXXX); mkdir -p $N/skills/commit-workflow $N/enforcement
printf 'commit-workflow # p # h # m\n' > $N/enforcement/dangerous-ops.txt
touch $N/skills/commit-workflow/SKILL.md
run "N-local-manifest-precedence" 0 "$N" "$LINFRA"

# Fixture O: consumer with a PARTIAL real skills/ dir against a MULTI-ENTRY in-force manifest
# -> 1. Pins the boundary the fallback deliberately does NOT cross: a consumer that cannot
# resolve the in-force manifest's skills has a genuinely unsatisfiable gate (the permanent
# confusing block Pass 1 exists to catch), and the fix must not paper over it. Without this
# fixture, L alone would imply "any consumer now passes" — the over-claim the #3462 review
# flagged.
O=$(mktemp -d /tmp/239-fix-O.XXXX); mkdir -p $O/skills/commit-workflow
touch $O/skills/commit-workflow/SKILL.md
run "O-partial-skills-still-fails" 1 "$O" "$LINFRA"

# Fixture P (structural, deliberately NARROW): a spelling canary for the unguarded-root-probe
# class. The vulnerable forms all expand to the absolute path /enforcement/dangerous-ops.txt
# when AGENT_INFRA_PATH is unset — a plantable path on a root-owned CI container, which would
# turn the fail-closed branch into a fail-open one.
#
# HONEST SCOPE — read this before trusting P (cycle-3 review, P2):
#   * P is a TEXT assertion, not a functional guard. It is not a proof.
#   * NO fixture here functionally guards this class. A functional guard would require the
#     failure condition — a plantable /enforcement/dangerous-ops.txt — which needs root.
#   * H does NOT carry this burden, contrary to what an earlier revision of this comment
#     claimed. H runs on a clean host where /enforcement does not exist, so it only pins
#     "no manifest anywhere ⇒ rc=1"; it cannot observe the fail-open at all.
#   * The real assurance for this class is the shape of the code itself (the fallback sits
#     behind `[ -n "${AGENT_INFRA_PATH:-}" ]`) plus review — not a test.
# Covered spellings: the naive form, the no-colon `${VAR-}` form, quote-shifted variants, tabs,
# and (via line-joining and backslash removal) line-continuation forms. The pattern requires the
# brace to sit immediately after the name/`:`/`-` — i.e. an EMPTY default — which is what makes
# it safe to run over the whole file. A broader `[^}]*}` match was tried and FALSE-POSITIVED on
# line 120's fail-closed message, which legitimately contains the literal text
# `${AGENT_INFRA_PATH:-<AGENT_INFRA_PATH unset>}/enforcement/` as display output, not a probe.
# NOT covered, and acknowledged. These are same-class regressions that pass the whole suite,
# so they are disclosed explicitly rather than left to be implied as covered:
#   * the BRACE-LESS form `"$AGENT_INFRA_PATH/enforcement/..."` — there is no `}` for the
#     pattern to anchor on. With the variable set but EMPTY (not unset, so `set -u` does not
#     abort) this expands to exactly the root probe /enforcement/dangerous-ops.txt. This is the
#     most plausible real-world regression of the class, and P cannot see it.
#   * assigning ${AGENT_INFRA_PATH:-} / ${AGENT_INFRA_PATH-} to a temp variable first.
#   * any indirection that never names AGENT_INFRA_PATH next to /enforcement.
# NARROWER THAN IT SOUNDS on line continuation: the transform substitutes a SPACE for a
# backslash-newline, so only splits AFTER the closing brace are caught. A continuation INSIDE
# the expansion — `"${AGENT_INFRA_PATH:-\<newline>}/enforcement/..."`, which bash resolves to
# the same vulnerable form — becomes `…:- }/enforcement…` and is NOT flagged. Claimed coverage
# is therefore "continuations after the closing brace", not line continuation in general.
# Comment lines are stripped first: the script DOCUMENTS the vulnerable form in a comment
# explaining why it is avoided, and a naive grep matched that documentation.
_LIVE_CODE=$(grep -v '^[[:space:]]*#' "$SCRIPT" | tr -d '\\' | tr '\n' ' ')
if grep -qE 'AGENT_INFRA_PATH[:-]*\}[^[:alnum:]_]*/enforcement' <<<"$_LIVE_CODE"; then
  echo "❌ P-no-naive-root-probe: unguarded AGENT_INFRA_PATH-derived root probe present in code"; FAIL=1
else
  echo "✅ P-no-naive-root-probe (spelling canary — NOT a functional guard; see comment)"
fi

[ $FAIL -eq 0 ] && echo "ALL FIXTURES PASS" || echo "FIXTURE FAILURES"
exit $FAIL
