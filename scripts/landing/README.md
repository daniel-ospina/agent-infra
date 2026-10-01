# Landing-lane instruments

Three small, read-only-by-default tools for a **merge-duty lane** — a session whose job is to
drive existing PRs through the sanctioned landing rail (`scripts/atomic-land.sh`) and report what
actually happened.

They are **advisory**. Nothing here is wired into a gate: they answer questions, and their answers
are inputs to a decision. The rail, the review record and the merge gate stay where they are.

They live here rather than in a lane's scratch directory because the facts they encode were paid
for once already, in `/tmp`, and are about to be paid for again by the next lane.

| Instrument | Answers | Where it runs |
|---|---|---|
| `landability.py` | Does this PR's **recorded review still bind its head**, and are its checks clear? | one PR, ~3 GitHub API calls |
| `rail-bg.sh` | Run the rail in the background, then read its **real** result from the API | one or many PRs |
| `bulk.py` | The same landability answer for **many PRs at once** (planning) | a list of PRs |

---

## `landability.py`

### What it answers

For one PR, whether the review record at `~/.pi/agent/reviews/<owner>-<repo>-<PR>.json` still
covers the code that would merge:

| Verdict | Meaning |
|---|---|
| `AT` | the record names the **current head** |
| `CARRY` | the record is from an older head but its `diff_sha256` equals today's normalized diff — the head moved by a **base-only** update, so `record-review.sh`'s carry-forward can re-bind it |
| `NEEDS-REVIEW` | no record, an unaccepted verdict, a changed diff, or no `diff_sha256` to compare |
| `BLOCKED` | the PR cannot go through the rail right now: not open, draft, merge conflict, or its checks are failed / in flight / untested |

`BLOCKED` wins the `VERDICT:` line when it applies, and the record answer is always printed
separately on the `record-binding:` line — so a blocked PR still tells you whether a fresh review
is needed. Precedence is fixed and documented in the module docstring: not-open → draft → merge
conflict → checks failed → checks in flight → checks untested → record binding.

The three check buckets come from the **newest attempt per `(app slug, job name)`**:

- `in-flight` — newest attempt not `completed`;
- `failed` — newest attempt completed with a conclusion outside `success`/`neutral`/`skipped`/`cancelled`/`stale`;
- `untested` — newest attempt is `cancelled`/`stale`, i.e. that job ran and **exercised nothing**.
  This is not the same as green, and not the same as red: `atomic-land.sh`'s own merge precondition
  is that the lane actually *tested* the head, and a cancelled run tested nothing.

The check-run read uses `?filter=all&per_page=100` **with `--paginate`**, because the default filter
is not "all" and a single page is not the whole set — a truncated page reads as absent checks, which
is how "are the checks terminal?" becomes a false *yes*.

### Exact invocation

```bash
python3.12 scripts/landing/landability.py <pr> [--repo owner/name] [--repo-dir PATH]

# real run, from an agent-infra worktree, against a tortoise PR:
python3.12 scripts/landing/landability.py 6872 \
  --repo daniel-ospina/tortoise \
  --repo-dir /Users/danielospina/Documents/GitHub/tortoise/.worktrees/1509-E1
```

- `--repo` defaults to `gh repo view --json nameWithOwner` resolved **in `--repo-dir`**.
- `--repo-dir` defaults to the current directory; it is the checkout `gh` runs in and the one the
  diff normalizer is read from.
