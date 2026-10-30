#!/usr/bin/env bash
# lane-env.test.sh — a lane started OUTSIDE the controller must still get its credentials
# (agent-infra#3060).
#
# THE MEASURED FAILURE THIS PINS. A hand-dispatched lane on a cell passed every gate and died in seven
# seconds with `No API key found for deepseek`, because the controller's supervisor sources keys.env and a
# lane started any other way inherits nothing.
#
# ⛔ THE PROPERTY IS "A SEPARATE CHILD PROCESS SEES IT". Every value arm starts a grandchild
# (`bash -c 'printf %s "${VAR-<unset>}"'`) AFTER the snippet has run, in a fresh process. A parent-only
# assertion passes straight through the real bug — verifier round 1 proved that the hard way: an earlier
# draft read the value in the SOURCING shell, so deleting `set -a` left every value arm green.
#
# ⛔ THE SNIPPET IS SOURCED AT TOP LEVEL, in a throwaway shell per arm — that is its real call shape
# (`LANE_ENV_LOG=… LANE_ENV_LABEL=… . lane-env.sh`). It is not a function, deliberately: three verifier
# rounds showed every attempt to make a FUNCTION survive `. file` (declare scope, then a quote-blind sed,
# then an `export -p` replay that spliced `export` into a multi-line VALUE) introduced a new way to
# corrupt or lose a credential.
#
# ⛔ THE CANARY NAMES ARE DELIBERATELY NOT CREDENTIAL-SHAPED: this harness redacts values bound to names
# that look like secrets (`[REDACTED-SECRET:env:…]`), and a test that used `DEEPSEEK_API_KEY` would then
# assert on the redactor instead of on the snippet.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
LIB="$HERE/lane-env.sh"
[ -r "$LIB" ] || { echo "FATAL: lane-env.sh not found beside this test ($LIB)" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/lane-env-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/home"
pass=0 fail=0
ok()  { printf '  ✅ %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  ❌ %s\n' "$1"; fail=$((fail+1)); }
eq()  { [ "$1" = "$2" ] && ok "$3" || bad "$3 (got: '$1', want: '$2')"; }
has() { case "$1" in *"$2"*) ok "$3" ;; *) bad "$3 (missing: $2)" ;; esac; }
hasnt() { case "$1" in *"$2"*) bad "$3 (unexpected: $2)" ;; *) ok "$3" ;; esac; }

# probe <env-file> [PREFACE] — runs the snippet at top level in a clean shell, then asks a SEPARATE CHILD
# what it inherited. Prints labelled lines: KEY_A/KEY_B/KEY_C, CHILD_A/PARENT_A (allexport), LOG_<line>.
probe() {
  local file="$1" preface="${2:-}"
  env -i PATH=/usr/bin:/bin HOME="$T/home" ENV_FILE="$file" \
    bash -c 'pre="$2"; [ -n "$pre" ] && eval "$pre"
             LANE_ENV_LOG="$3" LANE_ENV_LABEL=test-lane . "$1"
             printf "KEY_A=%s\n" "$(bash -c "printf %s \"\${LANE_CANARY_A-<unset>}\"")"
             printf "KEY_B=%s\n" "$(bash -c "printf %s \"\${LANE_CANARY_B-<unset>}\"")"
             printf "KEY_C=%s\n" "$(bash -c "printf %s \"\${LANE_CANARY_C-<unset>}\"")"
             printf "CHILD_A=%s\n" "$(bash -c "case \"\$-\" in *a*) printf on;; *) printf off;; esac")"
             case "$-" in *a*) a=on ;; *) a=off ;; esac
             printf "PARENT_A=%s\n" "$a"
             while IFS= read -r l; do printf "LOG_%s\n" "$l"; done < "$3" 2>/dev/null' \
    _ "$LIB" "$preface" "$T/probe.log"
}
logprobe() { # <env-file> [PREFACE] — the snippet's own log output only
  local file="$1" preface="${2:-}"
  env -i PATH=/usr/bin:/bin HOME="$T/home" ENV_FILE="$file" \
    bash -c 'pre="$2"; [ -n "$pre" ] && eval "$pre"; LANE_ENV_LABEL=test-lane . "$1"' _ "$LIB" "$preface" 2>&1
}
grab() { printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -1; }

echo "── A1: a plain KEY=value reaches a SEPARATE child (the production bug, exactly) ──"
printf 'LANE_CANARY_A=canary-plain\n' > "$T/plain.env"
out="$(probe "$T/plain.env")"
eq "$(grab "$out" KEY_A)" "canary-plain" "(A1) a separate child process sees a plain assignment"
has "$out" "sourced $T/plain.env" "(A1) the log names the file it sourced"
has "$out" "1 assignment(s)" "(A1) …and counts it"

