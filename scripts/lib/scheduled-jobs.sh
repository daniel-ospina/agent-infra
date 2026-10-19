#!/usr/bin/env bash
# scripts/lib/scheduled-jobs.sh — the ONE parser, renderer and live-surface reader behind
# agent-infra#2048. Sourced by scripts/scheduled-jobs.sh (the installer/controller) and by
# scripts/check-scheduled-parity.sh (the gate). ⛔ Neither of those may keep its own copy of anything
# in here: two parsers is how a declaration stops describing what is installed.
#
# WHAT THIS FILE OWNS
#   * parsing config/scheduled-jobs.declaration into records (awk; bash-3.2 safe — the laptop's
#     /bin/bash is 3.2, so no associative arrays, no ${x,,}, no mapfile)
#   * validating them (unknown key = ERROR, never a silently ignored line)
#   * RENDERING the two platform artifacts from ONE record: a systemd `.service`+`.timer`, a launchd
#     `.plist`. The platform is a rendering parameter, not a second implementation.
#   * reading the LIVE scheduler surface (launchd labels + loaded state, systemd timers + active
#     state, crontab lines) so the parity gate can compare it with the declaration.
#
# ⛔ MEASUREMENT DISCIPLINE (this repo's own rule). A surface this file could not read is NEVER
# reported as clean: every reader returns a distinguishable failure, and `sj_live_launchd` /
# `sj_live_systemd` say which populations they could not consult. Out-of-namespace jobs (com.google.*,
# com.premise.*, …) are EXCLUDED and COUNTED, so "no undeclared job" can never mean "I looked at
# nothing".
#
# CONTRACT
#   sj_ids                        → the ids, file order, one per line
#   sj_field <id> <key>           → the value (empty when absent; the caller knows which keys are required)
#   sj_envs <id>                  → `KEY=VALUE` lines, declaration order
#   sj_has_platform <id> <plat>   → 0/1
#   sj_validate                   → 0 ok; 1 with one `error: …` line per defect; NEVER installs anything
#   sj_schedule_seconds <id>      → interval seconds (0 for calendar schedules)
#   sj_unit <id> / sj_label <id>  → rendered names used by every verb and by the gate
#   sj_render_systemd <id> <dir> <system|user>
#   sj_render_launchd <id> <dest>
#   sj_live_*                     → see the section headers
set -uo pipefail

SJ_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
SJ_REPO_ROOT="$(cd "$SJ_LIB_DIR/../.." 2>/dev/null && pwd)"
# shellcheck source=portable.sh
. "$SJ_LIB_DIR/portable.sh" || { echo "scheduled-jobs: cannot load the portability shim" >&2; exit 1; }

# ⛔ THE DECLARATION MUST BE FOUND BY THE **FARMED** COPY TOO. `pi-bootstrap/setup.sh` farms
# `scripts/scheduled-jobs.sh` to `~/.pi/agent/scripts/` and `cloud-cell-bringup.sh` prefers that copy,
# so `$SJ_REPO_ROOT` is `~/.pi/agent` there — a path that never holds `config/`. Resolving only beside
# the LIBRARY made every verb refuse on every provisioned box ("the declaration is missing"), which is
# the #2046 shape again: installed, and unable to do its work. So: the repo copy, then the FARMED
# copy (setup.sh farms the declaration beside the farmed command), and the error names both.
sj_decl_path() { # sj_decl_path <basename>
    local name="$1" cand
    for cand in "$SJ_REPO_ROOT/config/$name" \
                "${SJ_FARM:-${HOME:-}/.pi/agent/scripts}/config/$name"; do
        [ -f "$cand" ] && { printf '%s\n' "$cand"; return 0; }
    done
    printf '%s\n' "$SJ_REPO_ROOT/config/$name"
    return 1
}
SJ_DECL="${SJ_DECLARATION:-$(sj_decl_path scheduled-jobs.declaration)}"
SJ_UNMANAGED="${SJ_UNMANAGED_REGISTER:-$(sj_decl_path scheduled-jobs.unmanaged)}"

# The desktop platforms this fleet runs on. A declaration naming anything else is a validation error:
# "it would work on FreeBSD" is not a schedule, and a typo'd `platforms=linuxx` must not silently
# become "not installed anywhere".
SJ_PLATFORMS="linux darwin"

# Keys a record may carry. ⛔ An UNKNOWN key is an error, not a comment: a misspelled `platfroms=`
# would otherwise render a Linux-only job and report parity clean, which is the silent-default class
# this whole feature exists to remove.
SJ_KEYS="platforms schedule script runner args arming managed owner label unit description env"

# ── parsing ───────────────────────────────────────────────────────────────────────────────────
sj_ids() {
    [ -f "$SJ_DECL" ] || return 1
    awk '
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*$/  { next }
        $1 == "job" { if ($2 != "") print $2 }
    ' "$SJ_DECL"
}

sj_field() { # sj_field <id> <key>
    [ -f "$SJ_DECL" ] || return 1
    awk -v id="$1" -v key="$2" '
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*$/  { next }
        $1 == "job" { cur = $2; next }
        cur != id { next }
        {
            line = $0
            sub(/^[[:space:]]+/, "", line); sub(/[[:space:]]+$/, "", line)
            if (line ~ /^env[[:space:]]/) next
            eq = index(line, "=")
            if (eq == 0) next
            k = substr(line, 1, eq - 1); v = substr(line, eq + 1)
            gsub(/[[:space:]]/, "", k)
            sub(/^[[:space:]]+/, "", v); sub(/[[:space:]]+$/, "", v)
            if (k == key) print v
        }
    ' "$SJ_DECL"
}

