#!/usr/bin/env bash
# scripts/landing/landability.test.sh — the regression pin for scripts/landing/landability.py.
#
# WHY THIS EXISTS (P2, fresh review of #1550). The module shipped with "the runs above are the
# verification" — but two of the four defects a fresh review found were PURE-FUNCTION defects that
# a handful of synthetic inputs would have caught, and the runs exercised only the live-API path:
#
#   1. `check_state`'s name sets mixed `None` (an unnamed run, which `newest_per_app_and_name`
#      deliberately supports) with a str, and `sorted()` raised TypeError — a crash in the one tool
#      a merge-duty lane runs to decide whether it may land.
#   2. `parse_ndjson` silently dropped a line it could not parse, so a truncated check surface lost
#      that run; if the dropped line was the only red, the verdict fell through to `AT` — a false
#      "checks clear".
#   3. `merge_base_of` returned "" on a failed read and the caller turned it into a REPOINT,
#      inviting a re-review of content that had not moved.
#   4. `record_binding` reported `diff-changed` for a diff it never measured (a draft/not-open PR).
#
# Every assertion below is about an OBSERVABLE: the returned value, or the named failure raised.
# Nothing here needs the network, a checkout, or `gh`.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON="${PYTHON:-python3}"

if ! command -v "$PYTHON" >/dev/null 2>&1; then
  echo "⚠ landability.test.sh: no $PYTHON — cannot run (this is a NAMED skip, not a pass)" >&2
  exit 2
fi

