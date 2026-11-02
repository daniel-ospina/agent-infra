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
        DIR/.lane-artifacts-index.
        ⛔ DIR is replaced only by a run that collected EVERYTHING (exit 0). A run that finds nothing,
        cannot reach a box, or fails a pull leaves the previous collection and index untouched and says
        so — a failed re-run must never destroy the only copy that exists.
        <pattern> is a glob fragment, so `collect ci-cause` finds /tmp/ci-cause.md.
        `collect '*'` sweeps all of /tmp.

  logs <name> [--out DIR] [--lines N] [--box LABEL]
        The deterministic per-lane stdout: /tmp/<name>.log, written by the dispatcher's launcher
        (`nohup pi -p < brief > /tmp/<name>.log`). This IS a cell lane's stdout.

  ls [--box LABEL] [--since MINUTES]
        Inventory of /tmp/*.md and /tmp/*.log per box. More than 200 matches on a box is a row-capped
        scan and ABSTAINS (exit 4) rather than printing a short list as a total.

Exit: 0 found · 3 ABSENT-EVERYWHERE · 4 UNMEASURED (absent NOT claimed) · 5 PULL-FAILED · 64 usage.
      `--since` takes whole minutes and must be >= 1. `--box` takes one non-empty label.
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
# ⛔ NO PIPE INTO A QUIET GREP. `printf … | grep -Eq` is exactly the idiom scripts/check-no-sigpipe-grep.sh
# refuses (grep -q exits at the first match, the writer dies of SIGPIPE, and under `pipefail` the pipeline
# reports failure — so a VALID number could read as invalid, or vice versa on a longer input). A `case`
# needs no pipe at all, and it is the form the guard itself recommends.
need_num() { case "$2" in ''|*[!0-9]*) echo "lane-artifacts: $1 must be a whole number, got '$2'" >&2; usage ;; esac; }
while [ $# -gt 0 ]; do
  case "$1" in
    # ⛔ `shift 2` with one arg left does NOT shift, so the loop would spin forever on a truncated
    # invocation (`collect ci-cause --out`) — a wedge, not an error. Check the count first.
    --out)     need_val --out "$#";   outdir="$2"; shift 2 ;;
    --lines)   need_val --lines "$#"; need_num --lines "$2"; lines="$2"; shift 2 ;;
    # ⛔ AN EMPTY `--box` WIDENS THE UNIVERSE instead of narrowing it: `need_val` only checks ARITY, so
    # `--box "$cell"` with an unset `$cell` fell through to the three default boxes — the tool then swept
    # every cell while the summary asserted "from 3 of 3 requested box(es)", i.e. a one-box request
    # reported as three, and artifacts from boxes the caller never named landing in --out.
    --box)     need_val --box "$#"
               [ -n "$2" ] || { echo "lane-artifacts: --box needs a non-empty label" >&2; usage; }
               case "$2" in -*) echo "lane-artifacts: --box '$2' looks like an option, not a label" >&2; usage ;; esac
               only_box="$2"; shift 2 ;;
    # A unit suffix (`--since 30m`) used to reach the remote `find` as `-mmin -30m`, whose error was
    # discarded — so the scan returned no rows and the tool claimed ABSENT about a file that exists.
    # Validate here, where a usage error is a usage error.
    # ⛔ `0` IS A FILTER THE TOOL CANNOT HONOUR: `find -mmin -0` matches NOTHING by construction, so the
    # run ended at ABSENT-EVERYWHERE about a file present on every box. That is the same defect as
    # `--since 30m` one value over, and the remedy is the same — refuse it, never let an unhonourable
    # filter turn into an absence verdict.
    --since)   need_val --since "$#"; need_num --since "$2"
               [ "$2" -ge 1 ] || { echo "lane-artifacts: --since must be >= 1 minute (0 matches nothing and cannot be honoured as a filter)" >&2; usage; }
               since="$2"; shift 2 ;;
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
#   -> `__OK__` then `size<TAB>mtime<TAB>path` rows, or `__NOK__ <reason>` and nothing else.
#      ⛔ the PATH is the LAST field on purpose — see the `-printf` block in `scan` for the false PASS
#      that a `path<TAB>size<TAB>mtime` order produced (`zz<TAB>7` accepted as a valid row for `zz`).
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
    # `logs` promises EXACTLY /tmp/<name>.log, so backslash-ESCAPE glob metacharacters. The previous
    # bracket-escape form was a silent NO-OP (one escaping layer too many: BRE saw a literal `\(`),
    # so `logs 'x[1]'` glob-matched, found nothing and returned a confident ABSENT-EVERYWHERE
    # about a file that EXISTED. The comment claimed a protection the code lacked.
    case "$4" in
      1) NAME="$(printf "%s" "$1" | sed "s/[][*?\\\\]/\\\\&/g")" ;;
      *) NAME="*$1*" ;;
    esac
    T=$(mktemp 2>/dev/null) || T="/tmp/.lane-artifacts.$$"
    if find "$R" -maxdepth 1 -type f -printf "" 2>/dev/null; then
      # ⛔ THE PATH IS THE LAST FIELD, AND THAT ORDER IS LOAD-BEARING. The first version put `%p` FIRST,
      # so a filename containing a TAB split the row and pushed the real size into the mtime column. The
      # guard against that ("a non-numeric size column means a corrupt row") was INSUFFICIENT: for a name
      # like `zz<TAB>7` the shifted size column IS numeric, so the row was accepted as a valid measurement
      # of `/root/zz` — a DIFFERENT file — which was then pulled, written as the artifact and counted at
      # exit 0, while the matched artifact was never collected and no warning was emitted. With the path
      # last, `read -r sz mt p` keeps a TAB inside the path (only the trailing field absorbs the
      # remainder) and the numeric size guard is then sound for real. A NEWLINE in a filename still
      # splits the record, and there the first field is the mangled tail — non-numeric, so it abstains.
      find "$R" -maxdepth 1 -type f -name "$NAME" ${2:+-mmin -$2} \
        -printf "%s\t%TY-%Tm-%TdT%TH:%TM:%TS\t%p\n" > "$T" 2>/dev/null
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
        printf "%s\t%s\t%s\n" "$(wc -c < "$f" | tr -d " ")" \
          "$(stat -c "%y" "$f" 2>/dev/null || stat -f "%Sm" -t "%FT%T" "$f" 2>/dev/null || echo -)" "$f" >> "$T"
      done < "$L"
      rm -f "$L"
    fi
    if [ "$rc" -ne 0 ]; then
      rm -f "$T"; echo "__NOK__ find-failed(rc=$rc)"; exit 0
    fi
    # Ask for one MORE row than the cap so "exactly ROW_CAP matches" is not mistaken for truncation.
    # ⛔ THE CAPPED READ IS BUFFERED AND ITS STATUS CHECKED BEFORE THE SENTINEL IS EMITTED. Emitting
    # `__OK__` and then letting `head` fail produced `__OK__` + zero rows + exit 0, which the caller reads
    # as "searched, matched nothing" -> ABSENT-EVERYWHERE. `find` was converted to `__NOK__`; the reader
    # was not, and that asymmetry is exactly what this file forbids. The list is already capped, so
    # buffering costs nothing.
    if ! head -n '"$((ROW_CAP + 1))"' "$T" > "$T.rows" 2>/dev/null; then
      rm -f "$T" "$T.rows"; echo "__NOK__ read-failed"; exit 0
    fi
    echo __OK__
    cat "$T.rows"
    rm -f "$T" "$T.rows"
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
          'b=$(base64 < "$1" 2>/dev/null); rc=$?; b=$(printf "%s" "$b" | tr -d "\n"); printf "RC=%s LEN=%s\n%s\n" "$rc" "${#b}" "$b"' \
          lane-artifacts "$path" </dev/null 2>/dev/null)"
  rc="$(printf '%s\n' "$raw" | sed -n '1s/^RC=\([0-9]*\) LEN=.*/\1/p' | tr -d '[:space:]')"
  # ⛔ THE LENGTH IS TAKEN FROM THE VERY STRING THAT WAS SENT, NOT FROM A SECOND READ OF THE FILE.
  # Two earlier versions got this wrong in opposite directions: the first compared against the size from
  # the EARLIER SCAN row (stale — a live lane had grown); the second emitted `wc -c` from a SECOND read in
  # the same exec, which still leaves a window between `base64 < file` and `wc -c < file`. Measured by
  # review: a fixture appended every 3 ms failed 2 of 3 runs — a BYTE-PERFECT artifact discarded as
  # "TRUNCATED" at exit 5, on exactly the case `logs` exists for. `${#b}` is computed from the payload
  # itself, so there is no window at all, and a cut of even one character is still caught.
  want_len="$(printf '%s\n' "$raw" | sed -n '1s/^RC=[0-9]* LEN=//p' | tr -d '[:space:]')"
  b64="$(printf '%s\n' "$raw" | tail -n +2 | tr -d '[:space:]')"
  if [ "${rc:-1}" != "0" ]; then
    printf '  ✗ pull failed (remote exit %s — unreadable or UNMEASURED): %s\n' "${rc:-?}" "$path" >&2
    rm -f "$dest"          # a stale copy from an earlier run must not survive as this run's result
    return 1
  fi
  if [ -z "${want_len:-}" ]; then
    # A missing in-band length is UNMEASURED — do NOT fall back to the scan row's size, which is the
    # stale comparison this check exists to avoid.
    printf '  ✗ pull failed (no in-band length — UNMEASURED): %s\n' "$path" >&2
    rm -f "$dest"; return 1
  fi
  if [ "${#b64}" != "$want_len" ]; then
    printf '  ✗ TRUNCATED: %s arrived with %s base64 chars, the box sent %s — discarded\n' \
      "$path" "${#b64}" "$want_len" >&2
    rm -f "$dest"; return 1
  fi
  if ! printf '%s' "$b64" | base64 -D > "$dest" 2>/dev/null && \
     ! printf '%s' "$b64" | base64 -d > "$dest" 2>/dev/null; then
    printf '  ✗ decode failed: %s\n' "$path" >&2; rm -f "$dest"; return 1
  fi
  # ⛔ `rc=$?` MUST FOLLOW `base64`, NOT A PIPELINE. The remote is `sh -c` with no `pipefail`, so with
  # `base64 < f | tr -d "\n"` inside the substitution, `rc` captured *tr*'s status — always 0. An
  # unreadable or vanished file therefore produced rc=0, LEN=0, and the length check compared 0 == 0 and
  # PASSED: `✓ wrote … (0 bytes)` at exit 0, indistinguishable from a lane that legitimately wrote nothing.
  # A false PASS on the one verb whose purpose is to stop exactly that. The strip is a separate statement.
  got="$(wc -c < "$dest" | tr -d '[:space:]')"
  # `want` (the scan size) may NOT reject — a live lane grows — but it can still say DIRECTIONALLY that a
  # 0-byte result is suspicious, which is the cheap cross-check for a file that vanished mid-flight.
  if [ "$got" = "0" ] && [ -n "${want:-}" ] && [ "${want:-0}" != "0" ] && [ "${want:-?}" != "?" ]; then
    printf '  ⚠ %s pulled 0 bytes but the scan measured %s — the file may have vanished mid-flight\n' \
      "$path" "$want" >&2
  fi
  printf '  ✓ wrote %s (%s bytes)\n' "$dest" "$got"
  PULL_BYTES="$got"        # the size actually written, so the index does not record the stale scan size
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
  local raw first res rows p sz mt dest prev
  raw="$(scan "$vm" "$pat" "$since" "$exact")"; local _src=$?
  # ⛔ THE EXEC'S OWN STATUS IS CHECKED, not just the sentinel. `__OK__` is printed by the remote shell
  # BEFORE it streams the rows, so a channel that dies mid-scan (the 60 s timeout firing, a dropped
  # connection) hands back the sentinel plus a PARTIAL row list — which read as "searched, matched
  # nothing" and produced a confident ABSENT-EVERYWHERE while the file sat on that box. A short row
  # list is a silent truncation of the universe, so the partial rows are DISCARDED, not used.
  if [ "$_src" -ne 0 ]; then echo "── $label  UNMEASURED(exec failed rc=$_src — the row list may be partial)"; return 1; fi
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
  while IFS="$(printf '\t')" read -r sz mt p; do
    # ⛔ A NON-NUMERIC SIZE COLUMN MEANS THE ROW IS CORRUPT — a newline in a filename splits the record and
    # the leading field then holds a fragment of the path. The old code carried that through to a pull and
    # produced a WRONG VERDICT (a bogus path, then PULL-FAILED) rather than an abstention. Abstain instead:
    # the doctrine is that a failure must never look like a result, and an unparseable row is a failure of
    # the listing, not evidence about the file.
    # ⛔ THIS GUARD IS ONLY SOUND BECAUSE `p` IS LAST: with the path first, a TAB in a filename shifted a
    # real (numeric!) size into this column and the row was accepted as a measurement of a different file.
    # ⛔ IT MUST RUN BEFORE THE EMPTY-PATH `continue`: a record split by a newline leaves a tail line whose
    # PATH field is empty and whose first field is a name fragment — checked in the other order that line
    # was silently skipped and the box read as fully parsed (found while pinning T17).
    case "${sz:-}" in
      ''|""|*[!0-9]*)
        echo "── $label  UNMEASURED(unparseable scan row — newline in a filename? raw: ${sz:-<empty row>} ${p:-<no path field>})"
        R_REACHED=0; R_UNPARSE=$((R_UNPARSE + 1)); return 1 ;;
    esac
    [ -n "${p:-}" ] || continue
    R_HITS=$((R_HITS + 1))
    echo
    echo "── $label  $p  (${sz:-?} bytes, ${mt:-?})"
    # The count and path go as argv, and stderr is kept OUT of the body: a remote "cannot open" — or a
    # `--lines` that `head` rejected — must never be rendered as though it were the artifact's content.
    # ⛔ A SCRATCH FILE IN $TMPDIR, NOT A FIXED /tmp PATH. The preview used `/tmp/.la-prev.$$`: it ignored
    # TMPDIR (so a host with a small or full /tmp fails the preview, and two shards sharing a host share
    # one path space), and a run killed mid-preview left the file behind where nothing reaps it. There is
    # deliberately NO `/tmp/...` fallback: if no scratch file can be made, the preview says so instead of
    # writing to a path it was never given.
    prev="$(mktemp "${TMPDIR:-/tmp}/la-prev.XXXXXX" 2>/dev/null)" || prev=""
    if [ -z "$prev" ]; then
      echo "   ⚠ preview unavailable (no scratch file under ${TMPDIR:-/tmp}) — the file is ${sz:-?} bytes on the box; content not shown"
    else
      "$CM" vm exec --timeout 60 "$vm" -- sh -c 'head -n "$1" -- "$2" 2>/dev/null; exit $?' \
        lane-artifacts "$lines" "$p" </dev/null 2>/dev/null > "$prev" 2>/dev/null
      if [ $? -ne 0 ]; then
        # A failed preview used to render as an EMPTY artifact at exit 0 — content-absence silently
        # standing in for a failed read, the one thing this tool refuses to do everywhere else.
        echo "   ⚠ preview failed (exec did not answer) — the file is ${sz:-?} bytes on the box; content not shown"
      else
        sed 's/^/   /' "$prev"
      fi
      rm -f "$prev"
    fi
    if [ -n "$outdir" ]; then
      # ⛔ STAGED, NOT THE DESTINATION. `dest` used to be `$outdir/<label>-<name>` directly, and `pull`
      # unlinks `$dest` on every failure path (rc!=0, missing in-band length, truncation, decode). So a
      # failed RE-PULL deleted the only good copy from an earlier run while `finish` printed "still holds
      # the PREVIOUS collection" — the round-7 claim, false for exactly the case that matters. Writing to
      # a per-run staging directory keeps the previous collection byte-identical until a run is known
      # complete, which is what `promote_stage`/`discard_stage` in `finish` enforce.
      dest="$OUT_STAGE/${label}-$(basename "$p")"
      if pull "$vm" "$p" "$sz" "$dest"; then
        R_PULLED=$((R_PULLED + 1))
        # label<TAB>SIZE<TAB>path — path LAST, so a TAB inside a filename cannot split the record (#3).
        printf '%s\t%s\t%s\n' "$label" "${PULL_BYTES:-${sz:-?}}" "$p" >> "$IDX_NEW"
      else
        R_PULLFAIL=$((R_PULLFAIL + 1))
      fi
    fi
  done <<< "$res"
  return 0
}

