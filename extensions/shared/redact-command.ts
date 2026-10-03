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
    // All six GitHub token families, not just `ghp_`/`github_pat_` (review, #1492):
    // `ghs_` (server), `gho_` (OAuth), `ghu_` (user), `ghr_` (refresh) are equally live
    // credentials and `ghp_`'s sibling spelling was passing straight through.
    .replace(/\bgh[opusr]_[A-Za-z0-9]{20,}\b/g, (m) => `${m.slice(0, 4)}***`)
    .replace(/\bgithub_pat_[A-Za-z0-9_]+/g, "github_pat_***");
}
