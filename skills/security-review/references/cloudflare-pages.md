# Cloudflare Pages SSR Security Patterns

## Environment Variables

**Use context.env, NOT process.env:**

In Cloudflare Pages `functions/` directory, environment variables are accessed via the request context:

```typescript
// WRONG: process.env doesn't exist in CF Workers runtime
const url = process.env.SUPABASE_URL;

// CORRECT: use context.env
export async function onRequest(context) {
  const url = context.env.SUPABASE_URL;
}
```

**Never hardcode fallback URLs:**

```typescript
// VULNERABLE: falls back to a URL if env var missing
const SITE_URL = context.env.SITE_URL || 'https://example.com';

// CORRECT: use helper that validates
import { getSiteUrl } from './_constants';
const SITE_URL = getSiteUrl(context.env);
```

## Routing Security

**_routes.json misconfiguration:**

`functions/_routes.json` controls which paths hit SSR functions vs static assets. Misconfiguration can:
- Expose raw HTML without SSR-injected OG tags (SEO impact)
- Bypass server-side auth checks
- Serve stale static content instead of dynamic responses

**Shared modules with _ prefix:**

Files prefixed with `_` in `functions/` are excluded from routing. Use this for shared modules:
- `functions/_crawlers.ts` — bot detection list
- `functions/_env.ts` — SSREnv type definition
- `functions/_constants.ts` — shared helpers

## SSR Response Security

**Never include sensitive data in SSR responses:**

SSR functions serve HTML to crawlers and users. Never include:
- API keys or tokens in HTML source
- User-specific data in crawler responses
- Database connection strings

**Bot detection pattern:**

```typescript
import { CRAWLERS } from './_crawlers';

const userAgent = request.headers.get('user-agent') || '';
const isBot = CRAWLERS.some(bot => userAgent.includes(bot));

if (isBot) {
  // Return minimal HTML with OG meta tags only
  return new Response(botHtml, { headers: { 'content-type': 'text/html' } });
}
// Return full SPA for real users
```
