---
name: ux-path-mapper
description: "Crawls the live El Dato app via Playwright MCP browser tools, exploring routes across auth states, and produces a structured path-map.json documenting all nodes, edges, and user journey flows"
subjects.team: organisation-design-team
allowed-tools: read write edit bash grep find web_search web_fetch todo_write task
---
> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

> **Sync note:** Canonical copy at `agent-infra/skills/ux-path-mapper/SKILL.md`. Product repos hard-link into `operations/skills/ux-path-mapper/SKILL.md`; Pi reads via `~/.pi/agent/skills`. Edit the agent-infra copy only.

# UX Path Mapper

## Purpose

Systematically explore the live El Dato web app using Playwright MCP browser tools. Capture every reachable screen, the navigational connections between them, and group those connections into named user journeys. Write the result to `path-map.json` for consumption by `ux-path-auditor`.

This skill is invoked by the `ux-qa` orchestrator (Phase 2) or standalone to document app UX flows.

---

## Inputs

You will receive these parameters when invoked. Apply the defaults when a parameter is absent:

| Parameter | Type | Default | Description |
|---|---|---|---|
| `entry_points` | string[] | `["/", "/acceso", "/ofertas", "/mi-negocio"]` | Routes to start crawling from |
| `auth_states` | string[] | `["unauth", "auth"]` | Which auth contexts to crawl |
| `depth` | number | `4` | Max navigation depth from each entry point |
| `output_dir` | string | `docs/ux-qa/` | Directory path to write `path-map.json` |

The `output_dir` is always an absolute path or relative to the repo root. Write `path-map.json` directly into it.

---

## App Reference

- **Base URL:** `http://localhost:8080`
- **Key routes:**
  - `/` — landing page
  - `/acceso` — login/auth page
  - `/ofertas` — deals list
  - `/oferta/:id` — deal detail
  - `/guardados/*` — saved deals (auth-gated)
  - `/mi-negocio/*` — business dashboard (auth-gated)
  - `/:city/:category/:subcategory` — SEO geo/category pages
- **Auth:** email+password login form at `/acceso`
- **Test credentials:** Read from environment variables `UX_QA_EMAIL` and `UX_QA_PASSWORD`. If these are not set, halt immediately and output:
  ```
  BLOCKED: UX_QA_EMAIL and UX_QA_PASSWORD environment variables are not set.
  Configure them before invoking this skill in authenticated mode.
  ```

---

## Playwright MCP Tool Reference

Use these tools exclusively for browser interaction. Do not use any other browser automation approach.

| Tool | Purpose |
|---|---|
| `browser_navigate` | Navigate to a URL |
| `browser_snapshot` | Capture accessibility tree snapshot of current page (use for DOM inspection) |
| `browser_click` | Click an element by accessibility selector |
| `browser_fill_form` | Fill form fields (used for login) |
| `browser_console_messages` | Read browser console log (errors, warnings) |
| `browser_network_requests` | Read network request/response log (check for 4xx/5xx) |
| `browser_wait_for` | Wait for a condition (element visible, URL change, network idle) |
| `browser_resize` | Resize viewport |
| `browser_evaluate` | Execute JavaScript in the page context |
| `browser_take_screenshot` | Capture screenshot (use for debugging only, not primary capture method) |
| `browser_press_key` | Send keyboard input |

**Primary capture method is `browser_snapshot`** — it provides the accessibility tree which is faster and more reliable than screenshots for structural analysis.

---

## Node Type Taxonomy

Classify each captured screen as one of these types. Use the first type that matches:

| Type | When to use |
|---|---|
| `landing` | Home/index page, marketing/promotional content, no auth required |
| `auth` | Login, signup, password reset, or any auth flow screen |
| `deals` | List of deals/offers (browse, search results, category pages) |
| `detail` | Single deal/offer detail page |
| `dashboard` | Business owner management screens (`/mi-negocio/*`) |
| `settings` | Account settings, profile, preferences |
| `admin` | Admin-only screens |
| `error` | 404, 500, or JS-error-dominated screen |

---

## Step-by-Step Process

### Step 0: Initialization

1. Initialize your working state:
   ```
   visited_set = Set of "route::auth_state" strings (prevents revisiting)
   nodes = []
   edges = []
   queue = []
   ```
2. Resize the viewport to 1280×800 using `browser_resize`.
3. Announce: `Starting UX path mapping — entry points: [list], auth states: [list], depth: N`

---

### Step 1: Auth State Setup

For each auth state in the `auth_states` parameter (process `"unauth"` first, then `"auth"`):

#### If auth state is `"unauth"`:
1. Clear cookies and localStorage by running `browser_evaluate` with:
   ```javascript
   localStorage.clear(); sessionStorage.clear();
   ```
