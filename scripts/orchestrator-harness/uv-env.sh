#!/usr/bin/env bash
# uv-env.sh — the uv CACHE + LINK-MODE pin every box gets, and the cold-cache reading that says what
# a worktree venv actually costs (agent-infra#2159).
#
# ── THE TWO SILENT ARITHMETICS THIS FILE EXISTS FOR ─────────────────────────────────────────────
# A per-worktree `.venv` is the fleet's largest regenerable object, and its REAL cost is not a
# property of the venv — it is a property of the box's uv cache, which nothing in the delivery path
# used to pin. Measured 2026-10-30 on the three cmux cells (the comment on #2159 that governs this
# file):
#
#   cell  cpus  MemAvail  swap used     disk free   ~/.cache/uv   consequence
#   1     8     6.4 GB    773 MB        20.5 GB     12,337 MB     venvs hardlink -> ~FREE
#   3     4     3.1 GB    3,263 MB(80%)   257 MB          0 MB     every venv is a full 5.8 GB COPY
#   4     8     10.0 GB   177 MB         8.7 GB      6,635 MB     venvs hardlink -> ~FREE
#
# So "1.1 GB per worktree" is TRUE on one cell and FALSE on another, and BOTH readings are correct:
#
#   * WARM cache: `uv` hardlinks the venv's files to cache entries, so `du -sh .venv` (5,730 MB)
#     overstates the marginal cost enormously and DELETING the venv frees ~nothing. This is why
#     "delete the venvs" is a REJECTED remedy (#2159, measured 2026-10-30 06:56) — six worktrees read
#     18,134 MB nominal against 11,538 MB distinct, `libtorch_cpu.so` being the same inode as its
#     `~/.cache/uv/archive-v0/…` entry.
#   * COLD cache: there is nothing to link to, so the sync MATERIALISES every byte. cell-3 went
#     17 GB free -> 257 MB free in ~50 minutes as its lanes synced, and each worktree paid the full
#     ~5.8 GB.
#
# The lever is therefore the CACHE, and it must be delivered by the code that sets a box up — not by
# an operator's `sed` on one box's profile. That is what `apply` does, and why it is wired into every
# delivery path (macOS launchd plist, Linux cell bring-up, the cell supervisor, and the per-lane env
# snapshot `worker-terminal.sh` writes).
#
# ── WHAT IS *NOT* DUPLICATED HERE ───────────────────────────────────────────────────────────────
# The reclaim classes already exist and are NOT re-implemented: `pi-cache-reap.sh` (preserves an entry
# that is still hardlinked — unlinking it frees nothing), `disk-floor.sh` (`uv cache prune`, then
# `uv cache clean` only under real pressure) and `cloud-cell-supervisor.sh hygiene`. `uv cache prune`
# removes UNUSED entries and centralised project environments (uv's own docs), which by definition
# cannot touch a live lane's bytes — measured on cell-3: `Removed 39558 files (6.4GiB)`, df
# 1,319 MB -> 5,036 MB, with a lane importing torch afterwards. This file only READS, and NAMES the
# existing remedy; a second deleter would be a second safety argument to get wrong.
#
# ── WHY `UV_LINK_MODE=hardlink` IS PINNED RATHER THAN LEFT TO THE DEFAULT ───────────────────────
# uv's default link mode is `clone` when the filesystem can clone and otherwise falls back; a clone
# (copy-on-write) venv is cheap in BYTES but its `du` is the full apparent size, and on a box whose
# filesystem cannot clone the fallback chain is not something a capacity number can be derived from.
# `hardlink` makes the sharing POSITIVE and MEASURABLE (`nlink > 1` on a `site-packages` file), which
# is what lets the report below state a fact instead of a hope. An operator's explicit pin always
# WINS — this file defaults, it never overrides.
#
# Usage:
#   uv-env.sh apply                     print the export lines (env snapshot / keys.env fragment)
#   uv-env.sh report [--estate DIR]     one-line reading: cache size, link mode, sharing verdict
#   uv-env.sh distinct DIR [DIR...]     du-summed-by-dir vs distinct(one invocation) bytes
#   uv-env.sh cache-dir                 the cache directory this box resolves
#
# Sourceable: `uv_env_apply`, `uv_env_report`, `uv_env_distinct_bytes`, `uv_env_cache_dir`,
# `uv_env_link_mode`, `uv_env_export_lines`. Nothing runs on source; the caller decides.
# POSIX-ish bash 3.2 (macOS) safe: no associative arrays, no `mapfile`, no `${x^^}`.

