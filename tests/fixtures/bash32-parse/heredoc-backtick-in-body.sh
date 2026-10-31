#!/bin/bash
# #2930 as it was measured on tests/actionlint/run.sh — a SINGLE backtick in a here-doc body inside
# `$( )` puts bash 3.2 into backtick-command-substitution mode; the file then ends inside it
# ("unexpected EOF while looking for matching `` ` ``"). One backtick, not a pair: a balanced pair
# parses clean on 3.2, so a two-backtick fixture would measure nothing.
out="$(python3 - "$ROOT" <<'PY'
# the `script: key, as a comment
print(1)
PY
)"
echo "$out"
