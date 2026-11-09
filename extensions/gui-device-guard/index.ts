/**
 * gui-device-guard — a lane may not silently seize the host's camera/microphone
 * (#2249).
 *
 * ── THE INCIDENT THIS EXISTS FOR ────────────────────────────────────────────
 * 2026-10-21, ~5 minutes before a customer call: Google Meet refused the camera
 * ("something else is using it") and the microphone did not work at all. No call
 * client was running. The holder was a **pi agent lane** — `.worktrees/launch-ping`
 * ran `npm exec electron .`, which launched the DMeer Electron app; the app held
 * `AVCaptureDevice`, and **every time the app was killed the live lane relaunched
 * it**. Only killing the LANE released the devices. Diagnosis took six rounds,
 * and the decisive read was the macOS *privileged* app list — `ps | grep electron`
 * never surfaced it because the argv is
 * `…/electron/dist/Electron.app/Contents/MacOS/Electron`.
 *
 * Nothing in the fleet could see it: `tools/fleet/liveness.py`, `fleet_state.py`
 * and the claim registry answer *"is this lane alive?"*, never *"does this lane's
 * child own a host device?"*. A lane can be perfectly healthy while making the
 * owner's machine unable to take a call.
 *
 * ── WHAT THIS GUARD DOES (and deliberately does not) ────────────────────────
 * Two rules, one cheap and one load-bearing:
 *
 *   R1 RECORD. An unattended run (print mode, or a linked-worktree lane — the
 *      `isPrintMode`/`laneContract` pair, so the answer is derived from the
 *      process and not from who launched it) that launches a host GUI app writes
 *      ONE row to the app-launch ledger
 *      (`~/.pi/agent/state/host-app-launches.jsonl`, override
 *      `GUI_DEVICE_GUARD_RECORD`). Kinds: an Electron invocation (including
 *      `electron-forge start`), a macOS `open -a`/`-b`/`.app` launch or `open` of
 *      a bundle's inner binary, an executable inside `…/Contents/MacOS/`. The
 *      ledger is the whole point of R1: with it, the incident above is one
 *      `jq` lookup instead of six rounds of `ps`.
 *
 *   R2 BLOCK THE MEDIA SHAPES ONLY. A GUI launch is refused when it can open a
 *      REAL capture device and nobody asked for a fake one: an Electron
 *      invocation, or a HEADED (`--headed`/`--ui`/`--debug`/`PWDEBUG`) Playwright
 *      run, that does not carry BOTH
 *      `--use-fake-device-for-media-stream --use-fake-ui-for-media-stream`.
 *      The refusal names the two flags. A headed-vs-headless distinction is
 *      drawn on purpose: headless Playwright cannot present a device picker, and
 *      blocking every `npx playwright test` would be the category-B friction
 *      this repo has already paid for once.
 *
 * ── WRAPPERS AND SUBSTITUTIONS ARE RE-READ, NOT DECLARED AWAY ───────────────
 * `bash -c "<cmd>"` and its ATTACHED spelling `bash -c"<cmd>"`, `sh -c`,
 * `sudo bash -lc`, `eval …`, and the body of
 * `$( … )` / a process substitution `< ( … )` / `> ( … )` / backticks are RECURSED
 * INTO (bounded to 3 levels), because the
 * command string is argv and can be classified. Review cycle 1 (F2) found these
 * were an UNDECLARED bypass of R2 while the header claimed completeness — and
 * `bash -c` is a shape `AGENTS.md` hands lanes routinely. Playwright's `codegen`
 * and `open` subcommands are headed BY DEFAULT, and a `PWDEBUG` exported in an
 * earlier segment now applies to the whole line.
 *
 * ── DECLARED RESIDUALS (what is still NOT classified, stated plainly) ────────
 * The list below is what a wrapper-recurse CANNOT reach; it is a residual list,
 * not a completeness claim.
 *   - `node script.js` that `require("electron")`s, a Swift/ObjC helper, a
 *     compiled `.app` started by name through a shell function, `xcodebuild
 *     test`, and `xcrun simctl` launches are NOT classified. argv cannot tell
 *     them apart from a plain `node` run; inventing a heuristic there would
 *     block correct work.
 *   - A command assembled at RUN time is not visible: `find … -exec`, `xargs`,
 *     a `while read` loop that runs its input, and `node -e`/`python -c` bodies
 *     (only a literal `-c`-style SHELL string is re-read). Those are DATA, not
 *     argv, at the moment this hook sees the command. The same class covers the
 *     two spellings a heredoc/here-string fix cannot reach: a body fed to a
 *     NON-shell interpreter (`python <<EOF`) and a shell started by a FLAG
 *     (`sudo -s <<EOF`, `su` with no `-c`) — neither resolves a stdin-program
 *     SHELL as a command word. A body fed to `bash`/`sh`/`zsh`/… IS read (round
 *     11), INCLUDING when that shell sits on the LEFT of a pipe (`bash <<EOF |
 *     tee log` — round 12; the redirect binds to its own segment, because
 *     `lineFeedsShell` used to ask about the line's LAST segment and answered
 *     "not a shell" for `tee`), and a body behind `-c` is that script's DATA
 *     (A46).
 *   - A GUI launch built by a shell variable (`APP=Electron; open -a "$APP"`) is
 *     not expanded: the token is `$APP` and the guard records it as an `open`
 *     launch with the unexpanded app name. Recording the SHAPE is still worth
 *     more than the exact string.
 *   - The heredoc DELIMITER is any word with quote removal applied (`<<\EOF`,
 *     `<<"E-O-F"`, `<<EOF` are the same), because that is bash's rule — a
 *     delimiter that is not recognised leaves its body in the parsed line, which
 *     is how one apostrophe in prose used to hide every later command.
 *   - A WRAPPER WORD the table above has never heard of, in front of a launch
 *     word that no package-runner introduces (`systemd-inhibit -w electron .`) is
 *     not classified. This cannot be closed structurally: with no command database,
 *     `grep -rn electron src/` and a wrapped bare launch are the same token
 *     shape, so widening further would refuse the SEARCH. The list is deliberate
 *     and finite — one word to add — and a runner-nested launch is caught behind
 *     ANY wrapper (`xvfb-run -a npm exec electron .`), which is the shape a lane
 *     actually writes.
 *   - Declared OVER-FIRE: an UNQUOTED line that only PRINTS a runner launch
 *     (`echo npm exec electron .`) is refused, because a runner anywhere in the
 *     segment counts. Quoting it is the workaround, and `ALLOW_MEDIA=1` waives one
 *     run — an over-fire is waivable, a miss is not. The same trade applies to a
 *     SEARCH behind a positional-taking wrapper (`flock /tmp/l.lock rg electron
 *     .`): the wrapper's own positional is skipped (round 12, so `flock FILE
 *     electron .` is no longer `[]`), which means the word scan has to run and it
 *     cannot tell that payload from a launch. A positional on its own stays clean
 *     (`flock /tmp/l.lock ls` — A63).
 *   - The guard is a `tool_call` pre-hook on pi's `bash` tool. A process started
 *     by something that is not pi (`cron`, a systemd unit, a human shell) is not
 *     seen. The host-side read is `scripts/orchestrator-harness/media-holders.sh`
 *     — it answers *who holds the device now*, which is the complement of this
 *     file.
 *
 * ── WHAT THIS GUARD MUST NEVER DO ───────────────────────────────────────────
 * It must never refuse an INTERACTIVE session. A human typing `open -a Safari`
 * at their own prompt is not the failure mode; treating it as one is. So the
 * whole guard is gated on `isUnattended()`, and `GUI_DEVICE_GUARD_DISABLED=1`
 * turns it off entirely.
 *
 * Design rules pinned by `test.mjs` (threat rows L1–L12): command-word location
 * (a watched word must HEAD a segment, optionally behind a prefix-like word or an
 * `A=B` assignment), quote-aware segmentation (a mention inside quotes is not a
 * launch), the fake-capture mitigation, the escape hatch, and the ledger row
 * shape. The guard's return value is pi's `{ block: true, reason }` — the same
 * contract `search-guard` and `main-worktree-guard` return.
 */

import { appendFileSync, mkdirSync } from "node:fs";
import { homedir, hostname } from "node:os";
import { dirname, join } from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { isToolCallEventType } from "../shared/tool-call-event.js";
import { isPrintMode } from "../shared/print-mode.js";
import { laneContract } from "../shared/headless-lane.js";
import { unquotedMask } from "../shared/git-command-parse.js";

/** The two Chromium switches that make a capture API use a synthetic device. */
export const FAKE_DEVICE_FLAG = "--use-fake-device-for-media-stream";
export const FAKE_UI_FLAG = "--use-fake-ui-for-media-stream";
export const FAKE_FLAGS_HINT = `${FAKE_DEVICE_FLAG} ${FAKE_UI_FLAG}`;

export const KILL_SWITCH = "GUI_DEVICE_GUARD_DISABLED";
export const ALLOW_MEDIA = "GUI_DEVICE_GUARD_ALLOW_MEDIA";
export const RECORD_ENV = "GUI_DEVICE_GUARD_RECORD";

/** Default ledger path — one row per host GUI-app launch, append-only. */
export function defaultRecordPath(): string {
  return join(homedir(), ".pi", "agent", "state", "host-app-launches.jsonl");
}

/**
 * Words that sit where a command word would. Their own declared value-taking
 * options are consumed (see `PREFIX_VALUE_FLAGS`); everything else is a
 * word-only prefix, so `sudo -u root electron .` still finds its command word.
 *
 * ⛔ This is NOT `search-guard`'s residual. There, an unparsed prefix costs an
 * unrefused expensive search; here it is a BYPASS — a one-word prefix would
 * walk an Electron launch past the only guard that stands between a lane and
 * the owner's camera. So the value-taking flags are closed by name, and the
 * cost of a flag this table does not know is an over-read of the NEXT word as
 * the command (which can only make the guard MORE likely to fire, not less).
 */
const PREFIXES = new Set([
  "!", "time", "sudo", "doas", "nohup", "command", "env", "exec",
  "nice", "ionice", "stdbuf", "timeout",
  // ⛔ A WRAPPER IS A PREFIX EVEN WHEN THE TABLE HAS NEVER HEARD OF IT (review
  // cycle 3, F1). `setsid`, `caffeinate`, `arch`, `taskset`, `flock`, `script`,
  // `chrt` … were classified as the COMMAND WORD, so the launch behind them was
  // invisible — and an empty finding list is not "allow": the handler returns
  // early, so R1 did not RECORD it either, losing the diagnosis half of #2249 as
  // well as the block. The tell, again: `env FOO=1 caffeinate npm exec electron .`
  // fired (env is a prefix ⇒ the word scan ran) while bare `caffeinate …` did not.
  "setsid", "caffeinate", "arch", "taskset", "flock", "script", "chrt",
  "unbuffer", "prlimit", "numactl", "builtin", "busybox", "firejail",
  // The next tier are the wrappers a LANE actually reaches for: a virtual
  // display (`xvfb-run`), a tracer/debugger in front of the app, a namespace
  // entry, a session bus, a user switch. Same tell as above — each was read as
  // the command word, so `xvfb-run npm exec electron .` produced NO finding and
  // therefore no ledger row either (#2249's diagnosis half).
  "xvfb-run", "dbus-run-session", "strace", "ltrace", "valgrind", "gdb",
  "unshare", "nsenter", "systemd-run", "watch", "fakeroot", "chroot",
  "su", "runuser",
]);

/**
 * The value-taking options of the prefixes above, per GNU/BSD's own grammars —
 * SHORT AND LONG SPELLINGS ALIKE.
 *
 * ⛔ A MISSING ENTRY HERE IS A FAIL-OPEN, NOT AN OVER-READ (review cycle 2, F1).
 * The comment above claimed "the cost of a flag this table does not know is an
 * over-read of the NEXT word as the command (which can only make the guard MORE
 * likely to fire)". That was FALSE, and measurably so: an unknown flag is skipped
 * ONE word, so the flag's VALUE became the command word and the launch was never
 * classified. `sudo -u root electron .` fired while `sudo --user root electron .`
 * returned `[]` — the same flag, two spellings, opposite coverage. `man7.org`'s
 * `timeout(1)` supplies the long forms below; the rest are the tools' own.
 */
