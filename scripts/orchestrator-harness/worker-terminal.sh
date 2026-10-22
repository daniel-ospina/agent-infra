#!/usr/bin/env bash
# worker-terminal.sh — the ONE place that LAUNCHES a worker, answers whether it is ALIVE, counts
# them, and KILLS one. Sourced by orch-loop.sh and dispatch-merge.sh.
#
# ⛔ WHY THIS FILE EXISTS — MEASURED 2026-10-20 ON ALL THREE CLOUD CELLS.
# A lane launched as a tmux window (or a `setsid nohup` child of a transient `cmux cloud exec`
# session) dies at ~21 log lines: its first `bash` tool call never returns and the child transcript
# stops after ONE toolCall. The SAME lane launched as a DURABLE TERMINAL — a surface the cmux daemon
# owns, not a child of the session that created it — stays alive (verified: `cmux vm terminal
# wait-exit` reports `pending` while it runs, and a `ps` taken from an exec session cannot even see
# the process, because the tree hangs off the daemon and not off the launcher). Bash-only rails
# launched via tmux survive 20+ minutes, so the kill targets the LANE's process tree, not bash — the
# launcher is what has to change, not the worker.
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
# named above is used instead. Both branches create a durable terminal; NEITHER falls back to tmux
# on a cell — see `wt_launcher` for the one surface where tmux is still correct.
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
# POSITIVE read (the workspace is gone; the session name is absent).
#
# ⛔ WHAT THIS FILE DELIBERATELY DOES NOT DO. No tmux fallback on a Linux cell (`wt_launcher` refuses
# out loud instead): a silent fallback would make the 21-line death invisible again, which is the
# defect being removed. No retry, no queue — a failed spawn returns non-zero and lets the caller's
# own failure branch (every call site has one) record the wait.

# ── small helpers ──────────────────────────────────────────────────────────────────────────────
# The shipped quoter, byte-identical to orch-loop.sh's shq() (a worker command is a shell LINE in the
# layout grammar and an argv word in the surface grammar; both need POSIX single-quote quoting).
wt_q() { local s="${1:-}" q="'"; printf "'%s'" "${s//$q/$q\\$q$q}"; }

# Where worker records live. `$O/state` is the same directory the claim/attempt records use, so an
# operator has ONE place to look; WT_DIR is a test seam, never an operator knob.
wt_dir() { printf '%s\n' "${WT_DIR:-${O:-$HOME/orchestrator}/state}"; }

# Say it on stderr AND in the controller's log (the controller's stdout is not read by anyone).
wt_warn() {
  printf '[worker-terminal] %s\n' "$*" >&2
  if [ -n "${LOG:-}" ]; then printf '[worker-terminal] %s\n' "$*" >> "$LOG" 2>/dev/null || true; fi
  return 0
}

# ── which launcher this surface gets ──────────────────────────────────────────────────────────
# `terminal` — a cmux surface where the DAEMON answers (a cloud cell, or a Mac process started
#              inside cmux). This is the only launcher a Linux host may use.
# `tmux`     — macOS with no reachable cmux daemon, i.e. the launchd controller. THAT IS DELIBERATE
#              AND NOT A DEGRADE: from launchd the cmux CLI is unusable by design ("Access denied -
#              only processes started inside cmux can connect", measured and recorded in
#              tools/fleet/lane_liveness.py), so tmux is the only launcher that works there — and
#              it is where the current worker model has always worked.
# `none`     — a Linux host with no reachable cmux. REFUSED, loudly, per spawn. Never tmux: on a
#              cell a tmux window is the measured 21-line death.
# ⛔ NO ENV OVERRIDE. It would be a one-line way to force tmux on a cell — i.e. to re-create the
# defect this file removes — and a gate a PR or an agent can defeat is not a gate. The launcher is a
# fact about the surface, read from the surface. (Tests choose a surface by stubbing PATH: `cmux` and
# `uname` are the only inputs, and `wt_forget` re-probes within one shell.)
wt_launcher() {
  if command -v cmux >/dev/null 2>&1 && cmux tree --json >/dev/null 2>&1; then
    WT_LAUNCHER=terminal
  elif [ "$(uname -s 2>/dev/null)" = "Darwin" ] && command -v tmux >/dev/null 2>&1; then
    WT_LAUNCHER=tmux
  else
    WT_LAUNCHER=none
  fi
  printf '%s\n' "$WT_LAUNCHER"
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
WT_TREE_PY="$(cat <<'PY'
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
)"
wt_tree_probe() { # stdin: `cmux tree --json`; stdout: "w:<worker>"|"t:<terminal-id>" TAB verdict
  python3 -c "$WT_TREE_PY" 2>/dev/null
}

