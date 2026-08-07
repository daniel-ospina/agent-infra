#!/usr/bin/env node
/**
 * swarm-org.mjs — org-data client for the swarm Supabase SOR (issue #102).
 *
 * Queries the swarm Supabase tables that SUPERSEDE the dead eldato-era
 * `operations/subjects/*.yaml` tree: teams, products, roles (migrations
 * 00003-00005 in daniel-ospina/swarm). Canonical source of truth for
 * team/role/product data — see skills/goal-setting, skills/issue-creation,
 * skills/team-registration, extensions/loop-enforcer.
 *
 * Usage:
 *   node scripts/swarm-org.mjs list-teams [--org <slug>]
 *   node scripts/swarm-org.mjs list-roles [--team <slug>]
 *   node scripts/swarm-org.mjs resolve-role <role-slug>   # loop-enforcer --for
 *   node scripts/swarm-org.mjs list-products [--team <slug>]
 *
 * Env (set in the swarm repo, see swarm/README.md "Runtime Setup"):
 *   SUPABASE_URL_ORG_DATA            e.g. https://<project>.supabase.co
 *   SUPABASE_SERVICE_ROLE_KEY_ORG_DATA  (falls back to SUPABASE_SERVICE_ROLE_KEY)
 *
 * Test mode: SWARM_ORG_MOCK=1 prints realistic fixtures without network.
 * Missing creds → JSON error + exit 1 (callers must degrade gracefully).
 * Zero dependencies — plain fetch (Node ≥ 18).
 */
const ORG_TABLES = ["organizations", "teams", "products", "roles", "features"];

function envUrl() {
  return process.env.SUPABASE_URL_ORG_DATA || "";
}
function envKey() {
  return process.env.SUPABASE_SERVICE_ROLE_KEY_ORG_DATA
    || process.env.SUPABASE_SERVICE_ROLE_KEY || "";
}

function requireCreds() {
  if (!envUrl() || !envKey()) {
    console.error(JSON.stringify({
      error: "swarm_sor_unavailable",
      message: "SUPABASE_URL_ORG_DATA and SUPABASE_SERVICE_ROLE_KEY_ORG_DATA must be set "
        + "(swarm Supabase SOR). See swarm repo README 'Runtime Setup'.",
      hint: "run from the swarm repo or export the credentials; mock with SWARM_ORG_MOCK=1",
    }, null, 2));
    process.exit(1);
  }
}

async function rest(table, opts = {}) {
  const { orgSlug, teamSlug, limit = 500 } = opts;
  const select = opts.select || "*";
  const url = new URL(`${envUrl()}/rest/v1/${table}`);
  url.searchParams.set("select", select);
  url.searchParams.set("limit", String(limit));
  if (orgSlug) {
    url.searchParams.set("org_id", `(select(id) from organizations where slug=eq.${orgSlug})`);
  }
  if (teamSlug) {
    url.searchParams.set("team_id", `(select(id) from teams where slug=eq.${teamSlug})`);
  }
  const res = await fetch(url.toString(), {
    headers: {
      apikey: envKey(),
      Authorization: `Bearer ${envKey()}`,
    },
  });
  if (!res.ok) {
    throw new Error(`Supabase ${table} query failed: HTTP ${res.status} ${await res.text()}`);
  }
  return res.json();
}

