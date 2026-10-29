#!/usr/bin/env bash
# cloud-cell-bringup.test.sh — the regression contract for agent-infra#1718.
#
# The operator PUSHES the gh token onto the cell as a FILE, so until it is deleted that file is a
# PUSH-CAPABLE credential sitting on a machine we hand between operators. The pre-fix cleanup was
# placed after the guard it was paired with:
#
#     gh auth login --with-token < "$tokfile" || die "gh auth failed from $tokfile"   # ← exits here
#     rm -f "$tokfile" && ok "token file removed"                                     # ← success only
#
# so `die` exited before the delete and the token SURVIVED every failure, every abort, and every
# signal — silently, because a token still on disk changes nothing the operator can see. The same
# `rm -f … && ok …` also swallowed a FAILED removal: nothing was printed and bring-up still reached
# its `CELL READY` banner with the token there.
#
# This suite drives the SHIPPED script end-to-end (not a re-implementation of the cleanup: a check
# that reimplements the logic passes on the broken copy too) and asserts:
#
#   * a FAILING `gh auth login` still removes the token, and does not reach the readiness banner;
#   * an abort BEFORE check_gh is reached (github unreachable) removes it too — the window the
#     pre-fix code left open, since its removal lived inside check_gh and there was no trap;
#   * the non-`die` exit (unknown mode) removes it;
#   * a SIGTERM removes it — and the load-bearing assertion is that the trap's cleanup RAN: an
#     UNTRAPPED fatal signal reaches the parent as 128+signal too and (measured on bash 3.2.57) runs
#     a bare EXIT trap as well, so the rc alone proves nothing either way;
#   * a removal that FAILS is loud and refuses to report readiness (fail-closed, not fail-open);
#   * a keys.env that runs `trap - EXIT` cannot disarm the cleanup (the handlers are re-asserted after
#     the file is sourced — measured: the token survived when they were not);
#   * a token whose parent directory denies traversal is still reported LOUDLY and never produces a
#     readiness banner — `[ -e ]`/`[ -f ]` are false there, so a stat-gated removal would skip it
#     silently, which is the pre-fix failure mode wearing a different hat;
#   * a DEAD STDOUT during the cleanup (the removal LOG write raises SIGPIPE) does not truncate the
#     loop: with two registered secrets BOTH are removed, not just the entry being logged;
#   * NON-VACUITY: a clean run still exits 0 and still prints CELL READY, and a token that is
#     present is genuinely deleted (a suite that never had the file would pass for the wrong reason).
#
# #2100 (the capture extension), added here because the two mechanisms meet in `--check`:
#   * the PROVIDER PROBE reads the provider, not the extension layer — a noisy layer (the measured
#     banner-only shape: `[tortoise-capture] …`, no answer) must NOT turn a healthy provider into
#     `FATAL: provider probe failed`. The stub `pi` reproduces that shape, and the probe's OWN
#     two-check contract is what is pinned: the ISOLATED probe (`--no-extensions`) owns the provider
#     verdict and runs first, then a LAYER-loaded lane-shaped turn (twice) proves the layer can
#     answer. So the noisy case must (i) report no provider failure, (ii) NAME the layer and say the
#     provider is healthy, (iii) not claim CELL READY, and (iv) a broken key must still be blamed on
#     the provider. Dropping or reordering either check turns one of those red (the cases prove the
#     fixture emits no LANE_READY with the layer loaded and DOES answer in isolation, so none can
#     pass vacuously);
#   * the ANSWER IS READ FROM THE WHOLE STREAM — the measured defect was `pi -p … 2>&1 | tail -3`,
#     so a regression that re-narrows either probe to its last lines must go red. The `trailing`
#     fixture answers FIRST and then prints three banner lines (the noisy layer writing AFTER the
#     answer), so its answer is outside any 3-line tail: re-applying `| tail -3` to the isolated
#     probe reads as a provider failure and re-applying it to the layer probe blames a HEALTHY layer
#     for swallowing the turn (both verified red against the mutated script).
#   * the DENY IS CELL-BOUND, not ship-list-bound — `pi-bootstrap/tests/test-cell-install.sh` run 2b
#     removes both denied rows from a COPY of manifest.json and proves the install half still
#     removes, and the verify half still refuses, a copy left on the cell;
#   * a cell that CARRIES `tortoise-capture` fails the installer's read-back at the named (b) call
#     (`capture extension present on a cell: …`) and `--check` SURFACES that line — it used to
#     discard the verify output entirely, so the reason the box kept re-breaking itself appeared
#     nowhere in the log. The run then repairs the cell (that IS the fix: the deny removes it), and
#     the evidence asserted here is the named line plus the extension's absence — never a claim of
#     readiness over a failed read-back;
#   * with the extension ABSENT and the provider healthy, `--check` reports NO provider failure.
#
# Hermetic: temp HOME/state/token path, stubbed toolchain, no network, and GH_TOKEN_FILE keeps it
# away from the REAL /tmp/.gh-tok. Run:  bash scripts/cloud-cell-bringup.test.sh
# ⚠️ `--check` now also provisions the operational layer (#1723) from the checkout this script
# lives in, so the clean-run case installs it into the temp CELL_HOME: that is why the stub set
# carries an offline `npm` and leaves `python3` to the host (see the stub block below).
# ⚠️ That hermeticity is a property of the FIXED script: GH_TOKEN_FILE is introduced by this fix, so
# running this suite against the PRE-FIX script (to show it is red) reads and `rm -f`s the real
# /tmp/.gh-tok of whatever host runs it. Do that only where that file does not exist (as here).

set -uo pipefail

# #2235: the suite must not inherit an ambient repo selector. gh gives `GH_REPO` precedence over the
# checkout for every call that omits `--repo`, so a value exported by the developer's shell (or by a
# cell's keys.env) would be judged against every fixture checkout's origin — reddening unrelated arms
# and letting this harness carry the very defect the new conformance arm exists to catch.
unset GH_REPO

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRINGUP="$HERE/cloud-cell-bringup.sh"

PASS=0; FAIL=0; SKIP=0
ok()  { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }
skip() { SKIP=$((SKIP + 1)); echo "  ⏭ SKIPPED — $1"; }
say_case() { echo; echo "── $1 ──"; }

T="$(mktemp -d "${TMPDIR:-/tmp}/cloud-cell-1718.XXXXXX")"
# The scheduled layer (agent-infra#1864) runs the declarations it is pointed at, so it is pointed at
# a HERMETIC fixture here: without TEMPLATES_DIR the shipped templates would run the REAL reapers
# (pi-reap-idle.sh is armed with REAP_DRY_RUN=0) against this host, which is not a test. The loop is
# stopped on the way out — a detached loop outlives the suite otherwise and keeps ticking at a
# deleted directory.
export TEMPLATES_DIR="$T/schedule-templates"
mkdir -p "$TEMPLATES_DIR"
printf '# fixture: nothing retired\n' > "$TEMPLATES_DIR/RETIRED"
cat > "$TEMPLATES_DIR/com.test.bringup-schedule.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
    <key>Label</key><string>com.test.bringup-schedule</string>
    <key>ProgramArguments</key>
    <array><string>/bin/sh</string><string>-c</string><string>echo ran >> "$T/schedule-marker"</string></array>
    <key>StartInterval</key><integer>3600</integer>
</dict>
</plist>
PLIST
# `chmod -R u+w` first: one case makes a parent directory unwritable to force `rm -f` to fail, and
# the suite must still be able to clean up after itself.
trap 'HOME="$T/home" CELL_HOME="$T/home" TEMPLATES_DIR="$T/schedule-templates" python3 "$HERE/fleet-schedule.py" --stop >/dev/null 2>&1; chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT

if [ -f "$BRINGUP" ]; then ok "shipped script present: cloud-cell-bringup.sh"
else bad "missing $BRINGUP"; echo; echo "  PASS=$PASS FAIL=$FAIL"; exit 1; fi

# ── stubbed toolchain (no network, no real gh, no real pi) ───────────────────────────────────────
STUB="$T/stub"; mkdir -p "$STUB"
for c in node uv tmux docker; do
  printf '#!/bin/sh\nexit 0\n' > "$STUB/$c"; chmod +x "$STUB/$c"
done
# `python3` is deliberately NOT stubbed. The operational layer's installer parses the farm set out
# of setup.sh, reads the ship-list out of manifest.json and merges settings.json with the REAL
# python3 — a no-op stub makes it parse nothing and refuse loudly by its own floor (which is the
# right answer on a cell without python3, so this suite runs against the host's interpreter).
# `npm` is stubbed because the layer installs each extension's declared dependencies: no network,
# and a POPULATED `node_modules` is what the installer reads back as "dependencies present" (a real
# `npm install` writes the lockfile it resolved, and an empty directory is refused by --verify).
printf '#!/bin/sh\nmkdir -p node_modules\necho x > node_modules/.package-lock.json\nexit 0\n' > "$STUB/npm"
# `git --version` is parsed for a version; `git -C <repo> rev-parse --short HEAD` is echoed into the
# "repo present" line. `git -C <repo> config …` output is ignored.
# ⛔ `GIT_STUB_REAL=1` DELEGATES THE WORKTREE VERBS TO THE REAL GIT. The harness-PIN cases (§below)
# must exercise a REAL linked worktree — `git worktree add` and the `worktree list --porcelain` read are
# the subject — and a stub that answers `abc1234` to every command cannot prove either. Only those verbs
# delegate: everything else keeps the fake answers the rest of this suite is written against, so no
# other case changes behaviour. Delegating by VERB (not by case) is deliberate: a fixture that switched
# git off wholesale would make check_repo/check_gh answer differently and redden unrelated arms.
printf '#!/bin/sh\ncase "$1" in --version) echo "git version 2.39.0";; *)\n  if [ -n "${GIT_STUB_REAL:-}" ]; then\n    case "$*" in *" rev-parse --git-dir"*|*" rev-parse --git-common-dir"*|*" worktree list"*|*" worktree add"*|*" worktree remove"*|*" rev-parse --verify"*) exec /usr/bin/git "$@" ;; esac\n  fi\n  echo abc1234;; esac\n' > "$STUB/git"
# The probe stub also has to be able to reproduce the MEASURED #2100 shape: a layer that emits banner
# lines and NEVER reaches the model, so the output carries no answer at all. It only answers when the
# probe asks for a provider with extensions DISABLED (`--no-extensions`). That is what makes the
# two-check contract testable: the provider verdict comes from the ISOLATED probe, and the LAYER turn
# goes red on this fixture — so the run must FAIL naming the layer, and must NOT report a provider
# failure. `broken` models the other attribution: the provider itself rejects the key in EVERY mode,
# so the run dies on the 401 arm. `instruction` prints the INSTRUCTION ITSELF (the vacuous-pass shape
# an extractor that accepted any matching line would take for an answer). `verbose` answers with the
# instruction embedded in a sentence — a REAL answer, which the extractor must accept (`-xF` narrows
# the refusal to a byte-identical line; a `-vF` version wrongly drops this one). `trailing` answers
# FIRST and then prints three banner lines, which is the shape that `| tail -3` mis-read as the
# answer. `PI_STUB_LOG`, when
# set, records one line per model call, so a case can prove how many calls actually ran.
cat > "$STUB/pi" <<'STUB'
#!/bin/sh
[ "$1" = "--version" ] && { echo "0.85.1"; exit 0; }
[ -n "${PI_STUB_LOG:-}" ] && echo call >> "$PI_STUB_LOG"
has_ne=0
for a in "$@"; do [ "$a" = "--no-extensions" ] && has_ne=1; done
if [ "${PI_STUB_MODE:-normal}" = broken ]; then
  printf '{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}\n'
  exit 0
fi
if [ "${PI_STUB_MODE:-normal}" = instruction ]; then
  printf 'Reply with exactly: LANE_READY\n'
  exit 0
fi
if [ "${PI_STUB_MODE:-normal}" = verbose ]; then
  printf 'Sure — the model replied: Reply with exactly: LANE_READY\n'
  exit 0
fi
if [ "${PI_STUB_MODE:-normal}" = trailing ]; then
  # The MEASURED shape of the original defect, mirrored: the answer is IN the stream and the last
  # three lines are a noisy layer's banner written AFTER it. `pi -p … | tail -3` read those three
  # lines as the answer, so the answer that had arrived was discarded. Emitted in BOTH modes
  # (isolated and layer-loaded) on purpose: whichever probe re-acquires a `| tail -3` loses its
  # answer here, so neither half can regress unnoticed.
  printf 'LANE_READY\n'
  printf '[tortoise-capture] install probe recorded (harness=pi)\n'
  printf '[tortoise-capture] spool flush (session_start): filed 0, deferred 2, skipped 320 (320 waiting on backoff)\n'
  printf '[tortoise-capture] spool close: 0 filed this turn\n'
  exit 0
fi
if [ "${PI_STUB_MODE:-normal}" = slowlayer ] && [ "$has_ne" -eq 0 ]; then
  # What `timeout` leaves behind when it kills the child: no output, exit 124.
  exit 124
fi
if [ "${PI_STUB_MODE:-normal}" = mixedlayer ] && [ "$has_ne" -eq 0 ]; then
  # A MIX: attempt 1 completes with banner-only output, attempt 2 is killed at 120 s. The run must
  # NOT claim "timed out on both attempts" (it would discard attempt 1's banner evidence) and must
  # NOT accuse an extension of a completed call.
  _c=0
  [ -f "${PI_STUB_COUNT:-/dev/null}" ] && _c="$(cat "${PI_STUB_COUNT:-/dev/null}" 2>/dev/null || echo 0)"
  _c=$((_c + 1)); [ -f "${PI_STUB_COUNT:-/dev/null}" ] && printf '%s\n' "$_c" > "${PI_STUB_COUNT:-/dev/null}"
  if [ "$_c" -eq 1 ]; then
    printf '[tortoise-capture] install probe recorded (harness=pi)\n'
    exit 0
  fi
  exit 124
fi
if [ "${PI_STUB_MODE:-normal}" = noisy ] && [ "$has_ne" -eq 0 ]; then
  printf '[tortoise-capture] install probe recorded (harness=pi)\n'
  printf '[tortoise-capture] spool flush (session_start): filed 0, deferred 2, skipped 320 (320 waiting on backoff)\n'
  exit 0
