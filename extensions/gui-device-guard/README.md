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
the body of `$( … )`, a PROCESS substitution `< ( … )` / `> ( … )` (no space), or
backticks are **recursed into** (bounded to 3 levels) — the
command string is argv and can be classified. Playwright's `codegen` and `open`
subcommands are headed **by default**, and a `PWDEBUG` exported in an earlier
segment applies to the whole line. A `< ( … )` inside DOUBLE QUOTES is literal text
and stays data — unlike `"$( … )"`, which bash does execute. And a single quote
INSIDE double quotes is data to bash, so it must not open a literal run for the
scanner: `echo "it's" "$(npm exec electron .)"` used to skip from the apostrophe to
the quote opening the next argument and swallow the substitution (L34a; A58 pins the
genuinely single-quoted twin as data).

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

**An attached option argument is the same argument — and starts right after its
letter.** getopt stops at the first VALUE-taking letter, so `-aSafari` is `-a
Safari`. Searching the token for the option letter's LAST occurrence searched the
app's own name too and cut it there: `open -aSafari` recorded `app: "ri"`,
`open -aBrave` → `"ve"`, and `open -aBanana` / `open -bcom.apple.Safari` produced no
finding at all — so the whole attached spelling family could lose BOTH halves of
#2249, and one letter of an app's name changed the answer (`round 12`, rows
L44a–L44c and their identity twins). A rest that could itself be `open` flags
(`-na`, `-bna`) still reads as a getopt CLUSTER whose value is the next word, which
is what the P2-4 rows pin. There is no "could be more flags" heuristic on top of that:
the remainder after the first value letter IS the argument, whatever follows it.
`open -anews notes.txt` records `news` and `open -aweb index.html` records `web` —
without that clause the first recorded NOTHING and the second recorded the FILE as the
app (`round 12`, rows L49a–L49c and their identity twins). bash's own `getopts`
settles the remaining case: `set -- -bna com.x` gives `opt=b arg=na`, so the row that
used to pin `-bna com.x` → `com.x` was wrong about getopt and now expects `na` (both
readings record the launch, so nothing is loosened).

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
pipeline — EXCEPT an fd duplicate that LEAVES STDOUT ON THE PIPE (`2>&1`, `3>&1`,
and the no-ops `>&1` / `1>&1`), which is decided by BOTH fds: `N>&M` moves stdout
only when N is 1 or absent and M is not 1, so `cat <<EOF 2>&1 | bash` and
`cat <<EOF >&1 | bash` both run the body (measured) while `>&2` / `1>&2` do not.
Bash's brace form is the same rule with a fresh descriptor: `{fd}>&M` allocates a
NEW fd, so stdout stays on the pipe whatever M is (L38a/L38b).
Every other case keeps the body data when nothing downstream receives it
(`round 12`, rows L29a–L29f, L36a/L36b, A48/A49/A53/A60).

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
their identity twins). A TRAILING SLASH is the same bundle too: tab completion
appends one to a directory, so `open ./Build/DMeer.app/` matched none of the three
shape tests while the `-a` spelling of the same token was refused — it is stripped
before the shape is judged (L30c, and its identity twin).

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
- **Parameter, command and arithmetic expansion inside an UNQUOTED heredoc body** is
  not modelled: the docstring of `unquoteHeredocBackslashes` says so, and only the
  backslash step (`\\`, `\$`, `` \` ``, continuation) is applied. A body whose launch is
  assembled by `$(…)` or `$VAR` inside such a heredoc is beyond a lexer — the same
  class as the expansion-built DELIMITER (`<<$VAR`) already listed.
- A command assembled at **run time** is invisible: `find … -exec`, `xargs`, a
  `while read` loop that runs its input, and `node -e`/`python -c` bodies (only a
  literal `-c`-style **command string** is re-read). At the moment this hook sees
  the command those are data, not argv. Same class, same reason: a heredoc body
  fed to a **non-shell** interpreter (`python <<EOF`) and a shell started by a
  **flag** (`sudo -s <<EOF`, `su` with no `-c`). A body fed to a stdin-program
  shell (`bash`/`sh`/`zsh`/… with no `-c`) **is** read — including its GLUED
  spelling `bash<<'EOF'`, which `tokenize` delivers as one token and which used to
  miss the shell test entirely (L35a) — and a body behind `-c` is that script's
  data. A shell INSIDE a substitution is the same shell: in `x=$(bash <<'EOF' … EOF)`
  the segment's command word is the redirect operator, so the body was blanked as
  data even though bash runs it (L47a, allow twin A70). L28a–L28h pin both
  directions, L29a–L29f and L36a/L36b the pipeline and
  fd-redirect spellings (a shell on the LEFT of a pipe is still fed by the
  heredoc). The DELIMITER is any word with quote removal applied, because bash
  says so: `<<\EOF` (the standard non-expanding spelling), `<<"E-O-F"` and
  `<<E\OF` are the same delimiter as `<<EOF`. Treating only an identifier as a
  delimiter left the body in the parsed line, and one apostrophe in ordinary prose
  then opened a literal run in the quote model — masking every later command
  (L37a/L37b: no refusal AND no ledger row) — while a body that merely DOCUMENTED a
  launch was refused (A61, the direction this file treats as a defect in its own
  right). Quote removal includes the `$'…'` / `$"…"` forms — `<<$'EOF'` is the
  delimiter `EOF`, not `$EOF` (L43a) — and a LINE MAY OPEN SEVERAL HEREDOCS, whose
  bodies arrive in the order the operators appear: `bash <<A; cat <<B` feeds A's
  body to `bash`, so locating only the last `<<` on the line turned the body the
  shell actually executes into data (L42a, A66).
- A REDIRECTION IS NOT A WORD: bash deletes it from the word list, so a leading
  `2>/dev/null` can never be the command word — but it was, and
  `2>/dev/null electron .` / `>/tmp/o.log <bundle>/Contents/MacOS/<bin>` were `[]`
  (no block, NO row) while the runner spelling of the same line fired. A redirect
  GLUED to a flag ends the WORD at the operator, so
  `npx playwright test --headed>/tmp/pw.log` lost the headed run and
  `electron . <both fake switches>/tmp/log` was refused with its own mitigation in
  argv. And the `&` of `2>&1` is not a command separator — splitting there cut the
  launch out of its own segment (`round 12`, rows L50a–L50c, L51a/L51b1, allow twin
  A73). The same strip is applied where the heredoc predicate reads its segment, so a
  leading redirect cannot hide the SHELL that consumes the body either
  (`2>/dev/null bash <<'EOF'` — L52a/L52b).
- A LINE CONTINUATION is joined per line INSIDE the heredoc scanner, so the operator can
  sit on the continued line (`bash \` + newline + `<<'EOF'`, `bash <<<\` + newline +
  `'electron .'` — both hand a body to `bash`, L53a/L53b) while a BODY is never joined:
  a trailing `\` on the last body line of a QUOTED heredoc used to eat the terminator
  and swallow every command after it (L54a/L54b). A continuation at the end of a
  COMMENT is not a continuation — `# note \` + newline + a launch RUNS the launch
  (A74) — and the comment predicate is bash's own set (a `#` glued to `;` or `)` starts
  one too: L55a/L55b), shared with `commentCutIndex`'s rule. ⛔ Those two rows pin the
  BEHAVIOUR, not the predicate in isolation: measured, reverting the shared predicate
  to "previous char is a blank" reds **0**, because `stripComments` — whose rule always
  had the full set — runs before the join on the no-heredoc path. They are regression
  rows for the end-to-end shape (a `#` glued to `;`/`)` must not swallow the launch
  after it), and the predicate stays because it is the rule the SCANNER's per-line
  joiner applies to RAW lines.
