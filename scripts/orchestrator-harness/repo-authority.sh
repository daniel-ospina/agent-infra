#!/usr/bin/env bash
# repo-authority.sh — the per-repo merge contract (agent-infra#1764).
#
# WHY THIS FILE EXISTS. orch-loop.sh carried tortoise's branch-protection contexts as a literal,
# and merge-one.sh asked every repo for tortoise's review gate. Pointed at a second repo both
# produced a CONFIDENT WRONG verdict: agent-infra PR #1763 had 21 passing checks and ZERO
# `ai-review-gate` runs, and the loop nonetheless logged `#1763 FAILED:ai-review-gate` — so no PR
# could read GREEN, the merge queue could not drain, and the controller logged
# `[dispatch] skipped (merge-priority …)` indefinitely. The required-check list and the review
# authority are REPO-DEPENDENT INPUTS carried as constants — the same class the #1736/#1748
# venv fix addressed, and the widened root this issue names.
#
# ONE HOME for the two inputs, SOURCED by BOTH orch-loop.sh and merge-one.sh so the two cannot
# drift:
#   required_checks          -> the repo's own branch-protection contexts
#   resolve_required_checks  -> that set, honouring the REQ operator override, else FALLBACK_REQ
#                               (ONE resolver: an earlier duplicate pair is what let a round-5 fix
#                                land in one copy and not the other — review round 6, P2)
#   merge_authority          -> gate (the review-gate check is the authority) | rail (the repo's
#                               own merge rail is the authority)
#
# ⛔ FAIL-CLOSED, THREE WAYS.
#   1. An unreadable protection endpoint NEVER becomes an EMPTY required set. An empty `want`
#      reads as NOCHECKS (nothing merges) and is indistinguishable from a permission-shaped
#      partial response, so `resolve_required_checks` substitutes FALLBACK_REQ — deliberately
#      NON-EMPTY names, and foreign to a repo that is not tortoise. ⚠️ On such a repo the
#      fallback's gate name reads FAILED (not PENDING — review P2, round 1), so an unresolved
#      contract stops ALL action: the CONTROLLER's sweep merges/auto-arms/spawns nothing while
#      protection is unreadable (orch-loop.sh, AUTHORITY_UNKNOWN), and merge-one.sh REFUSES on
#      its own fallback read (exit 5) — which covers every ingress, including chain-merge.sh and
#      fix-one.sh, which invoke it directly. A fallback left to drive the FAILED arm would
#      otherwise spawn a fresh-context reviewer per PR per cycle for as
#      long as the read fails. That is the fail-closed direction, and it is why the fallback is a
#      real list rather than the empty string.
#   2. The review gate is a REQUIRED name like any other: `merge_authority` reads it from the
#      resolved set, never from a per-PR observation, so "absent on THIS PR" can never demote it —
#      only "this repo does not require it" can.
#   3. A rail-managed repo whose rail is missing REFUSES; it never degrades to `gh pr merge`.
set -u

# The review-gate check NAME is itself repo-dependent (tortoise: `ai-review-gate`).
# REVIEW_GATE_DEFAULT is the name the DETECTOR compares against: a `REVIEW_GATE` that is merely
# echoed back can never disagree with itself (review round 6, P1 — the round-5 detector was
# arithmetically inert), so the question "did the override change the authority?" is answered with
# the DEFAULT gate name, which is what the repo's declaration would give with no override at all.
# Record whether it came from the environment: such an override moves the merge authority — and the
# classifier's gate_ok — onto a different name. That is sometimes intended (a repo whose gate has
# another name), but it must never be SILENT: it is read from the environment, and a cloud cell
# sources keys.env with `set -a`, so a stray export reaches here.
REVIEW_GATE_DEFAULT="ai-review-gate"
REVIEW_GATE_SOURCE="default"
if [ -n "${REVIEW_GATE:-}" ] && [ "$REVIEW_GATE" != "$REVIEW_GATE_DEFAULT" ]; then REVIEW_GATE_SOURCE="env"; fi
REVIEW_GATE="${REVIEW_GATE:-$REVIEW_GATE_DEFAULT}"

# LAST-RESORT ONLY, and the one place the pre-#1764 constant still lives — as the documented
# fallback for a repo whose protection cannot be read (see the header). It is NOT a default, and
# it never overrides a successful read or an explicit REQ.
FALLBACK_REQ="ai-review-gate python-ci-gate docs test-isolation license-surface legal-e2e pricing-artifact"

# _unrepresentable <owner/repo> <newline-delimited names> — rc 1 (loud) if any NAME carries
# whitespace or a comma.
# ⚠️ GitHub allows both in a context name (`ci / lint`, `a,b`), but neither can travel this
# contract: the set is SPACE-joined (the classifier splits on whitespace) and the RED set the
# controller derives is COMMA-joined (the FAILED arm splits on commas), so such a name silently
# becomes two names — the PR sits PENDING forever or misroutes to the wrong arm, with nothing
# logged (review rounds 3-4). The test is PER NAME, on the raw newline-delimited lines.
# Supporting such names end-to-end (bash splits, the python split, case matching) is a redesign;
# REFUSING loudly is the fail-closed answer: this counts as a FAILED read, so the fallback
# applies and the sweep — and every merge worker — refuses to act on a contract it cannot
# represent.
_unrepresentable() {
  grep -Eq '[[:space:],]' <<<"${2:-}" || return 0
  printf 'repo-authority: %s: a required context name contains whitespace or a comma [%s] — the space-joined contract (and the comma-joined RED list) cannot represent it; treating the read as FAILED (fail-closed)\n' "${1:-}" "$(grep -E '[[:space:],]' <<<"${2:-}" | tr '\n' ' ')" >&2
  return 1
}

