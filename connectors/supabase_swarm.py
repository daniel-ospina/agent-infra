"""Supabase store for the swarm runtime — missions, cards, card_events.

System of record (docs/vsm/github-system-of-record.md + mission #78):
- missions, cards, card_events live in Supabase (Postgres, org_id RLS, actor
  attribution) — NOT in the graph or JSON files.
- The graph remains a projection for traversal/reasoning.

Config (env): SUPABASE_URL_ORG_DATA, SUPABASE_SERVICE_ROLE_KEY_ORG_DATA.
Agent writes use the service role (bypasses RLS); humans go through Auth.

Write policy split (#4903):
- CLAIM-CRITICAL writes (claim_card, claim_card_atomic, update_touched_paths,
  release_paths, advance_phase) are never best-effort — Supabase unreachable
  or an API failure RAISES RuntimeError (atomic UPDATE or nothing; a lost
  race is the only non-exception, and surfaces as 0 rows → None/False).
- Advisory writes (append_event, update_card, upsert_*, missions) stay
  best-effort: False/None on failure, the daemon loop keeps working.
"""
from __future__ import annotations

import json
import os
from typing import Any

_ORG_SLUG = "apresto"

# Lease TTL (research #4902: 10 min; reclaim also requires dead PID).
CLAIM_TTL_SECONDS = 600

# cards.phase enum (migration 00015 CHECK) — checkpoint gating.
PHASES = ("scoping", "planning", "implementing", "done")

# card_events parallel-work payload enums (plan §4, issue #4903).
_NOTIFY_REASONS = frozenset({
    "overlap-after-scope", "overlap-after-plan", "overlap-after-merge",
    "split", "defer", "ttl", "dead-pid",
})
_RECLAIM_REASONS = frozenset({"ttl", "dead-pid"})
_OVERLAP_DECISIONS = frozenset({"split", "defer", "notify"})
_PARALLEL_EVENT_TYPES = frozenset({
    "checkpoint_pass", "overlap_decision", "reclaim", "notify",
})


def _utcnow(offset_seconds: int = 0) -> str:
    """UTC ISO-8601 timestamp (Z), optionally offset (lease expiry)."""
    import time as _time
    return _time.strftime("%Y-%m-%dT%H:%M:%SZ",
                          _time.gmtime(_time.time() + offset_seconds))


def _client():
    url = os.environ.get("SUPABASE_URL_ORG_DATA", "")
    key = os.environ.get("SUPABASE_SERVICE_ROLE_KEY_ORG_DATA",
                         os.environ.get("SUPABASE_SERVICE_ROLE_KEY", ""))
    if not url or not key:
        return None
    # Lazy import: only reach for the supabase package when configured
    # (keeps the module importable in stdlib-only environments, e.g. CI).
    try:
        from supabase import create_client
        return create_client(url, key)
    except Exception as e:
        print(f"[supabase_swarm] client init failed: {e}", flush=True)
        return None


def _org_id(sb) -> str | None:
    """Resolve the org id for the default tenant slug."""
    try:
        rows = sb.table("organizations").select("id").eq("slug", _ORG_SLUG).limit(1).execute()
        if rows.data:
            return rows.data[0]["id"]
    except Exception as e:
        print(f"[supabase_swarm] org resolve failed: {e}", flush=True)
    return None


def ensure_actor(sb, org_id: str, agent_id: str | None = None,
                 user_id: str | None = None, name: str = "") -> str | None:
    """Get-or-create an actor. Returns actor uuid or None."""
    try:
        if agent_id:
            rows = sb.table("actors").select("id").eq("org_id", org_id) \
                .eq("agent_id", agent_id).limit(1).execute()
            if rows.data:
                return rows.data[0]["id"]
        if user_id:
            rows = sb.table("actors").select("id").eq("org_id", org_id) \
                .eq("user_id", user_id).limit(1).execute()
            if rows.data:
                return rows.data[0]["id"]
        ins = sb.table("actors").insert({
            "org_id": org_id,
            "kind": "agent" if agent_id else "human",
            "agent_id": agent_id,
            "user_id": user_id,
            "name": name,
        }).execute()
        if ins.data:
            return ins.data[0]["id"]
    except Exception as e:
        print(f"[supabase_swarm] ensure_actor failed: {e}", flush=True)
    return None


