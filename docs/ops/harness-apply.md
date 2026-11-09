---
title: "Harness apply — activation on the clock (#2416)"
type: engineering
domain: operations
doc_status: live
subjects.team: organisation-design-team
created: 2026-10-23
aboutSubjects: organisation-design-team
aboutObjects: agent-infra, issue-2416, harness-activation, cloud-cell-supervisor, sync, systemd, launchd
---

# Harness apply (#2416)

One scheduled pass — `scripts/harness-apply-pass.sh` — that puts a box's harness on
`origin/main`. It **owns no activation**: it calls the verb the box already has, behind
the safety predicates that decide whether the box may be moved at all.

| platform | activation verb (existing) | scheduled artifact | cadence |
|---|---|---|---|
| Linux cell | `scripts/cloud-cell-supervisor.sh apply` (`--pin-only` while a controller is live) | `eldato-harness-apply.service` + `.timer` | `OnUnitActiveSec=10min`, `OnBootSec=2min` |
| macOS | the checkout's own `./sync.sh` (fetch + `pull --ff-only` + config refresh + launchd) | `~/Library/LaunchAgents/com.eldato.harness-apply.plist` | `StartInterval=600` (+ one at load) |

Installed by `scripts/install-harness-apply-timer.sh` — one installer that renders and
converges, both platforms. `cloud-cell-bringup.sh --check` runs it, so a cell is never
certified `CELL READY` without an activation clock.

## Why it exists

