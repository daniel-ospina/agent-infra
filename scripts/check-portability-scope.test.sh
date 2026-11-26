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
#      C5..C10 go one step further and RUN the shipped reporting step against a real detector run: the
#      issue it files, the title it gives it, and what it does when the verdict line is missing, when
#      the open-issue READ fails (it must never file a peer) and when the WRITE fails (it must never
#      claim a report it did not publish).
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

# A6a..A6d — THE WRAPPER'S OTHER REFUSAL SITES, EACH DRIVEN BY ITS OWN STUB (review P2, measured).
# ⛔ WHY THESE EXIST: AN EARLIER REVIEW CYCLE ON THIS PR (that cycle's `F2`, not an arm of the F-section —
# the F arms live in `check-portability-traps.test.sh` and are unrelated to these) replaced A6's original
# stub (which refused EVERY invocation) rather than duplicating it, so the site that stub happened to
# reach — the `--print-targets` guard —# lost its only invocation, and the EMPTY-set guard and the failed-`git diff` guard never had one. The
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

# A6d — THE DETECTOR'S OWN EMPTY-SET REFUSAL (`check-portability-traps.sh:1756-1762`), NOT THE
# WRAPPER'S (review P3, MEASURED). A6a/A6b drive sites in `check-portability-traps-changed.sh` with a
# STUB detector; the publisher's own guard — "an EMPTY scan set is a refusal, never a clean list" on the
# `--print-targets` path — had no arm at all, so deleting it left every arm green. Per mutation rule 3
# that reads as covered while unproven. This arm runs the REAL detector over a real git repo whose scan
# set is genuinely empty (a tracked README is not shell), so the guard is what produces the rc.
A6D_TREE="$TMP/emptyscan"
mkdir -p "$A6D_TREE"
a6dgit() { git -C "$A6D_TREE" -c user.email=t@example.invalid -c user.name=t "$@" >/dev/null 2>&1; }
a6dgit init -q
printf 'not shell\n' >"$A6D_TREE/README.md"
a6dgit add README.md
a6dgit commit -q -m "no shell files at all"
bash "$CHECK" --print-targets --root "$A6D_TREE" >"$TMP/a6d.out" 2>&1; rc=$?
if [ "$rc" = 2 ] && grep -q 'target set is EMPTY' "$TMP/a6d.out"; then
  ok "A6d: the DETECTOR's own empty scan set REFUSES BY NAME (rc 2) on --print-targets — an empty published set is never a clean list"
else
  bad "A6d: an empty scan set produced rc=$rc without naming the refusal (want rc 2 + 'target set is EMPTY'): $(head -2 "$TMP/a6d.out")"
fi
# A6d-b — THE MUTANT: the same run with the guard line DELETED must stop refusing. Without this the
# arm could be passing on some other guard, which is exactly how a deletion reads as covered.
mkdir -p "$TMP/a6dmut"
sed '/the target set is EMPTY/d' "$CHECK" >"$TMP/a6dmut/check-portability-traps.sh"
mut_out="$(bash "$TMP/a6dmut/check-portability-traps.sh" --print-targets --root "$A6D_TREE" 2>&1)"; mut_rc=$?
if [ "$mut_rc" = 0 ] && [ -z "$mut_out" ]; then
  ok "A6d-b: deleting that one guard turns the empty set into a SILENT SUCCESS (rc=0, no output) — A6d reds on the deletion, not on a neighbour"
else
  bad "A6d-b: the guard-deleted mutant still produced rc=$mut_rc / '$(printf '%s' "$mut_out" | head -1)' — A6d is not the arm that sees this deletion"
fi

# ── B1..B7b. THE TREE HALF CANNOT GO QUIET ──────────────────────────────────────────────────────
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

