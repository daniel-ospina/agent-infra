#!/usr/bin/env bash
# ci_runner_pool.sh — provision, report and RECONCILE this box's self-hosted CI runner pool.
#
# WHY THIS EXISTS (agent-infra#2373)
#   Provisioning a runner on the fleet's machine had no in-repo path at all. Two scripts could do
#   it, and both existed ONLY as untracked files in a cloud cell's /tmp (`cell-runner-add.sh`,
#   `runner-ctl.sh`) — neither in agent-infra nor in tortoise `origin/main` — so a fresh cell could
#   not provision a runner from the repo, both scripts were one `rm` away from being lost, and every
#   capacity change was a hand step made by whoever was driving. Measured 2026-10-22 22:30-22:45Z:
#   the pool went 6 -> 12 online entirely by hand; two runners GitHub showed OFFLINE were not
#   missing but had DEAD LISTENERS (their `_diag` stopped at 22:03 with `Deleting Runner Session`),
#   and one add was correctly refused at `MemAvailable=2.21 GB is below the 3.5 GB floor`.
#
# THE OWNER DECISION THIS ENCODES (agent-infra#2344, comment 6347825624, 2026-10-22)
#   "The runner build must refuse to add a runner when free memory is below a stated floor, and must
#    report the reading it used — 'manage capacity well' has to be a predicate the machine evaluates,
#    not a wish in a brief." Sizing is per box and MEMORY-bound, not a flat count: 3 slots on an
#    8-core/7.5 GB box, 2 on a 4-core box. Both gates below therefore PRINT the reading they used,
#    on success as well as on refusal. A gate that refuses without the number it read is a wish with
#    a semicolon.
#
# ⛔ THE FLOOR GATES *ADDING*, NEVER *RESTARTING*. Measured in the same incident: two runners came
#   back at ~200 MB each by restarting a stopped listener, while a NEW runner on a 2.21 GB box was
#   correctly refused. Applying the add-floor to a restart would leave a dead listener dead on a
#   busy box — the exact capacity the floor is trying to protect. `restart` has no floor; `add` has.
#
# THE CEILING IS CORE-AWARE AND PER BOX. Slots are bounded by `ceil(ncpu / RUNNER_CORES_PER_SLOT)`:
#   with the default 3 that is 3 on an 8-core box and 2 on a 4-core box, the owner's numbers. It is
#   a bound on how many runners THIS box carries, not a fleet-wide quota, and it is refused with the
#   core count, the ceiling, the slot count AND the memory reading printed.
#
# ⛔ ONE COMPLETE RUNNER INSTALL PER INSTANCE DIR — this is GitHub's layout, not a preference.
#   `config.sh` resolves its OWN directory (`DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"; cd "$DIR"`)
#   and `run.sh` does the same, so config writes `.runner` beside ITSELF and the listener runs from
#   there — the caller's cwd is ignored. Measured on the box: `/tmp/actions-runner/pi-runner-cell1-x64-1/`
#   holds config.sh, run.sh, env.sh, bin/, and the live listener is
#   `/tmp/actions-runner/pi-runner-cell1-x64-1/bin/Runner.Listener run`. So `add` COPIES
#   `RUNNER_TEMPLATE` (one pristine unpacked release) into `$RUNNER_ROOT/<name>` and configures THERE.
#   A single shared install with per-name instance dirs would register runners whose `.runner` never
#   appears where this script looks — and the suite would not have seen it, because a stub that
#   writes `.runner` into $PWD models a contract GitHub's script does not have.
#
# ⛔ LIVENESS IS THE PROCESS TABLE, NOT A PID FILE. A pid file is a stale flag that records a past
#   state and is never revalidated (#8175's class): a recycled pid would read "live" forever, and on
#   a box with no /proc it cannot be revalidated at all. The runner's own process cannot go stale —
#   its argv carries the instance dir and GitHub's binary name is fixed — so `listener_pid` reads
#   `ps` and matches BOTH. That is also the only way the runners the old hand scripts started are
#   visible at all: they wrote no pid file of ours, and reading them as DEAD would double-start a
#   listener on every pass.
#   ⛔ AND AN UNREADABLE PROCESS TABLE IS `cannot-measure`, NOT "no listeners" (#2373 review round
#   2): `ps` failing is the one input here whose absence would produce an ACTION (a double-started
#   listener) rather than a refusal, so it fails closed like every other reading.
#
# ⛔ THE ENV A LISTENER INHERITS IS PART OF STARTING IT (agent-infra#2937). An instance's `.env` can
#   name a TMPDIR (`TMPDIR=/tmp/ci-actions-runner-N` on the pi-runner VM, hand-written 2026-09-30), and
#   NOTHING creates that directory: GitHub's `run.sh` sources `.env` and runs every job step under it,
#   and the runner has no mkdir of its own. The instance dir is persistent and its unit is enabled, so
#   after a reboot the LISTENER survives and its TMPDIR does not — `mktemp: failed to create file via
#   template '/tmp/ci-actions-runner-2/tmp.XXXXXXXXXX'`, exit 2, on a runner GitHub reports `online`.
#   That presentation is the damage: jobs that use `mktemp` fail identically and jobs that do not, pass,
#   so a HOST-WIDE fault reads as a flaky, PR-specific one (measured: it cost a full investigation of
#   an unrelated PR before the `mktemp` line was read). So `start_listener` now satisfies the env it is
#   about to hand over (create it, idempotently, before exec) and `status` reports a missing target as
#   a DEFECT rather than leaving the next job to discover it.
#
# ⛔ EACH INSTANCE GETS ITS OWN PRIVATE TEMP ROOT, AND THE LISTENER IS STARTED WITH IT
#   (agent-infra#7815). `.env` above can name a TMPDIR, but nothing required it to — so an instance with
#   no `.env` inherited the BOX's temp dir, i.e. the machine-wide `/tmp` that every other runner install,
#   every peer lane and every unrelated process on that box writes into. Measured: a CI shard died in
#   `tests/_tmpdir_hygiene.py` with `SharedTmpdirScanError: os.scandir('/tmp')` — that suite's hygiene
#   guard protects the HOST temp dir and refuses entries it does not own, so on a shared `/tmp` it fires
#   on other people's files (one unrelated fixture had written 337 GB into /private/tmp; agent-infra#3003)
#   and every job's `mktemp`/`tmp_path` lands among them. So the private root is `$instance/_tmp`, mode
#   700, created by the same user that execs `run.sh` — the layout real multi-runner installs use (one
#   scratch dir per runner, precisely so runners stop competing for one `/tmp`) and the reason GitHub's
#   own `RUNNER_TEMP` is per JOB rather than per machine.
#   ⛔ THE ROOT IS STABLE AND SWEPT, NOT THE RUNNER'S PER-JOB `_work/_temp`. `RUNNER_TEMP` is the
#   runner's to own and to empty; two facts decided against reusing its path as the listener's TMPDIR.
#   (1) EXISTENCE IS THE WHOLE POINT: on a fresh install `_work/_temp` does not exist until the first
#   job, and Python — the tortoise suite included — resolves an ABSENT `$TMPDIR` by SILENTLY FALLING
#   BACK to the shared temp dir (measured on this box: `TMPDIR=/tmp/absent` →
#   `gettempdir()=='/tmp'`), i.e. the isolation would disappear with no error anywhere. `_tmp` is
#   created before `exec` and nothing else removes it, so the path a job inherits always exists.
#   ⛔ MEASURED ON THIS BOX (2026-10-28), because the shape of the win matters more than the claim: with
#   no private TMPDIR, `tempfile.gettempdir()` inside a job is `/tmp`, which carried **8,968 entries**
#   (foreign `tt_*` trees, `.tortoise`, `.transfer.chunks`, …) — with `$instance/_tmp` it resolves to a
#   tree with **1** entry, owned by that instance, and the neighbour is not visible at all. The tortoise
#   suite then treats THAT tree as its host temp dir (`HOST_TMPDIR`), so its cross-run bookkeeping is per
#   runner. (Its session root is still built under the SHORTEST base it can find — `/private/tmp`, 12
#   chars — by its own AF_UNIX rule, so socket paths stay short; that is tortoise's decision and this
#   tool must not fight it.)
#   ⛔ LENGTH, for consumers that DO build directly under the temp dir (macOS, `sun_path` ≈104 bytes):
#   `…/<instance>/_tmp` is 46 and `…/<instance>/_work/_temp` is 53 for `RUNNER_ROOT=/tmp/actions-runner`
#   with the fleet's longest instance name, so `_tmp` keeps 7 more bytes of that budget. It was a
#   TIE-BREAK, not the reason — the reason is the existence/residency argument above.
#   A STABLE root must be BOUNDED, so every start (and every live repair) sweeps entries older than
#   `RUNNER_TMP_MAX_AGE_MIN` (default 1440 = 24 h): a job's own scratch is minutes old in THIS fleet, so
#   the default does not race a running job, and a day-old file in a runner's private temp dir is
#   garbage by definition. ⛔ THAT IS WHY THE OPERAND HAS A FLOOR (360 min) rather than being free: a
#   self-hosted job may legally run 5 days (`docs.github.com/en/actions/reference/limits`), so the
#   safety of the sweep depends on the bound exceeding the longest job — the tool refuses values below
#   the GitHub-hosted 6 h ceiling and says how to be safe on a long-job box. `RUNNER_TEMP` itself is
#   NOT touched — the runner owns it, its lifecycle is per job.
#
# ⛔ THE LABEL DESCRIBES THE RUNNER. `ci_runner_gate.sh` selects the pool by `self-hosted-arm64` /
#   `self-hosted-x64`, and its invariant is "a runner's labels must describe that runner". A runner
#   registered with no pool marker is invisible to that gate forever and matches no `runs-on:` job —
#   registered, advertised to GitHub, and idle: zero capacity added. So the marker is derived from
#   the host's arch by DEFAULT, an unknown arch is `cannot-measure`, and a RUNNER_LABELS override
#   must still CONTAIN one of the two markers (a typo is refused, not registered as a jobless
#   runner). Runner NAMES are unique per repo, so the prefix defaults to `pi-runner-<host>` — two
#   boxes' passes must never mint the same name.
#
# THE RECONCILIATION PASS IS THE POINT (`reconcile`), not the one-shot verbs. It is idempotent:
#   (a) start the listener of every EXISTING registration that is dead, (b) add a runner only above
#   the memory floor, (c) REFUSE above the core-aware ceiling. Running it twice changes nothing the
#   second time. NOTHING SCHEDULES IT YET — arming it is an operator decision (which boxes, which
#   interval), so this file is callable and idempotent rather than self-arming.
#
# FAIL-CLOSED. An unreadable memory reading, core count, floor, cores-per-slot, arch, process table
#   or label is `cannot-measure` (rc 2) and changes NOTHING — never read as "probably fine". The
#   memory read is `orchestrator-harness/capacity.sh`'s, so this file adds no fourth /proc/meminfo
#   parser. ⛔ **THE POOL IS EVERY RUNNER ON THE BOX, NOT EVERY DIRECTORY UNDER ONE ROOT**: the same
#   process table is read for LIVE listeners whose instance dir sits OUTSIDE `RUNNER_ROOT` (measured
#   on the box this was written for: three live registrations under `/opt/gh-runner-*` while the
#   default root is `/tmp/actions-runner`). A listing that excludes them is a PARTIAL count of a
#   per-box budget, so `add` refuses (`why=pool-root-incomplete`) instead of putting a fourth runner
#   on a three-slot box, and `restart` refuses instead of calling an existing registration missing.
#   `RUNNER_ROOT` must be the directory that CONTAINS the instance dirs; set it to `/opt` and the same
#   box reports its real slots and can restart its real registrations.
#
# USAGE
#   ci_runner_pool.sh status  [--all]              # per-runner rows + this box's readings
#                                                 (--all is the SAME view: the default already lists
#                                                  every runner on THIS box, so the flag widens
#                                                  nothing. The cross-box view is capacity.sh / the
#                                                  fleet inventory, which this script does not
#                                                  duplicate.)
#                                                 A row whose instance `.env` names a TMPDIR that does
#                                                 NOT exist is reported as `defect tmpdir-missing` and
#                                                 is NOT a healthy row — see agent-infra#2937 below.
#   ci_runner_pool.sh add      --name <name> [--dry-run]
#   ci_runner_pool.sh restart  --name <name> [--dry-run]
#   ci_runner_pool.sh reclaim  [--name <name>] [--dry-run]
#                                                 # RETIRE a registration GitHub deleted (see R1)
#   ci_runner_pool.sh reconcile [--dry-run]        # the pass: restart dead listeners, RETIRE what
#                                                 # cannot be revived, then add to the ceiling
#
# ENV: RUNNER_ROOT (the directory that CONTAINS the instance dirs, one level above them; default
#        /tmp/actions-runner, where this tool puts what it creates — a root that excludes a LIVE
#        listener is refused as pool-root-incomplete)
#      RUNNER_TEMPLATE (pristine unpacked release to copy; default $RUNNER_ROOT/_template)
#      RUNNER_MEM_FLOOR_MB (3584 = the 3.5 GB the gate refused at) · RUNNER_CORES_PER_SLOT (3)
#      RUNNER_POOL_REPO (owner/name — BOTH the registration-token's scope and the URL the runner is
#        registered at, so it must be bare `owner/name`; a URL form is refused) · RUNNER_TOKEN (skip gh;
#        SINGLE-USE, so it serves one `add` — `reconcile` refuses it rather than spending it on the
#        first name and failing the rest)
#      RUNNER_LABELS (overrides the derived self-hosted-<arch> marker; must still contain it)
#      POOL_PREFIX (default pi-runner-<host>) · RUNNER_START_SETTLE_S (5)
#      RUNNER_MAX_SKEW_S (120) — the clock-skew bound a retirement is gated on (see `reclaim`)
#      RUNNER_TMP_MAX_AGE_MIN (1440 = 24 h — the age bound of the per-instance private temp root
#        `$instance/_tmp`, swept at every START and NEVER on a live listener: mtime age is not a
#        holder witness, and a self-hosted job may run 5 days; see agent-infra#7815 above)
#
# EXIT: 0 ok · 1 usage · 2 could-not-measure / could-not-act — nothing changed, EXCEPT a registration
#       the message names explicitly (a `.runner` written before its listener failed) · 3 REFUSED,
#       nothing changed — `add`: a gate verdict (a floor/ceiling refusal); `restart`: that name has no
#       registration under $RUNNER_ROOT, or its dir exists without a `.runner` (NOT a capacity verdict —
#       the message names the state and the action that clears it); `status`: the report it produced
#       contains a DEAD listener, an ORPHANED registration, or a `defect tmpdir-missing` row (see
#       below) · 4 name not available (that name is taken;
#       nothing changed, try another name) · 5 this name could not be REGISTERED (config.sh failed, or
#       it left no `.runner`): a per-name failure, so the pass tries the next name rather than ending
#       ⛔ 4 IS CHECKED BEFORE 3: a name that is already taken reports 4 even on a box that is also
#       at/below a gate, because the name condition is a fact about the request, not the box.
#       · 6 PROVABLY ORPHANED — the listener started and GitHub refused the session because the
#       registration no longer exists server-side (`restart`, `reconcile`). It is NOT 2 (nothing was
#       measured wrongly: this IS the measurement) and NOT 3 (no gate refused it): a scheduler must be
#       able to branch on "recover with `reclaim`". `reclaim` is the only verb that repairs it.
#
# `status` exits 3 when it produced a report in which at least one listener is DEAD, at least one
# registration is ORPHANED, or at least one row is `defect tmpdir-missing` — a report is still a
# report, but each of those is a fact a caller must be able to branch on without parsing the table.
# DEAD and ORPHANED are NOT interchangeable: an ORPHANED row means the newest evidence on the box says
# GitHub deleted that registration, so a plain `restart` cannot be assumed to clear it (`restart` →
# rc 6 when the fresh session is refused; `reclaim` is the verb that repairs it).
# ⛔ `status` NEVER RETURNS 3 FOR A QUARANTINE IT COULD NOT PROBE (#2899 review round 6, P3). An
# unmeasured quarantine is a PARTIAL MEASUREMENT and returns 2 — the row says `UNPROBED` and the
# cannot-measure paragraph below names it; 3 is reserved for verdicts this pass actually measured.
# It exits 2 (never 0, never 3) when it could not measure — including a pool it can only
# PARTLY see (a live listener outside `RUNNER_ROOT`, `why=pool-root-incomplete`), and including a
# quarantined install whose listener could not be probed (`UNPROBED`), because the rows and the slot
# count it prints would then describe part of the box as if it were all of it.
#
# ⛔ A `defect tmpdir-missing` ROW ALSO EXITS 3 (agent-infra#2937): a LIVE listener whose `.env` names
# a TMPDIR that does not exist is reported `online` by GitHub, runs its unit happily, PICKS UP jobs,
# and fails each one in its first seconds at `mktemp`. That is a report containing a runner nobody can
# use, so rc 0 over it would be a false PASS. `start_listener` — the single path `add`, `restart` and
# `reconcile` all start through — now creates the directory (`mkdir -p`, mode 700, owner = the
# listener's own user) before it execs `run.sh`, so a reboot cannot leave the listener without it and
# no systemd drop-in has to be remembered per instance.
# ⛔ AND THE SAME ARM COVERS THE INSTANCE'S OWN PRIVATE TEMP ROOT (#7815): `$instance/_tmp` is created
# and swept by the same call, so a row whose private root has vanished is reported `defect
# tmpdir-missing` on the path the listener is ACTUALLY started with — the `.env`-named path when there
# is one, `$instance/_tmp` otherwise — rather than reading as healthy while every job dies at `mktemp`.
# ⚠️ LIMIT, stated rather than implied: a listener that is ALREADY RUNNING keeps the environment it was
# exec'd with, and this tool never re-execs a live listener (that is the double-start it exists to
# prevent) — so `restart` restores the LAYOUT, and the NEXT start through `start_listener` is what
# carries the private root into a listener's env.
# ⛔ AND A BARE **UNIT RESTART DOES NOT CONFER IT** (#7815 review, F2). The export lives in exactly one
# place — `start_listener`'s `TMPDIR="$t" TMP="$t" TEMP="$t" exec "$d/run.sh"` — and nothing in this
# repo renders a runner unit or an `Environment=TMPDIR=` for one, so a unit restart re-execs `run.sh`
# with the UNIT's environment: it carries only what the unit itself supplies (or an `export TMPDIR=…`
# line in `.env`) — a BARE `TMPDIR=…` in `.env` is dropped (measured: sourcing a bare assignment sets it
# in the sourcing shell, not in the child) — and for an instance with no `.env`
# (the common shape) it hands the listener NO TMPDIR at all — every job then falls back to the box's
# shared temp dir, silently, while `status` grades the LAYOUT and calls the row clean. The two remedies
# that DO work: start the listener THROUGH this tool (stop it, then `restart --name <n>` on the now-dead
# listener — `add` is not one: an already-registered name is refused `rc 4 use restart`), or give the
# unit `Environment=TMPDIR=$instance/_tmp` (with `TMP`/`TEMP` beside it) so its own exec carries the root.
# `status` reports the layout, not a live process's env.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CAPACITY_LIB="${CAPACITY_LIB:-$SELF_DIR/orchestrator-harness/capacity.sh}"
# ⛔ RE-INVOKE THROUGH AN ABSOLUTE PATH, NEVER `$0`: `bash ci_runner_pool.sh reconcile` run from the
# script's own directory leaves `$0` as a bare filename that is not on PATH, so every child dispatch
# fails `command not found` — reconcile then reports a false `cannot-act` on a healthy box and no dead
# listener is ever restarted.
SELF="$SELF_DIR/$(basename "${BASH_SOURCE[0]}")"

RUNNER_ROOT="${RUNNER_ROOT:-/tmp/actions-runner}"
RUNNER_TEMPLATE="${RUNNER_TEMPLATE:-$RUNNER_ROOT/_template}"
MEM_FLOOR_MB="${RUNNER_MEM_FLOOR_MB:-3584}"   # 3.5 GB, the floor the gate refused at (#2373)
CORES_PER_SLOT="${RUNNER_CORES_PER_SLOT:-3}"  # 8 cores -> 3 slots, 4 cores -> 2 (owner sizing)
SETTLE_S="${RUNNER_START_SETTLE_S:-5}"        # how long a just-started listener gets to appear
# The largest clock skew a RETIREMENT may be taken under. GitHub refuses a session on a skewed clock
# and the listener prints the SAME "registration has been deleted" line it prints for a genuinely
# deleted registration (actions/runner#4648, #1798) — so the evidence `reclaim` acts on is only as
# good as the clock that produced it. 120 s is wide enough for any unsynchronised-but-working box and
# far below the interval at which a session is refused for skew.
MAX_SKEW_S="${RUNNER_MAX_SKEW_S:-120}"
CLOCK_PROBE_TIMEOUT_S="${RUNNER_CLOCK_PROBE_TIMEOUT_S:-10}"
# ⛔ THE AGE BOUND OF THE PER-INSTANCE PRIVATE TEMP ROOT (#7815). `_tmp` is STABLE — it survives a job,
# so it grows — and `$RUNNER_TMP_MAX_AGE_MIN` is what keeps that bounded at every start.
# ⛔ AND IT IS THE ONE OPERAND HERE WHOSE VALUE IS A DELETION THRESHOLD, so it has a FLOOR (#7815
# review, N1): `find -mmin +N` decides what `rm -rf` touches, and `N` is compared against a RUNNING job's
# scratch on the live-repair arms of `restart`/`reconcile`. The floor is GitHub's own **GitHub-hosted**
# job ceiling — 6 h (docs.github.com/en/actions/reference/limits) — because below it a legal-looking
# number deletes an in-flight job's scratch silently. It is not a claim that no job can be longer:
# `limits` documents **5 days** for a SELF-HOSTED job, so an operator on a long-job box must RAISE this
# bound above their longest job; the default (24 h) sits above this fleet's jobs and the floor refuses
# only values that are below any plausible one.
TMP_MAX_AGE_MIN="${RUNNER_TMP_MAX_AGE_MIN:-1440}"   # 24 h: a job's scratch is minutes old, never a day
TMP_MAX_AGE_FLOOR_MIN=360                            # 6 h — GitHub-hosted job ceiling; see above
POOL_REPO="${RUNNER_POOL_REPO:-daniel-ospina/tortoise}"
GH_CMD="${RUNNER_POOL_GH:-gh}"
POOL_LABEL_X64="self-hosted-x64"
POOL_LABEL_ARM64="self-hosted-arm64"

