# gui-device-guard (#2249)

A lane may not silently seize the host's camera/microphone.

## The incident

2026-10-21, ~5 minutes before a customer call: Google Meet refused the camera
("something else is using it") and the microphone did not work either. No call
client was running. The holder was a **pi agent lane** — `.worktrees/launch-ping`
ran `npm exec electron .`, launching the DMeer Electron app, which held
`AVCaptureDevice`. **Killing the app did not help**: the live lane relaunched it
within ~15 seconds. Only killing the LANE released the devices. Diagnosis took
six rounds; the decisive read was macOS's *privileged* app list, because
`ps | grep electron` never surfaced it — the argv is
`…/electron/dist/Electron.app/Contents/MacOS/Electron`.

Nothing in the fleet could see it. `tools/fleet/liveness.py`, `fleet_state.py`
and the claim registry answer *"is this lane alive?"*, never *"does this lane's
child own a host device?"*. A lane can be perfectly healthy while making the
owner's machine unable to take a call.

## What this extension does

| rule | when | effect |
|---|---|---|
| **R1 RECORD** | an **unattended** run launches a host GUI app | one row appended to `~/.pi/agent/state/host-app-launches.jsonl` |
| **R2 BLOCK THE MEDIA SHAPES** | an Electron launch (including `electron-forge start`), a **headed** Playwright run, or `open <path>.app` / `open …/Contents/MacOS/<bin>`, without `--use-fake-device-for-media-stream --use-fake-ui-for-media-stream` | the `bash` call is refused, and the refusal names both flags |

R1 is the cheap half and the one that would have cut the incident to a single
lookup. R2 is the load-bearing half: it stops the seizure instead of documenting
it.

**Kinds recorded:** Electron (`electron`, `npx/npm exec electron`, a
`node_modules/.bin/electron`, `electron-forge start`, the `…/Contents/MacOS/<bin>`
shape), macOS `open -a` / `open -b` / `open <path>.app` / `open …/Contents/MacOS/<bin>`,
and headed Playwright/Puppeteer.

**A PATH is a media shape; a NAME is not.** `open ./Build/DMeer.app` — the
incident's own app, launched the way a lane launches the bundle it just built — is
`media: true` and is refused without the fake switches. `open -a Safari` /
`open -b com.apple.Safari` stays `media: false` and is only recorded: refusing
every named-app launch is the category-B friction the scoping comment records as
rejected.

**"Unattended" is DERIVED, not declared** — `shared/print-mode.ts` (print mode)
or `shared/headless-lane.ts` (a headless run in a *linked worktree*). The
answer therefore comes from the process, never from whether a launcher
remembered to export a variable. An **interactive** session is never guarded: a
human typing `open -a Safari` at their own prompt is not this bug.

## Knobs

| variable | effect |
|---|---|
| `GUI_DEVICE_GUARD_RECORD` | ledger path (default `~/.pi/agent/state/host-app-launches.jsonl`) |
| `GUI_DEVICE_GUARD_ALLOW_MEDIA=1` | permit one deliberate real-device launch — still **recorded** |
| `GUI_DEVICE_GUARD_DISABLED=1` | turn the guard off entirely (no ledger, no refusal) |

The ledger is **append-only and not rotated**: one ~250-byte row per host GUI
launch, written only by unattended runs. It is a diagnostic record, not an audit
log — a lane that launches an app 100 times writes 100 rows, and nothing prunes
them. That is a deliberate trade (a rotation scheme that deletes the row you need
is worse than a file that grows by kilobytes), and it is stated here rather than
discovered by whoever finds a large file.

Reading the ledger — the lookup that was missing during the incident:

```bash
jq -c 'select(.media)' ~/.pi/agent/state/host-app-launches.jsonl | tail -20
jq -r '[.ts, .decision, .rule, .app, .cwd] | @tsv' ~/.pi/agent/state/host-app-launches.jsonl
```

⛔ `select(.media)` shows every launch that could take a capture device — Electron,
headed Playwright, and an `open <path>.app`. It does **not** show a named-app
launch (`open -a Safari`), which is recorded with `media: false` on purpose. If you
want every GUI launch regardless, drop the filter: `jq -c '.' …`.

## Wrappers and substitutions are RE-READ, not declared away

