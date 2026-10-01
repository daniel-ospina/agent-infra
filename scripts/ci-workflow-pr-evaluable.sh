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
    # A bare scalar: `on: push`. A QUOTED bare scalar (`on: "pull_request"`) is
    # the same value; strip one surrounding quote pair before the test, or a
    # legal declaration would be read as unrecognised and over-block.
    bare = value
    if len(bare) >= 2 and bare[0] == bare[-1] and bare[0] in ("\"", "'"):
        bare = bare[1:-1]
    if _KEY_RE.match(bare):
        return {bare}
    return None


def scan_flow_state(text_part, depth, quote):
    """Advance (flow_depth, open_quote) over ONE physical line.

    `depth` counts `[`/`{` minus `]`/`}` outside any quoted scalar; `quote` is
    `""`, `'"'` or `"'"` while a quoted scalar is open. A `#` outside a quote
    begins a comment and the rest of the line is ignored. A quote only OPENS at a
    token start (line start, or after `[`/`{`/`,`/`:`), so an apostrophe or a
    bracket inside a plain scalar (`paths: it's fine`, `paths: foo[bar`) opens
    nothing.

    WHY THIS EXISTS: the block-form walk terminates the `on:` region at the next
    COLUMN-0 line. A multi-line flow collection or quoted scalar puts a
    continuation at column 0, so terminating there reads only PART of the block
    and can answer `no` for a workflow that declares pull_request — a fail-open
    on the merge gate. The caller carries this state so a column-0 line inside an
    open construct is a continuation, never the terminator.
    """
    i = 0
    n = len(text_part)
    prev = None  # last significant (non-space) character seen on this line
    while i < n:
        ch = text_part[i]
        if quote == '"':
            if ch == "\\":
                i += 2
                continue
            if ch == '"':
                quote = ""
            i += 1
            continue
        if quote == "'":
            if ch == "'":
                if i + 1 < n and text_part[i + 1] == "'":
                    i += 2  # `''` escapes a single quote inside a single-quoted scalar
                    continue
                quote = ""
            i += 1
            continue
        if ch == "#" and (prev is None or prev in " \t"):
            break  # comment to end of line
        if ch in "\"'":
            if prev is None or prev in "[{,:":
                quote = ch
            i += 1
            prev = ch
            continue
        if ch == "[" or ch == "{":
            # A flow collection OPENS only at a value position. A bracket INSIDE a
            # plain scalar (`paths: src/[a-z]*`, `paths: foo[bar`) does NOT open
            # one — and counting it would make the region look unterminated, skip
            # the trigger keys after it, and answer `no` for a workflow that DOES
            # declare pull_request. Same token-boundary rule as a quoted scalar.
            if prev is None or prev in "[{,:":
                depth += 1
        elif ch == "]" or ch == "}":
            if depth > 0:
                depth -= 1
        if ch not in " \t":
            prev = ch
        i += 1
    return depth, quote


broke_at = None  # set by the block-form walk when a column-0 key ends the region

if inline:
    triggers = from_inline(inline)
    if triggers is None:
        sys.stdout.write(UNKNOWN + "\n")
        sys.exit(0)
