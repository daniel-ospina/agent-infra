#!/usr/bin/env bash
# repo-set.sh — THE machine's repo SET: one file, one reader (agent-infra#2281 §4).
#
# ⛔ THE GAP THIS FILLS. A box that runs SEVERAL repos has no way to say so. `orchestrator-bringup.sh`
# resolves exactly ONE repo per machine (`REPO` + `OR` from the environment or from ONE file,
# `$HOME/.config/orchestrator/bringup.env`), and `--reseed` writes one pair. So every consumer that
# needs "the repos this machine serves" invents its own answer: the doctor's `PR_DOCTOR_REPOS` has
# **no default set at all** — deliberately (agent-infra#2280), because there was no authoritative
# machine list to read — and the shipped `com.tortoise.pr-doctor` unit names ONE repo in argv. On a
# box whose controllers serve tortoise AND agent-infra, the second repo is simply not enumerated by
# anything, so its share of the box's capacity is zero and nothing says so.
#
# The fix this file begins (§4's "suggested order" item 1 — "nothing else can be rendered without
# it") is a machine config that names a SET of repos. §4 wants it to be one list with several
# readers (the controllers, the heartbeat's per-repo dispatch steps, the doctor's set, and the
# launchd/systemd units) and no second copy. This file IS that list's one reader. The readers wired
# to it today and the ones still owed are named in the PR that added it, not left implicit: a list
# nobody reads is the "installed but inert" state this repo keeps paying for.
#
# ⛔ WHAT A READER MUST NOT DO. It must not discover repos (a scan of the filesystem answers with
# whatever checkouts happen to exist — a default by another name, the reasoning `configured_repos()`
# in pr-doctor.py already records), and it must not silently skip a line it cannot parse (a shorter
# set reads exactly like a smaller machine). Syntax and semantic faults are REFUSED by name, with the
# file and line number, so a typo cannot quietly remove a repo from the set.
#
# FILE FORMAT — one repo per line; blank lines and `#` comments ignored; whitespace-separated
# key=value tokens; keys may appear in any order:
#
#     # the two repos this box serves
#     slug=daniel-ospina/tortoise    checkout=/home/cmux/tortoise    state=/home/cmux/orchestrator
#     slug=daniel-ospina/agent-infra checkout=/home/cmux/agent-infra  state=/home/cmux/orchestrator-ai
#
#   slug      REQUIRED  `owner/name`, the identity every consumer keys on.
#   checkout  REQUIRED  absolute path; `check()` proves its `origin` names `slug`.
#   state     OPTIONAL  the per-instance state dir for the CONTROLLER consumers (§2/§4a). The doctor
#                       does not read it: `--all-repos` derives a per-repo register under the fleet
#                       state dir itself (`_state_file()`), and a second authority for that path is
#                       the defect that function removes. It is carried HERE so the field has one
#                       home, and `check()` refuses the silent-sharing failure the controller
#                       launchers already refuse by name: TWO repos sharing one state dir (two
#                       controllers would then fight over one `.orch.lock`, one candidates list and
#                       one worker registry, each believing it is alone on the box). A state dir
#                       that is the PRIMARY controller's is NOT refused — the set names every repo
#                       the box runs, the primary included, and `$HOME/orchestrator` is rightly its.
#   Any other key is REFUSED (`UNKNOWN-KEY`) rather than ignored: `checkuot=` must not silently drop
#   a repo's checkout.
#
# VALUES MAY NOT CONTAIN SPACES OR COMMAS. A path with a space splits into two tokens and the second
# one has no `=`, which is refused as `BAD-TOKEN`. A comma is the separator `doctor-repos` renders
# entries with, so a value carrying one is refused as `SEPARATOR-IN-VALUE` — both loud, which is the
# point: a value that silently changed the SHAPE of the set is how one repo becomes two, or none.
#
# PATH. `$REPO_SET_FILE`, else `$HOME/.config/orchestrator/repos.conf`. `HOME` is the box's real home
# on a Mac and the cell home on a cell (`/tmp/cell-home`), the same root `bringup.env` lives under —
# so one box, one file, and it sits beside the config an operator already knows.
#
# USAGE (executed)
#   repo-set.sh path            # print the file this box would read, existing or not
#   repo-set.sh list            # one `slug<TAB>checkout<TAB>state` line per repo
#   repo-set.sh slugs           # one slug per line
#   repo-set.sh doctor-repos    # the `PR_DOCTOR_REPOS` value: `slug=checkout` joined by `,`
#   repo-set.sh check           # validate; print one line per repo and every refusal
#
# USAGE (sourced)   `. repo-set.sh` gives every function above without running a verb. A consumer
#                   calls `repo_set_parse` (syntax + slug shape) or `repo_set_check` (that, plus the
#                   checkout/state proofs) and acts on the return code — it never re-parses the file.
#
# RETURN CODES — ONE TABLE, AND IT IS THE SAME FOR A VERB AND FOR THE FUNCTION IT CALLS
#   0  OK                the set is well formed (parse) / valid (check)
#   3  NO-REPO-SET       the file does not exist — the box has named no repo. NOT a default.
#   4  NO-ENTRIES        the file exists and names nothing (comments/blank lines only).
#   5  INVALID           the file exists and is not a usable set: unreadable, not a regular file, or
#                        at least one line refused. The reasons are on stderr, by name and line.
#   1  UNPROVEN          (check only) the file parses, but a checkout/state proof failed.
#   2  usage
#
# ⛔ `repo_set_check` PROPAGATES 3/4/5 AND DOES NOT FOLD THEM INTO 1. Folding them inverted the one
# branch that matters for a consumer: "this box names no repo" (degrade / report) would read as "this
# box's file is broken" (refuse) — the two states `NO-REPO-SET` exists to keep apart. 1 is reserved
# for a file that PARSED and whose proofs failed, which is a different fix.
#
# ⛔ THE ABSENT-FILE CODE IS ITS OWN (3) AND IS NOT AN ERROR OF THE FILE. A consumer must be able to
# distinguish "this box names no repo" from "this box names a repo badly": the first is a
# configuration the operator has not made yet (and the doctor's answer is to refuse loudly, which is
# #2280's doctrine), the second is a broken file that must not be half-honoured. A file that EXISTS
# and cannot be read is the SECOND, never the first: telling an operator to create a file that is
# already there sends them at the wrong defect, and degrading on it silently un-serves the second
# repo — the exact failure #2281 exists to close.

