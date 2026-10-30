#!/bin/bash
# shard: off runs in ci.yml's dedicated `pi-config-extensions` job (PR lane only - ci-main's `pi-config-extensions-guard` job runs scripts/check-pi-config-extensions.sh, NOT this suite, so there is no post-merge suite run site, agent-infra#2610); a shard here would be a second run site (#2439)
# #498/#502 — pi-config extension-farm parity gate tests.
#
# Exercises scripts/check-pi-config-extensions.sh semantics against
# runtime-built fixture trees (mechanism: cost-config test 10 — the gate
# computes ROOT from its own path, so a copy under a tmp tree gates that
# tree; no committed fixtures, no gate-script override needed):
#   1. clean farm (links resolve into extensions/, *.test.ts unwired, manifest
#      rows match tree) → PASS
#   2. materialized copy over a link  (check 1)  → BLOCK, exit 1
#   3. mistargeted link (check 2)                → BLOCK, exit 1
#   4. broken farm link (check 2, resolve "")    → BLOCK, exit 1
#   5. extension present but not wired (check 3) + no manifest row (check 4a)
#      → BLOCK, exit 1, both diagnostics reported
#   6. extension in tree+farm but no manifest row (check 4a, #502) → BLOCK
#   7. manifest row with no matching tree entry (check 4b, #502)   → BLOCK
#   8. no manifest.json at all (check 4 fail-closed)               → BLOCK
#   9. malformed manifest.json (check 4 fail-closed)               → BLOCK
#  10. live farm link whose target is gone (check 5, #1214b)       → BLOCK
#  11. live farm links that all resolve (check 5)                  → PASS
#  12. no live farm at all — the CI shape (check 5)                → PASS +
#      an explicit ⏭️ skip line (never a silent pass)
#  13. directory whose ENTIRE content is git-ignored (the #2425 shape: an
#      untracked extensions/<x>/node_modules tree)                   → PASS, and
#      the skip line NAMES it (nothing is silently ignored)
#  14. TRACKED extension that ALSO carries an ignored node_modules
#      tree, but is unwired + unlisted                               → BLOCK — the
#      fix keys on tracked content per entry, so a real extension is never
#      exempted by a stray ignored tree inside it (#2425 constraint 2)
#  15. fixture that is not a git work tree                          → BLOCK
#      (fail-closed: the gate refuses to fall back to a filesystem scan, which
#      would reinstate #2425 silently)
#  16. a repo whose extensions/ are ALL unindexed                     → BLOCK
#      (vacuity floor: if the index names none of the extension-shaped paths
#      that exist on disk, the READING is wrong — checks 3/4a would otherwise
#      pass vacuously forever, the "check that cannot fail" class)
#  17. a tree that is a SUBDIRECTORY of a git repo (not its toplevel)  → BLOCK
#      (the second fail-closed branch: enumerating the OUTER repo's index would
#      answer about the wrong tree)
#  18. a TRACKED path whose name contains a newline                    → BLOCK
#      (the name is derived line-wise, so such a path would be silently
#      truncated — and an LF-bearing `grep -F` pattern can match another entry,
#      hiding the directory from the ⏭️ line; refuse instead of mis-name)
#  19. a TRACKED extension whose name begins with `-`                  → BLOCK,
#      naming it as TRACKED (not as UNTRACKED). `grep -Fqx` needs the `--`
#      terminator: without it a dash-leading pattern is parsed as an OPTION,
#      grep exits 2, and the membership test reads that as "not tracked" —
#      reporting a tracked extension as untracked, the #2425 class inverted)
#  20. a TRACKED dangling symlink under extensions/                    → BLOCK.
#      `-e` alone treats it as absent (`-L` true, `-e` false), so a tracked entry
#      that ships and loads NOTHING passed and was not even named — falsifying
#      the "nothing is silently ignored" claim. Checks 1/2 already draw this
#      distinction; checks 3/4a now do too.
#  21. a TRACKED dotfile under extensions/ (`.gitkeep`)                   → PASS and
#      NOT named: switching from the shell glob to the index made dotfiles
#      gateable for the first time, a latent false-block over repo furniture
#  22. a TRACKED *extension-shaped* dot entry (`.hidden.ts`, `.adapter/index.ts`)
#      → BLOCK, and named: pi's loader has NO dot filter (measured — dot-named
#      .ts files load) and bin/agent-infra.js farms a dot-named manifest row
#      verbatim, so exempting it would make this suite bless a false PASS. The
#      furniture exemption is narrowed to dot names with no extension shape
#  24. a *.test.ts in the LIVE farm (check 6, #1509)                       → BLOCK
#  25. a *.spec.ts in the LIVE farm (check 6, #2841)                      → BLOCK
#      The pre-#2841 check matched `*.test.ts` only, so the other three names pi
#      EXECUTES (`*.spec.ts`, `*.test.js`, `*.spec.js` — the loader loads a
#      top-level `.ts` OR `.js`) passed a gate whose whole subject is "pi must not
#      execute a test from this farm": a false PASS, not a cosmetic miss.
#  26. a *.test.js in the LIVE farm (check 6, #2841)                      → BLOCK
#  27. a test file NESTED in a live farm SUBDIRECTORY (check 6, #2841)     → PASS
#      pi never loads it: `collectAutoExtensionEntries` resolves a subdirectory
#      through its `pi.extensions` rows, else index.ts/index.js, and
#      never recurses. The pre-#2841 check failed it anyway — 62 such files on the
#      reporting box, none reachable by the loader, and because `sync.sh` runs this
#      gate under `set -e` that red aborted every `./sync.sh` there. Pinned in BOTH
#      directions: exit 0 AND the ⏭️ line still NAMES it (never a silent skip).
#  28. a live farm subdirectory whose `pi.extensions` row names a test
#      file (check 6, #2841)                                             → BLOCK
#      `resolveExtensionEntries` executes those rows verbatim, so this IS loaded;
#      no filename glob can see it, which is why check 6 reads package.json.
#      ⛔ The key is `pi.extensions`: `readPiManifest` returns null without a `pi`
#      object, so a TOP-LEVEL `extensions` key is ignored by pi (case 31).
#
# Fixture trees mirror the real farm: relative symlinks ../../../extensions/<e>
# from pi-bootstrap/pi-config/extensions/ into extensions/, plus a manifest.json
# at the tree root (the consumer ship-list check 4 gates).
#
# EVERY fixture EXCEPT the deliberate `no-git` case (15) is a real git repo
# (`git init` + an explicit `git add`, #2425): checks 3 and 4a ask what GIT TRACKS
# under extensions/, so a fixture that was not a repo would only ever exercise the
# fail-closed branch — which is exactly what 15 pins. `git add` needs no identity;
# the fixture's own .gitignore is what keeps an ignored node_modules tree
# untracked, exactly as on a developer machine.
#
# Check 5 (the machine-local live farm at ~/.pi/agent/extensions) is aimed at a
# fixture dir via PI_EXTENSIONS_DIR in EVERY case, so this suite's verdict never
# depends on the developer's own ~/.pi state.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GUARD="$ROOT/scripts/check-pi-config-extensions.sh"
OUT="$(mktemp /tmp/pi-config-ext-out.XXXXXX)"
failures=0

