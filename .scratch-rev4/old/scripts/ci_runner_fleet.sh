#!/usr/bin/env bash
# ci_runner_fleet.sh — ONE command that reports the CI runner pool PER CELL, and RECONCILES the two
# sources that can see it (agent-infra#2429; #2373 clause 2).
#
# WHY THIS EXISTS
#   #2373 clause 2 asks for "a `runner-ctl status --all` that reports per-cell: registered names,
#   listener count, live/offline, and the memory reading". #2381 delivered those four facts FOR THE
#   BOX THE TOOL RUNS ON (`ci_runner_pool.sh status`), and said so plainly: "nothing in this repo
#   reports runners per cell". So a capacity decision still needed one session per cell — which is
#   exactly the hand-read sequence that produced #2373 (measured 2026-10-22: the pool went 6 -> 12
#   online entirely by hand, and two runners GitHub showed OFFLINE had DEAD LISTENERS).
#
# ⛔ THE per-box TOOL IS THE SUBSTRATE — THIS IS THE AGGREGATOR, NOT A SECOND PROBE. #2381's `status`
#   output is documented as deliberately machine-readable (`host=… ncpu=… ceiling=… slots=…
#   mem_available=… floor=…`, one `<name> <listener> <state> <github_name>` row per registration, then
#   a `summary …` line) precisely so a cross-cell reader can aggregate it instead of re-implementing
#   the probe. Nothing here re-derives a listener, a slot count or a memory reading: those come from
#   the cell's own `ci_runner_pool.sh`, run ON the cell.
#
# ⛔ TWO SOURCES, RECONCILED — NEVER SUMMED (#2429 clause 2). They disagree in BOTH directions and
#   neither is a superset of the other:
#     * the LOCAL view (`$RUNNER_ROOT` on the box) is the only place a DEAD LISTENER is visible — a
#       registration that is still perfectly valid on GitHub, serving no work;
#     * GitHub's registry (`gh api …/actions/runners`) is the only place a registration that LOST ITS
#       BOX is visible — a `/tmp` wipe leaves registrations on GitHub with no local evidence at all,
#       and a hand-added runner can have a listener with no registration.
#   So a "total" that adds them double-counts, and a total that takes either alone is silently missing
#   one of the two failure classes. A local row is therefore CLAIMED BY ITS `GITHUB_NAME` — the
#   agentName in the instance's `.runner`, which is the identity GitHub knows and is NOT the instance
#   directory's basename (measured on `pi-cell-5`: dir `gh-runner-x64-2` carries agentName
#   `pi-runner-c5-x64-2`; matching on the directory name would report a healthy runner as a phantom).
#
# ⛔ FAIL-CLOSED ON AN UNREADABLE CELL (#2429 clause 3; the class #2381 closed per box). A cell whose
#   pool cannot be read reports `cannot-measure` FOR THAT CELL — never "0 runners". #2381's incident was
#   precisely an unlistable pool read as an empty one, which defused the ceiling. The same rule applies
#   to the registry: an unreadable registry is `read=cannot-measure`, never "0 registrations". And it
#   applies to ATTRIBUTION: a registry name no measured cell claims is a PHANTOM only when every
#   requested cell was measured — while a cell is unmeasured that name may live there, so it is
#   reported as `cannot-attribute`, not as a phantom.
#
# THE TRANSPORT (and the defect it currently meets)
#   Reading a cell needs a channel; the fleet's is `cmux vm exec` (the same one `lane-artifacts.sh`
#   pulls cell artifacts through). ⛔ MEASURED 2026-11-06 FROM `pi-cell-5`, and it is NOT this tool's
#   bug: `cmux vm exec <peer> -- hostname` fails for EVERY peer with
#       cmux: link to '<peer>' exited; see ~/.cmux/peer-links/<peer>.log
#       cmux-tui: no known daemon matches this route; connect with an invitation
#   while `cmux vm ls` prints `running reachable linked` for the same five boxes. That is
#   agent-infra#2345 (P1-severe, open) — the `vm exec` link path does not spend the `--carrier` mode
#   that DOES connect (its own comments record a successful `remote connect … --carrier` against the
#   same peer). This tool is NOT allowed to route around it (AGENTS "Fix Broken Infrastructure"), so
#   today it reports `read=cannot-measure why=transport-unreachable` for every cell and exits 2 — the
#   honest state of the fleet, and exactly clause 3's behaviour, from the first day.
#   `RUNNER_FLEET_EXEC` is the seam where the (one-line) #2345 fix — or the carrier recipe — lands,
#   without touching the aggregation, attribution or exit contract below.
#
# USAGE   ci_runner_fleet.sh [--box LABEL]… [--root PATH] [--no-root-derive]   (see --help)
#
# EXIT  0 every requested cell measured, every row agreed, every registration claimed
#       1 usage
#       2 CANNOT MEASURE — a cell, the roster or a registry could not be read, so no verdict is
#         claimed about what it holds (this OUTRANKS 3: a report that cannot see one cell cannot
#         certify the rest)
#       3 measured, and the report names a defect (a dead/orphaned listener, a tmpdir defect, a
#         registration no cell claims, a local registration GitHub does not have, or a name claimed
#         by two cells)
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SELF_DIR/$(basename "${BASH_SOURCE[0]}")"

# ── the fleet's ONE box inventory, and its ONE bounded-read helper ────────────────────────────────
# `capacity.sh` is a library (its own header documents `. capacity.sh`), already sourced this way by
# `ci_runner_pool.test.sh` and by `orch-loop.sh`. Reusing `cap_fleet_inventory` means this report
# cannot disagree with the placement path about WHICH BOXES EXIST — a second parser of the provider's
# JSON is how one instrument comes to read `expected=5` while another reads `expected=4`.
CAPACITY_LIB="${CAPACITY_LIB:-$SELF_DIR/orchestrator-harness/capacity.sh}"
if [ -r "$CAPACITY_LIB" ]; then
  # shellcheck source=scripts/orchestrator-harness/capacity.sh
  . "$CAPACITY_LIB" >/dev/null 2>&1 || true
fi
if ! declare -f cap_fleet_inventory >/dev/null 2>&1 || ! declare -f cap_bounded >/dev/null 2>&1; then
  printf '%s\n' "ci_runner_fleet: cannot-measure why=capacity-lib-absent ($CAPACITY_LIB) — the box inventory and the bounded-read helper are the fleet's ONE copy; this report does not carry a second"
  exit 2
fi

PROG="ci_runner_fleet"
err() { printf '%s: %s\n' "$PROG" "$*" >&2; }

