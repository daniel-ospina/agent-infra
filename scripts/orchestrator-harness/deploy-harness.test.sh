#!/usr/bin/env bash
# deploy-harness.test.sh — the regression contract for agent-infra#2041.
#
# The issue: `bg/finish.sh` deployed with a bare `cp -R`, ignored its rc, and then notified
# "convergence COMPLETE … $(ls "$O"/*.sh | wc -l) scripts" unconditionally. On a box whose checkout
# pre-dated the harness the `cp` returned 1, the deploy copied NOTHING, and the notification still
# reported the previous deployment's file count as this deploy's evidence. `gh-limit.py`, the
# `gh-limit/` shim and six reaper scripts were missing from a deployment everybody believed current.
#
# This suite drives the SHIPPED `deploy-harness.sh` against scratch sources and scratch runtimes. It
# asserts the behaviours the issue's Indicators name, and — the part that matters — it asserts them
# in the shape that was MEASURED, not a convenient one:
#
#   * a source directory that does not exist FAILS, in a runtime that is already full of scripts
#     (the 30-file pre-seeded target is the measured false-positive: "there are files there, so the
#     deploy must have worked");
#   * a deploy that copies nothing can never emit a success verdict;
#   * a copy that fails for ONE file is a FAILURE — partial is not success, and the count reported is
#     this run's, never the target's;
#   * a copy that "succeeds" but does not match the source is a FAILURE (the verification gate is
#     load-bearing, not decorative);
#   * every failing path notifies FAILURE, and no failing path notifies success;
#   * a preflight refusal leaves the target BYTE-IDENTICAL — a bad deploy changes nothing;
#   * a good deploy lands subdirectories (`gh-rest/gh`, `gh-limit/gh`, `retired/*.sh`), replaces a
#     stale file, preserves the executable bit, and does not disturb unrelated runtime files.
#
# Run: bash scripts/orchestrator-harness/deploy-harness.test.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY="${DEPLOY_UNDER_TEST:-$HERE/deploy-harness.sh}"

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }
say_case() { echo; echo "── $1 ──"; }

T="$(mktemp -d "${TMPDIR:-/tmp}/deploy-harness-test.XXXXXX")"
cleanup() { rm -rf "$T"; }
trap cleanup EXIT

[ -f "$DEPLOY" ] && ok "shipped deploy helper present: $(basename "$DEPLOY")" || { bad "missing $DEPLOY"; exit 1; }
[ -x "$DEPLOY" ] || bad "shipped deploy helper is not executable"
bash -n "$DEPLOY" 2>/dev/null && ok "deploy helper parses" || bad "deploy helper does not parse"

REAL_CP="$(command -v cp)"
REAL_CMP="$(command -v cmp)"
# ⛔ THE HASHER IS RESOLVED ONCE AND IS MANDATORY. `shasum -a 256` was hardcoded with no fallback, so
# on a host without it every hash slot in `snapshot()` came back EMPTY and the "target BYTE-IDENTICAL"
# assertions degraded to a filename+mode comparison while still printing ✅ — a green verdict over no
# evidence, the exact false-PASS class this suite exists to forbid. The repo's idiom is
# sha256sum-first (`check-deployed-drift.sh:292-293`, `install.sh:851-852`,
# `cloud-cell-supervisor.sh:837-838` — cited by FUNCTION (`o_payload_hash`, `prov_payload_hash`,
# `seed_and_stamp`) rather than only by line: the first version of this comment cited three line
# numbers that resolved to unrelated code, in a file whose subject is "evidence asserted rather than
# established" — review P2, 2026-10-21).
SHA_CMD="sha256sum"
command -v sha256sum >/dev/null 2>&1 || SHA_CMD="shasum -a 256"
if ! printf 'x' | $SHA_CMD >/dev/null 2>&1; then
  echo "FATAL: no usable sha256 tool (sha256sum / shasum -a 256) — refusing to report byte assertions as passed" >&2
  exit 1
fi
sha256_of() { $SHA_CMD < "$1" | cut -d' ' -f1; }