# _normalise_set <string> — collapse every whitespace RUN to one space and trim both ends, so the
# bash matchers (which delimit a name on a literal SPACE) and the classifier's `str.split()` can
# never disagree about the SAME string. A whitespace-only value normalises to EMPTY, which every
# caller here reads as "absent" — never as a non-empty contract.
# ⛔ review round 8, classes B2/B3. `_override_usable` screened only a comma, so a tab-separated
# override made `merge_authority` answer `rail` while the classifier enforced the gate: on a gate
# repo `merge-one.sh` then took its RAIL branch, skipping the fresh-context reviewer and the signed
# record — a §5.1 bypass — and a whitespace-only override routed to `rail` instead of refusing.
# ⛔⛔ THE DEFINITION MUST BE SHARED, NOT COPIED (round-9 review, P2). The first fix ENUMERATED the
# bytes to fold (`tr '\n\t\r\v\f'`), and an enumeration cannot be right: the classifier splits on
# Python's `str.isspace()`, a SUPERSET of POSIX `[:space:]`. Measured at 10c56ed5, a set joined by
# \x1c, \x1d or NBSP still made the classifier report GATE-ENFORCED while `merge_authority`
# answered `rail` — the identical bypass, still open. python3 is ALREADY the classifier's own
# dependency, so this normalises with the classifier's own rule and the two readers now agree BY
# CONSTRUCTION. rc 1 = the normaliser is unavailable; every caller must then treat the contract as
# ABSENT (fail-closed) rather than let an un-normalised value reach both readers differently.
_normalise_set() {
  local py
  py="$(command -v python3 2>/dev/null || true)"
  [ -n "$py" ] || return 1
  printf '%s' "${1:-}" | "$py" -c '
import sys
# ⛔ DECODE EXACTLY AS THE CLASSIFIER DOES (round-10 review, P2). The classifier reads
# os.environ["REQ"], which Python decodes with the FILESYSTEM encoding — NOT utf-8. Hard-coding
# utf-8 made the two definitions differ on a host whose filesystem encoding is single-byte:
# measured under a localedef ISO-8859-1 locale, a lone 0xA0 decoded to NBSP for the classifier
# (whitespace, so it SPLIT and enforced the gate) and to a surrogate here (not whitespace, so it
# did not, and merge_authority answered `rail`) — the same §5.1 bypass, one environment away.
enc = sys.getfilesystemencoding() or "utf-8"
err = sys.getfilesystemencodeerrors() or "surrogateescape"
d = sys.stdin.buffer.read().decode(enc, err)
sys.stdout.buffer.write(" ".join(d.split()).encode(enc, err))
' 2>/dev/null || return 1
}

# _override_usable <owner/repo> <space-joined REQ_OVERRIDE> — rc 1 (loud) if the override carries
# a comma (review round 5). The override is itself SPACE-separated, so a name containing a space
# is indistinguishable from two names there and cannot be screened; the comma IS detectable and is
# the destructive one, because it splits the comma-joined RED list — a red required check then
# reaches no worker at all. An unusable override is discarded by the resolvers, which fall through
# to the repo's own declaration (and, if that read also fails, to the refusal).
_override_usable() {
  grep -q ',' <<<"${2:-}" || return 0
  printf 'repo-authority: %s: the REQ override [%s] contains a comma — the comma-joined RED list cannot represent it, so the override is IGNORED (fail-closed: the repo declaration is used instead, or every caller refuses)\n' "${1:-}" "${2:-}" >&2
  return 1
}

# required_checks <owner/repo> [<gh-binary>]
# Print the repo's required status-check contexts, space-separated, once each.
#   rc 0 -> READ from branch protection (the printed set is NON-EMPTY)
#   rc 1 -> could NOT be read (network / permission / shape); nothing is printed
# A zero-name read is a FAILED read, never "this repo requires nothing".
required_checks() {
  local or="${1:-}" gh="${2:-gh}" raw joined
  [ -n "$or" ] || return 1
  raw="$("$gh" api "repos/$or/branches/main/protection/required_status_checks" --jq '.contexts[]' 2>/dev/null)" || return 1
  # De-duplicate and join on one line: the classifier splits on whitespace, and a newline would
  # otherwise reach it as part of the value rather than as a separator.
  _unrepresentable "$or" "$raw" || return 1
  joined="$(printf '%s\n' "$raw" | awk 'NF && !seen[$0]++' | tr '\n' ' ')"
  joined="${joined% }"
  [ -n "$joined" ] || return 1
  printf '%s\n' "$joined"
}