# B7b — THE SAME REFUSAL IN THE NEVER-SUCCEEDED BRANCH (review P3, MEASURED). B7 covers the
# last-success timestamp; this covers the workflow's `created_at`, which used to CLAMP a negative age to
# 0 — i.e. a registration timestamped in the future GRANTED the bootstrap window, while the branch 30
# lines above refused the identical input. #4210 acceptance 4 says a future timestamp is a refusal.
mkgh "$TMP/gh-future-created" '{"workflow_runs":[]}' "{\"created_at\":\"$(iso_of $((now + 7200)))\"}"
PATH="$TMP/gh-future-created:$PATH" bash "$ALIVE" --repo o/r >"$TMP/b7b.out" 2>&1; rc=$?
[ "$rc" = 2 ] && grep -q 'in the FUTURE' "$TMP/b7b.out" \
  && ok "B7b: a FUTURE registration date REFUSES (rc 2) instead of being clamped into a bootstrap window" \
  || bad "B7b: a future created_at produced rc=$rc (want 2): $(head -2 "$TMP/b7b.out")"

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

# ── C1..C10. THE WIRING, READ FROM THE PARSED FILES THAT RUN IT ────────────────────────────────
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
// step-run-text — emit the whole `run` text of the step whose LIVE (comment-stripped) command lines
// contain <token>. The comment-stripping is the assertion as much as the locator: a filing line that
// was commented out no longer selects a step, so the caller cannot extract-and-run a dead step.
if (cmd === "step-run-text") {
  const [token] = rest;
  const s = steps.find((s) => cmds(s.run).some((l) => l.includes(token)));
  if (!s) process.exit(1);
  process.stdout.write(String(s.run));
  process.exit(0);
}
if (cmd === "step-env") {
  const [script, key, value] = rest;
  process.exit(steps.some((s) => cmds(s.run).some((l) => invokes(l, script)) && String(s.env?.[key] ?? "") === value) ? 0 : 1);
}
if (cmd === "scheduled") process.exit(Object.prototype.hasOwnProperty.call(doc?.on ?? {}, "schedule") ? 0 : 1);
process.exit(2);
PROBE
wf() {  # wf <step-run|step-run-text|step-env|scheduled> ... — 0 = asserted, 1 = false, 3 = could not answer
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

# ── C5, C5b. THE BATCH LANE'S REPORT — RUN, NOT GREPPED ────────────────────────────────────────────
# ⛔ A SUBSTRING IS NOT A REPORT (#4210 review P2, MEASURED). C5 was
#     `grep -q 'gh issue create' "$BATCH" && grep -q 'gh issue list' "$BATCH"`
# and commenting the filing line out left it GREEN — so the one thing the batch lane exists for
# ("a red nobody reads is not a report") had no arm that could fail. The C-section header's own rule
# ("a substring cannot tell a live step from prose") was applied to C1/C2/C3 and never to C5.
#
# So this section does not read the workflow at all: it EXTRACTS the shipped reporting step from the
# PARSED document and RUNS it against a real detector run, with a `gh` shim that records what it
# filed. What is asserted is the artifact a tracker list, a search and a notification actually see:
# the `gh issue create --title` the step emitted. That is also the only way to test the title at all
# (C7) — the parser's input is a detector stream, and the arm has to produce that stream, not guess it.
C7DIR="$TMP/c7"
RISE_TREE="$C7DIR/tree"
mkdir -p "$RISE_TREE/scripts" "$C7DIR/shim"
# TWO FILES, ONE RULE, ONE GRANDFATHERED. The rise is then decided by PATH alone, which is what makes
# the POPULATION defect visible: a report reading the full finding list names the FIRST row
# (`aa-grandfathered.sh`), while the rise is the SECOND (`zz-rise.sh`). With different rules a
# population bug could hide behind a delimiter bug, and one fix would appear to cure the other.
printf '%s\n' '#!/usr/bin/env bash' 'n="$(nproc)"' >"$RISE_TREE/scripts/aa-grandfathered.sh"
printf '%s\n' '#!/usr/bin/env bash' 'n="$(nproc)"' >"$RISE_TREE/scripts/zz-rise.sh"
c7git() { git -C "$RISE_TREE" "$@" >/dev/null 2>&1; }
( cd "$RISE_TREE" && git init -q . )
c7git add -A
c7git -c user.email=t@example.invalid -c user.name=t commit -q -m base
# the detector's own baseline for the fixture, then everything EXCEPT the second file is kept — so
# `zz-rise.sh` is a rise by construction (baseline=0 live=1), not by hand-written fixture text.
bash "$CHECK" --root "$RISE_TREE" --emit-baseline >"$C7DIR/base-all.tsv" 2>/dev/null
grep -v 'zz-rise' "$C7DIR/base-all.tsv" >"$C7DIR/base.tsv"
c7_grandfathered="$(grep -c 'aa-grandfathered' "$C7DIR/base.tsv" || true)"
# THE INPUT, PRODUCED THE WAY CI PRODUCES IT: the same `--root` scan, stdout → findings, stderr →
# verdict, rc → the record the reporting step fails closed on.
C7SCAN="$C7DIR/scan-out"
mkdir -p "$C7SCAN"
c7rc=0
bash "$CHECK" --root "$RISE_TREE" --baseline "$C7DIR/base.tsv" >"$C7SCAN/findings.txt" 2>"$C7SCAN/verdict.txt" || c7rc=$?
printf '%s\n' "$c7rc" >"$C7SCAN/rc.txt"
c7_findings_n="$(grep -c . "$C7SCAN/findings.txt" || true)"
c7_rise_n="$(grep -c ': baseline=[0-9]' "$C7SCAN/verdict.txt" || true)"
if [ "$c7rc" = 1 ] && [ "$c7_findings_n" = 2 ] && [ "$c7_rise_n" = 1 ] && [ "$c7_grandfathered" = 1 ]; then
  ok "C5a: the fixture REPRODUCES the batch input by running the detector (rc=1, 2 live findings, 1 rising row, 1 grandfathered) — the report arms below have a real population"
else
  bad "C5a: the fixture does not reproduce a rise (rc=$c7rc findings=$c7_findings_n rise_rows=$c7_rise_n grandfathered=$c7_grandfathered; want rc=1 findings=2 rise_rows=1 grandfathered=1) — a report arm over this input would test nothing"
fi

cat >"$C7DIR/shim/gh" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "gh $*" >>"${GH_CALLS:-/dev/null}"
# GH_FAIL names the subcommand that FAILS, so the report arms can drive a failed READ and a failed
# WRITE separately (#4210 review P2). Without it the shim always succeeded, and no arm could see that
# the step treated a failed `issue list` as "no open issue" and filed a PEER.
case "${GH_FAIL:-}" in
  "$1 $2") echo "shim: gh $1 $2 FAILED (GH_FAIL=$GH_FAIL)" >&2; exit 1 ;;
