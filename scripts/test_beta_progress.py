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
import json
import pathlib
import time

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

    def fake_rest(state, limit=100, deadline=None, repo=None):
        rest_calls.append((state, limit))
        deadlines.append(deadline)
        if state == "open":
            return [pr(1), pr(2)]
        return [pr(3, merged=MERGED_TODAY), pr(4, merged=LONG_AGO)]

    # These two tests pin the TRACKER's GraphQL-refusal/REST-fallback contract, and their `gh` stub
    # answers every `pr list` alike — so the cross-repo gap read is pinned to the tracker here,
    # and graded on its own by the FIX_REPOS tests at the end of this file.
    monkeypatch.setattr(bp, "gh", fake_gh)
    monkeypatch.setattr(bp, "_rest_prs", fake_rest)

    out = bp.compute()
    assert out is not None
    assert out["open_prs"] == 2
    assert out["merged_today"] == 1
    # BOTH lists were re-read over REST, at the windows the GraphQL calls ask for, and the whole
    # READ PHASE shares ONE deadline: a per-read budget multiplies the phase's worst case by the
    # number of reads inside a tick that is killed (the doc states the shared budget as a rule, so
    # the suite must hold it).
    assert ("open", 500) in rest_calls
    assert ("merged", 400) in rest_calls
    assert deadlines[0] is not None
    # ⛔ ALL of them, not just the tracker pair. Asserting only that `deadlines[0] == deadlines[1]`
    # left each fix-repo read free to take a FRESH budget (measured: passing `None` instead of
    # `rest_deadline` to `_repo_prs` kept 25/25 green) -- the per-read budget the rule bans.
    assert len(deadlines) == 4, "tracker pair + both fix-repo reads, not %d" % len(deadlines)
    assert len(set(deadlines)) == 1, "every REST read must share ONE clock: %r" % (deadlines,)

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
    down with it", and the `DELIV=$(...)` capture in `orchestrator-heartbeat.sh` sends stderr to
    /dev/null: an exception here prints NOTHING where the operator needs
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
        # ⛔ `bool` IS AN `int` (#2142 review). `isinstance(True, int)` is True, so a cache
        # carrying JSON `true` for a counter passed this validator and rendered
        # `1 open PRs, 1 merged today` as if it had been MEASURED — a fabricated number in the
        # beat, the false-reading class this file refuses to print. `_rest_prs` already rejects
        # bool for `number`; the two guards must agree on what a count is.
        {"ts": int(_time.time()), "p0": {"open": 0, "with_pr": 0, "without": 0},
         "p1": {"open": 0, "with_pr": 0, "without": 0},
         "open_prs": True, "merged_today": 1},                        # bool counter
        {"ts": int(_time.time()), "p0": {"open": True, "with_pr": 0, "without": 0},
         "p1": {"open": 0, "with_pr": 0, "without": 0},
         "open_prs": 1, "merged_today": 1},                           # bool tier counter
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
    # ⛔ THE NESTED SHAPES MATTER MOST, and a key-presence test does not catch them: a fresh cache
    # carrying all five top-level keys but a broken tier passed a shallow check, then failed
    # `p0["with_pr"]` in the RENDER — so the beat printed `unavailable` (nothing was read) for
    # the rest of the TTL, because the bad cache was never replaced. Measured: 3 consecutive
    # beats, `compute()` never called. Every case below must produce the FRESH line.
    fresh = {"ts": int(_time.time()), "open_prs": 2, "merged_today": 1,
             "p0": {"open": 1, "with_pr": 1, "without": 0},
             "p1": {"open": 0, "with_pr": 0, "without": 0}}
    unrenderable = [
        {"ts": int(_time.time()), "open_prs": 99, "merged_today": 99},          # top level short
        {"ts": int(_time.time()), "open_prs": 99, "merged_today": 99,
         "p0": {"open": 1}, "p1": {"open": 1}},                        # tier keys missing
        {"ts": int(_time.time()), "open_prs": 99, "merged_today": 99,
         "p0": 5, "p1": 7},                                             # tiers not dicts
        {"ts": int(_time.time()), "open_prs": "many", "merged_today": "many",
         "p0": {"open": 1, "with_pr": 0, "without": 1},
         "p1": {"open": 0, "with_pr": 0, "without": 0}},              # `%d` on a str
        # ⛔ A NUMBER IS NOT A TIMESTAMP. `1e30` passes `isinstance(ts, (int, float))` and makes
        # `time.localtime()` raise OverflowError, and a FUTURE ts makes the age render as
        # `-Nm ago`; both were accepted as FRESH, so the render guard printed `unavailable` and
        # the file was never replaced (measured: 3 beats, `compute()` never called). The render
        # guard keeps a line here, but the RIGHT outcome is a refresh.
        {"ts": 1e30, "open_prs": 99, "merged_today": 99,
         "p0": {"open": 1, "with_pr": 0, "without": 1},
         "p1": {"open": 0, "with_pr": 0, "without": 0}},              # unrenderable ts
        {"ts": int(_time.time()) + 86400, "open_prs": 99, "merged_today": 99,
         "p0": {"open": 1, "with_pr": 0, "without": 1},
         "p1": {"open": 0, "with_pr": 0, "without": 0}},              # ts from the future
    ]
    for cached in unrenderable:
        no_cache.write_text(_json.dumps(cached))
        monkeypatch.setattr(bp, "compute", lambda: dict(fresh))
        assert bp.main() == 0, cached
        out = capsys.readouterr().out
        assert "unavailable" not in out, (cached, out)
        assert "2 open PRs, 1 merged today" in out, (cached, out)
        assert _json.loads(no_cache.read_text())["open_prs"] == 2, (
            "the bad cache must be REPLACED by the fresh read, or it poisons the next beat")