cleanup() { rm -f "$OUT"; }
trap cleanup EXIT

pass() { echo "   ✅ $1"; }
fail() { echo "   ❌ $1"; failures=$((failures + 1)); }

# write_manifest <path> <entry>... — manifest.json with files.extensions.entries
# holding exactly the given rows (dirs recorded with a trailing slash, matching
# the real manifest format). No trailing comma (invalid JSON).
write_manifest() {
  local path="$1"; shift
  local entries=""
  local first=1
  for entry in "$@"; do
    if [ "$first" -eq 1 ]; then
      entries="    \"${entry}\""
      first=0
    else
      entries="${entries},
    \"${entry}\""
    fi
  done
  # printf interprets \n (SC2059 is a style hint only — expansion is intended)
  printf '{\n  "files": {\n    "extensions/": {\n      "kind": "symlink",\n      "essential": true,\n      "entries": [\n%b\n  ]\n    }\n  }\n}\n' "$entries" > "$path"
}

# build_farm <mode> — fresh tmp tree per case; echoes the tree path.
# mode: clean | copy | retarget | broken | unwired | manifest-missing |
#       manifest-stale | no-manifest | bad-manifest | live-healthy |
#       live-dangling | ignored-node-modules | mixed-ignored | no-git |
#       all-untracked | nested-git | newline-name | dash-name |
#       dangling-ext | dotfile-ext | dot-extension | dotdot-untracked |
#       live-test-file | live-spec-file | live-test-js | live-nested-test |
#       live-pkg-row-test | live-root-pkg-row-test | live-root-short-circuit |
#       live-top-level-ext-key | live-dir-named-like-test
# The live-farm dir is always $TMP/live-extensions (run_gate points
# PI_EXTENSIONS_DIR at it); only the live-* modes create it, so every other mode
# exercises check 5's explicit skip.
build_farm() {
  local mode="$1"
  local TMP
  TMP="$(mktemp -d /tmp/pi-config-ext-fixture.XXXXXX)"
  # The gate copy run_gate executes. `nested-git` moves the whole tree under
  # $TMP/inner (so ROOT is a subdirectory of a repo), and points this at it.
  FIXTURE_GATE="$TMP/scripts/check-pi-config-extensions.sh"
  mkdir -p "$TMP/scripts" "$TMP/extensions" "$TMP/pi-bootstrap/pi-config/extensions"
  cp "$GUARD" "$TMP/scripts/check-pi-config-extensions.sh"

  # extensions/ tree: two single-file extensions, one dir extension, one
  # *.test.ts (test files are not extensions — never shipped, never wired).
  : > "$TMP/extensions/a.ts"
  : > "$TMP/extensions/b.ts"
  : > "$TMP/extensions/c.test.ts"
  mkdir -p "$TMP/extensions/d"
  : > "$TMP/extensions/d/index.ts"

  local FARM="$TMP/pi-bootstrap/pi-config/extensions"
  ln -s ../../../extensions/a.ts "$FARM/a.ts"
  ln -s ../../../extensions/d "$FARM/d"

  case "$mode" in
    clean)    ln -s ../../../extensions/b.ts "$FARM/b.ts" ;;
    live-healthy)  ln -s ../../../extensions/b.ts "$FARM/b.ts" ;;   # farm fine; live link resolves
    live-dangling) ln -s ../../../extensions/b.ts "$FARM/b.ts" ;;   # farm fine; live link dangles
    copy)     : > "$FARM/b.ts" ;;                                    # materialized copy
    retarget) ln -s ../../../extensions/a.ts "$FARM/b.ts" ;;         # resolves, wrong target
    broken)   ln -s ../../../extensions/missing.ts "$FARM/b.ts" ;;   # resolves to ""
    unwired)  ln -s ../../../extensions/b.ts "$FARM/b.ts"
              : > "$TMP/extensions/e.ts" ;;                          # new ext, NOT wired
    manifest-missing) ln -s ../../../extensions/b.ts "$FARM/b.ts" ;; # tree+farm ok, manifest omits b.ts
    manifest-stale)   ln -s ../../../extensions/b.ts "$FARM/b.ts" ;; # tree+farm ok, manifest lists z.ts below
    no-manifest)      ln -s ../../../extensions/b.ts "$FARM/b.ts" ;; # tree+farm ok, no manifest.json at all
    bad-manifest)     ln -s ../../../extensions/b.ts "$FARM/b.ts" ;; # tree+farm ok, manifest.json unparseable
    # #2425 — the measured shape: a directory under extensions/ whose ONLY
    # content is a git-ignored node_modules tree (no package.json, nothing
    # tracked). It is not an extension and no bootstrap could ship it.
    ignored-node-modules) ln -s ../../../extensions/b.ts "$FARM/b.ts"
              mkdir -p "$TMP/extensions/vision-interceptor/node_modules/foo"
              : > "$TMP/extensions/vision-interceptor/node_modules/foo/package.json"
              printf 'node_modules/\n' > "$TMP/.gitignore" ;;
    # #2425 constraint 2 — a TRACKED extension that happens to carry an ignored
    # node_modules tree INSIDE it must still be gated: the ignored child must not
    # exempt the tracked entry.
    mixed-ignored) ln -s ../../../extensions/b.ts "$FARM/b.ts"
              mkdir -p "$TMP/extensions/f/node_modules/foo"
              : > "$TMP/extensions/f/index.ts"
              : > "$TMP/extensions/f/node_modules/foo/package.json"
              printf 'node_modules/\n' > "$TMP/.gitignore" ;;
    no-git)   ln -s ../../../extensions/b.ts "$FARM/b.ts" ;;   # index unreadable on purpose
    # #2425 review — ROOT is a SUBDIRECTORY of a repo, not its toplevel: the
    # second fail-closed branch (enumerating the outer index answers about the
    # wrong tree). Relocated into $TMP/inner after the git block below.
    nested-git) ln -s ../../../extensions/b.ts "$FARM/b.ts" ;;
    # #2425 review — a TRACKED extension whose NAME contains a newline. The
    # top-level name is derived line-wise, so this path would truncate to `ext`
    # and (via grep -F's multi-pattern reading) could even collide with a real
    # entry, hiding it from the ⏭️ line. Must refuse, never mis-name.
    newline-name) ln -s ../../../extensions/b.ts "$FARM/b.ts"
              mkdir -p "$TMP/extensions/ext"$'\n'"ing"
              : > "$TMP/extensions/ext"$'\n'"ing/index.ts" ;;
    # #2425 review — a TRACKED extension whose name begins with `-`. Pins the
    # `grep -Fqx --` terminator: without it, grep parses "-e" as an option,
    # exits 2, and the membership test reads a TRACKED name as UNTRACKED.
    dash-name) ln -s ../../../extensions/b.ts "$FARM/b.ts"
              : > "$TMP/extensions/-e" ;;
    # #2425 review — a TRACKED DANGLING symlink under extensions/ (ships, loads
    # nothing). `-e` alone treats it as absent, so it used to pass unnamed.
    dangling-ext) ln -s ../../../extensions/b.ts "$FARM/b.ts"
              ln -s ./does-not-exist "$TMP/extensions/ghost" ;;
    # #2425 review — a TRACKED dotfile. Repo furniture, not an extension.
    dotfile-ext) ln -s ../../../extensions/b.ts "$FARM/b.ts"
              : > "$TMP/extensions/.gitkeep" ;;
    # #2425 review — dot-named BUT extension-shaped: loadable by pi, therefore
    # gated. Both a dot-named file and a dot-named directory extension.
    dot-extension) ln -s ../../../extensions/b.ts "$FARM/b.ts"
              : > "$TMP/extensions/.hidden.ts"
              mkdir -p "$TMP/extensions/.adapter"
              : > "$TMP/extensions/.adapter/index.ts" ;;
    # #2425 review — `..`-prefixed and extension-shaped, therefore GATED, but
    # untracked. No single glob reaches it (`*` skips dot-named names and
    # `.[!.]*` skips a name whose second character is a dot), so without the
    # `..?*` arm the gate never NAMED it — a silent skip, which is the class
    # this gate's header says it does not do.
    dotdot-untracked) ln -s ../../../extensions/b.ts "$FARM/b.ts" ;;
  esac

  # manifest.json rows: tree extensions a.ts + d/ always present; b.ts unless
  # mode is manifest-missing; e.ts absent in unwired (its own drift); z.ts
  # listed ONLY in manifest-stale (stale row — no tree counterpart).
  # no-manifest: omit the file (check 4 fail-closed on missing manifest).
  # bad-manifest: write malformed JSON (check 4 fail-closed on parse error).
  case "$mode" in
    manifest-missing) write_manifest "$TMP/manifest.json" a.ts d/ ;;
    manifest-stale)   write_manifest "$TMP/manifest.json" a.ts b.ts d/ z.ts ;;
    no-manifest)      : ;;   # no manifest.json written
    bad-manifest)     printf '{ this is not json
