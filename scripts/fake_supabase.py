"""Fake Supabase (PostgREST-shaped fluent API) for store tests.

Simulates table().select/update/insert/upsert().eq().in_().execute() chains
against an in-memory row store, recording update calls so tests can assert
single-UPDATE atomicity (CAS) and owner-only filters.
"""
from __future__ import annotations

from connectors.supabase_swarm import SwarmSupabaseStore

# ── Fake Supabase (PostgREST-shaped fluent API) ──────────────────

class FakeAPIResponse:
    def __init__(self, data):
        self.data = data


class FakeDB:
    def __init__(self, cards=None):
        self.tables = {
            "cards": [dict(r) for r in (cards or [])],
            "card_events": [],
            "organizations": [{"id": "org-1", "slug": "apresto"}],
            "actors": [{"id": "actor-1", "org_id": "org-1",
                        "agent_id": "agent-a", "kind": "agent", "name": "a"}],
        }
        self.update_calls = []  # record for atomicity/CAS assertions

    def card(self, card_id):
        for r in self.tables["cards"]:
            if r["id"] == card_id:
                return r
        return None


class FakeQueryBuilder:
    """Minimal PostgREST-style builder: select/update/insert/upsert + filters."""

    def __init__(self, db: FakeDB, table: str, verb="select", payload=None):
        self.db = db
        self.table = table
        self.verb = verb
        self.payload = payload
        self.filters = []  # (col, op, value)

    def eq(self, col, value):
        self.filters.append((col, "eq", value))
        return self

    def in_(self, col, values):
        self.filters.append((col, "in", list(values)))
        return self

    def order(self, col, desc=False):
        return self

    def limit(self, n):
        return self

    def _matches(self, row):
        for col, op, val in self.filters:
            v = row.get(col)
            if op == "eq" and v != val:
                return False
            if op == "in" and v not in val:
                return False
        return True

    def execute(self):
        rows = self.db.tables[self.table]
        if self.verb == "select":
            return FakeAPIResponse([dict(r) for r in rows if self._matches(r)])
        if self.verb == "update":
            self.db.update_calls.append({
                "table": self.table,
                "payload": dict(self.payload),
                "filters": list(self.filters),
            })
            updated = []
            for r in rows:
                if self._matches(r):
                    r.update(self.payload)
                    updated.append(dict(r))
            return FakeAPIResponse(updated)
        if self.verb == "insert":
            items = self.payload if isinstance(self.payload, list) else [self.payload]
            for item in items:
                rows.append(dict(item))
            return FakeAPIResponse([dict(i) for i in items])
        if self.verb == "upsert":
            self.db.update_calls.append({
                "table": self.table, "verb": "upsert",
                "payload": dict(self.payload), "filters": list(self.filters),
            })
            for r in rows:
                if r["id"] == self.payload.get("id"):
                    r.update(self.payload)
                    return FakeAPIResponse([dict(r)])
            rows.append(dict(self.payload))
            return FakeAPIResponse([dict(self.payload)])
        raise NotImplementedError(self.verb)


class FakeSupabase:
    def __init__(self, db: FakeDB, fail_after: int | None = None):
        self.db = db
        self.fail_after = fail_after  # simulate infra failure after N calls
        self.calls = 0

    def table(self, name):
        return _FakeTableHandle(self, name)


class _FakeTableHandle:
    def __init__(self, client: FakeSupabase, name: str):
        self.client = client
        self.name = name

    def _builder(self, verb, *args, **kwargs):
        self.client.calls += 1
        if self.client.fail_after is not None \
                and self.client.calls > self.client.fail_after:
            raise ConnectionError("simulated Supabase outage")
        return FakeQueryBuilder(self.client.db, self.name, verb, *args, **kwargs)

    def select(self, *cols):
        return self._builder("select")

    def update(self, payload):
        return self._builder("update", payload=payload)

    def insert(self, payload):
        return self._builder("insert", payload=payload)

    def upsert(self, payload, on_conflict=None):
        return self._builder("upsert", payload=payload)


class InjectedStore(SwarmSupabaseStore):
    """Store with injected fake client/org (bypasses env-based _ready path)."""

    def __init__(self, sb: FakeSupabase, org="org-1"):
        self._sb = sb
        self._org = org
