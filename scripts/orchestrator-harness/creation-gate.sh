#!/usr/bin/env bash
# creation-gate.sh — THE creation gate, asked at the ACT (#2535).
#
# WHY THIS FILE EXISTS (measured, 2026-10-23). #2460 put a correct creation gate where a WORKER is
# spawned (`run_agent` in spawn-gate.sh, keyed on the exported KIND). Run against live numbers at
# 16:15Z it answered, correctly:
#
#     LAND-BACKLOG 69 open / 1.8 landings per hour (ceiling 44 …) — hold new creation   [rc=1]
#
# …and in the half hour before that reading SIX PRs were created (#2524 #2525 #2527 #2529 #2530
# #2534). The gate was right and it was bypassed, because it asks *"may a worker of this KIND
# start?"* and never *"may this PR be created?"*. Those are different questions:
#
#   * `fixer`/`reviewer`/`prfix` are exempt by design (their product IS the drain) — but nothing
#     stopped an exempt worker from opening a NEW PR. 7 of the last 10 PRs are follow-ups to a PR
#     under review, i.e. created from inside exactly those exempt paths.
#   * a `task` sub-agent inside a running lane is spawned by `pi` itself, never through `run_agent`;
#   * an interactive session / `cmux send` into a live pane never passes `run_agent` either;
#   * and the gate is a property of each box's pinned `$O` copy, not of the repo: the copy on this
#     cell is dated 05:03Z while #2460 landed at 14:02Z, so that box enforces nothing and says so
#     nowhere (no `[land-backlog]` line exists in any log on it).
#
# So this is the SAME threshold and the SAME window as #2460, asked at a boundary every creation
# path must cross: `gh pr create` — wired in `gh-rest/gh`, the one `gh` every harness process
# resolves first on PATH (install.sh seeds `$O/gh-rest` and puts it first, on Macs and cells alike).
#
# ── THE MEASUREMENT, AND WHY IT IS THIS ONE ─────────────────────────────────────────────────────
# Little's law: L = λW. The open PRs are the system's WIP (L), the landing rate is its throughput
# (λ), and lead time (W) is what the operator actually feels. At constant throughput the ONLY lever
# on lead time is WIP — and a fleet with free lane slots in front of a 69-PR queue reads perfectly
# healthy while opening the 70th. So the gate asks the question in the units the law uses: at the
# current landing rate, how long does the open queue take to drain? If that is longer than the lead
# time we accept, creation is held.
#
# ⛔ AND IT CAPS ARRIVALS ONLY — NEVER THE SERVICE. In M/M/1, W = 1/(μ−λ) and standing L = λ/(μ−λ):
# throttling μ (merges, fixes, measurements) RAISES both. A gate that also held a landing lane
# during a landing backlog would be self-defeating and, at the limit, a deadlock — nothing admitted
# and nothing landed. That is why `land`/`fix`/`measure` are unconditionally allowed below, and why
# it is a REQUIREMENT rather than a loophole: the drain is the one capability the constraint exists
# to protect.
#
# ── THE THREE STATES, AND THE ASYMMETRY THAT IS DELIBERATE ──────────────────────────────────────
#   MEASURED-OVER   → `create` REFUSED (rc 1), quoting the numbers
#   MEASURED-OK     → `create` allowed (rc 0)
#   UNREADABLE      → `create` REFUSED (rc 3), `land`/`fix`/`measure` still allowed (rc 0)
#
# A stale stamp, a failed read, an absent cache and a missing gate script are ALL "UNREADABLE" and
# are NEVER a zero: a ratio that silently reads 0 would refuse every creation for ever, and one that
# silently reads 100 would allow every creation for ever. The asymmetry in the third state is the
# point: a false hold costs one re-dispatch, while refusing to land because GitHub was unreachable
# would freeze the fleet in exactly the moment it must keep moving.
#
# USAGE
#   creation-gate.sh --kind=create|land|fix|measure [--repo owner/name] [--now <epoch>] [--quiet]
#
# rc 0 = allowed · 1 = REFUSED (measured over) · 2 = usage · 3 = REFUSED (unreadable)
#
# STATED LIMITS (the same class the gh-shim names, so nobody reads this as more than it is):
#   * `--kind` is DECLARED BY THE CALLER. A creation that declares itself `land` is not caught here;
#     the value of the flag is that the harness's own paths declare honestly and a future path has
#     to make a choice instead of inheriting "allowed". The ACT gate in gh-rest/gh does not take the
#     caller's word — it IS `pr create`.
#   * the cache is a file under `$O/state`, so a caller with write access to `$O` can forge a fresh
#     reading. This gate raises the cost of an INVOLUNTARY creation; it is not a defence against a
#     caller who removes it (same class as `GH_REST_REAL_GH` / `AGENT_ADMIN_MERGE_OVERRIDE`).
#   * it measures ONE repo, the one being created into. A fleet opening PRs in five repos can be
#     under every individual ceiling and still be over its total capacity; that is a fleet-level
#     question and is not answered here.
set -u

