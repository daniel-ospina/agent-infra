#!/usr/bin/env bash
# patch-pi-retry.sh — apply the agent-infra offline-resume retry patch to the
# installed pi package (idempotent; safe to run on every sync).
#
# Upstream pi's agent-level retry policy (settings.json `retry.*`) uses pure
# exponential backoff with NO delay cap (`baseDelayMs * 2^(attempt-1)`). With
# the default `maxRetries: 3` that means 3 quick retries (2s/4s/8s) and then
# the session dies on a network outage. We want: quick retries first, then
# keep retrying every 5 minutes indefinitely so a wifi drop (5 min commute,
# laptop sleeping through a dead connection) pauses the session instead of
# killing it.
#
# This patch caps the backoff at 5 minutes (300_000 ms). Combined with
# `retry.maxRetries: 10000` in pi-bootstrap/pi-config/settings.json (≈34 days
# of 5-min intervals = effectively infinite), a session survives any network
# outage and resumes automatically when connectivity returns. The user can
# still abort a retry at any time (Esc / abort_retry).
#
# Two files are patched:
#   1. dist/core/agent-session.js  — agent-turn retry (the visible
#      "Retry N/M" path that stops the session after 3 attempts).
#   2. node_modules/@earendil-works/pi-ai/dist/utils/retry.js — the
#      compaction / branch-summary retry path (same no-cap backoff).
#
# Idempotency: a second run no-ops (marker comment + capped line present).
# Cap-awareness: PI_MAX_RETRY_DELAY_MS changes re-apply the patch with the
# new cap (the capped code line is part of the already-patched check).
# Safety: if a target file exists but the expected code is NOT found (a pi
# upgrade changed the shape), the script FAILS LOUDLY instead of silently
# mis-patching. Re-run after `pi update` (sync.sh → setup.sh → this).
#
# Upstream gap tracked in docs/upstream-pi-bugs.md: pi has no configurable
# agent-level max retry delay — request `retry.maxDelayMs` upstream.
#
# Usage:
#   patch-pi-retry.sh               patch + verify (idempotent)
#   patch-pi-retry.sh --check       verify-only; exit 1 if unpatched
#   patch-pi-retry.sh --paths       print the resolved pi package paths
#
# Env overrides:
#   PI_NODE_ROOT    pi-node install root (default: $HOME/.local/share/pi-node)
#   PI_MAX_RETRY_DELAY_MS   cap in ms (default 300000 = 5 min)
#
# Exit codes: 0 = patched/verified, 1 = failure (loud), 2 = usage error.
set -uo pipefail

INFRA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CAP_MS="${PI_MAX_RETRY_DELAY_MS:-300000}"
MARKER="agent-infra offline-resume patch"

# #254 drift-watch precondition (Task 10): pi version change without a
# successful oracle re-probe is a LOUD FAILURE. The frontmatter validator's
# committed fixture records (frontmatter-fixtures.mjs PI_VERSION_PIN) are
# pinned to the installed pi version — a pi bump invalidates them until the
# probe re-derives them (scripts/probe-frontmatter-fixtures.mjs --write) and
# the oracle re-verifies (scripts/check-skill-lint.oracle.test.mjs).
check_oracle_reprobe_precondition() {
  [ -f "$INFRA_ROOT/scripts/frontmatter-fixtures.mjs" ] || return 0
  command -v node >/dev/null 2>&1 || return 0
  [ -n "${PI_PKG:-}" ] && [ -f "$PI_PKG/dist/bundle/index.js" ] || return 0
  local pin live last_run age
  pin="$(node -e "import('$INFRA_ROOT/scripts/frontmatter-fixtures.mjs').then(m=>console.log(m.PI_VERSION_PIN))" 2>/dev/null || true)"
  [ -n "$pin" ] || return 0
  live="$(node -e "import('$PI_PKG/dist/bundle/index.js').then(m=>console.log(m.VERSION))" 2>/dev/null || true)"
  [ -n "$live" ] && [ "$pin" != "$live" ] || return 0
  last_run="$(cat "$INFRA_ROOT/.last-oracle-run" 2>/dev/null || echo 0)"
  age=$(( ($(date +%s) - last_run) / 86400 ))
  if [ "$age" -gt 1 ]; then
    echo "❌ pi version $live != validator pin $pin and the oracle has NOT re-probed recently (${age}d) —" >&2
    echo "   run: node scripts/probe-frontmatter-fixtures.mjs --write (re-derive fixture records)" >&2
    echo "   then: node scripts/check-skill-lint.oracle.test.mjs (verify) before touching pi (#254)" >&2
    return 1
  fi
  echo "⚠️  pi version $live != pin $pin but the oracle re-probed recently — fixture records are current, proceeding" >&2
  return 0
}

