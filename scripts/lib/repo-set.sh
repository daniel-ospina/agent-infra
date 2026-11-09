#!/usr/bin/env bash
# repo-set.sh — THE machine's repo SET: one file, one reader (agent-infra#2281 §4).
#
# ⛔ THE GAP THIS FILLS. A box that runs SEVERAL repos has no way to say so. `orchestrator-bringup.sh`
# resolves exactly ONE repo per machine (`REPO` + `OR` from the environment or from ONE file,
# `$HOME/.config/orchestrator/bringup.env`), and `--reseed` writes one pair. So every consumer that
# needs "the repos this machine serves" invents its own answer: the doctor's `PR_DOCTOR_REPOS` has
# **no default set at all** — deliberately (agent-infra#2280), because there was no authoritative
# machine list to read — and the `com.tortoise.pr-doctor` unit NAMED ONE REPO IN ARGV, as it shipped
# before this change (it names none now, which is exactly what this file makes possible). On a
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
# ⛔ THE SECOND SEAM IS `$REPO_SET_DOCTOR`, AND IT IS A TEST INJECTION POINT, NOT AN OPERATOR KNOB
# (review round 40, P2 — it was undocumented, so nothing in this file said it existed). It names the
# `pr-doctor.py` that `_rs_doctor_py()` asks the delegated proofs of, overriding the sibling that sits
# beside this reader. The suite uses it to point at MUTATED doctors; that is what it is for.
# ⛔ WHAT SETTING IT COSTS — stated here because the cost is the surprise: every whole-set proof (the
# `configured_repos()` splitter round-trip and `set_tag_collisions`) is DELEGATED, so a seam naming a
# file that does not exist makes both UNASKABLE, and unaskable is a WARN by this file's own doctrine
# (nothing is PROVEN, but nothing is WRONG either) — so a set the real doctor beside the wrapper would
# REFUSE can come back `OK` on the WARN path. An operator who sets this to a typo therefore downgrades
# two whole-set refusals to warnings. ⛔ THAT IS NOT A BUG TO PATCH BY REFUSING: turning unaskable into
# a refusal would reverse the round-4 decision that a missing sibling/`python3` must never block a box
# that carries this file without the doctor. The honest defence is to name the CAUSE — the WARN below
# says `REPO_SET_DOCTOR names no file` when the seam is what made the proofs unaskable, so an operator
# is not sent to look for a sibling that is present — and to leave this seam undocumented as a way to
# change what gets graded, because it is not one.
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
#   1  UNPROVEN          (check only) the file parses, but a proof failed: a checkout of a DIFFERENT
#                        repo, two repos sharing a state dir, a set the doctor's own splitter would
#                        divide differently from the lines named, or a set whose repo TAGS collide
#                        (`set_tag_collisions`: two slugs rendering one register). The last two refuse
#                        the SET rather than a line, and say so.
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
  # ⛔ `${HOME:-}` — THE GUARD THE HEADER PROMISES (round 32, P2). It was the ONE unguarded expansion
  # in this file, and it broke the file's own contract: "every expansion is `${x:-}`-guarded". Measured
  # with `env -u HOME`: `path` died with `HOME: unbound variable` (rc 1), and `check` — because the
  # kill happens inside the `$(repo_set_file)` SUBSHELL — survived with an EMPTY path and reported
  # `NO-REPO-SET —  does not exist`, i.e. code 3, which is exactly the code the wrapper DEGRADES on. A
  # box that names two repos would grade one and be told to create a file at an empty path; 5 (broken)
  # is the honest class, and `repo_set_parse` now returns it for "no home to resolve".
  printf '%s\n' "${REPO_SET_FILE:-${HOME:-}/.config/orchestrator/repos.conf}"
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

# _rs_nearest_existing_ancestor <path> — the first path component that EXISTS, walking up from the
# given path's directory. It always answers: an existing ancestor, or `/` (which exists) — the "" case in
# the first version of this line was unreachable, a reviewer found it, and the caller's `-e` on `/` is the
# only fallback that is not a silent proof of absence. It is the whole basis of the
# absence proof above: `-e` false under a TRAVERSABLE existing ancestor is proof of absence, and under
# an untraversable one it is proof of nothing.
# ⛔ NO `dirname` IN THIS WALK, AND IT IS NOT AN OPTIMISATION (review round 44, P2 — measured). In the
# ANCESTOR WALK `dirname` was the last unguarded external, and its absence silently DISARMED the absence
# proof: with it failing, the walk never ran, the function answered `/` (traversable), and a set that
# EXISTS behind an untraversable ancestor was reported `NO-REPO-SET … does not exist` at code **3** — the
# one code the wrapper DEGRADES on, so the box then graded one repo instead of refusing. Measured with the
# interpreter candidates rewritten the way `f48` does it: `dirname` present → rc 5 INVALID; absent → rc 3
# with `Create it, one repo per line` for a file that is already there. Bash's `${var%/*}` gives the same
# parent with no process and no dependency, so there is nothing to guard and no new refusal to invent.
# ⛔ …BUT ONLY WITH THE SLASH-LESS CASE HANDLED: `${d%/*}` on a name with no `/` returns it UNCHANGED,
# which is a loop that never advances. That is exactly what the first cut of this function did, and it
# HUNG on a relative `$REPO_SET_FILE` until a reviewer measured it. The `case` arms below are the fix and
# `j16g`/`j16h` are the arms; see the note inside the function.
# ⛔ SCOPED TO THE WALK, BECAUSE ONE MORE `dirname` SURVIVES IN THIS FILE AND I OVERCLAIMED IT ONCE (this
# comment first said it was "the ONE remaining unguarded external in this reader" — falsified by
# `_rs_doctor_py`, which still uses it). That one is DELIBERATE and stays: it runs inside
# `$(cd … 2>/dev/null && pwd)`, and a failure yields an empty doctor path — "could not ask", which the
# reader WARNS on — never a false proof. `dirname` failing on the walk was different in kind: the walk's
# caller reads a fallback (`/`) as an ANSWER, so the failure became a verdict.
_rs_nearest_existing_ancestor() {
  local d="${1:-}"
  # Strip trailing slashes so `/a/b/` and `/a/b` walk the same parents.
  while [ "${d%/}" != "$d" ] && [ -n "$d" ]; do d="${d%/}"; done
  # ⛔ A SLASH-LESS NAME HAS NO PARENT, AND `${d%/*}` SAYS SO BY RETURNING IT UNCHANGED (review-instrumented
  # round 44 — this was a REGRESSION I introduced, caught by measurement, not by the arm count: every one
  # of the arms that existed then passed an absolute path, so all of them stayed green). The
  # first cut did `d="${d%/*}"` and `${d%/*}` on `repo.conf` yields `repo.conf`; the loop then re-tested the
  # SAME string forever, so a RELATIVE `$REPO_SET_FILE` HUNG the reader — `REPO_SET_FILE=repo.conf` gave
  # rc 124 with no output, where HEAD's `dirname` answered `.` and the loop exited to rc 3 NO-REPO-SET.
  # No arm used a relative set path, so nothing reddened. `dirname X` answers `.` for a slash-less X, and
  # that is what these two `case` arms reproduce; the `*) break` also makes termination STRUCTURAL — every
  # iteration either shortens `d` (it contains a slash) or leaves the loop.
  case "$d" in */*) d="${d%/*}" ;; *) d="." ;; esac
  # ⛔ AN UNRESOLVABLE SYMLINK COMPONENT IS *EXISTING*, NOT ABSENT (round 46, P2 — measured). `[ -e ]`
  # FOLLOWS the link, so a component that is a symlink whose target cannot be resolved here answers FALSE
  # and the walk SKIPS it, returning a traversable grandparent above the link. The caller then reads a
  # traversable ancestor as proof of absence and answers code 3 for a set that EXISTS — the same
  # degrade-code failure this whole function was rewritten to remove, reached by a different route. The
  # shape is reachable without any exotic setup: a set path that goes THROUGH a link into `~/Documents`
  # on a Mac with no Full Disk Access (the `-L` arm documents those users), on a box whose interpreter
  # resolves but cannot execute, so `_rs_stat_kind` answers `unknown` and no errno ever arrives to name the
  # denial. `[ -L ]` is true for an existing link REGARDLESS of its target, so the link becomes the nearest
  # existing component and the caller REFUSES it as a broken state (5) instead of proving absence through
  # what it could not resolve. This function's job is to stop the walk from answering `-e`-false with a
  # traversable grandparent; what the caller does with the link is the caller's business, stated there.
  # ⛔ AND THE CALLER NOW REFUSES IT ON BOTH ROUTES (round 48 review, P2 — this note used to say the refusal
  # was the `unknown` path only, "because a DANGLING link is `absent`, whose 3 is correct"). THE STAT ANSWER
  # DOES NOT DECIDE THE VERDICT ANY MORE: a shape whose chain holds a link that cannot be resolved is
  # refused 5 before the absence test can see it. ⛔ BUT IT IS NOT ALWAYS THIS ARM THAT REFUSES IT (round 48
  # review, P3 — measured, and this sentence used to claim the opposite): a link LOOP answers
  # `other` at `_rs_stat_kind`, and `denied|other` returns 5 from the ERRNO arm, which runs EARLIER — so the
  # loop's 5 has the same verdict through a different arm. ⛔ AND THIS ARM'S SCOPE IS NARROWER THAN "EVERY
  # `absent` ROUTE" (round 48 cycle 4, P2 — measured, and the line below over-generalised): it is the refusal
  # route for an `absent`-with-errno spelling whose LEAF is below the link (`<a dangling link>/repos.conf`)
  # and for `unknown`. A dangling link spelled with a TRAILING SLASH is `absent` as well, but it is refused
  # EARLIER, by `repo_set_parse`'s stripped-spelling arm — measured: `dang/` on a dangling link answers 5
  # quoting "the spelling without its trailing slash is a symbolic link", NOT this arm's "nearest existing
  # component". Measured: every unresolvable-link spelling answers 5 on both
  # readers whatever the arm, and the rc-3 set is IDENTICAL between them and contains no UNRESOLVABLE link.
  # ⛔ AND IT MUST NOT OVERCLAIM THE OTHER WAY EITHER: rc 3 IS right for a spelling that traverses a link
  # which RESOLVES, because then only the remainder is absent (`<a good link>/nope.conf` → 3). No COUNTS are
  # quoted here on purpose — three independently built generators produced three different totals, so an
  # integer would be a claim a reader cannot re-verify; the invariant is what matters, and it survived all
  # three.
  # The old sentence was falsified by that arm and would teach the next lane to restore the 3.
  # A link that DOES resolve is still found by `-e` first, so the ordinary walk is untouched.
  while [ -n "$d" ] && [ "$d" != "/" ] && [ "$d" != "." ]; do
    if [ -e "$d" ] || [ -L "$d" ]; then printf '%s' "$d"; return 0; fi
    case "$d" in */*) d="${d%/*}" ;; *) break ;; esac
  done
  [ -e / ] && { printf '/'; return 0; }
  return 0
}