esac
case "$1 $2" in
  "issue list") exit 0 ;;
  "issue create") printf 'https://example.invalid/1\n' ;;
  "label create") : ;;
esac
exit 0
SHIM
chmod +x "$C7DIR/shim/gh"

run_report() {  # run_report <report.sh> <dir> [<scan-out src>] — runs the shipped step; echoes its rc
  local script="$1" dir="$2" src="${3:-$C7SCAN}"
  mkdir -p "$dir/scan-out"
  cp "$src/findings.txt" "$src/verdict.txt" "$src/rc.txt" "$dir/scan-out/" 2>/dev/null
  : >"$dir/gh-calls.txt"
  : >"$dir/summary.md"
  ( cd "$dir" \
      && PATH="$C7DIR/shim:$PATH" GH_CALLS="$dir/gh-calls.txt" GH_FAIL="${GH_FAIL:-}" \
         DISPATCH_REASON="${DISPATCH_REASON:-}" \
         GITHUB_SHA=deadbeefcafe GITHUB_SERVER_URL=https://ci.example \
         GITHUB_REPOSITORY=o/r GITHUB_RUN_ID=7 GITHUB_WORKFLOW=portability-tree-scan.yml \
         GITHUB_STEP_SUMMARY="$dir/summary.md" GH_TOKEN=shim \
         bash "$script" ) >"$dir/out.log" 2>&1
  echo "$?"
}

