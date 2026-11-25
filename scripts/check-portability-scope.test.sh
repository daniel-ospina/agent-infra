#!/usr/bin/env bash
# check-portability-scope.test.sh — the #4210 SCOPE SPLIT, and the freshness guard that keeps the
# moved half observable.
#
# WHAT THIS SUITE IS FOR (agent-infra#4210, owner decision 2026-11-25, option A)
# -----------------------------------------------------------------------------
# The detector answers two questions with very different costs:
#   the DIFF     "did THIS change introduce a trap"  → the required lane, every PR, cheap
#   the TREE     "is the accumulated tree still clean" → a batch run, where being slow is affordable
# The split is only real if each half is (a) actually wired, (b) actually still able to FAIL, and
# (c) unable to go quiet. That is what these arms test:
#
#   A. `check-portability-traps-changed.sh` — the diff half. A trap added in a changed file REDS; a
#      change with no trap passes; a change touching nothing in the scan set says so BY NAME; an
#      unanswerable diff REFUSES (rc 2) instead of reading as "nothing changed" — and EVERY refusal
#      site is driven by its own arm (unresolvable base, failed `git diff`, unpublishable scan set,
#      empty published set, and the detector's own refusal at the scan), because a site with no arm is
#      a guard whose deletion nothing reds; the scan set comes from the detector's own derivation, not
#      from a second `*.sh` guess.
#   B. `check-portability-tree-scan-alive.sh` — the tree half CANNOT GO QUIET. A fresh success
#      passes, a stale one fails, a workflow that has NEVER succeeded fails once its registration is
#      older than the bound (the bootstrap window is the one narrow exception, and it is reported),
#      and an unreadable API is a refusal. A 404 is told apart from an outage by the TREE and the BASE
#      together: absent from both the repository and the tree is an absence, and a file the BASE
#      already carries but the API does not is an absence too — only a file this change ADDS gets the
#      named bootstrap window, so it cannot be ridden forever.
#   C. THE WIRING, READ FROM THE PARSED FILES THAT RUN IT — both bounded lanes switch the whole-tree arm
#      off, the batch workflow switches it ON and runs `--root`, the batch workflow files ONE issue on
#      a rise, and both bounded lanes ask the freshness question. These assert on the PARSED document
#      (`scripts/workflow-yaml.mjs`): a step whose run COMMAND is the script, and a step's parsed env.
#      Each is paired with the mutant that reverts it, and the mutant keeps the script's NAME in the
#      text — because a substring check (“the name appears in the file”) is satisfied by a comment, which
#      is the bypass the parsed assertions close. A moved arm with no wiring is a removed arm.
#
# HERMETIC: every fixture is a throwaway git repo or a PATH shim under $TMP. No network, no real
# repository state, and — measured — the whole suite runs in about a second.
#
#   bash scripts/check-portability-scope.test.sh
#
# BASH 3.2-SAFE (macOS /bin/bash is a host this class exists for), and this file is scanned by the
# detector it drives, so it uses no `sed -i`, no `date -d`, no `stat -c`, no `timeout`.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || { echo "❌ unresolvable"; exit 1; }
SCOPE="$HERE/check-portability-traps-changed.sh"
ALIVE="$HERE/check-portability-tree-scan-alive.sh"
CHECK="$HERE/check-portability-traps.sh"
SUITE="$HERE/check-portability-traps.test.sh"
REPO_ROOT="$(cd "$HERE/.." && pwd)"

[ -f "$SCOPE" ] || { echo "❌ missing: $SCOPE"; exit 1; }
[ -f "$ALIVE" ] || { echo "❌ missing: $ALIVE"; exit 1; }

PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); printf 'PASS %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf 'FAIL %s\n' "$1"; }
skip() { SKIP=$((SKIP+1)); printf 'SKIP %s\n' "$1"; }

OS="$(uname -s 2>/dev/null || echo unknown)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/portability-scope-XXXXXX")" || { echo "❌ mktemp"; exit 1; }
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# ── A0. THE DETECTOR PUBLISHES ITS SCAN SET (the input the diff half depends on) ─────────────────
# ⛔ NON-VACUITY FIRST: every arm below intersects against this set, so an EMPTY or unreadable set
# would make the whole section pass by matching nothing.
out="$(bash "$CHECK" --print-targets 2>"$TMP/pt.err")"; rc=$?
n="$(printf '%s\n' "$out" | grep -c .)"
if [ "$rc" = 0 ] && [ "$n" -ge 50 ]; then
  ok "A0: --print-targets publishes the scan set ($n tracked shell file(s)) — the diff half has a real population"
else
  bad "A0: --print-targets rc=$rc with $n path(s) — the diff half would intersect against nothing"
fi
grep -q 'scripts/check-portability-traps.sh' <<<"$out" \
  && ok "A0b: the published set contains a file this repo really ships (not an empty derivation)" \
  || bad "A0b: the published scan set does not contain the detector itself"