# ⛔ NO TOP-LEVEL `set -u`. THIS FILE IS SOURCED — that is its advertised contract (above) — and a
# library that turns on `-u` in its caller's shell changes the caller's semantics: measured in review
# round 2, a consumer that sourced this file died on the ordinary idiom `[ "$UNSET" = "1" ]`. The
# strict flags belong to the EXECUTED path only, and are set at the bottom, immediately before a verb
# runs. Nothing in this file needs `-u`: every expansion is `${x:-}`-guarded.

repo_set_file() {
  printf '%s\n' "${REPO_SET_FILE:-$HOME/.config/orchestrator/repos.conf}"
}

# _rs_say <stream> <text...> — one prefixed line. Kept as one helper so every consumer's output is
# greppable by the single token `repo-set:`.
_rs_say() { local s="$1"; shift; printf '%s\n' "$*" >&"$s"; }

# _rs_lower <s> — the ONE case fold. ⛔ EVERY COMPARISON OF TWO SLUGS GOES THROUGH IT, because the
# consumer this file feeds is case-INSENSITIVE and this file must not disagree with it:
# `resolve_repo()` accepts a case-differing slug (`got.lower() == slug.lower()`), `repo_tag()`
# lowercases the identity with an explicit note that the doctor "already treats the identity as
# case-insensitive (#2980 review cycle 4, P2) … GitHub itself is case-insensitive", and
# `configured_repos()` lowercases its dedupe key. A byte-exact comparison here produced BOTH failures,
# measured in review of this change: (1) a set declaring `Daniel-Ospina/Tortoise` over a checkout whose
# origin spells it lowercase was REFUSED — whole-machine exit 2, with a message asserting two
# spellings of one repo are different repos, while `resolve_repo` accepts the identical pair; and
# (2) two spellings of one slug passed DUPLICATE-SLUG while the doctor deduped them to one entry, so
# the wrapper logged `grading 2 repo(s)` for ONE graded repo — the "a shorter set must not read as a
# smaller machine" failure this file exists to prevent.
_rs_lower() { printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]'; }

