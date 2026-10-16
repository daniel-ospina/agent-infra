#!/usr/bin/env bash
# verify.sh — re-run every piece of evidence for the clamp-death fix (#1214) and print raw output.
#
# Read-only against the installed pi tree: it CHECKs the patch (behavioural probe) rather than
# applying it. Run after apply.sh to confirm the fix is genuinely in effect, and after an upgrade
# to find out that it is not.
#
# Exit codes: 0 all evidence holds · 1 patch absent (or patch state unverifiable) · 2 the durable-
#             record test failed · 3 the extension guard test failed · 4 the #1215 watchdog suite
#             failed · 5 the summarization budget floor test failed · 6 the summarization clamp
#             exemption test failed.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
export NODE_ENV="${NODE_ENV:-test}"

status=0
section() { printf '\n\033[1m──── %s ────\033[0m\n' "$1"; }

section "1/6  patch state + clamp behaviour against the LIVE bundle (change b)"
bash "$HERE/apply.sh" --check
patch_status=$?
[ "$patch_status" -eq 0 ] || {
	printf '\n⛔ the source patch is NOT in effect (exit %s). Run: bash %s/apply.sh\n' "$patch_status" "$HERE" >&2
	status=1
}

section "2/6  a failed compaction leaves a DURABLE session-file entry (change a)"
if node "$HERE/tests/verify-a-durable-failure-record.mjs"; then
	printf '\n✅ change (a) holds\n'
else
	printf '\n⛔ change (a) FAILED\n' >&2
	status=2
fi

section "3/6  the upgrade-proof extension guard (change b, extension layer)"
if npx --yes tsx "$REPO_ROOT/extensions/clamp-output-floor.test.ts"; then
	printf '\n✅ change (b) extension layer holds\n'
else
	printf '\n⛔ the extension guard FAILED\n' >&2
	status=3
fi

section "4/6  the shipped detector is still green (change a, #1215 — untouched by this patch)"
if npx --yes tsx "$REPO_ROOT/extensions/compaction-watchdog.test.ts"; then
	printf '\n✅ the #1215 watchdog suite still holds\n'
else
	printf '\n⛔ the #1215 watchdog suite regressed\n' >&2
	status="${status:-4}"
	[ "$status" -eq 0 ] && status=4
fi

section "5/6  the summarization budget never sits below the summary it must preserve (change d, #1263)"
if node "$HERE/tests/verify-summarization-budget-floor.mjs"; then
	printf '\n✅ change (d) holds\n'
else
	printf '\n⛔ change (d) FAILED\n' >&2
	status="${status:-5}"
	[ "$status" -eq 0 ] && status=5
fi

section "6/6  the summarization request is exempt from the clamp, normal turns are not (change e, #1316)"
if node "$HERE/tests/verify-summarization-clamp-exemption.mjs"; then
	printf '\n✅ change (e) holds\n'
else
	printf '\n⛔ change (e) FAILED\n' >&2
	status="${status:-6}"
	[ "$status" -eq 0 ] && status=6
fi

printf '\n'
if [ "$status" -eq 0 ]; then
	printf '\033[1m✅ ALL EVIDENCE HOLDS\033[0m — the clamp death is fixed and the guard is armed.\n'
else
	printf '\033[1m⛔ EVIDENCE INCOMPLETE (exit %s)\033[0m — the clamp death is NOT fully covered.\n' "$status"
fi
exit "$status"