# `resolve_required_checks` <owner/repo> [<gh-binary>]
# Sets REQ and REQ_SOURCE in the CALLER'S shell — the one production callers use.
# ⛔ A CALLER CANNOT DO THIS ITSELF: `REQ="$(resolve_required_checks …)"` runs the resolver in
# a command-substitution SUBSHELL, so REQ_SOURCE cannot survive the assignment (measured live:
# REQ=[pipeline-compliance] REQ_SOURCE=[<EMPTY>]) and the operational fallback warning can never
# fire. This wrapper performs the same three-way resolution in the current shell, where both
# globals land.
# ⛔ ONE RESOLVER, DELIBERATELY (review round 6). An `effective_required_checks` twin existed and
# had no production caller; a fix landed in `resolve_required_checks` only, and a mutant of the
# twin stayed green across every suite. Two copies of one policy is how that happens.
resolve_required_checks() {
  local _ov
  if [ -n "${REQ_OVERRIDE:-}" ]; then
    if ! _ov="$(_normalise_set "${REQ_OVERRIDE:-}")"; then
      # The normaliser itself is unavailable (no python3). Discard the override rather than let an
      # un-normalised value reach the classifier and the matcher unalike — fail-closed.
      printf 'repo-authority: %s: the REQ override CANNOT be normalised (python3 is required) — the override is IGNORED (fail-closed: the repo declaration is used instead)\n' "${1:-}" >&2
    elif [ -z "$_ov" ]; then
      # ⛔ A whitespace-only override is NOT an override: `' '.split()` is `[]` for the classifier,
      # so a non-empty-but-NAMELESS contract would ROUTE (`rail`) instead of refusing — the round-8
      # B3 bypass. Discard it and fall through to the repo's own declaration (fail-closed).
      printf 'repo-authority: %s: the REQ override is whitespace-only — it carries no names, so it is treated as ABSENT (fail-closed: the repo declaration is used instead)\n' "${1:-}" >&2
    elif _override_usable "$1" "$_ov"; then REQ="$_ov"; REQ_SOURCE=env; return 0
    fi
    REQ_OVERRIDE=""  # malformed or nameless: discard (loudly) and use the repo's own declaration
  fi
  if REQ="$(required_checks "$1" "${2:-gh}")"; then REQ_SOURCE=protection; return 0; fi
  REQ="$FALLBACK_REQ"; REQ_SOURCE=fallback; return 0
}

# merge_authority <required-check-string> -> `gate` | `rail` | `unknown`
# ⚠️ An EMPTY set is `unknown` (review round 3): a stale or partial repo-authority.sh used to
# yield REQ="" here, which read as `rail` and silently rerouted a gate repo onto the rail —
# an empty contract must refuse, never route.
# A repo that REQUIRES the review gate uses that check as the merge authority, and a plain
# squash merge lands. A repo that does NOT must use its own merge rail: `gh pr merge` there
# would land the PR on the required checks alone, with no head-bound evidence — the bypass
# agent-infra's own AGENTS.md forbids ("merge via `scripts/admin-merge.sh <PR>`, never raw
# `gh pr merge`").
merge_authority() {
  # ⛔ NORMALISE FIRST (review round 8, B3). A whitespace-bearing set makes the classifier
  # (`str.split()`, which splits on ANY whitespace) and this whole-name test (which delimited on a
  # literal space) disagree about the same string — `rail` here, gate enforced there. And a
  # whitespace-only set is `[]` to the classifier while a bare `-z` test called it non-empty and
  # routed it to `rail`; both are "an empty contract must refuse, never route".
  local _set
  if ! _set="$(_normalise_set "${1:-}")"; then
    printf 'repo-authority: the required-check set CANNOT be normalised (python3 is required) — refusing (fail-closed)\n' >&2
    printf 'unknown\n'; return 0
  fi
  if [ -z "$_set" ]; then printf 'unknown\n'; return 0; fi
  # ⛔ round-12 review, P2. The classifier tests the gate name as ONE WHOLE TOKEN (`rgate in
  # want`), while the `case` below matches it as a SUBSTRING SPAN of the space-joined set. Those
  # agree for every single-token name and DIVERGE for a name containing whitespace: with
  # REVIEW_GATE='docs license-surface' and the set 'pipeline-compliance docs license-surface', the
  # span MATCHED (authority=gate, so the GREEN arm issued a RAW `gh pr merge`) while the classifier
  # never enforced the gate (no such TOKEN existed) — an UNREVIEWED change merges. Measured at
  # ed5ba51e. A whitespace-bearing name is not representable as one token in this space-joined
  # model, so it REFUSES rather than answering `gate`; reachable from an ambient / keys.env
  # REVIEW_GATE, which the harness otherwise does not screen.
  case "${REVIEW_GATE:-}" in
    *[[:space:]]*)
      printf 'repo-authority: REVIEW_GATE=[%s] contains whitespace — REQ is space-joined, so a name with an internal space can never be matched as ONE token by the classifier; the merge authority is UNKNOWN and nothing merges (fail-closed)\n' "${REVIEW_GATE:-}" >&2
      printf 'unknown\n'; return 0 ;;
  esac
  case " $_set " in
    *" $REVIEW_GATE "*) printf 'gate\n' ;;
    *)                  printf 'rail\n' ;;
  esac
}

