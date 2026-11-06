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


def pr(number, merged=None, ref=None, title=None):
    """One row in the `gh pr list --json` shape this file consumes.

    ⛔ `merged` DEFAULTS TO `None`, NOT `""` (#3457 review round 14). `mergedAt` is MANDATORY in a
    merged window (`_shape_pr_rows`), and every row of a `gh pr list --state merged` read carries a
    non-empty stamp, so `""` was a payload NEITHER production arm can emit — and it was the easy
    default, so three fixtures put an impossible row into a merged window and pinned the leniency.
    With `None` the mistake is refused: a merged-window fixture must pass `merged=` explicitly.
    """
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
    """The budget is shared by ALL FOUR PR lists (the tracker's open/merged pair and every fix
    repo's pair), so a page that hangs must not eat the
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
    # ⛔ AND THE SECOND SOURCE IS REFUSED HERE TOO. Without this, a mutation that forces the REST
    # path sends the test to the REAL api.github.com: on a box holding a token it PASSES on live
    # data (measured: the suite goes 0.9 s -> 21.9 s and the mutant stays green, because the
    # network answered 38 real rows). A test the internet can satisfy is not pinning the code it
    # names — `test_an_unreadable_fix_repo_is_not_a_gap` already stubs both sources for this reason.
    monkeypatch.setattr(bp, "_rest_prs", lambda *a, **k: None)

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
            # a stamp on the merged arm: `mergedAt` is mandatory in a merged window (#3457 round 14)
            return [pr(3368, merged=LONG_AGO,
                       title="fix(reaper): the harness PIN TREE is a holder (#10114)")]
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

    assert bp._rest_prs("open", limit=100, deadline=bp.time.monotonic() + 30, repo=other) == []
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
    tried = []

    def refusing_rest(state, limit=100, deadline=None, repo=None):
        tried.append((repo, state))
        return None

    monkeypatch.setattr(bp, "_rest_prs", refusing_rest)

    assert bp.compute() is None, (
        "a malformed fix-repo payload must not raise out of compute(), and must not be read as "
        "a complete list")
    # ⛔ "REST TRIED AND REFUSED" IS NOT "REST NEVER TRIED" (#3457 review round 11). The shape gate
    # used to sit AFTER the fallback, so this payload returned None without ever asking the second
    # source — and this test could not see the difference, because both outcomes are `compute() is
    # None`. That is precisely the "one repo's odd answer costs the whole line" failure `_repo_prs`
    # exists to prevent: a fix repo answering `{"message": "Not Found"}` took the DELIVERY line
    # down while a REST read would have answered.
    assert ("daniel-ospina/agent-infra", "open") in tried, (
        "the second source was never asked for the malformed fix repo — the shape gate ran before "
        "the fallback instead of as part of it")

    # ⛔ AND A MALFORMED LIST MUST ASK IT TOO, not only a non-list (#3457 review round 12). The
    # first form of this test glued a `{"message": ...}` OBJECT, which `_rest_prs` also refuses, so
    # the round-11 mutant — fallback gated on `not isinstance(rows, list)` only — stayed green while
    # the shipped code recovered `with_pr=1` on the same payload. Here the bad answer is a LIST of
    # non-rows, which is the shape a `isinstance(rows, list)`-only fallback lets through to the gate
    # AFTER it: the read comes back `None` instead of asking the second source.
    def fake_gh_bad_list(*args):
        if args[:2] == ("pr", "list"):
            repo = args[args.index("--repo") + 1]
            if repo == bp.REPO:
                return [pr(900)] if args[args.index("--state") + 1] == "open" else []
            return ["nope", 42]                     # a LIST, of things that are not rows
        return []

    tried.clear()
    monkeypatch.setattr(bp, "gh", fake_gh_bad_list)
    answered = {"n": 0}

    def answering_rest(state, limit=100, deadline=None, repo=None):
        tried.append((repo, state))
        answered["n"] += 1
        return [pr(3368, merged=LONG_AGO, ref="fix/10114-x",
                   title="fix(reaper): the thing (#10114)")]

    monkeypatch.setattr(bp, "_rest_prs", answering_rest)
    assert bp.compute() is not None, (
        "a malformed LIST from the fix repo must fall back to REST, not lose the line")
    assert ("daniel-ospina/agent-infra", "open") in tried, (
        "the second source was never asked for a malformed LIST — the gate ran after the fallback "
        "again, one shape further out")


def test_a_non_list_tracker_list_of_non_dicts_is_unavailable_not_a_count(monkeypatch, no_cache):
    """⛔ `len()` TURNS A BAD LIST INTO A NUMBER, AND ONLY `covered()` WOULD HAVE RAISED.

    The tracker lists had a LIST-level gate for one round and no per-row one. With both tier lists
    EMPTY, `covered()` never runs — so nothing raised, and an answered `["nope", None, 42]` printed
    `... | 3 open PRs, 0 merged today` and CACHED it for the 1800 s TTL (measured on a copy before
    the fix). That is the same class, and the same caching consequence, that makes the issue read's
    `{}` the worst of the four.

    The second member is silent: a falsy non-str `mergedAt` (`{}`, `0`) is swallowed by
    `(p.get("mergedAt") or "")` and UNDER-counts `merged_today`, where the fix-repo path refuses
    the identical row. Both are refused now, by the one shared predicate.
    """
    def fake_gh(*args):
        if args[:2] == ("pr", "list"):
            # ⛔ REPO-DISCRIMINATING, AND THAT IS THE POINT (#3457 review round 12). The first form
            # answered the malformed list for EVERY repo, so the FIX-REPO consumer refused it
            # first and the assertion passed for the wrong reason: deleting BOTH tracker
            # `_shape_pr_rows` call sites left 42/42 GREEN (measured). Only `FIX_REPOS == (REPO,)`
            # made the tracker gate observable, which is not a test — it is a coincidence.
            if args[args.index("--repo") + 1] != bp.REPO:
                return []                          # the fix repo answers fine; ONLY the tracker is bad
            return ["nope", None, 42] if args[args.index("--state") + 1] == "open" else []
        return []                                    # both tiers EMPTY: `covered()` never runs

    monkeypatch.setattr(bp, "gh", fake_gh)
    monkeypatch.setattr(bp, "_rest_prs", lambda *a, **k: None)
    assert bp.compute() is None, (
        "a list of non-dict tracker rows must be `unavailable`, never `3 open PRs`")

    # ...and the silent half: a `merged` row whose `mergedAt` is a dict, with an EMPTY open list.
    def fake_gh_merged(*args):
        if args[:2] == ("pr", "list"):
            if args[args.index("--repo") + 1] != bp.REPO:
                return []
            return [] if args[args.index("--state") + 1] == "open" \
                else [{"number": 1, "title": "t", "headRefName": "r", "mergedAt": {}}]
        return []

    monkeypatch.setattr(bp, "gh", fake_gh_merged)
    assert bp.compute() is None, (
        "a non-str `mergedAt` must refuse the read, not UNDER-count `merged_today` through "
        "`(p.get(\"mergedAt\") or \"\")`")

    # ⛔ AND AN ABSENT OR NULL `mergedAt` IS MANDATORY-IN-A-MERGED-WINDOW (#3457 review round 13).
    # The lenient form ("a string WHEN PRESENT") let these through, and every row of a `gh pr list
    # --state merged` read is merged BY CONSTRUCTION — so an absent key is a PARTIAL payload, and
    # `merged_today` reported 0 for it and cached that for the TTL (measured). `_rest_prs` filters
    # unmerged rows out and always emits a string, so nothing legitimate reaches this shape.
    # ⛔ AND `""` BELONGS IN THAT SET (#3457 review round 14): a type check alone accepted it, and
    # `(p.get("mergedAt") or "")` then reports 0 for it exactly as it does for `null` — the
    # rationale this block gives for refusing `None` applies to the empty string verbatim. Only
    # `--state merged` reads are affected: an OPEN list legitimately carries no `mergedAt`.
    for absent in ({}, {"mergedAt": None}, {"mergedAt": ""}):
        def fake_gh_partial(*args, _absent=absent):
            if args[:2] == ("pr", "list"):
                if args[args.index("--repo") + 1] != bp.REPO:
                    return []
                if args[args.index("--state") + 1] == "open":
                    return []
                row = {"number": 3, "title": "a merged PR", "headRefName": "fix/3-x"}
                row.update(_absent)
                return [row]
            return []

        monkeypatch.setattr(bp, "gh", fake_gh_partial)
        assert bp.compute() is None, (
            "a merged-window row with %r must refuse the read — `merged_today` must not report 0 "
            "for a payload it could not fully read" % (absent,))


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
    # ⛔ AND THE SECOND SOURCE IS REFUSED HERE TOO. Without this, a mutation that forces the REST
    # path sends the test to the REAL api.github.com: on a box holding a token it PASSES on live
    # data (measured: the suite goes 0.9 s -> 21.9 s and the mutant stays green, because the
    # network answered 38 real rows). A test the internet can satisfy is not pinning the code it
    # names — `test_an_unreadable_fix_repo_is_not_a_gap` already stubs both sources for this reason.
    monkeypatch.setattr(bp, "_rest_prs", lambda *a, **k: None)

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
    # ⛔ AND THE SECOND SOURCE IS REFUSED HERE TOO. Without this, a mutation that forces the REST
    # path sends the test to the REAL api.github.com: on a box holding a token it PASSES on live
    # data (measured: the suite goes 0.9 s -> 21.9 s and the mutant stays green, because the
    # network answered 38 real rows). A test the internet can satisfy is not pinning the code it
    # names — `test_an_unreadable_fix_repo_is_not_a_gap` already stubs both sources for this reason.
    monkeypatch.setattr(bp, "_rest_prs", lambda *a, **k: None)
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
    # ⛔ THE TRACKER PAIR MUST BE VALID, OR THIS TEST PINS NOTHING (#3457 review round 15). It used
    # to answer `[pr(900)]` for BOTH windows; when `pr()`'s `merged` default became `None` (round
    # 14), the MERGED row was refused by the mandatory-`mergedAt` clause, `compute()` returned None
    # BEFORE the `FIX_REPOS` loop, and the historic `dict.fromkeys`-before-validation bug went
    # invisible: re-applying it left 42/42 GREEN, where at `da437ada3` it redded (measured). A
    # fixture that short-circuits ahead of the code under test is the same false PASS in the other
    # direction.
    def fake_gh(*a):
        if a[:2] != ("pr", "list"):
            return []
        return [pr(900)] if a[a.index("--state") + 1] == "open" else [pr(900, merged=LONG_AGO)]

    monkeypatch.setattr(bp, "gh", fake_gh)
    # ⛔ AND THE SECOND SOURCE IS REFUSED HERE TOO (#3457 review round 10). Every entry in this
    # loop is rejected BEFORE a read, so the fallback never ran -- but the tracker pair's own REST
    # arm does, and a mutant that forces it sent this test to the REAL api.github.com (measured on
    # a copy: 31 live `/pulls` requests, 39.9 s, and the test still PASSED). The suite must not
    # spend the bucket `REST_BUDGET_S` exists to ration.
    monkeypatch.setattr(bp, "_rest_prs", lambda *a, **k: None)
    for bad in (None, "", "agent-infra", "daniel-ospina/agent-infra/extra", "daniel-ospina/",
                ["daniel-ospina/agent-infra"], {"repo": "daniel-ospina/agent-infra"}):
        monkeypatch.setattr(bp, "FIX_REPOS", (bp.REPO, bad))
        assert bp.compute() is None, (
            "%r must be UNREADABLE (return None), never a TypeError and never a silent "
            "substitution of the tracker" % (bad,))


def test_an_empty_object_issue_read_is_unavailable_not_a_zero_line(monkeypatch, no_cache):
    """⛔ THE WORST NON-LIST PAYLOAD IS THE ISSUE READ'S `{}` (#3457 review round 10).

    `{}` iterates to NOTHING, so there is no row to reject: `len({})` is 0 and the tier renders
    `0 open, 0 with PR, 0 NONE` — a WRONG NUMBER rather than `unavailable`, and `main()` CACHES it
    for the whole 1800 s TTL. Measured on the shipped module before the gate: an issue read that
    answered `{}` printed `P0 0 open (0 with PR, 0 NONE) | P1 0 open (0 with PR, 0 NONE)`, i.e.
    "beta has no open P0/P1" — the single most misleading line this instrument can print.

    The fix-repo path got this gate in this PR; the three tracker/issue reads did not, and `gh` can
    exit 0 with a JSON object (`{"message": "Not Found"}`) exactly as it can for a PR list.
    """
    def fake_gh(*args):
        if args[:2] == ("pr", "list"):
            return [pr(900)] if args[args.index("--state") + 1] == "open" else []
        return {}                                   # rc 0, an empty JSON OBJECT

    monkeypatch.setattr(bp, "gh", fake_gh)
    monkeypatch.setattr(bp, "_rest_prs", lambda *a, **k: None)
    assert bp.compute() is None, (
        "an answered non-list ISSUE read must be `unavailable`, never a cached zero line")

    # ⛔ AND THE ISSUE ROWS ARE THE ONLY ONES WHOSE `number` IS DEREFERENCED — so the shared
    # predicate's bool-is-not-an-int rule belongs here most of all (#3457 review round 12). A tier
    # list of `[{"number": True}]` used to pass the old `isinstance(rows, list)` gate and reach
    # `covered(True)`, where `"%d" % True` is `"1"` — a cover decided by a searched-for `1`.
    def fake_gh_bool(*args):
        if args[:2] == ("pr", "list"):
            return [pr(900)] if args[args.index("--state") + 1] == "open" else []
        return [{"number": True}]

    monkeypatch.setattr(bp, "gh", fake_gh_bool)
    assert bp.compute() is None, (
        "a bool `number` on a tier row must refuse the read — `covered(True)` searches for '1'")


def test_an_answered_non_list_tracker_pr_read_engages_the_rest_fallback(monkeypatch, no_cache):
    """⛔ A DICT IS TRUTHY AND SIZED, SO `is None` NEVER FIRES ON IT (#3457 review round 10).

    Measured before the gate: an open read answered `{"message": "Not Found"}` against a good
    merged list printed `... | 1 open PRs, 0 merged today` — `len(dict)` == 1 — and never reached
    the REST fallback, which is the failure this file's whole second-source exists to prevent.
    The tracker reads now apply the SAME rule the fix-repo path already had: a non-list answer is
    a FAILED read, so the second source is tried; if that refuses too, the line is `unavailable`.
    """
    def fake_gh(*args):
        if args[:2] == ("pr", "list"):
            # ⛔ REPO-DISCRIMINATING (#3457 review round 12): the tracker answers badly and the fix
            # repo answers well, so ONLY the tracker's normalisation can produce this `None`.
            if args[args.index("--repo") + 1] != bp.REPO:
                return []
            return {"message": "Not Found"}         # rc 0, wrong shape, TRUTHY
        return []

    spent = []

    def refusing_rest(state, limit=100, deadline=None, repo=None):
        spent.append(state)
        return None

    monkeypatch.setattr(bp, "gh", fake_gh)
    monkeypatch.setattr(bp, "_rest_prs", refusing_rest)

    assert bp.compute() is None, (
        "a malformed-but-answered tracker list is a FAILED read, never `1 open PRs`")
    assert "open" in spent, (
        "the second source was never asked — a non-list answer must trigger the fallback, not be "
        "counted through `len()`")


def test_a_fix_repo_listed_twice_is_read_once(monkeypatch, no_cache):
    """The dedupe is load-bearing on the BUDGET, not only on tidiness: a repo listed twice used to
    be one read via `dict.fromkeys`, and moving validation ahead of it must not lose that."""
    other = "daniel-ospina/agent-infra"
    calls = []

    def fake_gh(*args):
        calls.append(args)
        if args[:2] == ("pr", "list"):
            if args[args.index("--repo") + 1] != bp.REPO:
                return []
            # the merged window needs its stamp: `mergedAt` is mandatory there (#3457 round 14)
            return [pr(900)] if args[args.index("--state") + 1] == "open" \
                else [pr(900, merged=LONG_AGO)]
        return []

    monkeypatch.setattr(bp, "gh", fake_gh)
    monkeypatch.setattr(bp, "FIX_REPOS", (bp.REPO, other, other))
    # ⛔ AND THE SECOND SOURCE IS REFUSED HERE TOO. Without this, a mutation that forces the REST
    # path sends the test to the REAL api.github.com: on a box holding a token it PASSES on live
    # data (measured: the suite goes 0.9 s -> 21.9 s and the mutant stays green, because the
    # network answered 38 real rows). A test the internet can satisfy is not pinning the code it
    # names — `test_an_unreadable_fix_repo_is_not_a_gap` already stubs both sources for this reason.
    monkeypatch.setattr(bp, "_rest_prs", lambda *a, **k: None)

    assert bp.compute() is not None
    reads = [a for a in calls
             if a[:2] == ("pr", "list") and a[a.index("--repo") + 1] == other]
    assert len(reads) == 2, "one repo, two windows — got %d reads: %r" % (len(reads), reads)
    # ⛔ AND THE WINDOW SIZES ARE PART OF THE CONTRACT, NOT A DETAIL (#3457 review round 6). They
    # were unpinned: on a /tmp copy, `(500, 400)` -> `(100, 100)` left the whole suite GREEN. A
    # 100-row merged window scrolls `agent-infra#3368`'s cover of #10114 out within DAYS (the
    # 400-row window already spans #2035..#3418), silently re-creating the decay this change exists
    # to remove -- and nothing would red. The tracker pair's windows are already asserted; this is
    # the same assertion for the pair that feeds the gap count.
    windows = {a[a.index("--state") + 1]: a[a.index("--limit") + 1] for a in reads}
    assert windows == {"open": "500", "merged": "400"}, (
        "the fix-repo windows must be the tracker's windows (open 500 / merged 400), got %r"
        % (windows,))
    # ⛔ AND THE MERGED READ MUST ASK FOR THE STAMP (#3457 review round 15). `mergedAt` is
    # MANDATORY in a merged window, so dropping it from the `--json` list would make every merged
    # read refuse — and, because `_repo_prs` then falls back, silently move all four lists onto the
    # un-layer'd REST arm forever. Nothing asserted the field list, so both such edits left 42/42
    # GREEN (measured). This is the one place the field list is observable.
    for a in calls:                    # EVERY list, the TRACKER's included
        if a[:2] == ("pr", "list") and a[a.index("--state") + 1] == "merged":
            assert "mergedAt" in a[a.index("--json") + 1], (
                "a merged read does not ask for `mergedAt` (%r) — every row it returns will be "
                "refused by the mandatory-stamp rule, and the read will silently live on the REST "
                "fallback with nothing red" % (a,))


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
            # ⛔ EVERY CASE HERE CARRIES A VALID `mergedAt` (#3457 review round 15). Without a
            # stamp the MERGED window refused each row first, so the branch under test was never
            # the one that refused: deleting the `title`/`headRefName` clause left 42/42 GREEN
            # (measured). A valid stamp makes the type branch the ONLY possible refusal.
            {"number": 3368, "title": {"a": 1}, "headRefName": "fix/x", "mergedAt": LONG_AGO},
            {"number": 3368, "title": "t", "headRefName": ["fix/x"], "mergedAt": LONG_AGO},
            {"number": {"n": 1}, "title": "t", "headRefName": "fix/x", "mergedAt": LONG_AGO},
            {"number": True, "title": "t", "headRefName": "fix/x", "mergedAt": LONG_AGO},
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


def test_an_empty_object_fix_repo_payload_is_unavailable_not_a_gap(monkeypatch, no_cache):
    """⛔ THE ONE PAYLOAD THE PER-ROW GATE CANNOT SEE: `{}`.

    `_repo_prs` refuses a non-list, then refuses any row that is not a well-shaped dict. An EMPTY
    JSON OBJECT (`{}`, rc 0) satisfies BOTH: iterating it yields no row to reject, and
    `fix_prs.extend({})` is a silent no-op — so the fix repo contributes nothing and the metric
    reports a GAP for every unit whose fix lives there, which is the exact fail-open direction this
    change exists to remove (an unreadable repo must read `unavailable`, never `without_pr`).

    ⛔ THIS TEST PINNED A GAP IN THE GATE, measured: deleting `if not isinstance(rows, list):
    return None` left the suite GREEN at 35 passed, because `{"message": "Not Found"}` happens to
    be caught one line later (iterating a dict yields its KEYS, which are not dicts) and
    `{}` was never offered. With the gate removed this test's `compute()` returns a clean-looking
    `p0 {open: 1, with_pr: 0, without: 1}` instead of `None`.
    """
    def fake_gh(*args):
        if args[:2] == ("pr", "list"):
            repo = args[args.index("--repo") + 1]
            if repo == bp.REPO:
                return [pr(900)] if args[args.index("--state") + 1] == "open" else []
            return {}                                # rc 0, an empty JSON OBJECT
        label = args[args.index("--label") + 1]
        return _issue_rows(*{"P0-blocker": (10114,), "P1-severe": ()}[label])

    monkeypatch.setattr(bp, "gh", fake_gh)
    monkeypatch.setattr(bp, "_rest_prs", lambda *a, **k: None)

    assert bp.compute() is None, (
        "an empty-object fix-repo payload must read `unavailable`, never a gap — an unread repo "
        "that contributes no rows is indistinguishable from a repo with no PRs")


def test_the_token_spawn_draws_on_the_phase_clock_too(monkeypatch, tmp_path):
    """⛔ "ONE CLOCK BOUNDS THE WHOLE PHASE" WAS FALSE BY 5 s — THE CREDENTIAL SPAWN.

    `gh auth token` is a `gh` CHILD on a flat 5 s and `_rest_prs` resolves it BEFORE checking its own
    deadline, so on a gh-refusing box (keyring config, no env token) the phase's worst case was
    `PHASE_BUDGET_S + 5 s`. Measured before the fix: with `PHASE_BUDGET_S = 0.0001` `compute()`
    still spawned `['…/gh', 'auth', 'token', '--hostname', 'github.com']` with `timeout=5`, i.e. the
    phase can outlive its own clock inside exactly the case the clock was added for.
    """
    monkeypatch.delenv("GH_TOKEN", raising=False)
    monkeypatch.delenv("GITHUB_TOKEN", raising=False)
    monkeypatch.delenv("GH_CONFIG_DIR", raising=False)
    monkeypatch.setenv("HOME", str(tmp_path))        # no hosts.yml -> the subprocess path
    spawned = []

    def fake_run(args, **kw):
        spawned.append(kw.get("timeout"))
        raise RuntimeError("stop here — the timeout is the datum")

    monkeypatch.setattr(bp.subprocess, "run", fake_run)

    # A spent clock: refuse, do NOT spend the last seconds of the pass on a credential lookup.
    monkeypatch.setattr(bp, "_PHASE_DEADLINE", bp.time.monotonic() - 1)
    assert bp._token() == ""
    assert spawned == [], "a spent phase clock must refuse the credential spawn, not run it"

    # A live clock: the child's timeout is what is LEFT of the phase, not the flat 5 s.
    monkeypatch.setattr(bp, "_PHASE_DEADLINE", bp.time.monotonic() + 2)
    assert bp._token() == ""                       # the fake_run raises -> caught -> ""
    assert spawned and spawned[0] is not None and spawned[0] <= 2.1, (
        "the credential spawn got %r, not what was left of the phase clock" % (spawned[0],))


def test_a_number_that_is_only_a_PREFIX_of_a_fix_repo_citation_is_not_covered(monkeypatch, no_cache):
    """⛔ THE BOUNDARY GUARD IN `covered()` IS NOW LOAD-BEARING ON 448x MORE ROWS.

    `covered()` matches `(?<![\\d])N(?![\\d])`, and that guard was unpinned: replacing the
    pattern with a bare `%d` left the whole suite GREEN (measured, 38 passed). The consequence is a
    FALSE COVER — demonstrated end-to-end on that copy with a P0 unit `#1011` and a fix-repo PR
    titled `fix(reaper): the thing (#10114)`: shipped code reports
    `p0 {open: 1, with_pr: 0, without: 1}`, the mutant reports `{open: 1, with_pr: 1, without: 0}`
    — a P0 silently dropped from the gap count a lane is chartered off. The guard predates this
    change, but the change runs that regex over every row of every repo a fix lands in, so a
    boundary defect that used to see one repo's PRs now sees ~448 more.

    `#101` is included because the prefix relation goes both ways: a PR citing `#10114` must not
    cover `#101` either, and a naive `startswith`-style match would take both.
    """
    other = "daniel-ospina/agent-infra"

    def fake_gh(*args):
        if args[:2] == ("pr", "list"):
            repo = args[args.index("--repo") + 1]
            state = args[args.index("--state") + 1]
            if repo == bp.REPO:
                return [pr(900)] if state == "open" else []
            # The ONLY citation in either repo is `#10114` — a fix for 10114, not for 1011/101.
            return ([pr(3368, ref="fix/10114-pin-tree-is-a-holder",
                         title="fix(reaper): the thing (#10114)")] if state == "open" else [])
        label = args[args.index("--label") + 1]
        return _issue_rows(*{"P0-blocker": (1011,), "P1-severe": (101,)}[label])

    monkeypatch.setattr(bp, "gh", fake_gh)
    assert other in bp.FIX_REPOS
    # ⛔ AND THE SECOND SOURCE IS REFUSED HERE TOO. Without this, a mutation that forces the REST
    # path sends the test to the REAL api.github.com: on a box holding a token it PASSES on live
    # data (measured: the suite goes 0.9 s -> 21.9 s and the mutant stays green, because the
    # network answered 38 real rows). A test the internet can satisfy is not pinning the code it
    # names — `test_an_unreadable_fix_repo_is_not_a_gap` already stubs both sources for this reason.
    monkeypatch.setattr(bp, "_rest_prs", lambda *a, **k: None)

    out = bp.compute()
    assert out is not None
    assert out["p0"] == {"open": 1, "with_pr": 0, "without": 1}, (
        "#1011 must NOT be covered by a citation of #10114 — a prefix match silently drops a P0 "
        "from the gap count, which is the miss this instrument exists to report")
    assert out["p1"] == {"open": 1, "with_pr": 0, "without": 1}, (
        "#101 must NOT be covered by a citation of #10114 either — the boundary holds in both "
        "directions")


def test_the_phase_clock_restores_the_deadline_it_found(monkeypatch):
    """⛔ THE RESTORE IS A CONTRACT, AND IT WAS UNPINNED IN BOTH DIRECTIONS (#3457 review round 7).

    `_phase_clock` claims it "restores what was there before" and the module comment says
    `compute()` "restores the previous value when it returns". Neither was observable: `compute()`
    is the only `with` caller, so `_prev` is always `None` in production, and BOTH mutations —
    `__exit__` assigning `None` unconditionally, and deleting `_prev`/`__slots__` outright — left
    the suite GREEN. A context manager whose restoration is indistinguishable from a hard reset is
    a claim, not a mechanism; the next caller to nest it (a partial re-read, a test that opens a
    short clock inside a long one) would silently have its outer bound destroyed.
    """
    outer = bp.time.monotonic() + 100
    monkeypatch.setattr(bp, "_PHASE_DEADLINE", outer)

    with bp._phase_clock() as inner:
        assert inner is not outer, "the block did not open its own clock"
        assert bp._PHASE_DEADLINE == inner
        with bp._phase_clock() as innermost:
            assert bp._PHASE_DEADLINE == innermost
        assert bp._PHASE_DEADLINE == inner, (
            "the nested block did not restore the clock it found — a partial re-read would lose "
            "its parent's bound")

    assert bp._PHASE_DEADLINE == outer, (
        "the outermost block must restore the deadline that was there BEFORE it, not `None`")

    # ⛔ AND IT MUST NOT SWALLOW WHAT HAPPENS INSIDE IT (#3457 review round 8). `__exit__` returns
    # `False`, and that was unpinned: mutating it to `return True` left 38 passed, because the
    # restore is asserted and the exception's fate is not. A swallowed exception means `main()`'s
    # handler — the one whose recorded detail the module calls invaluable in a hand run — never
    # runs, the tick prints a bare `unavailable`, and NOTHING is red. The clock is restored on the
    # way out either way, so both halves are asserted here.
    with pytest.raises(RuntimeError, match="boom"):
        with bp._phase_clock():
            raise RuntimeError("boom")
    assert bp._PHASE_DEADLINE == outer, (
        "an exception must not leave the phase clock spent either")


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
    monkeypatch.setattr(bp, "_PHASE_DEADLINE", bp.time.monotonic() - 1)

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

    started = bp.time.monotonic()
    assert bp.compute() is not None
    assert deadlines, "the REST arm never ran"
    assert all(d is not None for d in deadlines)
    assert max(deadlines) <= started + 5 + 1, (
        "a REST read was given a budget that outlives the phase clock: %r" % (deadlines,))
    assert bp._PHASE_DEADLINE is None, "the phase clock must be RESTORED, never left spent"

    # ⛔ AND THE CLAMP IS NOT THE ONLY HALF (#3457 review round 7). `rest_deadline` is a MIN of the
    # REST budget and the phase clock, and every assertion above runs with a SHORT clock (5 s),
    # which the min always wins -- so the REST arm's own half was untested. Measured: with the
    # phase clock at 100 s, mutating `REST_BUDGET_S` -> `PHASE_BUDGET_S` there left 37 passed, i.e.
    # a future edit could silently hand the REST arm the whole phase budget (60 s) and the
    # "REST IS A CHILD OF THE PHASE CLOCK, not a peer" property would be gone with nothing red.
    deadlines.clear()
    monkeypatch.setattr(bp, "PHASE_BUDGET_S", 100)     # well ABOVE REST_BUDGET_S, so the min matters
    monkeypatch.setattr(bp, "_PHASE_DEADLINE", bp.time.monotonic() + 100)
    started = bp.time.monotonic()
    assert bp._compute() is not None
    assert deadlines and all(d is not None for d in deadlines)
    assert max(deadlines) - started <= bp.REST_BUDGET_S + 1, (
        "the REST arm was handed %r, i.e. NOT bounded by its own %ss budget -- the phase clock is "
        "its PARENT, not its substitute" % (max(deadlines) - started, bp.REST_BUDGET_S))


def test_the_phase_budget_fits_the_slack_band_and_holds_the_rest_budget():
    """⛔ A PHASE BUDGET IS NOT A READ BUDGET — TWO EARLIER DRAFTS GOT THIS WRONG IN OPPOSITE WAYS.

    * 40 s set it BELOW a single measured `gh` read.
    * 100 s set it ABOVE the 40-90 s this step actually has left inside the tick
      (`scripts/heartbeat-loop.sh`: `run_bounded $((TARGET - IN_PASS_RESERVE))` = 390 s for the
      WHOLE `orchestrator-heartbeat.sh`, of which ~300-350 s is spent before `beta-progress.py`
      runs (the `DELIV=` step in `scripts/orchestrator-heartbeat.sh`)). A budget above the remaining
      slack can
      never fire before `run_bounded` kills the tick, so it is an INERT ENFORCER: it looks like
      protection and protects nothing.

    ⛔ AND THE BAND HAS A FLOOR THE CEILING TEST CANNOT SEE. 60 s fires whenever at least 60 s of
    the pass remain — the band's middle and up — but it CANNOT fire in the band's bottom (40-59 s),
    where the tick is killed first; below 40 it is worse, and the harness's own accounting floors a
    tick residual at 20 s (the `remaining()` helper in `heartbeat-loop.sh`). The module states that
    residual instead of
    claiming the clock covers the whole band. What this test must catch is the OPPOSITE error (a
    constant so large it can never fire), which is why the ceiling is asserted against the band's
    TOP — not a figure of speech about "inside the window".

    So the pin is two-sided: the phase must FIT under the band's top (else it is inert) and must
    HOLD the REST arm it contains (else the REST reads are clipped by the clock instead of by their
    own budget). It is deliberately NOT tied to a single-read latency measurement — a phase
    containing six such reads cannot fit this step whatever the constants say, and that residual is
    stated in the module rather than papered over with a number the step cannot honour.
    """
    assert bp.PHASE_BUDGET_S >= 2 * bp.REST_BUDGET_S, (
        "the REST arm (%ss) must fit INSIDE the phase budget (%ss) with room, or the phase clock "
        "clips reads the REST budget meant to allow" % (bp.REST_BUDGET_S, bp.PHASE_BUDGET_S))
    assert bp.PHASE_BUDGET_S <= 90, (
        "a phase budget above the TOP of this step's residual slack (40-90 s) cannot fire before "
        "`run_bounded` kills the tick even in the best case — it is an inert enforcer, not a bound")
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
    monkeypatch.setattr(bp, "_PHASE_DEADLINE", bp.time.monotonic() + 3)
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
        assert bp._rest_prs("open", limit=100, deadline=bp.time.monotonic() + 5, repo=bad) is None, (
            "repo=%r must be REFUSED, not answered with the tracker's list" % (bad,))
    assert urls == [], "a refused repo still made a request: %r" % (urls,)

    # `None` is the documented tracker default and still works.
    assert bp._rest_prs("open", limit=100, deadline=bp.time.monotonic() + 5, repo=None) == []
    assert "/repos/%s/pulls" % bp.REPO in urls[0]


# ── a cover that lives ONLY in a branch name, which nothing else exercised ────
def test_a_number_that_appears_ONLY_in_the_fix_repo_branch_is_a_cover(monkeypatch, no_cache):
    """⛔ THE `headRefName` HALF OF `covered()` WAS PINNED BY NO TEST (#3457 review round 19).

    Mutating `covered()` to search `title` only left the whole suite GREEN, because every fixture
    that cites a tracker unit in a fix-repo row carried the number in BOTH fields — so no
    assertion could say which one produced the cover, and the branch half could be deleted in
    silence. That is the wrong half to be blind to: this section's own measured collision list is
    BRANCH citations (`fix/10114-pin-tree-is-a-holder`, `fix/10951-pool-filter`), i.e. exactly the
    shape nothing exercised on its own.

    Here the TITLE carries no number at all, so `with_pr` can only come from `headRefName`.
    """
    _gh_by_repo(
        monkeypatch,
        tracker_open=[pr(900)],
        tracker_merged=[],
        other_open=[pr(3368, ref="fix/10114-pin-tree-is-a-holder",
                        title="fix(reaper): the harness PIN TREE is a holder, not residue")])
    # Same reason as the test above: a forced-REST mutant must not reach api.github.com.
    monkeypatch.setattr(bp, "_rest_prs", lambda *a, **k: None)

    out = bp.compute()
    assert out is not None
    assert out["p0"] == {"open": 1, "with_pr": 1, "without": 0}, (
        "the branch carries `10114` and the title does NOT — a cover visible only through "
        "`headRefName` must still count, or every `fix/<n>-…` PR is invisible to the gap count")


# ── the `merged_today` day boundary: `>=`, and the suite was blind to it ──────
def test_merged_today_counts_a_pr_merged_at_exactly_midnight_utc(monkeypatch):
    """⛔ THE DAY BOUNDARY IS `>=`, AND THE WHOLE SUITE WAS BLIND TO IT (#3457 review round 16).

    MEASURED defect this pins: flipping `>=` to `>` in `_compute()`'s
    `merged_today = sum(1 for p in merged if (p.get("mergedAt") or "") >= today)` left **42/42
    GREEN**, because every "merged today" fixture is either `MERGED_TODAY =
    "2999-01-01T00:00:00Z"` or `LONG_AGO = 2020…` — both far from the boundary — so not one
    assertion in this file could tell the two operators apart. `>` drops a PR merged AT midnight
    UTC out of the headline count with no refusal: a silently SHORT `merged_today`, the direction
    this file says it must never fail in.

    Both directions are pinned (the midnight row must COUNT, the row one second earlier must
    NOT), and the calendar is FROZEN rather than read: `MERGED_TODAY`'s own comment exists so a
    midnight-straddling run cannot flake, and a boundary test that read the live clock would red
    for the clock instead of for the code.

    ⛔ AND THE STUB DELEGATES ITS ARGUMENT, which is the difference between pinning the OPERATOR
    and pinning the BOUNDARY (#3457 review round 17). The first form answered `gmtime()` with the
    frozen instant for ANY argument, so it could not see a boundary derived from the wrong
    instant: `today = time.strftime(…, time.gmtime(time.time() - 86400))` — yesterday's midnight
    as the boundary, an INFLATED `merged_today` — left the suite 43/43 GREEN. `time()`
    is frozen to the same instant and `gmtime(secs)` really delegates, so a wrong derivation is a
    wrong answer here rather than an invisible one.
    """
    import datetime
    import time as _time

    epoch = 1_790_000_000
    instant = _time.gmtime(epoch)

    class _Frozen:                      # a closure over `_time`, NOT a module-level class
        """`bp.time` with a PINNED calendar, delegating the stopwatch to the real module.

        `gmtime`/`strftime`/`time` answer from the pinned instant; everything else — `monotonic()`
        above all, which the phase clock budgets on — stays REAL. Freezing the stopwatch would
        make `_PHASE_DEADLINE` unreachable and pin a different program from the one that ships.
        """

        def __init__(self, instant, epoch):
            self._instant = instant
            self._epoch = epoch

        def time(self):
            return float(self._epoch)

        def gmtime(self, secs=None):
            # ⛔ DELEGATE THE ARGUMENT, do not discard it: this is what makes a boundary
            # derived from the WRONG instant observable instead of invisible.
            return self._instant if secs is None else _time.gmtime(secs)

        def strftime(self, fmt, tm):
            return _time.strftime(fmt, tm)

        def __getattr__(self, name):
            return getattr(_time, name)

    day = datetime.datetime(instant.tm_year, instant.tm_mon, instant.tm_mday,
                            tzinfo=datetime.timezone.utc)
    at_midnight = day.strftime("%Y-%m-%dT00:00:00Z")        # == the module's own `today`
    one_second_before = (day - datetime.timedelta(seconds=1)).strftime("%Y-%m-%dT%H:%M:%SZ")

    def fake_gh(*args):
        if args[:2] != ("pr", "list"):
            return []
        if "--state" in args and args[args.index("--state") + 1] == "merged":
            return [pr(1, merged=at_midnight), pr(2, merged=one_second_before)]
        return []

    monkeypatch.setattr(bp, "gh", fake_gh)
    monkeypatch.setattr(bp, "_rest_prs", lambda *a, **kw: [])
    monkeypatch.setattr(bp, "time", _Frozen(instant, epoch))
    # ⛔ THE STUB'S OWN FIDELITY, ASSERTED RATHER THAN PROMISED. The phase clock budgets on
    # `monotonic()`; a stub that froze it would leave `_PHASE_DEADLINE` unreachable and this test
    # would be pinning a different program from the one that ships.
    assert abs(bp.time.monotonic() - _time.monotonic()) < 5, (
        "the frozen stub must delegate `monotonic()` to the REAL module")

    out = bp.compute()
    assert out is not None
    assert out["merged_today"] == 1, (
        "a PR merged at exactly today's 00:00:00Z must COUNT (`>=`) and one merged one second "
        "earlier must NOT — got %r, so the boundary is wrong in one direction: `>` drops the "
        "midnight row (a silently SHORT count) and anything looser counts yesterday"
        % (out["merged_today"],))


def test_rest_prs_with_no_deadline_is_clamped_to_a_live_phase_clock(monkeypatch):
    """⛔ `deadline=None` MUST NOT OUTLIVE THE PHASE CLOCK (#3457 review round 21).

    The default was a bare `REST_BUDGET_S`, so a caller omitting the deadline got 30 s even with
    2 s left on the phase — and the module's "ONE clock bounds the WHOLE phase" then held only
    while every caller remembered to clamp (`_compute` does: `min(rest_deadline, _PHASE_DEADLINE)`).
    A bound a callee holds only when its caller remembers is not a bound; the shipped call sites
    are unaffected, and this removes the trap for the next read someone adds.

    Both halves are asserted because they fail in opposite directions: a LIVE clock shortens the
    request timeout, a SPENT one refuses without spending a request at all.
    """
    seen = []
    monkeypatch.setattr(bp, "_token", lambda: "test-token")          # bypass the credential refusal
    monkeypatch.setattr(bp, "_rest_get_json",
                        lambda url, tok, timeout=None: (seen.append(timeout) or []))

    monkeypatch.setattr(bp, "_PHASE_DEADLINE", bp.time.monotonic() + 2)
    assert bp._rest_prs("open", limit=100) == []
    assert seen and seen[0] <= 2.1, (
        "the request timeout %r was not clamped to the 2 s the phase has left" % (seen[0],))

    seen.clear()
    monkeypatch.setattr(bp, "_PHASE_DEADLINE", bp.time.monotonic() - 1)
    assert bp._rest_prs("open", limit=100) is None, "a spent phase clock must REFUSE the read"
    assert seen == [], "a spent phase clock still issued a request"

    # ...and with NO phase in flight the pre-existing default budget is unchanged.
    seen.clear()
    monkeypatch.setattr(bp, "_PHASE_DEADLINE", None)
    assert bp._rest_prs("open", limit=100) == []
    assert seen == [bp.REST_TIMEOUT_S], (
        "without a phase clock the read keeps its own per-request timeout, got %r" % (seen,))


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

# ── `--repo` must never relabel another repo's cached figures ──
def test_a_repo_call_never_returns_another_repos_cached_figures(monkeypatch, no_cache, capsys):
    """⛔ THE CACHE WAS REPO-BLIND, AND `--repo` CHANGED THE LABEL ON IT.

    `--repo X` mutates the global `REPO`, but the cache was one file whose payload carried no repo
    identity and the cache-HIT path is taken ABOVE `compute()` — so for the whole TTL (~15 beats of
    16) a `--repo owner/other` call returned the cached TORTOISE counts printed as `owner/other`'s,
    and in the other direction a miss wrote other-repo numbers into the file the no-arg beat renders
    as tortoise's `DELIVERY:` line. `mcp-servers/orchestrator/server.py::_census` is exactly that
    caller: it fans out with `["--repo", repo, "--json"]`.

    Three arms, one per mechanism: a cache LABELLED with another repo is a miss; an UNLABELLED cache
    away from the base path is a miss; and a `--repo` run writes its own labelled file while leaving
    the base file byte-identical.
    """
    import json as _json
    import time as _time

    now = int(_time.time())
    tortoise_cached = {"ts": now, "repo": "daniel-ospina/tortoise", "open_prs": 7, "merged_today": 3,
                       "p0": {"open": 2, "with_pr": 1, "without": 1},
                       "p1": {"open": 4, "with_pr": 2, "without": 2}}
    other_cached = dict(tortoise_cached, repo="owner/other", open_prs=99, merged_today=99)

    def fresh():
        return {"ts": int(_time.time()), "repo": bp.REPO, "open_prs": 1, "merged_today": 0,
                "p0": {"open": 9, "with_pr": 9, "without": 0},
                "p1": {"open": 9, "with_pr": 9, "without": 0}}

    # (1) A LABELLED cache for a DIFFERENT repo is never served under this repo's name.
    monkeypatch.setattr(bp, "REPO", "owner/other")
    pe = bp._cache_path()
    monkeypatch.setattr(bp, "CACHE", str(no_cache))
    assert bp._cache_path() != str(no_cache), "a non-default repo must not share the base file"
    import pathlib
    pathlib.Path(bp._cache_path()).write_text(_json.dumps(tortoise_cached))
    monkeypatch.setattr(bp, "compute", fresh)
    assert bp.main() == 0
    out = capsys.readouterr().out
    assert "7 open PRs" not in out, "TORTOISE'S CACHED COUNT was served as owner/other's: %s" % out
    assert "99 open PRs" not in out
    assert "1 open PRs" in out, "a mislabelled cache must be a MISS, so the fresh read is used: %s" % out

    # (2) AN UNLABELLED cache away from the base path is a MISS (we cannot know what it measured).
    pathlib.Path(bp._cache_path()).write_text(_json.dumps(
        {k: v for k, v in other_cached.items() if k != "repo"}))
    monkeypatch.setattr(bp, "compute", fresh)
    assert bp.main() == 0
    out = capsys.readouterr().out
    assert "99 open PRs" not in out, "an unlabelled per-repo cache was adopted: %s" % out

    # (3) AND A `--repo` RUN DOES NOT TOUCH THE BASE FILE (the beat's state).
    monkeypatch.setattr(bp, "DEFAULT_REPO", "daniel-ospina/tortoise")
    base_before = no_cache.read_bytes() if no_cache.exists() else b"<absent>"
    monkeypatch.setattr(bp, "compute", fresh)
    # ⛔ DRIVEN THROUGH THE REAL ARGV SURFACE. This arm used to call `bp.main()` with NO arguments
    # and set `REPO` with monkeypatch, so the `--repo` branch was never entered by ANY arm in this
    # file (all 11 call sites were bare `bp.main()`): deleting the whole `elif a == "--repo":` branch
    # left every arm green, including this one, whose TITLE is "a `--repo` run does not touch the base
    # file". `REPO` is reset to the base repo first so a deleted `--repo` branch is OBSERVABLE —
    # without the reset the previous arm's monkeypatched value would make it pass anyway.
    monkeypatch.setattr(bp, "REPO", "daniel-ospina/tortoise")
    assert bp.main(["--repo", "owner/other"]) == 0
    capsys.readouterr()
    assert bp.REPO == "owner/other", "--repo did not reach the module's REPO: %r" % (bp.REPO,)
    after = no_cache.read_bytes() if no_cache.exists() else b"<absent>"
    assert after == base_before, "a --repo run overwrote the base cache the beat renders"
    written = _json.loads(pathlib.Path(bp._cache_path()).read_text())
    assert written["repo"] == "owner/other", written


def test_the_cli_argv_surface_is_real(monkeypatch, no_cache, capsys):
    """⛔ `--repo` AND `--json` ARE THE CONTRACT `_census` CALLS, so they must be driven AS ARGV.

    `mcp-servers/orchestrator/server.py::_census` fans out with `["--repo", repo, "--json"]`, and
    the module's previous body parsed NO argv at all (it hardcoded one repo), so this surface is the
    thing the PR adds. Every other arm in this file sets `REPO` with monkeypatch and calls
    `bp.main()`, which exercises the parser's DEFAULT path only — the two branches below could be
    deleted with the suite green. This arm drives the branches themselves.
    """
    import json as _json
    import time as _time

    def fresh():
        return {"ts": int(_time.time()), "repo": bp.REPO, "open_prs": 1, "merged_today": 0,
                "p0": {"open": 9, "with_pr": 9, "without": 0},
                "p1": {"open": 9, "with_pr": 9, "without": 0}}

    monkeypatch.setattr(bp, "compute", fresh)
    # (a) `--repo` + `--json`: both branches fire, and the payload is the labelled JSON.
    assert bp.main(["--repo", "owner/other", "--json"]) == 0
    payload = _json.loads(capsys.readouterr().out)
    assert payload["repo"] == "owner/other", payload
    assert payload["readable"] is True, payload
    assert payload["measured_at"], payload
    # (b) `--json` ALONE is still the JSON surface, and without it the same run is PROSE — a `--json`
    #     branch that never fired would print the prose line to a caller parsing JSON.
    assert bp.main(["--repo", "owner/other", "--json"]) == 0
    assert capsys.readouterr().out.lstrip().startswith("{"), "--json must emit JSON"
    assert bp.main(["--repo", "owner/other"]) == 0
    prose = capsys.readouterr().out
    assert not prose.lstrip().startswith("{"), "without --json the line is prose: %r" % prose[:80]
    # (c) A MALFORMED OR UNKNOWN ARGUMENT IS A USAGE ERROR (2), never a silent default.
    for argv in (["--repo"], ["--repo", "noslash"], ["--bogus"]):
        assert bp.main(argv) == 2, "%r must be a usage error (2)" % (argv,)


def test_T_fix_repos_follows_the_repo_argument(monkeypatch, tmp_path):
    """[P2, review cycle 7] The merge's `FIX_REPOS` re-derivation was unpinned AND too wide.

    Two defects, one arm each: (a) `globals()["FIX_REPOS"] = _derive_fix_repos(REPO)` could be replaced by
    `pass` with all 49 tests still green, because every `--repo` arm stubs `compute` and never consumes
    FIX_REPOS; (b) `_derive_fix_repos` kept a hardcoded tail, so `--repo owner/other` also counted
    agent-infra PRs as coverage for that repo's issues — the attribution failure the module forbids.
    Deleting the re-derivation, or restoring the unconditional tail, must red this arm.
    """
    # ⛔ HERMETIC, LIKE EVERY SIBLING `--repo` ARM (review cycle 8, P2). Without these two lines the arm
    # performed LIVE GitHub reads (measured 4.8-5.2 s per call, `rest read failed: HTTPError
    # api.github.com/repos/owner/other/pulls`) and WROTE THE OPERATOR'S REAL STATE FILES — a suite run
    # left `~/.pi/agent/state/beta-progress.json` with a real measurement in it, which is the file
    # `scripts/merge-queue.py` and the beat read. Under CI's `--timeout=60` three live calls can also
    # exceed the bound whenever the API degrades.
    # ⛔ AND NOTHING IS LOST BY STUBBING `compute`: the FIX_REPOS re-derivation lives in the ARG PARSER,
    # which runs before `compute` is ever reached — verified by mutation after this change (removing the
    # re-derivation, or restoring the unconditional tail, still reds the arm).
    monkeypatch.setattr(bp, "CACHE", str(tmp_path / "bp.json"))
    monkeypatch.setattr(bp, "compute", lambda *a, **k: {
        "ts": int(time.time()), "repo": bp.REPO, "open_prs": 1, "merged_today": 0,
        "p0": {"open": 0, "with_pr": 0, "without": 0},
        "p1": {"open": 0, "with_pr": 0, "without": 0},
        "coverage": "test", "unavailable": None,
    })
    # ⛔ `main(["--repo", …])` MUTATES MODULE GLOBALS, so this arm restores them — without that it
    # leaves REPO/FIX_REPOS repointed and every later arm inherits the wrong repo (measured: this test
    # passes alone and failed in the full run for exactly that reason).
    saved = (bp.REPO, bp.FIX_REPOS)
    try:
        # ⛔ DO NOT ASSERT THE AMBIENT DEFAULT: an earlier `--repo` arm in this file may already have
        # repointed the globals (measured). Establish the baseline by ASKING for the tracker repo.
        assert bp.main(["--repo", "daniel-ospina/tortoise", "--json"]) in (0, 1)
        assert bp.FIX_REPOS == ("daniel-ospina/tortoise", "daniel-ospina/agent-infra"), bp.FIX_REPOS
        assert bp.main(["--repo", "owner/other", "--json"]) in (0, 1), "usage must not fail"
        # (a) the re-derivation actually ran…
        assert bp.FIX_REPOS == ("owner/other",), bp.FIX_REPOS
        # (b) …and it does NOT inherit the tortoise-specific tail
        assert "daniel-ospina/agent-infra" not in bp.FIX_REPOS, bp.FIX_REPOS
        # naming the tail repo explicitly is its own single-element set, not a duplicate
        assert bp.main(["--repo", "daniel-ospina/agent-infra", "--json"]) in (0, 1)
        assert bp.FIX_REPOS == ("daniel-ospina/agent-infra",), bp.FIX_REPOS
    finally:
        bp.REPO, bp.FIX_REPOS = saved
