# Landing-lane instruments

Three small tools for a **merge-duty lane** — a session whose job is to drive existing PRs
through the sanctioned landing rail (`scripts/atomic-land.sh`) and report what actually happened.
Two (`landability.py`, `bulk.py`) only read. One (`rail-bg.sh`) **drives the rail**, which updates
the branch, posts to the PR and merges: its `start` subcommand is not read-only — it delegates to
`scripts/rail-run.sh`, the fleet's one background-rail instrument (agent-infra#2905).

They are **advisory**. Nothing here is wired into a gate: they answer questions, and their answers
are inputs to a decision. The rail, the review record and the merge gate stay where they are.

They live here rather than in a lane's scratch directory because the facts they encode were paid
for once already, in `/tmp`, and are about to be paid for again by the next lane.

| Instrument | Answers | Where it runs |
|---|---|---|
| `landability.py` | Does this PR's **recorded review still bind its head**, and are its checks clear? | one PR, ~3 GitHub API calls |
| `rail-bg.sh` | Run the rail in the background, then report `scripts/rail-run.sh`'s verdict for it | one or many PRs |
| `bulk.py` | The same landability answer for **many PRs at once** (planning) | a list of PRs |

---

## `landability.py`

### What it answers

For one PR, whether the review record at `~/.pi/agent/reviews/<owner>-<repo>-<PR>.json` still
covers the code that would merge:

| Verdict | Meaning |
|---|---|
| `AT` | the record names the **current head** |
| `CARRY` | the record is from an older head but its `diff_sha256` equals today's normalized diff — the reviewed **content** is unchanged by the head move (see *What `CARRY` does not prove*) |
| `NEEDS-REVIEW` | no record, an unaccepted verdict, a changed diff, or no `diff_sha256` to compare |
| `BLOCKED` | the PR cannot go through the rail right now: not open, draft, merge conflict, base repointed, no check-run at all, or checks that are failed / in flight / untested |

`BLOCKED` wins the `VERDICT:` line when it applies, and the record answer is always printed
separately on the `record-binding:` line — so a blocked PR still tells you whether a fresh review
is needed. Precedence is fixed and in the module docstring: not-open → draft → merge conflict →
base repointed → no check-run at all → checks failed → checks in flight → checks untested →
record binding.

The check buckets come from the **newest attempt per `(app slug, job name)`**:

- `in-flight` — newest attempt not `completed`;
- `failed` — newest attempt completed with a conclusion outside `success`/`neutral`/`skipped`/`cancelled`/`stale` — an undocumented or null conclusion lands here, which is the fail-closed direction;
- `untested` — newest attempt is `cancelled`/`stale`: the job ran and **exercised nothing**. Not green, and not red either — a cancelled newest attempt is anomalous, so it blocks;
- `not-tested` — newest attempt is `neutral`/`skipped`. Counted and reported, **never** a blocking
  reason: conditional jobs are skipped on every PR, so blocking on them would refuse every PR
  rather than the vacuous ones.

⚠️ `not-tested` is where this instrument's clear-set is **wider than the rail's**. The rail's own
vacuity guard credits only `success`/`failure`/`timed_out` as having *tested* a revision
(`scripts/check-lane-tested.sh`), so a head whose **lane** is entirely `skipped`/`neutral` reads
clear here and is still refused by `admin-merge.sh` with `BLOCK — no run of the lane actually
TESTED head <sha>`. That guard is evaluated per-lane; this instrument reports per-check and does
not attempt to guess which lane the rail will select.

**Declared residual — the grouping key.** `(app slug, job name)` cannot separate two *different*
workflows that publish the same job name (every Actions check-run carries the same app slug), so
the newest attempt of one can mask the other. The repo's rule for this question is
`(app slug, workflow, job name)`, resolved from `details_url`; `scripts/admin-merge.sh` keys the
same way this tool does and AGENTS.md records that as the rail's accepted residual. Separating
them here would cost one extra API call **per check-run** (tens per PR), so this tool adopts the
rail's key and declares the residual instead.

The check-run read uses `?filter=all&per_page=100` **with `--paginate`**, because the default filter
is not "all" and a single page is not the whole set — a truncated page reads as absent checks, which
is how "are the checks terminal?" becomes a false *yes*.

### Exact invocation

```bash
python3.12 scripts/landing/landability.py <pr> [--repo owner/name] [--repo-dir PATH]

# real run, from an agent-infra worktree, against a tortoise PR:
python3.12 scripts/landing/landability.py 6872 \
  --repo daniel-ospina/tortoise \
  --repo-dir <agent-infra-checkout>   # the checkout carrying scripts/lib/diff-normalize.py — NOT the PR's repo
```

