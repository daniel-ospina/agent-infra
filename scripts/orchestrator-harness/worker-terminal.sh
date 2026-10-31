#!/usr/bin/env bash
# worker-terminal.sh — the ONE place that LAUNCHES a worker, answers whether it is ALIVE, counts
# them, and KILLS one. Sourced by orch-loop.sh and dispatch-merge.sh.
#
# ⛔ WHY THIS FILE EXISTS — MEASURED 2026-10-20 ON ALL THREE CLOUD CELLS.
# A lane launched by the harness produced nothing: the worker log stopped after ~21 lines and the
# child transcript ended after ONE toolCall. agent-infra#2210 concluded "never a tmux window" and
# made `wt_launcher` return `tmux` on macOS ONLY — so on a Linux cell, where the guest cmux CLI cannot
# run at all, the launcher resolved to `none` and the controller refused EVERY spawn, every cycle,
# forever. agent-infra#2210 was reopened for that reason; the conclusion is corrected here.
#
# ⛔ THE ~21-LINE DEATH IS AN ENVIRONMENT FAILURE, NOT A TMUX ONE — MEASURED 2026-10-22, cell-1.
# The mechanism is #2210's own follow-up evidence read correctly: `gh`'s credential is HOME-BOUND
# (`$HOME/.config/gh/hosts.yml`), and a tmux spawn inherits the SERVER's environment — whatever shell
# happened to create that server. The pre-fix arm `tmux new-session -d -s X 'cd CWD && CMD'` therefore
# got, against one bare server (`env -i HOME=/home/cmux`, no keys):
#     7 lines, `gh auth status` rc=1, `You are not logged into any GitHub hosts`  → stops.
# The SAME server, same box, with `export HOME=/tmp/cell-home; . $HOME/keys.env` in the launch line:
#     50 lines, `gh auth status` rc=0 (account daniel-ospina), `SURVIVED` past 21 lines.
# And every lane alive on that box carried the prefix by hand (33 min, 31 min, 24 min …), which is why
# the death reproduced for the controller and never for an operator. So the fix is the ENVIRONMENT
# CONTRACT (see `wt_launcher_env`), not the launcher choice: a durable terminal is still preferred
# wherever the daemon answers, and tmux is used wherever it does not — with credentials, or not at all.
#
# The durable terminal remains the PREFERRED surface where the cmux daemon answers: its process tree
# hangs off the daemon (`__terminal-host`, ppid = the daemon), and `cmux vm terminal wait-exit` reports
# `pending` while it runs. That is a better surface; it is not the only workable one.
#
# ⛔ WHICH CMUX VERB, AND WHY IT IS NOT LITERALLY `surface new-terminal`. That spelling exists on the
# Mac's host CLI; the CLI that ships INSIDE a cloud cell does not have it (`cmux surface ls` →
# `cmux: unknown resource scope "surface"`, measured on cell-3 with cmux 0.1.0). What the guest CLI
# does have is `cmux layout apply`, and its own help draws the equivalence: "Terminal surfaces are
# login shells in their cwd (+ env); `command` is typed into them." A one-surface layout therefore
# produces the same artifact `surface new-terminal --cwd <dir> --no-open -- <cmd>` produces: a
# daemon-owned terminal, in that cwd, no window opened, running that command. Verified on cell-3
# before this file was written: the created terminal's tree is `__terminal-host` → a child of the
# cmux-tui SERVER (ppid = the daemon, not the caller), `cmux terminal wait-exit` says `pending`
# while it runs and `exited code=N` once the command returns, and `cmux terminal close` ends it.
# When the installed CLI DOES advertise the `surface` scope (the Mac host CLI), the exact primitive
# named above is used instead. Both branches create a durable terminal. Where NEITHER can run — the
# cmux daemon does not answer — `wt_launcher` selects tmux: on a launchd Mac AND on a cell (#2210).
# That arm, and only that arm, carries the `wt_launcher_env` contract below, because it is the one
# surface whose worker inherits a FOREIGN environment (the tmux server's).
#
# ⛔ WHY THE ENVIRONMENT IS CARRIED EXPLICITLY. A tmux worker inherited the SERVER's environment, so
# an exported O / PATH / API key reached it for free. A durable terminal's shell is a LOGIN shell
# started by the daemon: measured on cell-3 it gets HOME=/home/cmux and NONE of the controller's
# exports (no DEEPSEEK_API_KEY, no GH_TOKEN, no AGENT_INFRA_PATH, no pi shim first on PATH). So each
# spawn writes an env snapshot beside the worker record and the worker's command sources it with
# `set -a` — the same shape the cell's own `keys.env` uses, and the reason `launch-lane.sh` had to
# `set -a` at all. Without this a lane starts, finds no key, and dies in 300 bytes — indistinguishable
# from the launcher bug this file is fixing.
#
# ⛔ THE POLARITY RULE, STATED ONCE. Liveness is `alive` / `dead` / `unknown`, and UNKNOWN IS ALIVE:
# the concurrency caps must keep BINDING and a reaper must never kill what it cannot see. The other
# direction — "we could not read it, so it is dead" — silently frees every slot and lets the box
# spawn without limit exactly when the daemon is in trouble. `dead` is only ever concluded from a
# POSITIVE read: (1) the workspace is gone, (2) the session name is absent, or (3) — added
# deliberately with agent-infra#2653, see the `wt_table` absent-owner arm — the session OWNER is
# confirmed ABSENT (`Connection refused` from an empty `cmux tree`, i.e. a socket nobody is listening
# on, or the CLI's own `no server running`) and CONFIRMED BY TWO SAMPLES at least `WT_ABSENT_CONFIRM`
# (default 60s) apart — a single refusal only opens the window and keeps the caps binding, because a
# hard-killed owner leaves pty children behind. A terminal spawn proves the owner answered and closes
# the window. No owner, no terminal. That third read is a MEASUREMENT, not a guess, and it is
# deliberately narrow —
# the errno-agnostic `cannot connect to session socket <path>: <reason>` wrapper does NOT qualify
# (ENOENT / EACCES / EAGAIN are reachable with the daemon and its terminals ALIVE), so a merely
# illegible or unreachable answer still leaves its workers UNKNOWN and the caps binding.
#
# ⛔ WHAT THIS FILE DELIBERATELY DOES NOT DO. No SILENT anything: a box with no surface at all is
# refused out loud, and a tmux spawn that cannot be given an environment with a credential is refused
# out loud too (a silent credential-less worker is how the 21-line death stayed invisible). No retry
# of a FAILED operation and no queue — a failed spawn returns non-zero and lets the caller's own
# failure branch (every call site has one) record the wait. ⛔ THE ONE EXCEPTION IS NAMED, NOT SLID IN
# (agent-infra#2404): when the DURABLE SESSION ITSELF is the finding, the surface is recovered ONCE
# (`wt_cmux_session_ensure`, bounded) and the create is re-attempted ONCE — because the measured case
# left a cell unable to spawn for three days while every other lane kept cycling, and a refusal that
# repairs nothing is the outage. It never retries a failure it did not diagnose, and it never stops
# anything (see `wt_cmux_session_ensure` for why the destructive lever stays out of the spawn path).
#
# ⛔ AND IT NEVER REPORTS A CAUSE IT DID NOT MEASURE (agent-infra#2404, measured on cell-3
# 2026-11-02). `cmux layout apply` failed with `"reason":"database or disk is full"` on a box with
# 28 G free on `/`, 25 % of its inodes used and a 37 M state dir: a THREE-DAY-OLD durable session
# owner could no longer allocate a workspace, and it named the disk. The refusal used to relay that
# message verbatim as the reason — so every reader was sent to `df`, and the real state survived for
# hours. A refusal now carries the measurements it took (`wt_cmux_probe`) and says which of them the
# daemon's claim is consistent with, or that the claim is not what the readings show.

# ── small helpers ──────────────────────────────────────────────────────────────────────────────
# The shipped quoter, byte-identical to orch-loop.sh's shq() (a worker command is a shell LINE in the
# layout grammar and an argv word in the surface grammar; both need POSIX single-quote quoting).
wt_q() { local s="${1:-}" q="'"; printf "'%s'" "${s//$q/$q\\$q$q}"; }

# Where worker records live. `$O/state` is the same directory the claim/attempt records use, so an
# operator has ONE place to look; WT_DIR is a test seam, never an operator knob.
wt_dir() { printf '%s\n' "${WT_DIR:-${O:-$HOME/orchestrator}/state}"; }

# The worker-name rule, ONE definition for its two consumers: `wt_spawn`'s argument check and
# `wt_refusal_record`'s NAME COLUMN (a record must not print an identifier a spawn would refuse).
wt_name_ok() { case "${1:-}" in ''|*[!A-Za-z0-9-]*) return 1 ;; esac; return 0; }

# Say it on stderr AND in the controller's log (the controller's stdout is not read by anyone).
wt_warn() {
  printf '[worker-terminal] %s\n' "$*" >&2
  if [ -n "${LOG:-}" ]; then printf '[worker-terminal] %s\n' "$*" >> "$LOG" 2>/dev/null || true; fi
  # ⛔ A REFUSAL IS A MEASUREMENT, NOT ONLY A LOG LINE (measured 2026-10-22 on a cloud cell).
  # The cmux registry's own volume reached 100% (`database or disk is full`), so EVERY `wt_spawn`
  # returned 1 with that reason — 1,562 refusals in ONE controller log, and not one lane started for
  # six hours. The controller recorded each refusal as a per-PR `wait` and its cycle line still read
  # `N acted, M named wait(s)`: the reason lived in a line nobody reads and never reached the decision
  # line. Recording it HERE is what makes it reachable: this is the single point every LAUNCHER
  # refusal passes through, so a future spawn site cannot forget it. (Two earliest guards — a missing
  # argument and an unsafe worker name — are ARGUMENT errors rather than launcher refusals and are
  # deliberately not recorded: they mean the caller is broken, not that the actuator refused.)
  case "$*" in
    'REFUSED '*)
      _wt_refmsg="${*#REFUSED }"
      wt_refusal_record "${_wt_refmsg%%:*}" "${_wt_refmsg#*: }"
      ;;
  esac
  return 0
}

# ── the refusal record the CONTROLLER's summary reads ─────────────────────────────────────────────
# ONE TAB-delimited row per refused spawn: `<worker name>\t<the launcher's reason>`. The controller
# TRUNCATES it per cycle (orch-loop.sh, beside the per-PR disposition ledger) and folds the count and
# the first reason into the `[pr]` line, the `[dispatch]` tail and the DRAIN STALLED line — so
# `lanes=0` can never again be printed without the actuator's own answer beside it.
# ⛔ THE NAME COLUMN HOLDS A WORKER NAME OR NOTHING (P2 review finding, 2026-10-27, MEASURED). It was
# filled from `${reason%%:*}` — the text before the first colon of whatever `wt_warn` was handed — and
# the MODEL-CREDENTIAL gate refuses before it knows a session is being asked for, so its message reads
# `REFUSED a worker on 'deepseek': …` and the column literally held `a worker on 'deepseek'`: a
# sentence, in the column a reader (and a human scanning the TSV) reads as an IDENTIFIER. A column that
# reads as a name when it is not one is worse than a blank, because a blank is honestly unknown while
# that value looks attributable to a worker that does not exist. So the same rule that ADMITS a worker
# name in `wt_spawn` decides this column, and anything else is recorded as EMPTY.
# ⛔ BOUNDED BY CONSTRUCTION, NOT BY HOPE: at most 200 REFUSAL rows per cycle (201 lines, because
# the controller's probe row occupies one). A refusal storm is exactly the moment a growing file
# must not become the next full volume.
wt_refused_file() { printf '%s\n' "$(wt_dir)/spawn-refused.tsv"; }
wt_refusal_record() { # <name> <reason>
  local f name reason n=0
  f="$(wt_refused_file)" 2>/dev/null || return 0
  [ -n "${f:-}" ] || return 0
  name="${1:-?}"; reason="${2:-no reason given}"
  # ONE rule for a worker name (`wt_spawn`'s argument check), so the record cannot accept an identifier
  # a spawn would refuse, or print a sentence in the identifier column.
  wt_name_ok "$name" || name=""
  if [ -f "$f" ]; then
    n="$(wc -l < "$f" 2>/dev/null | tr -d ' ')"
    case "${n:-}" in ''|*[!0-9]*) n=0 ;; esac
  fi
  [ "$n" -ge 201 ] && return 0
  { printf '%s\t%s\n' "$(printf '%s' "$name" | tr -d '\t\n')" \
      "$(printf '%s' "$reason" | tr '\t\n' '  ' | cut -c1-240)" >> "$f"; } 2>/dev/null || true
  return 0
}

# `wt_bounded <secs> <cmd...>` — run a probe under a bound, because EVERY probe here can HANG.
# ⛔ WHY THIS EXISTS (P1 review finding, 2026-10-23, MEASURED). Two facts, both measured:
#   * `gh auth token` can block until the caller is killed (rc=142) on these images — the hazard
#     `scripts/harness-up` records in its own header (`NEVER gh auth token` … "`hu_bounded` is what
#     stops it hanging") and `scripts/harness-cohesion.test.sh` pins for itself;
#   * a tmux server that is REACHABLE BUT WEDGED makes `show-environment`/`ls`/`new-session` block
#     indefinitely (measured on tmux 3.4: socket listening, never answering, still blocked after
#     8s, rc=124 under `timeout`).
# This change puts both on the controller's SYNCHRONOUS spawn path — the cycle's critical path — so an
# unbounded probe there is a controller that silently stops cycling, which is #2210's own symptom in a
# new form. A bound that FIRES is a normal non-zero answer: every caller treats it as "no answer"
# (refuse the spawn, or UNKNOWN — which is ALIVE in the census), never as a pass.
# perl's `alarm` survives `exec`, which is why it is the bound and not `timeout` (absent on macOS — see
# scripts/orchestrator-harness/README.md's platform rules); `timeout` is the second choice, and the
# last resort is a plain run (declared residual: a box with neither cannot be bounded, and refusing
# every spawn there would be the refusal loop this change exists to remove).
wt_bounded() { # <secs> <cmd...>
  local s="${1:-10}"; shift || true
  # ⛔ ZERO IS NOT A BOUND (P2 review finding, 2026-10-23, MEASURED): `perl -e 'alarm 0'` and
  # `timeout 0` both mean "no alarm" — measured, `wt_bounded 0 sleep 2` returned after the full 2s. A
  # `WT_PROBE_TIMEOUT=0` written as "turn it off" (the module's own `WT_TABLE_TTL=0` disable seam invites
  # that reading) would silently disarm the probe that exists to stop the controller freezing.
  case "$s" in ''|*[!0-9]*) s=10 ;; esac
  # …and the zero test is NUMERIC, not lexical (P2 review finding, 2026-10-23, MEASURED): `00`/`000` pass
  # a `case` match on `0` and `alarm 00` is still "no alarm" (`wt_bounded 00 sleep 2` ran the full 2s).
  [ "$s" -gt 0 ] 2>/dev/null || s=10
  if command -v perl >/dev/null 2>&1; then perl -e 'alarm shift; exec @ARGV' "$s" "$@"; return $?; fi
  if command -v timeout >/dev/null 2>&1; then timeout "$s" "$@"; return $?; fi
  "$@"
}

# ── the durable SESSION's health, MEASURED — the reading a create refusal must carry ─────────────
# WHY THESE FOUR FUNCTIONS EXIST, AND WHAT THEY DELIBERATELY ARE NOT (agent-infra#2404). On a cell,
# worker spawning goes through the guest CLI (`cmux layout apply`, i.e. `workspace create`), and when
# the durable session owner can no longer allocate a workspace it fails with
# `{"code":"operation.failed","details":{"operation":"resource.runtime","reason":"database or disk
# is full"}}` — measured on cell-3 2026-11-02 while `/` had 28 G free, inodes were 25 % used and
# `~/.cmux` was 37 M. The daemon states a cause it did not check; the operator is sent to `df`; the
# cell is silently capped at the lanes it already had, for hours, while the controller's own `[cap]`
# line reads healthy. ⛔ So this is NOT a new health model: it takes only the readings the incident's
# own table took (free space, inodes, state size, the session's own status), it decides NOTHING about
# capacity or liveness (that stays with `wt_table`'s census and `wt_launcher`'s probe — #2946), and it
# never writes to the cmux CLI except the ONE idempotent `ensure` the owner's ruling names.
#
# The floor is a KNOB, because the right number is per-box: `WT_STATE_FREE_FLOOR_MB` (default 1024) and
# `WT_STATE_INODE_PCT_FLOOR` (default 95). A reading that cannot be taken is reported as UNREADABLE and
# is NEVER collapsed into "fine" — an unmeasured cause is exactly the defect this replaces.
wt_cmux_session() {
  # The durable session this box's guest CLI serves. `cloud` is the name the cells use (measured:
  # `cmux server status --session cloud`, `cannot connect to session socket
  # /tmp/cmux-tui-1000/cloud.sock`). WT_CMUX_SESSION is a fixture/operator seam, not a gate a PR can
  # flip: it changes WHICH session is described, never whether a refusal is honest.
  printf '%s\n' "${WT_CMUX_SESSION:-cloud}"
}

# The directory whose VOLUME the daemon writes its registry to. The candidates are the two shapes the
# measured boxes use (`~/.cmux` on the cells, `~/.local/state/cmux` on the macOS controller);
# WT_CMUX_STATE_DIR pins it. Prints nothing when there is no such directory — the caller must say
# UNREADABLE rather than measure `/` and call it the state volume.
wt_cmux_state_dir() {
  local d
  for d in "${WT_CMUX_STATE_DIR:-}" "${HOME:+$HOME/.cmux}" "${HOME:+$HOME/.local/state/cmux}"; do
    case "$d" in ''|/) continue ;; esac
    [ -d "$d" ] && { printf '%s\n' "$d"; return 0; }
  done
  return 1
}

# `cmux server <verb> --session <s>` — a GUEST CLI verb. ⛔ The macOS host CLI has NO `server` command
# at all (`cmux server --help` → `Error: Unknown command 'server'`, measured on the controller
# 2026-10-28), so "this CLI cannot answer that" is a DISTINCT outcome from "the session is down" —
# collapsing them would make the probe name an outage on every Mac spawn that failed for another
# reason. Four outcomes, and the two that are not readings are non-zero:
#   0 the verb answered       1 the verb answered with a failure      3 no such verb on this CLI
#   4 no answer within the bound (a wedged daemon — also NOT a reading)
wt_cmux_server() { # <verb> [args...] -> prints the answer
  local verb="${1:-}" out rc low
  [ -n "$verb" ] || return 3
  shift || true
  # BOUNDED (`wt_bounded`): an unresponsive daemon is the exact state this runs in, so an unbounded
  # `server status` would freeze the controller's synchronous spawn path — the symptom this file's
  # bound exists to prevent, in the one place it is guaranteed to be reached.
  out="$(wt_bounded "${WT_SERVER_TIMEOUT:-10}" cmux server "$verb" --session "$(wt_cmux_session)" "$@" 2>&1)"
  rc=$?
  case "$rc" in 124|137|142) printf '%s\n' "$out"; return 4 ;; esac
  low="$(printf '%s' "$out" | tr '[:upper:]' '[:lower:]')"
  case "$low" in
    *"unknown command"*|*"unknown subcommand"*|*'unknown resource scope'*) printf '%s\n' "$out"; return 3 ;;
  esac
  printf '%s\n' "$out"
  [ "$rc" -eq 0 ] && return 0
  return 1
}

