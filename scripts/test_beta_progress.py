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
  * the fallback is a FALLBACK — a healthy GraphQL read pays for no REST — and a failed OPEN
    read short-circuits the merged one, because the pair shares ONE budget;
  * the token is host-associated and keyring-capable, and travels in an Authorization header
    printed nowhere, on the REAL transport
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

    deadlines = []

    def fake_rest(state, limit=100, deadline=None):
        rest_calls.append((state, limit))
        deadlines.append(deadline)
        if state == "open":
            return [pr(1), pr(2)]
        return [pr(3, merged=MERGED_TODAY), pr(4, merged=LONG_AGO)]

    monkeypatch.setattr(bp, "gh", fake_gh)
    monkeypatch.setattr(bp, "_rest_prs", fake_rest)

    out = bp.compute()
    assert out is not None
    assert out["open_prs"] == 2
    assert out["merged_today"] == 1
    # BOTH lists were re-read over REST, at the windows the GraphQL calls ask for, and the PAIR
    # shares ONE deadline: a per-read budget doubles the phase's worst case inside a tick that is
    # killed (the doc states the shared budget as a rule, so the suite must hold it).
    assert ("open", 500) in rest_calls
    assert ("merged", 400) in rest_calls
    assert deadlines[0] is not None
    assert deadlines[0] == deadlines[1], "the pair must share one deadline"

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
    rest_attempts = []
    monkeypatch.setattr(bp, "_rest_prs",
                        lambda state, **k: rest_attempts.append(state) or None)

    assert bp.compute() is None
    assert rest_attempts == ["open"], (
        "once the OPEN REST read has failed the merged one cannot be used (the guard needs "
        "both), so spending the shared budget on it only starves the tick")
    assert bp.main() == 0
    printed = capsys.readouterr().out
    assert "DELIVERY: unavailable (metrics read failed)" in printed


# ── the exit-0 promise survives an UNEXPECTED failure, not just a refused one ──
def test_main_prints_the_unavailable_line_even_if_compute_raises(monkeypatch, no_cache, capsys):
    """`main()`'s contract is "Exit 0 always — a metrics failure must never take the heartbeat
    down with it", and the heartbeat pipes stderr away
    (`orchestrator-heartbeat.sh:181`): an exception here prints NOTHING where the operator needs
    the `unavailable` line. Measured before this guard: a page whose `number` was an object
    raised TypeError out of `sys.exit(main())` and produced no line at all. The row guards make
    that payload unreachable; this pins the belt that keeps a FUTURE one from silencing the beat.
    """
    def boom():
        raise RuntimeError("a shape guard missed something")

    monkeypatch.setattr(bp, "compute", boom)
    assert bp.main() == 0
    assert "DELIVERY: unavailable (metrics read failed)" in capsys.readouterr().out


