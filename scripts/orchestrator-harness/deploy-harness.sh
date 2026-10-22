#!/usr/bin/env bash
# deploy-harness.sh — deploy the shipped harness onto a live runtime, and establish success FROM WHAT
# THE COPY ACTUALLY DID.
#
#   ./deploy-harness.sh --src <harness-dir> --o <runtime> [--notify <notify.sh>] [--ledger <path>]
#   ./deploy-harness.sh --repo <checkout>  --o <runtime> [...]     # --src defaults to the checkout's
#                                                                  # scripts/orchestrator-harness
#   ./deploy-harness.sh ... --no-notify                            # verdict printed, no notification
#
# Exit: 0 = DEPLOYED AND VERIFIED   (every file the source ships was copied by THIS run and is
#                                    byte-identical to its source, and the source ships ≥1 file)
#       1 = the copy or the verification failed — partial, drifted or empty; a failure notification
#           was emitted and NOTHING was announced as success
#      78 = refused BEFORE touching the target (bad invocation, source absent, source is not a
#           harness, source ships nothing, target is not a directory)
#
# WHY THIS EXISTS (agent-infra#2041). `bg/finish.sh` — the live-only autonomous endgame — deployed
# with a bare `cp -R "$R"/scripts/orchestrator-harness/. "$O"/` and then, on the NEXT line and
# unconditionally, notified
#
#     "orchestrator: convergence COMPLETE"  "… $(ls "$O"/*.sh | wc -l) scripts …"
#
# Three false-PASS mechanisms in five lines:
#
#   1. the `cp` rc was never checked. Measured 2026-10-18: the source directory did not exist on the
#      box at all (its `main` was 1274 commits stale, pre-dating the harness), so `cp` returned 1 and
#      the deploy copied NOTHING;
#   2. the notification was not on a success path — it was simply the next statement;
#   3. the evidence was self-confirming: `$(ls "$O"/*.sh | wc -l)` counts the PREVIOUS deployment's
#      files, so the message manufactured its own corroboration. A count of files that were already
#      there is not proof that this run wrote anything.
#
# Consequence, and the reason this is not cosmetic: the live deployment was missing `gh-limit.py`,
# the `gh-limit/` shim and six reaper scripts while every notification said the box was current.
# `$O/gh-rest/gh` falls back to the raw `gh` when its `../gh-limit.py` is absent, so EVERY harness
# `gh` call was unserialised and unbounded, and a GraphQL refusal stopped both halves of the harness
# while REST answered normally.
#
# THE RULE THIS FILE ENFORCES, and it is a rule about EVIDENCE, not about messages:
#
#   success  ⟺  files_shipped ≥ 1  ∧  copied == files_shipped  ∧  verified == files_shipped
#
# Every term is a fact about THIS run's copy. Nothing is counted from a listing of the target, so a
# target full of the previous deployment's files cannot make an empty deploy look successful — that
# is exactly the regression `deploy-harness.test.sh` pins (case 2: an absent source against a target
# pre-seeded with 30 scripts must still FAIL).
#
# And the notification is emitted FROM the verdict, in this file — not by its caller — so the two can
# never drift into siblings again. There is no path through this script that prints success and exits
# non-zero, and none that exits non-zero and announces success.
#
# WHAT THIS SCRIPT DOES NOT DO: it does not stop or restart the controller. Restart ownership stays
# with the caller (a deploy helper that restarts cannot help but claim a restart, and a claim about a
# process it did not verify is the same defect one line over). The gated call site is in
# `README.md` §4.1 ("Redeploying an existing box"); the measured incident is agent-infra#2041.
set -uo pipefail

PROG="$(basename "${BASH_SOURCE[0]}")"
usage() { awk 'NR>1 && /^set -uo pipefail$/{exit} NR>1{sub(/^# ?/,""); print}' "${BASH_SOURCE[0]}"; }

SRC="" ; NOTIFY="" ; LEDGER="" ; DO_NOTIFY=1 ; QUIET=0
# ⛔ `O` is NOT initialised here — not even to "". Setting `O=""` on this line CLEARED an env
# `O=<dir>` before the assignment below could read it, so the "honour the convention" comment was
# false and an explicit `O=<dir> ...` silently addressed the default runtime — the measured
# #1745-class false PASS about a directory the operator never named. Every sibling in this directory
# honours an env `O=<dir>` (`install.sh`, `orch-loop.sh`, `report.sh`, `check-deployed-drift.sh` all
# do), and suite case 16 pins it. `SRC` has no such convention, so it IS cleared (review P2).
# ⛔ AND 'CLEARED' MEANS NO AMBIENT INPUT DECIDES THE SOURCE. This read `${HARNESS_SRC:-}` — an
# undocumented variable that occurs nowhere else in the repo, is absent from `usage()` and from
# README §4.1 — so an ambient `HARNESS_SRC` silently chose the source when the operator passed only
# `--o`, which is the one input this comment exists to say cannot exist. The explicit `--src`/`--repo`
# flags are the only way to name a source: a fact the next reader can check against `usage()`.
SRC=""
O="${O:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    --src)      [ $# -ge 2 ] || { echo "$PROG: --src needs a path" >&2; exit 78; }; SRC="$2"; shift 2 ;;
    --repo)     [ $# -ge 2 ] || { echo "$PROG: --repo needs a path" >&2; exit 78; }
                SRC="$2/scripts/orchestrator-harness"; shift 2 ;;
    --o)        [ $# -ge 2 ] || { echo "$PROG: --o needs a path" >&2; exit 78; }; O="$2"; shift 2 ;;
    --notify)   [ $# -ge 2 ] || { echo "$PROG: --notify needs a path" >&2; exit 78; }; NOTIFY="$2"; shift 2 ;;
    --no-notify) DO_NOTIFY=0; shift ;;
    --ledger)   [ $# -ge 2 ] || { echo "$PROG: --ledger needs a path" >&2; exit 78; }; LEDGER="$2"; shift 2 ;;
    --quiet)    QUIET=1; shift ;;
    -h|--help)  usage; exit 0 ;;
    *)          echo "$PROG: unknown argument: $1" >&2; exit 78 ;;
  esac
done