# ── THE CONSTANTS: the window and the threshold live HERE, once ────────────────────────────────
# Nothing else in the harness states them. `CG_MAX_LEAD_H` is the lead time we accept for one open
# PR; the floor is DERIVED from it (a queue that drains inside 24h has a per-hour drain rate of
# 1/24 = 4.2% of the open count), so the two can never drift apart.
CG_WINDOW_MIN=60                                   # observation window
CG_MAX_LEAD_H=24                                   # accepted lead time for one open PR, in hours
CG_DRAIN_PCT10=$(( (1000 + CG_MAX_LEAD_H - 1) / CG_MAX_LEAD_H ))   # 4.2%, in TENTHS of a percent
CG_CACHE_MAX_AGE_S=600                             # a read older than this is UNKNOWN, never zero
CG_MERGED_SAMPLE=100                               # nodes read; the window is far inside this

KIND=""; REPO=""; NOW=""; QUIET=0
while [ $# -gt 0 ]; do
  arg="$1"
  case "$arg" in
    --kind=*)  KIND="${arg#--kind=}" ;;
    --repo=*)  REPO="${arg#--repo=}" ;;
    --now=*)   NOW="${arg#--now=}" ;;
    # The two-token spellings are accepted because a CALLER already passes them that way
    # (`gh-rest/gh` forwards `--repo <slug>` as gh's own flag pair). Accepting only the `=` form
    # made the first live call fail with a usage error, which is exactly the kind of near-miss a
    # gate must not have: it refuses for the wrong reason and blames the operator.
    --kind|--repo|--now)
      [ $# -ge 2 ] || { printf 'creation-gate: %s needs a value\n' "$arg" >&2; exit 2; }
      case "$arg" in
        --kind) KIND="$2" ;;
        --repo) REPO="$2" ;;
        --now)  NOW="$2" ;;
      esac
      shift ;;
    --quiet)   QUIET=1 ;;
    -h|--help)
      sed -n '2,60p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'creation-gate: unknown argument %s\n' "$arg" >&2; exit 2 ;;
  esac
  shift
done

usage() {
  printf 'creation-gate: --kind is REQUIRED and has no default (an unlabelled dispatch is not a\n' >&2
  printf '  dispatch anyone reasoned about): --kind=create|land|fix|measure\n' >&2
  exit 2
}

# ⛔ NO DEFAULT. A default would be the "unsafe default" this flag exists to remove: every caller
# that forgot it would silently inherit one behaviour, and the direction it happened to pick would
# be an accident of history rather than a decision. `measure` is a first-class kind for the same
# reason — a measurement lane must be dispatchable during a hold, or nobody can watch the queue.
case "$KIND" in
  create|land|fix|measure) : ;;
  "") usage ;;
  *) printf 'creation-gate: --kind=%s is not one of create|land|fix|measure\n' "$KIND" >&2; exit 2 ;;
esac

now_epoch() {  # the one clock read; `--now` exists so a test can pin the stamp arithmetic
  if [ -n "$NOW" ]; then printf '%s' "$NOW"; else date +%s; fi
}
NOW_EPOCH="$(now_epoch)"
case "$NOW_EPOCH" in ''|*[!0-9]*) printf 'creation-gate: --now must be an epoch, got %s\n' "$NOW_EPOCH" >&2; exit 2 ;; esac

# ── the repo this creation is going INTO ────────────────────────────────────────────────────────
# `--repo` when the caller states it (gh's own precedence), else the checkout's origin. Deriving it
# rather than defaulting matters: grading the wrong repo's queue is a fail-open that reads green
# (#2040 measured three cells logging another repo's open count for hours).
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
if [ -z "$REPO" ]; then
  if [ -f "$SELF_DIR/repo-slug.sh" ]; then
    # shellcheck disable=SC1091
    . "$SELF_DIR/repo-slug.sh" 2>/dev/null || true
  fi
  if command -v repo_slug_from_remote >/dev/null 2>&1; then
    REPO="$(repo_slug_from_remote "$(git remote get-url origin 2>/dev/null)" 2>/dev/null)" || REPO=""
  fi
