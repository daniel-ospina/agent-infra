#!/usr/bin/env bash
# media-holders.test.sh — the honesty contract of `media-holders.sh` (#2249, half B).
#
# WHAT THIS SUITE IS FOR
# ----------------------
# `media-holders.sh` answers "who holds the camera / the microphone", and the only
# thing that makes it safe is that it NEVER guesses. Its two failure modes are
# both silent and both worse than "I don't know":
#
#   FAIL-OPEN — reporting `FREE` from a read that did not happen (another user's
#     /proc/<pid>/fd denied, an empty census, an absent log). On the box that
#     hosted agent-infra#2249 this is the answer that keeps a human debugging a
#     camera they cannot use.
#   SILENCE — printing nothing, or a bare "unknown", leaving the operator with no
#     next action. #2249 is explicit: "the latter is an acceptable answer, silence
#     is not".
#
# So every arm below drives the REAL script through its `MH_*` seams and asserts
# the exact verdict word AND that the two "we could not tell" verdicts carry a
# non-empty reason.
#
# Portability: bash 3.2 (no associative arrays, no mapfile). Runs on a Linux cell
# and on a macOS box; the macOS arms use stubs on PATH so they execute anywhere.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/media-holders.sh"
[ -f "$SCRIPT" ] || { echo "FATAL: $SCRIPT not found" >&2; exit 1; }