# `wt_cmux_probe` — take the incident's own table, flat, and derive a VERDICT from it. Sets (no
# subshell, because the caller DECIDES on the reading):
#   WT_PROBE_VERDICT     space | owner-down | owner-running | unreadable | not-run
#   WT_PROBE_LINE        `space free=… inodes=… state=… floor=…; server status=…` — the readings, verbatim
#   WT_PROBE_SHORT       1 only when the volume was MEASURED at/below a floor (never on an unreadable)
#   WT_PROBE_OWNER       running | down | unreadable | unsupported
#   WT_PROBE_SPACE_READ / WT_PROBE_INODE_READ / WT_PROBE_SIZE_READ   1 iff THAT reading answered.
#                        Three flags, because a verdict is not a reading: `fine` says the volume is not
#                        at a floor, it does NOT say all three were taken (review round 4, finding F1).
# The verdict order is deliberate: SPACE WINS when it is short, because then the daemon's own message is
# consistent with a measurement and no recovery is worth attempting (restarting a session frees no
# space). `owner-running` is the cell-3 reading, and it is the one that must never be flattened into
# "down": the owner ANSWERED `status running` and still could not allocate — a session-owner state
# failure, not a dead process and not a full disk.
wt_cmux_probe() {
  local dir fk space_u inode_u size_kb srv srvlow floor ino_floor
  WT_PROBE_VERDICT=unreadable; WT_PROBE_SHORT=0; WT_PROBE_OWNER=unreadable; WT_PROBE_LINE=""
  WT_PROBE_SPACE_READ=0; WT_PROBE_INODE_READ=0; WT_PROBE_SIZE_READ=0
  floor="${WT_STATE_FREE_FLOOR_MB:-1024}"; case "$floor" in ''|*[!0-9]*) floor=1024 ;; esac
  ino_floor="${WT_STATE_INODE_PCT_FLOOR:-95}"; case "$ino_floor" in ''|*[!0-9]*) ino_floor=95 ;; esac

  dir="$(wt_cmux_state_dir)" || dir=""
  fk=""; inode_u=""; size_kb=""
  if [ -n "$dir" ]; then
    # `df -Pk` is POSIX and field 4 is Available on both shapes (Linux and macOS). `df -Pi` puts the
    # inode percentage LAST on macOS (capacity is the earlier `%` column) and only on the inode column
    # on Linux — so the LAST `N%` field is the inode reading on both, which is what this takes.
    fk="$(wt_bounded 5 df -Pk "$dir" 2>/dev/null | awk 'NR>1 && NF>=6 && $4 ~ /^[0-9]+$/ {print $4; exit}')"
    space_u="$(wt_bounded 5 df -Pk "$dir" 2>/dev/null | awk 'NR>1 && NF>=6 && $5 ~ /^[0-9]+%$/ {print $5; exit}')"
    inode_u="$(wt_bounded 5 df -Pi "$dir" 2>/dev/null | awk 'NR>1 {for(i=1;i<=NF;i++) if ($i ~ /^[0-9]+%$/) p=$i} END{if (p!="") print p}')"
    size_kb="$(wt_bounded 10 du -sk "$dir" 2>/dev/null | awk '{print $1; exit}')"
  fi

  WT_PROBE_OWNER=unreadable; srv=""
  if command -v cmux >/dev/null 2>&1; then
    srv="$(wt_cmux_server status 2>&1)"
    case "$?" in
      0)
        srvlow="$(printf '%s' "$srv" | tr '[:upper:]' '[:lower:]')"
        # ⛔ THE NEGATIVE SIGNATURES ARE TESTED FIRST, AND THE ORDER IS THE WHOLE POINT. POSIX `case`
        # takes the FIRST matching pattern (§2.9.4.2), and `not running` / `no server running` CONTAIN
        # `running` — so with `*running*` ahead of the down list, two of the five down signatures were
        # DEAD CODE and an owner that had just said it was not running was reported `owner-running`. The
        # refusal then called the daemon's cause FALSE and the spawn ran an `ensure` + a re-attempt on a
        # box whose owner was down: the same defect as #2404 with the polarity flipped — an instrument
        # asserting a reading it does not have (review round 1, finding 1; pinned by arm R7).
        case "$srvlow" in
          *"cannot connect"*|*"connection refused"*|*"no server"*|*"not running"*|*"stopped"*) WT_PROBE_OWNER=down ;;
          *running*) WT_PROBE_OWNER=running ;;
          *) WT_PROBE_OWNER=unreadable ;;
        esac ;;
      3) WT_PROBE_OWNER=unsupported ;;
      4) WT_PROBE_OWNER=unreadable ;;
      *)
        srvlow="$(printf '%s' "$srv" | tr '[:upper:]' '[:lower:]')"
        case "$srvlow" in
          *"cannot connect"*|*"connection refused"*|*"no server"*|*"not running"*|*"stopped"*) WT_PROBE_OWNER=down ;;
          *) WT_PROBE_OWNER=unreadable ;;
        esac ;;
    esac
  fi

  # MEASURED-SHORT ONLY. A blank `df` reading is UNREADABLE, not zero and not fine.
  case "${fk:-}" in
    ''|*[!0-9]*) : ;;
    *) WT_PROBE_SPACE_READ=1; [ "$fk" -le "$((floor * 1024))" ] && WT_PROBE_SHORT=1 ;;
  esac
  case "${inode_u:-}" in
    *%) WT_PROBE_INODE_READ=1; [ "${inode_u%\%}" -ge "$ino_floor" ] 2>/dev/null && WT_PROBE_SHORT=1 ;;
  esac
  case "${size_kb:-}" in
    ''|*[!0-9]*) : ;;
    *) WT_PROBE_SIZE_READ=1 ;;
  esac

  if [ "$WT_PROBE_SHORT" = "1" ]; then WT_PROBE_VERDICT=space
  elif [ "$WT_PROBE_OWNER" = "down" ]; then WT_PROBE_VERDICT=owner-down
  elif [ "$WT_PROBE_OWNER" = "running" ]; then WT_PROBE_VERDICT=owner-running
  else WT_PROBE_VERDICT=unreadable
  fi

  # ONE flat line, every value either MEASURED or explicitly UNREADABLE — the shape the refusal carries.
  WT_PROBE_LINE="space$( [ -n "$dir" ] && printf ' [%s]' "$dir" ) free=$( [ -n "${fk:-}" ] && printf '%sMB' "$((fk / 1024))" || printf UNREADABLE ) use=$( [ -n "${space_u:-}" ] && printf '%s' "$space_u" || printf UNREADABLE ) inodes=$( [ -n "${inode_u:-}" ] && printf '%s' "$inode_u" || printf UNREADABLE ) state=$( [ -n "${size_kb:-}" ] && printf '%sMB' "$((size_kb / 1024))" || printf UNREADABLE ) floor=${floor}MB/${ino_floor}%; server status=$( [ -n "$srv" ] && printf '%s' "$(printf '%s' "$srv" | tr '\n' ' ' | cut -c1-200)" || printf 'NOT READ (owner=%s)' "$WT_PROBE_OWNER" )"
  return 0
}

# Which of the three VOLUME readings the probe did NOT get, as one comma-joined phrase — EMPTY only
# when all three answered. ⛔ IT EXISTS BECAUSE A VERDICT IS NOT A READING (review round 4, finding F1):
# the `fine` arm used to say "free space, inodes and state size all measured" off `WT_PROBE_SPACE_READ`
# alone, while the same refusal printed `inodes=UNREADABLE` a few words earlier — this file's own defect
# class, reintroduced inside the one sentence that exists to remove it. An inode-less `df -Pi` (no `N%`
# column) or a `du -sk` that hits its bound reaches that state without any exotic condition.
wt_cmux_vol_unread() {
  local u=""
  [ "${WT_PROBE_SPACE_READ:-0}" = "1" ] || u="free space"
  [ "${WT_PROBE_INODE_READ:-0}" = "1" ] || u="${u:+$u, }inodes"
  [ "${WT_PROBE_SIZE_READ:-0}" = "1" ] || u="${u:+$u, }state size"
  printf '%s' "$u"
}

# The READING of a probe, as one sentence for a refusal. ⛔ It states what the measurements show and
# labels the daemon's own message a claim; it never repeats the daemon's cause as the reason.
wt_cmux_probe_reading() {
  # ⛔ EVERY CLAUSE IS QUALIFIED BY WHETHER THE READING EXISTS. "the volume is NOT short" is only
  # sayable when `df` answered: an unreadable space reading is reported as UNREADABLE, never as fine
  # (the daemon's own defect, one layer down).
  local sp srvowner
  srvowner="${WT_PROBE_OWNER:-unreadable}"
  case "${WT_PROBE_SPACE_READ:-0}" in
    1) if [ "${WT_PROBE_SHORT:-0}" = "1" ]; then sp=short; else sp=fine; fi ;;
    *) sp=unreadable ;;
  esac
  case "${WT_PROBE_VERDICT:-unreadable}" in
    not-run)
      # ⛔ THE OFF SWITCH TAKES NO READING, SO THE READING MUST NOT DESCRIBE ONE. Without this arm the
      # refusal printed "NEITHER the session owner nor the state volume could be READ on this box" for a
      # probe that was deliberately never run — an attempted-read claim for a read nobody attempted, in
      # the one message whose purpose is to stop exactly that (review round 1, finding 2).
      printf 'the probe was DISABLED on this box (`WT_SESSION_RECOVER=0`), so NO reading was taken here and NO cause is stated — the daemon message below is its own claim, neither confirmed nor denied' ;;
    space)
      printf 'the state volume IS at or below the floor this probe measured against (see `space …` above), so the daemon message is CONSISTENT with a measurement of this box — and no recovery is attempted, because restarting a session frees no space' ;;
    owner-down)
      # ⛔ THE SAME COMPLETENESS RULE APPLIES HERE (review round 5, finding F1). This arm was left
      # behind by the round-4 fix, and it is the arm MOST LIKELY TO FIRE: `owner-down` is the reading
      # in this PR's own cell-4 artifact. "not on the disk the daemon named" exonerates a disk the
      # probe read on free space alone, while `MEASURED` above may print `inodes=UNREADABLE`.
      if [ "$sp" = "fine" ] && [ -z "$(wt_cmux_vol_unread)" ]; then
        printf 'the durable session owner did NOT answer (`server status` carried a connection/no-server failure) and the state volume is NOT short (free space, inodes and state size all measured), so the create failed on the SESSION — not on the disk the daemon named'
      elif [ "$sp" = "fine" ]; then
        printf 'the durable session owner did NOT answer (`server status` carried a connection/no-server failure); free space is measured and NOT short, but this probe could NOT read %s (see `space …` above) — so the disk is NOT ruled out, and the SESSION is the only cause this probe actually established' "$(wt_cmux_vol_unread)"
      else
        printf 'the durable session owner did NOT answer (`server status` carried a connection/no-server failure); the state volume could NOT be read, so it is NOT ruled out — the daemon cause is unconfirmed in both directions'
      fi ;;
    owner-running)
      # ⛔ NO `short)` ARM HERE, DELIBERATELY (review #3031 round 6, finding F4). `wt_cmux_probe` gives a
      # MEASURED-SHORT volume precedence over the owner reading, so `owner-running` already implies
      # `WT_PROBE_SHORT=0` and `sp` can never be `short` on this arm: the sentence that used to live here
      # ("BOTH readings are real, and the owner is the one that needs a human") was UNREACHABLE, so a
      # reader of this ladder believed a state could be reported that no run can produce.
      case "$sp" in
        fine)
          # ⛔ FALSE CAUSE IS A VERDICT ON A COMPLETE READING, AND IT IS ONLY SAYABLE THEN (review round 4,
          # finding F1). Inode exhaustion IS a disk-full cause, so a volume read on free space alone
          # cannot exonerate the disk: the incomplete arm states what it measured and no verdict.
          if [ -z "$(wt_cmux_vol_unread)" ]; then
            printf 'the durable session owner answers `status running` and the state volume is NOT short (free space, inodes and state size all measured), so NEITHER of the causes this probe can measure is the failure — the create failed inside the SESSION OWNER, which is the one candidate left; the disk-full wording in the daemon message is a FALSE CAUSE'
          else
            printf 'the durable session owner answers `status running` and the state volume is NOT short on free space, but this probe could NOT read %s (see `space …` above) — so the disk is NOT ruled out, no FALSE-CAUSE verdict is stated, and the one thing measured is that the owner answered and still could not allocate a workspace' "$(wt_cmux_vol_unread)"
          fi ;;
        *)     printf 'the durable session owner answers `status running` yet could not allocate a workspace; the state volume could NOT be read, so the disk is not ruled out' ;;
      esac ;;
    *)
      if [ "$srvowner" = "unsupported" ]; then
        if [ "$sp" = "fine" ]; then
          if [ -z "$(wt_cmux_vol_unread)" ]; then
            printf 'this CLI has NO `server` verb (`cmux server --help` answers Unknown command), so the session was NOT probed and nothing here claims to have read it; the volume readings above ARE this box, and none of them is at a floor — so no cause is established, and the daemon one is not repeated'
          else
            printf 'this CLI has NO `server` verb (`cmux server --help` answers Unknown command), so the session was NOT probed and nothing here claims to have read it; the volume readings above ARE this box, though %s could not be read — so no cause is established, and the daemon one is not repeated' "$(wt_cmux_vol_unread)"
          fi
        else
          printf 'this CLI has NO `server` verb, so the session was NOT probed, and the state volume could not be read either — NO cause is established here, and the daemon one is not repeated'
        fi
      elif [ "$sp" = "fine" ]; then
        if [ -z "$(wt_cmux_vol_unread)" ]; then
          printf 'the session owner did not answer within the bound or answered something this probe cannot read, while the state volume is NOT short (free space, inodes and state size all measured) — so the daemon cause is NOT supported by any reading taken here'
        else
          printf 'the session owner did not answer within the bound or answered something this probe cannot read; free space is measured and NOT short, but %s could not be read — so the daemon cause is NOT supported by the readings taken, and it is not ruled out either' "$(wt_cmux_vol_unread)"
        fi
      else
        printf 'NEITHER the session owner nor the state volume could be READ on this box, so this probe confirms NO cause — it does not repeat the daemon one either'
      fi ;;
  esac
  return 0
}

# `wt_cmux_session_ensure` — ask the durable session to become READY, bounded, at most
# WT_SERVER_ENSURE_ATTEMPTS (default 2, because the measured flake on cell-3 was "failed once and
# succeeded on retry"). 0 = it answered, 1 = still failing, 3 = this CLI has no `server` verb.
# ⛔ IT NEVER STOPS ANYTHING, AND THAT IS A DECISION, NOT AN OVERSIGHT. The lever that CLEARED the
# recorded bad state was `server stop --session cloud --force` followed by `ensure` — and a terminal
# lives INSIDE the session owner (this file's own census says so), so stopping it ends every live lane
# on the box. The owner's repair-forward ruling covers a box that went DOWN (the next cycle repairs it);
# it does not license a spawn path to kill another lane's work to make its own spawn succeed. `ensure`
# is idempotent by its own name: on a healthy owner it changes nothing, on an absent one it starts it.
# The residual is stated in every refusal this recovery could not clear.
wt_cmux_session_ensure() {
  local i n out rc
  i=0; n="${WT_SERVER_ENSURE_ATTEMPTS:-2}"; case "$n" in ''|*[!0-9]*|0) n=2 ;; esac
  WT_ENSURE_TRIES=0; WT_ENSURE_SEEN=""
  while [ "$i" -lt "$n" ]; do
    i=$((i + 1)); WT_ENSURE_TRIES=$i
    out="$(wt_cmux_server ensure 2>&1)"; rc=$?
    WT_ENSURE_SEEN="$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)"
    [ "$rc" -eq 0 ] && return 0
    [ "$rc" -eq 3 ] && return 3
    [ "$i" -lt "$n" ] && sleep "${WT_SERVER_ENSURE_SLEEP:-2}"
  done
  return 1
}

# ── which launcher this surface gets ──────────────────────────────────────────────────────────
# `terminal` — a cmux surface where the DAEMON answers (a Mac process started inside cmux, or a cell
#              whose guest CLI can run). PREFERRED everywhere it answers.
# `tmux`     — no reachable cmux daemon, but tmux exists. TWO surfaces, and BOTH are correct:
#              the launchd MAC controller (from launchd the cmux CLI is unusable by design — "Access
#              denied - only processes started inside cmux can connect", recorded in
#              tools/fleet/lane_liveness.py), and a LINUX CELL, where the guest CLI cannot run at all
#              (measured: `cmux: cmux-tui daemon binary not found at /root/.cmux/bin/cmux-tui`, its
#              `cmux-tui` symlink dangling, no daemon process — agent-infra#2368). On a cell this is
#              the ONLY surface that can start a worker, and refusing it started nothing forever.
# `none`     — no surface at all: no cmux answer AND no tmux binary. REFUSED, loudly, per spawn. That
#              refusal is protective and stays: there is genuinely nothing to run a worker in.
# ⛔ WHAT MADE `tmux` WRONG ON A LINUX CELL WAS NEVER TMUX (see this file's header, measured
# 2026-10-22): it was that the arm passed NO ENVIRONMENT, so the worker inherited the tmux server's
# and, with `HOME` never set to the cell home, had no `gh` credential and stopped at its first call.
# The arm now carries the contract explicitly — `wt_launcher_env` — and REFUSES when it cannot.
# ⛔ NO ENV OVERRIDE FOR THE LAUNCHER ITSELF. The launcher is a fact about the surface, read from the
# surface; a gate a PR or an agent can defeat with an export is not a gate. (`WT_WORKER_HOME` is not
# a launcher override — it names which HOME holds a worker's credentials, an input to the env
# contract below.) Tests choose a surface by stubbing PATH: `cmux` and `tmux` are the inputs, and
# `wt_forget` re-probes within one shell.
wt_launcher() {
  if command -v cmux >/dev/null 2>&1 && cmux tree --json >/dev/null 2>&1; then
    WT_LAUNCHER=terminal
  elif command -v tmux >/dev/null 2>&1; then
    WT_LAUNCHER=tmux
  else
    WT_LAUNCHER=none
  fi
  printf '%s\n' "$WT_LAUNCHER"
}

# ── the environment contract a tmux worker MUST get ──────────────────────────────────────────
# `gh`'s credential is HOME-BOUND: it reads `$HOME/.config/gh/hosts.yml`. A tmux worker inherits the
# SERVER's environment, so with no explicit HOME it gets whatever HOME that server was created with —
# `/home/cmux` on a cell that keeps its credential in `/tmp/cell-home` — and its first `gh` call prints
# `You are not logged into any GitHub hosts` before the lane has done anything. That is what "dies at
# ~21 log lines" looks like from outside (measured 2026-10-22: 7 lines with no env, 50 lines with it,
# same box, same bare server — see the header).
#
# `wt_gh_hosts <home>` — the `gh` credential file for that HOME. ⛔ NOT a bare `$HOME/.config/gh`
# (review finding on this diff): `gh` resolves its config dir as `GH_CONFIG_DIR`, then
# `${XDG_CONFIG_HOME}/gh`, then `$HOME/.config/gh`, so a box that repoints its config is AUTHENTICATED
# while a one-location probe says otherwise — and the refusal that follows is terminal (no session is
# started, so nothing can ever change the answer: refused every cycle, forever).
wt_gh_hosts() {
  local home="${1:-}"
  if [ -n "${GH_CONFIG_DIR:-}" ]; then printf '%s\n' "$GH_CONFIG_DIR/hosts.yml"
  elif [ -n "${XDG_CONFIG_HOME:-}" ]; then printf '%s\n' "$XDG_CONFIG_HOME/gh/hosts.yml"
  else printf '%s\n' "$home/.config/gh/hosts.yml"; fi
}

# The `oauth_token:` VALUE pattern, ONE definition for every consumer (the no-gh fallback probe, the
# runtime guard in the launch line, and `wt_gh_hosts_value`). Group excludes the quote characters and
# `#`, because `oauth_token: ""` is empty and `oauth_token:   # redacted` is a YAML NULL — neither is a
# token (measured: gh itself answers `no oauth token found for github.com` for both).
WT_OAUTH_TOKEN_RX='^[[:space:]]*oauth_token:[[:space:]]*["'"'"']?[^[:space:]#"'"'"']'

# `wt_gh_hosts_value <file>` — the FALLBACK probe, for a box with no `gh` on PATH: 0 iff that file is a
# regular file carrying a non-empty `oauth_token:` VALUE. Kept as its own function so it is testable on
# its own (a spawn-level test cannot reach it on a box that HAS gh — `wt_gh_hosts_token` takes the gh
# arm first, so the regex would be unpinned there).
wt_gh_hosts_value() {
  local f="${1:-}"
  [ -n "$f" ] && [ -f "$f" ] || return 1
  grep -qE "$WT_OAUTH_TOKEN_RX" "$f" 2>/dev/null
}

# `wt_gh_hosts_token <home>` — 0 iff `gh` ITSELF can produce a token for that HOME.
# ⛔ ASK gh, DO NOT GREP THE FILE (P1 review finding, 2026-10-23, measured). gh's DEFAULT store is the
# system credential store (keychain / secret service), and in that mode gh **removes the plaintext
# `oauth_token:` from `hosts.yml`** — so a file grep refuses a FULLY PROVISIONED box on every spawn,
# forever: `wt_launcher_env` returns 1, and because a refusal starts no session nothing can ever change
# the answer. That is #2210's own loop, re-created one predicate over, and it would have applied to the
# macOS launchd arm that this PR newly gates. `gh auth token` is an OFFLINE lookup over whichever store
# gh resolves (hosts.yml or the keyring), which is the same store the WORKER's gh will read — the shape
# `refresh-candidates.sh` already uses for exactly this question. GH_TOKEN/GITHUB_TOKEN are cleared so
# this probe answers "what does THIS HOME hold?": the caller's own environment token is credited
# separately below, and crediting it here would bless a worker that never inherits it (a session
# against an already-running server).
# Residual (filed, #2435): the probe is host-agnostic — a GHES-only `hosts.yml` answers for a lane that
# will talk to github.com. Deliberate polarity: a wrong refusal here stops the whole cell, so this probe
# over-credits rather than over-blocks. Residual: an EXPIRED token is still a token — expiry cannot be
# read offline and is not this probe's question.
wt_gh_hosts_token() {
  local home="${1:-}"
  [ -n "$home" ] || return 1
  wt_gh_token "$home" >/dev/null && return 0
  # ⛔ NO gh (or no BOUNDED gh — see `wt_gh_token`): ask the FILE the worker's gh would read. The two
  # predicates must agree with the runtime guard in the launch line, or a credit this probe granted is
  # revoked one layer down (see the guard's own note).
  wt_gh_hosts_value "$(wt_gh_hosts "$home")"
}

# `wt_gh_token <home>` — gh's OWN answer for that HOME, printed on stdout; 0 iff it carries a non-space
# value. ⛔ BOUNDED (recorded rule, README §"Two platform rules are enforced by the suite"): a plain
# `gh auth token` can hang for the life of the shell (rc=142 measured), and `wt_spawn` runs on the
# controller's SINGLE-THREADED cycle — a hung probe freezes the cycle (no heartbeat, no census, no
# dispatch), a worse failure than the credential-less lane this gate refuses. `timeout`/`gtimeout` are
# absent on macOS, so the bound is perl's alarm, the README's own bound. With no perl there is no bound
# to give, so this returns 1 and the FILE predicate answers instead — never an unbounded call on the hot
# path. Residual: a box with no perl AND keyring-only auth falls back to the file test; macOS ships perl
# and `gh`, so that shape is a container edge, and it is a REFUSAL, not a silent dead lane.
# ⛔ gh's own OUTPUT is held to the same rule as every other arm (review finding, 2026-10-23, measured):
# `oauth_token: "   "` made `gh auth token` print three spaces and exit 0, so the gh arm credited a file
# its own file-arm refuses, and the worker's gh rejected the value at the first call.
wt_gh_token() {
  local home="${1:-}" tok
  [ -n "$home" ] || return 1
  command -v gh >/dev/null 2>&1 || return 1
  # ONE bound implementation for the whole module (`wt_bounded`): this call used to carry its own
  # inline `perl -e 'alarm 10'` and to REFUSE outright when perl was absent, which left a box with
  # `timeout` but no perl on the file-probe fallback for no reason — and duplicated the one thing a
  # bound must never be (two definitions of "did it answer in time").
  tok="$(wt_bounded "${WT_PROBE_TIMEOUT:-10}" env -u GH_TOKEN -u GITHUB_TOKEN HOME="$home" gh auth token 2>/dev/null)" || return 1
  case "$tok" in *[![:space:]]*) printf '%s' "$tok"; return 0 ;; esac
  return 1
}