DRY=0
MEM_MB=""; NCPU=""; CEILING=""; LISTENER_PID=""; SLOTS=""; SLOT_REGS=""; SLOT_ORPHANED=""

log_line() { printf '%s\n' "$*"; }
err() { printf '%s\n' "$*" >&2; }

# mb_as_gb <mb> — the human form the owner reads ("2.21 GB"), never the only form printed.
mb_as_gb() { awk -v m="${1:-0}" 'BEGIN{printf "%.2f", m/1024}'; }
usage() {
  # The USAGE..EXIT block, read from this file's own header so help cannot drift from the contract.
  awk '/^# USAGE$/{f=1} f{ if ($0 ~ /^#/) { sub(/^# ?/, ""); print } else { exit } }' "$0"
  exit "${1:-1}"
}

# is_uint <value> — a non-empty, positive decimal integer small enough for `test` to compare.
# ⛔ EVERY operand of a gate passes through this. `[ "2263" -lt "3.5G" ]` returns 2 with
# "integer expression expected", and under `set -uo pipefail` (no -e) an `if` reads that ERROR as
# FALSE — so an unvalidated operand does not fail the gate, it SILENTLY DISABLES it and the add
# proceeds on a box at 2.21 GB. The floor is the owner's predicate; it may not be unset by a typo,
# and the length cap closes the same hole from the other side (a 20-digit value also ERRORS the
# comparison, which reads as false — `[ 12000 -lt 99999999999999999999 ]` is rc 2, not true).
is_uint() {
  local v="${1:-}"
  # ⛔ `0?*` — a LEADING ZERO is OCTAL to bash's arithmetic, and `08`/`09` are fatal there: the
  # arithmetic error kills the shell outright (rc 1, the documented USAGE code) mid-action, so a
  # "validated" operand could still die inside `$((…))` with no verdict printed. `010` is worse than
  # fatal: it is accepted, and means EIGHT where every other comparison reads it as ten.
  case "$v" in ''|*[!0-9]*|0|0?*) return 1 ;; esac
  [ "${#v}" -le 15 ] || return 1
  return 0
}

# validate_operands — the env operands that are not READINGS but still gate an action.
# ⛔ `RUNNER_START_SETTLE_S` was the one operand that reached arithmetic unvalidated: `5s` made
# `$((SETTLE_S * 2))` a bash ERROR (rc 1, "value too great for base") on a start that had already
# succeeded, and `0` skipped the settle loop entirely and reported `listener-never-appeared` for a
# listener that was running. Both are a one-character typo producing a wrong verdict.
validate_operands() {
  if ! is_uint "$SETTLE_S"; then
    err "cannot-measure why=settle-unreadable value=${SETTLE_S:-<empty>} (RUNNER_START_SETTLE_S must be a positive integer of seconds)"; return 2
  fi
  # The skew bound is compared against a measured number, so an unreadable one is the same class as
  # the settle operand: a typo must not silently widen (or disable) the guard that stands between a
  # bad clock and an irreversible deletion.
  if ! is_uint "$MAX_SKEW_S"; then
    err "cannot-measure why=skew-bound-unreadable value=${MAX_SKEW_S:-<empty>} (RUNNER_MAX_SKEW_S must be a positive integer of seconds)"; return 2
  fi
  # ⛔ THE SWEEP'S BOUND IS AN OPERAND TOO, AND IT LIVES HERE — NOT IN `readings()` (#7815 review, F1).
  # `readings()` runs on `status`, `add` and `reconcile`'s ADD arm only; `restart` — the verb the new
  # `defect tmpdir-missing` remedy PRINTS, and the verb a scheduler drives — never calls it, so a check
  # that lived there was absent on exactly the path that sweeps. Measured on this box:
  #   RUNNER_TMP_MAX_AGE_MIN=24h  -> `find -mmin +24h` is rc 1 with NO output, so nothing is ever swept,
  #                                 `removed=0`, no `swept …` line, `restart` exits 0 — the one property
  #                                 the private root is bounded by is silently disabled;
  #   RUNNER_TMP_MAX_AGE_MIN=0    -> `-mmin +0` matches EVERY entry older than a minute, i.e. a RUNNING
  #                                 job's scratch on a live listener (the live-repair arm sweeps while
  #                                 jobs may be in flight), silently deleted.
  # `validate_operands` runs in `main` for EVERY verb before dispatch (`--help` still returns first), so
  # this is the one home where no verb can reach the sweep unvalidated.
  if ! is_uint "$TMP_MAX_AGE_MIN"; then
    err "cannot-measure why=tmp-max-age-unreadable value=${TMP_MAX_AGE_MIN:-<empty>} (RUNNER_TMP_MAX_AGE_MIN must be a positive integer of minutes — the age bound of each instance's _tmp)"; return 2
  fi
  # ⛔ AND THE VALUE IS A DELETION THRESHOLD, SO IT HAS A FLOOR TOO (#7815 review, N1): `is_uint` alone
  # accepts `1`, and `find -mmin +1` on the LIVE-repair arm matches a 3-minute-old entry — a RUNNING
  # job's scratch, `rm -rf`'d silently (`2>/dev/null`). Measured on this box: `-mmin +1` matched a
  # 3-minute-old file, `-mmin +1440` did not. `0` is already refused by `is_uint`; `1` was not, and its
  # effect on a live job is the same. A value below the floor is cannot-measure: nothing swept, and the
  # message names the relation rather than the number.
  if [ "$TMP_MAX_AGE_MIN" -lt "$TMP_MAX_AGE_FLOOR_MIN" ]; then
    err "cannot-measure why=tmp-max-age-too-small value=${TMP_MAX_AGE_MIN}m floor=${TMP_MAX_AGE_FLOOR_MIN}m (RUNNER_TMP_MAX_AGE_MIN is what \`sweep_tmp_root\` deletes by, and the start path may follow a listener that died MID-JOB: a bound below the longest job deletes a RUNNING job's scratch, so it may not go below ${TMP_MAX_AGE_FLOOR_MIN} min — the GitHub-hosted job ceiling; a SELF-HOSTED job may run up to 5 days, so raise it above your longest job rather than lowering it)"; return 2
  fi
  # ⛔ THE REPO IS AN OPERAND TOO, and it now has TWO consumers: the `gh` token path
  # (`repos/$POOL_REPO/...`) and the registration URL (`https://github.com/$POOL_REPO`). A URL-form or
  # multi-slash value produces `https://github.com/https://github.com/o/r`; config.sh then fails at
  # parse time per NAME, so `add` returns rc 5 for every name and `reconcile` grinds through its whole
  # attempt budget before `cannot-act` — the only evidence a per-name `.config-<name>.log`.
  case "$POOL_REPO" in
    ''|/*|*/|*/*/*|*://*) err "cannot-measure why=repo-unreadable value=${POOL_REPO:-<empty>} (RUNNER_POOL_REPO must be owner/name — it is both the token scope and the registration URL)"; return 2 ;;
    */*) : ;;
    *) err "cannot-measure why=repo-unreadable value=$POOL_REPO (RUNNER_POOL_REPO must be owner/name)"; return 2 ;;
  esac
  return 0
}

# ── readings ─────────────────────────────────────────────────────────────────────────────────
# Both gates read HERE, once, so the number a decision was taken on is the number it printed.
readings() {
  [ -r "$CAPACITY_LIB" ] || { err "cannot-measure why=capacity-lib-absent path=$CAPACITY_LIB"; return 2; }
  # shellcheck source=/dev/null
  . "$CAPACITY_LIB"
  if ! is_uint "$MEM_FLOOR_MB"; then
    err "cannot-measure why=floor-unreadable value=${MEM_FLOOR_MB:-<empty>} (RUNNER_MEM_FLOOR_MB must be a positive integer MB)"; return 2
  fi
  if ! is_uint "$CORES_PER_SLOT"; then
    err "cannot-measure why=cores-per-slot-unreadable value=${CORES_PER_SLOT:-<empty>}"; return 2
  fi
  # ⛔ THE SWEEP'S BOUND IS VALIDATED IN `validate_operands`, NOT HERE (#7815 review, F1): this function
  # is not on the `restart` path, and `restart` is the verb that sweeps. A check here was absent where
  # it mattered.
  MEM_MB="$(cap_mem_free_mb 2>/dev/null)" || MEM_MB=""
  if ! is_uint "$MEM_MB"; then
    MEM_MB=""; err "cannot-measure why=mem-unreadable (cap_mem_free_mb gave no usable value)"; return 2
  fi
  NCPU="$(cap_ncpu 2>/dev/null)" || NCPU=""
  if ! is_uint "$NCPU"; then
    NCPU=""; err "cannot-measure why=ncpu-unreadable (cap_ncpu gave no usable value)"; return 2
  fi
  CEILING=$(( (NCPU + CORES_PER_SLOT - 1) / CORES_PER_SLOT ))
  [ "$CEILING" -ge 1 ] || CEILING=1
  return 0
}

# arch marker — GitHub stamps ARM64/X64 from the REGISTRATION HOST, and the gate selects on the
# matching custom marker. `uname -m` is the only statement available BEFORE the registration.
pool_label_for_host() {
  case "$(uname -m 2>/dev/null)" in
    x86_64|amd64)          printf '%s' "$POOL_LABEL_X64" ;;
    arm64|aarch64)         printf '%s' "$POOL_LABEL_ARM64" ;;
    *) return 1 ;;
  esac
}

# ── the pool as it stands ────────────────────────────────────────────────────────────────────
# A registration is a directory carrying `.runner` — GitHub's own marker, written by config.sh. The
# listing is the FILESYSTEM, not a `gh` call: a box that cannot reach GitHub must still be able to
# say what it has registered (and GitHub's view is the thing that lies when a listener has died).
registered_dirs() {
  local d tpl tpl_lit
  # ⛔ AN ABSENT ROOT IS AN EMPTY POOL (a fresh box); a root that EXISTS but is not a DIRECTORY is a
  # misconfiguration, and reading it as "0 slots, rc 0" is the same false empty-pool reading the guard
  # below closes.
  [ -e "$RUNNER_ROOT" ] || [ -L "$RUNNER_ROOT" ] || return 0
  if [ ! -d "$RUNNER_ROOT" ]; then
    err "cannot-measure why=runner-root-not-a-directory path=$RUNNER_ROOT"; return 2
  fi
  # ⛔ "THERE IS NO POOL" AND "I CANNOT READ THE POOL" ARE DIFFERENT ANSWERS, and only the first one is
  # 0. The glob below expands to NOTHING on a root that exists but cannot be listed (mode 300, an ACL
  # or SELinux denial, a transient readdir error on a mounted root), so the pool read as EMPTY — and
  # an empty pool never trips the ceiling: `add` added on a box already at its bound and `reconcile`
  # spent its whole attempt budget minting listeners on a box sized for a third as many (measured: 32
  # listeners on a 3-slot box, rc 0, cannot=0). This is the same class as the unreadable process
  # table — the one input whose absence would produce an ACTION instead of a refusal.
  # ⛔ READ **AND** SEARCH (`r`+`x`). `-r` alone is not enough for a listing: `readdir` needs `r`, but
  # every `[ -d "$d" ]`/`[ -e "$d/.runner" ]` on the entries needs `x` — so a mode-444 root SUCCEEDED
  # `ls -A` while the glob matched nothing, and the pool read empty with rc 0 (measured).
  if [ ! -r "$RUNNER_ROOT" ] || [ ! -x "$RUNNER_ROOT" ] || ! ls -A "$RUNNER_ROOT" >/dev/null 2>&1; then
    err "cannot-measure why=runner-root-unreadable path=$RUNNER_ROOT"; return 2
  fi
  # ⛔ THE TEMPLATE EXCLUSION MUST NOT DEPEND ON THE TEMPLATE RESOLVING. `$tpl` used to be the only
  # bound, so an unresolvable RUNNER_TEMPLATE left it EMPTY and the `[ -z "$tpl" ] || …` guard
  # evaluated TRUE — the pristine release was then emitted as a runner, `reconcile` started a
  # listener INSIDE it (which every later `add` copies into its instance, `.runner` and all, voiding
  # the proof-of-registration check), and `slots` counted it against the ceiling. So BOTH the
  # resolved and the literal path are excluded, plus the documented default `$RUNNER_ROOT/_template`
  # by name — the layout the shipped default uses while a release is still unpacking.
  tpl="$(cd "$RUNNER_TEMPLATE" 2>/dev/null && pwd -P)" || tpl=""
  tpl_lit="${RUNNER_TEMPLATE%/}"
  # ⛔ DOT DIRECTORIES ARE ENUMERATED: `"$RUNNER_ROOT"/*/` never matches a name starting with `.`,
  # so a hand-provisioned `.foo` registration was invisible to `status` and to `slots` (never
  # bounded by the ceiling) while `restart` happily started it — the same registration read two
  # different ways by two verbs.
  for d in "$RUNNER_ROOT"/*/ "$RUNNER_ROOT"/.[!.]*/; do
    [ -d "$d" ] || continue
    d="${d%/}"
    # ⛔ A DIR WE CANNOT INSPECT IS COUNTED, NOT SKIPPED. `-f .runner` is FALSE for a registration
    # we cannot read, so a `chmod 000` instance vanished from `slots`: the box looked EMPTIER than
    # it is and the core-aware ceiling (the owner's sizing bound) under-counted — the OVER-add
    # direction. Counting it keeps the ceiling conservative, and the probe downstream then reports
    # cannot-measure instead of inventing a number.
    # ⛔ READ **AND** SEARCH: a dir with `r` but not `x` (mode 444) passes `-r` and then fails every
    # `-d`/`-e` on its contents, so it was DROPPED from the listing — the box looked emptier than it is
    # and the ceiling under-counted, which is the OVER-add direction this arm exists to prevent.
    # ⛔ EXCEPT WHEN ITS NON-MEMBERSHIP IS PROVABLE (agent-infra#2892). "Cannot inspect" was rendered as
    # one condition, but it is two: WITHOUT SEARCH (`x`) nothing inside can be tested at all, so the dir
    # must be counted; WITH SEARCH BUT WITHOUT READ the four install markers are still testable BY
    # DIRECT PATH (`-e` needs traversal only, never a readdir), and a dir that carries none of them is
    # measurably NOT a registration. Measured on `pi-cell-4`: `RUNNER_ROOT=/opt` is where all four
    # installs live, `/opt/containerd` is `drwx--x--x root`, and counting it made EVERY pass exit 2
    # (`cannot-measure why=instance-unreadable path=/opt/containerd`) — a legitimately mixed root became
    # permanently unmeasurable, so the repair pass could never act on the box that needed it.
    # A QUARANTINED install is out of the pool (`reclaim` renames the dir before deleting it, so the
    # bytes it could not remove are still NAMED). It keeps its `.runner` inside, so without this arm it
    # would come straight back as a registration the ceiling counts — a retired runner that never left.
    # ⛔ AND THIS TEST COMES BEFORE THE UNREADABLE ARM (#2892 review, P2): placed after it, a quarantine
    # dir that is unreadable-but-searchable re-entered as a slot, made `status` exit 2 with
    # `instance-unreadable`, and poisoned the ceiling forever — the opposite of what the retire message
    # promises. A quarantine is excluded by its NAME, which needs no permission at all.
    case "${d##*/}" in *.retired-*) continue ;; esac
    if [ ! -r "$d" ] || [ ! -x "$d" ]; then
      if [ -x "$d" ] && [ ! -r "$d" ] && ! has_install_marker "$d"; then continue; fi
      printf '%s\n' "$d"; continue
    fi
    [ -e "$d/.runner" ] || [ -L "$d/.runner" ] || continue
    # The pristine template is never a runner, even if something wrote a `.runner` into it.
    [ "$d" != "${RUNNER_ROOT%/}/_template" ] || continue
    [ -z "$tpl_lit" ] || [ "$d" != "$tpl_lit" ] || continue
    [ -z "$tpl" ] || [ "$(cd "$d" && pwd -P)" != "$tpl" ] || continue
    printf '%s\n' "$d"
  done
}
# count_dirs <listing> — 0 for an EMPTY listing (`wc -l` over an empty string is 1, not 0).
count_dirs() { local s="${1:-}"; [ -n "$s" ] || { printf '0'; return 0; }; printf '%s\n' "$s" | wc -l | tr -d ' '; }

# has_install_marker <dir> — ANY of the markers GitHub's own scripts resolve from an install: the
# registration (`.runner`, written by config.sh), the configurator, the launcher, the listener binary.
# ⛔ PROBED BY DIRECT PATH ONLY: `-e`/`-L` need traversal, never iterating the directory, so this
# answers for a `0711` root-owned directory the caller cannot list. That distinction is the whole point
# (see the arm in `registered_dirs`): "I cannot list it" and "I cannot learn anything about it" are
# different readings, and only the second one is a reason to count a directory as capacity.
has_install_marker() {
  local d="$1" m
  for m in .runner config.sh run.sh bin/Runner.Listener; do
    if [ -e "$d/$m" ] || [ -L "$d/$m" ]; then return 0; fi
  done
  return 1
}

# registration_name <dir> — the name GITHUB knows this registration by, read from `.runner`.
# ⛔ THE DIRECTORY BASENAME IS NOT THE IDENTITY (#2892). Measured on `pi-cell-4`: two installs
# (`/opt/gh-runner-x64-1` and `/opt/gh-runner-cell4-x64`) both carry
# `"agentName": "pi-runner-cell4-x64-1"` — one GitHub registration, two local directories, because
# `--replace`/a second config re-uses the NAME while a fresh `add` mints a fresh DIRECTORY. Counting
# directories against a ceiling that bounds RUNNERS over-counts, and re-registering such a name
# deletes whichever live registration holds it. Empty output = the name could not be read (an
# unreadable instance), which the callers treat as its own slot rather than as a duplicate.
registration_name() {
  sed -n 's/.*"agentName"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$1/.runner" 2>/dev/null | head -1
}
registration_agent_id() {
  sed -n 's/.*"agentId"[[:space:]]*:[[:space:]]*"\{0,1\}\([0-9][0-9]*\)"\{0,1\}.*/\1/p' "$1/.runner" 2>/dev/null | head -1
}

# ⛔ THE ORPHAN SIGNATURE IS TEXT, NEVER AN EXIT CODE OR A MISSING PROCESS (#2892). Measured on
# `pi-cell-4`, `2026-10-27T04:19Z`, on an install whose registration GitHub had deleted:
#   ( cd /opt/gh-runner-cell4-x64 && exec ./run.sh )  →  DIED rc=0 after 4s
#   listener.log: Failed to create a session. The runner registration has been deleted from the
#                 server, please re-configure. …
# The process APPEARS, then exits ZERO — so neither `kill -0` at start time nor the exit status
# classifies this state, and a pass that reads either reports the slot restarted forever. The message
# is the only evidence, and it is also the reason a retirement is gated on a sane clock: GitHub emits
# the SAME line when session creation fails on a skewed clock (actions/runner#4648, #1798).
ORPHAN_SIG="registration has been deleted from the server"

