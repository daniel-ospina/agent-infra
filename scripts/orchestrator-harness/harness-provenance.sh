#!/usr/bin/env bash
# harness-provenance.sh — a deployed harness tree CARRIES the commit it is and the bytes it holds;
# and a deploy can ask, before it overwrites anything, whether it is about to discard someone's patch.
#
#   harness-provenance.sh write --o <runtime> --src <harness-src> [--commit <sha>] [--ref <ref>]
#                               [--repo <checkout>] [--source-dirty <true|false|unknown>]
#                               [--origin <harness-live-dir>]
#   harness-provenance.sh check --o <runtime> [--src <harness-src>] [--skip <relpath>]...
#   harness-provenance.sh show  --o <runtime>
#
# Exit: write → 0 recorded, 1 could NOT record (says why), 78 bad invocation / unusable input
#       check → 0 no uncommitted edit, 1 at least one found (each PRINTED), 2 UNKNOWN (no usable
#               record — never a clean answer), 78 bad invocation
#       show  → 0 printed, 2 UNKNOWN (no usable record, or commit=UNKNOWN), 78 bad invocation
#
# ── WHY THIS EXISTS, MEASURED TWICE ON TWO BOXES (2026-10-28, 2026-10-29) ────────────────────────
# The deployed harness at `$O` silently stopped being the canonical code, and nothing said so:
#
#   * Box A (macOS, 2026-10-28): a hand-applied fix to `$O/merge-one.sh` was REVERTED TWICE by a
#     redeploy (the file's mtime moved at 20:02 and again at 20:15, after the patch). The box then
#     ran unpatched code and a production fix looked like it had "stopped working". The deploy
#     printed nothing it was about to overwrite, and did not refuse.
#   * Box B (2026-10-29): `harness=diverged:5712e52776c8` — `~/orchestrator/orch-loop.sh` was not
#     byte-identical to `scripts/orchestrator-harness/orch-loop.sh`, so a diagnosis made against the
#     checkout described code the box was not running.
#
# `check-deployed-drift.sh` already compared $O to a checkout and named differing files. What no
# artifact could say was **which commit this deployed tree IS**, so the check could not separate the
# two questions a reader actually has, and no deploy could tell a hand patch from its own last run.
#
# ── THE TWO QUESTIONS, AND WHY THEY MUST NOT BE CONFLATED ────────────────────────────────────────
#   (a) IS $O THE TREE IT CLAIMS?      ← answered by THIS record alone, with no checkout present:
#                                          the manifest below is what the deploy wrote. A file that
#                                          no longer hashes to its entry is an EDIT IN $O.
#   (b) IS $O IDENTICAL TO THE CHECKOUT ← answered by check-deployed-drift.sh against the ref.
#       RIGHT NOW?                        A box deliberately one commit BEHIND is (a)-clean and
#                                          (b)-behind: a KNOWN state, not a defect. A box carrying
#                                          uncommitted edits is (a)-DIRTY: a different thing, and the
#                                          one that silently ate a fix.
#
# ── THE RECORD ──────────────────────────────────────────────────────────────────────────────────
# `$O/.harness-provenance`, plain text so bash 3.2 can write and read it with no jq and no JSON
# escaping. `check-deployed-drift.sh` reads the SAME format; a change here must change it there.
#
#     # comment lines
#     version=1
#     commit=<40-hex|UNKNOWN>        the SOURCE commit the deploy came from
#     ref=origin/main                 the ref that commit was resolved against
#     refCommit=<40-hex|UNKNOWN>      that ref's tip AT DEPLOY TIME (a LATER move is "behind")
#     source=<path>                  the LIVE harness directory a redeploy would read (see
#                                   `--origin`: a deploy that stages through a temporary dir
#                                   records the live tree, because `source=` is what a plain
#                                   `check` classifies a phase-A leftover against)
#     recordedAt=<UTC ISO-8601>
#     files=<n>
#     sourceDirty=<true|false|unknown> whether the SOURCE could carry bytes `commit` does not
#                                   (`--source-dirty` states it for a staged deploy: a
#                                   `git archive` staging dir cannot be asked, and its payload is
#                                   committed bytes by construction, so it is `false`)
#     <sha256>  <relpath>             one line per regular file the source shipped
#
# ⛔ `commit=UNKNOWN` IS AN ANSWER, A MISSING RECORD IS NOT: an explicit UNKNOWN makes the reader
# exit 2, and a missing record does too. Neither is ever read as clean.
#
# ── WHO WRITES IT ───────────────────────────────────────────────────────────────────────────────
# The DEPLOY path, at the end of a COMPLETE deploy: `deploy-harness.sh` and
# `deploy-mac-orchestrator.sh` (phase B). Not `install.sh` — that keeps writing its own
# `.agent-infra-stamp.json`, which this record does not replace (the check prefers this one when it
# is present and falls back to the stamp otherwise, so every existing box keeps its answer).
# ⛔ A PARTIAL deploy must NOT write it: `deploy-mac-orchestrator.sh` phase A deliberately leaves
# `orch-loop.sh` alone, so a record written then would claim a commit for a tree that is half of it.
#
# ⛔ SAFE TO RUN ON A LIVE BOX: `write` creates one record file (temp-then-rename in the same
# directory, so a reader never sees half of it), and `check`/`show` write nothing at all.
set -u

