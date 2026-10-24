#!/usr/bin/env bash
# disk-reaper-classes.test.sh — the two classes #2542 measured, and the arms that make them safe.
#
# Run: bash scripts/disk-reaper-classes.test.sh
# Exits 0 when ALL assertions pass, 1 on any failure.
#
# ⛔ EVERY CASE IS MUTATION-CHECKED. A test that passes against a broken script proves nothing, so each
# case runs TWICE: once against the real owner (must PASS) and once against a MUTANT of the same file
# with that case's arm neutered (must FAIL). If a mutation cannot be applied — the source line moved —
# the suite says so and counts it a failure, because a stale mutation is a case that has silently
# stopped checking anything.
#
# COVERAGE — the five arms the brief names, one case each:
#   A  an OLD directory with a LIVE CWD inside it is KEPT and NAMED — while an identical old
#      directory in the same run is reaped, so the witness is the only difference.
#      Mutant: `if lp_path_held …` -> `if false` (the arm deleted).
#   B  an OLD directory with NO live cwd is REAPED, and the reclaim is reported as a **df delta** by
#      the entry point (not a `du` sum) — driven through `disk-reaper.sh --only worktree --apply`.
#      Mutant: `if remove_one …` -> `if false` (the removal arm deleted).
#   C  with the PROCESS LIST UNREADABLE the sweep is SKIPPED and REPORTS THE SKIP: exit 3, nothing
#      removed, `SKIP reason=census-unreadable` on stdout.
#      Mutant: `if ! lp_census …` -> `if false` (the fail-closed arm deleted: it then reaps blind).
#   D  the sha pinned in `.agent-infra-stamp.json` is NEVER reaped, even when old and apparently idle
#      — by NAME (`<sha12>`) and by PATH (a directory under the stamped harness path) — while a
#      sibling candidate in the same run IS reaped, so the pin is not a blanket refusal.
#      Mutant: `if pinned …` -> `if false`.
#   E  duplicate-install KEEPS THE LAST COPY: the newest copy is never a candidate, a copy a live
#      listener sits in is kept and named, and only the provably-idle surplus copy is removed.
#      Mutant: `[ "$c" = "$newest" ]` -> `[ "$c" = "__never__" ]` (the keep-newest arm deleted).
#
# Hermetic: every fixture is under $T, HOME is redirected, both owners' state/lock/log dirs are under
# $T, and every scratch root is an explicit `$T/...` path. NOTHING here can read or write the real
# box's `/tmp` — a suite that can delete outside its fixture is not a suite (measured: the first
# version of the abandoned-worktree arm, driven by the pre-existing suite before it scoped its roots,
# reaped four of this box's own abandoned checkouts in `--apply`).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAPER="$HERE/disk-reaper.sh"
AW_OWNER="$HERE/reap-abandoned-worktrees.sh"
DI_OWNER="$HERE/reap-duplicate-installs.sh"
LIVE_LIB="$HERE/lib/live-paths.sh"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ✅ %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  ❌ %s\n' "$1"; }
# `case_check` is used INSIDE a case (which runs in a subshell): it prints and returns, and the case's
# own failure count decides the subshell's exit status. It deliberately does not touch PASS/FAIL —
# the OUTER runner counts one line per case, and a mutant run must never inflate the real tally.
CASE_FAIL=0
case_check() { # <0|1> <message>
    if [ "$1" = 0 ]; then printf '     · %s\n' "$2"; return 0; fi
    printf '     ✗ %s\n' "$2"; CASE_FAIL=$((CASE_FAIL + 1)); return 1
}
expect_pass() { # <label> <fn> [args...]
    local label="$1"; shift
    if ( CASE_FAIL=0; "$@" ); then ok "$label"; else bad "$label"; fi
}
expect_fail() { # <label> <fn> [args...] — the mutant MUST be caught
    local label="$1"; shift
    if ( CASE_FAIL=0; "$@" ); then
        bad "$label — MUTANT SURVIVED: the arm is not covered by this case"
    else
        ok "$label"
    fi
}

for f in "$REAPER" "$AW_OWNER" "$DI_OWNER" "$LIVE_LIB"; do
    [ -f "$f" ] || { printf 'FATAL: %s missing — this suite tests the #2542 classes and their owners\n' "$f"; exit 1; }
done

T="$(mktemp -d "${TMPDIR:-/tmp}/dr-classes-test.XXXXXX")"
T="$(cd "$T" && pwd -P)"
SLEEPERS=""
cleanup() {
    local p
    for p in $SLEEPERS; do kill "$p" 2>/dev/null; done
    rm -rf "$T"
}
trap cleanup EXIT

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
REAL_GIT="$(command -v git)"
export HOME="$T/home"; mkdir -p "$HOME"

# ── fixtures ────────────────────────────────────────────────────────────────────────────────────
# newbase <letter> — a UNIQUE fixture dir per invocation. Every case runs TWICE (real + mutant) and a
# shared fixture makes the second run silently vacuous: the branch already exists, `git worktree add`
# fails, and assertions about a directory that was never created pass for the wrong reason (measured).
newbase() { mktemp -d "$T/$1.XXXXXX"; }