# commit_index — promote the side index this run wrote, and only NOW delete what the previous index
# recorded and this run did not. Reached only from the exit-0 path (every requested box answered AND
# every pull succeeded), which is the only state in which replacing the previous collection is honest.
commit_index() {
  local _l p _s _n new_keys
  [ -n "${outdir:-}" ] || return 0
  if [ ! -f "${IDX:-}" ]; then mv -f "$IDX_NEW" "$IDX" 2>/dev/null; return 0; fi
  # label<TAB>path pairs this run recorded. Exact-match, so a caller-supplied label is handled the same
  # way a default one is; the old `pi-cell-*` glob missed any such label and left run 1's file beside
  # run 2's index for any consumer that globs the directory instead of reading the index.
  #
  # ⛔ THE PATH IS THE LAST FIELD, SO IT MAY CONTAIN A TAB. The row used to be `label<TAB>path<TAB>size`,
  # and the scan parser was fixed to carry a TAB in a filename (T28) — but the index still split the
  # path at the TAB, so `cut -f1,2` collapsed two different artifacts onto one key. Measured: after a
  # complete run that collected only the TAB-named file, run 1's ordinary-named artifact SURVIVED a
  # "complete" run, breaking the stale-file invariant T15 pins for every other name. Size is the field
  # in the middle because it can never contain a TAB; the path takes the rest of the line.
  new_keys="$(awk -F'\t' '{ p=$0; sub(/^[^\t]*\t/,"",p); sub(/^[^\t]*\t/,"",p); print $1 "\t" p }' "$IDX_NEW" 2>/dev/null)"
  while IFS="$(printf '\t')" read -r _l _s p; do
    [ -n "${p:-}" ] || continue
    _n="$_l-$(basename "$p")"
    # ⛔ A HERE-STRING, NOT A PIPE. `producer | grep -q` is the shape this repo's sigpipe guard exists
    # for: grep exits at the first match, the producer dies of SIGPIPE, and under `pipefail` the pipeline
    # reports failure — which here would read as "not in the new index" and DELETE a file this run had
    # just collected, the same data-loss class the promotion exists to prevent.
    if grep -qxF -- "$_l$(printf '\t')$p" <<< "$new_keys"; then continue; fi
    rm -f "$outdir/$_n"
  done < "$IDX"
  mv -f "$IDX_NEW" "$IDX" 2>/dev/null
}

