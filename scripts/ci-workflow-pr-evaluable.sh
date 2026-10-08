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
# ── THE QUESTION IS SELECTABLE (#1614), AND THE DEFAULT IS THE #6807 ONE ─────
# `CI_WF_PR_EVALUABLE_QUESTION` selects WHICH question the one token answers:
#   check-attachable   (DEFAULT) — "can this workflow's checks attach to a PR
#                      head sha, so that its base red is a red the PR could have
#                      measured?" This is the #6807/#1542 contract and is
#                      UNCHANGED. For a REUSABLE (`workflow_call`) workflow it
#                      must stay `unknown`, because its jobs DO attach — inside
#                      its CALLER's run, under the CALLER's name — and answering
#                      `no` here would be consumed downstream as an affirmative
#                      exemption of a red a PR may well have measured (the #1413
#                      decision; see `trigger_measurable`).
#   lane-applicable    — "does this workflow declare a pull_request /
#                      pull_request_target that can FIRE for THIS PR's changed
#                      set?" This is the LANE-SELECTOR question the merge rail
#                      needs (#1614): a workflow with no PR trigger at all
#                      cannot produce a run of ITSELF on a PR head, so a lane
#                      pointed at it is INAPPLICABLE to the diff, not missing.
#                      Unlike the default question, a workflow whose only
#                      triggers are non-PR answers `no` — MEASURED, not guessed,
#                      because the trigger set was parsed in full (the #6807
#                      safety net still turns an undecidable document into
#                      `unknown`). The `no` here is NOT an exemption and is not
#                      consumed as one: the rail's caller falls back to a
#                      STRICTER surface (every lane that ran), never to "nothing".
# In `lane-applicable` mode a one-line `lane-applicable: …` REASON is written to
# stderr naming the ground (no PR trigger declared / the path filter excluded
# every changed path, with the patterns). stdout stays ONE token either way.
# PR_CHANGED_PATHS must be SET in either mode for a `paths:`-filtered PR trigger
# to be decidable; absent means undecidable, never "matches nothing".
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

# #1614: which question this invocation answers. An unknown value is treated as
# the DEFAULT, which is the fail-closed direction for BOTH callers: the default
# can only answer `no` for a document whose triggers are all non-PR, and the
# lane-applicable caller is the only one that consumes `no` as a fallback.
QUESTION = os.environ.get("CI_WF_PR_EVALUABLE_QUESTION", "check-attachable")
LANE_APPLICABLE = QUESTION == "lane-applicable"

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

# THE SAFETY NET's matcher: a `pull_request` / `pull_request_target` KEY anywhere
# in the document, however it is spelled (quoted, anchored, tagged). It is
# deliberately looser than `_BLOCK_KEY_RE` — a node this parser cannot name must
# still be able to force a refusal.
_PR_KEY_RE = re.compile(r"(?<![\w-])[\"']?pull_request(?:_target)?[\"']?\s*:")

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


def _opens_node(prev, sep, depth):
    """May a flow collection / quoted scalar START at this character?

    A plain scalar's characters are not indicators. In BLOCK context (`depth == 0`)
    a node starts only where a mapping/sequence separator is followed by
    WHITESPACE (`key: [a, b]`, `- [a, b]`) or at the start of the line's content —
    because a bare `:`/`,` with no space is part of a PLAIN SCALAR
    (`default: a:[b`, `paths: a:{b`), and reading one character of that scalar as
    a flow opener swallows the rest of the block and can answer `no` for a
    workflow that declares pull_request. In FLOW context a node may follow any of
    `[`/`{`/`,`/`:` with no space (`{a:[b]}`).
    """
    if depth > 0:
        return prev in "[{,:"
    return prev is None or (prev in ":-" and sep)


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
    sep = True   # the char immediately before i is whitespace (or i is line start)
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
            if _opens_node(prev, sep, depth):
                quote = ch
            i += 1
            prev = ch
            sep = False
            continue
        if ch == "[" or ch == "{":
            # A flow collection OPENS only where a node may start. A bracket INSIDE
            # a plain scalar (`paths: foo[bar`, `paths: a:{b`) does NOT open one —
            # counting it would make the region look unterminated, skip the trigger
            # keys after it, and answer `no` for a workflow that DOES declare
            # pull_request.
            if _opens_node(prev, sep, depth):
                depth += 1
        elif ch == "]" or ch == "}":
            if depth > 0:
                depth -= 1
        if ch in " \t":
            sep = True
        else:
            prev = ch
            sep = False
        i += 1
    return depth, quote