mk_repo() { # mk_repo <base> -> a repo with one commit and NO GitHub remote (the open-PR gate is n/a)
    local r="$1/repo"
    mkdir -p "$r"
    "$REAL_GIT" -C "$r" init -q -b main >/dev/null 2>&1 || "$REAL_GIT" -C "$r" init -q
    mkdir -p "$r"
    printf 'base\n' >"$r/f.txt"
    # `blob.bin` is IGNORED so a case can put real bytes in a worktree — to make a reclaim visible in
    # `df` — without the dirty dial (correctly) refusing to touch it.
    printf 'blob.bin\n' >"$r/.gitignore"
    "$REAL_GIT" -C "$r" add f.txt .gitignore
    "$REAL_GIT" -C "$r" commit -qm init
    printf '%s\n' "$r"
}

mk_linked_wt() { # mk_linked_wt <repo> <scratch-root> <name> <branch> -> worktree path
    local r="$1" root="$2" n="$3" b="$4"
    mkdir -p "$root"
    "$REAL_GIT" -C "$r" worktree add -q "$root/$n" -b "$b" >/dev/null 2>&1
    printf '%s' "$root/$n"
}

# wait_cwd <pid> <path> — poll until the process's cwd is really inside <path>. Returns 1 if it never
# is: a witness that never landed must FAIL the case, not silently make it a no-op (measured: an
# unpolled start raced the census once and turned a KEEP into a REAP).
wait_cwd() { # <pid> <dir-it-must-be-cwd'd-in>
    local pid="$1" want="$2" i got
    for i in $(seq 1 40); do
        if [ -d /proc ]; then
            got="$(readlink "/proc/$pid/cwd" 2>/dev/null)"
        elif command -v lsof >/dev/null 2>&1; then
            # The owners carry a `lsof` census arm for exactly this platform, so the witness must not
            # be Linux-only: a witness that cannot run makes cases A and E fail on the OS the arm is
            # for, and a suite that only runs where `/proc` exists cannot vouch for the other arm.
            got="$(lsof -a -d cwd -p "$pid" -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)"
        else
            got=""
        fi
        [ "$got" = "$want" ] && return 0
        sleep 0.25
    done
    return 1
}

age_path() { # age_path <path> <minutes>
    local when=$(( $(date +%s) - $2 * 60 ))
    touch -d "@$when" "$1" 2>/dev/null || touch -t "$(date -r "$when" +%Y%m%d%H%M 2>/dev/null || printf 202001010000)" "$1" 2>/dev/null || true
}

# apply_mutation <src> <dest> <sed-expression> — write the mutant; FAIL LOUDLY when nothing changed.
apply_mutation() {
    local src="$1" dest="$2" expr="$3"
    mkdir -p "$(dirname "$dest")"
    ln -sfn "$HERE/lib" "$(dirname "$dest")/lib"
    sed "$expr" "$src" >"$dest" 2>/dev/null || return 1
    cmp -s "$src" "$dest" && return 1              # the expression matched nothing: a STALE mutation
    bash -n "$dest" 2>/dev/null || return 1        # a syntax error is not a mutation of behaviour
    chmod +x "$dest"
    return 0
}

# ── A: an old directory a live process sits in is KEPT and NAMED ────────────────────────────────
case_a() { # <owner-script>
    local owner="$1" base root repo live idle pid out rc
    base="$(newbase a)"; root="$base/scratch"
    repo="$(mk_repo "$base")"
    live="$(mk_linked_wt "$repo" "$root" old-live feat/a-live)"
    idle="$(mk_linked_wt "$repo" "$root" old-idle feat/a-idle)"
    age_path "$live" 400; age_path "$idle" 400
    # A REAL process whose cwd is inside `old-live` — the witness an argv scan would miss.
    ( cd "$live" && exec sleep 180 ) &
    pid=$!; SLEEPERS="$SLEEPERS $pid"
    case_check "$(wait_cwd "$pid" "$live" && echo 0 || echo 1)" "the witness process is cwd'd inside the directory"
    out="$(REAP_AW_STATE_DIR="$base/state" REAP_AW_ROOTS="$root" bash "$owner" --apply 2>&1)"; rc=$?
    [ -n "${DRC_DEBUG:-}" ] && printf '%s\n' "$out" >&2
    case_check "$([ "$rc" = 0 ] && echo 0 || echo 1)" "the pass exits 0 (rc=$rc)"
    case_check "$([ -d "$live" ] && echo 0 || echo 1)" "the OLD directory a live process sits in SURVIVED"
    case_check "$(grep -qF "KEPT   $live reason=live-cwd" <<<"$out" && echo 0 || echo 1)" \
               "and it is KEPT BY NAME with the reason (reason=live-cwd)"
    case_check "$(grep -qF "cwd pid $pid" <<<"$out" && echo 0 || echo 1)" \
               "the KEEP line names the WITNESS (cwd pid $pid), not just a verdict"
    case_check "$([ ! -d "$idle" ] && echo 0 || echo 1)" \
               "an IDENTICAL old directory with no live cwd in the same run WAS reaped (the witness is the only difference)"
    kill "$pid" 2>/dev/null
    return $((CASE_FAIL > 0))
}