⛔ `--repo-dir` is **not** the PR's repo. It selects the *normalizer implementation* the review
contract is defined in (`agent-infra` #1362 D1), so for a `tortoise` PR it is still an
**agent-infra** checkout: `tortoise` carries no `scripts/lib/diff-normalize.py`, and pointing there
fails closed with exit 2 rather than answering with a different normalization.

- `--repo` defaults to `gh repo view --json nameWithOwner` resolved **in `--repo-dir`**.
- `--repo-dir` defaults to the current directory; it is the checkout `gh` runs in and the one the
  diff normalizer is read from.
- The normalizer is resolved as **`<repo-dir>/scripts/lib/diff-normalize.py`**, and the tool
  **fails (exit 2) with a message naming that path** when it is absent. That is deliberate: the
  digest is `sha256` over that file's output, it is the *one* implementation of the review-evidence
  normalization (agent-infra #1362 D1), and without it the `CARRY` answer is unprovable. A silent
  raw-diff fallback would answer a different question with the same word.
- The digest is computed over the normalizer's **bytes** (not a decoded string) with the same
  interpreter that runs the tool, and it was checked against the producer: for tortoise PRs whose
  recorded head equals the current head (6762, 6731, 6791), the recomputed digest equals the
  record's `diff_sha256` exactly. That equality is what `CARRY`'s content comparison rests on, and a
  real head-moved case was observed on tortoise #6794 (record head `5b861947…`, live head
  `f0105965…`, identical digest → `record-binding: CARRY`).
- Exit code: `0` = a verdict was printed; `2` = it could not answer. It never guesses. An
  unexecutable `gh` is exit 2, not a traceback.
- The record's `merge_base_sha` is used when the record carries one (a `clean-low` record does): a
  record bound to a *different* merge base than the PR has now is `BLOCKED(base-repointed)`. This
  mirrors the rail's own pre-unit check (`atomic-land.sh`, B10) — a base repoint leaves every
  head-bound check passing while the certified diff is no longer the diff that would merge.
  `clean`/`clean-micro` records carry no base field, so the arm cannot fire for them: the same
  declared residual the rail documents.

### What `CARRY` does not prove

The producer's carry-forward needs **two** conditions and this tool can see one of them:

1. the reviewed content is unchanged — the local record's `diff_sha256` vs the live normalized
   diff. **This is what `CARRY` reports.**
2. the PR body carries **verifiable signed evidence** — an HMAC-signed
   `review recorded: … diff=<hash> … sig=<hash>` marker whose digest matches. `record-review.sh`
   refuses to carry without it, and this tool does not read it.

The two can disagree in **both** directions, so `CARRY` means "the reviewed content is unchanged",
**not** "the rail's carry-forward will fire":

- a record whose `diff_sha256` still matches but whose **body marker was edited away** reads
  `CARRY` here and is refused by the producer (the documented way a PR-body edit destroys an
  attestation);
- a pre-#1362 marker carrying the legacy **raw** digest is *accepted* by the producer's
  `PRIOR_DIFF_ALT` alternation but reads `NEEDS-REVIEW(no-diff-identity)` here.

Read the rail's step `[3/4] record` output for the producer's own answer.

### ⛔ Why it is not called `preflight.py` — read before renaming it

The fleet already mandates a tool called **`collision_preflight.py`** (it lives in the **tortoise**
repo at `tools/collision_preflight.py`): the **dispatch-side** gate that answers a *different*
question — **"is issue N already being worked?"** — from *different* inputs (an issue number;
open/closed PRs by title and head ref, branches, `git worktree list`, assignee/claims), with the
verdicts `CLEAN` / `COLLISION` / `INCOMPLETE`. It is referenced **by name** in tortoise's
`AGENTS.md` and in four of this repo's skills (`issue-workflow`, `epic-executor`,
`executing-plans`, `subagent-driven-development`).

This script is a **landing-side, advisory** check. Calling it a "preflight" invites a future lane to
substitute one for the other — an advisory landability check standing in for the mandated collision
gate, or a dispatch gate's `CLEAN` being read as a landing verdict. It is named for the question it
answers, for the same reason the collision gate is. (The name it had in the lane's scratch
directory was exactly `preflight.py`; that is the name this section exists to prevent.)

---

## `rail-bg.sh`

### What it answers

