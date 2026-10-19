#!/usr/bin/env bash
# check-scheduled-parity.sh — THE gate: is the live host's schedule the one this fleet DECLARES?
# (agent-infra#2048)
#
# WHY THIS EXISTS. The measured state on 2026-10-18 was 35 launchd components on the Mac, 1 known to
# `install.sh`, and ZERO systemd units on the Linux cells. Nothing was lying — no component claimed a
# job it did not have. The failure was that NOBODY COMPARED the two directions, so 34 of 35 schedules
# were invisible: not declared, not reproducible, and lost the day the laptop's disk (or its user)
# forgot them. This check is that comparison. It would have caught all 34 on the first run.
#
# IT FAILS IN EITHER DIRECTION, AND IT IS DELIBERATELY NOT SYMMETRIC IN ITS EVIDENCE:
#   UNDECLARED       the host runs a scheduled job the declaration does not name      → FAIL
#   MISSING          the declaration names a job this host does not run               → FAIL
#   INERT            declared and installed, but not loaded/enabled, so it never fires → FAIL
#                    (a schedule that exists and does not fire is the false PASS this repo keeps
#                     removing: "installed" is not "reaped")
#   SCHEDULE-DRIFT   declared interval ≠ the interval in the installed artifact        → FAIL
#   PAYLOAD-DRIFT    the installed artifact ≠ what the declaration renders (a second  → FAIL
#                    ExecStart/trigger/env, a replaced program, a lost unit)
#   STALE-REGISTER   the unmanaged register names a job that is no longer live         → FAIL
#   NO-REASON        an unmanaged register entry carries no reason                     → FAIL
#   CONFLICT         a job is both declared and registered, or two mechanisms clock it → FAIL
#   NO-JOBS          the surface was readable and carried zero in-scope jobs           → FAIL
#   UNMANAGED        live, not declared, but registered WITH a reason                  → ok, counted
#   out-of-scope     a third-party agent (com.google.*, com.premise.*, …)             → ok, counted
#
# ⛔ AN EMPTY SURFACE IS NEVER A GREEN ONE. If the scheduler cannot be read at all, this exits 3
# ("could not measure") — never 0 — because "I found no undeclared jobs" must be distinguishable from
# "I looked at nothing". The same rule applies to the declaration: zero records is a failure.
#
# Usage:
#   check-scheduled-parity.sh [--static] [--platform linux|darwin] [--declaration FILE]
#                             [--register FILE] [--quiet]
#
#   (default)   compare the DECLARATION with the LIVE scheduler on this host
#   --static    no live surface touched: validate the declaration and RENDER both platforms for every
#               record (this is the CI mode — a Linux runner has no launchd, and a gate that cannot
#               answer its question must not pretend to)
#   --quiet     findings only, no summary
#   --only <ids>  scope the DECLARED loop to these records (the installer's closing gate passes the
#               selection it just acted on); the UNDECLARED direction still covers the whole host
#
# Exit codes: 0 parity holds/static checks pass · 1 drift or a declaration defect · 2 usage ·
#             3 the live surface could not be measured (NEVER 0 — see above).
#
# Env seams (tests, and a host with an unusual layout):
#   SJ_DECLARATION / SJ_UNMANAGED_REGISTER   file overrides
#   PORTABLE_PLATFORM                        linux | darwin
#   SJ_LAUNCHD_DIR / SJ_LAUNCHCTL            launchd surface + tool
#   SJ_SYSTEMD_UNIT_DIR / SJ_SYSTEMCTL       systemd surface + tool
#   SJ_NAMESPACES                            in-scope label prefixes (default: com.eldato.,com.tortoise.)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/scheduled-jobs.sh
. "$HERE/lib/scheduled-jobs.sh" || { echo "check-scheduled-parity: cannot load the declaration library" >&2; exit 1; }

