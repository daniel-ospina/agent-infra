#!/usr/bin/env bash
# pr-doctor-machine.sh — the MACHINE-scoped pr-doctor entry point (agent-infra#2281 §1).
#
# ⛔ THE DEFECT THIS REPLACES. The shipped `com.tortoise.pr-doctor` unit asserted its repo in argv:
#
#     <string>--repo</string><string>daniel-ospina/tortoise</string>
#
# so on ANY box the doctor graded exactly one repo, whatever that box's controllers actually served.
# Measured on a cell whose `keys.env` declares `OR=daniel-ospina/agent-infra` while its controller was
# started for `daniel-ospina/tortoise`: the doctor logged `repo: daniel-ospina/tortoise (from --repo)`
# on every pass while the second repo's queue was read by nothing at all. #2280 fixed WHICH repo the
# resolver picks; it did not give a multi-repo box more than one. §1 asks for "one unit rendered from
# a versioned template with the repo set as a parameter" — the repo set is
# `scripts/lib/repo-set.sh` (§4), and this file is the doctor's reader of it.
#
# WHAT IT DOES, IN EXACTLY THESE THREE STATES (the three are the design, not error handling):
#
#   set exists and `check()` accepts it   -> grade EVERY repo in it (`--all-repos`). Each repo gets its
#                                            own register, status and log under the fleet state dir
#                                            (`pr-doctor-<owner>-<name>.json`, `pr-doctor.<tag>.status
#                                            .json`, per-repo `#2700`/`#2725`), and the rubric it is
#                                            judged by is decided PER REPO by `contract_note()` and
#                                            reported on its own line. A repo whose rubric the
#                                            classifier cannot hold is still GRADED and is named as
#                                            `REFUSING TO DISPATCH — … tracked: agent-infra#2518`.
#                                            ⛔ That refusal is the truthful half: wiring the
#                                            per-repo rubric is #2518's, and inventing one here
#                                            would grade every PR by a declaration nobody read.
#   set ABSENT, and the box can still name a repo -> the single-repo form, and loudly. It resolves in
#                                            pr-doctor's OWN rank order (`PR_DOCTOR_REPO` rank 2,
#                                            `OR` rank 3, `REPO`'s proved `origin` rank 4), VALIDATES
#                                            the value it is about to advertise, and is LOGGED EVERY
#                                            PASS with the exact file to create. This is the state a box
#                                            is in *before* an operator names its repos, and a doctor
#                                            that stopped grading on upgrade would trade a silent gap
#                                            for an outage.
#   set ABSENT and NOTHING names a repo      -> REFUSE (exit 2), naming both fixes. ⛔ THE WRAPPER
#                                            CHECKED THIS RATHER THAN ASSUMING IT: the doctor's
#                                            REPO-only arm raises when the checkout's `origin` proves
#                                            nothing, so on a box whose checkout launchd cannot READ
#                                            (~/Documents under TCC — the default macOS install)
#                                            the "degraded" pass would have exited 2 before its first
#                                            read while this file claimed it was grading. It was
#                                            measured, not reasoned: review round 2, P1.
#   set exists and is NOT usable          -> REFUSE (exit 2). Never half-honour a broken file: dropping
#                                            a line it cannot parse would grade a shorter set and read
#                                            exactly like a smaller machine.
#
# ⛔ IT TAKES NO ARGUMENTS, AND REFUSES ANY. The unit's argv IS the declaration. A wrapper that
# silently ignored an argument would make a future `--dry-run` in a plist look honoured while a real
# pass ran — the `NOT_A_FLEET_READING` failure pr-doctor.py already guards one layer down.
#
# ⛔ IT MUST NOT RESOLVE THE SET ITSELF. `$HERE/lib/repo-set.sh` is resolved as a sibling so the SAME
# file works in the checkout (`scripts/lib/repo-set.sh`) and on the farm (`$DEST/scripts/lib/…`,
# `pi-bootstrap/setup.sh`'s `lib_srcs`). A second parser here would be the two-authorities defect the
# reader exists to remove — and `check()` is run before every pass, so the list that is graded is the
# list that was validated, not a value that drifted between the two.
#
# ⛔ A FARM GAP IS LOUD, NOT SKIPPED. If the sibling reader is missing the farm did not deliver what
# `lib_srcs` declares; refusing here names that instead of degrading into a one-repo pass that looks
# exactly like a healthy single-repo box.
#
# STDOUT/STDERR go to the plist's capture (`/tmp/pr-doctor.launchd.{log,err}`) — that file is the only
# place an interpreter-level death lands, which is what makes "the wrapper refused" distinguishable
# from "the doctor died on import".
#
# Exit codes: 0 = a pass ran and ended clean; pr-doctor's own rc (2 refuse, 3 blocked, 6 no-capacity,
# …) when it ran and ended otherwise; 2 = this wrapper refused to start a pass at all.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
READER="$HERE/lib/repo-set.sh"
DOCTOR="$HERE/pr-doctor.py"

