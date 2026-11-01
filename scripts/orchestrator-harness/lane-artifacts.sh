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
# ⛔ THE HONESTY INVARIANT, and it is the whole reason the exit codes are this specific:
#      a failed exec is UNMEASURED, NEVER "absent" — an unreachable box says nothing about its files.
#      0 = found · 3 = every resolved box was reached and matched nothing
#      4 = some/every box UNMEASURED (so "absent" is NOT claimed) · 5 = a requested pull failed
# ⛔ Never make the lane responsible for its own collection: the failure is a lane that died before it
#    could do anything after the kill.
set -uo pipefail

CM="${CMUX_BIN:-/Applications/cmux.app/Contents/Resources/bin/cmux}"
BOXES_DEFAULT="${LANE_ARTIFACT_BOXES:-pi-cell-1 pi-cell-3 pi-cell-4}"
# The directory scanned on each box. `/tmp` in production; overridable ONLY so the test can build a
# fixture tree instead of asserting against whatever happens to be on a live box.
ATIF_ROOT="${LANE_ARTIFACT_ROOT:-/tmp}"

usage() {
  cat >&2 <<'EOF'
usage: lane-artifacts.sh <verb> [args]

  collect <pattern> [--out DIR] [--lines N] [--box LABEL] [--since MINUTES]
        Find every /tmp/*<pattern>* on the cells, print it (first --lines, default 40),
        and with --out write each FULL file to DIR/<cell>-<basename> and record it in
        DIR/.lane-artifacts-index (truncated per run).
        <pattern> is a glob fragment, so `collect ci-cause` finds /tmp/ci-cause.md.
        `collect '*'` sweeps all of /tmp.

  logs <name> [--out DIR] [--lines N] [--box LABEL]
        The deterministic per-lane stdout: EXACTLY /tmp/<name>.log (no glob), written by the
        dispatcher's launcher (`nohup pi -p < brief > /tmp/<name>.log`). This IS a cell lane's stdout.

  ls [--box LABEL] [--since MINUTES]
        Inventory of /tmp/*.md and /tmp/*.log per box.

Exit: 0 found · 3 ABSENT-EVERYWHERE · 4 UNMEASURED (absent NOT claimed) · 5 PULL-FAILED.
EOF
  exit 64
}

verb="${1:-}"; [ -n "$verb" ] || usage; shift || true

pattern=""; outdir=""; lines=40; only_box=""; since=""
need_val() { [ "$2" -ge 2 ] || { echo "lane-artifacts: missing value for $1" >&2; usage; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    # ⛔ `shift 2` with one arg left does NOT shift, so the loop would spin forever on a truncated
    # invocation (`collect ci-cause --out`) — a wedge, not an error. Check the count first.
    --out)     need_val --out "$#";   outdir="$2"; shift 2 ;;
    --lines)   need_val --lines "$#"; lines="$2";  shift 2 ;;
    --box)     need_val --box "$#";   only_box="$2"; shift 2 ;;
    --since)   need_val --since "$#"; since="$2";  shift 2 ;;
    -h|--help) usage ;;
    *)         if [ -z "$pattern" ]; then pattern="$1"; shift; else echo "unexpected arg: $1" >&2; usage; fi ;;
  esac
done

# `cmux vm exec` addresses a box by its VM NAME, not its label — passing the label fails with an
# opaque `Reference: <hash>`. Resolve label -> name from `cmux vm list` and NAME the labels that could
# not be resolved, rather than silently collecting from fewer boxes than the operator believes.
resolve_boxes() {
  local want="$1" list label name labels
  list="$("$CM" vm list </dev/null 2>/dev/null)" || { echo "UNMEASURED cmux-vm-list-failed" >&2; return 1; }
  labels="$BOXES_DEFAULT"; [ -n "$want" ] && labels="$want"
  for label in $labels; do
    name="$(printf '%s\n' "$list" | awk -v L="$label" '$2==L {print $1; exit}')"
    if [ -n "$name" ]; then printf '%s %s\n' "$label" "$name"
    else printf 'UNMEASURED no-VM-labelled-%s\n' "$label" >&2; fi
  done
}

# scan <vm> <pattern> <since_minutes> <exact:0|1>
#   -> `__OK__` sentinel, then `path<TAB>size<TAB>mtime` rows.
# `find <root> -maxdepth 1` is an EXPLICIT, BOUNDED start point (never a root walk).
#
# ⛔ `</dev/null` IS LOAD-BEARING ON EVERY EXEC THAT RUNS INSIDE A `while read … <<< "$MAP"` LOOP —
#    this one included. An exec that inherits that here-string EATS the unread rows, so whole boxes are
#    skipped and the tool answers "ABSENT-EVERYWHERE" about a file that is present. Found in `pull`
#    first (the last matched file vanished from every run); the same shape was then still present here,
#    which is why this comment names the loop rather than the call — grep for `</dev/null` and every
#    exec inside a read loop must have one.
#
# ONE syscall pass per box: `-printf` replaces a per-file `wc -c`+`stat` subshell (the first version did
# that per file, took ~14 s/box, and silently LOST a row on a slow box — the truncation this tool exists
# to stop producing).
#
# The sentinel is echoed BY THE REMOTE SHELL, so its absence means the exec failed (UNMEASURED) rather
# than "no files". Do not build it with `sed '1s/^/…\n/'` — BSD sed does not expand `\n`, so on a mac
# the sentinel became the literal `__OK__n` and every box read as UNMEASURED while the files sat there.
# `__NOK__` is emitted when `sh` did start but the root is not a readable directory: also UNMEASURED.
scan() {
  local vm="$1" pat="$2" since_min="$3" exact="$4"
  "$CM" vm exec --timeout 60 "$vm" -- sh -c '
    R="$3"
    [ -d "$R" ] && [ -r "$R" ] || { echo __NOK__; exit 0; }
    echo __OK__
    case "$4" in
      1) NAME=$(printf "%s" "$1") ;;
      *) NAME="*$1*" ;;
    esac
    if find "$R" -maxdepth 1 -type f -printf "" 2>/dev/null; then
      find "$R" -maxdepth 1 -type f -name "$NAME" ${2:+-mmin -$2} \
        -printf "%p\t%s\t%TY-%Tm-%TdT%TH:%TM:%TS\n" 2>/dev/null | head -200
    else
      # No -printf => BSD/busybox find (a mac, or a stripped image). Same rows, per-file stat: slower,
      # and only ever the fallback. WITHOUT IT the mac-side test could not exercise the real scan at
      # all — `-printf` silently returned nothing and every fixture box read as empty, i.e. a
      # portable-looking tool that only works on GNU find is a false PASS waiting to happen.
      # `stat -c` is tried FIRST because Linux is the production platform; GNU `stat -f` means
      # --file-system and would SUCCEED while printing filesystem status, so the BSD arm would never
      # fall through and the mtime column would be garbage for every row.
      find "$R" -maxdepth 1 -type f -name "$NAME" ${2:+-mmin -$2} 2>/dev/null | head -200 |
        while IFS= read -r f; do
          printf "%s\t%s\t%s\n" "$f" "$(wc -c < "$f" | tr -d " ")" \
            "$(stat -c "%y" "$f" 2>/dev/null || stat -f "%Sm" -t "%FT%T" "$f" 2>/dev/null || echo -)"
        done
    fi
  ' lane-artifacts "$pat" "$since_min" "$ATIF_ROOT" "$exact" </dev/null 2>/dev/null
}

# pull <vm> <remote path> <remote size> <dest>
#   Byte-exact or it FAILS: a `cmux vm exec` cut mid-stream at a 4-char-aligned base64 boundary decodes
#   cleanly to a TRUNCATED file, so the decoded size is compared against the size `scan` already read.
#   The path travels as argv ($1), never interpolated into the command text — a filename containing an
#   apostrophe broke the interpolated form (and its `2>&1` rendered "cannot open" as the artifact body).
#   A 0-byte artifact is a legitimate result (a lane killed between creating and writing) and is NOT a
#   failed pull: the remote exit status decides, not the emptiness of the payload.
pull() {
  local vm="$1" path="$2" want="$3" dest="$4" raw b64 rc got
  # ⛔ THE STATUS GOES FIRST, ON ITS OWN LINE. It used to be a trailing `RC=` marker, and a transfer
  # truncated mid-flight cuts the END off — so the marker itself was destroyed and the tool reported a
  # nonsense "remote exit bGVkZ2VyIG9uIG…" instead of the size mismatch it had actually detected. A
  # prefix marker survives truncation from the end; a suffix marker cannot. (Caught by T10.)
  raw="$("$CM" vm exec --timeout 120 "$vm" -- sh -c 'base64 < "$1" 2>/dev/null; printf "\nRC=%s\n" "$?"' \
          lane-artifacts "$path" </dev/null 2>/dev/null)"
  rc="$(printf '%s\n' "$raw" | sed -n 's/^RC=//p' | tail -1 | tr -d '[:space:]')"
  b64="$(printf '%s\n' "$raw" | sed '/^RC=/d' | tr -d '[:space:]')"
  if [ "${rc:-1}" != "0" ]; then
    printf '  ✗ pull failed (remote exit %s — unreadable or UNMEASURED): %s\n' "${rc:-?}" "$path" >&2
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

MAP="$(resolve_boxes "$only_box")"
NBOX="$(printf '%s\n' "$MAP" | awk 'NF{ n++ } END{ print n+0 }')"
if [ "$NBOX" -eq 0 ]; then echo "UNMEASURED(no box resolved from cmux vm list)"; exit 4; fi

# Emit `collect`-shaped output for one box. Sets R_REACHED=1 when the box answered.
emit_box() {
  local label="$1" vm="$2" pat="$3" exact="$4" outdir="$5" lines="$6" since="$7"
  local raw first res rows p sz mt dest
  raw="$(scan "$vm" "$pat" "$since" "$exact")"
  first="$(printf '%s\n' "$raw" | head -1)"
  if [ "$first" != "__OK__" ]; then
    if [ "$first" = "__NOK__" ]; then
      echo "── $label  UNMEASURED(scan root '${ATIF_ROOT}' is not a readable directory on $label)"
    else
      echo "── $label  UNMEASURED(exec did not answer — says nothing about whether the file exists)"
    fi
    return 1
  fi
  R_REACHED=1
  res="$(printf '%s\n' "$raw" | tail -n +2 | grep -v '^$')"
  [ -n "$res" ] || return 0
  rows="$(printf '%s\n' "$res" | wc -l | tr -d ' ')"
  [ "$rows" -ge 200 ] && R_TRUNC=$((R_TRUNC + 1))
  while IFS="$(printf '\t')" read -r p sz mt; do
    [ -n "${p:-}" ] || continue
    R_HITS=$((R_HITS + 1))
    echo
    echo "── $label  $p  (${sz:-?} bytes, ${mt:-?})"
    # `head -n`/`--` with the count and path as argv, and stderr kept OUT of the body: a remote "cannot
    # open" must never be rendered as though it were the artifact's first lines.
    "$CM" vm exec --timeout 60 "$vm" -- sh -c 'head -n "$1" -- "$2" 2>/dev/null' \
      lane-artifacts "$lines" "$p" </dev/null 2>/dev/null | sed 's/^/   /'
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
    pat="$pattern"; exact=0
    if [ "$verb" = "logs" ]; then
      # EXACT name: `<name>` is documented as the deterministic /tmp/<name>.log, so a glob here would
      # also pull /tmp/<name>.log.bak — "the exact path" and "any path starting with it" are different
      # promises, and the usage text makes the first one.
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
      : > "$outdir/.lane-artifacts-index"   # per-run, not accumulated: an index that cannot say what
    fi                                      # THIS run collected is a stale record, not an index
    echo "== lane-artifacts $verb '$pat' over $NBOX box(es)"
    while read -r label vm; do
      [ -n "${label:-}" ] || continue
      R_REACHED=0
      emit_box "$label" "$vm" "$pat" "$exact" "$outdir" "$lines" "$since"
      if [ "$R_REACHED" -eq 1 ]; then
        REACHED=$((REACHED + 1)); REACHED_LABELS="$REACHED_LABELS $label"
      fi
    done <<< "$MAP"

    echo
    if [ "$REACHED" -eq 0 ]; then
      echo "UNMEASURED(no box answered — this says nothing about whether the file exists)"
      exit 4
    fi
    if [ "$R_HITS" -eq 0 ]; then
      if [ "$REACHED" -lt "$NBOX" ]; then
        # ⛔ DO NOT CLAIM ABSENT WHILE A BOX WAS UNMEASURED. `$MAP` is every RESOLVED box; `$REACHED_LABELS`
        # is every box actually searched — naming $MAP here asserted a search of a box that never
        # answered, which is how "not found" gets read as "does not exist".
        printf 'UNMEASURED(nothing matched on the %s box(es) actually searched:%s — %s box(es) did NOT answer, so ABSENT is not claimed)\n' \
          "$REACHED" "$REACHED_LABELS" "$((NBOX - REACHED))"
        exit 4
      fi
      printf 'ABSENT-EVERYWHERE(find %s -maxdepth 1 -name "%s" matched nothing on all %s box(es):%s)\n' \
        "$ATIF_ROOT" "$pat" "$REACHED" "$REACHED_LABELS"
      exit 3
    fi
    [ "$R_TRUNC" -gt 0 ] && echo "⚠ TRUNCATED at the 200-row cap on $R_TRUNC box(es) — narrow the pattern; this list is NOT complete"
    echo "== $R_HITS file(s) collected from $REACHED box(es)${outdir:+; $R_PULLED pulled into $outdir}"
    if [ "$R_PULLFAIL" -gt 0 ]; then
      echo "PULL-FAILED($R_PULLFAIL of $R_PULLED + $R_PULLFAIL requested file(s) did NOT arrive — see the ✗ lines)"
      exit 5
    fi
    exit 0
    ;;
  ls)
    T="$(printf '\t')"; any=0; reached=0
    while read -r label vm; do
      [ -n "${label:-}" ] || continue
      echo "== $label"
      R_REACHED=0; R_TRUNC=0
      raw="$(scan "$vm" ".md" "$since" 0)"
      first="$(printf '%s\n' "$raw" | head -1)"
      if [ "$first" != "__OK__" ]; then
        # ⛔ The inventory verb must not turn a dead fleet into an empty, healthy-looking list (exit 0):
        # that is indistinguishable from "three boxes with nothing in /tmp", in the verb an operator uses
        # to DISCOVER what exists.
        if [ "$first" = "__NOK__" ]; then echo "   UNMEASURED(scan root '${ATIF_ROOT}' unreadable)"
        else echo "   UNMEASURED(exec did not answer)"; fi
        continue
      fi
      reached=$((reached + 1))
      printf '%s\n' "$raw" | tail -n +2 | grep -v '^$' | head -25 |
        awk -F"$T" '{printf "  %10s  %s  %s\n", $2, $1, $3}'
      raw="$(scan "$vm" ".log" "$since" 0)"
      printf '%s\n' "$raw" | tail -n +2 | grep -v '^$' | head -10 |
        awk -F"$T" '{printf "  %10s  %s  %s\n", $2, $1, $3}'
      any=1
    done <<< "$MAP"
    if [ "$reached" -eq 0 ]; then echo "UNMEASURED(no box answered — says nothing about what is on them)"; exit 4; fi
    exit 0
    ;;
  *) usage ;;
esac
