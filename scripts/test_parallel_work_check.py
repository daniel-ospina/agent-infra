"""Tests for parallel_work_check — C1-C5 verdicts (issue #4904, surface S3).

Unit (fixture verdicts via injected guard/GH/board/store) + integration
(real temp git repos, MockGh = local REST endpoint at GH_API_BASE, board
fixture via injectable Supabase REST URL) + bash-wrapper end-to-end.

Coverage per the issue's verification checklist:
- every phase verdict incl. UNKNOWN (infra/timeout/budget >2s→UNKNOWN)
- expired-lease filtering (live := lease_expires_at > now(), PRIMARY)
- symbol booster advisory-vs-blocking (Gate A noise caveat)
- DUP_FIX at start AND implement
- base-commit drift → STALE
- options=<...> emitted; PASS token ONLY on CLEAR
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import threading
import time
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote

import pytest

_REPO_ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(_REPO_ROOT))
sys.path.insert(0, str(_REPO_ROOT / "tests"))

import parallel_work_check as pwc
from fake_supabase import FakeDB, FakeSupabase, InjectedStore

CHECK_SH = Path(__file__).resolve().parent / "parallel_work_check.sh"
PYTHON = sys.executable


# ── local HTTP mock (MockGh / MockSupabase REST) ──────────────

class _MockHandler(BaseHTTPRequestHandler):
    def log_message(self, *args):  # silence
        pass

    def _send(self, status: int, payload) -> None:
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        routes = getattr(self.server, "routes", {})
        path = unquote(self.path)
        for key, spec in routes.items():
            if key in path:
                time.sleep(float(spec.get("sleep", 0)))
                return self._send(spec.get("status", 200),
                                  spec.get("payload", {}))
        self._send(404, {})

    def do_PATCH(self):
        routes = getattr(self.server, "patch_routes", {})
        path = unquote(self.path)
        for key, spec in routes.items():
            if key in path:
                return self._send(spec.get("status", 200),
                                  spec.get("payload", []))
        self._send(404, {})


def _serve(routes=None, patch_routes=None) -> ThreadingHTTPServer:
    server = ThreadingHTTPServer(("127.0.0.1", 0), _MockHandler)
    server.routes = routes or {}
    server.patch_routes = patch_routes or {}
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def _url(server: ThreadingHTTPServer) -> str:
    return f"http://127.0.0.1:{server.server_address[1]}"


# ── fixtures ───────────────────────────────────────────────────

NOW = datetime(2026, 8, 13, 12, 0, 0, tzinfo=timezone.utc)


def _iso(dt: datetime) -> str:
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def _card(card_id="card-a", *, issue="4904", status="running", claimed="agent-a",
          phase="scoping", touched=("src/auth.py",), lease=3600,
          base="cafe1234") -> dict:
    return {
        "id": card_id, "issue_number": issue, "status": status,
        "claimed_by": claimed, "phase": phase,
        "touched_paths": list(touched) if touched else None,
        "lease_expires_at": _iso(NOW + timedelta(seconds=lease))
        if lease is not None else None,
        "heartbeat_at": _iso(NOW),
        "base_commit": base,
    }


def _env(card_id="card-a", agent="agent-a", paths=("src/auth.py",),
         token=None, timeout="5", symbol=None) -> dict:
    env = {
        "SWARM_CARD_ID": card_id,
        "AGENT_ID": agent,
        "SWARM_TOUCHED_PATHS": "\n".join(paths),
        "PARALLEL_CHECK_TIMEOUT_SECS": timeout,
        "PARALLEL_CHECK_TOKEN_FILE": str(token),
        "PARALLEL_CHECK_REPO_SLUG": "daniel-ospina/swarm",
    }
    if symbol:
        env["PARALLEL_CHECK_SYMBOL"] = symbol
    return env


class FakeGit:
    """Injectable GitOps stand-in for pure-fixture unit tests."""

    def __init__(self, fetch_raises=False):
        self.fetch_raises = fetch_raises

    def fetch(self, timeout):
        if self.fetch_raises:
            raise pwc.InfraError("git-timeout")

    def history_paths(self, hours, rev, timeout):
        return set()

    def pickaxe(self, symbol, days, rev, timeout):
        return {}

    def behind(self, timeout):
        return 0

    def head(self, timeout):
        return "cafe1234"

    def is_ancestor(self, base, ref, timeout):
        return True


def _store(cards):
    db = FakeDB(cards=cards)
    return InjectedStore(FakeSupabase(db)), db


def _board(server, cards):
    server.routes["/rest/v1/cards"] = {"payload": cards}
    return pwc.BoardRest(_url(server), "test-key", 5.0)


def _gh(server, closed=None, prs=None):
    if closed is not None:
        server.routes["state:closed"] = {
            "payload": {"total_count": len(closed), "items": closed}}
    if prs is not None:
        server.routes["is:pr"] = {
            "payload": {"total_count": len(prs), "items": prs}}
    return pwc.GhRest(_url(server), "test-token", 5.0)


@pytest.fixture
def servers():
    gh, sb = _serve(), _serve()
    yield gh, sb
    gh.shutdown()
    sb.shutdown()


# ── git fixtures (integration-shaped) ─────────────────────────

def _git(*args, cwd=None, check=True) -> subprocess.CompletedProcess:
    cmd = list(args) if cwd is None else ["-C", str(cwd), *args]
    return subprocess.run(["git", *cmd], capture_output=True, text=True,
                          check=check)


def _make_repo(tmp_path: Path) -> tuple[Path, Path]:
    """Working repo (branch main, 1 commit) + bare origin; commit pushed."""
    repo = tmp_path / "repo"
    origin = tmp_path / "origin.git"
    _git("init", "-b", "main", str(repo))
    _git("config", "user.email", "pwc-test@example.com", cwd=repo)
    _git("config", "user.name", "PWC Test", cwd=repo)
    (repo / "file.txt").write_text("v1\n")
    _git("add", "file.txt", cwd=repo)
    _git("commit", "-m", "c1", cwd=repo)
    _git("init", "--bare", "-b", "main", str(origin))
    _git("remote", "add", "origin", str(origin), cwd=repo)
    _git("push", "-u", "origin", "main", cwd=repo)
    return repo, origin


def _advance_origin(tmp_path: Path, origin: Path, message="c2") -> str:
    """Push a new commit to origin (scratch clone) — working repo falls behind."""
    scratch = tmp_path / "scratch"
    _git("clone", str(origin), str(scratch))
    _git("config", "user.email", "pwc-test@example.com", cwd=scratch)
    _git("config", "user.name", "PWC Test", cwd=scratch)
    (scratch / "extra.txt").write_text("extra\n")
    _git("add", "extra.txt", cwd=scratch)
    _git("commit", "-m", message, cwd=scratch)
    _git("push", "origin", "main", cwd=scratch)
    return _git("rev-parse", "HEAD", cwd=scratch).stdout.strip()


def _rev(repo: Path, ref="HEAD") -> str:
    return _git("rev-parse", ref, cwd=repo).stdout.strip()


# ── C1 unit: fixture verdicts ──────────────────────────────────

def test_c1_clear_writes_pass_token(servers, tmp_path):
    gh, sb = servers
    token = tmp_path / "token.json"
    res = pwc.run_check(
        "start", repo=str(tmp_path), symbol="auth_token",
        env=_env(token=token, symbol="auth_token"),
        git=FakeGit(), gh=_gh(gh, closed=[], prs=[]),
        board=_board(sb, [_card()]),
        guard=lambda repo, env, timeout:
            "checkout-guard VERDICT: CLEAR checkout up-to-date\n",
        now=NOW)
    assert res.verdict == "CLEAR"
    assert res.code == "C1"
    assert json.loads(token.read_text())["verdict"] == "CLEAR"
    assert json.loads(token.read_text())["phase"] == "start"


def test_c1_guard_stale(servers, tmp_path):
    gh, sb = servers
    token = tmp_path / "token.json"
    res = pwc.run_check(
        "start", repo=str(tmp_path), env=_env(token=token),
        git=FakeGit(), gh=_gh(gh), board=_board(sb, [_card()]),
        guard=lambda repo, env, timeout:
            "checkout-guard VERDICT: STALE behind origin/main\n",
        now=NOW)
    assert res.verdict == "STALE"
    assert "rebase" in res.options
    assert not token.exists()


def test_c1_guard_defer_maps_to_stale(servers, tmp_path):
    gh, sb = servers
    res = pwc.run_check(
        "start", repo=str(tmp_path), env=_env(token=tmp_path / "t.json"),
        git=FakeGit(), gh=_gh(gh), board=_board(sb, [_card()]),
        guard=lambda repo, env, timeout:
            "checkout-guard VERDICT: DEFER checkout collision detected\n",
        now=NOW)
    assert res.verdict == "STALE"
    assert "DEFER" in res.details


def test_c1_guard_no_verdict_line_unknown(servers, tmp_path):
    gh, sb = servers
    res = pwc.run_check(
        "start", repo=str(tmp_path), env=_env(token=tmp_path / "t.json"),
        git=FakeGit(), gh=_gh(gh), board=_board(sb, [_card()]),
        guard=lambda repo, env, timeout: "garbage output\n", now=NOW)
    assert res.verdict == "UNKNOWN"
    assert "checkout-guard" in res.details


def test_c1_closed_issue_dup_fix(servers, tmp_path):
    gh, sb = servers
    res = pwc.run_check(
        "start", repo=str(tmp_path), symbol="auth_token",
        env=_env(token=tmp_path / "t.json", symbol="auth_token"),
        git=FakeGit(),
        gh=_gh(gh, closed=[{"number": 4800, "title": "auth token fixed"}]),
        board=_board(sb, [_card()]),
        guard=lambda repo, env, timeout:
            "checkout-guard VERDICT: CLEAR checkout up-to-date\n",
        now=NOW)
    assert res.verdict == "DUP_FIX"
    assert "4800" in res.details
    assert not (tmp_path / "t.json").exists()


def test_c1_board_same_issue_dup_fix(servers, tmp_path):
    gh, sb = servers
    res = pwc.run_check(
        "start", repo=str(tmp_path), symbol="auth_token",
        env=_env(token=tmp_path / "t.json", symbol="auth_token"),
        git=FakeGit(), gh=_gh(gh, closed=[]),
        board=_board(sb, [_card("card-a"), _card("card-b", lease=600)]),
        guard=lambda repo, env, timeout:
            "checkout-guard VERDICT: CLEAR checkout up-to-date\n",
        now=NOW)
    assert res.verdict == "DUP_FIX"
    assert "card-b" in res.details


def test_c1_board_unreachable_unknown(servers, tmp_path):
    gh, _ = servers
    dead = pwc.BoardRest("http://127.0.0.1:1", "k", 1.0)
    token = tmp_path / "t.json"
    res = pwc.run_check(
        "start", repo=str(tmp_path), env=_env(token=token),
        git=FakeGit(), gh=_gh(gh, closed=[]), board=dead,
        guard=lambda repo, env, timeout:
            "checkout-guard VERDICT: CLEAR checkout up-to-date\n",
        now=NOW)
    assert res.verdict == "UNKNOWN"
    assert not token.exists()


def test_c1_git_fetch_fail_unknown(servers, tmp_path):
    gh, sb = servers
    res = pwc.run_check(
        "start", repo=str(tmp_path / "nope"), env=_env(token=tmp_path / "t.json"),
        git=FakeGit(fetch_raises=True), gh=_gh(gh), board=_board(sb, [_card()]),
        guard=lambda repo, env, timeout: "checkout-guard VERDICT: CLEAR\n",
        now=NOW)
    assert res.verdict == "UNKNOWN"
    assert "git-fetch" in res.details


# ── C2 unit: intent write, live overlap, expired-lease filter ─

def test_c2_writes_touched_paths_and_clears(servers, tmp_path):
    gh, sb = servers
    store, db = _store([_card()])
    token = tmp_path / "t.json"
    res = pwc.run_check(
        "scope", repo=str(tmp_path), env=_env(token=token),
        git=FakeGit(), gh=_gh(gh), board=_board(sb, [_card()]),
        store=store, now=NOW)
    assert res.verdict == "CLEAR"
    assert db.card("card-a")["touched_paths"] == ["src/auth.py"]
    assert token.exists()


def test_c2_live_overlap_blocking(servers, tmp_path):
    gh, sb = servers
    store, _ = _store([_card()])
    res = pwc.run_check(
        "scope", repo=str(tmp_path), env=_env(token=tmp_path / "t.json"),
        git=FakeGit(), gh=_gh(gh),
        board=_board(sb, [_card("card-a"), _card("card-b", lease=600)]),
        store=store, now=NOW)
    assert res.verdict == "OVERLAP"
    assert "card-b" in res.details
    assert "split" in res.options and "notify-owner" in res.options


def test_c2_expired_lease_filtered_out(servers, tmp_path):
    """E2E-1 expired-lease negative: lease_expires_at <= now → NOT live."""
    gh, sb = servers
    store, _ = _store([_card()])
    expired = _card("card-b", lease=-60)  # expired 60s ago
    assert pwc._lease_live(expired, NOW) is False
    res = pwc.run_check(
        "scope", repo=str(tmp_path), env=_env(token=tmp_path / "t.json"),
        git=FakeGit(), gh=_gh(gh),
        board=_board(sb, [_card("card-a"), expired]),
        store=store, now=NOW)
    assert res.verdict == "CLEAR"


def test_c2_missing_lease_filtered_out(servers, tmp_path):
    gh, sb = servers
    store, _ = _store([_card()])
    no_lease = _card("card-b", lease=None)
    res = pwc.run_check(
        "scope", repo=str(tmp_path), env=_env(token=tmp_path / "t.json"),
        git=FakeGit(), gh=_gh(gh),
        board=_board(sb, [_card("card-a"), no_lease]),
        store=store, now=NOW)
    assert res.verdict == "CLEAR"


def test_c2_store_not_holder_unknown(servers, tmp_path):
    gh, sb = servers
    store, _ = _store([_card("card-a", claimed="other-agent")])
    res = pwc.run_check(
        "scope", repo=str(tmp_path), env=_env(token=tmp_path / "t.json"),
        git=FakeGit(), gh=_gh(gh), board=_board(sb, [_card("card-a")]),
        store=store, now=NOW)
    assert res.verdict == "UNKNOWN"
    assert "not-holder" in res.details


def test_c2_missing_card_context_unknown(tmp_path):
    res = pwc.run_check(
        "scope", repo=str(tmp_path), env=_env(card_id="", token=tmp_path / "t.json"),
        git=FakeGit(), now=NOW)
    assert res.verdict == "UNKNOWN"
    assert "missing-card-context" in res.details


# ── C2 symbol booster: advisory vs blocking (Gate A caveat) ───

def test_c2_history_overlap_advisory_without_symbol(tmp_path):
    """Raw 72h path overlap with no symbol → CLEAR (noise caveat)."""
    repo, _ = _make_repo(tmp_path)
    (repo / "src").mkdir()
    (repo / "src" / "auth.py").write_text("def auth_token(): pass\n")
    _git("add", ".", cwd=repo)
    _git("commit", "-m", "auth work", cwd=repo)
    base = _rev(repo)  # card base_commit includes the overlapping commit
    store, _ = _store([_card("card-a", base=base)])
    res = pwc.run_check(
        "scope", repo=str(repo), env=_env(token=tmp_path / "t.json"),
        git=None, gh=_gh(_serve()), board=_board(_serve(), [_card("card-a", base=base)]),
        store=store, now=NOW)
    assert res.verdict == "CLEAR"
    assert "advisory-history-overlap" in res.details


def test_c2_symbol_booster_confirmed_blocking_overlap(tmp_path):
    repo, _ = _make_repo(tmp_path)
    (repo / "src").mkdir()
    (repo / "src" / "auth.py").write_text("def auth_token(): pass\n")
    _git("add", ".", cwd=repo)
    _git("commit", "-m", "auth work", cwd=repo)
    base = _rev(repo)  # card base_commit includes the overlapping commit
    store, _ = _store([_card("card-a", base=base)])
    res = pwc.run_check(
        "scope", repo=str(repo), symbol="auth_token",
        env=_env(token=tmp_path / "t.json", symbol="auth_token"),
        gh=_gh(_serve(), closed=[]),
        board=_board(_serve(), [_card("card-a", base=base)]),
        store=store, now=NOW)
    assert res.verdict == "OVERLAP"
    assert "symbol-booster-confirmed" in res.details


# ── C3: open-PR search ─────────────────────────────────────────

def test_c3_open_pr_overlap(servers, tmp_path):
    gh, sb = servers
    res = pwc.run_check(
        "plan", repo=str(tmp_path), env=_env(token=tmp_path / "t.json"),
        git=FakeGit(),
        gh=_gh(gh, prs=[{"number": 5210, "title": "auth rewrite"}]),
        board=_board(sb, [_card("card-a", touched=("src/auth.py",))]),
        now=NOW)
    assert res.verdict == "OVERLAP"
    assert "5210" in res.details
    assert "rebase" in res.options and "notify-owner" in res.options


def test_c3_no_open_prs_clear(servers, tmp_path):
    gh, sb = servers
    res = pwc.run_check(
        "plan", repo=str(tmp_path), env=_env(token=tmp_path / "t.json"),
        git=FakeGit(), gh=_gh(gh, prs=[]),
        board=_board(sb, [_card("card-a", touched=("src/auth.py",))]),
        now=NOW)
    assert res.verdict == "CLEAR"


# ── C4: behind, base-drift, -S re-check ────────────────────────

def test_c4_behind_origin_stale(tmp_path):
    repo, origin = _make_repo(tmp_path)
    _advance_origin(tmp_path, origin)
    base = _rev(repo)  # local HEAD (now behind)
    res = pwc.run_check(
        "implement", repo=str(repo),
        env=_env(token=tmp_path / "t.json"),
        board=_board(_serve(), [_card("card-a", base=base)]),
        gh=_gh(_serve(), prs=[]), now=NOW)
    assert res.verdict == "STALE"
    assert "behind-origin" in res.details


def test_c4_base_commit_drift_stale(tmp_path):
    """base_commit not an ancestor of (rewritten) origin/main → STALE."""
    repo, origin = _make_repo(tmp_path)
    # main: c1(root) → c2; the agent claims with base_commit = c2.
    scratch = tmp_path / "scratch"
    _git("clone", str(origin), str(scratch))
    _git("config", "user.email", "pwc-test@example.com", cwd=scratch)
    _git("config", "user.name", "PWC Test", cwd=scratch)
    (scratch / "extra.txt").write_text("v1\n")
    _git("add", "extra.txt", cwd=scratch)
    _git("commit", "-m", "c2", cwd=scratch)
    _git("push", "origin", "main", cwd=scratch)
    _git("fetch", "origin", "main", cwd=repo)
    _git("reset", "--hard", "origin/main", cwd=repo)
    base = _rev(repo)  # c2
    # Rewrite main tip (amend c2 → c2') so base drops out of main's history.
    (scratch / "extra.txt").write_text("rewritten\n")
    _git("add", "extra.txt", cwd=scratch)
    _git("commit", "--amend", "--no-edit", cwd=scratch)
    _git("push", "--force", "origin", "main", cwd=scratch)
    # Agent side: commit work on top of base, then merge origin/main so the
    # behind-count is 0 while base stays outside origin/main's history.
    (repo / "work.txt").write_text("w\n")
    _git("add", "work.txt", cwd=repo)
    _git("commit", "-m", "work", cwd=repo)
    _git("fetch", "origin", "main", cwd=repo)
    # -X theirs: the rewritten extra.txt wins — the merge conflict is a
    # fixture artifact, not what this test asserts (the drift check is).
    _git("merge", "origin/main", "--no-edit", "-X", "theirs", cwd=repo)
    assert _git("rev-list", "--count", "HEAD..origin/main",
                cwd=repo).stdout.strip() == "0"
    res = pwc.run_check(
        "implement", repo=str(repo), env=_env(token=tmp_path / "t.json"),
        board=_board(_serve(), [_card("card-a", base=base)]),
        gh=_gh(_serve(), prs=[]), now=NOW)
    assert res.verdict == "STALE"
    assert "base-commit-drift" in res.details


def test_c4_symbol_recheck_dup_fix(tmp_path):
    """git log -S symbol in 14d on origin/main → DUP_FIX (E2E-3)."""
    repo, origin = _make_repo(tmp_path)
    scratch = tmp_path / "scratch"
    _git("clone", str(origin), str(scratch))
    _git("config", "user.email", "pwc-test@example.com", cwd=scratch)
    _git("config", "user.name", "PWC Test", cwd=scratch)
    (scratch / "src").mkdir(exist_ok=True)
    (scratch / "src" / "auth.py").write_text("def auth_token(): pass\n")
    _git("add", ".", cwd=scratch)
    _git("commit", "-m", "add auth_token", cwd=scratch)
    _git("push", "origin", "main", cwd=scratch)
    _git("fetch", "origin", "main", cwd=repo)
    _git("reset", "--hard", "origin/main", cwd=repo)
    base = _rev(repo)
    res = pwc.run_check(
        "implement", repo=str(repo), symbol="auth_token",
        env=_env(token=tmp_path / "t.json", symbol="auth_token"),
        board=_board(_serve(), [_card("card-a", base=base)]),
        gh=_gh(_serve(), prs=[]), now=NOW)
    assert res.verdict == "DUP_FIX"
    assert "symbol-recheck" in res.details


def test_c4_symbol_recheck_clean(tmp_path):
    repo, _ = _make_repo(tmp_path)
    base = _rev(repo)
    res = pwc.run_check(
        "implement", repo=str(repo), symbol="no_such_symbol",
        env=_env(token=tmp_path / "t.json", symbol="no_such_symbol"),
        board=_board(_serve(), [_card("card-a", base=base)]),
        gh=_gh(_serve(), prs=[]), now=NOW)
    assert res.verdict == "CLEAR"


# ── C5: merge orchestration (release + notify + events + advance) ──

def test_c5_full_merge_pass(servers, tmp_path):
    """Overlapping owner → release_and_notify + overlap_decision; release;
    checkpoint_pass; advance_phase implementing→done; token on CLEAR."""
    gh, sb = servers
    store, db = _store([
        _card("card-a", phase="implementing"),
        _card("card-b", lease=600),
    ])
    token = tmp_path / "t.json"
    res = pwc.run_check(
        "merge", repo=str(tmp_path), env=_env(token=token),
        git=FakeGit(), gh=_gh(gh),
        board=_board(sb, [_card("card-a", phase="implementing"),
                          _card("card-b", lease=600)]),
        store=store, now=NOW)
    assert res.verdict == "CLEAR"
    card_a = db.card("card-a")
    assert card_a["touched_paths"] is None
    assert card_a["lease_expires_at"] is None
    assert card_a["phase"] == "done"
    events = [e["event_type"] for e in db.tables["card_events"]]
    assert "notify" in events and "overlap_decision" in events
    assert "checkpoint_pass" in events
    notify_payloads = [json.loads(e["payload"]) for e in db.tables["card_events"]
                       if e["event_type"] == "notify"]
    assert any(p.get("reason") == "overlap-after-merge"
               and p.get("from_card") == "card-b" for p in notify_payloads)
    decision_payloads = [json.loads(e["payload"]) for e in db.tables["card_events"]
                         if e["event_type"] == "overlap_decision"]
    assert any(p.get("other_card") == "card-b"
               and p.get("decision") == "notify" for p in decision_payloads)
    assert token.exists()


def test_c5_no_overlaps_no_notify(servers, tmp_path):
    gh, sb = servers
    store, db = _store([_card("card-a", phase="implementing")])
    res = pwc.run_check(
        "merge", repo=str(tmp_path), env=_env(token=tmp_path / "t.json"),
        git=FakeGit(), gh=_gh(gh),
        board=_board(sb, [_card("card-a", phase="implementing")]),
        store=store, now=NOW)
    assert res.verdict == "CLEAR"
    events = [e["event_type"] for e in db.tables["card_events"]]
    assert "notify" not in events and "overlap_decision" not in events
    assert "checkpoint_pass" in events
    assert db.card("card-a")["phase"] == "done"


def test_c5_expired_overlap_not_notified(servers, tmp_path):
    gh, sb = servers
    store, db = _store([_card("card-a", phase="implementing")])
    res = pwc.run_check(
        "merge", repo=str(tmp_path), env=_env(token=tmp_path / "t.json"),
        git=FakeGit(), gh=_gh(gh),
        board=_board(sb, [_card("card-a", phase="implementing"),
                          _card("card-b", lease=-60)]),  # expired → not live
        store=store, now=NOW)
    assert res.verdict == "CLEAR"
    assert "notify" not in [e["event_type"] for e in db.tables["card_events"]]


def test_c5_board_unreachable_unknown(servers, tmp_path):
    _, _ = servers
    store, _ = _store([_card("card-a", phase="implementing")])
    dead = pwc.BoardRest("http://127.0.0.1:1", "k", 1.0)
    token = tmp_path / "t.json"
    res = pwc.run_check(
        "merge", repo=str(tmp_path), env=_env(token=token),
        git=FakeGit(), gh=_gh(_serve()), board=dead, store=store, now=NOW)
    assert res.verdict == "UNKNOWN"
    assert not token.exists()


# ── UNKNOWN: script-error and budget ───────────────────────────

def test_script_error_unknown(servers, tmp_path):
    gh, sb = servers
    token = tmp_path / "t.json"
    token.write_text("stale-token")

    class ExplodingStore:
        def update_touched_paths(self, *a, **k):
            raise ValueError("boom")

    res = pwc.run_check(
        "scope", repo=str(tmp_path), env=_env(token=token),
        git=FakeGit(), gh=_gh(gh), board=_board(sb, [_card()]),
        store=ExplodingStore(), now=NOW)
    assert res.verdict == "UNKNOWN"
    assert "script-error" in res.details
    assert not token.exists()  # UNKNOWN removes any stale token


def test_budget_overrun_unknown(servers, tmp_path):
    """>budget → UNKNOWN (E2E-8): GitHub REST slower than the 0.3s budget."""
    gh, sb = servers
    gh.routes["state:closed"] = {"payload": {"total_count": 0, "items": []},
                                  "sleep": 1.0}
    token = tmp_path / "t.json"
    res = pwc.run_check(
        "start", repo=str(tmp_path), symbol="auth_token",
        env=_env(token=token, timeout="0.3", symbol="auth_token"),
        git=FakeGit(), gh=pwc.GhRest(_url(gh), "t", 5.0),
        board=_board(sb, [_card()]),
        guard=lambda repo, env, timeout:
            "checkout-guard VERDICT: CLEAR checkout up-to-date\n",
        now=NOW)
    assert res.verdict == "UNKNOWN"
    assert not token.exists()


# ── bash wrapper end-to-end ────────────────────────────────────

def _bash_env(gh_url, sb_url, tmp_path, token, timeout="10"):
    return {
        **os.environ,
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
        "PYTHON_BIN": PYTHON,
        "GH_API_BASE": gh_url,
        "GH_TOKEN": "test-token",
        "PARALLEL_CHECK_SB_URL": sb_url,
        "PARALLEL_CHECK_SB_KEY": "test-key",
        "SUPABASE_URL_ORG_DATA": sb_url,
        "SUPABASE_SERVICE_ROLE_KEY_ORG_DATA": "test-key",
        "PARALLEL_CHECK_REPO_SLUG": "daniel-ospina/swarm",
        "PARALLEL_CHECK_TOKEN_FILE": str(token),
        "PARALLEL_CHECK_TIMEOUT_SECS": timeout,
        "SWARM_CARD_ID": "card-a",
        "AGENT_ID": "agent-a",
        "SWARM_TOUCHED_PATHS": "src/auth.py",
        "HEARTBEAT_EVENTS_FILE": str(tmp_path / "no-events.jsonl"),
        "CHECKOUT_GUARD_LOG": str(tmp_path / "guard.log"),
    }


def _run_bash(tmp_path, phase, repo, env, symbol=None):
    cmd = ["bash", str(CHECK_SH), phase, "--repo", str(repo)]
    if symbol:
        cmd += ["--symbol", symbol]
    proc = subprocess.run(cmd, capture_output=True, text=True, env=env,
                          timeout=60)
    return proc


def test_bash_c1_clear_end_to_end(tmp_path):
    repo, _ = _make_repo(tmp_path)
    gh, sb = _serve(), _serve()
    token = tmp_path / "token.json"
    _gh(gh, closed=[], prs=[])
    _board(sb, [_card()])
    env = _bash_env(_url(gh), _url(sb), tmp_path, token)
    env["CHECKOUT_GUARD_SWARM_ROOT"] = str(repo)  # fixture IS the swarm root (per-repo policy)
    proc = _run_bash(tmp_path, "start", repo, env, symbol="auth_token")
    assert proc.returncode == 0
    line = proc.stdout.strip().splitlines()[0]
    assert line.startswith("C1: CLEAR"), line
    assert "options=" in line
    assert json.loads(token.read_text())["code"] == "C1"


def test_bash_c1_stale_end_to_end(tmp_path):
    """E2E-2: behind origin/main → C1: STALE via checkout_guard delegation."""
    repo, origin = _make_repo(tmp_path)
    _advance_origin(tmp_path, origin)
    gh, sb = _serve(), _serve()
    token = tmp_path / "token.json"
    _gh(gh, closed=[])
    _board(sb, [_card()])
    env = _bash_env(_url(gh), _url(sb), tmp_path, token)
    env["CHECKOUT_GUARD_SWARM_ROOT"] = str(repo)  # per-repo policy: this fixture IS the swarm root
    proc = _run_bash(tmp_path, "start", repo, env)
    assert proc.returncode == 0
    line = proc.stdout.strip().splitlines()[0]
    assert line.startswith("C1: STALE"), line
    assert not token.exists()


def _has_supabase_v2() -> bool:
    """The bash C2 E2E path exercises the REAL #4903 store (supabase-py)."""
    try:
        from supabase import create_client  # noqa: F401
        return True
    except ImportError:
        return False