- A backslash ESCAPES THE NEXT CHARACTER, so only an ODD trailing run of them continues
  a line: `echo hi \\` is a literal backslash and the line ENDS there — bash runs the
  launch on the next line — while `echo hi \\\` continues into it and makes the launch an
  `echo` ARGUMENT. Taking the last backslash at face value joined the launch into
  `echo` and lost it (`round 12`, rows L57a/L57b, allow twin A77), in both joiners.
- An UNQUOTED heredoc is a DIFFERENT document from the source bytes: bash removes
  `\` + newline and collapses `\\`, `\$` and `` \` `` in it, and — measured — matches the
  TERMINATOR against that text. `<<EOF` … `EO\` + newline + `F` ends the here-document and
  the launch after it RUNS, which the raw comparison did not see: the rest of the
  command, launch included, was swallowed as body (L60). The body the consuming shell
  receives is the COLLAPSED text, so `sh <<EOF` with `echo a \\` hands the shell
  `echo a \` + newline + `electron .`, which its own continuation join turns into one
  `echo` — classifying the raw body over-blocked that (allow twin A79). A QUOTED
  delimiter keeps both properties of a literal document: no collapse, no joining, and
  `EO\`+`F` is NOT its terminator (allow twin A80).
- The continuation lines a join CONSUMES are not re-emitted. Re-emitting them duplicated
  a fragment that could carry a lone quote — and a duplicated closing quote changed how
  the rest of the command read, losing the launch after it (L58) — and the quote model
  is consulted at the JOINED text's own offsets, so a `<<` past a join seam is not read
  as an operator by accident (L59; allow twin A78, where `<<EOF` with no command
  discards its body and nothing runs).
- A LINE CONTINUATION (`\` + newline) is NOT a command separator: bash deletes it
  before word splitting, so
  `npm exec electron . \` + `--use-fake-device-for-media-stream --use-fake-ui-for-media-stream`
  is one argv and the mitigation applies. Splitting on the newline put the launch and
  its switches in different segments, which REFUSED the mitigated launch (the refusal
  printed the very remedy the lane had already written) and dropped both halves for
  `npx playwright test \` + `--headed`. Inside SINGLE quotes it stays literal text,
  and a `\` at the end of a COMMENT is not a continuation — both pinned (`round 12`,
  rows L48a–L48c, allow twins A71/A72).
- A CONTROL-FLOW WORD sits where a command word would, and the list is bash's
  grammar, not a heuristic: `until`/`select` join `if`/`while`/`do`, so
  `until electron .; do break; done` no longer answers `[]` while `while` fires
  (L46a/L46c, allow twin A69). A grouping `(` glued to a token AFTER such a keyword
  is normalised too (`if (npm exec electron .)` — L46b).
- A bash METACHARACTER GLUED TO A TOKEN IS NOT PART OF THE WORD: `tokenize` splits
  on whitespace only, so `(open ./Build/DMeer.app)` carries the `)` on its last
  token — and every exact-token predicate (`.app` suffix, the bundle regexes, the
  headed flags, the fake-capture switches) compared against the glued spelling.
  Bash strips the parenthesis (`bash -c '(open X.app)'` passes `X.app` as `$1`), and
  so does the guard: trailing metacharacters are removed once, at tokenize time,
  which fixes both directions in one place — a miss (`(open X.app)`,
  `(npx playwright test --headed)` → no block AND no row) and a FALSE BLOCK on
  working work (`(electron . --use-fake-… --use-fake-ui-…)` was refused instead of
  recorded as mitigated) (`round 12`, rows L40a–L40c, A64, L11b1).
- A wrapper **in** the list whose bare OPERAND is a `sh -c` script is re-read:
  `watch -n 1 "electron ."` was `[]` (no block, no row) while the UNQUOTED spelling
  fired, although `watch --help` states the default is `sh -c` and a real run
  executes the operand (`round 12`, row L45a, allow twin A68) — and the wrapper is
  looked for at ANY position, so `timeout 30 watch …`, `sudo watch …` and
  `env FOO=1 watch …` are read too (L56a–L56c, allow twin A76).
- A wrapper **in** the list takes its own leading POSITIONAL before the command
  (`flock FILE CMD`, `taskset MASK CMD`, `chrt PRIORITY CMD`, `script FILE CMD`,
  `chroot ROOT CMD`),
  and that positional is skipped rather than read as the command word — otherwise
  `flock /tmp/l.lock electron .` and `taskset 0x3 electron .` were `[]` (no block,
  no ledger row) while the runner spelling of the SAME wrapper fired, even though
  `flock`/`taskset` run the payload either way (measured with a stubbed `electron`
  on PATH; L39a–L39e). When the fail-safe word scan runs for such a wrapper it
  starts at the payload, so a wrapper that only LOOKS like it takes a positional
  cannot swallow the launch.
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
  (`sudo rg electron .`, `timeout 30 rg electron .` — A38–A40), and neither is a
  wrapper's positional on its own (`flock /tmp/l.lock ls` — A63). The one addition
  from the positional fix: a SEARCH behind a positional-taking wrapper
  (`flock /tmp/l.lock rg electron .`) is now refused, because skipping the
  positional means the word scan has to run and it cannot tell that payload from a
  launch. Same trade, same waiver.
- A `case … in` PATTERN body is not resolved: the pattern's `)` is indistinguishable
  from a command boundary once metacharacters are stripped, so `case x in x) electron
  .;; esac` can read as a miss. (`until`/`while`/`if`/`select` bodies ARE read — they
  have no per-branch pattern grammar.)
- **Over-fire, declared**: an UNQUOTED heredoc body whose last line ends with `\`
  swallows the terminator in bash (so the following line is BODY, not a command), while
  the guard still reads it as a command and may refuse it. Modeling that needs the
  body-expansion rules of an unquoted heredoc; the direction is over-fire, which is
  waivable, unlike a miss.
- A launch built from a shell variable (`APP=Electron; open -a "$APP"`) is
  recorded with the unexpanded name — the shape is kept, the string is not. The
  same limit reaches a heredoc DELIMITER built from a variable (`cat <<$X`), because
  bash expands that word before matching the terminator: the guard keeps `$X`
  literally, so it cannot find the terminator and the rest of the input is treated as
  body. Static quoting (`<<'X'`, `<<\X`, `<<$'X'`) IS resolved — only expansion is
  not.
- A process started by anything that is not `pi` (`cron`, systemd, a human
  shell) is not seen. The complement is
  [`scripts/orchestrator-harness/media-holders.sh`](../../scripts/orchestrator-harness/media-holders.sh):
  *who holds the device right now*.
- Headless Playwright is **recorded by neither rule** — it cannot present a
  device picker, and refusing every `npx playwright test` is the category-B
  friction `AGENTS.md` has already paid for once.

## Tests

```bash
node extensions/gui-device-guard/test.mjs                    # 323 assertions, threat table L1–L60 + handler H1–H15
node extensions/gui-device-guard/test.mjs --classify 'npm exec electron .'
```

The suite loads the **real** `index.ts` through
`../main-worktree-guard/module-load-hooks.mjs` and drives the **real registered
`tool_call` handler** — the #744/#697 lesson: a suite that imports only a helper
stays green while `index.ts` is broken and the guard is inert in every session.
Mutations are pinned, each attributable to the row it is about, all measured at
ONE head (**this** head — re-measured, not carried over: the counts are the output
of running the mutant against `test.mjs`, and the assertion total is
`323 = 252 ROWS + 14 APP_ROWS + 57 explicit \`check()\` calls`): the Electron
rule's `media` → `false` reds **142**; the wrapper recursion
removed reds **8**; the wrapper WORDS removed reds **4** (L45a + L56a–L56c); the structural rule that
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
round-11 blocking defect) reds **23** (L28a–L28f, L29a–L29f, L35a/L36a/L36b/L37a/L38a/L42a/L47a, L52a/L52b,
L53a/L53b —
the body is deleted as data, so there is no block AND no ledger row); treating an unquoted
`<<<word` as a heredoc
opener reds **1** (L28h — the phantom heredoc deletes the rest of the input);
reading the body behind `bash -c` as a program reds **1** (A46, the ALLOW twin that
keeps the fix from over-firing on the fleet's own idiom); reverting
`lineFeedsShell` to the line's LAST segment (the round-12 blocking defect — a
heredoc fed to a shell on the left of a pipe) reds **7** (L29a–L29d plus A49, A53
and A60, which pin the other direction: `cat <<EOF; bash`, `cat <<EOF >&2 | bash`
and `cat <<EOF 1>&2 | bash` must stay data); dropping the fd-duplication exception
entirely (`2>&1` read as a command separator) reds **6** (L29e, L29f, L36a, L36b —
measured, and a regression the round-11 code did not have), while the narrower
pre-fix rule (keyed on the LEFT fd only) reds **2** (L36a `>&1`, L36b `1>&1`);
accepting only a `.app` SUFFIX in `open`'s positional arm reds **6** (L30a–L30c and
their three identity twins); ungating the single-quote skip from the double-quote
state reds **2** (L34a — one apostrophe in `echo "it's"` hid every later `$( … )` —
and A58, which the pre-fix code refused); dropping the glued-heredoc split reds
**1** (L35a, `bash<<'EOF'` with no space); dropping the trailing-slash
normalisation reds **2** (L30c and its identity twin); reverting the heredoc
DELIMITER grammar to the pre-fix identifier-only regex (`<<\EOF` and `<<"E-O-F"`
stop being heredocs, so their bodies are parsed as argv) reds **4** (L37a, L37b and
the two ALLOW twins A61/A67 — the mis-read now over-fires on a body that is data); dropping the `{fd}` term from the fd-duplicate rule reds
**1** (L38a — `{fd}>&2` allocates a NEW descriptor, so stdout stays on the pipe);
dropping the wrapper POSITIONAL skip reds **4** (L39a–L39c and L41a — `flock FILE`,
`taskset MASK`, `chrt PRIORITY`, `chroot ROOT`), and starting the fail-safe scan AFTER the resolved
word instead of at the payload reds **1** (L39e); dropping the TRAILING-metachar
strip reds **4** (L40a–L40c and L11b1 — a glued `)` is a bash metacharacter, not a
word character); dropping `chroot` from the positional table reds **1** (L41a);
locating only the LAST heredoc on a line reds **1** (L42a — `bash <<A; cat <<B`
feeds A's body to `bash`); and dropping `$'…'`/`$"…"` from the delimiter's quote
removal reds **1** (L43a); reverting the ATTACHED-option rule to `lastIndexOf(letter)`
reds **5** (L44b, L44c and the three identity twins — `-aSafari` recorded `app: "ri"`
and `-aBanana` found nothing); dropping `watch`'s command operand reds **1** (L45a);
dropping `until`/`select` from the control-flow words reds **1** (L46c); dropping the
leading `(`/`{` normalisation reds **1** (L46b); and dropping the substitution unwrap
in `shellExecutesStdin` reds **1** (L47a); not joining LINE CONTINUATIONS reds **3**
(L48b, L48c, L48a1 — the mitigated launch was refused with its own remedy already
written, and the continued headed run lost block AND row); treating an attached `-a<name>` as a
cluster reds **7** (L44b, L44c, the corrected P2-4 identity and four identity twins);
NOT removing redirects from the word list reds **5** (L50a, L50b, L51a, L51b1 — a
leading redirect became the command word, and a redirect glued to `--headed` or to the
fake switches hid them); splitting on the `&` of `2>&1` reds **1** (L50c); NOT stripping redirects in
`lineFeedsShell` reds **3** (L35a, L52a, L52b — the redirect became the shell's
command word, so a body the shell runs was blanked as data); joining continuations
AFTER the heredoc scan reds **5** (L48b, L48c, L48a1, L53a, L53b); joining over the WHOLE
command again (instead of per line inside the scanner) reds **2** (L54a/L54b — a
trailing `\` in a QUOTED body ate the terminator); disabling the scanner's per-line
join reds **2** (L53a/L53b); dropping the escape-PAIR parity from the whole-command
joiner reds **2** (L57a/L57b) and from the per-line joiner alone reds **1** (L57b);
re-emitting the consumed continuation lines reds **2** (L58/L59); reading the quote
model at the RAW line's base instead of the joined text's offsets reds **1** (A78);
matching an UNQUOTED heredoc's terminator against the raw line again reds **1** (L60);
dropping the `\\`/`\$`/`` \` `` collapse from an unquoted body reds **1** (A79); and
joining a QUOTED body — or failing to notice that its delimiter was quoted — reds
**3** (L54a/L54b, A80);
and reading `watch`'s operand from token 0 again reds **3**
(L56a–L56c); dropping `electron-forge` from the electron head test reds **5**
(L31a–L31e); removing the PROCESS-substitution arm (`<( … )` / `>( … )`, the
round-12 review's second P2) reds **3** (L32a–L32c, and A55 stays green because the
double-quoted spelling never was a substitution); dropping the inner-binary term from
the electron arm reds **1** (L33a — `Contents/MacOS/DMeer` as a COMMAND WORD, the
spelling `open` already refused).

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
