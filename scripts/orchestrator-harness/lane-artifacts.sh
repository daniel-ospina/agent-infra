#!/usr/bin/env bash
# lane-artifacts.sh — collect a cell lane's artifacts ONTO the machine the orchestrator runs on.
#
# THE DEFECT THIS EXISTS FOR (measured 2026-11-01, three times in one night):
#   Briefs mandate that a lane write its findings to a file as it goes (`/tmp/<topic>.md`), because a
#   reply that is never sent is lost while a file survives a kill. But a lane dispatched to a CELL
#   writes that file ON THE CELL. The orchestrator's `ls /tmp/ci-cause.md` then returns nothing while
#   the lane is demonstrably alive, and the orchestrator's only channel is again the final reply —
#   the exact thing that failed. Measured: all four artifacts mandated that night EXISTED —
#   `ci-cause.md` on pi-cell-3, `blocked-histogram.md` and `p1-10515.md` on pi-cell-4,
#   `epic-ledger.md` on pi-cell-1 — each on a *different* box, and not one reachable from the mac.
#   A deliverable the consumer cannot reach is not a deliverable.
#
# WHY PULL AND NOT PUSH (researched, not assumed — see the PR body):
#   GitHub Actions and Buildkite both require the WORKER to upload before the job ends (GitHub's docs:
#   "files must be uploaded before the job ends"; post-kill recovery is explicitly not guaranteed).
#   That is precisely the lane-died-before-it-could-act case, so a worker-push sidecar is DISQUALIFIED
#   here. Nomad and Kubernetes do the opposite: the runtime writes task stdout to a file on the node
#   and the control plane PULLS it on demand (`nomad alloc logs`, `kubectl logs`). That survives a hard
#   kill because the write is done by the runtime, not by the workload. This fleet is already the Nomad
#   shape — `robust_push.py`'s LAUNCH heredoc is the runtime that writes `/tmp/<name>.log` — and it
#   already has the transport (`cmux vm exec`). Nothing new is invented: this script is the PULL VERB.
#
# WHY DISCOVERY AND NOT A REGISTRY (the alternative, rejected):
#   The obvious design is for the dispatcher to record `name -> box -> path`. That record is a SECOND
#   SOURCE OF TRUTH about where the artifact is, and it goes stale exactly when it matters — after a
#   re-dispatch, a respawn, a box swap — so it can answer confidently and wrongly. Worse, the path is
#   lane-chosen: lane `t-ci-cause` wrote `/tmp/ci-cause.md`, so a dispatcher-supplied path would have
#   been wrong even on the night it was recorded. Discovery is SELF-VALIDATING (the file is there or
#   it is not) at the cost of one cheap `cmux vm exec` per box.
#
# ⛔ THE HONESTY INVARIANT — this is the whole reason the exit codes are this specific, and every
#    branch below exists to keep it true. A claim of ABSENCE must rest on having actually searched
#    EVERY box the caller asked for:
#      0 = found · 3 = ABSENT-EVERYWHERE (every requested box resolved AND was searched AND matched
#          nothing) · 4 = UNMEASURED, so "absent" is NOT claimed (a box failed, errored, or never
#          resolved) · 5 = PULL-FAILED · 64 = usage error
#    "Resolved" is not "searched", and a `find` that ERRORED is not a `find` that found nothing.
# ⛔ Never make the lane responsible for its own collection: the failure is a lane that died before it
#    could do anything after the kill.
set -uo pipefail

CM="${CMUX_BIN:-/Applications/cmux.app/Contents/Resources/bin/cmux}"
BOXES_DEFAULT="${LANE_ARTIFACT_BOXES:-pi-cell-1 pi-cell-3 pi-cell-4}"
# The directory scanned on each box. `/tmp` in production; overridable ONLY so the test can build a
# fixture tree instead of asserting against whatever happens to be on a live box.
ATIF_ROOT="${LANE_ARTIFACT_ROOT:-/tmp}"
ROW_CAP=200