' > "$TMP/manifest.json" ;;
    *)                write_manifest "$TMP/manifest.json" a.ts b.ts d/ ;;
  esac

  # Live farm (check 5) — the materialized ~/.pi/agent/extensions shape. A
  # shipped row farmed as a symlink: live-healthy resolves, live-dangling does
  # not. Any other mode leaves $TMP/live-extensions absent (the CI shape).
  case "$mode" in
    live-healthy)  mkdir -p "$TMP/live-extensions"
                   ln -s "$TMP/extensions/a.ts" "$TMP/live-extensions/a.ts" ;;
    # #1509 — a *.test.ts in the LIVE materialised dir. pi's extension loader
    # executes every top-level `.ts`/`.js` it finds there, so this is not a test:
    # it runs its suite at session start and that output becomes the session's answer.
    live-test-file) ln -s ../../../extensions/b.ts "$FARM/b.ts"   # farm otherwise fine, like live-healthy, so exit 1 is attributable to check 6 ALONE
                    mkdir -p "$TMP/live-extensions"
                    ln -s "$TMP/extensions/a.ts" "$TMP/live-extensions/a.ts"
                    touch "$TMP/live-extensions/leaked.test.ts" ;;
    # #2841 — the names the pre-fix check could not see, each LOADED at top level
    # by pi's loader (`.ts` OR `.js` → an extension).
    live-spec-file) ln -s ../../../extensions/b.ts "$FARM/b.ts"
                    mkdir -p "$TMP/live-extensions"
                    ln -s "$TMP/extensions/a.ts" "$TMP/live-extensions/a.ts"
                    touch "$TMP/live-extensions/leaked.spec.ts" ;;
    live-test-js)   ln -s ../../../extensions/b.ts "$FARM/b.ts"
                    mkdir -p "$TMP/live-extensions"
                    ln -s "$TMP/extensions/a.ts" "$TMP/live-extensions/a.ts"
                    touch "$TMP/live-extensions/leaked.test.js" ;;
    # #2841 — a test file NESTED in a farm subdirectory. pi resolves the subdirectory
    # through package.json/index and never recurses, so this is INERT: it must not
    # fail the gate (the measured 62-file false block) and must not be skipped
    # silently either.
    live-nested-test) ln -s ../../../extensions/b.ts "$FARM/b.ts"
                    mkdir -p "$TMP/live-extensions/pkg"
                    ln -s "$TMP/extensions/a.ts" "$TMP/live-extensions/a.ts"
                    : > "$TMP/live-extensions/pkg/index.ts"
                    : > "$TMP/live-extensions/pkg/leaked.test.ts" ;;
    # #2841 — the third load path: `resolveExtensionEntries` executes a subdirectory's
    # `pi.extensions` rows verbatim, so a row naming a test file IS loaded while
    # every filename-glob check is blind to it. ⛔ The key is `pi.extensions` —
    # `readPiManifest` returns null without a `pi` object, so a top-level
    # `extensions` key would be ignored by pi and case 31 pins that inversion.
    live-pkg-row-test) ln -s ../../../extensions/b.ts "$FARM/b.ts"
                    mkdir -p "$TMP/live-extensions/pkg"
                    ln -s "$TMP/extensions/a.ts" "$TMP/live-extensions/a.ts"
                    : > "$TMP/live-extensions/pkg/index.test.ts"
                    printf '{\n  "name": "pkg",\n  "pi": { "extensions": ["index.test.ts"] }\n}\n' \
                      > "$TMP/live-extensions/pkg/package.json" ;;
    live-dangling) mkdir -p "$TMP/live-extensions"
                   ln -s "$TMP/extensions/gone.ts" "$TMP/live-extensions/a.ts" ;;
    # #2841 review — the FIRST branch of the loader the gate quotes: the farm
    # ROOT's own `pi.extensions` rows are returned by `resolveExtensionEntries(dir)`
    # and `collectAutoExtensionEntries` returns THERE, skipping the whole directory
    # scan. A root row naming a test file is therefore executed by pi while every
    # filename glob — and the subdirectory arm — is blind to it (the top-level
    # entry's basename is the SUBDIRECTORY, `pkg`, not the row's target).
    live-root-pkg-row-test) ln -s ../../../extensions/b.ts "$FARM/b.ts"
                    mkdir -p "$TMP/live-extensions/pkg"
                    ln -s "$TMP/extensions/a.ts" "$TMP/live-extensions/a.ts"
                    : > "$TMP/live-extensions/pkg/leaked.test.ts"
                    printf '{\n  "name": "farm-root",\n  "pi": { "extensions": ["pkg/leaked.test.ts"] }\n}\n' \
                      > "$TMP/live-extensions/package.json" ;;
    # #2841 review — the OTHER side of the root short-circuit: when the root
    # resolves entries, the loader never runs its directory scan, so a TOP-LEVEL
    # test-shaped entry is inert. Failing on it would be the #2425 false-block
    # class this PR exists to stop; naming it keeps the skip honest.
    live-root-short-circuit) ln -s ../../../extensions/b.ts "$FARM/b.ts"
                    mkdir -p "$TMP/live-extensions"
                    ln -s "$TMP/extensions/a.ts" "$TMP/live-extensions/a.ts"
                    : > "$TMP/live-extensions/leaked.test.ts"
                    printf '{\n  "name": "farm-root",\n  "pi": { "extensions": ["a.ts"] }\n}\n' \
                      > "$TMP/live-extensions/package.json" ;;
    # #2841 review (round 2) — the INVERSION GUARD. pi's `readPiManifest` requires a
    # `pi` object and reads `pi.extensions`; a TOP-LEVEL `extensions` key is ignored
    # entirely, so the loader falls through to its directory scan and DOES execute
    # the top-level test file. A gate that read the top-level key would call this
    # farm short-circuited and stay GREEN over a file pi runs — the exact regression
    # this case exists to make impossible to reintroduce.
    live-top-level-ext-key) ln -s ../../../extensions/b.ts "$FARM/b.ts"
                    mkdir -p "$TMP/live-extensions"
                    ln -s "$TMP/extensions/a.ts" "$TMP/live-extensions/a.ts"
                    : > "$TMP/live-extensions/leaked.test.ts"
                    printf '{\n  "name": "farm-root",\n  "extensions": ["a.ts"]\n}\n' \
                      > "$TMP/live-extensions/package.json" ;;
    # #2841 review (round 2) — the loader's `isFile` branch: a DIRECTORY named
    # `*.test.ts` is routed to `resolveExtensionEntries`, never executed AS A FILE,
    # so the top-level arm must not indite it (a false block, #2425 class). The
    # fixture RESOLVES an entry (`index.ts`) on purpose: an EMPTY directory is
    # routed to the same branch and returns null, so it cannot tell "the loader
    # skips it" from "the loader runs what it resolves" — and the second claim is
    # the one the arm's comment is written against.
    live-dir-named-like-test) ln -s ../../../extensions/b.ts "$FARM/b.ts"
                    mkdir -p "$TMP/live-extensions/weird.test.ts"
                    ln -s "$TMP/extensions/a.ts" "$TMP/live-extensions/a.ts"
                    : > "$TMP/live-extensions/weird.test.ts/index.ts" ;;
  esac

  # #2425 — checks 3/4a read the GIT INDEX, so every fixture is a real repo with
  # exactly the shippable files staged. The fixture's own .gitignore is what makes
  # the ignored-node_modules case a real test rather than a filesystem-only one.
  # `no-git` deliberately skips the init so the fail-closed branch is pinned too.
  # (No commit and no identity needed: `git ls-files` reads the index.) Staged by
  # explicit path, never `add -A` — the worktree guard refuses a repo-wide stage,
  # and a directory stage still honours .gitignore. `init` is spelled `git init -q
  # "$TMP"`, NOT `git -C "$TMP" init`: the worktree guard refuses a `-C` whose
  # target is a variable inside a repo script ("unverifiable-verb") and accepted
  # the directory form — measured, the `-C` spelling blocked this suite outright.
  if [ "$mode" != "no-git" ]; then
    git init -q "$TMP" || return 1
    # `all-untracked` stages everything EXCEPT extensions/ — the vacuity floor
    # needs a repo whose whole extensions/ tree is unindexed (#2425).
    if [ "$mode" != "all-untracked" ]; then
      git -C "$TMP" add -- extensions || return 1
    fi
    git -C "$TMP" add -- pi-bootstrap || return 1
    if [ -f "$TMP/manifest.json" ]; then git -C "$TMP" add -- manifest.json || return 1; fi
    if [ -f "$TMP/.gitignore" ]; then git -C "$TMP" add -- .gitignore || return 1; fi
  fi

  # #2425 review — an UNTRACKED `..`-prefixed, extension-shaped file. It MUST be
  # created AFTER the index is staged: `git add -- extensions` indexes everything
  # under extensions/, so a file written before that line is genuinely TRACKED and
  # the gate would be right to red it. Created here, it is what the case names —
  # a path no glob reaches, that git does not ship.
  if [ "$mode" = "dotdot-untracked" ]; then
    : > "$TMP/extensions/..hidden.ts" || return 1
  fi

  # #2425 review — the nested-repo shape: the repo toplevel is $TMP but the gate's
  # ROOT is $TMP/inner, so the index it can reach describes a DIFFERENT tree.
  # Relocate the whole fixture tree (the gate derives ROOT from its own path).
  if [ "$mode" = "nested-git" ]; then
    mkdir -p "$TMP/inner"
    mv "$TMP/scripts" "$TMP/extensions" "$TMP/pi-bootstrap" "$TMP/inner/" || return 1
    if [ -f "$TMP/manifest.json" ]; then mv "$TMP/manifest.json" "$TMP/inner/" || return 1; fi
    FIXTURE_GATE="$TMP/inner/scripts/check-pi-config-extensions.sh"
  fi

  # build_farm must NOT run in a command substitution: it sets FIXTURE_GATE
  # (nested-git relocates the tree), and a subshell would drop that assignment.
  FIXTURE_TMP="$TMP"
  return 0
}

