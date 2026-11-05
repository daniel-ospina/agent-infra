#!/usr/bin/env bash
# tortoise-graph.sh — the ONE way a lane reads and writes the HOSTED Tortoise graph.
#
# WHY THIS EXISTS. The owner's mandate (2026-11-02): every agent checks the graph before it
# researches, confirms direction in the graph before it is dispatched, and logs what it learns
# after it is done — "so we can stop re-discovering the same thing 10 times". A mandate that
# needs a 40-line python preamble per lane does not get obeyed; this is the primitive it needs.
#
# WHY NOT THE MCP SERVER. An env-expanded `Authorization: Bearer …` header in the pi MCP entry
# (`${TORTOISE_MCP_API_KEY}` — the standard name) expands to
# EMPTY in a long-lived pi process started before the key existed, so the connection fails
# "Unauthorized: invalid or missing Bearer token" — measured 2026-11-02 on a fleet cell that
# CARRIES the key, while that same key authenticated a direct POST with HTTP 200 (the endpoint
# answers 401 without it, and advertises 69 tools — measured 2026-11-04, and the count moves with the
# surface, so date it rather than trusting it).
# The endpoint, the key and the tools are all healthy; only the client-side plumbing is stale.
# Not reproducible on a cell without the key — there this script exits 3 GRAPH-UNREACHABLE(NO-KEY).
# This script therefore reads the key at CALL time, from the live environment.
#
# USAGE
#   tortoise-graph.sh health
#   tortoise-graph.sh search 'attestation staleness'        # text search (what is already known)
#   tortoise-graph.sh get <point-id>                        # read one point
#   tortoise-graph.sh evidence 'MEASURED: …' [--to ID] [--pred supports]
#   tortoise-graph.sh decision 'DECIDED: …' [--to ID]
#   tortoise-graph.sh stats                                 # kind counts
#
# EXIT CODES: 0 ok · 2 usage · 3 graph unreachable / not configured (NEVER a silent skip) · 4 tool error
#             (4 also covers a 2xx that carries no result — an empty answer is never read as OK)
#
# ⛔ Read the skill before you WRITE: ~/.pi/agent/skills/how-to-use-tortoise/SKILL.md
#    A finding needs a NUMBER or a SOURCE — "tests are slow" is not a finding, "98.01 s of which
#    42.23 s is one test" is. Keep points atomic: one claim per point.

set -uo pipefail

# TORTOISE_MCP_API_KEY FIRST: it is the STANDARD name (`skills/research/SKILL.md`: "The credential is
# the standard variable TORTOISE_MCP_API_KEY; TORTOISE_API_KEY is the legacy compat alias", measured
# identical, Bearer -> 200) and the name the committed `.mcp.json` expands, so a box that resolves
# the MCP also resolves this script. The legacy `TORTOISE_API_KEY` is still accepted SECOND, so a
# box provisioned under the old name keeps working — but it is the fallback, never the preference:
# a box carrying only the alias needs the one-line alias to use the MCP at all, and reading the
# standard name first keeps the two paths in step (agent-infra#3374).
KEY="${TORTOISE_MCP_API_KEY:-${TORTOISE_API_KEY:-}}"
URL="${TORTOISE_API_URL:-https://api.premiselabs.co}"
EP="${URL%/}/mcp/"

if [ -z "$KEY" ]; then
    echo "GRAPH-UNREACHABLE(NO-KEY): neither TORTOISE_MCP_API_KEY nor TORTOISE_API_KEY is in this process's environment." >&2
    echo "  remedy: put the hosted key in ~/keys.env (mode 600) as TORTOISE_MCP_API_KEY — the launcher" >&2
    echo "          sources it — and alias it if the box carries only the LEGACY name:" >&2
    echo "          export TORTOISE_MCP_API_KEY=\"\$TORTOISE_API_KEY\" (#5153)." >&2
    echo "  Do NOT silently fall back to another graph." >&2
    exit 3
fi

export TORTOISE_GRAPH_EP="$EP" TORTOISE_GRAPH_KEY="$KEY"
exec python3 "$(dirname "$0")/tortoise_graph_client.py" "$@"
