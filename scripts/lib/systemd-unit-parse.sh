#!/usr/bin/env bash
# scripts/lib/systemd-unit-parse.sh — HOW systemd READS A UNIT, once, for every reader in this repo.
#
#   . "$INFRA_ROOT/scripts/lib/systemd-unit-parse.sh"
#   envmap="$(effective_env "$unit_text")"      # NAME=VALUE lines (last assignment wins)
#
# ══ THE FIELD OF VIEW, STATED ONCE (agent-infra#4034 round 3) ══════════════════════════════════════
# What a reader of a unit file must model is NOT the lines of that file. It is the environment (and the
# command list) the MANAGER COMPILES from them, and the manager's field of view differs from a line
# reader's in three ways. All three were MEASURED through `install-drainer-timer.sh --status`, each
# returning rc 0 ("provably agrees with the seam") over a box systemd dispatches at the OLD cap:
#
#   1. SECTION SCOPE. `systemd.exec(5)`, opening paragraph: "The execution specific configuration
#      options are configured in the `[Service]`, `[Socket]`, `[Mount]`, or `[Swap]` sections,
#      depending on the unit type." A directive written in any other section — or outside one — is
#      dropped with a log line, not an error. A physical-line reader therefore grades text the manager
#      DISCARDS, which is a false PASS in the pin/command direction and a false STALE in the other.
#      ⛔ This is the rule `scripts/cell-self-pin.sh:801-807` records as LOAD-BEARING: "SECTION-AWARE
#      PARSING IS LOAD-BEARING WHEREVER A RULE IS ABOUT A DIRECTIVE SYSTEMD ONLY HONOURS IN ONE
#      SECTION … A rule built on `directive` alone therefore reads a directive that does nothing as
#      satisfied, which is a false PASS." `unit_service_lines` is that rule, once, here.
#
#   2. THE MUTATING-DIRECTIVE FAMILY, BY NAME, IN ONE LIST. `systemd.exec(5)` §"Environment Variables
#      in Spawned Processes": the list is compiled from (…, `Environment=`, `EnvironmentFile=`, …) and
#      "If the same environment variable is set by multiple of these sources, the later source —
#      according to the order of the list above — wins", and "as the final step all variables listed
#      in `UnsetEnvironment=` are removed from the compiled environment variable list". So
#      `EnvironmentFile=` OVERRIDES `Environment=` and `PassEnvironment=` imports names from the
#      manager's own block, while `UnsetEnvironment=` can CLEAR the pin the `Environment=` rules just
#      read. `cell-self-pin.sh:807` refuses the same three names as ONE list
#      (`ENV_MUTATING_DIRECTIVES="EnvironmentFile UnsetEnvironment PassEnvironment"`), each "measured
#      at rc=0" before that ruling. Here: the two that are NOT computable from the unit text
#      (`EnvironmentFile=`, `PassEnvironment=`) are reported as `!unresolvable:` and the caller grades
#      UNKNOWN; the one that IS computable (`UnsetEnvironment=`, a name/assignment list applied last)
#      is APPLIED, because a pin that systemd really does remove is not an unknowable cap — it is a
#      cap that is absent, which the caller already grades against the unit's own `ExecStart=`.
#
#   3. THE EXPANSION CLASS, REFUSED AND NOT ENUMERATED. `systemd.syntax(7)`: "Lines ending in a
#      backslash are concatenated with the following line while reading and the backslash is replaced
#      by a space character", and Table 1 ("Supported escapes") makes `"\xxx"` "character number xx in
#      hexadecimal encoding" — so `Environment=HOME=/x \` + `LANE_TIMEOUT=7200` is ONE directive whose
#      SECOND assignment wins, and `Environment=\x4CA\x4EE_TIMEOUT=7200` assigns `LANE_TIMEOUT`. A
#      continuation can even swallow a SECTION HEADER (a `[Service]` preceded by a continued line is
#      no longer a header), so a backslash anywhere is a hazard for every reader here, not only for
#      the line it sits on.
#      ⛔ CLOSED BY REFUSAL, WHICH IS THE REPO'S RECORDED RULING — `scripts/cell-self-pin.sh:838-848`:
#      "Refusing a backslash in a directive closes BOTH [`Environment=\` continuations and `\x43`
#      escapes], plus any future spelling built on the same two constructs, instead of enumerating
#      them — and it costs nothing: the rendered unit is generated from a template of plain paths and
#      numbers, so it needs no continuation and no escape." Implementing the escape table instead
#      would be a SECOND grammar to keep in step with systemd's (which may add patterns: "other
#      patterns may be added in the future"), and a parser that is 99% right on escapes is exactly the
#      silent mis-parse this round is about. The same ruling refuses `%`-specifiers (`:855-863`); this
#      lib refuses them only on a `[Service]` line of a directive it PARSES, because a `%` in a
#      `Description=` or in a directive nothing here reads cannot move a value this lib reports (no
#      live false clean was measured for the pin — it is refused for the same one-line reason, at the
#      exact place it could matter).
#
# The cost of the refusal is a FALSE UNKNOWN (rc 5, "the cap cannot be determined", with the directive
# and the remedy named) on a unit that legitimately carries a backslash or a specifier in a directive
# this lib reads. That is the fail-closed direction, it is what `cell-self-pin.sh` already pays, and
# the remedy is the one the verb prints: re-run the installer to re-render the pin.
#
# ── WHY THIS IS A LIB AND NOT TWO COPIES ────────────────────────────────────────────────────────
# It was written for `install-disk-reaper-timer.sh`'s read-back, and agent-infra#4034's `--status`
# gained a SECOND reader of the same grammar (`install-drainer-timer.sh` reads the installed
# `Environment=LANE_TIMEOUT` pin). The second reader shipped as `grep '^Environment=LANE_TIMEOUT='`,
# which is a SPELLING match, not a grammar: a quoted pin, a multi-assignment line and a `.service.d/
# *.conf` drop-in all read as "the unit carries no pin" — and that verb reports rc 0 as "provably
# agrees with the seam". So the safe reader and the unsafe one disagreed about the same unit, and the
# file that defines the safe one is where a second implementation must NOT be born. One definition,
# both callers, and a unit a caller cannot parse is REPORTED (`!unparseable:`, `!unresolvable:`)
# rather than guessed at — because a caller that cannot tell "this unit sets no such variable" from
# "this unit sets it in a way nothing here can compile" is the fail-open direction.
#
# ── THE GRAMMAR (systemd.exec(5) `Environment=`; systemd.service(5) + systemd.unit(5) `ExecStart=`) ──
# * `Environment=` may appear many times; the assignments MERGE, and a LATER assignment of the SAME
#   name wins. A bare `Environment=` (no value) RESETS the list to empty.
# * One line may carry SEVERAL space-separated assignments: `Environment=HOME=/x LANE_TIMEOUT=7200`.
# * Values may be quoted with double or single quotes (to embed spaces); inside quotes a backslash
#   escapes the next character (`Environment="A=/tmp/q\"uo"`). Quotes are NOT part of the value.
# * Whitespace is allowed around the key and the `=` and before the value; lines may be indented:
#   `  Environment = LANE_TIMEOUT=7200` is legal and means the same thing.
# * An UNTERMINATED quote makes systemd return EINVAL, log, and ABANDON that line — the process
#   starts WITHOUT those variables. So an unparseable line is not an empty value; it is a line whose
#   content nobody can know, and `effective_env` prints `!unparseable:<rest of line>` for it so the
#   caller can REFUSE instead of certifying a value the unit will never have.
# * Drop-ins (`<unit>.d/*.conf`) are parsed AFTER the unit file, so THEY WIN. A caller reading only
#   the unit file can certify a value systemd has already overridden.
# * A REPEATED `[<section>]` header CONTINUES the section rather than restarting it (systemd merges the
#   blocks), so section tracking is a one-pass state machine, not "the last block wins".
# * A comment line is a line whose first non-space character is `#` or `;` — it is dropped before any
#   directive rule sees it, which is why a unit's PROSE can say `LANE_TIMEOUT` without reading as a pin.
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
normalize_unit_lines() {
    sed -E 's/^[[:space:]]+//; s/^([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*/\1=/'
}

