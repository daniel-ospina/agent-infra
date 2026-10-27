#!/usr/bin/env bash
# frag-stubs.sh — the ONE place a FRAGMENT RUNNER neutralises what a shipped fragment can reach.
#
#        . "$(dirname "$0")/lib/frag-stubs.sh"      # or an equivalent absolute path
#        mk_quiet_bin "$B/bin" "$B/calls"           # a RECORDER first on the fragment's own PATH
#        PATH="$B/bin:/usr/bin:/bin" bash -c "${FRAG_STUBS}my_behaviour_stub(){ :; }; $(cat "$FRAG")"
#        [ -s "$B/calls" ] && bad "the fragment reached a real system binary: $(cat "$B/calls")"
#
# ── THE DEFECT THIS FILE EXISTS TO CLOSE (agent-infra #2910) ────────────────────────────────────
# A runner that extracts a SLICE of a shipped script and executes it in a fresh shell gets a shell in
# which that script's own functions DO NOT EXIST. Every name the fragment calls is then either stubbed
# by the runner or resolved through PATH — and on macOS `say` resolves to /usr/bin/say, the
# text-to-speech binary. That is not hypothetical: `install-controller-service.test.sh` executed the
# supervisor's service-mode fragment with its `say` unbaked and READ
# `controller: FOREGROUND — this process is the controller …` ALOUD through the speaker, repeatedly,
# during the owner's live customer call (2026-10-27; `pmset -g assertions` showed `audio-out
# BuiltInSpeakerDevice` created for the say pid). No arm failed, nothing was logged: the suite read
# GREEN while it spoke.
#
# The FIRST repair (#2911) added a stub prelude to ONE suite. ~50 minutes later a live lane ran that
# suite from ITS OWN pre-fix worktree and the machine spoke again — because a per-file stub list is a
# convention, and a convention is a thing a new runner can forget. So the list lives here, once, and
# the second half of the fix is a NAME that cannot resolve to a binary: the helper is `log_line`, so a
# forgotten definition now fails as `bash: log_line: command not found` — loud, local, attributable,
# and silent to the owner's speakers. See the rename in this same change (#2910).
#
# ── THE CONTRACT: BOTH HALVES, AND NEITHER IS OPTIONAL ──────────────────────────────────────────
#   1. FRAG_STUBS — stub the names the SHIPPED SCRIPT defines (its print/log helpers), so the fragment
#      stays quiet and self-contained. A new helper added to the supervisor later must be added here;
#      `install-controller-service.test.sh` §O ENFORCES that by enumerating the file-scope functions of
#      `cloud-cell-supervisor.sh` which the shipped fragment actually invokes, so a new one is RED on
#      the next run instead of becoming a voice on the next call.
#   2. mk_quiet_bin — a RECORDER first on PATH for the binaries that can SPEAK or LAUNCH
#      (`say`, `open`, `osascript`, `afplay`). This half is the capability guard: it intercepts the
#      BINARY, so it survives our helper being renamed again, and asserting the calls file is empty is
#      evidence about the real system rather than the absence of a crash.
#
# ⛔ `say` IS DELIBERATELY **NOT** IN `FRAG_STUBS`, AND THAT IS THE WHOLE POINT OF THE SPLIT.
# Stubbing `say` here would shadow the recorder too, so "the calls file is empty" would be vacuous —
# it would prove only that our own stub ran. `say` is a SYSTEM binary name (layer 2's business), not
# one of our helper names (layer 1's), and the two lists change for different reasons: layer 1 tracks
# this repo's code, layer 2 tracks macOS.
# ⛔ And `die` is never stubbed: it is BEHAVIOUR (it exits 1), not output, so stubbing it would silence
# a fragment's real failure paths and turn an arm into a green over nothing.

# Layer 1 — the names OUR shipped scripts define at file scope and a fragment may call.
# `log_line` is the print helper (renamed from `say` in #2910 — see above).
FRAG_STUBS='log_line(){ :; }; open(){ :; }; osascript(){ :; }; afplay(){ :; }; '

# Layer 2 — the system binaries that make a NOISE or LAUNCH something. A fragment-runner recorder
# should cover all of these; a suite-runner covering only `say` is stated at its own call site.
FRAG_SYSTEM_CALLS='say open osascript afplay'

# mk_quiet_bin <bin dir> <calls file> [binary ...]
# Creates <bin dir> and puts a RECORDER in it for each binary named (default: FRAG_SYSTEM_CALLS). A
# recorder appends its own name and argv to <calls file> and exits 0 — it never performs the action.
# The caller must put <bin dir> FIRST on the PATH the fragment runs with (the fragment suites already
# set PATH="$B/bin:/usr/bin:/bin"), which is what makes the empty-calls-file assertion meaningful.
mk_quiet_bin() { # <bin dir> <calls file> [binary ...]
  local bin="$1" calls="$2"; shift 2
  local n names
  [ "$#" -gt 0 ] && names="$*" || names="$FRAG_SYSTEM_CALLS"
  mkdir -p "$bin" || return 1
  : > "$calls" || return 1
  for n in $names; do
    cat > "$bin/$n" <<SHIM
#!/bin/bash
printf '%s %s\n' "$n" "\$*" >> "$calls"
exit 0
SHIM
    chmod +x "$bin/$n" || return 1
  done
}
