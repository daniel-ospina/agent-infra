#!/usr/bin/env bash
# cell-home-migrate.test.sh — the tool that converges a box onto ONE home (agent-infra#3453).
#
# WHY THIS SUITE EXISTS, AND WHAT IT REFUSES TO TAKE ON FAITH
# ---------------------------------------------------------
# `cell-home-migrate.sh --apply` EDITS UNIT FILES ON A LIVE CELL. Two ways that can go wrong are worse
# than not running it at all, and both are silent:
#
#   * it copies a credential over a NEWER one — a rotated key rolled back to a stale value, with the box
#     reading as converged (the "0 landings" failure wearing a `provider=OK` mask);
#   * it repoints a unit to a path that does NOT exist — `ExecStart=` then exits 203/EXEC on the next
#     restart, i.e. a migration that turned a working cell into a dead one, and the tool reported success.
#
# So the arms below are about the REFUSALS as much as the writes:
#   (a) `--check` is read-only and its verdict is real: converged -> 0, drift -> 1
#   (b) a credential is copied ONLY when the durable side is missing; an existing one is never touched;
#       a legacy copy NEWER than the durable one is reported as a conflict and NOTHING is written
#   (c) no secret VALUE ever reaches stdout/stderr — the fixture plants a sentinel and the arms grep for it
#   (d) a unit whose projected path is missing is REFUSED BY NAME and the original file is untouched
#   (e) `--apply` is idempotent, keeps a one-time backup, and NEVER deletes the legacy home
#   (f) NON-VACUITY: each of (b)(d) is driven against a MUTATED COPY of the tool (§g) — without that,
#       "the file was refused" could be satisfied by a tool that refused everything.
#
# HERMETIC: every path is under mktemp. The unit dirs come from the tool's own documented seam
# (`CELL_HOME_MIGRATE_UNIT_DIRS`), the reload is disabled with `CELL_HOME_MIGRATE_NO_RELOAD=1`, and no
# real home, credential or systemd manager is touched.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
set -u
TOOL="$HERE/cell-home-migrate.sh"
[ -f "$TOOL" ] || { echo "FATAL: $TOOL not found" >&2; exit 2; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

T="$(mktemp -d 2>/dev/null)" || { echo "FATAL: mktemp -d failed" >&2; exit 2; }
trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT

SENTINEL="sk-CELLHOME-SENTINEL-3453"

# ── a fresh fixture box: two homes, a drifting unit, and the credential shapes that matter ────────
mk_box() { # <dir> — returns the paths in NEW/DUR/LEG/UNITS
  local d="$1"
  NEW="$d"; DUR="$d/durable"; LEG="$d/legacy"; UNITS="$d/units"
  rm -rf "$NEW"; mkdir -p "$DUR/.pi/agent" "$DUR/.local/bin" "$DUR/harness" "$LEG/.pi/agent" "$UNITS/app.service.d"
  printf '#!/bin/sh\n' >"$DUR/harness/run.sh"; chmod +x "$DUR/harness/run.sh"
  # keys.env exists on BOTH sides (the measured cell-3/cell-4 shape), auth.json only on the legacy side,
  # hosts.yml only on the durable side.
  printf 'export HOME=%s\nDEEPSEEK_API_KEY=%s\n' "$DUR" "$SENTINEL" >"$LEG/keys.env"; chmod 600 "$LEG/keys.env"
  printf 'export HOME=%s\nDEEPSEEK_API_KEY=%s\n' "$DUR" "$SENTINEL" >"$DUR/keys.env"; chmod 600 "$DUR/keys.env"
  printf '{"deepseek":{"type":"api_key","key":"%s"}}\n' "$SENTINEL" >"$LEG/.pi/agent/auth.json"; chmod 600 "$LEG/.pi/agent/auth.json"
  mkdir -p "$DUR/.config/gh"
  printf 'github.com:\n  oauth_token: %s\n' "$SENTINEL" >"$DUR/.config/gh/hosts.yml"
  chmod 600 "$DUR/.config/gh/hosts.yml"
  # The drifting unit — the measured cell-4 shape, minus the directives that would make it unrunnable.
  cat >"$UNITS/app.service" <<EOF
[Service]
# a COMMENT naming $LEG must not be graded (unit files carry paragraphs of measured history)
User=cmux
Environment=HOME=$LEG
Environment=CELL_HOME=$LEG
Environment=PATH=$LEG/.local/bin:/usr/local/bin:/usr/bin
ExecStart=$LEG/harness/run.sh
EOF
  printf '[Service]\nEnvironment=HOME=%s\n' "$LEG" >"$UNITS/app.service.d/env.conf"
}

run_tool() { # <tool> <mode> — the tool against the fixture, hermetic
  CELL_HOME="$DUR" CELL_HOME_LEGACY="$LEG" CELL_HOME_MIGRATE_UNIT_DIRS="$UNITS" \
  CELL_HOME_MIGRATE_NO_RELOAD=1 bash "$1" "$2" 2>&1
}
run_tool_rc() { # <tool> <mode> — same, printing only the rc
  local out rc
  out="$(run_tool "$1" "$2")"; rc=$?
  printf '%s' "$rc"
  LAST_OUT="$out"
}

printf '\n── (a) --check is read-only, and its verdict is real ────────────────────────────────\n'

mk_box "$T/a"
_out="$(run_tool "$TOOL" --check)"; _rc=$?
case "$_out" in *"app.service"*) ok "a1 the check NAMES the drifting unit" ;; *) bad "a1 the check does not name the drifting unit" ;; esac
[ "$_rc" = 1 ] && ok "a2 drift -> rc 1" || bad "a2 drift -> rc 1 (got $_rc)"
# Read-only: byte-for-byte unchanged, and no backup was created.
_before="$(cat "$UNITS/app.service" "$UNITS/app.service.d/env.conf")"
_out2="$(run_tool "$TOOL" --check)"
_after="$(cat "$UNITS/app.service" "$UNITS/app.service.d/env.conf")"
[ "$_before" = "$_after" ] && ok "a3 --check changed NOTHING in the unit files" || bad "a3 --check modified a unit file"
[ ! -e "$UNITS/app.service.pre-cell-home" ] && ok "a4 --check wrote no backup (it wrote no file at all)" || bad "a4 --check created a backup"
case "$_out" in *"legacy home size:"*) ok "a5 the deferred reclaim is stated as a NUMBER, not as prose" ;; *) bad "a5 the legacy home size is not reported" ;; esac
case "$_out" in *"NOT reclaimed"*) ok "a6 …and it says the legacy home is NOT reclaimed by this change" ;; *) bad "a6 the output does not say the legacy home is left alone" ;; esac

