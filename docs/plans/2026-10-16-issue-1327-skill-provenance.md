---
title: "#1327 — skill-enforcer: a SKILL.md forged inside a trusted root still satisfies a gate"
type: engineering
domain: platform
doc_status: draft
created: 2026-10-16
subjects.team: organisation-design-team
aboutSubjects: organisation-design-team
aboutObjects: agent-infra
---

# #1327 — skill-enforcer: a SKILL.md forged INSIDE a trusted root still satisfies a gate

**Level:** task · **complexity:** standard · **Class:** A (a gate an agent can *defeat*, silently
fail-open) · **Supersedes:** the "T7 residual" declared out of scope in
`docs/plans/2026-09-21-issue-1321-1322-skill-enforcer-gates.md`.

## Problem (re-measured on `main` @ `6ce6e274`, not taken from the issue body)

`canonicalSkillName()` anchored a read to a trusted root + a known shape, so an unanchored
`/tmp/evil/skills/<n>/SKILL.md` was refused (#1321/T7). It never checked that the file **is** the
skill. Every trusted root is agent-writable — `<cwd>/skills`, `<cwd>/operations/skills`,
`<cwd>/.agents/skills`, `<cwd>/.pi/skills`, and `~/.pi/agent/skills` wherever it is writable — so:

```
mkdir -p <repo>/skills/commit-workflow && echo anything > <repo>/skills/commit-workflow/SKILL.md
```

then reading it cleared the `git commit` gate, while the banner kept reporting
`✅ enforcing 4 skill gates`. Reproduced end-to-end before the change (forged read ⇒
`blockedAfter = false`).

## Decision

**A gate is satisfied only by the skill agent-infra ships.** The canonical bytes live in
`REPO_DIR/skills/` — the same trust anchor `resolveManifestPath()` already uses for the manifest
itself — and the farm path is **pinned at module load** (`CANONICAL_SKILLS_RESOLUTION`), exactly as
`MANIFEST_PATH` is. A read registers a skill name only when the file read is that canonical file:

- the same **inode** (`dev`+`ino`, which covers a symlink and a hard link), or
- the same **bytes** (which covers the folder-copy machine `sync.sh` produces).

Every legitimate layout is one of those: `~/.pi/agent/skills` is a symlink to the farm (or a
folder copy), consumer repos hard-link or directory-symlink the farm into `operations/skills/`
(`scripts/link-skills.sh`), and the farm path itself is the farm.

Identity is matched on the path **relative to the skill root the read matched under**, so
`skills/reviewers/<n>/SKILL.md` maps to `<farm>/reviewers/<n>/SKILL.md` and a consumer's
`operations/skills/<n>/SKILL.md` maps to `<farm>/<n>/SKILL.md`.

### Alternatives rejected

| # | Approach (from the issue) | Why not |
|---|---|---|
| A | Content-hash each skill into a recorded manifest-of-hashes | The hash list is itself a file; unless it lives in an operator-owned root it is forgeable, which reduces to this same design with an extra file that goes stale on every skill edit (a stale hash = an unsatisfiable gate = a fleet block). |
| B | Trust only operator-owned **roots** for gate satisfaction | `~/.pi/agent/skills` is a symlink to the farm but is also user-writable, and on the legacy registry layout it is a directory of per-skill links — root membership alone cannot tell a link to the real skill from a forgery *in* the root. Identity is strictly better: it refuses the forgery **and** accepts a legitimate consumer hard link that a root check would refuse. |
| C | Resolve through the registry (#1323) | `skill_registry.py` does not exist in agent-infra and the extension's lookup is broken (that is #1323). The farm *is* the registry's source of truth (`~/.pi/agent/skills` → `$AGENT_INFRA_PATH/skills`); depending on a broken component would trade a working anchor for a broken one. |

## Fail-closed when the anchor is missing

No farm at load ⇒ **no read can satisfy any gate** ⇒ every armed gate blocks, with an
unconditional `❌` on stderr and a `failed` health entry naming the cause. This is deliberately
*not* the missing-manifest verdict (#1321: nothing is armed, so there is nothing to block, and
failing closed there would deny all git use on a broken load). Here something **is** armed and
there is no honest way to satisfy it — and a shape-only fallback would be exactly the
`mkdir && read` bypass being closed. It cannot brick a working machine: `REPO_DIR` is the real
module location (the hub in the deployed symlink layout), whose `skills/` is git-tracked and
`essential: true` in `manifest.json`, and the manifest already depends on the identical sibling-or-
`AGENT_INFRA_PATH` resolution — so a host where the farm is unreachable is a host where the gates
are already not armed. The block reason names the `SKILL_ENFORCER_DISABLED=1` escape hatch.

## Declared residuals (bounded, not chased)

1. **An agent that can write the operator's canonical farm can satisfy any gate** by editing the
   skill there — inherent to *any* in-repo anchor, and strictly weaker than the bypass already
   available by editing `enforcement/dangerous-ops.txt` (which disarms the gates outright). Farm
   write-protection is `main-worktree-guard`'s job, not this extension's.
2. **A byte-identical copy of the canonical skill satisfies the gate, by design.** The claim is
   "the skill's instructions reached the model's context"; a copy that is read puts exactly those
   instructions in context. A look-alike, or canonical bytes plus one other byte, does not.
3. **The 24 h persisted-read window is unchanged** (#7416 by design; #1331 owns it). #1327 narrowed
   it to "the entry must name a skill the farm ships" and dropped the dependence on a *shaped* file
   existing anywhere — a hand-written `skill-reads.json` naming a real skill still restores on its
   own word, pinned as a boundary test.

## Tests — `extensions/skill-enforcer.test.ts` (45 → 56, 0 failing)

The suite now builds a hermetic **deployed** layout: `main()` swaps `process.env.HOME` to a fixture
HOME whose `~/.pi/agent/skills` is a real directory of per-skill symlinks into the farm (the
legacy-registry shape, and the shape that lets a leg plant a forgery **next to** the real skills).
`npm_config_cache` is pinned so the fixture HOME cannot make `npx tsx` download the runner.

New load-bearing legs: forged SKILL.md refused at each of the four shapes; forged SKILL.md refused
*through the pi-served path*; a name the farm does not ship refused; canonical bytes + one byte
refused; hard link / directory symlink / byte-identical copy accepted; the same forgery-and-control
pair end-to-end through the gate handler; and the deployed-loader farm (`--preserve-symlinks`)
refusing the forged read while the real read clears the same gate.

RED re-derivation (`git show HEAD:extensions/skill-enforcer.ts > /tmp/pre-fix-1327.ts`, then
`SE_TEST_MODULE_SRC=/tmp/pre-fix-1327.ts npx tsx extensions/skill-enforcer.test.ts`): the deployed
forged-read leg and the missing-farm leg both fail, and the pre-fix module logs a *successful*
`📖 commit-workflow read (manifest)` for a forged file. (The pre-fix `T1` leg also fails, as always
under this seam: the seam's module lives outside the repo, so its `MODULE_DIR` is not
`REPO_ROOT/extensions`.)
