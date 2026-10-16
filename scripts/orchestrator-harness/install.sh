#!/usr/bin/env bash
# install.sh — render + install the launchd agent for the orchestrator harness.
#
# Deliberately does NOT start the loop. It writes the plist and prints the load command.
# Starting an autonomous merge loop is an explicit act, not a side effect of installing.
#
#   ./install.sh                 # render + install (idempotent)
#   ./install.sh --uninstall     # unload + remove the plist (leaves state/logs alone)
#
# Config comes from the environment; defaults are the values this harness was built with
# (see README §4). Nothing is written outside ~/Library/LaunchAgents and $O.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

O="${O:-$HOME/orchestrator}"
REPO="${REPO:-/Users/danielospina/Documents/GitHub/tortoise}"
OR="${OR:-daniel-ospina/tortoise}"

# sanity ceiling only; the swap/RAM gates below are the real constraint.
# Portable core count, IDENTICAL to orch-loop.sh's line. install.sh itself refuses to run off macOS
# (it renders a launchd plist), but selftest §7 EVALUATES this assignment on whatever host runs the
# suite and compares it with the loop's — so on a Linux host a divergence here would resolve
# MAX_LOAD=40 against the loop's cores*10 and fail a check for a difference with no runtime effect.
# sysctl -n hw.ncpu is a macOS-only key and sysctl is absent from a minimal Linux userland
# (debian:stable-slim ships no procps): in the LOOP that silently pinned _NCPU=4, MAX_LOAD=40 (#1702).
_NCPU="$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"
# ⛔ THE GUARD, NOT JUST THE LINE (P3, third review round, 2026-10-14). The comment above calls this
# assignment "IDENTICAL to orch-loop.sh's line" — the LINE was, the PROTECTION was not: orch-loop.sh
# coerces `_NCPU` with `is_num` on the line before its only read, and install.sh had NO is_num at all.
# `sysctl` can SUCCEED while printing an empty or garbage value, and `$(( 10#$_NCPU * 10 ))` is then a
# syntax error that ABORTS the installer mid-run under `set -euo pipefail` — instead of falling back
# to 4 exactly as the loop does. Same predicate as every shipped copy (leading zeros are read as
# octal by `$(( ))`, so `08` must be rejected too).
is_num() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; 0) return 0 ;; 0*) return 1 ;; *) return 0 ;; esac; }
# ⛔ A DIGIT STRING IS NOT ENOUGH FOR `_NCPU` — IT MUST BE A MAGNITUDE (P3, fifth review round,
# 2026-10-14). `is_num` accepts a 19-digit probe, and `$(( 10#$_NCPU * 10 ))` then WRAPS instead of
# erroring: 9223372036854775808 (2**63) * 10 is exactly 0, which every downstream guard accepts
# (`0` is a legal plist limit), so the rendered plist carries `MAX_LOAD=0` and the loop's
# `[ "$L" -ge 0 ]` is always true — the box dispatches NOTHING, silently and indefinitely. This was
# already closed in orch-loop.sh; install.sh runs the IDENTICAL derivation but had only `is_num`, so
# the wrap survived on the real production path (install.sh is what substitutes __MAX_LOAD__ into the
# live plist). Mirror the loop exactly.
is_limit() { is_num "${1:-}" && [ "${#1}" -le 9 ]; }
is_limit "${_NCPU:-}"   || _NCPU=4
# A 0-valued probe is a FAILED probe, not "no cores": the identical line is in orch-loop.sh.
[ "${_NCPU:-0}" -ge 1 ] || _NCPU=4
MAX_LOAD="${MAX_LOAD:-$(( 10#$_NCPU * 10 ))}"
# The same two guards the loop applies, for the same reason: the first fallback re-derives from the
# SAME `_NCPU`, so it cannot repair an out-of-range PRODUCT (a 9-digit probe yields a 10-digit value
# that `[ -ge ]` never binds); only a true default does. `is_limit` must NOT reject `0` — it also
# validates plist limits where 0 is legal (see the `0) : ;;` arm below).
is_limit "${MAX_LOAD:-}" || MAX_LOAD=$(( 10#$_NCPU * 10 )); is_limit "${MAX_LOAD:-}" || MAX_LOAD=40
MAX_LANES="${MAX_LANES:-4}"
MAX_REVIEW="${MAX_REVIEW:-4}"
MERGE_PRIORITY_AT="${MERGE_PRIORITY_AT:-25}"
MAX_FIX="${MAX_FIX:-3}"
MAX_FIX_TRIES="${MAX_FIX_TRIES:-3}"
MIN_SWAP_FREE="${MIN_SWAP_FREE:-600}"
MIN_MEM_FREE_MB="${MIN_MEM_FREE_MB:-512}"
BATCH="${BATCH:-2}"
CYC="${CYC:-240}"
# Drain scope (README §5): auto (count rule) | own (pin own-only) | broad (pin broad).
# A fleet runs exactly ONE broad box; the rest pin own. Validated below, AFTER the --uninstall
# branch (uninstall does not render, and must never be blocked by a config typo).
# ⛔ Presence, not emptiness: `${SCOPE:-auto}` would coerce a set-but-BLANK value to auto and
# silently evaporate the pin — the exact failure the whole SCOPE override exists to prevent.
[ -z "${SCOPE+x}" ] && SCOPE=auto

LABEL="com.eldato.orchestrator-loop"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
TEMPLATE="$HERE/launchd.plist.template"

die() { echo "❌ $*" >&2; exit 1; }
ok()  { echo "  ✓ $*"; }
warn(){ echo "  ⚠️  $*"; }

# ── uninstall ────────────────────────────────────────────────────────────────────
if [ "${1:-}" = "--uninstall" ]; then
  launchctl unload -w "$PLIST" 2>/dev/null || true
  rm -f "$PLIST"
  echo "✅ Removed $LABEL."
  echo "   State and logs left intact: $O/{logs,state,wip}"
  exit 0
fi

# SCOPE is operator config: orch-loop.sh treats anything but auto|own|broad (or UNSET) as FATAL,
# and set-but-empty is fatal too. Refuse it at install time, where the operator can still see it,
# so a typo cannot be rendered into a plist that dies on its first cycle.
case "$SCOPE" in
  auto|own|broad) ;;
  *) die "SCOPE must be auto|own|broad (got '$SCOPE')" ;;
