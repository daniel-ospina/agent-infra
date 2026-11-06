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

# _rs_norm_path <path> — the canonical SPELLING of a path, without touching the filesystem:
# repeated separators collapsed, `.` components dropped, trailing `/` removed. It is not a realpath
# (no symlink or `..` resolution — that needs the filesystem, and this must work for a dir that does
# not exist yet), and it does not fold case: the caller composes it with `_rs_lower`.
#
# ⛔ WHY IT IS NEEDED, MEASURED IN REVIEW ROUND 3 (P2): `/srv/state` and `/srv//state` and
# `/srv/./state` are ONE DIRECTORY. The shared-state guard compared raw spellings, so a set that named
# the same state dir two ways returned OK — on exactly the silent-sharing failure the guard exists to
# refuse (two controllers on one `.orch.lock`). The repo already treats this class as real:
# `check-farm-drift.sh` normalises `//` and `.` after a measured incident.
_rs_norm_path() {
  local out="" comp
  while IFS= read -r comp; do
    case "$comp" in ''|.) continue ;; esac
    out="$out/$comp"
  done <<EOF_NORM
$(printf '%s' "${1:-}" | tr '/' '\n')
EOF_NORM
  [ -n "$out" ] || out="/"
  printf '%s' "$out"
}

# _rs_state_key <path> — the IDENTITY of a state dir, for the shared-state refusal. Spelling is not
# identity, and `_rs_norm_path` alone cannot express that: it folds `//`, `.` and a trailing `/`
# WITHOUT touching the filesystem (right for a dir the operator has not created yet), so `..` and a
# SYMLINK survive it — and each of those is ONE DIRECTORY with its target.
#
# ⛔ MEASURED, WITH INODE PROOF (review round 6, P2 — the arm round 3 opened and only half-closed).
# Against this reader before this helper existed, `state=/srv/s` vs `state=/srv/s/sub/..` and
# `state=/srv/s` vs a symlink to it both printed `repo-set: ok` for BOTH entries and exited 0 with
# `repo-set: OK — 2 repo(s)` — while `stat -c '%d:%i'` returned ONE inode for each pair. That is a
# green `check` on precisely the silent-sharing failure this file's own docstring says it refuses:
# two controllers on one `.orch.lock`, one candidates list, one worker registry, each believing it is
# alone on the box. The controls (identical spellings, a trailing `/`) DO refuse, which is what makes
# it a defect rather than a matter of taste — the refusal was satisfiable by a differently-typed path.
#
# So: RESOLVE when the path exists, fall back to the pure-spelling norm when it does not.
#   * `cd -P` collapses `..`, `//`, `.` AND symlinks in one step on macOS and GNU alike — no
#     `readlink -f` (BSD does not have it) and no `stat -f`/`stat -c` flag divergence to get wrong,
#     which is the same portability argument this file already makes for `case` over `[[ =~ ]]`.
#   * the fallback is not an oversight: `check` deliberately does NOT require `state` to exist, and a
#     set whose state dir the operator creates afterwards must not start failing.
#   * case stays the CALLER's fold (`_rs_lower`), because a dir that does not exist cannot be
#     resolved at all — folding after resolution is the only way the APFS arm (m1) survives when the
#     fixture (and a real box) has no such directory yet.
_rs_state_key() {
  local p="${1:-}" resolved=""
  if [ -n "$p" ]; then
    resolved="$( cd -P "$p" 2>/dev/null && pwd -P )"
  fi
  [ -n "$resolved" ] || resolved="$(_rs_norm_path "$p")"
  printf '%s' "$resolved"
}

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

# ⛔ THE PROOF IS DELEGATED, NOT RE-IMPLEMENTED (review round 4, P2). The first version parsed origin
# URLs in bash, and review measured it disagreeing with the doctor IN BOTH DIRECTIONS on the same
# remote: `case "$url" in *github.com[:/]*)` is a SUBSTRING match, so `notgithub.com/o/n` and
# `mirror.github.com/o/n` "proved" a GitHub repo the doctor's `_names_github()` refuses to attest —
# the reader certified a checkout the doctor grades read-only, and (with `notgithub.com/other/repo`)
# REFUSED the whole set on a proof the doctor treats as none. Every extra parsing rule written here is
# another chance to diverge from `resolve_repo()`; the honest fix is to ask the component that owns
# the rule. `pr-doctor.py` sits beside the wrapper in BOTH layouts the farm produces
# (`scripts/pr-doctor.py` and `$DEST/scripts/pr-doctor.py`), so `_rs_doctor_py()` finds it from
# `scripts/lib/` in each.
#
# ⛔ WHAT A FAILURE TO ASK MEANS: nothing is PROVEN. A missing `pr-doctor.py`, a missing `python3`, a
# module that will not load, a checkout this process may not stat, a checkout that is not a directory
# — all of those are "unverifiable", never "wrong", and the caller WARNS on them. Only a slug the
# doctor's own `_origin_slug()` returns can disagree with the declared one, and only that refuses.
_rs_doctor_py() {
  local d="${REPO_SET_DOCTOR:-}"
  if [ -z "$d" ]; then
    d="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)/pr-doctor.py"
  fi
  [ -f "$d" ] || return 0
  printf '%s' "$d"
}

