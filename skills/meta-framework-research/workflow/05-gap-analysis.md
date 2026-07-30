# Phase 5: Gap Analysis

Identify missing perspectives, underweighted schools, and blind spots in the synthesis.

## Steps

### 5.1 Check for Complicated Domain
If Phase 1 classified domain as **Complicated**: run light checklist only (items 1-3). Skip full analysis.

### 5.2 Run Gap Checklist
Apply static checklist against synthesis:

- ☐ **School diversity:** Framework catalog covers ≥3 distinct schools of thought?
- ☐ **Outlier incorporation:** Outlier lens perspectives that didn't make the synthesis → flag
- ☐ **Geographic/cultural bias:** All frameworks from Western/English sources? → flag if yes
- ☐ **Temporal bias:** All frameworks from same era (e.g., all 1990s, all post-2020)? → flag if yes
- ☐ **Temporal validity:** For each framework in catalog: does it still hold under current conditions? Run stress test: what assumptions does it make about cost, speed, and scale? Flag any framework with assumptions invalidated by AI-era economics (near-zero software cost, instant iteration, automation of knowledge work).
- ☐ **Practitioner-academic balance:** Heavy on one side? → flag the imbalance
- ☐ **Missing sub-domains:** Any obvious sub-domain absent from ontology tree? → flag

### 5.3 Flag Partial Failure Gaps
If Phase 3 had partial failures (≤1 lens), flag the missing perspective(s):
```
⚠️ MISSING_PERSPECTIVE: <lens name> — lens failed in Phase 3. <domain> analysis may be incomplete in this dimension.
```

### 5.4 Identify Blind Spots
What might be missing not because of lens failure but because no lens was configured to look? Consider:
- Non-academic knowledge (practitioner heuristics, folk models)
- Non-English language research
- Pre-digital era frameworks (pre-1990)
- Cross-domain exaptation (frameworks from adjacent domains that apply here)

### 5.5 Write Artifact
Write to `research/05-gaps.md`:
```markdown
# Gap Analysis: <domain>

## Checklist Results
- [x] School diversity: ≥3 schools — <names>
- [ ] Geographic bias: all Western sources — <specific gap>
...

## Missing Perspectives
- <lens name>: lens failed in Phase 3

## Blind Spots
- <blind spot 1>
- <blind spot 2>
```

Proceed to Phase 6.