**Nothing of its own — it delegates.** It drives the rail and then reports what `scripts/rail-run.sh`
says happened. That separation is deliberate: rail-run is the fleet's ONE background-rail verdict
function (eight states, distinct exit codes, liveness from `scripts/lib/pid-identity.sh`), and this
file is the landing-lane CLI over it. It does not read liveness, does not call the API itself, and
derives no verdict — `rail-bg.test.sh` fails if any of that comes back.

Why it had to change (agent-infra#2905): this script used to be a *second* instrument, with its own
pid file, its own `kill -0` liveness, its own `gh api … .merged` read and its own `REFUSED`/`LANDED`
recommendations. Two verdict rules for one question is the shape AGENTS.md's recorded rule forbids
(*"One verdict function, never a second."*). The capability #1549 introduced is preserved: this CLI
still drives **`atomic-land.sh`** — the full landing unit (base update, CI wait, record
carry-forward, then admin-merge) — through rail-run's `RAIL_RUN_RAIL` seam.

### Why one script with subcommands, not three

The three operations are one lifecycle and share one set of variables: the checkout the rail runs in,
the log directory, and the repo identity. The originals were three separate
files (`launch.sh`, `wait.sh`, `poll.sh`) that each **hardcoded all three** (`/private/tmp/land-lane-4`,
`/tmp/land4`, `daniel-ospina/tortoise`) — that hardcoding is exactly what made them unusable from any
other lane. Merging them puts the resolution in one place, makes `--help` one document, and makes the
instrument a single file to farm into a lane.

### Exact invocation

```bash
scripts/landing/rail-bg.sh start <pr> [rail args...]   # rail-run start; prints the run id + log
scripts/landing/rail-bg.sh wait  <pr> [max_s]          # poll rail-run until it leaves `running`
scripts/landing/rail-bg.sh poll  [--max s] <pr> [pr...]  # the same over several PRs
```

```bash
# real run: a tortoise PR with no review record — the rail stops, and the report says so
LAND_DIR=<agent-infra-checkout> LAND_REPO=daniel-ospina/tortoise \
  scripts/landing/rail-bg.sh start 6872
LAND_DIR=... LAND_REPO=daniel-ospina/tortoise scripts/landing/rail-bg.sh wait 6872 90
# ── rail-run state after 15s ──
# refused pr=6872 run=<id> repo=daniel-ospina/tortoise pid=none rail_pid=none rc=1 pr_state=OPEN …
#   the rail refused this head: admin-merge: ✗ … no review record …
# CONFIRMED merged=false
# RECOMMEND: 6872 REFUSED
```

| Env | Default | What |
|---|---|---|
| `LAND_DIR` | git top level of this script's directory | the checkout the rail runs in; the rail is `$LAND_DIR/scripts/atomic-land.sh` — an **agent-infra** checkout, never the PR's repo (`tortoise` has no `scripts/atomic-land.sh`) |
| `LAND_RAIL` | `$LAND_DIR/scripts/atomic-land.sh` | the rail executable, handed to rail-run as `RAIL_RUN_RAIL` |
| `LAND_REPO` | `gh repo view` **in `LAND_DIR`** | the `[HOST/]owner/name` identity passed to rail-run as `--repo` — it also keys rail-run's run state. It is the **only** way to name it: `start` refuses a `--repo` argument, because `wait`/`poll` take none and two spellings would let them poll a different run than the one `start` created. A failed resolve is an environment error, never a guess |
| `LAND_LOG_DIR` | `$TMPDIR/pi-landing-lane` | where this CLI remembers **which** run it started — `rail-<hex(identity)>-<pr>.run`, keyed by identity **and** PR because rail-run's own store is (a PR-only key let two repos' PR 42 share one binding on a box with the shared default dir). Rail state and logs live in rail-run's `RAIL_RUN_DIR`, not here |
| `LAND_POLL_MAX` | `1500` | default `max_s` for `wait`/`poll`; must be numeric, and a non-numeric value is refused (a bound that can never fire is not a bound) |
| `RAIL_RUN_SH` | `scripts/rail-run.sh` in this repo | the delegate — a test seam, not a knob to point at a second instrument |

Extra `start` args pass straight through to `atomic-land.sh` (`--dry-run`, `--no-wait`, or
`-- --squash` for `admin-merge.sh`), which is how the tool was tested without mutating anything — with
one exception: **`--repo` is refused** (exit 2), because the identity keys rail-run's run state and
`wait`/`poll` carry no `--repo`. Set `LAND_REPO` instead; that is the one place the identity lives.

### The contract that matters

`wait` and `poll` print **rail-run's own state row verbatim** (its evidence: rc, pids, log size, the
PR's state and merge timestamp) followed by two transcribed lines:

- **`CONFIRMED merged=true|false|UNREADABLE`** — read from that row's `merged=`/`pr_state=` fields,
  which are rail-run's recorded API read. `true` for an observed merge (a `merged=` timestamp, **or**
  `pr_state=MERGED` — `mergedAt` is schema-nullable, so `MERGED` with `merged=-` is a real pair and it
  is a merge, never a `false`), `false` only when the read returned `OPEN`/`CLOSED`, and
  **`UNREADABLE reason=…`** otherwise: never an empty field, because an empty field is read as
  whatever the parser wants, and `false` would be a claim the tool cannot make. **The same value feeds
  the `LANDED` recommendation's `merged=`, so the two lines cannot contradict each other.**
- **`RECOMMEND: <pr> LANDED|PENDING|REFUSED|KILLED|NO-VERDICT|EXITED-ZERO-NOT-LANDED|NO-RUN|UNKNOWN`**
  — a RENAME of rail-run's exit code, nothing more. A code outside rail-run's table, or a code and a
  row that disagree, prints **`UNKNOWN (rc=… state=… )`** — it is never resolved in favour of
  `LANDED`/`REFUSED`. A `running` run at the caller's bound prints **`PENDING`**: a still-running rail
  has no outcome yet and frequently does land (#2412 is the shape where a lane was told "refused" and
  the PR merged four minutes later).

The exit code is **rail-run's**, with two stated exceptions: `0` landed · `10` running · `20` refused ·
`21` killed · `22` gone-without-verdict · `23` exited-zero · `24` no-run · `25` unknown ·
`2` usage/environment · `3` a live run already holds the PR · `5` the launch did not start (rail-run
could not record a pid) · `78` rail-run's identity library is missing (it refuses to guess liveness).

