# Phase 4: Synthesis

Synthesize lens outputs into structured intermediate artifacts. Map agreements, disagreements, and outliers. Build ontology tree and framework catalog.

## Steps

### 4.0 Size Check
Before starting synthesis, check total lens output size:
```bash
wc -l research/03-lenses/*.md | tail -1
```

- **<800 lines total:** Single pass — read all lenses, synthesize normally (Steps 4.1-4.8).
- **800+ lines total:** Split into two sub-agent passes:
  - **Pass A:** Read only canonical + systems + historical lenses → build ontology tree (Steps 4.5). Output: `research/04-ontology-tree.md`
  - **Pass B:** Read critical + outlier + practitioner + contemporary + authority lenses → build framework catalog + tensions + outlier observations (Steps 4.1-4.4, 4.6-4.7). Input includes Pass A's ontology tree.
  - Merge Pass A + Pass B outputs into `research/04-synthesis-map.yaml`.
- **Comprehensive scope:** Sub-agent timeout = 480s (not 240s).

### 4.1 Read Lens Outputs
Read each lens file from `research/03-lenses/<lens>.md` sequentially (not all in context at once). Extract key claims, frameworks, thinkers, and tensions.

### 4.2 Map Agreements
Build agreement matrix. Where ≥2 lenses assert the same claim → high-confidence.

```markdown
| Claim | Canonical | Critical | Systems | Historical | Outlier | Practitioner | Agreement |
|-------|-----------|----------|---------|------------|---------|-------------|-----------|
| <claim> | ✅/❌/— | ✅/❌/— | ... | ... | ... | ... | <N>/<M> |
```

### 4.3 Map Disagreements
Where lenses diverge → that's where the interesting information lives. Flag as tensions for the output.

### 4.4 Treat Outliers as Signal
The outlier lens may see what others don't. Do NOT dismiss — document separately. Per Snowden: "We don't see things we don't expect to see."

### 4.5 Build Ontology Tree
Structure domain → sub-domain → methodology/framework as nested list:

```
<domain>
├── <sub-domain A>
│   ├── <methodology 1>
│   └── <methodology 2>
├── <sub-domain B>
│   ├── <framework 1>
│   └── <framework 2>
└── <sub-domain C>
```

### 4.6 Build Framework Catalog
Per sub-domain, catalog frameworks:

```markdown
| Name | School | Thinkers (type) | Core Claim | When to Use | When NOT | Confidence |
|------|--------|-----------------|------------|-------------|----------|------------|
| <name> | <school> | <name> (Academic|Practitioner|Thought Leader) | <claim> | <context> | <anti-context> | <tier> |
```

### 4.6b Verify Catalog ↔ Tree Coherence
Cross-reference the ontology tree against the framework catalog. Every leaf in the tree MUST have a catalog entry. If a leaf has no catalog entry: either add it or document a reason for exclusion in the catalog header.

### 4.7 Identify Central Tensions

```markdown
| Axis | Position A | Position B |
|------|-----------|------------|
| <tension name> | <school A view> | <school B view> |
```

### 4.8 Write Artifact
Write to `research/04-synthesis-map.yaml` in structured format preserving:
- Agreement matrix
- Ontology tree
- Framework catalog
- Central tensions
- Outlier observations

Proceed to Phase 5.
