# Independent review — findings and what was fixed (2026-10-14)

Two fresh-context reviews were run. The **first one caught a serious defect in this export's own
first version**; that is recorded here rather than quietly corrected, because the same trap will
catch the next person who edits these prompts.

## 🔴 CAUGHT IN REVIEW #1 — the stall fix used unescaped backticks inside unquoted heredocs

**Severity: would have shipped a prompt that executes commands at build time.**

The agent prompts are built with `cat > "$L-reviewer.txt" <<EOF` — an **unquoted** heredoc, so
command substitution runs. The first version of the stall fix added `\``-free backticks, so:

- `` `uv sync` `` → **executed `uv sync`** every time `merge-one.sh` ran (in the main checkout)
- `` `ls` `` → spliced a directory listing **into the reviewer prompt**
- `` `UNVERIFIED` `` → executed and erased — i.e. the one token the change depended on was deleted
- `` `find` ``, `` `rg` ``, `` `du` ``, `` `mdfind` `` → executed, words lost from the prompt

`bash -n` passes throughout, because it does not expand heredocs — which is exactly why this looks
safe and is not. **Reproduced with command shims**: expansion produced `[SHIM EXECUTED: uv]`,
`[SHIM EXECUTED: UNVERIFIED]`.

**Fixed** by escaping only *unescaped* backticks (regex lookbehind `(?<!\\)\``, so pre-existing
`\`` sequences were not double-escaped), in all three files — `merge-one.sh` 24, `fix-one.sh` 18,
`lane.sh` 18. **Re-verified by real expansion**: 0 shim executions, with `UNVERIFIED`, `uv sync` and
`find` surviving literally in the generated prompt.

> Rule for these files: inside the prompt heredocs, **every backtick must be written `` \` ``.**

## Review #2 — integrity and protocol

All 12 files hash-verified and non-empty. The primitive was exercised against a **local bare repo**
(no shared state touched):

- content-addressed key ✅ · atomic create rejects an existing different ref ✅ · read-back compares
  the remote SHA ✅
- live lease blocks (`rc=1`); expired lease reclaims (`rc=0`); an **unparseable lease is treated as
  LIVE** (fail-closed) ✅
- fencing: stale-owner release **refused**, correct-owner release accepted ✅
- `claim_status`/`claim_snapshot` lookups **match** `claim_ref()` (the `refs/claims/.-<sha>`
  regression is fixed) ✅
- no command injection: refspecs are single argv elements; `merge-one.sh` enforces a numeric PR;
  `orch-loop.sh` gates with `is_num`/`safe_ref` ✅

`merge-one.sh` integration verified: head resolved **before** claiming; a refused claim exits without
spawning a reviewer; the claim is released on every exit path; and the log-truncating redirect runs
**before** the claim evidence is appended (the ordering bug that used to delete the "acquired" line).

## 🟠 P1 — owner identity is not unique, so the CAS token is not guaranteed distinct

`claim_owner()` is `hostname -s` + `$$`. Two acquisitions with the same owner **and the same
`lease_until` second** produce **byte-identical** commits; pushing an identical commit to a ref that
already holds it exits 0 ("up-to-date"), and the read-back then confirms it — so the second acquirer
reports `acquired`.

- **`test-claims.sh`'s headline assertion ("B lost the race") is flaky** for the same reason: both
  clones share `$$` and hostname, so it cannot prove cross-box atomicity on one machine. It passed
  here and **must not be treated as the cross-box proof**.
- Two boxes sharing a hostname (cloned VMs, or the `|| echo box` fallback) would both claim.
- **Not unsafe**: it degenerates to the duplicate execution the design already tolerates, and
  fencing is unaffected (both hold the same SHA — one delete wins, the other is fenced).
- **Fix:** add a random nonce to the claim commit message; give the test a per-box owner override.

## 🟡 P2 / P3

- `claim_snapshot` is not `set -u`-safe when its optional argument is omitted
  (`local out="${1:-…}" tmp="$1.$$"` dereferences unset `$1`). Production unaffected (`orch-loop.sh`
  always passes a path).
- **`divergence.txt`'s earlier "my-edits" column was stale** (bad baseline glob) — superseded; trust
  the patch and the "total delta" column.
- `test-crossbox.sh` is not self-contained: it references a scratch copy of `merge-one.sh` and
  hard-codes this box's clone paths. Point it at `files/merge-one.sh` to re-run.
- `README.md` relies on side-effect idempotency as its fail-open rationale while listing the
  `record-review.sh` idempotency check as *open*. The risk is accepted, not proven — #1709 rec 7.
- A stale `ls-remote` right after push makes `claim_acquire` return 2; the caller then fail-opens
  without holding the claim ref, so its own ref is not released and expires by lease.

## Suites: what actually ran

- `test-gates.sh` — **ran: 10 passed / 0 failed** (offline; extraction of the live `mp_reason` matched).
- `test-claims.sh` — **not run in review** (writes `refs/claims/*` to live origin); additionally
  cannot prove cross-box atomicity on one machine, per the P1 above.
- `test-crossbox.sh` — cannot run as shipped without path adjustment (see above).
- There are **three** test scripts, not four.
