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

print(f"── landability.test.sh: {ok} assertions passed ──")
PY
