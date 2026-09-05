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
from uuid import uuid4

import pytest

_REPO_ROOT = Path(__file__).resolve().parent.parent  # agent-infra
# Vendored layout: scripts/ lives ONE level under the repo root (agent-infra)
# — the swarm `parent.parent.parent` resolves to the repo's PARENT here and
# `_REPO_ROOT / "tests"` doesn't exist (fake_supabase.py lives IN scripts/);
# both inserts are dead under pytest. Insert the agent-infra root so
# `fake_supabase`'s own `from connectors.supabase_swarm import` resolves
# (the standalone probe `cd scripts && python3 -c "import
# test_parallel_work_check"` relies on it); parallel_work_check.py resolves
# from scripts/ itself.
sys.path.insert(0, str(_REPO_ROOT))

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

    def __init__(self, fetch_raises=False, remote="unknown"):
        self.fetch_raises = fetch_raises
        self.remote = remote

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

    def _run_ok(self, args, timeout):
        """#383: no git config in fixtures — the slug falls back to ''."""
        return None

    def remote_url(self, timeout=5.0):
        """#383: token repo of the resolved ops target (URL form, 'unknown'
        when undeterminable — B18/B22/B26/B32 pin real-git resolution)."""
        return self.remote


class RecordingGit(FakeGit):
    """FakeGit that records which git operations ran (B10/B11/B25)."""

    def __init__(self, picks=None, **kw):
        super().__init__(**kw)
        self.calls: list = []
        self._picks = picks or {}

    def fetch(self, timeout):
        self.calls.append("fetch")
        super().fetch(timeout)

    def behind(self, timeout):
        self.calls.append("behind")
        return super().behind(timeout)

    def pickaxe(self, symbol, days, rev, timeout):
        self.calls.append(("pickaxe", symbol))
        return self._picks


def _env_noboard(token=None, timeout="5", symbol=None, **extra) -> dict:
    """#383: minimal env with NO board signals — the no-board tenant shape.
    Optional PARALLEL_CHECK_SYMBOL and any extra names ride along."""
    env = {"PARALLEL_CHECK_TIMEOUT_SECS": timeout}
    if token is not None:
        env["PARALLEL_CHECK_TOKEN_FILE"] = str(token)
    if symbol is not None:
        env["PARALLEL_CHECK_SYMBOL"] = symbol
    env.update(extra)
    return env


def _guard_clear(repo=None, env=None, timeout=None):
    return "checkout-guard VERDICT: CLEAR checkout up-to-date\n"


class ThrowingBoard:
    """Board spy that fails the test if called in no-board mode."""

    def list_cards(self, timeout):
        raise AssertionError("board.list_cards called in no-board mode")

    def get_card(self, card_id, timeout):
        raise AssertionError("board.get_card called in no-board mode")


class ThrowingStore:
    """Store spy that fails the test if called in no-board mode."""

    def __getattr__(self, name):
        raise AssertionError(f"store.{name} called in no-board mode")


class OkBoard:
    """Board stub that returns one live card (board-mode fixtures)."""

    def list_cards(self, timeout):
        return [_card()]

    def get_card(self, card_id, timeout):
        return _card()


def _set_origin(repo: Path, url: str) -> None:
    _git("remote", "set-url", "origin", url, cwd=repo)


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

def _git(*args, cwd=None, check=True, env=None) -> subprocess.CompletedProcess:
    cmd = list(args) if cwd is None else ["-C", str(cwd), *args]
    return subprocess.run(["git", *cmd], capture_output=True, text=True,
                          check=check, env=env)


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
    # #388: the mock sleep MUST sit outside the watchdog window (budget+2.0s
    # → watchdog at ~2.3s with the 0.3s budget here) so the watchdog path is
    # deterministic — a real-time race between the mock's response and the
    # watchdog kill is load-dependent (the 5.0s sleep vs the 2.3s watchdog
    # leaves a ~2.7s margin that machine load eats).
    gh.routes["state:closed"]["sleep"] = 5.0
    _board(sb, [_card()])
    token = tmp_path / "token.json"
    env = _bash_env(_url(gh), _url(sb), tmp_path, token, timeout="0.3")
    # #388: without the per-repo-policy fixture the guard DEFERs (recent
    # commits → foreign-activity) and the verdict races the 0.3s budget —
    # loading the guard into the slow-mock timeout path makes the xpass
    # deterministic (the budget deadline clamps the urlopen; UNKNOWN wins).
    env["CHECKOUT_GUARD_SWARM_ROOT"] = str(repo)
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
    # #388: the mock sleep MUST sit outside the watchdog window (budget+2.0s
    # → watchdog at ~2.05s) so the watchdog always fires first and python can
    # never self-write a verdict before the kill. Under the client-timeout
    # model python self-fails-closed at ~0.1s (UNKNOWN, no token) — same
    # asserted contract either way, with no real-time race left to flip it.
    gh.routes["state:closed"]["sleep"] = 5.0
    _board(sb, [_card()])
    token = tmp_path / "token.json"
    env = _bash_env(_url(gh), _url(sb), tmp_path, token, timeout="0.05")
    # #388 (guard-DEFER half): the fixture MUST be the swarm root — without
    # CHECKOUT_GUARD_SWARM_ROOT the tmp repo is a FOREIGN checkout and its
    # fresh commit trips the guard's foreign-activity DEFER (300s grace),
    # short-circuiting C1 to STALE before the slow-GH/timeout path ever runs.
    # That DEFER is load-INDEPENDENT (~always fires); the load-dependent
    # masking was the fetch exceeding the 0.05s budget → UNKNOWN → false pass.
    env["CHECKOUT_GUARD_SWARM_ROOT"] = str(repo)  # per-repo-policy fixture
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


@pytest.mark.parametrize("timeout_val", ["inf", "nan", "1e309"])
def test_bash_watchdog_non_finite_budget_fires(tmp_path, timeout_val):
    """#383 P3: the .sh watchdog's NON-FINITE budget path — a hanging
    python with PARALLEL_CHECK_TIMEOUT_SECS=<non-finite> can never stall
    the watchdog: the raw-string regex gate maps inf/nan → default 2.0 and
    1e309 → overflow-clamped to PARALLEL_CHECK_BUDGET_MAX, so the watchdog
    fires within bounded time (~cap+2s), the error branch unlinks the token,
    the verdict is C1: UNKNOWN, rc 0. (The hang/unlink tests pin the
    hang behavior; this one pins the non-finite budget class specifically —
    the .sh never `sleep inf`.)"""
    token = tmp_path / "token.json"
    fake = _fake_interpreter(tmp_path, f'''
TOKEN="${{PARALLEL_CHECK_TOKEN_FILE:-{token}}}"
printf '%s' '{{"phase":"start","verdict":"CLEAR","code":"C1","ts":1}}' > "$TOKEN"
sleep 30
''')
    env = dict(os.environ)
    env["PYTHON_BIN"] = str(fake)
    env["PARALLEL_CHECK_TOKEN_FILE"] = str(token)
    env["PARALLEL_CHECK_TIMEOUT_SECS"] = timeout_val
    env["PARALLEL_CHECK_BUDGET_MAX"] = "0.2"
    t0 = time.monotonic()
    proc = subprocess.run(["bash", str(CHECK_SH), "start"], capture_output=True,
                          text=True, env=env, timeout=30)
    elapsed = time.monotonic() - t0
    assert elapsed < 10.0, \
        f"non-finite budget stalled the watchdog: {elapsed:.1f}s"
    assert proc.returncode == 0
    assert proc.stdout.strip().splitlines()[0].startswith("C1: UNKNOWN")
    assert not token.exists()


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


# ══════════════════════════════════════════════════════════════════════
# #383 B-series — no-board predicate + distinguishable skip (Phase B, TDD)
# ══════════════════════════════════════════════════════════════════════

# ── B1-B5: C1 no-board skip + retained checks + negative fences ──────

def test_b1_c1_no_board_skip_clears(tmp_path):
    """no-board C1: fetch/guard/dup-search retained, board scan skipped →
    CLEAR no-board-skip; the board spy must never fire."""
    token = tmp_path / "t.json"
    res = pwc.run_check(
        "start", repo=str(tmp_path), env=_env_noboard(token=token),
        git=FakeGit(), gh=ThrowingBoard(), board=ThrowingBoard(),
        guard=_guard_clear, now=NOW)
    assert res.verdict == "CLEAR"
    assert "no-board-skip" in res.details
    assert res.mode == "no-board-skip"
    assert token.exists()


def test_b2_c1_no_board_guard_stale_still_wins(tmp_path):
    """guard STALE precedes the skip — a stale no-board checkout never
    skip-CLEARs."""
    token = tmp_path / "t.json"
    res = pwc.run_check(
        "start", repo=str(tmp_path), env=_env_noboard(token=token),
        git=FakeGit(), board=ThrowingBoard(),
        guard=lambda repo, env, timeout:
            "checkout-guard VERDICT: STALE behind origin/main\n",
        now=NOW)
    assert res.verdict == "STALE"
    assert "no-board-skip" not in res.details
    assert not token.exists()


def test_b3_c1_no_board_dup_search_still_runs(servers, tmp_path):
    """DUP_FIX precedes the skip — the closed-issue dup-search is retained
    in no-board mode."""
    gh, _ = servers
    token = tmp_path / "t.json"
    env = _env_noboard(token=token, symbol="auth_token",
                       PARALLEL_CHECK_REPO_SLUG="daniel-ospina/swarm")
    res = pwc.run_check(
        "start", repo=str(tmp_path), env=env, git=FakeGit(),
        gh=_gh(gh, closed=[{"number": 4800, "title": "auth token fixed"}]),
        board=ThrowingBoard(), guard=_guard_clear, now=NOW)
    assert res.verdict == "DUP_FIX"
    assert "4800" in res.details
    assert "no-board-skip" not in res.details


def test_b4_c1_negative_fence_agent_only(tmp_path):
    """AGENT_ID only → NOT no-board → fail-closed UNKNOWN (never skip)."""
    token = tmp_path / "t.json"
    env = _env_noboard(token=token, AGENT_ID="agent-a")
    assert pwc._is_no_board(env) is False
    res = pwc.run_check("start", repo=str(tmp_path), env=env, git=FakeGit(),
                        guard=_guard_clear, now=NOW)
    assert res.verdict == "UNKNOWN"
    assert "no-board-skip" not in res.details


