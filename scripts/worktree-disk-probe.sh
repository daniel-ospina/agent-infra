#!/usr/bin/env bash
# worktree-disk-probe.sh — measure what a worktree estate REALLY costs on THIS machine (#1851).
#
# WHY THIS EXISTS
# ---------------
# The fleet sizes a worktree estate with `du` (apparent bytes) and used to translate that into
# real disk with ONE hard-coded ratio justified by a mechanism that does not hold everywhere:
#
#     "per-worktree .venv`s are hardlinked to the uv cache, so du over-reports them
#      (measured: 84 GB du delta vs 22 GB actually freed)"
#
# The NUMBER is a real observation. The MECHANISM is falsified, and that distinction is the whole
# point: the apparent→real gap is a SHARING property of the filesystem, so it is per-machine, and
# the machines that filled are precisely the ones where the sharing does NOT happen. Measured
# 2026-10-16, three regimes, three instruments:
#
#   * APFS + the uv cache on the SAME volume — copy-on-write `clonefile` sharing.
#     Isolated sparse APFS image, uv 0.12.3: one venv was `du` 22.0 MB against a `df` used delta
#     of +0.6 MB; `stat %l` (nlink) was 1 on every file, and a `--link-mode=hardlink` control
#     produced nlink=2, proving the flag is honoured and the default is genuinely not a hardlink.
#     (Whole image: cache + 3 venvs = 89.1 MB apparent vs 25.1 MB real, 3.6x.)
#   * hardlinks into the uv cache (nlink > 1) — the venv's marginal cost IS the cache's.
#     Fresh Linux clone, `uv sync --extra embeddings --extra parity`: `du -sm` on the worktree
#     venv said 5,704 MB while deleting it released 186 MB (30x). Ranking reapers by `du` picks
#     the wrong target: deleting the CACHE would release ~3.5 GB and break every venv linking it.
#   * neither (Linux/overlayfs, a cache on another mount, `--link-mode=copy` against a bare
#     cache) — the venv is REAL. cmux cell `pi-lane-1`, removing 75 worktrees: `du -sm` summed
#     5,647 MiB against a `df -B1` used delta of 5,899,853,824 B — ratio 1.004. `du` was a VALID
#     instrument on that machine; the caveat does not generalise to "`du` is always wrong".
#
# Consequence, and the reason this file exists: the only honest per-machine figure is a `df` delta
# measured on the machine that removes. A `du` figure alone is an upper bound whose error is
# machine-specific and unmeasured. This script produces the real figure, and classifies which
# regime the machine is in — so the lever (reap vs shrink-the-venv) is chosen on measurement.
#
# THE HONEST COLUMN IS `used`, NOT `avail`
# ----------------------------------------
# `avail` moves with concurrent writes. On the cmux cell above, ~1 MB/s of drift (a cmux sqlite
# WAL, logs, and a uv cache all writing) showed as 0.3 % error on a 5.9 GB measurement, while the
# `used` column moved monotonically by exactly the freed bytes. `spawn-gate.sh`'s free-space floor
# and `orch-loop.sh`'s disk probe both read `avail` — correct for a FLOOR ("is there room to start
# an agent?"). A MEASUREMENT must read `used`. This script reads `used`.
#
# WHAT IT IS NOT
# --------------
# It is NOT a reaper and it removes at most the ONE path the caller names with --measure-removal.
# `--measure-removal` runs `git worktree remove` with NO `--force`, so git's own refusal on
# tracked/untracked dirt is the second gate, and branch refs survive (only the checkout dies).
# Choose the path from a `pi-reap-worktrees.sh --dry-run` row it reports as reclaimable: the
# reaper's clean/reachable/unreferenced gates are the thing that makes a removal safe, and this
# script deliberately does not re-implement them.
#
# BOUNDEDNESS: the one expensive operation is the `du -sk` walk (minutes on a 100 GB+ estate);
# `--no-du` skips it. Everything else is O(filesystems) + one bounded `find` per sampled venv
# (depth-limited, capped at --sample files). This script never walks the ESTATE to decide anything.
#
# Usage:
#   worktree-disk-probe.sh [--dir PATH] [--sample N] [--no-du]
#   worktree-disk-probe.sh --repo PATH --measure-removal PATH --yes
#   worktree-disk-probe.sh --help
#
#   (no mode flag)         non-destructive report: volume, apparent size, cache/estate volume
#                          identity, and the nlink/hardlink regime — then the exact command that
#                          measures real bytes on this machine.
#   --measure-removal PATH REQUIRES --repo and --yes. Removes that ONE registered worktree via
#                          `git worktree remove` (no --force) and reports BOTH the apparent
#                          (`du -sk`) and the real (`df -Pk` used delta) figure. Never a `du`
#                          figure alone.
#   --dir PATH             estate directory to report on (default: $PWD/.worktrees if present,
#                          else $PWD)
#   --sample N             .venv files to stat for nlink (default 200)
#   --no-du                skip the `du -sk` walk
#   --yes                  acknowledge that --measure-removal DELETES the named checkout
#
# Env seams (for tests): DF_BIN DU_BIN GIT_BIN FIND_BIN
#   UV_CACHE_DIR WORKTREE_DISK_PROBE_SETTLE (seconds to settle before the `df` after-reading)
#
# Exit codes: 0 measured/reported, 2 usage, 3 fail-closed (a reading could not be taken — never
# read an unreadable `df` as a number), 4 the removal was refused or failed (nothing measured).

