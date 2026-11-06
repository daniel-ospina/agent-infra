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
#   set ABSENT                            -> DEGRADED, and loudly. The pass runs the single-repo form
#                                            and resolves its repo from the box's OWN evidence
#                                            (`REPO`'s git `origin`, then `OR` — pr-doctor's ranks
#                                            4 and 3), which is what this unit did before. This is
#                                            deliberately NOT a refusal: an absent set is the state a
#                                            box is in *before* an operator names its repos, and a
#                                            doctor that stops grading every existing box on upgrade
#                                            would trade a silent gap for an outage. What makes it
#                                            honest is that it is LOGGED EVERY PASS with the exact
#                                            file to create — a degraded mode nobody can see is the
#                                            "installed but inert" state this repo keeps paying for.
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
    # NO-REPO-SET — the documented degraded mode. The reader's own text says which file to create and
    # in what shape, so the whole fix is copy-paste from the capture; this line says what the wrapper
    # DID about it.
    repo_set_parse 1>&2
    _say "DEGRADED — NO-REPO-SET: $(repo_set_file) does not exist, so this box has named no repo."
    _say "  Grading the ONE repo this box's own config declares (REPO's origin, then OR)."
    _say "  Create the file above and this same unit grades every repo it names, with no reinstall."
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
