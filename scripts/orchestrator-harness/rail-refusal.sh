#!/usr/bin/env bash
# rail-refusal.sh — classify and record a MERGE-RAIL refusal, so the controller can spawn a FIXER
# for the head the rail just refused.
#
# WHY THIS FILE EXISTS (measured 2026-10-20, agent-infra). The fleet stalled for a week with a full
# PR queue and ZERO agent lanes:
#
#     open=17   rails "running"=13   merged today=1   cells' agent lanes=0
#     every rail log ended in a refusal line
#
# Rails are bash: they REFUSE a red tree by design and that is correct. Nothing in the controller
# ever turned a refusal into WORK — `merge-one.sh`'s `rail_attempt()` logged the refusal and, at
# `RAIL_TRIES`, parked the PR as "needs a human"; the sweep's only fixer arms are keyed on CHECKS
# (the `FAILED:` classes), and a rail refusal is not a check classification. So a PR whose tree the
# rail refused sat untouched while every actor reported itself healthy. After hand-spawned fixers:
# merged 1 -> 6 in ~40 min, open 19 -> 16.
#
# THE MISSING ROLE IS A SPAWN-ON-REFUSAL, and this file is the half both sides need to agree on:
#
#   writer  `merge-one.sh` (rail_attempt)   — the ONE place that runs the rail, on every ingress
#                                             (controller `merge-<PR>`, `fix-one.sh`, `chain-merge.sh`)
#   reader  `orch-loop.sh` (the sweep)      — the ONE place that may spawn a worker
#
# ⛔ ONE CLASSIFIER, NOT TWO. A refusal's class decides whether a lane is spawned, and the repo has
# already paid for two readers of one fact disagreeing (`objective.classify_one`, #1872: two
# classifiers, 36% and 41% disagreement on the same PRs). So the class is computed HERE, from the
# rail's own text, and the writer stores it: the router never re-parses a log, and re-wording a
# refusal breaks exactly one place (this one) — visibly, because the class falls back to `other`,
# which spawns nothing.
#
# ⛔ THE TRIGGER IS A *RED TREE*, NOT "ANY REFUSAL". The rail exits 1 for a dozen unrelated reasons —
# a draft, an unreadable check surface, a rate limit, a lane-parity refusal, a head that moved. A
# fixer cannot repair any of those, and spawning one would burn the per-head budget on work that
# cannot help (then park the PR for the wrong reason). Only the refusal that says the TREE is red is
# a lane's work: the checks are red, and `fix-one.sh` already knows how to fetch their failing logs
# and fix the cause.
#
# ⛔ THE OVERRIDE PATH IS EXCLUDED, AND IS NEVER TAKEN HERE. `AGENT_ADMIN_MERGE_OVERRIDE=1` is the
# audited route for landing a red tree on purpose (a human's decision, logged as
# `admin_merge_override`). A refusal produced while that is in play is a DECISION, not a defect, so
# it is recorded as class `override` and spawns nothing. Nothing in this file, the recorder or the
# router ever SETS it — a red tree is fixed or reported, never overridden.
#
# ⛔ THE RECORD IS HEAD-BOUND. A rail refusal describes THIS tree; a push makes it obsolete. The head
# is part of the record's identity, so the router can tell "the refusal still stands" from "a fixer
# pushed and this is the old verdict" — the bug where a repaired PR kept being skipped because a
# stale refusal outlived the head it was about.
#
# SOURCED (not executed) by `merge-one.sh` and `orch-loop.sh`. Every function is pure state I/O over
# `$O/state/railrefusal-<PR>`; it starts no process, reads no network, and is exercised directly by
# `red-fixer.test.sh` against a FAKE rail.