fi
echo LANE_READY
STUB
# check_provider wraps the probe in `timeout 120 pi …`; GNU timeout is not on every dev box (macOS
# has none), so it is stubbed here rather than assumed.
printf '#!/bin/sh\nshift\nexec "$@"\n' > "$STUB/timeout"
# rm shim — delegates to the real rm, but PARKS first when RM_STUB_SLOW is set, so a case can deliver
# a second signal while the EXIT trap's cleanup is genuinely in flight. Leave RM_STUB_SLOW unset and
# it is transparent.
printf '#!/bin/sh\ncase "$*" in\n  *.gh-tok*) if [ -n "${RM_STUB_SLOW:-}" ]; then [ -n "${RM_STUB_MARK:-}" ] && : > "$RM_STUB_MARK"; sleep 2; fi ;;\nesac\nexec /bin/rm "$@"\n' > "$STUB/rm"
# check_network reads the http_code from stdout. `slow` parks the script there so a SIGTERM can be
# delivered while it is genuinely in flight (and writes a marker so the test does not race startup).
printf '#!/bin/sh\ncase "${CURL_STUB_MODE:-normal}" in\n  fail) echo 000 ;;\n  slow) : > "$CURL_STUB_MARK"; sleep 2; echo 200 ;;\n  *) echo 200 ;;\n  esac\n' > "$STUB/curl"
# A gh that can be told to reject the token. Failing `auth login` is the shape the issue measured.
printf '#!/bin/sh\nmode="${GH_STUB_MODE:-ok}"\ncase "$1 $2" in\n  "auth login")   [ "$mode" = fail ] && exit 1; exit 0 ;;\n  "auth status")  exit 0 ;;\n  "api user")     echo tester; exit 0 ;;\n  "api repos"*)   echo true; exit 0 ;;\nesac\nexit 0\n' > "$STUB/gh"
# ── the disk-reaper timer installer (#2032) ──────────────────────────────────────────────────────
# The bring-up now INSTALLS an hourly systemd timer. This suite must never touch the real
# /etc/systemd/system, so the unit dir is redirected to a fixture dir and `systemctl` is the shim
# below: an installer that reaches the real systemd during a test is a test that can change the host.
# SYSTEMCTL_STUB_MODE=fail makes `daemon-reload`/`enable` refuse, which is the shape of a cell whose
# scheduler cannot be armed — the bring-up must refuse that cell rather than certify it.
export SYSTEMD_UNIT_DIR="$T/systemd-units"
# ⛔ THE READ SIDE TOO, OR THE SUITE CHANGES THE HOST (review P2, #2402). `SYSTEMD_UNIT_DIR` is the
# installer's WRITE seam; `installed_units`/`find_installed_unit` READ `${CONTROLLER_SYSTEM_UNIT_DIR:-
# /etc/systemd/system}` and `$HOME/.config/systemd/user`, and `--install` refuses when a second copy is
# already installed. Pinning only the write side left every read-back arm reading this box — so on any cell
# that has run install-controller-service.sh (the exact box shape this PR creates) the new controller check
# sees a foreign copy, `--install` refuses, and the bring-up dies on its own deployment target. The
# installer's own suite pins both seams for the same reason; HOME is pinned with them because the user-scope
# directory is derived from it.
export CONTROLLER_SYSTEM_UNIT_DIR="$T/systemd-units"
export HOME="$T/home"
# The one-home check (#2916) refuses a cell-state path under a volatile root that is NOT under
# CELL_HOME. This fixture's home IS under the host's temp dir, so the shipped default (`/tmp:/var/tmp`)
# would redden every arm on a Linux host for the fixture's own sake. Same kind of seam as
# SYSTEMD_UNIT_DIR above; the shipped default is what cloud-cell-bringup.verify.test.sh's red arms use.
export CELL_VOLATILE_ROOTS=/nonexistent-fixture-volatile-root
export SYSTEMCTL="$STUB/systemctl"
printf '#!/bin/sh\ncase "$*" in\n  *is-enabled*) echo enabled ;;\n  *is-active*) echo active ;;\n  *list-timers*) echo "Mon 2026-10-19 00:30:00 UTC 1h left Sun 2026-10-18 23:30:00 UTC 3h ago eldato-disk-reaper.timer eldato-disk-reaper.service" ;;\n  *MainPID*) echo "MainPID=1234" ;;\n  *NRestarts*) echo "NRestarts=0" ;;\n  *show*) echo 0 ;;\n  *start*) mkdir -p "$CELL_HOME/orchestrator" 2>/dev/null; date +%%s > "$CELL_HOME/orchestrator/heartbeat" 2>/dev/null; exit 0 ;;\n  *enable*|*daemon-reload*) [ "${SYSTEMCTL_STUB_MODE:-ok}" = fail ] && exit 1; exit 0 ;;\n  *) exit 0 ;;\nesac\n' > "$STUB/systemctl"
chmod +x "$STUB"/*   # glob, not an explicit "$STUB/git" "$STUB/pi" … list: the main-worktree-guard's script
                     # walker reads the literal token "$STUB/git" + a following $VAR as a NON-STATIC `git`
                     # invocation and fails closed, blocking the suite from running at all.

# ── swap provisioning (agent-infra#2390) ─────────────────────────────────────────────────────────
# The bring-up now CREATES SWAP, which needs root. This suite must never create swap on (or edit
# /etc of) the host that runs it, so every path the step touches is redirected into $T and the
# kernel-side commands are shims whose effects land in a FIXTURE that stands in for /proc/swaps.
# The seam is the same one the script documents (`SWAP_SUDO`), emptied here so nothing escalates.
# ⛔ The fixture is not proof of the kernel — the real read-back is `swapon --show` on a cell. What
# these cases pin is the SHIPPED logic: what it creates, what it skips on a re-run, and what it says
# when it cannot act.
export SWAPFILE="$T/swapfile"
export SWAP_MB="4096"          # pinned so the cases do not depend on the RAM of the host running them
export SWAP_PROC="$T/proc-swaps"
export SWAP_FSTAB="$T/fstab"
export SWAP_SYSCTL_CONF="$T/sysctl.d/99-cell-swap.conf"
export SWAP_SYSCTL_FILE="$T/swappiness"
export SWAP_SUDO=""           # no escalation in a test; a case overrides it with `false`
export SWAP_AVAIL_KB=104857600  # 100 GiB free: the refusal is exercised deliberately only
mkdir -p "$T/sysctl.d"
printf 'Filename\tType\tSize\tUsed\tPriority\n' > "$T/proc-swaps"   # header only: no swap, the measured shape
: > "$T/fstab"
printf '60\n' > "$T/swappiness"                                     # the image default, so the pin is a CHANGE
SWAP_LOG="$T/swap-calls.log"
# `fallocate` allocates SPARSELY for the fixture (dd seek), so a 4 GiB request costs no disk here.
printf '#!/bin/sh\nsz=""; prev=""; f=""\nfor a in "$@"; do [ "$prev" = "-l" ] && sz="$a"; f="$a"; prev="$a"; done\nn="${sz%%M}"\ndd if=/dev/zero of="$f" bs=1048576 count=0 seek="$n" 2>/dev/null || exit 1\n[ "$(wc -c < "$f")" = "$((n * 1048576))" ] || exit 1\n[ -n "${SWAP_STUB_LOG:-}" ] && echo "fallocate $sz $f" >> "$SWAP_STUB_LOG"\nexit 0\n' > "$STUB/fallocate"
printf '#!/bin/sh\n[ -n "${SWAP_STUB_LOG:-}" ] && echo "mkswap $*" >> "$SWAP_STUB_LOG"\nexit 0\n' > "$STUB/mkswap"
# `swapon <file>` appends a REAL /proc/swaps row (path, type, size_kb, used_kb, prio) to the fixture,
# so the script's own reading of the swap record is what the case asserts on. `--show` is only there
# for a hand-run on the fixture; the script itself deliberately reads the record instead.
printf '#!/bin/sh\n[ "$1" = "--show" ] && { cat "$SWAP_PROC"; exit 0; }\n[ -n "${SWAP_STUB_LOG:-}" ] && echo "swapon $*" >> "$SWAP_STUB_LOG"\nkb=$(( $(wc -c < "$1") / 1024 ))\ngrep -qF "$1" "$SWAP_PROC" 2>/dev/null || printf "%%s file %%s 0 -2\\n" "$1" "$kb" >> "$SWAP_PROC"\nexit 0\n' > "$STUB/swapon"
printf '#!/bin/sh\n[ -n "${SWAP_STUB_LOG:-}" ] && echo "swapoff $*" >> "$SWAP_STUB_LOG"\ngrep -vF "$1" "$SWAP_PROC" > "$SWAP_PROC.tmp" 2>/dev/null && mv "$SWAP_PROC.tmp" "$SWAP_PROC"\nexit 0\n' > "$STUB/swapoff"
printf '#!/bin/sh\n[ -n "${SWAP_STUB_LOG:-}" ] && echo "sysctl $*" >> "$SWAP_STUB_LOG"\nfor a in "$@"; do case "$a" in vm.swappiness=*) printf "%%s\\n" "${a#vm.swappiness=}" > "$SWAP_SYSCTL_FILE" ;; esac; done\nexit 0\n' > "$STUB/sysctl"
chmod +x "$STUB"/*
# ── fixtures: a HOME, a pre-existing clone (so check_repo never reaches the network), a keys.env ──
mkdir -p "$T/home" "$T/tok"
# ⛔ A REAL CHECKOUT, NOT AN EMPTY `.git` DIRECTORY (measured on CI, 2026-10-24). `mkdir -p "$T/cell/.git"`
# is not a repository: real git refuses it, so the disk-reaper installer's `git -C <path> rev-parse
# --git-dir` dropped the ONLY candidate it could have scanned and refused to install. Locally that was
# masked because the developer shell exports AGENT_INFRA_PATH, which the installer accepted instead —
# the arm then asserted a unit whose DISK_REAPER_REPOS named the DEVELOPER'S checkout, not the cell's.
git init -q "$T/cell" >/dev/null 2>&1 || { echo "fixture: git init failed" >&2; exit 1; }
git -C "$T/cell" -c user.email=fixture@example.invalid -c user.name=fixture -c commit.gpgsign=false \
    commit -q --allow-empty -m fixture >/dev/null 2>&1 || { echo "fixture: git commit failed" >&2; exit 1; }
printf 'DEEPSEEK_API_KEY=fake\n' > "$T/keys.env"
TOK="$T/tok/.gh-tok"
printf 'ghp_FAKE_PUSH_CAPABLE_TOKEN\n' > "$TOK"   # (re-created per case; asserted deleted after)
TOK_BODY="$(cat "$TOK")"

# check_dispatch (agent-infra#1736) runs the REAL `refresh-candidates.sh --check` whenever the
# harness is resolvable, which it is from a full checkout — and this suite's fixture clone has no
# tools/collision_preflight.py, so the real check dies before the banner and every case that expects
# a clean run goes red. HARNESS is the documented override: pinning it at a non-existent directory
# takes check_dispatch's `warn … return 0` path, keeping this suite about #1718's secret lifetime
# and not about whether the fixture repo can be provisioned for dispatch. Exported so it reaches
# `br()` and every inline invocation below (they add vars as a command prefix, which does not clear
# the already-exported environment).
export HARNESS="$T/no-harness"

# ── a REAL harness checkout to pin FROM (the measured trap this suite pins) ────────────────────────
# `check_harness_pin` materialises a LINKED WORKTREE (`git worktree add --detach`) and refuses a pin
# root that is a directory of sha-named COPIES. Both are git facts a stub cannot answer, so the fixture
# is a throwaway bare-origin repo with a real `origin/main` and a real harness tree, and the git stub
# delegates the worktree verbs for every case (GIT_STUB_REAL). It is also the honest shape of a new
# box: bring-up pins from the checkout it trusts, not from a hand-copy.
INFRA="$T/infra"; INFRA_ORIGIN="$T/infra-origin.git"
mkdir -p "$INFRA/scripts/orchestrator-harness"
git init -q --bare "$INFRA_ORIGIN"
git init -q "$INFRA"
git -C "$INFRA" config user.email test@test.local
git -C "$INFRA" config user.name test
git -C "$INFRA" config commit.gpgsign false
printf '#!/bin/bash\n: controller\n' > "$INFRA/scripts/orchestrator-harness/orch-loop.sh"
chmod +x "$INFRA/scripts/orchestrator-harness/orch-loop.sh"
git -C "$INFRA" add -A
git -C "$INFRA" commit -q -m "fixture harness"
git -C "$INFRA" branch -M main
git -C "$INFRA" remote add origin "$INFRA_ORIGIN"
git -C "$INFRA" push -q origin main
export HARNESS_REPO="$INFRA" GIT_STUB_REAL=1

# br <gh-mode> <curl-mode> [extra args…] — run the REAL script with the stub toolchain. Capture rc
# in BR_RC and combined output in BR_OUT, exactly as cloud-cell-supervisor.test.sh does.
BR_RC=0; BR_OUT=''
br() {
  # ${BR_EXTRA_ENV:+$BR_EXTRA_ENV} is expanded UNQUOTED on purpose (it carries `NAME=value` pairs), so a
  # value with whitespace would make `env` treat the remaining words as the command: the bring-up never
  # runs, `env` exits 127, and an arm asserting only a non-zero rc passes VACUOUSLY. Refuse it here.
  case "${BR_EXTRA_ENV:-}" in
    *[[:space:]]*) echo "fixture: BR_EXTRA_ENV must not contain whitespace (got '$BR_EXTRA_ENV')" >&2; exit 1 ;;
  esac
  # ⛔ HERMETIC FROM THE BOX (measured on a fresh CI runner, 2026-10-24). Every ambient repo variable is
  # CLEARED here, because the disk-reaper installer falls back to them when nothing tells it which repo
  # to scan: with $AGENT_INFRA_PATH exported by a developer's shell the install succeeded locally while
  # the SAME suite failed 24 arms on CI, where nothing is exported — a host dependency wearing a test's
  # clothes. With them cleared, the only repo the installer can learn about is the one the bring-up
  # passes from its own verified checkout, which is what the `Environment=DISK_REAPER_REPOS=` arm asserts.
  # `-u DEEPSEEK_API_KEY` for the SAME reason as the repo vars: on a developer's box the provider key is
  # exported and the run sails past `check_provider`, while on a bare runner the identical invocation
  # dies there - measured 2026-10-24, where the GH_REPO-ordering arm asserted an `ok: gh login` line the
  # CI run never reached (the key it needed came from the author's shell, not from the fixture). An arm
  # that needs a key must pass one explicitly (`BR_EXTRA_ENV=...`), so no arm silently inherits one.
  # BOTH provider keys the bring-up accepts (`cloud-cell-bringup.sh`: it refuses only when NEITHER is
  # set), so an ambient `ANTHROPIC_API_KEY` cannot stand in for the fixture's either — measured: with
  # only that key ambient, the pre-fix ordering arm PASSED locally for the wrong reason.
  # `GH_REPO` too: an operator shell exporting the fleet's slug would let the "a GLOBAL GH_REPO pushed
  # in keys.env is DROPPED" arm stay green even with its own post-source drop deleted (measured: the
  # mutated bring-up still passed that arm as `GH_REPO=daniel-ospina/tortoise` ambient, and reddened
  # without it). The one arm that needs an ambient slug asks for it by name.
  # `INFRA_ROOT` is cleared for the same reason as the others: the bring-up tries it FIRST when it
  # resolves the infra checkout, so a developer shell that exports it makes the layer arms grade a
  # DIFFERENT checkout (measured: an ambient decoy's installer ran and the suite still reported 142/0).
  BR_OUT="$(env -u AGENT_INFRA_PATH -u INFRA_ROOT -u TORTOISE_REPO -u DISK_REAPER_REPOS -u GH_REPO \
            -u DEEPSEEK_API_KEY -u ANTHROPIC_API_KEY \
            PATH="$STUB:$PATH" REPO="${BR_AMBIENT_REPO:-}" GH_REPO="${BR_GH_REPO:-}" \
            ${BR_EXTRA_ENV:+$BR_EXTRA_ENV} \
            CELL_HOME="$T/home" WORKDIR="$T/cell" ENV_FILE="${BR_ENV_FILE:-$T/keys.env}" \
            GH_TOKEN_FILE="$TOK" GH_STUB_MODE="$1" CURL_STUB_MODE="$2" \
            REPO_SLUG="daniel-ospina/tortoise" \
            bash "$BRINGUP" "${@:3}" 2>&1)"
  BR_RC=$?
}

# ── 1) the measured defect: a REJECTED token ─────────────────────────────────────────────────────
say_case "gh auth login FAILS (the measured #1718 shape)"
printf '%s\n' "$TOK_BODY" > "$TOK"
br fail normal --check
[ "$BR_RC" -ne 0 ] && ok "bring-up exits non-zero ($BR_RC) on a failed login" \
                   || bad "bring-up returned 0 on a failed login"
[ ! -e "$TOK" ] && ok "token file REMOVED after the failed login" \
                || bad "token file SURVIVED a failed login — a push-capable credential left on the VM"
case "$BR_OUT" in
  *"gh auth failed"*) ok "the failure names the login that failed" ;;
  *) bad "the failure does not name the login — output: $BR_OUT" ;;
esac
case "$BR_OUT" in
  *"CELL READY"*) bad "CLAIMED readiness on a failed login" ;;
  *) ok "never claims CELL READY on a failed login" ;;
esac

# ── 2) NON-VACUITY: the clean path still works, and really deletes a present token ───────────────
say_case "clean run (must NOT be broken by the cleanup)"
printf '%s\n' "$TOK_BODY" > "$TOK"
# The probe count is part of the contract: a healthy box makes TWO model calls — the isolated
# PROVIDER verdict and one layer-loaded turn — and the layer check must NOT be retried when it
# answers. A regression that re-runs the layer probe (or drops either one) shows up here.
PI_CALLS="$T/pi-calls.log"; : > "$PI_CALLS"
PI_STUB_LOG="$PI_CALLS" br ok normal --check
[ "$(grep -c . "$PI_CALLS")" -eq 2 ] && ok "a healthy run makes exactly 2 model calls (isolated verdict + one layer turn)" \
  || bad "a healthy run made $(grep -c . "$PI_CALLS") model calls, expected 2 (isolated provider verdict + one layer-loaded turn, no retry on success)"
[ "$BR_RC" -eq 0 ] && ok "bring-up still exits 0 on a clean run" \
                   || bad "clean run FAILED (rc=$BR_RC): $BR_OUT"
case "$BR_OUT" in
  *"the extension layer answers a lane-shaped turn"*) ok "the layer-loaded turn is measured and reported (the detector is live on a healthy box)" ;;
  *) bad "a clean run never reports the layer-loaded turn — the layer detector is inert: $BR_OUT" ;;
esac
# ... and it must be measured AFTER the layer is provisioned. The first `--check` on a cell installs
# it, and a layer probe that ran before that install would measure an EMPTY extension set and certify
# a layer it never saw (the false PASS this PR exists to remove).
install_ln="$(printf '%s\n' "$BR_OUT" | grep -n 'installing it from' | head -1 | cut -d: -f1)"
layer_ln="$(printf '%s\n' "$BR_OUT" | grep -n 'the extension layer answers a lane-shaped turn' | head -1 | cut -d: -f1)"
if [ -n "$install_ln" ] && [ -n "$layer_ln" ] && [ "$layer_ln" -gt "$install_ln" ]; then
  ok "the layer is measured AFTER it is installed (line $layer_ln > install line $install_ln)"
else
  bad "the layer turn is measured BEFORE the layer is installed (install line='$install_ln', layer line='$layer_ln') — a first bring-up would certify a layer it has not installed yet"
fi
case "$BR_OUT" in
  *"CELL READY"*) ok "a clean run still reaches CELL READY" ;;
  *) bad "a clean run no longer reaches CELL READY — output: $BR_OUT" ;;
esac
[ ! -e "$TOK" ] && ok "token file removed on the success path (as before the fix)" \
                || bad "token file SURVIVED a successful run"
# #1987 — the machine-global package caches are REPORTED by --check, so a growing disk is visible
# BEFORE it stops dispatch (measured: pi-cell-3 refused every dispatch at 258MB free while a 7.1GB
# ~/.cache/uv went unreported). Report-only by design: a cache over its bound must not refuse a
# cell that has room, so this asserts the LINE, not a failure.
case "$BR_OUT" in
  *"caches:"*) ok "bring-up REPORTS the machine-global package caches (#1987)" ;;
  *) bad "bring-up does not report the package caches — a disk sink is invisible again (#1987): $BR_OUT" ;;
esac
case "$BR_OUT" in
  *"per cache, source "*) ok "the cache report carries the bound AND where it came from (an operator can see what 'too big' means, and whether the plist or this environment set it)" ;;
  *) bad "the cache report does not name the bound and its source: $BR_OUT" ;;
esac

# #2032 — the disk reaper is SCHEDULED by the bring-up, not merely reported. Disk exhaustion is the
# second reason cells stopped working: at ~97% used a controller still beats and every dispatch is
# refused, so a report-only check leaves the box to die on a clock.
case "$BR_OUT" in
  *"disk reaper scheduled"*) ok "bring-up INSTALLS and reports the disk reaper timer (#2032)" ;;
  *) bad "bring-up does not schedule the disk reaper — the sinks are unbounded again: $BR_OUT" ;;
esac
# #2416 — harness ACTIVATION is scheduled by the same pass, and the bring-up refuses `CELL READY`
# without it. A cell that runs whatever code it had at its last start is the drift the pass exists to
# stop, and this step was the only one whose failure mode (an unscheduled clock) is invisible in
# `status`: the box looks healthy and simply stops receiving every merged harness fix.
case "$BR_OUT" in
  *"harness activation scheduled"*) ok "bring-up INSTALLS and reports the harness-apply timer (#2416)" ;;
  *) bad "bring-up does not schedule harness activation — the cell will run stale code: $BR_OUT" ;;
esac
if [ -f "$T/systemd-units/eldato-harness-apply.timer" ]; then
  ok "the harness-apply timer unit was rendered and installed"
else
  bad "no harness-apply timer unit was installed under $T/systemd-units"
fi
if grep -q 'ExecStart=/bin/bash .*harness-apply-pass.sh' "$T/systemd-units/eldato-harness-apply.service" 2>/dev/null; then
  ok "and it runs the pass, not the scheduler's own copy of the logic"
else
  bad "the harness-apply unit does not name the pass"
fi
if [ -f "$T/systemd-units/eldato-disk-reaper.timer" ]; then
  ok "the timer unit was rendered and installed"
else
  bad "no timer unit was installed under $T/systemd-units"
fi
if grep -q -- '--apply' "$T/systemd-units/eldato-disk-reaper.service" 2>/dev/null; then
  ok "the installed pass is ARMED (--apply), as this feature was instructed to be"
else
  bad "the installed unit is not armed — it would only ever report"
fi
if grep -q 'Environment=DISK_REAPER_REPOS=' "$T/systemd-units/eldato-disk-reaper.service" 2>/dev/null; then
  ok "the unit carries the repos the venv/worktree classes scan"
else
  bad "the unit carries no DISK_REAPER_REPOS — those classes would fail closed every hour"
fi

say_case "the reaper timer scans the CELL's own checkout, never an ambient \$REPO"
# ⛔ THIS IS THE ARM THAT PINS THE PRODUCT FIX (measured on a fresh CI runner, 2026-10-24). The installer
# falls back to ambient variables when nobody tells it which repo to scan — and it REFUSES outright when
# that fallback yields nothing, which withheld CELL READY on a box that had just cloned its checkout.
# The bring-up already KNOWS the checkout it verified, so it must say so; an ambient $REPO naming some
# OTHER checkout must not win. A decoy repo here makes the two answers DIFFERENT, which is what makes the
# assertion able to fail: without the fix the unit names the decoy.
git init -q "$T/decoy" >/dev/null 2>&1 || { echo "fixture: git init decoy failed" >&2; exit 1; }
git -C "$T/decoy" -c user.email=fixture@example.invalid -c user.name=fixture -c commit.gpgsign=false \
    commit -q --allow-empty -m decoy >/dev/null 2>&1 || { echo "fixture: decoy commit failed" >&2; exit 1; }
printf '%s\n' "$TOK_BODY" > "$TOK"
rm -f "$T/systemd-units/eldato-disk-reaper.service" "$T/systemd-units/eldato-disk-reaper.timer"
BR_AMBIENT_REPO="$T/decoy" br ok normal --check
case "$(cat "$T/systemd-units/eldato-disk-reaper.service" 2>/dev/null)" in
  *"DISK_REAPER_REPOS=$T/cell"*)
    ok "the installed unit scans the CELL's checkout the bring-up just verified" ;;
  *) bad "the installed unit does not scan the cell's checkout — $(grep -h 'DISK_REAPER_REPOS=' "$T/systemd-units/eldato-disk-reaper.service" 2>/dev/null || echo 'no unit at all')" ;;
esac
case "$(cat "$T/systemd-units/eldato-disk-reaper.service" 2>/dev/null)" in
  *"$T/decoy"*)
    bad "an ambient \$REPO($T/decoy) was scanned instead of the cell's own checkout — the reaper would reap a repo this cell does not own" ;;
  *) ok "an ambient \$REPO is NOT substituted for the cell's checkout" ;;
esac

# #2402 — the CONTROLLER is supervised by a service unit the bring-up INSTALLS and reads back. Without
# this the installer exists but nothing invokes it, so a rebuilt cell keeps the measured defect (the
# controller dies with the last tmux session) while the banner says CELL READY.
case "$BR_OUT" in
  *"controller supervised"*) ok "bring-up INSTALLS the controller service unit and reports it (#2402)" ;;
  *) bad "bring-up does not put the controller under a service — the installer is never invoked, so an empty box still loses its dispatcher: $BR_OUT" ;;
esac
if [ -f "$T/systemd-units/eldato-orchestrator.service" ]; then
  ok "the controller unit was rendered and installed"
  grep -qxF 'Restart=always' "$T/systemd-units/eldato-orchestrator.service" \
    && ok "the installed controller unit carries Restart=always (an orderly exit 0 is restarted)" \
    || bad "the installed controller unit does not carry Restart=always — the measured defect is re-shipped"
else
  bad "no controller unit was installed under $T/systemd-units"
fi

say_case "a cell whose CONTROLLER cannot be supervised is refused (not certified)"
# A REAL installer that fails is the shape: the fix must not be "install it, ignore the exit code".
printf '%s\n' '#!/bin/sh' 'echo "installer: no service manager available" >&2' 'exit 1' > "$T/broken-controller-installer.sh"
chmod +x "$T/broken-controller-installer.sh"
printf '%s\n' "$TOK_BODY" > "$TOK"
CONTROLLER_SERVICE_INSTALLER="$T/broken-controller-installer.sh" br ok normal --check
[ "$BR_RC" -ne 0 ] && ok "bring-up exits non-zero when the controller service cannot be installed (rc=$BR_RC)" \
                   || bad "bring-up returned 0 with an unsupervised controller"
case "$BR_OUT" in
  *"CELL READY"*) bad "CLAIMED readiness on a cell whose controller has nothing above it" ;;
  *) ok "does not claim CELL READY when the controller is unsupervised" ;;
esac
rm -f "$T/broken-controller-installer.sh"

say_case "a cell whose reaper timer cannot be ENABLED is refused (not certified)"
printf '%s\n' "$TOK_BODY" > "$TOK"
SYSTEMCTL_STUB_MODE=fail br ok normal --check
[ "$BR_RC" -ne 0 ] && ok "bring-up exits non-zero when the timer cannot be enabled (rc=$BR_RC)" \
                   || bad "bring-up returned 0 with an un-armable timer"
case "$BR_OUT" in
  *"CELL READY"*) bad "CLAIMED readiness on a cell whose disk reaper is not scheduled" ;;
  *) ok "does not claim CELL READY when the reaper is unscheduled" ;;
esac

# ── 2b) a cell that ALREADY carries the layer is a read-back, not a re-install (#1723) ───────────
# `--check` verifies first and only installs when the read-back refuses, so a re-run against a
# provisioned cell must not re-copy the layer. The discriminator is the installer's own mode
# banner: "mode=--verify" on the fast path, "mode=--install" if it re-installed.
say_case "second clean run — the layer is verified, not re-installed"
printf '%s\n' "$TOK_BODY" > "$TOK"
br ok normal --check
[ "$BR_RC" -eq 0 ] && ok "the second clean run still exits 0" \
                   || bad "second clean run FAILED (rc=$BR_RC): $BR_OUT"
case "$BR_OUT" in
  *"mode=--install"*) bad "the second run RE-INSTALLED the layer instead of verifying it" ;;
  *"mode=--verify"*) ok "the second run certified the existing layer by reading it back (no install)" ;;
  *) bad "the second run never reported a verify of the layer — output: $BR_OUT" ;;
esac
[ ! -e "$TOK" ] && ok "the token is removed on the second run too" \
                || bad "token file SURVIVED the second clean run"

# ── 2c) a NOISY layer cannot turn a healthy provider into a provider failure (#2100) ─────────────
# Measured 2026-10-19 (#2100 — one box unusable while two ran lanes, the extension present on all
# three): the affected cell's `tortoise-capture` consumed the turn and every turn ended with
# banner-only output (259-262 B). The provider probe read `… | tail -3` of `pi -p` with the whole
# extension layer loaded, so those banner lines BECAME the answer and a healthy box was refused with
# `FATAL: provider probe failed` (`pi` returned LANE_READY once the extension was gone).
# The contract now: the PROVIDER verdict comes from the ISOLATED probe first (nothing in the layer
# can answer for it), and the layer-loaded turn is measured separately, twice. So a noisy layer
# cannot produce a provider failure — and it cannot certify the cell either, because a layer that
# produces no answer in two attempts IS a cell that cannot run a lane.
say_case "a noisy extension layer cannot produce a provider failure (#2100)"
# NON-VACUITY first: the fixture really is the measured shape — asked WITH the layer, it emits banner
# lines and no answer, which is exactly what used to be read as "the provider is broken".
probe_out="$(PATH="$STUB:$PATH" PI_STUB_MODE=noisy "$STUB/pi" -p --no-session \
              'Reply with exactly: LANE_READY' 2>&1)"
case "$probe_out" in
  *LANE_READY*) bad "the noisy fixture still answers — this case would pass for the wrong reason" ;;
  *) ok "the fixture reproduces the measured shape: banner-only output, no provider answer" ;;
esac
# ... and the OTHER half: the same fixture DOES answer when the probe isolates, which is what makes
# the verdict "the layer, not the provider" (and not "everything is broken").
probe_iso="$(PATH="$STUB:$PATH" PI_STUB_MODE=noisy "$STUB/pi" -p --no-session --no-extensions \
              'Reply with exactly: LANE_READY' 2>&1)"
case "$probe_iso" in
  *LANE_READY*) ok "the same fixture answers with extensions disabled — the layer is the culprit, provably" ;;
  *) bad "the fixture does not answer even in isolation — the attribution below would be vacuous" ;;
esac
printf '%s\n' "$TOK_BODY" > "$TOK"
PI_STUB_MODE=noisy br ok normal --check
case "$BR_OUT" in
  *"provider probe failed"*) bad "a NOISY layer turned a healthy provider into a provider failure — the probe is not isolated: $BR_OUT" ;;
  *) ok "the probe reports NO provider failure while the layer emits banner lines" ;;
esac
# The detector must be LIVE, not merely absent: the isolated probe proved the provider healthy, so the
# run has to NAME the layer and state that the provider is not the problem.
case "$BR_OUT" in
  *"the PROVIDER is healthy"*) ok "the failure states the provider is healthy (the layer is the culprit)" ;;
  *) bad "the layer swallowed the turn and the failure does not name the attribution: $BR_OUT" ;;
esac
[ "$BR_RC" -ne 0 ] && ok "the run FAILS on a layer that produces no answer (rc=$BR_RC)" \
                   || bad "the run reported success over a layer that cannot complete a turn"
case "$BR_OUT" in
  *"CELL READY"*) bad "CELL READY was claimed over a box whose turns produce no answer — the mirror false PASS" ;;
  *) ok "no readiness banner is claimed over a layer that cannot complete a turn" ;;
esac

# ── 2c1) the INSTRUCTION cannot satisfy either probe: no vacuous pass on the prompt text ─────────
# The instruction itself contains the token, so output that prints that line would answer the probe
# with no model call. The extractor refuses a byte-identical instruction line, so both probes read
# "no answer" and the run fails as a provider failure. DECLARED LIMIT (pinned by 2c1b, not asserted
# away): the refusal is exact-line only — any OTHER line carrying the token counts, so a wrapper that
# echoes the prompt inside a longer line would still answer for the model. Widening the refusal to
# close that re-opens the false negative 2c1b pins.
say_case "the instruction printed back cannot pass the probe (#2100)"
printf '%s\n' "$TOK_BODY" > "$TOK"
PI_STUB_MODE=instruction br ok normal --check
[ "$BR_RC" -ne 0 ] && ok "the run FAILS when the only 'answer' is the instruction printed back" \
                   || bad "printing the instruction back satisfied the probe — vacuous pass"
case "$BR_OUT" in
  *"provider probe failed"*) ok "the printed-back instruction is reported as NO provider answer" ;;
  *) bad "the printed-back instruction was not classified as a missing answer: $BR_OUT" ;;
esac

# ── 2c1b) a VERBOSE answer still counts: the echo guard must stay narrow ─────────────────────────
# The mirror of 2c1. `grep -vF 'Reply with exactly'` (the first cut of the guard) discarded ANY line
# containing the phrase, so a model that wrapped the token in the instruction — a correct answer —
# read as "no answer" and a healthy box died with `FATAL: provider probe failed`. Only a
# BYTE-IDENTICAL line is refused now; this case goes red if the guard is ever widened back.
say_case "a verbose answer is still an answer (#2100)"
printf '%s\n' "$TOK_BODY" > "$TOK"
PI_STUB_MODE=verbose br ok normal --check
case "$BR_OUT" in
  *"provider probe failed"*) bad "a verbose-but-correct answer was read as no answer — the echo guard is too wide: $BR_OUT" ;;
  *) ok "a verbose answer (token wrapped in the instruction) is accepted" ;;
esac
[ "$BR_RC" -eq 0 ] && ok "the run still reaches a clean verdict on a verbose answer" \
                   || bad "the run FAILED on a verbose answer (rc=$BR_RC): $BR_OUT"
case "$BR_OUT" in
  *"CELL READY"*) ok "a verbose answer still reaches CELL READY" ;;
  *) bad "a verbose answer never reaches CELL READY — output: $BR_OUT" ;;
esac

# ── 2c1c) a KILLED layer probe is not blamed on an extension (#2100 review) ─────────────────────
# `timeout` kills the child at 120s and reports 124. The provider already answered in isolation, so
# the key is good and the call is what failed: reporting "find the extension and remove it" would
# send an operator to delete a healthy extension over a network flap — the same mis-attribution the
# provider-side arms exist to prevent.
say_case "a timed-out layer probe names the CALL, not an extension (#2100)"
printf '%s\n' "$TOK_BODY" > "$TOK"
PI_STUB_MODE=slowlayer br ok normal --check
[ "$BR_RC" -ne 0 ] && ok "the run FAILS when the layer probe is killed on both attempts (rc=$BR_RC)" \
                   || bad "the run passed while the layer probe never completed"
case "$BR_OUT" in
  *"TIMED OUT after 120s"*) ok "the failure names the TIMEOUT (exit 124)" ;;
  *) bad "the timeout is not named — output: $BR_OUT" ;;
esac
case "$BR_OUT" in
  *"Find the extension"*) bad "a killed probe was blamed on an extension — the operator would delete a healthy one" ;;
  *) ok "the failure does not accuse an extension" ;;
esac

# ── 2c1d) a MIXED layer outcome must report both attempts, not claim a double timeout ──────────
# The reviewer's case: attempt 1 completes (banner-only, exit 0), attempt 2 is killed (124). Saying
# "timed out on both attempts" would be false about attempt 1 AND discard the banner it produced —
# the mis-attribution this PR exists to remove, mirrored.
say_case "a mixed layer outcome reports BOTH attempts, not a baseline-wide claim (#2100)"
printf '%s\n' "$TOK_BODY" > "$TOK"
: > "$T/mixed-attempts.cnt"
PI_STUB_COUNT="$T/mixed-attempts.cnt" PI_STUB_MODE=mixedlayer br ok normal --check
[ "$BR_RC" -ne 0 ] && ok "the run FAILS on a mixed layer outcome (rc=$BR_RC)" \
                   || bad "the run passed while the layer never answered"
case "$BR_OUT" in
  *"on BOTH attempts"*) bad "a mixed outcome was reported as a double timeout — the completed attempt's evidence was discarded: $BR_OUT" ;;
  *) ok "the failure does not claim a double timeout" ;;
esac
case "$BR_OUT" in
  *"exits 0,124"*) ok "the per-attempt exits are reported (0,124)" ;;
  *) bad "the per-attempt exits are not reported — the evidence is lost: $BR_OUT" ;;
esac
case "$BR_OUT" in
  *"[attempt 1 exit 0]"*) ok "the completed attempt's own output is kept in the failure" ;;
  *) bad "the completed attempt's evidence is missing from the failure: $BR_OUT" ;;
esac

# ── 2c1e) the answer is read from the WHOLE stream, never from its last lines (#2100 review) ─────
# The measured defect was `pi -p … 2>&1 | tail -3`: whatever printed LAST became the answer. The
# two-probe split fixed the ATTRIBUTION, but nothing pinned the extractor's second half — every
# other fixture puts the answer on the LAST line (or omits it entirely), so re-adding `| tail -3`
# to either probe left this suite fully green while the answer sat above the window. The `trailing`
# fixture is the measured shape: the answer FIRST, then three banner lines a noisy layer wrote
# after it. It answers in BOTH modes, so a `tail` regression on the isolated probe reads as a
# provider failure and one on the layer probe blames a HEALTHY layer for swallowing the turn.
say_case "the answer is read from the WHOLE stream, not its last lines (#2100 review)"
# NON-VACUITY: the answer really is outside a 3-line tail of this fixture's output — a case whose
# answer happened to sit in the last three lines could not discriminate a `tail` regression at all.
trail_out="$(PATH="$STUB:$PATH" PI_STUB_MODE=trailing "$STUB/pi" -p --no-session \
              'Reply with exactly: LANE_READY' 2>&1)"
case "$trail_out" in
  *LANE_READY*) ok "the trailing fixture DOES answer — this case would pass for the wrong reason otherwise" ;;
  *) bad "the trailing fixture never answers, so the assertions below are vacuous" ;;
esac
case "$(printf '%s\n' "$trail_out" | grep -v '^[[:space:]]*$' | tail -3)" in
  *LANE_READY*) bad "the answer is still inside the last 3 lines — this fixture cannot discriminate a 3-line-tail regression" ;;
  *) ok "the answer sits ABOVE the last three lines (a 3-line tail window cannot see it)" ;;
esac
printf '%s\n' "$TOK_BODY" > "$TOK"
PI_STUB_MODE=trailing br ok normal --check
case "$BR_OUT" in
  *"provider probe failed"*) bad "a trailing banner after the answer became a PROVIDER failure — the probe still reads only the last lines: $BR_OUT" ;;
  *) ok "the isolated provider probe finds the answer with banner lines printed after it" ;;
esac
case "$BR_OUT" in
  *"provider call works (pi returned LANE_READY)"*) ok "the provider verdict is positive on a trailing-banner answer" ;;
  *) bad "the provider verdict was not positive although the answer was in the stream: $BR_OUT" ;;
esac
case "$BR_OUT" in
  *"produced no answer in two attempts"*)
    bad "a HEALTHY layer was blamed for swallowing the turn — the layer probe discarded the answer above its last lines: $BR_OUT" ;;
  *) ok "a trailing banner does not make a HEALTHY layer look like it swallowed the turn" ;;
esac
[ "$BR_RC" -eq 0 ] && ok "the run still exits 0 on an answer followed by banner lines (rc=$BR_RC)" \
                   || bad "a healthy box FAILED on an answer followed by banner lines (rc=$BR_RC): $BR_OUT"
case "$BR_OUT" in
  *"CELL READY"*) ok "a trailing-banner run still reaches CELL READY" ;;
  *) bad "a trailing-banner run never reaches CELL READY — output: $BR_OUT" ;;
esac

# ── 2c2) a BROKEN provider is still blamed on the provider, whatever the layer does ──────────────
# The two-probe contract must not turn a genuinely dead key into a layer finding. With the provider
# rejecting in EVERY mode (isolated included), the 401 arm is authoritative — this is the case that
# goes red if the isolated probe is ever demoted behind the layer probe or skipped.
say_case "a rejecting provider is still a provider failure, layer or no layer (#2100)"
printf '%s\n' "$TOK_BODY" > "$TOK"
PI_STUB_MODE=broken br ok normal --check
case "$BR_OUT" in
  *"provider key REJECTED (401)"*) ok "the run blames the PROVIDER when the key is rejected in every mode" ;;
  *) bad "a rejecting provider was not reported as a provider failure — output: $BR_OUT" ;;
esac
case "$BR_OUT" in
  *"the PROVIDER is healthy"*) bad "a dead key was mis-attributed to the extension layer" ;;
  *) ok "no layer attribution is emitted when the provider is the culprit" ;;
esac
[ "$BR_RC" -ne 0 ] && ok "the run FAILS on a rejecting provider" \
                   || bad "the run reported success over a rejecting provider"

# ── 2d) a cell that CARRIES the capture extension: the read-back fails, and --check NAMES it ────
# This is the provisioning half of #2100. The extension is still in the manifest ship-list, so a
# bare bringup re-ships it; the deny in cell-install.sh is what keeps it off the cell, and its
# `--verify` half must REFUSE a cell that carries it. `--check` used to DISCARD the verify output
# (`out` was overwritten by the install) — so the operator saw "the cell does not carry a current
# layer" and never the artifact that was wrong, while the next bringup put the extension back.
# The line below is the whole diagnosis, and it is asserted on its EXACT wording.
say_case "a cell carrying tortoise-capture fails the read-back, and --check names it (#2100)"
CAPTURE_LINE='capture extension present on a cell: it blocks session_start and corrupts the provider probe'
mkdir -p "$T/home/.pi/agent/extensions/tortoise-capture"
echo '// hand-pushed by the test' > "$T/home/.pi/agent/extensions/tortoise-capture/index.ts"
printf '%s\n' "$TOK_BODY" > "$TOK"
br ok normal --check
case "$BR_OUT" in
  *"$CAPTURE_LINE"*) ok "--check surfaces the (b) failure verbatim: $CAPTURE_LINE" ;;
  *) bad "--check never names the capture extension — the read-back's refusal is still swallowed: $BR_OUT" ;;
esac
case "$BR_OUT" in
  *"provider probe failed"*) bad "the run blamed the PROVIDER — the extension's banner corrupted the probe again" ;;
  *) ok "the failure is attributable to the extension (b), not to the provider probe" ;;
esac
[ ! -e "$T/home/.pi/agent/extensions/tortoise-capture" ] \
  && ok "the run REMOVED the extension (the deny repairs a cell that carries it, instead of certifying it)" \
  || bad "the capture extension SURVIVED the bringup — it would block every lane turn again"
[ "$BR_RC" -eq 0 ] && ok "readiness is reported only AFTER the read-back refused and the repair removed it" \
                   || bad "the run failed after the repair (rc=$BR_RC): $BR_OUT"
case "$BR_OUT" in
  *"CELL READY"*) ok "the repaired cell reaches CELL READY" ;;
  *) bad "the repaired cell never reaches CELL READY — output: $BR_OUT" ;;
esac
# ── 2c) the SCHEDULED layer (#1864): a cell that comes up has jobs that RUN ──────────────────────
# The measured defect was a whole layer that never reached the cells (10 plists, 0 live) and no
# instrument that said so. The acceptance is therefore a RUN, not a loaded unit or a present file:
# a stamp with an rc plus a fresh log line, produced by the job itself.
say_case "the scheduled layer is installed AND proven by a run (#1864)"
printf '%s\n' "$TOK_BODY" > "$TOK"
# Make the fixture job DUE again: it already ran on the earlier clean runs and its interval is an
# hour, so without clearing the stamp this case would assert on a job that had nothing to do — and
# pass for the wrong reason. (A never-run job is due immediately, which is the same path a fresh
# cell takes.)
rm -f "$T/schedule-marker" \
      "$T/home/.pi/agent/state/fleet-schedule/jobs/com.test.bringup-schedule.json"
br ok normal --check
[ "$BR_RC" -eq 0 ] && ok "bring-up still exits 0 with the scheduled layer" \
                   || bad "bring-up FAILED on the scheduled layer (rc=$BR_RC): $BR_OUT"
case "$BR_OUT" in
  *"scheduled layer live: SCHEDULE VERIFIED"*) ok "it reports the scheduler's own verified verdict" ;;
  *) bad "no verified schedule verdict in the bring-up output — output: $BR_OUT" ;;
esac
[ -f "$T/schedule-marker" ] && ok "the declared job actually RAN during bring-up (its own marker exists)" \
                            || bad "no job ran — 'scheduled' would be believed, not proven"
log="$T/home/.pi/agent/state/fleet-schedule/logs/com.test.bringup-schedule.log"
grep -q 'fleet-schedule run com.test.bringup-schedule start' "$log" 2>/dev/null \
  && ok "the run left a fresh log line at $log" || bad "no run log line at $log"
[ ! -e "$TOK" ] && ok "the token is still removed on this path" || bad "token SURVIVED the scheduled-layer run"

# ── 2d) a scheduled layer that cannot be honoured REFUSES the cell ──────────────────────────────
# A "CELL READY" over a cell with no reaping/liveness/canary is the false PASS this whole script
# exists to remove, so a broken declaration must be fatal. The broken job's target does not exist —
# the same rule install-launchd.sh applies to a plist ("a dead job must never be installed").
say_case "a broken job declaration refuses the cell (no false CELL READY)"
BROKENDIR="$T/schedule-broken"
mkdir -p "$BROKENDIR"
printf '# fixture: nothing retired\n' > "$BROKENDIR/RETIRED"
cat > "$BROKENDIR/com.test.broken.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
    <key>Label</key><string>com.test.broken</string>
    <key>ProgramArguments</key>
    <array><string>/bin/sh</string><string>{{HOME}}/.pi/agent/scripts/cell-bringup-1864-missing.sh</string></array>
    <key>StartInterval</key><integer>3600</integer>
</dict>
</plist>
PLIST
printf '%s\n' "$TOK_BODY" > "$TOK"
BR_OUT="$(PATH="$STUB:$PATH" \
          CELL_HOME="$T/home" WORKDIR="$T/cell" ENV_FILE="$T/keys.env" \
          GH_TOKEN_FILE="$TOK" CURL_STUB_MODE=normal TEMPLATES_DIR="$BROKENDIR" \
          REPO_SLUG="daniel-ospina/tortoise" \
          bash "$BRINGUP" --check 2>&1)"
BR_RC=$?
[ "$BR_RC" -ne 0 ] && ok "bring-up exits non-zero ($BR_RC) on an unhonourable job set" \
                   || bad "bring-up returned 0 over a job set it could not schedule"
case "$BR_OUT" in
  *"broken target"*) ok "the failure names the broken target" ;;
  *) bad "the failure is not diagnosable — output: $BR_OUT" ;;
esac
case "$BR_OUT" in
  *"CELL READY"*) bad "CLAIMED readiness with no working scheduled layer" ;;
  *) ok "never claims CELL READY with a broken schedule" ;;
esac

# ── 3) an abort BEFORE check_gh is reached — the window the pre-fix code left open ───────────────
# The removal used to live INSIDE check_gh, and there was no trap, so a failure in check_tools or
# check_network left the pushed token on disk for as long as the VM existed.
say_case "abort between the push and check_gh (github unreachable)"
printf '%s\n' "$TOK_BODY" > "$TOK"
br ok fail --check
[ "$BR_RC" -ne 0 ] && ok "bring-up exits non-zero ($BR_RC) when github is unreachable" \
                   || bad "bring-up returned 0 with github unreachable"
case "$BR_OUT" in
  *"cannot reach github.com"*) ok "it died at check_network (check_gh was never reached)" ;;
  *) bad "did not fail at check_network — output: $BR_OUT" ;;
esac
[ ! -e "$TOK" ] && ok "token REMOVED although check_gh was never reached" \
                || bad "token SURVIVED an abort that happened before check_gh"

# ── 4) the non-`die` exit path: an unknown mode exits 2 ──────────────────────────────────────────
say_case "unknown mode (the exit-2 path, not a die)"
printf '%s\n' "$TOK_BODY" > "$TOK"
br ok normal --bogus
[ "$BR_RC" -eq 2 ] && ok "bring-up exits 2 on an unknown mode" || bad "expected rc=2, got $BR_RC"
[ ! -e "$TOK" ] && ok "token REMOVED on the unknown-mode exit" \
                || bad "token SURVIVED the unknown-mode exit"

# ── 5) SIGTERM: the cleanup must RUN — the 143 alone is not the proof ──────────────────────────
say_case "SIGTERM while the run is in flight"
printf '%s\n' "$TOK_BODY" > "$TOK"
rm -f "$T/curl-started"
PATH="$STUB:$PATH" CELL_HOME="$T/home" WORKDIR="$T/cell" ENV_FILE="$T/keys.env" \
  GH_TOKEN_FILE="$TOK" CURL_STUB_MODE=slow CURL_STUB_MARK="$T/curl-started" \
  REPO_SLUG="daniel-ospina/tortoise" \
  bash "$BRINGUP" --check > "$T/term.out" 2>&1 &
TERM_PID=$!
# Kill only once the script is provably in flight (the curl stub has started), so the TERM cannot
# land before the trap is installed — that race would fail a correct implementation.
i=0
while [ ! -e "$T/curl-started" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
if [ ! -e "$T/curl-started" ]; then
  bad "the script never reached check_network — cannot test SIGTERM"
  kill -TERM "$TERM_PID" 2>/dev/null
else
  kill -TERM "$TERM_PID" 2>/dev/null
fi
wait "$TERM_PID" 2>/dev/null; TERM_RC=$?
[ "$TERM_RC" -eq 143 ] && ok "the shell reports 143 on TERM" \
                       || bad "expected rc=143 after TERM, got $TERM_RC"
# The real contract is that the trap's cleanup RAN. 143 is a weak signal: an untrapped TERM reaches
# the parent as 143 as well, so the removal log and the token's absence are what this case pins.
case "$(cat "$T/term.out" 2>/dev/null)" in
  *"secret file removed: $TOK"*) ok "the EXIT trap's own cleanup ran on TERM (the real contract)" ;;
  *) bad "no removal log on TERM — the cleanup did not run" ;;
esac
[ ! -e "$TOK" ] && ok "token REMOVED on SIGTERM" || bad "token SURVIVED SIGTERM"

# ── 6) a removal that FAILS must be LOUD and must not report readiness ───────────────────────────
# The pre-fix `rm -f "$tokfile" && ok "token file removed"` printed NOTHING when rm failed, so a
# token that could not be removed fell straight through to the CELL READY banner.
# ⚠️ LIMIT: this case does NOT reproduce the pre-fix defect. The pre-fix script contains no
# GH_TOKEN_FILE at all (grep -c = 0 on 15ee52a's copy) and hardcodes /tmp/.gh-tok, so against that
# copy the case fails because the path is simply IGNORED, not because the removal failed. It is a
# contract test of the shipped implementation (fail-closed on a removal that fails); the
# reproduction of the defect is case 1. The same holds for the unreachable-parent case 8.
say_case "the token file cannot be removed (fail-closed, not fail-open)"
if [ "$(id -u)" = "0" ]; then
  skip "the token file cannot be removed — running as root, a mode-500 parent does not deny rm"
else
  mkdir -p "$T/ro"
  printf '%s\n' "$TOK_BODY" > "$T/ro/.gh-tok"
  chmod 500 "$T/ro"
  BR_OUT="$(PATH="$STUB:$PATH" \
            CELL_HOME="$T/home" WORKDIR="$T/cell" ENV_FILE="$T/keys.env" \
            GH_TOKEN_FILE="$T/ro/.gh-tok" CURL_STUB_MODE=normal \
            REPO_SLUG="daniel-ospina/tortoise" \
            bash "$BRINGUP" --check 2>&1)"
  BR_RC=$?
  chmod 700 "$T/ro"
  [ "$BR_RC" -ne 0 ] && ok "bring-up exits non-zero ($BR_RC) when the token cannot be deleted" \
                     || bad "bring-up returned 0 with the token still on disk"
  case "$BR_OUT" in
    *"could not remove the token file"*) ok "the failure names the file that could not be removed" ;;
    *) bad "the failed removal is not reported — output: $BR_OUT" ;;
  esac
  [ "$(printf '%s\n' "$BR_OUT" | grep -c 'SECURITY:')" -eq 1 ] \
    && ok "the failure is reported exactly once (the pre-banner refusal and the EXIT trap do not double-report)" \
    || bad "the SECURITY report was duplicated or absent — output: $BR_OUT"
  case "$BR_OUT" in
    *"CELL READY"*) bad "CLAIMED readiness with the token still on disk (fail-open)" ;;
    *) ok "never claims CELL READY while the token is still on disk" ;;
  esac
  chmod 700 "$T/ro" 2>/dev/null
  rm -f "$T/ro/.gh-tok" 2>/dev/null
  rmdir "$T/ro" 2>/dev/null
fi

# ── 7) a keys.env that tries to DISARM the cleanup ──────────────────────────────────────────────
# $ENV_FILE is arbitrary shell, and the cleanup lives in a trap in the SAME shell that sources it.
# One line, `trap - EXIT`, removes the handler and the pushed token then outlives the run — the
# #1713 guard cannot see it (the file parses, and it does not end with a top-level exit), so the
# handlers must be (re-)asserted after the source.
say_case "keys.env disarms the cleanup with 'trap - EXIT'"
if [ -f "$T/keys-trap.env" ]; then :; fi
printf 'DEEPSEEK_API_KEY=fake\ntrap - EXIT\n' > "$T/keys-trap.env"
printf '%s\n' "$TOK_BODY" > "$TOK"
BR_OUT="$(PATH="$STUB:$PATH" \
          CELL_HOME="$T/home" WORKDIR="$T/cell" ENV_FILE="$T/keys-trap.env" \
          GH_TOKEN_FILE="$TOK" GH_STUB_MODE=fail CURL_STUB_MODE=normal \
          REPO_SLUG="daniel-ospina/tortoise" \
          bash "$BRINGUP" --check 2>&1)"
BR_RC=$?
[ "$BR_RC" -ne 0 ] && ok "bring-up still exits non-zero ($BR_RC) with the trap-disarming keys.env" \
                   || bad "bring-up returned 0 with a trap-disarming keys.env"
[ ! -e "$TOK" ] && ok "token REMOVED although keys.env ran 'trap - EXIT'" \
                || bad "token SURVIVED — keys.env disarmed the EXIT trap"

# ── 8) a token whose parent denies TRAVERSAL (stat cannot see it) ───────────────────────────────
# `[ -e ]`/`[ -f ]` are FALSE for a file under a directory with no +x — the same answer they give
# for an absent file. A cleanup that gates on that stat (the first version of this fix did)
# therefore skipped the removal, printed nothing, and reached CELL READY with the credential still
# on disk. `rm -f`'s own status is the fail-closed signal.
say_case "the token's parent denies traversal (present but unstatable)"
if [ "$(id -u)" = "0" ]; then
  skip "the token's parent denies traversal — running as root bypasses directory permission checks"
else
  mkdir -p "$T/nox"
  printf '%s\n' "$TOK_BODY" > "$T/nox/.gh-tok"
  chmod 400 "$T/nox"
  BR_OUT="$(PATH="$STUB:$PATH" \
            CELL_HOME="$T/home" WORKDIR="$T/cell" ENV_FILE="$T/keys.env" \
            GH_TOKEN_FILE="$T/nox/.gh-tok" CURL_STUB_MODE=normal \
            REPO_SLUG="daniel-ospina/tortoise" \
            bash "$BRINGUP" --check 2>&1)"
  BR_RC=$?
  chmod 700 "$T/nox"
  [ "$BR_RC" -ne 0 ] && ok "bring-up exits non-zero ($BR_RC) when the credential cannot be reached" \
                     || bad "bring-up returned 0 for a token it could not even stat"
  case "$BR_OUT" in
    *"SECURITY:"*) ok "the unreachable credential is reported loudly" ;;
    *) bad "the unreachable credential was IGNORED silently — output: $BR_OUT" ;;
  esac
  [ "$(printf '%s\n' "$BR_OUT" | grep -c 'SECURITY:')" -eq 1 ] \
    && ok "reported exactly once (the refusal and the EXIT trap do not double-report)" \
    || bad "the SECURITY report was duplicated or absent — output: $BR_OUT"
  case "$BR_OUT" in
    *"CELL READY — all links verified"*) bad "CLAIMED readiness while the credential was still on disk (fail-open)" ;;
    *) ok "never claims CELL READY while the credential is still on disk" ;;
  esac
  [ -e "$T/nox/.gh-tok" ] && ok "the suite's fixture is still present (the failure was the script's)" \
                          || bad "the fixture vanished — the case did not test what it claims"
  rm -f "$T/nox/.gh-tok" 2>/dev/null
  rmdir "$T/nox" 2>/dev/null
fi

# ── 9) a SECOND signal while the cleanup is running must not abort it ────────────────────────────
# The EXIT trap IGNORES INT/TERM/HUP/PIPE for the duration of the cleanup. Without that, a second signal
# kills the shell mid-loop and the remaining secrets stay on disk — silently, because a survivor
# changes nothing the operator can see. The `rm` shim parks so the window is real, not theoretical.
# The discriminator is the trap's own REMOVAL LOG: a shell killed mid-cleanup never reaches it (the
# shim's child may still unlink the file), so asserting only the token's absence would pass for the
# wrong reason.
say_case "a second signal during the cleanup cannot abort it"
printf '%s\n' "$TOK_BODY" > "$TOK"
rm -f "$T/curl-started" "$T/rm-started"
PATH="$STUB:$PATH" CELL_HOME="$T/home" WORKDIR="$T/cell" ENV_FILE="$T/keys.env" \
  GH_TOKEN_FILE="$TOK" CURL_STUB_MODE=slow CURL_STUB_MARK="$T/curl-started" \
  RM_STUB_SLOW=1 RM_STUB_MARK="$T/rm-started" \
  REPO_SLUG="daniel-ospina/tortoise" \
  bash "$BRINGUP" --check > "$T/twice.out" 2>&1 &
TWICE_PID=$!
i=0
while [ ! -e "$T/curl-started" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
kill -TERM "$TWICE_PID" 2>/dev/null   # signal 1 — kills the shell, which runs the EXIT trap
i=0
while [ ! -e "$T/rm-started" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
if [ ! -e "$T/rm-started" ]; then
  bad "the cleanup never started — the second-signal window could not be tested"
else
  kill -TERM "$TWICE_PID" 2>/dev/null # signal 2 — lands INSIDE the cleanup
fi
wait "$TWICE_PID" 2>/dev/null
case "$(cat "$T/twice.out" 2>/dev/null)" in
  *"secret file removed: $TOK"*) ok "the cleanup COMPLETED through the second signal (removal logged)" ;;
  *) bad "the cleanup was ABORTED by the second signal — nothing logged a removal" ;;
esac
[ ! -e "$TOK" ] && ok "the token is gone after the second signal" || bad "the token SURVIVED the second signal"

# ── 10) a DEAD STDOUT while the cleanup is running must not truncate it ──────────────────────────
# The cleanup LOGS every removal to stdout, and a log write to a pipe whose reader is gone raises
# SIGPIPE. If that signal is not ignored for the duration of the cleanup it kills the shell mid-loop
# and every registered secret AFTER the current one stays on disk — silently, because a survivor the
# operator is never told about changes nothing they can see. Reproduced on bash 3.2.57 with
# INT/TERM/HUP ignored and two registered secrets: A removed, B LEFT.
# ⚠️ This sources the SHIPPED definitions (only the final `main "$@"` line is stripped): the shipped
# CLI path registers exactly ONE secret, so a second entry cannot be exercised through it — and the
# file explicitly invites registering another. The cleanup code under test is the shipped cleanup.
say_case "a dead stdout during the cleanup cannot truncate it (two registered secrets)"
LIB="$T/bringup-defs.sh"
if [ "$(tail -n 1 "$BRINGUP")" != 'main "$@"' ]; then
  bad "the shipped entry point is no longer the last line — the definitions copy would run main"
else
  sed '$d' "$BRINGUP" > "$LIB"
  SEC_A="$T/tok/.gh-tok"; SEC_B="$T/tok/.second-tok"
  printf '%s\n' "$TOK_BODY" > "$SEC_A"
  printf '%s\n' "$TOK_BODY" > "$SEC_B"
  (
    GH_TOKEN_FILE="$SEC_A"     # what the lib's top-level `register_secret` picks up (entry 1)
    . "$LIB"
    register_secret "$SEC_B"   # entry 2
    exec 1> >(exec true)       # stdout becomes a pipe whose reader is about to be gone
    sleep 1                    # ...provably gone before the trap logs its first removal
    exit 0
  ) 2>/dev/null
  DEAD_RC=$?
  [ ! -e "$SEC_A" ] && ok "the FIRST registered secret was removed" \
                    || bad "the first registered secret SURVIVED the dead-stdout cleanup (rc=$DEAD_RC)"
  [ ! -e "$SEC_B" ] && ok "the SECOND registered secret was removed (the loop reached the end)" \
                    || bad "the second registered secret SURVIVED — a dead stdout truncated the cleanup (rc=$DEAD_RC)"
fi

# ── THE HARNESS PIN: a LINKED WORKTREE, or a refusal that names the path ────────────────────────
# MEASURED 2026-10-21 on two fresh boxes: `$HOME/harness` was a DIRECTORY OF SHA-NAMED SUBDIRECTORIES —
# copies, not worktrees — so the pin file named a path with no `.git` and no `orch-loop.sh` and every
# consumer read `pinned=none` WHILE a pin file existed. The box certified clean and could not run a
# controller. Both halves are pinned here: the refusal (naming the path, because the operator's next
# move depends on WHICH path is wrong) and the materialisation (a real worktree + the sha+timestamp
# record `cloud-cell-supervisor.sh status` reads).
say_case "the harness pin is a LINKED WORKTREE — a directory of sha-named copies is REFUSED, named"
PIN_ROOT="$T/home/harness"
# The measured shape: sha-named DIRECTORIES that are only copies. (They are not git worktrees, so
# `git -C <dir> rev-parse --git-dir` fails for each of them — that is the whole defect.)
rm -rf "$T/home/harness" "$T/home/.harness-path" "$T/home/.pi/agent/state/HARNESS-PIN"
mkdir -p "$PIN_ROOT/abc1234def567/scripts/orchestrator-harness"
printf '#!/bin/bash\n' > "$PIN_ROOT/abc1234def567/scripts/orchestrator-harness/orch-loop.sh"
printf '%s\n' "$PIN_ROOT/abc1234def567/scripts/orchestrator-harness" > "$T/home/.harness-path"
printf '%s\n' "abc1234def567" > "$T/home/.pi/agent/state/HARNESS-PIN" 2>/dev/null || {
  mkdir -p "$T/home/.pi/agent/state"; printf '%s\n' "abc1234def567" > "$T/home/.pi/agent/state/HARNESS-PIN"; }
printf '%s\n' "$TOK_BODY" > "$TOK"
br ok normal --check
[ "$BR_RC" -ne 0 ] && ok "bring-up REFUSES a pin root that is a directory of copies (rc=$BR_RC)" \
                   || bad "bring-up certified a box whose \$HOME/harness is not a worktree — the measured pinned=none state"
case "$BR_OUT" in
  *"$PIN_ROOT exists but is NOT a git worktree"*) ok "the refusal NAMES the path (the operator cannot fix a path nobody printed)" ;;
  *) bad "the refusal does not name \$HOME/harness — output: $BR_OUT" ;;
esac
case "$BR_OUT" in
  *"CELL READY"*) bad "CLAIMED CELL READY over a box whose harness pin points at nothing" ;;
  *) ok "never claims CELL READY over a non-worktree pin root" ;;
esac
case "$BR_OUT" in
  *"mv '"*) ok "the refusal carries the remedy (move the impostor aside), not just the diagnosis" ;;
  *) bad "the refusal gives no remedy — output: $BR_OUT" ;;
esac

say_case "a GLOBAL GH_REPO pushed in keys.env is DROPPED and said out loud (#2235's class)"
# MEASURED 2026-10-21: a cell's keys.env exported GH_REPO=daniel-ospina/tortoise. `gh` honours GH_REPO as
# the DEFAULT repo for every command, so agent-infra rails on that box graded the TORTOISE repo and
# printed `ALREADY MERGED` over zero work. The box must not be refused for it (it is a provisioning
# detail, not a broken cell) — it must be NEUTRALISED, loudly, before anything reads a repo.
# (the pin root is reset to a GOOD shape first: the preceding case deliberately leaves an impostor
# there, and this case is about the env, not about the pin)
rm -rf "$T/home/harness" "$T/home/.harness-path" "$T/home/.pi/agent/state/HARNESS-PIN"
printf 'DEEPSEEK_API_KEY=fake\nexport GH_REPO=daniel-ospina/tortoise\n' > "$T/keys.env"
printf '%s\n' "$TOK_BODY" > "$TOK"
br ok normal --check
case "$BR_OUT" in
  *"dropping GH_REPO='daniel-ospina/tortoise'"*) ok "the pushed global GH_REPO is dropped and NAMED (silent neutralisation would be a mystery)" ;;
  *) bad "bring-up did not report dropping a global GH_REPO — output: $BR_OUT" ;;
esac
[ "$BR_RC" -eq 0 ] && ok "the cell is NOT refused for a keys.env that carries GH_REPO (it is neutralised, not fatal)" \
                   || bad "bring-up refused a cell merely because keys.env exports GH_REPO (rc=$BR_RC): $BR_OUT"
printf 'DEEPSEEK_API_KEY=fake\n' > "$T/keys.env"

say_case "an OPERATOR-SHELL GH_REPO is DROPPED even when keys.env is ABSENT"
# The guard's own docstring claims it covers GH_REPO "from $ENV_FILE or the operator's shell". The
# first cut only ran it AFTER sourcing, and a missing keys.env is a supported non-fatal path — so on
# exactly the arm with no file to blame, an operator shell's sticky `GH_REPO` survived and every
# check below graded another repo. Nothing in the suite covered it: every `br …` case writes
# $T/keys.env first. Assert the DROP line, and the ORDERING, on the no-file arm.
# ⛔ THE PROVIDER KEY MUST COME FROM SOMEWHERE (measured on the CI runner, 2026-10-24): this arm used to
# rely on the CALLER's shell exporting it, so `ok: gh login` -- the first repo-reading check the ordering
# is anchored on -- never printed on CI and the assertion could not observe the claim it makes
# (`drop=3 check=none`), while passing on the author's box. The scenario it models is "the operator's
# shell carries the key, keys.env is absent", so the key is supplied the way that operator would: in the
# ENVIRONMENT (BR_EXTRA_ENV), never in the file this arm proves is absent. `br()` clears the ambient
# keys, so an arm that needs one asks for it by name.
rm -f "$T/absent.env"
BR_ENV_FILE="$T/absent.env" BR_GH_REPO="daniel-ospina/tortoise" BR_EXTRA_ENV="DEEPSEEK_API_KEY=fake" \
  br ok normal --check
case "$BR_OUT" in
  *"dropping GH_REPO='daniel-ospina/tortoise'"*) ok "the operator-shell GH_REPO is dropped and NAMED with keys.env ABSENT" ;;
  *) bad "with keys.env absent, bring-up did not drop an operator-shell GH_REPO — output: $BR_OUT" ;;
esac
drop_at="$(printf '%s\n' "$BR_OUT" | grep -n 'dropping GH_REPO' | head -1 | cut -d: -f1)"
check_at="$(printf '%s\n' "$BR_OUT" | grep -n 'ok: gh login' | head -1 | cut -d: -f1)"
[ -n "$drop_at" ] && [ -n "$check_at" ] && [ "$drop_at" -lt "$check_at" ] \
  && ok "the drop precedes the first repo-reading check (line $drop_at < $check_at)" \
  || bad "the GH_REPO drop did not precede the first repo-reading check (drop=${drop_at:-none} check=${check_at:-none}) — output: $BR_OUT"

say_case "a REPO set to an owner/name SLUG is REPORTED (the guard's own stated class)"
# The guard exists for "an operator who sets it to an owner/name slug gets a named refusal". The first
# cut tested `*/*` — and a slug CONTAINS a slash, so the one shape it was written for was accepted
# SILENTLY (an inert guard), while the warning that did fire described a bare name as a slug. Both
# halves are pinned here so neither direction can go vacuous: the slug must warn, an absolute path
# must stay silent.
printf 'DEEPSEEK_API_KEY=fake\nexport REPO=daniel-ospina/tortoise\n' > "$T/keys.env"
printf '%s\n' "$TOK_BODY" > "$TOK"
br ok normal --check
case "$BR_OUT" in
  *"REPO='daniel-ospina/tortoise' is not an absolute path"*) ok "an owner/name REPO is named, not silently accepted (a '*/*' test made this arm unreachable)" ;;
  *) bad "bring-up accepted REPO=daniel-ospina/tortoise without a word — the guard is inert for the class it names: $BR_OUT" ;;
esac
printf 'DEEPSEEK_API_KEY=fake\nexport REPO=/srv/cell/checkout\n' > "$T/keys.env"
br ok normal --check
case "$BR_OUT" in
  *"REPO='/srv/cell/checkout' is not an absolute path"*) bad "an ABSOLUTE path REPO was warned about — the guard now fires on the shape it must accept: $BR_OUT" ;;
  *) ok "an absolute-path REPO stays silent (a guard that fires on everything is not a guard)" ;;
esac
printf 'DEEPSEEK_API_KEY=fake\n' > "$T/keys.env"

say_case "a NEW box is born PINNED: a linked worktree plus the sha+timestamp record"
rm -rf "$T/home/harness" "$T/home/.harness-path" "$T/home/.pi/agent/state/HARNESS-PIN"
printf '%s\n' "$TOK_BODY" > "$TOK"
br ok normal --check
[ "$BR_RC" -eq 0 ] && ok "bring-up succeeds with no pin present (it materialises one)" \
                   || bad "bring-up failed on a box with no pin (rc=$BR_RC): $BR_OUT"
PIN_SHA="$(git -C "$INFRA" rev-parse origin/main)"
PIN_DIR="$T/home/harness/$(printf '%s' "$PIN_SHA" | cut -c1-12)"
if [ -f "$PIN_DIR/.git" ] && git -C "$PIN_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  ok "the pin is a REAL LINKED WORKTREE ($PIN_DIR) — '.git' is a FILE linking it to the checkout"
else
  bad "no linked worktree at $PIN_DIR — the pin was not materialised (ls: $(ls -A "$T/home/harness" 2>/dev/null | tr '\n' ' '))"
fi
[ -f "$PIN_DIR/scripts/orchestrator-harness/orch-loop.sh" ] \
  && ok "the pinned worktree carries the harness (orch-loop.sh)" \
  || bad "the pinned worktree carries no harness — a controller started from it would exit at once"
[ "$(head -1 "$T/home/.harness-path" 2>/dev/null)" = "$PIN_DIR/scripts/orchestrator-harness" ] \
  && ok ".harness-path names the pinned harness (what cloud-cell-supervisor.sh start reads)" \
  || bad ".harness-path is '$(head -1 "$T/home/.harness-path" 2>/dev/null)' (want $PIN_DIR/scripts/orchestrator-harness)"
REC="$T/home/.pi/agent/state/HARNESS-PIN"
[ "$(head -1 "$REC" 2>/dev/null)" = "$PIN_SHA" ] \
  && ok "HARNESS-PIN line 1 is the FULL sha, so 'status' can read it with head -1" \
  || bad "HARNESS-PIN line 1 is '$(head -1 "$REC" 2>/dev/null)' (want $PIN_SHA)"
case "$(sed -n '2p' "$REC" 2>/dev/null)" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z)
    ok "HARNESS-PIN line 2 is the timestamp (a pin with no age cannot be judged stale)" ;;
  *) bad "HARNESS-PIN carries no ISO timestamp on line 2 — got '$(sed -n '2p' "$REC" 2>/dev/null)'" ;;
esac
case "$BR_OUT" in
  *"CELL READY"*) ok "the pinned box reaches CELL READY" ;;
  *) bad "the pinned box never reached CELL READY — output: $BR_OUT" ;;
esac

say_case "an EXISTING pin is recorded as the commit it is ON — never as origin/main by assumption"
# ⛔ REVIEW FINDING (P1) ON THIS PR: the accept-existing arm used to write `$want` (origin/main's sha) into
# HARNESS-PIN while accepting a worktree that was on an OLDER commit — so `status` printed a sha the box
# was not deployed to: the "pin says one thing, deployment is another" false PASS this whole step exists
# to remove. It also picked "whichever child the glob yielded first", so the choice depended on
# lexicographic order. Both are pinned here: the record carries the worktree's OWN HEAD, the divergence
# is said out loud with the verb that advances it, and a `--check` does not silently redeploy.
PIN_OLD="$(git -C "$PIN_DIR" rev-parse HEAD 2>/dev/null)"
printf 'advance\n' > "$INFRA/scripts/orchestrator-harness/marker.txt"
git -C "$INFRA" add -A
git -C "$INFRA" commit -q -m "advance origin/main past the pin"
git -C "$INFRA" push -q origin main
PIN_NEW="$(git -C "$INFRA" rev-parse origin/main)"
printf '%s\n' "$TOK_BODY" > "$TOK"
br ok normal --check
[ "$PIN_OLD" != "$PIN_NEW" ] && ok "fixture: origin/main advanced past the pinned commit (the state under test)" \
  || bad "fixture: origin/main did not advance, so this case proves nothing"
[ "$BR_RC" -eq 0 ] && ok "an existing (behind) pin does not fail the check (a check must not redeploy)" \
                   || bad "the check failed on a box whose pin is merely behind (rc=$BR_RC): $BR_OUT"
[ "$(head -1 "$REC" 2>/dev/null)" = "$PIN_OLD" ] \
  && ok "HARNESS-PIN records the commit the worktree is ACTUALLY on ($(printf '%s' "$PIN_OLD" | cut -c1-12)), not origin/main's" \
  || bad "HARNESS-PIN line 1 is '$(head -1 "$REC" 2>/dev/null | cut -c1-12)' — it claims a commit the pin is not on (want $(printf '%s' "$PIN_OLD" | cut -c1-12))"
case "$BR_OUT" in
  *"is NOT at origin/main"*) ok "the divergence is REPORTED, with the verb that advances it" ;;
  *) bad "the box is behind its pin and nothing said so — output: $BR_OUT" ;;
esac
case "$BR_OUT" in
  *"run 'cloud-cell-supervisor.sh apply'"*|*"cloud-cell-supervisor.sh apply"*) ok "the report names 'apply' (the remedy), not just the gap" ;;
  *) bad "the behind-pin report names no remedy — output: $BR_OUT" ;;
esac
[ "$(head -1 "$T/home/.harness-path" 2>/dev/null)" = "$PIN_DIR/scripts/orchestrator-harness" ] \
  && ok ".harness-path still names the pin the box is ON (unchanged by the behind report)" \
  || bad ".harness-path moved to '$(head -1 "$T/home/.harness-path" 2>/dev/null)' — a check redeployed the box"
# ⛔ The glob-order defect, DETERMINISTICALLY (review P2 on this PR): the first version of this case put
# the older pin at a random sha-named path, so whether "first glob match" picked the wrong child was a
# ~50% coin flip — and with the RECORD bug still present, `$want` was written regardless of which child
# was chosen, so the two defects masked each other and the case could not fail at all. Two changes make
# it a real detector: the older pin is renamed to `000000000000`, which sorts BEFORE any sha, so
# glob-order selection picks it EVERY time; and the record is read back as the OLD commit's sha, so the
# only logic that can produce the right answer is "prefer the child at the ref".
git -C "$INFRA" worktree remove --force "$PIN_DIR" >/dev/null 2>&1 || true
git -C "$INFRA" worktree add -q --detach "$T/home/harness/000000000000" "$PIN_OLD" >/dev/null 2>&1
PIN_REF_DIR="$T/home/harness/$(printf '%s' "$PIN_NEW" | cut -c1-12)"
git -C "$INFRA" worktree add -q --detach "$PIN_REF_DIR" "$PIN_NEW" >/dev/null 2>&1
printf '%s\n' "$TOK_BODY" > "$TOK"
br ok normal --check
[ "$(head -1 "$REC" 2>/dev/null)" = "$PIN_NEW" ] \
  && ok "with a pin at the ref present AND an older pin that sorts first, the child AT THE REF is CHOSEN" \
  || bad "the pin chosen was '$(head -1 "$REC" 2>/dev/null | cut -c1-12)' — selection follows GLOB ORDER (the older 000000000000 pin), not the ref"
[ "$(head -1 "$T/home/.harness-path" 2>/dev/null)" = "$PIN_REF_DIR/scripts/orchestrator-harness" ] \
  && ok "and .harness-path names THAT pin, so the controller starts from it" \
  || bad ".harness-path names '$(head -1 "$T/home/.harness-path" 2>/dev/null)' — the harness path did not follow the selection"

echo
# ── 11) swap: a cell with NO swap must get one — the measured shape (agent-infra#2390) ───────────
# cell-3 at 345M available with 17 lanes and two pytest runs has nowhere to put a spike: the next
# allocation is an OOM kill. The bring-up is the one step that can escalate, so it must provision
# swap, ACTIVATE it, and read it back from the kernel record rather than trust `swapon`'s status.
say_case "swap absent -> provisioned, activated, persisted, swappiness pinned"
# RESET to the measured shape: no swap row, no file, no fstab line (case 2 already ran this path).
printf 'Filename\tType\tSize\tUsed\tPriority\n' > "$T/proc-swaps"
: > "$T/fstab"
printf '60\n' > "$T/swappiness"
rm -f "$T/swapfile" "$T/sysctl.d/99-cell-swap.conf"
: > "$SWAP_LOG"
SWAP_STUB_LOG="$SWAP_LOG" br ok normal --check
[ "$BR_RC" -eq 0 ] && ok "bring-up exits 0 with swap provisioned (rc=$BR_RC)" \
  || bad "bring-up FAILED provisioning swap (rc=$BR_RC): $BR_OUT"
[ -f "$T/swapfile" ] && ok "the swapfile was created at \$SWAPFILE" \
  || bad "no swapfile was created"
[ "$(grep -c '^fallocate ' "$SWAP_LOG" 2>/dev/null)" = 1 ] \
  && ok "the file was ALLOCATED once (fallocate, not a sparse region of zeros)" \
  || bad "expected exactly 1 fallocate call, got: $(cat "$SWAP_LOG" 2>/dev/null)"
# The MODE, not just the file: a world-readable swapfile leaks the pages of every process on the box,
# and nothing else here would notice `chmod 600` being dropped (the fixture stays private either way).
[ "$(ls -l "$T/swapfile" 2>/dev/null | cut -c1-10)" = "-rw-------" ] \
  && ok "the swapfile is mode 600 (not world-readable)" \
  || bad "the swapfile mode is '$(ls -l "$T/swapfile" 2>/dev/null | cut -c1-10)', expected -rw-------"
# ORDER, not presence: an implementation that swapped on before formatting would still log both.
MK_LINE="$(grep -n '^mkswap ' "$SWAP_LOG" 2>/dev/null | cut -d: -f1)"
SW_LINE="$(grep -n '^swapon ' "$SWAP_LOG" 2>/dev/null | cut -d: -f1)"
[ -n "$MK_LINE" ] && [ -n "$SW_LINE" ] && [ "$MK_LINE" -lt "$SW_LINE" ] \
  && ok "mkswap ran BEFORE swapon (an unformatted file is never activated)" \
  || bad "mkswap/swapon order is wrong or a call is missing: $(cat "$SWAP_LOG" 2>/dev/null)"
grep -qF "$T/swapfile file " "$T/proc-swaps" 2>/dev/null \
  && ok "the kernel swap record carries the new area (the read-back, not swapon's exit status)" \
  || bad "the swap record has no row for the file: $(cat "$T/proc-swaps" 2>/dev/null)"
# 4096 MB = 4194304 KB, the SWAP_MB value pinned above.
grep -qF "$T/swapfile file 4194304 " "$T/proc-swaps" 2>/dev/null \
  && ok "the active area matches the requested size (4096M)" \
  || bad "the active area is not the requested size: $(cat "$T/proc-swaps" 2>/dev/null)"
case "$BR_OUT" in
  *"swap: 4096M active"*) ok "the report states the measured swap total and target" ;;
  *) bad "the swap line does not report the reading: $BR_OUT" ;;
esac
[ "$(grep -cF "$T/swapfile none swap sw" "$T/fstab" 2>/dev/null)" = 1 ] \
  && ok "an fstab entry was added, once (the swap survives a reboot)" \
  || bad "expected exactly one fstab entry, got: $(cat "$T/fstab" 2>/dev/null)"
[ "$(cat "$T/swappiness" 2>/dev/null)" = "30" ] \
  && ok "vm.swappiness was pinned to 30 (not left at the image default of 60)" \
  || bad "vm.swappiness is '$(cat "$T/swappiness" 2>/dev/null)', expected 30"
grep -qxF 'vm.swappiness=30' "$T/sysctl.d/99-cell-swap.conf" 2>/dev/null \
  && ok "the boot-time pin is written to \$SWAP_SYSCTL_CONF" \
  || bad "no boot-time swappiness pin: $(cat "$T/sysctl.d/99-cell-swap.conf" 2>/dev/null)"

# ── 12) IDEMPOTENCY: a second run must not touch a provisioned cell ────────────────────────────
# Rewriting a LIVE swap area is an outage for every page in it, and re-appending the fstab line is
# how a re-run slowly corrupts the boot path. So: no second fallocate/mkswap/swapon, no duplicate
# fstab row, and the report says so.
say_case "swap already provisioned -> nothing is re-created (idempotent)"
: > "$SWAP_LOG"
SWAP_STUB_LOG="$SWAP_LOG" br ok normal --check
[ "$BR_RC" -eq 0 ] && ok "a re-run exits 0 (rc=$BR_RC)" || bad "a re-run FAILED (rc=$BR_RC): $BR_OUT"
[ ! -s "$SWAP_LOG" ] && ok "a re-run issued NO fallocate/mkswap/swapon/swapoff (the area was left alone)" \
  || bad "a re-run touched the live area: $(cat "$SWAP_LOG" 2>/dev/null)"
case "$BR_OUT" in
  *"already provisioned"*) ok "the report says the cell was already provisioned" ;;
  *) bad "the re-run does not report the existing swap: $BR_OUT" ;;
esac
[ "$(grep -cF "$T/swapfile none swap sw" "$T/fstab" 2>/dev/null)" = 1 ] \
  && ok "the fstab entry was not duplicated" \
  || bad "the fstab entry was duplicated: $(cat "$T/fstab" 2>/dev/null)"

# ── 12b) ACTIVE but NOT PERSISTED: the fstab line is re-established on the "already provisioned"
# path too. An area a hand `swapon` (or a first run whose append failed) left out of fstab is
# otherwise certified for ever, and the cell comes back from a reboot with NO swap — the measured
# defect, one power cycle later. The check must ADD the entry and still not touch the live area.
say_case "active swap with NO fstab entry -> the entry is added, the area is not touched"
: > "$T/fstab"
: > "$SWAP_LOG"
SWAP_STUB_LOG="$SWAP_LOG" br ok normal --check
[ "$BR_RC" -eq 0 ] && ok "the run exits 0 (rc=$BR_RC)" || bad "the run FAILED (rc=$BR_RC): $BR_OUT"
[ "$(grep -cF "$T/swapfile none swap sw" "$T/fstab" 2>/dev/null)" = 1 ] \
  && ok "the missing fstab entry was ADDED on the already-provisioned path" \
  || bad "an active swap area was left unpersisted: $(cat "$T/fstab" 2>/dev/null)"
[ ! -s "$SWAP_LOG" ] && ok "the live area was not swapped off or re-created to persist it" \
  || bad "the live area was touched: $(cat "$SWAP_LOG" 2>/dev/null)"

# ── 12c) a `noauto` ENTRY IS NOT A BOOT MOUNT. It names the file in field 1 but explicitly does not
# mount at boot, so a first-field-only match reports "survives a reboot" for the one entry that
# guarantees it does not.
say_case "an fstab entry with noauto does NOT count as persisted"
printf '%s none swap noauto 0 0\n' "$T/swapfile" > "$T/fstab"
: > "$SWAP_LOG"
SWAP_STUB_LOG="$SWAP_LOG" br ok normal --check
[ "$BR_RC" -eq 0 ] && ok "the run exits 0 (rc=$BR_RC)" || bad "the run FAILED (rc=$BR_RC): $BR_OUT"
[ "$(grep -cF "$T/swapfile none swap sw 0 0" "$T/fstab" 2>/dev/null)" = 1 ] \
  && ok "a real boot entry was added beside the noauto one" \
  || bad "the noauto entry was accepted as a boot mount: $(cat "$T/fstab" 2>/dev/null)"
printf '%s none swap sw 0 0\n' "$T/swapfile" > "$T/fstab"   # restore the persisted shape

# ── 12d) A LIVE AREA BELOW TARGET IS NOT RESIZED. `swapoff` faults every swapped page back into RAM,
# and this step runs on a box already short of it — the one action that could OOM-kill the lanes the
# swap exists to protect. It must be REPORTED, not performed: a failed re-allocation after a removal
# is how a cell that had some swap ends up with NONE.
say_case "a live area below target is reported, never swapped off"
printf 'Filename\tType\tSize\tUsed\tPriority\n' > "$T/proc-swaps"
printf '%s file 1048576 0 -2\n' "$T/swapfile" >> "$T/proc-swaps"   # 1024M live, target 4096M
: > "$SWAP_LOG"
SWAP_STUB_LOG="$SWAP_LOG" br ok normal --check
[ "$BR_RC" -eq 0 ] && ok "the run exits 0 (rc=$BR_RC)" || bad "the run FAILED (rc=$BR_RC): $BR_OUT"
case "$BR_OUT" in
  *"NOT resizing a live area"*) ok "the shortfall is REPORTED as a decision not to resize" ;;
  *) bad "the below-target live area was not reported: $BR_OUT" ;;
esac
case "$BR_OUT" in
  *"READING: MemTotal="*) ok "the report carries the reading" ;;
  *) bad "the report does not carry the reading: $BR_OUT" ;;
esac
[ ! -s "$SWAP_LOG" ] && ok "nothing was swapped off, re-allocated or re-formatted" \
  || bad "a live area was destroyed by a --check: $(cat "$SWAP_LOG" 2>/dev/null)"

# ── 12e) THE BOOT-TIME PIN IS VERIFIED ON ITS OWN. When the runtime value already reads 30, a
# pin_swappiness that only writes the drop-in inside the "runtime differs" branch reports "pinned at
# boot" while the file does not exist — and the cell reverts to the image default at the next reboot,
# with the one line an operator greps reading as success.
say_case "runtime already 30 -> the boot-time pin is still written and verified"
printf '30\n' > "$T/swappiness"
rm -f "$T/sysctl.d/99-cell-swap.conf"
SWAP_STUB_LOG="$SWAP_LOG" br ok normal --check
grep -qxF 'vm.swappiness=30' "$T/sysctl.d/99-cell-swap.conf" 2>/dev/null \
  && ok "the drop-in was written although the runtime value already matched" \
  || bad "the boot-time pin was reported on the strength of the runtime value: $(cat "$T/sysctl.d/99-cell-swap.conf" 2>/dev/null)"
case "$BR_OUT" in
  *"runtime and pinned at boot"*) ok "the report distinguishes the runtime value from the boot pin" ;;
  *) bad "the swappiness line does not name both halves: $BR_OUT" ;;
esac

# ── 12f) NOT ENOUGH FREE DISK: a swapfile is not reclaimable by the disk reaper, so allocating one
# on a cell near the threshold trades an OOM kill for a dead cell (worktree/uv fail at ~97%).
say_case "not enough free disk -> refused with the reading, no CELL READY"
printf 'Filename\tType\tSize\tUsed\tPriority\n' > "$T/proc-swaps"
printf '60\n' > "$T/swappiness"
BR_OUT="$(PATH="$STUB:$PATH" \
          CELL_HOME="$T/home" WORKDIR="$T/cell" ENV_FILE="$T/keys.env" \
          GH_TOKEN_FILE="$TOK" CURL_STUB_MODE=normal \
          SWAP_AVAIL_KB=1024 \
          REPO_SLUG="daniel-ospina/tortoise" \
          bash "$BRINGUP" --check 2>&1)"
BR_RC=$?
[ "$BR_RC" -ne 0 ] && ok "bring-up exits non-zero ($BR_RC) when the swapfile would not fit" \
  || bad "bring-up returned 0 and allocated a swapfile on a full disk"
case "$BR_OUT" in
  *"not enough free disk"*"free 1024K"*) ok "the refusal names the free-space reading it acted on" ;;
  *) bad "the refusal does not print the disk reading: $BR_OUT" ;;
esac
case "$BR_OUT" in
  *"CELL READY"*) bad "CLAIMED readiness after refusing to allocate" ;;
  *) ok "never claims CELL READY after the refusal" ;;
esac
# restore the provisioned shape for the cases that follow
printf 'Filename\tType\tSize\tUsed\tPriority\n' > "$T/proc-swaps"
printf '%s file 4194300 0 -2\n' "$T/swapfile" >> "$T/proc-swaps"
printf '30\n' > "$T/swappiness"

# ── 13) REFUSAL: a cell that cannot get swap must not be certified ────────────────────────────
# The failure this removes is a box that looks healthy at 345M available and then silently loses
# lanes. The refusal must name the READING (MemTotal, SwapTotal, target) so an operator can act on
# it, and must not print CELL READY over a cell with no swap.
say_case "cannot escalate -> refused WITH the reading, no CELL READY"
printf 'Filename\tType\tSize\tUsed\tPriority\n' > "$T/proc-swaps"
rm -f "$T/swapfile"
BR_OUT="$(PATH="$STUB:$PATH" \
          CELL_HOME="$T/home" WORKDIR="$T/cell" ENV_FILE="$T/keys.env" \
          GH_TOKEN_FILE="$TOK" CURL_STUB_MODE=normal \
          SWAP_SUDO=false \
          REPO_SLUG="daniel-ospina/tortoise" \
          bash "$BRINGUP" --check 2>&1)"
BR_RC=$?
[ "$BR_RC" -ne 0 ] && ok "bring-up exits non-zero ($BR_RC) when it cannot create swap" \
  || bad "bring-up returned 0 with NO swap on the cell"
case "$BR_OUT" in
  *"cannot escalate to root"*) ok "the refusal names escalation as the reason" ;;
  *) bad "the refusal does not name why it could not act: $BR_OUT" ;;
esac
case "$BR_OUT" in
  *"READING: MemTotal="*"SwapTotal="*"target="*) ok "the refusal PRINTS THE READING (MemTotal/SwapTotal/target)" ;;
  *) bad "the refusal does not print the reading: $BR_OUT" ;;
esac
case "$BR_OUT" in
  *"CELL READY"*) bad "CLAIMED readiness with no swap on the cell (fail-open)" ;;
  *) ok "never claims CELL READY without swap" ;;
esac

# ── 14) the KERNEL'S ROUNDING is not a shortfall (found on a live cell) ──────────────────────
# A 4096M swapfile reports 4194300K = 4095M in /proc/swaps: the kernel rounds the area down to whole
# pages and drops the swap header. Without slack that reads as "below target", so every bring-up
# would WARN on a healthy cell and — worse — swapoff/re-create a LIVE area. Measured on this cell
# (`/swapfile file 4194300 0 -2` for a `-l 4096M` file), pinned here so the rounding cannot come back
# as a re-creation loop.
say_case "a kernel-rounded area (4095M for a 4096M request) is NOT re-created"
printf 'Filename\tType\tSize\tUsed\tPriority\n' > "$T/proc-swaps"
printf '%s file 4194300 0 -2\n' "$T/swapfile" >> "$T/proc-swaps"
: > "$SWAP_LOG"
SWAP_STUB_LOG="$SWAP_LOG" br ok normal --check
[ "$BR_RC" -eq 0 ] && ok "a re-run on the rounded area exits 0 (rc=$BR_RC)" \
  || bad "a rounded area FAILED the run (rc=$BR_RC): $BR_OUT"
case "$BR_OUT" in
  *"already provisioned"*) ok "4095M counts as provisioned against a 4096M target" ;;
  *) bad "the rounded area is not recognised as provisioned: $BR_OUT" ;;
esac
[ ! -s "$SWAP_LOG" ] && ok "nothing was swapped off or re-created (a live area was left alone)" \
  || bad "the rounded area was re-created: $(cat "$SWAP_LOG" 2>/dev/null)"

# ── 15) the SIZING PREDICATE, driven from the shipped function ─────────────────────────────────
# Extracted and driven, not re-derived here: a copy of `max(4 GiB, MemTotal/4)` written into this
# suite would pass against a build whose predicate had been changed to a flat number.
say_case "sizing predicate: max(4 GiB, RAM/4), capped at 16 GiB"
sed -n '/^swap_target_mb() {/,/^}/p' "$BRINGUP" > "$T/target.sh"
if [ -s "$T/target.sh" ]; then
  ( unset SWAP_MB
    . "$T/target.sh"
    t4096=$(swap_target_mb 8011)    # the measured 8 GiB cell: 25% is 2 GiB, below the floor
    tfloor=$(swap_target_mb 2048)   # even a 2 GiB box gets 4 GiB
    t32=$(swap_target_mb 32768)
    t64=$(swap_target_mb 65536)     # capped
    SWAP_MB=512; tover=$(swap_target_mb 32768)
    printf '%s %s %s %s %s' "$t4096" "$tfloor" "$t32" "$t64" "$tover" ) > "$T/target.out"
  got="$(cat "$T/target.out")"
  [ "$got" = "4096 4096 8192 16384 512" ] \
    && ok "8011M->4096M, 2048M->4096M (floor), 32768M->8192M, 65536M->16384M (cap), SWAP_MB=512->512M" \
    || bad "predicate drift: got '$got', expected '4096 4096 8192 16384 512'"
else
  bad "swap_target_mb() is no longer extractable from the shipped script"
fi

# ── 16) the ARMING PREDICATE, driven from the shipped function ────────────────────────────────
# #2164: a cell reported CELL READY while every lane on it logged `#984 … only the string scanner is
# active`. The ready path now conditions its claim on the layer's own activation line, and the
# direction of that condition is the whole point — read backwards it certifies a DISARMED cell as
# armed, which is the defect. Driven from the shipped predicate (extracted, not re-derived), and
# driven in BOTH directions so a predicate that always answers the same way cannot pass.
say_case "arming predicate: a DISARMED activation line is DEGRADED, an armed one is not"
sed -n '/^gh_shim_disarmed() {/,/^}/p' "$BRINGUP" > "$T/shimsed.sh"
if [ -s "$T/shimsed.sh" ]; then
  ( . "$T/shimsed.sh"
    armed='activation: gh shim PRESENT at /home/cell/.pi/agent/gate-bin/gh'
    disarmed='activation: gh shim PRESENT at /home/cell/.pi/agent/gate-bin/gh (DISARMED: AGENT_GH_SHIM=0)'
    absent='activation: (none) gh shim absent — string scanner only'
    gh_shim_disarmed "$armed"    && printf '1' || printf '0'
    gh_shim_disarmed "$disarmed" && printf '1' || printf '0'
    gh_shim_disarmed "$absent"   && printf '1' || printf '0'
  ) > "$T/shim.out"
  got=$(cat "$T/shim.out")
  # armed=0 (the caller's else: NOT degraded), DISARMED=1 (the caller's warn arm), absent=0 — an
  # absent shim is settled by `--verify`'s rc=0 before this predicate is ever consulted.
  [ "$got" = "010" ] \
    && ok "armed->NOT degraded, DISARMED->DEGRADED, no activation line->not this predicate's call" \
    || bad "the arming predicate is INVERTED or blind: got '$got', expected '010' (armed, DISARMED, absent)"
