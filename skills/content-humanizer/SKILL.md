---
allowed-tools: read write edit bash grep find web_search web_fetch todo_write task
name: content-humanizer
description: Naturalization pass that removes AI writing patterns from drafts BEFORE the reviewer cycle. Invoke after initial drafting, before reviewers. This is a preparation step — it doesn't produce final content, it prepares the draft for the quality gate.
domain: growth
---
> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

# Content Humanizer

Adapted from `blader/humanizer` v2.8.0 (MIT license). Strips AI writing patterns from El Dato content drafts while preserving our Voice DNA, partner mentions, deal embeds, and disclosure compliance. Runs as a sub-skill — invoked by orchestrators and writers, not directly by users.

**Voice DNA:** `docs/teams/eldato-app-team/domains (S1)/product/voice_dna.md` — the single source of truth for El Dato's editorial voice. This skill reads §4 (Calibration Sample) as permanent voice calibration. *(Lives in the **eldato** repo — fetch: `gh api repos/daniel-ospina/eldato/contents/<path> --jq .content | base64 -d`.)*

---

## Your Task

When given a content draft to humanize:

1. **Identify AI patterns** — scan for the 33 patterns below
2. **Rewrite, don't delete** — replace AI-isms with natural alternatives. Cover everything the original covers. If the original has five paragraphs, the rewrite has five paragraphs
3. **Preserve meaning** — keep core message intact. This includes ALL partner mentions, deal embeds (`<deal-embed deal-id="...">`), price facts, confidence annotations (✓/~/✗), and disclosure-compliant data
4. **Match our voice** — calibrate against the Voice DNA sample (see Calibration section below). El Dato's voice is: knowledgeable local friend, practical over promotional, specific over generic, sensory detail, resident perspective

The draft → audit → final loop and the deliverable are defined under Process and Output below.

---

## Calibration (Permanent)

This skill always calibrates against El Dato's Voice DNA. Read `docs/teams/eldato-app-team/domains (S1)/product/voice_dna.md` §4 (eldato repo) before humanizing. The calibration sample demonstrates:

- Short, punchy sentences mixed with longer flowing ones
- Specific locations (Constituyentes, Calle 12)
- Sensory details (habanero-heavy, hums with Spanish, clinking glasses)
- Practical tips (arrive early, call ahead, cash only)
- Prices in MXN with USD context
- No filler superlatives (see Voice DNA §2 for the full forbidden words list)
- Conversational register without being sloppy
- Unreserved recommendations grounded in specifics

**Additional El Dato constraints (beyond upstream humanizer):**

| Constraint | Source |
|---|---|
| No em dashes in final output (hard cut — upstream rule §14) | Blader §14 |
| No forbidden words: 8 ES + 11 EN (see Voice DNA §2) | `voice_dna.md` §2 |
| No dead phrases: "Descuentos para locales", "Exclusivo para residentes", etc. | `voice_dna.md` §2 |
| Never remove or alter `<deal-embed>` tags | `guide-content-writer` |
| Never remove or alter ✓/~/✗ confidence annotations | `editorial-content-writer` |
| Never expose gated data in public fields (exact hours, ID types, redemption steps) | Disclosure model |
| Never change prices, partner names, or factual claims from the research brief | All writers |
| Spanish content must remain native phrasing — do not "fix" into translated-from-English patterns | Voice DNA R6 |

---

## Personality and Soul

Avoiding AI patterns is only half the job. Sterile, voiceless writing is just as obvious as slop. Good writing has a human behind it.

**Apply only when the content calls for it** — El Dato editorial, guides, and deal copy should have a pulse. Business pages and deal descriptions lean more neutral but still need sentence variety.

### Signs of soulless writing (even if technically "clean"):
- Every sentence is the same length and structure
- No opinions, just neutral reporting
- No acknowledgment of uncertainty or mixed feelings
- Reads like a Wikipedia article or press release

### How to add voice:
**Have opinions.** React to facts — "vale la pena" is more human than neutrally listing features.
**Vary your rhythm.** Short punchy sentences. Then longer ones that take their time.
**Let some mess in.** Perfect structure feels algorithmic. Tangents, asides, and half-formed thoughts are human.

---

## Pattern Detection (33 Patterns)

### Content Patterns