# ══════════════════════════════════════════════════════════════════════════════════════════════════
# THE LANDING READ (agent-infra#2320) — "does this box's gh chain reach a REAL binary, and is the
# merge contract readable HERE?"
#
# WHY (measured 2026-10-22, the owner's Mac). The wrapper chain
# `gh-limit -> gh-rest -> .pi/agent/shims/gh` resolved to ITSELF, gh-limit refused at depth 2 —
#   "refusing a third gh-shim hop (HARNESS_GH_SHIM_DEPTH=2) — the shims are resolving to each other
#    and no real gh is reachable"
# — and EVERY gh call returned EMPTY. `required_checks` above reads an empty/rc-1 answer as
# unreadable, so `resolve_required_checks` fell back, and `merge-one.sh` refused every merge with
# exit 5 ("the merge contract is UNKNOWN — branch protection was UNREADABLE"). The fleet could not
# land anything through its own chain for hours and NOTHING named the cause: the reported cause
# pointed at permissions, not at the wrapper. `AGENT_GH_REAL=<the box's real gh>` fixed it instantly.
# (`/opt/homebrew/bin/gh` — first on the harness PATH there — did not exist at all.)
#
# So the question is asked ONCE, in the module that already owns the merge contract, and answered on
# the ONE surface an operator or agent reads: `bin/harness status`.
#
# ⛔ THE RESOLUTION MIRRORS `find_real_gh` IN `scripts/gh-shim/gh` — the layer that actually decides —
# so this read gives the answer the chain gives, not a second opinion in parallel: honour
# `AGENT_GH_REAL` when it names a usable file; otherwise walk PATH in order, skipping `""`/`.`
# (a `gh` in the CWD is not a resolution — it is a hijack), anything that is not an executable
# REGULAR FILE (`-x` is TRUE for a directory, and exec-ing one is rc 126 on every call), any harness
# layer by its OWN sentinel line (`harness-gh-shim-marker`, read in the first 8 KiB — the same window
# every resolver reads, so identity does not vanish with a missing sibling), and any candidate that
# is the SAME FILE (`-ef`: device+inode THROUGH symlinks — a link, a link chain and a hardlink alike)
# as one already judged. A symlink farm puts one file on PATH many times; probing each incarnation
# again is the recursion this read exists to detect.
#
# ⛔ AND IT IS VERIFIED, NEVER GUESSED. A walk can only say "this is not one of the layers I know";
# it cannot say "this is a gh". The AGENT shim deliberately carries no sentinel — it must keep
# delegating mutations through #984's argv guard — so a static test alone would resolve the shim as
# "the real gh" on exactly the box this read exists for. One BOUNDED `--version` probe settles it: a
# real gh prints `gh version …`; a chain that cannot land exits with its own words, which are
# quoted back VERBATIM (that is how the measured depth-guard message reaches the operator).
# ⛔ A `gh`-shaped SCRIPT that answers as a gh is still a PASS for the BOX: the chain reaches a real
# binary, so the box can land. What may never be EXPORTED as `AGENT_GH_REAL` is a script — see
# `ensure_agent_gh_real`.
# ⛔ AND NO $O-SIDE DEPENDENCY. This block sources nothing (`scripts/lib/bounded.sh` is not shipped
# into a deployed `$O`), so the bound is `timeout`/`gtimeout` when the host has one and a BASH-NATIVE
# WATCHDOG otherwise — the residual this used to state (`a direct run`) is gone because it was the
# wrong residual: macOS, the platform the incident was measured on, ships NEITHER binary, so the one
# call the whole read exists to bound was unbounded exactly there (fresh review P2).
#
# ONE READER, TWO CONSUMERS. `bin/harness status` renders both answers; `ensure_agent_gh_real` uses
# the same resolution to pin the box. There is deliberately no third copy of "which gh is real".

# _gh_is_text_script <path> — is this a `#!`-led TEXT script?
# ⛔ THE GATE IS LOAD-BEARING, NOT TIDINESS. Reading the first KiBs of a real gh (a 20 MB Mach-O/ELF
# binary) into a shell VARIABLE makes bash print `warning: command substitution: ignored null byte in
# input` on the CALLER's stderr — and call sites in this tree capture `2>&1` and parse the merged
# bytes, so a healthy box would be read as a broken one by its own health check (#2184's class).
# Every layer this fleet interposes IS a `#!/usr/bin/env bash` script, so the gate costs nothing real.
_gh_is_text_script() {
  local _hdr
  [ -f "${1:-}" ] || return 1
  _hdr="$(head -c 2 "$1" 2>/dev/null)"
  [ "$_hdr" = '#!' ]
}

# _gh_is_harness_layer <path> — is this file a harness interposer (`gh-rest`/`gh-limit`)?
# One rule for both directions, and it is the file's OWN content, never a sibling's existence: a
# half-installed box is exactly where "`../gh-limit.py` exists" answers wrongly.
_gh_is_harness_layer() {
  _gh_is_text_script "${1:-}" || return 1
  case "$(head -c 8192 "$1" 2>/dev/null)" in *harness-gh-shim-marker*) return 0 ;; esac
  return 1
}

# _gh_is_agent_shim <path> — is this file the argv-level admin-merge guard (`scripts/gh-shim/gh`)?
# It carries NO sentinel (deliberately: keeping it marker-free is what lets the harness layers keep
# delegating mutations THROUGH it), so identity is its own two defining references. The `#!` gate is
# load-bearing: on a real gh (a Mach-O/ELF binary) the 64 KiB body would be read into a variable full
# of NUL bytes, and bash prints a null-byte warning on the CALLER's stderr — which several call sites
# in this tree parse as data (#2184's class).
_gh_is_agent_shim() {
  local f="${1:-}" _body
  _gh_is_text_script "$f" || return 1
  _body="$(head -c 65536 "$f" 2>/dev/null)" || return 1
  case "$_body" in *find_real_gh*) ;; *) return 1 ;; esac
  case "$_body" in *AGENT_GH_REAL*) return 0 ;; esac
  return 1
}