# ── A1..A6. THE DIFF HALF ────────────────────────────────────────────────────────────────────────
# A throwaway repo with two shell files in the detector's scan set, plus a non-shell file. The base
# commit holds no traps; the arms then change exactly one thing each.
FIX="$TMP/fixrepo"
mkdir -p "$FIX/scripts" "$FIX/bin"
printf '%s\n' '#!/usr/bin/env bash' 'echo base' >"$FIX/scripts/one.sh"
printf '%s\n' '#!/usr/bin/env bash' 'echo base' >"$FIX/scripts/two.sh"
printf '%s\n' '# notes' >"$FIX/NOTES.md"
printf '%s\n' '#!/usr/bin/env node' 'console.log(1)' >"$FIX/bin/tool.js"
fgit() { git -C "$FIX" "$@" >/dev/null 2>&1; }
fgit init -q -b main
fgit config user.email scope@example.invalid
fgit config user.name scope-arm
fgit add scripts/one.sh scripts/two.sh NOTES.md bin/tool.js
fgit commit -q -m base

# A1 — THE GATE MUST BITE: a real trap introduced in a changed shell file.
printf '%s\n' '#!/usr/bin/env bash' 'echo base' 'n="$(nproc)"' >"$FIX/scripts/one.sh"
fgit add scripts/one.sh
fgit commit -q -m "add a trap"
bash "$SCOPE" --root "$FIX" --base HEAD~1 >"$TMP/a1.out" 2>&1; rc=$?
if [ "$rc" = 1 ] && grep -q 'scripts/one.sh:3: cpu-count-single-mechanism' "$TMP/a1.out"; then
  ok "A1: a trap introduced by the change REDS, naming file:line and the rule"
else
  bad "A1: the change-level gate did not red on a real trap (rc=$rc) — the required lane would pass it"
fi

# A2 — THE OTHER DIRECTION (no false block): a changed shell file with NO trap passes.
printf '%s\n' '#!/usr/bin/env bash' 'echo base' >"$FIX/scripts/one.sh"
fgit add scripts/one.sh
fgit commit -q -m "fix the trap"
bash "$SCOPE" --root "$FIX" --base HEAD~1 >"$TMP/a2.out" 2>&1; rc=$?
[ "$rc" = 0 ] && ok "A2: a changed shell file with no trap passes (the gate is not a blanket red)" \
  || bad "A2: a clean change rc=$rc — a red that is not a defect is how a gate loses its authority"

# A3 — NOTHING IN SCOPE IS NAMED, NOT SILENT: a change that touches no scanned file says so.
printf '%s\n' '# notes' '# more notes' >"$FIX/NOTES.md"
fgit add NOTES.md
fgit commit -q -m "docs only"
bash "$SCOPE" --root "$FIX" --base HEAD~1 >"$TMP/a3.out" 2>&1; rc=$?
if [ "$rc" = 0 ] && grep -q 'no changed file is in the portability scan set' "$TMP/a3.out" && grep -q '0 in the detector scan set' "$TMP/a3.out"; then
  ok "A3: a change with nothing in the scan set passes NAMING its conclusion (an unexplained green is indistinguishable from a gate that never ran)"
else
  bad "A3: out-of-scope change rc=$rc without a named conclusion"
fi

# A4 — AN UNANSWERABLE DIFF REFUSES (rc 2). This is the false-CLEAN direction: an unresolvable base
# must never be read as "nothing changed".
bash "$SCOPE" --root "$FIX" --base refs/heads/definitely-not-a-ref >"$TMP/a4.out" 2>&1; rc=$?
[ "$rc" = 2 ] && ok "A4: an unresolvable base REFUSES (rc 2) instead of reading as an empty diff" \
  || bad "A4: an unresolvable base produced rc=$rc — an unanswerable question passed as a clean answer"

# A5 — THE SCAN SET IS THE DETECTOR'S, NOT A SECOND `*.sh` GUESS. `bin/tool.js` is a tracked,
# changed, non-shell file: a `*.sh`-only derivation would also exclude a shebang shell file with no
# extension, so the arm asserts BOTH halves of the intersection rule.
printf '%s\n' '#!/usr/bin/env node' 'console.log(2)' >"$FIX/bin/tool.js"
printf '%s\n' '#!/usr/bin/env bash' 'n="$(nproc)"' >"$FIX/bin/shless-trap"
fgit add bin/tool.js bin/shless-trap
fgit commit -q -m "change a node file and add an extensionless shell file with a trap"
bash "$SCOPE" --root "$FIX" --base HEAD~1 --print-list >"$TMP/a5.out" 2>&1; rc=$?
if [ "$rc" = 0 ] && grep -q '^bin/shless-trap$' "$TMP/a5.out" && ! grep -q '^bin/tool.js$' "$TMP/a5.out"; then
  ok "A5: an extensionless shell file IS in scope and a changed node file is NOT — the intersection is the detector's own shebang rule, not a filename guess"
else
  bad "A5: the changed-set intersection diverges from the detector's scan set: $(tr '\n' ' ' <"$TMP/a5.out")"