# ── #1542: the trigger's FILTERS decide measurability, not just its name ─────
# A trigger NAME alone cannot answer "can this workflow attach a check to THIS
# PR's head sha?". Two limbs:
#   OVER-BLOCK — `pull_request` with a `paths:` filter that the PR's changed set
#     cannot match never runs for that PR, so it cannot have measured the red we
#     are comparing it against.
#   FAIL-OPEN  — a `push:` with NO `branches` filter DOES run on a PR's head
#     branch, so its checks CAN attach; exempting its base red exempts a red the
#     PR could have measured. The fail-open dominates: a fix that closes only the
#     over-block would leave this gate MORE permissive than it is now.
# BOTH inputs are optional env vars. ABSENT MEANS UNDECIDABLE, NOT EMPTY: with no
# changed set a filtered `pull_request` is `unknown` (which the caller treats as
# blocking), never `no`. Only an affirmative, *measured* mismatch exempts.
PR_HEAD_BRANCH = os.environ.get("PR_HEAD_BRANCH") or None
_raw_paths = os.environ.get("PR_CHANGED_PATHS")
# ⛔ A WHITESPACE-ONLY VALUE IS UNREADABLE, NOT EMPTY. `[ -z ]` in the calling
# shell does not catch `"   "`, and an EMPTY path list makes `matches_multi`
# answer "matches nothing" — which a filtered trigger reads as an AFFIRMATIVE
# EXEMPTION. So an all-blank list collapses to None (undecidable) here, at the
# one place every caller's input passes through.
PR_CHANGED_PATHS = ([p for p in _raw_paths.split("\n") if p.strip()] or None) if _raw_paths else None

_FILTER_KEYS = {"paths", "paths-ignore", "branches", "branches-ignore",
                "tags", "tags-ignore"}