# _gh_is_binary <path> — is this file a COMPILED binary (ELF / Mach-O / PE)?
# ⛔ THIS IS THE TEST THE PIN NEEDS, AND `head -c 2 … != '#!'` IS NOT IT (fresh review P1). A script
# without a shebang is a legal wrapper (the shell falls back to running it as sh) and starts with
# something else, so a two-byte test pinned a WRAPPER — the #2266 recursion — while this module's own
# comment said a script is never exported. The test is POSITIVE: a real `gh` is a compiled binary on
# every platform this fleet runs (a Go build: ELF, Mach-O or PE), so magic bytes decide it and an
# unrecognised file is simply not pinned. `od` is POSIX and yields TEXT, so no NUL byte ever reaches a
# shell variable (a NUL there would print a warning on the caller's stderr, #2184's class).
_gh_is_binary() {
  local m
  [ -f "${1:-}" ] || return 1
  m="$(od -A n -t x1 -N 4 "$1" 2>/dev/null | tr -d ' \n')"
  case "$m" in
    7f454c46) return 0 ;;   # ELF     (\x7fELF) — Linux
    4d5a*)    return 0 ;;   # PE/COFF (MZ)     — Windows
    cffaedfe|feedface|cefaedfe|feedfacf|cafebabe|bebafeca) return 0 ;;  # Mach-O / fat — macOS
  esac
  return 1
}

# _gh_bounded <secs> <cmd…> — `timeout` -> `gtimeout` -> a bash-native watchdog.
# ⛔ THE THIRD ARM IS THE macOS CASE, NOT A COURTESY (fresh review P2). `timeout` is GNU coreutils and
# macOS ships it nowhere (`gtimeout` only with Homebrew coreutils), so on the platform this incident
# was measured on neither of the first two arms can fire: one blocking candidate would hold
# `bin/harness status`, `merge-one.sh` and `orch-loop.sh` with NO wall clock at all. The watchdog
# gives the same contract `timeout` gives — kill the child at <secs>, report 124.
# ⛔ THE WATCHDOG'S OWN OUTPUT IS REDIRECTED, AND THAT IS LOAD-BEARING. A `$( … )` caller reads until
# every holder of the pipe's write end closes it, so a bare `( sleep; kill ) &` would keep the command
# substitution open for the whole sleep AFTER the child died — turning a bound into a `sleep <secs>`
# floor on every healthy probe. `>/dev/null 2>&1` closes that end inside the watchdog.
_gh_bounded() {
  local s="${1:-}"; shift 2>/dev/null || true
  [ "$#" -gt 0 ] || return 2
  case "$s" in ''|*[!0-9]*) s=20 ;; esac
  if command -v timeout >/dev/null 2>&1; then timeout "$s" "$@"; return $?; fi
  if command -v gtimeout >/dev/null 2>&1; then gtimeout "$s" "$@"; return $?; fi
  # No `sleep` means no watchdog: run direct rather than fake a timeout on every healthy probe
  # (a missing `sleep` is a broken fixture, and a false 124 would read as a false CANNOT-REACH).
  command -v sleep >/dev/null 2>&1 || { "$@"; return $?; }
  local _p _w _rc
  "$@" & _p=$!
  { sleep "$s"; kill -9 "$_p"; } >/dev/null 2>&1 & _w=$!
  # ⛔ `2>/dev/null` ON THE `wait` IS NOT TIDINESS EITHER. Bash reports a signal-killed job on its
  # OWN stderr at reap time (`<file>: line N: PID Killed  "$@"`), and every probe caller captures
  # `2>&1` to keep the chain's words — so an unredirected notice would be parsed as the candidate's
  # output. The redirect silences the SHELL's notice only; the child's own stderr was inherited at
  # spawn and is untouched.
  wait "$_p" 2>/dev/null; _rc=$?
  if kill -0 "$_w" 2>/dev/null; then kill "$_w" 2>/dev/null; else _rc=124; fi
  return "$_rc"
}

# _gh_first_line <text> — the first line, collapsed to ONE line for the single-line contract below.
_gh_first_line() {
  printf '%s' "${1:-}" | sed -n '1p' | tr '\n\t\r' '   '
}