set -uo pipefail

SCRIPT_NAME="worktree-disk-probe.sh"
ISSUE_REF="#1851"

DF_BIN="${DF_BIN:-df}"
DU_BIN="${DU_BIN:-du}"
GIT_BIN="${GIT_BIN:-git}"
FIND_BIN="${FIND_BIN:-find}"
SETTLE="${WORKTREE_DISK_PROBE_SETTLE:-2}"

DIR=""
REPO=""
SAMPLE=200
NO_DU=0
MEASURE=""
YES=0

usage() {
    # The range ENDS at the first line that is not header comment, so the WHOLE contract prints —
    # including the exit codes (#1858 review P2: the old range stopped AT `# Exit codes:` and the
    # second sed then deleted that line, so the codes a caller depends on were never shown).
    awk 'p && /^[^#]/ { exit } /^# Usage:/ { p=1 } p { sub(/^# ?/, ""); print }' "$0"
}

die() { # $1=code $2..=message
    local code="$1"; shift
    echo "✖ $SCRIPT_NAME: $*" >&2
    exit "$code"
}

while [ $# -gt 0 ]; do
    case "$1" in
        # Every value-bearing option REFUSES a missing value (#1858 review P1). `shift 2` with one
        # word left is a silent no-op in bash, so the loop re-read the same option forever: measured
        # `timeout 5 bash worktree-disk-probe.sh --dir` => exit 124, zero output, one core spinning —
        # reachable from an unquoted unset variable (`--dir $ESTATE`), and a hang is the opposite of
        # the boundedness this script promises.
        --dir)             [ $# -ge 2 ] || die 2 "--dir requires a value"; DIR="$2"; shift 2 ;;
        --repo)            [ $# -ge 2 ] || die 2 "--repo requires a value"; REPO="$2"; shift 2 ;;
        --sample)          [ $# -ge 2 ] || die 2 "--sample requires a value"; SAMPLE="$2"; shift 2 ;;
        --measure-removal) [ $# -ge 2 ] || die 2 "--measure-removal requires a value"; MEASURE="$2"; shift 2 ;;
        --no-du)           NO_DU=1; shift ;;
        --yes)             YES=1; shift ;;
        --help|-h)         usage; exit 0 ;;
        *)                 die 2 "unknown argument: $1 (try --help)" ;;
    esac
done

case "$SAMPLE" in
    ''|*[!0-9]*) die 2 "--sample must be a positive integer (got: '$SAMPLE')" ;;
