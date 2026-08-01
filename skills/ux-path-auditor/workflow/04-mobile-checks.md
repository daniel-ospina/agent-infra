> **Step 4/5** | ← requires: workflow/03-desktop-checks.md | → next: workflow/02-walk-journeys.md (return to loop) or workflow/05-output.md (when all journeys done)

# Mobile Audit Checklist (375px)

After completing the desktop checklist, run `browser_resize` to set viewport to 375×812.

Re-run only these three checks using the same investigation logic as in [workflow/03-desktop-checks.md](./03-desktop-checks.md), but with `viewport: "375px"` in the evidence for any findings. Use the same [Recording a Finding](./03-desktop-checks.md#recording-a-finding) schema from Step 3.

---

## Mobile-Only Checks

### 1. `mobile-overflow`

Take `browser_snapshot`. Use `browser_evaluate` to detect elements that overflow the viewport horizontally:

```javascript
Array.from(document.querySelectorAll('*'))
  .filter(el => el.getBoundingClientRect().right > window.innerWidth)
  .map(el => ({ tag: el.tagName, class: el.className.toString().slice(0, 80), right: Math.round(el.getBoundingClientRect().right) }))
  .slice(0, 10)
```

Fail condition: one or more elements extend beyond the 375px viewport width.

Severity: `medium`.

### 2. `dead-end` (re-check)

Re-run the dead-end check at 375px. A screen that has CTAs on desktop may lose them on mobile due to overflow or z-index stacking.

Use the same severity rule as desktop: `high` unless `journey.id` contains `admin` or `debug`.

### 3. `auth-signal-missing` (re-check)

Re-run the auth-signal check at 375px. Auth prompts may be hidden on small viewports.

Skip if `current_auth_state` is `auth` — there is no auth prompt to check for.

Severity: `high`.

---

## After Mobile Checks

If `browser_evaluate` throws during the overflow check: log `WARN: overflow check failed at {route} — JS evaluate error` and skip `mobile-overflow` for this screen.

Resize back to 1280×800 before returning.

→ **Return to workflow/02-walk-journeys.md** for the next journey step (Step 2i), or proceed to workflow/05-output.md when all journeys are complete.
