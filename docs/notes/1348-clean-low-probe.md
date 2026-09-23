# End-to-end probe for `clean-low` (#1348)

Throwaway file. This PR is a **probe**, not a change: it exists to run the
`clean-low` guard against a REAL content-only diff and the real GitHub API, which
the stubbed unit suite cannot do. It is closed unmerged.

Why the probe is needed: every stub in the suite fabricates the compare response,
including the `merge_base_commit.sha` line. If the guard's `--jq` filter were
wrong against the real API, the guard would refuse every content-only PR —
fail-closed, so nothing unsafe would merge, but the verdict would be **inert**
and no test would notice. One real run settles it.
