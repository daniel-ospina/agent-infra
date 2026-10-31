#!/bin/bash
# The REMEDY (#2248, landed form): the here-doc lives in a FUNCTION body, so the substitution that
# captures its output carries no here-doc at all. Parses identically on bash 3.2 and 5.
_probe() { python3 - "$1" <<'PY'
import sys
print(0 if len(sys.argv) > 1 else 1)
PY
}
out="$(_probe "$1")"
echo "$out"