# run_gate <expected-exit> <label> <mode> [pattern]... — each pattern must
# appear in the gate output (multiple = all required). A pattern prefixed with
# `!` must NOT appear: presence-only assertions cannot see a WRONG diagnostic
# that accompanies the right one (measured: case 19 stayed green when the `--`
# terminator was stripped from a `grep -Fqx` membership test, because the exit
# code and the required line were unaffected while a false "not gated
# (UNTRACKED) …" line appeared — the suite was not pinning the thing it named).
run_gate() {
  local expected="$1"; shift
  local label="$1"; shift
  local mode="$1"; shift
  local TMP
  build_farm "$mode" || { fail "$label — fixture build failed ($mode)"; return; }
  TMP="$FIXTURE_TMP"
  # Check 5 is aimed at the fixture dir in every case (see the suite header), so
  # the verdict is hermetic and the real ~/.pi never participates. #3002: the CI
  # marker is cleared for the same reason — a case must not change meaning
  # because the suite happens to run inside Actions (it does). The two cases that
  # DO pin CI behaviour set it explicitly, with PI_EXTENSIONS_DIR unset.
  unset GITHUB_ACTIONS CI
  export PI_EXTENSIONS_DIR="$TMP/live-extensions"
  bash "${FIXTURE_GATE:-$TMP/scripts/check-pi-config-extensions.sh}" >"$OUT" 2>&1
  local code=$?
  if [ "$code" -eq "$expected" ]; then
    pass "$label (exit $code)"
  else
    fail "$label — expected exit $expected, got $code"
    sed -n '1,60p' "$OUT"
  fi
  for grep_for in "$@"; do
    case "$grep_for" in
      '!'*)
        local forbidden="${grep_for#!}"
        if grep -q -- "$forbidden" "$OUT"; then
          fail "forbidden diagnostic present: $forbidden"
          sed -n '1,40p' "$OUT"
        else
          pass "forbidden absent: $forbidden"
        fi
        ;;
      *)
        if grep -q -- "$grep_for" "$OUT"; then
          pass "diagnostic present: $grep_for"
        else
          fail "expected diagnostic: $grep_for"
          sed -n '1,40p' "$OUT"
        fi
        ;;
    esac
  done
  rm -rf "$TMP"
}