MODE=live
QUIET=0
ONLY=""     # `--only <ids>`: scope the DECLARED loop to a selection (the installer's closing gate)
PLATFORM="${SJ_PLATFORM_OVERRIDE:-}"
while [ $# -gt 0 ]; do
    case "$1" in
        --static|--declaration-only) MODE=static ;;
        --live)                      MODE=live ;;
        --platform)                  PLATFORM="${2:-}"; shift ;;
        --declaration)               SJ_DECL="${2:-}"; shift ;;
        --register)                  SJ_UNMANAGED="${2:-}"; shift ;;
        --quiet|-q)                  QUIET=1 ;;
        --only)                      ONLY="${2:-}"; shift ;;
        --help|-h)                   sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "check-scheduled-parity: unknown argument '$1'" >&2; exit 2 ;;
    esac
    shift
done
[ -n "$PLATFORM" ] || PLATFORM="$(_portable_platform)"

say()  { [ "$QUIET" = 1 ] || printf '%s\n' "$*"; }
fail() { printf 'FAIL %s\n' "$*"; FAILS=$((FAILS + 1)); }
warn() { printf 'WARN %s\n' "$*"; }

FAILS=0
CHECKS=0
# ⛔ AN UNUSABLE SCRATCH DIR IS UNMEASURABLE, NOT A VERDICT. Routing it through `fail()` made a run
# that could read nothing at all exit 1 — the same code as "this job is missing" — so a consumer that
# retries on 3 vs alerts on 1 was misled, and the gate published a class verdict it never earned.
# The err-file fallback must never be `/dev/null`: the EXIT trap would `rm -f` it.
if ! TMPDIR_SJ_ERR="$(mktemp "${TMPDIR:-/tmp}/sj-perr.XXXXXX" 2>/dev/null)"; then
    printf 'verdict=UNMEASURABLE platform=%s mode=%s — cannot create a scratch file, so NOTHING was read\n' "${PLATFORM:-?}" "$MODE"
    exit 3
fi
trap 'rm -f "$TMPDIR_SJ_ERR"' EXIT

# ── static half: the declaration must be installable on BOTH platforms ────────────────────────
# This is not a formality: it is what makes "one declaration rendered for both platforms" TRUE rather
# than claimed. Every record is rendered for EVERY platform it declares, and an artifact that cannot be
# produced (an unresolvable script, an unresolved placeholder, a malformed plist) is a FAILURE here —
# before any scheduler is touched.
SJ_FARM="${SJ_FARM:-${HOME:-}/.pi/agent/scripts}"

# ⛔ A SELECTION THAT MATCHES NOTHING VERIFIES NOTHING. `--only typo-id` continue'd past every record and
# published `verdict=OK checks=3` — a one-word typo in the installer's closing gate bought a clean bill
# of health. The selection is validated against the declaration before anything is checked.
if [ -n "$ONLY" ]; then
    _sel_ok=0
    for _sel_id in $(printf '%s' "$ONLY" | tr ',' ' '); do
        for _decl_id in $(sj_ids); do
            [ "$_sel_id" = "$_decl_id" ] && _sel_ok=$((_sel_ok + 1))
        done
    done
    if [ "$_sel_ok" -eq 0 ]; then
        printf 'FAIL --only names no declared record (%s) — a selection that matches nothing verifies nothing\n' "$ONLY"
        exit 2
    fi
