---
name: team-registration
description: Checklist for registering a new team across all operational surfaces. Use when creating a new team to ensure no registration surface is missed. Supabase is the canonical source of truth.
domain: operations
type: reference
status: live
allowed-tools: read write edit bash
tags: [operations, team-setup, checklist]
---

# Team Registration

Checklist of every surface that must be touched when creating a new team. Follow in order — each step is a hard gate. Skipping a step silently breaks issue labeling, escalation routing, or document classification.

**Canonical source of truth:** Supabase SOR in the **swarm** repo (`supabase/` migrations, `teams` table — `SUPABASE_URL_ORG_DATA` / `SUPABASE_SERVICE_ROLE_KEY_ORG_DATA`). All other surfaces are derived.

## Registration Surfaces

### 1. Supabase — teams table (CANONICAL)

Insert into the swarm org-data Supabase:

```sql
INSERT INTO teams (org_id, name, slug, description)
VALUES (
  (SELECT id FROM organizations WHERE slug = 'premise-labs'),
  '<Team Name>',
  '<team-slug>',
  '<one-line description>'
);
```

Then run the migration:
```bash
cd ~/Documents/GitHub/swarm && supabase db push
```

Verify via the agent-infra helper (needs the same env vars):
```bash
node scripts/swarm-org.mjs list-teams
```

### 2. Repo Setup

If this team needs its own repository, create it with the common structure:

```
<team-repo>/
  README.md              ← purpose, stack, index link, cross-repo refs to all El Dato repos
  docs/00_index.md       ← canonical index
  capability/index.md    ← placeholder (all 9 domains required)
  data/index.md
  engineering/index.md
  finance-accounting/index.md
  growth/index.md
  legal/index.md
  operations/index.md
  product/index.md
  ux/index.md
```

Use the common README template:
```markdown
# <Team Name>

<one-line description>

## Tech Stack

<stack>

## Documentation

See [docs/00_index.md](docs/00_index.md) for architecture and operations.

## Related Repositories
- [eldato](https://github.com/daniel-ospina/eldato) — Main El Dato app + canonical product docs
- [tortoise](https://github.com/daniel-ospina/tortoise) — Tortoise knowledge graph engine + canonical ontology (`docs/ONTOLOGY.md`)
- [swarm](https://github.com/daniel-ospina/swarm) — Org data Supabase SOR (`supabase/`, `connectors/supabase_org.py`) + coordination
- [eldato-outreach](https://github.com/daniel-ospina/eldato-outreach) — B2B WhatsApp outreach
- [dmer](https://github.com/daniel-ospina/dmer) — Instagram DM daemon
```

If the team lives in the main `eldato` repo, create domain folders at `docs/teams/<team-slug>/domains (S1)/<domain>/` (the eldato `docs/teams/` layout):

### 3. Main docs/00_index.md

Add team to the index in the main `eldato` repo's `docs/00_index.md` under the Teams section.

### 4. GitHub Label

```bash
gh label create "team:<team-slug>" --description "Issues owned by <team-slug>" --color "0E8A16" --force
```

### 5. GitHub Team (if new repo)

If a standalone repo was created in step 2:
```bash
gh api /orgs/daniel-ospina/teams -f name='<team-slug>' -f privacy='closed'
# Add repo to team
gh api /orgs/daniel-ospina/teams/<team-slug>/repos/daniel-ospina/<team-repo> -X PUT
```

### 6. Classification Manifest (eldato repo)

Add a `batch_N_<team-slug>:` section to `docs/teams/_classification-manifest.yaml` in the **eldato** repo for any epics, research briefs, or plans the team already has. Update `summary.team_distribution` and `summary.total_files_classified` counters.

### 7. Actor File (swarm repo — if using operations/actors)

Create `operations/actors/<team-slug>.yaml` in the **swarm** repo:

```yaml
# <Team Name>
# <one-line description>
team:
  slug: <team-slug>
  name: <Team Name>
  leads_to: organisation-design-team
  escalation: human
```

### 8. Subject File (superseded — swarm Supabase SOR)

The eldato-era `operations/subjects/<team-slug>.yaml` YAML backup is **superseded** by the swarm Supabase SOR (`teams`/`roles` tables, migrations 00003-00005). The swarm repo keeps derived YAML mirrors at `operations/subjects/` for local reads — update those if you work from a swarm checkout, but the Supabase rows are canonical.

### 9. Label System (superseded)

`scripts/subjects-labels.cjs` was never vendored into agent-infra and is **superseded** by the swarm SOR (see #102). Team labels resolve from the `teams` table via `node scripts/swarm-org.mjs list-teams`.

## Verification

```bash
# Verify Supabase record exists (swarm SOR)
cd ~/Documents/GitHub/swarm && supabase db query "SELECT * FROM teams WHERE slug = '<team-slug>'"

# Verify via agent-infra helper
node scripts/swarm-org.mjs resolve-role <team-slug>
node scripts/swarm-org.mjs list-teams

# Verify GitHub label
gh label list --search "team:<team-slug>"
```

## Common Mistakes

| Symptom | Missed Surface |
|---------|---------------|
| Issues can't be tagged `team:X` | GitHub label (step 4) |
| Team slug not found by `swarm-org.mjs` | Supabase record (step 1) |
| Team docs not in classification system | Manifest batch (step 6) |
| Domain folders missing | Repo setup (step 2) |
| Cross-repo links missing | README template (step 2) |
---
> Continue following the workflow as mandated by this skill. Do not skip steps.
