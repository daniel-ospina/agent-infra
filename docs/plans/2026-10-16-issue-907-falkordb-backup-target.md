---
title: "Plan: agent-infra#907 — the FalkorDB backup target is resolved from the port it publishes"
type: engineering
domain: operations
doc_status: live
subjects.team: organisation-design-team
created: 2026-10-16
aboutSubjects: organisation-design-team
aboutObjects: agent-infra-907, daily-backup, restore-smoke, falkordb-16379, fail-loud-preflight, partial-fix
---

# Plan — agent-infra#907 → `scripts/daily-backup.sh` resolves its target

> Status: **shipped on `feat/907-tm` (PR #1886)**. The code and its hermetic suite landed in
> commit `32cade47`; this doc was added by the follow-up fix pass as the
> plan/evidence record `pipeline-compliance` check (d) requires for a
> `complexity:standard` issue (the same role the sibling
> `docs/plans/2026-10-16-issue-1341-pi-patches-positional-proof.md` plays).
> Refs: agent-infra#907 (the issue), agent-infra#101 (the script's origin),
> tortoise#6666 (the `::1` decoy this change refuses to back up by accident).

## Confirmed problem

`scripts/daily-backup.sh` shipped a **hard-coded container name**:

```bash
CONTAINER="${CONTAINER:-falkordb-personal}"
```

No container by that name exists on the machine — the one publishing host port
16379 is `falkordb-16379`. The header advertised "RPO ≤ 24h", so the guarantee
was stated and **not in force**, and two literals that had drifted apart had
nothing able to notice (#907). The failure was measured with a `docker` shim
whose only container is `falkordb-16379`:

```
Triggering BGSAVE on falkordb-personal...
Error response from daemon: No such container: falkordb-personal   -> exit 1
```

and it was **not** a clean failure: an empty `backups/<timestamp>/` was left
behind, and `restore-smoke.sh` picked the **newest** directory under `backups/`,
so the empty directory became "the newest backup" and blocked verification of a
**good** older one (`No dump.rdb in …`). One failed backup disabled the check of
the last good one.

## Root cause

Two independent defects with one shape — an unproven assumption turned into a
verdict:

1. **The target was a literal, not a fact.** A container name is not derivable
   from anything the script checks; the port the graph publishes is. Naming the
   container made drift undetectable, and the script exited 0 over the wrong
   graph whenever a same-port container existed.
2. **Failure left state that read as success.** The run created the backup
   directory before the copy, and nothing removed it on failure, so "newest
   directory" — the selector `restore-smoke.sh` used — was not "newest
   backup".

There is also a **pre-existing abort** on the documented emergency path: in the
BGSAVE wait, `$lg_rc` was read where it had never been assigned (one `if`/`elif`
pair spanning two guards), so `LOAD_GATE_FORCE=1` died at the first iteration
with `lg_rc: unbound variable` under `set -u`. The emergency bypass could not
complete a backup at all.

## Considered alternatives

| Approach | Verdict |
|---|---|
| Keep a container literal, add a second literal | **Rejected** — that is the drift itself; two literals with nothing to compare them is the reported defect, not a fix. |
| Resolve the name from the port it **publishes** (`docker ps --filter publish=$REDIS_HOST_PORT`) | **Chosen** — the one fact that cannot drift; `CONTAINER=<name>` remains the explicit human override. |
| Resolve by image name / label | Rejected — the image tag is not pinned anywhere in this repo, so the comparison would be just as unverifiable. |
| Pick the first of several publishers | **Rejected** — >1 publisher on the port is a refusal that names every candidate, because 16379 is also where the near-empty `::1` decoy can appear (tortoise#6666) and backing up the wrong graph exits 0. |

## Change

- `scripts/daily-backup.sh`: `resolve_container()` (port-resolved, ambiguity
  refuses loudly, `CONTAINER` overrides); `preflight_container()` (`docker
  inspect` + a bounded `PING`) runs **before any state exists**; `on_exit` trap
  removes an incomplete backup directory (no `manifest.json`) on any failure; the
  `$lg_rc` unbound-read abort is fixed; the header states the RPO claim is
  **conditional** on an external scheduler instead of implying a guarantee.
- `scripts/restore-smoke.sh`: `newest_backup_dir()` selects the newest directory
  that actually holds a `dump.rdb` — the independent second half of the same
  guard, so an interruption that skips the cleanup (SIGKILL, power loss) cannot
  re-create the false FAIL.
- `.gitignore`: `backups/` — an RDB dump of the fleet's graph was one `git add`
  from a public repo.
- `scripts/run-bash-shards.sh`: registers `scripts/daily-backup.test.sh`, so both
  CI lanes run it (`check-ci-lane-parity` stays green).

## Wiring

| Touch point | Type | Covered by | Status |
|---|---|---|---|
| `docker ps --filter publish=$REDIS_HOST_PORT` | external service (Docker) | `resolve_container()`; shim-driven in `daily-backup.test.sh` | ✅ |
| `docker inspect` + `redis-cli PING` preflight | external service (Docker/Redis) | `preflight_container()`; refusal cases tested | ✅ |
| `backups/<ts>/` + `$HOME/backups/tortoise/<ts>` | data store (filesystem) | `on_exit` removal of incomplete dirs; both roots tested | ✅ |
| `restore-smoke.sh` newest-backup selection | cross-script consumer | `newest_backup_dir()` extracted from the **shipped** file and tested | ✅ |
| `.gitignore` `backups/` rule | repo config | throwaway-git-repo test + non-vacuity check (source not ignored) | ✅ |
| `scripts/run-bash-shards.sh` shard list | CI wiring | `bash scripts/check-ci-lane-parity.sh` | ✅ |
| Scheduling the script on a ≤24h cadence | **machine infra — NOT covered** | deliberately out of scope; see Residual | ⚠️ |
| Named volume / `appendonly yes` on the container | **machine infra — NOT covered** | deliberately out of scope; owner-gated | ⚠️ |

## Verification

The suite is hermetic: a `docker` shim, a throwaway `HOME`, and the shipped
script copied under its own repo root, so no real container is touched and no
artifact lands in the checkout.

```
bash scripts/daily-backup.test.sh       -> 53 passed, 0 failed
bash scripts/check-no-sigpipe-grep.sh   -> clean (136 files)
bash scripts/check-ci-lane-parity.sh    -> clean, 28 shards, 2 sweep targets
bash -n scripts/*.sh scripts/checkout-hygiene/*.sh   -> clean
```

It covers resolution, the ambiguity refusal, the `CONTAINER` override, the
PING/stopped refusals, "nothing written" on every refusal, removal of an
incomplete directory, the exit-2 artifact being **kept**, `--keep` validation,
the `.gitignore` rule, and the newest-restorable-backup selection.

### Non-vacuity

The pre-fix tree fails the defect pin: with the shipped `daily-backup.sh`
reverted to `CONTAINER="${CONTAINER:-falkordb-personal}"` and no preflight, the
resolution/refusal cases fail against the shim (the shim publishes only
`falkordb-16379`), and the pre-fix `restore-smoke.sh` selector picks the empty
newest directory and reports the false FAIL the change removes.

## Residual (named, not hidden)

- The container still has **no named volume** and `appendonly no`.
- The script is still **not scheduled**, so "RPO ≤ 24h" is not in force; the
  header now says so instead of implying it.
- The off-box copy is still the **same disk** (`$HOME/backups/tortoise`) — a real
  off-box destination needs a remote and credentials.
- Recreating the container would destroy the surviving points (the issue thread
  says so) and is a fleet-wide change needing the owner, so the repo-owned third
  is fixed here and the machine third is left visible rather than worked around.