sj_envs() { # sj_envs <id> — `KEY=VALUE` per line
    [ -f "$SJ_DECL" ] || return 1
    awk -v id="$1" '
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*$/  { next }
        $1 == "job" { cur = $2; next }
        cur != id { next }
        {
            line = $0
            sub(/^[[:space:]]+/, "", line); sub(/[[:space:]]+$/, "", line)
            if (line !~ /^env[[:space:]]+/) next
            sub(/^env[[:space:]]+/, "", line)
            sub(/[[:space:]]+$/, "", line)
            eq = index(line, "=")
            if (eq == 0) next
            k = substr(line, 1, eq - 1); v = substr(line, eq + 1)
            gsub(/[[:space:]]/, "", k)
            sub(/^[[:space:]]+/, "", v); sub(/[[:space:]]+$/, "", v)
            print k "=" v
        }
    ' "$SJ_DECL"
}

sj_has_platform() { # sj_has_platform <id> <linux|darwin>
    local p
    for p in $(printf '%s' "$(sj_field "$1" platforms)" | tr ',' ' '); do
        [ "$p" = "$2" ] && return 0
    done
    return 1
}

sj_schedule_seconds() { # sj_schedule_seconds <id> — 0 for a calendar schedule
    local s n
    s="$(sj_field "$1" schedule)"
    case "$s" in
        hourly)  printf '3600\n' ;;
        daily)   printf '86400\n' ;;
        weekly)  printf '604800\n' ;;
        *s) n="${s%s}"; case "$n" in ''|*[!0-9]*) return 1 ;; esac; printf '%s\n' "$n" ;;
        *m) n="${s%m}"; case "$n" in ''|*[!0-9]*) return 1 ;; esac; printf '%s\n' "$(( n * 60 ))" ;;
        *h) n="${s%h}"; case "$n" in ''|*[!0-9]*) return 1 ;; esac; printf '%s\n' "$(( n * 3600 ))" ;;
        *) return 1 ;;
    esac
}

sj_unit()  { local u; u="$(sj_field "$1" unit)";  printf '%s\n' "${u:-$1}"; }
sj_label() { sj_field "$1" label; }