printf '\n── (c) NO SECRET VALUE EVER REACHES THE OUTPUT ─────────────────────────────────────\n'

case "$_out" in *"$SENTINEL"*) bad "c1 --check printed a credential VALUE" ;; *) ok "c1 --check never prints a credential value (the fixture sentinel does not appear)" ;; esac
_out_apply="$(run_tool "$TOOL" --apply)"
case "$_out_apply" in *"$SENTINEL"*) bad "c2 --apply printed a credential VALUE" ;; *) ok "c2 --apply never prints a credential value" ;; esac
case "$_out" in *"keys.env: legacy"*) ok "c3 …while still REPORTING each credential (path/size/mode, value absent)" ;; *) bad "c3 credentials are not reported at all" ;; esac

printf '\n── (b) CREDENTIALS: copy only what is missing, never overwrite ─────────────────────\n'

mk_box "$T/b"
# keys.env exists on both sides: the durable copy must be untouched (compare BYTES + mtime).
printf 'durable-marker\n' >>"$DUR/keys.env"
_dur_before="$(cat "$DUR/keys.env")"; _dur_mtime="$(stat -c %Y "$DUR/keys.env" 2>/dev/null || stat -f %m "$DUR/keys.env")"
run_tool "$TOOL" --apply >/dev/null 2>&1
_dur_after="$(cat "$DUR/keys.env")"; _dur_mtime2="$(stat -c %Y "$DUR/keys.env" 2>/dev/null || stat -f %m "$DUR/keys.env")"
[ "$_dur_before" = "$_dur_after" ] && [ "$_dur_mtime" = "$_dur_mtime2" ] \
  && ok "b1 an EXISTING durable keys.env is neither rewritten nor touched (same bytes, same mtime)" \
  || bad "b1 the durable keys.env was modified"

