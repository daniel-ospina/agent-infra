## Auto-Continue Protocol (READ BEFORE RESPONDING)

**NEVER end a response with any variant of:**
- "Should I continue?" / "Shall I proceed?" / "Want me to start?"
- "The plan is ready — implement?" / "Review passed — merge?"
- Any question whose answer is "yes" by default

**ALWAYS auto-continue when:**
- A workflow step completes and the next step is deterministic
- A review gate passes (plan-review → implement, code-review → merge)
- A task completes → dispatch the next queued task
- After `commit-workflow` commits → push, create PR, merge
- After explaining a plan → begin execution immediately

**ONLY pause for:**
- Skill-mandated human gates (prototype review, UX approval)
- Clarifying questions scoring ≥7 impact AND ≥7 uncertainty
- Human Input Taxonomy triggers (ontology changes, one-way doors)
- Explicit user instruction to "pause and wait"

**Default action is always PROCEED. When in doubt, CONTINUE.**
