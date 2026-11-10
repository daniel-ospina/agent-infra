#!/usr/bin/env bash
# apply.sh — re-arm the pi clamp-death fix on the INSTALLED pi tree, and PROVE it is in place.
#
# This is the entrypoint a postinstall hook / fleet bootstrap / human runs after any pi upgrade.
# It never fails quietly: every refusal exits non-zero with an explicit reason.
#
#   scripts/pi-patches/apply.sh            # apply (idempotent) + verify
#   scripts/pi-patches/apply.sh --check    # 0 = fix in place · 1 = fix ABSENT · 3 = version drift
#   scripts/pi-patches/apply.sh --revert   # restore the pre-patch files
#
# Exit codes: 0 ok · 1 not applied (--check) · 2 bad manifest/anchors · 3 version drift · 4 verify failed
#
# Why this file exists: the defect is inside pi's own request path (pi-ai's
# `clampMaxTokensToContext`), so it cannot be fixed from configuration. A patch inside
# node_modules is reverted by the next install — so the patch is a version-pinned ARTIFACT
# plus this script, and the pin is enforced loudly rather than assumed.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NODE_BIN="${NODE_BIN:-node}"

if ! command -v "$NODE_BIN" >/dev/null 2>&1; then
	printf '\n⛔ pi-patches: node is not on PATH — cannot apply or verify the fix.\n\n' >&2
	exit 2
fi

exec "$NODE_BIN" "$HERE/apply.mjs" "$@"