# gh_probe_real <path> [<clear-seam:0|1>] — does this file (or the chain that starts here) answer as
# a REAL gh?
#   rc 0 REAL      prints the `gh version` line
#   rc 1 REFUSED   prints the chain's own refusal (e.g. the depth-guard message)
#   rc 2 UNKNOWN   prints why (timed out / a different failure / a `gh` that is not gh)
# ⛔ A FRESH HOP BUDGET. An inherited `HARNESS_GH_SHIM_DEPTH` makes a HEALTHY chain refuse at the
# guard, so the box would read broken because its parent happened to be mid-chain.
# ⛔ <clear-seam>=1 drops the inherited pins for THIS probe only. That is what makes the PATH walk
# answer the sustainable question ("can the chain resolve ITSELF?") instead of "the operator once
# exported a pin that worked": with a bad pin inherited, every candidate would resolve through it and
# the walk would learn nothing.
gh_probe_real() {
  local p="${1:-}" clear="${2:-0}" out rc
  [ -n "$p" ] || { printf 'no candidate\n'; return 2; }
  # ⛔ THE PROBE MUST NOT HANG, AND ON macOS THERE IS NO `timeout`: `timeout` is GNU coreutils and
  # macOS ships it nowhere (`gtimeout` only with Homebrew coreutils), so `_gh_bounded` degrades to a
  # direct run there. A probe that lands on a gh layer therefore carries the layer's own knobs —
  # admission capped at 5 s instead of 300 s, and the gate's mutex at 1 s — so a HEALTH read cannot
  # sit in a fleet-wide queue for five minutes. A real `gh` ignores both (they are the shim's env).
  if [ "$clear" = "1" ]; then
    out="$( unset AGENT_GH_REAL GH_LIMIT_REAL_GH GH_REST_REAL_GH
            HARNESS_GH_SHIM_DEPTH=0; export HARNESS_GH_SHIM_DEPTH
            AGENT_GH_GATE_ACQUIRE_TIMEOUT=5 AGENT_GH_GATE_LOCK_TIMEOUT_MS=1000 \
            GH_LIMIT_NO_WAIT=1 AGENT_GH_GATE_NO_WAIT=1 \
            _gh_bounded 20 "$p" --version 2>&1 )"; rc=$?
  else
    out="$( HARNESS_GH_SHIM_DEPTH=0; export HARNESS_GH_SHIM_DEPTH
            AGENT_GH_GATE_ACQUIRE_TIMEOUT=5 AGENT_GH_GATE_LOCK_TIMEOUT_MS=1000 \
            GH_LIMIT_NO_WAIT=1 AGENT_GH_GATE_NO_WAIT=1 \
            _gh_bounded 20 "$p" --version 2>&1 )"; rc=$?
  fi
  case "$rc" in
    0)
      case "$out" in
        'gh version'*) _gh_first_line "$out"; return 0 ;;
        *) printf 'a `gh` that is not gh: %s\n' "$(_gh_first_line "${out:-<no output>}")"; return 2 ;;
      esac ;;
    124) printf 'timed out after 20s\n'; return 2 ;;
    127)
      # THE MEASURED CLASS: the chain refuses instead of running anything. Any other 127 is unknown,
      # not a refusal — the same discipline the wrappers apply to their own exit codes.
      case "$out" in
        *'gh-shim hop'*|*'real gh'*|*'cannot find the real gh'*|*'cannot locate the real gh'*)
          _gh_first_line "$out"; return 1 ;;
        *) printf 'rc 127: %s\n' "$(_gh_first_line "${out:-<no output>}")"; return 2 ;;
      esac ;;
    *) printf 'rc %s: %s\n' "$rc" "$(_gh_first_line "${out:-<no output>}")"; return 2 ;;
  esac
}