`bash -c "<cmd>"`, `sh -c`, `sudo bash -lc`, `flock … -c "<cmd>"`, `eval …`, and
the body of `$( … )` or backticks are **recursed into** (bounded to 3 levels) — the
command string is argv and can be classified. Playwright's `codegen` and `open`
subcommands are headed **by default**, and a `PWDEBUG` exported in an earlier
segment applies to the whole line.

**Wrapper words are prefixes.** `setsid`, `caffeinate`, `arch`, `taskset`, `flock`,
`script`, `chrt`, `unbuffer`, `prlimit`, `numactl`, `builtin`, `busybox`,
`firejail`, `xvfb-run`, `dbus-run-session`, `strace`, `ltrace`, `valgrind`, `gdb`,
`unshare`, `nsenter`, `systemd-run`, `watch`, `fakeroot`, `chroot`, `su` and
`runuser` are recognised as prefixes, and a launch behind one is classified
normally. Before that (`review cycle 3, F1`) they were read as the *command word*,
so the launch behind them produced **no finding at all** — which is not "allow":
the handler returns early on an empty list, so R1 did not record it either and the
diagnosis half of #2249 vanished with the block.

**A nested EXEC-style runner's payload is a launch shape.** The table above
cannot close that class — there is no command database, so a wrapper word it has
never heard of is unrecognisable as a wrapper — but a runner does not need to be
recognised: `npm exec`/`npx`/`pnpm dlx`/`yarn exec`/`bun x`/`mise exec`/`asdf exec`
is itself the announcement that the next word is a program, and it reads the same
behind ANY prefix. So `xvfb-run -a npm exec electron .`, `strace -f npm exec
electron .` and `eatmydata npm exec electron .` are classified without naming
`xvfb-run`, `strace` or `eatmydata` anywhere (L19h/L19i name no wrapper at all),
and `bun x electron .` — `bunx`'s own alias — is classified exactly like
`bunx electron .` (L24a). The **exec verb** is what makes it a launch shape, not
the runner's name: a runner that is only *installing* (`sudo npm install electron
-D`, `bun install electron`) or running a script is not launching anything, so it
stays clean (A13, A36, A41). Reading the runner NAME alone refused both
(`review cycle 6/7, P2-5`).

**A version pin is a lexical suffix, not another program.** `npx electron@30 .`,
`npm exec electron@latest -- .` and `npx playwright@1.50.0 --headed` are the same
launch as their unpinned spellings, so the payload is compared by its **package
name** (`packageBaseName`), not verbatim. All three were `[]` — no block, no
ledger row — because the token was matched against `electron`/`LAUNCH_WORDS`
literally (`round 7, P1-2`, rows L24e–L24g). This is the "two spellings of one
flag must not disagree" rule applied to the payload instead of the flag.

**Two spellings of one flag must not disagree.** Every value-taking option is
closed in both spellings (`--user` as well as `-u`, `--signal=` as well as `-s`,
`--prefix` as well as `-p`), `--flag=value` is treated as self-contained, and a
fail-safe word scan covers a flag nobody has seen yet. That scan is gated on the
prefix having **skipped at least one flag**, or on the command word itself
resolving a runner in EXEC position — the two shapes where a wrapper's grammar can
have swallowed the command word. With no flag between the prefix and the command
word nothing could have been swallowed, so `rg electron .`, `sudo rg electron .`,
`timeout 30 rg electron .`, `timeout 60 grep -rn electron src/` and `npm install
electron` (an install, not a launch) stay clean. Before that gate, the rescue
picked up **any** later word spelled `electron` and refused a search run under
`sudo`/`timeout` — the documented reassurance was true only for the unprefixed
spelling (`round 7, P2-5`, rows A38–A41).

**An argument that EXECUTES is re-read, whoever declared it a value.** `env -S
"<cmd>"` / `env --split-string=<cmd>`, `npm exec -c "<cmd>"` and `npx -c "<cmd>"`
are command strings in argv, so they go to `COMMAND_STRING_FLAGS` — the same table
`flock -c`/`script -c`/`su -c` already use — instead of being consumed as ordinary
values. `env -S` was in the value-flag table and absent from the command-string
table, i.e. two tables disagreed about the same flag; the runner family's
`-c/--call` had no row anywhere. All were `[]`, and the wrapper is looked for at
**any** position, not only token 0 (`sudo env -S "<cmd>"` consumes its whole
segment) — `round 7, P1-3`, rows L25a–L25f, with A34/A35 as the benign twins.

**A standalone shell operator is SEPARATION, not a command word.** `( electron .
&)`, `{ electron . ; }` and `! electron .` are the spaced spellings of the shape
`(npm exec electron . &)` reaches attached: the operator is its own token, it is
dropped, and the launch at index 1 is classified normally. Before that, the token
stripped to `""` and `""` was taken as the command word — **no finding and no
ledger row**, i.e. both halves of #2249 skipped (`review cycle 4, F1`; the guard
failed on the shape *next to* the one it pinned). `( )` and other operator-only
segments hold no launch and are skipped.

**An attached option argument is the same argument.** `bash -c"<cmd>"`
(tokenised as one token, `-cnpm exec electron .`), `sh -c'<cmd>'`, `-lcCMD` and
`flock -c"<cmd>"` are the attached spellings of the same flags and are re-read the
same way; the argument is normalised from the **same** `COMMAND_STRING_FLAGS` table
the separated form reads, so a wrapper added later gets both spellings at once.
`open -a"Google Chrome"` / `open -aDMeer` were the same root on the record-only
rule: **not** refused (a named app is recorded, `media: false`), but not recorded
either — which lost R1, the diagnosis half of #2249 (`review cycle 5, F1`, rows
L21a–L21h).

**`open`'s argument goes to an OPTION LETTER, and a plain word is never a flag.**
`-a<app>`, `-na <name>`, `-bna <id>` are spellings of the same option: a cluster
is a thing for `open` (`open -na "Google Chrome"` is `-n -a`, getopt clustering,
the documented "named app, new instance" idiom), every letter before the option
letter is a bare flag, and everything after it is the argument — or the next word
when nothing follows. The predicate is `clusterShortArg`, the same shape
`attachedShortArg` uses for the shells, and it reports **which letter** took the
argument: `-b` takes a bundle ID, so `-b com.example.app` is an identifier even
though it ends in `.app`, while `-a`/the positional form can name a bundle and a
trailing `.app` there is a media claim (L9f). Two defects lived in the previous inline
copy, in opposite directions (`round 7, P1-1 and P2-4`):

- it never checked that the token **starts with `-`**, so any bare `<Name>.app`
  whose **second letter** is `a`/`b` was read as an attached flag — `open
  Banjo.app` and `open Safari.app` became `media: false`/`decision: "record"` and
  were **allowed**, i.e. a FALSE PASS on the incident's own `open <bundle>` shape
  downgraded by a letter of the app's name, with a mangled identity (`njo.app`) in
  the ledger row. L9d/L9e were green only because their app names spell the second
  letter differently; L23a–L23c now pin both spellings;
- it required the option letter to be the **first** one, so `open -na <name>` was
  `[]` — no ledger row for the canonical idiom, R1's half of #2249 lost — while
  `open -bna com.x` recorded `app: "na"`. L23d/L23e pin the cluster and its
  identity.

**A redirect binds to the SEGMENT IT SITS IN, not to the line's last one.**
`lineFeedsShell` asked about the last segment, so `bash <<'EOF' | tee /tmp/log`
was measured against `tee log` — not a shell — and the body was blanked as data:
**no refusal and no ledger row**, the same double loss rounds 3/4/5/11 treat as
blocking, on the pipeline spelling of the shape round 11 closed for a bare
`bash <<'EOF'`. The redirect's own offset now selects the segment, and the scan
follows pipes FORWARD, because a body a pipe delivers to a shell *is* that shell's
program (`cat <<EOF | bash` must keep firing). A `;`, `&`, newline or `||` ends the
pipeline — EXCEPT an fd duplicate (`2>&1`, `3>&1`), which leaves stdout in the pipe
(`cat <<EOF 2>&1 | bash` runs the body, measured), all of which keeps the body
data when nothing downstream receives it (`round 12`, rows L29a–L29f, A48/A49/A53).

**`electron-forge` is an Electron launch; only its `start` verb is.** Every head
test keyed on the package name `electron` exactly, so `npx electron-forge start` —
the first-party launcher, and what an Electron repo's own `start` script calls —
was `[]`: no refusal, no ledger row. It is distinguishable from a plain `node` run
by its leftmost word, so it was never in the declared residual class (only a
package.json script genuinely is). `start` launches; `package`/`make`/`publish`/
`lint`/`import` do not, so they stay allowed (`round 12`, rows L31a–L31e, A51/A52).

**A bundle's INNER BINARY is a bundle, in both spellings.** `open`'s positional arm
accepted only a `.app` suffix, so `open /Applications/X.app/Contents/MacOS/X` — the
same token the electron rule refuses as a command word — produced NO finding, while
the kind list above already names the `…/Contents/MacOS/<bin>` shape. The ledger
names the BUNDLE, which is what the owner quits (`round 12`, rows L30a/L30b and
their identity twins).

**A `<<` inside a comment is DATA.** The heredoc scanner reads raw lines with the
quote model, and `#` is not a quote character — so a comment merely *mentioning*
the idiom (`# usage: write a file with cat <<EOF`) used to open a heredoc, find no
terminator, and delete every following line: **no block and no ledger row** for the
launch after it. The comment rule is now one helper (`commentCutIndex`) read by
both the comment stripper and the heredoc scanner. The terminator rule itself is
untouched — `EOF # done` genuinely does not terminate a heredoc in `sh`, so the
text after it genuinely is data (A32 pins that side too), and a `<<` inside an
arithmetic expansion (`$(( n << shift ))`) stays declared rather than claimed
complete (`review cycle 5, F2`, rows L22a/L22b).