# _rs_py_resolve — the interpreter, resolved the same way the wrapper resolves it (`command -v python3`,
# then the two absolute paths launchd needs when it has no PATH of its own). ⛔ ONE HOME FOR THAT ORDER
# IN THIS FILE, and its callers are enumerated by `grep -n '_rs_py_resolve' <this file>` — NOT by a count
# in this sentence (round 15, P2: `_rs_with_doctor` carried its own loop; round 16, P2: this line then
# named two and omitted `_rs_stat_kind`; round 46, P2: it said "THREE callers" and `_rs_origin_slug` made
# it four). A list of the file's own call sites is exactly the thing that goes stale — same lesson as the
# `_rs_bound` header.
# ⛔ THE WRAPPER CARRIES THE SAME ORDER IN ITS OWN LINES, AND THAT IS AN ORDERING FACT, NOT A SECOND
# AUTHORITY. `scripts/pr-doctor-machine.sh` resolves `$PY` BEFORE it sources this file — it has to,
# because it refuses with its own message when no interpreter resolves, and it must do that before
# anything from here exists in its shell. So it cannot call this function at that point, and it resolves
# the same three candidates in the same order in its own loop. After the source it never needs to: every
# interpreter it wants is resolved by this one function, through `_rs_doctor_available`,
# `_rs_with_doctor` or `_rs_stat_kind` (round 19, P2: this line named only the first two and so
# contradicted the count the header used to carry; round 46, P2: that count said "THREE", the header is a
# grep recipe now, and these are the three the AUTHORITY claim rests on — `_rs_origin_slug` is the fourth
# caller and is NOT part of it, because it does not resolve the interpreter FOR anything: it renders the
# residue that says the proof returned nothing).
# ⛔ NO LINE NUMBERS IN THIS PARAGRAPH, DELIBERATELY (round 19, P2). It used to say "the loop is at
# `:95-103`, the source is `:119`" — and those numbers were wrong twice in two rounds, once because the
# wrapper moved and once because THIS PR added comment lines above them. A citation that goes stale
# when an unrelated edit lands above it is not evidence. The authority is the code, found by NAME:
# `grep -n '\. "$READER"' scripts/pr-doctor-machine.sh` (the source) and the `PY=` resolution above it.
# (That grep is written so it RUNS: an earlier version of this very sentence double-escaped it, so the
# "authority" returned nothing and a reader would have concluded the wrapper does NOT source the reader.)
# ⛔ AND THE WRAPPER SOURCES THIS FILE, DELIBERATELY — because it needs the reader's FUNCTIONS AND
# THEIR VALUES (the set path, the rendered entry list, the trim, the origin proof, the slug
# normalisation), not merely a verdict. ⛔ AND THE LIST IS DELIBERATELY NOT ENUMERATED HERE: an earlier
# revision named them and included one the wrapper never calls (`_rs_slug_ok`, whose verdict reaches it
# only inside `repo_set_parse`) — the fifth comment in this PR to describe code that is not there. The
# authority is `grep -n '\. "$READER"' scripts/pr-doctor-machine.sh` plus the calls that follow it,
# never a prose list.  ⛔ NOT because a subprocess would lose the exit code: the
# executed path returns `repo_set_check`'s code verbatim, so `bash "$READER" check` answers 3/4/5 for
# absent/empty/malformed exactly as the sourced form does (measured, and pinned by this suite's own
# `run_reader_rc`, which IS that subprocess). A comment claiming otherwise — in either file — describes
# behaviour that is not there, and this PR has had to delete four of those.
_rs_py_resolve() {
  local c
  for c in python3 /usr/bin/python3 /usr/local/bin/python3; do
    if command -v "$c" >/dev/null 2>&1; then command -v "$c"; return 0; fi
  done
  return 0
}

# _rs_doctor_available — can the sibling `pr-doctor.py` be asked at all? The delegated proofs need BOTH
# the file and an interpreter, and "could not ask" must never be read as "the proof held".
_rs_doctor_available() {
  [ -n "$(_rs_doctor_py)" ] || return 1
  [ -n "$(_rs_py_resolve)" ] || return 1
  return 0
}

# _rs_stat_kind <path> — `present` | `absent` | `denied` | `notdir` | `other` | `unknown`.
# ⛔ `notdir` IS ITS OWN ANSWER AND THE ENUMERATION ABOVE IS THE CONTRACT (review round 44, P2): it was
# added for `ENOTDIR` (a path component is a FILE) and left out of this line, which is the drift this file
# keeps recording. `unknown` means the stat call produced NO USABLE ANSWER — no interpreter, an
# interpreter that cannot execute, a NON-ZERO STATUS (whatever it printed), or a payload outside the six
# values below. The last was reachable: a `python3` that runs and prints junk exited 0 and this function
# answered the junk (round 46, P3 — measured with a shim printing `warning: shim deprecated`, which came
# back as the "kind"). So the answer is VALIDATED against the enumeration rather than assumed: the enum
# above is the contract, and a contract nothing checks is a comment.
# ⛔ AN EMPTY ANSWER WAS THE SAME CLASS AND IS NORMALISED TOO (round 46, P3 — measured): a `python3` that
# EXECUTES and prints nothing with status 0 answered the EMPTY STRING. No verdict changed — every caller
# treats `unknown` as "no kind" and an empty answer fell through identically — which is why nothing
# reddened; `j16o` and `j16p` are the arms that check the contract now.
#
# ⛔ `[ ! -e ]` DOES NOT MEAN "ABSENT", AND THE ANCESTOR WALK ALONE CANNOT TELL (review round 11, P2).
# `-e` is false for EVERY stat failure, and absence (ENOENT) is only one of them — so what follows is
# EXAMPLES, not an enumeration, and a new errno does not make it false: EACCES/EPERM (a denial — TCC
# denies at an ancestor while that ancestor's MODE still reads traversable, which is exactly how the walk
# above gets it wrong), ENOTDIR (a path component is a FILE — the `notdir` kind above, and the sharpest
# demonstration that `-e` false is not absence), ENAMETOOLONG, EIO. A denial read as absence means the box
# DEGRADES on a set that exists and is told to create it — the round-9 P2 this arm keeps trying to close,
# surviving one errno over.
# Bash cannot see the errno; python can, and the same interpreter is already resolved for the doctor.
#
# ⛔ THE STAT PAYLOAD'S HEREDOC LIVES IN A FUNCTION BODY, BECAUSE THE CAPTURE BELOW PUTS IT INSIDE `$( )`.
# ⛔ AND THE PRECISE bash-3.2 BEHAVIOUR, MEASURED WITH 3.2.57 (the version macOS ships as /bin/bash, which the
# launchd unit runs, and what `bash32-parse` checks): a heredoc inside a command substitution PARSES while its
# body is quote/backtick/paren balanced — this one is, so the wrapped form would pass the gate today — and an
# unbalanced quote in that body DESYNCHRONISES the parse state for the REST OF THE FILE. The proof child's
# `PY_PROOF` hit exactly that; the measured message and its distance are quoted ONCE, in the note above
# `_rs_proof_child`, so this paragraph cannot drift from it. `scripts/check-bash32-parse.sh` states both
# halves in its own header. So the body stays
# out of the substitution: adding one apostrophe to the Python below must not be able to break the file
# elsewhere, and the capture then only ever sees a plain call.
_rs_stat_kind_child() { PYTHONUTF8=1 "$1" - "$2" <<'PY_STAT' 2>/dev/null
import os, sys
try:
    os.stat(sys.argv[1])
except FileNotFoundError:
    print("absent")
except PermissionError:
    print("denied")
except NotADirectoryError:
    print("notdir")
except OSError:
    print("other")
else:
    print("present")
PY_STAT
}
_rs_stat_kind() {
  local p="${1:-}" py k
  py="$(_rs_py_resolve)"
  [ -n "$py" ] || { printf 'unknown'; return 0; }
  # ⛔ UTF-8 MODE HERE IS SYMMETRY, NOT A MEASURED FIX — said plainly because the first version of this
  # comment claimed one and was FALSIFIED (round 41). It said a non-ASCII path "decodes to surrogate
  # escapes that `os.stat` cannot open at all". Measured on this very heredoc: it opens fine. CPython's
  # `fsencode` re-encodes surrogate escapes back to the original bytes, so `os.stat` round-trips and only
  # STRING-SEMANTIC operations break — which is why the proof runner next door genuinely needed the
  # prefix (`str.strip`/`re.split` see an NBSP as a non-space and the guards become no-ops) and this one
  # does not. The prefix stays because the heredoc is where a path comparison would one day be added, and
  # a locale-dependent STRING compare there would fail silently as `unknown`.
  k="$(_rs_stat_kind_child "$py" "$p")" || k=unknown
  # ⛔ THE CONTRACT IS ENFORCED HERE, NOT MERELY DOCUMENTED (round 46, P3 — measured): an empty answer and a
  # non-empty answer outside the six are the same defect — a `python3` that runs and prints junk exits 0 and
  # would otherwise be returned as the kind, and no arm asserting the six values exists to catch it.
  case "$k" in
    present|absent|denied|notdir|other|unknown) ;;
    *) k=unknown ;;
  esac
  printf '%s' "$k"
}

# _rs_norm_path <path> — the canonical SPELLING of a path, without touching the filesystem:
# repeated separators collapsed, `.` components dropped, trailing `/` removed. It is not a realpath
# (no symlink or `..` resolution), and it does not fold case.
#
# ⛔ THIS IS LOAD-BEARING — IT IS THE STATE ARM'S SPELLING AXIS (round 10). Round 9's note in this
# spot said it was "no longer on the shipped path"; that was true when written and became FALSE when
# the shared-state guard grew a second axis. `repo_set_check` calls it for the SPELLING check, so two
# state dirs identical after folding `//`, `.`, a trailing `/` (and case, via `_rs_lower`) still refuse
# when an unenterable ancestor leaves the IDENTITY unprovable. Deleting this as "the unused spelling
# primitive" would remove the mechanism m18/m19 pin and re-open the false PASS those arms cover.
#
# ⛔ IT IS NOT THE IDENTITY AUTHORITY — do not promote it to one. It deliberately does NOT fold `..`
# and never touches the filesystem (that is what makes it usable for a dir that does not exist yet),
# so `_rs_state_key` stays the single authority for `..`, symlinks, and a case-differing spelling of a
# directory this process CAN enter. The two are complementary by design: SPELLING is proof on its own
# (identical text is one path, whatever the permission bits), IDENTITY is proof only when resolvable.
# A textual `..` fold here would be a NEW false pass — `/a/link/../b` with `/a/link -> /c` is
# physically `/b`, and text would call it `/a/b`.
#
# It is ALSO used by the suite's non-vacuity mutation, which expresses the ROUND-6 fallback with it, so
# removing it would additionally turn m11/m12 into assertions about an undefined command — a mutation
# that cannot apply, which is the "proves nothing" trap those arms exist to avoid.
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

# ⛔ `_rs_norm_path` DELIBERATELY DOES NOT COLLAPSE `..`, AND THE SHARED-STATE KEY DOES NOT CALL IT
# FOR THAT (review round 9; corrected round 15). Two rounds fixed this arm from opposite directions —
# one folded `..` here textually, the other (`_rs_state_key`) walks the path and canonicalises each
# EXISTING prefix with `cd -P` — and the walking one is the correct one: `/a/link/../b` with
# `/a/link -> /c` is PHYSICALLY `/b`, so a textual fold would call it `/a/b` and get a real directory
# wrong. ⛔ `_rs_state_key` IS THE SINGLE AUTHORITY AND DOES NOT CALL THIS FUNCTION AT ALL — since round
# 7's component walk it folds the unresolved remainder itself, inline (`out="$cand"`). The earlier
# wording here claimed this function was "its fallback for the LEADING run of a path", which described
# the ROUND-6 shape (`resolved="$(cd -P …)" || resolved="$(_rs_norm_path …)"`) that the walk replaced;
# saying so again would send a reader looking for a call site that does not exist. This function's only
# live caller is the state arm's SPELLING axis (m18/m19), which is a DIFFERENT proof, not a fallback.

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
# So: RESOLVE what exists, and fold the rest LEXICALLY.
#   * `cd -P` collapses `..`, `//`, `.` AND symlinks in one step on macOS and GNU alike — no
#     `readlink -f` (BSD does not have it) and no `stat -f`/`stat -c` flag divergence to get wrong,
#     which is the same portability argument this file already makes for `case` over `[[ =~ ]]`.
#   * ⛔ A WHOLE-PATH `cd -P` IS NOT ENOUGH (review round 7, P2 — round 6 closed the EXISTING case and
#     left the not-yet-created one open). When the dir does not exist the round-6 fallback was
#     `_rs_norm_path`, which folds `//`, `.` and `/` but NOT `..` — so
#     `state=/srv/nx/state` vs `state=/srv/nx/state/../state`, neither existing yet, printed
#     `repo-set: ok` twice and exited 0 with `OK — 2 repo(s)`, on two spellings that become ONE
#     directory the moment a controller creates it. That is the FIRST-INSTALL state, which is the
#     state this reader deliberately permits — so the gap sat exactly where the check is most used.
#   * THE REPAIR IS NOT A LEXICAL `..` COLLAPSE, which would be a NEW false pass: `/a/link/../b`
#     with `/a/link -> /c` is PHYSICALLY `/b`, and collapsing text would call it `/a/b` — losing the
#     collision. So walk the path COMPONENT BY COMPONENT from the root, canonicalising each prefix
#     that exists with `cd -P` (following symlinks), and folding the remainder lexically — valid
#     because once a prefix does not exist, nothing below it exists either, so no remaining
#     component can be a symlink and `..` there is pure text.
#   * ⛔ THAT JUSTIFICATION HAS ONE HOLE, AND IT IS THE TCC SHAPE THIS FILE KEEPS MEETING (round 9,
#     P2). A component that EXISTS but cannot be ENTERED (EACCES/EPERM/ELOOP — a `mode 000` dir, a
#     denied ancestor, launchd without Full Disk Access) is not "absent": the walk fell through to
#     the lexical branch, and every later `..` was then folded textually. Measured with kernel truth:
#     `a/link -> tgt`, `tgt` mode 000 — `realpath(a/link/../b)` and `realpath(b)` are ONE directory,
#     and the reader printed `ok` for BOTH entries and `OK — 2 repo(s)` at rc 0, with NO message;
#     make `tgt` traversable and the SAME fixture REFUSES at rc 1. A false PASS produced purely by a
#     permission bit is the worst shape, because nothing on the box looks different.
#     WHAT IT DOES INSTEAD: an unresolvable-but-present component makes the identity UNPROVABLE, so
#     this function prints NOTHING and the caller WARNS and omits the key from the dedupe. It does
#     NOT refuse — "only a PROVEN fault refuses" and "existence stays UNREQUIRED" are both recorded
#     decisions in this file, and a permission denial is not a fact about the set. What must not
#     happen is the previous SILENT assent: the operator now sees the entry named as ungraded.
#   * existence stays UNREQUIRED: a set whose state dir the operator creates afterwards must not start
#     failing. That requirement is about existence, NOT about `..`, so closing the `..` gap reopens
#     nothing.
#   * case stays the CALLER's fold (`_rs_lower`), because a dir that does not exist cannot be
#     resolved at all — folding after resolution is the only way the APFS arm (m1) survives when the
#     fixture (and a real box) has no such directory yet.
_rs_state_key() {
  local p="${1:-}" whole=""
  # Fast path: the directory exists, so ONE physical resolution settles it.
  if [ -n "$p" ]; then
    whole="$( cd -P "$p" 2>/dev/null && pwd -P )"
  fi
  if [ -n "$whole" ]; then printf '%s' "$whole"; return 0; fi

  local out="" comp cand resolved
  while IFS= read -r comp; do
    case "$comp" in
      ''|.) continue ;;
      '..') if [ -n "$out" ]; then out="${out%/*}"; fi; continue ;;
    esac
    cand="$out/$comp"
    resolved="$( cd -P "$cand" 2>/dev/null && pwd -P )"
    if [ -n "$resolved" ]; then
      out="$resolved"
    elif [ -e "$cand" ] || [ -L "$cand" ]; then
      # PRESENT but not enterable, so its canonical form is UNPROVABLE. Emit nothing: the caller
      # warns and leaves this entry out of the dedupe rather than silently folding it lexically.
      return 0
    else
      out="$cand"
    fi
  done <<EOF_STATE_KEY
