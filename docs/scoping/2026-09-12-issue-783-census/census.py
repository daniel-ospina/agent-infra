#!/usr/bin/env python3
"""Census of real task-tool hard-cap payloads in pi session transcripts (#783).

Fingerprint: a string value that STARTS WITH the cap headline AND contains
"Alive state:". The startswith gate excludes quotations of a payload inside
prose (including sessions that discuss the payload).

NO de-duplication: a cap payload is composed exactly once per cap event
(extensions/builtin-tools/index.ts `composeAbnormalExit` cap arm), so two payloads
sharing a prefix
but differing in alive-state fields are DISTINCT events. De-duplicating on a
prefix silently deletes real losses (131 -> 120 on this corpus).

Measures BOTH channels. The payload is
  <headline> + Alive state: ... + "--- last stderr ---" + "--- last stdout ---"
i.e. `cleanStderr(stderr.slice(-2000))` then `stdout.slice(-500)`
(extensions/builtin-tools/index.ts `composeAbnormalExit`, cap arm; Task 3 moved it
behind the shared composer without changing this text).

The stderr in that payload is the CHILD PROCESS's stderr (`:2337` `stderr: proc.stderr`,
`:2401` `proc.stderr.on("data", ...)` -> appendCap), not the parent's. The clause describing
it was overstated FIVE times, each caught by a fresh verifier leg; this docstring is now the
corrected version and must not drift back:
  rev 3 "the payload is empty"                      -> withdrawn (only stdout was measured)
  rev 4 "the parent's banner noise"                  -> withdrawn (it is child-side)
  rev 5 "is NOT the worktree the child was editing"  -> withdrawn (see below)
  rev 6 headline "carries no location"               -> withdrawn (82/144 name a repo root)
  rev 7 "no branch is returned"                      -> withdrawn (5/144 name a branch in prose;
                                                       7/144 carry branch guard text)
What it actually is: child-side startup banners + child-side enforcement events, including
`[verification-gate] ... for root <path>`. That path is `normalizeWorktreeRoot(resolveGitRoot(
process.cwd()))` (`verification-gate/index.ts:2922`) = `git rev-parse --show-toplevel` of the
child's spawn cwd (`:2356`). `spawnSubAgent` forces that cwd equal to the parent's (`:2306`),
but `--show-toplevel` resolves it to the enclosing REPO TOP LEVEL — which IS a worktree when
the parent runs from one (this repo's normal pattern). So the payload CAN name the worktree;
the 0/82 observation below is an observation, not a structural guarantee.

Reported as `stderr_names_child_root`, `stderr_mentions_branch`, `git_field_state` so every
part of the claim stays observable.

Usage: census.py [--root DIR]... [--assert-nonzero]

`--root` is REPEATABLE and ADDITIVE (Task 3): every occurrence is scanned and the
payload counts are the UNION across roots (de-duplicated by path). With no `--root`
the scan runs on the default session root ONLY — never repointed — because the cap
payload is composed by the PARENT `task` tool and lives in the PARENT's transcript;
since Task 1 relocates only the CHILD transcript, pointing `ROOT` at
`task-sessions/` would find 0 payloads and make `--assert-nonzero` fail by
construction. The child root is meant to be added as an EXTRA root.
"""
import json
import glob
import re
import sys
import collections
import os

DEFAULT_ROOT = "/Users/danielospina/.pi/agent/sessions"

# Repeatable --root (additive). Parsed positionally so `--root A --root B` scans
# BOTH; a single --root keeps the legacy behaviour. No --root → default root.
ROOTS: list[str] = []
_argv = sys.argv[1:]
_i = 0
while _i < len(_argv):
    if _argv[_i] == "--root" and _i + 1 < len(_argv):
        ROOTS.append(_argv[_i + 1])
        _i += 2
        continue
    _i += 1
if not ROOTS:
    ROOTS = [DEFAULT_ROOT]

PREFIX = "⚠️ Sub-agent exceeded the task hard cap"

# Branch-related guard TEXT in the stderr tail. Deliberately NOT a loose `<word>/<word>`
# token pattern: `docs/static` in a VGATE line matches that shape and produced 2 FALSE
# POSITIVES when tried (8 vs the correct 6).
# The last alternative is the `#265` banner's TAIL, because the 2000-char slice can cut the
# banner's head off — matching only the head under-counts (4 instead of 5 #265 banners).
BRANCH_TEXT = (
    r"BRANCH CHANGED"
    r"|Commits are BLOCKED until you check out your own branch"
    r"|HUB DISCIPLINE|on branch\s+\""
    r"|\u2192\s*current\s*\"|detached HEAD|HEAD is now at"
    r"|Switched to (?:a new )?branch|On branch "
)

# A branch NAME actually VISIBLE in the tail. Cycle-9 finding: `BRANCH_TEXT` over-counts
# the phrase "names a branch" — 2 of its 7 hits carry only guard wording (the
# `HUB DISCIPLINE` dirty-tree variant has no branch line at all; one `#265` banner is
# head-cut so only the generic string "check out your own branch" survives). Text is 7,
# names is 5. Both are published; do not merge them into one number.
BRANCH_NAME = r'(?:baseline|current|on branch)\s+"([^"]+)"|detached HEAD'