# ── B: an old directory with no live cwd is REAPED, and the pass reports a df DELTA ─────────────
case_b() { # <owner-script> <entry-point>
    local owner="$1" pass="$2" base root repo wt out rc status n
    base="$(newbase b)"; root="$base/scratch"
    repo="$(mk_repo "$base")"
    wt="$(mk_linked_wt "$repo" "$root" old-idle feat/b-idle)"
    # 64 MB of real bytes so the reclaim is visible in `df` (whose granularity is 1 MB) above the
    # noise of a box other lanes are writing to. Ignored, so the dirty dial does not (correctly) hold.
    # ⛔ WRITE FIRST, AGE SECOND: creating a file updates the DIRECTORY's mtime, so an earlier
    # `age_path` was silently undone and the candidate read as 0 minutes old.
    dd if=/dev/zero of="$wt/blob.bin" bs=1M count=64 >/dev/null 2>&1
    age_path "$wt" 400
    # The REGISTERED-worktree owner is stubbed to a no-op: this case measures the abandoned arm's
    # accounting through the entry point, and that owner's own policy (clean/reachable/aged-by-HEAD)
    # would otherwise reap the very fixture the abandoned arm is being measured on, making the df
    # delta ambiguous. It is a stub, not a weakening: case A covers the arm's own behaviour.
    mkdir -p "$base/bin"
    printf '#!/usr/bin/env bash\nexit 0\n' >"$base/bin/pi-reap-worktrees.sh"
    chmod +x "$base/bin/pi-reap-worktrees.sh"
    out="$(DISK_REAPER_STATE_DIR="$base/state" REAP_AW_ROOTS="$root" REAP_DI_ROOTS="$base/no-dups" \
           WORKTREE_REAPER="$base/bin/pi-reap-worktrees.sh" \
           ABANDONED_WT_REAPER="$owner" \
           bash "$pass" --apply --only worktree --repo "$repo" 2>&1)"; rc=$?
    [ -n "${DRC_DEBUG:-}" ] && printf 'B rc=%s\n%s\n' "$rc" "$out" >&2
    status="$(cat "$base/state/disk-reaper.status" 2>/dev/null)"
    n="$(printf '%s' "$out" | sed -n 's/.*class=worktree .*freed_df=\([0-9][0-9]*\)MB.*/\1/p' | head -1)"
    case_check "$([ ! -d "$wt" ] && echo 0 || echo 1)" "the old, idle directory WAS reaped"
    case_check "$(grep -qF 'class=worktree' <<<"$out" && echo 0 || echo 1)" \
               "and the class reported itself (rc=$rc)"
    case_check "$(grep -qF '(df delta)' <<<"$out" && echo 0 || echo 1)" \
               "the report is labelled a df delta, never a du sum"
    case_check "$(grep -q '^freed_mb_worktree=[0-9][0-9]*$' <<<"$status" && echo 0 || echo 1)" \
               "the pass record carries a MEASURED freed_mb_worktree (not 'unmeasured')"
    case_check "$([ -n "$n" ] && echo 0 || echo 1)" "the class line carries a numeric freed_df"
    # ⛔ THE MAGNITUDE IS NOT ASSERTED. This is a shared box: another lane writing 4 GB during the
    # pass moved the same counter by 4,160 MB in one measured run. What the case pins is that the
    # reclaim is expressed as a df DELTA at all (a `du` sum would be a different label entirely) and
    # that the record's value is a measured number — not `unmeasured`.
    case_check "$([ -n "$n" ] && [ "$n" -ge 1 ] && echo 0 || echo 1)" \
               "and the reclaim is visible in df (freed_df=${n:-?}MB; magnitude not asserted on a shared box)"
    return $((CASE_FAIL > 0))
}

# ── C: an unreadable process list SKIPS the sweep and says so ───────────────────────────────────
case_c() { # <owner-script>
    local owner="$1" base root repo wt out rc
    base="$(newbase c)"; root="$base/scratch"
    repo="$(mk_repo "$base")"
    wt="$(mk_linked_wt "$repo" "$root" old-idle feat/c-idle)"
    age_path "$wt" 400
    out="$(LP_CENSUS_UNAVAILABLE=1 REAP_AW_STATE_DIR="$base/state" REAP_AW_ROOTS="$root" \
           bash "$owner" --apply 2>&1)"; rc=$?
    [ -n "${DRC_DEBUG:-}" ] && printf 'C rc=%s\n%s\n' "$rc" "$out" >&2
    case_check "$([ "$rc" = 3 ] && echo 0 || echo 1)" "the pass FAILS CLOSED (exit 3, got $rc)"
    case_check "$([ -d "$wt" ] && echo 0 || echo 1)" "NOTHING was reaped on a census it could not read"
    case_check "$(grep -qF 'SKIP reason=census-unreadable' <<<"$out" && echo 0 || echo 1)" \
               "and it REPORTS the skip (SKIP reason=census-unreadable)"
    case_check "$(grep -qF 'nothing was reaped' <<<"$out" && echo 0 || echo 1)" \
               "the skip says in words that nothing was reaped"
    return $((CASE_FAIL > 0))
}

