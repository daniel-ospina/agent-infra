---
name: find-bugs
description: Find bugs, security vulnerabilities, and code quality issues in local branch changes. Use when asked to review changes, find bugs, security review, or audit code on the current branch.
allowed-tools: read write edit bash grep find web_search web_fetch todo_write task
steps:
  - name: input_gathering
    type: skill
    gate: auto
    produces: [file_list, scan_mode]
  - name: attack_surface_mapping
    type: skill
    gate: auto
    requires: [input_gathering]
    produces: [surface_map]
  - name: security_checklist
    type: skill
    gate: auto
    requires: [attack_surface_mapping]
    produces: [findings]
  - name: verification
    type: skill
    gate: auto
    requires: [security_checklist]
    produces: [verified_findings]
  - name: pre_conclusion_audit
    type: skill
    gate: verifier
    requires: [verification]
    produces: [final_report]
---
> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

**Verifier gate:** dispatches AI reviewers. Pipeline auto-advances when clean.

> **Source:** Canonical copy at `skills/find-bugs/SKILL.md``.

## Mode Detection

Before starting, detect the scan mode:

1. **Targeted mode** — user provided specific file paths → scan those files only
2. **Diff mode** (default) — no arguments → diff current branch against default branch (original behavior)
3. **Full-codebase mode** — user said "full", "full scan", or "full-codebase" → enumerate all .ts/.tsx files in src/, functions/, supabase/functions/ and batch-process through Phases 2-5

In full-codebase mode, replace Phase 1 (git diff) with:
```
find src/ functions/ supabase/functions/ -name '*.ts' -o -name '*.tsx' | grep -v '.test.' | grep -v '.d.ts'
```
Process files in batches of 10-15 for manageability. Apply Phases 2-5 to each batch.

# Find Bugs

Review changes on this branch for bugs, security vulnerabilities, and code quality issues.

## Phase 1: Complete Input Gathering

1. Get the FULL diff: `git diff $(gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name')...HEAD`
2. If output is truncated, read each changed file individually until you have seen every changed line
3. List all files modified in this branch before proceeding

## Phase 2: Attack Surface Mapping

For each changed file, identify and list:

* All user inputs (request params, headers, body, URL components)
* All database queries
* All authentication/authorization checks
* All session/state operations
* All external calls
* All cryptographic operations

## Phase 3: Security Checklist (check EVERY item for EVERY file)

* [ ] **Injection**: SQL, command, template, header injection
* [ ] **XSS**: All outputs in templates properly escaped?
* [ ] **Authentication**: Auth checks on all protected operations?
* [ ] **Authorization/IDOR**: Access control verified, not just auth?
* [ ] **CSRF**: State-changing operations protected?
* [ ] **Race conditions**: TOCTOU in any read-then-write patterns?
* [ ] **Session**: Fixation, expiration, secure flags?
* [ ] **Cryptography**: Secure random, proper algorithms, no secrets in logs?
* [ ] **Information disclosure**: Error messages, logs, timing attacks?
* [ ] **DoS**: Unbounded operations, missing rate limits, resource exhaustion?
* [ ] **Business logic**: Edge cases, state machine violations, numeric overflow?

## Phase 4: Verification

For each potential issue:

* Check if it's already handled elsewhere in the changed code
* Search for existing tests covering the scenario
* Read surrounding context to verify the issue is real

## Research Discipline

See [research-protocol Quick Reference](../reference/research-protocol/SKILL.md#quick-reference) for domain-aware external search patterns. Tier 1 integration.

### Phase 4.5 — External Vulnerability Cross-Reference (NEW)

For each HIGH-confidence finding, run 1 targeted `perplexity_search`:
- `"[pattern description] security vulnerability CVE known exploit"`

This catches patterns that are independently known vulnerabilities beyond OWASP checklists. Cap: 1 search per HIGH finding, max 5 searches total. Skip if no HIGH-confidence findings.

## Phase 5: Pre-Conclusion Audit

Before finalizing, you MUST:

1. List every file you reviewed and confirm you read it completely
2. List every checklist item and note whether you found issues or confirmed it's clean
3. List any areas you could NOT fully verify and why
4. Only then provide your final findings

## Output Format

**Prioritize**: security vulnerabilities > bugs > code quality

**Skip**: stylistic/formatting issues

For each issue:

* **File:Line** - Brief description
* **Severity**: Critical/High/Medium/Low
* **Problem**: What's wrong
* **Evidence**: Why this is real (not already fixed, no existing test, etc.)
* **Fix**: Concrete suggestion
* **References**: OWASP, RFCs, or other standards if applicable

If you find nothing significant, say so - don't invent issues.

Do not make changes - just report findings. I'll decide what to address.
---
> Continue following the workflow as mandated by this skill. Do not skip steps.
