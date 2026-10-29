#!/bin/bash
# check-bash32-parse.sh — #2930: every shipped `*.sh` must parse under APPLE'S bash 3.2.
#
# WHY THIS EXISTS. `/bin/bash` on macOS is 3.2.57 (bash 4+ is GPLv3, so Apple never shipped it), and
# the harness's runtime platform is that Mac. CI runs Linux/bash 5, so a construct 3.2 cannot parse
# ships GREEN and only breaks at the destination:
#
#   - `scripts/orchestrator-harness/merge-reminder.test.sh` failed `bash -n` at line 2629 under 3.2,
#     `install.sh` runs `bash -n` over every shipped script and `die`d, so the harness could not be
#     installed on a stock Mac at all — and `install.sh` re-checks the PINNED tree too, so moving the
#     file aside makes the tree DIRTY and the controller reports `harness=dirty:` (a catch-22).
#   - #2248 is the same family one step worse: 3.2 does not merely fail to parse a here-doc nested in
#     a command substitution, it EXECUTES the here-doc's words as commands — a controller that died
#     at source time while its supervisor logged "controller is alive" for an hour.
#
# THE CONSTRUCT. bash 3.2's `$( )` scanner does not know about here-documents: it walks the body as
# if it were code, so an unbalanced quote, backtick or parenthesis INSIDE a here-doc body inside a
# substitution desynchronises the parse state for the REST OF THE FILE. The error is therefore
# reported far below the defect (line 2629 for a body at 2566), and a body that fails this way
# parses fine on its own — which is exactly how it got past review. The remedy is the form #2248
# landed: put the here-doc in a FUNCTION body, so the substitution carries no here-doc
#
#     _probe() { python3 - "$SUT" <<'PY'
#     ...
#     PY
#     }
#     out="$(_probe)"
#
# WHAT THIS GATE MEASURES — the platform, not a proxy. It runs the real `bash -n` under a real bash
# 3.x: the host's own `/bin/bash` where that IS 3.x (macOS, so the gate is meaningful locally), or
# the pinned `bash:3.2` image everywhere else (the same zero-new-deps docker shape as
# scripts/check-workflow-actionlint.sh). A textual scan for `$( … <<'X'` would be a proxy that could
# drift from bash's own parser; this is the parser.
#
# ⛔ FAIL-CLOSED. A gate that cannot run must never read green (#2930 IS the class where a gate that
# could not see the platform reported OK): no interpreter, no docker, an interpreter that is not 3.x,
# and an EMPTY file list each exit 2 and NAME the cause. `BASH32=<path>` is the seam for a box whose
# 3.2 lives elsewhere; it is VERIFIED to be 3.x first, because pointing it at bash 5 would turn the
# leg into a silent pass.
#
# ⛔ WHAT IT DOES NOT CATCH, stated so nobody reads it as more than it is: a here-doc in a `$( )` whose
# body happens to be quote/backtick/paren balanced still PARSES on 3.2 and is still wrong at RUNTIME
# (#2248's shape: the body's words run as commands). This gate is a parse leg; the runtime half of
# that class is pinned textually elsewhere (scripts/orchestrator-harness/worker-terminal.test.sh).
#
# THE POPULATION IS DERIVED FROM THE INDEX, NEVER HAND-KEPT. Both halves of it — the `*.sh` sweep and
# the suffixless bash entry points — are read from `git ls-files`, and the suffixless half is selected
# by the only property that makes a file a bash PROGRAM: its shebang names bash. A hand-kept list is
# what drifted (#2976): it named 4 of the tree's 9 suffixless bash entry points, so the same defect
# introduced later in `bin/harness`, `sync`, `sync-all`, `scripts/gh-shim/gh` or
# `scripts/orchestrator-harness/gh-limit/gh` would still have shipped GREEN — the exact false PASS
# this gate exists to remove. The named list survives only as an ASSERTION (`MUST_DERIVE`): if the
# derivation ever stops seeing a file this repo knows it ships, the gate REDS instead of quietly
# shrinking its population.
#
# Usage:
#   scripts/check-bash32-parse.sh                 # every tracked *.sh (minus tests/fixtures) + every tracked suffixless bash program
#   scripts/check-bash32-parse.sh FILE...         # explicit files (fixture tests)
#   BASH32=/opt/bash-3.2/bin/bash scripts/check-bash32-parse.sh   # pin the interpreter
#   BASH32_IMAGE=<ref> scripts/check-bash32-parse.sh               # override the pinned image (tests)
#   CHECK_BASH32_ROOT=<dir>                        # resolve repo-relative paths against <dir>
#
# Exit: 0 = all parsed; 1 = one or more files failed (each named); 2 = cannot measure.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="${CHECK_BASH32_ROOT:-$(cd "$SELF_DIR/.." && pwd)}"
# Pinned by DIGEST: `bash:3.2` is a moving tag, and a tag that later resolved to bash 4/5 would make
# this leg measure the wrong platform while still printing a green line.
IMAGE="${BASH32_IMAGE:-bash:3.2@sha256:b6252c62fc86114f93f02104a486c71e6569371d95950ea7479a2ffd6b47f16a}"
# ⛔ THIS IS NOT THE POPULATION — the population is derived (see `derive_suffixless`). These are the
# suffixless bash programs this repo KNOWS it ships, kept only so the derivation cannot fail QUIETLY:
# a shebang lost in an edit, a file moved out of the index, or a broken derivation would otherwise
# shrink the sweep while still printing a green line. Each entry is checked against the derived set
# and a miss exits 2 ("cannot measure") rather than passing over a file nobody parsed.
MUST_DERIVE=(bin/harness scripts/gh-shim/gh scripts/harness-up scripts/harness-down
             scripts/harness-status scripts/orchestrator-harness/gh-rest/gh
             scripts/orchestrator-harness/gh-limit/gh sync sync-all)