fi
# and the same change must actually RED, because the extensionless file carries a trap.
bash "$SCOPE" --root "$FIX" --base HEAD~1 >"$TMP/a5b.out" 2>&1; rc=$?
[ "$rc" = 1 ] && grep -q 'bin/shless-trap' "$TMP/a5b.out" \
  && ok "A5b: the trap in that extensionless file is CAUGHT by the diff half (the set is not merely listed, it is scanned)" \
  || bad "A5b: the extensionless trap was not caught (rc=$rc)"

# A6 — A REFUSAL FROM THE DETECTOR IS NOT A CLEAN RUN. If the detector exits 2 (a scan refusal) the
# wrapper must not translate it into a pass.
# ⛔ THE STUB MUST REACH THE SCAN, WHICH IS THE CODE THIS ARM NAMES (review P2, measured). The first
# version refused EVERY invocation, so the wrapper died at its own `--print-targets` call
# (check-portability-traps-changed.sh:95-100) and the arm's rc 2 was produced THERE — never by the
# tail that translates the scan's rc. Mutating that tail to "only rc 1 fails" left this arm GREEN: a
# refusing detector would have read as CLEAN in the required lane, which is the fail-open class the
# wrapper's own header refuses. (Its second `printf` also overwrote the first, so line :145 was a
# dead statement — one stub now, and it answers the two calls differently.)
mkdir -p "$TMP/broken"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'case " $* " in' \
  "  *' --print-targets '*) printf '%s\\n' 'scripts/two.sh'; exit 0 ;;" \
  'esac' \
  'echo "refusing at the SCAN" >&2' \
  'exit 2' >"$TMP/broken/check-portability-traps.sh"
chmod +x "$TMP/broken/check-portability-traps.sh"
printf '%s\n' '#!/usr/bin/env bash' 'echo base' 'n="$(nproc)"' >"$FIX/scripts/two.sh"
fgit add scripts/two.sh
fgit commit -q -m "trap in two.sh"
# the wrapper resolves the detector next to ITSELF, so stage the wrapper beside the broken copy.
cp "$SCOPE" "$TMP/broken/check-portability-traps-changed.sh"
bash "$TMP/broken/check-portability-traps-changed.sh" --root "$FIX" --base HEAD~1 >"$TMP/a6.out" 2>&1; rc=$?
[ "$rc" = 2 ] && ok "A6: a detector REFUSAL (rc 2) propagates as a refusal, never as a pass" \
  || bad "A6: a refusing detector produced rc=$rc — a gate that cannot run must not read as green"

# A6a..A6c — THE WRAPPER'S OTHER TWO REFUSAL SITES, EACH DRIVEN BY ITS OWN STUB (review P2, measured).
# ⛔ WHY THESE EXIST: the F2 fix above replaced A6's original stub (which refused EVERY invocation)
# rather than duplicating it, so the site that stub happened to reach — the `--print-targets` guard —
# lost its only invocation, and the EMPTY-set guard and the failed-`git diff` guard never had one. The
# three guards mask each other pairwise today, so a single deleted handler still refuses via its
# neighbour: exactly the shape that makes a deletion of two of them silently read as CLEAN, which is
# the one direction this file exists to refuse. Each arm below drives ONE site and asserts the
# refusal BY NAME, so a handler that stops naming its reason cannot pass on some other site's rc.

# A6a — THE DETECTOR CANNOT PUBLISH ITS SCAN SET (an empty set would read as 'nothing to scan').
mkdir -p "$TMP/nopublish"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'echo "shim: cannot answer --print-targets" >&2' \
  'exit 3' >"$TMP/nopublish/check-portability-traps.sh"
chmod +x "$TMP/nopublish/check-portability-traps.sh"
cp "$SCOPE" "$TMP/nopublish/check-portability-traps-changed.sh"
bash "$TMP/nopublish/check-portability-traps-changed.sh" --root "$FIX" --base HEAD~1 >"$TMP/a6a.out" 2>&1; rc=$?
if [ "$rc" = 2 ] && grep -q 'could not publish its scan set' "$TMP/a6a.out"; then
  ok "A6a: a detector that cannot publish its scan set REFUSES BY NAME (rc 2) — not an empty set read as 'nothing to scan'"
else
  bad "A6a: an unpublishable scan set produced rc=$rc without naming the refusal: $(head -2 "$TMP/a6a.out")"
fi

# A6b — THE DETECTOR PUBLISHES AN EMPTY SET: a successfully answered question with no answer in it.
mkdir -p "$TMP/emptyset"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'case " $* " in' \
  "  *' --print-targets '*) exit 0 ;;" \
  'esac' \
  'exit 0' >"$TMP/emptyset/check-portability-traps.sh"
chmod +x "$TMP/emptyset/check-portability-traps.sh"
cp "$SCOPE" "$TMP/emptyset/check-portability-traps-changed.sh"
bash "$TMP/emptyset/check-portability-traps-changed.sh" --root "$FIX" --base HEAD~1 >"$TMP/a6b.out" 2>&1; rc=$?
if [ "$rc" = 2 ] && grep -q 'EMPTY scan set' "$TMP/a6b.out"; then
  ok "A6b: a PUBLISHED BUT EMPTY scan set REFUSES BY NAME (rc 2) — an answered-but-empty set is a refusal, not a clean run"