# _rr_has <file> <fixed-substring> -> 0 when the file contains the substring on one line.
# `index()` is a LITERAL substring test: the patterns below are the rail's own sentence fragments
# (an em dash, a `✗`), and putting them through a regex would make the match depend on escaping
# rather than on the sentence.
_rr_has() {
  [ -n "${1:-}" ] && [ -f "$1" ] || return 1
  awk -v s="${2:-}" 'index($0, s) { f = 1; exit } END { exit(f ? 0 : 1) }' "$1" 2>/dev/null
}

# _rr_clean <value> -> the value as ONE line (records are key=value, one per line, and every reader
# splits on the newline; a multi-line value would forge a key).
_rr_clean() { printf '%s' "${1:-}" | tr -d '\r\n'; }

# rail_refusal_reason <text-file> -> the refusal's own line, VERBATIM ('' when there is none).
# The red-tree sentence when present (it is the one that decides), otherwise the first
# `admin-merge: ✗` line — so a non-red-tree refusal is still RECORDED and LOGGED with its own words
# rather than summarised into a category name.
rail_refusal_reason() {
  local f="${1:-}" l=""
  [ -n "$f" ] && [ -f "$f" ] || return 0
  l="$(awk 'index($0, "THE TREE THIS PR PRODUCES IS RED") { print; exit }' "$f" 2>/dev/null)"
  if [ -z "${l:-}" ]; then
    l="$(awk 'index($0, "admin-merge: ✗") { print; exit }' "$f" 2>/dev/null)"
  fi
  printf '%s' "${l:-}"
}

# rail_refusal_detail <text-file> -> the line immediately after the red-tree sentence (the rail's
# summary: which checks, on which surface). Empty when the shape is not there — never invented.
rail_refusal_detail() {
  local f="${1:-}"
  [ -n "$f" ] && [ -f "$f" ] || return 0
  awk 'index($0, "THE TREE THIS PR PRODUCES IS RED") { getline; print; exit }' "$f" 2>/dev/null
}

# rail_refusal_class <text-file> [<override-in-play:0|1>] -> red-tree | override | conflict |
# unreadable | other
#
# Allow-list polarity, deliberately: a text this file has never seen is `other`, which spawns
# nothing. A deny-list ("anything not clearly unreadable is repairable") would spawn a fixer for a
# refusal nobody classified — the fail-open shape this repo keeps closing.
rail_refusal_class() {
  local f="${1:-}" ovr="${2:-0}"
  if [ -n "$f" ] && [ -f "$f" ]; then
    if _rr_has "$f" 'THE TREE THIS PR PRODUCES IS RED'; then
      # A red tree landed on purpose is the audited override, not a defect to repair.
      if [ "${ovr:-0}" = "1" ]; then printf 'override'; else printf 'red-tree'; fi
      return 0
    fi
    # The tree could not be MEASURED (gh auth/network, a half-read surface). A fixer cannot repair a
    # measurement, and a lane spawned here would consume an attempt and change nothing.
    if _rr_has "$f" 'evaluated-tree surface was only HALF read' \
       || _rr_has "$f" 'evaluated-tree surface could NOT be read' \
       || _rr_has "$f" 'rate_limited'; then
      printf 'unreadable'; return 0
    fi
    # Merge-conflict-only refusals belong to the sweep's CONFLICTING arm (which integrates
    # origin/main and resolves the conflict). Recording them as a different class keeps the two
    # from fighting over the same PR.
    if _rr_has "$f" 'CONFLICTING' || _rr_has "$f" 'is not mergeable' \
       || _rr_has "$f" 'merge conflict' || _rr_has "$f" 'conflict marker'; then
      printf 'conflict'; return 0
    fi
  fi
  printf 'other'
}