pass=0
fail=0
ok()   { pass=$((pass + 1)); printf '✅ %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf '❌ %s%s\n' "$1" "${2:+ — $2}"; }
check() { if [ "$2" -eq 0 ]; then ok "$1"; else bad "$1" "${3:-}"; fi; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/media-holders.XXXXXX")" || exit 1
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT INT TERM

# ── fixtures ────────────────────────────────────────────────────────────────
# A Linux /proc: one holder of the camera, one of a capture PCM, one process with
# NO readable fd directory (the EPERM case), one innocent bystander.
PROC="$TMP/proc"
mkdir -p "$PROC/100/fd" "$PROC/200/fd" "$PROC/300" "$PROC/400/fd" "$TMP/dev"
: > "$TMP/dev/video0"
: > "$TMP/dev/video1"
printf 'electron\n' > "$PROC/100/comm"
printf 'Meet Helper\n' > "$PROC/200/comm"
printf 'firefox\n' > "$PROC/300/comm"
printf 'sshd\n' > "$PROC/400/comm"
ln -s "$TMP/dev/video0" "$PROC/100/fd/7"
ln -s "/dev/snd/pcmC0D0c" "$PROC/200/fd/3"
ln -s /dev/null "$PROC/400/fd/0"
ln -s /dev/null "$PROC/400/fd/1"

ASOUND="$TMP/asound-pcm"
printf '00-00: ALC295 Analog : capture 1\n00-01: ALC295 Alt Analog : playback 1\n' > "$ASOUND"

run_linux() { # run_linux <proc> <v4l-glob> <asound> [extra args…]
  local p="$1" g="$2" a="$3"; shift 3
  MH_PLATFORM=Linux MH_PROC="$p" MH_V4L_GLOB="$g" MH_ASOUND_PCM="$a" \
    bash "$SCRIPT" "$@" 2>&1
}

# ── L1: a proven holder is named, with pid and device ───────────────────────
OUT="$(run_linux "$PROC" "$TMP/dev/video*" "$ASOUND")"
RC=$?
grep -q 'camera: HELD-BY(pid=100 comm=electron device='"$TMP"'/dev/video0)' <<<"$OUT"
check "L1 camera HELD-BY names the holder's pid, comm and device" $? "$OUT"

# ── L2: the unreadable pid makes the answer UNVERIFIABLE, never FREE ────────
# 300 has no `fd/`, i.e. exactly the EPERM shape, and NO process holds video1.
rm -f "$PROC/100/fd/7"
OUT="$(run_linux "$PROC" "$TMP/dev/video*" "$ASOUND")"
RC=$?
grep -q 'camera: UNVERIFIABLE(partial:' <<<"$OUT"
check "L2 an unreadable fd dir ⇒ UNVERIFIABLE(partial: …), not FREE" $? "$OUT"
check "L2a that UNVERIFIABLE exits 2 (CANNOT VERIFY)" "$([ "$RC" -eq 2 ] && echo 0 || echo 1)" "rc=$RC"

# ── L3: a COMPLETE census with no holder IS free — the one place absence proves
rm -rf "$PROC/300"
OUT="$(run_linux "$PROC" "$TMP/dev/video*" "$ASOUND")"
grep -qx 'camera: FREE' <<<"$OUT"
check "L3 a complete census with no holder ⇒ FREE" $? "$OUT"

# ── L4: no device at all is ABSENT, and says what it looked for ────────────
OUT="$(run_linux "$PROC" "$TMP/nonexistent-video*" "$ASOUND")"
grep -q 'camera: ABSENT(no video device' <<<"$OUT"
check "L4 no video device ⇒ ABSENT(<what was looked for>)" $? "$OUT"

# ── L5: an EMPTY census is not "no holders" ────────────────────────────────
mkdir -p "$TMP/empty-proc"
OUT="$(MH_PLATFORM=Linux MH_PROC="$TMP/empty-proc" MH_V4L_GLOB="$TMP/dev/video*" \
       MH_ASOUND_PCM="$ASOUND" bash "$SCRIPT" 2>&1)"
grep -q 'camera: UNVERIFIABLE(partial:' <<<"$OUT"
check "L5 an EMPTY process population ⇒ UNVERIFIABLE (a failed read, not a free device)" $? "$OUT"

# ── L6: the microphone names its holder ───────────────────────────────────
OUT="$(run_linux "$PROC" "$TMP/nonexistent-video*" "$ASOUND")"
grep -q 'microphone: HELD-BY(pid=200 comm=Meet Helper device=/dev/snd/pcmC0D0c)' <<<"$OUT"
check "L6 microphone HELD-BY names the capture-PCM holder" $? "$OUT"

# ── L7: no capture PCM ⇒ ABSENT (hardware/pcm read, not a guess) ──────────
printf '00-01: ALC295 : playback 1\n' > "$TMP/asound-playback-only"
OUT="$(run_linux "$PROC" "$TMP/nonexistent-video*" "$TMP/asound-playback-only")"
grep -q 'microphone: ABSENT(' <<<"$OUT"
check "L7 no capturing PCM ⇒ microphone ABSENT" $? "$OUT"

# ── L8: a capture PCM exists but nobody holds it ⇒ UNVERIFIABLE, NEVER FREE ─
# This is the ALSA honesty rule: "nobody opened one" and "we cannot see who
# opened one" are the same bytes, so FREE here would be a fabricated answer.
mkdir -p "$TMP/proc-idle/900/fd"
printf 'bash\n' > "$TMP/proc-idle/900/comm"
ln -s /dev/null "$TMP/proc-idle/900/fd/0"
OUT="$(MH_PLATFORM=Linux MH_PROC="$TMP/proc-idle" MH_V4L_GLOB="$TMP/nonexistent-video*" \
       MH_ASOUND_PCM="$ASOUND" bash "$SCRIPT" 2>&1)"
grep -q 'microphone: UNVERIFIABLE(.*ALSA has no holder table' <<<"$OUT"
check "L8 idle capture PCM ⇒ microphone UNVERIFIABLE (ALSA has no holder table)" $? "$OUT"

# ── L9: a missing ALSA tree ⇒ UNVERIFIABLE, not ABSENT ────────────────────
OUT="$(run_linux "$PROC" "$TMP/nonexistent-video*" "$TMP/no-such-asound")"
grep -q 'microphone: UNVERIFIABLE(no readable' <<<"$OUT"
check "L9 no readable ALSA state ⇒ UNVERIFIABLE (a failed read is not absence)" $? "$OUT"

# ── JSON shape: the same verdicts, machine-readable ───────────────────────
OUT="$(run_linux "$PROC" "$TMP/dev/video*" "$ASOUND" --json)"
grep -q '^{"platform":"Linux","devices":\[' <<<"$OUT"
check "J1 --json emits one object with a devices array" $? "$OUT"
grep -q '"verdict":"HELD-BY"' <<<"$OUT"
check "J2 --json carries the same HELD-BY verdict" $? "$OUT"
# A tab/newline in a detail would break the document; the fixture "Meet Helper"
# carries a space, which must survive unescaped-but-quoted.
printf '%s' "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["devices"], d' 2>/dev/null
check "J3 --json is VALID JSON a parser accepts" $? "$OUT"

# ── macOS arms (stubs on PATH — they run on any host) ─────────────────────
FAKEBIN="$TMP/bin"
mkdir -p "$FAKEBIN"
# system_profiler: a camera is present for SPCameraDataType.
cat > "$FAKEBIN/system_profiler" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  SPCameraDataType) printf 'Camera:\n\n      Model ID: UVC Camera VendorID_1452\n'; exit 0 ;;
  SPAudioDataType)  printf 'Audio:\n\n      Input Source: Internal Microphone\n'; exit 0 ;;