const PREFIX_VALUE_FLAGS: Record<string, string[]> = {
  sudo: ["-u", "--user", "-g", "--group", "-p", "--prompt", "-C", "--close-from",
    "-D", "--chdir", "-h", "--host", "-r", "--role", "-t", "--type",
    "-U", "--other-user", "-R", "--chroot", "-T", "--command-timeout"],
  doas: ["-u", "-C"],
  nice: ["-n", "--adjustment"],
  ionice: ["-c", "--class", "-n", "--classdata", "-p", "--pid"],
  env: ["-u", "--unset", "-C", "--chdir", "-S", "--split-string"],
  stdbuf: ["-i", "--input", "-o", "--output", "-e", "--error"],
  timeout: ["-s", "--signal", "-k", "--kill-after"],
  caffeinate: ["-t", "-w"],
  arch: ["-arch", "-e", "--arch"],
  taskset: ["-c", "--cpu-list", "-p", "--pid"],
  chrt: ["-p", "--pid"],
  prlimit: ["-p", "--pid", "-n", "--nproc", "-c", "--core", "-f", "--fsize"],
  numactl: ["-i", "--interleave", "-m", "--membind", "-N", "--cpunodebind",
    "-C", "--physcpubind", "-p", "--preferred"],
  flock: ["-w", "--wait", "--timeout", "-E", "--conflict-exit-code"],
  script: ["-t", "--timing"],
  firejail: ["--profile", "--net", "--ip"],
  // ⛔ `su`/`runuser` deliberately do NOT declare `-c` here: `-c` is the
  // COMMAND-STRING flag handled by `COMMAND_STRING_FLAGS` below. Declaring it as
  // a value flag would consume the command string as an ordinary argument, leave
  // no command word at all, and turn a launch into nothing.
  "xvfb-run": ["-n", "--server-num", "-s", "--server-args", "-f", "--auth-file", "-e", "--error-file"],
  strace: ["-o", "-e", "-p", "-s", "-u", "-E"],
  ltrace: ["-o", "-e", "-p"],
  valgrind: ["--tool", "--log-file", "--suppressions"],
  gdb: ["-x", "--eval-command", "-iex", "-cd"],
  nsenter: ["-t", "--target", "-r", "--root", "-w", "--wd"],
  "systemd-run": ["-u", "--unit", "-p", "--property", "--description", "-E", "--setenv"],
  watch: ["-n", "--interval"],
  chroot: ["--userspec", "--groups"],
  su: ["-s", "--shell", "-g", "--group"],
  runuser: ["-u", "--user", "-g", "--group", "-s", "--shell"],
};

/**
 * Flags whose ARGUMENT is a COMMAND STRING (the shell's `-c`, `flock -c`,
 * `script -c`). The parser used to special-case `bash -c` only; a `flock … -c
 * "npm exec electron ."` was therefore invisible (review cycle 3, F1).
 *
 * ⛔ AN ARGUMENT THAT EXECUTES IS RE-READ, WHOEVER DECLARED IT A VALUE
 * (review cycle 6 F4 / round 7 P1-3). `env` is in `PREFIXES` and `-S` is in
 * `PREFIX_VALUE_FLAGS` — the prefix loop consumed the split string as an ordinary
 * VALUE and never looked at it, so `env -S "npm exec electron ."` was `[]`: no
 * block AND no ledger row. The two tables disagreed about the same flag, one
 * knowing it takes a value and the other not knowing that the value RUNS. The
 * runner family's `-c/--call` (`npm exec -c`, `npx -c`) is the same mechanism
 * (`afterRunner` skips an unrecognised runner flag as a boolean), so it belongs
 * in the same table rather than in a second branch.
 */
const COMMAND_STRING_FLAGS: Record<string, string[]> = {
  bash: ["-c"], sh: ["-c"], zsh: ["-c"], dash: ["-c"], ksh: ["-c"], ash: ["-c"],
  busybox: ["-c"], flock: ["-c", "--command"], script: ["-c", "--command"],
  su: ["-c", "--command", "--session-command"], runuser: ["-c", "--command"],
  env: ["-S", "--split-string"],
  npm: ["-c", "--call"], npx: ["-c", "--call"],
  pnpm: ["-c", "--call"], yarn: ["-c", "--call"],
};

/**
 * Options of the PACKAGE RUNNERS that take a value. Same failure direction as
 * `PREFIX_VALUE_FLAGS`: `npm exec --prefix apps/web electron .` swallowed
 * `apps/web` as the payload while `--prefix=apps/web` (self-contained) classified,
 * and `yarn --cwd web playwright test --headed` swallowed `web`.
 */
const RUNNER_VALUE_FLAGS = [
  "--prefix", "-w", "--workspace", "--cwd", "--registry", "--cache",
  "--userconfig", "--script-shell", "--filter", "--package", "-p",
];

/** `timeout`'s own duration (`30`, `2.5s`, `1m`), or its `-s`\/`-k` value. */
const TIMEOUT_DURATION = /^\d+(\.\d+)?[smhd]?$/;

/**
 * The letters `open` accepts as options, for telling an attached ARGUMENT from a
 * getopt CLUSTER (`-aSafari` vs `-na`). `-a`, `-b`, `-s`, `-u`, `-t` take values;
 * the rest are switches. Used only by `clusterShortArg`.
 */
/**
 * The letters `open` accepts as options. Kept for documentation of the option
 * contract the `-a`/`-b` predicates assume; the parsing itself is pure getopt.
 */
const OPEN_FLAG_LETTERS = "abefghjnstuwREFW";

/**
 * How many LEADING POSITIONAL arguments a prefix takes before the real command.
 *
 * ⛔ A WRAPPER'S OWN POSITIONAL IS NOT THE COMMAND WORD (round-12 review, P3).
 * `commandWordIndex` skipped only `-`-prefixed tokens after a prefix, so the
 * wrapper's positional BECAME the command word and the launch behind it vanished:
 * `flock /tmp/l.lock electron .` and `taskset 0x3 electron .` were `[]` — no
 * refusal and no ledger row — while the runner spelling of the SAME wrapper
 * (`flock /tmp/l.lock npm exec electron .`) fired. Real `flock`/`taskset` run the
 * payload in both spellings (measured with a stubbed `electron` on PATH).
 *
 * These arities are the canonical single-positional grammars: `flock FILE CMD`,
 * `taskset MASK CMD` (the mask is omitted when `-c/--cpu-list` supplies it),
 * `chrt PRIORITY CMD`, and `script FILE [CMD …]`. A wrapper that is not listed
 * keeps its old behaviour, and the fail-safe word scan is enabled whenever a
 * positional was skipped, so a wrapper that only LOOKS like it takes one cannot
 * swallow the launch.
 */
const PREFIX_POSITIONALS: Record<string, number> = {
  flock: 1,
  taskset: 1,
  chrt: 1,
  script: 1,
  // `chroot NEWROOT [COMMAND …]` — the root is a positional, the command follows
  // it (round-12 review, P2: `chroot /tmp/root electron .` was `[]` while
  // `chroot --userspec=0:0 /tmp/root electron .` was refused — the same launch,
  // one flag apart; `unshare … chroot $ROOT /echo` proved the payload runs).
  chroot: 1,
};

/**
 * Shell grouping / control-flow words sit where a command word would.
 *
 * `(`/`{` arrive as their OWN token only when the operator is SPACED; when it is
 * attached (`(npm …`) `stripLeadingMetachars` normalises the token instead. Both
 * spellings are now covered — the spaced one by `commandWordIndex`'s leading-token
 * drop (review cycle 4, F1), which is why a bare `(`/`{` never reaches this set.
 */
const TRANSPARENT = new Set(["{", "}", "(", ")", "then", "do", "done", "fi", "else", "elif", "if", "while", "until", "select"]);

/**
 * Wrapper words whose bare OPERAND is a command string for `sh -c`.
 *
 * ⛔ `watch` RUNS ITS OPERAND, AND ITS OPERAND IS NOT THE COMMAND WORD (round-12
 * review, HIGH). `watch -n 1 "electron ."` was `[]` — no block, no ledger row —
 * while the UNQUOTED spelling fired, and `watch --exec electron .` fired too: the
 * one listed prefix whose command-string operand had no `COMMAND_STRING_FLAGS` row.
 * `watch --help` states the default is `sh -c`, and a stubbed `electron` on PATH was
 * executed by a real `watch` run. The whole remaining operand is re-read, which is
 * exactly what `sh -c` would do with it.
 */
const PREFIX_COMMAND_OPERAND = new Set(["watch"]);

/**
 * Package-runners whose first PACKAGE argument is the thing being launched.
 *
 * ⛔ A RUNNER'S ALIAS IS THE SAME RUNNER (review cycle 6 F3 / round 7 P1-2).
 * `bunx` was listed and `bun x` was not, so `bun x electron .` was `[]` — no
 * refusal, no ledger row — while Bun's own documentation says *"bunx is an alias
 * for bun x"* (`https://bun.com/docs/cli/bunx`). `EXEC_VERBS` already carried `x`,
 * so the table already intended to cover it. `mise exec -- <cmd>` and
 * `asdf exec <cmd>` are the same shape in the version-manager family; the
 * structural rule in `classifyLaunchCommand` reads an exec-verb payload behind ANY
 * of these, so a runner the table has not heard of degrades to an over-fire at
 * worst, never to a `[]`.
 */
const RUNNERS = new Set(["npx", "npm", "pnpm", "yarn", "bunx", "bun", "mise", "asdf"]);

/**
 * The runner verbs that EXECUTE a payload (`npx foo`, `npm exec foo`,
 * `pnpm dlx foo`, `yarn dlx foo`) rather than managing a dependency tree.
 * The distinction is load-bearing: `npm install electron` INSTALLS the package
 * and must never be read as launching it (an over-fire on a shape every lane
 * runs), while `npm exec electron` IS a launch.
 */
const EXEC_VERBS = new Set(["exec", "dlx", "x", "execx"]);

/** Words that NAME a GUI launch — used only as the last-resort fail-safe scan. */
const LAUNCH_WORDS = new Set(["electron", "playwright", "puppeteer", "playwright-core"]);

/**
 * Electron's own launcher packages, as a runner's payload spells them.
 *
 * ⛔ `electron-forge` IS AN ELECTRON LAUNCH (round 12, P2). Every head test keyed on
 * the package name `electron` exactly, so `npx electron-forge start` — the first-party
 * launcher, and the one an Electron repo's own `start` script calls — classified `[]`:
 * no refusal, no ledger row. It is distinguishable from a plain `node` run by its
 * leftmost word, so it is NOT in the declared residual class ("argv cannot tell them
 * apart from a plain `node` run"); only a package.json script genuinely is.
 *
 * `@electron-forge/cli` is the same tool under its scoped name, so both spellings are
 * here rather than the bare word alone.
 */
const ELECTRON_FORGE = new Set(["electron-forge", "@electron-forge/cli"]);

/** Is this token an Electron Forge package spec — optionally version-pinned? */
function isElectronForge(tok: string): boolean {
  // Strip a trailing `@version` WITHOUT eating a scope: `@electron-forge/cli` has no
  // version to strip (its only `@` is followed by `/`), `@electron-forge/cli@7` does.
  const spec = tok.replace(/@[^/@]+$/, "");
  return ELECTRON_FORGE.has(spec) || (spec.split("/").pop() ?? spec) === "electron-forge";
}

/**
 * Does this Electron Forge invocation LAUNCH the app? Only `start` does.
 *
 * `package`, `make`, `publish`, `import`, `lint` and `init` build, publish or inspect
 * an app and never open a window — refusing them would be the category-B friction of
 * blocking a routine build, and `start` is the only verb the incident's shape needs.
 * The verb is the first non-flag word after the package; `npm exec electron-forge --
 * start` spells it after a `--`, which is skipped for the same reason `afterRunner`
 * skips it. No verb at all (`electron-forge` alone) prints help.
 */
function forgeLaunches(toks: string[], from: number): boolean {
  for (let i = from; i < toks.length; i++) {
    const tok = toks[i];
    if (tok === "--" || tok.startsWith("-")) continue;
    return tok === "start";
  }
  return false;
}

/** A headed-browser signal: the run can present a real device picker. */
const HEADED_FLAGS = new Set(["--headed", "--ui", "--debug", "--pause"]);

/**
 * Playwright's subcommands that are HEADED BY DEFAULT — `codegen` records a
 * browser the user drives, and `open` opens one. Neither needs a flag, so a
 * `--headed`-only test missed them entirely (review cycle 1, F2).
 */
const HEADED_SUBCOMMANDS = new Set(["codegen", "open"]);

/** Shells whose `-c <string>` argument is a COMMAND this classifier must re-read. */
const SHELLS = new Set(["bash", "sh", "zsh", "dash", "ksh", "ash", "busybox"]);

/** How deep a nested wrapper may go before it is refused as un-analysable. */
const MAX_WRAPPER_DEPTH = 3;

export type LaunchRule = "electron" | "open" | "app-bundle" | "playwright";

export interface LaunchFinding {
  /** which rule fired */
  rule: LaunchRule;
  /** the GUI app identity we could name (`Electron`, `Safari`, a bundle path…) */
  app: string;
  /** the segment's argv, joined for the ledger */
  argv: string;
  /** true when this launch can open a REAL capture device */
  media: boolean;
  /** true when the fake-capture switches are present in the same segment */
  faked: boolean;
}

export interface LaunchVerdict {
  block: true;
  reason: string;
}

type Warn = (message: string) => void;
const defaultWarn: Warn = (m) => console.warn(`[gui-device-guard] ${m}`);

// ── segmentation / tokenisation ─────────────────────────────────────────────
//
// Quote state is NOT re-modelled here: `unquotedMask` is the repo's single quote
// model (`extensions/shared/git-command-parse.ts`), shared with the gh-verb
// matchers. A second copy is the defect #966 records.

const SEPARATORS = new Set([";", "&", "|", "\n", "\r"]);

/** Split a command line on UNQUOTED separators. A quote-aware mention stays inside. */
/**
 * Is this `&` part of a REDIRECTION rather than a command separator?
 *
 * ⛔ `2>&1` AND `&>file` ARE NOT `&` SEPARATORS (round-12 review, HIGH). Splitting on
 * every unquoted `&` cut `2>&1 electron .` into `2>` and `1 electron .`, so the launch
 * was never the command word (`[]` — no block, no ledger row) even after the redirect
 * tokens themselves were dropped.
 */
