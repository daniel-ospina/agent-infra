#!/usr/bin/env bash
# pr-doctor-machine.sh — the MACHINE-scoped pr-doctor entry point (agent-infra#2281 §1).
#
# ⛔ THE DEFECT THIS REPLACES. The shipped `com.tortoise.pr-doctor` unit asserted its repo in argv:
#
#     <string>--repo</string><string>daniel-ospina/tortoise</string>
#
# so on ANY box the doctor graded exactly one repo, whatever that box's controllers actually served.
# Measured on a cell whose `keys.env` declares `OR=daniel-ospina/agent-infra` while its controller was
# started for `daniel-ospina/tortoise`: the doctor logged
# `repo: daniel-ospina/tortoise (from --repo; checkout …)` on every pass while the second repo's queue
# was read by nothing at all. #2280 fixed WHICH repo the
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
#                                            `rubric: REFUSING TO DISPATCH -- … Tracked:
#                                            agent-infra#2518` (quoted as EMITTED, review round 22).
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
# ⛔ IT TAKES NO ARGUMENTS, AND REFUSES ANY. THE MACHINE REPO SET IS THE DECLARATION (§4) — NOT this
# entry point's argv (round 19, P2: this line said "the unit's argv IS the declaration", which is the
# PRE-#2281 model and the exact thing this PR removes; the shipped plist names no repo, and this file's
# own arg-refusal text below says "The repo set is the declaration"). An argument here is therefore not
# a SMALLER declaration, it is a SECOND one. A wrapper that
# silently ignored an argument would make a future `--dry-run` in a plist look honoured while a real
# pass ran — the `NOT_A_FLEET_READING` failure pr-doctor.py already guards one layer down.
#
# ⛔ IT MUST NOT RESOLVE THE SET ITSELF. `$HERE/lib/repo-set.sh` is resolved as a sibling so the SAME
# file works in the checkout (`scripts/lib/repo-set.sh`) and on the farm (`$DEST/scripts/lib/…`,
# `pi-bootstrap/setup.sh`'s `lib_srcs`). A second parser here would be the two-authorities defect the
# reader exists to remove — and `check()` is run before every pass. ⛔ ONE PARSER, ONE FORMAT is what
# that buys; it is NOT "the graded list is the same bytes as the validated one" (review round 22, P2):
# the file is read again by `repo_set_doctor_repos`, so a rewrite between the two is not compared. What
# is guaranteed is that both reads use THIS reader's parser, so they cannot disagree about the FORMAT.
#
# ⛔ A FARM GAP IS LOUD, NOT SKIPPED. If the sibling reader is missing the farm did not deliver what
# `lib_srcs` declares; refusing here names that instead of degrading into a one-repo pass that looks
# exactly like a healthy single-repo box.
#
# STDOUT/STDERR go to the plist's capture (`/tmp/pr-doctor.launchd.{log,err}`) — that file is the only
# place an interpreter-level death lands, which is what makes "the wrapper refused" distinguishable
# from "the doctor died on import".
#
# Exit codes: 0 = a pass ran and ended clean; pr-doctor's own rc (2 refuse, 3 UNPLACED — the doctor
# read the queue and placed the work, but no worker took it; 6 no-capacity,
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
# ⛔ `-f` AND `-r` BOTH, BECAUSE `-r` IS TRUE FOR A DIRECTORY (review round 43, P2 — measured). Round 42
# replaced `-f` with `-r` to catch an unreadable doctor, and that swap DROPPED the regular-file test: a
# DIRECTORY at the doctor path is readable, so the wrapper announced `grading 2 repo(s)` and python died
# with `can't find '__main__' module in …` at rc 1 — outside this header's whole contract, and the same
# "pass claim for a run that never started" the round-42 fix was for. Both tests, then.
# ⛔ AND THE READER GATE IS `-e`, so a DIRECTORY there falls through to the sourced probe below and gets
# "cannot be used by this wrapper; it does not provide: repo_set_parse" — a diagnosis of the reader. `-f`
# reported a directory as a missing farm file ("Re-run pi-bootstrap/setup.sh"), and `-r` would have
# admitted it. `-e` is the one test that sends neither to the wrong place: absent/ dangling link → the
# farm message; present but unusable → the probe.
if [ ! -e "$READER" ]; then
  _say "REFUSING — $READER is missing: pi-bootstrap/setup.sh's \`lib_srcs\` declares it, so the farm"
  _say "  did not deliver a file this unit depends on. Nothing ran. Re-run pi-bootstrap/setup.sh."
  exit 2