# ── fixtures ─────────────────────────────────────────────────────────────────────────────────────
# A source that looks like the shipped harness: top-level scripts, two subdirectory shims (the pair
# the measured box was missing), and a retired/ file. Plus a file whose executable bit matters.
make_src() { # make_src <dir>
  local d="$1"
  mkdir -p "$d/gh-rest" "$d/gh-limit" "$d/retired"
  printf '#!/bin/bash\necho orch-loop v2\n'   > "$d/orch-loop.sh"
  printf '#!/bin/bash\necho claims v2\n'      > "$d/claims.sh"
  printf '#!/bin/bash\necho merge-one v2\n'   > "$d/merge-one.sh"
  printf '#!/usr/bin/env python3\nprint(1)\n' > "$d/gh-limit.py"
  printf '#!/bin/bash\necho rest\n'           > "$d/gh-rest/gh"
  printf '#!/bin/bash\necho limit-shim\n'     > "$d/gh-limit/gh"
  printf '#!/bin/bash\necho old\n'            > "$d/retired/sweep.sh"
  printf 'plain data\n'                       > "$d/port-provenance.txt"
  chmod +x "$d"/*.sh "$d"/*.py "$d"/gh-rest/gh "$d"/gh-limit/gh "$d"/retired/sweep.sh
}
# A runtime that ALREADY has a full deployment (stale bytes) plus unrelated runtime state. The stale
# orch-loop.sh is the file a correct deploy must replace; `keep-state.txt` is the file it must not.
make_target() { # make_target <dir> [pre-seed-count]
  local d="$1" n="${2:-0}" i
  mkdir -p "$d/state" "$d/logs"
  printf '#!/bin/bash\necho orch-loop STALE\n' > "$d/orch-loop.sh"; chmod +x "$d/orch-loop.sh"
  printf 'runtime state — must survive any deploy\n' > "$d/keep-state.txt"
  printf 'live-only patch\n' > "$d/live-only.sh"
  for i in $(seq 1 "$n"); do printf '#!/bin/bash\n# pre-existing script %s\n' "$i" > "$d/preseed-$i.sh"; done
}
# The notifier stub. It records EXACTLY the calls the helper made — that log is the assertion surface
# for "the notification is gated on the verdict". `BGDIR` points it away from the target so a
# notification never mutates the directory we are asserting is untouched.
NOTIFY="$T/bin/notify.sh"; mkdir -p "$T/bin"
cat > "$NOTIFY" <<'SH'
#!/usr/bin/env bash
printf '%s|%s|%s\n' "$1" "${2:-}" "${3:-}" >> "$DEPLOY_TEST_NOTIFY_LOG"
echo "  [notify] $1: ${2:-}"
SH
chmod +x "$NOTIFY"
NLOG="$T/notify.log"
export DEPLOY_TEST_NOTIFY_LOG="$NLOG"
notify_lines() { [ -f "$NLOG" ] && wc -l < "$NLOG" | tr -d ' ' || echo 0; }
notify_reset() { : > "$NLOG"; }
notify_last()  { tail -1 "$NLOG" 2>/dev/null; }
notify_has()   { [ -f "$NLOG" ] && grep -q -- "$1" "$NLOG"; }
notify_success() { notify_has "deploy VERIFIED"; }
notify_failure() { notify_has "deploy FAILED"; }

# `deploy <src> <o> [extra args...]` -> sets RC, OUT
deploy() {
  local src="$1" o="$2"; shift 2
  OUT="$(bash "$DEPLOY" --src "$src" --o "$o" --notify "$NOTIFY" "$@" 2>&1)"; RC=$?
}
# A byte-level snapshot of a directory, for "the target was left untouched" assertions. Sizes are
# useless for that (the measured doc's own rule) — this hashes the bytes and the modes.
snapshot() { ( cd "$1" 2>/dev/null && find . -type f -print | LC_ALL=C sort | while IFS= read -r f; do
  printf '%s %s %s\n' "$f" "$(sha256_of "$f")" "$( [ -x "$f" ] && echo x || echo - )"; done ); }

# ── 1. THE HAPPY PATH — and proof that it is a deploy, not a listing ────────────────────────────
say_case "1. a valid source deploys, verifies, and notifies success"
SRC1="$T/src1"; O1="$T/o1"; make_src "$SRC1"; make_target "$O1"
mkdir -p "$O1/bg"
# ⛔ THE SELF-CONFIRMING SHAPE, on purpose: the target already holds 30 scripts AND the exact files
# the source ships. A deploy that counted what is already there would call this a success before it
# copied anything. The assertion is that success comes from the COPY, so the stale orch-loop.sh must
# be replaced and the unrelated files must survive.
BEFORE_LIVE="$(sha256_of "$O1/live-only.sh")"
notify_reset
deploy "$SRC1" "$O1"
if [ "$RC" -eq 0 ]; then ok "valid source -> exit 0"; else bad "valid source -> exit $RC (expected 0): $OUT"; fi
grep -q "VERIFIED" <<< "$OUT" && ok "prints the VERIFIED verdict" || bad "no VERIFIED verdict in output"
if notify_success; then ok "notification is the SUCCESS one"; else bad "no success notification (got: $(notify_last))"; fi
notify_failure && bad "a successful deploy also notified FAILURE" || ok "success path emits no failure notification"
[ "$(notify_lines)" = "1" ] && ok "exactly one notification per run" || bad "$(notify_lines) notifications for one run"

# the copy really happened: stale bytes replaced, by comparison with the source
cmp -s "$SRC1/orch-loop.sh" "$O1/orch-loop.sh" && ok "stale orch-loop.sh replaced with the source bytes" || bad "orch-loop.sh does not match the source"
cmp -s "$SRC1/claims.sh" "$O1/claims.sh"     && ok "claims.sh present and identical" || bad "claims.sh missing or differs"
# subdirectories — the measured gap (gh-rest/gh, gh-limit/gh never landed)
[ -f "$O1/gh-rest/gh" ] && cmp -s "$SRC1/gh-rest/gh" "$O1/gh-rest/gh" && ok "subdir gh-rest/gh deployed" || bad "subdir gh-rest/gh NOT deployed"
[ -f "$O1/gh-limit/gh" ] && cmp -s "$SRC1/gh-limit/gh" "$O1/gh-limit/gh" && ok "subdir gh-limit/gh deployed" || bad "subdir gh-limit/gh NOT deployed"
[ -f "$O1/retired/sweep.sh" ] && ok "nested retired/ deployed" || bad "nested retired/ NOT deployed"
# the executable bit — a 0644 merge-one.sh is a loop that cannot spawn, and the loss is silent
[ -x "$O1/merge-one.sh" ] && ok "executable bit preserved" || bad "executable bit LOST on merge-one.sh"
[ ! -x "$O1/port-provenance.txt" ] && ok "non-executable file stays non-executable" || bad "port-provenance.txt gained +x"
# runtime state is not the harness and must not be touched
[ "$(sha256_of "$O1/live-only.sh")" = "$BEFORE_LIVE" ] && ok "live-only runtime file untouched" || bad "deploy overwrote or removed a non-harness file"
[ -f "$O1/keep-state.txt" ] && ok "runtime state file preserved" || bad "runtime state file destroyed"
grep -q "verified	gh-rest/gh" "$O1/.deploy-ledger.tsv" 2>/dev/null && ok "per-file ledger records the copy" || bad "no per-file ledger entry for gh-rest/gh"

# ── 2. THE MEASURED DEFECT — absent source against a target full of scripts ──────────────────────
say_case "2. absent source, target pre-seeded with 30 scripts -> FAILURE, target untouched"
O2="$T/o2"; make_target "$O2" 30
BEFORE="$(snapshot "$O2")"
notify_reset
deploy "$T/does-not-exist" "$O2"
[ "$RC" -ne 0 ] && ok "absent source -> non-zero exit ($RC)" || bad "absent source exited 0 — the #2041 false PASS"
[ "$RC" = "78" ] && ok "exit 78 (refused before touching anything)" || bad "exit $RC, expected 78"
notify_failure && ok "failure notification emitted" || bad "NO failure notification for an absent source"
notify_success && bad "an absent source notified SUCCESS" || ok "no success notification"
grep -qi "does not exist" <<< "$(notify_last)" && ok "notification names the cause" || bad "notification does not name the cause: $(notify_last)"
if [ "$(snapshot "$O2")" = "$BEFORE" ]; then ok "target byte-identical after the refusal"; else bad "the refusal MODIFIED the target"; fi
# the exact self-confirming counter from the old line 34 must not appear as evidence of anything.
# ⛔ ASSERT THE REMOVED SHAPE, NOT A BARE NUMBER (review P3). `grep -q "30"` searched the WHOLE
# output — including the scratch paths (`$T` = mktemp -d …/deploy-harness-test.XXXXXX) — so a random
# suffix containing `30` (~0.1%/run) reddened a shard with nothing wrong with it, and the assertion
# was a heuristic rather than the formula that was actually removed
# (`$(ls "$O"/*.sh | wc -l) scripts`). Case 5 already pins the same class precisely.
OUT_NO_T="${OUT//$T/<T>}"
grep -qE '(^|[^0-9])[0-9]+ scripts' <<< "$OUT_NO_T" && bad "output leans on a pre-existing file count" || ok "output does not cite pre-existing file counts"

# ── 3. NOTHING COPIED — a source that ships no files ─────────────────────────────────────────────
say_case "3. source shipping zero files -> FAILURE (a deploy of nothing is not a success)"
SRC3="$T/src3"; O3="$T/o3"; mkdir -p "$SRC3"; make_target "$O3" 5
BEFORE="$(snapshot "$O3")"
notify_reset; deploy "$SRC3" "$O3"
[ "$RC" -ne 0 ] && ok "empty source -> non-zero exit ($RC)" || bad "empty source exited 0"
# ⛔ The EXIT CODE, not just "non-zero": without this the later internal-invariant fallback (exit 1)
# satisfied the case, so the zero-file REFUSAL — and its "refused before touching the target"
# contract — was never actually pinned. Deleting the N==0 block left the suite green.
[ "$RC" = "78" ] && ok "exit 78 (the zero-file refusal, not a later invariant fallback)" || bad "exit $RC, expected 78 (refused before touching anything)"
grep -qi "ships ZERO files" <<< "$OUT" && ok "the refusal names zero shipped files (indicator (b))" || bad "refused for some other reason: $OUT"
notify_success && bad "empty source notified SUCCESS — indicator (b) violated" || ok "no success notification (0 files copied)"
notify_failure && ok "failure notification emitted" || bad "no failure notification"
[ "$(snapshot "$O3")" = "$BEFORE" ] && ok "target untouched" || bad "empty-source refusal modified the target"

# ── 4. A DIRECTORY THAT IS NOT THE HARNESS ───────────────────────────────────────────────────────
say_case "4. a source with no orch-loop.sh/claims.sh is refused, not deployed"
SRC4="$T/src4"; O4="$T/o4"; mkdir -p "$SRC4"; printf 'not a harness\n' > "$SRC4/random.sh"; make_target "$O4"
BEFORE="$(snapshot "$O4")"
notify_reset; deploy "$SRC4" "$O4"
[ "$RC" -ne 0 ] && ok "non-harness source -> non-zero exit ($RC)" || bad "non-harness source exited 0"
notify_failure && ok "failure notification emitted" || bad "no failure notification"
notify_success && bad "non-harness source notified SUCCESS" || ok "no success notification"
[ "$(snapshot "$O4")" = "$BEFORE" ] && ok "target untouched" || bad "refusal modified the target"

# ── 5. A COPY THAT FAILS MID-RUN — partial is not success ────────────────────────────────────────
say_case "5. copy fails for one file mid-run -> FAILURE, no partial success claimed"
SRC5="$T/src5"; O5="$T/o5"; make_src "$SRC5"; make_target "$O5" 10
# A `cp` shim that fails for exactly one file. This is the "copy status per file" the fix is built
# on: the helper must PROPAGATE a failed copy, not discover it later and not average it away.
mkdir -p "$T/cpbin"
cat > "$T/cpbin/cp" <<SH
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in *merge-one.sh) echo "cp: \$a: permission denied" >&2; exit 1 ;; esac
done
exec "$REAL_CP" "\$@"
SH
chmod +x "$T/cpbin/cp"
notify_reset
OUT="$(PATH="$T/cpbin:$PATH" bash "$DEPLOY" --src "$SRC5" --o "$O5" --notify "$NOTIFY" 2>&1)"; RC=$?
[ "$RC" -ne 0 ] && ok "failed copy -> non-zero exit ($RC)" || bad "failed copy exited 0"
[ "$RC" = "1" ] && ok "exit 1 (copy failure, not a refusal)" || bad "exit $RC, expected 1"
notify_failure && ok "failure notification emitted" || bad "no failure notification for a failed copy"
notify_success && bad "a failed copy notified SUCCESS — partial success claimed" || ok "no success notification"
grep -q "PARTIAL" <<< "$(notify_last)" && ok "notification states the runtime is now partial" || bad "notification does not warn about the partial runtime: $(notify_last)"
grep -q "merge-one.sh" <<< "$(notify_last)" && ok "notification names the failed file" || bad "notification does not name the failed file"
grep -q "COPY-FAIL	merge-one.sh" "$O5/.deploy-ledger.tsv" 2>/dev/null && ok "ledger records the failed file" || bad "ledger does not record the failed copy"
grep -qi "VERIFIED" <<< "$(notify_last)" && bad "failure notification contains the success vocabulary" || ok "failure notification carries no success claim"
# the count in the message must be THIS RUN's copy count, never a listing of the target (28 pre-
# existing + 9 copied would look like "37 files, all good" — the old formula's exact failure)
grep -q "$(ls "$O5"/*.sh 2>/dev/null | wc -l | tr -d ' ') of" <<< "$(notify_last)" && bad "notification quotes the target's file count as evidence" || ok "notification does not quote the target's file count"
# ⛔ AND ZERO WRITTEN IS NOT "PARTIAL". The message above is right for a partial copy; asserting it
# unconditionally told an operator their runtime was PARTIAL when nothing had been written at all,
# which invites a restore/re-kill of a box that is exactly as it was. Branch on the count.
if [ "$(id -u)" = "0" ]; then
  echo "  (zero-written sub-case skipped — running as root, where a 0555 target is still writable)"
else
  SRC5b="$T/src5b"; O5b="$T/o5b"; make_src "$SRC5b"; make_target "$O5b" 2
  chmod 555 "$O5b"                     # every copy fails, nothing can be written
  notify_reset; deploy "$SRC5b" "$O5b"
  chmod 755 "$O5b"
  [ "$RC" = "1" ] && ok "nothing writable -> exit 1 (a copy failure, not a refusal)" || bad "exit $RC, expected 1"
  grep -qi "NOTHING was copied" <<< "$(notify_last)" && ok "0 copied says NOTHING was copied" || bad "a zero-file copy did not say nothing was copied: $(notify_last)"
  grep -qi "PARTIAL" <<< "$(notify_last)" && bad "a zero-file copy claimed the runtime is PARTIAL (it is untouched)" || ok "does not claim PARTIAL when nothing was written"
  grep -qi "unchanged" <<< "$(notify_last)" && ok "says the runtime is unchanged" || bad "does not say the runtime was left as it was: $(notify_last)"
fi

# ⛔ AND "UNCHANGED" IS A CLAIM ABOUT THE RUNTIME, NOT ABOUT THE FILE COUNT (review P3). `mkdir -p`
# runs before every `cp` and is never rolled back, so a run that copies 0 FILES can still have created
# directories in $O. The 0555 sub-case above cannot see this — mkdir fails there too — so it pinned
# the word "unchanged" without pinning the measurement behind it. Here every `cp` fails while the
# target's subdirectories are MISSING, so `mkdir -p` succeeds before the first copy fails.
if [ "$(id -u)" = "0" ]; then
  echo "  (directories-created sub-case skipped — running as root, where 0555/000 do not bind)"
else
  SRC5c="$T/src5c"; O5c="$T/o5c"; make_src "$SRC5c"; make_target "$O5c"
  mkdir -p "$T/cpbin5c"
  cat > "$T/cpbin5c/cp" <<'SH'
#!/usr/bin/env bash
# every copy fails, as on a full target; `mkdir -p` has already run by then
echo "cp: disk full" >&2
exit 1
SH
  chmod +x "$T/cpbin5c/cp"
  notify_reset
  OUT="$(PATH="$T/cpbin5c:$PATH" bash "$DEPLOY" --src "$SRC5c" --o "$O5c" --notify "$NOTIFY" 2>&1)"; RC=$?
  [ "$RC" = "1" ] && ok "every copy failing -> exit 1" || bad "exit $RC, expected 1: $OUT"
  [ -d "$O5c/gh-rest" ] && ok "the fixture really left a created directory behind (the assertion is not vacuous)" || bad "the fixture created nothing — the claim below would be vacuous"
  grep -qiE 'is unchanged' <<< "$(notify_last)" && bad "a run that CREATED directories still calls the runtime unchanged" || ok "does not call the runtime unchanged when directories were created"
  grep -qiE '[0-9]+ director(y|ies) (was|were) created' <<< "$(notify_last)" && ok "names the directories it created instead" || bad "does not say what it changed: $(notify_last)"
  grep -qi "PARTIAL" <<< "$(notify_last)" && bad "uses PARTIAL — no FILE was written" || ok "does not claim the runtime is PARTIAL"
  grep -q "COPY-FAIL" "$O5c/.deploy-ledger.tsv" 2>/dev/null && ok "the ledger still records the per-file copy failures" || bad "the ledger lost the per-file failures"
fi

# ⛔ AND THE LEDGER IS ITSELF A WRITE (review P2, 2026-10-21). The failure ledger is installed INTO
# `$O`, so a WRITABLE runtime whose every `cp` failed used to say "the runtime is unchanged" while the
# run had just added `$O/.deploy-ledger.tsv`. Case 5b cannot see it (its 0555 target refuses the ledger
# too, so "unchanged" is accidentally true there) and 5c cannot either (it creates directories, so it
# takes the other branch). This is the only case with a writable target, no created directory, and
# zero copied files.
if [ "$(id -u)" = "0" ]; then
  echo "  (ledger-is-a-write sub-case skipped — running as root)"
else
  SRC5d="$T/src5d"; O5d="$T/o5d"; make_src "$SRC5d"; make_target "$O5d"
  # Every destination directory already exists, so `mkdir -p` creates nothing (MADE_DIRS=0) and the
  # "directories were created" branch cannot mask the claim; every `cp` then fails.
  mkdir -p "$O5d/gh-rest" "$O5d/gh-limit" "$O5d/retired"
  mkdir -p "$T/cpbin5d"
  cat > "$T/cpbin5d/cp" <<'SH'
#!/usr/bin/env bash
echo "cp: read-only source" >&2
exit 1
SH
  chmod +x "$T/cpbin5d/cp"
  notify_reset
  OUT="$(PATH="$T/cpbin5d:$PATH" bash "$DEPLOY" --src "$SRC5d" --o "$O5d" --notify "$NOTIFY" 2>&1)"; RC=$?
  [ "$RC" = "1" ] && ok "writable target, every cp failing -> exit 1" || bad "exit $RC, expected 1: $OUT"
  [ -f "$O5d/.deploy-ledger.tsv" ] && ok "the fixture really did write the ledger into the target (the assertion is not vacuous)" || bad "no ledger was written — the claim below would be vacuous"
  grep -qiE 'runtime at .* is unchanged' <<< "$(notify_last)" && bad "claimed the runtime is UNCHANGED after writing its ledger into it" || ok "does not call the runtime unchanged when the ledger was written"
  grep -qi 'deploy-ledger' <<< "$(notify_last)" && ok "names the ledger as the one file it did write" || bad "does not name the ledger it wrote: $(notify_last)"
  grep -qi "PARTIAL" <<< "$(notify_last)" && bad "uses PARTIAL — no FILE was copied" || ok "does not claim the runtime is PARTIAL"
fi

# ── 6. A COPY THAT SILENTLY DOES NOT MATCH — the verification gate is load-bearing ───────────────
say_case "6. copy reports success but bytes differ -> FAILURE (verification, not the copy, decides)"
SRC6="$T/src6"; O6="$T/o6"; make_src "$SRC6"; make_target "$O6"
# ⛔ THE REAL DEFECT SHAPE: `cp` exits 0 and the bytes at the target are NOT the source's. A `cmp`
# shim was NOT enough — it exits on the argument text, so `cmp a b` and `cmp b b` both matched and a
# verify loop comparing the TARGET WITH ITSELF (a tautology: `cmp -s "$O/$rel" "$O/$rel"`) still
# passed this case, i.e. the half the PR exists to add could have been entirely decorative. Corrupting
# the copy instead makes the assertion direction-sensitive by construction.
mkdir -p "$T/cpbin"
cat > "$T/cpbin/cp" <<SH
#!/usr/bin/env bash
"$REAL_CP" "\$@" || exit \$?
# append a byte to exactly one destination, reporting success — the silent-drift case.
# NB the staging name is `mktemp`-generated and no longer carries the file name (cycle 4), so the
# file is identified from the SOURCE argument and the destination from the arg that is a staging path.
# `cp -p SRC TMP`: the source is not `$1` (that is `-p`), so match any arg and use the LAST as dest
case "\$*" in *claims.sh*)
  case "\${!#}" in */.deploy-*) printf 'CORRUPTED\n' >> "\${!#}" ;; esac ;;