# orphan_evidence_file <dir> [skip_bytes] — print the file that proves GitHub deleted this
# registration, rc 1 when nothing proves it. `skip_bytes` restricts the search in OUR OWN
# `listener.log` to what a start appended (so a listener that was already dead before we tried cannot
# lend its evidence to a fresh attempt). BOTH sources are candidates for EVERY attempt: our own log
# because a start this tool performed writes there, `_diag` because a start SYSTEMD performed writes
# ONLY there (measured: the `pi-cell-4` orphan's diag had the message and its `listener.log` did not
# exist) — and the NEWEST candidate decides (see the (a)/(b)/(c) list below; the older "check our own
# log first, fall back to _diag" order was defect (a) and is gone).
# ⛔ A `_diag` LINE OLDER THAN THE REGISTRATION IS NOT EVIDENCE ABOUT IT. An install that was orphaned,
# then RE-REGISTERED in place (`config.sh remove` + `add` under a fresh token) keeps every old log —
# and reading those would retire a HEALTHY registration on the strength of a failure that its current
# `.runner` already superseded. The marker's mtime is the registration's birth, so the evidence must be
# at least that new.
#
# ⛔ THE NEWEST LOG DECIDES, AND EVERY SOURCE IS BOUNDED THE SAME WAY (#2892 review, P1/P2). Three
# defects lived in the previous shape, all of them the same mistake — one SOURCE treated as the
# verdict, and the other sources read only as a fallback:
#   (a) `listener.log` was consulted FIRST and returned on a match, so a NEWER `_diag` log showing a
#       later, SUCCESSFUL start could not veto it. A log accumulates across every start in one
#       registration's life, so one deletion line written earlier (under a skewed clock, which prints
#       the SAME line — actions/runner#4648) authorised a retire after the clock was corrected and
#       the install was revivable again. Now the newest log is the one that speaks: if the newest
#       file does not carry the line, there is no evidence.
#   (b) the `_diag` arm ignored `skip_bytes`, so on a FRESH attempt (`skip>0`) a previous attempt's
#       diag could lend its evidence to a start that died for an unrelated reason — and rc 6 routes
#       straight into `reclaim`, which deletes the install. A fresh attempt now bounds `_diag` by the
#       attempt's own start time (`started`), the same way it bounds `listener.log` by byte offset.
#   (c) a tie at the newest mtime is REFUSED rather than resolved by source order: two equally-new
#       logs that disagree mean the pass cannot prove which attempt is the last one.
# Candidates are deduplicated by (device, inode) first: in a real install `listener.log` is often the
# same file as a `_diag/Runner_*.log`, and counting one file twice would manufacture the (c) conflict.
orphan_evidence_file() {
  local d="$1" skip="${2:-0}" started="${3:-0}" f c nat mt born=0 added="" has=0
  local best_mt=-1 best_f="" best_ok=0 conflict=0 seen=" " ident=""
  if [ -e "$d/.runner" ]; then
    born="$(stat -c %Y "$d/.runner" 2>/dev/null || stat -f %m "$d/.runner" 2>/dev/null)" || born=0
    case "$born" in ''|*[!0-9]*) born=0 ;; esac
  fi
  nat=""
  [ -f "$d/listener.log" ] && nat="$d/listener.log"$'\n'
  for f in "$d"/_diag/Runner_*.log; do
    [ -f "$f" ] || continue
    nat="$nat$f"$'\n'
  done
  [ -n "$nat" ] || return 1
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    # One physical file, one candidate — `listener.log` is frequently a link to the `_diag` log.
    ident="$(stat -c '%d:%i' "$c" 2>/dev/null || stat -f '%d:%i' "$c" 2>/dev/null)" || ident=""
    if [ -n "$ident" ]; then
      case "$seen" in *" $ident "*) continue ;; esac
      seen="$seen$ident "
    fi
    mt="$(stat -c %Y "$c" 2>/dev/null || stat -f %m "$c" 2>/dev/null)" || continue
    case "$mt" in ''|*[!0-9]*) continue ;; esac
    # A line older than the registration is not evidence about it (in-place re-registration).
    [ "$mt" -ge "$born" ] || continue
    # A FRESH attempt may only read what its own attempt produced — on EVERY source (review finding a).
    # ⛔ THE START-TIME BOUND IS GATED ON `started` ALONE, NEVER ON `skip` (#2892 review round 2, P2).
    # `skip` is the pre-start BYTE LENGTH OF `listener.log`, so on any install where that file did not
    # exist before the start — every systemd install, whose log lives only in `_diag`, and every fixture
    # that registers its own log — `skip` is 0 and the bound was INERT exactly where it was needed: the
    # `_diag` source is a SEPARATE file per attempt, so it is not scoped by a byte offset at all. The two
    # sources need two different bounds, and each is applied to its own source: byte offset to
    # `listener.log`, start time to every other file.
    if [ "$started" -gt 0 ] && [ "$c" != "$d/listener.log" ] && [ "$mt" -lt "$started" ]; then continue; fi
    if [ "$skip" -gt 0 ] && [ "$c" = "$d/listener.log" ]; then
      # ⛔ NO `| grep -q` (#2892 review, P1). `grep -q` exits at the first match, `tail` then dies of
      # SIGPIPE, and under this file's `set -o pipefail` the PIPELINE returns 141 — so the `if` was
      # FALSE with the evidence sitting in the file. Measured: identical 230 KB log, signature at byte
      # 0 => `preserve why=no-orphan-evidence`, rc 0, while a <64 KB copy of the same file retired
      # correctly. Size-dependent, so the defect appeared and disappeared between passes.
      # Capturing first has no pipeline to break; `case` matches with no external process at all.
      added="$(tail -c "+$((skip + 1))" "$c" 2>/dev/null)" || added=""
    else
      added="$(cat "$c" 2>/dev/null)" || added=""
    fi
    case "$added" in *"$ORPHAN_SIG"*) has=1 ;; *) has=0 ;; esac
    if [ "$mt" -gt "$best_mt" ]; then
      best_mt="$mt"; best_f="$c"; best_ok="$has"; conflict=0
    elif [ "$mt" -eq "$best_mt" ] && [ "$has" != "$best_ok" ]; then
      conflict=1
    fi
  done <<<"$nat"
  [ "$best_ok" = 1 ] || return 1
  [ "$conflict" = 0 ] || return 1
  printf '%s' "$best_f"
  return 0
}

# clock_skew_s — |local − remote| in seconds from GitHub's OWN Date header. rc 1 = cannot measure.
# ⛔ THIS IS THE GUARD ON AN IRREVERSIBLE ACTION. Retiring a registration deletes an install; doing it
# on a box whose clock is wrong destroys a HEALTHY runner (the skew fakes the very evidence the
# retirement is based on) and the only remedy left is a re-registration token. So an unmeasurable
# clock is a REFUSAL here, not a shrug: the cost of declining is one idle slot, the cost of guessing
# is a deleted runner. The HTTP Date header is used rather than an NTP query so no extra service is
# required; a multi-second skew is normal for a single request, which is why the bound is minutes.
clock_skew_s() {
  local hdr remote remote_s local_s skew
  command -v curl >/dev/null 2>&1 || return 1
  # ⛔ NO `-f`: a Date header is present on every HTTP response, and GitHub answers HEAD probes with
  # 403/429 often enough that `-f` turned a perfectly datable answer into `cannot-measure` (measured on
  # `pi-cell-4`: `reclaim` read skew=1s while `reconcile`'s child, seconds later, reported
  # `clock-unverified` and refused the preview). The status code is not what this function needs.
  hdr="$(curl -sSI --max-time "$CLOCK_PROBE_TIMEOUT_S" https://api.github.com 2>/dev/null)" || return 1
  remote="$(printf '%s' "$hdr" | sed -n 's/^[Dd]ate:[[:space:]]*//p' | head -1 | tr -d '\r')"
  [ -n "$remote" ] || return 1
  remote_s="$(date -u -d "$remote" +%s 2>/dev/null)" || remote_s=""
  if [ -z "$remote_s" ]; then   # BSD/macOS date
    remote_s="$(date -u -j -f '%a, %d %b %Y %H:%M:%S %Z' "$remote" +%s 2>/dev/null)" || return 1
  fi
  is_uint "$remote_s" || return 1
  local_s="$(date -u +%s 2>/dev/null)" || return 1
  is_uint "$local_s" || return 1
  skew=$((local_s - remote_s))
  [ "$skew" -lt 0 ] && skew=$((-skew))
  printf '%s' "$skew"
  return 0
}

# capacity_class <dir> — SILENT per-install classifier behind the ceiling count. One token on stdout:
#   live | revivable | orphaned | uninspectable
# rc 2 = the PROCESS TABLE could not be read, so the count would be a guess (propagated, never 0).
# ⛔ AN ORPHANED REGISTRATION IS NOT CAPACITY AND NOT A SLOT (#2892): it has no listener, and counting
# it against the core-aware ceiling is what made `pi-cell-4` unable to add a runner to a box whose real
# capacity was one short — `slots=5` against `ceiling=3`, three of those five being a deleted
# registration, a directory with no registration in it, and `/opt/containerd`. It becomes `reclaim`'s
# work, not the ceiling's arithmetic.
# ⛔ RECORDED TRADE-OFF, NOT AN OVERSIGHT — the evidence is a LINE, and `reclaim` says so (#2899 review
# round 6, P1 and R1). On actions/runner#4648's measured shape a skewed clock prints the SAME deletion
# line, the runner exits permanently, and after NTP corrects the clock the install is DEAD with the
# skew-era line still newest while its registration is HEALTHY — so a classifier reading only logs can
# call a revivable install `orphaned`, subtract it from `SLOTS`, and let a standalone `add` provision
# one runner past the ceiling (then `reconcile` revives it: ceiling+1 live). Counting it back as
# `revivable` would close THAT direction and re-open the one this change exists for — an unretired
# orphan taking a slot on a box whose real capacity is one short, which is the measured `pi-cell-4`
# failure. The owner's direction ("an orphaned registration is not capacity", R3 of
# docs/research/2026-10-27-runner-pool-self-healing.md) is therefore kept, deliberately, and the
# exposure is bounded instead: `status`/`reconcile` print `orphaned=` and exit 3, `reclaim` is the
# single verb that retires or revives, and `reconcile` runs restart → reclaim → add in that order in one
# pass, so the ceiling+1 window needs a STANDALONE `add` on a box that also holds unevidenced-dead
# installs. ⛔ Overturning the direction is a REOPEN of R3 with the owner, argued on this evidence —
# never a quiet classification change, which is why this comment exists at the classifier.
capacity_class() {
  local d="$1" p
  if [ ! -r "$d" ] || [ ! -x "$d" ]; then printf 'uninspectable'; return 0; fi
  p="$(listener_pid "$d")" || return 2
  if [ -n "$p" ]; then printf 'live'; return 0; fi
  if orphan_evidence_file "$d" >/dev/null 2>&1; then printf 'orphaned'; return 0; fi
  printf 'revivable'
  return 0
}

# capacity_from_listing <listing> — the ceiling's operand, computed from ONE already-taken listing.
# Sets SLOTS (capacity), SLOT_REGS (directory count), SLOT_ORPHANED.
# ⛔ `slots` IS CAPACITY, NOT A DIRECTORY COUNT (#2892), and the two are no longer the same number:
#   SLOT_REGS   every registration directory the listing returned (the report's own field)
#   SLOT_ORPHANED those whose NEWEST evidence says GitHub deleted the registration (retirable, not
#               capacity — evidence, not proof: see the RECORDED TRADE-OFF block on capacity_class)
#   SLOTS       live + revivable, DEDUPED BY agentName + uninspectable — what the ceiling bounds
# The dedupe is not tidiness: two directories carrying one `agentName` are ONE registration on GitHub,
# so starting both is not twice the capacity and the second session is refused. Uninspectable installs
# are counted, keeping the OVER-add direction conservative where nothing can be proven.
# An ORPHANED registration is neither capacity nor a slot: it has no listener, and counting it
# against the core-aware ceiling is what made `pi-cell-4` unable to add a runner to a box whose real
# capacity was one short — `slots=5` against `ceiling=3`, three of those five being a deleted
# registration, a directory with no registration in it, and `/opt/containerd`. It is `reclaim`'s work,
# not the ceiling's arithmetic.
# ⛔ THAT IS A RECORDED TRADE-OFF, NOT A PROOF, and the exposure runs OPPOSITE to the defect this arm
# closes: the classifier reads a LOG LINE, a skew-era line outlives the clock (bounded on
# capacity_class), and such an install is `orphaned` here yet `restart` can recover it. So this
# subtraction can let a STANDALONE `add` provision one past the ceiling on a box that also holds
# unevidenced-dead installs — `reconcile` cannot (restart → reclaim → add, one pass, in that order)
# and `reclaim` verifies before it acts. Counting it back as capacity closes that window and RE-OPENS
# the measured `pi-cell-4` under-add, which is the failure R3 of
# docs/research/2026-10-27-runner-pool-self-healing.md exists to fix; the owner's direction stands and
# overturning it is a REOPEN of R3 argued on this evidence, never a quiet edit here.
capacity_from_listing() {
  local out="${1:-}" d kind nm seen="|" cap=0 orph=0
  while read -r d; do
    [ -n "$d" ] || continue
    kind="$(capacity_class "$d")" || return 2
    case "$kind" in
      orphaned) orph=$((orph + 1)); continue ;;
      uninspectable) cap=$((cap + 1)); continue ;;
    esac
    nm="$(registration_name "$d")"
    [ -n "$nm" ] || nm="dir:$d"
    case "$seen" in *"|$nm|"*) continue ;; esac
    seen="$seen$nm|"
    cap=$((cap + 1))
  done <<<"$out"
  SLOTS="$cap"; SLOT_REGS="$(count_dirs "$out")"; SLOT_ORPHANED="$orph"
  return 0
}

# slots — refresh the capacity count. rc 2 = CANNOT MEASURE, and EVERY consumer must refuse:
# `n="$(registered_dirs | wc -l)"` (the old shape) turned "could not read the pool" into the integer 0,
# which is the unsafe direction on both gates (0 never reaches the ceiling).
slots() {
  local out
  out="$(registered_dirs)" || return 2   # pipefail is set; the listing error is not swallowed
  capacity_from_listing "$out"
}

