#!/usr/bin/env python3
"""undelivered-answers — which owner answers never reached a lane?

READ-ONLY. This script makes no writes: only `gh issue list/view` and `gh api`
GETs. It exists because every failure of the question-gate's delivery path is
SILENT by construction — an answer that never reached a lane appears nowhere,
so the owner cannot see it and the heartbeat's ask/pass/bounce/answered counts
cannot show it. Measured 2026-09-26: five lanes were stranded behind replies the
owner had already written, and nothing anywhere said so.

The delivery predicate lives in ask-owner.py::scan(). An answer is delivered only
when ALL of these hold:
  1. the issue carries NONE OF  owner-decision / question-bounced / answer-delivered
  2. it has a comment starting with `RESEARCH:` (the declaration)
  3. it has an `unlabeled owner-decision` timeline event newer than that declaration,
     AND (agent-infra#1903) the issue does NOT carry `question-bounced` — a bounce
     writes that same removal, and a bounced question is out of the owner's queue,
     so a removal while the bounce label is present is NOT an answer. Same rule as
     ask-owner.py::owner_answered_at (one definition, two readers)
  4. it carries a `lane:` label, or the relay reports NO LANE ROUTE for it
This script reports, per answered issue, which of those is missing.

Usage:
    python3 undelivered-answers.py            # human table
    python3 undelivered-answers.py --json     # machine

Last line is always machine-readable: `UNDELIVERED count=N answered=M`.
"""
import json
import os
import subprocess

# ⛔ THE LAYER MUST NOT SLEEP INSIDE THIS PROCESS (#1988). This script is run by the heartbeat under
# `run_bounded`, so it has a subprocess bound of its own (90 s) while the layer's first documented
# backoff is 60 s: an in-call wait would outlive the caller and the box would report an unreadable
# surface instead of the RATE-LIMITED verdict it can prove. NO_WAIT makes the layer record the limit
# and return at once, so this process's own deferral takes over. Applies to CHILDREN only.
os.environ.setdefault("GH_LIMIT_NO_WAIT", "1")

import sys

REPOS = ["daniel-ospina/tortoise", "daniel-ospina/premise-labs",
         "daniel-ospina/agent-infra"]

# Scope note: `--state open`, matching ask-owner.py::scan(). A closed issue is not
# a candidate for that scan either, so a closed-but-undelivered answer is out of
# scope BY PARITY, not by oversight — flagging it here would report a failure that
# the delivery path could never have prevented. (Measured 2026-09-26: the only
# CLOSED issue carrying `owner-answered` was agent-infra #1475, a deliberate test
# issue titled "TEST — ask-owner gate handshake (close me; not real work)".)

ANSWERED = "owner-answered"      # human-facing: "the owner replied"
DELIVERED = "answer-delivered"   # written ONLY by ask-owner.py
QUEUE = "owner-decision"         # "a decision is still owed"
BOUNCED = "question-bounced"     # gate sent it back; the lane must clear it


# ⛔ EVERY gh CALL MUST REACH THE LIMIT LAYER (#1988). These tools are the heartbeat's children, and
# `heartbeat-loop.sh` pins a PATH (`~/bin`, `~/.pi/agent/shims`, `/opt/homebrew/bin`) in which the
# real gh OUTRANKS the seeded shims — so a bare `"gh"` here is unserialised and un-backed-off against
# the account four boxes share. The layer's path comes from `$O`, never from PATH, so the caller's
# PATH cannot defeat it; with no `$O` the bare name keeps the old behaviour.
def _gh_layer():
    o = os.environ.get("O", "")
    if not o:
        return None
    for c in (os.path.join(o, "gh-rest", "gh"), os.path.join(o, "gh-limit", "gh")):
        if os.path.isfile(c) and os.access(c, os.X_OK):
            return c
    return None


GH = _gh_layer() or "gh"


def sh(args):
    try:
        p = subprocess.run(args, capture_output=True, text=True, timeout=90)
        return p.returncode, p.stdout, p.stderr
    except Exception as e:                                   # noqa: BLE001
        return 1, "", str(e)


def answered_issues(repo):
    rc, out, err = sh([GH, "issue", "list", "--repo", repo, "--state", "open",
                       "--label", ANSWERED, "--limit", "100",
                       "--json", "number,title,state,labels,updatedAt"])
    if rc != 0:
        # A failed read must never look like "nothing to report".
        print("  SCAN FAILED %s rc=%d :: %s" % (repo, rc, err.strip()[:160]),
              file=sys.stderr)
        return None
    return json.loads(out or "[]")


def declaration_count(repo, n):
    rc, out, _ = sh([GH, "issue", "view", str(n), "--repo", repo,
                     "--json", "comments",
                     "--jq", '[.comments[].body|select(test("^ *RESEARCH:"))]|length'])
    return int(out.strip()) if rc == 0 and out.strip().isdigit() else None