# rail_refusal_record <O> <pr> <head> <attempt> <text-file> [<override-in-play:0|1>]
#   -> writes `$O/state/railrefusal-<PR>` and PRINTS the class.
#
# ATOMIC REPLACE (write a temp, then `mv`): the writer is the rail worker and the reader is the
# controller, two processes, and a reader that caught a half-written record would see `class=` empty
# — which is `other`, i.e. a refusal silently losing its fixer for one cycle. `mv` within one
# directory is atomic, so the reader sees either the old record or the new one.
rail_refusal_record() {
  local o="${1:-}" pr="${2:-}" head="${3:-}" att="${4:-}" txt="${5:-}" ovr="${6:-0}"
  local cls tmp
  cls="$(rail_refusal_class "$txt" "$ovr")"
  # ⛔ NO ARGUMENTS, NO CLAIM: a caller that cannot name the PR gets no class printed, because the
  # printed class is what the caller LOGS as "recorded". Silence + a non-zero rc is the honest answer.
  if [ -z "$o" ] || [ -z "$pr" ]; then return 1; fi
  mkdir -p "$o/state" 2>/dev/null
  tmp="$o/state/.railrefusal-$pr.tmp.$$"
  # ⛔ THE RETURN STATUS IS THE WRITE'S, NOT THE CLASSIFIER'S (review P2, 2026-10-21). This used to
  # print the class and return 0 with every write step's failure discarded, so on an unwritable
  # `state/` the caller logged `refusal recorded: class=red-tree` while NO record existed — the
  # controller then spawned nothing, and the stall this change exists to end came back with a log
  # asserting the opposite. A writer that cannot say "I did not write" is worse than no writer.
  if {
    printf 'head=%s\n'     "$(_rr_clean "$head")"
    printf 'attempt=%s\n'  "$(_rr_clean "$att")"
    printf 'override=%s\n' "$(_rr_clean "$ovr")"
    printf 'class=%s\n'    "$(_rr_clean "$cls")"
    printf 'reason=%s\n'   "$(_rr_clean "$(rail_refusal_reason "$txt")")"
    printf 'detail=%s\n'   "$(_rr_clean "$(rail_refusal_detail "$txt")")"
  } > "$tmp" 2>/dev/null && [ -s "$tmp" ] \
    && mv -f "$tmp" "$o/state/railrefusal-$pr" 2>/dev/null; then
    printf '%s' "$cls"
    return 0
  fi
  rm -f "$tmp" 2>/dev/null
  return 1
}

# rail_refusal_field <O> <pr> <key> -> the value ('' when absent). Non-zero rc when the record or
# the key is missing, so a caller can tell "absent" from "present and empty".
rail_refusal_field() {
  local f="${1:-}/state/railrefusal-${2:-}" k="${3:-}" v=""
  [ -n "${1:-}" ] && [ -n "${2:-}" ] && [ -n "$k" ] || return 1
  [ -f "$f" ] || return 1
  v="$(awk -v k="$k" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); found = 1; exit } END { exit(found ? 0 : 1) }' "$f" 2>/dev/null)" || return 1
  printf '%s' "$v"
}

# rail_refusal_get <record-text> <key> -> the value from a record ALREADY READ (see the note below).
#
# ⛔ ONE READ, THEN PARSE (review P3, cycle 3). `rail_refusal_field` re-opens and re-parses the file
# per key, and TWO writers replace it (merge-one.sh, the cell doctor). Each `mv` is atomic, but FOUR
# reads are not one snapshot: the head could come from one record and the class from the next, i.e.
# a verdict assembled from two different trees. The router therefore `cat`s the record once and
# parses every field out of that string; the file-based reader stays for one-field callers and tests.
rail_refusal_get() {
  local txt="${1:-}" k="${2:-}"
  [ -n "$txt" ] && [ -n "$k" ] || return 1
  printf '%s\n' "$txt" | awk -v k="$k" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); found = 1; exit } END { exit(found ? 0 : 1) }' 2>/dev/null
}

# rail_refusal_clear <O> <pr> -> drop the record (a merged PR, or a head the refusal no longer
# describes). Silence when there was nothing to drop.
rail_refusal_clear() {
  [ -n "${1:-}" ] && [ -n "${2:-}" ] || return 0
  rm -f "$1/state/railrefusal-$2" 2>/dev/null
  return 0
}
