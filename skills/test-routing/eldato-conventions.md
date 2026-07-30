> ⚠️ **El Dato-specific.** This file only applies to the El Dato repo. When deploying this skill to another repo, create a `repo-conventions.md` file instead. See `repo-conventions.md` for the template.

# Eldato Conventions — test-routing

Maps universal patterns in `SKILL.md` to concrete eldato tooling.

## Pipeline Integration
- **Invoked by:** `writing-plans` Step 3.5, `code-review` Step 0
- **Complexity ratings source:** Issue body fractal fields (UX/Architecture/Ontology/Accessibility)
- **Surface map source:** `test-design` skill output

## Tool Mapping
| Universal Reference | Eldato Concrete |
|---|---|
| "your code test tool" | Vitest |
| "your e2e tool" | Playwright |
| "your DB tool" | Supabase |
| "your component library" | `docs/teams/eldato-app-team/ux/component_catalog.md` |

## Deferred Domains
- content → `content-strategy-agent` (#6053)
- config → `config-validation` (#6053)
- research → `research` skill adversarial review (#6053)
