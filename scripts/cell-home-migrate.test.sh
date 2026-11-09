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
#   (k) CANNOT MEASURE IS NOT A VERDICT: a unit this account cannot OPEN, a drop-in dir it cannot WALK,
#       and a legacy credential path it cannot STAT are all exit 3 — never 0 ("one home") and never 1
#       (ordinary drift), because `--check` -> 0 is the stated precondition for RECLAIMING the legacy
#       home. The tool's own exit table reserved 3 for this class; nothing was raising it on the read
#       that matters most, so an unread file read as a clean one.
#   (k) A CONTINUATION BELONGS TO ITS LOGICAL LINE: an intermediate continuation line that names no
#       legacy path, and a COMMENT between continued lines, both still converge — `systemd.syntax(7)`
#       concatenates the lines and ignores a comment block after a backslash. Clearing the inherited
#       directive name on either shape refused a unit the tool can perfectly well re-base, and made
#       `--check` unreachable -> 0 for a reason the tool invented.
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
  # ⛔ THE COMMENT CARRIES A LEGACY PATH FOLLOWED BY A `/` ON PURPOSE: that is the only shape a naive
  # rewriter would touch, so the comment arm can VARY. With the path followed by a space the occurrence is
  # never re-based and the arm passes whether or not the writer grades comments (review F3, `d4`).
  cat >"$UNITS/app.service" <<EOF
[Service]
# a COMMENT naming $LEG/state must not be graded (unit files carry paragraphs of measured history)
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
# ⛔ THE DERIVATION ARMS BELOW STUB THEIR PASSWD HOME UNDER `$T` (I.E. UNDER A VOLATILE ROOT), AND THAT IS
# FINE — `cell_home_resolve`'s step 2 applies the "is this a home at all" test (absolute, not `/`) and NOT
# the volatile-root test, because the passwd record is the box's AUTHORITATIVE answer rather than a guess
# lifted from the environment. See `lib/cell-home.sh` step 2 and its `a10` arm (`scripts/lib/cell-home.test.sh`),
# which pins that polarity in the opposite direction. So a fixture account home under `/tmp` is what these
# arms get, and no seam is needed to make it stick.
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

# ⛔ THE ARM THAT WAS MISSING, AND WHY IT MATTERS (review F1 / rule-3). The ONLY row that claimed to
# observe the `--check` verdict used to be `a2`, and its red came from `check_credentials` ALONE (the
# fixture plants `auth.json` on the legacy side only). So `check_units` could `return 0` unconditionally
# and the whole suite stayed green — which is how a `--check` that answered "one home" on a box with
# EVERY unit still pointed at the legacy home shipped. `--check` -> 0 is the stated precondition for
# RECLAIMING the legacy home, so that false PASS is a delete-the-live-directory defect, not a cosmetic
# one. The fixture below is the shape that catches it: credentials already CONVERGED (nothing for the
# credential leg to report) and units un-migrated with every durable counterpart PRESENT (nothing for
# the missing-target leg to refuse) — i.e. the ordinary "just run --apply" box.
mk_box "$T/a2"
cp "$LEG/.pi/agent/auth.json" "$DUR/.pi/agent/auth.json"
chmod 600 "$DUR/.pi/agent/auth.json"
_out="$(run_tool "$TOOL" --check)"; _rc=$?
[ "$_rc" = 1 ] && ok "a7 CONVERGED credentials + UN-MIGRATED units whose every target exists -> --check is 1 (a repointable record is drift, not convergence)" \
  || bad "a7 --check reported $_rc on an un-migrated box whose credentials were already converged — the reclaim precondition would read as met"
case "$_out" in *"NOT CONVERGED"*) ok "a8 …and it reports the record as NOT CONVERGED, not as a mere existing counterpart" ;; *) bad "a8 the check does not report the record as un-converged" ;; esac
# The polarity partner: the SAME fixture after --apply must be 0, so a7 cannot be satisfied by a tool
# that answers 1 to everything.
run_tool "$TOOL" --apply >/dev/null 2>&1
run_tool "$TOOL" --check >/dev/null 2>&1 && ok "a9 …the same fixture after --apply reads 0 (a7 is a polarity, not a tool that always says drift)" \
  || bad "a9 the migrated box does not read converged"

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

# ⛔ THE TWO MODES MUST NOT DISAGREE ABOUT THE SAME BOX (fresh-context review F1). `--check` printed the
# divergence warning and did NOT set rc, while `--apply` set it — so `--check` answered
# "one home — nothing to do" over a box whose LEGACY credential was NEWER than the durable one. That is
# the dangerous direction: `--check` -> 0 is the stated precondition for RECLAIMING the legacy home, so
# the quiet half told an operator to delete the only copy of a rotated key. The fixture is deliberately
# CONVERGED everywhere else (units migrated, every other credential present on both sides) so the red can
# only come from the conflict leg itself — the hazard is per-file, and it must survive converged peers.
mk_box "$T/newer"
run_tool "$TOOL" --apply >/dev/null 2>&1     # converge units + copy the legacy-only auth.json
run_tool "$TOOL" --check >/dev/null 2>&1 && ok "b6 the converged fixture first reads 0 (the polarity partner for b7/b8)" \
  || bad "b6 fixture: the converged box does not read 0, so b7/b8 could not isolate the conflict"
sleep 1; touch "$LEG/keys.env"               # ONLY keys.env diverges, and the LEGACY side is the newer one
_out="$(run_tool "$TOOL" --check)"; _rc=$?
case "$_out" in *"LEGACY copy is NEWER"*) ok "b7 --check NAMES the newer-legacy conflict" ;; *) bad "b7 --check does not report the newer-legacy conflict" ;; esac
[ "$_rc" = 1 ] && ok "b8 …and --check exits 1 on it, so the reclaim precondition cannot read as met" \
  || bad "b8 --check answered $_rc over a box whose legacy credential is NEWER than the durable one"
run_tool "$TOOL" --apply >/dev/null 2>&1; _rc2=$?
[ "$_rc2" = 1 ] && ok "b9 …and --apply agrees with --check on the same box (one predicate, two modes)" \
  || bad "b9 --apply answered $_rc2 where --check answers 1 — the two modes disagree"

printf '\n── (d) UNITS: repoint what runs, refuse what would not ─────────────────────────────\n'

mk_box "$T/d"
run_tool "$TOOL" --apply >/dev/null 2>&1
grep -q "Environment=HOME=$DUR" "$UNITS/app.service" && ok "d1 --apply repoints Environment=HOME= to the durable home" \
  || bad "d1 Environment=HOME= was not repointed"
grep -q "ExecStart=$DUR/harness/run.sh" "$UNITS/app.service" && ok "d2 …and ExecStart= (a projected path that EXISTS)" \
  || bad "d2 ExecStart= was not repointed"
# A GRADED directive must carry no legacy path once migrated — compared through the SHELL, not through a
# `grep -q` pipe: a quiet grep at the end of a pipe is the SIGPIPE false-negative idiom under `pipefail`
# (#841/#864), and this suite is itself linted by `scripts/check-no-sigpipe-grep.sh`.
_graded_body="$(grep -v '^[[:space:]]*#' "$UNITS/app.service" || true)"
case "$_graded_body" in *"$LEG"*) bad "d3 the legacy path survived in a graded directive" ;; *) ok "d3 no graded directive still names the legacy home (comments excluded by design)" ;; esac
grep -q "a COMMENT naming" "$UNITS/app.service" && ok "d4 …while the COMMENT naming the legacy home is untouched (a comment is not a directive)" \
  || bad "d4 the comment was altered (comments must not be graded)"
# ⛔ THE COMMENT'S BYTES, AND A SHAPE THAT CAN VARY (review F3). The arm above asserted that a comment
# containing the legacy path still existed — but the fixture's comment had the path followed by a SPACE,
# which the boundary rule never re-bases, so the arm passed whether or not the writer graded comments: it
# was dead weight. `_project_file` passed EVERY line through the projector while the scanner skipped `#`,
# so an operator's measured history inside a root-owned unit was silently edited — and the edited comment
# then read as a FALSE statement about the past. This arm compares the whole comment line.
mk_box "$T/cmt"
_cmt_before="$(grep '^# a COMMENT naming' "$UNITS/app.service")"
run_tool "$TOOL" --apply >/dev/null 2>&1
_cmt_after="$(grep '^# a COMMENT naming' "$UNITS/app.service")"
[ -n "$_cmt_before" ] && [ "$_cmt_before" = "$_cmt_after" ] \
  && ok "d4b …and the comment is BYTE-IDENTICAL after --apply (the writer does not rewrite what the scanner skips)" \
  || bad "d4b the comment was rewritten: '$_cmt_after' (a comment is not a directive, in either direction)"
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

# ⛔ A BACKSLASH CONTINUATION IS PART OF ITS DIRECTIVE (review P1). The scan grades a continuation by
# INHERITING the directive name while the old writer re-based only lines that literally began with a
# graded directive — so this file was HALF-written, `--apply` printed "one home" and exited 0, and the
# next `--check` blamed the operator for the tool's own partial write. The arm asserts the CONTENT (a
# half-written file also exits 0 on the pre-fix code, so an rc assertion here would be vacuous).
mk_box "$T/cont"
mkdir -p "$DUR/state"
cat >"$UNITS/app.service" <<EOF
[Service]
Environment=HOME=$LEG
ExecStart=$LEG/harness/run.sh \\
  --state $LEG/state
EOF
_out="$(run_tool "$TOOL" --apply)"; _rc=$?
[ "$_rc" = 0 ] && ok "d17 a unit with a continued directive converges (rc 0)" || bad "d17 the continued unit exited $_rc"
case "$(cat "$UNITS/app.service")" in
  *"--state $LEG/state"*) bad "d18 the CONTINUATION still names the legacy home — the file was half-written while --apply reported success" ;;
  *"--state $DUR/state"*) ok "d18 …and the CONTINUATION is repointed too (the writer agrees with the scanner)" ;;
  *) bad "d18 the continuation was neither repointed nor left as it was" ;;
esac
run_tool "$TOOL" --check >/dev/null 2>&1 && ok "d19 …and the follow-up --check is green (the tool does not cite its own partial write as the operator's defect)" \
  || bad "d19 the follow-up --check is not green after a continued-directive migration"

# ⛔ A SIBLING NAME IS NOT THIS HOME (review P2): `/tmp/cell-home.bak` is a pre-migration ARCHIVE, and a
# naive replace projected it to `<durable>.bak` — a target nobody has — so `--apply` refused the whole
# unit and named a FABRICATED path. The arm asserts the sibling survives BYTE FOR BYTE.
mk_box "$T/sib"
cat >>"$UNITS/app.service" <<EOF
Environment=ARCHIVE=$LEG.bak
EOF
_out="$(run_tool "$TOOL" --apply)"; _rc=$?
[ "$_rc" = 0 ] && ok "d20 a unit carrying a SIBLING name ($LEG.bak) still converges (rc 0)" || bad "d20 the sibling-name unit exited $_rc"
case "$(cat "$UNITS/app.service")" in
  *"Environment=ARCHIVE=$LEG.bak"*) ok "d21 …and the sibling path is left EXACTLY as it was (only a whole path component moves)" ;;
  *) bad "d21 the sibling path was re-based (fabricated target: $(grep ARCHIVE "$UNITS/app.service" || true))" ;;
esac

# ⛔ A `;` LINE IS THE OTHER COMMENT SPELLING (review F4). `systemd.syntax(7)`: "Empty lines and lines
# beginning with `#` or `;` are ignored as comments." The scanner knew only `#`, so a unit whose measured
# history sat behind `;` produced an UNHANDLED record — refused by name by `--apply`, and the box could
# NEVER read `--check` -> 0 (the reclaim precondition) while its only "defect" was a comment. That is a
# false block on a real box, and the tool's own header predicts the class for `#`.
mk_box "$T/semi"
run_tool "$TOOL" --apply >/dev/null 2>&1          # converge everything first
printf '; legacy note: this used to exec %s/harness/run.sh\n' "$LEG" >>"$UNITS/app.service"
_out="$(run_tool "$TOOL" --check)"; _rc=$?
[ "$_rc" = 0 ] && ok "d22 a unit whose ONLY mention of the legacy home is a ';' comment reads converged (--check 0)" \
  || bad "d22 a ';' comment was graded as a directive (--check $_rc) — such a unit can never reach one home"
case "$_out" in
  *UNHANDLED*) bad "d22b …and the ';' line is still reported as an un-rebasable directive" ;;
  *) ok "d22b …and no UNHANDLED record is raised for it" ;;
esac

# ⛔ A PATH COMPONENT ENDS AT ANY SEPARATOR, NOT ONLY AT `/` (review F1). The projector treated every
# non-`/` tail as a continuation of the filename, so `Environment="HOME=<legacy>"` (systemd removes the
# quotes: the value really is the legacy home) and `ReadWritePaths=<legacy> <durable>/state` (a
# space-separated list) read as SIBLINGS. `--check` answered 0 — the RECLAIM precondition — over units
# that still named the legacy home, and `--apply` printed "one home" over a file it had half-written.
mk_box "$T/sep"; mkdir -p "$DUR/state"
run_tool "$TOOL" --apply >/dev/null 2>&1              # converge the box first
cat >>"$UNITS/app.service" <<EOF
Environment="HOME=$LEG"
ReadWritePaths=$LEG $DUR/state
EOF
_out="$(run_tool "$TOOL" --check)"; _rc=$?
[ "$_rc" = 1 ] && ok "d23 a QUOTED legacy path and a space-separated path list are DRIFT (--check 1, not a false one home)" \
  || bad "d23 --check answered $_rc over a unit whose quoted/space-separated legacy paths were never moved"
_out="$(run_tool "$TOOL" --apply)"; _rc=$?
if grep -q "Environment=\"HOME=$DUR\"" "$UNITS/app.service" && grep -q "ReadWritePaths=$DUR $DUR/state" "$UNITS/app.service"; then
  ok "d24 …and --apply re-bases BOTH shapes (rc $_rc), so nothing names the legacy home afterwards"
else
  bad "d24 --apply left a legacy path in place: $(grep -E 'Environment="HOME=|ReadWritePaths=' "$UNITS/app.service" | tr '\n' ' ')"
fi

# ⛔ `mk_box` PLANTS `export HOME=$DUR` IN BOTH `keys.env` FILES, AND THE DERIVATION ARMS BELOW STUB THEIR
# PASSWD HOME UNDER `$T` — see the note beside `run_tool`: that is the authoritative answer, not a guess,
# so it is what the resolver returns and what these arms grade.

printf '\n── (i) THE DERIVATION: the account the UNITS RUN AS, not the invoker (review F2) ────────\n'
# ⛔ THE DANGEROUS WRITE. `sudo` re-sets HOME to the target account's home and drops an ambient
# CELL_HOME (`env_reset`), so the remedy this tool used to print — `sudo -n bash $0 --apply` — derived
# /root: it created a THIRD home there with the cell's credentials in it and repointed every
# `Environment=`-only directive (the commonest shape of all) to it, then reported "one home". The tool
# must now REFUSE to derive from a privileged invoker. `id` is stubbed, so the arm grades the guard and
# not the account running the suite.
STUBROOT="$T/stubroot"; mkdir -p "$STUBROOT"
printf '#!/bin/sh\ncase "$1" in -u) echo 0 ;; -un) echo root ;; *) exit 1 ;; esac\n' >"$STUBROOT/id"; chmod +x "$STUBROOT/id"
mk_box "$T/root"
# ⛔ `env -u CELL_HOME` IS PART OF THE ARM: on a real cell this suite itself runs with CELL_HOME
# exported, and an inherited CELL_HOME is an EXPLICIT home — the guard is about GUESSING it. Without
# the unset this arm would grade the host's env and pass for the wrong reason.
_out="$(env -u CELL_HOME PATH="$STUBROOT:$PATH" CELL_HOME_LEGACY="$LEG" CELL_HOME_MIGRATE_UNIT_DIRS="$UNITS" \
        CELL_HOME_MIGRATE_NO_RELOAD=1 bash "$TOOL" --apply 2>&1)"; _rc=$?
[ "$_rc" = 3 ] && ok "i1 a PRIVILEGED invoker with no explicit CELL_HOME is refused (rc 3, CANNOT MEASURE — never a repoint into /root)" \
  || bad "i1 a privileged invoker exited $_rc instead of refusing the derivation"
case "$_out" in *"REFUSED"*"CELL_HOME="*) ok "i2 …and the refusal names the explicit-CELL_HOME remedy (so a bare sudo cannot derive /root again)" ;; *) bad "i2 the refusal does not name the explicit-home remedy" ;; esac
case "$(cat "$UNITS/app.service")" in *"$DUR"*) bad "i3 the refused run WROTE the unit anyway" ;; *) ok "i3 …and nothing was written to the units" ;; esac

# The second half: units that declare an account which does not live in the derived home. HERE the
# derivation IS possible (a passwd record answers) and it is WRONG for these units, which is the same
# defect one step quieter.
STUBACCT="$T/stubacct"; mkdir -p "$STUBACCT" "$T/realhome" "$T/otherhome"
printf '#!/bin/sh\ncase "$1" in -u) echo 1000 ;; -un) echo cmux ;; *) exit 1 ;; esac\n' >"$STUBACCT/id"
printf '#!/bin/sh\ncase "$1" in passwd) case "$2" in cmux) echo "cmux:x:1000:1000::%s:/bin/bash" ;; ubuntu) echo "ubuntu:x:1001:1001::%s:/bin/bash" ;; esac ;; esac\n' "$T/realhome" "$T/otherhome" >"$STUBACCT/getent"
chmod +x "$STUBACCT/id" "$STUBACCT/getent"
mk_box "$T/acct"
sed -i.bak 's/^User=.*/User=ubuntu/' "$UNITS/app.service" && rm -f "$UNITS/app.service.bak"
_out="$(env -u CELL_HOME PATH="$STUBACCT:$PATH" CELL_HOME_LEGACY="$LEG" CELL_HOME_MIGRATE_UNIT_DIRS="$UNITS" \
        CELL_HOME_MIGRATE_NO_RELOAD=1 bash "$TOOL" --check 2>&1)"; _rc=$?