UV_ENV_NAME="uv-env.sh"
# The cache size at or below which a venv cannot be hardlinked from anything: if the cache holds less
# than this, the first sync on the box pays full price for every byte. A seam (not a constant) so a
# test can drive BOTH verdicts deterministically; a bad value falls back to the default.
UV_ENV_COLD_CACHE_MB_DEFAULT=1024

# `[base-home]`: the home the DEFAULT resolves under. The cell bring-up runs before `HOME` becomes
# `$CELL_HOME`, and resolving the cache under the ambient `$HOME` pinned `/root/.cache/uv` for a box
# whose lanes then ran under `/tmp/cell-home` — two caches, no cross-sharing, every venv a full copy
# (review finding). XDG_CACHE_HOME still wins, and a pinned UV_CACHE_DIR always wins.
# ⛔ A PASSED BASE HOME OUTRANKS AN AMBIENT `XDG_CACHE_HOME` (review round 2, measured):
# `XDG_CACHE_HOME=/root/.cache uv_env_apply /tmp/cell-home` pinned `/root/.cache/uv` — the very two-
# cache defect the base-home parameter was added to remove, one variable over. On a cell, XDG can only
# be an ambient leftover (nothing normalises it the way `setup_home` normalises `$HOME`), while a base
# home is a statement about the home the lanes will run under. With NO base home passed, uv's own
# precedence stands: `$XDG_CACHE_HOME/uv`, else `$HOME/.cache/uv`.
uv_env_cache_dir() { # [base-home]
  if [ -n "${1:-}" ]; then
    printf '%s\n' "${UV_CACHE_DIR:-$1/.cache/uv}"
  else
    printf '%s\n' "${UV_CACHE_DIR:-${XDG_CACHE_HOME:-${HOME:-}/.cache}/uv}"
  fi
}
uv_env_link_mode() { printf '%s\n' "${UV_LINK_MODE:-hardlink}"; }

# shell single-quote: the one quoting that is identical in bash 3.2 and 5.x.
uv_env_shq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

uv_env_export_lines() {
  printf 'export UV_CACHE_DIR=%s\n' "$(uv_env_shq "$(uv_env_cache_dir)")"
  printf 'export UV_LINK_MODE=%s\n' "$(uv_env_shq "$(uv_env_link_mode)")"
}