@pytest.mark.skipif(not _has_supabase_v2(),
                    reason="supabase-py v2 required for the real #4903 store")
def test_bash_c2_expired_lease_ignored_live_overlap_blocks(tmp_path):
    repo, _ = _make_repo(tmp_path)
    gh, sb = _serve(), _serve()
    _gh(gh, closed=[], prs=[])
    # the real #4903 store resolves its org against this mock
    sb.routes["/rest/v1/organizations"] = {
        "payload": [{"id": "org-1", "slug": "apresto"}]}
    sb.patch_routes["/rest/v1/cards"] = {"payload": [{"id": "card-a"}]}
    # card-b lease EXPIRED → not live → CLEAR
    _board(sb, [_card("card-a"), _card("card-b", lease=-60)])
    env = _bash_env(_url(gh), _url(sb), tmp_path, tmp_path / "token.json")
    proc = _run_bash(tmp_path, "scope", repo, env)
    assert proc.returncode == 0
    assert proc.stdout.strip().splitlines()[0].startswith("C2: CLEAR")
    # card-b lease LIVE + overlapping touched_paths → OVERLAP
    _board(sb, [_card("card-a"), _card("card-b", lease=600)])
    proc = _run_bash(tmp_path, "scope", repo, env)
    assert proc.returncode == 0
    line = proc.stdout.strip().splitlines()[0]
    assert line.startswith("C2: OVERLAP"), line