else
  bad "A6b: an empty published set produced rc=$rc without naming the refusal: $(head -2 "$TMP/a6b.out")"
fi

# A6c — THE BASE RESOLVES, BUT THE DIFF ITSELF FAILS (a corrupt object store, an unmounted volume, a
# repo readable for `rev-parse` and not for `diff`). 'I could not compute the changed set' must never
# become 'nothing changed'. A PATH shim answers the base resolution from the real git and fails only
# at `diff`, so the arm reaches `:88-91` and not the base guard one line above it.
mkdir -p "$TMP/gitfail"
real_git="$(command -v git)"
printf '%s\n' '#!/usr/bin/env bash' \
  'for a in "$@"; do' \
  '  if [ "$a" = "diff" ]; then echo "shim: cannot read the object store" >&2; exit 128; fi' \
  'done' \
  "exec \"$real_git\" \"\$@\"" >"$TMP/gitfail/git"
chmod +x "$TMP/gitfail/git"
PATH="$TMP/gitfail:$PATH" bash "$SCOPE" --root "$FIX" --base HEAD~1 >"$TMP/a6c.out" 2>&1; rc=$?
if [ "$rc" = 2 ] && grep -q 'cannot compute the changed set' "$TMP/a6c.out"; then
  ok "A6c: a FAILED 'git diff' behind a RESOLVABLE base REFUSES BY NAME (rc 2) — uncomputable is not empty"
else
  bad "A6c: a failed diff produced rc=$rc without naming the refusal: $(head -2 "$TMP/a6c.out")"
fi

# ── B1..B7. THE TREE HALF CANNOT GO QUIET ───────────────────────────────────────────────────────
# A PATH shim stands in for `gh`: each arm states which reads it answers, and the guard must reach a
# verdict from THOSE answers only.
mkgh() {  # mkgh <dir> <runs-json> <workflow-json> <exit-code-for-both>
  mkdir -p "$1"
  printf '%s\n' '#!/usr/bin/env bash' \
    "case \"\$*\" in" \
    "  *'/runs?'*) cat \"$1/runs.json\"; exit ${4:-0} ;;" \
    "  *'/actions/workflows/'*) cat \"$1/workflow.json\"; exit ${4:-0} ;;" \
    "esac" \
    'exit 2' >"$1/gh"
  chmod +x "$1/gh"
  printf '%s\n' "$2" >"$1/runs.json"
  printf '%s\n' "$3" >"$1/workflow.json"
}
# ISO instants relative to THIS clock, so the arms do not rot: computed with the same shim the guard
# uses (box_iso_to_epoch) and its inverse.
now="$(date -u +%s)"
iso_of() { bash -c '. "$1/lib/box.sh"; box_epoch_to_iso "$2"' _ "$HERE" "$1"; }
fresh_iso="$(iso_of $((now - 3600)))"
stale_iso="$(iso_of $((now - 400 * 3600)))"
old_iso="$(iso_of $((now - 400 * 3600)))"

mkgh "$TMP/gh-fresh" "{\"workflow_runs\":[{\"head_sha\":\"aaaa1111bbbb\",\"updated_at\":\"$fresh_iso\",\"html_url\":\"https://example.invalid/run/1\"}]}" '{}'
PATH="$TMP/gh-fresh:$PATH" bash "$ALIVE" --repo o/r >"$TMP/b1.out" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q 'is alive' "$TMP/b1.out" \
  && ok "B1: a recent success certifies the tree half alive, and the check prints the timestamp it used" \
  || bad "B1: a fresh success did not pass (rc=$rc): $(head -2 "$TMP/b1.out")"

mkgh "$TMP/gh-stale" "{\"workflow_runs\":[{\"head_sha\":\"cccc2222dddd\",\"updated_at\":\"$stale_iso\",\"html_url\":\"https://example.invalid/run/2\"}]}" '{}'
PATH="$TMP/gh-stale:$PATH" bash "$ALIVE" --repo o/r >"$TMP/b2.out" 2>&1; rc=$?
[ "$rc" = 1 ] && grep -q 'STALE' "$TMP/b2.out" \
  && ok "B2: a success older than the bound is STALE and FAILS (staleness is itself a failure)" \
  || bad "B2: a stale success did not fail (rc=$rc)"

mkgh "$TMP/gh-never" '{"workflow_runs":[]}' "{\"created_at\":\"$old_iso\"}"
PATH="$TMP/gh-never:$PATH" bash "$ALIVE" --repo o/r >"$TMP/b3.out" 2>&1; rc=$?
[ "$rc" = 1 ] && grep -q 'NEVER completed successfully' "$TMP/b3.out" \
  && ok "B3: a workflow that has NEVER succeeded and predates the bound FAILS — the absence a self-check cannot see" \
  || bad "B3: a never-successful workflow passed (rc=$rc) — the moved assertion could go quiet"

mkgh "$TMP/gh-boot" '{"workflow_runs":[]}' "{\"created_at\":\"$fresh_iso\"}"
PATH="$TMP/gh-boot:$PATH" bash "$ALIVE" --repo o/r >"$TMP/b4.out" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q 'NOTE bootstrap' "$TMP/b4.out" \
  && ok "B4: a just-landed workflow inside its bootstrap window passes WITH a NOTE (the window is named, never silent)" \
  || bad "B4: the bootstrap window did not behave as documented (rc=$rc)"