# ── the RENDER guard itself: a cache that PASSES the validator but cannot be formatted ──
# ⛔ THE CACHE TEST ABOVE CANNOT PIN THIS. Every case in its first loop produces `unavailable`
# from the COMPUTE guard (it stubs `compute()` to `None`), and every case in its second loop is
# rejected by the validator before the render -- so DELETING the render guard leaves all 14 tests
# green (measured, at two spellings of the removal). The gap is not academic: an accepted cache
# with an unrenderable `ts` raised `OverflowError` out of `sys.exit(main())` and printed NO line,
# which is the failure the guard exists to prevent. This test feeds the render a shape the
# validator never sees (`compute()`'s return, not the file) so the guard is the only thing
# between it and a traceback.
def test_the_render_guard_holds_when_compute_returns_an_unformattable_shape(
        monkeypatch, no_cache, capsys):
    """`compute()` is a pile of dereferences over API data; the render is the last place an
    unexpected shape can reach the operator as a traceback instead of the honest line. The
    heartbeat pipes stderr away (`orchestrator-heartbeat.sh`), so a raise here is silence."""
    for unformattable in ({"ts": int(bp.time.time())},                       # no p0/p1
                          {"ts": int(bp.time.time()), "p0": {"open": 1},  # half a tier
                           "p1": {"open": 0, "with_pr": 0, "without": 0},
                           "open_prs": 1, "merged_today": 1},
                          {"ts": int(bp.time.time()), "p0": "not a dict"}):
        monkeypatch.setattr(bp, "compute", lambda u=unformattable: dict(u))
        assert bp.main() == 0, unformattable
        assert "DELIVERY: unavailable (metrics read failed)" in capsys.readouterr().out, (
            "an unformattable shape must still produce a line — exit 0 with silence is the "
            "failure this guard exists for", unformattable)


# ── a FUTURE cache stamp never renders a NEGATIVE age ──────────────
# ⛔ CLAMPED, NOT REFUSED. `CACHE_TS_SKEW_S` admits a few seconds of future `ts` on purpose
# (writer/reader clock skew is real), but the age is computed as `int((now - ts) / 60)`, so an
# accepted future stamp rendered `-1m ago` (`ts = now+120`) or `-4m ago` (`now+299`) on the
# owner's line -- the symptom the bound's own comment cites as its reason, surviving INSIDE the
# band the bound allows. Unpinned before this: nothing drove a future-but-accepted stamp.
def test_a_slightly_future_cache_stamp_never_prints_a_negative_age(monkeypatch, no_cache, capsys):
    import json as _json
    import time as _time

    for ahead_s in (1, 120, 299):
        no_cache.write_text(_json.dumps(
            {"ts": int(_time.time()) + ahead_s, "open_prs": 2, "merged_today": 1,
             "p0": {"open": 1, "with_pr": 1, "without": 0},
             "p1": {"open": 0, "with_pr": 0, "without": 0}}))
        # If the stamp were refused as stale this would be a refresh; either way the line is
        # real. What must NEVER appear is a negative age.
        monkeypatch.setattr(bp, "compute", lambda: None)
        assert bp.main() == 0
        out = capsys.readouterr().out
        assert "-" not in out.split("ago]")[0].split(", ")[-1], (
            "a future-but-accepted cache stamp rendered a NEGATIVE age: %r" % (out,))


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

    def fake_rest(state, limit=100, deadline=None, repo=None):
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

    def fake_rest_mirror(state, limit=100, deadline=None, repo=None):
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

    # ⛔ THE ASYMMETRIC ARM — the only direction where the rule can actually break, and the
    # one both arms above miss (each drives REST to succeed on BOTH lists, so `ro` and `rm`
    # fail or succeed TOGETHER and the pair guard is never exercised alone). Here GraphQL
    # OPEN is refused while GraphQL merged is ALIVE, and REST answers the open list but
    # REFUSES the merged one. Without this arm a mutant that assigns the two lists
    # independently (`if ro is not None: openpr = ro` / `if rm is not None: merged = rm`)
    # passes all 14 tests and emits a REST open-count beside a GraphQL merged-count — the
    # exact defect rule (d) forbids (measured: open_prs=2 / merged_today=1).
    def fake_gh_asymmetric(*args):
        if args[:2] != ("pr", "list"):
            return []
        if "--state" in args and args[args.index("--state") + 1] == "open":
            return None                                  # GraphQL open REFUSED
        return [pr(300, merged=MERGED_TODAY)]            # GraphQL merged ALIVE

    def fake_rest_asymmetric(state, limit=100, deadline=None):
        if state == "open":
            return [pr(100), pr(101)]                    # REST open answers
        return None                                      # REST merged REFUSES

    monkeypatch.setattr(bp, "gh", fake_gh_asymmetric)
    monkeypatch.setattr(bp, "_rest_prs", fake_rest_asymmetric)

    assert bp.compute() is None, (
        "a REST open window beside a surviving GraphQL merged window is a MIXED read: with "
        "no merged window on the same source the metric must be refused entirely, not "
        "rendered from two differently-wrong reads")


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


# ── the PER-REQUEST timeout is clamped by the SHARED budget ──────────────────
# ⛔ THIS GUARD WAS UNPINNED. `min(REST_TIMEOUT_S, remaining)` is the only thing that makes
# `REST_BUDGET_S` a bound on a HANGING page: mutate it to a bare `REST_TIMEOUT_S` (valid,
# compiles, reads plausibly) and the suite stayed at 15 passed, while a request landing near the
# deadline was allowed a full 15 s PAST it -- 30 + 15 = 45 s against the `run_bounded 390 s` tick
# the module comment says this read must fit inside. The budget test above cannot catch it: it
# sets `REST_BUDGET_S = 0`, so the refusal happens BEFORE any request and the clamp is never
# exercised. This one spends the budget ACROSS a page boundary, so a request is always issued
# with less than a full timeout left.
def test_a_request_near_the_deadline_gets_only_the_time_left(monkeypatch):
    """The budget is shared by the open/merged PAIR, so a page that hangs must not eat the
    remainder in a single 15 s request -- the timeout handed to the transport is the remaining
    budget, whichever is smaller."""
    budget = 0.5
    monkeypatch.setattr(bp, "REST_BUDGET_S", budget)
    monkeypatch.setattr(bp, "_token", lambda: "test-token")
    timeouts = []

    def slow_get(url, tok, timeout=None):
        timeouts.append(timeout)
        import time as _t
        _t.sleep(min(timeout or 0, 0.05))          # a page that never answers promptly
        return [rest_row(n, merged_at=LONG_AGO) for n in range(100)]   # a FULL page: keep paging

    monkeypatch.setattr(bp, "_rest_get_json", slow_get)
    assert bp._rest_prs("merged", limit=400) is None, "a spent budget must refuse the window"
    assert timeouts, "a request must have been issued with budget left"
    assert max(timeouts) <= budget, (
        "the per-request timeout must be CLAMPED by the remaining budget, not handed a full "
        "REST_TIMEOUT_S (%r); measured timeouts=%r against a %r s budget"
        % (bp.REST_TIMEOUT_S, timeouts, budget))


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
        # Served AFTER #150 bumped to the head, i.e. the order a REAL API would return:
        # `150, 1..149, 151, 152, ...`. Offset 100 therefore lands on 100 — the last row page 1
        # already returned — and #150 itself sits at offset 0, behind the cursor, so it is
        # served by NO page. (The earlier fixture kept #150 at its old index as well, a page
        # sequence no offset paging can produce.)
        return [rest_row(n) for n in list(range(100, 150)) + list(range(151, 201))]

    monkeypatch.setattr(bp, "_rest_get_json", shifted)
    assert bp._rest_prs("open", limit=200) is None, (
        "a repeat proves the list moved mid-read, and a moved list is also a SHORT one — the "
        "window cannot be certified, so it must not be returned (keeping the window would "
        "hide the missing row)")

    # The other direction: a read that does not move at all is an ANSWER. The refusal is not a
    # blanket one — every happy-path test in this file depends on that.
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
    # ⛔ THE RETRY IS PINNED HERE (#2142 review): a repeat abandons that ATTEMPT and the read is
    # retried ONCE, so a persistently-shifting window costs exactly two page-sets and still
    # REFUSES. The pages are the same both times because the stub's list keeps moving — which is
    # the point: a retry must never turn two different windows into a number.
    assert calls == [1, 2, 1, 2], calls


