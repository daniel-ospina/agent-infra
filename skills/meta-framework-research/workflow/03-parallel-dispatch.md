# Phase 3: Parallel Research Dispatch

Dispatch independent sub-agents to research the domain from multiple lenses simultaneously. Follows `parallel-orchestrator` fan-out/fan-in pattern.

## Steps

### 3.1 Check for Clear Domain
If Phase 1 classified domain as **Clear**: skip parallel dispatch. Run a single best-practice query instead:
```
web_search("best practices for <domain> framework")
```
Write result to `research/03-lenses/best-practice.md`. Skip to Phase 4.

### 3.2 Prepare Lens Prompts
For each selected lens, construct a sub-agent prompt:

**Canonical lens:** "Research the mainstream/accepted frameworks and thinkers in <domain>. What does the establishment say? What's the consensus view?"

**Critical lens:** "Research what's wrong, missing, or oversimplified in <domain>. What frameworks are overrated? What evidence contradicts the consensus? What are the blind spots?"

**Systems lens:** "Research how pieces of <domain> connect. What are the causal relationships between sub-domains? What feedback loops exist? How does changing one part affect others?"

**Historical lens:** "Research how <domain> evolved over time. What were the key turning points? Which frameworks emerged when and why? What was replaced and why?"

**Outlier lens:** "Research fringe, emerging, or contrarian perspectives in <domain>. What's on the horizon? What ideas are dismissed but might be right? What are practitioners doing that academics haven't formalized?"

**Practitioner lens:** "Research how <domain> is actually applied in practice. What do practitioners use vs what textbooks recommend? What's the gap between theory and practice?"

**Contemporary lens:** "Run web_search for leading-edge developments in <domain>. Search queries:
- '<domain> latest developments <current year>'
- '<domain> emerging trends <current year>'
- 'how is AI changing <domain>'
- '<domain> thought leaders Substack Twitter'

Then synthesize: what's shifting in <domain> RIGHT NOW (last 12-24 months)? What established frameworks are being challenged by AI, automation, and cost inversion? What do leading-edge practitioners say that contradicts textbooks? What new practices have emerged that aren't yet formalized into frameworks? Search for: recent conference talks, Substack posts, Twitter/X threads from domain leaders, GitHub trending projects, Hacker News discussions. Focus on velocity of change, not just novelty.

IMPORTANT: For each contrarian position found, IDENTIFY THE THINKER by name. Output a table:
| Thinker | What They Challenge | Their Alternative | Evidence | Confidence |
|---------|---------------------|-------------------|----------|------------|
This feeds directly into the Contrarian Thinkers section of the output."
**Authority lens:** "Research how success is defined in <domain> and WHO defines it. Steps:
1. Run web_search: 'how is success defined in <domain>' and '<domain> success criteria metrics'
2. Identify the canonical institutions, publications, and individuals that DEFINE success in this domain (e.g., for startups: YC, a16z; for medicine: NEJM, Lancet, WHO; for design: Apple, IDEO, Dieter Rams)
3. Run web_search specifically targeting those authorities: '<authority> <domain> framework methodology'
4. Surface: what frameworks/references/standards do these authorities use that general research misses?

Why this lens: Domain authority is often concentrated in specific institutions. Searching 'startup strategy' returns generic content; searching 'YC startup framework' returns the source material that defines the domain. This lens identifies the arbiters of success FIRST, then searches their outputs."


### 3.3 Dispatch (Parallel)
Dispatch ALL lens sub-agents simultaneously via `task` tool. Each writes output to `research/03-lenses/<lens>.md`.

**Fan-out pattern (per parallel-orchestrator):**
- Dispatch all lenses in one call batch
- Each sub-agent prompt includes: lens description + domain name + scope + "write findings to `research/03-lenses/<lens>.md`"
- No sub-agent timeout — wait for all

### 3.4 Handle Partial Failure
After all lenses return:
- **All succeeded:** proceed to Phase 4
- **≤1 lens failed:** proceed with remaining lenses. Flag missing perspective in Phase 5 gap analysis
- **≥2 lenses failed:** abort pipeline. Output partial findings with warning:
  ```
  ⚠️ PHASE_ERROR
  phase: 3
  reason: "<N> of <M> lenses failed"
  action: abort
  ```
  Write available findings to research/ directory. Do NOT proceed to Phase 4.

### 3.5 Context Management
Lenses write to disk (`research/03-lenses/`). Do NOT hold all lens outputs in context simultaneously — Phase 4 reads them sequentially from disk.

Proceed to Phase 4.