fi
static_checks() {
    local errs id plat d out
    errs="$(sj_validate 2>&1)"; local vrc=$?
    CHECKS=$((CHECKS + 1))
    if [ "$vrc" -ne 0 ]; then
        while IFS= read -r out; do [ -n "$out" ] && fail "declaration: $out"; done <<EOF
$errs
EOF
    fi
    d="$(mktemp -d "${TMPDIR:-/tmp}/sj-parity.XXXXXX")" || { printf 'FAIL cannot create a temp dir — NOTHING was read\n'; return 3; }
    for id in $(sj_ids); do
        if [ -n "$ONLY" ]; then
            case ",$(printf '%s' "$ONLY" | tr -d ' ')," in *",$id,"*) ;; *) continue ;; esac
        fi
        for plat in linux darwin; do
            sj_has_platform "$id" "$plat" || continue
            CHECKS=$((CHECKS + 1))
            if [ "$plat" = linux ]; then
                out="$(sj_render_systemd "$id" "$d" system 2>&1)" \
                    || { fail "$id: systemd rendering failed${out:+ ($out)}"; continue; }
                [ -s "$d/$(sj_unit "$id").timer" ] || fail "$id: systemd timer rendered EMPTY"
                grep -q '{{' "$d/$(sj_unit "$id").service" "$d/$(sj_unit "$id").timer" \
                    && fail "$id: unresolved placeholder in the rendered systemd unit"
                grep -q '^ExecStart=./' "$d/$(sj_unit "$id").service" \
                    || fail "$id: the rendered unit has no ExecStart — an inert job"
            else
                out="$(sj_render_launchd "$id" "$d/$(sj_label "$id").plist" 2>&1)" \
                    || { fail "$id: launchd rendering failed${out:+ ($out)}"; continue; }
                [ -s "$d/$(sj_label "$id").plist" ] || fail "$id: launchd plist rendered EMPTY"
                grep -q '{{' "$d/$(sj_label "$id").plist" && fail "$id: unresolved placeholder in the rendered plist"
                if command -v plutil >/dev/null 2>&1; then
                    plutil -lint "$d/$(sj_label "$id").plist" >/dev/null 2>&1 \
                        || fail "$id: the rendered plist is MALFORMED (launchd would ignore it)"
                fi
                # An unarmed/armed flag must be READABLE from the artifact, never implied.
                if [ -n "$(sj_field "$id" arming)" ]; then
                    grep -qE -- '--apply|--dry-run' "$d/$(sj_label "$id").plist" \
                        || fail "$id: arming is declared but no mode flag is in the rendered plist"
                fi
            fi
        done
    done
    rm -rf "$d"
    return 0
}

# ── live half ────────────────────────────────────────────────────────────────────────────────
declare_line() { # declare_line <id> -> "name|installed|active|interval-or-unknown"
    case "$PLATFORM" in
        darwin) printf '%s|%s\n' "$(sj_label "$1")" "$1" ;;
        linux)  printf '%s|%s\n' "$(sj_unit "$1")" "$1" ;;
        *)      return 1 ;;
    esac
}

live_rows() { # live_rows -> rows on stdout; exit 3 when unmeasurable
    case "$PLATFORM" in
        darwin) sj_live_launchd ;;
        linux)  sj_live_systemd ;;
        *) echo "no scheduler known for platform '$PLATFORM'" >&2; return 1 ;;
    esac
}

# A register entry belongs to ONE platform's naming scheme: `com.*` is a launchd label, anything else
# is a systemd unit base. Judged only there, so a cell is not reddened by the Mac's register.
register_applies() { # register_applies <name>
    case "$1" in
        com.*) [ "$PLATFORM" = darwin ] ;;
        *)     [ "$PLATFORM" = linux ] ;;
    esac
}

# The cadence a DECLARED record asks for, in the same vocabulary the artifact readers emit.
sj_expect_cadence() { # sj_expect_cadence <id>
    local s
    s="$(sj_field "$1" schedule)"
    case "$s" in
        hourly|daily|weekly) printf 'cadence:%s\n' "$s"; return 0 ;;
    esac
    sj_schedule_seconds "$1" 2>/dev/null | sed 's/^/interval:/'
}

# Normalise a cadence to SECONDS so the two vocabularies compare: `hourly` and `3600s` are the same
# instruction, and a record that says `900s` is NOT the same as an artifact launched daily.
cad_seconds() { # cad_seconds <cadence> -> seconds on stdout, 1 when not comparable
    case "$1" in
        cadence:hourly)  printf '3600\n' ;;
        cadence:daily)   printf '86400\n' ;;
        cadence:weekly)  printf '604800\n' ;;
        interval:*)      printf '%s\n' "${1#interval:}" ;;
        *) return 1 ;;
    esac
}

