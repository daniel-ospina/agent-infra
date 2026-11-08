#!/usr/bin/env bash
# media-holders.sh — "who is holding the camera / the microphone on THIS host", or
# a plain statement that we cannot say (#2249, half B).
#
# ── WHY THIS EXISTS ──────────────────────────────────────────────────────────
# 2026-10-21, ~5 minutes before a customer call: Google Meet refused the camera
# ("something else is using it") and the microphone did not work. The holder was a
# pi lane running `npm exec electron .`. Diagnosing it took six rounds, because:
#
#   1. macOS has NO supported CLI verb for "who holds the camera". `log show
#      --predicate 'subsystem == "com.apple.coremedia"'` over 3- and 10-minute
#      windows returned NOTHING at default and at `--info --debug` levels; the TCC
#      database needs Full Disk Access; `ffmpeg`/`imagesnap` are not installed, so
#      there is no way to attempt an exclusive open and read the contention error.
#   2. Device ownership is not a fleet signal. `tools/fleet/liveness.py`,
#      `fleet_state.py` and the claim registry describe LANES. A lane can be
#      perfectly healthy, reporting progress, while its child owns the camera.
#   3. Killing the APP is a trap: the live lane relaunched it within seconds. The
#      fix that actually worked was killing the LANE TREE — which is why
#      `--ancestry` is here (see the runbook, `docs/ops/media-devices.md`).
#
# ── THE HONESTY CONTRACT ────────────────────────────────────────────────────
# Silence is NOT an acceptable answer; "I cannot tell you" IS. So every device
# answer is one of exactly four words, and the two that mean "unknown" say WHY:
#
#   HELD-BY(pid=<p> comm=<c> device=<d>)   a reader PROVED an open handle/claim
#   FREE                                   a reader enumerated the whole holder
#                                          population and found no holder
#   ABSENT(<evidence>)                     the hardware is not present
#   UNVERIFIABLE(<why>)                    the read did not happen. NEVER "free"
#
# ⛔ `FREE` is the only answer that may rest on absence, and it may rest ONLY on a
# COMPLETE population read. A /proc scan that could not read another user's fd
# directory yields `UNVERIFIABLE(partial: N pid(s) unreadable)`, not `FREE` — the
# same abstention rule the fleet's liveness classifier carries (#1178 C3). An
# unreadable read reported as "free" is the fail-open this script exists to
# prevent, in the exact domain where being wrong means the owner cannot take a
# call.
#
# ── WHAT IT READS, PER PLATFORM ─────────────────────────────────────────────
# Linux  — camera: `/dev/video*` presence, holders from `/proc/*/fd` targets (one
#          `ls -l` census, not one fork per fd). A pid whose fd directory is
#          unreadable makes the answer UNVERIFIABLE rather than FREE.
#          microphone: `/proc/asound/pcm` capture subdevices are the presence read;
#          an open capture stream shows as a `/dev/snd/pcmC*D*c` holder. There is
#          no `FREE` claim for the microphone on Linux: ALSA has no holder table,
#          and a PCM that nobody opened and a PCM we cannot see are the same
#          bytes. `FREE` there would be a guess.
# macOS  — camera presence: `system_profiler SPCameraDataType` (slow; skipped by
#          `--skip-presence`). Holders: NONE of the reads is authoritative, so the
#          script ATTEMPTS the two that exist and reports what each returned:
#          `log show --predicate 'subsystem == "com.apple.coremedia"'` and the
#          privileged app list via `osascript`. Both empty ⇒ UNVERIFIABLE, with
#          the app list printed so a human can act in one glance.
#
# ── USAGE ──────────────────────────────────────────────────────────────────
#   bash media-holders.sh                    # camera + microphone, plain lines
#   bash media-holders.sh --json             # one JSON object
#   bash media-holders.sh --apps             # the privileged app list (the fallback)
#   bash media-holders.sh --ancestry <pid>   # the process chain to the LANE root
#   bash media-holders.sh --skip-presence    # don't pay system_profiler
#
# Exit: 0 = every device answered definitively; 2 = at least one UNVERIFIABLE
# (CANNOT VERIFY — never treat 2 as "free"); 3 = usage error.
#
# ⛔ `--ancestry` ACQUIRES evidence, it does not decide a state. It walks ppid from
# the pid you name and prints the chain; naming the LANE root is the operator's
# read (and the doc says which ancestor that is), because a second liveness
# verdict is exactly the defect `docs/ops/fleet-liveness.md` forbids.
#
# Portability: Linux cells and macOS boxes. bash 3.2 (no associative arrays, no
# `${var,,}`, no mapfile). Test seams are the `MH_*` variables, used only by
# `media-holders.test.sh`.
set -u

