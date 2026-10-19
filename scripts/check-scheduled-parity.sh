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
#   STALE-REGISTER   the unmanaged register names a job that is no longer live         → FAIL
#   NO-REASON        an unmanaged register entry carries no reason                     → FAIL
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
TMPDIR_SJ_ERR="$(mktemp "${TMPDIR:-/tmp}/sj-perr.XXXXXX")" || TMPDIR_SJ_ERR=/dev/null
trap 'rm -f "$TMPDIR_SJ_ERR"' EXIT

# ── static half: the declaration must be installable on BOTH platforms ────────────────────────
# This is not a formality: it is what makes "one declaration rendered for both platforms" TRUE rather
# than claimed. Every record is rendered for EVERY platform it declares, and an artifact that cannot be
# produced (an unresolvable script, an unresolved placeholder, a malformed plist) is a FAILURE here —
# before any scheduler is touched.
SJ_FARM="${SJ_FARM:-${HOME:-}/.pi/agent/scripts}"
static_checks() {
    local errs id plat d out
    errs="$(sj_validate 2>&1)"; local vrc=$?
    CHECKS=$((CHECKS + 1))
    if [ "$vrc" -ne 0 ]; then
        while IFS= read -r out; do [ -n "$out" ] && fail "declaration: $out"; done <<EOF
$errs
EOF
    fi
    d="$(mktemp -d "${TMPDIR:-/tmp}/sj-parity.XXXXXX")" || { fail "cannot create a temp dir"; return 1; }
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

# ⛔ THE PAYLOAD. A label and a cadence can be preserved while the PROGRAM is replaced — that is what
# a hijacked agent looks like, and reading only the interval gave it the fleet's blessing. For a
# record this command actually installs (`managed=yes`), compare what the artifact will RUN against
# what the record renders. `managed=no` artifacts belong to another installer whose command line this
# declaration does not model, so only their existence/cadence is asserted here.
payload_drift() { # payload_drift <id> <rendered-expected> <installed-argv|execstart>
    local id="$1" want="$2" got="$3"
    CHECKS=$((CHECKS + 1))
    [ "$want" = "$got" ] && return 0
    fail "PAYLOAD-DRIFT $id — the installed job does not run what the declaration says: installed [$got], declared [$want]"
    return 0
}

# Render the record's own artifact and compare the PROGRAM it would install with the one that is
# installed. The mode flag is taken from the ARTIFACT, not from the declaration: arming is a separate,
# visible step (#1678), so an armed job is not drift — a job running a different script is.
payload_checks() { # payload_checks <id> <installed-name>
    local id="$1" name="$2" d arm="" want got
    case "$PLATFORM" in
        darwin)
            local f; f="$(sj_launchd_dir)/$name.plist"
            got="$(sj_launchd_argv "$f" 2>/dev/null)" || got=""
            case "$got" in
                *--apply*)   arm=armed ;;
                *--dry-run*) arm=report-only ;;
            esac
            [ -n "$(sj_field "$id" arming)" ] || arm=""
            want="$(sj_argv "$id" darwin "$arm" 2>/dev/null)" || { CHECKS=$((CHECKS + 1)); fail "PAYLOAD-DRIFT $id — the record cannot render an argv for this host (runner/script unresolved)"; return 0; }
            payload_drift "$id" "$want" "$got"
            ;;
        linux)
            local svc; svc="$(sj_systemd_units_dir)/$name.service"
            got="$(sj_systemd_execstart "$svc" 2>/dev/null)" || got=""
            case "$got" in
                *--apply*)   arm=armed ;;
                *--dry-run*) arm=report-only ;;
            esac
            [ -n "$(sj_field "$id" arming)" ] || arm=""
            d="$(mktemp -d "${TMPDIR:-/tmp}/sj-payload.XXXXXX")" || { CHECKS=$((CHECKS + 1)); fail "PAYLOAD-DRIFT $id — cannot render the record to compare"; return 0; }
            if sj_render_systemd "$id" "$d" system "$arm" >/dev/null 2>&1; then
                want="$(sj_systemd_execstart "$d/$name.service" 2>/dev/null)"
            else
                want=""
            fi
            rm -rf "$d"
            payload_drift "$id" "$want" "$got"
            ;;
    esac
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
    local cron_rows cron_line cron_script matched cron_in_scope=0 cron_err
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
                case "$cron_line" in *"${cron_script##*/}"*) matched="$id" ;; esac
            done
            if [ -n "$matched" ]; then
                say "note: crontab also triggers declared job '$matched' — a second clock for one job (not a parity failure, worth removing)"
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
static_checks
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