esac

# $O must satisfy the SAME guard orch-loop.sh applies: it rejects a quote or shell metacharacter,
# because $O is interpolated into every lane's command string. A path that renders here but is
# refused there is worse than a refusal — with RunAtLoad+KeepAlive the daemon relaunches a
# guaranteed-fatal controller forever. Refuse at install time, where the operator can see it.
case "$O" in
  *"'"*|*'"'*|*'`'*|*'$'*|*';'*|*'|'*|*'&'*|*' '*) die "\$O must not contain a quote or shell metacharacter: $O" ;;
esac

# ── platform ─────────────────────────────────────────────────────────────────────
echo "==> preflight"
[ "$(uname)" = "Darwin" ] || die "this harness uses launchd + tmux; only macOS is supported"
[ -f "$TEMPLATE" ] || die "missing template: $TEMPLATE"

# ── dependencies ─────────────────────────────────────────────────────────────────
for bin in tmux gh pi; do
  command -v "$bin" >/dev/null 2>&1 && ok "$bin" || die "$bin not on PATH"
done
command -v uv >/dev/null 2>&1 && ok "uv" || warn "uv not found — lane.sh needs it to sync each worktree"
gh auth status >/dev/null 2>&1 && ok "gh authenticated" || die "gh is not authenticated"

