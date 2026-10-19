#!/usr/bin/env python3
"""Proof that the DELIVERY line survives a GraphQL refusal — and never invents a number.

WHY THIS FILE EXISTS. `compute()` built BOTH PR lists with `gh pr list --json`, which is
GraphQL. Under fleet concurrency GitHub refuses that read on the SECONDARY limit while the
primary budget is nearly untouched (measured 2026-10-19: core 1599/5000, graphql
4612/5000, one REST call answering in 0.43 s with 17 concurrent gh clients on one box).
The beat then printed `DELIVERY: unavailable (metrics read failed)` — the fleet losing its
own progress measurement, the number the owner reads, while a readable source existed.

The rules pinned here, in both directions:
  * a GraphQL refusal with REST healthy still produces a REAL line, `merged_today` included;
  * BOTH sources refused keeps the `unavailable` path — the honesty invariant is not traded
    away to make the happy case green;
  * REST's `closed` window never counts a PR closed WITHOUT merging as merged;
  * a failed GraphQL read NEVER yields a mixed-source read (a REST open-count beside a
    GraphQL merged-count compares two differently-wrong reads);
  * the token travels in an Authorization header and is printed nowhere, on the REAL transport
    path and not only where the transport is stubbed;
  * the REST path PAGES the whole requested window (REST caps `per_page` at 100, the callers
    ask for 500/400) and refuses a partial one — a silently short list under-counts
    `merged_today`, which is the one error this fallback must not add.

The module is loaded BY LOCATION, exactly as the heartbeat executes it — never a copy:
`scripts/orchestrator-heartbeat.sh` runs `python3 scripts/beta-progress.py`.

Run:  python3 -m pytest scripts/test_beta_progress.py -q
"""
from __future__ import annotations

import importlib.util
import pathlib

import pytest

# ── THE MODULE UNDER TEST ───────────────────────────────────────────────────
_SPEC = importlib.util.spec_from_file_location(
    "beta_progress_under_test", pathlib.Path(__file__).with_name("beta-progress.py"))
bp = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(bp)

# ⛔ A FAR-FUTURE merge stamp, not the current instant: `compute()` recomputes today's UTC
# midnight at CALL time, so a stamp captured at import is "yesterday" for any run that
# straddles midnight — and the assertion would red for the clock, not the code. 2999 can
# never be before any "today" the module computes; 2020 can never be after one.
MERGED_TODAY = "2999-01-01T00:00:00Z"
LONG_AGO = "2020-01-01T00:00:00Z"


def pr(number, merged="", ref=None, title=None):
    """One row in the `gh pr list --json` shape this file consumes."""
    return {
        "number": number,
        "title": "PR %d" % number if title is None else title,
        "headRefName": ("fix/%d-x" % number) if ref is None else ref,
        "mergedAt": merged,
    }


def rest_row(number, merged_at=None, ref=None, title=None):
    """One row in the REST `/pulls` shape, before `_rest_prs` maps it."""
    return {
        "number": number,
        "title": "PR %d" % number if title is None else title,
        "head": {"ref": ("fix/%d-x" % number) if ref is None else ref},
        "merged_at": merged_at,
    }


@pytest.fixture
def no_cache(tmp_path, monkeypatch):
    """`main()` must read/write a scratch cache, never the live loop's state file."""
    cache = tmp_path / "beta-progress.json"
    monkeypatch.setattr(bp, "CACHE", str(cache))
    return cache


# ── (a) GraphQL refused + REST healthy -> a REAL line, merged_today included ──
def test_graphql_failure_uses_rest_and_still_counts_merged_today(monkeypatch, no_cache, capsys):
    """The measured 2026-10-19 failure: `gh pr list` refused, REST answering.

    Without the fallback this printed `DELIVERY: unavailable (metrics read failed)` for
    whole cycles. The assertion that matters is not "it did not crash" — it is that the
    line the owner reads carries a NUMBER, and that `merged_today` was computed from the
    merged window rather than defaulted to 0.
    """
    gh_calls, rest_calls = [], []

    def fake_gh(*args):
        gh_calls.append(args)
        if args[:2] == ("pr", "list"):
            return None          # the SECONDARY-limit refusal this fix answers
        return []                # the P0/P1 issue reads still answer

    def fake_rest(state, limit=100):
        rest_calls.append((state, limit))
        if state == "open":
            return [pr(1), pr(2)]
        return [pr(3, merged=MERGED_TODAY), pr(4, merged=LONG_AGO)]

    monkeypatch.setattr(bp, "gh", fake_gh)
    monkeypatch.setattr(bp, "_rest_prs", fake_rest)

    out = bp.compute()
    assert out is not None
    assert out["open_prs"] == 2
    assert out["merged_today"] == 1
    # BOTH lists were re-read over REST, at the windows the GraphQL calls ask for.
    assert ("open", 500) in rest_calls
    assert ("merged", 400) in rest_calls

    assert bp.main() == 0
    printed = capsys.readouterr().out
    assert "unavailable" not in printed
    assert "2 open PRs, 1 merged today" in printed


