# Fixture repo — simulated consumer

> This fixture stands in for a real consumer of agent-infra. Its copied
> surfaces (AGENTS.md, .mcp.json, .husky/*) are DELIBERATELY customized —
> consumers legitimately diverge from the base templates. In CI mode these
> are content-drift warnings (exit 0); structural surfaces still fail.

## Fixture specifics

- Relative `scripts` symlink into the agent-infra checkout (resolves in-place).
- Real committed CI-workflow file (docs stack) — the #303 real-file contract:
  GitHub Actions cannot parse symlinked workflow files (#555), so consumers
  commit REAL workflow files pinned to a semver tag (manifest ci.ref).
- Customized AGENTS.md / .mcp.json / .husky/pre-commit (content drift).
- `.agent-infra-version` is written by tests/drift/run.sh (gitignored).