# ── the CACHE-HIT path is the one taken most beats, and it must not go silent ──
def test_a_cache_this_version_cannot_render_falls_through_to_a_real_line(monkeypatch, no_cache, capsys):
    """The cache-hit path is ~15 of every 16 beats (TTL 1800 s, heartbeat ~2 min) and it sits
    ABOVE the `compute()` guard, so a cache written by another schema, or truncated, used to rise
    out of `sys.exit(main())` and print NOTHING — measured: `{"ts": <now>}` → KeyError 'p0',
    `{"ts": <now>, "p0": {}}` → KeyError 'open', `open_prs: "many"` → TypeError in `%d`. The
    heartbeat pipes stderr away, so the beat simply loses the line. A cache this version cannot
    render is not a cache: it now falls through to `compute()` (which answers or says
    `unavailable`), and the render is guarded as well.
    """
    import json as _json
    import time as _time

    bad = [
        {"ts": int(_time.time())},                                    # no p0/p1 at all
        {"ts": int(_time.time()), "p0": {}},                         # stops one level short
        {"ts": int(_time.time()), "p0": {"open": 1}, "p1": {"open": 1},
         "open_prs": 1, "merged_today": 1},                           # tier keys missing
        {"ts": int(_time.time()), "p0": {"open": "many", "with_pr": 0, "without": 0},
         "p1": {"open": 0, "with_pr": 0, "without": 0},
         "open_prs": 1, "merged_today": 1},                           # `%d` on a str
        [1, 2, 3],                                                    # not even a mapping
    ]
    for cached in bad:
        no_cache.write_text(_json.dumps(cached))
        # `compute()` is stubbed to fail so the assertion is about the CACHE path, not the fetch.
        monkeypatch.setattr(bp, "compute", lambda: None)
        assert bp.main() == 0, cached
        out = capsys.readouterr().out
        assert "DELIVERY: unavailable (metrics read failed)" in out, cached

    # AND THE VALIDATION ITSELF, separately from the render guard: an unusable cache must FALL
    # THROUGH to a fresh read, not merely fail loudly. Here `compute()` answers properly, so the
    # line has to carry the FRESH numbers — if the bad cache were used, the render guard would
    # print `unavailable` and this assertion fails.
    no_cache.write_text(_json.dumps({"ts": int(_time.time()), "open_prs": 99, "merged_today": 99}))
    fresh = {"ts": int(_time.time()), "open_prs": 2, "merged_today": 1,
             "p0": {"open": 1, "with_pr": 1, "without": 0},
             "p1": {"open": 0, "with_pr": 0, "without": 0}}
    monkeypatch.setattr(bp, "compute", lambda: fresh)
    assert bp.main() == 0
    out = capsys.readouterr().out
    assert "unavailable" not in out, out
    assert "2 open PRs, 1 merged today" in out, out


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

    def fake_rest(state, limit=100, deadline=None):
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

    def fake_rest_mirror(state, limit=100, deadline=None):
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
    # The ORDER is what makes the window sound: a PR merged today was updated today, so
    # `updated desc` puts it inside the window. Without it the window is the 400
    # most-recently-CREATED closed PRs and `merged_today` silently under-counts.
    assert all("sort=updated&direction=desc" in u for u in seen_urls)
    assert any(p["mergedAt"] == MERGED_TODAY for p in merged), (
        "the merged-today PR lived on page 4 — a single-page read would report 0")

    # ⛔ THE OPEN READ IS A DIFFERENT BRANCH of the same function and gets no coverage from
    # the assertions above: they are all made on the merged window, and `fake_get` ignores the
    # URL. So `path = "closed"` unconditionally (open_prs would report the CLOSED count) and
    # a cap of 100 on the open window both survived this test 10/10 — each a wrong NUMBER,
    # which is exactly the class the fallback must not introduce. Pin the open URL and window.
    seen_urls.clear()
    open_rows = bp._rest_prs("open", limit=500)
    assert open_rows is not None and len(open_rows) == 500, (
        "a 500 window is 500 rows — a capped or single-page read under-counts open_prs")
    assert len(seen_urls) == 5, "a 500 window is 5 requests at per_page=100, not one"
    assert all("state=open" in u for u in seen_urls), (
        "the open read must ask for state=open — REST's `closed` window would answer a "
        "DIFFERENT count and `open_prs` would silently report it")
    assert all("per_page=100" in u for u in seen_urls)
    assert all("sort=updated&direction=desc" in u for u in seen_urls)

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
    monkeypatch.setattr(bp, "REST_BUDGET_S", 30)   # undo the spent budget above
    reached = []
    monkeypatch.setattr(bp, "_rest_get_json",
                        lambda url, tok, timeout=None: reached.append(url) or [rest_row(1)])
    monkeypatch.setattr(bp, "_token", lambda: "")
    assert bp._rest_prs("open", limit=500) is None
    assert reached == [], "an unauthenticated read must be refused BEFORE any request"