# ⛔ THE PAYLOAD — and the WHOLE artifact, not a projection of it. Comparing ONE field lets a
# SECOND `ExecStart=` line (systemd runs every one for `Type=oneshot`), a second trigger
# (`OnCalendar=`, `OnUnitActiveSec=`, or `StartCalendarInterval` beside `StartInterval`) or an added
# `Environment=` / plist key ride along untouched: keep the declared program and cadence, append
# `ExecStart=/bin/sh -c "curl … | sh"`, and a field-only reader reports OK. So for a record this
# command actually installs (`managed=yes`) re-render the record and compare the ARTIFACTS. Arming is
# the one legitimate difference — a stance, separate and visible (#1678) — so the arm token is removed
# from both sides, and the stance itself is asserted on the artifact rather than inferred from the diff.
strip_arm() { # strip_arm <file> — the arming flag is the artifact's stance, never its definition
    # Both shapes: an argv WORD (`… alpha.sh --dry-run`) and a plist `<string>` that holds only the
    # flag. Missing the second form made "the owner armed it" read as PAYLOAD-DRIFT (#1678).
    sed -e 's/ --apply//g' -e 's/ --dry-run//g' -e 's/ "--apply"//g' -e 's/ "--dry-run"//g' \
        -e 's|^[[:space:]]*<string>--apply</string>[[:space:]]*$||' \
        -e 's|^[[:space:]]*<string>--dry-run</string>[[:space:]]*$||' "$1" | grep -v '^[[:space:]]*$'
}

# ⛔ MACHINE STATE IS NOT DRIFT. `HOME`, `PATH` and any declared env whose value carries a placeholder
# (`@state`, `@repos`, …) are resolved from the BOX at INSTALL time — that is what makes one declaration
# installable anywhere — so a parity run in a different shell (a fixture, a non-login shell, a cell whose
# repo moved) would otherwise report every job in the declaration as tampered. Their VALUES are masked on
# both sides; every other byte — the program argv, every trigger key, every other env, every plist key —
# is compared exactly as installed. A tampered artifact is not machine state: it names a different program.
state_keys() { # state_keys <id> — the env keys whose value the box supplies
    local id="$1" k v
    printf 'HOME\nPATH\n'
    while IFS= read -r k; do
        [ -n "$k" ] || continue
        v="${k#*=}"
        case "$v" in *@*) printf '%s\n' "${k%%=*}" ;; esac
    done <<EOF
$(sj_envs "$id")
EOF
}

normalize_state() { # normalize_state <file> <state-key-below>...
    local f="$1" keys; shift
    # ⛔ KEYS ARE JOINED WITH SPACES INTO A SHELL VARIABLE, never inline in the awk program: a
    # `printf '%s '` inside the single-quoted program CLOSES the quote, which truncated the filter —
    # and a truncated filter printed nothing, so both sides compared equal and every tampered artifact
    # went GREEN. (Found by the added-artifact tests; the symptom was a false PASS, not an error.)
    keys="$*"
    awk -v keys="$keys" '
        BEGIN { n = split(keys, ka, " "); for (i = 1; i <= n; i++) if (ka[i] != "") st[ka[i]] = 1; prev = "" }
        {
            line = $0
            # The service USER is a deployment decision (system vs user scope), not part of the
            # job definition: the installer picks the scope the box supports, so comparing it would
            # red a correct install on a box where the installer chose `user`.
            if (line ~ /^[[:space:]]*User=/) { next }
            if (match(line, /^[[:space:]]*Environment=[A-Za-z_][A-Za-z0-9_]*=/)) {
                k = line; sub(/^[[:space:]]*Environment=/, "", k); sub(/=.*$/, "", k)
                if (k in st) { sub(/=.*$/, "=@value", line); print line; prev = ""; next }
            }
            if (prev != "" && (prev in st) && match(line, /^[[:space:]]*<string>.*<\/string>[[:space:]]*$/)) {
                sub(/<string>.*<\/string>/, "<string>@value</string>", line)
                print line; prev = ""; next
            }
            if (match(line, /^[[:space:]]*<key>[A-Za-z_][A-Za-z0-9_]*<\/key>[[:space:]]*$/)) {
                k = line; sub(/^[[:space:]]*<key>/, "", k); sub(/<\/key>.*$/, "", k); prev = k
            } else if (line !~ /^[[:space:]]*$/) { prev = "" }
            print line
        }' "$f"
}

# ⛔ A MISSING HELPER MUST NOT READ AS GREEN. `payload_drift: command not found` inside a shell that has
# no `set -e` prints to stderr and returns 127 — which the caller ignored, so a gate could ship with its
# central verdict function undefined and still publish `verdict=OK`. The functions this file cannot run
# without are asserted at startup.
payload_drift() { # payload_drift <id> <what>
    CHECKS=$((CHECKS + 1))
    fail "PAYLOAD-DRIFT $1 — the installed artifact does not match what the declaration renders: $2"
    return 0
}

