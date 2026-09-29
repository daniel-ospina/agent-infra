# search-guard

Refuses an **unbounded recursive search** over a tree that carries vendored or parallel trees
(`node_modules`, `.worktrees`) and names a bounded replacement. Last line of defence for
[#1069](https://github.com/daniel-ospina/agent-infra/issues/1069): an ignore-blind walk started at a
repo root descends into `.worktrees/*/node_modules` — 169 GB per checkout — and the issue's live
evidence shows three concurrent sessions holding load ~18 on 10 CPUs for 80 minutes.

The other half of the fix is the corpus: `## Search` in `AGENTS.md`, and the rewrite of the **133**
taught `grep -r` sites. The two halves share one invariant:

> **The corpus teaches only primitives the guard allows; the guard refuses only the shape the corpus
> no longer teaches.**

`tests/search-cost/run.sh` asserts both directions through this module's real classifier. The forward
direction alone would be satisfied vacuously by a `classify()` that returns `null` for everything.

## Rules

| Rule | Refuses |
|---|---|
| **R0** | nothing by itself — it is the *command-word locator*: the watched binary must head a command segment, preceded at most by prefix-like words (`sudo`, `env`, `!`, `time`, `timeout`, `stdbuf`, `VAR=`) or shell grouping (`{`, `(`, `then`, `do`) |
| **R1** | a recursive search rooted at `/`, a **home directory**, a **top-level system prefix** (`/Users`, `/home`, `/Volumes`, `/System`, `/Applications`, `/private`, `/etc`, `/usr`, `/var`, `/opt`, `/tmp`, `/bin`, `/sbin`, `/Library`), or a **direct child** of one — cwd-independent, never softened by R5 |
| **R2** | an unbounded recursive `grep -r*` whose root carries `node_modules`/`.worktrees` (at the root or one level down), whose root cannot be resolved statically, or whose glob prefix is not a bounded, vendored-free directory |
| **R3** | the same for `find` |
| **R3p** | the *exemption*: `-maxdepth`, or a `-prune` guarded by a genuinely directory-blocking predicate, bounds the walk — so the literal-prefix/root predicate does not apply. **R1 is never exempted.** |
| **R4** | ignore-defeat flags: `--no-ignore*` for `rg` **and** `fd`, `rg -u`/`-uu`/`-uuu`/`--unrestricted`, `fd -I` (incl. inside `-HI`), `fd -u`/`--unrestricted` |
| **R5** | the *carve-out*: an unbounded `grep -r*` carrying **both** `--exclude-dir=.worktrees` and `--exclude-dir=node_modules` is allowed — evaluated **after** R1, so it can never soften R1 |
| **R6** | the escape hatch: `SEARCH_GUARD_DISABLED=1` (env or command prefix) allows everything |

Blocked commands are **never rewritten** — the guard returns `{ block: true, reason }`, so argv
semantics are never silently changed. The reason always contains a runnable replacement, and the `rg`
line is included only when `rg` is actually available.

## Explicitly out of scope

Allowed through, deliberately, and listed here rather than implied:

- **Recursive payloads:** `sh -c`, `bash -c`, `eval`, backticks, `$()`, `xargs` — unbounded, refused
  as a design boundary.
- **Token obfuscation:** `f""ind`, `\find`, `"find" /`, `${IFS}`, aliases, shell functions defined
  earlier in the call.
- **Word-only wrapper options:** `sudo -u root find /`, `env -i find /`. R0's prefixes are word-only
  except `stdbuf`/`timeout`, whose *declared* value-taking options (including `--signal=VALUE`) are
  parsed.
- **Other walkers:** `du -a /`, `tar`, `rsync`, `python3 -c os.walk('/')`, `node -e`, `perl -e`.
- **A walk outside a vendored root:** a repo with neither `node_modules` nor `.worktrees` at or one
  level below the root is not blocked — there is no amplification to remove. The same applies to a home
  subtree below the top level (`find ~/proj`).
- **Walks initiated from a script file's contents** — only the top-level command string is classified.
- **Sessions where the extension is not loaded:** `--no-extensions`, non-pi harnesses, MCP search
  tools, and a session already running when the extension lands (the module loads at startup — deploy
  lag is expected, not a failure). `check-pi-config-extensions.sh` guarantees farm parity, not liveness.

## Fail-open, declared

`carriesVendoredTrees()` reads directories. A read failure (unreadable root, ELOOP) is a **declared
fail-open to ALLOW** with a `console.warn`: a category-B cost guard must never abort a tool call (the
#879 class). The child scan is bounded (`MAX_CHILDREN = 200`) so a huge directory cannot make the hook
O(n) per command. `tests/search-guard` pins the unreadable-root case.

## Files

- `index.ts` — the rule set. Imports `unquotedMask` / `parseCdChains` / `expandCdTarget` from
  `../shared/git-command-parse.js`, "THE single copy of the git/gh command-parsing helpers" (#966).
  There is no second tokenizer and no second cwd resolver here: the shared module's header records what
  a private copy cost (two copies disagreed on seven input classes; one shipped a fail-open
  root mis-resolution, #960). `test.mjs` pins the import so the copy cannot reappear.
- `test.mjs` — loads the **real** `index.ts` through
  `../main-worktree-guard/module-load-hooks.mjs` and drives the **real** registered `tool_call`
  handler. A suite that imports only a helper stays green while `index.ts` is broken (#744/#697).
  `--classify <command> [--cwd <dir>]` is the entry point the shell harness uses.