# _rs_with_doctor <verb> <arg> — run ONE question against pr-doctor.py's own functions, so the reader
# and the doctor cannot disagree about a remote or a slug. Prints the answer, or "" when nothing could
# be asked. `verb` is `origin` (_origin_slug) or `norm` (_normalize_slug).
_rs_with_doctor() {
  local verb="${1:-}" arg="${2:-}" doc py
  doc="$(_rs_doctor_py)"
  [ -n "$doc" ] || return 0
  py="$(command -v python3 2>/dev/null)"
  [ -n "$py" ] || return 0
  "$py" - "$doc" "$verb" "$arg" <<'PY_PROOF' 2>/dev/null
import importlib.util, sys
doc, verb, arg = sys.argv[1], sys.argv[2], sys.argv[3]
spec = importlib.util.spec_from_file_location("_prd", doc)
mod = importlib.util.module_from_spec(spec)
try:
    spec.loader.exec_module(mod)
except Exception:
    raise SystemExit(0)
if verb == "norm":
    sys.stdout.write(mod._normalize_slug(arg))
else:
    slug, why = mod._origin_slug(arg)
    sys.stdout.write(("%s\t" % slug) if slug else ("\t%s" % why))
PY_PROOF
}

# _rs_origin_slug <checkout> — the `owner/name` this checkout's `origin` PROVES, or "" and a reason.
# The SAME function `pr-doctor` grades with, so the two verdicts are one verdict.
_rs_origin_slug() {
  local dir="${1:-}" out
  if [ -z "$dir" ]; then printf '\tno checkout was named'; return 0; fi
  out="$(_rs_with_doctor origin "$dir")"
  if [ -z "$out" ] && [ -z "$(_rs_doctor_py)" ]; then
    printf '\tpr-doctor.py was not found beside this reader, so no origin can be proved'
    return 0
  fi
  if [ -z "$out" ]; then
    printf '\tpr-doctor.py could not be asked (no python3, or it would not load)'
    return 0
  fi
  printf '%s' "$out"
}

# _rs_normalize_slug <value> — `owner/name` from anything `_normalize_slug` accepts (a bare slug, a
# `[HOST/]OWNER/REPO`, a URL, `.git`, an scp-style remote), or "" when it names no repo. Delegated for
# the same reason: the DEGRADED path advertises a slug and then the doctor re-resolves it, so a
# stricter parser here refuses values the doctor runs (measured: a `https://github.com/o/n` seam).
_rs_normalize_slug() {
  local v="${1:-}"
  [ -n "$v" ] || return 0
  _rs_with_doctor norm "$v"
  return 0
}