# Set the two variables in the CALLER's shell, defaulting only when they are genuinely unset/empty.
# `UV_ENV_DEFAULTED` records what this call supplied ("cache", "link", "cache link", or "none") so a
# caller can SAY it defaulted instead of silently pinning a box — the #2159 defect was invisible.
uv_env_apply() { # [base-home] — the home the CACHE default resolves under (defaults to $HOME)
  local d="" base="${1:-}"
  case "${UV_CACHE_DIR:-}" in
    # An ABSENT argument is not an empty one: with no base home named, uv's own precedence applies
    # (XDG_CACHE_HOME first). Passing `$HOME` unconditionally would have silently retired that knob.
    '') if [ -n "$base" ]; then UV_CACHE_DIR="$(uv_env_cache_dir "$base")"; else UV_CACHE_DIR="$(uv_env_cache_dir)"; fi
        d="cache" ;;
  esac
  case "${UV_LINK_MODE:-}" in
    '') UV_LINK_MODE="hardlink"; d="${d:+$d }link" ;;
  esac
  # ⛔ THE PIN MUST NOT BE A PATH THAT DOES NOT EXIST YET ON A FRESH BOX: `uv` creates it, but a
  # report that says "cache 0MB" for a directory nobody made is indistinguishable from a box whose
  # cache was deleted. The distinction is carried by `uv_env_report`, never by a fabricated `mkdir`.
  export UV_CACHE_DIR UV_LINK_MODE
  # ⛔ PROVENANCE IS RECORDED BY VALUE, NOT ONCE-AND-FROZEN — both simpler rules are wrong, and both
  # were measured on this file (review rounds 1 and 2):
  #   * recomputing from "is it set now" reported `none` on the SECOND apply, because the FIRST call's
  #     own default made it set: a cell that defaulted its cache was announced as operator-pinned;
  #   * freezing the first record was the mirror image: a `keys.env` that pins the cache AFTER the
  #     early apply (the bring-up's own order) kept reading `defaulted: cache link`, so every
  #     operator-pinned cell got a false `warn:` and advice to do what it had already done.
  # So each half we supply is remembered with the value we supplied, and a half counts as DEFAULTED
  # only while the box still holds exactly that value.
  case "$d" in
    *cache*) [ -n "${UV_ENV_SUPPLIED_CACHE:-}" ] || UV_ENV_SUPPLIED_CACHE="$UV_CACHE_DIR" ;;
  esac
  case "$d" in
    *link*)  [ -n "${UV_ENV_SUPPLIED_LINK:-}" ] || UV_ENV_SUPPLIED_LINK="$UV_LINK_MODE" ;;
  esac
  d=""
  if [ -n "${UV_ENV_SUPPLIED_CACHE:-}" ] && [ "$UV_CACHE_DIR" = "$UV_ENV_SUPPLIED_CACHE" ]; then d="cache"; fi
  if [ -n "${UV_ENV_SUPPLIED_LINK:-}" ] && [ "$UV_LINK_MODE" = "$UV_ENV_SUPPLIED_LINK" ]; then d="${d:+$d }link"; fi
  UV_ENV_DEFAULTED="${d:-none}"
  return 0
}

uv_env_mb() { # <kb> -> MB, integer
  case "${1:-}" in ''|*[!0-9]*) printf '?' ; return 0 ;; esac
  printf '%s' $(( $1 / 1024 ))
}

# THE COLD FLOOR, resolved once so the resolution itself is testable: an unusable or zero value falls
# back to the default rather than DISABLING the check (a `0` floor would silently certify every box as
# warm — the "a seam that switches the gate off" class).
uv_env_cold_floor() {
  local v="${UV_ENV_COLD_CACHE_MB:-}"
  case "$v" in ''|*[!0-9]*|0*) v="$UV_ENV_COLD_CACHE_MB_DEFAULT" ;; esac
  printf '%s\n' "$v"
}

# Bounded size of a directory in KiB, or empty when unreadable. `du -sk` (not `-sh`) so the number has
# one format on both platforms; a symlinked cache is resolved first, because `du -sk <link>` stats the
# LINK — the "0MB on a 7.1GB cache" blind spot cloud-cell-bringup.sh already records.
# ⛔ THREE STATES, NOT TWO (review finding): "measured", "absent" and "UNMEASURABLE". `du` exits
# non-zero while still printing a partial total when any subtree is unreadable (measured elsewhere in
# this repo: a 3,016 KiB tree with one mode-000 subdir prints `16` and exits 1), so collapsing a
# failed read into `0` reported a WARM 12 GB cache as `0MB` and then as COLD-CACHE — announcing the
# opposite of the truth on the one verdict this file exists to produce. Only a `measured` value may be
# compared against the cold floor; `unmeasurable` is CANNOT-VERIFY and says so.
uv_env_measure_dir() { # <dir> -> "measured <kb>" | "absent" | "unmeasurable"
  local d="${1:-}" out rc
  [ -n "$d" ] || { printf 'absent\n'; return 0; }
  if [ ! -d "$d" ]; then printf 'absent\n'; return 0; fi
  if [ -L "$d" ]; then
    d="$(cd "$d" 2>/dev/null && pwd -P)" || { printf 'unmeasurable\n'; return 0; }
  fi
  out="$(du -sk "$d" 2>/dev/null)"; rc=$?
  out="${out%%[[:space:]]*}"
  case "$out" in ''|*[!0-9]*) printf 'unmeasurable\n'; return 0 ;; esac
  [ "$rc" -eq 0 ] || { printf 'unmeasurable\n'; return 0; }
  printf 'measured %s\n' "$out"
}