esac
exit 0
SH
chmod +x "$T/cpbin/cp"
notify_reset
OUT="$(PATH="$T/cpbin:$PATH" bash "$DEPLOY" --src "$SRC6" --o "$O6" --notify "$NOTIFY" 2>&1)"; RC=$?
[ "$RC" -ne 0 ] && ok "unverified bytes -> non-zero exit ($RC)" || bad "unverified bytes exited 0"
notify_failure && ok "failure notification emitted" || bad "no failure notification"
notify_success && bad "unverified bytes notified SUCCESS" || ok "no success notification"
grep -q "DRIFT	claims.sh" "$O6/.deploy-ledger.tsv" 2>/dev/null && ok "ledger records the drift" || bad "ledger does not record the drift"
grep -qi "verification failed" <<< "$OUT" && ok "reports a VERIFICATION failure (distinct from a copy failure)" || bad "does not report a verification failure: $OUT"
# and the comparison's DIRECTION is pinned structurally, so the tautology above cannot come back quietly
DEPLOY_CODE0="$(grep -v '^[[:space:]]*#' "$DEPLOY" || true)"
grep -q 'cmp -s "\$SRC/\$rel" "\$O/\$rel"' <<< "$DEPLOY_CODE0" && ok "verification compares SOURCE against target (not target against itself)" || bad "the compare is not source->target — a self-comparison cannot fail"

# ── 7. A REAL UNREADABLE SOURCE FILE (the issue's own case (c), non-root only) ───────────────────
say_case "7. an unreadable source file -> FAILURE, not partial success"
if [ "$(id -u)" = "0" ]; then
  echo "  (skipped — running as root, where chmod 000 is still readable)"
else
  SRC7="$T/src7"; O7="$T/o7"; make_src "$SRC7"; make_target "$O7"
  chmod 000 "$SRC7/merge-one.sh"
  notify_reset; deploy "$SRC7" "$O7"
  chmod 644 "$SRC7/merge-one.sh"
  [ "$RC" -ne 0 ] && ok "unreadable source file -> non-zero exit ($RC)" || bad "unreadable source file exited 0"
  notify_success && bad "unreadable source file notified SUCCESS" || ok "no success notification"
  notify_failure && ok "failure notification emitted" || bad "no failure notification"
fi

# ── 8. A TARGET SHAPE THAT WOULD SWALLOW THE RENAME ─────────────────────────────────────────────
say_case "8. a directory where a file belongs is a copy failure, not a silent move-into"
SRC8="$T/src8"; O8="$T/o8"; make_src "$SRC8"; make_target "$O8"
mkdir -p "$O8/claims.sh"          # a DIRECTORY sitting where claims.sh belongs
notify_reset; deploy "$SRC8" "$O8"
[ "$RC" -ne 0 ] && ok "wrong target shape -> non-zero exit ($RC)" || bad "wrong target shape exited 0"
notify_success && bad "wrong target shape notified SUCCESS" || ok "no success notification"
[ -d "$O8/claims.sh" ] && ok "the directory was not silently replaced" || bad "deploy replaced a directory"
# ⛔ AND it must fail in the COPY phase, not be caught later by `cmp` on a directory: the assertions
# above were satisfied by the verify half alone, so deleting the shape guard left the suite green.
grep -q "COPY-FAIL	claims.sh" "$O8/.deploy-ledger.tsv" 2>/dev/null && ok "the ledger names the COPY-FAIL (the guard fired, not the verify half)" || bad "no COPY-FAIL entry — the shape guard is not load-bearing"

# ── 9. THE VERDICT IS NOT HOSTAGE TO THE NOTIFIER ───────────────────────────────────────────────
say_case "9. an unrunnable notifier does not fake a failure, and does not fake a report"
SRC9="$T/src9"; O9="$T/o9"; make_src "$SRC9"; make_target "$O9"
OUT="$(bash "$DEPLOY" --src "$SRC9" --o "$O9" --notify "$T/nope.sh" 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && ok "verified deploy still exits 0 without a notifier" || bad "missing notifier turned a good deploy into exit $RC"
grep -qi "notify-UNRUNNABLE\|no notifier at" <<< "$OUT" && ok "says loudly that nobody was notified" || bad "silently declined to notify"
# and --no-notify is honoured
notify_reset
OUT="$(bash "$DEPLOY" --src "$SRC9" --o "$O9" --no-notify 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && ok "--no-notify still verifies (exit 0)" || bad "--no-notify exited $RC"
[ "$(notify_lines)" = "0" ] && ok "--no-notify fired no notification" || bad "--no-notify still fired $(notify_lines)"
# ⛔ AND A NOTIFIER THAT RUNS AND FAILS MUST NOT DECIDE THE VERDICT (review P2, 2026-10-21). The two
# cases above only reach the ABSENT-notifier branch. The documented contract — "a failing notifier is a
# REPORTING gap, not a deploy failure" — was defended by NOTHING: mutating the guard to `bash "$NOTIFY"
# ... || exit 9` left this suite GREEN (135/135). Both arms are pinned here, so that mutation cannot
# survive again.
cat > "$T/bin/notify-fails.sh" <<'SH'
#!/usr/bin/env bash
printf '%s|%s\n' "$1" "${2:-}" >> "$DEPLOY_TEST_NOTIFY_LOG"
echo "  [notify-EXIT-3] $1" >&2
exit 3
SH
chmod +x "$T/bin/notify-fails.sh"
notify_reset
OUT="$(bash "$DEPLOY" --src "$SRC9" --o "$O9" --notify "$T/bin/notify-fails.sh" 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && ok "a notifier that exits 3 does NOT turn a verified deploy into a failure" || bad "the notifier's status decided the verdict (exit $RC)"
grep -q "deploy VERIFIED" <<< "$OUT" && ok "the verdict is still reported (VERIFIED) after the notifier failed" || bad "the verdict was lost when the notifier failed: $OUT"
grep -qi "notifier.*exited non-zero" <<< "$OUT" && ok "says the notifier itself failed, so the gap is not silent" || bad "a failed notification was swallowed: $OUT"
# the failure arm: a REFUSAL stays a refusal, and its exit code is not replaced by the notifier's
notify_reset
OUT="$(bash "$DEPLOY" --src "$T/does-not-exist" --o "$O9" --notify "$T/bin/notify-fails.sh" 2>&1)"; RC=$?
[ "$RC" -eq 78 ] && ok "a failing notifier does not overwrite a refusal's exit 78" || bad "refusal exit became $RC when the notifier failed"

# ── 10. IDEMPOTENCE — a second deploy of the same source is still a verified success ──────────────
say_case "10. re-running the deploy over its own output is a verified success"
notify_reset; deploy "$SRC1" "$O1"
[ "$RC" -eq 0 ] && ok "second run exits 0" || bad "second run exited $RC"
notify_success && ok "second run verifies (bytes already matched, and it still copied them)" || bad "second run did not verify: $(notify_last)"
[ "$(notify_lines)" = "1" ] && ok "exactly one notification on the second run" || bad "$(notify_lines) notifications"

# ── 11. THE DOCUMENTED CALL SITE — bg/finish.sh must not be able to bypass the verdict ───────────
say_case "11. the helper owns the verdict, so a caller cannot announce success on a failed deploy"
# The old finish.sh announced success as a SIBLING statement, so the fix is that success exists only
# as this script's exit code + its own notification. Structural assertion: the success string is
# emitted on exactly one line of the helper, and that line is unreachable on any failure path
# (it sits after the copy-fail and verify-fail gates, which both `exit 1`).
n_success_lines="$(grep -c 'harness deploy VERIFIED' "$DEPLOY")"
[ "$n_success_lines" = "1" ] && ok "one success-notification site" || bad "$n_success_lines success-notification sites (expected 1)"
n_verified_print="$(grep -c 'say "\$PROG: VERIFIED' "$DEPLOY")"
[ "$n_verified_print" = "1" ] && ok "one VERIFIED print site" || bad "$n_verified_print VERIFIED print sites (expected 1)"
# The helper's non-comment lines are CAPTURED once and tested in the shell: a non-quiet grep piped
# into `grep -q` is the #841/#864 SIGPIPE false-negative (the quiet grep exits early, the producer
# dies of SIGPIPE, and under `pipefail` the assertion reports the wrong cause).
DEPLOY_CODE="$(grep -v '^[[:space:]]*#' "$DEPLOY" || true)"
grep -q 'ls "\$O"' <<< "$DEPLOY_CODE" && bad "the helper counts files from the target (self-confirming evidence)" || ok "the helper never counts files from the target"
grep -q 'cp -R' <<< "$DEPLOY_CODE" && bad "the helper still uses a bare recursive cp" || ok "no bare recursive copy"

# ── 12. A TRUNCATED INVENTORY — the walk's status must be READ, not discarded ─────────────────────
say_case "12. an unsearchable source SUBDIRECTORY -> FAILURE (a partial inventory is not a deploy)"
# ⛔ This was a second measured false PASS of the same #2041 class: the inventory was built inside a
# PROCESS SUBSTITUTION, whose exit status bash never waits for, so `find` exiting 1 ("Permission
# denied") yielded a TRUNCATED file list, every term of the verdict then agreed with itself, and the
# run printed `VERIFIED — 2/2` + exit 0 while the source's own `gh-limit.py` was never deployed.
if [ "$(id -u)" = "0" ]; then
  echo "  (skipped — running as root, where chmod 000 is still searchable)"
else
  SRC12="$T/src12"; O12="$T/o12"; make_src "$SRC12"; make_target "$O12"
  # ⛔ `retired/`, deliberately a NON-anchor subtree: chmod-ing `gh-limit` here made the anchor check
  # (which stats the real path) refuse first, so the case passed against a helper whose inventory was
  # still truncated — the assertion would have been satisfied by a different guard.
  chmod 000 "$SRC12/retired"           # a DIRECTORY, not a file: case 7 is the unreadable-FILE shape
  notify_reset; deploy "$SRC12" "$O12"
  chmod 755 "$SRC12/retired"
  [ "$RC" = "78" ] && ok "unsearchable subdirectory -> exit 78 (refused, nothing written)" || bad "exit $RC, expected 78 — a truncated inventory was deployed as if complete"
  notify_success && bad "a truncated inventory notified SUCCESS — the #2041 false PASS, one mechanism over" || ok "no success notification"
  notify_failure && ok "failure notification emitted" || bad "no failure notification"
  [ -e "$O12/gh-limit/gh" ] && bad "a partial deploy still wrote files" || ok "nothing was written by the refusal"
fi

# ⛔ 12b AND THE INVENTORY'S STATUS READ IS PINNED ON ITS OWN (review P2, cycle 4). Case 12 above does
# NOT pin it: `chmod 000` fails BOTH walks, and the NONREG walk is evaluated first, so deleting the
# inventory's status read leaves 12 fully green — the recurring "an assertion satisfied by a different
# guard" pattern. This sub-case fails ONLY the inventory form, by stubbing `find`.
if [ "$(id -u)" = "0" ]; then
  echo "  (12b skipped — running as root)"
else
  SRC12b="$T/src12b"; O12b="$T/o12b"; make_src "$SRC12b"; make_target "$O12b"
  mkdir -p "$T/findbin12b"; REAL_FIND12B="$(command -v find)"
  cat > "$T/findbin12b/find" <<SH
#!/usr/bin/env bash
# the INVENTORY form fails and returns a TRUNCATED list; every other form is real
case "\$*" in
  *'-type f -print'*) printf './claims.sh\n'; exit 1 ;;