# ── D: the pinned sha is never reaped, even when old and apparently idle ────────────────────────
case_d() { # <owner-script>
    local owner="$1" base root repo byname bypath byalias free out rc sha stamp
    base="$(newbase d)"; root="$base/scratch"
    repo="$(mk_repo "$base")"
    sha="0123456789abcdef0123456789abcdef01234567"
    byname="$(mk_linked_wt "$repo" "$root" "${sha:0:12}" feat/d-sha)"
    bypath="$(mk_linked_wt "$repo" "$root" pinned feat/d-path)"
    free="$(mk_linked_wt "$repo" "$root" free feat/d-free)"
    # ⛔ A STAMP THAT NAMES ITS TREE THROUGH A SYMLINK. Candidates are compared by PHYSICAL path, so a
    # stamp spelling that goes via a link matched nothing: on macOS (`/tmp` -> `/private/tmp`) the
    # default `--root /tmp` makes EVERY candidate `/private/tmp/…`, so the path arm of the pin was dead
    # by construction there — and the pinned checkout was reaped.
    # The alias points at the CANDIDATE itself: its raw spelling shares no prefix with the physical
    # path, so only canonicalisation can protect it — and it covers nothing else (an alias to the
    # scratch ROOT would pin every sibling and the "free" assertion would stop discriminating).
    byalias="$(mk_linked_wt "$repo" "$root" pinned-via-alias feat/d-alias)"
    ln -s "$byalias" "$base/alias-worktree"
    age_path "$byalias" 900
    age_path "$byname" 900; age_path "$bypath" 900; age_path "$free" 900
    stamp="$base/.agent-infra-stamp.json"
    mkdir -p "$base"
    printf '{\n  "version": 1,\n  "surface": "cloud-cell",\n  "harness": "%s",\n  "harness_alias": "%s",\n  "commit": "%s"\n}\n' \
        "$bypath/scripts" "$base/alias-worktree" "$sha" >"$stamp"
    out="$(REAP_AW_STAMP="$stamp" REAP_AW_STATE_DIR="$base/state" REAP_AW_ROOTS="$root" \
           bash "$owner" --apply 2>&1)"; rc=$?
    [ -n "${DRC_DEBUG:-}" ] && printf 'D rc=%s\n%s\n' "$rc" "$out" >&2
    case_check "$([ -d "$byname" ] && echo 0 || echo 1)" "the directory NAMED after the pinned sha SURVIVED"
    case_check "$(grep -qF "KEPT   $byname reason=pinned" <<<"$out" && echo 0 || echo 1)" \
               "and is KEPT BY NAME with reason=pinned"
    case_check "$([ -d "$bypath" ] && echo 0 || echo 1)" "the directory UNDER the stamped harness path SURVIVED"
    case_check "$(grep -qF "KEPT   $bypath reason=pinned" <<<"$out" && echo 0 || echo 1)" \
               "and is KEPT BY NAME with reason=pinned (the path arm)"
    case_check "$([ -d "$byalias" ] && echo 0 || echo 1)" \
               "a checkout reached by the stamp's SYMLINKED spelling SURVIVED (pins are canonicalised)"
    case_check "$([ ! -d "$free" ] && echo 0 || echo 1)" \
               "a sibling candidate in the SAME run was reaped — the pin is not a blanket refusal"
    return $((CASE_FAIL > 0))
}