# ── a row that moves across a page boundary REFUSES the window ──────────────
def test_a_row_that_moves_across_a_page_boundary_refuses_the_window(monkeypatch):
    """The window is paged by OFFSET over a LIVE order (`sort=updated&direction=desc`). A PR
    updated mid-read jumps to offset 0 — INSIDE the page already read — and every row below it
    shifts down by one. That is ONE event, and it produces the two symptoms the guard is about:

      * the row that sat at the END of the page just read is pushed across the boundary and
        returned a SECOND time by the next page (the double-count);
      * the mover itself is at offset 0, already behind the cursor, so it is returned by NO page
        (the missing row — for the closed window, exactly the PR that just merged).

    Filtering the duplicate fixes only the first and leaves the second silently short — the
    class this file refuses to report. A repeat can only arise from the list changing between
    two requests, so it is a SOUND detector for this direction: the read refuses. Measured with
    the shipped loop: #150 bumped after page 1 → `100` repeated, `150` never returned.
    """
    monkeypatch.setattr(bp, "_token", lambda: "test-token")

    def shifted(url, tok, timeout=None):
        page = int(url.rsplit("page=", 1)[1])
        if page == 1:
            # Served BEFORE the bump: the natural order 1..100.
            return [rest_row(n, merged_at=MERGED_TODAY) for n in range(1, 101)]
        # Served AFTER #150 bumped to the head: offset 100 now lands on 100 (already read),
        # and #150 itself is at offset 0 — behind the cursor, never returned.
        return [rest_row(n) for n in range(100, 200)]

    monkeypatch.setattr(bp, "_rest_get_json", shifted)
    assert bp._rest_prs("open", limit=200) is None, (
        "a repeat proves the list moved mid-read, and a moved list is also a SHORT one — the "
        "window cannot be certified, so it must not be returned (keeping the window would "
        "hide the missing row)")

    # The other direction: a shift that stays INSIDE one page produces no repeat and costs
    # nothing, so the refusal is not a blanket one — a stable read of the same window is an
    # ANSWER, and that is what the happy-path tests rely on.
    def stable(url, tok, timeout=None):
        page = int(url.rsplit("page=", 1)[1])
        return [rest_row(n) for n in range((page - 1) * 100 + 1, page * 100 + 1)]

    monkeypatch.setattr(bp, "_rest_get_json", stable)
    rows = bp._rest_prs("open", limit=200)
    assert rows is not None and len(rows) == 200
    assert len({r["number"] for r in rows}) == 200


def test_a_repeat_from_a_NON_COUNTED_row_still_refuses_the_window(monkeypatch):
    """The repeat is evidence about the LIST, not about which rows count. In the MERGED window the
    closed-without-merge rows are dropped, and the row that shifts a live `updated desc` order
    mid-read is very often one of those (closed without merging, re-labelled, superseded) — so a
    check placed AFTER the drop never sees the only sound signal the read has. Measured before
    this ordering fix: 100 unmerged rows on page 1, then one PR merges (now at offset 0) and
    unmerged row 100 repeats on page 2 — the guard never fired and the read returned 0 rows, a
    REAL "0 merged today" line while the truth was 1. That is the false zero the file header
    says was fixed on 2026-10-01.
    """
    monkeypatch.setattr(bp, "_token", lambda: "test-token")
    calls = []

    def pages(url, tok, timeout=None):
        page = int(url.rsplit("page=", 1)[1])
        calls.append(page)
        if page == 1:
            return [rest_row(n) for n in range(1, 101)]              # unmerged closed rows
        if page == 2:
            return [rest_row(100)] + [rest_row(n) for n in range(101, 200)]   # #100 repeats
        return [rest_row(n) for n in range(200, 205)]               # short page ends the read

    monkeypatch.setattr(bp, "_rest_get_json", pages)
    assert bp._rest_prs("merged", limit=400) is None, (
        "the repeat was of a row the merged filter DROPS — it is still proof the list moved, and "
        "the moved list is also the short one")
    assert calls == [1, 2], calls