# ── script resolution ────────────────────────────────────────────────────────────────────────
# The FARM first: it is what a box actually has after `pi-bootstrap/setup.sh`, and a job pointing at a
# worktree checkout breaks the day that worktree is reaped — by this very reaper.
# A path that is SET but missing is a refusal, never a silent search for a different file.
sj_resolve_script() { # sj_resolve_script <id>
    local s cand farm
    s="$(sj_field "$1" script)"
    [ -n "$s" ] || return 1
    farm="${SJ_FARM:-${HOME:-}/.pi/agent/scripts}"
    case "$s" in /*) [ -f "$s" ] && { printf '%s\n' "$s"; return 0; }; return 1 ;; esac
    for cand in "$farm/$s" "$SJ_REPO_ROOT/scripts/$s"; do
        [ -f "$cand" ] && { printf '%s\n' "$cand"; return 0; }
    done
    # A job another installer owns: the farmed path is what IT installs, whether or not this checkout
    # carries a copy. Rendering the declaration must not require this repo to hold someone else's tool
    # (that is how `lane-liveness` made `--static` — the CI mode — fail on a clean runner).
    if [ "$(sj_field "$1" managed)" = no ]; then printf '%s\n' "$farm/$s"; return 0; fi
    return 1
}

# ── validation ──────────────────────────────────────────────────────────────────────────────
# Every defect is reported, then the exit status is non-zero: a caller never installs half a set.
sj_validate() {
    local rc=0 ids id seen="" seen_labels="" seen_units="" k v p s
    if [ ! -f "$SJ_DECL" ]; then
        echo "error: the declaration is missing — looked in $SJ_REPO_ROOT/config/ and ${SJ_FARM:-${HOME:-}/.pi/agent/scripts}/config/ (got: $SJ_DECL). There is nothing to install or verify."
        return 1
    fi
    ids="$(sj_ids)"
    if [ -z "$ids" ]; then
        echo "error: the declaration has no records ($SJ_DECL) — an empty schedule is not a schedule"
        return 1
    fi
    # ⛔ A KEY BEFORE ANY `job` LINE BELONGS TO NO RECORD. Every parser here skips lines until it is
    # inside the record it wants, so an `env`/`args`/`description` line pasted above the first `job`
    # is dropped by all of them and the job half-declares with validation green — an `env` that never
    # reaches the artifact, reported as OK. Position is a real shape, so it is validated, not assumed.
    local orphan
    orphan="$(awk '
        /^[[:space:]]*#/ { next } /^[[:space:]]*$/ { next }
        $1 == "job" { seen = 1; next }
        !seen { print NR": "$0 }' "$SJ_DECL")"
    if [ -n "$orphan" ]; then
        echo "error: the declaration has content BEFORE the first 'job' record — it belongs to no job and no renderer would use it:
$orphan"
        rc=1
    fi
    for id in $ids; do
        case " $seen " in *" $id "*) echo "error: duplicate job '$id'"; rc=1 ;; esac
        seen="$seen $id"
        case "$id" in *[!A-Za-z0-9._-]*) echo "error: job '$id' has characters a unit name cannot carry"; rc=1 ;; esac
        # Unknown keys — the typo guard.
        while IFS= read -r k; do
            [ -n "$k" ] || continue
            case " $SJ_KEYS " in *" $k "*) ;; *) echo "error: job '$id' has an unknown key '$k'"; rc=1 ;; esac
        done <<EOF
$(awk -v id="$id" '
    /^[[:space:]]*#/ { next } /^[[:space:]]*$/ { next }
    $1 == "job" { cur = $2; next }
    cur != id { next }
    { line = $0; sub(/^[[:space:]]+/, "", line)
      if (line ~ /^env[[:space:]]/) next
      eq = index(line, "="); if (eq == 0) { print line; next }
      k = substr(line, 1, eq - 1); gsub(/[[:space:]]/, "", k); print k }' "$SJ_DECL")
EOF
        # Required keys.
        for k in platforms schedule runner managed; do
            [ -n "$(sj_field "$id" "$k")" ] || { echo "error: job '$id' is missing '$k'"; rc=1; }
        done
        v="$(sj_field "$id" platforms)"
        for p in $(printf '%s' "$v" | tr ',' ' '); do
            case " $SJ_PLATFORMS " in *" $p "*) ;; *) echo "error: job '$id' declares an unknown platform '$p'"; rc=1 ;; esac
        done
        v="$(sj_field "$id" runner)"
        case "$v" in bash|python|python-launcher|'') ;; *) echo "error: job '$id' has an unknown runner '$v'"; rc=1 ;; esac
        v="$(sj_field "$id" managed)"
        case "$v" in yes|no|'') ;; *) echo "error: job '$id' has 'managed=$v' (want yes|no)"; rc=1 ;; esac
        v="$(sj_field "$id" arming)"
        case "$v" in ''|report-only|armed) ;; *) echo "error: job '$id' has an unknown arming '$v' (want report-only|armed)"; rc=1 ;; esac
        s="$(sj_field "$id" schedule)"
        case "$s" in
            hourly|daily|weekly) ;;
            '') ;;
            *) if ! sj_schedule_seconds "$id" >/dev/null; then
                   echo "error: job '$id' has an unparseable schedule '$s'"; rc=1
               elif [ "$(sj_schedule_seconds "$id")" -le 0 ]; then
                   # `0s` renders `StartInterval 0` / `OnUnitActiveSec=0s`: installed, enabled, and
                   # never fires. A schedule that cannot fire is not a schedule.
                   echo "error: job '$id' has schedule '$s', which resolves to 0 seconds — a job that never fires"; rc=1
               fi ;;
        esac
        # Ownership is never implied: an unmanaged record names who DOES install it.
        if [ "$(sj_field "$id" managed)" = "no" ] && [ -z "$(sj_field "$id" owner)" ]; then
            echo "error: job '$id' is managed=no but names no owner — an unowned schedule is how a job goes missing"; rc=1
        fi
        # A Darwin record needs a label, and a managed one needs a resolvable script: both are
        # rendered into an artifact, and a missing either produces an INERT job that looks scheduled.
        if sj_has_platform "$id" darwin && [ -z "$(sj_label "$id")" ]; then
            echo "error: job '$id' runs on darwin but declares no label"; rc=1
        fi
        # ⛔ AN ARTIFACT NAME IS NOT FREE TEXT: it becomes a FILENAME in a directory the scheduler owns.
        # `unit=../../x` (or a label with a slash) writes outside that directory — verified: the
        # renderer honoured it and put the units two levels above the caller. `job <id>` was checked
        # for this; the two keys that name the artifact were not.
        for k in label unit; do
            v="$(sj_field "$id" "$k")"
            [ -n "$v" ] || continue
            case "$v" in
                *[!A-Za-z0-9._@-]*|.|..) echo "error: job '$id' has $k='$v' — an artifact name may not carry a path separator or traversal"; rc=1 ;;
            esac
        done
        if [ "$(sj_field "$id" managed)" = "yes" ] && ! sj_resolve_script "$id" >/dev/null; then
            echo "error: job '$id' is managed=yes but its script '$(sj_field "$id" script)' does not resolve (looked in \${SJ_FARM:-$HOME/.pi/agent/scripts} and $SJ_REPO_ROOT/scripts)"
            rc=1
        fi
        # Two records must never claim one schedule artifact: whichever installs second would silently
        # own what the first declared.
        if sj_has_platform "$id" darwin; then
            case " $seen_labels " in *" $(sj_label "$id") "*) echo "error: two records claim the launchd label $(sj_label "$id")"; rc=1 ;; esac
            seen_labels="$seen_labels $(sj_label "$id")"
        fi
        if sj_has_platform "$id" linux; then
            case " $seen_units " in *" $(sj_unit "$id") "*) echo "error: two records claim the systemd unit $(sj_unit "$id")"; rc=1 ;; esac
            seen_units="$seen_units $(sj_unit "$id")"
        fi
    done
    return "$rc"
}

# ── rendering: ONE record, two platforms ────────────────────────────────────────────────────
sj_xml() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
sj_sysd_quote() { printf '"%s"' "$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/%/%%/g')"; }

# The command line for this record, as argv words (one per line) — the single place the runner
# difference lives, so the two renderers cannot disagree about what runs.
sj_argv() { # sj_argv <id> <linux|darwin> [report-only|armed|""]
    local id="$1" plat="$2" mode="${3:-}" script args runner py launcher a
    script="$(sj_resolve_script "$id")" || return 1
    runner="$(sj_field "$id" runner)"; [ -n "$runner" ] || runner=bash
    args="$(sj_field "$id" args)"
    case "$runner" in
        bash)
            printf '%s\n' "/bin/bash" "$script" ;;
        python)
            py="${SJ_PYTHON_BIN:-python3}"
            printf '%s\n' "$py" "$script" ;;
        python-launcher)
            if [ "$plat" = darwin ]; then
                py="${SJ_PYTHON_BIN:-$(command -v python3 2>/dev/null)}"
                [ -n "$py" ] || return 1
                launcher="${SJ_LAUNCHER:-${HOME:-}/.pi/agent/scripts/pi-reap-worktrees-launchd.py}"
                # The farmed copy is what the job would run; the repo copy is the same file and is
                # what makes the declaration renderable before a box is provisioned (the CI mode).
                [ -f "$launcher" ] || launcher="$SJ_REPO_ROOT/scripts/pi-reap-worktrees-launchd.py"
                [ -f "$launcher" ] || return 1
                printf '%s\n' "$py" "$launcher" "--script" "$script"
            else
                # Linux has no TCC; the launcher would be a pointless extra process. The SEAM is data.
                printf '%s\n' "/bin/bash" "$script"
            fi
            ;;
        *) return 1 ;;
    esac
    # Fixed arguments, split on spaces. A record needing a quoted space in an argument would need a
    # richer format, and none does — say so here rather than silently mangling one.
    for a in $args; do printf '%s\n' "$a"; done
    # ⛔ ARMING IS RENDERED INTO THE ARTIFACT (#1678). An empty `arming` means "this job takes no mode
    # flag"; `report-only` and `armed` are the two stances, and the flag they produce is readable from
    # the installed unit/plist without asking the installer what it was told.
    case "$mode" in
        '') ;;
        report-only) printf -- '--dry-run\n' ;;
        armed)       printf -- '--apply\n' ;;
        *) return 1 ;;
    esac
}

sj_render_systemd() { # sj_render_systemd <id> <destdir> <system|user> [arming-override]
    local id="$1" dir="$2" scope="${3:-system}" arm="${4:-}" unit argv a k v desc exec_line=""
    unit="$(sj_unit "$id")"
    arm="${arm:-$(sj_field "$id" arming)}"
    argv="$(sj_argv "$id" linux "$arm")" || return 1
    desc="$(sj_field "$id" description)"; [ -n "$desc" ] || desc="$id"
    mkdir -p "$dir" || return 1

    {
        printf '# RENDERED from config/scheduled-jobs.declaration by scripts/scheduled-jobs.sh — do not edit.\n'
        printf '# The declaration is the source of truth (agent-infra#2048); an edit here is reverted on the\n'
        printf '# next install and is invisible to the parity check.\n'
        printf '[Unit]\n'
        printf 'Description=%s\n' "$desc"
        printf 'Documentation=https://github.com/daniel-ospina/agent-infra/blob/main/docs/ops/scheduled-jobs.md\n'
        printf 'After=local-fs.target\n'
        printf 'DefaultDependencies=no\n\n'
        printf '[Service]\n'
        printf 'Type=oneshot\n'
        [ "$scope" = system ] && printf 'User=%s\n' "$(id -un)"
        printf 'Environment=HOME=%s\n' "$HOME"
        # The renderer is called by the installer, the farm and the parity gate; the gate's `$PLATFORM`
        # is NOT part of the library's contract. A bare `$PLATFORM` under `set -u` aborted the render
        # half-way through writing the unit, so the platform is resolved by ONE helper.
        printf 'Environment=PATH=%s\n' "$(sj_job_path "$(sj_render_platform)")"
        printf 'Environment=SJ_JOB=%s\n' "$id"
        while IFS= read -r k; do
            [ -n "$k" ] || continue
            v="${k#*=}"; k="${k%%=*}"
            printf 'Environment=%s=%s\n' "$k" "$(sj_render_value "$v")"
        done <<EOF
$(sj_envs "$id")
EOF
        # Never compete with a lane for CPU or I/O: a background sweep, not a deadline.
        printf 'Nice=10\n'
        printf 'IOSchedulingClass=idle\n'
        # ⛔ NO SuccessExitStatus. The retired unit carried `SuccessExitStatus=0 4 5`, which made a
        # pass that failed a class (4) or found un-reclaimed work (5) read as SUCCESS to `systemctl
        # status` — a false PASS in the scheduler's own vocabulary. Requirement of #2048: a non-zero
        # exit is a FAILURE, so the status is left alone and `scheduled-jobs.sh status` reports it.
        printf 'TimeoutStartSec=3600\n'
        while IFS= read -r a; do
            exec_line="${exec_line}${exec_line:+ }$(sj_sysd_quote "$a")"
        done <<EOF
$argv
EOF
        printf 'ExecStart=%s\n' "$exec_line"
    } >"$dir/$unit.service" || return 1

    {
        printf '# RENDERED from config/scheduled-jobs.declaration by scripts/scheduled-jobs.sh — do not edit.\n'
        printf '[Unit]\n'
        printf 'Description=%s schedule (%s)\n' "$id" "$(sj_field "$id" schedule)"
        printf '\n[Timer]\n'
        sj_timer_lines "$id"
        printf 'Unit=%s.service\n\n[Install]\nWantedBy=timers.target\n' "$unit"
    } >"$dir/$unit.timer" || return 1
    return 0
}

# The calendar/interval half of a timer. Persistent=true on a calendar timer means a cell that was
# suspended runs one pass as soon as it comes back instead of waiting out a whole interval at 97% used.
sj_timer_lines() { # sj_timer_lines <id>
    local s secs
    s="$(sj_field "$1" schedule)"
    case "$s" in
        hourly) printf 'OnCalendar=hourly\nRandomizedDelaySec=300\nPersistent=true\n' ;;
        daily)  printf 'OnCalendar=daily\nRandomizedDelaySec=300\nPersistent=true\n' ;;
        weekly) printf 'OnCalendar=weekly\nRandomizedDelaySec=300\nPersistent=true\n' ;;
        *)
            secs="$(sj_schedule_seconds "$1")" || return 1
            printf 'OnBootSec=5min\nOnUnitActiveSec=%ss\n' "$secs"
            ;;
    esac
}

sj_render_launchd() { # sj_render_launchd <id> <destfile> [arming-override]
    local id="$1" dest="$2" arm="${3:-}" label argv a k v secs s
    label="$(sj_label "$id")"; [ -n "$label" ] || return 1
    arm="${arm:-$(sj_field "$id" arming)}"
    argv="$(sj_argv "$id" darwin "$arm")" || return 1
    {
        printf '<?xml version="1.0" encoding="UTF-8"?>\n'
        printf '<!-- RENDERED from config/scheduled-jobs.declaration by scripts/scheduled-jobs.sh — do not edit.\n'
        printf '     The declaration is the source of truth (agent-infra#2048). An edit here is reverted on the\n'
        printf '     next install and is invisible to the parity check. -->\n'
        printf '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
        printf '<plist version="1.0">\n<dict>\n'
        printf '    <key>Label</key>\n    <string>%s</string>\n' "$(sj_xml "$label")"
        printf '    <key>ProgramArguments</key>\n    <array>\n'
        while IFS= read -r a; do printf '        <string>%s</string>\n' "$(sj_xml "$a")"; done <<EOF
$argv
EOF
        printf '    </array>\n'
        printf '    <key>EnvironmentVariables</key>\n    <dict>\n'
        printf '        <key>PATH</key>\n        <string>%s</string>\n' "$(sj_xml "$(sj_job_path darwin)")"
        printf '        <key>HOME</key>\n        <string>%s</string>\n' "$(sj_xml "$HOME")"
        printf '        <key>SJ_JOB</key>\n        <string>%s</string>\n' "$(sj_xml "$id")"
        while IFS= read -r k; do
            [ -n "$k" ] || continue
            v="${k#*=}"; k="${k%%=*}"
            k="$(sj_render_value "$k")"; v="$(sj_render_value "$v")"
            printf '        <key>%s</key>\n        <string>%s</string>\n' "$(sj_xml "$k")" "$(sj_xml "$v")"
        done <<EOF
$(sj_envs "$id")
EOF
        printf '    </dict>\n'
        printf '    <key>RunAtLoad</key>\n    <true/>\n'
        s="$(sj_field "$id" schedule)"
        case "$s" in
            daily)  printf '    <key>StartCalendarInterval</key>\n    <dict><key>Hour</key><integer>6</integer><key>Minute</key><integer>0</integer></dict>\n' ;;
            weekly) printf '    <key>StartCalendarInterval</key>\n    <dict><key>Weekday</key><integer>0</integer><key>Hour</key><integer>6</integer><key>Minute</key><integer>0</integer></dict>\n' ;;
            *)
                secs="$(sj_schedule_seconds "$id")" || return 1
                printf '    <key>StartInterval</key>\n    <integer>%s</integer>\n' "$secs"
                ;;
        esac
        printf '    <key>ProcessType</key>\n    <string>Background</string>\n'
        printf '    <key>LowPriorityIO</key>\n    <true/>\n'
        printf '    <key>Nice</key>\n    <integer>10</integer>\n'
        printf '</dict>\n</plist>\n'
    } >"$dest" || return 1
    return 0
}

# sj_job_path — the PATH a RENDERED DARWIN JOB gets.
#
# ⛔ A shim dir must never reach a launchd job (#2048 review, BLOCK; #427). `~/.pi/agent/shims/gh` is a
# symlink into `~/Documents`, which TCC denies to a launchd-spawned process, so the job resolves `gh`,
# gets EPERM and fails closed — the reaper's worktree class would abort every hour on the one platform
# this PR exists for, with a message telling the operator to install a `gh` the box already has.
# `install-launchd.sh:launchd_path` strips `*/shims` for the same reason; the shared renderer must
# apply the same rule or the two installers disagree about the same box. Linux keeps its PATH: systemd
# runs as the user with no TCC boundary.
# ⛔ ONE PLATFORM RESOLVER. `sj_job_path` strips the macOS shim dirs, so it must be told the platform —
# and the renderers are called from the installer, the farm AND the gate, which do not all export
# `PLATFORM`. Defaulting differently per call site (linux here, darwin there) meant one render embedded
# the shims while the other stripped them, and the artifacts differed for no reason.
sj_render_platform() { # sj_render_platform -> darwin|linux, from the caller or the box itself
    if [ -n "${PLATFORM:-}" ]; then printf '%s\n' "$PLATFORM"; return 0; fi
    case "$(uname -s 2>/dev/null)" in
        Darwin) printf 'darwin\n' ;;
        *)      printf 'linux\n' ;;
    esac
}

sj_job_path() { # sj_job_path <platform>
    local out="" p glob_was_off=0
    local IFS=:
    case "$-" in *f*) glob_was_off=1 ;; esac
    set -f
    for p in $PATH; do
        case "$p" in "") continue ;; esac
        case "$1" in
            darwin) case "$p" in */shims|*/shims/*) continue ;; esac ;;
        esac
        out="${out:+$out:}$p"
    done
    [ "$glob_was_off" = 1 ] || set +f
    printf '%s' "$out"
}

# ── machine-state placeholders ──────────────────────────────────────────────────────────────
# ONE resolver, used by both renderers, so the state dir a cell's unit exports and the one a Mac's
# plist exports cannot drift.
sj_render_value() { # sj_render_value <string>
    local v="$1"
    v="${v//@home/$HOME}"
    v="${v//@path/$(sj_job_path "$(sj_render_platform)")}"
    v="${v//@state/${SJ_STATE_DIR:-$HOME/.pi/agent/state}}"
    v="${v//@repos/${SJ_REPOS:-${SJ_TORTOISE_REPO:-${TORTOISE_REPO:-$HOME/Documents/GitHub/tortoise}}}}"
    v="${v//@tortoise/${SJ_TORTOISE_REPO:-${TORTOISE_REPO:-$HOME/Documents/GitHub/tortoise}}}"
    printf '%s' "$v"
}

# ── the live scheduler surface ──────────────────────────────────────────────────────────────
# Each reader prints one record per job and returns 0 only when the surface was actually read. A
# failure is 1 with a reason on stderr — the caller must NOT read that as "nothing scheduled" (an
# empty surface is never a green one).

sj_launchd_dir()  { printf '%s\n' "${SJ_LAUNCHD_DIR:-${HOME:-}/Library/LaunchAgents}"; }
sj_launchctl()    { printf '%s\n' "${SJ_LAUNCHCTL:-launchctl}"; }
# In scope: the fleet's own labels. Everything else (com.google.*, com.premise.*, com.minutes.*) is a
# third-party agent that this repo neither installs nor verifies — EXCLUDED AND COUNTED, never assumed
# absent.
sj_in_namespace() {
    local ns p re=""
    ns="${SJ_NAMESPACES:-com.eldato.,com.tortoise.}"
    for p in $(printf '%s' "$ns" | tr ',' ' '); do
        [ -n "$p" ] || continue
        re="${re}${re:+|}$(printf '%s' "$p" | sed -e 's/[.]/\\./g')"
    done
    [ -n "$re" ] || return 1
    grep -Eq "^($re)" <<<"$1"
}

sj_live_launchd() { # prints: <label>|<installed yes/no>|<loaded yes/no>|<cadence>|<svc yes>
    local dir lc label loaded cadence f skipped=0 total=0
    dir="$(sj_launchd_dir)"; lc="$(sj_launchctl)"
    case "$lc" in */*) [ -x "$lc" ] || { echo "sj_live_launchd: launchctl is not executable ($lc)" >&2; return 1; } ;;
                      *) command -v "$lc" >/dev/null 2>&1 || { echo "sj_live_launchd: launchctl not found ($lc)" >&2; return 1; } ;;
    esac
    if [ ! -d "$dir" ]; then
        echo "sj_live_launchd: no agent directory ($dir) — this box has no launchd surface to read" >&2
        return 1
    fi
    # ⛔ A DISABLED JOB IS INERT, NOT "installed and fine" — and only macOS knows this state, through
    # `launchctl print-disabled`. The systemd reader checks enablement three times; this one checked it
    # never, so a `launchctl disable`d job read as healthy on the Mac while the same state was INERT on
    # a cell. Measured on this box: eight in-namespace labels are `=> disabled`. An unreadable
    # `print-disabled` is a MEASUREMENT GAP (exit 3), exactly like an unreadable `launchctl list`.
    local disabled_list dsrc
    disabled_list="$("$lc" print-disabled "${SJ_LAUNCHD_DOMAIN:-gui/$(id -u)}" 2>/dev/null)"; dsrc=$?
    if [ "$dsrc" -ne 0 ]; then
        echo "sj_live_launchd: 'launchctl print-disabled' failed (rc=$dsrc) — whether these jobs are ENABLED cannot be read, so 'active' would be a guess" >&2
        return 1
    fi
    # Files first: a plist on disk is the strongest "installed" signal, and it is what survives a
    # reboot. Non-`.plist` entries (`.bak-*`, `.disabled`) are NOT jobs and are counted separately so
    # the exclusion is visible rather than silent.
    for f in "$dir"/*.plist; do
        [ -f "$f" ] || continue
        label="$(basename "$f" .plist)"
        if ! sj_in_namespace "$label"; then skipped=$((skipped + 1)); continue; fi
        total=$((total + 1))
        if "$lc" print "${SJ_LAUNCHD_DOMAIN:-gui/$(id -u)}/$label" >/dev/null 2>&1; then loaded=yes; else loaded=no; fi
        # load and enablement are DIFFERENT states: a loaded-but-disabled job keeps firing from its
        # in-memory definition until logout, then never again.
        case "$disabled_list" in
            *"\"$label\" => disabled"*) loaded="$loaded:disabled" ;;
        esac
        cadence="$(sj_launchd_cadence "$f")"
        # svc=yes: on launchd the plist IS the payload, so the artifact cannot exist without one.
        printf '%s|yes|%s|%s|yes\n' "$label" "$loaded" "$cadence"
    done
    for f in "$dir"/*; do
        [ -e "$f" ] || continue
        case "$f" in *.plist) continue ;; esac
        skipped=$((skipped + 1))
    done
    # A label loaded from somewhere other than the agent dir (a /Library/LaunchAgents drop, or a
    # state-only registration) still RUNS, so it is still in scope. `launchctl list` is the only
    # surface that shows it.
    # ⛔ ITS EXIT STATUS IS THE MEASUREMENT. `launchctl list` failing means this population was NOT
    # read — and it is the ONLY population that can see a job loaded from another directory, so
    # swallowing the failure made a live undeclared job invisible while every published count stayed
    # the same (in_scope counts the agent DIR). An unreadable surface is exit 3, never "nothing found".
    local listing lrc
    listing="$("$lc" list 2>/dev/null)"; lrc=$?
    if [ "$lrc" -ne 0 ]; then
        echo "sj_live_launchd: 'launchctl list' failed (rc=$lrc) — the loaded-job population is UNREADABLE; a job loaded from another directory would be invisible" >&2
        return 1
    fi
    while IFS= read -r label; do
        [ -n "$label" ] || continue
        sj_in_namespace "$label" || continue
        [ -f "$dir/$label.plist" ] && continue
        # A job loaded from ANOTHER directory is held by launchd exactly like a local one, so the same
        # enablement rule applies to it.
        case "$disabled_list" in
            *"\"$label\" => disabled"*) printf '%s|no|yes:disabled|unknown|no\n' "$label"; continue ;;
        esac
        printf '%s|no|yes|unknown|no\n' "$label"
    done <<EOF
$(printf '%s\n' "$listing" | awk 'NR>1 && NF>=3 {print $3}')
EOF
    # Declare the populations this reader could NOT consult (#2048: a report must name what it could
    # not measure — silence about a lane no population can contain is indistinguishable from clean).
    printf '#meta|dir=%s|in_scope=%s|excluded=%s|daemons=not_consulted\n' "$dir" "$total" "$skipped"
    return 0
}

# ── the schedule an installed artifact actually carries ────────────────────────────────────────
# `interval:<N>` | `cadence:hourly|daily|weekly` | `calendar:<keys>` | `none` | `unknown`.
#
# ⛔ AT THE GRANULARITY THE DECLARATION STATES. A record says `schedule=weekly`, a CADENCE — not a
# wall-clock time — so an artifact launched weekly at 06:30 is not in drift about what the record
# says, while one launched weekly IS drift from a record that says `900s`. Comparing exact calendar
# fields would fail another owner's job over a minute it never claimed.
sj_launchd_cadence() { # sj_launchd_cadence <plist>
    local f="$1"
    [ -f "$f" ] || { printf 'unknown\n'; return 0; }
    # Tokenise on `<`, so each XML node becomes `<token>` lines (`key>StartInterval`, `/key>`,
    # `integer>900`, `/integer>`), then a tiny state machine. No plutil dependency: this must answer
    # on a Linux runner exercising the darwin fixtures too, and plutil does not exist there.
    tr '<' '\n' <"$f" | awk '
        function emit(s) { print s; done = 1; exit }
        /^key>StartInterval$/ { st = "iv"; next }
        st == "iv" && /^integer>[0-9]+$/ { v = $0; sub(/^integer>/, "", v); emit("interval:" v) }
        st == "iv" && /^real>[0-9.]+$/ {
            v = $0; sub(/^real>/, "", v); sub(/\.0*$/, "", v)
            if (v ~ /^[0-9]+$/) emit("interval:" v)
            next }
        st == "iv" && /^key>/ { st = "" }
        /^key>StartCalendarInterval$/ { st = "cal"; keys = ""; next }
        st == "cal" && /^key>[A-Za-z]+$/ {
            k = $0; sub(/^key>/, "", k); keys = keys (keys == "" ? "" : ",") k; next }
        st == "cal" && /^\/dict>$/ {
            st = ""
            if (keys == "") emit("calendar:none")
            # launchd cannot express "hourly" without a Minute; Weekday means weekly. This is the
            # cadence vocabulary the declaration uses, read off the artifact.
            if (keys ~ /(^|,)Weekday(,|$)/) emit("cadence:weekly")
            if (keys ~ /(^|,)Hour(,|$)/)    emit("cadence:daily")
            if (keys ~ /(^|,)Minute(,|$)/ || keys ~ /(^|,)Second(,|$)/) emit("cadence:hourly")
            emit("calendar:" keys) }
        END { if (!done) print "unknown" }'
}

# The program + arguments an installed plist actually runs, one argv word per line. The payload is
# what an artifact can be HIJACKED with: keep the label and the cadence, replace the program, and the
# fleet's schedule blessing ships someone else's code. Read from the artifact, never assumed.
sj_launchd_argv() { # sj_launchd_argv <plist>
    local f="$1"
    [ -f "$f" ] || return 1
    tr '<' '\n' <"$f" | awk '
        /^key>ProgramArguments$/ { on = 1; next }
        on && /^\/array>$/ { done = 1; exit }
        on && /^string>/ { v = $0; sub(/^string>/, "", v); print v }
        END { if (!done) exit 1 }'
}

sj_systemd_units_dir() { printf '%s\n' "${SJ_SYSTEMD_UNIT_DIR:-/etc/systemd/system}"; }
sj_systemctl()         { printf '%s\n' "${SJ_SYSTEMCTL:-systemctl}"; }

# The schedule a systemd timer actually carries: `OnCalendar=hourly|daily|weekly` -> the same cadence
# vocabulary; `OnUnitActiveSec=<N>s` -> interval:<N>; anything else -> calendar:<raw>, which is NOT
# the declared cadence and is therefore reported rather than assumed equivalent.
sj_systemd_timer_cadence() { # sj_systemd_timer_cadence <timerfile>
    local f="$1" oc oua
    [ -f "$f" ] || { printf 'unknown\n'; return 0; }
    oc="$(sed -n 's/^[[:space:]]*OnCalendar[[:space:]]*=[[:space:]]*//p' "$f" | head -1)"
    case "$oc" in
        hourly|daily|weekly) printf 'cadence:%s\n' "$oc"; return 0 ;;
        '') ;;
        *) printf 'calendar:%s\n' "$oc"; return 0 ;;
    esac
    oua="$(sed -n 's/^[[:space:]]*OnUnitActiveSec[[:space:]]*=[[:space:]]*\([0-9][0-9]*\)s*$/\1/p' "$f" | head -1)"
    case "$oua" in ''|*[!0-9]*) ;; *) printf 'interval:%s\n' "$oua"; return 0 ;; esac
    printf 'none\n'
}

# The ExecStart= line an installed unit actually runs (payload, as on darwin).
sj_systemd_execstart() { # sj_systemd_execstart <servicefile>
    local f="$1"
    [ -f "$f" ] || return 1
    sed -n 's/^ExecStart=//p' "$f" | head -1
}

# The Environment KEYS an artifact carries — compared against the record's keys, so an env the
# declaration adds and the installed job lost is visible. VALUES are deliberately not compared:
# `@repos`/`@state` are rendered from the box at INSTALL time, and a parity run in a shell without
# them would report every job as drifted; the pinned values are what `status` reports on.
sj_artifact_env_keys() { # sj_artifact_env_keys <file...>
    # `Environment=KEY=value` (systemd) and `<key>KEY</key>` (plist). The non-job plist keys are
    # filtered with a fixed grep pattern rather than a built one, so a stray quote cannot end the
    # pipeline early and silently drop every key.
    sed -n \
        -e 's/^[[:space:]]*Environment=\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' \
        -e 's|^[[:space:]]*<key>\([A-Za-z_][A-Za-z0-9_]*\)</key>[[:space:]]*$|\1|p' \
        "$@" 2>/dev/null \
        | grep -v -x -e PATH -e HOME -e Label -e ProgramArguments -e EnvironmentVariables \
            -e RunAtLoad -e StartInterval -e StartCalendarInterval -e ProcessType \
            -e LowPriorityIO -e Nice -e SJ_JOB \
        | sort -u
}

sj_systemd_units_dir() { printf '%s\n' "${SJ_SYSTEMD_UNIT_DIR:-/etc/systemd/system}"; }
sj_systemctl()         { printf '%s\n' "${SJ_SYSTEMCTL:-systemctl}"; }

sj_live_systemd() { # prints: <unit-base>|<installed>|<active>|<cadence>|<svc yes/no>
    local dir sc u base active enabled total=0 cadence svc
    dir="$(sj_systemd_units_dir)"; sc="$(sj_systemctl)"
    [ -d "$dir" ] || { echo "sj_live_systemd: no unit directory ($dir)" >&2; return 1; }
    # ⛔ AN UNUSABLE SCHEDULER TOOL IS A MEASUREMENT GAP — probed BEFORE the units are read, not only
    # when nothing was found. Probing only the empty case put the guard exactly where it could not
    # matter: with timers present, a broken `systemctl` makes every `is-active` return empty, and the
    # gate published `INERT … it never fires` — a claim it had not measured — instead of exiting 3.
    if ! $sc --version >/dev/null 2>&1; then
        echo "sj_live_systemd: systemctl is unusable ($sc) — cannot enumerate timers" >&2
        return 1
    fi
    for u in "$dir"/*.timer; do
        [ -f "$u" ] || continue
        base="$(basename "$u" .timer)"
        active="$($sc is-active "$base.timer" 2>/dev/null || true)"; [ -n "$active" ] || active=unknown
        enabled="$($sc is-enabled "$base.timer" 2>/dev/null || true)"; [ -n "$enabled" ] || enabled=unknown
        cadence="$(sj_systemd_timer_cadence "$u")"
        # ⛔ A TIMER WITHOUT ITS SERVICE CAN NEVER RUN A JOB. `is-active` on the timer still says
        # active (the timer is fine; it is the unit it triggers that is missing), so this field is
        # what separates "scheduled" from "installed and inert".
        if [ -f "$dir/$base.service" ]; then svc=yes; else svc=no; fi
        total=$((total + 1))
        printf '%s|yes|%s|%s|%s\n' "$base" "$active:$enabled" "$cadence" "$svc"
    done
    printf '#meta|dir=%s|in_scope=%s\n' "$dir" "$total"
    return 0
}

# crontab is a third scheduler that exists on both platforms. Entries in the FLEET's namespace are in
# scope; a personal entry is counted and excluded (the criterion is stated, not assumed).
sj_live_cron() { # prints: <line> for in-scope entries, then #meta
    local out n=0 excluded=0 line rc=0
    # ⛔ rc=1 from `crontab -l` means NO CRONTAB FOR THIS USER — an empty surface, which is a real
    # measurement. Any OTHER failure means the surface could not be read, and "I read nothing" must
    # never be published as "nothing is scheduled" (the `|| true` here did exactly that).
    out="$(crontab -l 2>/dev/null)"; rc=$?
    case "$rc" in
        0) ;;
        1) out="" ;;
        *) echo "sj_live_cron: 'crontab -l' failed (rc=$rc) — the crontab population is UNREADABLE" >&2; return 1 ;;
    esac
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        case "$line" in \#*) continue ;; esac
        if grep -Eqi 'eldato|tortoise|disk-reaper|reap' <<<"$line"; then
            n=$((n + 1)); printf '%s\n' "$line"
        else
            excluded=$((excluded + 1))
        fi
    done <<EOF
$out
EOF
    printf '#meta|cron=%s|excluded=%s\n' "$n" "$excluded"
    return 0
}

# ── the unmanaged register ─────────────────────────────────────────────────────────────────
# `label|reason` (systemd: the unit base). A record here says "this job is real, this fleet knows it,
# and it is NOT managed by the declaration" — with a REASON, because "unmanaged" without one is how a
# job becomes invisible again. A register entry with no live job is reported as STALE (drift): the
# register must shrink as jobs are retired, not accumulate.
sj_unmanaged_reason() { # sj_unmanaged_reason <name> [register]
    local name="$1" reg="${2:-$SJ_UNMANAGED}" line n r
    [ -f "$reg" ] || return 1
    while IFS= read -r line; do
        case "$line" in ''|\#*) continue ;; esac
        n="${line%%|*}"
        # ⛔ THE SEPARATOR IS MANDATORY. `${line#*|}` leaves the WHOLE LINE in `r` when there is no
        # `|`, so a bare label (the exact thing a lane pastes out of `launchctl list`) read as
        # `n == r == <label>` — a present, non-empty "reason", and one bare line laundered any live
        # undeclared job. A line without the separator is a NO-REASON, never a reasoned entry.
        case "$line" in
            *'|'*) r="${line#*|}" ;;
            *)
                n="$(printf '%s' "$n" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
                [ "$n" = "$name" ] && return 2
                continue ;;
        esac
        n="$(printf '%s' "$n" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        [ "$n" = "$name" ] || continue
        r="$(printf '%s' "$r" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        [ -n "$r" ] || return 2
        printf '%s\n' "$r"; return 0
    done <"$reg"
    return 1
}

sj_unmanaged_names() {
    local reg="${1:-$SJ_UNMANAGED}" line
    [ -f "$reg" ] || return 0
    while IFS= read -r line; do
        case "$line" in ''|\#*) continue ;; esac
        printf '%s\n' "${line%%|*}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
    done <"$reg"
}