title_of() {  # title_of <dir> — the --title the step handed to `gh issue create`, verbatim
  grep '^gh issue create ' "$1/gh-calls.txt" 2>/dev/null \
    | sed -n 's/^gh issue create --title //; s/ --label .*$//p' | head -1
}

SHIP="$C7DIR/report.sh"
c5_extracted=0
if wf step-run-text "$BATCH" 'gh issue create' >"$SHIP" 2>"$TMP/wf.err" && grep -q . "$SHIP"; then
  c5_extracted=1
fi

if [ "$c5_extracted" = 1 ]; then
  ship_rc="$(run_report "$SHIP" "$C7DIR/ship")"
  if grep -q '^gh issue create ' "$C7DIR/ship/gh-calls.txt" && grep -q '^gh issue list ' "$C7DIR/ship/gh-calls.txt"; then
    ok "C5: the batch lane FILES an issue when the scan reds, and asks for an open one first (the shipped step, extracted from the parsed workflow and RUN against a real detector run — a commented-out filing line cannot pass)"
  else
    bad "C5: the shipped reporting step ran (rc=$ship_rc) and did not file: $(tail -2 "$C7DIR/ship/out.log" 2>/dev/null)"
  fi
else
  bad "C5: the parsed workflow has no step whose LIVE (comment-stripped) command line files an issue — extracting it is the first half of the assertion: $(head -1 "$TMP/wf.err" 2>/dev/null)"
fi

# C5b — THE MUTANT. Replace the filing command with a NO-OP that still CARRIES the phrase, and the
# RUN must stop filing. The no-op shape (not a comment) matters: commenting the line out leaves the
# enclosing `if` with an EMPTY branch, so bash exits 2 on a SYNTAX error — the step would then file
# nothing for a reason that has nothing to do with the arm, and C5b would pass on a parse failure. This
# mutant stays VALID BASH that runs to the end (rc 1 asserted below), so the only difference is that the
# report is dead while a raw grep still matches it — precisely how the old substring C5 stayed green.
# ⛔ THE SED MUST REACH THE SHIPPED SHAPE, AND SAY SO WHEN IT DOES NOT (#4210 review, MEASURED). The
# filing call now sits inside `if gh issue create …; then` (the write's exit code is checked so the
# final line can report what actually happened), so the old anchored pattern STOPPED MATCHING — the
# mutant became a byte-identical copy, the step filed as usual, and C5b failed while blaming the arm.
# The `if `/`if ! ` prefix is therefore part of the pattern, and `cmp` proves the substitution landed.
MUT="$C7DIR/report-noissue.sh"
if [ "$c5_extracted" = 1 ]; then
  sed -e 's|^\( *\)if gh issue create |\1if : no-op gh issue create |' \
      -e 's|^\( *\)gh issue create |\1: no-op gh issue create |' "$SHIP" >"$MUT"
  mut_rc="$(run_report "$MUT" "$C7DIR/mut")"
  if cmp -s "$SHIP" "$MUT"; then
    bad "C5b: the mutant is BYTE-IDENTICAL to the shipped step — the sed pattern no longer matches the filing call, so this arm tested nothing (fix the pattern; do not trust a green here)"
  elif grep -q 'gh issue create' "$MUT" && [ "$mut_rc" = 1 ] && ! grep -q '^gh issue create ' "$C7DIR/mut/gh-calls.txt"; then
    ok "C5b: disabling the filing command (valid bash that keeps the TEXT, so a raw grep still matches) makes the step file NOTHING while still failing the run (rc=$mut_rc) — C5 is a run, not a substring"
  else
    bad "C5b: the report path was disabled and C5 could not tell — mutant rc=$mut_rc (want 1, i.e. it ran to the end rather than dying at a parse error), filed: $(grep -c 'issue create' "$C7DIR/mut/gh-calls.txt" 2>/dev/null) issue(s)"
  fi
else
  bad "C5b: skipped the mutant because the shipped reporting step could not be extracted (see C5)"
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