PROG="$(basename "$0")"
JSON=0
APPS_ONLY=0
ANCESTRY=""
SKIP_PRESENCE=0

MH_PLATFORM="${MH_PLATFORM:-$(uname -s 2>/dev/null || echo unknown)}"
MH_PROC="${MH_PROC:-/proc}"
MH_V4L_GLOB="${MH_V4L_GLOB:-/dev/video*}"
MH_ASOUND_PCM="${MH_ASOUND_PCM:-/proc/asound/pcm}"

die3() { printf '%s\n' "$PROG: $*" >&2; exit 3; }
say() { printf '%s\n' "$*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --json) JSON=1; shift ;;
    --apps) APPS_ONLY=1; shift ;;
    --ancestry) [ $# -ge 2 ] || die3 "--ancestry needs a pid"; ANCESTRY="$2"; shift 2 ;;
    --skip-presence) SKIP_PRESENCE=1; shift ;;
    -h|--help) awk 'NR>1 && /^set -u$/{exit} NR>1{sub(/^# ?/,""); print}' "$0"; exit 0 ;;
    *) die3 "unknown argument: $1 (try --help)" ;;
  esac
done

# ── JSON helpers (bash 3.2: no printf %q for JSON, so escape by hand) ────────
json_str() {
  # Escape \ and ", and every control character a JSON document cannot carry raw.
  #
  # ⛔ LF AND CR ARE ESCAPED, NOT ASSUMED AWAY (review F3). The first version
  # stripped the control range and escaped TAB only — so a literal LF or CR passed
  # through UNESCAPED and `--json` emitted an invalid document. Not hypothetical:
  # `--ancestry`'s whole purpose is the LANE ROOT, whose argv is
  # `pi -p "<multi-line brief>"`, and a NUL→space `tr` leaves the LFs in place.
  # awk (not sed) because sed is line-oriented and cannot see a LF inside its
  # pattern space at all; awk's `gsub` on a `-v` value can.
  awk -v s="$1" 'BEGIN {
    gsub(/\\/, "\\\\", s)
    gsub(/"/, "\\\"", s)
    gsub(/\t/, "\\t", s)
    gsub(/\r/, "\\r", s)
    gsub(/\n/, "\\n", s)
    gsub(/[\001-\010\013\014\016-\037]/, "", s)
    printf "\"%s\"", s
  }'
}
JSON_DEVICES=""
SAW_UNVERIFIABLE=0

emit_device() {
  # emit_device <device> <verdict> [detail]   — detail is OPTIONAL, and a missing
  # one is not an error (FREE carries none). `set -u` makes a bare "$3" fatal, so
  # every read of it is defaulted.
  local device="$1" verdict="$2" detail="${3:-}"
  [ "$verdict" = "UNVERIFIABLE" ] && SAW_UNVERIFIABLE=1
  if [ "$JSON" -eq 1 ]; then
    [ -n "$JSON_DEVICES" ] && JSON_DEVICES="$JSON_DEVICES,"
    JSON_DEVICES="$JSON_DEVICES{\"device\":$(json_str "$device"),\"verdict\":$(json_str "$verdict"),\"detail\":$(json_str "$detail")}"
  else
    if [ -n "$detail" ]; then say "$device: $verdict($detail)"; else say "$device: $verdict"; fi
  fi
}

# ── the privileged app list (macOS) — THE documented fallback ───────────────
read_apps() {
  # Sets APPS (newline separated), APPS_ERR (empty on success).
  APPS=""
  APPS_ERR=""
  if [ "$MH_PLATFORM" != "Darwin" ]; then
    APPS_ERR="no privileged app list on $MH_PLATFORM (foreground apps are a macOS concept)"
    return 1
  fi
  local out rc
  out="$(osascript -e 'tell application "System Events" to get name of every process whose background only is false' 2>&1)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    # The usual failure is TCC: Automation permission was never granted, or a
    # headless lane has no one to answer the prompt.
    APPS_ERR="osascript rc=$rc: $(printf '%s' "$out" | tr '\n' ' ')"
    return 1
  fi
  # `osascript` returns a comma-separated list.
  APPS="$(printf '%s' "$out" | tr ',' '\n' | sed -e 's/^ *//' -e 's/ *$//' | grep -v '^$')"
  return 0
}

