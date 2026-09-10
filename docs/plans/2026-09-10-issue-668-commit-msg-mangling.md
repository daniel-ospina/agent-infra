---
title: "#668 — ban -m commit messages + flag shell-substitution-mangled ones — Scope & Plan"
type: engineering
domain: operations
doc_status: draft
subjects.team: organisation-design-team
created: 2026-09-10
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, issue-668
---

<!-- research-path: none — mechanical fix; no external research required (issue Research: none) -->

# #668 — the `-m` commit-message path mangles backticks

## Confirmed Problem

#194 (closed) fixed the **heredoc** class: `git commit -m "$(cat <<'EOF' … EOF)"`
breaks because the pi bash wrapper re-processes the command string. The
replacement standard ("write via the `write` tool to `/tmp/commit-msg-*.md`,
then `git commit -F`") was recorded in the commit-workflow skill, but the
**guidance named heredocs as the prohibited shape**, which leaves
`git commit -m "…"` looking permitted.

`-m` is the *same* hazard: inside double quotes the shell performs command
substitution before git sees the argument. Observed twice while landing #640
(both pushed mangled, each costing an `--amend` + force-push, and one later
flagged by a reviewer as an inaccurate record):

```
# source:  … key matching via keyRe() which tolerates `key :` — and anchors …
git commit -m "… key matching via keyRe() which tolerates \`key :\` — and anchors …"
# committed as (silent — the span became the empty string):
#   … key matching via keyRe() which tolerates  — and anchors …

# source:  … real binding set to `|| true` …
git commit -m "… real binding set to \`|| true\` …"
# bash: key: command not found   ← the substitution actually ran
```

The failure is **silent at commit time**: the substitution yields an empty
string, git accepts the message, and only a human reading the log sees the hole.
Nothing guarded `-m` — no hook, no test.

**Premise correction (verified against `origin/main`):** the heredoc prohibition
lives in `skills/commit-workflow/workflow/02-commit-pr.md`, and `AGENTS.md`
§Editing Rules carried **no** commit-message bullet at all (it names only `sed`,
`git add -A`, and the `edit`-over-`write` preference). The issue asked for the
rule to be present and to name every mangling shape — so this change **adds**
the bullet to `AGENTS.md` (and to `templates/AGENTS.base.md`, the base that
consumer repos materialize from) rather than rephrasing an existing one.

## Decision — warn-only vs reject (issue open decision 2)

**Decision: warn-only (exit 0), with `COMMIT_MSG_MANGLE_STRICT=1` as an opt-in
hard gate.**

Both detectable signatures have realistic false positives, so a *reject* gate
would block legitimate commits:

| Signature | Realistic false positive | Evidence |
|---|---|---|
| odd backtick count | a message may legitimately contain one backtick (`docs: explain the \` character`) | fixture `unbalanced.md` is planted, but the class is asymmetric detection — a lone-backtick prose message is indistinguishable |
| doubled space | aligned text / code blocks legitimately use runs of spaces (`name    value`) | fixture `aligned.md`: **flagged, exit 0** — asserted in the suite as the documented false positive |

I could not show the heuristic has **no** realistic false positive — I found at
least one for each signature, and the aligned-block case is pinned in the test
suite. Warn-only is therefore the correct level: it surfaces the hole without
becoming the new blocker. The decision is also cheap to revisit — strict mode
already exists, so a later "no false positives in N weeks" finding can flip the
default without a code change.

The hook applies to **every committer**, not only agents: there is no reliable
"is an agent" signal inside a `commit-msg` hook, and the defect is a property of
the message, not the author.

## Plan

1. **Guidance** — `AGENTS.md` §Editing Rules and `templates/AGENTS.base.md`:
   the rule becomes "always `git commit -F <file>` — **never `-m`, never a
   heredoc**", with the silent-substitution mechanism and the repair rule.
   (Deliberately NOT in §Review Loop Protocol — owned by #665 — or §Process
   Discipline — owned by #664.)
2. **Heuristic hook** — `.husky/commit-msg` (and the byte-identical
   `templates/.husky/commit-msg`, which `bin/agent-infra.js doctor` compares):
   * signature 1: odd backtick count (a backticked span was eaten);
   * signature 2: a doubled space between two non-space characters, excluding
     sentence-ending punctuation (`.`/`!`/`?`) — the hole an erased inline-code
     span leaves (`which tolerates  — and anchors`);
   * guarded `husky.sh` source + guarded `node_modules/.bin/commitlint` call so
     the file runs standalone when invoked directly (husky is uninstalled
     everywhere today — #672 — and this repo has no `commitlint`).
3. **Repair guidance** — in the hook's warning and in
   `workflow/02-commit-pr.md`: amend before push; if already pushed and under
   review, post a correction note rather than silently force-pushing.
4. **Worked example** — `write` → `/tmp/commit-msg-668.md` → `git commit -F`,
   with a message containing backticks, in `workflow/02-commit-pr.md`.
5. **Tests** — `scripts/commit-msg-check.test.sh`, invoking the hook directly
   (no husky), registered in `.github/workflows/ci-main.yml`.

## Verification

| Surface | Layer | Verification | Result |
|---|---|---|---|
| hook — clean | unit | multi-line Conventional Commit → exit 0, **no output** | ✅ |
| hook — unbalanced backticks | unit | planted message flagged, warn-only (exit 0) | ✅ |
| hook — substitution gap | unit | `… tolerates  — and anchors` flagged, warn-only | ✅ |
| hook — legit code | unit | balanced backticks + `$`/`{{` → exit 0, no output | ✅ |
| hook — sentence style | unit | two spaces after `.`/`!`/`?` not flagged | ✅ |
| hook — false positive | unit | aligned block flagged but exit 0 (evidence for warn-only) | ✅ |
| hook — strict | unit | `COMMIT_MSG_MANGLE_STRICT=1` → exit 1 on a hit | ✅ |
| hook — parity | unit | `.husky` == `templates/.husky`; hook executable | ✅ |
| real flow | manual | `write` → `/tmp/commit-msg-668.md` → `git commit -F` round-trips a message containing backticks and `$` | ✅ (this PR's own commit) |
| guidance | docs | `AGENTS.md` names `-m` and heredocs as forbidden and prescribes `write` + `-F` | ✅ |
| repo suites | CI | skill-lint, oracle, actionlint, ci-ref-check | ✅ |

## Non-goals

- Changing git semantics or wrapping git.
- Conventional-commit conformance linting (separate concern — commitlint's job).
- Installing husky (`core.hooksPath` is unset — #672, separate issue).

## Review Cycle Log

(Filled after the fresh-context review cycle.)

## Learnings

(Filled after implementation.)
