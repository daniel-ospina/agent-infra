#!/usr/bin/env python3
"""scripts/test_lane_wip.py — the payload contract `lane-wip.py` states but never pinned.

`lane-wip.py` builds ONE payload for two surfaces (prose and `--json`), and its own comment says
the point is that "the JSON and the prose can never disagree". Nothing tested that, so the rewrite
that introduced `collect()` silently dropped the `…` truncation marker the prose had carried
before it, and set `turns_truncated` to the REQUESTED turn count rather than a truncation flag —
a field whose name and value disagreed on every call.

Both are the "arm that cannot fail" class: a payload asserted only by prose in its comments.

`lane_rows` / `session_file` / `turns` are stubbed, so nothing shells out and no session directory
is read.
"""
import importlib.util
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))


def _load():
    spec = importlib.util.spec_from_file_location(
        "lane_wip_under_test", os.path.join(_HERE, "lane-wip.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _collect(monkeypatch, chars, want, turns_read):
    """Drive `collect()` with its three I/O seams stubbed."""
    lw = _load()
    monkeypatch.setattr(lw, "lane_rows",
                        lambda: [{"ws": "WS1", "lane": "L1", "sid": "sid-abc12345",
                                  "verdict": "WORKING"}])
    monkeypatch.setattr(lw, "session_file", lambda sid: __file__)
    monkeypatch.setattr(lw, "turns", lambda path, n: list(turns_read))
    return lw.collect("WS1", chars=chars, want=want)


def test_an_over_long_turn_is_cut_and_marked(monkeypatch):
    """⛔ THE MARKER WAS DROPPED. The pre-#3382 prose appended `("…" if len(t) > chars else "")`;
    the rewrite that introduced `collect()` cut with a bare `t[:chars]`, so an operator could no
    longer tell a truncated turn from a complete one — the ONE thing `--chars` exists to make
    unambiguous."""
    rc, p = _collect(monkeypatch, chars=10, want=1, turns_read=["x" * 50])
    assert rc == 0, rc
    assert p["turns"] == ["x" * 10 + "\u2026"], p["turns"]
    assert p["turns"][0].count("\u2026") == 1, "exactly ONE ellipsis (a marker, not a pad)"


def test_a_turn_that_fits_is_not_marked(monkeypatch):
    rc, p = _collect(monkeypatch, chars=10, want=1, turns_read=["yyy"])
    assert rc == 0, rc
    assert p["turns"] == ["yyy"], p["turns"]
    assert "\u2026" not in p["turns"][0], "no ellipsis is invented on a turn that fits"


def test_turns_truncated_is_a_flag_not_the_requested_count(monkeypatch):
    """⛔ IT HELD `want`. A consumer reading it as a truncation flag was wrong on EVERY call.

    The requested count is still reported — as `turns_requested`, a name that is true.
    """
    _, p = _collect(monkeypatch, chars=10, want=1, turns_read=["yyy"])
    assert p["turns_truncated"] is False, p["turns_truncated"]
    assert p["turns_requested"] == 1, p["turns_requested"]

    _, p = _collect(monkeypatch, chars=10, want=3,
                    turns_read=["yyy", "x" * 50, "yyy"])
    assert p["turns_truncated"] is True, "one long turn among three still sets the flag"
    assert p["turns_requested"] == 3, p["turns_requested"]
    assert len(p["turns"]) == 3, p["turns"]


def test_the_exit_contract_separates_a_failed_read_from_no_match(monkeypatch):
    """#3382 invariant 1: a lane table that could not be READ is not "no lane matches".

    ⛔ THIS ARM MUST DRIVE `lane_rows()`'s REAL BODY, NOT ONLY ITS OUTPUT. Stubbing `lane_rows` to
    return `None` exercises `collect()` and proves nothing about the function that PRODUCES the
    distinction — and `lane_rows()` is where the defect lived: its old body caught every exception
    and returned `[]`, so an unreadable `lane-status.py` and a fleet with no lanes were the same
    value (the module docstring says exactly this). Reverting `return None` to `return []` left the
    stubbed version of this arm green, so it could not have caught its own defect. Driving
    `subprocess.run` is what makes the production side falsifiable.
    """
    lw = _load()

    # (a) THE PRODUCER: a `lane-status.py` that cannot be read yields `None`, NEVER `[]`.
    def boom(*a, **kw):
        raise OSError("lane-status.py is not there")
    monkeypatch.setattr(lw.subprocess, "run", boom)
    assert lw.lane_rows() is None, "an unreadable lane table is `None`, never `[]`"
    rc, p = lw.collect("WS1")
    assert rc == 3 and "UNMEASURED" in (p.get("unmeasured") or ""), (rc, p)

    # (b) …and a table that is NOT a list (a JSON object, an error blob, empty output) is also
    #     `None` — "could not be read" is not "zero lanes".
    class _Proc:
        def __init__(self, out):
            self.stdout = out
    for out in ('{"not": "a list"}', "", "Traceback (most recent call last):"):
        monkeypatch.setattr(lw.subprocess, "run", lambda *a, **kw: _Proc(out))
        assert lw.lane_rows() is None, "a non-list payload is not a lane table: %r" % (out,)

    # (c) AND A REAL EMPTY FLEET IS `[]`, which IS a readable answer — the two must not collapse.
    monkeypatch.setattr(lw.subprocess, "run", lambda *a, **kw: _Proc("[]"))
    assert lw.lane_rows() == [], "an empty fleet is a READ answer, not an abstention"
    rc, p = lw.collect("NOPE")
    assert rc == 2 and p.get("note"), (rc, p)


def test_an_unreadable_session_file_is_still_UNMEASURED_not_exit_1(monkeypatch, tmp_path):
    """⛔ `session_file()` PROVES THE PATH EXISTS, NOT THAT IT CAN BE READ.

    The exit contract retires rc 1 precisely so "the lane matched but its activity could not be
    read" has a name. But `getmtime()` and `open()` were unguarded, so a file owned by another user,
    one rotated away between the glob and the open, or a DIRECTORY matching the glob raised straight
    out of `collect()` and `main()` — the process died with rc 1 and EMPTY stdout, i.e. the retired
    code on the one path the contract exists for. Measured: `IsADirectoryError` from `turns()`.

    The stub returns a path that is REAL and matches the shape `session_file()` returns, but is a
    directory — so the failure is the production one, not a stub artefact.
    """
    lw = _load()
    vanished = tmp_path / "sid-abc12345.jsonl"
    vanished.mkdir()                      # a DIRECTORY, as `turns()`'s `open()` would find it
    monkeypatch.setattr(lw, "lane_rows",
                        lambda: [{"ws": "WS1", "lane": "L1", "sid": "sid-abc12345",
                                  "verdict": "WORKING"}])
    monkeypatch.setattr(lw, "session_file", lambda sid: str(vanished))
    rc, p = lw.collect("WS1")
    assert rc == 3, "an unreadable session file is UNMEASURED (3), never the retired rc 1: %r" % (rc,)
    assert "UNMEASURED(" in (p.get("unmeasured") or ""), p.get("unmeasured")
    assert "unreadable" in p["unmeasured"], p["unmeasured"]

    # …and the same for a file that VANISHED between the glob and the read.
    monkeypatch.setattr(lw, "session_file", lambda sid: str(tmp_path / "gone.jsonl"))
    rc, p = lw.collect("WS1")
    assert rc == 3 and "UNMEASURED(" in (p.get("unmeasured") or ""), (rc, p)


def test_a_bad_chars_or_turns_value_is_a_usage_error_not_a_traceback(monkeypatch):
    """⛔ `int()` RAISES `ValueError`, WHICH NOTHING CAUGHT: rc 1 with empty stdout from a caller typo.

    The contract assigns 2 to "usage", and 1 is the code it retires. `--chars --json` is included
    because the flag is consumed as the VALUE there, which is the shape a caller hits by accident.
    """
    lw = _load()
    for argv in (["lane-wip.py", "WS1", "--chars", "abc"],
                 ["lane-wip.py", "WS1", "--turns", "x"],
                 ["lane-wip.py", "WS1", "--chars", "--json"]):
        monkeypatch.setattr(lw.sys, "argv", argv)
        assert lw.main() == 2, argv


def test_a_json_line_that_is_not_an_object_is_skipped_not_a_crash(monkeypatch, tmp_path):
    """⛔ `null`, `5`, `[]` and `"x"` PARSE, then raise `AttributeError` from `.get()`.

    That is not an `OSError`, so it slipped past both this function's own "tolerate an unparseable
    line" stance and `collect()`'s guard, and killed the process with rc 1 and empty stdout — the
    retired code again, on a session file that is merely unusual rather than unreadable.
    """
    lw = _load()
    f = tmp_path / "sid-abc12345.jsonl"
    f.write_text('null\n5\n[]\n"text"\n{"message": {"role": "assistant", "content": "hi"}}\n')
    monkeypatch.setattr(lw, "lane_rows",
                        lambda: [{"ws": "WS1", "lane": "L1", "sid": "sid-abc12345",
                                  "verdict": "WORKING"}])
    monkeypatch.setattr(lw, "session_file", lambda sid: str(f))
    rc, p = lw.collect("WS1")
    assert rc == 0, (rc, p)
    assert p["turns"] == ["hi"], p["turns"]


def test_a_text_block_whose_text_is_not_a_string_is_not_a_crash(monkeypatch, tmp_path):
    """⛔ `{"type": "text", "text": null}` RAISES `TypeError` OUT OF THE JOIN, not an `OSError`.

    `" ".join(...)` requires `str`; a `null` or numeric `text` (which a compaction or a provider can
    emit) is `TypeError: sequence item 0: expected str instance, NoneType/in found` — so it escaped
    `collect()`'s `except OSError` and the process exited 1 with empty stdout: the retired code again,
    on a session file that is merely unusual. Measured with `scripts/lane-wip.py WS1 --json`.
    """
    lw = _load()
    f = tmp_path / "sid-abc12345.jsonl"
    f.write_text('{"message": {"role": "assistant", "content": '
                 '[{"type": "text", "text": null}, {"type": "text", "text": 5}, '
                 '{"type": "text", "text": "real"}]}}\n')
    monkeypatch.setattr(lw, "lane_rows",
                        lambda: [{"ws": "WS1", "lane": "L1", "sid": "sid-abc12345",
                                  "verdict": "WORKING"}])
    monkeypatch.setattr(lw, "session_file", lambda sid: str(f))
    rc, p = lw.collect("WS1")
    assert rc == 0, (rc, p)
    assert p["turns"] == ["5 real"], p["turns"]


def test_a_lane_row_that_is_not_an_object_is_skipped(monkeypatch):
    """⛔ `lane_rows()` ONLY CHECKS THAT THE PAYLOAD IS A LIST, so `null` / `"WS1"` / `[]` elements
    reach the row scan and `.get()` raises `AttributeError` — the same non-OSError escape the
    line-level guard closes one layer down. A row that is not an object cannot match a lane."""
    lw = _load()
    monkeypatch.setattr(lw, "lane_rows",
                        lambda: [None, "WS1", [], {"ws": "WS1", "lane": "L1", "sid": "sid-x",
                                                     "verdict": "WORKING"}])
    monkeypatch.setattr(lw, "session_file", lambda sid: None)
    rc, p = lw.collect("WS1")
    assert rc == 3, "the dict row matched and had no session file, so rc 3 (not a crash): %r" % (rc,)
    assert "UNMEASURED(" in (p.get("unmeasured") or ""), p


def test_a_session_file_that_vanishes_during_the_glob_is_not_found(monkeypatch):
    """⛔ `session_file()`'s `max(..., key=getmtime)` RACES THE FILE IT JUST GLOBBED.

    A rotated or removed session file raises `FileNotFoundError` INSIDE that call — one call BEFORE
    `collect()`'s guard — so it escaped to rc 1 as well. A hit that is no longer stat-able is "no
    session file", which the caller already answers with rc 3.
    """
    lw = _load()
    monkeypatch.setattr(lw.glob, "glob", lambda pat: ["/tmp/vanished-sid-abc.jsonl"])

    def boom(p):
        raise FileNotFoundError(2, "No such file", p)

    monkeypatch.setattr(lw.os.path, "getmtime", boom)
    assert lw.session_file("sid-abc") is None