@pytest.mark.xfail(strict=False, reason="known swarm-main failure — timeout-mock race; upstream fix tracked (swarm issue filed); vendored parity 32/1/1 — on the vendored layout this test PASSES deterministically (xpass under strict=False); the sibling test_bash_timeout_contract owns the timeout contract")
def test_bash_timeout_unknown_and_exit_zero(tmp_path):
    """E2E-8: budget overrun → UNKNOWN verdict line, exit 0, no token."""
    repo, _ = _make_repo(tmp_path)
    gh, sb = _serve(), _serve()
    _gh(gh, closed=[{"number": 1, "title": "x"}])
    gh.routes["state:closed"]["sleep"] = 2.0
    _board(sb, [_card()])
    token = tmp_path / "token.json"
    env = _bash_env(_url(gh), _url(sb), tmp_path, token, timeout="0.3")
    proc = _run_bash(tmp_path, "start", repo, env, symbol="auth_token")
    assert proc.returncode == 0
    line = proc.stdout.strip().splitlines()[0]
    assert line.startswith("C1: UNKNOWN"), line
    assert not token.exists()


def test_bash_missing_phase_unknown_exit_zero(tmp_path):
    proc = subprocess.run(["bash", str(CHECK_SH)], capture_output=True,
                          text=True, env=os.environ, timeout=30)
    assert proc.returncode == 0
    assert proc.stdout.strip().splitlines()[0].startswith("C?: UNKNOWN")


