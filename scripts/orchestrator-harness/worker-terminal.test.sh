#!/usr/bin/env bash
# worker-terminal.test.sh — the worker launcher and the controller's portability, driven.
#
# TWO MEASURED FACTS THIS SUITE PINS:
#   1. (2026-10-20, corrected 2026-10-22) A lane launched by the harness produced nothing and its log
#      stopped after ~21 lines. agent-infra#2210 first concluded "never a tmux window" and made the
#      tmux arm macOS-only — which on a Linux cell resolved to `none` and refused EVERY spawn, every
#      cycle. The reopening measured the mechanism: `gh`'s credential is HOME-bound
#      (`$HOME/.config/gh/hosts.yml`) and a tmux worker inherits the tmux SERVER's environment, so a
#      worker with no explicit HOME has no credential and stops at its first `gh` call. So: a spawn
#      must carry the HOME+keys.env contract or be REFUSED (never started credential-less), tmux is
#      the surface where the cmux daemon does not answer — on Linux as well as macOS — and a box with
#      NO surface at all still refuses.
#   2. `orch-loop.sh`'s capacity probes must answer on Linux as well as macOS. agent-infra#1702's
#      portable helpers are already shipped; what was NOT pinned is the macOS SHAPE of the stat probe
#      (`stat -f %m` succeeding while `stat -c %Y` fails) — unreachable on a Linux CI host without a
#      stub, and the shape that decides whether a cell reaps or aborts. Both shapes are driven here.
#
# HOW: the stubs are FILES on PATH (`cmux`, `tmux`, `uname`, `stat`), because the modules under test
# call them by name — so what runs is the real shipped code, not a re-implementation. Every assertion
# reads an ARTIFACT: the surface's recorded argv, the record file, the run script, a log line.
#
# Hermetic: no network, no tmux server, no cmux daemon, no git writes. Run: bash worker-terminal.test.sh
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/worker-terminal.sh"
LOOP="$HERE/orch-loop.sh"
DM="$HERE/dispatch-merge.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── HERMETIC FROM THE BOX'S gh CONFIG DIRECTION (measured on the CI runner, 2026-10-24) ──────
# `gh` resolves its config dir as $GH_CONFIG_DIR, then $XDG_CONFIG_HOME/gh, then $HOME/.config/gh —
# and the shipped `wt_gh_hosts` mirrors that order DELIBERATELY (a one-location probe refuses an
# AUTHENTICATED box, forever: #2396). The consequence for THIS SUITE is not a product bug but a
# hermeticity one: the GitHub runner exports XDG_CONFIG_HOME=/home/runner/.config, so every fixture
# that builds `$fixture_home/.config/gh/hosts.yml` was evaluated against the RUNNER's config instead
# of the fixture's, and 7 unrelated assertions went red (`wt_gh_hosts` answered the runner's path,
# the credential probe refused a provisioned worker, the cleanup then had no session to name).
# One ambient variable cascaded into seven arms, on main and on every PR, so no PR could land.
# The arms that PIN the resolver's precedence still set these per-arm (inline assignment, `env -i`,
# or a subshell), which is exactly why scrubbing them here cannot weaken those assertions.
unset GH_CONFIG_DIR XDG_CONFIG_HOME
PASS=0; FAIL=0
# ⛔ THE SUITE MUST NOT INHERIT AN AMBIENT `CYC` (review round 12 of #2653): the PR made CYC a real
# input to `wt_table` (`WT_ABSENT_STALE_MIN = max(4*CYC, 2*window)`), and `install.sh` renders CYC into
# the controller's environment (floor 5, documented quiet-cell values in the hundreds). Inherited, the
# arms that seed a "600 s old" stamp flip: `CYC=60` → STALE_MIN 240 → the stamp is not stale →
# different verdicts, 4 red. Scrubbed here, like GH_CONFIG_DIR/XDG_CONFIG_HOME above; the arms that
# TEST the knob (q15/q16/q20) set it explicitly.
unset CYC
ck() { # ck <name> <0|1>
  if [ "$2" -eq 0 ]; then printf '  \033[32mPASS\033[0m  %s\n' "$1"; PASS=$((PASS+1));
  else printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAIL=$((FAIL+1)); fi
}
# The scrub above must be ASSERTED, not assumed: a box (or a future runner image, or another lane's
# shell) that repoints gh's config would otherwise re-break seven arms with one variable, and the
# failure would again read as seven unrelated defects. One named assertion, at the top, so the next
# occurrence fails ONCE and says why.
ck "hermetic: the caller's gh config dir is not inherited (GH_CONFIG_DIR/XDG_CONFIG_HOME scrubbed)" \
   "$([ -z "${GH_CONFIG_DIR:-}" ] && [ -z "${XDG_CONFIG_HOME:-}" ] && echo 0 || echo 1)"
# A `hosts.yml` that ACTUALLY carries a token — the only shape `wt_gh_hosts_token` blesses. ⛔ The old
# fixture was `printf 'github.com:\n'` (a host entry and nothing else), which the probe read as
# PROVISIONED: a `gh auth logout`/half-write leftover starts the credential-less worker this gate
# exists to refuse (review finding, 2026-10-23 — a fixture that pins the defect is not a fixture).
gh_hosts_fixture() { # <home>
  mkdir -p "$1/.config/gh"
  printf 'github.com:\n    user: fixture\n    oauth_token: gho_fixture0token\n    git_protocol: https\n' \
    > "$1/.config/gh/hosts.yml"
}

# ── 0) HERMETICITY: the BOX's gh-config redirect is not an input to this suite (#2644) ─────────────
# `wt_gh_hosts` resolves `GH_CONFIG_DIR` → `XDG_CONFIG_HOME` → `$home/.config/gh/hosts.yml`. That order
# is the shipped contract and is pinned below where it belongs. What it is NOT is a property of this
# suite's fixtures: every section here builds its OWN HOME with its OWN hosts.yml, so an AMBIENT value
# silently retargets every credential probe in the file at a directory that belongs to the machine.
#
# MEASURED (2026-10-24, `ci-main` run 40049617028, `189 passed, 7 failed`): the GitHub-hosted runner
# exports `XDG_CONFIG_HOME=/home/runner/.config`, so `wt_spawn` refused a fixture HOME that carried a
# valid `oauth_token` — its refusal message named `/home/runner/.config/gh/hosts.yml` — and seven
# assertions thirty sections apart went red for one reason none of them named. A developer box passed
# only because its shell had no such value (and often has `GH_TOKEN`, which credits several arms
# through the caller-token branch and never reaches the store probe at all). Reproduced 7/7 locally by
# exporting the runner's own value; green with it absent.
#
# ⛔ TWO HALVES, and the second is why this is not just an `unset`. (1) Scrub, so the suite is a
# function of its fixtures and of nothing else. (2) ASSERT the scrub took, as ONE named assertion at
# the top — so a box (or a future edit) that re-introduces a redirect is told WHAT is wrong, instead of
# an unrelated-looking cascade.
#
# ⛔ WHAT THE MUTATION ARM IS, EXACTLY (review cycle 1 — this used to overstate it). Deleting the
# `unset` reddens this assertion ONLY on a box that carries an ambient redirect; on a clean box the
# deletion is invisible, because there is nothing to scrub. That is a property of an ABSENCE and cannot
# be pinned more tightly than "the resolution is correct on the box we are on", so the arm is the
# RUNNER SHAPE: with `XDG_CONFIG_HOME` exported, the scrub-less copy fails here first and names the
# values, and the scrubbed copy passes.
_amb_gh_dir="${GH_CONFIG_DIR:-<unset>}"
_amb_xdg_home="${XDG_CONFIG_HOME:-<unset>}"
unset GH_CONFIG_DIR XDG_CONFIG_HOME
_hermetic_probe="$TMP/hermetic-probe"
_hermetic_hosts="$( set -u; . "$LIB" >/dev/null 2>&1; wt_gh_hosts "$_hermetic_probe" )"
if [ "$_hermetic_hosts" = "$_hermetic_probe/.config/gh/hosts.yml" ]; then
  rc=0
else
  rc=1
  echo "      wt_gh_hosts(\$_hermetic_probe) => '$_hermetic_hosts'"
  echo "      ambient BEFORE the scrub: GH_CONFIG_DIR='$_amb_gh_dir' XDG_CONFIG_HOME='$_amb_xdg_home'"
fi
ck "hermetic: no ambient GH_CONFIG_DIR/XDG_CONFIG_HOME retargets the credential probe" $rc

# ── the fake surface ───────────────────────────────────────────────────────────
# ONE stub, parameterised by env, installed into each scenario's bin dir. It answers the guest CLI's
# grammar (`tree`, `layout apply`, `terminal close`, `workspace rm`) and refuses `surface` exactly as
# the cell's CLI does (`cmux: unknown resource scope "surface"`, measured on cell-3) — unless
# CMUX_HOST=1, which models the Mac host CLI and its `surface` scope.
mkdir -p "$TMP/stub"
cat > "$TMP/stub/cmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "CMUX $*" >> "${CMUX_LOG:-/dev/null}"
if [ "${CMUX_ABSENT:-0}" = "1" ]; then echo "cmux: no daemon from the surface-stub" >&2; exit 1; fi
case "${1:-}" in
  tree)
    # ⛔ AN ABSENT SESSION OWNER: no stdout, a transport error ON STDERR, non-zero rc. This is the
    # measured shape of the live cell on 2026-10-24 (`cannot connect to session socket …: Connection
    # refused (os error 111)`) and it is a READING, not an unreadable census (agent-infra#2653).
    [ "${CMUX_TREE_ABSENT:-0}" = "1" ] && { printf '%s\n' "${CMUX_TREE_ABSENT_MSG:-cannot connect to session socket /tmp/cmux-tui-1000/cloud.sock: Connection refused (os error 111)}" >&2; exit 3; }
    # A daemon that dies WITHOUT a word: the case where a bare verdict is least usable, so the reason
    # must fall back to the exit status rather than printing an empty cause.
    [ "${CMUX_TREE_SILENT:-0}" = "1" ] && { exit 7; }
    # FAIL-ONCE: the FIRST call fails and every later one answers — the probe-flip shape (the launcher's
    # read fails, the reason's read succeeds). Reachable only through that race, so it is driven here.
    if [ -n "${CMUX_FAIL_ONCE:-}" ]; then
      if [ -f "$CMUX_FAIL_ONCE" ]; then rm -f "$CMUX_FAIL_ONCE"; else : > "$CMUX_FAIL_ONCE"; echo "cmux: transient probe failure" >&2; exit 1; fi
    fi
    [ "${CMUX_TREE_FAIL:-0}" = "1" ] && { echo "cmux: cannot read" >&2; exit 1; }
    # A SEQUENCED tree: the daemon answers differently on the nth call (a close is verified against a
    # SECOND read). `$CMUX_TREE_SEQ.1`, `.2`, … with `.last` as the fallback.
    if [ -n "${CMUX_TREE_SEQ:-}" ]; then
      _n=$(cat "$CMUX_TREE_SEQ.n" 2>/dev/null || echo 0); _n=$((_n+1)); printf '%s\n' "$_n" > "$CMUX_TREE_SEQ.n"
      for _f in "$CMUX_TREE_SEQ.$_n" "$CMUX_TREE_SEQ.last"; do
        [ -f "$_f" ] && { cat "$_f"; exit 0; }
      done
      echo "cmux: no such sequence step" >&2; exit 1
    fi
    # A RAW answer, byte for byte (a banner line, a drifted shape — anything the parser may refuse).
    [ -n "${CMUX_TREE_RAW:-}" ] && { printf '%s\n' "$CMUX_TREE_RAW"; exit 0; }
    # ⛔ NOT `${CMUX_TREE_JSON:-{...}}`: brace nesting inside that expansion makes bash emit the
    # value PLUS a literal `}` — a stub bug that turns valid JSON into `Extra data` and reads as
    # "the census saw nothing", i.e. every worker dead. Measured here before it was fixed.
    if [ -n "${CMUX_TREE_JSON:-}" ]; then printf '%s\n' "$CMUX_TREE_JSON"
    else printf '%s\n' '{"workspaces":[],"screens":[],"tabs":[],"terminals":[]}'; fi
    # ⛔ A REPLY THAT IS JSON **AND** EXITS NON-ZERO: not a reading (the writable capture branch
    # discards it with `|| tree=""`), so the fallback must not trust it either (review round 7).
    [ -n "${CMUX_TREE_JSON_RC:-}" ] && exit "$CMUX_TREE_JSON_RC"
    ;;
  surface)
    [ "${CMUX_HOST:-0}" = "1" ] || { echo 'cmux: unknown resource scope "surface"' >&2; exit 1; }
    if [ "${2:-}" = "ls" ]; then exit 0; fi
    if [ "${2:-}" = "new-terminal" ]; then printf 'surface:term_host42\n'; exit 0; fi
    ;;
  layout)
    # ⛔ FAIL-ONCE, and WITH A CHOSEN MESSAGE (agent-infra#2404). The measured refusal carried the
    # daemon's own JSON (`"reason":"database or disk is full"`); an arm that can only make the create
    # fail cannot drive the message this change exists to stop relaying.
    if [ -n "${CMUX_LAYOUT_FAIL_ONCE:-}" ]; then
      if [ -f "$CMUX_LAYOUT_FAIL_ONCE" ]; then rm -f "$CMUX_LAYOUT_FAIL_ONCE"; else : > "$CMUX_LAYOUT_FAIL_ONCE"; printf '%s\n' "${CMUX_LAYOUT_MSG:-cmux: layout apply failed}" >&2; exit "${CMUX_LAYOUT_RC:-1}"; fi
    fi
    [ "${CMUX_LAYOUT_RC:-0}" = "0" ] || { printf '%s\n' "${CMUX_LAYOUT_MSG:-cmux: layout apply failed}" >&2; exit "${CMUX_LAYOUT_RC}"; }
    cat >/dev/null 2>&1 || true          # the layout document arrives on stdin
    if [ "${CMUX_NO_ID:-0}" = "1" ]; then printf '{"warnings": []}\n'; exit 0; fi
    # a workspace with NO terminal id: the create half-succeeded, so the refusal must undo it
    if [ "${CMUX_NO_ID_WS:-0}" = "1" ]; then printf '{"workspace_id": "ws_half9"}\n'; exit 0; fi
    printf '{"workspace_id": "ws_%s", "panes": [{"surfaces": [{"terminal_id": "term_%s"}]}]}\n' \
      "${CMUX_WS_SUFFIX:-x}" "${CMUX_WS_SUFFIX:-x}"
    ;;
  server)
    # ⛔ THE GUEST CLI'S `server` VERBS — and the macOS host CLI's ABSENCE of them, which is the other
    # half of the contract: `cmux server --help` answers `Error: Unknown command 'server'` on this
    # controller (measured 2026-10-28), so a probe that treated that as "the session is down" would
    # name an outage on every Mac spawn that failed for any reason.
    [ "${CMUX_SERVER_UNSUPPORTED:-0}" = "1" ] && { echo "Error: Unknown command 'server'. Run 'cmux --help' for the full command list." >&2; exit 1; }
    case "${2:-}" in
      status)
        [ -n "${CMUX_SERVER_STATUS:-}" ] || { echo "cannot connect to the local server" >&2; exit 1; }
        printf '%s\n' "$CMUX_SERVER_STATUS"; exit "${CMUX_SERVER_STATUS_RC:-0}" ;;
      ensure)
        printf '%s\n' "ENSURE $*" >> "${CMUX_ENSURE_LOG:-/dev/null}"
        # FAIL-ONCE models the measured flake on cell-3: `ensure` failed once and succeeded on retry.
        if [ -n "${CMUX_ENSURE_FAIL_ONCE:-}" ]; then
          if [ -f "$CMUX_ENSURE_FAIL_ONCE" ]; then rm -f "$CMUX_ENSURE_FAIL_ONCE"; else : > "$CMUX_ENSURE_FAIL_ONCE"; echo 'the detached session owner did not become ready' >&2; exit 1; fi
        fi
        exit "${CMUX_ENSURE_RC:-0}" ;;
      *) exit 0 ;;
    esac
    ;;
  terminal)
    [ "${2:-}" = "close" ] && printf '%s\n' "${3:-}" >> "${CMUX_CLOSED:-/dev/null}"
    ;;
  workspace) : ;;
esac
exit 0
SH
chmod +x "$TMP/stub/cmux"
# The tmux side: a session list and a spawn/kill recorder. A test that a spawn did NOT reach tmux is
# only meaningful because this stub WOULD have recorded it.
cat > "$TMP/stub/tmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "TMUX $*" >> "${TMUX_LOG:-/dev/null}"
# ⛔ EACH ARGUMENT ON ITS OWN LINE. `$*` FLATTENS the argv, so `bash -c 'LINE'` and
# `bash -c "'LINE'"` log IDENTICALLY — which is how a spawn-127 regression passed this suite
# (2026-10-23). Pins that care about the SHAPE count these instead of grepping the flattened line.
for _a in "$@"; do printf 'ARGV %s\n' "$_a" >> "${TMUX_LOG:-/dev/null}"; done
# The session list lives in a FILE because `kill-session` must actually remove the session: a stub
# that only records the kill would leave the list intact, and a close that is VERIFIED against it
# could never be observed to succeed — the assertion would pass for the wrong reason.
st="${TMUX_STATE:-}"
# ⛔ A SERVER IS NOT A SESSION LIST (review finding, measured on tmux 3.4 2026-10-23). A LIVE server
# with ZERO sessions (`exit-empty off`) answers `tmux ls` with rc 0 and an EMPTY list; a socket that was
# never created answers with its own error. The production code tells those apart with a
# `show-environment -g` probe, so this stub must be able to EXPRESS both — a stub that reports "no
# sessions" and "no server" with the same bytes lets a pin pass for a state real tmux never reports.
#   TMUX_SERVER_EXISTS=1  a server answers even with no session recorded (zero-session server)
#   TMUX_SERVER_EXISTS=0  no server at all
#   unset                 a server exists iff a session is recorded (the ordinary fixture)
srv() {
  case "${TMUX_SERVER_EXISTS:-}" in
    1) return 0 ;;
    0) return 1 ;;
  esac
  [ -n "$st" ] && [ -s "$st" ]
}
# ⛔ FAITHFUL TO tmux 3.4 (review finding, 2026-10-23, MEASURED): a box that has NEVER started a
# server answers `no server running on <socket>` (rc 1). The `error connecting to … (No such file or
# directory)` wording is a DIFFERENT state — the socket file having been unlinked out from under a
# server that is still running — and modelling absence with it made the census's most dangerous state
# look like its most ordinary one (see section K).
noserver() { echo "no server running on /tmp/tmux-501/default"; }
case "${1:-}" in
  ls) if [ "${TMUX_LS_UNLINKED:-0}" = "1" ]; then
        # The socket FILE was removed under a LIVE server: tmux 3.4 answers exactly this, rc 1, while
        # the session's processes keep running (measured on a real server, 2026-10-23).
        echo "error connecting to /tmp/tmux-501/default (No such file or directory)"; exit 1
      fi
      if [ "${TMUX_LS_FAIL:-0}" = "1" ]; then
        # tmux's own UNREADABLE-socket answer, and deliberately NOT the "No such file" wording above:
        # a broken socket must stay distinguishable from a box that never started a server, because
        # the code treats them differently (unreadable = UNKNOWN/fail-closed, absent = EMPTY/positive).
        echo "error connecting to /tmp/tmux-501/default (Permission denied)"; exit 1
      fi
      srv || { noserver; exit 1; }
      [ -n "$st" ] && [ -f "$st" ] && sed '/^$/d' "$st" ;;
  # ⛔ a pid that CANNOT exist (above pid_max): `wt_close` really does `kill -TERM`/`-KILL` it, and a
  # plausible number here signalled whatever unrelated process happened to own it during a test run.
  list-panes) printf '%s\n' "${TMUX_PANE_PID:-4194305}" ;;
  new-session) [ "${TMUX_LS_FAIL:-0}" = "1" ] && exit 1   # an unreadable socket cannot start a session
               [ "${TMUX_SPAWN_RC:-0}" = "0" ]; [ -n "$st" ] && printf '%s\n' "${4#=}" >> "$st" ;;
  # `tmux show-environment -g <name>` — the SERVER-environment credential probe `wt_launcher_env`
  # uses when a worker's HOME carries no credential file. Faithful: tmux exits 1 with
  # `unknown variable` when the name is not set (a different answer from an empty value, which it
  # prints as `NAME=`), and both names are probed because gh honours GITHUB_TOKEN too.
  show-environment) if [ "${TMUX_SERVER_SLOW:-0}" = "1" ]; then
                      # A server that is REACHABLE BUT DOES NOT ANSWER — the state the bound exists for
                      # (measured on tmux 3.4: a wedged server blocks `show-environment` indefinitely).
                      sleep 3; exit 1
                    fi
                    if [ -z "${3:-}" ]; then
                      # `tmux show-environment -g` with NO name — the SERVER-existence probe
                      # (`wt_tmux_has_server`). Faithful: a live server answers rc 0 even with ZERO
                      # sessions; a socket that was never created answers with tmux's own error, rc 1.
                      srv || { noserver; exit 1; }
                      echo "PATH=/usr/bin:/bin"
                      exit 0
                    fi
                    if [ "${3:-}" = "GH_TOKEN" ] || [ "${3:-}" = "GITHUB_TOKEN" ]; then
                      if [ "${3:-}" = "GITHUB_TOKEN" ] && [ "${TMUX_SERVER_GH_TOKEN:-0}" != "1" ]; then
                        echo "unknown variable: GITHUB_TOKEN"; exit 1
                      fi
                      [ "${TMUX_SERVER_GH_TOKEN:-0}" = "1" ] && { printf 'GH_TOKEN=%s\n' "${TMUX_SERVER_TOKEN_VAL-ghp_test}"; exit 0; }
                      echo "unknown variable: ${3:-}"; exit 1
                    fi ;;
  # The LOG keeps the target VERBATIM (the `=` prefix is the assertion); the STATE file needs the
  # bare name so membership still matches.
  # ⛔ REAL tmux SEMANTICS, BOTH HALVES (review finding, 2026-10-23, MEASURED): `-t NAME` is a PREFIX
  # match (a real `tmux kill-session -t fix-8` really kills `fix-82`), `-t =NAME` is EXACT. The stub
  # used to remove by exact membership for BOTH shapes, so a pin asserting "a peer session whose name
  # extends ours survives" could not fail — the stub had no prefix behaviour to get wrong, and the
  # assertion passed for the wrong reason.
  kill-session) printf '%s\n' "${3:-}" >> "${TMUX_KILLED:-/dev/null}"
                tgt="${3:-}"
                [ -n "$st" ] && [ -f "$st" ] || exit 0
                case "$tgt" in
                  =*) grep -vx -- "${tgt#=}" "$st" > "$st.n" ;;
                  *)  awk -v p="$tgt" 'index($0, p) != 1' "$st" > "$st.n" ;;
                esac
                mv "$st.n" "$st" ;;
esac
exit 0
SH
chmod +x "$TMP/stub/tmux"
cat > "$TMP/stub/uname" <<'SH'
#!/usr/bin/env bash
echo "${FAKE_UNAME:-Linux}"
SH
chmod +x "$TMP/stub/uname"
# A plaintext-store `gh` — the shape CI's ubuntu runner has. It answers from the SAME hosts.yml the
# shipped code reads (GH_CONFIG_DIR, then XDG, then $HOME/.config/gh) and NEVER from the machine's own
# store, so a fixture HOME's answer is a property of the fixture on every platform.
cat > "$TMP/stub/gh" <<'SH'
#!/usr/bin/env bash
h="${GH_CONFIG_DIR:-${XDG_CONFIG_HOME:+$XDG_CONFIG_HOME/gh}}"; h="${h:-$HOME/.config/gh}"
f="$h/hosts.yml"
case "${1:-} ${2:-}" in
  "auth token")
    [ -f "$f" ] || exit 1
    while IFS= read -r l; do
      case "$l" in *oauth_token:*) : ;; *) continue ;; esac
      v="${l#*oauth_token:}"
      v="${v#"${v%%[![:space:]]*}"}"
      case "$v" in ''|'#'*) continue ;; esac
      v="${v#\"}"; v="${v%\"}"; v="${v#\'}"; v="${v%\'}"
      case "$v" in *[![:space:]]*) printf '%s\n' "$v"; exit 0 ;; esac
    done < "$f"
    exit 1 ;;
  "auth status")
    grep -q 'oauth_token:' "$f" 2>/dev/null && exit 0 || exit 1 ;;
esac
exit 1
SH
chmod +x "$TMP/stub/gh"
# scenario <name> — a bin dir whose stubs are the ones above (first on PATH, so they shadow the real
# cmux/uname/tmux a developer box or a cell may have).
# ⛔ AND A HERMETIC `gh` (review finding, 2026-10-23): without one, every REFUSED leg asks whatever gh
# the MACHINE has, and gh's default store is the system keychain, which answers for a HOME it was never
# pointed at — 34 pins then red on the maintainer's macOS box on an unchanged tree while CI (plaintext
# store) was green. The stub models the plaintext store off the SAME hosts.yml the code reads.
scenario() { mkdir -p "$TMP/bin-$1"; cp "$TMP/stub/cmux" "$TMP/stub/tmux" "$TMP/stub/uname" "$TMP/stub/gh" "$TMP/bin-$1/"; }
scenario cmux; scenario absent; scenario darwin; scenario host
# A box with NO surface at all: cmux cannot answer AND there is no tmux binary. `PATH` for this one is
# the scenario dir ALONE (no `:$PATH`), or the real /usr/bin/tmux a developer box carries would be
# found and the case could never be driven.
scenario bare; rm -f "$TMP/bin-bare/tmux"
# ⛔ THE STUBS ARE `#!/usr/bin/env bash`, so a scenario whose PATH is this dir ALONE still needs the
# interpreter and the utilities the module actually calls — symlinked in (the `storenogh` pattern
# below) — or every stub dies 127 and the box looks surface-less for the WRONG reason. `tmux` stays
# ABSENT deliberately: this box's whole purpose is the no-surface state, and the real /usr/bin/tmux a
# dev box carries must not be reachable.
for _u in bash env tr cut sed cat grep date mkdir rm ln; do
  [ -e "$TMP/bin-bare/$_u" ] || { _p="$(command -v "$_u" 2>/dev/null)" && ln -sf "$_p" "$TMP/bin-bare/$_u"; }
done
# A box whose `gh` cannot answer (absent, or a broken install): `scenario` copies the cmux/tmux/uname
# stubs so only `gh` differs. The credential-contract pins below need it — a hosts.yml credit is only
# usable if the worker's OWN `gh` can read the store, and that is the arm a session-start cannot see.
scenario nogh
printf '#!/usr/bin/env bash\nexit 1\n' > "$TMP/bin-nogh/gh"; chmod +x "$TMP/bin-nogh/gh"
# …and the positive control: a `gh` that ANSWERS a token (offline — this suite makes no network call),
# so the refusal below is a real probe of the environment, not a blanket ban on a store credit.
scenario ghtok
printf '#!/usr/bin/env bash\nprintf %%s\\n gho_stubtoken\n' > "$TMP/bin-ghtok/gh"; chmod +x "$TMP/bin-ghtok/gh"
# A box with NO `gh` AT ALL — the grader is driven with `PATH` set to this dir ALONE, because a
# `:$PATH` suffix would find the real /usr/bin/gh and the arm could never be reached. Only the
# utilities the prefix itself calls are linked in, so "no gh" means no gh.
scenario storenogh
for _u in bash env grep mkdir date rm sed cat; do
  _p="$(command -v "$_u" 2>/dev/null)" && ln -sf "$_p" "$TMP/bin-storenogh/$_u"
done

# lib <scenario> <O> — a shell with the SHIPPED library sourced and nothing else set up.
librun() { # librun <dir-name> <script-text...>
  local d="$1"; shift
  ( set -u
    PATH="$TMP/bin-$d:$PATH"
    O="$2"; WT_DIR="$O/state"; WT_TABLE_TTL=0; mkdir -p "$WT_DIR"
    # shellcheck disable=SC1090
    . "$LIB" )
}