# C7 — THE BATCH LANE'S ISSUE TITLE NAMES THE RISE, READ FROM A REAL DETECTOR RUN.
# ⛔ THE PREVIOUS C7 WAS VACUOUS, AND THAT IS THE WORST KIND OF ARM (#4210 review P2, MEASURED). It
# extracted the title's two awk programs from the workflow and fed them a HAND-WRITTEN tab row:
#     printf 'scripts/foo.sh\t142\tdate-d-gnu\tBSD: `date -r <epoch>`; ...'
# The detector never emits that row — its PUBLISHER reformats `hit()`'s tab row at
# check-portability-traps.sh:1845 into `path:line: rule — use replacement`. So C7 printed PASS over a
# parser that returned empty on every real run, and the issue title shipped `unknown unknown` with a
# count of the whole live finding list (144 measured) instead of the rise (1). Everything below is read
# off the ACTUAL `gh issue create --title` from C5's run, which is the string a tracker would show.
if [ "$c5_extracted" = 1 ]; then
  c7_title="$(title_of "$C7DIR/ship")"
  c7_ok=0
  case "$c7_title" in
    *"1 new trap(s)"*scripts/zz-rise.sh*cpu-count-single-mechanism*) c7_ok=1 ;;
  esac
  # a title that names the GRANDFATHERED row, or falls back to `unknown`, is the defect this arm exists
  # for — regardless of anything else it gets right.
  case "$c7_title" in
    *unknown*|*aa-grandfathered*) c7_ok=0 ;;
  esac
  if [ -n "$c7_title" ] && [ "$c7_ok" = 1 ]; then
    ok "C7: the batch issue title names the RISE — its file and rule and its count ('$c7_title'), from the detector's own output rather than the full live finding list"
  else
    bad "C7: the batch issue title does not name the rise (got '$c7_title'; want 'portability(tree): 1 new trap(s) — first: scripts/zz-rise.sh cpu-count-single-mechanism', never 'unknown' and never the grandfathered row)"
  fi
else
  bad "C7: skipped — the shipped reporting step could not be extracted (see C5), so the title was never produced"
fi

# C7b — NON-VACUITY: the PRE-FIX parsers, replayed on the SAME real run. If any of these ever starts
# reading the rise correctly, the fixture has lost the power to tell the shipped parser from the broken
# ones and C7 proves nothing — so that is a FAILURE of this arm, not a curiosity.
if [ "$c5_extracted" = 1 ] && [ -s "$C7SCAN/findings.txt" ]; then
  pf_tab="$(awk -F'\t' 'NF>=3 { print $1; exit }' "$C7SCAN/findings.txt")"
  pf_n="$(grep -c . "$C7SCAN/findings.txt" || true)"
  pf_colon="$(awk -F: 'NF>=2 { print $1; exit }' "$C7SCAN/findings.txt")"
  if [ -z "$pf_tab" ] && [ "$pf_n" != "$c7_rise_n" ] && [ "$pf_colon" = "scripts/aa-grandfathered.sh" ]; then
    ok "C7b: the PRE-FIX parsers MISREAD this same real run (tab parse='' → 'unknown'; count=$pf_n where the rise is $c7_rise_n; colon parse='$pf_colon', the GRANDFATHERED row) — C7 can tell the shipped parser from all three"
  else
    bad "C7b: the pre-fix parsers read the real run correctly (tab='$pf_tab' colon='$pf_colon' count=$pf_n rise=$c7_rise_n) — the fixture lost its discriminating power, so C7 proves nothing"
  fi
else
  bad "C7b: skipped — no real detector output to replay the pre-fix parsers against (see C5a)"
fi