# `_wt_exported <name>` — 0 iff that shell variable carries the EXPORT attribute. Only exported names
# cross into a tmux client's environment, so only those may be credited as "the caller's credential".
_wt_exported() {
  case "$(export -p 2>/dev/null)" in *" $1="*) return 0 ;; esac
  return 1
}

# `wt_keys_credit <keys.env>` — 0 iff the file ASSIGNS a token-looking value to GH_TOKEN/GITHUB_TOKEN.
# ONE predicate for its two consumers (`wt_launcher_home`'s SELECTION and `wt_launcher_env`'s credit),
# so the HOME that is chosen and the HOME that is accepted cannot disagree (review finding, 2026-10-23):
# selection used the gh-store probe only, so a HOME provisioned by its own keys.env — the shape this
# file's header measures as the working manual dispatch — was never a candidate and the spawn was
# refused on a box that had a credential. A static match is a CLAIM only; the launch line re-verifies
# the credit dynamically after the source (see `wt_launcher_env`).
wt_keys_credit() {
  local keys="${1:-}"
  [ -n "$keys" ] && [ -f "$keys" ] || return 1
  grep -qE '^[[:space:]]*(export[[:space:]]+)?(GH_TOKEN|GITHUB_TOKEN)=["'\'']?[^[:space:]"'\'']' "$keys" 2>/dev/null
}

# ── THE MODEL CREDENTIAL: DELIVER IT, OR REFUSE — NEVER START A LANE THAT CANNOT AUTHENTICATE ────
# ⛔ THE MEASURED DEFECT (2026-10-27). Every review and fixer worker on the Mac died 2-10 seconds after
# it started, with pi's own words in its own log:
#
#     [agent] provider=deepseek model=deepseek-flash
#     No API key found for deepseek.
#     [timeout] agent pid=… wall_limit=1800s elapsed=6s rc=1
#     [merge 10021] verdict: <none>
#
# 69 lane logs carried that line (56 `merge`, 11 `fix`, 2 `lane`); the last CLEAN reviewer verdict was
# 2026-10-25T22:5x and `state/merged-*.done` stops 2026-10-24 — while the controller kept producing
# review work the whole time (measured in its own log: `#10201 re-record`, `#10202 re-record`, … six in
# ONE pass). So the reviews were ORDERED and none could RUN. Each death was then booked as an attempt
# and, at `MAX_REVIEW_TRIES`, PARKED the PR with "the reviewer produced NO usable verdict … fix the
# reviewer's budget/cap (REVIEW_TIMEOUT) or its output format" — a diagnosis naming the REVIEWER for a
# fault in the worker's ENVIRONMENT, on a head nothing had reviewed. That park is what turned a
# 10-second credential fault into 26 open PRs waiting for a human.
# ⛔ THE CREDENTIAL WAS NEVER MISSING FROM THE BOX. `~/pi-keys.env` (mode 0600, sourced by `~/.zshrc`)
# carries a valid, funded provider key (checked against the provider's own balance endpoint). It was
# missing from the WORKER: this function sources only `$HOME/keys.env` (absent on this box) and the tmux
# SERVER's environment carries no provider key at all (measured: a bare pane's `env` holds ZERO
# `*_API_KEY`/`*_TOKEN` names), so nothing delivered it.
# ⛔ SO THIS IS THE SAME DEFECT THE gh GUARD BELOW ALREADY REFUSES, ONE VARIABLE OVER — and it was left
# ungated, so a spawn reported "provisioned" for a lane that could not make a single model call. An
# instrument that holds the datum (models.json names the variable) and does not read it is category A.
# ⛔ THE POLARITY: DELIVERY FIRST, AND AN UNREADABLE DATUM NEVER REFUSES. Refusal requires the required
# env NAME to be POSITIVELY known AND its value POSITIVELY absent from every source. A missing or
# unreadable `models.json`, a provider whose `apiKey` is a literal, and a provider pi authenticates
# from its own auth store all leave `wt_provider_key_var` EMPTY — and an empty answer refuses nothing.
# That asymmetry is deliberate (#2210's lesson): our own inability to read a datum must never become a
# refusal loop that stops the fleet.
#
# `wt_provider_key_var <home> [<provider>]` — the env var the lane provider's apiKey resolves from.
# Empty when we cannot say, which is the "do not refuse" answer above. The optional provider lets a
# caller that has ALREADY resolved the pair (`wt_launcher_env`) hand it in, so the pair is measured
# ONCE per spawn instead of three times (each measurement SOURCES the box's env files — see below).
wt_provider_key_var() {
  local home="${1:-}" mj prov="${2:-}"
  [ -n "$home" ] || return 0
  mj="$home/.pi/agent/models.json"
  [ -r "$mj" ] || return 0
  [ -n "$prov" ] || prov="$(wt_lane_provider "$home")"
  command -v python3 >/dev/null 2>&1 || return 0
  # A literal apiKey, a provider absent from the file, and an unparseable file all print NOTHING.
  # ⛔ BOUNDED, like every other probe on this path (P1 review finding, 2026-10-27, MEASURED): this
  # runs on the controller's SYNCHRONOUS spawn path, so an unbounded python3 there is a controller that
  # can stop cycling (see `wt_bounded`). A fired bound prints nothing, which is the gate's own "cannot
  # say" answer — the same fail-safe direction as an unreadable models.json, never a refusal.
  wt_bounded "${WT_PROBE_TIMEOUT:-15}" python3 - "$mj" "$prov" <<'PY' 2>/dev/null
import json, re, sys
prov = sys.argv[2]
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    raise SystemExit(0)
p = (d.get("providers") or {}).get(prov) or {}
k = p.get("apiKey")
if not isinstance(k, str):
    raise SystemExit(0)
m = re.fullmatch(r"\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?", k.strip())
if m:
    print(m.group(1))
PY
}
# `wt_lane_provider [<home>]` — the provider the lanes run on, resolved so the gate and the LANE cannot
# disagree (`lane-exec.sh`, `spawn-gate.sh::run_agent` and `merge-one.sh` each resolve
# `${PI_LANE_PROVIDER:-deepseek}` INSIDE the pane; this is the same default on the caller side).
# ⛔ THE PANE IS AUTHORITATIVE, AND THE CALLER USED TO THINK OTHERWISE (P3b review finding, 2026-10-27).
# The gate read the CALLER's `PI_LANE_PROVIDER` while the lane reads it in the PANE — and the pane's
# value is the `keys.env` this launch line sources under `set -a` (the box's channel for `PI_LANE_*`:
# `cloud-cell-supervisor.sh` measures that an ambient shell value does NOT reach the tmux sessions, and
# reports the env file as the governing channel). So a `keys.env` naming another provider had the gate
# checking one provider's credential while the lane ran — and billed — another.
# The pane is authoritative because it is the process that spends the credential; so the gate resolves
# THAT answer, and `wt_launcher_env` then PINS it into the launch line, which is what makes agreement
# hold even against a stale server environment. The file is measured, not grepped, exactly as
# `cloud-cell-supervisor.sh` measures the pair (a static match is a claim about the file, not about the
# environment the source produces).
# ⛔ THE PAIR IS RESOLVED TOGETHER, AND `pi-keys.env` COUNTS (P2 review finding, 2026-10-27, MEASURED).
# The resolution used to read `keys.env` ONLY, while the launch line also sources `$home/pi-keys.env` —
# and on a Mac `pi-keys.env` is the only env file there is. Measured: `pi-keys.env` carrying
# `PI_LANE_PROVIDER=zai` + `PI_LANE_MODEL=qwen3.8-max` gave `gate resolves [deepseek]` and a pane whose
# pair was `provider=[deepseek] model=[qwen3.8-max]` — the provider PINNED to the value the gate checked
# and the model left as the file wrote it, i.e. a HALF-PINNED PAIR: two members of one decision, from two
# different measurements. So both members are measured from BOTH files, in the ORDER THE LAUNCH LINE
# SOURCES THEM (`keys.env`, then `pi-keys.env`), last non-blank value wins — which is exactly what the
# pane holds after both sources — and the model is resolved here too, for the pin.
# ⛔ AND IT IS BOUNDED (P1 review finding, 2026-10-27, MEASURED: 10.28 s vs 0.06 s). Sourcing a file
# EXECUTES it, and this runs on the controller's SYNCHRONOUS spawn path, so a `keys.env` that sleeps or
# blocks froze the controller's cycle — the same freeze `wt_bounded` exists to prevent for every other
# probe here. A fired bound resolves as "this file did not answer", i.e. it contributes nothing.
# Emits TWO lines: the provider, then the model (which may be empty).
wt_lane_pair() { # [<home>] -> "<provider>\n<model>"
  local home="${1:-}" f v pv mv prov="" model=""
  for f in "$home/keys.env" "$home/pi-keys.env"; do
    [ -n "$home" ] && [ -f "$f" ] || continue
    v="$(wt_bounded "${WT_PROBE_TIMEOUT:-15}" env -u PI_LANE_PROVIDER -u PI_LANE_MODEL bash -c '
          set -a; . "$1" >/dev/null 2>&1
          printf "P=%s\nM=%s\n" "${PI_LANE_PROVIDER:-}" "${PI_LANE_MODEL:-}"' _ "$f" 2>/dev/null)" || v=""
    pv="$(printf '%s\n' "$v" | sed -n '1s/^P=//p')"
    mv="$(printf '%s\n' "$v" | sed -n '2s/^M=//p')"
    case "$pv" in *[![:space:]]*) prov="$pv" ;; esac
    case "$mv" in *[![:space:]]*) model="$mv" ;; esac
  done
  [ -n "$prov" ] || prov="${PI_LANE_PROVIDER:-deepseek}"
  [ -n "$model" ] || model="${PI_LANE_MODEL:-}"
  printf '%s\n%s\n' "$prov" "$model"
}
# `wt_lane_provider [<home>]` — the provider half of that pair, for the callers that need only it.
# (`wt_lane_pair` is the whole answer: the model half must be read from the SAME measurement, or the
# pair is assembled from two — which is the defect this replaced.)
wt_lane_provider() {
  wt_lane_pair "${1:-}" | sed -n '1p'
}
# `wt_provider_credit <VARNAME> <file>` — 0 iff the file ASSIGNS a non-blank value to that variable.
# A static match is a CLAIM; the launch line re-verifies the delivery dynamically after the source
# (`wt_launcher_env`'s provider guard), exactly as it does for GH — the same reason, measured there.
wt_provider_credit() {
  local v="${1:-}" f="${2:-}"
  case "$v" in ''|*[!A-Za-z0-9_]*) return 1 ;; esac
  [ -n "$f" ] && [ -f "$f" ] || return 1
  grep -qE "^[[:space:]]*(export[[:space:]]+)?${v}=[\"']?[^[:space:]\"']" "$f" 2>/dev/null
}
# `wt_env_nonblank <VARNAME>` — 0 iff the CALLER's environment holds a non-blank value. Indirect (the
# name comes from the provider's config), so the name is validated before it is expanded.
wt_env_nonblank() {
  local v="${1:-}" val
  case "$v" in ''|*[!A-Za-z0-9_]*) return 1 ;; esac
  eval "val=\${$v:-}" 2>/dev/null || val=""
  case "$val" in *[![:space:]]*) return 0 ;; esac
  return 1
}
# `wt_launcher_home` — the HOME to export. An explicit `WT_WORKER_HOME` WINS outright (it is the
# operator saying "the credential is HERE"; silently falling through would make the knob a suggestion).
# Otherwise: the caller's own HOME, then the cell home — each only when it actually HOLDS a credential,
# either a `gh` store that answers (`wt_gh_hosts_token`) OR its own `keys.env` carrying a token value
# (`wt_keys_credit`). If none does (a box authenticating from `GH_TOKEN` in the environment), the
# caller's HOME is used anyway and `wt_launcher_env` decides. Returns 1 only when there is no HOME at
# all to export, which is a spawn this file cannot make safely.
wt_launcher_home() {
  local c
  [ -n "${WT_WORKER_HOME:-}" ] && { printf '%s\n' "$WT_WORKER_HOME"; return 0; }
  for c in "${HOME:-}" /tmp/cell-home; do
    [ -n "$c" ] || continue
    { wt_gh_hosts_token "$c" || wt_keys_credit "$c/keys.env"; } && { printf '%s\n' "$c"; return 0; }
  done
  [ -n "${HOME:-}" ] && { printf '%s\n' "$HOME"; return 0; }
  return 1
}

# `wt_tmux_server_token` — 0 when the tmux SERVER's global environment carries a token VARIABLE with a
# VALUE. This is the only credential a worker against an ALREADY-RUNNING server can inherit (see
# `wt_launcher_env`), so it is probed for both names, and an empty value is not provision.
# ⛔ A BLANK VALUE IS NOT A VALUE, on every arm (review finding, 2026-10-23, measured): `-n "$v"` credited
# three spaces, and `gh auth status` answers `Failed to log in to github.com using token (GH_TOKEN)` for
# that value — the same defect the keys.env arm refuses statically. Every arm of this gate now applies
# one rule: a credential is a value containing a non-space character.
wt_tmux_server_token() { wt_tmux_server_token_value >/dev/null 2>&1; }

# `wt_tmux_server_token_value` — the VALUE, when the server's global environment carries one (the
# predicate above is this question with the answer thrown away). `wt_spawn` needs the value, not just
# the verdict: on the server-token arm the launch line neither exports a token nor reads a file for it
# — the pane inherits it from the SERVER — so the caller-side pre-flight of the launch line has to be
# given what the pane would inherit, or it would judge an arm it cannot see (`wt_spawn`, the P1 fix).
wt_tmux_server_token_value() { # [<name>] — with a name, asks the SERVER about that ONE variable
  local n v
  command -v tmux >/dev/null 2>&1 || return 1
  # `$1` narrows the probe to a single name (the lane MODEL credential, whose provider models.json
  # names); no argument keeps the original question, the two names gh honours.
  for n in ${1:-GH_TOKEN GITHUB_TOKEN}; do
    v="$(wt_bounded "${WT_PROBE_TIMEOUT:-15}" tmux show-environment -g "$n" 2>/dev/null)" || continue
    case "$v" in
      "$n="*) case "${v#"$n="}" in *[![:space:]]*) printf '%s\n' "${v#"$n="}"; return 0 ;; esac ;;
    esac
  done
  return 1
}

# `wt_tmux_has_server` — 0 iff a tmux SERVER answers on this socket. ⛔ DELIBERATELY NOT `tmux ls`
# (review finding, measured on tmux 3.4, 2026-10-23): a live server with ZERO sessions (`exit-empty
# off`) answers `tmux ls` with rc 0 and an EMPTY list, so "no session names" cannot be read as "no
# server" — and it was, which credited a caller's `GH_TOKEN` for a server that does not inherit it
# and started exactly the credential-less worker this gate exists to refuse. `show-environment -g`
# talks to the SERVER, so it answers for a zero-session server (rc 0, 73 vars measured) and fails on
# a socket that has none (rc 1) — the distinction the listing cannot make.
wt_tmux_has_server() { # 0 = a server answers · 1 = no server answers · 3 = no ANSWER (bound fired)
  command -v tmux >/dev/null 2>&1 || return 1
  local rc=0
  wt_bounded "${WT_PROBE_TIMEOUT:-15}" tmux show-environment -g >/dev/null 2>&1 || rc=$?
  # ⛔ THREE-VALUED (P2 review finding, 2026-10-23, MEASURED): a fired bound (142 perl / 124 timeout)
  # used to be indistinguishable from "no server", and the caller-token arm CREDITED a caller's token on
  # the strength of it — while a server that is merely slow keeps its OWN environment, so the session
  # does not inherit that token: dead lane, reported provisioned. Only a POSITIVE absence (rc 1) may
  # credit; "no answer" is UNKNOWN and refuses (`wt_launcher_env`).
  case "$rc" in
    0) return 0 ;;
    1) return 1 ;;
  esac
  # ⛔ ALLOW-LIST, NOT A DENY-LIST (P2 review finding, 2026-10-23): the default branch used to be `return
  # 1` = "no server answers", which is the CREDIT arm — so an unnamed rc (a probe SIGKILLed by the OOM
  # killer is 137, a SIGTERMed one 143) was read as a positive absence and credited a caller token for a
  # server that keeps its own environment. Every MEASURED absence shape (no socket dir, no socket file,
  # empty or stale socket) answers rc 1, so only 1 may fall through to the credit; anything else is
  # "no answer" (UNKNOWN, refuses) — the same allow-list polarity the merge rail uses, for the same
  # reason: a value GitHub has not documented yet must never fall through a gap.
  return 3
}