else
  bad "gh_shim_disarmed() is no longer extractable from the shipped script"
fi

echo
say_case "the controller check resolves the installer from the LAYER, not from where this script was pushed"
# ⛔ A REAL CELL RUNS THIS SCRIPT FROM /tmp (pushed standalone), and the installer is not in the farm list:
# a check that only looks "beside this script" (or in $HOME/.pi/agent/scripts) therefore DIED on every
# provisioned cell — killing the bring-up it was added to protect. Resolution must use the layer checkout
# check_operational_layer just installed, which is what this arm pins.
mkdir -p "$T/standalone"
cp "$BRINGUP" "$T/standalone/cloud-cell-bringup.sh"
printf '%s\n' "$TOK_BODY" > "$TOK"
SA_RC=0
SA_OUT="$(PATH="$STUB:$PATH" CELL_HOME="$T/home" WORKDIR="$T/cell" ENV_FILE="$T/keys.env" \
          GH_TOKEN_FILE="$TOK" GH_STUB_MODE=ok CURL_STUB_MODE=normal \
          INFRA_ROOT="$(cd "$HERE/.." && pwd)" REPO_SLUG="daniel-ospina/tortoise" \
          bash "$T/standalone/cloud-cell-bringup.sh" --check 2>&1)" || SA_RC=$?