esac
exit 0
STUB
# The privileged app list — the documented fallback. `Electron` is the #2249 holder.
cat > "$FAKEBIN/osascript" <<'STUB'
#!/usr/bin/env bash
printf 'Finder, cmux, Electron, Google Chrome\n'
exit 0
STUB
# coremedia produces NOTHING (the measured behaviour that made the incident hard).
cat > "$FAKEBIN/log" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$FAKEBIN/system_profiler" "$FAKEBIN/osascript" "$FAKEBIN/log"

run_mac() { PATH="$FAKEBIN:$PATH" MH_PLATFORM=Darwin bash "$SCRIPT" "$@" 2>&1; }

OUT="$(run_mac)"
RC=$?
grep -q 'camera: UNVERIFIABLE(' <<<"$OUT"
check "M1 macOS camera is UNVERIFIABLE — no per-client owner is published" $? "$OUT"
grep -q 'Electron' <<<"$OUT"
check "M2 …and the refusal NAMES the privileged app list (so the human can act)" $? "$OUT"
check "M2a macOS UNVERIFIABLE exits 2" "$([ "$RC" -eq 2 ] && echo 0 || echo 1)" "rc=$RC"
grep -q 'microphone: UNVERIFIABLE(' <<<"$OUT"
check "M3 macOS microphone is UNVERIFIABLE, with a reason (#2249: silence is not OK)" $? "$OUT"

# M4 — a coremedia capture EVENT is reported as events, never invented as a pid.
cat > "$FAKEBIN/log" <<'STUB'
#!/usr/bin/env bash
printf '2026-10-21 09:12:00 coremedia: AVCaptureDevice startCapture requested\n'
STUB
chmod +x "$FAKEBIN/log"
OUT="$(run_mac)"
grep -q 'capture-event line(s)' <<<"$OUT"
check "M4 a coremedia capture event is reported as an EVENT, never as an owner pid" $? "$OUT"
CAM_LINE="$(printf '%s\n' "$OUT" | grep 'camera:' || true)"
case "$CAM_LINE" in
  *pid=*) bad "M4a …and no invented pid appears in the camera verdict" "$CAM_LINE" ;;
  *)      ok  "M4a …and no invented pid appears in the camera verdict" ;;
esac

# M5 — TCC denying Automation is named, not swallowed.
# The coremedia log goes back to SILENT first, so this arm reaches the app-list
# read it is about (a capture-event line would short-circuit it by design — M4).
cat > "$FAKEBIN/log" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$FAKEBIN/log"
cat > "$FAKEBIN/osascript" <<'STUB'
#!/usr/bin/env bash
printf 'execution error: Not authorized to send Apple events to System Events. (-1743)\n' >&2
exit 1
STUB
chmod +x "$FAKEBIN/osascript"
OUT="$(run_mac)"
grep -q 'osascript rc=1' <<<"$OUT"
check "M5 a TCC/Automation denial is NAMED in the reason, not swallowed" $? "$OUT"