fi
if [ ! -f "$DOCTOR" ] || [ ! -r "$DOCTOR" ]; then
  _say "REFUSING — $DOCTOR is missing, unreadable, or not a regular file (the farm's \`fleet_srcs\`"
  _say "  declares pr-doctor.py). Nothing ran. A mode problem is not a missing file: check the mode."
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
# ⛔ SOURCED, AND THE REASON IS THE FUNCTIONS, NOT THE EXIT CODE. This block used to say a
# `bash "$READER" check` subprocess "collapses 3/4/5 to 0/1" — it does NOT (the executed path returns
# `repo_set_check`'s code verbatim; measured 3/4/5 for absent/empty/malformed, and this repo's suite
# asserts exactly that through `bash "$READER"` in `repo-set.test.sh`). What a subprocess cannot give
# this process is the reader's FUNCTIONS AND THEIR VALUES — the set path, the rendered entry list, the
# trim, the origin proof, the slug normalisation — which the branches below CALL. ⛔ NAMING THEM ONE BY
# ONE IS WHAT WENT WRONG HERE THREE TIMES: a list invites a name that is not actually called (`_rs_slug_ok`
# reaches this process only inside `repo_set_parse`'s verdict). The property is "this process calls the
# reader's functions", and `grep -n '_rs_' scripts/pr-doctor-machine.sh` is its check.
# Re-parsing the file here, or scraping a subprocess's stdout for them, would be the two-authorities
# defect the reader exists to remove. One parser, in-process, so the verdict and the values are the
# same reader's.
# shellcheck disable=SC1090  # a farmed sibling, resolved above
. "$READER"
# ⛔ SOURCED IS NOT THE SAME AS LOADED (round 34, P2), AND LOADED IS NOT THE SAME AS BEING THE READER
# THIS WRAPPER WAS WRITTEN AGAINST (round 37, P1). `[ ! -e "$READER" ]` above is an EXISTENCE test only,
# so it accepts a reader that EXISTS but produces nothing — mode 000, a DIRECTORY, a truncated or corrupt
# farmed copy (the drift class `check-farm-drift.sh` exists for). ⛔ The flag named here was `-f` until
# round 43 changed the gate to `-e` so that a DIRECTORY takes this path instead of the farm message; the
# sentence's substance was always right, the flag was not. The `.` then defines no functions, the probe below returns 127, and
# the `*)` arm printed `no usable repo set at` followed by an EMPTY path plus two `command not found`
# lines — the round-33 defect one layer down: a summary naming a file it could not name.
#
# ⛔ AND PROBING ONLY THE `repo_set_*` FUNCTIONS CLOSED THE TRUNCATION HALF AND LEFT THE SKEW HALF OPEN
# (round 37, P1 — the round-35 guard's own subject said "every function the wrapper calls" and it
# probed four of nine). Truncation is not the realistic shape anyway: `setup.sh`'s lib farm copies via
# write-temp-then-`mv`, so a HALF file cannot land — what lands is `COPY/RENAME FAILED … leaving any
# previous copy in place`, i.e. a COMPLETE **OLDER** reader beside a NEW wrapper. Every `repo_set_*`
# exists in that file, so the four-name probe passed, and the wrapper then died five times on
# `_rs_doctor_available`/`_rs_origin_slug`/`_rs_normalize_slug` before refusing a VALID `OR` with
# `is not an owner/name slug` — the round-2/3/10 "refuse a pass the doctor runs" shape wearing the
# round-18/29/31 wrong-cause diagnosis. Measured with `git show 2a698a98:scripts/lib/repo-set.sh` as
# the sibling; the same env with this branch's reader prints `Grading the ONE repo … OR=…`.
#
# ⛔ THE LIST IS THE WRAPPER'S OWN CALL CONTRACT, AND IT IS KEPT HONEST BY A TEST, NOT BY PROSE (see the
# paragraph above about naming them one by one — that warning is why this cannot be a hand-maintained
# list with nothing watching it). `f11e` in `scripts/lib/repo-set.test.sh` recomputes the call sites out
# of THIS file and reddens in BOTH directions: a call the list does not name, and a name the file no
# longer calls. `f11d` drives the skew shape end to end.
_reader_needs="repo_set_parse repo_set_check repo_set_file repo_set_doctor_repos _rs_doctor_available _rs_strip _rs_origin_slug _rs_normalize_slug _rs_lower"
_reader_missing=""
for _need in $_reader_needs; do
  command -v "$_need" >/dev/null 2>&1 || _reader_missing="${_reader_missing:+$_reader_missing }$_need"