def collect_filters(lines, on_index):
    """{trigger: {filter_key: [patterns]}} for the BLOCK form, else None.

    Returns None when the region does not fit the shape this reads, and the
    caller then fails closed PER TRIGGER. It reads only a depth-1 `trigger:`, a
    depth-2 filter key under it, and `- 'pattern'` items (or an inline `[a, b]`).
    Anything else — an inline value on the trigger key, a deeper nesting, a
    non-list scalar — abandons the attribution rather than guessing it.
    """
    out = {}
    cur_trig = None
    cur_filter = None
    base = None
    # #1637: set when a key that is NOT a filter is seen at trigger depth. A
    # reusable trigger needs to know (see the guard below and the tail check).
    nonfilter_seen = False

    def _unquote(s):
        if len(s) >= 2 and s[0] == s[-1] and s[0] in "\"'":
            return s[1:-1]
        return s

    for raw in lines[on_index + 1:]:
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        if raw[:1] not in (" ", "\t"):
            break
        indent = len(raw) - len(raw.lstrip(" \t"))
        s = raw.strip()
        if base is None:
            base = indent
        if indent == base:
            m = _BLOCK_KEY_RE.match(raw)
            if not m:
                return None
            cur_trig = m.group(2) if m.group(2) is not None else (
                m.group(3) if m.group(3) is not None else m.group(4))
            cur_filter = None
            out.setdefault(cur_trig, {})
            rest = (m.group(5) or "").strip()
            if rest and rest not in ("|", ">"):
                return None  # an inline value on the trigger key
            continue
        if cur_trig is None:
            return None
        if s.startswith("-"):
            # A list item. It is a FILTER pattern only when it follows a filter
            # key we read; a list under some other key (`schedule: - cron: …`) is
            # not ours to interpret, and bailing to `None` for it would fail
            # EVERY trigger closed (a `push` alongside a `schedule` would stop
            # being exempt). Ignore it and keep reading.
            if cur_filter in _FILTER_KEYS:
                out[cur_trig].setdefault(cur_filter, []).append(_unquote(s[1:].strip()))
            else:
                # ⛔ #1637 REVIEW P2 — THIS IS A CONTENT PATH TOO. A list under a
                # key this reader does not interpret is attribution it could not
                # complete, so it must set the flag that lets a REUSABLE trigger
                # in the same document fail closed. It was the one content path
                # that did not, so `workflow_call` + `schedule:\n    - cron: …`
                # reached `flt == {}`, fell through to `trigger_measurable`'s tail
                # `return False`, and answered `no` — the same fail-open, on the
                # ordinary way to write a schedule.
                nonfilter_seen = True
            continue
        m = _BLOCK_KEY_RE.match(raw)
        if not m:
            return None
        cur_filter = m.group(2) if m.group(2) is not None else (
            m.group(3) if m.group(3) is not None else m.group(4))
        # ⛔ #1637 — A NON-FILTER KEY MUST NOT ABANDON THE ATTRIBUTION.
        # The bail below (`return None` on an inline non-list scalar) is right for
        # a FILTER whose shape this reader cannot parse, but it is wrong for a key
        # that is not a filter at all — and `workflow_dispatch.inputs` is nothing
        # but those (`description:`, `required:`, `default:`, `type:`). A `None`
        # here means "the region does not fit this shape", which the caller reads
        # as an unattributed trigger — so the #6807 exemption stopped firing for
        # the very file it was written for (`deploy-hosted.yml`: `on: push` with
        # `branches:` + `workflow_dispatch`, and no `pull_request` at all) the
        # moment #1542 introduced this reader. Measured on identical input: the
        # pre-#1542 predicate answers `no` for that file, this one answered
        # `unknown`.
        #
        # BUT A NON-FILTER KEY'S SHAPE STILL HAS TO BALANCE. Such a key is not
        # ours to interpret, yet an UNTERMINATED flow collection is a shape this
        # reader cannot attribute wherever it appears, so it still bails. Without
        # this, a `paths:` inside another key's multi-line flow sequence is read as
        # a top-level PR filter and the verdict moves `yes` -> `no` on input the
        # reader cannot attribute — a fail-open.
        #
        # #1413 IS THE ONE INVARIANT THAT SURVIVES, AND IT IS A PROPERTY OF THE
        # TRIGGER — NOT OF WHICH KEY HAPPENED TO BAIL. A reusable workflow's jobs
        # attach a check to a PR head inside the CALLER's run, under the CALLER's
        # NAME, so this file cannot answer for it: `unknown` is the only sound
        # answer, and `no` would be consumed downstream as a false exemption. That
        # is reached through `flt is None`, so ANY `workflow_call` in the document
        # whose attribution is not COMPLETE must keep failing the attribution.
        # ⛔ KEYING THIS ON `cur_trig` WAS A BUG: an unattributable key under a
        # SIBLING (`workflow_call` + `workflow_dispatch: inputs:` at the same
        # depth) left the reusable trigger with `flt == {}`, execution fell through
        # to `trigger_measurable`'s tail `return False`, and the predicate answered
        # `no` — the same fail-open, one trigger over. The document-level flag
        # tested at the tail is the correct predicate. A BARE `workflow_call` (no
        # non-filter key anywhere) still answers `no`.
        if cur_filter not in _FILTER_KEYS:
            nonfilter_seen = True
            rest = (m.group(5) or "").strip()
            if (rest[:1] == "[" and rest[-1:] != "]") or (rest[:1] == "{" and rest[-1:] != "}"):
                return None
            cur_filter = None
            continue
        rest = (m.group(5) or "").strip()
        pats = []
        if rest.startswith("["):
            if not rest.endswith("]"):
                return None
            for part in rest[1:-1].split(","):
                part = part.strip()
                if part:
                    pats.append(_unquote(part))
        elif rest and rest not in ("|", ">"):
            return None
        out[cur_trig][cur_filter] = pats
    # #1413, at the DOCUMENT level (see the guard above): a reusable trigger whose
    # attribution is INCOMPLETE must fail closed, even when the unattributable key
    # lived under a sibling trigger.
    if nonfilter_seen and "workflow_call" in out:
        return None
    return out


def _glob_re(pat):
    """A GitHub filter pattern as a regex. `**` spans `/`, `*`/`?` do not."""
    out = []
    i, n = 0, len(pat)
    while i < n:
        c = pat[i]
        if c == "*":
            if i + 1 < n and pat[i + 1] == "*":
                out.append(".*")
                i += 2
            else:
                out.append("[^/]*")
                i += 1
        elif c == "?":
            out.append("[^/]")
            i += 1
        else:
            out.append(re.escape(c))
            i += 1
    return re.compile("^" + "".join(out) + "$")