usage() {
  local rc="${1:-64}"
  cat >&2 <<'EOF'
usage: lane-artifacts.sh <verb> [args]

  collect <pattern> [--out DIR] [--lines N] [--box LABEL] [--since MINUTES]
        Find every /tmp/*<pattern>* on the cells, print it (first --lines, default 40),
        and with --out write each FULL file to DIR/<cell>-<basename>, recorded in
        DIR/.lane-artifacts-index (rewritten per run).
        <pattern> is a glob fragment, so `collect ci-cause` finds /tmp/ci-cause.md.
        `collect '*'` sweeps all of /tmp.

  logs <name> [--out DIR] [--lines N] [--box LABEL]
        The deterministic per-lane stdout: /tmp/<name>.log, written by the dispatcher's launcher
        (`nohup pi -p < brief > /tmp/<name>.log`). This IS a cell lane's stdout.

  ls [--box LABEL] [--since MINUTES]
        Inventory of /tmp/*.md and /tmp/*.log per box.

Exit: 0 found · 3 ABSENT-EVERYWHERE · 4 UNMEASURED (absent NOT claimed) · 5 PULL-FAILED.
EOF
  exit "$rc"
}

verb="${1:-}"; [ -n "$verb" ] || usage
# `--help` is asked for as a VERB (`lane-artifacts.sh --help`), so it must be recognised before the shift
# that consumes it — otherwise it fell through to the "no pattern" guard and returned the usage-ERROR
# code 64 for a help request, which a doc/CI wrapper reads as failure.
case "$verb" in -h|--help) usage 0 ;; esac
shift || true

pattern=""; outdir=""; lines=40; only_box=""; since=""
need_val() { [ "$2" -ge 2 ] || { echo "lane-artifacts: missing value for $1" >&2; usage; }; }
need_num() { printf '%s' "$2" | grep -Eq '^[0-9]+$' || { echo "lane-artifacts: $1 must be a whole number, got '$2'" >&2; usage; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    # ⛔ `shift 2` with one arg left does NOT shift, so the loop would spin forever on a truncated
    # invocation (`collect ci-cause --out`) — a wedge, not an error. Check the count first.
    --out)     need_val --out "$#";   outdir="$2"; shift 2 ;;
    --lines)   need_val --lines "$#"; need_num --lines "$2"; lines="$2"; shift 2 ;;
    --box)     need_val --box "$#";   only_box="$2"; shift 2 ;;
    # A unit suffix (`--since 30m`) used to reach the remote `find` as `-mmin -30m`, whose error was
    # discarded — so the scan returned no rows and the tool claimed ABSENT about a file that exists.
    # Validate here, where a usage error is a usage error.
    --since)   need_val --since "$#"; need_num --since "$2"; since="$2"; shift 2 ;;
    -h|--help) usage 0 ;;
    *)         if [ -z "$pattern" ]; then pattern="$1"; shift; else echo "unexpected arg: $1" >&2; usage; fi ;;
  esac
done
[ -n "$pattern" ] || [ "$verb" = "ls" ] || usage   # `ls` takes no pattern

# `cmux vm exec` addresses a box by its VM NAME, not by its label — passing the label fails with an
# opaque `Reference: <hash>`. Resolve label -> name from `cmux vm list`, and report how many requested
# labels did NOT resolve: a label that silently vanishes shrinks the universe, which would let exit 3
# ("absent everywhere") be claimed without ever attempting that box.
resolve_boxes() {
  local want="$1" list label name labels
  list="$("$CM" vm list </dev/null 2>/dev/null)" || { echo "UNMEASURED cmux-vm-list-failed" >&2; return 1; }
  labels="$BOXES_DEFAULT"; [ -n "$want" ] && labels="$want"
  for label in $labels; do
    name="$(printf '%s\n' "$list" | awk -v L="$label" '$2==L {print $1; exit}')"
    if [ -n "$name" ]; then printf '%s %s\n' "$label" "$name"
    else printf 'UNRESOLVED %s\n' "$label"; fi
  done
}

# scan <vm> <pattern> <since_minutes|""> <exact:0|1>
#   -> `__OK__` then `path<TAB>size<TAB>mtime` rows, or `__NOK__ <reason>` and nothing else.
#
# `find <root> -maxdepth 1` is an EXPLICIT, BOUNDED start point (never a root walk).
#
# TWO failures must be distinguishable, and neither is "no files":
#   __NOK__ unreadable-root — the root is not a readable directory
#   __NOK__ find-failed     — the match step ERRORED (bad flag, broken find, missing binary)
# Both are UNMEASURED. The first version emitted `__OK__` BEFORE `find` ran and discarded its exit
# status, so a `find` error produced `__OK__` + no rows = "searched, matched nothing" = ABSENT claimed
# about a box that was never searched. `find` and `head` are therefore run to a temp file and their
# status is checked before the sentinel.
#
# ⛔ `</dev/null` IS LOAD-BEARING ON EVERY EXEC THAT RUNS INSIDE A `while read … <<< "$MAP"` LOOP —
#    this one included. An exec that inherits that here-string EATS the unread rows, so whole boxes are
#    skipped. Found in `pull` first (the last matched file vanished from every run), then still present
#    here; the reviewer proved the `head`-preview exec had it too. Grep for `</dev/null`: every exec
#    inside a read loop must have one.
#
# ONE pass per box: `-printf` replaces a per-file `wc -c`+`stat` subshell (the first version did that per
# file, took ~14 s/box, and silently LOST a row on a slow box — the truncation this tool exists to stop).
#
# The sentinel is echoed BY THE REMOTE SHELL. Do not build it with `sed '1s/^/…\n/'` — BSD sed does not
# expand `\n`, so on a mac the sentinel became the literal `__OK__n` and every box read as UNMEASURED
# while the files sat there.
scan() {
  local vm="$1" pat="$2" since_min="$3" exact="$4"
  "$CM" vm exec --timeout 60 "$vm" -- sh -c '
    R="$3"
    [ -d "$R" ] && [ -r "$R" ] || { echo "__NOK__ unreadable-root"; exit 0; }
    case "$4" in 1) NAME="$(printf "%s" "$1" | sed "s/\\\\([][*?]\\\\)/[\\\\1]/g")" ;; *) NAME="*$1*" ;; esac
    T=$(mktemp 2>/dev/null) || T="/tmp/.lane-artifacts.$$"
    if find "$R" -maxdepth 1 -type f -printf "" 2>/dev/null; then
      find "$R" -maxdepth 1 -type f -name "$NAME" ${2:+-mmin -$2} \
        -printf "%p\t%s\t%TY-%Tm-%TdT%TH:%TM:%TS\n" > "$T" 2>/dev/null
      rc=$?
    else
      # No -printf => BSD/busybox find (a mac, or a stripped image). Same rows, per-file stat: slower,
      # and only ever the fallback. WITHOUT IT the mac-side test could not exercise the real scan at
      # all — `-printf` silently returned nothing and every fixture box read as empty, i.e. a
      # portable-looking tool that only works on GNU find is a false PASS waiting to happen.
      # `stat -c` is tried FIRST because Linux is the production platform; GNU `stat -f` means
      # --file-system and would SUCCEED while printing filesystem status, so the BSD arm would never
      # fall through and the mtime column would be garbage for every row.
      L=$(mktemp 2>/dev/null) || L="/tmp/.lane-artifacts.l.$$"
      find "$R" -maxdepth 1 -type f -name "$NAME" ${2:+-mmin -$2} > "$L" 2>/dev/null
      rc=$?
      : > "$T"
      while IFS= read -r f; do
        printf "%s\t%s\t%s\n" "$f" "$(wc -c < "$f" | tr -d " ")" \
          "$(stat -c "%y" "$f" 2>/dev/null || stat -f "%Sm" -t "%FT%T" "$f" 2>/dev/null || echo -)" >> "$T"
      done < "$L"
      rm -f "$L"
    fi
    if [ "$rc" -ne 0 ]; then
      rm -f "$T"; echo "__NOK__ find-failed(rc=$rc)"; exit 0
    fi
    echo __OK__
    # Ask for one MORE row than the cap so "exactly ROW_CAP matches" is not mistaken for truncation.
    head -n '"$((ROW_CAP + 1))"' "$T"
    rm -f "$T"
  ' lane-artifacts "$pat" "$since_min" "$ATIF_ROOT" "$exact" </dev/null 2>/dev/null
}

# pull <vm> <remote path> <remote size> <dest>
#   Byte-exact or it FAILS: a transfer cut mid-stream at a 4-char-aligned base64 boundary decodes
#   cleanly to a TRUNCATED file, so the decoded size is compared with the size `scan` already read.
#   The path travels as argv ($1), never interpolated — a filename with an apostrophe broke that.
#   A 0-byte artifact is a legitimate result (a lane killed between creating and writing): the remote
#   exit status decides, not the emptiness of the payload.
pull() {
  local vm="$1" path="$2" want="$3" dest="$4" raw b64 rc got
  # ⛔ THE STATUS LINE COMES FIRST. It used to be a trailing `RC=` marker, and a transfer truncated
  # mid-flight cuts the END off — destroying the marker, so the size check below was UNREACHABLE for
  # the one failure it was written for and the operator was told "unreadable or UNMEASURED" about a
  # transient truncation. A prefix marker survives truncation from the end; a suffix marker cannot.
  # (The previous version of this file CLAIMED this fix in a comment while the code still emitted the
  # marker last — found by review. The code is the claim.)
  raw="$("$CM" vm exec --timeout 120 "$vm" -- sh -c \
          'b=$(base64 < "$1" 2>/dev/null); rc=$?; printf "RC=%s\n%s\n" "$rc" "$b"' \
          lane-artifacts "$path" </dev/null 2>/dev/null)"
  rc="$(printf '%s\n' "$raw" | sed -n '1s/^RC=//p' | tr -d '[:space:]')"
  b64="$(printf '%s\n' "$raw" | tail -n +2 | tr -d '[:space:]')"
  if [ "${rc:-1}" != "0" ]; then
    printf '  ✗ pull failed (remote exit %s — unreadable or UNMEASURED): %s\n' "${rc:-?}" "$path" >&2
    rm -f "$dest"          # a stale copy from an earlier run must not survive as this run's result
    return 1
  fi
  if ! printf '%s' "$b64" | base64 -D > "$dest" 2>/dev/null && \
     ! printf '%s' "$b64" | base64 -d > "$dest" 2>/dev/null; then
    printf '  ✗ decode failed: %s\n' "$path" >&2; rm -f "$dest"; return 1
  fi
  got="$(wc -c < "$dest" | tr -d '[:space:]')"
  if [ -n "${want:-}" ] && [ "${want:-x}" != "?" ] && [ "$got" != "$want" ]; then
    printf '  ✗ SIZE MISMATCH: %s decoded %s bytes, the box reported %s — TRUNCATED, discarded\n' \
      "$path" "$got" "$want" >&2
    rm -f "$dest"; return 1
  fi
  printf '  ✓ wrote %s (%s bytes)\n' "$dest" "$got"
}

MAP_RAW="$(resolve_boxes "$only_box")"
MAP="$MAP_RAW"
RBOX="$(printf '%s\n' "$MAP" | awk '$1=="UNRESOLVED"{ n++; next } NF{ m++ } END{ print (m+0), (n+0) }')"
NBOX="${RBOX% *}"; NUNRESOLVED="${RBOX#* }"
if [ "${NBOX:-0}" -eq 0 ]; then
  echo "UNMEASURED(no box resolved from cmux vm list — $(printf '%s' "$MAP" | awk '$1=="UNRESOLVED"{printf "%s ",$2}'))"
  exit 4
fi
MAP="$(printf '%s\n' "$MAP" | awk '$1!="UNRESOLVED"')"
# Derived from the SINGLE listing already in hand, not from a second `cmux vm list` round trip: a moving
# universe could make the count (call 1) and the names (call 2) disagree, and the message would then
# fall back to a vague `exec failed` about a label it had just resolved.
UNRESOLVED_LABELS="$(MAP_RAW=$MAP_RAW awk 'BEGIN{ n=split(ENVIRON["MAP_RAW"],a,"\n"); for(i=1;i<=n;i++){ split(a[i],f," "); if(f[1]=="UNRESOLVED") printf "%s ", f[2] } }')"

# emit_box <label> <vm> … — `collect`-shaped output for one box. Sets R_REACHED=1 when it answered.
emit_box() {
  local label="$1" vm="$2" pat="$3" exact="$4" outdir="$5" lines="$6" since="$7"
  local raw first res rows p sz mt dest
  raw="$(scan "$vm" "$pat" "$since" "$exact")"
  first="$(printf '%s\n' "$raw" | head -1)"
  if [ "${first:0:7}" = "__NOK__" ]; then
    echo "── $label  UNMEASURED(${first#__NOK__ })"
    return 1
  fi
  if [ "$first" != "__OK__" ]; then
    echo "── $label  UNMEASURED(exec did not answer — says nothing about whether the file exists)"
    return 1
  fi
  R_REACHED=1
  res="$(printf '%s\n' "$raw" | tail -n +2 | grep -v '^$')"
  [ -n "$res" ] || return 0
  rows="$(printf '%s\n' "$res" | wc -l | tr -d ' ')"
  if [ "$rows" -gt "$ROW_CAP" ]; then
    R_TRUNC=$((R_TRUNC + 1))
    res="$(printf '%s\n' "$res" | head -n "$ROW_CAP")"
  fi
  while IFS="$(printf '\t')" read -r p sz mt; do
    [ -n "${p:-}" ] || continue
    R_HITS=$((R_HITS + 1))
    echo
    echo "── $label  $p  (${sz:-?} bytes, ${mt:-?})"
    # The count and path go as argv, and stderr is kept OUT of the body: a remote "cannot open" — or a
    # `--lines` that `head` rejected — must never be rendered as though it were the artifact's content.
    "$CM" vm exec --timeout 60 "$vm" -- sh -c 'head -n "$1" -- "$2" 2>/dev/null; exit $?' \
      lane-artifacts "$lines" "$p" </dev/null 2>/dev/null > /tmp/.la-prev.$$ 2>/dev/null
    if [ $? -ne 0 ]; then
      # A failed preview used to render as an EMPTY artifact at exit 0 — content-absence silently
      # standing in for a failed read, the one thing this tool refuses to do everywhere else.
      echo "   ⚠ preview failed (exec did not answer) — the file is ${sz:-?} bytes on the box; content not shown"
    else
      sed 's/^/   /' /tmp/.la-prev.$$
    fi
    rm -f /tmp/.la-prev.$$
    if [ -n "$outdir" ]; then
      dest="$outdir/${label}-$(basename "$p")"
      if pull "$vm" "$p" "$sz" "$dest"; then
        R_PULLED=$((R_PULLED + 1))
        printf '%s\t%s\t%s\n' "$label" "$p" "${sz:-?}" >> "$outdir/.lane-artifacts-index"
      else
        R_PULLFAIL=$((R_PULLFAIL + 1))
      fi
    fi
  done <<< "$res"
  return 0
}

case "$verb" in
  collect|logs)
  # ⛔ `find -name` NEVER matches a `/`, and the briefs this tool serves mandate `/tmp/<topic>.md` — so a
  # pasted path is the likely first invocation, and it used to return a confident ABSENT-EVERYWHERE
  # (every box searched, matched nothing: the letter of the contract, the wrong verdict — the same class
  # as `--since 30m`). A path is a usage error, not a pattern.
  case "$pattern" in
    */*) echo "lane-artifacts: pattern is a filename fragment, not a path — give 'ci-cause', not '/tmp/ci-cause.md'" >&2; usage ;;
  esac
  pat="$pattern"; exact=0
    if [ "$verb" = "logs" ]; then
      # EXACT name: `<name>` is documented as the deterministic /tmp/<name>.log. `logs` with no name is
      # a usage error, not an absence verdict about a name the operator never gave.
      [ -n "$pattern" ] || usage
      pat="${pattern%.log}.log"; exact=1
    elif [ "$pat" = "*" ] || [ "$pat" = "." ]; then
      pat=""                          # a full sweep is /tmp/*, not /tmp/**
    fi
    R_HITS=0; R_PULLED=0; R_PULLFAIL=0; R_TRUNC=0; REACHED=0; REACHED_LABELS=""
    if [ -n "$outdir" ]; then
      mkdir -p "$outdir" 2>/dev/null
      if [ ! -d "$outdir" ] || [ ! -w "$outdir" ]; then
        echo "lane-artifacts: --out '$outdir' is not a writable directory" >&2; exit 64
      fi
      # Delete exactly what the PREVIOUS index recorded — label-independent. A `pi-cell-*` glob missed
      # any caller-supplied label (`--box edge-7`), leaving run 1's file beside run 2's empty index for
      # any consumer that globs the directory instead of reading the index.
      if [ -f "$outdir/.lane-artifacts-index" ]; then
        while IFS="$(printf '\t')" read -r _l p _s; do
          [ -n "${p:-}" ] && rm -f "$outdir/${_l}-$(basename "$p")"
        done < "$outdir/.lane-artifacts-index"
      fi
      : > "$outdir/.lane-artifacts-index"
    fi
    UNRES_NOTE=""
    [ "${NUNRESOLVED:-0}" -gt 0 ] && UNRES_NOTE=" (+$NUNRESOLVED unresolved label(s):$UNRESOLVED_LABELS)"
    echo "== lane-artifacts $verb '$pat' over $NBOX box(es)$UNRES_NOTE"
    while read -r label vm; do
      [ -n "${label:-}" ] || continue
      R_REACHED=0
      emit_box "$label" "$vm" "$pat" "$exact" "$outdir" "$lines" "$since"
      if [ "$R_REACHED" -eq 1 ]; then
        REACHED=$((REACHED + 1)); REACHED_LABELS="$REACHED_LABELS $label"
      fi
    done <<< "$MAP"

    echo
    # UNRESOLVED labels count as "not measured": they were requested and never attempted, so exit 3
    # must not be claimed on their behalf.
    MISSING=$(( (NBOX - REACHED) + NUNRESOLVED ))
    if [ "$REACHED" -eq 0 ]; then
      echo "UNMEASURED(no box answered — this says nothing about whether the file exists)"
      exit 4
    fi
    if [ "$R_HITS" -eq 0 ]; then
      if [ "$MISSING" -gt 0 ]; then
        printf 'UNMEASURED(nothing matched on the %s box(es) actually searched:%s — %s requested box(es) did NOT answer (%s), so ABSENT is NOT claimed)\n' \
          "$REACHED" "$REACHED_LABELS" "$MISSING" "${UNRESOLVED_LABELS:-exec failed}"
        exit 4
      fi
      printf 'ABSENT-EVERYWHERE(find %s -maxdepth 1 -name "%s" matched nothing on all %s box(es):%s)\n' \
        "$ATIF_ROOT" "$pat" "$REACHED" "$REACHED_LABELS"
      exit 3
    fi
    [ "$R_TRUNC" -gt 0 ] && echo "⚠ TRUNCATED at the $ROW_CAP-row cap on $R_TRUNC box(es) — narrow the pattern; this list is NOT complete"
    # Partial coverage is disclosed on the SUCCESS path too: exit 0 with 1 of 3 boxes silent reads as
    # a complete result to any caller keying on the exit status.
    echo "== $R_HITS file(s) collected from $REACHED of $((NBOX + NUNRESOLVED)) requested box(es)${outdir:+; $R_PULLED pulled into $outdir}"
    if [ "$MISSING" -gt 0 ]; then
      echo "⚠ COVERAGE INCOMPLETE: $MISSING requested box(es) did NOT answer (${UNRESOLVED_LABELS:-exec failed}) — files may exist there"
    fi
    if [ "$R_PULLFAIL" -gt 0 ]; then
      echo "PULL-FAILED($R_PULLFAIL file(s) did NOT arrive — see the ✗ lines)"
      exit 5
    fi
    exit 0
    ;;
  ls)
    T="$(printf '\t')"; reached=0
    show() {  # show <label> <vm> <fragment> <cap> <what> — checked in BOTH scans, not just the first
      local label="$1" vm="$2" frag="$3" cap="$4" what="$5" raw first rows
      raw="$(scan "$vm" "$frag" "$since" 0)"
      first="$(printf '%s\n' "$raw" | head -1)"
      if [ "${first:0:7}" = "__NOK__" ]; then
        echo "   UNMEASURED($what: ${first#__NOK__ })"; return 1
      fi
      if [ "$first" != "__OK__" ]; then
        # ⛔ The inventory verb must not turn a dead box into an empty, healthy-looking list (exit 0) —
        # indistinguishable from "nothing in /tmp" — in the verb used to DISCOVER what exists.
        echo "   UNMEASURED($what: exec did not answer)"; return 1
      fi
      rows="$(printf '%s\n' "$raw" | tail -n +2 | grep -v '^$')"
      [ -n "$rows" ] || return 0
      n="$(printf '%s\n' "$rows" | wc -l | tr -d ' ')"
      printf '%s\n' "$rows" | head -n "$cap" | awk -F"$T" '{printf "  %10s  %s  %s\n", $2, $1, $3}'
      [ "$n" -gt "$cap" ] && echo "   ⚠ shown $cap of $n — pass a narrower pattern with \`collect\` for the rest"
      return 0
    }
    while read -r label vm; do
      [ -n "${label:-}" ] || continue
      echo "== $label"
      ok_md=0; ok_log=0
      show "$label" "$vm" ".md" 25 "md" && ok_md=1
      show "$label" "$vm" ".log" 10 "log" && ok_log=1
      if [ "$ok_md" -eq 1 ] || [ "$ok_log" -eq 1 ]; then reached=$((reached + 1)); fi
    done <<< "$MAP"
    # ⛔ A REQUESTED BOX THAT NEVER RESOLVED MUST BE NAMED. `collect` was fixed for this and `ls` was not,
    # so a label missing from `cmux vm list` produced no header, no UNMEASURED line and exit 0 — silence
    # read as "nothing there", in the verb an operator uses to ask what IS there.
    if [ "${NUNRESOLVED:-0}" -gt 0 ]; then
      for l in $UNRESOLVED_LABELS; do echo "== $l  UNRESOLVED(not in cmux vm list — NOT searched)"; done
    fi
    if [ "$reached" -eq 0 ]; then echo "UNMEASURED(no box answered — says nothing about what is on them)"; exit 4; fi
    if [ "${NUNRESOLVED:-0}" -gt 0 ]; then
      echo "⚠ COVERAGE INCOMPLETE: $NUNRESOLVED requested box(es) were never resolved ($UNRESOLVED_LABELS)"
    fi
    exit 0
    ;;
  *) usage ;;
esac
