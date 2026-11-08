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
case "$_out" in *"not the home of the account the graded units run as"*) ok "i5 …naming the conflict, so the operator knows which home to pass" ;; *) bad "i5 the conflict is not named" ;; esac
# …and the SAME box converges when the operator names the home (an explicit CELL_HOME is always honoured).
env -u CELL_HOME PATH="$STUBACCT:$PATH" CELL_HOME="$T/otherhome" CELL_HOME_LEGACY="$LEG" CELL_HOME_MIGRATE_UNIT_DIRS="$UNITS" \
  CELL_HOME_MIGRATE_NO_RELOAD=1 bash "$TOOL" --check >/dev/null 2>&1
[ "$?" != 3 ] && ok "i6 …while an explicit CELL_HOME for that account is honoured (not refused)" \
  || bad "i6 an explicit CELL_HOME was refused too — the guard would block the sanctioned fix"

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
sed 's#^    case "\$line" in \[A-Za-z\]\*) dir="\${line%%=\*}" ;; \*) dir="\$cont" ;; esac#    case "$line" in [A-Za-z]*) dir="${line%%=*}" ;; *) dir="" ;; esac#' "$HERE/cell-home-migrate.sh" >"$T/mutdir5/cell-home-migrate.sh"
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
sed -e 's#^    if is_comment "\$line"; then continue; fi#    if is_comment "$line"; then cont=""; continue; fi#' "$TOOL" \
  | awk 'index($0, "[A-Za-z]*) cont=") > 0 { print "          : ;;"; next } { print }' >"$MUT8"
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

printf '\n── (h) argument handling ────────────────────────────────────────────────────────────\n'
run_tool "$TOOL" --nonsense >/dev/null 2>&1 && bad "h1 an unknown argument is not refused" || ok "h1 an unknown argument is refused"
run_tool "$TOOL" --help >/dev/null 2>&1 && ok "h2 --help exits 0" || bad "h2 --help exits non-zero"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ] || exit 1
exit 0