def test_b5_c1_negative_fence_card_only(tmp_path):
    """CARD_ID only → NOT no-board → fail-closed UNKNOWN (never skip)."""
    token = tmp_path / "t.json"
    env = _env_noboard(token=token, CARD_ID="card-a")
    assert pwc._is_no_board(env) is False
    res = pwc.run_check("start", repo=str(tmp_path), env=env, git=FakeGit(),
                        guard=_guard_clear, now=NOW)
    assert res.verdict == "UNKNOWN"
    assert "no-board-skip" not in res.details


# ── B6-B7: C2 no-board skip + negative fence ─────────────────────────

def test_b6_c2_no_board_skip(tmp_path):
    """no-board C2: claim/overlap checks skipped — zero store calls."""
    token = tmp_path / "t.json"
    res = pwc.run_check("scope", repo=str(tmp_path),
                        env=_env_noboard(token=token), git=FakeGit(),
                        store=ThrowingStore(), now=NOW)
    assert res.verdict == "CLEAR"
    assert "no-board-skip" in res.details
    assert token.exists()


def test_b7_c2_negative_fence_agent_only(tmp_path):
    """board present + agent signal, card absent → missing-card-context
    UNKNOWN (the retained guard fires, never a skip)."""
    token = tmp_path / "t.json"
    env = _env_noboard(token=token, AGENT_ID="agent-a",
                       SUPABASE_URL="https://x.supabase.co",
                       SUPABASE_SERVICE_ROLE_KEY="k")
    assert pwc._is_no_board(env) is False
    res = pwc.run_check("scope", repo=str(tmp_path), env=env, git=FakeGit(),
                        store=ThrowingStore(), now=NOW)
    assert res.verdict == "UNKNOWN"
    assert "missing-card-context" in res.details


# ── B8-B9: C3 no-board skip + negative fence ─────────────────────────

def test_b8_c3_no_board_skip(tmp_path):
    """no-board C3: open-PR overlap check skipped — GH never called."""
    token = tmp_path / "t.json"
    res = pwc.run_check("plan", repo=str(tmp_path),
                        env=_env_noboard(token=token), git=FakeGit(),
                        gh=ThrowingBoard(), now=NOW)
    assert res.verdict == "CLEAR"
    assert "no-board-skip" in res.details
    assert token.exists()


def test_b9_c3_negative_fence_paths_no_card(tmp_path):
    """paths claimed + board present, no card → UNKNOWN (vacuous CLEAR
    deleted — B24's sibling; here the paths claim is the fence)."""
    token = tmp_path / "t.json"
    env = _env_noboard(token=token, TOUCHED_PATHS="src/auth.py",
                       SUPABASE_URL="https://x.supabase.co",
                       SUPABASE_ANON_KEY="k")
    res = pwc.run_check("plan", repo=str(tmp_path), env=env, git=FakeGit(),
                        gh=ThrowingBoard(), now=NOW)
    assert res.verdict == "UNKNOWN"
    assert "missing-card-context" in res.details
    assert "no-board-skip" not in res.details


# ── B10-B12: C4 no-board skip, pickaxe hoist, negative fence ─────────

def test_b10_c4_no_board_skip(tmp_path):
    """no-board C4: fetch+behind+symbol-gated pickaxe run → skip-CLEAR."""
    git = RecordingGit()
    token = tmp_path / "t.json"
    env = _env_noboard(token=token, symbol="auth_token")
    res = pwc.run_check("implement", repo=str(tmp_path), env=env, git=git,
                        now=NOW)
    assert res.verdict == "CLEAR"
    assert "no-board-skip" in res.details
    assert "fetch" in git.calls and "behind" in git.calls
    assert ("pickaxe", "auth_token") in git.calls
    assert token.exists()


def test_b11_c4_no_board_pickaxe_dup(tmp_path):
    """no-board C4 + symbol hits → DUP_FIX — the hoisted pickaxe runs before
    any card gate."""
    git = RecordingGit(picks={"abc123": {"src/auth.py"}})
    token = tmp_path / "t.json"
    env = _env_noboard(token=token, symbol="auth_token")
    res = pwc.run_check("implement", repo=str(tmp_path), env=env, git=git,
                        now=NOW)
    assert res.verdict == "DUP_FIX"
    assert "symbol-recheck" in res.details
    assert ("pickaxe", "auth_token") in git.calls
    assert not token.exists()


def test_b12_c4_negative_fence_board_no_card(tmp_path):
    """board present, no card → C4 UNKNOWN missing-card-context (the dead
    no-card CLEAR is removed — B24)."""
    token = tmp_path / "t.json"
    env = _env_noboard(token=token, SUPABASE_URL="https://x.supabase.co",
                       SUPABASE_ANON_KEY="k")
    res = pwc.run_check("implement", repo=str(tmp_path), env=env,
                        git=FakeGit(), now=NOW)
    assert res.verdict == "UNKNOWN"
    assert "missing-card-context" in res.details
    assert "no-board-skip" not in res.details
    assert not token.exists()


# ── B13: C5 no-board skip ────────────────────────────────────────────

def test_b13_c5_no_board_skip(tmp_path):
    """no-board C5: merge orchestration skipped — zero store calls."""
    token = tmp_path / "t.json"
    res = pwc.run_check("merge", repo=str(tmp_path),
                        env=_env_noboard(token=token), git=FakeGit(),
                        store=ThrowingStore(), now=NOW)
    assert res.verdict == "CLEAR"
    assert "no-board-skip" in res.details
    assert token.exists()


# ── B14-B15: token mode/repo + distinguishable contract ──────────────

def test_b14_skip_token_mode_and_repo(tmp_path):
    """no-board skip token: mode == 'no-board-skip', repo == the resolved
    ops target's remote (URL form via remote get-url)."""
    repo, _ = _make_repo(tmp_path)
    remote = _git("remote", "get-url", "origin", cwd=repo).stdout.strip()
    token = tmp_path / "t.json"
    res = pwc.run_check("plan", repo=str(repo), env=_env_noboard(token=token),
                        now=NOW)
    assert res.verdict == "CLEAR"
    assert "no-board-skip" in res.details
    payload = json.loads(token.read_text())
    assert payload["mode"] == "no-board-skip"
    assert payload["repo"] == remote
    assert payload["verdict"] == "CLEAR"


def test_b15_distinguishable_verdict_contract(tmp_path):
    """_skip's line is never byte-identical to the plain board-mode CLEAR —
    it carries CLEAR + the no-board-skip advisory (the audit-visible
    distinction)."""
    token = tmp_path / "t.json"
    env = _env_noboard(token=token)
    res = pwc.run_check("start", repo=str(tmp_path), env=env, git=FakeGit(),
                        guard=_guard_clear, now=NOW)
    line = res.line()
    assert "CLEAR" in line and "no-board-skip" in line
    board_env = _env(token=token)
    res_board = pwc.run_check("start", repo=str(tmp_path), env=board_env,
                              git=FakeGit(), gh=_gh(_serve(), closed=[]),
                              board=_board(_serve(), [_card()]),
                              guard=_guard_clear, now=NOW)
    assert res_board.verdict == "CLEAR"
    assert res_board.mode == ""
    assert "no-board-skip" not in res_board.line()
    assert res_board.line() != line


# ── B16-B17: real .sh no-board e2e + realistic consumer probe ────────

def _noboard_bash_env(gh, sb, tmp_path, token, timeout="6"):
    """_bash_env with every board signal stripped — the no-board tenant.

    timeout default 6 (P3, flake #392): a SAFE budget for the ~278ms warm
    real-python pipeline — the old 0.5s left only ~220ms headroom on the
    C1: CLEAR assertions and flaked under load. 6s gives ~5.7s headroom
    (~20x). (#391: the budget+2.0s watchdog tail this margin once
    protected against is gone — the watchdog subshell redirects its stdio
    to /dev/null so a killed subshell's orphaned `sleep` no longer holds
    the caller's stdout pipe open; each .sh invocation now returns ≈ the
    python pipeline time.) The tight-budget timeout contract is owned by
    test_bash_timeout_contract (0.05s) and the B23 folds, NOT by B16/B17."""
    env = _bash_env(_url(gh), _url(sb), tmp_path, token, timeout=timeout)
    for name in ("SWARM_CARD_ID", "AGENT_ID", "SWARM_TOUCHED_PATHS",
                 "PARALLEL_CHECK_SB_URL", "PARALLEL_CHECK_SB_KEY",
                 "SUPABASE_URL_ORG_DATA", "SUPABASE_SERVICE_ROLE_KEY_ORG_DATA"):
        env.pop(name, None)
    return env


def test_b16_bash_no_board_end_to_end(tmp_path):
    """Real .sh with a no-board env: C1: CLEAR no-board-skip + token mode."""
    repo, _ = _make_repo(tmp_path)
    gh, sb = _serve(), _serve()
    token = tmp_path / "token.json"
    env = _noboard_bash_env(gh, sb, tmp_path, token)
    env["CHECKOUT_GUARD_SWARM_ROOT"] = str(repo)  # per-repo-policy fixture
    proc = _run_bash(tmp_path, "start", repo, env)
    assert proc.returncode == 0
    line = proc.stdout.strip().splitlines()[0]
    assert line.startswith("C1: CLEAR"), line
    assert "no-board-skip" in line
    payload = json.loads(token.read_text())
    assert payload["mode"] == "no-board-skip"


def test_b17_realistic_no_board_consumer_probe(tmp_path):
    """Fresh consumer checkout + minimal env: skip fires across start/plan/
    implement; AGENT_ID-only fails closed; symbol-without-slug → UNKNOWN."""
    repo, _ = _make_repo(tmp_path)
    gh, sb = _serve(), _serve()
    for phase in ("start", "plan", "implement"):
        token = tmp_path / f"token-{phase}.json"
        env = _noboard_bash_env(gh, sb, tmp_path, token)
        env["CHECKOUT_GUARD_SWARM_ROOT"] = str(repo)
        proc = _run_bash(tmp_path, phase, repo, env)
        assert proc.returncode == 0
        line = proc.stdout.strip().splitlines()[0]
        assert line.startswith(f"{pwc.PHASE_CODE[phase]}: CLEAR"), line
        assert "no-board-skip" in line
    # AGENT_ID only → fail-closed UNKNOWN (never skip)
    token = tmp_path / "token-agent.json"
    env = _noboard_bash_env(gh, sb, tmp_path, token)
    env["CHECKOUT_GUARD_SWARM_ROOT"] = str(repo)
    env["AGENT_ID"] = "agent-a"
    proc = _run_bash(tmp_path, "start", repo, env)
    line = proc.stdout.strip().splitlines()[0]
    assert line.startswith("C1: UNKNOWN"), line
    assert "no-board-skip" not in line
    # symbol without a slug (local-path origin) → UNKNOWN, not skip-CLEAR
    token = tmp_path / "token-sym.json"
    env = _noboard_bash_env(gh, sb, tmp_path, token)
    env["CHECKOUT_GUARD_SWARM_ROOT"] = str(repo)
    env["PARALLEL_CHECK_SYMBOL"] = "auth_token"
    env.pop("PARALLEL_CHECK_REPO_SLUG", None)   # genuine consumer: no slug
    env.pop("GH_REPOSITORY", None)
    proc = _run_bash(tmp_path, "start", repo, env, symbol="auth_token")
    line = proc.stdout.strip().splitlines()[0]
    assert line.startswith("C1: UNKNOWN"), line
    assert "repo-slug" in line