echo "== pi-config extension-farm parity gate tests (#498) =="
echo ""

echo "1. Clean farm → PASS, exit 0 (a.ts + d/ wired; *.test.ts excluded)"
run_gate 0 "clean farm" clean "symlink farm into extensions/"

echo ""
echo "2. Materialized copy over a link (check 1) → BLOCK, exit 1"
run_gate 1 "materialized copy" copy "NOT a symlink"

echo ""
echo "3. Mistargeted link (check 2) → BLOCK, exit 1"
run_gate 1 "mistargeted link" retarget "does not resolve"

echo ""
echo "4. Broken farm link (check 2, resolve empty) → BLOCK, exit 1"
run_gate 1 "broken link" broken "does not resolve"

echo ""
echo "5. Extension present but not wired (check 3) + no manifest row (check 4a) → BLOCK, exit 1, both reported"
run_gate 1 "unwired extension" unwired "not wired into pi-config" "has no manifest.json files.extensions.entries row" "tracked extension e.ts"

echo ""
echo "6. Extension in tree+farm but no manifest row (check 4a, #502) → BLOCK, exit 1"
run_gate 1 "manifest row missing" manifest-missing "has no manifest.json files.extensions.entries row" "tracked extension b.ts"

echo ""
echo "7. Manifest row with no matching tree entry (check 4b, #502) → BLOCK, exit 1"
run_gate 1 "stale manifest row" manifest-stale "has no matching extensions/ entry"

