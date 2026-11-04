#!/usr/bin/env bash
# orch-pin-exec.sh — the STABLE launchd entrypoint for the orchestrator loop (agent-infra#3309).
#
# ⛔ WHY THIS FILE EXISTS. launchd reads `ProgramArguments` ONCE at bootstrap and cannot follow a
# moving pin. The rendered program used to be `$HARNESS/$HARNESS_ENTRY`, i.e.
# `~/harness/<sha12>/scripts/orchestrator-harness/launchd-controller.sh` — a HASH-NAMED snapshot that
# `harness-refresh.sh` garbage-collects as the pin advances. The moment the pin moved, every launchd
# tick died on `No such file or directory` (exit 127) while `launchctl list` still reported the job
# `loaded`, `launchd.err` repeated one stale-looking line, and a 15-hour-old `candidates.txt` read as a
# full queue. The loop was dead for ~15 hours and nothing said so.
#
# This stub sits at a path that never moves (`$O/orch-pin-exec.sh`) and resolves the CURRENT pin on
# every tick, so a pin advance changes what runs WITHOUT touching the plist. install.sh renders the
# plist to name THIS file and REFUSES to install unless this file, run now, resolves to the pin's own
# entrypoint — so "the plist names a tree nobody verified" cannot be rendered.
#
# ⛔ NOT A HAND-EDITED COPY (the #2231 defect). The bytes are seeded from the pinned tree by
# install.sh on every run; the wrapper is a fixed resolver, not a controller, so there is no logic in
# it that can diverge from the pin. `check-deployed-drift.sh` compares it against the shipped copy.
#
# Contract:
#   orch-pin-exec.sh                 exec the current pin's entrypoint (what launchd runs)
#   orch-pin-exec.sh --resolve-only  print the program that would be exec'd, change nothing
#   exit 127 + a `PIN-EXEC: DEAD-SUPERVISOR:` line on stderr when the pin cannot be resolved.
#
# ⛔ THE 127 IS DELIBERATE. It preserves the exit code the fleet already reads (`launchctl list` shows
# it beside the label), and the MARKER is what makes it diagnosable: `127` alone is a bare number
# nobody reads, which is exactly how a dead supervisor read as "between ticks". Grep for the marker —
# never infer liveness from `loaded`.

set -uo pipefail