_say() { printf 'pr-doctor-machine: %s\n' "$*" >&2; }

if [ "$#" -ne 0 ]; then
  _say "REFUSING — this entry point takes no arguments (got: $*). The repo set is the declaration;"
  _say "  pass a repo with \`pr-doctor.py --repo\` directly if that is what you meant. Nothing ran."
  exit 2
fi
if [ ! -f "$READER" ]; then
  _say "REFUSING — $READER is missing: pi-bootstrap/setup.sh's \`lib_srcs\` declares it, so the farm"
  _say "  did not deliver a file this unit depends on. Nothing ran. Re-run pi-bootstrap/setup.sh."
  exit 2
fi
if [ ! -f "$DOCTOR" ]; then
  _say "REFUSING — $DOCTOR is missing (the farm's \`fleet_srcs\` declares pr-doctor.py). Nothing ran."
  exit 2
fi

# The interpreter: the shape the live job was armed with (`env python3`), with the absolute fallbacks
# a launchd job needs because launchd gives a job no PATH of its own.
PY=""
for c in python3 /usr/bin/python3 /usr/local/bin/python3; do
  if command -v "$c" >/dev/null 2>&1; then PY="$(command -v "$c")"; break; fi
done
if [ -z "$PY" ]; then
  _say "REFUSING — no python3 on this box (looked for python3 on PATH, /usr/bin/python3,"
  _say "  /usr/local/bin/python3). Nothing ran."
  exit 2
fi

# ── the reader is sourced ONCE, and every branch below uses ITS verdict ─────────────────────────
# ⛔ NOT a `bash "$READER" check` SUBPROCESS. The distinction the wrapper needs is the reader's OWN
# return code (3 absent / 4 empty / 5 malformed), and a subprocess collapses it to 0/1 — which is how
# a broken file and a missing file become the same branch. One parser, called in-process.
# shellcheck disable=SC1090  # a farmed sibling, resolved above
. "$READER"

