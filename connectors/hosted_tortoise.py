"""Hosted tortoise connector — dogfood the product (mission #80).

The swarm connector layer for the hosted tortoise knowledge graph. Ingest
swarm entities (issues / cards / missions) as knowledge Points and query the
graph for mission context. Standalone module — no coordination call sites
touched here (TORTOISE_DB_URI wiring at the 15 coordination call sites is
mission #78 gap D6; ingestion placement/routing is premise-labs #171).

SOR boundary (docs/vsm/github-system-of-record.md): this connector writes
KNOWLEDGE Points ONLY. Runtime state (missions, cards, card_events) lives in
Supabase — never mirrored into the graph here.

Backend resolution (first match wins):
  1. TORTOISE_DB_URI set AND the `tortoise` SDK importable → SDK backend
     (local docker://, managed redis:///rediss://). Graph isolated via
     TORTOISE_NAMESPACE (default "swarm").
  2. TORTOISE_API_KEY set → hosted HTTP backend (the product we dogfood).
     Base URL from HOSTED_TORTOISE_URL (default https://tortoise-y4mjjq.fly.dev).
  3. Neither → not configured: every call degrades gracefully (None / []
     / {skipped: N}), prints one clear warning, never raises into the daemon.

Tenant provisioning is SELF-SERVE: POST /v1/agent/signup mints a team + tt_ key
(no email/dashboard needed). Run `uv run scripts/mint_tortoise_key.py --write`
and set TORTOISE_API_KEY in ~/.swarm.env (see swarm#966 AC#3).

Kinds are validated server-side (tortoise/domain_loader.known_kinds):
issue, goal, statement, ... — `mission` is NOT a known kind, so missions
ingest as `goal` (O/I/T semantics). Cards track GitHub issues → `issue`.
"""
from __future__ import annotations

import json
import os
from typing import Any

try:
    import requests
    _HAS_REQUESTS = True
except ImportError:  # pragma: no cover — requests is the repo standard
    _HAS_REQUESTS = False

DEFAULT_URL = "https://tortoise-y4mjjq.fly.dev"
_TIMEOUT = 15

# Known tortoise point kinds (server-validated) — swarm entity → kind mapping.
_KIND_MAP = {
    "issue": "issue",
    "card": "issue",     # cards track GitHub issues → same kind
    "mission": "goal",   # O/I/T semantics; no `mission` kind exists
    "memory": "statement",
    "statement": "statement",
    "goal": "goal",
}


# ── Config helpers ─────────────────────────────────────────────

def _db_uri() -> str:
    return os.environ.get("TORTOISE_DB_URI", "").strip()


def _namespace() -> str:
    return os.environ.get("TORTOISE_NAMESPACE", "swarm").strip() or "swarm"


def _base() -> str:
    return os.environ.get("HOSTED_TORTOISE_URL", DEFAULT_URL).rstrip("/")


def _key() -> str:
    return os.environ.get("TORTOISE_API_KEY", "").strip()


def _sdk_importable() -> bool:
    try:
        import tortoise  # noqa: F401
        return True
    except ImportError:
        return False


def is_configured() -> bool:
    """True when a backend is available (SDK via URI, or hosted API key)."""
    if _db_uri() and _sdk_importable():
        return True
    return bool(_key())


def backend_name() -> str:
    """Which backend would be used: 'sdk' | 'http' | '' (not configured).

    Resolution order (controlled by TORTOISE_BACKEND env var):
      - "http": force hosted HTTP backend (requires TORTOISE_API_KEY)
      - "sdk":  force SDK backend (requires TORTOISE_DB_URI + importable SDK)
      - "auto" (default): TORTOISE_API_KEY → http;
          else TORTOISE_DB_URI + SDK → sdk; else http if key present
    """
    mode = os.environ.get("TORTOISE_BACKEND", "auto").strip().lower() or "auto"

    has_db = bool(_db_uri() and _sdk_importable())
    has_key = bool(_key())

    if mode == "http":
        return "http" if has_key else ""
    if mode == "sdk":
        return "sdk" if has_db else ""

    # auto: key wins over DB — setting a tt_ key routes to the hosted API
    if has_key:
        return "http"
    if has_db:
        return "sdk"
    return ""


def _warn_not_configured() -> None:
    print(
        "[hosted_tortoise] not configured — set TORTOISE_DB_URI (with the "
        "tortoise SDK installed) or TORTOISE_API_KEY (hosted, provisioned via "
        "/internal/provision). Skipping.",
        flush=True,
    )


# ── Backends (lazy singletons) ─────────────────────────────────

_sdk = None
_http = None


def _get_sdk():
    """Lazy SDK backend. Only called when TORTOISE_DB_URI is set."""
    global _sdk
    if _sdk is None:
        from tortoise.sdk import TortoiseSDK
        _sdk = TortoiseSDK(namespace=_namespace())
    return _sdk