[ "$_rc" = 3 ] && ok "i4 units that declare an account which does NOT live in the derived home -> refused (rc 3)" \
  || bad "i4 a home that is not the units' account home was accepted (rc $_rc)"
case "$_out" in *"not the home of the account the units this tool grades run as"*) ok "i5 …naming the conflict, so the operator knows which home to pass" ;; *) bad "i5 the conflict is not named" ;; esac
# …and the SAME box converges when the operator names the home (an explicit CELL_HOME is always honoured).
env -u CELL_HOME PATH="$STUBACCT:$PATH" CELL_HOME="$T/otherhome" CELL_HOME_LEGACY="$LEG" CELL_HOME_MIGRATE_UNIT_DIRS="$UNITS" \
  CELL_HOME_MIGRATE_NO_RELOAD=1 bash "$TOOL" --check >/dev/null 2>&1
[ "$?" != 3 ] && ok "i6 …while an explicit CELL_HOME for that account is honoured (not refused)" \
  || bad "i6 an explicit CELL_HOME was refused too — the guard would block the sanctioned fix"

# ⛔ AN UNREADABLE POPULATION IS NOT "THE UNITS DECLARE NO OTHER ACCOUNT" (review F3). `unit_users`
# silenced its own `find`/`awk` errors, so a unit dir this account cannot walk contributed NO `User=` —
# which `check_derivation` reads as "no conflicting account". The derivation was then ACCEPTED and the
# credential half — which `main` runs BEFORE the unit half — wrote the cell's secrets into a home the
# units were never verified to run in. That is the THIRD-home write the guard exists to prevent, reached
# by a read that was never taken.
mk_box "$T/acct2"
sed -i.bak 's/^User=.*/User=ubuntu/' "$UNITS/app.service" && rm -f "$UNITS/app.service.bak"
rm -f "$DUR/keys.env"                                  # so a copy would be observable
chmod 000 "$UNITS"
if ls "$UNITS" >/dev/null 2>&1; then
  ok "i7 SKIPS honestly: this account can read a mode-000 unit dir, so the fixture cannot be made unreadable"
  ok "i8 (same skip)"
else
  # ⛔ WITH NO EXPLICIT CELL_HOME THE HOME IS DERIVED, so the fixture must know WHICH home that is: the
  # `getent`/`id` stubs answer `$T/realhome` for `cmux` (the same shim i4 uses). Asserting on `$DUR`
  # would look green while the tool wrote somewhere else — the shape of a vacuous arm.
  rm -f "$T/realhome/keys.env" "$T/realhome/.pi/agent/auth.json"
  _out="$(env -u CELL_HOME PATH="$STUBACCT:$PATH" CELL_HOME_LEGACY="$LEG" CELL_HOME_MIGRATE_UNIT_DIRS="$UNITS" \
          CELL_HOME_MIGRATE_NO_RELOAD=1 bash "$TOOL" --apply 2>&1)"; _rc=$?
  [ "$_rc" = 3 ] && ok "i7 an UNWALKABLE unit dir is refused BEFORE any write (rc 3, not an accepted derivation)" \
    || bad "i7 the derivation was accepted over a population it could not walk (rc $_rc)"
  # ⛔ EITHER CREDENTIAL COUNTS: `keys.env` can also be refused on content (it names the OTHER home), so
  # the copy this arm must see blocked is the one no content rule can stall — `auth.json`.
  [ ! -e "$T/realhome/keys.env" ] && [ ! -e "$T/realhome/.pi/agent/auth.json" ] \
    && ok "i8 …and NO credential was written into the DERIVED home ($T/realhome) whose account could not be verified" \
    || bad "i8 a credential was written into the derived home before the population was known to be measurable"
fi
chmod 755 "$UNITS" 2>/dev/null

printf '\n── (i-2) THE DERIVATION GRADES THE UNITS IT WOULD REPOINT, NOT EVERY UNIT systemd LOADS ────\n'
# ⛔ THE FALSE BLOCK THIS SECTION EXISTS FOR (review F1, measured on a live cell). `systemctl enable`
# installs an `/etc` SYMLINK to a vendor unit's definition, and `unit_files` grades symlinks ON PURPOSE
# (a `systemctl link`ed unit is real drift) — so on an ordinary Ubuntu/Debian cell the graded population
# contains `dbus-org.freedesktop.resolve1.service` (User=systemd-resolve, home `/`),
# `dbus-org.freedesktop.timesync1.service` (User=systemd-timesync, home `/`) and
# `cmux-resource-stats.service` (User=nobody, home `/nonexistent`). Reading `User=` from the WHOLE
# population put those three accounts in the conflict list of a box that was ALREADY CONVERGED, so
# `check_derivation` answered 3 for BOTH verbs: `--check` could never reach 0 (this PR's own acceptance
# criterion #1 and the RECLAIM precondition) and `--apply` never reached a credential copy or a unit
# write — the migration did not run on the box it targets.
# ⛔ NO ARM COULD SEE IT: every arm above pins the population through the seam to units that declare
# `User=cmux`/`User=root` (and i4 plants `User=ubuntu` on a unit the tool WOULD repoint), while a Mac has
# no `/etc/systemd/system` at all — so the scope defect was invisible on both hosts.
vend_stub() { # <dir> <cmux-home> — `id`/`getent` for a box whose population contains VENDOR units
  mkdir -p "$1"
  printf '#!/bin/sh\ncase "$1" in -u) echo 1000 ;; -un) echo cmux ;; *) exit 1 ;; esac\n' >"$1/id"
  # ⛔ THE VENDOR ACCOUNTS' HOMES ARE THE MEASURED ONES AND THEY MUST STAY UNREAL (review F1 round 3):
  # `systemd-resolve`/`systemd-timesync` answer `/` and `nobody` answers `/nonexistent`, which is what
  # makes them excludable BY ACCOUNT (`is_cell_home`) instead of by unit. The cell account's home is the
  # durable home the arm asserts on.
  # ⛔ AND `ubuntu`'s HOME MUST **EXIST** (review F1 round 3): the surviving conflict is "an account the
  # units run as whose passwd home is a REAL, DIFFERENT directory", and a non-existent home is not a
  # conflict any more. With `/home/ubuntu` this arm would pass for the wrong reason on a host without
  # that path — it would be excluded, not graded — so the fixture OWNS the directory.
  mkdir -p "$1/otherhome"
  printf '#!/bin/sh\ncase "$1:$2" in\n  passwd:cmux) echo "cmux:x:1000:1000::%s:/bin/bash" ;;\n  passwd:ubuntu) echo "ubuntu:x:1001:1001::%s:/bin/bash" ;;\n  passwd:nobody) echo "nobody:x:65534:65534::/nonexistent:/usr/sbin/nologin" ;;\n  passwd:systemd-resolve) echo "systemd-resolve:x:991:991::/:/usr/sbin/nologin" ;;\nesac\n' "$2" "$1/otherhome" >"$1/getent"
  chmod +x "$1/id" "$1/getent"
}
# plant_vendor <units-dir> <target-dir> — the two shapes an enabled vendor unit really takes: a stray
# definition and a `systemctl enable` ALIAS (a symlink) to a definition living outside the unit dir.
plant_vendor() {
  mkdir -p "$2"
  printf '[Service]\nUser=nobody\nExecStart=/usr/bin/cmux-resource-stats\n' >"$1/cmux-resource-stats.service"
  printf '[Service]\nUser=systemd-resolve\n' >"$2/resolved.service"
  ln -s "$2/resolved.service" "$1/dbus-org.freedesktop.resolve1.service"
}
# The positive control first: on the SAME box with the SAME homes and credentials, the vendor
# population they measured is present and the box still converges.
mk_box "$T/vend"
plant_vendor "$UNITS" "$T/vend/vendor"
VSTUB="$T/vstub"; vend_stub "$VSTUB" "$DUR"
# ⛔ THE DERIVED HOME IS THE ONE THE STUB ANSWERS, so every assertion below names `$DUR` and not a guess.
_out="$(env -u CELL_HOME PATH="$VSTUB:$PATH" CELL_HOME_LEGACY="$LEG" CELL_HOME_MIGRATE_UNIT_DIRS="$UNITS" \
        CELL_HOME_MIGRATE_NO_RELOAD=1 bash "$TOOL" --apply 2>&1)"; _rc=$?
[ "$_rc" = 0 ] && ok "i9 a CONVERGED population that carries a vendor unit + its enable alias is not refused (--apply rc 0, was 3)" \
  || bad "i9 the derivation was refused over a vendor unit the tool would never repoint (rc $_rc)"
case "$(cat "$UNITS/app.service")" in
  *"$DUR"*) ok "i10 …and the migration WIRED: the cell's own unit was repointed onto the derived home" ;;
  *) bad "i10 nothing was repointed — the guard refused before the first write" ;;
esac
_out="$(env -u CELL_HOME PATH="$VSTUB:$PATH" CELL_HOME_LEGACY="$LEG" CELL_HOME_MIGRATE_UNIT_DIRS="$UNITS" \
        CELL_HOME_MIGRATE_NO_RELOAD=1 bash "$TOOL" --check 2>&1)"; _rc=$?
[ "$_rc" = 0 ] && ok "i11 …and --check answers 0 on that box, so the RECLAIM precondition is reachable again" \
  || bad "i11 --check answered $_rc on a converged cell that carries a vendor unit — the precondition is unreachable"
# ⛔ AND THE RULE SURVIVES: the population was NARROWED, not deleted. The SAME vendor population plus one
# unit the tool WOULD repoint that declares a foreign-home account is still refused by name.
mk_box "$T/vend2"
plant_vendor "$UNITS" "$T/vend2/vendor"
sed -i.bak 's/^User=.*/User=ubuntu/' "$UNITS/app.service" && rm -f "$UNITS/app.service.bak"
VSTUB2="$T/vstub2"; vend_stub "$VSTUB2" "$DUR"
_out="$(env -u CELL_HOME PATH="$VSTUB2:$PATH" CELL_HOME_LEGACY="$LEG" CELL_HOME_MIGRATE_UNIT_DIRS="$UNITS" \
        CELL_HOME_MIGRATE_NO_RELOAD=1 bash "$TOOL" --check 2>&1)"; _rc=$?
[ "$_rc" = 3 ] && ok "i12 …while a unit this tool WOULD repoint that declares a foreign-home account is STILL refused (rc 3)" \
  || bad "i12 a repoint onto a home the unit does not run in was accepted (rc $_rc) — the rule was deleted, not scoped"
case "$_out" in *ubuntu*) ok "i13 …and the refusal still names the account whose home conflicts" ;; *) bad "i13 the conflict account is not named" ;; esac

printf '\n── (i-3) THE GUARD IS NOT VACUOUS ON A CONVERGED BOX (review F1 round 3) ─────────────\n'
# ⛔ THE STATE THAT SILENCED THE GUARD. The round-2 fix graded `User=` from the files whose scan still
# yields a record — i.e. the files this tool WOULD REPOINT — and that set is EMPTY on a converged box,
# which is exactly what `--apply` produces. So on a converged box `check_derivation` returned 0 for ANY
# derived home the invoking account's passwd record answers (bar a root invoker and a home that does not
# exist), and `main` runs the CREDENTIAL half FIRST: `--apply` copied `keys.env` and
# `.pi/agent/auth.json` into a THIRD home, printed `VERDICT: one home` and exited 0 — and a follow-up
# `--check` then read 0 as well, because the durable side now held the copies. That 0 is the stated
# precondition for reclaiming the legacy home, so the tool could move the only copy of the cell's
# credentials to an account the units do not run as and then authorise deleting the source.
# ⛔ THE SHAPE THE PREVIOUS REVIEW MEASURED, and the one no arm produced: units CONVERGED, and a
# derivation that is NOT their account home. `$CEL/units` never mentions the legacy home after the
# convergence step below, so the repoint set is empty by construction — asserted, not assumed (i15).
CEL="$T/converged"
mk_box "$CEL"
run_tool "$TOOL" --apply >/dev/null 2>&1                # converge the units (explicit CELL_HOME)
# ⛔ THE FIXTURE'S OWN PREMISE, asserted before the arms that depend on it: the box really is converged,
# so "nothing would be repointed" is a reading and not this suite's hope. It must be asserted BEFORE the
# durable credentials are removed below — a missing durable credential is drift, and the arm would then
# be measuring that instead of the population.
_out="$(run_tool "$TOOL" --check)"; _rc=$?
[ "$_rc" = 0 ] && ok "i14 the fixture premise: the units are CONVERGED before the derivation arms run (--check 0) — so no file would be repointed" \
  || bad "i14 the fixture is not converged (--check $_rc), so the vacuity arms below would prove nothing"
rm -f "$DUR/keys.env" "$DUR/.pi/agent/auth.json"       # …and leave the durable side MISSING them again
mkdir -p "$CEL/inv-home"                                # the invoker's real, DIFFERENT home
# The invoker is `ubuntu` (home `$CEL/inv-home`); the units run as `cmux` (home `$DUR`).
mkdir -p "$CEL/stub"
printf '#!/bin/sh\ncase "$1" in -u) echo 1001 ;; -un) echo ubuntu ;; *) exit 1 ;; esac\n' >"$CEL/stub/id"
printf '#!/bin/sh\ncase "$1:$2" in\n  passwd:cmux) echo "cmux:x:1000:1000::%s:/bin/bash" ;;\n  passwd:ubuntu) echo "ubuntu:x:1001:1001::%s:/bin/bash" ;;\nesac\n' "$DUR" "$CEL/inv-home" >"$CEL/stub/getent"
chmod +x "$CEL/stub/id" "$CEL/stub/getent"
_out="$(env -u CELL_HOME PATH="$CEL/stub:$PATH" CELL_HOME_LEGACY="$LEG" CELL_HOME_MIGRATE_UNIT_DIRS="$UNITS" \
        CELL_HOME_MIGRATE_NO_RELOAD=1 bash "$TOOL" --apply 2>&1)"; _rc=$?
[ "$_rc" = 3 ] && ok "i15 a CONVERGED box + a derivation that is NOT the units' account home is REFUSED (rc 3, not an accepted third home)" \
  || bad "i15 the derivation guard was vacuous on a converged box (rc $_rc) — the credential half then acts on a home the units do not run in"
case "$_out" in *"cmux($DUR)"*) ok "i16 …and the refusal names the units' account and its real home" ;; *) bad "i16 the refusal does not name the account the units run as (rc $_rc): $_out" ;; esac
if [ ! -e "$CEL/inv-home/keys.env" ] && [ ! -e "$CEL/inv-home/.pi/agent/auth.json" ]; then
  ok "i17 …and NO credential was copied into the derived third home, so the secret never left the cell account"
else
  bad "i17 the credential half wrote the cell's secrets into $CEL/inv-home BEFORE the derivation was refused"
fi
case "$_out" in *"one home"*) bad "i17b the refused run still reported 'one home'";; *) ok "i17b …and the run did not report the RECLAIM verdict it did not earn" ;; esac
# The control: the SAME box converges when the operator NAMES the home — the guard is about GUESSING it.
env -u CELL_HOME PATH="$CEL/stub:$PATH" CELL_HOME="$DUR" CELL_HOME_LEGACY="$LEG" CELL_HOME_MIGRATE_UNIT_DIRS="$UNITS" \
  CELL_HOME_MIGRATE_NO_RELOAD=1 bash "$TOOL" --apply >/dev/null 2>&1; _rc=$?
[ "$_rc" = 0 ] && [ -e "$DUR/.pi/agent/auth.json" ] \
  && ok "i18 …while an EXPLICIT CELL_HOME for that account is honoured (rc 0, credentials restored) — the guard is a scope, not a deletion" \
  || bad "i18 the sanctioned explicit-CELL_HOME path was refused too (rc $_rc) — the guard would block the fix it documents"

printf '\n── (j) THE CREDENTIAL THAT IS ALSO A PROGRAM (review F3/P1) ─────────────────────────────\n'

# `keys.env` is SOURCED by the processes this migration converges, so a `HOME=`/`CELL_HOME=` assignment in
# it re-selects the home of every lane that reads it — including one that puts them back in the legacy
# home. Rule 3 forbids printing a VALUE, so the tool reports the NAME only, and it refuses to COPY a
# poisoned file rather than installing it.
POISON="sk-CELLHOME-ENVVAL-3453"
mk_box "$T/env1"
printf 'export CELL_HOME=%s\nDEEPSEEK_API_KEY=%s\n' "$LEG" "$POISON" >"$DUR/keys.env"; chmod 600 "$DUR/keys.env"
_out="$(run_tool "$TOOL" --check)"; _rc=$?
[ "$_rc" = 1 ] && ok "j1 a durable keys.env whose ASSIGNMENT re-points CELL_HOME at the legacy home -> --check is 1" \
  || bad "j1 a re-pointing durable keys.env read as converged (rc $_rc)"
case "$_out" in *"ASSIGNS CELL_HOME"*) ok "j2 …naming the VARIABLE that re-points the home" ;; *) bad "j2 the re-pointing assignment is not reported" ;; esac
case "$_out" in *"$POISON"*) bad "j2b the report printed the assignment's VALUE (rule 3)" ;; *) ok "j2b …and the value never appears in the output (rule 3 holds for the content leg)" ;; esac

# The copy leg: the durable side is MISSING, so `--apply` would install the legacy file — including its
# assignment. It must refuse, and leave the durable side MISSING (a missing credential a lane reports is
# safer than one that silently moves every lane back).
mk_box "$T/env2"
rm -f "$DUR/keys.env"
printf 'export HOME=%s\nexport CELL_HOME=%s\nDEEPSEEK_API_KEY=%s\n' "$LEG" "$LEG" "$POISON" >"$LEG/keys.env"; chmod 600 "$LEG/keys.env"
_out="$(run_tool "$TOOL" --apply)"; _rc=$?
[ "$_rc" = 1 ] && ok "j3 --apply REFUSES to copy a legacy keys.env that re-points the home (rc 1)" || bad "j3 the poisoned copy exited $_rc"
[ ! -e "$DUR/keys.env" ] && ok "j4 …and the durable side is left MISSING rather than installed poisoned" \
  || bad "j4 the poisoned keys.env was installed in the durable home"
