---
title: "#920 — verification-gate O3: the verify loop treats every read failure as a deletion — Implementation Plan"
type: engineering
domain: operations
doc_status: implemented
subjects.team: organisation-design-team
created: 2026-09-14
aboutSubjects: organisation-design-team, verification-gate
aboutObjects: agent-infra, issue-920, issue-917, issue-559
---

# Plan — issue #920: improve the verify-loop read-failure discrimination (O3)

> **Scope signature:** posted on #920 (`<!-- issue-scoping: 2026-09-14 · #920 · the verify loop treats every read failure as a deletion -->`).
> **Base:** worktree `.worktrees/fix-920-vgate-o3-readfail` @ `b3723f5` (= `origin/main`, #1005 merged). The original analysis cited `e95d17b7`; line numbers were re-verified against `b3723f5` and match.
> **Line refs (cycle-1 review P2):** every `:NNNN` below is re-verified against the amended head (`251b55a` + the cycle-1 review fixes). §5's refs were stale (`:2538`/`:2626`/`:2697`) and disagreed with the PR body; the verified numbers are `:2484` and `:2625`/`:2649`/`:2684`/`:2695`.
> **Line refs (cycle-2 review P2-A/P2-B):** the P2-A hardening added ~40 lines around the index probe, so every ref after it moved. Re-verified at this head: verify loop `:3656`→`:3704`; allow sink `:3736`→`:3791`; `indexRecordsContent` `:2861`→`:2904`; `hashAndMergeFiles` `:2948`→`:2996` (per-file catch `:2965`→`:3013`); registration `try` `:3222`→`:3269`; verifier-unparseable refusal `:4010`→`:4055`; outer catch `:4145`→`:4200`; auto-bypass sink `:3727`→`:3782`; `isTaskSubAgent()` at the verify site `:3715`→`:3770`; catch-site comment `:3677`→`:3709`. Unmoved (before the probe): `:179`, `:381`, `:2484`, `:2622`, `:2625`/`:2649`/`:2684`/`:2695`, `:2692`, `:2811`.
> **Adversarial domain:** gate/enforcement code whose correctness is "an attacker cannot make it fail open". Bound = declared threat surface (2 cycles), acceptance = declared classes covered by a test + green CI.
> **Line refs (cycle-4 review P2):** the stderr-parsing probe was deleted and replaced by `git ls-files -z` (no stderr interpretation), removing ~24 lines around the index probe. Re-verified at this head: `indexRecordsContent` `:2904`→`:2880`; verify loop `:3704`→`:3678`; catch-site comment `:3709`→`:3683`; registration `try` `:3269`→`:3244`; `isTaskSubAgent()` at the verify site `:3770`→`:3744`; `hashAndMergeFiles` `:2996`→`:2970` (per-file catch `:3013`→`:2987`); allow sink `:3791`→`:3765`; auto-bypass sink `:3782`→`:3756`. Unmoved (before the probe): `:179`, `:2484`, `:2625`/`:2649`/`:2684`/`:2695`, `:2692`, `:2811`.

## 1. The defect (O3)

In the `tool_call` handler's verify loop (`extensions/verification-gate/index.ts:3704`), each changed file is hashed from its **worktree** copy:

```ts
try {
  currentHash = hashFile(cwd, file);
} catch {
  // File doesn't exist (deleted) — skip verification
  continue;                      // ← fail OPEN for every non-ENOENT errno
}
```

`hashFile` (`:2811-2815`) is an unguarded `readFileSync`. `readFileSync` throws for many errnos, not only `ENOENT`. The bare `catch` cannot distinguish them, so **every** read failure is treated as "the file was deleted," the file is never pushed to `unverified`, and control falls through to `✅ N files verified — allowing` (`:3791`) — for a file the gate never read.

Admitted errno classes:

| errno | trigger | real meaning |
|---|---|---|
| `EACCES` | file (or a restricted parent dir) mode `000` | staged content exists and **will be committed**; unreadable ≠ deleted |
| `EISDIR` | a directory where a file path is expected | scope/parse disagreement; unreadable ≠ deleted |
| `ENOTDIR` | a path **component** replaced by a non-directory (D/F conflict) | **NOT absence** — the index may still hold the staged blob the commit records; discriminate on the index, not the errno (cycle-1 review P1) |
| `EIO` / other | I/O fault | unreadable ≠ deleted |

**Reproduction.** Stage a change to `a.ts`; `chmod 000 a.ts`; fire the commit op. Pre-fix the gate allots the op and prints `✅ … files verified — allowing`, while `git show :a.ts` is non-empty and a bare `git commit` records that unverified staged blob. `chmod 000` is the exploit primitive; before this fix no test in either suite chmodded anything (baseline: zero `chmod` matches in `index.test.ts` / `index.e2e.test.ts`) — scenario 920 below is the first.

### 1.1 Why O3, and not the issue body's N1/N3

#920 declares an adversarial surface and scoped two candidate paths. Read-only verification against `origin/main` shows neither is the live fail-open on this surface:

- **N1** — a single `try` wraps all handler registration (`:3269`); the catch (`:4200`) only logs. This is a **guard-machinery** error, and epic decision **D1** says guard-machinery errors fail **OPEN** with a loud alarm while detected violations fail **CLOSED**. Today's behaviour already complies with D1. **Recorded here as a D1-policy question, not a bug; not changed.** → see §4.
- **N3** (`writeBridge` catch `:381`) and **N4**/verifier-unparseable fail-open refusal (`:4055`) — both already fail **CLOSED**. Not defects.

The genuine uncovered fail-open is O3: a **detected** condition (unreadable staged content) is silently converted into an allow. That is exactly "an attacker can make it fail open". O3 is therefore the correct close for #920's declared threat surface.

**Adjacent path checked and left alone:** `hashAndMergeFiles` (`:2996`) has a bare catch too (its per-file `} catch {` is `:3013`), but it is the **registration** path — a failed hash simply does not record verification credit, so the file stays `unverified` and a later op blocks. That is fail **CLOSED**, not the O3 class. Not a defect.

## 2. The fix — INDEX discrimination at the catch site

```ts
try {
  currentHash = hashFile(cwd, file);
} catch (err: any) {
  // #920 (O3): discriminate on the INDEX — the errno ALONE cannot separate
  // "deleted" (content-free) from "content staged but unreadable" (must block):
  //   • ENOENT — the worktree path is ABSENT. For a `D` row that is a
  //     content-free deletion, so keep skipping: never name-block, never
  //     forever-block (pinned by e2e 49b + 55c + 920(P1)c). For an `A`/`AD`
  //     row this skip IS the deferred #1018 fail-open (§5/§7) — ENOENT does
  //     not stand in for the row type.
  //   • ENOTDIR — a path COMPONENT is not a directory (a D/F conflict) — NOT
  //     proof of absence. Ask the index: an entry ⇒ the commit records content
  //     ⇒ unverified (block); no entry ⇒ a deletion ⇒ skip. (Cycle-1 review P1.)
  //   • ANY OTHER errno (EACCES/EISDIR/EIO/…) — the path EXISTS but could not
  //     be READ; its STAGED content may still be committed. Fail CLOSED by
  //     naming it unverified so the op blocks.
  const code = err?.code;
  if (code === "ENOENT") continue;
  if (code === "ENOTDIR" && !indexRecordsContent(cwd, file)) continue;
  unverified.push(file);
  continue;
}
```

**Why `ENOTDIR` is not "absent" (cycle-1 review P1).** `ENOENT` proves the path is gone; `ENOTDIR` proves only that a path **component** is not a directory. After a D/F conflict (`git add a/b.ts && rm -rf a && echo x > a`) the parent `a` is a regular file while the index **still holds the staged blob at `a/b.ts`** — and a bare `git commit` records exactly that blob. Treating `ENOTDIR` as absent therefore re-opened the same fail-open through another errno; simply DROPPING it from the skip set is not the fix either, because `ENOTDIR` on a genuine `D` row (a deletion whose parent was replaced) must still skip — the project never name-blocks a deletion. The discriminator is the **index**: `indexRecordsContent` (`:2880`) asks it directly — `git ls-files -z -- :(top,literal)<repo-relative-path>`: non-empty stdout ⇒ an index entry exists (stage 0, or an unmerged stage 1/2/3 entry) ⇒ the commit records content ⇒ `unverified`; empty stdout with exit 0 ⇒ no entry ⇒ a deletion ⇒ skip. `:(top,literal)` keeps the path repo-root-relative at ANY cwd (a plain pathspec resolves against a sub-directory `cwd`) and literal (a real file name containing `[`/`*` would otherwise be expanded as a glob) — either mistake empties the listing for a path that IS in the index, i.e. reads an entry as absence. The probe is guarded and **fails CLOSED**: every throwing outcome — 126/127 = git not runnable, a timeout/signal, a spawn failure, a non-zero exit — is ambiguous and routes to `unverified` (cycle-4 review P2: stderr is no longer interpreted at all — below).

**Why exit 128 alone is not absence (cycle-2 review P2-A).** 128 is git's generic `fatal` code, and `git cat-file -e -- :<path>` emits it for **four** unrelated faults: the genuine `path '<p>' does not exist (neither on disk nor in the index)`; `fatal: not a git repository` (cwd outside any repo); `fatal: cannot change to '<dir>'` (cwd missing or unreadable); and `fatal: Not a valid object name` (the index entry EXISTS but its blob object is missing — a partial clone or a corrupt object store). With `stdio: "ignore"` those were indistinguishable. The cycle-1 comment justified "128 ⇒ absent" with a **temporal** argument — "only reachable here inside a repo whose `git diff --cached` for this very op already succeeded" — which is an assumption about *reachability*, not a code guarantee, and it is false for all three non-genuine faults: reading them as "absent" skips a path whose staged content a bare `git commit` still records — the same fail-open, reached through a second 128. The probe therefore **captures stderr** (`stdio: ["ignore", "pipe", "pipe"]`, `encoding: "utf-8"`) and `indexProbeFailureMeansAbsent` (`:2893`, exported for the unit pin) accepts 128 as absence **only** when stderr carries the genuine message; every other outcome — a different stderr, an empty/absent stderr, a non-128 exit, a signal — fails CLOSED and the log names which case it was. Reachability of the demonstrated non-genuine variants was blocked by the empty-allow path, so this is a **hardening** close of an *ambiguous* branch rather than a live exploit — but on this surface an ambiguous 128 must not read as absence. *(Superseded in cycle-4 — this stderr rule was itself unsound; see the next paragraph.)*

**Why the stderr rule was ITSELF unsound — and is now GONE (cycle-4 review P2).** Cycle-2's close was still text interpretation, and git's fatal messages are not a decision surface: **git echoes the probed path**. For a path literally named `does not exist (neither on disk nor in the index)`, git's own echo made `stderr.includes(INDEX_ABSENT_STDERR)` true. The conflicted-index form — `fatal: path '<p>' is in the index, but not at stage 0` — is a 128 that echoes the path and matched, so such a path read as *absent*, the `ENOTDIR` branch `continue`d, and the op was **ALLOWED**: a fail-open counterexample to this section's "every other outcome fails CLOSED" claim, on the declared adversarial surface. Reproduced with real git (new `index.test.ts` pin, RED pre-fix; captured stderr `fatal: path 'does not exist (neither on disk nor in the index)' is in the index, but not at stage 0`). The probe therefore **stops parsing stderr altogether** (`:2880`): `git ls-files -z -- :(top,literal)<path>` — non-empty stdout ⇔ an entry exists ⇔ the commit records content; empty stdout with exit 0 ⇔ no entry ⇔ absent; **every** throwing outcome ⇒ fail CLOSED. `INDEX_ABSENT_STDERR` and `indexProbeFailureMeansAbsent` are **deleted**, and so are their 9 unit tests — a test of a function nothing calls is vacuous. stderr is still captured, for the fail-closed diagnostic log ONLY, and is never matched against.

**Why the other classes differ.** A `D` row commits *nothing* — there is no blob to verify and no drift to detect, so skipping is safe and is the only non-blocking behaviour that keeps legitimate deletions committable. Any other errno describes a path that **still exists in the worktree** with **staged content still pending commit**; the gate's whole job is to refuse to authorize content it has not verified. Reading failure is not deletion, so it must route to the same fail-closed sink (`unverified`) that a missing PASS would. For `ENOTDIR` the index decides which of the two it actually is.

**Why the catch site, not `hashFile`.** `hashFile` is consumed elsewhere (mismatch diagnostics). Changing its contract to a sentinel would push the discrimination problem to every caller. The catch site is the only place that knows the correct action (`skip` vs `block`).

**Why not compare `git status` rows here.** That is the structurally better long-term shape but a larger change touching the producer/consumer seam — it is the **follow-up** (§5), not this minimal close.

## 3. Pinned scenarios that constrain the fix (must stay green — do NOT edit the tests)

Both are `D` rows; both must keep skipping:

- `index.e2e.test.ts` **scenario 49 sub-case (b)** (test ~`:2210`, assertion ~`:2273`): a staged deletion under `git commit -a` must block on the *content* file, and `!resB.reason.includes("src.ts")` requires the deleted row never to be named. Our fix keeps `ENOENT` skipping ⇒ `src.ts` is never pushed to `unverified`. Verified green.
- `index.e2e.test.ts` **scenario 55 leg (c)** (test ~`:2496`, assertion ~`:2564`): force-push over diverged `origin/main` includes a `D` row from the REF tree; the leg asserts ALLOW and no forever-block on the deleted row. Our fix keeps `ENOENT` skipping. Verified green.
- `index.e2e.test.ts` **scenario 920 (P1) leg (b)** (cycle-1 review, `:4203`): `ENOTDIR` on a `D` row whose parent was replaced by a file (no index entry) must still be skipped, never name-blocked. This is the pin that stops the naive "just drop `ENOTDIR` from the skip set" fix — a mutation to that form reds this leg alone (see §6).
- `index.test.ts` **`REAL git: a path in NEITHER the index nor the worktree is ABSENT`** (cycle-2 review P2-A; kept through cycle-4, §6): a genuine absence — empty `git ls-files` output with exit 0 — must still read as ABSENT. This is the unit-side twin of leg (b) — the anti-over-blocking pin that stops the new index question from name-blocking every deletion.
- `index.test.ts` **`REAL git: the probe outside any repo reads as RECORDS CONTENT`** (cycle-2 review P2-A; kept through cycle-4 as the non-zero-exit pin, §6): a non-repo cwd makes **git itself** return a non-zero exit — that must NOT read as absence.

A red on any of these would mean the discrimination is wrong — not the test.

## 4. Decisions recorded

- **N1 — D1-policy question, NOT a bug.** The registration-`try`'s log-only catch is guard-machinery failure, and D1 prescribes fail-OPEN-with-alarm for that class while detected violations fail CLOSED. Today's behaviour already complies. Left unchanged; surfaced for a separate epic decision.
- **N3 / O4 — already fail CLOSED**, not defects. Left unchanged.
- **#7591 third-attempt auto-bypass BOUNDS the "fail closed" claim — pre-existing, NOT introduced here.** A *persistent* primitive (a `chmod 000` file, or a persistent probe fault) produces the SAME blocked set on every attempt, so the third commit attempt satisfies `autoBypassed === allBlockedFiles.length` and ALLOWS, logging `⏩ Auto-bypassed` (`BLOCK_ATTEMPT_THRESHOLD = 3`, `:179`; sink `:3782`). For that primitive the gate is therefore fail-closed on attempts **1–2 only**. This is #7591 policy and is deliberately **not changed here** — do not oversell safety. It applies to **interactive** sessions only: `isTaskSubAgent()` (`:3770`) gets no auto-bypass, so a task child's block is final on every attempt.
- **O1 — `runBranchScope` exec-failure `clean:true` (`:2692`).** Deliberate, documented residual: `docs/plans/2026-09-06-issue-559-vgate-rename-source.md` §1 residual list explicitly pins it — "empty-allow … documented residual §1; the fail-open precedent computeBranchDiff catch→[] — preserved, pinned as residual, **do NOT silently 'fix' to parse-block**" (plan line 50; also lines 33, 96-97). Asserted by e2e scenario 75 leg C. Not touched.
- **O2 — `runStagedScope` (`:2622`).** Same documented rationale (`§1`): worktree exec-failure → logged staged fallback; branch → `{files:[], clean:true}`. Not touched.
- **Invalid-UTF-8 path residual is NOT closed by this fix** — `#559` §1 residual 4 documents that invalid-UTF-8 names (Linux-only) decode lossily to U+FFFD, yielding `ENOENT` → drop → allow. Our discrimination keeps `ENOENT` skipping, so that ENOENT-manifesting residual stays as documented in #559. It is a naming/decoding defect, not an errno-conflation defect.

## 5. Follow-up filed (residual this fix does NOT close)

An **`AD` row** (staged content present, worktree copy genuinely **gone**) still commits its unverified staged blob: the check hashes the **worktree** copy rather than the index blob, and `ENOENT`-skip (correctly preserved for real deletions) also skips this case. Closing it requires hashing `git show :<rel>` for rows whose status says staged content exists. The producers already compute a per-path status map (`parseDiffNameStatusDetailed`, `:2484`) but **drop** it at `:2625`/`:2649`/`:2684`/`:2695` — the four `const { scope, statuses } = parseDiffNameStatusDetailed(out)` call sites, after which `statuses` is consumed by `subtractForArm` and never returned (the `DiffScope` the producer hands downstream carries no status map). So the status information needed to discriminate `D` from `AD` is available and unused. Filed as follow-up **#1018** (see PR body).

## 6. The RED → GREEN tests

**Original #920 test:**

- `scenario 920: unreadable changed file (EACCES, not ENOENT) must BLOCK, never be skipped as deleted` (`index.e2e.test.ts`): stage `unreadable920.ts` content → `chmod 000` the worktree copy → fire the bare commit op → assert `res.block === true` and `res.reason.includes("unreadable920.ts")`.
- `finally { chmodSync(…, 0o644) }` so the fixture can never leak a `000` file into cleanup.
- `chmodSync` added to the existing `node:fs` import.

**Cycle-1 review P1 — new e2e tests** (same file, appended to the queue before the `main()` close):

- `scenario 920 (P1): ENOTDIR from a D/F conflict WITH an index entry must BLOCK …` (`:4171`) — build a D/F conflict on a staged `M` row (replace the parent dir with a regular file) → fire the bare commit op → assert `res.block === true` and that the reason names the D/F child. **RED pre-fix.**
- `scenario 920 (P1): ENOTDIR on a genuine DELETION row (no index entry) must still be skipped …` (`:4203`) — the same D/F shape on a staged `D` row → assert the op is ALLOWED and the deleted path is never named. This pins the *other* branch of the index probe and is what a naive "drop `ENOTDIR` from the skip set" reds.
- `scenario 920 (P1): ENOENT (a genuine deletion) must still be skipped …` (`:4232`) — `git rm` a committed file → assert the op is ALLOWED. The 49b/55c deletion policy, restated locally.

**Cycle-4 review P2 — the stderr rule replaced by an index question** (`index.test.ts`, section `indexRecordsContent — membership comes from the index, never from stderr (#920 P2)`). The cycle-2 test block and its helper were **deleted**: they pinned `indexProbeFailureMeansAbsent` and `INDEX_ABSENT_STDERR`, both of which no longer exist, and a test of a dead function is vacuous — worse than no test. They are replaced by **7 tests, all against `indexRecordsContent` itself**:

- `REAL git: a conflicted-index path NAMED like git's absence message is RECORDS CONTENT (#920 P2)` — **the cycle-4 counterexample**: an unmerged index (stages 1/2/3, no stage 0) at a path literally named `does not exist (neither on disk nor in the index)`. Pre-fix `git cat-file -e` answered 128 with `fatal: path '<name>' is in the index, but not at stage 0`; the echoed path satisfied the substring test ⇒ read as absence ⇒ skip ⇒ ALLOW. **RED pre-fix; GREEN after.**
- `REAL git: a staged index entry reads as RECORDS CONTENT` and `REAL git: a path in NEITHER the index nor the worktree is ABSENT — the skip branch stays intact` — the two positive controls (entry ⇒ block; genuine absence ⇒ skip), so the new probe is neither vacuous nor over-blocking (§3).
- `REAL git: a non-zero exit outside any repo reads as RECORDS CONTENT (fail CLOSED)` and `ambiguous/spawn failure ⇒ fail CLOSED (unanswerable cwd reads as RECORDS CONTENT)` — the two fault classes: git's own non-repo exit, and a `cwd` that cannot be spawned at all.
- `REAL git: glob metacharacters in a real file name are matched LITERALLY` — a real file `a[1].ts` must resolve to its own index entry (`:(top,literal)`), the pin against the glob fail-open.
- `the index probe never substring-matches stderr (#920 P2 structural pin)` — reads the probe's source and asserts `git ls-files -z --` is present and `cat-file`, `includes(…)` and the absence-message constant are all absent from it.

**Evidence:**

| Run | Fix state | Result |
|---|---|---|
| RED (cycle-1 P1) | `index.ts` @ `251b55a` (pre-P1-fix) | `index.e2e.test.ts` → **89 passed, 1 failed** — only `scenario 920 (P1) … WITH an index entry` red (the staged blob was allowed unverified); the two deletion pins green |
| Mutation (non-vacuity) | fix replaced by naive `if (code === "ENOTDIR") unverified.push(file)` | `index.e2e.test.ts` → **89 passed, 1 failed** — only `scenario 920 (P1) … DELETION row` red, so both probe branches are pinned and neither test is vacuous |
| GREEN | P1 fix applied | `index.e2e.test.ts` → **90 passed, 0 failed** |
| Unit | P1 fix applied | `index.test.ts` → **307 passed, 0 failed** |
| Third CI suite | P1 fix applied | `subtract-scope.test.ts` → **49 passed, 0 failed** |
| RED (original #920) | discrimination reverted to bare `catch { continue }` | `index.e2e.test.ts` → **86 passed, 1 failed** — only the EACCES scenario red, with `✅ 1 files verified — allowing` printed; 49b/55c green |
| RED (cycle-2 P2-A) | helper reverted to the pre-P2-A rule (`status === 128 && !signal`, stderr ignored) | `index.test.ts` → **311 passed, 5 failed** — exactly the five non-genuine-128 cases red, including the REAL non-repo probe; the four genuine/staged/exit-code pins green |
| GREEN (cycle-2 P2-A/P2-B) | stderr rule applied | `index.test.ts` → **316 passed, 0 failed**; `index.e2e.test.ts` → **90 passed, 0 failed** (block/skip semantics unchanged) |
| RED (cycle-4 P2) | probe reverted to `git cat-file -e` + `stderr.includes(...)` (cycle-2 helper restored) | `index.test.ts` → **312 passed, 2 failed** — the conflicted-index path-name counterexample red (`indexRecordsContent` read a real, unmerged index entry as absent) **and** the structural no-stderr-matching pin red. Captured real stderr: `fatal: path 'does not exist (neither on disk nor in the index)' is in the index, but not at stage 0` |
| GREEN (cycle-4 P2) | `git ls-files -z -- :(top,literal)<path>`, no stderr matching | `index.test.ts` → **314 passed, 0 failed** (316 − 9 deleted cycle-2 probe tests + 7 cycle-4 probe tests); `index.e2e.test.ts` → **90 passed, 0 failed** (catch-site `ENOENT`/`ENOTDIR`/other-errno semantics identical) |

Suites are run exactly as CI invokes them (`.github/workflows/ci-main.yml:114-127`).

## 7. Blast radius

- Fail-open → fail-closed on the verify path. The new behaviour is a **correct** block when a changed file's worktree copy cannot be read **and the index still holds content for it**. **Bounded by the pre-existing #7591 auto-bypass (see §4):** for a persistent primitive the gate is fail-closed on attempts 1–2 and auto-bypassed on the third; a task sub-agent gets no auto-bypass, so its block is final. "Fail closed" is not an unconditional claim.
- **`AD`-row residual — #1018, still OPEN, and NOT bounded by #7591.** The `ENOENT` skip is *correct* for a real `D` row (content-free) but is taken unchanged on an **`A`/`AD` row** — the index holds staged content, the worktree copy is gone — so that unverified staged blob commits: a plain fail-open this fix deliberately does NOT close (§5). It is the **second** residual and it is named where the first one is: the in-code catch-site comment (`index.ts:3709`) says ENOENT does not stand in for the row type, and the follow-up is filed as **#1018**. Closing it needs index-blob hashing (`git show :<rel>`) keyed off the per-path status map the producers already compute and discard (§5).
- **The probe no longer interprets stderr at all (cycle-4 review P2).** `indexRecordsContent` answers membership from `git ls-files -z`: non-empty ⇒ content, empty-with-exit-0 ⇒ absent, every throwing outcome ⇒ fail CLOSED. The cycle-2 rule ("128 + git's genuine absence message ⇒ absent") was unsound because git **echoes the probed path**; a path literally named after that message satisfied the substring test, and the path-echoing conflicted-index fatal is a 128 — a counterexample to the previous "fail CLOSED" claim (RED pin in §6). `INDEX_ABSENT_STDERR` and `indexProbeFailureMeansAbsent` are deleted with their tests. The `D`-row skip is unchanged (pinned by the REAL-git unit pins in §6 and e2e 920(P1) leg (b)).
- Legitimate deletions unaffected: `ENOENT` always skips, and `ENOTDIR` skips exactly when the index holds **no** entry for the path (a D/F conflict on a deletion) — a deletion is never name-blocked, never forever-blocked.
- No interface change: `hashFile` signature and throw semantics unchanged; `indexRecordsContent`'s contract (`true` ⇔ the index records content at this path) is unchanged, though its implementation and ambiguous-fault handling changed in cycle-4; no producer/gate-routing change.
- Untouched by design: O1, O2 (documented + test-pinned), N1 (D1 question), N3/O4 (already closed).

## 8. Verification checklist

- [x] Scoping comment on #920 (marker on the first content line).
- [x] Fix applied at the catch site; `ENOTDIR` is discriminated on the INDEX, not on the errno (cycle-1 review P1), and the probe fails CLOSED.
- [x] New tests RED before, GREEN after, plus a non-vacuity mutation run (evidence table §6).
- [x] e2e 90/0, unit **314/0** after cycle-4 (316 pre-cycle-4 − 9 deleted cycle-2 probe tests + 7 cycle-4 probe tests), subtract-scope 49/0.
- [x] Pinned 49b + 55c + 920(P1) leg (b) green.
- [x] #7591 residual recorded (§4, §7) and in the PR body — "fail closed" is not claimed without qualification (cycle-1 review P2).
- [x] Follow-up issue **#1018** filed for the `AD` residual.
- [x] **Cycle-2 review P2-A:** the index probe captures stderr and reads exit 128 as absence **only** with git's genuine message; every other 128 fails CLOSED and is logged with git's own first stderr line (§2, §6, §7). No other behaviour changed. *(Superseded by the cycle-4 item below.)*
- [x] **Cycle-2 review P2-B:** the `ENOENT` catch-site comment names the `D` vs `A`/`AD` row distinction and #1018 — `ENOENT` no longer reads as standing in for the row type — and #1018 sits in §7's residual list next to the #7591 caveat (§5, §7).
- [x] **Cycle-4 review P2:** the index probe asks the index (`git ls-files -z -- :(top,literal)<path>`) and never substring-matches stderr; `INDEX_ABSENT_STDERR` + `indexProbeFailureMeansAbsent` and their 9 unit tests are deleted and replaced by 7 tests against `indexRecordsContent` (entry ⇒ content; absent ⇒ absent; non-zero exit ⇒ CLOSED; spawn failure ⇒ CLOSED; the conflicted-index path-name counterexample; glob-literalness; the structural no-stderr-matching pin). Catch-site semantics (`ENOENT` skip / `ENOTDIR` with no entry skip, with entry block / other errno block) unchanged.