esac
[ "$SAMPLE" -gt 0 ] || die 2 "--sample must be positive"
case "$SETTLE" in
    ''|*[!0-9]*) die 2 "WORKTREE_DISK_PROBE_SETTLE must be a non-negative integer (got: '$SETTLE')" ;;
esac

# ── platform helpers ─────────────────────────────────────────────────────────────────────────
# `stat -f` means "filesystem status" on GNU coreutils, so it must never be used as the primary
# form: on Linux it SUCCEEDS and prints something that is not a device id or a link count. Branch
# on the kernel, and if the form fails, return empty (the caller reports "unreadable", it never
# invents a number).
stat_dev() { # -> device id of a path, empty if unreadable
    case "$(uname -s)" in
        Darwin) stat -f '%d' "$1" 2>/dev/null ;;
        *)      stat -c '%d' "$1" 2>/dev/null ;;
    esac
}
stat_nlink() { # -> link count of a path, empty if unreadable
    case "$(uname -s)" in
        Darwin) stat -f '%l' "$1" 2>/dev/null ;;
        *)      stat -c '%h' "$1" 2>/dev/null ;;
    esac
}

# one `df -Pk` row, tab-separated: fs<TAB>size_kib<TAB>used_kib<TAB>avail_kib<TAB>capacity
# Validated, not trusted: a locale- or column-shifted `df` yields NOTHING, so the caller fails
# closed instead of acting on a positionally-wrong number.
df_row() {
    "$DF_BIN" -Pk "$1" 2>/dev/null \
        | awk 'NR==2 && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ && $4 ~ /^[0-9]+$/ {printf "%s\t%s\t%s\t%s\t%s\n", $1, $2, $3, $4, $5}'
}

canon_dir() { # canonical absolute path of an existing directory, empty on failure
    (cd "$1" 2>/dev/null && pwd -P) || true
}

# `du -sk` with its EXIT STATUS preserved, so a PARTIAL walk is distinguishable from a full one.
# Every caller must branch on the status: du prints a partial total AND exits non-zero when a
# subtree is unreadable, and publishing that total as an "upper bound" (report) or folding it into
# the ratio (measure) reads a lower bound as an upper one (#1858 review P1). Prints the KiB total,
# possibly empty; returns du's status.
du_total() { # <dir> -> stdout KiB | nothing
    local out
    out="$("$DU_BIN" -sk "$1" 2>/dev/null)" || { printf '%s\n' "$out" | awk '$1 ~ /^[0-9]+$/ {print $1}'; return 1; }
    printf '%s\n' "$out" | awk '$1 ~ /^[0-9]+$/ {print $1}'
    return 0
}

uv_cache_dir() {
    if [ -n "${UV_CACHE_DIR:-}" ]; then
        printf '%s\n' "$UV_CACHE_DIR"
        return 0
    fi
    command -v uv >/dev/null 2>&1 && { uv cache dir 2>/dev/null; return 0; }
    case "$(uname -s)" in
        Darwin) printf '%s\n' "${HOME:-}/Library/Caches/uv" ;;
        *)      printf '%s\n' "${XDG_CACHE_HOME:-${HOME:-}/.cache}/uv" ;;
    esac
}