echo "── A2: \`declare -x NAME=…\` works — the shape \`export -p > keys.env\` writes ──"
printf 'declare -x LANE_CANARY_A=canary-declare\n' > "$T/declare.env"
eq "$(grab "$(probe "$T/declare.env")" KEY_A)" "canary-declare" "(A2) a declare -x line reaches the child"
printf 'export LANE_CANARY_A=canary-exported\n' > "$T/exported.env"
eq "$(grab "$(probe "$T/exported.env")" KEY_A)" "canary-exported" "(A2b) an already-exported line works"

echo "── A3: a QUOTED value containing '; NAME=' is copied verbatim ──"
# The value is data. Nothing in this snippet re-serialises the file, so a `;`-containing value is safe by
# construction — this arm exists because two earlier designs corrupted exactly this.
printf 'LANE_CANARY_A="host=x; LANE_CANARY_C=1"\n' > "$T/quoted.env"
out="$(probe "$T/quoted.env")"
eq "$(grab "$out" KEY_A)" "host=x; LANE_CANARY_C=1" "(A3) a quoted value with '; NAME=' survives intact"
eq "$(grab "$out" KEY_C)" "<unset>" "(A3) …and the text inside the quotes did not become an assignment"

echo "── A4: a MULTI-LINE value survives byte-for-byte (the replay defect) ──"
# ⛔ Verifier round 3's defect: replaying `export -p` spliced `export ` into a value whose continuation
# line happened to start with `declare -x NAME=`. Sourcing the file directly cannot do that.
printf 'LANE_CANARY_A="a\ndeclare -x LANE_CANARY_C=evil\nb"\n' > "$T/multiline.env"
env -i PATH=/usr/bin:/bin HOME="$T/home" ENV_FILE="$T/multiline.env" bash -c \
  'LANE_ENV_LABEL=t . "$1" >/dev/null 2>&1; bash -c "printf %s \"\$LANE_CANARY_A\""' _ "$LIB" > "$T/ml.out" 2>/dev/null
if [ "$(cat "$T/ml.out")" = "$(printf 'a\ndeclare -x LANE_CANARY_C=evil\nb')" ]; then
  ok "(A4) a multi-line value is preserved exactly, including a line that looks like an assignment"
else
  bad "(A4) the value was altered: $(od -c "$T/ml.out" | head -3 | tr '\n' ' ')"
fi
eq "$(env -i PATH=/usr/bin:/bin HOME="$T/home" ENV_FILE="$T/multiline.env" bash -c 'LANE_ENV_LABEL=t . "$1" >/dev/null 2>&1; bash -c "printf %s \"\${LANE_CANARY_C-<unset>}\""' _ "$LIB")" \
  "<unset>" "(A4b) …and the fake assignment inside it never became a variable"

echo "── A5: co-assigned names on ONE line are all exported (\`A=1; B=2\`) ──"
printf 'LANE_CANARY_A=c5a; LANE_CANARY_B=c5b\n' > "$T/coassign.env"
out="$(probe "$T/coassign.env")"
eq "$(grab "$out" KEY_A)" "c5a" "(A5) the first name on the line is exported"
eq "$(grab "$out" KEY_B)" "c5b" "(A5) …and so is the second"

echo "── A6: PATH from the file reaches the child (parity with the controller) ──"
printf 'PATH=/canary/bin:/usr/bin:/bin\n' > "$T/path.env"
childpath="$(env -i PATH=/usr/bin:/bin HOME="$T/home" ENV_FILE="$T/path.env" bash -c \
  'LANE_ENV_LABEL=t . "$1" >/dev/null 2>&1; bash -c "printf %s \"\$PATH\""' _ "$LIB")"
eq "$(printf '%s' "$childpath" | cut -d: -f1)" "/canary/bin" "(A6) the file's PATH wins, as it does for the controller"

echo "── A7: no file is not a failure, and it names the exact path ──"
out="$(env -i PATH=/usr/bin:/bin HOME="$T/nofile" bash -c 'LANE_ENV_LABEL=t . "$1" 2>&1; echo "rc=$?"' _ "$LIB")"
has "$out" "rc=0" "(A7) a missing file does not fail the lane"
has "$out" "no readable" "(A7) the line says it was not readable"
has "$out" "$T/nofile/keys.env" "(A7) …and names the path it looked at"