# ── token: env first, then gh's hosts.yml — and never on stdout ─────────────
def test_token_prefers_env_then_hosts_yml_and_is_never_logged(monkeypatch, tmp_path, no_cache, capsys):
    """The REST read authenticates with a token this process OWNS, and never prints it.

    Three box shapes drive this: the plain hosts.yml, one that relocates its config
    (`GH_CONFIG_DIR`), and one whose hosts.yml lists ANOTHER host first — reading the first
    `oauth_token:` line in that file sends a GHES token to api.github.com, i.e. a 401 that
    reads as "REST is down". A keyring-backed config has no `oauth_token:` at all, so
    `gh auth token` (an OFFLINE lookup the layer does not count as a request) is the last
    resort. An ambient `GH_CONFIG_DIR` must not leak into the first assertion.
    """
    monkeypatch.delenv("GH_TOKEN", raising=False)
    monkeypatch.delenv("GITHUB_TOKEN", raising=False)
    monkeypatch.delenv("GH_CONFIG_DIR", raising=False)
    monkeypatch.setenv("HOME", str(tmp_path))

    # No credential on the box: the subprocess path must answer "no token", not raise.
    class _NoAuth:
        returncode = 1
        stdout = ""
        stderr = ""

    monkeypatch.setattr(bp.subprocess, "run", lambda *a, **k: _NoAuth())

    hosts = tmp_path / ".config" / "gh" / "hosts.yml"
    hosts.parent.mkdir(parents=True)
    hosts.write_text(
        "github.com:\n"
        "    user: someone\n"
        "    oauth_token: 'gho_from_hosts_yml'\n"
        "    git_protocol: https\n")

    assert bp._token() == "gho_from_hosts_yml"          # quotes stripped

    # gh's own GH_CONFIG_DIR override — the harness already honours it, and ignoring it
    # makes the fallback silently inert on a box that relocates its config.
    moved = tmp_path / "elsewhere"
    (moved / "gh").mkdir(parents=True)
    (moved / "gh" / "hosts.yml").write_text("github.com:\n    oauth_token: gho_relocated\n")
    monkeypatch.setenv("GH_CONFIG_DIR", str(moved / "gh"))
    assert bp._token() == "gho_relocated"
    monkeypatch.delenv("GH_CONFIG_DIR")

    # A hosts.yml that lists another host FIRST must not donate that host's token.
    hosts.write_text(
        "ghe.corp.example:\n"
        "    oauth_token: GHES_MUST_NOT_BE_USED\n"
        "github.com:\n"
        "    oauth_token: gho_right_host\n")
    assert bp._token() == "gho_right_host"

    # ⛔ AND DEPTH: gh's multi-account config nests per-user credentials under `users:`, with
    # the nested entry FIRST. "First oauth_token inside the github.com block" therefore answers
    # ANOTHER account's token — a 401/404 against api.github.com that reads as "REST is down",
    # or a read spent on the wrong account's quota. Nothing at the block's OWN depth means no
    # token from the file; here there is no credential either, so the answer is empty.
    hosts.write_text(
        "github.com:\n"
        "    users:\n"
        "        other:\n"
        "            oauth_token: gho_OTHER_ACCOUNT\n"
        "        active:\n"
        "            oauth_token: gho_ACTIVE_NESTED\n"
        "    user: active\n")
    assert bp._token() == "", (
        "a nested account's token is not this block's key — falling through to `gh auth "
        "token` (the ACTIVE account) is the only correct answer")

    # ⛔ AND THE REALISTIC MIXED SHAPE, which is what gh actually WRITES: a `users:` map whose
    # entries come first, PLUS a block-level `oauth_token`. gh moves the ACTIVE user's token up
    # to block level when it switches accounts, so the block-level key is the active account's
    # and the read must use it WITHOUT spawning `gh auth token` at all. Skipping the nested
    # `gho_OTHER_ACCOUNT` is the whole point; falling through here would be a wasted subprocess,
    # and reading the nested entry would be another account's token.
    hosts.write_text(
        "github.com:\n"
        "    users:\n"
        "        other:\n"
        "            oauth_token: gho_OTHER_ACCOUNT\n"
        "    user: active\n"
        "    oauth_token: gho_ACTIVE_BLOCK\n")
    calls = []
    monkeypatch.setattr(bp.subprocess, "run", lambda argv, **k: calls.append(argv) or _NoAuth())
    assert bp._token() == "gho_ACTIVE_BLOCK", (
        "the block-level token IS the active account's — a mixed config must not reach into "
        "the nested map, and must not need `gh auth token`")
    assert calls == [], "the block-level token needs no subprocess"
    monkeypatch.setattr(bp.subprocess, "run", lambda *a, **k: _NoAuth())

    monkeypatch.setenv("GH_TOKEN", "gho_from_env")      # the fleet's own env wins
    assert bp._token() == "gho_from_env"
    monkeypatch.delenv("GH_TOKEN")

    # Keyring-backed config: no oauth_token line at all -> ask gh, which is offline.
    hosts.write_text("github.com:\n    user: someone\n    git_protocol: https\n")

    class _Auth:
        returncode = 0
        stdout = "gho_from_keyring\n"
        stderr = ""

    asked = []

    def _auth(argv, **kw):
        asked.append(list(argv))
        return _Auth()

    monkeypatch.setattr(bp.subprocess, "run", _auth)
    assert bp._token() == "gho_from_keyring"
    # The COMMAND is the contract, not just its stdout: `gh auth token` is what the layer
    # classifies as an offline lookup, so it is the only subprocess this read may run.
    assert asked and asked[0][1:3] == ["auth", "token"], asked
    assert "--hostname" in asked[0] and "github.com" in asked[0], asked
    monkeypatch.setattr(bp.subprocess, "run", lambda *a, **k: _NoAuth())

    hosts.unlink()                        # no file, no env, no gh -> falsy, not None
    assert not bp._token()

    # ⛔ "NEVER LOGGED" MUST HOLD AT THE FINDER, NOT ONLY AT THE TRANSPORT. The assertion above
    # pins the value that reaches `compute()`; a `print()` inside `_token()` itself is upstream of
    # it and shipped GREEN under a check for one literal. Every credential literal this test
    # plants must therefore be absent from the whole captured stream.
    leaked = capsys.readouterr()
    stream = leaked.out + leaked.err
    for literal in ("gho_from_hosts_yml", "gho_relocated", "gho_right_host",
                    "gho_from_keyring", "gho_from_env", "GHES_MUST_NOT_BE_USED",
                    "gho_OTHER_ACCOUNT", "gho_ACTIVE_NESTED"):
        assert literal not in stream, (
            "_token() printed %r — the credential must never reach stdout/stderr, and "
            "pinning it only at the transport leaves the finder free to print it" % literal)

    # A full failing read must not print the token anywhere.
    monkeypatch.setenv("GH_TOKEN", "gho_secret_marker")
    monkeypatch.setattr(bp, "gh", lambda *a: None if a[:2] == ("pr", "list") else [])
    monkeypatch.setattr(bp, "_rest_get_json", lambda url, tok, timeout=None: None)
    assert bp.compute() is None
    assert bp.main() == 0
    captured = capsys.readouterr()
    assert "gho_secret_marker" not in (captured.out + captured.err)