# ── report mode (non-destructive) ─────────────────────────────────────────────────────────────
report() {
    local dir_canon row fs size used avail cap estate_dev cache cache_dev links_total links_shared
    local venv f n

    [ -n "$DIR" ] || {
        if [ -d "$PWD/.worktrees" ]; then DIR="$PWD/.worktrees"; else DIR="$PWD"; fi
    }
    dir_canon="$(canon_dir "$DIR")" || true
    [ -n "$dir_canon" ] || die 2 "--dir is not a readable directory: '$DIR'"

    echo "worktree-disk-probe — ${ISSUE_REF} per-machine apparent-vs-real measurement"
    echo ""

    row="$(df_row "$dir_canon")"
    [ -n "$row" ] || die 3 "df gave no usable answer for '$dir_canon' — refusing to report a number that was not read"
    fs="$(printf '%s' "$row" | cut -f1)"
    size="$(printf '%s' "$row" | cut -f2)"
    used="$(printf '%s' "$row" | cut -f3)"
    avail="$(printf '%s' "$row" | cut -f4)"
    cap="$(printf '%s' "$row" | cut -f5)"
    printf '[volume]   %s  size %s KiB  used %s KiB  avail %s KiB  %s  (%s)\n' \
        "$fs" "$size" "$used" "$avail" "$cap" "$dir_canon"

    if [ "$NO_DU" = 1 ]; then
        echo "[apparent] (skipped — --no-du)"
    else
        local duk
        # `du` exits NON-ZERO and still prints a PARTIAL total when any subtree is unreadable
        # (a root-run `uv sync`, another uid's venv — measured: 7836 KiB printed, rc=1, on a tree
        # holding ~58 MB). Discarding that status published a LOWER bound as "an UPPER BOUND"
        # (#1858 review P1). A partial walk is still worth showing, so print it and NAME it.
        if duk="$(du_total "$dir_canon")"; then
            [ -n "$duk" ] || die 3 "\`du -sk\` gave no usable answer for '$dir_canon' — re-run with --no-du to report the regime without it"
            printf '[apparent] %s KiB  (%s, one walk of the estate; this is an UPPER BOUND, never the real figure)\n' "$duk" "$DU_BIN -sk"
        else
            case "$duk" in
                '') die 3 "\`du -sk\` failed and gave no total for '$dir_canon' — re-run with --no-du to report the regime without it" ;;
            esac
            printf '[apparent] %s KiB  (%s -sk read a PARTIAL walk — it exited non-zero, so an\n' "$duk" "$DU_BIN"
            echo "           unreadable subtree was skipped and this is a LOWER bound, NOT an upper bound)."
        fi
    fi

    cache="$(uv_cache_dir)"
    estate_dev="$(stat_dev "$dir_canon")"
    cache_dev=""
    [ -d "$cache" ] && cache_dev="$(stat_dev "$cache")"
    if [ -z "$estate_dev" ]; then
        echo "[uv-cache] $cache  (estate device unreadable — cannot compare volumes)"
    elif [ -z "$cache_dev" ]; then
        echo "[uv-cache] $cache  (absent or unreadable — sharing cannot be established)"
    elif [ "$estate_dev" = "$cache_dev" ]; then
        echo "[uv-cache] $cache (device $cache_dev)  estate device $estate_dev  -> SAME volume: block sharing (hardlink or CoW) is possible here"
    else
        echo "[uv-cache] $cache (device $cache_dev)  estate device $estate_dev  -> DIFFERENT volumes: NO block sharing is possible; each .venv is REAL"
    fi

    links_total=0
    links_shared=0
    # A .venv lives at the ROOT of a worktree, so an estate's sits ONE level below --dir; but --dir
    # may itself BE a worktree or a repo root (that is the DEFAULT — $PWD when $PWD/.worktrees is
    # absent), where the .venv is AT --dir. Sampling only `<dir>/*/.venv` found nothing in that
    # layout and then printed the affirmative "venv sharing is NOT in play here" — a claim about a
    # path the instrument never looked at, and one that contradicts measure(), which samples
    # `<worktree>/.venv/lib` (#1858 review P1). Both modes must agree on where a venv lives.
    for venv in "$dir_canon"/.venv "$dir_canon"/*/.venv; do
        [ -d "$venv" ] || continue
        [ "$links_total" -lt "$SAMPLE" ] || break
        # Bounded, explicit walk: depth-limited under one venv's lib/, capped by --sample. This is
        # the only recursive filesystem call in the script and it never touches the estate root.
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            n="$(stat_nlink "$f")"
            case "$n" in ''|*[!0-9]*) continue ;; esac
            links_total=$((links_total + 1))
            [ "$n" -gt 1 ] && links_shared=$((links_shared + 1))
            [ "$links_total" -lt "$SAMPLE" ] || break
        done < <("$FIND_BIN" "$venv/lib" -maxdepth 6 -type f \( -name '*.py' -o -name '*.so' -o -name '*.pyd' \) 2>/dev/null | head -n "$SAMPLE")
    done

    if [ "$links_total" = 0 ]; then
        echo "[links]    no .venv found at '$dir_canon/.venv' or one level below it (or none readable)" 
        echo "           — venv sharing is NOT in play in what was EXAMINED here; the estate's real cost is"
        echo "           its checkouts. Measure it with --measure-removal."
    elif [ "$links_shared" -gt 0 ]; then
        # nlink > 1 proves the blocks are SHARED; it does not prove WHO holds them. Nothing here
        # compares against the cache path, and the suite's own A3 fixture hardlinks two files to
        # EACH OTHER — so naming the cache as the holder was a provenance claim the instrument never
        # checked (#1858 review P1→P2). Say what was measured.
        printf '[links]    %s of %s sampled .venv file(s) have nlink > 1 -> BLOCK SHARING (a hardlink,\n' "$links_shared" "$links_total"
        echo "           most often into the uv cache when it is on the same volume — see [uv-cache] above)"
        echo "           (deleting such a venv frees ~0 — another holder keeps the blocks; do NOT rank targets by du)"
    else
        printf '[links]    %s sampled .venv file(s), ALL nlink = 1 -> no hardlinks\n' "$links_total"
        echo "           nlink=1 alone cannot separate CoW (clonefile) sharing from no sharing:"
        echo "           only the df used delta can. Run the measurement below on THIS machine."
    fi

    echo "[measure]  real bytes freed, on THIS machine, for ONE reclaimable worktree:"
    echo "             bash $SCRIPT_NAME --repo <repo> --measure-removal <a pi-reap-worktrees.sh --dry-run reclaimable row> --yes"
    echo "[note]     the honest column is df \`used\` (monotonic); \`avail\` drifts with concurrent writes."
    return 0
}

# ── measure mode (the real-byte figure; deletes exactly one caller-named worktree) ────────────
measure() {
    local repo_canon p_canon anchor before_row after_row before_used after_used real app ratio
    local fs main_wt n f
    local listed=0

    [ "$YES" = 1 ] || die 2 "--measure-removal DELETES the named checkout; re-run with --yes once you have chosen it from a reaper dry-run"
    [ -n "$REPO" ] || die 2 "--measure-removal requires --repo (the repo the worktree is registered in)"
    [ -n "$MEASURE" ] || die 2 "--measure-removal requires a path"

    repo_canon="$(canon_dir "$REPO")" || true
    [ -n "$repo_canon" ] || die 2 "--repo is not a readable directory: '$REPO'"
    p_canon="$(canon_dir "$MEASURE")" || true
    [ -n "$p_canon" ] || die 2 "--measure-removal path is not a readable directory: '$MEASURE'"

    # Self-protection: never delete the tree we are running inside, nor an ancestor of it.
    # BOTH SIDES ARE CANONICALISED (#1858 review P1). $p_canon is `pwd -P` output while $PWD is
    # bash's LOGICAL cwd, so any symlinked path component defeated both arms — and on macOS
    # /tmp -> /private/tmp and /var -> /private/var are symlinks, i.e. every fixture under $TMPDIR
    # hit it. Measured: `cd $TMPDIR/lnk/wt/sub` then `--measure-removal <the real wt>` REMOVED the
    # worktree containing the process's cwd. A guard that fails open on a path SPELLING is not a
    # guard; canonicalise the cwd the same way the target was canonicalised.
    pwd_canon="$(canon_dir "$PWD")" || true
    case "$pwd_canon" in
        ''|"$p_canon"|"$p_canon"/*) die 3 "refusing to remove '$p_canon': it contains this process's cwd" ;;
    esac

    # It must be a REGISTERED worktree of --repo. `git worktree list --porcelain` is the only
    # source of that truth (the same source the reaper uses), and its paths are resolved.
    local p
    while IFS= read -r p; do
        [ "$p" = "$p_canon" ] && listed=1
    done < <("$GIT_BIN" -C "$repo_canon" worktree list --porcelain 2>/dev/null | awk '/^worktree /{sub(/^worktree /,""); print}')
    [ "$listed" = 1 ] || die 3 "'$p_canon' is not a registered worktree of '$repo_canon' — refusing (use --dir for the non-destructive report)"

    main_wt="$("$GIT_BIN" -C "$repo_canon" worktree list --porcelain 2>/dev/null | awk '/^worktree /{sub(/^worktree /,""); print; exit}')"
    case "$main_wt" in
        ''|"$p_canon") die 3 "refusing to remove '$p_canon': it is the repo's main checkout (or could not be ruled out)" ;;
    esac

    # Anchor the df readings on the parent directory: it is on the volume that changes and it
    # still exists after the child checkout is removed.
    anchor="$(dirname "$p_canon")"

    # EVERY INSTRUMENT READ THAT TAKES TIME HAPPENS BEFORE THE BASELINE (#1858 review P1).
    # The `du` walk and the nlink sample used to sit BETWEEN the two df readings, so "real" was
    # not "the bytes this removal freed" but "this removal PLUS however far the volume drifted
    # during a full tree walk" — and on the shared box this file's own §3.5 decision #1 describes
    # (~1 MB/s of other writers), a small worktree plus a few seconds of drift lands squarely in
    # the band where the verdict prints the confident "REAL … du is a VALID instrument here".
    # Neither the >1.1·app nor the <=0 arm catches that band. Baseline immediately before removal.
    app=""
    app_partial=0
    if [ "$NO_DU" = 1 ]; then
        :   # --no-du is honoured here too; measure() used to walk anyway (#1858 review P2).
    else
        if app="$(du_total "$p_canon")"; then
            :
        else
            # A non-zero `du` prints a PARTIAL total: a LOWER bound. Using it as the apparent
            # figure makes `real > 1.1·app` fire on an undercount and diagnose "other writers"
            # for du's own missing subtree (#1858 review P1) — so no ratio is claimed from it.
            app_partial=1
            [ -n "$app" ] && :
        fi
    fi
    n=""
    f="$("$FIND_BIN" "$p_canon/.venv/lib" -maxdepth 6 -type f -name '*.py' 2>/dev/null | head -n 1)"
    [ -n "$f" ] && n="$(stat_nlink "$f")"

    before_row="$(df_row "$anchor")"
    [ -n "$before_row" ] || die 3 "df gave no usable answer for '$anchor' BEFORE removal — nothing measured, nothing removed"
    fs="$(printf '%s' "$before_row" | cut -f1)"
    before_used="$(printf '%s' "$before_row" | cut -f3)"

    echo "worktree-disk-probe --measure-removal — ${ISSUE_REF}"
    echo ""
    printf '[before]   %s used %s KiB  (anchor %s)\n' "$fs" "$before_used" "$anchor"
    if [ "$NO_DU" = 1 ]; then
        echo "[apparent] (skipped — --no-du) — the df figure below is still measured"
    elif [ "$app_partial" = 1 ]; then
        printf '[apparent] %s KiB  (%s -sk read a PARTIAL walk — it exited non-zero, so an unreadable\n' "${app:-?}" "$DU_BIN"
        echo "           subtree was skipped and this is a LOWER bound, not an upper bound)."
        echo "           No ratio is claimed from it: an undercount would make the >1.1 test fire and"
        echo "           blame other writers for a subtree du could not read."
        app=""
    elif [ -n "$app" ]; then
        printf '[apparent] %s KiB  (%s -sk, an UPPER BOUND — du alone is not the real figure)\n' "$app" "$DU_BIN"
    else
        echo "[apparent] unreadable (du gave no answer) — reporting the df figure only"
    fi
    case "$n" in
        ''|*[!0-9]*) : ;;
        1)   echo '[nlink]    sample .venv file nlink = 1 (no hardlink; CoW sharing is still possible)' ;;
        *)   printf '[nlink]    sample .venv file nlink = %s (block SHARING — a hardlink; who holds the other link is not what was read)\n' "$n" ;;
    esac

    printf '[remove]   %s -C %s worktree remove %s\n' "$GIT_BIN" "$repo_canon" "$p_canon"
    if ! "$GIT_BIN" -C "$repo_canon" worktree remove "$p_canon"; then
        die 4 "git refused or failed the removal of '$p_canon' — nothing measured (git refuses tracked/untracked dirt; branch refs are never deleted)"
    fi
    [ -d "$p_canon" ] && die 4 "git reported success but '$p_canon' is still present — refusing to report a measurement"

    sync 2>/dev/null || true
    [ "$SETTLE" -gt 0 ] && sleep "$SETTLE"
    after_row="$(df_row "$anchor")"
    [ -n "$after_row" ] || die 3 "df gave no usable answer for '$anchor' AFTER removal — no real figure can be reported"
    after_used="$(printf '%s' "$after_row" | cut -f3)"

    real=$((before_used - after_used))
    printf '[after]    %s used %s KiB\n' "$fs" "$after_used"
    printf '[real]     %s KiB released (df -Pk used delta: %s - %s; concurrent writes can MASK a small\n' \
        "$real" "$before_used" "$after_used"
    echo "           removal — or INFLATE it; a delta above the apparent size is reported as no figure)"

    if [ "$real" -le 0 ]; then
        echo "[ratio]    n/a"
        echo "[verdict]  NO REAL FIGURE: the used delta was <= 0. Re-run on a quieter machine (the fleet's"
        echo "           own writes on a shared box can hide a small removal). This is NOT a pass."
        return 0
    fi

    if [ -n "$app" ]; then
        ratio="$(awk -v a="$app" -v r="$real" 'BEGIN { printf "%.2f", a / r }')"
        printf '[ratio]    apparent/real = %s\n' "$ratio"
        # A delta LARGER than the apparent size cannot have come from this removal — it is proof
        # that other writers' bytes were counted, so the window has no attribution (#1858 review
        # P1). Without this branch the ratio falls below 1.0, misses the `> 1.1` test and prints
        # the CONFIDENT "REAL … du is a VALID instrument here" verdict — a false PASS, and the one
        # the file's own §3.5 decision #1 (a shared box's df delta has no attribution) forbids.
        # 10% slack absorbs block-accounting noise on an otherwise quiet box.
        if awk -v a="$app" -v r="$real" 'BEGIN { exit !(r > a * 11 / 10) }'; then
            echo "[ratio]    apparent/real = $ratio — the used delta EXCEEDS the apparent size"
            echo "[verdict]  NO REAL FIGURE: the used delta is LARGER than what this worktree could"
            echo "           have held, so other writers were counted in the window. Nothing here is"
            echo "           attributable to this removal. This is NOT a pass — re-run on a quieter"
            echo "           machine (WORKTREE_DISK_PROBE_SETTLE=N allows writeback to land)."
            return 0
        fi
        if awk -v r="$ratio" 'BEGIN { exit !(r > 1.1) }'; then
            echo "[verdict]  SHARED: du OVER-reports what removing this worktree frees on THIS machine"
            echo "           (apparent/real = $ratio). Reap whole worktrees; do NOT rank or shrink by du."
        else
            echo "[verdict]  REAL: removing this worktree released ~its apparent size on THIS machine"
            echo "           (apparent/real = $ratio). du is a VALID instrument here — reap was the right lever."
        fi
    else
        echo "[ratio]    n/a (no du reading)"
        echo "[verdict]  real figure above; no apparent figure was read, so no ratio is claimed."
    fi
    return 0
}

if [ -n "$MEASURE" ]; then
    measure
else
    report
fi