def matches_any(value, patterns):
    """GitHub's ordered semantics: match a positive, then no `!` pattern."""
    pos = [p for p in patterns if not p.startswith("!")]
    neg = [p[1:] for p in patterns if p.startswith("!")]
    if not pos:
        return None  # a `!`-only list is not a decidable filter
    if not any(_glob_re(p).match(value) for p in pos):
        return False
    if any(_glob_re(p).match(value) for p in neg):
        return False
    return True


def matches_multi(values, patterns):
    for v in values:
        m = matches_any(v, patterns)
        if m is None:
            return None
        if m:
            return True
    return False


def any_unmatched(values, patterns):
    """True iff SOME value does NOT match — GitHub's `paths-ignore` rule.

    `paths-ignore` is NOT the mirror of `paths:`. GitHub: "When ALL the path names
    match patterns in `paths-ignore`, the workflow will not run. If ANY path names
    do not match patterns in `paths-ignore`, even if some path names match the
    patterns, the workflow will run." So the workflow runs iff some changed path is
    NOT ignored — `not all`, never `not any` (#1614 review: the `not any` form
    reported a workflow GitHub WILL run as unable-to-run, and that answer is
    consumed as an affirmative exemption by the rail's base-side `no)
    pr_evaluable=0` and by the #1614 lane-inapplicable fallback). `None` whenever
    any single match is undecidable.
    """
    for v in values:
        m = matches_any(v, patterns)
        if m is None:
            return None
        if not m:
            return True
    return False


def trigger_measurable(trig, flt):
    """True = measurable (blocks) / False = never attaches (exempt) / None = fail closed."""
    if flt is None:
        # Filters unattributed (an inline `on:` form, or a shape collect_filters
        # refused). A PR trigger is measurable whatever it filters on, so `yes`
        # keeps the pre-#1542 answer; a `push` may be unfiltered and measurable,
        # and we cannot tell — refuse rather than exempt.
        #
        # ⛔ `workflow_call` STAYS `None` HERE — and that is a DECISION, not an
        # omission (#1413). A REUSABLE workflow's jobs DO attach a check to a PR
        # head: they run inside the CALLER's run, under the CALLER's NAME. Measured:
        # .github/workflows/ci.yml is `on: pull_request` and calls
        # node-ci.yml@main, and a PR head's check-runs carry `ci / unit-test`,
        # `ci / lint`, `ci / typecheck` — the CALLER's workflow name, not
        # node-ci.yml's. (The `extension-tests / *` jobs are ci-main.yml's, a
        # POST-MERGE push lane — citing those as the PR evidence was wrong.)
        # So this file CANNOT answer for it — whether
        # any caller runs it on pull_request is unknowable from the file alone — and
        # `None` (fail closed) is the only sound answer. Returning `False` would be
        # consumed as an AFFIRMATIVE EXEMPTION downstream (admin-merge.sh's base-side
        # `no) pr_evaluable=0`, which prints "no PR can attach its checks to a head
        # sha") — a false claim and a FAIL-OPEN in the same line.
        return True if trig in PR_TRIGGERS else None
    if trig in PR_TRIGGERS:
        if "paths" in flt and "paths-ignore" in flt:
            return None  # GitHub rejects both; never guess which wins
        if "paths" in flt:
            return None if PR_CHANGED_PATHS is None else matches_multi(PR_CHANGED_PATHS, flt["paths"])
        if "paths-ignore" in flt:
            if PR_CHANGED_PATHS is None:
                return None
            return any_unmatched(PR_CHANGED_PATHS, flt["paths-ignore"])
        return True
    if trig == "push":
        # ⛔ NOT PR-EVALUABLE, FILTERED OR NOT — and this is a DECISION, not an
        # oversight. A `push` workflow runs on a push to a BRANCH; its checks land
        # on the pushed commit, never on `refs/pull/<N>/merge`, which is the
        # surface the rail compares. So no `push` run can appear on a PR's
        # evaluated tree, whether or not it carries a `branches` filter.
        #
        # A FIRST DRAFT OF #1542 CLAIMED THIS LIMB WAS A FAIL-OPEN (an unfiltered
        # `push` runs on a PR's head branch, so its red "could have been
        # measured"). That claim is WITHDRAWN: it contradicts the contract this
        # file documents above, and implementing it regressed #6807's merged fix
        # (9 of 979 admin-merge tests, including #6807's own fixture — the
        # unfiltered `on: push` `deploy-hosted` — because it stopped exempting
        # exactly the base reds #6807 was merged to stop refusing). Re-creating
        # that over-block is worse than the latent risk it was traded for.
        # If the unfiltered-`push` case is genuinely wanted, it needs its own
        # issue and a decision — NOT a silent widening here.
        return False
    # schedule / workflow_dispatch / issues / … never attach a check to a head.
    return False