mkgh "$TMP/gh-broken" '{}' '{}' 1
PATH="$TMP/gh-broken:$PATH" bash "$ALIVE" --repo o/r >"$TMP/b5.out" 2>&1; rc=$?
[ "$rc" = 2 ] && ok "B5: an unreadable Actions API REFUSES (rc 2) — a question it could not answer is not a fresh one" \
  || bad "B5: an API failure produced rc=$rc"

mkgh "$TMP/gh-garbage" '{"workflow_runs":[{"updated_at":"not-a-date"}]}' '{}'
PATH="$TMP/gh-garbage:$PATH" bash "$ALIVE" --repo o/r >"$TMP/b6.out" 2>&1; rc=$?
[ "$rc" = 2 ] && ok "B6: an unparseable timestamp REFUSES (rc 2) instead of becoming a confident age" \
  || bad "B6: a garbage timestamp produced rc=$rc"

mkgh "$TMP/gh-future" "{\"workflow_runs\":[{\"updated_at\":\"$(iso_of $((now + 7200)))\"}]}" '{}'
PATH="$TMP/gh-future:$PATH" bash "$ALIVE" --repo o/r >"$TMP/b7.out" 2>&1; rc=$?
[ "$rc" = 2 ] && ok "B7: a FUTURE timestamp REFUSES (a negative age would sail under every bound forever)" \
  || bad "B7: a future timestamp produced rc=$rc"

# B8/B9 — A 404 IS NOT AN OUTAGE, AND THE TREE ALONE IS NOT THE DISAMBIGUATOR (#4210 review P2).
# A file in THIS tree but not yet in the repository is a landing PR (reding it would red every PR until
# the first merge), and a file in NEITHER is a real absence. But "the file is in the tree" is ALSO true
# on `main`, so on its own it is an UNBOUNDED window: a workflow that landed and never registered would
# read as fresh forever. The BASE answers the second half, so this fixture gives the guard a real base
# to ask (the old arm leaned on the live repo's `origin/main`, which stops being a landing PR the
# moment this change merges — a test that rots into the wrong answer).
mkdir -p "$TMP/gh-404"
printf '%s\n' '#!/usr/bin/env bash' 'echo "gh: Not Found (HTTP 404)" >&2' 'exit 1' >"$TMP/gh-404/gh"
chmod +x "$TMP/gh-404/gh"
B8FIX="$TMP/alive-boot"
mkdir -p "$B8FIX/scripts/lib" "$B8FIX/.github/workflows"
cp "$ALIVE" "$B8FIX/scripts/check-portability-tree-scan-alive.sh"
cp "$HERE/lib/box.sh" "$B8FIX/scripts/lib/box.sh"
b8git() { git -C "$B8FIX" -c user.email=t@example.invalid -c user.name=t "$@" >/dev/null 2>&1; }
b8git init -q
printf 'base\n' >"$B8FIX/README.md"
b8git add README.md
b8git commit -q -m "base: no batch workflow yet"
printf 'name: portability-tree-scan\non:\n  schedule:\n    - cron: "0 3 * * *"\n' >"$B8FIX/.github/workflows/portability-tree-scan.yml"
b8git add .github/workflows/portability-tree-scan.yml
b8git commit -q -m "land the batch workflow"
B8ALIVE="$B8FIX/scripts/check-portability-tree-scan-alive.sh"

PATH="$TMP/gh-404:$PATH" bash "$B8ALIVE" --repo o/r --base HEAD^ >"$TMP/b8.out" 2>&1; rc=$?
if [ "$rc" = 0 ] && grep -q 'NOTE bootstrap' "$TMP/b8.out" && grep -q 'not yet registered' "$TMP/b8.out"; then
  ok "B8: a workflow present in this tree but not yet registered passes WITH a named bootstrap note, and the note names the base that bounds it (the landing PR does not red on its own change)"
else
  bad "B8: the landing-PR case produced rc=$rc: $(head -2 "$TMP/b8.out")"
fi

# B8b — THE SAME 404, BUT THE BASE ALREADY CARRIES THE FILE: that is not a landing PR, it is a
# workflow that landed and never registered, so the window must CLOSE (this is the assertion F3 was
# missing — before the fix, this case was an unconditional exit 0 forever).
PATH="$TMP/gh-404:$PATH" bash "$B8ALIVE" --repo o/r --base HEAD >"$TMP/b8b.out" 2>&1; rc=$?
[ "$rc" = 2 ] && grep -q 'ALREADY ON' "$TMP/b8b.out" \
  && ok "B8b: a 404 for a workflow the BASE already carries REFUSES (rc 2) — a workflow that never registered cannot ride the bootstrap window forever" \
  || bad "B8b: a landed-but-unregistered workflow produced rc=$rc: $(head -2 "$TMP/b8b.out")"