# ── E: duplicate-install keeps the last copy ───────────────────────────────────────────────────
case_e() { # <owner-script>
    local owner="$1" base fam c out rc survivors
    base="$(newbase e)"
    fam="$base/root/fam"
    for c in a b c; do
        mkdir -p "$fam/$c/bin"
        printf 'runner\n' >"$fam/$c/bin/Runner.Listener"
    done
    # ⛔ AGE THE MARKER, NOT ONLY THE DIRECTORY: the owner decides both the age dial and which copy is
    # NEWEST from the install marker's mtime (a directory mtime is rewritten by any child change).
    age_path "$fam/a" 400; age_path "$fam/b" 400; age_path "$fam/c" 5
    age_path "$fam/a/bin/Runner.Listener" 400
    age_path "$fam/b/bin/Runner.Listener" 400
    age_path "$fam/c/bin/Runner.Listener" 5
    # A live listener inside copy `a`: deleting its install would kill a job.
    ( cd "$fam/a" && exec sleep 180 ) &
    local pid=$!; SLEEPERS="$SLEEPERS $pid"
    case_check "$(wait_cwd "$pid" "$fam/a" && echo 0 || echo 1)" "the listener witness is cwd'd inside copy a"
    out="$(REAP_DI_STATE_DIR="$base/state" REAP_DI_ROOTS="$base/root" bash "$owner" --apply 2>&1)"; rc=$?
    case_check "$([ "$rc" = 0 ] && echo 0 || echo 1)" "the pass exits 0 (rc=$rc)"
    case_check "$([ -d "$fam/c" ] && echo 0 || echo 1)" "the NEWEST copy SURVIVED"
    case_check "$(grep -qF "KEPT   $fam/c reason=newest" <<<"$out" && echo 0 || echo 1)" \
               "and it is KEPT BY NAME as the newest (never a candidate)"
    case_check "$([ -d "$fam/a" ] && echo 0 || echo 1)" "the copy a LIVE listener sits in SURVIVED"
    case_check "$(grep -qF "KEPT   $fam/a reason=live-listener" <<<"$out" && echo 0 || echo 1)" \
               "and is KEPT BY NAME with reason=live-listener"
    case_check "$([ ! -d "$fam/b" ] && echo 0 || echo 1)" \
               "the only PROVABLY IDLE surplus copy WAS reaped"
    # ⛔ AN EXACT SET, not a disjunction: `[ -d a ] || [ -d b ] || [ -d c ]` is true as long as ANY
    # copy exists, which the two assertions above already establish — it could never fail. The
    # invariant is "exactly the two kept copies survive, the idle one is gone".
    survivors=""
    for c in a b c; do [ -d "$fam/$c" ] && survivors="$survivors$c"; done
    case_check "$([ "$survivors" = ac ] && echo 0 || echo 1)" \
               "the family was not emptied: exactly the two KEPT copies survive (got '$survivors')"
    kill "$pid" 2>/dev/null
    return $((CASE_FAIL > 0))
}

# ── F: the abandoned arm runs on a cell with NO REPO (the #2443 shape) ─────────────────────────
# `reap_worktree` used to `return 3` when no repo could be resolved, which took the class's ONLY
# working arm with it on exactly the cell that was filling: the one the timer passes no `--repo`
# for. The registered arm still fails closed (that is correct); the abandoned arm must still run.
case_f() { # <owner-script> <entry-point>
    local owner="$1" pass="$2" base root repo wt out rc status
    base="$(newbase f)"; root="$base/scratch"
    repo="$(mk_repo "$base")"
    wt="$(mk_linked_wt "$repo" "$root" old-idle feat/f-idle)"
    age_path "$wt" 400
    out="$(DISK_REAPER_STATE_DIR="$base/state" REAP_AW_ROOTS="$root" REAP_DI_ROOTS="$base/no-dups" \
           DISK_REAPER_REPOS="$base/not-a-repo" ABANDONED_WT_REAPER="$owner" \
           bash "$pass" --apply --only worktree 2>&1)"; rc=$?
    [ -n "${DRC_DEBUG:-}" ] && printf 'F rc=%s\n%s\n' "$rc" "$out" >&2
    status="$(cat "$base/state/disk-reaper.status" 2>/dev/null)"
    case_check "$([ ! -d "$wt" ] && echo 0 || echo 1)" \
               "with NO resolvable repo the abandoned arm STILL ran and reaped the old idle directory"
    case_check "$(grep -qF 'the abandoned arm still runs' <<<"$out" && echo 0 || echo 1)" \
               "and the pass says the registered arm failed closed while the abandoned arm ran"
    case_check "$(grep -q '^verdict_worktree=misconfigured$' <<<"$status" && echo 0 || echo 1)" \
               "the un-runnable registered arm is recorded as misconfigured, never as a measured zero"
    return $((CASE_FAIL > 0))
}

# ── G: a class that removed NOTHING does not claim the window's df change ────────────────────────
# Measured 2026-10-24 on this box: a pass whose registered arm failed closed and whose abandoned arm
# found nothing still reported `freed_df=110MB`, because two other lanes were writing inside the
# window. `df`-instead-of-`du` was adopted to stop one false credit; this is the same false credit
# arriving through the other door. The fixture makes the foreign change DETERMINISTIC: a stub owner
# deletes a pre-seeded file (so the root really does gain free space) and reports `reaped=0`.
case_g() { # <entry-point> <stub-owner>
    local pass="$1" stub="$2" base root out status
    base="$(newbase g)"; root="$base/scratch"
    mkdir -p "$root"
    dd if=/dev/zero of="$root/other-lane-was-here.bin" bs=1M count=32 >/dev/null 2>&1
    out="$(DISK_REAPER_STATE_DIR="$base/state" REAP_DI_ROOTS="$root" REAP_AW_ROOTS="$base/no-aw" \
           DUP_INSTALL_REAPER="$stub" bash "$pass" --apply --only duplicate-install 2>&1)"
    [ -n "${DRC_DEBUG:-}" ] && printf 'G\n%s\n' "$out" >&2
    status="$(cat "$base/state/disk-reaper.status" 2>/dev/null)"
    case_check "$(grep -q '^freed_mb_duplicate_install=0$' <<<"$status" && echo 0 || echo 1)" \
               "a class that removed nothing reports freed=0, not the 32MB another process freed"
    # The note lives in the pass RECORD (`detail=`), which is the artifact an operator reads — not on
    # the class line, which carries the numbers only.
    case_check "$(grep -qF 'belongs to another process (not attributed)' <<<"$status" && echo 0 || echo 1)" \
               "and it NAMES the un-attributed change in the pass record instead of dropping it"
    return $((CASE_FAIL > 0))
}

