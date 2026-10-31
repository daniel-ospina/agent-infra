#!/usr/bin/env python3
"""Which `brief-gate.sh` copy renders the research contract, and does the gate ADMIT it?

WHY THIS PROBE EXISTS (agent-infra#2708, measured 2026-10-27). The capability is "the contract a
worker brief carries is the contract the gate enforces", and its inertness is invisible: a stale
`$O/brief-gate.sh` renders a stale section, the SAME stale copy validates it, the brief is admitted,
a worker starts, and nothing anywhere says the contract was nine hours old. Two of the three
measured stalls were exactly this, and the second showed the other half of the blindness -- the fix
went to the FARM (`~/.pi/agent/scripts/`) and never reached the copy the driver resolves first, with
no line in any pass saying which copy had rendered it.

So the probe reports the two things a reader of ONE pass could not previously know:

  * the BRIEF the shipped `brief()` would write (so a test can grade it with the gate that will
    actually judge it, instead of trusting the copy that produced it), and
  * the log lines naming WHICH copy rendered the contract (provenance, not inference from the
    deploy scripts).

It drives the SHIPPED file -- nothing is re-implemented here -- and it is inert: `brief()` renders
text and never dispatches.

Usage:  probe_brief_contract.py <pr-doctor.py> <orch-dir> <pr-number>
Env:    HOME is whatever the caller set (the suite gives it a private one); `O` is ignored, the
        module's `ORCH_DIR` is pointed at <orch-dir> AFTER import so no ambient `$O` can answer.
"""
import importlib.util
import os
import sys

doctor_path, orch_dir, number = sys.argv[1], sys.argv[2], int(sys.argv[3])

spec = importlib.util.spec_from_file_location("pr_doctor_probe", doctor_path)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

# AFTER import, on purpose: `ORCH_DIR` is a module global resolved at import time, and the point of
# this probe is to choose the `$O` the shipped ladder sees without also choosing it for the import.
mod.ORCH_DIR = orch_dir
logs = []
mod.log = logs.append

prd = {"number": number, "title": "probe the contract", "isDraft": False,
       "headRefOid": "a" * 40, "headRefName": "fix/probe", "mergeStateStatus": "CLEAN",
       "isCrossRepository": False, "files": []}

text = mod.brief(prd, "fix-ci", "python-ci-gate", None)
sys.stdout.write("---BRIEF---\n%s\n---LOG---\n%s\n" % (text, "\n".join(logs)))