**A comment begins after ANY bash metacharacter — including `)`.** `commentCutIndex`
kept a hand-written predecessor list (`;&|(`) that was narrower than bash's own
word-start rule, so `(npm exec electron .)# <both fake switches>` read the switches
as ARGV and reported `faked: true` — a **false PASS in the one direction this guard
exists to prevent** — while real bash discarded them:
`bash -c '(echo RAN)# --ignored-flag'` prints `RAN`. It was the identical false PASS
review cycle 2 closed for `;`, left open for one character, and the same gap cost
R1's half too: a commented `<<` after `)` opened a heredoc and deleted the rest of
the input, so the launch was **neither blocked nor recorded**. The predicate now
uses bash's closed metacharacter set (blanks plus `;&|()<>`; GNU Bash manual,
Comments; POSIX XCU token-recognition rule 10) and refuses to call a predecessor a
boundary when it is itself QUOTED or ESCAPED — `echo x\)#c` prints `x)#c`, one word,
so `#` there is data (`round 10`, rows L27a–L27c, A42/A43, and the field pin L11f).

**`command -v` is a lookup, not a launch.** `command` is a prefix word, so the
resolved "command word" was the *looked-up* name and `command -v electron` was
refused — a false block on correct work, which is a defect in its own right
(`review cycle 4, minor`). The query forms (`-v`, `-V`, `--help`, `--version`) do
not execute, so they are not classified and not recorded; `command -p electron .`
still runs and is classified as a launch.