esac
exec "$REAL_FIND12B" "\$@"
SH
  chmod +x "$T/findbin12b/find"
  notify_reset
  OUT="$(PATH="$T/findbin12b:$PATH" bash "$DEPLOY" --src "$SRC12b" --o "$O12b" --notify "$NOTIFY" 2>&1)"; RC=$?
  [ "$RC" = "78" ] && ok "12b: ONLY the inventory walk failing -> exit 78" || bad "12b: exit $RC, expected 78 — the inventory's own status is not read"
  notify_success && bad "12b: a truncated inventory notified SUCCESS" || ok "12b: no success notification"
  [ -e "$O12b/claims.sh" ] && bad "12b: the truncated inventory was deployed anyway" || ok "12b: nothing was written"
  # and the fixture is not vacuous: the stub really is what refused, not the NONREG walk
  # ⛔ THIS MUST NOT MATCH THE *NONREG* REFUSAL (review P2, cycle 5). The previous pattern
  # ("inventory|searchable|Permission|truncat") matched "source inventory for NON-REGULAR entries FAILED
  # … (unsearchable directory …)" verbatim, so it would have printed ✅ if the WRONG guard had refused —
  # an assertion that cannot discriminate the thing it claims to. Matching the inventory message's own
  # wording is what makes it a check.
  grep -qi "source inventory FAILED" <<< "$OUT" && ok "12b: the verdict names the inventory walk, not the non-regular walk" || bad "12b: refused without naming the inventory walk: $OUT"
  grep -qi "NON-REGULAR" <<< "$OUT" && bad "12b: the NON-REGULAR walk refused too — the fixture is not isolating the inventory" || ok "12b: the non-regular walk did not fire (the stub isolates the inventory)"
fi

# ── 13. A STALE BUT REAL HARNESS — the anchors must cover the files #2041 measured missing ────────
say_case "13. a source with the two old anchors but no gh-limit.py/gh-rest/gh/gh-limit/gh -> REFUSED"
# `orch-loop.sh` and `claims.sh` exist in every checkout back to 2026-10-13; the three files whose
# absence #2041 measured landed 2026-10-17/18. A two-anchor test therefore CERTIFIED a days-stale
# checkout that shipped none of them — the identical measured consequence, reached through a source
# that is days old instead of 1274 commits old. Nothing else in the fleet catches it:
# check-deployed-drift.sh compares depth-1 `*.sh` only (`:333`), and `install.sh`'s payload fold
# excludes `gh-rest/gh` by name (`:877-881`, `prov_payload_hash` at `:860`) from
# the payload fold by name.
SRC13="$T/src13"; O13="$T/o13"; make_target "$O13"
mkdir -p "$SRC13"; printf '#!/bin/bash\n' > "$SRC13/orch-loop.sh"; printf '#!/bin/bash\n' > "$SRC13/claims.sh"
notify_reset; deploy "$SRC13" "$O13"
[ "$RC" = "78" ] && ok "old-but-real harness -> exit 78 (refused)" || bad "exit $RC, expected 78 — a checkout missing gh-limit.py was certified"
notify_success && bad "a harness missing gh-limit.py notified SUCCESS" || ok "no success notification"
grep -qi "gh-limit.py" <<< "$(notify_last)" && ok "the notification names the missing anchor" || bad "notification does not name the cause: $(notify_last)"

# ── 14. A SYMLINK THE SOURCE SHIPS — refused, never silently omitted ──────────────────────────────
say_case "14. a symlink in the source -> REFUSAL (find -type f cannot see it; cp -R used to carry it)"
SRC14="$T/src14"; O14="$T/o14"; make_src "$SRC14"; make_target "$O14"
ln -s gh-limit.py "$SRC14/gh-shim"        # the shape a future `gh-*/gh` fallback would ship as
notify_reset; deploy "$SRC14" "$O14"
[ "$RC" = "78" ] && ok "source symlink -> exit 78 (refused, nothing written)" || bad "exit $RC, expected 78 — a symlink was silently left behind"
notify_success && bad "a source with an undeployable symlink notified SUCCESS" || ok "no success notification"
[ -e "$O14/gh-shim" ] && bad "the refusal still wrote to the target" || ok "nothing was written by the refusal"
# ⛔ AND NOT ONLY A SYMLINK (review P2, 2026-10-21). The probe was `find -type l`, which catches exactly
# one of the classes `find -type f` cannot see. A FIFO in the source was silently dropped from the
# inventory: the run copied the regular files, reported "8/8 verified", and the FIFO simply never landed
# — the same "a file the source ships went missing from a deployment that said VERIFIED" defect the
# symlink arm exists to stop. `! -type f ! -type d` subsumes both.
say_case "14b. a NON-REGULAR source entry (a FIFO) -> REFUSAL, not a silent omission"
if ! command -v mkfifo >/dev/null 2>&1; then
  echo "  (FIFO sub-case skipped — no mkfifo on this platform)"
else
  SRC14b="$T/src14b"; O14b="$T/o14b"; make_src "$SRC14b"; make_target "$O14b"
  mkfifo "$SRC14b/pipe.sh"
  notify_reset; deploy "$SRC14b" "$O14b"
  [ "$RC" = "78" ] && ok "a source FIFO -> exit 78 (refused)" || bad "exit $RC, expected 78 — a FIFO was silently omitted from the deploy"
  grep -qi "non-regular entry" <<< "$OUT" && ok "the refusal names the non-regular entry" || bad "refused without naming the shape: $OUT"
  notify_success && bad "a source with a FIFO notified SUCCESS" || ok "no success notification"
  [ -e "$O14b/pipe.sh" ] && bad "the refusal still wrote to the target" || ok "nothing was written by the refusal"
fi

# ── 15. A SELF-DEPLOY — every file would compare with itself ─────────────────────────────────────
say_case "15. --src == --o is refused (a self-comparison cannot fail, and the ledger would land in the source)"
SRC15="$T/src15"; make_src "$SRC15"
notify_reset; deploy "$SRC15" "$SRC15"
[ "$RC" = "78" ] && ok "source == target -> exit 78 (refused)" || bad "exit $RC, expected 78 — a tautological VERIFIED was printed"
notify_success && bad "a self-deploy notified SUCCESS" || ok "no success notification"
[ -e "$SRC15/.deploy-ledger.tsv" ] && bad "the refusal wrote a ledger INTO the source tree" || ok "no deploy artefact left in the source"
# a target nested inside the source is the same defect with a longer path
# ⛔ THE NESTED TARGET MUST EXIST, OR THIS CASE PINS THE WRONG GUARD (review P2). It used to be
# `deploy "$SRC15" "$SRC15/nested"` with `nested` never created, so `[ -d "$O" ]` refused at the
# "target runtime is not a directory" preflight and the run never REACHED the overlap test — the
# second arm of `SELF_OVERLAP` (`$O_REAL/` inside `$SRC_REAL`) was pinned by nothing: deleting it left
# this case green, while a deploy into a subdirectory of the source would copy the bytes AND its
# ledger INTO the checkout and report VERIFIED, and the next run's inventory would ship that subtree
# as harness content. With `nested` present the case reaches the overlap test, and the cause is
# asserted, not just the exit code.
mkdir -p "$SRC15/nested"
notify_reset; deploy "$SRC15" "$SRC15/nested"
[ "$RC" = "78" ] && ok "target nested inside the source -> exit 78" || bad "nested overlap exited $RC, expected 78"
grep -qi 'overlap' <<< "$OUT" && ok "the nested refusal names OVERLAP (not the \"not a directory\" preflight)" || bad "the nested target was refused for the wrong reason: $OUT"

# ── 16. THE DOCUMENTED CALL SHAPE — `--repo`, and the notifier default ───────────────────────────
say_case "16. --repo derivation + \$O/bg/notify.sh default + env O are the shape the caller actually uses"
# The documented invocation is `--repo <checkout> --o <runtime>` with NO `--notify`; every other case
# here passes `--src` and `--notify` explicitly, so neither the derivation nor the notifier default
# — the block whose own comment says the ordering "is the whole point" — was exercised at all.
CO16="$T/co16"; O16="$T/o16"; mkdir -p "$CO16/scripts"; mk_src16="$CO16/scripts/orchestrator-harness"
make_src "$mk_src16"; make_target "$O16"; mkdir -p "$O16/bg"
cp "$NOTIFY" "$O16/bg/notify.sh"
notify_reset
OUT="$(bash "$DEPLOY" --repo "$CO16" --o "$O16" 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && ok "--repo resolves the source and deploys (exit 0)" || bad "--repo invocation exited $RC: $OUT"
# ⛔ ONE ASSERTION, WITH A REAL FAILURE ARM. This line used to read
#     notify_success && ok "…" || ok "notification default: $(notify_last)"
# — BOTH arms called `ok`, so it printed ✅ unconditionally, including when the default notifier never
# fired. A green verdict over no evidence is the exact false-PASS class §1 and case 18 forbid, and it
# was a false-green LINE (the assertion below it still failed the case correctly). The duplicate is
# gone; this is the one assertion, and it fails.
notify_success && ok "the \$O/bg/notify.sh default fired the success notification (resolved before the preflight)" || bad "the default notifier never fired a success notification (got: $(notify_last))"
# and an absent source through the SAME default must notify FAILURE, not fall silent
notify_reset
OUT="$(bash "$DEPLOY" --src "$T/absent16" --o "$O16" 2>&1)"; RC=$?
[ "$RC" = "78" ] && ok "absent source via the default notifier -> exit 78" || bad "exit $RC, expected 78"
notify_failure && ok "the default notifier reported the refusal (indicator (a) of #2041)" || bad "a refusal reached nobody: $(notify_last)"
# env `O` is honoured (the #1745-class false PASS: an explicit `O=<dir>` used to address $HOME/orchestrator)
notify_reset
OUT="$(O="$O16" bash "$DEPLOY" --src "$SRC1" --no-notify 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && ok "env O=<dir> is honoured without --o" || bad "env O exited $RC: $OUT"
# ⛔ AND `SRC` HAS NO SUCH CONVENTION (review P2). The helper read `${HARNESS_SRC:-}` — a variable
# documented nowhere (not in `usage()`, not in README §4.1, and appearing in exactly one line of the
# repo) — while its own comment on the line above said the value IS cleared. An ambient `HARNESS_SRC`
# therefore chose the source for an operator who passed only `--o`. The source is named by `--src` /
# `--repo` or it is not named at all, so this must refuse rather than deploy from the environment.
SRC16B="$T/src16b"; O16B="$T/o16b"; make_src "$SRC16B"; make_target "$O16B"
notify_reset
OUT="$(HARNESS_SRC="$SRC16B" bash "$DEPLOY" --o "$O16B" --notify "$NOTIFY" 2>&1)"; RC=$?
[ "$RC" = "78" ] && ok "an ambient HARNESS_SRC does NOT choose the source (exit 78, no --src given)" || bad "HARNESS_SRC selected the source: exit $RC: $OUT"
[ -e "$O16B/gh-rest/gh" ] && bad "the deploy ran from an environment variable instead of a flag" || ok "nothing was deployed from the environment"

