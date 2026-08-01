> **Step 3/5** | ← requires: workflow/02-walk-journeys.md | → next: workflow/04-mobile-checks.md

# Desktop Audit Checklist (1280px)

Set viewport to 1280×800 using `browser_resize` before starting (or confirm it is already set).

For each check below, perform the investigation. If the check fails, record a finding immediately using the schema in [Recording a Finding](#recording-a-finding). If the check passes, move to the next check.

---

## Audit Checklist

| Check ID | What to look for | Severity |
|---|---|---|
| `dead-end` | No clear next action and no way back — user is stuck with no CTA and no back-navigation affordance | `high` if `journey.id` does not contain `admin` or `debug`; `medium` otherwise |
| `broken-nav` | Page shows a 404, a hard JS crash (blank page with console errors), or a spinner that never resolves after 5 seconds | `high` |
| `copy-inconsistency` | Mixed Spanish/English content on the same screen, inconsistent button labels for equivalent actions (e.g. "Save" vs "Guardar" for same action in two places), or visible placeholder/lorem text | `medium` |
| `missing-empty-state` | An API call returned an empty collection (visible from network log or DOM showing a list container with no items) but there is no empty-state message, illustration, or CTA explaining what to do next | `medium` |
| `form-validation-gap` | A form's required fields are submittable while empty — test by attempting to submit the form without filling required fields using `browser_click` on the submit button; if no validation error appears, this check fails | `high` |
| `mobile-overflow` | (NOTE: checked in Step 4, not here.) | `medium` |
| `auth-signal-missing` | A page renders in a broken, empty, or degraded state but gives no visible signal that the user needs to log in — the user cannot tell whether the problem is a bug or a login requirement | `high` |
| `aria-label-missing` | An interactive element (button, link, icon-only control, input) lacks a visible label and has no `aria-label` or `aria-labelledby` | `medium` |
| `loading-state-missing` | An async action (form submit, navigation, data fetch) completes with no loading indicator — the user has no feedback that something is happening | `low` |
| `error-recovery-missing` | An error state is displayed (network error, validation error, empty result set framed as an error) but no recovery action is offered (no retry button, no back link, no alternative path) | `high` |

---

## Detailed Check Procedures

### `dead-end`
- Take `browser_snapshot`. Look for: at least one CTA button or prominent action link, AND at least one back-navigation affordance (breadcrumb, "back" link, nav menu, or the page is the app root).
- Fail condition: no CTA AND no navigation path is visible. Also fails if the only visible element is an error message with no recovery link.
- Severity: `high` if the finding occurs on a journey that is not explicitly an admin or debug journey (i.e., `journey.id` does not contain `admin` or `debug`). Default to `high` for all standard consumer-facing journeys.

### `broken-nav`
- Check `browser_console_messages` for JS errors. Check `browser_network_requests` for 4xx/5xx on the main document or critical API calls. Take `browser_snapshot` and check if the page is blank or shows only an error boundary.
- Wait up to 5 seconds using `browser_wait_for` if the page appears to still be loading. If it still shows a spinner after 5 seconds, this check fails.
- Fail condition: JS error causing blank page, hard crash, HTTP 404/500 on the main document, or unresolved spinner after 5 seconds.
- Severity: `high`.

### `copy-inconsistency`
- Take `browser_snapshot`. Scan all visible text nodes for English words mixed into Spanish content. Look for equivalent actions labeled differently (e.g. two "save" buttons using different words). Look for placeholder text (`Lorem`, `TODO`, `...`).
- Fail condition: mixed-language content on the same screen, inconsistent labels for equivalent actions, or visible placeholder text.
- Severity: `medium`.

### `missing-empty-state`
- Check `browser_network_requests` for API responses. If any list or collection endpoint returned a 200 with an empty array, take `browser_snapshot` and check whether the UI shows an empty-state message.
- Also check the DOM for list containers (`ul`, `ol`, grid containers, card containers) with zero children that show no fallback content.
- Fail condition: list API returned empty data AND no empty-state UI is rendered.
- Severity: `medium`.

### `form-validation-gap`
- Take `browser_snapshot`. Identify any forms on the page. For each form found:
  - Attempt to submit without filling any fields: use `browser_click` on the submit button.
  - Wait briefly using `browser_wait_for` for a validation error to appear.
  - Take a second `browser_snapshot` and check for visible validation messages (red text, error icons, field outlines, or HTML5 validation popups).
  - Fail condition: form submitted (page navigated or success message shown) without displaying validation errors, or form reset without error message.
- If no forms are present on this screen, mark as N/A (skip — do not record a finding).
- Severity: `high`.

### `auth-signal-missing`
- Take `browser_snapshot`. If `current_auth_state` is `unauth` and the screen appears empty, broken, or shows only a spinner:
  - Check whether any visible text indicates a login is required (e.g. "Inicia sesión para ver esto", lock icon, redirect message).
  - Fail condition: screen appears degraded/empty/broken AND no login prompt or signal is visible.
- If `current_auth_state` is `auth`, skip this check.
- Severity: `high`.

### `aria-label-missing`
- Take `browser_snapshot`. In the accessibility tree, identify all interactive elements: buttons, links, and inputs. For each:
  - Check whether the element has a visible text label OR an `aria-label` OR an `aria-labelledby` reference.
  - Icon-only buttons (buttons with no text, only an SVG or image) that lack an aria-label are a definitive fail.
- Fail condition: one or more interactive elements have no accessible name.
- Severity: `medium`.

### `loading-state-missing`
- This check applies only to screens with forms or async-triggering buttons. If neither is present, skip.
- For forms: fill required fields with placeholder valid data (e.g. `test@test.com` for email fields, `"test"` for text fields), click submit, then immediately check within 500ms for a loading indicator (spinner, disabled button, "cargando..." text) using `browser_wait_for` with a short timeout. Navigate back after the check.
- For CTAs/buttons that trigger async operations (e.g. "Guardar", "Reservar"): click and check within 500ms for a loading indicator. If navigation occurred, navigate back before continuing.
- For data-fetching: check `browser_network_requests` — if a fetch is in flight and the UI shows no loading indicator (nothing in DOM matches spinner/skeleton/loading patterns), this check fails.
- Fail condition: async action with no loading indicator.
- Severity: `low`.

### `error-recovery-missing`
- Take `browser_snapshot`. Look for any error state UI: error boundaries, error messages, "no results" states framed as errors, network error toasts. For each error state found:
  - Check whether there is a recovery action: retry button, back link, or alternative path CTA.
  - Fail condition: error state visible with no recovery affordance.
- Also check `browser_console_messages` for caught errors that resulted in an error UI.
- Severity: `high`.

---

## Evidence to Capture Per Finding

For every failing check, record all of the following:

- **`dom_excerpt`**: The outer HTML of the most relevant element from `browser_snapshot`. For dead-ends: the full list of CTAs (or absence thereof). For form gaps: the form element. For copy issues: the inconsistent text nodes. Keep excerpts under 500 characters; truncate with `...` if longer.
- **`console_errors`**: All entries from `browser_console_messages` at the time of the finding (empty array if none).
- **`network_failures`**: All 4xx and 5xx responses from `browser_network_requests` at the time of the finding (empty array if none).
- **`viewport`**: `"1280px"` if found at this viewport.

---

## Classification Hints

After capturing evidence, assign a `classification_hint` to each finding:

| Signal present | Hint |
|---|---|
| JS console error, network 4xx/5xx, form submit logic failure, component receives data but renders nothing | `tech` |
| Copy mismatch, missing label, layout overflow, hierarchy problem, missing navigation element, missing empty/loading state design | `ux` |
| Auth-gated content without signal (could be a missing route guard OR a missing design element) | `ambiguous` |
| Any other case where the root cause is unclear without deeper code inspection | `ambiguous` |

When in doubt, use `ambiguous`. It is cheaper to flag for human triage than to silently misclassify.

---

## Recording a Finding

When a check fails, record this structure immediately (before moving to the next check):

```json
{
  "id": "F{NNN}",
  "journey": "journey-id",
  "step": 2,
  "screen": "node-id",
  "route": "/path",
  "check": "check-id",
  "severity": "high | medium | low",
  "description": "One sentence describing what the problem is and where it was observed",
  "evidence": {
    "dom_excerpt": "Outer HTML of the most relevant element, under 500 chars",
    "console_errors": [],
    "network_failures": [],
    "viewport": "1280px"
  },
  "occurrences": ["node-id"],
  "classification_hint": "ux | tech | ambiguous"
}
```

Assign the next sequential raw ID (F001, F002, ...) at record time. `occurrences` starts as a single-element array containing the current `screen` node ID.

---

After all 10 desktop checks complete for this screen, → **return to workflow/02-walk-journeys.md** to proceed to mobile checks (Step 2h).