# ── an unusable page is UNREADABLE, never an empty answer ───────────────────
def test_a_page_of_unusable_rows_refuses_instead_of_reporting_zero(monkeypatch):
    """`continue` on a malformed row consumed the window while `seen` advanced, so a page of
    rows that are not `/pulls` objects returned [] — and `compute()` accepts [] because
    `[] is not None`, printing a REAL line with `0 open PRs`. That is the false zero this
    file's header says was fixed on 2026-10-01. The honest answer is `None` (unavailable)."""
    monkeypatch.setattr(bp, "_token", lambda: "test-token")

    for page in (
        ["not a dict", 42, None],                            # wrong element type
        [{"title": "no number"}, {"title": "no number"}],    # drifted shape
        # ⛔ PRESENCE IS NOT ENOUGH — the TYPES that are hashed, dereferenced and compared must
        # be the documented ones, or the guard reports "not malformed" and something further in
        # raises instead. Measured before these cases: `number: {}`/`[]` raised TypeError out of
        # the repeat check's `in numbers` and printed NO line at all; `head: "x"` raised
        # AttributeError; a dict `merged_at` raised in `compute()`'s comparison.
        [{"number": {"x": 1}}],                            # unhashable number
        [{"number": [1]}],                                 # unhashable number
        [{"number": 7, "head": "not-a-dict"}],             # head dereferenced as a mapping
        [{"number": 7, "head": ["ref"]}],                  # head wrong type
        [{"number": 7, "merged_at": {"at": 1}}],          # merged_at compared to a str
        [{"number": True}],                                # bool is not a PR number
    ):
        monkeypatch.setattr(bp, "_rest_get_json",
                            lambda url, tok, timeout=None, _p=page: list(_p))
        assert bp._rest_prs("open", limit=500) is None, page

    # The other direction still holds: a genuinely EMPTY collection is an ANSWER (0), not a
    # failure — otherwise "no PRs" and "could not read" collapse into one signal.
    monkeypatch.setattr(bp, "_rest_get_json", lambda url, tok, timeout=None: [])
    assert bp._rest_prs("open", limit=500) == []


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


