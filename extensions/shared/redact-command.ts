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
 *
 * NO pattern below carries a word anchor, on either side. This is the whole of the
 * rule, and it is deliberate: an anchor makes a credential that sits against a word
 * character survive (`MY_GITHUB_TOKEN=…`, `TOKEN_ghp_…`, `ghp_abc_def`), which is the
 * one direction this module must never err in. Every attempt to be cleverer than the
 * unanchored original lost coverage somewhere (review, #1492) — so the tolerant shape
 * is the shape, for all three patterns, including the `_TOKEN=` rule above.
 */
export function redactCommand(command: string): string {
  return command
    .replace(/(?:GH|GITHUB)_TOKEN=\S+/gi, "***")
    // All six GitHub token families: ghp_ gho_ ghu_ ghs_ ghr_ github_pat_.
    .replace(/gh[opusr]_[A-Za-z0-9]+/g, (m) => `${m.slice(0, 4)}***`)
    .replace(/github_pat_[A-Za-z0-9_]+/g, "github_pat_***");
}