# C7c — A RISE THE REPORT CANNOT PARSE IS REPORTED AS SUCH, never as `0 new trap(s)`. rc=1 is the
# detector's own statement that the rise is non-empty, so zero parsed rows means the ROW FORMAT moved.
# Silently filing "0 new trap(s)" would be a false report about a real red — the one thing this title
# must not do — so the step says so in the title AND in a warning annotation.
if [ "$c5_extracted" = 1 ]; then
  C7BROKEN="$C7DIR/unparsed"
  mkdir -p "$C7BROKEN"
  grep -v ': baseline=[0-9]' "$C7SCAN/verdict.txt" >"$C7BROKEN/verdict.txt"
  cp "$C7SCAN/findings.txt" "$C7BROKEN/findings.txt"
  printf '1\n' >"$C7BROKEN/rc.txt"
  broken_rc="$(run_report "$SHIP" "$C7DIR/brokenrun" "$C7BROKEN")"
  broken_title="$(title_of "$C7DIR/brokenrun")"
  brk_ok=0
  case "$broken_title" in
    *"could not parse"*) brk_ok=1 ;;
    *"0 new trap(s)"*) brk_ok=0 ;;
  esac
  if [ "$brk_ok" = 1 ] && [ "$broken_rc" = 1 ]; then
    ok "C7c: a rise whose rows the report cannot parse says so in the title and still fails the run (rc=$broken_rc) — an unparseable rise is never filed as '0 new trap(s)'"
  else
    bad "C7c: an unparseable rise filed '$broken_title' (step rc=$broken_rc; want a title containing 'could not parse', never '0 new trap(s)')"
  fi
else
  bad "C7c: skipped — the shipped reporting step could not be extracted (see C5)"
fi