# ── the fallback is a FALLBACK: a healthy GraphQL read pays for no REST ─────
def test_both_graphql_reads_succeeding_never_pays_for_rest(monkeypatch, no_cache):
    """Measured mutant: making the fallback unconditional (`if True:`) left every test green.
    The cost is not cosmetic — a refresh would then spend 9 REST requests (~4 s) on the very
    bucket this change exists to keep free, on the happy path, ten times an hour per box."""
    rest_calls = []
    gql_open = [pr(1), pr(2), pr(3)]
    gql_merged = [pr(4, merged=MERGED_TODAY)]

    def fake_gh(*args):
        if args[:2] != ("pr", "list"):
            return []
        return gql_open if args[args.index("--state") + 1] == "open" else gql_merged

    monkeypatch.setattr(bp, "gh", fake_gh)
    monkeypatch.setattr(bp, "_rest_prs",
                        lambda *a, **k: rest_calls.append((a, k)) or [])

    out = bp.compute()
    assert out is not None
    assert rest_calls == [], "REST must not be read when both GraphQL reads answered"
    assert out["open_prs"] == 3
    assert out["merged_today"] == 1


# ── per_page never shrinks: GitHub's offset follows the request's per_page ──
def test_a_limit_that_is_not_a_multiple_of_100_keeps_the_page_offsets_sound(monkeypatch):
    """`min(100, limit - seen)` as `per_page` re-reads an earlier range on the last page,
    because GitHub computes the offset from THAT request's per_page: measured, limit=250
    returned rows 1-150 with 101-150 duplicated and 201-250 MISSING — a short window that
    the loop then reports as filled. The window is trimmed after the page arrives instead."""
    monkeypatch.setattr(bp, "_token", lambda: "test-token")
    seen_urls = []

    def fake_get(url, tok, timeout=None):
        seen_urls.append(url)
        per_page = int(url.split("per_page=")[1].split("&")[0])
        page = int(url.rsplit("page=", 1)[1])
        start = (page - 1) * per_page          # GitHub's own offset semantics
        return [rest_row(start + n + 1, merged_at=LONG_AGO) for n in range(per_page)]

    monkeypatch.setattr(bp, "_rest_get_json", fake_get)
    rows = bp._rest_prs("merged", limit=250)
    assert rows is not None
    numbers = [r["number"] for r in rows]
    assert numbers == list(range(1, 251)), "hole or duplicate: the window is not the window"
    assert [u.split("per_page=")[1].split("&")[0] for u in seen_urls] == ["100", "100", "100"]
    assert len(seen_urls) == 3