class SwarmSupabaseStore:
    """Supabase store. Claim-critical writes raise on infra failure (#4903);
    advisory writes stay best-effort (False/None on failure)."""

    def __init__(self):
        self._sb = None
        self._org = None

    def _ready(self):
        if self._sb is None:
            self._sb = _client()
            if self._sb is not None:
                self._org = _org_id(self._sb)
        return self._sb is not None and self._org is not None

    # ── Missions ─────────────────────────────────────────────

    def upsert_mission(self, m: dict) -> bool:
        if not self._ready():
            return False
        try:
            row = dict(m)
            row["org_id"] = self._org
            for k in ("indicators", "targets", "issue_ids", "depends_on", "artifacts"):
                if isinstance(row.get(k), (list, tuple)):
                    row[k] = json.dumps(row[k])
            self._sb.table("missions").upsert(row, on_conflict="id").execute()
            return True
        except Exception as e:
            print(f"[supabase_swarm] upsert_mission failed: {e}", flush=True)
            return False

    def get_mission(self, mission_id: str) -> dict | None:
        if not self._ready():
            return None
        try:
            rows = self._sb.table("missions").select("*").eq("id", mission_id).limit(1).execute()
            return rows.data[0] if rows.data else None
        except Exception as e:
            print(f"[supabase_swarm] get_mission failed: {e}", flush=True)
            return None

    def list_missions(self, status: str | None = None) -> list[dict]:
        if not self._ready():
            return []
        try:
            q = self._sb.table("missions").select("*").order("created_at")
            if status:
                q = q.eq("status", status)
            rows = q.execute()
            return rows.data or []
        except Exception as e:
            print(f"[supabase_swarm] list_missions failed: {e}", flush=True)
            return []

    def update_mission(self, mission_id: str, **fields) -> bool:
        if not self._ready():
            return False
        try:
            # JSONB columns need serialization for the update payload
            row = {}
            for k, v in fields.items():
                if isinstance(v, (list, dict)):
                    row[k] = json.dumps(v)
                else:
                    row[k] = v
            self._sb.table("missions").update(row).eq("id", mission_id).execute()
            return True
        except Exception as e:
            print(f"[supabase_swarm] update_mission failed: {e}", flush=True)
            return False

    # ── Cards (SOR — swarm#130) ────────────────────────────
    # The Supabase cards table is the system of record for Kanban boards.
    # The graph (FalkorDB) is a read-only projection for search/indexing.

    # Allowed card status transitions (from coordination.py CardStatus)
    _CARD_TRANSITIONS: dict[str, set[str]] = {
        "provided":  {"ready", "cancelled", "expired", "blocked"},
        "ready":     {"running", "cancelled", "expired"},
        "running":   {"reviewing", "failed", "blocked", "delegated"},
        "reviewing": {"done", "failed", "blocked"},
        "done":      {"ready"},
        "failed":    {"ready"},
        "blocked":   {"ready", "cancelled"},
        "cancelled": {"ready"},
        "expired":   set(),
        "delegated": set(),
    }

    def create_card(self, card: dict) -> dict | None:
        """Create a card row in Supabase. Returns the row dict or None on failure."""
        if not self._ready():
            return None
        try:
            row = {
                "org_id": self._org,
                "id": card.get("id", ""),
                "issue_number": str(card.get("issue_number", card.get("source_id", ""))),
                "repo": card.get("repo", "daniel-ospina/swarm"),
                "role": card.get("role", card.get("assigned_to", "")),
                "team": card.get("team", ""),
                "status": card.get("status", "provided"),
                # phase '' → NULL (00015 CHECK: NULL | enum only)
                "phase": card.get("phase") or None,
                "claimed_by": card.get("claimed_by", ""),
                "priority": int(card.get("priority", 5)),
                "complexity": card.get("complexity", "standard"),
            }
            if card.get("mission_id"):
                row["mission_id"] = card["mission_id"]
            # QA mission fields (issue #4899): the minted card's title + mission
            # type + target + scope hints survive to the agent prompt.
            for _k in ("title", "mission_type", "target_product", "scope_hints"):
                if card.get(_k):
                    row[_k] = card[_k]
            self._sb.table("cards").upsert(
                row, on_conflict="org_id,repo,issue_number"
            ).execute()
            return self.get_card(row["id"])
        except Exception as e:
            print(f"[supabase_swarm] create_card failed: {e}", flush=True)
            return None

    def get_card(self, card_id: str) -> dict | None:
        """Get a single card by id."""
        if not self._ready():
            return None
        try:
            rows = self._sb.table("cards").select("*").eq("id", card_id).limit(1).execute()
            return rows.data[0] if rows.data else None
        except Exception as e:
            print(f"[supabase_swarm] get_card failed: {e}", flush=True)
            return None

    def list_cards_by_board(self, role: str, team: str,
                            status: str | None = None) -> list[dict]:
        """List cards for a (role, team) board, optionally filtered by status."""
        if not self._ready():
            return []
        try:
            q = self._sb.table("cards").select("*") \
                .eq("role", role).eq("team", team) \
                .order("priority", desc=False)
            if status:
                q = q.eq("status", status)
            rows = q.execute()
            return rows.data or []
        except Exception as e:
            print(f"[supabase_swarm] list_cards_by_board failed: {e}", flush=True)
            return []

    def list_pending_cards(self, role: str, team: str) -> list[dict]:
        """Cards in 'provided' or 'ready' status for a board, ordered by priority."""
        if not self._ready():
            return []
        try:
            rows = self._sb.table("cards").select("*") \
                .eq("role", role).eq("team", team) \
                .in_("status", ["provided", "ready"]) \
                .order("priority", desc=False) \
                .order("created_at", desc=False) \
                .execute()
            return rows.data or []
        except Exception as e:
            print(f"[supabase_swarm] list_pending_cards failed: {e}", flush=True)
            return []

    def claim_card(self, role: str, team: str, agent_id: str,
                   base_commit: str | None = None) -> dict | None:
        """Claim the highest-priority pending card for a board.

        Atomic conditional-UPDATE CAS extended with lease fields (#4903):
        lease_expires_at, heartbeat_at, base_commit, phase='scoping', and
        touched_paths reset to NULL — all in ONE UPDATE statement (E2E-4).

        Returns the claimed card dict, or None when there is no pending card
        or the CAS race was lost (0 rows updated). Raises RuntimeError when
        Supabase is unreachable — claims are never best-effort.
        """
        if not self._ready():
            raise RuntimeError(
                "[supabase_swarm] Supabase unreachable — claim_card refused "
                "(claims are never best-effort)")
        pending = self._list_pending_cards_strict(role, team)
        if not pending:
            return None
        target = pending[0]
        return self.claim_card_atomic(
            target["id"], agent_id, base_commit=base_commit,
            expected_status=target["status"])

    def _list_pending_cards_strict(self, role: str, team: str) -> list[dict]:
        """list_pending_cards, but infra failures RAISE (claim path).

        The advisory variant returns [] on error, which would make claim_card
        silently report "no cards" during an outage — forbidden for claims.
        """
        try:
            rows = self._sb.table("cards").select("*") \
                .eq("role", role).eq("team", team) \
                .in_("status", ["provided", "ready"]) \
                .order("priority", desc=False) \
                .order("created_at", desc=False) \
                .execute()
            return rows.data or []
        except Exception as e:
            raise RuntimeError(
                f"[supabase_swarm] pending-cards read failed: {e}") from e

    def claim_card_atomic(self, card_id: str, agent_id: str,
                          base_commit: str | None = None,
                          expected_status: str | None = None) -> dict | None:
        """CAS claim of a specific card — ONE conditional UPDATE (E2E-4).

        A single UPDATE statement sets status/claimed_by/updated_at plus the
        lease fields: lease_expires_at (now + TTL), heartbeat_at, base_commit,
        phase='scoping', touched_paths=NULL — WHERE id AND status matches
        (snapshot status, or provided|ready when unknown). No read-then-write:
        a lost race surfaces as 0 rows → None.

        Raises RuntimeError on infra failure; claims are never best-effort.
        """
        if not self._ready():
            raise RuntimeError(
                "[supabase_swarm] Supabase unreachable — claim_card_atomic "
                "refused (claims are never best-effort)")
        payload = {
            "status": "running",
            "claimed_by": agent_id,
            "updated_at": _utcnow(),
            "lease_expires_at": _utcnow(CLAIM_TTL_SECONDS),
            "heartbeat_at": _utcnow(),
            "base_commit": base_commit,
            "phase": "scoping",
            "touched_paths": None,  # reset — claim intent starts empty
        }
        try:
            q = self._sb.table("cards").update(payload).eq("id", card_id)
            if expected_status:
                q = q.eq("status", expected_status)
            else:
                q = q.in_("status", ["provided", "ready"])
            result = q.execute()
            if not result.data:
                return None  # lost the CAS race — not an infra failure
            return result.data[0]
        except Exception as e:
            raise RuntimeError(
                f"[supabase_swarm] claim_card_atomic failed: {e}") from e

    # ── File-level claim intent + lease release (#4903) ──────────
    # Owner-only writes: WHERE claimed_by = agent_id. 0 rows → False (the
    # caller is not the holder / card missing — a fencing signal, not an
    # infra failure; infra failures RAISE).

    def update_touched_paths(self, card_id: str, paths: list[str],
                             agent_id: str) -> bool:
        """FULL-ARRAY replacement of cards.touched_paths (claim intent).

        Not a merge/append — the owning session replaces the whole file set
        (single-writer rule). Owner-only: WHERE id AND claimed_by=agent_id.
        0 rows → False. Raises RuntimeError on infra failure.
        """
        if not self._ready():
            raise RuntimeError(
                "[supabase_swarm] Supabase unreachable — update_touched_paths "
                "refused")
        try:
            result = self._sb.table("cards").update({
                "touched_paths": list(paths),
                "updated_at": _utcnow(),
            }).eq("id", card_id).eq("claimed_by", agent_id).execute()
            return bool(result.data)
        except Exception as e:
            raise RuntimeError(
                f"[supabase_swarm] update_touched_paths failed: {e}") from e

    def release_paths(self, card_id: str, agent_id: str) -> bool:
        """Release side of complete/reclaim: clear touched_paths +
        lease_expires_at in ONE owner-only UPDATE.

        0 rows → False: the caller was not the current holder (prior holder
        cannot re-complete — E2E-12 fencing). Raises RuntimeError on infra
        failure.
        """
        if not self._ready():
            raise RuntimeError(
                "[supabase_swarm] Supabase unreachable — release_paths refused")
        try:
            result = self._sb.table("cards").update({
                "touched_paths": None,
                "lease_expires_at": None,
                "updated_at": _utcnow(),
            }).eq("id", card_id).eq("claimed_by", agent_id).execute()
            return bool(result.data)
        except Exception as e:
            raise RuntimeError(
                f"[supabase_swarm] release_paths failed: {e}") from e

    def renew_lease(self, card_id: str, agent_id: str) -> bool:
        """Renew the claim lease (#4906): heartbeat_at=now, lease_expires_at=
        now+TTL in ONE owner-only UPDATE (WHERE claimed_by = agent_id).

        heartbeat_at is the reclaim key for recover_stale_cards — the owning
        daemon renews it each loop iteration while the card is in flight.
        0 rows → False: not the holder / card gone (fencing signal, not an
        infra failure). Raises RuntimeError on infra failure.
        """
        if not self._ready():
            raise RuntimeError(
                "[supabase_swarm] Supabase unreachable — renew_lease refused")
        try:
            result = self._sb.table("cards").update({
                "heartbeat_at": _utcnow(),
                "lease_expires_at": _utcnow(CLAIM_TTL_SECONDS),
                "updated_at": _utcnow(),
            }).eq("id", card_id).eq("claimed_by", agent_id).execute()
            return bool(result.data)
        except Exception as e:
            raise RuntimeError(
                f"[supabase_swarm] renew_lease failed: {e}") from e

    def advance_phase(self, card_id: str, from_phase: str, to_phase: str,
                      agent_id: str) -> bool:
        """Owner-only phase advance with from_phase CAS guard (E2E-10).

        WHERE id AND claimed_by=agent_id AND phase=from_phase → 0 rows means
        non-owner, wrong from_phase (out-of-order/duplicate advance), or a
        missing card → False. Raises RuntimeError on infra failure.
        """
        if from_phase not in PHASES or to_phase not in PHASES:
            raise ValueError(
                f"advance_phase: phases must be one of {PHASES}, "
                f"got {from_phase!r} → {to_phase!r}")
        if not self._ready():
            raise RuntimeError(
                "[supabase_swarm] Supabase unreachable — advance_phase refused")
        try:
            result = self._sb.table("cards").update({
                "phase": to_phase,
                "updated_at": _utcnow(),
            }).eq("id", card_id).eq("claimed_by", agent_id) \
              .eq("phase", from_phase).execute()
            return bool(result.data)
        except Exception as e:
            raise RuntimeError(
                f"[supabase_swarm] advance_phase failed: {e}") from e

    def transition_card(self, card_id: str, target_status: str) -> dict | None:
        """Transition a card to a new status, validating against CARD_TRANSITIONS.

        Returns the updated card dict, or None on failure / invalid transition.
        """
        if not self._ready():
            return None
        try:
            current = self.get_card(card_id)
            if current is None:
                return None
            cur = current.get("status", "")
            allowed = self._CARD_TRANSITIONS.get(cur, set())
            if target_status not in allowed:
                print(
                    f"[supabase_swarm] invalid transition: {cur} → {target_status}",
                    flush=True,
                )
                return None
            import time as _time
            now = _time.strftime("%Y-%m-%dT%H:%M:%SZ", _time.gmtime())
            self._sb.table("cards").update({
                "status": target_status,
                "updated_at": now,
            }).eq("id", card_id).execute()
            return self.get_card(card_id)
        except Exception as e:
            print(f"[supabase_swarm] transition_card failed: {e}", flush=True)
            return None

    def update_card(self, card_id: str, **fields) -> bool:
        """Update arbitrary card fields. Returns True on success."""
        if not self._ready():
            return False
        try:
            import time as _time
            fields["updated_at"] = _time.strftime("%Y-%m-%dT%H:%M:%SZ", _time.gmtime())
            self._sb.table("cards").update(fields).eq("id", card_id).execute()
            return True
        except Exception as e:
            print(f"[supabase_swarm] update_card failed: {e}", flush=True)
            return False

    def upsert_card(self, card: dict) -> bool:
        if not self._ready():
            return False
        try:
            # Only include present fields — passing None overrides DB defaults
            # (e.g. claimed_by NOT NULL DEFAULT '' → NULL violation).
            row = {k: card.get(k) for k in
                   ("id", "mission_id", "issue_number", "repo", "role", "team",
                    "status", "phase", "claimed_by", "priority", "complexity")
                   if card.get(k) is not None}
            if row.get("phase") == "":
                row["phase"] = None  # 00015 CHECK: NULL | enum only
            row["org_id"] = self._org
            self._sb.table("cards").upsert(row, on_conflict="id").execute()
            return True
        except Exception as e:
            print(f"[supabase_swarm] upsert_card failed: {e}", flush=True)
            return False

    # ── card_events (append-only audit/replay trail) ─────────

    def write_parallel_event(self, card_id: str, event_type: str,
                             payload: dict | None = None,
                             actor_agent_id: str | None = None) -> bool:
        """Append a parallel-work event — the single write path for
        checkpoint_pass | overlap_decision | reclaim | notify (plan §4).

        Payload enums validated (ValueError = caller bug, loud):
          checkpoint_pass  {card_id, phase∈PHASES, checkpoint, ts}
          overlap_decision {card_id, other_card, decision∈{split,defer,notify}, ts}
          reclaim          {card_id, reason∈{ttl,dead-pid}, ts}
          notify           {card_id, from_card, reason∈{overlap-after-scope,
                            overlap-after-plan, overlap-after-merge, split,
                            defer, ttl, dead-pid}, ts}

        card_events.event_type is TEXT (migration 00013) — no schema change.
        Writes via append_event (best-effort: False on infra failure —
        claim-critical state lives in cards, not the log). Detect layers
        (#4904) CALL this helper; they never write events directly.
        """
        if event_type not in _PARALLEL_EVENT_TYPES:
            raise ValueError(
                f"write_parallel_event: unknown event_type {event_type!r}; "
                f"expected one of {sorted(_PARALLEL_EVENT_TYPES)}")
        data = dict(payload or {})
        data.setdefault("card_id", card_id)
        data.setdefault("ts", _utcnow())
        if event_type == "checkpoint_pass":
            for key in ("phase", "checkpoint"):
                if key not in data:
                    raise ValueError(
                        f"checkpoint_pass payload missing {key!r}")
            if data["phase"] not in PHASES:
                raise ValueError(
                    f"checkpoint_pass phase {data['phase']!r} not in {PHASES}")
        elif event_type == "overlap_decision":
            if "other_card" not in data or "decision" not in data:
                raise ValueError(
                    "overlap_decision payload needs other_card + decision")
            if data["decision"] not in _OVERLAP_DECISIONS:
                raise ValueError(
                    f"overlap_decision decision {data['decision']!r} not in "
                    f"{sorted(_OVERLAP_DECISIONS)}")
        elif event_type == "reclaim":
            if data.get("reason") not in _RECLAIM_REASONS:
                raise ValueError(
                    f"reclaim reason {data.get('reason')!r} not in "
                    f"{sorted(_RECLAIM_REASONS)}")
        elif event_type == "notify":
            if data.get("reason") not in _NOTIFY_REASONS:
                raise ValueError(
                    f"notify reason {data.get('reason')!r} not in "
                    f"{sorted(_NOTIFY_REASONS)}")
        return self.append_event(card_id, event_type,
                                 actor_agent_id=actor_agent_id, payload=data)

    def release_and_notify(self, card_id: str, agent_id: str, reason: str,
                           from_card: str | None = None) -> bool:
        """Release + notify event with enum reason (E2E-12 fence) — the
        release side of complete/reclaim with overlap signalling.

        release_paths is owner-only, so a prior holder gets False (fenced).
        The notify event is written regardless of release outcome so the
        overlap is on record; enum reasons validated (ValueError on bad
        reason).
        """
        released = self.release_paths(card_id, agent_id)
        self.write_parallel_event(card_id, "notify", {
            "card_id": card_id,
            "from_card": from_card,
            "reason": reason,
        }, actor_agent_id=agent_id)
        return released

    def append_event(self, card_id: str, event_type: str,
                     actor_agent_id: str | None = None,
                     payload: dict | None = None) -> bool:
        """Append a lifecycle event. Returns False on failure."""
        if not self._ready():
            return False
        try:
            actor_id = None
            if actor_agent_id:
                actor_id = ensure_actor(self._sb, self._org, agent_id=actor_agent_id)
            self._sb.table("card_events").insert({
                "org_id": self._org,
                "card_id": card_id,
                "actor_id": actor_id,
                "event_type": event_type,
                "payload": json.dumps(payload or {}),
            }).execute()
            return True
        except Exception as e:
            print(f"[supabase_swarm] append_event failed: {e}", flush=True)
            return False

    def recent_events(self, event_type: str | None = None, minutes: int = 5) -> list[dict]:
        """Recent lifecycle events — the checkout guard's activity signal."""
        if not self._ready():
            return []
        try:
            # PostgREST evaluates filters client-side — pass a real ISO
            # timestamp, not a SQL expression (the expression was rejected).
            from datetime import datetime, timedelta, timezone
            cutoff = (datetime.now(timezone.utc) - timedelta(minutes=minutes)).isoformat()
            q = self._sb.table("card_events").select("*") \
                .gte("created_at", cutoff)
            if event_type:
                q = q.eq("event_type", event_type)
            rows = q.limit(50).execute()
            return rows.data or []
        except Exception as e:
            print(f"[supabase_swarm] recent_events failed: {e}", flush=True)
            return []


def store() -> SwarmSupabaseStore:
    return SwarmSupabaseStore()