def test_bash_timeout_contract(tmp_path):
    """#383: deterministic sibling for the xfail'd swarm-flaky timeout test —
    the bash-level watchdog contract owned here: budget overrun → C1: UNKNOWN
    first line, exit 0, NO token written. The xfail (strict=False) is
    satisfied by both pass and fail, so this sibling is the load-bearing
    assertion (a regression that hangs or writes a token on timeout would
    otherwise be CI-green indefinitely).
    """
    repo, _ = _make_repo(tmp_path)
    gh, sb = _serve(), _serve()
    _gh(gh, closed=[{"number": 1, "title": "x"}])
    gh.routes["state:closed"]["sleep"] = 2.0
    _board(sb, [_card()])
    token = tmp_path / "token.json"
    env = _bash_env(_url(gh), _url(sb), tmp_path, token, timeout="0.05")
    proc = _run_bash(tmp_path, "start", repo, env, symbol="auth_token")
    assert proc.returncode == 0
    line = proc.stdout.strip().splitlines()[0]
    assert line.startswith("C1: UNKNOWN"), line
    assert not token.exists()


def _fake_interpreter(tmp_path, body: str) -> Path:
    """#383: a fake PYTHON_BIN the .sh wrapper executes (it ignores argv).
    Simulates the python side for watchdog error-branch tests."""
    fake = tmp_path / "fake_interp.sh"
    fake.write_text("#!/usr/bin/env bash\nset -u\n" + body + "\n")
    fake.chmod(0o755)
    return fake


