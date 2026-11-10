#!/usr/bin/env bash
# cell-home.sh — THE one derivation of a cell's home (agent-infra#3453). One rule, one reader.
#
# ⛔ THE FAILURE THIS PREVENTS, MEASURED TWICE. A cell ran with TWO homes and the units disagreed
# about which one a process gets:
#
#   /etc/systemd/system/eldato-orchestrator.service   HOME=/home/cmux        <- the unit that SPAWNS lanes
#   /etc/systemd/system/cell-self-pin.service.d/…     HOME=/tmp/cell-home    <- every other cell service
#
# `gh` resolves its credential `GH_TOKEN` -> `GITHUB_TOKEN` -> `$HOME/.config/gh/hosts.yml`, and `git`
# inherits that through `credential.helper = !gh auth git-credential`, so the two conventions resolved
# two DIFFERENT credentials and a 17-lane wave produced **0 landings**: every lane got a fine-grained
# PAT with `contents=read`, so `git push` answered `403 … X-Accepted-Github-Permissions: contents=write`
# while `gh` READS still worked — which reads like an account problem and sent lanes hunting for a token
# to mint while a working credential was already on the box.
#
# The second consequence is capacity: `/tmp/cell-home` was the `HOME=` of 9 unit files on cell-4 and 7 on
# cell-3 and holds ~23 GB on each, on the SAME filesystem as `/` (measured 2026-11-06: 213G used, 28G
# free). `runner_autoscale.py` budgets 8 GB per runner against a 20 GB reserve, so those cells sit at
# `by_disk=1` and the ceiling cannot rise while the second home holds the space.
#
# ── THE RULE ────────────────────────────────────────────────────────────────────────────────────
# A cell has ONE home. It is the DURABLE one — the account's own home directory — and it is DERIVED,
# never spelled out at each call site. In precedence order:
#
#   1. `${CELL_HOME}` — an explicit override always wins (operator, unit Environment=, installer).
#   2. the account's home from the passwd record (`/home/cmux` on a cell, `/Users/<you>` on a laptop).
#      This is the honest answer even when `$HOME` is not: `cmux vm exec` hands over `HOME=/home/ubuntu`,
#      a directory that does not exist on the image. Same ordering `cloud-cell-bringup.sh::_one_home_want`
#      already uses for its `--check` gate — this file is that derivation given ONE home instead of two.
#      ⛔ AND IT IS GRADED BY THE PREDICATE THAT DECIDES "IS THIS A HOME AT ALL" — absolute, and not
#      `/` — because the passwd record is the box's AUTHORITATIVE answer for its own account, not a guess
#      to be second-guessed. The volatile-root test is step 3's, where the value IS a guess.
#   3. `${HOME_ORIG}` / `${HOME}` — only when the value is absolute and NOT under a volatile root.
#   4. `CELL_HOME_FLEET_DEFAULT` — the fleet's durable cell home. ⛔ THIS IS THE ONLY PLACE THE LITERAL
#      LIVES. A second copy of it is the defect this file exists to remove, so a consumer that needs a
#      default CONSUMES this resolver (see the pin in scripts/cell-home.test.sh).
#
# `/tmp/cell-home` is NEVER derived. It is the LEGACY volatile home: kept (never deleted by this change),
# reported, and reclaimable only after every unit repoints AND a lane proves `push=OK` + `provider=OK`
# from a clean shell with nothing sourced. `CELL_HOME_LEGACY` names it so the migration can speak about
# it without a second literal in every script.
#
# ── WHAT A CONSUMER DOES ────────────────────────────────────────────────────────────────────────
#   . "$(dirname "${BASH_SOURCE[0]}")/lib/cell-home.sh" || exit 78
#   CELL_HOME="$(cell_home_resolve)"          # 0 = resolved; it always prints one line
#   ENV_FILE="${ENV_FILE:-$CELL_HOME/keys.env}"
#
# Exit 78 (EX_CONFIG) on a missing sibling is deliberate: a script that cannot find this file must not
# invent a home, because inventing one is the defect. The file is declared in `pi-bootstrap/setup.sh`'s
# `lib_srcs`, so a farm delivers it to `$HOME/.pi/agent/scripts/lib/cell-home.sh` next to every consumer
# that is farmed, and a checkout or a pinned harness worktree carries it at `<repo>/scripts/lib/`.
#
# ── CONSUMERS: THE SELF PATH, AND WHY `${BASH_SOURCE[0]:-$0}` IS NOT ENOUGH ─────────────────────
# ⛔ A PIPED START (`... | bash -s`) HAS NO `BASH_SOURCE` AND ITS `$0` IS LITERALLY `bash`. So
# `dirname "${BASH_SOURCE[0]:-$0}"` answers `.`, the consumer's `SELF_DIR` becomes the CURRENT WORKING
# DIRECTORY, and `<SELF_DIR>/lib/cell-home.sh` becomes `$PWD/lib/cell-home.sh` — the consumer then
# SOURCES CODE FROM A DIRECTORY IT DOES NOT OWN. That is the same code-execution-from-CWD shape
# `pi-bootstrap/cell-install.sh` refuses for a `keys.env` it does not own (a world-writable parent makes
# "the file is there" not a trust signal). `:-$0` removes the `set -u` crash and replaces it with a
# quieter, worse failure; the crash was at least fail-closed.
#
# THE RULE, at every consumer: the self path counts only when it NAMES THE FILE BEING EXECUTED.
#
#   _SELF="${BASH_SOURCE[0]:-}"; [ -f "$_SELF" ] || _SELF=""
#   SELF_DIR=""
#   if [ -n "$_SELF" ]; then SELF_DIR="$(cd "$(dirname "$_SELF")" 2>/dev/null && pwd -P)"; fi
#
# Without a file there is no sibling to trust, so the consumer takes its documented non-resolver
# fallback — and where that fallback would be an EMPTY home (`O=/orchestrator`,
# `SCRIPTS=/.pi/agent/scripts`, a layer installed at `/.pi/agent`), it REFUSES with exit 78 instead, the
# same refusal the strict consumers already make. Reachability, stated honestly: no shipped invocation
# pipes these files today (`pi-reap-worktrees-launchd.py` is the one piped caller, and launchd's cwd is
# `/`, which holds no `lib/`), so this closes a latent hole rather than a live one.
#
# ── NOT A GATE ──────────────────────────────────────────────────────────────────────────────────
# This file does not decide whether a box is compliant, and it repairs nothing. The gate that REFUSES a
# two-home box is `cloud-cell-bringup.sh::check_one_home` (`--check`), the repointing/migration tool is
# `cell-home-migrate.sh`, and the `--status` report of what a box currently runs is
# `cloud-cell-supervisor.sh status`. One question, one reader.