PROG="$(basename "${BASH_SOURCE[0]}")"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
usage() { awk 'NR>1 && /^set -u$/{exit} NR>1{sub(/^# ?/,""); print}' "${BASH_SOURCE[0]}"; }

die() { printf '%s: %s\n' "$PROG" "$*" >&2; exit 78; }
say() { printf '%s\n' "$*"; }
# Every refusal/failure prints on stderr and names the file, so an operator reading only stderr has
# the whole reason — the same discipline deploy-harness.sh follows.
bad() { printf '%s: %s\n' "$PROG" "$*" >&2; }

SHA_CMD="sha256sum"
command -v sha256sum >/dev/null 2>&1 || SHA_CMD="shasum -a 256"
command -v ${SHA_CMD%% *} >/dev/null 2>&1 || die "no sha256sum/shasum on PATH — cannot hash the deployed files"

# The digest of one file, or a NON-ZERO status with no output. ⛔ The caller MUST read the status: an
# unreadable file that hashes to "" would be compared against nothing and reported as fine.
sha_of() { # sha_of <path>
  local out
  out="$( $SHA_CMD "$1" 2>/dev/null )" || return 1
  out="${out%% *}"
  [ -n "$out" ] || return 1
  printf '%s' "$out"
}

# One `key=value` field out of the record. Anchored on the key at the START of the line, so
# `commit` cannot match `refCommit`.
prov_field() { # prov_field <record> <key>
  sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1
}

# A trailing slash is the same directory (tab completion adds one); normalise once.
norm_dir() { # norm_dir <path>
  while [ "${#1}" -gt 1 ] && [ "${1%/}" != "$1" ]; do set -- "${1%/}"; done
  printf '%s' "$1"
}

MODE="${1:-}"
[ -n "$MODE" ] || { usage >&2; exit 78; }
case "$MODE" in -h|--help) usage; exit 0 ;; esac
shift