# gh_chain_read — THE read. One line on stdout, so a caller can parse it without a second format:
#   GH=OK source=<env|path> ver=<version line> path=<resolved>          rc 0
#   GH=CANNOT-REACH-REAL-GH msg=<why>                                  rc 1
#   GH=UNVERIFIABLE why=<token> msg=<detail>                           rc 2
# ⛔ `path=` IS LAST, AND THAT IS STRUCTURAL, NOT COSMETIC (fresh review P2). Every other field can
# then be parsed with `[^ ]*` and the path — the ONE value that may legally contain a SPACE
# (`/Volumes/My Passport/…` is ordinary on macOS, the platform this incident was measured on) — is
# taken as everything to end-of-line. With the old order a path with a space was silently truncated,
# so the operator's remedy line named a file that does not exist and `landing.ghPath` was wrong.
# ⛔ CANNOT-REACH IS NOT UNVERIFIABLE. The first is a POSITIVE finding — every gh on this box is a
# shim and a depth guard is what ends the call — and its consequence is stated by the caller ("a box
# without a real gh cannot land anything"). The second is "the probe could not answer", which is
# never a pass either.
gh_chain_read() {
  local _ifs_save p cand detail rc msg="" seen="" dup _s pmsg="" wmsg=""
  # ⛔ `$IFS` IS ASSIGNED UNCONDITIONALLY, NEVER VIA `${IFS:-}`. Bash always initialises IFS, so a
  # `:-` default can only ever fire when the caller DELETED it — and restoring `IFS=""` there would
  # silently disable word splitting for the REST of that caller's shell (every later `for x in $y`
  # would iterate once). `_ifs_save=$IFS` is the faithful save.
  # ⛔ EVERY LOOP VARIABLE IS `local` (#fresh review P2: `_s` was not). This module is SOURCED, so a
  # stray assignment lands in the caller's shell for the rest of a controller cycle.
  _ifs_save=$IFS
  # ── (1) THE SEAM, FIRST — it is what the agent shim itself honours and what the fleet pins per box.
  if [ -n "${AGENT_GH_REAL:-}" ]; then
    if [ -f "${AGENT_GH_REAL}" ] && [ -x "${AGENT_GH_REAL}" ] \
       && ! _gh_is_harness_layer "${AGENT_GH_REAL}" && ! _gh_is_agent_shim "${AGENT_GH_REAL}"; then
      if detail="$(gh_probe_real "${AGENT_GH_REAL}")"; then
        printf 'GH=OK source=env ver=%s path=%s\n' "$detail" "${AGENT_GH_REAL}" ; return 0
      fi
      pmsg="AGENT_GH_REAL=${AGENT_GH_REAL} does not answer as a gh ($detail)"
    elif [ ! -f "${AGENT_GH_REAL}" ] || [ ! -x "${AGENT_GH_REAL}" ]; then
      # ⛔ FOUR DIFFERENT FAILURES, FOUR DIFFERENT SENTENCES (#fresh review P2). The shared arm
      # called a MISSING file, a non-executable and a directory "a harness shim" — so the issue's own
      # measured path (`/opt/homebrew/bin/gh`, which does not exist on that Mac) was diagnosed as
      # shim-ness, sending the operator after a chain problem instead of a missing binary.
      pmsg="AGENT_GH_REAL=${AGENT_GH_REAL} is not an executable regular file"
    elif _gh_is_agent_shim "${AGENT_GH_REAL}"; then
      pmsg="AGENT_GH_REAL=${AGENT_GH_REAL} is the argv-level gh shim, not a real gh — refused, because a value that IS a shim re-enters the chain (#2266)"
    else
      pmsg="AGENT_GH_REAL=${AGENT_GH_REAL} is a harness gh layer, not a real gh — refused, because a value that IS a shim re-enters the chain (#2266)"
    fi
  fi
  # ── (2) THE PATH WALK — find_real_gh's rules, in its order.
  IFS=:
  for p in ${PATH:-/usr/bin:/bin}; do
    cand="$p/gh"
    IFS="$_ifs_save"
    case "$p" in ''|.) IFS=:; continue ;; esac
    if [ ! -f "$cand" ] || [ ! -x "$cand" ]; then IFS=:; continue; fi
    # `-ef` dedupe against everything already judged (a farm repeats ONE file under many names).
    dup=0
    for _s in $seen; do [ "$cand" -ef "$_s" ] 2>/dev/null && { dup=1; break; }; done
    seen="$seen $cand"
    IFS=:
    [ "$dup" -eq 1 ] && continue
    if _gh_is_harness_layer "$cand"; then
      [ -n "$wmsg" ] || wmsg="$cand is a harness gh layer (its own sentinel), not the real binary"
      continue
    fi
    if _gh_is_agent_shim "$cand"; then
      [ -n "$wmsg" ] || wmsg="$cand is the argv-level gh shim, not the real binary"
      continue
    fi
    detail="$(gh_probe_real "$cand" 1)"; rc=$?
    if [ "$rc" -eq 0 ]; then
      IFS="$_ifs_save"
      printf 'GH=OK source=path ver=%s path=%s\n' "$detail" "$cand"
      return 0
    fi
    # ⛔ rc 1 (REFUSED) IS TERMINAL — IT IS THE FINDING THIS READ EXISTS FOR (fresh review P1). Every
    # marked layer and the agent shim are already skipped STATICALLY above, so a candidate that had to
    # be PROBED and then refused IS this box's chain entry: the bare `gh` call would land on it and
    # die, no matter how healthy a later PATH entry is (a later entry is not reachable from a `gh` the
    # box does not shadow). Keeping the walk going let `broken/gh` reserve its refusal and then report
    # `GH=OK path=<the next entry>`, which pinned that entry as `AGENT_GH_REAL` and told the operator
    # the box was fine — the false PASS this read exists to refuse. STOP here and name it.
    if [ "$rc" -eq 1 ]; then
      IFS="$_ifs_save"
      msg="$cand: $detail"
      if [ -n "$pmsg" ]; then msg="$msg (also: $pmsg)"; fi
      printf 'GH=CANNOT-REACH-REAL-GH msg=%s\n' "$msg"; return 1
    fi
    # rc 2 is a weaker datum — recorded only when nothing better exists.
    if [ -z "$wmsg" ]; then wmsg="$cand: $detail"; fi
  done
  IFS="$_ifs_save"
  # ⛔ THE WALK'S DATUM OUTRANKS THE PIN'S DIAGNOSIS, AND NEITHER IS DROPPED (#fresh review P2). They
  # describe different things — what the PATH found, and why the inherited pin was unusable — and the
  # previous single slot let a pin diagnosis SUPPRESS the accurate finding (`…/shims/gh is the
  # argv-level gh shim`), which is the line an operator acts on.
  msg="$wmsg"
  if [ -n "$pmsg" ]; then
    if [ -n "$msg" ]; then msg="$msg (also: $pmsg)"; else msg="$pmsg"; fi
  fi
  if [ -n "$msg" ]; then
    printf 'GH=CANNOT-REACH-REAL-GH msg=%s\n' "$msg"; return 1
  fi
  printf 'GH=UNVERIFIABLE why=no_candidate msg=no gh on PATH, and no AGENT_GH_REAL pin\n'; return 2
}

