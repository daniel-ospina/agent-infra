---
title: "rail-run — running the merge rail without letting a tool call kill it (#2885)"
type: engineering
domain: operations
doc_status: live
subjects.team: organisation-design-team
created: 2026-10-27
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, issue-2885, issue-1167, merge-rail, admin-merge, rail-run, pid-identity, fleet-liveness, tool-timeout
---

# rail-run — running the merge rail without letting a tool call kill it

`scripts/rail-run.sh` starts the merge rail (`scripts/admin-merge.sh`) **detached** and gives a lane a
first-class verdict to poll. It exists because of a bound mismatch between two processes.

## The defect (measured, agent-infra#2885)

| bound | value | owner |
|---|---|---|
| a blocking tool call | **1800 s** | the harness (`pi`) — not settable from this repo |
| the rail's FIRST-CHECKS ceiling (`ADMIN_MERGE_FIRST_CHECKS_CEILING`) | **18064 s** | `scripts/admin-merge.sh` (#1167 is this one) |

A lane that ran `bash scripts/admin-merge.sh <PR>` inside a blocking tool call was SIGTERMed at
1800 s while the rail was legitimately still waiting on CI. Measured 2026-10-26 on PR #2873:

| event | timestamp |
|---|---|
| the lane's rail invocation started | `22:40:54Z` |
| the rail still logging `FIRST-CHECKS wait: still RUNNING and PROGRESSING` | `23:10:47Z` |
| the lane's bash call killed at its 1800 s cap | `23:10:47Z` |
| **#2873 merged** (head unchanged, attestation intact) | `03:56:04Z` |

So a *healthy* rail read as a failure, and **no rail verdict exists for that head at all** — the
lane could not tell "still running" from "refused" from "killed".

## Use

```bash
bash scripts/rail-run.sh start  <PR> ARGS...                              # returns at once
bash scripts/rail-run.sh status <PR> (--repo owner/repo) (--run <run-id>)        # poll
```

`start` launches the rail in its own session with its own log and its own recorded exit status,
prints the run id / log path / exact poll command, and exits. Nothing in this script waits on the
rail, so no tool call can be capped by it.

State lives under `${RAIL_RUN_DIR:-${O:-$HOME/orchestrator}/state/rail-run}/<repo-key>/pr-<N>/<run-id>/`
(`pid`, `start`, `created`, `railpid`, `railstart`, `rc`, `log`, `repo`, `host`, `rail`, `args`,
`started`, and a `latest` pointer, which is written atomically and validated like `--run` because it is
joined into a
path; a directory with neither a `log` nor a `repo` — e.g. the `.starting` claim — is not a run). Knobs: `RAIL_RUN_DIR`, `RAIL_RUN_RAIL` (the rail, default `admin-merge.sh` beside
this script), `RAIL_RUN_REPO_SLUG` (pin the repo identity instead of resolving `origin`),
`RAIL_RUN_GH_HOST` (pin the **web host** the artifact URL must name — for a checkout whose `origin`
names a mirror, an ssh alias, or a transport port that the web URL never carries. The host is RECORDED
with the run at `start` and a poll only reads that record, so this knob takes effect on the NEXT run,
not on a re-poll of a live one. Precedence at `start`, highest first: a host-naming `--repo` or
`RAIL_RUN_REPO_SLUG` (`HOST/OWNER/REPO` — the host comes from the same value the slug came from), then
this knob, then `origin`; `github.com` when none of them names one),
`RAIL_RUN_CLAIM_MAX` (60 s) and `RAIL_RUN_RECORD_MAX` (24 h). **Both must be positive integers**: an
unreadable value is refused at load (`exit 2`, naming the knob) rather than silently used, because an
erroring `[ -le ]` answers "not young", which would judge a live claim stale and let a second rail
start on the same PR.

**One rail per PR.** `start` takes an atomic `mkdir` claim *before* it probes, so two concurrent
starts for one PR cannot both launch a rail (two merge attempts on one head). The claim is released
only once `latest` is published; a claim whose launcher is positively gone, or one older than
`RAIL_RUN_CLAIM_MAX`, is cleared and retried once. A claim that has not written its pid yet is **in
flight, not dead** — reading that window as "no owner" is how a guard deletes a live claim.

## States (each one derived, never guessed)