function isRedirectionAmp(command: string, i: number): boolean {
  if (command[i] !== "&") return false;
  return command[i - 1] === ">" || command[i + 1] === ">";
}

export function splitSegments(command: string): string[] {
  const mask = unquotedMask(command);
  const out: string[] = [];
  let cur = "";
  for (let i = 0; i < command.length; i++) {
    const ch = command[i];
    if (mask[i] && SEPARATORS.has(ch) && !isRedirectionAmp(command, i)) {
      out.push(cur);
      cur = "";
      continue;
    }
    cur += ch;
  }
  out.push(cur);
  return out.map((s) => s.trim()).filter((s) => s.length > 0);
}

/** One segment of a line, with the character range it occupies in that line. */
interface LineSegment {
  text: string;
  /** First character of the segment in the line (its separator excluded). */
  start: number;
  /** One past the last character, i.e. the index of its separator. */
  end: number;
  /** Does this segment feed the NEXT one through a pipe (`|` or `|&`)? */
  pipeToNext: boolean;
}

/**
 * `splitSegments` with OFFSETS kept, so a caller that knows WHERE an operator sits
 * can ask about the segment that operator binds to.
 *
 * ⛔ THE OFFSETS ARE THE POINT, AND `splitSegments` CANNOT SUPPLY THEM (round 12,
 * P1). It trims and drops empty segments, which is right for the argv rules and
 * useless for "which segment carries this redirect". `pipeToNext` distinguishes a
 * PIPE (`|`, and `|&`, which IS a pipe with stderr folded in) from a command
 * separator (`;`, `&`, newline) and from `||` — the logical OR, whose right-hand
 * side does NOT receive the left-hand side's standard input.
 */
function lineSegments(line: string): LineSegment[] {
  const mask = unquotedMask(line);
  const out: LineSegment[] = [];
  let cur = "";
  let start = 0;
  for (let i = 0; i < line.length; i++) {
    const ch = line[i];
    if (!mask[i] || !SEPARATORS.has(ch)) {
      cur += ch;
      continue;
    }
    // ⛔ `>&` IS A REDIRECT, NOT A COMMAND SEPARATOR — and WHICH redirect decides
    // whether the pipe still carries the body (round 12 review round 2, P2).
    // `cat <<EOF 2>&1 | bash` RUNS the body (measured: `BODY_RAN`), because `2>&1`
    // duplicates stderr ONTO stdout — stdout itself is still piped. Reading that
    // `&` as a separator cut the pipeline at `2>&`, the forward scan stopped before
    // the shell, and the line became `[]`: the double loss (no refusal, no ledger
    // row) that L28f/L29a exist to close, introduced by the very fix for `bash
    // <<EOF | tee`. The fd number before the `>` decides — absent means fd 1:
    //   `2>&1`, `3>&1`, `2>&-`  stdout stays in the pipe  → keep the pipeline
    //   `>&2`, `>&-`, `1>&2`    stdout LEAVES the pipe    → the pipeline ends
    // `&>` / `&>>` are not this case: the `&` comes BEFORE the `>`, so it is still
    // read as a separator below, which is also the right answer (stdout went to a
    // file, so nothing reaches the shell).
    if (ch === "&" && line[i - 1] === ">") {
      // `N>&M` copies fd N onto fd M, so STDOUT LEAVES THE PIPE IFF N is 1 (or
      // absent, which defaults to 1) and M is not 1. Both sides are needed:
      //   `2>&1`, `3>&1`, `2>&-`, `{fd}>&1`, `>&1`, `1>&1`  stdout stays → keep
      //   `>&2`, `1>&2`, `>&-`, `1>&-`                      stdout leaves → end
      // ⛔ KEYING ON THE LEFT FD ALONE LOST `>&1` AND `1>&1` (round-12 review,
      // P3): those are no-ops that leave stdout ON the pipe, and treating them as
      // separators dropped a heredoc body `bash` really executes (`cat <<'EOF' >&1
      // | bash` printed `BODY_RAN` — measured).
      let k = i - 2;
      let left = "";
      while (k >= 0 && /\d/.test(line[k])) {
        left = line[k] + left;
        k--;
      }
      // ⛔ `{fd}>&2` ALLOCATES A NEW DESCRIPTOR (round-12 review, P3): the left side
      // is `{name}`, not an absent fd 1, so stdout stays on the pipe — yet the digit
      // scan saw nothing and treated it as fd 1 (`cat <<'EOF' {fd}>&2 | bash` printed
      // `BRACEFD_RAN` while the guard returned `[]`).
      const braceFd = left === "" && k >= 0 && line[k] === "}";
      let m = i + 1;
      let right = "";
      while (m < line.length && /\d/.test(line[m])) {
        right += line[m];
        m++;
      }
      const leftIsStdout = !braceFd && (left === "" || left === "1");
      const stdoutMoves = leftIsStdout && right !== "1";
      if (!stdoutMoves) {
        cur += ch;
        continue;
      }
    }
    const pipeToNext = ch === "|" && line[i + 1] !== "|";
    // `||` / `&&` are ONE operator each and `|&` is ONE pipe, so each pair is
    // consumed as a single separator — otherwise the second `|` of a `||` would be
    // read as a PIPE and a redirect on its left would look like it reaches the next
    // segment.
    if (ch === "|" && line[i + 1] === "&") i++;
    else if (line[i + 1] === ch) i++;
    out.push({ text: cur, start, end: i, pipeToNext });
    cur = "";
    start = i + 1;
  }
  out.push({ text: cur, start, end: line.length, pipeToNext: false });
  return out;
}

/**
 * Index of the `#` that starts a COMMENT on `line`, or -1.
 *
 * One rule, two readers: `stripComments` (which cuts the line there) and
 * `stripHeredocBodies` (which must not read a `<<` that lives in a comment).
 * Duplicating it is the #966 defect — a second copy of a parse rule.
 *
 * ⛔ THE SET IS BASH'S METACHARACTERS, NOT A GUESS AT THEM (round 10, blocking).
 * The predecessor list was ";&|(" and omitted `)`, so `(npm exec electron .)# <both
 * fake switches>` read the switches as ARGV and reported `faked: true` — this
 * guard's one forbidden direction — while real bash discarded them:
 *
 *     $ bash -c '(echo RAN)# --ignored-flag'   →  RAN
 *
 * Bash recognises a comment when a word beginning with `#` starts a TOKEN, and its
 * metacharacters are blanks plus `| & ; ( ) < >` (GNU Bash manual, Comments; POSIX
 * XCU token-recognition rule 10) — the same set the repo's own comparables use:
 * `shell-quote` keys comment recognition off its metacharacter set, and bash's own
 * lexer assembles the token first and has no predecessor table at all. That list is
 * closed, so it cannot grow; what it must NOT do is call a character a boundary when
 * the character is itself QUOTED or ESCAPED — `echo x\)#c` prints `x)#c`, one word,
 * so `#` there is data. Hence the two guards below, not just a wider `.includes`.
 */
const WORD_BOUNDARY = ";&|()<>";

/** Is the character at `j` (unquoted) itself escaped by a preceding backslash? */
function isEscaped(line: string, j: number, base: number, mask: boolean[]): boolean {
  let n = 0;
  for (let k = j - 1; k >= 0 && line[k] === "\\" && mask[base + k] === true; k--) n++;
  return n % 2 === 1;
}

function commentCutIndex(line: string, base: number, mask: boolean[]): number {
  for (let i = 0; i < line.length; i++) {
    if (line[i] !== "#") continue;
    if (mask[base + i] !== true) continue;             // quoted: data, not a comment
    // Start of input/line, after a blank, or after an UNQUOTED, UNESCAPED operator.
    if (i === 0) return i;
    const prev = line[i - 1];
    if (mask[base + i - 1] !== true) continue;         // glued to a closing quote
    if (isEscaped(line, i - 1, base, mask)) continue;   // `x\)#` is one word
    if (/\s/.test(prev) || WORD_BOUNDARY.includes(prev)) return i;
  }
  return -1;
}

/**
 * Blank out shell COMMENTS before segmentation.
 *
 * ⛔ A COMMENT IS NOT ARGV (review cycle 2, F2). Without this, an unquoted `#`
 * left the rest of the line as ordinary tokens, so
 *
 *     electron . # --use-fake-device-for-media-stream --use-fake-ui-for-media-stream
 *
 * produced `faked: true` and the launch was ALLOWED while Chromium received
 * neither switch — a false PASS in the one direction this guard exists to
 * prevent, and reachable by pasting the guard's OWN refusal text (which prints
 * both flags). Only an unquoted `#` that BEGINS A WORD is a comment: `a#b` is
 * one word, and a `#` inside single/double quotes or a heredoc body is data.
 */
export function stripComments(command: string): string {
  if (!command.includes("#")) return command;
  const mask = unquotedMask(command);
  const lines = command.split("\n");
  const out: string[] = [];
  let at = 0;
  for (const line of lines) {
    const cut = commentCutIndex(line, at, mask);
    out.push(cut === -1 ? line : line.slice(0, cut));
    at += line.length + 1;
  }
  return out.join("\n");
}

/**
 * Blank out heredoc BODIES before segmentation.
 *
 * A heredoc body is DATA, not shell: `git commit -F - <<'EOF'` whose message
 * mentions `electron .` used to yield a second segment reading `electron . is
 * what broke`, i.e. a launch — a false BLOCK on the fleet's own commit idiom.
 * A guard that refuses correct work is the category-B friction `AGENTS.md`
 * names, so the body is removed rather than tolerated.
 *
 * ⛔ A `<<` INSIDE A COMMENT IS NOT A REDIRECT (review cycle 5, F2). This scanner
 * used to read raw lines with only the quote model, and `#` is not a quote
 * character — so a comment that merely MENTIONED the idiom
 *
 *     # usage: write a file with cat <<EOF
 *     npm exec electron .
 *
 * opened a heredoc with delimiter `EOF`, found no terminator, and deleted every
 * remaining line (`li = lines.length`). The launch was then neither blocked nor
 * recorded — the double loss cycles 3 and 4 treated as blocking — and the
 * one-directional claim this comment used to make was false for exactly that
 * shape. `commentCutIndex` (the same rule `stripComments` uses) is consulted per
 * line so a commented `<<` is data.
 *
 * The terminator comparison is deliberately UNCHANGED (a line must BE the
 * delimiter): `EOF # done` really does not terminate a heredoc in `sh`, so the
 * text after it really is data, and A32/A33 pin both directions.
 *
 * ⛔ A BODY IS DATA FOR `cat` AND THE PROGRAM FOR A SHELL (round 11, blocking).
 * The blanking above is unconditional, which is right for `cat` / `git commit -F -
 * -` (A3, A31) and WRONG when the command word is a SHELL: a shell with no command
 * operand (or with `-s`) reads and EXECUTES its standard input, and the heredoc /
 * here-string IS that input (GNU Bash Reference Manual §3.6 — Here Documents and
 * Here Strings both redirect standard input; §Invoking Bash — `-s` reads commands
 * from standard input). So
 *
 *     bash <<'EOF'
 *     npm exec electron .
 *     EOF
 *
 * was `[]`: the body was deleted before any rule saw it, and the handler returns
 * early on `[]`, so the refusal AND the ledger row were lost together — the exact
 * double loss cycles 3, 4 and 5 treated as blocking, and the same shape those
 * cycles closed for `bash -c "…"` (the command string IS argv). The body here is
 * not even a residual: `stripHeredocBodies` already locates the delimiter and its
 * body, so what was missing is a conditional, not a grammar.
 *
 * The exception is `-c`: `bash -c 'script' <<EOF` RUNS the string and hands the
 * body to it as DATA, so a body behind a command-string flag is never a program.
 * A46 pins that direction, so the fix cannot over-fire on the fleet's own idiom.
 *
 * Declared residual: a `<<` inside an ARITHMETIC expansion (`$(( n << shift ))`)
 * is still read as a redirect, because the delimiter there (`shift`) is a legal
 * word. Closing it needs an arithmetic grammar this file does not have, and the
 * direction it fails in is the one that must be SAID rather than implied: with no
 * later line equal to the variable name, the following text is deleted and the
 * guard fires LESS. Declared here, not claimed complete.
 *
 * Declared residual: the SHELL-FED body is read only for a stdin-program SHELL —
 * `bash`/`sh`/`zsh`/… as the command word with no `-c`. A shell started by a FLAG
 * (`sudo -s`, `su` with no `-c`) is not resolved as a command word; a heredoc fed
 * to another interpreter (`python <<EOF`) is the same class the module header
 * already declares for `node -e`/`python -c` — the program is not in argv.
 */
export interface ShellStdin {
  /** The command with every heredoc body blanked — what the argv rules segment. */
  cleaned: string;
  /** Bodies a shell will EXECUTE from stdin, in source order, for re-classification. */
  programs: string[];
}

/** The two LITERAL `<<<` operand forms: a quoted string, or one bare word. */
const HERESTRING = /<<<\s*(?:'([^']*)'|"((?:[^"\\]|\\.)*)"|(\S+))/g;