$(printf '%s' "$p" | tr '/' '\n')
EOF_STATE_KEY
  [ -n "$out" ] || out="/"
  printf '%s' "$out"
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
# _rs_require <tool> <why> — a tool this reader NEEDS, named rather than assumed.
#
# ⛔ THE READER'S OWN DEPENDENCIES WERE INVISIBLE, AND THEIR ABSENCE PRODUCED A FALSE VERDICT (review
# round 42, P2, measured twice). `sed` trims a line; with `sed` off PATH every line read as blank and a
# VALID two-repo set came back `NO-ENTRIES — … names no repo (comments and blank lines only)`, rc 4 — a
# claim about a file that named two repos. `awk` renders the entry list; with `awk` off PATH both
# `rendered` and `expected` came back empty, `_rs_split_divergence` compared two empty strings as EQUAL,
# and a set this same reader REFUSES at rc 1 (a tag collision) was certified `OK — 2 repo(s)`, rc 0.
# That is a FALSE PASS, not a diagnosis defect. Neither tool is a proof: they are the reader's own
# substrate, so their absence must be a NAMED REFUSAL at the point of use, never a silently smaller set.
_rs_require() {
  command -v "$1" >/dev/null 2>&1 && return 0
  _rs_say 2 "repo-set: REFUSED — \`$1\` is not on PATH, and it is not optional: $2"
  return 1
}