else:
    # Block form: depth-1 keys are the triggers. Walk forward until the next
    # top-level key, collecting (indent, key) for every mapping line. A line that
    # is not a mapping line (`- item`, a scalar continuation, blank, comment) is
    # not a trigger key — but it CAN open a flow collection or a quoted scalar
    # that continues onto a LATER line, so the walk carries that state: while a
    # `[`/`{` or a quote is OPEN, a column-0 line is a CONTINUATION, not the next
    # top-level key. Terminating on it truncates the trigger set and can answer
    # `no` for a workflow that declares pull_request — the fail-open that
    # `scan_flow_state` closes. A MERGE KEY at depth 1 can pull in triggers from
    # an anchor, whose names this parser cannot see, so it forces `unknown`.
    collected = []
    merges = []
    flow_depth = 0
    open_quote = ""
    broke_at = None
    for line_no, raw in enumerate(lines[on_index + 1:]):
        if flow_depth == 0 and not open_quote:
            if not raw.strip():
                continue
            if raw.lstrip().startswith("#"):
                continue
            if raw[:1] not in (" ", "\t"):
                broke_at = on_index + 1 + line_no
                break  # next top-level key genuinely ends the `on:` block
            indent = len(raw) - len(raw.lstrip(" \t"))
            if "\t" in raw[:indent]:
                # A tab in the indentation is not legal YAML; refuse.
                sys.stdout.write(UNKNOWN + "\n")
                sys.exit(0)
            stripped = raw.lstrip()
            if stripped.startswith("?") or stripped.startswith(":"):
                # An EXPLICIT mapping key (`? name` / `: value`) IS a trigger key,
                # but not one this parser reads — so the set would be silently
                # PARTIAL. A partial read is never authoritative: refuse.
                sys.stdout.write(UNKNOWN + "\n")
                sys.exit(0)
            if stripped.startswith("<<"):
                merges.append(indent)
                flow_depth, open_quote = scan_flow_state(raw, flow_depth, open_quote)
                continue
            m = _BLOCK_KEY_RE.match(raw)
            if not m:
                # Not a mapping line (a `- item`, a scalar continuation, or a key
                # this parser does not recognise). It cannot add a trigger key,
                # but the state must still advance — it may open a flow/quote.
                flow_depth, open_quote = scan_flow_state(raw, flow_depth, open_quote)
                continue
            key = m.group(2) if m.group(2) is not None else (
                m.group(3) if m.group(3) is not None else m.group(4))
            if not _KEY_RE.match(key):
                sys.stdout.write(UNKNOWN + "\n")
                sys.exit(0)
            collected.append((indent, key))
            flow_depth, open_quote = scan_flow_state(raw, flow_depth, open_quote)
        else:
            # Inside an open flow collection / quoted scalar: this line is a
            # CONTINUATION, never a depth-1 trigger key — and it may close the
            # construct. A column-0 line here is NOT the next top-level key.
            flow_depth, open_quote = scan_flow_state(raw, flow_depth, open_quote)
    if flow_depth != 0 or open_quote:
        # The walk ended with an unterminated flow/quote, so it read only PART of
        # the `on:` block — and a partial read that answered `no` would be a
        # fail-open. Refuse.
        sys.stdout.write(UNKNOWN + "\n")
        sys.exit(0)
    if not collected:
        sys.stdout.write(UNKNOWN + "\n")
        sys.exit(0)
    depth = min(ind for ind, _ in collected)
    if any(ind == depth for ind in merges):
        # A depth-1 merge key can add triggers from elsewhere in the document.
        sys.stdout.write(UNKNOWN + "\n")
        sys.exit(0)
    triggers = {k for ind, k in collected if ind == depth}

if broke_at is not None and not (triggers & PR_TRIGGERS):
    # SAFETY NET (#6807). The block walk terminated at a column-0 line and found
    # no PR trigger. If a `pull_request` / `pull_request_target` KEY appears after
    # that point, the "terminator" was a continuation this parser did not
    # recognise — a PARTIAL read. A partial read that answers `no` exempts a red a
    # PR can measure, so refuse instead (fail closed). This can only turn `no`
    # into `unknown`, never the reverse.
    for raw in lines[broke_at + 1:]:
        m = _BLOCK_KEY_RE.match(raw)
        if not m:
            continue
        k = m.group(2) if m.group(2) is not None else (
            m.group(3) if m.group(3) is not None else m.group(4))
        if k in PR_TRIGGERS:
            sys.stdout.write(UNKNOWN + "\n")
            sys.exit(0)

sys.stdout.write((YES if (triggers & PR_TRIGGERS) else NO) + "\n")
PYEOF