echo
echo "── A) the shipped launchers do not start a worker with a bare detached process ──"
# ⛔ THE GREPS BELOW ARE ON THE SHIPPED FILES, and they are NON-VACUOUS: a synthetic file carrying
# each banned shape is fed through the same predicates at the end of this block.
n_spawn="$(grep -c 'tmux new-session' "$LOOP" "$DM" 2>/dev/null | awk -F: '{s+=$2} END{print s+0}')"
[ "$n_spawn" = "0" ] && rc=0 || rc=1
ck "orch-loop.sh and dispatch-merge.sh contain NO \`tmux new-session\` worker spawn (found $n_spawn)" $rc
n_detach="$(grep -cE '(setsid|nohup)[^#]*\bpi\b' "$LOOP" "$DM" 2>/dev/null | awk -F: '{s+=$2} END{print s+0}')"
[ "$n_detach" = "0" ] && rc=0 || rc=1
ck "…and no \`setsid\`/\`nohup\` pi spawn (the transient-exec shape that dies at ~21 lines)" $rc
# The tmux branch still exists, but only inside the launcher module, and it is NOT gated on Darwin:
# agent-infra#2210's Linux refusal made the launcher resolve to `none` on every cloud cell, where the
# guest cmux CLI cannot run at all — so the controller refused every spawn, every cycle, forever.
# Measured 2026-10-22: with the environment contract (HOME + keys.env) a tmux worker on that box ran
# 50 lines with `gh auth status` rc=0, against 7 lines without it. So the gate is "is there a tmux
# binary", not "is this Darwin" — and the ENVIRONMENT is now the thing that is checked.
n_lib="$(grep 'tmux new-session' "$LIB" | grep -vc '^[[:space:]]*#')"
[ "$n_lib" = "1" ] && rc=0 || rc=1
ck "the ONE remaining tmux spawn lives in worker-terminal.sh (found $n_lib, comments excluded)" $rc
grep -q 'elif command -v tmux >/dev/null 2>&1; then' "$LIB" && rc=0 || rc=1
ck "…and the tmux arm is selected by TMUX PRESENCE, not by uname=Darwin (reachable on Linux)" $rc
grep -qE 'elif.*uname.*Darwin.*tmux' "$LIB" && rc=1 || rc=0
ck "…the old Darwin-only condition is GONE (a Linux cell with tmux must not resolve to none)" $rc
# Both launchers must source the module AND validate EVERY verb they call (a narrower guard passes a
# module that is present but partial, and the controller then logs `launcher=` and a false 0 workers).
for f in "$LOOP" "$DM"; do
  rc=0
  grep -q 'worker-terminal.sh' "$f" || rc=1
  grep -q 'for _wt_v in wt_spawn' "$f" || rc=1
  grep -q 'command -v "$_wt_v"' "$f" || rc=1
  # ⛔ AN EXACT LIST, not a substring. `grep -q 'wt_close wt_launcher'` was satisfied by
  # `… wt_close wt_launcher wt_count`, so it stayed green when the list grew a verb a caller needed
  # (dispatch-merge.sh's `wt_spawn` calls `wt_launcher_why`, and its guard omitted it — a module with
  # the new `wt_spawn` and no helper then logged `— why: ` EMPTY, the exact #2366 defect).
  # Each controller's list is asserted EXACTLY as shipped (they differ: orch-loop also calls
  # `wt_startup_banner` and `wt_table`), so adding a verb to a caller without adding it here reds this.
  case "$f" in
    "$LOOP") want='for _wt_v in wt_spawn wt_alive wt_count wt_close wt_launcher wt_launcher_why wt_startup_banner wt_table; do' ;;
    "$DM")   want='for _wt_v in wt_spawn wt_alive wt_close wt_launcher wt_launcher_why wt_count; do' ;;
    *)       want='__never__' ;;
  esac
  grep -qF "$want" "$f" || rc=1
  [ "$rc" -eq 0 ] || break
done
ck "…and both launchers source it and REFUSE to run without EVERY verb they call" $rc
# NON-VACUITY: the predicates must fire on a planted shape, or they prove nothing about the files.
printf 'tmux new-session -d -s "lane-1" "pi -p x"\nsetsid nohup pi -p y\n' > "$TMP/planted.sh"
grep -q 'tmux new-session' "$TMP/planted.sh" && grep -qE '(setsid|nohup)[^#]*\bpi\b' "$TMP/planted.sh" && rc=0 || rc=1
ck "non-vacuity: the banned-shape predicates DO fire on a planted spawn" $rc

echo
echo "── B) a spawn is a DURABLE TERMINAL, and a failed one leaves nothing behind ──"
cat > "$TMP/b1.sh" <<'SH'
set -u
PATH="$2:$PATH"; O="$3"; WT_DIR="$O/state"; WT_TABLE_TTL=0; mkdir -p "$WT_DIR"
# exported: the stubs are CHILD PROCESSES, so a plain assignment would be invisible to them —
# and every assertion below about a stub ("it was never called") would pass vacuously.
export CMUX_LOG="$4"; : > "$CMUX_LOG"
. "$1"
echo "launcher=$(wt_launcher) grammar=$(wt_grammar)"
wt_spawn "lane-7" "/tmp" 'bash /tmp/lane.sh 7 feat/7-tm owner/repo'; echo "rc=$?"
SH
out="$(bash "$TMP/b1.sh" "$LIB" "$TMP/bin-cmux" "$TMP/O1" "$TMP/cmux1.log" 2>&1)"
case "$out" in *"launcher=terminal"*) rc=0 ;; *) rc=1; echo "      $out";; esac
ck "a cmux surface selects the durable-terminal launcher" $rc
case "$out" in *"rc=0"*) rc=0 ;; *) rc=1;; esac
ck "…and the spawn succeeds" $rc
grep -q 'layout apply --name wt-lane-7 --cwd /tmp' "$TMP/cmux1.log" && rc=0 || rc=1
ck "…by asking the daemon for a terminal surface named wt-<worker> in the worker's cwd" $rc
grep -qx 'kind=terminal' "$TMP/O1/state/worker-lane-7" && rc=0 || rc=1
ck "…and recording the terminal so the reaper can find it" $rc
[ -x "$TMP/O1/state/run-lane-7.sh" ] && rc=0 || rc=1
ck "…with an executable run script (the exact command, readable by an operator)" $rc
grep -qF "bash /tmp/lane.sh 7 feat/7-tm owner/repo" "$TMP/O1/state/run-lane-7.sh" && rc=0 || rc=1
ck "…that carries the caller's command verbatim" $rc
[ "$(stat -c '%a' "$TMP/O1/state/env-lane-7.sh" 2>/dev/null || stat -f '%Lp' "$TMP/O1/state/env-lane-7.sh")" = "600" ] && rc=0 || rc=1
ck "the env snapshot (the keys the terminal does NOT inherit) is written 0600" $rc
grep -q '^export O=' "$TMP/O1/state/env-lane-7.sh" && rc=0 || rc=1
ck "…and it carries O, which a durable terminal would otherwise lose" $rc
# A failed create must NOT look like a worker: no record, no run script, non-zero rc.
rm -rf "$TMP/O2"; CMUX_LAYOUT_RC=1 bash "$TMP/b1.sh" "$LIB" "$TMP/bin-cmux" "$TMP/O2" "$TMP/cmux2.log" >"$TMP/b2.out" 2>&1
grep -q 'rc=1' "$TMP/b2.out" && [ ! -f "$TMP/O2/state/worker-lane-7" ] && rc=0 || { rc=1; cat "$TMP/b2.out"; }
ck "a create that FAILS returns non-zero and records NO worker (no phantom)" $rc
grep -q 'REFUSED lane-7' "$TMP/b2.out" && rc=0 || rc=1
ck "…and says why, naming the worker" $rc
# A create that succeeds but prints no id is a terminal nobody can reap — treated as a failure.
rm -rf "$TMP/O3"; CMUX_NO_ID=1 bash "$TMP/b1.sh" "$LIB" "$TMP/bin-cmux" "$TMP/O3" "$TMP/cmux3.log" >"$TMP/b3.out" 2>&1
grep -q 'rc=1' "$TMP/b3.out" && [ ! -f "$TMP/O3/state/worker-lane-7" ] && rc=0 || { rc=1; cat "$TMP/b3.out"; }
ck "a terminal with NO readable id is refused (an untrackable worker cannot be reaped)" $rc
# …and the HALF-CREATED workspace is undone, not leaked: a create that returns a workspace but no
# terminal leaves an unowned surface behind, and nothing could ever close it (no record, no id).
rm -rf "$TMP/O3b"; CMUX_NO_ID_WS=1 bash "$TMP/b1.sh" "$LIB" "$TMP/bin-cmux" "$TMP/O3b" "$TMP/cmux3b.log" >"$TMP/b3b.out" 2>&1
grep -q 'CMUX workspace rm ws_half9' "$TMP/cmux3b.log" && rc=0 || { rc=1; cat "$TMP/cmux3b.log"; }
ck "…and the workspace that create had already made is REMOVED, not leaked" $rc

echo
echo "── C) a Linux box with no cmux answer uses TMUX, with the environment contract (agent-infra#2210 reopened) ──"
# ⛔ THE PREDICATE THIS BLOCK REPLACES made a Linux cell resolve to `none`, so the controller refused
# EVERY spawn every cycle (`[startup] worker launcher=none (cmux=yes, uname=Linux)` then
# `#9544 re-record spawn FAILED`), and nothing landed without a human. The reason recorded for it was
# a ~21-line worker death — which is an ENVIRONMENT failure, measured 2026-10-22 on cell-1: against
# ONE bare tmux server, `cd CWD && CMD` gave 7 lines and `gh auth status` rc=1 (`You are not logged
# into any GitHub hosts`), while adding `export HOME=/tmp/cell-home; . $HOME/keys.env` gave 50 lines
# and rc=0. So: tmux IS the Linux surface, and the spawn must carry HOME + keys.env or be refused.
gh_hosts_fixture "$TMP/home-c"   # a hosts.yml that CARRIES A TOKEN: presence is not provision
printf 'export GH_TOKEN=%s\n' "ghp_from_keys_env" > "$TMP/home-c/keys.env"
cat > "$TMP/c1.sh" <<'SH'
set -u
PATH="$2:$PATH"; O="$3"; WT_DIR="$O/state"; WT_TABLE_TTL=0; LOG="$O/test.log"; mkdir -p "$WT_DIR"
export CMUX_ABSENT=1 TMUX_LOG="$4" WT_WORKER_HOME="$5" CMUX_LOG="$O/cmux-calls.log"; : > "$TMUX_LOG"; : > "$CMUX_LOG"
. "$1"
# The REAL startup emitter (worker-terminal.sh::wt_startup_banner), captured on its own so a matching
# reason further down this capture cannot satisfy it — the previous version of this assertion was
# VACUOUS for exactly that reason (it matched the REFUSED line below and passed with the startup half
# deleted). `> $O/banner.txt` keeps the two artifacts separate.
wt_startup_banner > "$O/banner.txt" 2>/dev/null
cat "$O/banner.txt"
wt_spawn "lane-8" "/tmp" 'bash /tmp/lane.sh 8 b o/r'; echo "rc=$?"
SH
out="$(FAKE_UNAME=Linux bash "$TMP/c1.sh" "$LIB" "$TMP/bin-absent" "$TMP/O4" "$TMP/tmux4.log" "$TMP/home-c" 2>&1)"
case "$out" in *"launcher=tmux"*) rc=0 ;; *) rc=1; echo "      $out";; esac
ck "no cmux answer + Linux + tmux => launcher=tmux (NOT none: there is a surface)" $rc
case "$out" in *"rc=0"*) rc=0 ;; *) rc=1; echo "      $out";; esac
ck "…and the spawn SUCCEEDS" $rc
grep -q 'TMUX new-session -d -s lane-8' "$TMP/tmux4.log" && rc=0 || { rc=1; cat "$TMP/tmux4.log"; }
ck "…by starting a tmux session, as a worker that can actually run" $rc
# ⛔ The line now runs under `bash -c '<whole line>'` (the spawn pins the SOURCING shell, so the
# pre-check's dialect and the runtime's dialect are the same one), so the log carries inner single
# quotes escaped as `'\''`. Un-escape before asserting: these pins are about WHAT the line does.
unesc() { sed "s/'\\\\''/'/g" "$1"; }
unesc "$TMP/tmux4.log" | grep -qF "export HOME='$TMP/home-c'" && rc=0 || { rc=1; cat "$TMP/tmux4.log"; }
ck "…whose launch line exports the HOME that holds the gh credential (the credential is HOME-bound)" $rc
unesc "$TMP/tmux4.log" | grep -qF ". '$TMP/home-c/keys.env'" && rc=0 || { rc=1; cat "$TMP/tmux4.log"; }
ck "…and sources that HOME's keys.env, exactly like the cell's working manual dispatch" $rc
# ⛔ SOURCED UNDER `set -a` — the supervisor's own idiom (`set -a; . "$ENV_FILE"; set +a`). A keys.env
# that ASSIGNS without `export` is legal there, and a worker that sourced it plainly would keep those
# values in its own launch shell and hand the lane it starts nothing: the credential-less worker this
# gate removes, one layer lower. Driven for real — the prefix is EXECUTED and `env` is read back.
gh_hosts_fixture "$TMP/home-plain"
printf 'CELLPLAIN=plainvalue\n' > "$TMP/home-plain/keys.env"
cat > "$TMP/c5.sh" <<'SH'
set -u
PATH="$2:$PATH"; O="$3"; WT_DIR="$O/state"; WT_TABLE_TTL=0; mkdir -p "$WT_DIR"
. "$1"
printf 'PFX<<%s>>\n' "$(wt_launcher_env "$4")"
SH
out="$(bash "$TMP/c5.sh" "$LIB" "$TMP/bin-absent" "$TMP/O4k" "$TMP/home-plain" 2>&1)"
pfx="$(printf '%s\n' "$out" | sed -n 's/^PFX<<\(.*\)>>$/\1/p')"
seen="$(env -i PATH=/usr/bin:/bin O="$TMP/O4k" "$BASH" -c "$pfx; env" 2>/dev/null | grep -c '^CELLPLAIN=plainvalue$')"
[ "$seen" = "1" ] && rc=0 || { rc=1; echo "      prefix=$pfx"; }
ck "a keys.env that assigns WITHOUT export still reaches the worker (sourced under set -a)" $rc
grep -q '^kind=tmux' "$TMP/O4/state/worker-lane-8" && grep -q '^home=' "$TMP/O4/state/worker-lane-8" && rc=0 || rc=1
ck "…and records the worker AND the HOME it was given, so an operator can audit it" $rc
# ⛔ THE LOUD HALF: a tmux spawn whose worker would have NO credential is refused, not started.
# A credential-less lane is the ~21-line death: it burns its dispatch and produces nothing, which looks
# exactly like the launcher killing it.
rm -rf "$TMP/O4b"; mkdir -p "$TMP/home-nocred"
cat > "$TMP/c2.sh" <<'SH'
set -u
PATH="$2:$PATH"; O="$3"; WT_DIR="$O/state"; WT_TABLE_TTL=0; LOG="$O/test.log"; mkdir -p "$WT_DIR"
export CMUX_ABSENT=1 TMUX_LOG="$4" WT_WORKER_HOME="$5" TMUX_SERVER_GH_TOKEN="${TMUX_SERVER_GH_TOKEN:-0}"; : > "$TMUX_LOG"
# The CALLER's own token is a credential source now (see wt_launcher_env), so a test of the REFUSAL
# must clear it — otherwise this driver passes on a lane box and fails on a clean one, for a reason
# that has nothing to do with what it asserts. The caller-token case sets it back deliberately.
[ "${KEEP_CALLER_TOKEN:-0}" = "1" ] || unset GH_TOKEN GITHUB_TOKEN
# `CALLER_UNEXPORTED=1`: the name is a SHELL VARIABLE, not in the environment — a tmux client never
# carries it, so crediting it would bless a dead lane (review finding, 2026-10-23, measured). The unset
# is REQUIRED here: this suite inherits the lane's own exported GH_TOKEN, and an assignment to an
# already-exported name keeps the export attribute, which would make the fixture look exported.
if [ "${CALLER_UNEXPORTED:-0}" = "1" ]; then unset GH_TOKEN GITHUB_TOKEN; GH_TOKEN=ghp_shell_only; fi
. "$1"
wt_spawn "lane-8" "/tmp" 'bash /tmp/lane.sh 8 b o/r'; echo "rc=$?"
SH
out="$(FAKE_UNAME=Linux bash "$TMP/c2.sh" "$LIB" "$TMP/bin-absent" "$TMP/O4b" "$TMP/tmux4b.log" "$TMP/home-nocred" 2>&1)"
case "$out" in *"rc=1"*) rc=0 ;; *) rc=1; echo "      $out";; esac
ck "a worker that would start with NO gh credential is REFUSED (loud, not a silent dead lane)" $rc
grep -q 'new-session' "$TMP/tmux4b.log" && rc=1 || rc=0
ck "…and tmux is never asked to START one (the credential probe is the only call it makes)" $rc
# ⛔ THE MESSAGE MUST NOT NAME A CAUSE THE GATE DID NOT ESTABLISH (2026-10-27). This assertion used to
# pin `NO gh credential`, which was a FALSE DIAGNOSIS as soon as the gate learned to refuse on the MODEL
# credential too: an operator whose provider key was missing was told to fix a gh credential that was
# fine. So it pins the honest shape instead — the refusal says the environment contract could not be
# built, names BOTH surfaces it requires, and still lists every path it looked at.
grep -q 'could NOT build the worker' "$TMP/O4b/test.log" \
  && grep -qF 'hosts.yml' "$TMP/O4b/test.log" \
  && grep -qF 'keys.env (no GH_TOKEN/GITHUB_TOKEN value)' "$TMP/O4b/test.log" \
  && grep -qF "tmux server's GH_TOKEN/GITHUB_TOKEN" "$TMP/O4b/test.log" \
  && rc=0 || { rc=1; cat "$TMP/O4b/test.log" 2>/dev/null; }