/** Undo the backslash escapes `tokenize` would have applied inside `"…"`. */
function unescapeDouble(s: string): string {
  return s.replace(/\\(.)/g, "$1");
}

/**
 * Does this SEGMENT name a shell that will EXECUTE its standard input?
 *
 * `-c` (in any cluster: `-c`, `-lc`, `-ec`) is the exception — the shell runs the
 * ARGUMENT and passes stdin to that script as data, so the body is not a program.
 * `-s` is the explicit "read commands from standard input" spelling and needs no
 * special case: a shell with no `-c` reads stdin anyway.
 */
function shellExecutesStdin(rawToks: string[]): boolean {
  let toks = rawToks;
  for (let depth = 0; depth < 3; depth++) {
    const cwi = commandWordIndex(toks);
    if (cwi >= 0) {
      // ⛔ A SHELL GLUED TO ITS REDIRECT IS STILL THE COMMAND WORD (round-12 review,
      // P2). `tokenize` never splits `<<` off a word, so `bash<<'EOF'` arrives as ONE
      // token, `basename` reads `bash<<EOF`, it misses `SHELLS`, and the body was
      // blanked as data: `bash<<'EOF'` + a launch was `[]` while the SPACED twin fired
      // — and real bash runs the body either way (`bash <<'EOF'|tee` and `bash<<'EOF'|
      // tee` both printed it). Truncating at the operator is what `tokenize` would
      // have done had the redirect been spaced.
      const head = basename(toks[cwi].split("<<")[0]);
      if (head !== "" && SHELLS.has(head)) {
        for (let i = cwi + 1; i < toks.length; i++) {
          if (/^-[A-Za-z]*c[A-Za-z]*$/.test(toks[i]) || toks[i] === "--command") return false;
        }
        return true;
      }
    }
    // ⛔ THE SHELL CAN BE INSIDE A SUBSTITUTION, AND THE REDIRECT CAN BE ITS OWN
    // TOKEN (round-12 review, LOW): `x=$(bash <<'EOF'` resolves to the command word
    // `<<EOF` (the assignment is skipped, the operator is not), so there is NO
    // shell at this level and the body was blanked as data even though bash runs it
    // (measured: `x=$(bash <<'EOF' … EOF)` captured the body's output). Unwrap the
    // substitution and ask again.
    const text = toks.join(" ");
    const at = Math.max(text.lastIndexOf("$("), text.lastIndexOf("<("), text.lastIndexOf("`"));
    if (at < 0) return false;
    const inner = text[at] === "`" ? text.slice(at + 1) : text.slice(at + 2);
    const next = tokenize(inner).map(stripTrailingMetachars);
    if (next.length === 0) return false;
    toks = next;
  }
  return false;
}

/**
 * Does this redirect feed a shell?
 *
 * ⛔ THE REDIRECT BINDS TO THE SEGMENT IT SITS IN — NOT TO THE LINE'S LAST ONE
 * (round 12, P1). The predecessor asked `shellExecutesStdin(segs[segs.length - 1])`
 * and its docstring claimed that was safe because "the redirect binds to the LAST
 * segment on the line". It does not: a redirect binds to the COMMAND it follows.
 *
 *     bash <<'EOF' | tee log        the redirect is in `bash`'s segment
 *     npm exec electron .
 *     EOF
 *
 * ran the body on this host, but the last segment is `tee log` — not a shell — so
 * the body was blanked as data and the line classified `[]`: no refusal AND no
 * ledger row (the handler returns early on an empty list), the double loss cycles
 * 3/4/5/11 treat as blocking, on the PIPE-LEFT spelling of the shape round 11
 * closed for a bare `bash <<'EOF'`.
 *
 * The mirror case must keep working: in `cat <<EOF | bash` the redirect is in
 * `cat`'s segment, but bash really does execute the body — it arrives over the
 * PIPE — so the scan follows `pipeToNext` and asks each piped-to segment too. A
 * `;`, `&`, newline or `||` ends the pipeline: nothing downstream receives the
 * body, so `cat <<EOF; bash` stays data.
 */
function lineFeedsShell(line: string, cut: number, offset: number): boolean {
  const head = cut === -1 ? line : line.slice(0, cut);
  const segs = lineSegments(head);
  let at = segs.findIndex((s) => offset >= s.start && offset <= s.end);
  // A redirect can only be outside a segment if the caller's offset is stale;
  // the last segment is then the safe (over-reading) answer.
  if (at < 0) at = segs.length - 1;
  if (at < 0) return false;
  if (shellExecutesStdin(tokenize(segs[at].text))) return true;
  for (let k = at; k + 1 < segs.length; k++) {
    if (!segs[k].pipeToNext) return false;
    if (shellExecutesStdin(tokenize(segs[k + 1].text))) return true;
  }
  return false;
}

/**
 * Bash's heredoc DELIMITER: the word after `<<`, with quote removal applied.
 *
 * ⛔ THE DELIMITER IS ANY WORD, NOT AN IDENTIFIER (round-12 review, P1/P2). The
 * scanner accepted only `['"]?[A-Za-z_][A-Za-z0-9_]*`, so the STANDARD way to write
 * a non-expanding heredoc — `<<\EOF` — was not a heredoc at all: its body was left
 * in `cleaned` and parsed as ARGV. Two failures followed from that one gap:
 *   - a lone apostrophe in the body (`don't touch the camera`) opened a literal run
 *     in the shared quote model, masking the newline separators and every later
 *     command → the launch was invisible (`[]`: no refusal, no ledger row);
 *   - a body that merely DOCUMENTED a launch was refused (`cat >> runbook.md <<\EOF`
 *     with `open ./Build/DMeer.app` inside) — a block on correct work, which this
 *     file treats as a defect in its own right.
 * `<<\EOF`, `<<'EOF'`, `<<"EOF"`, `<<E\OF`, `<<"E-O-F"` and `<<EOF` are all the
 * same delimiter to bash, and no expansion is performed on the word.
 */
function heredocDelimiter(raw: string): string | null {
  let out = "";
  let i = 0;
  while (i < raw.length) {
    const ch = raw[i];
    // ⛔ `$'…'` AND `$"…"` ARE QUOTE FORMS, NOT EXPANSION (round-12 review, P2).
    // `$` was kept literally, so `<<$'EOF'` produced the delimiter `$EOF`, found no
    // terminator, and swallowed the rest of the input — including the launch after
    // the real `EOF` line (measured: `cat <<$'EOF'` terminates at `EOF` and runs the
    // next line). ANSI-C and locale quoting are quote removal like any other.
    if (ch === "$" && (raw[i + 1] === "'" || raw[i + 1] === '"')) {
      i++;
      continue;
    }
    if (ch === "'") {
      const end = raw.indexOf("'", i + 1);
      if (end < 0) return null;
      out += raw.slice(i + 1, end);
      i = end + 1;
      continue;
    }
    if (ch === '"') {
      const end = raw.indexOf('"', i + 1);
      if (end < 0) return null;
      out += raw.slice(i + 1, end);
      i = end + 1;
      continue;
    }
    if (ch === "\\") {
      if (i + 1 >= raw.length) return null;
      out += raw[i + 1];
      i += 2;
      continue;
    }
    // A metacharacter ends the delimiter word (`<<EOF;` → `EOF`), and meeting one
    // FIRST means this `<<` is not a heredoc at all (`<<<EOF` → `<EOF` → null).
    if (";&|<>()`".includes(ch)) break;
    out += ch;
    i++;
  }
  return out === "" ? null : out;
}

export function splitShellStdin(command: string): ShellStdin {

  if (!command.includes("<<")) return { cleaned: command, programs: [] };
  const lines = command.split("\n");
  const mask = unquotedMask(command);
  // Offsets of each line's start, so the quote model can be consulted per char.
  const starts: number[] = [];
  let at = 0;
  for (const line of lines) {
    starts.push(at);
    at += line.length + 1;
  }
  const out: string[] = [];
  const programs: string[] = [];
  for (let li = 0; li < lines.length; li++) {
    const line = lines[li];
    out.push(line);
    const base = starts[li];
    const cut = commentCutIndex(line, base, mask);
    // ── here-STRING (`<<<`): its operand is the shell's stdin too, and `tokenize`
    //    folds `<<<"npm exec …"` into ONE token, so nothing else ever looks at it.
    for (const m of line.matchAll(HERESTRING)) {
      if (mask[base + m.index] !== true) continue;          // a quoted `<<<` is data
      if (cut !== -1 && m.index > cut) continue;             // a commented `<<<` is data
      const operand = m[1] ?? (m[2] === undefined ? m[3] : unescapeDouble(m[2])) ?? "";
      // The redirect's own offset decides which segment's shell (if any) receives it.
      if (operand === "" || !lineFeedsShell(line, cut, m.index)) continue;
      programs.push(operand);
    }
    const re = /<<(-?)\s*(\S+)/g;
    let m: RegExpExecArray | null;
    const pending: { word: string; offset: number; stripTabs: boolean }[] = [];
    while ((m = re.exec(line)) !== null) {
      // ⛔ A `<<` THAT IS PART OF `<<<` IS A HERE-STRING, not a heredoc: otherwise
      //    `bash <<<EOF` opened a heredoc with delimiter `EOF` and swallowed the
      //    rest of the input.
      if (m.index > 0 && line[m.index - 1] === "<") continue;
      const idx = base + m.index;
      if (mask[idx] === false) continue; // quoted `<<` inside a string, not a redirect
      // ⛔ A COMMENTED `<<` IS DATA (review cycle 5, F2) — see the header. It used
      // to delete every following line, which lost the block AND the ledger row.
      if (cut !== -1 && m.index > cut) continue;
      const word = heredocDelimiter(m[2]);
      if (word === null) continue; // `<<<` and a bare `<<` with no usable word
      pending.push({ word, offset: m.index, stripTabs: m[1] === "-" });
    }
    if (pending.length === 0) continue;
    // ⛔ A LINE CAN OPEN SEVERAL HEREDOCS, AND THE BODIES ARRIVE IN ORDER (round-12
    // review, P2). Only the LAST `<<` on the line was located, so
    // `bash <<A; cat <<B` sent A's body to the void and B's body was located
    // instead — the body bash actually feeds to `bash` became DATA, and the launch
    // inside it lost BOTH the refusal and the ledger row (measured: that line
    // prints A's body, then B's). Each operator consumes its own body, in
    // appearance order, exactly as the shell does.
    let j = li + 1;
    for (const p of pending) {
      const body: string[] = [];
      while (j < lines.length && lines[j].replace(/^\t+/, "") !== p.word) {
        out.push("");
        // `<<-` strips leading TABS from the body at execution time, so the program
        // the shell runs is the tab-stripped text — not the source bytes.
        body.push(p.stripTabs ? lines[j].replace(/^\t+/, "") : lines[j]);
        j++;
      }
      if (body.length > 0 && lineFeedsShell(line, cut, p.offset)) {
        programs.push(body.join("\n"));
      }
      if (j < lines.length) {
        out.push(""); // the terminator line carries no command
        j++;
      }
    }
    li = j - 1;
  }
  return { cleaned: out.join("\n"), programs };
}

/** The blanking half of `splitShellStdin`, kept as the name its callers know. */
export function stripHeredocBodies(command: string): string {
  return splitShellStdin(command).cleaned;
}

/** Whitespace split that honours `'…'`, `"…"` and backslash escapes. */
export function tokenize(segment: string): string[] {
  const toks: string[] = [];
  let cur = "";
  let quote: string | null = null;
  let has = false;
  for (let i = 0; i < segment.length; i++) {
    const ch = segment[i];
    if (quote !== null) {
      if (ch === quote) quote = null;
      else if (quote === '"' && ch === "\\" && i + 1 < segment.length) cur += segment[++i];
      else cur += ch;
      has = true;
      continue;
    }
    if (ch === "'" || ch === '"') {
      quote = ch;
      has = true;
      continue;
    }
    if (ch === "\\" && i + 1 < segment.length) {
      cur += segment[++i];
      has = true;
      continue;
    }
    if (/\s/.test(ch)) {
      if (has) {
        toks.push(cur);
        cur = "";
        has = false;
      }
      continue;
    }
    cur += ch;
    has = true;
  }
  if (has) toks.push(cur);
  return toks;
}

/**
 * Strip the shell metacharacters a segment can begin with. `tokenize` does not
 * split `(`/`{` from the word, so `(npm exec electron . &)` — the idiomatic way a
 * lane BACKGROUNDS a GUI app — produced the token `(npm`, which matched no rule
 * and left the declared `TRANSPARENT` entries for `(`/`{` unreachable (review
 * cycle 3, F1). Only the FIRST token is normalised: a `(` later in a segment is
 * part of an argument.
 *
 * ⛔ A token that is ONLY metacharacters strips to `""` — and `""` is not a
 * command word, it is separation. `commandWordIndex` DROPS such a token instead
 * of keeping it (review cycle 4, F1); see the note there.
 */
function stripLeadingMetachars(tok: string): string {
  let i = 0;
  while (i < tok.length && "({$!".includes(tok[i])) i++;
  return i === 0 ? tok : tok.slice(i);
}