echo ""
echo "8. No manifest.json at all (check 4 fail-closed, #502) → BLOCK, exit 1"
run_gate 1 "missing manifest file" no-manifest "manifest.json missing at"

echo ""
echo "9. Malformed manifest.json (check 4 fail-closed, #502) → BLOCK, exit 1"
run_gate 1 "malformed manifest" bad-manifest "cannot parse"

echo ""
echo "10. Live farm link whose target is gone (check 5, #1214b) → BLOCK, exit 1"
run_gate 1 "dangling live farm link" live-dangling "is DANGLING"

echo ""
echo "11. Live farm links that all resolve (check 5) → PASS, exit 0"
run_gate 0 "healthy live farm links" live-healthy "symlink farm into extensions/"

echo ""
echo "12. No live farm at all — the CI shape (check 5) → PASS + explicit skip line"
run_gate 0 "absent live farm" clean "check 5 (dangling shipped links) skipped"

echo ""
echo "13. #2425 — directory whose ONLY content is a git-ignored node_modules tree → PASS"
run_gate 0 "ignored node_modules-only dir is not an extension" ignored-node-modules \
  "⏭️  not gated (UNTRACKED" \
  "vision-interceptor" \
  "4a asks whether every TRACKED extension has a row"

echo ""
echo "14. #2425 constraint 2 — a TRACKED extension carrying an ignored node_modules tree is STILL gated"
run_gate 1 "tracked extension with an ignored child is not exempt" mixed-ignored \
  "tracked extension f exists in extensions/" \
  "not wired into pi-config" \
  "has no manifest.json files.extensions.entries row"

echo ""
echo "15. #2425 fail-closed — not a git work tree: refuse, never fall back to the filesystem scan"
run_gate 1 "unreadable index" no-git "cannot read the git index"

echo ""
echo "16. #2425 vacuity floor — a repo whose extensions/ are ALL unindexed cannot pass vacuously"
run_gate 1 "empty tracked set over a populated tree" all-untracked "tracks NO extension under extensions/"

echo ""
echo "17. #2425 review — ROOT inside a repo but not its toplevel: refuse (never read the outer index)"
run_gate 1 "nested tree inside another repo" nested-git "cannot read the git index"

echo ""
echo "18. #2425 review — a TRACKED path whose name contains a newline: refuse, never mis-name"
run_gate 1 "tracked newline name" newline-name "contains a newline"

echo ""
echo "19. #2425 review — a TRACKED name beginning with '-' is still recognised as TRACKED (grep --)"
# The negative assertions are the pin: without the `--` terminator grep exits 2,
# the membership test reads a TRACKED name as untracked, and the gate emits a
# FALSE `not gated (UNTRACKED) …: -e` line (plus a grep usage error) while the
# exit code and the tracked-extension diagnostic stay unchanged.
run_gate 1 "dash-leading tracked name" dash-name \
  "tracked extension -e exists in extensions/" \
  "!not gated (UNTRACKED" \
  "!option requires an argument"

echo ""
echo "20. #2425 review — a TRACKED dangling symlink under extensions/ is a shipped entry that loads nothing"
run_gate 1 "tracked dangling symlink" dangling-ext \
  "tracked extension ghost exists in extensions/" \
  "has no manifest.json files.extensions.entries row"

echo ""
echo "21. #2425 review — a TRACKED dotfile is repo furniture, not an extension"
run_gate 0 "tracked dotfile is not an extension" dotfile-ext \
  "symlink farm into extensions/" \
  "!not gated (UNTRACKED" \
  "!gitkeep"

echo ""
echo "22. #2425 review — a dot-named EXTENSION (.hidden.ts / .adapter/index.ts) is still gated"
run_gate 1 "dot-named extension-shaped entries" dot-extension \
  "tracked extension .hidden.ts exists in extensions/" \
  "tracked extension .adapter exists in extensions/" \
  "has no manifest.json files.extensions.entries row"