# ── the notification, resolved EARLY but fired only from a verdict ───────────────────────────────
# Fired exactly once per run, from one of the three terminal points below. `notified` makes a double
# fire a bug rather than an accident.
NOTIFIED=0
notify() { # notify <title> <message> <priority>
  [ "$DO_NOTIFY" -eq 1 ] || { echo "  [notify suppressed] $1: $2"; return 0; }
  [ "$NOTIFIED" -eq 0 ] || { echo "$PROG: BUG — a second notification was attempted ($1)" >&2; return 0; }
  NOTIFIED=1
  if [ -n "$NOTIFY" ] && [ -f "$NOTIFY" ]; then
    if ! bash "$NOTIFY" "$1" "$2" "$3"; then
      # ⛔ A NOTIFIER THAT FAILS IS NOT A DEPLOY THAT FAILED — but silence is how a real failure gets
      # lost, so it is loud on stderr and never quiet.
      echo "$PROG: WARNING — the notifier ($NOTIFY) exited non-zero; the verdict above was still delivered here" >&2
    fi
  else
    # No notifier is a REPORTING gap, not a deploy failure: the verdict is still printed (below) and
    # still decides the exit code. It says so, loudly, rather than pretending it notified someone.
    echo "$PROG: WARNING — no notifier at '${NOTIFY:-<unset>}' (looking for \$O/bg/notify.sh); verdict printed only" >&2
    printf '  [notify-UNRUNNABLE] %s: %s\n' "$1" "$2"
  fi
}

say() { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*"; }
fatal() { echo "$PROG: FATAL: $*" >&2; }

# ⛔ THE NOTIFIER DEFAULT IS RESOLVED *BEFORE* THE PREFLIGHT, and that ordering is the whole point:
# the refusal paths are the ones that must notify a FAILURE (indicator (a) of #2041), so a notifier
# resolved after them would leave exactly the loudest failure — "the source was not there" — reported
# to nobody. `-f` tolerates a target that does not exist yet; the preflight below is what refuses it.
if [ "$DO_NOTIFY" -eq 1 ] && [ -z "$NOTIFY" ] && [ -n "$O" ] && [ -f "$O/bg/notify.sh" ]; then
  NOTIFY="$O/bg/notify.sh"
fi

# ⛔ THE LEDGER IS THE EVIDENCE, and it is written from THIS run's observations only. It is written
# to a temp file in the target directory and renamed, so a concurrent reader sees a whole ledger or
# none — never a half-written one. `check-deployed-drift.sh` hashes only `*.sh`, so this file is
# invisible to it by construction and cannot perturb the drift answer.
# Returns non-zero when the ledger could NOT be installed, so the success path can say so instead of
# pointing an operator at evidence that does not exist. `fatal` (stderr, never `say`) so `--quiet`
# cannot suppress the one line that matters.

# Portable octal mode of a path, INCLUDING the setuid/setgid/sticky bits: GNU `stat -c %a` ("4755"),
# BSD `stat -f %p` ("104755", last four digits). ⛔ NOT `stat -f %Lp` — it is the low NINE bits only
# ("755" for a 4755 file), which made the mode blind exactly where it claimed to compare (cycle 7).
# (This line said `%Lp` for a cycle after the code stopped using it; a doc line that re-asserts the
# blind spot it was written to close is the defect class this file exists for.)
# ⛔ THE OUTPUT IS VALIDATED, NOT TRUSTED (review P2, cycle 6). Neither form is safe to believe on its
# own: on GNU, `-f` is the boolean `--file-system` and takes NO argument, so `stat -f %p "$1"` treats
# `%p` as a PATH OPERAND and exits 0 whenever a file of that name exists — returning a multi-line
# filesystem dump. Probe ORDER cannot fix that class (a future `stat` can mis-answer either form), so
# the result is accepted only when it is 3-4 octal digits and is EMPTY otherwise. Empty makes the caller
# take the executable-bit path AND count the file in MODE_UNSET, so the verdict says the mode is not
# this run's evidence instead of asserting something it did not measure.
# ⛔ AND ON BSD THE PERMISSION-ONLY FORMAT IS NOT ENOUGH (review P2, cycle 7). `stat -f %Lp` returns the
# low NINE bits — a 4755 source reads "755" — so the setuid/setgid/sticky bits were invisible to BOTH
# the copy and the verdict: the deploy chmod'd 755 over a 4755 target and still printed VERIFIED. `%p`
# carries the file type and the full mode ("104755"), so the last four digits are taken instead. On GNU
# `stat -c %a` already includes them ("4755"), which is why the first form is tried first.
mode_of() {
  _mo="$(stat -c %a "$1" 2>/dev/null)"
  if [ -z "$_mo" ]; then
    _p="$(stat -f %p "$1" 2>/dev/null)"     # BSD: "100644" / "104755" — file type + full mode
    _mo="${_p#"${_p%????}"}"                 # keep the last four octal digits
  fi
  case "$_mo" in
    [0-7][0-7][0-7]|[0-7][0-7][0-7][0-7]) printf '%s
' "$_mo" ;;
    *) : ;;
  esac
}

# cannot suppress the one line that matters.
write_ledger() { # write_ledger <verdict> <line...>
  [ -n "$LEDGER" ] || return 0
  local tmp v="$1"; shift
  # ⛔ THE LEDGER PATH IS A WRITE TARGET TOO (review P1, 2026-10-21). `> "$tmp"` follows a symlink, so a
  # link planted at the temp name redirected the evidence file outside `$O` while the notification
  # cited it. Same at `$LEDGER` itself, which `mv -f` would replace with a link. Clear the temp (rm -f
  # removes a link, never its target) and refuse a link at the destination.
  #
  # ⛔ AND THE TEMP NAME IS NOT PREDICTABLE (review P2, cycle 4). It used to be `$LEDGER.$$` — `$$` is
  # readable from `ps`, and the clear→write window is a full fork/exec wide, so the name could be
  # targeted. `mktemp` creates the file atomically with O_EXCL, so the name cannot be pre-planted and
  # the redirect writes into a file this process created.
  tmp="$(mktemp "$LEDGER.XXXXXX" 2>/dev/null)" || { fatal "ledger NOT written — cannot create a temp file beside $LEDGER"; return 1; }
  if [ -L "$LEDGER" ]; then
    rm -f "$tmp"; fatal "ledger NOT installed — $LEDGER is a SYMLINK, refusing to write through it"; return 1
  fi
  { printf '# deploy-harness %s  src=%s  o=%s\n' "$(date -u '+%FT%TZ')" "$SRC" "$O"
    printf '# verdict\t%s\n' "$v"
    printf '%s\n' "$@"; } > "$tmp" 2>/dev/null || { rm -f "$tmp"; fatal "ledger NOT written — $LEDGER is not writable"; return 1; }
  # ⛔ `mv -f` onto a DIRECTORY succeeds by moving the temp file INSIDE it, silently — so the shape is
  # refused here rather than reported as a successful install.
  if [ -d "$LEDGER" ] || ! mv -f "$tmp" "$LEDGER" 2>/dev/null; then
    rm -f "$tmp"; fatal "ledger NOT installed — $LEDGER is a directory or cannot be replaced"; return 1
  fi
  return 0
}