ck "…naming every place it looked (hosts.yml, keys.env, the caller's env, the tmux server)" $rc
# …and it must name the MODEL surface too, because that is the other credential the gate now refuses on.
grep -qF 'LANE MODEL credential' "$TMP/O4b/test.log" && grep -qF 'pi-keys.env' "$TMP/O4b/test.log" && rc=0 || { rc=1; cat "$TMP/O4b/test.log" 2>/dev/null; }
ck "…and does not claim a gh-only cause: the refusal names the LANE MODEL credential as the other surface" $rc
[ -f "$TMP/O4b/state/worker-lane-8" ] && rc=1 || rc=0
ck "…and leaving NO worker record behind (a refusal is not a worker)" $rc
# POSITIVE CONTROL: the same empty HOME is FINE when the tmux server's own environment carries the
# token — so the refusal is a real probe of the environment, not a blanket ban on a bare HOME.
rm -rf "$TMP/O4c"
out="$(FAKE_UNAME=Linux TMUX_SERVER_GH_TOKEN=1 bash "$TMP/c2.sh" "$LIB" "$TMP/bin-absent" "$TMP/O4c" "$TMP/tmux4c.log" "$TMP/home-nocred" 2>&1)"
case "$out" in *"rc=0"*) rc=0 ;; *) rc=1; echo "      $out";; esac
ck "control: a HOME with no credential file still spawns when the tmux server carries GH_TOKEN" $rc
# ⛔ THE CALLER'S OWN ENVIRONMENT IS A CREDENTIAL SOURCE (review finding, 2026-10-22). `tmux
# new-session` starts a SERVER that inherits the CALLER's environment, so a box whose gh authenticates
# from `GH_TOKEN` in the environment is a working shape — and a probe that asked only the tmux SERVER
# refused it forever (`show-environment` needs a server, and a refusal starts none). That is the same
# "refused every spawn, every cycle" failure this change removes, in a different credential shape.
rm -rf "$TMP/O4f"
out="$(FAKE_UNAME=Linux KEEP_CALLER_TOKEN=1 GH_TOKEN=ghp_from_caller_env bash "$TMP/c2.sh" "$LIB" "$TMP/bin-absent" "$TMP/O4f" "$TMP/tmux4f.log" "$TMP/home-nocred" 2>&1)"
case "$out" in *"rc=0"*) rc=0 ;; *) rc=1; echo "      $out";; esac
ck "a caller whose own environment carries GH_TOKEN spawns (it will CREATE the server)" $rc
grep -q 'TMUX new-session -d -s lane-8' "$TMP/tmux4f.log" && rc=0 || rc=1
ck "…and it is a tmux session the worker inherits the caller's GH_TOKEN through" $rc
# ⛔ …BUT ONLY IF IT IS **EXPORTED** (P1 review finding, 2026-10-23, measured). A tmux client hands the
# server — and therefore the pane — only EXPORTED variables. `GH_TOKEN=ghp_x` as a plain shell variable is
# invisible to tmux, so crediting it produced gate rc=0, a written record, and a lane with NO credential:
# the same dead lane as the ~21-line death, reported as provisioned. Driven through the real spawn path.
rm -rf "$TMP/O4u"
out="$(FAKE_UNAME=Linux KEEP_CALLER_TOKEN=1 CALLER_UNEXPORTED=1 bash "$TMP/c2.sh" "$LIB" "$TMP/bin-absent" "$TMP/O4u" "$TMP/tmux4u.log" "$TMP/home-nocred" 2>&1)"
case "$out" in *"rc=1"*) rc=0 ;; *) rc=1; echo "      $out";; esac
ck "a caller GH_TOKEN that is NOT exported is REFUSED (a tmux pane never inherits a shell variable)" $rc
grep -q 'new-session -d -s lane-8' "$TMP/tmux4u.log" && rc=1 || rc=0
ck "…and no session is started for it" $rc
# ⛔ BUT ONLY WHEN THE SPAWN *CREATES* THE SERVER (review finding 1 on this diff, measured on tmux 3.4):
# against an ALREADY-RUNNING server a `new-session` gets the SERVER's global env plus tmux's
# `update-environment` list, which does not carry GH_TOKEN — a server created by `env -i HOME=/tmp/a`
# then `GH_TOKEN=ghp_caller_only tmux new-session` gave a pane with NO GH_TOKEN
# (`tmux show-environment -g GH_TOKEN` → `unknown variable`). Crediting the caller there is the same
# silent credential-less worker this gate exists to refuse, so it must be refused.
rm -rf "$TMP/O4h"; printf 'lane-99\n' > "$TMP/srv-sessions"
out="$(FAKE_UNAME=Linux KEEP_CALLER_TOKEN=1 GH_TOKEN=ghp_from_caller_env TMUX_STATE="$TMP/srv-sessions" bash "$TMP/c2.sh" "$LIB" "$TMP/bin-absent" "$TMP/O4h" "$TMP/tmux4h.log" "$TMP/home-nocred" 2>&1)"
case "$out" in *"rc=1"*) rc=0 ;; *) rc=1; echo "      $out";; esac
ck "a caller token against an EXISTING server is REFUSED (that session does not inherit it)" $rc
grep -q 'new-session -d -s lane-8' "$TMP/tmux4h.log" && rc=1 || rc=0
ck "…and no session is started for it" $rc
# ⛔ WHICH "NO SESSION NAMES" IS WHICH (review findings 1 + 2, measured on tmux 3.4, 2026-10-23). Two
# different boxes answer with NO session names, and they must not be conflated — the caller-token arm
# turns on the difference:
#   (i)  a LIVE server with ZERO sessions (`exit-empty off`): `tmux ls` → rc 0, EMPTY. The session does
#        NOT inherit the caller's GH_TOKEN, so crediting it starts exactly the credential-less worker
#        this gate exists to refuse. The old `-z "$(wt_tmux_names)"` inference did that (fail-open).
#   (ii) a box that has NEVER started a server. tmux answers rc 1 here — its WORDING depends on the
#        shape (`no server running on …` for an absent/stale socket, `error connecting to … (No such
#        file or directory)` when the socket FILE is missing; both measured on 3.4, and the second is
#        ALSO what a live server with an unlinked socket answers). The credit below keys on the RC, not
#        on the wording — `wt_tmux_has_server` returns 1 = "no server answers", 3 = "no answer". The
#        spawn CREATES the server, so the caller's token IS portable — refusing it is the "refused
#        every spawn, every cycle, forever" loop this change removes.
rm -rf "$TMP/O4n" "$TMP/srv-empty"; : > "$TMP/srv-empty"
out="$(FAKE_UNAME=Linux KEEP_CALLER_TOKEN=1 GH_TOKEN=ghp_from_caller_env TMUX_SERVER_EXISTS=1 TMUX_STATE="$TMP/srv-empty" bash "$TMP/c2.sh" "$LIB" "$TMP/bin-absent" "$TMP/O4n" "$TMP/tmux4n.log" "$TMP/home-nocred" 2>&1)"
case "$out" in *"rc=1"*) rc=0 ;; *) rc=1; echo "      $out";; esac
ck "(i) a caller token is REFUSED against a LIVE server with ZERO sessions (that session does not inherit it)" $rc
grep -q 'new-session -d -s lane-8' "$TMP/tmux4n.log" && rc=1 || rc=0
ck "…and no session is started against it" $rc
cat > "$TMP/c7.sh" <<'SH'
set -u
PATH="$2:$PATH"; O="$3"; WT_DIR="$O/state"; WT_TABLE_TTL=0; mkdir -p "$WT_DIR"
export CMUX_ABSENT=1 TMUX_STATE="$O/never" TMUX_LOG="$O/tmux.log"
. "$1"
if out="$(wt_tmux_names)"; then echo "names_rc=0 names=[$out]"; else echo "names_rc=$? names=[$out]"; fi
SH
out="$(FAKE_UNAME=Linux bash "$TMP/c7.sh" "$LIB" "$TMP/bin-absent" "$TMP/O4o" 2>&1)"
case "$out" in *"names_rc=0 names=[]"*) rc=0 ;; *) rc=1; echo "      $out";; esac
ck "(ii) a socket that was never created reads as 'no server' (rc 0, EMPTY) — not as unreadable (rc 3)" $rc
rm -rf "$TMP/O4p"
out="$(FAKE_UNAME=Linux KEEP_CALLER_TOKEN=1 GH_TOKEN=ghp_from_caller_env bash "$TMP/c2.sh" "$LIB" "$TMP/bin-absent" "$TMP/O4p" "$TMP/tmux4p.log" "$TMP/home-nocred" 2>&1)"
case "$out" in *"rc=0"*) rc=0 ;; *) rc=1; echo "      $out";; esac
ck "(ii) …so on a never-a-server box the spawn is NOT refused: it creates the server and inherits the token" $rc
# ⛔ A QUOTED EMPTY VALUE IS STILL EMPTY (review finding, measured 2026-10-23): `=[^[:space:]]` counted
# `GH_TOKEN=""` as provision — the character after `=` is a quote — so keys.env exported an EMPTY token,
# gh fell back to a hosts.yml this HOME does not have, and the worker died at its first call while the
# gate reported it provisioned.
rm -rf "$TMP/home-qempty" "$TMP/O4q"; mkdir -p "$TMP/home-qempty"
printf 'export GH_TOKEN=""\n' > "$TMP/home-qempty/keys.env"
out="$(FAKE_UNAME=Linux bash "$TMP/c2.sh" "$LIB" "$TMP/bin-absent" "$TMP/O4q" "$TMP/tmux4q.log" "$TMP/home-qempty" 2>&1)"
case "$out" in *"rc=1"*) rc=0 ;; *) rc=1; echo "      $out";; esac
ck "a QUOTED empty GH_TOKEN in keys.env is REFUSED (a quote is not a value)" $rc
# ⛔ gh's CONFIG DIR IS NOT ALWAYS `$HOME/.config/gh` (review finding). gh resolves `GH_CONFIG_DIR`,
# then `${XDG_CONFIG_HOME}/gh`, then `$HOME/.config/gh`. A one-location probe refuses an AUTHENTICATED
# box forever — the refusal starts no session, so nothing can ever change the answer.
rm -rf "$TMP/home-ghcd" "$TMP/ghcd" "$TMP/O4r"; mkdir -p "$TMP/home-ghcd" "$TMP/ghcd"
printf 'github.com:\n    oauth_token: gho_from_ghcd\n' > "$TMP/ghcd/hosts.yml"
out="$(FAKE_UNAME=Linux GH_CONFIG_DIR="$TMP/ghcd" bash "$TMP/c2.sh" "$LIB" "$TMP/bin-absent" "$TMP/O4r" "$TMP/tmux4r.log" "$TMP/home-ghcd" 2>&1)"
case "$out" in *"rc=0"*) rc=0 ;; *) rc=1; echo "      $out";; esac
ck "…while a box whose credential lives in GH_CONFIG_DIR spawns (gh's own resolution order)" $rc
# …AND THE WORKER IS TOLD WHERE IT IS. A tmux session does not inherit this shell's environment, so a
# probe that accepts a repointed config dir while the launch line omits it blesses a credential the
# WORKER cannot see — a false provision one layer down (found reviewing this diff's own fix).
grep -q "export GH_CONFIG_DIR=" "$TMP/tmux4r.log" && rc=0 || { rc=1; cat "$TMP/tmux4r.log" 2>/dev/null; }
ck "…and the launch line carries GH_CONFIG_DIR, so the worker's gh resolves the same file the probe read" $rc
# ⛔ AND THE INVERSE, WHICH IS THE SAME BUG (review finding, 2026-10-23): when the probe used the
# DEFAULT (`$home/.config/gh`, neither variable set in the caller), a worker that still inherits
# `GH_CONFIG_DIR`/`XDG_CONFIG_HOME` — from the tmux SERVER's environment, or exported by the `keys.env`
# sourced under `set -a` — reads a DIFFERENT file than the one that was probed. Measured at 9b30d611:
# the probe read `$home/.config/gh/hosts.yml` (token present) while the worker's gh would have read
# `$XDG_CONFIG_HOME/gh/hosts.yml` (no token) — a dead lane on a spawn that returned 0. Driven for real:
# the prefix is EXECUTED under `env -i` carrying both variables, and both are read back.
cat > "$TMP/c8.sh" <<'SH'
set -u
PATH="$2:$PATH"; O="$3"; WT_DIR="$O/state"; WT_TABLE_TTL=0; mkdir -p "$WT_DIR"
unset GH_CONFIG_DIR XDG_CONFIG_HOME   # the CALLER probes the default; the worker must inherit nothing
. "$1"
printf 'PFX<<%s>>\n' "$(wt_launcher_env "$4")"
SH
out="$(bash "$TMP/c8.sh" "$LIB" "$TMP/bin-absent" "$TMP/O4s" "$TMP/home-plain" 2>&1)"
pfx="$(printf '%s\n' "$out" | sed -n 's/^PFX<<\(.*\)>>$/\1/p')"
envout="$(env -i PATH=/usr/bin:/bin HOME="$TMP/home-plain" XDG_CONFIG_HOME="$TMP/elsewhere" GH_CONFIG_DIR="$TMP/ghcd" "$BASH" -c "$pfx; printf 'XDG=[%s] GHCD=[%s]\n' \"\${XDG_CONFIG_HOME:-unset}\" \"\${GH_CONFIG_DIR:-unset}\"" 2>&1)"
case "$envout" in *"XDG=[unset] GHCD=[unset]"*) rc=0 ;; *) rc=1; echo "      $envout";; esac
ck "…and a DEFAULT-config probe UNSETS both, so an inherited config dir cannot repoint the worker's gh" $rc
# ⛔ A `keys.env` THAT FAILS TO SOURCE IS FATAL (review finding): `wt_runfile` already dies (`|| exit
# 98`), and the tmux arm must agree — otherwise a failed source silently drops the token assignment
# and runs a credential-less lane on a spawn that returned 0 and wrote its record.
rm -rf "$TMP/home-badkeys" "$TMP/O4t"; gh_hosts_fixture "$TMP/home-badkeys"
printf 'GH_TOKEN=ghp_ok\nBADLINE ( (\n' > "$TMP/home-badkeys/keys.env"
out="$(bash "$TMP/c8.sh" "$LIB" "$TMP/bin-absent" "$TMP/O4t" "$TMP/home-badkeys" 2>&1)"
pfx="$(printf '%s\n' "$out" | sed -n 's/^PFX<<\(.*\)>>$/\1/p')"
env -i PATH=/usr/bin:/bin "$BASH" -c "$pfx; echo REACHED" >/dev/null 2>&1; rcs=$?
[ "$rcs" = "98" ] && rc=0 || { rc=1; echo "      rc=$rcs prefix=$pfx"; }
ck "a keys.env that fails to source EXITS 98 (the worker's own shell dies before it runs the command)" $rc
# ⛔ THAT GUARD IS NOW ENFORCED BEFORE ANY SESSION EXISTS (P1 review finding, 2026-10-23, MEASURED).
# This note used to say only that `tmux new-session -d` returns 0 as soon as the session object exists,
# so a worker that exits 98 in its first millisecond is still recorded as started — true, and filed as
# agent-infra#2447, but it left the guard above DECORATIVE: measured on the pre-fix head, (i) a
# token-bearing hosts.yml on a box with no `gh` and (ii) a keys.env line the static credit sees but the
# source never executes each produced `wt_spawn` rc=0 AND a `kind=tmux` record for a pane that had
# already exited 98. `wt_spawn` now executes the prefix once caller-side and refuses on non-zero, so the
# CREDENTIAL-CONTRACT arm cannot be blessed; #2447 keeps the wider residual (any worker COMMAND that
# dies at once, after the contract passed).
rm -rf "$TMP/O4nogh"; gh_hosts_fixture "$TMP/home-store-nogh"
cat > "$TMP/c10.sh" <<'SH'
set -u
O="$3"; WT_DIR="$O/state"; WT_TABLE_TTL=0; LOG="$O/test.log"
mkdir -p "$WT_DIR"          # still the caller's PATH here — narrowed to the box below
PATH="$2"                  # NO gh anywhere: a `:$PATH` suffix would find the real /usr/bin/gh
export CMUX_ABSENT=1 TMUX_LOG="$4" WT_WORKER_HOME="$5"; : > "$TMUX_LOG"
unset GH_TOKEN GITHUB_TOKEN
. "$1"
wt_spawn "lane-8" "/tmp" 'bash /tmp/lane.sh 8 b o/r'; echo "rc=$?"
SH
out="$(bash "$TMP/c10.sh" "$LIB" "$TMP/bin-storenogh" "$TMP/O4nogh" "$TMP/tmux4nogh.log" "$TMP/home-store-nogh" 2>&1)"
case "$out" in *"rc=1"*) rc=0 ;; *) rc=1; echo "      $out";; esac
ck "(i) a hosts.yml credit on a box with NO gh is REFUSED, not started" $rc
grep -q 'new-session' "$TMP/tmux4nogh.log" && rc=1 || rc=0
ck "…and no session is created for it (the refusal lands BEFORE new-session)" $rc
[ -f "$TMP/O4nogh/state/worker-lane-8" ] && rc=1 || rc=0
ck "…and NO worker record is written, so nothing reports a dead lane as started" $rc
grep -q 'FAILS when it is executed' "$TMP/O4nogh/test.log" && rc=0 || { rc=1; cat "$TMP/O4nogh/test.log" 2>/dev/null; }
ck "…naming the executed contract as the reason, so an operator can see where the credit broke" $rc
# ⛔ AND A STATIC GREP MATCH IS NOT A CREDIT (case ii): the file PARSES and the line matches, but the
# source never executes it — the shape the grep-alone credit blessed and the pane then exited 98 on.
rm -rf "$TMP/O4static"; mkdir -p "$TMP/home-static"
printf 'if [ -n "${NEVER_SET:-}" ]; then\nexport GH_TOKEN=ghp_never_runs\nfi\n' > "$TMP/home-static/keys.env"
out="$(FAKE_UNAME=Linux bash "$TMP/c2.sh" "$LIB" "$TMP/bin-absent" "$TMP/O4static" "$TMP/tmux4static.log" "$TMP/home-static" 2>&1)"
case "$out" in *"rc=1"*) rc=0 ;; *) rc=1; echo "      $out";; esac
ck "(ii) a keys.env line the static credit sees but the source never runs is REFUSED" $rc
grep -q 'new-session' "$TMP/tmux4static.log" && rc=1 || rc=0
ck "…and no session is created (the credit is VERIFIED by execution, not by the grep)" $rc
[ -f "$TMP/O4static/state/worker-lane-8" ] && rc=1 || rc=0
ck "…and no worker record is written" $rc
# POSITIVE CONTROL: the SAME token-bearing hosts.yml on a box whose gh DOES answer spawns — the
# pre-flight is a probe of the environment, not a blanket ban on the store arm.
rm -rf "$TMP/O4ghok"; gh_hosts_fixture "$TMP/home-store-ghok"
out="$(FAKE_UNAME=Linux bash "$TMP/c2.sh" "$LIB" "$TMP/bin-ghtok" "$TMP/O4ghok" "$TMP/tmux4ghok.log" "$TMP/home-store-ghok" 2>&1)"
case "$out" in *"rc=0"*) rc=0 ;; *) rc=1; echo "      $out";; esac
ck "control: the same store credit spawns when the worker's gh can read it (the pre-flight is a probe)" $rc
grep -q '^kind=tmux' "$TMP/O4ghok/state/worker-lane-8" && rc=0 || rc=1
ck "…and the worker record is written, as before" $rc
# ⛔ BUT A BENIGN NON-ZERO LAST STATEMENT IS NOT A BROKEN FILE (review finding, 2026-10-23, measured).
# The guard used to be `… && . FILE || exit 98`, which reads the status of the LAST COMMAND IN THE FILE —
# so an ordinary operator line like `[ -d /x ] && export Y`, false and last, killed the worker AFTER it
# had exported the token, on a spawn that returned 0 and wrote its record. The guard is now a PARSE
# check in the sourcing dialect (`bash -n`, `sh -n` only when bash is absent) BEFORE the source, plus a
# post-source credential re-check that fires only on a non-zero status — so this shape runs.
rm -rf "$TMP/home-lastfalse" "$TMP/O4t2"; gh_hosts_fixture "$TMP/home-lastfalse"
printf 'GH_TOKEN=ghp_ok\n[ -d /tmp/definitely-not-a-dir-2396 ] && export EXTRA=1\n' > "$TMP/home-lastfalse/keys.env"
out="$(bash "$TMP/c8.sh" "$LIB" "$TMP/bin-absent" "$TMP/O4t2" "$TMP/home-lastfalse" 2>&1)"
pfx="$(printf '%s\n' "$out" | sed -n 's/^PFX<<\(.*\)>>$/\1/p')"
reach="$(env -i PATH=/usr/bin:/bin "$BASH" -c "$pfx; printf 'REACHED'" 2>/dev/null)"
[ "$reach" = "REACHED" ] && rc=0 || { rc=1; echo "      reach=[$reach] prefix=$pfx"; }
ck "a keys.env whose LAST statement is false still runs the worker (a non-zero status is not fatal while a credential was exported)" $rc
# ⛔ …AND A FILE THAT TERMINATES THE SOURCING SHELL IS REFUSED (review finding, 2026-10-23, measured —
# agent-infra#1713's class). `bash -n` accepts `GH_TOKEN=ghp_x` + `exit 0`, and a plain `. FILE` then ends
# the WORKER's shell BEFORE the HOME re-assert and the credential re-check: the spawn returns 0, the
# `home=` record is written, and the lane never starts. The sentinel probe's ABSENCE is the signal —
# `exit 0` IS a success status, so a status-based guard cannot see this.
rm -rf "$TMP/home-exit" "$TMP/O4t1x"; mkdir -p "$TMP/home-exit"
printf 'GH_TOKEN=ghp_ok\nexit 0\n' > "$TMP/home-exit/keys.env"
out="$(bash "$TMP/c8.sh" "$LIB" "$TMP/bin-absent" "$TMP/O4t1x" "$TMP/home-exit" 2>&1)"
pfx="$(printf '%s\n' "$out" | sed -n 's/^PFX<<\(.*\)>>$/\1/p')"
reach="$(env -i PATH=/usr/bin:/bin HOME="$TMP/home-exit" "$BASH" -c "$pfx; printf 'REACHED'" 2>/dev/null)"; rcs=$?
[ "$reach" = "" ] && [ "$rcs" = "98" ] && rc=0 || { rc=1; echo "      reach=[$reach] rc=$rcs prefix=$pfx"; }
ck "a keys.env with a top-level 'exit 0' exits 98 (the file terminated its shell, so the token check never ran)" $rc
# ⛔ …AND A FILE THAT PARSES BUT ABORTS **BEFORE** THE TOKEN IS STILL FATAL (the other half, measured):
# `return 1` is legal in a sourced file and `sh -n` accepts it, so a syntax pre-check alone would let the
# source stop before the token assignment and run the worker credential-less on an rc=0 spawn. The guard
# therefore re-checks the ENVIRONMENT after the source: non-zero status AND no credential ⇒ exit 98.
# ⚠ NO hosts.yml on this HOME: with one, the environment would legitimately hold a credential through it
# and running the worker would be correct — the case under test is the one where NOTHING does.
rm -rf "$TMP/home-return" "$TMP/O4t3"; mkdir -p "$TMP/home-return"
printf 'FOO=1\nreturn 1\nGH_TOKEN=ghp_ok\n' > "$TMP/home-return/keys.env"
out="$(bash "$TMP/c8.sh" "$LIB" "$TMP/bin-absent" "$TMP/O4t3" "$TMP/home-return" 2>&1)"
pfx="$(printf '%s\n' "$out" | sed -n 's/^PFX<<\(.*\)>>$/\1/p')"
reach="$(env -i PATH=/usr/bin:/bin HOME="$TMP/home-return" "$BASH" -c "$pfx; printf 'REACHED'" 2>/dev/null)"
[ "$reach" = "" ] && rc=0 || { rc=1; echo "      reach=[$reach] prefix=$pfx"; }
ck "a keys.env that aborts BEFORE the token exits 98 (a parse check alone would have run it)" $rc
# …and the same abort AFTER the token has been exported is NOT fatal — the environment holds the
# credential the worker needs, which is the question the guard is asking.
rm -rf "$TMP/home-return2" "$TMP/O4t4"; mkdir -p "$TMP/home-return2"
printf 'GH_TOKEN=ghp_ok\nreturn 1\n' > "$TMP/home-return2/keys.env"
out="$(bash "$TMP/c8.sh" "$LIB" "$TMP/bin-absent" "$TMP/O4t4" "$TMP/home-return2" 2>&1)"
pfx="$(printf '%s\n' "$out" | sed -n 's/^PFX<<\(.*\)>>$/\1/p')"
reach="$(env -i PATH=/usr/bin:/bin HOME="$TMP/home-return2" "$BASH" -c "$pfx; printf 'REACHED'" 2>/dev/null)"
[ "$reach" = "REACHED" ] && rc=0 || { rc=1; echo "      reach=[$reach] prefix=$pfx"; }
ck "a keys.env that aborts AFTER exporting the token still runs the worker (a credential is present)" $rc
# ⛔ A CLEAN-SOURCING `keys.env` MUST NOT CLOBBER ANOTHER ARM'S CREDIT (review finding, 2026-10-23,
# measured). The post-source re-check used to fire ONLY when the FILE had credited the token, so a CALLER
# token (or a store credit) followed by a file carrying the blank `GH_TOKEN=` placeholder an operator
# leaves when moving to store auth exported an EMPTY value over it — and nothing re-read it: a
# credential-less worker on an rc=0 spawn, the ~21-line death this gate exists to refuse.
rm -rf "$TMP/home-clobber" "$TMP/O4t8"; mkdir -p "$TMP/home-clobber"
printf 'GH_TOKEN=\n' > "$TMP/home-clobber/keys.env"
out="$(KEEP_CALLER_TOKEN=1 GH_TOKEN=ghp_from_caller_env bash "$TMP/c8.sh" "$LIB" "$TMP/bin-absent" "$TMP/O4t8" "$TMP/home-clobber" 2>&1)"
pfx="$(printf '%s\n' "$out" | sed -n 's/^PFX<<\(.*\)>>$/\1/p')"
reach="$(env -i PATH=/usr/bin:/bin HOME="$TMP/home-clobber" GH_TOKEN=ghp_from_caller_env "$BASH" -c "$pfx; printf 'REACHED'" 2>/dev/null)"
[ "$reach" = "" ] && rc=0 || { rc=1; echo "      reach=[$reach] prefix=$pfx"; }
ck "a keys.env that blanks GH_TOKEN over a caller credit exits 98 (the credit is re-read after the source)" $rc
# ⛔ A GREP MATCH IS NOT PROOF THE SOURCE EXPORTS IT (review finding, 2026-10-23, measured). A token line
# the file never EXECUTES — inside an `if` that is false, or a function nobody calls — matches the static
# grep, so the gate reports provisioned while the worker gets nothing and stops at its first `gh` call.
# The file-only credit is therefore verified after the source: no non-blank token in the environment and
# no other store ⇒ exit 98.
rm -rf "$TMP/home-cond" "$TMP/O4t7"; mkdir -p "$TMP/home-cond"
printf 'if [ -n "${NEVER_SET:-}" ]; then\n  export GH_TOKEN=ghp_never_executed\nfi\n' > "$TMP/home-cond/keys.env"
out="$(bash "$TMP/c8.sh" "$LIB" "$TMP/bin-absent" "$TMP/O4t7" "$TMP/home-cond" 2>&1)"
pfx="$(printf '%s\n' "$out" | sed -n 's/^PFX<<\(.*\)>>$/\1/p')"
reach="$(env -i PATH=/usr/bin:/bin HOME="$TMP/home-cond" "$BASH" -c "$pfx; printf 'REACHED'" 2>/dev/null)"
[ "$reach" = "" ] && rc=0 || { rc=1; echo "      reach=[$reach] prefix=$pfx"; }
ck "a keys.env whose token line never EXECUTES exits 98 (the file credit is verified, not grepped)" $rc
# ⛔ `wt_gh_hosts` RESOLUTION ORDER, PINNED DIRECTLY (review finding): its two consumers are the no-gh
# fallback and the refusal message, and the spawn-level pins never reach it because the gh arm answers
# first — a mutant that deleted the GH_CONFIG_DIR arm survived the whole suite. Pure function, no gh.
hosts_rc() { ( set -u; . "$LIB" >/dev/null 2>&1; wt_gh_hosts "$1" ); }
( export GH_CONFIG_DIR=/tmp/ghcd-2396; [ "$(hosts_rc /tmp/h-2396)" = "/tmp/ghcd-2396/hosts.yml" ] ) && rc=0 || rc=1
ck "wt_gh_hosts: GH_CONFIG_DIR wins when set" $rc
( export XDG_CONFIG_HOME=/tmp/xdg-2396; [ "$(hosts_rc /tmp/h-2396)" = "/tmp/xdg-2396/gh/hosts.yml" ] ) && rc=0 || rc=1
ck "wt_gh_hosts: \$XDG_CONFIG_HOME/gh/hosts.yml when only XDG_CONFIG_HOME is set" $rc
[ "$(hosts_rc /tmp/h-2396)" = "/tmp/h-2396/.config/gh/hosts.yml" ] && rc=0 || rc=1
ck "wt_gh_hosts: \$HOME/.config/gh/hosts.yml when neither is set" $rc
# ⛔ AND `wt_launcher_env` REFUSES AN EMPTY HOME BY ITSELF (review finding: the spawn pin passed for a
# different reason — the server probe refused first — so the guard was unpinned).
env_empty_rc() { ( set -u; PATH="$TMP/bin-absent:$PATH"; export TMUX_STATE="$TMP/srv-sessions" TMUX_SERVER_GH_TOKEN=1
                    . "$LIB" >/dev/null 2>&1; wt_launcher_env "" >/dev/null 2>&1; printf '%s' "$?" ); }
[ "$(env_empty_rc)" != "0" ] && rc=0 || rc=1
ck "wt_launcher_env with no HOME refuses even when the SERVER carries a token (there is nothing to export)" $rc
# ⛔ AN INHERITED `GH_TOKEN` MUST NOT OVERRIDE THE STORE THE GATE VALIDATED (P1 review finding,
# 2026-10-23, measured). gh prefers `GH_TOKEN`/`GITHUB_TOKEN` over ANY store, and a tmux pane inherits the
# SERVER's environment — which this module can itself stamp (the caller-token arm creates the server with
# the caller's env). Driven: the prefix is EXECUTED with a server token in the environment, and the
# worker's own environment is read back.
rm -rf "$TMP/home-store" "$TMP/O4u1"; gh_hosts_fixture "$TMP/home-store"
out="$(bash "$TMP/c8.sh" "$LIB" "$TMP/bin-absent" "$TMP/O4u1" "$TMP/home-store" 2>&1)"
pfx="$(printf '%s\n' "$out" | sed -n 's/^PFX<<\(.*\)>>$/\1/p')"
seen="$(env -i PATH=/usr/bin:/bin HOME="$TMP/home-store" GH_TOKEN=ghp_from_SERVER /bin/bash -c "$pfx; printf '%s' \"\${GH_TOKEN:-NONE}\"")"
[ "$seen" = "NONE" ] && rc=0 || { rc=1; echo "      worker GH_TOKEN=[$seen]"; }
ck "…and a STORE credit CLEARS an inherited GH_TOKEN, so the worker uses the store the probe read" $rc
seen="$(env -i PATH=/usr/bin:/bin HOME="$TMP/home-store" GH_TOKEN='   ' /bin/bash -c "$pfx; printf '%s' \"\${GH_TOKEN:-NONE}\"")"
[ "$seen" = "NONE" ] && rc=0 || { rc=1; echo "      worker GH_TOKEN=[$seen]"; }
ck "…a BLANK inherited GH_TOKEN is cleared too (gh prefers it over a valid GITHUB_TOKEN)" $rc
# …while the CALLER-token arm is deliberately EXEMPT: there the inherited value IS the credential.
rm -rf "$TMP/home-callertok" "$TMP/O4u2"; mkdir -p "$TMP/home-callertok"
out="$(KEEP_CALLER_TOKEN=1 GH_TOKEN=ghp_from_caller bash "$TMP/c8.sh" "$LIB" "$TMP/bin-absent" "$TMP/O4u2" "$TMP/home-callertok" 2>&1)"
pfx="$(printf '%s\n' "$out" | sed -n 's/^PFX<<\(.*\)>>$/\1/p')"
seen="$(env -i PATH=/usr/bin:/bin HOME="$TMP/home-callertok" GH_TOKEN=ghp_from_caller /bin/bash -c "$pfx; printf '%s' \"\${GH_TOKEN:-NONE}\"")"
[ "$seen" = "ghp_from_caller" ] && rc=0 || { rc=1; echo "      worker GH_TOKEN=[$seen]"; }
ck "…but a CALLER-token credit does NOT clear it (the worker inherits that token through the new server)" $rc
# ⛔ AND A BLANK `GH_TOKEN` IS CLEARED EVEN ON THE EXEMPT ARMS (review finding): gh prefers `GH_TOKEN` over
# a perfectly good `GITHUB_TOKEN`, so a stray space in one leaves a dead lane while the other is valid.
# This arm is deliberately NOT cleared wholesale, which is exactly why the blank-name rule must stand alone.
seen="$(env -i PATH=/usr/bin:/bin HOME="$TMP/home-callertok" GH_TOKEN='   ' GITHUB_TOKEN=ghp_valid /bin/bash -c "$pfx; printf '%s/%s' \"\${GH_TOKEN:-NONE}\" \"\${GITHUB_TOKEN:-NONE}\"")"
[ "$seen" = "NONE/ghp_valid" ] && rc=0 || { rc=1; echo "      worker GH/GITHUB=[$seen]"; }
ck "…a BLANK GH_TOKEN is cleared while GITHUB_TOKEN survives (gh prefers the blank one, so it must go)" $rc
# ⛔ THE CLEAR MUST SEE WHAT `keys.env` WROTE (P1 review finding, 2026-10-23, MEASURED). The clear used
# to be emitted BEFORE the source, so a file re-introducing `GH_TOKEN='   '` kept it — and on a STORE
# credit the old post-source check (gated on the FILE credit or a non-zero status) never fired, so the
# worker's gh answered `The token in GH_TOKEN is invalid` on a spawn that reported provisioned.
rm -rf "$TMP/home-storews" "$TMP/O4ws"; gh_hosts_fixture "$TMP/home-storews"
printf "export GH_TOKEN='   '\n" > "$TMP/home-storews/keys.env"
out="$(bash "$TMP/c8.sh" "$LIB" "$TMP/bin-absent" "$TMP/O4ws" "$TMP/home-storews" 2>&1)"
pfx="$(printf '%s\n' "$out" | sed -n 's/^PFX<<\(.*\)>>$/\1/p')"
seen="$(env -i PATH=/usr/bin:/bin HOME="$TMP/home-storews" O="$TMP/O4ws" /bin/bash -c "$pfx; printf '%s' \"\${GH_TOKEN:-NONE}\"" 2>/dev/null)"
[ "$seen" = "NONE" ] && rc=0 || { rc=1; echo "      worker GH_TOKEN=[$seen]"; }
ck "…a blank GH_TOKEN written by keys.env is cleared AFTER the source, so the store the probe read is used" $rc
# …and where the file's blank token has JUST DISPLACED an inherited one, no credential remains — so the
# guard must REFUSE the worker instead of starting it credential-less (fail-closed, not fail-open).
rm -rf "$TMP/home-wsdisp" "$TMP/O4ws2"; mkdir -p "$TMP/home-wsdisp"
printf "export GH_TOKEN='   '\n" > "$TMP/home-wsdisp/keys.env"
out="$(GH_TOKEN=ghp_from_caller bash "$TMP/c8.sh" "$LIB" "$TMP/bin-absent" "$TMP/O4ws2" "$TMP/home-wsdisp" 2>&1)"
pfx="$(printf '%s\n' "$out" | sed -n 's/^PFX<<\(.*\)>>$/\1/p')"
reach="$(env -i PATH=/usr/bin:/bin HOME="$TMP/home-wsdisp" O="$TMP/O4ws2" /bin/bash -c "$pfx; printf 'REACHED'" 2>/dev/null)"
[ "$reach" = "" ] && rc=0 || { rc=1; echo "      reach=[$reach] prefix=$pfx"; }
ck "…and a file that blanks the ONLY credential EXITS 98 (no store to fall back to: refused, not started)" $rc
# ⛔ gh's OWN OUTPUT is held to the same value rule (review finding): a whitespace token comes back rc 0
# from `gh auth token`, so without the value test the gh arm credited a file its own file-arm refuses.
tok_rc() { ( set -u; . "$LIB" >/dev/null 2>&1; wt_gh_hosts_token "$1" >/dev/null 2>&1; printf '%s' "$?" ); }
rm -rf "$TMP/home-wstok"; mkdir -p "$TMP/home-wstok/.config/gh"
printf 'github.com:\n    user: fixture\n    oauth_token: "   "\n' > "$TMP/home-wstok/.config/gh/hosts.yml"
# ⛔ HERMETIC (review finding, 2026-10-23): this pin asks the shipped probe directly, so without a stub
# it asks whatever gh the MACHINE has — and a keychain store answers for a HOME it was never pointed at.
# The stub models the exact faulty answer: rc 0 with three spaces.
mkdir -p "$TMP/bin-wstok"
printf '#!/usr/bin/env bash\ncase "${1:-} ${2:-}" in "auth token") printf "   \\n"; exit 0 ;; esac\nexit 1\n' > "$TMP/bin-wstok/gh"
chmod +x "$TMP/bin-wstok/gh"
[ "$( PATH="$TMP/bin-wstok:$PATH" tok_rc "$TMP/home-wstok" )" != "0" ] && rc=0 || rc=1
ck "wt_gh_hosts_token: a WHITESPACE token is refused by the gh arm too (one rule, both arms)" $rc
# ⛔ AND THE SPAWN PINS THE SOURCING SHELL: the pre-check's dialect must be the runtime's dialect.
grep -q 'TMUX new-session -d -s lane-8 bash -c' "$TMP/tmux4.log" && rc=0 || { rc=1; cat "$TMP/tmux4.log"; }
ck "…the session runs under \`bash -c\`, so the parse check and the source use the same shell" $rc
# ⛔ ONE SHELL-COMMAND ARGUMENT, AND IT MUST ACTUALLY RUN (P0 review finding, 2026-10-23, MEASURED).
# tmux passes a SINGLE shell-command argument through the shell, but EXECs a MULTI-argument command
# DIRECTLY — so the three-word form `bash -c "'<line>'"` handed bash a literally single-quoted word as
# its command string, bash looked for a command by that name, every pane died with status 127, and
# `new-session -d` still returned 0. That is the dead-lane-reported-provisioned this PR exists to
# remove, and the pins above could not see it: `TMUX $*` renders both shapes identically.
ns_argv() { awk '/^ARGV new-session$/{f=1;n=0;next} f&&/^ARGV /{n++;a[n]=substr($0,6);next} f{exit} END{printf "%d\t%s\n", n, a[n]}' "$1"; }
rm -rf "$TMP/ran" "$TMP/O9"; mkdir -p "$TMP/ran"
cat > "$TMP/c9.sh" <<'SH'
set -u
PATH="$2:$PATH"; O="$3"; WT_DIR="$O/state"; WT_TABLE_TTL=0; LOG="$O/test.log"; mkdir -p "$WT_DIR"
export CMUX_ABSENT=1 TMUX_LOG="$4" WT_WORKER_HOME="$5"; : > "$TMUX_LOG"
. "$1"
wt_spawn "lane-9" "$6" 'printf RAN_OK > ran.txt'
SH
out="$(FAKE_UNAME=Linux bash "$TMP/c9.sh" "$LIB" "$TMP/bin-absent" "$TMP/O9" "$TMP/tmux9.log" "$TMP/home-c" "$TMP/ran" 2>&1)"
[ "$(ns_argv "$TMP/tmux9.log" | cut -f1)" = "4" ] && rc=0 || { rc=1; echo "      argv=$(ns_argv "$TMP/tmux9.log" | cut -f1)"; sed -n '/^ARGV/p' "$TMP/tmux9.log"; }
ck "…and hands tmux ONE shell-command argument (a multi-word command is exec'd directly: 127)" $rc
cmdline="$(ns_argv "$TMP/tmux9.log" | cut -f2-)"
( cd "$TMP/ran" && timeout 60 sh -c "$cmdline" ) >/dev/null 2>&1
{ [ -f "$TMP/ran/ran.txt" ] && [ "$(cat "$TMP/ran/ran.txt" 2>/dev/null)" = "RAN_OK" ]; } && rc=0 || { rc=1; echo "      cmdline=$cmdline"; }
ck "…and executing that argument the way tmux does (one argument → the shell) really RUNS the line" $rc
# ⛔ AND THE REAL BINARY AGREES (the P0 was measured on tmux 3.4). Declared BLIND where tmux is absent —
# never a silent pass.
if command -v tmux >/dev/null 2>&1; then
  _sock="wt2396-$$"; _conf="$TMP/tmux-real.conf"
  printf 'set -g remain-on-exit on\nset -g exit-empty off\n' > "$_conf"
  rm -f "$TMP/ran/ran.txt"
  timeout 30 tmux -L "$_sock" -f "$_conf" new-session -d -s probe "$cmdline" >/dev/null 2>&1
  _i=0; while [ "$_i" -lt 100 ] && [ ! -f "$TMP/ran/ran.txt" ]; do sleep 0.1; _i=$((_i+1)); done
  _panes="$(tmux -L "$_sock" list-panes -F '#{pane_dead}:#{pane_dead_status}' 2>/dev/null | head -1)"
  tmux -L "$_sock" kill-server >/dev/null 2>&1
  { [ -f "$TMP/ran/ran.txt" ] && [ "$(cat "$TMP/ran/ran.txt" 2>/dev/null)" = "RAN_OK" ]; } && rc=0 || { rc=1; echo "      panes=$_panes ran=[$(cat "$TMP/ran/ran.txt" 2>/dev/null)]"; }
  ck "…and a REAL tmux runs the same argv (multi-word would be exec'd directly and die 127)" $rc