echo ""
echo "23. #2425 review — an UNTRACKED '..'-prefixed extension is NAMED, never silently skipped"
run_gate 0 "untracked ..-prefixed extension is named" dotdot-untracked \
  "not gated (UNTRACKED" \
  "..hidden.ts"

echo ""
echo "24. #1509 — a *.test.ts in the LIVE farm is executed by pi's loader, not run as a test"
run_gate 1 "test file in the live farm" live-test-file \
  "test file(s) in the live extension farm" \
  "leaked.test.ts" \
  "!symlink farm into extensions/"

echo ""
echo "25. #2841 — a *.spec.ts in the LIVE farm is EXECUTED too (the pre-fix check was green over it)"
run_gate 1 "spec file in the live farm" live-spec-file \
  "test file(s) in the live extension farm" \
  "leaked.spec.ts" \
  "!symlink farm into extensions/"

echo ""
echo "26. #2841 — a *.test.js in the LIVE farm is EXECUTED too (the loader loads '.js', not just '.ts')"
run_gate 1 "js test file in the live farm" live-test-js \
  "test file(s) in the live extension farm" \
  "leaked.test.js" \
  "!symlink farm into extensions/"

echo ""
echo "27. #2841 — a test file NESTED in a farm subdirectory is INERT: not fatal, but NAMED"
# The negative half is the pin: this case exists because the old `-maxdepth 3`
# `find` failed 62 files the loader cannot reach and thereby aborted every
# `./sync.sh` on the reporting box. A future "just widen the find again" edit
# reddens this case, and the named-note assertion keeps the skip honest.
run_gate 0 "nested test copy is inert" live-nested-test \
  "symlink farm into extensions/" \
  "not gated (test copy NESTED in a farm subdirectory" \
  "pkg/leaked.test.ts" \
  "!test file(s) in the live extension farm"

echo ""
echo "28. #2841 — a farm subdir's package.json pi.extensions row naming a test file IS loaded"
# ⛔ The key is `pi.extensions` (readPiManifest requires a `pi` object). Case 31
# pins the inversion: a top-level `extensions` key is IGNORED by pi, so reading it
# here would both green a loaded file and red an unloaded one.
run_gate 1 "pi.extensions row names a test file" live-pkg-row-test \
  "test file(s) in the live extension farm" \
  "pkg: pi.extensions row" \
  "-> index.test.ts" \
  "!symlink farm into extensions/"

echo ""
echo "29. #2841 review — the farm ROOT's pi.extensions row naming a test file IS loaded"
# The root short-circuit is the FIRST branch of the loader the header quotes. A
# gate that models only the top-level and subdirectory rows exits 0 here while
# telling the reader "nothing here executes today" about a file pi runs at every
# session start — a false PASS over the exact condition this check exists for.
run_gate 1 "root pi.extensions row names a test file" live-root-pkg-row-test \
  "test file(s) in the live extension farm" \
  "pi.extensions row" \
  "-> pkg/leaked.test.ts" \
  "!symlink farm into extensions/" \
  "!not gated"

echo ""
echo "30. #2841 review — a ROOT that resolves entries makes a top-level test file INERT (named, not fatal)"
# The other direction of case 29, and the reason it is not a one-line widening:
# `collectAutoExtensionEntries` returns the root's entries BEFORE its directory
# scan, so `leaked.test.ts` cannot load. Failing it would re-create the measured
# #2425 false block (a red that aborts every `./sync.sh` under set -e).
run_gate 0 "root short-circuit makes a top-level test file inert" live-root-short-circuit \
  "symlink farm into extensions/" \
  "not gated (the farm ROOT resolves extension entries" \
  "leaked.test.ts" \
  "!test file(s) in the live extension farm"

echo ""
echo "31. #2841 review round 2 — a TOP-LEVEL \`extensions\` key is IGNORED by pi, so the scan still runs"
# `readPiManifest` returns null unless the package.json carries a `pi` OBJECT and
# reads `pi.extensions`; a top-level `extensions` key never reaches
# `resolveExtensionEntries`, which falls back to index.ts/index.js (absent here),
# so `collectAutoExtensionEntries` runs its directory scan and EXECUTES
# `leaked.test.ts`. A gate reading the top-level key would call this farm
# short-circuited and stay GREEN over a file pi runs at every session start.
run_gate 1 "top-level extensions key does not suppress the directory scan" live-top-level-ext-key \
  "test file(s) in the live extension farm" \
  "leaked.test.ts" \
  "!not gated (the farm ROOT resolves extension entries" \
  "!symlink farm into extensions/"

echo ""
echo "32. #2841 review round 2 — a DIRECTORY named *.test.ts is not a test FILE (no false block)"
# The loader's top-level branch requires `isFile`; a directory is routed to
# `resolveExtensionEntries`. This fixture RESOLVES one (`index.ts`), so the arm is
# exercised against the loader's real isDir behaviour rather than against a directory
# that happens to return null — while the directory's NAME is still not a test file,
# so inditing it would be the gate's own #2425-class false block.
run_gate 0 "a directory named like a test is not a test file" live-dir-named-like-test \
  "symlink farm into extensions/" \
  "!test file(s) in the live extension farm" \
  "!weird.test.ts"

