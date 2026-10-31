#!/usr/bin/env python3
"""check-class.py — THE check-surface classifier of the orchestrator harness.

ONE IMPLEMENTATION, TWO CALLERS. This file was extracted verbatim from the `python3 -c` heredoc in
`orch-loop.sh`'s sweep (the `V=` pipeline) so that the cycle's classification and the NOCHECKS arm's
re-read cannot drift apart. A second copy of these rules is how the harness and the merge rail
disagreed before (#1714); the arm exists precisely to replace a non-answer with THIS answer, so it
must be this file's answer and not a lookalike.

  stdin   the check rows, in EITHER shape the harness sees:
            * the flat list `gh pr checks --json name,state,workflow` prints, or
            * the check-runs API shape (an object carrying a `check_runs` list) — what the REST
              adapter and `/commits/<sha>/check-runs` return.
  env     REQ          space-separated required check names (branch protection), may be empty
          REVIEW_GATE  the repo's review-gate check name (default `ai-review-gate`)
  stdout  ONE token: `GREEN` | `PENDING:<names>` | `FAILED:<names>` | `NOCHECKS`

`NOCHECKS` means "this read produced no check rows" — an EMPTY surface, or an unreadable one. It is
NOT a pass and NOT a pending: this TOKEN reaches neither the merge arm nor the fixer arm. The NOCHECKS arm
(`nochk-resolve.py`) is what turns that non-answer into a named verdict — and ITS answer is what may reach
an acting arm (`RECOVERED:GREEN` merges, `RECOVERED:FAILED:*` reaches the fixer), so a merge after a
NOCHECKS rests on that second read at the live head, never on the empty one that produced this token.
Every `NOCHECKS`-producing path in this file must keep printing it: an empty stdout from this file is
READ as a read failure by the caller (#3110), not as a class.
"""
import json
import os
import sys