This was review cycle 1's **F2**: those shapes were measured as `[]` (no finding)
while the header claimed completeness, and `bash -c` is a form `AGENTS.md` hands
lanes routinely. Every one of them is now pinned in the suite (L13/L14) with an
ALLOW twin (A10–A12), because a guard that refuses correct work is its own defect.

## Declared residuals — what is STILL not classified

This is a residual list, not a completeness claim:

- `node script.js` that `require("electron")`s, a compiled `.app` started by a
  shell function, `xcodebuild test`, `xcrun simctl` — **not classified**. argv
  cannot tell them from a plain `node` run.
- A command assembled at **run time** is invisible: `find … -exec`, `xargs`, a
  `while read` loop that runs its input, and `node -e`/`python -c` bodies (only a
  literal `-c`-style **command string** is re-read). At the moment this hook sees
  the command those are data, not argv. Same class, same reason: a heredoc body
  fed to a **non-shell** interpreter (`python <<EOF`) and a shell started by a
  **flag** (`sudo -s <<EOF`, `su` with no `-c`). A body fed to a stdin-program
  shell (`bash`/`sh`/`zsh`/… with no `-c`) **is** read, and a body behind `-c` is
  that script's data — L28a–L28h pin both directions, and L29a–L29d pin the
  pipeline spelling (a shell on the LEFT of a pipe is still fed by the heredoc).
- A wrapper word that is **not** in the list above, in front of a launch word
  that is **not** brought in by a package-runner (`systemd-inhibit -w electron .`)
  behaves like a plain command: its own arguments are not scanned. That is the one
  gap the structural rule cannot close — `grep -rn electron src/` and
  `systemd-inhibit -w electron .` are the same two tokens to a parser with no
  command database, so widening further would refuse the search. The list is
  deliberate and finite; adding one is a one-word edit. (`xvfb-run` USED to be the
  example here and no longer is: it is in the list, pinned green as L19d.)
