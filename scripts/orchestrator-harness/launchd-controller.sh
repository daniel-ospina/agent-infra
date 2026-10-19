#!/bin/bash
# launchd-controller.sh — the launchd entry point: keep the controller alive INSIDE tmux.
#
# ⛔ WHY THIS EXISTS (measured 2026-10-18, this Mac). A launchd job cannot read the product
# checkout. The repo lives under ~/Documents, which macOS TCC protects, so a launchd-born
# `/bin/bash` gets `Operation not permitted` on the whole tree — not just on its cwd:
#
#   launchd job /bin/bash   -> head -c 12 ~/Documents/GitHub/tortoise/pyproject.toml : EPERM
#   launchd job tmux        -> [project]                                              : OK
#   fresh `tmux -L sock`    -> [project]                                              : OK
#
# So the fix is NOT a better cwd. `cd` into the repo SUCCEEDS and every read inside it still
# fails; `git` then dies with `Unable to read current working directory: Operation not
# permitted`, `_claim_commit` returns "", and every candidate is refused with the misleading
# "[dispatch] #N NOT dispatched — could not build claim commit". install.sh already documents
# this TCC class for the gh shim ("macOS TCC blocks launchd from reading ~/Documents").
#
# The Full Disk Access grant on this box is attached to the **tmux binary**. A process forked by
# a tmux server therefore inherits it, whatever launched that server (the fresh-socket case above
# proves it is the binary's grant, not a particular server's birth lineage). Running the
# controller as a tmux pane command is what gives it a repo it can actually read.
#
# ⛔ THE SESSION NAME MUST NOT COLLIDE WITH THE LANE PREFIXES. orch-loop.sh counts concurrency
# with `tmux ls | grep -c '^lane-'` / '^fix-' / '^merge-' and reaps with '^(merge|lane|fix)-';
# `orch-controller` matches none of those, so it can never be counted as a lane or reaped.
#
# ⛔ THE JOB'S WorkingDirectory MUST NOT BE THE REPO. A launchd job started with a TCC-denied cwd
# cannot even `getcwd` (bash: `getcwd: cannot access parent directories: Operation not
# permitted`), which breaks python3 (`PermissionError`) and therefore the refresh's reap pass —
# that is how the candidate queue froze for six hours. ~/orchestrator is outside TCC.

set -u

# ⛔ NO MACHINE-SPECIFIC PATHS IN THIS FILE (#2094 class, and the reason orch-loop.sh already refuses
# to default REPO). `O` is the SAME expression every other entry point uses — `$HOME/orchestrator`,
# exactly as in install.sh:26 and orch-loop.sh:24 — not one developer's absolute home. A lifted
# `O=/Users/<someone>/orchestrator` works on the box it was copied from and nowhere else: it reads a
# candidates.txt that does not exist, which is indistinguishable from an empty backlog, so the
# controller reports health over a queue it never opened.
O="${O:-$HOME/orchestrator}"
S="${CONTROLLER_SESSION:-orch-controller}"

# tmux is RESOLVED, not assumed at one Apple-Silicon path. `/opt/homebrew/bin` is Homebrew on arm64
# and `/usr/local/bin` is Homebrew on Intel, and either can be absent or elsewhere (a Linux cell is
# systemd + cloud-cell-supervisor.sh and never runs this file, but an operator's own prefix can). A
# hardcoded miss exits 78 on a box where tmux IS installed — a refusal that names the wrong cause.
TMUX_BIN="${TMUX_BIN:-}"
if [ -z "$TMUX_BIN" ]; then
  for _c in "$(command -v tmux 2>/dev/null)" /opt/homebrew/bin/tmux /usr/local/bin/tmux; do
    if [ -n "$_c" ] && [ -x "$_c" ]; then TMUX_BIN="$_c"; break; fi
  done
fi
[ -n "$TMUX_BIN" ] && [ -x "$TMUX_BIN" ] \
  || { echo "launchd-controller: tmux not found (looked on PATH, /opt/homebrew/bin, /usr/local/bin) — set TMUX_BIN" >&2; exit 78; }

# ⛔ THE PANE MUST CARRY THIS JOB'S ENVIRONMENT, AND IT DOES NOT INHERIT IT (measured 2026-10-18,
# tmux 3.8 on this Mac). tmux gives a NEW session the SERVER's environment, not the client's: a
# variable present only in the creating client does not cross (A/B on an isolated socket whose server
# was born without it — `new-session 'env > f'` records nothing for it). So when the tmux server was
# born from an operator's terminal — the normal case on a box whose lanes are attached by hand — the
# controller pane starts with NO REPO. orch-loop.sh refuses that by design (`FATAL REPO is not set`,
# exit 78), the session dies, the wait loop below exits and KeepAlive restarts the job: a silent ~15s
# restart loop that reads exactly like an idle box, which is the failure class this file exists to end.
# `new-session -e VAR=value` is the direct fix but needs tmux >= 3.2, so the environment is passed ON
# THE COMMAND LINE instead — portable, and it works on an older tmux too. The list is the set the
# plist renders that orch-loop and its children consume; anything unset in this job is skipped, and
# every value is POSIX-quoted for the `sh -c` string tmux runs (never bare — a path with a space
# would split).
CONTROLLER_ENV="PATH HOME OR REPO O SCOPE MAX_LOAD MAX_LANES MAX_REVIEW MERGE_PRIORITY_AT \
MAX_FIX MAX_FIX_TRIES MIN_SWAP_FREE MIN_MEM_FREE_MB BATCH CYC"
# shq — POSIX single-quote a word for the `sh -c` string tmux runs. The implementation is the TWIN of
# orch-loop.sh's shq() and must stay identical: bash's `printf %q` emits `$'…'` for non-printable
# bytes, and `$'…'` is NOT a quoting form in POSIX sh — on a Debian cell that quoting is LOST and the
# remainder re-parsed as commands (#1988's class). `'\''` escaping is POSIX for every byte.
_shq() { local s="${1:-}" q="'"; printf "'%s'" "${s//$q/$q\\$q$q}"; }
ENV_PREFIX=""
for _v in $CONTROLLER_ENV; do
  eval "_val=\${$_v-}"
  [ -n "$_val" ] || continue
  ENV_PREFIX="$ENV_PREFIX $_v=$(_shq "$_val")"
  unset _val