fi
case "$REPO" in
  */*) : ;;
  *)   REPO="" ;;
esac

O_DIR="${O:-$HOME/orchestrator}"
STATE_DIR="$O_DIR/state"
CACHE=""
[ -n "$REPO" ] && CACHE="$STATE_DIR/creation-ratio-$(printf '%s' "$REPO" | tr '/' '-').tsv"

say()  { [ "$QUIET" = 1 ] || printf 'creation-gate: %s\n' "$*"; }
warn() { printf 'creation-gate: %s\n' "$*" >&2; }

# ── the three verdicts, as functions, so the refusal and the allowance cannot disagree ─────────
allow_drain() {  # <why> — land/fix/measure: the service side is never throttled
  if [ -n "${1:-}" ]; then say "OK kind=$KIND — $1"; else say "OK kind=$KIND"; fi
  exit 0
}
refuse_over() {  # <open> <lands> <pct10> <rate10>
  printf 'creation-gate: REFUSED kind=create — %s open, %s landed in %s min (ratio %s.%s%% < %s.%s%% floor = a %sh lead time at this drain rate). Creation is HELD; land/fix/measure are always allowed, and nothing was created.\n' \
    "$1" "$2" "$CG_WINDOW_MIN" "$(( $3 / 10 ))" "$(( $3 % 10 ))" \
    "$(( CG_DRAIN_PCT10 / 10 ))" "$(( CG_DRAIN_PCT10 % 10 ))" "$CG_MAX_LEAD_H" >&2
  exit 1
}
refuse_unreadable() {  # <reason>
  printf 'creation-gate: REFUSED kind=create — measurement UNREADABLE (%s). A failed or stale read is never a zero, so creation is HELD (fail closed: a false hold costs one re-dispatch, a false allow adds PRs that nothing lands). land/fix/measure are UNAFFECTED (fail open: refusing to land because GitHub was unreachable would freeze the fleet exactly when it must keep moving).\n' \
    "$1" >&2
  exit 3
}

# ── ONE cached read ────────────────────────────────────────────────────────────────────────────
# `gh api graphql` is rate-limited and has been exhausted twice today, so the measurement is read
# ONCE and shared by every creation in the window. The stamp is what makes staleness detectable:
# without it an old file is indistinguishable from "no queue", which is the silent-zero failure.
read_cache() {  # -> sets C_AT C_OK C_OPEN C_LANDS ; rc 1 when absent/unparseable
  [ -n "$CACHE" ] && [ -f "$CACHE" ] || return 1
  local line
  line="$(grep -v '^#' "$CACHE" 2>/dev/null | head -1)" || return 1
  [ -n "$line" ] || return 1
  # `<read_at>\t<ok|failed>\t<open>\t<lands>\t<window_min>`
  C_AT="$(printf '%s' "$line" | cut -f1)"
  C_OK="$(printf '%s' "$line" | cut -f2)"
  C_OPEN="$(printf '%s' "$line" | cut -f3)"
  C_LANDS="$(printf '%s' "$line" | cut -f4)"
  C_WIN="$(printf '%s' "$line" | cut -f5)"
  case "$C_AT" in ''|*[!0-9]*) return 1 ;; esac
  [ "$C_OK" = "ok" ] || return 1
  case "$C_OPEN$C_LANDS" in *[!0-9]*) return 1 ;; esac
  return 0
}

write_cache() {  # <read_at> <ok|failed> <open|-1> <lands|-1>
  [ -n "$CACHE" ] || return 0
  mkdir -p "$STATE_DIR" 2>/dev/null || return 0
  { printf '# creation-gate cache (#2535) — window=%s min, floor=%s.%s%%\n' \
      "$CG_WINDOW_MIN" "$(( CG_DRAIN_PCT10 / 10 ))" "$(( CG_DRAIN_PCT10 % 10 ))"
    printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$CG_WINDOW_MIN"
  } >"$CACHE.tmp.$$" 2>/dev/null && mv -f "$CACHE.tmp.$$" "$CACHE" 2>/dev/null || rm -f "$CACHE.tmp.$$" 2>/dev/null
  return 0
}

measure() {  # -> sets M_OPEN M_LANDS ; rc 1 with M_WHY set when it cannot be read
  local q out
  # ONE query, two counts. `open` is a totalCount; the merged nodes are ordered by UPDATED_AT
  # descending, which for a merged PR is its merge time — so a window inside the sample is exact and
  # the sample size is not reached by a 60-minute window unless the repo lands >100 PRs/hour.
  q="query(\$o:String!,\$n:String!){repository(owner:\$o,name:\$n){"
  q="$q open: pullRequests(states:OPEN){ totalCount }"
  q="$q merged: pullRequests(states:MERGED, orderBy:{field:UPDATED_AT, direction:DESC}, first:$CG_MERGED_SAMPLE){ nodes { mergedAt } } } }"
  if ! out="$(gh api graphql -f "query=$q" -f "o=${REPO%%/*}" -f "n=${REPO##*/}" 2>&1)"; then
    M_WHY="the gh read failed: $(printf '%s' "$out" | tail -1 | cut -c1-160)"; return 1
  fi
  # ⛔ python3, not jq: gh-rest/gh already requires it for every projection, so it is on the box in
  # every state this gate can run in — and a missing jq must not be able to read as "no PRs".
  if ! out="$(printf '%s' "$out" | CG_NOW="$NOW_EPOCH" CG_WIN="$CG_WINDOW_MIN" python3 -c '
