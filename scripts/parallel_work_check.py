#!/usr/bin/env python3
"""parallel_work_check — deterministic C1-C5 parallel-work / duplicate / stale
checks (epic #4902, issue #4904).

O/I/T (plan §6 + issue #4904 review fixes):
  parallel_work_check <phase: start|scope|plan|implement|merge> [--repo PATH] [--symbol STRING]
  stdout (ONE machine-parseable line; the bash wrapper always exits 0 — callers
  parse the verdict line, never the exit code):
    <C#>: <CLEAR|STALE|OVERLAP|DUP_FIX|UNKNOWN>  [details]  [warn=<note> ...]  options=<a|b>

  No-board sessions (issue #383): a tenant with NO board signals skips the
  pure-board sub-checks with a DISTINGUISHABLE verdict —
    <C#>: CLEAR  no-board-skip: <advisory>  options=
  (never a byte-identical vacuous CLEAR; `_skip()` is the only emitter). The
  git-local checks stay retained in no-board mode (C1 fetch/guard/dup-search,
  C4 fetch/behind/symbol-gated pickaxe) and their failures still fail closed
  to UNKNOWN. warn=<note> tokens ride the verdict line (the bash wrapper's
  head -n 1 drops any standalone stdout line): token-write-failed,
  unlink-failed, near-miss:<name>, new-signal:<name>.

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
(default /tmp/parallel-check-token.json — PER-SESSION scoped to
/tmp/parallel-check-token.<sid>.json when run inside a pi session, sid =
PI_SESSION_ID; #378) is written ONLY on CLEAR; any other verdict removes
it — UNKNOWN at a gated checkpoint
means NO token, and the enforcer gate (issue #5039) blocks with
retry(2)+override. The CLEAR token payload carries mode ("" for board mode,
"no-board-skip" for no-board skips) and repo (URL form via `git remote
get-url` of the resolved ops target; "unknown" when undeterminable).
Advisory reads (C2 git-history, C4 -S) fail open to
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
  PI_SESSION_ID (set by pi in bash-tool children) — scopes the token default
  PARALLEL_CHECK_TIMEOUT_SECS (default 2.0)   — wall-clock budget
  PARALLEL_CHECK_TOKEN_FILE (default /tmp/parallel-check-token.json —
    per-session scoped to parallel-check-token.<PI_SESSION_ID>.json when
    the env carries PI_SESSION_ID, #378)
  PARALLEL_CHECK_SYMBOL                       — keyword fallback for --symbol
  PARALLEL_CHECK_REPO                         — repo fallback for --repo

The five signal families (board URL/key, card, agent, paths) are shared
module-level constants consumed by BOTH the read paths and _is_no_board;
absent = unset OR empty/whitespace (stripped value-truthiness).
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode, urlsplit
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
# #378: when run inside a pi session the default is per-session scoped to
# /tmp/parallel-check-token.<sid>.json (sid = PI_SESSION_ID); see
# _token_file_path. TOKEN_FILE_DEFAULT stays the UNSCOPED base + fallback.
BUDGET_DEFAULT = 2.0
BUDGET_MAX_DEFAULT = 60.0
GIT_HISTORY_HOURS = 72.0
SYMBOL_LOOKBACK_DAYS = 14.0
PR_PATH_CAP = 5  # max touched files sent to the open-PR search at C3

# ── #383: the FIVE signal families (14 names) — ONE set of shared constants
# consumed by BOTH the read paths (_sb_config, _paths_from_env, run_check's
# card/agent reads) AND the _is_no_board predicate, so the predicate can never
# diverge from the read paths (a names-parity B-test pins it — B23 P2).
# Absent = unset OR empty/whitespace (stripped value-truthiness).
_SB_URL_NAMES = ("PARALLEL_CHECK_SB_URL", "SUPABASE_URL_ORG_DATA",
                 "SUPABASE_URL")
_SB_KEY_NAMES = ("PARALLEL_CHECK_SB_KEY", "SUPABASE_SERVICE_ROLE_KEY_ORG_DATA",
                 "SUPABASE_SERVICE_ROLE_KEY", "SUPABASE_ANON_KEY_ORG_DATA",
                 "SUPABASE_ANON_KEY")
_CARD_ID_NAMES = ("SWARM_CARD_ID", "CARD_ID")
_AGENT_ID_NAMES = ("AGENT_ID", "SWARM_AGENT_ID")
_PATHS_NAMES = ("SWARM_TOUCHED_PATHS", "TOUCHED_PATHS")
_BOARD_NAMES = _SB_URL_NAMES + _SB_KEY_NAMES  # the 8 board signals
_SIGNAL_FAMILIES = (_SB_URL_NAMES, _SB_KEY_NAMES, _CARD_ID_NAMES,
                    _AGENT_ID_NAMES, _PATHS_NAMES)

# B27: board-signal NAMES absent from the probe-time snapshot (the committed
# consumer-env fixture inventories, scripts/testdata/consumer-env-*.names) that
# are now present → warn=new-signal:<name>. BAKED constant derived from the
# fixtures at implementation time (runtime stays stdlib-only, no file dep); the
# B27 parity test re-derives it and trips CI if a fixture adds a name. Today the
# union is empty — neither capture exports a board signal.
NEW_BOARD_SIGNAL_NAMES: tuple[str, ...] = ()

_HASH_RE = re.compile(r"^[0-9a-f]{40}$")


class InfraError(Exception):
    """Unreachable dependency or hard timeout — surfaces as UNKNOWN."""


class CheckResult:
    __slots__ = ("code", "verdict", "details", "options", "mode", "warns")

    def __init__(self, code: str, verdict: str, details: str = "",
                 options: tuple[str, ...] = ()):
        self.code = code
        self.verdict = verdict
        self.details = details
        self.options = options
        # #383: token mode ("" for board CLEAR, "no-board-skip" for skips)
        # + warn= notes that ride the verdict line (B27/B29 contract).
        self.mode = ""
        self.warns: list[str] = []

    def line(self) -> str:
        opts = "|".join(self.options)
        # keep the trailing options=<...> token unique for parsers
        details = self.details.replace("options=", "opts=")
        parts = [f"{self.code}: {self.verdict}"]
        if details:
            parts.append(f"  {details}")
        if self.warns:
            parts.append("  " + " ".join(f"warn={w}" for w in self.warns))
        parts.append(f"  options={opts}")
        return "".join(parts)

    def __repr__(self) -> str:  # pragma: no cover - debugging aid
        return self.line()


# ── env helpers ────────────────────────────────────────────────

def _env(env: dict, names: tuple[str, ...], default: str = "") -> str:
    """First STRIPPED-truthy value in the names tuple, else default.

    B23 P2: strip BEFORE truthiness — a whitespace-valued earlier name is
    absent (never shadows a valid later name in the chain, e.g. slug/
    board pairs) and a whitespace single name yields its documented
    fallback. All callers already strip/split/float their result, so this
    is behavior-preserving for valid values."""
    for name in names:
        value = env.get(name, "").strip()
        if value:
            return value
    return default


# #378: PER-SESSION token-file scoping. The token default is no longer a
# single machine-global path: when this checker runs INSIDE a pi session
# (its bash-tool child env carries PI_SESSION_ID — the SAME value the
# session's enforcer resolves via ctx.sessionManager.getSessionId()), the
# default resolves to /tmp/parallel-check-token.<sid>.json so concurrent
# sessions never share/clobber one token. Env override
# (PARALLEL_CHECK_TOKEN_FILE) wins VERBATIM (never session-scoped — an
# override is deliberate operator intent). No session (operator shell run)
# → the legacy unscoped default — the enforcer of a no-session boundary
# (auditSessionId null) reads the same unscoped path, so the contract never
# splits. Sanitization is BYTE-wise (utf-8): every byte outside
# [A-Za-z0-9._-] becomes "_" — byte-identical to the .sh wrapper's `tr -c`
# and the enforcer's Node-Buffer scope, so all three derive the same path
# from the same id (a code-point regex would map one non-ASCII char to one
# "_" while tr maps its N bytes → drift).
_SESSION_ID_ENV = "PI_SESSION_ID"
_FILENAME_SAFE_BYTES = re.compile(rb"[^A-Za-z0-9._-]")


def _session_scope_suffix(env: dict) -> str | None:
    """Sanitized per-session scope suffix from PI_SESSION_ID; None when unset
    / empty / whitespace (the caller falls back to the unscoped path). Trim is
    ASCII-whitespace-only (" \t\n\r\v\f") to mirror the TS `sessionFileScope`
    and the .sh pattern trim exactly — JS `.trim()`/python bare `.strip()`
    would also strip NBSP/BOM, which the .sh does not (an NBSP-padded id must
    sanitize to underscores on EVERY side, not trim on some)."""
    raw = (env.get(_SESSION_ID_ENV) or "").strip(" \t\n\r\v\f")
    if not raw:
        return None
    safe = _FILENAME_SAFE_BYTES.sub(
        b"_", raw.encode("utf-8", "replace")).decode("ascii")
    return safe or None


def _token_file_path(env: dict) -> str:
    """Resolve the token path: PARALLEL_CHECK_TOKEN_FILE override (verbatim,
    first stripped-truthy) → per-session scoped default → legacy unscoped
    default. Reads the TOKEN_FILE_DEFAULT module global at call time (tests
    monkeypatch it to a tmp base for hermetic scoped-path assertions)."""
    explicit = _env(env, ("PARALLEL_CHECK_TOKEN_FILE",))
    if explicit:
        return explicit
    suffix = _session_scope_suffix(env)
    if suffix is None:
        return TOKEN_FILE_DEFAULT
    base_dir = os.path.dirname(TOKEN_FILE_DEFAULT)
    stem, ext = os.path.splitext(os.path.basename(TOKEN_FILE_DEFAULT))
    return os.path.join(base_dir, f"{stem}.{suffix}{ext}")


def _paths_from_env(env: dict) -> list[str]:
    raw = _env(env, _PATHS_NAMES)
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

    def remote_url(self, timeout: float = 5.0) -> str:
        """#383: URL form of the ops target's origin (B18/B22/B26/B32).

        `git -C <repo> remote get-url origin`, trimmed; fail → "unknown"
        (both-"unknown" binding parity with the enforcer). NEVER the raw
        PARALLEL_CHECK_REPO env string and never _REPO_ROOT's remote.

        P2/P3 (code-quality round): the token's repo field must never carry a
        credential — the /tmp token file is created mode 0600 via mkstemp
        (since the P3 round), but the payload is only as safe as the string
        written into it. urlsplit: ANY non-empty userinfo on a scheme-bearing
        URL is stripped — BOTH the `user:pass@` form AND the bare-PAT form
        (`https://ghp_FAKETOKEN@github.com/org/repo.git`, NO colon — common
        for GitHub PATs-as-username) would leak the secret verbatim if left.
        The netloc is rebuilt WITHOUT userinfo (`rsplit("@", 1)[-1]`,
        host:port preserved exactly) → `https://github.com/org/repo.git`.
        This also strips `ssh://git@host/...` → `ssh://host/...` — userinfo
        is never part of repo identity. scp-form
        `git@github.com:org/repo.git` (no scheme → no netloc) is NOT a URL
        form and stays byte-identical — the normal ssh remote keeps enforcer
        binding parity. Parse failure → "unknown". URL-form contract
        otherwise unchanged.

        CRITICAL PARITY NOTE: Task 3's enforcer `bindingRepo()` MUST strip
        ALL userinfo from scheme-bearing URLs identically — a
        credential-bearing origin must bind consistently (sanitized checker
        side vs raw enforcer side would mismatch → spurious BLOCK). The
        both-"unknown" parity anchors the no-remote case.
        """
        out = self._run_ok(["remote", "get-url", "origin"], timeout)
        raw = (out or "").strip()
        if not raw:
            return "unknown"
        try:
            parts = urlsplit(raw)
        except ValueError:
            return "unknown"
        # scp-form / file URLs have empty scheme/netloc (urlsplit puts the
        # whole string in path) → the scheme+netloc guard leaves them
        # byte-identical (the normal ssh remote form).
        if parts.scheme and parts.netloc and "@" in parts.netloc:
            # P2 (code-quality round): strip ANY non-empty userinfo — the
            # `user:pass@` form AND the bare-PAT form
            # (`https://ghp_FAKETOKEN@github.com/org/repo.git`, NO colon —
            # common for GitHub PATs-as-username) both leak the credential
            # verbatim if left. Rebuild the netloc WITHOUT userinfo via
            # `rsplit("@", 1)[-1]` — host:port survive exactly. This also
            # strips `ssh://git@host/...` → `ssh://host/...`: userinfo is
            # never part of repo identity (Task 3's bindingRepo() mirrors
            # strip-ALL — simpler than the old colon heuristic).
            return parts._replace(
                netloc=parts.netloc.rsplit("@", 1)[-1]).geturl()
        return raw


def _resolve_slug(env: dict, git: GitOps, timeout: float) -> str:
    slug = _env(env, ("PARALLEL_CHECK_REPO_SLUG", "GH_REPOSITORY")).strip()
    if slug:
        return slug
    url = git._run_ok(["config", "--get", "remote.origin.url"], timeout) or ""
    match = re.search(r"github\.com[:/]([^/]+)/([^/]+?)(?:\.git)?$",
                      url.strip())
    return f"{match.group(1)}/{match.group(2)}" if match else ""


def _sb_config(env: dict) -> tuple[str, str]:
    # #383: reads the SAME shared constants the predicate consumes — the
    # 8-name board signal set can never diverge between the read path and
    # _is_no_board (B23 P2 names-parity).
    url = _env(env, _SB_URL_NAMES).strip()
    key = _env(env, _SB_KEY_NAMES).strip()
    return url, key


def _resolve_ops_target(repo: str | None, env: dict) -> str:
    """#383: ops-target chain — --repo → PARALLEL_CHECK_REPO (stripped;
    empty/whitespace falls through, never presence-keyed) → cwd. Under the
    canonical invocation cwd == _REPO_ROOT; worktree/session checkouts
    resolve to the session cwd (B18/B22/B32)."""
    if repo and repo.strip():
        return os.path.abspath(repo)
    env_repo = _env(env, ("PARALLEL_CHECK_REPO",))
    if env_repo and env_repo.strip():
        return os.path.abspath(env_repo)
    return os.path.abspath(os.getcwd())


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
                 card_id: str, token_repo: str, symbol: str) -> tuple[str, ...]:
    """Write (CLEAR) or unlink (anything else) the PASS token.

    #383 contract: CLEAR payload carries mode (res.mode) + repo (URL form via
    remote get-url of the resolved ops target — never "" and never a path
    string). The write is ATOMIC: serialize to a per-invocation-unique tmp in
    dirname(token_file) (<tokenfile>.tmp.<mkstemp-unique>) + os.rename
    (same-directory rename). On write failure the tmp is cleaned in a finally, ANY existing
    token at the target is UNLINKED (restoring the enforcer's "none found"
    BLOCK backstop) and a failure note rides the verdict line as
    warn=token-write-failed. Unlink failures surface as warn=unlink-failed —
    never silent (the old `except OSError: pass` is removed). Returns the warn
    notes for run_check to append to the verdict line.
    """
    warns: list[str] = []
    if res.verdict == "CLEAR":
        payload = {"code": res.code, "phase": phase, "verdict": "CLEAR",
                   "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                   "card_id": card_id or "", "repo": token_repo,
                   "symbol": symbol or "", "mode": res.mode}
        tmp_path: str | None = None
        try:
            directory = os.path.dirname(token_file)
            if directory:
                os.makedirs(directory, exist_ok=True)
            # P3 (code-quality round): per-INVOCATION-unique tmp via mkstemp
            # (the old `<tokenfile>.tmp.<pid>` name is pid-unique only — two
            # run_check calls in ONE process would share it and clobber each
            # other's mid-write file). mkstemp keeps the same same-dir +
            # `<tokenfile>.tmp.*` glob contract (B30/B34 pin it) and creates
            # the file mode 0600 — the renamed token inherits that 0600 (same
            # inode via os.rename), so the payload is never staged through nor
            # left in a umask-open file.
            fd, tmp_path = tempfile.mkstemp(
                dir=directory, prefix=f"{os.path.basename(token_file)}.tmp.")
            with os.fdopen(fd, "w") as handle:
                json.dump(payload, handle)
            os.rename(tmp_path, token_file)
            tmp_path = None  # consumed by the rename
        except OSError:
            warns.append("token-write-failed")
            try:
                if os.path.exists(token_file):
                    os.unlink(token_file)
            except OSError:
                warns.append("unlink-failed")
        finally:
            if tmp_path is not None and os.path.exists(tmp_path):
                try:
                    os.unlink(tmp_path)
                except OSError:
                    warns.append("unlink-failed")
    else:
        try:
            if os.path.exists(token_file):
                os.unlink(token_file)
        except OSError:
            warns.append("unlink-failed")
    return tuple(warns)


# ── #383: no-board tenant detection + distinguishable skip ──

def _is_no_board(env: dict) -> bool:
    """True iff ALL FIVE signal families are absent.

    Absent = unset OR empty/whitespace (stripped value-truthiness, NOT
    presence-keyed — no-board consumer shells ubiquitously export empty vars).
    ANY non-empty signal → False (fail-closed). The name sets are the SAME
    shared constants the read paths consume (B23 P2 names-parity).
    """
    for family in _SIGNAL_FAMILIES:
        if any((env.get(name) or "").strip() for name in family):
            return False
    return True


def _near_miss_name(env: dict) -> str | None:
    """B27: EXACTLY ONE board-signal-family member non-empty → its name
    (near-miss: a session that looks no-board except one stray board var —
    ambiguous → fail-closed UNKNOWN + warn=near-miss:<name>)."""
    non_empty = [name for name in _BOARD_NAMES
                 if (env.get(name) or "").strip()]
    return non_empty[0] if len(non_empty) == 1 else None


class _Ctx:
    __slots__ = ("code", "env", "repo", "symbol", "now", "card_id", "agent",
                 "paths", "deadline", "token_file", "store", "gh", "board",
                 "git", "guard", "repo_slug", "is_no_board")

    def remaining(self) -> float:
        return max(0.05, self.deadline - time.monotonic())

    def budget_ok(self) -> bool:
        return time.monotonic() < self.deadline

    def over_budget(self) -> CheckResult:
        return CheckResult(self.code, "UNKNOWN", "budget-exceeded")


def _skip(ctx: _Ctx, detail: str) -> CheckResult:
    """#383: the distinguishable no-board skip — CLEAR with a no-board-skip
    advisory + mode (never a byte-identical vacuous CLEAR; B15 pins the
    contract)."""
    res = CheckResult(ctx.code, "CLEAR", f"no-board-skip: {detail}")
    res.mode = "no-board-skip"
    return res


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
    if ctx.is_no_board:
        # #383: no-board tenant — the board scan is board-only and skipped;
        # fetch/guard/dup-search above are retained and still fail closed.
        if not ctx.budget_ok():
            return ctx.over_budget()
        return _skip(ctx, "no board session — board scan skipped")
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
    if ctx.is_no_board:
        # #383: claim-intent + overlap checks are board-only.
        return _skip(ctx, "no board session — claim/overlap checks skipped")
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
    if ctx.is_no_board:
        # #383: no-board tenant — open-PR overlap scope is board-only.
        return _skip(ctx, "no board session — open-PR overlap check skipped")
    if not ctx.card_id:
        # #383 (B24): the partial's vacuous `no-card-no-scope` CLEAR is
        # DELETED — board-mode-no-card fails closed (swarm-parity UNKNOWN).
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
    if ctx.is_no_board:
        # #383: no-board tenant — the git staleness gate above (fetch +
        # behind-origin) already ran; the pickaxe re-check is retained and
        # SYMBOL-GATED (never pickaxe(None) — B11/B25/B31), then skip the
        # board-scoped ancestry/symbol claims.
        if ctx.symbol:
            picks = ctx.git.pickaxe(ctx.symbol, SYMBOL_LOOKBACK_DAYS,
                                    "origin/main", ctx.remaining())
            if picks:
                return CheckResult(
                    ctx.code, "DUP_FIX",
                    f"symbol-recheck {len(picks)} commit(s)-in-14d")
        if not ctx.budget_ok():
            return ctx.over_budget()
        return _skip(ctx, "no board session — board-scoped checks skipped")
    if not ctx.card_id:
        # #383 (B24): the partial's dead `no-card` CLEAR is DELETED —
        # board-mode-no-card fails closed (swarm-parity UNKNOWN).
        return CheckResult(ctx.code, "UNKNOWN",
                           "missing-card-context SWARM_CARD_ID")
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
    if ctx.is_no_board:
        # #383: release/notify orchestration is board-only.
        return _skip(ctx, "no board session — merge orchestration skipped")
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
    token_file = _token_file_path(env)
    # #383: ops-target chain — --repo → PARALLEL_CHECK_REPO (stripped,
    # empty/whitespace falls through) → cwd (B18/B22/B32).
    repo_path = _resolve_ops_target(repo, env)
    symbol = (symbol or _env(env, ("PARALLEL_CHECK_SYMBOL",))).strip() or None
    # #383: read paths consume the SAME shared constants the predicate uses
    # (B23 P2 names-parity); stripped values = value-truthiness everywhere.
    card_id = _env(env, _CARD_ID_NAMES).strip()
    agent = _env(env, _AGENT_ID_NAMES).strip()
    paths = _paths_from_env(env)
    now = now or datetime.now(timezone.utc)
    # #383 (B23): the budget CLAMP — min(parse, PARALLEL_CHECK_BUDGET_MAX)
    # with the same env-read constant + default 60 as the .sh watchdog;
    # float("inf")/"1e309" parse WITHOUT ValueError and min() bounds them;
    # float("nan") → min(nan, max) = nan → deadline nan → budget_ok() False
    # → immediate UNKNOWN (fail-closed, acceptable).
    try:
        budget = min(
            float(_env(env, ("PARALLEL_CHECK_TIMEOUT_SECS",),
                       str(BUDGET_DEFAULT))),
            float(_env(env, ("PARALLEL_CHECK_BUDGET_MAX",),
                       str(BUDGET_MAX_DEFAULT))),
        )
    except (ValueError, OverflowError):
        budget = BUDGET_DEFAULT

    sb_url, sb_key = _sb_config(env)
    git = git or GitOps(repo_path, env)
    board = board or (BoardRest(sb_url, sb_key) if sb_url else _NoBoard())
    gh = gh or GhRest(_env(env, ("GH_API_BASE",),
                           "https://api.github.com").strip()
                      or "https://api.github.com",
                      _env(env, ("GH_TOKEN",)).strip())
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
    # #383: tenant detection — the predicate is set BEFORE the phase check
    # (after env resolution, before board construction).
    ctx.is_no_board = _is_no_board(env)

    # B27: warn notes that ride the verdict line — near-miss (exactly one
    # board-family member → UNKNOWN + warn=near-miss:<name>) and new-signal
    # (a board-signal NAME absent from the probe-time snapshot, now present).
    warns: list[str] = []
    near_miss = None if ctx.is_no_board else _near_miss_name(env)
    if near_miss is not None:
        warns.append(f"near-miss:{near_miss}")
    for name in NEW_BOARD_SIGNAL_NAMES:
        if (env.get(name) or "").strip():
            warns.append("new-signal:" + name)

    try:
        if near_miss is not None:
            # ambiguous single board signal → deterministic UNKNOWN, no check
            result = CheckResult(code, "UNKNOWN")
        else:
            result = _CHECKERS[phase](ctx)
    except InfraError as e:
        result = CheckResult(code, "UNKNOWN", str(e))
    except Exception as e:  # script-error must never crash the caller
        result = CheckResult(code, "UNKNOWN",
                             f"script-error {type(e).__name__}: {e}")

    result.warns.extend(warns)
    # P3 (code-quality round): token_repo is LAZY — resolved ONLY on a CLEAR
    # verdict. The old eager call paid a ~25ms `git remote get-url` subprocess
    # + budget slice on EVERY invocation, including UNKNOWN/STALE paths where
    # the token is never written (only CLEAR writes one). main()'s exception
    # path keeps passing "unknown".
    if result.verdict == "CLEAR":
        try:
            token_repo = git.remote_url(ctx.remaining())
        except Exception:
            token_repo = "unknown"   # same fail-safe as remote_url's internal paths
    else:
        token_repo = "unknown"
    # P3 (code-quality round): _apply_token catches OSError internally
    # (write/unlink failures → its specific warn notes); a NON-OSError (e.g.
    # a future non-serializable payload → TypeError from json.dump) would
    # propagate out of run_check and violate its documented "NEVER raises"
    # contract (currently unreachable, but the asymmetry is a latent
    # footgun). The outer wrapper ONLY contains the non-OSError class — the
    # OSError path still flows through the internal handling and its notes
    # are never swallowed (mirrors the lazy remote_url isolation just above).
    try:
        token_warns = _apply_token(result, phase, env, token_file, card_id,
                                   token_repo, symbol)
    except Exception as e:  # non-OSError only — OSError is handled inside
        token_warns = (f"token-error:{type(e).__name__}",)
    result.warns.extend(token_warns)
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
        # #383 signature-sync under the new _apply_token contract (mode/repo
        # params): the verdict is UNKNOWN, so ONLY the unlink branch can run —
        # never a CLEAR-shaped token when repo/mode are unknowable.
        # #378: the exception path resolves the SAME session-scoped default
        # (_token_file_path reads PI_SESSION_ID from os.environ).
        _apply_token(result, args.phase, dict(os.environ),
                     _token_file_path(dict(os.environ)), "", "unknown", "")
    print(result.line(), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