2. Navigate to `/` to confirm you are in an unauthenticated state.
3. Take a `browser_snapshot` — confirm no user session indicators (avatar, "Mi Cuenta", etc.) are visible.

#### If auth state is `"auth"`:
1. Navigate to `http://localhost:8080/acceso` using `browser_navigate`.
2. Wait for the login form using `browser_wait_for` (wait for an email input field to be visible).
3. Fill the login form using `browser_fill_form`:
   - Email field: value from `UX_QA_EMAIL` env var
   - Password field: value from `UX_QA_PASSWORD` env var
4. Submit by clicking the submit button using `browser_click`.
5. Wait for navigation away from `/acceso` using `browser_wait_for` (wait for URL to not contain `/acceso`, or for a session indicator to appear).
6. Take a `browser_snapshot` to confirm session is active (look for user avatar, "Mi Cuenta", business name, or similar indicator).
7. If login fails (still on `/acceso`, or error message visible): log as a `WARN: auth login failed — skipping auth state` and skip the `"auth"` state entirely. Continue with unauthenticated results only.

---

### Step 2: Crawl Entry Points

For the current auth state, seed the queue with each entry point at depth 0:

```
For each route in entry_points:
  If "route::auth_state" not in visited_set:
    enqueue { route, depth: 0, parent_node_id: null, edge_action: null }
```

Then process the queue (breadth-first):

```
While queue is not empty:
  item = dequeue()
  If item.depth > depth parameter: skip
  If "item.route::auth_state" in visited_set: skip
  Add "item.route::auth_state" to visited_set

  node = capture_node(item.route, auth_state)
  nodes.push(node)

  If item.parent_node_id is not null:
    edges.push({
      from: item.parent_node_id,
      to: node.id,
      action: item.edge_action,
      auth: auth_state
    })

  If node.type != "error" AND item.depth < depth:
    For each link/button in node.nav_actions:
      If link is same-domain AND not in destructive blacklist:
        enqueue { route: link.href, depth: item.depth + 1, parent_node_id: node.id, edge_action: link.label }
```

---

### Step 3: Capture Node

To capture a node for a given route:

1. Navigate to `http://localhost:8080{route}` using `browser_navigate`.
2. Wait for the page to settle: use `browser_wait_for` for network idle or a landmark element.
3. Take `browser_snapshot` — this is your primary data source.
4. Run `browser_console_messages` — collect any errors or warnings.
5. Run `browser_network_requests` — collect any 4xx or 5xx responses.

From the snapshot, extract:
- **heading**: The text of the first H1 on the page. If no H1, use the first H2. If neither, use the page `<title>`.
- **type**: Apply the node type taxonomy above.
- **ctas**: All button labels and prominent link labels that represent primary actions (e.g. "Ver oferta", "Iniciar sesión", "Crear cuenta", "Guardar", "Reservar"). Exclude navigation links and footer links.
- **forms**: Identifiers for any forms present (use form label, aria-label, or first visible input placeholder as the identifier).
- **nav_links**: All `<a>` elements with `href` that point to same-domain paths. Include the `href` and visible text.
- **nav_actions**: Merge nav_links + any buttons that trigger navigation (role=button with href-like behavior). This is used for enqueuing children — not stored in the node directly.
- **console_errors**: Array of console error messages (type = "error" only, not warnings).

Construct the node:
```json
{
  "id": "<slugified-route>-<auth_state>",
  "route": "/the/route",
  "heading": "H1 text here",
  "type": "deals",
  "ctas": ["Ver oferta", "Guardar"],
  "forms": [],
  "auth": "unauth",
  "console_errors": []
}
```

Node ID format: replace `/` with `-`, strip leading `-`, append `-<auth_state>`. Examples:
- `/` + `unauth` → `root-unauth`
- `/ofertas` + `auth` → `ofertas-auth`
- `/oferta/123` + `unauth` → `oferta-123-unauth`
- `/mi-negocio/deals` + `auth` → `mi-negocio-deals-auth`

**If the page returns a 404, shows a hard JS crash (blank page with console errors), or spins indefinitely:**
- Set `type: "error"`.
- Record the console errors.
- Do NOT enqueue any children from this node.
- Log: `WARN: error node at {route} (auth: {auth_state})`

---

### Step 4: Safety Rules — Destructive Action Blacklist

**Never click or follow links/buttons matching any of these patterns** (case-insensitive, partial match):

- "eliminar" / "delete" / "remove"
- "cancelar suscripción" / "cancel subscription"
- "desactivar" / "deactivate"
- "borrar" / "clear all"
- "pagar" / "pay" / "checkout" / "procesar pago"
- "submit payment" / "confirmar pago"
- "cerrar cuenta" / "close account"