die() { printf '❌ check-bash32-parse: %s\n' "$*" >&2; exit 2; }

# The suffixless bash programs, read out of the INDEX (the same source as the `*.sh` sweep, so an
# untracked scratch file is not a shipped surface) and selected by the shebang. Reads ONE line per
# tracked file, so it is bounded by the index and never walks the tree (docs/ops/load-policy.md).
# Covered shapes: `#!/bin/bash`, `#!/usr/local/bin/bash -eu`, `#!/usr/bin/env bash`,
# `#!/usr/bin/env -S bash -eu`. Bash versions are matched by the interpreter WORD — the `env` wrapper
# and its flags are skipped — never by a substring, so a `#!/usr/bin/python3` file that merely
# mentions bash is not pulled into a bash parse sweep.
derive_suffixless() {
  local rel first nb tok
  while IFS= read -r rel; do
    case "$rel" in
      *.sh) continue ;;             # already swept by the `*.sh` half above
      tests/fixtures/*) continue ;; # the deliberate 3.2-hostile fixtures (same carve-out, same reason)
    esac
    first=""
    IFS= read -r first <"$ROOT/$rel" 2>/dev/null || continue
    case "$first" in '#!'*) : ;; *) continue ;; esac
    nb="${first:2}"
    # Word splitting IS the tokeniser: a shebang line carries no quoting (SC2086 is intended here).
    # shellcheck disable=SC2086
    set -- $nb
    [ "$#" -gt 0 ] || continue
    [ "${1##*/}" = env ] && shift
    tok=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -*) shift ;; # an `env` flag (`-S`, `-i`), not the interpreter
        *) tok="$1"; break ;;
      esac
    done
    [ "${tok##*/}" = bash ] && printf '%s\n' "$rel"
  done < <(git -C "$ROOT" ls-files 2>/dev/null | LC_ALL=C sort)
}