# ── 17. TWO SHAPES THAT MUST NOT WRITE OUTSIDE THE TARGET, OR LIE ABOUT EVIDENCE ────────────────
say_case "17. a symlink at the destination, and a directory at the ledger path"
SRC17="$T/src17"; O17="$T/o17"; EL="$T/elsewhere17"; make_src "$SRC17"; make_target "$O17"
mkdir -p "$EL"
rm -f "$O17/claims.sh"; ln -s "$EL" "$O17/claims.sh"   # a shipped name that is a link into another dir
notify_reset; deploy "$SRC17" "$O17"
[ "$RC" -ne 0 ] && ok "destination symlink -> non-zero exit ($RC)" || bad "destination symlink exited 0"
notify_success && bad "a symlink destination notified SUCCESS" || ok "no success notification"
[ -z "$(ls -A "$EL" 2>/dev/null)" ] && ok "nothing was written through the link, outside the target" || bad "the deploy wrote $(ls -A "$EL") OUTSIDE the target"
grep -q "COPY-FAIL	claims.sh	(target path is a SYMLINK" "$O17/.deploy-ledger.tsv" 2>/dev/null && ok "the ledger names the SYMLINK shape (not merely \"is a directory\")" || bad "the symlink guard did not fire (masked by the directory guard?)"
# a DIRECTORY at the ledger path: `mv` would move the temp INSIDE it and report success silently
SRC17b="$T/src17b"; O17b="$T/o17b"; make_src "$SRC17b"; make_target "$O17b"; mkdir -p "$O17b/.deploy-ledger.tsv"
notify_reset; deploy "$SRC17b" "$O17b"
[ "$RC" -eq 0 ] && ok "bytes are still verified when only the ledger cannot be installed" || bad "ledger shape changed the deploy verdict (exit $RC)"
grep -qi "ledger NOT installed" <<< "$OUT" && ok "says the ledger could NOT be installed" || bad "silently moved the temp file into the ledger directory"
# ⛔ AND THE *NOTIFICATION* MUST NOT CITE IT (review P2, cycle 3). The `say` line above is stdout; a
# caller reads the notification. It kept asserting "(this deploy's own ledger, not a listing of what was
# already there)" while no ledger existed — the invariant the code block states, broken one line over.
# Mutating the claim back leaves every other assertion green, so this is the only thing that pins it.
notify_last | grep -qi "this deploy's own ledger" && bad "the NOTIFICATION still cites a ledger that was never installed" || ok "the notification does not cite the missing ledger"
notify_last | grep -qi "could NOT be installed\|counts" && ok "the notification says the verdict rests on this run's counts instead" || bad "the notification does not say the ledger is missing: $(notify_last)"
grep -qi "ledger could NOT be written" <<< "$OUT" && ok "the verdict names the missing evidence instead of pointing at it" || bad "VERIFIED still points at a ledger that does not exist"
# ── 17b. A SYMLINKED PARENT DIRECTORY — the same escape, one directory up ───────────────────────
# The leaf guard above cannot see this shape: nothing named in the source IS the link — a DIRECTORY on
# the deploy path is. `mkdir -p` follows it, the staged `mv` writes through it, and the verify `cmp`
# resolves it the same way, so the run printed VERIFIED while the bytes landed outside the runtime.
# Refused in the preflight (78), because nothing may be written at all.
say_case "17b. a symlinked PARENT directory on the deploy path -> REFUSAL, nothing written"
SRC17c="$T/src17c"; O17c="$T/o17c"; EL17="$T/elsewhere17c"; make_src "$SRC17c"; make_target "$O17c"
mkdir -p "$EL17"
rm -rf "$O17c/gh-rest"; ln -s "$EL17" "$O17c/gh-rest"     # a shipped SUBTREE whose parent is a link
notify_reset; deploy "$SRC17c" "$O17c"
[ "$RC" = "78" ] && ok "symlinked parent directory -> exit 78 (refused before any write)" || bad "symlinked parent exited $RC, expected 78 — the bytes were written outside the target"
notify_success && bad "a deploy that writes through a symlinked directory notified SUCCESS" || ok "no success notification"
notify_failure && ok "the refusal notified FAILURE and names the cause" || bad "nobody was told the deploy was refused"
grep -qi "symlinked directory" <<< "$(notify_last)" && ok "the notification names the SYMLINKED DIRECTORY, not a generic failure" || bad "notification does not name the cause: $(notify_last)"
[ -z "$(ls -A "$EL17" 2>/dev/null)" ] && ok "nothing was written through the linked directory, outside the target" || bad "the deploy wrote $(ls -A "$EL17") OUTSIDE the target"
[ -e "$O17c/.deploy-ledger.tsv" ] && bad "the refusal wrote a ledger into a runtime it promised not to touch" || ok "no ledger — the refusal wrote NOTHING"
# ── 17c. THE WALK MUST BE COMPONENT-WISE — a link that is not the deepest component ─────────────
# `[ -L "$O/${rel%/*}" ]` (a one-component check) tests `$O/deep/inner` here, which the link makes look
# like an ordinary directory, and passes it through. Only a deepest-to-shallowest walk sees `$O/deep`.
say_case "17c. a link that is an INTERMEDIATE component (not the deepest) is still refused"
SRC17d="$T/src17d"; O17d="$T/o17d"; EL17d="$T/elsewhere17d"; make_src "$SRC17d"; make_target "$O17d"
mkdir -p "$SRC17d/deep/inner" "$EL17d"
printf '#!/bin/bash\necho deep\n' > "$SRC17d/deep/inner/thing.sh"
ln -s "$EL17d" "$O17d/deep"
notify_reset; deploy "$SRC17d" "$O17d"
[ "$RC" = "78" ] && ok "intermediate symlink component -> exit 78 (refused)" || bad "intermediate symlink exited $RC, expected 78 — a one-component check would miss it"
[ -z "$(ls -A "$EL17d" 2>/dev/null)" ] && ok "nothing was written through the intermediate link" || bad "the deploy wrote $(ls -A "$EL17d") OUTSIDE the target"
[ -e "$O17d/deep/inner/thing.sh" ] && bad "a file was created through the link" || ok "no file was staged under the linked path"

# ── 17e. THE STAGING PATH IS A WRITE TARGET — the escape one name to the LEFT of $dst ────────────
# Review P1 (2026-10-21), reproduced end-to-end before this case existed. Every guard in the copy loop
# inspected `$dst`; none inspected `$tmp`. `cp` writes THROUGH a symlink at that name, `mv -f` then
# renames the LINK onto `$dst`, and the verifier's `cmp` FOLLOWS links — so the run wrote the harness
# bytes to a path outside `$O`, left `$O/claims.sh` a link to it, and still said "VERIFIED — 74/74",
# exit 0, success notification.
#
# ⛔ THE NAMING CHANGED IN CYCLE 4 AND THIS CASE HAD TO CHANGE WITH IT (review P2, cycle 4). The staging
# name used to be `$dstdir/.<name>.deploy.$$`, so the pre-existing case planted a link there from a
# wrapper that `exec`s the deployer (pid preserved → name predictable → the vector was real, not
# contrived). That name no longer exists: the staging file is `mktemp "$dstdir/.deploy-XXXXXX"`, which
# creates it atomically with O_EXCL, so it CANNOT be pre-planted — the case as written would now pass
# vacuously while testing nothing. What is still possible is a swap INSIDE the copy, so the vector is
# now driven by a `cp` shim that replaces its own destination with a link and then writes: the copy
# must be refused, the outside file must be untouched, and the run must not claim success.
say_case "17e. a link replacing the STAGING file during the copy is refused, and nothing is certified"
SRC17e="$T/src17e"; O17e="$T/o17e"; EL17e="$T/elsewhere17e"; make_src "$SRC17e"; make_target "$O17e"
mkdir -p "$EL17e" "$T/cpbin17e"; printf 'PRECIOUS\n' > "$EL17e/precious"
EL17e_BEFORE="$(sha256_of "$EL17e/precious")"
REAL_CP17E="$(command -v cp)"
cat > "$T/cpbin17e/cp" <<SH
#!/usr/bin/env bash
# Model a writer winning the window between mktemp's create and cp's open: replace the destination (a
# staging file this run owns) with a link, then WRITE THROUGH IT.
# ⛔ THE WRITE IS DONE HERE, NOT BY `cp` (cycle 4, found under docker bash:5). BSD `cp` follows a
# symlink destination and writes through it; GNU `cp` UNLINKS it and writes a fresh regular file. A
# fixture that delegates to `cp` therefore exercises the vector on macOS and not on Linux, and the
# case silently stops testing anything there. Writing through the link explicitly is the shape being
# guarded, and it reproduces on both.
case "\${!#}" in
  */.deploy-*) rm -f "\${!#}"; ln -s "$EL17e/precious" "\${!#}"
               printf 'HARNESS-BYTES\n' >> "\${!#}" ;;
esac
exit 0
SH
chmod +x "$T/cpbin17e/cp"
notify_reset
OUT="$(PATH="$T/cpbin17e:$PATH" bash "$DEPLOY" --src "$SRC17e" --o "$O17e" --notify "$NOTIFY" 2>&1)"; RC=$?
[ "$(sha256_of "$EL17e/precious")" = "$EL17e_BEFORE" ] && bad "the fixture failed to write THROUGH the staging link — the case is vacuous" || ok "the fixture really did write outside the target (not vacuous)"
[ "$RC" -ne 0 ] && ok "a staging path replaced by a link -> non-zero exit ($RC)" || bad "certified a run whose staging path was a link (exit 0)"
grep -qi "staging path was replaced by a non-regular file" <<< "$OUT" && ok "the verdict names the staging path as the reason" || bad "refused without naming the staging path: $OUT"
[ -L "$O17e/claims.sh" ] && bad "the deployment left claims.sh as a SYMLINK" || ok "no symlink was left at the deployed path"
notify_success && bad "notified SUCCESS over a replaced staging path" || ok "no success notification"
# ⛔ AND THE NAME IS UNPREDICTABLE — this half is what pins `mktemp` itself (mutant: put the name
# back to `$dstdir/.<name>.deploy.$$` and the suite must go red). `exec` preserves the pid, so the
# staging name the helper WILL use is knowable before it starts; the link is planted at that exact
# name. With `mktemp` the planted name is never consulted and the deploy is clean; with a predictable
# name `cp` writes THROUGH the link and the outside file is destroyed.
notify_reset
OPRED="$T/opred17e"; make_target "$OPRED"
printf 'PRECIOUS-STALE\n' > "$EL17e/stale"; STALE_BEFORE="$(sha256_of "$EL17e/stale")"
cat > "$T/predict17e.sh" <<SH
#!/usr/bin/env bash
p=\$\$
# the pre-cycle-4 name, per file: \$dstdir/.<name>.deploy.\$\$
for f in claims.sh orch-loop.sh merge-one.sh; do
  ln -s "$EL17e/stale" "$OPRED/.\$f.deploy.\$p" 2>/dev/null
done
exec bash "$DEPLOY" --src "$SRC17e" --o "$OPRED" --notify "$NOTIFY" "\$@"
SH
chmod +x "$T/predict17e.sh"
OUT="$(bash "$T/predict17e.sh" 2>&1)"; RC=$?
[ "$(sha256_of "$EL17e/stale")" = "$STALE_BEFORE" ] && ok "a link planted at the OLD staging name is INERT (mktemp ignores it) — the name cannot be pre-planted" || bad "the deploy wrote OUTSIDE the target through a predictable staging name (mktemp removed?)"
[ -L "$OPRED/claims.sh" ] && bad "the deployed claims.sh is a link to the leftover" || ok "claims.sh holds real bytes, not the leftover link target"
[ "$RC" -eq 0 ] && ok "the deploy still succeeds ($RC)" || bad "a leftover link at an unused name broke the deploy (exit $RC): $OUT"
cmp -s "$SRC17e/claims.sh" "$OPRED/claims.sh" && ok "and it holds the SOURCE bytes" || bad "claims.sh does not hold the source bytes"