def test_a_repeat_on_the_first_attempt_is_retried_once_and_can_succeed(monkeypatch):
    """The complement of the refusal above: a repeat is CHURN evidence, not proof the read can
    never be trusted. On a box running ~17 concurrent gh clients the mover is usually an update
    that has settled by the time the page-set is re-read, so attempt 1 refuses and attempt 2
    returns the REAL window (#2142 review). Without this the fallback would print `unavailable`
    for most of its attempts and the DELIVERY line would be lost to churn rather than to a
    rate limit — the exact regression this PR exists to prevent."""
    monkeypatch.setattr(bp, "_token", lambda: "test-token")
    rounds = []

    def pages(url, tok, timeout=None):
        page = int(url.rsplit("page=", 1)[1])
        rounds.append(page)
        attempt = rounds.count(1)          # 1 while reading the FIRST attempt's page 1
        if attempt == 1 and page == 2:
            return [rest_row(100)] + [rest_row(n) for n in range(101, 200)]   # churned window
        if page == 1:
            return [rest_row(n) for n in range(1, 101)]
        return [rest_row(n) for n in range(101, 201)]                      # settled on retry

    monkeypatch.setattr(bp, "_rest_get_json", pages)
    rows = bp._rest_prs("open", limit=200)
    assert rows is not None, "the retry must be able to turn churn into a real window"
    assert [r["number"] for r in rows] == list(range(1, 201)), "the retry returned a short window"
    assert rounds.count(1) == 2, rounds      # exactly ONE retry, never a loop


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
        # ⛔ AND THE TWO FIELDS THAT REACH A REGEX (#2142 review). The heading above says the
        # guard covers the types, but `title` and `head.ref` were never checked, so a dict title
        # passed the guard, reached `pat.search()` in `covered()` and raised TypeError — which
        # the catch-all turned into the WHOLE metric reading `unavailable` instead of this page
        # being refused. Every field the read later HASHES, DEREFERENCES, COMPARES or SEARCHES
        # must be checked here, or the guard's claim is false.
        [{"number": 7, "title": {"a": 1}, "head": {"ref": "fix/7-x"}}],
        [{"number": 7, "title": ["t"], "head": {"ref": "fix/7-x"}}],
        [{"number": 7, "title": "t", "head": {"ref": {"x": 1}}}],
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

    monkeypatch.setattr(bp, "_rest_open", fake_urlopen)
    out = bp._rest_get_json("https://api.github.com/repos/o/r/pulls?state=open",
                            "gho_real_path_token")
    assert out == [{"number": 1, "head": {"ref": "x"}, "merged_at": None}]
    assert seen["auth"] == "bearer gho_real_path_token", (
        "the credential must be a HEADER — never part of the URL, which is logged everywhere")
    assert "gho_real_path_token" not in seen["url"]
    assert seen["timeout"] == bp.REST_TIMEOUT_S

    def boom(req, timeout=None):
        raise OSError("connection refused")

    monkeypatch.setattr(bp, "_rest_open", boom)
    assert bp._rest_get_json("https://api.github.com/x", "gho_real_path_token") is None

    captured = capsys.readouterr()
    assert "gho_real_path_token" not in (captured.out + captured.err), (
        "the transport must not print the credential on either path")


# ── the PAT never leaves the origin it was sent to ──────────────────────
def test_a_cross_origin_redirect_never_carries_the_token_to_the_new_host():
    """`_rest_get_json` is the ONE function holding the credential, and urllib's default
    redirect handler re-sends every header except content-length/content-type. Without the
    same-origin rule a 30x naming another host would hand `Authorization: bearer <tok>` to
    that host. Two loopback ports are two origins, so this needs no network. The positive
    control pins the other half -- a redirect that stays put is still followed, so the rule
    did not silence legitimate redirects."""
    import http.server
    import threading

    received = []

    class _Sink(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            received.append((self.path, self.headers.get("Authorization")))
            body = b'{"ok": true}'
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *a):
            pass

    class _Redirector(http.server.BaseHTTPRequestHandler):
        away = ""

        def do_GET(self):
            if self.path in ("/away", "/stay"):
                self.send_response(302)
                self.send_header("Location", self.away if self.path == "/away" else "/ok")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            body = b'{"same": "origin"}'
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *a):
            pass

    sink = http.server.HTTPServer(("127.0.0.1", 0), _Sink)
    redir = http.server.HTTPServer(("127.0.0.1", 0), _Redirector)
    _Redirector.away = "http://127.0.0.1:%d/x" % sink.server_address[1]
    redir_url = "http://127.0.0.1:%d" % redir.server_address[1]
    threads = [threading.Thread(target=s.serve_forever, daemon=True) for s in (sink, redir)]
    for t in threads:
        t.start()
    try:
        assert bp._rest_get_json(redir_url + "/away", "gho_redirect_token") is None, (
            "a cross-origin redirect must be refused, not followed")
        assert received == [], (
            "nothing may reach the other origin -- the header carrying the PAT was re-sent "
            "by urllib's default redirect handler (got %r)" % (received,))
        assert bp._rest_get_json(redir_url + "/stay", "gho_redirect_token") == {
            "same": "origin"}, "a same-origin redirect must still be followed"
    finally:
        for s in (sink, redir):
            s.shutdown()
            s.server_close()


