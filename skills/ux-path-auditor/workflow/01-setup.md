> **Step 1/5** | → next: workflow/02-walk-journeys.md

# Setup: Load Path Map, Initialize, Auth

## Inputs

You will receive these parameters when invoked. Apply defaults when absent:

| Parameter | Type | Required | Description |
|---|---|---|---|
| `path_map` | string | yes | Absolute or repo-relative path to `path-map.json` produced by `ux-path-mapper` |
| `output_dir` | string | yes | Directory path to write `audit-report.json` |

The `output_dir` is always an absolute path or repo-relative to `/Users/home/eldato/`. Pre-created by the `ux-qa` orchestrator. If standalone, create it manually: `mkdir -p {output_dir}`.

## App Reference

- **Base URL:** `http://localhost:8080`
- **Auth:** email+password login form at `/acceso`
- **Test credentials:** Read from `UX_QA_EMAIL` and `UX_QA_PASSWORD` env vars. If these are not set and the path map includes auth-state nodes, halt immediately:

```
BLOCKED: UX_QA_EMAIL and UX_QA_PASSWORD environment variables are not set.
Configure them before invoking this skill with auth-state journeys.
```

## Playwright MCP Tool Reference

| Tool | Purpose |
|---|---|
| `browser_navigate` | Navigate to a URL |
| `browser_snapshot` | Accessibility tree snapshot (primary evidence source — use for DOM inspection and element extraction) |
| `browser_click` | Click an element by accessibility selector |
| `browser_fill_form` | Fill form fields (used for auth setup) |
| `browser_console_messages` | Read browser console log — collect errors and warnings |
| `browser_network_requests` | Read network request/response log — check for 4xx/5xx |
| `browser_wait_for` | Wait for a condition (element visible, URL change, network idle) |
| `browser_resize` | Resize viewport |
| `browser_evaluate` | Execute JavaScript in page context |
| `browser_take_screenshot` | Capture screenshot (debugging only — `browser_snapshot` is primary) |
| `browser_press_key` | Send keyboard input |

---

## Step 0: Initialization

1. Read and parse `path-map.json` from the `path_map` path.
2. Validate that it contains `nodes`, `edges`, and `journeys` arrays. If any are missing or the file cannot be parsed, halt with:

   ```
   BLOCKED: path-map.json at {path} is missing required fields: {list}. Re-run ux-path-mapper first.
   ```

3. Initialize working state:
   ```
   findings_raw = []           # all findings before deduplication
   finding_counter = 1         # for raw ID assignment during collection
   current_auth_state = null   # tracks which auth state browser is currently in
   ```
4. If `UX_QA_EMAIL` / `UX_QA_PASSWORD` are not set and any journey step requires `auth` state, halt with the BLOCKED message from the Inputs section.

5. Announce:

   ```
   Starting UX path audit — {N} journeys, {N} nodes, {N} screens to walk
   ```

---

## Step 1: Auth State Setup

Track `current_auth_state` to avoid redundant login/logout operations.

### Set to `"unauth"`:

1. Clear session via `browser_evaluate`:
   ```javascript
   localStorage.clear(); sessionStorage.clear();
   ```
2. Navigate to `http://localhost:8080/` using `browser_navigate`.
3. Take `browser_snapshot` and confirm no session indicators are visible (avatar, "Mi Cuenta", business name).
4. Set `current_auth_state = "unauth"`.

### Set to `"auth"`:

1. Navigate to `http://localhost:8080/acceso` using `browser_navigate`.
2. Wait for the login form using `browser_wait_for`.
3. Fill the form using `browser_fill_form` with `UX_QA_EMAIL` and `UX_QA_PASSWORD`.
4. Click submit using `browser_click`.
5. Wait for navigation away from `/acceso` using `browser_wait_for`.
6. Take `browser_snapshot` and confirm session is active (look for user avatar, "Mi Cuenta", or business name).
7. If login fails: log `WARN: auth login failed — auth-state steps will be skipped` and skip all steps requiring auth. Set `current_auth_state = "auth-failed"`.
8. Set `current_auth_state = "auth"`.