case "$_out" in *"$POISON"*) bad "j4b the refusal printed a credential value (rule 3)" ;; *) ok "j4b …and the refusal prints no credential value" ;; esac
# …while a clean keys.env still copies (the polarity: the refusal is about the CONTENT, not the file).
mk_box "$T/env3"
rm -f "$DUR/keys.env"
_out="$(run_tool "$TOOL" --apply)"; _rc=$?
if [ -f "$DUR/keys.env" ]; then ok "j5 a keys.env that names the DURABLE home is copied (the refusal is content, not the filename)"; else bad "j5 a clean keys.env was not copied (rc $_rc)"; fi

# ⛔ THE CONTENT LEG IS INDEPENDENT OF THE LEGACY SIDE. The legacy home is reclaimed LATER, so a durable
# `keys.env` that re-points the home must still be drift after the legacy copy is gone — otherwise the
# report disappears exactly when the operator cleans up, and both modes would read "one home" over a
# box whose every lane is back in the second home.
mk_box "$T/env4"
printf 'export CELL_HOME=%s\nDEEPSEEK_API_KEY=%s\n' "$LEG" "$POISON" >"$DUR/keys.env"; chmod 600 "$DUR/keys.env"
rm -f "$LEG/keys.env"
[ -e "$LEG/keys.env" ] && bad "j6 fixture: the legacy copy is still there" || ok "j6 fixture: the legacy keys.env is gone, the durable one is poisoned"
run_tool "$TOOL" --check >/dev/null 2>&1; _rc=$?
[ "$_rc" = 1 ] && ok "j7 …--check is STILL 1 with no legacy copy left (the check did not go quiet with the legacy home)" \
  || bad "j7 the durable re-pointing went unreported once the legacy copy was removed (rc $_rc)"
_out="$(run_tool "$TOOL" --apply)"; _rc=$?
[ "$_rc" = 1 ] && ok "j8 …and --apply does not report convergence over it either (the two modes agree)" \
  || bad "j8 --apply answered $_rc while --check answers 1 on the same box"

# ⛔ AN UNREADABLE DURABLE `keys.env` IS NOT "NAMES NO VOLATILE HOME" (review F2).
# `volatile_home_assignments` starts with `[ -r "$f" ] || return 0`, so a file this account cannot read
# printed NOTHING — which is indistinguishable from a converged one. A durable `keys.env` that
# re-pointed HOME/CELL_HOME at the legacy home therefore read as clean: `--check` answered 0 (the
# RECLAIM precondition) and `--apply` reported the poisoned copy as "kept". `[ -r ]` is also permission
# BITS rather than a reading (`probe_open` is the open), so the same arm holds for root.
mk_box "$T/env5"
printf 'export CELL_HOME=%s\nDEEPSEEK_API_KEY=%s\n' "$LEG" "$POISON" >"$DUR/keys.env"; chmod 000 "$DUR/keys.env"
if ( : <"$DUR/keys.env" ) 2>/dev/null; then
  ok "j9 SKIPS honestly: this account can open a mode-000 file, so the fixture cannot be made unreadable"
  ok "j10 (same skip)"
else
  _out="$(run_tool "$TOOL" --check)"; _rc=$?
  [ "$_rc" = 3 ] && ok "j9 a durable keys.env this account cannot OPEN is CANNOT MEASURE (3), never 'one home'" \
    || bad "j9 an unreadable durable keys.env read as converged (rc $_rc) — a false PASS on the reclaim precondition"
  case "$_out" in *"CANNOT MEASURE"*"keys.env"*) ok "j10 …and the report names the file it could not read" ;; *) bad "j10 the unreadable env file is not named" ;; esac
fi
chmod 600 "$DUR/keys.env" 2>/dev/null

printf '\n── (k) CANNOT MEASURE IS NOT A VERDICT (review F1/F2) ───────────────────────────────\n'
# ⛔ THE FALSE PASS THIS SECTION EXISTS FOR. `--check` -> 0 is the stated precondition for RECLAIMING the
# legacy home, so a PASS manufactured from a reading that was never taken tells an operator to delete the
# only copy of something. Three ways a read goes missing, all of them silent before this change:
#   * the file cannot be OPENED (`grep -q … || continue` gave EACCES the same exit as "no match", and
#     `done < "$f"` produced no record at all);
#   * the population cannot be WALKED (find's stderr was thrown away, so a `.service.d` dir this account
#     cannot read contributed no file and the dir read as "clear of the legacy home");
#   * a legacy credential path cannot be STATed (`[ ! -e ]` is the same answer for "gone" and "denied").
# The header's exit table already reserved 3 for exactly this class: "Never 0: 'could not read' is not
# 'one home'." These arms take it at its word.

# ⛔ THIS IS THE REVIEWER'S REPRODUCTION, not an approximation of it: a box that is ALREADY on one home
# in every other respect, plus ONE unit that names the legacy home and that this account cannot open —
# the shape of a root-owned unit carrying a secret in `Environment=`, graded by a `--check` run as the
# cell account. Nothing else on the box drifts, so the ONLY thing between it and `--check` -> 0 (the
# reclaim precondition) is the file that was never read.
HIDDEN_BEFORE=""
mk_hidden_box() { # <dir>
  mk_box "$1"
  run_tool "$TOOL" --apply >/dev/null 2>&1        # converge everything else
  printf '[Service]\nEnvironment=HOME=%s\nExecStart=%s/harness/run.sh\n' "$LEG" "$LEG" >"$UNITS/hidden.service"
  HIDDEN_BEFORE="$(cat "$UNITS/hidden.service")"
  chmod 000 "$UNITS/hidden.service"
}

mk_hidden_box "$T/k1"
# ⛔ A REAL OPEN IS THE HONEST PROBE, because `[ -r ]` reads permission BITS: an account holding
# DAC_OVERRIDE (root) CAN open a mode-000 file, so only a real open answers "can this identity measure
# it". Where the fixture cannot be blind to us, the leg says so instead of asserting nothing.
if ( : <"$UNITS/hidden.service" ) 2>/dev/null; then
  ok "k1 SKIPS the unreadable-unit legs honestly: this suite runs as an account that can open a mode-000 file, so the fixture cannot be unreadable to it"
else
  _out="$(run_tool "$TOOL" --check)"; _rc=$?
  [ "$_rc" = 3 ] && ok "k1 a unit this account cannot OPEN -> --check is 3 (CANNOT MEASURE)" \
    || bad "k1 --check answered $_rc over a unit it never read (0 = a PASS manufactured from an unread reading, 1 = misreported as ordinary drift)"
  case "$_out" in *"CANNOT MEASURE"*"hidden.service"*) ok "k2 …naming the file whose reading could not be taken" ;; *) bad "k2 the unmeasurable unit is not named" ;; esac
  case "$_out" in *"VERDICT: one home"*) bad "k3 the unreadable unit still produced 'VERDICT: one home' — the reclaim precondition would read as met" ;; *) ok "k3 …and it never answers 'one home' over a file it did not read" ;; esac
  _out="$(run_tool "$TOOL" --apply)"; _rc=$?
  [ "$_rc" = 3 ] && ok "k4 --apply is 3 over the same unit (it can be neither repointed nor ruled out)" \
    || bad "k4 --apply answered $_rc over a unit it never read"
  chmod 644 "$UNITS/hidden.service"
  [ "$HIDDEN_BEFORE" = "$(cat "$UNITS/hidden.service")" ] && ok "k5 …and the file was left BYTE-FOR-BYTE intact" \
    || bad "k5 the run modified a unit it could not read"
fi
chmod 644 "$UNITS/hidden.service" 2>/dev/null

# The population leg: a drop-in DIR this account cannot walk used to contribute no file at all.
mk_box "$T/k6"
chmod 000 "$UNITS/app.service.d"
if ( : <"$UNITS/app.service.d/env.conf" ) 2>/dev/null; then
  ok "k6 SKIPS the un-walkable drop-in dir leg honestly: this account can open a file inside a mode-000 dir"
else
  _out="$(run_tool "$TOOL" --check)"; _rc=$?
  [ "$_rc" = 3 ] && ok "k6 a drop-in dir this account cannot WALK -> --check is 3, not 'clear of the legacy home'" \
    || bad "k6 --check answered $_rc over a population it could not walk"
  case "$_out" in *"cannot be walked"*) ok "k7 …naming the population that could not be read" ;; *) bad "k7 the unwalkable population is not named" ;; esac
fi
chmod 755 "$UNITS/app.service.d" 2>/dev/null

# The credential leg: `[ ! -e "$f_leg" ]` read an unsearchable legacy HOME as "legacy MIA" — i.e. the
# credential half looked converged on a box where it was never looked at.
mk_box "$T/k8"
chmod 000 "$LEG"
if ( : <"$LEG/keys.env" ) 2>/dev/null; then
  ok "k8 SKIPS the unsearchable-legacy-home leg honestly: this account can read through a mode-000 dir"
else
  _out="$(run_tool "$TOOL" --check)"; _rc=$?
  [ "$_rc" = 3 ] && ok "k8 a legacy home this account cannot SEARCH -> --check is 3 (a denied stat is not 'legacy MIA')" \
    || bad "k8 --check answered $_rc while a legacy credential path could not be stat'ed"
  case "$_out" in *"CANNOT MEASURE"*"keys.env"*) ok "k9 …naming the credential path it could not look at" ;; *) bad "k9 the unmeasurable credential is not named" ;; esac
  case "$_out" in *"legacy MIA"*) bad "k9b …and it still reports the denied path as 'legacy MIA'" ;; *) ok "k9b …and it does NOT report the denied path as 'legacy MIA'" ;; esac
  # ⛔ AND THE GUARD MUST NOT SHORT-CIRCUIT THE DURABLE-SIDE CONTENT LEG. The durable `keys.env` is what
  # lanes SOURCE, so a re-pointing assignment in it is drift whether or not the legacy side can be seen
  # — the leg's own rule, stated one screen above it. A guard placed ABOVE that leg `continue`s past it
  # and stops grading the one file that can put every lane back into the second home; this arm is what
  # makes such a placement red instead of quietly "safer".
  printf 'export CELL_HOME=%s\n' "$LEG" >"$DUR/keys.env"; chmod 600 "$DUR/keys.env"
  _out="$(run_tool "$TOOL" --check)"
  case "$_out" in
    *"keys.env: the DURABLE copy ASSIGNS"*) ok "k9c …while the DURABLE-side content leg still runs (a poisoned keys.env is named even with the legacy side blind)" ;;
    *) bad "k9c the unmeasurable-legacy guard short-circuited the durable-side content leg" ;;
  esac
fi
chmod 755 "$LEG" 2>/dev/null

# ── F2: a continuation belongs to its LOGICAL line ────────────────────────────────────────────
# `systemd.syntax(7)`: "Lines ending in a backslash are concatenated with the following line … When a
# comment line or lines follow a line ending with a backslash, the comment block is ignored, so the
# continued line is concatenated with whatever follows the comment block." `d17` puts the legacy path in
# the ONLY continuation line, so it passes with the inherited name cleared on every non-hit line. These
# two fixtures are the shapes that cannot: an intermediate line that names no legacy path, and a comment
# between the continued lines.
mk_box "$T/k10"; mkdir -p "$DUR/state"
cat >"$UNITS/app.service" <<EOF
[Service]
Environment=HOME=$LEG
ExecStart=$LEG/harness/run.sh \\
  --flag \\
  --state $LEG/state
EOF
_out="$(run_tool "$TOOL" --apply)"; _rc=$?
[ "$_rc" = 0 ] && ok "k10 a continued directive whose MIDDLE line names no legacy path converges (rc 0)" \
  || bad "k10 the file was refused ($_rc) because the inherited directive name was dropped on the middle line"
case "$(cat "$UNITS/app.service")" in
  *"--state $DUR/state"*) ok "k11 …and its last continuation line IS repointed" ;;
  *) bad "k11 the last continuation line still carries the legacy path: $(grep -- '--state' "$UNITS/app.service" || true)" ;;
esac

mk_box "$T/k12"; mkdir -p "$DUR/state"
cat >"$UNITS/app.service" <<EOF
[Service]
Environment=HOME=$LEG
ExecStart=$LEG/harness/run.sh \\
# measured note naming $LEG/harness/run.sh must not be graded, and must not break the continuation either
  --state $LEG/state
EOF
_out="$(run_tool "$TOOL" --apply)"; _rc=$?
[ "$_rc" = 0 ] && ok "k12 a COMMENT between two continued lines does not break the continuation (rc 0)" \
  || bad "k12 the comment ended the logical line, so the file could never converge ($_rc)"
case "$(cat "$UNITS/app.service")" in
  *"--state $DUR/state"*) ok "k13 …and the line after the comment is repointed" ;;
  *) bad "k13 the continuation after the comment was not repointed" ;;
esac
grep -q "^# measured note naming $LEG/harness/run.sh" "$UNITS/app.service" \
  && ok "k14 …while the comment itself is copied VERBATIM (ignored in both directions)" \
  || bad "k14 the comment was rewritten or dropped"

# ── F4: the DIRECTIVE NAME comes from the logical line, not the line's first character ────────
# systemd accepts an INDENTED directive (measured with `systemd-analyze verify`, which reports an
# unknown key in that position and not the indentation), and a continuation may begin with a word that
# is not `--`. Deriving the name from the first character made both shapes UNHANDLED: refused forever by
# `--apply`, on a diagnostic that was FALSE ("a directive this tool does not re-base" about an
# `ExecStart=`/`Environment=` it demonstrably does). Same class as the `;`-comment false block.
mk_box "$T/ind"
cat >"$UNITS/ind.service" <<EOF
[Service]
   Environment=HOME=$LEG
EOF
cat >"$UNITS/word.service" <<EOF
[Service]
ExecStart=/bin/sh -c \\
cd $LEG
EOF
_out="$(run_tool "$TOOL" --apply)"; _rc=$?
[ "$_rc" = 0 ] && ok "k15 an INDENTED directive and a word-starting continuation converge (rc 0, no UNHANDLED record)" \
  || bad "k15 an indented directive / word-starting continuation was refused ($_rc) — --check could never reach 0"
grep -q "^   Environment=HOME=$DUR$" "$UNITS/ind.service" \
  && ok "k16 …and the indented directive is repointed, keeping its indentation" \
  || bad "k16 the indented directive was not repointed"
grep -q "^cd $DUR$" "$UNITS/word.service" \
  && ok "k16b …and so is the continuation line that begins with a word" \
  || bad "k16b the word-starting continuation still names the legacy home"

# ── F5: the GRADED POPULATION is the one systemd LOADS ─────────────────────────────────────
# The verdict asserts "none — every unit … is clear of the legacy home", so the population must not be
# `*.service|*.timer` AND `-type f` only: a `.socket` naming the legacy home, and a SYMLINKED unit
# (`systemctl link` installs units as symlinks) were both invisible and `--check` answered 0.
# ⛔ EACH FIXTURE IS CONVERGED FIRST: the default `mk_box` unit drifts, so without that every arm would
# redden for the wrong reason and none would measure the new population member.
mk_box "$T/pop"
run_tool "$TOOL" --apply >/dev/null 2>&1              # converge, so ONLY the .socket can drift
printf '[Socket]\nListenStream=%s/lane.sock\n' "$LEG" >"$UNITS/app.socket"
_out="$(run_tool "$TOOL" --check)"; _rc=$?
[ "$_rc" = 1 ] && ok "k17 a .socket whose ListenStream names the legacy home is DRIFT, not an invisible file" \
  || bad "k17 a .socket naming the legacy home was outside the population (--check $_rc)"
case "$_out" in *"app.socket"*) ok "k18 …and it is named in the report" ;; *) bad "k18 the .socket is not named" ;; esac

mk_box "$T/link"
run_tool "$TOOL" --apply >/dev/null 2>&1              # converge, so ONLY the link can drift
printf '[Service]\nEnvironment=HOME=%s\n' "$LEG" >"$T/link/target.service"
ln -s "$T/link/target.service" "$UNITS/linked.service"
run_tool "$TOOL" --check >/dev/null 2>&1; _rc=$?
[ "$_rc" = 1 ] && ok "k19 a SYMLINKED unit (systemctl link) is graded like any other (--check 1)" \
  || bad "k19 a symlinked unit was outside the population (--check $_rc)"
_out="$(run_tool "$TOOL" --apply)"; _rc=$?
case "$_out" in *symlink*) ok "k20 …and --apply REFUSES it by name instead of replacing the link with a file" ;; *) bad "k20 the writer did not call out the symlinked unit" ;; esac
[ -L "$UNITS/linked.service" ] && ok "k20b …so the link survives (systemctl link semantics preserved)" \
  || bad "k20b the writer replaced a symlink with a regular file"

# ── F1: a LAST LINE WITHOUT A TRAILING NEWLINE is still a line ──────────────────────────────
# `while IFS= read -r line` DROPS it, so a unit whose final directive carried the legacy home and had no
# trailing newline produced no record: `--check` answered 0 (the RECLAIM precondition) and `--apply`
# reported "one home" over a file it never rewrote. The writer already used the correct idiom, so this
# was also a scanner/writer disagreement.
mk_box "$T/nonl"
run_tool "$TOOL" --apply >/dev/null 2>&1              # converge the fixture, so only the last line can drift
printf 'Environment=PATH=/usr/bin\nEnvironment=HOME=%s' "$LEG" >>"$UNITS/app.service"   # NO trailing newline
run_tool "$TOOL" --check >/dev/null 2>&1; _rc=$?
[ "$_rc" = 1 ] && ok "k21 an UNTERMINATED last line naming the legacy home is DRIFT (--check 1, not a false one home)" \
  || bad "k21 the last line without a trailing newline was invisible to the scanner (--check $_rc)"
run_tool "$TOOL" --apply >/dev/null 2>&1; _rc=$?
case "$(cat "$UNITS/app.service")" in
  *"Environment=HOME=$DUR"*) ok "k21b …and --apply rewrites it (rc $_rc)" ;;
  *) bad "k21b the unterminated line was never rewritten" ;;