def test_a_same_host_scheme_downgrade_is_refused_too():
    """An ORIGIN is (scheme, host, port), so `https:` -> `http:` ON THE SAME HOST is still a
    different origin -- and following it would re-send the PAT in CLEARTEXT. The stdlib check
    in `http_error_302` only asserts the scheme is one it knows, never that it did not change,
    so `netloc` alone passes this. Two loopback servers cannot express a scheme change, hence
    this drives the handler directly."""
    import urllib.request

    req = urllib.request.Request("https://api.github.com/repos/o/r/pulls?state=open",
                                 headers={"Authorization": "bearer gho_downgrade"})
    assert bp._SameOriginOnly().redirect_request(
        req, None, 302, "Found", {}, "http://api.github.com/repos/o/r/pulls2") is None, (
        "a same-host scheme downgrade must be refused, not followed with the credential")
    assert bp._SameOriginOnly().redirect_request(
        req, None, 302, "Found", {}, "https://api.github.com/repos/o/r/pulls2") is not None, (
        "a same-origin redirect must still be followed")


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


# ══ THE GAP COUNT MUST SEE THE REPO THE FIX LANDS IN (tortoise#10951) ═══════════════
# `REPO` is the TRACKER. It is not the repo every fix lands in: tortoise's P0/P1 backlog is
# worked by the harness (agent-infra), whose PRs live under a different repo. A metric that reads a
# single repo's PR list turns "landed elsewhere" into "nobody is on it", and this is the number the
# owner reads to decide whether beta ships.
# ⛔ NOT A NOISE THE PRE-FIX COUNT IS MAKING TODAY. On 2026-11-05 #10114 reads `with_pr` anyway --
# a MERGED tracker PR (#10250) carries its number -- so `main` prints the same gap set with and
# without this change. These tests are COUNTERFACTUAL regression guards: they pin the rule that a
# fix-repo PR is a landing path, which becomes load-bearing the moment #10250 scrolls out of the
# newest-400 merged window, and they are red on `main` because the MECHANISM is absent, not because
# a number moved. (The first draft of this header claimed #10114 was reported `without_pr`, which
# tortoise#11020's own correction comment retracts; restated as measured rather than deleted.)
def _issue_rows(*numbers):
    return [{"number": n} for n in numbers]


def _gh_by_repo(monkeypatch, tracker_open, tracker_merged, other_open, other_merged=None):
    """A `gh` whose answer depends on `--repo` AND on `--state`, which is what the defect is about.

    ⛔ THE FIX REPO'S TWO WINDOWS ARE SEPARATE ARGUMENTS ON PURPOSE. When one list answers both
    states, an assertion that `without == 0` cannot say WHICH window produced the cover -- and the
    mutant `for _state, _l in (...): rows = _repo_prs(...); if _state == "open": fix_prs.extend(rows)`
    keeps the whole suite green (measured on the first draft). `other_merged` therefore defaults to
    an EMPTY window: a test that means "the OPEN window covers this" cannot be satisfied by the
    merged one, and the merged window has its own test below.
    """
    calls = []

    def fake_gh(*args):
        calls.append(args)
        repo = args[args.index("--repo") + 1] if "--repo" in args else bp.REPO
        if args[:2] == ("pr", "list"):
            state = args[args.index("--state") + 1]
            if repo == bp.REPO:
                return tracker_open if state == "open" else tracker_merged
            return other_open if state == "open" else ([] if other_merged is None else other_merged)
        label = args[args.index("--label") + 1]
        return _issue_rows(*{"P0-blocker": (10114,), "P1-severe": (10951,)}[label])
    monkeypatch.setattr(bp, "gh", fake_gh)
    return calls


def test_a_fix_in_another_repo_is_a_landing_path_not_a_gap(monkeypatch, no_cache):
    """#10114: no tortoise PR, an OPEN agent-infra PR whose TITLE carries `(#10114)`.

    ⛔ A COUNTERFACTUAL GUARD, not a reproduced flip: `main` prints the SAME gap set today (see
    the section header). The assertion is not "the number changed" — it is that an OPEN PR
    referencing the issue, in the repo the fix is actually written in, makes `without` ZERO,
    because that is the fact a lane charter reads. What is red on `main` is the MECHANISM; what
    becomes red later is the number, the moment the merged tracker PR that covers #10114 by
    accident leaves the 400-row window.

    The fix repo's merged window is EMPTY here on purpose: this test grades the OPEN half only, so
    a read that asked for `--state open` and nothing else would still pass it.

    ⛔ NO `FIX_REPOS` PIN HERE, ON PURPOSE. The shipped default already names agent-infra, and
    pinning it made the red-first run die on `AttributeError: no attribute 'FIX_REPOS'` against
    the pre-change module — an error that PROVES A NEW CONSTANT EXISTS, not that the defect does.
    Unpinned, the same tests are red on the old code with the real defect in the assertion
    (`p0 == {'open': 1, 'with_pr': 0, 'without': 1}`).
    """
    other = "daniel-ospina/agent-infra"
    calls = _gh_by_repo(
        monkeypatch,
        tracker_open=[pr(900)],
        tracker_merged=[],
        other_open=[pr(3368, ref="fix/10114-pin-tree-is-a-holder",
                        title="fix(reaper): the harness PIN TREE is a holder, not residue (#10114)"),
                    pr(3333, title="batch(#3309 #10114 #3243): one integration branch")])

    out = bp.compute()
    assert out is not None
    assert out["p0"] == {"open": 1, "with_pr": 1, "without": 0}, (
        "an OPEN PR in the fix repo IS a landing path; counting it as a gap is what chartered "
        "a lane to rebuild landed-elsewhere work")
    # #10951 has NO PR in EITHER repo — the metric must not become optimistic either.
    assert out["p1"] == {"open": 1, "with_pr": 0, "without": 1}
    # The headline count keeps its meaning: the TRACKER's open PRs, not the fleet's.
    assert out["open_prs"] == 1
    # ⛔ THE WINDOW IS PART OF THE CONTRACT, so it is asserted and not just commented: a fix-repo
    # read that asked only for `--state open` would drop #10114 the moment #3368 merged — "no PR,
    # you are the path" about work that had LANDED, which is worse than the open case this fixes.
    for want in ("open", "merged"):
        assert any(a[:2] == ("pr", "list")
                   and a[a.index("--repo") + 1] == other
                   and a[a.index("--state") + 1] == want for a in calls), \
            "the fix repo was never read as an %r window — a merged fix would read as a gap" % want