def test_b17_variant_non_main_default_branch(tmp_path):
    """Inherited origin/main assumption: a no-board consumer whose origin
    has no `main` ref → C1/C4 fail-closed UNKNOWN (never skip)."""
    repo = tmp_path / "repo"
    origin = tmp_path / "origin.git"
    _git("init", "-b", "master", str(repo))
    _git("config", "user.email", "pwc-test@example.com", cwd=repo)
    _git("config", "user.name", "PWC Test", cwd=repo)
    (repo / "file.txt").write_text("v1\n")
    _git("add", "file.txt", cwd=repo)
    _git("commit", "-m", "c1", cwd=repo)
    _git("init", "--bare", "-b", "master", str(origin))
    _git("remote", "add", "origin", str(origin), cwd=repo)
    _git("push", "-u", "origin", "master", cwd=repo)
    token = tmp_path / "t.json"
    env = _env_noboard(token=token)
    for phase in ("start", "implement"):
        res = pwc.run_check(phase, repo=str(repo), env=env,
                            guard=_guard_clear, now=NOW)
        assert res.verdict == "UNKNOWN", phase
        assert "no-board-skip" not in res.details
    assert not token.exists()


def test_b17_variant_no_origin_fork_layout(tmp_path):
    """Fork layout (no origin, only upstream): remote_url → 'unknown' on
    both sides (both-"unknown" binding) while C1's fetch of origin/main
    fails → fail-closed UNKNOWN."""
    repo, _ = _make_repo(tmp_path)
    _git("remote", "add", "upstream",
         "https://github.com/upstream/consumer.git", cwd=repo)
    _git("remote", "remove", "origin", cwd=repo)
    assert pwc.GitOps(str(repo)).remote_url() == "unknown"
    token = tmp_path / "t.json"
    env = _env_noboard(token=token)
    res = pwc.run_check("start", repo=str(repo), env=env,
                        guard=_guard_clear, now=NOW)
    assert res.verdict == "UNKNOWN"
    assert "no-board-skip" not in res.details


# ── B18: repo-path resolution (cwd chain + insteadOf + slug) ─────────

def test_b18_repo_path_resolution(tmp_path, monkeypatch):
    """Fallback chain --repo > PARALLEL_CHECK_REPO > cwd; token repo ==
    remote get-url of the resolved target (never _REPO_ROOT's remote, never
    the raw env string); no-remote → 'unknown'; insteadOf rewrites get-url
    but NOT the config --get slug (A1 P4-2)."""
    repo, _ = _make_repo(tmp_path)
    remote = _git("remote", "get-url", "origin", cwd=repo).stdout.strip()
    other, _ = _make_repo(tmp_path / "r2")
    other_remote = _git("remote", "get-url", "origin", cwd=other).stdout.strip()
    token = tmp_path / "t.json"

    # cwd resolution: no --repo, no env → ops target = cwd
    monkeypatch.chdir(repo)
    res = pwc.run_check("start", env=_env_noboard(token=token),
                        guard=_guard_clear, now=NOW)
    assert res.verdict == "CLEAR"
    assert json.loads(token.read_text())["repo"] == remote

    # --repo beats cwd
    monkeypatch.chdir(other)
    res = pwc.run_check("start", repo=str(repo), env=_env_noboard(token=token),
                        guard=_guard_clear, now=NOW)
    assert json.loads(token.read_text())["repo"] == remote

    # PARALLEL_CHECK_REPO beats cwd; token repo never == _REPO_ROOT's remote
    res = pwc.run_check("start",
                        env=_env_noboard(token=token,
                                         PARALLEL_CHECK_REPO=str(repo)),
                        guard=_guard_clear, now=NOW)
    assert json.loads(token.read_text())["repo"] == remote
    try:
        root_remote = _git("remote", "get-url", "origin",
                           cwd=pwc._REPO_ROOT).stdout.strip()
        assert remote != root_remote
    except subprocess.CalledProcessError:
        pass  # _REPO_ROOT without an origin — nothing to compare

    # no-remote dir → 'unknown' (C3 skips before fetch — token still written)
    bare = tmp_path / "noremo"
    _git("init", "-b", "main", str(bare))
    res = pwc.run_check("plan", repo=str(bare), env=_env_noboard(token=token),
                        now=NOW)
    assert res.verdict == "CLEAR" and "no-board-skip" in res.details
    assert json.loads(token.read_text())["repo"] == "unknown"

    # insteadOf: remote get-url applies the rewrite (scoped repo-local —
    # never the global gitconfig); the slug stays on config --get (raw).
    _set_origin(repo, "https://github.com/daniel-ospina/swarm.git")
    _git("config", "url.https://gitmirror.example.com/.insteadOf",
         "https://github.com/", cwd=repo)
    git = pwc.GitOps(str(repo))
    assert git.remote_url() == "https://gitmirror.example.com/daniel-ospina/swarm.git"
    assert pwc._resolve_slug({}, git, 5.0) == "daniel-ospina/swarm"
    # a stored non-github URL → empty slug (dup-search skipped)
    _set_origin(repo, "git@gitlab.com:group/proj.git")
    assert pwc._resolve_slug({}, pwc.GitOps(str(repo)), 5.0) == ""


# ── P3 (code-quality round): CLEAR-branch lazy token_repo fail-safe ──

def test_p3_clearbranch_lazy_remote_typeerror_contained(tmp_path):
    """P3 (code-quality): a non-str value anywhere in the subprocess env
    makes the REAL GitOps.remote_url() raise TypeError (subprocess.run
    requires str env values) — the CLEAR branch must contain it, never
    propagate out of run_check ("NEVER raises" contract), and the token
    repo falls back to "unknown" like every other subprocess call's
    fail-closed path. Phase: C3 no-board skips BEFORE any git subprocess,
    and PARALLEL_CHECK_REPO_SLUG bypasses _resolve_slug's git config call,
    so the ONLY subprocess in the run is the lazy remote_url itself."""
    token = tmp_path / "t.json"
    env = _env_noboard(token=token,
                       PARALLEL_CHECK_REPO_SLUG="daniel-ospina/swarm",
                       WEIRD_UNUSED=12345)
    # no git= injection → real GitOps; the non-str env value rides sub_env
    res = pwc.run_check("plan", repo=str(tmp_path), env=env, now=NOW)
    assert res.verdict == "CLEAR"
    assert "no-board-skip" in res.details
    payload = json.loads(token.read_text())
    assert payload["repo"] == "unknown"


# ── B19: C5 negative fence ───────────────────────────────────────────

def test_b19_c5_negative_fence_board_no_card(tmp_path):
    """board present, no card → C5 UNKNOWN missing-card-context (guard
    retained; zero store calls)."""
    token = tmp_path / "t.json"
    env = _env_noboard(token=token, SUPABASE_URL="https://x.supabase.co",
                       SUPABASE_ANON_KEY="k")
    res = pwc.run_check("merge", repo=str(tmp_path), env=env, git=FakeGit(),
                        store=ThrowingStore(), now=NOW)
    assert res.verdict == "UNKNOWN"
    assert "missing-card-context" in res.details


# ── B20: vendor-drift script mechanics ───────────────────────────────

def _has_swarm_checkout() -> bool:
    """B20's drift-ledger test needs the REAL swarm checkout (check-vendor-drift.sh
    exits 2 without a git repo at SWARM_ROOT even in --manifest mode, because it
    reverse-applies the ledger patches against the swarm base files). CI runners
    have no ~/swarm — the CI drift gate is the vendor-drift job; B20 is the
    local ledger test (mirrors the _has_supabase_v2 skipif precedent)."""
    return (Path(os.path.expanduser("~/swarm")) / ".git").is_dir()


@pytest.mark.skipif(not _has_swarm_checkout(),
                    reason="swarm checkout required for the drift-ledger test "
                           "(CI drift gate = the vendor-drift job)")
def test_b20_vendor_drift_manifest(tmp_path):
    """check-vendor-drift.sh --manifest against a fixture copy: clean → 0;
    an identical@base edit → non-zero; a deleted patched file → non-zero."""
    import shutil
    repo_root = Path(__file__).resolve().parent.parent  # agent-infra
    tmprepo = tmp_path / "vendored"
    (tmprepo / "scripts").mkdir(parents=True)
    (tmprepo / "connectors").mkdir()
    for rel in ("scripts/checkout_guard.sh", "scripts/parallel_work_check.sh",
                "scripts/parallel_work_check.py",
                "scripts/test_parallel_work_check.py",
                "scripts/fake_supabase.py", "scripts/.vendor-manifest.json",
                "connectors/__init__.py", "connectors/supabase_swarm.py",
                "connectors/supabase_org.py", "connectors/hosted_tortoise.py"):
        dst = tmprepo / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(repo_root / rel, dst)
    shutil.copytree(repo_root / "scripts/.vendor-patches",
                    tmprepo / "scripts/.vendor-patches")
    _git("init", str(tmprepo))
    env = dict(os.environ,
               SWARM_ROOT=os.path.expanduser("~/swarm"),
               MANIFEST=str(tmprepo / "scripts/.vendor-manifest.json"))

    def run_drift():
        return subprocess.run(
            ["bash", str(repo_root / "scripts/check-vendor-drift.sh"),
             "--manifest"],
            capture_output=True, text=True, env=env, cwd=str(tmprepo))

    assert run_drift().returncode == 0
    guard = tmprepo / "scripts/checkout_guard.sh"
    guard.write_text(guard.read_text() + "\n# drift\n")
    assert run_drift().returncode != 0   # identical@base file changed
    shutil.copy2(repo_root / "scripts/checkout_guard.sh", guard)
    (tmprepo / "scripts/parallel_work_check.py").unlink()
    assert run_drift().returncode != 0   # patched file deleted