require_functions() { # every helper the live half depends on must actually be defined
    local fn missing=""
    for fn in payload_checks payload_drift side_file normalize_state strip_arm first_diff \
              state_keys register_applies cad_seconds sj_expect_cadence live_rows declare_line; do
        command -v "$fn" >/dev/null 2>&1 || missing="$missing $fn"
    done
    if [ -n "$missing" ]; then
        printf 'verdict=UNMEASURABLE platform=%s mode=%s — the gate is INCOMPLETE (undefined:%s), so NOTHING was verified\n' \
            "${PLATFORM:-?}" "$MODE" "$missing"
        exit 3
    fi
}

# The first line that differs between two texts, so the verdict names the tamper instead of the fact.
first_diff() { # first_diff <leftfile> <rightfile> — the installed side of the first hunk
    # Normal diff (not -u): line 2 is `< <installed line>`, so the verdict quotes the ARTIFACT'S line
    # rather than a `@@` header that tells a reader nothing about the tamper.
    diff "$1" "$2" 2>/dev/null | sed -n '2p' | sed 's/^< //' | cut -c1-200
}

# One side of the comparison: the arm token removed (a stance is not a definition) and machine state
# normalised back to its tokens (a PATH is not a definition either). Blank lines carry no meaning in
# these artifacts and are dropped so a whitespace-only edit is not reported as drift.
side_file() { # side_file <id> <outfile> <artifact...>
    local id="$1" out="$2"; shift 2
    : >"$out"
    local f sk
    sk="$(state_keys "$id")"
    for f in "$@"; do
        [ -f "$f" ] || continue
        strip_arm "$f" >"$out.part"
        normalize_state "$out.part" $(printf '%s' "$sk") >>"$out"
        rm -f "$out.part"
    done
}

payload_checks() { # payload_checks <id> <installed-name>
    local id="$1" name="$2" d installed installed_timer="" rendered rendered_timer="" arm line
    d="$(mktemp -d "${TMPDIR:-/tmp}/sj-payload.XXXXXX")" || { payload_drift "$id" "cannot render the record to compare"; return 0; }
    case "$PLATFORM" in
        darwin)
            installed="$(sj_launchd_dir)/$name.plist"
            rendered="$d/$name.plist"
            if ! sj_render_launchd "$id" "$rendered" >/dev/null 2>&1; then
                rm -rf "$d"; payload_drift "$id" "the record cannot be rendered for this host (runner/script unresolved)"; return 0
            fi
            ;;
        linux)
            installed="$(sj_systemd_units_dir)/$name.service"
            installed_timer="$(sj_systemd_units_dir)/$name.timer"
            if ! sj_render_systemd "$id" "$d" system >/dev/null 2>&1; then
                rm -rf "$d"; payload_drift "$id" "the record cannot be rendered for this host (runner/script unresolved)"; return 0
            fi
            rendered="$d/$name.service"; rendered_timer="$d/$name.timer"
            ;;
    esac
    if [ ! -f "$installed" ]; then
        rm -rf "$d"; payload_drift "$id" "the installed artifact '$installed' is not readable"; return 0
    fi
    # The artifact's arming stance, asserted on the artifact (the comparison below is deliberately
    # blind to it, so this is the only place the stance is read).
    CHECKS=$((CHECKS + 1))
    case "$PLATFORM" in
        darwin) arm="$(sj_launchd_argv "$installed" 2>/dev/null)" ;;
        linux)  arm="$(sj_systemd_execstart "$installed" 2>/dev/null)" ;;
    esac
    if [ -n "$(sj_field "$id" arming)" ]; then
        case "$arm" in
            *--apply*|*--dry-run*) ;;
            *) fail "PAYLOAD-DRIFT $id — the record declares an arming stance but the installed artifact carries no readable mode flag" ;;
        esac
    fi
    # The TIMER is part of the schedule definition: an artifact may keep the declared interval and add a
    # second trigger key beside it, and systemd honours every trigger line.
    side_file "$id" "$d/.installed" "$installed" ${installed_timer:+"$installed_timer"}
    side_file "$id" "$d/.declared"  "$rendered"  ${rendered_timer:+"$rendered_timer"}
    # A filter that produced nothing compared to nothing would be EQUAL — the false pass this check
    # exists to prevent. An empty side against a non-empty artifact is unmeasured, never a match.
    if [ ! -s "$d/.installed" ] || [ ! -s "$d/.declared" ]; then
        rm -rf "$d"; payload_drift "$id" "the comparison produced nothing (the artifact could not be normalised) — UNMEASURED, not a match"; return 0
    fi
    if ! cmp -s "$d/.installed" "$d/.declared"; then
        line="$(first_diff "$d/.installed" "$d/.declared")"
        payload_drift "$id" "${line:-the artifact bodies differ}"
    fi
    rm -rf "$d"
    return 0
}