- **Over-fire, declared**: a runner in EXEC position with a flag the table does
  not know, or a prefix that skipped a **flag**, can still rescue a later word
  spelled `electron` — so `sudo -n rg electron .` and an UNQUOTED line that merely
  *prints* a runner launch (`echo npm exec electron .`) are refused. Quoting the
  line (`echo "npm exec electron ."`) is the workaround, and
  `GUI_DEVICE_GUARD_ALLOW_MEDIA=1` waives one run. A miss is not waivable; this is.
  The unprefixed or flag-free spelling of a search is NOT affected
  (`sudo rg electron .`, `timeout 30 rg electron .` — A38–A40).
- A launch built from a shell variable (`APP=Electron; open -a "$APP"`) is
  recorded with the unexpanded name — the shape is kept, the string is not.
- A process started by anything that is not `pi` (`cron`, systemd, a human
  shell) is not seen. The complement is
  [`scripts/orchestrator-harness/media-holders.sh`](../../scripts/orchestrator-harness/media-holders.sh):
  *who holds the device right now*.
- Headless Playwright is **recorded by neither rule** — it cannot present a
  device picker, and refusing every `npx playwright test` is the category-B
  friction `AGENTS.md` has already paid for once.

## Tests

```bash
node extensions/gui-device-guard/test.mjs                    # 229 assertions, threat table L1–L31 + handler H1–H15
node extensions/gui-device-guard/test.mjs --classify 'npm exec electron .'
```

The suite loads the **real** `index.ts` through
`../main-worktree-guard/module-load-hooks.mjs` and drives the **real registered
`tool_call` handler** — the #744/#697 lesson: a suite that imports only a helper
stays green while `index.ts` is broken and the guard is inert in every session.
Mutations are pinned, each attributable to the row it is about, all measured at
ONE head (**this** head — re-measured, not carried over: the counts are the output
of running the mutant against `test.mjs`, and the assertion total is
`229 = 169 ROWS + 7 APP_ROWS + 53 explicit \`check()\` calls`): the Electron
rule's `media` → `false` reds **97**; the wrapper recursion
removed reds **8**; the wrapper WORDS removed reds **2**; the structural rule that
reads a package-runner anywhere in the segment removed reds **2** (L19h/L19i); the
comment stripper removed reds **2** (L11d and L11f — re-measured at this head; the
earlier claim of `1` in this ledger was wrong at every head it was quoted for);
the fail-safe word scan removed reds
**5**; the quote-aware paren scan removed reds **1** (L17); honouring the fake
switches on an `open` line reds **3** (L18b + H3b/H3c); forcing `faked: false`
for the whole `open` rule again reds **3** (L18c, H3d, H3d1 — the `--args` spelling
it refused is a REAL mitigation); refusing to normalise an
ATTACHED short-option argument reds **8** (L21a–L21f, H13, H13a); removing the
`open -a<name>` attached branch reds **3** (L21g, L21h, H13b); reading a commented
`<<` as a heredoc again reds **4** (L22a, L22b, H14, H14a); reverting
`clusterShortArg` to the pre-round-7 single-letter predicate (`tok[1] === "a" ||
tok[1] === "b"`) reds **6** (L23d, L23e and the four identity rows — `njo.app`,
`fari.app`, `na`, `undefined`, so L23a–L23c stay green); refusing a getopt CLUSTER
reds **2** (L23d, L23e); reading a runner's payload
verbatim instead of by package name reds **3** (L24e–L24g); removing `bun` from the
runner set reds **2** (L24a, L24b); dropping the `env -S`/runner `-c` command-string
rows reds **6** (L25a–L25f); ungating the fail-safe word scan from `sawFlag` reds
**4** (A38–A41); reverting the pre-hook's `safeLane()`/`safeCwd()` to the raw
`laneContract()`/`process.cwd()` reds **3** (H15a–H15c, with `ENOENT uv_cwd`);
removing the `.app` suffix from the `open` predicate reds **1** (L9f); dropping `)`
from the comment predecessor set (the round-10 blocking defect) reds **2** (L11f and,
on the heredoc half, L27b — L27a's count/rule/media columns were already satisfied
by the defect, so it is the record-half twin: it reds if the fix over-cuts and
reports nothing); deleting the escape guard that the wider set needs reds **1**
(L27c — without it `x\)#` is cut as a comment and the launch after the `;` is lost);
removing the shell-STDIN recursion (a heredoc/here-string fed to a shell, the
round-11 blocking defect) reds **12** (L28a–L28f and L29a–L29f — the body is
deleted as data, so there is no block AND no ledger row); treating an unquoted
`<<<word` as a heredoc
opener reds **1** (L28h — the phantom heredoc deletes the rest of the input);
reading the body behind `bash -c` as a program reds **1** (A46, the ALLOW twin that
keeps the fix from over-firing on the fleet's own idiom); reverting
`lineFeedsShell` to the line's LAST segment (the round-12 blocking defect — a
heredoc fed to a shell on the left of a pipe) reds **6** (L29a–L29d and A49 plus
A53, which pin the other direction: `cat <<EOF; bash` and `cat <<EOF >&2 | bash`
must stay data); dropping the fd-duplication exception (`2>&1` read as a command
separator) reds **2** (L29e, L29f — measured, and a regression the round-11 code
did not have); accepting only a
`.app` SUFFIX in `open`'s positional arm reds **4** (L30a/L30b and their two
identity twins); dropping `electron-forge` from the electron head test reds **5**
(L31a–L31e).