# The code probe: the reader's refusal text is printed by the branch that ACTS on the code, so it is
# emitted once and always next to the line that says what this wrapper did about it.
repo_set_parse >/dev/null 2>&1
_rc=$?
case "$_rc" in
  0)
    # The proofs (checkout exists, its origin PROVES the slug, no shared state dir) run BEFORE the
    # pass: a set that is valid on paper but names a checkout that is gone is refused here, not
    # discovered as 40 unreadable PR rows inside the pass.
    if ! repo_set_check 1>&2; then
      _say "REFUSING — $(repo_set_file) exists and is not a usable repo set (see the report above)."
      _say "  Nothing was graded and nothing was dispatched: a shorter set would read exactly like a"
      _say "  smaller machine."
      exit 2
    fi
    repos="$(repo_set_doctor_repos)" || {
      _say "REFUSING — the set validated but rendered no entry list; this is a reader defect, not a"
      _say "  configuration one. Nothing ran."
      exit 2
    }
    _say "set: $(repo_set_file) -> grading $(printf '%s\n' "$repos" | awk -F, '{print NF}') repo(s)"
    PR_DOCTOR_REPOS="$repos"
    export PR_DOCTOR_REPOS
    exec "$PY" "$DOCTOR" --all-repos
    ;;
  3)
    # NO-REPO-SET — the single-repo mode, and ONLY when this box can still name a repo.
    #
    # ⛔ A DEGRADED PASS THAT CANNOT NAME A REPO IS NOT A DEGRADED PASS (review round 2, P1). Removing
    # `--repo` from the plist removed the one datum the doctor cannot derive on a box whose checkout it
    # cannot READ: `resolve_repo`'s REPO-only arm (rank 4) RAISES when the checkout's `origin` proves
    # nothing, so the pass exits 2 before its first read — where the pre-#2281 unit passed `--repo`
    # (rank 1) and then graded the queue READ-ONLY. That is not exotic: `install-launchd.sh` prefers
    # `~/Documents/GitHub/tortoise`, which launchd has no Full Disk Access to (the TCC limitation
    # `pr-doctor.py` and `repo-set.sh` both document). So this branch establishes, BEFORE exec'ing, that
    # a slug is actually available, using the reader's own proof rather than a guess:
    #
    #   * `OR` set and a slug          -> rank 3: the doctor names it (and grades read-only if `REPO`
    #                                     cannot be proven — exactly the old behaviour).
    #   * `REPO` proves its slug       -> rank 4: the doctor names it.
    #   * neither                      -> REFUSE here, by name, instead of printing "grading ..." and
    #                                     letting the doctor die with a resolver message that does not
    #                                     mention the file that fixes it.
    repo_set_parse 1>&2
    _say "DEGRADED — NO-REPO-SET: $(repo_set_file) does not exist, so this box has named no repo set."
    # The wrapper must establish the SAME evidence pr-doctor's resolver will use, in ITS rank order
    # (2 `PR_DOCTOR_REPO`, 3 `OR`, 4 `REPO`'s proved `origin`), and refuse only when that resolution
    # cannot produce a repo. Two easy ways to get this wrong, both MEASURED in review round 3:
    #   * adopting `OR` VERBATIM — an `OR` that is not a slug (`"Not A Slug"`) made this line claim
    #     "Grading the ONE repo" and the doctor then refused, i.e. the exact "claims to grade, grades
    #     nothing" shape the round-2 fix removed from the other arm;
    #   * IGNORING rank 2 — a box with `PR_DOCTOR_REPO` set (which the doctor honours ABOVE `OR`) was
    #     refused here with "no repo to name", while the doctor would have run a full pass.
    _degraded=""
    _why_not=""
    # ⛔ ALL FOUR ARE TRIMMED, BECAUSE `resolve_repo()` TRIMS ALL FOUR (review round 5, P2). The slug
    # seams were trimmed and the two PATH seams were used raw, so a value carrying surrounding
    # whitespace — a CRLF `keys.env` is the measured shape — made the reader's proof fail
    # (`os.path.isdir` on the padded path) while the doctor saw a clean one, and the two reached
    # OPPOSITE verdicts: `OR` + a CR-padded `REPO` printed "Grading the ONE repo …" and the doctor
    # then refused the pair, while a bare CR-padded `REPO` was refused here with "is not a directory"
    # for a path that plainly is one (the CR is invisible in the message). One trim rule, every value.
    # ⛔ `_trim` IS THE DOCTOR'S OWN `str.strip()`, DELEGATED (review round 9, P2). `sed '[[:space:]]'`
    # does not strip a non-ASCII space (U+00A0 and friends) and Python's `strip()` does, so a `REPO` with
    # one trailing NBSP made the wrapper's proof fail on a path the doctor then resolved cleanly — the
    # wrapper REFUSED every pass the doctor would run, on the migration state every box is in today.
    # `_rs_strip` asks the same parser the doctor uses, and falls back to the sed form only when the
    # doctor cannot be asked at all (in which case nothing else here can be proved either).
    _trim() {
      local v="${1:-}" out
      out="$(_rs_strip "$v")"
      if [ -z "$out" ] && [ -n "$v" ]; then
        out="$(printf '%s' "$v" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
      fi
      printf '%s' "$out"
    }
    _seam="$(_trim "${PR_DOCTOR_REPO:-}")"
    _seam_dir="$(_trim "${PR_DOCTOR_REPO_DIR:-}")"
    _or="$(_trim "${OR:-}")"
    _repo="$(_trim "${REPO:-}")"
    _proved=""; _proved_why=""
    if [ -n "$_repo" ]; then
      # The reader's own proof function — the same one `check` uses, and it is pr-doctor's own
      # `_origin_slug()` underneath, so the two cannot disagree.
      _p="$(_rs_origin_slug "$_repo")"; _proved_why="${_p#*$'\t'}"; _proved="${_p%%$'\t'*}"
    fi

    # ⛔ EACH SEAM IS DECISIVE AT ITS OWN RANK, exactly as `resolve_repo()` treats it: rank 2
    # `PR_DOCTOR_REPO` is consulted FIRST and consumes the decision, rank 3 `OR` next, rank 4 `REPO`'s
    # proved origin last. "Decisive" cuts BOTH ways, and the first version of this block got it wrong in
    # both: it adopted `OR` verbatim (an invalid `OR` printed "Grading the ONE repo" while the doctor
    # refused) and it ignored `PR_DOCTOR_REPO` entirely (a box that sets it was refused here while the
    # doctor would have run a full pass). Measured in review rounds 3 and 4.
    #
    # ⛔ AND THE VALUES ARE NORMALISED BY THE DOCTOR'S OWN PARSER (`_rs_normalize_slug` ->
    # `_normalize_slug`). A stricter reader refused `https://github.com/owner/name` where the doctor
    # returns `owner/name` and runs — the reader would have refused a pass, which is the same class as
    # claiming one it cannot deliver.
    _decided=0
    if [ -n "$_seam" ] && [ "$_decided" = 0 ]; then
      _decided=1
      _seam_n="$(_rs_normalize_slug "$_seam")"
      if [ -z "$_seam_n" ]; then
        _why_not="PR_DOCTOR_REPO='$_seam' is not an owner/name slug"
      else
        # Rank 2's checkout, when the launcher named one: a PROVEN disagreement is refused by the
        # doctor too, so it is refused here with both values visible.
        _sd_proof=""
        if [ -n "$_seam_dir" ]; then
          _sd="$(_rs_origin_slug "$_seam_dir")"; _sd_proof="${_sd%%$'\t'*}"
        fi
        if [ -n "$_sd_proof" ] && [ "$(_rs_lower "$_sd_proof")" != "$(_rs_lower "$_seam_n")" ]; then
          _why_not="PR_DOCTOR_REPO=$_seam_n but PR_DOCTOR_REPO_DIR=$_seam_dir is a checkout of $_sd_proof"
        else
          _degraded="$_seam_n"; _say "  Grading the ONE repo this unit declares in PR_DOCTOR_REPO=$_seam_n."
        fi
      fi
    fi
    if [ -n "$_or" ] && [ "$_decided" = 0 ]; then
      _decided=1
      _or_n="$(_rs_normalize_slug "$_or")"
      if [ -z "$_or_n" ]; then
        _why_not="OR='$_or' is not an owner/name slug"
      elif [ -n "$_proved" ] && [ "$(_rs_lower "$_proved")" != "$(_rs_lower "$_or_n")" ]; then
        _why_not="the box names two different repos: OR=$_or but REPO=$_repo is a checkout of $_proved"
      else
        _degraded="$_or_n"; _say "  Grading the ONE repo this unit declares in OR=$_or_n."
      fi
    fi
    if [ "$_decided" = 0 ] && [ -n "$_proved" ]; then
      _degraded="$_proved"; _say "  Grading the ONE repo REPO proves: $_proved (from $_repo)."
    fi

    if [ -z "$_degraded" ]; then
      if [ -n "$_why_not" ]; then _say "  $_why_not — so this pass has NO usable repo."; fi
      if [ -n "$_repo" ] && [ -z "$_proved" ] && [ "$_decided" = 0 ]; then
        _say "  REPO=$_repo proves no repo ($_proved_why)."
      fi
      # ⛔ "NO USABLE REPO", NOT "NO REPO DECLARED" (review round 6, P2). This one block prints from five
      # different states and the first repair told all five a fact that is true of ONE of them: with
      # `PR_DOCTOR_REPO='Not A Slug'` the line above already says a repo IS declared, so "no repo is
      # DECLARED" contradicted the line before it.
      _say "REFUSING — no USABLE repo for this pass."
      _say "  Fix, either way:"
      _say "    (1) create the repo set above — one line per repo this box serves; or"
      _say "    (2) set PR_DOCTOR_REPO=OWNER/NAME or OR=OWNER/NAME (or point REPO at a checkout whose git origin proves it)."
      # ⛔ AND THE CWD NOTE IS PRINTED ONLY WHERE IT IS TRUE (review round 6, P2). `resolve_repo` reaches
      # its rank-5 arm (the current directory's `origin`) only after ranks 2, 3 and 4 answered NOTHING
      # — and rank 4 RAISES when `REPO` is set and proves nothing, so a declared-but-unprovable `REPO`
      # never reaches it. Printing "the doctor would fall back to the cwd" in the arms where the doctor
      # refuses exactly as this wrapper does told the operator the wrapper was the stricter of the two.
      # Nothing declared at all is precisely the state where the two really do differ.
      if [ -z "$_seam" ] && [ -z "$_or" ] && [ -z "$_repo" ]; then
        _say "  (Nothing is declared, so the doctor would fall back to the CURRENT DIRECTORY's git origin;"
        _say "   this wrapper does not adopt an ambient cwd — a working directory is not a declaration.)"
      fi
      exit 2
    fi
    _say "  Create the repo set above and this same unit grades every repo it names, with no reinstall."
    exec "$PY" "$DOCTOR"
    ;;
  *)
    repo_set_parse 1>&2
    _say "REFUSING — $(repo_set_file) exists and is not a usable repo set (see the report above)."
    _say "  Nothing was graded and nothing was dispatched: a shorter set would read exactly like a"
    _say "  smaller machine."
    exit 2
    ;;
esac