# The cap is interpolated into the applied patch — validate it is a plain
# number BEFORE use so a bad env value can never corrupt the patched dist.
case "$CAP_MS" in
  ''|*[!0-9]*)
    echo "❌ PI_MAX_RETRY_DELAY_MS must be a plain integer (got '$CAP_MS') — refusing to patch." >&2
    exit 1 ;;
esac

# ── discover the installed pi package (node-versioned global install) ────
# Prefer the ACTIVE binary: resolve `pi` to its real file (symlink-safe),
# walk up looking for the package. Falls back to globbing node roots and
# npm's global root. Lexical glob order could pick a STALE node root if pi
# ever leaves multiple node-v* installs around, so the binary walk wins.
find_pi_pkg() {
  if command -v pi >/dev/null 2>&1; then
    local bin real cur
    bin="$(command -v pi)"
    real="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$bin" 2>/dev/null || echo "$bin")"
    cur="$(dirname "$real")"
    while [ "$cur" != "/" ]; do
      if [ -f "$cur/dist/core/agent-session.js" ] && [[ "$cur" == *@earendil-works* ]]; then
        echo "$cur"; return 0
      fi
      cur="$(dirname "$cur")"
    done
  fi
  local node_root="${PI_NODE_ROOT:-$HOME/.local/share/pi-node}"
  local glob
  for glob in "$node_root"/node-v*/lib/node_modules/@earendil-works/pi-coding-agent \
              "$node_root"/node*/lib/node_modules/@earendil-works/pi-coding-agent \
              "$(npm root -g 2>/dev/null)"/@earendil-works/pi-coding-agent; do
    [ -f "$glob/dist/core/agent-session.js" ] && { echo "$glob"; return 0; }
  done
  return 1
}

PI_PKG="$(find_pi_pkg || true)"
PI_AI="${PI_PKG:+$PI_PKG/node_modules/@earendil-works/pi-ai}"

# #254 drift-watch precondition — pi version drift without a recent oracle
# re-probe blocks the patch path (never silently patch against stale pins).
if [ "${1:-}" != "--check" ] && [ "${1:-}" != "--paths" ]; then
  check_oracle_reprobe_precondition || exit 1
fi

# The capped code line for THIS cap — the already-patched and verification
# checks are cap-aware single-line greps (a multi-line grep pattern would
# depend on how the replacement rendered newlines and could false-verify a
# line swallowed into a comment).
PATCHED_LINE1="        const delayMs = Math.min(settings.baseDelayMs * 2 ** (this._retryAttempt - 1), ${CAP_MS});"
PATCHED_LINE2="        const delayMs = Math.min(policy.baseDelayMs * 2 ** (attempt - 1), ${CAP_MS});"