# B8c — THE BASE ITSELF DOES NOT RESOLVE: the question cannot be asked, and an unanswerable question is
# a refusal, never a fresh-looking pass (a silent fallback would answer about a different ref).
PATH="$TMP/gh-404:$PATH" bash "$B8ALIVE" --repo o/r --base definitely-not-a-ref >"$TMP/b8c.out" 2>&1; rc=$?
[ "$rc" = 2 ] && grep -q 'Pass --base' "$TMP/b8c.out" \
  && ok "B8c: an unresolvable --base REFUSES (rc 2) instead of falling back to a different ref" \
  || bad "B8c: an unresolvable base produced rc=$rc: $(head -2 "$TMP/b8c.out")"

PATH="$TMP/gh-404:$PATH" bash "$B8ALIVE" --repo o/r --workflow definitely-absent-workflow.yml >"$TMP/b9.out" 2>&1; rc=$?
[ "$rc" = 2 ] && grep -q 'NOT present in this tree' "$TMP/b9.out" \
  && ok "B9: a workflow that is in NEITHER the repository NOR the tree REFUSES (a deleted workflow cannot ride the bootstrap window)" \
  || bad "B9: an absent workflow produced rc=$rc"

# ── C1..C7. THE WIRING, READ FROM THE PARSED FILES THAT RUN IT ─────────────────────────────────
# ⛔ PARSED NODES, NOT TEXT (#4210 review P2 — MEASURED, not argued). These arms used to `grep -q` the
# YAML SOURCE, and a substring cannot tell a live step from prose: deleting the diff half's `run:` line
# left C2 GREEN on the comment that names it (ci.yml:2002), and commenting out the scope env left C1
# green while the bounded lane went back to the 2356 s tree scan. So the arms now read the STRUCTURE
# with `scripts/workflow-yaml.mjs` — the same parser the lane-parity guards use — and assert that a
# step's `run` COMMAND is the script, and that a step's parsed `env.PORTABILITY_TREE_SCAN` is exactly
# "0". Each arm is paired with the mutant that reverts it (Cn-b), and the mutant KEEPS the script's
# name in the text on purpose: a text grep still matches while the step is dead, which is precisely the
# assertion being replaced.
CI_PRLANE="$REPO_ROOT/.github/workflows/ci.yml"
CI_MAIN="$REPO_ROOT/.github/workflows/ci-main.yml"
BATCH="$REPO_ROOT/.github/workflows/portability-tree-scan.yml"

WF_YAML_MODULE="$REPO_ROOT/scripts/workflow-yaml.mjs"
export WF_YAML_MODULE
WF_PROBE="$TMP/wfprobe.mjs"
cat >"$WF_PROBE" <<'PROBE'
import { readFileSync } from "node:fs";
const { parseWorkflowYaml } = await import(process.env.WF_YAML_MODULE);
const [cmd, file, ...rest] = process.argv.slice(2);
let doc;
try { doc = parseWorkflowYaml(readFileSync(file, "utf8")); }
catch (e) { console.error("parse error: " + e.message); process.exit(3); }
const steps = [];
for (const job of Object.values(doc?.jobs ?? {})) if (Array.isArray(job?.steps)) steps.push(...job.steps);
if (!steps.length) { console.error("no steps parsed"); process.exit(3); }
const cmds = (run) => String(run ?? "").split("\n").map((l) => l.trim()).filter((l) => l && !l.startsWith("#"));
const invokes = (line, script) => {
  const t = line.split(/\s+/);
  if (t[0] !== "bash" && t[0] !== "sh") return false;
  const p = t[1] ?? "";
  return p === script || p.endsWith("/" + script);
};
if (cmd === "step-run") {
  const [script, token] = rest;
  process.exit(steps.some((s) => cmds(s.run).some((l) => invokes(l, script) && (!token || l.includes(token)))) ? 0 : 1);
}
if (cmd === "step-env") {
  const [script, key, value] = rest;
  process.exit(steps.some((s) => cmds(s.run).some((l) => invokes(l, script)) && String(s.env?.[key] ?? "") === value) ? 0 : 1);
}
if (cmd === "scheduled") process.exit(Object.prototype.hasOwnProperty.call(doc?.on ?? {}, "schedule") ? 0 : 1);
process.exit(2);
PROBE
wf() {  # wf <step-run|step-env|scheduled> ... — 0 = asserted, 1 = false, 3 = could not answer
  command -v node >/dev/null 2>&1 || { echo "node is not installed" >"$TMP/wf.err"; return 3; }
  node "$WF_PROBE" "$@" 2>"$TMP/wf.err"
}

# C1 — both bounded lanes switch the whole-tree arm OFF on the shard step, IN THE PARSED ENV.
for f in "$CI_PRLANE" "$CI_MAIN"; do
  b="$(basename "$f")"
  if wf step-env "$f" run-bash-shards.sh PORTABILITY_TREE_SCAN 0; then
    ok "C1: $b runs the shard step with PORTABILITY_TREE_SCAN=0 (parsed step env — the whole-tree arm is off the bounded lane)"
  else
    bad "C1: $b does not switch the whole-tree arm off on the shard step (rc=$?; parsed env, so a commented-out key does not count): $(head -1 "$TMP/wf.err")"
  fi
done