import json, os, sys
try:
    d = json.load(sys.stdin)["data"]["repository"]
    open_n = int(d["open"]["totalCount"])
    cut = int(os.environ["CG_NOW"]) - int(os.environ["CG_WIN"]) * 60
    lands = 0
    for nd in (d.get("merged") or {}).get("nodes") or []:
        m = nd.get("mergedAt")
        if not m: continue
        # 2026-10-23T15:04:24Z
        import calendar, time
        try: t = calendar.timegm(time.strptime(m, "%Y-%m-%dT%H:%M:%SZ"))
        except Exception: continue
        if t >= cut: lands += 1
    print("%d %d" % (open_n, lands))
except Exception as e:
    sys.stderr.write("parse: %s\n" % e); raise SystemExit(1)
' 2>&1)"; then
    M_WHY="the gh answer could not be parsed: $(printf '%s' "$out" | tail -1 | cut -c1-160)"; return 1
  fi
  M_OPEN="${out% *}"; M_LANDS="${out#* }"
  case "$M_OPEN$M_LANDS" in ''|*[!0-9]*) M_WHY="non-numeric counts"; return 1 ;; esac
  return 0
}

# ── the verdict ────────────────────────────────────────────────────────────────────────────────
# pct10 = 1000 * (lands * 60 / window) / open  — the drain rate as tenths of a percent of the open
# queue per hour. Integer-only, so the printed number IS the compared number: a refusal that quotes
# a threshold it did not actually compare is a mood, not a measurement.
verdict() {  # <open> <lands> -> sets V_PCT10
  local open="$1" lands="$2" num
  if [ "$open" -le 0 ]; then V_PCT10=999999; return 0; fi   # nothing open: any landing rate clears
  num=$(( lands * 60000 / CG_WINDOW_MIN ))
  V_PCT10=$(( num / open ))
  return 0
}

# ── land / fix / measure: never gated, in ANY state ────────────────────────────────────────────
if [ "$KIND" != "create" ]; then
  if [ -z "$REPO" ]; then allow_drain "the drain is never throttled (repo not resolvable here, which does not matter to a $KIND)"; fi
  if read_cache; then
    if [ $(( NOW_EPOCH - C_AT )) -le "$CG_CACHE_MAX_AGE_S" ]; then
      verdict "$C_OPEN" "$C_LANDS"
      if [ "$V_PCT10" -lt "$CG_DRAIN_PCT10" ]; then
        allow_drain "$C_OPEN open, $C_LANDS landed in $CG_WINDOW_MIN min (ratio $(( V_PCT10 / 10 )).$(( V_PCT10 % 10 ))% < $(( CG_DRAIN_PCT10 / 10 )).$(( CG_DRAIN_PCT10 % 10 ))%) — the drain is exactly the work the floor exists to protect, so a $KIND dispatch is never held"
      fi
    fi
  fi
  allow_drain
fi

# ── create: the measurement must EXIST and be FRESH ───────────────────────────────────────────
if [ -z "$REPO" ]; then
  refuse_unreadable "the repo is not resolvable (no --repo, and 'git remote get-url origin' in $(pwd) is not a GitHub owner/name) — the ratio cannot be measured, so creation is HELD rather than assumed fine"
fi

if read_cache && [ $(( NOW_EPOCH - C_AT )) -le "$CG_CACHE_MAX_AGE_S" ]; then
  :
else
  # Stale or absent: measure ONCE now. A failed read is UNREADABLE, never zero.
  if ! measure; then
    write_cache "$NOW_EPOCH" "failed" "-1" "-1"
    refuse_unreadable "$M_WHY"
  fi
  write_cache "$NOW_EPOCH" "ok" "$M_OPEN" "$M_LANDS"
  C_AT="$NOW_EPOCH"; C_OPEN="$M_OPEN"; C_LANDS="$M_LANDS"
fi

verdict "$C_OPEN" "$C_LANDS"
if [ "$V_PCT10" -lt "$CG_DRAIN_PCT10" ]; then
  refuse_over "$C_OPEN" "$C_LANDS" "$V_PCT10"
fi
say "OK kind=create — $C_OPEN open, $C_LANDS landed in $CG_WINDOW_MIN min (ratio $(( V_PCT10 / 10 )).$(( V_PCT10 % 10 ))% >= $(( CG_DRAIN_PCT10 / 10 )).$(( CG_DRAIN_PCT10 % 10 ))% floor)"
exit 0