/**
 * Strip a TRAILING bash metacharacter from a token.
 *
 * ⛔ `tokenize` SPLITS ON WHITESPACE ONLY, AND BASH'S GROUPING OPERATORS ARE
 * METACHARACTERS, NOT SPACES (round-12 review, P1). Only the FIRST token's
 * leading metachars were normalised, so a command wrapped in parentheses carried
 * the `)` on its LAST token and every exact-token predicate compared against the
 * glued spelling:
 *   - `(open ./Build/DMeer.app)` — `.app)` failed the suffix test AND both bundle
 *     regexes, so the launch produced NO finding AND no ledger row;
 *   - `(npx playwright test --headed)` — `--headed)` failed `HEADED_FLAGS`, so a
 *     HEADED run was allowed;
 *   - `(electron . --use-fake-… --use-fake-ui-…)` — the fake flags did not match,
 *     so a MITIGATED run was refused: the false-block direction, in the same bug.
 * Bash itself strips the parenthesis (`bash -c '(open ./Build/DMeer.app)'` passes
 * `./Build/DMeer.app` as `$1`), so the guard must too.
 */
function stripTrailingMetachars(tok: string): string {
  let end = tok.length;
  while (end > 0 && ";&|()<>`".includes(tok[end - 1])) end--;
  return end === tok.length ? tok : tok.slice(0, end);
}

/** `A=B` leading assignment (an env prefix, not a command word). */
function isAssignment(tok: string): boolean {
  return /^[A-Za-z_][A-Za-z0-9_]*=/.test(tok);
}

function basename(p: string): string {
  const b = p.split("/").pop() ?? p;
  return b.replace(/\.exe$/i, "");
}

/**
 * The PACKAGE a runner's argument names, without its version spec:
 * `electron@30` → `electron`, `playwright@1.50.0` → `playwright`,
 * `@scope/pkg@2` → `pkg`, `electron` → `electron`.
 *
 * ⛔ A VERSION PIN IS ONE LEXICAL SUFFIX, NOT ANOTHER PROGRAM (round 7 P1-2).
 * `npx electron@30 .`, `npm exec electron@latest -- .` and
 * `npx playwright@1.50.0 test --headed` were all `[]` because the payload token was
 * compared VERBATIM against `electron` and against `LAUNCH_WORDS`. That is the
 * README's own "two spellings of one thing must not disagree" rule applied to the
 * payload instead of to the flag — and it was an undeclared residual, not a
 * declared one.
 */
function packageBaseName(tok: string): string {
  const word = basename(tok);
  const at = word.lastIndexOf("@");
  return at > 0 ? word.slice(0, at) : word;
}

/**
 * Index of the command word: skip leading `A=B` assignments, prefix-like words
 * (and the values their own flags consume) and grouping words. Returns -1 when
 * the segment holds no command word.
 */
function commandWordIndex(toks: string[], out?: { sawFlag?: boolean; payloadStart?: number }): number {
  // ⛔ AN OPERATOR TOKEN IS SEPARATION, NOT A COMMAND WORD (review cycle 4, F1).
  // `stripLeadingMetachars` strips metacharacters from INSIDE a token, so a token
  // that IS a metachar became `""` — and `""` was accepted as the command word.
  // `classifySegment` then returned `null` for it, the `PREFIXES` loop was never
  // entered, and the hint at index 1 was never asked
  // about: `( electron . &)`, `{ electron . ; }`, `! electron .` produced NO
  // finding — which is not "allow", because the handler returns early on an empty
  // list and R1 wrote no ledger row either. Both halves of #2249 skipped, on the
  // SPACED spelling of the shape cycle 3 fixed only when attached (`(npm …`).
  // Drop the token instead. Dropping is what makes the DECLARED entries
  // reachable again: the token after a dropped `(` is `electron` (the case that
  // was broken), and in a NESTED group (`( ( electron . &)`) it is `(` — which
  // `TRANSPARENT` now actually sees, as its header has always claimed. The loop
  // (rather than the single shift the review measured) is defence in depth for
  // the metacharacters that are in NEITHER table (`$`), so a later edit to either
  // table cannot re-open the hole; for `(`, `{` and `!` one shift is already
  // sufficient, which is why L20e is green under both forms.
  // An operator-only segment (`( )`) therefore returns -1.
  while (toks.length > 0 && stripLeadingMetachars(toks[0]) === "") toks.shift();
  if (toks.length === 0) return -1;
  let i = 0;
  // ⛔ A PREFIX THAT SKIPPED NO FLAG CANNOT HAVE SWALLOWED THE COMMAND WORD
  // (round 7 P2-5). `out.sawFlag` records whether the prefix's flag loop consumed
  // at least one token; the fail-safe scan is gated on it, so `sudo rg electron .
  // …` and `timeout 30 rg electron .` (a bare prefix then the real command) stay
  // clean while `sudo --some-future-flag value electron .` is still rescued.
  toks[0] = stripLeadingMetachars(toks[0]);
  while (i < toks.length) {
    const tok = toks[i];
    if (isAssignment(tok) || TRANSPARENT.has(tok)) {
      i++;
      continue;
    }
    if (PREFIXES.has(tok)) {
      // ⛔ `command -v` IS A LOOKUP, NOT A LAUNCH (review cycle 4, minor).
      // `command` is a prefix word, so the resolved command word was the LOOKED-UP
      // name and `command -v electron` was REFUSED — a false block on correct work,
      // the direction README:114 calls a defect in its own right, and the one the
      // comparable (Claude Code's bash permissions) explicitly exempts: "the query
      // form `command -v` … looks up a command rather than running one". Nothing
      // executes, so there is no launch to classify (and nothing to record).
      if (tok === "command" && i + 1 < toks.length && /^(-v|-V|--help|--version)$/.test(toks[i + 1])) {
        return -1;
      }
      const valueFlags = PREFIX_VALUE_FLAGS[tok] ?? [];
      i++;
      // ⛔ ONE LOOP FOR EVERY PREFIX (review cycle 2, F1). `timeout` used to have
      // its own branch that `continue`d BEFORE the generic skip, so any long
      // option (`--preserve-status`, `--foreground`, `--verbose`) left a `--flag`
      // token sitting where the command word belongs and the segment became
      // unclassifiable. Its duration argument is now just another positional.
      while (i < toks.length && toks[i].startsWith("-")) {
        // `--flag=value` is SELF-CONTAINED and consumes no following word.
        if (out) out.sawFlag = true;
        if (toks[i].includes("=")) {
          i += 1;
        } else if (valueFlags.includes(toks[i])) {
          i += 2;
        } else {
          i += 1;
        }
      }
      if (tok === "timeout" && i < toks.length && TIMEOUT_DURATION.test(toks[i])) i++;
      // A wrapper's own positional (lock file, CPU mask, priority) is skipped — see
      // PREFIX_POSITIONALS. `taskset -c 0-3` supplies the mask by flag, so the token
      // that lands on the command word is skipped here and found by the fail-safe
      // scan instead (which starts at the payload, so it sees the real command).
      const positionals = PREFIX_POSITIONALS[tok] ?? 0;
      if (positionals > 0 && i < toks.length && !toks[i].startsWith("-")) {
        if (out) {
          out.sawFlag = true;
          out.payloadStart = i;
        }
        i += positionals;
      }
      continue;
    }
    return i;
  }
  return -1;
}

/** Strip a package-runner prefix, returning the package/command index. */
function afterRunner(
  toks: string[],
  start: number,
): { index: number; runner: string | null; execVerb: boolean } {
  const word = basename(toks[start] ?? "");
  if (!RUNNERS.has(word)) return { index: start, runner: null, execVerb: false };
  const bare = word === "npx" || word === "bunx";
  let i = start + 1;
  let execVerb = bare;
  while (i < toks.length) {
    const tok = toks[i];
    if (EXEC_VERBS.has(tok)) {
      execVerb = true;
      i++;
      continue;
    }
    if (tok === "--") {
      i++;
      continue;
    }
    if (tok.startsWith("-")) {
      // ⛔ THE RULE IS THE SAME ONE AS `commandWordIndex` (review cycle 2, F1):
      // `--flag=value` is self-contained, a KNOWN value flag consumes the next
      // word, and anything else is a boolean. `-p` is deliberately NOT treated as
      // npx's `--package` here — for `npx -p foo` the payload follows, and the
      // fail-safe scan below covers the ambiguity instead of guessing.
      if (tok.includes("=")) i += 1;
      else if (RUNNER_VALUE_FLAGS.includes(tok) && i + 1 < toks.length) i += 2;
      else i += 1;
      continue;
    }
    return { index: i, runner: word, execVerb };
  }
  return { index: -1, runner: word, execVerb };
}

/**
 * The index of the first word that NAMES a GUI launch, or -1.
 *
 * ⛔ THE LAST-RESORT FAIL-SAFE (review cycle 2, F1). It is applied ONLY to a
 * segment that began with a prefix word or an EXEC-style runner — the two shapes
 * where a wrapper's own grammar can swallow the command word — so a plain
 * `rg electron .` is untouched. Its direction is "catch more": a value that
 * happens to be spelled `electron` would over-fire, and an over-fire is waivable
 * (`GUI_DEVICE_GUARD_ALLOW_MEDIA=1`) while a miss is not.
 */
function launchWordIndex(toks: string[], from: number): number {
  for (let i = from; i < toks.length; i++) {
    const tok = toks[i];
    if (tok.startsWith("-") || isAssignment(tok)) continue;
    if (LAUNCH_WORDS.has(packageBaseName(tok)) || appBundleBinary(tok) !== null) return i;
  }
  return -1;
}

// ── classification ──────────────────────────────────────────────────────────

/** `…/electron/dist/Electron.app/Contents/MacOS/Electron` and friends. */
function appBundleBinary(tok: string): string | null {
  const m = /^(.*\.app)\/Contents\/MacOS\/([^/]+)$/.exec(tok);
  return m ? m[1] : null;
}

/**
 * Is this token the INNER BINARY of a macOS bundle — `…/X.app/Contents/MacOS/X`, or
 * the relative `Contents/MacOS/X` a shell inside the bundle would name?
 *
 * ⛔ THE `open` RULE AND THE COMMAND-WORD RULE MUST SPELL ONE SHAPE THE SAME WAY
 * (round 12, P2). `appBundleBinary` is consulted when the token is the COMMAND WORD,
 * so `/Applications/X.app/Contents/MacOS/X` was refused — while the identical token
 * after `open` was accepted only if it ended in `.app`, i.e. never. `open` on a
 * bundle's inner binary therefore produced NO finding at all: nothing refused and
 * nothing recorded, which is the diagnosis half of #2249 lost on a launch the guard
 * already blocks in its other spelling.
 */
function bundleInnerBinary(tok: string): boolean {
  return /(^|\/)Contents\/MacOS\/[^/]+$/.test(tok);
}

/**
 * The bodies of every command substitution in a command line — `$( … )`, `<( … )`,
 * `>( … )` and `` ` … ` `` — that EXECUTES.
 *
 * ⛔ SINGLE-QUOTED MATTERS (review cycle 1, F2's twin). `unquotedMask` cannot be
 * used here: it masks `$(…)` inside DOUBLE quotes too, and a double-quoted
 * substitution IS executed (`echo "$(npm exec electron .)"` launches the app).
 * A single-quoted one is literal text, and treating it as a launch is the exact
 * false BLOCK this guard already paid for once (`git commit` message bodies).
 * Parenthesis depth is counted so `$(a $(b))` yields the outer body whole.
 *
 * ⛔ A PROCESS SUBSTITUTION IS THE SAME CLASS AND WAS AN UNDECLARED MISS (round-12
 * review, P2). `<( … )` and `>( … )` run their body in a subshell and hand its
 * /dev/fd to the command — bash executes the body (`diff <(echo RAN) /dev/null`
 * prints `1d0 < RAN`, measured) — yet only `$(` was scanned, so `diff <(npm exec
 * electron .) /dev/null`, `cat < <(npm exec electron .)` and `tee > >(npm exec
 * electron .)` were all `[]`: no refusal AND no ledger row, on the shape the
 * README already claims to recurse into ("the body of `$( … )` or backticks").
 * ⛔ AND IT IS NOT EXECUTED INSIDE DOUBLE QUOTES: `echo "<(npm exec electron .)"`
 * prints the text (measured), so that spelling must stay data — which is why the
 * `<(`/`>(` arm is gated on the double-quote state while the `$(` arm is not.
 */