# merge_contract_read <owner/repo> [<gh-command>] — is the merge contract readable HERE?
#   CONTRACT=OK required=<space-joined> repos=<slug>        rc 0
#   CONTRACT=UNREADABLE why=<token> repos=<slug>            rc 1  (EMPTY or unreadable — never "requires nothing")
#   CONTRACT=UNVERIFIED why=<token>                         rc 2  (no slug, or no gh to ask through)
# ⛔ THIS IS `required_checks`, NOT A SECOND IMPLEMENTATION. The rule that an empty read is a FAILED
# read lives in exactly one place; a copy here would be a second definition of the merge contract —
# the duplicate-contract defect this module was created to end. What this adds is the DISTINCTION the
# callers need: "the chain could not ask" (why=no_real_gh) is not "the contract came back empty".
# ⛔ AND IT ASKS THROUGH THE BOX'S OWN `gh` (the caller passes the bare name once the chain is proven
# to reach a real binary), NOT through the absolute path this read resolved. A resolved binary called
# by absolute path is UNPACED — it skips the serialisation/pacing layer that #1910 exists for, which
# the shim's own STATED LIMITS name as the class a caller must not enter casually. Asking through the
# chain also answers the question a WORKER asks ("can I read the contract from here?"), and the
# resolved path stays available for the operator to pin.
# ⚠️ STATED RESIDUAL: the call is NOT wrapped in a timeout of its own. It inherits whatever bound the
# gh layer it is asked through applies — the pacing/serialisation layer's when the chain is used — and
# that is DELIBERATE: this read must answer the same question the merge path (`resolve_required_checks`
# → `required_checks`) answers, with the same bound, or the two could disagree about what "readable"
# means. Bounding it here and not there would make a hanging network read as UNREADABLE on the status
# surface and as a stall on the merge surface — two verdicts for one condition.
merge_contract_read() {
  local or="${1:-}" gh="${2:-}" out
  case "$or" in ''|*/*/*|*:*) printf 'CONTRACT=UNVERIFIED why=no_repo_slug\n'; return 2 ;; esac
  case "$or" in */*) : ;; *) printf 'CONTRACT=UNVERIFIED why=no_repo_slug\n'; return 2 ;; esac
  if [ -z "$gh" ]; then
    printf 'CONTRACT=UNREADABLE why=no_real_gh repos=%s\n' "$or"; return 1
  fi
  if out="$(required_checks "$or" "$gh" 2>/dev/null)"; then
    printf 'CONTRACT=OK required=%s repos=%s\n' "$out" "$or"; return 0
  fi
  printf 'CONTRACT=UNREADABLE why=empty_or_unreadable repos=%s\n' "$or"; return 1
}

# ensure_agent_gh_real — export the ONE real gh this box resolves, so no layer can hop back into the
# chain. rc 0 = a pin is in place (honoured or newly discovered); rc 1 = nothing resolvable, so the
# box keeps its current behaviour and `bin/harness status` NAMES that state (never silence).
# ⛔ ONLY A COMPILED BINARY IS EVER EXPORTED (`_gh_is_binary`). Every harness layer AND the agent shim
# are shell scripts, and an `AGENT_GH_REAL` naming one re-enters the chain — measured in #2266 (2,543
# shim processes, every gh call on the box dead for ~10 hours) and refused at the seam by PR #2295. A
# WRONG PIN IS WORSE THAN NO PIN, so an unrecognised file is skipped, never exported — and a box whose
# `gh` IS a script keeps today's behaviour (the read still reports OK; nothing is pinned).
# ⛔ A PROVABLY-BROKEN INHERITED VALUE IS REPLACED; an operator's working one is not — and "working"
# is DECIDED BY THE PROBE THE READ USES, never by appearance (fresh review P2). A value that is a
# harness layer or the agent shim cannot be a preference (it IS the recursion, #2266), and a value
# whose `--version` does not answer as a gh cannot be one either: keeping it returned rc 0 ("a pin is
# in place") while the read of the very same value said CANNOT-REACH-REAL-GH — measured with
# `AGENT_GH_REAL=/usr/bin/false`, where every gh call on the box then failed silently and the caller
# was told the pin was fine. Both are dropped and re-resolved below.
ensure_agent_gh_real() {
  local line p
  if [ -n "${AGENT_GH_REAL:-}" ]; then
    if [ -f "${AGENT_GH_REAL}" ] && [ -x "${AGENT_GH_REAL}" ] \
       && ! _gh_is_harness_layer "${AGENT_GH_REAL}" && ! _gh_is_agent_shim "${AGENT_GH_REAL}" \
       && gh_probe_real "${AGENT_GH_REAL}" >/dev/null 2>&1; then
      return 0
    fi
    # ⛔ A PROVABLY-BROKEN PIN IS DROPPED, NOT CARRIED. A value naming a harness layer, the agent
    # shim, or a file that does not answer as a gh cannot be an operator preference — the first two
    # ARE the recursion (#2266) and the third fails every gh call it is handed — so leaving any of
    # them in place keeps the breakage on every descendant. Dropped here, re-resolved below. A value
    # that is merely a non-file is not unset (the seam's own `-f` check, #2295, already sends the call
    # to the PATH walk) and is replaced by the resolved binary at the end of this function.
    if [ -f "${AGENT_GH_REAL}" ] && [ -x "${AGENT_GH_REAL}" ]; then
      unset AGENT_GH_REAL
    fi
  fi
  line="$(gh_chain_read 2>/dev/null)" || return 1
  case "$line" in GH=OK*) ;; *) return 1 ;; esac
  # `path=` is LAST in the protocol, so everything after it IS the path — spaces included.
  p="${line#* path=}"
  [ -n "$p" ] && [ -f "$p" ] && [ -x "$p" ] || return 1
  _gh_is_binary "$p" || return 1
  AGENT_GH_REAL="$p"; export AGENT_GH_REAL
  return 0
}