# ── 17f. THE VERDICT REFUSES A SYMLINK AT THE DEPLOYED PATH, even when it compares equal ──────────
# The staging-name fix above closes the write; this closes the CERTIFICATION. A `mv` shim installs a
# SYMLINK to the source at the destination AFTER the copy loop's guards have passed, so the run copied
# and the link's bytes compare equal to the source — the old verifier (`cmp` alone, which FOLLOWS links)
# called that "byte-identical". A deployed path that is a link is not the bytes this run landed.
say_case "17f. a symlink at the deployed path is never VERIFIED (cmp follows links, the verdict must not)"
SRC17f="$T/src17f"; O17f="$T/o17f"; make_src "$SRC17f"; make_target "$O17f"
mkdir -p "$T/mvbin17f"
cat > "$T/mvbin17f/mv" <<SH
#!/usr/bin/env bash
"$(command -v mv)" "\$@" || exit \$?
dst="\${!#}"
# only the deployed copies — not the ledger's own install, which also goes through mv
case "\$dst" in "$O17f"/*) case "\$(basename "\$dst")" in .deploy-ledger.tsv) ;; *) rm -f "\$dst"; ln -s "$SRC17f/\${dst#$O17f/}" "\$dst" ;; esac ;; esac
exit 0
SH
chmod +x "$T/mvbin17f/mv"
notify_reset
OUT="$(PATH="$T/mvbin17f:$PATH" bash "$DEPLOY" --src "$SRC17f" --o "$O17f" --notify "$NOTIFY" 2>&1)"; RC=$?
[ -L "$O17f/claims.sh" ] && ok "the fixture really did leave a SYMLINK at the deployed path (the assertion is not vacuous)" || bad "the fixture did not produce a symlink — the case would be vacuous"
[ "$RC" -ne 0 ] && ok "a symlink at the deployed path -> non-zero exit ($RC)" || bad "a deploy that left SYMLINKS reported success (exit 0)"
grep -qi "SYMLINK" <<< "$OUT" && ok "the verdict names the SYMLINK as the reason" || bad "refused without naming the symlink: $OUT"
notify_success && bad "a deploy that left symlinks notified SUCCESS" || ok "no success notification for a symlinked deployment"
grep -q "SYMLINK" "$O17f/.deploy-ledger.tsv" 2>/dev/null && ok "the ledger records the SYMLINK per file" || bad "the ledger does not record the symlink"

# ── 17g. THE LEDGER'S OWN TWO WRITE TARGETS — the same escape, in the evidence file ───────────────
# Review P2 (2026-10-21): cycle 1's fix hardened the copy's staging name and the ledger's, but only the
# COPY half was pinned. Mutating away the ledger-temp `rm -f`, or the `[ -L "$LEDGER" ]` refusal, left
# this suite GREEN (162/162) — while the unfixed helper wrote the ledger THROUGH the link, into a file
# outside `$O`, and the notification cited it as "this deploy's own ledger". Same defect as F4 (a branch
# never driven), one site over.
say_case "17g. a symlink at the LEDGER's temp name cannot write outside the target"
SRC17g="$T/src17g"; O17g="$T/o17g"; EL17g="$T/elsewhere17g"; make_src "$SRC17g"; make_target "$O17g"
mkdir -p "$EL17g"; printf 'VICTIM\n' > "$EL17g/victim"
VICTIM_BEFORE="$(sha256_of "$EL17g/victim")"
# `exec` preserves the pid, so `$LEDGER.$$` is knowable in advance (case 17e uses the same trick).
cat > "$T/ledger-link.sh" <<SH
#!/usr/bin/env bash
p=\$\$
ln -s "$EL17g/victim" "$O17g/.deploy-ledger.tsv.\$p" 2>/dev/null
exec bash "$DEPLOY" --src "$SRC17g" --o "$O17g" --notify "$NOTIFY" "\$@"
SH
chmod +x "$T/ledger-link.sh"
notify_reset
OUT="$(bash "$T/ledger-link.sh" 2>&1)"; RC=$?
[ "$(sha256_of "$EL17g/victim")" = "$VICTIM_BEFORE" ] && ok "the victim outside the target was NOT overwritten through the ledger temp link" || bad "the ledger was written OUTSIDE the target through the temp symlink"
[ -f "$O17g/.deploy-ledger.tsv" ] && [ ! -L "$O17g/.deploy-ledger.tsv" ] && ok "the ledger is a regular file at the target" || bad "the ledger is missing or is a SYMLINK"
[ "$RC" -eq 0 ] && ok "the deploy still succeeds (a link at the ledger temp name is never consulted)" || bad "clearing the ledger temp broke a good deploy (exit $RC): $OUT"

say_case "17h. a symlink AT the ledger path is refused, and nothing is written through it"
SRC17h="$T/src17h"; O17h="$T/o17h"; EL17h="$T/elsewhere17h"; make_src "$SRC17h"; make_target "$O17h"
mkdir -p "$EL17h"; printf 'VICTIM2\n' > "$EL17h/victim2"
VICTIM2_BEFORE="$(sha256_of "$EL17h/victim2")"
ln -s "$EL17h/victim2" "$O17h/.deploy-ledger.tsv"
notify_reset; deploy "$SRC17h" "$O17h"
[ "$(sha256_of "$EL17h/victim2")" = "$VICTIM2_BEFORE" ] && ok "the symlink target outside the runtime was not written through" || bad "the ledger was written OUTSIDE the target through the \$LEDGER link"
[ -L "$O17h/.deploy-ledger.tsv" ] && ok "the symlink is still a symlink (refused, not silently replaced)" || bad "the ledger symlink was replaced — the refusal did not fire"
grep -qi "ledger NOT installed\|is a SYMLINK" <<< "$OUT" && ok "the run names the ledger symlink refusal" || bad "the refusal was silent: $OUT"

# ── 17i. A DIRECTORY SWAPPED FOR A LINK **DURING** THE RUN — the verdict must not follow it ────────
# Review P2 (2026-10-21): the preflight's component walk is a property of the runtime AS IT WAS. A
# directory made a symlink while the run is in progress is followed by `mkdir -p`, by the staged `mv`
# and by the verify `cmp`, so the run certifies bytes OUTSIDE the runtime it was given. Refusing at the
# preflight cannot catch it; only re-checking the chain in the VERIFY loop can. Driven with a `cp` shim
# that plants the link just before the copy that would traverse it.
if [ -n "$(command -v cp)" ]; then
  say_case "17i. a directory symlinked MID-RUN is caught by the verdict, not only by the preflight"
  SRC17i="$T/src17i"; O17i="$T/o17i"; EL17i="$T/elsewhere17i"; make_src "$SRC17i"; make_target "$O17i"
  rm -rf "$O17i/gh-rest"; mkdir -p "$O17i/gh-rest" "$EL17i"
  mkdir -p "$T/cpbin17i"
  REAL_CP17I="$(command -v cp)"
  cat > "$T/cpbin17i/cp" <<SH
#!/usr/bin/env bash
# just before the subdirectory copy, swap the REAL directory for a link (nothing else changes)
case "\${!#}" in *gh-rest/*) rm -rf "$O17i/gh-rest"; mkdir -p "$EL17i"; ln -s "$EL17i" "$O17i/gh-rest" ;; esac
exec "$REAL_CP17I" "\$@"
SH
  chmod +x "$T/cpbin17i/cp"
  notify_reset
  OUT="$(PATH="$T/cpbin17i:$PATH" bash "$DEPLOY" --src "$SRC17i" --o "$O17i" --notify "$NOTIFY" 2>&1)"; RC=$?
  [ -L "$O17i/gh-rest" ] && ok "the fixture really did swap the directory for a link mid-run (not vacuous)" || bad "the fixture did not produce the mid-run link"
  [ "$RC" -ne 0 ] && ok "a directory symlinked mid-run -> non-zero exit ($RC)" || bad "a run that wrote through a mid-run link reported success (exit 0)"
  grep -qi "SYMLINK" <<< "$OUT" && ok "the verdict names the symlinked directory" || bad "refused without naming the cause: $OUT"
  notify_success && bad "a run that wrote outside the target notified SUCCESS" || ok "no success notification for a mid-run symlinked directory"
fi

# ── 17j. THE SOURCE SIDE, MID-RUN — a file swapped for a link is never certified ──────────────────
# Review P1 (cycle 3). The preflight refuses a source that SHIPS a link, but that walk is a property of
# the source AS IT WAS. A file replaced by a symlink DURING the run is followed by both `cp -p "$SRC/$rel"`
# and the verify `cmp`, so bytes from OUTSIDE the harness land in `$O` and are certified. Reproduced
# against the pre-fix guard: `VERIFIED — 7/7`, exit 0, `$O/claims.sh` holding the impostor's bytes.
# Reachable without an attacker (a `git checkout`/stash or an editor's atomic save in the source).
say_case "17j. a source file symlinked MID-RUN -> FAILURE, the outside bytes are never certified"
SRC17j="$T/src17j"; O17j="$T/o17j"; EL17j="$T/elsewhere17j"; make_src "$SRC17j"; make_target "$O17j"
mkdir -p "$EL17j"; printf 'echo OUTSIDE-THE-HARNESS\n' > "$EL17j/impostor.sh"
mkdir -p "$T/cpbin17j"
REAL_CP17J="$(command -v cp)"
cat > "$T/cpbin17j/cp" <<SH
#!/usr/bin/env bash
# the first copy of claims.sh swaps the SOURCE for a link: the next cp and the cmp both follow it
case "\${!#}" in
  */.deploy-*)
    case "\$*" in *"$SRC17j/claims.sh"*)
      rm -f "$SRC17j/claims.sh"; ln -s "$EL17j/impostor.sh" "$SRC17j/claims.sh" ;;
    esac ;;
esac
exec "$REAL_CP17J" "\$@"
SH
chmod +x "$T/cpbin17j/cp"
notify_reset
OUT="$(PATH="$T/cpbin17j:$PATH" bash "$DEPLOY" --src "$SRC17j" --o "$O17j" --notify "$NOTIFY" 2>&1)"; RC=$?
[ -L "$SRC17j/claims.sh" ] && ok "the fixture really did symlink the SOURCE mid-run (the assertion is not vacuous)" || bad "the fixture did not produce the mid-run source link"
[ "$RC" -ne 0 ] && ok "a source file symlinked mid-run -> non-zero exit ($RC)" || bad "a deploy that copied bytes from OUTSIDE the harness reported success (exit 0)"
grep -qi "became a SYMLINK" <<< "$OUT" && ok "the verdict names the SOURCE symlink as the reason" || bad "refused without naming the source symlink: $OUT"
notify_success && bad "a deploy that copied an outside file notified SUCCESS" || ok "no success notification for a mid-run source link"
grep -q "OUTSIDE-THE-HARNESS" "$O17j/claims.sh" 2>/dev/null && bad "the IMPOSTOR's bytes really did land in the runtime" || ok "the runtime never received the outside bytes"

# ── 17k. THE INVENTORY'S EXIT STATUS — an unreadable walk is not an absence of entries ────────────
# Review P2 (cycle 3): the probe's OTHER half was unpinned. Mutating the wide probe back to `-type l`
# reds case 14b, but mutating ONLY the status read (`NONREG="$(…)` with no `if !`) left the suite
# CLEAN — while a `find` without `-quit` (busybox/toybox class) exits non-zero, the test read false, and
# the run said VERIFIED over a source shipping a FIFO it never copied. That is #2041's own shape.
# Driven with a `find` stub that fails only when the non-regular probe's arguments are used.
say_case "17k. the non-regular-entry walk FAILING is a refusal, not an empty result"
if [ "$(id -u)" = "0" ] && ! command -v mkfifo >/dev/null 2>&1; then
  echo "  (status-read sub-case skipped — no mkfifo on this platform)"
else
  SRC17k="$T/src17k"; O17k="$T/o17k"; make_src "$SRC17k"; make_target "$O17k"
  mkfifo "$SRC17k/pipe.sh"
  REAL_FIND="$(command -v find)"
  mkdir -p "$T/findbin17k"
  cat > "$T/findbin17k/find" <<SH
#!/usr/bin/env bash
# fail ONLY on the non-regular probe (the invocation carrying '!'); pass every other call through
case "\$*" in *"!"*) echo "find: unrecognized: -quit" >&2; exit 1 ;; esac
exec "$REAL_FIND" "\$@"
SH
  chmod +x "$T/findbin17k/find"
  notify_reset
  OUT="$(PATH="$T/findbin17k:$PATH" bash "$DEPLOY" --src "$SRC17k" --o "$O17k" --notify "$NOTIFY" 2>&1)"; RC=$?
  [ "$RC" = "78" ] && ok "an unreadable non-regular walk -> exit 78 (refused)" || bad "a FAILING walk was read as 'no entries' (exit $RC) — the status read is not load-bearing"
  grep -qi "inventory for NON-REGULAR entries FAILED\|non-regular entry" <<< "$OUT" && ok "the refusal names the walk or the entry" || bad "refused without naming the cause: $OUT"
  notify_success && bad "a source whose walk could not be read notified SUCCESS" || ok "no success notification"
  [ -e "$O17k/pipe.sh" ] && bad "the refusal still wrote to the target" || ok "nothing was written by the refusal"
fi

# ── 17l. A SOURCE LINKED *AFTER* ITS OWN COPY — the verify-side source arm, on its own ────────────
# Review P2 (cycle 3). Case 17j is caught earlier, by the POST-COPY re-check, so it cannot pin the
# verify-side SOURCE arm at all: mutating that arm away leaves the suite GREEN. This case creates the
# narrow window it exists for — file A is copied and re-checked while still a real file, and only THEN
# is the SOURCE of A replaced by a link (during the copy of the last file), so the copy loop has already
# finished with A and only the verdict can see it.
say_case "17l. a source linked AFTER its own copy is still caught by the VERDICT"
SRC17l="$T/src17l"; O17l="$T/o17l"; EL17l="$T/elsewhere17l"; make_src "$SRC17l"; make_target "$O17l"
mkdir -p "$EL17l"; printf 'echo IMPOSTOR-LATE\n' > "$EL17l/late.sh"
mkdir -p "$T/cpbin17l"
REAL_CP17L="$(command -v cp)"
cat > "$T/cpbin17l/cp" <<SH
#!/usr/bin/env bash
# on the LAST source file's copy, symlink the FIRST one — that one is already copied and re-checked
# the staging name is now unpredictable, so the trigger is the FILE being copied, not the tmp name
case "\$*" in
  *port-provenance.txt*)
    rm -f "$SRC17l/orch-loop.sh"; ln -s "$EL17l/late.sh" "$SRC17l/orch-loop.sh" ;;