# The fleet's durable cell home. ⛔ The single literal (see the header).
CELL_HOME_FLEET_DEFAULT="${CELL_HOME_FLEET_DEFAULT:-/home/cmux}"

# The LEGACY volatile home. Named, never derived, never deleted by this change.
CELL_HOME_LEGACY="${CELL_HOME_LEGACY:-/tmp/cell-home}"

# Roots a cell's DURABLE state must not live in. Overridable so a hermetic suite can grade its own
# temp-dir home without grading the host (the same fixture seam `cloud-cell-bringup.sh` declares).
CELL_HOME_VOLATILE_ROOTS="${CELL_HOME_VOLATILE_ROOTS:-/tmp:/var/tmp}"

# cell_home_under_volatile <path> — 0 iff <path> is absolute AND under one of $CELL_HOME_VOLATILE_ROOTS.
cell_home_under_volatile() {
  local p="${1:-}" root
  case "$p" in /*) ;; *) return 1 ;; esac
  while IFS= read -r root; do
    [ -n "$root" ] || continue
    case "$p" in "$root"|"$root"/*) return 0 ;; esac
  done <<EOF
$(printf '%s' "$CELL_HOME_VOLATILE_ROOTS" | tr ':' '\n')
EOF
  return 1
}

# cell_home_account_home — the passwd record's home for the account running this code.
# `getent` is Linux; `dscl`-less macOS answers via `cd ~user`. Both are tried, in that order: `cd ~user`
# is the portable fallback `cloud-cell-bringup.sh` already uses for the same question.
cell_home_account_home() {
  local u acct=""
  u="$(id -un 2>/dev/null || printf '%s' "${USER:-}")"
  [ -n "$u" ] || return 1
  if command -v getent >/dev/null 2>&1; then
    acct="$(getent passwd "$u" 2>/dev/null | awk -F: 'NR==1{print $6}')"
  fi
  [ -n "$acct" ] || acct="$(cd ~"$u" 2>/dev/null && pwd -P)"
  [ -n "$acct" ] || return 1
  printf '%s\n' "$acct"
}

# cell_home_resolve — print the ONE home for this box. Always prints exactly one line; never fails.
# The precedence is the header's list, in the header's order — including the checks that make the derived
# answers a DERIVATION rather than a preference: a value that is not absolute, or that names the root, or
# that sits under a volatile root, is not a durable home and is skipped rather than trusted. ⛔ WHICH
# CHECKS APPLY DEPENDS ON THE ARM, and the arms differ on purpose (see steps 2 and 3 below): ABSOLUTE +
# not-the-root applies to both derived arms, the VOLATILE-ROOT test to step 3 only. A version of this
# paragraph that said "the two checks … a value that is not absolute, or that sits under a volatile root,
# is skipped" was read as covering the passwd record too, and step 2 deliberately does not (the passwd
# record is the box's authoritative answer; arm a10 pins that a volatile passwd home IS returned).
# ⛔ AND THE CHECKS APPLY TO STEP 2 TOO (review P3). They used to gate step 3 only, while step 2 — the
# arm that WINS BY DEFAULT — accepted any non-empty string: with a stubbed passwd record that answers
# `/` (a container account, `sysd:x:100:100::/:/usr/sbin/nologin`), `cell_home_resolve` printed `/`, the
# exact value the sibling consumers' guards exist to prevent (`O=/orchestrator`, `SCRIPTS=/.pi/agent/scripts`, a
# layer installed at `/.pi/agent`). ⛔ NAME THE CLASS, NEVER THE TALLY: the consumer files used to say
# "five sibling consumers", and the tree carried far more than five by the time anyone counted — a number
# that was wrong the moment a consumer was added, and that a reader who trusts it under-counts the blast
# radius with.
# The "is this a home at all" half — ABSOLUTE, not `/`, and not one of the root's own aliases — is
# applied HERE, in BOTH DERIVED ARMS (step 2's passwd record and step 3's environment guesses), so no
# caller has to re-ask it for a DERIVED home. ⛔ STEP 1 IS NOT GRADED AND THIS SENTENCE DOES NOT COVER IT
# (review cycle-7 #5, measured): an explicit `CELL_HOME` is an operator's answer and is printed verbatim,
# including `/` — that is a recorded decision (`cmux vm exec` may hand `HOME=/home/ubuntu` and an operator
# fixing a box may name a scratch home), so a caller that passes `CELL_HOME` still owns the sanity of the
# value it passes. ⛔ THE VOLATILE-ROOT HALF IS NOT APPLIED, deliberately: see step 2 below.
cell_home_resolve() {
  local v=""
  # 1. explicit override — always wins, even if it is under a volatile root (an operator running a
  #    fixture or a migration on a scratch home must get the home they named, not a correction).
  if [ -n "${CELL_HOME:-}" ]; then
    printf '%s\n' "$CELL_HOME"; return 0
  fi
  # 2. the account's home — the durable answer, and the reason this file exists. ⛔ IT IS GRADED BY THE
  #    PREDICATE THAT DECIDES "IS THIS A HOME AT ALL" — ABSOLUTE, and not the filesystem root — and NOT
  #    by the volatile-root test. Step 3 is a GUESS lifted from the environment, so a volatile guess is
  #    wrong and gets skipped; the passwd record is the box's AUTHORITATIVE answer for its own account,
  #    so substituting the fleet default for a real account home under `/tmp` would answer a directory
  #    that does not exist on that box (measured: 37 arms of `harness-apply-timer.test.sh` pin a fixture
  #    account home under `/tmp`, and every one of them flipped to `/home/cmux` under that reading).
  v="$(cell_home_account_home || true)"
  # ⛔ `/` HAS ALIASES, AND `/?*` ACCEPTS THEM (review P2, measured). `//`, `/.`, `/./` and `/..` all name
  # the filesystem root — POSIX leaves a leading `//` implementation-defined, and Linux resolves it to `/`
  # — so a stubbed passwd record answering any of them walked through the predicate that exists to reject
  # `/`, and the resolver printed it. Every consumer then built `O=<that>/orchestrator` and
  # `SCRIPTS=<that>/.pi/agent/scripts`, i.e. the root walk this file's step-2 note, the guards below it and
  # `refresh-candidates.sh`'s empty-CELL_HOME refusal all exist to prevent — reached by one character.
  # ⛔ THE TEST IS "NAMES NOTHING BUT SEPARATORS AND `.`", NOT A LIST OF SPELLINGS: an enumeration covered
  # `//`, `/.` and `/./` and still missed `/..`, `/../..` and every other spelling of the root. A value that
  # names ANY real component (`/home`, `/.hidden`, `relhome`) falls through to the ABSOLUTE test below,
  # which is what rejects `relhome`. ⛔ "NOTHING BUT SEPARATORS" IS NOT THE WHOLE RULE (review cycle-4 #2,
  # measured): a value with real components can still RESOLVE to the root — `/usr/..`, `/var/log/../..` —
  # and both passed, from step 2 AND step 3, so consumers built `/usr/../orchestrator` = the root walk.
  # Containment in the string is not resolution, so a `..` COMPONENT is refused outright below: no passwd
  # record or HOME meaning a durable home carries one, and normalising here would mean shipping a path
  # resolver in a file whose job is to answer one string.
  # A SEPARATE CASE for each rule, ON PURPOSE: the `/?*` branch is what the `e4` mutant removes, and
  # folding either of these into it would leave that mutation matching nothing (the arm proving nothing).
  case "$v" in */../*|*/..) v="" ;; esac
  case "$v" in
    *[!/.]*) ;;               # names a real component: not the root under any spelling
    *)       v="" ;;          # `/`, `//`, `/.`, `/./`, `/..`, `/../..` — the root, or nothing at all
  esac
  case "$v" in
    /?*) ;;                 # ABSOLUTE and not the filesystem root — the two shapes that are not a home
    *)   v="" ;;
  esac
  if [ -n "$v" ]; then printf '%s\n' "$v"; return 0; fi
  # 3. HOME_ORIG (the pre-override value) then HOME, each only when it is a plausible durable home.
  for v in "${HOME_ORIG:-}" "${HOME:-}"; do
    case "$v" in /*) ;; *) continue ;; esac
    # ⛔ THE ROOT'S ALIASES ARE REJECTED HERE TOO (review N5, measured). Step 3 tested ABSOLUTENESS only,
    # so with an unreadable passwd record and `HOME=//` (or `/.`, `/..`) the resolver printed the root under
    # another name and every consumer built `O=/../orchestrator` — the same walk step 2 rejects. The
    # docstring below claims "the 'is this a home at all' half … is applied HERE, so no caller has to
    # re-ask it": applying it in ONE arm made that sentence false, and a docstring that overstates its
    # own coverage is how the gap survives a reading. Same three rules as step 2 (`..` component, nothing
    # but separators, ABSOLUTE), so the two arms cannot disagree.
    case "$v" in */../*|*/..) continue ;; esac
    case "$v" in *[!/.]*) ;; *) continue ;; esac
    cell_home_under_volatile "$v" && continue
    printf '%s\n' "$v"; return 0
  done
  # 4. the fleet default — the last resort, and the only literal.
  printf '%s\n' "$CELL_HOME_FLEET_DEFAULT"
}