repo_set_parse() {
  # ⛔ `tr` IS THE THIRD PIECE OF SUBSTRATE, AND IT WAS THE ONE STILL UNGUARDED (review round 43, P2 —
  # measured three ways). `_rs_lower` IS `tr`, and every dedupe key and every state/provenance comparison
  # goes through it. With `tr` off PATH each key folded to the EMPTY string, so:
  #   · a VALID two-repo set was refused `DUPLICATE-SLUG — … is already named above` at rc 5 (both
  #     entries keyed to ""), i.e. a false block that names the wrong cause;
  #   · the wrapper's `"$a" != "$b"` provenance refusal became `"" != ""` = false, so it announced
  #     `Grading the ONE repo this unit declares in PR_DOCTOR_REPO=…` for a checkout that PROVES a
  #     different repo — the "claims to grade, grades nothing" shape that branch was rewritten to remove;
  #   · the state-spelling WARN promised "beyond its own spelling" for a proof whose spelling axis had
  #     not run at all. The refusal here pre-empts all three with no wrapper edit: the wrapper only enters
  #     the degraded branch on rc 3, so a named rc-5 refusal stops it first.
  _rs_require tr "it is the case fold every slug, state and provenance comparison goes through, so without it every dedupe key is EMPTY: a valid set reads as DUPLICATE-SLUG, and two different repos compare as equal." || return 5
  _rs_require sed "it trims a line's surrounding whitespace, so without it every line reads as blank and a set full of repos would be reported EMPTY rather than unreadable." || return 5
  local f; f="$(repo_set_file)"
  # ⛔ `-L` BEFORE `-e`: `-e` FOLLOWS the link, so a DANGLING symlink reads as absent and the box
  # silently degrades — measured in review round 7. A dotfile manager whose target moved (stow,
  # chezmoi) lands exactly here: the machine stops grading every repo but one and is told to create a
  # file that is already there. An existing LINK that does not resolve is the broken state (5).
  # ⛔ THE ARM DOES NOT DIAGNOSE THE CAUSE, BECAUSE `[ ! -e ]` CANNOT (review round 8, P2). `-e` is false
  # for EVERY stat failure — a missing target, an EACCES/EPERM denial on an ancestor (the same macOS TCC
  # shape this file reasons about sixteen lines below), and an ELOOP link loop all land here. Round 7's
  # first cut asserted "whose target does not exist", i.e. it turned the very test this file says can
  # never PROVE absence into a proven claim, and sent an operator whose dotfile target is merely
  # unreachable to "fix the link's target". The code (5, broken — never 3, absent) is right; the
  # diagnosis is now the observation plus the two candidates.
  if [ -L "$f" ] && [ ! -e "$f" ]; then
    _rs_say 2 "repo-set: INVALID — $f is a SYMLINK that does not RESOLVE. An existing link that leads"
    _rs_say 2 "repo-set:   nowhere is the broken state, not the absent one: this machine has named a repo"
    _rs_say 2 "repo-set:   set and nothing can read it. Causes: the target was moved/deleted, an ancestor"
    _rs_say 2 "repo-set:   denies this process (launchd has no Full Disk Access under ~/Documents), or the"
    _rs_say 2 "repo-set:   link loops. Check the target; creating the file would REPLACE the link."
    return 5
  fi
  # ⛔ ABSENCE IS ONLY PROVEN WHEN WE CAN SEE THE DIRECTORY THAT WOULD HOLD IT (review round 9, P2).
  # `-e` is false for EVERY stat failure, so a readable config behind a `chmod 000` ancestor — the
  # macOS TCC shape, one level up from the symlink arm above — read as "does not exist", the box got
  # code 3, and the wrapper DEGRADED: the machine graded ONE repo while the operator was told to create
  # a file that is already there. `-e` false + a traversable parent IS proof of absence (we can list the
  # directory); `-e` false + an untraversable parent is UNRESOLVABLE, which is the broken state.
  # ⛔ ABSENCE IS PROVABLE WHENEVER THE NEAREST **EXISTING** ANCESTOR IS TRAVERSABLE (review round 10,
  # P1). Round 9 tested only the IMMEDIATE parent, `[ -d ] && [ -r ] && [ -x ]`, which is wrong twice
  # over:
  #   * a box that has never created `~/.config/orchestrator` at all — the FIRST-INSTALL / migration
  #     state this whole change exists to serve — fell to the INVALID branch, so `check` returned 5 and
  #     the wrapper REFUSED exit 2 and the documented single-repo degraded mode was UNREACHABLE. It also
  #     told that operator "the file exists" and "do not create the file", both false;
  #   * `-r` on the parent was never needed: `x` alone makes `stat(<dir>/<file>)` answer honestly, so a
  #     mode-111 parent was reported broken for no reason.
  # So: walk UP to the nearest path component that exists. If that component is a traversable
  # directory, we can see the whole chain below it and `-e` false IS proof of absence (code 3). If it is
  # not traversable — the macOS TCC shape, `~/Documents` with no Full Disk Access — absence cannot be
  # proven, and that is the broken state (5).
  if [ ! -e "$f" ]; then
    local anc kind; anc="$(_rs_nearest_existing_ancestor "$f")"
    kind="$(_rs_stat_kind "$f")"
    # ⛔ THE ONE SPELLING THAT MAKES `-e` LIE ABOUT AN EXISTING NON-DIRECTORY IS A TRAILING SLASH (round 47
    # review, P1). `stat("<file>/")` is ENOTDIR, so `[ -e "<file>/" ]` is FALSE while `[ -e "<file>" ]` is
    # true — which is how this arm was reached for a set that is right there. The walk cannot see it
    # either: it strips the trailing slash and then starts at the PARENT, so `anc` is a TRAVERSABLE
    # DIRECTORY and the ancestor test alone proves absence. With a stat answer the `notdir` errno names what
    # the path IS (a file, not a directory), and NOT who found it: the refusal below branches on the SPELLING
    # (`[ -e "$stripped" ] && [ ! -d "$stripped" ]`), so an errno route and a no-errno route answer the same
    # text — measured, byte-identical output with and without an interpreter; with none — `unknown`, the
    # no-interpreter route — the stripped spelling is the ONLY evidence available, so it is tested before
    # absence is claimed.
    # ⛔ AND IT IS NOT GATED ON `kind` (round 48 — measured, and this note used to claim the opposite): a
    # dangling link spelled with a trailing slash answers `absent` (ENOENT), NOT ENOTDIR, and it very much
    # has an existing stripped form. The stripped-spelling test therefore fires on the `absent` route as well
    # as on `unknown`, which is precisely what `j16r` pins — gate it on `unknown` and that shape degrades to
    # rc 3, the code the wrapper acts on.
    local stripped="$f"
    while [ "${stripped%/}" != "$stripped" ] && [ -n "$stripped" ]; do stripped="${stripped%/}"; done
    # ⛔ `/` ONLY — AND `/.` WAS TRIED AND REMOVED (round 48, measured, twice). `/srv/state` and `/srv/./state`
    # really are one directory, so `<a dangling link>/.` was a hole while absence was decided by the ancestor
    # walk alone. That hole is now closed by the ANCESTOR-LINK ARM near the end of this function (it runs
    # immediately BEFORE the absence claim — note that it is BELOW this comment, not above it; "above" here is
    # where the LEAF arm lives, which is about a link at the path itself and does not close the `/.` hole).
    # With that arm in place a `/.`-stripping loop changes NOTHING: every dot-suffixed spelling of a broken
    # path answers 5 through the arm — measured by reverting the loop, which red NO arm and changed NO
    # verdict on six spellings. Speculative code carrying a comment that calls it load-bearing is worse than
    # no code, so it is gone, and this note is what stops the next lane re-adding it without a fixture that
    # needs it.
    # ⛔ NOT `_rs_norm_path` EITHER: it ABSOLUTISES, turning a RELATIVE `dang.conf/` into `/dang.conf`, which
    # REGRESSES that spelling from 5 back to 3 (measured).
    # ⛔ THE ERRNO DECIDES WHEN IT CAN (review round 11, P2). `-e` false is false for EVERY stat failure,
    # and absence is only one of them — EXAMPLES, not an enumeration, so the list cannot go stale the way
    # the kind list beside it did: ENOENT, EACCES/EPERM (a TCC denial under a MODE-traversable ancestor),
    # ENOTDIR (a component is a FILE — the walk below is the one authority for that cause, since round 45
    # deleted the `case` arm that used to own it), ENAMETOOLONG, EIO. Only ENOENT is absence.
    # When `unknown` comes back, the ancestor walk below decides and the narrower claim in its message
    # ("we cannot see it") is the honest one.
    case "$kind" in
      denied|other)
        _rs_say 2 "repo-set: INVALID — $f cannot be STAT'd, and the failure is NOT "no such file""
        _rs_say 2 "repo-set:   (errno reported: $kind). That is the BROKEN state, not the absent one: this"
        _rs_say 2 "repo-set:   box may well have named its repos and this process cannot see them — a"
        _rs_say 2 "repo-set:   permission denial on an ancestor (launchd has no Full Disk Access under"
        _rs_say 2 "repo-set:   ~/Documents), a path that is too long, or an I/O error. Do not create the file;"
        _rs_say 2 "repo-set:   check its location and the mode of the directories above it."
        return 5 ;;
    esac
    if [ "$kind" = present ]; then
      # `-e` false but stat succeeded: a link/race we do not model — broken, not absent.
      _rs_say 2 "repo-set: INVALID — $f stat's but is not visible as a path; refusing to guess why."
      return 5
    fi
    # ⛔ THE WALK'S FALLBACK IS FOR `unknown` ONLY — THE KIND-BLIND FORM CERTIFIED ABSENCE ON AN `ENOTDIR`
    # PATH (round 47 review, P1 — measured). The clause used to be
    # `[ "$kind" = absent ] || { [ -n "$anc" ] && [ -d "$anc" ] && [ -x "$anc" ]; }`: the second half
    # tested the ANCESTOR and never the KIND, so any shape whose nearest existing component is a
    # TRAVERSABLE DIRECTORY proved absence whatever the errno said. The spelling that reaches it without
    # a mode bit, a link or an exotic host is a set path ending in `/` on a REGULAR FILE
    # (`REPO_SET_FILE=<an existing set>/`): `-e` is false there (`stat` says ENOTDIR, the last component
    # is not a directory), the walk STRIPS the trailing slash and answers the file's parent — a
    # traversable directory — so the old clause certified "this machine has named no repo" about a file
    # that is right there, at code 3, which is the one code `pr-doctor-machine.sh`'s degrade branch acts
    # on. Measured on that exact fixture: the kind-blind clause answers rc 3 `NO-REPO-SET … does not
    # exist`; with the kind pinned to `unknown` the walk's own fallback below answers rc 5 and keeps its
    # `must be a DIRECTORY` guidance.
    # ⛔ WHY `unknown` IS THE ONLY KIND THAT NEEDS THIS CLAUSE: every other kind that can reach here is
    # either already returned above (`denied`/`other`, `present`) or a MEASURED fault of its own
    # (`notdir` — a component is a file, which the walk names). `unknown` is the ONE answer that is not a
    # claim — no interpreter resolve, or an answer outside the six-value contract — so it is the one case
    # where the traversable-ancestor test is the only evidence available, which is what `j16f` and
    # `j16l` pin.
    # ⛔ A DANGLING LINK SPELLED WITH A TRAILING SLASH IS THE SAME SHAPE ONE LEVEL OUT, AND IT SATISFIED THE
    # ABSENCE CLAUSE (round 48 review, P1 — measured). Round 47 keys absence on `[ ! -e "$stripped" ]`, and
    # `-e` FOLLOWS the link: for `dang.conf -> <a target that is not there>` the STRIPPED spelling reads
    # "absent" as well, so a set that is right there was certified absent at **rc 3** — the code the wrapper
    # DEGRADES on — and the operator was told to create a file that is a link in plain sight. `[ -L
    # "dang.conf/" ]` is FALSE (the trailing slash makes the check follow), so no arm could see it in the
    # spelled form; the link is visible only in the STRIPPED spelling. ⛔ THIS IS THE `absent` ROUTE, NOT ONLY
    # `unknown` — a dangling leaf answers `absent` even WITH an interpreter — which is why it is tested
    # BEFORE the absent disjunct rather than inside it.
    # ⛔ AND IT MUST NOT SWALLOW A LINK THAT RESOLVES TO A FILE (`filelink/`): `[ ! -e ]` is false for that
    # one, so it keeps the not-a-directory cause below, which is true of it.
    if [ -n "$stripped" ] && [ -L "$stripped" ] && [ ! -e "$stripped" ]; then
      _rs_say 2 "repo-set: INVALID — $f is not visible from here, because the spelling without its trailing slash is a symbolic link that cannot be resolved from here"
      _rs_say 2 "repo-set:   (the link: $stripped). That is the BROKEN state, not the absent one:"
      _rs_say 2 "repo-set:   nothing below an unresolvable link can be shown to exist OR to be absent."
      _rs_say 2 "repo-set:   Do not create the file; check what that link points at, and whether this"
      _rs_say 2 "repo-set:   process is allowed to follow it."
      return 5
    fi
    # ⛔ AN UNRESOLVABLE LINK **ABOVE** THE SET IS THE SAME BROKEN STATE AS ONE AT IT, SO THE WALK'S LINK
    # ARM NOW RUNS *BEFORE* THE ABSENCE CLAIM (round 48 review, P1 — measured). For `$T/dirlink/repos.conf`
    # where `dirlink` points at a directory that is not there, `stat` answers ENOENT — so the `absent`
    # disjunct below fired and the WITH-interpreter reader answered 3 (`does not exist`) while the
    # no-interpreter reader answered 5 through this arm: the better-equipped reader gave the more dangerous
    # answer, and the wrapper took its DEGRADE branch for a box whose mount is simply not there (the stow /
    # chezmoi / unmounted-volume shape round 7 exists for). The doctrine is that an existing link which
    # leads nowhere is BROKEN, not absent — it does not stop being true one component up.
    # ⛔ THIS IS THE WALK'S OWN ARM, MOVED — NOT COPIED (measured: a duplicate left this one unreachable, so
    # its message could never print and `j16l` — which pins that message — reddened while the verdict stayed
    # right). One arm, one message, one sensor, and it fires for BOTH readers because `anc` is the link on
    # both routes.
    if [ -n "$anc" ] && [ -L "$anc" ] && [ ! -e "$anc" ]; then
      _rs_say 2 "repo-set: INVALID — $f is not visible from here, because its nearest existing component is a symbolic link that cannot be resolved from here"
      _rs_say 2 "repo-set:   (nearest existing: $anc). That is the BROKEN state, not the absent one:"
      _rs_say 2 "repo-set:   nothing below an unresolvable link can be shown to exist OR to be absent."
      _rs_say 2 "repo-set:   Do not create the file; check what that link points at, and whether this"
      _rs_say 2 "repo-set:   process is allowed to follow it."
      return 5
    fi
    if [ "$kind" = absent ] || { [ "$kind" = unknown ] && [ ! -e "$stripped" ] && [ -n "$anc" ] && [ -d "$anc" ] && [ -x "$anc" ]; }; then
      # ⛔ "NO HOME TO RESOLVE" IS BROKEN (5), NOT ABSENT (3) (round 32, P2). With `HOME` unset the path
      # above is EMPTY, and calling that "this machine has named no repo" degrades the wrapper on a box
      # that may well have named several — the opposite of what code 3 means. Name it instead.
      if [ -z "${REPO_SET_FILE:-}" ] && [ -z "${HOME:-}" ]; then
        _rs_say 2 "repo-set: INVALID — HOME is unset or empty and REPO_SET_FILE names nothing, so the set path cannot be resolved; set REPO_SET_FILE=<absolute path>"
        return 5
      fi
      # ⛔ THE MESSAGE MUST NOT CLAIM MORE THAN THE ROUTE PROVED (round 48 review, P3 — measured): the
      # `unknown` disjunct is an INFERENCE from a traversable ancestor, and no length or permission test
      # exists on it, so a set path over `PATH_MAX` (or one only launchd's Full Disk Access can see) with
      # no runnable interpreter reaches this branch and used to be told `does not exist` as though that had
      # been established. The verdict stays 3 — the ancestor walk is the best evidence there is here — but
      # the sentence says which evidence it is, and names what it cannot rule out.
      if [ "$kind" = absent ]; then
        _rs_say 2 "repo-set: NO-REPO-SET — $f does not exist, so this machine has named no repo."
      else
        _rs_say 2 "repo-set: NO-REPO-SET — $f shows no sign of existing, and no stat answer came back (no"
        _rs_say 2 "repo-set:   runnable python3 resolved, or the answer was outside the six-value contract), so"
        _rs_say 2 "repo-set:   this is the ancestor walk's INFERENCE and not a proof: the path could be too"
        _rs_say 2 "repo-set:   long, or visible only with Full Disk Access. As far as this process can tell,"
        _rs_say 2 "repo-set:   this machine has named no repo."
      fi
      _rs_say 2 "repo-set:   Create it, one repo per line:"
      _rs_say 2 "repo-set:     slug=OWNER/NAME checkout=/abs/checkout [state=/abs/state-dir]"
      return 3
    fi
    # ⛔ THE WALK IS THE ONE AUTHORITY FOR THESE CAUSES (round 45, P2 — measured): with an interpreter the
    # `ENOTDIR` shape answers `notdir` and falls through to here (no `case` arm claims it), and with none it
    # answers `unknown` and lands here the same way. One path, one cause, one sensor behind it.
    # ⛔ AND SEVERAL SHAPES REACH THIS POINT, SO ONE SENTENCE CANNOT DESCRIBE THEM ALL (round 46, P2 —
    # measured: the untraversable-directory shape printed "neither is any directory above it" one line above
    # `(nearest existing: /tmp/f1/den)`, which refutes it, in `j16f`'s OWN fixture). The walk's answer is one of:
    #   * a SYMLINK that cannot be resolved here (`-L` true, `-e` false). It is returned as the nearest
    #     existing component (round 46: `[ -e ]` used to SKIP it and hand back a traversable grandparent, so
    #     absence was "proven" through the link — the degrade code for a set that exists). ⛔ THIS ARM HAS
    #     MOVED: it is now tested BEFORE the absence claim, so it fires on the `unknown` route AND on the
    #     `absent`-with-errno route, and the `absent` test below can no longer turn a link into 3. The
    #     earlier note here said the opposite ("reached only when no stat answer came back", because "a
    #     DANGLING link answers `absent`, which the absent test above turns into 3 — correct") — that was
    #     measured false in round 48 and is the reason a set spelled BELOW a dangling link degraded.
    #   * a nearest existing component that is not a DIRECTORY — a file, a FIFO, or a link resolving to one.
    #   * a TRAILING-SLASH path whose stripped spelling is an existing NON-directory (`<an existing set>/`).
    #     ⛔ THE WALK CANNOT SEE THAT COMPONENT: it strips the trailing slash and then starts at the PARENT,
    #     so for this shape `anc` is a TRAVERSABLE DIRECTORY and every ancestor-based test below is false
    #     about the real cause (round 47 review, P1 — measured). It is recognised by SPELLING, not by the
    #     `notdir` errno, because the no-interpreter route has no errno at all. Without this the shape
    #     reached the absence proof above and answered code 3 for a file that is right there.
    #   * a nearest existing DIRECTORY that is not traversable (mode 000, the TCC shape). It IS a directory,
    #     so the not-a-directory causes are false about it and it needs its own sentence.
    #   * nothing examinable at all (empty `anc`) — declared below, with no arm.
    if [ -n "$anc" ] && { [ ! -d "$anc" ] || { [ -e "$stripped" ] && [ ! -d "$stripped" ]; }; }; then
      # ⛔ AND THE GUIDANCE IS THE MEASURED ONE, NOT A LIST OF CANDIDATES: the walk has just established
      # that the nearest existing component is a FILE, so offering "launchd has no Full Disk Access" or
      # "check the location and mode" would send the operator to a cause this code just DISPROVED. Every
      # component above the file must be a directory, and one of them is not.
      # ⛔ AND THE SECOND DISJUNCT IS THE TRAILING-SLASH CAUSE (round 47 review, P1 — measured), stated by
      # the SPELLING rather than by the errno so it holds with OR without a stat answer: a path ending in
      # `/` whose stripped spelling EXISTS but is not a directory names a non-directory AS a directory. The
      # walk cannot see that component (it strips the slash and starts at the PARENT), so `anc` is an
      # innocent traversable DIRECTORY and the traversability sentence below was false about it. This test
      # is the one evidence that needs no interpreter, which is why it, and not `kind = notdir`, is what
      # the arm branches on. "every component above the file must be a DIRECTORY, and one of them is not"
      # is true of it; "not traversable" is not.
      _rs_say 2 "repo-set: INVALID — $f is not visible from here, because its nearest existing component is not a directory"
      _rs_say 2 "repo-set:   (nearest existing: $anc). That is the BROKEN state, not the absent one:"
      _rs_say 2 "repo-set:   every component above the file must be a DIRECTORY, and one of them is not."
      _rs_say 2 "repo-set:   Do not create the file; fix the path above."
      return 5
    fi
    if [ -n "$anc" ]; then
      _rs_say 2 "repo-set: INVALID — $f is not visible from here, because the nearest existing directory above it is not traversable from here"
      _rs_say 2 "repo-set:   (nearest existing: $anc). That is the BROKEN state, not the absent one:"
    else
      # ⛔ THIS ARM HAS NO SENSOR AND IS NOT CLAIMED TO HAVE ONE (round 46). It runs only when `anc` is EMPTY,
      # and the walk answers / whenever `[ -e / ]` — so no environment on any host this runs on reaches it,
      # and a mutant that deletes it stays green. It is kept because the alternative is a fallthrough that
      # prints the NOT-A-DIRECTORY cause for a shape nobody examined, and it is DECLARED rather than
      # silently uncovered: the only way in is a box where even `/` cannot be tested.
      _rs_say 2 "repo-set: INVALID — $f is not visible from here, and NO component above it could be examined"
      _rs_say 2 "repo-set:   (nearest existing: none). That is the BROKEN state, not the absent one:"
    fi
    _rs_say 2 "repo-set:   this box may well have named its repos and this process cannot see them (launchd"
    _rs_say 2 "repo-set:   has no Full Disk Access under ~/Documents). Do not create the file; check the"
    _rs_say 2 "repo-set:   location and mode of the path above."
    return 5
  fi
  # ⛔ `-e` IS TESTED FIRST. The absent arm used `[ ! -f ]`, so a DIRECTORY at the config path read as
  # "this box names no repo" (code 3) and the wrapper DEGRADED on it — while telling the operator the
  # path "does not exist", which it plainly does. An existing thing that is not a usable file is the
  # broken-file state (5), never the absent one (3).
  if [ ! -f "$f" ]; then
    # ⛔ THE PARENTHETICAL NAMED ONE CAUSE FOR ONE OF MANY STATES, AND EVERY COUNT OF THE MANY WAS STALE ON
    # ARRIVAL (review round 44, P2; measured three times). It said "a directory at the config path cannot
    # name repos", while a FIFO and a SOCKET reach this arm and a FIFO very much can carry lines. The
    # replacement said "three states"; its replacement said "six kinds" — and a BLOCK device (`/dev/vda`)
    # reaches it too, at the same rc with the same message. ⚠️ THAT IS THE POINT, SO THERE IS DELIBERATELY
    # NO NUMBER HERE: the rule is the BOUNDARY, not the list. The message below says "not a regular file"
    # because that is true of every kind including ones nobody has tried yet, and it goes stale only if
    # the boundary itself moves. Before this round only a directory was armed (`j3`/`j4`; this round adds
    # `j4b`, a FIFO), so the old sentence asserted an unverified specific — the "right code, wrong cause"
    # shape the `-L` arm above was rewritten to avoid. "Before this round" is load-bearing: written in the
    # present tense it read as a statement about the head, where a FIFO now reaches this arm.
    # The rule, stated as the rule.
    _rs_say 2 "repo-set: INVALID — $f exists but is not a regular file (a repo set must be a regular file)."
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
  # ⛔ `_dupkey` MUST BE LOCAL, OR IT LEAKS INTO THE CALLER'S SHELL (round 9, P2). This file's contract
  # is that it can be SOURCED, and its own n1/n2 arms make caller-shell purity a named defect class.
  # Measured before this line existed: after `repo_set_parse` + `repo_set_check` in a sourcing shell,
  # `_dupkey` was still set. It is reassigned every iteration so the reader itself is unaffected — it
  # is the caller that inherits a variable it never declared.
  local _dupkey=""
  local -a out=()

  while IFS= read -r line || [ -n "$line" ]; do
    ln=$(( ln + 1 ))
    line="${line%$'\r'}"
    # Leading/trailing whitespace, then blank/comment.
    line="$(printf '%s' "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    case "$line" in ''|'#'*) continue ;; esac

    slug=""; checkout=""; state=""
    # ⛔ EMPTINESS IS NOT A "SEEN" FLAG (review round 40, P2). The three duplicate checks used
    # `[ -z "$var" ]`, so `checkout= checkout=/tmp` — the FIRST occurrence empty — never reported
    # DUPLICATE-KEY and the LAST value won silently (measured: rc 0, no message, `/tmp` kept; the
    # mirror shape `checkout=/tmp checkout=` was refused, so the refusal depended on ORDER). A key
    # given twice is refused because a set that reads differently depending on token order is a set
    # whose shape an operator cannot see. The empty value itself stays legal ONCE, but NOT for
    # `checkout`: `checkout=` empty is `MISSING-CHECKOUT` (the format table makes checkout REQUIRED).
    # The optional key is `state=` — that is how a line omits the state dir — which is what the
    # flag/value split protects. ⛔ This sentence said `checkout=` until round 43 measured it and found
    # the opposite (review P2); the arm that pins it uses `state=` and always did, so only the prose was
    # wrong.
    local slug_seen=0 checkout_seen=0 state_seen=0
    local line_bad=0
    local IFS=$' \t'
    for tok in $line; do
      case "$tok" in
        *=*) : ;;
        *) _rs_say 2 "repo-set: BAD-TOKEN — $f:$ln: \`$tok\` is not key=value (a value with a space splits here)"; line_bad=1; continue ;;
      esac
      key="${tok%%=*}"; val="${tok#*=}"
      case "$key" in
        slug)     [ "$slug_seen" = 0 ]     || { _rs_say 2 "repo-set: DUPLICATE-KEY — $f:$ln: slug= given twice"; line_bad=1; };     slug="$val";     slug_seen=1 ;;
        checkout) [ "$checkout_seen" = 0 ] || { _rs_say 2 "repo-set: DUPLICATE-KEY — $f:$ln: checkout= given twice"; line_bad=1; }; checkout="$val"; checkout_seen=1 ;;
        state)    [ "$state_seen" = 0 ]    || { _rs_say 2 "repo-set: DUPLICATE-KEY — $f:$ln: state= given twice"; line_bad=1; };    state="$val";    state_seen=1 ;;
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
    # ⛔ THE KEY IS THE DOCTOR'S OWN NORMALIZED IDENTITY (review round 8, P2), not a case fold: the
    # parser this file already delegates to maps `owner/name`, `owner/name.git`, a host prefix and a URL
    # onto ONE slug, so `daniel-ospina/tortoise` and `daniel-ospina/tortoise.git` are the same repo to
    # every consumer — and `set_tag_collisions` compares NORMALIZED slugs, so it cannot catch this pair
    # either. Two entries of one repo against one register is exactly what this arm forbids.
    _dupkey="$(_rs_normalize_slug "$slug")"
    # ⛔ THE SENTINEL IS NOT A DEDUPE KEY (round 18, P2). `_rs_normalize_slug` answers
    # `__UNASKABLE__` when the sibling will not LOAD, and that is a non-empty string — so the
    # `[ -n ]` fallback below would NOT fire and EVERY entry would key to `__unaskable__`, refusing a
    # healthy multi-repo set as DUPLICATE-SLUG (rc 5, wrapper exit 2) purely because the doctor was
    # unloadable. Measured: a valid 2-repo fixture + an unloadable sibling went from `OK — 2 repo(s)`
    # to `DUPLICATE-SLUG`/rc 5. Clear it so the slug-spelling fallback does its job, exactly as it does
    # when normalisation is simply unavailable.
    [ "$_dupkey" = "__UNASKABLE__" ] && _dupkey=""
    [ -n "$_dupkey" ] || _dupkey="$(_rs_lower "$slug")"
    case "$seen" in
      *$'\n'"$(_rs_lower "$_dupkey")"$'\n'*)
        _rs_say 2 "repo-set: DUPLICATE-SLUG — $f:$ln: \`$slug\` is already named above; a set with the same repo twice grades it twice and dispatches it twice (case-INSENSITIVE, like the doctor's own dedupe)"
        rc=5; continue ;;
    esac
    seen="$seen"$'\n'"$(_rs_lower "$_dupkey")"$'\n'

    if [ -z "$checkout" ]; then
      _rs_say 2 "repo-set: MISSING-CHECKOUT — $f:$ln: \`$slug\` names no checkout; the doctor will fall back to REPO/cwd for one, or grade its queue read-only"
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
    # ⛔ THE CODE IS THE RETURN VALUE, NOT THE SENTENCE'S SUBJECT (round 35, P2). This used to read
    # "REFUSING <file> — 5 is not a usable set until the lines above are fixed", which an operator
    # reads as "5 is not a usable set": the number is the function's answer (and the RETURN CODES
    # table is the place that names it), not a thing that can be spoken about. The refusal already
    # named every fault above it, so the summary says what it measured and stops.
    _rs_say 2 "repo-set: REFUSING $f — not a usable set until the lines above are fixed"
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
# and the doctor cannot disagree about a remote, a slug, a tag set or the set's own splitting.
# Prints the answer, or "" when nothing could be asked. ⛔ THE EXCEPTION IS THE SENTINEL: the verbs
# whose empty answer is MEANINGFUL print `__UNASKABLE__` instead, because the caller cannot tell
# "nothing to report" from "could not ask":
#   tags  — "" means no collision          -> sentinel emitted here
#   strip — "" means "nothing to trim"     -> sentinel emitted here
#   norm  — "" means "not a slug"         -> sentinel emitted here
#   split — "" means "no divergence"      -> sentinel applied by `_rs_split_entries`
#   origin— "" means "proves nothing"      -> its own TAB reason, written by the `try/except` in the
#                                            heredoc below; ⛔ it does NOT report "no python3, or it would
#                                            not load", which this line claimed until round 42 measured a
#                                            sibling that LOADED and merely LACKED `_origin_slug` being
#                                            blamed on the interpreter.
# Keep this list true when adding a verb — a stale contract line here is how the `tags` guard went a
# whole round reading a dead sibling as agreement.
#
# ⛔ THE VERB LIST IS PART OF THE CONTRACT — KEEP IT TRUE (review round 12, P2). It said `origin` or
# `norm` long after three more verbs had been added, so a reader could believe the whole-set guards
# did not exist. There are FIVE, each delegating to the function named:
#   strip  (_rs_strip)          `str.strip()` — what Python's strip removes, incl. U+00A0
#   split  (configured_repos)   the set as the doctor's own splitter reads it
#   tags   (set_tag_collisions) repo-tag collisions across the whole set
#   norm   (_normalize_slug)    one slug normalised
#   origin (_origin_slug)       the slug a checkout's origin PROVES (the `else` arm)
# ⛔ THE PROOF CHILD'S HEREDOC LIVES IN A FUNCTION BODY, NOT INSIDE `$( )` — AND THIS BODY IS WHY. bash 3.2's
# `$( )` scanner does not follow here-document quoting: an unbalanced quote, backtick or parenthesis in the
# body desynchronises the parse state for the REST OF THE FILE, so this body — full of apostrophes
# (`wrapper's`, `caller's`, ...) — failed to parse at EOF. ⛔ THE MESSAGE IS QUOTED VERBATIM HERE AND NOWHERE
# ELSE, because a near-miss is ungreppable (an earlier version rendered it with a double quote where bash
# prints a backtick). bash 3.2.57 prints, on `4d5d395e`'s file:
#
#     unexpected EOF while looking for matching `"'
#
# 575 lines below the cause — opener at line 800, error at 1375 — and only on the platform the fleet runs
# (macOS `/bin/bash`; `bash32-parse` is the gate). ⛔ AND THE SHAPE IS THE FIX, NOT A QUOTE AUDIT:
# a body that happens to be quote/backtick/paren BALANCED does parse on 3.2 and is still wrong at RUNTIME, so
# the gate's header names both halves. Keep the heredoc in a function body and make the capture a plain call
# (the remediation the gate itself names, #2248, #2930).
_rs_proof_child() {
  PYTHONUTF8=1 "$1" - "$2" "$3" "$4" <<'PY_PROOF' 2>/dev/null
import importlib.util, sys
doc, verb, arg = sys.argv[1], sys.argv[2], sys.argv[3]
spec = importlib.util.spec_from_file_location("_prd", doc)
mod = importlib.util.module_from_spec(spec)
try:
    spec.loader.exec_module(mod)
except Exception:
    # ⛔ A SIBLING THAT WILL NOT LOAD IS ALSO "COULD NOT ASK" — AND THE ANSWER IS PER VERB (round 17,
    # P2). This arm used to exit silently with empty stdout for EVERY verb, so a guard reading "" as a
    # MEANINGFUL answer ("no collision", "no trimming needed") read a dead module as agreement.
    # Reachable in practice: a sibling whose annotations need a newer interpreter fails at exec_module.
    # ⛔ PER VERB, NOT A GLOBAL GATE (round 18 corrected round 17/18's own first attempt). Gating the
    # whole-set proofs behind a loadability probe made the reader SKIP both guards, which suppressed the
    # specific warnings and turned m29 red — strictly worse than the shape it fixed. Each guard that has
    # a meaningful empty answer is told here instead:
    #   tags  — "" means no collision          -> sentinel
    #   strip — "" means "nothing to trim"     -> sentinel, and the wrapper's `_trim` falls back on it
    #   norm  — "" means "not a slug"         -> sentinel, and the wrapper's rank checks read it as
    #                                               "could not be normalised", not "invalid slug"
    #   split — mapped shell-side by `_rs_split_entries`
    #   origin— answers its own TAB reason (round 42) **including in THIS arm** (round 44, P2 — measured):
    #            before that it wrote nothing here, fell through to the caller's residue line, and the
    #            operator was told `the proof child did not start` about a child that started, imported and
    #            RAISED. Every verb EXCEPT `split` answers here — `split` is mapped shell-side by
    #            `_rs_split_entries` (the line above), and saying "every verb" contradicted that line.
    if verb in ("tags", "strip", "norm"):
        sys.stdout.write("__UNASKABLE__")
    elif verb == "origin":
        sys.stdout.write("\tpr-doctor.py would not LOAD, so no origin can be proved")
    raise SystemExit(0)
if verb == "strip":
    sys.stdout.write(arg.strip())
elif verb == "split":
    # ⛔ DELEGATED, NOT RE-TYPED (round 10, P2). This carried its OWN copy of the splitter
    # (`re.split(r"[,\s]+", arg)`), which is byte-identical to `configured_repos()` TODAY — and that
    # is exactly what made it a latent false PASS. The promise below ("any future separator it learns
    # is covered the day the doctor learns it") is undeliverable by a copy. Measured with a doctored
    # `pr-doctor.py` in /tmp whose `configured_repos` also splits on `;`: the reader certified
    # `OK — 1 repo(s)` at rc 0 for a checkout path carrying `;`, and the doctor then split it into a
    # TRUNCATED real entry plus a phantom repo — the same failure this guard already refuses for `,`
    # and for NBSP. So ask the doctor's own splitter.
    # The dedupe `configured_repos()` applies cannot shrink an accepted set: two entries of one
    # normalized key are already refused upstream as DUPLICATE-SLUG.
    sys.stdout.write("\n".join(mod.configured_repos([], {"PR_DOCTOR_REPOS": arg})))
elif verb == "tags":
    # ⛔ A MISSING OR RAISING `set_tag_collisions` MUST NOT LOOK LIKE "NO COLLISION" (round 16, P2).
    # Only MODULE-LOAD failure is caught above; this verb's own failure made python exit non-zero with
    # stdout suppressed, so `_rs_tag_collision` returned "" — byte-identical to the legitimate
    # no-collision answer — and the reader certified a colliding set. Measured with a sibling doctor
    # whose `set_tag_collisions` was deleted, and again with one that raised: the colliding two-repo set
    # (`acme/tools-api` + `acme-tools/api`) printed `OK — 2 repo(s)` at rc 0 with NO warning, against
    # rc 1 with the shipped doctor. Same sentinel the `split` verb already uses for exactly this shape.
    try:
        sys.stdout.write(mod.set_tag_collisions(arg.split(",") if arg else []))
    except Exception:
        sys.stdout.write("__UNASKABLE__")
elif verb == "norm":
    # ⛔ A MISSING OR RAISING `_normalize_slug` MUST NOT LOOK LIKE "NOT A SLUG" (round 29, P2). The
    # `tags` guard above covers only its own verb; this one had none, so a sibling that LOADS but
    # predates the helper raised AttributeError AT CALL TIME, stdout was suppressed, and every caller
    # read "" as the MEANINGFUL answer "not a slug". Measured with a sibling that loads and simply
    # lacks the function: a VALID `OR=daniel-ospina/agent-infra` made the wrapper print "is not an
    # owner/name slug" and refuse (rc 2), sending the operator to fix a slug that was already right;
    # and `slug=acme/alpha.git` over a checkout proving `acme/alpha` was REFUSED, undoing round 25's
    # normalisation fix. Reachable via a stale farmed sibling — the class `check-farm-drift.sh` exists
    # for — and fail-closed, which is why it is a diagnosis defect rather than a false pass.
    try:
        sys.stdout.write(mod._normalize_slug(arg))
    except Exception:
        sys.stdout.write("__UNASKABLE__")
else:
    # ⛔ THIS IS THE ONE VERB WITH NO PER-VERB "COULD NOT ASK" ANSWER (review round 42, P2 — measured).
    # Every other verb reports its own failure; `_origin_slug` is called bare, so a sibling that LOADS
    # and simply LACKS it raised AttributeError out of the heredoc, the caller saw empty stdout, and
    # `_rs_origin_slug` rendered "no python3, or it would not load" — two things that were both false
    # (python3 resolved; the module imported cleanly). That is the stale-farmed-sibling class the
    # per-verb sentinels already cover for `strip`/`norm`/`tags`, and it is reachable exactly there.
    # The `else` clause keeps the success path's bytes unchanged.
    try:
        slug, why = mod._origin_slug(arg)
    except Exception:
        sys.stdout.write("\tpr-doctor.py's `_origin_slug` is missing, or it raised")
    else:
        sys.stdout.write(("%s\t" % slug) if slug else ("\t%s" % why))
PY_PROOF
}