esac

# ── F3: systemd ignores whitespace around `=` ───────────────────────────────────────────────
# `systemd.syntax(7)`: "Whitespace immediately before or after the `=` is ignored"; `systemd-analyze
# verify` agrees. Keeping the blank in the derived name matched no known directive, so the line was
# graded UNHANDLED and refused forever — --check could never reach 0.
mk_box "$T/ws"
printf '[Service]\nEnvironment = HOME=%s\nExecStart = /bin/true\n' "$LEG" >"$UNITS/ws.service"
_out="$(run_tool "$TOOL" --apply)"; _rc=$?
[ "$_rc" = 0 ] && ok "k22 'Environment = HOME=<legacy>' (spaces around '=') converges (rc 0, no UNHANDLED record)" \
  || bad "k22 a directive with spaces around '=' was refused ($_rc) — --check could never reach 0"
grep -q "^Environment = HOME=$DUR$" "$UNITS/ws.service" \
  && ok "k22b …and the value is repointed, keeping the spacing" \
  || bad "k22b the spaced directive was not repointed"

# ── F4: enablement aliases are not definitions, and a dangling link names nothing ────────────
# `systemctl enable` writes `<target>.wants/<unit>` as a SYMLINK to a unit defined elsewhere. Grading it
# made the definition graded twice, and the writer (which refuses symlinks by name) then refused the
# alias while repointing its target — rc 1 forever, order-dependent on the unit's name.
mk_box "$T/alias"
run_tool "$TOOL" --apply >/dev/null 2>&1              # converge the fixture first
# ⛔ THE NAME DECIDES THE OUTCOME UNDER THE BUG, so the fixture uses one that SORTS AFTER the alias dir:
# the alias (`default.target.wants/zzz.service`) is then graded BEFORE its definition (`zzz.service`),
# which is the order that refused the alias while repointing the target.
printf '[Service]\nEnvironment=HOME=%s\n' "$LEG" >"$UNITS/zzz.service"
mkdir -p "$UNITS/default.target.wants"
ln -s "../zzz.service" "$UNITS/default.target.wants/zzz.service"
_out="$(run_tool "$TOOL" --apply)"; _rc=$?
[ "$_rc" = 0 ] && ok "k23 a <target>.wants/ enablement alias does not block --apply (rc 0; the definition is graded once)" \
  || bad "k23 the alias was refused ($_rc) while its target was repointed — --check would never reach 0"
case "$(cat "$UNITS/zzz.service")" in
  *"Environment=HOME=$DUR"*) ok "k23b …and the unit DEFINITION it points at is still repointed" ;;
  *) bad "k23b the definition was not repointed" ;;
esac
ln -s "../gone.service" "$UNITS/dangling.service"
_out="$(run_tool "$TOOL" --check)"; _rc=$?
[ "$_rc" = 0 ] && ok "k23c a DANGLING symlink is ABSENT, not CANNOT MEASURE (rc 0, no permanent exit 3)" \
  || bad "k23c a dangling symlink made every run read CANNOT MEASURE (rc $_rc) — only deleting the link would recover"

# ── F6: the DURABLE side needs the same three-valued read as the legacy side ─────────────────
# `[ -e "$f_dur" ]` answers "absent" for "I could not look", so with the legacy home already reclaimed
# (its credentials gone) `--check` reported every credential as `durable MISSING` and answered 0 — a PASS
# over credentials it never stat'ed, on the reclaim precondition.
mk_box "$T/dur"
run_tool "$TOOL" --apply >/dev/null 2>&1              # converge the UNITS first (they are not what this arm is about)
rm -f "$LEG/keys.env" "$LEG/.pi/agent/auth.json"      # the post-reclaim shape: legacy side empty
chmod 600 "$DUR"                                      # …and the durable home cannot be searched
# ⛔ THE GUARD MUST TEST TRAVERSAL, NOT LISTING: a mode-600 DIRECTORY still lets its owner READ the
# names (`ls` works) while denying SEARCH, so `[ -e "$DUR/keys.env" ]` is the reading that matters.
if ( : <"$DUR/keys.env" ) 2>/dev/null; then
  ok "k24 SKIPS honestly: this account can still reach an entry in a mode-600 durable home"
else
  _out="$(run_tool "$TOOL" --check)"; _rc=$?
  [ "$_rc" = 3 ] && ok "k24 an UNSEARCHABLE durable home is CANNOT MEASURE (3), never 'one home' over unread credentials" \
    || bad "k24 an unsearchable durable home read as converged (rc $_rc)"
fi
chmod 755 "$DUR" 2>/dev/null

# ── F5: a FOREIGN prefix and a filename continuation are NOT this home ──────────────────────
mk_box "$T/anchor"
run_tool "$TOOL" --apply >/dev/null 2>&1              # converge, so anything reported below is the new line
printf 'Environment=TOOLDIR=/opt/tools%s/bin\nEnvironment=ARCH=%s~\n' "$LEG" "$LEG" >>"$UNITS/app.service"
_out="$(run_tool "$TOOL" --check)"; _rc=$?
[ "$_rc" = 0 ] && ok "k25 a foreign prefix (/opt/tools<legacy>/bin) and a sibling continuation (<legacy>~) are NOT ours (--check 0)" \
  || bad "k25 the projector claimed a foreign path or a sibling continuation as the legacy home (rc $_rc)"
grep -q "TOOLDIR=/opt/tools$LEG/bin" "$UNITS/app.service" \
  && ok "k25b …and --apply left both BYTE FOR BYTE" \
  || bad "k25b --apply rewrote a foreign prefix or a sibling continuation"

# ── F1 (round 3): the systemd EXEC PREFIXES belong to the token ────────────────────────────
# `systemd.service(5)` Table 2: `@`, `-`, `:`, `+`, `!` may prefix an executable path, in any order;
# `-` is also a per-item prefix for `WorkingDirectory=`/`EnvironmentFile=`/`ReadWritePaths=`. Without
# them in the START set the line produced NO record: `--check` 0, `--apply` repointing the OTHER
# directives and leaving these, i.e. two homes in one file — and `203/EXEC` after the reclaim.
mk_box "$T/pfx"; mkdir -p "$DUR/state" "$DUR/env"
printf '#!/bin/sh\n' >"$DUR/harness/run.sh"
cat >"$UNITS/pfx.service" <<EOF
[Service]
Environment=HOME=$LEG
EnvironmentFile=-$LEG/env
WorkingDirectory=-$LEG/state
ExecStart=-$LEG/harness/run.sh
ExecStartPost=+$LEG/harness/run.sh
EOF
_out="$(run_tool "$TOOL" --apply)"; _rc=$?
[ "$_rc" = 0 ] && ok "k26 a unit whose paths carry systemd exec prefixes converges (rc 0)" \
  || bad "k26 the prefixed unit was refused ($_rc)"
if grep -q "$LEG" "$UNITS/pfx.service"; then
  bad "k26b …but the file STILL names the legacy home: $(grep -- "$LEG" "$UNITS/pfx.service" | tr '\n' ' ')"
else
  ok "k26b …and NOTHING in it names the legacy home any more (no half-migration)"
fi
run_tool "$TOOL" --check >/dev/null 2>&1; _rc=$?
[ "$_rc" = 0 ] && ok "k26c …so the follow-up --check reads 0 (the reclaim precondition is met over a file that meets it)" \
  || bad "k26c the follow-up --check answered $_rc — the tool left something behind and called it converged"

# ── F2 (round 3): a TAB inside a graded line must not move a record field ───────────────────
# Tabs are legal systemd whitespace. The raw line used to be field 3 of a TAB-delimited record, so a tab
# pushed the tail into the MISS field and the tool then reported a "durable counterpart missing" for a
# path that exists — refusing the file forever.
mk_box "$T/tab"; mkdir -p "$DUR/state"
printf '#!/bin/sh\n' >"$DUR/harness/run.sh"
printf '[Service]\nEnvironment=HOME=%s\nExecStart=%s/harness/run.sh\t--state %s/state\n' "$LEG" "$LEG" "$LEG" >"$UNITS/tab.service"
_out="$(run_tool "$TOOL" --apply)"; _rc=$?
[ "$_rc" = 0 ] && ok "k27 a unit with a TAB inside a graded directive converges (rc 0, no fabricated missing target)" \
  || bad "k27 a tab in the line corrupted the record and refused the file ($_rc)"
case "$_out" in
  *"durable counterpart missing"*) bad "k27b …and the report claims a durable counterpart is missing (it exists)" ;;
  *) ok "k27b …and no missing-counterpart was invented from the line's tail" ;;
esac

# ── F3 (round 3): pi-keys.env is a credential the fleet reads ───────────────────────────────
# The launch line sources `$home/keys.env` AND `$home/pi-keys.env`; the tool's own notes say so. Outside
# CRED_FILES it read as "one home" while the only copy of the model credential sat in the legacy home.
mk_box "$T/pikeys"
printf 'DEEPSEEK_API_KEY=%s\n' "$SENTINEL" >"$LEG/pi-keys.env"; chmod 600 "$LEG/pi-keys.env"
rm -f "$DUR/pi-keys.env"
run_tool "$TOOL" --check >/dev/null 2>&1; _rc=$?
[ "$_rc" = 1 ] && ok "k28 a legacy-only pi-keys.env is DRIFT (--check 1, not a false one home over the model credential)" \
  || bad "k28 pi-keys.env was outside the credential population (--check $_rc)"
_out="$(run_tool "$TOOL" --apply)"; _rc=$?
[ -e "$DUR/pi-keys.env" ] && ok "k28b …and --apply copies it into the durable home" \
  || bad "k28b pi-keys.env was not copied (rc $_rc) — it would be lost with the legacy home"
case "$_out" in *"$SENTINEL"*) bad "k28c the run printed the credential VALUE (rule 3)" ;; *) ok "k28c …and no credential value appears in the output" ;; esac

# ── F3 general: the ADVISORY listing is visible and changes nothing ─────────────────────────
mk_box "$T/adv"
run_tool "$TOOL" --apply >/dev/null 2>&1
printf 'operator notes\n' >"$LEG/legacy-only.txt"
_out="$(run_tool "$TOOL" --check)"; _rc=$?
case "$_out" in *"ADVISORY"*"legacy-only.txt"*) ok "k29 an entry the tool does not grade is listed ADVISORY" ;; *) bad "k29 the ungraded population is not surfaced" ;; esac
[ "$_rc" = 0 ] && ok "k29b …and it does NOT change the verdict (an advisory is not a gate, so no false block)" \
  || bad "k29b the advisory changed the exit code ($_rc) — it would block real boxes"

# ── F4 (round 3): the ownership fix must be gradeable, and its failure reported ────────────
# Ownership only needs fixing on a ROOT run, so the fixture stubs `id` (as i1 does) and names the owner
# that SHOULD be stamped. A chown that cannot succeed must be a WARN + rc 1, not `|| true`.
mk_box "$T/own"
rm -f "$DUR/keys.env"
_out="$(env CELL_HOME="$DUR" CELL_HOME_LEGACY="$LEG" CELL_HOME_MIGRATE_UNIT_DIRS="$UNITS" \
        CELL_HOME_MIGRATE_NO_RELOAD=1 CELL_HOME_MIGRATE_FORCE_OWNER="4242:4242" \
        PATH="$STUBROOT:$PATH" bash "$TOOL" --apply 2>&1)"; _rc=$?
[ "$_rc" = 1 ] && ok "k30 a root run whose ownership fix FAILS reports it (rc 1, not a swallowed 'copied …')" \
  || bad "k30 the ownership failure was swallowed (rc $_rc)"
case "$_out" in *"WRITTEN BUT NOT RE-OWNED"*) ok "k30b …naming the file and the owner it did not get" ;; *) bad "k30b the ownership failure is not reported" ;; esac

# ── F1/F2 (round 4): pi-keys.env is CONTENT-graded and mode-clamped, like keys.env ──────────
# `CRED_FILES` gives a file presence treatment; `ENV_FILES` is what gets its ASSIGNMENTS graded and what
# refuses a copy that re-points the home. Adding pi-keys.env to the first only installed a poisoned copy
# and certified "one home" — and it took the SOURCE mode, so a 0644 legacy file became a world-readable
# model credential.
mk_box "$T/pk2"
rm -f "$DUR/pi-keys.env"
printf 'export HOME=%s\nDEEPSEEK_API_KEY=%s\n' "$LEG" "$SENTINEL" >"$LEG/pi-keys.env"; chmod 644 "$LEG/pi-keys.env"
_out="$(run_tool "$TOOL" --apply)"; _rc=$?
[ "$_rc" = 1 ] && ok "k31 a legacy pi-keys.env that re-points HOME is REFUSED as a copy (rc 1, same rule as keys.env)" \
  || bad "k31 the poisoned pi-keys.env was copied ($_rc) — one rule for one file and not the other"
[ ! -e "$DUR/pi-keys.env" ] && ok "k31b …and the durable side is left MISSING rather than installed poisoned" \
  || bad "k31b the poisoned pi-keys.env landed in the durable home"
mk_box "$T/pk3"
rm -f "$DUR/pi-keys.env"
printf 'DEEPSEEK_API_KEY=%s\n' "$SENTINEL" >"$LEG/pi-keys.env"; chmod 644 "$LEG/pi-keys.env"
run_tool "$TOOL" --apply >/dev/null 2>&1
# `mode_of` lives in the TOOL, not in this suite: ask stat directly, guarded the way the tool does it.
_pm="$(stat -c '%a' "$DUR/pi-keys.env" 2>/dev/null || stat -f '%Lp' "$DUR/pi-keys.env" 2>/dev/null || true)"
[ -n "$_pm" ] && [ "$_pm" != "644" ] && ok "k32 a copied pi-keys.env is clamped to a private mode (got $_pm, source was 644)" \
  || bad "k32 the model credential was installed with the SOURCE mode (${_pm:-missing}) — world-readable"

# ── F3 (round 4): the UNIT chown refusal is armed (it had no arm at all) ─────────────────────
# A `chown` stub that always fails, and NO root stub, so only the unit-write leg can reach it: the rewrite
# must be refused by name and the original left byte-for-byte.
STUBCH="$T/stubchown"; mkdir -p "$STUBCH"
printf '#!/bin/sh\nexit 1\n' >"$STUBCH/chown"; chmod +x "$STUBCH/chown"
mk_box "$T/uch"
_before_u="$(cat "$UNITS/app.service")"
_out="$(PATH="$STUBCH:$PATH" CELL_HOME="$DUR" CELL_HOME_LEGACY="$LEG" CELL_HOME_MIGRATE_UNIT_DIRS="$UNITS" \
        CELL_HOME_MIGRATE_NO_RELOAD=1 bash "$TOOL" --apply 2>&1)"; _rc=$?
case "$_out" in *"could not be re-owned"*) ok "k33 a unit whose ownership cannot be restored is REFUSED by name" ;; *) bad "k33 the unit-write ownership failure is not reported" ;; esac
[ "$_before_u" = "$(cat "$UNITS/app.service")" ] && ok "k33b …and the original unit is left BYTE-FOR-BYTE intact" \
  || bad "k33b the refused rewrite still replaced the unit"

# ── F5 (round 4): the ADVISORY must be a real read and must not mislabel graded files ───────
mk_box "$T/adv2"
run_tool "$TOOL" --apply >/dev/null 2>&1
printf 'operator notes\n' >"$LEG/legacy-only.txt"
_out="$(run_tool "$TOOL" --check)"
case "$_out" in *"NOT graded by this tool"*"keys.env"*) bad "k34 the advisory calls a GRADED credential 'not graded'" ;; *) ok "k34 …and a graded credential is not labelled ungraded" ;; esac
chmod 111 "$LEG"                                        # searchable but NOT listable
if ls -A "$LEG" >/dev/null 2>&1; then
  ok "k34b SKIPS honestly: this account can still list a mode-111 directory"
else
  _out="$(run_tool "$TOOL" --check)"
  case "$_out" in *"CANNOT LIST"*) ok "k34b …and an UNLISTABLE legacy home is stated, not read as 'nothing ungraded'" ;; *) bad "k34b silence was presented as 'nothing ungraded' over a population that was never read" ;; esac
fi
chmod 755 "$LEG" 2>/dev/null

# ── F1/F5 (round 5): EVERY level `mkdir -p` created must be re-owned, and the failure is asserted ────
# A `chown` stub that fails only for DIRECTORIES, plus the root stub, so the directory leg is the only
# thing that can fail. The nested `.pi/agent` chain does not exist, so `mkdir -p` creates BOTH levels and
# the invariant is that neither is left root-owned while the run still says "copied …".
STUBCHD="$T/stubchowndir"; mkdir -p "$STUBCHD"
printf '#!/bin/sh\nfor a in "$@"; do case "$a" in -*) ;; *) [ -d "$a" ] && exit 1 ;; esac; done\nexit 0\n' >"$STUBCHD/chown"
chmod +x "$STUBCHD/chown"
mk_box "$T/nest"
rm -rf "$DUR/.pi"                                   # so the chain is CREATED by the copy
_out="$(env CELL_HOME="$DUR" CELL_HOME_LEGACY="$LEG" CELL_HOME_MIGRATE_UNIT_DIRS="$UNITS" \
        CELL_HOME_MIGRATE_NO_RELOAD=1 CELL_HOME_MIGRATE_FORCE_OWNER="4242:4242" \
        PATH="$STUBCHD:$STUBROOT:$PATH" bash "$TOOL" --apply 2>&1)"; _rc=$?
[ "$_rc" = 1 ] && ok "k35 a directory level this run created but could not re-own is a FAILURE (rc 1, not a silent 'one home')" \
  || bad "k35 a root run left an un-ownable credential directory behind and reported rc $_rc"
case "$_out" in *"cannot create or own"*) ok "k35b …naming the directory it could not take ownership of" ;; *) bad "k35b the ownership failure of a created directory is not reported" ;; esac