# `wt_launcher_env <home>` — the launch-line prefix, or non-zero when the worker would start with no
# credential. ⛔ THIS IS THE LOUD HALF: a credential-less worker burns a dispatch and produces nothing,
# which is indistinguishable from the launcher killing it — so the spawn is refused, naming every
# place a credential could have come from.
# ⛔ A CALLER'S `GH_TOKEN` IS ONLY PORTABLE WHEN THIS SPAWN CREATES THE SERVER (review finding,
# 2026-10-22). `tmux new-session` inherits the CALLER's environment only when it starts a server;
# against an ALREADY-RUNNING server the session gets that server's global env plus tmux's
# `update-environment` list, which does not include `GH_TOKEN` — measured on tmux 3.4: a server
# created by `env -i HOME=/tmp/a` then `GH_TOKEN=ghp_caller_only tmux new-session` gave a pane whose
# environ had NO `GH_TOKEN` and `tmux show-environment -g GH_TOKEN` said `unknown variable`. So the
# caller's token is credited only when there is positively no server; otherwise the server itself
# must answer (below). A steady-state cell has exactly such a server, so this is the normal case.
# ⛔ AND PRESENCE IS NOT PROVISION: an EMPTY `hosts.yml` (a `gh auth logout` leftover), a `hosts.yml`
# whose host entry carries no `oauth_token:` (the same leftover, half-written), a `keys.env` that
# assigns no value, and a server variable set to the empty string are all refusals. A file or variable
# counts only when it carries a VALUE; `GITHUB_TOKEN` is accepted beside `GH_TOKEN` everywhere
# (gh honours both) because a `GITHUB_TOKEN`-only box is otherwise refused forever.
wt_launcher_env() {
  local home="${1:-}" keys have=0 keys_credit=0 caller_val=0 store_credit=0
  [ -n "$home" ] || return 1
  keys="$home/keys.env"
  # ── THE MODEL CREDENTIAL, DECIDED BEFORE THE gh ONE (see wt_provider_key_var's note) ─────────
  # `pkeys` is the file this spawn must ALSO source to deliver it; empty means no delivery is needed
  # (either the caller's environment already carries a value, or we could not name the variable).
  # ⛔ A PANE, NOT A SUBSHELL, DECIDES NOTHING HERE: this is the CALLER-SIDE verdict. A provider we
  # cannot provision is refused BEFORE `tmux new-session`, because after it `wt_spawn` has already
  # reported success and the caller books an attempt for a lane that will die in seconds — the
  # measured shape that parked 12 PRs as "the reviewer produced no usable verdict".
  local pvar="" pkeys="" phave=0 _pf pdeliv="" prov="" prov_pair="" pmodel=""
  # ⛔ ONE measurement of the pair, used for the credential lookup AND both pins below (P2 review
  # finding, 2026-10-27 — the pair used to be resolved twice, and `pi-keys.env` not at all: see
  # `wt_lane_pair`). Measuring a file EXECUTES it, so a second resolution is a second unbounded-ish
  # source on the synchronous spawn path; one call per spawn is the whole budget.
  prov_pair="$(wt_lane_pair "$home")"
  prov="$(printf '%s\n' "$prov_pair" | sed -n '1p')"
  pmodel="$(printf '%s\n' "$prov_pair" | sed -n '2p')"
  [ -n "$prov" ] || prov="${PI_LANE_PROVIDER:-deepseek}"
  pvar="$(wt_provider_key_var "$home" "$prov")"
  if [ -n "$pvar" ]; then
    # ⛔ THE CALLER'S OWN VALUE IS CREDITED ON TWO CONDITIONS, NOT ONE (P1 review finding, 2026-10-27,
    # MEASURED — this arm delivered NOTHING). It used to be `wt_env_nonblank` alone, which credits a
    # value the pane will never hold, twice over:
    #   (1) EXPORTED. A tmux client hands the server only EXPORTED variables, so a plain
    #       `DEEPSEEK_API_KEY=x` satisfied the read here and reached no pane at all. Same rule, same
    #       reason, as the gh arm's `_wt_exported` below.
    #   (2) NO SERVER. `tmux new-session` inherits the CALLER's environment only when it CREATES the
    #       server; against a running one the pane gets that server's global env. Measured on this box
    #       (2026-10-27): exported caller var => 0 key occurrences in the worker env, plain var => 0,
    #       the file arm => 1. A steady-state box has a server, so (2) is the NORMAL case.
    # Without both, the FILE arm (below) and the SERVER arm answer instead, and a box where neither does
    # is REFUSED rather than handed a lane that dies at its first model call.
    if wt_env_nonblank "$pvar" && _wt_exported "$pvar"; then
      local _srv_rc=0
      command -v tmux >/dev/null 2>&1 || return 1
      wt_tmux_has_server || _srv_rc=$?
      # ⛔ `pdeliv` IS INTERPOLATED INTO THE LAUNCH LINE, so it must carry NO `$`: the prefix is a shell
      # string that is EVALUATED again (pre-check and pane), so a `$` here would be expanded there and a
      # `$`-name printed EMPTY in the refusal (measured by the new pair arms: "the caller's exported ;
      # credited because…"). The variable's NAME is named instead, which cannot be re-expanded.
      [ "$_srv_rc" = "1" ] && { phave=1; pdeliv="inherited from this spawn's environment (this caller's exported $pvar; credited because this spawn CREATES the tmux server)"; }
    fi
    # ⛔ THE FILE ARM COMES BEFORE THE SERVER ARM, AND THAT ORDER IS THE FIX (P1 review finding,
    # 2026-10-27, MEASURED). It used to be the other way round, and the consequence was a refusal that
    # NOTHING the operator could write would clear: with the server carrying the key, arm 2 credited it,
    # so `pkeys` stayed empty and `$home/pi-keys.env` was never sourced — so putting the key there did
    # not change the spawn at all, and only killing the tmux server did, which no message said.
    # It is also the FAITHFUL order: the launch line sources these files under `set -a` AFTER the pane
    # has inherited the server's environment, so a file that ASSIGNS the variable OVERWRITES the server's
    # value in the pane. Crediting the server while a file that assigns it sits unused made the gate's
    # answer and the worker's value disagree; crediting the file first makes them the same answer, on
    # the arm the launch line can actually deliver and prove. The server arm still answers for the shape
    # it exists for — a box with no key file whose supervisor exported the key.
    if [ "$phave" = "0" ]; then
      # DELIVERY FROM A FILE this launch line sources. Precedence: the box-local operator file first
      # (what this box's own shell sources), then the cell's `keys.env` (the operator-pushed contract on
      # a cell). Whichever ASSIGNS it is used. Both are sourced, in that order, by the launch line, so
      # this precedence is also the order that decides the pane's own value.
      for _pf in "$home/pi-keys.env" "$keys"; do
        [ -n "$_pf" ] && [ -f "$_pf" ] || continue
        wt_provider_credit "$pvar" "$_pf" && { pkeys="$_pf"; phave=1; pdeliv="sourced from $_pf"; break; }
      done
    fi
    if [ "$phave" = "0" ]; then
      # THE SERVER'S OWN ENVIRONMENT, which is what an already-running server hands the pane. Asked of
      # the server for THIS name; a box whose supervisor exported the key is a working shape and must not
      # be refused (the same arm the gh gate carries as `wt_tmux_server_token`). ⛔ `wt_spawn`'s
      # caller-side pre-check INJECTS this same value for this same name (`srv_pval`), because that
      # pre-check runs in the CALLER's environment: without the injection the gate credited a credential
      # the pre-check could not see, the prefix exited 98 there, and the spawn was REFUSED on a box whose
      # worker would have worked — measured 2026-10-27. The invariant is that the gate's answer and the
      # pre-check's answer are the SAME answer, on EVERY arm.
      case "$(wt_tmux_server_token_value "$pvar" 2>/dev/null)" in *[![:space:]]*)
        phave=1
        # ⛔ NO BACKTICKS EITHER, AND THAT IS A CREDENTIAL LEAK, NOT TYPOGRAPHY (review finding,
        # 2026-10-28, MEASURED). `pdeliv` is interpolated into the launch line, which is EVALUATED again
        # (the caller-side pre-check, then the pane), so a backtick in it is COMMAND SUBSTITUTION. With a
        # server carrying the key and a `keys.env` holding a blank `export DEEPSEEK_API_KEY=` (the shape
        # that blanks the pane's inherited value), the refusal printed
        # `DEEPSEEK_API_KEY=sk_…from_server` — the SERVER'S CREDENTIAL VALUE — and `wt_spawn` carries that
        # very line into the controller's log (`${premsg:0:300}`) and the pane's stderr, while the guidance
        # the message exists to give was replaced by the command's output. The `$` rule above is the same
        # rule; the command is NAMED here, never executed.
        pdeliv="inherited from the tmux SERVER's global environment (the value behind 'tmux show-environment -g $pvar'; no file here assigns it) — to stop depending on the server, put a non-blank $pvar in $home/pi-keys.env or $keys, which this launch line sources with set -a and which OVERRIDES the server's value" ;;
      esac
    fi
    if [ "$phave" = "0" ]; then
      wt_warn "REFUSED a worker on '$prov': models.json resolves its credential from \$$pvar and NO source DELIVERS a value — not this caller's environment (a caller value counts only when it is EXPORTED *and* this spawn creates the tmux server, since a running server's environment shadows it), not the tmux server's own environment (\`tmux show-environment -g $pvar\`), not $home/pi-keys.env, not $keys. A worker started now dies at its first model call within seconds (pi: 'No API key found for $prov'), and the caller books that as a review that produced NO verdict and, at MAX_REVIEW_TRIES, PARKS the PR — measured 2026-10-26/27, 69 lane logs and 12 parked PRs. Refusing here spends nothing and leaves the PR queued, which is the honest state. Put the key where the worker can read it: a non-blank \$$pvar in $home/pi-keys.env or $home/keys.env, which this launch line sources with set -a (a file also OVERRIDES the tmux server's value, so a file entry clears this refusal even when the server carries a different one)."
      return 1
    fi
  fi
  # ⛔ THE CALLER'S CREDIT MUST BE **EXPORTED** (P1 review finding, 2026-10-23, measured). A tmux client
  # hands the server — and therefore the pane — only EXPORTED variables, so a `GH_TOKEN=x` that is a plain
  # shell variable satisfies `"${GH_TOKEN:-}"` here while never reaching the worker: gate rc=0, record
  # written, lane dead at its first `gh` call. `export -p` is the portable way to ask (bash prints
  # `declare -x GH_TOKEN=…`, POSIX sh prints `export GH_TOKEN=…`; both carry ` GH_TOKEN=`).
  if [ "${caller_val:-0}" = "0" ]; then case "${GH_TOKEN:-}" in *[![:space:]]*) _wt_exported GH_TOKEN && caller_val=1 ;; esac; fi
  if [ "${caller_val:-0}" = "0" ]; then case "${GITHUB_TOKEN:-}" in *[![:space:]]*) _wt_exported GITHUB_TOKEN && caller_val=1 ;; esac; fi
  wt_gh_hosts_token "$home" && { have=1; store_credit=1; }
  # ⛔ A VALUE IS NOT A QUOTED EMPTY (review finding, measured 2026-10-23). `=[^[:space:]]` counted
  # `GH_TOKEN=""` as provision — the character after `=` is a quote — so the file exported an EMPTY
  # token, `gh` fell back to the hosts.yml this HOME does not have, and the worker died at its first
  # call while the gate reported it provisioned. Requiring one non-space, non-quote character after
  # an optional opening quote rejects `=`, `=""` and `=''` and keeps `=ghp_x` / `="ghp_x"`.
  # Residual: `GH_TOKEN="$SOMETHING"` is counted — a variable reference cannot be evaluated without
  # sourcing the file here, and an operator who writes one is asserting it resolves.
  # ⛔ A STATIC GREP IS NOT PROOF THE SOURCE EXPORTS IT (review finding, 2026-10-23, measured). A line the
  # file never executes — `if [ -n "$X" ]; then export GH_TOKEN=…; fi`, or an assignment in a function
  # nobody calls — matches this grep, so the gate reports provisioned while the worker gets nothing. The
  # file's credit is therefore VERIFIED in the launch line after the source, unconditionally: a
  # file-only credit must leave a non-blank token in the environment, or the worker is refused. That is
  # the same dynamic check the broken-file guard uses, applied where the credit came from the file.
  if [ "$have" = "0" ] && wt_keys_credit "$keys"; then
    have=1; keys_credit=1
  fi
  if [ "$have" = "0" ] && [ "$caller_val" = "1" ]; then
    # ... but only if this spawn will CREATE the server (see above), and that is decided by a
    # POSITIVE server probe, never by an empty session list (see `wt_tmux_has_server`).
    # ⛔ ONLY rc 1 ("no server answers") CREDITS (P2 review finding, 2026-10-23, MEASURED): an UNREADABLE
    # probe (rc 3, the bound fired) must never be read as absence — see `wt_tmux_has_server`'s note.
    command -v tmux >/dev/null 2>&1 || return 1
    local srv_rc=0
    wt_tmux_has_server || srv_rc=$?
    [ "$srv_rc" = "1" ] && have=1
  fi
  if [ "$have" = "0" ]; then
    # nothing in the HOME or a credit-bearing caller: the tmux SERVER's global env may still carry one,
    # and a worker against that server inherits it. Probe it — non-blank value, either name.
    wt_tmux_server_token || return 1
  fi
  printf 'export HOME=%s' "$(wt_q "$home")"
  # ⛔ AN INHERITED `GH_TOKEN` OVERRIDES THE STORE THE GATE JUST CHECKED (P1 review finding, 2026-10-23,
  # measured). gh prefers `GH_TOKEN`/`GITHUB_TOKEN` over ANY store, and a tmux pane inherits the SERVER's
  # environment — which this very module can have stamped (the caller-token arm creates the server with
  # the caller's env, and `wt_tmux_server_token` exists because such servers carry tokens). So when the
  # credit came from the STORE or the FILE, the launch line clears those two names before the file is
  # read: the worker then resolves the credential the probe resolved. Driven end-to-end before this: a
  # server carrying `GH_TOKEN=ghp_from_SERVER` plus a validated `hosts.yml` gave a worker whose
  # `gh auth token` printed the SERVER's token, on a spawn that reported provisioned. The caller-token
  # and server-token arms are deliberately EXEMPT — there the inherited value IS the credential.
  # ⛔ A BLANK `GH_TOKEN`/`GITHUB_TOKEN` IS CLEARED ON EVERY ARM: gh prefers it over a valid
  # `GITHUB_TOKEN` and over the store, so `GH_TOKEN='   '` beside a real token is a dead lane, not a
  # provisioned one.
  # ⛔ AND THE BLANK-VALUE CLEAR RUNS AFTER `keys.env` IS SOURCED, not here (P1 review finding,
  # 2026-10-23, MEASURED). Emitted before the source, it could not see what the file wrote: on a STORE
  # credit the old post-source check never ran (it was gated on the FILE credit or a non-zero source
  # status), so a file carrying `GH_TOKEN='   '` beside a validated `hosts.yml` produced a worker whose
  # gh printed `The token in GH_TOKEN is invalid`, on a spawn that reported provisioned. Only the
  # STORE-override unset belongs here, before the file is read.
  if [ "$store_credit" = "1" ] || [ "$keys_credit" = "1" ]; then
    printf '; unset GH_TOKEN GITHUB_TOKEN'
  fi
  # ⛔ keys.env IS SOURCED UNDER `set -a`, exactly as cloud-cell-supervisor.sh sources it. An operator
  # file that ASSIGNS without `export` is legal there (`set -a; . "$ENV_FILE"; set +a`), and a worker
  # that sourced it plainly would hold those values in the launch shell only and hand the lane it
  # starts NOTHING — the credential-less worker this gate exists to refuse, one layer down. `set +a`
  # follows immediately so the worker's own shell options are the caller's, unchanged.
  if [ -f "$keys" ]; then
    # ⛔ THE PRE-CHECK USES THE DIALECT THE FILE WILL BE SOURCED IN (review finding, 2026-10-23, measured):
    # `sh -n` on a dash box refuses a BASH-valid `keys.env` (e.g. one carrying an array), and this file's
    # own launch line is bash-shaped — so a `sh -n` check is an over-block on a perfectly good cell, which
    # is the #2210 refusal loop in a new disguise. bash is what the harness runs and what the cell's own
    # supervisor sources this file with, so bash decides when it exists; `sh -n` is the last resort.
    # ⛔ AND THE FILE MUST ACTUALLY FINISH SOURCING (review finding, 2026-10-23, measured — agent-infra
    # #1713's class). `bash -n` accepts `GH_TOKEN=ghp_x` + `exit 0`, and `. FILE` then ends the WORKER'S
    # shell before the HOME re-assert, the config-dir pin and the credential re-check ever run: the
    # spawn returns 0, the `home=` record is written, and the lane never starts. The file is therefore
    # evaluated in a throwaway subshell whose LAST action is a sentinel — the sentinel's ABSENCE (not a
    # non-zero status: `exit 0` IS success) is the signal — and only then sourced for real. The file is
    # evaluated more than once; like the cell supervisor's own `source_env_file`, it must be a plain
    # assignment file.
    printf '; [ -r %s ] || exit 98; if command -v bash >/dev/null 2>&1; then bash -n %s || exit 98; else sh -n %s || exit 98; fi; _p="$( set -a; . %s >/dev/null 2>&1; set +a; echo __ai1713_env_sourced__ )"; case "$_p" in *__ai1713_env_sourced__) unset _p ;; *) exit 98 ;; esac; set -a; . %s; set +a' \
      "$(wt_q "$keys")" "$(wt_q "$keys")" "$(wt_q "$keys")" "$(wt_q "$keys")" "$(wt_q "$keys")"
  fi
  # ⛔ THE DELIVERY OF THE MODEL CREDENTIAL WHEN IT LIVES IN A BOX-LOCAL FILE (`~/pi-keys.env`, the file
  # this box's `~/.zshrc` sources and the ONLY place the key exists here). Same discipline as `keys.env`
  # above and for the same measured reason: `set -a`, a parse check, and a sentinel proving the file
  # FINISHED (a `keys.env` carrying `exit 0` parsed, then ended the worker's shell before anything ran).
  # Emitted BEFORE the HOME/PATH pins below, so the file cannot repoint either of them.
  if [ -n "$pkeys" ] && [ "$pkeys" != "$keys" ]; then
    printf '; [ -r %s ] || exit 98; if command -v bash >/dev/null 2>&1; then bash -n %s || exit 98; else sh -n %s || exit 98; fi; _pm="$( set -a; . %s >/dev/null 2>&1; set +a; echo __ai_provider_env_sourced__ )"; case "$_pm" in *__ai_provider_env_sourced__) unset _pm ;; *) exit 98 ;; esac; set -a; . %s; set +a' \
      "$(wt_q "$pkeys")" "$(wt_q "$pkeys")" "$(wt_q "$pkeys")" "$(wt_q "$pkeys")" "$(wt_q "$pkeys")"
  fi
  # ⛔ A BROKEN `keys.env` MUST NOT RUN A HALF-PROVISIONED WORKER, AND AN ORDINARY ONE MUST NOT BE FATAL
  # (review findings, 2026-10-23, both measured). `… && . FILE || exit 98` reads the status of the LAST
  # COMMAND IN THE FILE, so `[ -d /x ] && export Y` — false, last — killed a perfectly good worker AFTER
  # it had exported the token, on a spawn that returned 0 and wrote its record. A parse check alone fixes
  # that but re-opens the other side: a file containing `return 1` PARSES, then aborts the source before
  # the token assignment, and the worker runs credential-less. So the guard asks two questions: does it
  # parse AND finish (the sentinel above), and does the environment HOLD a credential now? The second
  # check is UNCONDITIONAL (review finding, 2026-10-23, measured): it used to fire only when the file
  # had credited the token, so a `keys.env` that SOURCES CLEANLY but carries `GH_TOKEN=` (the
  # placeholder an operator leaves when moving to store auth) exported an EMPTY value over a caller or
  # store credit and nothing re-read it — a credential-less worker on an rc=0 spawn, which is the
  # #2210 death this gate exists to refuse. It runs AFTER the config-dir pinning below, so it sees the
  # same store the worker will.
  # ⛔ HOME IS RE-ASSERTED AFTER THE SOURCE, and that is not belt-and-braces (review finding,
  # 2026-10-22). A `HOME=` line inside keys.env is exported by the `set -a` source above and would
  # OVERWRITE the HOME this gate just validated — measured: a file carrying `HOME=/home/cmux` left the
  # worker with `worker_HOME=/home/cmux`, where no `hosts.yml` exists, i.e. the exact credential-less
  # worker the gate exists to refuse, blessed as provisioned. Same two-step shape as
  # `cloud-cell-supervisor.sh` (pre-source so `$HOME` expansions inside the file still resolve to the
  # cell home; post-source so the file cannot repoint it). `O` is emitted after the source for the
  # same reason.
  printf '; export HOME=%s' "$(wt_q "$home")"
  # ⛔ THE WORKER'S PATH IS PART OF THE CONTRACT, because the tmux SERVER's PATH is not the caller's
  # (P1 review finding, 2026-10-23, MEASURED): `tmux show-environment -g PATH` answers
  # `unknown variable: PATH` on a server created by `env -i`, and the pane then runs with bash's
  # DEFAULT path — so on a Mac (gh only in /opt/homebrew/bin) the caller-side pre-check resolved `gh`
  # and the PANE did not: the guard exited 98 in the pane's first millisecond, `new-session -d` had
  # already returned 0, and `wt_spawn` reported a provisioned lane that was dead on arrival — the exact
  # class this file exists to refuse. Pinning it also makes the pre-check faithful (it now measures the
  # resolution the worker will have) and gives the tmux arm what the durable-terminal arm already gets
  # from its env snapshot. Emitted AFTER the source, like HOME, so a `keys.env` cannot repoint where
  # `gh`, `uv` or `pi` resolve to.
  printf '; export PATH=%s' "$(wt_q "$PATH")"
  # ⛔ AND THE PROVIDER THE GATE RESOLVED IS DELIVERED TO THE PANE (P3b review finding, 2026-10-27).
  # The three lane files resolve `${PI_LANE_PROVIDER:-deepseek}` in the PANE (the tmux server's
  # environment, then whatever this line sources), while the gate resolved it caller-side — so an
  # ambient value could make the lane run, and bill, a provider whose credential was never checked (and
  # a different model than its reviewer). `wt_lane_provider "$home"` now resolves the PANE's answer; this
  # line PINS that answer AFTER every source, so the server's stale environment or a later source cannot
  # move it, and gate and lane cannot disagree by construction.
  # ⛔ AND THE MODEL IS PINNED WITH IT — BOTH MEMBERS OR NEITHER (P2 review finding, 2026-10-27,
  # MEASURED). Pinning only the provider produced a HALF-PINNED PAIR: a `pi-keys.env` naming
  # `PI_LANE_PROVIDER=zai` + `PI_LANE_MODEL=qwen3.8-max` (a file the old resolution never read) gave
  # `provider=[deepseek] model=[qwen3.8-max]` in the pane — the provider pinned to what the gate checked,
  # the model left as the file wrote it, i.e. one decision assembled from two measurements. Both members
  # now come from the ONE `wt_lane_pair` resolution.
  # ⛔ WHEN NO SOURCE NAMES A MODEL, THE INHERITED ONE IS CLEARED rather than left to shadow the pair: an
  # inherited `PI_LANE_MODEL` is a model NO source in this measurement supplied, and leaving it beside a
  # pinned provider re-creates the same half-pin from the other side (the tmux server's stale model with a
  # gate-checked provider). Clearing it lets the lane's own `${PI_LANE_MODEL:-deepseek-flash}` default
  # apply — the SAME default the caller-side resolution uses — so the pane's pair is always the pair this
  # line decided, both halves. The channel for an override is the env file (`keys.env`, then
  # `pi-keys.env` — what `cloud-cell-supervisor.sh` measures and the README documents), where it is now
  # both MEASURED (the credential the gate checks) and PINNED.
  printf '; export PI_LANE_PROVIDER=%s' "$(wt_q "$prov")"
  if [ -n "$pmodel" ]; then
    printf '; export PI_LANE_MODEL=%s' "$(wt_q "$pmodel")"
  else
    printf '; unset PI_LANE_MODEL'
  fi
  # ⛔ THE WORKER MUST RESOLVE `gh`'s CONFIG THE WAY THE PROBE DID — IN BOTH DIRECTIONS.
  # `wt_gh_hosts` accepts `GH_CONFIG_DIR` / `XDG_CONFIG_HOME`, but a tmux session does NOT inherit this
  # shell's environment — so probing a repointed config dir and then starting a worker without it would
  # be the same false provision this gate exists to refuse, one layer down. The INVERSE is the same bug
  # (review finding, 2026-10-23): when the probe used the DEFAULT (`$home/.config/gh`, neither variable
  # set here), a worker that still inherits `GH_CONFIG_DIR`/`XDG_CONFIG_HOME` — from the tmux SERVER's
  # environment, or exported by the `keys.env` sourced under `set -a` just above — reads a DIFFERENT
  # file than the one that was probed. Measured on 9b30d611 with a token-bearing caller HOME and
  # `XDG_CONFIG_HOME` in the session env: `wt_launcher_env` returned 0, and the worker's `gh` would have
  # read `<XDG>/gh/hosts.yml`, which in the fixture carries no token — a dead lane, reported provisioned.
  # So the default case UNSETS both: the launch line, not the spawn caller's environment, decides where
  # the worker's gh looks.
  if [ -n "${GH_CONFIG_DIR:-}" ]; then
    printf '; export GH_CONFIG_DIR=%s' "$(wt_q "$GH_CONFIG_DIR")"
    printf '; unset XDG_CONFIG_HOME'
  elif [ -n "${XDG_CONFIG_HOME:-}" ]; then
    printf '; export XDG_CONFIG_HOME=%s' "$(wt_q "$XDG_CONFIG_HOME")"
    printf '; unset GH_CONFIG_DIR'
  else
    printf '; unset GH_CONFIG_DIR XDG_CONFIG_HOME'
  fi
  [ -n "${O:-}" ] && printf '; export O=%s' "$(wt_q "$O")"
  # ⛔ A BLANK VALUE IS NOT A CREDENTIAL, AND THE CLEAR MUST SEE WHAT THE SOURCE WROTE (P1 review
  # finding, 2026-10-23, MEASURED): the pre-source clear could not, so a `keys.env` re-introducing
  # `GH_TOKEN='   '` survived on every arm whose post-source check did not fire. Both names, because gh
  # prefers `GH_TOKEN` then `GITHUB_TOKEN` over any store — a blank one in either hides a valid one.
  printf '; case "${GH_TOKEN:-}" in *[![:space:]]*) : ;; *) unset GH_TOKEN ;; esac; case "${GITHUB_TOKEN:-}" in *[![:space:]]*) : ;; *) unset GITHUB_TOKEN ;; esac'
  # The credential guard: after the source and the blank-clear, either a name holds a VALUE or the
  # store the probe read must answer. ⛔ IT RUNS ON EVERY ARM (P1 review finding, 2026-10-23, measured):
  # gating it on the FILE credit or a non-zero source status skipped exactly the arm where a `keys.env`
  # had just overwritten an inherited token, leaving a credential-less worker on a spawn that reported
  # provisioned. It costs a `gh auth token` only when no name carries a value — and `gh auth token`
  # answers for the worker's own HOME + pinned config dir, so with no gh at all the fallthrough exits
  # 98 (fail-closed).
  # ⛔ AND THE gh CALL MUST NOT RE-READ THE VALUE THAT WAS JUST JUDGED BLANK (review finding, 2026-10-23,
  # measured): with `GH_TOKEN='   '` exported, `gh auth token` prints it and exits 0, so the guard would
  # bless the very token the `case` above rejected. The environment names are cleared for this one call
  # (as the static probe clears them), so it answers the question the `case` asked — is there a token in
  # the STORE — and never the question it just answered NO to.
  # ⛔ AND IT MUST ASK THE **SAME QUESTION THE GATE ASKED, WITH THE SAME gh** (P2 review finding,
  # 2026-10-23, measured): the guard used to resolve `gh` through the PANE's PATH, which a `PATH=` line
  # inside `keys.env` can rewrite (measured: gate rc=0, record written, worker `exit 98` on its first
  # statement — a silently dead lane). It now takes gh's answer from an ABSOLUTE path resolved at BUILD
  # time, and stays bounded (`wt_gh_token`): a hung `gh auth token` on the pane side is the same freeze
  # as on the gate side. Where NO gh can be resolved at build time the guard REFUSES (`false`): a box
  # with no gh anywhere cannot run a lane at all, and refusing loudly — before the session starts, via
  # `wt_spawn`'s caller-side pre-flight — is the documented fail-closed policy for that shape, not a
  # file credit the worker's own gh could never spend.
  _guard="false"
  _ghbin="$(command -v gh 2>/dev/null || true)"
  if [ -n "$_ghbin" ] && command -v perl >/dev/null 2>&1; then
    _guard="env -u GH_TOKEN -u GITHUB_TOKEN perl -e 'alarm 10; exec @ARGV' $(wt_q "$_ghbin") auth token >/dev/null 2>&1"
  fi
  printf '; case "${GH_TOKEN:-}${GITHUB_TOKEN:-}" in *[![:space:]]*) : ;; *) %s || exit 98 ;; esac' "$_guard"
  # ── AND THE MODEL CREDENTIAL IS VERIFIED WHERE THE gh ONE IS — AFTER every source, against the
  # environment the worker will actually run with. This is the question a static grep cannot answer: did
  # the delivery LAND?
  # ⛔ IT RUNS ON EVERY ARM (P1 review finding, 2026-10-27, MEASURED) — it used to be gated on `pkeys`,
  # i.e. on the FILE arm, so the CALLER arm (this box's normal one) emitted no check at all: the pane
  # started with a blank key and died at its first model call on a spawn that reported provisioned. That
  # is exactly the gate-on-the-file-credit mistake the gh guard above was fixed for, one credential over,
  # so it takes the gh guard's shape: whenever the required NAME is positively known, the pane proves it
  # holds a VALUE or refuses. Where the name is NOT known (`pvar` empty: an unreadable models.json, a
  # literal apiKey, a provider pi authenticates itself) nothing is emitted and nothing refuses — our own
  # blindness must never become a refusal loop (#2210).
  if [ -n "$pvar" ]; then
    printf '; case "${%s:-}" in *[![:space:]]*) : ;; *) echo "[worker-terminal] REFUSED: the model credential \$%s is blank in the worker (%s) — this lane could not authenticate a single model call" >&2; exit 98 ;; esac' \
      "$pvar" "$pvar" "$pdeliv"
  fi
  return 0
}