# ── 0. PREFLIGHT — refuse BEFORE anything is written, so a bad deploy leaves the box as it found it ──
# ⛔ THE ORDER MATTERS. A preflight that runs after the first write is not a preflight: the measured
# failure was a deploy that half-applied and then announced completion. Nothing below this block may
# be reachable while any of these refuses.
# ⛔ AND A REFUSAL WRITES NOTHING — not even the ledger. Leaving a ledger beside the runtime would
# make the very directory we just promised not to touch carry a deploy artefact, and a later reader
# would find evidence of a deploy that never happened. The reason travels in the notification and on
# stderr instead; the ledger exists only from the first attempted copy onward.
# ⛔ These two refusals notify like every other one: the argument-parse refusals above cannot (the
# notifier is resolved after the loop), so these are the last ones that could go unreported and they
# must not. A missing `--o` is an operator typing `--src` and forgetting the runtime.
[ -n "$O" ] || { fatal "--o <runtime dir> is required (or export O=<runtime dir>); refusing to guess a live runtime"
  notify "orchestrator: harness deploy FAILED" "No target runtime was named (--o / \$O) — nothing was copied (#2041)." high; exit 78; }
[ -n "$SRC" ] || { fatal "--src <harness dir> (or --repo <checkout>) is required"
  notify "orchestrator: harness deploy FAILED" "No source harness directory was named (--src / --repo) — nothing was copied (#2041)." high; exit 78; }

# (a) THE MEASURED DEFECT: the source directory did not exist and the deploy "succeeded".
if [ ! -e "$SRC" ]; then
  fatal "source harness directory does not exist: $SRC"
  fatal "  nothing was copied and nothing was written — this is the agent-infra#2041 false PASS."
  fatal "  A checkout whose main predates scripts/orchestrator-harness produces exactly this; fetch main first."
  notify "orchestrator: harness deploy FAILED" "Source harness directory does not exist: $SRC — nothing was copied, and the runtime at $O was left untouched (#2041)." high
  exit 78
fi
[ -d "$SRC" ] || { fatal "source is not a directory: $SRC"
  notify "orchestrator: harness deploy FAILED" "Source is not a directory: $SRC — nothing was copied (#2041)." high; exit 78; }
[ -r "$SRC" ] && [ -x "$SRC" ] || { fatal "source is not readable/searchable: $SRC"
  notify "orchestrator: harness deploy FAILED" "Source harness directory is not readable: $SRC — nothing was copied (#2041)." high; exit 78; }

[ -d "$O" ] || { fatal "target runtime is not a directory: $O"
  fatal "  this helper REDEPLOYS an existing runtime; a fresh box is install.sh's job, not a silent mkdir."
  notify "orchestrator: harness deploy FAILED" "Target runtime $O is not a directory — nothing was copied (#2041)." high; exit 78; }

# (b2) THE TARGET IS NOT THE SOURCE. A self-deploy compares every file with itself, so its verdict is a
# tautology printed as a success — and it would write the ledger INTO the source tree (an untracked
# file in a checkout, which the next deploy then ships as harness content).
SRC_REAL="$(cd "$SRC" && pwd -P)" || { fatal "source path cannot be resolved: $SRC"
  notify "orchestrator: harness deploy FAILED" "Source path $SRC cannot be resolved — nothing was copied (#2041)." high; exit 78; }
O_REAL="$(cd "$O" && pwd -P)" || { fatal "target path cannot be resolved: $O"
  notify "orchestrator: harness deploy FAILED" "Target path $O cannot be resolved — nothing was copied (#2041)." high; exit 78; }