# ── F2 (round 5): the EXISTENCE GUARD sees the same tokens the projector moves ───────────────────
# `>`, `<`, `|`, `&`, `(` are token starts to the projector, so `>>$LEG/log` IS a path the writer moves.
# `paths_in` did not split on them, the token did not start with `/`, the `miss` list stayed EMPTY — and
# `--apply` wrote a unit whose redirect target does not exist (rule 4: never write a unit that would not
# run; systemd fails a unit whose unprefixed ExecStartPost fails).
mk_box "$T/redir"; rm -rf "$DUR/logs"
printf '[Service]\nEnvironment=HOME=%s\nExecStartPost=/bin/sh -c "echo x >>%s/logs/run.log"\n' "$LEG" "$LEG" >"$UNITS/redir.service"
_out="$(run_tool "$TOOL" --apply)"; _rc=$?
[ "$_rc" = 1 ] && ok "k36 --apply REFUSES a redirect target whose durable counterpart does not exist (rc 1)" \
  || bad "k36 the unit was written with a missing redirect target (rc $_rc) — rule 4 violated"
case "$(cat "$UNITS/redir.service")" in
  *"$LEG/logs"*) ok "k36b …and the original file is left untouched" ;;
  *) bad "k36b the unit was half-written with a nonexistent target" ;;
esac
mkdir -p "$DUR/logs"
run_tool "$TOOL" --apply >/dev/null 2>&1; _rc=$?
[ "$_rc" = 0 ] && ok "k36c …while the same unit converges once the target EXISTS (the refusal is about the target, not the shape)" \
  || bad "k36c the same unit was still refused with the target present (rc $_rc)"

# ── F3 (round 5): content grading is by VALUE, not only by the HOME/CELL_HOME names ──────────────
# The fleet sources its credential THROUGH `ENV_FILE` (`lane-env.sh`, `cloud-cell-supervisor.sh`,
# `install-repair-service.sh`), so a durable `keys.env` naming the legacy home in `ENV_FILE` re-installs
# the split from inside the file this migration installed.
mk_box "$T/envfile"
printf 'export HOME=%s\nENV_FILE=%s/keys.env\n' "$DUR" "$LEG" >"$DUR/keys.env"
_out="$(run_tool "$TOOL" --check)"; _rc=$?
[ "$_rc" = 1 ] && ok "k37 a durable keys.env whose ENV_FILE names the legacy home is DRIFT (CHECK 1, not a false one home)" \
  || bad "k37 an ENV_FILE pointing at the legacy home read as converged (rc $_rc)"
case "$_out" in *"ASSIGNS ENV_FILE"*) ok "k37b …and the report names ENV_FILE" ;; *) bad "k37b the assignment is not named" ;; esac

# ── F4 (round 5): a partially-graded directory is SURFACED, not swallowed ────────────────────────
mk_box "$T/part"; run_tool "$TOOL" --apply >/dev/null 2>&1
mkdir -p "$LEG/.pi/agent/sessions"; printf 'x\n' >"$LEG/.pi/agent/sessions/s1.json"
_out="$(run_tool "$TOOL" --check)"
case "$_out" in *"PARTIALLY graded"*".pi"*) ok "k38 a directory holding a graded credential AND ungraded content is reported PARTIALLY graded" ;; *) bad "k38 the partially-graded directory is silently dropped from the advisory" ;; esac

printf '\n── (m) THE POPULATION, THE EXEC PREFIX, AND THE EXISTENCE GUARD (review F1/F2/P1) ───\n'

# ⛔ F1 (review, reproduced): the USER-UNIT DIR came from the invoking shell's `$HOME` and the home this
# tool DERIVED was never consulted. ONE byte-identical legacy-naming unit under
# `$HOME_DURABLE/.config/systemd/user` answered `0 one home` when the tool was started with a different
# `HOME`, and `1 drift` when it was not — opposite verdicts for the same box. The two channels that reach
# it are the ones this project names itself (`cmux vm exec` hands over `HOME=/home/ubuntu`, and the
# tool's own printed root remedy runs with the target account's `HOME`), and the directory is real: the
# fleet's installer writes `UNIT_DIR="$HOME/.config/systemd/user"`. `--check` -> 0 is the RECLAIM
# precondition, so the quiet half authorises deleting the directory every user unit still names.
# The three system dirs are pinned to an empty fixture dir, so the arm grades the USER-DIR RESOLUTION
# instead of this host's `/etc/systemd/system` (a real cell carries vendor units there).
mk_box "$T/m1"
cp "$LEG/.pi/agent/auth.json" "$DUR/.pi/agent/auth.json"; chmod 600 "$DUR/.pi/agent/auth.json"   # credentials CONVERGED
mkdir -p "$DUR/.config/systemd/user" "$T/m1/wronghome" "$T/m1/nodir"
printf '[Service]\nEnvironment=HOME=%s\nExecStart=/bin/echo hi\n' "$LEG" >"$DUR/.config/systemd/user/legacyunit.service"
run_nodirs() { # <tool> <mode> — NO `CELL_HOME_MIGRATE_UNIT_DIRS` seam: the tool resolves its own population
  CELL_HOME="$DUR" CELL_HOME_LEGACY="$LEG" CELL_HOME_MIGRATE_NO_RELOAD=1 \
  SYSTEMD_UNIT_DIR="$T/m1/nodir" CONTROLLER_SYSTEM_UNIT_DIR="$T/m1/nodir" HOME="$T/m1/wronghome" \
  bash "$1" "$2" 2>&1
}
_out="$(run_nodirs "$TOOL" --check)"; _rc=$?
[ "$_rc" = 1 ] && ok "m1 a legacy-naming USER unit under the DURABLE home is DRIFT even when the invoking HOME is elsewhere (CHECK 1, not a false one home)" \
  || bad "m1 a user unit under the durable home read as converged (rc $_rc) — the population follows the invoker's HOME"
case "$_out" in *legacyunit.service*) ok "m2 …and the report NAMES it" ;; *) bad "m2 the graded user unit is not named: $_out" ;; esac
# ⛔ CONTROL: the invoker's own user-unit dir is an ADDITIONAL candidate, not a replacement — a unit that
# really lives there must still be graded, or the fix would trade one blind spot for another.
mkdir -p "$T/m1/wronghome/.config/systemd/user"
mv "$DUR/.config/systemd/user/legacyunit.service" "$T/m1/wronghome/.config/systemd/user/legacyunit.service"
_out="$(run_nodirs "$TOOL" --check)"; _rc=$?
[ "$_rc" = 1 ] && ok "m3 …while a unit under the INVOKING home's user-unit dir is still graded (additional candidate, not a replacement)" \
  || bad "m3 a unit under the invoking home's user dir is no longer graded (rc $_rc)"
mv "$T/m1/wronghome/.config/systemd/user/legacyunit.service" "$DUR/.config/systemd/user/legacyunit.service"

# ⛔ F2 (review, reproduced): the existence guard filtered by LOCATION — "any token under $HOME_DURABLE on
# the projected line" — not by "the REWRITE introduced this token". So a `StateDirectory=` (which
# systemd MANAGES rather than opens — and whose required form is RELATIVE, so an absolute value is
# IGNORED by systemd, `systemd-analyze verify` saying so) and an `Environment=PATH=` list entry were
# refused with a false `203/EXEC` diagnosis. A refused file never repoints, so `--check` could never
# reach 0 on that box: the RECLAIM precondition was PERMANENTLY unreachable, with a remedy built on a
# wrong diagnosis.
mk_box "$T/m2"
printf '[Service]\nStateDirectory=%s/state\nEnvironment=PATH=%s/bin:/usr/bin\nExecStart=/bin/echo hi\n' "$LEG" "$LEG" >"$UNITS/statedir.service"
[ ! -e "$DUR/state" ] && [ ! -e "$DUR/bin" ] && ok "m4 the fixture premise: BOTH projected targets are absent ($DUR/state, $DUR/bin)" \
  || bad "m4 the fixture accidentally created a target, so m5 proves nothing"
_out="$(run_tool "$TOOL" --apply)"; _rc=$?
[ "$_rc" = 0 ] && ok "m5 a StateDirectory=/PATH-list whose durable paths do NOT exist is not refused (the unit still starts: systemd IGNORES an absolute StateDirectory= and never opens an Environment= value), so the box converges" \
  || bad "m5 a unit systemd will start anyway was refused (rc $_rc) — the box can never reach one home"
case "$(cat "$UNITS/statedir.service" 2>/dev/null)" in
  *"StateDirectory=$DUR/state"*) ok "m6 …and it IS repointed onto the durable home" ;;
  *) bad "m6 the StateDirectory line was not repointed: $(grep StateDirectory "$UNITS/statedir.service" 2>/dev/null)" ;;
esac
case "$(cat "$UNITS/statedir.service" 2>/dev/null)" in
  *"PATH=$DUR/bin:/usr/bin"*) ok "m7 …and so is a PATH list entry under the legacy home" ;;
  *) bad "m7 the PATH list was not repointed" ;;
esac

# ⛔ B-P1 (review, reproduced): the projector MOVES a systemd exec-prefixed path (`-/…`, `+/…`, `!/…`,
# `@/…`) — `lib/cell-home.sh`'s `cell_home_project_line` strips the prefix run — while `paths_in` dropped every token that did
# not begin with `/`. So a PREFIXED path was repointed without its durable counterpart ever being graded:
# `--apply` wrote `ExecStart=+<durable>/run.sh` for a missing target, printed `VERDICT: one home` and
# exited 0, and that 0 is the stated RECLAIM precondition. The identical line WITHOUT the prefix was
# correctly refused, which is what made this a hole in the prefix and not in the guard.
mk_box "$T/m3"; run_tool "$TOOL" --apply >/dev/null 2>&1        # converge, so only the new unit drifts
rm -f "$DUR/harness/run.sh"
printf '[Service]\nEnvironment=HOME=%s\nExecStart=+%s/harness/run.sh\n' "$LEG" "$LEG" >"$UNITS/p.service"
_out="$(run_tool "$TOOL" --apply)"; _rc=$?
[ "$_rc" != 0 ] && ok "m8 a PREFIXED exec path whose durable counterpart is MISSING is REFUSED (rc $_rc, not a silent repoint)" \
  || bad "m8 a prefixed exec path was repointed at a path that does not exist (rc $_rc)"
case "$_out" in *"$DUR/harness/run.sh"*) ok "m9 …and the refusal names the missing durable target, so the diagnosis is checkable" ;; *) bad "m9 the refusal does not name the target: $_out" ;; esac
case "$(cat "$UNITS/p.service" 2>/dev/null)" in
  *"$LEG/harness/run.sh"*) ok "m10 …and the file is UNTOUCHED (still on the legacy home, never written to a dead target)" ;;
  *) bad "m10 the unit was rewritten anyway" ;;
esac
mkdir -p "$DUR/harness"; printf '#!/bin/sh\n' >"$DUR/harness/run.sh"
run_tool "$TOOL" --apply >/dev/null 2>&1; _rc=$?
[ "$_rc" = 0 ] && ok "m11 …while the same prefixed unit converges once the target EXISTS (the refusal grades the target, not the shape)" \
  || bad "m11 the prefixed unit was still refused with its target present (rc $_rc)"

# ⛔ B-P1'S FIX OVERSHOT, AND THAT IS ITS OWN FALSE BLOCK (review P1-1, reproduced). Stripping the exec
# prefix is right for the PROJECTOR (it moves the path either way), but `-` is NOT decoration: on
# `EnvironmentFile=`, `ReadWritePaths=`/`ReadOnlyPaths=` and `WorkingDirectory=` a leading `-` means
# "ignore if it does not exist" (`systemd.exec(5)`), so a rewrite that leaves such a target absent
# produces a unit that STARTS. ⛔ `RootDirectory=` IS NOT IN THIS FAMILY (review A): systemd documents no
# `-` prefix there and an absolute value is a FATAL error — m16 pins the refusal.
# The strip graded them as MANDATORY, so
# the repair refused every one of them, the file never repointed, and `--check` could never reach 0 —
# the RECLAIM precondition permanently unreachable on a unit that is fine (the same shape the A-F2 scan
# scope was widened for, one fix later). On `ExecStart*` the same `-` means only "this exit status is not
# fatal" and the binary MUST exist, so a blanket exemption is wrong in the other direction: the
# DIRECTIVE decides — m12/m15 (optional) against m14 (not optional).
mk_box "$T/m4"; run_tool "$TOOL" --apply >/dev/null 2>&1
rm -f "$DUR/f.env"
printf '[Service]\nEnvironment=HOME=%s\nEnvironmentFile=-%s/f.env\nExecStart=/bin/echo hi\n' "$LEG" "$LEG" >"$UNITS/opt.service"
_out="$(run_tool "$TOOL" --apply)"; _rc=$?
[ "$_rc" = 0 ] && ok "m12 EnvironmentFile=-<legacy>/f.env with NO durable counterpart converges (the unit itself says 'ignore if missing')" \
  || bad "m12 an optional EnvironmentFile was refused (rc $_rc) — that box can never reach one home"
case "$(cat "$UNITS/opt.service" 2>/dev/null)" in
  *"EnvironmentFile=-$DUR/f.env"*) ok "m13 …and it is repointed WITH its '-' prefix intact" ;;
  *) bad "m13 the prefix or the repointing was lost: $(grep EnvironmentFile "$UNITS/opt.service" 2>/dev/null)" ;;
esac
rm -f "$DUR/harness/run.sh"
printf '[Service]\nEnvironment=HOME=%s\nExecStart=-%s/harness/run.sh\n' "$LEG" "$LEG" >"$UNITS/optexec.service"
_out="$(run_tool "$TOOL" --apply)"; _rc=$?
[ "$_rc" != 0 ] && ok "m14 …while ExecStart=-<legacy>/run.sh is STILL refused: there '-' only means the exit status is not fatal, so the binary must exist (rc $_rc)" \
  || bad "m14 an optional EXEC target was repointed at a path that does not exist (rc $_rc)"
rm -f "$UNITS/optexec.service"
rm -f "$DUR/out.log"
printf '[Service]\nEnvironment=HOME=%s\nStandardOutput=file:%s/out.log\nExecStart=/bin/echo hi\n' "$LEG" "$LEG" >"$UNITS/stdout.service"
_out="$(run_tool "$TOOL" --apply)"; _rc=$?
[ "$_rc" = 0 ] && ok "m15 StandardOutput=file:<legacy>/out.log converges: systemd CREATES the file, so only its parent must exist" \
  || bad "m15 a StandardOutput= file that systemd creates was refused (rc $_rc)"
# ⛔ `RootDirectory=` HAS NO `-` SEMANTICS, SO IT MUST NOT BE EXEMPT (review A, measured with
# `systemd-analyze verify`): unlike `EnvironmentFile=`/`ReadWritePaths=`/`WorkingDirectory=`, an absolute
# `RootDirectory=-<path>` is a FATAL configuration error ("path is not absolute", "unit will not be
# started"), so a rewrite that leaves the target absent writes exactly the unrunnable unit rule 4 exists
# to prevent — and still exits 0, which is the RECLAIM precondition. The first cut of the `-` exemption
# listed it, so this is the arm that keeps the family honest.
rm -f "$UNITS/stdout.service"
rm -rf "$DUR/chroot"
printf '[Service]\nEnvironment=HOME=%s\nRootDirectory=-%s/chroot\nExecStart=/bin/echo hi\n' "$LEG" "$LEG" >"$UNITS/rootdir.service"
_out="$(run_tool "$TOOL" --apply)"; _rc=$?
[ "$_rc" != 0 ] && ok "m16 RootDirectory=-<legacy>/chroot with no durable counterpart is REFUSED: '-' is not a path prefix there, an absolute one is fatal (rc $_rc)" \
  || bad "m16 an absolute RootDirectory=-… was written with a missing target and the tool reported one home (rc $_rc)"
rm -f "$UNITS/rootdir.service"
# ⛔ THE INCLUSION SIDE OF THE FAMILY IS PINNED FOR EVERY MEMBER (review N6): m12 covers
# `EnvironmentFile=-` with an ABSENT twin, and m17 covers `WorkingDirectory=-`/`ReadWritePaths=-`/
# `ReadOnlyPaths=-` with absent twins — ⛔ NOT `k26`, WHICH DOES NOT CARRY THOSE TWO AT ALL (review
# cycle-6 #4): k26's fixture has `EnvironmentFile=` and `WorkingDirectory=` only, both with their durable
# targets CREATED, where need=1 and need=3 behave IDENTICALLY. So the arms that can see a member dropped
# from the exemption are m12 and m17, and nothing narrower: narrowing the regex to one member keeps m12's
# half green and reds m17. An absent `ReadWritePaths=`/`ReadOnlyPaths=` target is
# the shape an operator uses BEFORE the mount point exists, and `WorkingDirectory=-` is documented to be
# non-fatal when the directory is missing.
rm -rf "$DUR/wd" "$DUR/rw" "$DUR/ro"
printf '[Service]\nEnvironment=HOME=%s\nWorkingDirectory=-%s/wd\nReadWritePaths=-%s/rw\nReadOnlyPaths=-%s/ro\nExecStart=/bin/echo hi\n' \
    "$LEG" "$LEG" "$LEG" "$LEG" >"$UNITS/optpaths.service"
_out="$(run_tool "$TOOL" --apply)"; _rc=$?
[ "$_rc" = 0 ] && ok "m17 WorkingDirectory=/ReadWritePaths=/ReadOnlyPaths= with '-' and NO durable target converge (every family member except `EnvironmentFile=`, which m12 pins)" \
  || bad "m17 a '-' -prefixed working/mount path was refused (rc $_rc) — the exemption covers fewer members than it claims"
case "$(cat "$UNITS/optpaths.service" 2>/dev/null)" in
  *"WorkingDirectory=-$DUR/wd"*"ReadWritePaths=-$DUR/rw"*"ReadOnlyPaths=-$DUR/ro"*)
    ok "m18 …and ALL THREE are repointed with their '-' intact (the pattern names each one, so a writer that dropped a line reds here)" ;;
  *) bad "m18 the repointing or the prefix was lost: $(grep -E 'WorkingDirectory|ReadWritePaths|ReadOnlyPaths' "$UNITS/optpaths.service" 2>/dev/null)" ;;
