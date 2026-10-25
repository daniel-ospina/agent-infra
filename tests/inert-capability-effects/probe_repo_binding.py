#!/usr/bin/env python3
"""tests/inert-capability-effects/probe_repo_binding.py — §1 of the inert-capability suite (#2708).

Prints WHICH repo the shipped `pr-loop.py`'s classifier would grade, driving the SAME `_objective()`
its `main()` calls. It asks a question about an EFFECT (which repo is graded), never about how the
value was derived, so the assertion survives any refactor that keeps the effect.

    probe_repo_binding.py <path-to-pr-loop.py>

Output, one line, never a traceback:
    REPO:<owner/name>     the classifier would grade this repo
    REFUSED:<reason>      the shipped code declined to guess (the fail-closed answer)
    ERROR:<Type>:<msg>    it did neither — neither an answer nor a named refusal
"""

import importlib.util
import sys


def main(argv):
    if len(argv) < 2:
        print("ERROR:usage:probe_repo_binding.py <pr-loop.py>")
        return 4
    spec = importlib.util.spec_from_file_location("pr_loop_under_test", argv[1])
    mod = importlib.util.module_from_spec(spec)
    try:
        spec.loader.exec_module(mod)
        objective = mod._objective()
    except SystemExit as exc:
        print("REFUSED:%s" % (exc.code if exc.code is not None else ""))
        return 3
    except Exception as exc:                     # noqa: BLE001 - reported, never a pass
        print("ERROR:%s:%s" % (type(exc).__name__, exc))
        return 4
    print("REPO:%s" % getattr(objective, "REPO", "<absent>"))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