O=""; SRC=""; COMMIT_ARG=""; REF_ARG=""; REPO_ARG=""; DIRTY_ARG=""; ORIGIN_ARG=""
SKIPS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --o)      [ $# -ge 2 ] || die "--o needs a path";        O="$2"; shift 2 ;;
    --src)    [ $# -ge 2 ] || die "--src needs a path";      SRC="$2"; shift 2 ;;
    --commit) [ $# -ge 2 ] || die "--commit needs a sha";    COMMIT_ARG="$2"; shift 2 ;;
    --ref)    [ $# -ge 2 ] || die "--ref needs a git ref";   REF_ARG="$2"; shift 2 ;;
    --repo)   [ $# -ge 2 ] || die "--repo needs a path";     REPO_ARG="$2"; shift 2 ;;
    # ⛔ THE TWO FIELDS A STAGED DEPLOY CANNOT DERIVE FOR ITSELF (`write` only). `deploy-mac-orchestrator.sh`
    # stages `git archive <ref>` into a throwaway directory and deletes it, so neither field can be asked of
    # `--src`: the staging dir is not a checkout (dirtiness is UNKNOWABLE there) and it is gone by the time
    # anyone reads the record (the `source=` PENDING arm was dead on every mac box). Left underived, the
    # record said `sourceDirty=unknown` — which `check-deployed-drift.sh` REFUSES — so the box the record was
    # built for went UNKNOWN, and because the record is preferred over install.sh's stamp it lost the
    # attribution it already had. See `--origin` for `source=`.
    #
    # `--source-dirty` is the deploy's own statement and is VALIDATED: a `git archive` payload is committed
    # bytes by construction, so `false` is the truthful answer there — not `true`, and never a guess.
    --source-dirty)
              [ $# -ge 2 ] || die "--source-dirty needs true|false|unknown"
              case "$2" in true|false|unknown) ;; *) die "--source-dirty must be true, false or unknown (got '$2')" ;; esac
              DIRTY_ARG="$2"; shift 2 ;;
    # `--origin` is what gets RECORDED as `source=`: the LIVE harness directory a redeploy would read. The
    # manifest is still hashed from `--src` (the bytes that were actually deployed), so a staged deploy keeps
    # a truthful inventory AND leaves the reader something that exists.
    --origin) [ $# -ge 2 ] || die "--origin needs a path";   ORIGIN_ARG="$2"; shift 2 ;;
    # ⛔ `--skip <relpath>` (repeatable, `check` only): THE FILES THIS CALLER DOES NOT WRITE. A partial
    # deploy must not refuse over a file it never touches — measured: `deploy-mac-orchestrator.sh` with
    # `PHASE=A` deliberately leaves `$O/orch-loop.sh` alone (phase B owns it), yet the gate asked the
    # writer about the whole staged tree, so an edit to `orch-loop.sh` alone refused a run that would
    # not have overwritten it, and offered `--accept-discard` for a file it never writes. The seam is
    # the caller's own statement of its write set, checked literally.
    --skip)   [ $# -ge 2 ] || die "--skip needs a relative path"; SKIPS="$SKIPS$2
"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ -n "$O" ] || die "--o <runtime dir> is required (the deployed harness tree)"
O="$(norm_dir "$O")"
[ -d "$O" ] || die "no directory at --o $O"
REC="$O/.harness-provenance"

case "$MODE" in

write)
  # ── resolve the SOURCE, and refuse a source that IS the target ────────────────────────────────
  [ -n "$SRC" ] || SRC="$HERE"
  SRC="$(norm_dir "$SRC")"
  [ -d "$SRC" ] || die "--src $SRC is not a directory"
  SRC_REAL="$(cd "$SRC" && pwd -P)" || die "--src $SRC cannot be resolved"
  O_REAL="$(cd "$O" && pwd -P)" || die "--o $O cannot be resolved"
  # ⛔ A SELF-MANIFEST IS A TAUTOLOGY AND A LIAR: asked to record $O from $O, every file would be
  # hashed from the same tree it describes, and the record would then bless whatever `$O` holds —
  # including the runtime state that is not part of any deploy. Refused rather than half-answered.
  [ "$SRC_REAL" != "$O_REAL" ] || die "refusing to record $O from itself — pass --src <the harness directory that was deployed>"

  # `source=` is what a plain `check --o $O` classifies a phase-A leftover against, so it must name a tree
  # that will still EXIST when the record is read. A staged deploy passes `--origin` for that; every other
  # caller's `--src` already is a live directory. It is a SEPARATE variable from SRC_REAL on purpose: the
  # manifest is hashed from `--src` (the bytes actually deployed), and the self-manifest refusal above must
  # keep comparing THAT tree with `$O`, never the origin.
  SOURCE_REC="$SRC_REAL"
  if [ -n "$ORIGIN_ARG" ]; then
    [ -d "$ORIGIN_ARG" ] || die "--origin $ORIGIN_ARG is not a directory (it is recorded as source=, which a reader must be able to look at)"
    SOURCE_REC="$(cd "$ORIGIN_ARG" && pwd -P)" || die "--origin $ORIGIN_ARG cannot be resolved"
    # ⛔ THE SAME TAUTOLOGY, REACHED THROUGH THE NEW FLAG. `source=` is what a plain `check --o $O`
    # classifies a phase-A leftover against (`cmp $CSRC/$rel $O/$rel`), so an origin that IS `$O`
    # compares the tree with itself: the documented `check --o $O` then answers CLEAN over a hand edit
    # a redeploy destroys — the one state this tool exists to make impossible. `--src` is refused for
    # exactly this reason three statements above; `--origin` must be too, or the refusal is a bypass.
    [ "$SOURCE_REC" != "$O_REAL" ] || die "refusing --origin $O — it resolves to --o, and a record whose source IS its target can never report an edit (pass --origin <the live harness directory a redeploy would read>)"
  fi

  W="$(mktemp -d "$O/.harness-prov.XXXXXX" 2>/dev/null)" || die "cannot create a work dir in $O (not writable?)"
  # A refusal from here on must not leave a half-written record behind.
  trap 'rm -rf "$W"' EXIT

  # ── the inventory: what the SOURCE shipped, relative to itself ────────────────────────────────
  # ⛔ The walk's STATUS is read. A truncated inventory would record a manifest that omits files the
  # deploy actually wrote, and every later `check` would call those files hand-placed.
  if ! INV="$( cd "$SRC" && find . -type f -print 2>/dev/null )"; then
    die "the source inventory failed under $SRC (unreadable directory, vanished path or I/O error) — nothing recorded"
  fi
  [ -n "$INV" ] || die "the source at $SRC ships no files — nothing to record"
  # Sorted once, then READ FROM A FILE: a loop fed by a substitution cannot report a truncated feed,
  # and this loop's zero-iteration case would write an empty manifest that reads as "no files".
  if ! printf '%s\n' "$INV" | sed 's|^\./||' | LC_ALL=C sort > "$W/inv" 2>/dev/null; then
    die "could not normalise the source inventory under $SRC — nothing recorded"
  fi

  # ── the commit the deploy came from ──────────────────────────────────────────────────────────
  # `--commit` is the deploy's own statement (deploy-mac-orchestrator stages a `git archive` of a
  # ref, so the staged dir is NOT a checkout and `git -C $SRC` would answer nothing).
  COMMIT="$COMMIT_ARG"
  if [ -z "$COMMIT" ]; then
    COMMIT="$(git -C "$SRC" rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null)" || COMMIT=""
  fi
  [ -n "$COMMIT" ] || COMMIT="UNKNOWN"
  # ⛔ `--verify --quiet`: a bare `git rev-parse <unknown>` ECHOES its argument AND exits non-zero, so
  # an uncaught capture would record the argument as a resolved commit.
  REF="${REF_ARG:-${HARNESS_REF:-origin/main}}"
  REFREPO="${REPO_ARG:-$SRC}"
  REFCOMMIT=""
  if [ -d "$REFREPO" ]; then
    REFCOMMIT="$(git -C "$REFREPO" rev-parse --verify --quiet "$REF^{commit}" 2>/dev/null)" || REFCOMMIT=""
  fi
  [ -n "$REFCOMMIT" ] || REFCOMMIT="UNKNOWN"
  # ⛔ A DIRTY SOURCE IS ITS OWN FACT, AND IT USED TO BE INVISIBLE. The commit is read from the source's
  # HEAD, so a deploy staged from a checkout with uncommitted changes recorded `commit=<HEAD>` for bytes
  # HEAD does not contain — and the box's one-line answer then named a commit it was not running. The
  # legacy stamp carried this (`agentInfraDirty`) but the record did not, so the better record MASKED the
  # only dirtiness signal the codebase had. `unknown` is its own answer: a `git archive` staging dir is
  # not a checkout and cannot be asked.
  SRC_DIRTY="${DIRTY_ARG:-unknown}"
  if [ -z "$DIRTY_ARG" ] && git -C "$SRC" rev-parse --verify --quiet 'HEAD^{commit}' >/dev/null 2>&1; then
    # ⛔ `.` IS THE SOURCE DIRECTORY, AND A PATHSPEC IS READ RELATIVE TO `git -C`'s DIRECTORY. Passing
    # `rev-parse --show-prefix` here (a path relative to the REPO ROOT) from inside the subdirectory
    # matched nothing, so a genuinely dirty source recorded as clean — the one signal this field exists
    # to carry, silently absent. `.` asks about exactly the tree being recorded.
    if _st="$(git -C "$SRC" status --porcelain --untracked-files=no -- . 2>/dev/null)"; then
      if [ -n "$_st" ]; then SRC_DIRTY="true"; else SRC_DIRTY="false"; fi
    fi
  fi

  # ── the manifest: every file the source shipped, as it exists in $O NOW ──────────────────────
  N=0
  : > "$W/manifest" || die "cannot write the manifest in $W"
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    # ⛔ A file the source ships and $O lacks is a FAILED record, not a thin one: the manifest would
    # silently describe less than the deploy claims to have written.
    if [ ! -f "$O/$rel" ]; then
      bad "the source ships $rel but $O has no such file — the deploy is not complete, so no record was written"
      exit 1
    fi
    # ⛔ THE BYTES MUST BE THE SOURCE'S. `write` records what `$O` HOLDS, so on a hand-patched box it
    # produced a record that called the patched bytes "commit <the checkout's>" — and every later
    # `check` then read the patch as something a deploy wrote: the alarm silenced, and the NEXT deploy
    # overwriting the patch believing it was its own. Measured: `write` on a patched `$O` exited 0, and
    # the following `check --src` returned 0 (clean) while `cmp` said the two sides differ. That is the
    # 2026-10-28 incident re-enabled by the tool's own remedy. A record may only describe a deploy.
    cmp -s "$SRC/$rel" "$O/$rel"; CMP_RC=$?
    if [ "$CMP_RC" -eq 1 ]; then
      bad "$O/$rel DIFFERS from $SRC/$rel — a record written now would claim these bytes came from the source, which is exactly the false provenance that hides a hand edit. Land the difference in the checkout and DEPLOY, or move the edited bytes aside. Nothing was recorded"
      exit 1
    elif [ "$CMP_RC" -ne 0 ]; then
      # ⛔ `cmp` RETURNS 2 FOR AN I/O ERROR. Reporting that as "DIFFERS" sends an operator to go and
      # "land the difference" when the files are byte-identical and one of them is merely unreadable —
      # the message-must-match-what-was-measured rule, broken in the operator's own disfavour.
      bad "cannot COMPARE $SRC/$rel with $O/$rel (one of them is unreadable) — a record written now could not be verified against the source. Nothing was recorded"
      exit 1
    fi
    H="$(sha_of "$O/$rel")" || { bad "cannot hash $O/$rel (unreadable?) — no record was written"; exit 1; }
    # The two-space separator is the format check-deployed-drift.sh parses; `rel` may contain
    # spaces, which is why a reader splits on the FIRST two-space run and not on any space.
    printf '%s  %s\n' "$H" "$rel" >> "$W/manifest" || { bad "cannot write the manifest at $W/manifest"; exit 1; }
    N=$((N + 1))
  done < "$W/inv"
  [ "$N" -gt 0 ] || { bad "recorded 0 files from $SRC — refusing to write an empty record"; exit 1; }

  # ── the header — written AFTER the counts, so `files=` cannot disagree with the manifest ──────
  {
    printf '# .harness-provenance — WRITTEN by harness-provenance.sh at the end of a complete deploy.\n'
    printf '# Read by check-deployed-drift.sh (question (a): is this tree the one the record describes?)\n'
    printf '# and by harness-provenance.sh check. Plain text on purpose: bash 3.2 writes and reads it\n'
    printf '# with no jq and no JSON escaping. Do not hand-edit it — re-run the deploy.\n'
    printf 'version=1\n'
    printf 'commit=%s\n' "$COMMIT"
    printf 'ref=%s\n' "$REF"
    printf 'refCommit=%s\n' "$REFCOMMIT"
    printf 'source=%s\n' "$SOURCE_REC"
    printf 'recordedAt=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'files=%s\n' "$N"
    printf 'sourceDirty=%s\n' "$SRC_DIRTY"
  } > "$W/head" || { bad "cannot write the record header in $W"; exit 1; }

  # ── assemble: header, then manifest — temp-then-RENAME ───────────────────────────────────────
  # ⛔ NEVER `cat > "$REC"`: an in-place write truncates the real record FIRST, so an ENOSPC in that
  # window destroys the one artifact that makes the box answerable (the same rule install.sh's stamp
  # writer and deploy-harness.sh's ledger follow).
  if ! cat "$W/head" "$W/manifest" > "$W/final" 2>/dev/null; then
    bad "cannot assemble the record in $W (disk full?)"; exit 1
  fi
  if ! mv -f "$W/final" "$REC" 2>/dev/null; then
    bad "cannot install the record at $REC"; exit 1
  fi
  trap - EXIT
  rm -rf "$W"
  say "recorded $REC"
  say "  commit ${COMMIT:0:12}   ref $REF   $N file(s)"
  if [ "$SRC_DIRTY" = "true" ]; then
    bad "WARNING — the source at $SRC_REAL had UNCOMMITTED changes: commit ${COMMIT:0:12} does NOT describe"
    bad "  these bytes (the record says so: sourceDirty=true). Land the change, redeploy, and the box's"
    bad "  commit answer means what it says."
  fi
  if [ "$COMMIT" = "UNKNOWN" ]; then
    bad "  'which commit is this box running?' has no answer for $O until it is deployed from one."
  fi
  exit 0
  ;;