def test_a_refused_fix_repo_read_falls_back_to_rest_not_to_unavailable(monkeypatch, no_cache):
    """⛔ THE #2139 REFUSAL IS A SECONDARY-LIMIT ONE, SO IT HITS EVERY `gh pr list` AT ONCE.

    `compute()`'s REST fallback covered only the tracker pair; a fix repo read through the same
    GraphQL call would return None on those boxes and take the whole DELIVERY line down — while
    the tracker's own successful read had already been paid for. The fix repo gets the same
    second source, and the REST URL is built from the repo it was asked for (it used to hardcode
    the TRACKER, which would hand back the tracker's `/pulls` under the fix repo's name).
    """
    other = "daniel-ospina/agent-infra"
    rest_calls = []

    def fake_gh(*args):
        if args[:2] == ("pr", "list"):
            return None                      # refused for EVERY repo, as it is on a cell
        label = args[args.index("--label") + 1]
        return _issue_rows(*{"P0-blocker": (10114,), "P1-severe": ()}[label])

    def fake_rest(state, limit=100, deadline=None, repo=None):
        rest_calls.append(repo)
        if repo == other:
            return [pr(3368, title="fix(reaper): the harness PIN TREE is a holder (#10114)")]
        return [pr(900)] if state == "open" else []

    monkeypatch.setattr(bp, "gh", fake_gh)
    monkeypatch.setattr(bp, "_rest_prs", fake_rest)

    out = bp.compute()
    assert out is not None, "a refused GraphQL read must not cost the line its REST fallback"
    assert out["p0"] == {"open": 1, "with_pr": 1, "without": 0}
    assert other in rest_calls, "the fix repo was never read over REST — it has no second source"


def test_an_unreadable_fix_repo_is_not_a_gap(monkeypatch, no_cache):
    """⛔ COULD NOT READ IS NOT 'NO PR'. A refused read of the fix repo must make the metric
    UNAVAILABLE, never inflate `without` — that is the fail-open direction, and it is the one
    that sends a lane to rebuild work somebody else already has open.

    ⛔ BOTH SOURCES MUST BE REFUSED, NOT JUST GRAPHQL. The first draft stubbed only `gh`, so the
    fix-repo REST fallback went to the REAL api.github.com; on a box with a token it answered 38
    real rows and the metric came back non-None — the test passed only where the network was
    absent (caught by the [VGATE] verifier, which reproduced it live). A test about "unreadable"
    has to make both sources unreadable.
    """
    _gh_by_repo(monkeypatch, tracker_open=[pr(900)], tracker_merged=[], other_open=None)
    monkeypatch.setattr(bp, "_rest_prs", lambda *a, **k: None)   # no second source either

    assert bp.compute() is None, (
        "a refused read of a fix repo must not be reported as a real gap — it must not be "
        "reported at all")


def test_the_rest_fallback_asks_the_repo_it_was_given(monkeypatch):
    """⛔ THE URL IS PART OF THE FIX, AND THIS IS THE ONLY TEST THAT CAN SEE IT.

    `_rest_prs` built its URL from the module constant `REPO`, so a fix-repo call would have been
    answered with the TRACKER's `/pulls` and the fix repo's name attached to it — a wrong list that
    still looks complete. Every other test stubs `_rest_prs` wholesale and can only observe the
    `repo` ARGUMENT, so reverting the URL to `% (REPO, ...)` used to leave the whole suite green
    (measured: 23 passed). This pins the bytes actually requested.
    """
    other = "daniel-ospina/agent-infra"
    seen = []

    def fake_get(url, tok, timeout=None):
        seen.append(url)
        return []

    monkeypatch.setattr(bp, "_token", lambda: "test-token")
    monkeypatch.setattr(bp, "_rest_get_json", fake_get)

    assert bp._rest_prs("open", limit=100, deadline=bp.time.time() + 30, repo=other) == []
    assert seen, "_rest_prs made no request at all"
    assert "/repos/%s/pulls" % other in seen[0], (
        "the REST read asked for %r, not the repo it was given" % seen[0])


def test_a_malformed_fix_repo_payload_is_unavailable_not_a_traceback(monkeypatch, no_cache):
    """⛔ `gh` CAN EXIT 0 WITH A JSON OBJECT (`{"message": "Not Found"}`) OR A LIST OF NON-DICTS.

    `covered()` calls `.get()` on every row, so a str row RAISES; `main()` catches it and the box
    then prints a traceback and `unavailable` on EVERY refresh for as long as that payload persists
    — a whole metric lost to one repo's odd answer, and nothing cached to self-heal. The shape gate
    in `_repo_prs` turns that into the honest `unavailable`-by-return-None path instead.
    """
    def fake_gh(*args):
        if args[:2] == ("pr", "list"):
            repo = args[args.index("--repo") + 1]
            if repo == bp.REPO:
                return [pr(900)] if args[args.index("--state") + 1] == "open" else []
            return {"message": "Not Found"}          # rc 0, wrong shape
        label = args[args.index("--label") + 1]
        return _issue_rows(*{"P0-blocker": (10114,), "P1-severe": ()}[label])

    monkeypatch.setattr(bp, "gh", fake_gh)
    monkeypatch.setattr(bp, "_rest_prs", lambda *a, **k: None)

    assert bp.compute() is None, (
        "a malformed fix-repo payload must not raise out of compute(), and must not be read as "
        "a complete list")


def test_the_merged_fix_repo_window_alone_covers_a_landed_fix(monkeypatch, no_cache):
    """⛔ THE MERGED HALF IS THE WHOLE POINT, AND IT WAS UNTESTED.

    A PR in a fix repo does NOT close a TRACKER issue, so the issue stays open AFTER the fix
    merges. Read only OPEN rows and #10114 becomes `without_pr` the moment agent-infra#3368 merges
    — "no PR, you are the path" about work that had LANDED, which is strictly worse than the open
    case this change exists to fix.

    ⛔ THIS TEST IS THE ONE THAT KILLS THE FETCH-AND-DISCARD MUTANT. The first draft asserted only
    that a `--state merged` call was MADE, so

        for _state, _l in (("open", 500), ("merged", 400)):
            rows = _repo_prs(...)
            if _state == "open": fix_prs.extend(rows)      # merged rows fetched, then dropped

    kept 25/25 green. Here the OPEN window is EMPTY and the fix PR exists ONLY in the merged one,
    so `without == 0` can only come from the merged rows actually being USED.
    """
    other = "daniel-ospina/agent-infra"
    _gh_by_repo(
        monkeypatch,
        tracker_open=[pr(900)],
        tracker_merged=[],
        other_open=[],
        other_merged=[pr(3368, merged=MERGED_TODAY, ref="fix/10114-pin-tree-is-a-holder",
                          title="fix(reaper): the harness PIN TREE is a holder (#10114)")])

    out = bp.compute()
    assert out is not None
    assert out["p0"] == {"open": 1, "with_pr": 1, "without": 0}, (
        "a MERGED fix-repo PR is a landing path — reading only the OPEN window would report a "
        "landed fix as a gap and charter a lane to rebuild it")
    # And the fix must not become optimistic in the other direction: #10951 has no PR in any window.
    assert out["p1"] == {"open": 1, "with_pr": 0, "without": 1}