case "$SRC_REAL/" in "$O_REAL"/*) SELF_OVERLAP=1 ;; *) case "$O_REAL/" in "$SRC_REAL"/*) SELF_OVERLAP=1 ;; *) SELF_OVERLAP=0 ;; esac ;; esac
if [ "$SELF_OVERLAP" -eq 1 ]; then
  fatal "source and target overlap ($SRC_REAL vs $O_REAL) — refusing a self-deploy"
  fatal "  every file would compare with itself, so the verdict could not fail; nothing was written."
  notify "orchestrator: harness deploy FAILED" "Source and target overlap ($SRC_REAL vs $O_REAL) — a self-deploy verifies nothing; nothing was copied (#2041)." high
  exit 78
fi

# ── inventory: what the SOURCE ships, recursively ────────────────────────────────────────────────
# ⛔ FROM THE SOURCE, never from the target. `find "$SRC"` is a bounded walk under one directory this
# script was pointed at — not a root walk — and `-type f` recurses so `gh-rest/gh`, `gh-limit/gh` and
# `retired/*.sh` are deployed too. The old `cp -R src/. $O/` carried them by luck; #2039 is the
# measured case of a subdirectory that never landed.
#
# ⛔ THE WALK'S STATUS IS CHECKED, and this is not defensive pedantry — it was a measured FALSE PASS of
# the same #2041 class. The inventory used to be built inside a PROCESS SUBSTITUTION
# (`while … done < <(cd src && find …)`), whose exit status bash never waits for: an unsearchable
# subdirectory (`find` exit 1, "Permission denied") or a path that VANISHED mid-walk produced a
# TRUNCATED file list, N shrank to the readable subset, every term of the verdict then agreed with
# itself, and the run printed `VERIFIED — 2/2` and exit 0 while the source's `gh-limit.py` was never
# deployed — the exact consequence the file exists to prevent. A partial inventory is not a deploy.
INV=""
if ! INV="$(cd "$SRC" && find . -type f -print)"; then
  fatal "source inventory FAILED under $SRC — a directory is unsearchable, a path vanished mid-walk, or the filesystem errored"
  fatal "  a partial file set cannot be deployed or verified; refusing rather than certifying a subset."
  notify "orchestrator: harness deploy FAILED" "Source inventory failed under $SRC (unsearchable directory, vanished path or I/O error) — a partial file set was NOT deployed, and nothing was written to $O (#2041)." high
  exit 78
fi
# ⛔ AND ANYTHING THAT IS NOT A REGULAR FILE OR A DIRECTORY IS REFUSED, not silently dropped: `find
# -type f` cannot see a symlink, FIFO, socket or device, while the `cp -R` this replaces carried the
# symlink — so a shim shipped in one of those shapes would go missing from a deployment that still
# said VERIFIED. This was a `-type l` probe until review found the FIFO hole (2026-10-21): a source
# carrying `pipe.sh` as a FIFO deployed "5/5 verified" and simply never landed it.
# ⛔ AND THE WALK'S STATUS IS READ (review P2, 2026-10-21): the first version was
# `[ -n "$(cd "$SRC" && find . ! -type f ! -type d -print -quit)" ]`, which discards the exit status
# — so on any `find` without `-quit` (busybox/toybox class) the probe failed, read as "no such entry",
# and the run went on to say VERIFIED over a source that shipped a file it never copied. That is #2041's
# own shape inside the guard that forbids it. Capture, THEN test — the same discipline as the inventory
# above — and walk once instead of twice (`-quit` is dropped along with the second walk it invited).
if ! NONREG="$(cd "$SRC" && find . ! -type f ! -type d -print)"; then
  fatal "source inventory for NON-REGULAR entries FAILED under $SRC (unsearchable directory, vanished path or I/O error)"
  fatal "  an unreadable entry list is not an absence of entries; refusing rather than certifying a subset."
  notify "orchestrator: harness deploy FAILED" "The source scan for non-regular entries failed under $SRC — nothing was written to $O (#2041)." high
  exit 78
fi
if [ -n "$NONREG" ]; then
  LINK="$(printf '%s\n' "$NONREG" | head -1)"
  fatal "source ships a non-regular entry (${LINK#./}) — this deploy copies and byte-verifies regular files only"
  fatal "  dereference it (ship the file it points at) so the bytes this run lands can be compared."
  notify "orchestrator: harness deploy FAILED" "Source $SRC ships a non-regular entry (${LINK#./}) — a symlink, FIFO, socket or device cannot be byte-verified by this deploy — nothing was written to $O (#2041)." high
  exit 78
fi
REL=()
while IFS= read -r f; do [ -n "$f" ] && REL+=("${f#./}"); done < <(printf '%s\n' "$INV" | LC_ALL=C sort)
N=${#REL[@]}

if [ "$N" -eq 0 ]; then
  # Indicator (b) of #2041: "a deploy that copies 0 files cannot print the completion line". Here it
  # cannot even start — an empty source is a broken checkout, not an empty product.
  fatal "source ships ZERO files: $SRC"
  fatal "  a deploy of nothing is not a success; there is nothing this run could verify."
  notify "orchestrator: harness deploy FAILED" "Source $SRC ships zero files — nothing to deploy, and nothing was written to $O (#2041)." high
  exit 78
fi
# Identity anchors. A directory with neither of the first two is not the harness at all; the LAST
# THREE are the files #2041 measured MISSING, and they are required for a second reason: a source
# checkout dated 2026-10-14..2026-10-16 has `orch-loop.sh` and `claims.sh` but not `gh-limit.py`,
# `gh-rest/gh` or `gh-limit/gh` (they landed 2026-10-17/18), so a two-anchor test CERTIFIED a stale
# harness — a days-old checkout instead of a 1274-commit-old one, with the same measured consequence
# (every harness `gh` call unserialised, the `gh-limit` PATH layer absent). A source that is genuinely
# the current harness ships all five, so this is a strict tightening that cannot false-refuse one.
for anchor in orch-loop.sh claims.sh gh-limit.py gh-rest/gh gh-limit/gh; do
  [ -f "$SRC/$anchor" ] || { fatal "$SRC has no $anchor — refusing to deploy a directory that is not the harness"
    notify "orchestrator: harness deploy FAILED" "$SRC has no $anchor — it is not the harness; nothing was written to $O (#2041)." high; exit 78; }
done

# ⛔ A SYMLINKED PARENT DIRECTORY IS THE SAME ESCAPE AS A SYMLINKED LEAF (review P2). The leaf guard in
# the copy loop refuses a target FILE that is a link, but nothing looked at the intermediate
# components: `mkdir -p` follows a symlinked parent, then the staged `mv` writes through it and the
# verify `cmp -s "$SRC/$rel" "$O/$rel"` resolves the SAME way — so the bytes land outside the runtime
# the operator named while the run still prints VERIFIED. That is the #2041 shape exactly ("the shape
# looked fine"), only reached one directory up. It is refused HERE, in the preflight, because it is a
# property of the RUNTIME's shape rather than of one file: nothing at all is written.
# ⛔ THE WALK IS COMPONENT-WISE, deepest to shallowest, on purpose: a single `[ -L "$O/${rel%/*}" ]`
# only inspects the DEEPEST component, so with `$O/a` a link and a source file `a/b/c.sh` it would test
# `$O/a/b` (which the link makes look like a directory) and miss the link that matters.
SYMLINK_DIR=""
for rel in "${REL[@]}"; do
  case "$rel" in */*) d="${rel%/*}" ;; *) continue ;; esac
  while [ -n "$d" ]; do
    if [ -L "$O/$d" ]; then SYMLINK_DIR="$d"; break 2; fi
    case "$d" in */*) d="${d%/*}" ;; *) d="" ;; esac
  done
done
if [ -n "$SYMLINK_DIR" ]; then
  fatal "target has a SYMLINKED DIRECTORY (\$O/$SYMLINK_DIR) on the deploy path — refusing to write through it"
  fatal "  a deploy writes only inside $O; mkdir -p and the staged mv would follow that link and land the bytes elsewhere."
  fatal "  replace it with a real directory (or point --o at the runtime it resolves to) and re-run; nothing was written."
  notify "orchestrator: harness deploy FAILED" "Target $O has a symlinked directory ($SYMLINK_DIR) on the deploy path; writing through it would land files OUTSIDE $O, so nothing was written (#2041)." high
  exit 78
fi

# The ledger lives in the runtime, beside the bytes it describes, unless the caller names a path.
[ -n "$LEDGER" ] || LEDGER="$O/.deploy-ledger.tsv"

say "$PROG: $N file(s) from $SRC -> $O"

# ── 1. COPY — per file, staged then renamed, with the status of EVERY file kept ──────────────────
# ⛔ STAGE-THEN-RENAME, not `cp` over the target: bash reads a script incrementally, so an in-place
# overwrite truncates the inode the controller is executing and it can run mixed content (half old,
# half new). Writing a temp file in the SAME directory and `mv`-ing it over gives the target a NEW
# inode, so a running bash keeps reading its old one through its open fd. Same discipline as
# install.sh's gh-rest/gh seeding and deploy-mac-orchestrator.sh's install_file.
COPIED=0
# Files whose mode could NOT be taken from the source (no usable `stat`) — see the fallback in the copy
# loop. Counted so the verdict can say the mode is not this run's evidence, instead of implying it is.
MODE_UNSET=0
# ⛔ DIRECTORIES CREATED ARE COUNTED, because "0 files written" is NOT "the runtime is unchanged".
# `mkdir -p` runs BEFORE `cp`, and a directory it created is not rolled back: on a full target (or an
# unreadable source) every `cp` fails after some `mkdir -p` calls already succeeded, so `COPIED=0`
# while `$O/gh-rest/` now exists empty. Telling an operator "the runtime is unchanged" in that state
# is the message-must-match-what-was-measured rule (below) broken in the operator's own favour, and
# the next reader trusts it. Review P3.
MADE_DIRS=0
# Whether the failure ledger actually landed in `$O` — it is a WRITE, so a zero-copy run that wrote it
# may not call the runtime "unchanged" (review P2, 2026-10-21).
LEDGER_WRITTEN=0
copy_fail=()
detail=()
for rel in "${REL[@]}"; do
  dst="$O/$rel"
  dstdir="$(dirname "$dst")"
  # ⛔ A SYMLINK AT THE DESTINATION IS A FAILURE TOO. `[ -d ]` follows the link, so a target file that
  # is a symlink into another directory used to pass this guard and `mv` then moved the staged file
  # INTO that unrelated directory — writing outside the runtime we were given while the shape looked
  # fine. A deploy writes only inside `$O`. (The LEAF is refused here, per file, so a partial deploy is
  # reported per file; a symlinked PARENT DIRECTORY is refused in the preflight above, where nothing has
  # been written yet — the two shapes have different blast radii and are refused where each one stops.)
  if [ -L "$dst" ]; then
    copy_fail+=("$rel")
    detail+=("COPY-FAIL	$rel	(target path is a SYMLINK — refusing to write through it)")
    continue
  fi
  # ⛔ AND THE SOURCE LEAF IS CHECKED HERE, BEFORE THE WRITE (review P1, cycle 3). Checking it only in
  # the verdict is too late: `cp -p "$SRC/$rel"` has already followed the link, so the impostor's bytes
  # are IN `$O` by the time the run refuses to certify them — the runtime is already wrong, and a later
  # process reading `$O` sees them. Refusing at the copy means the bytes never land. (The preflight
  # catches a source that SHIPS a link; this catches one that becomes a link mid-run, which is the
  # reachable case — a `git checkout`/stash or an editor's atomic save in the source checkout. The
  # verify-side arm below stays as the second half: it catches a swap between this check and the cmp.)
  if [ -L "$SRC/$rel" ]; then
    copy_fail+=("$rel")
    detail+=("COPY-FAIL	$rel	(source path is a SYMLINK — refusing to copy its target's bytes)")
    continue
  fi
  if [ -d "$dst" ]; then
    # A directory where a file belongs: staging would succeed and `mv` would move the staged file
    # INTO it, reporting success while the target kept the wrong shape. Refuse the shape.
    copy_fail+=("$rel")
    detail+=("COPY-FAIL	$rel	(target path is a DIRECTORY, not a file)")
    continue
  fi
  # Count the components THIS call will create, so a zero-file run can say what it actually changed.
  # Walked BEFORE the mkdir, stopping at the first component that already exists — exactly what
  # `mkdir -p` creates. It walks up from the destination rather than comparing against "$O" by
  # string, so a trailing slash (or any other spelling of the same runtime) cannot skew the count.
  made=0; _d="$dstdir"
  while [ ! -d "$_d" ]; do
    made=$((made + 1)); _p="$(dirname "$_d")"; [ "$_p" = "$_d" ] && break; _d="$_p"
  done
  if ! mkdir -p "$dstdir" 2>/dev/null; then
    copy_fail+=("$rel"); detail+=("COPY-FAIL	$rel	(cannot create $dstdir)"); continue
  fi
  MADE_DIRS=$((MADE_DIRS + made))
  # ⛔ THE STAGING NAME IS A WRITE TARGET TOO (review P1, 2026-10-21). Every guard in this loop looked
  # at `$dst`, and none at `$tmp` — but `cp` writes THROUGH a symlink at the destination path. A link
  # planted at `$dstdir/.<name>.deploy.<pid>` (a leftover from a crashed run is enough, and `$$` is
  # readable from `ps`) sent the harness bytes to a path OUTSIDE `$O`, left `$O/<name>` as a link to it,
  # and then verified equal because `cmp` follows links — reproduced: "VERIFIED — 74/74", exit 0, the
  # bytes landed in /tmp.
  #
  # ⛔ SO THE STAGING NAME IS UNPREDICTABLE, NOT MERELY CLEARED (review P2, cycle 4). Clearing closed a
  # link that was ALREADY there; the clear→cp window is a fork/exec wide and the old name was fully
  # predictable, so it could be re-planted inside that window (reproduced: `cp` wrote THROUGH the link
  # and `chmod +x`-ed it, destroying an arbitrary file outside `$O` — the verdict failed closed, but a
  # deploy may not destroy a file it does not own). `mktemp` creates the name atomically with O_EXCL,
  # so it cannot be created by anyone else first, and the copy writes into a file this run owns.
  tmp="$(mktemp "$dstdir/.deploy-XXXXXX" 2>/dev/null)" || {
    copy_fail+=("$rel"); detail+=("COPY-FAIL	$rel	(cannot create a staging file in $dstdir)"); continue
  }
  if ! cp -p "$SRC/$rel" "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    copy_fail+=("$rel"); detail+=("COPY-FAIL	$rel	(cp from source failed)"); continue
  fi
  # the staging file is OURS if it is still a regular file: `mktemp` made it, and a swap after that
  # point would have had to be performed by a concurrent writer — see the residual recorded in the VERIFY loop below.
  if [ -L "$tmp" ] || [ ! -f "$tmp" ]; then
    rm -f "$tmp"
    copy_fail+=("$rel"); detail+=("COPY-FAIL	$rel	(staging path was replaced by a non-regular file — staged bytes discarded)")
    continue
  fi
  # ⛔ RE-CHECK THE SOURCE LEAF **AFTER** THE COPY — the check before it cannot help, because the swap
  # happens INSIDE `cp` (the shim in case 17j proves it: the pre-copy check sees the real file, then cp
  # reads the link). Discarding the staged file here means the impostor's bytes never reach `$O` at all,
  # instead of being written and then refused at the verdict. All three points are needed: before the
  # copy (a link already present), after it (a link created during it), and in the verify loop (a link
  # created after the copy, before the cmp).
  if [ -L "$SRC/$rel" ]; then
    rm -f "$tmp"
    copy_fail+=("$rel"); detail+=("COPY-FAIL	$rel	(source became a SYMLINK during the copy — staged bytes discarded)")
    continue
  fi
  # ⛔ THE MODE IS APPLIED EXPLICITLY, NOT INHERITED FROM `cp -p` (review P2, cycle 5). The executable
  # bit is the piece of metadata whose loss is silent AND fatal (a 0644 merge-one.sh is a loop that
  # cannot spawn), so it was always asserted — but the rest of the mode was left to `cp -p`, and once
  # the staging file is pre-created by `mktemp` (0600) a `cp` that ignores `-p` lands 0600/0711 instead
  # of the source's mode. Rather than trust the flag, copy the source's mode across; the exec-bit
  # repair stays as the fallback for a platform with no usable `stat`.
  _smode="$(mode_of "$SRC/$rel")"
  if [ -n "$_smode" ]; then
    if ! chmod "$_smode" "$tmp" 2>/dev/null; then
      rm -f "$tmp"; copy_fail+=("$rel"); detail+=("COPY-FAIL	$rel	(cannot set the source's mode $_smode)"); continue
    fi
  elif [ -x "$SRC/$rel" ] && ! chmod +x "$tmp" 2>/dev/null; then
    rm -f "$tmp"; copy_fail+=("$rel"); detail+=("COPY-FAIL	$rel	(cannot set the executable bit)"); continue
  elif [ -z "$_smode" ]; then
    # ⛔ WHAT THIS FALLBACK ACTUALLY DOES, STATED (review P2, cycle 6). It restores the EXECUTABLE BIT and
    # nothing else: the rest of the mode stays whatever the copy landed, which — with the staging file
    # pre-created 0600 by `mktemp` — is the staging mode, not the source's. The earlier comment called
    # this "the fallback", implying a safe degradation; it is a KNOWN limitation, so it is counted and
    # reported in the verdict rather than left to be discovered.
    MODE_UNSET=$((MODE_UNSET + 1))
    detail+=("MODE-UNSET	$rel	(no usable 'stat' — only the executable bit was restored)")
  fi
  if ! mv -f "$tmp" "$dst" 2>/dev/null; then
    rm -f "$tmp"; copy_fail+=("$rel"); detail+=("COPY-FAIL	$rel	(rename onto target failed)"); continue
  fi
  COPIED=$((COPIED + 1))
  detail+=("copied	$rel")
done

if [ "${#copy_fail[@]}" -ne 0 ]; then
  # ⛔ NO PARTIAL SUCCESS IS CLAIMED, and the count is THIS RUN's, never the target's: "$COPIED of $N
  # WERE written" is a statement about what happened, not about what is on disk.
  fatal "copy FAILED for ${#copy_fail[@]} of $N file(s) — $COPIED written, $((N - COPIED)) not"
  # ⛔ THE REASON IS PRINTED, not just logged (review P1/P2, cycle 3): a bare "FAILED claims.sh" makes an
  # operator guess between a symlink, a full disk and a lost rename. The reason already travels in
  # `detail` as a tab-separated COPY-FAIL record, so it is READ from there rather than carried twice —
  # a second parallel array is a second thing to keep in sync (bash 3.2 has no associative arrays).
  for f in "${copy_fail[@]}"; do
    _why="$(printf '%s\n' "${detail[@]}" | awk -F'\t' -v r="$f" '$1=="COPY-FAIL" && $2==r {print $3; exit}')"
    printf '  FAILED  %s  %s\n' "$f" "${_why:-(copy failed)}" >&2
  done
  write_ledger "FAILED: copy ($COPIED/$N written, ${#copy_fail[@]} failed)" "${detail[@]}" && LEDGER_WRITTEN=1
  # ⛔ THE MESSAGE MUST MATCH WHAT WAS MEASURED. With ZERO files written the runtime is NOT "partial" —
  # it is exactly as it was, and telling an operator it is partial invites a restore/re-kill of a
  # healthy box. Branch on the count instead of asserting the worse case.
  if [ "$COPIED" -eq 0 ]; then
    # ⛔ AND "UNCHANGED" IS A CLAIM ABOUT THE WHOLE RUNTIME, not about the file count. `mkdir -p` is
    # not rolled back, so a zero-file run may still have left empty directories behind. Say which
    # measurement produced the words; only a run that created nothing may call the runtime unchanged.
    # ⛔ AND THE LEDGER IS A WRITE (review P2, 2026-10-21). The failure ledger is installed INTO `$O`
    # above, so a writable runtime with every `cp` failing used to claim "unchanged" while the run had
    # just added `$O/.deploy-ledger.tsv` — this file's own rule broken in the operator's favour. The
    # wording now names the one file the run did write, instead of denying it.
    LEDGER_CLAUSE=""
    [ "${LEDGER_WRITTEN:-0}" = 1 ] && LEDGER_CLAUSE=" (the run did write its own record to $LEDGER, and nothing else)"
    if [ "$MADE_DIRS" -eq 0 ]; then
      notify "orchestrator: harness deploy FAILED" "Copy failed for ${#copy_fail[@]} of $N file(s) — NOTHING was copied (0/$N); the runtime at $O is otherwise unchanged${LEDGER_CLAUSE}. First: $(printf '%s' "${copy_fail[0]}") (#2041)." high
    else
      if [ "$MADE_DIRS" -eq 1 ]; then MADE_WORD="1 directory was created"
      else MADE_WORD="$MADE_DIRS directories were created"; fi
      notify "orchestrator: harness deploy FAILED" "Copy failed for ${#copy_fail[@]} of $N file(s) — no FILE was written (0/$N), but $MADE_WORD under $O, so it is NOT byte-unchanged. First: $(printf '%s' "${copy_fail[0]}") (#2041)." high
    fi
  else
    notify "orchestrator: harness deploy FAILED" "Copy failed for ${#copy_fail[@]} of $N file(s) ($COPIED written, first: $(printf '%s' "${copy_fail[0]}")). The runtime at $O is now PARTIAL — do not treat it as current (#2041)." high
  fi
  exit 1
fi

# ── 2. VERIFY — the diff/drift half: does every source file exist at the target, byte for byte? ──
# ⛔ THIS IS THE PART THE OLD DEPLOY NEVER HAD. A count of files in the target proves nothing; a
# comparison of every file against its source proves the bytes actually landed. Verified counts what
# THIS run copied AND what compares equal — a pre-existing file that differs (a live-only patch, a
# stale script) is a FAILURE here, not a file that "was already there".
VERIFIED=0
verify_fail=()
# The per-file REASON, kept parallel to `verify_fail` (bash 3.2 has no associative arrays). #2041's own
# rule is that a message must match what was measured — a bare "DRIFT claims.sh" makes an operator
# guess between a byte diff, a lost exec bit and a symlink, so the reason is printed, not just logged.
verify_why=()
for rel in "${REL[@]}"; do
  # ⛔ A SYMLINK AT THE TARGET IS NEVER VERIFIED **WHEN IT IS THERE AT THE CHECK** (review P1, 2026-10-21;
  # claim narrowed by review P1, cycle 4). `cmp` follows links, so a link at `$O/<name>` compares equal
  # to the source while `$O` does not actually hold those bytes — the runtime would run whatever the
  # link points at. Checked FIRST so the reported reason is the link, not a downstream byte diff.
  #
  # ⛔ WHAT THIS DOES *NOT* COVER, STATED RATHER THAN OVERCLAIMED. An earlier version of this comment said
  # "whatever put it there", which is false: this test and the `cmp` below are two statements, and a link
  # arriving BETWEEN them is followed — reproduced in cycle 4 with a `cmp` shim that swaps the
  # destination for a link to the source (equal bytes, exit 0, `VERIFIED`, ledger says `verified`, while
  # `$O` holds links). Closing that needs an atomic compare (open the target `O_NOFOLLOW`, `fstat` it
  # regular, compare through the fd), which bash cannot express; a second `[ -L ]` after `cmp` would
  # just be the same check-then-use one line later, so it is not added as theatre. **The residual is:
  # a concurrent writer with write access to `$O` during the run can defeat this arm.** That writer
  # already has `$O` write access, so this is not a privilege boundary — the guard's job is the
  # the #2041 class (the TOOL lying about its own work), and for that the arm is sound.
  # ⛔ AND THE PARENT CHAIN IS RE-CHECKED HERE, not only in the preflight (review P2, 2026-10-21). The
  # preflight walk is a property of the runtime AS IT WAS; a directory on the deploy path swapped for a
  # link DURING the run is followed by `mkdir -p`, by the staged `mv` and by this `cmp`, and the run then
  # certifies bytes outside the runtime it was given. The preflight comment claimed the verdict was
  # independent of "any future way a link reaches `$O`" — true for leaves, false for parents until this
  # walk existed. Component-wise, deepest to shallowest, same as the preflight.
  _lrel=""
  case "$rel" in */*) _d="${rel%/*}"; while [ -n "$_d" ]; do [ -L "$O/$_d" ] && { _lrel="$_d"; break; }; case "$_d" in */*) _d="${_d%/*}" ;; *) _d="" ;; esac; done ;; esac
  if [ -n "$_lrel" ]; then
    verify_fail+=("$rel"); verify_why+=("a DIRECTORY on its deploy path ($_lrel) is a SYMLINK, so the bytes landed outside $O")
    detail+=("DRIFT	$rel	(a directory on its deploy path ($_lrel) is a SYMLINK)")
  elif [ -L "$O/$rel" ]; then
    verify_fail+=("$rel"); verify_why+=("target path is a SYMLINK, so 'equal' would be the link's target")
    detail+=("DRIFT	$rel	(target path is a SYMLINK, so 'equal' would be the link's target)")
  elif [ -L "$SRC/$rel" ]; then
    # ⛔ THE SOURCE SIDE IS RE-CHECKED TOO (review P1, cycle 3). The preflight refuses a source that
    # SHIPS a link, but that walk is a property of the source AS IT WAS: a file replaced by a symlink
    # DURING the run is followed by BOTH `cp -p "$SRC/$rel"` and the `cmp` below, so the bytes that land
    # in `$O` come from outside the harness and are certified anyway. Reproduced with a `cp` shim that
    # swaps `$SRC/claims.sh` for a link: `VERIFIED — 7/7`, exit 0, while `$O/claims.sh` held the
    # impostor's bytes. Reachable without an attacker — a `git checkout`/stash or an editor's atomic
    # save in the source checkout does it. Symmetric with the target-side arms above.
    verify_fail+=("$rel"); verify_why+=("the SOURCE path became a SYMLINK during the run, so the bytes copied are the link's target")
    detail+=("DRIFT	$rel	(the SOURCE path became a SYMLINK during the run)")
  elif ! cmp -s "$SRC/$rel" "$O/$rel"; then
    verify_fail+=("$rel"); verify_why+=("bytes differ from the source after copy")
    detail+=("DRIFT	$rel	(bytes differ from the source after copy)")
  elif [ -x "$SRC/$rel" ] && [ ! -x "$O/$rel" ]; then
    verify_fail+=("$rel"); verify_why+=("source is executable, target is not")
    detail+=("DRIFT	$rel	(source is executable, target is not)")
  elif [ -n "$(mode_of "$SRC/$rel")" ] && [ "$(mode_of "$SRC/$rel")" != "$(mode_of "$O/$rel")" ]; then
    # ⛔ THE MODE IS EVIDENCE HERE TOO, NOT JUST IN THE COPY (review P3, cycle 6). The copy applies the
    # source's mode, but a `chmod` that returns success while the result differs (a kernel clearing a
    # setgid bit for a non-member group, a mount that masks bits) used to certify VERIFIED with a mode
    # the source does not have. Comparing it here means the TOOL's own evidence covers what the suite
    # otherwise had to pin on its behalf.
    verify_fail+=("$rel"); verify_why+=("mode differs: source $(mode_of "$SRC/$rel"), target $(mode_of "$O/$rel")")
    detail+=("DRIFT	$rel	(mode differs: source $(mode_of "$SRC/$rel"), target $(mode_of "$O/$rel"))")
  else
    VERIFIED=$((VERIFIED + 1))
    detail+=("verified	$rel")
  fi
done

if [ "${#verify_fail[@]}" -ne 0 ]; then
  fatal "VERIFICATION FAILED for ${#verify_fail[@]} of $N file(s) — $VERIFIED verified"
  _i=0
  while [ "$_i" -lt "${#verify_fail[@]}" ]; do
    printf '  DRIFT  %s  (%s)\n' "${verify_fail[$_i]}" "${verify_why[$_i]}" >&2
    _i=$((_i + 1))
  done
  write_ledger "FAILED: verification ($VERIFIED/$N verified, ${#verify_fail[@]} drifted)" "${detail[@]}"
  notify "orchestrator: harness deploy FAILED" "Verification failed for ${#verify_fail[@]} of $N file(s) after copy ($VERIFIED identical, first: $(printf '%s' "${verify_fail[0]}")). The runtime at $O does NOT match $SRC (#2041)." high
  exit 1
fi

# ── 3. THE VERDICT — a conjunction, and every term is about this run ─────────────────────────────
# Reachable only when: N ≥ 1 (preflight), copy_fail empty (so COPIED == N), verify_fail empty (so
# VERIFIED == N). Re-asserted rather than assumed: if any future edit breaks one of those invariants,
# this refuses to call it a success instead of printing a number that happens to look right.
if [ "$N" -lt 1 ] || [ "$COPIED" -ne "$N" ] || [ "$VERIFIED" -ne "$N" ]; then
  fatal "internal invariant broken: N=$N copied=$COPIED verified=$VERIFIED — refusing to report success"
  write_ledger "FAILED: invariant (N=$N copied=$COPIED verified=$VERIFIED)" "${detail[@]}"
  notify "orchestrator: harness deploy FAILED" "Deploy invariant broken (shipped=$N copied=$COPIED verified=$VERIFIED); refusing to report success for $O (#2041)." high
  exit 1
fi

say "$PROG: VERIFIED — $VERIFIED/$N file(s) written by this run and byte-identical to $SRC"
if [ "$MODE_UNSET" -gt 0 ]; then
  # The bytes are verified; the MODE is not. Said here because the line above is what an operator quotes.
  say "$PROG: ⚠️  mode NOT set from the source for $MODE_UNSET file(s) (no usable 'stat' on this host) — only the executable bit was restored; do not read this verdict as 'the mode is the source's'"
fi

# ── 3b. THE IDENTITY RECORD — the bytes are right, but is the box's OWN record still about them? ─
# `install.sh` folds this deployment's `$O/*.sh` into `.agent-infra-stamp.json` (`payloadSha256`), and
# `check-deployed-drift.sh` reports a mismatch as "a post-install hand edit" — its top-severity alarm.
# Nothing re-stamped after a redeploy, so EVERY legitimate redeploy turned into that alarm and the
# alarm stopped meaning anything. The stamp is not this helper's to write (install.sh owns the
# provenance record), so the verdict NAMES the staleness instead of hiding it: the deploy's own
# evidence is still true, and the operator is told the one command that re-records it.
STAMP_NOTE=""
STAMP="$O/.agent-infra-stamp.json"
if [ -f "$STAMP" ]; then
  SHA_CMD="sha256sum"; command -v sha256sum >/dev/null 2>&1 || SHA_CMD="shasum -a 256"
  # ⛔ AN UNREADABLE STAMP IS "CANNOT CHECK", NOT "NO RECORD" (review P3, cycle 8). The assignment's
  # status was unread, so a present-but-unreadable stamp yielded an empty REC, the whole arm was skipped,
  # and the run said nothing — silently deleting the one check whose contract (above) is that "cannot
  # check" is ALWAYS said out loud. An absent stamp is legitimately silent; an unreadable one is not.
  if [ ! -r "$STAMP" ]; then
    say "  ⚠ identity record NOT CHECKED: $STAMP exists but is UNREADABLE, so the record was not compared."
    say "    The bytes above are still verified. Fix its permissions, then re-run install.sh."
    detail+=("STAMP-UNCHECKED	.agent-infra-stamp.json	(the stamp exists but is UNREADABLE)")
  fi
  REC="$(sed -n 's/.*"payloadSha256"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$STAMP" 2>/dev/null | head -1)"
  # ⛔ AN INCOMPLETE FOLD IS NOT A COMPARISON — the fold's STATUS IS READ (review P2). The `|| exit 3`
  # below was inert: `set -uo pipefail` makes the pipeline status 3, but nothing read the assignment's
  # rc, so `LIVE` kept whatever `awk` printed. One unreadable `$O/*.sh` (a root-owned 0600 leftover, a
  # hardened copy) produced a PARTIAL digest, the first unreadable one produced the empty-input digest
  # `e3b0c442…`, and a host with no sha tool produced nothing at all — and every one of those was
  # reported as "identity record STALE — run install.sh to re-stamp" over a record that was correct,
  # while the no-tool case said NOTHING and looked like a pass. Both siblings guard this explicitly
  # (`install.sh`'s `prov_payload_hash` → `UNKNOWN`; `check-deployed-drift.sh`'s `o_payload_hash` →
  # `unknown`, whose comment records the measurement: a chmod-000 `$O/claims.sh` produced a false
  # DRIFT). The wrong advice also propagates: install.sh's own fold fails on the same file, so the
  # re-stamp it recommends cannot run — "cannot check" is the truthful verdict.
  LIVE=""
  if [ -n "$REC" ] && [ -r "$STAMP" ]; then
    if ! LIVE="$( { set -o pipefail
        ( cd "$O" || exit 3
          for f in *.sh; do [ -f "$f" ] || continue; $SHA_CMD "$f" || exit 3; done ) \
          | $SHA_CMD | awk '{print $1}'
      } 2>/dev/null )"; then
      LIVE=""
    fi
    if [ -z "$LIVE" ]; then
      say "  ⚠ identity record NOT CHECKED: the payload fold could not complete over $O/*.sh (an unreadable file, or no sha256 tool)."
      say "    The bytes above are still verified; the stamp at $STAMP was NOT compared. Fix the unreadable file, then re-run install.sh."
      detail+=("STAMP-UNCHECKED	.agent-infra-stamp.json	(cannot hash the deployed *.sh — unreadable file, or no sha256 tool)")
    elif [ "$REC" != "$LIVE" ]; then
      STAMP_NOTE="; identity record STALE — run install.sh to re-stamp"
      say "  ⚠ identity record STALE: $STAMP no longer describes these bytes (payloadSha256 ${REC:0:12}… vs live ${LIVE:0:12}…)."
      say "    Re-run install.sh to re-record it; check-deployed-drift.sh will otherwise call this deploy a hand edit."
      detail+=("STALE-STAMP	.agent-infra-stamp.json	(payloadSha256 ${REC:0:12} vs live ${LIVE:0:12})")
    fi
  fi
fi

if ! write_ledger "VERIFIED: $VERIFIED/$N copied and identical${STAMP_NOTE:+, identity record STALE}" "${detail[@]}"; then
  # ⛔ A success verdict whose evidence file could not be written must SAY SO in the verdict — the
  # notification points the operator at the ledger, and pointing at a file that does not exist is the
  # same defect one line over. The bytes are still verified; the reporting gap is named, not hidden.
  say "  ⚠ the ledger could NOT be written at $LEDGER — the verdict above rests on this run's counts, not on a file"
  # ⛔ AND THE *NOTIFICATION* MUST AGREE (review P2, cycle 3). The `say` line above is stdout; a caller
  # reads the notification. It kept asserting "this deploy's own ledger" while no ledger existed — the
  # invariant this block states, broken one line over, and NEW at the symlink path (before the
  # `[ -L "$LEDGER" ]` refusal that path silently replaced the link and the cited ledger existed).
  LEDGER_CLAIM="the ledger could NOT be installed at $LEDGER — the verdict rests on this run's counts"
else
  LEDGER_CLAIM="this deploy's own ledger, not a listing of what was already there"
fi
# ⛔ NO RESTART CLAIM. This message says what was measured: N files copied and compared. It does not
# say the controller restarted, because this script did not restart it.
notify "orchestrator: harness deploy VERIFIED" "$VERIFIED/$N file(s) copied from $SRC and byte-identical at $O (${LEDGER_CLAIM})${STAMP_NOTE}." high
exit 0