live_checks() {
    local rows meta in_scope declared_line name id inst active iv declared_names="" live_names=""
    local r_name r_inst r_active r_iv found
    CHECKS=$((CHECKS + 1))
    if ! rows="$(live_rows)"; then
        printf 'FAIL could not measure the live %s surface on this host — an unreadable surface is never a clean one\n' "$PLATFORM"
        return 3
    fi
    meta="$(printf '%s\n' "$rows" | grep '^#meta|' | head -1)"
    rows="$(printf '%s\n' "$rows" | grep -v '^#meta|')"
    in_scope="$(printf '%s' "$meta" | awk -F'|' '{for(i=1;i<=NF;i++) if ($i ~ /^in_scope=/) {sub("in_scope=","",$i); print $i}}')"

    # 1. every declared record for this platform must be installed, loaded and (where readable) on the
    #    declared interval.
    # ⛔ THE DECLARATION'S NAME SET IS THE WHOLE DECLARATION, EVEN ON A SCOPED RUN (`--only`).
    # Building it from the selection made every UNSELECTED declared job read as UNDECLARED — a scoped
    # install of `alpha` failed the gate on `beta`, which the declaration names perfectly well. The
    # selection scopes the CHECKS; it never narrows what counts as declared.
    for id in $(sj_ids); do
        sj_has_platform "$id" "$PLATFORM" || continue
        declared_line="$(declare_line "$id")" || continue
        declared_names="$declared_names ${declared_line%%|*}"
    done

    for id in $(sj_ids); do
        sj_has_platform "$id" "$PLATFORM" || continue
        if [ -n "$ONLY" ]; then
            case ",$(printf '%s' "$ONLY" | tr -d ' ')," in *",$id,"*) ;; *) continue ;; esac
        fi
        declared_line="$(declare_line "$id")" || { fail "$id: this platform has no scheduler"; continue; }
        name="${declared_line%%|*}"
        found="$(printf '%s\n' "$rows" | awk -F'|' -v n="$name" '$1 == n')"
        CHECKS=$((CHECKS + 1))
        if [ -z "$found" ]; then
            fail "MISSING $id — declared for $PLATFORM as '$name' but this host does not run it (installed=no)"
            continue
        fi
        r_inst="$(printf '%s' "$found" | cut -d'|' -f2)"
        r_active="$(printf '%s' "$found" | cut -d'|' -f3)"
        r_cad="$(printf '%s' "$found" | cut -d'|' -f4)"
        r_svc="$(printf '%s' "$found" | cut -d'|' -f5)"
        [ "$r_inst" = yes ] || fail "MISSING $id — '$name' is not installed on this host"
        case "$r_active" in
            active|yes|running|active:enabled|active:static|active:enabled-runtime) ;;
            *) fail "INERT $id — '$name' is installed but NOT loaded/enabled (state=$r_active): it never fires" ;;
        esac
        # A systemd timer without its .service is installed, enabled, active — and can never run a job.
        if [ "$r_svc" = no ]; then
            fail "MISSING $id — '$name.timer' is installed but '$name.service' is ABSENT: the timer can never run the job"
        fi
        # ⛔ THE REGISTER MAY NOT DISAGREE WITH THE DECLARATION — and a BLANK reason is a disagreement
        # too. Branching on the OUTPUT (`[ -n "$(...)" ]`) hid both `registered with no reason` and the
        # separator-less line, because both return status 2 with empty stdout.
        local rr rrc
        rr="$(sj_unmanaged_reason "$name")"; rrc=$?
        case "$rrc" in
            0) fail "CONFLICT $id — '$name' is BOTH declared and registered as unmanaged; one of the two is wrong" ;;
            2) fail "NO-REASON $id — '$name' is registered as unmanaged with NO reason, and it is ALSO declared; the register entry is wrong" ;;
        esac
        # Schedule drift — on BOTH platforms. It was darwin-only, which left the LINUX cells (the
        # platform that had zero units before this feature) with no cadence check at all: an installed
        # `OnCalendar=daily` against a declared `900s` read green.
        local want_c got_c want_s got_s
        want_c="$(sj_expect_cadence "$id")"
        got_c="$r_cad"
        CHECKS=$((CHECKS + 1))
        if want_s="$(cad_seconds "$want_c" 2>/dev/null)" && got_s="$(cad_seconds "$got_c" 2>/dev/null)"; then
            [ "$want_s" = "$got_s" ] || fail "SCHEDULE-DRIFT $id — declared ${want_s}s, installed ${got_s}s ($got_c)"
        else
            # Not comparable to the declaration (no schedule key, a calendar expression the declaration
            # does not state, or an unreadable artifact). A record ALWAYS declares a schedule, so this
            # is a disagreement, not a note — an `unknown` that scrolled past as "not verifiable" is
            # how `StartInterval` vanished from a plist and nothing noticed.
            fail "SCHEDULE-DRIFT $id — declared '$want_c', the installed artifact says '$got_c': the artifact's schedule cannot be confirmed as the declared one"
        fi
        if [ "$(sj_field "$id" managed)" = yes ]; then
            payload_checks "$id" "$name"
        fi
    done

    # 2. every live in-scope job must be declared, or registered with a reason.
    while IFS='|' read -r r_name r_inst r_active r_iv; do
        [ -n "$r_name" ] || continue
        live_names="$live_names $r_name"
        case " $declared_names " in *" $r_name "*) continue ;; esac
        CHECKS=$((CHECKS + 1))
        local reason rc
        reason="$(sj_unmanaged_reason "$r_name")"; rc=$?
        # ⛔ A REGISTER ENTRY ONLY SPEAKS FOR ITS OWN PLATFORM. Applying it un-scoped LAUNDERED a live
        # Linux unit named `com.tortoise.hidden`: the darwin line silenced the linux UNDECLARED finding.
        # Judged on one platform, the entry must be judged only there — in BOTH directions.
        register_applies "$r_name" || rc=1
        case "$rc" in
            0) UNMANAGED=$((UNMANAGED + 1)) ;;
            2) fail "NO-REASON $r_name — registered as unmanaged with NO reason; an unexplained exclusion is how a job disappears" ;;
            *) fail "UNDECLARED $r_name — this host runs it and the declaration does not name it (add a record, or register it in $SJ_UNMANAGED with a reason)" ;;
        esac
    done <<EOF