def unlabeled_event_count(repo, n):
    """Count `unlabeled owner-decision` events ACROSS ALL PAGES, EXCLUDING the
    gate's own bounce removal.

    ⛔ The timeline endpoint returns the **FIRST page** by default, so a bare
    call shows the OLDEST events and silently misses the most recent ones — which
    is exactly where a removal lives. Measured 2026-09-26: the unpaginated form
    reported *"no `unlabeled owner-decision` event (removal never happened)"* for
    **#1026**, while the event sits at `2026-09-26T12:57:19Z` (verified: every
    "labeled" and "unlabeled" event for that label, newest last).

    ⛔ Do **not** use `|length` here: under `--paginate`, `--jq` runs **per page**,
    so `|length` emits one number PER PAGE and the caller cannot sum them (it
    would fall into the `None`/UNVERIFIED branch and silently disarm this check).
    Emitting one line per matching event and counting lines is pagination-safe.

    ⛔ THE GATE WRITES THIS EVENT TOO (agent-infra#1903): a bounce removes
    `owner-decision`. This count is the RAW event count (removals newer than the
    newest `labeled question-bounced` event) — `diagnose` applies the label-state
    rule on top, so a bounced question is never reported as "conditions satisfied
    — PENDING (clean)", i.e. as an answer that does not exist.
    """
    rc, out, _ = sh([GH, "api",
                     "repos/%s/issues/%d/timeline?per_page=100" % (repo, n),
                     "--paginate",
                     "--jq",
                     '.[]|select((.event=="unlabeled" and .label.name=="%s") '
                     'or (.event=="labeled" and .label.name=="%s"))'
                     r'|"\(.event)\t\(.created_at)"' % (QUEUE, BOUNCED)])
    if rc != 0:
        return None
    removed, bounced = [], []
    for ln in out.splitlines():
        if not ln.strip():
            continue
        ev, _, at = ln.partition("\t")
        if not at.strip():
            continue
        (removed if ev.strip() == "unlabeled" else bounced).append(at.strip())
    newest_bounce = max(bounced) if bounced else ""
    return len([at for at in removed if at > newest_bounce])


def diagnose(repo, issue):
    """Return (blockers, lanes) — what stops delivery, and who is waiting."""
    names = [l["name"] for l in issue["labels"]]
    lanes = [l for l in names if l.startswith("lane:")]
    blockers = []
    if DELIVERED in names:
        return ["DELIVERED"], lanes
    # condition 1 — the three exclusions
    if QUEUE in names:
        blockers.append("owner-decision kept (question still owed OR partial answer)")
    if BOUNCED in names:
        blockers.append("question-bounced left on (the lane must clear it)")
    # condition 2
    n_decl = declaration_count(repo, issue["number"])
    if n_decl == 0:
        blockers.append("no RESEARCH: declaration comment")
    elif n_decl is None:
        blockers.append("UNVERIFIED: could not read comments")
    # condition 3
    n_unl = unlabeled_event_count(repo, issue["number"])
    if n_unl is None:
        blockers.append("UNVERIFIED: could not read timeline")
    elif n_unl == 0:
        blockers.append("no `unlabeled owner-decision` event (removal never happened)")
    elif BOUNCED in names:
        # The gate's own bounce writes this removal (agent-infra#1903), so while
        # `question-bounced` is present it is not an owner answer — do NOT tell the
        # operator a removal "never happened" when one did, and do not pass this
        # off as "conditions satisfied".
        blockers.append("only `unlabeled owner-decision` events while "
                        "`question-bounced` is present — the gate's own bounce, "
                        "not an owner answer")
    # condition 4
    if not lanes:
        blockers.append("NO LANE ROUTE: no `lane:` label")
    if not blockers:
        # All conditions satisfied and steps 2-3 agree: this will deliver on the
        # next tick. Not a failure — say which one it is.
        blockers.append("PENDING (clean — delivers on a tick)")
    return blockers, lanes


def main():
    as_json = "--json" in sys.argv
    rows, scan_failed, answered = [], 0, 0
    for repo in REPOS:
        issues = answered_issues(repo)
        if issues is None:
            scan_failed += 1
            continue
        for it in issues:
            answered += 1
            blockers, lanes = diagnose(repo, it)
            rows.append(dict(repo=repo.split("/")[-1], number=it["number"],
                             state=it["state"], lanes=lanes, blockers=blockers,
                             title=it["title"][:70], updated=it["updatedAt"][:16]))
    undelivered = [r for r in rows if r["blockers"] != ["DELIVERED"]
                   and not r["blockers"][0].startswith("PENDING")]

    if as_json:
        print(json.dumps(dict(undelivered=undelivered, all=rows), indent=2))
    else:
        print("answered issues: %d across %d repos" % (answered, len(REPOS)))
        print()
        for r in rows:
            tag = "DELIVERED" if r["blockers"] == ["DELIVERED"] else (
                "pending" if r["blockers"][0].startswith("PENDING") else "RELAY-NO")
            print("  %-8s %s#%-5s %-9s lanes=%s" % (
                tag, r["repo"], r["number"], r["state"],
                ",".join(l.replace("lane:", "") for l in r["lanes"]) or "-"))
            for b in r["blockers"]:
                if b != "DELIVERED":
                    print("           · %s" % b)
        print()
        print("NOTE: `RELAY-NO` means the RELAY cannot deliver this — it does NOT mean")
        print("      the lane was never told. A hand-carry delivers a question the relay")
        print("      cannot see, and leaves no trace this tool reads. Measured")
        print("      2026-09-26: tortoise#3923 read `RELAY-NO` (no RESEARCH: declaration)")
        print("      while its lane had ALREADY been delivered the same ruling by hand at")
        print("      06:50 (`[FLEET DELIVERY 06:50]` sat in that lane's queue). Confirm")
        print("      delivery from the LANE (pane queue / session), never from this verdict.")
    if scan_failed:
        print("UNDELIVERED count=? answered=%d  (%d repo(s) unreadable)"
              % (answered, scan_failed))
        return 2
    print("UNDELIVERED count=%d answered=%d" % (len(undelivered), answered))
    return 0 if not undelivered else 1


if __name__ == "__main__":
    sys.exit(main())