# valid_name <name> — a runner name is a path component AND goes to `config.sh --name`.
# Anything with a `/` or a leading dot escapes $RUNNER_ROOT and is invisible to `slots`/`status`, so
# an escaped registration would sit outside the ceiling that is supposed to bound it. A leading `-` is
# refused because `--name -x` would be read as a FLAG by config.sh (and `--name --dry-run` would
# otherwise register a runner named `--dry-run` while leaving DRY at 0 — a preview that installs).
# ⛔ AND THE QUARANTINE SUFFIX IS RESERVED (#2892 review round 2, P2). `reclaim` renames an install to
# `<name>.retired-<stamp>` and `registered_dirs` excludes that BY NAME (deliberately: a retired runner
# must never re-enter capacity, and the name needs no permission to read). Nothing stopped `add --name
# live.retired-20260101T000000Z` from minting a LIVE registration under that suffix — which then left
# the ceiling silently and was reported by `status` as a retired leftover whose remedy is `rm -rf`.
# Refusing the suffix here closes the only door that can create one.
# ⛔ AND IT SAYS WHICH RULE THE NAME BROKE (#2899 review round 6, P2). The quarantine arm was added
# after the generic refusal text, so `add --name x.retired-20260101T000000Z` recited a rule the name
# OBEYS (`[A-Za-z0-9._-]`, no leading dot, no `/`) and gave the operator no way to find the real
# constraint. `NAME_WHY` carries the refusal's reason to the caller that prints it, the same way
# `SLOTS`/`CEILING` carry a reading to the verb that reports it.
NAME_WHY=""
valid_name() {
  NAME_WHY=""
  case "${1:-}" in
    '') NAME_WHY="empty" ;;
    .*) NAME_WHY="starts with '.' — it would be a hidden entry, and a hidden registration is still a registration";;
    -*) NAME_WHY="starts with '-' — config.sh would read the value as a FLAG";;
    */*) NAME_WHY="contains '/' — the name would escape \$RUNNER_ROOT";;
    *[!A-Za-z0-9._-]*) NAME_WHY="contains a character outside [A-Za-z0-9._-]";;
    # ⛔ THE RESERVED SUFFIX IS ITS OWN REASON, NOT A CHARACTER-CLASS FAILURE: the name satisfies every
    # other rule, so reciting them is advice an operator cannot act on.
    *.retired-*) NAME_WHY="carries the RESERVED quarantine suffix '.retired-' — that suffix names a retired install (excluded from capacity by name and never startable), so pick a name without it";;
    *) return 0 ;;
  esac
  return 1
}

# take_name_value <verb> <argc> <value> — the `--name` arm's own contract.
# ⛔ `shift 2` with ONE argument left FAILS WITHOUT DECREMENTING `$#`, and under `set -uo pipefail`
# (no `-e`) nothing stops it: `add --name` looped forever instead of returning the documented rc 1.
take_name_value() {
  local verb="$1" argc="$2" val="${3:-}"
  if [ "$argc" -lt 2 ]; then err "usage: $verb --name <runner-name> [--dry-run]"; return 1; fi
  case "$val" in
    -*) err "usage: $verb --name <runner-name> — the name must not start with '-'"; return 1 ;;
  esac
  return 0
}

# listener_pid <dir> — pid of a LIVE listener for this instance dir, or empty.
# rc 0 = measured (the pid printed, or nothing when there is none). rc 2 = CANNOT MEASURE.
# ⛔ THE PROCESS TABLE IS THE EVIDENCE: the runner's argv carries its own install dir and GitHub's
# binary is always named `Runner.Listener`, so neither can go stale (unlike a pid file) and it works
# on a box with no /proc. Every match is enumerated — a first-match read is how a stale process gets
# mistaken for the live one. The `/bin/Runner.Listener` suffix is what keeps `pi-runner-1` from
# matching `pi-runner-10`. An empty table is `cannot-measure` too: `ps` never lists zero processes.
listener_pid() {
  local d="$1" phys out pid args
  phys="$(cd "$d" 2>/dev/null && pwd -P)" || phys="$d"
  # ⛔ `-ww`, NOT A BARE `ps -eo`: procps TRUNCATES `args` to `$COLUMNS` (measured: with
  # `COLUMNS=80` every line came back exactly 80 chars, the argv cut mid-`Runner.Li`, while
  # `ps -ww` returned the full line under the same COLUMNS), and BSD/macOS `ps` truncates `args`
  # unless `-w` is given — and this file explicitly claims to work on a box with no /proc.
  # A truncated argv makes the suffix match below MISS a LIVE listener, which is not a cosmetic
  # reporting bug: `restart`/`reconcile` then start a SECOND listener for one registration (the
  # double-start the process-table design exists to prevent) and `status` exits 3 (DEAD) on a
  # healthy box. Double `-w` means unlimited width on both GNU and BSD.
  if ! out="$(ps -ww -eo pid=,args= 2>/dev/null)"; then
    err "cannot-measure why=process-table-unreadable (ps -ww -eo pid=,args= failed)"; return 2
  fi
  [ -n "$out" ] || { err "cannot-measure why=process-table-empty (ps listed no processes)"; return 2; }
  while read -r pid args; do
    [ -n "${pid:-}" ] || continue
    case "$args" in
      *Runner.Listener*)
        # ⛔ ANCHOR ON THE INVOCATION, NOT ON THE PATH. A live runner's measured argv is
        # `<dir>/bin/Runner.Listener run --startuptype service`, so requiring the ` run` that must
        # follow the binary is what separates a LISTENER from any process that merely NAMES the file
        # (`tail -f <dir>/bin/Runner.Listener`, an editor, a shell holding the path as an argument).
        # A bare path-substring match is this file's own named defect in disguise: a DEAD
        # registration then reads LIVE forever, so `restart`/`reconcile` skip it and the slot stays
        # idle while the report says healthy.
        case "$args" in
          *"$phys/bin/Runner.Listener run"*|*"$d/bin/Runner.Listener run"*) printf '%s\n' "$pid"; return 0 ;;
        esac ;;
    esac
  done <<<"$out"
  return 0
}

# outside_listener_dirs — instance dirs with a LIVE listener that sit OUTSIDE $RUNNER_ROOT.
# rc 0 = measured (one dir per line, possibly none) · rc 2 = CANNOT MEASURE.
# ⛔ THE POOL IS EVERY RUNNER ON THE BOX, NOT EVERY DIRECTORY UNDER ONE ROOT (#2381 review, P1).
# A box whose registrations live under a DIFFERENT parent (measured: three live listeners under
# /opt/gh-runner-*, while the shipped default root is /tmp/actions-runner) made `slots` read 1 where
# the box carried 3 — so `reconcile` would ADD onto a box already at the owner's 3-slot ceiling
# (memory and cores are per BOX, not per root), and `restart` answered "no registration … (add it
# first)" for a registration that was right there. Both are ACTIONS taken from a listing that was
# not the pool — the class this file refuses everywhere else. The process table is the one reading
# that holds regardless of where the installs live, and it is already this file's liveness evidence.
# is_plain_path <s> — no whitespace and no shell syntax. A dir that does not RESOLVE is judged by its
# spelling only when it is a plain path (#2524 review, P1): `bash -c 'cd <root>/pi-1 && exec
# <outside>/bin/…'` leaves a "dir" whose literal prefix is under the root but which is not a path at
# all, and calling that "inside" is how an outside listener read as in-pool.
is_plain_path() {
  case "${1:-}" in
    *[[:space:]]*|*'&'*|*'|'*|*';'*|*'<'*|*'>'*) return 1 ;;
  esac
  return 0
}

outside_listener_dirs() {
  local out pid args dir root lroot pdir cand one
  if ! out="$(ps -ww -eo pid=,args= 2>/dev/null)"; then
    err "cannot-measure why=process-table-unreadable (ps -ww -eo pid=,args= failed)"; return 2
  fi
  [ -n "$out" ] || { err "cannot-measure why=process-table-empty (ps listed no processes)"; return 2; }
  # The PHYSICAL root when it resolves, the literal one otherwise: a symlinked root must not report
  # every registration under it as "outside". ⛔ A ROOT OF `/` STAYS `/` — normalising it away made
  # the containment pattern `//*`, which no absolute dir matches, so every listener on the box
  # reported "outside" with a remedy the operator had already applied (#2381 review round 6).
  root="$(cd "$RUNNER_ROOT" 2>/dev/null && pwd -P)" || root="$RUNNER_ROOT"
  root="${root%/}"; [ -n "$root" ] || root="/"
  lroot="${RUNNER_ROOT%/}"; [ -n "$lroot" ] || lroot="/"
  while read -r pid args; do
    [ -n "${pid:-}" ] || continue
    # Same invocation anchor as `listener_pid`: the ` run` after the binary is what separates a
    # LISTENER from any process that merely names the file.
    case "$args" in *"/bin/Runner.Listener run"*) ;; *) continue ;; esac
    # ⛔ THE INSTANCE DIR IS THE ARGV WORD THAT CARRIES THE BINARY, NOT EVERYTHING BEFORE IT (#2381
    # review round 6, P1): a listener started through a wrapper (`nohup`, `env K=V`, `bash`, `sudo`,
    # a service shim) has `<wrapper> <dir>/bin/Runner.Listener run` as its argv, so the whole prefix
    # was `nohup <dir>` — not an absolute path — and the old `continue` DROPPED it silently. Measured:
    # `listener_pid` calls that same process LIVE while this arm called the pool complete, so `add`
    # minted a token and REGISTERED a runner on a box already at its ceiling.
    dir="${args%%/bin/Runner.Listener run*}"
    # Strip the WRAPPER tokens, not everything before the binary: `nohup <dir>/bin/…`, `env K=V <dir>/…`,
    # `bash <dir>/bin/…` all carry a wrapper in front. ⚠️ One token at a time, because an INSTANCE DIR
    # MAY CONTAIN A SPACE (measured: the suite's own `bad name` fixture) — splitting on the last space
    # tore `…/bad name` into `name` and dropped a LIVE listener out of the pool.
    while [ -n "$dir" ] && [ "${dir#/}" = "$dir" ] && [ "$dir" != "${dir#* }" ]; do dir="${dir#* }"; done
    case "$dir" in
      # ⛔ A RELATIVE INSTANCE DIR IS cannot-measure, NEVER "not an instance": GitHub's own `run.sh`
      # starts `./bin/Runner.Listener`, and a relative dir cannot be judged inside or outside without
      # the process's cwd — so dropping it is how an outside listener gets past the arm that exists to
      # catch exactly that.
      /*) ;;
      *) err "cannot-measure why=instance-dir-unresolvable argv=$args (the instance dir is not an absolute path, so it cannot be judged against RUNNER_ROOT)"; return 2 ;;
    esac
    dir="${dir%/}"
    # ⛔ RESOLVE FIRST, THEN JUDGE (#2524 review, P1): a LITERAL prefix test is defeated by `..`
    # (`$RUNNER_ROOT/../outside/pi-x`) and by a wrapper whose argv contains its own `cd` target
    # (`bash -c 'cd $RUNNER_ROOT/pi-1 && exec <outside>/bin/…'`), so those listeners read IN-POOL and
    # the pool read as complete — the over-add this arm exists to prevent. The physical dir is the only
    # evidence that can be trusted. A dir that does not RESOLVE is judged by spelling ONLY when the
    # spelling is a plain path under our own root (a deleted instance is still our capacity), and is
    # `cannot-measure` (rc 2) otherwise — never dropped, and never called "inside" on shell syntax.
    if ! pdir="$(cd "$dir" 2>/dev/null && pwd -P)" || [ -z "$pdir" ]; then
      # ⛔ AN UNRESOLVABLE DIR IS JUDGED BY SPELLING ONLY WHEN THE SPELLING IS A PLAIN PATH (#2524
      # review, P1). A deleted instance dir under our OWN root is still a runner of ours — the capacity
      # is on the box, its listing entry is simply gone (an operator `rm -rf`ed it under a live
      # listener), so it stays IN-POOL rather than blocking every add. But a wrapper's own `cd` target
      # is NOT a path: `bash -c 'cd <root>/pi-1 && exec <outside>/bin/…'` has a literal prefix under the
      # root, and judging THAT by spelling is how an outside listener read as inside. Anything carrying
      # shell syntax is `cannot-measure` (rc 2), never "inside".
      is_plain_path "$dir" || {
        err "cannot-measure why=instance-dir-unresolvable argv=$args (the instance dir '$dir' is not a plain path and does not resolve, so it cannot be judged against RUNNER_ROOT)"; return 2; }
      for cand in "$root" "$lroot"; do
        [ -n "$cand" ] || continue
        [ "$cand" = "/" ] && continue 2
        case "$dir" in "$cand"/*) continue 2 ;; esac
      done
      err "cannot-measure why=instance-dir-unresolvable argv=$args (the instance dir '$dir' does not resolve on this box, so it cannot be judged against RUNNER_ROOT)"; return 2
    fi
    # INSIDE = the PHYSICAL dir under the PHYSICAL or the LITERAL root (`/` contains every absolute path).
    for cand in "$root" "$lroot"; do
      [ -n "$cand" ] || continue
      [ "$cand" = "/" ] && continue 2
      case "$pdir" in "$cand"/*) continue 2 ;; esac
      # ⛔ A SYMLINKED INSTANCE INSIDE THE ROOT IS IN THE POOL (#2381 review round 6, P1): `run.sh`
      # resolves its own dir with `cd -P`, so argv carries the TARGET and the dir is not literally
      # under the root — while `registered_dirs` counts `$RUNNER_ROOT/$(basename)` as a slot and
      # `listener_pid` reads it LIVE. Reporting it outside refused `add` and `reconcile` on a box whose
      # only defect was a hand-made symlink, and printed a report that contradicted its own rows.
      one="$cand/$(basename "$dir")"
      if [ -d "$one" ] && [ "$(cd "$one" 2>/dev/null && pwd -P)" = "$pdir" ]; then continue 2; fi
    done
    printf '%s\n' "$dir"
  done <<<"$out"
  return 0
}

# join_lines <text> — one comma-separated field from a newline-separated list (#2381 review round 6,
# P2): the machine-readable `outside=` field was `tr '\n' ' '`, which glued the first dir to the em
# dash (`outside=/opt/x— a LIVE…`) and left two dirs an unquoted space-separated list.
join_lines() { local s; s="$(printf '%s' "$1" | tr '\n' ',')"; printf '%s' "${s%,}"; }

# require_pool_complete <verb> — rc 0 = the listing under $RUNNER_ROOT IS the box's pool.
# rc 2 = a LIVE listener runs from an instance dir OUTSIDE it, so the listing (and the ceiling
# counted from it) is INCOMPLETE and no action may be taken from it. Fails closed: an unreadable
# process table is rc 2 here too, never "nothing outside".
require_pool_complete() {
  local outside
  outside="$(outside_listener_dirs)" || return 2
  [ -z "$outside" ] && return 0
  err "cannot-measure why=pool-root-incomplete root=$RUNNER_ROOT outside=$(join_lines "$outside") — a LIVE listener runs from an instance dir OUTSIDE RUNNER_ROOT, so the pool listing (and the ceiling counted from it) is incomplete; set RUNNER_ROOT to the directory that CONTAINS every instance dir (one level above them) — $1 NOT attempted"
  return 2
}

# probe_listener <dir> — sets LISTENER_PID. rc 0 alive · 1 dead · 2 cannot-measure.
# The third state is the point: "no listeners" and "I could not look" must never be the same value,
# because one of them starts a second listener.
probe_listener() {
  local p
  LISTENER_PID=""
  # ⛔ AN INSTANCE DIR WE CANNOT INSPECT IS cannot-measure, NOT DEAD. `listener_pid` cannot resolve its
  # physical path, so a `chmod 000` registration used to report DEAD (rc 3) and `restart` refused it
  # "no registration at … (add it first)" — both asserting a measured fact the tool never measured, on
  # a registration that EXISTS. It is COUNTED as a slot (registered_dirs), so the two halves agree:
  # counted against the ceiling, and reported unreadable rather than dead.
  [ -r "$1" ] && [ -x "$1" ] || { err "cannot-measure why=instance-unreadable path=$1"; return 2; }
  p="$(listener_pid "$1")" || return 2
  LISTENER_PID="$p"
  [ -n "$p" ] || return 1
  return 0
}

# instance_tmpdir <dir> — the TMPDIR the instance's own `.env` names, as an ABSOLUTE path, or empty
# when it names none. ⛔ NOTHING CREATES THAT DIRECTORY (agent-infra#2937). GitHub's `run.sh` sources
# `.env` and runs every job step under that TMPDIR; the runner has no mkdir of its own, and this tool
# neither wrote the `.env` nor ever looked at it. So an instance whose `.env` names a VOLATILE path
# (`/tmp/ci-actions-runner-N`, hand-written on the pi-runner VM) keeps a HEALTHY listener across a
# reboot while its TMPDIR is gone: the job is PICKED UP, starts, and dies in its first seconds at
# `mktemp` — which reads as "this workflow is broken", not "this host is". Measured job 122457527181:
# `mktemp: failed to create file via template '/tmp/ci-actions-runner-2/tmp.XXXXXXXXXX'`, exit 2, on a
# box GitHub reported `online`.
# A relative value is REFUSED, not resolved: `run.sh` `cd`s into the instance dir before the listener
# READS the variable, but the listener hands the value to each JOB, whose working directory is
# `_work/<repo>/<repo>` — so a relative TMPDIR resolves THERE, and any directory this tool created
# would be one no job uses. See the refusal at the end of `instance_tmpdir` (#3004 review, P2).
#
# ⛔ THREE STATES, NOT TWO (#3004 review, P1). Returning empty for BOTH "the file names no TMPDIR" AND
# "the file could not be read" made an unreadable `.env` collapse into "names none": `[ -f ]` is TRUE
# for a mode-000 file, `sed`'s error was discarded, and the caller then published `tmpdir_defects=0`
# — a count over a reading nobody took. `status` may legitimately run as a DIFFERENT user from the
# runner's, so that shape is reachable exactly as the comment on its call site describes.
#   rc 0 + a path   · it names a TMPDIR (absolute, resolved)
#   0, no output    · it names none (the agent-infra `ai-runner-*` shape) — nothing to create
#   2               · CANNOT MEASURE (unreadable `.env`), or a value no shell-free read can satisfy
#
# ⛔ AND THE VALUE IS PARSED THE WAY A SOURCING SHELL PARSES IT, NOT LIKE A SHELL WORD (#3004 review,
# P1 + P2). `run.sh` SOURCES `.env`, so the listener sees the EXPANDED value while a `sed` read sees
# the raw text: `TMPDIR=$HOME/ci-tmp` had this tool create a directory literally named `$HOME` under
# the instance dir and print `created tmpdir=…` (rc 0) over a runner that still inherited an ABSENT
# TMPDIR — a false PASS in the exact dimension this arm adds. A value needing shell evaluation is
# refused rather than guessed at.
# ⛔ BUT THE REFUSAL MUST NOT TAKE LEGAL VALUES WITH IT. The first shape stripped quotes FIRST and then
# refused the unquoted remainder for whitespace/`$`/`~`, i.e. it removed exactly the characters that
# had made the value legal. Measured refusals on values the listener honours EXACTLY:
# `TMPDIR="/tmp/a b"` (a quoted path with a space) and `TMPDIR='/tmp/a$b'` (single quotes are
# literal) were both `cannot-act`, so `restart` — the remedy `status` prints — started NOTHING on a
# legal `.env`; and `TMPDIR=/tmp/x  # scratch` was refused although an unquoted assignment ENDS at
# the first whitespace, so `/tmp/x` is not a guess but the value. The shell's own rules:
#   unquoted  · ends at the first whitespace (which is also where a trailing comment starts);
#               `~` expands ONLY as the FIRST character; `$`/`` ` `` expand
#   'single'  · everything up to the closing quote is LITERAL — nothing expands
#   "double"  · spaces are part of the value; `$`/`` ` `` expand; `~` does not
# Anything whose meaning depends on evaluation is refused, naming the value and the remedy.
instance_tmpdir() {
  local d="$1" raw t rest
  [ -f "$d/.env" ] || return 0
  # An EXISTING but unreadable `.env` is cannot-measure. `-r` is the read this function actually does
  # (and it is FALSE for a mode-000 file, which `-f` alone happily accepts).
  [ -r "$d/.env" ] || { err "cannot-measure why=tmpdir-unreadable path=$d/.env"; return 2; }
  # LAST assignment wins, which is what a shell sourcing the file would do. `export TMPDIR=…` is
  # honoured too — `. ./.env` accepts it, so requiring a bare `TMPDIR=` made a legal .env invisible to
  # BOTH the creation and the detection. The `2>/dev/null` is gone on purpose: a read that failed must
  # be visible, not silently equal to "names none".
  raw="$(sed -n 's/^[[:space:]]*\(export[[:space:]][[:space:]]*\)\{0,1\}TMPDIR=//p' "$d/.env" | tail -n 1)" || return 2
  raw="${raw%$'\r'}"   # a `.env` edited on a CRLF host would otherwise name a path with a CR in it
  # ⛔ ANY SHELL SYNTAX THIS PARSER DOES NOT MODEL IS REFUSED UP FRONT, because truncating at it would
  # silently create a DIFFERENT directory and report `created tmpdir=…` over the real one's absence.
  # Measured on the round-2 shape, each accepted with rc 0 and the WRONG path created:
  #   `TMPDIR=/tmp/x/a\ b`      → created `a\`      (the shell's value is `/tmp/x/a b`)
  #   `TMPDIR=/tmp/x/x; echo hi` → created `x;`      (the shell's value is `/tmp/x/x`)
  #   `TMPDIR="/tmp/a\"b"`       → created `/tmp/a\`   (the shell's value is `/tmp/a"b`)
  #   `TMPDIR='/tmp/a'x`         → created `/tmp/a`  (adjacent segments concatenate: `/tmp/ax`)
  # A backslash, a command separator, a redirection or a subshell is EVALUATION, and evaluation is the
  # one thing this function may not do (`.env` is another user's file; `status` may run as root). So the
  # presence of any of them is `cannot-act` — refused, never guessed at (#3004 review round 3, P1).
  case "$raw" in
    *'\'*|*';'*|*'&'*|*'|'*|*'<'*|*'>'*|*'('*|*')'*)
      err "cannot-act why=tmpdir-value-not-literal value=$raw (named by $d/.env) — the value contains shell syntax (a backslash, a separator, a redirection or a subshell) that only EVALUATION could resolve, and this tool will not evaluate another user's .env; write a plain absolute path in $d/.env"
      return 2 ;;
  esac
  case "$raw" in
    \'*)
      # A closing quote is part of the value's MEANING — without it the string written is not the path
      # the listener resolves, so an unterminated one is refused rather than turned into a directory.
      case "${raw#\'}" in
        *\'*) t="${raw#\'}"; rest="${t#*\'}"; t="${t%%\'*}" ;;
        *) err "cannot-act why=tmpdir-value-unterminated-quote value=$raw (named by $d/.env) — single quotes are taken LITERALLY by the listener, so nothing but a closing quote makes this a path; write the path, or close the quote, in $d/.env"
           return 2 ;;
      esac ;;
    \"*)
      case "${raw#\"}" in
        *\"*) t="${raw#\"}"; rest="${t#*\"}"; t="${t%%\"*}" ;;
        *) err "cannot-act why=tmpdir-value-unterminated-quote value=$raw (named by $d/.env) — a double-quoted value ends at its closing quote, so this names no path; write the path, or close the quote, in $d/.env"
           return 2 ;;
      esac
      # INSIDE double quotes a `$` or a backtick IS expanded by the sourcing listener, so it still
      # cannot be honoured from the raw text; a space or a `~` inside them is LITERAL.
      case "$t" in
        *'$'*|*'`'*)
          err "cannot-act why=tmpdir-value-not-literal value=$raw (named by $d/.env) — the listener SOURCES .env, so this value is expanded there and cannot be satisfied from the raw text; write a literal absolute path in $d/.env"
          return 2 ;;
      esac ;;
    *)
      t="${raw%%[[:space:]]*}"   # an unquoted assignment ENDS at the first whitespace
      rest="${raw#"${raw%%[[:space:]]*}"}"
      # ⛔ A QUOTE INSIDE AN UNQUOTED VALUE IS STILL QUOTING SYNTAX, and a sourcing shell would USE it:
      # `/tmp/x/adj'x` is `/tmp/x/adjx` to the listener. Unmodelled, it was accepted verbatim and the
      # tool created a directory whose name carries the quote (#3004 review round 3, P1).
      case "$t" in
        *"'"*|*'"'*|'~'*|*'$'*|*'`'*)
          err "cannot-act why=tmpdir-value-not-literal value=$t (named by $d/.env) — the listener SOURCES .env, so this value is expanded there and cannot be satisfied from the raw text; write a literal absolute path in $d/.env"
          return 2 ;;
      esac ;;
  esac
  # ⛔ WHAT FOLLOWS THE VALUE MUST BE BLANK OR A COMMENT. Anything else is a second shell word that a
  # sourcing shell would either CONCATENATE (`'/tmp/a'x` → `/tmp/ax`) or run (`… ; rm -rf /`), and this
  # parser models neither — so it refuses rather than create the path it happened to read (#3004
  # review round 3, P1). ⛔ AND `#` IS ONLY A COMMENT AT THE START OF A WORD: for a QUOTED value `rest`
  # begins immediately after the closing quote, so `'/tmp/a'#x` has `#x` CONCATENATED into the word
  # (`/tmp/a#x`) and is NOT a comment — accepting it created the truncated `/tmp/a` and reported
  # `created tmpdir=…` over the listener's absent path (#3004 review round 4, P1). Hence: blank, or
  # WHITESPACE followed by nothing-or-comment. Never `#` with no whitespace before it.
  case "$rest" in
    '') : ;;
    [[:space:]]*) case "${rest#"${rest%%[![:space:]]*}"}" in ''|'#'*) : ;; *)
        err "cannot-act why=tmpdir-value-trailing-syntax value=$raw (named by $d/.env) — a sourcing shell would CONCATENATE or EXECUTE what follows the value (${rest}), so the path this tool read is not the path the listener uses; write one plain absolute path in $d/.env"
        return 2 ;; esac ;;
    *) err "cannot-act why=tmpdir-value-trailing-syntax value=$raw (named by $d/.env) — a sourcing shell would CONCATENATE or EXECUTE what follows the value (${rest}), so the path this tool read is not the path the listener uses; write one plain absolute path in $d/.env"
       return 2 ;;
  esac
  [ -n "$t" ] || return 0
  case "$t" in /*) printf '%s' "$t"; return 0 ;; esac
  # ⛔ A RELATIVE VALUE IS REFUSED, NOT RESOLVED (#3004 review, P2). This arm used to create
  # `$d/<value>`, on the claim that `run.sh` `cd`s into the instance dir before the listener reads the
  # variable. That is true of the READ and false at USE: the listener hands the env to each JOB, whose
  # working directory is `_work/<repo>/<repo>`, so a relative TMPDIR resolves THERE — never under the
  # instance dir. The directory this arm created was therefore one no job ever used, while it printed
  # `created tmpdir=…`, exited 0, and `status` called the row clean: a false PASS in the exact
  # dimension this arm adds. Nothing here can make a relative value true (the value is the listener's,
  # not ours — rewriting another tool's `.env` is not this function's to do), so it is refused.
  err "cannot-act why=tmpdir-value-relative value=$t (named by $d/.env) — a relative TMPDIR is resolved against each JOB's working directory (_work/<repo>/<repo>), not the instance dir, so no directory created here would be the one a job uses; write an absolute path in $d/.env"
  return 2
}

# instance_tmp_root <dir> — the instance's OWN private temp root (agent-infra#7815).
# ⛔ NOT THE RUNNER'S `_work/_temp`. `RUNNER_TEMP` is created, emptied and owned by the runner, and it
# does not exist before the first job — where an ABSENT `$TMPDIR` makes `tempfile.gettempdir()` fall
# back to the SHARED temp dir with no error (measured: `TMPDIR=/tmp/absent` → `gettempdir()=='/tmp'`),
# i.e. the isolation would vanish silently. So the root here is created before `exec`, is never emptied
# by anyone else, and therefore always exists when a job resolves it. It is BOUNDED by the age sweep
# below instead of by the runner's per-job cleanup.
instance_tmp_root() { printf '%s' "${1%/}/_tmp"; }

# sweep_tmp_root <dir> — keep the STABLE private root from growing without bound.
# ⛔ MTIME AGE IS NOT A HOLDER WITNESS, SO THIS NEVER RUNS ON A LIVE LISTENER (review P2-1). The old
# header claimed that an entry older than `$RUNNER_TMP_MAX_AGE_MIN` "cannot belong to a job that runs
# SHORTER than the bound", and then swept on the LIVE-repair arms of `restart` and `reconcile`, which run
# while jobs may be in flight. Read plainly, that sentence licenses deleting the scratch of every job
# that runs LONGER than the bound — and GitHub allows a self-hosted job to run up to 5 days
# (`docs.github.com/en/actions/reference/limits`), so on a box carrying the 24 h default a day-old JOB
# is exactly what the age test matches. `docs/ops/disk-reaper.md` states the doctrine this file was
# missing: "A live holder is never selected. The witnesses are mechanical and fail closed" — and an age
# is not a witness. So this is called ONLY from the START path (`ensure_private_tmp` with NO live
# listener), where the listener is DEAD and the root cannot belong to a running job. The LIVE-repair
# arms create/verify the root and sweep nothing, and say so (`tmpdir-sweep skipped …`) instead of
# leaving the operator to assume a sweep happened.
# ⛔ THE BOUND IS STILL VALIDATED AND STILL FLOORED (`validate_operands`, 360 min): the start path can
# follow a listener that died MID-JOB, so a typo-scale bound is still not a bound.
# Nothing here is ever deleted on mtime ALONE when the sweep cannot enumerate: a failed `find` removes
# nothing and claims nothing — the only consequence is growth, and the next start retries. Dry runs
# REPORT, and remove nothing.
# ⛔ THE WALK IS BOUNDED: one explicit start point, `-maxdepth 1` (the root's own entries; the root
# itself is never a candidate), `-print0` so a name with a newline cannot be split into two deletions.
sweep_tmp_root() {
  local t="$1" removed=0 victim
  [ -d "$t" ] || return 0
  while IFS= read -r -d '' victim; do
    if [ "$DRY" = 1 ]; then removed=$((removed + 1)); continue; fi
    rm -rf -- "$victim" 2>/dev/null && removed=$((removed + 1))
  done < <(find "$t" -mindepth 1 -maxdepth 1 -mmin +"$TMP_MAX_AGE_MIN" -print0 2>/dev/null)
  [ "$removed" -gt 0 ] || return 0
  if [ "$DRY" = 1 ]; then
    log_line "dry-run: would sweep tmpdir-root=$t removed=$removed older_than=${TMP_MAX_AGE_MIN}m"
  else
    log_line "swept tmpdir-root=$t removed=$removed older_than=${TMP_MAX_AGE_MIN}m"
  fi
  return 0
}

# tmp_owner_guard <path> <live_listener_pid> <label> — rc 0 = this process may create/verify `path` as
# the listener's env · 2 = the LIVE listener belongs to ANOTHER user, so nothing here can establish
# whether that user can write it.
# ⛔ THE INVOKER IS NOT NECESSARILY THE LISTENER'S USER (#3004 review, P1), and that is true whether or
# not the directory already exists (#3004 review round 4, P2). Everything in `ensure_private_tmp`
# measures access as THIS process: for the START path that is the right subject, because
# `start_listener` execs `run.sh` as the same user. For a LIVE listener it is not — so a wrong-owner
# directory reported "satisfiable" by a `-w` test that is trivially true for root is the false PASS the
# #2937 arm exists to refuse. A mismatch is cannot-measure: this tool cannot establish another user's
# access, and saying "fine" is what the issue is about. It applies to BOTH directories this tool
# manages — a `.env`-named TMPDIR and the instance's own `_tmp` — so it has one definition.
# ⛔ ONLY A READING THAT LOOKS LIKE A USER MAY REFUSE. `ps` is a READ this file already treats as
# fallible, and this repo's own suite replaces it (`$BIN/ps` models the process table), so a garbage
# line must degrade to "no mismatch proven" — NOT to a refusal that would block a legal repair on every
# box whose `ps` is a shim.
tmp_owner_guard() {
  local t="$1" live_pid="${2:-}" label="${3:-}" lu
  [ -n "$live_pid" ] || return 0
  lu="$(ps -o user= -p "$live_pid" 2>/dev/null | tr -d '[:space:]')"
  case "$lu" in
    ''|*[!A-Za-z0-9_.-]*) lu="" ;;
  esac
  if [ -n "$lu" ] && [ "$lu" != "$(id -un 2>/dev/null)" ]; then
    err "cannot-measure why=tmpdir-owner-mismatch path=$t ($label) — the live listener pid=$live_pid runs as user=$lu and this pass runs as user=$(id -un 2>/dev/null), so this process cannot establish whether that user can write the directory, and every job on it dies at mktemp if it cannot; run this pass as $lu (or as the listener's own user) so the check measures the right process"
    return 2
  fi
  return 0
}

# ensure_private_tmp <dir> [live_listener_pid] — create (idempotently) the instance's own private temp
# root, and SWEEP it ONLY when no listener is live. rc 0 = satisfiable · 2 = cannot-act, nothing started.
# ⛔ THE SWEEP IS GATED ON THE HOLDER, NOT ON THE AGE (review P2-1). A live listener's instance may be
# running a job RIGHT NOW, and there is no witness in this file that can tell a 2-day-old job's scratch
# from a 2-day-old abandoned file — so on the live arms (`cmd_restart`, `cmd_reconcile`, both of which
# pass `$LISTENER_PID`) this function creates and verifies and sweeps NOTHING. It says so on stdout, so
# a pass an operator reads cannot imply a sweep it did not perform.
# ⛔ THIS IS THE SINGLE DEFINITION, CALLED FROM `ensure_tmpdir` — which `start_listener` (and therefore
# `add`, `restart` and `reconcile`) and both LIVE-repair arms already go through. So an instance can be
# DELETED AND RE-CREATED and the isolation comes back with no hand action: `add` re-copies the release
# and calls `start_listener`, which lands here, which recreates `_tmp`. Nothing else has to remember it.
# ⛔ MODE 700, CREATED BY THE USER THAT WILL RUN THE LISTENER, and `mkdir -p` leaves an EXISTING
# directory's mode alone — so a hand-repaired box is not silently tightened, and the owner can only be
# the right one because `start_listener` execs `run.sh` as this same process's user.
# ⛔ A CREATION THAT FAILED IS A REFUSAL, NOT A WARNING: a listener that comes up under a TMPDIR which
# does not exist is the #2937 incident (jobs die at `mktemp` while GitHub says `online`).
ensure_private_tmp() {
  local d="$1" live_pid="${2:-}" t p
  t="$(instance_tmp_root "$d")"
  tmp_owner_guard "$t" "$live_pid" "the instance's private temp root" || return 2
  if [ ! -d "$t" ]; then
    # ⛔ A PREVIEW MAY NOT MUTATE (#3004 review, P2): in DRY mode the same satisfiability question is
    # asked WITHOUT creating — `mkdir -p` succeeds over any missing ancestors, so the test is the first
    # ancestor that EXISTS.
    if [ "$DRY" = 1 ]; then
      p="$t"
      while [ ! -e "$p" ] && [ "$p" != "/" ] && [ "$p" != "." ]; do p="$(dirname "$p")"; done
      if ! { [ -d "$p" ] && [ -w "$p" ] && [ -x "$p" ]; }; then
        err "cannot-act why=tmpdir-root-uncreatable path=$t — nothing started: the listener would inherit a TMPDIR that does not exist and every job on it would die at mktemp; check the parent directory's permissions and that no FILE sits on the path"
        return 2
      fi
      log_line "dry-run: would create tmpdir-root=$t (the instance's private TMPDIR)"
      return 0
    fi
    mkdir -p -m 700 "$t" 2>/dev/null || true
    [ -d "$t" ] || {
      err "cannot-act why=tmpdir-root-uncreatable path=$t — nothing started: the listener would inherit a TMPDIR that does not exist and every job on it would die at mktemp; check the parent directory's permissions and that no FILE sits on the path"
      return 2
    }
    log_line "created tmpdir-root=$t (the instance's private TMPDIR; nothing else creates it)"
  fi
  # WRITE is not enough — `mktemp` needs SEARCH too (the `-w`-only false PASS this file already paid for
  # once, on the `.env` arm).
  [ -w "$t" ] && [ -x "$t" ] || {
    err "cannot-act why=tmpdir-root-unwritable path=$t — this user needs WRITE and SEARCH (w=$([ -w "$t" ] && echo y || echo n) x=$([ -x "$t" ] && echo y || echo n)) on the instance's private temp root, and every job on it would otherwise die at mktemp"
    return 2
  }
  # ⛔ NO HOLDER WITNESS ⇒ NO SWEEP (review P2-1). `live_pid` non-empty MEANS a listener is running on
  # this instance, i.e. a job may be live in `$t` right now; the age bound would then be the only thing
  # between a >bound job and `rm -rf` of its scratch. Create, verify, and leave the entries alone.
  if [ -n "$live_pid" ]; then
    log_line "tmpdir-sweep skipped tmpdir-root=$t reason=live-listener pid=$live_pid (mtime age is not a holder witness, so this pass creates and verifies the root and sweeps nothing; the next START sweeps it)"
    return 0
  fi
  sweep_tmp_root "$t"
  return 0
}

# ensure_tmpdir <dir> [live_listener_pid] — create the TMPDIR the instance's `.env` names,
# IDEMPOTENTLY, before the listener is exec'd. rc 0 = satisfiable (created, or already there) ·
# 2 = cannot-act, nothing started. The optional pid is the LIVE listener the caller is repairing
# (the post-reboot arms); it makes the ownership check below possible.
# ⛔ OWNER AND MODE. The directory is created BY THE USER THAT WILL RUN THE LISTENER, which is the only
# owner that can be right here: `start_listener` execs `run.sh` as this same process's user, so a
# `mkdir` needs no chown and cannot pick the wrong one. Mode 700 is what a private per-runner temp dir
# should be, and `mkdir -p` does NOT touch the mode of a directory that already exists — so the
# operative boxes (hand-repaired, carrying 755) are left exactly as they are, and only a directory
# this tool creates is tightened.
# ⛔ AND A CREATION THAT FAILED IS A REFUSAL, NOT A WARNING. Starting the listener anyway is the whole
# defect: it comes up healthy and every job on it dies at `mktemp`. `mkdir`'s exit code alone is not
# the verdict either (the `-p` arm can succeed while the target is still not a directory) — the test
# is that the directory EXISTS and this user can write it, which is what `mktemp` will do next.
ensure_tmpdir() {
  local d="$1" live_pid="${2:-}" t created=0 rc=0 p
  t="$(instance_tmpdir "$d")" || rc=$?
  # cannot-measure (`tmpdir-unreadable`) and a non-literal value are BOTH cannot-act here: the reason
  # was already named by `instance_tmpdir`, so this arm does not invent a second one. Starting the
  # listener anyway is the defect — the env it would inherit is unknown.
  [ "$rc" -eq 0 ] || return 2
  # ⛔ THE INSTANCE'S OWN PRIVATE TEMP ROOT IS SATISFIED FIRST AND ALWAYS (#7815) — it is the TMPDIR the
  # listener is started with whenever `.env` names none, and this call is also the INSTALL-TIME and
  # REINSTALL path: `add` -> `start_listener` -> here recreates it after an instance dir was deleted.
  # It runs after the `.env` read so that an unreadable `.env` still mutates nothing.
  ensure_private_tmp "$d" "$live_pid" || return 2
  [ -n "$t" ] || return 0
  # ⛔ THE INVOKER IS NOT NECESSARILY THE LISTENER'S USER (#3004 review, P1), AND THAT IS TRUE WHETHER
  # OR NOT THE DIRECTORY ALREADY EXISTS (#3004 review round 4, P2). The comparison runs first, for both
  # branches, and a mismatch is cannot-measure; the guard itself is `tmp_owner_guard` (one definition,
  # shared with the private root above).
  tmp_owner_guard "$t" "$live_pid" "named by $d/.env" || return 2
  if [ ! -d "$t" ]; then
    # The owner question is settled ABOVE, by `tmp_owner_guard`, before either branch — so what remains
    # here is only creation (and its preview).
    # ⛔ A PREVIEW MAY NOT MUTATE, AND IT MAY NOT LIE (#3004 review, P2). `--dry-run` used to skip this
    # check entirely (it sat downstream of the DRY return), so an uncreatable target previewed as
    # "would start the listener" (rc 0) and then refused for real (rc 2) — the lying preview this file
    # refuses everywhere else. In DRY mode the same satisfiability question is asked WITHOUT creating:
    # `mkdir -p` succeeds over any missing ancestors, so the test is the first ancestor that EXISTS.
    if [ "$DRY" = 1 ]; then
      p="$t"
      while [ ! -e "$p" ] && [ "$p" != "/" ] && [ "$p" != "." ]; do p="$(dirname "$p")"; done
      if [ -d "$p" ] && [ -w "$p" ] && [ -x "$p" ]; then
        log_line "dry-run: would create tmpdir=$t (named by $d/.env)"
        return 0
      fi
      err "cannot-act why=tmpdir-uncreatable path=$t (named by $d/.env) — nothing started: the listener would come up healthy and every job on it would die at mktemp; check the parent directory's permissions and that no FILE sits on the path"
      return 2
    fi
    mkdir -p -m 700 "$t" 2>/dev/null || true
    [ -d "$t" ] || {
      err "cannot-act why=tmpdir-uncreatable path=$t (named by $d/.env) — nothing started: the listener would come up healthy and every job on it would die at mktemp; check the parent directory's permissions and that no FILE sits on the path"
      return 2
    }
    created=1
  fi
  # ⛔ WRITE IS NOT ENOUGH — `mktemp` needs SEARCH too (#3004 review, P2). `[ -w ]` is true for a
  # mode-200 directory, and `mktemp` in that same directory fails (measured: rc 1), so a `-w`-only
  # verdict returned 0 SILENTLY — no `created`, no `cannot-act` — over a TMPDIR every job dies in:
  # the false PASS this function's own header says it refuses. `-x` is the missing bit of the same
  # question, and the DRY ancestor test above asks it too (otherwise the preview promises a creation
  # the real `mkdir -p` then refuses).
  [ -w "$t" ] && [ -x "$t" ] || {
    err "cannot-act why=tmpdir-unwritable path=$t (named by $d/.env) — nothing started: this user needs WRITE and SEARCH (w=$([ -w "$t" ] && echo y || echo n) x=$([ -x "$t" ] && echo y || echo n)) on it, and every job on it would otherwise die at mktemp"
    return 2
  }
  # PRINT THE PATH, as the memory floor prints its reading: a creation nobody can see is one the
  # operator cannot audit, and this is the line that distinguishes a repaired box from a lucky one.
  [ "$created" = 1 ] && log_line "created tmpdir=$t (named by $d/.env; nothing else creates it)"
  return 0
}

# start_listener <dir> — start run.sh from the instance dir, PROVE a listener appeared, and then
# PROVE IT SURVIVED. rc 0 = listening · 2 = cannot-measure / cannot-act · 6 = PROVABLY ORPHANED.
# ⛔ IT ALSO MAKES THE LISTENER'S ENV SATISFIABLE FIRST (agent-infra#2937): `ensure_tmpdir` creates the
# directory the instance's `.env` names, so a start can never leave a job to discover it at `mktemp`.
# A pid we just forked exists for one instant; a registration whose listener dies on connect (GitHub
# refusing a duplicate, a revoked token, a registration deleted server-side) would otherwise be
# reported "restarted" every pass, forever.
# ⛔ APPEARANCE IS NOT A SESSION — the two-read probe (#2892). Before this, `start_listener` returned
# on the first 0.5 s poll that saw the process, which is ~3.5 s BEFORE an orphan dies: measured on
# `pi-cell-4` (2026-10-27T04:19Z) the listener for a deleted registration appeared immediately and
# then exited at +4 s with rc 0. So the old probe reported `listener_pid=…` success for a slot that
# could never serve a job, `reconcile` counted it `restarted=`, and the fleet's "self-healing" pass was
# green over a dead runner. The second read holds the full settle window and decides on what it sees:
# still alive → success; gone with GitHub's `registration has been deleted` line in the log → rc 6;
# gone for any other reason → cannot-act (2), naming the log the operator has to read.
start_listener() {
  local d="$1" i=0 rc log before="0" started=0 ev="" t
  [ -x "$d/run.sh" ] || { err "cannot-act why=runner-not-installed path=$d/run.sh"; return 2; }
  log="$d/listener.log"
  # The pre-start length, so "this attempt's" evidence can be told apart from a previous one's.
  if [ -f "$log" ]; then before="$(wc -c <"$log" 2>/dev/null | tr -d ' ')" || before=0; fi
  case "$before" in ''|*[!0-9]*) before=0 ;; esac
  # ⛔ THE ATTEMPT'S OWN START TIME, not just the byte offset (#2892 review, P1). `skip_bytes` only
  # scopes `listener.log`; `_diag/Runner_*.log` is a SEPARATE file per attempt, so a previous attempt's
  # diag could still supply the deletion line for a start that died for an unrelated reason — and rc 6
  # is routed straight to `reclaim`, which deletes the install. Both bounds are therefore passed.
  started="$(date -u +%s 2>/dev/null)" || started=0
  case "$started" in ''|*[!0-9]*) started=0 ;; esac
  # ⛔ THE ENV THE LISTENER INHERITS MUST BE SATISFIABLE BEFORE IT IS EXEC'D (agent-infra#2937). This is
  # the ONE place a listener is STARTED — `add`, `restart` and `reconcile` all come through here — so
  # the creation is at START TIME and survives a reboot with no systemd drop-in to remember. It is not
  # the only place a listener RUNS, though: a listener that SURVIVED the reboot is never started again,
  # so `cmd_restart` and `cmd_reconcile` also repair their LIVE arms (#3004 review, P1). `--dry-run`
  # cannot reach here, but `ensure_tmpdir` is DRY-aware anyway so no future caller can mutate a preview.
  # It is also what creates (and sweeps) the instance's own private temp root (#7815).
  ensure_tmpdir "$d" || return 2
  # ⛔ THE TEMP ROOT IS THE PRIVATE ONE, AND IT IS EXPORTED (#7815). GitHub's `run.sh` sources `.env` and
  # then starts the listener, which hands ITS OWN environment to every job step — so these three
  # variables are what decides where `mktemp`, `tempfile.gettempdir()` and every other temp consumer in
  # a job land. Without them an instance with no `.env` wrote into the BOX's shared temp dir, which is
  # what made the tortoise hygiene guard fire on other people's files (agent-infra#7815 / #3003).
  # `TMP` and `TEMP` travel with `TMPDIR` because toolchains read them by different names — moving only
  # `TMPDIR` leaves npm/node-style consumers still writing in the shared dir.
  # A `.env` that names a TMPDIR still WINS: `run.sh` sources it AFTER this and overwrites the value,
  # which is the documented precedence (an explicit operator setting beats a default) — and the export
  # here uses that same value in that case, so all three variables agree either way.
  t="$(instance_tmpdir "$d")" || return 2
  [ -n "$t" ] || t="$(instance_tmp_root "$d")"
  # PRINT THE PATHS, as the memory floor prints its reading: an env an operator cannot see is one they
  # cannot audit, and this is the line that proves two instances of one box are isolated.
  log_line "env name=$(basename "$d") TMPDIR=$t TMP=$t TEMP=$t (RUNNER_TEMP is the runner's own)"
  (
    cd "$d" || exit 2
    TMPDIR="$t" TMP="$t" TEMP="$t" exec "$d/run.sh"
  ) >>"$log" 2>&1 &
  while [ "$i" -lt $((SETTLE_S * 2)) ]; do
    rc=0; probe_listener "$d" || rc=$?
    case "$rc" in
      0) break ;;
      2) return 2 ;;   # cannot measure: never claim a start, never wait blind
    esac
    sleep 0.5; i=$((i + 1))
  done
  if [ "$i" -ge $((SETTLE_S * 2)) ]; then
    err "cannot-act why=listener-never-appeared waited=${SETTLE_S}s see=$log"
    return 2
  fi
  # Hold the settle window: a process that appears and dies is the shape this verb kept calling a win.
  sleep "$SETTLE_S"
  rc=0; probe_listener "$d" || rc=$?
  case "$rc" in
    0) log_line "listener_pid=$LISTENER_PID"; return 0 ;;
    2) return 2 ;;
  esac
  if ev="$(orphan_evidence_file "$d" "$before" "$started")"; then
    err "orphaned name=$(basename "$d") dir=$d evidence=$ev — the listener started, GitHub refused the session because THIS registration no longer exists, and the process exited; nothing about the install can bring it back: run: $SELF reclaim --name $(basename "$d")"
    return 6
  fi
  err "cannot-act why=listener-exited waited=${SETTLE_S}s see=$log (the process appeared, then went away with no orphaned-registration evidence — read the log before starting it again)"
  return 2
}

# ── verbs ────────────────────────────────────────────────────────────────────────────────────
cmd_status() {
  local dead=0 live=0 orph=0 qn=0 qunprobed=0 tmpdir_defects=0 d rc qrc dirs outside qdirs t rownote rt
  # `--all` is ACCEPTED AND CHANGES NOTHING, DELIBERATELY: #2373 names a `status --all`, and the
  # default view already IS every runner on this box, so there is no narrower form for the flag to
  # widen. It is documented as such (USAGE) rather than left as a flag a reader assumes reveals more
  # than it does — and rather than dropped, because the issue's clause names it.
  while [ $# -gt 0 ]; do
    case "$1" in --all) shift ;; *) err "usage: status [--all]"; return 1 ;; esac
  done
  readings || return 2
  # ⛔ THE INCOMPLETE-POOL READ IS ITS OWN REFUSAL (#2381 review, P1): a report that counts only
  # `$RUNNER_ROOT` while live listeners run elsewhere is a partial count printed as the box's pool.
  outside="$(outside_listener_dirs)" || return 2
  # ONE listing, one count: `slots` (listing #1) and `dirs` (listing #2) could disagree while
  # registrations appeared, and the report then printed more DEAD rows than `slots=` (measured:
  # `live=0 dead=30 slots=17`). The rows and the count now come from the SAME read.
  dirs="$(registered_dirs)" || return 2
  capacity_from_listing "$dirs" || return 2
  printf 'host=%s ncpu=%s ceiling=%s slots=%s mem_available=%s MB (%s GB) floor=%s MB (%s GB)\n' \
    "$(cap_host 2>/dev/null || hostname 2>/dev/null || printf box)" \
    "$NCPU" "$CEILING" "$SLOTS" "$MEM_MB" "$(mb_as_gb "$MEM_MB")" \
    "$MEM_FLOOR_MB" "$(mb_as_gb "$MEM_FLOOR_MB")"
  printf '%-32s %-9s %-9s %s\n' NAME LISTENER STATE GITHUB_NAME
  while read -r d; do
    [ -n "$d" ] || continue
    rc=0; probe_listener "$d" || rc=$?
    case "$rc" in
      0) printf '%-32s %-9s %-9s %s\n' "$(basename "$d")" "$LISTENER_PID" "live" "$(registration_name "$d")"; live=$((live + 1)) ;;
      1)
        # ⛔ DEAD AND ORPHANED ARE DIFFERENT ROWS (#2892). A dead listener is capacity waiting for a
        # start; an ORPHANED row is a registration whose NEWEST evidence says GitHub deleted it, so a
        # blind `restart` cannot be assumed to recover it (the session is refused ⇒ rc 6) and the name
        # stays taken until `reclaim` retires it. Rendering both as DEAD is how a fleet reads
        # "someone will restart it" over a slot that needs a different verb.
        # ⛔ IT IS EVIDENCE, NOT PROOF (#2899 review round 6, P1): a skew-era line survives a clock
        # later corrected, and on that shape `restart` DOES recover the install (the suite's `skewline`
        # arm asserts it). `reclaim` is the verb that settles it, which is what rc 3 routes the caller
        # to — this row must not claim more than the log it read.
        if orphan_evidence_file "$d" >/dev/null 2>&1; then
          printf '%-32s %-9s %-9s %s\n' "$(basename "$d")" "-" "ORPHANED" "$(registration_name "$d")"
          orph=$((orph + 1))
        else
          printf '%-32s %-9s %-9s %s\n' "$(basename "$d")" "-" "DEAD" "$(registration_name "$d")"
          dead=$((dead + 1))
        fi ;;
      # An unreadable probe is NOT a dead listener: a report that says DEAD here would be a false
      # verdict a caller acts on, and rc 3 would claim it measured something.
      *) return 2 ;;
    esac
    # ⛔ A LIVE ROW UNDER A MISSING TMPDIR IS NOT A HEALTHY ROW (agent-infra#2937). This is the exact
    # shape that cost a full investigation of an unrelated PR: GitHub says `online`, the unit says
    # `active (running)`, the job is PICKED UP — and every job on the instance dies at `mktemp` in its
    # first seconds, so the failure presents as "this workflow is broken". The tool holds the datum
    # (`.env`) and now reads it, instead of leaving the next job to discover it.
    # ⛔ MISSING ONLY, NOT UNWRITABLE: `status` may legitimately run as a different user from the one
    # that owns the runner, so a `-w` test here would report a defect on a healthy box. The launcher
    # runs as the listener's own user and DOES refuse an unwritable target.
    t="$(instance_tmpdir "$d")" || return 2   # cannot measure: never publish tmpdir_defects=0 over it
    # ⛔ THE EFFECTIVE TEMP ROOT IS WHAT MUST EXIST (#7815): the `.env`-named path when there is one,
    # otherwise the instance's own `_tmp` — which `start_listener` creates and nothing else does. The
    # old arm returned clean for an instance naming none, so a runner whose private root had been
    # deleted read as a HEALTHY row while every job started from then on would die at `mktemp`. That is
    # the same false PASS #2937 refuses, arrived at through the other branch.
    if [ -z "$t" ]; then
      rt="$(instance_tmp_root "$d")"
      if [ ! -d "$rt" ]; then
        # The clause claims only what it measured: this tool creates the root at every START, so its
        # absence is a fact about the LAYOUT — never a claim about the env of a listener this tool did
        # not start (that one keeps whatever its unit gave it).
        err "defect tmpdir-missing name=$(basename "$d") path=$rt — the instance's private temp root is missing (this tool creates it at every start; nothing else does), so a listener started from now on inherits a TMPDIR that does not exist and its jobs die at mktemp; run: $SELF restart --name $(basename "$d")"
        tmpdir_defects=$((tmpdir_defects + 1))
      fi
    elif [ ! -d "$t" ]; then
      # ⛔ THE CLAUSE MUST MATCH THE ROW IT IS UNDER (#3004 review, P2): this arm runs for DEAD rows
      # too, where "report it healthy" is false — the row says DEAD and GitHub says offline — and only
      # the missing-TMPDIR half is true. `rc` is the state this loop already measured.
      rownote="the listener row above (and GitHub) report it healthy"
      [ "$rc" = 1 ] && rownote="the listener row above reports it DEAD"
      err "defect tmpdir-missing name=$(basename "$d") path=$t — $rownote, and every job on it dies at mktemp; run: $SELF restart --name $(basename "$d")"
      tmpdir_defects=$((tmpdir_defects + 1))
    fi
  done <<<"$dirs"
  # ⛔ QUARANTINED INSTALLS ARE NAMED, EVERY TIME, UNTIL THEY ARE GONE (#2892). A `reclaim` whose
  # files could not be all removed renames the install to `*.retired-<stamp>`; those bytes are outside
  # the pool but still on the disk, and the ONE measured failure mode this repo keeps re-learning is
  # space that nothing accounts for. They are reported here and counted in the summary, and they are
  # NOT capacity (excluded by `registered_dirs`).
  # ⛔ DOT-NAMED INSTALLS TOO (#2892 review, P2): `registered_dirs` enumerates `.foo` registrations, so
  # `reclaim` can quarantine one as `.foo.retired-<stamp>`, and a `*` glob does not match a leading dot —
  # the leftover's bytes would then be named by nothing, which is the one outcome this row exists for.
  qdirs="$(for qd in "$RUNNER_ROOT"/*.retired-* "$RUNNER_ROOT"/.[!.]*.retired-*; do [ -d "$qd" ] || [ -L "$qd" ] || continue; printf '%s\n' "$qd"; done)"
  while IFS= read -r qd; do
    [ -n "$qd" ] || continue
    # ⛔ A QUARANTINE NAME DOES NOT PROVE ITS LISTENER IS GONE (#2892 review round 2, P2). The suffix is
    # now reserved in `valid_name`, but a dir created by hand or by an older version can still hold a
    # RUNNING registration. Excluding it from `slots` stays deliberate; printing `rm -rf as its owner`
    # over a live runner is the one instruction that would delete a working registration, so a listener
    # changes the row instead of the count. An unreadable dir keeps the plain row: its bytes must still
    # be removable by their owner, and no probe could say otherwise.
    # ⛔ A PROBE THAT COULD NOT RUN IS NOT A DEAD LISTENER (#2892 review round 4, P1). `probe_listener`
    # has THREE outcomes (0 live · 1 dead · 2 cannot-measure) and the old `&& probe …` folded ALL
    # non-zero into the else, so rc 2 — a `ps` that failed or listed nothing (`process-table-unreadable`
    # / `process-table-empty`) — printed `rm -rf as its owner` over a listener that may be RUNNING. That
    # is the one instruction that deletes a working registration, printed on a read the pass never
    # completed, and the `[ -r ] && [ -x ]` guard below only covers the OTHER cause of rc 2 (an
    # unreadable dir), not this one. The unmeasurable case gets its own row and holds the rc at
    # cannot-measure, because a report that cannot see one row cannot certify the rest.
    if [ -r "$qd" ] && [ -x "$qd" ]; then
      qrc=0; probe_listener "$qd" >/dev/null 2>&1 || qrc=$?
      case "$qrc" in
        0) printf '%-32s %-9s %-9s %s\n' "$(basename "$qd")" "${LISTENER_PID:-?}" "LIVE-QUAR" "a listener is RUNNING on a retired-named install — do NOT rm -rf; stop it and retire it with reclaim" ;;
        1) printf '%-32s %-9s %-9s %s\n' "$(basename "$qd")" "-" "QUARANTINE" "retired install — rm -rf as its owner" ;;
        *) printf '%-32s %-9s %-9s %s\n' "$(basename "$qd")" "?" "UNPROBED" "could not measure whether a listener runs here (the process table was unreadable) — do NOT rm -rf until it can be read"
           qunprobed=$((qunprobed + 1)) ;;
      esac
    else
      printf '%-32s %-9s %-9s %s\n' "$(basename "$qd")" "-" "QUARANTINE" "retired install — rm -rf as its owner"
    fi
    qn=$((qn + 1))
  done <<<"$qdirs"
  # ⛔ THE SUMMARY NAMES THE READING IT IS (#2381 review round 6, P1). The rows come from the PROCESS
  # TABLE, which only holds LIVE listeners: an instance dir outside RUNNER_ROOT whose listener is DEAD
  # is invisible here, and a bare `slots=N` over it read as "the box's pool" in exactly the incident
  # `restart` exists for (two runners GitHub showed OFFLINE). The caveat travels WITH the count.
  printf 'summary live=%s dead=%s slots=%s ceiling=%s pool_read=process-table-live-only orphaned=%s registrations=%s quarantine=%s tmpdir_defects=%s\n' "$live" "$dead" "$SLOTS" "$CEILING" "$orph" "$SLOT_REGS" "$qn" "$tmpdir_defects"
  # After the measured rows, so the report is visible — but the count it publishes is NOT this box's
  # pool, so the rc must not claim a complete measurement.
  if [ -n "$outside" ]; then
    err "cannot-measure why=pool-root-incomplete root=$RUNNER_ROOT outside=$(join_lines "$outside") — a LIVE listener runs from an instance dir OUTSIDE RUNNER_ROOT, so slots=$SLOTS counts a PARTIAL pool; set RUNNER_ROOT to the directory that CONTAINS every instance dir (one level above them) and re-read — ⚠️ this reading is the process table, so consolidating the parents is what makes it complete; an instance dir outside RUNNER_ROOT whose listener is DEAD is not enumerable at all"
    return 2
  fi
  # ⛔ AN UNPROBED QUARANTINE IS A PARTIAL MEASUREMENT, NOT A CLEAN ONE (#2892 review round 4, P1).
  # The rows are printed either way — an operator must see WHICH directory could not be probed — but the
  # rc must not claim the box was measured.
  [ "$qunprobed" -eq 0 ] || return 2
  # ⛔ A MISSING TMPDIR IS A DEFECT THE CALLER MUST BE ABLE TO BRANCH ON, like a DEAD listener: rc 0
  # over a row whose jobs cannot run is the false PASS this arm exists to refuse (agent-infra#2937).
  [ "$dead" -eq 0 ] && [ "$orph" -eq 0 ] && [ "$tmpdir_defects" -eq 0 ] || return 3
  return 0
}

cmd_add() {
  local name="" dir token rc
  while [ $# -gt 0 ]; do
    case "$1" in
      --name) take_name_value add "$#" "${2:-}" || return 1; name="${2:-}"; shift 2 ;;
      --dry-run) DRY=1; shift ;;
      *) err "usage: add --name <runner-name> [--dry-run]"; return 1 ;;
    esac
  done
  if ! valid_name "$name"; then
    # ⛔ THE REFUSAL NAMES THE RULE THE NAME ACTUALLY BREAKS (#2899 review round 6, P2), and keeps the
    # general contract as the second half so a caller still learns what a legal name looks like.
    err "usage: add --name <runner-name> — refused: $NAME_WHY (a name must be [A-Za-z0-9._-], must not start with '.', must not contain '/', and must not carry the reserved '.retired-' quarantine suffix)"; return 1
  fi
  # ⛔ THE NAME'S OWN VERDICT COMES BEFORE THE BOX'S. A name availability check placed AFTER the
  # floor/ceiling gates returned rc 3 on a box at its ceiling even when the name was already
  # registered — so a caller branching on the documented "4 = that name is taken, try another"
  # could never see the name condition it was asking about. These checks read no capacity, so
  # running them first costs nothing and costs the caller nothing.
  dir="$RUNNER_ROOT/$name"
  if [ -e "$dir" ] || [ -L "$dir" ]; then
    if [ -e "$dir/.runner" ] || [ -L "$dir/.runner" ]; then
      err "name-unavailable name=$name already registered at $dir — use restart"; return 4
    fi
    # ⛔ `-e`, NOT `-d`. A caller-supplied path may be a FILE (an operator's notes, a symlink to a
    # shared install), and a `-d` test let it through to `cp -aL`; the copy then fails and the
    # cleanup below does `rm -rf "$dir"` — DELETING the operator's file to tidy up after our own
    # failure. Anything already at the target path is refused, and its message does not claim it
    # is a directory.
    err "name-unavailable name=$name path=$dir already exists (a file, a symlink, or a directory without a .runner registration) — clear it or pick another name"; return 4
  fi
  readings || return 2

  # ⛔ MEMORY FIRST: the owner's binding constraint is memory, not cores (#2344 comment 6347825624).
  if [ "$MEM_MB" -lt "$MEM_FLOOR_MB" ]; then
    err "REFUSED add name=$name MemAvailable=$(mb_as_gb "$MEM_MB") GB is below the $(mb_as_gb "$MEM_FLOOR_MB") GB floor (read ${MEM_MB} MB, floor ${MEM_FLOOR_MB} MB) — nothing added"
    return 3
  fi
  slots || return 2
  # ⛔ A CEILING COUNTED FROM PART OF THE BOX IS NOT THE CEILING (#2381 review, P1). This gate is the
  # last thing between the pass and a registration, so it refuses rather than trusting a listing that
  # provably excludes a live listener.
  require_pool_complete add || return 2
  if [ "$SLOTS" -ge "$CEILING" ]; then
    err "REFUSED add name=$name slots=$SLOTS ceiling=$CEILING ncpu=$NCPU cores_per_slot=$CORES_PER_SLOT MemAvailable=$(mb_as_gb "$MEM_MB") GB floor=$(mb_as_gb "$MEM_FLOOR_MB") GB — above the core-aware ceiling, nothing added"
    return 3
  fi

  # The marker the pool gate selects on. Without it the runner is registered, advertised and idle —
  # and a TYPO in the override would produce exactly that with rc 0, so the marker is required to be
  # present in whatever we are about to pass to config.sh.
  local label="${RUNNER_LABELS:-}"
  if [ -z "$label" ]; then
    label="$(pool_label_for_host)" || label=""
    if [ -z "$label" ]; then
      err "cannot-measure why=arch-unknown uname_m=$(uname -m 2>/dev/null || printf '?') — set RUNNER_LABELS to the pool marker ($POOL_LABEL_X64 or $POOL_LABEL_ARM64)"; return 2
    fi
  fi
  case ",$label," in
    *",$POOL_LABEL_X64,"*|*",$POOL_LABEL_ARM64,"*) ;;
    *) err "cannot-measure why=label-unknown value=$label — a runner without $POOL_LABEL_X64/$POOL_LABEL_ARM64 matches no job and is invisible to ci_runner_gate.sh"; return 2 ;;
  esac
  log_line "reading: MemAvailable=$(mb_as_gb "$MEM_MB") GB (${MEM_MB} MB) floor=$(mb_as_gb "$MEM_FLOOR_MB") GB ncpu=$NCPU ceiling=$CEILING slots=$SLOTS labels=$label"

  [ -x "$RUNNER_TEMPLATE/config.sh" ] || {
    err "cannot-act why=runner-template-absent path=$RUNNER_TEMPLATE/config.sh (one complete runner install to copy)"; return 2
  }
  if [ "$DRY" = 1 ]; then
    # The registration token is the add's last precondition and is minted AFTER this return (a dry run
    # must not POST). So the preview requires a token SOURCE — and says so — rather than announcing an
    # add the pass cannot make. A `gh` that is present but unauthenticated is the one residual a
    # side-effect-free probe cannot see; it is named here rather than papered over.
    if [ -z "${RUNNER_TOKEN:-}" ] && ! command -v "$GH_CMD" >/dev/null 2>&1; then
      err "cannot-act why=no-registration-token repo=$POOL_REPO (set RUNNER_TOKEN, or put $GH_CMD on PATH) — a preview cannot mint one"; return 2
    fi
    log_line "dry-run: would copy $RUNNER_TEMPLATE to $dir, register name=$name and start its listener"; return 0
  fi

  token="${RUNNER_TOKEN:-}"
  if [ -z "$token" ]; then
    # A registration token is single-use and expires in ~1h, so it is minted per add and never stored.
    token="$("$GH_CMD" api -X POST "repos/$POOL_REPO/actions/runners/registration-token" --jq .token 2>/dev/null)" || token=""
  fi
  case "$token" in
    ''|null|*[[:space:]]*) err "cannot-act why=no-registration-token repo=$POOL_REPO (set RUNNER_TOKEN, or authenticate $GH_CMD)"; return 2 ;;
  esac

  # ONE COMPLETE INSTALL PER INSTANCE (see the header): config.sh writes `.runner` beside ITSELF.
  # ⛔ THE CLAIM IS ATOMIC. `mkdir` is the only filesystem verb here that FAILS when another pass has
  # taken the name; the `[ -e "$dir" ]` check above is check-then-act, and `cp -aL <template> <existing
  # dir>` NESTS into it rather than failing — so two overlapping invocations (a hand `add` during a
  # scheduled `reconcile`, two operators) would both configure ONE instance: a second registration
  # token spent, `.runner` overwritten, the GitHub-side registration orphaned, and both passes
  # reporting an add neither uniquely made (measured: two simultaneous passes both reported
  # `added name=pi-runner-…-1`).
  if ! mkdir "$dir" 2>/dev/null; then
    if [ -e "$dir" ] || [ -L "$dir" ]; then
      err "name-unavailable name=$name path=$dir appeared while this add ran (another pass took it) — use restart"; return 4
    fi
    err "cannot-act why=template-copy-failed from=$RUNNER_TEMPLATE to=$dir (the instance dir could not be created)"; return 2
  fi
  # ⛔ THE CEILING IS RE-READ AFTER THE NAME IS CLAIMED. The gate above is a SNAPSHOT taken before the
  # token mint, so two passes adding DIFFERENT names both clear it and the box ends ABOVE the owner's
  # core-aware bound with both rc 0 (measured: 4 registrations on a 3-slot box). `mkdir` is the
  # serialisation point: a pass that lost the race hears it here and gives the directory back.
  # ⚠️ Residual: two passes can still both read `slots` before either writes its `.runner`; closing that
  # completely needs a pool-level lock, which is a declared follow-up (a lock that survives a killed
  # pass is machinery of its own).
  if ! slots; then
    rm -rf "$dir"
    err "cannot-measure why=runner-root-unreadable path=$RUNNER_ROOT (the ceiling could not be re-read after claiming $name; the claim was released)"; return 2
  fi
  # The SAME completeness check as the pre-claim gate: an outside listener can appear (a hand add, a
  # peer pass with a different root) between the two reads, and the claim is released rather than
  # turned into a registration the ceiling never counted.
  if ! require_pool_complete add; then rm -rf "$dir"; return 2; fi
  if [ "$SLOTS" -ge "$CEILING" ]; then
    rm -rf "$dir"
    err "REFUSED add name=$name slots=$SLOTS ceiling=$CEILING — another pass took the free slot while this add ran; nothing added"
    return 3
  fi
  # ⛔ `-L`, NOT a bare `-a`: `cp -a` is `--no-dereference`, so a SYMLINKED template would produce a
  # symlinked instance — every alias then shares ONE install and one listener, `listener_pid` reads
  # them all LIVE through the shared physical path (so a dead one is never restarted), the template
  # is mutated by the first config, and each alias eats a slot it does not own. Dereferenced, the copy
  # is a real install or it is nothing — so the install is checked, not assumed.
  if ! cp -aL "$RUNNER_TEMPLATE/." "$dir/" 2>/dev/null; then
    rm -rf "$dir"   # a partial install is invisible to `slots` and would block this name forever
    err "cannot-act why=template-copy-failed from=$RUNNER_TEMPLATE to=$dir (the partial copy was removed)"; return 2
  fi
  if [ -L "$dir" ] || [ ! -f "$dir/config.sh" ]; then
    rm -rf "$dir"
    err "cannot-act why=template-not-copied template=$RUNNER_TEMPLATE ($dir has no config.sh — the copy was removed)"; return 2
  fi
  # ⛔ THE LOG LIVES OUTSIDE THE INSTANCE DIR, because the instance dir is REMOVED on failure and
  # config.sh's stderr is the only diagnostic for the commonest real failures (name taken on GitHub,
  # token already used/expired, disk full). A `see=` path pointing into a directory we just deleted
  # is worse than no pointer at all.
  local cfglog="$RUNNER_ROOT/.config-$name.log"
  # ⛔ `--url` IS REQUIRED, NOT OPTIONAL. GitHub's own `config.sh --help` says "Repository to add the
  # runner to. Required if unattended", `CommandSettings.GetUrl()` passes an EMPTY default, and
  # PromptManager's unattended arm THROWS on an empty non-optional value ("Invalid configuration
  # provided for --url. Terminating unattended configuration.") instead of falling back to the
  # token's repo. Without it every real add failed at config and reported it as a NAME problem
  # (rc 5, "a token it consumed may have registered the name") — and the suite stayed green because
  # its config stub ignored argv. Derived from POOL_REPO in ONE place so the two cannot drift.
  local pool_url="https://github.com/$POOL_REPO"
  local -a args=(--unattended --url "$pool_url" --name "$name" --work "$dir/_work" --labels "$label" --token "$token")
  if ! "$dir/config.sh" "${args[@]}" >"$cfglog" 2>&1; then
    # Nothing valid exists yet, and a full runner install left behind is invisible to `slots`, never
    # bounded by the ceiling, and would make the next pass mint another name — so it goes.
    rm -rf "$dir"
    # ⛔ rc 5, NOT rc 2: a config failure is about THIS NAME (GitHub already holds it, the token was
    # spent, this dir's permissions), while the gates an rc 2 reports are about the BOX. Ending the
    # pass here is how a box that rebooted `/tmp` — every local `.runner` gone, every name still taken
    # on GitHub — could never re-provision the pool this pass exists to recover.
    err "name-failed why=config-failed see=$cfglog (the installation was removed; GitHub-side state is unknown — a token it consumed may have registered the name); trying the next name"; return 5
  fi
  # config.sh's own `.runner` marker is the proof the registration happened — never the exit code
  # alone (a config that "succeeded" without writing `.runner` has registered nothing).
  if [ ! -f "$dir/.runner" ]; then
    rm -rf "$dir"
    err "name-failed why=no-registration-marker dir=$dir see=$cfglog (the installation was removed); trying the next name"; return 5
  fi
  rm -f "$cfglog"   # the marker proves the registration; a successful log is no longer news
  if ! start_listener "$dir"; then
    # The registration EXISTS now. Saying "nothing changed" here would be false, and the retry is
    # refused by the `.runner` check above — so name the state and the way back.
    err "registered=1 listener=dead name=$name dir=$dir — the registration is in place; run: $SELF restart --name $name"
    return 2
  fi
  log_line "added name=$name dir=$dir listener_pid=$(listener_pid "$dir")"
  return 0
}

cmd_restart() {
  local name="" dir rc
  while [ $# -gt 0 ]; do
    case "$1" in
      --name) take_name_value restart "$#" "${2:-}" || return 1; name="${2:-}"; shift 2 ;;
      --dry-run) DRY=1; shift ;;
      *) err "usage: restart --name <runner-name> [--dry-run]"; return 1 ;;
    esac
  done
  # ⛔ `restart` ADDRESSES something that already exists, so it must not impose `add`'s creation
  # rules: the migration population this tool was written for is hand-provisioned and its names were
  # never validated (`bad name` is a legal directory). Rejecting those would leave that listener dead
  # forever AND make every reconcile pass exit 2 on an otherwise healthy box. Only path ESCAPES are
  # refused here.
  case "$name" in ''|.|..|-*|*/*) err "usage: restart --name <runner-name> — a name must not be empty, start with '-', be '.'/'..', or contain '/'"; return 1 ;; esac
  dir="$RUNNER_ROOT/$name"
  # ⛔ JUDGE THE ROOT BEFORE CONCLUDING "NO REGISTRATION". Every test on `$RUNNER_ROOT/$name` needs `x`
  # on the ROOT (traversal — NOT `r`: `restart` addresses a KNOWN name and never lists the pool, so a
  # mode-111 root is legitimate here and must not be refused). A non-searchable root made this verb
  # report a registration that EXISTS as missing and send the operator to `add` it (which then refuses
  # rc 4 on the existing directory) — the same false verdict `status` refuses to print. An ABSENT root
  # still falls through to rc 3 "no registration"; a root that is not a directory is named as such.
  if [ -e "$RUNNER_ROOT" ] || [ -L "$RUNNER_ROOT" ]; then
    if [ ! -d "$RUNNER_ROOT" ]; then
      err "cannot-measure why=runner-root-not-a-directory path=$RUNNER_ROOT"; return 2
    fi
    if [ ! -x "$RUNNER_ROOT" ]; then
      err "cannot-measure why=runner-root-unreadable path=$RUNNER_ROOT"; return 2
    fi
  fi
  # ⛔ AN UNREADABLE INSTANCE IS cannot-measure, NOT "no registration": `-f .runner` is FALSE for a
  # registration we cannot reach, and the message would send the operator to `add` a runner that is
  # already registered (the same false verdict `status` must never print). This guard DEREFERENCES a
  # KNOWN name, so traversal (`x`) is what it needs; `probe_listener` below independently requires
  # `r`+`x` before liveness is judged, so do not "restore symmetry" by relaxing that one too.
  if [ ! -x "$dir" ]; then
    if [ -d "$dir" ]; then
      err "cannot-measure why=instance-unreadable path=$dir"; return 2
    fi
    # ⛔ A PATH THAT EXISTS IS NOT A MISSING REGISTRATION (#2381 review round 2, P2): a FILE or a
    # DANGLING SYMLINK squatting on the name is refused by `add` (rc 4, "clear it or pick another
    # name"), so "add it first" here sent the operator to a verb that cannot help — the two-verb
    # bounce this file exists to end, surviving for every non-directory shape because this arm only
    # asked "is it a traversable directory".
    if [ -e "$dir" ] || [ -L "$dir" ]; then
      err "REFUSED restart name=$name path=$dir exists but is not a searchable directory (a file or a symlink) — clear it, or pick another name; nothing changed"; return 3
    fi
    # ⛔ BEFORE CONCLUDING "NO REGISTRATION", ASK WHERE THE POOL ACTUALLY LIVES (#2381 review, P1).
    # A registration under another parent is not missing, and "add it first" is the one remedy that
    # cannot help (add refuses a name it cannot see, and the operator is sent to re-register a runner
    # that already exists).
    require_pool_complete restart || return 2
    # ⛔ THIS READ IS THE PROCESS TABLE, AND IT ONLY SEES LIVE LISTENERS (#2381 review round 6, P1).
    # A registration under another parent whose listener is DEAD is invisible here, so "no
    # registration" would be a measured claim the tool did not measure — and "(add it first)" is the
    # one verb that cannot help (add refuses a held name and cannot see the other parent either). The
    # message names the limitation and the real next step instead of asserting absence.
    err "REFUSED restart name=$name no registration at $dir — nothing changed. ⚠️ this read is the PROCESS TABLE (ps), so an instance dir OUTSIDE RUNNER_ROOT=$RUNNER_ROOT whose listener is DEAD is invisible here: check the other parents on this box (e.g. the installs §'pool is every runner on the box' names), or set RUNNER_ROOT to the parent that CONTAINS every instance dir"; return 3
  fi
  # ⛔ ONE REGISTRATION, ONE DEFINITION (#2381 review, P2). The listing (`registered_dirs`) and `add`
  # both accept a `.runner` that is a FILE **or a SYMLINK** (`-e || -L`); this verb required `-f`,
  # which is FALSE for a symlink whose target is a directory or does not exist. The verbs then read
  # ONE registration two ways and bounced the operator forever: `add` answered "already registered —
  # use restart" (rc 4) and `restart` answered "no registration — add it first" (rc 3), so an
  # enumerated, DEAD slot could never be restarted — it stayed advertised to GitHub and idle, which is
  # the one state `restart` exists to end. `-f` here was also the false verdict the guard above
  # refuses to print, arrived at by a different predicate: a registration we cannot inspect is
  # `cannot-measure`, never "no registration".
  if [ ! -e "$dir/.runner" ] && [ ! -L "$dir/.runner" ]; then
    # ⛔ "ADD IT FIRST" IS NOT A REMEDY HERE (#2381 review, P2): the directory EXISTS, so `add`
    # refuses this same path as unavailable (rc 4) and the operator bounces between two verbs forever.
    # Name the state that was measured and the action that actually clears it.
    err "REFUSED restart name=$name path=$dir exists but carries no .runner registration (a file, a symlink, or a directory without one) — clear it, or pick another name; nothing changed"; return 3
  fi
  # ⛔ NO MEMORY FLOOR ON THIS PATH, DELIBERATELY (#2373). The floor gates ADDING a new runner. A
  # dead listener for an EXISTING registration costs ~200 MB to bring back and is capacity the box has
  # already paid for; refusing it on a low-memory box would leave the slot registered, advertised and
  # idle — the worst of the three states. The owner's floor sentence names ADDING, not restarting.
  rc=0; probe_listener "$dir" || rc=$?
  case "$rc" in
    # ⛔ A LIVE LISTENER IS NOT A REPAIRED BOX (#3004 review, P1). The scenario THIS TOOL EXISTS FOR is
    # the post-reboot one: the instance dir is persistent and its unit is enabled, so the LISTENER
    # SURVIVES while its /tmp TMPDIR does not. `start_listener` cannot help there — nothing is started —
    # so skipping the live arm made `restart`, the very remedy `status` prints, answer "not touched"
    # and exit 0 over the still-broken box: a false PASS handed to the operator, and the PR's own claim
    # ("start-time, so a reboot cannot undo it") false for the reboot it documents. Creating a
    # directory does not touch, restart or double-start a listener — the invariant this line states
    # still holds; the env the listener ALREADY has is simply made satisfiable at last.
    0) ensure_tmpdir "$dir" "$LISTENER_PID" || return 2
       log_line "live name=$name pid=$LISTENER_PID — not touched"; return 0 ;;
    2) return 2 ;;   # cannot measure: START NOTHING (a blind start is how a listener is doubled)
  esac
  # ⛔ THE START'S OWN PRECONDITION IS CHECKED BEFORE THE DRY RETURN, so a preview cannot announce a
  # start the real pass refuses. `start_listener` re-checks it (defence in depth), but a check that
  # only lives downstream of the `--dry-run` return is a preview that lies.
  [ -x "$dir/run.sh" ] || { err "cannot-act why=runner-not-installed path=$dir/run.sh"; return 2; }
  # ⛔ AND SO IS THE ENV PRECONDITION (#3004 review, P2): it lives in `start_listener`, i.e. downstream
  # of this DRY return, so an uncreatable TMPDIR previewed as "would start the listener" (rc 0) and
  # then refused for real (rc 2). `ensure_tmpdir` is DRY-aware: it REPORTS the creation it would make
  # and refuses an unsatisfiable target, mutating nothing.
  ensure_tmpdir "$dir" || return 2
  if [ "$DRY" = 1 ]; then log_line "dry-run: would start the listener for name=$name"; return 0; fi
  rc=0; start_listener "$dir" || rc=$?
  case "$rc" in
    0) log_line "restarted name=$name pid=$(listener_pid "$dir")"; return 0 ;;
    # ⛔ 6 IS PASSED THROUGH, NOT FOLDED INTO 2 (#2892). "I could not act" and "this registration is
    # GONE server-side" lead an operator to opposite next steps — re-run versus `reclaim` — and the
    # caller that matters here is `reconcile`, which routes 6 to the retire arm and counts 2 as
    # cannot-measure. Folding them is how the orphan kept being counted `restarted`.
    6) return 6 ;;
    *) return 2 ;;
  esac
}