# ── the daemon's PATH ────────────────────────────────────────────────────────────
# ⛔ launchd gives a process NO shell environment, so every binary the daemon shells out to must be
# findable on the PATH baked into the plist. The original version hardcoded three brew dirs, which
# was correct only because gh/uv/pi happened to be brew-installed on the box it was built on.
# On a box where they live under the user's own prefix the loop does NOT fail loudly — it reads an
# EMPTY QUEUE: `OPEN_N="$(gh pr list ... 2>/dev/null)"` yields "" and `${OPEN_N:=0}` turns that
# into 0, so the sweep logs `[scope] open=0 -> OWN` while the queue is full and the loop idles.
# Measured 2026-10-12 on a second box: 25 open PRs invisible; `pi` missing would also have broken
# every lane spawn and `uv` every worktree sync. Resolve the real directories instead of assuming.
# Three traps here, and ALL fail silently at runtime rather than loudly at install time:
#  (1) `command -v` can return a WRAPPER, not the tool. Where `gh` is the pi agent shim
#      (~/.pi/agent/shims/gh), the resolved directory is the SHIM's — and the shim locates the real
#      gh by scanning PATH minus its own directory, finds nothing, and exits 127. The loop then
#      reads an empty queue and logs `[scope] open=0 -> OWN`. A shimmed tool therefore needs the
#      directory of its REAL binary on the PATH too.
#  (2) `command -v` can return a NON-ABSOLUTE name (a shell function/alias), and `dirname` of that
#      is `.` — baking the current directory into an unattended daemon's PATH.
#  (3) ⛔ A shim directory must NEVER be baked into the daemon PATH at all — under launchd the shim
#      can be UNEXECUTABLE. ~/.pi/agent/shims/gh is a symlink INTO ~/Documents, and macOS TCC
#      (Transparency, Consent & Control) blocks launchd from reading ~/Documents, so the daemon
#      gets `bash: ~/.pi/agent/shims/gh: Operation not permitted` — EPERM (a TCC denial on the
#      symlink's TARGET), NOT a missing file or permission bit. The install shell is interactive
#      and CAN read ~/Documents, so the probe-by-execution below SUCCEEDS and install reports OK:
#      a FALSE GREEN for exactly the silent failure this block exists to prevent (the daemon later
#      reads an empty queue and idles at open=0). No install-time probe can see the EPERM, so the
#      exclusion below — not a stronger probe — is the guard. add_dir() therefore refuses every
#      `*/shims`, `*/shims/*` and `*/.pi/*` directory while the "resolve PAST a wrapper" loop keeps
#      adding the REAL binary's directory, so the tool is still findable. Do not "simplify" this
#      exclusion away: it is invisible to every check that runs before launchd does.
add_dir() {
  case "$1" in /*) ;; *) return 0 ;; esac
  # ⛔ Trap (3): a shim / ~/.pi directory is EPERM under launchd (macOS TCC on ~/Documents). The
  # real binary's directory is added separately, so dropping the shim does not lose the tool.
  # Test the PHYSICAL path (pwd -P), not the name: a PATH entry that is a SYMLINK to the shim
  # directory matches none of the name patterns, and without this it slips through AND suppresses
  # the real binary (the resolve-past loop keys off the same patterns). Store the LOGICAL path so
  # the version-independent pi symlink is not pinned to a version-stamped target.
  local _phys
  _phys="$(cd "$1" 2>/dev/null && pwd -P)" || return 0
  case "$_phys" in ""|*/shims|*/shims/*|*/.pi/*) return 0 ;; esac
  case ":$DAEMON_PATH:" in *":$1:"*) ;; *) DAEMON_PATH="$DAEMON_PATH:$1" ;; esac
}
DAEMON_PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
# Prefer the version-independent pi symlink: a resolved version-stamped pi-node directory is pinned
# to today's version, and a pi upgrade would leave the daemon on a stale (or missing) one.
if [ -x "$HOME/.local/share/pi-node/current/bin/pi" ]; then
  command -v pi >/dev/null 2>&1 && add_dir "$HOME/.local/share/pi-node/current/bin"
fi
for bin in tmux gh uv pi; do
  # ⛔ Resolve the BINARY, not a shell function/alias. `command -v` reports an exported function
  # REGARDLESS of PATH (and a BARE name for it), so with a `gh`/`pi` function in the environment the
  # real binary's directory would never be found AND the name would be unusable. `type -P` searches
  # PATH ONLY (ignoring functions/aliases) and returns an absolute path — exactly what launchd will
  # exec — so trap (2) (a `.`-dirname from a bare name) cannot arise; the `/*` guard stays as
  # defence in depth.
  p="$(type -P "$bin" 2>/dev/null)" || continue
  case "$p" in /*) ;; *) continue ;; esac
  add_dir "$(cd "$(dirname "$p")" 2>/dev/null && pwd)"
done
# Resolve PAST a wrapper: add the first PATH entry holding a real executable of that name outside a
# shim/.pi directory, so the shim can find it. Tested on the PHYSICAL path like add_dir(), so a
# symlink TO a shim directory is recognised as a shim too.
for bin in gh pi uv tmux; do
  p="$(type -P "$bin" 2>/dev/null)" || continue
  case "$p" in /*) ;; *) continue ;; esac
  _pd="$(cd "$(dirname "$p")" 2>/dev/null && pwd -P)" || continue
  case "$_pd" in
    */shims|*/shims/*|*/.pi/*)
      _oldifs="$IFS"; IFS=:
      # `for d in $PATH` word-splits on `:` and then GLOBS each entry: an entry containing `*`
      # would expand to directories that are not PATH entries. Disable globbing for the scan.
      case $- in *f*) _had_noglob=1 ;; *) _had_noglob=0 ;; esac
      set -f
      for d in $PATH; do
        [ -n "$d" ] || continue
        _dd="$(cd "$d" 2>/dev/null && pwd -P)" || continue
        case "$_dd" in ""|*/shims|*/shims/*|*/.pi/*) continue ;; esac
        if [ -x "$d/$bin" ]; then add_dir "$d"; break; fi
      done
      [ "$_had_noglob" = 1 ] || set +f
      IFS="$_oldifs" ;;
  esac
done
ok "daemon PATH: $DAEMON_PATH"
# ⛔ PROBE BY EXECUTION AND BY ABSOLUTE PATH. Resolving a name is not running it, and `command -v`
# cannot answer the daemon's question: it reports an EXPORTED SHELL FUNCTION (which launchd never
# sees), and executed by bare name it would run the function instead of the daemon's binary — a
# false green. `type -P` under the daemon PATH returns the absolute binary launchd will exec
# (ignoring functions/aliases); each is then EXECUTED. A shim/wrapper directory that does not match
# the exclusion patterns (cmux's `cmux-cli-shims` is a real one) is caught here because its tool
# exits 127. uv is optional (warned above): its failure WARNS, and is never fatal. Still BLIND to
# trap (3) — TCC refuses the read only when LAUNCHD does it, not when an interactive shell does.
for bin in tmux uv pi gh; do
  command -v "$bin" >/dev/null 2>&1 || continue     # not present in this shell at all
  # ⛔ `|| true`: install.sh runs under `set -euo pipefail`, and `type -P` returns non-zero for a
  # tool that is not on $DAEMON_PATH. Unguarded, that bare assignment aborts the script AT THIS
  # LINE — before the `if [ -n "$_p" ]` test below — so the operator gets a bare rc=1 with no
  # diagnostic, and the optional `uv` (documented and warned as non-fatal above) becomes fatal.
  _p="$(PATH="$DAEMON_PATH" type -P "$bin" 2>/dev/null || true)"
  case "$_p" in /*) ;; *) _p="" ;; esac
  # tmux takes -V; the rest take --version. Either way it must actually EXECUTE.
  _vflag="--version"; [ "$bin" = "tmux" ] && _vflag="-V"
  # ⛔ Execute under the DAEMON PATH, not this shell's: a wrapper that DELEGATES by name (strip
  # its own dir, `exec $bin`) would find the tool on the interactive PATH and exit 0 while launchd
  # gets 127 — the same false green one layer in. The prefix reproduces the daemon's environment.
  if [ -n "$_p" ] && PATH="$DAEMON_PATH" "$_p" "$_vflag" >/dev/null 2>&1; then continue; fi
  if [ "$bin" = "uv" ]; then
    warn "daemon PATH cannot run uv — lane.sh will not sync worktrees: $DAEMON_PATH"
  else
    die "daemon PATH cannot run $bin: $DAEMON_PATH"
  fi
done

# ── the merge authority ──────────────────────────────────────────────────────────
# The harness can review and record, but it cannot MERGE without the gate key.
# IMPORTANT: only the key FILE reaches the daemon. launchd inherits no shell environment, and
# install.sh deliberately does not copy a secret into a world-readable plist — so an env-only key
# must be reported as insufficient rather than as "present", or the box silently degrades to
# review-only while everyone believes it holds the merge authority.
KEY_FILE="$HOME/.pi/agent/.ai-review-gate-key"
# -s, not -f: a ZERO-BYTE key file is not a key. And test the CONTENT, not the size: the consumer
# (record-review.sh) strips whitespace and treats the result as absent, so a 1-byte newline file —
# exactly what `echo "$AI_REVIEW_GATE_KEY" > file` writes for an unset variable — must not be blessed.
KEY_TRIMMED="$(tr -d '[:space:]' 2>/dev/null < "$KEY_FILE" || true)"
if [ -n "$KEY_TRIMMED" ]; then
  ok "gate key file present ($KEY_FILE)"
  [ -n "${AI_REVIEW_GATE_KEY:-}" ] && ok "AI_REVIEW_GATE_KEY also exported in this shell"
elif [ -f "$KEY_FILE" ]; then
  # An EXISTING but UNREADABLE file is neither missing nor empty, and the remedy differs: telling
  # the operator to WRITE a 000-mode file that may already hold a valid key is advice that
  # reproduces the state it was meant to fix. `[ -r ]` is what separates the two. The shared
  # CONSEQUENCE is emitted after the branch — ahead of it, an orphaned `→` continuation attaches to
  # whatever the previous check printed and names neither the file nor the fault.
  if [ -r "$KEY_FILE" ]; then
    warn "$KEY_FILE holds no key (empty or whitespace-only) — treated as absent."
    warn "  → fix: printf '%s' \"\$AI_REVIEW_GATE_KEY\" > $KEY_FILE && chmod 600 $KEY_FILE"
  else
    warn "$KEY_FILE exists but is NOT READABLE — treated as absent."
    warn "  → it may already hold a valid key: check its mode and its parent directories."
    warn "  → fix: chmod 600 $KEY_FILE  (and 700 on its parent directories)"
  fi
  warn "  → the daemon will record reviews UNSIGNED and ai-review-gate will fail: no merge role."
elif [ -n "${AI_REVIEW_GATE_KEY:-}" ]; then
  warn "AI_REVIEW_GATE_KEY is set in THIS SHELL ONLY — launchd will not see it."
  warn "  → the daemon will record reviews UNSIGNED and ai-review-gate will fail: no merge role."
  warn "  → fix: printf '%s' \"\$AI_REVIEW_GATE_KEY\" > $KEY_FILE && chmod 600 $KEY_FILE"
else
  warn "no AI_REVIEW_GATE_KEY (neither $KEY_FILE nor the environment)"
  warn "  → the loop degrades to review/record only. Fine for evaluation; not for a merge role."
fi
[ -f "$HOME/.pi/agent/scripts/record-review.sh" ] \
  && ok "record-review.sh" \
  || warn "~/.pi/agent/scripts/record-review.sh missing — record step will fail (shipped by agent-infra)"

# ── target repo ──────────────────────────────────────────────────────────────────
git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || die "not a git checkout: $REPO"
git -C "$REPO" check-ignore -q .worktrees/ \
  && ok "$REPO/.worktrees is gitignored" \
  || die "$REPO/.worktrees is NOT gitignored — worktrees would be committed. Fix .gitignore first."
[ -f "$REPO/tools/collision_preflight.py" ] \
  && ok "collision pre-flight present in the repo" \
  || true
# ── dispatch provisioning, judged ONCE here (agent-infra#1736) ───────────────────
# The refresh step refills the dispatch backlog, and orch-loop.sh runs it in a BACKGROUNDED
# subshell — so a refresh that aborts every cycle cannot fail the loop: the controller reports
# RUNNING with `lanes: 0` forever and the cell is MERGE-ONLY. Surface it at install time, with the
# reason, by running refresh-candidates.sh's own read-only `--check` (the same probe the cell's
# `start` runs). Warn, not die: a deliberately merge-only install is a legitimate configuration,
# and the hard gate is the cell supervisor's `check`, which refuses to START such a cell.
if PV="$(REPO="$REPO" OR="$OR" O="$O" bash "$HERE/refresh-candidates.sh" --check 2>&1)"; then
  printf '%s\n' "$PV" | sed 's/^/    /'
  ok "dispatch provisioning — this repo can be pre-flighted, so lanes will be dispatched"
else
  printf '%s\n' "$PV" >&2
  warn "this repo cannot be provisioned for dispatch — a cell on it could only MERGE;"
  warn "  refresh-candidates.sh would add nothing to the backlog (agent-infra#1736)."
  warn "  Fix: set TORTOISE_REPO=<a tortoise checkout>, or vendor tools/collision_preflight.py into $REPO."
fi
# The scout VENV is a uv-Python step: warn about it only for a repo that declares one.
if [ -f "$REPO/pyproject.toml" ] && [ ! -x "$REPO/.worktrees/dispatch-scout/.venv/bin/python" ]; then
  warn "scout worktree/venv not provisioned at $REPO/.worktrees/dispatch-scout"
  warn "  → refresh-candidates.sh will provision it on first run (git worktree add + uv sync),"
  warn "    which takes a couple of minutes and needs network access."
fi

# ── shipped scripts ──────────────────────────────────────────────────────────────
for f in "$HERE"/*.sh; do
  bash -n "$f" || die "syntax error in $(basename "$f")"
done
ok "all shipped scripts parse"

# ── state dir ────────────────────────────────────────────────────────────────────
mkdir -p "$O/logs" "$O/state" "$O/wip"
touch "$O/candidates.txt" "$O/dispatched.txt" "$O/checked.txt"
ok "state dir $O"

# ── render plist ─────────────────────────────────────────────────────────────────
echo "==> rendering $PLIST"
mkdir -p "$(dirname "$PLIST")" || die "cannot create $(dirname "$PLIST") — is HOME=$HOME correct?"
# Two independent levels of escaping are required, and they fail differently:
#  1. XML — a bare & < > makes the plist invalid XML and launchd will not load it. (plutil -lint
#     catches this, so it fails loudly rather than silently.)
#  2. sed — an unescaped & in the REPLACEMENT expands to the matched text, so `O=/tmp/a&b`
#     rendered the path as /tmp/a__O__b: a syntactically VALID plist pointing at wrong paths,
#     which plutil -lint cannot catch. Escape \, & and the | delimiter too.
xml_esc() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'; }
sed_esc() { printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'; }
esc() { sed_esc "$(xml_esc "$1")"; }
# Every numeric limit below is substituted VERBATIM -- deliberately NOT routed through esc(), because
# a whole number has nothing to escape. That contract was never checked, and breaking it fails two
# different ways: '4x' renders a plist that LIES about the ceiling and still exits 0 (only the loop's
# own coercion saves the run), while '4&5' renders the literal `4__MAX_LANES__5` -- a syntactically
# VALID plist (plutil -lint passes) whose value reads as non-numeric downstream.
for _n in MAX_LOAD MAX_LANES MAX_REVIEW MERGE_PRIORITY_AT MAX_FIX MAX_FIX_TRIES MIN_SWAP_FREE MIN_MEM_FREE_MB BATCH CYC; do
  _v="${!_n}"
  case "${_v:-}" in
    ''|*[!0-9]*) die "$_n='${_v:-}' is not a whole number — a value here silently opens the gate it configures" ;;
    0) : ;;
    # ⛔ LEADING ZEROS (P1/P2, second review round, 2026-10-14). `''|*[!0-9]*` accepted `08`, which
    # rendered into the plist and then reached the loop, where `$(( ))` parses base 0 (leading 0 =
    # OCTAL) and `08`/`09` are not octal — on /bin/bash 3.2.57 the failed arithmetic silently
    # disabled the claim / discarded the controller loop. The loop now coerces such a value to the
    # DEFAULT, so accepting it here would render a plist that LIES about the ceiling while exiting 0.
    # Refuse it loudly instead: a value this installer accepts must be the value the loop uses.
    0*) die "$_n='$_v' has a leading zero — the loop reads these in base 10 and would silently coerce it to the default" ;;
  esac
  # A digit string is not enough: `[` ERRORS at or above 2**63, and an errored test is FALSE, which
  # OPENS the gate the value configures. `MAX_LANES=99999999999999999999` passed the class test, and
  # install.sh exited 0; the loop then compared, errored, and lost the lane cap. No limit here is near
  # a billion, so bound the length.
  [ "${#_v}" -le 9 ] || die "$_n='$_v' is out of range (at most 9 digits)"
done
# ⛔ CYC NEEDS A FLOOR, NOT JUST A TYPE CHECK (P3, third review round, 2026-10-14). The loop above
# deliberately allows `0` — it is a valid integer and every OTHER limit may legitimately be 0 — but
# `CYC=0` reaches the loop's `sleep $(( 10#0 - 0 + RANDOM % 1 ))` = `sleep 0`, so the controller
# revisits every cycle with no delay and hammers the GitHub API. The loop floors it to 240 as well;
# refusing it here is the consistent half — a value this installer accepts must be the value the loop
# uses. 5s, not 240, so a deliberately small cycle is not silently replaced.
[ "$CYC" -ge 5 ] || die "CYC=$CYC is below the 5s floor — a zero (or near-zero) cycle re-hits the GitHub API with no delay"
# Each value is substituted by its OWN sed rule and the rules run IN ORDER, so a value carrying a
# LATER token is rewritten by that later rule: `OR=__MAX_LANES__` rendered as `4` — exit 0, plutil OK,
# and the daemon then ran `gh --repo 4`. Refusing it at the input also means the post-render assertion
# below can only fire on a genuinely unrendered TEMPLATE token, never on a value that merely looks
# like one (a legal `O=/tmp/__DATA__host` used to be refused with a diagnostic naming the wrong cause).
for _v in "$O" "$REPO" "$OR" "$SCOPE" "$HOME" "$DAEMON_PATH"; do
  case "$_v" in *__[A-Z_]*__*) die "a substituted value contains a template token ('$_v') — sed applies its rules in order, so a later rule would rewrite it" ;; esac
  case "$_v" in *$'\n'*) die "a substituted value contains a newline, which sed cannot put in a replacement" ;; esac
done
# Render ATOMICALLY: the redirect truncates its target BEFORE sed runs, so rendering straight into
# $PLIST and then rejecting the result left the LIVE plist empty or poisoned -- and README §9's next
# step (`launchctl unload && launchctl load`) then failed, so a rejected re-install destroyed a working
# daemon config. Render to a temp file, validate THAT, and only then move it into place.
#
# The trap is not decoration: the render runs under `set -euo pipefail`, so a sed/template read
# failure aborts BETWEEN creating $RENDER and the two explicit `rm -f`s below, orphaning a
# `*.plist.new.<pid>` in LaunchAgents that nothing ever prunes (README §7.5 tracks exactly this
# class of unbounded growth). It also covers any future early-exit between here and the `mv`. After
# a successful `mv` the path no longer exists, so the trap is a no-op on the happy path.
RENDER="$PLIST.new.$$"
trap 'rm -f "$RENDER"' EXIT
sed \
  -e "s|__O__|$(esc "$O")|g" \
  -e "s|__REPO__|$(esc "$REPO")|g" \
  -e "s|__OR__|$(esc "$OR")|g" \
  -e "s|__SCOPE__|$(esc "$SCOPE")|g" \
  -e "s|__HOME__|$(esc "$HOME")|g" \
  -e "s|__PATH__|$(esc "$DAEMON_PATH")|g" \
  -e "s|__MAX_LOAD__|$MAX_LOAD|g" \
  -e "s|__MAX_LANES__|$MAX_LANES|g" \
  -e "s|__MAX_REVIEW__|$MAX_REVIEW|g" \
  -e "s|__MERGE_PRIORITY_AT__|$MERGE_PRIORITY_AT|g" \
  -e "s|__MAX_FIX__|$MAX_FIX|g" \
  -e "s|__MAX_FIX_TRIES__|$MAX_FIX_TRIES|g" \
  -e "s|__MIN_SWAP_FREE__|$MIN_SWAP_FREE|g" \
  -e "s|__MIN_MEM_FREE_MB__|$MIN_MEM_FREE_MB|g" \
  -e "s|__BATCH__|$BATCH|g" \
  -e "s|__CYC__|$CYC|g" \
  "$TEMPLATE" > "$RENDER"
plutil -lint "$RENDER" >/dev/null || { rm -f "$RENDER"; die "rendered plist is invalid"; }
# plutil -lint proves the XML is well-formed; it cannot tell that a substitution did not take. The
# substituted VALUES are checked above, so a token surviving here means the TEMPLATE has a token with
# no rule -- which this catches, and it catches it for any token added later too.
if grep -q '__[A-Z_]*__' "$RENDER"; then
  _toks="$(grep -o '__[A-Z_]*__' "$RENDER" | sort -u | tr '\n' ' ')— a template token has no substitution rule"
  rm -f "$RENDER"; die "rendered plist still contains ${_toks}"
fi
mv -f "$RENDER" "$PLIST"
ok "plist valid"

# launchd runs $O/<script>, not the copies in this directory — check EVERY script the daemon
# invokes, not just orch-loop.sh. A drift here is silent and serious: a fix applied only to the
# shipped copy (e.g. the fail-closed ai-review-gate classifier) would never reach the running box.
# claims.sh is in this list because it is SOURCED by orch-loop.sh and merge-one.sh, so the daemon
# executes it — leaving it out let a fix to the claim CAS sit in the repo while $O ran the old one
# (the same silent-drift failure this list exists to name). repo-authority.sh is here for the SAME
# reason (#1764): it is sourced by both, and a $O copy without it holds the resolver the daemon
# needs to know what the target repo actually requires. spawn-gate.sh is the SAME class again
# (review round 2, P2): it is sourced by lane.sh and fix-one.sh — orch-loop.sh deliberately does NOT
# source it (see its own header; it keeps a private can_spawn for its decision sites) — and it CARRIES
# the gate codes those two callers branch on. A $O copy left behind at a pre-#1765 revision is a caller
# missing AGENT_DISK_REFUSED, which under `set -u` aborts a refusal before its refund (the callers
# are tolerant of that now, but surviving a stale helper silently is not the same as DETECTING it).
DRIFTED=""
for f in orch-loop.sh claims.sh repo-authority.sh spawn-gate.sh dispatch-merge.sh lane.sh chain-merge.sh merge-one.sh fix-one.sh refresh-candidates.sh adopt-fix.sh; do
  [ -f "$O/$f" ] || { DRIFTED="$DRIFTED $f(missing)"; continue; }
  diff -q "$HERE/$f" "$O/$f" >/dev/null 2>&1 || DRIFTED="$DRIFTED $f"
done
if [ -n "$DRIFTED" ]; then
  warn "the running copy at \$O differs from the shipped copy:$DRIFTED"
  warn "  the daemon executes \$O/<script> — sync them or the fixes here are not in effect:"
  warn "  cp '$HERE'/*.sh '$O'/";
fi

cat <<EOF

✅ Installed $LABEL

  harness   $O
  repo      $REPO   ($OR)
  limits    lanes=$MAX_LANES review=$MAX_REVIEW fix=$MAX_FIX fix_tries=$MAX_FIX_TRIES
            max_load=$MAX_LOAD min_swap_free=${MIN_SWAP_FREE}M min_mem_free_mb=${MIN_MEM_FREE_MB}M batch=$BATCH cycle=${CYC}s
            merge_priority_at=${MERGE_PRIORITY_AT} UNOWNED open PRs

The loop is NOT running. To start it:

    launchctl load -w "$PLIST"

Watch it (the first line of the decision log each cycle):

    tail -f "$O/logs/orch-loop.log"

Liveness — a stale heartbeat means the controller is wedged:

    echo \$(( \$(date +%s) - \$(cat "$O/heartbeat") ))   # seconds since last cycle

Stop it before handing the machine to a human, and capture dirty work (README §6):

    launchctl unload -w "$PLIST"; pkill -f orch-loop.sh; rm -f "$O/.orch.lock"
EOF
