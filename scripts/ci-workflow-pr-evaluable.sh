#!/usr/bin/env bash
# ci-workflow-pr-evaluable.sh — THE ONE PREDICATE for "can this workflow attach
# a check to a pull-request head sha?" (#6807).
#
# WHAT IT ANSWERS. A GitHub Actions workflow is PR-EVALUABLE when its `on:` block
# declares `pull_request` or `pull_request_target`: only then can a check run from
# that workflow land on a PR's evaluated-tree surface (`<head sha>`). A workflow
# that declares neither — e.g. `deploy-hosted.yml` (`on: push` +
# `workflow_dispatch` only) — CANNOT attach a check to a PR head sha, so NO PR can
# ever measure it. Its red on the base is therefore unmeasurable by every PR, and
# the merge rail must not compare a PR against it (see `check_surface_probe`'s
# base-side exemption in scripts/admin-merge.sh, §4.6).
#
# ⛔ THIS IS A PROPERTY OF THE WORKFLOW, NOT OF THE EVENT NAME. The event that
# REDDENED the base is *what happened to run*, not *what the workflow can be*: a
# push-only workflow reddens on `push`; a cron workflow reddens on `schedule`. A
# gate keyed on the event name has to whitelist each unmeasurable event forever,
# and rots the moment a new one appears. The declarability question is asked of
# the workflow FILE, and the set of PR triggers is not a list to maintain.
#
# USAGE
#   ci-workflow-pr-evaluable.sh < workflow.yml        # YAML on stdin
#   ci-workflow-pr-evaluable.sh .github/workflows/x.yml
# Prints EXACTLY ONE token on stdout:
#   yes      — declares pull_request or pull_request_target
#   no       — parsed successfully and declares neither
#   unknown  — could not be parsed confidently
# ⛔ THE CALLER MUST TREAT `unknown` AS `yes` (FAIL CLOSED). An unresolvable
# workflow stays blocking, exactly like an unresolved run; defaulting it to `no`
# would convert a fail-closed guard into a fail-open one.
#
# PARSE STRATEGY. PyYAML is not assumed present (the rail must run wherever it is
# invoked, and a YAML import failure must not silently decide a merge). The `on:`
# block is a narrow, well-formed slice of YAML — a top-level key whose value is
# either an inline scalar / flow sequence / flow mapping, or a block mapping whose
# depth-1 keys ARE the trigger names. This parser reads ONLY that slice and
# returns `unknown` on anything it does not fully recognise, so an unfamiliar
# shape can only over-block.

set -uo pipefail

UNKNOWN="unknown"
YES="yes"
NO="no"

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi

# fd 3 is the workflow text. It is set BEFORE the python heredoc claims stdin, so
# the heredoc carries the SCRIPT and fd 3 carries the DATA.
if [ "$#" -ge 1 ] && [ "$1" != "-" ]; then
  [ -r "$1" ] || { printf '%s\n' "$UNKNOWN"; exit 0; }
  exec 3< "$1"
else
  exec 3<&0
fi

python3 - "$UNKNOWN" "$YES" "$NO" <<'PYEOF'
import os
import re
import sys

UNKNOWN, YES, NO = sys.argv[1], sys.argv[2], sys.argv[3]

# The whole question. Not a list to maintain: these are the only two events that
# attach a check to a pull-request head sha.
PR_TRIGGERS = {"pull_request", "pull_request_target"}

# A trigger NAME, as it appears as a mapping key. GitHub's event names are
# `[A-Za-z0-9_]`, but a key may be quoted. A key that is not this shape is not a
# trigger this parser understands -> `unknown`.
_KEY_RE = re.compile(r"^[A-Za-z0-9_\-\.]+$")
_TOP_ON_RE = re.compile(r"^(?:\"on\"|'on'|on)\s*:(.*)$")
_BLOCK_KEY_RE = re.compile(
    r"^([ \t]*)(?:\"([^\"]*)\"|'([^']*)'|([A-Za-z0-9_\-\.]+))\s*:(.*)$")

text = os.fdopen(3, "r").read()

lines = text.splitlines()

on_inline = None
on_index = None
for i, raw in enumerate(lines):
    if not raw.strip() or raw.lstrip().startswith("#"):
        continue
    if raw[:1] in (" ", "\t"):
        continue  # indented -> not a top-level key
    m = _TOP_ON_RE.match(raw)
    if m:
        if on_index is not None:
            # Duplicate top-level `on:` is invalid YAML; refusing to guess.
            sys.stdout.write(UNKNOWN + "\n")
            sys.exit(0)
        on_index = i
        on_inline = m.group(1)