# ── the file list ────────────────────────────────────────────────────────────────────────────────
FILES=()
if [ "$#" -gt 0 ]; then
  for f in "$@"; do
    case "$f" in /*) FILES+=("$f") ;; *) FILES+=("$ROOT/$f") ;; esac
  done
else
  command -v git >/dev/null 2>&1 || die "git is required to enumerate the tracked *.sh population"
  # `git ls-files` reads the INDEX: a file that exists but is not tracked is not a shipped surface,
  # and a `find`-based walk would descend into .worktrees/ (docs/ops/load-policy.md).
  #
  # ⛔ tests/fixtures/ IS CARVED OUT BY NAME, and only it: those files are DELIBERATELY hostile to
  # bash 3.2 (each one pins a construct this gate must catch), so sweeping them would red the gate
  # forever. The suite passes them explicitly. Nothing else is excluded — a shipped script that moved
  # into tests/fixtures/ would leave this population, which is why the carve-out is this narrow.
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    case "$rel" in tests/fixtures/*) continue ;; esac
    FILES+=("$ROOT/$rel")
  done < <(git -C "$ROOT" ls-files '*.sh' 2>/dev/null | LC_ALL=C sort)
  [ "${#FILES[@]}" -gt 0 ] || die "git ls-files returned no *.sh under $ROOT — that is not a repository with shipped scripts"

  # ⛔ DERIVED, not listed (#2976). A hand-kept list had already drifted to 4 of 9 files.
  suffixless="$(derive_suffixless)"
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    FILES+=("$ROOT/$rel")
  done <<< "$suffixless"
  # ...and the derivation is CHECKED against the known set, so a loss is loud. A path that is no
  # longer in the index is skipped: it is not a file that the derivation failed to see, it is a file
  # that is no longer shipped (`git ls-files --error-unmatch` is the "is it tracked?" test).
  for rel in "${MUST_DERIVE[@]}"; do
    git -C "$ROOT" ls-files --error-unmatch -- "$rel" >/dev/null 2>&1 || continue
    case "
$suffixless
" in *"
$rel
"*) : ;; *) die "the derived suffixless-bash population does not cover '$rel', which is tracked — the derivation is broken, so this sweep would report OK over a file it never parsed" ;; esac
  done
fi
[ "${#FILES[@]}" -gt 0 ] || die "no files to check — an empty population must not read as a pass"

# ── the interpreter: a real bash 3.x, never a substitute ────────────────────────────────────────
# Identified by `BASH_VERSINFO[0]` (available since bash 2.0), never by the path or by the shape of
# the version string.
version_major() { "$1" -c 'printf "%s" "${BASH_VERSINFO[0]}"' 2>/dev/null; }

NATIVE=""
if [ -n "${BASH32:-}" ]; then
  [ -x "$BASH32" ] || die "BASH32='$BASH32' is not an executable — refusing rather than silently falling back to another interpreter"
  major="$(version_major "$BASH32")"
  [ "$major" = "3" ] || die "BASH32='$BASH32' reports bash major version '${major:-unknown}', not 3 — the point of this gate is the 3.x parser, so a 5.x interpreter here would be a false PASS"
  NATIVE="$BASH32"
elif [ -x /bin/bash ] && [ "$(version_major /bin/bash)" = "3" ]; then
  NATIVE=/bin/bash
fi

if [ -n "$NATIVE" ]; then
  VER="$("$NATIVE" -c 'printf "%s" "$BASH_VERSION"')"
  rc=0; n=0; failed=0
  for f in "${FILES[@]}"; do
    n=$((n + 1))
    if ! out="$("$NATIVE" -n "$f" 2>&1)"; then
      failed=$((failed + 1))
      printf '❌ %s\n' "${f#"$ROOT"/}"
      printf '%s\n' "$out" | sed 's/^/     /'
      rc=1
    fi
  done
  if [ "$rc" -eq 0 ]; then
    printf '✅ bash32-parse: %s script(s) parse under GNU bash %s (native: %s)\n' "$n" "$VER" "$NATIVE"
  else
    printf '❌ bash32-parse: %s of %s script(s) FAIL to parse under GNU bash %s (%s)\n' "$failed" "$n" "$VER" "$NATIVE" >&2
    printf '   A here-doc nested in a command substitution desynchronises the bash 3.2 scanner —\n' >&2
    printf '   move it into a function body and call that (#2248, #2930).\n' >&2
  fi
  exit "$rc"
fi

command -v docker >/dev/null 2>&1 || die "no bash 3.x on this host and docker is not installed — cannot measure. Supply one: BASH32=/path/to/bash-3.2 (macOS /bin/bash IS 3.2.57; ubuntu-latest's is 5.x, hence the image)."
# Everything mounted must live under ROOT: a path outside it cannot be resolved in the container, and
# silently SKIPPING such a file is exactly the false green this gate exists to prevent.
for f in "${FILES[@]}"; do
  case "$f" in "$ROOT"/*) : ;; *) die "'$f' is outside $ROOT and cannot be mounted for the container — point CHECK_BASH32_ROOT at its tree" ;; esac
done
REL=()
for f in "${FILES[@]}"; do REL+=("${f#"$ROOT"/}"); done

docker run --rm -v "$ROOT:/repo:ro" -e BASH32_IMAGE_SEEN="$IMAGE" "$IMAGE" bash -c '
# The container half carries its OWN version check: a retargeted image (or a BASH32_IMAGE override)
# that runs bash 5 here would make every file parse and the gate report OK on the wrong platform.
if [ "${BASH_VERSINFO[0]}" != "3" ]; then
  printf "❌ check-bash32-parse: the image runs GNU bash %s, not 3.x — refusing to measure (a 5.x parser here would be a false PASS)\n" "$BASH_VERSION" >&2
  exit 2
fi
rc=0; n=0; failed=0
for rel in "$@"; do
  n=$((n + 1))
  if ! out="$(cd /repo && bash -n "$rel" 2>&1)"; then
    failed=$((failed + 1))
    printf "❌ %s\n" "$rel"
    printf "%s\n" "$out" | sed "s|^|     |"
    rc=1
  fi
done
if [ "$rc" -eq 0 ]; then
  printf "✅ bash32-parse: %s script(s) parse under GNU bash %s (docker: %s)\n" "$n" "$BASH_VERSION" "$BASH32_IMAGE_SEEN"
else
  printf "❌ bash32-parse: %s of %s script(s) FAIL to parse under GNU bash %s\n" "$failed" "$n" "$BASH_VERSION" >&2
  printf "   A here-doc nested in a command substitution desynchronises the bash 3.2 scanner —\n" >&2
  printf "   move it into a function body and call that (#2248, #2930).\n" >&2
fi
exit "$rc"
' _ "${REL[@]}"
