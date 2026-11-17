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
# ── THE GRAMMAR (systemd.exec(5), `Environment=`) ───────────────────────────────────────────────
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
# ⛔ NOTHING HERE EXECUTES ANYTHING. Both functions take unit TEXT on stdin/argv and print text, so a
# caller can feed them the installed file plus its drop-ins without running a unit, a systemctl or a
# `git` — this file is safe to source inside a test's subshell.

# normalize_unit_lines — systemd's own reading of `Key = value`: strip indentation, strip whitespace
# around the key and around the `=`, strip whitespace before the value. Everything else is preserved
# verbatim, including an empty value (`NAME=`) and a comment line (which simply never matches a key).
normalize_unit_lines() {
    sed -E 's/^[[:space:]]+//; s/^([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*/\1=/'
}

# effective_env <unit text> — the Environment= map systemd will ACTUALLY hand the process, printed as
# `NAME=VALUE` lines (one per variable, in first-assignment order, last assignment wins), plus one
# `!unparseable:<rest of the line>` line per `Environment=` line whose quoting systemd would reject.
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