# ── B21: consumer-env fixture assertion (real capture evidence) ───────

def test_b21_consumer_env_fixtures():
    """The committed no-board consumer captures (Task 1 Step 6): the
    predicate is True on the real session envs, every board-signal NAME is
    absent-or-empty, real-session markers hold, ≥2 fixtures with DISTINCT
    captured origins, and GH_TOKEN is absent from both (gh CLI auth)."""
    data_dir = Path(__file__).resolve().parent / "testdata"
    env_files = sorted(data_dir.glob("consumer-env-*.env"))
    name_files = sorted(data_dir.glob("consumer-env-*.names"))
    assert len(env_files) >= 2, "minimum fixture-set gate: ≥2 fixtures"
    assert len(name_files) == len(env_files)
    origins = set()
    for fx in env_files:
        env = {}
        for line in fx.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, value = line.partition("=")
            env[key.strip()] = value
        assert pwc._is_no_board(env) is True, f"{fx} classified as board"
        for name in pwc._BOARD_NAMES:
            assert not (env.get(name) or "").strip(), \
                f"{fx}: board signal {name} present"
        assert any(k.startswith("PI_") for k in env), f"{fx}: no PI_ markers"
        assert "PATH" in env, f"{fx}: no PATH"
        assert "GH_TOKEN" not in env, f"{fx}: GH_TOKEN leaked into capture"
        remote = env.get("REMOTE") or ""
        assert remote, f"{fx}: no REMOTE affinity evidence"
        origins.add(remote)
    assert len(origins) >= 2, "minimum fixture-set gate: ≥2 distinct origins"


# ── B22: board-mode resolution regression (cwd = session target) ──────

def test_b22_board_mode_resolution(tmp_path, monkeypatch):
    """Board session from a worktree-style cwd: ops/guard target + token
    repo resolve to the session cwd; --repo/PARALLEL_CHECK_REPO overrides
    honored; board CLEAR tokens carry mode '' (no skip)."""
    repo, _ = _make_repo(tmp_path)
    remote = _git("remote", "get-url", "origin", cwd=repo).stdout.strip()
    token = tmp_path / "t.json"
    env = {
        "SWARM_CARD_ID": "card-a", "AGENT_ID": "agent-a",
        "SWARM_TOUCHED_PATHS": "src/auth.py",
        "SUPABASE_URL": "https://x.supabase.co",
        "SUPABASE_SERVICE_ROLE_KEY": "k",
        "PARALLEL_CHECK_TIMEOUT_SECS": "5",
        "PARALLEL_CHECK_TOKEN_FILE": str(token),
    }
    captured = []
    monkeypatch.chdir(repo)
    res = pwc.run_check("start", env=env, board=OkBoard(),
                        guard=lambda r, e, t: captured.append(str(r))
                        or _guard_clear(), now=NOW)
    assert res.verdict == "CLEAR"
    assert res.mode == ""
    assert captured == [str(repo)]       # guard target == session cwd
    assert json.loads(token.read_text())["repo"] == remote

    other, _ = _make_repo(tmp_path / "r2")
    other_remote = _git("remote", "get-url", "origin", cwd=other).stdout.strip()
    res = pwc.run_check("start", repo=str(other), env=env, board=OkBoard(),
                        guard=lambda r, e, t: captured.append(str(r))
                        or _guard_clear(), now=NOW)
    assert captured[-1] == str(other)    # --repo override wins
    assert json.loads(token.read_text())["repo"] == other_remote
    res = pwc.run_check("start", env=dict(env, PARALLEL_CHECK_REPO=str(other)),
                        board=OkBoard(),
                        guard=lambda r, e, t: captured.append(str(r))
                        or _guard_clear(), now=NOW)
    assert captured[-1] == str(other)    # env override wins over cwd
    assert json.loads(token.read_text())["repo"] == other_remote


# ── B23: predicate value-semantics boundary (all five families) ───────

@pytest.mark.parametrize("name",
                         [n for fam in pwc._SIGNAL_FAMILIES for n in fam])
def test_b23_single_signal_fence(tmp_path, name):
    """ANY ONE of the 14 signal names (from the shared constants, never
    prose) non-empty → fail-closed, never skip."""
    token = tmp_path / "t.json"
    env = _env_noboard(token=token)
    env[name] = "non-empty"
    assert pwc._is_no_board(env) is False
    res = pwc.run_check("start", repo=str(tmp_path), env=env, git=FakeGit(),
                        guard=_guard_clear, now=NOW)
    assert res.verdict == "UNKNOWN"
    assert "no-board-skip" not in res.details


@pytest.mark.parametrize("name",
                         [n for fam in pwc._SIGNAL_FAMILIES for n in fam])
@pytest.mark.parametrize("value", ["", "   "])
def test_b23_empty_whitespace_absent(name, value):
    """Empty/whitespace = absent (stripped value-truthiness) across ALL
    five families — a presence-keyed bug (e.g. SWARM_CARD_ID='' exported in
    a no-board shell tripping the predicate) would fail here."""
    env = _env_noboard()
    env[name] = value
    assert pwc._is_no_board(env) is True


def test_b23_family_constants_shape():
    """Five independent absent-conditions, 14 names, 8 board names — the
    read paths and the predicate share the SAME constants."""
    fams = pwc._SIGNAL_FAMILIES
    assert len(fams) == 5
    names = [n for fam in fams for n in fam]
    assert len(names) == 14 and len(set(names)) == 14
    assert pwc._BOARD_NAMES == pwc._SB_URL_NAMES + pwc._SB_KEY_NAMES
    assert len(pwc._BOARD_NAMES) == 8
    assert pwc._is_no_board({n: "" for n in names}) is True
    assert pwc._is_no_board({n: "   " for n in names}) is True


@pytest.mark.parametrize("value", ["", "   "])
def test_b23_gh_env_fallbacks(tmp_path, value):
    """Whitespace GH_API_BASE/GH_REPOSITORY/PARALLEL_CHECK_REPO_SLUG →
    documented fallbacks (the plan's injectable-env fold enumerates all
    three — each must yield its documented fallback) — a whitespace slug
    must not produce a malformed search URL; the slug is undeterminable →
    fail-closed UNKNOWN."""
    token = tmp_path / "t.json"
    env = _env_noboard(token=token, symbol="auth_token",
                       GH_API_BASE=value, GH_REPOSITORY=value,
                       PARALLEL_CHECK_REPO_SLUG=value)
    res = pwc.run_check("start", repo=str(tmp_path), env=env, git=FakeGit(),
                        guard=_guard_clear, now=NOW)
    assert res.verdict == "UNKNOWN"
    assert "repo-slug-undeterminable" in res.details
    assert "no-board-skip" not in res.details


def test_b23_fallback_chain_whitespace_does_not_shadow(tmp_path):
    """B23 P2 fallback-chain: a whitespace-valued EARLIER name is absent
    (stripped value-truthiness) — it must NOT shadow a valid later name in
    the same tuple. Slug pair: whitespace PARALLEL_CHECK_REPO_SLUG +
    GH_REPOSITORY=owner/repo → slug resolves owner/repo (FakeGit's config
    lookup returns None, so the env chain is what's under test). Board
    pair: whitespace PARALLEL_CHECK_SB_URL + SUPABASE_URL → the board URL
    resolves through the unset middle name too. A raw-truthiness _env
    returns the whitespace value and both fail."""
    # slug pair — the valid later name must win over the whitespace earlier one
    env = {"PARALLEL_CHECK_REPO_SLUG": "   ",
           "GH_REPOSITORY": "owner/repo"}
    assert pwc._resolve_slug(env, FakeGit(), 5.0) == "owner/repo"
    # board pair — whitespace SB_URL falls through SB_URL_ORG_DATA (unset)
    # to SUPABASE_URL
    env = {"PARALLEL_CHECK_SB_URL": "   ",
           "SUPABASE_URL": "https://x.supabase.co"}
    url, key = pwc._sb_config(env)
    assert url == "https://x.supabase.co"
    assert key == ""  # no key anywhere → unconfigured key


@pytest.mark.parametrize("value", ["", "   "])
def test_b23_symbol_empty_whitespace_gate(tmp_path, value):
    """Empty/whitespace PARALLEL_CHECK_SYMBOL → the symbol gate does NOT
    fire — no blank-query dup-search in a no-board session."""
    token = tmp_path / "t.json"
    env = _env_noboard(token=token, symbol=value)
    res = pwc.run_check("start", repo=str(tmp_path), env=env, git=FakeGit(),
                        guard=_guard_clear, now=NOW)
    assert res.verdict == "CLEAR"
    assert "no-board-skip" in res.details
    assert token.exists()


@pytest.mark.parametrize("timeout_val", ["", "   ", "0", "-1", "abc"])
def test_b23_timeout_edge_values(tmp_path, timeout_val):
    """Edge PARALLEL_CHECK_TIMEOUT_SECS values through the real .sh: the
    verdict line is NEVER blank (the float('')-crash + head -n 1 class),
    exit 0, no token."""
    repo, _ = _make_repo(tmp_path)
    gh, sb = _serve(), _serve()
    _gh(gh, closed=[{"number": 1, "title": "x"}])
    gh.routes["state:closed"]["sleep"] = 5.0
    _board(sb, [_card()])
    token = tmp_path / "token.json"
    env = _bash_env(_url(gh), _url(sb), tmp_path, token, timeout=timeout_val)
    env["CHECKOUT_GUARD_SWARM_ROOT"] = str(repo)  # per-repo-policy fixture
    proc = _run_bash(tmp_path, "start", repo, env, symbol="auth_token")
    assert proc.returncode == 0
    line = proc.stdout.strip().splitlines()[0] if proc.stdout.strip() else ""
    assert line, "verdict line must never be blank"
    assert line.startswith("C1: UNKNOWN"), line
    assert not token.exists()