uv_env_du_kb() { # <dir> -> KiB on stdout, non-zero unless the read was COMPLETE
  local st kind kb
  st="$(uv_env_measure_dir "${1:-}")"
  kind="${st%% *}"; kb="${st#* }"
  [ "$kind" = "measured" ] || return 1
  printf '%s\n' "$kb"
}

# THE SHARING reading: sample `site-packages` files under every `*/.venv` in <estate> and count how
# many have nlink > 1. nlink > 1 proves the blocks are SHARED (a hardlink); it does NOT prove WHO holds
# the other name — that is `worktree-disk-probe.sh`'s separate, deliberate caution and it applies here.
# Prints "<shared> <sampled>"; empty when nothing could be sampled.
# The venv DIRECTORIES first, then the sample inside each. A single depth-limited PATTERN was
# reviewed and rejected: at `--estate $WORKDIR` (the cell's bring-up root, checkout one level below) a
# venv file sits at depth 9, so the pattern matched NOTHING on the layout a cell actually has and the
# report then asserted "no worktree .venv exists" about a hardlinked venv that was present. Locating
# the directory is the cheap, layout-tolerant half; the bounded sample stays bounded.
uv_env_venv_dirs() { # <estate> [max-venvs]
  local estate="${1:-}" maxv="${2:-20}" d n=0
  [ -n "$estate" ] && [ -d "$estate" ] || return 1
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    printf '%s\n' "$d"
    n=$(( n + 1 ))
    [ "$n" -ge "$maxv" ] && break
  done <<EOF
$(find "$estate" -maxdepth 5 -type d -name .venv 2>/dev/null | head -n "$maxv")
EOF
  return 0
}

# Sets UV_ENV_LINKS_SHARED / UV_ENV_LINKS_TOTAL (never prints, never decides) so the caller can tell
# "no venv to sample" from "a venv exists but nothing in it could be read" — the second must not read
# as warmth. Returns 1 when nothing could be sampled.
uv_env_sample_links() { # <estate> [max-files]
  local estate="${1:-}" max="${2:-50}" n=0 shared=0 f l venv
  UV_ENV_LINKS_SHARED=0
  UV_ENV_LINKS_TOTAL=0
  [ -n "$estate" ] && [ -d "$estate" ] || return 1
  while IFS= read -r venv; do
    [ -n "$venv" ] || continue
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      l="$(stat -c '%h' "$f" 2>/dev/null || stat -f '%l' "$f" 2>/dev/null)" || l=""
      case "$l" in ''|*[!0-9]*) continue ;; esac
      n=$(( n + 1 ))
      [ "$l" -gt 1 ] && shared=$(( shared + 1 ))
      [ "$n" -ge "$max" ] && break
    done <<EOF
$(find "$venv/lib" -maxdepth 4 -type f -path '*site-packages/*' 2>/dev/null | head -n "$max")
EOF
    [ "$n" -ge "$max" ] && break
  done <<EOF2
$(uv_env_venv_dirs "$estate")
EOF2
  UV_ENV_LINKS_SHARED=$shared
  UV_ENV_LINKS_TOTAL=$n
  [ "$n" -gt 0 ] || return 1
  return 0
}

