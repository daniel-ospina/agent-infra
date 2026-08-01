# Component Schema Reference

## PitchComponent Interface

```typescript
interface PitchComponent {
  slug: string;              // unique identifier (snake_case)
  content_es: string;        // Spanish (primary)
  content_en: string;        // English
  type: PitchComponentType;  // one of 10 types
  tags: PitchTag[];          // phase/context matching
  target_personas: Persona[];// which personas this applies to (empty = universal)
  version: number;           // increment on each regeneration
  is_active: boolean;        // false to soft-delete without removing
  confidence: Confidence;    // hypothesis lifecycle — manually promoted by user
}
```

## Confidence Lifecycle

```typescript
type Confidence = 'hypothesis' | 'promising' | 'validated' | 'retiring';
```

| Level | Meaning | Transition |
|-------|---------|------------|
| `hypothesis` | New/untested component (default for all generated) | → `promising` (user observes positive signals) |
| `promising` | Positive signals in conversations, not enough volume | → `validated` (consistent performance) or → `retiring` (doesn't land) |
| `validated` | Consistently performs well, keep unless strategy changes | → `retiring` (strategy shifts) |
| `retiring` | Phasing out, `is_active: false`, preserved in file | — (end state) |

**Deletion policy:** Never hard-delete. Set `confidence: 'retiring'` and `is_active: false`. Explicit user confirmation required before retiring any component.

## Component Types (10)

`data_point` | `description` | `differentiator` | `counter_argument` | `USP` | `benefit` | `context` | `roadmap` | `business_model` | `faq`

## Tags (9)

`warmup_compatible` | `transition_compatible` | `objection_operational` | `objection_corporate` | `anti_discount_pivot` | `business_model` | `objection_in_person` | `close_compatible` | `discovery_compatible`

## Personas

Read dynamically from `strategy.md` §7.3 — do not hardcode. Reference set (may change with strategy): `owner`, `general_manager`, `marketing_manager`, `pr_social`, `receptionist`

## Manifest Structure

```json
{
  "generated_at": "ISO timestamp",
  "strategy_version": "git SHA of strategy.md at generation time",
  "section_hashes": {
    "§3_jtbd": "sha256 of §3 content",
    "§4_competition": "sha256 of §4 content",
    "§5_value_prop": "sha256 of §5 content",
    "§6_differentiators": "sha256 of §6 content",
    "§7_pitch_derivation": "sha256 of §7 content"
  },
  "components": [
    {
      "slug": "...",
      "type": "data_point",
      "strategy_source": "§5.1",
      "generated_at": "ISO timestamp",
      "review_status": "approved",
      "confidence": "hypothesis",
      "promoted_at": null,
      "demoted_at": null
    }
  ]
}
```