# ── Linux ──────────────────────────────────────────────────────────────────
# For every /proc/<pid>/fd directory we list the symlink TARGETS. A directory
# that cannot be listed is counted UNREADABLE (EPERM on another user's process),
# which is what turns the answer into UNVERIFIABLE instead of a guessed FREE.
#
# Deliberately one `ls` per pid rather than one per fd: a /proc walk that forks
# per descriptor costs seconds on a busy box, and this runs while a human is
# waiting to get into a call.
linux_fd_census() {
  # Sets: HOLDERS (newline-separated "pid|target" records), UNREADABLE (count).
  #
  # ⛔ THE RECORD CARRIES `pid|target` AND NOTHING ELSE, AND THE FREE-FORM FIELD
  # IS LAST (review F1). `/proc/<pid>/comm` is a 15-byte string any process can
  # set with `prctl(PR_SET_NAME)` — it may contain `|` or a NEWLINE, and either
  # one DESYNCHRONISED the old `pid|comm|target` tuple: `target` no longer
  # equalled the device, `found` stayed 0, the census was COMPLETE so UNREADABLE
  # was 0, and the script printed **FREE over a device a process provably held**.
  # That is the exact fail-open the header forbids, so the free-form value is not
  # in the record at all: `comm` is resolved per holder, at emit time, through
  # `pid_comm`, which strips every character that could re-frame a record.
  # (`target`, the last field, can still contain `|` and survives — `read` gives
  # the remainder of the line to the last variable.)
  HOLDERS=""
  UNREADABLE=0
  local d pid line target total=0
  for d in "$MH_PROC"/[0-9]*; do
    [ -d "$d" ] || continue
    total=$((total + 1))
    pid="${d##*/}"
    if ! ls -l "$d/fd" >/dev/null 2>&1; then
      UNREADABLE=$((UNREADABLE + 1))
      continue
    fi
    while IFS= read -r line; do
      case "$line" in *' -> '*) ;; *) continue ;; esac
      target="${line##* -> }"
      target="${target% (deleted)}"
      # (No newline guard is needed — or possible: `ls -l` is line-oriented, so a
      # target carrying an LF arrives as a SEPARATE line without " -> " and is
      # already skipped by the case above. A `case` pattern built from
      # `$(printf '\n')` collapses to the empty string and matches EVERY line,
      # which silently disabled the whole census — the shape of bug this file is
      # about, so it is named rather than quietly deleted.)
      HOLDERS="$HOLDERS$pid|$target
"
    done <<EOF
$(ls -l "$d/fd" 2>/dev/null)
EOF
  done
  # An empty population is not "no holders": it is a failed read (no /proc, or
  # every pid denied). A caller must never read that as FREE.
  if [ "$total" -eq 0 ]; then
    UNREADABLE=1
  fi
  return 0
}

# resolve_path <path> — a portable realpath. `readlink -f` is a GNU extension
# (absent on macOS, and the portability checker flags it), and `cd … && pwd -P`
# resolves only the DIRECTORY, not a trailing symlink — which is the hop this
# needs. python3 ships on both platforms and `os.path.realpath` is exact.
resolve_path() {
  python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1" 2>/dev/null \
    || printf '%s' "$1"
}

# pid_comm <pid> — a DISPLAY-only process name, stripped of every byte that could
# re-frame a census record or produce a second line ("|", LF, CR, tab, other
# controls). `/proc/<pid>/comm` is attacker-influenced-by-the-process, so it is
# never trusted to be delimiter-free; the record simply does not contain it.
pid_comm() {
  local c
  # Delete the WHOLE C0 range including TAB (009), LF (012) and CR (015), plus
  # DEL. ⛔ The first cut wrote `\000-\011\013-\037`, which SKIPS 012 — so the LF
  # case the finding is about survived the sanitiser and still split the record.
  # The set is stated as one range for exactly that reason.
  c="$(tr -d '\000-\037\177' < "$MH_PROC/$1/comm" 2>/dev/null | tr '|' '/')"
  [ -n "$c" ] || c="?"
  printf '%s' "$c"
}