# The reading. One line of FACT, then a VERDICT line that names the cost of the next sync and the
# remedy that is actually available on this box. Never exits non-zero: this is a report, and a report
# that fails closed when the cache is unreadable is the same blind spot in a new costume.
uv_env_report() { # [--estate DIR]
  local estate="" cache cache_kb cache_mb mode cold state kind bonds
  while [ $# -gt 0 ]; do
    case "$1" in
      --estate) [ -n "${2:-}" ] && { estate="$2"; shift 2; } || shift ;;
      *) shift ;;
    esac
  done
  [ -n "$estate" ] || estate="${UV_ENV_ESTATE:-}"
  mode="$(uv_env_link_mode)"
  cache="$(uv_env_cache_dir)"
  cold="$(uv_env_cold_floor)"

  state="$(uv_env_measure_dir "$cache")"
  kind="${state%% *}"; cache_kb="${state#* }"
  case "$kind" in
    measured) cache_mb="$(uv_env_mb "$cache_kb")" ;;
    absent)   cache_mb="absent" ;;
    *)        cache_mb="UNMEASURABLE" ;;
  esac

  printf '[uv-env] cache=%s %s link_mode=%s%s\n' "$cache" \
    "$(case "$cache_mb" in absent|UNMEASURABLE) printf '%s' "$cache_mb" ;; *) printf '%sMB' "$cache_mb" ;; esac)" \
    "$mode" \
    "$(case "${UV_ENV_DEFAULTED:-none}" in none|'') printf '' ;; *) printf ' (defaulted: %s)' "$UV_ENV_DEFAULTED" ;; esac)"

  if [ "$mode" != "hardlink" ]; then
    # A deliberate non-hardlink pin is not a defect of this file — it is an operator decision (a
    # filesystem with no hardlink support, or a cache on another device where a hardlink cannot
    # exist). It IS a cost, and the cost is what has to be said out loud.
    printf '[uv-env] verdict=NOT-SHARING-BY-DESIGN: UV_LINK_MODE=%s — each worktree venv pays its FULL size (measured 5,730MB for a tortoise worktree) and N lanes need N copies. The shipped pin is `hardlink`; if this value was set on purpose, the per-worktree cost is the intended trade.\n' "$mode"
    return 0
  fi

  # ⛔ ONLY A MEASURED SIZE MAY REACH THE FLOOR COMPARISON. An unreadable cache is NOT "cold" — it is
  # unknown, and reporting it cold would send an operator to prune a cache nobody measured.
  if [ "$cache_mb" = "UNMEASURABLE" ]; then
    printf '[uv-env] verdict=CACHE-UNMEASURABLE: %s cannot be measured (`du` failed or a subtree is unreadable), so whether this box is COLD or WARM is UNKNOWN — which is not the same as either. Fix the read (permissions on the cache, a wedged mount) and re-run; do not prune a cache you could not measure.\n' "$cache"
    return 0
  fi
  if [ "$cache_mb" = "absent" ] || [ "$cache_mb" -lt "$cold" ] 2>/dev/null; then
    printf '[uv-env] verdict=COLD-CACHE: the cache holds less than %sMB, so the next `uv sync` has nothing to link to and MATERIALISES every byte — on a tortoise checkout that is ~5,800MB PER WORKTREE (measured cell-3: 17GB free -> 257MB free in ~50 min as its lanes synced). This is a CACHE problem: warm it (let one sync finish, then every later venv is nearly free), and reclaim with `uv cache prune` (unused + centralised envs only — it cannot touch the bytes of a live lane; measured: 6.4GiB freed, a live lane still imported torch). Do NOT delete a venv on a box whose cache is warm: `du` there reports 5,730MB while the distinct cost is ~0 (#2159).\n' "$cold"
    return 0
  fi

  if uv_env_sample_links "$estate"; then
    if [ "$UV_ENV_LINKS_SHARED" -gt 0 ]; then
      printf '[uv-env] verdict=WARM-SHARED: %s of %s sampled .venv file(s) have nlink>1, so venv bytes are shared with the cache — a new worktree venv costs the DIFFERENCE, not its `du` (measured: 18,134MB across six worktrees vs 11,538MB distinct). Read distinct bytes, not the sum of per-worktree `du`.\n' "$UV_ENV_LINKS_SHARED" "$UV_ENV_LINKS_TOTAL"
    else
      printf '[uv-env] verdict=NOT-SHARED: the cache is %sMB (>= the %sMB cold floor) but ALL %s sampled .venv file(s) have nlink=1 — the sharing is not happening on this box (a cache on another filesystem, a copy-on-write clone, or a --link-mode=copy pin). nlink=1 alone cannot separate CoW sharing from none, so MEASURE removal (`worktree-disk-probe.sh --measure-removal`) before believing either number.\n' "$cache_mb" "$cold" "$UV_ENV_LINKS_TOTAL"
    fi
    return 0
  fi
  # A VENV THAT EXISTS BUT COULD NOT BE SAMPLED IS NOT WARMTH (review finding): the two states have
  # different meanings and different remedies, so they get different verdicts.
  if [ -n "$estate" ] && [ -n "$(uv_env_venv_dirs "$estate" | head -1)" ]; then
    printf '[uv-env] verdict=SHARING-UNMEASURED: a .venv exists under %s but no file in it could be sampled (unreadable, or no site-packages yet) — whether these venvs share bytes with the cache is UNKNOWN, not confirmed.\n' "$estate"
    return 0
  fi
  printf '[uv-env] verdict=WARM-NO-VENV: the cache is %sMB and no worktree .venv was found to sample%s — the next sync should be nearly free, and the reading becomes positive (nlink>1) as soon as one exists.\n' \
    "$cache_mb" "${estate:+ under $estate}"
  return 0
}