# WHY the launcher is not `terminal` — the PROBE'S OWN ANSWER, for the startup line and the refusal.
# ⛔ THE ANSWER USED TO BE THROWN AWAY, AND THAT IS THE DEFECT THIS FUNCTION REMOVES. `cmux tree
# --json >/dev/null 2>&1` keeps the DECISION and discards the REASON, so a box reports
# `launcher=none (cmux=yes, uname=Linux)` — true, actionable in no way, and indistinguishable from a
# tty gate, a TERM/TERM_PROGRAM gate, a `cmux tree` whose output SHAPE drifted, or a daemon that is
# simply not there. Measured 2026-10-22 on cell-1 (agent-infra#2366): the answer the probe already
# held was `cmux: cmux-tui daemon binary not found at /root/.cmux/bin/cmux-tui` — the box had no
# daemon at all — and the binary that message names is the guest CLI's own CLIENT, which
# /usr/local/libexec/cmux-cloud-adapter:762-772 requires as `[ -x "$CMUX_TUI_BIN" ]` for every verb
# but identity and help. One log line would have said so; `none` alone left it to be re-derived.
# An instrument that holds the datum and does not read it is a category-A defect, so the reason now
# travels with the verdict.
# ONE probe IN THIS FUNCTION, and the honest arithmetic for a caller — corrected after the rebase,
# because the CALLER's cost is not this function's cost. This function makes ONE `cmux tree` call
# (stderr only). What a `none` box costs end-to-end is FIVE, and the arithmetic is the union of both
# sides of the merge: the startup banner's own `wt_launcher` read + this function's read (2), then the
# SAME two on a refused spawn (2), PLUS main's deliberate re-measurement of `cmux tree` rc on the
# refusal line (1) — main re-probes there because a presence test sent the operator to the wrong fault
# (#2210). ⛔ An earlier draft of this comment said "TWO per startup line and per refused spawn — not
# three", which was true only before main's rc re-measure landed; it is now FALSE and it disagrees
# with the pinned count in the suite, so it is corrected here rather than left to misdirect the next
# reader into resetting the pin. Pinned as a COUNT by the suite so it cannot creep back. ⚠️ Under
# `set -e` a bare failing probe would exit the shell before `rc=$?`; every shipped call site wraps
# this in `$( )` (a subshell absorbs the status) and both controllers run `set -u` only — but a new
# direct caller must keep that in mind.
wt_launcher_why() {
  if ! command -v cmux >/dev/null 2>&1; then
    printf 'cmux is not on PATH'
    return 0
  fi
  # STDERR ONLY. `2>&1` duplicates fd2 onto the substitution's pipe BEFORE `>/dev/null` moves fd1, so
  # the daemon's own complaint is kept and a multi-kilobyte workspace tree is not.
  local err rc flat
  err="$(cmux tree --json 2>&1 >/dev/null)"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    # Reachable only when the LAUNCHER's own probe failed and this one did not — a probe flipped
    # between two reads. Saying anything else here would name a mechanism the code does not have.
    printf 'cmux tree --json answered on re-probe (it failed on the launcher read): a probe flip'
    return 0
  fi
  # The sibling idiom for a captured message (see wt_spawn's own refusals): flatten, then bound.
  flat="$(printf '%s' "$err" | tr '\n' ' ' | cut -c1-300)"
  printf 'cmux tree --json failed (rc=%s): %s' "$rc" "${flat:-no stderr, exit status only}"
}

# THE controller's one startup line — which launcher this surface got, and WHY when it got none.
# It lives here, beside the verb whose verdict it reports, so that a test can drive the REAL line
# instead of a copy of it (the copy this fix first shipped was vacuous: it matched the reason on the
# `REFUSED` line further down the same capture, so it passed with the startup half deleted).
# The suffix is appended ONLY for `none` — the refused state. A healthy launchd Mac reports `tmux`,
# which is DELIBERATE and not a degrade (see the table above), and stamping `failed:` on a designed
# state is how `failed` stops meaning anything.
wt_startup_banner() {
  local la
  la="$(wt_launcher)"
  printf '[startup] worker launcher=%s (cmux=%s, uname=%s)' "$la" \
    "$(command -v cmux >/dev/null 2>&1 && echo yes || echo no)" "$(uname -s 2>/dev/null)"
  case "$la" in none) printf ' — %s' "$(wt_launcher_why)" ;; esac
  printf '\n'
  return 0
}

# `surface` (the named primitive) vs `layout` (the guest CLI's equivalent). Probed ONCE, because a
# CLI that answers `surface ls` is a different build, not a transient state.
wt_grammar() {
  if cmux surface ls >/dev/null 2>&1; then WT_GRAMMAR=surface; else WT_GRAMMAR=layout; fi
  printf '%s\n' "$WT_GRAMMAR"
}

# Drop the memoized launcher, liveness table and the census file (after any spawn/close, and in
# tests). ⛔ The FILE is the memo that counts: every caller reads the table through a command
# substitution, so an in-shell variable alone would leave a stale census behind a spawn.
wt_forget() {
  WT_LAUNCHER=""; WT_GRAMMAR=""; WT_TABLE=""; WT_TABLE_AT=0
  rm -f "$(wt_dir)/.wt-census" 2>/dev/null || true
  return 0
}

# ── the census: who exists, and is it alive ───────────────────────────────────────────────────
# ONE daemon read per table, not one per question: the controller asks ~12 times a cycle (five spawn
# sites, two ceilings each, plus the log line). `cmux tree --json` answers workspace → screens →
# tabs → terminal ids in a single call, so the whole census is one round trip.
#
# The workspace NAME carries the worker identity (`wt-<worker>`), which is what makes the census
# independent of this file's own records: a worker whose record was lost (a wiped $O/state, a lane
# spawned by an older harness) is still counted and still reaped. A ledger-only census would leak
# exactly those.
# The program is held in a variable and passed with `-c`, NOT fed to python through a heredoc:
# stdin carries the daemon's JSON, and a heredoc here consumes it, leaving `json.load` to read the
# program text. Measured: the census silently returned nothing, which reads exactly like "no workers".
#
# ⛔ THE HEREDOC LIVES IN A FUNCTION BODY, AND THE SUBSTITUTION CARRIES NONE (#2248). Apple ships
# bash 3.2, which mis-parses a heredoc nested inside a command substitution: the WORDS OF THE
# HEREDOC BODY are executed as commands, and the mis-parse runs on into the rest of the file. At
# `WT_TREE_PY="$(cat <<'PY'"` the comment ending `…like "no workers".` was executed as a command,
# then `WT_TREE_PY: unbound variable`, and every function below it was never defined — so the
# controller died AT SOURCE TIME on macOS while `launchctl` and `harness verify` both said GREEN
# (box log: `controller … alive but the heartbeat is 3652s old`). `bash -n` PASSES on the broken
# form — it is a runtime mis-parse, not a syntax error — so nothing catches it until a macOS box
# sources the file. Function-body-then-substitute parses identically under 3.2 and 5.x; keep it.
_wt_tree_py_body() { cat <<'PY'
import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    sys.exit(3)
# ⛔ SHAPE, NOT JUST SYNTAX. `json.load` accepts any document whose top-level keys we then `.get()`
# past — so a reply that PARSES but no longer carries the tree (an envelope like {"data": {...}}, a
# renamed `terminals`) produced a non-empty table of `dead` rows with the probe reporting success:
# the caps stopped binding and `wt_close` deleted a live worker's record. The header already records
# that the id shape differs between cmux builds, so a drifted document is a live risk, not a
# hypothetical. `screens` and `terminals` are the load-bearing pair: require them present and every
# key we read to be a LIST when present. A genuinely idle daemon answers all four as [].
if not isinstance(d, dict):
    sys.exit(3)
for _k in ("screens", "terminals"):
    if not isinstance(d.get(_k), list):
        sys.exit(3)
for _k in ("workspaces", "tabs"):
    if _k in d and not isinstance(d.get(_k), list):
        sys.exit(3)
ws={w.get("id"):(w.get("name") or "") for w in d.get("workspaces",[]) or []}
tabs={t.get("id"):t.get("content_id") for t in d.get("tabs",[]) or []}
run={t.get("id"):bool(t.get("running")) for t in d.get("terminals",[]) or []}
state={}
for s in d.get("screens",[]) or []:
    wname=ws.get(s.get("workspace_id") or "","")
    if not wname.startswith("wt-"):
        continue
    ids=[]
    stack=[((s.get("layout") or {}).get("root") or {})]
    while stack:
        n=stack.pop()
        if not isinstance(n,dict): continue
        ids.extend(n.get("tab_ids") or [])
        stack.extend(n.get("children") or [])
    alive=any(run.get(tabs.get(t) or "",False) for t in ids) if ids else False
    state[wname]=state.get(wname,False) or alive
# TWO key spaces, because the two grammars name a worker differently:
#   w:<worker>      the workspace name (`wt-<worker>`), which only the LAYOUT grammar sets;
#   t:<terminal-id> every terminal in the tree — the only handle a `surface new-terminal` spawn has
#                   (that primitive takes no name), and the authority for a terminal RECORD.
# Without the second, a surface-grammar worker is untrackable: the census could never return it, so
# it read DEAD, `wt_count` stopped counting it and `wt_alive` re-spawned the same PR every cycle.
for n,v in sorted(state.items()):
    print("w:%s\t%s" % (n[3:], "alive" if v else "dead"))
for tid,v in sorted(run.items()):
    print("t:%s\t%s" % (tid, "alive" if v else "dead"))
PY
}
WT_TREE_PY="$(_wt_tree_py_body)"
wt_tree_probe() { # stdin: `cmux tree --json`; stdout: "w:<worker>"|"t:<terminal-id>" TAB verdict
  python3 -c "$WT_TREE_PY" 2>/dev/null
}

# The SURFACE half of a close: given a worker NAME, print `ws<TAB><workspace-id>` and
# `term<TAB><terminal-id>` for its `wt-<name>` workspace. Needed because the census counts a worker
# whose RECORD is gone (a wiped $O/state, a lane from an older harness) — and a reap that cannot
# resolve that worker leaves it holding a slot forever while logging "could NOT be proven gone".
# ⛔ FUNCTION BODY, NOT AN INLINE HEREDOC IN THE SUBSTITUTION — see the bash 3.2 note above (#2248).
_wt_ws_py_body() { cat <<'PY'
import json,sys
name=sys.argv[1]
try:
    d=json.load(sys.stdin)
except Exception:
    sys.exit(3)
ws={w.get("id"):(w.get("name") or "") for w in d.get("workspaces",[]) or []}
tabs={t.get("id"):t.get("content_id") for t in d.get("tabs",[]) or []}
seen=[]
def add(k,v):
    if v and (k,v) not in seen: seen.append((k,v))
for s in d.get("screens",[]) or []:
    wid=s.get("workspace_id") or ""
    if ws.get(wid,"") != name:
        continue
    add("ws",wid)
    ids=[]
    stack=[((s.get("layout") or {}).get("root") or {})]
    while stack:
        n=stack.pop()
        if not isinstance(n,dict): continue
        ids.extend(n.get("tab_ids") or [])
        stack.extend(n.get("children") or [])
    for t in ids:
        add("term",tabs.get(t))
for k,v in seen:
    print("%s\t%s" % (k,v))
PY
}
WT_WS_PY="$(_wt_ws_py_body)"

# The tmux half of the census: session names, read once. Exact membership (`grep -qx`), never `-t`
# prefix matching — `tmux has-session -t fix-82` matches `fix-820`, which is how a healthy worker
# gets mistaken for another PR's session.
# ⛔ THREE ANSWERS, NOT TWO (return 3 = UNKNOWN). Folding "the read failed" into "no sessions" is how
# a broken socket became a DEAD worker: the census then read 0 workers, `wt_count` stopped binding the
# caps, and `wt_close` DELETED the record of a session that was still running — the unproven kill this
# file says it never reports. `tmux ls` says `no server running`/`no sessions` for the genuinely
# absent case, and THAT is a positive empty answer; anything else is a failed read.
wt_tmux_names() {
  local out
  command -v tmux >/dev/null 2>&1 || return 0     # no binary ⇒ no tmux session can exist
  if out="$(wt_bounded "${WT_PROBE_TIMEOUT:-15}" tmux ls -F '#{session_name}' 2>&1)"; then
    printf '%s\n' "$out"; return 0
  fi
  # A bound that fired is an UNREADABLE read, not an empty one: fall through to `return 3` (UNKNOWN),
  # which the census reads as ALIVE — the fail-closed direction.
  # ⛔ WHY THE WORDING IS NOT A POLARITY SIGNAL (P2 review finding, 2026-10-23, MEASURED — this block
  # used to claim the opposite and was wrong): tmux's client messages do NOT partition the states the way
  # one would like. An absent socket FILE answers `error connecting to <socket> (No such file or
  # directory)`, rc 1 — and SO DOES a live server whose socket file was unlinked (`rm` it under a running
  # server and panes keep running, measured). `no server running on <socket>` is what a STALE socket file
  # (or a completely absent socket dir) answers. So `error connecting … No such file` cannot be read as
  # "no sessions": the census treats it as UNREADABLE (rc 3 → UNKNOWN → ALIVE), which is the fail-closed
  # direction, and the DECLARED COST is on the other side — on a genuinely fresh box a tmux record left in
  # `$O/state` reads UNKNOWN, so `wt_count` never frees that slot and `wt_close` cannot prove death (no
  # age escape exists). Pre-existing; it is the cheap side of the trade. `wt_launcher_env` does not read
  # this function at all — it asks `wt_tmux_has_server`, whose rc is what credits a caller token. OLD NOTE,
  # kept for the parse hazard it records: matching the `No such file` wording as "no sessions" made a
  # FRESH box answer 3, so `wt_launcher_env` refused the very shape it credits (a caller carrying GH_TOKEN
  # that will CREATE the server), i.e. refused every spawn, every cycle (measured on tmux 3.4). That is
  # now fixed at the CORRECT seam (`wt_tmux_has_server`), not by widening this arm.
  #
  # ⛔ THE EXPLANATION LIVES ABOVE THE case, NOT INSIDE THE ARM. Measured on this change: with the
  # seven-line version of it inside the arm below, `/bin/bash -n` on the PR head (d635527b) exited 2 —
  # "syntax error near unexpected token" on a stray close-paren — so the module did not PARSE,
  # wt_spawn was undefined,
  # and orch-loop.sh turns that into exit 78 FATAL. Deleting the block restored rc=0 in both
  # directions, so the block is the trigger. macOS /bin/bash is 3.2 and orch-loop.sh declares it;
  # CI's bash 5 parses the same text happily, which is why nothing caught it before merge.
  # It did NOT reduce to a standalone fixture (the same text in a fresh file parses), so the durable
  # rule is not "avoid these characters" — it is that this file is parse-checked in the controller's
  # own shell, which worker-terminal.test.sh now does (and which is blind where /bin/bash is bash 5).
  # ⛔ `error connecting to … (No such file or directory)` IS NOT "NO SESSIONS" (P1 review finding,
  # 2026-10-23, MEASURED — this arm was WRONG and it inverted the polarity rule at the top of this
  # file). tmux 3.4 prints exactly that, rc 1, for the socket FILE HAVING BEEN UNLINKED under a server
  # that is still running: measured end-to-end, `rm` the socket of a live session and `tmux ls` answers
  # this while the pane's process keeps running. Matching it as a positive EMPTY read made the census
  # print `lane-N dead`, `wt_count` = 0 and `wt_alive` = DEAD for a worker that was running — so the
  # caps stopped binding and `wt_close` proceeded to delete a live worker's record (which then runs
  # untracked forever). MEASURED MODEL, and it is why the WORDING cannot carry polarity: an absent
  # socket dir or file answers `error connecting … (No such file or directory)` rc 1, AND a live server
  # whose socket file was unlinked answers the same; `no server running` is what a stale/empty socket
  # answers. So every `error connecting` shape stays rc 3 — unreadable is never evidence of a fresh
  # start — and `no server running` (no server can be reached, so no tmux session can exist) is EMPTY.
  case "$out" in
    *'no server running'*|*'no sessions'*|*'no current session'*) return 0 ;;
  esac
  return 3
}