export function extractSubstitutions(command: string): string[] {
  const bodies: string[] = [];
  let i = 0;
  // Double-quote state, tracked ONLY for the process-substitution arm (a `$(`
  // inside double quotes still executes, and is handled exactly as before).
  let dq = false;
  while (i < command.length) {
    const ch = command[i];
    if (ch === "\\" && i + 1 < command.length) {
      i += 2;
      continue;
    }
    if (ch === "'") {
      // ⛔ A SINGLE QUOTE INSIDE DOUBLE QUOTES IS DATA (round-12 review, P2), and
      // the unconditional skip made it a LITERAL RUN: `echo "it's" "$(npm exec
      // electron .)"` skipped from the apostrophe to the `'` that opens the next
      // argument, swallowed the `$( … )` between them, and returned `[]` — while
      // bash prints `it's` and RUNS the substitution (measured: `BODY_RAN`). One
      // line of prose in an echo is all it took to lose the refusal AND the ledger
      // row. The `dq` state is the one bash uses: `'` only opens a literal run
      // OUTSIDE double quotes.
      if (dq) {
        i++;
        continue;
      }
      // Skip a single-quoted run wholesale.
      const end = command.indexOf("'", i + 1);
      i = end === -1 ? command.length : end + 1;
      continue;
    }
    if (ch === '"') {
      dq = !dq;
      i++;
      continue;
    }
    if (ch === "`") {
      const end = command.indexOf("`", i + 1);
      if (end === -1) break;
      bodies.push(command.slice(i + 1, end));
      i = end + 1;
      continue;
    }
    if (
      (ch === "$" && command[i + 1] === "(") ||
      (!dq && (ch === "<" || ch === ">") && command[i + 1] === "(")
    ) {
      // ⛔ QUOTE STATE, NOT A BARE DEPTH COUNTER (review cycle 3, F3).
      // `echo "$(echo ")"; npm exec electron .)"` closes the body early at the
      // `)` inside the quoted string, the remainder is dropped, and the launch
      // inside it was never classified — the same class the cycle-1 wrapper fix
      // declared closed. Inside the body, `'…'` and `"…"` are skipped whole
      // (with backslash escapes in double quotes), so a quoted paren is DATA.
      let depth = 0;
      let j = i + 1;
      let quote: string | null = null;
      for (; j < command.length; j++) {
        const cj = command[j];
        if (quote !== null) {
          if (cj === "\\" && quote === '"' && j + 1 < command.length) { j++; continue; }
          if (cj === quote) quote = null;
          continue;
        }
        if (cj === "'" || cj === '"') { quote = cj; continue; }
        if (cj === "\\" && j + 1 < command.length) { j++; continue; }
        if (cj === "(") depth++;
        else if (cj === ")") {
          depth--;
          if (depth === 0) break;
        }
      }
      if (j < command.length) {
        bodies.push(command.slice(i + 2, j));
        i = j + 1;
        continue;
      }
      break; // unterminated — nothing to analyse
    }
    i++;
  }
  return bodies;
}

/**
 * The argument ATTACHED to a short option: `-cCMD`, `-lcCMD`, `-aAPP`.
 *
 * ⛔ AN ATTACHED ARGUMENT IS THE SAME ARGUMENT (review cycle 5, F1). `tokenize`
 * collapses `bash -c"npm exec electron ."` to ONE token, `-cnpm exec electron .`,
 * which is neither the exact flag nor a bare `-c` cluster — so it was skipped as
 * an ordinary flag, no argument was ever handed to the wrapper recursion, and the
 * segment classified as `[]`: no block AND no ledger row. `-cCMD` is a legal, common
 * spelling of the very idiom the header says is recursed into.
 *
 * The letter comes from the CALLER's table (never a second copy of "c"), so a
 * wrapper added later gets the attached form for free. Anything after the flag
 * letter is the argument, and every character BEFORE it must itself be a
 * single-letter flag (`-lc`, `-xc`), which is how a cluster spells it.
 */
function attachedShortArg(tok: string, letter: string): string | null {
  if (!tok.startsWith("-") || tok.startsWith("--")) return null;
  const body = tok.slice(1);
  const at = body.indexOf(letter);
  if (at < 0) return null;
  if (!/^[A-Za-z]*$/.test(body.slice(0, at))) return null;
  const rest = body.slice(at + 1);
  return rest === "" ? null : rest;
}

/**
 * The argument a SHORT-FLAG CLUSTER hands to one of `letters` — `-na <name>`,
 * `-bna <id>`, `-a<app>` — or null when this token is not a flag cluster that
 * carries one of those letters at all. An empty string means the argument is the
 * NEXT token.
 *
 * ⛔ A CLUSTER IS A THING FOR `open` (review cycle 6 F2 / round 7 P2-4). The
 * previous inline copy (`tok[1] === "a" || tok[1] === "b"`) had TWO defects in one
 * predicate:
 *
 * 1. it never checked `tok.startsWith("-")`, so any plain word whose SECOND
 *    character is `a`/`b` was read as an attached flag — `open Banjo.app` became
 *    `app: "njo.app"`, `fromFlag = true`, `media: false`, i.e. a FALSE PASS on the
 *    incident's own `open <bundle>` shape, downgraded by a letter of the app's
 *    name, with a mangled identity in the ledger row;
 * 2. it insisted the flag letter be the FIRST one, which is false — `open -na
 *    "Google Chrome"` is `-n -a <name>` (getopt clustering; the widely used
 *    "new instance of a named app" idiom) and it classified `[]`, losing the R1
 *    row, while `open -bna com.x` recorded `app: "na"`.
 *
 * The rule here is the one `attachedShortArg` already writes for the shell
 * family: every character BEFORE the option letter must itself be a letter (a
 * bare flag), and the LAST of `letters` present in the cluster wins — so `-bna`
 * is `-b -n -a` and its argument is the next word, matching `-na`.
 */
/**
 * Remove REDIRECTIONS from the word list, the way bash does before running a
 * command.
 *
 * ⛔ A REDIRECTION IS NOT A WORD (round-12 review, HIGH). `commandWordIndex`
 * returned the first non-prefix token, and a leading redirection is such a token —
 * so `2>/dev/null electron .` resolved the command word to `null` (from the redirect
 * TARGET) and `>/tmp/o.log /Applications/DMeer.app/Contents/MacOS/DMeer` to `o.log`:
 * both `[]`, losing the refusal AND the ledger row, while the runner spelling of the
 * same line (`2>/dev/null npm exec electron .`) fired because the nested-payload scan
 * starts at index 1. A redirect GLUED to the end of a word hid the exact-token flags
 * in the other direction: `npx playwright test --headed>/tmp/pw.log` was `[]` and
 * `electron . <both fake switches>/tmp/log` was REFUSED although both switches were
 * in argv. Bash deletes redirections from the word list and ends a word at the
 * operator; so does this. (Quotes are already removed by `tokenize`, so a QUOTED
 * `>` is treated as an operator here — the same accepted trade `stripTrailingMetachars`
 * makes.)
 */
function stripRedirections(toks: string[]): string[] {
  const out: string[] = [];
  for (let i = 0; i < toks.length; i++) {
    const tok = toks[i];
    // A token that IS a redirection (`>`, `2>`, `>>f`, `2>&1`, `&>f`, `<<EOF`): bash
    // never passes it as a word. With no target attached, the target is the NEXT word.
    const lead = /^(?:\d{1,2})?(?:&>>|&>|>{1,3}|<{1,3}|>\||&)(.*)$/.exec(tok);
    if (lead) {
      if (lead[1] === "") i++;
      continue;
    }
    // A redirect glued to the END of an ordinary word ends the word at the operator.
    const at = tok.search(/[<>]/);
    if (at > 0) {
      out.push(tok.slice(0, at));
      continue;
    }
    out.push(tok);
  }
  return out;
}

function clusterShortArg(
  tok: string,
  letters: readonly string[],
): { letter: string; arg: string } | null {
  if (!tok.startsWith("-") || tok.startsWith("--")) return null;
  const body = tok.slice(1);
  // ⛔ THE ATTACHED ARGUMENT STARTS AFTER THE OPTION LETTER, NOT AFTER ITS LAST
  // OCCURRENCE ANYWHERE IN THE TOKEN (round-12 review, HIGH). `body.lastIndexOf
  // (letter)` searched the ARGUMENT too, so the app's own name was cut at its last
  // `a`/`b`: `open -aSafari` recorded `app: "ri"`, `open -aBrave` → `"ve"`, and
  // `open -aBanana` / `open -bcom.apple.Safari` failed every `.app` predicate and
  // produced NO finding at all — losing the ledger row for the whole attached
  // spelling family, while `-aDMeer` (the pinned row) happened to survive. getopt
  // stops at the first VALUE-taking letter: `-aSafari` is `-a Safari`.
  //
  // ⛔ PURE GETOPT, NO HEURISTIC (round-12 review, eighth pass): the remainder after
  // the first value letter IS the argument — full stop. A "could be more flags"
  // reading of `-anews`/`-aweb` made `open -anews notes.txt` record NOTHING and
  // `open -aweb index.html` record `app: "index.html"` (the launched app is `web`).
  // bash's own `getopts` settles it: `set -- -bna com.x` → `opt=b arg=na`, so the
  // P2-4 row that pinned `-bna com.x` → `com.x` was WRONG about getopt and has been
  // corrected to `na` (the README's own sentence — "getopt stops at the first
  // VALUE-taking letter" — already said so).
  let run = 0;
  while (run < body.length && /[A-Za-z]/.test(body[run])) run++;
  for (let i = 0; i < run; i++) {
    const ch = body[i];
    if (!letters.includes(ch)) continue;
    return { letter: ch, arg: body.slice(i + 1) };
  }
  return null;
}

/**
 * The command-string argument of a wrapper that takes one — the shell's `-c`
 * (also `-lc`, `-ec`, `-o pipefail -c`), `flock -c`, `script -c` — or null.
 *
 * ⛔ GENERALISED FROM THE SHELL-ONLY CASE (review cycle 3, F1): `flock /tmp/l -c
 * "npm exec electron ."` was invisible because only `bash`-family heads were
 * re-read. `COMMAND_STRING_FLAGS` names the flag per head, so a wrapper added
 * later is one table row rather than a second branch.
 */
function shellCommandArg(toks: string[], headIndex: number): string | null {
  const head = basename(toks[headIndex] ?? "");
  const flags = COMMAND_STRING_FLAGS[head];
  if (!flags) return null;
  for (let i = headIndex + 1; i < toks.length; i++) {
    const tok = toks[i];
    if (tok === "--") continue;
    // ⛔ `--flag=value` IS THE SAME FLAG (round 7 P1-3). `env --split-string='npm
    // exec electron .'` was `[]` even with the `env` row present, because only the
    // exact token was matched. A self-contained long spelling must not disagree
    // with the separated one.
    for (const flag of flags) {
      if (flag.startsWith("--") && tok.startsWith(`${flag}=`)) return tok.slice(flag.length + 1);
    }
    if (flags.includes(tok)) return toks[i + 1] ?? null;
    // A short-flag cluster containing `c` for the shell family only.
    if (SHELLS.has(head) && /^-[A-Za-z]*c[A-Za-z]*$/.test(tok)) return toks[i + 1] ?? null;
    // ⛔ `-cCMD` — the ATTACHED spelling of the same flag (review cycle 5, F1).
    for (const flag of flags) {
      if (flag.startsWith("--")) continue;
      const attached = attachedShortArg(tok, flag[1]);
      if (attached !== null) return attached;
    }
  }
  return null;
}

/**
 * The nearest COMMAND STRING carried by ANY wrapper in the segment, or null.
 *
 * ⛔ THE WRAPPER IS NOT ALWAYS AT TOKEN 0 (round 7 P1-3). `sudo env -S "electron
 * ."` resolves no command word at all (`env -S` consumes its value, `cwi === -1`),
 * and `shellCommandArg(toks, 0)` asked `sudo` — which carries no command-string
 * flag — so the split string was never re-read. Scanning every position finds the
 * wrapper wherever the prefix chain left it; a token that is not a registered head
 * returns null immediately, so the scan costs one comparison per token.
 */
function wrapperCommandArg(toks: string[]): string | null {
  for (let i = 0; i < toks.length; i++) {
    const arg = shellCommandArg(toks, i);
    if (arg !== null && arg !== "") return arg;
  }
  return null;
}

/**
 * One segment, classified from a given command-word index. Split out of the loop
 * so the same segment can be read TWICE when a wrapper's own grammar is ambiguous
 * (see `classifyLaunchCommand`'s fail-safe scan) without duplicating a single rule.
 */