# ── patch a single file (idempotent, cap-aware) ─────────────────────────
# $1 = file, $2 = exact uncapped line (first-time shape), $3 = replacement
# (multi-line, REAL newlines via ANSI-C quoting), $4 = new capped line for
# THIS cap (verification + already-patched check)
#
# Replacement is done with python3 (already a dependency of find_pi_pkg):
# first-time apply = exact-line swap; already-patched-with-different-cap =
# swap the cap digits in place (regex). The regex-based approach sidesteps
# awk's BSD-vs-mawk newline/ERE divergence a shell-only version would hit.
patch_file() {
  local file="$1" old="$2" new="$3" patched_line="$4"
  if grep -qF "$MARKER" "$file" && grep -qF "$patched_line" "$file"; then
    echo "    already patched (cap ${CAP_MS}ms): $file"
    return 0
  fi
  grep -qF "$MARKER" "$file" && echo "    re-patching (cap changed to ${CAP_MS}ms): $file"
  local tmp
  tmp="$(mktemp "$(dirname "$file")/.retry-patch.XXXXXX")"
  python3 - "$file" "$old" "$new" "$CAP_MS" "$tmp" << 'PY'
import re, sys
path, old, new, newcap, out = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
src = open(path, encoding="utf-8").read()
if old in src:
    # first-time (or a pi upgrade restored the uncapped shape)
    src = src.replace(old, new, 1)
else:
    # already patched with a DIFFERENT cap — swap the cap digits in place.
    # group 1 = the prefix through ", ", group 2 = the old digits, group 3 =
    # ");" — only the digits change; marker comment lines never match.
    pat = re.compile(
        r"(const delayMs = Math\.min\((?:settings\.baseDelayMs \* 2 \*\* \(this\._retryAttempt - 1\), "
        r"|policy\.baseDelayMs \* 2 \*\* \(attempt - 1\), ))(\d+)(\);)"
    )
    if not pat.search(src):
        sys.exit(2)
    src = pat.sub(lambda m: m.group(1) + newcap + m.group(3), src)
open(out, "w", encoding="utf-8").write(src)
PY
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    rm -f "$tmp"
    if [ "$rc" -eq 2 ]; then
      echo "❌ patch target not found in $file — a pi upgrade likely changed this code." >&2
      echo "   Re-run after verifying the new shape; update this script (scripts/patch-pi-retry.sh)." >&2
    fi
    return 1
  fi
  mv "$tmp" "$file"
  if ! grep -qF "$patched_line" "$file"; then
    echo "❌ patch did not take effect in $file" >&2
    return 1
  fi
  echo "    patched: $file (backoff capped at ${CAP_MS}ms)"
  return 0
}

usage() { sed -n '2,58p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

if [ "${1:-}" = "--paths" ]; then
  [ -n "$PI_PKG" ] || { echo "pi package not found" >&2; exit 1; }
  echo "$PI_PKG"
  echo "$PI_AI/dist/utils/retry.js"
  exit 0
fi

if [ -z "$PI_PKG" ]; then
  echo "⚠️  pi package not found — retry patch skipped (looked in \$HOME/.local/share/pi-node and \$(npm root -g))." >&2
  exit 1
fi

# Replacement text built with REAL newlines (ANSI-C quoting) — never rely on
# awk's own \n processing, which differs between BSD awk and mawk.
OLD1="        const delayMs = settings.baseDelayMs * 2 ** (this._retryAttempt - 1);"
NEW1="$(printf '        // agent-infra offline-resume patch: cap the exponential backoff so retries continue every %sms\n        // indefinitely instead of growing unboundedly.\n        const delayMs = Math.min(settings.baseDelayMs * 2 ** (this._retryAttempt - 1), %s);' "$CAP_MS" "$CAP_MS")"
OLD2="        const delayMs = policy.baseDelayMs * 2 ** (attempt - 1);"
NEW2="$(printf '        // agent-infra offline-resume patch: cap the exponential backoff so summarization/compaction\n        // retries continue every %sms instead of growing unboundedly.\n        const delayMs = Math.min(policy.baseDelayMs * 2 ** (attempt - 1), %s);' "$CAP_MS" "$CAP_MS")"

if [ "${1:-}" = "--check" ]; then
  local_ok=1
  grep -qF "$PATCHED_LINE1" "$PI_PKG/dist/core/agent-session.js" || local_ok=0
  grep -qF "$PATCHED_LINE2" "$PI_AI/dist/utils/retry.js" || local_ok=0
  [ "$local_ok" = "1" ] && { echo "✅ retry patch applied and verified (cap ${CAP_MS}ms)"; exit 0; }
  echo "❌ retry patch NOT applied (run scripts/patch-pi-retry.sh)" >&2
  exit 1
fi

echo "==> applying offline-resume retry patch to pi ($PI_PKG)"
fail=0
patch_file "$PI_PKG/dist/core/agent-session.js" "$OLD1" "$NEW1" "$PATCHED_LINE1" || fail=1
[ -f "$PI_AI/dist/utils/retry.js" ] || { echo "❌ pi-ai not found at $PI_AI" >&2; fail=1; }
patch_file "$PI_AI/dist/utils/retry.js" "$OLD2" "$NEW2" "$PATCHED_LINE2" || fail=1

if [ "$fail" = "1" ]; then
  echo "❌ retry patch FAILED — sessions will still stop after 3 quick retries on network loss." >&2
  exit 1
fi
echo "✅ retry patch applied — sessions now retry every ${CAP_MS}ms after the initial quick retries."
