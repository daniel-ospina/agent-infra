#!/usr/bin/env bash
# scripts/lib/systemd-unit-parse.sh — HOW systemd READS A UNIT, once, for every reader in this repo.
#
#   . "$INFRA_ROOT/scripts/lib/systemd-unit-parse.sh"
#   envmap="$(effective_env "$unit_text")"      # NAME=VALUE lines (last assignment wins)
#
# ── WHY THIS IS A LIB AND NOT TWO COPIES ────────────────────────────────────────────────────────
# It was written for `install-disk-reaper-timer.sh`'s read-back, and agent-infra#4034's `--status`
# gained a SECOND reader of the same grammar (`install-drainer-timer.sh` reads the installed
# `Environment=LANE_TIMEOUT` pin). The second reader shipped as `grep '^Environment=LANE_TIMEOUT='`,
# which is a SPELLING match, not a grammar: a quoted pin, a multi-assignment line and a `.service.d/
# *.conf` drop-in all read as "the unit carries no pin" — and that verb reports rc 0 as "provably
# agrees with the seam". So the safe reader and the unsafe one disagreed about the same unit, and the
# file that defines the safe one is where a second implementation must NOT be born. One definition,
# both callers, and a unit a caller cannot parse is REPORTED (`!unparseable:`) rather than guessed at.
#
# ── THE GRAMMAR (systemd.exec(5) `Environment=`; systemd.service(5) + systemd.unit(5) `ExecStart=`) ──
# * A DIRECTIVE IS HONOURED IN ONE SECTION ONLY. systemd.exec(5): "The execution specific configuration
#   options are configured in the `[Service]`, `[Socket]`, `[Mount]`, or `[Swap]` sections, depending
#   on the unit type." For the `.service` files every caller here reads, that is `[Service]` — so an
#   `Environment=` left under `[Unit]` or `[Install]` is a SILENT SKIP to systemd, not a pin, and
#   grading it is the false PASS `scripts/cell-self-pin.sh:801-807` records as load-bearing
#   ("SECTION-AWARE PARSING … a rule built on `directive` alone therefore reads a directive that does
#   nothing as satisfied, which is a false PASS"). Both readers below are section-scoped, and a
#   REPEATED `[Service]` header CONTINUES the section (it does not restart it), which is what systemd
#   does.
# * `Environment=` may appear many times; the assignments MERGE, and a LATER assignment of the SAME
#   name wins. A bare `Environment=` (no value) RESETS the list to empty.
# * One line may carry SEVERAL space-separated assignments: `Environment=HOME=/x LANE_TIMEOUT=7200`.
# * Values may be quoted with double or single quotes (to embed spaces); inside quotes a backslash
#   escapes the next character (`Environment="A=/tmp/q\"uo"`). Quotes are NOT part of the value.
# * Whitespace is allowed around the key and the `=` and before the value; lines may be indented:
#   `  Environment = LANE_TIMEOUT=7200` is legal and means the same thing.
# * LINES ENDING IN A BACKSLASH ARE CONCATENATED (systemd.syntax(7): "Lines ending in a backslash are
#   concatenated with the following line while reading and the backslash is replaced by a space
#   character"), and "When a comment line or lines follow a line ending with a backslash, the comment
#   block is ignored". `normalize_unit_lines` performs BOTH — see the measured defeat at its definition.
# * C-STYLE ESCAPES AND `%`-SPECIFIERS ARE NOT RECONSTRUCTED HERE, and pretending otherwise is how a
#   name hides. systemd.syntax(7) Table 1: `\x43` is `C`, `\s` a space, `\n` a newline; and
#   `Environment=` values and the `ExecStart=` command line both take `%` specifiers. So
#   `Environment=\x4CA\x4EE_TIMEOUT=7200` is a `LANE_TIMEOUT=7200` pin to systemd and an unknown name
#   to a line reader. The two escapes this file DOES read the way systemd does — `\"`, `\'` and `\\`
#   inside quotes — are kept, and every OTHER `\` and every `%` is reported by
#   `env_compile_hazards` so a caller refuses instead of certifying (`scripts/cell-self-pin.sh:838-848`
#   closes the same boundary by refusing, "plus any future spelling built on the same two constructs,
#   instead of enumerating them").
# * An UNTERMINATED quote makes systemd return EINVAL, log, and ABANDON that line — the process
#   starts WITHOUT those variables. So an unparseable line is not an empty value; it is a line whose
#   content nobody can know, and `effective_env` prints `!unparseable:<rest of line>` for it so the
#   caller can REFUSE instead of certifying a value the unit will never have.
# * Drop-ins (`<unit>.d/*.conf`) are parsed AFTER the unit file, so THEY WIN. A caller reading only
#   the unit file can certify a value systemd has already overridden.
#
# ⛔ MEASURED (the read-back's own review, and again in #4034's re-review): a drop-in with
# `Environment=PATH=/usr/bin:/bin HOME=/tmp/tmp.deadbeef/bg/home`, and another with
# `Environment="HOME=/tmp/tmp.deadbeef/bg/home"`, both left the plain line match intact and the
# installer printed "verify: … read back" over the dead tree; and the drainer's `--status` exited 0
# (clean) over a unit whose pin was quoted. A gate anchored on ONE LINE SHAPE is defeatable by any
# legal spelling, and a gate that reads one line and reports "verified" is the false PASS this file
# exists to remove. Normalising the TEXT once, rather than teaching every parser the grammar, keeps
# ONE definition of "what systemd will read".
#
# ⛔ NOTHING HERE EXECUTES ANYTHING. Every function takes unit TEXT on stdin/argv and prints text, so a
# caller can feed them the installed file plus its drop-ins without running a unit, a systemctl or a
# `git` — this file is safe to source inside a test's subshell.