_rs_with_doctor() {
  local verb="${1:-}" arg="${2:-}" doc py
  doc="$(_rs_doctor_py)"
  [ -n "$doc" ] || return 0
  # ⛔ THE SAME RESOLUTION THE WRAPPER USES (review round 8, P2). `command -v python3` alone fails on the
  # launchd-shaped PATH this whole unit exists to survive, and because an empty answer means "no proof"
  # the provenance arm silently downgraded from REFUSE to WARN and the tag guard silently no-op'd — so
  # the wrapper announced a pass for a set the doctor then refused wholesale. An absolute fallback is
  # not a nicety here; it is the difference between a proof and a silent skip.
  py="$(_rs_py_resolve)"
  [ -n "$py" ] || return 0
  # ⛔ `PYTHONUTF8=1` IS PART OF THE PROOF, NOT A TIDY-UP (review round 41, P2 — measured fail-open).
  # The value travels on ARGV, and under an ambient `LC_ALL=POSIX` (the launchd/cron default shape this
  # unit exists to survive) CPython decodes argv with surrogateescape, so a UTF-8 NBSP arrives as
  # `\udcc2\udca0`: `str.strip()` sees no whitespace, `re.split` sees one part, and the delegated guards
  # become NO-OPS. Measured end to end on a value with a trailing NBSP separator: `LC_ALL=C.UTF-8` ->
  # `REFUSED set … a value contains a separator`, rc 1; `LC_ALL=POSIX` -> `repo-set: OK — 1 repo(s)`,
  # rc 0. Same bytes, opposite verdicts, and the permissive one wins on the box's default locale — a
  # child that reads the value differently from the caller is not a proof. UTF-8 mode fixes the DECODE
  # (surrogateescape still applies to invalid bytes, so no path is lost), and it is scoped to this one
  # child so nothing else inherits it.
  # ⚠️ THE `PYTHONUTF8=1` ITSELF LIVES IN `_rs_proof_child` ABOVE: the heredoc had to leave `$( )` so
  # bash 3.2 could parse this file, which moved the invocation with it. The reasoning is unchanged.
  local out rc
  out="$(_rs_proof_child "$py" "$doc" "$verb" "$arg")"
  rc=$?
  # ⛔ A CHILD THAT CANNOT BE RUN ANSWERS NOTHING, AND "NOTHING" IS AN ANSWER FOR THREE VERBS (round 45,
  # P1 — measured). Every arm ABOVE distinguishes the ways the child fails AFTER it starts — the module
  # will not load, the function is missing, it raised — because each of those writes its own sentinel.
  # None of them covers the interpreter that RESOLVES and cannot EXEC: the child never runs, no sentinel is
  # written, stdout is empty, and `tags` read that empty answer as "no collision". MEASURED through a
  # `python3` shim that exits 127 (the shape `m47` builds) over a tag-colliding set: `repo-set: OK — 2
  # repo(s)`, rc 0, and the whole-set tag WARN never printed — while the splitter round-trip in the SAME
  # run warned, so one guard said "unaskable" and the other said "nothing to report" about one dead child.
  # Round 16's own ruling — a missing or raising `set_tag_collisions` MUST NOT look like "no collision" —
  # was still open for the cannot-run route.
  # ⛔ THE EXIT STATUS IS THE DISCRIMINATOR, NOT A SECOND GUESS AT THE CAUSE: every LEGITIMATE empty
  # answer here comes with exit 0 (`set_tag_collisions` returning "" is "no collision"; `str.strip` and
  # `_normalize_slug` returning "" are answers too). Empty stdout AND a non-zero status means the question
  # was never asked. `origin` and `split` are deliberately EXCLUDED: their empty answer is mapped
  # shell-side (`_rs_origin_slug`'s residue, `_rs_split_entries`'s sentinel), and a sentinel here would be
  # read as a slug or as an entry list.
  if [ -z "$out" ] && [ "$rc" -ne 0 ]; then
    case "$verb" in
      tags|strip|norm) out="__UNASKABLE__" ;;
    esac
  fi
  printf '%s' "$out"
}