**1. Undue Emphasis on Significance / Legacy / Broader Trends**
Words to watch: stands/serves as, is a testament/reminder, a vital/significant/crucial/pivotal/key role/moment, underscores/highlights its importance/significance, reflects broader, symbolizing, contributing to, setting the stage for, marking/shaping the, represents/marks a shift, key turning point, evolving landscape, focal point, indelible mark, deeply rooted

**2. Undue Emphasis on Notability and Media Coverage**
Words to watch: independent coverage, local/regional/national media outlets, written by a leading expert, active social media presence

**3. Superficial Analyses with -ing Endings**
Words to watch: highlighting/underscoring/emphasizing..., ensuring..., reflecting/symbolizing..., contributing to..., cultivating/fostering..., encompassing..., showcasing...

**4. Promotional and Advertisement-like Language**
Words to watch: boasts a, vibrant, rich (figurative), profound, enhancing its, showcasing, exemplifies, commitment to, natural beauty, nestled, in the heart of, groundbreaking (figurative), renowned, breathtaking, must-visit, stunning

**5. Vague Attributions and Weasel Words**
Words to watch: Industry reports, Observers have cited, Experts argue, Some critics argue, several sources/publications (when few cited)

**6. Outline-like "Challenges and Future Prospects" Sections**
Words to watch: Despite its... faces several challenges..., Despite these challenges, Challenges and Legacy, Future Outlook

### Language and Grammar Patterns

**7. Overused "AI Vocabulary" Words**
High-frequency AI words: Actually, additionally, align with, crucial, delve, emphasizing, enduring, enhance, fostering, garner, highlight (verb), interplay, intricate/intricacies, key (adjective), landscape (abstract noun), pivotal, showcase, tapestry (abstract noun), testament, underscore (verb), valuable, vibrant

**8. Avoidance of "is"/"are" (Copula Avoidance)**
Words to watch: serves as/stands as/marks/represents [a], boasts/features/offers [a]

**9. Negative Parallelisms and Tailing Negations**
Constructions like "Not only...but..." or "It's not just about..., it's...". Tailing negations: "no guessing", "no wasted motion" tacked onto sentence ends.

**10. Rule of Three Overuse**
Forcing ideas into groups of three to appear comprehensive.

**11. Elegant Variation (Synonym Cycling)**
AI repetition-penalty causing excessive synonym substitution.

**12. False Ranges**
"From X to Y" constructions where X and Y aren't on a meaningful scale.

**13. Passive Voice and Subjectless Fragments**
Hiding the actor or dropping the subject. Rewrite when active voice is clearer.

### Style Patterns

**14. Em Dashes and En Dashes — HARD CUT**
Final rewrite must contain NO em dashes (—) or en dashes (–). Replace with: period, comma, colon, parentheses, or restructure. Also catch spaced em dashes (` — `) and double hyphens (` -- `). Scan final output for `—` and `–` — any hit means the draft isn't done.

**15. Overuse of Boldface**
Mechanical emphasis. Convert to prose.

**16. Inline-Header Vertical Lists**
Items starting with bolded headers followed by colons. Convert to prose.

**17. Title Case in Headings**
Capitalizing all main words in headings → sentence case.

**18. Emojis**
Remove emoji decoration from text.

**19. Curly Quotation Marks**
Curly quotes (“...”) → straight quotes ("...").

**26. Hyphenated Word Pair Overuse**
Common word pairs uniformly hyphenated. Keep attributive hyphens (`a high-quality report`), drop predicate hyphens (`the report is high quality`).

**27. Persuasive Authority Tropes**
The real question is, at its core, in reality, what really matters, fundamentally, the deeper issue, the heart of the matter.

**28. Signposting and Announcements**
Let's dive in, let's explore, let's break this down, here's what you need to know, without further ado.

**29. Fragmented Headers**
A heading followed by a one-line paragraph that simply restates the heading.

**30. Diff-Anchored Writing**
Narrating a change rather than describing the thing as it is. Unless the content is a changelog.

**31. Manufactured Punchlines and Staccato Drama**
Stacking short declarative fragments to manufacture drama. A single short sentence for emphasis is fine; a run of them sounds engineered.

**32. Aphorism Formulas**
X is the Y of Z, X becomes a trap, X is not a tool but a mirror, the language of, the currency of, the architecture of.

**33. Conversational Rhetorical Openers**
Honestly?, Look, Here's the thing, The thing is, Let's be honest, Real talk — standalone hooks or fake-candid pauses before an ordinary point.

### Communication Patterns