# auth.json exists ONLY on the legacy side: it must be copied, at mode 600.
[ -f "$DUR/.pi/agent/auth.json" ] && ok "b2 a credential MISSING from the durable home is copied in" \
  || bad "b2 a missing credential was not copied"
_mode="$(stat -c %a "$DUR/.pi/agent/auth.json" 2>/dev/null || stat -f %Lp "$DUR/.pi/agent/auth.json")"
[ "$_mode" = 600 ] && ok "b3 …with mode 600 (never momentarily group/other-readable)" || bad "b3 copied credential mode is $_mode, not 600"

# A legacy copy NEWER than the durable one is a CONFLICT: reported, and NOTHING written.
mk_box "$T/c"
printf 'legacy-newer\n' >>"$LEG/keys.env"; sleep 1; touch "$LEG/keys.env"
_dur_before="$(cat "$DUR/keys.env")"
_out="$(run_tool "$TOOL" --apply)"
case "$_out" in *"LEGACY copy is NEWER"*) ok "b4 a legacy copy NEWER than the durable one is named as a CONFLICT" ;; *) bad "b4 the newer-legacy conflict is not reported" ;; esac
[ "$_dur_before" = "$(cat "$DUR/keys.env")" ] && ok "b5 …and the durable copy is left EXACTLY as it was (no rollback)" || bad "b5 the durable copy was overwritten"

printf '\n── (d) UNITS: repoint what runs, refuse what would not ─────────────────────────────\n'

mk_box "$T/d"
run_tool "$TOOL" --apply >/dev/null 2>&1
grep -q "Environment=HOME=$DUR" "$UNITS/app.service" && ok "d1 --apply repoints Environment=HOME= to the durable home" \
  || bad "d1 Environment=HOME= was not repointed"
grep -q "ExecStart=$DUR/harness/run.sh" "$UNITS/app.service" && ok "d2 …and ExecStart= (a projected path that EXISTS)" \
  || bad "d2 ExecStart= was not repointed"
grep -v '^[[:space:]]*#' "$UNITS/app.service" | grep -qF "$LEG" && bad "d3 the legacy path survived in a graded directive" || ok "d3 no graded directive still names the legacy home (comments excluded by design)"
grep -q "a COMMENT naming" "$UNITS/app.service" && ok "d4 …while the COMMENT naming the legacy home is untouched (a comment is not a directive)" \
  || bad "d4 the comment was altered (comments must not be graded)"
[ -f "$UNITS/app.service.pre-cell-home" ] && ok "d5 a one-time backup is kept beside the rewritten file" || bad "d5 no backup was written"
grep -q "Environment=HOME=$DUR" "$UNITS/app.service.d/env.conf" && ok "d6 a DROP-IN is repointed too (systemd merges both shapes)" \
  || bad "d6 the drop-in was not repointed"

# Idempotence: a second --apply writes nothing and reports converged.
_b1="$(grep -v '^$' "$UNITS/app.service")"; _bk="$(cat "$UNITS/app.service.pre-cell-home")"
_out="$(run_tool "$TOOL" --apply)"; _rc=$?
[ "$_rc" = 0 ] && ok "d7 a second --apply exits 0 (converged)" || bad "d7 a second --apply exits $_rc"
[ "$(grep -v '^$' "$UNITS/app.service")" = "$_b1" ] && ok "d8 …and changes nothing (idempotent)" || bad "d8 the second --apply rewrote the unit"
[ "$(cat "$UNITS/app.service.pre-cell-home")" = "$_bk" ] && ok "d9 …and does not clobber the first backup with the migrated file" \
  || bad "d9 the backup was overwritten by the second run"
# The follow-up --check on the migrated box is green (i.e. the tool's own verdict agrees).
run_tool "$TOOL" --check >/dev/null 2>&1 && ok "d10 the post-migration --check reports ONE HOME (rc 0)" \
  || bad "d10 the post-migration --check is not green"