- The normalizer is resolved as **`<repo-dir>/scripts/lib/diff-normalize.py`**, and the tool
  **fails (exit 2) with a message naming that path** when it is absent. That is deliberate: the
  digest is `sha256` over that file's output, it is the *one* implementation of the review-evidence
  normalization (agent-infra #1362 D1), and without it the `CARRY` answer is unprovable. A silent
  raw-diff fallback would answer a different question with the same word.
- The digest is computed over the normalizer's **bytes** (not a decoded string) with the same
  interpreter that runs the tool, and it was checked against the producer: for three tortoise PRs
  whose recorded head equals the current head, the recomputed digest equals the record's
  `diff_sha256` exactly. That is the whole basis of `CARRY`.
- Exit code: `0` = a verdict was printed; `2` = it could not answer. It never guesses.

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

Nothing by itself — it drives the rail and then **reads back what happened**, because the rail's own
output cannot be trusted for that (see *Operational facts* below).

### Why one script with subcommands, not three

The three operations are one lifecycle and share one set of variables: the checkout the rail runs in,
the log/pid directory, and the repo for the merged-state read. The originals were three separate
files (`launch.sh`, `wait.sh`, `poll.sh`) that each **hardcoded all three** (`/private/tmp/land-lane-4`,
`/tmp/land4`, `daniel-ospina/tortoise`) — that hardcoding is exactly what made them unusable from any
other lane. Merging them puts the resolution in one place, makes `--help` one document, and makes the
instrument a single file to farm into a lane.

### Exact invocation

```bash
scripts/landing/rail-bg.sh start <pr> [rail args...]   # nohup the rail; writes rail-<pr>.{log,pid}
scripts/landing/rail-bg.sh wait  <pr> [max_s]          # wait, then print the log tail + merged=
scripts/landing/rail-bg.sh poll  [--max s] <pr> [pr...]  # wait for several, then report each
```

```bash
# real run: a tortoise PR with no review record — the rail stops, and the report says so
LAND_DIR=/Users/danielospina/Documents/GitHub/tortoise/.worktrees/1509-E1 \
LAND_LOG_DIR=/tmp/pi-railbg-test LAND_REPO=daniel-ospina/tortoise \
  scripts/landing/rail-bg.sh start 6872
LAND_DIR=... LAND_LOG_DIR=/tmp/pi-railbg-test LAND_REPO=daniel-ospina/tortoise \
  scripts/landing/rail-bg.sh wait 6872 90
# ── rail finished after 15s ──
# ⛔ atomic-land: STOP — no review record for daniel-ospina/tortoise#6872 — there is no verdict to
#    carry and this rail cannot review; run the review, then record
# NOTE: the rail process ending (and its exit code) is NOT proof of a landing — the API read below is.
# CONFIRMED merged=false
# RECOMMEND: 6872 REFUSED
```

| Env | Default | What |
|---|---|---|
| `LAND_DIR` | git top level of this script's directory | the checkout the rail runs in; the rail is `$LAND_DIR/scripts/atomic-land.sh` |
| `LAND_LOG_DIR` | `$TMPDIR/pi-landing-lane` | where `rail-<pr>.log` and `rail-<pr>.pid` live |
| `LAND_REPO` | `gh repo view` **in `LAND_DIR`** | repo for the merged-state read |
| `LAND_POLL_MAX` | `1500` | default `max_s` for `wait`/`poll` |

Extra `start` args pass straight through to `atomic-land.sh` (`--dry-run`, `--no-wait`, or
`-- --squash` for `admin-merge.sh`), which is how the tool was tested without mutating anything.

### The contract that matters

`wait` and `poll` print **`CONFIRMED merged=true|false`** read from
`gh api repos/<o>/<r>/pulls/<n> --jq .merged`. A failed API read prints
**`CONFIRMED merged=UNREADABLE reason=…`** — never an empty field, because an empty field is read
as whatever the parser wants, and `false` would be a claim the tool cannot make. `RECOMMEND: …
LANDED` is printed only on a read that returned `true`.

Exit `0` means the wait/start completed. It is **not** a landing verdict. Read the printed value.

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
python3.12 scripts/landing/bulk.py --repo daniel-ospina/tortoise --repo-dir <tortoise-checkout> \
  6872 6862 6860 6837 6804 6794 6791 6788 6762 6742 6731 6719

# or any file whose first column is a PR number ('-' = stdin)
gh pr list --repo daniel-ospina/tortoise --state open --limit 45 --json number --jq '.[].number' \
  | python3.12 scripts/landing/bulk.py --repo daniel-ospina/tortoise --repo-dir <checkout> --prs-file -
```

Blank lines and `#` comments are skipped. `--jobs` (default 8) sets concurrency.

Exit `0` = every row is `AT`/`CARRY`; `1` = at least one row needs attention; `2` = it could not
answer. **It is a report: it does not claim, queue, record or land anything** — claims still go
through the queue tool.

---

## Operational facts these instruments exist to carry

### 1. A rail exit code is not proof that a landing happened

`atomic-land.sh` once printed "merged" while the PR was still open (#1359), and a merge can complete
server-side while the command exits non-zero (#193). That is why `rail-bg.sh` reads
`gh api repos/<o>/<r>/pulls/<n> --jq .merged` and prints it, and why `wait` says so out loud. Count a
landing only on `merged=true` from the API.

### 2. A base-state refusal is usually about the **base**, not the PR

`admin-merge.sh` refuses with statements about **main's** measurement state:

- `BLOCK — no run of the lane actually TESTED head <sha>` — the lane's run was queued or cancelled,
  so it exercised nothing;
- `BLOCK — the lane '<lane>' never TESTED main, so there is no baseline` — main's side of the
  comparison is empty, and an empty baseline absorbs nothing;
- `no main-side measurement — NOT exempt` — main's baseline carries no measurement of that file, so
  absence is **not** exemption.

None of those are defects in the PR. Read them as "the base is not measurable right now", fix the
base side, and re-run.

### 3. What re-running actually re-evaluates — two different commands

This is the part that gets misremembered, so it is stated exactly:

- **Re-running the rail re-reads the base.** `atomic-land.sh` fetches `pulls/<n> .base.sha`,
  `compare/<base>...<head> .merge_base_commit.sha` and `.behind_by` on *every* run. So re-running the
  rail against an unchanged head **does** evaluate that same head against the base as it is **now**.
  That is the command to reach for after a base-side fix: `rail-bg.sh start <pr>` (or
  `scripts/atomic-land.sh <pr>`).
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
- `rail-bg.sh`'s liveness test is `kill -0` on a pid file, so a pid recycled by an unrelated process
  looks like a live rail — bounded by `max_s`, which is why every wait takes one.