def test_bash_watchdog_unlink_on_hang(tmp_path):
    """#383: write-then-hang watchdog window — python writes a CLEAR token
    (and a mid-write unique tmp) then blocks; the watchdog SIGKILLs it
    (skipping python's own cleanup); the .sh error branch must unlink the
    token AND the scoped tmp, emit UNKNOWN, exit 0."""
    token = tmp_path / "token.json"
    fake = _fake_interpreter(tmp_path, f'''
TOKEN="${{PARALLEL_CHECK_TOKEN_FILE:-{token}}}"
printf '%s' '{{"phase":"start","verdict":"CLEAR","code":"C1","ts":1}}' > "$TOKEN"
printf x > "$TOKEN.tmp.$$"
sleep 30
''')
    env = dict(os.environ)
    env["PYTHON_BIN"] = str(fake)
    env["PARALLEL_CHECK_TOKEN_FILE"] = str(token)
    env["PARALLEL_CHECK_TIMEOUT_SECS"] = "0.1"
    proc = subprocess.run(["bash", str(CHECK_SH), "start"], capture_output=True,
                          text=True, env=env, timeout=30)
    assert proc.returncode == 0
    assert proc.stdout.strip().splitlines()[0].startswith("C1: UNKNOWN")
    assert not token.exists()
    assert not list(tmp_path.glob("token.json.tmp.*"))


def test_bash_watchdog_unlink_on_non_clear_verdict(tmp_path):
    """#383: UNKNOWN verdicts exit 0 by design — a token surviving a
    non-CLEAR verdict would let the enforcer's marker advance (which reads
    only the token) pass a check the operator just saw fail. The .sh must
    unlink the token on any non-CLEAR first line, not just rc != 0."""
    token = tmp_path / "token.json"
    fake = _fake_interpreter(tmp_path, f'''
TOKEN="${{PARALLEL_CHECK_TOKEN_FILE:-{token}}}"
printf '%s' '{{"phase":"start","verdict":"CLEAR","code":"C1","ts":1}}' > "$TOKEN"
echo "C1: UNKNOWN  fake  options="
exit 0
''')
    env = dict(os.environ)
    env["PYTHON_BIN"] = str(fake)
    env["PARALLEL_CHECK_TOKEN_FILE"] = str(token)
    env["PARALLEL_CHECK_TIMEOUT_SECS"] = "1"
    proc = subprocess.run(["bash", str(CHECK_SH), "start"], capture_output=True,
                          text=True, env=env, timeout=30)
    assert proc.returncode == 0
    assert proc.stdout.strip().splitlines()[0].startswith("C1: UNKNOWN")
    assert not token.exists()