# ── (b) BOTH sources refused -> the `unavailable` path must survive ───────────
def test_both_sources_failing_keeps_the_unavailable_path(monkeypatch, no_cache, capsys):
    """The honesty invariant. A fix that made the happy case green by inventing a number
    (0 open PRs, 0 merged) would be strictly worse than the loud `unavailable` line: an
    empty list must never stand as evidence of absence."""
    monkeypatch.setattr(bp, "gh", lambda *a: None if a[:2] == ("pr", "list") else [])
    monkeypatch.setattr(bp, "_rest_prs", lambda state, limit=100: None)

    assert bp.compute() is None
    assert bp.main() == 0
    printed = capsys.readouterr().out
    assert "DELIVERY: unavailable (metrics read failed)" in printed


# ── (c) REST `closed` also carries unmerged PRs -> excluded ──────────────────
def test_rest_closed_window_excludes_unmerged_prs(monkeypatch):
    """`gh pr list --state merged` never returned a closed-unmerged PR, so REST must not
    either: counting one would inflate `merged_today` with abandoned work. The filter is
    state-specific — the OPEN window legitimately contains rows with no `merged_at`."""
    monkeypatch.setattr(bp, "_token", lambda: "test-token")
    rows = [
        rest_row(11, merged_at=MERGED_TODAY, ref="fix/11-a", title="merged today"),
        rest_row(12, merged_at=None, ref="fix/12-b", title="closed, never merged"),
        rest_row(13, merged_at=LONG_AGO, ref="fix/13-c"),
    ]
    monkeypatch.setattr(bp, "_rest_get_json", lambda url, tok, timeout=None: list(rows))

    merged = bp._rest_prs("merged")
    assert merged is not None
    assert [p["number"] for p in merged] == [11, 13]
    # The `gh pr list --json` shape, mapped out of the REST field names.
    assert merged[0] == {"number": 11, "title": "merged today",
                         "headRefName": "fix/11-a", "mergedAt": MERGED_TODAY}

    opened = bp._rest_prs("open")
    assert opened is not None
    assert [p["number"] for p in opened] == [11, 12, 13], (
        "the merged_at filter must apply to the CLOSED window only — the open list keeps "
        "every row, including ones that were never merged")


# ── (d) the same-source rule: never a mixed read ─────────────────────────────
def test_a_failed_graphql_read_never_produces_a_mixed_source_read(monkeypatch):
    """If EITHER GraphQL read fails, BOTH lists come from REST.

    A REST open-count beside a GraphQL merged-count compares two differently-wrong reads,
    and the two counts are read together (`merged_today` against the open window's PRs).
    The fixture makes the two sources DISAGREE on every field, so a mixed read is
    observable rather than a matter of trust.
    """
    calls = []

    def fake_gh(*args):
        calls.append(args)
        if args[:2] != ("pr", "list"):
            return []
        # GraphQL: open succeeds with 7 PRs, merged is refused.
        if "--state" in args and args[args.index("--state") + 1] == "open":
            return [pr(n) for n in range(1, 8)]
        return None

    def fake_rest(state, limit=100):
        if state == "open":
            return [pr(100), pr(101)]          # REST's open window: 2, not 7
        return [pr(200, merged=LONG_AGO)]      # no PR merged today

    monkeypatch.setattr(bp, "gh", fake_gh)
    monkeypatch.setattr(bp, "_rest_prs", fake_rest)

    out = bp.compute()
    assert out is not None
    assert out["open_prs"] == 2, (
        "the SUCCESSFUL GraphQL open read must be DISCARDED once the merged read fell back "
        "— a mixed REST-open/GraphQL-merged count is the defect this rule forbids")
    assert out["merged_today"] == 0

    # The mirror: the MERGED read succeeds and the OPEN read is refused. Nothing from the
    # GraphQL merged window may survive beside the REST open window either.
    def fake_gh_mirror(*args):
        if args[:2] != ("pr", "list"):
            return []
        if "--state" in args and args[args.index("--state") + 1] == "merged":
            return [pr(300, merged=LONG_AGO)]  # GraphQL says: 0 merged today
        return None

    def fake_rest_mirror(state, limit=100):
        if state == "open":
            return [pr(400), pr(401), pr(402), pr(403)]
        return [pr(500, merged=MERGED_TODAY), pr(501, merged=LONG_AGO)]   # REST says: 1

    monkeypatch.setattr(bp, "gh", fake_gh_mirror)
    monkeypatch.setattr(bp, "_rest_prs", fake_rest_mirror)

    out = bp.compute()
    assert out is not None
    assert out["open_prs"] == 4
    assert out["merged_today"] == 1, (
        "merged_today must come from the SAME source as the open window, not from the "
        "GraphQL read that survived")