# C8/C8b — THE CLEAN VERDICT LINE IS ASSERTED WHERE "CLEAN" IS CONCLUDED (#4210 review P2, MEASURED).
# The suite's F5 ("a clean run PRINTS its verdict line; silence is never a pass") rides on F4's `--root`
# run. This job runs that suite with `PORTABILITY_TREE_SCAN: 0`, so F4 and F5 both SKIP here, and both
# bounded lanes run the same suite with the arm off — the assertion was REMOVED rather than MOVED, and
# the job's clean verdict rested on `rc=0` alone. A detector that exits 0 while printing no verdict was
# therefore reported CLEAN. The fix puts the same assertion in the shipped reporting step; these arms
# RUN that step, because a `grep` in the YAML is not the step.
if [ "$c5_extracted" = 1 ]; then
  # C8 — rc=0 WITH NO VERDICT LINE: the step must FAIL CLOSED, and must not claim a clean tree.
  CSILENT="$C7DIR/silent"
  mkdir -p "$CSILENT"
  printf '0\n' >"$CSILENT/rc.txt"
  printf 'the detector printed nothing at all\n' >"$CSILENT/findings.txt"
  printf 'nothing at all\n' >"$CSILENT/verdict.txt"
  silent_rc="$(run_report "$SHIP" "$C7DIR/silentrun" "$CSILENT")"
  if [ "$silent_rc" = 1 ] && grep -q 'NO clean verdict line' "$C7DIR/silentrun/out.log" \
     && ! grep -q 'tree clean at' "$C7DIR/silentrun/out.log"; then
    ok "C8: an rc=0 run that printed NO clean verdict line FAILS the reporting step (rc=$silent_rc) — silence is never a pass, and the assertion moved with the arm"
  else
    bad "C8: a silent rc=0 run produced rc=$silent_rc (want 1) — a detector that exits 0 without a verdict is reported CLEAN: $(tail -2 "$C7DIR/silentrun/out.log") "
  fi

  # C8b — THE CONTROL, AND THE NON-VACUITY GUARD IN THE OTHER DIRECTION: a REAL clean detector run
  # (the same fixture, with the full baseline so nothing rises) must still pass rc=0 and file NOTHING.
  # Without this, an assertion written to always fail — or one matching the wrong string — would pass C8.
  CCLEAN="$C7DIR/clean"
  mkdir -p "$CCLEAN"
  c8b_detector_rc=0
  bash "$CHECK" --root "$RISE_TREE" --baseline "$C7DIR/base-all.tsv" >"$CCLEAN/findings.txt" 2>"$CCLEAN/verdict.txt" || c8b_detector_rc=$?
  printf '%s\n' "$c8b_detector_rc" >"$CCLEAN/rc.txt"
  clean_rc="$(run_report "$SHIP" "$C7DIR/cleanrun" "$CCLEAN")"
  if [ "$c8b_detector_rc" = 0 ] && [ "$clean_rc" = 0 ] \
     && grep -q 'tree clean at' "$C7DIR/cleanrun/out.log" \
     && ! grep -q '^gh issue create ' "$C7DIR/cleanrun/gh-calls.txt"; then
    ok "C8b: a REAL clean detector run still passes the step (rc=0), announces the clean tree and files NOTHING — the new assertion is not a blanket red"
  else
    bad "C8b: a real clean run behaved wrongly (detector rc=$c8b_detector_rc step rc=$clean_rc; want 0/0, clean line and no issue): $(tail -2 "$C7DIR/cleanrun/out.log")"
  fi

  # C9 — A FAILED `gh issue list` MUST NOT BECOME A PEER ISSUE (#4210 review P2, MEASURED). Under
  # `set -uo pipefail` (no `-e`) the unchecked read yielded an EMPTY `existing`, which took the `else`
  # and filed a brand-new PEER — the one thing this issue body and the fleet's hard rule forbid. Every
  # other read in this change refuses on failure; this arm makes this one do the same.
  listfail_rc="$(GH_FAIL='issue list' run_report "$SHIP" "$C7DIR/listfail")"
  if [ "$listfail_rc" = 1 ] \
     && ! grep -q '^gh issue create ' "$C7DIR/listfail/gh-calls.txt" \
     && grep -q 'refusing to file a PEER' "$C7DIR/listfail/out.log"; then
    ok "C9: a FAILED open-issue list files NOTHING and names the refusal (rc=$listfail_rc) — a failed read is not 'no open issue'"
  else
    bad "C9: a failed 'gh issue list' produced rc=$listfail_rc and filed $(grep -c '^gh issue create ' "$C7DIR/listfail/gh-calls.txt" 2>/dev/null) peer issue(s) — want rc 1, zero creates, refusal named: $(tail -2 "$C7DIR/listfail/out.log")"
  fi

  # C10 — A FAILED WRITE MUST NOT BE REPORTED AS A FILED REPORT (#4210 review P2). The final line used
  # to assert "filed/updated an issue" unconditionally, so the step's own record of whether the tracker
  # got the report carried no information — and the report is this batch lane's single deliverable.
  createfail_rc="$(GH_FAIL='issue create' run_report "$SHIP" "$C7DIR/createfail")"
  if [ "$createfail_rc" = 1 ] \
     && grep -q '^gh issue create ' "$C7DIR/createfail/gh-calls.txt" \
     && grep -q 'the report was NOT filed' "$C7DIR/createfail/out.log" \
     && ! grep -q 'FILED an issue' "$C7DIR/createfail/out.log"; then
    ok "C10: a FAILED 'gh issue create' is reported as NOT filed (rc=$createfail_rc) — the step no longer asserts a report that may not exist"
  else
    bad "C10: a failed create produced rc=$createfail_rc and the step still described the report as filed: $(tail -2 "$C7DIR/createfail/out.log")"
  fi
  # C11 — THE DISPATCH REASON IS RECORDED, BECAUSE THE INPUT PROMISES IT IS (#4210 review P3, MEASURED).
  # `on.workflow_dispatch.inputs.reason` said "recorded in the run summary" and NO STEP READ IT, so the
  # description was a claim about nothing. This drives it through the shipped step and reads the summary.
  dispatch_rc="$(DISPATCH_REASON='investigating the rise from run 7' run_report "$SHIP" "$C7DIR/reasonrun")"
  if grep -q '| reason | investigating the rise from run 7 |' "$C7DIR/reasonrun/summary.md" 2>/dev/null; then
    ok "C11: a workflow_dispatch reason is WRITTEN INTO THE RUN SUMMARY by the shipped step (rc=$dispatch_rc) — the input's own description is now true"
  else
    bad "C11: the dispatch reason was not recorded in the run summary — the input's description is still a claim about nothing: $(head -3 "$C7DIR/reasonrun/summary.md" 2>/dev/null)"
  fi

  # C12 — rc=1 IS NOT ALWAYS A RISE (#4210 review P3, MEASURED). `check-portability-traps.sh:1974-1978`
  # exits 1 for a JUSTIFICATION-LESS BASELINE ROW and does so BEFORE the NEW path (:1980) — no
  # `baseline=` row is printed at all. That was titled "a rise the report could not parse", i.e. the ROW
  # FORMAT was blamed for a different, real failure. The input here is produced by the REAL detector
  # from a baseline whose column 4 is blank, so the discriminator is tested against the detector's own
  # message rather than a hand-copied string.
  CNOJUST="$C7DIR/nojust"
  mkdir -p "$CNOJUST"
  awk -F'\t' 'BEGIN{OFS="\t"} /^#/ {print; next} NF>=4 {$4=""; print; next} {print}' "$C7DIR/base.tsv" >"$C7DIR/base-nojust.tsv"
  c12_rc=0
  bash "$CHECK" --root "$RISE_TREE" --baseline "$C7DIR/base-nojust.tsv" >"$CNOJUST/findings.txt" 2>"$CNOJUST/verdict.txt" || c12_rc=$?
  printf '%s\n' "$c12_rc" >"$CNOJUST/rc.txt"
  nojust_rc="$(run_report "$SHIP" "$C7DIR/nojustrun" "$CNOJUST")"
  nojust_title="$(title_of "$C7DIR/nojustrun")"
  if [ "$c12_rc" = 1 ] && grep -q 'carry NO justification' "$CNOJUST/verdict.txt" \
     && ! grep -q 'baseline=[0-9]' "$CNOJUST/verdict.txt" \
     && case "$nojust_title" in *justification*) true ;; *) false ;; esac \
     && case "$nojust_title" in *"could not parse"*) false ;; *) true ;; esac \
     && [ "$nojust_rc" = 1 ] \
     && ! grep -q 'reported a rise' "$C7DIR/nojustrun/issue-body.md"; then
    ok "C12: a justification-less baseline row (rc=1, NO rise rows) is reported as ITS OWN cause, not as an unparseable rise ('$nojust_title')"
  else
    bad "C12: the justification-less case was mis-diagnosed (detector rc=$c12_rc title='$nojust_title' step rc=$nojust_rc; want a title naming the justification, never 'could not parse', and a body that does not claim a rise)"
  fi

  # C12b — rc>2 IS A REFUSAL, AND THE ISSUE BODY MUST NOT OPEN BY CLAIMING A RISE (#4210 review P3). A
  # reader of the tracker got a false description of the incident, because the body's first sentence was
  # unconditional prose rather than the incident the run actually measured.
  CREF="$C7DIR/refused"
  mkdir -p "$CREF"
  printf '2\n' >"$CREF/rc.txt"
  printf 'the scan could not read its target set\n' >"$CREF/findings.txt"
  printf '❌ the target set is EMPTY — refusing to report a CLEAN over zero files\n' >"$CREF/verdict.txt"
  ref_rc="$(run_report "$SHIP" "$C7DIR/refrun" "$CREF")"
  ref_title="$(title_of "$C7DIR/refrun")"
  if [ "$ref_rc" = 1 ] && case "$ref_title" in *REFUSED*) true ;; *) false ;; esac \
     && ! grep -q 'reported a rise' "$C7DIR/refrun/issue-body.md" \
     && grep -q 'REFUSED' "$C7DIR/refrun/issue-body.md"; then
    ok "C12b: a REFUSED run (rc=2) files a body that says it was refused and does NOT claim a rise (title='$ref_title')"
  else
    bad "C12b: the rc=2 incident was described as a rise (title='$ref_title' step rc=$ref_rc) — the tracker got a false description"
  fi
else
  bad "C8/C8b/C9/C10/C11/C12: skipped — the shipped reporting step could not be extracted (see C5)"
fi

printf '\nportability-scope.test: %d passed, %d failed, %d skipped (%s)\n' "$PASS" "$FAIL" "$SKIP" "$OS"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