def _get_http():
    """Lazy hosted-HTTP backend. Only called when TORTOISE_API_KEY is set."""
    global _http
    if _http is None:
        if not _HAS_REQUESTS:
            raise RuntimeError(
                "requests is required for the hosted HTTP backend — "
                "`python3 -m pip install requests`")
        _http = _HttpBackend()
    return _http


class _HttpBackend:
    """Minimal client for the hosted tortoise REST API (tortoise/hosted_api.py)."""

    def __init__(self):
        self.base = _base()
        self.key = _key()

    def _headers(self) -> dict:
        return {"Authorization": f"Bearer {self.key}",
                "Content-Type": "application/json"}

    def health(self) -> dict | None:
        try:
            r = requests.get(f"{self.base}/health", timeout=_TIMEOUT)
            return r.json() if r.status_code == 200 else None
        except Exception as e:
            print(f"[hosted_tortoise] health failed: {e}", flush=True)
            return None

    def create_point(self, content: str, kind: str, tags: list[str]) -> str | None:
        r = requests.post(
            f"{self.base}/v1/points",
            json={"content": content, "kind": kind, "tags": tags or []},
            headers=self._headers(), timeout=_TIMEOUT)
        # API returns 200 (FastAPI default); 201 accepted defensively.
        if r.status_code in (200, 201):
            return r.json().get("id")
        print(f"[hosted_tortoise] create_point {r.status_code}: "
              f"{r.text[:200]}", flush=True)
        return None

    def search(self, query: str, limit: int) -> list[dict]:
        r = requests.get(f"{self.base}/v1/search",
                         params={"q": query, "limit": limit},
                         headers=self._headers(), timeout=_TIMEOUT)
        if r.status_code == 200:
            data = r.json()
            return data.get("results", data if isinstance(data, list) else [])
        print(f"[hosted_tortoise] search {r.status_code}: {r.text[:200]}",
              flush=True)
        return []


def _sdk_create_point(content: str, kind: str, tags: list[str]) -> str | None:
    try:
        result = _get_sdk().create_point(kind=kind, content=content, tags=tags)
        return result.get("id")
    except Exception as e:
        print(f"[hosted_tortoise] sdk create_point failed: {e}", flush=True)
        return None


def _sdk_search(query: str, limit: int) -> list[dict]:
    try:
        sdk = _get_sdk()
        # The hosted product SDK exposes tortoise_fts_query; the legacy
        # SDK (used when TORTOISE_DB_URI points at a local graph) exposes
        # search(). Prefer fts_query, fall back to search — both return point
        # dicts (review P2).
        search_fn = getattr(sdk, "tortoise_fts_query", None) or sdk.search
        results = search_fn(query, limit=limit)
    except Exception as e:
        print(f"[hosted_tortoise] sdk search failed: {e}", flush=True)
        return []
    out = []
    for r in results:
        props = dict(r)
        if "pointKind" in props:
            props["kind"] = props.pop("pointKind")
        if "kind" not in props:
            props["kind"] = "statement"
        out.append(props)
    return out


# ── Public surface ─────────────────────────────────────────────

def health() -> dict | None:
    """Probe backend liveness. Returns parsed JSON or None.

    The hosted /health endpoint is public (no API key required — SKIP_AUTH in
    tortoise/hosted_api.py), so this works even before tenant provisioning and
    doubles as a plain reachability smoke test.
    """
    try:
        if _key():
            return _get_http().health()
        if _db_uri() and _sdk_importable():
            _get_sdk()._get_proj().g.query("RETURN 1")
            return {"status": "ok", "db": "connected", "backend": "sdk"}
        # Not configured for writes — still probe the public hosted endpoint.
        return _get_http().health()
    except Exception as e:
        print(f"[hosted_tortoise] health failed: {e}", flush=True)
        return None


def create_point(content: str, kind: str = "statement",
                 tags: list[str] | None = None) -> str | None:
    """Create a knowledge point. Returns point id or None (best-effort)."""
    kind = _map_kind(kind)
    # Server-side tag validation: non-empty, <= 200 chars, no control chars
    # (CreatePointRequest.valid_tags 422s otherwise) — sanitize client-side so
    # a bad tag degrades to a clean skip, not a logged failure (review P3).
    import re as _re
    _tag_re = _re.compile(r"[^\x20-\x7e]")
    tags = [
        _tag_re.sub("", t)[:200]
        for t in (tags or [])
        if isinstance(t, str) and t.strip()
    ]
    tags = [t for t in tags if t.strip()]
    if not content or not content.strip():
        print("[hosted_tortoise] create_point skipped — empty content",
              flush=True)
        return None
    if not is_configured():
        _warn_not_configured()
        return None
    try:
        if backend_name() == "sdk":
            return _sdk_create_point(content.strip(), kind, tags)
        return _get_http().create_point(content.strip(), kind, tags)
    except Exception as e:
        print(f"[hosted_tortoise] create_point failed: {e}", flush=True)
        return None