# THE ACCOUNTING fix (#2159 item 3): a report that `du`s each worktree separately and ADDS the numbers
# counts a shared inode once per worktree. `du` deduplicates a hardlinked inode WITHIN one invocation,
# so the honest distinct figure is a SINGLE `du` over the whole set. This prints both, so a hardlinked
# box is never read as "no room", and the gap is the size of the lie.
#   du_sum_mb   what `du -sk WT1; du -sk WT2; …` summed     (over-reports)
#   distinct_mb what `du -sk -c WT1 WT2 …` says             (the bytes actually held)
#   shared_mb   the difference — bytes held by more than one name
uv_env_distinct_bytes() { # <dir>...
  local sum_kb=0 kb d total="" raw rc all unmeasured=0
  local -a dirs=()
  for d in "$@"; do
    [ -n "$d" ] && [ -e "$d" ] || continue
    dirs[${#dirs[@]}]="$d"
    if kb="$(uv_env_du_kb "$d")"; then sum_kb=$(( sum_kb + kb )); else unmeasured=$(( unmeasured + 1 )); fi
  done
  [ "${#dirs[@]}" -gt 0 ] || { printf 'du_sum_kb=0 distinct_kb=0 shared_kb=0 (no readable directory)\n'; return 1; }
  # ⛔ THE WALK'S STATUS IS READ, NOT THE PIPELINE'S (review round 2, measured). `${PIPESTATUS[0]}` /
  # an awk tail reports awk's status, so `du` exiting 1 on an unreadable subtree was invisible while it
  # still printed a PARTIAL total; the per-dir sum then dropped that directory and the subtraction
  # published `du_sum_mb=2 distinct_mb=8 shared_mb=0` — an IMPOSSIBLE result (distinct <= sum by
  # construction), clamped to a "nothing is shared" that reads as measured and supports the deleted-venv
  # remedy. A partial or unmeasurable read is reported as PARTIAL, never as a number.
  raw="$(du -skc "${dirs[@]}" 2>/dev/null)"; rc=$?
  all="$(printf '%s\n' "$raw" | awk 'END{print $1}')"
  if [ "$rc" -ne 0 ] || [ "$unmeasured" -gt 0 ]; then
    printf 'du_sum_mb=%s distinct_mb=? shared_mb=? (PARTIAL walk: %s unmeasurable dir(s), du rc=%s — fix the unreadable subtree, never read this as "nothing is shared")\n' \
      "$(uv_env_mb "$sum_kb")" "$unmeasured" "$rc"
    return 1
  fi
  case "${all:-}" in
    ''|*[!0-9]*) printf 'du_sum_mb=%s distinct_mb=? shared_mb=? (one-invocation du gave no total)\n' "$(uv_env_mb "$sum_kb")"; return 1 ;;
  esac
  local shared_kb=$(( sum_kb - all ))
  [ "$shared_kb" -ge 0 ] || { printf 'du_sum_kb=%s distinct_kb=%s (INCONSISTENT: distinct > per-dir sum, which cannot happen — refusing to report a shared figure)\n' "$sum_kb" "$all"; return 1; }
  # MB for reading, KiB for the sub-megabyte case: `uv_env_mb` truncates, so a real 52 KiB gap printed
  # as `shared_mb=0` — a measured zero from a rounded number (review round 2).
  printf 'du_sum_mb=%s distinct_mb=%s shared_mb=%s du_sum_kb=%s distinct_kb=%s shared_kb=%s\n' \
    "$(uv_env_mb "$sum_kb")" "$(uv_env_mb "$all")" "$(uv_env_mb "$shared_kb")" "$sum_kb" "$all" "$shared_kb"
}

# ── THE ONE BIT THE ADMISSION GATE NEEDS (agent-infra#2159, extending #2850/#2721) ──────────────
# `spawn-gate.sh` admits a python lane on `max(tree, self) + reserve`, where `self` is the FULL-
# materialise worst case (6144MB) for a box whose venv cannot be linked into the cache. That number is
# RIGHT for such a box and it is ~19x the measured marginal cost of the same lane (316MB) on a box
# that shares — so on a 121GB cell with 16GB free it admits ONE python lane where the measurement
# admits tens. The gate cannot measure this itself: `uv_env_report` walks the cache, and a spawn would
# pay for that walk on every lane.
#
# So the question is reduced to ONE BIT, answered from a RECORD refreshed at most once per day:
#   SHARED — this box links worktree venvs into its cache, so a lane costs `tree`, not `self`.
#   FULL   — anything else. Sharing is not guaranteed, so admit on the worst case.
# ⛔ FAIL-CLOSED IS THE ENTIRE SAFETY ARGUMENT. Every absent, unreadable, stale, malformed or
# unrecognised state returns FULL, which is exactly today's admission. A box becomes cheaper to admit
# onto ONLY by producing positive evidence (link_mode=hardlink AND a cache measured at or above the
# cold floor). Loosening admission is a capacity change; it may never happen by accident, a typo, or a
# missing file — that is the inert-gate class, and here the inert direction *adds* lanes.
# Record: one tab-separated line, `token<TAB>epoch<TAB>link_mode<TAB>cache_mb<TAB>cache_dir`, so a
# reader that finds the admission loosened can SEE what it rested on instead of trusting a word.
UV_ENV_SHARING_RECORD="${UV_ENV_SHARING_RECORD:-uv-env-sharing}"
UV_ENV_SHARING_MAX_AGE_S="${UV_ENV_SHARING_MAX_AGE_S:-86400}"

uv_env_sharing_record_path() { printf '%s/%s\n' "${1:-}" "$UV_ENV_SHARING_RECORD"; }

# The token, from raw evidence. Total for any input; every unknown is FULL.
uv_env_sharing_token_from() { # <link_mode> <measure-kind> <cache-mb>
  local mode="${1:-}" kind="${2:-}" mb="${3:-0}" cold
  [ "$mode" = "hardlink" ] || { printf 'FULL\n'; return 0; }
  [ "$kind" = "measured" ] || { printf 'FULL\n'; return 0; }
  case "$mb" in ''|*[!0-9]*) printf 'FULL\n'; return 0 ;; esac
  cold="$(uv_env_cold_floor)"
  [ "$mb" -ge "$cold" ] || { printf 'FULL\n'; return 0; }
  printf 'SHARED\n'
}