# _rs_slug_ok <s> — `owner/name`, and exactly one `/`. `case` rather than `[[ =~ ]]` so this file
# parses under bash 3.2 (macOS) as readily as under bash 5 (cells) — the shard runs the same file on
# both, and a `=~` that only one of them supports is a suite that fails on the box nobody is looking
# at. The OWNER's first character must be alphanumeric, matching `pr-doctor.py`'s `_SLUG_RE`
# (`[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9_.-]+`): that regex refuses a leading `.`/`-`, so accepting one
# here would bless a set the doctor then refuses — a disagreement, even a loud one.
_rs_slug_ok() {
  local s="${1:-}" owner name
  [ -n "$s" ] || return 1
  case "$s" in *' '*) return 1 ;; esac          # a value with a space is two tokens upstream
  case "$s" in *,*) return 1 ;; esac            # a value with a comma splits `doctor-repos` (below)
  case "$s" in */*/*) return 1 ;; esac          # more than one slash is not owner/name
  case "$s" in */*) : ;; *) return 1 ;; esac    # exactly one slash
  owner="${s%%/*}"; name="${s#*/}"
  [ -n "$owner" ] && [ -n "$name" ] || return 1
  case "$owner" in [!A-Za-z0-9]*) return 1 ;; esac
  case "$owner$name" in *[!A-Za-z0-9._-]*) return 1 ;; esac
  return 0
}