check)
  # ── answer (a): does $O still hold the bytes the RECORD says were deployed? ──────────────────
  # ⛔ CANNOT-VERIFY IS A THIRD ANSWER AND IT IS NEVER CLEAN. No record, an unreadable record, or a
  # record with no manifest all exit 2 — that is the fail-closed rule the whole issue rests on.
  if [ ! -e "$REC" ]; then
    bad "UNKNOWN: no provenance record at $REC — this tree has never been recorded, so whether it carries uncommitted edits CANNOT BE ANSWERED (and unknown is never clean)"
    exit 2
  fi
  [ -r "$REC" ] || { bad "UNKNOWN: the provenance record at $REC is not readable — cannot verify which bytes were deployed"; exit 2; }
  NMAN="$(prov_field "$REC" files)"
  case "$NMAN" in ''|*[!0-9]*) bad "UNKNOWN: the record at $REC carries no usable file count (files='${NMAN:-<absent>}') — it cannot describe its own manifest"; exit 2 ;; esac
  # ⛔ A ZERO COUNT IS THE SAME CANNOT-VERIFY, AND IT IS THE ONE THAT MATTERS MOST HERE. `check` is the
  # refusal gate both deploys call: with `files=0` and `--src` every manifest entry is skipped, so the
  # gate answers "clean" having compared nothing — a hand-edited box passes the very gate written to
  # stop the overwrite. The sibling reader in check-deployed-drift.sh already refuses this record
  # ("carries an EMPTY manifest"); two readers of one format must not disagree, and the permissive one
  # must never be the gate.
  if [ "$NMAN" -eq 0 ]; then
    bad "UNKNOWN: the record at $REC says files=0 — a record with an EMPTY manifest cannot describe any bytes, so it cannot be checked against $O"; exit 2
  fi

  # ⛔ `check` WRITES NOTHING IN $O — the box under inspection is not a scratch space, and a stray
  # file beside the record would itself be an edit nothing recorded. The staged list lives in a
  # temp dir of its own.
  SRCLIST=""
  if [ -n "$SRC" ]; then
    SRC="$(norm_dir "$SRC")"
    [ -d "$SRC" ] || die "--src $SRC is not a directory"
    # The set this deploy WILL WRITE. A record entry the source does not ship is not overwritten by
    # the deploy, so its edit is not discarded by it (a plain `check` still reports it).
    if ! SRCINV="$( cd "$SRC" && find . -type f -print 2>/dev/null )"; then
      bad "UNKNOWN: the source inventory failed under $SRC — cannot tell what this deploy would overwrite"; exit 2
    fi
    SRCLIST="$(mktemp "${TMPDIR:-/tmp}/harness-prov-src.XXXXXX" 2>/dev/null)" || {
      bad "UNKNOWN: cannot stage the source inventory — cannot tell what this deploy would overwrite"; exit 2; }
    trap 'rm -f "$SRCLIST"' EXIT
    if ! printf '%s\n' "$SRCINV" | sed 's|^\./||' | LC_ALL=C sort > "$SRCLIST" 2>/dev/null; then
      bad "UNKNOWN: cannot stage the source inventory — cannot tell what this deploy would overwrite"; exit 2
    fi
    # ⛔ AN EMPTY SOURCE INVENTORY IS CANNOT-VERIFY, NOT "NOTHING TO DISCARD". Measured: `--src` on an
    # empty directory staged a list holding one empty line, every record entry was dropped by the
    # narrowing, and `check` answered 0 — clean — having compared NOTHING, on a box whose edited file
    # was still sitting in `$O`. `write` already refuses that exact input ("ships no files"); one tool
    # must not give two answers about one input, and "cannot-verify is never clean" applies here too.
    case "$(sed -n '1p' "$SRCLIST" 2>/dev/null)" in
      '') bad "UNKNOWN: the source at $SRC ships NO files, so this check would compare nothing and could only answer 'clean' — that is cannot-verify, never a pass"; exit 2 ;;
    esac
  fi

  EDITS=0
  MISS=0
  PEND=0
  PRESENT=0
  UNSHIPPED=0
  # ⛔ THE RECORD NAMES THE TREE IT WAS WRITTEN FROM (`source=`), SO A PLAIN `check` HAS A SOURCE TOO.
  # Classification used `$SRC` only, which is set only by `--src` — so the DOCUMENTED call
  # (`check --o $O`, no `--src`) still labelled a `PHASE=A` leftover "UNCOMMITTED-EDIT … recover the edit",
  # the exact mislabel this suite's `PENDING` arm was added to remove. Narrowing to `--src` stays a
  # separate decision; CLASSIFYING against the record's own source does not narrow anything.
  CSRC=""
  if [ -n "$SRC" ]; then CSRC="$SRC"
  else
    _rs="$(prov_field "$REC" source)"
    if [ -n "$_rs" ] && [ -d "$_rs" ]; then CSRC="$_rs"; fi
  fi
  NSEEN=0
  SEEN=""
  while IFS= read -r line; do
    # ⛔ CLASSIFY BY THE `<64 hex>  <path>` PREFIX, NOT BY "the line contains two spaces". A header VALUE
    # can contain a two-space run — the deploy writes `source=<the checkout path>`, and a checkout named
    # with two consecutive spaces produced a record whose own `source=` line was read as a manifest
    # entry: `check` exited 2 "cannot parse" FOREVER (re-recording reproduced it), and the drift reader
    # fabricated a MISSING file from a path that never existed. A record the writer cannot read back is
    # worse than no record, so the discriminator is the format's own first field.
    # (This filter is the ONLY non-manifest filter: the `*[!0-9a-f]*) bad …` arm that used to sit below
    # it tested the same string and was unreachable, while its comment claimed to be this reader's
    # CANNOT-VERIFY path. Removed rather than trusted — a guard that cannot run is worse than none.)
    _h="${line%%  *}"
    case "$_h" in
      ''|'#'*) continue ;;              # a blank line or a comment
      *[!0-9a-f]*) continue ;;          # a `key=value` header field, or a stray line
    esac
    H_REC="$_h"
    REL="${line#*  }"
    # A manifest line is `<64 hex>  <path>`; a hash that is not 64 hex chars means a record this
    # reader cannot parse, which is CANNOT-VERIFY rather than "no entries".
    [ "${#H_REC}" -eq 64 ] || { bad "UNKNOWN: the record at $REC has a manifest line whose hash is not 64 hex chars: '$line'"; exit 2; }
    # ⛔ THE SEPARATOR IS ITS OWN TEST, BECAUSE `%%` AND `#` BOTH RETURN THE WHOLE LINE WHEN IT IS ABSENT:
    # on a pathless `<64 hex>` line, `${line%%  *}` and `${line#*  }` are the SAME string, so `REL` became the
    # DIGEST, the emptiness guard below could never fire, and the entry counted as a file whose name was its
    # own hash. `files=` still agreed, so the record looked self-consistent while a hand edit to a nested file
    # answered CLEAN on the documented `check --o $O` call — the one direction this tool exists to close.
    case "$line" in
      *'  '*) ;;
      *) bad "UNKNOWN: the record at $REC has a manifest line with no path: '$line'"; exit 2 ;;
    esac
    [ -n "$REL" ] || { bad "UNKNOWN: the record at $REC has a manifest line with no path: '$line'"; exit 2; }
    NSEEN=$((NSEEN + 1))
    SEEN="$SEEN$REL