"$PYTHON" - "$DIR/landability.py" <<'PY'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("landability", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

ok = 0


def ck(cond, label, detail=""):
    global ok
    if cond:
        ok += 1
        print(f"  ✅ {label}")
    else:
        print(f"  ❌ {label}{(' — ' + str(detail)) if detail else ''}")
        raise SystemExit(1)


# (1) an UNNAMED run beside a named one is a supported shape, not a crash
runs = [
    {"id": 2, "name": None, "status": "in_progress", "conclusion": None, "app": {"slug": "gh"}},
    {"id": 1, "name": "build", "status": "in_progress", "conclusion": None, "app": {"slug": "gh"}},
]
try:
    _g, in_flight, failed, untested, not_tested = m.check_state(runs)
    ck("build" in in_flight, "check_state: a named in-flight run is reported", in_flight)
    ck(
        any(s.startswith("<unnamed:") for s in in_flight),
        "check_state: an UNNAMED in-flight run is attributable, not a TypeError",
        in_flight,
    )
except TypeError as exc:  # the exact defect this pins
    ck(False, "check_state: unnamed + named runs must not raise", exc)

# (2) a line we cannot read is an ABSTENTION, never an absent check
for bad in ('{"id":1}\nnot json\n', "null\n", '{"id":1}\n"x"\n'):
    try:
        m.parse_ndjson(bad)
    except m.Failure:
        ck(True, f"parse_ndjson: {bad.splitlines()[-1]!r} raises a NAMED failure")
    else:
        ck(False, f"parse_ndjson: {bad.splitlines()[-1]!r} was silently dropped")
ck(m.parse_ndjson('{"id":1}\n\n{"id":2}\n') == [{"id": 1}, {"id": 2}],
   "parse_ndjson: well-formed lines (and a blank one) still parse")

# (1b) EVERY name set, not just in_flight: `not_tested` (neutral/skipped) and `untested`
# (cancelled/stale) are separate sets, and a partial fix left the same TypeError in one of them
# (caught by VGATE on this change). One unnamed + one named run per conclusion class.
for concl in ("in_progress", "skipped", "cancelled", "neutral", "failure"):
    runs = [
        {"id": 2, "name": None, "status": "completed" if concl != "in_progress" else "in_progress",
         "conclusion": None if concl == "in_progress" else concl, "app": {"slug": "gh"}},
        {"id": 1, "name": "build", "status": "completed" if concl != "in_progress" else "in_progress",
         "conclusion": None if concl == "in_progress" else concl, "app": {"slug": "gh"}},
    ]
    try:
        res = m.check_state(runs)
    except TypeError as exc:
        ck(False, f"check_state: unnamed+named {concl} run must not raise", exc)
    # ⛔ THE ASSERTION CONSUMES THE RESULT (P2, fresh review): an unconditional `ck(True, …)` is a
    # no-op that cannot fail, so it would keep ticking if the call above were dropped in a refactor
    # — and it was 5 of the 17 assertions quoted as evidence of coverage. Shape-check the tuple.
    ck(
        len(res) == 5
        and all(isinstance(x, list) for x in res)
        and any(str(n).startswith("<unnamed:") for n in (res[1] + res[2] + res[3] + res[4])),
        f"check_state: unnamed+named {concl} runs are attributable in every name set",
        res,
    )

# (3) an unreadable merge base RAISES; it is never reported as a repoint
real = m.gh_text
m.gh_text = lambda argv, d: (1, "", "HTTP 502 from the API")
try:
    m.merge_base_of("o/r", "main", "a" * 40, ".")
except m.Failure as exc:
    ck("could not read the merge base" in str(exc),
       "merge_base_of: an unreadable read names the read it could not take", exc)
else:
    ck(False, "merge_base_of: an unreadable read must not answer ''")
finally:
    m.gh_text = real
m.gh_text = lambda argv, d: (0, "f" * 40 + "\n", "")
ck(m.merge_base_of("o/r", "main", "a" * 40, ".") == "f" * 40,
   "merge_base_of: a successful read returns the sha")
m.gh_text = real

# (4) an UNMEASURED diff is not a changed diff
rec = {"verdict": "clean", "head_sha": "a" * 40, "diff_sha256": "b" * 64}
ck(m.record_binding(rec, "c" * 40, "") == "NEEDS-REVIEW(diff-unmeasured)",
   "record_binding: a diff that was never measured is a NAMED abstention")
ck(m.record_binding(rec, "c" * 40, "b" * 64) == "CARRY",
   "record_binding: a byte-identical diff still carries")
ck(m.record_binding(rec, "c" * 40, "d" * 64) == "NEEDS-REVIEW(diff-changed)",
   "record_binding: a genuinely different diff still reads changed")
ck(m.record_binding(rec, "a" * 40, "") == "AT",
   "record_binding: a head match is AT without needing the diff")

# (5) a record that parses to a NON-OBJECT is an abstention, never a traceback (P2, fresh review):
# `main()` catches only Failure, and bulk.py catches only Failure too, so an AttributeError here
# aborted a whole batch. Exercised through read_record() with a real file in a temp HOME.
import tempfile, os, json as _json
_tmp = tempfile.mkdtemp()
os.makedirs(os.path.join(_tmp, ".pi", "agent", "reviews"), exist_ok=True)
with open(os.path.join(_tmp, ".pi", "agent", "reviews", "1.json"), "w") as _fh:
    _json.dump([], _fh)          # array-shaped legacy record: parses, but is not an object
_old_home = os.environ.get("HOME")
os.environ["HOME"] = _tmp
try:
    rec, path = m.read_record("daniel-ospina/agent-infra", 1)
    ck(rec is None and path is not None,
       "read_record: a non-object record is an ABSTENTION (never a crash)", (rec, path))
    ck(m.record_binding(rec, "c" * 40, "b" * 64) == "NEEDS-REVIEW(no-record)",
       "record_binding: an unreadable record reads as no-record, not an AttributeError")
finally:
    if _old_home is None:
        os.environ.pop("HOME", None)
    else:
        os.environ["HOME"] = _old_home

# (5b) the record's FIELDS are coerced, not trusted (P2, fresh review): a hand-edited legacy record
# with a non-string head_sha / diff_sha256 must abstain, never raise AttributeError (which main()
# does not catch, so bulk.py aborted a whole batch).
ck(m.record_binding({"verdict": "clean", "head_sha": 12345, "diff_sha256": "b" * 64},
                    "a" * 40, "b" * 64) == "CARRY",
   "record_binding: a non-string head_sha does not crash, and does not match the head")
ck(m.record_binding({"verdict": "clean", "head_sha": "c" * 40, "diff_sha256": 999},
                    "a" * 40, "b" * 64) == "NEEDS-REVIEW(no-diff-identity)",
   "record_binding: a non-string digest is an abstention (at a non-matching head)")
# (5c) the PRINTER is the last unguarded read of the same field class (P1, fresh review):
# `report()` sliced `head_sha` directly, so the record blessed by the assertion above computed a
# correct CARRY verdict and then raised TypeError — exit 1 with a traceback, on the tool a
# merge-duty lane runs to decide whether it may land. Printing must not be able to crash.
_res = {"pr": "1", "repo": "o/r", "state": "OPEN", "draft": False, "head": "a" * 40,
        "branch": "b", "base": "main", "mergeable": "MERGEABLE", "merge_state": "CLEAN",
        "record": {"verdict": "clean", "head_sha": 12345, "diff_sha256": 999,
                   "merge_base_sha": {"not": "a string"}, "reviewed_at": "t"},
        "record_file": "/x/1.json", "live_diff": "b" * 64, "checks_total": 1,
        "in_flight": [], "failed": [], "untested": [], "not_tested": [],
        "base_repointed": False, "binding": "CARRY", "verdict": "CARRY"}
import io, contextlib
_buf = io.StringIO()
try:
    with contextlib.redirect_stdout(_buf):
        m.report(_res)
    ck("record: verdict=clean" in _buf.getvalue(),
       "report(): a non-string record field is coerced, not sliced", _buf.getvalue()[:120])
except Exception as exc:
    ck(False, "report(): a non-string record field must not crash", f"{type(exc).__name__}: {exc}")

# (6) `check()`'s PRECEDENCE LADDER — the fail-open guard the tool actually runs (P2, fresh review):
# `elif not runs: BLOCKED(checks-unmeasured)` is the only arm that stops an EMPTY check surface from
# falling through to the record binding, i.e. to `AT` on a head nobody tested. It was unpinned: a
# reorder that dropped it left every assertion green. These stub the read layer, so no network.
import types

PR = {"state": "OPEN", "isDraft": False, "headRefOid": "a" * 40, "baseRefName": "main",
      "mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN", "headRefName": "b"}
_rec = {"verdict": "clean", "head_sha": "a" * 40, "diff_sha256": "b" * 64}

def run_check(*, pr=None, runs="", diff=b"diff --git a/x b/x\n+1\n", record=_rec, bytes_rc=0,
              merge_base=None):
    saved = (m.gh_text, m.gh_bytes, m.read_record, m.normalize)
    prj = dict(PR, **(pr or {}))

    def _gh_text(argv, d):
        if argv[:2] == ["pr", "view"]:
            return (0, __import__("json").dumps(prj), "")
        # `merge_base_of` reads `compare/<base>...<head>`; without this arm the stub below would
        # hand it the CHECK-RUN surface and the two reads would be indistinguishable (P2, fresh
        # review: the base-repointed arm of the ladder was unpinnable for exactly that reason).
        if merge_base is not None and any("compare/" in str(x) for x in argv):
            return (0, merge_base + "\n", "")
        return (0, runs, "")

    m.gh_text = _gh_text
    m.gh_bytes = lambda argv, d: types.SimpleNamespace(returncode=bytes_rc, stdout=diff, stderr=b"")
    m.read_record = lambda repo, n: (record, "/home/x/.pi/agent/reviews/1.json")
    m.normalize = lambda raw, n: raw
    try:
        return m.check(1, "o/r", ".", "/fake/diff-normalize.py")
    finally:
        m.gh_text, m.gh_bytes, m.read_record, m.normalize = saved

# an EMPTY check surface must never read as clean, even with a matching record and a matching diff
r = run_check(runs="")
ck(r["verdict"] == "BLOCKED(checks-unmeasured)",
   "check(): an EMPTY check surface is BLOCKED(checks-unmeasured), never AT", r["verdict"])
# a RED check outranks an in-flight one, and both are named
r = run_check(runs='{"id":1,"name":"t","status":"completed","conclusion":"failure"}\n'
                    '{"id":2,"name":"u","status":"in_progress","conclusion":null}\n')
ck(r["verdict"].startswith("BLOCKED(checks-failed)"), "check(): a failed check outranks in-flight", r["verdict"])
ck(r["failed"] == ["t"] and r["in_flight"] == ["u"],
   "check(): the failed and in-flight sets are both reported", (r["failed"], r["in_flight"]))
# DRAFT outranks a conflict, and a conflict outranks a clean surface
r = run_check(pr={"isDraft": True, "mergeable": "CONFLICTING", "mergeStateStatus": "DIRTY"})
ck(r["verdict"] == "BLOCKED(draft)", "check(): draft outranks merge-conflict", r["verdict"])
r = run_check(pr={"mergeable": "CONFLICTING", "mergeStateStatus": "DIRTY"})
ck(r["verdict"] == "BLOCKED(merge-conflict)", "check(): a conflict blocks", r["verdict"])

# ⛔ THE THREE UNPINNED LADDER ARMS (P2, fresh review). The four cases above leave `untested`,
# `not-tested` and `base-repointed` unconstrained: a regression that moved the `untested` arm BELOW
# the record binding would report a head whose newest attempt is `cancelled` as `AT`/`CARRY` — a
# false clear, the class this file exists to defend — with every assertion above still green.
# (a) `cancelled`/`stale` ran but exercised nothing → BLOCKED, never a clear
r = run_check(runs='{"id":1,"name":"t","status":"completed","conclusion":"cancelled"}\n')
ck(r["verdict"] == "BLOCKED(checks-untested)",
   "check(): a cancelled head is BLOCKED(checks-untested), never AT", r["verdict"])
# (b) `skipped`/`neutral` are green for TREE HEALTH and credit nothing in the rail's vocabulary —
# deliberately NOT a blocking reason (blocking on them would refuse every PR, not the vacuous ones).
r = run_check(runs='{"id":1,"name":"t","status":"completed","conclusion":"skipped"}\n')
ck(r["verdict"] == "AT",
   "check(): a skipped job does NOT block a head-bound record", r["verdict"])
# (c) a base repoint leaves every head-bound check green while the certified diff is not the diff
# that would merge, so it must outrank the (empty) check surface.
r = run_check(
    runs="",
    record={"verdict": "clean", "head_sha": "a" * 40, "diff_sha256": "b" * 64,
            "merge_base_sha": "e" * 40},
    merge_base="f" * 40,
)
ck(r["verdict"] == "BLOCKED(base-repointed)",
   "check(): base-repointed outranks checks-unmeasured", r["verdict"])
# a 2xx body that is NOT a diff must not be hashed and reported as "changed"
try:
    run_check(diff=b'{"message":"Not Found"}')
except m.Failure as exc:
    ck("no diff entry boundary" in str(exc),
       "check(): a 2xx NON-DIFF body is a NAMED failure, never diff-changed", exc)
else:
    ck(False, "check(): a 2xx non-diff body was hashed as content")

print(f"── landability.test.sh: {ok} assertions passed ──")
PY