def test_a_fix_repo_row_citing_its_own_number_still_covers_it_pins_the_disclosed_residual(monkeypatch, no_cache):
    """⛔ THE KNOWN FALSE-COVER RESIDUAL, PINNED AS THE SHIPPED BEHAVIOUR — NOT AS CORRECT.

    agent-infra numbers its own issues and PRs in the SAME sequence as the tracker, so its branch
    `fix/2513-pool-filter` cites agent-infra#2513 while tortoise#2513 is a different issue with the
    same number. `covered()` cannot tell which repo a row came from, so that row marks tortoise#2513
    covered and nobody builds it.

    ⛔ A "SELF-REFERENCE" FILTER WAS SHIPPED FOR THIS AND THEN REMOVED, because the measurement did
    not support it: of 447 agent-infra rows only 2 carry their own number at all, and 0 of the 7
    rows that actually collide with an open tracker unit are self-references — they all cite the
    tracker BARE (`fix/10114-pin-tree-is-a-holder`, `p0-10114`, `batch(#3309 #10114 …)`), which is
    the same fact that rules out a qualified match. So the filter closed nothing measurable while
    suppressing genuine covers (a fix-repo PR numbered N that really does fix tortoise#N).

    This test therefore asserts the RESIDUAL IS OPEN. If it ever goes red because someone narrowed
    `covered()`, that is a behaviour change to be justified against the comment in
    `scripts/beta-progress.py` — not a test to "fix" by relaxing it.
    """
    other = "daniel-ospina/agent-infra"

    def fake_gh(*args):
        if args[:2] == ("pr", "list"):
            repo = args[args.index("--repo") + 1]
            state = args[args.index("--state") + 1]
            if repo == bp.REPO:
                return [pr(900)] if state == "open" else []
            if state != "open":
                return []
            return [
                # agent-infra's OWN issue 2513 — a DIFFERENT issue from tortoise#2513.
                pr(2513, ref="fix/2513-pool-filter", title="fix(2513): the pool filter, one def"),
                # a cross-reference to a different number covers, as it must (#10114).
                pr(4000, ref="fix/pin-tree", title="fix(reaper): the PIN TREE (#10114)"),
            ]
        label = args[args.index("--label") + 1]
        return _issue_rows(*{"P0-blocker": (10114,), "P1-severe": (2513,)}[label])

    monkeypatch.setattr(bp, "gh", fake_gh)
    out = bp.compute()
    assert out is not None
    assert out["p1"] == {"open": 1, "with_pr": 1, "without": 0}, (
        "the disclosed residual: a fix-repo row citing an in-range number IS read as a cover. If "
        "this changed, the change needs its own justification against the measured collision data")
    assert out["p0"] == {"open": 1, "with_pr": 1, "without": 0}


def test_a_malformed_fix_repo_entry_is_unavailable_not_a_typeerror(monkeypatch, no_cache):
    """⛔ `dict.fromkeys(FIX_REPOS)` RAN BEFORE THE `owner/name` VALIDATION.

    An UNHASHABLE entry (a list, a dict) therefore raised `TypeError` out of `compute()` — the
    traceback-and-no-line path the shape gate exists to prevent — instead of the documented
    `return None`. The dedupe now runs AFTER validation, so every malformed entry takes the honest
    `unavailable` path.
    """
    monkeypatch.setattr(bp, "gh",
                        lambda *a: [pr(900)] if a[:2] == ("pr", "list") else [])
    for bad in (None, "", "agent-infra", "daniel-ospina/agent-infra/extra", "daniel-ospina/",
                ["daniel-ospina/agent-infra"], {"repo": "daniel-ospina/agent-infra"}):
        monkeypatch.setattr(bp, "FIX_REPOS", (bp.REPO, bad))
        assert bp.compute() is None, (
            "%r must be UNREADABLE (return None), never a TypeError and never a silent "
            "substitution of the tracker" % (bad,))


def test_a_fix_repo_listed_twice_is_read_once(monkeypatch, no_cache):
    """The dedupe is load-bearing on the BUDGET, not only on tidiness: a repo listed twice used to
    be one read via `dict.fromkeys`, and moving validation ahead of it must not lose that."""
    other = "daniel-ospina/agent-infra"
    calls = []

    def fake_gh(*args):
        calls.append(args)
        if args[:2] == ("pr", "list"):
            return [pr(900)] if args[args.index("--repo") + 1] == bp.REPO else []
        return []

    monkeypatch.setattr(bp, "gh", fake_gh)
    monkeypatch.setattr(bp, "FIX_REPOS", (bp.REPO, other, other))

    assert bp.compute() is not None
    reads = [a for a in calls
             if a[:2] == ("pr", "list") and a[a.index("--repo") + 1] == other]
    assert len(reads) == 2, "one repo, two windows — got %d reads: %r" % (len(reads), reads)


def test_a_non_dict_fix_repo_row_is_unavailable_not_a_traceback(monkeypatch, no_cache):
    """⛔ `isinstance(r, dict)` ALONE IS NOT THE SHAPE GATE ITS DOCSTRING CLAIMS.

    `covered()` runs `pat.search()` over `title` and `headRefName`, so a row that IS a dict but
    carries a non-str in either field raised `TypeError: expected string or bytes-like object` out
    of `compute()` — the traceback this gate says it prevents. `_rest_prs` already refuses such a
    row per page; `_repo_prs` now applies the same rule, TYPES INCLUDED.
    """
    other = "daniel-ospina/agent-infra"

    def payload(bad_row):
        def fake_gh(*args):
            if args[:2] == ("pr", "list"):
                repo = args[args.index("--repo") + 1]
                state = args[args.index("--state") + 1]
                if repo == bp.REPO:
                    return [pr(900)] if state == "open" else []
                # ⛔ BOTH WINDOWS: `mergedAt` is only requested/checked for a NON-open window, so a
                # bad row offered only as `open` never reaches that branch of the gate.
                return [bad_row]
            return _issue_rows(*{"P0-blocker": (10114,), "P1-severe": ()}[
                args[args.index("--label") + 1]])
        return fake_gh

    for bad_row in (
            "fix/10114",                                                  # a str, not a row
            {"number": 3368, "title": {"a": 1}, "headRefName": "fix/x"},   # dict title
            {"number": 3368, "title": "t", "headRefName": ["fix/x"]},      # list ref
            {"number": {"n": 1}, "title": "t", "headRefName": "fix/x"},    # non-int number
            {"number": True, "title": "t", "headRefName": "fix/x"},        # bool is not a number
            # ⛔ THE `mergedAt` GATE TOO. `_repo_prs` requests `mergedAt` for a non-open window, so a
            # non-str there is the documented shape violation -- and it was the one branch of that
            # gate with no test, so deleting it left the suite green.
            {"number": 3368, "title": "t", "headRefName": "fix/x", "mergedAt": {"m": 1}},
    ):
        monkeypatch.setattr(bp, "gh", payload(bad_row))
        monkeypatch.setattr(bp, "_rest_prs", lambda *a, **k: None)
        assert bp.compute() is None, (
            "a row of the wrong shape must REFUSE the read, not raise out of compute(): %r"
            % (bad_row,))


