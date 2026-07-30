---
name: shared-verify
description: Pre + post-deploy verification gate. Epic → epic-verify, Project → verification-before-completion.
domain: capability
type: Routing
status: stub
tags: [pipeline, shared, verify]
created: 2026-07-26
---

> ⚠️ **Stub — full implementation pending (#5872).** Routes to existing skills.

# Verify Stage

## Instructions

1. **Epic workflow:** Run `epic-verify` — cross-phase coherence, E2E alignment, artifacts.
2. **Project workflow:** Run `verification-before-completion` — typecheck, tests, deploy check.