def main() -> int:
    try:
        d = json.load(sys.stdin)
    except Exception:
        print('NOCHECKS')
        return 0
    # The source is either the check-runs API shape (an object carrying a check_runs list) or the flat
    # list `gh pr checks --json` prints. Both normalise to one row list; anything else is unreadable.
    rows = d.get('check_runs') if isinstance(d, dict) else d
    if not isinstance(rows, list):
        print('NOCHECKS')
        return 0
    # ⛔ SPELLED EXACTLY AS THE SHIPPED RULE (agent-infra#2719): test-gates.sh pins this line as the
    # classifier's split rule, and _normalise_set shares it — a whitespace change here is drift the pin
    # is meant to see, so the extraction keeps the original spelling rather than reformatting it.
    want=(os.environ.get('REQ') or '').split()
    # ⛔ ALLOW-LISTS, NEVER A DENY-LIST (agent-infra#1714). A conclusion is NON-RED only if it is NAMED
    # here - the identical five spellings admin-merge.sh (NON_RED_CONC) and record-review.sh
    # (target_head_red) use, so the harness and the merge rail cannot disagree. 'not in the red set' is
    # not a synonym for non-red: a token this code has never seen (a vendor adds a conclusion, GitHub
    # returns a newer spelling, the value is null) must FAIL CLOSED, so it is RED. The deny-list this
    # replaced named the red tokens and filed EVERYTHING ELSE as PENDING, so an unrecognised or NULL
    # conclusion reached `gh pr merge --auto` instead of blocking - the fail-open the issue is about.
    NONRED = ('success', 'neutral', 'skipped', 'cancelled', 'stale')
    # IN FLIGHT means a status the API NAMES as in flight - the same five the rail uses. Any OTHER
    # non-completed spelling is judged by its CONCLUSION under the allow-list, so an unrecognised status
    # with a null conclusion is RED, not pending (the rail's #1353 fail-open shape, closed the same
    # way). `expected` is deliberately NOT here: it is not a named in-flight spelling, so a check
    # GitHub has announced but not reported reads RED - the fail-closed direction, matching the rule.
    INFLIGHT = ('queued', 'in_progress', 'waiting', 'requested', 'pending')
    # One entry per (app, name) - NOT per name: a same-named check under two apps must not let one
    # app's result mask the other's (agent-infra#1714). `app.slug` when the source supplies it (the
    # check-runs API), otherwise the workflow name (`gh pr checks` exposes no app field), and the
    # NEWEST attempt by id when the source supplies one. Ties, and sources with no id at all, take the
    # last row seen - all the information `gh pr checks` carries.
    groups = {}
    for c in rows:
        if not isinstance(c, dict):
            continue
        name = str(c.get('name') or '')
        app = c.get('app')
        if isinstance(app, dict):
            app = app.get('slug') or ''
        if not app:
            app = c.get('workflow') or ''
        try:
            cid = int(c.get('id') or c.get('databaseId') or 0)
        except Exception:
            cid = 0
        if 'status' in c or 'conclusion' in c:
            status = str(c.get('status') or '').lower()
            concl = str(c.get('conclusion') or '').lower()
        else:
            st = str(c.get('state') or '').lower()
            status, concl = (st, '') if st in INFLIGHT else ('completed', st)
        k = (str(app), name)
        prev = groups.get(k)
        if prev is None or cid >= prev[0]:
            groups[k] = (cid, status, concl)
    rank = {'nonred': 0, 'pending': 1, 'red': 2}
    # The repo's review-gate NAME is an INPUT (agent-infra#1764), not the literal 'ai-review-gate'.
    # It is read from the env the bash side passes in, with the same default repo-authority.sh uses.
    rgate = os.environ.get('REVIEW_GATE') or 'ai-review-gate'
    named = {}
    gate = []
    for k in groups:
        status = groups[k][1]
        concl = groups[k][2]
        v = 'pending' if status in INFLIGHT else ('nonred' if concl in NONRED else 'red')
        if k[1] == rgate:
            gate.append((v, concl))
        if k[1] not in named or rank[v] > rank[named[k[1]]]:
            named[k[1]] = v
    # THE REVIEW GATE IS THE MERGE AUTHORITY **WHERE THE REPO REQUIRES IT**, so it must be an explicit
    # SUCCESS there. SKIPPED/NEUTRAL means no signed review exists; reading that as satisfied would
    # merge without evidence. This is also why GREEN always carries at least one MEASURING success: a
    # surface of nothing but cancelled/stale/skipped/neutral rows can never read green - those are
    # non-red, never green.
    # ⛔ SCOPED BY 'rgate in want', WHICH IS THE WHOLE POINT (#1764). On a repo whose protection does
    # not require the gate (agent-infra), the name is NOT in 'want' and the rule below never fires -
    # otherwise its ABSENCE forced RED and deadlocked the queue. The rule is NOT weakened: on tortoise
    # the gate IS required, so a missing/red/skipped gate still blocks exactly as before. The
    # fail-closed posture is unchanged and stays INSIDE the repo's own required set.
    gate_ok = len(gate) > 0 and all(v == 'nonred' and c == 'success' for v, c in gate)
    # Read it in this order: RED if any required check is red (a completed red is final - nothing in
    # flight can un-fail it); otherwise NOT YET KNOWN while any is in flight or never reported;
    # otherwise GREEN. An EMPTY surface is NOCHECKS, never GREEN - a missing check is not a green check,
    # and NOCHECKS reaches neither the merge nor the fixer arm below.
    fail = [n for n in want if named.get(n) == 'red']
    pend = [n for n in want if named.get(n) == 'pending' or n not in named]
    if rgate in want and not gate_ok and rgate not in fail:
        fail.insert(0, rgate)
    print('NOCHECKS' if not groups else ('FAILED:' + ','.join(fail) if fail else (
        'PENDING:' + ','.join(pend) if pend else ('GREEN' if want else 'NOCHECKS'))))
    return 0


if __name__ == '__main__':
    sys.exit(main())
