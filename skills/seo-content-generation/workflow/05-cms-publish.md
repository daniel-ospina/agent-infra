# Step 6 — CMS ingest, meta generation, and the keyword-wiring check

**Produces:** a CMS draft row with correct SEO fields.
**Owner:** agent. **Gate:** auto, then **human gate 2** (step 7 — the owner publishes).

## ⛔ A write is unrecoverable — and the agent cannot read the row

**The CMS has no GET path and no revision history** (`tortoise#8002`). A write is unrecoverable: the
previous body is gone with no way to diff or restore it — and that is not hypothetical, it is the
incident `tortoise#8002` records.

Before any write:

1. `POST` the post. A `409 slug_conflict` response means a post already owns that slug — **stop**.
2. **The agent cannot read a draft row.** There is no agent GET path (`tortoise#8002`), so the agent
   has no way to see what a PATCH would destroy. The 409 body carries no `id` either, so the agent
   cannot even construct the editor URL. On a 409, **do not PATCH**: give the owner the **slug** and
   ask them to find it in the admin post list, read it, and say whether the new body should replace
   it — or whether to create a **new draft** under a new slug. **Only PATCH after the owner confirms
   they have read the existing row**; their read is the guard, because the agent has none.
3. **PATCH also requires ownership.** The API returns `403 forbidden` unless the row's `created_by`
   is *this agent's* name — so a post the owner created in the editor is not editable by the agent.
   A 403 means exactly that: create a **new draft** under a new slug rather than retrying.
   **Never set `status: published` yourself** — the API accepts it, but the owner publishes at gate 2.

## The CMS surface

| | |
|---|---|
| Blog origin | `https://tortoise.premiselabs.co/blog` |
| Posts API | `https://tortoise.premiselabs.co/blog/api/posts` |
| Admin editor | `https://app.premiselabs.co/admin/#/edit/<post-id>` |
| Auth | `X-Agent-Key: $BLOG_AGENT_KEY` — sha256-compared against `blog_agent_keys` |
| Key location | `BLOG_AGENT_KEY` in the **tortoise** repo `.env` |

Announce the secret access before reading `.env`, and never print the key. **Reading `.env` with the
`read` tool does not export anything** — load the key into the shell explicitly, or the header goes
out empty and the API answers `401`:

```bash
BASE="https://tortoise.premiselabs.co"
# load from .env without echoing it (never print the key)
export BLOG_AGENT_KEY="$(grep -m1 '^BLOG_AGENT_KEY=' /Users/danielospina/Documents/GitHub/tortoise/.env | cut -d= -f2-)"

# create (409 slug_conflict if it exists — that is information, not an error)
curl -sS -X POST "$BASE/blog/api/posts" \
  -H "X-Agent-Key: $BLOG_AGENT_KEY" -H "Content-Type: application/json" \
  -d @post.json

# update an existing post
curl -sS -X PATCH "$BASE/blog/api/posts/<slug>" \
  -H "X-Agent-Key: $BLOG_AGENT_KEY" -H "Content-Type: application/json" \
  -d @post.json
```

## Meta title / description

The blog's automated SEO generator is `POST /blog/api/generate-seo { title, body, tags? }` →
`{ slug, excerpt, tags, meta_title, meta_description }`. It is **admin-gated** (PKCE session, not the
agent key), so **the owner triggers it in the editor — that is the intended path**, and the one the
owner's step 6 describes.

> ⛔ **The keyword injection happens ONLY inside the generator.** `keywordsFor`/`TAG_KEYWORDS` have
> exactly one consumer in the codebase (`website/functions/blog/api/generate-seo.ts:20,65-66`); the
> posts API length-checks `meta_title`/`meta_description` and does nothing else with them
> (`api/posts/[[path]].ts:162-163`, `:261`, `:265`). So if the agent writes the meta fields itself,
> **no injection happens** — and the tag check below still passes, because it inspects tags only. That
> is the exact failure this section exists to prevent: a clean-looking post whose meta carries none of
> our keywords.
>
> **Prefer the generator.** If it genuinely cannot be run, the agent must lift the post's
> `keywordsFor(tag)` terms out of `TAG_KEYWORDS` **into the `meta_title`/`meta_description` it writes**,
> and say that it did — the tag check alone does **not** establish that the keywords reached the meta.

Either way the agent's job is the **wiring check** below, because that is the part that silently fails.

## ⛔ The keyword-wiring check — the step that silently does nothing

The generator injects our keywords from `website/functions/blog/_shared/seo-keywords.ts`:

