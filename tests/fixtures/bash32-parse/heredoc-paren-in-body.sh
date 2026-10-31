#!/bin/bash
# #2930, the parenthesis half — a bare `(` in a here-doc body inside `$( )` desynchronises the same
# scanner: 3.2 counts it as an opening parenthesis for the substitution and never closes it.
out="$(python3 - "$SUT" <<'PYMOD'
# a comment with a ( paren
print(1)
PYMOD
)"
echo "$out"