**20. Collaborative Communication Artifacts**
I hope this helps, Of course!, Certainly!, You're absolutely right!, Would you like..., Want me to...?, Should I continue?, let me know, here is a...

**21. Knowledge-Cutoff Disclaimers and Speculative Gap-Filling**
as of [date], Up to my last training update, While specific details are limited/scarce..., based on available information, not publicly available, maintains a low profile, keeps personal details private, likely [grew up/studied/began], it is believed that.

**22. Sycophantic/Servile Tone**
Great question! You're absolutely right! That's an excellent point. Respond directly instead.

### Filler and Hedging

**23. Filler Phrases**
"In order to" → "To". "Due to the fact that" → "Because". "At this point in time" → "Now". "In the event that" → "If". "The system has the ability to" → "The system can". "It is important to note that the data shows" → "The data shows".

**24. Excessive Hedging**
Over-qualifying: "could potentially possibly be argued that the policy might have some effect" → "the policy may affect".

**25. Generic Positive Conclusions**
"The future looks bright." "Exciting times lie ahead." "This represents a major step." → Replace with specific plans or facts, or drop.

---

## Detection Guidance

### What NOT to flag (false positives)

- **Perfect grammar and consistent style.** Polish does not equal AI.
- **Mixed casual and formal registers.** This often signals a person in a technical field, not a chatbot.
- **"Bland" or "robotic" prose.** AI prose has *specific* tells. Generic dryness without those tells is just dry writing.
- **Common transition words in isolation.** *Additionally*, *moreover*, *consequently* are AI-coded only when piled up. One *however* is not a tell.
- **Curly quotes alone.** macOS, Word, and most CMSes auto-curl.
- **Em dashes alone.** Many editors use them. Em dashes are evidence only when paired with formulaic sales-y rhythm.
- **One short emphatic sentence.** Humans use clipped sentences. Flag staccato drama only when several short fragments stack up.

Look for **clusters** of tells, not isolated ones.

### Signs of human writing (preserve these)

- Specific, unusual, hard-to-fabricate detail. A real address. A weird quote.
- Mixed feelings and unresolved tension. "I think this is mostly good, but it bothers me."
- First-person editorial choices the writer can defend.
- Variety in sentence length. Real writing alternates short and long.
- Genuine asides, parentheticals, or self-corrections.

---

## Process and Output

1. **Read the calibration sample** from `docs/teams/eldato-app-team/domains (S1)/product/voice_dna.md` §4 — internalize the voice.
2. **Read the input draft carefully** — identify every instance of the 33 patterns above.
3. **Write a draft rewrite.** Check that it: reads naturally aloud, varies sentence length, prefers specific details and simple constructions (is/are/has), keeps the appropriate register, matches our Voice DNA.
4. **Audit:** ask "What makes this still obviously AI generated?" List remaining tells.
5. **Revise into a final rewrite** that addresses them and contains no em or en dashes (§14).
6. **Preservation check:** verify all partner mentions, deal embeds, prices, confidence annotations, and disclosure-compliant data are intact and unchanged.
7. **Output:** the humanized content in the same format it was received (same fields, same structure).

---

## Input Contract

The skill receives a content draft from the orchestrator or writer:

```
{
  "draft": {
    // editorial: { intro, body, faqs, meta_title, meta_description }
    // guide: { body, faqs, meta_title, meta_description }
    // deal: { title, title_es, seo_meta_title, seo_meta_title_es, seo_meta_description, seo_meta_description_es, seo_faq_json, description, description_es, how_to_book, how_to_book_es }
    // business: { intro, body, faqs, meta_title, meta_description }
  },
  "page_type": "editorial" | "guide" | "deal" | "business" | "refresh" | "carousel-b2b",
  "language": "es" | "en"
}
```

## Output Contract

The same structure as input, with all text fields humanized. Facts, embeds, annotations, and disclosure compliance unchanged.

---

## Reference

- `blader/humanizer` v2.8.0 — https://github.com/blader/humanizer (MIT license)
- Wikipedia: Signs of AI writing — https://en.wikipedia.org/wiki/Wikipedia:Signs_of_AI_writing
- El Dato Voice DNA — `docs/teams/eldato-app-team/domains (S1)/product/voice_dna.md`
- El Dato Brand Messaging — `docs/teams/eldato-app-team/domains (S1)/growth/brand-messaging.md`
---
> Continue following the workflow as mandated by this skill. Do not skip steps.