# ── (e) the window is PAGED, and a partial read is refused ──────────────────
def test_rest_pages_the_requested_window_and_refuses_a_partial_read(monkeypatch):
    """REST caps `per_page` at 100 while the callers ask for 500 (open) and 400 (merged),
    so one request is NOT the window. Reading only the first page would return 100 of 400
    merged PRs at rc 0 — a silent under-count of `merged_today`, which is worse than the
    `unavailable` line it replaces."""
    monkeypatch.setattr(bp, "_token", lambda: "test-token")
    seen_urls = []

    def fake_get(url, tok, timeout=None):
        seen_urls.append(url)
        page = int(url.rsplit("page=", 1)[1])
        # A full 100-row page. The single merged-today PR sits on the LAST page of the
        # 400 window, i.e. exactly the row a single-request read would lose.
        rows = [rest_row(page * 1000 + n, merged_at=LONG_AGO) for n in range(100)]
        if page == 4:
            rows[-1] = rest_row(9999, merged_at=MERGED_TODAY)
        return rows

    monkeypatch.setattr(bp, "_rest_get_json", fake_get)

    merged = bp._rest_prs("merged", limit=400)
    assert merged is not None
    assert len(merged) == 400
    assert len(seen_urls) == 4, "a 400 window is 4 requests at per_page=100, not one"
    assert [u.rsplit("page=", 1)[1] for u in seen_urls] == ["1", "2", "3", "4"]
    assert all("per_page=100" in u for u in seen_urls)
    assert all("state=closed" in u for u in seen_urls)
    assert any(p["mergedAt"] == MERGED_TODAY for p in merged), (
        "the merged-today PR lived on page 4 — a single-page read would report 0")

    # A page that cannot be read returns None for the WHOLE read: a partial list is
    # indistinguishable from a complete one at the call site.
    def failing_get(url, tok, timeout=None):
        page = int(url.rsplit("page=", 1)[1])
        return None if page == 3 else [rest_row(page * 1000 + n, merged_at=LONG_AGO)
                                       for n in range(100)]

    monkeypatch.setattr(bp, "_rest_get_json", failing_get)
    assert bp._rest_prs("merged", limit=400) is None

    # Budget spent -> REFUSE, never a short window: a truncated 400-row read would report a
    # `merged_today` that looks like a measurement. The caller's own bound — the heartbeat tick
    # that runs this refresh is killed, so this must not page past it — is why the read refuses
    # instead. The transport is HEALTHY here, so a pass can only come from the budget guard.
    asked = []
    monkeypatch.setattr(bp, "_rest_get_json",
                        lambda url, tok, timeout=None: asked.append(url) or [rest_row(1)])
    monkeypatch.setattr(bp, "REST_BUDGET_S", 0)
    assert bp._rest_prs("merged", limit=400) is None
    assert asked == [], "a spent budget must refuse BEFORE issuing a request"

    # No readable token is also "no read", never an empty list — and it must not reach the
    # network at all: an unauthenticated /pulls answers a 60-request anonymous bucket and
    # then refuses, which would look like a source failure instead of a missing credential.
    monkeypatch.setattr(bp, "REST_BUDGET_S", 45)   # undo the spent budget above
    reached = []
    monkeypatch.setattr(bp, "_rest_get_json",
                        lambda url, tok, timeout=None: reached.append(url) or [rest_row(1)])
    monkeypatch.setattr(bp, "_token", lambda: "")
    assert bp._rest_prs("open", limit=500) is None
    assert reached == [], "an unauthenticated read must be refused BEFORE any request"