# wt_table -> "<worker>\t<alive|dead|unknown>", one line per worker this box knows about, deduped.
# Memoized for WT_TABLE_TTL seconds (default 10) so a cycle's dozen questions are one daemon read;
# 0 disables the memo (tests, and an operator debugging a stubborn box).
# ⛔ THE MEMO IS A FILE, because every call site reads the table through `$(wt_table)` — a shell
# variable set inside that command substitution dies with the subshell, so an in-memory memo was
# never once hit (measured: three questions, three full `cmux tree` probes). The file carries its own
# timestamp so this stays portable (no `stat` dialect in the hot path), it is written atomically, and
# `wt_forget` removes it — a spawn or a close must never be answered from the census it invalidates.
# WT_ABSENT_CONFIRM — how long an absent session owner must persist before its records are concluded
# dead (agent-infra#2653, review round 5). Two samples, never one: see the arm in wt_table.
WT_ABSENT_CONFIRM="${WT_ABSENT_CONFIRM:-60}"
case "$WT_ABSENT_CONFIRM" in ''|*[!0-9]*|0*) WT_ABSENT_CONFIRM=60 ;; *) WT_ABSENT_CONFIRM=$(( 10#$WT_ABSENT_CONFIRM )) ;; esac
# ⛔ ZERO IS NOT "OFF", IT IS "CONFIRM ON ONE SAMPLE" (review round 7 of #2653, P2): any `export` could
# set it, and a gate an export can defeat is not a gate (the same reasoning `wt_bounded` records for its
# own `0`). An ALREADY-ELAPSED window is a different input and still confirms on this sample.
# ⛔ AND IT IS COERCED **BEFORE** `WT_ABSENT_STALE_MIN` IS DERIVED (review round 11 of #2653): done the
# other way round, `0` made the `2*window` floor 0, leaving `4*CYC` = 20s at the sanctioned `CYC=5` —
# NARROWER than the 60s window it must be wider than, so every stamp was discarded as stale before it
# could confirm and the release could never fire, silently.
[ "$WT_ABSENT_CONFIRM" -ge 1 ] 2>/dev/null || WT_ABSENT_CONFIRM=60
# ⛔ CYC IS READ BY THE STALENESS RULE BELOW, SO IT IS COERCED HERE, NOT ASSUMED (review round 10 of
# #2653). This module is sourced by `dispatch-merge.sh` and `report.sh`, which do NOT coerce CYC for
# it (`orch-loop.sh` repairs only its own shell), so a non-numeric value from the environment reaches
# `$(( 4 * 10#$CYC ))` — and an arithmetic-expansion error TERMINATES `wt_table` before it prints.
# An empty table is read as "this box has no workers": the caps stop binding and `wt_close` deletes a
# record it never looked at. `CYC` also floors at 5 (install.sh, orch-loop), so a legitimate small
# cycle is preserved.
# ⛔ NORMALISE INTO A LOCAL, DO NOT CLASS-CHECK AND DO NOT TOUCH THE CALLER'S `CYC` (review round 13 of
# #2653, P1). `case ''|*[!0-9]*)` ACCEPTS `08`, `[ 08 -ge 1 ]` is true (test parses decimal), and then
# `$(( 4 * CYC ))` reads `08` as OCTAL and ERRORS — the assignment fails, and with `set -u` (every
# consumer: orch-loop.sh, dispatch-merge.sh, report.sh) `WT_ABSENT_STALE_MIN` is UNBOUND, which is fatal
# at SOURCE time: the controller and the merge dispatcher exit before a cycle runs, and KeepAlive
# relaunches a process that dies in the same place — the `CYC=08` relaunch-loop the `is_num` doctrine
# records. `0*` is therefore rejected as well, and `10#` makes the rest decimal.
CYCN=240
case "${CYC:-}" in
  ''|*[!0-9]*|0*) : ;;
  *) [ "${#CYC}" -le 9 ] && CYCN=$(( 10#$CYC )) ;;
esac
[ "$CYCN" -ge 1 ] 2>/dev/null || CYCN=240
# A stamp older than this is not continuity for the CURRENT outage: it is re-stamped, never confirmed.
# ⛔ AND IT MUST BE WIDER THAN THE CONFIRMATION WINDOW (review round 10 of #2653), or a sanctioned
# small cycle (`CYC` floors at 5) would discard every stamp before it could ever confirm — the release
# #2653 provides would silently never happen. Whichever is larger: 4 cycles, or twice the window.
WT_ABSENT_STALE_MIN=$(( 4 * CYCN ))
[ "$WT_ABSENT_STALE_MIN" -ge $(( 2 * WT_ABSENT_CONFIRM )) ] || WT_ABSENT_STALE_MIN=$(( 2 * WT_ABSENT_CONFIRM ))
WT_CENSUS=""
wt_table() {
  local now ttl dir cache hdr tree tree_err tfile absent_now absent_since absent_last _cont _mage _wl nrc names probe_ok raw="" tbl="" f name kind id st
  # ⛔ A FAILED OR BACKWARDS CLOCK MUST NOT FREEZE THE MEMO (review round 13 of #2653, P2). `|| echo 0`
  # is the idiom round 12 removed from the absent arm: with `now=0` (or after a backwards clock step)
  # `now - at` is NEGATIVE, which is `< ttl`, so a memo is served FOREVER instead of for 10 s — the
  # census freezes at the pre-step verdict, and a frozen `dead` row is the under-count direction (the
  # caps stop binding). The age must be non-negative AND under the TTL.
  now="$(date +%s 2>/dev/null)" || now=""
  case "$now" in ''|*[!0-9]*) now="" ;; esac
  ttl="${WT_TABLE_TTL:-10}"
  dir="$(wt_dir)"; cache="$dir/.wt-census"
  if [ "${ttl:-0}" -gt 0 ] 2>/dev/null && [ -f "$cache" ]; then
    hdr="$(head -1 "$cache" 2>/dev/null)"
    case "$hdr" in
      '# at='*)
        case "${hdr#\# at=}" in
          ''|*[!0-9]*) : ;;
          *) if [ -n "$now" ]; then
               _mage=$(( now - 10#${hdr#\# at=} ))
               [ "$_mage" -ge 0 ] && [ "$_mage" -lt "$ttl" ] && { sed '1d' "$cache"; return 0; }
             fi ;;
        esac ;;
    esac
  fi
  # ⛔ AN ABSENT SESSION OWNER IS A READING, NOT AN UNREADABLE ONE (agent-infra#2653, measured
  # 2026-10-24). `cmux tree --json` was read with its stderr discarded, so a daemon that was NOT
  # RUNNING — answering `cannot connect to session socket …: Connection refused (os error 111)` with
  # an empty stdout — was indistinguishable from a daemon that answered something undecodable. Both
  # read UNKNOWN, every `kind=terminal` record read UNKNOWN, and `unknown` counts as LIVE by the
  # fail-closed rule below. The measured consequence on the live cell: 18 stale worker records (logs
  # silent for 26-30h) counted as 18 live workers; `wt_close` could never PROVE a close (its
  # verification read is the same unreadable census), so the records were kept forever; the review
  # lane ceiling never fell (`review lanes=11/6` every cycle for 26h); no review was dispatched for
  # the 8 NEEDS-REVIEW PRs; the PR queue could not drain; and the threshold-free merge-priority gate
  # held the issue path shut while 175 candidates went undispatched on a box reporting idle lanes.
  # A terminal lives INSIDE the session owner. If the owner is not running there is no terminal —
  # that is a MEASUREMENT, not a guess, and it is the same polarity the tmux half already implements
  # (`no server running` = EMPTY, `error connecting` = unreadable). A daemon that ANSWERS with
  # something undecodable (a banner, a drifted shape) is still UNKNOWN, below, unchanged: the caps
  # keep binding on a read that is merely illegible, and only a CONFIRMED-ABSENT transport empties
  # the census.
  # ⛔ THE CAPTURE MUST NOT BE ABLE TO STOP THE PROBE (review round 6 of #2653, P2). A redirect that
  # cannot be opened makes bash SKIP the command entirely, so on an unwritable (or missing) `$dir`
  # `cmux tree` would never run: `tree` empty, `tree_err` empty, probe UNKNOWN, and the table loses
  # every row it derives FROM THE DAEMON — the record-less workers the census exists to keep. That is
  # the under-count direction (caps stop binding). So the capture is optional: if the file cannot be
  # created, the probe still runs and its stderr is discarded exactly as before.
  # ⛔ THREE SEPARATE NAMES, BECAUSE ONE WAS DOING TWO JOBS (review round 7 of #2653): `tree_err` held
  # the FILE PATH and then the file's CONTENT, so `rm -f "$tree_err"` removed nothing and one capture
  # file accumulated per controller process (carrying the daemon's stale stderr, and colliding with the
  # next run's `mkdir`). And a failing `>` redirect prints its own diagnostic on the PRE-COMMAND stderr,
  # which `2>/dev/null` on that simple command does not silence — the `{ …; } 2>/dev/null` group does,
  # which matters because on an unwritable `$dir` this runs on EVERY census read and the controller's
  # log is append-only and never rotated.
  # ⛔ ONE CAPTURE LOCATION, AND IT IS NOT `$dir` (review round 8 of #2653, P1). Round 6's fallback
  # captured the streams differently when `$dir` was unwritable, so the SAME bytes could read one way
  # with a writable dir and another way without it: the writable branch routed only STDERR into
  # `tree_err` (an unparseable STDOUT left the verdict UNKNOWN), while the fallback merged both — so a
  # `no server running` line printed on STDOUT became the absent-owner signal in one branch and not in
  # the other. `dead` frees the caps and lets `wt_close` close a live worker's terminal, so that was
  # the same P1 class the round-7 rc fix closed on the OTHER axis.
  # The capture now lives in `$TMPDIR` (always writable for the user running the controller), so there
  # is exactly ONE branch: stdout → `tree`, stderr → `tree_err`. If even that cannot be created, the
  # probe still runs with stderr discarded and the absent-owner signal is simply UNOBSERVABLE — the
  # census stays UNKNOWN and the caps binding, which is the pre-change behaviour and the safe side.
  tfile="${TMPDIR:-/tmp}/.wt-tree-err.$$"
  if { : >"$tfile"; } 2>/dev/null; then
    tree="$(cmux tree --json 2>"$tfile")" || tree=""
    tree_err="$(cat "$tfile" 2>/dev/null || true)"
    rm -f "$tfile" 2>/dev/null || true
  else
    tree="$(cmux tree --json 2>/dev/null)" || tree=""
    tree_err=""
  fi
  # ⛔ READABILITY IS THE PROBE'S ANSWER, NOT "the daemon printed something". A reply the parser
  # cannot decode (a banner line before the JSON, a shape that drifted between cmux builds — the
  # header already records that the id shape differs) yields an EMPTY table while `$tree` is
  # non-empty, and treating that as a successful read concluded `dead` for every terminal record:
  # the caps stopped binding and `wt_close` deleted a live worker's record. `probe_ok` is what the
  # polarity rule below gates on, so an unparseable answer is UNKNOWN — alive, caps binding, and a
  # close that cannot be proven.
  probe_ok=0
  names=""; nrc=3
  if command -v tmux >/dev/null 2>&1; then names="$(wt_tmux_names)" && nrc=0 || nrc=3; else nrc=0; fi
  if [ -n "$tree" ]; then
    if raw="$(printf '%s\n' "$tree" | wt_tree_probe)"; then probe_ok=1; else raw=""; fi
  else
    # NOTHING IS LISTENING => NOTHING IS RUNNING. ⛔ ONLY THE TWO SHAPES THAT NAME AN ABSENT SERVER
    # COUNT — `Connection refused` (measured: a socket file with no listener, `os error 111`) and
    # `no server running` (the CLI's own semantic answer, the same polarity `wt_tmux_names` gives).
    # ⛔ AND **NOT** THE WRAPPER (`cannot connect to session socket …`): it is errno-agnostic, so it
    # also carries `No such file or directory` (a repointed HOME, a wrong/unlinked socket path) and
    # `Permission denied` — BOTH reachable while the daemon and its terminals are ALIVE. Emptying the
    # census on those deletes a lived worker's record and stops every cap binding, which is the P1
    # incident the tmux half's header records (`error connecting` = unreadable). A banner, a drifted
    # shape, `cmux: cannot read`, a missing binary (127) or any other failure stays UNKNOWN too.
    # ⛔ AND ONE SAMPLE IS NOT A STATE (review round 5 of #2653; this repo's own rule: "a measurement
    # artifact is not a state — never take a destructive action from a first-match reading"). Terminal
    # records carry no pid, so once this read concludes `dead` the record can only be judged by the
    # owner: a HARD-KILLED daemon never closes its ptys or signals its children, so an orphaned worker
    # could still be running while the harness frees its slot and deletes its handle — and a restart
    # window is seconds. So the absent answer is CONFIRMED by two samples at least WT_ABSENT_CONFIRM
    # apart; the first one only opens the window (still UNKNOWN, caps binding), and a readable census
    # closes it. Two controller cycles (CYC=240) always span the default, so the 26h stall is fixed
    # while a single refusal sample cannot empty the census.
    case "$tree_err" in
      *'Connection refused'*|*'no server running'*)
        # ⛔ A FAILED CLOCK MUST NOT BECOME THE LITERAL `0` (review round 12 of #2653, P1): `|| echo 0`
        # handed a failure STRAIGHT THROUGH the digit guard below, PERSISTED `0` as the stamp, and the
        # already-elapsed arm then confirmed on ONE real sample with zero elapsed window — the exact P1
        # the two-sample rule exists to prevent, on the state that survives the process. Capture the
        # STATUS, so a failure lands in the fail-closed `-z` branch.
        absent_now="$(date +%s 2>/dev/null)" || absent_now=""
        # ⛔ A FAILED CLOCK MUST NOT EMPTY THE CENSUS OR POISON THE STAMP (review round 11 of #2653, P2):
        # a `date` printing a diagnostic makes `$(( 10#… ))` error — `wt_table` aborts before printing,
        # and an empty table is read as "no workers" — and the failure would then PERSIST the stamp `0`,
        # which the read arm treats as an already-elapsed window, confirming on ONE real sample. Guard it
        # and refuse to open a window on an unusable clock: the record stays UNKNOWN (fail-closed).
        case "$absent_now" in ''|*[!0-9]*) absent_now="" ;; esac
        if [ -z "$absent_now" ]; then :; else
        # ⛔ TWO VALUES, BECAUSE ONE COULD NOT TELL "A GAP" FROM "STILL ABSENT" (review round 14 of
        # #2653, P2). The file used to hold only FIRST-SEEN. With a single value, a CONTINUOUS outage
        # longer than `WT_ABSENT_STALE_MIN` looked like a gap: the stamp aged past the bound, the
        # staleness rule re-opened the window, and the rows flipped `dead` → `unknown` for a full
        # `WT_ABSENT_CONFIRM` before confirming again — so the release was a DUTY CYCLE (measured at the
        # defaults: ~900s dead, ~60s unknown, repeating), i.e. the 26h stall reduced to one cycle in four
        # rather than ended. Format: "<first_seen> <last_absent>". A legacy single-value file (an older
        # harness) reads as first_seen with an empty last_absent → continuity is judged on first_seen (so a
        # deploy that restarts the controller MID-OUTAGE still releases rather than starting the clock
        # again), which is the safe reading for a file this build did not write.
        absent_since=""; absent_last=""
        if [ -f "$dir/.wt-absent-since" ]; then
          read -r absent_since absent_last < "$dir/.wt-absent-since" 2>/dev/null || true
        fi
        case "$absent_since" in ''|*[!0-9]*) absent_since="" ;; esac
        case "$absent_last"  in ''|*[!0-9]*) absent_last=""  ;; esac
        # ⛔ AND IT IS `10#`-NORMALISED TOO (review round 15 of #2653, P1): `_cont` is used as a bare
        # arithmetic VARIABLE, which re-parses its value as an expression — `08` is read as OCTAL, the
        # expansion errors, and `wt_table` ABORTS BEFORE IT PRINTS. Every later read hits the same field
        # (nothing repairs the file during an outage), so the census stays EMPTY: `wt_count` 0 (caps stop
        # binding) and `wt_alive` "not alive", so `wt_close` deletes a record it never looked at. This is
        # the field BOTH writers emit, so it is the normal case — the guard existed one line away for
        # field 1 and not for field 2.
        if [ -n "$absent_last" ]; then absent_last=$(( 10#$absent_last )); fi
        # ⛔ `08` PASSES THE DIGIT GUARD AND THEN ABORTS THE ARITHMETIC (review round 8 of #2653, P2):
        # `$(( … ))` reads a leading zero as OCTAL, `08` is not octal, the expansion errors and the
        # FUNCTION ABORTS before printing a table — an EMPTY census, which every consumer reads as "the
        # box has no workers" (caps stop binding, `wt_close` deletes a record it never looked at). The
        # `10#` normalisation is the same one `floor_norm` uses, and it is also why `is_num` refuses a
        # leading zero. ⛔ AND IT APPLIES ONLY TO A STAMP THAT EXISTS — normalising an EMPTY stamp would
        # turn it into `0` (an already-elapsed window) and confirm on the FIRST sample, which is the
        # single-sample conclusion this whole rule forbids.
        absent_now=$(( 10#${absent_now:-0} ))
        # ⛔ NORMALISE A PRESENT STAMP BEFORE ANY ARITHMETIC (see the `08` note below): the stale check
        # immediately below does subtraction, so an `08` would abort here instead of there.
        if [ -n "$absent_since" ]; then absent_since=$(( 10#$absent_since )); fi
        # ⛔ A STALE STAMP IS NOT CONTINUITY (review round 9 of #2653, P1). The stamp records when an
        # absent owner was FIRST seen; nothing requires it to belong to the CURRENT outage. If the owner
        # was absent at T0, came back while NOTHING read the census (a deploy restarted the controller, a
        # cycle froze in a hung probe), and went absent again, the first sample of the later outage found
        # an ancient stamp and confirmed immediately — a single-sample `dead`, which frees every cap and
        # lets `wt_close` delete a live worker's record.
        # ⛔ AND A FUTURE STAMP IS NOT CONTINUITY EITHER (review round 10 of #2653): after an NTP step or
        # a VM snapshot restore the subtraction is negative, so neither the staleness check nor the
        # confirm test fires and the release is pinned for the whole skew — the stall this change ends,
        # in the fail-closed direction. A non-monotonic stamp is discarded like a stale one.
        # ⛔ AND THE EMPTINESS TEST IS A `case`, NOT `[ … -gt 0 ]` (review round 10): `[` on an empty
        # value prints its own diagnostic on EVERY window opening — the per-read bash noise silenced
        # everywhere else in this file. A stamp of literally `0` IS an already-elapsed window, kept.
        # ⛔ AND A `0` STAMP IS NOT A SPECIAL CASE (review round 12 of #2653): the old `0) : ;;` arm kept
        # it as an "already-elapsed window", which is exactly what let a failed clock (persisted as 0)
        # confirm on the next sample. Judged by the ordinary staleness rule a `0` is older than
        # `WT_ABSENT_STALE_MIN` on any real clock, so it is discarded → first sample → fail-closed, and
        # epoch-zero / NTP-step inputs are covered by the same rule. (No suite writes a `0` stamp: every
        # fixture writes `now - N`.)
        # The continuity datum is `last_absent` when the file carries two values (this build), else
        # `first_seen` (a legacy stamp). A FUTURE value, or one older than the bound, breaks continuity.
        _cont="${absent_last:-$absent_since}"
        case "$_cont" in
          '') : ;;
          *)  if [ "$_cont" -gt "$absent_now" ] \
                 || [ $(( absent_now - _cont )) -gt "$WT_ABSENT_STALE_MIN" ]; then
                absent_since=""; absent_last=""
              fi ;;
        esac
        if [ -z "$absent_since" ]; then
          # ⛔ NAMED, NOT SWALLOWED (review round 6 of #2653, P2): if the window cannot be persisted
          # every sample restarts it, the comparison never elapses, and the census stays UNKNOWN for
          # ever — exactly the 26h stall this change exists to end, with nothing saying so. `wt_warn`
          # writes to stderr AND `$LOG`, which is where that stall would have been visible.
          # ⛔ LATCHED (review round 9 of #2653, P2): the write fails on EVERY attempt, so an unlatched
          # warning is ~250 B per census read (~12/cycle, ~1 MB/day) into the append-only, never-rotated
          # log — the same hazard this file just removed bash's own per-read diagnostic for. Named once
          # per process; the state is still visible in stderr and `$LOG`.
          # A successful write RE-ARMS the warning (the next inability to confirm is a new fact).
          { printf '%s %s\n' "$absent_now" "$absent_now" > "$dir/.wt-absent-since"; } 2>/dev/null \
            && rm -f "${TMPDIR:-/tmp}/.wt-warned-absent-window.$$" 2>/dev/null \
            || { _wl="${TMPDIR:-/tmp}/.wt-warned-absent-window.$$"
                 # ⛔ THE LATCH IS A FILE, NOT A VARIABLE (review round 10 of #2653, P2): every consumer
                 # calls `wt_table` in a COMMAND SUBSTITUTION (`$(wt_table)`, `wt_table | awk`), i.e. in a
                 # subshell, so an in-process variable was assigned and discarded on every read — the
                 # warning fired per read, ~12/cycle, ~1 MB/day into the append-only log. `$$` is the
                 # parent's pid and is stable across those subshells, so this file latches.
                 [ -e "$_wl" ] || { : >"$_wl" 2>/dev/null || true; wt_warn "census absent-window UNWRITABLE at $dir/.wt-absent-since — the review/fix caps cannot free until $dir is writable (the absent owner is real but cannot be CONFIRMED); logged once per process"; }; }
          absent_since="$absent_now"; absent_last="$absent_now"
        else
          # CONTINUOUS absence: refresh ONLY the continuity datum, so the window never ages past the
          # staleness bound while the outage lasts — and keep `first_seen`, which is what the two-sample
          # confirmation measures.
          { printf '%s %s\n' "$absent_since" "$absent_now" > "$dir/.wt-absent-since"; } 2>/dev/null || true
          absent_last="$absent_now"
        fi
        # ONE comparison, always: an ALREADY-ELAPSED stamp confirms on THIS sample — that is how an
        # operator declares "this outage has lasted", and how the fixtures say it. ⛔ THE KNOB'S `0` DOES
        # NOT: it is coerced to 60 above (review round 7), because zero would confirm on one sample.
        # This comment claimed the suites set the knob to 0 — they did exactly the opposite, BECAUSE of
        # round 7, and a reader looking for that debugging switch would think the knob was broken
        # (review round 13).
        [ $(( absent_now - absent_since )) -ge "$WT_ABSENT_CONFIRM" ] && probe_ok=1
        fi ;;
      # ⛔ ANY OTHER ANSWER CLOSES THE WINDOW TOO (review round 8 of #2653, P2). It used to close only
      # on a READABLE tree, so an answer that proves nothing either way — the
      # `cannot connect … No such file or directory` wrapper this module deliberately treats as UNKNOWN,
      # a banner — left an ANCIENT stamp standing; the next absent sample then confirmed immediately, a
      # single-sample conclusion reached through a recovery path. Closing here means an outage whose
      # messages alternate restarts the timer: the fail-CLOSED direction (caps bind longer).
      *) rm -f "$dir/.wt-absent-since" 2>/dev/null || true ;;
    esac
  fi
  # …and a readable census closes it as well (the owner answered).
  [ -n "$tree" ] && rm -f "$dir/.wt-absent-since" 2>/dev/null || true
  # Records. A terminal record is resolved by its TERMINAL ID first (the only handle the surface
  # grammar has), then by the workspace name (the layout grammar, and records predating the id).
  # An unreadable probe is UNKNOWN — never dead: see the polarity rule in the header.
  for f in "$dir"/worker-*; do
    [ -f "$f" ] || continue
    name="${f##*/worker-}"
    case "$name" in ''|*[!A-Za-z0-9-]*) continue ;; esac
    kind="$(sed -n 's/^kind=//p' "$f" 2>/dev/null | head -1)"
    id="$(sed -n 's/^id=//p' "$f" 2>/dev/null | head -1)"
    if [ "$kind" = "tmux" ]; then
      if [ "$nrc" -ne 0 ]; then st=unknown
      # ⛔ HERE-STRING, NOT A PIPE (scripts/check-no-sigpipe-grep.sh): `producer | grep -q` lets grep
      # exit on first match, the producer takes SIGPIPE, and under `pipefail` a MATCH then reads as a
      # failure — a live worker read as dead. Every occurrence in this repo is guarded (#841/#864).
      elif grep -qx -- "$name" <<<"$names"; then st=alive
      else st=dead; fi
    else
      if [ "$probe_ok" = "1" ]; then st=dead; else st=unknown; fi
      if [ -n "$id" ]; then
        case "$(printf '%s\n' "$raw" | awk -F'\t' -v n="t:$id" '$1==n{print $2; exit}')" in
          alive) st=alive ;; dead) st=dead ;; esac
      fi
      case "$(printf '%s\n' "$raw" | awk -F'\t' -v n="w:$name" '$1==n{print $2; exit}')" in
        alive) st=alive ;; dead) st=dead ;; esac
    fi
    tbl="$tbl