esac
rm -f "$UNITS/optpaths.service"
# ⛔ THE STRICTEST GRADE PER PATH WINS, NOT THE FIRST MENTION (review cycle-9 #5, reproduced on the real
# function). Stripping the exec prefix folded `-/x` and `/x` onto ONE key, and the dedupe was
# first-mention-wins — so a path the SAME directive lists both optionally and mandatorily was graded
# OPTIONAL (need=3) whenever the `-` spelling came first, and a rewrite could then leave it absent. That
# is a fail-open on the rule-4 / `--check`→0 surface this tool exists to protect. Both orders are pinned:
# the reverse order already graded correctly, and an arm that only tested one order would pass on the bug.
rm -rf "$DUR/twice"
printf '[Service]\nEnvironment=HOME=%s\nReadWritePaths=-%s/twice %s/twice\nExecStart=/bin/echo hi\n' \
    "$LEG" "$LEG" "$LEG" >"$UNITS/twice.service"
_out="$(run_tool "$TOOL" --apply)"; _rc=$?
[ "$_rc" != 0 ] && ok "m19 ReadWritePaths=-<legacy>/twice <legacy>/twice is REFUSED: the mandatory mention of an absent path outranks the optional one on the same line (rc $_rc)" \
  || bad "m19 an absent path that the same directive also names MANDATORILY was graded optional and repointed (rc $_rc) — first-mention-wins"
rm -f "$UNITS/twice.service"

# mut_sub <src> <dst> <function> <old-substring> <new> — replace ONE substring on the FIRST line of ONE
# function that carries it. Scoped by function because several guards share a spelling; a control whose
# mutation cannot be applied must fail loudly rather than silently grade the unmutated tool.
mut_sub() {
  awk -v fn="$3" -v old="$4" -v new="$5" '
    $0 == fn "() {" { inf=1 }
    inf && !done && index($0, old) > 0 { i=index($0, old); $0 = substr($0,1,i-1) new substr($0,i+length(old)); done=1 }
    inf && /^}$/ { inf=0 }
    { print }' "$1" >"$2"
}
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

# g3: NEUTRALISE THE PROJECTOR so no unit line is ever graded (the PRE-FIX SHAPE of the verdict: a box
# with every unit pointed at the legacy home produced no record, so `--check` answered "one home"). a7/a8
# must redden — that is what makes them a measurement of the VERDICT rather than of the fixture.
mkdir -p "$T/mutdir3/lib"
cp "$TOOL" "$T/mutdir3/cell-home-migrate.sh"
sed 's#out="\$out\$head\$home"#out="$out$head$pat"#' "$HERE/lib/cell-home.sh" >"$T/mutdir3/lib/cell-home.sh"
if cmp -s "$HERE/lib/cell-home.sh" "$T/mutdir3/lib/cell-home.sh"; then
  bad "g3 the boundary-neutralising mutation could not be applied — a7 is not checking the verdict"
else
  mk_box "$T/g3"
  cp "$LEG/.pi/agent/auth.json" "$DUR/.pi/agent/auth.json"; chmod 600 "$DUR/.pi/agent/auth.json"
  run_tool "$T/mutdir3/cell-home-migrate.sh" --check >/dev/null 2>&1
  if [ "$?" = 0 ]; then
    ok "g3 WITH the projector neutralised the un-migrated box reads 0 — a7 measures the VERDICT (the F1 false PASS)"
  else
    bad "g3 the neutralised projector still reported drift — a7 is not measuring the verdict"
  fi
fi

# g4: RE-BASE SIBLINGS (the naive-replace shape) and d20/d21 must redden — the boundary arm really is
# testing `cell_home_project_line`'s `/`-or-end-of-line rule.
mkdir -p "$T/mutdir4/lib"; cp "$HERE/cell-home-migrate.sh" "$T/mutdir4/cell-home-migrate.sh"
sed 's#out="\$out\$head\$pat"#out="$out$head$home"#' "$HERE/lib/cell-home.sh" >"$T/mutdir4/lib/cell-home.sh"
if cmp -s "$HERE/lib/cell-home.sh" "$T/mutdir4/lib/cell-home.sh"; then
  bad "g4 the sibling-rebasing mutation could not be applied — d20/d21 are not checking the boundary"
else
  mk_box "$T/g4"
  printf 'Environment=ARCHIVE=%s.bak\n' "$LEG" >>"$UNITS/app.service"
  run_tool "$T/mutdir4/cell-home-migrate.sh" --apply >/dev/null 2>&1
  case "$(cat "$UNITS/app.service")" in
    *"ARCHIVE=$LEG.bak"*) bad "g4 the sibling-rebasing mutant still left the archive path alone — d21 is not measuring the boundary" ;;
    *) ok "g4 WITH siblings re-based the archive path is rewritten (or the file refused) — d21 measures the boundary" ;;
  esac
fi

# g5: DROP THE CONTINUATION INHERITANCE and d17-d19 must redden. This is the writer/scanner disagreement
# shape: a continuation line is then no longer graded at all, so the file cannot converge.
mkdir -p "$T/mutdir5/lib"; cp "$HERE/lib/cell-home.sh" "$T/mutdir5/lib/cell-home.sh"
mut_sub "$TOOL" "$T/mutdir5/cell-home-migrate.sh" unit_scan 'if [ -n "$cont" ]; then' 'if false; then' 
if cmp -s "$HERE/cell-home-migrate.sh" "$T/mutdir5/cell-home-migrate.sh"; then
  bad "g5 the continuation mutation could not be applied — d17-d19 are not checking the continuation"
else
  mk_box "$T/g5"; mkdir -p "$DUR/state"
  cat >"$UNITS/app.service" <<EOF
[Service]
Environment=HOME=$LEG
ExecStart=$LEG/harness/run.sh \\
  --state $LEG/state
EOF
  run_tool "$T/mutdir5/cell-home-migrate.sh" --apply >/dev/null 2>&1
  case "$(cat "$UNITS/app.service")" in
    *"--state $LEG/state"*) ok "g5 WITHOUT the continuation inheritance the continuation keeps the legacy path — d18 measures it" ;;
    *) bad "g5 the mutant still converged the continuation — d18 is not measuring it" ;;
  esac
  # …and the SAME mutant is F4's pre-fix shape for a continuation that begins with a WORD (it is derived
  # from the first character instead of inherited), so k16b must redden here too.
  mk_box "$T/g5b"
  cat >"$UNITS/app.service" <<EOF
[Service]
ExecStart=/bin/sh -c \\
cd $LEG
EOF
  run_tool "$T/mutdir5/cell-home-migrate.sh" --apply >/dev/null 2>&1; _m5rc=$?
  case "$(cat "$UNITS/app.service")" in
    *"cd $DUR"*) bad "g5b the mutant still repointed a word-starting continuation — k16b is not measuring the inheritance" ;;
    *) [ "$_m5rc" != 0 ] && ok "g5b WITHOUT the inheritance a word-starting continuation is refused (rc $_m5rc) — k16b measures it" \
         || bad "g5b the mutant answered 0 without repointing the continuation — k16b is ambiguous" ;;
  esac
fi

# g6: NEUTRALISE THE CONFLICT PREDICATE and b4/b7/b8 must redden — i.e. those arms measure the SHARED
# predicate (`credential_conflict`, called by both modes) rather than a fixture that could never produce a
# conflict. This is the mutation for the F1 false PASS, where the guard simply did not exist in `--check`.
MUT6="$T/mutdir6"; mkdir -p "$MUT6/lib"; cp "$HERE/lib/cell-home.sh" "$MUT6/lib/cell-home.sh"
awk 'BEGIN{inb=0}
  /^credential_conflict\(\) \{$/ { inb=1; print; next }
  inb && /^}$/             { inb=0; print; next }
  inb && index($0, "mtime_of") > 0 { print "  return 1"; next }
  { print }' "$TOOL" >"$MUT6/cell-home-migrate.sh"
if ! grep -q '^  return 1$' "$MUT6/cell-home-migrate.sh"; then
  bad "g6 the conflict mutation could not be applied — b7/b8 are not checking the predicate"
else
  mk_box "$T/g6"
  run_tool "$MUT6/cell-home-migrate.sh" --apply >/dev/null 2>&1
  sleep 1; touch "$LEG/keys.env"
  run_tool "$MUT6/cell-home-migrate.sh" --check >/dev/null 2>&1; _m6=$?
  [ "$_m6" = 0 ] && ok "g6 WITHOUT the conflict predicate --check reads 0 over a NEWER legacy credential — b8 measures it" \
    || bad "g6 the mutated tool still reported drift (rc $_m6) — b8 is not measuring the predicate"
fi


# g7: REVERT THE CANNOT-MEASURE GUARDS (the pre-fix shape: the prefilter's failure indistinguishable from
# "no match", and the read redirect failing silently). k1-k5 must redden — that is what makes them a
# measurement of the F1 fix rather than a fixture property.
mkdir -p "$T/mutdir7/lib"; cp "$HERE/lib/cell-home.sh" "$T/mutdir7/lib/cell-home.sh"
MUT7="$T/mutdir7/cell-home-migrate.sh"
sed -e 's#^probe_open() { ( : <"$1" ) 2>/dev/null; }#probe_open() { return 0; }#' \
    -e 's#^      if \[ "$st" -gt 1 \]; then#      if false; then#' "$TOOL" >"$MUT7"
# The SAME converged-box fixture k1 uses, so the only thing that can move the rc is the hidden unit.
mk_hidden_box "$T/g7"
if cmp -s "$TOOL" "$MUT7"; then
  bad "g7 the cannot-measure mutation could not be applied — k1-k5 are not checking the read guards"
elif ( : <"$UNITS/hidden.service" ) 2>/dev/null; then
  ok "g7 SKIPS honestly: this account can read a mode-000 unit, so no mutant can make the fixture unreadable"
else
  _m7="$(run_tool "$MUT7" --check)"; _m7rc=$?
  case "$_m7" in *"VERDICT: one home"*) _m7said=1 ;; *) _m7said=0 ;; esac
  [ "$_m7rc" = 0 ] && [ "$_m7said" = 1 ] \
    && ok "g7 WITHOUT the read guards an OPEN-DENIED unit reads as 'one home' (rc 0) — k1/k3 measure the fix" \
    || bad "g7 the mutated tool answered $_m7rc without a 'one home' verdict — k1 is not measuring the read guard"
fi
chmod 644 "$UNITS/hidden.service" 2>/dev/null

# g8: REVERT THE CONTINUATION RULES to their pre-fix shape — the inherited name cleared on a comment and
# on every non-hit line — and k10-k13 must redden. This is F2's exact regression, not the general
# inheritance `g5` already covers.
mkdir -p "$T/mutdir8/lib"; cp "$HERE/lib/cell-home.sh" "$T/mutdir8/lib/cell-home.sh"
MUT8="$T/mutdir8/cell-home-migrate.sh"
sed -e 's#^    if is_comment "\$line"; then continue; fi#    if is_comment "$line"; then cont=""; continue; fi#' "$TOOL" >"$T/mutdir8/tmp.sh"
# the pre-fix rule: every NON-HIT line cleared the inherited name, whether or not it was a continuation.
# Restored by short-circuiting the branch (the bookkeeping below it becomes dead code, which is the point).
mut_sub "$T/mutdir8/tmp.sh" "$MUT8" unit_scan '        case "$stripped" in' '        cont=""; continue; case "$stripped" in'
rm -f "$T/mutdir8/tmp.sh"
if cmp -s "$TOOL" "$MUT8"; then
  bad "g8 the continuation mutation could not be applied — k10-k13 are not checking the logical line"
else
  mk_box "$T/g8"; mkdir -p "$DUR/state"
  cat >"$UNITS/app.service" <<EOF
[Service]
Environment=HOME=$LEG
ExecStart=$LEG/harness/run.sh \\
  --flag \\
  --state $LEG/state
EOF
  run_tool "$MUT8" --apply >/dev/null 2>&1; _m8rc=$?
  case "$(cat "$UNITS/app.service")" in
    *"--state $DUR/state"*) bad "g8 the mutant still converged the middle-line continuation — k10/k11 are not measuring it" ;;
    *) [ "$_m8rc" != 0 ] && ok "g8 WITHOUT the logical-line rule the middle-line continuation is refused/left behind (rc $_m8rc) — k10/k11 measure it" \
         || bad "g8 the mutant answered 0 without repointing the continuation — k10/k11 are ambiguous" ;;
  esac
  mk_box "$T/g8b"; mkdir -p "$DUR/state"
  cat >"$UNITS/app.service" <<EOF
[Service]
Environment=HOME=$LEG
ExecStart=$LEG/harness/run.sh \\
# measured note
  --state $LEG/state
EOF
  run_tool "$MUT8" --apply >/dev/null 2>&1; _m8brc=$?
  case "$(cat "$UNITS/app.service")" in
    *"--state $DUR/state"*) bad "g8b the mutant still converged through the comment — k12/k13 are not measuring it" ;;
    *) [ "$_m8brc" != 0 ] && ok "g8b WITHOUT the comment rule the comment ends the logical line and the file is refused (rc $_m8brc) — k12/k13 measure it" \
         || bad "g8b the mutant answered 0 through the comment — k12/k13 are ambiguous" ;;
  esac
fi

# g9: THE POST-WRITE RE-GRADE (rule-3 note 2 from the review — it had NO arm). Two mutants of the writer,
# differing ONLY in the post-condition:
#   (a) a writer that does not project, WITH the re-grade  -> must REFUSE, original untouched;
#   (b) the same writer with the re-grade deleted         -> must SWAP IN the un-projected file.
# (b) is what makes (a) a measurement: without it, "the file was refused" could be any other refusal.
mkdir -p "$T/mutdir9/lib"; cp "$HERE/lib/cell-home.sh" "$T/mutdir9/lib/cell-home.sh"
_printf_proj='printf'
MUT9="$T/mutdir9/cell-home-migrate.sh"
awk 'index($0, "'"$_printf_proj"' \047%s\\n\047 \"$(cell_home_project_line") > 0 { print "    printf \047%s\\n\047 \"$line\" >>\"$dst\" || return 1"; next } { print }' \
  "$TOOL" >"$MUT9"
MUT9b="$T/mutdir9/cell-home-migrate-nopost.sh"
awk 'index($0, "if [ -n \"$(unit_scan \"$tmpdir\")\" ]; then") > 0 { print "        if false; then"; next } { print }' \
  "$MUT9" >"$MUT9b"
if cmp -s "$TOOL" "$MUT9" || cmp -s "$MUT9" "$MUT9b"; then
  bad "g9 the writer/ungraded mutations could not be applied — (d) does not measure the re-grade"
else
  mk_box "$T/g9"
  _g9_before="$(cat "$UNITS/app.service")"
  _out9="$(run_tool "$MUT9" --apply)"; _rc9=$?
  case "$_out9" in
    *"the writer and the scanner disagree"*) ok "g9 WITH the re-grade a writer that does not project is REFUSED by name — the swap never happens" ;;
    *) bad "g9 an un-projected rewrite was not caught by the post-write re-grade (rc $_rc9)" ;;
  esac
  [ "$_g9_before" = "$(cat "$UNITS/app.service")" ] && ok "g9b …and the original unit is left BYTE-FOR-BYTE intact" \
    || bad "g9b the refused rewrite still replaced the unit"
  mk_box "$T/g9c"
  run_tool "$MUT9b" --apply >/dev/null 2>&1; _rc9b=$?
  case "$(cat "$UNITS/app.service")" in
    *"$LEG/harness/run.sh"*) [ "$_rc9b" = 0 ] && ok "g9c WITH the re-grade DELETED the same writer swaps in a file that still names the legacy home — g9 measures the re-grade, not another guard" \
        || bad "g9c the no-re-grade mutant refused anyway (rc $_rc9b) — g9's refusal is not attributable to the re-grade" ;;
    *) bad "g9c the no-re-grade mutant did not write the un-projected file — g9 is ambiguous" ;;
  esac
fi


# g10: REMOVE THE DERIVATION'S MEASURABILITY GATES and i7/i8 must redden — i.e. those arms measure the
# gates, not a fixture that happens to refuse for another reason. ⛔ ALL THREE legs are mutated together:
# the DIR-walkability gate, `find`'s traversal error, and the unit's own open. Any one left in place still
# refuses i7's box, and the mutant then writes nothing — the control says nothing (measured: with only
# the first two mutated, the third alone answered for i7 and g10 went red).
mkdir -p "$T/mutdir10/lib"; cp "$HERE/lib/cell-home.sh" "$T/mutdir10/lib/cell-home.sh"
MUT10="$T/mutdir10/cell-home-migrate.sh"
mut_sub "$TOOL" "$T/mutdir10/m1.sh" check_derivation 'walkable_dir "$d"; wst=$?' 'wst=0'
mut_sub "$T/mutdir10/m1.sh" "$T/mutdir10/m2.sh" check_derivation 'if [ -n "$UNIT_FIND_ERR" ]; then' 'if false; then'
mut_sub "$T/mutdir10/m2.sh" "$MUT10" check_derivation 'if ! probe_open "$f"; then' 'if false; then'
rm -f "$T/mutdir10/m1.sh" "$T/mutdir10/m2.sh"
if cmp -s "$TOOL" "$MUT10"; then
  bad "g10 the derivation-gate mutation could not be applied — i7/i8 are not checking it"
elif ! ls "$UNITS" >/dev/null 2>&1; then
  ok "g10 SKIPS honestly: the previous fixture is still unreadable"