// ── Mock fixtures (SWARM_ORG_MOCK=1) — shape mirrors real SOR rows ──
const MOCK = {
  organizations: [{ id: "org-1", name: "Premise Labs", slug: "premise-labs" },
    { id: "org-2", name: "El Dato", slug: "eldato" }],
  teams: [
    { id: "t-1", org_id: "org-2", name: "Organisation Design", slug: "organisation-design-team", description: "Org design + capability" },
    { id: "t-2", org_id: "org-2", name: "El Dato App", slug: "eldato-app-team", description: "Main El Dato app" },
    { id: "t-3", org_id: "org-2", name: "Epistemic", slug: "epistemic-team", description: "Knowledge graph" },
  ],
  roles: [
    { id: "r-1", org_id: "org-2", team_id: "t-1", name: "Team Strategist", slug: "team-strategist", subject_kind: "role", held_by: "pi", loop_type: "cron", delegation: "open", reports_to: null },
    { id: "r-2", org_id: "org-2", team_id: "t-1", name: "Product Strategist", slug: "product-strategist", subject_kind: "role", held_by: "pi", loop_type: "cron", delegation: "open", reports_to: "team-strategist" },
    { id: "r-3", org_id: "org-2", team_id: "t-2", name: "Growth Hacker", slug: "growth-hacker", subject_kind: "role", held_by: "pi", loop_type: "cron", delegation: "open", reports_to: null },
    { id: "r-4", org_id: "org-2", team_id: "t-3", name: "Epistemic Steward", slug: "epistemic-steward", subject_kind: "role", held_by: "pi", loop_type: "continuous", delegation: "open", reports_to: null },
  ],
  products: [
    { id: "p-1", org_id: "org-2", team_id: "t-2", name: "El Dato", slug: "eldato", object_kind: "product", stage: "live", repo_url: "https://github.com/daniel-ospina/eldato" },
    { id: "p-2", org_id: "org-2", team_id: "t-3", name: "Tortoise", slug: "tortoise", object_kind: "product", stage: "live", repo_url: "https://github.com/daniel-ospina/tortoise" },
  ],
  features: [],
};

async function query(table, opts) {
  if (process.env.SWARM_ORG_MOCK === "1") {
    let rows = MOCK[table] || [];
    if (opts.orgSlug) rows = rows.filter((r) => (MOCK.organizations.find((o) => o.slug === opts.orgSlug) || {}).id === r.org_id);
    if (opts.teamSlug) rows = rows.filter((r) => (MOCK.teams.find((t) => t.slug === opts.teamSlug) || {}).id === r.team_id);
    return rows;
  }
  requireCreds();
  return rest(table, opts);
}

async function main() {
  const [cmd, ...args] = process.argv.slice(2);
  const opt = (name, dflt = "") => {
    const i = args.indexOf(name);
    return i >= 0 ? args[i + 1] : dflt;
  };
  const orgSlug = opt("--org", "");
  const teamSlug = opt("--team", "");

  switch (cmd) {
    case "list-teams": {
      const rows = await query("teams", { orgSlug });
      console.log(JSON.stringify({ count: rows.length, teams: rows }, null, 2));
      break;
    }
    case "list-roles": {
      const rows = await query("roles", { orgSlug, teamSlug });
      console.log(JSON.stringify({ count: rows.length, roles: rows }, null, 2));
      break;
    }
    case "resolve-role": {
      const slug = args.find((a) => !a.startsWith("--")) || "";
      if (!slug) { console.error("resolve-role requires a role slug"); process.exit(2); }
      const roles = await query("roles", { orgSlug });
      const role = roles.find((r) => r.slug === slug);
      if (!role) {
        console.log(JSON.stringify({ found: false, slug, message: `no role with slug '${slug}' in swarm SOR` }, null, 2));
        process.exit(0);
      }
      const teams = await query("teams", {});
      const team = teams.find((t) => t.id === role.team_id) || null;
      console.log(JSON.stringify({
        found: true, role: role.slug, name: role.name,
        team: team ? team.slug : null,
        held_by: role.held_by, loop_type: role.loop_type,
        delegation: role.delegation, reports_to: role.reports_to,
      }, null, 2));
      break;
    }
    case "list-products": {
      const rows = await query("products", { orgSlug, teamSlug });
      console.log(JSON.stringify({ count: rows.length, products: rows }, null, 2));
      break;
    }
    case "status": {
      if (process.env.SWARM_ORG_MOCK !== "1") requireCreds();
      const counts = {};
      for (const t of ORG_TABLES) {
        const rows = await query(t, {});
        counts[t] = rows.length;
      }
      console.log(JSON.stringify({ available: true, source: "swarm Supabase SOR", counts }, null, 2));
      break;
    }
    default:
      console.error(`Usage: node scripts/swarm-org.mjs <list-teams|list-roles|resolve-role|list-products|status> [--org <slug>] [--team <slug>]
Env: SUPABASE_URL_ORG_DATA, SUPABASE_SERVICE_ROLE_KEY_ORG_DATA (see swarm repo README)
Mock: SWARM_ORG_MOCK=1`);
      process.exit(2);
  }
}

main().catch((e) => {
  console.error(JSON.stringify({ error: "swarm_org_failed", message: String(e.message || e) }, null, 2));
  process.exit(1);
});