esac
exec "$REAL_CP17L" "\$@"
SH
chmod +x "$T/cpbin17l/cp"
ORCH17L_BEFORE="$(sha256_of "$SRC17l/orch-loop.sh")"   # the source is a LINK by the time we assert
notify_reset
OUT="$(PATH="$T/cpbin17l:$PATH" bash "$DEPLOY" --src "$SRC17l" --o "$O17l" --notify "$NOTIFY" 2>&1)"; RC=$?
[ -L "$SRC17l/orch-loop.sh" ] && ok "the fixture linked the source only after its own copy (not vacuous)" || bad "the fixture did not produce the late source link"
[ "$RC" -ne 0 ] && ok "a source linked after its copy -> non-zero exit ($RC)" || bad "the verdict certified a run whose source is now a link (exit 0)"
grep -qi "became a SYMLINK" <<< "$OUT" && ok "the verdict names the source symlink" || bad "refused without naming it: $OUT"
# ⛔ AND THE LEDGER ROW IS REAL TSV (review P2, cycle 5). This arm's row was written with a LITERAL
# backslash-t instead of a tab, so it was a single field — `awk -F'\t' '{print NF}'` yielded 1 while every
# sibling row yielded 2 or 3, and the README sells this file as the per-file TSV evidence.
_rows="$(awk -F'\t' '/orch-loop\.sh/ {print NF}' "$O17l/.deploy-ledger.tsv" 2>/dev/null | tr '\n' ' ')"
case "$_rows" in
  *"1 "*) bad "a ledger row for orch-loop.sh has only 1 tab-separated field (a literal \\t instead of a tab?)" ;;
  *[23]*) ok "the source-symlink ledger row is real TSV ($_rows fields)" ;;
  *) bad "no ledger row found for orch-loop.sh (rows: '$_rows')" ;;
esac
notify_success && bad "notified SUCCESS over a late-linked source" || ok "no success notification"
# the file itself was copied correctly BEFORE the swap: the point is the verdict, not the bytes
[ "$(sha256_of "$O17l/orch-loop.sh")" = "$ORCH17L_BEFORE" ] && ok "sanity: the deployed orch-loop.sh is the ORIGINAL (the swap came after its copy)" || bad "sanity: the deployed orch-loop.sh is not the original — the case is not exercising the late window"

# ── 18. THE EXECUTABLE BIT IS ASSERTED, NOT INHERITED FROM `cp -p` ───────────────────────────────
say_case "18. a copy that drops the mode is repaired (a 0644 merge-one.sh is a loop that cannot spawn)"
# Without this case the block above was unfalsifiable: `cp -p` carried the mode, so deleting the
# helper's own chmod left every assertion green — the comment credited code that was not load-bearing.
SRC18="$T/src18"; O18="$T/o18"; make_src "$SRC18"; make_target "$O18"
mkdir -p "$T/cpbin18"
cat > "$T/cpbin18/cp" <<'SH'
#!/usr/bin/env bash
# a cp that ignores -p, the platform whose mode preservation we must not trust. NOTE the QUOTED
# heredoc delimiter: backticks in an unquoted heredoc BODY are command substitution, and the word
# `cp` in a comment ran the real cp with no operands on the first attempt.
args=(); for a in "$@"; do [ "$a" = "-p" ] || args+=("$a"); done
"${REAL_CP:?}" "${args[@]}" || exit $?
# ⛔ FORCE THE MODE HERE, DO NOT RELY ON `cp` DROPPING IT (cycle 6, found under docker bash:5). BSD `cp`
# without -p leaves an EXISTING destination's mode alone (so the mktemp 0600 survives); GNU `cp` still
# applies the source's mode. Delegating the drop to `cp` therefore makes this case platform-dependent —
# it exercised the repair on macOS and nothing at all on Linux. Setting 0600 explicitly is the shape
# being guarded and reproduces on both.
for a in "${args[@]}"; do
  case "$a" in */.deploy-*) chmod 0600 "$a" 2>/dev/null || true ;; esac
done
# ⛔ AND DO NOT FORCE A MODE HERE (review P2, cycle 5). This shim used to `chmod 644` the staged file so
# the executable bit would be missing — but that also MASKED what mode the deploy actually lands: once
# the staging file is pre-created by `mktemp` (0600) a plain `cp` leaves it 0600 and the old shim turned
# that into 0644, so the case could not see the regression it is built for. Dropping `-p` is the whole
# fixture; whatever the helper lands is what gets asserted below.
exit 0
SH
chmod +x "$T/cpbin18/cp"
notify_reset
OUT="$(REAL_CP="$REAL_CP" PATH="$T/cpbin18:$PATH" bash "$DEPLOY" --src "$SRC18" --o "$O18" --notify "$NOTIFY" 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && ok "deploy without -p still verifies (exit 0)" || bad "deploy without -p exited $RC: $OUT"
[ -x "$O18/merge-one.sh" ] && ok "the helper RESTORED the executable bit itself" || bad "the executable bit was lost (only cp -p was carrying it)"
# ⛔ AND THE WHOLE MODE, not just the exec bit (review P2, cycle 5). `mktemp` pre-creates 0600 and a `cp`
# that ignores `-p` does not change an existing destination's mode, so the deploy landed 0600/0711 while
# every other assertion stayed green. The mode now comes from the SOURCE explicitly.
mode_of_test() { if stat -f %Lp "$1" >/dev/null 2>&1; then stat -f %Lp "$1"; else stat -c %a "$1" 2>/dev/null; fi; }
for _f in merge-one.sh port-provenance.txt gh-rest/gh; do
  [ "$(mode_of_test "$O18/$_f")" = "$(mode_of_test "$SRC18/$_f")" ] && ok "18: $_f lands with the SOURCE's mode ($(mode_of_test "$SRC18/$_f"))" || bad "18: $_f landed $(mode_of_test "$O18/$_f"), source is $(mode_of_test "$SRC18/$_f") — the mode came from the staging file, not the source"
done

# ── 18b. A `chmod` THAT LIES IS CAUGHT BY THE VERDICT, not only by this suite ────────────────────
# Review P3 (cycle 6). The copy applies the source's mode, but if `chmod` returns 0 and the mode does
# not actually change (a kernel clearing a setgid bit, a mount masking bits, a hostile shim) the run
# used to certify VERIFIED with a mode the source does not have — the branch's whole mode regression
# would have been caught by the TEST but not by the TOOL. The verify loop now compares the mode, so
# this fails closed.
say_case "18b. a chmod that silently does nothing -> FAILURE (the verdict compares the mode)"
SRC18b="$T/src18b"; O18b="$T/o18b"; make_src "$SRC18b"; make_target "$O18b"
mkdir -p "$T/bin18b"; REAL_CHMOD18B="$(command -v chmod)"
cat > "$T/bin18b/chmod" <<SH
#!/usr/bin/env bash
# report success, change nothing — the "chmod succeeded but the result differs" shape
case "\$1" in [0-7][0-7][0-7]*) exit 0 ;; esac
exec "$REAL_CHMOD18B" "\$@"
SH
chmod +x "$T/bin18b/chmod"
# AND a `cp` that ignores `-p`, or the shim above is inert: `cp -p` lands the source mode anyway and a
# lying chmod then changes nothing. The pair is what makes the mode actually wrong.
REAL_CP18B="$(command -v cp)"   # BEFORE the heredoc: it is unquoted, so this expands at creation
cat > "$T/bin18b/cp" <<SH
#!/usr/bin/env bash
args=(); for a in "\$@"; do [ "\$a" = "-p" ] || args+=("\$a"); done
"$REAL_CP18B" "\${args[@]}" || exit \$?
# same platform note as case 18: force the mode so the shim does not depend on cp's semantics
# (NO BACKTICKS in this body — an unquoted heredoc runs them, which is how this line first broke)
# ⛔ THE ABSOLUTE PATH, NOT `chmod` (cycle 6): the liar shim also answers `chmod 0600`, so a bare
# `chmod` here was swallowed and the file stayed at the source mode — the case proved nothing.
for a in "\${args[@]}"; do
  case "\$a" in */.deploy-*) "$REAL_CHMOD18B" 0600 "\$a" 2>/dev/null || true ;; esac
done
exit 0
SH
chmod +x "$T/bin18b/cp"
notify_reset
OUT="$(REAL_CP18B="$REAL_CP18B" PATH="$T/bin18b:$PATH" bash "$DEPLOY" --src "$SRC18b" --o "$O18b" --notify "$NOTIFY" 2>&1)"; RC=$?
[ "$RC" -ne 0 ] && ok "a lying chmod -> non-zero exit ($RC)" || bad "certified VERIFIED with a mode the source does not have (exit 0)"
grep -qi "mode differs" <<< "$OUT" && ok "the verdict names the MODE as the reason" || bad "refused without naming the mode: $OUT"
notify_success && bad "notified SUCCESS over a mode that differs from the source" || ok "no success notification"

# ── 18c. NO USABLE `stat` — the deploy still succeeds, and the verdict says the mode is NOT evidence ──
# Review P2 (cycle 6). `mode_of` accepts only 3-4 octal digits, because neither stat form is safe to
# believe on its own: on GNU, `-f` takes no argument, so `stat -f %Lp "$1"` treats `%Lp` as a PATH and
# exits 0 with a multi-line filesystem dump whenever a file of that name exists. The stub below prints
# exactly that shape and exits 0. The deploy must (a) not fail — the BYTES are what it verified — and
# (b) not imply the mode came from the source. Without the validation, `chmod` receives the dump, the
# copy is refused, and (a) fails; without MODE_UNSET, the verdict says nothing and (b) fails.
say_case "18c. an unusable 'stat' -> deploy succeeds, and the verdict says the MODE was not set"
SRC18c="$T/src18c"; O18c="$T/o18c"; make_src "$SRC18c"; make_target "$O18c"
mkdir -p "$T/bin18c"
cat > "$T/bin18c/stat" <<'SH'
#!/usr/bin/env bash
# the GNU `-f` hazard: exit 0 with a filesystem dump, for every form
printf '  File: "%%Lp"\n    ID: 0   Namelen: 255   Type: UNKNOWN\n'
exit 0
SH
chmod +x "$T/bin18c/stat"
notify_reset
OUT="$(PATH="$T/bin18c:$PATH" bash "$DEPLOY" --src "$SRC18c" --o "$O18c" --notify "$NOTIFY" 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && ok "18c: an unusable stat does not fail the deploy (the bytes are verified)" || bad "18c: exited $RC — a garbage mode was fed to chmod instead of being rejected: $OUT"
grep -qi "mode NOT set from the source" <<< "$OUT" && ok "18c: the verdict says the MODE was not set from the source" || bad "18c: the verdict implies the mode is the source's when it was never read: $OUT"
cmp -s "$SRC18c/claims.sh" "$O18c/claims.sh" && ok "18c: the bytes still landed and verified" || bad "18c: the bytes did not land"

