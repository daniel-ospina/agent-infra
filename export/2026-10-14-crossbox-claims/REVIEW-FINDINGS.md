# Independent review of this export — findings (2026-10-14)

Reviewed by a fresh-context sub-agent. Hash/integrity check on all 12 files passed; the patch was
confirmed to round-trip against `files/`. **Verdict: no defect violates the safety invariants
(atomic create, read-back, lease-as-data, fencing) — passing, with the fixes below recommended.**

## P1 — owner identity is not unique, so the CAS token is not guaranteed distinct

`claim_owner()` is `hostname -s` + `$$`. Two acquisitions with the same owner **and the same
`lease_until` second** produce **byte-identical** `commit-tree` objects. Pushing an identical commit
to a ref that already holds it exits 0 ("up-to-date"), and the read-back then confirms it — so the
second acquirer reports `acquired`.

- Breaks **`test-claims.sh`'s headline assertion** ("B lost the race"): both clones share `$$` and
  hostname, so the test cannot prove cross-box atomicity on one machine. **It is flaky, not
  wrong-by-design** — that is why it passed here and must not be trusted as the cross-box proof.
- Two boxes sharing a hostname (cloned VMs/containers, or the `|| echo box` fallback) would both
  believe they own the key.
- **Does not corrupt state** in the documented 3-distinct-box fleet: it degenerates to the
  explicitly tolerated duplicate execution, and fencing is unaffected (both hold the same SHA, so
  one delete wins and the other is fenced).
- **Fix:** add a random nonce to the claim commit message so every object is unique, and give the
  test a per-box owner override.

## P2 — `claim_snapshot` is not `set -u`-safe with its optional argument omitted

`local out="${1:-…}" tmp="$1.$$"` dereferences unset `$1` → `unbound variable` / exit 127.
Production is unaffected (`orch-loop.sh` always passes a path), but it is a latent footgun.

## P2 — the numbers in this export disagree with each other

`README.md` says the "my edits" split is 66 / ~30 / 14 / 27; `divergence.txt` says 12 / 7 / 7 / 7;
the patch itself adds 60 / 54 / 13 / 13. **`divergence.txt`'s "my-edits" column is stale** (it was
generated with a wrong baseline glob) — trust the patch and the "total delta" column.

## P2 — `test-crossbox.sh` is not self-contained

It runs `bash /tmp/merge-one.new`, a file **not in this export**, and hard-codes
`/Users/home/eldato/tortoise`. The README's "end-to-end through the real merge-one.sh" is therefore
not literally what the shipped script does. Point it at `files/merge-one.sh` when re-running.

## P3

- `README.md` is self-contradictory on idempotency: the fail-open rationale relies on side effects
  being idempotent per head, while the open follow-ups admit that verifying `record-review.sh`'s
  marker idempotency is unfinished. The safety argument rests on an unverified assumption.
- `claim_status`'s comment says "every git call uses the cwd" but it uses `CLAIM_REPO`; the ignored
  `repo` positional in `claim_acquire`/`claim_release` is documented only for `claim_status`.
- A stale `ls-remote` advertisement right after push makes `claim_acquire` return 2; the caller then
  fail-opens **without** `CROSS_OWN`, so it never releases its own (actually-held) ref — the lease
  expires it. Fail-open, but it can orphan a claim until expiry.
- `divergence.txt` "FEATURE PRESENCE" scans only the five edited scripts (excluding `claims.sh`,
  where all `force-with-lease` uses live), so `force-with-lease my-box=0` is an artifact.

## Suites: what actually ran

- `test-gates.sh` — **ran, 10 passed / 0 failed** (offline, extraction of the live `mp_reason` matched).
- `test-claims.sh` — **not run here**; writes `refs/claims/*` to live origin, and (per the P1 above)
  cannot prove cross-box atomicity on a single machine.
- `test-crossbox.sh` — **cannot run as exported** (missing `/tmp/merge-one.new`).
- There are **three** test scripts in this export, not four.