echo "── A8: an unparseable file is reported as SOURCED WITH ERRORS, never as success ──"
# ⛔ Verifier round 3's defect: the earlier guard tested "did any file name reach the environment", which
# matched an INHERITED `PATH=` and reported success for a file that applied nothing. `.` returns non-zero
# on a syntax error — that is the honest signal, and it is used here.
printf 'LANE_CANARY_A="unclosed\nLANE_CANARY_B=b8\n' > "$T/broken.env"
out="$(logprobe "$T/broken.env")"
# ⛔ HERE-STRINGS, NOT PIPES INTO A QUIET GREP (#841/#864). Under `pipefail`, `grep -q` exiting at its
# first match leaves the `printf` writer to take SIGPIPE (141), and the pipeline status becomes non-zero
# — so these assertions take the `else` branch and fail a verdict that IS in the output.
if grep -q 'SOURCED WITH ERRORS' <<<"$out"; then ok "(A8) an unparseable file reports SOURCED WITH ERRORS"
elif grep -q 'env: sourced' <<<"$out"; then bad "(A8) an unparseable file was reported as a clean 'sourced': $out"
else bad "(A8) no verdict at all for an unparseable file: $out"; fi
# a file whose only assignment shares a name with the INHERITED environment must still be judged on its own
printf 'PATH="/unclosed\n' > "$T/broken-path.env"
out="$(logprobe "$T/broken-path.env")"
if grep -q 'SOURCED WITH ERRORS' <<<"$out"; then ok "(A8b) …including when the only name it sets is one the environment already exports"
else bad "(A8b) an unparseable PATH-only file reported success: $out"; fi

echo "── A9: the log never carries a VALUE ──"
out="$(logprobe "$T/plain.env")"
hasnt "$out" "canary-plain" "(A9) no value appears in the sourcing line"
has "$out" "$T/plain.env" "(A9) …while the path does"

echo "── A10: \$ENV_FILE wins over \$HOME/keys.env (the controller's precedence) ──"
mkdir -p "$T/home2"; printf 'LANE_CANARY_B=from-home\n' > "$T/home2/keys.env"
printf 'LANE_CANARY_A=from-envfile\n' > "$T/explicit.env"
out="$(env -i PATH=/usr/bin:/bin HOME="$T/home2" ENV_FILE="$T/explicit.env" bash -c \
  'LANE_ENV_LABEL=t . "$1" >/dev/null 2>&1; bash -c "printf \"%s/%s\" \"\${LANE_CANARY_A-<unset>}\" \"\${LANE_CANARY_B-<unset>}\""' _ "$LIB")"
eq "$out" "from-envfile/<unset>" "(A10) ENV_FILE is used and \$HOME/keys.env is not"

echo "── A11: allexport is left EXACTLY as the caller had it ──"
eq "$(grab "$(probe "$T/plain.env")" PARENT_A)" "off" "(A11) a caller with allexport off still has it off"
eq "$(grab "$(probe "$T/plain.env" 'set -a')" PARENT_A)" "on" "(A11) a caller with allexport ON keeps it on"
eq "$(grab "$(probe "$T/plain.env")" CHILD_A)" "off" "(A11) …and the child does not inherit a stray allexport"

echo "── A12: the lane log is where a reader looks ──"
: > "$T/lane.log"
env -i PATH=/usr/bin:/bin HOME="$T/home" ENV_FILE="$T/plain.env" bash -c \
  'LANE_ENV_LOG="$2" LANE_ENV_LABEL="lane 10077" . "$1" >/dev/null 2>&1' _ "$LIB" "$T/lane.log"
has "$(cat "$T/lane.log" 2>/dev/null)" "env: sourced" "(A12) the line lands in the lane log"
has "$(cat "$T/lane.log" 2>/dev/null)" "lane 10077" "(A12) …carrying the lane label"

echo "── A13: no temp file is created at all (nothing can leak a credential) ──"
before="$(ls "${TMPDIR:-/tmp}" 2>/dev/null | grep -c '^lane-env' || true)"
probe "$T/plain.env" >/dev/null 2>&1
after="$(ls "${TMPDIR:-/tmp}" 2>/dev/null | grep -c '^lane-env' || true)"
eq "$after" "$before" "(A13) the snippet writes no credential-bearing temp file"

echo "── A14: lane.sh actually SOURCES the snippet (a snippet nothing sources fixes nothing) ──"
LANE="$HERE/lane.sh"
if [ -r "$LANE" ]; then
  calls="$(grep -cE '^[[:space:]]*[A-Z_]+=.*\. "\$SELF/lane-env\.sh"|^[[:space:]]*\. "\$SELF/lane-env\.sh"' "$LANE" || true)"
  if [ "${calls:-0}" -ge 1 ] 2>/dev/null; then ok "(A14) lane.sh sources the snippet on a live (non-comment) line"
  else bad "(A14) lane.sh does not source lane-env.sh on a live line"; fi
  has "$(cat "$LANE")" 'lane-env.sh missing' "(A14) …and refuses loudly when the snippet is not beside it"
else
  bad "(A14) lane.sh not found beside this test"
fi

echo "───────────────────────────────────────────────────────────────────"
if [ "$fail" -eq 0 ]; then echo "✅ lane-env suite: all $pass assertions passed"; else echo "❌ lane-env suite: $fail failure(s), $pass passed"; fi
exit $([ "$fail" -eq 0 ] && echo 0 || echo 1)
