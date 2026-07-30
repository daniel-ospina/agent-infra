# Phase 1: Intake

Receive domain name and scope. Classify the domain using Cynefin. Produce structured classification.

## Steps

### 1.1 Parse Input
Extract from invocation: `domain`, `scope` (default: comprehensive), `team` (infer from cwd), `lenses` (auto-select), `execution_intent` (default: autonomous).

### 1.2 Validate Domain
- Empty or whitespace-only → halt with:
  ```
  ⚠️ VALIDATION_ERROR
  field: domain
  message: "Domain is required"
  ```
- Valid domain name → continue to 1.3

### 1.3 Classify Domain (Cynefin)
Ask: what is the causal structure of this domain?

| Question | If Yes | Domain |
|---|---|---|
| Can I write down exact steps to understand this domain? | Yes | **Clear** — best practice exists, skip research |
| I know what questions to ask, just need expert answers | Yes | **Complicated** — analyze (sense→analyze→respond) |
| Multiple competing hypotheses, all coherent, all supported by evidence | Yes | **Complex** — probe first (probe→sense→respond) |

Default: if uncertain → Complex (safer to over-probe than under-probe).

### 1.4 Handle Ambiguity
If domain cannot be classified:
```
⚠️ AMBIGUOUS_DOMAIN: <domain>
Reason: <why unclassifiable>
Suggestion: <clarification request or sub-domain suggestion>
```
**HALT.** Controller must resolve before re-invoking.

### 1.5 Handle Too-Broad Domain
If domain is valid but too broad (e.g., "philosophy", "science", "technology"):
```
⚠️ DOMAIN_ERROR
kind: too_broad
domain: <domain>
sub_domains: [<suggested decomposition>]
```
**HALT.** Controller must narrow scope.

### 1.6 Select Lenses
If `lenses` not explicitly provided, auto-select:
- Complex → all 8: canonical, critical, systems, historical, outlier, practitioner, contemporary, authority
- Complicated → 5: canonical, critical, systems, practitioner, contemporary
- Clear → none (single best-practice query in Phase 3 instead)
- execution_intent=fast → 3: canonical, critical, authority

### 1.7 Write Artifact
Write to `research/01-domain-classification.md`:
```markdown
# Domain Classification: <domain>

**Cynefin Domain:** <Clear | Complicated | Complex>
**Rationale:** <1-2 sentence justification>
**Scope:** <comprehensive | targeted | quick>
**Team:** <team name>
**Selected Lenses:** <lens list>
**Execution Intent:** <profile>
```

Proceed to Phase 2.