# _rs_origin_slug <checkout> — the `owner/name` this checkout's `origin` PROVES, or "" and a reason.
# The SAME function `pr-doctor` grades with, so the two verdicts are one verdict.
_rs_origin_slug() {
  local dir="${1:-}" out
  if [ -z "$dir" ]; then printf '\tno checkout was named'; return 0; fi
  out="$(_rs_with_doctor origin "$dir")"
  # ⛔ NAME THE SEAM BEFORE THE SIBLING (round 42, P2 — the misdiagnosis round 41 fixed one layer up,
  # found again here). With a typo'd `REPO_SET_DOCTOR` there is no doctor to ask AND no sibling fallback,
  # so the branch below reported "was not found beside this reader" — sending an operator to hunt a
  # sibling that is present. Same cause, same sentence as the whole-set WARN.
  if [ -z "$out" ] && [ -n "${REPO_SET_DOCTOR:-}" ] && [ ! -f "$REPO_SET_DOCTOR" ]; then
    printf '\t`REPO_SET_DOCTOR` is set to %s, which is not a file, so no origin can be asked' "$REPO_SET_DOCTOR"
    return 0
  fi
  if [ -z "$out" ] && [ -z "$(_rs_doctor_py)" ]; then
    printf '\tpr-doctor.py was not found beside this reader, so no origin can be proved'
    return 0
  fi
  if [ -z "$out" ]; then
    # ⛔ THIS IS A RESIDUE, SO IT MUST NOT NAME A CAUSE — BUT "NO CAUSE" IS NOT THE SAME AS "NO THIRD BRANCH"
    # (review round 44, P2 — measured, and the first repair here was itself incomplete). It first said `the
    # proof child did not start`, and with an unloadable sibling BOTH that message AND the whole-set `would
    # not LOAD` WARNs appeared in ONE run — the child started, imported and raised. The repair made it a bare
    # residue ("cannot see why") — and a reviewer then showed a shape where the reader CAN see why: the
    # sibling is PRESENT and `_rs_py_resolve` is empty, so the very next whole-set WARN says `or no python3
    # resolves` while this line said it could not see. A residue is for what is genuinely unaccounted for,
    # not for the one remaining named cause.
    # ⛔ AND THE RESIDUE MUST NOT CLAIM IT "COULD BE RUN" EITHER (round 45, P2 — measured): `python3` can
    # RESOLVE and still fail to EXEC (a broken or blocked interpreter), and then the reader has verified
    # nothing about whether the sibling could run. That shape reaches this line, so the sentence names no
    # cause at all — `m47` pins it, and the named branch above is only for the case the reader can prove.
    if [ -z "$(_rs_py_resolve 2>/dev/null)" ]; then
      printf '\tno python3 resolves here, so pr-doctor.py could not be RUN at all'
      return 0
    fi
    printf '\tpr-doctor.py produced no answer, and this reader cannot see why'
    return 0
  fi
  printf '%s' "$out"
}