# ⛔ PHYSICAL PATHS, OR THE "NEVER EXEC OURSELVES" GUARD FAILS OPEN (agent-infra#3309 review, P1).
# `pwd` returns a LOGICAL path: with `~/orchestrator` (or any pin root) reachable through a symlink, the
# stub's own path and an alias of its own directory are different STRINGS for the same file — so a pin
# record naming the alias with `ORCH_ENTRY=orch-pin-exec.sh` was NOT refused: `--resolve-only` printed
# the alias path of the stub itself and exited 0, and the exec path would re-exec this file every 10 s
# under KeepAlive/ThrottleInterval. That is the launchd spin this guard exists to prevent, in its own
# named shape. `pwd -P` alone is not enough either: a symlinked FILE needs following too, which is what
# `phys` does (bash 3.2 / macOS safe — no `readlink -f`, no GNU tools).
phys() { # <path> → absolute path with every dir AND file symlink resolved
  local p="$1" d t
  [ -n "$p" ] || { printf '%s' "$p"; return 0; }
  while [ -L "$p" ]; do
    d="$(cd -P "$(dirname "$p")" >/dev/null 2>&1 && pwd -P)" || break
    t="$(readlink "$p" 2>/dev/null)" || break
    case "$t" in /*) p="$t" ;; *) p="$d/$t" ;; esac
  done
  d="$(cd -P "$(dirname "$p")" >/dev/null 2>&1 && pwd -P)" || { printf '%s' "$p"; return 0; }
  printf '%s/%s' "$d" "$(basename "$p")"
}

SELF_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
SELF="$(phys "${BASH_SOURCE[0]}")"

die() {
  printf 'PIN-EXEC: DEAD-SUPERVISOR: %s\n' "$*" >&2
  printf 'PIN-EXEC: this job is a DEAD SUPERVISOR, not "between ticks" — launchd keeps it loaded and\n' >&2
  printf 'PIN-EXEC: retries it on ThrottleInterval. Fix the pin record, then: launchctl kickstart -k gui/%s/%s\n' \
    "$(id -u)" "${LABEL:-com.eldato.orchestrator-loop}" >&2
  exit 127
}

RESOLVE_ONLY=0
case "${1:-}" in
  --resolve-only) RESOLVE_ONLY=1 ;;
  --help|-h)
    printf 'usage: %s [--resolve-only]\n' "$(basename "$SELF")"
    printf '  execs the harness the pin record names; --resolve-only prints it\n'
    exit 0 ;;
  '') : ;;
  *) die "unexpected argument '$1' (this entrypoint takes no arguments; use --resolve-only)" ;;
esac

# The DIR record is the one that matters: `HARNESS_PIN` is the SHA, `HARNESS_PIN_FILE` is the path the
# controller execs (the cells' own spelling, agent-infra#2215). Both are rendered into the plist's
# EnvironmentVariables, so launchd supplies them; the defaults keep this runnable by hand.
PIN_FILE="${HARNESS_PIN_FILE:-$HOME/.harness-path}"

[ -e "$PIN_FILE" ] || die "pin dir record ${PIN_FILE} does not exist — the loop has no harness to exec (the record is written by install.sh and advanced by harness-refresh.sh)"
[ -r "$PIN_FILE" ] || die "pin dir record ${PIN_FILE} exists but is UNREADABLE — cannot resolve a harness"

# ⛔ ONE LINE, TRIMMED. A trailing newline or CR from a rewritten record must not become part of a path
# (`cd '/x/y\r'`); `head -n1` also means a record with diagnostics appended after the path still
# resolves instead of silently failing.
DIR="$(head -n1 "$PIN_FILE" 2>/dev/null | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

[ -n "$DIR" ] || die "pin dir record ${PIN_FILE} is EMPTY — a blank record is a dead supervisor, not an unset option"
case "$DIR" in
  /*) : ;;
  *)  die "pin dir record ${PIN_FILE} holds a RELATIVE path ('${DIR}') — the launchd cwd is the job WorkingDirectory (\$O), so a relative pin is not addressable" ;;
esac
[ -d "$DIR" ] || die "pin dir '${DIR}' (from ${PIN_FILE}) DOES NOT EXIST — the snapshot was garbage-collected as the pin advanced. This is the #3309 failure: the plist is fine, the pin record is stale. Advance it (harness-refresh.sh) or re-run install.sh"
[ -x "$DIR" ] || die "pin dir '${DIR}' is not searchable by this user — cannot exec the controller inside it"

# Which entry inside the pin: the same preference install.sh applies at render time, so the wrapper and
# the installer can never disagree about the program. `ORCH_ENTRY` is the deliberate override.
ENTRY="${ORCH_ENTRY:-}"
if [ -z "$ENTRY" ]; then
  if [ -f "$DIR/launchd-controller.sh" ]; then ENTRY="launchd-controller.sh"
  elif [ -f "$DIR/orch-loop.sh" ]; then ENTRY="orch-loop.sh"
  else
    die "the pin dir '${DIR}' carries NEITHER launchd-controller.sh NOR orch-loop.sh — there is nothing to exec"
  fi
fi
case "$ENTRY" in
  ''|*/*) die "entry '$ENTRY' is not a bare name inside the pin dir" ;;
esac
PROGRAM="$DIR/$ENTRY"
[ -f "$PROGRAM" ] || die "the pin dir '${DIR}' does not carry '${ENTRY}' — the pin is half-materialised (re-run harness-refresh.sh)"
[ -r "$PROGRAM" ] || die "'${PROGRAM}' exists but is unreadable"

# ⛔ NEVER EXEC OURSELVES. A pin record pointing back at this stub (a mis-restored `.harness-path`
# naming `$O` or a symlink to it, or an entry name equal to this file) would fork-bomb launchd on a 10 s
# KeepAlive loop instead of failing. Compare PHYSICAL paths, not strings: `pwd` alone made the two sides
# disagree whenever either was reached through a symlink, and the guard passed the alias through.
PROGRAM_REAL="$(phys "$PROGRAM")"
[ "$PROGRAM_REAL" != "$SELF" ] || die "the pin record resolves back to THIS wrapper (${SELF}) — refusing to exec ourselves in a launchd loop"

if [ "$RESOLVE_ONLY" = "1" ]; then
  printf '%s\n' "$PROGRAM"
  exit 0
fi

# The bash that launchd invoked is the bash the controller gets; no re-exec through a different
# interpreter, no `cd` (the plist's WorkingDirectory is the worker surface $O, deliberately not the repo).
exec /bin/bash "$PROGRAM"
