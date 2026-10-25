#!/usr/bin/env bash
# live-paths.sh — the ONE census of what live processes name on the filesystem (cwd, exe, argv).
#
# WHY THIS IS A LIBRARY AND NOT TWO COPIES. Two reclamation policies now need the same
# question answered — "is a live process inside this directory?" — for the same reason and with
# the same failure mode:
#
#   * `reap-abandoned-worktrees.sh` must not delete a `/tmp` worktree a lane is still sitting in;
#   * `reap-duplicate-installs.sh` must not delete a CI runner install whose listener/exe/argv is
#     inside it (a runner killed mid-job is a lost job — worse than a full disk).
#
# A second copy of this predicate is how the two drift, and the drift here is silent in the
# dangerous direction: the copy that forgets one arm deletes live work. So there is ONE census,
# ONE matching rule, and ONE fail-closed rule, and both owners source it.
#
# ⛔ THE POPULATION COMES FROM THE PROCESS TABLE, NEVER FROM `pgrep -f`. Measured 2026-10-24
# (#2542): `pgrep -f` self-matches the shell that runs the check (its own command line carries the
# pattern), and it matches the *pattern*, not the *population* — it shows the nesting stack of
# whatever launched the sweep rather than who is actually working. Reading `/proc/<pid>/cwd` for
# every pid is the predicate that earned its place: on the three cells it KEPT five directories
# whose age alone would have condemned them (`cell-wt-tmainred70` 226 m, `cell-wt-zombiepi` 742 m,
# `cell-wt-trebase6` 823 m, `cell-wt-venvlink` 1,080 m, `wt-pinfix` 2,200 m) while a live process
# sat inside each.
#
# ⛔ THIS IS THE SAME PROBE AS `scripts/orchestrator-harness/live-ownership.sh::lo_cwd_rows`, and
# that is deliberate: the merged #2594 hygiene pass (`root_excluded()`) proves per root whether a
# live process holds it from exactly this read. It is reimplemented here rather than sourced
# because `orchestrator-harness/` is NOT farmed (only `scripts/*.sh` and `scripts/lib/*` are), so a
# farmed reaper cannot resolve that file. If the two ever disagree about how a cwd is read, this
# one is wrong — the semantics are pinned by orchestrator-harness/claim-cwd.test.sh.
#
# WHAT A ROW IS. One line, TAB separated: `<kind>\t<pid>\t<path>` where kind is cwd | exe | arg.
# Paths are absolute, resolved through the kernel's own symlink (`/proc/<pid>/cwd`), with the
# kernel's ` (deleted)` suffix stripped — a process whose cwd was removed still NAMES the path we
# are about to reuse, so matching on the stripped form is the safe direction.
#
# FAIL-CLOSED (the whole point). `lp_census` returns 1 when the population cannot be read at all:
# no probe available, the probe produced nothing, or the probe command is missing. The CALLER must
# then skip its sweep and SAY SO — never read "could not enumerate" as "nothing is live". A PARTIAL
# read (this user cannot see root's /proc entries) is still a real census and is reported as one,
# with the count of unreadable pids, because refusing on a partial read would make every sweep on a
# real box permanently inert — the inert-enforcer shape this family exists to remove.
#
# READ-ONLY. This file deletes nothing and writes only inside the caller's census directory.
# Bounded: one `ls` over /proc (or one `lsof`), one BUILTIN read per pid's cmdline (no `tr` fork),
# no recursion. Rows: cwd/exe per pid plus one row per path-like or bare non-flag argv token.. The caller owns the
# watchdog — every invocation here is a handful of bulk reads.

# ── integer helper (no octal surprises: leading zeros parse as OCTAL inside $(( ))) ──────────────
lp_num() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; 0) return 0 ;; 0*) return 1 ;; *) return 0 ;; esac; }