# _rs_tag_collision <comma-joined entries> — the doctor's own SET-LEVEL guard, delegated. It refuses a
# set whose repo TAGS collide (`acme/tools-api` and `acme-tools/api` both render `acme-tools-api`, so
# their registers, worker names and status files are one file), and it is the ONE whole-set refusal the
# reader cannot express from its own arms — so a set this reader certified could still be refused
# wholesale by the doctor, which made the wrapper's "grading N repo(s)" false (review round 7).
_rs_tag_collision() {
  local entries="${1:-}"
  [ -n "$entries" ] || return 0
  _rs_with_doctor tags "$entries"
  return 0
}

# _rs_split_entries <comma-joined entries> — the entries the DOCTOR'S OWN splitter
# (`configured_repos`, which splits on `re.split(r"[,\s]+")` and dedupes by normalized key) yields.
# The reader refuses `,` inside a value, but that enumerates ONE character class of a splitter that
# also splits on `\v`, `\f`, `\r` and Unicode whitespace — measured in review round 8, an NBSP inside
# a checkout path passed every arm, produced `grading 1 repo(s)`, and the doctor split it into a
# TRUNCATED real entry plus a phantom repo it then refused. Round-tripping the rendered list through
# the doctor's own splitter is the check that cannot drift — which is only true because the `split`
# verb CALLS `configured_repos` rather than copying its regex (it copied it until round 10).
# ⛔ THE `splitcount` VERB IS GONE (round 10). Round 9 replaced the count comparison with
# `_rs_split_divergence`, which compares ENTRIES, so nothing called `_rs_split_count` any more — and
# leaving a second, regex-copying splitter in the file is how a dead copy gets revived and silently
# becomes the authority again. One splitter, one authority.
# ⛔ AN EMPTY ANSWER FROM A VERB THAT CANNOT LEGITIMATELY BE EMPTY IS "COULD NOT ASK", NOT "NO
# ENTRIES". `configured_repos()` always yields at least one entry for a non-empty list, so an empty
# result means the sibling module lacks the function or it raised — and the caller must treat that
# exactly like an unavailable doctor (WARN, do not refuse), not like a divergence. Measured: a sibling
# without `configured_repos` made every legitimate two-repo set refuse with "entry 1 ... reads it as
# <empty>", on any consumer that carries this file without a current doctor beside it.
_rs_split_entries() {
  local entries="${1:-}" out
  [ -n "$entries" ] || return 0
  out="$(_rs_with_doctor split "$entries")"
  if [ -z "$out" ]; then printf '%s' "__UNASKABLE__"; return 0; fi
  printf '%s' "$out"
  return 0
}

# _rs_split_divergence <rendered> <expected-newline-joined> — "" when the doctor's own splitter
# reproduces EXACTLY the entries we meant to render, a non-empty `index<TAB>got<TAB>want` report for the
# first entry that differs, or the `__UNASKABLE__` sentinel (the question could not be answered).
#
# ⛔ "" IS RESERVED FOR "NO DIVERGENCE", AND AN EMPTY FIELD IS NOT A LEGIBLE DIFFERENCE (review
# round 12, P2). ⚠️ THIS IS ABOUT THE MESSAGE, NOT THE VERDICT — and the comment must say which, because
# the two were the SAME bug only in the pre-index shape. There, the report was `printf … "$line" …`,
# so a divergence whose `$line` was empty printed NOTHING and the caller's `[ -n "$diverged" ]` read
# it as agreement: measured, `OK — 2 repo(s)` at rc 0 with no message. Round 10 then made the report
# start with the entry INDEX (`printf '%s\t…' "$i" …`), and THAT is what guarantees a non-empty report
# — so the false pass is closed structurally, by the index, and a revert here no longer re-opens it
# (measured: with `"$line"` restored, rc is still 1).
# What `${line:-<empty entry>}` still buys, and why it stays: without it the refusal reads
#   `` the doctor reads it as `` where `o/b=…` was named ``
# i.e. it names an empty hole instead of the fault, which is the operator-facing half of the same
# finding. With it: `the doctor reads it as <empty entry> where o/b=… was named`.
# ⛔ KNOWN RESIDUAL, DOCUMENTED RATHER THAN PROMISED AWAY: a TRAILING empty entry is invisible here,
# because `got="$(…)"` strips trailing newlines — `['e1','e2','']` captures as `e1\ne2` and compares
# equal. A LEADING or MIDDLE empty entry IS caught (measured). It is unreachable on the SHIPPED path —
# not because `configured_repos()` cannot emit a trailing empty (it CAN: `raw.strip()` strips
# whitespace, not the join comma, so `PR_DOCTOR_REPOS="a=1,b=2,"` yields a trailing empty entry —
# pr-doctor.py:724-727), but because the READER never renders a trailing separator to ask about:
# `repo_set_doctor_repos` comma-joins with no trailing `,`, and a value cannot contain one
# (`SEPARATOR-IN-VALUE`). So the hole is in the guard's coverage of a shape the doctor could describe,
# not in the question the reader actually asks — closing it needs the entry COUNT to travel across the
# delegation seam rather than be recovered from a newline-stripped capture. ("Could not ask" is a
# DIFFERENT case, handled above by `__UNASKABLE__`: one sentinel, not two.)
#
# ⛔ BY ENTRIES, NOT BY COUNT (review round 9, P2). The count-only round-trip could not see a separator
# at the END of a value: `repo_set_doctor_repos` joins with `,`, so `/x/decoy ` + `,` is one `[,\s]+` run
# and the count stayed `n` — the value was silently TRUNCATED to `/x/decoy` (the doctor strips it
# again), so `check` returned 0 on a set whose checkout proved a DIFFERENT repo. Comparing the actual
# entries to the intended ones catches truncation, insertion and reordering alike — EXCEPT a TRAILING
# empty entry, which the capture strips (see the residual above); do not restate this as unconditional.
_rs_split_divergence() {
  local rendered="${1:-}" expected="${2:-}" got
  got="$(_rs_split_entries "$rendered")"
  if [ "$got" = "$expected" ]; then return 0; fi
  # ⛔ THE INDEX TRAVELS WITH THE ENTRY (review round 10, P2). It used to return only the offending
  # entry, and the caller paired it with the FIRST expected line — so a fault on line 2 was reported
  # against line 1, sending the operator to the wrong config line.
  # the sentinel means "the doctor could not be asked": it is NOT a divergence, and the caller WARNs
  if [ "$got" = "__UNASKABLE__" ]; then printf '%s' "__UNASKABLE__"; return 0; fi
  local i=1 line want
  while IFS= read -r line; do
    want="$(printf '%s\n' "$expected" | sed -n "${i}p")"
    if [ "$line" != "$want" ]; then printf '%s\t%s\t%s' "$i" "${line:-<empty entry>}" "$want"; return 0; fi
    i=$(( i + 1 ))
  done <<EOF_GOT
$got
EOF_GOT
  printf '%s\t%s\t%s' "$i" "(no entry at this position)" "$(printf '%s\n' "$expected" | sed -n "${i}p")"
  return 0
}

# _rs_strip <value> — `str.strip()` exactly as `resolve_repo()` applies it to all four seams. The sed
# form the wrapper used does not strip a NON-ASCII space, so a single trailing U+00A0 in `REPO` made the
# wrapper refuse a pass the doctor ran (review round 9, P2).
_rs_strip() {
  local v="${1:-}"
  [ -n "$v" ] || return 0
  _rs_with_doctor strip "$v"
  return 0
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
#     UNVERIFIABLE, all a WARN. What the PASS then does is the doctor's to say — it may adopt another
#     checkout for the slug (`REPO`, then the cwd, through `_checkout_that_proves()`) and SPAWN, or
#     grade read-only; this reader states only what it measured, and makes no promise about the pass.
#     The split is the one `resolve_repo()` makes, and the reason is measured twice over: launchd has no Full Disk Access
#     under `~/Documents` (the default checkout), so refusing there discarded a pass the doctor
#     completes. "I could not look" must never be reported as "it is wrong".
#   * the rendered list round-trips through the DOCTOR'S OWN splitter as exactly the entries declared,
#     and the doctor's own `set_tag_collisions` accepts it — the two whole-set proofs the per-line arms
#     cannot express (both delegated, both hard `rc 1`). ⛔ When the doctor CANNOT be asked they are
#     SKIPPED WITH A WARN, never silently green — "could not ask" is not "the proof held";
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
  # `awk` is needed HERE and in `repo_set_doctor_repos` to render the entry list. Checked before anything
  # is proved, because the empty-render fallback below is a REFUSAL, not a comparison.
  _rs_require awk "it renders the \`slug=checkout\` entry list the splitter round-trip compares against, so without it both sides of that proof are empty and a set this reader refuses would be certified OK." || return 5
  parsed="$(repo_set_parse)"; rc=$?
  # ⛔ PROPAGATE 3/4/5, never fold them into 1 (see RETURN CODES): a consumer must be able to tell a
  # box that names no repo (degrade / report) from one whose file is broken (refuse).
  if [ "$rc" != 0 ]; then return "$rc"; fi

  local f; f="$(repo_set_file)"
  local bad=0 n=0 slug checkout state seen_states="" seen_state_spell=""

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
    # So: a checkout of a DIFFERENT repo refuses (the only proven fault about a checkout);
    # UNVERIFIABLE warns, and this reader makes no promise about what the pass then does — the doctor
    # may adopt `REPO`/cwd for the checkout and spawn, or grade read-only.
    # ⛔ NOTHING ABOUT THE CHECKOUT'S EXISTENCE REFUSES (review round 4, P1; round 3, P1). Round 3 moved
    # this refusal off `git rev-parse` and onto `test -e` — which is the SAME defect one syscall over:
    # macOS TCC denies at the ANCESTOR (`~/Documents`), so `stat` fails with EACCES, `-e` is false, and
    # the reader printed a false "does not exist" and refused the WHOLE set while the doctor handed the
    # same entry a complete read-only pass. And a sandbox is entitled to answer ENOENT for a denied
    # path, so even an errno-aware test cannot PROVE absence from inside it.
    #
    # THE RULE, THEN, AND IT IS THE WHOLE RULE: only a PROVEN fault refuses. A slug the doctor's own
    # `_origin_slug()` returns that differs from the declared one is proven. Everything else — absent,
    # denied, not a directory, no `origin`, no `git`, no `python3` — is UNVERIFIABLE and warns, and
    # nothing is promised about what the pass then does (the doctor may adopt `REPO`/cwd and spawn).
    #
    # ⛔ AND A WARN IS A STATEMENT ABOUT THIS ENTRY'S CHECKOUT, NOT ABOUT THE PASS. The doctor resolves
    # each entry through `_checkout_that_proves()`, which falls back to `REPO` and then the cwd, so it
    # may still find a spawnable checkout for this slug and may grade read-only if it does not. The
    # reader cannot know which; promising "nothing will be spawned" was overreach (review round 5).
    local proof why
    proof="$(_rs_origin_slug "$checkout")"; why="${proof#*$'\t'}"; proof="${proof%%$'\t'*}"
    if [ -n "$proof" ]; then
      # ⛔ NORMALISE THE DECLARED SLUG BEFORE COMPARING (round 25, P2). The parse-time dedupe key is
      # `_rs_normalize_slug "$slug"` BECAUSE `owner/name`, `owner/name.git`, a host prefix and a URL
      # are ONE repo to the doctor — so comparing the RAW slug here made the same string "one repo"
      # to one arm and "a different repo" to another. Measured: `slug=acme/alpha.git` over a checkout
      # whose origin proves `acme/alpha` was REFUSED with "is a checkout of acme/alpha, not
      # acme/alpha.git" (rc 1, wrapper exit 2) while the doctor would have graded it — the
      # "reader refuses a pass the doctor runs" class. ⛔ AN UNNORMALISABLE ANSWER MAKES THE COMPARISON
      # UNPROVEN, AND THIS ARM WARNS INSTEAD OF COMPARING (round 29) — it does NOT fall back to a raw
      # comparison. (Round 25's note here said it did, which round 29 made false; the `slug_n="$slug"`
      # assignment that implemented the old behaviour is gone too, because the only branch that reads
      # `slug_n` is the `elif`, which runs precisely when nothing set `norm_why`.)
      local slug_n norm_why=""
      slug_n="$(_rs_normalize_slug "$slug")"
      case "$slug_n" in
        ''|'__UNASKABLE__')
          # ⛔ AN UNNORMALISABLE DECLARED SLUG MAKES THE COMPARISON UNPROVEN, SO IT WARNS (round 29, P2).
          # The proof says `acme/alpha`; the declared slug is `acme/alpha.git`; without normalisation we
          # cannot tell "same repo, different spelling" from "different repo" — and "only a PROVEN fault
          # refuses" is a recorded decision in this file. Falling back to a RAW comparison refused the
          # `.git` case, undoing round 25's fix in exactly the state (a loadable-but-stale sibling) it
          # was most likely to be needed. Measured before: that pair printed `REFUSED … is a checkout of
          # acme/alpha, not acme/alpha.git` — a false proof claim.
          norm_why="the declared slug could not be normalised (the sibling pr-doctor.py lacks _normalize_slug, or it raised), so whether this checkout proves it is UNPROVEN" ;;
      esac
      if [ -n "$norm_why" ]; then
        printf 'repo-set: WARN CHECKOUT-UNVERIFIED — %s: `%s` proves %s; %s\n' "$slug" "$checkout" "$proof" "$norm_why"
      elif [ "$(_rs_lower "$proof")" != "$(_rs_lower "$slug_n")" ]; then
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
      # are one directory, so a raw comparison passed the collision this arm refuses; the state KEY
      # collapses them (it folds `//`, `.`, `..` and symlinks), and `_rs_lower` covers APFS/HFS+.
      # ⛔ AND SO DO `..` AND SYMLINKS (round 6, P2). Those two are one directory with their target
      # and a spelling-only comparison cannot see it — it never touches the filesystem — so both
      # passed as `ok`. `_rs_state_key` is the identity walk that closes it: it resolves every prefix
      # that exists (so `..` and symlinks are PHYSICAL, not textual) and folds the not-yet-created
      # remainder lexically; `_rs_lower` still folds case on top, which is what keeps the APFS arm
      # working for a directory that does not exist yet.
      # ⛔ AN UNPROVABLE KEY WARNS AND IS LEFT OUT OF THE IDENTITY DEDUPE (round 9, P2).
      # `_rs_state_key` prints nothing when a component is PRESENT but unenterable (EACCES/EPERM/ELOOP
      # — the TCC shape). Omitting the IDENTITY key is deliberately NOT a refusal: a permission denial
      # is not a fact about the set, and "only a PROVEN fault refuses" is a recorded decision here.
      # ⛔ BUT OMITTING IT MUST NOT DISCARD WHAT IS STILL PROVABLE (round 10, P2). Dropping the entry
      # entirely turned a REFUSAL into rc 0 for a class that needs no filesystem at all: two entries
      # spelled the same after folding `//`, `.`, a trailing `/` and case ARE one directory, whether
      # or not this process may enter it. Measured before this second axis existed, with the ancestor
      # mode 000: `state=$T/denied/state` TWICE returned `OK — 2 repo(s)` at rc 0 (and the round-8
      # reader refused it), while the same fixture traversable refused. So there are now TWO axes:
      #   * SPELLING — always computed, and PROOF on its own. Identical after folding `//`, `.`, a
      #     trailing `/` and case cannot be two directories.
      #   * IDENTITY — the resolved key, only when provable, which is what catches `..`, symlinks and
      #     a case-differing spelling of a directory this process CAN enter.
      # A match on either refuses. Only an entry that matches neither AND has no identity key warns.
      local norm_state spell_state shared=""
      norm_state="$(_rs_lower "$(_rs_state_key "$state")")"
      spell_state="$(_rs_lower "$(_rs_norm_path "$state")")"
      if [ -n "$spell_state" ]; then
        case "$seen_state_spell" in *$'\n'"$spell_state"$'\n'*) shared="spelling" ;; esac
      fi
      if [ -n "$norm_state" ]; then
        case "$seen_states" in *$'\n'"$norm_state"$'\n'*) shared="identity" ;; esac
      fi
      if [ -n "$shared" ]; then
        problems="$problems; state=$state is shared with another repo in this set — the same silent-sharing failure two controllers would hit"
      elif [ -z "$norm_state" ]; then
        printf 'repo-set: WARN STATE-UNVERIFIED — %s: could not resolve `%s` to a directory identity (present but not enterable), so it is NOT checked for a share with another repo beyond its own spelling; give it a path this process can traverse\n' "$slug" "$state"
      fi
      if [ -n "$spell_state" ]; then seen_state_spell="$seen_state_spell"$'\n'"$spell_state"$'\n'; fi
      if [ -n "$norm_state" ]; then seen_states="$seen_states"$'\n'"$norm_state"$'\n'; fi
    fi

    if [ -n "$problems" ]; then
      # ⛔ STRIP THE LEADING SEPARATOR BEFORE PRINTING (round 24, P2). `problems` is accumulated as
      # `problems="$problems; …"`, so the raw value starts with `; ` and every refusal rendered as
      # `REFUSED <slug> —; reason` — a doubled separator on the one line an operator reads. Flagged as
      # cosmetic in round 1 and left; it is cheap and it is the operator's first impression.
      printf 'repo-set: REFUSED %s — %s\n' "$slug" "${problems#; }"
      bad=1
    else
      printf 'repo-set: ok %s -> %s%s\n' "$slug" "$checkout" "${state:+ (state $state)}"
    fi
  done <<EOF