# ── reclaim: RETIRE a registration GitHub has deleted (agent-infra#2892) ─────────────────────────
# WHAT THIS FIXES. Every other verb treats `.runner` as proof that a registration exists, so an
# install whose registration GitHub deleted is stuck in a state no verb can leave: `add` refuses the
# name (rc 4 "already registered"), `restart` starts a listener that dies at +4 s (rc 6), and
# `reconcile` counts it against the ceiling forever. Measured on `pi-cell-4` 2026-10-27: TWO such
# states (`--replace` on a name whose old registration is deleted server-side), and a `config.sh`
# that answers: "Cannot configure the runner because it is already configured. To reconfigure the
# runner, run 'config.cmd remove' or './config.sh remove' first". `--replace` cannot help: that refusal
# is the LOCAL precondition, raised before the flag is read (actions/runner#1021, #3238, #756).
#
# WHAT IT DOES INSTEAD. GitHub's own documented local cleanup for a registration that no longer
# exists is removing the install, and `config.sh remove` needs a REMOVE TOKEN this box may not be able
# to mint (the runner-scope API also rate-limits — measured: `gh api .../actions/runners` answered with
# a rate-limit body on the same box that was busy renewing jobs). So: delete the install, and say so.
#
# ⛔ FOUR GUARDS, EACH ONE MEASURED, EACH ONE BEFORE THE DELETE:
#   1. EVIDENCE, NOT AN INFERENCE. The newest log this registration's own listener wrote must carry
#      GitHub's "registration has been deleted from the server" line, dated no earlier than the
#      `.runner` marker itself (an install re-registered in place keeps old logs; they are not evidence
#      about its CURRENT registration).
#   2. THE CLOCK MUST BE SANE. GitHub emits that same line when session creation fails on a skewed
#      clock (actions/runner#4648, #1798), so on a box whose clock cannot be shown to be within
#      RUNNER_MAX_SKEW_S the pass REFUSES rather than deleting a healthy runner. Declining costs one
#      idle slot; guessing costs a runner and a re-registration token.
#   3. A NAME A LIVE SIBLING HOLDS IS NOT RE-REGISTERED. Two directories can carry one `agentName`
#      (measured here), and registering that name again DELETES whichever registration holds it — the
#      precise bug that created this orphan. The stale install is removed; the name is left alone.
#   4. IT NEVER TOUCHES A LIVE LISTENER, and `--dry-run` deletes nothing.
cmd_reclaim() {
  local name="" only=0 dirs="" d nm aid rc ev retired=0 preserved=0 live=0 cannot=0 skew="" clock_checked=0 sib="" sib_unknown=0 q="" removed=1 qn=0 revived=0 vrc=0 verout="" sib_scan=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --name) take_name_value reclaim "$#" "${2:-}" || return 1; name="${2:-}"; only=1; shift 2 ;;
      --dry-run) DRY=1; shift ;;
      *) err "usage: reclaim [--name <name>] [--dry-run]"; return 1 ;;
    esac
  done
  if [ "$only" = 1 ]; then
    case "$name" in ''|.|..|-*|*/*) err "usage: reclaim --name <name> — a name must not be empty, start with '-', be '.'/'..', or contain '/'"; return 1 ;; esac
    d="$RUNNER_ROOT/$name"
    if [ ! -e "$d" ] && [ ! -L "$d" ]; then
      err "REFUSED reclaim name=$name path=$d — no such directory under $RUNNER_ROOT; nothing changed"; return 3
    fi
    if [ ! -e "$d/.runner" ] && [ ! -L "$d/.runner" ]; then
      # ⛔ NOT `add --name` (#2892 review round 4, P2). `add` refuses an existing path with rc 4
      # (`name-unavailable … already exists (a file, a symlink, or a directory without a .runner
      # registration)`), so naming it here sends the operator into the two-verb bounce this file
      # resolves for `restart` above. The remedy is to clear the path, or to complete the install in
      # place — neither of which this verb can do.
      err "REFUSED reclaim name=$name path=$d — no .runner registration to retire (that dir is not a registration; 'add' refuses an existing path, so the remedy is: remove $d, or complete the install inside it before reclaiming); nothing changed"; return 3
    fi
    dirs="$d"
  else
    dirs="$(registered_dirs)" || return 2
    # ⛔ THE SCAN ARM IS THE ONE VERB PATH WITH NO COMPLETENESS GATE, AND IT IS THE DELETE PATH
    # (#2899 review round 5, P2). Without this, `RUNNER_ROOT` naming a directory that is not the box's
    # pool yields an EMPTY (but readable) listing, the loop below never runs — so guard 3's own
    # `outside_listener_dirs` read at `sib` is never reached either — and the pass prints
    # `reclaim: retired=0 preserved=0 revived=0 live=0 …` and exits 0. "The pool is clean" and "I
    # listed an empty directory" become the same line, over an unread pool, from the verb that
    # deletes. `status`, `reconcile`, `add` and `restart` all refuse this state (require_pool_complete
    # / their own outside read), and the recovery recipe this change documents (§6 step 2 of
    # docs/research/2026-10-27-runner-pool-self-healing.md) tells the operator to run exactly
    # `reclaim --dry-run` then `reclaim` — on the `pi-cell-4` shape, where the installs live under
    # `/opt` and the root defaults elsewhere. So the gate that every other verb passes is applied here
    # too: a listing that is not the box's pool is not a listing to report a clean pass over.
    # `--name` is deliberately NOT gated: it names one directory explicitly and never reads the pool
    # as a whole, so an incomplete root cannot make its verdict wrong.
    require_pool_complete reclaim || return 2
  fi
  while read -r d; do
    [ -n "$d" ] || continue
    if [ ! -e "$d/.runner" ] && [ ! -L "$d/.runner" ]; then
      [ "$only" = 1 ] && { err "REFUSED reclaim name=$name path=$d — no .runner registration to retire; nothing changed"; return 3; }
      continue
    fi
    rc=0; probe_listener "$d" || rc=$?
    case "$rc" in
      0) live=$((live + 1)); log_line "live name=$(basename "$d") pid=$LISTENER_PID — not touched"; continue ;;
      2) cannot=$((cannot + 1)); continue ;;   # unreadable: cannot prove anything about it
    esac
    # ⛔ A SYMLINKED INSTANCE IS NOT RETIRABLE BY THIS VERB (#2892 review, P1). `registered_dirs`
    # deliberately counts a symlink-to-install as in-pool, but `mv` would rename the LINK and `rm -rf`
    # would remove only the link: the pass would print `retired … the name is free again` and its own
    # `[ -e "$q" ]` read-back would confirm it, while the real install — its `.runner` and its GB —
    # survives, unnamed and outside every verb. That is the exact failure the rename-first design
    # exists to prevent, reported as a clean success. Retiring through a link would also be a guess
    # about which of the two paths the operator meant, so it refuses and names the path.
    if [ -L "$d" ]; then
      err "cannot-act why=instance-is-symlink dir=$d target=$(readlink "$d" 2>/dev/null || printf '?') — the pool entry is a LINK, so renaming it would move the link and leave the install behind; retire the resolved path instead (move it under a name this tool owns, then re-run), nothing changed"
      cannot=$((cannot + 1)); continue
    fi
    if ! ev="$(orphan_evidence_file "$d")"; then
      preserved=$((preserved + 1))
      # ⛔ THE REMEDY MUST EXIST FOR THE NAME IT IS PRINTED ABOUT (#2899 review round 6, P3). Reachable
      # through `reclaim --name <quarantine>`: the basename carries the reserved `*.retired-` suffix, and
      # `restart` (which refuses only ''/'.'/'..'/'-*'/'*/*') would happily start a listener on it —
      # re-creating the LIVE-QUAR state `status` warns about, from the tool's own printed advice. A
      # retired-named install is never capacity and is never startable ON PURPOSE; its bytes belong to
      # its owner. The listener here is already proven DEAD (rc 0 returned above as `live`, rc 2 as
      # `cannot`), so pointing at `rm -rf` cannot delete a running registration.
      case "$(basename "$d")" in
        *.retired-*) log_line "preserve name=$(basename "$d") dir=$d why=no-orphan-evidence (a retired-named install is never capacity and no verb re-registers it: when you no longer need the bytes, rm -rf it as its owner)" ;;
        *) log_line "preserve name=$(basename "$d") dir=$d why=no-orphan-evidence (no listener and no 'registration has been deleted' line in listener.log/_diag — retirable with 'config.sh remove', but not by this verb: use: $SELF restart --name $(basename "$d"))" ;;
      esac
      continue
    fi
    if [ "$clock_checked" = 0 ]; then
      clock_checked=1
      if ! skew="$(clock_skew_s)"; then
        err "cannot-measure why=clock-unverified — the offset of this box's clock from GitHub's could not be read, and that same GitHub message is ALSO what a skewed clock produces (actions/runner#4648): this pass deletes nothing it cannot date. Retire by hand after checking the clock, or re-run with network access to https://api.github.com"
        return 2
      fi
      if [ "$skew" -gt "$MAX_SKEW_S" ]; then
        err "REFUSED reclaim skew=${skew}s bound=${MAX_SKEW_S}s — this box's clock is ${skew}s off GitHub's, and a skewed clock makes a HEALTHY registration print the same 'registration has been deleted' line this verb retires on: fix the clock first (timedatectl status / NTP), then re-run; nothing changed"
        return 3
      fi
    fi
    nm="$(registration_name "$d")"
    aid="$(registration_agent_id "$d")"; [ -n "$aid" ] || aid="?"
    sib=""; sib_unknown=0
    # ⛔ AN UNPROVEN *OWN* NAME IS "UNVERIFIED" TOO — NOT "NOTHING HOLDS IT" (#2892 review round 3, P1).
    # Guard 3 compares the retiring install's name against the pool, so an unreadable OWN name used to
    # skip the whole guard (`if [ "$nm" != "?" ]`) and leave `sib_unknown=0` — which printed "the name
    # is free again; run: add --name <basename>", the exact instruction that DELETES whichever live
    # runner holds that name. Reachable without exotic permissions: `add` accepts an EMPTY `.runner` as
    # proof of registration (`-f` only), so a `{}` marker sends a real install down this path. An
    # unknown own name proves as little as an unknown sibling's, so it takes the same verdict.
    if [ -z "$nm" ]; then nm="?"; sib_unknown=1; fi
    # The name to provision again is the GITHUB name when it was readable (that is what GitHub holds),
    # and this directory's own name otherwise — `add --name '?'` is not a usable instruction.
    local next="$nm"; valid_name "$next" || next="$(basename "$d")"
    # Guard 3: a LIVE sibling holding this name must not have its registration re-created (a fresh
    # register with the same name DELETES it — the exact event that orphans the install being retired).
    # ⛔ GUARD 3 MUST NOT DEGRADE TO "NO SIBLING" WHEN THE POOL CANNOT BE READ (#2892 review, P1).
    # `2>/dev/null` turned an unreadable listing into an empty one, and an empty one makes `sib=""`,
    # which makes the message tell the operator to `add --name <name>` — the one action that DELETES
    # whichever registration still holds it. Same for a live holder OUTSIDE `RUNNER_ROOT`: the pool is
    # every runner on the box, so the outside read counts too. Both are refusals, never a guess.
    # ⛔ AND A POOL ENTRY WE COULD NOT READ IS NOT "NO SIBLING EITHER" (#2892 review round 2, P2).
    # `registration_name` returns EMPTY on an unreadable `.runner`, and the old `[ "$(…)" = "$nm" ]
    # || continue` therefore DROPPED that entry before liveness was asked — so an unreadable holder
    # vanished from the check, `sib` stayed empty, and the pass printed "the name is free again; run:
    # add". An unreadable probe (rc 2) was read the same way. Both now mark the name UNVERIFIED, which
    # suppresses the re-register advice: the retire itself is still guarded by a fresh refusal + the
    # clock, but the one instruction that can delete a working runner is never printed on a guess.
    # ⛔ AND THE HOLDER MAY BE SITTING IN A QUARANTINE DIRECTORY (#2892 review round 3, P2). `registered_dirs`
    # excludes `*.retired-*` BY NAME (correct — a retired runner must never re-enter capacity), so a
    # listener still RUNNING on a quarantined install was invisible to guard 3 — while this very file
    # gives that state its own `status` row (LIVE-QUAR) and `valid_name`'s comment concedes such a dir
    # "can still hold a RUNNING registration". It is enumerated here for the HOLDER SCAN ONLY, by the
    # same globs `status` uses; capacity is never counted from it.
    sib_scan=""
    if [ "$nm" != "?" ]; then
      local e plist en prc qd qlist
      if ! plist="$(registered_dirs)"; then
        err "cannot-measure why=runner-root-unreadable path=$RUNNER_ROOT (the LIVE-holder check could not list the pool, so this pass cannot tell whether re-registering $nm would delete a working runner; nothing was retired)"
        cannot=$((cannot + 1)); continue
      fi
      qlist=""
      for qd in "$RUNNER_ROOT"/*.retired-* "$RUNNER_ROOT"/.[!.]*.retired-*; do
        [ -d "$qd" ] || [ -L "$qd" ] || continue
        qlist="$qlist$( [ -n "$qlist" ] && printf '\n' )$qd"
      done
      sib_scan="$(printf '%s\n%s' "$plist" "$qlist")"
      while read -r e; do
        [ -n "$e" ] || continue
        [ "$e" = "$d" ] && continue
        # ⛔ "NO `.runner`" IS NOT "UNREADABLE" (#2892 review round 4, P2). The scan set now includes
        # `*.retired-*` quarantine dirs, and a quarantine normally HAS no `.runner` — rename-then-delete
        # unlinks it first, which is the measured `pi-cell-4` failure this design exists for. Reading
        # that as "a pool entry could not be read" marked the NAME unverified on every later pass, so
        # the recovery this verb documents (`reclaim` → `add --name …`) never printed again on a box
        # with one leftover. A readable dir carrying no `.runner` provably holds no registration, so it
        # cannot hold the name either: only "unreadable dir" or "a `.runner` whose agentName cannot be
        # parsed" leaves the name UNVERIFIED.
        if [ ! -e "$e/.runner" ] && [ ! -L "$e/.runner" ] && [ -r "$e" ] && [ -x "$e" ]; then continue; fi
        en="$(registration_name "$e")"
        if [ -z "$en" ]; then sib_unknown=1; continue; fi
        [ "$en" = "$nm" ] || continue
        prc=0; probe_listener "$e" >/dev/null 2>&1 || prc=$?
        if [ "$prc" -eq 0 ]; then sib="$e"; break; fi
        [ "$prc" -eq 2 ] && sib_unknown=1
      done <<<"$sib_scan"
      if [ -z "$sib" ] && ! outside="$(outside_listener_dirs)"; then
        err "cannot-measure why=pool-root-incomplete root=$RUNNER_ROOT (the LIVE-holder check could not enumerate listeners outside the root; nothing was retired)"
        cannot=$((cannot + 1)); continue
      fi
      # A live listener outside the root holding this name counts exactly like an in-pool sibling.
      if [ -z "$sib" ] && [ -n "${outside:-}" ]; then
        while read -r e; do
          [ -n "$e" ] || continue
          en="$(registration_name "$e")"
          if [ -z "$en" ]; then sib_unknown=1; continue; fi
          [ "$en" = "$nm" ] || continue
          sib="$e"; break
        done <<<"$outside"
      fi
    fi
    # ⛔ THE RETIREMENT NEEDS A REFUSAL PRODUCED UNDER THE CLOCK WE JUST VERIFIED — NOT AN OLD LINE
    # (#2892 review round 3, P1). The check above proves this box's clock is sane NOW; the deletion line
    # in the log was written EARLIER, by a clock nobody verified and cannot now be dated. On
    # actions/runner#4648's measured shape the runner prints that line, EXITS PERMANENTLY and is never
    # restarted — so after NTP corrects the clock the newest log is STILL the skew-era line, the install
    # is DEAD and the registration is HEALTHY at the same time, and retiring on that line deletes a
    # working runner (its registration survives on GitHub holding the name, and the re-register advice
    # then DELETES it). `reconcile` already refuses to trust the log — it starts the listener and believes
    # rc 6 — and the verb that DELETES must hold itself to the same standard. It is also the only standard
    # that works: the refusal is dated to THIS pass, so the skew cannot have written it.
    # A start that comes up and SURVIVES is a REPAIR, not a retire: the registration answers GitHub, and
    # the old line was a skew artifact. Anything that cannot be proven either way is cannot-act.
    if [ "$DRY" = 1 ]; then
      log_line "dry-run: would START name=$nm agent_id=$aid dir=$d evidence=$ev and retire it only if GitHub refuses the session — a dry run starts nothing and deletes nothing, so it cannot prove either outcome"
      retired=$((retired + 1))
      continue
    fi
    vrc=0; verout="$(start_listener "$d" 2>&1)" || vrc=$?
    case "$vrc" in
      0)
        revived=$((revived + 1))
        log_line "revived name=$nm agent_id=$aid dir=$d — the listener started and SURVIVED the settle window, so this registration still answers GitHub: the 'deleted' line in its log is NOT evidence (a skewed clock prints the same line — actions/runner#4648) and nothing was deleted"
        continue ;;
      6)
        log_line "verified name=$nm agent_id=$aid dir=$d — GitHub refused a session started in THIS pass, under the clock measured here (skew=${skew}s bound=${MAX_SKEW_S}s): the retirement rests on a refusal it dated itself, not on an old log line" ;;
      *)
        cannot=$((cannot + 1))
        log_line "$verout"
        continue ;;
    esac
    # ⛔ RENAME FIRST, DELETE SECOND — MEASURED, AND THE REASON THIS IS NOT ONE `rm -rf` (#2892).
    # On `pi-cell-4` the real retirement failed halfway: systemd had written `_diag` as root, so
    # `rm -rf` hit EACCES AFTER it had already unlinked `.runner`. The pass correctly reported
    # `cannot-act why=retire-failed`, and the result was still the worst of both worlds — 6.9 GB of
    # bytes NAMED BY NOTHING, invisible to `status`, to `slots` and to every later pass, because every
    # verb identifies a registration by `.runner`. A single untracked `rm -rf` cannot be made atomic,
    # but a RENAME can: after it, the registration is out of the pool in one step whatever the bytes do
    # next, and the leftover is a `*.retired-<stamp>` directory whose name says exactly what it is.
    q="$d.retired-$(date -u +%Y%m%dT%H%M%SZ)"
    if ! mv "$d" "$q" 2>/dev/null; then
      err "cannot-act why=retire-failed dir=$d (the install could not be moved aside — it is still a registration and nothing about the name changed; check ownership of $RUNNER_ROOT)"
      cannot=$((cannot + 1)); continue
    fi
    retired=$((retired + 1))
    removed=1
    if ! rm -rf "$q" 2>/dev/null || [ -e "$q" ] || [ -L "$q" ]; then removed=0; qn=$((qn + 1)); fi
    if [ -n "$sib" ]; then
      log_line "retired name=$nm agent_id=$aid dir=$d evidence=$ev kept=$sib — a LIVE registration still holds this name, so nothing was re-registered (re-registering here would have deleted it)"
    elif [ "$sib_unknown" = 1 ]; then
      log_line "retired name=$nm agent_id=$aid dir=$d evidence=$ev — the name is UNVERIFIED: at least one pool entry could not be read, so this pass cannot prove no live runner holds it; do NOT run '$SELF add --name $next' until the pool is readable — re-registering a name a live runner holds DELETES that runner"
    else
      log_line "retired name=$nm agent_id=$aid dir=$d evidence=$ev — the name is free again; run: $SELF add --name $next"
    fi
    if [ "$removed" = 0 ]; then
      log_line "quarantined dir=$q — the registration is OUT of the pool, but its files could not be removed (a root-owned file inside, usually systemd's _diag): run: rm -rf \"$q\" as the account that owns them; this path is excluded from slots and from every later pass, and status keeps naming it until it is gone"
    fi
  done <<<"$dirs"
  # ⛔ THE SUMMARY CARRIES ITS DENOMINATOR (#2899 review round 5, P2). An all-zero line with no
  # `root=` reads as "the pool is clean" when it may be "this root holds nothing"; the refusal above
  # closes that case, and naming the root makes the remaining one (a correct root with zero
  # registrations) legible on the line itself rather than inferred from an earlier `status`.
  printf 'reclaim: retired=%s preserved=%s revived=%s live=%s quarantined=%s cannot=%s clock_skew=%s bound=%ss dry_run=%s root=%s\n' \
    "$retired" "$preserved" "$revived" "$live" "$qn" "$cannot" "${skew:-unmeasured}" "$MAX_SKEW_S" "$DRY" "$RUNNER_ROOT"
  # ⛔ rc 3 IS REACHABLE ONLY BEFORE THE LOOP (a name with no registration, or a refused clock): the
  # two verdicts inside the loop are cannot-act (2), because they are facts about what could not be
  # read or done, not gate verdicts about the box. There is deliberately no `refused` counter — and no
  # `refused` LOCAL either (#2892 review round 2, P2): one was declared here and never read while this
  # comment claimed it had been removed, which is a comment asserting a fix the code did not finish.
  [ "$cannot" -eq 0 ] || return 2
  return 0
}

cmd_reconcile() {
  local d restarted=0 added=0 refused=0 cannot=0 dead=0 skipped=0 failed=0 n=1 rc budget scan=0 dry_adds=0 outside reclaimed=0 rcout=""
  while [ $# -gt 0 ]; do
    case "$1" in --dry-run) DRY=1; shift ;; *) err "usage: reconcile [--dry-run]"; return 1 ;; esac
  done

  # (a) every EXISTING registration must have a live listener. This is the half the fleet had no
  #     automation for at all: a dead listener on a live registration reads OFFLINE to GitHub while
  #     the registration still occupies the slot.
  # ⛔ A CHECKED ENUMERATION, like `cmd_status`: a here-string DISCARDS the producer's status, so an
  # unlistable root made this arm silently do nothing and the summary print `dead=0 restarted=0` — a
  # "nothing to do" reading where nothing was measured. The pass still exited 2, but a monitor keyed on
  # `dead=` read a healthy pool.
  local dirs
  if ! dirs="$(registered_dirs)"; then
    cannot=$((cannot + 1))
    # The REASON was already named by `registered_dirs` (runner-root-unreadable /
    # runner-root-not-a-directory), so this line does not invent one — and the pass still publishes its
    # machine-readable summary, as every other cannot-measure exit of this verb does.
    printf 'reconcile: dead=%s restarted=%s added=%s skipped=%s failed=%s refused=%s cannot=%s slots=unmeasured ceiling=%s mem_available=unmeasured floor=%s MB dry_run=%s\n' \
      "$dead" "$restarted" "$added" "$skipped" "$failed" "$refused" "$cannot" "${CEILING:-unmeasured}" "${MEM_FLOOR_MB:-unset}" "$DRY"
    err "cannot-act (the restart arm could not enumerate the pool; the reason is the line above the summary)"
    return 2
  fi
  while read -r d; do
    [ -n "$d" ] || continue
    rc=0; probe_listener "$d" || rc=$?
    case "$rc" in
      # ⛔ THE LIVE ARM IS THIS PASS'S REPAIR PATH FOR THE POST-REBOOT STATE (#3004 review, P1): the
      # listener survived, its TMPDIR did not, and nothing below this line runs for it. Repairing the
      # env does not touch the listener, so "not touched" stays true while the box stops being broken.
      # An unrepairable TMPDIR is `cannot`, not a clean pass.
      0) ensure_tmpdir "$d" "$LISTENER_PID" || cannot=$((cannot + 1)); continue ;;
      2) cannot=$((cannot + 1)); continue ;;   # cannot measure: start nothing
    esac
    dead=$((dead + 1))
    if [ "$DRY" = 1 ]; then
      # ⛔ A PREVIEW THAT ANNOUNCES A START FOR AN ORPHAN IS THE SAME LIE THE REAL PASS USED TO TELL
      # (#2892). This pass has already read the evidence (`capacity_class`), so the honest preview is
      # "this cannot be started" here, with the retire preview printed by the arm below — not "would
      # start" followed by a retirement of the very same directory.
      if [ "$(capacity_class "$d" 2>/dev/null)" = "orphaned" ]; then
        log_line "dry-run: the listener for name=$(basename "$d") cannot be started — its registration no longer exists server-side (see the retire preview below)"
        continue
      fi
      # ⛔ THE PREVIEW ASKS, IT DOES NOT RESTATE. `restart --dry-run` re-runs the same liveness probe
      # and the same cannot-measure arm, so a preview can never announce a start the real pass would
      # refuse (an unreadable process table, a missing `run.sh`).
      rc=0
      "$SELF" restart --name "$(basename "$d")" --dry-run || rc=$?
      case "$rc" in
        0) restarted=$((restarted + 1)) ;;
        3) cannot=$((cannot + 1)) ;;   # see the race note below — never `refused`
        *) cannot=$((cannot + 1)) ;;
      esac
      continue
    fi
    rc=0
    "$SELF" restart --name "$(basename "$d")" || rc=$?
    case "$rc" in
      0) restarted=$((restarted + 1)) ;;
      # ⛔ 6 = THIS REGISTRATION IS GONE SERVER-SIDE, so the restart arm must not count it as a
      # cannot-act and must not keep retrying it: the pass RETIRES it (below) and the slot comes back as
      # real capacity. Before #2892 this code did not exist, so an orphan was either reported
      # `restarted` (when the process appeared first) or `cannot` — and either way the pass never fixed
      # it, which is why `pi-cell-4` sat at 2 live runners with 2 dead installs for days.
      6) : ;;   # the retire arm below repairs it; counting it here too would double-report the slot
      # ⛔ A RESTART REFUSAL IS NOT A PASS (#2381 review, P2). `refused` is the ADD arm's
      # floor/ceiling refusal — a legitimate outcome that must not fail the pass — and it NEVER
      # reaches the exit decision, so counting a `restart` rc 3 here printed `dead=1 refused=1` and
      # exited 0: a false PASS over the pass's OWN first job, a slot it had enumerated as dead one
      # line above and left dead. A restart rc 3 means the verb disagreed with the listing this pass
      # just used (the registration vanished between the two, a TOCTOU), so it is cannot-act (exit
      # 2), never success. The reachable half of that disagreement — a `.runner` this pass lists and
      # `restart` calls missing — is pinned in `ci_runner_pool.test.sh` ("a dangling-symlink
      # marker"); this arm is the residual race a static fixture cannot construct.
      3) cannot=$((cannot + 1)) ;;
      # ⛔ A cannot-act is NOT a refusal: a scheduler branching on the documented codes must not see
      # a pass that could not act reported as success.
      *) cannot=$((cannot + 1)) ;;
    esac
  done <<<"$dirs"

  # ⛔ THE RESTART ARM CANNOT ENUMERATE A POOL THAT IS NOT UNDER $RUNNER_ROOT (#2381 review, P1).
  # Reporting `dead=0 restarted=0` over listeners it never listed is a false healthy reading, and the
  # ADD arm downstream counts its ceiling from the same partial listing — so the pass names the gap
  # and exits 2 rather than publishing a clean summary over part of the box.
  if ! outside="$(outside_listener_dirs)"; then
    cannot=$((cannot + 1))
  elif [ -n "$outside" ]; then
    cannot=$((cannot + 1))
    err "cannot-measure why=pool-root-incomplete root=$RUNNER_ROOT outside=$(join_lines "$outside") — a LIVE listener runs from an instance dir OUTSIDE RUNNER_ROOT: this pass could not enumerate it (the restart arm covers RUNNER_ROOT alone) and the ADD arm refuses on the same reading; set RUNNER_ROOT to the directory that CONTAINS every instance dir"
  fi

  # (a2) RETIRE WHAT A START CAN NEVER REVIVE (agent-infra#2892). A registration GitHub deleted cannot
  #      be restarted, added over, or healed by anything but removing the local install; the restart arm
  #      above now reports rc 6 for it instead of a false success. This arm runs ONLY when the evidence
  #      says there is something to retire (`capacity_class` = orphaned), so a healthy box never pays for
  #      `reclaim`'s clock probe and never sees a refusal it did not need. In a dry run the same
  #      evidence drives a preview: `restart --dry-run` starts nothing, so it cannot observe the orphan.
  local cand="" e
  while read -r e; do
    [ -n "$e" ] || continue
    [ "$(capacity_class "$e" 2>/dev/null)" = "orphaned" ] || continue
    cand="$cand$( [ -n "$cand" ] && printf '\n' )$e"
  done <<<"$dirs"
  if [ -n "$cand" ]; then
    rc=0
    if [ "$DRY" = 1 ]; then rcout="$("$SELF" reclaim --dry-run 2>&1)" || rc=$?; else rcout="$("$SELF" reclaim 2>&1)" || rc=$?; fi
    [ -n "$rcout" ] && log_line "$rcout"
    reclaimed="$(printf '%s\n' "$rcout" | sed -n 's/^reclaim: retired=\([0-9][0-9]*\) .*/\1/p' | head -1)"
    case "${reclaimed:-}" in ''|*[!0-9]*) reclaimed=0 ;; esac
    case "$rc" in 0) : ;; *) cannot=$((cannot + 1)) ;; esac
  fi

  # ⛔ THE TWO HALVES OF THE PASS DO NOT NEED THE SAME INPUTS. Restarting a dead listener needs no
  # capacity reading at all — no floor, no ceiling (see cmd_restart) — so gating the WHOLE pass on
  # `readings` refused the one action this tool exists for, on exactly the box that needs it: dead
  # listeners on a host whose memory read is broken. Measured shape: an unreadable
  # cap_mem_free_mb returned 2 before the restart arm ran, so every dead listener stayed dead and
  # nothing in the output said the restart arm had never been reached. The restart arm therefore runs
  # FIRST; only the ADD arm requires the readings, and an unreadable reading still makes the pass exit
  # 2 — after the restarts, with the summary disclosing that the add arm did not run.
  if ! readings; then
    cannot=$((cannot + 1))
    slots >/dev/null 2>&1 || SLOTS="unmeasured"
    printf 'reconcile: dead=%s restarted=%s added=%s skipped=%s failed=%s refused=%s cannot=%s slots=%s ceiling=unmeasured mem_available=unmeasured floor=%s MB dry_run=%s\n' \
      "$dead" "$restarted" "$added" "$skipped" "$failed" "$refused" "$cannot" "${SLOTS:-unmeasured}" "${MEM_FLOOR_MB:-unset}" "$DRY"
    err "cannot-measure why=capacity-readings-unavailable (the restart arm already ran; nothing was ADDED) — fix the reading, then re-run"
    return 2
  fi
  # ⛔ THIS BOUNDS ATTEMPTS, NOT ADDS. Every iteration advances `n` (or breaks), so this is what makes
  # the loop terminate — but a name GitHub already holds costs an attempt AND adds nothing, so a budget
  # sized to the ceiling lands the pass short of capacity, and at 2*CEILING+4 held names it can never
  # add at all. Held names are normal after a `/tmp` wipe (every local `.runner` gone, every
  # registration still on GitHub), so the slack is sized for that, not for a hypothetical bug.
  budget=$((CEILING * 4 + 20))
  # ⛔ A CALLER-SUPPLIED TOKEN CANNOT SERVE A PASS (#2381 review, P2). A registration token is
  # SINGLE-USE and expires in ~1h — both this file's own premises — so an inherited $RUNNER_TOKEN
  # covers exactly ONE add: every later name would fail config.sh (rc 5) and the pass would burn its
  # whole attempt budget reporting `failed=N added=0`. A dry run spends nothing, so it may preview.
  if [ "$DRY" = 0 ] && [ -n "${RUNNER_TOKEN:-}" ]; then
    cannot=$((cannot + 1)); budget=0
    err "cannot-act why=runner-token-single-use (RUNNER_TOKEN is single-use, so it covers ONE add; this pass can add several — the ADD arm did not run, the RESTART arm already did; unset RUNNER_TOKEN and authenticate $GH_CMD so each add mints its own)"
  fi

  # (b)+(c) add only ABOVE the floor and BELOW the ceiling. A gate verdict (rc 3) ENDS the pass — it
  #        is a measurement of this box, not a per-name accident — while an UNAVAILABLE name (rc 4)
  #        is a per-name accident: skip to the next name, because one stale directory must not cost
  #        the box the capacity it is entitled to.
  while [ "$budget" -gt 0 ]; do
    budget=$((budget - 1))
    # ⛔ A POOL THAT CANNOT BE READ ENDS THE PASS (rc 2, nothing added): `slots` reads 0 for "cannot
    # list the root", and 0 never reaches the ceiling — that is how one pass minted 32 listeners on a
    # 3-slot box while reporting cannot=0.
    if ! slots; then
      cannot=$((cannot + 1))
      err "cannot-measure why=runner-root-unreadable path=$RUNNER_ROOT (the pass stopped; nothing was added)"
      break
    fi
    # Nothing is added in a dry run, so `slots` never moves: the ceiling is counted against
    # slots + what the preview has already announced.
    if [ "$DRY" = 1 ]; then
      [ $(( SLOTS + dry_adds )) -lt "$CEILING" ] || {
        log_line "dry-run: ceiling would be reached slots=$SLOTS+$dry_adds ceiling=$CEILING ncpu=$NCPU"; break; }
    else
      [ "$SLOTS" -lt "$CEILING" ] || { log_line "ceiling reached slots=$SLOTS ceiling=$CEILING ncpu=$NCPU"; break; }
    fi
    scan=0
    while [ -e "$RUNNER_ROOT/$POOL_PREFIX-$n" ]; do
      n=$((n + 1)); scan=$((scan + 1))
      if [ "$scan" -ge 200 ]; then
        err "cannot-act why=no-free-runner-name scanned=200 prefix=$POOL_PREFIX-$n"
        cannot=$((cannot + 1)); break 2
      fi
    done
    # ⛔ THE PREVIEW ASKS, IT DOES NOT RESTATE: `add --dry-run` runs the SAME floor, ceiling, label,
    # name-availability and template checks, in the same order, and returns the same codes. A preview
    # that published "would add" unconditionally announced capacity the owner's memory floor refuses
    # (the mirror of under-reporting it).
    rc=0
    if [ "$DRY" = 1 ]; then
      "$SELF" add --name "$POOL_PREFIX-$n" --dry-run || rc=$?
    else
      "$SELF" add --name "$POOL_PREFIX-$n" || rc=$?
    fi
    case "$rc" in
      0) if [ "$DRY" = 1 ]; then dry_adds=$((dry_adds + 1)); else added=$((added + 1)); fi; n=$((n + 1)) ;;
      4) skipped=$((skipped + 1)); n=$((n + 1)) ;;
      # A name that could not be REGISTERED is a per-name accident too: try the next one, because the
      # box's capacity does not depend on GitHub happening to hold this name.
      5) failed=$((failed + 1)); n=$((n + 1)) ;;
      3) refused=$((refused + 1)); break ;;
      *) cannot=$((cannot + 1)); break ;;
    esac
  done

  # ⛔ In a dry run the counts are the PREVIEW's, for every field — `restarted` already counted what
  # it would start, so `added` must count what it would add, or the machine-readable summary
  # under-reports the very change the preview announced.
  [ "$DRY" = 1 ] && added=$((added + dry_adds))
  # ⛔ THE FINAL LISTING IS ITSELF A GATE OPERAND (#2381 review, P1). This used to be
  # `slots >/dev/null 2>&1 || SLOTS="unmeasured"`, and the literal string then reached
  # `[ "$SLOTS" -lt "$CEILING" ]` below: that test ERRORS, and under `set -uo pipefail` (no `-e`) an
  # errored test is FALSE — so the "provisioned nothing" guard was SILENTLY DISABLED and the pass
  # exited 0 over a pool it could not list. Exactly the class the header names for every other
  # operand; the summary read must fail closed like them. `SLOTS` is CLEARED first so a failed read
  # cannot leave the loop's earlier count in place and be printed as if it had just been measured —
  # and `SLOT_REGS`/`SLOT_ORPHANED` are cleared WITH IT (#2892 review round 2, P2): they are refreshed
  # by the same `slots` call, so clearing only `SLOTS` printed the pass's earlier registrations= /
  # orphaned= beside `slots=unmeasured` as if that half had just been measured.
  SLOTS=""; SLOT_REGS=""; SLOT_ORPHANED=""
  if ! slots; then
    cannot=$((cannot + 1))
  fi
  printf 'reconcile: dead=%s restarted=%s added=%s skipped=%s failed=%s refused=%s cannot=%s slots=%s ceiling=%s mem_available=%s MB floor=%s MB dry_run=%s reclaimed=%s registrations=%s orphaned=%s\n' \
    "$dead" "$restarted" "$added" "$skipped" "$failed" "$refused" "$cannot" "${SLOTS:-unmeasured}" "$CEILING" "$MEM_MB" "$MEM_FLOOR_MB" "$DRY" "$reclaimed" "${SLOT_REGS:-unmeasured}" "${SLOT_ORPHANED:-unmeasured}"
  # ⛔ A PASS THAT PROVISIONED NOTHING IS NOT A SUCCESS. Exit 5 is per-NAME (that is the whole point:
  # one taken name must not end the pass), so on its own it cannot report a box that could not register
  # ANYTHING — a GitHub 5xx, an expired runner scope, a full disk all arrive as the same code. When the
  # pass ended short of the ceiling with every attempt failing, that IS cannot-act. The `-n` operand
  # check is load-bearing: without it an unmeasured `SLOTS` re-opens the silent-disable above.
  if [ "$added" -eq 0 ] && [ "$failed" -gt 0 ] && [ -n "$SLOTS" ] && [ "$SLOTS" -lt "$CEILING" ]; then
    err "cannot-act why=no-runner-registered failed=$failed slots=${SLOTS:-unmeasured} ceiling=$CEILING — the box gained no capacity this pass"
    return 2
  fi
  [ "$cannot" -eq 0 ] || return 2
  return 0
}