# ── seams ─────────────────────────────────────────────────────────────────────────────────────────
# ⛔ THE ROSTER. `cmux vm list --json` via capacity.sh by default; an explicit roster when a host has no
# provider CLI (a cell carries none in some images — capacity.sh says so by name), which is the same
# precedence `cap_expected_boxes` applies. NEVER a default that silently shrinks to "the boxes I could
# reach": that is the absence-reads-as-healthy defect (#3446).
FLEET_BOXES="${RUNNER_FLEET_BOXES:-}"
# ⛔ THE EXEC TEMPLATE, NOT A TRANSPORT IMPLEMENTATION. `{box}` is replaced by the box label and the
# remote argv is APPENDED, so the #2345 fix (or the carrier recipe its own comments record) is a seam
# change, not a rewrite of this file.
# ⛔ TWO STEPS ON PURPOSE: `{box}` inside a `${VAR:-default}` word ends the parameter expansion at the
# FIRST `}`, so the one-line form silently produced `cmux vm exec {box --}` — a template with no
# `{box}` placeholder, which the runner then refused for every cell.
FLEET_EXEC="${RUNNER_FLEET_EXEC:-}"
[ -n "$FLEET_EXEC" ] || FLEET_EXEC='cmux vm exec {box} --'
# ⛔ THE REGISTRIES. A cell carries installs registered into MORE THAN ONE repo — MEASURED 2026-11-06
# on `pi-cell-5`: `/opt/gh-runner-*` carry agentNames registered in `daniel-ospina/tortoise` while
# `/opt/ai-runner-cell5-*` carry names registered in `daniel-ospina/agent-infra`. A single-repo default
# would report every install of the other repo as `unregistered` — i.e. as a defect — on a healthy box.
FLEET_REPOS="${RUNNER_FLEET_REPOS:-daniel-ospina/tortoise daniel-ospina/agent-infra}"
FLEET_TIMEOUT="${RUNNER_FLEET_TIMEOUT:-60}"          # per box, and per registry page walk
FLEET_GH="${RUNNER_FLEET_GH:-gh}"
FLEET_ROOT="${RUNNER_FLEET_ROOT:-}"                  # RUNNER_ROOT for every box ('' = the box's own)
FLEET_ROOTS="${RUNNER_FLEET_ROOTS:-}"                # per-box map: "label=/path label=/path"
ROOT_DERIVE=1                                        # retry from the refusal's own `outside=` list
ONLY_BOXES=""

usage() {
  local rc="${1:-1}"
  cat >&2 <<'EOF'
usage: ci_runner_fleet.sh [report] [options]

  One line per cell, then one line per runner, reconciled against GitHub's registry.
  THE REPORT IS ON STDOUT (machine-readable, one fact per line); diagnostics are on stderr.

  --box LABEL        report only this cell (repeatable). A label the roster does not carry is a
                     CANNOT MEASURE, never a silently smaller fleet (exit 2). The boxes it EXCLUDES
                     are counted (`--box` is a SCOPE, not a claim that the rest of the fleet does not
                     exist): a registration they carry is `cannot-attribute(<N>-cell-not-requested)`,
                     never a phantom — so a scoped run never advises `reclaim` on a live runner.
  --root PATH        set RUNNER_ROOT on EVERY cell (default: each cell's own).
  --no-root-derive   do not retry a cell whose pool read was refused as
                     `cannot-measure why=pool-root-incomplete` using the parents of the directories
                     that refusal NAMED. Use when a root is pinned deliberately and must not move.
  -h, --help         this text.

  Report lines:
    registry repo=<name> read=ok runners=…            | read=cannot-measure why=… detail=…
    cell     label=… read=ok host=… ncpu=… ceiling=… slots=… mem_available_mb=… floor_mb=…
             live=… dead=… orphaned=… quarantine=… registrations=… tmpdir_defects=… rc=…
    cell     label=… read=cannot-measure why=… [rc=…] [unclassified=…] detail=…
             (ONE line per requested cell, ALWAYS; where=roster=… for the roster itself)
    cell-note label=… root_derived=…                        (a retry that succeeded)
    runner   cell=… name=… github_name=… listener=… local=… github=… busy=… registry=… verdict=…
             verdict ∈ ok | dead-listener | orphaned | quarantine | defect-<token> |
                       github-offline | github-unreadable | unregistered | cannot-attribute
    registry-unclaimed name=… registry=… status=… reason=no-running-cell-claims-it |
             cannot-attribute(<N>-cell-unmeasured[,<N>-cell-not-requested][,<N>-registry-unread] |
                              name-carried-by-more-than-one-registry)
             `no-running-cell-claims-it` is the ONLY phantom claim: the roster is the provider's
             RUNNING inventory, so a registration held by a STOPPED/parked box lands here too — check
             `cmux vm list` before acting on it.
    name-collision name=… cells=…
    summary  cells=… measured=… unmeasured=… skipped=… registry=… registry_unread=… claimed=…
             unclaimed=… unregistered=… unjoinable=… disagreements=… collisions=… not_ok=…
             (`skipped=` counts the roster boxes --box EXCLUDED — a scope, never a failure)

  Seams: RUNNER_FLEET_BOXES (explicit roster), RUNNER_FLEET_EXEC (exec template, `{box}` substituted),
  RUNNER_FLEET_REPOS (registry repos), RUNNER_FLEET_ROOT / RUNNER_FLEET_ROOTS (RUNNER_ROOT per fleet /
  per cell), RUNNER_FLEET_TIMEOUT (per-read bound, seconds), RUNNER_FLEET_GH (gh binary), CAPACITY_LIB.
EOF
  exit "$rc"
}

while [ $# -gt 0 ]; do
  case "$1" in
    report) shift ;;
    --box)  [ "$#" -ge 2 ] || usage
            case "$2" in ''|-*) err "--box needs a label"; usage ;; esac
            ONLY_BOXES="$ONLY_BOXES $2"; shift 2 ;;
    # ⛔ THE ROOT IS INLINED INTO THE REMOTE SNIPPET, so it is validated HERE, against a charset that
    # cannot carry a quote, a space or a `$`: a value outside it is a usage error, not a remote word.
    --root) [ "$#" -ge 2 ] || usage
            case "$2" in *[!A-Za-z0-9._/-]*|'') err "--root '$2' is not a plain path (allowed: A-Za-z0-9._/-)"; usage ;; esac
            FLEET_ROOT="$2"; shift 2 ;;
    --no-root-derive) ROOT_DERIVE=0; shift ;;
    -h|--help) usage 0 ;;
    *) err "unknown argument '$1'"; usage ;;
  esac
done

TMPD="$(mktemp -d "${TMPDIR:-/tmp}/ci-runner-fleet.XXXXXX")" || { err "cannot-measure why=tmpdir"; exit 2; }
trap 'rm -rf "$TMPD" 2>/dev/null' EXIT
trap 'exit 143' TERM INT HUP