# cell_home_project <home> — the home a value BELONGS to when it is re-based onto <home>.
# Prints the re-based path when <value> is under $CELL_HOME_LEGACY, else prints <value> unchanged.
# This is what the migration uses, so "which paths move" is answered here and not in the rewriter.
cell_home_project() { # <home> <value>
  local home="${1:-}" val="${2:-}"
  [ -n "$home" ] && [ -n "$val" ] || { printf '%s\n' "$val"; return 0; }
  case "$val" in
    "$CELL_HOME_LEGACY") printf '%s\n' "$home" ;;
    "$CELL_HOME_LEGACY"/*) printf '%s\n' "$home${val#"$CELL_HOME_LEGACY"}" ;;
    *) printf '%s\n' "$val" ;;
  esac
}

# cell_home_project_line <home> <line> — the SAME boundary rule, applied to EVERY occurrence inside a
# value that carries several path tokens. This is the projector the migration uses (a unit directive is
# `ExecStart=<path> --state <path> --log <path>`, and a whole line is what has to be re-based).
#
# ⛔ THE BOUNDARY IS THE WHOLE POINT, AND IT IS THE SAME BOUNDARY cell_home_project APPLIES. A naive
# whole-line replace (`${line//$CELL_HOME_LEGACY/$home}`) re-bases `/tmp/cell-home.bak` — an operator's
# pre-migration archive, and the same shape the migration writes as `<file>.pre-cell-home` — to
# `<home>.bak`, a path nobody has. The migration then refused the whole unit and diagnosed a FABRICATED
# target. Only a whole path COMPONENT moves.
#
# ⛔ AND A COMPONENT ENDS AT ANY SEPARATOR, NOT ONLY AT `/` OR THE END OF THE LINE (review F1). The old
# test (`''|/*`) treated EVERY other following character as a continuation of the filename, so a legacy
# path followed by a `"` or a space read as a SIBLING and did not move. Both shapes are ordinary
# systemd, not exotica: `systemd.syntax(7)` says quotes "may be used to wrap a whole item" and that
# "quotes themselves are removed", and `systemd.exec(5)` documents `Environment="VAR1=word1 word2"` —
# so `Environment="HOME=/tmp/cell-home"` sets HOME to the legacy home while the projector called the
# line unchanged, and the scan's record test ("the projection changed this line") saw nothing. That is
# a PASS manufactured from a reading that never happened: `--check` answered 0 (the RECLAIM
# precondition) and `--apply` reported "one home" over a unit it left naming the legacy home.
#
# ⛔ AND THE OCCURRENCE MUST BE A WHOLE PATH TOKEN, AT BOTH ENDS (review F5). The first cut of the fix
# tested only what FOLLOWED the occurrence and treated "not `.`/`-`/`_`/alnum" as a terminator, which is
# not the same thing: `~`, `+`, `#`, `@`, `(`, `!` are all legal filename continuations, so
# `<legacy>~` was rebased to `<durable>~` — a path nobody has. It also never checked what PRECEDED the
# occurrence, so `/opt/tools<legacy>/bin` became `/opt/tools<durable>/bin`, silently rewriting a FOREIGN
# path. So the test is conservative on both sides:
#   * START: the token must start at the beginning of the line, after `=`, whitespace, a quote, or one
#     of `,` `;` `:` `(` — i.e. where a systemd path token really begins;
#   * END: `/` (under the home), end of line, or one of whitespace `"` `'` `,` `;` `:` `)` `]`.
# Anything else is a sibling (`.bak`, `-2`, `~`, `+old`) or a foreign prefix, and does NOT move.
# A colon-separated list still moves token by token: `$LEG/bin:$DUR/bin` is `/`-terminated, and the
# second `$LEG` in `PATH=$LEG:$OTHER` is preceded by `:`.
#
# `${line%%$pat*}` / `${line#*$pat}` are UNQUOTED ON PURPOSE: on bash 3.2 (macOS) a quoted alternative
# inside `${…%%…}` splices the quote characters into the pattern (the same trap the migration records).
# A printf builtin is the producer here, so no pipe exists to SIGPIPE (#841).
cell_home_project_line() { # <home> <line>
  local home="${1:-}" line="${2:-}" pat="$CELL_HOME_LEGACY" out="" head tail probe prev tok end
  [ -n "$home" ] && [ -n "$line" ] || { printf '%s\n' "$line"; return 0; }
  while :; do
    case "$line" in *"$pat"*) ;; *) out="$out$line"; break ;; esac
    head="${line%%$pat*}"        # everything before the FIRST occurrence
    tail="${line#*$pat}"         # everything after that occurrence
    # ⛔ THE OCCURRENCE MUST BE A WHOLE PATH TOKEN — both ends are checked (review F5). Checking only the
    # tail made `/opt/tools<legacy>/bin` rebase a FOREIGN path, and made `<legacy>~`, `<legacy>+old`,
    # `<legacy>#1` (all legal filename continuations that are NOT our home) move, because "not one of
    # `.` `-` `_` alnum" is not the same as "terminates a path". So: the token must START where a path
    # token starts, and END at a separator or the end of the line.
    # ⛔ A RUN OF systemd EXEC PREFIXES BELONGS TO THE TOKEN (review F1). `systemd.service(5)` Table 2:
    # `@`, `-`, `:`, `+`, `!` (and `!!`) may prefix an executable path, in any order and in combination,
    # and `-` is also a documented per-item prefix for `WorkingDirectory=`, `EnvironmentFile=` and
    # `ReadWritePaths=`. Without this, `ExecStart=-<legacy>/run.sh` read as "a sibling or a foreign path"
    # — NO record, `--check` 0 (the reclaim precondition), `--apply` half-migrating the file (the other
    # directives repointed, this one not), and after the reclaim `203/EXEC`. So the prefix run is
    # stripped first and the character BEFORE the run must still start a token: `a-<legacy>/x` is NOT ours.
    probe="$out$head"
    while :; do
      case "$probe" in
        *[-+!@]) probe="${probe%?}" ;;
        *) break ;;
      esac
    done
    prev=""
    if [ -n "$probe" ]; then prev="${probe: -1}"; fi
    tok=0
    case "$prev" in
      '') tok=1 ;;                                   # start of the line
      # `>` `<` `|` `&` begin a REDIRECT or PIPE TARGET, which is a whole path token inside a `sh -c`
      # payload: without them `ExecStartPost=/bin/sh -c "echo x >>/legacy/log"` produced NO record, so
      # `--check` answered 0 over a unit that still named the legacy home (review F4 round 4 — the same
      # fail-open class as the exec prefixes, one character over).
      '='|' '|'	'|'"'|"'"|','|';'|':'|'('|'>'|'<'|'|'|'&') tok=1 ;;  # a value, separator, quote, redirect
    esac
    end=0
    case "$tail" in
      /*) end=1 ;;                                   # under the home: a component boundary
      '') end=1 ;;                                   # end of the line
      *)
        case "${tail:0:1}" in
          [[:space:]]|'"'|"'"|','|';'|':'|')'|']'|\\) end=1 ;;   # …and a continuation ends the ITEM
        esac ;;
    esac
    if [ "$tok" = 1 ] && [ "$end" = 1 ]; then
      out="$out$head$home"
    else
      out="$out$head$pat"                            # a sibling or a foreign path: NOT this home
    fi
    line="$tail"
  done
  printf '%s\n' "$out"
}