def query_graph(query: str, limit: int = 10) -> list[dict]:
    """Search the hosted graph for mission context. Normalized point dicts."""
    if not is_configured():
        _warn_not_configured()
        return []
    try:
        if backend_name() == "sdk":
            return _sdk_search(query, limit)
        return _get_http().search(query, limit)
    except Exception as e:
        print(f"[hosted_tortoise] query_graph failed: {e}", flush=True)
        return []


# Back-compat alias (pre-#80 name in scripts/CLI).
def search(query: str, limit: int = 10) -> list[dict]:
    return query_graph(query, limit)


def _map_kind(entity_or_kind: str) -> str:
    """Map a swarm entity name to a valid tortoise point kind."""
    return _KIND_MAP.get(entity_or_kind, entity_or_kind)


def ingest_points(items: list[dict]) -> dict:
    """Ingest swarm entities as knowledge Points.

    item shape: {"entity": "issue"|"card"|"mission"|"memory", ...fields}
    Each item maps to a point kind (issue→issue, card→issue, mission→goal,
    memory→statement). Best-effort per item — one failure never aborts the
    batch.

    Returns {"written": N, "skipped": M, "errors": K, "ids": [...]}.
    """
    written = skipped = errors = 0
    ids: list[str] = []
    for item in items:
        try:
            content, kind, tags = _build_point(item)
        except Exception as e:
            errors += 1
            print(f"[hosted_tortoise] ingest item skipped: {e}", flush=True)
            continue
        pid = create_point(content, kind=kind, tags=tags)
        if pid:
            written += 1
            ids.append(pid)
        else:
            skipped += 1
    return {"written": written, "skipped": skipped, "errors": errors,
            "ids": ids}


def _build_point(item: dict) -> tuple[str, str, list[str]]:
    """Build (content, kind, tags) from a swarm entity dict."""
    entity = _map_kind(item.get("entity") or item.get("kind") or "memory")
    tags = ["swarm", "vsm"]
    repo = item.get("repo", "")
    if repo:
        tags.append(repo.split("/")[-1])
    role = item.get("role", "")
    if role:
        tags.append(role)

    if entity == "issue":
        num = item.get("number") or item.get("issue_number") or item.get("source_id")
        title = item.get("title", "")
        state = item.get("state", "")
        content = (f"Issue #{num} ({state}): {title}"
                   + (f" — {repo}" if repo else ""))
        return content, "issue", tags

    if entity == "goal":  # mission
        mid = item.get("id", "")
        obj = item.get("objective") or item.get("title") or ""
        indicators = item.get("indicators") or []
        if indicators and not obj:
            obj = ", ".join(indicators[:3])
        if not obj:
            raise ValueError(
                "mission/goal point requires objective, title, or indicators"
            )
        content = (f"Mission {mid}: {obj}".strip()
                   + (f" (repo {repo})" if repo else ""))
        return content, "goal", tags

    # memory / statement / default
    content = item.get("content") or item.get("objective") or item.get("title") or ""
    if not content:
        raise ValueError(f"item has no content/title/objective: {item!r}")
    return str(content), entity, tags


# ── Dogfooding: card completion → knowledge point ─────────────

def record_card_completed(card: dict) -> str | None:
    """Write a knowledge point for a completed card (dogfood the product).

    Kept for the merged agent_daemon.complete_card hook (#80, commit 03fd274).
    card: dict with title, source_id/issue_number, repo, role, team, phase.
    Returns point id or None.
    """
    title = card.get("title", "")
    issue = card.get("source_id") or card.get("issue_number", "")
    repo = card.get("repo", "daniel-ospina/swarm")
    role = card.get("role", "")
    content = (f"Completed swarm work item: {title} "
               f"(repo {repo}, issue #{issue}, role {role}).")
    tags = ["swarm", "vsm", repo.split("/")[-1]]
    if role:
        tags.append(role)
    return create_point(content, kind="statement", tags=tags)


if __name__ == "__main__":
    import sys
    if len(sys.argv) >= 2 and sys.argv[1] == "health":
        print(json.dumps(health()))
    elif len(sys.argv) >= 2 and sys.argv[1] == "search":
        print(json.dumps(query_graph(sys.argv[2] if len(sys.argv) > 2 else "")))
    elif len(sys.argv) >= 3 and sys.argv[1] == "ingest":
        print(json.dumps(ingest_points(
            [{"entity": sys.argv[2], "title": " ".join(sys.argv[3:])}])))
    else:
        print(__doc__)
