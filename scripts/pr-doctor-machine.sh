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
    _seam="$(printf '%s' "${PR_DOCTOR_REPO:-}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    _or="$(printf '%s' "${OR:-}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    _proved=""; _proved_why=""
    if [ -n "${REPO:-}" ]; then
      # The reader's own proof function — the same one `check` uses, so the two cannot disagree.
      _p="$(_rs_origin_slug "$REPO")"; _proved_why="${_p#*$'	'}"; _proved="${_p%%$'	'*}"
    fi
    if [ -n "$_seam" ]; then
      if _rs_slug_ok "$_seam"; then
        _degraded="$_seam"; _say "  Grading the ONE repo this unit declares in PR_DOCTOR_REPO=$_seam."
      else
        _why_not="PR_DOCTOR_REPO='$_seam' is not an owner/name slug"
      fi
    fi
    # ⛔ AN `OR` THAT IS SET CONSUMES RANK 3, so it is decisive — valid-and-agreeing, or a refusal.
    # It is NOT a hurdle to fall past: pr-doctor enters its rank-3 arm whenever `OR` is present and
    # refuses an invalid one or a pair that names two repos, so falling through to `REPO`'s proof here
    # would pick a repo the doctor then refuses (measured in review round 3: `OR=tortoise` with a
    # `REPO` checkout of agent-infra ran, where the doctor refuses the pair).
    _or_decisive=0
    if [ -z "$_degraded" ] && [ -n "$_or" ]; then
      _or_decisive=1
      if ! _rs_slug_ok "$_or"; then
        _why_not="OR='$_or' is not an owner/name slug"
      elif [ -n "$_proved" ] && [ "$(_rs_lower "$_proved")" != "$(_rs_lower "$_or")" ]; then
        _why_not="the box names two different repos: OR=$_or but REPO=$REPO is a checkout of $_proved"
      else
        _degraded="$_or"; _say "  Grading the ONE repo this unit declares in OR=$_or."
      fi
    fi
    if [ -z "$_degraded" ] && [ "$_or_decisive" = 0 ] && [ -n "$_proved" ]; then
      _degraded="$_proved"; _say "  Grading the ONE repo REPO proves: $_proved (from $REPO)."
    fi
    if [ -z "$_degraded" ]; then
      if [ -n "$_why_not" ]; then _say "  $_why_not — so this pass has NO usable repo."; fi
      if [ -n "${REPO:-}" ] && [ -z "$_proved" ]; then
        _say "  REPO=$REPO proves no repo ($_proved_why)."
      elif [ -z "${REPO:-}" ] && [ -z "$_seam" ] && [ -z "$_or" ]; then
        _say "  Neither PR_DOCTOR_REPO, OR nor REPO is set — so this pass has NO repo to name."
      fi
      _say "REFUSING — a pass with no usable repo would exit 2 on its first line, having graded nothing."
      _say "  Fix, either way:"
      _say "    (1) create the repo set above — one line per repo this box serves; or"
      _say "    (2) set PR_DOCTOR_REPO=OWNER/NAME or OR=OWNER/NAME (or point REPO at a checkout whose git origin proves it)."
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