# ── token: env first, then gh's hosts.yml — and never on stdout ─────────────
def test_token_prefers_env_then_hosts_yml_and_is_never_logged(monkeypatch, tmp_path, no_cache, capsys):
    """The REST read authenticates with a token this process OWNS. Two contracts: it is
    resolved without a `gh` subprocess (the whole point — `gh` is what is refusing), and it
    never reaches a log line or the DELIVERY output."""
    monkeypatch.delenv("GH_TOKEN", raising=False)
    monkeypatch.delenv("GITHUB_TOKEN", raising=False)
    monkeypatch.setenv("HOME", str(tmp_path))

    hosts = tmp_path / ".config" / "gh" / "hosts.yml"
    hosts.parent.mkdir(parents=True)
    hosts.write_text(
        "github.com:\n"
        "    user: someone\n"
        "    oauth_token: 'gho_from_hosts_yml'\n"
        "    git_protocol: https\n")

    assert bp._token() == "gho_from_hosts_yml"          # quotes stripped

    monkeypatch.setenv("GH_TOKEN", "gho_from_env")      # the fleet's own env wins
    assert bp._token() == "gho_from_env"

    hosts.unlink()                                       # no file, no env -> falsy, not None
    monkeypatch.delenv("GH_TOKEN")
    assert not bp._token()

    # A full failing read must not print the token anywhere.
    monkeypatch.setenv("GH_TOKEN", "gho_secret_marker")
    monkeypatch.setattr(bp, "gh", lambda *a: None if a[:2] == ("pr", "list") else [])
    monkeypatch.setattr(bp, "_rest_get_json", lambda url, tok, timeout=None: None)
    assert bp.compute() is None
    assert bp.main() == 0
    captured = capsys.readouterr()
    assert "gho_secret_marker" not in (captured.out + captured.err)


# ── the REAL transport: the token travels in a header, never in output ──────
def test_the_real_request_path_sends_the_token_in_a_header_and_never_prints_it(monkeypatch, capsys):
    """Every other test stubs `_rest_get_json`, so a `print(tok)` INSIDE it would ship green —
    the one function that holds the credential would be pinned by nothing (the inert-enforcer
    class). This drives the shipped transport against a fake `urlopen`: the credential must
    reach the wire as an `Authorization` header and appear in no output, on success AND on
    failure (an exception message is where a credential most often escapes)."""
    seen = {}

    class _Resp:
        def __init__(self, payload):
            self._payload = payload

        def read(self):
            return self._payload

        def __enter__(self):
            return self

        def __exit__(self, *exc):
            return False

    def fake_urlopen(req, timeout=None):
        seen["url"] = req.full_url
        seen["auth"] = req.get_header("Authorization")
        seen["timeout"] = timeout
        return _Resp(b'[{"number": 1, "head": {"ref": "x"}, "merged_at": null}]')

    monkeypatch.setattr(bp.urllib.request, "urlopen", fake_urlopen)
    out = bp._rest_get_json("https://api.github.com/repos/o/r/pulls?state=open",
                            "gho_real_path_token")
    assert out == [{"number": 1, "head": {"ref": "x"}, "merged_at": None}]
    assert seen["auth"] == "bearer gho_real_path_token", (
        "the credential must be a HEADER — never part of the URL, which is logged everywhere")
    assert "gho_real_path_token" not in seen["url"]
    assert seen["timeout"] == bp.REST_TIMEOUT_S

    def boom(req, timeout=None):
        raise OSError("connection refused")

    monkeypatch.setattr(bp.urllib.request, "urlopen", boom)
    assert bp._rest_get_json("https://api.github.com/x", "gho_real_path_token") is None

    captured = capsys.readouterr()
    assert "gho_real_path_token" not in (captured.out + captured.err), (
        "the transport must not print the credential on either path")