$rows
EOF

    # 3. the register may not outlive the jobs it describes — ON THE PLATFORM THAT ENTRY BELONGS TO.
    # ⛔ A launchd label is not a systemd unit base, so on a Linux cell every launchd entry in the
    # register was "not live" and the gate could NEVER be green there (measured: 17 STALE-REGISTER on
    # a cell with the declared job installed and active). The cheapest green would have been deleting
    # the register — reopening the laundering exit the register exists to close. So an entry is
    # judged only on its own platform: `com.*` is a launchd label (darwin), anything else is a systemd
    # unit base (linux). Stated here because it is a rule, not an accident of our naming.
    for r_name in $(sj_unmanaged_names); do
        case " $live_names " in *" $r_name "*) continue ;; esac
        register_applies "$r_name" || { CHECKS=$((CHECKS + 1)); continue; }
        CHECKS=$((CHECKS + 1))
        fail "STALE-REGISTER $r_name — registered as unmanaged but not live on this host; remove the entry"
    done

    # 3b. crontab is the third scheduler and exists on both platforms.
    # ⛔ Its entries carry no name, so the ONLY honest test of "is this declared" is whether the line
    # runs one of the declared scripts. A cron line that does is a duplicate trigger for a declared
    # job (reported, not failed); one that runs anything else in the fleet's namespace is UNDECLARED.
    local cron_rows cron_line cron_script cron_resolved matched cron_in_scope=0 cron_err
    if ! cron_rows="$(sj_live_cron 2>"$TMPDIR_SJ_ERR")"; then
        # ⛔ AN UNREADABLE CRONTAB IS NOT AN EMPTY ONE. This arm used to be absent, so a reader failure
        # silently dropped the whole crontab population while the run stayed green — the "I looked at
        # nothing" failure this gate exists to refuse.
        cron_err="$(cat "$TMPDIR_SJ_ERR" 2>/dev/null)"
        printf 'FAIL could not measure the crontab on this host%s — an unreadable surface is never a clean one\n' "${cron_err:+ ($cron_err)}"
        return 3
    fi
    if :; then
        while IFS= read -r cron_line; do
            case "$cron_line" in ''|'#meta|'*) continue ;; esac
            cron_in_scope=$((cron_in_scope + 1))
            CHECKS=$((CHECKS + 1))
            matched=""
            for id in $(sj_ids); do
                cron_script="$(sj_field "$id" script)"
                [ -n "$cron_script" ] || continue
                # ⛔ THE DECLARED SCRIPT'S PATH, NOT ITS BASENAME. A substring match on the basename
                # accepted `/tmp/evil/eldato-alpha.sh --exfil` as "a second clock for alpha" — a NOTE,
                # never a failure — so whether a foreign payload was waved through depended on what the
                # attacker NAMED it. Only a line that runs the script this declaration resolves to is a
                # second clock; anything else that looks like ours is simply UNDECLARED.
                cron_resolved="$(sj_resolve_script "$id" 2>/dev/null)" || cron_resolved=""
                [ -n "$cron_resolved" ] || cron_resolved="$SJ_FARM/$cron_script"
                case " $cron_line " in
                    *" $cron_resolved "*) matched="$id" ;;
                esac
            done
            if [ -n "$matched" ]; then
                fail "CONFLICT cron:$cron_line — a SECOND clock for declared job '$matched': the same job is scheduled by two mechanisms"
            else
                fail "UNDECLARED cron:$cron_line — a crontab entry in the fleet namespace names no declared job's script"
            fi
        done <<EOF