total = 0
git_state = 0
inflight = 0
saw_true = 0
saw_false = 0
no_field = 0
empty_stdout = 0
stderr_nonempty = 0
stderr_abs = 0
stderr_worktree = 0
stderr_child_root = 0
stderr_mentions_branch = 0
stderr_names_branch = 0
child_roots = collections.Counter()
trace_present = 0
caps = collections.Counter()
per_day = collections.Counter()
files = set()
per_file_payloads = collections.defaultdict(list)
all_payloads = []
alive_prefix = collections.defaultdict(collections.Counter)

files_to_scan: list[str] = []
_seen_files: set[str] = set()
for _root in ROOTS:
    for _f in sorted(glob.glob(os.path.join(_root, "**", "*.jsonl"), recursive=True)):
        if _f not in _seen_files:
            _seen_files.add(_f)
            files_to_scan.append(_f)

for f in files_to_scan:
    day = re.search(r"([0-9]{4}-[0-9]{2}-[0-9]{2})T", f)
    yes = False
    try:
        raw = open(f, errors="ignore").read()
    except Exception:
        continue
    for line in raw.splitlines():
        if "exceeded the task hard cap" not in line:
            continue
        try:
            o = json.loads(line)
        except Exception:
            continue
        stack = [o]
        while stack:
            v = stack.pop()
            if isinstance(v, str):
                if v.strip().startswith(PREFIX) and "Alive state:" in v:
                    total += 1
                    yes = True
                    per_file_payloads[f].append(v)
                    all_payloads.append(v)
                    _alive = v.split("Alive state:")[1].split("--- last stderr ---")[0].strip()[:40]
                    alive_prefix[f][_alive] += 1
                    if re.search(r"(^|\s)(branch|headSha|worktree|dirty)=", v):
                        git_state += 1
                    if re.search(r"toolsInFlight=[1-9]", v):
                        inflight += 1
                    if "everSawTool=true" in v:
                        saw_true += 1
                    elif "everSawTool=false" in v:
                        saw_false += 1
                    else:
                        no_field += 1
                    if "trace=[" in v:
                        trace_present += 1
                    tail = v.split("--- last stdout ---")
                    if len(tail) > 1 and tail[1].strip() == "":
                        empty_stdout += 1
                    parts = v.split("--- last stderr ---")
                    if len(parts) > 1:
                        se = parts[1].split("--- last stdout ---")[0].strip()
                        if se:
                            stderr_nonempty += 1
                            # An ABSOLUTE path: a leading "/" at a token boundary,
                            # followed by a second segment. Cycle-6 finding: the previous
                            # regex also matched purely RELATIVE segments (e.g. "tools/foo/"),
                            # so the field over-counted under its own name (107 vs 106).
                            if re.search(r"(?:^|[\s'\"(\[=:,])/[A-Za-z0-9_.-][^\s]*/", se):
                                stderr_abs += 1
                            if re.search(r"\.worktrees?/", se):
                                stderr_worktree += 1
                            found = re.findall(r"for root (\S+)", se)
                            if found:
                                stderr_child_root += 1
                                for r in found:
                                    child_roots[r] += 1
                            # Cycle-8 P0: two DIFFERENT banners name a branch, and the
                            # 2000-char slice can cut a banner's HEAD off. Matching only the
                            # `#265 BRANCH CHANGED` head missed both cases, so the published
                            # count was 4 when the true figure is 7. Match every head AND the
                            # slice-truncated tail signature.
                            if re.search(BRANCH_TEXT, se):
                                stderr_mentions_branch += 1
                            if re.search(BRANCH_NAME, se):
                                stderr_names_branch += 1
                    m = re.search(r"hard cap \((\d+)s\)", v)
                    if m:
                        caps[m.group(1)] += 1
            elif isinstance(v, dict):
                stack.extend(v.values())
            elif isinstance(v, list):
                stack.extend(v)
    if yes:
        files.add(f)
        per_day[day.group(1) if day else "?"] += 1

# Counted GLOBALLY, not per file: a cap payload is composed once per cap event, so a
# byte-identical repeat anywhere in the corpus means the same event was counted twice.
duplicate_payload_strings = len(all_payloads) - len(set(all_payloads))
alive_prefix_collision_files = sum(1 for c in alive_prefix.values() if max(c.values()) > 1)

print(f"payloads={total} files={len(files)} git_field_state={git_state}")
print(f"  everSawTool=true={saw_true} false={saw_false} no_field={no_field}")
print(f"  toolsInFlight>0={inflight}")
print(f"  stdout_tail_empty={empty_stdout}  stderr_tail_nonempty={stderr_nonempty}")
print(f"  stderr_has_abs_path={stderr_abs}  stderr_mentions_worktree={stderr_worktree}")
print(f"  stderr_names_child_root={stderr_child_root} (distinct_roots={len(child_roots)})")
print(f"  stderr_mentions_branch={stderr_mentions_branch} stderr_names_branch={stderr_names_branch}")
print(f"  has_activity_trace={trace_present}")
print(f"  cap_seconds={dict(caps)}")
print(f"  active_days={len(per_day)}")
print(f"  duplicate_payload_strings={duplicate_payload_strings}")
print(f"  alive_prefix_collision_files={alive_prefix_collision_files}")
for d, c in sorted(per_day.items()):
    print(f"    {d}: {c}")

# A format change must not present as "no losses".
if "--assert-nonzero" in sys.argv and total == 0:
    print("INSTRUMENT FAILED: payloads=0 on the live corpus — suspect format drift, not 'no losses'")
    sys.exit(1)