main() {
  local verb="${1:-}"; shift 2>/dev/null || true
  if [ -z "${POOL_PREFIX:-}" ]; then
    # Runner names are unique PER REPO, so an unqualified prefix means two boxes' passes mint the
    # same names and each one's registration replaces the other's. The measured names were
    # box-qualified (`pi-runner-cell4-x64-2`) for exactly this reason.
    local h; h="$(hostname -s 2>/dev/null || hostname 2>/dev/null)" || h=""
    case "$h" in ''|*[!A-Za-z0-9._-]*) h="box" ;; esac
    POOL_PREFIX="pi-runner-$h"
  fi
  # ⛔ HELP BEFORE VALIDATION: `--help` reads no operand, and the box whose env is WRONG is exactly
  # the one that cannot read the contract otherwise — `RUNNER_START_SETTLE_S=5s … --help` used to
  # report `cannot-measure` and exit 2 with the usage block unreachable.
  case "$verb" in
    ''|-h|--help|help) usage 0 ;;
  esac
  validate_operands || return 2
  case "$verb" in
    status)    cmd_status "$@" ;;
    add)       cmd_add "$@" ;;
    restart)   cmd_restart "$@" ;;
    reconcile) cmd_reconcile "$@" ;;
    reclaim)   cmd_reclaim "$@" ;;
    *) err "ci_runner_pool: unknown command '$verb' (try: status|add|restart|reclaim|reconcile)"; return 1 ;;
  esac
}

main "$@"