# Refresh the record from a live measurement. The ONLY place the cache is walked for this bit.
uv_env_sharing_record_write() { # <state-dir>
  local dir="${1:-}" mode state kind kb mb token
  [ -n "$dir" ] || return 1
  mode="$(uv_env_link_mode)"
  state="$(uv_env_measure_dir "$(uv_env_cache_dir)")"
  kind="${state%% *}"; kb="${state#* }"
  case "$kind" in measured) mb="$(uv_env_mb "$kb")" ;; *) mb=0 ;; esac
  token="$(uv_env_sharing_token_from "$mode" "$kind" "$mb")"
  mkdir -p "$dir" 2>/dev/null || return 1
  printf '%s\t%s\t%s\t%s\t%s\n' "$token" "$(date +%s)" "$mode" \
    "$(case "$kind" in measured) printf '%s' "$mb" ;; *) printf '%s' "$kind" ;; esac)" \
    "$(uv_env_cache_dir)" > "$(uv_env_sharing_record_path "$dir")" 2>/dev/null || return 1
  return 0
}

# THE READER. Prints SHARED or FULL, always, and never fails.
# A stale record is REFRESHED here (once per UV_ENV_SHARING_MAX_AGE_S) rather than merely distrusted:
# a record that is only ever written by a bring-up goes stale on a box that never gets re-provisioned,
# and then the gate silently returns to the pessimistic constant for ever — an admitted lane's cost
# would depend on how long ago the box was built. One bounded `du` per day is the cheaper contract.
# ⛔ A REFRESH THAT CANNOT MEASURE WRITES NOTHING and returns FULL: an unreadable cache must not be
# allowed to overwrite a good SHARED record with a pessimistic one either, because that would make a
# transient mount hiccup permanently halve a cell's capacity until the next bring-up.
uv_env_sharing_token() { # <state-dir>
  local dir="${1:-}" f tok ts now max age
  if [ -z "$dir" ]; then printf 'FULL\n'; return 0; fi
  f="$(uv_env_sharing_record_path "$dir")"
  max="$UV_ENV_SHARING_MAX_AGE_S"
  case "$max" in ''|*[!0-9]*) max=86400 ;; esac
  now="$(date +%s)"
  if [ -r "$f" ]; then
    tok="$(cut -f1 "$f" 2>/dev/null)"
    ts="$(cut -f2 "$f" 2>/dev/null)"
    case "$ts" in
      ''|*[!0-9]*) : ;;
      *) age=$(( now - ts ))
         # A record dated in the FUTURE is not fresh, it is wrong (the one-sided age test this repo
         # has already been bitten by): treat it as stale so it is re-measured rather than trusted.
         if [ "$age" -ge 0 ] && [ "$age" -le "$max" ]; then
           case "$tok" in SHARED) printf 'SHARED\n' ;; *) printf 'FULL\n' ;; esac
           return 0
         fi ;;
    esac
  fi
  # Missing or stale: try to refresh. A failure leaves the old record (if any) untouched.
  if uv_env_sharing_record_write "$dir"; then
    tok="$(cut -f1 "$f" 2>/dev/null)"
    case "$tok" in SHARED) printf 'SHARED\n'; return 0 ;; esac
  fi
  printf 'FULL\n'
  return 0
}