1. When this CLI **retracts** the code — a row exists but it and the code disagree, so the report says
   `UNKNOWN (rc=… state=…)` — it exits `25` (rail-run's own abstention), **never** the retracted
   `0`/`20`: exiting `LANDED`/`REFUSED` while printing "no verdict" is the false-PASS and #2412
   abandon shape in the signal lanes actually branch on. When rail-run exits with **no state row at
   all** (`2` usage, `3` a live run holds the PR, `5` the launch did not start, `78` its identity
   library is missing) that is **not** a retraction: the report says `ERROR (rc=… — <what it means>)`
   and the code is kept, so a partial install still names itself.
2. `poll` exits with the **worst of the per-PR codes** (the `gh pr checks` convention for a multi-item
   answer), so one landed PR beside one abstention exits `25`, not `0`.

`0` on `start` means launched, not landed.

**One rail per PR.** rail-run refuses a second live run for the same PR (exit 3) and its claim has a
stale bound, so the README's own advice (fact 3 below) — re-run the rail after a base-side fix — is
safe: wait for the first run, or let its claim age out. This CLI adds no second guard of its own.

---

## `bulk.py`

### What it answers

The same landability question for many PRs, in parallel — "of the PRs I might land, which can the
rail take right now?" One row per PR, plus `verdicts:` counts and
`landable now (AT or CARRY): N/M`.

### Why it is genuinely useful without the queue file

The original read a fixed `LANDABLE.tsv` plus a `CLAIMS.tsv` and joined them on a queue schema. That
join is the queue tool's job, and this tool cannot know that schema. What it *can* do without knowing
anything is read **the first column as a PR number**, which every queue, `gh pr list`, and hand-typed
list already is:

```bash
python3.12 scripts/landing/bulk.py --repo daniel-ospina/tortoise --repo-dir <agent-infra-checkout> \
  6872 6862 6860 6837 6804 6794 6791 6788 6762 6742 6731 6719

# or any file whose first column is a PR number ('-' = stdin)
gh pr list --repo daniel-ospina/tortoise --state open --limit 45 --json number --jq '.[].number' \
  | python3.12 scripts/landing/bulk.py --repo daniel-ospina/tortoise --repo-dir <agent-infra-checkout> --prs-file -
```

Blank lines and `#` comments are skipped. `--jobs` (default 8) sets concurrency.

Exit `0` = every row is `AT`/`CARRY`; `1` = at least one row needs attention; `2` = it could not
answer at all — usage, bad input, missing normalizer, or a `gh` failure that made **every** row
unreadable. A single unreadable row among readable ones is reported as a row and exits `1`, because
the report itself succeeded. **It is a report: it does not claim, queue, record or land anything** —
claims still go through the queue tool.

---

## Operational facts these instruments exist to carry

### 1. A rail exit code is not proof that a landing happened

`atomic-land.sh` once printed "merged" while the PR was still open (#1359), and a merge can complete
server-side while the command exits non-zero (#193). That is why the verdict is not the exit code:
`rail-run.sh` derives the state from the recorded status, both incarnations, the log and the PR's own
`merged` field, and `rail-bg.sh` reports that read as `CONFIRMED merged=…`. Count a
landing only on `merged=true` from the API.

### 2. A base-state refusal is usually about the **base**, not the PR

`admin-merge.sh` — and the `ci_exemption.py` it calls — refuses with statements about **main's**
measurement state:

- `BLOCK — no run of the lane actually TESTED head <sha>` — the lane's run was queued or cancelled,
  so it exercised nothing;
- `BLOCK — BASELINE-INAPPLICABLE: the baseline lane '<lane>' never TESTED main, so there is no
  baseline` — main's side of the comparison is empty, and an empty baseline absorbs nothing. The
  state names the workflow it looked for and three remedies, in order: one lane that runs on both
  sides (`--workflow` alone), a named base-side lane (`--baseline-workflow <main-lane>`), or — if
  nothing measures main — the fact that this rail cannot judge it;
- `no main-side measurement (PR <rate>) — NOT exempt` — main's baseline carries no measurement of
  that file, so absence is **not** exemption.

None of those are defects in the PR. Read them as "the base is not measurable right now", fix the
base side, and re-run.

### 3. What re-running actually re-evaluates — two different commands

This is the part that gets misremembered, so it is stated exactly:

- **Re-running the rail re-reads the base.** `atomic-land.sh` resolves the base relation from the
  API on each pass — `merge_base_of()` (`compare/<base>...<head>` `.merge_base_commit.sha`) and
  `base_tip()` (`pulls/<n>` `.base.sha`) on every round, and `behind_by_of()` (`.behind_by`)
  whenever the merge state is not already `BEHIND`. So re-running the rail against an unchanged head
  **does** evaluate that same head against the base as it is **now**. That is the command to reach
  for after a base-side fix: `rail-bg.sh start <pr>` (or `scripts/atomic-land.sh <pr>`). A run that
  stops early — e.g. at `read_record`, before the loop — reads none of them, so there is no base
  measurement in that log.

  A capture that comes back **empty** is not read as a value on the first reply: `gh_read()` re-polls
  it a bounded number of times (`ATOMIC_LAND_TRANSIENT_POLLS`, default 5) before the caller's
  fail-closed test sees it, so a transient API failure settles while a genuinely unreadable base
  still refuses. `atomic-land: could not read the base tip` therefore means *persistently*
  unreadable, not *once*. See issue #1558.
- **`gh run rerun <run-id>` re-executes one CI lane at the commit that run was created for.** Per
  GitHub's own documentation, a re-run "will also use the same `GITHUB_SHA` (commit SHA) and
  `GITHUB_REF` (git ref) of the original event that triggered the workflow run". So a re-run is the
  right remedy when what is missing is a **measurement of that same commit** — a flaky or cancelled
  lane run at the base, or a lane that was never started — and it is **not** a way to measure a base
  that has since moved. Re-running an old lane run measures the old commit.

  `gh run rerun <run-id>` takes the run id; `gh run view <run-id> --json jobs --jq '.jobs[] |
  .databaseId'` gives the job ids that `--job` wants (the number in the browser URL is *not* it).

### 4. ⛔ Never "push an empty commit" to clear a stale-base refusal

An empty commit moves the head. The review evidence is **bound to the head** (`diff_sha256` over the
normalized diff), so moving the head for a reason that does not change the reviewed code destroys a
valid attestation and forces a fresh review — the loop the rail's carry-forward arm exists to avoid.
Re-run the rail instead: it re-reads the base without touching the head, and the carry-forward keeps
the record when the reviewed content is unchanged.

### 5. ⛔ Never brand a landing-side check `preflight.py`

See `landability.py`'s section above. The name is taken by the mandated dispatch-side collision gate.

---

## What these do not do

- They do not review, record, merge, dispatch, claim, or queue.
- They are not a substitute for `collision_preflight.py` (dispatch-side: "is issue N already being
  worked?").
- `landability.py` / `bulk.py` need a checkout that carries `scripts/lib/diff-normalize.py`. A lane
  that only has the rail installed is a **partial install** and the tool says exactly that.
- `rail-bg.sh` derives no verdict of its own: liveness, the PR read and the state word all come from
  `scripts/rail-run.sh` (agent-infra#2905). Its only local state is the run id it started, so a `wait`
  polls that run rather than a newer one. `rail-bg.test.sh` fails if a second verdict rule returns.