done
if [ -n "$_reader_missing" ]; then
  _say "REFUSING — $READER cannot be used by this wrapper; it does not provide: $_reader_missing"
  # ⛔ NO UNESCAPED BACKTICKS IN AN EMITTED LINE (round 38, P1; the co-working lane fixed the same two
  # lines independently, so both fixes landed in one block — the redundancy is in the HISTORY, never in
  # the escapes). ⛔ EVERY backtick below is load-bearing, and unescaping ONE of a pair is WORSE than
  # unescaping both: the substitution never terminates and swallows the rest of the file (`bash -n`
  # then fails with `unexpected EOF while looking for matching` and everything downstream of it reds).
  # The suite's own red count is deliberately not written here — three lanes change this branch's arm
  # total, so a total written once is wrong by the next commit. Both of these were
  # double-quoted with raw backticks around the quoted farm message, so bash ran
  # `COPY/RENAME FAILED … leaving any` as a COMMAND: every refusal printed
  #   /path/pr-doctor-machine.sh: line N: COPY/RENAME: No such file or directory
  # and the sentence lost the one clause that says the farm left an OLDER copy behind — i.e. the
  # explanation this guard exists to give. It also executed a relative path in the job's cwd (the unit
  # sets no WorkingDirectory, so `/`), which is why this is P1 and not a typo. The arms could not see
  # it: bash reports a slash-bearing name as `No such file or directory`, and they only looked for
  # `command not found`. They look for both now, and `f11b2` pins the log string verbatim.
  # ⛔ AND THE SHAPES ARE NOT COUNTED (round 38, P2). This said "Three shapes land here" and then named
  # three that did not include a reader that is present, readable and simply NOT SHELL — which the text
  # it replaced did name, and which `check-farm-drift.sh` exists for. "Not shell at all" is in the list
  # now and the count is gone, because a count in a refusal is a claim about the world that nothing
  # re-checks when a fourth shape appears.
  _say "  The shapes that land here share one repair: a reader that is unreadable, one that is not"
  _say "  shell at all, one truncated mid-file, or an OLDER reader than this wrapper — the last being"
  _say "  the state the farm deliberately leaves behind when a copy fails"
  _say "  (\`COPY/RENAME FAILED … leaving any previous copy in place\`). Nothing ran."
  _say "  Repair the farm: re-run pi-bootstrap/setup.sh — its \`lib_srcs\` declares repo-set.sh."
  exit 2
fi