# The SURFACE half of a close: given a worker NAME, print `ws<TAB><workspace-id>` and
# `term<TAB><terminal-id>` for its `wt-<name>` workspace. Needed because the census counts a worker
# whose RECORD is gone (a wiped $O/state, a lane from an older harness) — and a reap that cannot
# resolve that worker leaves it holding a slot forever while logging "could NOT be proven gone".
WT_WS_PY="$(cat <<'PY'
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
)"

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
  if out="$(tmux ls -F '#{session_name}' 2>&1)"; then printf '%s\n' "$out"; return 0; fi
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
WT_CENSUS=""
wt_table() {
  local now ttl dir cache hdr tree nrc names probe_ok raw="" tbl="" f name kind id st
  now="$(date +%s 2>/dev/null || echo 0)"; ttl="${WT_TABLE_TTL:-10}"
  dir="$(wt_dir)"; cache="$dir/.wt-census"
  if [ "${ttl:-0}" -gt 0 ] 2>/dev/null && [ -f "$cache" ]; then
    hdr="$(head -1 "$cache" 2>/dev/null)"
    case "$hdr" in
      '# at='*)
        case "${hdr#\# at=}" in
          ''|*[!0-9]*) : ;;
          *) [ $(( now - ${hdr#\# at=} )) -lt "$ttl" ] && { sed '1d' "$cache"; return 0; } ;;
        esac ;;
    esac
  fi
  tree="$(cmux tree --json 2>/dev/null)" || tree=""
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
  fi
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
      case "$name" in lane-*|merge-*|fix-*) ;; *) continue ;; esac
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
  { printf '# at=%s\n' "$now"; printf '%s\n' "$WT_TABLE"; } > "$cache.tmp.$$" 2>/dev/null \
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
wt_env_snapshot() { # <name> -> prints the path
  local dir f
  dir="$(wt_dir)"; mkdir -p "$dir" 2>/dev/null || return 1
  f="$dir/env-$1.sh"
  ( umask 077
    { export -p; printf 'export O=%s\n' "$(wt_q "${O:-}")"; } > "$f" ) 2>/dev/null || return 1
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
  local name cwd cmd kind grammar dir envf runf doc out id ws
  [ "$#" -ge 3 ] || { wt_warn "wt_spawn needs <name> <cwd> <command>"; return 1; }
  name="$1"; cwd="$2"; shift 2; cmd="$*"
  case "$name" in
    ''|*[!A-Za-z0-9-]*) wt_warn "refusing a worker name with anything but [A-Za-z0-9-]: '$name'"; return 1 ;;
  esac
  dir="$(wt_dir)"
  kind="$(wt_launcher)"
  case "$kind" in
    none)
      wt_warn "REFUSED $name: no durable-terminal surface on this host (cmux is absent or its daemon does not answer) and this is not macOS — a tmux worker here dies at ~21 log lines (agent-infra#1702 follow-up), so nothing is started"
      return 1 ;;
    tmux)
      # The launchd surface, where tmux is the only launcher that works (see wt_launcher).
      if tmux new-session -d -s "$name" "cd $(wt_q "$cwd") && $cmd" 2>/dev/null; then
        mkdir -p "$dir" 2>/dev/null || true
        printf 'kind=tmux\ncwd=%s\ncreated=%s\n' "$cwd" "$(date +%s)" > "$dir/worker-$name" 2>/dev/null || true
        wt_forget
        return 0
      fi
      wt_warn "tmux could not start $name"
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
    if [ -n "${WT_MACHINE:-}" ]; then set -- "$@" --machine "$WT_MACHINE"; fi
    set -- "$@" --cwd "$cwd" --no-open -- /bin/bash "$runf"
    out="$(cmux "$@" 2>&1)" || { wt_warn "REFUSED $name: cmux surface new-terminal failed: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-300)"; rm -f "$envf" "$runf"; return 1; }
    id="$(printf '%s\n' "$out" | grep -oE 'term_[A-Za-z0-9]+|surface:[0-9]+' | head -1)"
    [ -n "$id" ] || { wt_warn "REFUSED $name: cmux surface new-terminal printed no terminal id (nothing to track or reap): $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-300)"; rm -f "$envf" "$runf"; return 1; }
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
    out="$(printf '%s\n' "$doc" | cmux layout apply --name "wt-$name" --cwd "$cwd" --json - 2>&1)" \
      || { wt_warn "REFUSED $name: cmux layout apply failed: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-300)"; rm -f "$envf" "$runf"; return 1; }
    id="$(printf '%s\n' "$out" | sed -n 's/.*"terminal_id": *"\([^"]*\)".*/\1/p' | head -1)"
    ws="$(printf '%s\n' "$out" | sed -n 's/.*"workspace_id": *"\([^"]*\)".*/\1/p' | head -1)"
    [ -n "$id" ] || { wt_warn "REFUSED $name: cmux created the workspace but printed no terminal_id (nothing to track or reap): $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-300)"; \
      [ -n "${ws:-}" ] && cmux workspace rm "$ws" >/dev/null 2>&1; rm -f "$envf" "$runf"; wt_forget; return 1; }
  fi
  mkdir -p "$dir" 2>/dev/null || true
  # ⛔ THE RECORD WRITE IS CHECKED. A spawn that returns 0 without a record is an UNTRACKABLE worker: the
  # census can still see its surface (so the slot is held) but `wt_close` has no `kind`/`id` to close it
  # with — the worker holds a slot forever and the reap can never free it. So a failed write closes the
  # terminal it just created and FAILS the spawn.
  if ! printf 'kind=terminal\nid=%s\nworkspace=%s\ngrammar=%s\ncwd=%s\nrun=%s\ncreated=%s\n' \
    "$id" "${ws:-}" "$grammar" "$cwd" "$runf" "$(date +%s)" > "$dir/worker-$name" 2>/dev/null; then
    wt_warn "REFUSED $name: created terminal '$id' but could not record it in $dir — closing that terminal rather than leaving an untrackable worker behind"
    [ -n "$id" ] && cmux terminal close "$id" >/dev/null 2>&1
    [ -n "${ws:-}" ] && cmux workspace rm "$ws" >/dev/null 2>&1
    rm -f "$envf" "$runf" 2>/dev/null || true
    wt_forget
    return 1
  fi
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