# repo_set_parse — the SYNTAX half. Emits `slug<TAB>checkout<TAB>state`, or nothing and a refusal.
repo_set_parse() {
  local f; f="$(repo_set_file)"
  if [ ! -e "$f" ]; then
    _rs_say 2 "repo-set: NO-REPO-SET — $f does not exist, so this machine has named no repo."
    _rs_say 2 "repo-set:   Create it, one repo per line:"
    _rs_say 2 "repo-set:     slug=OWNER/NAME checkout=/abs/checkout [state=/abs/state-dir]"
    return 3
  fi
  # ⛔ `-e` IS TESTED FIRST. The absent arm used `[ ! -f ]`, so a DIRECTORY at the config path read as
  # "this box names no repo" (code 3) and the wrapper DEGRADED on it — while telling the operator the
  # path "does not exist", which it plainly does. An existing thing that is not a usable file is the
  # broken-file state (5), never the absent one (3).
  if [ ! -f "$f" ]; then
    _rs_say 2 "repo-set: INVALID — $f exists but is not a regular file (a directory at the config path cannot name repos)."
    return 5
  fi
  if [ ! -r "$f" ]; then
    _rs_say 2 "repo-set: INVALID — $f exists but is not readable by $(id -un 2>/dev/null || echo this user)."
    _rs_say 2 "repo-set:   A file that EXISTS and cannot be read is a BROKEN set, not an absent one: this box"
    _rs_say 2 "repo-set:   has named repos and nothing can grade them. Fix that file's mode/ownership;"
    _rs_say 2 "repo-set:   telling the operator to create it would send them at the wrong defect."
    return 5
  fi

  local rc=0 n=0 line tok key val ln=0
  local slug="" checkout="" state=""
  local seen=""           # newline-delimited slugs already taken (no associative arrays on bash 3.2)
  local -a out=()

  while IFS= read -r line || [ -n "$line" ]; do
    ln=$(( ln + 1 ))
    line="${line%$'\r'}"
    # Leading/trailing whitespace, then blank/comment.
    line="$(printf '%s' "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    case "$line" in ''|'#'*) continue ;; esac

    slug=""; checkout=""; state=""
    local line_bad=0
    local IFS=$' \t'
    for tok in $line; do
      case "$tok" in
        *=*) : ;;
        *) _rs_say 2 "repo-set: BAD-TOKEN — $f:$ln: \`$tok\` is not key=value (a value with a space splits here)"; line_bad=1; continue ;;
      esac
      key="${tok%%=*}"; val="${tok#*=}"
      case "$key" in
        slug)     [ -z "$slug" ]     || { _rs_say 2 "repo-set: DUPLICATE-KEY — $f:$ln: slug= given twice"; line_bad=1; }; slug="$val" ;;
        checkout) [ -z "$checkout" ] || { _rs_say 2 "repo-set: DUPLICATE-KEY — $f:$ln: checkout= given twice"; line_bad=1; }; checkout="$val" ;;
        state)    [ -z "$state" ]    || { _rs_say 2 "repo-set: DUPLICATE-KEY — $f:$ln: state= given twice"; line_bad=1; }; state="$val" ;;
        *) _rs_say 2 "repo-set: UNKNOWN-KEY — $f:$ln: \`$key=\` is not a key this set has (slug, checkout, state)"; line_bad=1 ;;
      esac
    done
    unset IFS

    if [ "$line_bad" = 1 ]; then rc=5; continue; fi

    if [ -z "$slug" ]; then
      _rs_say 2 "repo-set: MISSING-SLUG — $f:$ln: every line must name the repo it is about"; rc=5; continue
    fi
    if ! _rs_slug_ok "$slug"; then
      _rs_say 2 "repo-set: BAD-SLUG — $f:$ln: \`$slug\` is not owner/name"; rc=5; continue
    fi
    # ⛔ THE KEY IS CASE-FOLDED. `configured_repos()` lowercases its dedupe key and `repo_tag()`
    # lowercases the state file, so two spellings of one repo are ONE repo to the doctor — a reader
    # that called them two would render a set the doctor silently shrinks.
    case "$seen" in
      *$'\n'"$(_rs_lower "$slug")"$'\n'*)
        _rs_say 2 "repo-set: DUPLICATE-SLUG — $f:$ln: \`$slug\` is already named above; a set with the same repo twice grades it twice and dispatches it twice (case-INSENSITIVE, like the doctor's own dedupe)"
        rc=5; continue ;;
    esac
    seen="$seen"$'\n'"$(_rs_lower "$slug")"$'\n'

    if [ -z "$checkout" ]; then
      _rs_say 2 "repo-set: MISSING-CHECKOUT — $f:$ln: \`$slug\` names no checkout, so nothing can be spawned for it (its queue could only be graded read-only)"
      rc=5; continue
    fi
    # ⛔ A COMMA IS A SEPARATOR IN THE VALUE THIS FILE RENDERS, SO IT CANNOT APPEAR IN A VALUE.
    # `repo_set_doctor_repos` joins entries with `,` and `configured_repos()` splits on `[,\s]+`, so a
    # checkout path carrying one truncated the real checkout AND invented a phantom repo — measured in
    # review of this change: a ONE-repo set rendered two entries, the second named `po`. A space is
    # refused upstream as BAD-TOKEN; this is the same rule for the other separator.
    case "$checkout$state" in
      *,*) _rs_say 2 "repo-set: SEPARATOR-IN-VALUE — $f:$ln: a value contains a comma; \`,\` separates entries in the list this reader renders, so it cannot appear inside one"; rc=5; continue ;;
    esac
    case "$checkout" in
      /*) : ;;
      *) _rs_say 2 "repo-set: RELATIVE-CHECKOUT — $f:$ln: \`$checkout\` is not absolute; a relative path is resolved against whatever cwd the reader happens to have"; rc=5; continue ;;
    esac
    if [ -n "$state" ]; then
      case "$state" in
        /*) : ;;
        *) _rs_say 2 "repo-set: RELATIVE-STATE — $f:$ln: \`$state\` is not absolute"; rc=5; continue ;;
      esac
    fi

    n=$(( n + 1 ))
    out[${#out[@]}]="$slug"$'\t'"$checkout"$'\t'"$state"
  done < "$f"

  if [ "$rc" != 0 ]; then
    _rs_say 2 "repo-set: REFUSING $f — $rc is not a usable set until the lines above are fixed"
    return "$rc"
  fi
  if [ "$n" -eq 0 ]; then
    _rs_say 2 "repo-set: NO-ENTRIES — $f exists and names no repo (comments and blank lines only)"
    return 4
  fi

  local i=0
  while [ "$i" -lt "${#out[@]}" ]; do printf '%s\n' "${out[$i]}"; i=$(( i + 1 )); done
  return 0
}

# _rs_origin_slug <checkout> — the `owner/name` this checkout's `origin` PROVES, or "" and a reason.
# One parser, same shapes pr-doctor.py's `_origin_slug()` accepts, and the CALLER compares it through
# `_rs_lower()` like the doctor's `resolve_repo()` does — so the set's verdict and the doctor's verdict
# about the same checkout cannot disagree, in either direction.
_rs_origin_slug() {
  local dir="${1:-}" url=""
  command -v git >/dev/null 2>&1 || { printf '\tgit is not on PATH'; return 0; }
  url="$(git -C "$dir" config --get remote.origin.url 2>/dev/null)" || url=""
  [ -n "$url" ] || { printf '\tno remote.origin.url'; return 0; }
  case "$url" in
    *github.com[:/]*)
      local tail="${url#*github.com}"; tail="${tail#:}"; tail="${tail#/}"; tail="${tail%.git}"
      if _rs_slug_ok "$tail"; then printf '%s\t' "$tail"; return 0; fi
      printf '\torigin url is not owner/name: %s' "$url"; return 0 ;;
  esac
  printf '\torigin does not name github.com: %s' "$url"
  return 0
}

# repo_set_check — the SYNTAX half plus the proofs that make the list trustworthy:
#   * every checkout exists and is a git work tree;
#   * its `origin` PROVES the slug it is declared under (a PROVEN disagreement refuses; an UNREADABLE
#     origin only warns — the same split pr-doctor.py's `resolve_repo()` makes, because launchd has no
#     Full Disk Access under ~/Documents and refusing there would refuse every real multi-repo box);
#   * no two repos share a state dir — the silent-sharing failure `multi-repo-controller.sh` refuses
#     by name, one level up: two controllers pointed at one state dir fight over ONE `.orch.lock`,
#     ONE candidates list and ONE worker registry, so each believes it is alone on the box.
#
# ⛔ NOT REFUSED: a state dir that is the PRIMARY controller's. ⛔ It was, in the first draft of this
# file, and the arm was wrong: the set describes EVERY repo the box runs, the primary included, and
# `$HOME/orchestrator` is legitimately the primary's. Refusing it would make the primary's own entry
# impossible to declare — a false block on the one line every box needs. The real defect is two
# entries claiming the SAME dir, and that is the arm above.
repo_set_check() {
  local parsed rc
  parsed="$(repo_set_parse)"; rc=$?
  # ⛔ PROPAGATE 3/4/5, never fold them into 1 (see RETURN CODES): a consumer must be able to tell a
  # box that names no repo (degrade / report) from one whose file is broken (refuse).
  if [ "$rc" != 0 ]; then return "$rc"; fi

  local f; f="$(repo_set_file)"
  local bad=0 n=0 slug checkout state seen_states=""

  printf 'repo-set: %s\n' "$f"
  while IFS=$'\t' read -r slug checkout state; do
    [ -n "${slug:-}" ] || continue
    n=$(( n + 1 ))
    local problems=""

    if [ ! -d "$checkout" ]; then
      problems="$problems; $checkout does not exist"
    elif ! git -C "$checkout" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      problems="$problems; $checkout is not a git work tree"
    else
      local proof why
      proof="$(_rs_origin_slug "$checkout")"; why="${proof#*$'\t'}"; proof="${proof%%$'\t'*}"
      if [ -n "$proof" ]; then
        if [ "$(_rs_lower "$proof")" != "$(_rs_lower "$slug")" ]; then
          problems="$problems; $checkout is a checkout of $proof, not $slug — refusing to grade a repo the checkout does not prove"
        fi
      else
        printf 'repo-set: WARN CHECKOUT-UNVERIFIED — %s: `%s` proves no repo (%s); its queue will be graded read-only\n' "$slug" "$checkout" "$why"
      fi
    fi

    if [ -n "$state" ]; then
      # ⛔ CASE-FOLDED LIKE THE SLUG ABOVE (review round 2, P2). On APFS/HFS+ — the macOS default,
      # and the platform this file's bash-3.2 note exists for — `/Users/x/Orchestrator` and
      # `/Users/x/orchestrator` are ONE DIRECTORY, so a byte-exact comparison returned OK on exactly
      # the silent-sharing failure this arm exists to refuse: two controllers on one `.orch.lock`,
      # one candidates list, one worker registry. A case-SENSITIVE filesystem with two state dirs
      # differing only by case now gets a refusal it did not need — loud, renameable, and strictly
      # cheaper than the collision it prevents.
      local norm_state
      norm_state="$(_rs_lower "$(printf '%s' "$state" | sed 's:/*$::')")"
      case "$seen_states" in
        *$'\n'"$norm_state"$'\n'*)
          problems="$problems; state=$state is shared with another repo in this set — the same silent-sharing failure two controllers would hit" ;;
      esac
      seen_states="$seen_states"$'\n'"$norm_state"$'\n'
    fi

    if [ -n "$problems" ]; then
      printf 'repo-set: REFUSED %s —%s\n' "$slug" "$problems"
      bad=1
    else
      printf 'repo-set: ok %s -> %s%s\n' "$slug" "$checkout" "${state:+ (state $state)}"
    fi
  done <<EOF
$parsed
EOF

  if [ "$bad" != 0 ]; then
    printf 'repo-set: REFUSING — %d repo(s) named, at least one refused above\n' "$n"
    return 1
  fi
  printf 'repo-set: OK — %d repo(s)\n' "$n"
  return 0
}

# repo_set_slugs / repo_set_doctor_repos are DERIVED from `repo_set_parse`, never re-parsed: a second
# parser is how a set that validates one way renders another (the two-authorities defect).
repo_set_slugs() {
  local parsed rc
  parsed="$(repo_set_parse)"; rc=$?
  [ "$rc" = 0 ] || return "$rc"
  printf '%s\n' "$parsed" | awk -F'\t' 'NF{print $1}'
}

repo_set_doctor_repos() {
  local parsed rc
  parsed="$(repo_set_parse)"; rc=$?
  [ "$rc" = 0 ] || return "$rc"
  # `slug=checkout`, comma-joined — exactly the entry form `configured_repos()` accepts, including the
  # `=<checkout>` half that lets one machine grade repos that do not share a `REPO` checkout. ⛔ A
  # comma INSIDE a value would be read as an entry boundary by that splitter, which is why
  # `repo_set_parse` refuses one (`SEPARATOR-IN-VALUE`) rather than rendering a shape it cannot
  # guarantee.
  printf '%s\n' "$parsed" | awk -F'\t' 'NF{ if (out != "") out = out ","; out = out $1 "=" $2 } END { printf "%s", out }'
  printf '\n'
}

# ── verbs ────────────────────────────────────────────────────────────────────────────────────────
_rs_main() {
  local verb="${1:-}"
  case "$verb" in
    path)         repo_set_file ;;
    list)         repo_set_parse ;;
    slugs)        repo_set_slugs ;;
    doctor-repos) repo_set_doctor_repos ;;
    check)        repo_set_check ;;
    ''|-h|--help|help)
      sed -n '/^# USAGE (executed)/,/^# RETURN CODES/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      [ -n "$verb" ] || return 2 ;;
    *)
      _rs_say 2 "repo-set: unknown verb \`$verb\` (path|list|slugs|doctor-repos|check)"
      return 2 ;;
  esac
}

# Sourced ⇒ functions only; executed ⇒ one verb. `BASH_SOURCE[0]` != `$0` when sourced.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  set -uo pipefail
  _rs_main "$@"
  exit $?
fi