# promote_stage — move this run's staged artifacts onto their final names. Called ONLY from the
# exit-0 path, after every requested box answered and every pull succeeded.
promote_stage() {
  local f
  [ -n "${OUT_STAGE:-}" ] || return 0
  for f in "$OUT_STAGE"/*; do
    [ -e "$f" ] || continue
    mv -f "$f" "$outdir"/ || echo "lane-artifacts: could not promote $(basename "$f") into '$outdir'" >&2
  done
  rm -rf "$OUT_STAGE" 2>/dev/null
  OUT_STAGE=""
}

# discard_stage — throw away everything this run staged. The previous collection is then untouched,
# byte for byte, AND no orphan arrives that the committed (unpromoted) index does not describe.
discard_stage() {
  [ -n "${OUT_STAGE:-}" ] || return 0
  rm -rf "$OUT_STAGE" 2>/dev/null
  OUT_STAGE=""
}

# finish <rc> — the ONE terminal path for `collect`/`logs`: promote the collection on a complete run,
# discard the side index AND the staged files on any other, and say plainly which collection the
# directory now holds.
finish() {
  local rc="$1"
  if [ -n "${outdir:-}" ] && [ -n "${IDX_NEW:-}" ]; then
    if [ "$rc" -eq 0 ] && [ "${R_PULLFAIL:-0}" -eq 0 ]; then
      promote_stage
      commit_index
    else
      rm -f "$IDX_NEW"
      discard_stage
      if [ -f "${IDX:-}" ]; then
        echo "ℹ '$outdir' still holds the PREVIOUS collection — this run ended at exit $rc and did NOT replace it"
      fi
    fi
  fi
  exit "$rc"
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
    R_HITS=0; R_PULLED=0; R_PULLFAIL=0; R_TRUNC=0; R_UNPARSE=0; REACHED=0; REACHED_LABELS=""
    if [ -n "$outdir" ]; then
      mkdir -p "$outdir" 2>/dev/null
      if [ ! -d "$outdir" ] || [ ! -w "$outdir" ]; then
        echo "lane-artifacts: --out '$outdir' is not a writable directory" >&2; exit 64
      fi
      # ⛔ THE PREVIOUS COLLECTION IS NOT TOUCHED UNTIL THIS RUN HAS SOMETHING TO REPLACE IT WITH.
      # A startup pass deleted every file the old index recorded and truncated the index BEFORE the
      # first box was scanned; the run then routinely produced nothing (ABSENT / UNMEASURED /
      # PULL-FAILED) and never repopulated the directory, so a typo'd or failing re-run silently
      # DESTROYED the only orchestrator-side copy of a cell lane's artifact — while the box copy may
      # already be gone after a recycle or a kill. That is the durability this tool exists to provide,
      # so the deletion is the one thing that must not be optimistic. Rows go to a SIDE index and are
      # promoted by `commit_index` only on the path that actually collected everything.
      IDX="$outdir/.lane-artifacts-index"
      IDX_NEW="$outdir/.lane-artifacts-index.new"
      : > "$IDX_NEW" 2>/dev/null || { echo "lane-artifacts: --out '$outdir' index is not writable" >&2; exit 64; }
      # A per-run staging directory INSIDE `$outdir`, so the promotion is a same-filesystem `mv` and a
      # failed run can be discarded whole — leaving neither a destroyed prior copy nor a new file the
      # committed index does not describe. Dot-prefixed so a consumer that globs `*` does not see it.
      OUT_STAGE="$(mktemp -d "$outdir/.la-stage.XXXXXX" 2>/dev/null)" || OUT_STAGE=""
      if [ -z "$OUT_STAGE" ]; then
        echo "lane-artifacts: --out '$outdir' cannot create a staging directory" >&2; exit 64
      fi
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
      finish 4
    fi
    if [ "$R_HITS" -eq 0 ]; then
      if [ "$MISSING" -gt 0 ]; then
        printf 'UNMEASURED(nothing matched on the %s box(es) actually searched:%s — %s requested box(es) did NOT answer (%s), so ABSENT is NOT claimed)\n' \
          "$REACHED" "$REACHED_LABELS" "$MISSING" "${UNRESOLVED_LABELS:-exec failed}"
        finish 4
      fi
      printf 'ABSENT-EVERYWHERE(find %s -maxdepth 1 %s-name "%s" matched nothing%s on all %s box(es):%s)\n' \
        "$ATIF_ROOT" "${since:+-mmin -$since }" "$pat" "${since:+ in the last $since minutes}" "$REACHED" "$REACHED_LABELS"
      finish 3
    fi
    [ "$R_TRUNC" -gt 0 ] && echo "⚠ TRUNCATED at the $ROW_CAP-row cap on $R_TRUNC box(es)"
    # ⛔ A ROW-CAPPED LIST IS A PARTIAL LIST. `collect '*'` with more matches than the cap printed "this list
    # is NOT complete" and still exited 0, so a caller keying on the status read a short list as whole —
    # the same doctrine this file applies to `ls`. Abstain, with a distinct verdict so the operator can
    # tell "incomplete" from "nothing found".
    # ⛔ AN UNPARSEABLE ROW IS AN UNMEASURED BOX, so the whole verdict abstains even when other boxes yielded
    # hits: a corrupt listing means the universe was not fully read, and reporting "found N files" at exit 0
    # would let a caller treat a short list as complete.
    if [ "${R_TRUNC:-0}" -gt 0 ]; then
      echo "FOUND-TRUNCATED($R_HITS file(s) shown, capped at $ROW_CAP per box on $R_TRUNC box(es) — the list is NOT complete; narrow the pattern)"
      finish 4
    fi
    if [ "${R_UNPARSE:-0}" -gt 0 ]; then
      echo "UNMEASURED($R_UNPARSE box(es) returned an unparseable scan row — the list above is NOT complete, so no 'found/absent' verdict is claimed)"
      finish 4
    fi
    # Partial coverage is disclosed on the SUCCESS path too: exit 0 with 1 of 3 boxes silent reads as
    # a complete result to any caller keying on the exit status.
    echo "== $R_HITS file(s) collected from $REACHED of $((NBOX + NUNRESOLVED)) requested box(es)${outdir:+; $R_PULLED pulled into $outdir}"
    if [ "$MISSING" -gt 0 ]; then
      echo "⚠ COVERAGE INCOMPLETE: $MISSING requested box(es) did NOT answer (${UNRESOLVED_LABELS:-exec failed}) — files may exist there"
    fi
    if [ "$R_PULLFAIL" -gt 0 ]; then
      echo "PULL-FAILED($R_PULLFAIL file(s) did NOT arrive — see the ✗ lines)"
      finish 5
    fi
    finish 0
    ;;
  ls)
    T="$(printf '\t')"; ls_hole=0; any_scanned=0
    show() {  # show <label> <vm> <fragment> <cap> <what> — checked in BOTH scans, not just the first
      local label="$1" vm="$2" frag="$3" cap="$4" what="$5" raw first rows
      raw="$(scan "$vm" "$frag" "$since" 0)"; local _src=$?
      if [ "$_src" -ne 0 ]; then echo "   UNMEASURED($what: exec failed rc=$_src — row list may be partial)"; return 1; fi
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
      # ⛔ A ROW-CAPPED SCAN IS NOT A TOTAL. `scan` stops at ROW_CAP, so `n` was at most ROW_CAP+1 while this
      # verb printed it as the population ("shown 25 of 201" about a box holding 250) and exited 0 — a
      # measured total the inventory never measured, in the verb an operator uses to ask what EXISTS. The
      # display cap is fine (it is disclosed and `n` is then true); the ROW cap is a coverage hole and must
      # abstain, exactly as `collect` does on the same signal.
      if [ "$n" -gt "$ROW_CAP" ]; then
        echo "   UNMEASURED($what: more than $ROW_CAP matches — the scan is row-capped, so this inventory is NOT complete; use \`collect\` with a narrower pattern)"
        return 1
      fi
      printf '%s\n' "$rows" | head -n "$cap" | awk -F"$T" '{printf "  %10s  %s  %s\n", $1, $3, $2}'
      [ "$n" -gt "$cap" ] && echo "   ⚠ shown $cap of $n — pass a narrower pattern with \`collect\` for the rest"
      return 0
    }
    while read -r label vm; do
      [ -n "${label:-}" ] || continue
      echo "== $label"
      ok_md=0; ok_log=0
      show "$label" "$vm" ".md" 25 "md" && ok_md=1
      show "$label" "$vm" ".log" 10 "log" && ok_log=1
      # ⛔ BOTH scans must be guarded: a partial inventory (one scan failed, the other returned rows)
      # used to exit 0, so a caller keying on the status could not tell a complete inventory from a
      # partial one. Any failed scan is a COVERAGE hole and the verb abstains.
      if [ "$ok_md" -ne 1 ] || [ "$ok_log" -ne 1 ]; then ls_hole=$((ls_hole + 1)); fi
      if [ "$ok_md" -eq 1 ] || [ "$ok_log" -eq 1 ]; then any_scanned=$((any_scanned + 1)); fi
    done <<< "$MAP"
    # so a label missing from `cmux vm list` produced no header, no UNMEASURED line and exit 0 — silence
    # read as "nothing there", in the verb an operator uses to ask what IS there.
    if [ "${NUNRESOLVED:-0}" -gt 0 ]; then
      for l in $UNRESOLVED_LABELS; do echo "== $l  UNRESOLVED(not in cmux vm list — NOT searched)"; done
    fi
    # "no box answered" is decided on ANY scan answering, not on a complete one — otherwise a fleet where
    # every `.log` scan failed reported "no box answered" while `.md` inventories had printed fine.
    if [ "$any_scanned" -eq 0 ]; then echo "UNMEASURED(no box answered — says nothing about what is on them)"; exit 4; fi
    if [ "${NUNRESOLVED:-0}" -gt 0 ]; then
      echo "⚠ COVERAGE INCOMPLETE: $NUNRESOLVED requested box(es) were never resolved ($UNRESOLVED_LABELS)"
    fi
    # ⛔ A PARTIAL INVENTORY IS NOT AN INVENTORY. Both scans were ORed, so a box whose `.md` scan failed
    # while `.log` succeeded counted as "reached" and the verb exited 0 — a caller keying on the status
    # could not tell a complete inventory from a partial one, in the verb used to discover what exists.
    # A failed scan is a coverage hole, so the verb abstains rather than reporting a short list as whole.
    if [ "$ls_hole" -gt 0 ] || [ "${NUNRESOLVED:-0}" -gt 0 ]; then
      echo "UNMEASURED($((ls_hole + NUNRESOLVED)) requested box(es) could not be fully inventoried — a scan failed or a label never resolved; the list above is NOT complete)"
      exit 4
    fi
    exit 0
    ;;
  *) usage ;;
esac
