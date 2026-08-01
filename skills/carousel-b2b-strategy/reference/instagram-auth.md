# Instagram Auth Reference

Operational patterns for Instagram Graph API authentication. Read before debugging posting failures.

## Business Manager Linking

**Problem:** `/me/accounts` returns empty or missing Instagram account. Token has correct scopes but can't access the account.

**Solution:** Instagram accounts must be linked to Facebook Pages under the same Business Manager. If the account isn't linked, create a Facebook Page, link the IG account (Instagram app → Edit Profile → Page), and re-authorize the token via OAuth redirect.

**Concrete example (eldato.b2b, #4647):** The `eldato.b2b` account returned empty `/me/accounts` despite having correct scopes. Root cause: no Facebook Page was linked to the Instagram account under the same Business Manager. Fix: created "El Dato B2B" Facebook Page, linked it to the IG account, then re-authorized the token. Without this Page link, the token has no surface to publish on — even with all scopes granted.

## OAuth Re-Authorization Sequence

**Problem:** Token expired or doesn't include newly linked accounts.

**Solution:** Full re-authorization flow: navigate to `https://www.facebook.com/v21.0/dialog/oauth` with scopes (`instagram_basic,instagram_content_publish,pages_read_engagement,pages_show_list,business_management`), redirect to Explorer callback. Click through: Pages (Continue) → Businesses (Continue) → Instagram accounts (select + Continue) → Save. Any missing step = token without access.

## Token Types

**Problem:** Using wrong token type for content publishing.

**Solution:** Facebook Graph API tokens (starts with `EAA`) for content publishing. Instagram Login API tokens (starts with `IGAA`) don't work for posting — they're for the Instagram Basic Display API. Generate Graph API tokens via OAuth redirect, never via the Instagram API Setup page "Generate token" buttons.

## Browser Fragility

**Problem:** Agent-browser session killed mid-OAuth, forcing re-login. Explorer reconnect dialog creates infinite loops.

**Solution:** Never close agent-browser during multi-step OAuth. Use direct OAuth URLs (`dialog/oauth`) instead of the Graph API Explorer UI — the Explorer's reconnect dialog loops indefinitely with certain app configurations.

## Consumers

- `scripts/ig-post.ts`
- `scripts/ig-post-carousel.ts`