uv_env_usage() {
  sed -n '3,6p' "$0" >/dev/null 2>&1 || true
  cat <<'USAGE'
uv-env.sh — the uv cache + link-mode pin and the cold-cache reading (agent-infra#2159)

  uv-env.sh apply                     print the export lines for an env snapshot / plist
  uv-env.sh report [--estate DIR]     cache size, link mode, sharing verdict, what a sync costs
  uv-env.sh distinct DIR [DIR...]     du_sum_mb vs distinct_mb (hardlinks counted once)
  uv-env.sh cache-dir                 the cache directory this box resolves

Seams: UV_CACHE_DIR, XDG_CACHE_HOME, UV_LINK_MODE (all honoured, never overridden),
       UV_ENV_COLD_CACHE_MB (cold floor, default 1024), UV_ENV_ESTATE (default --estate).
USAGE
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    apply)      shift; uv_env_export_lines ;;
    report)     shift; uv_env_report "$@" ;;
    distinct)   shift; [ $# -gt 0 ] || { echo "distinct needs at least one directory" >&2; exit 2; }; uv_env_distinct_bytes "$@" ;;
    cache-dir)  uv_env_cache_dir ;;
    sharing-token) shift; uv_env_sharing_token "${1:-}" ;;
    ''|-h|--help|help) uv_env_usage ;;
    *) echo "$UV_ENV_NAME: unknown argument: $1 (try --help)" >&2; exit 2 ;;
  esac
fi