| state | exit | meaning |
|---|---|---|
| `running` | 10 | no exit status yet, and the **recorder** is alive — or the **rail** is, when the recorder has been SIGKILLed out from under it |
| `landed` | 0 | the PR is MERGED. `verdict=rail` when the rail exited 0; `verdict=artifact` when the merge is real but the rail wrote **no verdict or a non-zero one** |
| `refused` | 20 | rc=2 (a **usage/configuration** refusal — about the invocation, not the head; a MERGED artifact still wins over it), or rc≠ 0 whose last `admin-merge: ✗ …` line is one of the **recognised head-verdict wordings** — `THE TREE THIS PR PRODUCES IS RED`, `CONFLICTED`, `PR #N is a DRAFT`, `… failure(s) SURVIVED the re-run`. Everything else is `unknown` (25), and the exclusions matter more than the list: the family-wide `THE BASE IS RED` is out (one of its three lines says the rail could not read the base parent); `… HAS NOT MEASURED IT` and `… EVALUATED AGAINST AN OLDER BASE` are out because `admin-merge.sh` calls that family a **re-measurement request, never a verdict on the PR** (its own remedy is "RE-MEASURE against the current base, then re-run the rail"); `never TESTED main` is out because the rail calls it a **misconfiguration** whose remedy is an invocation change (`add --any-workflow`); `--no-rerun` is out because it is the **caller's own flag**; and `no run of the lane actually TESTED head` is out because it is a precondition about CI having been dispatched rather than a judgement of the diff. The rule the list encodes is `scripts/orchestrator-harness/rail-refusal.sh`'s — *the trigger is a RED TREE, not "any refusal"*: a lane told `refused` abandons a PR, and a re-measurement or a config refusal must not do that. Any other `✗` line — the rail has ~117 templates, most of them "could not read", "no classification attempted", or "stopped mid-wait" — is `unknown`: a refusal is a claim about your head and needs positive support |
| `killed` | 21 | the rail died of a signal (rc ≥ 128), named (SIGTERM / SIGKILL / …) |
| `gone-without-verdict` | 22 | **no exit status, recorder gone, rail not alive, PR not MERGED: this run produced no verdict.** Never reported as a landing |
| `exited-zero` | 23 | rc=0 and the PR is not merged (a `--dry-run` / `--print-bounds` inspection run) |
| `unknown` | 25 | an evidence read abstained: `ps` unreadable, no recorded incarnation, an unusable recorded start, a corrupt status file, an **unreadable or unverified** PR state, a non-zero exit with no `admin-merge: ✗` line, or a `✗` line that is not a **recognised head verdict** (an ERROR / a no-verdict run — the rail's own words are always printed) |
| `no-run` | 24 | nothing was ever started for this PR |

Other codes: `2` usage, `3` a live (or unverifiable) run already holds this PR, `5` the launch did
not start, `78` the identity library is missing.

Every poll prints its evidence on one line — `pid`, `rail_pid`, `rc`, `pr_state`, `merged`,
`started`, `log_bytes`, `log_age_s`, `verdict` — followed by reason lines.

**Liveness is not `%CPU` and not a first-match `ps` grep.** Identity comes from
`scripts/lib/pid-identity.sh`, the fleet's one process-identity rule, whose `unknown` verdict is an
abstention and never a death witness; a live pid whose incarnation does not match is not "running".
Both the **recorder's** and the **rail's** incarnations are checked, which is what keeps the two
load-bearing distinctions honest:

- **"still running" vs "no verdict"**: `running` (10) needs positive evidence that the run is alive
  (recorder or rail); `gone-without-verdict` (22) needs positive evidence that neither is; anything
  else — including an absent or unreadable record — is `unknown` (25).
- **"a verdict" vs "a merge"**: `landed` needs the MERGED artifact; `rc=0` alone is `exited-zero`
  (23) unless the PR says MERGED, and a failed artifact read is `unknown` for every exit status **that
  classifies the head** — so `killed`/`refused` can never be printed over a merge the API failed to
  report. The one exception is `rc=2`, decided *before* that abstention by design: a usage/configuration
  refusal is a fact about the **invocation** (the rail never analysed this head, so there is no head
  verdict to protect), which is what keeps a run usable in a checkout whose PR read is unavailable —
  the `refused` row above states the same exception, and a MERGED artifact still wins over it.
- **"a merged PR" vs "a merged PR of the same number somewhere else"**: the artifact read is *about a
  PR number*, and `gh` resolves a bare number against ambient `GH_REPO` or the poller's cwd — the
  measured #2235 shape, where a cell-wide `GH_REPO` made the rail print `ALREADY MERGED` over an open
  PR. So the read always passes `--repo`, always asks for the PR's `url`, and **the url must name this
  repo, this PR, and the host recorded at `start`** (a path SUFFIX match is not an identity: the rail
  learned the same lesson in #2235) or the read abstains.
  The identity is **normalised** (`[HOST/]OWNER/REPO` and the `--repo=X` spelling both reduce to
  `owner/repo`, lower-cased because GitHub's names are case-insensitive while a `case` glob is not —
  un-lower-cased, a canonical URL never matched and `landed` was unreachable), it is forwarded to the
  rail as `--repo` when it did not come from argv (so the record and the rail's target are one value
  by construction), and it is **required to start**: `start` refuses (exit 2) when neither `--repo` nor
  `origin` names a repository, because a run that can never verify its own artifact could only ever
  report `unknown`. It is recorded in the run, and that record is authoritative: a poll whose
  `--repo` contradicts it abstains, because the state key maps `/` to `-` and is not injective
  (`a/b-c` and `a-b/c` share one).
  **The host comes from the same value as the slug.** When `--repo` — or the checkout-wide
  `RAIL_RUN_REPO_SLUG` pin, which is spelled the same way — is given as `[HOST/]OWNER/REPO`, the host
  it names is recorded; only a bare `owner/repo` (or no identity argument at all) falls back to
  `origin`. Reading the host from `origin` while the slug came from `--repo` (or from the pin, which is
  the seam for a checkout whose `origin` does *not* name its repo) recorded a `github.com/<slug>` pair
  for a target on another host, so the artifact check demanded a URL that host never serves and
  `landed` was unreachable — fail-closed, but a run nobody could land.
  **A transport port is not part of the host.** When the fallback reads `origin`, the `user@` prefix is
  stripped (validating before stripping degraded `git@host:owner/repo` to `github.com`) and an
  `ssh://`/`git://` port is dropped — those ports belong to the git transport, and the artifact URL
  compared is an https URL that never carries them, so recording `host:22` made `landed` unreachable.
  An `https://host:8443` port is **kept**: a GHE on a custom port really does serve URLs carrying it.

One live rail per PR: `start` takes an **atomic claim** (`mkdir`) *before* it probes the existing
run, so two racing starts cannot both launch a rail (two merge attempts on one PR). The state key is
the **canonical slug** (`start 5` and `start 5 --repo owner/repo` converge on one key), so the two
documented spellings cannot reach the rail twice either. The probe itself is on the previous run's
incarnation, so a stale run directory never blocks a start — only positive evidence of a live one
does.

⛔ **Every abstention that can block a start is BOUNDED**, on a `created` epoch written at
creation (not on an mtime, which can be unreadable — and an unreadable age is *not* "young"), because an unbounded "may still be alive"
is the stale-flag defect (#8175) — a PR that can never be started again without hand-editing state.
A claim is stale after `RAIL_RUN_CLAIM_MAX` (60 s: its launcher's whole life is the 5 s pid wait),
and a run record whose liveness abstains stops blocking after `RAIL_RUN_RECORD_MAX` (24 h: a real
rail run is hours). The bound applies only to the *admission* decision — `status` keeps saying
`unknown` for that record, because "is it alive" genuinely is unknown. **The claim path and the
record path take that bound from one helper**, so a claim with no pid and an unreadable age is
stale rather than an eternal refusal — the two must not drift apart, because drift in the
*blocking* direction is the defect itself. When a launch is reported failed but its spawn is still
alive, the claim is deliberately **kept and re-pointed at that live spawn**, so the next start is
refused by a probe that can see it instead of by a launcher pid that has already exited.

## What is NOT fixed here (the honest half)

**The 1800 s tool cap is the harness's, not this repo's.** Changing it belongs in `pi` (a
per-dispatch tool timeout), and this script does not depend on that happening: the poll is the
interface, so a lane works identically with or without a longer cap. Until the cap moves, **do not
run the rail in a blocking tool call** — use `start` + `status`.

Three stated residuals:

- **`session=shared`.** Isolation is used when `setsid` (or `python3`) is available; when neither is,
  the rail shares the caller's process group and a process-*group* kill aimed at the caller reaches
  it. `start` measures this after the spawn and prints `session=own|shared|unknown` — it never claims
  isolation it did not get. The tool-cap collision is still removed in the `shared` case, because the
  caller's call has already returned.
- **A SIGKILL of the recorder** writes no exit status by construction. The rail can outlive it and
  still merge; the poll then reports `running` (the rail is what is alive), and once the rail is gone
  it reports `gone-without-verdict`. If the PR turns out MERGED, the state is `landed
  verdict=artifact`, which says the merge is real and that *this run* certified nothing.
- **A microsecond window**: the rail's pid is recorded immediately after the spawn, so a SIGKILL in
  that window leaves a run whose rail is unrecorded. It reads `gone-without-verdict`, and each
  subsequent poll re-reads the artifact — a merge that then happens is reported as
  `landed verdict=artifact`, never as a rail verdict.

## Tests

```bash
bash scripts/rail-run.test.sh      # no network, no real gh, no real rail
```

**213 passed, 0 failed** (`bash scripts/rail-run.test.sh`, no network; the only number asserted anywhere is the pass/fail line). The suite is mostly
negative — `running` must never read as landed or refused, `rc=0` is not a landing when the artifact
disagrees, `gone-without-verdict` is never a landing *or* claimed over an unread artifact, an
unreadable liveness or PR read abstains, a live pid with the wrong incarnation is not "running", a
claim in its `mkdir`→`pid` window is in flight rather than dead, `--repo`/`--run` cannot escape the
run root, an artifact read whose url names another repo is not a landing, a poll that contradicts
the run's recorded repo abstains instead of answering with it, a mixed-case slug is one key and one
identity, the identity reaches the rail exactly once even with a `--`, a flag in a flag's value slot is
refused by both verbs instead of silently dropping the pin (and the identity pin's host is recorded, so
a GHE pin can actually land), a `✗` line that could not
read something is not a refusal, an abstaining run record cannot block a PR forever, and two racing
starts reach the rail exactly once (the recorder's own liveness blocks too, so the window before
the rail's pid exists is covered). Every arm names the guard it discriminates; removing that guard
fails the arm (mutation-checked while writing it).
