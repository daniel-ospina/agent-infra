#!/bin/bash
# #2930 — an APOSTROPHE inside a here-doc body that sits inside a `$( )`. bash 3.2's substitution
# scanner does not know about here-documents, so it enters single-quote mode here and never leaves:
# the failure is reported FAR below this line (that is why the reported line number is useless), and
# this body's own line parses fine on its own. Fails `bash -n` on 3.2.57; parses on bash 5.
out="$(python3 - "$SUT" <<'PYMOD'
# candidate 3 is this script's own checkout
print(1)
PYMOD
)"
echo "$out"