def test_a_spent_phase_clock_refuses_the_read_instead_of_spawning(monkeypatch):
    """⛔ THE PHASE CLOCK IS WHAT KEEPS THE WORST CASE CONSTANT AS REPOS ARE ADDED.

    Every `gh()` read used to get a flat 120 s, so the phase's worst case grew with the NUMBER of
    reads: 4 reads (2 PR lists + 2 issue lists) was already 480 s against a 390 s `run_bounded`
    kill, and the two fix-repo PR lists added here take it to 720 s — the tick is killed and the
    box prints NOTHING. With one clock, a spent budget REFUSES (None → the honest `unavailable`
    line) instead of spawning a read it cannot bound.
    """
    spawned = []
    monkeypatch.setattr(bp.subprocess, "run", lambda *a, **k: spawned.append(a))
    monkeypatch.setattr(bp, "_PHASE_DEADLINE", bp.time.time() - 1)

    assert bp.gh("pr", "list", "--repo", bp.REPO) is None
    assert spawned == [], "a spent clock must refuse, not spawn a read it cannot bound"


def test_the_phase_clock_bounds_the_rest_deadline_and_is_then_restored(monkeypatch, no_cache):
    """⛔ REST IS A CHILD OF THE PHASE CLOCK, NOT A PEER OF IT.

    A slow `gh` read has already spent part of the phase; REST may not spend that part a second
    time, or the two budgets are additive and the tick dies anyway. And the clock must be
    RESTORED — a deadline left behind would silently bound every later `gh()` call to nothing.
    """
    monkeypatch.setattr(bp, "gh", lambda *a: None if a[:2] == ("pr", "list") else [])
    deadlines = []

    def fake_rest(state, limit=100, deadline=None, repo=None):
        deadlines.append(deadline)
        return []

    monkeypatch.setattr(bp, "_rest_prs", fake_rest)
    monkeypatch.setattr(bp, "PHASE_BUDGET_S", 5)
    monkeypatch.setattr(bp, "_PHASE_DEADLINE", None)

    started = bp.time.time()
    assert bp.compute() is not None
    assert deadlines, "the REST arm never ran"
    assert all(d is not None for d in deadlines)
    assert max(deadlines) <= started + 5 + 1, (
        "a REST read was given a budget that outlives the phase clock: %r" % (deadlines,))
    assert bp._PHASE_DEADLINE is None, "the phase clock must be RESTORED, never left spent"


def test_the_phase_budget_fits_the_slack_band_and_holds_the_rest_budget():
    """⛔ A PHASE BUDGET IS NOT A READ BUDGET — TWO EARLIER DRAFTS GOT THIS WRONG IN OPPOSITE WAYS.

    * 40 s set it BELOW a single measured `gh` read.
    * 100 s set it ABOVE the 40-90 s this step actually has left inside the tick
      (`scripts/heartbeat-loop.sh`: `run_bounded $((TARGET - IN_PASS_RESERVE))` = 390 s for the
      WHOLE `orchestrator-heartbeat.sh`, of which ~300-350 s is spent before `beta-progress.py`
      runs at `scripts/orchestrator-heartbeat.sh:411`). A budget above the remaining slack can
      never fire before `run_bounded` kills the tick, so it is an INERT ENFORCER: it looks like
      protection and protects nothing.

    So the pin is two-sided: the phase must FIT the slack band (else it is inert) and must HOLD the
    REST arm it contains (else the REST reads are clipped by the clock instead of by their own
    budget). It is deliberately NOT tied to a single-read latency measurement — a phase containing
    six such reads cannot fit this step whatever the constants say, and that residual is stated in
    the module rather than papered over with a number the step cannot honour.
    """
    assert bp.PHASE_BUDGET_S >= 2 * bp.REST_BUDGET_S, (
        "the REST arm (%ss) must fit INSIDE the phase budget (%ss) with room, or the phase clock "
        "clips reads the REST budget meant to allow" % (bp.REST_BUDGET_S, bp.PHASE_BUDGET_S))
    assert bp.PHASE_BUDGET_S <= 90, (
        "a phase budget above this step's residual slack (40-90 s) cannot fire before "
        "`run_bounded` kills the tick — it is an inert enforcer, not a bound")
    assert bp.PHASE_BUDGET_S < 390, (
        "a phase budget at or above the tick's own kill cannot bound anything")


def test_gh_derives_its_child_timeout_from_the_phase_clock(monkeypatch):
    """⛔ THE PHASE CLOCK'S CENTRAL CLAIM: `gh()` SHRINKS ITS CHILD'S TIMEOUT TO WHAT IS LEFT.

    Deleting just `tmo = min(tmo, left)` (keeping the spent-clock refusal) left 33/33 green — so the
    mechanism the whole bound rests on was untested. Without it a read starting with 1 s left still
    gets a flat 120 s and can outlive the phase by 119 s, which is exactly the unbounded growth the
    clock exists to remove.
    """
    seen = []

    def fake_run(args, **kw):
        seen.append(kw.get("timeout"))
        raise RuntimeError("stop here — the timeout is the datum")

    monkeypatch.setattr(bp.subprocess, "run", fake_run)
    monkeypatch.setattr(bp, "_PHASE_DEADLINE", bp.time.time() + 3)
    assert bp.gh("pr", "list", "--repo", bp.REPO) is None   # no output -> None
    assert seen, "gh() never spawned the child"
    assert seen[0] is not None and seen[0] <= 3.1, (
        "the child timeout %r was not derived from the 3 s left on the phase clock" % (seen[0],))

    # ...and with NO phase in flight, the pre-existing flat timeout is kept.
    seen.clear()
    monkeypatch.setattr(bp, "_PHASE_DEADLINE", None)
    assert bp.gh("pr", "list", "--repo", bp.REPO) is None
    assert seen[0] == 120.0, "a direct call must keep gh()'s own 120 s, got %r" % (seen[0],)


