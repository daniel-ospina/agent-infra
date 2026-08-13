#!/bin/bash
# Fixture harness for scripts/ci/enforce-protocol-table.sh (issue #239)
set -u
SCRIPT="$(pwd)/scripts/ci/enforce-protocol-table.sh"
FAIL=0
run() { # name, expected_rc, fixture_dir
  local name="$1" exp="$2" fix="$3"
  ROOT="$fix" bash "$SCRIPT" >/dev/null 2>&1
  local rc=$?
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

[ $FAIL -eq 0 ] && echo "ALL FIXTURES PASS" || echo "FIXTURE FAILURES"
exit $FAIL