# repo_set_check — the SYNTAX half plus the proofs that make the list trustworthy:
#   * its `origin` PROVES the slug it is declared under — THE ONLY PROOF THAT CAN REFUSE, because the
#     proof is `pr-doctor.py`'s own `_origin_slug()`, delegated rather than re-implemented;
#   * nothing else refuses. Absent, denied, not a directory, no `origin`, no `git`, no `python3`: all
#     UNVERIFIABLE, all a WARN. What the PASS then does is the doctor's to say (it may adopt another
#     checkout for the slug, or grade read-only); this reader states only what it measured. The split
#     is the one `resolve_repo()` makes, and the reason is measured twice over: launchd has no Full Disk Access
#     under `~/Documents` (the default checkout), so refusing there discarded a pass the doctor
#     completes. "I could not look" must never be reported as "it is wrong".
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

    # ⛔ A REFUSAL HERE MUST REST ON A PROOF, NOT ON THIS PROCESS'S ABILITY TO LOOK (review round 3,
    # P1). This used to probe `git -C "$checkout" rev-parse` FIRST and call any failure "not a git work
    # tree" — so on a box where the process cannot even CHDIR into the checkout, `check` refused the
    # whole set and the wrapper exited 2, while the DOCTOR hands the same entry a complete read-only
    # pass ("checkout: NONE … the queue is graded and NOTHING will be spawned"). That is the macOS TCC
    # shape and it is `install-launchd.sh`'s DEFAULT checkout (`~/Documents/GitHub/tortoise`), so the
    # refusal discarded the very pass this file exists to make possible — and it made the WARN arm
    # below unreachable for exactly the case it was written for. Same for a missing `git` and a
    # `dubious ownership` refusal, which are not facts about the checkout.
    #
    # So: PROVEN wrong (absent, or a checkout of a different repo) refuses; UNVERIFIABLE warns and
    # lets the pass grade read-only, which is what the doctor does with the same evidence.
    # ⛔ NOTHING ABOUT THE CHECKOUT'S EXISTENCE REFUSES (review round 4, P1; round 3, P1). Round 3 moved
    # this refusal off `git rev-parse` and onto `test -e` — which is the SAME defect one syscall over:
    # macOS TCC denies at the ANCESTOR (`~/Documents`), so `stat` fails with EACCES, `-e` is false, and
    # the reader printed a false "does not exist" and refused the WHOLE set while the doctor handed the
    # same entry a complete read-only pass. And a sandbox is entitled to answer ENOENT for a denied
    # path, so even an errno-aware test cannot PROVE absence from inside it.
    #
    # THE RULE, THEN, AND IT IS THE WHOLE RULE: only a PROVEN fault refuses. A slug the doctor's own
    # `_origin_slug()` returns that differs from the declared one is proven. Everything else — absent,
    # denied, not a directory, no `origin`, no `git`, no `python3` — is UNVERIFIABLE and warns.
    #
    # ⛔ AND A WARN IS A STATEMENT ABOUT THIS ENTRY'S CHECKOUT, NOT ABOUT THE PASS. The doctor resolves
    # each entry through `_checkout_that_proves()`, which falls back to `REPO` and then the cwd, so it
    # may still find a spawnable checkout for this slug and may grade read-only if it does not. The
    # reader cannot know which; promising "nothing will be spawned" was overreach (review round 5).
    local proof why
    proof="$(_rs_origin_slug "$checkout")"; why="${proof#*$'\t'}"; proof="${proof%%$'\t'*}"
    if [ -n "$proof" ]; then
      if [ "$(_rs_lower "$proof")" != "$(_rs_lower "$slug")" ]; then
        problems="$problems; $checkout is a checkout of $proof, not $slug — refusing to grade a repo the checkout does not prove"
      fi
    else
      # ⛔ THIS WARNS ABOUT *THIS ENTRY'S OWN* CHECKOUT, AND DOES NOT PROMISE THE OUTCOME (review
      # round 5, P2). `run_all_repos()` passes the entry to `resolve_repo()`, whose `_checkout_that_
      # proves()` falls back to `REPO` and then the cwd when the entry's own checkout proves nothing —
      # so the doctor CAN still find a spawnable checkout for this slug, and "nothing will be
      # spawned" was a promise this reader cannot make. What it can state is the fact it measured:
      # THIS checkout proves no repo.
      printf 'repo-set: WARN CHECKOUT-UNVERIFIED — %s: `%s` proves no repo (%s); the doctor may still adopt another checkout for this repo, or grade it read-only\n' "$slug" "$checkout" "$why"
    fi

    if [ -n "$state" ]; then
      # ⛔ CASE-FOLDED LIKE THE SLUG ABOVE (review round 2, P2). On APFS/HFS+ — the macOS default,
      # and the platform this file's bash-3.2 note exists for — `/Users/x/Orchestrator` and
      # `/Users/x/orchestrator` are ONE DIRECTORY, so a byte-exact comparison returned OK on exactly
      # the silent-sharing failure this arm exists to refuse: two controllers on one `.orch.lock`,
      # one candidates list, one worker registry. A case-SENSITIVE filesystem with two state dirs
      # differing only by case now gets a refusal it did not need — loud, renameable, and strictly
      # cheaper than the collision it prevents.
      # ⛔ SPELLING AND CASE BOTH FOLD (round 3, P2). `/srv/state`, `/srv//state` and `/srv/./state`
      # are one directory, so a raw comparison passed the collision this arm refuses; `_rs_norm_path`
      # collapses them without touching the filesystem, and `_rs_lower` covers APFS/HFS+.
      # ⛔ AND SO DO `..` AND SYMLINKS (round 6, P2). Those two are one directory with their target
      # and `_rs_norm_path` cannot see it — it never touches the filesystem — so both passed as `ok`.
      # `_rs_state_key` resolves identity when the path exists and keeps the spelling norm as the
      # not-yet-created fallback; `_rs_lower` still folds on top, which is what keeps the APFS arm
      # working for a directory that does not exist yet.
      local norm_state
      norm_state="$(_rs_lower "$(_rs_state_key "$state")")"
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