@pytest.mark.parametrize("timeout_val", ["999999999", "inf", "nan", "1e309"])
def test_b23_timeout_upper_bound_clamp(tmp_path, timeout_val):
    """Non-finite/upper-bound timeout values: BOTH sides clamp to
    PARALLEL_CHECK_BUDGET_MAX (test-injected small max → fast watchdog),
    verdict non-blank, exit 0, no token."""
    repo, _ = _make_repo(tmp_path)
    gh, sb = _serve(), _serve()
    _gh(gh, closed=[{"number": 1, "title": "x"}])
    gh.routes["state:closed"]["sleep"] = 5.0
    _board(sb, [_card()])
    token = tmp_path / "token.json"
    env = _bash_env(_url(gh), _url(sb), tmp_path, token, timeout=timeout_val)
    env["CHECKOUT_GUARD_SWARM_ROOT"] = str(repo)  # per-repo-policy fixture
    env["PARALLEL_CHECK_BUDGET_MAX"] = "0.2"
    proc = _run_bash(tmp_path, "start", repo, env, symbol="auth_token")
    assert proc.returncode == 0
    line = proc.stdout.strip().splitlines()[0] if proc.stdout.strip() else ""
    assert line, "verdict line must never be blank"
    assert line.startswith("C1: UNKNOWN"), line
    assert not token.exists()


def test_b23_budget_max_default_and_python_clamp(tmp_path):
    """Default PARALLEL_CHECK_BUDGET_MAX == 60 (fast unit pin); the python
    side CLAMPS: with an injected max of 0.2s + timeout=inf + a slow mock,
    the checker self-fails-closed in well under a second — an unclamped inf
    deadline would wait out the 5s mock and return DUP_FIX."""
    assert pwc.BUDGET_MAX_DEFAULT == 60.0
    gh, sb = _serve(), _serve()
    _gh(gh, closed=[{"number": 1, "title": "x"}])
    gh.routes["state:closed"]["sleep"] = 5.0
    _board(sb, [_card()])
    token = tmp_path / "token.json"
    env = {
        "PARALLEL_CHECK_TIMEOUT_SECS": "inf",
        "PARALLEL_CHECK_BUDGET_MAX": "0.2",
        "PARALLEL_CHECK_TOKEN_FILE": str(token),
        "PARALLEL_CHECK_REPO_SLUG": "daniel-ospina/swarm",
        "PARALLEL_CHECK_SYMBOL": "auth_token",  # forces the slow-mock hit
        "SWARM_CARD_ID": "card-a", "AGENT_ID": "agent-a",
        "SWARM_TOUCHED_PATHS": "src/auth.py",
    }
    t0 = time.monotonic()
    res = pwc.run_check("start", repo=str(tmp_path), env=env,
                        gh=pwc.GhRest(_url(gh), "t", 5.0),
                        board=_board(sb, [_card()]), git=FakeGit(),
                        guard=_guard_clear, now=NOW)
    elapsed = time.monotonic() - t0
    assert res.verdict == "UNKNOWN"
    assert elapsed < 2.0, f"python budget not clamped: {elapsed:.2f}s"
    assert not token.exists()


# ── B24: vacuous-CLEAR deletion regression ───────────────────────────

def test_b24_vacuous_clear_deletion(tmp_path):
    """Board present, no card, no paths → C3 UNKNOWN missing-card-context
    (the vendored no-card-no-scope CLEAR is deleted; B24 fails on today's
    code). C4's dead no-card CLEAR is gone too."""
    token = tmp_path / "t.json"
    env = _env_noboard(token=token, SUPABASE_URL="https://x.supabase.co",
                       SUPABASE_SERVICE_ROLE_KEY="k")
    res = pwc.run_check("plan", repo=str(tmp_path), env=env, git=FakeGit(),
                        now=NOW)
    assert res.verdict == "UNKNOWN"
    assert "missing-card-context" in res.details
    assert "no-card-no-scope" not in res.details
    assert "no-board-skip" not in res.details
    assert not token.exists()
    res4 = pwc.run_check("implement", repo=str(tmp_path), env=env,
                         git=FakeGit(), now=NOW)
    assert res4.verdict == "UNKNOWN"
    assert "missing-card-context" in res4.details
    assert "no-card" not in res4.details
    assert "no-board-skip" not in res4.details


# ── B25: no-board pickaxe symbol gate ────────────────────────────────

def test_b25_c4_no_board_pickaxe_no_symbol(tmp_path):
    """no-board C4 with NO symbol: the pickaxe call is symbol-gated — no
    pickaxe(None) TypeError, no DUP_FIX, clean skip."""
    git = RecordingGit()
    token = tmp_path / "t.json"
    res = pwc.run_check("implement", repo=str(tmp_path),
                        env=_env_noboard(token=token), git=git, now=NOW)
    assert res.verdict == "CLEAR"
    assert "no-board-skip" in res.details
    assert "fetch" in git.calls and "behind" in git.calls
    assert not any(isinstance(c, tuple) and c[0] == "pickaxe"
                   for c in git.calls)
    assert token.exists()


# ── B26: override-binding parity ─────────────────────────────────────

def test_b26_override_binding_parity(tmp_path):
    """PARALLEL_CHECK_REPO set: the token repo == the override's remote via
    remote get-url (URL form) — never the raw env string."""
    repo, _ = _make_repo(tmp_path)
    _set_origin(repo, "https://github.com/daniel-ospina/consumer.git")
    token = tmp_path / "t.json"
    env = _env_noboard(token=token, PARALLEL_CHECK_REPO=str(repo))
    res = pwc.run_check("plan", env=env, now=NOW)
    assert res.verdict == "CLEAR"
    payload = json.loads(token.read_text())
    assert payload["repo"] == "https://github.com/daniel-ospina/consumer.git"
    assert payload["repo"] != str(repo)   # URL form, not the raw path


def test_b26_credential_userinfo_sanitized(tmp_path):
    """P2 (code-quality): ANY userinfo on a scheme-bearing origin is
    SANITIZED in remote_url() — the token's repo field must never carry a
    credential: the `user:pass@` form AND the bare-PAT form
    (`https://ghp_FAKETOKEN@host/...`, NO colon — common for GitHub
    PATs-as-username) both leak the secret verbatim if left; `ssh://git@`
    is stripped too (userinfo is never part of repo identity). The
    scp-form `git@github.com:org/repo.git` has NO scheme → NOT a URL form
    → passes through byte-identical (normal ssh remote, enforcer binding
    parity); a normal https origin (no userinfo) is untouched."""
    repo, _ = _make_repo(tmp_path)
    token = tmp_path / "t.json"
    # (a) user:pass credential → userinfo stripped, URL form preserved
    _set_origin(repo,
                "https://x-access-token:ghp_FAKETOKEN@github.com/"
                "daniel-ospina/consumer.git")
    assert pwc.GitOps(str(repo)).remote_url() == \
        "https://github.com/daniel-ospina/consumer.git"
    # (a') BARE-PAT form (no colon — the P2 gap) → stripped identically;
    # the token payload shows NO userinfo for this case
    _set_origin(repo,
                "https://ghp_FAKETOKEN@github.com/daniel-ospina/consumer.git")
    assert pwc.GitOps(str(repo)).remote_url() == \
        "https://github.com/daniel-ospina/consumer.git"
    env = _env_noboard(token=token, PARALLEL_CHECK_REPO=str(repo))
    res = pwc.run_check("plan", env=env, now=NOW)
    assert res.verdict == "CLEAR"
    payload = json.loads(token.read_text())
    assert payload["repo"] == "https://github.com/daniel-ospina/consumer.git"
    assert "x-access-token" not in payload["repo"]
    assert "ghp_" not in payload["repo"]
    assert "@" not in payload["repo"]   # NO userinfo in the payload
    # (b) ssh:// with a bare user → STRIPPED to the host:port (userinfo is
    # never part of repo identity)
    _set_origin(repo, "ssh://git@github.com/daniel-ospina/consumer.git")
    assert pwc.GitOps(str(repo)).remote_url() == \
        "ssh://github.com/daniel-ospina/consumer.git"
    # (c) bare-username scp-form → UNCHANGED (no scheme → no netloc → the
    # sanitizer guard leaves it byte-identical — parity-preserving pin)
    _set_origin(repo, "git@github.com:daniel-ospina/consumer.git")
    assert pwc.GitOps(str(repo)).remote_url() == \
        "git@github.com:daniel-ospina/consumer.git"
    # (d) normal https (no userinfo) → untouched
    _set_origin(repo, "https://github.com/daniel-ospina/consumer.git")
    assert pwc.GitOps(str(repo)).remote_url() == \
        "https://github.com/daniel-ospina/consumer.git"


# ── B27: stale-clone edge + near-miss/new-signal warn emission ───────

def test_b27_c4_stale_clone_edge(tmp_path):
    """no-board + behind>0 → C4 STALE (behind fires before the no-board
    branch) — actionable pull-and-rerun, NOT a skip; token NOT written."""
    repo, origin = _make_repo(tmp_path)
    _advance_origin(tmp_path, origin)
    token = tmp_path / "t.json"
    res = pwc.run_check("implement", repo=str(repo),
                        env=_env_noboard(token=token), now=NOW)
    assert res.verdict == "STALE"
    assert "behind-origin" in res.details
    assert "no-board-skip" not in res.details
    assert not token.exists()


def test_b27_near_miss_warn(tmp_path):
    """Exactly one board-family signal → UNKNOWN + warn=near-miss:<name> —
    the note RIDES the verdict line (the .sh head -n 1 drops standalone
    stdout lines)."""
    token = tmp_path / "t.json"
    env = _env_noboard(token=token, SUPABASE_URL="https://x.supabase.co")
    res = pwc.run_check("start", repo=str(tmp_path), env=env, git=FakeGit(),
                        guard=_guard_clear, now=NOW)
    assert res.verdict == "UNKNOWN"
    assert "warn=near-miss:SUPABASE_URL" in res.line()
    assert not token.exists()


def test_b27_near_miss_wrapper_rides_verdict_line(tmp_path):
    """Wrapper-level: the near-miss warn survives the .sh's head -n 1 —
    it rides the sole stdout verdict line."""
    repo, _ = _make_repo(tmp_path)
    gh, sb = _serve(), _serve()
    token = tmp_path / "token.json"
    env = _noboard_bash_env(gh, sb, tmp_path, token)
    env["CHECKOUT_GUARD_SWARM_ROOT"] = str(repo)
    env["SUPABASE_URL"] = "https://x.supabase.co"
    proc = _run_bash(tmp_path, "start", repo, env)
    line = proc.stdout.strip().splitlines()[0]
    assert line.startswith("C1: UNKNOWN"), line
    assert "warn=near-miss:SUPABASE_URL" in line