done

# ⛔ `-A` IS NOT AN IDEMPOTENT NO-OP ON A LIVE SESSION, AND THIS FILE MUST NOT BE BUILT AS IF IT WERE
# (measured 2026-10-18, tmux 3.8, this Mac). With no terminal on stdin — every launchd job —
# `new-session -A -d` on an EXISTING session tries to ATTACH, fails, and exits 1:
#     fresh session  -> rc=0
#     same command, session already present -> rc=1, "open terminal failed: not a terminal"
# So `-A ... || exit $?` turned every restart into an immediate failure: launchd KeepAlive relaunched
# the job every ~10s forever (`install.sh --restart` reported "it starts and dies" while the previous
# controller kept running happily), and `launchd-cycle.sh`'s stability assertion then declared a
# healthy box a crash loop. `-A -D` and attaching are not options here — there is no terminal.
#
# THE SESSION IS THEREFORE REPLACED EXPLICITLY, which also restores the pre-entrypoint invariant that
# a job (re)start yields a controller running with THIS job's environment. Without it, a restart could
# not apply a changed MAX_LANES/MAX_LOAD: the old pane would keep the old env forever. Killing is safe
# by design — `tmux kill-session` SIGHUPs the pane, orch-loop.sh dies, and its `.orch.lock` is released
# by the EXIT trap (and reclaimed from a dead pid by acq() if the signal won the race). The wait loop
# makes the replacement ordered rather than racy: without it the new controller can start while the
# old lock pid is still alive and exit 0 with `already running`.
if "$TMUX_BIN" has-session -t "=$S" 2>/dev/null; then
  echo "launchd-controller: replacing the existing '$S' session so the controller runs with THIS job's environment" >&2
  "$TMUX_BIN" kill-session -t "=$S" 2>/dev/null
  _n=0
  while "$TMUX_BIN" has-session -t "=$S" 2>/dev/null && [ "$_n" -lt 50 ]; do sleep 0.2; _n=$((_n + 1)); done
fi

# /usr/bin/env is absolute: the pane's shell resolves it BEFORE the forwarded PATH is in effect.
"$TMUX_BIN" new-session -d -s "$S" \
  "exec /usr/bin/env$ENV_PREFIX /bin/bash $(_shq "$O/orch-loop.sh")" || exit $?
# ⛔ A CREATE THAT "SUCCEEDED" IS NOT A CONTROLLER — AND `has-session` IMMEDIATELY AFTER IS VACUOUS
# (review round 2, measured on tmux 3.8, isolated socket). tmux tears a dead pane's session down a beat
# later, not synchronously: `new-session -d -s S "exec /bin/bash -c 'exit 7'"` returns 0 and
# `has-session -t =S` is TRUE right after — FALSE ~300ms later. So a single immediate check proves
# nothing and `exit 69` would be unreachable, which is the "looks like an idle box" failure this file
# exists to end. Settle first, then require the session to still be there.
_ok=0
for _n in 1 2 3 4 5 6 7 8 9 10; do
  sleep 0.2
  "$TMUX_BIN" has-session -t "=$S" 2>/dev/null || { echo "launchd-controller: '$S' died within $((_n * 2))00ms of starting — see the pane output above" >&2; exit 69; }
  [ "$_n" -ge 5 ] && { _ok=1; break; }
done
[ "$_ok" -eq 1 ] \
  || { echo "launchd-controller: '$S' did not come up — see the pane output above" >&2; exit 69; }

# Block while the controller's session lives, so KeepAlive gives real supervision: when the
# controller exits, this script exits, and launchd starts a fresh one. Without the block the job
# would exit immediately after creating the session and KeepAlive would spin.
_STARTED="$(date +%s)"
while "$TMUX_BIN" has-session -t "=$S" 2>/dev/null; do sleep 5; done
_LIVED=$(( $(date +%s) - _STARTED ))
# ⛔ SAY HOW LONG IT RAN (review round 2). Exiting 0 after a controller that died in two seconds is
# indistinguishable in launchd.err from an idle box; the lifetime is the one datum that separates them.
# It stays exit 0 because a controller that exits AT ONCE is a legitimate state — orch-loop.sh exits 0
# when another controller holds `.orch.lock` — so this is a diagnostic, not a verdict.

# Floor the restart rate. orch-loop.sh exits 0 at once when another controller holds the lock
# (a peer in the FDA lineage, or a leftover). launchd already throttles KeepAlive to 10s; this
# keeps the log honest instead of printing a start line every throttle window.
echo "launchd-controller: the '$S' session ran for ${_LIVED}s and ended (exit 0)" >&2
sleep 15
exit 0