echo ""
echo "33. #3002 — a CI verdict is NOT decided by the runner box's own ~/.pi farm"
# Measured 2026-10-28 on PR #3002: `pi-config-extensions` reddened on
# ai-runner-cell3-x64-3, a self-hosted pi box whose ~/.pi/agent/extensions held
# 12 stale top-level *.test.ts copies, over a diff that touched neither
# extensions/ nor the farm. The gate read ${HOME:-}/.pi/agent/extensions with no
# CI awareness at all, so which box served the job decided the repo's verdict.
# The arm below is the defect: CI + a contaminated AMBIENT farm + no named farm
# must be a NAMED skip, not a red — and must not indite the ambient file either.
build_farm live-test-file || fail "CI ambient-farm case — fixture build failed"
TMP="$FIXTURE_TMP"
mkdir -p "$TMP/ambient-home/.pi/agent/extensions" || fail "CI ambient-farm case — mkdir failed"
: > "$TMP/ambient-home/.pi/agent/extensions/leaked-ambient.test.ts"
unset PI_EXTENSIONS_DIR
HOME="$TMP/ambient-home" GITHUB_ACTIONS=true bash "${FIXTURE_GATE:-$TMP/scripts/check-pi-config-extensions.sh}" >"$OUT" 2>&1
ci_ambient_code=$?
if [ "$ci_ambient_code" -eq 0 ]; then
  pass "contaminated ambient farm in CI: exit 0 (box state is not this repo's verdict)"
else
  fail "contaminated ambient farm in CI — expected exit 0, got $ci_ambient_code (the runner box decided the verdict)"
  sed -n '1,40p' "$OUT"
fi
if grep -q 'live extension farm NOT READ' "$OUT"; then
  pass "diagnostic present: live extension farm NOT READ (the skip is named, not silent)"
else
  fail "diagnostic absent: live extension farm NOT READ"
  sed -n '1,40p' "$OUT"
fi
if grep -q 'leaked-ambient.test.ts' "$OUT"; then
  fail "forbidden present: leaked-ambient.test.ts (the ambient file was still indited)"
else
  pass "forbidden absent: leaked-ambient.test.ts"
fi

echo ""
echo "34. #3002 — the CI refusal is not a blanket off-switch: a NAMED farm is still gated"
# The anti-fail-open half. Case 33 must not be satisfiable by turning checks 5/6
# off whenever CI is set: a farm named by PI_EXTENSIONS_DIR is read and gated
# even in CI, which is exactly how .github/workflows/ci.yml keeps real
# discriminating power over the farm this repo ships.
build_farm live-test-file || fail "CI named-farm case — fixture build failed"
TMP="$FIXTURE_TMP"
HOME="$TMP/ambient-home" GITHUB_ACTIONS=true PI_EXTENSIONS_DIR="$TMP/live-extensions" \
  bash "${FIXTURE_GATE:-$TMP/scripts/check-pi-config-extensions.sh}" >"$OUT" 2>&1
ci_named_code=$?
if [ "$ci_named_code" -eq 1 ]; then
  pass "named farm in CI is still gated (exit 1)"
else
  fail "named farm in CI — expected exit 1, got $ci_named_code (the CI branch swallowed a real farm)"
  sed -n '1,40p' "$OUT"
fi
if grep -q 'test file(s) in the live extension farm' "$OUT"; then
  pass "diagnostic present: test file(s) in the live extension farm"
else
  fail "diagnostic absent: test file(s) in the live extension farm"
  sed -n '1,40p' "$OUT"
fi

echo ""
echo "35. #3002 — the CI wiring that keeps the shipped farm gated cannot be deleted and stay green"
# ⛔ THE FAIL-OPEN ARM (#3002 review P2). In CI the gate refuses the runner box's ambient farm and
# reads only a NAMED one, so `PI_EXTENSIONS_DIR` on the two jobs is the ONLY thing that keeps checks
# 5/6 doing any work in CI. Without it the gate takes its named-skip branch and exits 0 — so a PR that
# simply DELETES that env line from ci.yml would leave every check green while the shipped farm lost
# its test-file and dangling-link coverage. Nothing else reads the workflows for this, so the wiring
# is pinned here: both jobs that run this gate must aim it at the farm this repo ships, and the value
# must be the workspace-relative shipped farm (not a `$HOME` path, which is the defect again).
# #1719 precedent: "the scheduled job, the farm and the script must agree" (ci_runner_gate.test.sh).
WANT_FARM='${{ github.workspace }}/pi-bootstrap/pi-config/extensions'
assert_wired() { # <workflow file> <job id>
  local wf="$ROOT/.github/workflows/$1" job="$2" got
  if [ ! -f "$wf" ]; then
    fail "wiring: .github/workflows/$1 is missing — the job list is not what this case assumed"
    return
  fi
  # The job block runs from its `^  <job>:` line to the next top-level-keyed job line (2-space indent).
  got="$(awk -v want="$job" '
    $0 ~ "^  "want":" { injob=1; next }
    injob && /^  [A-Za-z0-9_.-]+:[[:space:]]*$/ { injob=0 }
    injob && /PI_EXTENSIONS_DIR:/ { sub(/^[[:space:]]*PI_EXTENSIONS_DIR:[[:space:]]*/, ""); print; exit }
  ' "$wf")"
  if [ -z "$got" ]; then
    fail "wiring: $1 job '$job' does NOT set PI_EXTENSIONS_DIR — the gate would skip checks 5/6 in CI and stay green (the #3002 fail-open)"
    return
  fi
  if [ "$got" != "$WANT_FARM" ]; then
    fail "wiring: $1 job '$job' sets PI_EXTENSIONS_DIR='$got' — want the SHIPPED farm '$WANT_FARM' (a \$HOME path reintroduces the host-dependent verdict)"
    return
  fi
  pass "wiring: $1 job '$job' aims the machine-local checks at the shipped farm"
}
assert_wired ci.yml pi-config-extensions
assert_wired ci-main.yml pi-config-extensions-guard

echo ""
if [ "$failures" -gt 0 ]; then
  echo "❌ $failures pi-config extension gate test(s) failed"
  exit 1
fi
echo "✅ All pi-config extension-farm parity gate tests passed"