$cron_rows
EOF
        [ "$QUIET" = 1 ] || printf 'measured cron: in_scope=%s\n' "$cron_in_scope"
    fi

    # 4. the surface must not be empty: zero in-scope jobs means either nothing is scheduled or the
    #    namespace/prefix is wrong, and both are failures for a box the fleet claims to schedule.
    CHECKS=$((CHECKS + 1))
    if [ "${in_scope:-0}" -eq 0 ]; then
        fail "NO-JOBS the $PLATFORM surface is readable but carries ZERO in-scope scheduled jobs — nothing on this host is scheduled by the fleet"
    fi
    [ "$QUIET" = 1 ] || printf 'measured %s: in_scope=%s unmanaged=%s out_of_scope_excluded=%s\n' \
        "$PLATFORM" "${in_scope:-?}" "$UNMANAGED" "$(printf '%s' "$meta" | sed -n 's/.*excluded=\([0-9]*\).*/\1/p')"
    return 0
}

UNMANAGED=0
require_functions
static_checks; STATIC_RC=$?
if [ "$STATIC_RC" = 3 ]; then
    echo "verdict=UNMEASURABLE platform=$PLATFORM mode=$MODE checks=$CHECKS"
    exit 3
fi
if [ "$MODE" = live ]; then
    live_checks; LIVE_RC=$?
    if [ "$LIVE_RC" = 3 ]; then
        echo "verdict=UNMEASURABLE platform=$PLATFORM checks=$CHECKS"
        exit 3
    fi
fi

if [ "$FAILS" -gt 0 ]; then
    echo "verdict=FAIL platform=$PLATFORM mode=$MODE failures=$FAILS checks=$CHECKS"
    exit 1
fi
echo "verdict=OK platform=$PLATFORM mode=$MODE checks=$CHECKS unmanaged=$UNMANAGED"
exit 0