else
  mk_box "$T/g10"
  sed -i.bak 's/^User=.*/User=ubuntu/' "$UNITS/app.service" && rm -f "$UNITS/app.service.bak"
  rm -f "$T/realhome/keys.env" "$T/realhome/.pi/agent/auth.json" "$DUR/keys.env"
  chmod 000 "$UNITS"
  if ls "$UNITS" >/dev/null 2>&1; then
    ok "g10 SKIPS honestly: this account can read a mode-000 unit dir"
  else
    env -u CELL_HOME PATH="$STUBACCT:$PATH" CELL_HOME_LEGACY="$LEG" CELL_HOME_MIGRATE_UNIT_DIRS="$UNITS" \
      CELL_HOME_MIGRATE_NO_RELOAD=1 bash "$MUT10" --apply >/dev/null 2>&1
    [ -e "$T/realhome/.pi/agent/auth.json" ] && ok "g10 WITHOUT the measurability gate a credential IS written into the DERIVED home — i8 measures the gate" \
      || bad "g10 the mutant still wrote nothing into the derived home — i8 is not attributable to the gate"
  fi
  chmod 755 "$UNITS" 2>/dev/null
fi

# g11: REMOVE the `probe_open` leg from `report_env_file` and j9 must redden — an unreadable durable
# `keys.env` then reads as "names no volatile home" again (0/1 instead of 3).
mkdir -p "$T/mutdir11/lib"; cp "$HERE/lib/cell-home.sh" "$T/mutdir11/lib/cell-home.sh"
MUT11="$T/mutdir11/cell-home-migrate.sh"
# ⛔ BOTH PROBE LEGS, because the durable-side read (F6, `durable_state`) now catches the unreadable file
# before `report_env_file` ever runs — removing only the latter would leave j9 green for the right
# reason and this control would have nothing to say.
mut_sub "$TOOL" "$T/mutdir11/m1.sh" durable_state 'probe_open "$p" || return 3' ':'
mut_sub "$T/mutdir11/m1.sh" "$MUT11" report_env_file 'if [ -e "$f" ] && ! probe_open "$f"; then' 'if false; then'
rm -f "$T/mutdir11/m1.sh"
if cmp -s "$TOOL" "$MUT11"; then
  bad "g11 the env-file probe mutation could not be applied — j9 is not checking it"
else
  mk_box "$T/g11"
  printf 'export CELL_HOME=%s\nK=%s\n' "$LEG" "$POISON" >"$DUR/keys.env"; chmod 000 "$DUR/keys.env"
  if ( : <"$DUR/keys.env" ) 2>/dev/null; then
    ok "g11 SKIPS honestly: this account can open a mode-000 file"
  else
    run_tool "$MUT11" --check >/dev/null 2>&1; _m11rc=$?
    [ "$_m11rc" != 3 ] && ok "g11 WITHOUT the probe an unreadable durable keys.env is no longer CANNOT MEASURE (rc $_m11rc) — j9 measures the probe" \
      || bad "g11 the mutant still answered 3 — j9 is not measuring the probe"
  fi
  chmod 600 "$DUR/keys.env" 2>/dev/null
fi

# g12: NARROW THE POPULATION back to `-type f` and k19 must redden (the symlink becomes invisible);
# g12b: drop `*.socket` from the name set and k17 must redden.
mkdir -p "$T/mutdir12/lib"; cp "$HERE/lib/cell-home.sh" "$T/mutdir12/lib/cell-home.sh"
MUT12="$T/mutdir12/cell-home-migrate.sh"
mut_sub "$TOOL" "$MUT12" unit_files '-type f -o -type l' '-type f'
MUT12b="$T/mutdir12/cell-home-migrate-nosock.sh"
mut_sub "$TOOL" "$MUT12b" unit_files " -o -name '*.socket'" ""
if cmp -s "$TOOL" "$MUT12" || cmp -s "$TOOL" "$MUT12b"; then
  bad "g12 the population mutations could not be applied — k17/k19 are not checking the population"
else
  mk_box "$T/g12"
  run_tool "$TOOL" --apply >/dev/null 2>&1
  printf '[Service]\nEnvironment=HOME=%s\n' "$LEG" >"$T/g12/target.service"
  ln -s "$T/g12/target.service" "$UNITS/linked.service"
  run_tool "$MUT12" --check >/dev/null 2>&1; _m12rc=$?
  [ "$_m12rc" = 0 ] && ok "g12 WITHOUT -type l a symlinked unit is invisible again (--check 0) — k19 measures the population" \
    || bad "g12 the mutant still saw the symlink (rc $_m12rc) — k19 is not measuring it"
  mk_box "$T/g12b"
  run_tool "$TOOL" --apply >/dev/null 2>&1
  printf '[Socket]\nListenStream=%s/lane.sock\n' "$LEG" >"$UNITS/app.socket"
  run_tool "$MUT12b" --check >/dev/null 2>&1; _m12brc=$?
  [ "$_m12brc" = 0 ] && ok "g12b WITHOUT *.socket a socket unit is invisible again (--check 0) — k17 measures the name set" \
    || bad "g12b the mutant still saw the .socket (rc $_m12brc) — k17 is not measuring it"
fi
# g13: drop the whitespace trim (F3) and k22 must redden — the spaced directive becomes UNHANDLED again.
mkdir -p "$T/mutdir13/lib"; cp "$HERE/lib/cell-home.sh" "$T/mutdir13/lib/cell-home.sh"
MUT13="$T/mutdir13/cell-home-migrate.sh"
mut_sub "$TOOL" "$MUT13" unit_scan 'dir="$(trim_tail "${stripped%%=*}")"' 'dir="${stripped%%=*}"'
if cmp -s "$TOOL" "$MUT13"; then
  bad "g13 the whitespace-trim mutation could not be applied — k22 is not checking it"
else
  mk_box "$T/g13"
  printf '[Service]\nEnvironment = HOME=%s\nExecStart = /bin/true\n' "$LEG" >"$UNITS/ws.service"
  run_tool "$MUT13" --apply >/dev/null 2>&1; _m13rc=$?
  case "$(cat "$UNITS/ws.service")" in
    *"HOME=$LEG"*) [ "$_m13rc" != 0 ] && ok "g13 WITHOUT the trim 'Environment = …' is UNHANDLED/refused (rc $_m13rc) — k22 measures it" \
        || bad "g13 the mutant answered 0 without repointing — k22 is ambiguous" ;;
    *) bad "g13 the mutant still repointed the spaced directive — k22 is not measuring the trim" ;;
  esac
fi

# g14: put enablement aliases back in the population (F4) and k23 must redden.
mkdir -p "$T/mutdir14/lib"; cp "$HERE/lib/cell-home.sh" "$T/mutdir14/lib/cell-home.sh"
MUT14="$T/mutdir14/cell-home-migrate.sh"
mut_sub "$TOOL" "$MUT14" unit_files "! -path '*.wants/*' ! -path '*.requires/*' ! -path '*.upholds/*' )" ")"
if cmp -s "$TOOL" "$MUT14"; then
  bad "g14 the alias-exclusion mutation could not be applied — k23 is not checking it"
else
  mk_box "$T/g14"
  run_tool "$TOOL" --apply >/dev/null 2>&1
  printf '[Service]\nEnvironment=HOME=%s\n' "$LEG" >"$UNITS/zzz.service"
  mkdir -p "$UNITS/default.target.wants"
  ln -s "../zzz.service" "$UNITS/default.target.wants/zzz.service"
  run_tool "$MUT14" --apply >/dev/null 2>&1; _m14rc=$?
  [ "$_m14rc" != 0 ] && ok "g14 WITHOUT the exclusion the enablement alias is refused while its target is repointed (rc $_m14rc) — k23 measures it" \
    || bad "g14 the mutant converged anyway — k23 is not measuring the alias exclusion"
fi
# g14b: a dangling symlink back in the population must turn every run into a permanent exit 3.
MUT14b="$T/mutdir14/cell-home-migrate-nodangle.sh"
mut_sub "$TOOL" "$MUT14b" unit_files 'if [ -L "$f" ] && [ ! -e "$f" ]; then continue; fi' ':'
if cmp -s "$TOOL" "$MUT14b"; then
  bad "g14b the dangling-link mutation could not be applied — k23c is not checking it"
else
  mk_box "$T/g14b"
  run_tool "$TOOL" --apply >/dev/null 2>&1
  ln -s "../gone.service" "$UNITS/dangling.service"
  run_tool "$MUT14b" --check >/dev/null 2>&1; _m14brc=$?
  [ "$_m14brc" = 3 ] && ok "g14b WITHOUT the dangling-link skip a stale alias makes --check a permanent 3 — k23c measures it" \
    || bad "g14b the mutant answered $_m14brc — k23c is not measuring the skip"
fi

# g15: drop the unterminated-line idiom (F1) and k21 must redden.
mkdir -p "$T/mutdir15/lib"; cp "$HERE/lib/cell-home.sh" "$T/mutdir15/lib/cell-home.sh"
MUT15="$T/mutdir15/cell-home-migrate.sh"
mut_sub "$TOOL" "$MUT15" unit_scan 'while IFS= read -r line || [ -n "$line" ]; do' 'while IFS= read -r line; do'
if cmp -s "$TOOL" "$MUT15"; then
  bad "g15 the read-loop mutation could not be applied — k21 is not checking it"
else
  mk_box "$T/g15"
  run_tool "$TOOL" --apply >/dev/null 2>&1
  printf 'Environment=PATH=/usr/bin\nEnvironment=HOME=%s' "$LEG" >>"$UNITS/app.service"   # no trailing newline
  run_tool "$MUT15" --check >/dev/null 2>&1; _m15rc=$?
  [ "$_m15rc" = 0 ] && ok "g15 WITHOUT the idiom an unterminated last line is invisible (--check 0) — k21 measures it" \
    || bad "g15 the mutant still saw the last line (rc $_m15rc) — k21 is not measuring it"
fi

# g16: remove BOTH durable-side read guards (F6) and k24 must redden.
mkdir -p "$T/mutdir16/lib"; cp "$HERE/lib/cell-home.sh" "$T/mutdir16/lib/cell-home.sh"
MUT16="$T/mutdir16/cell-home-migrate.sh"
mut_sub "$TOOL" "$T/mutdir16/m1.sh" durable_state 'probe_open "$p" || return 3' ':'
mut_sub "$T/mutdir16/m1.sh" "$MUT16" durable_state 'cannot_traverse "$p" && return 3' ':'
rm -f "$T/mutdir16/m1.sh"
if cmp -s "$TOOL" "$MUT16"; then
  bad "g16 the durable-side mutation could not be applied — k24 is not checking it"
else
  mk_box "$T/g16"
  run_tool "$TOOL" --apply >/dev/null 2>&1
  rm -f "$LEG/keys.env" "$LEG/.pi/agent/auth.json"
  chmod 600 "$DUR"
  if ( : <"$DUR/keys.env" ) 2>/dev/null; then
    ok "g16 SKIPS honestly: this account can still reach an entry in a mode-600 durable home"
  else
    run_tool "$MUT16" --check >/dev/null 2>&1; _m16rc=$?
    [ "$_m16rc" = 0 ] && ok "g16 WITHOUT the durable-side read guards an unsearchable durable home reads 'one home' (0) — k24 measures them" \
      || bad "g16 the mutant answered $_m16rc — k24 is not measuring the guards"
  fi
  chmod 755 "$DUR" 2>/dev/null
fi

# g17: remove the durable-side ownership fix (F4 round 3) and k30 must redden — the failure is then
# swallowed and the run reports success over a credential the cell account cannot read.
mkdir -p "$T/mutdir17/lib"; cp "$HERE/lib/cell-home.sh" "$T/mutdir17/lib/cell-home.sh"
MUT17="$T/mutdir17/cell-home-migrate.sh"
mut_sub "$TOOL" "$T/mutdir17/m1.sh" migrate_credentials 'if ! chown "$DUR_OWNER" "$(dirname "$f_dur")" 2>/dev/null; then' 'if false; then'
mut_sub "$T/mutdir17/m1.sh" "$MUT17" migrate_credentials 'if ! chown "$DUR_OWNER" "$f_dur" 2>/dev/null; then' 'if false; then'
rm -f "$T/mutdir17/m1.sh"
if cmp -s "$TOOL" "$MUT17"; then
  bad "g17 the ownership mutation could not be applied — k30 is not checking it"
else
  mk_box "$T/g17"; rm -f "$DUR/keys.env"
  env CELL_HOME="$DUR" CELL_HOME_LEGACY="$LEG" CELL_HOME_MIGRATE_UNIT_DIRS="$UNITS" \
      CELL_HOME_MIGRATE_NO_RELOAD=1 CELL_HOME_MIGRATE_FORCE_OWNER="4242:4242" \
      PATH="$STUBROOT:$PATH" bash "$MUT17" --apply >/dev/null 2>&1; _m17rc=$?
  [ "$_m17rc" = 0 ] && ok "g17 WITHOUT the ownership report a failed chown is swallowed (rc 0) — k30 measures it" \
    || bad "g17 the mutant still failed (rc $_m17rc) — k30 is not attributable to the ownership fix"
fi

# g18: put the raw unit line back into the TAB-delimited record (F2 round 3) and k27 must redden.
mkdir -p "$T/mutdir18/lib"; cp "$HERE/lib/cell-home.sh" "$T/mutdir18/lib/cell-home.sh"
MUT18="$T/mutdir18/cell-home-migrate.sh"
# the pre-fix record carried the LINE as a field; putting a line-shaped value back in the payload is
# the same defect in miniature (a TAB in the line then moves the field boundary).
mut_sub "$TOOL" "$MUT18" unit_scan '${miss# }' '$projected'
if cmp -s "$TOOL" "$MUT18"; then
  bad "g18 the record-format mutation could not be applied — k27 is not checking it"
else
  mk_box "$T/g18"; mkdir -p "$DUR/state"
  printf '#!/bin/sh\n' >"$DUR/harness/run.sh"
  printf '[Service]\nEnvironment=HOME=%s\nExecStart=%s/harness/run.sh\t--state %s/state\n' "$LEG" "$LEG" "$LEG" >"$UNITS/tab.service"
  run_tool "$MUT18" --apply >/dev/null 2>&1; _m18rc=$?
  [ "$_m18rc" != 0 ] && ok "g18 WITH the raw line in the record a TAB corrupts it and the file is refused (rc $_m18rc) — k27 measures the format" \
    || bad "g18 the mutant converged anyway — k27 is not measuring the record format"
fi

# g19: drop pi-keys.env from the population (F3 round 3) and k28 must redden.
mkdir -p "$T/mutdir19/lib"; cp "$HERE/lib/cell-home.sh" "$T/mutdir19/lib/cell-home.sh"
MUT19="$T/mutdir19/cell-home-migrate.sh"
# the list entry is the line that is EXACTLY `pi-keys.env` (the comments mention it in prose).
awk '$0 == "pi-keys.env" && !done { done=1; next } { print }' "$TOOL" >"$MUT19"
if cmp -s "$TOOL" "$MUT19"; then
  bad "g19 the credential-population mutation could not be applied — k28 is not checking it"
else
  mk_box "$T/g19"
  run_tool "$TOOL" --apply >/dev/null 2>&1              # converge FIRST, so only pi-keys.env can drift
  printf 'DEEPSEEK_API_KEY=%s\n' "$SENTINEL" >"$LEG/pi-keys.env"; chmod 600 "$LEG/pi-keys.env"
  rm -f "$DUR/pi-keys.env"
  run_tool "$MUT19" --check >/dev/null 2>&1; _m19rc=$?
  [ "$_m19rc" = 0 ] && ok "g19 WITHOUT pi-keys.env in the population the box reads 'one home' (0) — k28 measures it" \
    || bad "g19 the mutant still reported drift (rc $_m19rc) — k28 is not measuring the population"
fi

# g20: revert ENV_FILES to `keys.env` only (round-4 F1) and k31 must redden — the poisoned pi-keys.env is
# then copied and certified "one home".
mkdir -p "$T/mutdir20/lib"; cp "$HERE/lib/cell-home.sh" "$T/mutdir20/lib/cell-home.sh"
MUT20="$T/mutdir20/cell-home-migrate.sh"
awk 'index($0, "ENV_FILES=\"keys.env pi-keys.env\"") > 0 && !done { print "ENV_FILES=\"keys.env\""; done=1; next } { print }' "$TOOL" >"$MUT20"
if cmp -s "$TOOL" "$MUT20"; then
  bad "g20 the ENV_FILES mutation could not be applied — k31 is not checking it"
else
  mk_box "$T/g20"; rm -f "$DUR/pi-keys.env"
  printf 'export HOME=%s\nK=%s\n' "$LEG" "$SENTINEL" >"$LEG/pi-keys.env"; chmod 644 "$LEG/pi-keys.env"
  run_tool "$MUT20" --apply >/dev/null 2>&1; _m20rc=$?
  [ -e "$DUR/pi-keys.env" ] && [ "$_m20rc" = 0 ] \
    && ok "g20 WITHOUT pi-keys.env in ENV_FILES a home-re-pointing copy IS installed and the run reads 0 — k31 measures it" \
    || bad "g20 the mutant still refused the copy (rc $_m20rc) — k31 is not attributable to ENV_FILES"
fi

# g21: revert the 600 clamp (round-4 F2) and k32 must redden.
MUT21="$T/mutdir20/cell-home-migrate-mode.sh"
awk 'index($0, "keys.env|pi-keys.env|.pi/agent/auth.json|.config/gh/hosts.yml) mode=600") > 0 && !done { print "      keys.env|.pi/agent/auth.json|.config/gh/hosts.yml) mode=600 ;;"; done=1; next } { print }' "$TOOL" >"$MUT21"
if cmp -s "$TOOL" "$MUT21"; then
  bad "g21 the mode-clamp mutation could not be applied — k32 is not checking it"
else
  mk_box "$T/g21"; rm -f "$DUR/pi-keys.env"
  printf 'K=%s\n' "$SENTINEL" >"$LEG/pi-keys.env"; chmod 644 "$LEG/pi-keys.env"
  run_tool "$MUT21" --apply >/dev/null 2>&1
  _m21m="$(stat -c '%a' "$DUR/pi-keys.env" 2>/dev/null || stat -f '%Lp' "$DUR/pi-keys.env" 2>/dev/null || true)"
  [ "$_m21m" = "644" ] && ok "g21 WITHOUT the clamp pi-keys.env keeps the legacy 644 — k32 measures the clamp" \
    || bad "g21 the mutant still installed a private mode ($_m21m) — k32 is not measuring the clamp"