# normalize_unit_lines — systemd's own reading of `Key = value`: strip indentation, strip whitespace
# around the key and around the `=`, strip whitespace before the value. Everything else is preserved
# verbatim, including an empty value (`NAME=`) and a comment line (which simply never matches a key).
#
# ⛔ IT ALSO JOINS CONTINUATIONS, because a physical-line reader cannot see the directive systemd reads.
# systemd.syntax(7): a line ending in a backslash is "concatenated with the following line … and the
# backslash is replaced by a space character", and a comment block after such a line is ignored. Being
# blind to that is a MEASURED false clean (round-2 re-review, F3):
#     Environment=HOME=/x \
#     LANE_TIMEOUT=7200
# is ONE directive whose SECOND assignment wins, while a physical-line reader saw `HOME=/x` alone and
# certified "the unit carries no pin" at rc 0 over a box at 7200.
#
# ⛔ AND IT STOPS AT A FILE BOUNDARY (`[]`, see `unit_text_from_files`). systemd reads the unit and each
# drop-in as a SEPARATE file, so a trailing `\` at one file's end joins with NOTHING — never with the
# next file's first line. Joining across the boundary would both corrupt the boundary and DESTROY the
# hazard (the renamed `\` is what tells `env_compile_hazards` this text cannot be certified), so the
# pending line keeps its backslash and the boundary is re-emitted after it: an EOF-dangling continuation
# is unknowable, and unknowable must stay visible.
normalize_unit_lines() {
    awk '
        { sub(/\r$/, "") }
        {
            # a continuation is IN FLIGHT: a comment line is part of the ignored comment block, anything
            # else is the line systemd is still reading (systemd.syntax(7), quoted at the header).
            if (held) {
                if ($0 ~ /^[ \t]*[#;]/) next
                if ($0 ~ /^[ \t]*\[\]/) { held = 0; print pending "\\"; print "[]"; next }
                $0 = pending " " $0
                held = 0
            }
            if ($0 ~ /\\$/) { pending = substr($0, 1, length($0) - 1); held = 1; next }
            print
        }
        END { if (held) print pending "\\" }
    ' | sed -E 's/^[[:space:]]+//; s/^([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*/\1=/'
}

# unit_text_from_files <path>... — the text of every file that EXISTS, in the order given, each one
# preceded by a FILE BOUNDARY (`[]`).
#
# ⛔ A FILE BOUNDARY IS NOT COSMETIC, AND ITS ABSENCE WAS A MEASURED FALSE CLEAN. systemd reads the unit
# and every drop-in as SEPARATE files, so an assignment that appears before that file's first
# `[Section]` header belongs to NO section and is DROPPED — systemd's own diagnostic (v257,
# `src/shared/conf-parser.c:253`): "Assignment outside of section. Ignoring." A bare `cat` of
# unit-then-drop-ins instead attaches such a line to whatever section the PREVIOUS file happened to end
# in, which certifies a value systemd never compiles: MEASURED at `c4edfd1fd`, a base
# `[Service] Environment=LANE_TIMEOUT=7200` plus a HEADERLESS drop-in
# `Environment=LANE_TIMEOUT=36000` read "pin: 36000 s installed · agrees" at **rc 0**, while systemd
# ignores the drop-in and the box runs the base's 7200. The mirror matters too: a headerless drop-in
# cannot RESCUE a stale base either.
#
# `[]` is the truthful encoding rather than a trick: it is the header of a section that does not exist,
# so no reader honours anything under it (exactly as systemd honours nothing before the first real
# header), it can never collide with a real section name, and `normalize_unit_lines` treats it as a
# continuation barrier so a trailing `\` at one file's EOF cannot swallow the next file's first line.
unit_text_from_files() {
    local f
    for f in "$@"; do
        [ -f "$f" ] || continue
        printf '[]\n'
        cat "$f"
        printf '\n'
    done
}

# unit_text_cat_boundaries — the same boundaries for `systemctl cat` output, which concatenates a unit
# and its drop-ins with a `# <path>` comment line before each file (so the caller cannot pass file paths
# at all: the manager, not the checkout, is the only truthful source for a system unit).
# ⛔ A unit COMMENT that begins `# /` would over-reset here; the consequence is fail-closed in both
# callers (the readers stop seeing directives until the next real header, so a caller reports UNKNOWN or
# refuses rather than certifying), which is why the filter is keyed on the separator shape and nothing
# more ambitious.
unit_text_cat_boundaries() {
    awk '/^# \//{print "[]"} {print}'
}

# unit_text_effective <systemctl-cmd> <target> <unit-dir> <unit-file> — the text systemd will LOAD for
# one unit, from the source that is truthful FOR THAT TARGET. One definition, both callers: the disk
# reaper's read-back and the drainer's `--status` asked this question in two places, and only one of
# them could answer it.
#
# ⛔ WHY THE FILES ARE NOT ENOUGH (this was a MEASURED false clean in the drainer, round-2 re-review P3,
# left open by the round-3 lane and closed here). `$UNIT_DIR/<unit>.d/*.conf` is ONE directory in a
# PRIORITY-ORDERED list. systemd also merges `/run/systemd/system/<unit>.d` and
# `/usr/lib/systemd/system/<unit>.d` for a system unit (and `~/.config/systemd/user/.config`… plus the
# higher-priority user dirs for a user unit) — systemd.unit(5): "drop-in files … are read from
# `<unit>.d/` directories in all the directories searched for unit files", with earlier entries in the
# search path winning. A drop-in in any of those is invisible to a reader that only opens `$UNIT_DIR`,
# and `--status` then certifies a cap systemd does not use: the same false PASS as the drop-in it
# already learned to read, one directory over. Only the manager knows the merged answer, which is why
# this function asks it there.
#
#   override — the documented test seam (a scratch dir no systemd knows about): the file plus its own
#              `<unit>.d/*.conf`, the way systemd merges them. rc 1 when the unit file is absent.
#   user     — `systemctl --user cat` first (it merges the whole user search path); the installed file
#              plus its `<unit>.d/*.conf` only when the manager gives no answer, which for a USER unit
#              is still a truthful source — `$UNIT_DIR` is the user config dir it just failed to list.
#   *        — `systemctl cat` is REQUIRED. An unreadable answer there is indistinguishable from "no
#              drop-in", so it is rc 1 (the caller reports UNKNOWN / refuses) and never a clean grade.
unit_text_effective() {
    local sc="$1" target="$2" udir="$3" ufile="$4" out=""
    case "$target" in
        override)
            [ -f "$udir/$ufile" ] || return 1
            unit_text_from_files "$udir/$ufile" "$udir/$ufile.d"/*.conf ;;
        user)
            out="$($sc cat "$ufile" 2>/dev/null)"
            if [ -n "$out" ]; then
                printf '%s\n' "$out" | unit_text_cat_boundaries
            else
                [ -f "$udir/$ufile" ] || return 1
                unit_text_from_files "$udir/$ufile" "$udir/$ufile.d"/*.conf
            fi ;;
        *)
            out="$($sc cat "$ufile" 2>/dev/null)"
            [ -n "$out" ] || return 1
            printf '%s\n' "$out" | unit_text_cat_boundaries ;;
    esac
    return 0
}

# effective_env <unit text> — the Environment= map systemd will ACTUALLY hand the process, printed as
# `NAME=VALUE` lines (one per variable, in first-assignment order, last assignment wins), plus one
# `!unparseable:<rest of the line>` line per `Environment=` line whose quoting systemd would reject.
#
# ⛔ `[Service]` ONLY (see the header): `Environment=` in `[Unit]`/`[Install]` is a silent skip to
# systemd, so reading it certifies a variable the process never gets — MEASURED in the round-2 re-review
# (F2): `Environment=LANE_TIMEOUT=36000` under `[Install]` over a 7200-default script read rc 0, and its
# mirror (a stale `Environment=` left in `[Unit]`) read a false STALE (rc 3).
#
# ⛔ WHAT THIS FUNCTION CANNOT SEE, `env_compile_hazards` REPORTS: `EnvironmentFile=`,
# `UnsetEnvironment=`, `PassEnvironment=`, C-style escapes and `%`-specifiers.
#
# ⛔ THE `!unparseable:` LINES ARE THE POINT, not a debug aid: a caller that ignores them cannot tell
# "this unit sets no such variable" from "this unit sets it on a line nothing can read", which is the
# fail-open direction. Callers in this repo treat a present `!unparseable:` as REFUSE/UNKNOWN.
# `env -i`-style edge cases (an empty value, `NAME=` with nothing after it) are preserved verbatim,
# because an empty value is not the value the caller rendered and must be its own decision.
effective_env() {
    printf '%s\n' "$1" | normalize_unit_lines | awk '
        function emit(tok,   eq, name) {
            eq = index(tok, "=")
            if (eq <= 1) return                     # not a NAME=VALUE assignment: systemd ignores it
            name = substr(tok, 1, eq - 1)
            vals[name] = substr(tok, eq + 1)
            if (!(name in seen)) { seen[name] = 1; order[++n] = name }
        }
        /^\[/ { s = substr($0, 2); sub(/\].*$/, "", s); sec = s; next }
        sec != "Service" { next }                       # the section systemd honours these in
        /^Environment=/ {
            rest = substr($0, 13)
            if (rest == "") { n = 0; split("", order); split("", vals); split("", seen); next }
            tok = ""; inq = 0; q = ""
            for (i = 1; i <= length(rest); i++) {
                ch = substr(rest, i, 1)
                # A BACKSLASH ESCAPES THE NEXT CHARACTER inside a quoted value: systemd accepts
                # `Environment="HOME=/tmp/q\\"uo"`, so treating the escaped quote as the terminator made
                # this parser refuse a line systemd is happy with (an over-block with a false reason).
                if (esc) { tok = tok ch; esc = 0; continue }
                if (inq) {
                    if (ch == "\\") { esc = 1; continue }
                    if (ch == q) { inq = 0; continue }
                    tok = tok ch; continue
                }
                if (ch == "\"" || ch == "\047") { inq = 1; q = ch; continue }
                if (ch == " " || ch == "\t") { if (tok != "") { emit(tok); tok = "" }; continue }
                tok = tok ch
            }
            # NOTE (apostrophes are ILLEGAL here: this is a single-quoted awk program):
            # AN UNTERMINATED QUOTE IS AN UNPARSEABLE LINE, NOT A VALUE. systemd returns EINVAL,
            # logs, and ABANDONS the whole line — the service starts WITHOUT those variables.
            # Emitting `HOME=<rest of line>` would certify a HOME the unit never gets (a fail-open
            # the pre-fix line match did not have, because it compared the value with the quote
            # still attached). systemd rule applied: discard the line, and REPORT it so the caller
            # can refuse instead of guessing.
            if (inq || esc) { bad[++b] = rest; next }
            if (tok != "") emit(tok)
            next
        }
        END { for (i = 1; i <= b; i++) print "!unparseable:" bad[i]
              for (i = 1; i <= n; i++) print order[i] "=" vals[order[i]] }'
}

# effective_execstarts <unit text> — the `ExecStart=` command lines systemd will ACTUALLY run, one per
# line, applying systemd's own list semantics:
#
# * `ExecStart=` may appear once (and, for `Type=oneshot`, several times — the commands then run in the
#   order they appear). systemd.service(5): "Unless Type= is oneshot, exactly one command must be given."
# * A bare `ExecStart=` RESETS the list — systemd.service(5): "If the empty string is assigned to this
#   option, the list of commands to start is reset, prior assignments of this option will have no
#   effect." That is how a drop-in MASK replaces a unit's command.
# * Drop-ins are parsed AFTER the unit file (systemd.unit(5): "All files with the suffix `.conf` from
#   this directory will be merged in the alphanumeric order and parsed after the main unit file itself
#   has been parsed"), so a caller that feeds the unit first and its drop-ins after it gets systemd's
#   order — and a drop-in's `ExecStart=` therefore applies LAST.
#
# ⛔ WHY THIS LIVES HERE AND NOT IN ITS ONE CALLER (this file's own rule, one definition, both callers).
# It was written inside `install-disk-reaper-timer.sh`'s read-back, and `install-drainer-timer.sh`'s
# no-pin arm then read `ExecStart=` with a `sed` spelling match on the BASE FILE ALONE — so a drop-in
# override was invisible and the arm graded a script systemd would not run. MEASURED (round-2
# re-review, P2): base `ExecStart=/bin/bash <fresh>`, drop-in `ExecStart=` + `ExecStart=/bin/bash
# <stale>` read rc 0 "agrees with what this checkout would render" over a unit that runs the STALE
# script. A second reader that can disagree with the first about the same unit is the #1872 shape.
# ⛔ `[Service]` ONLY, for the same measured reason as `effective_env`: an `ExecStart=` under another
# header is one systemd would not run, and grading it certifies the wrong command.
#
# ⛔ A `\` (other than the `\"`, `\'`, `\\` the splitter understands) or a `%` in the command line can
# move the SCRIPT systemd resolves — `%h` is the manager user's home, `\x2F` is `/` — so a caller that
# needs the script's identity must consult `env_compile_hazards` first. This function still returns the
# literal text; it does not silently rewrite it.
effective_execstarts() {
    printf '%s\n' "$1" | normalize_unit_lines | awk '
        /^\[/ { s = substr($0, 2); sub(/\].*$/, "", s); sec = s; next }
        sec != "Service" { next }
        /^ExecStart=$/ { n = 0; next }                  # a bare assignment RESETS the list
        /^ExecStart=/  { L[++n] = substr($0, 11); next } # 10 chars + 1: everything after `ExecStart=`
        END            { for (i = 1; i <= n; i++) print L[i] }'
}

# env_compile_hazards <unit text> — one line per construct that makes the COMPILED environment
# impossible for a line reader to certify. EMPTY OUTPUT MEANS "the map above is the manager's"; a caller
# that certifies a value while this prints anything is the false PASS these findings are about.
#
# ⛔ WHY THIS EXISTS AS ITS OWN FUNCTION AND NOT AS MORE PARSING. Each construct below changes the
# environment BEHIND `Environment=` and cannot be reconstructed from the unit text alone:
#
#   1. `EnvironmentFile=`     — systemd READS the named file, and its variables OVERRIDE `Environment=`
#                              (systemd.exec(5): "If the same environment variable is set by multiple of
#                              these sources, the later source … wins", with `EnvironmentFile=` listed
#                              after `Environment=`). MEASURED (round-2 F1): a drop-in carrying
#                              `EnvironmentFile=<LANE_TIMEOUT=7200>` over a `LANE_TIMEOUT=36000` pin read
#                              "36000 s installed" at rc 0 over a box systemd dispatches at 7200.
#   2. `UnsetEnvironment=`    — "applied as the final step", so it can CLEAR a pin `effective_env` returns.
#   3. `PassEnvironment=`     — imports names from the MANAGER's environment.
#   4. a C-style escape (`\x4C`, `\s`) or a `%`-specifier — they rewrite NAMES as well as values, so the
#                              variable the manager sets is not the one this text spells. MEASURED
#                              (round-2 F3b): `Environment=\x4CA\x4EE_TIMEOUT=7200` is a 7200 pin to
#                              systemd ("\x4C" is "L") and an unknown name here — a false clean at rc 0.
#
# These are the SAME family `scripts/cell-self-pin.sh` refuses by name (`ENV_MUTATING_DIRECTIVES`) and
# closes at the raw-text boundary ("refusing a backslash in a directive closes BOTH, plus any future
# spelling built on the same two constructs, instead of enumerating them"). This file is where that rule
# has to land now that it is the ONE definition of "what systemd reads" — one list, both callers.
#
# ⛔ THE TWO ESCAPES A SPLITTER CAN HONESTLY HANDLE ARE NOT HAZARDS: `\"`, `\'` and `\\` mean exactly
# what this repo's tokenisers make of them, so a quoted value containing an escaped quote stays
# certifiable (the disk reaper has an arm for that line, and refusing it would be a false block with an
# untrue reason). Every other backslash is uncertain — including one at end-of-line that the
# continuation join could not consume.
#
# ⛔ SECTION-SCOPED, like the readers: `EnvironmentFile=` under `[Install]` is a directive systemd
# IGNORES, and refusing on it would be the same section-blindness in the other direction.
ENV_MUTATING_DIRECTIVES="EnvironmentFile UnsetEnvironment PassEnvironment"
env_compile_hazards() {
    printf '%s\n' "$1" | normalize_unit_lines | awk -v mut="$ENV_MUTATING_DIRECTIVES" '
        # 1 = this line contains an escape or a specifier that can rewrite a variable NAME or the
        # command systemd resolves. `\\"`, `\\047` and `\\\\` are the ones the splitter reads the way
        # systemd does; anything else (\x43, \s, \n, a lone trailing `\`) is opaque.
        function opaque_escape(s,   i, n, nx) {
            n = length(s)
            for (i = 1; i <= n; i++) {
                if (substr(s, i, 1) != "\\") continue
                if (i == n) return 1
                nx = substr(s, i + 1, 1)
                if (nx != "\"" && nx != "\047" && nx != "\\") return 1
                i++
            }
            return 0
        }
        BEGIN { k = split(mut, M, " "); for (i = 1; i <= k; i++) mutator[M[i]] = 1 }
        /^\[/ { s = substr($0, 2); sub(/\].*$/, "", s); sec = s; next }
        sec != "Service" { next }
        {
            name = $0; sub(/=.*$/, "", name)
            if (name in mutator)            { print $0; next }
            if (name == "Environment" || name == "ExecStart") {
                if (index($0, "%") > 0)     { print $0; next }
                if (opaque_escape($0))      { print $0 }
            }
        }'
}
