# Strategy Builder — Context Management

> Referenced by: `workflow/01-mode-and-setup.md` (progressive commit), `workflow/02-full-build-frameworks.md` (session boundaries).

---

## Progressive Commit Protocol

After each phase boundary: `git add docs/09_strategy/ && git commit -m "docs(strategy): Phase N complete — [brief description]"`

This is documentation, exempt from `commit-workflow`. Direct commits are appropriate.

**Core rule:** If context crashes, the last committed phase is always recoverable.

---

## Session Boundaries

| Session | Phases | Output |
|---|---|---|
| 1 | 1-2 | Philosophy + frameworks + customer definition |
| 2 | 3-3.5 | JTBD mapping + competitor intelligence |
| 3 | 4-5 | Competition + value prop + differentiators + pitch derivation |
| 4 | 6-7 | Experiments + coherence review |
| 5 | 8-9 | Pitch assessment + retrospective |

**Adaptive:** Simple → merge sessions. Complex → split phases into separate sessions.

---

## Session Handoff

When ending a session:
1. Ensure all outputs written to disk + committed
2. Provide exact resume prompt:

```
Continue strategy-builder in [mode] mode.
Read ALL artifacts (strategy/product docs live in the eldato repo — fetch: `gh api repos/daniel-ospina/eldato/contents/<path> --jq .content | base64 -d`):
- docs/teams/eldato-app-team/domains (S1)/product/strategy.md
- docs/teams/eldato-app-team/domains (S1)/product/philosophy.md
- docs/teams/eldato-app-team/domains (S1)/product/experiments.md
- docs/teams/eldato-app-team/domains (S1)/product/earned_secrets.md
- docs/09_strategy/research/YYYY-MM-DD-full-build.md (latest research dump)
Resume from Phase [N]. Previous session completed through Phase [N-1].
[Any specific context]
```

---

## Subagent Usage

- Parallel research queries (3-5 agents on different topics simultaneously)
- Adversarial review (sequential: attacker → defender → synthesizer)
- Competitor intelligence mining (1 agent per competitor)
- Clean room VP comparison (2 agents independently)

All subagents must read relevant strategy.md sections before starting, append to research dump, return structured outputs.