else
  printf '  \033[33mSKIP\033[0m  real-tmux spawn leg DECLARED BLIND: no tmux on this box\n'
fi
# ⛔ A BLANK VALUE IS NOT A CREDENTIAL, AND THE TWO HALVES OF THIS GATE MUST AGREE ON THAT (review
# finding, 2026-10-23, measured). `[ -z "$GH_TOKEN$GITHUB_TOKEN" ]` counted `GH_TOKEN='   '` as provision,
# while the STATIC keys.env arm refuses whitespace (`[^[:space:]]`) — and gh rejects it at the first call.
# The `$( )` spelling is what the static arm's documented residual lets through, so it is the shape that
# reaches the dynamic guard at all.
rm -rf "$TMP/home-ws" "$TMP/O4t5"; mkdir -p "$TMP/home-ws"
printf 'GH_TOKEN="$(printf '\''   '\'')"\nfalse\n' > "$TMP/home-ws/keys.env"
out="$(bash "$TMP/c8.sh" "$LIB" "$TMP/bin-absent" "$TMP/O4t5" "$TMP/home-ws" 2>&1)"
pfx="$(printf '%s\n' "$out" | sed -n 's/^PFX<<\(.*\)>>$/\1/p')"
reach="$(env -i PATH=/usr/bin:/bin HOME="$TMP/home-ws" "$BASH" -c "$pfx; printf 'REACHED'" 2>/dev/null)"
[ "$reach" = "" ] && rc=0 || { rc=1; echo "      reach=[$reach] prefix=$pfx"; }
ck "a WHITESPACE-only GH_TOKEN plus a non-zero source status exits 98 (blank is not a credential)" $rc
# ⛔ THE PARSE CHECK MUST USE THE DIALECT THE FILE IS WRITTEN IN (review finding, 2026-10-23, measured):
# `sh -n` on a dash box refuses a BASH-valid keys.env, and a refused spawn is forever (no session starts,
# so nothing changes the answer) — the #2210 loop in a new disguise. bash decides when it exists.
rm -rf "$TMP/home-bashy" "$TMP/O4t6"; mkdir -p "$TMP/home-bashy"
printf 'GH_TOKEN=ghp_ok\nARR=(1 2)\n' > "$TMP/home-bashy/keys.env"
out="$(bash "$TMP/c8.sh" "$LIB" "$TMP/bin-absent" "$TMP/O4t6" "$TMP/home-bashy" 2>&1)"
pfx="$(printf '%s\n' "$out" | sed -n 's/^PFX<<\(.*\)>>$/\1/p')"
reach="$(env -i PATH=/usr/bin:/bin HOME="$TMP/home-bashy" "$BASH" -c "$pfx; printf 'REACHED'" 2>/dev/null)"
[ "$reach" = "REACHED" ] && rc=0 || { rc=1; echo "      reach=[$reach] prefix=$pfx"; }
ck "a BASH-only syntax in keys.env is not refused by the pre-check (bash decides, not dash)" $rc
# ⛔ THE RUNTIME GUARD MUST RESOLVE gh THE SAME WAY THE GATE DID, AND BE BOUNDED (P2 review finding,
# 2026-10-23, measured). It used to call `gh` through the PANE's PATH — which a `PATH=` line inside
# `keys.env` rewrites (measured: gate rc=0, record written, worker `exit 98` on its first statement, a
# silently dead lane) — and it was UNBOUNDED, against the README's own rule (a plain `gh auth token` can
# hang for the life of the shell, rc=142 measured). It now calls an ABSOLUTE path resolved at build time
# under perl's alarm. Where no gh is resolvable at build time the guard is `false` — a refusal BEFORE
# the session (the peer round's pre-flight), which is this file's documented fail-closed policy for a
# box that cannot run a lane at all; it is NOT replaced by a credential-file credit the worker's own gh
# could never spend.
rm -rf "$TMP/home-guard" "$TMP/O4t9"; gh_hosts_fixture "$TMP/home-guard"
printf 'EXTRA=1\n' > "$TMP/home-guard/keys.env"
out="$(bash "$TMP/c8.sh" "$LIB" "$TMP/bin-absent" "$TMP/O4t9" "$TMP/home-guard" 2>&1)"
pfx="$(printf '%s\n' "$out" | sed -n 's/^PFX<<\(.*\)>>$/\1/p')"
case "$pfx" in *"*) false || exit 98"*) rc=1 ;; *"*) "*"auth token"*) rc=0 ;; *) rc=1 ;; esac
ck "…the guard never credits a file the worker's own gh could not spend (no gh => REFUSED, not blessed)" $rc
if command -v perl >/dev/null 2>&1; then
  case "$pfx" in *"perl -e 'alarm 10; exec @ARGV' '/"*) rc=0 ;; *) rc=1; echo "      prefix=$pfx";; esac
  ck "…and its gh call is BOUNDED and ABSOLUTE (a hung gh would freeze the controller's whole cycle)" $rc
  case "$pfx" in *"|| gh auth token"*|*"|gh auth token"*) rc=1 ;; *) rc=0 ;; esac
  ck "…and no bare gh lookup survives in the guard (it is the build-time absolute path)" $rc
fi
# ⛔ AND THE GATE-SIDE PROBE IS BOUNDED TOO (recorded rule, README §"Two platform rules …": a plain
# `gh auth token` can hang for the life of the shell, rc=142 measured — and `wt_spawn` runs on the
# controller's single-threaded cycle). Asserted at the SOURCE: a runtime pin would have to hang for the
# whole alarm window to tell the difference. ⛔ THE BOUND HAS TWO LEGAL SPELLINGS, and the assertion
# accepts exactly those two: THROUGH `wt_bounded` (module-side probes) or the inline `alarm` the
# PANE-side guard must carry itself — the launch line runs in a fresh shell that never sources this
# module, so it cannot call the helper. Anything with NEITHER is an unbounded probe, which is the
# defect. The helper is then separately pinned: a name without the alarm would be a gate that reads
# correct and enforces nothing.
n_unbounded="$(grep -n 'auth token' "$LIB" | grep -v ':[[:space:]]*#' | grep -v 'wt_bounded' | grep -vc 'alarm')"
[ "$n_unbounded" = "0" ] && rc=0 || rc=1
ck "every non-comment 'gh auth token' in the library is BOUNDED (through the helper, or the pane's own alarm)" $rc
awk '/^wt_bounded\(\) \{/,/^}/' "$LIB" | grep -q "alarm shift; exec @ARGV" && rc=0 || rc=1
ck "…and that helper really arms perl's alarm (the bound is not only a name)" $rc
# ⛔ A `hosts.yml` THAT IS A DIRECTORY IS NOT A CREDENTIAL (review finding): `-s` was true for any
# object of non-zero size, and a directory has one. What refuses it here is the TOKEN READ — grep on a
# directory fails, so the value test cannot pass (`[ -f ]` alone does not decide it, measured: with the
# `-f` arm relaxed but the grep kept, this pin still passes). The pin covers the pre-fix predicate as a
# whole, which was presence without a value.
rm -rf "$TMP/home-dirgh" "$TMP/O4u"; mkdir -p "$TMP/home-dirgh/.config/gh/hosts.yml"
out="$(FAKE_UNAME=Linux bash "$TMP/c2.sh" "$LIB" "$TMP/bin-absent" "$TMP/O4u" "$TMP/tmux4u.log" "$TMP/home-dirgh" 2>&1)"
case "$out" in *"rc=1"*) rc=0 ;; *) rc=1; echo "      $out";; esac
ck "a hosts.yml that is a DIRECTORY is not provision (refused, never spawned)" $rc
# ... while the SAME pre-existing server is fine when IT carries the token (the positive control), so
# the refusal is a probe of where the credential actually is, not a blanket ban.
rm -rf "$TMP/O4i"
out="$(FAKE_UNAME=Linux KEEP_CALLER_TOKEN=1 GH_TOKEN=ghp_from_caller_env TMUX_STATE="$TMP/srv-sessions" TMUX_SERVER_GH_TOKEN=1 bash "$TMP/c2.sh" "$LIB" "$TMP/bin-absent" "$TMP/O4i" "$TMP/tmux4i.log" "$TMP/home-nocred" 2>&1)"
case "$out" in *"rc=0"*) rc=0 ;; *) rc=1; echo "      $out";; esac
ck "…but the same server WITH the token spawns (the worker inherits the server's env)" $rc
# ⛔ AN EMPTY VALUE IS NOT PROVISION, in either place (review finding 3): `GH_TOKEN=` in keys.env and a
# server variable set to the empty string both read as "provisioned" to a presence test.
rm -rf "$TMP/O4j"; mkdir -p "$TMP/home-emptytok/.config/gh"
printf 'github.com:\n' > "$TMP/home-emptytok/.config/gh/hosts.yml"
printf 'export GH_TOKEN=\n' > "$TMP/home-emptytok/keys.env"
: > "$TMP/home-emptytok/.config/gh/hosts.yml"   # no credential file either: the keys.env is all there is
out="$(FAKE_UNAME=Linux bash "$TMP/c2.sh" "$LIB" "$TMP/bin-absent" "$TMP/O4j" "$TMP/tmux4j.log" "$TMP/home-emptytok" 2>&1)"
case "$out" in *"rc=1"*) rc=0 ;; *) rc=1; echo "      $out";; esac
ck "an empty \`GH_TOKEN=\` in keys.env is REFUSED (an assignment with no value is not a credential)" $rc
rm -rf "$TMP/O4l"
out="$(FAKE_UNAME=Linux TMUX_STATE="$TMP/srv-sessions" TMUX_SERVER_GH_TOKEN=1 TMUX_SERVER_TOKEN_VAL='' bash "$TMP/c2.sh" "$LIB" "$TMP/bin-absent" "$TMP/O4l" "$TMP/tmux4l.log" "$TMP/home-nocred" 2>&1)"
case "$out" in *"rc=1"*) rc=0 ;; *) rc=1; echo "      $out";; esac
ck "an empty server variable is REFUSED too (presence is not provision on the server side)" $rc
# ⛔ …AND A BLANK ONE (review finding, 2026-10-23, measured): `-n "$v"` credited three spaces, and gh
# rejects that value (`Failed to log in to github.com using token (GH_TOKEN)`), so the gate blessed a
# worker that could never authenticate. Every arm now asks for a non-SPACE character, not for bytes.
rm -rf "$TMP/O4l2"
out="$(FAKE_UNAME=Linux TMUX_STATE="$TMP/srv-sessions" TMUX_SERVER_GH_TOKEN=1 TMUX_SERVER_TOKEN_VAL='   ' bash "$TMP/c2.sh" "$LIB" "$TMP/bin-absent" "$TMP/O4l2" "$TMP/tmux4l2.log" "$TMP/home-nocred" 2>&1)"
case "$out" in *"rc=1"*) rc=0 ;; *) rc=1; echo "      $out";; esac
ck "a WHITESPACE-only server variable is REFUSED (blank is not a credential on the server side either)" $rc
# ⛔ AND A BLANK CALLER TOKEN, on the arm that credits the caller's own environment (review finding):
# `[ -n "$GH_TOKEN$GITHUB_TOKEN" ]` credited spaces, and the spawn then handed the worker no usable token.
rm -rf "$TMP/O4l3"
out="$(FAKE_UNAME=Linux KEEP_CALLER_TOKEN=1 GH_TOKEN='   ' bash "$TMP/c2.sh" "$LIB" "$TMP/bin-absent" "$TMP/O4l3" "$TMP/tmux4l3.log" "$TMP/home-nocred" 2>&1)"
case "$out" in *"rc=1"*) rc=0 ;; *) rc=1; echo "      $out";; esac
ck "a WHITESPACE-only CALLER token is REFUSED (the caller arm asks for a value, like every other arm)" $rc
# ⛔ A `HOME=` LINE INSIDE keys.env MUST NOT REPOINT THE VALIDATED HOME (review finding 2, measured:
# the worker ended with `worker_HOME=/home/cmux`, where no hosts.yml exists — the exact credential-less
# worker this gate exists to refuse, reported as provisioned). Driven: the prefix is EXECUTED and $HOME
# is read back, so this pins the ORDER of the launch line, not its text.
rm -rf "$TMP/O4m"; mkdir -p "$TMP/home-repoint/.config/gh"
gh_hosts_fixture "$TMP/home-repoint"
printf 'HOME=/home/cmux\nexport DEEPSEEK_API_KEY=sk-x\n' > "$TMP/home-repoint/keys.env"
cat > "$TMP/c6.sh" <<'SH'
set -u
PATH="$2:$PATH"; O="$3"; WT_DIR="$O/state"; WT_TABLE_TTL=0; mkdir -p "$WT_DIR"
. "$1"
printf 'PFX<<%s>>\n' "$(wt_launcher_env "$4")"
SH
out="$(bash "$TMP/c6.sh" "$LIB" "$TMP/bin-absent" "$TMP/O4m" "$TMP/home-repoint" 2>&1)"
pfx="$(printf '%s\n' "$out" | sed -n 's/^PFX<<\(.*\)>>$/\1/p')"
worker_home="$(env -i PATH=/usr/bin:/bin HOME=/nonexistent O="$TMP/O4m" "$BASH" -c "$pfx; printf '%s' \"\$HOME\"" 2>/dev/null)"
[ "$worker_home" = "$TMP/home-repoint" ] && rc=0 || { rc=1; echo "      worker_HOME=$worker_home  prefix=$pfx"; }
ck "a HOME= line inside keys.env does NOT repoint the validated HOME (re-asserted after the source)" $rc
# ⛔ PRESENCE IS NOT PROVISION (same review): an EMPTY hosts.yml (a `gh auth logout` leftover) or a
# keys.env that names no token reads as provisioned and starts exactly the credential-less worker the
# gate exists to stop.
rm -rf "$TMP/home-empty" "$TMP/home-notok" "$TMP/O4g"
mkdir -p "$TMP/home-empty/.config/gh"; : > "$TMP/home-empty/.config/gh/hosts.yml"
mkdir -p "$TMP/home-notok"; printf 'export DEEPSEEK_API_KEY=%s\n' sk-x > "$TMP/home-notok/keys.env"
for h in home-empty home-notok; do
  rm -rf "$TMP/O-$h"
  out="$(FAKE_UNAME=Linux bash "$TMP/c2.sh" "$LIB" "$TMP/bin-absent" "$TMP/O-$h" "$TMP/tmux-$h.log" "$TMP/$h" 2>&1)"
  case "$out" in *"rc=1"*) rc=0 ;; *) rc=1; echo "      $h: $out";; esac
  ck "$h (a file that carries no credential) is REFUSED, not read as provisioned" $rc
done
# ⛔ A HOST ENTRY IS NOT A TOKEN (review finding, 2026-10-23, measured). The probe used to be `-s`
# ("exists and is non-empty"), so a `hosts.yml` of `{}` — or one whose `github.com:` entry lost its
# `oauth_token:` line, which is what a `gh auth logout` leftover or a half-written file looks like —
# read as PROVISIONED and started the credential-less worker: `wt_spawn` returned 0 AND wrote
# `home=…`, so the lane was recorded as started while it could never reach `gh`. That is the exact
# silent dead lane #2210 records, reported as provisioned. Only a VALUE counts, the same rule the
# keys.env arm already applies.
rm -rf "$TMP/home-hostonly" "$TMP/home-braces" "$TMP/home-unreadable" "$TMP/home-emptyval" "$TMP/home-hashval"
mkdir -p "$TMP/home-hostonly/.config/gh" "$TMP/home-braces/.config/gh" "$TMP/home-emptyval/.config/gh" "$TMP/home-hashval/.config/gh"
printf 'github.com:\n    user: fixture\n    git_protocol: https\n' > "$TMP/home-hostonly/.config/gh/hosts.yml"
printf '{}\n' > "$TMP/home-braces/.config/gh/hosts.yml"
# ⛔ A VALUE IS NOT A QUOTED EMPTY, AND A COMMENT IS NOT A VALUE (review finding, 2026-10-23, measured):
# the value regex accepted `#` as a character, so `oauth_token:   # redacted` — a YAML NULL, i.e. a file
# that carries no token at all — read as provision. Driven against the shipped probe: `emptyval` and
# `hashval` both come back `no oauth token found for github.com`.
printf 'github.com:\n    user: fixture\n    oauth_token: ""\n' > "$TMP/home-emptyval/.config/gh/hosts.yml"
printf 'github.com:\n    user: fixture\n    oauth_token:   # redacted\n' > "$TMP/home-hashval/.config/gh/hosts.yml"
# An UNREADABLE hosts.yml is a refusal too (mode 000). Skipped as root, where 000 is readable and the
# assertion would test the runtime user rather than the probe.
unreadable_cases=(hostonly braces emptyval hashval)
if [ "$(id -u)" != "0" ]; then
  gh_hosts_fixture "$TMP/home-unreadable"; chmod 000 "$TMP/home-unreadable/.config/gh/hosts.yml"
  unreadable_cases+=(unreadable)
fi
for h in "${unreadable_cases[@]}"; do
  rm -rf "$TMP/O-$h"
  out="$(FAKE_UNAME=Linux bash "$TMP/c2.sh" "$LIB" "$TMP/bin-absent" "$TMP/O-$h" "$TMP/tmux-$h.log" "$TMP/home-$h" 2>&1)"
  case "$out" in *"rc=1"*) rc=0 ;; *) rc=1; echo "      $h: $out";; esac
  ck "$h (hosts.yml carries no readable token VALUE) is REFUSED, not read as provisioned" $rc
  grep -q 'new-session' "$TMP/tmux-$h.log" 2>/dev/null && rc=1 || rc=0
  ck "…$h: and tmux is never asked to start the worker" $rc
  [ -f "$TMP/O-$h/state/worker-lane-8" ] && rc=1 || rc=0
  ck "…$h: and no worker record is left behind" $rc
done
# ⛔ THE FILE PROBE ITSELF, PINNED DIRECTLY (review finding, 2026-10-23). The loop above runs through
# `wt_spawn`, which takes the `gh` arm whenever gh is on PATH — so on any developer box or runner the
# FILE fallback is never executed, and a mutation that gutted its value regex (or replaced the whole
# predicate with `grep -qE '^'`) left every pin above green. `wt_gh_hosts_value` is the fallback as a
# function precisely so it can be pinned on its own: one file shape in, one rc out, gh irrelevant.
val_rc() { ( set -u; . "$LIB" >/dev/null 2>&1; wt_gh_hosts_value "$1" >/dev/null 2>&1; printf '%s' "$?" ); }
printf 'github.com:\n    user: fixture\n    oauth_token: gho_value0token\n    git_protocol: https\n' > "$TMP/hosts-real.yml"
[ "$(val_rc "$TMP/hosts-real.yml")" = "0" ] && rc=0 || rc=1
ck "wt_gh_hosts_value: a real oauth_token VALUE is a credential (rc 0)" $rc
for h in hostonly braces emptyval hashval; do
  [ "$(val_rc "$TMP/home-$h/.config/gh/hosts.yml")" = "1" ] && rc=0 || rc=1
  ck "wt_gh_hosts_value: $h is NOT a credential (no token value: absent, empty, or a YAML comment)" $rc