# The code probe: the reader's refusal text is printed by the branch that ACTS on the code, so it is
# emitted once and always next to the line that says what this wrapper did about it.
repo_set_parse >/dev/null 2>&1
_rc=$?
case "$_rc" in
  0)
    # ⛔ THE PROOFS THAT CAN REFUSE RUN BEFORE THE PASS (review round 12, P2). They are: an origin that
    # PROVES a DIFFERENT slug, two repos sharing a state dir, a set the doctor's own splitter divides
    # differently, and colliding repo tags. A GONE OR DENIED CHECKOUT IS NOT ONE OF THEM — this reader
    # cannot prove absence from inside the process (macOS TCC/sandboxes answer EACCES or even ENOENT
    # for paths that exist), so it WARNS CHECKOUT-UNVERIFIED and the pass still runs. This comment
    # used to claim the opposite, which sent a reader looking for a refusal that is not there.
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
    # ⛔ `PYTHONUTF8=1` ON THE DOCTOR TOO — THE ROUND-41 FIX WAS HALF-APPLIED (review round 42, P2, measured).
    # Round 41 forced UTF-8 mode on the reader's PROOF child so a trimmed value and the doctor's own
    # `str.strip()` agreed. The wrapper TRIMMED the same value with that child, then `exec`'d the doctor
    # with no prefix — so under `LC_ALL=POSIX` the doctor decoded the RAW argv and REFUSED a repo the
    # wrapper had just announced as proved. A child that reads the value differently from the caller is not
    # a proof — true of wrapper-vs-doctor exactly as it was of reader-vs-doctor. One decode now governs both.
    # ⛔ THIS SITE IS DEFENCE-IN-DEPTH, AND THE MEASURED HALF-APPLICATION WAS THE *OTHER* ONE (review round
    # 43, P2). Deleting this prefix alone leaves the suite green, and it cannot fail open here: the splitter
    # round-trip (`_rs_split_divergence`, whose `_rs_with_doctor` child is already UTF-8) refuses any value
    # the doctor's `configured_repos()` would divide, so `PR_DOCTOR_REPOS` is splitter-clean before it
    # arrives. The degraded site below — where an operator seam is read raw — is the one `f33b` pins.
    _say "set: $(repo_set_file) -> grading $(printf '%s\n' "$repos" | awk -F, '{print NF}') repo(s)"
    PR_DOCTOR_REPOS="$repos"
    export PR_DOCTOR_REPOS
    PYTHONUTF8=1 exec "$PY" "$DOCTOR" --all-repos
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
    _say "DEGRADED — NO-REPO-SET: $(repo_set_file) reported no usable repo set, so this box has named no repo set."
    # ⛔ AND THE SENTENCE MUST NOT RE-ASSERT AN EXISTENCE PROOF THE READER JUST DISCLAIMED (round 48 review,
    # P3 — measured). It said `<path> does not exist` unconditionally, one line after the reader printed that
    # on the no-stat route this is the ancestor walk's INFERENCE and not a proof — so the operator-facing
    # line claimed more than the evidence did, in the one place they are most likely to read.
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
    # ⛔ THE FALLBACK IS GATED ON "THE DOCTOR CANNOT BE ASKED", NOT ON "THE RESULT IS EMPTY" (review
    # round 10, P2). Round 9's first cut reinstated the RAW value whenever the strip produced nothing,
    # so a seam that is entirely a non-ASCII space — which `str.strip()` legitimately empties — came
    # back as the original NBSP and the wrapper refused a pass the doctor ran with `REPO` instead.
    # Empty is a legitimate ANSWER here; only an unavailable doctor is a reason to fall back.
    _trim() {
      local v="${1:-}" out
      if _rs_doctor_available; then
        out="$(_rs_strip "$v")"
        # ⛔ `__UNASKABLE__` FROM THE STRIP VERB IS NOT A TRIMMED SEAM (round 18, P2). The reader emits
        # it when the sibling is present but WILL NOT LOAD, because for `strip` the empty answer means
        # "nothing to trim" — the two are otherwise indistinguishable, so every declared seam was
        # silently trimmed to "" and this wrapper refused a DECLARED box while printing that nothing
        # was declared. Fall back to the local trim instead of accepting a sentinel as a value.
        case "$out" in
          '__UNASKABLE__') : ;;
          *) printf '%s' "$out"; return 0 ;;
        esac
      fi
      printf '%s' "$v" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
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
      if [ "$_seam_n" = "__UNASKABLE__" ]; then
        # ⛔ A VALID SLUG WE COULD NOT NORMALISE IS NOT AN INVALID SLUG (round 18, P2). Normalisation is
        # delegated, so a sibling that is present but will not LOAD answers nothing — and this branch
        # used to call that "not an owner/name slug", sending an operator who had already done everything
        # right at the wrong defect. `norm` carries the sentinel for exactly this.
        _why_not="PR_DOCTOR_REPO='$_seam' could not be normalised: the sibling pr-doctor.py is present but lacks or raises _normalize_slug, or no python3 resolves"
        _seam_n=""
      elif [ -z "$_seam_n" ]; then
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
      if [ "$_or_n" = "__UNASKABLE__" ]; then
        _why_not="OR='$_or' could not be normalised: the sibling pr-doctor.py is present but lacks or raises _normalize_slug, or no python3 resolves"
        _or_n=""
      elif [ -z "$_or_n" ]; then
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
    # Same prefix as the `--all-repos` exec above, for the same measured reason: this path passes the
    # DEGRADED repo through the same seam the doctor re-reads from the environment.
    PYTHONUTF8=1 exec "$PY" "$DOCTOR"
    ;;
  *)
    repo_set_parse 1>&2
    # ⛔ DO NOT ASSERT THE FILE EXISTS HERE (round 33, P2). This arm handles every non-0/3 parse code,
    # and one of them — the `HOME`-unset refusal added this round — is exactly a state where NOTHING
    # exists: the reader says "the set path cannot be resolved" and this line used to answer "…exists
    # and is not a usable repo set", so the summary contradicted the report directly above it. Say what
    # the reader proved (a set that is not usable), not what it did not.
    _say "REFUSING — no usable repo set at $(repo_set_file) (see the report above)."
    _say "  Nothing was graded and nothing was dispatched: a shorter set would read exactly like a"
    _say "  smaller machine."
    exit 2
    ;;
esac