$parsed
EOF

  # ⛔ THE DOCTOR'S OWN SET-LEVEL GUARD RUNS HERE TOO (review round 7, P2). `set_tag_collisions` is
  # the one whole-set refusal the arms above cannot express, and without it a set this reader called OK
  # was refused wholesale by the doctor — so the wrapper's "grading N repo(s)" was false and nothing
  # was graded. Delegated for the same reason every other proof is: one rule, one home.
  # ⛔ THE SHAPE ROUND-TRIP (review round 8, P2): the rendered list must yield exactly `n` entries under
  # the doctor's OWN splitter. Anything that adds or removes one — a separator the reader does not
  # enumerate, a value that splits — makes the graded set different from the validated one, which is the
  # "a shorter set reads like a smaller machine" failure in the other direction.
  # ⛔ "COULD NOT ASK" IS NOT "THE PROOF HELD" (review round 10, P2). Both delegated whole-set proofs go
  # quiet when the sibling doctor or an interpreter is missing, and `diverged=""` / `tagwhy=""` then read
  # as success — a green verdict this reader cannot support. The origin proof already tells the
  # difference out loud; these two now do the same.
  # ⛔ AND WHEN IT CANNOT BE ASKED, THE PROOFS ARE SKIPPED — NOT RUN AGAINST AN EMPTY ANSWER. The first
  # cut of this guard printed the WARN and then still compared, so `_rs_split_entries` returned "" and
  # the reader refused the set on "the doctor reads it as `` " — i.e. "could not ask" resolved to a
  # REFUSAL, which is the same false-verdict class in the other direction (measured in review: it killed
  # two unrelated mutation arms, and would have refused every legitimate set on any consumer that
  # carries this file without the doctor beside it).
  local rendered="" expected="" diverged=""
  if _rs_doctor_available; then
    rendered="$(repo_set_doctor_repos 2>/dev/null)"
    expected="$(printf '%s\n' "$parsed" | awk -F'\t' 'NF{print $1 "=" $2}')"
    # ⛔ TWO EMPTY STRINGS ARE NOT AN AGREEMENT (review round 42, P2 — measured FALSE PASS).
    # `_rs_split_divergence` compares the rendered list with the expected one, so when a render FAILS
    # both sides are empty, they compare EQUAL, and the round-trip "passes" by vacuity: with `awk` off
    # PATH a set this reader REFUSES at rc 1 (tag collision) was certified `OK — 2 repo(s)`, rc 0. The
    # guard above refuses a missing `awk`; this one is the second line of defence, because ANY future
    # reason for an empty render (a `parsed` the renderer cannot express, a child killed mid-pipe) lands
    # here too. `parsed` is non-empty at this point — an empty set returned 4 long before — so an empty
    # side means the render did not happen, which is unaskable, never agreement.
    if [ -n "$parsed" ] && { [ -z "$rendered" ] || [ -z "$expected" ]; }; then
      diverged="__UNASKABLE__"
    else
      diverged="$(_rs_split_divergence "$rendered" "$expected")"
    fi
  else
    # ⛔ NAME THE CAUSE, DO NOT RECITE THE CANDIDATES (review round 40, P2). The generic sentence below
    # lists "not beside this reader, or no python3 resolves". A seam naming a file that does not exist
    # is NEITHER, so an operator holding that message would go looking for a missing sibling that is
    # present. The seam is a test injection point (see the header), so this is the one branch where the
    # reader can say exactly what happened without inspecting anything new.
    if [ -n "${REPO_SET_DOCTOR:-}" ] && [ ! -f "$REPO_SET_DOCTOR" ]; then
      printf 'repo-set: WARN WHOLE-SET-PROOFS-SKIPPED — `REPO_SET_DOCTOR` is set to `%s`, which is not a file, so the proof cannot be asked at all. This is a TEST INJECTION SEAM, not an operator setting: unset it to let the sibling pr-doctor.py answer, or point it at a real one. The per-line arms still ran; this verdict is INCOMPLETE and says so.\n' "$REPO_SET_DOCTOR"
    else
      printf 'repo-set: WARN WHOLE-SET-PROOFS-SKIPPED — the two set-level proofs (the doctor splitter round-trip and `set_tag_collisions`) could NOT be run: pr-doctor.py is not beside this reader, or no python3 resolves. The per-line arms still ran; this verdict is INCOMPLETE and says so.\n'
    fi
  fi
  if [ "$diverged" = "__UNASKABLE__" ]; then
    printf 'repo-set: WARN WHOLE-SET-PROOFS-SKIPPED — `configured_repos()` could not be asked (the sibling pr-doctor.py lacks it, or it raised, or it would not LOAD, or the interpreter that RESOLVES could not RUN it), so the splitter round-trip did NOT run. The per-line arms still ran; this verdict is INCOMPLETE and says so.\n'
    diverged=""
  fi
  if [ -n "$diverged" ]; then
    local dline dgot dwant
    dline="${diverged%%$'\t'*}"; diverged="${diverged#*$'\t'}"
    dgot="${diverged%%$'\t'*}"; dwant="${diverged#*$'\t'}"
    printf 'repo-set: REFUSED set — entry %s of this set does not survive the list format: the doctor reads it as `%s` where `%s` was named. A value contains a separator `configured_repos()` splits on (a `,` or any whitespace, including a non-ASCII space).\n' \
      "$dline" "$dgot" "$dwant"
    bad=1
  fi

  local tagwhy
  tagwhy="$(_rs_tag_collision "$rendered")"
  if [ "$tagwhy" = "__UNASKABLE__" ]; then
    # ⛔ "COULD NOT ASK" IS NOT "NO COLLISION" (round 16, P2). The tag guard's failure mode is SHARED
    # STATE — one register, one worker name, one cooldown for two repos — so a silent pass here is
    # strictly worse than a loud one. It WARNS rather than refuses, the same rule as the splitter
    # round-trip: a broken/absent sibling is not a fact about the set.
    printf 'repo-set: WARN WHOLE-SET-PROOFS-SKIPPED — `set_tag_collisions()` could not be asked (the sibling pr-doctor.py lacks it, or it raised, or it would not LOAD, or the interpreter that RESOLVES could not RUN it — `command -v` proves resolution, never runnability), so the tag-collision proof did NOT run; a TAG collision between repos in this set would go undetected. The per-line arms still ran; this verdict is INCOMPLETE and says so.\n'
  elif [ -n "$tagwhy" ]; then
    printf 'repo-set: REFUSED set — %s\n' "$tagwhy"
    bad=1
  fi

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
  # ⛔ THE ONE `awk` CALL SITE WITH NO GUARD (review round 43, P2 — measured). Its sibling below refused
  # by name at rc 5; this verb ran `awk` bare, so with `awk` off PATH it printed an empty list and exited
  # **127** with no `repo-set:` line at all — a code the RETURN CODES table does not define, and a
  # consumer that reads stdout without re-checking rc reads "this set names no repos".
  _rs_require awk "it renders the slug list this verb exists to produce; without it the list would be EMPTY, and an empty list reads as a set that names no repos." || return 5
  parsed="$(repo_set_parse)"; rc=$?
  [ "$rc" = 0 ] || return "$rc"
  printf '%s\n' "$parsed" | awk -F'\t' 'NF{print $1}'
}

repo_set_doctor_repos() {
  local parsed rc
  _rs_require awk "it renders the comma-joined \`slug=checkout\` list this verb exists to produce; without it the list would be EMPTY, and an empty PR_DOCTOR_REPOS reads as a valid set of no repos." || return 5
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