if inline:
    triggers = from_inline(inline)
    filters = None
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
    for raw in lines[on_index + 1:]:
        if flow_depth == 0 and not open_quote:
            if not raw.strip():
                continue
            if raw.lstrip().startswith("#"):
                continue
            if raw[:1] not in (" ", "\t"):
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
    filters = collect_filters(lines, on_index)

if not (triggers & PR_TRIGGERS):
    # SAFETY NET (#6807). The walk may have missed a PR trigger — a column-0
    # continuation it did not recognise, an ANCHORED or TAGGED key
    # (`&a pull_request:`, `!!str pull_request:`) that `_BLOCK_KEY_RE` cannot
    # name, or any shape it silently skipped. A PARTIAL read that answers `no`
    # exempts a red a PR can measure, so if the document contains a
    # `pull_request` / `pull_request_target` KEY ANYWHERE, refuse (fail closed).
    # The matcher is deliberately looser than the key regex, so a node this
    # parser cannot NAME can still force a refusal. This can only turn `no` into
    # `unknown`, never the reverse — it cannot itself fail open.
    for raw in lines:
        if raw.lstrip().startswith("#"):
            continue
        if _PR_KEY_RE.search(raw):
            sys.stdout.write(UNKNOWN + "\n")
            sys.exit(0)

# ── #1614: THE LANE-SELECTOR QUESTION. A workflow whose `on:` block declares no
# pull_request / pull_request_target can never produce a run of ITSELF on a PR
# head, whatever the diff — so no path can "trigger" it and a lane pointed at it
# is INAPPLICABLE. This is ANSWERED BEFORE `trigger_measurable`, because that
# function's `None` for a non-PR trigger is the #1413 decision for the OTHER
# question (a reusable workflow's checks DO attach, via a caller). Here the
# trigger set was parsed in full and the #6807 safety net above has already
# promoted any unnameable PR key to `unknown`, so this `no` is MEASURED.
pr_triggers = triggers & PR_TRIGGERS
if LANE_APPLICABLE and not pr_triggers:
    sys.stderr.write(
        "lane-applicable: no-pr-trigger — the workflow's on: block declares no "
        "pull_request / pull_request_target, so no run of it can attach to a PR head "
        "(declared triggers: %s)\n" % ", ".join(sorted(triggers)))
    sys.stdout.write(NO + "\n")
    sys.exit(0)

# ── #1542: decide PER TRIGGER, and refuse rather than exempt ──────────────
# In lane-applicable mode only the PR triggers are consulted: a non-PR sibling
# (`push`, `schedule`, `workflow_call`) cannot fire a PR run, so its
# undecidability must not turn an otherwise-decided PR trigger into `unknown`.
verdicts = [trigger_measurable(t, (filters or {}).get(t) if filters is not None else None)
            for t in (pr_triggers if LANE_APPLICABLE else triggers)]
verdict = (YES if any(v is True for v in verdicts)
           else UNKNOWN if any(v is None for v in verdicts)
           else NO)
if LANE_APPLICABLE and verdict == NO:
    detail = []
    for t in sorted(pr_triggers):
        flt = (filters or {}).get(t) if filters is not None else None
        if not flt:
            continue
        for key in ("paths", "paths-ignore"):
            if key in flt:
                detail.append("%s %s: %s" % (t, key, ", ".join(flt[key])))
    if detail:
        sys.stderr.write(
            "lane-applicable: paths-excluded — the declared PR trigger's path "
            "filter matches none of this PR's changed files (%s)\n" % "; ".join(detail))
    else:
        sys.stderr.write(
            "lane-applicable: paths-excluded — no declared PR trigger can fire for "
            "this changed set\n")
elif LANE_APPLICABLE and verdict == UNKNOWN:
    sys.stderr.write(
        "lane-applicable: undecidable — the workflow's PR triggers or their filters "
        "could not be fully attributed, so the lane's applicability is UNMEASURED "
        "here (fail closed: the rail must refuse)\n")
sys.stdout.write(verdict + "\n")
PYEOF