def test_b27_new_signal_warn(tmp_path, monkeypatch):
    """A board-signal NAME absent from the probe-time snapshot fires
    warn=new-signal:<name> (mechanism — the constant is monkeypatched). The
    board is INJECTED (OkBoard) so the C1 board scan is deterministic — the
    real-supabase-shaped env must never attempt an outbound call to
    x.supabase.co on CI."""
    monkeypatch.setattr(pwc, "NEW_BOARD_SIGNAL_NAMES", ("SUPABASE_URL",))
    token = tmp_path / "t.json"
    env = _env_noboard(token=token, SUPABASE_URL="https://x.supabase.co",
                       SUPABASE_ANON_KEY="k")   # 2 signals → no near-miss
    res = pwc.run_check("start", repo=str(tmp_path), env=env, git=FakeGit(),
                        board=OkBoard(), guard=_guard_clear, now=NOW)
    assert "warn=new-signal:SUPABASE_URL" in res.line()


def test_b27_new_signal_parity():
    """The baked constant == the committed fixtures' name inventories ∩ the
    board-signal families — a new fixture name trips CI until regenerated
    (the same names-parity class B23's P2 pin enforces for the predicate)."""
    data_dir = Path(__file__).resolve().parent / "testdata"
    fixture_names = set()
    for nf in data_dir.glob("consumer-env-*.names"):
        for line in nf.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#"):
                fixture_names.add(line)
    assert set(pwc.NEW_BOARD_SIGNAL_NAMES) == (fixture_names
                                               & set(pwc._BOARD_NAMES))


# ── B28: concurrency, last-writer-wins (deterministic ordering) ──────

def test_b28_concurrency_last_writer_wins(tmp_path):
    """Two checker invocations on ONE token file, ordered deterministically:
    STALE-unlink AFTER the CLEAR write → token absent (the enforcer's
    'none found' BLOCK); CLEAR last → token survives (last-writer-wins)."""
    token = tmp_path / "token.json"
    env = _env_noboard(token=token)
    # Case 1: CLEAR write, THEN the STALE run's unlink → absent
    res_clear = pwc.run_check("start", repo=str(tmp_path), env=env,
                              git=FakeGit(), guard=_guard_clear, now=NOW)
    assert res_clear.verdict == "CLEAR"
    assert token.exists()
    res_stale = pwc.run_check(
        "start", repo=str(tmp_path), env=env, git=FakeGit(),
        guard=lambda r, e, t: "checkout-guard VERDICT: STALE behind origin/main\n",
        now=NOW)
    assert res_stale.verdict == "STALE"
    assert not token.exists()           # gate outcome: "none found" BLOCK
    # Case 2: reverse ordering — CLEAR last → survives intact
    pwc.run_check("start", repo=str(tmp_path), env=env, git=FakeGit(),
                  guard=lambda r, e, t:
                  "checkout-guard VERDICT: STALE behind origin/main\n",
                  now=NOW)
    assert not token.exists()
    pwc.run_check("start", repo=str(tmp_path), env=env, git=FakeGit(),
                  guard=_guard_clear, now=NOW)
    assert token.exists()
    payload = json.loads(token.read_text())
    assert payload["verdict"] == "CLEAR"
    assert payload["mode"] == "no-board-skip"


# ── B29: write-failure + stale-token + unlink-failure (never silent) ─

def test_b29_token_write_failure_verdict_note(tmp_path):
    """Unwritable token path (chmod-000 dir) → the VERDICT LINE carries
    warn=token-write-failed — the sole stdout line survives the .sh's
    head -n 1 (a stderr-only warn is invisible; an unmarked stdout warn
    would be emitted AS the verdict)."""
    ro = tmp_path / "ro"
    ro.mkdir()
    ro.chmod(0o000)
    try:
        token = ro / "token.json"
        env = _env_noboard(token=token)
        res = pwc.run_check("start", repo=str(tmp_path), env=env,
                            git=FakeGit(), guard=_guard_clear, now=NOW)
        assert res.verdict == "CLEAR"
        assert "no-board-skip" in res.details
        assert "warn=token-write-failed" in res.line()
        assert not os.path.exists(str(token))  # os.path (not Path) — the
        # 000 dir makes Path.exists raise PermissionError; os.path.exists
        # swallows OSError → False.
    finally:
        ro.chmod(0o755)


def test_b29_token_write_failure_wrapper_rides_verdict_line(tmp_path):
    """Wrapper-level (B29): real .sh with a chmod-000 token dir on the
    CLEAR no-board path — the verdict line stays the SOLE stdout line (the
    .sh's head -n 1 drops any standalone line) with warn=token-write-failed
    riding it; stdout is a SINGLE line; the token is absent (the 000 dir
    makes the write fail-closed); exit code 0. Notes pinned: on chmod-000
    os.path.exists() swallows the EACCES stat → the cleanup unlink is never
    attempted → exactly warn=token-write-failed (no warn=unlink-failed)."""
    repo, _ = _make_repo(tmp_path)
    gh, sb = _serve(), _serve()
    ro = tmp_path / "ro"
    ro.mkdir()
    ro.chmod(0o000)
    try:
        token = ro / "token.json"
        env = _noboard_bash_env(gh, sb, tmp_path, token, timeout="10")
        env["CHECKOUT_GUARD_SWARM_ROOT"] = str(repo)  # per-repo-policy fixture
        proc = _run_bash(tmp_path, "start", repo, env)
        assert proc.returncode == 0
        lines = proc.stdout.strip().splitlines()
        assert len(lines) == 1, f"stdout must be a SINGLE line: {lines!r}"
        line = lines[0]
        assert line.startswith("C1: CLEAR"), line
        assert "no-board-skip" in line, line  # the CLEAR path actually ran
        assert "warn=token-write-failed" in line, line
        assert "warn=unlink-failed" not in line, line  # pinned exact notes
        assert not os.path.exists(str(token))  # 000 dir → absent (fail-closed)
    finally:
        ro.chmod(0o755)


def test_b29_stale_token_unlinked_on_write_failure(tmp_path, monkeypatch):
    """ENOSPC-class write failure (dir stays READABLE) with a PRE-SEEDED
    stale same-phase CLEAR token: the failure path UNLINKS it — the
    enforcer's 'none found' BLOCK holds — and the verdict notes the
    failure. Without this a later ENOSPC run would advance the gate on the
    previous session's pass."""
    token = tmp_path / "token.json"
    token.write_text(json.dumps({"phase": "start", "verdict": "CLEAR",
                                 "code": "C1", "ts": 1}))

    def enospc(*a, **k):
        raise OSError(28, "No space left on device")

    monkeypatch.setattr("parallel_work_check.json.dump", enospc)
    env = _env_noboard(token=token)
    res = pwc.run_check("start", repo=str(tmp_path), env=env,
                        git=FakeGit(), guard=_guard_clear, now=NOW)
    assert res.verdict == "CLEAR"
    assert "warn=token-write-failed" in res.line()
    assert not token.exists()           # stale token gone → "none found"


def test_b29_unlink_failure_warn(tmp_path, monkeypatch):
    """Unlink failure on the UNKNOWN/STALE branch (EACCES/EROFS) surfaces as
    warn=unlink-failed — never silent (the read-only-dir both-fail corner
    is the documented environmental fail-open WITH the note)."""
    token = tmp_path / "token.json"
    token.write_text(json.dumps({"phase": "start", "verdict": "CLEAR",
                                 "code": "C1", "ts": 1}))
    real_unlink = os.unlink

    def eacces_unlink(path, *a, **k):
        if str(path) == str(token):
            raise OSError(13, "Permission denied")
        return real_unlink(path, *a, **k)

    monkeypatch.setattr("parallel_work_check.os.unlink", eacces_unlink)
    env = _env_noboard(token=token)
    res = pwc.run_check(
        "start", repo=str(tmp_path), env=env, git=FakeGit(),
        guard=lambda r, e, t: "checkout-guard VERDICT: STALE behind origin/main\n",
        now=NOW)
    assert res.verdict == "STALE"
    assert "warn=unlink-failed" in res.line()


def test_b29_unlink_failure_write_failure_branch(tmp_path, monkeypatch):
    """Branch (b) of the unlink-failure corner: the WRITE-FAILURE cleanup
    unlink (ENOSPC json.dump + EACCES unlink) on a CLEAR-path run with a
    pre-seeded stale same-phase CLEAR token → the verdict line carries BOTH
    warn=token-write-failed AND warn=unlink-failed, and the stale token
    SURVIVES — environmental fail-open WITH the notes (never silent)."""
    token = tmp_path / "token.json"
    token.write_text(json.dumps({"phase": "start", "verdict": "CLEAR",
                                 "code": "C1", "ts": 1}))
    real_unlink = os.unlink

    def enospc_dump(*a, **k):
        raise OSError(28, "No space left on device")

    def eacces_unlink(path, *a, **k):
        if str(path) == str(token):
            raise OSError(13, "Permission denied")
        return real_unlink(path, *a, **k)

    monkeypatch.setattr("parallel_work_check.json.dump", enospc_dump)
    monkeypatch.setattr("parallel_work_check.os.unlink", eacces_unlink)
    env = _env_noboard(token=token)
    res = pwc.run_check("start", repo=str(tmp_path), env=env,
                        git=FakeGit(), guard=_guard_clear, now=NOW)
    assert res.verdict == "CLEAR"
    assert "no-board-skip" in res.details
    line = res.line()
    assert "warn=token-write-failed" in line
    assert "warn=unlink-failed" in line
    assert token.exists()  # environmental fail-open WITH the notes


# ── B30: atomic write MECHANISM (same-dir rename + unique tmp) ───────