When a nav action matches the blacklist: record its label in the parent node's `ctas` array (so we know it exists), but do NOT enqueue it for crawling.

**Same-domain rule:** Only follow links where `href` starts with `/` (relative) or `http://localhost:8080`. Ignore external links, `mailto:`, `tel:`, and anchor-only links (`#...`).

---

### Step 5: Journey Grouping

After all nodes and edges are captured, group them into named journeys. A journey is an ordered list of node IDs representing a meaningful user flow.

Build each journey by tracing edges forward from a start node. Use the actual captured nodes — only include a journey if its start node exists in your nodes array.

#### Journey Templates

Build these four journeys (skip any for which no relevant nodes were captured):

**1. `new-user-onboarding`** — Label: "New User Onboarding"
- Start: `root-unauth`
- Follow edges toward: auth nodes → deals nodes
- Target path: Landing → (any CTA that leads to) Auth → (post-login) Deals or Dashboard
- Include up to 5 steps

**2. `deal-discovery`** — Label: "Deal Discovery"
- Start: `ofertas-unauth` (fall back to `root-unauth` if not present)
- Follow edges toward: deals list → deal detail → save/reserve action
- Target path: Deals list → Deal detail → (Guardar / Reservar CTA node if reachable)
- Include up to 6 steps

**3. `business-dashboard`** — Label: "Business Dashboard"
- Start: `mi-negocio-auth` or the first `dashboard`-type node in auth state
- Follow edges through: dashboard sub-pages (deal management, subscription, profile)
- Include up to 6 steps

**4. `returning-user`** — Label: "Returning User"
- Start: `acceso-unauth`
- Follow edges: Login → (post-auth redirect) → Saved deals or Deals list
- Include up to 5 steps

For each journey, trace the most direct path through captured edges. If an exact path cannot be traced from edges (e.g. the post-login redirect wasn't captured as an edge), construct the journey from node IDs directly if those nodes exist in your array.

If fewer than 2 nodes exist for a journey, omit that journey from the output.

---

### Step 6: Write Output

Write `path-map.json` to `{output_dir}/path-map.json`.

```json
{
  "generated": "<ISO 8601 timestamp>",
  "scope": "full",
  "auth_states_tested": ["unauth", "auth"],
  "nodes": [
    {
      "id": "root-unauth",
      "route": "/",
      "heading": "Descubre las mejores ofertas",
      "type": "landing",
      "ctas": ["Ver ofertas", "Crear cuenta"],
      "forms": [],
      "auth": "unauth",
      "console_errors": []
    }
  ],
  "edges": [
    {
      "from": "root-unauth",
      "to": "ofertas-unauth",
      "action": "Ver ofertas",
      "auth": "unauth"
    }
  ],
  "journeys": [
    {
      "id": "deal-discovery",
      "label": "Deal Discovery",
      "steps": ["ofertas-unauth", "oferta-123-unauth"]
    }
  ]
}
```

After writing, print a summary:
```
Path map complete → {output_dir}/path-map.json
  Nodes:    N (N unauth, N auth)
  Edges:    N
  Journeys: N (list journey IDs)
  Warnings: N (list any WARN lines)
```

---

## Error Handling

| Situation | Action |
|---|---|
| `browser_navigate` times out | Log `WARN: timeout at {route}`, create error node, skip children |
| Login fails | Log `WARN: auth login failed`, skip auth state, continue with unauth |
| Snapshot returns empty/blank | Retry once; if still empty, create error node |
| Network request returns 5xx for a route | Note in node's `console_errors`, set type to `error` |
| `UX_QA_EMAIL` / `UX_QA_PASSWORD` not set | Halt with BLOCKED message (see Step 1) |
| Output directory does not exist | Create it with `mkdir -p` equivalent before writing |

---

## Output Directory Notes

- If `output_dir` does not exist, create it before writing.
- If `path-map.json` already exists in `output_dir`, overwrite it (this skill is idempotent).
- The `output_dir` is typically set by the `ux-qa` orchestrator to a run-stamped path like `docs/ux-qa/2026-03-22-full/`. When invoked standalone, default to `docs/ux-qa/` and create a timestamped subdirectory: `docs/ux-qa/{YYYY-MM-DD}-standalone/`.

---

## Standalone Invocation

When invoked directly (not by `ux-qa`), accept arguments in this format:

```
/ux-path-mapper [entry_points=...] [auth_states=...] [depth=N] [output_dir=...]
```

If no arguments are provided, use all defaults and announce them before starting.
---
> Continue following the workflow as mandated by this skill. Do not skip steps.
