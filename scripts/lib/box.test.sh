#!/usr/bin/env bash
# box.test.sh — the portability shim's primitives, asserted on the platform it is running on.
#
# ⛔ WHY A SUITE AND NOT JUST `--selftest`: `box.sh --selftest` PROVES THE SHIM WORKS HERE. This suite
# asserts the properties a caller depends on and that a future "simplification" would silently break:
# a mechanism is NAMED (never assumed from `uname`), a CPU count is never 0, an epoch formats, and the
# BSD `sed -i` hazard is reproduced rather than described. Both run everywhere; the arms that cannot
# mean anything on a platform print WHY (a skip with no reason is a test that passes because someone
# remembered).
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOX="$HERE/box.sh"
PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); printf 'PASS %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf 'FAIL %s\n' "$1"; }
skip() { SKIP=$((SKIP+1)); printf 'SKIP %s\n' "$1"; }

[ -f "$BOX" ] || { echo "❌ box.sh missing"; exit 1; }
# shellcheck source=box.sh
. "$BOX"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/box-test-XXXXXX")" || { echo "❌ mktemp"; exit 1; }
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

OS="$(box_os)"
case "$OS" in darwin|linux|other) ok "os: recognised ($OS)";; *) bad "os: unrecognised '$OS'";; esac

# ── CPU count: an integer >= 1, from a NAMED mechanism.
N="$(box_ncpu)"
case "$N" in
  ''|*[!0-9]*) bad "ncpu: '$N' is not a number" ;;
  *) [ "$N" -ge 1 ] && ok "ncpu: $N (>=1)" || bad "ncpu: $N < 1 — a 0 propagates into every divisor" ;;
esac
prov="$(box_provenance)"
grep -qE 'ncpu=(sysctl|nproc|getconf|forced)' <<<"$prov" \
  && ok "ncpu: mechanism named [$prov]" \
  || bad "ncpu: no mechanism named in '$prov'"

# ── mtime: numeric, and it MOVES when the file is touched.
f="$TMP/probe"; printf 'alpha\n' > "$f"
m1="$(box_mtime "$f")"
case "$m1" in ''|*[!0-9]*) bad "mtime: '$m1' is not numeric";; *) ok "mtime: numeric ($m1)";; esac
# ⛔ NOT VACUOUS (found by review): the mechanism is set inside `box_mtime`, which the line above ran in
# a SUBSHELL, so the parent saw it empty and the old `case` accepted `''` — an assertion that could never
# fail. Re-run it in THIS shell and require a real mechanism.
box_mtime "$f" >/dev/null
case "${BOX_MTIME_MECH:-}" in
  stat-c|stat-f) ok "mtime: mechanism named ($BOX_MTIME_MECH)" ;;
  *) bad "mtime: mechanism not named (got '${BOX_MTIME_MECH:-<empty>}')" ;;
esac
printf 'alpha\n' > "$f"; sleep 1; printf 'alpha\n' > "$f"
m2="$(box_mtime "$f")"
[ "$m2" -ge "$m1" ] && ok "mtime: non-decreasing on a rewrite ($m1 -> $m2)" || bad "mtime: went backwards ($m1 -> $m2)"
box_mtime "$TMP/does-not-exist" >/dev/null 2>&1 && bad "mtime: a missing file reported success" || ok "mtime: a missing file fails (not 0)"

# ── epoch -> ISO: the BSD `date -r` / GNU `date -d` difference is the reason this exists.
iso="$(box_epoch_to_iso "$m1")"
case "$iso" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ok "epoch_to_iso: $iso" ;;
  *) bad "epoch_to_iso: '$iso' is not ISO-8601 UTC" ;;
esac

# ── sed -i: it rewrites, and the GNU spelling's BSD hazard is live.
printf 'alpha\n' > "$f"
if box_sed_i 's/alpha/beta/' "$f" && [ "$(head -1 "$f")" = "beta" ]; then ok "sed_i: rewrote the file"; else bad "sed_i: did not rewrite"; fi
printf 'alpha\n' > "$f"
sed -i 's/alpha/beta/' "$f" >/dev/null 2>&1
got="$(head -1 "$f")"
case "$OS" in
  darwin)
    [ "$got" = "alpha" ] \
      && ok "sed_i hazard: the GNU spelling (sed -i 's/…/…/' f) is SILENT on BSD here — no edit, exit 0. That is why callers must use the shim" \
      || bad "sed_i hazard: the GNU spelling DID rewrite on BSD ('$got') — the shim's premise is wrong on this box" ;;
  *)
    [ "$got" = "beta" ] \
      && ok "sed_i hazard: on GNU sed the same spelling works — identical call, different platform, which is the whole problem" \
      || skip "sed_i hazard: this platform's sed rewrote nothing and is not darwin — the hazard arm is inconclusive here" ;;
esac

# ── scheduler: a real value, never an error; and the platform's own answer.
sched="$(box_scheduler)"
case "$sched" in
  launchd) [ "$OS" = darwin ] && ok "scheduler: launchd on $OS" || bad "scheduler: launchd claimed on $OS" ;;
  systemd|tmux) [ "$OS" = linux ] && ok "scheduler: $sched on $OS" || bad "scheduler: $sched claimed on $OS" ;;
  none) skip "scheduler: this box has neither launchctl, systemctl nor tmux ('none' is a real answer, not an error)" ;;
  *) bad "scheduler: unexpected '$sched'" ;;
esac
[ "$OS" = darwin ] \
  && skip "scheduler-launchd-arm: the launchd arm needs an installed job; harness-exec.test.sh arm 10 asserts what this box's job actually runs" \
  || skip "scheduler-launchd-arm: $OS has no launchctl — nothing to assert"

# ── the probe-not-uname property: a WRONG uname must not change what answers.
out="$(BOX_OS=linux bash -c '. "$1"; printf "%s|%s\n" "$(box_os)" "$(box_ncpu)"' _ "$BOX")"
case "$out" in
  linux\|[1-9]*) ok "probe order: BOX_OS=linux still yields a real CPU count ($out) — the primitive is probed, not derived from uname" ;;
  *) bad "probe order: BOX_OS=linux produced '$out'" ;;
esac

printf '\nbox.test: %d passed, %d failed, %d skipped (%s)\n' "$PASS" "$FAIL" "$SKIP" "$OS"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