# lp_census <dir> — build <dir>/live-paths.tsv, and the counters in LP_*.
#   LP_CENSUS_ROWS  rows written
#   LP_CENSUS_PIDS  distinct pids seen (readable cwd OR exe OR argv)
# Returns 0 on a real census (including a partial one), 1 when it could not be read at all.
LP_CENSUS_ROWS=0; LP_CENSUS_PIDS=0; LP_CENSUS_MECH=""
# _lp_emit_relarg <pid> <token> — one row saying "this token is resolved against this pid's own cwd".
# `relarg` = the token contains a `/`; `relbare` = a bare, non-flag token (`git -C wt-x` names a tree
# with no `/` at all, so refusing those rows left that spelling invisible to every witness — measured).
# A bare token is only ~183 rows on a busy box, so this costs rows, never forks.
_lp_emit_relarg() {
    local _pid="$1" _tok="$2"
    # ⛔ A token can contain TAB or NEWLINE (an argv argument holding a script, measured: the table came
    # back as 200 rows of Python source). The table is TSV, so a raw token corrupts the parse for every
    # row after it — flatten the separators, and drop anything pathologically long (a path is not 4 KB).
    _tok="${_tok//$'\t'/ }"; _tok="${_tok//$'\n'/ }"; _tok="${_tok//$'\r'/ }"
    [ "${#_tok}" -le 1024 ] || return 0
    case "$_tok" in
        ''|-*) return 0 ;;
        */*) printf 'relarg\t%s\t%s\n' "$_pid" "$_tok" ;;
        *)   printf 'relbare\t%s\t%s\n' "$_pid" "$_tok" ;;
    esac
    return 0
}

lp_census() { # <dir>
    local dir="${1:-}" out probe proc="${LP_PROC_ROOT:-/proc}" rows pids
    [ -n "$dir" ] || return 1
    # ⛔ THE FAIL-CLOSED ARM NEEDS A SEAM A TEST CAN DRIVE ON EVERY HOST. Pointing /proc somewhere
    # missing is not enough: the macOS/container arm falls through to `lsof` and succeeds, so the
    # unreadable case would be untestable exactly where it matters (CI). This forces the SAME return
    # every arm produces when it cannot read the table — never a different code, never a different
    # message shape.
    if [ "${LP_CENSUS_UNAVAILABLE:-0}" = 1 ]; then LP_CENSUS_MECH="forced-unavailable"; return 1; fi
    mkdir -p "$dir" 2>/dev/null || return 1
    out="$dir/live-paths.tsv"
    : >"$out" 2>/dev/null || return 1
    LP_CENSUS_ROWS=0; LP_CENSUS_PIDS=0; LP_CENSUS_MECH=""

    if [ -d "$proc" ] && [ -e "$proc/self/cwd" ]; then
        # ── Linux: the kernel's own per-process links ──────────────────────────────────────────
        # ONE `ls` over the whole table (a per-pid probe is ~50ms x N and is what makes agents
        # abandon this kind of scan). Capture FIRST: a pipeline reports awk's status, so a broken
        # probe would otherwise look exactly like a census that found nobody.
        probe="${LP_LS_PROBE:-ls}"
        command -v "$probe" >/dev/null 2>&1 || return 1
        _lp_cwd="$("$probe" -l "$proc"/[0-9]*/cwd 2>/dev/null)"
        _lp_exe="$("$probe" -l "$proc"/[0-9]*/exe 2>/dev/null)"
        if [ -z "$_lp_cwd" ] && [ -z "$_lp_exe" ]; then
            LP_CENSUS_MECH="unreadable"
            return 1
        fi
        LP_CENSUS_MECH="/proc"
        {
            printf '%s\n' "$_lp_cwd" | _lp_parse_ls cwd
            printf '%s\n' "$_lp_exe" | _lp_parse_ls exe
            # argv: one small read per pid; absolute tokens only (a relative token names nothing
            # we could resolve, and resolving it against OUR cwd would be a lie).
            local _f _pid _tok
            for _f in "$proc"/[0-9]*/cmdline; do
                [ -r "$_f" ] || continue
                _pid="${_f#"$proc"/}"; _pid="${_pid%/cmdline}"
                lp_num "$_pid" || continue
                # ⛔ BUILTIN SPLIT. `tr '\0' '\n' | while …` forked once per pid — and the header
                # promises no per-pid fork; `toctou_preserve` runs a FULL census per candidate, so that
                # made a pass O(candidates x pids) forks.
                while IFS= read -r -d '' _tok; do
                    # ⛔ ABSOLUTE TOKENS ONLY — and an absolute path can arrive ATTACHED: a holder that
                    # names the tree as `--repo=/abs/tree` or `WORKTREE=/abs/tree` matched no `/*` case, so
                    # it did not protect the tree it named (measured: the tree was reaped while a live
                    # process had it in argv). Emit the part after `=`; a relative value still emits
                    # nothing, so the "absolute only" rule is unchanged.
                    # `relarg` = a token the holder resolves against ITS OWN cwd. Emitted for every
                    # non-absolute token; the match joins it with that pid's cwd row, in one awk pass.
                    case "$_tok" in
                        /*) printf 'arg\t%s\t%s\n' "$_pid" "$_tok" ;;
                        *=*) case "${_tok#*=}" in
                                 /*) printf 'arg\t%s\t%s\n' "$_pid" "${_tok#*=}" ;;
                                 # ⛔ THE VALUE, NOT THE WHOLE TOKEN: `GIT_DIR=wt-x/.git` emitted whole
                                 # made the matcher join `cwd/GIT_DIR=wt-x/.git`, never matching — while
                                 # the ps arm emitted the value and DID match. The two arms disagreeing
                                 # about what a holder named is the one thing this library forbids,
                                 # and Linux was the arm that failed open.
                                 # ⛔ BOTH SPELLINGS. Emitting only the value dropped the whole token when
                                 # the `=` sits INSIDE a path component (`wt-eq/f=1.txt` → the value has no
                                 # `/`), so a live holder naming the tree relatively through such a path
                                 # became invisible and the tree was reaped — a regression this very fix
                                 # introduced. The value covers `K=v/path`; the whole token covers
                                 # `path/with=sign`; each is emitted only when path-like.
                                 *)  _lp_emit_relarg "$_pid" "${_tok#*=}"
                                     _lp_emit_relarg "$_pid" "$_tok" ;;
                             esac ;;
                        # ⛔ PATH-LIKE ONLY. Emitting every token exploded the table 100x on a real box
                        # (32,686 rows over 127 pids, measured) because a bare word (`sleep`, `--flag`,
                        # a java classpath element) can never name a tree — and the matcher requires a
                        # `/` anyway. A token without one is not a candidate spelling.
                        *) _lp_emit_relarg "$_pid" "$_tok" ;;
                    esac
                done <"$_f" 2>/dev/null
            done
        } >>"$out" 2>/dev/null
    else
        # ── no /proc (macOS, and the CI runner's own container): lsof for cwd + ps for argv ────
        # Same contract, same TSV. `lsof` is the population probe the macOS arm of
        # live-ownership.sh uses; `ps` supplies argv (its first token is the executable on every
        # platform we run, which is what an `exe` row means here).
        probe="${LP_LSOF_PROBE:-lsof}"
        command -v "$probe" >/dev/null 2>&1 || return 1
        _lp_raw="$("$probe" -w -a -d cwd -Fpn 2>/dev/null)" || return 1
        [ -n "$_lp_raw" ] || return 1
        LP_CENSUS_MECH="lsof"
        {
            printf '%s\n' "$_lp_raw" | awk '
                /^p/ { pid = substr($0, 2); next }
                /^n/ { p = substr($0, 2); sub(/ \(deleted\)$/, "", p)
                       if (pid ~ /^[0-9]+$/ && p ~ /^\//) printf "cwd\t%s\t%s\n", pid, p }'
            # ⛔ NOT `|| return 0`. This block is inside a `{ … } >>"$out"` group, so a `return` here
            # returned from the WHOLE census: the counters below never ran and BOTH fail-closed gates
            # (`rows -eq 0`, `no cwd/exe`) were skipped, so on a host with `lsof` but no `ps` (the CI
            # runner's own container — this arm's declared target) an EMPTY census returned 0 and the
            # owner read it as "nothing is live" and reaped against it. Measured: a linked worktree with
            # a live process cwd'd inside it was REAPED on that host shape.
            _lp_ps_probe="${LP_PS_PROBE:-ps}"
            if command -v "$_lp_ps_probe" >/dev/null 2>&1; then
                "$_lp_ps_probe" -axo pid=,args= 2>/dev/null | awk '
                    { pid = $1; if (pid !~ /^[0-9]+$/) next
                      for (i = 2; i <= NF; i++) {
                        if ($i ~ /^\//) { printf "arg\t%s\t%s\n", pid, $i; continue }
                        # the ATTACHED spelling (`--repo=/abs`, `VAR=/abs`) — the /proc arm emits it,
                        # and leaving it out made the two arms disagree about what a holder "named"
                        n = split($i, kv, "=")
                        if (n == 2 && kv[2] ~ /^\//) { printf "arg\t%s\t%s\n", pid, kv[2]; continue }
                        # ⛔ BOTH SPELLINGS for n >= 2 as well: emitting only the value made the two arms
                        # disagree again for `A=b=c/d` (the /proc arm emits the value, this arm emitted the
                        # whole token), which is the invariant this file exists to hold.
                        if (n >= 2) {
                            # ⛔ the value is everything after the FIRST `=`. `kv[2]` is only the span
                            # between the first and second, so for `A=b=c/wt-o` this arm emitted just
                            # the whole token while /proc emitted `b=c/wt-o` — still disagreeing, and
                            # this is the ONLY arm on macOS.
                            rest = $i; sub(/^[^=]*=/, "", rest)
                            if (rest ~ /\//) printf "relarg\t%s\t%s\n", pid, rest
                            else if (rest != "" && rest !~ /^-/) printf "relbare\t%s\t%s\n", pid, rest
                            if ($i ~ /\//) printf "relarg\t%s\t%s\n", pid, $i
                        else if ($i != "" && $i !~ /^-/) printf "relbare\t%s\t%s\n", pid, $i
                            continue
                        }
                        if ($i ~ /\//) printf "relarg\t%s\t%s\n", pid, $i
                      } }'
            fi
        } >>"$out" 2>/dev/null
    fi

    rows="$(wc -l <"$out" 2>/dev/null | tr -d ' ')"
    lp_num "$rows" || rows=0
    pids="$(awk -F'\t' 'NF==3 {print $2}' "$out" 2>/dev/null | sort -u | wc -l | tr -d ' ')"
    lp_num "$pids" || pids=0
    LP_CENSUS_ROWS="$rows"; LP_CENSUS_PIDS="$pids"
    # A census with no cwd and no exe row read nothing we can prove idleness with.
    if [ "$rows" -eq 0 ]; then LP_CENSUS_MECH="unreadable"; return 1; fi
    if ! awk -F'\t' '$1=="cwd" || $1=="exe" {found=1; exit} END {exit(found?0:1)}' "$out" 2>/dev/null; then
        LP_CENSUS_MECH="no-cwd-or-exe"; return 1
    fi
    return 0
}

# _lp_parse_ls <kind> — stdin: `ls -l /proc/<pid>/{cwd,exe}` lines -> TSV rows.
#   lr-x------ 1 u g 0 Oct 24 07:11 /proc/123/cwd -> /tmp/wt-x
_lp_parse_ls() { # <kind>
    awk -v kind="$1" '
        match($0, /\/proc\/[0-9]+\/(cwd|exe)/) {
            pid = substr($0, RSTART + 6, RLENGTH - 10)
            i = index($0, " -> ")
            if (pid ~ /^[0-9]+$/ && i > 0) {
                t = substr($0, i + 4)
                sub(/ \(deleted\)$/, "", t)
                if (t ~ /^\//) printf "%s\t%s\t%s\n", kind, pid, t
            }
        }'
}

# _lp_rel <path> <base> — is <path> equal to <base> or under it? rc 0 yes.
# ⛔ BOUNDARY-AWARE, BOTH SIDES CANONICAL. A bare `case "$p" in "$base"*)` matches
# `/tmp/cell-wt-x-sibling` against `/tmp/cell-wt-x` and reads a live lane as free. Both sides are
# canonicalised by the caller (`lp_canon`); this test is the one place the boundary is decided.
_lp_rel() {
    local p="$1" b="$2"
    [ -n "$p" ] && [ -n "$b" ] || return 1
    [ "$p" = "$b" ] && return 0
    case "$p" in "$b"/*) return 0 ;; esac
    return 1
}

# lp_canon <path> — physical path, or empty when it cannot be resolved (never a guess).
lp_canon() { [ -n "${1:-}" ] && ( cd "$1" 2>/dev/null && pwd -P ); }

# lp_path_held <census-file> <path> — rc 0 when a live process's CWD or EXE is inside <path>.
# Sets LP_HOLD_WHY to a printable reason (`cwd pid 4242`), which is what a KEEP line must name.
LP_HOLD_WHY=""
lp_path_held() { # <census> <canonical-path>
    local f="$1" path="$2" kind pid p
    LP_HOLD_WHY=""
    [ -n "$path" ] && [ -r "$f" ] || return 1
    while IFS="$(printf '\t')" read -r kind pid p; do
        case "$kind" in cwd|exe) ;; *) continue ;; esac
        if _lp_rel "$p" "$path"; then LP_HOLD_WHY="$kind pid $pid"; return 0; fi
    done <"$f"
    return 1
}

# lp_path_named <census-file> <path> — rc 0 when a live process's ARGV names <path> (or something
# under it). This is the arm #2542 asks for by name: "never a root a live controller's
# /proc/<pid>/args names". A controller can be started from elsewhere and still hold the tree it
# was pointed at, so argv is a different witness from cwd.
LP_NAME_WHY=""
lp_path_named() { # <census> <canonical-path>
    local f="$1" path="$2" kind pid p _pp base _cand _relpid _rpid _rfork _rtok _rcwd _rcomp _rcanon _rfull
    base="${path##*/}"
    LP_NAME_WHY=""
    [ -n "$path" ] && [ -r "$f" ] || return 1
    while IFS="$(printf '\t')" read -r kind pid p; do
        [ "$kind" = arg ] || continue
        if _lp_rel "$p" "$path"; then LP_NAME_WHY="argv pid $pid"; return 0; fi
        # ⛔ THE TOKEN IS A RAW SPELLING; THE CANDIDATE IS A PHYSICAL ONE. Comparing them directly made
        # this arm miss whenever the holder spelled the tree differently — a controller pointed at the
        # tree THROUGH A SYMLINK named `/tmp/link/wt/f`, the candidate's canonical path was
        # `/tmp/real/wt`, no prefix matched, and the tree the live controller was working in was reaped
        # (measured: one sweep, two identical holders, one kept and one REAPED). On macOS the default
        # `--root /tmp` makes every candidate `/private/tmp/…`, so the arm was dead BY CONSTRUCTION
        # there — the same defect the pin path arm had.
        #
        # Cost control: only a token whose LAST PATH COMPONENT matches the candidate's earns the one
        # `lp_canon` call it takes to prove it, so a table of thousands of args costs string compares
        # and no subprocesses unless something could plausibly match.
        case "$p" in
            /*/*)
                # (A) the token ENDS at the candidate's own name, or (B) it sits UNDER it. Either way the
                # spelling is canonicalised from the token's own prefix, never guessed from the candidate.
                _cand=""
                case "$p" in
                    *"/$base")   _pp="$(lp_canon "${p%/$base}")" || _pp=""; _cand="${_pp%/}/$base" ;;
                    *"/$base/"*) _pp="$(lp_canon "${p%%/$base/*}")" || _pp=""; _cand="${_pp%/}/$base" ;;
                    # ⛔ AND THE TOKEN THAT **IS** AN ALIAS FOR THE TREE. `agent --repo /tmp/alias-a`,
                    # where `alias-a` is a symlink to the candidate, matches neither shape above (its
                    # last component is the ALIAS's name), so the arm was blind to the simplest symlink
                    # spelling of all and the tree was reaped while that process was alive. A stat is
                    # cheap; only a token that exists earns the `lp_canon` call.
                    # ⛔ A FILE UNDER AN ALIASED SPELLING still named nothing: `alias-wt/somefile.txt`
                    # is not a directory, so the stat arm skipped it, while `real-wt/somefile.txt` matched
                    # through the basename case. Canonicalise its DIRECTORY: that covers file, directory
                    # and symlinked-prefix spellings uniformly, and it still cannot reach an ancestor
                    # (`dirname /tmp/alias-root` is `/tmp`, which is not the candidate).
                    *) if [ -d "$p" ] || [ -L "$p" ]; then
                           _cand="$(lp_canon "$p")" || _cand=""
                       else
                           _pp="$(lp_canon "$(dirname "$p")")" || _pp=""
                           _cand="${_pp:+$_pp/}${p##*/}"
                       fi ;;
                esac
                if [ -n "${_cand:-}" ] && _lp_rel "$_cand" "$path"; then
                    LP_NAME_WHY="argv pid $pid (canonicalised)"; return 0
                fi ;;
        esac
    done <"$f"
    # ⛔ AND A TOKEN THAT IS RELATIVE TO THE HOLDER'S OWN CWD. "Absolute only" exists because resolving a
    # token against OUR cwd would be a lie — but the holder's cwd is in the SAME table, so resolving
    # against THAT is the truth, and a holder naming the tree as `wt-rel/f.txt` from its parent used to
    # name nothing at all. One awk pass does the join (a per-row subprocess would be hundreds of forks):
    # the row is a witness when `cwd + "/" + token` IS the candidate or sits under it — an exact
    # boundary, so `wt1-sibling` cannot match `wt1`, and a `..` component simply does not match (which
    # leaves the tree to the other arms: it is never reaped BECAUSE of the token).
    # ⛔ THE JOIN MUST BE RESOLVED FIRST. A textual `cwd + "/" + token` is not a path: a holder naming
    # `../wt-dotdot/f.txt` from a SIBLING directory produced `cwd/../wt-dotdot/f.txt`, which matched
    # nothing — and the "other arms will see it" justification is false, because the holder's cwd is
    # outside the tree, so no other arm can. `.`/`..` are collapsed lexically here (no subprocess);
    # a relative SYMLINKED prefix (`rel-link/f.txt`, where `rel-link` → the tree) is resolved after,
    # bounded, and only when the lexical pass found nothing.
    _relpid="$(awk -F'\t' -v cand="$path" '
        function norm(p,   n, i, out, parts, k) {
            n = split(p, parts, "/")
            k = 0
            for (i = 1; i <= n; i++) {
                if (parts[i] == "" || parts[i] == ".") continue
                if (parts[i] == "..") { if (k > 0) k--; continue }
                out[++k] = parts[i]
            }
            if (k == 0) return "/"
            r = ""
            for (i = 1; i <= k; i++) r = r "/" out[i]
            return r
        }
        $1 == "cwd" { cwd[$2] = $3; next }
        ($1 == "relarg" || $1 == "relbare") {
            if (!($2 in cwd)) next
            tok = $3
            if (tok == "") next
            full = norm(cwd[$2] "/" tok)
            # ⛔ A BARE token must resolve EXACTLY to the candidate. Prefix semantics are right for a
            # path-like token (naming something under the tree implies using it) but wrong for a bare
            # one: a holder whose cwd IS the tree and whose argv is `sleep 180` resolved to
            # `<tree>/180` and reported `reason=argv-named`, stealing the reason from the cwd arm that
            # actually proved it (measured). A bare name can only name the tree by being it.
            if ($1 == "relbare") { if (full == cand) { print $2; exit 0 } ; next }
            if (full == cand || index(full, cand "/") == 1) { print $2; exit 0 }
        }
        END { exit 1 }' "$f" 2>/dev/null)"
    if [ -z "$_relpid" ]; then
        # A second chance for a SYMLINKED relative prefix (`rel-link/f.txt`, `rel-link` → the tree).
        # ⛔ NO ROW CAP BEFORE THE CHEAP FILTER, AND NO FORK PER ROW. The first form of this pass capped
        # the raw rows at 200 — one chatty pid starved every later holder, failing OPEN where the pass
        # exists to fail closed — and looked each row's cwd up with its own `awk` (measured: a dry-run
        # over 37 candidates took 3m18s, rows 1,161). ONE awk emits (pid, cwd, component, rest); the
        # shell then does a builtin `-L` per row and forks only a real symlink (capped at 50).
        _rfork=0
        _relpid="$(awk -F'\t' '
            $1 == "cwd" { cwd[$2] = $3; next }
            ($1 == "relarg" || $1 == "relbare") && $3 ~ /\// {
                if (!($2 in cwd)) next
                id = $3
                i = index(id, "/")
                printf "%s\t%s\t%s\t%s\n", $2, cwd[$2], substr(id, 1, i - 1), substr(id, i + 1)
            }' "$f" 2>/dev/null | while IFS="$(printf '\t')" read -r _rpid _rcwd _rcomp _rrest; do
            [ -n "${_rpid:-}" ] || continue
            [ -n "${_rcomp:-}" ] || continue
            # ONLY a symlinked (or just-created) first component can resolve somewhere the lexical join
            # could not reach; a plain directory is exactly what the join already tested.
            [ -L "$_rcwd/$_rcomp" ] || continue
            _rcanon="$(lp_canon "$_rcwd/$_rcomp" 2>/dev/null)" || continue
            [ -n "$_rcanon" ] || continue
            if _lp_rel "${_rcanon%/}${_rrest:+/$_rrest}" "$path"; then printf '%s' "$_rpid"; exit 0; fi
            _rfork=$((_rfork + 1))
            [ "$_rfork" -ge 50 ] && exit 1
        done)"
    fi
    if [ -n "$_relpid" ]; then
        LP_NAME_WHY="argv pid $_relpid (relative to its own cwd)"
        return 0
    fi
    return 1
}

# lp_description — one line naming the mechanism and the population, for a pass to disclose.
lp_description() {
    printf 'live-paths census via %s: %s rows over %s pids' \
        "${LP_CENSUS_MECH:-none}" "${LP_CENSUS_ROWS:-0}" "${LP_CENSUS_PIDS:-0}"
}