# ── the remote probe ─────────────────────────────────────────────────────────────────────────────
# ⛔ ONE argv WORD, and `@ROOT@` is a SUBSTITUTION, never an eval: the snippet travels as a single
# quoted argument through `cmux vm exec`, so it is a program for the peer's shell, not a re-parse of
# our argv. It searches the documented clone locations because a cell's tree is NOT at this box's
# path (`/tmp/cell-ai` is the canonical cell clone); a box with none of them says so BY NAME.
read -r -d '' PROBE_TMPL <<'SH' || true
@ROOT@
for d in /tmp/cell-ai "$HOME/agent-infra" /home/cmux/agent-infra; do
  [ -f "$d/scripts/ci_runner_pool.sh" ] || continue
  cd "$d" || exit 2
  exec bash scripts/ci_runner_pool.sh status
done
echo "cannot-measure why=pool-tool-absent searched=/tmp/cell-ai:\$HOME/agent-infra:/home/cmux/agent-infra" >&2
exit 2
SH

# ⛔ THE ROOT IS INLINED INTO A REMOTE SHELL WORD, SO EVERY SOURCE IS VALIDATED, not just `--root`.
# The check that lived on the argument alone was false for the two ENV seams and for a derived root:
# `RUNNER_FLEET_ROOT="/opt/it's"` composed `RUNNER_ROOT='/opt/it's'; export RUNNER_ROOT`, which `sh -n`
# refuses as an unterminated string, and a value carrying `'; …; :'` composes a VALID remote command —
# i.e. an unvalidated seam turned a typo into arbitrary execution on a peer. This predicate is the one
# place that decides, and `probe_for_root` applies it so no caller can skip it.
valid_root() { case "${1:-}" in ''|*[!A-Za-z0-9._/-]*) return 1 ;; esac; return 0; }

probe_for_root() {  # <root|''> -> the snippet (rc 1 when the root cannot be a shell word)
  local pre="" snip="$PROBE_TMPL"
  if [ -n "$1" ]; then
    valid_root "$1" || return 1
    pre="RUNNER_ROOT='$1'; export RUNNER_ROOT"
  fi
  printf '%s' "${snip//@ROOT@/$pre}"
}

# ⛔ EVERY ROOT SEAM IS VALIDATED BEFORE ANY WORK (review P2-5): all three reach `probe_for_root`,
# which inlines them into the remote shell word, so a value outside the charset is a usage error here
# rather than a broken probe (or a composed command) on a peer.
if [ -n "$FLEET_ROOT" ] && ! valid_root "$FLEET_ROOT"; then
  err "RUNNER_FLEET_ROOT='$FLEET_ROOT' is not a plain path (allowed: A-Za-z0-9._/-) — it is inlined into the remote probe, so it must not be able to carry a quote, a space or a \$"; exit 1
fi
for pair in $FLEET_ROOTS; do
  case "$pair" in *=*) : ;; *) err "RUNNER_FLEET_ROOTS entry '$pair' is not <label>=<path>"; exit 1 ;; esac
  if ! valid_root "${pair#*=}"; then
    err "RUNNER_FLEET_ROOTS entry '$pair' carries a path that is not plain (allowed: A-Za-z0-9._/-) — it is inlined into the remote probe"; exit 1
  fi
done