# unit_service_lines <unit text> — the lines the manager HONOURS for execution directives: inside a
# `[Service]` section (`systemd.exec(5)`, quoted above), comments dropped, indentation and `Key = `
# normalised. A repeated `[Service]` header CONTINUES the section; every other header closes it.
#
# ⛔ THIS IS THE SECTION RULE, AND IT IS THE ONE THIS FILE GOT WRONG. Every reader below used to match
# physical lines with no section tracking, so `Environment=LANE_TIMEOUT=36000` under `[Install]` was
# graded as the effective pin — `--status` printed "pin: 36000 s installed · agrees" and exited **0**
# over a box systemd dispatches at 7200 (MEASURED, #4034 round 3, F2). `systemd.exec(5)` puts these
# directives in `[Service]` (or `[Socket]`/`[Mount]`/`[Swap]` for those unit types) and a directive
# elsewhere is a SILENT SKIP — so a reader that ignores sections reads a directive that does nothing as
# satisfied. `scripts/cell-self-pin.sh:801-807` records exactly this as the false PASS it fixed; this is
# the same fix, in the shared lib, for every caller at once instead of per-reader.
unit_service_lines() {
    printf '%s\n' "$1" | awk '
        { line = $0
          sub(/^[ \t]+/, "", line)
          if (line == "") next                       # a blank line carries no directive
          if (line ~ /^[#;]/) next                   # systemd.syntax(7): comments are `#` or `;`
          if (line ~ /^\[/) {                        # a section header: switch, and continue scanning
              sec = line
              sub(/^\[/, "", sec)
              sub(/\].*$/, "", sec)
              next
          }
          if (sec == "Service") print line
        }' | normalize_unit_lines
}

# unit_compile_hazards <unit text> — the constructs that make this parser's reading NOT the manager's
# reading, one `!unresolvable:<reason>` line each (empty output = the text is compilable here).
#
# ⛔ THE BACKSLASH TEST IS SECTION-BLIND AND WHOLE-TEXT ON PURPOSE. A continuation joins a line onto the
# PREVIOUS one, so a backslash can (a) hide the second assignment of a single `Environment=` line, and
# (b) DELETE A SECTION HEADER — `Description=x \` followed by `[Service]` makes `[Service]` part of the
# `Description=` value, so every directive under it is in the previous section and the manager ignores
# them. A test scoped to `Environment=` lines would miss (b) entirely. Refused as a CLASS, per
# `scripts/cell-self-pin.sh:838-848`; the escape table and the future spellings built on the same
# constructs cost nothing to cover this way, and an un-implemented expansion is never silently read.
unit_compile_hazards() {
    local lines bs pct
    lines="$(printf '%s\n' "$1" | normalize_unit_lines)"
    bs="$(printf '%s\n' "$lines" | awk '
        /^[#;]/ { next }
        index($0, "\\") > 0 { n++ }
        END { print n + 0 }')"
    # `%` is a SPECIFIER the manager expands at use time (systemd.unit(5)): `%h` is the manager user's
    # home, `%n` the unit name. Refused on a `[Service]` line of a directive THIS FILE PARSES, and not
    # body-wide: a `%` in `Description=` or in a directive no reader here consumes cannot move a value
    # reported below, and refusing it would be a false block on a healthy unit for no gain.
    pct="$(printf '%s\n' "$lines" | awk '
        /^\[/ { s = $0; sub(/^\[/, "", s); sub(/\].*$/, "", s); next }
        /^[#;]/ { next }
        s != "Service" { next }
        /^(Environment|EnvironmentFile|UnsetEnvironment|PassEnvironment|ExecStart)=/ && index($0, "%") > 0 { n++ }
        END { print n + 0 }')"
    if [ "${bs:-0}" -gt 0 ]; then
        printf '%s\n' '!unresolvable:a BACKSLASH in a directive — systemd.syntax(7) CONCATENATES a backslash-continued line ("the backslash is replaced by a space character") and EXPANDS C-style escapes (Table 1: "\xxx" is character xx in hex), so a continuation, an escape, or a section header swallowed by a continuation can hide or re-section an assignment; this reader does not implement expansions, so the value it compiles is not the value systemd runs'
    fi
    if [ "${pct:-0}" -gt 0 ]; then
        printf '%s\n' '!unresolvable:a %-SPECIFIER in a [Service] directive this reader parses — systemd EXPANDS specifiers at use time (%h is the manager user'"'"'s home, %n the unit name), so the literal text read here is not the value systemd runs'
    fi
    return 0
}

# effective_env <unit text> — the environment systemd will ACTUALLY hand the process, printed as
# `NAME=VALUE` lines (one per variable, in first-assignment order, last assignment wins), plus:
#   `!unparseable:<rest of the line>`  an `Environment=` line whose quoting systemd would reject
#   `!unresolvable:<reason>`           a construct that makes the compiled environment UNKNOWABLE here
#
# ⛔ THESE LINES ARE THE POINT, not a debug aid: a caller that ignores them cannot tell "this unit sets
# no such variable" from "this unit sets it on a line nothing here can read", which is the fail-open
# direction. Callers in this repo treat a present `!unparseable:` (when it names the variable they
# read) or ANY `!unresolvable:` as REFUSE/UNKNOWN.
# `env -i`-style edge cases (an empty value, `NAME=` with nothing after it) are preserved verbatim,
# because an empty value is not the value the caller rendered and must be its own decision.
effective_env() {
    local _haz
    _haz="$(unit_compile_hazards "$1")"
    if [ -n "$_haz" ]; then printf '%s\n' "$_haz"; fi
    unit_service_lines "$1" | awk '
        # splitq — the word splitting systemd applies to one directive value: double and single quotes
        # group, a
        # backslash escapes the next character INSIDE quotes, runs of whitespace separate. Fills
        # W[1..NW], returns the count, sets BAD on an unterminated quote.
        # Factored out so the four list directives below cannot drift apart in how they split.
        function splitq(rest,   i, ch, tok, inq, q, esc) {
            NW = 0; BAD = 0; tok = ""; inq = 0; q = ""; esc = 0
            for (i = 1; i <= length(rest); i++) {
                ch = substr(rest, i, 1)
                if (esc) { tok = tok ch; esc = 0; continue }
                if (inq) {
                    if (ch == "\\") { esc = 1; continue }
                    if (ch == q) { inq = 0; continue }
                    tok = tok ch; continue
                }
                if (ch == "\"" || ch == "\047") { inq = 1; q = ch; continue }
                if (ch == " " || ch == "\t") { if (tok != "") { W[++NW] = tok; tok = "" }; continue }
                tok = tok ch
            }
            if (inq || esc) { BAD = 1; return NW }
            if (tok != "") W[++NW] = tok
            return NW
        }
        function emit(tok,   eq, name) {
            eq = index(tok, "=")
            if (eq <= 1) return                     # not a NAME=VALUE assignment: systemd ignores it
            name = substr(tok, 1, eq - 1)
            vals[name] = substr(tok, eq + 1)
            if (!(name in seen)) { seen[name] = 1; order[++n] = name }
        }
        /^Environment=/ {
            rest = substr($0, 13)
            if (rest == "") { n = 0; split("", order); split("", vals); split("", seen); next }
            nw = splitq(rest)
            # AN UNTERMINATED QUOTE IS AN UNPARSEABLE LINE, NOT A VALUE. systemd returns EINVAL, logs,
            # and ABANDONS the whole line — the service starts WITHOUT those variables. Emitting
            # `HOME=<rest of line>` would certify a HOME the unit never gets (a fail-open the pre-fix
            # line match did not have, because it compared the value with the quote still attached).
            if (BAD) { bad[++b] = rest; next }
            for (i = 1; i <= nw; i++) emit(W[i])
            next
        }
        # ⛔ `EnvironmentFile=` IS THE LATER SOURCE AND WINS (`systemd.exec(5)`, quoted in the header), so
        # a unit carrying one has a compiled environment that CANNOT be known from its text — the file may
        # not even exist here (`-` prefix), and it may set any name. Reported, never guessed: MEASURED,
        # `Environment=LANE_TIMEOUT=36000` + a drop-in `EnvironmentFile=` whose file says 7200 read
        # "pin: 36000 s installed · agrees", rc 0, over a box dispatching at 7200 (F1).
        # A bare `EnvironmentFile=` RESETS the list (systemd.exec(5)), so it legitimately cancels an
        # earlier one — the count is of the CURRENT list, not of lines seen.
        /^EnvironmentFile=/ {
            rest = substr($0, 17)
            nw = splitq(rest)
            if (BAD) { bad[++b] = rest; next }
            if (nw == 0) envf = 0
            else envf += nw
            next
        }
        # `PassEnvironment=` imports names from the block the MANAGER holds — a value this box may or
        # may not carry, i.e. equally unknowable. A bare assignment resets the list, as above.
        /^PassEnvironment=/ {
            rest = substr($0, 17)
            nw = splitq(rest)
            if (BAD) { bad[++b] = rest; next }
            if (nw == 0) passn = 0
            else passn += nw
            next
        }
        # `UnsetEnvironment=` IS computable and is APPLIED, last, per systemd.exec(5): "as the final step
        # all variables listed in `UnsetEnvironment=` are removed from the compiled environment variable
        # list". A bare name removes every assignment of that name; a `NAME=VALUE` token removes only
        # that precise assignment (both are the documented rules, not a simplification). So a unit
        # that pins `LANE_TIMEOUT` and then UNSETS it has NO pin — which the caller already grades
        # against the `ExecStart=` script the unit runs, i.e. the fail-safe path, not a false CLEAN.
        /^UnsetEnvironment=/ {
            rest = substr($0, 18)
            nw = splitq(rest)
            if (BAD) { bad[++b] = rest; next }
            if (nw == 0) { nu = 0; split("", U) }
            else for (i = 1; i <= nw; i++) U[++nu] = W[i]
            next
        }
        END {
            if (envf > 0)
                print "!unresolvable:EnvironmentFile= names " envf " file(s) in [Service] — systemd READS it, and it is the LATER source, so it OVERRIDES every Environment= assignment (systemd.exec(5)); its contents are not in this unit text, so the compiled environment cannot be known here"
            if (passn > 0)
                print "!unresolvable:PassEnvironment= imports " passn " name(s) from the MANAGER'"'"'s own environment (systemd.exec(5)) — a value this unit text does not carry, so the compiled environment cannot be known here"
            for (i = 1; i <= b; i++) print "!unparseable:" bad[i]
            # UnsetEnvironment= is applied LAST, after every source — so it can clear a pin this map holds.
            for (i = 1; i <= nu; i++) {
                tok = U[i]; eq = index(tok, "=")
                if (eq > 0) { name = substr(tok, 1, eq - 1)
                              if ((name in vals) && vals[name] == substr(tok, eq + 1)) { delete seen[name]; delete vals[name] } }
                else        { delete seen[tok]; delete vals[tok] }
            }
            for (i = 1; i <= n; i++) if (order[i] in seen) print order[i] "=" vals[order[i]]
        }'
}

# effective_execstarts <unit text> — the `ExecStart=` command lines systemd will ACTUALLY run, one per
# line, applying systemd's own list semantics:
#
# * `ExecStart=` is a `[Service]` directive (`systemd.exec(5)`/`systemd.service(5)`), so an `ExecStart=`
#   under `[Unit]`/`[Install]` runs NOTHING — the section rule above is load-bearing here too.
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
#
# ⛔ A BACKSLASH OR SPECIFIER HAZARD IS NOT REPORTED HERE: this function's output is a list of command
# LINES, and a sentinel in that stream would be indistinguishable from a command. Callers that need the
# verdict call `unit_compile_hazards` (or `effective_env`, which folds it in) on the SAME text — the
# drainer's `--status` does, before it grades anything.
effective_execstarts() {
    unit_service_lines "$1" | awk '
        /^ExecStart=$/ { n = 0; next }                  # a bare assignment RESETS the list
        /^ExecStart=/  { L[++n] = substr($0, 11); next } # 10 chars + 1: everything after `ExecStart=`
        END            { for (i = 1; i <= n; i++) print L[i] }'
}