def test_b30_atomic_write_mechanism(tmp_path, monkeypatch):
    """The atomicity invariant itself: the tmp resolves to dirname(token)
    (same-directory rename) with a per-invocation-unique name; a mid-write
    rename failure leaves the final path unchanged/absent and NO tmp
    residue (the finally cleanup) + warn=token-write-failed."""
    token = tmp_path / "token.json"
    env = _env_noboard(token=token)
    real_rename = os.rename
    captured = {}

    def capture_rename(src, dst):
        captured["src"] = src
        captured["dst"] = dst
        return real_rename(src, dst)

    monkeypatch.setattr("parallel_work_check.os.rename", capture_rename)
    res = pwc.run_check("start", repo=str(tmp_path), env=env, git=FakeGit(),
                        guard=_guard_clear, now=NOW)
    assert res.verdict == "CLEAR"
    assert captured["dst"] == str(token)
    assert os.path.dirname(captured["src"]) == os.path.dirname(str(token))
    # mkstemp naming: <tokenfile>.tmp.<unique> — same-dir, invocation-unique
    # (the old pid-based exact-name pin is gone; the contract is the prefix
    # glob the watchdog/cleanup paths use, B30/B34).
    assert os.path.basename(captured["src"]).startswith(
        f"{os.path.basename(str(token))}.tmp.")
    assert token.exists()

    def fail_rename(src, dst):
        raise OSError(5, "EIO")

    monkeypatch.setattr("parallel_work_check.os.rename", fail_rename)
    token2 = tmp_path / "token2.json"
    res2 = pwc.run_check("start", repo=str(tmp_path),
                         env=_env_noboard(token=token2), git=FakeGit(),
                         guard=_guard_clear, now=NOW)
    assert res2.verdict == "CLEAR"
    assert not token2.exists()                       # never a partial token
    assert not list(tmp_path.glob("token2.json.tmp.*"))  # finally cleaned
    assert "warn=token-write-failed" in res2.line()


def test_b30_rename_over_existing_clear(tmp_path, servers):
    """Repeated-checkpoint real-world path: a SECOND CLEAR run over an
    existing CLEAR token REPLACES it ATOMICALLY (new payload wins via the
    same-dir rename) — no tmp residue, no warn notes. The enforcer gate must
    read the LATEST pass (here: the new symbol), never a stale mix."""
    gh, _ = servers
    token = tmp_path / "token.json"
    # first checkpoint — plain no-board CLEAR (symbol '')
    res1 = pwc.run_check("start", repo=str(tmp_path),
                         env=_env_noboard(token=token),
                         git=FakeGit(), guard=_guard_clear, now=NOW)
    assert res1.verdict == "CLEAR"
    assert res1.warns == []
    assert json.loads(token.read_text())["symbol"] == ""
    # second checkpoint — a NEW CLEAR (symbol) over the old token
    env2 = _env_noboard(token=token, symbol="auth_token",
                        PARALLEL_CHECK_REPO_SLUG="daniel-ospina/swarm")
    res2 = pwc.run_check("start", repo=str(tmp_path), env=env2,
                         git=FakeGit(), gh=_gh(gh, closed=[]),
                         guard=_guard_clear, now=NOW)
    assert res2.verdict == "CLEAR"
    assert res2.warns == []                     # clean atomic replace
    payload = json.loads(token.read_text())
    assert payload["symbol"] == "auth_token"   # the NEW payload won
    assert payload["mode"] == "no-board-skip"
    assert not list(tmp_path.glob("token.json.tmp.*"))  # no tmp residue


# ── B31: retained-check failure edges (fail-closed in no-board) ──────

def test_b31_c4_fetch_fail_unknown_no_board(tmp_path):
    """Retained-check edge (a): C4 fetch InfraError in no-board mode →
    C4: UNKNOWN (NEVER a skip-CLEAR); no token; exit-0 semantics."""
    token = tmp_path / "t.json"
    res = pwc.run_check("implement", repo=str(tmp_path),
                        env=_env_noboard(token=token),
                        git=FakeGit(fetch_raises=True), now=NOW)
    assert res.verdict == "UNKNOWN"
    assert "git-fetch" in res.details
    assert "no-board-skip" not in res.details
    assert not token.exists()


def test_b31_c1_guard_timeout_and_dup_500_unknown(servers, tmp_path):
    """Retained-check edge (b): C1 guard timeout AND dup-search 500 both
    run in no-board mode → C1: UNKNOWN (an offline no-board session must
    not silently pass)."""
    gh, _ = servers
    token = tmp_path / "t.json"
    env = _env_noboard(token=token, symbol="auth_token",
                       PARALLEL_CHECK_REPO_SLUG="daniel-ospina/swarm")

    def guard_timeout(repo, env, timeout):
        raise pwc.InfraError("checkout-guard-timeout")

    res = pwc.run_check("start", repo=str(tmp_path), env=env, git=FakeGit(),
                        gh=_gh(gh, closed=[]), guard=guard_timeout, now=NOW)
    assert res.verdict == "UNKNOWN"
    assert "checkout-guard" in res.details
    gh.routes["state:closed"] = {"status": 500, "payload": {}}
    res = pwc.run_check("start", repo=str(tmp_path), env=env, git=FakeGit(),
                        gh=pwc.GhRest(_url(gh), "t", 5.0),
                        guard=_guard_clear, now=NOW)
    assert res.verdict == "UNKNOWN"
    assert "github-search" in res.details
    assert "no-board-skip" not in res.details
    assert not token.exists()


# ── B32: repo env chain empty/whitespace ─────────────────────────────

def test_b32_repo_env_chain_empty_whitespace(tmp_path, monkeypatch):
    """PARALLEL_CHECK_REPO=''/whitespace falls through to cwd resolution —
    the token carries the resolved remote, never '' (presence-keyed
    resolution would block every genuine no-board session)."""
    repo, _ = _make_repo(tmp_path)
    remote = _git("remote", "get-url", "origin", cwd=repo).stdout.strip()
    monkeypatch.chdir(repo)
    for value in ("", "   "):
        token = tmp_path / f"t-{len(value)}.json"
        env = _env_noboard(token=token, PARALLEL_CHECK_REPO=value)
        res = pwc.run_check("plan", env=env, now=NOW)
        assert res.verdict == "CLEAR"
        assert "no-board-skip" in res.details
        payload = json.loads(token.read_text())
        assert payload["repo"] == remote
        assert payload["repo"] != ""


# ── B33: board-mode guard parity, TWO pinned cases ───────────────────

def test_b33_guard_parity_swarm_root_set(tmp_path):
    """(a) SWARM_ROOT-SET parity: CHECKOUT_GUARD_SWARM_ROOT pointed at the
    checkout → main/worktree collision checks fire like swarm's own
    invocation — a non-main branch DEFERs → C1 STALE."""
    repo, _ = _make_repo(tmp_path)
    _git("checkout", "-b", "feat/x", cwd=repo)
    env = _env_noboard()
    env["CHECKOUT_GUARD_SWARM_ROOT"] = str(repo)
    env["CHECKOUT_GUARD_LOG"] = str(tmp_path / "guard.log")
    out = pwc._guard_runner(str(repo), env, 10.0)
    assert "checkout-guard VERDICT: DEFER" in out
    # through the checker: the DEFER maps to C1 STALE (board mode)
    env2 = _env_noboard(token=tmp_path / "t.json",
                        SWARM_CARD_ID="card-a", AGENT_ID="agent-a",
                        SWARM_TOUCHED_PATHS="src/auth.py",
                        SUPABASE_URL="https://x.supabase.co",
                        SUPABASE_ANON_KEY="k")
    env2["CHECKOUT_GUARD_SWARM_ROOT"] = str(repo)
    res = pwc.run_check("start", repo=str(repo), env=env2, now=NOW)
    assert res.verdict == "STALE"
    assert "DEFER" in res.details


def test_b33_guard_parity_unset_default(tmp_path):
    """(b) UNSET default: the vendored guard's default root resolves to the
    agent-infra checkout ($CHECKOUT_GUARD_DIR/../..) — the fixture worktree
    is FOREIGN, so the main/worktree collision checks are SKIPPED
    (dirty-check-only); a non-main branch does NOT DEFER. Parity requires
    the env override (documented divergence, VENDOR.md)."""
    repo = tmp_path / "repo"
    origin = tmp_path / "origin.git"
    old = dict(os.environ, GIT_AUTHOR_DATE="2024-01-01T00:00:00",
               GIT_COMMITTER_DATE="2024-01-01T00:00:00")
    _git("init", "-b", "main", str(repo))
    _git("config", "user.email", "pwc-test@example.com", cwd=repo)
    _git("config", "user.name", "PWC Test", cwd=repo)
    (repo / "file.txt").write_text("v1\n")
    _git("add", "file.txt", cwd=repo)
    _git("commit", "-m", "c1", cwd=repo, env=old)  # 2024 dates → foreign-
    _git("init", "--bare", "-b", "main", str(origin))  # activity check silent
    _git("remote", "add", "origin", str(origin), cwd=repo)
    _git("push", "-u", "origin", "main", cwd=repo)
    _git("checkout", "-b", "feat/x", cwd=repo)
    env = _env_noboard()
    env["CHECKOUT_GUARD_LOG"] = str(tmp_path / "guard.log")
    # no CHECKOUT_GUARD_SWARM_ROOT → default root = agent-infra (foreign)
    out = pwc._guard_runner(str(repo), env, 10.0)
    assert "checkout-guard VERDICT: CLEAR" in out


# ── B34: watchdog cleanup × concurrent writer + heartbeat contract ───

def test_b34_watchdog_cleanup_concurrent_writer(tmp_path, monkeypatch):
    """Deterministic barrier variant (the glob-vs-rename interleaving
    FORCED): B's rename blocks mid-write; the concurrent invocation's
    scoped wrapper glob runs first; the rename resumes with a raise →
    rename-raise → unlink → absent-token fail-closed outcome WITH the
    warn=token-write-failed note."""
    token = tmp_path / "token.json"
    real_rename = os.rename
    state = {"src": None}
    barrier = threading.Event()

    def blocking_rename(src, dst):
        if str(dst) == str(token):
            state["src"] = str(src)
            barrier.wait(timeout=15)
            raise FileNotFoundError(2, "No such file or directory", src)
        return real_rename(src, dst)

    monkeypatch.setattr("parallel_work_check.os.rename", blocking_rename)
    env = _env_noboard(token=token)
    result = {}

    def worker():
        result["res"] = pwc.run_check("start", repo=str(tmp_path), env=env,
                                      git=FakeGit(), guard=_guard_clear,
                                      now=NOW)

    t = threading.Thread(target=worker)
    t.start()
    t0 = time.monotonic()
    while state["src"] is None and time.monotonic() - t0 < 15:
        time.sleep(0.005)
    assert state["src"] is not None, "writer never reached the rename"
    # the .sh watchdog's scoped glob runs while the writer is mid-rename
    for f in tmp_path.glob("token.json.tmp.*"):
        f.unlink()
    barrier.set()
    t.join(timeout=15)
    assert not t.is_alive()
    res = result["res"]
    assert res.verdict == "CLEAR"
    assert "warn=token-write-failed" in res.line()
    assert not token.exists()            # fail-closed BLOCK, never partial