linux_camera() {
  local devs dev found=0 hit pid target real devreal base suspicious=""
  devs="$(ls -d $MH_V4L_GLOB 2>/dev/null)"
  if [ -z "$devs" ]; then
    emit_device camera ABSENT "no video device (no $MH_V4L_GLOB)"
    return 0
  fi
  base="${MH_V4L_GLOB##*/}"      # e.g. `video*` — the NAME pattern we are looking for
  linux_fd_census
  while IFS='|' read -r pid target; do
    [ -n "${pid:-}" ] || continue
    # ── F2 (review cycle 3): identity is a DEVICE, not a STRING ───────────────
    # Comparing the fd target to the globbed path as TEXT meant a holder reached
    # through an alias was invisible: the census was COMPLETE, UNREADABLE stayed
    # 0, and the script answered **FREE over a device the process provably held**.
    # `sudo fuser -v /dev/video0` and `sudo lsof /dev/video0` — the canonical
    # reads — identify holders by device identity, not by path text.
    #
    # ⛔ `hit` is PER RECORD, and that is not style: the outer `found` is sticky
    # across pids, so testing it here made every pid AFTER the first holder skip the
    # alias and unattributable arms — a flag that records a past state and is never
    # revalidated, which is the exact shape this file exists to stop.
    hit=0
    # 1. exact path match
    for dev in $devs; do
      if [ "$target" = "$dev" ]; then
        emit_device camera HELD-BY "pid=$pid comm=$(pid_comm "$pid") device=$dev"
        found=1
        hit=1
        break
      fi
    done
    [ "$hit" -eq 1 ] && continue
    # 2. an ALIAS of a globbed device (udev `by-id`/`by-path`, a symlinked node):
    #    resolve the target and compare the RESOLVED path to the device list.
    if [ -c "$target" ]; then
      real="$(resolve_path "$target")"
      for dev in $devs; do
        # BOTH SIDES RESOLVED: the holder may name an alias, and the GLOBBED path
        # may itself be a symlinked node (udev ships `by-id`/`by-path` links), so a
        # one-sided `readlink` would compare a resolved path to an unresolved one.
        devreal="$(resolve_path "$dev")"
        if [ "$real" = "$devreal" ]; then
          emit_device camera HELD-BY "pid=$pid comm=$(pid_comm "$pid") device=$dev via=$target"
          found=1
          hit=1
          break
        fi
      done
      [ "$hit" -eq 1 ] && continue
      # 3. a character device we CANNOT attribute: name-matching (a second node of
      #    the same major/minor) or outside /dev (a bind mount of the camera into a
      #    containerised cell). This is what stops a silent FREE — we say we cannot
      #    tell instead of inventing one. Innocuous nodes (/dev/null, the DRM tree,
      #    ttys) never reach here because their basename does not match the pattern
      #    and their path IS under /dev.
      case "${target##*/}" in
        $base|$base[0-9]*) suspicious="$suspicious $target" ;;
        *)
          case "$target" in
            /dev/*) ;;
            *) suspicious="$suspicious $target" ;;
          esac ;;
      esac
    fi
  done <<EOF
$(printf '%s' "$HOLDERS")
EOF
  [ "$found" -eq 1 ] && return 0
  if [ -n "$suspicious" ]; then
    emit_device camera UNVERIFIABLE "character device(s) held that are NOT the globbed camera(s):$suspicious — an alias, a bind mount or a same-major/minor node can hide the camera, so no free claim"
    return 0
  fi
  if [ "$UNREADABLE" -gt 0 ]; then
    emit_device camera UNVERIFIABLE "partial: $UNREADABLE process fd dir(s) unreadable in $MH_PROC — no free claim from a partial census"
    return 0
  fi
  emit_device camera FREE
  return 0
}

linux_microphone() {
  local capture=0 holders="" pid comm target
  if [ ! -r "$MH_ASOUND_PCM" ]; then
    emit_device microphone UNVERIFIABLE "no readable $MH_ASOUND_PCM (ALSA state not installed, or no sound stack)"
    return 0
  fi
  capture="$(grep -c 'capture' "$MH_ASOUND_PCM" 2>/dev/null || true)"
  [ -n "$capture" ] || capture=0
  if [ "$capture" -eq 0 ]; then
    emit_device microphone ABSENT "no capturing PCM subdevice in $MH_ASOUND_PCM"
    return 0
  fi
  linux_fd_census
  # One LINE per holder, and the record is `pid|target` only (see
  # linux_fd_census for why `comm` is never carried inside it).
  while IFS='|' read -r pid target; do
    [ -n "$pid" ] || continue
    case "$target" in
      /dev/snd/pcmC*c) holders="$holders$pid|$target
" ;;
    esac
  done <<EOF
$(printf '%s' "$HOLDERS")
EOF
  if [ -n "$holders" ]; then
    local p t
    while IFS='|' read -r p t; do
      [ -n "${p:-}" ] || continue
      emit_device microphone HELD-BY "pid=$p comm=$(pid_comm "$p") device=$t"
    done <<EOF
$(printf '%s' "$holders")
EOF
    return 0
  fi
  # ⛔ No FREE for the microphone on Linux: ALSA has no holder table, so "nobody
  # opened a capture PCM" and "we could not see who opened one" are the same
  # bytes. $capture capture subdevices EXIST — that is all we proved.
  emit_device microphone UNVERIFIABLE "$capture capturing PCM subdevice(s) exist; ALSA has no holder table, so no read can prove free"
  return 0
}

# ── macOS ──────────────────────────────────────────────────────────────────
mac_camera_presence() {
  # Sets PRESENCE="present" | "absent" | "unknown", PRESENCE_WHY
  PRESENCE="unknown"
  PRESENCE_WHY=""
  if [ "$SKIP_PRESENCE" -eq 1 ]; then
    PRESENCE_WHY="presence read skipped (--skip-presence)"
    return 0
  fi
  local out rc
  out="$(system_profiler SPCameraDataType 2>&1)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    PRESENCE_WHY="system_profiler rc=$rc: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-120)"
    return 0
  fi
  if grep -q 'Model ID' <<<"$out"; then
    PRESENCE="present"
  else
    PRESENCE="absent"
  fi
  return 0
}

mac_coremedia_log() {
  # Sets LOG_HITS (count of capture-looking lines) and LOG_ERR.
  LOG_HITS=0
  LOG_ERR=""
  local out rc
  out="$(log show --last 2m --predicate 'subsystem == "com.apple.coremedia"' 2>&1)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    LOG_ERR="log show rc=$rc: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-120)"
    return 1
  fi
  LOG_HITS="$(printf '%s' "$out" | grep -c -i -e 'capture' -e 'AVCapture' || true)"
  [ -n "$LOG_HITS" ] || LOG_HITS=0
  return 0
}

mac_camera() {
  mac_camera_presence
  if [ "$PRESENCE" = "absent" ]; then
    emit_device camera ABSENT "system_profiler SPCameraDataType lists no camera"
    return 0
  fi
  if [ "$PRESENCE" = "unknown" ]; then
    emit_device camera UNVERIFIABLE "$PRESENCE_WHY"
    return 0
  fi
  mac_coremedia_log
  if [ "$LOG_HITS" -gt 0 ]; then
    # A hit is a CAPTURE EVENT, not an owner: macOS publishes no per-client
    # owner. Reporting a pid here would be an invention.
    emit_device camera UNVERIFIABLE "$LOG_HITS capture-event line(s) in the last 2m, but macOS publishes no per-client owner; use --apps and read docs/ops/media-devices.md"
    return 0
  fi
  if read_apps; then
    emit_device camera UNVERIFIABLE "no capture event in the coremedia log; foreground apps: $(printf '%s' "$APPS" | tr '\n' ' ')"
  else
    emit_device camera UNVERIFIABLE "no capture event in the coremedia log; ${APPS_ERR}${LOG_ERR:+; $LOG_ERR}"
  fi
  return 0
}

mac_microphone() {
  if [ "$SKIP_PRESENCE" -eq 0 ]; then
    local out
    out="$(system_profiler SPAudioDataType 2>&1)"
    if grep -q -i 'input' <<<"$out"; then
      :
    else
      emit_device microphone UNVERIFIABLE "system_profiler SPAudioDataType reported no input channel (or could not be read)"
      return 0
    fi
  fi
  mac_coremedia_log
  emit_device microphone UNVERIFIABLE "macOS publishes no per-client microphone owner${LOG_ERR:+ ($LOG_ERR)}; use --apps and read docs/ops/media-devices.md"
  return 0
}

# ── --ancestry: the LANE root, not the app ─────────────────────────────────
ancestry() {
  # `--ancestry <pid>` ACQUIRES evidence; it pronounces no verdict. Emits one line
  # per hop (plain), or ONE JSON OBJECT carrying a `chain` array — never a stream
  # of objects, because `--json` is documented as one document and a caller that
  # pipes it into a parser must not have to guess how many objects to expect
  # (review F3: the second hop used to arrive as a bare prose line).
  local pid="$1" hops=0 prev="" comm ppid cmd chain_json=""
  case "$pid" in ''|*[!0-9]*) die3 "--ancestry needs a numeric pid, got '$pid'" ;; esac
  while [ -n "$pid" ] && [ "$pid" != "0" ] && [ "$hops" -lt 24 ]; do
    comm="$(cat "$MH_PROC/$pid/comm" 2>/dev/null || true)"
    if [ -z "$comm" ]; then
      if [ "$JSON" -eq 1 ]; then
        [ -n "$chain_json" ] && chain_json="$chain_json,"
        chain_json="$chain_json{\"pid\":$pid,\"unreadable\":true,\"why\":$(json_str "unreadable in $MH_PROC — the chain stops here")}"
      else
        say "pid=$pid (unreadable in $MH_PROC — the chain stops here)"
      fi
      pid=""
      break
    fi
    # The full cmdline is what names the lane (`pi -p …`, `bash …/lane.sh <N>`).
    # NULs are the argument separators; LF/CR are kept for `json_str` to ESCAPE
    # (a lane root's argv is multi-line by construction).
    cmd="$(tr '\000' ' ' < "$MH_PROC/$pid/cmdline" 2>/dev/null | cut -c1-160)"
    ppid="$(awk '/^PPid:/{print $2}' "$MH_PROC/$pid/status" 2>/dev/null || true)"
    if [ "$JSON" -eq 1 ]; then
      [ -n "$chain_json" ] && chain_json="$chain_json,"
      chain_json="$chain_json{\"pid\":$pid,\"ppid\":${ppid:-0},\"comm\":$(json_str "$comm"),\"cmdline\":$(json_str "$cmd")}"
    else
      say "pid=$pid ppid=${ppid:-?} comm=$comm cmd=$cmd"
    fi
    [ "$ppid" = "$prev" ] && break     # cycle guard
    prev="$pid"
    pid="$ppid"
    hops=$((hops + 1))
  done
  [ "$hops" -lt 24 ] || say "$PROG: ancestry truncated at 24 hops (a cycle, or a very deep tree)" >&2
  if [ "$JSON" -eq 1 ]; then
    say "{\"platform\":$(json_str "$MH_PLATFORM"),\"chain\":[$chain_json]}"
  fi
  return 0
}

# ── main ───────────────────────────────────────────────────────────────────

if [ -n "$ANCESTRY" ]; then
  ancestry "$ANCESTRY"
  exit 0
fi

if [ "$APPS_ONLY" -eq 1 ]; then
  if read_apps; then
    if [ "$JSON" -eq 1 ]; then
      APPS_JSON=""
      while IFS= read -r a; do
        [ -n "$a" ] || continue
        [ -n "$APPS_JSON" ] && APPS_JSON="$APPS_JSON,"
        APPS_JSON="$APPS_JSON$(json_str "$a")"
      done <<EOF
$APPS
EOF
      say "{\"platform\":$(json_str "$MH_PLATFORM"),\"apps\":[$APPS_JSON]}"
    else
      printf '%s\n' "$APPS"
    fi
    exit 0
  fi
  if [ "$JSON" -eq 1 ]; then
    say "{\"platform\":$(json_str "$MH_PLATFORM"),\"apps\":null,\"why\":$(json_str "$APPS_ERR")}"
  else
    say "apps: UNVERIFIABLE($APPS_ERR)"
  fi
  exit 2
fi

case "$MH_PLATFORM" in
  Linux)  linux_camera; linux_microphone ;;
  Darwin) mac_camera; mac_microphone ;;
  *)
    emit_device camera UNVERIFIABLE "no media-device reader for platform '$MH_PLATFORM'"
    emit_device microphone UNVERIFIABLE "no media-device reader for platform '$MH_PLATFORM'"
    ;;
esac

if [ "$JSON" -eq 1 ]; then
  say "{\"platform\":$(json_str "$MH_PLATFORM"),\"devices\":[$JSON_DEVICES]}"
fi

# The exit code is part of the answer: 2 = CANNOT VERIFY, never "free". Read from
# the verdict counter (not from the JSON text), so the JSON and plain paths agree.
[ "$SAW_UNVERIFIABLE" -eq 1 ] && exit 2
exit 0