# M6 — no camera hardware at all is ABSENT (a definitive read).
cat > "$FAKEBIN/system_profiler" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  SPCameraDataType) printf 'Camera:\n\nNo camera found.\n'; exit 0 ;;
  SPAudioDataType)  printf 'Audio:\n\n      Input Source: Internal Microphone\n'; exit 0 ;;
esac
exit 0
STUB
chmod +x "$FAKEBIN/system_profiler"
OUT="$(run_mac)"
grep -q 'camera: ABSENT(' <<<"$OUT"
check "M6 no camera hardware ⇒ ABSENT (never UNVERIFIABLE-for-everything)" $? "$OUT"

# M7 — --apps prints the list on its own (the fallback verb a human types).
# Restore a WORKING osascript: M5 left the TCC-denied stub on PATH.
cat > "$FAKEBIN/osascript" <<'STUB'
#!/usr/bin/env bash
printf 'Finder, cmux, Electron, Google Chrome\n'
exit 0
STUB
chmod +x "$FAKEBIN/osascript"
cat > "$FAKEBIN/system_profiler" <<'STUB'
#!/usr/bin/env bash
printf '      Model ID: UVC Camera VendorID_1452\n'
STUB
chmod +x "$FAKEBIN/system_profiler"
OUT="$(run_mac --apps)"
grep -qx 'Electron' <<<"$OUT"
check "M7 --apps lists the privileged app list, one name per line" $? "$OUT"
# M8 — on a Linux box --apps ABSTAINS honestly instead of printing an empty list.
OUT="$(MH_PLATFORM=Linux bash "$SCRIPT" --apps 2>&1)"
RC=$?
grep -q 'apps: UNVERIFIABLE(' <<<"$OUT"
check "M8 --apps on Linux says it cannot, rather than printing an empty list" $? "$OUT"
check "M8a …and exits 2" "$([ "$RC" -eq 2 ] && echo 0 || echo 1)" "rc=$RC"

# ── --ancestry: acquisition, not a verdict ────────────────────────────────
# The chain is what names the LANE root: in #2249 the app was killed twice and
# came back, and only the lane's own process tree held the devices.
OUT="$(MH_PLATFORM=Linux MH_PROC="$PROC" bash "$SCRIPT" --ancestry 100 2>&1)"
grep -q '^pid=100 ppid=' <<<"$OUT"
check "A1 --ancestry prints the chain from the pid the operator named" $? "$OUT"
OUT="$(MH_PLATFORM=Linux MH_PROC="$PROC" bash "$SCRIPT" --ancestry not-a-pid 2>&1)"
RC=$?
check "A2 --ancestry refuses a non-numeric pid with rc=3 (usage)" "$([ "$RC" -eq 3 ] && echo 0 || echo 1)" "rc=$RC"

# ── the silence arm: EVERY verdict line carries a verdict word ────────────
OUT="$(run_linux "$PROC" "$TMP/dev/video*" "$ASOUND")"
DEV_LINES="$(printf '%s\n' "$OUT" | grep -c -e '^camera: ' -e '^microphone: ' || true)"
check "S1 both devices are always answered (2 verdict lines, never silence)" \
  "$([ "${DEV_LINES:-0}" -ge 2 ] && echo 0 || echo 1)" "lines=$DEV_LINES"
grep -q -e '^camera: \(HELD-BY\|FREE\|ABSENT\|UNVERIFIABLE\)' -e '^microphone: \(HELD-BY\|FREE\|ABSENT\|UNVERIFIABLE\)' <<<"$OUT"
check "S2 every verdict is one of the four declared words" $? "$OUT"

# ── non-vacuity floor ────────────────────────────────────────────────────
check "N1 the suite ran a meaningful number of assertions" "$([ "$pass" -ge 20 ] && echo 0 || echo 1)" "pass=$pass"

printf '\n%s media-holders suite: %s passed, %s failed\n' \
  "$([ "$fail" -eq 0 ] && echo '✅' || echo '❌')" "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
