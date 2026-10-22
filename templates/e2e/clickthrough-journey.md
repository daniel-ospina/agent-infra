# Clickthrough Journey Protocol

Template for describing a user journey the agent walks during post-deploy verification.
Used when Tortoise graph doesn't yet have journey data. The agent reads this and walks it with common sense — not deterministic selectors.

## Journey: <Name>

**Goal:** <What outcome the user achieves>
**Start URL:** <deploy URL or relative path>
**Auth required:** yes | no | magic-link

### Steps

| # | Action | Expected Outcome | Screenshot |
|---|--------|-----------------|------------|
| 1 | Navigate to homepage | Page loads, key elements visible | step1-homepage.png |
| 2 | Click the main CTA button (e.g., "Ver ofertas", "Sign up") | Next page/section loads | step2-after-cta.png |
| 3 | Fill in any required form (use common sense for field labels) | Form accepts input, no validation errors | step3-form-filled.png |
| 4 | Submit the form / complete the action | Success message or expected state | step4-success.png |
| 5 | Verify the outcome (e.g., deal reserved, account created) | Expected result visible on screen | step5-outcome.png |

### Edge Cases

| Scenario | Expected Behavior |
|----------|------------------|
| Empty state (no deals, no results) | Show empty state message, no crash |
| Invalid input (bad email, empty required field) | Show validation error, don't submit |
| Network error (navigate to bad URL) | Show error state, app doesn't crash |

### Notes for Agent

- Use `page.getByRole()` and text content to find elements — not CSS classes
- Screenshot EVERY step (pass or fail)
- Use the `read` tool to visually verify screenshots
- If stuck for >10s on a step, screenshot and mark as FAIL
- Walk edge cases after happy path