# C2 — both bounded lanes RUN the diff half (the assertion has to still bite).
for f in "$CI_PRLANE" "$CI_MAIN"; do
  b="$(basename "$f")"
  if wf step-run "$f" check-portability-traps-changed.sh; then
    ok "C2: $b runs check-portability-traps-changed.sh (parsed run command — the required lane scans the DIFF)"
  else
    bad "C2: $b never runs the diff half as a step command (rc=$?; a mention in a comment is not a step): $(head -1 "$TMP/wf.err")"
  fi
done

# C3 — both bounded lanes ask the freshness question (the moved half cannot go quiet), AND pass the
# `--base` its 404 branch needs to tell a landing workflow from one that never registered (#4210 P2).
for f in "$CI_PRLANE" "$CI_MAIN"; do
  b="$(basename "$f")"
  if wf step-run "$f" check-portability-tree-scan-alive.sh --base; then
    ok "C3: $b asks whether the whole-tree scan is alive, with the --base that bounds its 404 bootstrap window"
  else
    bad "C3: $b does not run the freshness question with --base (rc=$?; a dead batch job would ride an unbounded 404 window): $(head -1 "$TMP/wf.err")"
  fi
done

# C4 — the batch workflow exists, is scheduled, and runs the TREE scope with the arm DISABLED for the
# arms step. Read from the parsed document, so an unscheduled-but-mentioned workflow cannot pass.
if [ -f "$BATCH" ] && wf scheduled "$BATCH" \
   && wf step-run "$BATCH" check-portability-traps.sh --root \
   && wf step-env "$BATCH" check-portability-traps.test.sh PORTABILITY_TREE_SCAN 0 \
   && wf step-run "$BATCH" check-portability-traps.test.sh; then
  ok "C4: portability-tree-scan.yml is SCHEDULED, runs the tree scope with --root, and runs the arms in the bounded-lane mode (parsed)"
else
  bad "C4: the batch lane is missing, unscheduled, scans no tree, or never runs the arms (parsed; rc=$?): $(head -1 "$TMP/wf.err")"
fi

# C1b/C2b/C3b — THE MUTANTS. Each is the edit the review MEASURED staying green under the text arms.
# The arm passes only when the parsed assertion REDS while the raw-text grep still matches: that is
# what makes it a test of the wiring rather than of the prose.
sed 's|^\( *\)PORTABILITY_TREE_SCAN: "0"$|\1# MUTANT: PORTABILITY_TREE_SCAN: "0"|' "$CI_PRLANE" >"$TMP/mut-c1.yml"
sed 's|^\( *\)run: bash scripts/check-portability-traps-changed.sh$|\1run: ": no-op bash scripts/check-portability-traps-changed.sh"|' "$CI_PRLANE" >"$TMP/mut-c2.yml"
sed 's|^\( *\)run: bash scripts/check-portability-tree-scan-alive.sh --base origin/main$|\1run: ": no-op bash scripts/check-portability-tree-scan-alive.sh --base origin/main"|' "$CI_PRLANE" >"$TMP/mut-c3.yml"
if grep -q 'PORTABILITY_TREE_SCAN: "0"' "$TMP/mut-c1.yml" && ! wf step-env "$TMP/mut-c1.yml" run-bash-shards.sh PORTABILITY_TREE_SCAN 0; then
  ok "C1b: commenting out the scope env (the text survives) still REDS C1 — the arm reads the parsed env, not the string"
else
  bad "C1b: C1 stayed green with the scope env commented out — the arm is still a substring test"
fi
if grep -q 'check-portability-traps-changed.sh' "$TMP/mut-c2.yml" && ! wf step-run "$TMP/mut-c2.yml" check-portability-traps-changed.sh; then
  ok "C2b: replacing the diff step's command with a no-op that still NAMES the script REDS C2 — a mention is not a step"
else
  bad "C2b: C2 stayed green with the diff step's command removed — the arm is still a substring test"
fi
if grep -q 'check-portability-tree-scan-alive.sh' "$TMP/mut-c3.yml" && ! wf step-run "$TMP/mut-c3.yml" check-portability-tree-scan-alive.sh; then
  ok "C3b: replacing the freshness step's command with a no-op that still NAMES the script REDS C3"
else
  bad "C3b: C3 stayed green with the freshness step's command removed — the arm is still a substring test"
fi

# C5 — a batch failure FILES AN ISSUE (a red nobody visits is not a report), and reuses ONE open one.
if grep -q 'gh issue create' "$BATCH" && grep -q 'gh issue list' "$BATCH"; then
  ok "C5: a batch failure opens ONE issue and reuses an open one (no issue-per-run flood)"
else
  bad "C5: the batch lane does not file an issue (or files a new one every run)"
fi

