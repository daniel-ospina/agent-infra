> **Step 2/5** | ← requires: workflow/01-setup.md | → next: workflow/03-desktop-checks.md

# Walk Each Journey

For each journey in `path-map.json` `journeys` array, iterate in order.

## Per-Journey Loop

1. Log: `Auditing journey: {journey.label} ({journey.id}) — {N} steps`

2. For each step index `i` and node ID in `journey.steps`:

   **a. Node Lookup**
   Look up the node object in `nodes` by matching `id`. If not found, log `WARN: node {id} not in path map — skipping step` and continue to the next step.

   **b. Auth State Resolution**
   Resolve the required auth state from `node.auth`.

   **c. Auth State Sync**
   If `current_auth_state != node.auth` (and `current_auth_state != "auth-failed"`): return to Step 1 (workflow/01-setup.md) for the required auth state.

   **d. Auth-Failed Skip**
   If `current_auth_state == "auth-failed"` and `node.auth == "auth"`: skip this step, log `WARN: skipping auth step {node.id} — login failed`.

   **e. Navigate**
   Navigate to `http://localhost:8080{node.route}` using `browser_navigate`.

   **f. Settle**
   Wait for page to settle using `browser_wait_for` (network idle or landmark element visible).

   **g. Desktop Audit**
   Run the full audit checklist at 1280px viewport. → **Proceed to workflow/03-desktop-checks.md.**

   **h. Mobile Audit**
   Resize to 375×812 and re-run mobile checks. → **Proceed to workflow/04-mobile-checks.md.**

   **i. Reset Viewport**
   Resize back to 1280×800 before the next step.

## After All Journeys

All findings have been collected in `findings_raw`. → **Proceed to workflow/05-output.md** for deduplication and report writing.