"
    # A file this caller does not write is not this caller's to discard.
    if [ -n "$SKIPS" ] && grep -qxF -- "$REL" <<<"$SKIPS"; then continue; fi
    if [ -n "$SRC" ]; then
      # Narrow to what the deploy would write: a difference against the SOURCE is the only case in
      # which running this deploy destroys something.
      grep -qxF -- "$REL" "$SRCLIST" 2>/dev/null || continue
      if [ -f "$SRC/$REL" ] && [ -f "$O/$REL" ] && cmp -s "$SRC/$REL" "$O/$REL"; then
        # ⛔ NOT A SILENT `continue`. Bytes that already equal the SOURCE are a deploy the record has not
        # caught up with (a `PHASE=A` deploy writes $O and, by design, writes no record) — the gate must
        # not refuse it, and it must not stay quiet about it either: "the record is stale" is a fact an
        # operator needs, and the remedy is a completed deploy, not "recover your edit".
        _live="$(sha_of "$O/$REL" 2>/dev/null || true)"
        if [ -n "$_live" ] && [ "$_live" != "$H_REC" ]; then
          bad "PENDING   $REL — $O already holds the SOURCE's bytes; the record predates them (an unrecorded or partial deploy, not a hand edit)"
          PEND=$((PEND + 1))
        fi
        continue
      fi
    fi
    if [ ! -f "$O/$REL" ]; then
      # ⛔ NOT AN EDIT. A file the record names and $O does not have is a box this deploy REPAIRS — it
      # creates the file, so it cannot discard content that is not there. Counting it as an edit made
      # the deploy print "carries UNCOMMITTED EDITS that this deploy would OVERWRITE … copy them aside"
      # about a nonexistent file, and made `--accept-discard` the only way to repair a half-made deploy.
      bad "MISSING   $REL — the record says the deploy wrote it and it is not there now; a redeploy CREATES it (nothing of yours is discarded)"
      MISS=$((MISS + 1)); continue
    fi
    H_LIVE="$(sha_of "$O/$REL")" || { bad "UNKNOWN: cannot hash $O/$REL (unreadable?) — cannot verify it"; exit 2; }
    if [ "$H_LIVE" != "$H_REC" ]; then
      # ⛔ BYTES THAT ALREADY EQUAL THE SOURCE ARE A DEPLOY, NOT AN EDIT. `PHASE=A` writes $O and, by
      # design, writes NO record, so a partial deploy routinely leaves bytes newer than the record.
      if [ -n "$CSRC" ] && [ -f "$CSRC/$REL" ] && cmp -s "$CSRC/$REL" "$O/$REL"; then
        bad "PENDING   $REL — $O already holds the SOURCE's bytes; the record predates them (an unrecorded or partial deploy, not a hand edit)"
        PEND=$((PEND + 1)); continue
      fi
      EDITS=$((EDITS + 1))
      # ⛔ THREE ANSWERS, NOT TWO. On a filesystem with one-second mtime resolution an edit and the
      # record that describes it routinely land in the SAME second, and `-nt` is then false — calling
      # that "older than the record" would be a fabricated fact about which side changed.
      if [ "$O/$REL" -nt "$REC" ]; then WHEN="edited AFTER the record (its mtime is newer than the record's)"
      elif [ "$O/$REL" -ot "$REC" ]; then WHEN="OLDER than the record — the record was written after this file's last change"
      else WHEN="same timestamp as the record (this filesystem cannot order the two)"; fi
      bad "UNCOMMITTED-EDIT   $REL — the deployed copy differs from the record (live ${H_LIVE:0:12}, recorded ${H_REC:0:12}); $WHEN"
    fi
  done < "$REC"

  # The other direction: a file $O carries that the record never saw (hand-placed, or written by a path
  # that does not record). A plain `check` lists every top-level `*.sh`; with `--src` the list is the
  # FILES THE DEPLOY WOULD WRITE, because those are the ones it OVERWRITES.
  # ⛔ THE `--src` ARM IS NOT OPTIONAL. It used to be skipped on the premise that "the deploy does not
  # delete files" — true, and irrelevant: the deploy does not need to delete a file to destroy it, it
  # only needs to WRITE one of the same name. Measured: a hand-placed `foo.sh` in `$O`, a record written
  # from an older source that never shipped `foo.sh`, and a new source that DOES ship it — `check --src`
  # said clean (0) and `deploy-harness.sh` silently replaced the hand-placed bytes, printing nothing.
  # That is the 2026-10-28 incident one file name over, and the only reason it is not the same file is
  # that the record happened to be written by a source that carried it.
  if [ -z "$SRC" ]; then
    for _f in "$O"/*.sh; do
      [ -f "$_f" ] || continue
      _b="${_f##*/}"
      grep -qxF -- "$_b" <<<"$SEEN" && continue
      # ⛔ AN UNDESCRIBED FILE IS NOT AUTOMATICALLY AN EDIT, and calling it one is a false alarm on
      # the box class this record was built for. `$O` legitimately carries scripts no deploy ships —
      # on a Mac, the whole resolver set (`supervisor.sh`, `disk-reaper.sh`, `pi-cache-reap.sh`, … is
      # the ProgramArguments of an armed schedule and ships from `scripts/`, one directory over), and
      # `deploy_harness` KEEPS them on purpose. With every one of those labelled UNCOMMITTED-EDIT,
      # the documented question ("has anything in $O changed since that deploy?") answered RED on a
      # perfectly healthy box, permanently — the same "go hunt a patch that does not exist" defect
      # this file already fixed for STALE-RECORD and PENDING.
      # The distinction is what a deploy can DESTROY: a deploy writes only what its source ships, so
      # a file the record's own source does not ship cannot be overwritten by any deploy of this tree.
      # It is REPORTER, not counted, and not a finding — while a file the source DOES ship is exactly
      # the `--src` arm's case, and stays a refusal (the gate both deploys call uses --src).
      if [ -n "$CSRC" ] && [ ! -f "$CSRC/$_b" ]; then
        say "PRESENT          $_b — in $O and ABSENT from the record; the record's source ($CSRC) does not ship that name, so no deploy of this tree would overwrite it. Not an edit."
        PRESENT=$((PRESENT + 1)); continue
      fi
      if [ -z "$CSRC" ]; then
        # CANNOT-VERIFY, and it stays a failure: with no source to ask, this file COULD be one a
        # deploy overwrites, and "could be" is not a clean answer here.
        bad "UNSHIPPED-UNKNOWN $_b — in $O and ABSENT from the record, and the record names no source that exists on this box, so whether a deploy would overwrite that name CANNOT be checked"
        UNSHIPPED=$((UNSHIPPED + 1)); EDITS=$((EDITS + 1)); continue
      fi
      bad "UNCOMMITTED-EDIT   $_b — present in $O and ABSENT from the record (hand-placed, or written by a path that does not record), and the record's source ships that name, so a deploy would OVERWRITE it"
      EDITS=$((EDITS + 1))
    done
  else
    # Every file the source ships, at any depth, that already exists in $O under a name the record never
    # saw: the deploy would overwrite it, and $O's bytes are not in the record or anywhere else.
    while IFS= read -r _r; do
      [ -n "$_r" ] || continue
      [ -f "$O/$_r" ] || continue          # absent: the deploy CREATES it, nothing is discarded
      if [ -n "$SKIPS" ] && grep -qxF -- "$_r" <<<"$SKIPS"; then continue; fi
      grep -qxF -- "$_r" <<<"$SEEN" && continue
      bad "UNCOMMITTED-EDIT   $_r — present in $O and ABSENT from the record (hand-placed, or written by a path that does not record), and the source ships this name, so this deploy would OVERWRITE it"
      EDITS=$((EDITS + 1))
    done < "$SRCLIST"
  fi

  # The record must describe its own manifest: a count that does not match the lines below it means
  # the record was truncated, hand-edited, or written by a version this reader does not know — all
  # CANNOT-VERIFY, never "the entries I did read are fine".
  if [ "$NSEEN" -ne "$NMAN" ]; then
    bad "UNKNOWN: the record at $REC says files=$NMAN but carries $NSEEN manifest line(s) — it is truncated or hand-edited, so the entries it does carry cannot be trusted as the whole set"; exit 2
  fi
  if [ "$PEND" -gt 0 ]; then
    say "note: $PEND file(s) at $O already hold the SOURCE's bytes and the record predates them — an unrecorded or partial deploy; a completed deploy records it, nothing of yours is at risk"
  fi
  if [ "$MISS" -gt 0 ]; then
    say "note: $MISS file(s) the record names are ABSENT from $O — a redeploy would create them; that is not a discard, so it is not a refusal"
  fi
  if [ "$PRESENT" -gt 0 ]; then
    say "note: $PRESENT file(s) in $O are carried by the box and NOT shipped by the record's source — no deploy of this tree writes them, so they are reported and not counted as edits"
  fi
  [ "$EDITS" -eq 0 ] || exit 1
  exit 0
  ;;

