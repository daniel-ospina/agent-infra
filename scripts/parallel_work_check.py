#!/usr/bin/env python3
"""parallel_work_check — deterministic C1-C5 parallel-work / duplicate / stale
checks (epic #4902, issue #4904).

O/I/T (plan §6 + issue #4904 review fixes):
  parallel_work_check <phase: start|scope|plan|implement|merge> [--repo PATH] [--symbol STRING]
  stdout (ONE machine-parseable line; the bash wrapper always exits 0 — callers
  parse the verdict line, never the exit code):
    <C#>: <CLEAR|STALE|OVERLAP|DUP_FIX|UNKNOWN>  [details]  options=<a|b>

Phases:
  C1 start     — git fetch → behind-origin check DELEGATED to checkout_guard.sh
                 (issue #4905; its 'checkout-guard VERDICT:' stdout line is
                 grepped: STALE→STALE, DEFER→STALE, CLEAR→continue, no line→
                 UNKNOWN) → closed-issue DUP_FIX search (injectable GitHub REST
                 via GH_API_BASE/GH_TOKEN — the gh CLI is NEVER used) → board
                 scan of running cards (same-issue duplicate).
  C2 scope     — write touched_paths via the #4903 update_touched_paths helper
                 (claim intent) → 72h git-history path overlap on touched
                 files: ADVISORY unless the shared-symbol booster confirms
                 (Gate A noise caveat: raw path overlap alone is NOT blocking)
                 → LIVE touched_paths overlap vs other running cards is
                 BLOCKING regardless of symbols. Live predicate (E2E-1
                 expired-lease negative): live := lease_expires_at > now()
                 PRIMARY; lease-expired / missing-lease cards are filtered
                 OUT. Board read via injectable Supabase REST URL.
  C3 plan      — open-PR search (injectable REST) on touched files →
                 OVERLAP options=rebase|notify-owner.
  C4 implement — git fetch + ahead/behind (behind>0 → STALE) → base_commit
                 ancestry drift check (HEAD≠base_commit AND base_commit not
                 an ancestor of origin/main → STALE) → `git log -S` symbol
                 re-check on origin/main (14d lookback) → DUP_FIX.
  C5 merge     — detects overlapping owners → calls #4903's
                 release_and_notify (reason overlap-after-merge) and
                 release_paths helpers (NO event-write logic in this script);
                 writes checkpoint_pass + overlap_decision events via #4903's
                 write_parallel_event helper; calls advance_phase
                 (implementing→done) on PASS.

UNKNOWN = infra/timeout (supabase-unreachable, git-timeout with bounded
env-overridable timeout, script-error). Token semantics: the PASS token
(/tmp/parallel-check-token.json, env PARALLEL_CHECK_TOKEN_FILE) is written
ONLY on CLEAR; any other verdict removes it — UNKNOWN at a gated checkpoint
means NO token, and the enforcer gate (issue #5039) blocks with
retry(2)+override. Advisory reads (C2 git-history, C4 -S) fail open to
CLEAR; phase gates never silently pass. Budget: <1s typical, ≤2s hard bound
(env PARALLEL_CHECK_TIMEOUT_SECS, default 2.0) — overrun → UNKNOWN.

Environment (all injectable, tests point them at local mocks):
  GH_API_BASE (default https://api.github.com), GH_TOKEN
  PARALLEL_CHECK_REPO_SLUG | GH_REPOSITORY   — 'owner/repo' for search q
  PARALLEL_CHECK_SB_URL | SUPABASE_URL_ORG_DATA | SUPABASE_URL
  PARALLEL_CHECK_SB_KEY | SUPABASE_SERVICE_ROLE_KEY_ORG_DATA |
    SUPABASE_SERVICE_ROLE_KEY | SUPABASE_ANON_KEY
  SWARM_CARD_ID | CARD_ID                     — our card
  AGENT_ID | SWARM_AGENT_ID                   — our agent
  SWARM_TOUCHED_PATHS | TOUCHED_PATHS         — repo-relative, ws-separated
  PARALLEL_CHECK_TIMEOUT_SECS (default 2.0)   — wall-clock budget
  PARALLEL_CHECK_TOKEN_FILE (default /tmp/parallel-check-token.json)
  PARALLEL_CHECK_SYMBOL                       — keyword fallback for --symbol
  PARALLEL_CHECK_REPO                         — repo fallback for --repo
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen

_REPO_ROOT = Path(__file__).resolve().parent.parent.parent
# Vendored layout: scripts/ lives one level under the repo root (agent-infra);
# the original lived two levels down (operations/coordination). Resolve the
# repo root as the first ancestor containing the connectors/ package so both
# layouts import cleanly.
for _anc in (Path(__file__).resolve().parent,
             Path(__file__).resolve().parent.parent,
             Path(__file__).resolve().parent.parent.parent):
    if (_anc / "connectors").is_dir():
        _REPO_ROOT = _anc
        break
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

PHASES = ("start", "scope", "plan", "implement", "merge")
PHASE_CODE = {"start": "C1", "scope": "C2", "plan": "C3",
              "implement": "C4", "merge": "C5"}
VERDICTS = ("CLEAR", "STALE", "OVERLAP", "DUP_FIX", "UNKNOWN")

TOKEN_FILE_DEFAULT = "/tmp/parallel-check-token.json"
BUDGET_DEFAULT = 2.0
GIT_HISTORY_HOURS = 72.0
SYMBOL_LOOKBACK_DAYS = 14.0
PR_PATH_CAP = 5  # max touched files sent to the open-PR search at C3

_HASH_RE = re.compile(r"^[0-9a-f]{40}$")


class InfraError(Exception):
    """Unreachable dependency or hard timeout — surfaces as UNKNOWN."""


class CheckResult:
    __slots__ = ("code", "verdict", "details", "options")

    def __init__(self, code: str, verdict: str, details: str = "",
                 options: tuple[str, ...] = ()):
        self.code = code
        self.verdict = verdict
        self.details = details
        self.options = options

    def line(self) -> str:
        opts = "|".join(self.options)
        # keep the trailing options=<...> token unique for parsers
        details = self.details.replace("options=", "opts=")
        if details:
            return f"{self.code}: {self.verdict}  {details}  options={opts}"
        return f"{self.code}: {self.verdict}  options={opts}"

    def __repr__(self) -> str:  # pragma: no cover - debugging aid
        return self.line()


# ── env helpers ────────────────────────────────────────────────

def _env(env: dict, names: tuple[str, ...], default: str = "") -> str:
    for name in names:
        value = env.get(name, "")
        if value:
            return value
    return default


def _paths_from_env(env: dict) -> list[str]:
    raw = _env(env, ("SWARM_TOUCHED_PATHS", "TOUCHED_PATHS"))
    return _normalize_paths(raw.split() if raw else [])


def _normalize_paths(paths) -> list[str]:
    out: list[str] = []
    for p in paths:
        p = (p or "").strip()
        if not p:
            continue
        p = p[2:] if p.startswith("./") else p
        if p not in out:
            out.append(p)
    return out


def _parse_ts(value: str) -> datetime | None:
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except (ValueError, AttributeError):
        return None


def _lease_live(card: dict, now: datetime) -> bool:
    """live := lease_expires_at > now() (PRIMARY; issue #4904 review fix).

    Missing/unparseable lease → NOT live → filtered out. heartbeat_at is
    secondary/advisory by design and deliberately not consulted here.
    """
    lease = _parse_ts(card.get("lease_expires_at") or "")
    return lease is not None and lease > now


# ── REST clients (injectable base URLs; urllib only) ───────────

class GhRest:
    """GitHub REST via injectable GH_API_BASE/GH_TOKEN — never the gh CLI."""

    def __init__(self, base: str, token: str, timeout: float = 5.0):
        self.base = (base or "https://api.github.com").rstrip("/")
        self.token = token
        self.timeout = timeout

    def _get(self, path: str, params: dict, timeout: float) -> dict:
        url = f"{self.base}{path}?{urlencode(params)}"
        headers = {"Accept": "application/vnd.github+json",
                   "User-Agent": "parallel-work-check/4904"}
        if self.token:
            headers["Authorization"] = f"Bearer {self.token}"
        try:
            with urlopen(Request(url, headers=headers),
                         timeout=max(0.05, timeout)) as resp:
                return json.loads(resp.read().decode("utf-8"))
        except (URLError, HTTPError, TimeoutError, OSError, ValueError) as e:
            raise InfraError(f"github-rest {self.base}: {e}") from e

    def search_closed_issues(self, repo_slug: str, symbol: str,
                             timeout: float) -> list[dict]:
        q = f"repo:{repo_slug} is:issue state:closed in:title,body {symbol}"
        data = self._get("/search/issues", {"q": q, "per_page": "5"}, timeout)
        return list(data.get("items") or [])

    def search_open_prs(self, repo_slug: str, path: str,
                        timeout: float) -> list[dict]:
        q = f"repo:{repo_slug} is:pr is:open in:path:{path}"
        data = self._get("/search/issues", {"q": q, "per_page": "5"}, timeout)
        return list(data.get("items") or [])


class BoardRest:
    """Supabase PostgREST board reads via injectable REST URL."""

    def __init__(self, base: str, key: str, timeout: float = 5.0):
        self.base = (base or "").rstrip("/")
        self.key = key
        self.timeout = timeout

    def _get(self, resource: str, params: dict, timeout: float) -> list:
        url = f"{self.base}/rest/v1/{resource}?{urlencode(params)}"
        headers = {"apikey": self.key}
        if self.key:
            headers["Authorization"] = f"Bearer {self.key}"
        try:
            with urlopen(Request(url, headers=headers),
                         timeout=max(0.05, timeout)) as resp:
                data = json.loads(resp.read().decode("utf-8"))
            return data if isinstance(data, list) else []
        except (URLError, HTTPError, TimeoutError, OSError, ValueError) as e:
            raise InfraError(f"supabase-rest {self.base}: {e}") from e

    _SELECT = ("id,issue_number,status,claimed_by,phase,touched_paths,"
               "lease_expires_at,heartbeat_at,base_commit")

    def list_cards(self, timeout: float) -> list[dict]:
        return self._get("cards", {"select": self._SELECT}, timeout)

    def get_card(self, card_id: str, timeout: float) -> dict | None:
        for card in self.list_cards(timeout):
            if card.get("id") == card_id:
                return card
        return None


# ── git operations (all bounded by the budget timeout) ─────────

class GitOps:
    def __init__(self, repo: str, env: dict | None = None):
        self.repo = repo
        self.sub_env = dict(os.environ)
        if env:
            self.sub_env.update(env)

    def _run(self, args: list[str], timeout: float) -> str:
        """Blocking git call — non-zero / timeout raises InfraError."""
        try:
            proc = subprocess.run(["git", "-C", self.repo, *args],
                                  capture_output=True, text=True,
                                  env=self.sub_env,
                                  timeout=max(0.05, timeout))
        except subprocess.TimeoutExpired as e:
            raise InfraError("git-timeout") from e
        except OSError as e:
            raise InfraError(f"git-error: {e}") from e
        if proc.returncode != 0:
            raise InfraError(
                f"git-{args[0]}-failed rc={proc.returncode}")
        return proc.stdout

    def _run_ok(self, args: list[str], timeout: float) -> str | None:
        """Advisory git call — None on any failure (fail-open reads)."""
        try:
            return self._run(args, timeout)
        except InfraError:
            return None

    def fetch(self, timeout: float) -> None:
        self._run(["fetch", "origin", "main", "--quiet"], timeout)

    def head(self, timeout: float) -> str:
        return self._run(["rev-parse", "HEAD"], timeout).strip()

    def behind(self, timeout: float) -> int:
        out = self._run(["rev-list", "--count", "HEAD..origin/main"],
                        timeout).strip()
        return int(out) if out else 0

    def is_ancestor(self, base: str, ref: str, timeout: float) -> bool | None:
        """True/False/None — None = undeterminable (missing objects)."""
        try:
            proc = subprocess.run(
                ["git", "-C", self.repo, "merge-base", "--is-ancestor",
                 base, ref], capture_output=True, env=self.sub_env,
                timeout=max(0.05, timeout))
        except (subprocess.TimeoutExpired, OSError):
            return None
        if proc.returncode == 0:
            return True
        if proc.returncode == 1:
            return False
        return None

    def history_paths(self, hours: float, rev: str, timeout: float) -> set[str]:
        """Paths touched in `git log --since=<hours>` of rev. Advisory."""
        out = self._run_ok(
            ["log", f"--since={hours:.0f} hours ago", "--name-only",
             "--pretty=format:", rev], timeout)
        if not out:
            return set()
        return {line.strip() for line in out.splitlines() if line.strip()}

    def pickaxe(self, symbol: str, days: float, rev: str,
                timeout: float) -> dict[str, set[str]]:
        """`git log -S <symbol>` in the lookback window → {hash: paths}.

        Advisory — returns {} on git failure (fail-open read).
        """
        out = self._run_ok(
            ["log", f"--since={days:.0f} days ago", "-S", symbol,
             "--name-only", "--pretty=format:%H", rev], timeout)
        commits: dict[str, set[str]] = {}
        if not out:
            return commits
        current: set[str] | None = None
        for line in out.splitlines():
            line = line.strip()
            if not line:
                continue
            if _HASH_RE.fullmatch(line):
                current = set()
                commits[line] = current
            elif current is not None:
                current.add(line)
        return commits


def _resolve_slug(env: dict, git: GitOps, timeout: float) -> str:
    slug = _env(env, ("PARALLEL_CHECK_REPO_SLUG", "GH_REPOSITORY"))
    if slug:
        return slug
    url = git._run_ok(["config", "--get", "remote.origin.url"], timeout) or ""
    match = re.search(r"github\.com[:/]([^/]+)/([^/]+?)(?:\.git)?$",
                      url.strip())
    return f"{match.group(1)}/{match.group(2)}" if match else ""


def _sb_config(env: dict) -> tuple[str, str]:
    url = _env(env, ("PARALLEL_CHECK_SB_URL", "SUPABASE_URL_ORG_DATA",
                     "SUPABASE_URL"))
    key = _env(env, ("PARALLEL_CHECK_SB_KEY",
                     "SUPABASE_SERVICE_ROLE_KEY_ORG_DATA",
                     "SUPABASE_SERVICE_ROLE_KEY",
                     "SUPABASE_ANON_KEY_ORG_DATA", "SUPABASE_ANON_KEY"))
    return url, key


def _guard_runner(repo: str, env: dict, timeout: float) -> str:
    """Run checkout_guard.sh (issue #4905) and return its stdout.

    Sourced in one bash process so checkout_guard_check() runs and emits
    its machine-parseable 'checkout-guard VERDICT:' line.
    """
    guard_sh = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                            "checkout_guard.sh")
    sub_env = dict(os.environ)
    sub_env.update(env)
    cmd = ["bash", "-c", 'source "$0" && checkout_guard_check "$1"',
           str(guard_sh), str(repo)]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True,
                              env=sub_env, timeout=max(0.05, timeout))
    except subprocess.TimeoutExpired as e:
        raise InfraError("checkout-guard-timeout") from e
    except OSError as e:
        raise InfraError(f"checkout-guard-error: {e}") from e
    return proc.stdout


# ── token (PASS evidence for the enforcer gate, issue #5039) ──

def _apply_token(res: CheckResult, phase: str, env: dict, token_file: str,
                 card_id: str, repo: str, symbol: str) -> None:
    if res.verdict == "CLEAR":
        payload = {"code": res.code, "phase": phase, "verdict": "CLEAR",
                   "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                   "card_id": card_id or "", "repo": repo,
                   "symbol": symbol or ""}
        try:
            directory = os.path.dirname(token_file)
            if directory:
                os.makedirs(directory, exist_ok=True)
            with open(token_file, "w") as handle:
                json.dump(payload, handle)
        except OSError:
            pass  # best-effort; the verdict line is authoritative
    else:
        try:
            if os.path.exists(token_file):
                os.unlink(token_file)
        except OSError:
            pass


# ── context ────────────────────────────────────────────────────

class _Ctx:
    __slots__ = ("code", "env", "repo", "symbol", "now", "card_id", "agent",
                 "paths", "deadline", "token_file", "store", "gh", "board",
                 "git", "guard", "repo_slug")

    def remaining(self) -> float:
        return max(0.05, self.deadline - time.monotonic())

    def budget_ok(self) -> bool:
        return time.monotonic() < self.deadline

    def over_budget(self) -> CheckResult:
        return CheckResult(self.code, "UNKNOWN", "budget-exceeded")


class _NoBoard:
    """Stub for a missing board URL — phase code stays ordered and specific."""

    @staticmethod
    def _fail():
        raise InfraError("supabase-unconfigured no-board-url")

    def list_cards(self, timeout):
        self._fail()

    def get_card(self, card_id, timeout):
        self._fail()


# ── phase checks ───────────────────────────────────────────────

def _check_c1(ctx: _Ctx) -> CheckResult:
    # Fresh refs first — a stale local origin/main would fake the guard.
    try:
        ctx.git.fetch(ctx.remaining())
    except InfraError as e:
        return CheckResult(ctx.code, "UNKNOWN", f"git-fetch-failed {e}")
    if not ctx.budget_ok():
        return ctx.over_budget()
    # Behind-origin check DELEGATED to checkout_guard.sh (#4905) — grep its
    # verdict line; we only handle the DUP_FIX checks ourselves.
    try:
        guard_out = ctx.guard(ctx.repo, ctx.env, ctx.remaining())
    except InfraError as e:
        return CheckResult(ctx.code, "UNKNOWN", f"checkout-guard {e}")
    match = re.search(r"^checkout-guard VERDICT:\s*(STALE|CLEAR|DEFER)\b",
                      guard_out, re.M)
    if not match:
        return CheckResult(ctx.code, "UNKNOWN",
                           "checkout-guard-no-verdict")
    if match.group(1) == "STALE":
        return CheckResult(ctx.code, "STALE",
                           "behind origin/main (checkout-guard)",
                           ("rebase",))
    if match.group(1) == "DEFER":
        # Collision (active session/dirty checkout) — not safe to start.
        return CheckResult(ctx.code, "STALE",
                           "checkout-guard DEFER: checkout collision")
    if not ctx.budget_ok():
        return ctx.over_budget()
    # Closed-issue duplicate search (injectable REST — never the gh CLI).
    if ctx.symbol:
        if not ctx.repo_slug:
            return CheckResult(ctx.code, "UNKNOWN", "repo-slug-undeterminable")
        try:
            items = ctx.gh.search_closed_issues(ctx.repo_slug, ctx.symbol,
                                                ctx.remaining())
        except InfraError as e:
            return CheckResult(ctx.code, "UNKNOWN", f"github-search {e}")
        if items:
            top = items[0]
            title = str(top.get("title") or "").strip()[:60]
            return CheckResult(ctx.code, "DUP_FIX",
                               f"closed-issue #{top.get('number')} {title}")
    # Board scan: another running card claiming the same issue.
    try:
        cards = ctx.board.list_cards(ctx.remaining())
    except InfraError as e:
        return CheckResult(ctx.code, "UNKNOWN", f"supabase {e}")
    if ctx.card_id:
        ours = next((c for c in cards if c.get("id") == ctx.card_id), None)
        if ours and ours.get("issue_number"):
            for card in cards:
                if (card.get("id") != ctx.card_id
                        and card.get("status") == "running"
                        and card.get("issue_number") == ours.get("issue_number")):
                    return CheckResult(
                        ctx.code, "DUP_FIX",
                        f"running-card {card.get('id')} same-issue "
                        f"{ours.get('issue_number')}")
    if not ctx.budget_ok():
        return ctx.over_budget()
    return CheckResult(ctx.code, "CLEAR", "ok")


def _check_c2(ctx: _Ctx) -> CheckResult:
    if not ctx.card_id or not ctx.agent:
        return CheckResult(ctx.code, "UNKNOWN",
                           "missing-card-context SWARM_CARD_ID/AGENT_ID")
    if not ctx.paths:
        return CheckResult(ctx.code, "UNKNOWN",
                           "missing-touched-paths SWARM_TOUCHED_PATHS")
    try:
        card = ctx.board.get_card(ctx.card_id, ctx.remaining())
    except InfraError as e:
        return CheckResult(ctx.code, "UNKNOWN", f"supabase {e}")
    if not card:
        return CheckResult(ctx.code, "UNKNOWN",
                           f"card-not-found {ctx.card_id}")
    # Claim intent write (#4903 helper). Owner-only; fencing → UNKNOWN.
    try:
        written = ctx.store.update_touched_paths(ctx.card_id, ctx.paths,
                                                 ctx.agent)
    except RuntimeError as e:
        return CheckResult(ctx.code, "UNKNOWN", f"update-touched-paths {e}")
    if not written:
        return CheckResult(ctx.code, "UNKNOWN",
                           "not-holder update_touched_paths-fenced")
    if not ctx.budget_ok():
        return ctx.over_budget()
    # Advisory: 72h git-history path overlap on touched files. Gate A noise
    # caveat — raw path overlap alone is NOT blocking; only a confirmed
    # shared-symbol booster escalates it.
    base = card.get("base_commit") or "HEAD"
    hist = ctx.git.history_paths(GIT_HISTORY_HOURS, base, ctx.remaining())
    shared_hist = sorted(set(ctx.paths) & hist)
    if shared_hist and ctx.symbol:
        picks = ctx.git.pickaxe(ctx.symbol, GIT_HISTORY_HOURS / 24.0, base,
                                ctx.remaining())
        if any(set(ctx.paths) & pset for pset in picks.values()):
            return CheckResult(
                ctx.code, "OVERLAP",
                f"symbol-booster-confirmed {ctx.symbol} "
                f"shared={','.join(shared_hist)}",
                ("split", "defer", "notify-owner"))
    advisory = ""
    if shared_hist:
        if ctx.symbol:
            advisory = ("advisory-history-overlap "
                        f"shared={','.join(shared_hist)} booster-not-confirmed")
        else:
            advisory = ("advisory-history-overlap "
                        f"shared={','.join(shared_hist)} no-symbol")
    # Blocking: LIVE touched_paths overlap vs other running cards.
    try:
        cards = ctx.board.list_cards(ctx.remaining())
    except InfraError as e:
        return CheckResult(ctx.code, "UNKNOWN", f"supabase {e}")
    for other in cards:
        if other.get("id") == ctx.card_id or other.get("status") != "running":
            continue
        if not _lease_live(other, ctx.now):
            continue  # lease-expired → NOT live → filtered out (E2E-1)
        shared = sorted(set(ctx.paths) & set(other.get("touched_paths") or []))
        if shared:
            return CheckResult(
                ctx.code, "OVERLAP",
                f"live-touched-paths-overlap card={other.get('id')} "
                f"shared={','.join(shared)}",
                ("split", "defer", "notify-owner"))
    if not ctx.budget_ok():
        return ctx.over_budget()
    return CheckResult(ctx.code, "CLEAR", advisory or "ok")


def _check_c3(ctx: _Ctx) -> CheckResult:
    if not ctx.card_id:
        # #383: non-swarm pipelines have no board card. With NO claimed
        # touched paths there is no overlap scope to check — CLEAR (nothing
        # can overlap). If paths ARE claimed but no card exists, keep
        # failing closed (board intent is unclaimable).
        if not ctx.paths:
            return CheckResult(ctx.code, "CLEAR", "no-card-no-scope")
        return CheckResult(ctx.code, "UNKNOWN",
                           "missing-card-context SWARM_CARD_ID")
    try:
        card = ctx.board.get_card(ctx.card_id, ctx.remaining())
    except InfraError as e:
        return CheckResult(ctx.code, "UNKNOWN", f"supabase {e}")
    if not card:
        return CheckResult(ctx.code, "UNKNOWN",
                           f"card-not-found {ctx.card_id}")
    paths = list(card.get("touched_paths") or []) or ctx.paths
    if not paths:
        return CheckResult(ctx.code, "UNKNOWN", "no-touched-paths")
    if not ctx.repo_slug:
        return CheckResult(ctx.code, "UNKNOWN", "repo-slug-undeterminable")
    for path in paths[:PR_PATH_CAP]:
        try:
            prs = ctx.gh.search_open_prs(ctx.repo_slug, path, ctx.remaining())
        except InfraError as e:
            return CheckResult(ctx.code, "UNKNOWN", f"github-search {e}")
        if prs:
            top = prs[0]
            return CheckResult(ctx.code, "OVERLAP",
                               f"open-pr #{top.get('number')} touches {path}",
                               ("rebase", "notify-owner"))
        if not ctx.budget_ok():
            return ctx.over_budget()
    return CheckResult(ctx.code, "CLEAR", "ok")


def _check_c4(ctx: _Ctx) -> CheckResult:
    try:
        ctx.git.fetch(ctx.remaining())
    except InfraError as e:
        return CheckResult(ctx.code, "UNKNOWN", f"git-fetch-failed {e}")
    try:
        behind = ctx.git.behind(ctx.remaining())
    except InfraError as e:
        return CheckResult(ctx.code, "UNKNOWN", f"ahead-behind {e}")
    if behind > 0:
        return CheckResult(ctx.code, "STALE",
                           f"behind-origin by {behind} commit(s)",
                           ("rebase",))
    if not ctx.card_id:
        # #383: non-swarm pipelines have no board card. The git staleness
        # gate above (fetch + behind-origin) already ran; the card only
        # gates board-scoped ancestry/symbol claims.
        return CheckResult(ctx.code, "CLEAR", "no-card")
    try:
        card = ctx.board.get_card(ctx.card_id, ctx.remaining())
    except InfraError as e:
        return CheckResult(ctx.code, "UNKNOWN", f"supabase {e}")
    if not card:
        return CheckResult(ctx.code, "UNKNOWN",
                           f"card-not-found {ctx.card_id}")
    # base_commit ancestry drift: the branch was cut from a commit that
    # origin/main has moved past (rewritten) → the base is stale.
    base = card.get("base_commit")
    if base:
        try:
            head = ctx.git.head(ctx.remaining())
        except InfraError as e:
            return CheckResult(ctx.code, "UNKNOWN", f"git-head {e}")
        if head != base:
            ancestor = ctx.git.is_ancestor(base, "origin/main",
                                           ctx.remaining())
            if ancestor is False:
                return CheckResult(ctx.code, "STALE",
                                   "base-commit-drift base-not-ancestor-of-"
                                   "origin/main", ("rebase",))
            if ancestor is None:
                return CheckResult(ctx.code, "UNKNOWN",
                                   "ancestry-undeterminable")
    # `git log -S` symbol re-check (14d lookback) on origin/main only —
    # our unmerged branch commits are excluded from the duplicate scan.
    if ctx.symbol:
        picks = ctx.git.pickaxe(ctx.symbol, SYMBOL_LOOKBACK_DAYS, "origin/main",
                                ctx.remaining())
        if picks:
            return CheckResult(ctx.code, "DUP_FIX",
                               f"symbol-recheck {len(picks)} commit(s)-in-14d")
    if not ctx.budget_ok():
        return ctx.over_budget()
    return CheckResult(ctx.code, "CLEAR", "ok")


def _check_c5(ctx: _Ctx) -> CheckResult:
    if not ctx.card_id or not ctx.agent:
        return CheckResult(ctx.code, "UNKNOWN",
                           "missing-card-context SWARM_CARD_ID/AGENT_ID")
    try:
        card = ctx.board.get_card(ctx.card_id, ctx.remaining())
    except InfraError as e:
        return CheckResult(ctx.code, "UNKNOWN", f"supabase {e}")
    if not card:
        return CheckResult(ctx.code, "UNKNOWN",
                           f"card-not-found {ctx.card_id}")
    paths = list(card.get("touched_paths") or []) or ctx.paths
    try:
        cards = ctx.board.list_cards(ctx.remaining())
    except InfraError as e:
        return CheckResult(ctx.code, "UNKNOWN", f"supabase {e}")
    overlaps: list[dict] = []
    for other in cards:
        if other.get("id") == ctx.card_id or other.get("status") != "running":
            continue
        if not _lease_live(other, ctx.now):
            continue
        if set(paths) & set(other.get("touched_paths") or []):
            overlaps.append(other)
    notes: list[str] = []
    # C5 owns the ORCHESTRATION: detect overlapping owners → call #4903's
    # release_and_notify helper (no event-write logic in this script);
    # overlap_decision records the split/defer/notify choice (E2E-1).
    for other in overlaps:
        try:
            ctx.store.release_and_notify(ctx.card_id, ctx.agent,
                                         "overlap-after-merge",
                                         from_card=other.get("id"))
        except RuntimeError as e:
            return CheckResult(ctx.code, "UNKNOWN",
                               f"release-and-notify {e}")
        ctx.store.write_parallel_event(
            ctx.card_id, "overlap_decision",
            {"other_card": other.get("id"), "decision": "notify"})
        notes.append(f"notified {other.get('id')}")
    # Release our lease + touched_paths (#4903 helper; owner-only fence).
    try:
        released = ctx.store.release_paths(ctx.card_id, ctx.agent)
    except RuntimeError as e:
        return CheckResult(ctx.code, "UNKNOWN", f"release-paths {e}")
    if not released:
        notes.append("release-fenced")
    # checkpoint_pass event + advance_phase on PASS (#4903 helpers).
    ctx.store.write_parallel_event(ctx.card_id, "checkpoint_pass",
                                   {"phase": "done", "checkpoint": "merge"})
    try:
        advanced = ctx.store.advance_phase(ctx.card_id, "implementing", "done",
                                           ctx.agent)
    except RuntimeError as e:
        return CheckResult(ctx.code, "UNKNOWN", f"advance-phase {e}")
    if not advanced:
        notes.append("advance-cas-miss")
    if not ctx.budget_ok():
        return ctx.over_budget()
    return CheckResult(ctx.code, "CLEAR", "released " + " ".join(notes)
                       if notes else "released")


_CHECKERS = {"start": _check_c1, "scope": _check_c2, "plan": _check_c3,
             "implement": _check_c4, "merge": _check_c5}


# ── entry point ────────────────────────────────────────────────

def run_check(phase: str, repo: str | None = None, symbol: str | None = None,
              env: dict | None = None, *, store=None, gh=None, board=None,
              guard=None, git=None, now: datetime | None = None) -> CheckResult:
    """Run one phase check. Returns a CheckResult; NEVER raises InfraError.

    All dependencies are injectable for tests: store (Supabase write
    helpers, #4903), gh (GitHub REST), board (Supabase REST reads), guard
    (checkout_guard.sh stdout runner), git (GitOps). now fixes the clock
    for lease-liveness determinism.
    """
    if phase not in PHASES:
        raise ValueError(f"phase {phase!r} not in {PHASES}")
    env = dict(os.environ if env is None else env)
    code = PHASE_CODE[phase]
    token_file = _env(env, ("PARALLEL_CHECK_TOKEN_FILE",), TOKEN_FILE_DEFAULT)
    repo_path = os.path.abspath(
        repo or _env(env, ("PARALLEL_CHECK_REPO",)) or str(_REPO_ROOT))
    symbol = (symbol or _env(env, ("PARALLEL_CHECK_SYMBOL",))).strip() or None
    card_id = _env(env, ("SWARM_CARD_ID", "CARD_ID"))
    agent = _env(env, ("AGENT_ID", "SWARM_AGENT_ID"))
    paths = _paths_from_env(env)
    now = now or datetime.now(timezone.utc)
    try:
        budget = float(_env(env, ("PARALLEL_CHECK_TIMEOUT_SECS",),
                            str(BUDGET_DEFAULT)))
    except ValueError:
        budget = BUDGET_DEFAULT

    sb_url, sb_key = _sb_config(env)
    git = git or GitOps(repo_path, env)
    board = board or (BoardRest(sb_url, sb_key) if sb_url else _NoBoard())
    gh = gh or GhRest(_env(env, ("GH_API_BASE",),
                           "https://api.github.com"),
                      _env(env, ("GH_TOKEN",)))
    if store is None:
        from connectors.supabase_swarm import store as default_store
        store = default_store()
    if guard is None:
        guard = _guard_runner

    ctx = _Ctx()
    ctx.code = code
    ctx.env = env
    ctx.repo = repo_path
    ctx.symbol = symbol
    ctx.now = now
    ctx.card_id = card_id
    ctx.agent = agent
    ctx.paths = paths
    ctx.deadline = time.monotonic() + budget
    ctx.token_file = token_file
    ctx.store = store
    ctx.gh = gh
    ctx.board = board
    ctx.git = git
    ctx.guard = guard
    ctx.repo_slug = _resolve_slug(env, git, ctx.remaining())

    try:
        result = _CHECKERS[phase](ctx)
    except InfraError as e:
        result = CheckResult(code, "UNKNOWN", str(e))
    except Exception as e:  # script-error must never crash the caller
        result = CheckResult(code, "UNKNOWN",
                             f"script-error {type(e).__name__}: {e}")

    _apply_token(result, phase, env, token_file, card_id, repo_path, symbol)
    return result


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="parallel_work_check",
        description="C1-C5 parallel-work / duplicate / stale checks (#4904)")
    parser.add_argument("phase", choices=PHASES)
    parser.add_argument("--repo", default=None)
    parser.add_argument("--symbol", default=None)
    args = parser.parse_args(argv)

    try:
        result = run_check(args.phase, repo=args.repo, symbol=args.symbol)
    except Exception as e:  # defense-in-depth: still emit a verdict line
        result = CheckResult(PHASE_CODE[args.phase], "UNKNOWN",
                             f"script-error {type(e).__name__}: {e}")
        _apply_token(result, args.phase, dict(os.environ),
                     _env(dict(os.environ), ("PARALLEL_CHECK_TOKEN_FILE",),
                          TOKEN_FILE_DEFAULT), "", "", "")
    print(result.line(), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