done
printf 'github.com:\n    oauth_token: "gho_quoted"\n' > "$TMP/hosts-quoted.yml"
[ "$(val_rc "$TMP/hosts-quoted.yml")" = "0" ] && rc=0 || rc=1
ck "wt_gh_hosts_value: a QUOTED token still counts (the quote group is optional, not a ban)" $rc
# POSITIVE CONTROL for the same predicate: the SAME host entry PLUS a token spawns, so the refusals
# above are a probe of the token and not a ban on `hosts.yml`.
rm -rf "$TMP/O-hostok" "$TMP/home-hostok"; gh_hosts_fixture "$TMP/home-hostok"
out="$(FAKE_UNAME=Linux bash "$TMP/c2.sh" "$LIB" "$TMP/bin-absent" "$TMP/O-hostok" "$TMP/tmux-hostok.log" "$TMP/home-hostok" 2>&1)"
case "$out" in *"rc=0"*) rc=0 ;; *) rc=1; echo "      hostok: $out";; esac
ck "…while the same hosts.yml WITH an oauth_token spawns (the probe reads the token, not the file)" $rc
# ⛔ AND THE PROBE MUST ASK `gh`, NOT THE FILE (P1 review finding, 2026-10-23, measured). gh's DEFAULT
# store is the system credential store, and in that mode gh REMOVES the plaintext `oauth_token:` from
# `hosts.yml`. A file grep therefore refuses a FULLY PROVISIONED box on every spawn, forever — and a
# refusal starts no session, so nothing can ever change the answer. That is #2210's own loop, one
# predicate over, and it would newly apply to the macOS launchd arm this PR gates. Driven with a `gh`
# that reports a token and a hosts.yml that is the keyring SHAPE (no oauth_token line).
mkdir -p "$TMP/bin-keyring"; cp "$TMP/stub/cmux" "$TMP/stub/tmux" "$TMP/stub/uname" "$TMP/bin-keyring/"
cat > "$TMP/bin-keyring/gh" <<'SH'
#!/usr/bin/env bash
# stands in for `gh auth token` on a box whose credential lives in the OS keyring
echo gho_from_keyring
exit 0
SH
chmod +x "$TMP/bin-keyring/gh"
rm -rf "$TMP/O-keyring" "$TMP/home-keyring"; mkdir -p "$TMP/home-keyring/.config/gh"
printf 'github.com:\n    user: fixture\n    git_protocol: https\n' > "$TMP/home-keyring/.config/gh/hosts.yml"
out="$(FAKE_UNAME=Linux bash "$TMP/c2.sh" "$LIB" "$TMP/bin-keyring" "$TMP/O-keyring" "$TMP/tmux-keyring.log" "$TMP/home-keyring" 2>&1)"
case "$out" in *"rc=0"*) rc=0 ;; *) rc=1; echo "      keyring: $out";; esac
ck "a KEYRING-only hosts.yml spawns when gh reports a token (the probe asks gh, not the file)" $rc
grep -q 'TMUX new-session -d -s lane-8' "$TMP/tmux-keyring.log" 2>/dev/null && rc=0 || { rc=1; cat "$TMP/tmux-keyring.log" 2>/dev/null; }
ck "…and that box really gets a worker (the P1 is a refusal loop, not a cosmetic flag)" $rc
rm -rf "$TMP/O4d"
# ⛔ The `none` refusal is PROTECTIVE and stays: a box with no cmux answer AND no tmux binary has no
# surface at all and must not pretend otherwise.
cat > "$TMP/c3.sh" <<'SH'
set -u
O="$3"; WT_DIR="$O/state"; WT_TABLE_TTL=0; LOG="$O/test.log"
mkdir -p "$WT_DIR"          # still the caller's PATH here — this one is narrowed to the box below
PATH="$2"                  # NO tmux anywhere, including the real /usr/bin/tmux a dev box carries
export CMUX_ABSENT=1
. "$1"
echo "launcher=$(wt_launcher)"
wt_spawn "lane-8" "/tmp" 'bash /tmp/lane.sh 8 b o/r'; echo "rc=$?"
SH
out="$(bash "$TMP/c3.sh" "$LIB" "$TMP/bin-bare" "$TMP/O4d" 2>&1)"
case "$out" in *"launcher=none"*) rc=0 ;; *) rc=1; echo "      $out";; esac
ck "no cmux AND no tmux => launcher=none (a box with no surface at all is still reported, not guessed)" $rc
case "$out" in *"rc=1"*) rc=0 ;; *) rc=1; echo "      $out";; esac
ck "…and the spawn is REFUSED" $rc
grep -q 'tmux=absent' "$TMP/O4d/test.log" && grep -q 'cmux tree rc=' "$TMP/O4d/test.log" && rc=0 || { rc=1; cat "$TMP/O4d/test.log" 2>/dev/null; }
ck "…with a message that names BOTH surfaces AND what the cmux probe answered (rc, not binary presence)" $rc
# ⛔ And a box that cannot produce a CONTRACT is refused, not started credential-less. Two arms:
# the function itself refuses an empty HOME, and the knob an operator sets is the one that is used
# (a silent fall-through to $HOME would make "the credential lives at X" a suggestion).
rm -rf "$TMP/O4e"
cat > "$TMP/c4.sh" <<'SH'
set -u
PATH="$2:$PATH"; O="$3"; WT_DIR="$O/state"; WT_TABLE_TTL=0; mkdir -p "$WT_DIR"
. "$1"
wt_launcher_env "" >/dev/null 2>&1; echo "env_empty_rc=$?"
echo "home_knob=$(WT_WORKER_HOME="$4" wt_launcher_home)"
echo "home_plain=$(HOME="$4" wt_launcher_home)"
SH
gh_hosts_fixture "$TMP/home-k"
out="$(bash "$TMP/c4.sh" "$LIB" "$TMP/bin-absent" "$TMP/O4e" "$TMP/home-k" 2>&1)"
case "$out" in *"env_empty_rc=1"*) rc=0 ;; *) rc=1; echo "      $out";; esac
ck "no HOME to build a contract with => wt_launcher_env refuses (there is nothing to export)" $rc
case "$out" in *"home_knob=$TMP/home-k"*) rc=0 ;; *) rc=1; echo "      $out";; esac
ck "…WT_WORKER_HOME is the HOME used (the operator's answer, not a fall-through)" $rc
case "$out" in *"home_plain=$TMP/home-k"*) rc=0 ;; *) rc=1; echo "      $out";; esac
ck "…and with no knob, a HOME that HOLDS the credential is the one chosen" $rc
# ⛔ …AND A HOME PROVISIONED BY ITS OWN `keys.env` IS ALSO CHOSEN (review finding, 2026-10-23,
# measured): selection asked the gh STORE only, while acceptance also credits `keys.env`, so a box whose
# working credential is that file (this file's own header's measured shape) was refused forever — a
# false refusal is the #2210 loop, and it starts no session, so nothing can ever change the answer.
rm -rf "$TMP/home-keysonly" "$TMP/O4e2"; mkdir -p "$TMP/home-keysonly"
printf 'export GH_TOKEN=ghp_keysonly\n' > "$TMP/home-keysonly/keys.env"
out="$(bash "$TMP/c4.sh" "$LIB" "$TMP/bin-absent" "$TMP/O4e2" "$TMP/home-keysonly" 2>&1)"
case "$out" in *"home_plain=$TMP/home-keysonly"*) rc=0 ;; *) rc=1; echo "      $out";; esac
ck "…and a HOME whose own keys.env carries the token is chosen too (selection and acceptance agree)" $rc
# ⛔ A BOX WITH NO SURFACE AT ALL is now the ONLY state in which the launcher answers `none`: main
# made tmux a real Linux surface (#2210 — with the HOME+keys.env contract), so `$TMP/O4` above IS a
# tmux surface and correctly produces NO refusal. The #2366 assertions therefore get their own
# no-surface run, on `bin-bare` (no cmux answer AND no tmux binary, PATH narrowed so a dev box's real
# /usr/bin/tmux cannot be found). Without this they read a TMUX run's artifacts and pass vacuously —
# the "yesterday's fixture" failure a rebase manufactures.
rm -rf "$TMP/O4n"; mkdir -p "$TMP/O4n"
cat > "$TMP/c1n.sh" <<'SH'
set -u
O="$3"; WT_DIR="$O/state"; WT_TABLE_TTL=0; LOG="$O/test.log"
mkdir -p "$WT_DIR"
PATH="$2"
export CMUX_ABSENT=1 CMUX_LOG="$O/cmux-calls.log"; : > "$CMUX_LOG"
. "$1"
wt_startup_banner > "$O/banner.txt" 2>/dev/null
wt_spawn "lane-8" "/tmp" 'bash /tmp/lane.sh 8 b o/r'; echo "rc=$?"
SH
out="$(FAKE_UNAME=Linux bash "$TMP/c1n.sh" "$LIB" "$TMP/bin-bare" "$TMP/O4n" 2>&1)"
case "$out" in *"rc=1"*) rc=0 ;; *) rc=1; echo "      $out";; esac
ck "…WITHOUT falling back to tmux (no surface at all) — the spawn is REFUSED" $rc
grep -q 'REFUSED lane-8' "$TMP/O4n/test.log" && rc=0 || rc=1
ck "…and the refusal reaches the controller's log, not just stderr" $rc
# ⛔ THE PROBE COST IS A PINNED FACT, not a sentence in a comment (the comment said "one probe" while
# the banner cost three, then two, as the code changed under it). The MERGED cost is FIVE, and the
# arithmetic is the union of both sides: the banner's own read + the reason's read (2), then the same
# two on the refused spawn (2), PLUS main's own re-measurement of `cmux tree` rc on the refusal line
# (1) — main adds that probe deliberately, because a presence test sent the operator to the wrong
# fault (#2210). A rebase that left this at 4 would be pinning the pre-merge probe count.
n_mux="$(grep -c '^CMUX ' "$TMP/O4n/cmux-calls.log" 2>/dev/null || echo 0)"
[ "$n_mux" = "5" ] && rc=0 || rc=1
printf '      cmux calls for one banner + one refused spawn: %s (want 5)\n' "$n_mux"
ck "…and the whole refusal costs FIVE probes (2 banner + 3 spawn, main's rc re-measure included), not creeping further" $rc
# ⛔ THE PROBE'S OWN ANSWER MUST REACH THE OPERATOR (agent-infra#2366). `cmux tree --json >/dev/null
# 2>&1` keeps the decision and discards the reason, so a launcher-less box prints `launcher=none
# (cmux=yes, uname=Linux)` — a verdict with no cause, indistinguishable from a tty gate, a TERM gate,
# a drifted output shape, or a daemon that is not there. The assertion is on the BANNER FILE ALONE,
# and on the stub's own error string — a fact only the surface can supply.
grep -q '^\[startup\] worker launcher=none (cmux=yes, uname=Linux) — cmux tree --json failed (rc=1): cmux: no daemon from the surface-stub$' "$TMP/O4n/banner.txt" && rc=0 || { rc=1; cat "$TMP/O4n/banner.txt" 2>/dev/null; }
ck "the startup banner carries the PROBE'S own reason, not just the verdict" $rc
grep -q 'why: cmux tree --json failed (rc=1): cmux: no daemon from the surface-stub' "$TMP/O4n/test.log" && rc=0 || { rc=1; cat "$TMP/O4n/test.log"; }
ck "…and so does the per-spawn REFUSAL line" $rc
# An EMPTY-stderr failure must still be diagnosable (a daemon that dies silently is the case where a
# bare verdict is least useful), and the rc must be the probe's own.
cat > "$TMP/c1e.sh" <<'SH'
set -u
O="$3"; WT_DIR="$O/state"; WT_TABLE_TTL=0; mkdir -p "$WT_DIR"
PATH="$2"
. "$1"
wt_startup_banner
SH
out="$(FAKE_UNAME=Linux CMUX_TREE_SILENT=1 bash "$TMP/c1e.sh" "$LIB" "$TMP/bin-bare" "$TMP/O4e" 2>&1)"
case "$out" in *"failed (rc=7): no stderr, exit status only"*) rc=0 ;; *) rc=1; echo "      $out" ;; esac
ck "…and a silent failure still names the exit status instead of an empty cause" $rc
# Control: a HEALTHY terminal surface appends NO reason, and a healthy launchd Mac (`tmux`, which is
# DELIBERATE and not a degrade) must NOT be stamped `failed:` either.
cat > "$TMP/c1h.sh" <<'SH'
set -u
PATH="$2:$PATH"; O="$3"; WT_DIR="$O/state"; WT_TABLE_TTL=0; mkdir -p "$WT_DIR"
export CMUX_LOG="$O/cmux.log"; : > "$CMUX_LOG"
. "$1"
wt_startup_banner
SH
out="$(FAKE_UNAME=Linux bash "$TMP/c1h.sh" "$LIB" "$TMP/bin-cmux" "$TMP/O4h" 2>&1)"
case "$out" in "[startup] worker launcher=terminal (cmux=yes, uname=Linux)") rc=0 ;; *) rc=1; echo "      $out" ;; esac
ck "a healthy cmux surface reports the launcher with NO reason suffix appended" $rc
out="$(FAKE_UNAME=Darwin CMUX_ABSENT=1 bash "$TMP/c1h.sh" "$LIB" "$TMP/bin-absent" "$TMP/O4d" 2>&1)"
case "$out" in "[startup] worker launcher=tmux (cmux=yes, uname=Darwin)") rc=0 ;; *) rc=1; echo "      $out" ;; esac
ck "a healthy launchd Mac (`tmux`) is NOT stamped with a failed: reason" $rc
# ⛔ THE WIRING IS THE ARTIFACT. `wt_startup_banner` existing is not the fix; the CONTROLLER printing
# it is. Measured workaround-shape this test exists to catch: the banner could be perfect and
# orch-loop.sh could still emit its own line (or none).
grep -q '^wt_startup_banner >> "\$LOG"$' "$LOOP" && rc=0 || rc=1
ck "orch-loop.sh emits the module's banner (the wiring, not just the function)" $rc

# A PROBE FLIP: the launcher's read fails and the reason's read succeeds. Unreachable through any
# settled surface, and therefore never exercised — it exists so a transient failure does not print a
# stale cause. Driven here or it is a branch nothing proves.
cat > "$TMP/c1f.sh" <<'SH'
set -u
O="$3"; WT_DIR="$O/state"; WT_TABLE_TTL=0; mkdir -p "$WT_DIR"
PATH="$2"
. "$1"
wt_startup_banner
SH
out="$(FAKE_UNAME=Linux CMUX_FAIL_ONCE="$TMP/flip.marker" bash "$TMP/c1f.sh" "$LIB" "$TMP/bin-bare" "$TMP/O4f" 2>&1)"
case "$out" in *"answered on re-probe (it failed on the launcher read): a probe flip"*) rc=0 ;; *) rc=1; echo "      $out" ;; esac
ck "a probe flip reports the flip, not a cause it cannot know" $rc

echo
echo "── D) the launchd surface still uses tmux (the other place it is correct) ──"
# ⛔ HERMETIC (review finding, 2026-10-22): this block used to reach the machine's own credential —
# `$HOME` or the hardcoded `/tmp/cell-home` — so on a CI runner (no gh auth step, no /tmp/cell-home) the
# spawn was refused and the assertion reded on a clean box while passing on a cell. The launchd path
# gets an explicit WT_WORKER_HOME fixture, exactly as §C does.
gh_hosts_fixture "$TMP/home-d"
cat > "$TMP/d1.sh" <<'SH'
set -u
PATH="$2:$PATH"; O="$3"; WT_DIR="$O/state"; WT_TABLE_TTL=0; mkdir -p "$WT_DIR"
export CMUX_ABSENT=1 TMUX_LOG="$4" TMUX_KILLED="$5" TMUX_PANE_PID=4194305
# The session list carries this worker (and a peer, to prove the membership test is exact).
export TMUX_STATE="$O/tmux-sessions"; printf 'lane-9\nmerge-9\n' > "$TMUX_STATE"
: > "$TMUX_LOG"; : > "$TMUX_KILLED"
. "$1"
echo "launcher=$(wt_launcher)"
wt_spawn "lane-9" "/tmp" 'bash /tmp/lane.sh 9 b o/r'; echo "spawn_rc=$?"
echo "alive=$(wt_alive lane-9 && echo yes || echo no)"
wt_close lane-9; echo "close_rc=$?"
echo "record=$([ -f "$WT_DIR/worker-lane-9" ] && echo kept || echo gone)"
SH
out="$(FAKE_UNAME=Darwin WT_WORKER_HOME="$TMP/home-d" bash "$TMP/d1.sh" "$LIB" "$TMP/bin-darwin" "$TMP/O5" "$TMP/tmux5.log" "$TMP/killed5.log" 2>&1)"
case "$out" in *"launcher=tmux"*) rc=0 ;; *) rc=1; echo "      $out";; esac
ck "no cmux + macOS => launcher=tmux (launchd cannot reach the cmux daemon by design)" $rc
grep -q 'TMUX new-session -d -s lane-9' "$TMP/tmux5.log" && rc=0 || rc=1
ck "…and the spawn is a tmux session, exactly as before" $rc
case "$out" in *"alive=yes"*) rc=0 ;; *) rc=1;; esac
ck "…whose liveness is read from the session list" $rc
grep -qx '=lane-9' "$TMP/killed5.log" && rc=0 || rc=1
ck "…and closed with an EXACT session target (=name), never a prefix match" $rc
case "$out" in *"record=gone"*) rc=0 ;; *) rc=1; echo "      $out";; esac
ck "…removing its record once the kill is verified" $rc

echo
echo "── E) the census is fail-CLOSED: an unreadable surface counts as ALIVE ──"
cat > "$TMP/e1.sh" <<'SH'
set -u
PATH="$2:$PATH"; O="$3"; WT_DIR="$O/state"; WT_TABLE_TTL=0; mkdir -p "$WT_DIR"
printf 'kind=terminal\nid=term_x\nworkspace=ws_x\n' > "$WT_DIR/worker-fix-3"
export CMUX_TREE_FAIL=1
. "$1"
echo "alive=$(wt_alive fix-3 && echo yes || echo no)"
echo "count=$(wt_count fix-)"
echo "absent=$(wt_alive fix-999 && echo yes || echo no)"
SH
out="$(bash "$TMP/e1.sh" "$LIB" "$TMP/bin-cmux" "$TMP/O6" 2>&1)"
case "$out" in *"alive=yes"*) rc=0 ;; *) rc=1; echo "      $out";; esac
ck "a worker whose surface cannot be read is ALIVE, not dead (a kill needs positive evidence)" $rc
case "$out" in *"count=1"*) rc=0 ;; *) rc=1;; esac
ck "…so the concurrency ceiling keeps BINDING when the daemon is in trouble" $rc
case "$out" in *"absent=no"*) rc=0 ;; *) rc=1;; esac
ck "…while a name this box has never heard of is NOT a worker" $rc

echo
echo "── F) a kill that cannot be PROVEN is not reported as one ──"
cat > "$TMP/f1.sh" <<'SH'
set -u
PATH="$2:$PATH"; O="$3"; WT_DIR="$O/state"; WT_TABLE_TTL=0; mkdir -p "$WT_DIR"
# The surface still lists the workspace after `terminal close` (a daemon that ignored the close).
export CMUX_TREE_JSON='{"workspaces":[{"id":"ws_fix-4","name":"wt-fix-4"}],"screens":[{"id":"s1","workspace_id":"ws_fix-4","layout":{"root":{"tab_ids":["t1"]}}}],"tabs":[{"id":"t1","content_id":"term_fix-4"}],"terminals":[{"id":"term_fix-4","running":true}]}'
printf 'kind=terminal\nid=term_fix-4\nworkspace=ws_fix-4\n' > "$WT_DIR/worker-fix-4"
. "$1"
wt_close fix-4; echo "close_rc=$?"
echo "record=$([ -f "$WT_DIR/worker-fix-4" ] && echo kept || echo gone)"
SH
out="$(bash "$TMP/f1.sh" "$LIB" "$TMP/bin-cmux" "$TMP/O7" 2>&1)"
case "$out" in *"close_rc=1"*) rc=0 ;; *) rc=1; echo "      $out";; esac
ck "a worker still present after the close returns non-zero" $rc
case "$out" in *"record=kept"*) rc=0 ;; *) rc=1;; esac
ck "…and its record is KEPT, so the next cycle retries instead of leaking the slot" $rc

echo
echo "── G) the named primitive, when the installed CLI has it ──"
cat > "$TMP/g1.sh" <<'SH'
set -u
PATH="$2:$PATH"; O="$3"; WT_DIR="$O/state"; WT_TABLE_TTL=0; mkdir -p "$WT_DIR"
export CMUX_HOST=1 CMUX_LOG="$4" WT_MACHINE=vm-abc; : > "$CMUX_LOG"
. "$1"
echo "grammar=$(wt_grammar)"
wt_spawn "merge-5" "/tmp" 'bash /tmp/merge-one.sh --argv /tmp/a'; echo "rc=$?"
SH
out="$(bash "$TMP/g1.sh" "$LIB" "$TMP/bin-host" "$TMP/O8" "$TMP/cmux8.log" 2>&1)"
case "$out" in *"grammar=surface"*) rc=0 ;; *) rc=1; echo "      $out";; esac
ck "a CLI with the \`surface\` scope selects that grammar" $rc
grep -q 'CMUX surface new-terminal --machine vm-abc --cwd /tmp --no-open -- /bin/bash .*run-merge-5.sh' "$TMP/cmux8.log" && rc=0 || rc=1
ck "…and spawns with the named primitive: --machine/--cwd/--no-open and the run script" $rc
grep -qx 'grammar=surface' "$TMP/O8/state/worker-merge-5" && rc=0 || rc=1
ck "…recording which grammar produced it" $rc

echo
echo "── I) a surface-grammar worker is TRACKED BY ITS TERMINAL ID (it has no workspace name) ──"
# ⛔ `surface new-terminal` takes no name, so the layout grammar's `wt-<worker>` workspace does not
# exist for it. Keying the census on that name alone read such a worker DEAD: the caps stopped
# binding, `sess()` re-spawned the same PR every cycle, and dispatch-merge released a claim while the
# lane ran. The id from the record is the handle, so the census must resolve it.
cat > "$TMP/i1.sh" <<'SH'
set -u
PATH="$2:$PATH"; O="$3"; WT_DIR="$O/state"; WT_TABLE_TTL=0; mkdir -p "$WT_DIR"
export CMUX_HOST=1 CMUX_LOG="$4" WT_MACHINE=vm-abc
# the tree knows the terminal by ID and by no workspace name at all
export CMUX_TREE_JSON='{"workspaces":[],"screens":[],"tabs":[],"terminals":[{"id":"term_host42","running":true}]}'
: > "$CMUX_LOG"
. "$1"
wt_spawn "merge-5" "/tmp" 'bash /tmp/merge-one.sh --argv /tmp/a'; echo "rc=$?"
echo "alive=$(wt_alive merge-5 && echo yes || echo no)"
echo "count=$(wt_count merge-)"
SH
out="$(bash "$TMP/i1.sh" "$LIB" "$TMP/bin-host" "$TMP/O9" "$TMP/cmux9.log" 2>&1)"
case "$out" in *"alive=yes"*) rc=0 ;; *) rc=1; echo "      $out";; esac
ck "a worker whose surface has no workspace name is still ALIVE (resolved by terminal id)" $rc
case "$out" in *"count=1"*) rc=0 ;; *) rc=1;; esac
ck "…and the concurrency ceiling COUNTS it" $rc
# The same census, with the terminal no longer running: a POSITIVE read, so DEAD is allowed.
cat > "$TMP/i2.sh" <<'SH'
set -u
PATH="$2:$PATH"; O="$3"; WT_DIR="$O/state"; WT_TABLE_TTL=0; mkdir -p "$WT_DIR"
export CMUX_TREE_JSON='{"workspaces":[],"screens":[],"tabs":[],"terminals":[{"id":"term_host42","running":false}]}'
printf 'kind=terminal\nid=term_host42\nworkspace=\n' > "$WT_DIR/worker-merge-5"
. "$1"
echo "alive=$(wt_alive merge-5 && echo yes || echo no)"
SH
out="$(bash "$TMP/i2.sh" "$LIB" "$TMP/bin-host" "$TMP/O10" 2>&1)"
case "$out" in *"alive=no"*) rc=0 ;; *) rc=1; echo "      $out";; esac
ck "…and a terminal the daemon says is NOT running reads DEAD (a positive read, not a guess)" $rc

echo
echo "── J) an unreadable tmux session list is UNKNOWN, never 'no sessions' ──"
# ⛔ The 2026-10-20 polarity bug, second half: `tmux ls || true` folded a failed read into an empty
# list, so a broken socket read as "every tmux worker is gone" — `wt_count` stopped binding the caps
# and `wt_close` DELETED the record of a session that was still running.
cat > "$TMP/j1.sh" <<'SH'
set -u
PATH="$2:$PATH"; O="$3"; WT_DIR="$O/state"; WT_TABLE_TTL=0; mkdir -p "$WT_DIR"
export CMUX_ABSENT=1 TMUX_STATE="$O/tmux-sessions" TMUX_LOG="$O/tmux.log" TMUX_KILLED="$O/killed.log" TMUX_PANE_PID=4194305
export TMUX_LS_FAIL=1
printf 'merge-9\n' > "$TMUX_STATE"
printf 'kind=tmux\ncwd=/tmp\n' > "$WT_DIR/worker-merge-9"
. "$1"
echo "alive=$(wt_alive merge-9 && echo yes || echo no)"
echo "count=$(wt_count merge-)"
wt_close merge-9; echo "close_rc=$?"
echo "record=$([ -f "$WT_DIR/worker-merge-9" ] && echo kept || echo gone)"
SH
out="$(FAKE_UNAME=Darwin bash "$TMP/j1.sh" "$LIB" "$TMP/bin-darwin" "$TMP/O11" 2>&1)"
case "$out" in *"alive=yes"*) rc=0 ;; *) rc=1; echo "      $out";; esac
ck "a failed tmux read leaves its worker ALIVE (unknown is alive)" $rc
case "$out" in *"count=1"*) rc=0 ;; *) rc=1;; esac
ck "…so the caps keep binding through a broken socket" $rc
case "$out" in *"close_rc=1"*) rc=0 ;; *) rc=1;; esac
ck "…and a close it cannot VERIFY returns non-zero" $rc
case "$out" in *"record=kept"*) rc=0 ;; *) rc=1;; esac
ck "…keeping the record, so the reap retries instead of claiming a kill it never proved" $rc
# Control: tmux's REAL absent answer still reads as no sessions (otherwise the fix would brick a box
# that simply has no server, which is the normal state on a fresh Mac).
cat > "$TMP/j2.sh" <<'SH'
set -u
PATH="$2:$PATH"; O="$3"; WT_DIR="$O/state"; WT_TABLE_TTL=0; mkdir -p "$WT_DIR"
export CMUX_ABSENT=1 TMUX_STATE="$O/none" TMUX_LOG="$O/tmux.log"
. "$1"
printf 'kind=tmux\ncwd=/tmp\n' > "$WT_DIR/worker-merge-9"
echo "alive=$(wt_alive merge-9 && echo yes || echo no)"
SH
out="$(FAKE_UNAME=Darwin bash "$TMP/j2.sh" "$LIB" "$TMP/bin-darwin" "$TMP/O12" 2>&1)"
case "$out" in *"alive=no"*) rc=0 ;; *) rc=1; echo "      $out";; esac
ck "…while 'no server running' (the real absent answer) is still a positive EMPTY read" $rc
echo
echo "── K) an unlinked socket under a LIVE server is UNKNOWN — never 'no sessions' ──"
# ⛔ MEASURED (tmux 3.4, 2026-10-23): remove the socket FILE of a running server and `tmux ls` answers
# `error connecting to <socket> (No such file or directory)`, rc 1, WHILE ITS PANES KEEP RUNNING. An arm
# added by this change matched that as a positive EMPTY read, so the census printed every tmux worker
# DEAD: `wt_count` stopped binding the caps and `wt_close` went on to delete a live worker's record —
# the polarity rule at the top of the module inverted, on the surface a cell now uses for every worker.
cat > "$TMP/k1.sh" <<'SH'
set -u
PATH="$2:$PATH"; O="$3"; WT_DIR="$O/state"; WT_TABLE_TTL=0; mkdir -p "$WT_DIR"
export CMUX_ABSENT=1 TMUX_STATE="$O/tmux-sessions" TMUX_LOG="$O/tmux.log" TMUX_KILLED="$O/killed.log" TMUX_PANE_PID=4194305
export TMUX_LS_UNLINKED=1
printf 'lane-31\n' > "$TMUX_STATE"
printf 'kind=tmux\ncwd=/tmp\n' > "$WT_DIR/worker-lane-31"
. "$1"
echo "alive=$(wt_alive lane-31 && echo yes || echo no)"
echo "count=$(wt_count lane-)"
wt_close lane-31; echo "close_rc=$?"
echo "record=$([ -f "$WT_DIR/worker-lane-31" ] && echo kept || echo gone)"
SH
out="$(FAKE_UNAME=Darwin bash "$TMP/k1.sh" "$LIB" "$TMP/bin-darwin" "$TMP/O13b" 2>&1)"
case "$out" in *"alive=yes"*) rc=0 ;; *) rc=1; echo "      $out";; esac
ck "an unlinked socket leaves its worker ALIVE (unknown is alive)" $rc
case "$out" in *"count=1"*) rc=0 ;; *) rc=1;; esac
ck "…so the caps keep binding while the socket is unreachable" $rc
case "$out" in *"record=kept"*) rc=0 ;; *) rc=1;; esac
ck "…and a live worker's record is NOT deleted for a census that could not read it" $rc

echo
echo "── L) an unrecordable tmux session is closed by EXACT name, never a prefix ──"
# ⛔ P1 review finding, 2026-10-23, MEASURED: `tmux kill-session -t fix-8` is a PREFIX match and really
# kills a live `fix-82` (rc 0). The record-write cleanup must therefore pin `=fix-8` — the shape
# `wt_close` already uses — or the failure path of one lane kills a peer's mid-work worker, whose record
# still reads alive.
rm -rf "$TMP/home-l" "$TMP/O13c"; gh_hosts_fixture "$TMP/home-l"
cat > "$TMP/l1.sh" <<'SH'
set -u
PATH="$2:$PATH"; O="$3"; WT_DIR="$O/state"; WT_TABLE_TTL=0; LOG="$O/test.log"
mkdir -p "$WT_DIR"
export CMUX_ABSENT=1 TMUX_LOG="$O/tmux.log" WT_WORKER_HOME="$4" TMUX_STATE="$O/sessions" TMUX_KILLED="$O/killed.log" TMUX_SERVER_EXISTS=1
unset GH_TOKEN GITHUB_TOKEN
printf 'fix-82\n' > "$TMUX_STATE"      # a PEER lane whose name EXTENDS the one we spawn
: > "$TMUX_KILLED"
. "$1"
chmod 500 "$WT_DIR"                      # the record cannot be written
wt_spawn fix-8 /tmp 'true' 2>/dev/null; echo "rc=$?"
chmod 700 "$WT_DIR"
echo "killed=[$(tr '\n' ' ' < "$TMUX_KILLED")]"
echo "sessions=[$(tr '\n' ' ' < "$TMUX_STATE")]"
SH
out="$(bash "$TMP/l1.sh" "$LIB" "$TMP/bin-absent" "$TMP/O13c" "$TMP/home-l" 2>&1)"
case "$out" in *"rc=1"*) rc=0 ;; *) rc=1; echo "      $out";; esac
ck "a tmux spawn whose record cannot be written FAILS (no untrackable worker)" $rc
case "$out" in *"killed=[=fix-8 ]"*) rc=0 ;; *) rc=1; echo "      $out";; esac
ck "…and the cleanup names the session EXACTLY (=fix-8), not by prefix" $rc
case "$out" in *"fix-82"*) rc=0 ;; *) rc=1; echo "      $out";; esac
ck "…so a peer session whose name extends ours (fix-82) is still alive" $rc

echo
echo "── M) a server probe that cannot ANSWER must not credit a caller token ──"
# ⛔ P2 review finding, 2026-10-23, MEASURED (fail-open): `wt_tmux_has_server` folded "no answer"
# (the bound fired) into "no server", so a SLOW server credited the caller's `GH_TOKEN` — while that
# server keeps its OWN environment, so the new session does not inherit it: a dead lane, reported
# provisioned. The probe is three-valued now (0 answers · 1 absent · 3 no answer) and only a POSITIVE
# absence may credit.
rm -rf "$TMP/O13d" "$TMP/home-m"; mkdir -p "$TMP/home-m"
cat > "$TMP/m1.sh" <<'SH'
set -u
PATH="$2:$PATH"; O="$3"; WT_DIR="$O/state"; WT_TABLE_TTL=0; mkdir -p "$WT_DIR"
export CMUX_ABSENT=1 TMUX_LOG="$O/tmux.log" TMUX_SERVER_SLOW=1 WT_PROBE_TIMEOUT=1 WT_WORKER_HOME="$4"
export GH_TOKEN=ghp_caller_only
. "$1"
if pfx="$(wt_launcher_env "$4" 2>/dev/null)"; then echo "verdict=CREDITED"; else echo "verdict=refused"; fi
echo "prefix=[${pfx:-}]"
SH
out="$(bash "$TMP/m1.sh" "$LIB" "$TMP/bin-absent" "$TMP/O13d" "$TMP/home-m" 2>&1)"
case "$out" in *"verdict=refused"*) rc=0 ;; *) rc=1; echo "      $out";; esac
ck "a server probe that cannot ANSWER refuses — it does not credit the caller's token" $rc
# ⛔ A RECORD-LESS `chain-*` SESSION IS COUNTED TOO (review finding on this diff). dispatch-merge.sh
# spawns and counts `chain-<N>` workers, so a chain the census cannot see is a cap that reads low — and
# on a cell tmux is the only surface, so this covers the whole worker population there.
cat > "$TMP/j3.sh" <<'SH'
set -u
PATH="$2:$PATH"; O="$3"; WT_DIR="$O/state"; WT_TABLE_TTL=0; mkdir -p "$WT_DIR"
export CMUX_ABSENT=1 TMUX_STATE="$O/tmux-sessions" TMUX_LOG="$O/tmux.log"
printf 'chain-7\n' > "$TMUX_STATE"      # no state/worker-chain-7: the session name is the only record
. "$1"
echo "alive=$(wt_alive chain-7 && echo yes || echo no)"
echo "count=$(wt_count chain-)"
SH
out="$(FAKE_UNAME=Darwin bash "$TMP/j3.sh" "$LIB" "$TMP/bin-darwin" "$TMP/O12b" 2>&1)"
case "$out" in *"alive=yes"*) rc=0 ;; *) rc=1; echo "      $out";; esac
ck "a record-less chain-* session is ALIVE (the name is the contract, not the ledger)" $rc
case "$out" in *"count=1"*) rc=0 ;; *) rc=1;; esac
ck "…and it is COUNTED, so the chain cap reads the real population" $rc