function classifySegment(
  toks: string[],
  cwi: number,
  faked: boolean,
  pwdebug: boolean,
): LaunchFinding | null {
  const { index } = afterRunner(toks, cwi);
  // ⛔ THE PAYLOAD'S *PACKAGE* NAME, NOT ITS VERBATIM TOKEN (round 7 P1-2):
  // `npx electron@30 .` must read the same as `npx electron .`.
  // The RAW token is kept as well: a scoped spec (`@electron-forge/cli`) does not
  // survive `packageBaseName`, which reduces it to its last path segment.
  const headTok = index >= 0 ? toks[index] : toks[cwi];
  const head = packageBaseName(headTok);

  // R-electron: `electron .`, `npx electron .`, `npm exec electron -- .`,
  // `npx electron-forge start`, or a binary inside an Electron bundle.
  const bundle = index >= 0 ? appBundleBinary(toks[index]) : null;
  // ⛔ THE INNER-BINARY SHAPE MUST NOT DEPEND ON WHICH RULE IS ASKING (round-12
  // review, P3). `bundleInnerBinary` was consulted only in the `open` arm, so
  // `open Contents/MacOS/DMeer` fired while the SAME token as the COMMAND WORD —
  // which executes the bundle's binary — was `[]`: no refusal, no ledger row, and
  // the comment above `bundleInnerBinary` plus the README both claim the two
  // spellings agree. An ABSOLUTE `…/X.app/Contents/MacOS/X` is already caught by
  // `appBundleBinary`; this term is the RELATIVE spelling (and any bundle whose
  // `.app` is not in the token, e.g. a cwd inside the bundle).
  const inner = bundle === null && bundleInnerBinary(headTok) ? headTok : null;
  const forge = isElectronForge(headTok) && forgeLaunches(toks, (index >= 0 ? index : cwi) + 1);
  if (bundle || inner !== null || head === "electron" || forge) {
    return {
      rule: "electron",
      app: bundle ?? "Electron",
      argv: toks.join(" "),
      // An Electron app is a GUI app whose own code may request a capture
      // device at any moment — it is the exact shape of the #2249 incident.
      media: true,
      faked,
    };
  }

  // R-open: `open -a <app>` / `open -b <bundle-id>` / `open <path>.app`.
  if (head === "open" || head === "xdg-open") {
    const rest = toks.slice(index >= 0 ? index + 1 : cwi + 1);
    let app: string | null = null;
    let fromFlag = false;
    // ⛔ WHICH option letter took the argument decides whether a trailing `.app`
    // is a BUNDLE or part of an IDENTIFIER. `-b` takes a bundle ID, and
    // `open -nb com.example.app` is a legitimate ID that ENDS in `.app` — reading
    // the suffix there would turn a named-app launch into a media shape. Only `-a`
    // (a name or a path) and the positional form can name a bundle.
    let fromIdFlag = false;
    for (let i = 0; i < rest.length; i++) {
      const tok = rest[i];
      // ⛔ THE FLAG CLUSTER IS ONE PREDICATE, WITH THE `-` GUARD (round 7 P1-1 and
      // P2-4): `-a<app>` / `-b<id>` / `-na <name>` / `-bna <id>` hand their ARGUMENT
      // to the option letter, and a plain word never does. The letter comes from
      // the caller's own list, exactly like `attachedShortArg`.
      const flagArg = clusterShortArg(tok, ["a", "b"]);
      if (flagArg !== null) {
        // An empty remainder means the argument is the NEXT token (`-a <app>`,
        // `-na <name>`); a non-empty one is the ATTACHED spelling (`-aDMeer`).
        app = flagArg.arg !== "" ? flagArg.arg : (rest[i + 1] ?? null);
        if (app === null) continue; // a lone `-a` with nothing after it
        fromFlag = true;
        fromIdFlag = flagArg.letter === "b";
        break;
      }
      // ⛔ A BUNDLE'S INNER BINARY IS A BUNDLE (round 12, P2): `open` of
      // `…/X.app/Contents/MacOS/X` — or the relative `Contents/MacOS/X` — used to
      // match NOTHING here, because only a `.app` SUFFIX was accepted, while the
      // identical token as a command word is refused by the electron rule. Two
      // spellings of one launch must not disagree (README:33-35 lists the shape as a
      // recorded kind). The identity is the BUNDLE, not the inner binary, so the
      // ledger's `app` names what the owner would quit.
      // ⛔ A TRAILING SLASH IS THE SAME BUNDLE (round-12 review, P2). Tab
      // completion appends it to a directory, so `open ./Build/DMeer.app/` — the
      // incident's own app — matched NONE of the three tests below (`.app` suffix,
      // the `\.app/Contents…` regex, and `bundleInnerBinary`'s `[^/]+$`) and
      // produced no finding at all, while the `-a` spelling of the SAME token was
      // refused. Trailing slashes are stripped before the shape is judged, and the
      // ledger records the bundle path a human would type.
      const bare = tok.replace(/\/+$/, "");
      const asBundle = appBundleBinary(bare);
      if (bare.endsWith(".app") || asBundle !== null || bundleInnerBinary(bare)) {
        app = asBundle ?? bare;
        fromFlag = false;
        break;
      }
    }
    if (app !== null) {
      // ⛔ AN EXPLICIT BUNDLE *PATH* IS A MEDIA SHAPE; A NAMED APP IS NOT
      // (review cycle 2, F3). `open -a Safari` / `open -b <bundle id>` is the
      // category-B friction the scoping comment records as REJECTED — it is
      // RECORDED, never refused. But `open ./Build/DMeer.app` launches a bundle a
      // lane just built, which is exactly the app in the #2249 incident and the
      // same thing as running its `Contents/MacOS` binary (already `media: true`).
      // Leaving it `false` meant the README's own `select(.media)` lookup could
      // not find it. So: a PATH is a media claim, a NAME is not.
      // ⛔ THE `.app` SUFFIX COUNTS TOO (round-N P2). `open -a DMeer.app` and
      // `open DMeer.app` are the SAME bundle, and the positional arm above and
      // `appBundleBinary` both decide "is this a bundle" by the SUFFIX. Judging
      // only the `/` here made the verdict depend on the SPELLING: the bare name
      // was `media: true` and refused, the `-a`-attached name `media: false` and
      // allowed — a false PASS on the incident's own app, invisible to the
      // README's `select(.media)` lookup. A NAME (`-a Safari`) is still not a
      // path, so the recorded category-B rejection of "block every GUI launch"
      // is untouched.
      const isPath = !fromFlag || app.includes("/") || (!fromIdFlag && app.endsWith(".app"));
      // ⛔ `open` FORWARDS SWITCHES ONLY AFTER `--args` (round 9 P2). Cycle 3 was
      // right that a switch on an `open` line is NOT a mitigation by itself:
      // `open App.app --use-fake-device-for-media-stream` hands them to `open` as
      // FILE ARGUMENTS, so honouring them unconditionally was a false PASS. But
      // `open(1)` says of `--args`: "All remaining arguments are passed to the
      // opened application in the argv parameter to main()" — so after that token
      // the switches ARE argv to the app, which is the standard Electron idiom and
      // a REAL mitigation. Forcing `false` for the whole rule refused correct,
      // mitigated work AND offered `GUI_DEVICE_GUARD_ALLOW_MEDIA=1` — the one
      // documented way past the refusal permitted REAL capture — as the remedy.
      // Both halves are now decided by the token that changes the meaning.
      const argsAt = rest.indexOf("--args");
      const forwarded = argsAt >= 0 ? rest.slice(argsAt + 1) : [];
      const fakedViaArgs =
        forwarded.includes(FAKE_DEVICE_FLAG) && forwarded.includes(FAKE_UI_FLAG);
      return {
        rule: "open",
        app,
        argv: toks.join(" "),
        media: isPath,
        faked: fakedViaArgs,
      };
    }
    return null;
  }

  // R-playwright: a HEADED run can present a real device picker. Headless is
  // recorded by neither rule — see the header's friction note.
  const isPlaywright = head === "playwright" || head === "puppeteer" || head === "playwright-core";
  if (isPlaywright) {
    const rest = toks.slice(Math.max(index, cwi) + 1);
    const headed = rest.some((t) => HEADED_FLAGS.has(t)) ||
      rest.some((t) => HEADED_SUBCOMMANDS.has(t)) ||
      pwdebug ||
      toks.some((t) => /^PWDEBUG=(?!0$|false$)/.test(t));
    if (!headed) return null;
    return { rule: "playwright", app: head, argv: toks.join(" "), media: true, faked };
  }

  return null;
}

/**
 * Classify one bash command line. Pure: no I/O, no env, no cwd — so the threat
 * table can drive every row, and the handler is the only thing that acts.
 *
 * Returns one finding per GUI launch found; an empty array means "not a host GUI
 * app launch" (allow, and record nothing).
 *
 * ⛔ An empty list is NOT an "allow" verdict the handler can trust from a REMOTE
 * shape it failed to parse — which is why every spelling the classifier cannot see
 * is a finding against it, not a residual: the handler returns early on `[]`, so a
 * miss loses the refusal AND the ledger row together (cycles 3, 4 and 5).
 */
export /**
 * Remove bash's line CONTINUATIONS (`\` + newline) before the text is split into
 * segments.
 *
 * ⛔ A CONTINUATION IS NOT A SEPARATOR (round-12 review, HIGH). Bash deletes
 * `\`+newline before word splitting, so
 *
 *     npm exec electron . \
 *       --use-fake-device-for-media-stream --use-fake-ui-for-media-stream
 *
 * is ONE command whose argv carries both switches — but `splitSegments` split on the
 * newline, so the launch landed in one segment and its mitigation in the next. Two
 * failures, in both directions: the mitigated launch was REFUSED (the refusal's own
 * printed remedy was what the lane had already written), and
 * `npx playwright test \` + `--headed` lost the block AND the ledger row.
 *
 * The rules that decide what a continuation is:
 *   - inside SINGLE quotes it is literal text (`'x \` + newline + `y'` prints `x \ny`);
 *   - inside DOUBLE quotes and unquoted it is removed;
 *   - a `\` at the end of a COMMENT is not a continuation at all (`# c \` + newline +
 *     `echo two` runs `echo two` — measured), which is why this runs AFTER
 *     `stripComments` rather than before it.
 */
function joinLineContinuations(text: string): string {
  if (!/\\\r?\n/.test(text)) return text;
  let out = "";
  let sq = false;
  let dq = false;
  for (let i = 0; i < text.length; i++) {
    const ch = text[i];
    if (!sq && ch === "\\") {
      const nx = text[i + 1];
      if (nx === "\n") {
        i += 1;
        continue;
      }
      if (nx === "\r" && text[i + 2] === "\n") {
        i += 2;
        continue;
      }
      out += ch;
      if (dq && nx !== undefined) {
        out += nx;
        i += 1;
      }
      continue;
    }
    if (!dq && ch === "'") {
      sq = !sq;
      out += ch;
      continue;
    }
    if (!sq && ch === '"') {
      dq = !dq;
      out += ch;
      continue;
    }
    out += ch;
  }
  return out;
}