fi

# g22: remove the unit-chown refusal (round-4 F3) and k33 must redden — the swap lands with the wrong owner.
MUT22="$T/mutdir20/cell-home-migrate-unitown.sh"
mut_sub "$TOOL" "$MUT22" migrate_units 'if [ -n "$_own" ] && ! chown "$_own" "$tmpdir" 2>/dev/null; then' 'if false; then'
if cmp -s "$TOOL" "$MUT22"; then
  bad "g22 the unit-chown mutation could not be applied — k33 is not checking it"
else
  mk_box "$T/g22"
  _before22="$(cat "$UNITS/app.service")"
  PATH="$STUBCH:$PATH" CELL_HOME="$DUR" CELL_HOME_LEGACY="$LEG" CELL_HOME_MIGRATE_UNIT_DIRS="$UNITS" \
    CELL_HOME_MIGRATE_NO_RELOAD=1 bash "$MUT22" --apply >/dev/null 2>&1; _m22rc=$?
  [ "$_before22" != "$(cat "$UNITS/app.service")" ] \
    && ok "g22 WITHOUT the unit-chown refusal the rewrite IS swapped in (rc $_m22rc) — k33 measures the refusal" \
    || bad "g22 the mutant still left the unit untouched — k33 is not attributable to the refusal"
fi

# g23: silence the advisory's failed listing (round-4 F5) and k34b must redden.
MUT23="$T/mutdir20/cell-home-migrate-adv.sh"
mut_sub "$TOOL" "$MUT23" legacy_home_advisory 'if ! entries="$(ls -A "$HOME_LEGACY" 2>/dev/null)"; then' 'if false; then'
if cmp -s "$TOOL" "$MUT23"; then
  bad "g23 the advisory mutation could not be applied — k34b is not checking it"
else
  mk_box "$T/g23"; run_tool "$TOOL" --apply >/dev/null 2>&1
  printf 'note\n' >"$LEG/legacy-only.txt"; chmod 111 "$LEG"
  if ls -A "$LEG" >/dev/null 2>&1; then
    ok "g23 SKIPS honestly: this account can still list a mode-111 directory"
  else
    _out23="$(run_tool "$MUT23" --check)"
    case "$_out23" in *"CANNOT LIST"*) bad "g23 the mutant still stated it could not list" ;; *) ok "g23 WITHOUT the failed-listing line silence reads as 'nothing ungraded' — k34b measures it" ;; esac
  fi
  chmod 755 "$LEG" 2>/dev/null
fi

# g24: revert the per-level directory ownership (round-5 F1) and k35 must redden — the created chain stays
# root-owned while the run reports success.
mkdir -p "$T/mutdir24/lib"; cp "$HERE/lib/cell-home.sh" "$T/mutdir24/lib/cell-home.sh"
MUT24="$T/mutdir24/cell-home-migrate.sh"
mut_sub "$TOOL" "$MUT24" make_owned_dir 'chown "$DUR_OWNER" "$d" 2>/dev/null || return 3' ':'
if cmp -s "$TOOL" "$MUT24"; then
  bad "g24 the directory-ownership mutation could not be applied — k35 is not checking it"
else
  mk_box "$T/g24"; rm -rf "$DUR/.pi"
  env CELL_HOME="$DUR" CELL_HOME_LEGACY="$LEG" CELL_HOME_MIGRATE_UNIT_DIRS="$UNITS" \
      CELL_HOME_MIGRATE_NO_RELOAD=1 CELL_HOME_MIGRATE_FORCE_OWNER="4242:4242" \
      PATH="$STUBCHD:$STUBROOT:$PATH" bash "$MUT24" --apply >/dev/null 2>&1; _m24rc=$?
  [ "$_m24rc" = 0 ] && ok "g24 WITHOUT the per-level chown the run reports success (rc 0) — k35 measures it" \
    || bad "g24 the mutant still failed (rc $_m24rc) — k35 is not attributable to the per-level chown"
fi

# g25: drop the metacharacter separators from paths_in (round-5 F2) and k36 must redden — the redirect
# target is then never checked and the unit is written.
MUT25="$T/mutdir24/cell-home-migrate-paths.sh"
# (the mutation is on the need CLASS, because `awk -v` eats the backslash escapes in the separator set)
mut_sub "$TOOL" "$MUT25" paths_in 'if (sep == ">" || sep == "<") need = 2' 'if (sep == ">" || sep == "<") need = 1'
if cmp -s "$TOOL" "$MUT25"; then
  bad "g25 the paths_in mutation could not be applied — k36 is not checking it"
else
  mk_box "$T/g25"; mkdir -p "$DUR/logs"          # the DIRECTORY exists; the log FILE does not (normal)
  printf '[Service]\nEnvironment=HOME=%s\nExecStartPost=/bin/sh -c "echo x >>%s/logs/run.log"\n' "$LEG" "$LEG" >"$UNITS/redir.service"
  run_tool "$MUT25" --apply >/dev/null 2>&1; _m25rc=$?
  [ "$_m25rc" != 0 ] && ok "g25 WITHOUT the redirect-target class a normal redirect target is refused as 'missing' (rc $_m25rc) — k36c measures it" \
    || bad "g25 the mutant converged anyway — k36c is not measuring the need class"
fi

# g26: narrow the content leg back to the HOME/CELL_HOME names (round-5 F3) and k37 must redden.
MUT26="$T/mutdir24/cell-home-migrate-names.sh"
mut_sub "$TOOL" "$MUT26" volatile_home_assignments 'if (leg != "" && (val == leg || index(val, leg "/") == 1))' 'if (0 && (val == leg || index(val, leg "/") == 1))'
if cmp -s "$TOOL" "$MUT26"; then
  bad "g26 the content-leg mutation could not be applied — k37 is not checking it"
else
  mk_box "$T/g26"
  run_tool "$TOOL" --apply >/dev/null 2>&1              # converge first, so only ENV_FILE can drift
  printf 'export HOME=%s\nENV_FILE=%s/keys.env\n' "$DUR" "$LEG" >"$DUR/keys.env"
  run_tool "$MUT26" --check >/dev/null 2>&1; _m26rc=$?
  [ "$_m26rc" = 0 ] && ok "g26 WITHOUT value grading an ENV_FILE pointing at the legacy home reads 'one home' (0) — k37 measures it" \
    || bad "g26 the mutant still reported drift (rc $_m26rc) — k37 is not measuring value grading"
fi

# g27: make `is_cell_home` accept EVERY home (the round-2 state, where the exclusion did not exist) and
# i9-i11 must redden. Without this row the (i-2) arms would be green on a tree whose exclusion had been
# widened to nothing — a guard that refuses every converged cell that carries a vendor unit.
MUT27="$T/mutdir25/cell-home-migrate-users.sh"
mkdir -p "$T/mutdir25/lib"; cp "$HERE/lib/cell-home.sh" "$T/mutdir25/lib/cell-home.sh"
# the whole predicate, replaced by a constant "every home is a cell home" (awk, not `sed c\`: the
# replacement is multi-line and BSD sed spells `c\` differently from GNU sed)
awk '/^is_cell_home\(\) \{$/ { print "is_cell_home() { return 0; }"; skip = 1; next }
     skip && /^\}$/ { skip = 0; next }
     !skip' "$TOOL" >"$MUT27"
if cmp -s "$TOOL" "$MUT27"; then
  bad "g27 the exclusion mutation could not be applied — (i-2) is not checking the account exclusion"
else
  mk_box "$T/g27"
  plant_vendor "$UNITS" "$T/g27/vendor"
  VSTUB27="$T/vstub27"; vend_stub "$VSTUB27" "$DUR"
  env -u CELL_HOME PATH="$VSTUB27:$PATH" CELL_HOME_LEGACY="$LEG" CELL_HOME_MIGRATE_UNIT_DIRS="$UNITS" \
    CELL_HOME_MIGRATE_NO_RELOAD=1 bash "$MUT27" --check >/dev/null 2>&1; _m27rc=$?
  [ "$_m27rc" = 3 ] && ok "g27 WITHOUT the account exclusion a vendor account (home / or /nonexistent) refuses a converged box (rc 3) — (i-2) measures the EXCLUSION" \
    || bad "g27 the no-exclusion mutant answered $_m27rc — (i-2) is not measuring the exclusion"
fi

# g28: empty the population `unit_users` reads (the round-2 narrowing, `$REPOINT_FILES` — empty on a
# converged box) and (i-3) must redden. This is the row that makes i15 a measurement of the VACUITY
# rather than an assertion that happens to hold: with the population emptied, the converged fixture's
# foreign derivation is accepted again and the credential half acts on it.
MUT28="$T/mutdir25/cell-home-migrate-vacuous.sh"
# the population expression itself, swapped for the converged-box-empty one
sed 's#^\$GRADED_FILES$##' "$TOOL" >"$MUT28"
if cmp -s "$TOOL" "$MUT28"; then
  bad "g28 the vacuity mutation could not be applied — (i-3) is not checking the population"
else
  mk_box "$T/g28"
  run_tool "$MUT28" --apply >/dev/null 2>&1            # converge with the mutant itself (explicit CELL_HOME)
  rm -f "$DUR/keys.env" "$DUR/.pi/agent/auth.json"
  # ⛔ THE LEGACY `keys.env` MUST STOP NAMING A HOME FIRST (review P2, measured). `mk_box` writes it as
  # `export HOME=$DUR`, and under the mutant's FOREIGN derivation `$DUR` is not the durable home — so
  # `report_env_file` refuses the copy on the volatile-root rule and the mutant answers 1, not the 0 this
  # row asserts. That made the arm measure the CONTENT rule instead of the population read it claims
  # (green on macOS, where `$T` is under `/var/folders`; RED on Linux). Strip the assignment: with
  # nothing to refuse, the only thing left that can make the run converge is the emptied population.
  printf 'DEEPSEEK_API_KEY=%s\n' "$SENTINEL" >"$LEG/keys.env"
  chmod 600 "$LEG/keys.env"
  mkdir -p "$T/g28/inv-home" "$T/g28/stub"
  printf '#!/bin/sh\ncase "$1" in -u) echo 1001 ;; -un) echo ubuntu ;; *) exit 1 ;; esac\n' >"$T/g28/stub/id"
  printf '#!/bin/sh\ncase "$1:$2" in\n  passwd:cmux) echo "cmux:x:1000:1000::%s:/bin/bash" ;;\n  passwd:ubuntu) echo "ubuntu:x:1001:1001::%s:/bin/bash" ;;\nesac\n' "$DUR" "$T/g28/inv-home" >"$T/g28/stub/getent"
  chmod +x "$T/g28/stub/id" "$T/g28/stub/getent"
  env -u CELL_HOME PATH="$T/g28/stub:$PATH" CELL_HOME_LEGACY="$LEG" CELL_HOME_MIGRATE_UNIT_DIRS="$UNITS" \
    CELL_HOME_MIGRATE_NO_RELOAD=1 bash "$MUT28" --apply >/dev/null 2>&1; _m28rc=$?
  [ "$_m28rc" = 0 ] && ok "g28 WITH the population emptied a converged box ACCEPTS the foreign derivation (rc 0) — i15 measures the VACUITY" \
    || bad "g28 the emptied-population mutant answered $_m28rc — i15 is not measuring the population read"
fi

# g29: revert the population to the INVOKING home's user-unit dir (the pre-fix shape) and m1 must redden —
# i.e. m1 measures WHICH home the population is resolved from, not a fixture that happens to be graded.
MUT29="$T/mutdir26/cell-home-migrate-homepop.sh"
mkdir -p "$T/mutdir26/lib"; cp "$HERE/lib/cell-home.sh" "$T/mutdir26/lib/cell-home.sh"
# the durable-home candidate becomes a no-op; the `$HOME` candidate below it is untouched, so the mutant
# resolves exactly the population the tool resolved before review F1.
sed 's#\[ -n "${HOME_DURABLE:-}" \].*systemd/user"#:#' "$TOOL" >"$MUT29"
if cmp -s "$TOOL" "$MUT29"; then
  bad "g29 the population mutation could not be applied — m1 is not checking WHICH home the population comes from"
else
  # a FRESH box: `run_nodirs` reads $DUR/$LEG at CALL time, and the boxes above have moved them.
  mk_box "$T/g29"
  cp "$LEG/.pi/agent/auth.json" "$DUR/.pi/agent/auth.json"; chmod 600 "$DUR/.pi/agent/auth.json"
  mkdir -p "$DUR/.config/systemd/user"
  printf '[Service]\nEnvironment=HOME=%s\nExecStart=/bin/echo hi\n' "$LEG" >"$DUR/.config/systemd/user/legacyunit.service"
  _out="$(run_nodirs "$MUT29" --check)"; _m29rc=$?
  [ "$_m29rc" = 0 ] && ok "g29 WITH only the invoker's home in the population the durable home's user unit reads 'one home' (0) — m1 measures the resolution" \
    || bad "g29 the invoker-home mutant still reported drift (rc $_m29rc) — m1 is not measuring the resolution"
fi

# g30: put the systemd-CREATED directories back into the existence requirement and m5 must redden — i.e.
# m5 measures the SCOPE of the guard rather than a fixture that could never have been refused.
MUT30="$T/mutdir26/cell-home-migrate-statedir.sh"
mut_sub "$TOOL" "$MUT30" unit_scan 'StateDirectory|CacheDirectory|LogsDirectory|RuntimeDirectory) grade=0 ;;' 'NoSuchDirectiveX) grade=0 ;;'
if cmp -s "$TOOL" "$MUT30"; then
  bad "g30 the created-directory mutation could not be applied — m5 is not checking the guard's scope"
else
  mk_box "$T/g30"
  printf '[Service]\nStateDirectory=%s/state\nExecStart=/bin/echo hi\n' "$LEG" >"$UNITS/statedir.service"
  run_tool "$MUT30" --apply >/dev/null 2>&1; _m30rc=$?
  [ "$_m30rc" != 0 ] && ok "g30 WITH the created directories graded by LOCATION a legitimate StateDirectory= unit is refused (rc $_m30rc) — m5 measures the scope" \
    || bad "g30 the mutant converged anyway — m5 is not measuring the exclusion"
fi

# g31: drop the exec-prefix strip from `paths_in` (the pre-fix shape) and m8 must redden — i.e. m8
# measures the prefix grading, not the existence guard as a whole (which g1 already covers).
MUT31="$T/mutdir26/cell-home-migrate-prefix.sh"
cp "$HERE/lib/cell-home.sh" "$T/mutdir26/lib/cell-home.sh"
# ⛔ THE MUTATION TARGET IS THE LOOP HEADER, NOT THE OLD ONE-LINER (measured): the `-`-exemption fix
# turned the single-line strip into a block (it must also RECORD that a `-` was present), so the pre-fix
# spelling `while (substr(tok, 1, 1) ~ /[-+!@]/) tok = substr(tok, 2)` no longer exists and this mutant
# could not be applied at all — the arm silently stopped proving anything. `while (0)` leaves the body
# dead, which IS the pre-fix behaviour: a prefixed token does not start with `/` and is dropped.
mut_sub "$TOOL" "$MUT31" paths_in 'while (substr(tok, 1, 1) ~ /[-+!@]/) {' 'while (0) {'
if cmp -s "$TOOL" "$MUT31"; then
  bad "g31 the exec-prefix mutation could not be applied — m8 is not checking the prefix strip"
else
  mk_box "$T/g31"; run_tool "$MUT31" --apply >/dev/null 2>&1
  rm -f "$DUR/harness/run.sh"
  printf '[Service]\nEnvironment=HOME=%s\nExecStart=+%s/harness/run.sh\n' "$LEG" "$LEG" >"$UNITS/p.service"
  run_tool "$MUT31" --apply >/dev/null 2>&1; _m31rc=$?
  if [ "$_m31rc" = 0 ] && grep -q "ExecStart=+$DUR/harness/run.sh" "$UNITS/p.service"; then
    ok "g31 WITHOUT the prefix strip the tool DOES write a unit whose exec target is missing (rc 0) — m8 measures the prefix"
  else
    bad "g31 the mutant still refused (rc $_m31rc) — m8 is not measuring the prefix strip"
  fi
fi

# g32: drop the `-` EXEMPTION from `paths_in` (the shape B-P1 shipped before review P1-1) and m12 must
# redden — i.e. m12 measures the exemption, not the existence guard as a whole (which g1 covers).
MUT32="$T/mutdir26/cell-home-migrate-dashopt.sh"
cp "$HERE/lib/cell-home.sh" "$T/mutdir26/lib/cell-home.sh"
mut_sub "$TOOL" "$MUT32" paths_in 'if (dash && dir ~ /^(EnvironmentFile|WorkingDirectory|ReadWritePaths|ReadOnlyPaths)$/) need = 3' 'if (0) need = 3'
if cmp -s "$TOOL" "$MUT32"; then
  bad "g32 the optional-target mutation could not be applied — m12 is not checking the '-' exemption"
else
  mk_box "$T/g32"; run_tool "$MUT32" --apply >/dev/null 2>&1
  rm -f "$DUR/f.env"
  printf '[Service]\nEnvironment=HOME=%s\nEnvironmentFile=-%s/f.env\nExecStart=/bin/echo hi\n' "$LEG" "$LEG" >"$UNITS/opt.service"
  run_tool "$MUT32" --apply >/dev/null 2>&1; _m32rc=$?
  [ "$_m32rc" != 0 ] && ok "g32 WITHOUT the '-' exemption an optional EnvironmentFile whose durable twin is absent is REFUSED (rc $_m32rc) — m12 measures the exemption" \
    || bad "g32 the mutant converged anyway — m12 is not measuring the '-' exemption"
fi

printf '\n── (h) argument handling ────────────────────────────────────────────────────────────\n'
run_tool "$TOOL" --nonsense >/dev/null 2>&1 && bad "h1 an unknown argument is not refused" || ok "h1 an unknown argument is refused"
run_tool "$TOOL" --help >/dev/null 2>&1 && ok "h2 --help exits 0" || bad "h2 --help exits non-zero"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ] || exit 1
exit 0
