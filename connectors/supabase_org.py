"""Supabase → Tortoise connector.

Reads org-data Supabase tables and creates Subject/Object nodes
in Tortoise via the SDK. Idempotent via MERGE. Per-tenant isolation
via graph_name = org_id.
"""
from __future__ import annotations

import os
from typing import Any


def _get_supabase():
    """Lazy-import supabase client to avoid hard dependency."""
    from supabase import create_client
    url = os.environ.get("SUPABASE_URL_ORG_DATA", "")
    key = os.environ.get("SUPABASE_SERVICE_ROLE_KEY_ORG_DATA",
                         os.environ.get("SUPABASE_SERVICE_ROLE_KEY", ""))
    if not url or not key:
        raise RuntimeError(
            "SUPABASE_URL_ORG_DATA and SUPABASE_SERVICE_ROLE_KEY_ORG_DATA "
            "must be set")
    return create_client(url, key)


class SupabaseOrgConnector:
    """Sync org-data Supabase → Tortoise Subject/Object nodes."""

    def __init__(self, config: dict[str, Any] | None = None, api=None):
        self.config = config or {}
        self.api = api

    def sync(self) -> dict:
        """Run full sync. Returns {subjects: N, objects: M}."""
        sb = _get_supabase()
        proj = self.api.get_proj() if self.api else None

        subjects = 0
        objects = 0

        orgs = sb.table("organizations").select("*").execute()
        for org in orgs.data:
            org_id = org["id"]
            if proj:
                # Per-tenant graph isolation
                sdk = proj.sdk(graph_name=org_id)
            else:
                sdk = None

            # Organization → Subject
            if sdk:
                sdk.create_subject(org["name"], "organization")
                subjects += 1

            # Teams → Subjects
            teams = sb.table("teams").select("*").eq("org_id", org_id).execute()
            for team in teams.data:
                if sdk:
                    sdk.create_subject(team["name"], "team")
                    subjects += 1

            # Roles → Subjects
            roles = sb.table("roles").select("*").eq("org_id", org_id).execute()
            for role in roles.data:
                if sdk:
                    sdk.create_subject(role["name"], "role")
                    subjects += 1

            # Products → Objects
            products = sb.table("products").select("*").eq("org_id", org_id).execute()
            for prod in products.data:
                if sdk:
                    sdk.create_object(prod["name"],
                                      prod.get("object_kind", "product"))
                    objects += 1

            # Features → Objects
            features = sb.table("features").select("*").eq("org_id", org_id).execute()
            for feat in features.data:
                if sdk:
                    sdk.create_object(feat["name"],
                                      feat.get("object_kind", "feature"))
                    objects += 1

        return {"subjects": subjects, "objects": objects}