export function classifyLaunchCommand(command: string, depth = 0): LaunchFinding[] {
  const findings: LaunchFinding[] = [];
  // ⛔ A SHELL FED BY A HEREDOC / HERE-STRING RUNS ITS STDIN AS A PROGRAM (round 11,
  // blocking). The scan and the blanking are ONE pass, so the body a rule must read
  // is collected by the same predicate that decides whether it is data — a second
  // parse of `<<` is the #966 defect.
  const heredocs = splitShellStdin(command);
  // Comments are removed BEFORE tokens are read, so a comment can never satisfy
  // the fake-capture mitigation (review cycle 2, F2).
  const body = joinLineContinuations(stripComments(heredocs.cleaned));

  // ⛔ A `PWDEBUG` EXPORTED IN AN EARLIER SEGMENT STILL APPLIES (review cycle 1,
  // F2: `export PWDEBUG=1; npx playwright test` used to classify as `[]` because
  // the assignment is its own segment). Read it from the WHOLE line, once.
  const pwdebug = /(?:^|[\s;|&])(?:export\s+)?PWDEBUG=(?!0\b|false\b)/.test(body);

  for (const segment of splitSegments(body)) {
    // ⛔ A TRAILING `)`/`;`/`&` IS A METACHARACTER, NOT A WORD CHARACTER (round-12
    // review, P1): `(open X.app)` must segment exactly like `open X.app`. Leading
    // metachars are stripped by `commandWordIndex`; trailing ones are stripped
    // here, ONCE, so every predicate sees the word bash sees.
    // Order matters: redirections are removed from the RAW tokens (a bare `>` must
    // not be emptied first), then a trailing metacharacter is stripped, so
    // `(open X.app)` and `--headed>log` are both reduced to the word bash runs.
    const toks = stripRedirections(
      tokenize(segment).map((t) => t.replace(/^[({]+/, "")),
    ).map(stripTrailingMetachars);
    if (toks.length === 0) continue;
    const flags: { sawFlag?: boolean; payloadStart?: number } = {};
    const cwi = commandWordIndex(toks, flags);
    if (cwi < 0) {
      // ⛔ A WRAPPER CAN CONSUME ITS WHOLE SEGMENT (`flock -c"<cmd>"`, `su -c
      // "<cmd>"`): there is no command word left to locate, but the command string
      // is still ARGV and still executes. Without this, the ATTACHED spelling of
      // `flock -c` was `[]` even with the flag table fixed, because the prefix's
      // generic flag-skip ate the token and left nothing behind (review cycle 5,
      // F1). `cwi >= 0` segments take the wrapper branch below as before.
      if (depth < MAX_WRAPPER_DEPTH) {
        // ⛔ ANY POSITION, NOT JUST TOKEN 0 (round 7 P1-3): `sudo env -S "…"`
        // resolves no command word and the wrapper sits at index 1.
        const body0 = wrapperCommandArg(toks);
        if (body0 !== null && body0 !== "") {
          findings.push(...classifyLaunchCommand(body0, depth + 1));
        }
      }
      continue;
    }

    // ⛔ THE MITIGATION IS READ FROM ARGV, NOT FROM SHELL TEXT (review cycle 2,
    // F2). Segments were never comment-stripped, so
    // `electron . # --use-fake-device-for-media-stream --use-fake-ui-…` read the
    // two switches out of the COMMENT and allowed the launch while Chromium
    // received neither — a false PASS in the exact direction this guard exists to
    // prevent, reachable by pasting the guard's own refusal text.
    const faked = toks.includes(FAKE_DEVICE_FLAG) && toks.includes(FAKE_UI_FLAG);
    const { execVerb } = afterRunner(toks, cwi);

    const primary = classifySegment(toks, cwi, faked, pwdebug);
    if (primary) {
      findings.push(primary);
      continue;
    }

    // ⛔ A NESTED EXEC-STYLE RUNNER IS A LAUNCH SHAPE (review cycle 3's CLASS,
    // narrowed in round 7 P2-5). There is no command database, so a wrapper word
    // the table has never heard of is unrecognisable — but `npm exec` / `npx` /
    // `bun x` / `mise exec` is itself the announcement that the next word is a
    // PROGRAM, and that reads the same behind ANY prefix: `eatmydata npm exec
    // electron .`, `sudo npm exec electron .`, `xvfb-run -a npm exec electron .`.
    // The EXEC VERB is what makes it a launch shape (`afterRunner().execVerb`), not
    // the mere presence of a runner name: a runner that is only INSTALLING or
    // RUNNING A SCRIPT (`sudo npm install electron -D`, `bun install electron`) is
    // not launching it, and reading the runner NAME alone refused both (round 7
    // P2-5's over-fire). The payload index it resolves is classified directly, so
    // the rescue is positional rather than a word scan.
    let nestedPayload = -1;
    for (let i = 1; i < toks.length; i++) {
      if (!RUNNERS.has(basename(toks[i]))) continue;
      const nested = afterRunner(toks, i);
      if (nested.execVerb && nested.index > i) {
        nestedPayload = nested.index;
        break;
      }
    }
    if (nestedPayload >= 0 && nestedPayload !== cwi) {
      const rescued = classifySegment(toks, nestedPayload, faked, pwdebug);
      if (rescued) {
        findings.push(rescued);
        continue;
      }
    }

    // R-failsafe: a PREFIX that consumed a flag, or an EXEC-style runner, can have
    // swallowed the command word with a flag this table does not know (review cycle
    // 2, F1: `sudo --user root electron .`; L15j/L15k). ⛔ GATED ON A FLAG ACTUALLY
    // BEING SKIPPED (round 7 P2-5): with no flag between the prefix and the command
    // word, nothing could have swallowed it, so `sudo rg electron .`, `timeout 30 rg
    // electron .` and `timeout 60 grep -rn electron src/` are a SEARCH and stay
    // clean, instead of being refused by a word scan that rescued any later
    // `electron`. A prefix that DID skip a flag keeps the over-fire, which is the
    // declared direction (README's Declared residuals).
    if (flags.sawFlag || execVerb) {
      // A skipped POSITIONAL can also have swallowed the command word, and it sits
      // BEFORE the resolved word — so the scan starts at the payload, not after it.
      const from = flags.payloadStart !== undefined ? flags.payloadStart : cwi + 1;
      const alt = launchWordIndex(toks, from);
      if (alt >= 0 && alt !== cwi) {
        const rescued = classifySegment(toks, alt, faked, pwdebug);
        if (rescued) {
          findings.push(rescued);
          continue;
        }
      }
    }

    // R-wrapper: `bash -c "<cmd>"`, `sh -c …`, `sudo bash -lc …`, `flock … -c …`,
    // `su -c …`, `eval …` — the command string is ARGV, so it is re-read rather
    // than declared away (review cycle 1, F2: these were an UNDECLARED bypass of
    // R2, and `AGENTS.md`/the runbooks hand lanes `bash -c` idioms routinely).
    if (depth < MAX_WRAPPER_DEPTH) {
      const head = basename(toks[cwi]);
      // ⛔ READ THE COMMAND STRING FROM THE WRAPPER, NOT FROM THE RESOLVED
      // COMMAND WORD (review cycle 3, F1): in `flock /tmp/l -c "npm exec electron
      // ."` the resolved word is the LOCK PATH, so asking it for a `-c` argument
      // found nothing. `toks[0]` is the wrapper (already metachar-stripped by
      // `commandWordIndex`); the `cwi` read stays as the fallback for
      // `sudo bash -c "…"`, where the wrapper is `sudo` and the shell is `bash`.
      const shellBody = wrapperCommandArg(toks);
      const evalBody = head === "eval" ? toks.slice(cwi + 1).join(" ") : null;
      // ⛔ `watch … "<cmd>"` / `watch … <cmd> …` — the operand IS a `sh -c` script
      // (see PREFIX_COMMAND_OPERAND). Read from the resolved command word so a flag
      // that consumed a value cannot leave a `--flag` token where the script begins.
      const operandBody = PREFIX_COMMAND_OPERAND.has(basename(toks[0] ?? ""))
        ? toks.slice(Math.max(cwi, 1)).join(" ")
        : null;
      const nested = shellBody ?? evalBody ?? operandBody;
      if (nested !== null && nested !== "") {
        findings.push(...classifyLaunchCommand(nested, depth + 1));
        continue;
      }
    }
  }

  // R-substitution: the body of `$( … )` / `< ( … )` / `> ( … )` / backticks
  // executes, so it is classified as its own command line. Recurse rather than
  // declare. (`extractSubstitutions` gates the process-substitution spellings on
  // the double-quote state; a quoted `< ( … )` is literal text.)
  if (depth < MAX_WRAPPER_DEPTH) {
    for (const sub of extractSubstitutions(body)) {
      findings.push(...classifyLaunchCommand(sub, depth + 1));
    }
  }
  // R-stdin: the body of a heredoc/here-string a SHELL will execute. Same bounded
  // recursion the `-c` argument uses, and for the same reason: the program is in the
  // command string the hook received, so it is argv the classifier must read —
  // returning `[]` here loses the refusal AND the ledger row together.
  if (depth < MAX_WRAPPER_DEPTH) {
    for (const program of heredocs.programs) {
      findings.push(...classifyLaunchCommand(program, depth + 1));
    }
  }
  return findings;
}

// ── the ledger ──────────────────────────────────────────────────────────────

export interface LaunchRecord {
  event: "host-app-launch";
  ts: string;
  issue: 2249;
  decision: "record" | "block";
  rule: LaunchRule;
  app: string;
  argv: string;
  media: boolean;
  faked: boolean;
  cwd: string;
  pid: number;
  ppid: number;
  host: string;
  lane: boolean;
  tag: string | null;
}

/**
 * Append ONE row to the launch ledger. Best-effort by design (a guard must not
 * break a lane over a full disk) but never SILENT: every failure goes to
 * `warn`, because a ledger that quietly stopped writing is the no-op gate this
 * repo treats as a defect (#2249 asks for silence to be impossible).
 */
export function recordLaunch(
  record: LaunchRecord,
  recordPath: string,
  warn: Warn = defaultWarn,
): boolean {
  try {
    mkdirSync(dirname(recordPath), { recursive: true });
    appendFileSync(recordPath, `${JSON.stringify(record)}\n`, { encoding: "utf8", mode: 0o644 });
    return true;
  } catch (err) {
    warn(
      `could not write the app-launch ledger at ${recordPath} (${(err as Error).message}) — ` +
        "the launch is NOT recorded; fix the path or permissions before trusting the ledger",
    );
    return false;
  }
}

// ── the unattended predicate ────────────────────────────────────────────────

/**
 * Is this an UNATTENDED run — the audience a device seizure harms? Derived from
 * the process, never from a launcher's variable (the `shared/headless-lane.ts`
 * rule): print mode, or a headless run in a LINKED worktree.
 *
 * An interactive session is never guarded. A human at their own prompt typing
 * `open -a Safari` is not #2249.
 */
export function isUnattended(
  env: Record<string, string | undefined> = process.env,
  argv: string[] = process.argv,
): boolean {
  if (isPrintMode(env, argv)) return true;
  try {
    return laneContract().lane === true;
  } catch {
    // A git probe that throws is NOT evidence of a lane. Fail toward "guarded
    // arm stays guarded": an unattended run inside a linked worktree already
    // says so via print mode, which is checked above.
    return false;
  }
}

/**
 * `laneContract()`, made TOTAL — the pre-hook must never throw.
 *
 * ⛔ `deriveLaneContract` calls `process.cwd()` unguarded, which throws `ENOENT`
 * once the lane's worktree has been reaped out from under it
 * (`scripts/pi-reap-worktrees.sh`). `bash` keeps working in a deleted cwd, so the
 * only visible symptom was an opaque `uv_cwd` failure of the lane's own command.
 * An underivable contract is NOT evidence of a lane (the same call `isUnattended`
 * already makes), and it is never an exception.
 */
function safeLane(): { lane: boolean; tag: string | null } {
  try {
    const contract = laneContract();
    return { lane: contract.lane === true, tag: contract.tag ?? null };
  } catch {
    return { lane: false, tag: null };
  }
}

/** `process.cwd()`, made TOTAL — a removed cwd is a recorded fact, not a throw. */
function safeCwd(): string {
  try {
    return process.cwd();
  } catch {
    return "<cwd removed>";
  }
}

/**
 * The block's reason — names the incident, the remedy that actually applies, and
 * the hatch.
 *
 * ⛔ THE REMEDY IS PER-RULE (review cycle 3, minor; corrected round 9 P2). For
 * every Electron/Playwright shape the fix is the two Chromium switches. For
 * `open <path>.app` the switches only reach the app after a `--args` token —
 * without it they are file arguments to `open` and the first cut honoured them,
 * making the refusal's own remedy invert the gate. So this rule names the
 * `--args` spelling and no longer claims `open` cannot forward them at all.
 */
export function blockReason(finding: LaunchFinding, recordPath: string): string {
  if (finding.rule === "open") {
    return [
      `[gui-device-guard] 🚫 Blocked: this run opens a GUI app BUNDLE, which can take the REAL camera/microphone (#2249).`,
      ``,
      `  app: ${finding.app}`,
      `  argv: ${finding.argv}`,
      ``,
      `On 2026-10-21 a lane's Electron app held AVCaptureDevice, so Meet said "camera in use"`,
      `five minutes before a customer call — and killing the APP did not help, because the live`,
      `LANE relaunched it. Only killing the lane released the devices.`,
      ``,
      `There is no direct switch to add here: \`open\` forwards arguments to the app`,
      `only AFTER a \`--args\` token — without it they are FILE arguments to \`open\`.`,
      `So the ways past this refusal are`,
      `  · \`open <bundle>.app --args ${FAKE_FLAGS_HINT}\`, or`,
      `  · run the bundle's test harness with ${FAKE_FLAGS_HINT}, or`,
      `  · ${ALLOW_MEDIA}=1 for one deliberate real-device launch (still recorded).`,
      `Launch ledger: ${recordPath}`,
    ].join("\n");
  }
  return [
    `[gui-device-guard] 🚫 Blocked: this run launches a host GUI app that can take the REAL camera/microphone, and it did not ask for a fake device (#2249).`,
    ``,
    `  rule: ${finding.rule}   app: ${finding.app}`,
    `  argv: ${finding.argv}`,
    ``,
    `On 2026-10-21 a lane's \`npm exec electron .\` held AVCaptureDevice, so Meet said`,
    `"camera in use" five minutes before a customer call — and killing the APP did not`,
    `help, because the live LANE relaunched it. Only killing the lane released the devices.`,
    ``,
    `Add BOTH Chromium switches to the launch:`,
    `  ${FAKE_FLAGS_HINT}`,
    ``,
    `For one deliberate real-device run, set ${ALLOW_MEDIA}=1 (it is recorded either way).`,
    `Launch ledger: ${recordPath}`,
  ].join("\n");
}

// ── registration ────────────────────────────────────────────────────────────

export default function guiDeviceGuard(pi: ExtensionAPI): void {
  pi.on("tool_call", async (event, _ctx) => {
    if (!isToolCallEventType("bash", event)) return undefined;
    if (process.env[KILL_SWITCH] === "1") return undefined;
    const command = (event.input as { command?: string }).command ?? "";
    if (!command) return undefined;
    if (!isUnattended()) return undefined;

    const findings = classifyLaunchCommand(command);
    if (findings.length === 0) return undefined;

    const recordPath = process.env[RECORD_ENV] || defaultRecordPath();
    // ⛔ NEITHER OF THESE MAY THROW (review P1). `laneContract()` reaches
    // `process.cwd()` (shared/headless-lane.ts), which throws `ENOENT` when the
    // lane's cwd has been REMOVED — and print mode short-circuits the guarded
    // copy in `isUnattended()`, so the throw lands here, in the pre-hook. A throw
    // out of this hook FAILS the lane's own bash call and loses both halves of
    // #2249 at once (no block, no ledger row) on a shape the guard is otherwise
    // correct about. A lane we cannot derive is recorded as "not provably a
    // lane", never as a crash; a cwd we cannot read is recorded as unreadable.
    const lane = safeLane();
    const cwd = safeCwd();
    let blocked: LaunchFinding | null = null;

    for (const finding of findings) {
      const mediaBlocked = finding.media && !finding.faked && process.env[ALLOW_MEDIA] !== "1";
      if (mediaBlocked) blocked = finding;
      recordLaunch(
        {
          event: "host-app-launch",
          ts: new Date().toISOString(),
          issue: 2249,
          decision: mediaBlocked ? "block" : "record",
          rule: finding.rule,
          app: finding.app,
          argv: finding.argv,
          media: finding.media,
          faked: finding.faked,
          cwd,
          pid: process.pid,
          ppid: process.ppid,
          host: hostname(),
          lane: lane.lane === true,
          tag: lane.tag ?? null,
        },
        recordPath,
      );
    }

    if (blocked) return { block: true, reason: blockReason(blocked, recordPath) } as LaunchVerdict;
    return undefined;
  });
}