show)
  if [ ! -e "$REC" ]; then
    bad "UNKNOWN: no provenance record at $REC — this tree has no recorded commit, so 'which commit is this box running?' has no answer"
    exit 2
  fi
  [ -r "$REC" ] || { bad "UNKNOWN: the provenance record at $REC is not readable"; exit 2; }
  COMMIT="$(prov_field "$REC" commit)"
  REF="$(prov_field "$REC" ref)"
  REFCOMMIT="$(prov_field "$REC" refCommit)"
  SRC="$(prov_field "$REC" source)"
  AT="$(prov_field "$REC" recordedAt)"
  N="$(prov_field "$REC" files)"
  [ -n "$COMMIT" ] || COMMIT="UNKNOWN"
  case "$(prov_field "$REC" sourceDirty)" in
    true) printf 'harness commit %s   (SOURCE WAS DIRTY: these bytes are not that commit)   recorded %s   %s file(s)\n' "${COMMIT:0:12}" "${AT:-<none>}" "${N:-0}" ;;
    *)    printf 'harness commit %s   ref %s   recorded %s   %s file(s)\n' "${COMMIT:0:12}" "${REF:-<none>}" "${AT:-<none>}" "${N:-0}" ;;
  esac
  printf '  record: %s\n' "$REC"
  [ -n "$SRC" ] && printf '  source: %s\n' "$SRC"
  [ "$REFCOMMIT" = "UNKNOWN" ] || printf '  ref tip at deploy: %s\n' "${REFCOMMIT:0:12}"
  printf '  is that still the checkout?   bash "%s/check-deployed-drift.sh" --o "%s" --repo <checkout>\n' "$HERE" "$O"
  if [ "$COMMIT" = "UNKNOWN" ]; then
    bad "WARNING — the record says commit=UNKNOWN: this tree was not deployed from a git checkout."
    exit 2
  fi
  exit 0
  ;;

*) usage >&2; exit 78 ;;
esac