# ⛔ THE DANGEROUS WRITE, REFUSED: ExecStart names a path the durable home does not have.
mk_box "$T/e"
rm -f "$DUR/harness/run.sh"
_before="$(cat "$UNITS/app.service")"
_out="$(run_tool "$TOOL" --apply)"; _rc=$?
[ "$_rc" = 1 ] && ok "d11 an unrunnable repoint -> rc 1 (a refusal is not a success)" || bad "d11 an unrunnable repoint exited $_rc"
case "$_out" in *"REFUSED"*"app.service"*) ok "d12 …the refusal NAMES the file" ;; *) bad "d12 the refusal does not name the file" ;; esac
case "$_out" in *"$DUR/harness/run.sh"*) ok "d13 …and names the MISSING durable target it would have written" ;; *) bad "d13 the refusal does not name the missing target" ;; esac
[ "$_before" = "$(cat "$UNITS/app.service")" ] && ok "d14 …and the unit file is left BYTE-FOR-BYTE unchanged" \
  || bad "d14 the refused unit was modified anyway"
# …while the same run still did the safe half (the credential copy is independent of the unit).
[ -f "$DUR/.pi/agent/auth.json" ] && ok "d15 the credential half still converged (a refusal is scoped to the file it refused)" \
  || bad "d15 one refused unit stopped the credential convergence too"

# The legacy home is NEVER deleted — the constraint the change is bounded by.
[ -d "$LEG" ] && [ -f "$LEG/keys.env" ] && ok "d16 the LEGACY home still exists after --apply (never deleted by this change)" \
  || bad "d16 the legacy home was deleted or emptied"

printf '\n── (g) NON-VACUITY: the refusals are the code, not the fixture ──────────────────────\n'

# g1: remove the existence check from the tool and d11-d14 must fail — i.e. the arm above really is
# testing the guard, not a fixture that could never have been written.
mkdir -p "$T/mutdir/lib"; cp "$HERE/lib/cell-home.sh" "$T/mutdir/lib/cell-home.sh"
MUT="$T/mutdir/cell-home-migrate.sh"
sed 's#\[ -e "\$p" \] || miss="\$miss \$p"#:#' "$TOOL" >"$MUT"
if cmp -s "$TOOL" "$MUT"; then
  bad "g1 the mutation could not be applied — (d) is not checking the existence guard"
else
  mk_box "$T/f"
  rm -f "$DUR/harness/run.sh"
  run_tool "$MUT" --apply >/dev/null 2>&1
  if grep -q "ExecStart=$DUR/harness/run.sh" "$UNITS/app.service"; then
    ok "g1 WITHOUT the existence guard the tool DOES write the unrunnable unit — (d) measures the guard"
  else
    bad "g1 the mutated tool still refused — (d) is not measuring the existence guard"
  fi
fi

# g2: remove the "copy only when missing" test and b1 must fail (the durable copy gets clobbered).
mkdir -p "$T/mutdir2/lib"; cp "$HERE/lib/cell-home.sh" "$T/mutdir2/lib/cell-home.sh"
MUT2="$T/mutdir2/cell-home-migrate.sh"
sed 's#^    if \[ -e "\$f_dur" \]; then#    if false; then#' "$TOOL" >"$MUT2"
if cmp -s "$TOOL" "$MUT2"; then
  bad "g2 the mutation could not be applied — (b) is not checking the copy guard"
else
  mk_box "$T/g"
  printf 'durable-marker\n' >>"$DUR/keys.env"
  run_tool "$MUT2" --apply >/dev/null 2>&1
  if grep -q 'durable-marker' "$DUR/keys.env"; then
    bad "g2 the mutated tool still kept the durable copy — (b) is not measuring the copy guard"
  else
    ok "g2 WITHOUT the copy guard the tool OVERWRITES the durable credential — (b) measures the guard"
  fi
fi

printf '\n── (h) argument handling ────────────────────────────────────────────────────────────\n'
run_tool "$TOOL" --nonsense >/dev/null 2>&1 && bad "h1 an unknown argument is not refused" || ok "h1 an unknown argument is refused"
run_tool "$TOOL" --help >/dev/null 2>&1 && ok "h2 --help exits 0" || bad "h2 --help exits non-zero"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ] || exit 1
exit 0