def test_the_rest_read_refuses_a_falsy_repo_instead_of_substituting_the_tracker(monkeypatch):
    """⛔ `repo or REPO` WAS THE HAZARD ITS OWN CALLER'S COMMENT NAMED.

    The `FIX_REPOS` validation only protects the call sites that remember it; `_rest_prs` itself
    still fell back to the tracker for any falsy `repo`, handing back the TRACKER's `/pulls` under
    the caller's repo name — a wrong list that still looks complete. `None` is the documented
    "the tracker" default; anything else must be well-formed or the read is refused.
    """
    urls = []
    monkeypatch.setattr(bp, "_token", lambda: "test-token")
    monkeypatch.setattr(bp, "_rest_get_json",
                        lambda url, tok, timeout=None: (urls.append(url) or []))

    for bad in ("", "agent-infra", "daniel-ospina/", "a/b/c", False, 0):
        assert bp._rest_prs("open", limit=100, deadline=bp.time.time() + 5, repo=bad) is None, (
            "repo=%r must be REFUSED, not answered with the tracker's list" % (bad,))
    assert urls == [], "a refused repo still made a request: %r" % (urls,)

    # `None` is the documented tracker default and still works.
    assert bp._rest_prs("open", limit=100, deadline=bp.time.time() + 5, repo=None) == []
    assert "/repos/%s/pulls" % bp.REPO in urls[0]


# ── the PRODUCER'S contract: a failed read is UNKNOWN (None), never an empty list ──
def test_gh_returns_None_on_any_failure_and_never_an_empty_list(monkeypatch):
    """⛔ MUTATION-SURVIVED (measured 2026-11-03) BEFORE THIS TEST EXISTED.

    `test_both_sources_failing_keeps_the_unavailable_path` monkeypatches `bp.gh` itself, so it
    proves the CALLERS honour None and stays green when `gh()` is mutated back to the pre-fix
    `return []` on failure: every mutant of the producer passed the whole suite. That is defect
    (1) in this module's header — `json.loads(r.stdout or "[]")` turned a FAILED read into a
    VALID EMPTY LIST, so every `is None` guard became dead code and the fleet read "0 open PRs"
    while 100 were open. The invariant "unknown is not zero" has to be pinned where the
    regression lives, at the producer.
    """
    class R:
        def __init__(self, rc, out):
            self.returncode = rc
            self.stdout = out
            self.stderr = ""

    # A failing gh (auth refusal, rate limit, network) is UNKNOWN whatever it printed.
    for rc, out in ((1, ""), (1, "[]"), (2, "[]"), (0, ""), (0, "   \n")):
        monkeypatch.setattr(bp.subprocess, "run", lambda *a, **k: R(rc, out))
        assert bp.gh("issue", "list") is None, (
            "rc=%r stdout=%r must be UNKNOWN (None) -- an empty list renders as a measured zero"
            % (rc, out))

    # ⛔ …AND THE TWO `except` ARMS WERE STILL UNPINNED (review cycle 11, finding 1). Every case
    # above hands `gh()` a COMPLETED command with empty-or-`[]` stdout, so it never reaches either
    # exception path: `(0, "")` and `(0, "   \n")` short-circuit at the `if not out: return None`
    # guard BEFORE the parse, and nothing makes `subprocess.run` raise. Measured: mutating EITHER
    # arm's `return None` to the pre-fix `return []` left the suite at `22 passed` — the same
    # mutation-survival this test exists to end, one arm over. Both are reachable in production:
    # a truncated body, an HTML rate-limit page, or a layer warning on stdout takes the PARSE arm;
    # a missing or unelevatable `gh` binary takes the SPAWN arm. Both mean UNKNOWN.
    for out in ("not json", '{"truncated"', "<html>rate limited</html>"):
        monkeypatch.setattr(bp.subprocess, "run", lambda *a, **k: R(0, out))
        assert bp.gh("issue", "list") is None, (
            "rc=0 stdout=%r is not JSON -- a parse failure is UNKNOWN, never an empty list" % out)

    def _cannot_spawn(*a, **k):
        raise OSError("gh is not on PATH")

    monkeypatch.setattr(bp.subprocess, "run", _cannot_spawn)
    assert bp.gh("issue", "list") is None, (
        "a gh that could not be spawned is UNKNOWN -- the spawn arm must not render as []")

    # ... and a SUCCESSFUL read that genuinely returns [] is a real answer, not an abstention.
    monkeypatch.setattr(bp.subprocess, "run", lambda *a, **k: R(0, "[]"))
    assert bp.gh("issue", "list") == []


# ── the age's POSITIVE half: a stale cache must SAY it is stale ──
def test_a_cache_25_minutes_old_prints_25m_ago_not_zero(no_cache, capsys):
    """⛔ ONLY THE NEGATIVE HALF OF THE AGE WAS PINNED (measured 2026-11-03).

    `test_a_slightly_future_cache_stamp_never_prints_a_negative_age` covers `-Nm ago`; nothing
    asserted a POSITIVE age, so `age_m = 0` — the reported "always 0m ago" defect, which defeats
    the entire purpose of printing an age — survived the whole suite when mutated in. The header's
    own evidence is a line that read "P0 21 open" for ~50 minutes while the truth was 19, and the
    orchestrator nearly dispatched on it: a stale figure is read as LIVE unless the age says
    otherwise.

    The stamp is 25 min old, inside the 1800 s TTL, so this exercises the CACHE-HIT path — the
    one taken on ~15 of every 16 beats — rather than a recompute that would print 0m correctly.
    """
    stamp = int(time.time()) - 25 * 60
    with open(bp.CACHE, "w") as fh:
        json.dump({"ts": stamp, "open_prs": 5, "merged_today": 2,
                   "p0": {"open": 3, "with_pr": 2, "without": 1},
                   "p1": {"open": 4, "with_pr": 4, "without": 0}}, fh)

    assert bp.main() == 0
    out = capsys.readouterr().out
    assert "25m ago" in out, (
        "a 25-minute-old cache must print `25m ago` — an always-0m age makes a stale figure "
        "indistinguishable from a live one. got: %r" % out)