⛔ **The `<<<`-is-not-a-heredoc guard has no attributable red of its OWN, and is not
claimed as covered on its own.** Dropping it leaves L28g GREEN, because the body
the phantom heredoc swallows is still collected and reaches the recursion; what it
catches is only the NON-shell line (L28h), which is the red the guard owns. It is
disclosed rather than glossed, like the `clusterShortArg` term below.

⛔ **The `-` prefix guard in `clusterShortArg` has NO attributable red, and is not
claimed as covered.** Dropping `!tok.startsWith("-")` reds **0** rows, because a
second term in the same predicate (`/^[A-Za-z]*$/` on the text before the option
letter) already rejects `Banjo.app`, and the faithful pre-round-7 revert above
leaves L23a–L23c GREEN too (a mangled identity still ends in `.app`, so the
`.app`-suffix term keeps `media: true`). It is defence in depth; the rows that
CATCH the class are the identity rows, named in the revert above.

⛔ **`media-holders.sh`'s identity read: F2j is the row the incident verb needed.**
No verdict row can see a COST, so the suite counts interpreter launches through a
stub: 120 innocuous `/dev/null` fds cost **1** launch now, and the per-fd
`realpath` arm it replaced cost **240** (measured on the same 40-pid fixture). F2i
pins the identity read itself on a buildable shape (a same-device node under a
non-matching name is `HELD-BY`, never `FREE`); the root-only twin that needs a
second device node is declared in `docs/ops/media-devices.md` instead of claimed.

⛔ Deleting the `if (cwi < 0) continue;` guard does not print a red row — it makes
the SUITE CRASH (`Cannot read properties of undefined`, from `basename(toks[-1])`),
which is what it did in the wild: any bash call whose segment has no command word
(`FOO=1`, `sudo` alone) threw out of the `tool_call` pre-hook and failed the lane's
command. A25 pins it; a crash fails the row.

⛔ **The pre-hook must be TOTAL, not merely correct.** `laneContract()` reaches
`process.cwd()`, which throws `ENOENT` once the lane's worktree has been reaped;
print mode short-circuits the guarded copy in `isUnattended()`, so the throw landed
in the enforcement path and failed the lane's own bash call while losing both
halves of #2249 (no block, no ledger row). `safeLane()`/`safeCwd()` make both
total: an underivable lane is recorded as "not provably a lane", an unreadable cwd
as `<cwd removed>`. H15's fixture proves the throw is real (chdir into a temp dir,
delete it, `process.cwd()` throws `uv_cwd`); H15a–H15c pin the handler's answer.

⛔ **`-a <bundle>.app` is the same bundle as `<bundle>.app`.** The `-a`/positional
arms now test the `.app` SUFFIX as well as a `/`, which is what the positional arm
and `appBundleBinary` always did — otherwise `open -a DMeer.app` was `media: false`
(recorded, never refused, invisible to the `select(.media)` lookup) while
`open DMeer.app` was refused. The suffix test is **not** applied to `-b`, which
takes a bundle ID and `open -nb com.example.app` legitimately ends in `.app`;
`open -a Safari` stays record-only. Rows L9f, with L9a/L23e as the twins.

## Runbook

[`docs/ops/media-devices.md`](../../docs/ops/media-devices.md) — *kill the lane,
not the app*, and the privileged-app-list fallback.