echo
echo "── K) the census memo is a FILE, so a cycle's questions are ONE daemon read ──"
# ⛔ Every call site reads the table through `$(wt_table)`, so the in-shell memo never survived the
# subshell: three questions produced three `cmux tree` probes. Pinned here as a COUNT, because the
# claim ("one daemon read per table") is otherwise unobservable from outside.
cat > "$TMP/k1.sh" <<'SH'
set -u
PATH="$2:$PATH"; O="$3"; WT_DIR="$O/state"; WT_TABLE_TTL=10; mkdir -p "$WT_DIR"
export CMUX_LOG="$4"; : > "$CMUX_LOG"
. "$1"
printf 'kind=terminal\nid=term_host42\nworkspace=\n' > "$WT_DIR/worker-merge-5"
export CMUX_TREE_JSON='{"workspaces":[],"screens":[],"tabs":[],"terminals":[{"id":"term_host42","running":true}]}'
x="$(wt_alive merge-5 && echo yes)"; y="$(wt_count merge-)"; z="$(wt_alive merge-5 && echo yes)"
echo "answers=$x/$y/$z probes=$(grep -c 'CMUX tree' "$CMUX_LOG")"
SH
out="$(bash "$TMP/k1.sh" "$LIB" "$TMP/bin-host" "$TMP/O13" "$TMP/cmux13.log" 2>&1)"
case "$out" in *"probes=1"*) rc=0 ;; *) rc=1; echo "      $out";; esac
ck "three separate census questions cost ONE daemon read (the memo survives the subshell)" $rc
case "$out" in *"answers=yes/1/yes"*) rc=0 ;; *) rc=1; echo "      $out";; esac
ck "…and the memo answers all three correctly" $rc

echo
echo "── L) a spawn that cannot RECORD itself is not a success ──"
# ⛔ A terminal created without a record is untrackable: the census still sees the surface (the slot is
# held) while `wt_close` has no id to close, so the worker holds a slot the reaper can never free.
cat > "$TMP/l1.sh" <<'SH'
set -u
PATH="$2:$PATH"; O="$3"; WT_DIR="$O/state"; WT_TABLE_TTL=0; mkdir -p "$WT_DIR"
export CMUX_LOG="$4" CMUX_CLOSED="$5"; : > "$CMUX_LOG"; : > "$CMUX_CLOSED"
mkdir -p "$WT_DIR/worker-lane-7"          # the record path is a DIRECTORY: the write must fail
. "$1"
wt_spawn "lane-7" "/tmp" 'bash /tmp/lane.sh 7 b o/r'; echo "rc=$?"
SH
out="$(bash "$TMP/l1.sh" "$LIB" "$TMP/bin-cmux" "$TMP/O14" "$TMP/cmux14.log" "$TMP/closed14.log" 2>&1)"
case "$out" in *"rc=1"*) rc=0 ;; *) rc=1; echo "      $out";; esac
ck "a record that cannot be written FAILS the spawn (no untrackable worker)" $rc
grep -q 'REFUSED lane-7' <<<"$out" && rc=0 || rc=1
ck "…naming the worker and the reason" $rc
[ -s "$TMP/closed14.log" ] && rc=0 || rc=1
ck "…and CLOSING the terminal it had just created instead of leaking it" $rc

echo
echo "── M) a daemon answer the parser cannot read is UNKNOWN, not 'every worker is dead' ──"
# ⛔ The census's readability test was "did the daemon print something". A reply the parser refuses (a
# banner line before the JSON, a shape that drifted between cmux builds) is non-empty and unparseable:
# every terminal record then read DEAD, the caps stopped binding, and `wt_close` DELETED a live
# worker's record — a false PASS on the one gate whose whole job is proving a kill.
cat > "$TMP/m1.sh" <<'SH'
set -u
PATH="$2:$PATH"; O="$3"; WT_DIR="$O/state"; WT_TABLE_TTL=0; mkdir -p "$WT_DIR"
# A warning line first, then perfectly valid JSON that says the terminal IS running.
export CMUX_TREE_RAW='warning: cmux 0.1.1 available
{"workspaces":[],"screens":[],"tabs":[],"terminals":[{"id":"term_live","running":true}]}'
printf 'kind=terminal\nid=term_live\nworkspace=\n' > "$WT_DIR/worker-merge-77"
. "$1"
echo "alive=$(wt_alive merge-77 && echo yes || echo no)"
echo "count=$(wt_count merge-)"
wt_close merge-77; echo "close_rc=$?"
echo "record=$([ -f "$WT_DIR/worker-merge-77" ] && echo kept || echo gone)"
SH
out="$(bash "$TMP/m1.sh" "$LIB" "$TMP/bin-cmux" "$TMP/O15" 2>&1)"
case "$out" in *"alive=yes"*) rc=0 ;; *) rc=1; echo "      $out";; esac
ck "an unparseable census reply leaves its worker ALIVE" $rc
case "$out" in *"count=1"*) rc=0 ;; *) rc=1;; esac
ck "…so the caps keep binding when a cmux build prints a banner" $rc
case "$out" in *"close_rc=1"*) rc=0 ;; *) rc=1;; esac
ck "…and a close it cannot verify returns non-zero" $rc
case "$out" in *"record=kept"*) rc=0 ;; *) rc=1;; esac
ck "…instead of deleting a live worker's record (a false PASS on the reap gate)" $rc
# ⛔ SYNTAX IS NOT SHAPE. A reply that PARSES but no longer carries the tree (an envelope, a renamed
# `terminals`) used to produce a table of `dead` rows with the probe reporting SUCCESS — the same
# false PASS by a quieter route, and the header records that cmux builds already differ in shape.
cat > "$TMP/m2.sh" <<'SH'
set -u
PATH="$2:$PATH"; O="$3"; WT_DIR="$O/state"; WT_TABLE_TTL=0; mkdir -p "$WT_DIR"
export CMUX_TREE_RAW='{"data":{"workspaces":[],"screens":[],"tabs":[],"terminals":[{"id":"term_live","running":true}]}}'
printf 'kind=terminal
id=term_live
workspace=\n' > "$WT_DIR/worker-merge-78"
. "$1"
echo "alive=$(wt_alive merge-78 && echo yes || echo no)"
echo "count=$(wt_count merge-)"
wt_close merge-78; echo "close_rc=$?"
echo "record=$([ -f "$WT_DIR/worker-merge-78" ] && echo kept || echo gone)"
SH
out="$(bash "$TMP/m2.sh" "$LIB" "$TMP/bin-cmux" "$TMP/O17" 2>&1)"
case "$out" in *"alive=yes"*"count=1"*"close_rc=1"*"record=kept"*) rc=0 ;; *) rc=1; echo "      $out";; esac
ck "a PARSEABLE but drifted tree shape is UNKNOWN too (alive, counted, close unproven, record kept)" $rc

echo
echo "── N) a worker the CENSUS sees but this box has no RECORD of is still reaped ──"
# ⛔ The census resolves a record-less `wt-<worker>` workspace on purpose (a wiped $O/state, a lane from
# an older harness). `wt_close` used to address only tmux in that case, so such a worker held its slot
# forever and logged "could NOT be proven gone" every cycle.
cat > "$TMP/n1.sh" <<'SH'
set -u
PATH="$2:$PATH"; O="$3"; WT_DIR="$O/state"; WT_TABLE_TTL=0; mkdir -p "$WT_DIR"
export CMUX_LOG="$4"; : > "$CMUX_LOG"
T="$O/tree"
printf '%s\n' '{"workspaces":[{"id":"ws_lane9","name":"wt-lane-9"}],"screens":[{"id":"s1","workspace_id":"ws_lane9","layout":{"root":{"tab_ids":["t1"]}}}],"tabs":[{"id":"t1","content_id":"term_x"}],"terminals":[{"id":"term_x","running":true}]}' > "$T.1"
printf '%s\n' '{"workspaces":[],"screens":[],"tabs":[],"terminals":[]}' > "$T.last"
# phase 1: the daemon answers the same thing every time
export CMUX_TREE_RAW="$(cat "$T.1")"
. "$1"
echo "alive=$(wt_alive lane-9 && echo yes || echo no)"
echo "count=$(wt_count lane-)"
# phase 2: the close reads TWICE (once to resolve the surface, once to verify it is gone)
unset CMUX_TREE_RAW; export CMUX_TREE_SEQ="$T"
wt_close lane-9; echo "close_rc=$?"
SH
out="$(bash "$TMP/n1.sh" "$LIB" "$TMP/bin-cmux" "$TMP/O16" "$TMP/cmux16.log" 2>&1)"
case "$out" in *"alive=yes"*) rc=0 ;; *) rc=1; echo "      $out";; esac
ck "a record-less durable terminal is seen by the census" $rc
case "$out" in *"count=1"*) rc=0 ;; *) rc=1;; esac
ck "…and counted against the cap" $rc
grep -q 'CMUX terminal close term_x' "$TMP/cmux16.log" && rc=0 || { rc=1; cat "$TMP/cmux16.log"; }
ck "…and the reap closes its TERMINAL, resolved by the workspace name" $rc
grep -q 'CMUX workspace rm ws_lane9' "$TMP/cmux16.log" && rc=0 || rc=1
ck "…and removes that workspace" $rc
case "$out" in *"close_rc=0"*) rc=0 ;; *) rc=1; echo "      $out";; esac
ck "…reporting a VERIFIED close (the second read says it is gone)" $rc

echo
echo "── O) the PRINTED table carries WORKERS, not the census's internal key spaces ──"
# ⛔ The probe resolves a worker two ways (`w:<worker>`, `t:<terminal-id>`) and the table is what every
# consumer reads. Those internal rows leaked into the printed table, so `report.sh` counted one cmux
# worker as three "sessions" — the exact surface an operator reads to answer "is this box busy".
cat > "$TMP/o1.sh" <<'SH'
set -u
PATH="$2:$PATH"; O="$3"; WT_DIR="$O/state"; WT_TABLE_TTL=0; mkdir -p "$WT_DIR"
export CMUX_TREE_JSON='{"workspaces":[{"id":"ws_a","name":"wt-lane-1"},{"id":"ws_b","name":"wt-lane-2"}],"screens":[{"id":"sa","workspace_id":"ws_a","layout":{"root":{"tab_ids":["ta"]}}},{"id":"sb","workspace_id":"ws_b","layout":{"root":{"tab_ids":["tb"]}}}],"tabs":[{"id":"ta","content_id":"term_a"},{"id":"tb","content_id":"term_b"}],"terminals":[{"id":"term_a","running":true},{"id":"term_b","running":true}]}'
. "$1"
echo "--- table:"
wt_table
SH
out="$(bash "$TMP/o1.sh" "$LIB" "$TMP/bin-cmux" "$TMP/O18" 2>&1)"
# ⛔ `sed '1,/PATTERN/d'` is NOT "skip to the marker": when the pattern matches on line 1, the range
# has no second match and GNU sed deletes to EOF (measured — it produced zero rows from a full table).
rows="$(printf '%s\n' "$out" | awk 'f && NF {print} /^--- table:$/ {f=1}')"
[ "$(printf '%s\n' "$rows" | wc -l | tr -d ' ')" = "2" ] && rc=0 || { rc=1; printf '      rows=[%s] out=[%s]\n' "$rows" "$out"; }
ck "two durable-terminal workers print TWO rows (not six)" $rc
grep -qE '^[wt]:' <<<"$rows" && rc=1 || rc=0
ck "…and no internal \`w:\`/\`t:\` key row leaks into the printed table" $rc
printf '%s\n' "$rows" | awk -F'\t' '$1=="lane-1" && $2=="alive"{f=1} END{exit f?0:1}' && rc=0 || rc=1
ck "…the rows are the worker names with their verdict" $rc

echo
echo "── Q) an ABSENT session owner is a READING: nothing is listening, so nothing is running ──"
# ⛔ MEASURED 2026-10-24 (agent-infra#2653). The cmux daemon was not running and `cmux tree --json`
# answered `cannot connect to session socket …: Connection refused` with EMPTY stdout. The probe read
# that as UNREADABLE, every terminal record read UNKNOWN, and UNKNOWN counts as LIVE (the fail-closed
# rule below, which is right for a transient blip). The harness therefore counted 18 worker records
# whose logs had been silent for 26-30 HOURS as 18 live workers, `wt_close` could never PROVE a close,
# the review-lane ceiling stayed at 11/6 for 26 hours, no review was dispatched for the 8 NEEDS-REVIEW
# PRs, the PR queue could not drain, and the issue path stayed shut with 175 candidates waiting.
# A terminal lives INSIDE the session owner: if the owner is not running, the terminal is gone. That is
# a measurement — the same polarity the tmux half already implements.
cat > "$TMP/q1.sh" <<'SH'
set -u
PATH="$2:$PATH"; O="$3"; WT_DIR="$O/state"; WT_TABLE_TTL=0; mkdir -p "$WT_DIR"
export CMUX_TREE_ABSENT=1
# ⛔ AN ALREADY-ELAPSED WINDOW, NOT `WT_ABSENT_CONFIRM=0` (review round 7 of #2653): a zero knob would
# confirm on ONE sample — the conclusion the rule forbids — and the module now coerces it to 60. The
# switch that says "this outage has lasted" is this stamp, never the knob.
printf '%s\n' "$(( $(date +%s) - 600 ))" > "$WT_DIR/.wt-absent-since"
printf 'kind=terminal\nid=term_stale1\nworkspace=ws_stale1\n' > "$WT_DIR/worker-merge-91"
printf 'kind=terminal\nid=term_stale2\nworkspace=ws_stale2\n' > "$WT_DIR/worker-fix-92"
. "$1"
echo "alive=$(wt_alive merge-91 && echo yes || echo no)"
echo "merge=$(wt_count merge-)"
echo "fix=$(wt_count fix-)"
wt_close merge-91; echo "close_rc=$?"
echo "record=$([ -f "$WT_DIR/worker-merge-91" ] && echo kept || echo gone)"
SH
out="$(bash "$TMP/q1.sh" "$LIB" "$TMP/bin-cmux" "$TMP/O18" 2>&1)"
case "$out" in *"alive=no"*) rc=0 ;; *) rc=1; echo "      $out";; esac
ck "an absent daemon reads its terminal records DEAD (nothing is listening)" $rc
case "$out" in *"merge=0"*) rc=0 ;; *) rc=1; echo "      $out";; esac
ck "…so the REVIEW-lane census is 0, not 11 ghosts — the ceiling can free" $rc
case "$out" in *"fix=0"*) rc=0 ;; *) rc=1;; esac
ck "…and the fixer census with it (one polarity, every cap)" $rc
case "$out" in *"close_rc=0"*) rc=0 ;; *) rc=1; echo "      $out";; esac
ck "…a close is now PROVEN (the verification read can finally answer)" $rc
case "$out" in *"record=gone"*) rc=0 ;; *) rc=1;; esac
ck "…and the stale record is released instead of pinning a slot forever" $rc
# ⛔ THE OTHER DIRECTION, ON THE SAME FIXTURE: a daemon that ANSWERS but cannot be READ is a different
# state and must stay UNKNOWN. Without this half the change is a licence to declare every worker dead
# whenever the census is awkward, which is the false-PASS direction the polarity rule forbids.
cat > "$TMP/q2.sh" <<'SH'
set -u
PATH="$2:$PATH"; O="$3"; WT_DIR="$O/state"; WT_TABLE_TTL=0; mkdir -p "$WT_DIR"
export CMUX_TREE_FAIL=1
printf 'kind=terminal\nid=term_live1\nworkspace=ws_live1\n' > "$WT_DIR/worker-merge-93"
. "$1"
echo "alive=$(wt_alive merge-93 && echo yes || echo no)"
echo "merge=$(wt_count merge-)"
wt_close merge-93; echo "close_rc=$?"
echo "record=$([ -f "$WT_DIR/worker-merge-93" ] && echo kept || echo gone)"
SH
out="$(bash "$TMP/q2.sh" "$LIB" "$TMP/bin-cmux" "$TMP/O19" 2>&1)"
case "$out" in *"alive=yes"*"merge=1"*"close_rc=1"*"record=kept"*) rc=0 ;; *) rc=1; echo "      $out";; esac
ck "a FAILED (not absent) census read is still UNKNOWN: alive, counted, unprovable, record KEPT" $rc
# ⛔ AND THE WRAPPER IS NOT THE SIGNAL — THE ERRNO IS (review of #2653, P1). `cannot connect to session
# socket <path>: <reason>` is errno-agnostic, so it also carries `No such file or directory` (a
# repointed HOME / a wrong socket path) and `Permission denied` — BOTH reachable with the daemon and
# its terminals ALIVE. Matching the wrapper would empty the census and DELETE a lived worker's
# record, the P1 the tmux half's header records. Only an absent LISTENER (`Connection refused`) or the
# CLI's own `no server running` may empty it.
for _msg in 'cannot connect to session socket /tmp/x.sock: No such file or directory (os error 2)' \
            'cannot connect to session socket /tmp/x.sock: Permission denied (os error 13)' \
            'cannot connect to session socket /tmp/x.sock: Resource temporarily unavailable (os error 11)'; do
  cat > "$TMP/q3.sh" <<'SH'
set -u
PATH="$2:$PATH"; O="$3"; WT_DIR="$O/state"; WT_TABLE_TTL=0; mkdir -p "$WT_DIR"
export CMUX_TREE_ABSENT=1 CMUX_TREE_ABSENT_MSG="$4"
printf '%s\n' "$(( $(date +%s) - 600 ))" > "$WT_DIR/.wt-absent-since"   # an ELAPSED window
printf 'kind=terminal
id=term_live5
workspace=ws_live5
' > "$WT_DIR/worker-merge-95"
. "$1"
echo "alive=$(wt_alive merge-95 && echo yes || echo no)"
echo "count=$(wt_count merge-)"
SH
  out="$(bash "$TMP/q3.sh" "$LIB" "$TMP/bin-cmux" "$TMP/O20" "$_msg" 2>&1)"
  case "$out" in *"alive=yes"*"count=1"*) rc=0 ;; *) rc=1 ;; esac
  ck "the WRAPPER with a different errno is still UNKNOWN: ${_msg##*: }" $rc
done

# ⛔ ONE SAMPLE IS NOT A STATE (review round 5 of #2653). A terminal record carries no pid, so the
# absent-owner read is the ONLY thing that would justify deleting it — and a HARD-KILLED daemon never
# closes its ptys or signals its children, so an orphaned worker can outlive the owner. A restart
# window is seconds; the confirmation window is what keeps the 26h stall fixed without letting a single
# refusal sample empty the census.
cat > "$TMP/q4.sh" <<'SH'
set -u
PATH="$2:$PATH"; O="$3"; WT_DIR="$O/state"; WT_TABLE_TTL=0; mkdir -p "$WT_DIR"
export CMUX_TREE_ABSENT=1
printf 'kind=terminal\nid=term_open1\nworkspace=ws_open1\n' > "$WT_DIR/worker-merge-97"
. "$1"
echo "first=$(wt_alive merge-97 && echo yes || echo no)/$(wt_count merge-)"
echo "window=$([ -f "$WT_DIR/.wt-absent-since" ] && echo opened || echo none)"
# a SECOND sample, still inside the window -> still UNKNOWN
echo "second=$(wt_alive merge-97 && echo yes || echo no)/$(wt_count merge-)"
# an old window -> CONFIRMED
printf '%s\n' "$(( $(date +%s) - 600 ))" > "$WT_DIR/.wt-absent-since"
echo "confirmed=$(wt_alive merge-97 && echo yes || echo no)/$(wt_count merge-)"
SH
out="$(bash "$TMP/q4.sh" "$LIB" "$TMP/bin-cmux" "$TMP/O21" 2>&1)"
case "$out" in *"first=yes/1"*"window=opened"*"second=yes/1"*"confirmed=no/0"*) rc=0 ;; *) rc=1; echo "      $out";; esac
ck "the absent owner is CONFIRMED by two samples: one refusal keeps the caps binding, an elapsed window frees them" $rc
# …and a READABLE answer closes the window again (a restart must not inherit a stale verdict)
cat > "$TMP/q5.sh" <<'SH'
set -u
PATH="$2:$PATH"; O="$3"; WT_DIR="$O/state"; WT_TABLE_TTL=0; mkdir -p "$WT_DIR"
export CMUX_TREE_ABSENT=1
printf 'kind=terminal\nid=term_back1\nworkspace=ws_back1\n' > "$WT_DIR/worker-merge-98"
. "$1"
wt_table >/dev/null 2>&1 || true          # opens the window
echo "window=$([ -f "$WT_DIR/.wt-absent-since" ] && echo open || echo closed)"
unset CMUX_TREE_ABSENT; export CMUX_TREE_JSON='{"workspaces":[{"id":"ws_back1","name":"wt-merge-98"}],"screens":[{"id":"s1","workspace_id":"ws_back1","layout":{"root":{"tab_ids":["t1"]}}}],"tabs":[{"id":"t1","content_id":"term_back1"}],"terminals":[{"id":"term_back1","running":true}]}'
wt_table >/dev/null 2>&1 || true          # the FIRST read after the daemon answers again
echo "after-read=$([ -f "$WT_DIR/.wt-absent-since" ] && echo open || echo closed)"
echo "alive=$(wt_alive merge-98 && echo yes || echo no)"
SH
out="$(bash "$TMP/q5.sh" "$LIB" "$TMP/bin-cmux" "$TMP/O22" 2>&1)"
case "$out" in *"window=open"*"after-read=closed"*"alive=yes"*) rc=0 ;; *) rc=1; echo "      $out";; esac
ck "a READABLE census closes the absent window (a returning daemon is not judged by a stale one)" $rc

# ⛔ THE CAPTURE MUST NOT BE ABLE TO STOP THE PROBE (review round 6 of #2653). A redirect that cannot be
# opened makes bash SKIP the command, so an unwritable census dir would hide every row derived FROM THE
# DAEMON — the record-less workers the census exists to keep — and the caps would stop binding.
cat > "$TMP/q6.sh" <<'SH'
set -u
PATH="$2:$PATH"; O="$3"; mkdir -p "$O"
WT_DIR="$O/readonly/state"                     # the dir does NOT exist and cannot be created
export CMUX_TREE_JSON='{"workspaces":[{"id":"ws_r1","name":"wt-lane-31"}],"screens":[{"id":"s1","workspace_id":"ws_r1","layout":{"root":{"tab_ids":["t1"]}}}],"tabs":[{"id":"t1","content_id":"term_r1"}],"terminals":[{"id":"term_r1","running":true}]}'
WT_TABLE_TTL=0
. "$1"
echo "count=$(wt_count lane-)"
SH
out="$(bash "$TMP/q6.sh" "$LIB" "$TMP/bin-cmux" "$TMP/O23" 2>&1)"
case "$out" in *"count=1"*) rc=0 ;; *) rc=1; echo "      $out";; esac
ck "an UNWRITABLE census dir still READS the daemon (the capture cannot skip the probe)" $rc

# …and an unwritable absent-window is NAMED, because an inert release is the 26h stall again.
cat > "$TMP/q7.sh" <<'SH'
set -u
PATH="$2:$PATH"; O="$3"; mkdir -p "$O/state"
printf 'kind=terminal
id=term_w1
workspace=ws_w1
' > "$O/state/worker-merge-99"
chmod 500 "$O/state"
WT_DIR="$O/state"; WT_TABLE_TTL=0; export CMUX_TREE_ABSENT=1
. "$1"
wt_table >/dev/null 2>"$O/err.txt" || true
chmod 700 "$O/state"
echo "--- err:"; cat "$O/err.txt"
SH
out="$(bash "$TMP/q7.sh" "$LIB" "$TMP/bin-cmux" "$TMP/O24" 2>&1)"
case "$out" in *"UNWRITABLE"*) rc=0 ;; *) rc=1; echo "      $out";; esac
ck "an unwritable absent-window is NAMED (an inert release cannot pass as a bounded one)" $rc

# ⛔ AN RC!=0 REPLY IS NEVER THE CENSUS (review rounds 7-8 of #2653, P1). The probe discards it
# (`|| tree=""`). Round 6 had a second, merged-stream branch for an unwritable `$dir` that trusted a
# JSON-shaped answer regardless of rc — so the SAME bytes read `unknown`/count=1 with a writable dir and
# `dead`/count=0 without one. Round 8 removed that branch entirely (the capture moved to `$TMPDIR`), so
# this arm now pins the remaining rule: on a read-only state dir the reply is still discarded.
cat > "$TMP/q10.sh" <<'SH'
set -u
PATH="$2:$PATH"; O="$3"; WT_DIR="$O/state"; WT_TABLE_TTL=0; mkdir -p "$WT_DIR"
printf 'kind=terminal\nid=term_rc1\nworkspace=ws_rc1\n' > "$WT_DIR/worker-merge-96"
export CMUX_TREE_JSON='{"workspaces":[],"screens":[],"tabs":[],"terminals":[]}' CMUX_TREE_JSON_RC=3
# ⛔ FORCE THE CAPTURE TO BE UNOPENABLE, so the `else` arm (no stderr capture at all) is what runs.
# `chmod 500` on the STATE dir was inert here: round 8 moved the capture to `$TMPDIR`, exactly the
# assertion-inflation this arm had (it passed on origin/main too, i.e. it pinned nothing).
TMPDIR="$O/nope/absent"
. "$1"
echo "alive=$(wt_alive merge-96 && echo yes || echo no)"
echo "count=$(wt_count merge-)"
SH
out="$(bash "$TMP/q10.sh" "$LIB" "$TMP/bin-cmux" "$TMP/O27" 2>&1)"
case "$out" in *"alive=yes"*"count=1"*) rc=0 ;; *) rc=1; echo "      $out";; esac
ck "with NO usable capture the probe still runs and an rc!=0 reply is UNKNOWN (never the census)" $rc
# ⛔ AND THE SAME ARM WITH A *GOOD* REPLY PINS THE READ ITSELF (review round 12 of #2653): with no
# usable capture the probe must still be EXECUTED. Mutating the `else` branch to `tree=""; tree_err=""`
# (round 6's defect) left the rc assertion above green, because a discarded reply and a never-run probe
# are indistinguishable there — while it loses every daemon-derived row (the record-less workers the
# census keeps), i.e. the under-count direction.
cat > "$TMP/q10b.sh" <<'SH'
set -u
PATH="$2:$PATH"; O="$3"; WT_DIR="$O/state"; WT_TABLE_TTL=0; mkdir -p "$WT_DIR"
export CMUX_TREE_JSON='{"workspaces":[{"id":"ws_l31","name":"wt-lane-31"}],"screens":[{"id":"s1","workspace_id":"ws_l31","layout":{"root":{"tab_ids":["t1"]}}}],"tabs":[{"id":"t1","content_id":"term_l31"}],"terminals":[{"id":"term_l31","running":true}]}'
TMPDIR="$O/nope/absent"                    # no capture possible
. "$1"
echo "count=$(wt_count lane-)"
SH
out="$(bash "$TMP/q10b.sh" "$LIB" "$TMP/bin-cmux" "$TMP/O27b" 2>&1)"
case "$out" in *"count=1"*) rc=0 ;; *) rc=1; echo "      $out";; esac
ck "with NO usable capture a GOOD reply is still READ (a record-less worker is counted)" $rc