```ts
keywordsFor(tag) → TAG_KEYWORDS[tag] ?? []      // [] for any tag not in the map
```

**The keyword set is keyed on the post's TAGS.** A tag outside the taxonomy returns `[]` for that tag,
and when every tag misses, the generator **falls back to content-derived keywords** — the post
publishes with plausible-but-generic SEO text and *no signal that anything is wrong*.

**The canonical 12-tag taxonomy** — a post's tag set must be a subset of these:

```text
agent-memory · epistemic-memory · knowledge-graph · semantic-memory · episodic-memory · mcp
self-hosting · retrieval · belief-propagation · sessions · memory-systems · provenance
```

Verify with a command, not by eye:

```bash
# the taxonomy, from the source of truth
rg -n '^  "[a-z-]+":' website/functions/blog/_shared/seo-keywords.ts

# then diff it against the tags you are about to send
```

> ⛔ **Check the tags that will SHIP, not the ones you typed.** On the owner-triggered path the editor
> **overwrites the tags field with the generator's output**
> (`website/apps/blog-admin/src/pages/PostEditor.tsx:371`) — and nothing restricts that output to the
> 12 tags: the generator explicitly allows "Free-form tags" (`api/generate-seo.ts:82`), and
> `constraints.tags()` (`_shared/seo-constraints.ts`) has **zero** taxonomy coupling — it only
> normalises case and dashes. So a post can ship with off-taxonomy tags while the payload you checked
> was clean, and you cannot re-read it afterwards (no GET — `tortoise#8002`).
>
> **What the injection actually keys off:** `injectKeywords` (`api/generate-seo.ts:59-74`) reads the
> tags **in the request**, not the stored row. So on the path this file calls preferred — the owner
> clicking **Generate SEO fields** while the tags field still holds your clean taxonomy tags — the
> injection **succeeds**; the generator then writes its own tags back, which is harmless by itself. It
> degrades to content-derived keywords only on a **later** run, whose input is the tags the earlier
> run wrote back. The risk is the **second** run, not the first.
>
> **So:** have the owner run the generator **once**, while your tags are in the field — and if they run
> it again, ask them to read the tag field back to you and re-check it.
>
> ⚠️ Both **"Generate SEO fields"** and **"Generate with AI"** call the generator and both overwrite
> the tags field (`website/apps/blog-admin/src/pages/PostEditor.tsx:371` and `:396`).

If the article's natural tag is not in the taxonomy (e.g. `memory-layer`, `comparison`), **do not
invent it** — pick the nearest taxonomy tag. Adding a tag to the taxonomy is a code change in
`website/functions/blog/_shared/seo-keywords.ts`, not a content decision — and **nothing typechecks
that file** (its only importer is a Cloudflare Pages Function, which esbuild bundles with types
stripped, and no test imports it), so the `TagName` key type does **not** catch a typo for you. The
`rg` check above is the only thing that will.

## Field limits — the API rejects, it does not truncate

| Field | Limit | Note |
|---|---|---|
| `title` | **200** | **required** — `"title required, max 200 chars"` |
| `body` | **100,000** chars | rejects with **422**, not 400 — as does an unbalanced code fence; also required when `status=published` |
| `meta_title` | **60** | the final search-result title, suffix included. The **generator** appends `" \| Tortoise"` when it fits in 60; **SSR renders a stored `meta_title` verbatim**, and falls back to `"<title> \| Tortoise"` only when it is **null/omitted** (the check is `??`, not truthiness). An **empty string is stored and renders an empty `<title>`** — so **omit the field, never send `""`**. A hand-written value must carry the suffix itself if you want it. |
| `meta_description` | **155** | |
| `excerpt` | **300** | |
| tags | **≤10**, each **≤40** chars | |
| `slug` | **100** | lowercase alphanumeric-dash |

An over-length field returns a validation error on the field — it is not silently truncated. Fix it in
the payload, do not re-send.

## Done when

- The CMS row exists — **201 on create, 200 on update** (the create path returns 201, not 200).
- The tags **sent in the create/PATCH payload** are a **subset of the 12-tag taxonomy** — verified
  against `seo-keywords.ts`, not assumed. The **stored** tags may be the generator's free-form output;
  that is harmless provided the generator is not run a **second** time (see the ⛔ above).
- `meta_title` ≤60, `meta_description` ≤155, `excerpt` ≤300, ≤10 tags.
- The editor URL for the draft has been given to the owner.

## Then: human gate 2 (step 7)

**The owner reviews the preview in the editor and publishes.** The agent does not publish, does not
flip status, and does not set a publish date. Hand over the editor URL and stop.
