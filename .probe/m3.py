import sys
p = ".probe/mut/beta-progress.py"
s = open(p).read()
old = """    rest_deadline = time.time() + REST_BUDGET_S
    if _PHASE_DEADLINE is not None:
        # ⛔ THE REST BUDGET IS A CHILD OF THE PHASE CLOCK, not a peer of it: a slow `gh` read has
        # already spent part of the phase, and REST may not spend that part a second time.
        rest_deadline = min(rest_deadline, _PHASE_DEADLINE)
"""
assert old in s
s = s.replace(old, "    rest_deadline = time.time() + REST_BUDGET_S\n")
open(p, "w").write(s)