def test_b34_glob_scoped_and_intact_survivor(tmp_path):
    """Union complement: the wrapper's scoped tmp-glob deletes ONLY the
    token's own prefix; a concurrent CLEAR write that completes first
    survives INTACT (never a partial/corrupt token)."""
    token = tmp_path / "token.json"
    midwrite = tmp_path / "token.json.tmp.4242"   # A's mid-write residue
    unrelated = tmp_path / "other.json.tmp.999"
    midwrite.write_text("{partial")
    unrelated.write_text("keep")
    env = _env_noboard(token=token)
    res = pwc.run_check("start", repo=str(tmp_path), env=env, git=FakeGit(),
                        guard=_guard_clear, now=NOW)   # B completes a CLEAR
    assert res.verdict == "CLEAR"
    assert token.exists()
    payload = json.loads(token.read_text())
    assert payload["verdict"] == "CLEAR"              # intact — never partial
    # the wrapper's scoped glob now runs (as the watchdog path would):
    for f in tmp_path.glob("token.json.tmp.*"):
        f.unlink()
    assert not list(tmp_path.glob("token.json.tmp.*"))   # A's residue gone
    assert unrelated.exists()                         # scoped — others survive
    assert token.exists()                             # the CLEAR survives


def test_b34_heartbeat_contract(tmp_path):
    """scripts/heartbeats/ holds ≤ 1 file (the guard's single accumulating
    checkout_guard.log) across consecutive guard runs — the checker itself
    writes NO heartbeat files; a watchdog-killed session leaves the log
    (documented accumulation, VENDOR.md)."""
    hb_dir = Path(__file__).resolve().parent / "heartbeats"
    repo, _ = _make_repo(tmp_path)
    env = _env_noboard()
    env["CHECKOUT_GUARD_LOG"] = str(hb_dir / "checkout_guard.log")
    for _ in range(3):
        pwc._guard_runner(str(repo), env, 10.0)
    files = list(hb_dir.glob("*"))
    assert len(files) <= 1, f"heartbeats growth: {[f.name for f in files]}"


# ══════════════════════════════════════════════════════════════════════
# #378 — per-session token-file scoping (writer side)
# ══════════════════════════════════════════════════════════════════════
# The token DEFAULT is per-session: when the checker runs inside a pi session
# (PI_SESSION_ID set in the bash-tool child env — the SAME id the enforcer
# resolves via ctx.sessionManager.getSessionId()), the default token path is
# /tmp/parallel-check-token.<sid>.json so concurrent sessions never
# share/clobber one machine-global file. Env override wins VERBATIM; no
# session → the legacy unscoped default. Sanitization is BYTE-wise and must
# mirror the enforcer (Node Buffer) + the .sh wrapper (LC_ALL=C tr -c).

def test_378_session_scope_suffix_none_for_empty(monkeypatch):
    assert pwc._session_scope_suffix({}) is None
    assert pwc._session_scope_suffix({"PI_SESSION_ID": ""}) is None
    assert pwc._session_scope_suffix({"PI_SESSION_ID": "   "}) is None


def test_378_session_scope_suffix_sanitizes_bytewise():
    assert pwc._session_scope_suffix(
        {"PI_SESSION_ID": "01a072a1-93dc-7805-9a3c-a7a908512c6b"}
    ) == "01a072a1-93dc-7805-9a3c-a7a908512c6b"
    # path separators / traversal can never reach a filename
    assert pwc._session_scope_suffix(
        {"PI_SESSION_ID": "../evil"}) == ".._evil"
    # 'é' = 0xC3 0xA9 → TWO underscores (byte-wise — the enforcer Buffer and
    # the .sh `tr -c` map each utf-8 byte, NOT each code point).
    assert pwc._session_scope_suffix({"PI_SESSION_ID": "sessé"}) == "sess__"


def test_378_token_file_path_resolution(monkeypatch, tmp_path):
    base = tmp_path / "token.json"
    monkeypatch.setattr(pwc, "TOKEN_FILE_DEFAULT", str(base))
    # override wins VERBATIM (never session-scoped) — even with a session id
    override = str(tmp_path / "custom.json")
    assert pwc._token_file_path(
        {"PI_SESSION_ID": "sess-378", "PARALLEL_CHECK_TOKEN_FILE": override}
    ) == override
    # no session → legacy unscoped default
    assert pwc._token_file_path({}) == str(base)
    assert pwc._token_file_path({"PARALLEL_CHECK_TOKEN_FILE": "   "}) == str(base)
    # session → per-session scoped default (suffix before the extension)
    assert pwc._token_file_path({"PI_SESSION_ID": "sess-378"}) == \
        str(tmp_path / "token.sess-378.json")
    assert pwc._token_file_path({"PI_SESSION_ID": "../evil"}) == \
        str(tmp_path / "token..._evil.json")


def test_378_token_file_path_enforcer_parity_shape():
    """#378 enforcer-parity shape: the REAL (unpatched) default resolves to
    /tmp/parallel-check-token.<sid>.json — the EXACT path shape the enforcer
    derives from the same session id (both sides must agree byte-for-byte)."""
    assert pwc._token_file_path({"PI_SESSION_ID": "sess-378-parity"}) == \
        "/tmp/parallel-check-token.sess-378-parity.json"
    assert pwc._token_file_path({}) == "/tmp/parallel-check-token.json"


def test_378_run_check_writes_scoped_default_token(monkeypatch, tmp_path):
    """no-board C1 CLEAR with PI_SESSION_ID set + no override → the token lands
    at the SESSION-SCOPED default, not the unscoped base (hermetic via the
    monkeypatched TOKEN_FILE_DEFAULT base)."""
    base = tmp_path / "token.json"
    monkeypatch.setattr(pwc, "TOKEN_FILE_DEFAULT", str(base))
    env = _env_noboard()
    env["PI_SESSION_ID"] = "sess-378-e2e"
    res = pwc.run_check(
        "start", repo=str(tmp_path), env=env,
        git=FakeGit(), gh=ThrowingBoard(), board=ThrowingBoard(),
        guard=_guard_clear, now=NOW)
    assert res.verdict == "CLEAR"
    assert (tmp_path / "token.sess-378-e2e.json").exists(), \
        "token written at the session-scoped default"
    assert not base.exists(), "unscoped base must NOT receive the token"


def test_378_run_check_no_session_writes_unscoped_default(monkeypatch, tmp_path):
    """no PI_SESSION_ID (operator shell run) → the legacy unscoped default
    receives the token (writer↔reader both fall back — no split contract)."""
    base = tmp_path / "token.json"
    monkeypatch.setattr(pwc, "TOKEN_FILE_DEFAULT", str(base))
    env = _env_noboard()
    env.pop("PI_SESSION_ID", None)
    res = pwc.run_check(
        "start", repo=str(tmp_path), env=env,
        git=FakeGit(), gh=ThrowingBoard(), board=ThrowingBoard(),
        guard=_guard_clear, now=NOW)
    assert res.verdict == "CLEAR"
    assert base.exists()
    assert not (tmp_path / "token.none.json").exists()


def test_378_bash_wrapper_parity_with_python_on_padded_nonascii_id(tmp_path):
    """#378 .sh↔python parity on a whitespace-PADDED non-ASCII session id.
    python (the canonical writer) computes the scope (trim + byte sanitize);
    the .sh wrapper's error-branch unlink must target EXACTLY that path — if
    the wrapper drifts (no trim, or a code-point tr instead of byte-wise), the
    stale scoped CLEAR survives the watchdog unlink and this test fails."""
    sid = f"  pwc378-{uuid4().hex}-sess-é  "   # padded + é (2 utf-8 bytes)
    scope = pwc._session_scope_suffix({"PI_SESSION_ID": sid})
    assert scope is not None
    assert scope.endswith("-sess-__"), \
        f"byte-wise é → 2 underscores (got {scope!r})"
    scoped = Path(f"/tmp/parallel-check-token.{scope}.json")
    fake = _fake_interpreter(tmp_path, f'''
printf '%s' '{{"phase":"start","verdict":"CLEAR","code":"C1","ts":1}}' > "{scoped}"
sleep 30
''')
    env = dict(os.environ)
    env["PYTHON_BIN"] = str(fake)
    env["PI_SESSION_ID"] = sid
    env.pop("PARALLEL_CHECK_TOKEN_FILE", None)   # scoping must not be masked
    env["PARALLEL_CHECK_TIMEOUT_SECS"] = "0.1"
    try:
        proc = subprocess.run(["bash", str(CHECK_SH), "start"],
                              capture_output=True, text=True, env=env,
                              timeout=30)
        assert proc.returncode == 0
        assert proc.stdout.strip().splitlines()[0].startswith("C1: UNKNOWN")
        assert not scoped.exists(), \
            "the .sh error branch unlinked the SAME scoped path python derives"
    finally:
        try:
            scoped.unlink()
        except FileNotFoundError:
            pass


def test_378_bash_wrapper_unlinks_the_scoped_default_on_watchdog(tmp_path):
    """#378 .sh parity: with PI_SESSION_ID set and NO PARALLEL_CHECK_TOKEN_FILE
    override, the wrapper's error-branch unlink targets the SESSION-SCOPED
    default path (a watchdog SIGKILL skips python's own cleanup — the stale
    scoped CLEAR must not survive to pass the enforcer's marker advance)."""
    sid = f"pwc378-{uuid4().hex}"
    scoped = Path(f"/tmp/parallel-check-token.{sid}.json")
    fake = _fake_interpreter(tmp_path, f'''
printf '%s' '{{"phase":"start","verdict":"CLEAR","code":"C1","ts":1}}' > "{scoped}"
sleep 30
''')
    env = dict(os.environ)
    env["PYTHON_BIN"] = str(fake)
    env["PI_SESSION_ID"] = sid
    env.pop("PARALLEL_CHECK_TOKEN_FILE", None)   # scoping must not be masked
    env["PARALLEL_CHECK_TIMEOUT_SECS"] = "0.1"
    try:
        proc = subprocess.run(["bash", str(CHECK_SH), "start"],
                              capture_output=True, text=True, env=env,
                              timeout=30)
        assert proc.returncode == 0
        assert proc.stdout.strip().splitlines()[0].startswith("C1: UNKNOWN")
        assert not scoped.exists(), \
            "the .sh error branch unlinked the SESSION-SCOPED default token"
    finally:
        try:
            scoped.unlink()
        except FileNotFoundError:
            pass