# ⛔ THE LATCH MUST SURVIVE THE SUBSHELL (review round 11 of #2653, P2). Every consumer calls
# `wt_table` in a command substitution, so round 9's in-shell variable latched nothing and the warning
# fired per read. TWO reads, EACH THROUGH A SUBSTITUTION, must produce exactly ONE warning.
cat > "$TMP/q19.sh" <<'SH'
set -u
PATH="$2:$PATH"; O="$3"; WT_DIR="$O/state"; WT_TABLE_TTL=0; mkdir -p "$WT_DIR"
printf 'kind=terminal\nid=term_lat\nworkspace=ws_lat\n' > "$WT_DIR/worker-merge-88"
chmod 500 "$WT_DIR"
export CMUX_TREE_ABSENT=1
. "$1"
a="$(wt_table 2>>"$O/warn.txt")"
b="$(wt_table 2>>"$O/warn.txt")"
chmod 700 "$WT_DIR"
echo "warns=$(grep -c UNWRITABLE "$O/warn.txt" 2>/dev/null || echo 0)"
echo "rows=$([ -n "$a" ] && [ -n "$b" ] && echo 2 || echo 0)"
SH
out="$(bash "$TMP/q19.sh" "$LIB" "$TMP/bin-cmux" "$TMP/O36" 2>&1)"
case "$out" in *"warns=1"*"rows=2"*) rc=0 ;; *) rc=1; echo "      $out";; esac
ck "the unwritable-window warning latches ONCE across two \`\$(wt_table)\` subshells" $rc

# ⛔ COERCION ORDER: `WT_ABSENT_CONFIRM=0` AND the documented small `CYC=5` TOGETHER (review round 11,
# P1). Each alone passed; the combination left the staleness bound at 4x5=20s — narrower than the 60s
# window — so every stamp was discarded before it could confirm. A 90s stamp must still confirm.
cat > "$TMP/q20.sh" <<'SH'
set -u
PATH="$2:$PATH"; O="$3"; WT_DIR="$O/state"; WT_TABLE_TTL=0; mkdir -p "$WT_DIR"
printf 'kind=terminal\nid=term_ord\nworkspace=ws_ord\n' > "$WT_DIR/worker-merge-87"
printf '%s\n' "$(( $(date +%s) - 90 ))" > "$WT_DIR/.wt-absent-since"
export CMUX_TREE_ABSENT=1 CYC=5 WT_ABSENT_CONFIRM=0
. "$1"
echo "count=$(wt_count merge-)"
SH
out="$(bash "$TMP/q20.sh" "$LIB" "$TMP/bin-cmux" "$TMP/O37" 2>&1)"
case "$out" in *"count=0"*) rc=0 ;; *) rc=1; echo "      $out";; esac
ck "WT_ABSENT_CONFIRM=0 + CYC=5 together still confirm (the bound is never narrower than the window)" $rc

# ⛔ A LEADING-ZERO `CYC` MUST NOT KILL THE *SOURCE* (review round 13 of #2653, P1). `case ''|*[!0-9]*)`
# accepts `08` and `[ 08 -ge 1 ]` is true, so `$(( 4 * 08 ))` read it as OCTAL, errored, and left
# `WT_ABSENT_STALE_MIN` UNBOUND — fatal at source time under `set -u` in ALL THREE consumers
# (orch-loop.sh, dispatch-merge.sh, report.sh): the controller exits before a cycle runs and KeepAlive
# relaunches a process that dies in the same place. Measured on the previous head, green on main.
cat > "$TMP/q21.sh" <<'SH'
set -u
O="$2"; mkdir -p "$O"
CYC=08
. "$1"
echo "loaded=yes stale=$WT_ABSENT_STALE_MIN"
SH
out="$(CYC=08 bash "$TMP/q21.sh" "$LIB" "$TMP/O38" 2>&1)"
case "$out" in *"loaded=yes stale=960"*) rc=0 ;; *) rc=1; echo "      $out";; esac
ck "CYC=08 cannot kill the source (the octal expansion is normalised, not class-checked)" $rc

# ⛔ A BAD `CYC` MUST NOT EMPTY THE CENSUS (review round 10 of #2653, P1). The staleness rule does
# arithmetic on CYC, which this module inherits from the environment (its consumers, `dispatch-merge.sh`
# and `report.sh`, do not coerce it) — and an arithmetic-expansion error TERMINATES wt_table before it
# prints, which every consumer reads as "this box has no workers".
cat > "$TMP/q15.sh" <<'SH'
set -u
PATH="$2:$PATH"; O="$3"; WT_DIR="$O/state"; WT_TABLE_TTL=0; mkdir -p "$WT_DIR"
printf 'kind=terminal\nid=term_cyc\nworkspace=ws_cyc\n' > "$WT_DIR/worker-merge-91b"
printf '%s\n' "$(( $(date +%s) - 600 ))" > "$WT_DIR/.wt-absent-since"
export CMUX_TREE_ABSENT=1 CYC=abc
. "$1"
echo "rows=$(wt_table | wc -l | tr -d ' ')"
SH
out="$(bash "$TMP/q15.sh" "$LIB" "$TMP/bin-cmux" "$TMP/O32" 2>&1)"
case "$out" in *"rows=1"*) rc=0 ;; *) rc=1; echo "      $out";; esac
ck "a non-numeric CYC cannot abort the census into an EMPTY table" $rc

# ⛔ A SANCTIONED SMALL CYCLE MUST STILL CONFIRM (review round 10 of #2653, P2): CYC floors at 5, and
# the staleness bound used to be 4xCYC (=20s) — narrower than the 60s confirmation window — so every
# stamp was discarded before it could confirm and the release never happened (the 26h stall, silently).
cat > "$TMP/q16.sh" <<'SH'
set -u
PATH="$2:$PATH"; O="$3"; WT_DIR="$O/state"; WT_TABLE_TTL=0; mkdir -p "$WT_DIR"
printf 'kind=terminal\nid=term_c5\nworkspace=ws_c5\n' > "$WT_DIR/worker-merge-90"
# 90s: OLDER than 4xCYC (20s) but YOUNGER than the confirmation window's 2x floor (120s) — the stamp
# must still confirm, which is exactly what a bound of 4xCYC alone would have destroyed.
printf '%s\n' "$(( $(date +%s) - 90 ))" > "$WT_DIR/.wt-absent-since"
export CMUX_TREE_ABSENT=1 CYC=5
. "$1"
echo "count=$(wt_count merge-)"
SH
out="$(bash "$TMP/q16.sh" "$LIB" "$TMP/bin-cmux" "$TMP/O33" 2>&1)"
case "$out" in *"count=0"*) rc=0 ;; *) rc=1; echo "      $out";; esac
ck "a small CYC (the documented floor) still confirms an absent owner (the bound is never narrower than the window)" $rc

# ⛔ A FUTURE STAMP IS DISCARDED (review round 10 of #2653): after a clock step the subtraction is
# negative, so neither rule fired and the release was pinned for the whole skew.
cat > "$TMP/q17.sh" <<'SH'
set -u
PATH="$2:$PATH"; O="$3"; WT_DIR="$O/state"; WT_TABLE_TTL=0; mkdir -p "$WT_DIR"
printf 'kind=terminal\nid=term_fut\nworkspace=ws_fut\n' > "$WT_DIR/worker-merge-89"
printf '%s\n' "$(( $(date +%s) + 7200 ))" > "$WT_DIR/.wt-absent-since"
export CMUX_TREE_ABSENT=1
. "$1"
echo "count=$(wt_count merge-)"
echo "window=$([ -f "$WT_DIR/.wt-absent-since" ] && echo open || echo none)"
# the file now carries TWO values ("<first_seen> <last_absent>"), so read the FIRST
echo "delta=$(($(awk '{print $1}' "$WT_DIR/.wt-absent-since" 2>/dev/null || echo 0) - $(date +%s)))"
SH
out="$(bash "$TMP/q17.sh" "$LIB" "$TMP/bin-cmux" "$TMP/O34" 2>&1)"
# ⛔ AND THE STAMP MUST HAVE BEEN REWRITTEN, not merely kept (review round 13): with the stamp KEPT the
# elapsed value is negative, so neither rule fires and `count=1`/`window=open` are equally true — the
# old assertion was green on the pre-round-10 code. A rewritten stamp is within the window of NOW; the
# seeded one was +7200.
# ⛔ NUMERIC, NOT A PATTERN (review round 14 of #2653): `$(( ))` never prints a leading `+`, so the
# previous `*"delta="+"7200"*` guard could not match and the arm was the tautology it claimed to replace
# (deleting the future-stamp rule left it green). A REWRITTEN stamp is ~0; a KEPT one is +7200.
_d=$(printf '%s\n' "$out" | sed -n 's/^delta=//p')
if case "$out" in *"count=1"*"window=open"*) true ;; *) false ;; esac \
   && [ -n "${_d:-}" ] && [ "${_d#-}" -lt 120 ] 2>/dev/null; then rc=0; else rc=1; echo "      $out"; fi
ck "a FUTURE stamp (a clock step) is discarded instead of pinning the release" $rc

# ⛔ CONTINUOUS ABSENCE MUST NOT LOOK STALE (review round 14 of #2653, P2). With a single FIRST-SEEN
# stamp, an outage longer than `WT_ABSENT_STALE_MIN` re-opened the window every bound and the rows
# flipped `dead` → `unknown` for a full window — a duty cycle instead of a fix (measured ~900s dead /
# ~60s unknown, repeating). The file carries "<first_seen> <last_absent>": continuity is judged on the
# LAST sample, confirmation on the FIRST, so a continuously observed absence stays confirmed.
cat > "$TMP/q22.sh" <<'SH'
set -u
PATH="$2:$PATH"; O="$3"; WT_DIR="$O/state"; WT_TABLE_TTL=0; mkdir -p "$WT_DIR"
printf 'kind=terminal\nid=term_long\nworkspace=ws_long\n' > "$WT_DIR/worker-merge-86"
now=$(date +%s)
printf '%s %s\n' "$(( now - 5000 ))" "$(( now - 5 ))" > "$WT_DIR/.wt-absent-since"   # long outage, fresh sample
export CMUX_TREE_ABSENT=1
. "$1"
echo "count=$(wt_count merge-)"
echo "first=$(awk '{print $1}' "$WT_DIR/.wt-absent-since")"
echo "last=$(awk '{print $2}' "$WT_DIR/.wt-absent-since")"
SH
out="$(bash "$TMP/q22.sh" "$LIB" "$TMP/bin-cmux" "$TMP/O39" 2>&1)"
_n=$(printf '%s\n' "$out" | sed -n 's/^count=//p')
_fl=$(printf '%s\n' "$out" | sed -n 's/^last=//p')
if [ "${_n:-1}" = "0" ] && [ -n "${_fl:-}" ]; then rc=0; else rc=1; echo "      $out"; fi
ck "a CONTINUOUS outage stays confirmed (first_seen kept, last_absent refreshed — no duty cycle)" $rc
# ⛔ AND THE REFRESH ITSELF IS PINNED (review round 15 of #2653, residual 2): the seeded `last` is
# already fresh, so dropping the refresh write left the arm above green — the other half of the
# duty-cycle fix. A sample whose `last` is 800s old (inside the bound) must come back ~now.
cat > "$TMP/q22b.sh" <<'SH'
set -u
PATH="$2:$PATH"; O="$3"; WT_DIR="$O/state"; WT_TABLE_TTL=0; mkdir -p "$WT_DIR"
printf 'kind=terminal\nid=term_ref\nworkspace=ws_ref\n' > "$WT_DIR/worker-merge-84"
now=$(date +%s)
printf '%s %s\n' "$(( now - 5000 ))" "$(( now - 800 ))" > "$WT_DIR/.wt-absent-since"
export CMUX_TREE_ABSENT=1
. "$1"
wt_table >/dev/null 2>&1 || true
echo "last_age=$(( $(date +%s) - $(awk '{print $2}' "$WT_DIR/.wt-absent-since") ))"
SH
out="$(bash "$TMP/q22b.sh" "$LIB" "$TMP/bin-cmux" "$TMP/O39b" 2>&1)"
_la=$(printf '%s\n' "$out" | sed -n 's/^last_age=//p')
if [ -n "${_la:-}" ] && [ "${_la#-}" -lt 60 ] 2>/dev/null; then rc=0; else rc=1; echo "      $out"; fi
ck "…and the continuity datum is REFRESHED on every absent sample (not just at window open)" $rc

# ⛔ A STALE STAMP CONFIRMS NOTHING (review round 9 of #2653, P1): the stamp records when an absent
# owner was FIRST seen, and nothing requires it to belong to the current outage — after an up-period in
# which NOTHING read the census (a deploy restart, a frozen cycle), the first sample of the next outage
# used to confirm immediately, freeing every cap and letting `wt_close` delete a live worker's record.
cat > "$TMP/q14.sh" <<'SH'
set -u
PATH="$2:$PATH"; O="$3"; WT_DIR="$O/state"; WT_TABLE_TTL=0; mkdir -p "$WT_DIR"
printf 'kind=terminal\nid=term_stale\nworkspace=ws_stale\n' > "$WT_DIR/worker-merge-92"
printf '%s\n' "$(( $(date +%s) - 4000 ))" > "$WT_DIR/.wt-absent-since"   # far older than any gap
export CMUX_TREE_ABSENT=1
. "$1"
echo "count=$(wt_count merge-)"
echo "window=$([ -f "$WT_DIR/.wt-absent-since" ] && echo open || echo none)"
SH
out="$(bash "$TMP/q14.sh" "$LIB" "$TMP/bin-cmux" "$TMP/O31" 2>&1)"
case "$out" in *"count=1"*"window=open"*) rc=0 ;; *) rc=1; echo "      $out";; esac
ck "a STALE stamp re-opens the window instead of confirming on one sample" $rc

# ⛔ AND THE KNOB IS NOT AN OFF-SWITCH (review round 7 of #2653, P2): `WT_ABSENT_CONFIRM=0` would
# confirm on ONE sample — the conclusion the rule forbids — and any `export` could set it. It is
# coerced, so the first sample still keeps the caps binding.
cat > "$TMP/q11.sh" <<'SH'
set -u
PATH="$2:$PATH"; O="$3"; WT_DIR="$O/state"; WT_TABLE_TTL=0; mkdir -p "$WT_DIR"
printf 'kind=terminal\nid=term_k0\nworkspace=ws_k0\n' > "$WT_DIR/worker-merge-95b"
export CMUX_TREE_ABSENT=1 WT_ABSENT_CONFIRM=0
. "$1"
echo "count=$(wt_count merge-)"
SH
out="$(bash "$TMP/q11.sh" "$LIB" "$TMP/bin-cmux" "$TMP/O28" 2>&1)"
case "$out" in *"count=1"*) rc=0 ;; *) rc=1; echo "      $out";; esac
ck "WT_ABSENT_CONFIRM=0 cannot disable the two-sample rule (an export is not a gate)" $rc

# ⛔ `08` PASSES A DIGIT GUARD AND ABORTS `$(( ))` (review round 8 of #2653, P2). The expansion error
# kills `wt_table` BEFORE it prints, and an empty census is indistinguishable from "this box has no
# workers": the caps stop binding and `wt_close` deletes a record it never looked at. The `10#`
# normalisation is what keeps a hand-edited stamp harmless.
cat > "$TMP/q12.sh" <<'SH'
set -u
PATH="$2:$PATH"; O="$3"; WT_DIR="$O/state"; WT_TABLE_TTL=0; mkdir -p "$WT_DIR"
printf 'kind=terminal\nid=term_oct\nworkspace=ws_oct\n' > "$WT_DIR/worker-merge-94"
printf '08\n' > "$WT_DIR/.wt-absent-since"          # a leading-zero stamp: NOT octal
export CMUX_TREE_ABSENT=1
. "$1"
# ⛔ A ROW, NOT A COUNT: epoch-8 is far older than the staleness bound, so since round 9 it is discarded
# and the record reads `unknown` — what must NOT happen is the arithmetic aborting the function before it
# prints (an empty table reads as "no workers anywhere").
echo "rows=$(wt_table | wc -l | tr -d ' ')"
SH
out="$(bash "$TMP/q12.sh" "$LIB" "$TMP/bin-cmux" "$TMP/O29" 2>&1)"
case "$out" in *"rows=1"*) rc=0 ;; *) rc=1; echo "      $out";; esac
ck "a leading-zero stamp (\`08\`) cannot abort the census into an EMPTY table" $rc
# ⛔ …AND THE SAME FOR THE SECOND FIELD (review round 15 of #2653, P1). Both writers emit
# "<first_seen> <last_absent>", and `_cont` reads the SECOND — so a leading-zero `last_absent` is the
# NORMAL-case operand, and it was class-checked but never `10#`-normalised: `08` re-parsed as octal,
# `wt_table` aborted before printing, and the empty table made `wt_close` delete a record it never
# looked at. q12's single-field seed cannot catch this.
cat > "$TMP/q12b.sh" <<'SH'
set -u
PATH="$2:$PATH"; O="$3"; WT_DIR="$O/state"; WT_TABLE_TTL=0; mkdir -p "$WT_DIR"
printf 'kind=terminal\nid=term_oct2\nworkspace=ws_oct2\n' > "$WT_DIR/worker-merge-85"
printf '%s 08\n' "$(( $(date +%s) - 600 ))" > "$WT_DIR/.wt-absent-since"   # field 2 is `08`
export CMUX_TREE_ABSENT=1
. "$1"
echo "rows=$(wt_table | wc -l | tr -d ' ')"
SH
out="$(bash "$TMP/q12b.sh" "$LIB" "$TMP/bin-cmux" "$TMP/O29b" 2>&1)"
case "$out" in *"rows=1"*) rc=0 ;; *) rc=1; echo "      $out";; esac
ck "a leading-zero LAST_ABSENT cannot abort the census either (the field the arithmetic reads)" $rc

# ⛔ ONLY THE ABSENT ANSWER MAY LEAVE THE WINDOW STANDING (review round 8 of #2653, P2). An answer that
# proves nothing either way (the ENOENT wrapper this module deliberately treats as UNKNOWN, a banner)
# used to leave an ancient stamp, so the NEXT absent sample confirmed immediately — a single-sample
# conclusion reached through a recovery path.
cat > "$TMP/q13.sh" <<'SH'
set -u
PATH="$2:$PATH"; O="$3"; WT_DIR="$O/state"; WT_TABLE_TTL=60; mkdir -p "$WT_DIR"
printf 'kind=terminal\nid=term_rec\nworkspace=ws_rec\n' > "$WT_DIR/worker-merge-93b"
. "$1"
export CMUX_TREE_ABSENT=1
wt_table >/dev/null 2>&1 || true                     # opens the window
echo "window-open=$([ -f "$WT_DIR/.wt-absent-since" ] && echo open || echo closed)"
unset CMUX_TREE_ABSENT
export CMUX_TREE_ABSENT=1 CMUX_TREE_ABSENT_MSG='cannot connect to session socket /tmp/x.sock: No such file or directory (os error 2)'
WT_TABLE_TTL=0;     # a non-absent, non-readable answer
wt_table >/dev/null 2>&1 || true
echo "window-after-other=$([ -f "$WT_DIR/.wt-absent-since" ] && echo open || echo closed)"
SH
out="$(bash "$TMP/q13.sh" "$LIB" "$TMP/bin-cmux" "$TMP/O30" 2>&1)"
case "$out" in *"window-open=open"*"window-after-other=closed"*) rc=0 ;; *) rc=1; echo "      $out";; esac
ck "an answer that is neither readable nor absent CLOSES the window (no single-sample confirmation later)" $rc

# ⛔ AND THE CLEAR MUST SURVIVE A FAILED RECORD WRITE (review round 10 of #2653, P2). Round 9 moved the
# clear BEFORE the record write because the owner has demonstrably answered by then; q8 only covers a
# SUCCESSFUL spawn (where the later tail clears anyway), so dropping that line stayed green.
mkdir -p "$TMP/home-q8b"; gh_hosts_fixture "$TMP/home-q8b"
cat > "$TMP/q18.sh" <<'SH'
set -u
PATH="$2:$PATH"; O="$3"; WT_DIR="$O/state"; WT_TABLE_TTL=0; mkdir -p "$WT_DIR"
export CMUX_LOG="$4"; : > "$CMUX_LOG"
WT_WORKER_HOME="$5"
mkdir -p "$WT_DIR/worker-merge-79"                 # the RECORD path is a directory: the write must fail
printf '%s\n' "$(( $(date +%s) - 600 ))" > "$WT_DIR/.wt-absent-since"
. "$1"
wt_spawn "merge-79" "/tmp" 'bash /tmp/w.sh 79 b o/r'; echo "spawn_rc=$?"
echo "window-after=$([ -f "$WT_DIR/.wt-absent-since" ] && echo open || echo closed)"
SH
out="$(bash "$TMP/q18.sh" "$LIB" "$TMP/bin-cmux" "$TMP/O35" "$TMP/cmux35.log" "$TMP/home-q8b" 2>&1)"
case "$out" in *"spawn_rc=1"*"window-after=closed"*) rc=0 ;; *) rc=1; echo "      $out";; esac
ck "the absent window closes even when the worker RECORD cannot be written (the owner answered)" $rc

# ⛔ THE SPAWN-CLEAR NEEDS A PIN, OR A REFACTOR THAT FOLDS IT INTO wt_forget STAYS GREEN (review
# round 7 of #2653). A terminal spawn PROVES the cmux owner answered, so it must close the absent
# window; a TMUX spawn proves nothing about that owner (and is exactly what the controller keeps doing
# during an outage), so it must NOT — otherwise the 60s timer restarts on every outage spawn and the
# 26h stall returns.
mkdir -p "$TMP/home-q8" "$TMP/home-q9"
gh_hosts_fixture "$TMP/home-q8"; gh_hosts_fixture "$TMP/home-q9"
cat > "$TMP/q8.sh" <<'SH'
set -u
PATH="$2:$PATH"; O="$3"; WT_DIR="$O/state"; WT_TABLE_TTL=0; mkdir -p "$WT_DIR"
export CMUX_LOG="$4"; : > "$CMUX_LOG"
WT_WORKER_HOME="$5"
printf '%s\n' "$(( $(date +%s) - 600 ))" > "$WT_DIR/.wt-absent-since"
. "$1"
echo "window-before=$([ -f "$WT_DIR/.wt-absent-since" ] && echo open || echo closed)"
wt_spawn "merge-77" "/tmp" 'bash /tmp/w.sh 77 b o/r'; echo "spawn_rc=$?"
echo "window-after=$([ -f "$WT_DIR/.wt-absent-since" ] && echo open || echo closed)"
SH
out="$(bash "$TMP/q8.sh" "$LIB" "$TMP/bin-cmux" "$TMP/O25" "$TMP/cmux25.log" "$TMP/home-q8" 2>&1)"
case "$out" in *"window-before=open"*"spawn_rc=0"*"window-after=closed"*) rc=0 ;; *) rc=1; echo "      $out";; esac
ck "a successful TERMINAL spawn closes the absent window (the owner answered)" $rc

cat > "$TMP/q9.sh" <<'SH'
set -u
PATH="$2:$3:$PATH"; O="$4"; WT_DIR="$O/state"; WT_TABLE_TTL=0; mkdir -p "$WT_DIR"
export CMUX_ABSENT=1 TMUX_LOG="$5"; : > "$TMUX_LOG"
WT_WORKER_HOME="$6"
printf '%s\n' "$(( $(date +%s) - 600 ))" > "$WT_DIR/.wt-absent-since"
. "$1"
wt_spawn "lane-78" "/tmp" 'bash /tmp/w.sh 78 b o/r'; echo "spawn_rc=$?"
echo "window-after=$([ -f "$WT_DIR/.wt-absent-since" ] && echo open || echo closed)"
SH
out="$(bash "$TMP/q9.sh" "$LIB" "$TMP/bin-cmux" "$TMP/stub" "$TMP/O26" "$TMP/tmux26.log" "$TMP/home-q9" 2>&1)"
case "$out" in *"spawn_rc=0"*"window-after=open"*) rc=0 ;; *) rc=1; echo "      $out";; esac
ck "a TMUX spawn does NOT close the absent window (it proves nothing about the cmux owner)" $rc

echo
echo "── H) the controller's capacity probes answer on BOTH platforms (agent-infra#1702) ──"
# The SHIPPED helpers, extracted from orch-loop.sh — not a copy. `is_num` comes with them because the
# mtime probe validates its own answer with it.
{ grep -m1 '^is_num() {' "$LOOP"; sed -n '/^file_mtime_epoch() {/,/^}/p' "$LOOP"; } > "$TMP/mtime.sh"
sed -n '/^load1() {/,/^}/p' "$LOOP" > "$TMP/load1.sh"
sed -n '/^swap_usage_mb() {/,/^}/p' "$LOOP" > "$TMP/swap.sh"
need() { [ -s "$1" ] && return 0; ck "$2" 1; return 1; }
: > "$TMP/probe.log"; touch -t 202601010000 "$TMP/probe.log"
want="$(date -r "$TMP/probe.log" +%s)"
# (1) the host's own shape — GNU on a Linux cell, BSD on the operator's Mac.
got="$(bash -c ". '$TMP/mtime.sh'; file_mtime_epoch '$TMP/probe.log'")"
[ "$got" = "$want" ] && rc=0 || { rc=1; echo "      host got '$got' want '$want'"; }
ck "file_mtime_epoch(): the HOST's stat shape returns the mtime (got '${got:-<empty>}')" $rc
# (2) the macOS SHAPE: `stat -c %Y` fails and only `stat -f %m` answers. Unreachable on a Linux CI
# host without this stub, and it is the shape whose failure aborts the controller one cycle in.
mkdir -p "$TMP/bsdonly"
cat > "$TMP/bsdonly/stat" <<'SH'
#!/usr/bin/env bash
# BSD stat: only `-f %m <file>` answers; every GNU form fails (as BSD's does, cleanly).
[ "${1:-}" = "-f" ] && [ "${2:-}" = "%m" ] && { date -r "${3:-}" +%s; exit $?; }
exit 1
SH
chmod +x "$TMP/bsdonly/stat"
got="$(PATH="$TMP/bsdonly:$PATH" bash -c ". '$TMP/mtime.sh'; file_mtime_epoch '$TMP/probe.log'")"
[ "$got" = "$want" ] && rc=0 || { rc=1; echo "      bsd got '$got' want '$want'"; }
ck "file_mtime_epoch(): the macOS shape (stat -f %m) returns the SAME value (got '${got:-<empty>}')" $rc
# (3) both shapes unreadable => no value at all. A guessed age reads as a healthy worker.
got="$(PATH="$TMP/bsdonly:$PATH" bash -c ". '$TMP/mtime.sh'; file_mtime_epoch '$TMP/nope.log' && echo ZERO || echo NONZERO")"
[ "$got" = "NONZERO" ] && rc=0 || { rc=1; echo "      got '$got'"; }
ck "file_mtime_epoch(): unreadable fails to a non-zero rc instead of guessing" $rc
# (4) LOAD: /proc/loadavg field 1 on Linux, sysctl vm.loadavg field 2 on macOS.
printf '9.75 1.00 2.00 1/9 42\n' > "$TMP/loadavg"
got="$(bash -c ". '$TMP/load1.sh'; load1 '$TMP/loadavg'")"
[ "$got" = "9" ] && rc=0 || { rc=1; echo "      got '$got'"; }
ck "load1(): the Linux path yields the 1-min load (field 1) — '${got:-<empty>}'" $rc
got="$(bash -c "sysctl() { echo '{ 8.20 7.70 7.10 }'; }; . '$TMP/load1.sh'; load1 '$TMP/no-such-loadavg'")"
[ "$got" = "8" ] && rc=0 || { rc=1; echo "      got '$got'"; }
ck "load1(): the macOS path yields the 1-min load (field 2) — '${got:-<empty>}'" $rc
# (5) SWAP: /proc/meminfo kB on Linux, sysctl vm.swapusage on macOS. Both must return "<free> <total>".
printf 'MemTotal: 16000000 kB\nSwapTotal: 2048000 kB\nSwapFree: 1024000 kB\n' > "$TMP/meminfo"
got="$(bash -c ". '$TMP/swap.sh'; swap_usage_mb '$TMP/meminfo'")"
[ "$got" = "1000 2000" ] && rc=0 || { rc=1; echo "      got '$got'"; }
ck "swap_usage_mb(): the Linux path yields <free> <total> MB — '${got:-<empty>}'" $rc
got="$(bash -c "sysctl() { echo 'total = 2048.00M  used = 1.00M  free = 2047.00M'; }; . '$TMP/swap.sh'; swap_usage_mb '$TMP/no-such-meminfo'")"
[ "$got" = "2047 2048" ] && rc=0 || { rc=1; echo "      got '$got'"; }
ck "swap_usage_mb(): the macOS path yields <free> <total> MB — '${got:-<empty>}'" $rc

