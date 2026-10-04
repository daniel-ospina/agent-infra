/**
 * Redact credentials from a command before it hits the audit log.
 *
 * The audit files (`~/.pi/agent/audit/*.jsonl`) are WORLD-READABLE, so an inlined
 * `GH_TOKEN=…` must never persist. Hoisted here from `verification-gate` (which
 * owned the rule and the helper) when `review-enforcer` began recording the
 * refused command in `gate-events.jsonl` (#1492): two gates writing the same
 * `command` field into the same JSONL stream must not carry two drifting
 * redactors, and a second copy is exactly the drift the shared seam exists to
 * prevent (#966).
 *
 * Deliberately conservative — it over-redacts rather than under-redacts, because
 * a false redaction costs readability and a miss persists a live credential.
 */
export function redactCommand(command: string): string {
  return command
    .replace(/\b(?:GH|GITHUB)_TOKEN=\S+/gi, "***")
    // All six GitHub token families: ghp_ gho_ ghu_ ghs_ ghr_ github_pat_.
    // NO word anchors on either pattern. The patterns these replaced had none, and an
    // anchor makes a token that is preceded by a word character (`TOKEN_ghp_…`) or
    // followed by `_` (`ghp_abc_def`) survive — the direction this module must never
    // err in. Measured against `origin/main` both times; each attempt to be cleverer
    // than the original pattern lost coverage (review, #1492).
    .replace(/gh[opusr]_[A-Za-z0-9]+/g, (m) => `${m.slice(0, 4)}***`)
    .replace(/github_pat_[A-Za-z0-9_]+/g, "github_pat_***");
}