$name	$st"
  done
  # Workspace-name rows from the daemon, keyed by the worker name: a worker whose RECORD was lost (a
  # wiped $O/state, a lane started by an older harness) is still counted and still reaped. Without
  # this the census would be ledger-only, which leaks exactly those — this is why the workspace name
  # is worth having even though the surface grammar has none.
  # ⛔ `raw`, NOT `tbl`: the probe's `w:`/`t:` rows are the census's INTERNAL key spaces (a lookup
  # handle for a record, and for a surface that has no name). They must never reach the table this
  # function PRINTS — `report.sh` counted rows, so one cmux worker read as `sessions: 3` (its `w:`
  # row, its `t:` row and its name), and any operator reading the table saw the same triple.
  while IFS="$(printf '\t')" read -r _wt_k _wt_v; do
    case "$_wt_k" in w:*) _wt_k="${_wt_k#w:}" ;; *) continue ;; esac
    case "$_wt_k" in ''|*[!A-Za-z0-9-]*) continue ;; esac
    tbl="$tbl
$_wt_k	$_wt_v"
  done <<EOF
$raw
EOF
  # tmux sessions with a worker prefix and no record of their own (a lane started by an older
  # harness, or by hand). Counted and reaped like any other worker — the name is the contract. Only
  # when the read SUCCEEDED: an unreadable session list enumerates nothing, and inventing rows from
  # it would be the same fail-open this section's polarity rule forbids.
  if [ "$nrc" -eq 0 ]; then
    while IFS= read -r name; do
      # ⛔ `''` IS IN THE SKIP PATTERN, not in a shared empty arm: `case "" in ''|lane-*…) ;; *) continue`
      # falls THROUGH on the empty match, so the normal "no sessions" answer (one blank line) added a
      # phantom `\talive` row to the census. Consumers filter a nameless row, so it only added noise —
      # but noise in the one table every cap, liveness answer and reap reads is not worth keeping.
      # ⛔ `chain-*` IS IN THIS LIST (review finding on this diff): dispatch-merge.sh spawns
      # `chain-<N>` workers and counts them (`wt_count lane- chain-`), but a chain session with no
      # RECORD — a wiped $O/state, an older harness, a hand-start — was invisible here, so the census
      # under-counted it and the cap it feeds was softer than it claimed. Pre-existing, and more
      # load-bearing now that tmux is the only surface on a cell.
      # ⛔ `review-*` IS IN THIS LIST TOO (agent-infra#2971): the controller now dispatches a review
      # ORDER under that tag instead of reusing `merge-<PR>`, and a session with no RECORD of its own
      # (a wiped $O/state, a hand start) is invisible here — which would silently UNDER-count the
      # review ceiling this census feeds, making the cap softer than it claims.
      case "$name" in lane-*|merge-*|review-*|fix-*|chain-*) ;; *) continue ;; esac
      case "$name" in *[!A-Za-z0-9-]*) continue ;; esac
      # ⛔ IN-SHELL MEMBERSHIP, not `printf | awk` per line: a listing that STREAMS (the
      # cloud-cell-supervisor fixture streams 60k lines to prove no SIGPIPE fail-open) made this loop
      # one fork per name. The table is a few dozen rows, so a substring test is the cheap form.
      case "
$tbl
" in *"
$name	"*) continue ;; esac
      tbl="$tbl
$name	alive"
    done <<EOF
$names
EOF
  fi
  WT_TABLE="$(printf '%s\n' "$tbl" | sed '/^$/d' | awk -F'\t' 'NF==2 && !seen[$1]++')"
  WT_TABLE_AT="$now"
  # ⛔ THE `2>/dev/null` MUST APPLY TO THE GROUP, NOT SIT AFTER THE `>` (review round 8 of #2653, P2):
  # a failing `>` open prints bash's own diagnostic on the PRE-COMMAND stderr, which a redirect placed
  # after it never sees — so an unwritable `$dir` emitted raw bash noise on EVERY census read (~12 per
  # controller cycle) into an append-only, never-rotated log. Measured: the group form silences it and
  # keeps the same status.
  { { printf '# at=%s\n' "$now"; printf '%s\n' "$WT_TABLE"; } > "$cache.tmp.$$"; } 2>/dev/null \
    && mv -f "$cache.tmp.$$" "$cache" 2>/dev/null || rm -f "$cache.tmp.$$" 2>/dev/null
  printf '%s\n' "$WT_TABLE"
}

# wt_alive <name> — 0 when the worker is ALIVE or UNKNOWN, 1 when it is DEAD or unknown-to-this-box.
# An absent name is NOT a worker: `sess "fix-42"` for a PR with no worker must answer NO.
wt_alive() {
  local n="${1:-}" st
  [ -n "$n" ] || return 1
  st="$(wt_table | awk -F'\t' -v n="$n" '$1==n{print $2; exit}')"
  case "$st" in
    dead) return 1 ;;
    alive|unknown) return 0 ;;
    *) return 1 ;;
  esac
}

# wt_count <prefix>... — LIVE workers whose name starts with any of the prefixes. This is the
# concurrency census; unknown counts as live so a daemon read failure can never raise the ceiling.
wt_count() {
  local re="" p
  [ "$#" -gt 0 ] || { echo 0; return 0; }
  for p in "$@"; do case "$p" in ''|*[!A-Za-z0-9_-]*) continue ;; esac; re="$re${re:+|}^$p"; done
  [ -n "$re" ] || { echo 0; return 0; }
  wt_table | awk -F'\t' -v re="$re" '$1 ~ re && $2 != "dead" {n++} END{print n+0}'
}

# ── spawn ────────────────────────────────────────────────────────────────────────────────────
# The env snapshot: everything the controller exports, plus O (which the controller sets but does
# NOT export — a worker falling back to $HOME/orchestrator is how a box silently runs a different
# harness). Mode 0600 and removed with the worker: it carries the same secrets as the cell's keys.env.
#
# ⛔ THE uv PIN IS EMITTED AFTER `export -p`, AND THAT POSITION IS THE WHOLE POINT (agent-infra#2159).
# A lane is the process that runs `uv sync`, so it is the one that decides whether a worktree's `.venv`
# is hardlinked to the cache or MATERIALISED as a full copy (~5.8 GB measured on a cold-cache cell).
# `export -p` carries whatever the CONTROLLER happened to have; on a box where nobody pinned the cache
# that is nothing, and a cold cache is then invisible: measured, cell-3 went 17 GB free -> 257 MB free
# in ~50 minutes as its lanes synced. Emitting the pin LAST means an operator's value in the
# controller's environment still WINS (`uv_env_apply` only fills what is unset), while a box that
# never set it gets the repo's default instead of the filesystem's accident.
# The helper is a SIBLING file; if it cannot be read the two lines below are emitted from the same
# one-line formula rather than dropped — a worker must never be launched into a different cost regime
# because a helper went missing, and a silent drop here is exactly the failure this pin exists for.
wt_uv_env_lines() {
  local here helper
  here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd -P)"
  helper="$here/uv-env.sh"
  if [ -n "$here" ] && [ -r "$helper" ]; then
    UV_CACHE_DIR="${UV_CACHE_DIR:-}" UV_LINK_MODE="${UV_LINK_MODE:-}" bash -c '. "$1" >/dev/null 2>&1; uv_env_export_lines' _ "$helper" 2>/dev/null && return 0
  fi
  wt_warn "uv-env.sh not readable beside worker-terminal.sh — emitting the cache/link-mode pin from the inline default (the pin itself is not optional, agent-infra#2159)"
  printf 'export UV_CACHE_DIR=%s\n' "$(wt_q "${UV_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/uv}")"
  printf 'export UV_LINK_MODE=%s\n' "$(wt_q "${UV_LINK_MODE:-hardlink}")"
}

wt_env_snapshot() { # <name> -> prints the path
  local dir f
  dir="$(wt_dir)"; mkdir -p "$dir" 2>/dev/null || return 1
  f="$dir/env-$1.sh"
  ( umask 077
    { export -p; printf 'export O=%s\n' "$(wt_q "${O:-}")"; wt_uv_env_lines; } > "$f" ) 2>/dev/null || return 1
  chmod 600 "$f" 2>/dev/null || true
  printf '%s\n' "$f"
}

# THE RUN SCRIPT — one file per worker, and the ONLY thing the surface is asked to execute.
# Why a file rather than an inline command line: the layout grammar TYPES its command into a login
# shell, so the text has to be shell-parseable at the top level (wrapping it in one quoted word runs a
# COMMAND NAMED by the whole line — `command not found`, measured), it has to stay short (a terminal's
# canonical-mode line limit is a few KiB), and an operator debugging "what did this worker actually
# run?" must be able to READ it. So: `cd` first (a login shell starts in the daemon's idea of cwd),
# then the env snapshot under `set -a` (keys.env's own idiom), then the caller's command; the worker's
# exit status is the script's, so it becomes the terminal's.
wt_runfile() { # <name> <cwd> <envfile> <command> -> prints the path
  local dir f
  dir="$(wt_dir)"; mkdir -p "$dir" 2>/dev/null || return 1
  f="$dir/run-$1.sh"
  {
    printf '#!/usr/bin/env bash\n# worker %s, launched %s by worker-terminal.sh — the exact command this worker runs\n' \
      "$1" "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
    printf 'cd %s || exit 97\n' "$(wt_q "$2")"
    printf 'set -a; . %s || exit 98; set +a\n' "$(wt_q "$3")"
    printf '%s\n' "$4"
  } > "$f" 2>/dev/null || return 1
  chmod 700 "$f" 2>/dev/null || true
  printf '%s\n' "$f"
}

wt_spawn() { # wt_spawn <name> <cwd> <command...>  -> 0 spawned, 1 not spawned (reason on stderr)
  local name cwd cmd kind grammar dir envf runf doc out id ws home envpfx srv_val srv_pvar srv_pval pre_rc preout premsg pre_where spout spmsg _larc _lamsg _recovered _ensrc _ensclaim _enscmd
  [ "$#" -ge 3 ] || { wt_warn "wt_spawn needs <name> <cwd> <command>"; return 1; }
  name="$1"; cwd="$2"; shift 2; cmd="$*"
  wt_name_ok "$name" || { wt_warn "refusing a worker name with anything but [A-Za-z0-9-]: '$name'"; return 1; }
  dir="$(wt_dir)"
  kind="$(wt_launcher)"
  case "$kind" in
    none)
      # ⛔ THE MESSAGE CARRIES WHAT THE PROBE ACTUALLY ANSWERED, not whether a binary exists (review
      # finding, 2026-10-23; issue #2210's own reopen asks for "`cmux tree` rc, `tmux` presence,
      # `uname`"). `command -v cmux` is TRUE on every cloud cell — #2368's condition is precisely "the
      # binary exits, the daemon does not answer" — so a presence test sent the operator to the wrong
      # fault. The rc is re-measured here (the refusal is the rare path, and `wt_launcher` runs in a
      # command substitution, so it cannot hand a variable back).
      _cmrc=127
      if command -v cmux >/dev/null 2>&1; then _cmrc=0; cmux tree --json >/dev/null 2>&1 || _cmrc=$?; fi
      wt_warn "REFUSED $name: no worker surface on this host — \`cmux tree --json\` does not answer (cmux tree rc=$_cmrc$(command -v cmux >/dev/null 2>&1 && echo ', binary present' || echo ', no binary')) AND there is no tmux binary, so there is nothing to start a worker in (checked: uname=$(uname -s 2>/dev/null || echo unknown), tmux=$(command -v tmux >/dev/null 2>&1 && echo present || echo absent)) — why: $(wt_launcher_why)"
      return 1 ;;
    tmux)
      # The launchd Mac surface and the Linux cell (see wt_launcher) — WITH the environment contract.
      # ⛔ Never `cd CWD && CMD` alone: that inherits the tmux SERVER's environment, which carries no
      # `HOME=/tmp/cell-home` on a cell, so the worker has no gh credential and stops at line ~7
      # (measured 2026-10-22 — this file's header). The prefix is built by wt_launcher_env, and a box
      # that cannot produce one is REFUSED rather than started credential-less.
      home="$(wt_launcher_home)" || home=""
      if [ -z "$home" ]; then
        wt_warn "REFUSED $name: tmux is present but there is no HOME to run a worker with (WT_WORKER_HOME and HOME are both unset) — a worker with no HOME has no gh credential and no pi config, so it would stop at its first call rather than do any work"
        return 1
      fi
      envpfx="$(wt_launcher_env "$home")" || {
        # ⛔ THE MESSAGE NAMES THE FILE THE PROBE ACTUALLY READ (review finding, 2026-10-23): it used to
        # hardcode `$home/.config/gh/hosts.yml` while the probe goes through `wt_gh_hosts` (GH_CONFIG_DIR,
        # then XDG_CONFIG_HOME, then `$HOME/.config/gh`) — so on a repointed box the operator was sent to
        # a path that does not exist. A refusal must name the places it looked, not a guess at them.
        # ⛔ AND IT MUST NOT NAME A CAUSE IT DID NOT ESTABLISH (measured 2026-10-27, found by review of the
        # model-credential gate): `wt_launcher_env` refuses on EITHER credential, so this line — which
        # hardcoded "the worker would have NO gh credential" — told the operator to fix a gh credential
        # that was FINE whenever the refusal was the provider. Both surfaces are named here, the gates'
        # own REFUSED line above carries the specific one, and this line says which question it answered
        # ("the environment contract could not be built") rather than guessing at the answer.
        wt_warn "REFUSED $name: tmux can start a session here, but \`wt_launcher_env\` could NOT build the worker's environment contract — so the worker is not started. The gate's own REFUSED line ABOVE names which credential failed. Both surfaces it requires: (1) a gh credential — checked $(wt_gh_hosts "$home") (no readable oauth_token), $home/keys.env (no GH_TOKEN/GITHUB_TOKEN value), this caller's own GH_TOKEN/GITHUB_TOKEN (only when this spawn creates the server) and the tmux server's GH_TOKEN/GITHUB_TOKEN; (2) the LANE MODEL credential — the \$<VAR> named by $home/.pi/agent/models.json for provider '$(wt_lane_provider "$home")', which was absent from this caller's environment, $home/pi-keys.env and $home/keys.env. A lane started without either stops at its first call (the '~21-line death' agent-infra#2210 recorded, or pi's 'No API key found for …' at 2-10s); put the credential where the worker can read it, or set WT_WORKER_HOME to the HOME that holds it"
        return 1
      }
      # ⛔ THE LAUNCH LINE IS EXECUTED ONCE ON THE CALLER'S SIDE, BEFORE `new-session` (P1 review finding,
      # 2026-10-23, MEASURED). Every guard inside the prefix — the `[ -r ]`/`bash -n` check, the
      # post-source blank clear, and the `gh auth token` fallback — runs INSIDE the pane, and
      # `tmux new-session -d` returns 0 as soon as the SESSION OBJECT exists. Measured on the pre-fix
      # head, twice: (i) a token-bearing hosts.yml on a box whose PATH has no `gh` — the store credit was
      # granted, the pane exited 98 at the fallback, and `wt_spawn` returned 0 and wrote `kind=tmux`;
      # (ii) a keys.env line that the static grep credits but the source never executes — same outcome.
      # That is the dead-lane-reported-provisioned this change exists to remove, one layer below the
      # launcher: the refusal was real, and INVISIBLE. So the prefix runs once here and a non-zero
      # REFUSES the spawn before any session is created.
      # ⛔ THE PROBE MUST SEE WHAT THE PANE WOULD INHERIT, not what the caller happens to hold — FOR
      # EVERY CREDENTIAL, not just gh (P1 review finding, 2026-10-27, MEASURED). On the server-token arm
      # the credential comes from the tmux SERVER's global environment (the prefix neither exports it nor
      # reads a file for it), so the server's value is injected here; on every other arm the prefix pins
      # or clears the names itself, which makes the injection inert.
      # ⛔ AND THE MODEL CREDENTIAL NEEDS THE SAME INJECTION, with the same argument (measured): the gate
      # credits a server-carried `$<VAR>` — the pane inherits it — and without the injection the prefix's
      # own model guard evaluated in a caller that holds neither, exited 98, and `wt_spawn` REFUSED a box
      # whose worker would have worked: `HOME=…(models.json names the var) pvar=[DEEPSEEK_API_KEY] SPAWN
      # rc=1 — REFUSED` against `rc=0` for the same box with no models.json. The invariant is that the
      # gate's answer and the pre-check's answer are the SAME answer on EVERY arm, so the pre-check is
      # given exactly the environment the pane would inherit: the caller's, plus the server's names.
      # Two branches rather than an argv array, so the words cannot be split by a value with a space.
      # ⛔ PATH IS PINNED IN THE CONTRACT (P1 review finding, 2026-10-23, MEASURED — this comment used to
      # claim the opposite, and it was wrong): the pre-check below runs in the CALLER's environment while
      # the pane runs in the SERVER's, so an unpinned PATH validated a different `gh` resolution than the
      # one the worker would use. Measured on tmux 3.4, a server created by `env -i`: the caller-side
      # prefix exits 0 (its PATH carries an answering `gh`) while the same prefix in the pane exits 98
      # (the server's PATH has no `gh`) — a spawn reported provisioned for a lane dead in its first
      # millisecond. `wt_launcher_env` now emits `export PATH=…`, so the two measure the same thing.
      srv_val="$(wt_tmux_server_token_value 2>/dev/null)" || srv_val=""
      # The model credential's name is whatever models.json resolves it from; asked of the SERVER for
      # that one name, the same question the gh arm asks for its two.
      srv_pvar="$(wt_provider_key_var "$home" 2>/dev/null)" || srv_pvar=""
      srv_pval=""
      [ -n "$srv_pvar" ] && { srv_pval="$(wt_tmux_server_token_value "$srv_pvar" 2>/dev/null)" || srv_pval=""; }
      # gh's value is injected under GH_TOKEN because that is the name the gate's guard reads first; the
      # model credential is injected under ITS OWN name (it is a different variable every box).
      pre_rc=0
      # ⛔ BOUNDED, because the prefix's own guard calls `gh` (see `wt_bounded`): an unbounded probe
      # here hangs the controller's spawn path instead of refusing it. rc 142/124 is a REFUSAL — no
      # session is created — which is the fail-closed direction.
      if [ -n "$srv_val" ] && [ -n "$srv_pvar" ] && [ -n "$srv_pval" ]; then
        preout="$(wt_bounded "${WT_PRE_TIMEOUT:-20}" env GH_TOKEN="$srv_val" "$srv_pvar=$srv_pval" bash -c "$envpfx; :" 2>&1 </dev/null)" || pre_rc=$?
      elif [ -n "$srv_val" ]; then
        preout="$(wt_bounded "${WT_PRE_TIMEOUT:-20}" env GH_TOKEN="$srv_val" bash -c "$envpfx; :" 2>&1 </dev/null)" || pre_rc=$?
      elif [ -n "$srv_pvar" ] && [ -n "$srv_pval" ]; then
        preout="$(wt_bounded "${WT_PRE_TIMEOUT:-20}" env "$srv_pvar=$srv_pval" bash -c "$envpfx; :" 2>&1 </dev/null)" || pre_rc=$?
      else
        preout="$(wt_bounded "${WT_PRE_TIMEOUT:-20}" bash -c "$envpfx; :" 2>&1 </dev/null)" || pre_rc=$?
      fi
      if [ "$pre_rc" -ne 0 ]; then
        premsg="${preout//$'\n'/ }"
        # ⛔ AND IT SAYS WHAT ENVIRONMENT IT JUDGED (P1 review finding, 2026-10-27). This pre-check runs in
        # the CALLER's environment PLUS the tmux server's own global names (what the pane inherits), and it
        # used to say nothing about that — so a refusal on the server-credential arm read as though the
        # caller were the problem, sending the operator to `pi-keys.env` when the value was one
        # `tmux show-environment -g` away. It names both inputs now, and the pane-side line above (carried
        # in ${premsg}) names the exact credential and every source that was checked.
        pre_where=""
        [ -n "$srv_val" ] && pre_where="GH_TOKEN"
        if [ -n "$srv_pvar" ] && [ -n "$srv_pval" ]; then pre_where="${pre_where:+$pre_where and }$srv_pvar"; fi
        if [ -n "$pre_where" ]; then
          pre_where=" (this caller's environment plus the tmux SERVER's own global $pre_where, which is what the pane inherits)"
        else
          # ⛔ THE SERVER'S ANSWER IS THREE-VALUED, so the REFUSAL may not assert absence (review finding,
          # 2026-10-28). An empty `srv_val`/`srv_pval` collapses three different states — the server holds
          # neither name, there IS no server, and the probe could not answer at all (`wt_bounded` fired,
          # rc 142/124; or no `tmux`). The old wording said "the tmux server carries neither name" for all
          # three, i.e. it named a cause it had not established, which is the rule this file states for
          # itself at the launcher and `env` sites. `wt_tmux_has_server` is the existing three-valued
          # probe (0 = answers · 1 = none · 3 = no answer), so it decides the clause.
          local _pwrc=0
          wt_tmux_has_server || _pwrc=$?
          case "$_pwrc" in
            0) pre_where=" (this caller's environment; a tmux server ANSWERED and carries neither name)" ;;
            1) pre_where=" (this caller's environment; no tmux server answers on this socket, so the pane inherits only this)" ;;
            *) pre_where=" (this caller's environment; the tmux server did NOT answer within ${WT_PROBE_TIMEOUT:-15}s, so what it carries is UNKNOWN — not established as absent)" ;;
          esac
        fi
        wt_warn "REFUSED $name: the credential contract this launch line carries FAILS when it is executed (rc=$pre_rc), so the worker would die at once and be recorded as a started lane. The pre-check ran with the environment the PANE would inherit$pre_where — so this is not a caller-side artefact, and the pane-side line carried below names the credential and every source it checked: ${premsg:0:300}"
        return 1
      fi
      # ⛔ THE SHELL-COMMAND MUST BE ONE ARGUMENT (P0 review finding, 2026-10-23, MEASURED). tmux runs
      # a SINGLE shell-command argument through the shell, but a MULTI-argument command is exec'd
      # DIRECTLY — so the three-word form `bash -c "'<line>'"` handed bash a literally single-quoted
      # word as its command string, bash looked for a command by that name, and every pane died with
      # status 127 while `new-session -d` still returned 0 (spawn rc=0, record written, nothing running:
      # the dead-lane-reported-provisioned this PR exists to remove). `bash -c $(wt_q LINE)` is ONE argv,
      # so tmux's shell unquotes it exactly once and bash parses the line the pre-check validated.
      if spout="$(wt_bounded "${WT_SPAWN_TIMEOUT:-30}" tmux new-session -d -s "$name" "bash -c $(wt_q "$envpfx; cd $(wt_q "$cwd") && $cmd")" 2>&1)"; then
        mkdir -p "$dir" 2>/dev/null || true
        # ⛔ THE RECORD IS CHECKED, like the durable-terminal arm's (P2 review finding, 2026-10-23): a
        # spawn that returns 0 without a record is an UNTRACKABLE worker — no census, no cap, no reap —
        # and `home=` is the field this change added for the operator's audit. A session we cannot
        # record is closed again rather than leaked.
        if printf 'kind=tmux\nhome=%s\ncwd=%s\ncreated=%s\n' "$home" "$cwd" "$(date +%s)" > "$dir/worker-$name" 2>/dev/null; then
          wt_forget
          return 0
        fi
        # ⛔ EXACT TARGET (`=$name`) — P1 review finding, 2026-10-23, MEASURED: a bare `-t` is a PREFIX
        # match, and `tmux kill-session -t fix-8` really does kill a live `fix-82` (rc 0). This is the
        # cleanup of THIS spawn's own session, and `wt_close` already pins `=$name` for the same reason —
        # a cleanup that can kill a peer's mid-work lane is worse than the untracked session it closes.
        # (A pre-existing same-name session is impossible here: `new-session -s fix-8` against a live
        # `fix-8` answers `duplicate session` rc 1, so rc 0 above proves the session is this spawn's.)
        wt_bounded "${WT_SPAWN_TIMEOUT:-30}" tmux kill-session -t "=$name" >/dev/null 2>&1 || true
        wt_warn "REFUSED $name: the tmux session started but its record in $dir could not be written, so the worker would be untrackable (no census, no cap, no reap) — the session was closed again"
        return 1
      fi
      # ⛔ tmux's OWN ANSWER IS CARRIED (P2 review finding, 2026-10-23): every other refusal in this file
      # names what it read. On a cell tmux is the only surface, so "tmux could not start X" with the
      # reason discarded (a permission-broken socket dir answers `directory … has unsafe permissions`)
      # is the one diagnostic that matters most where it was missing.
      spmsg="${spout//$'\n'/ }"
      wt_warn "REFUSED $name: tmux could not start it: ${spmsg:0:300}"
      return 1 ;;
    terminal) : ;;
    *) wt_warn "REFUSED $name: unreadable launcher '$kind'"; return 1 ;;
  esac

  envf="$(wt_env_snapshot "$name")" || { wt_warn "REFUSED $name: cannot write the env snapshot in $dir"; return 1; }
  runf="$(wt_runfile "$name" "$cwd" "$envf" "$cmd")" || { wt_warn "REFUSED $name: cannot write the run script in $dir"; rm -f "$envf"; return 1; }
  grammar="$(wt_grammar)"
  if [ "$grammar" = "surface" ]; then
    # The primitive named in the incident report, for a CLI that has it: a durable terminal on the
    # given machine, in the given cwd, no window. The id shape differs between cmux builds, so it is
    # PARSED and the failure is explicit — an untracked terminal cannot be reaped.
    set -- surface new-terminal
    # ⛔ `--machine` IS MANDATORY IN CURRENT cmux, AND OMITTING IT REFUSES EVERY SPAWN.
    # The flag used to be added only when WT_MACHINE was set, so a box that never set it got
    # `cmux surface new-terminal: --machine <id|local> is required` on EVERY spawn — measured
    # 2026-10-29 on the Mac: 6 spawns refused in one pass while the controller read healthy and
    # simply never started a worker. `local` is the machine this process runs on, i.e. exactly
    # what the omitted flag used to mean; an explicit WT_MACHINE still wins.
    set -- "$@" --machine "${WT_MACHINE:-local}"
    set -- "$@" --cwd "$cwd" --no-open -- /bin/bash "$runf"
    out="$(cmux "$@" 2>&1)" || { wt_warn "REFUSED $name: cmux surface new-terminal failed: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-300)"; rm -f "$envf" "$runf"; return 1; }
    id="$(printf '%s\n' "$out" | grep -oE 'term_[A-Za-z0-9]+|surface:[0-9]+' | head -1)"
    [ -n "$id" ] || { wt_warn "REFUSED $name: cmux surface new-terminal printed no terminal id (nothing to track or reap): $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-300)"; rm -f "$envf" "$runf"; rm -f "$(wt_dir)/.wt-absent-since" 2>/dev/null || true; return 1; }
    ws=""
  else
    # The guest CLI's equivalent (see the header): one terminal surface, the run script typed into it.
    # `; exit` after it, because a typed line returns to the LOGIN SHELL's prompt when it finishes —
    # without it the terminal stays `running` forever and a finished worker looks alive.
    doc="$(python3 - "$name" "$cwd" "bash $(wt_q "$runf"); exit" <<'PY' 2>/dev/null