# (6) PARSE: a file that does not parse in the controller's OWN shell is a dead harness, and a COMMENT
# can do it. Measured on this change: `/bin/bash -n worker-terminal.sh` exited 2 on the PR head
# (d635527b) and 0 at the base, and 0 again once the offending arm comment was moved above the case —
# macOS ships bash 3.2 as /bin/bash and orch-loop.sh declares it, so "does not parse" means wt_spawn
# is undefined and orch-loop exits 78 FATAL. CI's bash 5 parses the same text, so CI cannot see the
# class. The blind spot is DECLARED rather than papered over: no minimal fixture reproduced it in
# isolation, so a canary asserting one would be a fake discriminator. TWO shells are checked because
# they are two different answers: the RUNNING bash (always present, and what CI uses) and /bin/bash
# when it exists (the macOS controller's 3.2, the shell orch-loop.sh declares). Hardcoding /bin/bash
# alone is not portable — a musl bash:5 image ships bash at /usr/local/bin only, and the leg then
# fails 127, which is a false red measured on this very change.
for _f in "$LIB" "$LOOP" "$DM" "$HERE/worker-terminal.test.sh"; do
  "$BASH" -n "$_f" >/dev/null 2>&1; rc=$?
  [ $rc -ne 0 ] && echo "      bash -n $_f → rc=$rc"
  ck "parse: the running bash accepts $(basename "$_f")" $rc
  if [ -x /bin/bash ]; then
    /bin/bash -n "$_f" >/dev/null 2>&1; rc=$?
    [ $rc -ne 0 ] && echo "      /bin/bash -n $_f → rc=$rc"
    ck "parse: /bin/bash (the controller shell) accepts $(basename "$_f")" $rc
  fi
done
if [ -x /bin/bash ] && [ "$(/bin/bash -c 'echo "${BASH_VERSINFO[0]}"' 2>/dev/null || echo 5)" -le 3 ]; then
  ck "parse: the /bin/bash legs ran on a 3.x parser, so they CAN see the macOS parse class" 0
else
  # ⛔ THE LEG ABOVE PASSES BLIND ON A BASH-5 BOX (review finding, 2026-10-23): macOS /bin/bash is 3.2,
  # and a comment placed inside a `case` arm stopped worker-terminal.sh PARSING there — `wt_spawn` was
  # undefined and orch-loop.sh turns that into exit 78 FATAL — while every ubuntu-latest job parsed it
  # happily. A green pass on the one leg that cannot see the class is the false PASS this suite exists to
  # prevent, so when a 3.2 binary is not on the box, ask a real one: docker is present on the CI runners.
  # Offline (no docker, or no image) is still reported as blind, never as a pass.
  b32=0
  if command -v docker >/dev/null 2>&1; then
    # ⛔ PROBE THE RUNTIME, NOT THE CLI (P2 review finding, 2026-10-23). A docker CLI with no usable
    # daemon or permission exits non-zero for a reason that has nothing to do with bash's parser, and
    # the old code read EVERY rc except 124/125 as "a real bash 3.2 REJECTS worker-terminal.sh" — an
    # environment artifact presented as a parse verdict, which reds bash-suites on a correct change
    # (measured shape: `docker run` rc=1, `Cannot connect to the Docker daemon`). Probe first; a probe
    # failure is DECLARED BLIND, exactly like the no-docker branch.
    if ! timeout 300 docker run --rm bash:3.2 true >/dev/null 2>&1; then
      ck "parse DECLARED BLIND: the docker CLI cannot run bash:3.2 here (no daemon, permission or image) — this leg checked nothing" 0
    else
      if timeout 300 docker run --rm -v "$HERE:/h:ro" bash:3.2 bash -n /h/worker-terminal.sh >/dev/null 2>&1; then b32=0
      else b32=$?; fi
      if [ "$b32" = "0" ]; then
        ck "parse: a real bash 3.2 (docker bash:3.2) accepts worker-terminal.sh — the macOS parse class" 0
      elif [ "$b32" = "124" ] || [ "$b32" = "125" ]; then
        ck "parse DECLARED BLIND: docker could not provide a 3.2 parser here (rc=$b32) — this leg checked nothing" 0
      else
        ck "parse: a real bash 3.2 (docker bash:3.2) REJECTS worker-terminal.sh (rc=$b32)" 1
      fi
    fi
  else
    ck "parse DECLARED BLIND: no 3.x /bin/bash and no docker — the legs cannot see the macOS 3.2 parse class" 0
  fi
fi

echo
echo "── R) a create refusal carries the READINGS it took, and recovers the SESSION once (#2404) ──"
# ⛔ THE MEASURED DEFECT THIS SECTION PINS (cell-3, 2026-11-02, agent-infra#2404). Every spawn was
# refused with `workspace create failed: {"reason":"database or disk is full"}` on a box whose `/` had
# 28 G free, whose inodes were 25 % used and whose `~/.cmux` was 37 M. The daemon named a cause it had
# not checked, the refusal RELAYED IT AS THE REASON, and the reader was sent to `df` while a
# three-day-old durable session owner stayed unable to allocate a workspace. So: a refusal must carry
# the readings, must not present the daemon's message as the cause, and — where the reading says the
# SESSION is the finding — must try the one idempotent recovery once before giving up.
scenario shortdf
cat > "$TMP/bin-shortdf/df" <<'SH'
#!/usr/bin/env bash
# A volume AT/BELOW the floor: 1000 KB free, and 5 % inodes so only the SPACE arm can fire.
case "$*" in
  *"-Pi"*|*" -i"*) printf 'Filesystem 512-blocks Used Available Capacity iused ifree %%iused Mounted on\n/dev/x 100 100 10 1%% 5 95 5%% /\n' ;;
  *) printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/x 4000000 3999000 1000 99%% /\n' ;;
esac
SH
chmod +x "$TMP/bin-shortdf/df"
# ⛔ THE HEALTHY-VOLUME FIXTURE IS A READING TOO, AND IT MUST COME FROM THE FIXTURE (review round 1,
# finding 3). R1/R2/R4/R5/R6/R7 pin WT_CMUX_STATE_DIR at a fixture, but only `shortdf` carried a `df`
# STUB — so every "healthy volume" arm read the RUNNER'S OWN volume against the DEFAULT floors (1024 MB /
# 95 %). A runner with <1 GB free in $TMP (or ≥95 % inodes) made WT_PROBE_SHORT=1, flipped the verdict to
# `space`, and reddened a CORRECT tree: the arms were a function of CI's disk, not of their fixtures.
# 4 GB free / 12 % inodes — unambiguously above both floors, on both the -Pk and -Pi shapes.
scenario okdf
cat > "$TMP/bin-okdf/df" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"-Pi"*|*" -i"*) printf 'Filesystem 512-blocks Used Available Capacity iused ifree %%iused Mounted on\n/dev/x 8000000 1000000 7000000 12%% 1000 9000 12%% /\n' ;;
  *) printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/x 8000000 3819776 4194304 12%% /\n' ;;
esac
SH
chmod +x "$TMP/bin-okdf/df"
# The driver: the SHIPPED library, one spawn, the state dir pinned at a fixture so `df`/`du` ALWAYS
# answer (an unpinned run reads the box's own $HOME and reports UNREADABLE, which would make the
# measured-value assertions vacuous on a runner that has no ~/.cmux).
cat > "$TMP/r1.sh" <<'SH'
set -u
PATH="$2:$PATH"; O="$3"; WT_DIR="$O/state"; WT_TABLE_TTL=0; mkdir -p "$WT_DIR" "$5"
export CMUX_LOG="$4"; : > "$CMUX_LOG"
export WT_CMUX_STATE_DIR="$5" WT_CMUX_SESSION=cloud WT_SERVER_ENSURE_SLEEP=0
. "$1"
wt_spawn "lane-8" "$5" 'printf RAN_OK'; echo "rc=$?"
SH
DISKFULL='workspace create failed: {"code":"operation.failed","details":{"operation":"resource.runtime","reason":"database or disk is full"},"message":"database or disk is full"}'
# (R1) the cell-3 reading itself: volume healthy, owner ANSWERED `status running`, ensure did not help.
rm -rf "$TMP/OR1" "$TMP/rstate1"; : > "$TMP/ensure1.log"
out="$(CMUX_LAYOUT_RC=1 CMUX_LAYOUT_MSG="$DISKFULL" CMUX_SERVER_STATUS='status running, generation 22667b14-395d' CMUX_ENSURE_RC=1 CMUX_ENSURE_LOG="$TMP/ensure1.log" \
  bash "$TMP/r1.sh" "$LIB" "$TMP/bin-okdf" "$TMP/OR1" "$TMP/cmuxr1.log" "$TMP/rstate1" 2>&1)"
case "$out" in *"rc=1"*) rc=0 ;; *) rc=1; echo "      $out" ;; esac
ck "R1: a create refused on a healthy box still refuses (the spawn is not silently retried into success)" $rc
case "$out" in *"FALSE CAUSE"*) rc=0 ;; *) rc=1; echo "      $out" ;; esac
ck "R1: …and the refusal names the daemon's \`database or disk is full\` a FALSE CAUSE, because the volume was measured" $rc
case "$out" in *"MEASURED on this box"*"free="*"inodes="*"state="*) rc=0 ;; *) rc=1; echo "      $out" ;; esac
ck "R1: …carrying the readings it took (free, inodes, state size) rather than a bare claim" $rc
case "$out" in *"server status=status running"*) rc=0 ;; *) rc=1; echo "      $out" ;; esac
ck "R1: …including the session owner's own answer, which is what the incident's table reported" $rc
case "$out" in *"which this probe did NOT verify as the cause: workspace create failed"*) rc=0 ;; *) rc=1; echo "      $out" ;; esac
ck "R1: …and the daemon's message is LABELLED a claim, not passed off as the reason" $rc
[ "$(grep -c '^ENSURE server ensure --session cloud' "$TMP/ensure1.log" 2>/dev/null)" = "2" ] && rc=0 || { rc=1; cat "$TMP/ensure1.log"; }
ck "R1: the recovery ran \`cmux server ensure --session cloud\` TWICE (the measured fail-once flake)" $rc
case "$out" in *"tried 2 time(s)"*) rc=0 ;; *) rc=1; echo "      $out" ;; esac
ck "R1: …and the refusal states how many recovery attempts were spent, so the residual is on the record" $rc
grep -q '^lane-8	' "$TMP/OR1/state/spawn-refused.tsv" 2>/dev/null && rc=0 || rc=1
ck "R1: …and the refusal still reaches the controller's refusal record, under the WORKER's name" $rc
# (R2) THE RECOVERY MUST EARN ITS PLACE: ensure answers on the retry, the re-attempted create succeeds.
rm -rf "$TMP/OR2" "$TMP/rstate2"; : > "$TMP/ensure2.log"
out="$(CMUX_LAYOUT_FAIL_ONCE="$TMP/r2.fail" CMUX_LAYOUT_MSG="$DISKFULL" CMUX_SERVER_STATUS='status running, generation 22667b14-395d' CMUX_ENSURE_LOG="$TMP/ensure2.log" \
  bash "$TMP/r1.sh" "$LIB" "$TMP/bin-okdf" "$TMP/OR2" "$TMP/cmuxr2.log" "$TMP/rstate2" 2>&1)"
rm -f "$TMP/r2.fail"
case "$out" in *"rc=0"*) rc=0 ;; *) rc=1; echo "      $out" ;; esac
ck "R2: when the session is the fault, ONE ensure + ONE re-attempt SAVES the spawn (rc=0, not a refusal)" $rc
grep -qx 'kind=terminal' "$TMP/OR2/state/worker-lane-8" 2>/dev/null && rc=0 || rc=1
ck "R2: …and the saved worker is RECORDED (a recovered spawn is a real spawn, tracked and reapable)" $rc
case "$out" in *"RECOVERED lane-8"*) rc=0 ;; *) rc=1; echo "      $out" ;; esac
ck "R2: …with the recovery SAID OUT LOUD, so the box's instability is visible in the log" $rc
case "$out" in *"REFUSED lane-8"*) rc=1 ;; *) rc=0 ;; esac
ck "R2: …and NO refusal recorded for a spawn that succeeded" $rc
[ "$(grep -c 'CMUX layout apply' "$TMP/cmuxr2.log")" = "2" ] && rc=0 || { rc=1; cat "$TMP/cmuxr2.log"; }
ck "R2: …because the create really WAS attempted twice (the recovery is exercised, not decorative)" $rc
# (R3) a volume that IS short: the daemon's message is consistent, and RESTARTING A SESSION FREES NOTHING.
rm -rf "$TMP/OR3" "$TMP/rstate3"; : > "$TMP/ensure3.log"
out="$(CMUX_LAYOUT_RC=1 CMUX_LAYOUT_MSG="$DISKFULL" CMUX_SERVER_STATUS='status running, generation 22667b14-395d' CMUX_ENSURE_LOG="$TMP/ensure3.log" \
  bash "$TMP/r1.sh" "$LIB" "$TMP/bin-shortdf" "$TMP/OR3" "$TMP/cmuxr3.log" "$TMP/rstate3" 2>&1)"
case "$out" in *"IS at or below the floor"*) rc=0 ;; *) rc=1; echo "      $out" ;; esac
ck "R3: a volume MEASURED short is reported as short (the reading decides, not the daemon's wording)" $rc
[ ! -s "$TMP/ensure3.log" ] && rc=0 || rc=1
ck "R3: …and NO recovery is attempted on a short volume (restarting a session frees no space)" $rc
# (R4) THE macOS HOST CLI: no `server` verb at all. That is not an outage, and must not be called one.
rm -rf "$TMP/OR4" "$TMP/rstate4"; : > "$TMP/ensure4.log"
out="$(CMUX_LAYOUT_RC=1 CMUX_LAYOUT_MSG="$DISKFULL" CMUX_SERVER_UNSUPPORTED=1 CMUX_ENSURE_LOG="$TMP/ensure4.log" \
  bash "$TMP/r1.sh" "$LIB" "$TMP/bin-okdf" "$TMP/OR4" "$TMP/cmuxr4.log" "$TMP/rstate4" 2>&1)"
case "$out" in *"NO \`server\` verb"*) rc=0 ;; *) rc=1; echo "      $out" ;; esac
ck "R4: a CLI with no \`server\` verb says exactly that (a missing verb is not a dead session)" $rc
[ ! -s "$TMP/ensure4.log" ] && rc=0 || rc=1
ck "R4: …and no ensure is attempted where the verb does not exist" $rc
# (R5) the operator's off switch: no probe, no recovery, and NO invented readings.
rm -rf "$TMP/OR5" "$TMP/rstate5"; : > "$TMP/ensure5.log"
out="$(WT_SESSION_RECOVER=0 CMUX_LAYOUT_RC=1 CMUX_LAYOUT_MSG="$DISKFULL" CMUX_SERVER_STATUS='status running, generation 22667b14-395d' CMUX_ENSURE_LOG="$TMP/ensure5.log" \
  bash "$TMP/r1.sh" "$LIB" "$TMP/bin-okdf" "$TMP/OR5" "$TMP/cmuxr5.log" "$TMP/rstate5" 2>&1)"
[ ! -s "$TMP/ensure5.log" ] && rc=0 || rc=1
ck "R5: \$WT_SESSION_RECOVER=0 takes no probe and no recovery (the operator's stop switch works)" $rc
case "$out" in *"no readings taken"*) rc=0 ;; *) rc=1; echo "      $out" ;; esac
ck "R5: …and the refusal says no reading was taken instead of printing an empty 'MEASURED' claim" $rc
# ⛔ THE OFF SWITCH MUST NOT DESCRIBE A READ IT DID NOT ATTEMPT (review round 1, finding 2). The old text
# said "NEITHER the session owner nor the state volume could be READ on this box" — a FAILED read, which
# claims an attempt this branch deliberately skipped, inside the very message that exists to stop that.
case "$out" in *"WT_SESSION_RECOVER=0"*"NO reading was taken"*) rc=0 ;; *) rc=1; echo "      $out" ;; esac
ck "R5: …and the READING states the probe was DISABLED, so no cause is asserted either way" $rc
case "$out" in *"could be READ"*) rc=1 ;; *) rc=0 ;; esac
ck "R5: …and it does NOT claim a read was attempted and failed (the false half the old arm passed over)" $rc
# (R6) THE HAPPY PATH STAYS FREE: a create that answers must not pay for a probe or an ensure.
rm -rf "$TMP/OR6" "$TMP/rstate6"; : > "$TMP/ensure6.log"
out="$(CMUX_SERVER_STATUS='status running, generation 22667b14-395d' CMUX_ENSURE_LOG="$TMP/ensure6.log" \
  bash "$TMP/r1.sh" "$LIB" "$TMP/bin-okdf" "$TMP/OR6" "$TMP/cmuxr6.log" "$TMP/rstate6" 2>&1)"
case "$out" in *"rc=0"*) rc=0 ;; *) rc=1; echo "      $out" ;; esac
ck "R6: a spawn whose create answers succeeds as before (the probe is not on the happy path)" $rc
[ ! -s "$TMP/ensure6.log" ] && rc=0 || rc=1
ck "R6: …and it calls NO server verb at all (no cost, no risk on the 1,500-spawn path)" $rc
grep -c '^CMUX server ' "$TMP/cmuxr6.log" | grep -qx '0' && rc=0 || rc=1
ck "R6: …verified on the CLI's own call log, not on the module's prose" $rc
# (R7) A STOPPED OWNER IS NOT A RUNNING ONE. `case` takes the FIRST matching pattern, and `not running`
# CONTAINS `running` — so the positive pattern first made two of the five down signatures dead code and
# printed FALSE CAUSE for a session that had just said it was down (review round 1, finding 1). Every
# other R arm supplied only a running-shaped `server status`, so the whole owner-down verdict was
# untested; this arm is the one that would have caught it.
rm -rf "$TMP/OR7" "$TMP/rstate7"; : > "$TMP/ensure7.log"
out="$(CMUX_LAYOUT_RC=1 CMUX_LAYOUT_MSG="$DISKFULL" CMUX_SERVER_STATUS='status not running' CMUX_SERVER_STATUS_RC=0 CMUX_ENSURE_LOG="$TMP/ensure7.log" \
  bash "$TMP/r1.sh" "$LIB" "$TMP/bin-okdf" "$TMP/OR7" "$TMP/cmuxr7.log" "$TMP/rstate7" 2>&1)"
case "$out" in *"did NOT answer"*) rc=0 ;; *) rc=1; echo "      $out" ;; esac
ck "R7: a rc=0 \`status not running\` is read as DOWN, not swallowed by \`*running*\`" $rc
case "$out" in *"FALSE CAUSE"*) rc=1 ;; *) rc=0 ;; esac
ck "R7: …so the refusal does NOT call the daemon a FALSE CAUSE on a box whose owner said it was down" $rc
case "$out" in *"answers \`status running\`"*) rc=1 ;; *) rc=0 ;; esac
ck "R7: …and it does not claim the owner answered \`status running\` when it answered the opposite" $rc

echo
echo "── P) the module INITIALISES under bash 3.2 — no heredoc inside a command substitution (#2248) ──"
# ⛔ WHY THIS TEST IS TEXTUAL, AND WHY A LINUX-ONLY CI NEEDS IT.
# Apple ships bash 3.2.57 (GPLv2). Under it, a heredoc NESTED INSIDE A COMMAND SUBSTITUTION is
# mis-parsed, in two measured ways (both reproduced on 3.2.57 before this gate was written):
#   1. the quoted delimiter is NOT honoured, so a single quote anywhere in the body opens an
#      unterminated string — `line N: unexpected EOF while looking for matching `''` — and the rest
#      of the file is swallowed by the parse;
#   2. the WORDS OF THE HEREDOC BODY are executed as commands.
# The shipped `WT_TREE_PY="$(cat <<'PY' … PY)"` did both: it executed a COMMENT as a command (the
# body contains `worker's`), then died on `WT_TREE_PY: unbound variable`, and every verb below it was
# never defined — the controller died AT SOURCE TIME on macOS while `launchctl` and `harness verify`
# both said GREEN (measured: `controller … alive but the heartbeat is 3652s old` for an hour).
# `bash -n` PASSES on the broken form: it is a runtime mis-parse, not a syntax error. And GitHub's
# runners are Linux with bash 5.x, which parses the construct CORRECTLY — so the box that breaks
# cannot run this file, and the box that runs this file cannot observe the break. The parse is simply
# unavailable to CI at ANY depth of testing, which leaves one honest way to pin it: assert the
# CONSTRUCT is absent, and separately drive the OBSERVABLE it destroyed (the two Python programs are
# non-empty after a source). Everything below is non-vacuous — three synthetic broken fixtures are
# fed through the same predicate, and the startup GUARD is EXECUTED, not grepped for.
#
# The predicate is per-file (never a word-split list), always quotes its operands, forces the
# filename prefix with -H, and answers SCANNER-ERROR instead of silence when it cannot scan — so it
# fails CLOSED on a path with a space, an empty file list, and a single-file directory alike.
_hh_hits() { # argv: files → one "file:line:text" per hit; never reads stdin, never silently empty
  local f
  [ "$#" -gt 0 ] || { printf 'SCANNER-ERROR: no files to scan\n'; return 0; }
  for f in "$@"; do
    [ -f "$f" ] || { printf 'SCANNER-ERROR: cannot scan %s\n' "$f"; continue; }
    # the single-line shapes, whitespace-tolerant (`$(cat <<`, `$( cat<<`, …), minus whole-line comments
    grep -Hn -E '\$\([[:space:]]*cat[[:space:]]*<<' -- "$f" | grep -vE ':[0-9]+:[[:space:]]*#'
    # the wrapped shape: `$(` ending a line, `cat <<` opening the next
    awk 'p ~ /\$\([[:space:]]*$/ && $0 ~ /^[[:space:]]*cat[[:space:]]*<</ { printf "%s:%d:%s\n", FILENAME, NR, $0 } { p = $0 }' "$f"
  done
}
harness_sh=()
for _f in "$HERE"/*.sh; do
  case "$_f" in *.test.sh) continue ;; esac   # a suite carries the shape as TEXT on purpose; no controller sources one
  harness_sh+=("$_f")
done
hits="$(_hh_hits "${harness_sh[@]}")"
[ -z "$hits" ] && rc=0 || { rc=1; printf '      %s\n' "$hits"; }
ck "no shipped harness module puts a heredoc inside a command substitution (the shape bash 3.2 executes)" $rc

# The observable that regressed: source the module and read the two variables the census feeds to
# `python3 -c`. An empty program is not a loud failure — `python3 -c ''` exits 0 and prints nothing,
# which in this module reads EXACTLY like "no workers": the caps stop binding and a busy box reports
# an idle controller. So assert non-empty, and name the program in the failure.
src_out="$(set -u; . "$LIB" 2>&1; echo "tree=${#WT_TREE_PY} ws=${#WT_WS_PY}")"
case "$src_out" in
  *"tree=0 "*) rc=1 ;;
  *"ws=0"*) rc=1 ;;
  *"tree="*"ws="*) rc=0 ;;
  *) rc=1 ;;
esac
ck "sourcing the module leaves WT_TREE_PY and WT_WS_PY NON-EMPTY — '$(printf '%s' "$src_out" | tr '\n' ' ')'" $rc
# …and it must not have leaked the parser's damage into the log: a bash 3.2 mis-parse prints
# `command not found` / `unexpected EOF` / `unbound variable` lines that a caller redirecting to a
# log would swallow.
case "$src_out" in
  *"command not found"*|*"unbound variable"*|*"syntax error"*|*"unexpected EOF"*)
    rc=1; printf '      %s\n' "$src_out" ;;
  *) rc=0 ;;
esac
ck "…and sourcing emits no command-not-found / unbound-variable / syntax-error / unexpected-EOF" $rc

# ⛔ THE STARTUP GUARD IS EXECUTED, NOT GREPPED FOR. Asserting the NAME appears in orch-loop.sh was a
# vacuous gate: the file's own prose explains the guard and mentions both variables, so DELETING the
# guard loop left that assertion green (measured), and dropping `WT_TREE_PY` from the loop while
# keeping `WT_WS_PY` left BOTH green — i.e. the check could not see the one variable whose emptiness
# produced the outage. So: extract the guard verbatim and RUN it, once per variable. It must exit 78
# AND name the empty variable.
awk '/^for _wt_py in WT_TREE_PY WT_WS_PY; do$/,/^done$/' "$LOOP" > "$TMP/wt-guard.sh"
[ -s "$TMP/wt-guard.sh" ] && rc=0 || { rc=1; echo "      orch-loop.sh no longer carries the WT_TREE_PY/WT_WS_PY startup guard"; }
ck "orch-loop.sh still carries the WT_TREE_PY/WT_WS_PY startup guard block" $rc
_guard() { # _guard <WT_TREE_PY> <WT_WS_PY> → "rc=<n>|<output>"
  bash -c 'O=/x; WT_MOD=/x/worker-terminal.sh; WT_TREE_PY="$2"; WT_WS_PY="$3"
           . "$1"; echo "rc=0|UNREACHABLE"' _ "$TMP/wt-guard.sh" "$1" "$2" 2>&1
}
g="$(_guard abc def)"
case "$g" in *UNREACHABLE*) rc=0 ;; *) rc=1; printf '      %s\n' "$g" ;; esac
ck "the guard PASSES when both programs are populated (it is not a blanket refusal)" $rc
for _gv in WT_TREE_PY WT_WS_PY; do
  if [ "$_gv" = WT_TREE_PY ]; then g="$(_guard "" def)"; else g="$(_guard abc "")"; fi
  case "$g" in
    *UNREACHABLE*) rc=1; echo "      an empty $_gv did NOT stop the controller" ;;
    *"$_gv is EMPTY"*) rc=0 ;;
    *) rc=1; printf '      %s\n' "$g" ;;
  esac
  ck "an EMPTY $_gv stops the controller at startup, naming $_gv" $rc
done

# NON-VACUITY of the scanner: three synthetic fixtures carrying the three shapes that break 3.2 —
# including the apostrophe, which is what makes the delimiter-quoting failure real rather than
# hypothetical (a fixture WITHOUT one sources fine on 3.2 and proves nothing; measured).
{ printf '%s\n' 'WT_X="$(cat <<'"'"'PY'"'"'' "# it's an apostrophe" 'PY' ')"'
  printf '%s\n' 'WT_Y="$(cat<<'"'"'PY'"'"'' "# no space before the <<" 'PY' ')"'
  printf '%s\n' 'WT_Z="$(' 'cat <<'"'"'PY'"'"'' "# the wrapped shape" 'PY' ')"'
} > "$TMP/broken-shapes.sh"
misses="$(_hh_hits "$TMP/broken-shapes.sh" | grep -c ':')"
[ "$misses" -ge 3 ] && rc=0 || { rc=1; echo "      the scanner found $misses of 3 known-broken shapes"; }
ck "the \$(cat << scan detects ALL THREE broken shapes (non-vacuous: spaced, unspaced, wrapped)" $rc
# …and it fails CLOSED when it cannot scan at all, rather than reporting a clean tree it never read.
case "$(_hh_hits "$TMP"/no-such-dir/*.sh)" in *SCANNER-ERROR*) rc=0 ;; *) rc=1 ;; esac
ck "the scanner reports SCANNER-ERROR when it cannot read its inputs (never a silent pass)" $rc

printf '  %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