The capability was built and correct (`apply` pins a per-commit worktree,
agent-infra#1745; `start` runs it before every launch). **Nothing scheduled it**, so a
box ran whatever code it had when it was last started. Measured 2026-10-23:

```
Mac   agent-infra HEAD ce97fe82 · origin/main c51630de · behind 91
      AGENT_SYNC_MODE=auto  -> yet 91 behind, because ONE modified tracked file
      (scripts/orchestrator-harness/install.sh) made sync.sh abort — and nothing said so
c1    HARNESS-PIN 54bbb0c6 while its checkout was ce987bb2      <- the pin lied
c3/c4 pin ce987bb2 while origin/main was c51630de               <- stale
```

A harness fix that merged but is not live on a cell **has fixed nothing**: the fleet
keeps executing the behaviour the fix removed. And the drift was invisible — the pin is
a file nothing re-read, `sync.sh` aborting is *correct* behaviour with no reporter above
it.

## The safety predicates (stated, and tested)

The pass refuses to move a box it must not move. Each predicate is a pair in
`scripts/harness-apply-timer.test.sh`: the refusal, and the same fixture moving once the
condition is gone.

- **AHEAD of the ref → REFUSED (exit 21), with the count.** Local commits may be a lane's
  only copy: c4 lost three unlanded commits on 2026-10-22, recovered only through
  `git cherry`. The count is in the message because "ahead" alone does not say whether it
  is worth keeping.
- **DIVERGED → REFUSED (exit 22).** Neither ancestor nor descendant: a rebase is an
  operator decision, not a scheduled one.
- **DIRTY → preserved BY NAME, then moved.** The bytes are written to
  `<state>/harness-apply-preserved/<UTC>-<pid>/changes.patch` (plus `changes.index.patch`,
  the staged half that `git diff HEAD` never reads), every untracked file is copied
  under `untracked/`, and `MANIFEST` lists every path taken; each path is printed as it is
  saved. Only then are the tracked paths brought back to `HEAD` and the checkout advanced.
  If anything cannot be preserved, the pass REFUSES (exit 20). Preservation and the restore
  are one pass over the same list, so a failure in the restore half can leave the checkout
  **part-restored** — every affected byte is written to the preservation directory first, and
  the refusal message says which of the two happened.
  This is the Mac defect: `sync.sh` aborting on a dirty tree is right — having no path
  that saves the work and finishes the advance is what cost 91 commits.
- **A RUNNING LANE IS NEVER SIGNALLED.** The pass contains no `kill`, `pkill`,
  `systemctl restart` or `launchctl kickstart` of any kind — not even a `kill -0` probe
  (it needs none: the advance is always `--force --pin-only`, so no branch depends on
  whether a controller is live). On a cell the advance is
  `apply --force --pin-only`: `--pin-only` keeps the scheduler out of `$O` (seeding is
  `start`'s job, and re-seeding under a live loop is the version skew
  `cloud-cell-supervisor.sh` refuses), and `--force` is what `apply` requires before it
  will touch a cell whose controller is live — with `--pin-only` alone it REFUSES, so a
  running cell would never advance. Together they create a NEW per-commit worktree and
  leave the running tree alone: a lane keeps the code it started with, and the restart is
  deferred to the next launch (`harness-refresh.sh`'s recorded design, honoured rather
  than re-decided).
- **THE READINGS ARE PRINTED EVERY PASS**: `head`, `deployed`, `ref`, `behind`, `ahead`,
  `dirty`, `pin`, `pin_tree`, the mode, and then the action. A verdict without the numbers
  behind it is not auditable, and "behind" is the number that was invisible for 91 commits.

## The pin must not lie

A pin is **two** records: `HARNESS-PIN` (a sha) and `.harness-path` (the tree the
controller execs). They can disagree, and a pin that disagrees with its checkout is a
false record of what is deployed — every reader then reports a commit nobody runs
(c1, 2026-10-23: `54bbb0c6` against a tree at `ce987bb2`).

After the move, the pass re-reads both. If the sha record does not name the tree's actual
`HEAD` it **repairs** it (`pin: REPAIRED <old> -> <new>`, exit 10); an absent or empty pin
is **mended** from the same reading (exit 11). `apply` is a no-op when the pin already
names the ref tip, which is exactly the state c1 was in — that is why the repair lives in
the pass and not in `apply`.

## The record, and who reads it

One `key=value` per line, written atomically to
`${HARNESS_APPLY_STATE_DIR:-$HOME/.pi/agent/state}/harness-apply.status`:

```
mode=pin
ok=1
rc=0
epoch=1750000000
at=2026-10-23T05:00:00Z
head=ce987bb2c1de            <- the CHECKOUT (a pin advance never moves it)
deployed=ce987bb2c1de        <- the commit this box RUNS (the pin tree); `behind` is measured from here
ref=ce987bb2c1de             <- equal to `deployed` exactly when `behind=0`
behind=0
ahead=0
dirty=0
pin=ce987bb2c1de
pin_tree=ce987bb2c1de
drift=clean:current          <- the deployed-drift reading, `<state>:<token>` (`executes:<dir>` is the red one)
farm_rows=none               <- `none` (farm matched), `not-graded` (NO USABLE grade), `unwritable` (rows write failed), or the FILE naming every drifting file
farm_n=0                     <- rows the farm grade reported: a COUNT when graded (0 when the farm matched), `not-graded` when no grade was produced, `unparsed` when a RED grade's completeness could not be PROVEN (rows did not match this pass's extractor, or no readable `DRIFT` summary was printed; the artifact's header reads `n=unparsed`; `0` would read as "nothing drifted")
preserved=none
remedy=none                  <- the ACTION for a refusal, never truncated (`detail=` is bounded at 240)
action=none
lanes=none-signalled
fetch=ok                     <- the comparison was FRESH; a failure is rc=23, never `current`
detail=current: the pin tree already names origin/main — head=ce987bb2c1de deployed=ce987bb2c1de ref=ce987bb2c1de behind=0 ahead=0 dirty=0 pin=ce987bb2c1de pin_tree=ce987bb2c1de drift=clean:current
```

`detail` is the verdict sentence **plus the readings appended by the recorder**, so the line
an operator (or the fleet instrument) reads can never carry numbers from before a move.
`fetch=` and `behind=` are the two fields BOTH readers gate on.

⛔ **`farm_rows=not-graded` CANNOT BE TOLD FROM A CLEAN NO-OP BY `action=`.** TWO arms write
`action=none` — a farmless host and a deliberately DISARMED check (`HARNESS_APPLY_FARM_CHECK=0`) —
which is the same value a pass that GRADED the farm and found it clean writes. `farm_rows=not-graded`
is what separates them, and only the journal's `farm: SKIPPED` line says which of the two it was.

⛔ **`farm_rows=` EXISTS BECAUSE A COUNT IS NOT A NAME** (tortoise#10114 arm 2: "a scheduled
check that names *each* drifting file"). The journal keeps a bounded human view — 12 rows, then
"… and N more" — so on a 30-row farm 18 files were counted and named nowhere durable (measured
on the `cmux` cell, 2026-11-07). Every row the instrument reports is therefore written, atomically,
to `${HARNESS_APPLY_STATE_DIR:-$HOME/.pi/agent/state}/harness-apply-farm-rows.txt` — absolutised, so a
relative `HARNESS_APPLY_STATE_DIR` still yields a path another process can open — and the record
names that file.

⛔ **`farm_rows=unwritable` IS A PATH-SPECIFIC REFUSAL, NOT AN UNWRITABLE STATE DIR.** The artifact and
the record are staged in the SAME directory by the SAME technique, so a state dir that refuses writes
fails the RECORD too: the pass exits 23, `write_record`'s staging fails, and the PREVIOUS record
stands — that is a staleness signal, not a field, and it is stated again below. What actually produces
`unwritable` is an artifact path that cannot be **published** while the record can (a directory sitting
at the path, a failed rename). In that state there is no artifact *from this pass* — and whatever an
earlier pass left at the fixed path is untouched, so the record naming `unwritable` is what tells a
reader that the file on disk is not this run's list.

The artifact lives at a **fixed path** and is **self-dating**: its first line carries the UTC
timestamp, ref, dest and row count of the run that wrote it. No later pass deletes it, so a reader
who opens it directly can always tell how old it is — and **`farm_rows=` is the currency
indicator**, not the file's presence: `none` (a graded farm matched) and `not-graded` (no usable
grade was produced — the switch is off, there was **no farm to grade**, a refusal exited first, or
the instrument's rc was unreadable) both mean the list on disk is *not* today's answer. **`action=` is
not the tie-breaker here**: it names the unreadable-rc case (`farm-unknown`) and the pre-flow
refusals, but the DISARMED switch and the FARMLESS host BOTH carry `action=none` — the same value a
clean no-op carries — so on those two the journal's own `farm: SKIPPED — …` line is the only thing
that says which (and a deliberately disarmed farm gate is a P0 condition worth seeing, not a benign
controller-only host). Deletion was tried and removed: it fired on the read-only verbs (`--print-status`,
which the timer installer itself calls), it sat below the seam validations so those refusals still
orphaned the list, and a fixed-path delete can unlink a concurrent pass's just-published file
between its write and its record.

⛔ **A CONCURRENT PASS CAN REPLACE THE FILE THIS RECORD NAMES — READ THE HEADER BEFORE YOU TRUST THE LIST.**
The path is fixed and the publish is a last-writer-wins rename, while the record is written later
(in `finish`, after the deployed readings, ~3–4 s of `check-deploy-drift` later), so a timer tick
overlapping an operator's hand-run can leave pass A's record naming pass A's rows while the file at
that path holds pass B's. The write is atomic (a reader never sees half a list, and no pass ever
removes another's file), but it is **not per-run**, and the header is what you can decide with:

- the header's `ref=` and `dest=` are the **ref name and farm path this record's `detail=` quotes** —
  on the drift arms `detail=` reads `farm: DRIFT — <the arm sentence>; <dest> is NOT the code <ref>
  ships`; the `rc=0`-contradicts-its-report and `rc=0`-with-no-verdict arms read `… for <dest> against
  <ref> …`; and the give-up arm (the instrument's own exit 2) reads `<dest> could not be graded against
  <ref>` — the same two variables either way, in three different sentences (the record has NO `dest=`
  field of its own, and the record's `ref=` is the RESOLVED SHORT SHA, a different value on purpose — do
  not compare those). ⛔ COMPARE ONLY THE CLAUSE THAT QUOTES THEM — the text between `is NOT the code `
  and the end of that clause on a drift arm, or the `<dest> … against <ref>` span on any `farm-unknown`
  arm, whichever sentence that arm prints — because BOTH values sit at the tail that the
  240-byte bound cuts, and the readings `finish` appends AFTER them (`— head=… ref=<checkout sha> …
  drift=…`) carry a `ref=` of their own that is the record's SHORT SHA, not the ref name; a reader who
  greps the last `ref=` compares the wrong token and rejects a correct artifact. Within that clause:
  the visible farm path must be a **prefix** of the header's `dest=`, and the visible fragment after
  `is NOT the code ` **up to the next space** must be a prefix of the header's `ref=` (clip at that
  space: a whole clause reads `origin/main ships — …`, which is LONGER than the ref and is not a prefix
  of it — without the clip the test rejects the very records it exists to accept). WHERE the clause
  breaks cannot be stated as a number: it depends on the ARM SENTENCE's own length (a longer arm starts
  the clause later in the field) and on the farm path, so the ONE property to rely on is that the
  visible part is always a PREFIX of the whole — the clause is either entire or cut from the right,
  never altered in the middle. Compare the visible prefix and nothing else; when the clause is cut, the
  header's `dest=`/`ref=` are authoritative. A `detail=` whose VISIBLE farm or ref
  DISAGREES is a different pass's and is what this rule rejects. (The arm sentence leads `detail=`
  precisely so a truncation can never eat the diagnosis.)
- the header's UTC must **not be later than** the record's `at=` (the artifact is published first,
so a header timestamp *after* the record's own is the one cheap impossibility — compare same-format
strings, both UTC, NOT the header's UTC against the record's `epoch=`);
- the header's `n=` must equal the record's `farm_n=`, **except** when the header reads `n=unparsed`
  — then `farm_n` is `unparsed` (the paragraph below governs), or `not-graded` when the header ALSO
  says `NO GRADE` (the instrument gave up with its own non-0/1/3 code — 2 is the common one — or the
  checker's exit status contradicted its own report; either way the file holds its output verbatim and
  no grade exists, so the header is the field that separates "not graded" from "graded, 2 rows" — see
  the `farm-unknown` paragraph below).

Those rules cannot separate two passes that produced the **same** row count inside this record's own
publish→`finish` window (~3–4 s); nothing in the artifact can, and claiming otherwise is worse than
saying so. What they do rule out is a list published **after** this record was written — a later pass
that died between its publish and its `finish`, leaving its file where this record names it. (A list
published *before* the record is the normal, honest shape: the artifact is stamped at publish time
and `at=` seconds later, which is exactly why rule 2 permits `header ≤ at=` instead of demanding
equality.)

`farm_n=unparsed` on a RED (`action=farm-drift`, `rc=24`) record means this pass's **extractor** could
not PROVE it accounted for every row the instrument reported — the installed `check-farm-drift.sh` is a
copy whose row vocabulary this pass does not know (a farm that lags the ref), so it matched none of
them, only some of them, or the proof itself was absent. The proof used is the instrument's own summary
(`DRIFT — <n> stale …, <n> declared-but-absent, <n> unsourced`), and it cuts BOTH ways: the extraction
is unproven when the extracted rows are **fewer** than that sum, when they are **more** (a widened
vocabulary that names a healthy `ok`/`LOCAL`/`SYMLINK` row), when **no readable summary was printed at
all**, and when **any of the three labels did not parse** (an instrument that says `2 missing` instead
of `2 declared-but-absent` would otherwise reduce the proof to the stale count alone, and certify a
short list as complete) — an unprovable extraction is not a complete one, so "cannot prove it" takes
the same door as "proved it wrong". The proof is also **closed**: a summary that carries a `<n> <label>`
component this pass does not count (a fourth class, `3 not-landed`) makes it unprovable, because the sum
is built from the three labels it knows — an unread fourth class would leave those rows out of numerator
AND denominator and let `2 == 2` certify a list that dropped them. The summary is read from a line with
**no pipe on it** (a row always carries its separators, so a farm file named `3 stale.py` is never taken
for the summary), and it need not carry the instrument's `PROG: DRIFT — ` prefix: a lagging farmed copy
that prints the same three labels on its own summary line still proves or refutes the extraction. Unproven, the artifact carries the instrument's **RAW output** verbatim, with
`n=unparsed` in its header. The DRIFT is still red and still recorded. The names are wherever the
instrument printed them — in that file whenever it published, and in this run's own journal excerpt (at
most the first 12 lines: the rows this pass MATCHED when it matched any, the instrument's own output
when it matched none) only when the publish failed — so the record says "published verbatim" and never
"every one named".

`farm_rows=<path>` with `n=unparsed` is ALSO written when the instrument printed **nothing** for a red
grade: the artifact is a header and **no body line at all** (an empty body writes none — a blank line
would be a stray row for anyone sizing the list with `wc -l - 1`), and the record's `detail=` says so
instead of claiming output was published. That is the one state where a published list can name no
file — because the instrument named none. (A checker that exits 0 printing nothing at all is the same
silence on a different arm: it records `farm_rows=not-graded` and publishes NO file, so "printed nothing"
has one artifact outcome — none — rather than a header-only file claiming an output that never existed.)

`action=farm-unknown` (`rc=24`) is also the answer when the checker's exit status CONTRADICTS its own
report — `rc=0` over a report that names drift. `HARNESS_APPLY_FARM_CHECKER` is a seam, so a wrapper
that reports the *pipeline's* status (`bash inner "$@" 2>&1 | tee -a log`) returns 0 over a drifting
farm; the report wins over the status (the output is published with a `NO GRADE` header and `remedy=`
names the wrapper), because an exit code that contradicts what it printed is not a grade. **`rc=0` is
refused on the `DRIFT —` VERDICT, not on one of its counts** — a summary reading `DRIFT — 0 stale, 2
declared-but-absent, 0 unsourced` is drift in a class a `stale`-only parse does not read, and a checker
whose row vocabulary this pass does not match leaves the row half blind too, so counting `stale` alone
would record `farm: ok` / `farm_rows=none` over two files the farm owes. The instrument prints `OK —` on a
match, so the verdict line by itself is the contradiction. The row half uses the SAME predicate and the
SAME three-label summary proof as the drift arm (one vocabulary, so the guard can never be weaker than
the branch it guards) — and the two halves catch different reports: the row scan refuses a trailing token
the vocabulary does not know, while the summary catches drift a report only TOTALS (no row carries a class
token at all), so a THREE-LABEL `2 stale, 0 declared-but-absent, 0 unsourced` total beside an `rc=0` is a
contradiction on its own. A one-label total is not: `farm_sum_count` requires all three label words (a
single label word in prose is not a summary at all — pinned by the benign-token fixture), so a summary
printing only `2 stale.` is certified, by design. A ZERO total is not one either: a copy printing both
verdict forms over a matching farm says `0 stale, 0 declared-but-absent, 0 unsourced`, and that stays a
match.
**Absence of evidence is not a match either:** an `rc=0` report this pass cannot CLASSIFY is refused,
because every other test on this arm fires only on something it can positively recognise. Two signals,
each named in the journal as an unclassifiable summary or row
(with a `remedy=` pointing at the checker's vocabulary, not at the farm): a pipe-free line carrying two
of the three label words with no parsable total, and a per-file row whose trailing token is neither benign
(`verdict`, `ok`, `LOCAL (declared)`, `SYMLINK (graded via its target)`) nor a class this pass knows —
scanned on any **row** of two or more fields, because a vocabulary that drifts by a suffix (`drift_v2`,
`drift.v2`, `drift:2`, `DRIFTED!`) or a report that prints two-field rows is exactly the class this check
exists for. A row is *a first field that is a path*: the instrument right-pads that field, so
the padding is trimmed first, and a phase line or wrapper tag — `harness-apply: checking farm`,
`12:00:03 harness-apply checking farm`, `[harness-apply] phase two` — has whitespace in it and no `/`, so
it is skipped rather than read as a row; a repo-relative path is a row even when its own name carries a
colon-space (`docs/review: notes.md`), which the earlier prefix test skipped. The skip is a *skip*, not a
stop: a real row further down the report is still scanned. Three boundaries are declared rather than
implied, because the same bytes are read differently either side of them: (i) a field-1 path carrying a
**space and no `/` at all** is read as chatter and skipped; (ii) a **sentence-final** token on a row-shaped
line (`phase | done.`) is refused — `done.` and `DRIFTED!` are the same bytes, so refusing the first is
the price of never certifying the second, which is the fail-closed direction; (iii) a **path-qualified**
program prefix (`/usr/local/bin/harness-apply: checking farm | starting`) carries a `/`, so it is NOT
skipped — it is refused, which is also what the check did before the skip existed, so it is the
fail-closed price of closing (i). An empty verdict field is an unreadable row, not a non-row: a row printed
with a trailing separator (`path | a | b |`) splits to an empty last field and is refused instead of
dropped. The token vocabulary is **closed**, not blocked: anything outside the instrument's own eight
tokens (a drifted class such as `NOT-LANDED2`, a shape such as `N/A`, `DRIFT/2`, `2-drift`, or a lowercase
`stale`) is a report this pass cannot classify, so it is refused rather than certified. One
label word in prose is NOT a summary — a healthy copy that mentions a `stale` entry while matching still
records a proven match. A checker that exits 0 printing **nothing** is refused too — the instrument
prints a summary on every graded run, so a silent exit produced no evidence and is not a match. One
documented flag breaks that on purpose: **`--quiet` suppresses the `OK —` summary** (it is a
`log_line`; the DRIFT summary is `say_err` and survives), so a seam that runs the instrument quiet
cannot certify a match at all — the refusal names the flag in its `remedy=`, because the operator IS
pointing at the instrument and telling them to point harder would not fix it. ⛔ **And output being
non-empty is not a report either:** a match is PROVEN by the instrument's own `OK —` line, so an `rc=0`
whose output carries **no verdict** — the `bash inner "$@" 2>&1 | tee -a log` wrapper whose `inner` is
missing, where `tee` supplies the 0 and the only output is bash's error line — is `farm-unknown`, never
`farm: ok`. Without that, `farm_rows=none` / `farm_n=0` would certify a farm that was never graded and
`--print-status` would answer `status=ok` for it. A wrapper over a genuinely matching farm still passes
(it prints the instrument's verdict), and prose/summary lines are never read as rows — the class token
must END the line, the line must reach the row scan at all (a first field with no whitespace in it, or one
carrying a `/`), and a trailing token outside the instrument's closed vocabulary is what the scan reports. The verdict probes are anchored on the instrument's LINE shape rather than on the bare token, because a
per-file ROW can carry either word — measured both ways: an unanchored `OK — ` certified a match over a
report whose only "OK" was a filename, and an unanchored `DRIFT — ` refused a genuine match whose output
merely mentioned the word. The anchor is **no pipe anywhere on the line** (`^[^|]*: OK — [^|]*$`), not
merely "no pipe before the token": a row's FIRST field is its PATH, so a prefix-only anchor still let
`weird: OK — x.py | … | DRIFTED` certify a match. A verdict line never contains a pipe; a row always does.

`farm_rows=<path>` is ALSO written on `action=farm-unknown` — on all THREE producers: the arm where the
instrument gives up (its own exit 2), the `rc=0`-contradicts-its-report arm, and the `rc=0`-with-no-verdict
arm. All three publish under the same `NO GRADE` header, because a refusal that names nobody is the very
gap this PR closes. On the give-up arm, the
instrument prints its per-file rows BEFORE the exits that give up (`matched == 0`, a partly ungradeable
declaration), so "no grade" never meant "nothing was reported": the file carries that output verbatim
with a `NO GRADE` header, `farm_n=not-graded` still says no grade was produced, and `farm_rows=` stays
`not-graded` only when the instrument printed nothing at all.

`remedy=` carries the instrument's own `Next:` block on ANY refusal that has one — the drift arms and
the give-up `farm-unknown` arm (rc=2), which is the one that often prints it last — and the one actionable text it
prints, which is per class ("re-run the farm", "declare it LOCAL, delete, or retire it", "a deploy
cannot fix this") — so the record never names a defect and leaves nobody an action. A checker that
printed no `Next:` block (a mis-worded farmed copy, or one that died after its rows) makes `remedy=`
say exactly that and name the manual route (`read farm_rows= … and re-run check-farm-drift.sh`), and
`detail=` carries no remedy clause at all (it sat at the end of the bounded field and was cut
mid-word) — `remedy=` is the only place the action appears, and it is never truncated. A checker seam
that cannot be RESOLVED is a refusal of the same kind, with its own action: a link cycle is refused at
40 hops (`break the link cycle`) and a link whose target is gone keeps the "no `check-farm-drift.sh`
could be found" answer — neither is ever executed, and neither is reported as the OTHER one.

`farm_rows=unwritable` means the rows write failed **while the record write still succeeded**. On the
DRIFT arms the drift is still red, `farm_n` still carries the count it had (or `unparsed` when the
extraction was **not proven complete** — a partial match counts here too, not only a total miss), and
the journal says in as many words that the rows are named nowhere durable: with more than 12 rows it
names the cut only (`rows 13..N are named NOWHERE durable`), and with 12 or fewer — where the whole list
was in the excerpt and nothing would otherwise be said — it says the full list could not be persisted and
that the rows above are in this run's output only (a COMPLETE extraction is not exempt: the state that
matters is the failed write, not the elision), plus that a stale artifact from an earlier pass may still
sit at that path. The two states are exclusive: the `N>12` arm owns the cut, the `N<=12` arm owns the
silence, so the journal never prints both and never counts rows it did not print. On
the `farm-unknown` arm (any of the three producers — an instrument that gave up with its own exit 2, an
`rc=0` that contradicts its report, or an `rc=0` that printed no verdict line) the field alone carries it: `farm_n=not-graded`, and the journal prints
only its UNKNOWN line — a checker that printed rows before giving up had them captured, but nothing was
ever excerpted and no artifact was written, so those names are durable nowhere (that is the price of a
failed write on an arm with no grade to justify another one). When the instrument printed nothing at
all, the journal says *that* instead of claiming a raw output could not be persisted. (A state dir that
is unwritable for the record too leaves the PREVIOUS record in place: staleness, not a field, is that
signal.)

⛔ **`detail=` IS BOUNDED, SO IT LEADS WITH THE DIAGNOSIS AND NO SENTENCE INLINES THE ARTIFACT PATH.** The
field is cut at 240 bytes, so *what comes last is what gets lost*: with the farm path first, a 92-char
farm pushed the arm sentence past the bound (`…; RAW output published verba`) and a very long one left
nothing but a path — the record then stated no diagnosis at all. The arm sentence now comes FIRST and
the farm path after it (the artifact's own `dest=` header is the authoritative copy of that path), and
no sentence inlines the artifact path — they all say "see `farm_rows=`", which is the field that
carries the path (or `unwritable`) in the same record. The bound also truncates at a **byte** and used
to land inside a multi-byte character — leaving one invalid UTF-8 sequence that made
`grep '^detail='` classify the WHOLE record as binary and print nothing, so the truncation now stops at
the last ASCII byte (a boundary a multi-byte sequence cannot straddle).

⛔ `deployed` EXISTS BECAUSE THE CHECKOUT IS NOT THE DEPLOYMENT. A pin-per-commit cell
never moves its checkout, so `behind` measured there would be permanently non-zero and
the alarm un-clearable; measured from the deployed commit it is 0 exactly when the box
runs main. The record is written from the FINAL state, never from the readings taken
before the move (a record saying `behind=1` beside `action=advanced` alarms on the pass
that just fixed it).

`harness-apply-pass.sh --print-status` answers "did the last pass succeed", and applies a
staleness bound (`HARNESS_APPLY_STALE_SECONDS`, default 3600 = six cadences): a job that
stopped writing its record is an alarm, not a healthy silence.

⛔ **The Mac's silent failure is now loud on the fleet's own instrument.** `tools/fleet/fleet-health.py`
reads this record on every host — the same section that reads the disk reaper's — and
alarms when `behind>0` **even for a pass that exited cleanly**, because the number is a
reading about the checkout while the exit code is about the pass. A refusal (ahead,
unpreservable dirt) and a stale record alarm too. `fleet-health` exits non-zero on any of
them, so a scheduler can see it.

## Exit vocabulary

Adopted verbatim from `scripts/orchestrator-harness/harness-refresh.sh`, because both
answer the same question in the same fleet and two vocabularies for one fact is the defect
this repo keeps deleting.

| code | meaning | unit colour |
|---|---|---|
| 0 | `current` — the pin already names the ref tip; nothing changed | green |
| 1 | REFUSED `deployed-drift` — the pass itself succeeded, but a live controller is **EXECUTING** a harness tree the box cannot match to this repo (see *Deployed-drift reading* below) | **red** |
| 10 | `advanced` — the materialiser ran and the pin moved (or a lying pin record was repaired) | green |
| 11 | `mended` — the pin was missing/empty; what the box actually runs was recorded | green |
| 20 | REFUSED dirty — the tree carries work that could not be preserved | **red** |
| 21 | REFUSED ahead — local commits are not on the ref's line | **red** |
| 22 | REFUSED diverged | **red** |
| 23 | REFUSED unknown — the ref/repo/HEAD cannot be resolved, the materialiser failed, or the pin record could not be written | **red** |
| 24 | `farm-drift` — the **FARM** (`$CELL_HOME/.pi/agent/scripts`, the directory this box *executes*) differs from the ref, owes files, or cannot be graded (a dangling link, a checker that lives inside the farm, an explicitly-named farm that is absent) — an **absent *default* farm is SKIPPED and the pass stays green**, because only then does "no farm" describe the host rather than the config | **red** |
| 25 | behind, and this box has nothing that can advance it | **red** |
| 27 | REFUSED `split-home` — this pass derives one cell home while the **unit that starts it** (`HOME=`) or the **controller's own unit** (`Environment=CELL_HOME=`) names another, so the pin it would write is not the pin the controller reads. Nothing in the **worktree** is touched — the refusal precedes the dirty-preservation pass and every other write (the `git fetch` that refreshed the ref has already run); it names both homes and the remedy (`cell-home-migrate.sh --check`, then `--apply`). An **explicit `CELL_HOME` is never second-guessed**, and a controller value the pass cannot resolve (`{{CELL_HOME}}` unrendered, a `%h` specifier) or a box with **no controller unit at all** is *cannot-measure*, not a split. `--dry-run` and `--print-status` **never** take this exit: the preview reports `would REFUSE split-home` and stays 0, and the record read reports `split_home=` as a reading | **red** |

⛔ **26 IS NOT FREE** — `harness-refresh.sh` already spends it (`REFUSED blocked`), so `split-home`
takes 27 rather than giving one code two meanings (the ONE VOCABULARY rule above).

A red tick is deliberate: those are states a **human** must resolve, and the unit colour
is the only surface that reaches someone who is not tailing a log.

### Exit 1 — `deployed-drift`

Every other code answers *"did this pass advance the box?"*. Exit 1 answers a different
question, and it is the one `#10114` measured a whole fleet failing on:
**is the code this box EXECUTES the code this repo ships?**

The pass takes one deployed-drift reading per tick, from the final state, by calling
`scripts/orchestrator-harness/check-deployed-drift.sh --surface` and printing its token as
`harness: deployed_drift=<state> token=<token>` (recorded in the `drift=` field).

The checker is DISCOVERED, not assumed, and it is not shipped by the farm — so the search covers
both a deployed box and the scheduler's own environment, first match wins: beside this pass
(`$HERE`), `$AGENT_INFRA_PATH/scripts/orchestrator-harness/`, `$O`, then the governed checkout
(`$REPO/scripts/orchestrator-harness/` — the candidate the systemd unit's environment actually
has, since it exports `HARNESS_APPLY_REPO` and no `AGENT_INFRA_PATH`). When none exists the
reading is `not-run`/`absent` and says so: we cannot verify what we did not run.

Only one token reds a pass this way:

| token | pass result |
|---|---|
| **`executes:<dir>`** — a live controller executes a directory the box does not have | **exit 1**, `action=deployed-drift` |
| `behind:<sha>`, `diverged:<sha>`, `payload-differs`, `uncommitted-edit:<path>`, `incomplete:<path>`, `source-dirty:<sha>`, `surface` | reported in `drift=`, pass stays green |
| `UNKNOWN:` / exit 2 from the checker | reported, pass stays green (`cannot-verify-rc2`) |

Scoped deliberately: the other tokens legitimately describe a developer box mid-edit or a
deliberately-behind checkout, and a check that reds every working box is one operators
learn to ignore. Only a live controller running code the box does not have means
**nothing** the controller does is this repo's code.

⛔ **Exit 1 is not clearable by redeploying.** A redeploy writes a copy at rest; it does not
restart the controller, so the gone tree keeps being executed. The remedy — carried in the
record's own `remedy=` field, untruncated — is: advance the pin
(`bash <resolved>/cloud-cell-supervisor.sh apply --force --pin-only`), then **restart the
controller from the pinned tree**.

⛔ **The command is RESOLVED to a path, not named.** Nothing in this fleet puts
`cloud-cell-supervisor.sh` on `PATH` (`command -v` is empty on a deployed cell; the farm keeps
it beside this pass at `~/.pi/agent/scripts/`), so a bare command name would be
`command not found` on exactly the boxes the red fires on. The pass emits
`bash <path>` for the first of `$HARNESS_MATERIALISER`, `$HERE/cloud-cell-supervisor.sh`,
`$O/cloud-cell-supervisor.sh`, `<repo>/scripts/cloud-cell-supervisor.sh` that exists, and says
`NOT FOUND on this box — set HARNESS_MATERIALISER` when none does — never an implied command
that cannot run.

`detail=` is bounded at 240 characters, which is why `remedy=` and `preserved=` are
separate fields: an operator-needed fact must never be at the mercy of a prose truncation
(measured — the `deployed-drift` sentence is 706 characters and its remedy begins at 272,
so `detail=` alone loses the remedy entirely).

## Install, verify, disarm

Install on a cell (idempotent; a second run is byte-identical and prints `changed=0`):

```bash
bash scripts/install-harness-apply-timer.sh --install
```

Verify it is armed (exit 0 = armed **and** the last pass was healthy):

```bash
bash scripts/install-harness-apply-timer.sh --status
```

Disarm — one verb, no hand-edit of an installed file:

```bash
bash scripts/install-harness-apply-timer.sh --uninstall
# the platform's own fallback if the installer is unavailable:
systemctl disable --now eldato-harness-apply.timer
launchctl bootout "gui/$(id -u)/com.eldato.harness-apply"
```

`--dry-run` is a PREVIEW (renders and prints the artifact, writes nothing, enables
nothing) and is **not** a disarm.

`--status` is the readiness gate, and every leg below is a distinct way a scheduled pass
can be dead while looking alive:

- **not installed** — including the macOS case where the job is LOADED but its plist is
  gone (launchd keeps it loaded; the plist is what returns at the next login);
- **not enabled** — active now, absent after the next reboot;
- **inactive** — an enabled-but-inactive timer is not a schedule;
- **user scope without lingering** — fires while you are logged in and never again;
- **the service's own last exit** — the only witness for a pass that refuses before it
  can write a record (its previous `ok=1` record would otherwise stay fresh for an hour);
- **the pass record** — refusing, stale, dated in the future, `behind>0`, or written from
  a comparison that was not fresh;
- **never having fired at all** past the grace period (two intervals) — on BOTH platforms: a
  job armed for hours that produced no record is inert, not fresh;
- **a comparison that could not be made** — a failed `git fetch` is `cannot-verify`
  (exit 23), never `current` against a stale ref.

A fresh install whose first tick is still running reports `note=…` rather than failing —
the trigger exists immediately (a timer whose `OnBootSec` has elapsed fires at once), so a
pass that has **never completed** is the honest discriminator, not the trigger's presence.

## Install targets

systemd, in this order, with the reason named in the output:

1. a **system** unit via passwordless sudo (`/etc/systemd/system`) — the cell's normal
   shape; the service runs as the invoking user, so the pass writes the lane user's state;
2. a **user** unit (`~/.config/systemd/user`) when the user manager answers — a cell
   without sudo still gets a clock. Lingering is **checked**, because a user timer without
   it fires while you are logged in and never again;
3. nothing — a **loud failure naming the remedy**, never a silent no-op.

macOS has one: a LaunchAgent in the user's GUI domain, started through the checkout's own
interpreter (`pi-reap-worktrees-launchd.py`) because TCC is per-binary — a
launchd-spawned `bash`/`git` cannot read a repo under `~/Documents`, so a `bash` job would
fail closed every ten minutes while `launchctl list` showed it healthy. No usable
interpreter is a refusal at install time.

## Declared limits

⛔ **An agent cannot execute the pass from a dirty checkout, by design.**
`main-worktree-guard` (#709) classifies the dirty-preserving restore — bringing tracked
paths back to `HEAD` from git content — as a REVERT, so `--print-status` and even
`bash -n` are refused from a checkout carrying uncommitted changes. That is the guard
doing its job on a shared checkout: under the scheduler there is no such guard, the
installer calls the pass through its own resolved path (so
`install-harness-apply-timer.sh --status` is unaffected), and an operator with a dirty
checkout can use the documented hatch. The same interaction is recorded for
`scripts/pi-cache-reap.test.sh` in `docs/ops/disk-reaper.md`.

## What this does not do

- **It does not change `apply`.** If `apply` has a defect, that is a separate issue, not a
  silent fix here.
- **It does not restart a controller or a lane.** The advance is pin-per-commit; the
  restart is the next launch's business (`restart-pending` is reported by `harness-up`).
- **It is not a second seeder, stamper or drift detector** — `seed_and_stamp`,
  `harness-refresh.sh` and `check-deployed-drift.sh` keep their jobs.

## Tests

`scripts/harness-apply-timer.test.sh` — 652 assertions, run by the
`harness-apply-timer` shard of `run-bash-shards.sh`:

| | |
|---|---|
| T1 | a box **AHEAD** of main is refused, with the ahead count in the message and in the record; the same fixture **BEHIND** advances (the control) |
| T2 | a **DIRTY** box preserves the modified tracked file and every untracked file BY NAME, names each path, fast-forwards, and leaves the patch + copies where the record says; a *converged* box preserves nothing (no per-tick pile-up) |
| T3 | two installs: `changed=0`, and the service and timer unit bytes are **identical** |
| T4 | a **lying pin** (`HARNESS-PIN` ≠ the tree's HEAD) is repaired to the tree's head; an absent pin is mended from it |
| T5 | a box with **no installable scheduler** exits non-zero, says so, and installs nothing |
| T6 | the pass is a **no-op** when the pin already names the ref tip (`action=none`, HEAD unmoved) |
| T7 | the pass contains **no `kill` of any kind** — no signal, no restart, and no `kill -0` probe either (a plain zero, not a comparison that can pass as 0 == 0) |
| T7b | the advance calls the materialiser with **both** `--force` and `--pin-only` — a stub that enforces the supervisor's own refusal makes a regression that drops either flag go red |
| T8 | an enabled-but-**inactive** timer fails readiness; a record whose `rc` is a refusal fails it too |
| T9 | `--dry-run` moves nothing and reports what it *would* preserve |
| T10 | `--uninstall` disables and removes, and `--status` then reports not-installed |
| T11 | the same verb installs, reports and disarms the **macOS** artifact; no interpreter is a refusal |
| T12 | a unit rendered from **transient scratch** (`/tmp/tmp.XXXX`) is refused — the measured 127-every-tick unit |
| T13 | the cadence seam is validated (`abc`, `0`, `1441` refused); a value that does not divide the hour (7) is kept — the artifact states the cadence it keeps |
| T14 | a **stale** record (including one dated in the FUTURE) is an alarm, a non-numeric staleness bound is refused, and no record at all is `never`, not success |
| T24 | the **FARM** is graded against the ref: stale → **RED 24** naming the file, exit 3 (undeployable) is red too, a matching farm keeps the normal verdict, an **absent** farm is skipped by name while a **dangling** link reddens, an invalid seam value is refused *before* any move, and a checker living **inside** the farm it grades is refused rather than trusted |
| T24r | the **rows artifact**'s own lifecycle: every reported row is written (header + all 20, including the last, which no excerpt can show), an **unwritable** artifact path is recorded as `unwritable` rather than silently dropped, a **clean** and a **not-graded** pass each LEAVE the previous list **with its rows intact** and say so in `farm_rows=` (presence is not the promise — `grep -c .` is asserted beside the planted line, so a pass that TRUNCATES the file reds, which a `[ -f ]` row cannot see) |
| T26 | the materialiser is **TOLD which cell home to pin into**: under the rendered unit's own environment (`env -i`, `HOME` and no `CELL_HOME`) a stub that reproduces `cloud-cell-supervisor.sh`'s defaulting pins under the pass's own root and the farm grade is then reachable (**24**); reverted one edit, the same stub pins into the scratch default and the pass reports **25** "nothing moved this box" — never reaching predicate 4 (agent-infra#3593) |
| T15 | a dirty **tracked symlink** is restored as a symlink, and the clean file it pointed at is byte-for-byte untouched (this repo tracks 34 symlinks; writing the blob through the link corrupted the target) |

| T16 | the pass runs from **the unit's own environment** (`env -i` with only `HARNESS_APPLY_REPO`/`_REF`/`_MODE`/`_STATE_DIR`), asserted on the record's `ref=` — the rendered unit exported names the pass did not read, so every scheduled tick exited 23 while `list-timers` showed it scheduled |
| T17 | the dirty set survives an **executable bit**, a **path with a space**, **three `git mv` renames** (one rename passes even when the destination set is read through a command substitution, which drops NULs) and a **plain `mv`** (which git reports as a deletion + an untracked file, not as a rename), and the checkout is **clean** afterwards; a later upstream commit to a renamed path still merges |
| T18 | **DIVERGED** → 22; a sync verb that exits 0 **without moving the checkout** → 25 (never `advanced`); and the **pin-mode no-op** — a converged pin with a lagging checkout calls the materialiser not at all |
| T19 | the pass runs through the **launchd TCC launcher** (`bash -s`, no `BASH_SOURCE`) with **nothing on stderr** — it used to print "BASH_SOURCE[0]: unbound variable" every tick on the Mac |
| T20 | an **unpreservable** dirty tree is REFUSED (20) and nothing moves — the other half of the DIRTY pair, which had no fixture |
| T23 | a **converged** box needs no materialiser and no sync verb: it is a GREEN no-op (the existence check used to run before the "anything to do?" decision, reddening healthy boxes), while the same box BEHIND without one is a named failure (the control) |
| T21 | a **failed `git fetch`** is `cannot-verify` (23), recorded as `fetch=failed`, refused by `--print-status` — and the same fixture is green once the origin is reachable (the control) |
| T22 | the **user-scope** install (no sudo, user manager answering): it REFUSES when lingering cannot be enabled, succeeds with `linger: enabled` once it can, and `--status` fails when lingering is cleared afterwards |
| T8a | an installed-but-**disabled** timer fails readiness (it will not survive a reboot), and so does `is-enabled=static` (no `[Install]` section: gone at the next boot) |
| T8b2 | the **fresh-install grace is bounded**: a timer armed past two intervals that has never fired and has no record fails readiness — otherwise a silently inert job read as "fresh" for ever |

`tools/fleet/fleet_health.test.py` gained the `HARNESS:` leg for the record reader: no
record without a schedule is not an alarm, a scheduled box with no record is, `behind=91`
alarms on the number, an ahead refusal alarms, and stale / future-dated / epoch-less
records alarm.