import json,sys
print(json.dumps({"layout":{"pane":{"surfaces":[{"type":"terminal","name":sys.argv[1],"cwd":sys.argv[2],"command":sys.argv[3]}]}}}))
PY
)"
    [ -n "$doc" ] || { wt_warn "REFUSED $name: cannot build the layout document"; rm -f "$envf" "$runf"; return 1; }
    # ⛔ A CREATE REFUSAL CARRIES THE READINGS THIS PROBE TOOK, NOT THE DAEMON'S OWN GUESS
    # (agent-infra#2404). The one-line version relayed `{"reason":"database or disk is full"}` as the
    # REASON — on a box with 28 G free, 25 % inodes used and a 37 M state dir — and sent every reader to
    # `df` while a three-day-old session owner stayed unable to allocate. So on failure: measure first,
    # name only what was measured, then (and only when the reading says the SESSION is the finding, and
    # never when the volume is short) recover the surface once and re-attempt the create once. The
    # re-attempt is safe against a half-created workspace: the target name is this worker's own, and a
    # workspace left by the FAILED attempt carries no record, so it cannot be confused with a tracked
    # worker. ⛔ The earlier draft also claimed `wt_close_named_surface` had already reaped it — IT HAS
    # NOT (review #3031 round 6, finding F5): that reap is reached only from `wt_close`'s tmux arm and
    # from the no-terminal_id branch, so a `wt-<name>` workspace created by the failed attempt survives a
    # successful re-attempt. Closing it here is deliberately NOT done: this path is reached without a
    # liveness re-check, so an unconditional reap of `wt-<name>` could end a LIVE lane holding that name —
    # the one thing this file never does. Recorded as a residual on #2404.
    _larc=0
    out="$(printf '%s\n' "$doc" | cmux layout apply --name "wt-$name" --cwd "$cwd" --json - 2>&1)" || _larc=$?
    if [ "$_larc" -ne 0 ]; then
      _lamsg="$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-300)"
      WT_PROBE_VERDICT=unreadable; WT_PROBE_LINE=""; WT_PROBE_SHORT=0; WT_PROBE_OWNER=unreadable
      WT_PROBE_SPACE_READ=0; WT_PROBE_INODE_READ=0; WT_PROBE_SIZE_READ=0
      WT_ENSURE_TRIES=0; WT_ENSURE_SEEN=""
      _recovered=""
      # The probe, and the recovery, are SKIPPED in exactly two cases, each for a reason:
      #   * `WT_SESSION_RECOVER=0` — the operator's off switch (an actuator an operator cannot stop is
      #     not an actuator an operator has);
      #   * the CLI has no `server` verb at all (the macOS host CLI) — there is nothing to probe and
      #     nothing to ensure, and pretending otherwise would invent a cause on the box that has no
      #     durable session in the first place.
      if [ "${WT_SESSION_RECOVER:-1}" = "0" ]; then
        # ⛔ NOT-READ IS A VERDICT, NOT THE ABSENCE OF ONE — see `wt_cmux_probe_reading`'s `not-run` arm.
        WT_PROBE_VERDICT=not-run
        # ⛔ THE OFF SWITCH MUST SAY WHAT IT DID NOT DO (review round 5, finding F2). Every other
        # refusal carries a `— recovery: …` clause; this branch left the residual to be inferred from
        # silence, so a reader could not tell whether a repair had been attempted.
        _recovered=" — recovery: NOT attempted, because the probe and the recovery are BOTH disabled on this box (\`WT_SESSION_RECOVER=0\`); unset it to let a spawn measure the box and repair the surface"
      else
        wt_cmux_probe
        # ⛔ THE RECOVERY RUNS ONLY WHERE A READING NAMES THE SESSION (review round 4, finding F2).
        # `WT_PROBE_VERDICT=unreadable` used to satisfy the gate below, so a daemon that did not answer
        # within `WT_SERVER_TIMEOUT` — the very state this path runs in — bought up to
        # `WT_SERVER_ENSURE_ATTEMPTS` ensure calls, a 2 s pause each, and a SECOND `cmux layout apply` on
        # the controller's synchronous spawn path, for a box the probe could not read at all. That is a
        # retry of a failure this file did not diagnose, which its own header and
        # `docs/ops/self-healing-contract.md` §3.8 both deny. So the gate is the VERDICT, not the
        # absence of a disqualifier: `owner-down` and `owner-running` are the two readings that put the
        # session on the hook (a stopped owner, or the cell-3 owner that answered and still could not
        # allocate); no reading, no retry.
        if [ "$WT_PROBE_SHORT" = "1" ]; then
          _recovered=" — recovery: NOT attempted, because restarting a session frees no space; reclaim the volume (the recorded lever for the FULL-volume variant is agent-infra#2312)"
        elif [ "$WT_PROBE_OWNER" = "unsupported" ]; then
          _recovered=" — recovery: NOT possible on this CLI (no \`server\` verb: \`cmux server --help\` answers 'Unknown command'), so nothing here could repair the surface and nothing here claims to have read it"
        else
          case "${WT_PROBE_VERDICT:-unreadable}" in
            owner-down|owner-running)
              # ⛔ THE ENSURE'S OWN EXIT STATUS IS KEPT, BECAUSE THE RECOVERED LINE IS EVIDENCE (review
              # #3031 round 6, finding F2). It used to be discarded (`|| true`) while the line said,
              # unconditionally, "the ensure answered on attempt N" — so with BOTH ensure attempts failing
              # and the re-attempted create succeeding anyway, the one line that exists to expose a box's
              # session-owner instability asserted a recovery that never happened: this change's own
              # defect class (an instrument stating a cause it did not check) inside the sentence that
              # reports the repair.
              wt_cmux_session_ensure; _ensrc=$?
              # ⛔ THE COMMAND NAME HERE IS QUOTED, NOT RUN (review #3031 round 7, finding P1). These two
              # assignments used UNESCAPED backticks inside a double-quoted string, so the shell performed
              # COMMAND SUBSTITUTION instead of printing the command: every recovered spawn issued a
              # SECOND, UNBOUNDED `cmux server ensure` on the controller's synchronous path (bypassing
              # `wt_bounded`, the one thing this file never does) and `_ensclaim` became that call's STDOUT
              # — `status started` — so the evidence line read `RECOVERED lane-8: ... status started
              # answered on attempt 1`, losing the fact the commit exists to add. Every sibling line in
              # this block escapes its backticks; these two did not. R2 pins the single call AND the
              # command name so it cannot come back.
              _enscmd="cmux server ensure --session $(wt_cmux_session)"
              _larc=0
              out="$(printf '%s\n' "$doc" | cmux layout apply --name "wt-$name" --cwd "$cwd" --json - 2>&1)" || _larc=$?
              if [ "$_larc" -eq 0 ]; then
                if [ "$_ensrc" -eq 0 ]; then
                  _ensclaim="\`$_enscmd\` answered on attempt $WT_ENSURE_TRIES"
                else
                  _ensclaim="\`$_enscmd\` did NOT answer (rc=$_ensrc after $WT_ENSURE_TRIES attempt(s)$( [ -n "$WT_ENSURE_SEEN" ] && printf '; last answer: %s' "$WT_ENSURE_SEEN" )), so the ensure did NOT clear it"
                fi
                # ⛔ A RECOVERY IS SAID OUT LOUD, because it is EVIDENCE ABOUT THE BOX: a spawn that needed
                # the session ensured is a cell whose owner had stopped allocating, and the next cycle must
                # be able to see that from the log rather than infer it from a spawn count. It also says
                # WHICH fact this is — the ensure answering, or the re-attempt carrying the spawn alone.
                wt_warn "RECOVERED $name: \`cmux layout apply\` failed once, $_ensclaim; the re-attempt SUCCEEDED — MEASURED: ${WT_PROBE_LINE}; READING: $(wt_cmux_probe_reading). The first failure's own message (NOT verified as a cause): ${_lamsg:-no output, exit status only}"
              else
                _recovered=" — recovery: \`$_enscmd\` tried $WT_ENSURE_TRIES time(s)$( [ -n "$WT_ENSURE_SEEN" ] && printf ' (last answer: %s)' "$WT_ENSURE_SEEN" ) and the re-attempt FAILED TOO; the residual is that the session owner must be repaired out of band (\`server stop --force\` + \`ensure\` is the recorded lever, and it ends every terminal inside the owner, so this spawn path does not take it)"
              fi ;;
            *)
              # ⛔ NO READING, NO RETRY (review round 4, finding F2). The refusal that says "no cause is
              # established" must not then act as if one were: the message and the behaviour are the same
              # claim, so this arm states the residual and leaves the box alone.
              _recovered=" — recovery: NOT attempted, because the probe could not READ the session owner (\`server status\` did not answer within ${WT_SERVER_TIMEOUT:-10}s, or answered something this classifier cannot read), so NO reading here names the session as the finding — a retry on a guess is exactly what this path does not do; re-run the spawn or inspect the owner by hand" ;;
          esac
        fi
      fi
      if [ "$_larc" -ne 0 ]; then
        # ⛔ THE VERDICT LEADS, BECAUSE THE RECORD THE CONTROLLER READS IS CUT AT 240 CHARS (review #3031
        # round 6, finding F3). `wt_refusal_record` bounds each reason (`cut -c1-240`), and the MEASURED
        # line alone can spend most of that on `server status=` — so with the READING second, the verdict
        # this change exists to deliver was truncated OUT of `spawn-refused.tsv` (measured: the row ended
        # `… retry; READI`, and neither `FALSE CAUSE` nor `not on the disk` survived). The line now opens
        # with the machine-readable verdict and the reading; the readings follow. The 240 bound is
        # deliberately NOT raised: it exists so a refusal storm cannot become the next full volume.
        wt_warn "REFUSED $name: cmux layout apply failed [verdict=${WT_PROBE_VERDICT:-unreadable} short=${WT_PROBE_SHORT:-0} owner=${WT_PROBE_OWNER:-unreadable}]: READING: $(wt_cmux_probe_reading)$_recovered; MEASURED on this box — ${WT_PROBE_LINE:-no readings taken}. The daemon's own message, which this probe did NOT verify as the cause: ${_lamsg:-no output, exit status only}"
        rm -f "$envf" "$runf"; return 1
      fi
    fi
    id="$(printf '%s\n' "$out" | sed -n 's/.*"terminal_id": *"\([^"]*\)".*/\1/p' | head -1)"
    ws="$(printf '%s\n' "$out" | sed -n 's/.*"workspace_id": *"\([^"]*\)".*/\1/p' | head -1)"
    [ -n "$id" ] || { wt_warn "REFUSED $name: cmux created the workspace but printed no terminal_id (nothing to track or reap): $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-300)"; \
      [ -n "${ws:-}" ] && cmux workspace rm "$ws" >/dev/null 2>&1; rm -f "$envf" "$runf"; rm -f "$(wt_dir)/.wt-absent-since" 2>/dev/null || true; wt_forget; return 1; }
  fi
  mkdir -p "$dir" 2>/dev/null || true
  # ⛔ THE RECORD WRITE IS CHECKED. A spawn that returns 0 without a record is an UNTRACKABLE worker: the
  # census can still see its surface (so the slot is held) but `wt_close` has no `kind`/`id` to close it
  # with — the worker holds a slot forever and the reap can never free it. So a failed write closes the
  # terminal it just created and FAILS the spawn.
  # ⛔ THE OWNER HAS ANSWERED BY HERE (a terminal id came back), so the absent window is stale whatever
  # happens to the RECORD WRITE below: a failed `printf > worker-<name>` returns 1 at the check below,
  # and clearing only on the success tail left the ancient stamp standing — a second route to a
  # one-sample confirmation (review round 9 of #2653, P2).
  rm -f "$(wt_dir)/.wt-absent-since" 2>/dev/null || true
  if ! printf 'kind=terminal\nid=%s\nworkspace=%s\ngrammar=%s\ncwd=%s\nrun=%s\ncreated=%s\n' \
    "$id" "${ws:-}" "$grammar" "$cwd" "$runf" "$(date +%s)" > "$dir/worker-$name" 2>/dev/null; then
    wt_warn "REFUSED $name: created terminal '$id' but could not record it in $dir — closing that terminal rather than leaving an untrackable worker behind"
    [ -n "$id" ] && cmux terminal close "$id" >/dev/null 2>&1
    [ -n "${ws:-}" ] && cmux workspace rm "$ws" >/dev/null 2>&1
    rm -f "$envf" "$runf" 2>/dev/null || true
    wt_forget
    return 1
  fi
  # ⛔ A TERMINAL SPAWN PROVES THE OWNER ANSWERED (review round 6 of #2653, P2), so the absent window
  # must not survive it: otherwise the window stays ancient across an outage, and the FIRST absent
  # sample after a restart-and-crash confirms immediately — the single-sample conclusion the two-sample
  # rule exists to forbid. ⛔ AND IT BELONGS HERE, NOT IN wt_forget: wt_forget also runs for TMUX
  # spawns, which prove nothing about the cmux owner and are exactly what the controller keeps doing
  # during an outage — clearing there would restart the timer on every outage spawn and re-create the
  # 26h stall.
  wt_forget
  return 0
}

# ── reap ────────────────────────────────────────────────────────────────────────────────────
# Close a durable terminal this box has no RECORD of, by its workspace name. Best effort by design:
# the caller re-verifies with the census afterwards, and a surface that refuses to go keeps the
# worker counted (which is the safe direction).
wt_close_named_surface() {
  local name="${1:-}" tree map k v
  [ -n "$name" ] || return 0
  command -v cmux >/dev/null 2>&1 || return 0
  tree="$(cmux tree --json 2>/dev/null)" || return 0
  [ -n "$tree" ] || return 0
  map="$(printf '%s\n' "$tree" | python3 -c "$WT_WS_PY" "wt-$name" 2>/dev/null)" || return 0
  [ -n "$map" ] || return 0
  while IFS="$(printf '\t')" read -r k v; do
    case "$k" in
      term) [ -n "$v" ] && cmux terminal close "$v" >/dev/null 2>&1 ;;
      ws)   [ -n "$v" ] && cmux workspace rm "$v" >/dev/null 2>&1 ;;
    esac
  done <<EOF
$map
EOF
  return 0
}

# wt_close <name> — kill the worker and PROVE it is gone. Returns 1 when it cannot prove that, and
# then it KEEPS the record so a later cycle retries: "closed" is a claim about reality, and a reaper
# that reports a kill it did not verify is the same class of lie as a spawn that never happened.
wt_close() {
  local name dir f kind id ws pid
  name="${1:-}"; [ -n "$name" ] || return 1
  case "$name" in *[!A-Za-z0-9-]*) return 1 ;; esac
  dir="$(wt_dir)"; f="$dir/worker-$name"
  kind=tmux; id=""; ws=""
  [ -f "$f" ] && { kind="$(sed -n 's/^kind=//p' "$f" | head -1)"; id="$(sed -n 's/^id=//p' "$f" | head -1)"; ws="$(sed -n 's/^workspace=//p' "$f" | head -1)"; }
  wt_forget
  case "$kind" in
    terminal)
      [ -n "$id" ] && cmux terminal close "$id" >/dev/null 2>&1
      [ -n "$ws" ] && cmux workspace rm "$ws" >/dev/null 2>&1
      # A record with neither field (an older harness) has nothing to address by id: fall back to
      # the workspace name, the same handle the census uses.
      [ -z "$id" ] && [ -z "$ws" ] && wt_close_named_surface "$name"
      ;;
    *)
      # tmux: resolve the pane pid BEFORE killing the session (the session is what holds it), kill the
      # session with an EXACT target, then the pid tree — a child that ignored the HUP (a stuck `find`)
      # survives the session alone.
      pid="$(tmux list-panes -t "=$name" -F '#{pane_pid}' 2>/dev/null | head -1)"
      tmux kill-session -t "=$name" 2>/dev/null
      if [ -n "$pid" ]; then kill -TERM "$pid" 2>/dev/null; sleep 1; kill -KILL "$pid" 2>/dev/null; fi
      # ⛔ And a DURABLE TERMINAL the census can see but this box has no record of (a wiped
      # $O/state, a lane from an older harness) is closed by its workspace name — otherwise the
      # reap can never free it and logs "could NOT be proven gone" every cycle, forever.
      wt_close_named_surface "$name"
      ;;
  esac
  wt_forget
  if wt_alive "$name"; then
    return 1
  fi
  rm -f "$f" "$dir/env-$name.sh" "$dir/run-$name.sh" 2>/dev/null || true
  return 0
}