# C6 — the SUITE's own scope gate is the one predicate, and EACH F arm sits BEHIND it.
# ⛔ A COUNT IS A PROXY, NOT THE PROPERTY (#4210 review P2, measured). `uses` used to be
# `-ge 2 && -le 4`, so BOTH directions it names stayed green: deleting F4's gate (`if tree_scan_enabled`
# → `if true`) took the readers 3→2 and the bounded lane silently went back to the tree scan, and
# adding a SECOND copy of the predicate (4 readers) — the "a second copy is a second truth" case its own
# message names — also passed. C6b cannot see either, because it reads only the --scope-self-test branch.
# So the count is pinned EXACTLY and each F body is asserted to sit behind a guard: a count alone can be
# kept at 3 while the F arms are unguarded (delete one guard, add one reader), which is the fail-open
# direction that costs 2356 s in the bounded lane.
defs="$(grep -c 'tree_scan_enabled()' "$SUITE")"
# ⛔ A GUARD LINE, NOT A MENTION: the bare substring `if tree_scan_enabled` also matches the pattern
# this very check carries, so the count would include itself (measured: 4 readers, C6 red on a clean
# tree). Anchored to a whole guard line it counts only real branch sites.
uses="$(grep -c '^[[:space:]]*if tree_scan_enabled; then$' "$SUITE")"
guarded() {  # guarded <unique F-body anchor>: that body's line is inside a tree_scan_enabled guard
  local ln
  ln="$(grep -nF -- "$1" "$SUITE" | head -1 | cut -d: -f1)"
  [ -n "$ln" ] || return 1
  sed -n "$(( ln > 2 ? ln - 2 : 1 )),${ln}p" "$SUITE" | grep -q '^[[:space:]]*if tree_scan_enabled; then$'
}
if [ "$defs" = 1 ] && [ "$uses" = 3 ] \
   && guarded 'real_out="$(bash "$CHECK" --root' && guarded '<<<"$real_out"'; then
  ok "C6: the suite gates F4/F5 through ONE predicate (one definition, $uses readers — the self-test, F4 and F5 — and both F bodies sit behind the guard)"
else
  bad "C6: the suite scope gate is missing, duplicated, or an F arm lost its guard (definitions=$defs readers=$uses; want 1/3 AND both F bodies guarded) — a second copy is a second truth, and an unguarded arm runs the whole-tree scan in the bounded lane"
fi
run_out="$(PORTABILITY_TREE_SCAN=1 bash "$SUITE" --scope-self-test 2>&1)"
skip_out="$(PORTABILITY_TREE_SCAN=0 bash "$SUITE" --scope-self-test 2>&1)"
if grep -q 'F4/F5=RUN' <<<"$run_out" && grep -q 'F4/F5=SKIP' <<<"$skip_out"; then
  ok "C6b: the scope decision is INVERTIBLE and printed for both values (RUN when enabled, SKIP when not)"
else
  bad "C6b: the scope decision did not follow PORTABILITY_TREE_SCAN (run='$run_out' skip='$skip_out')"
fi

# C7 — THE BATCH LANE'S ISSUE TITLE PARSES WHAT THE DETECTOR ACTUALLY EMITS (#4210 review P2).
# `scan-out/findings.txt` is the detector's STDOUT, and `hit()` writes `path<TAB>line<TAB>rule<TAB>
# replacement` (check-portability-traps.sh:1729). The title parser used `-F:` / `-F': '`, so a row whose
# REPLACEMENT contains a colon — the shipped `date-d-gnu` row does — produced a title carrying tabs and
# a row fragment, and a row without `": "` rendered `unknown` for a file and rule that are right there
# in columns 1 and 3. This arm RUNS the two programs the workflow ships (extracted from the workflow
# itself, so there is no second copy to drift) against a row in the emitted format, and then runs the
# PRE-FIX programs on the same row to prove the arm can tell the two apart.
title_line="$(grep -F 'first_file=' "$BATCH" | head -1)"
rule_line="$(grep -F 'first_rule=' "$BATCH" | head -1)"
sep="$(printf '%s' "$title_line" | cut -d"'" -f2)"
file_prog="$(printf '%s' "$title_line" | cut -d"'" -f4)"
rule_prog="$(printf '%s' "$rule_line" | cut -d"'" -f4)"
printf 'scripts/foo.sh\t142\tdate-d-gnu\tBSD: `date -r <epoch>`; portable: box_epoch_to_iso\n' >"$TMP/findings-row.txt"
got_file="$(awk -F"$sep" "$file_prog" "$TMP/findings-row.txt" 2>/dev/null)"
got_rule="$(awk -F"$sep" "$rule_prog" "$TMP/findings-row.txt" 2>/dev/null)"
bad_file="$(awk -F: 'NF>=2 { print $1; exit }' "$TMP/findings-row.txt" 2>/dev/null)"
if [ "$got_file" = "scripts/foo.sh" ] && [ "$got_rule" = "date-d-gnu" ] && [ "$bad_file" != "scripts/foo.sh" ]; then
  ok "C7: the batch issue title reads the detector's TAB row — file and rule are column-accurate, and a colon inside the REPLACEMENT cannot split the row"
else
  bad "C7: the batch title parser does not read the emitted format (file='$got_file' rule='$got_rule', pre-fix file='$bad_file'; want 'scripts/foo.sh' / 'date-d-gnu')"
fi

printf '\nportability-scope.test: %d passed, %d failed, %d skipped (%s)\n' "$PASS" "$FAIL" "$SKIP" "$OS"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