# The stub honours the delegate contract the entry point relays on: `--print-config` (it answers
# `roots=`) and a mode invocation (it frees 32MB of someone else's and reports reaped=0).
mk_foreign_change_owner() { # <path>
    # `--print-config` answers NOTHING on purpose: the entry point then falls back to `REAP_DI_ROOTS`,
    # which is the per-invocation root — a root baked in at creation time would be the wrong fixture.
    cat >"$1" <<STUB
#!/usr/bin/env bash
[ "\$1" = "--print-config" ] && exit 1
root=""; while [ \$# -gt 0 ]; do [ "\$1" = "--root" ] && { root="\$2"; shift; }; shift; done
[ -n "\$root" ] && rm -f "\$root/other-lane-was-here.bin"
echo "SUMMARY class=duplicate-install families=1 candidates=0 reaped=0 kept=0 failed=0"
exit 0
STUB
    chmod +x "$1"
}

# ── H: a SYMLINK in the scratch root is never followed out of it ─────────────────────────────────
# `*/` matches a symlink-to-directory, `-d` follows it, and every later step resolves the TARGET
# (`pwd -P`) — so a link in a scratch root made the sweep classify, and `rm -rf`, a directory OUTSIDE
# the root it was told to sweep. The link is kept and named; the target is never touched.
case_h() { # <owner-script>
    local owner="$1" base outside root wt out
    base="$(newbase h)"; root="$base/scratch"; outside="$base/outside"
    mkdir -p "$root" "$outside"
    # a REAL old, clean, idle linked worktree — everything the two dials would clear — placed OUTSIDE
    # the scratch root, and a symlink to it INSIDE the root.
    repo="$(mk_repo "$base")"
    wt="$(mk_linked_wt "$repo" "$outside" old-idle feat/h-outside)"
    age_path "$wt" 400
    ln -s "$wt" "$root/alias-to-outside"
    out="$(REAP_AW_STATE_DIR="$base/state" REAP_AW_ROOTS="$root" bash "$owner" --apply 2>&1)"
    [ -n "${DRC_DEBUG:-}" ] && printf 'H\n%s\n' "$out" >&2
    case_check "$([ -d "$wt" ] && echo 0 || echo 1)" \
               "the worktree OUTSIDE the scratch root SURVIVED (the link was not followed)"
    case_check "$(grep -qF "reason=symlink" <<<"$out" && echo 0 || echo 1)" \
               "and the link is KEPT BY NAME with reason=symlink"
    return $((CASE_FAIL > 0))
}

# ── I: an UNREADABLE tree is not a CLEAN tree ───────────────────────────────────────────────────
# `git status | wc -l` prints 0 when git FAILS, and 0 clears the default `--dirty keep` dial — so a
# dangling `.git` (the record pruned: exactly the moved/pruned population this arm targets) would read
# as clean and `rm -rf` would take uncommitted work with it.
case_i() { # <owner-script>
    local owner="$1" base root broken out
    base="$(newbase i)"; root="$base/scratch"; mkdir -p "$root"
    broken="$root/old-broken"
    mkdir -p "$broken"
    # a linked-worktree `.git` FILE whose gitdir does not exist -> every git verb in it fails
    printf 'gitdir: %s/.git/worktrees/gone\n' "$base/nonexistent" >"$broken/.git"
    printf 'uncommitted work that must not be destroyed\n' >"$broken/precious.txt"
    age_path "$broken" 400
    out="$(REAP_AW_STATE_DIR="$base/state" REAP_AW_ROOTS="$root" bash "$owner" --apply 2>&1)"
    [ -n "${DRC_DEBUG:-}" ] && printf 'I\n%s\n' "$out" >&2
    case_check "$([ -d "$broken" ] && [ -f "$broken/precious.txt" ] && echo 0 || echo 1)" \
               "a tree git cannot read is KEPT — its uncommitted work survives"
    case_check "$(grep -qF "reason=clean-unknown" <<<"$out" && echo 0 || echo 1)" \
               "and it is KEPT BY NAME as clean-unknown, not as a clean tree"
    return $((CASE_FAIL > 0))
}

# ── J: a lock held by a LIVE pid is honoured, never reclaimed as stale ──────────────────────────
# The token is ONE line (`pid=<n> started=<epoch>`). Parsing it as `s/^pid=//` captures the whole tail,
# which `num` rejects — so the live-owner check never ran, the tokenless arm (anchored `^started=`)
# never matched either, and EVERY existing lock was declared stale and DELETED WHILE ITS OWNER WAS
# LIVE. That removed the only exclusion between two concurrent sweeps of one root.
case_j() { # <owner-script> <lock-dir-name>
    local owner="$1" lockname="$2" base root state out rc
    base="$(newbase j)"; root="$base/root"; state="$base/state"
    mkdir -p "$root" "$state/$lockname"
    # the owner's OWN token format, naming a pid that is certainly alive (this test shell)
    printf 'pid=%s started=%s\n' "$$" "$(date +%s)" >"$state/$lockname/token"
    out="$(REAP_AW_STATE_DIR="$state" REAP_DI_STATE_DIR="$state" REAP_AW_ROOTS="$root" REAP_DI_ROOTS="$root" \
           bash "$owner" --apply 2>&1)"; rc=$?
    [ -n "${DRC_DEBUG:-}" ] && printf 'J %s rc=%s\n%s\n' "$lockname" "$rc" "$out" >&2
    case_check "$([ "$rc" = 3 ] && echo 0 || echo 1)" "a LIVE lock is a refusal (rc=$rc, expected 3)"
    case_check "$(grep -qF 'SKIP reason=lock-held' <<<"$out" && echo 0 || echo 1)" \
               "and it says so by name (SKIP reason=lock-held)"
    case_check "$([ -d "$state/$lockname" ] && echo 0 || echo 1)" \
               "and the live owner's lock is still there (never reclaimed)"
    return $((CASE_FAIL > 0))
}

# ── the mutations ──────────────────────────────────────────────────────────────────────────────
MUT_A='s/if lp_path_held "\$CENSUS" "\$canon"; then/if false; then/'
MUT_B='s/if remove_one "\$canon" "\$repo"; then/if false; then/'
MUT_C='s/if ! lp_census "\$CENSUSDIR"; then/if false; then/'
MUT_D='s/if pinned "\$canon" "\$base"; then/if false; then/'
MUT_E='s/\[ "\$c" = "\$newest" \] \&\&/[ "$c" = "__never__" ] \&\&/'
MUT_F='s/REPO_ARM_OK=0; REPOS=""/return 3/'
MUT_G='s/if \[ "\$reaped" = 0 \] \&\& ! is_dry; then/if false; then/'
MUT_H='s/if \[ -L "\$d" \]; then/if false; then/'
MUT_I='s/        dirty="?"$/        dirty="0"/'
MUT_D2='s/^        PIN_PATHS="\$_pc"$/        :/'
MUT_J='s/kill -0/false/'

echo "── disk-reaper-classes.test.sh — #2542 classes ─────────────────────────────────────────────"

expect_pass "A an old directory with a LIVE cwd inside is KEPT and NAMED (real owner)" case_a "$AW_OWNER"
if apply_mutation "$AW_OWNER" "$T/mut-a/reap-abandoned-worktrees.sh" "$MUT_A"; then
    expect_fail "A mutation: deleting the live-cwd arm turns the case RED" case_a "$T/mut-a/reap-abandoned-worktrees.sh"
else
    bad "A mutation could not be applied (the live-cwd arm moved) — the case is not checking it any more"
fi

expect_pass "B an old directory with NO live cwd is REAPED and the df delta is reported (entry point)" case_b "$AW_OWNER" "$REAPER"
if apply_mutation "$AW_OWNER" "$T/mut-b/reap-abandoned-worktrees.sh" "$MUT_B"; then
    expect_fail "B mutation: deleting the removal arm turns the case RED" case_b "$T/mut-b/reap-abandoned-worktrees.sh" "$REAPER"
else
    bad "B mutation could not be applied (the removal arm moved) — the case is not checking it any more"
fi

expect_pass "C an unreadable process list SKIPS the sweep and reports the skip (real owner)" case_c "$AW_OWNER"
if apply_mutation "$AW_OWNER" "$T/mut-c/reap-abandoned-worktrees.sh" "$MUT_C"; then
    expect_fail "C mutation: deleting the fail-closed census arm turns the case RED" case_c "$T/mut-c/reap-abandoned-worktrees.sh"
else
    bad "C mutation could not be applied (the census arm moved) — the case is not checking it any more"
fi

expect_pass "D the pinned sha is never reaped, even when old and apparently idle (real owner)" case_d "$AW_OWNER"
if apply_mutation "$AW_OWNER" "$T/mut-d/reap-abandoned-worktrees.sh" "$MUT_D"; then
    expect_fail "D mutation: deleting the pin arm turns the case RED" case_d "$T/mut-d/reap-abandoned-worktrees.sh"
else
    bad "D mutation could not be applied (the pin arm moved) — the case is not checking it any more"
fi

expect_pass "E duplicate-install keeps the last copy, and only reaps a PROVABLY IDLE copy (real owner)" case_e "$DI_OWNER"
if apply_mutation "$DI_OWNER" "$T/mut-e/reap-duplicate-installs.sh" "$MUT_E"; then
    expect_fail "E mutation: deleting the keep-newest arm turns the case RED" case_e "$T/mut-e/reap-duplicate-installs.sh"
else
    bad "E mutation could not be applied (the keep-newest arm moved) — the case is not checking it any more"
fi

expect_pass "F with NO resolvable repo the abandoned arm still runs (real owner + entry point)" case_f "$AW_OWNER" "$REAPER"
if apply_mutation "$REAPER" "$T/mut-f/disk-reaper.sh" "$MUT_F"; then
    # ⚠️ The mutant entry point must find ITS OWN delegates: it resolves them beside itself, so the
    # real owners are symlinked next to it (a missing delegate would fail closed for a different
    # reason and the mutant would "pass" the wrong test).
    for d in pi-reap-worktrees.sh reap-abandoned-worktrees.sh reap-duplicate-installs.sh pi-cache-reap.sh reap-lane-venvs.sh; do
        [ -f "$HERE/$d" ] && ln -sfn "$HERE/$d" "$T/mut-f/$d"
    done
    expect_fail "F mutation: returning early when no repo resolves turns the case RED" case_f "$AW_OWNER" "$T/mut-f/disk-reaper.sh"
else
    bad "F mutation could not be applied (the repo-arm arms moved) — the case is not checking it any more"
fi

# G needs a stub owner, so it is built here rather than in the case body.
mk_foreign_change_owner "$T/stub-foreign.sh"
expect_pass "G a class that removed nothing does not claim another process' df change" case_g "$REAPER" "$T/stub-foreign.sh"
if apply_mutation "$REAPER" "$T/mut-g/disk-reaper.sh" "$MUT_G"; then
    for d in pi-reap-worktrees.sh reap-abandoned-worktrees.sh reap-duplicate-installs.sh pi-cache-reap.sh reap-lane-venvs.sh; do
        [ -f "$HERE/$d" ] && ln -sfn "$HERE/$d" "$T/mut-g/$d"
    done
    expect_fail "G mutation: reporting the window's df change as freed turns the case RED" case_g "$T/mut-g/disk-reaper.sh" "$T/stub-foreign.sh"
else
    bad "G mutation could not be applied (the attribution rule moved) — the case is not checking it any more"
fi

expect_pass "H a symlink in the scratch root is never followed out of it" case_h "$AW_OWNER"
if apply_mutation "$AW_OWNER" "$T/mut-h/reap-abandoned-worktrees.sh" "$MUT_H"; then
    expect_fail "H mutation: following the symlink turns the case RED" case_h "$T/mut-h/reap-abandoned-worktrees.sh"
else
    bad "H mutation could not be applied (the symlink arm moved) — the case is not checking it any more"
fi

expect_pass "I an unreadable tree is not a CLEAN tree (fail closed, dirty work survives)" case_i "$AW_OWNER"
if apply_mutation "$AW_OWNER" "$T/mut-i/reap-abandoned-worktrees.sh" "$MUT_I"; then
    expect_fail "I mutation: reading a failed git status as dirty=0 turns the case RED" case_i "$T/mut-i/reap-abandoned-worktrees.sh"
else
    bad "I mutation could not be applied (the unreadable-tree arm moved) — the case is not checking it any more"
fi

expect_pass "J a lock held by a LIVE pid is honoured (abandoned-worktree owner)" case_j "$AW_OWNER" reap-abandoned-worktrees.lock
expect_pass "J a lock held by a LIVE pid is honoured (duplicate-install owner)" case_j "$DI_OWNER" reap-duplicate-installs.lock
if apply_mutation "$AW_OWNER" "$T/mut-j/reap-abandoned-worktrees.sh" "$MUT_J"; then
    expect_fail "J mutation: mis-parsing the lock token turns the case RED" case_j "$T/mut-j/reap-abandoned-worktrees.sh" reap-abandoned-worktrees.lock
else
    bad "J mutation could not be applied (the lock token parse moved) — the case is not checking it any more"
fi
if apply_mutation "$AW_OWNER" "$T/mut-d2/reap-abandoned-worktrees.sh" "$MUT_D2"; then
    expect_fail "D mutation: dropping the pin canonicalisation turns the symlinked-stamp case RED" case_d "$T/mut-d2/reap-abandoned-worktrees.sh"
else
    bad "D canonicalisation mutation could not be applied — the aliased pin is not being checked"
fi

echo
echo "──────────────────────────────────────────────────────────────────────"
if [ "$FAIL" -gt 0 ]; then
    echo "FAILED ($FAIL failed, $PASS passed)"
    exit 1
fi
echo "ALL PASS ($PASS assertions)"