case "$SA_OUT" in
  *"controller supervised"*) ok "a standalone-pushed bring-up finds the installer in the layer checkout" ;;
  *"install-controller-service.sh not found"*) bad "a standalone-pushed bring-up cannot find the installer — every cell bring-up dies at the controller check" ;;
  *) bad "the standalone run did not reach the controller check (rc=$SA_RC): $(printf '%s' "$SA_OUT" | tail -6 | tr '\n' ' ')" ;;
esac
rm -rf "$T/standalone"

echo "── Summary ───────────────────────────────────────────────────────"
echo "  PASS=$PASS FAIL=$FAIL SKIPPED=$SKIP"
if [ "$SKIP" -gt 0 ]; then
  echo "  ⚠️  $SKIP case(s) SKIPPED above — the fail-closed removal contract was NOT exercised on this"
  echo "      host. A green run here is partial coverage, not a verified contract."
fi
[ "$FAIL" -eq 0 ] || { echo "  ❌ FAILURES — fix and re-run"; exit 1; }
if [ "$SKIP" -gt 0 ]; then
  echo "  ⛔ $SKIP contract case(s) were SKIPPED: this host cannot exercise the fail-closed removal"
  echo "     contract (root bypasses directory permissions). That is NOT a pass — run as a non-root"
  echo "     user. Exiting non-zero so a green shard can never mean 'unverified'."
  exit 1
fi
echo "  ✅ all checks passed"
exit 0