# ── 19. THE IDENTITY RECORD — a redeploy must not make the drift gate cry "hand edit" ────────────
say_case "19. a stale .agent-infra-stamp.json is NAMED in the verdict, not hidden"
# install.sh folds $O/*.sh into `payloadSha256`; check-deployed-drift.sh reports a mismatch as its
# top-severity "post-install hand edit". Nothing re-stamped after a redeploy, so every legitimate
# deploy produced that alarm and it stopped meaning anything.
SRC19="$T/src19"; O19="$T/o19"; make_src "$SRC19"; make_target "$O19"
printf '{"payloadSha256":"deadbeefdeadbeef"}\n' > "$O19/.agent-infra-stamp.json"
notify_reset; deploy "$SRC19" "$O19"
[ "$RC" -eq 0 ] && ok "the bytes still verify (the stamp is not the deploy's evidence)" || bad "a stale stamp failed the deploy (exit $RC)"
grep -qi "identity record STALE" <<< "$OUT" && ok "the verdict names the stale identity record" || bad "silently left a stale payloadSha256 behind"
grep -qi "STALE" <<< "$(notify_last)" && ok "the notification names it too (a caller reads only that)" || bad "the notification reads as fully current: $(notify_last)"
grep -q "STALE-STAMP" "$O19/.deploy-ledger.tsv" 2>/dev/null && ok "the ledger records the stale stamp" || bad "the ledger does not record the stale stamp"
# and a matching stamp is NOT reported (no false alarm on a fresh install's own record)
STAMP_LIVE="$( ( cd "$O19" && for f in *.sh; do [ -f "$f" ] || continue; $SHA_CMD "$f"; done ) | $SHA_CMD | awk '{print $1}' )"
printf '{"payloadSha256":"%s"}\n' "$STAMP_LIVE" > "$O19/.agent-infra-stamp.json"
notify_reset; deploy "$SRC19" "$O19"
grep -qi "identity record STALE" <<< "$OUT" && bad "a CURRENT stamp was reported as stale (false alarm)" || ok "a current identity record is not flagged"

# ── 19b. AN INCOMPLETE FOLD IS NOT A COMPARISON — no false "hand edit" alarm ──────────────────────
# The fold's `|| exit 3` was INERT: `set -uo pipefail` made the pipeline status 3, but nothing read the
# assignment's rc, so `LIVE` kept whatever `awk` printed. One unreadable `$O/*.sh` — a root-owned 0600
# leftover, or a script the repo no longer ships — therefore produced a PARTIAL digest, `REC != LIVE`,
# and the verdict told the operator their identity record was STALE and to re-run install.sh over a
# record that was CORRECT. install.sh's own `prov_payload_hash` fails on the same file, so the step it
# recommends cannot fix it. The truthful verdict is "NOT CHECKED" — the discipline both siblings
# already implement (install.sh → UNKNOWN, check-deployed-drift.sh → unknown, whose comment records
# the measurement: a chmod-000 `$O/claims.sh` produced a false DRIFT).
if [ "$(id -u)" = "0" ]; then
  echo "  (unreadable-payload sub-case skipped — running as root, where chmod 000 is still readable)"
else
  SRC19b="$T/src19b"; O19b="$T/o19b"; make_src "$SRC19b"; make_target "$O19b"
  notify_reset; deploy "$SRC19b" "$O19b"
  [ "$RC" -eq 0 ] && ok "setup deploy verified" || bad "setup deploy exited $RC: $OUT"
  # a *.sh the SOURCE does not ship, so no copy replaces it — the stale-hand-placed shape
  printf '#!/bin/bash\n# retired two releases ago\n' > "$O19b/stale-retired.sh"
  STAMP_COMPLETE="$( ( cd "$O19b" && for f in *.sh; do [ -f "$f" ] || continue; $SHA_CMD "$f"; done ) | $SHA_CMD | awk '{print $1}' )"
  printf '{"payloadSha256":"%s"}\n' "$STAMP_COMPLETE" > "$O19b/.agent-infra-stamp.json"
  chmod 000 "$O19b/stale-retired.sh"      # the record covers it; the fold can no longer read it
  notify_reset; deploy "$SRC19b" "$O19b"
  chmod 644 "$O19b/stale-retired.sh"
  [ "$RC" -eq 0 ] && ok "the bytes still verify with an unreadable sibling (exit 0)" || bad "exit $RC: $OUT"
  grep -qi "identity record STALE" <<< "$OUT" && bad "an INCOMPLETE fold was reported STALE — a false hand-edit alarm over a correct record" || ok "an incomplete fold is not reported as STALE"
  grep -qi "identity record NOT CHECKED" <<< "$OUT" && ok "the verdict says the identity record could NOT be checked" || bad "silently said nothing about an unreadable payload: $OUT"
  grep -qi "STALE" <<< "$(notify_last)" && bad "the notification cried STALE over an unreadable payload" || ok "the notification carries no false STALE"
  grep -q "STAMP-UNCHECKED" "$O19b/.deploy-ledger.tsv" 2>/dev/null && ok "the ledger records STAMP-UNCHECKED, not STALE-STAMP" || bad "the ledger does not record the cannot-check"
  # ⛔ AND THE STALE VERDICT IS NOT SIMPLY GONE: with a READABLE payload and a wrong record it still fires.
  printf '{"payloadSha256":"deadbeefdeadbeef"}\n' > "$O19b/.agent-infra-stamp.json"
  notify_reset; deploy "$SRC19b" "$O19b"
  grep -qi "identity record STALE" <<< "$OUT" && ok "a readable payload with a wrong record is still STALE (the check was not weakened)" || bad "the STALE verdict was lost entirely: $OUT"
fi

echo
# ── 20. THE REMEDY TEXT — install.sh must not send the operator back to a bare depth-1 `cp` ───────
# install.sh's DRIFTED / provenance warnings are the most operator-visible remedy in the harness, and
# README §4.1 tells the operator to RE-RUN install.sh after a redeploy. While they printed
# `cp '$HERE'/*.sh '$O'/`, the documented post-deploy step recommended the unverified depth-1 copy this
# whole file exists to replace (#2041) — immediately after a verified deploy. Pinned here so the text
# cannot drift back: the suite that owns the deploy remedy owns the words that invoke it.
say_case "20. every redeploy remedy THIS CHANGE OWNS names deploy-harness.sh, never a bare cp *.sh"
INSTALL_SH="$HERE/install.sh"
if [ -f "$INSTALL_SH" ]; then
  BARE_CP="$(grep -nE 'warn .*cp .*\*\.sh' "$INSTALL_SH")"
  [ -z "$BARE_CP" ] && ok "no install.sh warning recommends a bare 'cp *.sh' redeploy" || bad "install.sh still prints an unverified cp remedy: $BARE_CP"
  grep -q 'deploy-harness\.sh' "$INSTALL_SH" && ok "install.sh names deploy-harness.sh as the redeploy remedy" || bad "install.sh never names the verified redeploy helper"
else
  bad "install.sh is missing from the harness directory — the remedy cannot be pinned"
fi
# ⛔ THE CLASS, NOT ONE FILE (review P2, 2026-10-21). The check above looks at install.sh only, so five
# operator-facing sites in the SAME commit's own edited files kept printing the unverified depth-1 copy
# — including the two controller-startup FATALs an operator actually sees. They were converted; this is
# what keeps the class from reappearing in a file the suite does not otherwise look at.
# ⚠️ COORDINATION NOTE (open PR #2271 `feat/mac-pin-parity`): that PR rewrites the same two install.sh
# warning lines and substitutes a pinned tree (`cp '$SHIPPED'/*.sh`). If it lands, the assertion above
# SHOULD red — a depth-1 glob copy is exactly what this forbids — and the correct resolution is to
# emit `deploy-harness.sh --src '$SHIPPED' --o '$O'`, not to relax this check. Do not "fix" a red here
# by deleting the assertion; that re-introduces #2041.
# Scoped to REMEDY MESSAGES, not to every occurrence: a test fixture that seeds a throwaway runtime
# with a `cp` (selftest.sh's own `deploy()` helper) is not operator advice, and reddening on it would
# make this assertion cry wolf until someone deleted it — which is how a real check gets removed.
# ⛔ SCOPED TO THE SITES THIS CHANGE OWNS — because a repo-wide prose scan cannot be made honest.
# Cycle 2 asked for the scan to cover "the effect, not one spelling", and the attempt is recorded here
# rather than silently dropped: an effect-based scan over every shipped script REDS on (a) COMMENTS that
# describe the old `cp` in order to condemn it (install.sh:817, check-deployed-drift.sh:61) and (b) the
# deploy IMPLEMENTATIONS this issue explicitly leaves as remaining work (deploy-crossbox.sh:59,
# cloud-cell-quiesce.sh:78). Excluding those needs the scan to tell prose from code from advice, and each
# exclusion widens the hole — this repo has already learned that no text parser can prove execution
# ("each hardened regex just moved the gap", run-bash-shards.sh's own header). A gate whose only failure
# is wording is also the process-weight trap. So the CLAIM is narrowed to what is measured: the remedy
# SITES this change converted must name the helper. ⚠️ WHAT THIS IS AND IS NOT (review P2, cycle 3): it
# is a per-FILE string-presence check. `chain-merge.sh`, `check-deployed-drift.sh` and `report.sh` have
# exactly one mention each, so for them file-level IS site-level; `orch-loop.sh` (9 mentions),
# `refresh-candidates.sh` (4), `install.sh` (3) and `dispatch-merge.sh` (2) are not — reverting ONE
# remedy in those leaves the assertion green. Only `install.sh` additionally gets a site-level check
# (the `warn .*cp .*\.sh` arm above). A file-level check is what this is, and claiming more would be the
# same overclaim the case exists to prevent.
# never touched is not claimed.
REMEDY_SITES="install.sh orch-loop.sh dispatch-merge.sh chain-merge.sh refresh-candidates.sh check-deployed-drift.sh report.sh"
for _site in $REMEDY_SITES; do
  [ -f "$HERE/$_site" ] && ok "remedy site present: $_site (the assertion below is not vacuous for it)" || bad "remedy site missing from the harness: $_site"
  grep -q 'deploy-harness\.sh' "$HERE/$_site" 2>/dev/null && ok "  $_site names the verified redeploy helper" || bad "  $_site does not name deploy-harness.sh — its remedy is the unverified copy again"
done

echo
# ── 21. PRODUCER/CHECKER AGREEMENT — driven from install.sh's OWN fold ───────────────────────
# The `payloadSha256` fold exists in four places (install.sh's `prov_payload_hash`, the cell
# supervisor's `o_payload_hash`, the helper's checker, and — until review P2 — a literal copy of it
# HERE). Case 19's "current stamp is not flagged" assertion built its expectation with this file's own
# copy, so it pinned the checker against the TEST and never against the PRODUCER: if `install.sh`'s
# fold and the helper's ever diverged, every redeploy would print `identity record STALE — run
# install.sh to re-stamp` immediately after a re-stamp — the exact "the alarm stopped meaning
# anything" harm §4.1 exists to remove — and this suite stayed green.
# This case extracts install.sh's `prov_payload_hash()` and drives IT, so what is under test is the
# two shipped implementations agreeing.
say_case "21. a stamp produced by install.sh's own fold is not called STALE by the helper"
if [ -f "$HERE/install.sh" ]; then
  sed -n '/^prov_payload_hash() {/,/^}/p' "$HERE/install.sh" > "$T/prov_payload_hash.sh"
  if [ -s "$T/prov_payload_hash.sh" ]; then
    SRC21="$T/src21"; O21="$T/o21"; make_src "$SRC21"; make_target "$O21"
    notify_reset; deploy "$SRC21" "$O21"      # land the bytes first, as a real install would
    [ "$RC" -eq 0 ] && ok "the redeploy target starts from a verified deployment" || bad "setup deploy exited $RC: $OUT"
    STAMP_PROD="$(O="$O21" PROV_SHA="$SHA_CMD" bash -c 'set -uo pipefail; . "$1" || exit 1; prov_payload_hash' _ "$T/prov_payload_hash.sh" 2>/dev/null)"
    if [ -n "$STAMP_PROD" ]; then
      ok "install.sh's prov_payload_hash produces a payload digest"
      printf '{"payloadSha256":"%s"}\n' "$STAMP_PROD" > "$O21/.agent-infra-stamp.json"
      notify_reset; deploy "$SRC21" "$O21"
      grep -qi 'identity record STALE' <<< "$OUT" \
        && bad "a stamp written from install.sh's own fold was reported STALE — the checker's fold diverges from the producer's" \
        || ok "a stamp from install.sh's own fold is NOT reported stale (producer == checker)"
      grep -qi 'STALE' <<< "$(notify_last)" && bad "the notification cried STALE over the producer's own stamp" || ok "the notification stays quiet too"
    else
      bad "install.sh's prov_payload_hash yielded nothing — producer/checker agreement cannot be asserted"
    fi
  else
    bad "could not extract prov_payload_hash from install.sh — the fold is checked against nothing"
  fi
else
  bad "install.sh is missing — producer/checker agreement cannot be asserted"
fi

echo
echo "════════════════════════════════════════"
printf 'PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && { echo "RESULT: CLEAN"; exit 0; }
echo "RESULT: $FAIL FAILURE(S)"
exit 1