if on_index is None:
    # No top-level `on:` at all. A real workflow ALWAYS has one, so a document
    # without it is not a workflow this parser can resolve — and an EMPTY body
    # (a failed fetch) is indistinguishable from one. Both are `unknown`, i.e.
    # FAIL CLOSED: never read an unreadable file as "declares no PR trigger".
    sys.stdout.write(UNKNOWN + "\n")
    sys.exit(0)

# The inline value, with a trailing comment removed. A `#` cannot appear inside a
# bare scalar or a flow collection element here, so this is safe for the shapes
# a trigger list can take.
inline = re.sub(r"\s+#.*$", "", on_inline or "").strip()

# Anchors/aliases/merge keys make the literal trigger set depend on a definition
# elsewhere in the document; refuse rather than guess.
if any(tok in inline for tok in ("&", "*", "<<")):
    sys.stdout.write(UNKNOWN + "\n")
    sys.exit(0)


def from_inline(value):
    """Trigger set for an inline `on:` value, or None when not understood."""
    if value.startswith("["):
        if not value.endswith("]"):
            return None
        keys = set()
        for part in value[1:-1].split(","):
            part = part.strip().strip('"').strip("'")
            if not part:
                continue
            if not _KEY_RE.match(part):
                return None
            keys.add(part)
        return keys
    if value.startswith("{"):
        if not value.endswith("}"):
            return None
        keys = set()
        for part in value[1:-1].split(","):
            if ":" not in part:
                if part.strip():
                    return None
                continue
            key = part.split(":", 1)[0].strip().strip('"').strip("'")
            if not _KEY_RE.match(key):
                return None
            keys.add(key)
        return keys
    # A bare scalar: `on: push`.
    if _KEY_RE.match(value):
        return {value}
    return None


if inline:
    triggers = from_inline(inline)
    if triggers is None:
        sys.stdout.write(UNKNOWN + "\n")
        sys.exit(0)
else:
    # Block form: depth-1 keys are the triggers. Walk forward until the next
    # top-level key, collecting (indent, key) for every mapping line. A line that
    # is not a mapping line (`- item`, a scalar continuation, blank, comment) is
    # ignored: it belongs to a nested block of a trigger, never to the trigger
    # set. A MERGE KEY at depth 1 is the exception: it can pull in triggers from
    # an anchor, whose names this parser cannot see, so it forces `unknown`.
    collected = []
    merges = []
    for raw in lines[on_index + 1:]:
        if not raw.strip():
            continue
        if raw.lstrip().startswith("#"):
            continue
        if raw[:1] not in (" ", "\t"):
            break  # next top-level key ends the `on:` block
        indent = len(raw) - len(raw.lstrip(" \t"))
        if "\t" in raw[:indent]:
            # A tab in the indentation is not legal YAML; refuse.
            sys.stdout.write(UNKNOWN + "\n")
            sys.exit(0)
        if raw.lstrip().startswith("<<"):
            merges.append(indent)
            continue
        m = _BLOCK_KEY_RE.match(raw)
        if not m:
            # Not a mapping line (a `- item`, a scalar continuation, or a key
            # this parser does not recognise). A line that cannot be a trigger
            # key cannot add one; if it is the ONLY content the block is empty
            # and `unknown` is returned below. (An anchor/alias cannot form a
            # plain key either, so it falls here.)
            continue
        key = m.group(2) if m.group(2) is not None else (
            m.group(3) if m.group(3) is not None else m.group(4))
        if not _KEY_RE.match(key):
            sys.stdout.write(UNKNOWN + "\n")
            sys.exit(0)
        collected.append((indent, key))
    if not collected:
        sys.stdout.write(UNKNOWN + "\n")
        sys.exit(0)
    depth = min(ind for ind, _ in collected)
    if any(ind == depth for ind in merges):
        # A depth-1 merge key can add triggers from elsewhere in the document.
        sys.stdout.write(UNKNOWN + "\n")
        sys.exit(0)
    triggers = {k for ind, k in collected if ind == depth}

sys.stdout.write((YES if (triggers & PR_TRIGGERS) else NO) + "\n")
PYEOF