# ── reading one cell ─────────────────────────────────────────────────────────────────────────────
# exec_box <label> <snippet> -> combined stdout+stderr of the remote probe; rc is the REMOTE rc
# (cap_bounded normalises a timeout to 124). ⛔ STDERR IS MERGED ON PURPOSE: the pool tool prints
# `cannot-measure …` / `defect …` on stderr and its rows on stdout, and `cmux vm exec`'s own refusal
# arrives on stderr — a reader that kept the streams apart would have to guess which side a failure
# took, and the transport failure IS the diagnostic that has to be printed.
# ⛔ STDIN IS /dev/null: the real `cmux vm exec` READS THE CALLER'S STDIN (measured; `lane-artifacts`
# models it), and this reporter drives the call from inside a `while read` over the roster — a
# transport that ate that stream would silently shorten the fleet.
exec_box() {
  local box="$1" snip="$2" have=0 tok
  local -a argv=()
  # shellcheck disable=SC2086
  for tok in $FLEET_EXEC; do
    case "$tok" in '{box}') argv[${#argv[@]}]="$box"; have=1 ;; *) argv[${#argv[@]}]="$tok" ;; esac
  done
  [ "$have" = 1 ] || { printf 'cannot-measure why=exec-template-without-box (RUNNER_FLEET_EXEC=%s)\n' "$FLEET_EXEC"; return 2; }
  argv[${#argv[@]}]="sh"
  argv[${#argv[@]}]="-lc"
  argv[${#argv[@]}]="$snip"
  cap_bounded "$FLEET_TIMEOUT" sh -c 'exec "$@" 2>&1' _ "${argv[@]}" </dev/null
}

# BOX_AWK — the per-box block reader. Input: the remote probe's combined output. Output: the three
# line kinds this report aggregates (`K|…` per box, `R|…` per registration, `X|…` for a line it could
# not classify, `C|…` for the producer's own refusal text). ⛔ IT IS THE ONLY PARSER: the row grammar it must survive is #2381's (fixed-width
# NAME/LISTENER/STATE/GITHUB_NAME), and it classifies by the STATE TOKEN rather than a byte offset,
# because the QUARANTINE rows carry prose in the fourth column and a width-based read would put that
# prose in `github_name` and report a retired install as an unregistered runner.
BOX_AWK='
function tok(name,   i, kv) {
  for (i = 1; i <= NF; i++) { split($i, kv, "="); if (kv[1] == name) return kv[2] }
  return ""
}
# ⛔ THE STATE COLUMN IS AN ALLOW-LIST, AND ANYTHING ELSE IS A REFUSAL — not a row (review P2-6).
# A row is recognised by its THIRD field being a state the producer can print; a line that is neither
# a known prefix nor a known row makes the whole block UNPARSEABLE, because the alternative was
# measured: an instance directory whose name contains a space (`my runner  111  live  pi-runner-1`)
# was split into NAME=my, LISTENER=runner, STATE=111, printed as a fabricated row, and the REAL
# registration it carried was then reported as a PHANTOM on a fully measured fleet
# (`registry-unclaimed … reason=no-running-cell-claims-it`, after the round-5 rename) — the exact harm the attribution rule
# of clause 2 exists to prevent. Refusing the cell cannot invent a defect.
function isstate(s) {
  return (s == "live" || s == "DEAD" || s == "ORPHANED" || s == "QUARANTINE" || s == "LIVE-QUAR" || s == "UNPROBED")
}
/^host=/ {
  H = tok("host"); NCPU = tok("ncpu"); CEIL = tok("ceiling"); SLOTS = tok("slots")
  MEM = tok("mem_available"); FLOOR = tok("floor"); seen_host = 1; next
}
/^summary / {
  LIVE = tok("live"); DEAD = tok("dead"); ORPH = tok("orphaned"); QN = tok("quarantine")
  REGS = tok("registrations"); TDEF = tok("tmpdir_defects"); seen_sum = 1; next
}
/^defect / {
  d = tok("name")
  # ⛔ THE DEFECT TOKEN TRAVELS (review P3-8): every `defect` line used to render as `tmpdir-missing`,
  # so `defect tmpdir-mode=755` pointed an operator at a MISSING root (remedy: restart) when the defect
  # was a wrong MODE (remedy: chmod 700).
  if (d != "") { defect[d] = 1; dtype[d] = $2 }
  next
}
/^cannot-measure / { CM = $0; next }
/^NAME[ \t]+LISTENER/ { next }
/^[ \t]*$/ { next }
{
  # ⛔ A FIELD CARRYING THE RECORD SEPARATOR IS UNCLASSIFIABLE, NOT A ROW (review round 5, P3). This
  # awk emits `R|name|listener|state|github_name|defect` and the reader splits on `|`, so an instance
  # directory containing `|` re-split AFTER `isstate()` had passed: measured `name=weird
  # github_name=live listener=dir local=111 … verdict=quarantine` — a fabricated row AND a phantom
  # registration with `reclaim` advice, on a healthy runner. The space-in-a-name case (suite case P) is
  # the same class one byte over.
  if (NF >= 3 && isstate($3) && $0 !~ /\|/) {
    # ⛔ NOT `RS`: that name is the awk RECORD SEPARATOR builtin, and indexing it is a syntax error
    # under mawk (the awk every cell ships, #2637). The state column is `ST[n]`.
    n++; RN[n] = $1; RL[n] = $2; ST[n] = $3
    if ($3 == "live" || $3 == "DEAD" || $3 == "ORPHANED") RG[n] = $4; else RG[n] = ""
    next
  }
  if (bad == 0) badline = $0
  bad++
  next
}
END {
  # ⛔ MEASURED MEANS BOTH LINES CAME. A `host=` line without the `summary` is a truncated read (a
  # killed transport, a half-written pipe), and certifying a box from it would publish `slots=0` —
  # the empty-pool-reads-as-zero defect #2381 closed one layer down.
  if (!seen_host || !seen_sum) { print "M|0"; if (CM != "") print "C|" CM; exit 0 }
  print "M|1"
  printf "K|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n", H, NCPU, CEIL, SLOTS, MEM, FLOOR, LIVE, DEAD, ORPH, QN, REGS, TDEF
  for (i = 1; i <= n; i++) printf "R|%s|%s|%s|%s|%s\n", RN[i], RL[i], ST[i], RG[i], ((RN[i] in defect) ? dtype[RN[i]] : "")
  printf "X|%d|%s\n", bad, badline
  if (CM != "") print "C|" CM
}'

# derive_root <probe-output> -> the ONE parent directory the `pool-root-incomplete` refusal enables,
# or empty when the refusal does not name a single parent. ⛔ THIS IS NOT A GUESS: the per-box tool
# REFUSES with the directories it could see (`outside=/opt/a,/opt/b`), and its documented remedy is
# "set RUNNER_ROOT to the directory that CONTAINS every instance dir". Two distinct parents cannot be
# satisfied by one root, so the ambiguity stays `cannot-measure` rather than being resolved by picking.
derive_root() {
  local line dirs d parent parents="" ifs_save="$IFS"
  line="$(printf '%s\n' "$1" | awk '/^cannot-measure / && /why=pool-root-incomplete/ {print; exit}')"
  [ -n "$line" ] || return 0
  dirs="$(printf '%s\n' "$line" | awk '{ for (i = 1; i <= NF; i++) if (index($i, "outside=") == 1) { print substr($i, 9); exit } }')"
  [ -n "$dirs" ] || return 0
  IFS=','
  for d in $dirs; do
    [ -n "$d" ] || continue
    parent="${d%/*}"; [ -n "$parent" ] || parent="/"
    case " $parents " in *" $parent "*) : ;; *) parents="$parents $parent" ;; esac
  done
  IFS="$ifs_save"
  # shellcheck disable=SC2086
  set -- $parents
  [ "$#" -eq 1 ] || return 0
  printf '%s' "$1"
}

# ── reading the registries ──────────────────────────────────────────────────────────────────────
# registry_read <owner/name> -> `name<TAB>status<TAB>busy` lines, rc 0; else rc != 0 (stderr kept by
# the caller). ⛔ `--paginate` WITH `--jq` APPLIES THE FILTER PER PAGE (gh's documented behaviour), so
# a pool larger than one page is never truncated to its first 100 — the same reason
# `ci_runner_gate.sh` paginates.
registry_read() {  # <owner/name> <stderr-file>
  # ⛔ STDERR GOES TO A FILE, NOT INTO THE ROWS (review cycle 3, P2). `cap_bounded` sends the child's
  # stderr to /dev/null on every arm, so the caller's `2>file` never received it (every refusal read
  # `detail=no-output`, with 404/auth/rate-limit indistinguishable) — and the obvious repair (`2>&1`)
  # is WORSE: on a SUCCESSFUL read a gh warning becomes a ROW, is parsed as a registration, and a
  # healthy fleet reads `registry-unclaimed name=warning: gh 2.40.0 is out of date ... not_ok=1` and
  # exits 3. The wrapper hands the child its own stderr fd, so the two streams never meet.
  cap_bounded "$FLEET_TIMEOUT" sh -c 'errf="$1"; shift; exec "$@" 2>"$errf"' _ "${2:-/dev/null}" \
    "$FLEET_GH" api --paginate \
    "repos/$1/actions/runners?per_page=100" \
    --jq '.runners[] | [.name, .status, (.busy|tostring)] | @tsv' </dev/null
}

# ══ RUN ═════════════════════════════════════════════════════════════════════════════════════════
# ⛔ THREE COUNTERS, THREE DIFFERENT FAILURES — never one "unmeasured" (review P2-4). The first
# version carried cells and registries in one counter, so a run with EVERY cell measured and one
# registry unreadable printed `cells=1 measured=1 unmeasured=1` and explained an unclaimed
# registration as `cannot-attribute(1-cell-unmeasured)` — naming a cell that does not exist, and
# sending an operator to hunt for it. They are separated here because the three populations send you
# to three different places: a CELL you could not reach, a REGISTRY you could not read, and a local
# row you could not JOIN to either. `unjoinable` spans BOTH sides of that join on purpose — a local row
# that could not be bound to a registration AND a registry row that could not be attributed to one —
# because a fleet where every registration is unattributable must not read as a clean one; the count is
# therefore "unattributable readings", not "unjoined installs".
unmeasured=0; measured=0; cells=0
reg_unread=0; reg_total=0; reg_claimed=0; reg_unclaimed=0
local_rows=0; unregistered=0; unjoinable=0; disagreements=0; not_ok=0; collision=0
skipped=0; reg_scope=0; reg_tokens=0; missing_seen=""
# ⛔ A BOX DELIBERATELY EXCLUDED BY --box IS NOT A BOX THAT FAILED (review cycle 2, P1). Leaving it
# uncounted made the attribution guard read a scoped run as a COMPLETE one, so `--box cell-a` on a
# healthy two-cell fleet printed cell-b's registration as `registry-unclaimed …
# reason=no-running-cell-claims-it` (the token was renamed in round 5) and exited 3 — advice whose
# printed remedy is `reclaim`, aimed at
# a live registration on a box nobody asked about. Excluded boxes are counted (`skipped=`) and the
# guard refuses a phantom claim while any exist; they do NOT force exit 2, because the operator asked
# for a SCOPE, not a full fleet.
: >"$TMPD/reg"     # name<TAB>repo<TAB>status<TAB>busy
: >"$TMPD/claim"   # github_name<TAB>cell<TAB>name

# ── 1. the registries (independent of the cells, so a fleet with no reachable cell still gets them) ─
# ⛔ A REPO LISTED TWICE IS ONE REGISTRY (review round 6, P3). Without this, `RUNNER_FLEET_REPOS="o/a
# o/a"` writes every name twice into the registry table, the ambiguity table then calls EVERY name
# ambiguous, and a fully measured, agreeing fleet is refused (exit 2) with
# `name-carried-by-more-than-one-registry` — a claim that is false, about an ambiguity that does not
# exist. Same dedupe the roster got, for the same reason.
reg_tokens=0
for repo in $(printf '%s\n' $FLEET_REPOS | awk 'NF && !seen[$1]++ {print $1}'); do
  reg_tokens=$((reg_tokens + 1))
  # ⛔ A MALFORMED REPO TOKEN IS AN UNREAD REGISTRY, NOT A SKIP (review P1-3, related). It used to
  # `continue` with no counter, so a typo'd seam left the registry half EMPTY while `summary …
  # registry=0` read as "this repo has no runners" — the absence-reads-as-zero shape, one seam in.
  case "$repo" in */*) : ;; *)
    printf 'registry repo=%s read=cannot-measure why=repo-token-malformed detail=%s\n' "$repo" "not owner/name"
    reg_unread=$((reg_unread + 1)); continue ;;
  esac
  reg_scope=$((reg_scope + 1))
  : >"$TMPD/regerr"
  reg_rc=0
  reg_out="$(registry_read "$repo" "$TMPD/regerr")" || reg_rc=$?
  if [ "$reg_rc" -eq 0 ]; then
    # ⛔ AN EMPTY REGISTRY IS A LEGITIMATE READING (a repo whose jobs run on GitHub-hosted runners —
    # `ci-queue.sh` names that shape). It is NOT `cannot-measure`, and it is NOT "the fleet is gone".
    n="$(printf '%s\n' "$reg_out" | awk 'NF' | wc -l)"; n=$((n))
    printf 'registry repo=%s read=ok runners=%s\n' "$repo" "$n"
    # ⛔ TAB-AWARE, BECAUSE `@tsv` YIELDS EMPTY FIELDS AND WHITESPACE SPLITTING COLLAPSES THEM
    # (review P1-2). A null `.status` renders as `name<TAB><TAB>false`; the old default-FS split made
    # that `name false` — status="false", busy="" — and the polarity test `= offline` fell through to
    # `verdict=ok`, certifying a runner whose registry row could not be read. Measured:
    # `runner … github=false busy=? registry=a verdict=ok`.
    printf '%s\n' "$reg_out" | awk -F'\t' -v R="$repo" '
      /^[ \t]*$/ { next }
      { printf "%s\t%s\t%s\t%s\n", $1, R, (NF >= 2 ? $2 : ""), (NF >= 3 ? $3 : "") }' >>"$TMPD/reg"
  else
    why="$(awk 'NF {print; exit}' "$TMPD/regerr")"
    # ⛔ A TIMEOUT IS ITS OWN READING, because "the API did not answer in bounded time" sends an
    # operator somewhere different from "the API refused" (measured: the box's `gh` shim serialises
    # its calls, so a queued registry read can exceed FLEET_TIMEOUT and produce NO stderr at all —
    # which used to print `detail=no-output`, naming nothing).
    [ "$reg_rc" -eq 124 ] && why="${why:-timed-out-after-${FLEET_TIMEOUT}s}"
    printf 'registry repo=%s read=cannot-measure why=registry-unreadable rc=%s detail=%s\n' "$repo" "$reg_rc" "${why:-no-output}"
    reg_unread=$((reg_unread + 1))
  fi
done
# ⛔ A SEAM THAT WORD-SPLITS TO NOTHING IS AN UNREAD REGISTRY, NOT AN EMPTY ONE (review cycle 2, P2).
# `RUNNER_FLEET_REPOS=" "` iterated zero times, so the registry half simply vanished: `registry=0` read
# as "this repo has no runners" and every healthy runner was then `verdict=unregistered` — the same
# class the malformed-token arm covers, one value over.
if [ "$reg_tokens" -eq 0 ]; then
  printf 'registry repo=- read=cannot-measure why=repo-list-empty detail=RUNNER_FLEET_REPOS is empty
'
  reg_unread=$((reg_unread + 1))
fi
reg_total="$(awk 'NF' "$TMPD/reg" | wc -l)"; reg_total=$((reg_total))
# ⛔ THE AMBIGUITY TABLE IS BUILT HERE, BEFORE ANY CELL IS READ, because BOTH loops consume it: the
# row join (a name in more than one registry cannot be bound from the local side) and the unclaimed
# pass (each such registry row is an abstention, never a phantom). Built ONCE and read as a FILE
# ARGUMENT, never piped into a quiet `grep` (the class scripts/check-no-sigpipe-grep.sh refuses).
awk -F'\t' '{c[$1]++} END {for (n in c) if (c[n] > 1) print n}' "$TMPD/reg" >"$TMPD/ambig"

# ── 2. the roster ────────────────────────────────────────────────────────────────────────────────
if [ -n "$FLEET_BOXES" ]; then
  # shellcheck disable=SC2086
  printf '%s\n' $FLEET_BOXES | awk 'NF && !seen[$1]++ {print $1}' >"$TMPD/roster"
else
  roster="$(cap_fleet_inventory)"; rrc=$?
  if [ "$rrc" -ne 0 ]; then
    printf 'cell roster=cannot-measure why=roster-unreadable detail=%s\n' "${roster#UNKNOWN }"
    printf 'summary cells=UNKNOWN measured=0 unmeasured=UNKNOWN skipped=UNKNOWN registry=%s registry_unread=%s claimed=0 unclaimed=UNKNOWN unregistered=UNKNOWN unjoinable=UNKNOWN disagreements=UNKNOWN collisions=UNKNOWN not_ok=UNKNOWN\n' \
      "$reg_total" "$reg_unread"
    exit 2
  fi
  printf '%s\n' "$roster" | awk 'NF { print $1 }' >"$TMPD/roster"
fi

# ⛔ AN EMPTY ROSTER IS A REFUSAL, NOT A FLEET OF ZERO (review cycle 2, P2). A whitespace-only
# `RUNNER_FLEET_BOXES` produced one blank line, the loop skipped it, and the run printed
# `cells=0 measured=0 unmeasured=0 not_ok=0` and exited 0 — a clean bill of health from a run that
# probed nothing. `--list`-style discovery has the same rule (`cap_expected_boxes` refuses a roster
# that tokenises to nothing).
if [ ! -s "$TMPD/roster" ] || ! awk 'NF {found = 1} END {exit !found}' "$TMPD/roster"; then
  printf 'cell roster=cannot-measure why=roster-empty detail=no-usable-label-in-the-roster\n'
  printf 'summary cells=0 measured=0 unmeasured=UNKNOWN skipped=UNKNOWN registry=%s registry_unread=%s claimed=0 unclaimed=UNKNOWN unregistered=UNKNOWN unjoinable=UNKNOWN disagreements=UNKNOWN collisions=UNKNOWN not_ok=UNKNOWN\n' \
    "$reg_total" "$reg_unread"
  exit 2
fi

# ⛔ A `--box` THE ROSTER DOES NOT CARRY IS A REFUSAL, NOT A SMALLER FLEET. A typo (or a label the
# provider renamed) otherwise reports `cells=0` and exits 0 — a clean bill of health built from
# nothing, the shape `cap_expected_boxes` refuses one namespace over.
for want in $ONLY_BOXES; do
  # ⛔ ONCE PER LABEL: `--box typo --box typo` counted cells=2 / unmeasured=2 for one missing label.
  case " $missing_seen " in *" $want "*) continue ;; esac
  if ! grep -qxF -- "$want" "$TMPD/roster"; then
    missing_seen="$missing_seen $want"
    cells=$((cells + 1)); unmeasured=$((unmeasured + 1))
    printf 'cell label=%s read=cannot-measure why=box-not-in-roster detail=not-in-cmux-vm-list\n' "$want"
  fi
done

# ── 3. every cell, one at a time ─────────────────────────────────────────────────────────────────
while read -r box <&3; do
  [ -n "$box" ] || continue
  if [ -n "$ONLY_BOXES" ]; then
    case " $ONLY_BOXES " in *" $box "*) : ;; *) skipped=$((skipped + 1)); continue ;; esac
  fi
  cells=$((cells + 1))
  root="$FLEET_ROOT"; note=""
  # the per-cell map wins over the fleet-wide default (a box laid out under /opt beside one under /tmp)
  for pair in $FLEET_ROOTS; do
    case "$pair" in "$box="*) root="${pair#*=}" ;; esac
  done
  if ! snip="$(probe_for_root "$root")"; then
    printf 'cell label=%s read=cannot-measure why=root-unusable detail=RUNNER_ROOT=%s\n' "$box" "$root"
    unmeasured=$((unmeasured + 1)); continue
  fi
  out="$(exec_box "$box" "$snip")"; rc=$?
  # ⛔ ONE RETRY, DRIVEN BY THE REFUSAL ITSELF, AND ONLY WHEN NO ROOT WAS PINNED. Moving a root a
  # human chose would be the tool overriding its operator; deriving it from the directories the pool
  # tool NAMED is the pool tool's own documented remedy, executed once.
  if [ "$ROOT_DERIVE" = 1 ] && [ -z "$root" ] && [ "$rc" -eq 2 ]; then
    derived="$(derive_root "$out")"
    if [ -n "$derived" ] && valid_root "$derived"; then
      snip="$(probe_for_root "$derived")" || snip=""
      if [ -n "$snip" ]; then
        out="$(exec_box "$box" "$snip")"; rc=$?
        note="root_derived=$derived"
      fi
    fi
  fi
  printf '%s\n' "$out" | awk "$BOX_AWK" >"$TMPD/parsed"
  # ── the refusal arm. FOUR ways to be unmeasured, and each keeps its own reason ────────────────
  cdetail="$(awk -F'|' '$1=="C" {print substr($0, 3); exit}' "$TMPD/parsed")"
  cwhy="$(printf '%s' "$cdetail" | awk '{ for (i = 1; i <= NF; i++) if (index($i, "why=") == 1) { print substr($i, 5); exit } }')"
  if ! grep -qxF 'M|1' "$TMPD/parsed"; then
    # ⛔ THE DETAIL IS THE TRANSPORT'S OR THE PROBE'S OWN FIRST LINE — never a summary this tool
    # invented, because the operator's next step depends on which failure it was.
    why="$(printf '%s\n' "$out" | awk 'NF {print; exit}')"
    case "$rc" in
      124) tok="transport-timeout" ;;
      127) tok="pool-tool-absent" ;;
      2)   tok="pool-unreadable" ;;
      *)   tok="transport-unreachable" ;;
    esac
    # ⛔ THE PRODUCER'S OWN TOKEN WINS OVER THE rc-DERIVED ONE (review cycle 2, P3): `cwhy` was
    # computed two lines above and then dropped, so `cannot-measure why=pool-tool-absent` (a peer with
    # no clone) printed `why=pool-unreadable` — the same word as an unreadable root or instance, for
    # four different causes a consumer must branch on differently.
    printf 'cell label=%s read=cannot-measure why=%s rc=%s detail=%s\n' "$box" "${cwhy:-$tok}" "$rc" "${why:-no-output}"
    unmeasured=$((unmeasured + 1)); continue
  fi
  # ⛔ A COMPLETE BLOCK WITH A NON-ZERO PRODUCER rc IS NOT A MEASUREMENT (review P1-1). `status`
  # exits 2 for "a PARTIAL MEASUREMENT" — `pool-root-incomplete` and an UNPROBED quarantine BOTH print
  # a full block (host, rows, summary) AND exit 2, saying in its own words that `slots=` "counts a
  # PARTIAL pool". Keying "measured" on the block alone certified exactly that: measured with
  # `rc=2`, `unmeasured=0`, not_ok=0 → **exit 0**, publishing a partial count as the box's pool.
  # The producer's complete-reading codes are 0 and 3 (3 = measured, and the report names a defect).
  case "$rc" in 0|3) : ;; *)
    printf 'cell label=%s read=cannot-measure why=%s rc=%s detail=%s\n' \
      "$box" "${cwhy:-pool-partial}" "$rc" "${cdetail:-block-complete-but-rc=$rc}"
    unmeasured=$((unmeasured + 1)); continue ;;
  esac
  # ⛔ A LINE THE PARSER COULD NOT CLASSIFY MAKES THE BLOCK UNPARSEABLE (review P2-6). Certifying the
  # rows it DID understand is how a fabricated row became a phantom registration on a measured fleet.
  xcount="$(awk -F'|' '$1=="X" {print $2; exit}' "$TMPD/parsed")"
  if [ "${xcount:-0}" != "0" ]; then
    xline="$(awk -F'|' '$1=="X" {print substr($0, index($0, $3)); exit}' "$TMPD/parsed")"
    printf 'cell label=%s read=cannot-measure why=block-unparseable rc=%s unclassified=%s detail=%s\n' \
      "$box" "$rc" "$xcount" "$xline"
    unmeasured=$((unmeasured + 1)); continue
  fi
  measured=$((measured + 1))
  IFS='|' read -r _ kh kncpu kceil kslots kmem kfloor klive kdead korph kq kregs ktdef < <(awk -F'|' '$1=="K"' "$TMPD/parsed")
  printf 'cell label=%s read=ok host=%s ncpu=%s ceiling=%s slots=%s mem_available_mb=%s floor_mb=%s live=%s dead=%s orphaned=%s quarantine=%s registrations=%s tmpdir_defects=%s rc=%s\n' \
    "$box" "${kh:--}" "${kncpu:--}" "${kceil:--}" "${kslots:--}" "${kmem:--}" "${kfloor:--}" \
    "${klive:--}" "${kdead:--}" "${korph:--}" "${kq:--}" "${kregs:--}" "${ktdef:--}" "$rc"
  [ -n "$note" ] && printf 'cell-note label=%s %s\n' "$box" "$note"
  # ── the rows, joined to the registry BY agentName ──────────────────────────────────────────────
  while IFS='|' read -r kind name listener state ghname dtok; do
    [ "$kind" = "R" ] || continue
    local_rows=$((local_rows + 1))
    rstatus=""; rbusy=""; rrepo=""; hit=""
    # ⛔ A NAME CARRIED BY MORE THAN ONE REGISTRY IS NOT BINDABLE FROM THE LOCAL SIDE (review cycle 3,
    # P2). Names are unique PER REPO and two registries are read by default, so one agentName may
    # legitimately exist in both while the per-box `status` block does not say which repo an install is
    # registered to. Binding to the FIRST row was measured to compute cell-b's verdict from cell-a's
    # registration (a false `ok`, or a false `github-offline`), to print the wrong `registry=`, and to
    # fire a `name-collision` on a perfectly healthy two-cell fleet.
    # ⛔ …AND THE AMBIGUITY IS RECORDED, NOT ACTED ON HERE (review round 4, P3): an early `continue`
    # shadowed verdicts that need NO registry at all, so an ambiguous name that was ALSO a dead
    # listener printed `verdict=cannot-attribute` instead of `dead-listener`, and a `defect
    # tmpdir-mode=755` row lost its token entirely — the restart-vs-reclaim distinction this file
    # treats as load-bearing, gone. It now only SKIPS THE JOIN, and the abstention sits in the ladder
    # below, after the local facts.
    ambig_name=0
    if [ -n "$ghname" ] && grep -qxF -- "$ghname" "$TMPD/ambig"; then ambig_name=1; fi
    if [ "$ambig_name" = 0 ] && [ -n "$ghname" ]; then
      hit="$(awk -F'\t' -v n="$ghname" '$1==n {print; exit}' "$TMPD/reg")"
      if [ -n "$hit" ]; then
        rstatus="$(printf '%s' "$hit" | cut -f3)"
        rbusy="$(printf '%s' "$hit" | cut -f4)"
        rrepo="$(printf '%s' "$hit" | cut -f2)"
      fi
    fi
    # ⛔ THE VERDICT ORDER IS THE SAFETY ORDER — the LOCAL facts are measured first, then the join,
    # then the GitHub side, which is the only half that can be a value this report cannot classify.
    #   * a state outside `live|DEAD|ORPHANED` is one the producer prints for an install that is not a
    #     runner (QUARANTINE / LIVE-QUAR / UNPROBED): a defect, and never a registry claim;
    #   * ORPHANED is not fixed by `restart` (it exits 6) and needs `reclaim`;
    #   * a DEAD listener is capacity one start away;
    #   * a `defect` token is carried VERBATIM, so `tmpdir-mode=755` no longer claims a missing root;
    #   * an EMPTY agentName, or a missing hit while a registry was UNREAD, is `cannot-attribute` —
    #     an abstention, never `unregistered` (review P1-3: one refused registry read printed every
    #     healthy runner on the box as `unregistered`, a defect fabricated from a read that never
    #     happened);
    #   * `unregistered` is claimed ONLY when the registries were all read.
    if [ "$state" != "live" ] && [ "$state" != "DEAD" ] && [ "$state" != "ORPHANED" ]; then
      verdict="quarantine"; not_ok=$((not_ok + 1))
    elif [ "$state" = "ORPHANED" ]; then
      verdict="orphaned"; not_ok=$((not_ok + 1))
    elif [ "$state" = "DEAD" ]; then
      verdict="dead-listener"; not_ok=$((not_ok + 1))
    elif [ -n "$dtok" ]; then
      verdict="defect-$(printf '%s' "$dtok" | tr '=' ':')"; not_ok=$((not_ok + 1))
    elif [ "$ambig_name" = 1 ]; then
      verdict="cannot-attribute"; unjoinable=$((unjoinable + 1))
    elif [ -z "$ghname" ]; then
      verdict="cannot-attribute"; unjoinable=$((unjoinable + 1))
    elif [ -z "$hit" ] && [ "$reg_unread" -gt 0 ]; then
      verdict="cannot-attribute"; unjoinable=$((unjoinable + 1))
    elif [ -z "$hit" ]; then
      verdict="unregistered"; unregistered=$((unregistered + 1)); not_ok=$((not_ok + 1))
    elif [ "$rstatus" = "offline" ]; then
      verdict="github-offline"; not_ok=$((not_ok + 1))
    elif [ "${rstatus}" != "online" ]; then
      verdict="github-unreadable"; not_ok=$((not_ok + 1))
    else
      verdict="ok"
    fi
    # ⛔ ABSENT AND UNREADABLE ARE DIFFERENT ANSWERS: a row the registry DID carry but whose status the
    # report cannot classify prints `github=unread`, never `ABSENT` (which is a claim about the
    # registry this read did not make).
    if [ "$ambig_name" = 1 ]; then gshow="unread"
    elif [ -z "$rstatus" ]; then
      if [ -n "$hit" ]; then gshow="unread"; else gshow="ABSENT"; fi
    else gshow="$rstatus"; fi
    # ⛔ ONE PAIR TEST, COUNTED INDEPENDENTLY OF WHICH VERDICT WON (review cycles 2 and 3, P3). The
    # increments used to live inside the verdict arms, which was wrong in BOTH directions: the
    # `defect` arm sat before the offline arm so a row carrying both never counted (a disagreement
    # vanished), while `DEAD` incremented AND the offline test incremented again — so
    # `local=DEAD github=offline` (the sources AGREEING) counted 2 and `local=ORPHANED github=online`
    # (a real disagreement) counted 0. The state:status PAIR is the whole rule.
    case "$state:$rstatus" in
      live:offline|DEAD:online|ORPHANED:online) disagreements=$((disagreements + 1)) ;;
    esac
    printf 'runner cell=%s name=%s github_name=%s listener=%s local=%s github=%s busy=%s registry=%s verdict=%s\n' \
      "$box" "$name" "${ghname:--}" "${listener:--}" "$state" "$gshow" "${rbusy:-?}" "${rrepo:--}" "$verdict"
    # ⛔ AN AMBIGUOUS ROW RECORDS NO CLAIM: it cannot say which registration it is, and a claim here
    # would make one of the two registry rows look attributed.
    [ -n "$ghname" ] && [ "$ambig_name" = 0 ] && printf '%s\t%s\t%s\n' "$ghname" "$box" "$name" >>"$TMPD/claim"
  done <"$TMPD/parsed"
done 3<"$TMPD/roster"

# ── 4. the registry names no measured cell claims ────────────────────────────────────────────────
# ⛔ THE ATTRIBUTION RULE IS WHERE CLAUSE 3 ACTUALLY BITES. A name is a PHANTOM only when every
# requested cell was measured AND every registry was read; while either is short the name may live in
# the part that was not read, and calling it a phantom would send an operator to `reclaim` a
# registration that is serving jobs.
# ⛔ RUNNER NAMES ARE UNIQUE PER REPO, NOT ACROSS REPOS (review cycle 2, P2): this report reads TWO
# registries by default, so one local row matching one name must not "claim" that name in BOTH — it
# counted `claimed=2` for one runner AND swallowed the second registry's registration, which is
# exactly the lost-its-box class clause 2 exists for. A name carried by more than one registry is
# attributed to the FIRST and the rest are an abstention, named.
# ⛔ NO PIPE INTO A QUIET GREP (scripts/check-no-sigpipe-grep.sh's class): both tables are built once,
# then read as FILE ARGUMENTS, so a truncated reader cannot turn a valid answer into a SIGPIPE failure.
# ⛔ UNPACKED BY HAND, NOT `IFS=$'\t' read` (review round 6, P3). A tab IS IFS-whitespace, so `read`
# COLLAPSES a run of them: a registry row with an EMPTY status (`name<TAB>repo<TAB><TAB>false`, which
# gh's @tsv produces for a null status — case O's own rationale) shifted left and printed
# `status=false` — the busy value in the status field, on the line whose advice is `reclaim`. The join
# path uses `cut -f3/-f4`, which preserves the empty field, so the two readers disagreed about one
# file. Parameter expansion keeps every field where it is.
while IFS= read -r rline; do
  [ -n "$rline" ] || continue
  rname="${rline%%$'\t'*}"; rline="${rline#*$'\t'}"
  rrepo2="${rline%%$'\t'*}"; rline="${rline#*$'\t'}"
  rstatus2="${rline%%$'\t'*}"; rbusy2="${rline#*$'\t'}"
  if grep -qxF -- "$rname" "$TMPD/ambig"; then
    reg_unclaimed=$((reg_unclaimed + 1)); unjoinable=$((unjoinable + 1))
    printf 'registry-unclaimed name=%s registry=%s status=%s reason=cannot-attribute(name-carried-by-more-than-one-registry)\n' \
      "$rname" "$rrepo2" "$rstatus2"
    continue
  fi
  if awk -F'\t' -v n="$rname" '$1==n {found=1} END {exit !found}' "$TMPD/claim"; then
    reg_claimed=$((reg_claimed + 1)); continue
  fi
  reg_unclaimed=$((reg_unclaimed + 1))
  # an EMPTY status is a value the registry did not give us; printing it blank on the line that invites
  # `reclaim` reads as "no status", so it is named.
  [ -n "$rstatus2" ] || rstatus2="unread"
  if [ "$unmeasured" -eq 0 ] && [ "$skipped" -eq 0 ] && [ "$reg_unread" -eq 0 ]; then
    # ⛔ THE CLAIM IS BOUNDED BY WHICH BOXES EXIST, AND THE BOUNDARY IS NAMED (review round 5, P2).
    # The roster is the provider RUNNING inventory (`cap_fleet_inventory` deliberately drops a
    # `stopped` machine — an unreadable status is UNCLASSIFIED, not parked), so a registration held by
    # a box the operator parked appears here with no local evidence, exactly like one that lost its
    # box. Saying "no MEASURED cell claims it" claimed more than was read; the remedy it prints
    # (`reclaim`) then deletes a valid registration the parked box needs when it returns. The token
    # now names what was actually observed — no RUNNING cell — and `--help`/docs carry the caveat.
    printf 'registry-unclaimed name=%s registry=%s status=%s reason=no-running-cell-claims-it\n' "$rname" "$rrepo2" "$rstatus2"
    not_ok=$((not_ok + 1))
  else
    why=""
    [ "$unmeasured" -gt 0 ] && why="${unmeasured}-cell-unmeasured"
    if [ "$skipped" -gt 0 ]; then
      [ -n "$why" ] && why="$why,"
      why="${why}${skipped}-cell-not-requested"
    fi
    if [ "$reg_unread" -gt 0 ]; then
      [ -n "$why" ] && why="$why,"
      why="${why}${reg_unread}-registry-unread"
    fi
    printf 'registry-unclaimed name=%s registry=%s status=%s reason=cannot-attribute(%s)\n' "$rname" "$rrepo2" "$rstatus2" "$why"
  fi
done <"$TMPD/reg"

# ── 5. one agentName claimed by two cells ────────────────────────────────────────────────────────
# GitHub runner NAMES are unique per repo, so two local installs carrying one agentName are one
# registration (or a stale `.runner`), and starting both is not twice the capacity — the rule #2381
# encodes as "DEDUPED BY agentName".
for dup in $(awk -F'\t' '{c[$1]++; cell[$1]=cell[$1] "," $2} END {for (n in c) if (c[n] > 1) print n}' "$TMPD/claim"); do
  grep -qxF -- "$dup" "$TMPD/ambig" && continue
  printf 'name-collision name=%s cells=%s\n' "$dup" "$(awk -F'\t' -v n="$dup" '$1==n {printf "%s,", $2}' "$TMPD/claim" | sed 's/,$//')"
  collision=$((collision + 1)); not_ok=$((not_ok + 1))
done

# ── 6. the verdict ───────────────────────────────────────────────────────────────────────────────
printf 'summary cells=%s measured=%s unmeasured=%s skipped=%s registry=%s registry_unread=%s claimed=%s unclaimed=%s unregistered=%s unjoinable=%s disagreements=%s collisions=%s not_ok=%s\n' \
  "$cells" "$measured" "$unmeasured" "$skipped" "$reg_total" "$reg_unread" "$reg_claimed" "$reg_unclaimed" "$unregistered" "$unjoinable" "$disagreements" "$collision" "$not_ok"
# ⛔ 2 OUTRANKS 3: a report that could not read a cell, a registry, or the join between them cannot
# certify anything about what it holds, so "a defect was found" is the weaker claim and must not mask
# the unmeasured one.
if [ "$unmeasured" -gt 0 ] || [ "$reg_unread" -gt 0 ] || [ "$unjoinable" -gt 0 ]; then exit 2; fi
[ "$not_ok" -eq 0 ] || exit 3
exit 0
