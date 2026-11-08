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
 *      `GUI_DEVICE_GUARD_RECORD`). Kinds: an Electron invocation, a macOS `open
 *      -a`/`-b`/`.app` launch, an executable inside `…/Contents/MacOS/`. The
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
 * `$( … )` / backticks are RECURSED INTO (bounded to 3 levels), because the
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
 *     argv, at the moment this hook sees the command.
 *   - A GUI launch built by a shell variable (`APP=Electron; open -a "$APP"`) is
 *     not expanded: the token is `$APP` and the guard records it as an `open`
 *     launch with the unexpanded app name. Recording the SHAPE is still worth
 *     more than the exact string.
 *   - A WRAPPER WORD the table above has never heard of, in front of a launch
 *     word that no package-runner introduces (`xvfb-run -a electron`) is not
 *     classified. This cannot be closed structurally: with no command database,
 *     `grep -rn electron src/` and a wrapped bare launch are the same token
 *     shape, so widening further would refuse the SEARCH. The list is deliberate
 *     and finite — one word to add — and a runner-nested launch is caught behind
 *     ANY wrapper (`xvfb-run -a npm exec electron .`), which is the shape a lane
 *     actually writes.
 *   - Declared OVER-FIRE: an UNQUOTED line that only PRINTS a runner launch
 *     (`echo npm exec electron .`) is refused, because a runner anywhere in the
 *     segment counts. Quoting it is the workaround, and `ALLOW_MEDIA=1` waives one
 *     run — an over-fire is waivable, a miss is not.
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
 */
const COMMAND_STRING_FLAGS: Record<string, string[]> = {
  bash: ["-c"], sh: ["-c"], zsh: ["-c"], dash: ["-c"], ksh: ["-c"], ash: ["-c"],
  busybox: ["-c"], flock: ["-c", "--command"], script: ["-c", "--command"],
  su: ["-c", "--command", "--session-command"], runuser: ["-c", "--command"],
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
 * Shell grouping / control-flow words sit where a command word would.
 *
 * `(`/`{` arrive as their OWN token only when the operator is SPACED; when it is
 * attached (`(npm …`) `stripLeadingMetachars` normalises the token instead. Both
 * spellings are now covered — the spaced one by `commandWordIndex`'s leading-token
 * drop (review cycle 4, F1), which is why a bare `(`/`{` never reaches this set.
 */
const TRANSPARENT = new Set(["{", "}", "(", ")", "then", "do", "done", "fi", "else", "elif", "if", "while"]);

/** Package-runners whose first PACKAGE argument is the thing being launched. */
const RUNNERS = new Set(["npx", "npm", "pnpm", "yarn", "bunx"]);

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
export function splitSegments(command: string): string[] {
  const mask = unquotedMask(command);
  const out: string[] = [];
  let cur = "";
  for (let i = 0; i < command.length; i++) {
    const ch = command[i];
    if (mask[i] && SEPARATORS.has(ch)) {
      out.push(cur);
      cur = "";
      continue;
    }
    cur += ch;
  }
  out.push(cur);
  return out.map((s) => s.trim()).filter((s) => s.length > 0);
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
/**
 * Index of the `#` that starts a COMMENT on `line`, or -1.
 *
 * One rule, two readers: `stripComments` (which cuts the line there) and
 * `stripHeredocBodies` (which must not read a `<<` that lives in a comment).
 * Duplicating it is the #966 defect — a second copy of a parse rule.
 */
function commentCutIndex(line: string, base: number, mask: boolean[]): number {
  for (let i = 0; i < line.length; i++) {
    if (line[i] !== "#") continue;
    if (mask[base + i] !== true) continue;             // quoted: data, not a comment
    const prev = i === 0 ? " " : line[i - 1];
    if (/\s/.test(prev) || ";&|(".includes(prev)) return i;
  }
  return -1;
}

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
 * Declared residual: a `<<` inside an ARITHMETIC expansion (`$(( n << shift ))`)
 * is still read as a redirect, because the delimiter there (`shift`) is a legal
 * word. It is not closable without a real arithmetic grammar, it deletes DATA in
 * the safe direction only when no later line equals the variable name, and the
 * direction is stated rather than claimed complete.
 */
export function stripHeredocBodies(command: string): string {
  if (!command.includes("<<")) return command;
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
  for (let li = 0; li < lines.length; li++) {
    const line = lines[li];
    out.push(line);
    const base = starts[li];
    const cut = commentCutIndex(line, base, mask);
    const re = /<<(-?)\s*(['"]?)([A-Za-z_][A-Za-z0-9_]*)\2/g;
    let m: RegExpExecArray | null;
    let delim: string | null = null;
    while ((m = re.exec(line)) !== null) {
      const idx = base + m.index;
      if (mask[idx] === false) continue; // quoted `<<` inside a string, not a redirect
      // ⛔ A COMMENTED `<<` IS DATA (review cycle 5, F2) — see the header. It used
      // to delete every following line, which lost the block AND the ledger row.
      if (cut !== -1 && m.index > cut) continue;
      delim = m[3];
    }
    if (delim === null) continue;
    // Consume body lines through the terminator (which is kept: it carries no command).
    let j = li + 1;
    while (j < lines.length && lines[j].replace(/^\t+/, "") !== delim) {
      out.push("");
      j++;
    }
    if (j < lines.length) {
      out.push("");
      li = j;
    } else {
      li = lines.length;
    }
  }
  return out.join("\n");
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

/** `A=B` leading assignment (an env prefix, not a command word). */
function isAssignment(tok: string): boolean {
  return /^[A-Za-z_][A-Za-z0-9_]*=/.test(tok);
}

function basename(p: string): string {
  const b = p.split("/").pop() ?? p;
  return b.replace(/\.exe$/i, "");
}

/**
 * Index of the command word: skip leading `A=B` assignments, prefix-like words
 * (and the values their own flags consume) and grouping words. Returns -1 when
 * the segment holds no command word.
 */
function commandWordIndex(toks: string[], out?: { prefixSeen?: boolean }): number {
  // ⛔ AN OPERATOR TOKEN IS SEPARATION, NOT A COMMAND WORD (review cycle 4, F1).
  // `stripLeadingMetachars` strips metacharacters from INSIDE a token, so a token
  // that IS a metachar became `""` — and `""` was accepted as the command word.
  // `classifySegment` then returned `null` for it, `prefixSeen` stayed false (the
  // `PREFIXES` loop was never entered), and the hint at index 1 was never asked
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
  let prefixSeen = false;
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
      prefixSeen = true;
      const valueFlags = PREFIX_VALUE_FLAGS[tok] ?? [];
      i++;
      // ⛔ ONE LOOP FOR EVERY PREFIX (review cycle 2, F1). `timeout` used to have
      // its own branch that `continue`d BEFORE the generic skip, so any long
      // option (`--preserve-status`, `--foreground`, `--verbose`) left a `--flag`
      // token sitting where the command word belongs and the segment became
      // unclassifiable. Its duration argument is now just another positional.
      while (i < toks.length && toks[i].startsWith("-")) {
        // `--flag=value` is SELF-CONTAINED and consumes no following word.
        if (toks[i].includes("=")) {
          i += 1;
        } else if (valueFlags.includes(toks[i])) {
          i += 2;
        } else {
          i += 1;
        }
      }
      if (tok === "timeout" && i < toks.length && TIMEOUT_DURATION.test(toks[i])) i++;
      continue;
    }
    if (out) out.prefixSeen = prefixSeen;
    return i;
  }
  if (out) out.prefixSeen = prefixSeen;
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
    if (LAUNCH_WORDS.has(basename(tok)) || appBundleBinary(tok) !== null) return i;
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
 * Classify one bash command line. Pure: no I/O, no env, no cwd — so the threat
 * table can drive every row, and the handler is the only thing that acts.
 *
 * Returns one finding per GUI launch found; an empty array means "not a host GUI
 * app launch" (allow, and record nothing).
 */
/**
 * The bodies of every command substitution in a command line — `$( … )` and
 * `` ` … ` `` — that is NOT inside single quotes.
 *
 * ⛔ SINGLE-QUOTED MATTERS (review cycle 1, F2's twin). `unquotedMask` cannot be
 * used here: it masks `$(…)` inside DOUBLE quotes too, and a double-quoted
 * substitution IS executed (`echo "$(npm exec electron .)"` launches the app).
 * A single-quoted one is literal text, and treating it as a launch is the exact
 * false BLOCK this guard already paid for once (`git commit` message bodies).
 * Parenthesis depth is counted so `$(a $(b))` yields the outer body whole.
 */
export function extractSubstitutions(command: string): string[] {
  const bodies: string[] = [];
  let i = 0;
  while (i < command.length) {
    const ch = command[i];
    if (ch === "'") {
      // Skip a single-quoted run wholesale.
      const end = command.indexOf("'", i + 1);
      i = end === -1 ? command.length : end + 1;
      continue;
    }
    if (ch === "`") {
      const end = command.indexOf("`", i + 1);
      if (end === -1) break;
      bodies.push(command.slice(i + 1, end));
      i = end + 1;
      continue;
    }
    if (ch === "$" && command[i + 1] === "(") {
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
 * The command-string argument of a wrapper that takes one — the shell's `-c`
 * (also `-lc`, `-ec`, `-o pipefail -c`), `flock -c`, `script -c` — or null.
 *
 * ⛔ GENERALISED FROM THE SHELL-ONLY CASE (review cycle 3, F1): `flock /tmp/l -c
 * "npm exec electron ."` was invisible because only `bash`-family heads were
 * re-read. `COMMAND_STRING_FLAGS` names the flag per head, so a wrapper added
 * later is one table row rather than a second branch.
 */
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

function shellCommandArg(toks: string[], headIndex: number): string | null {
  const head = basename(toks[headIndex] ?? "");
  const flags = COMMAND_STRING_FLAGS[head];
  if (!flags) return null;
  for (let i = headIndex + 1; i < toks.length; i++) {
    const tok = toks[i];
    if (tok === "--") continue;
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
  const head = index >= 0 ? basename(toks[index]) : basename(toks[cwi]);

  // R-electron: `electron .`, `npx electron .`, `npm exec electron -- .`,
  // or a binary inside an Electron bundle.
  const bundle = index >= 0 ? appBundleBinary(toks[index]) : null;
  if (bundle || head === "electron") {
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
    for (let i = 0; i < rest.length; i++) {
      const tok = rest[i];
      if ((tok === "-a" || tok === "-b") && i + 1 < rest.length) {
        app = rest[i + 1];
        fromFlag = true;
        break;
      }
      if (tok === "-a" || tok === "-b") continue;
      // ⛔ `-a<app>` / `-b<id>` — the ATTACHED spelling (review cycle 5, F1).
      // `open -a"Google Chrome"` tokenises to `-aGoogle Chrome`, matched no
      // branch, and the launch was `[]`: not refused (correct — a NAMED app is
      // record-only) but also NOT RECORDED, which loses R1 — the half of #2249
      // that would have cut the incident to one `jq` lookup. The flag letter must
      // be the FIRST one (a cluster is not a thing for `open`), so `--args` and
      // `open -R`/`-n`/`-g` are untouched.
      if (tok.length > 2 && !tok.startsWith("--") && (tok[1] === "a" || tok[1] === "b")) {
        app = tok.slice(2);
        fromFlag = true;
        break;
      }
      if (tok.endsWith(".app")) {
        app = tok;
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
      const isPath = !fromFlag || app.includes("/");
      return {
        rule: "open",
        app,
        argv: toks.join(" "),
        media: isPath,
        // ⛔ `faked` is FORCED false for this rule: `open` does not forward
        // Chromium switches, so a line that carries them is not a mitigation —
        // honouring it was a false PASS (review cycle 3, minor, reproduced).
        faked: false,
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

export function classifyLaunchCommand(command: string, depth = 0): LaunchFinding[] {
  const findings: LaunchFinding[] = [];
  // Comments are removed BEFORE tokens are read, so a comment can never satisfy
  // the fake-capture mitigation (review cycle 2, F2).
  const body = stripComments(stripHeredocBodies(command));

  // ⛔ A `PWDEBUG` EXPORTED IN AN EARLIER SEGMENT STILL APPLIES (review cycle 1,
  // F2: `export PWDEBUG=1; npx playwright test` used to classify as `[]` because
  // the assignment is its own segment). Read it from the WHOLE line, once.
  const pwdebug = /(?:^|[\s;|&])(?:export\s+)?PWDEBUG=(?!0\b|false\b)/.test(body);

  for (const segment of splitSegments(body)) {
    const toks = tokenize(segment);
    if (toks.length === 0) continue;
    const flags: { prefixSeen?: boolean } = {};
    const cwi = commandWordIndex(toks, flags);
    if (cwi < 0) {
      // ⛔ A WRAPPER CAN CONSUME ITS WHOLE SEGMENT (`flock -c"<cmd>"`, `su -c
      // "<cmd>"`): there is no command word left to locate, but the command string
      // is still ARGV and still executes. Without this, the ATTACHED spelling of
      // `flock -c` was `[]` even with the flag table fixed, because the prefix's
      // generic flag-skip ate the token and left nothing behind (review cycle 5,
      // F1). `cwi >= 0` segments take the wrapper branch below as before.
      if (depth < MAX_WRAPPER_DEPTH) {
        const body0 = shellCommandArg(toks, 0);
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

    // ⛔ A PACKAGE-RUNNER ANYWHERE IN THE SEGMENT IS A LAUNCH SHAPE, whatever
    // heads the segment (review cycle 3, F1's CLASS rather than its instances).
    // The wrapper table above cannot close this class — there is no command
    // database, so a wrapper word it has never heard of is unrecognisable — but a
    // runner does not need to be recognised as a WRAPPER: `npm exec`/`npx`/
    // `pnpm dlx` is itself the announcement that the next word is a program, and
    // that reads the same behind ANY prefix. `xvfb-run -a npm exec electron .`,
    // `strace -f npx playwright test --headed` and `systemd-run --user npm exec
    // electron .` were all `[]` (no block, no ledger row) before this. Rows
    // L19h/L19i name no wrapper at all, so deleting this rule cannot stay green.
    const runnerNested = toks.some((t, i) => i > 0 && RUNNERS.has(basename(t)));

    // R-failsafe: a PREFIX or an EXEC-style runner can swallow the command word
    // with a value-taking flag this table does not know (review cycle 2, F1:
    // `sudo --user root electron .`). Only those shapes are scanned, so a plain
    // `rg electron .` is untouched.
    if (flags.prefixSeen || execVerb || runnerNested) {
      const alt = launchWordIndex(toks, cwi + 1);
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
      const shellBody = shellCommandArg(toks, 0) ?? shellCommandArg(toks, cwi);
      const evalBody = head === "eval" ? toks.slice(cwi + 1).join(" ") : null;
      const nested = shellBody ?? evalBody;
      if (nested !== null && nested !== "") {
        findings.push(...classifyLaunchCommand(nested, depth + 1));
        continue;
      }
    }
  }

  // R-substitution: the body of `$( … )` / backticks executes, so it is
  // classified as its own command line. Recurse rather than declare.
  if (depth < MAX_WRAPPER_DEPTH) {
    for (const sub of extractSubstitutions(body)) {
      findings.push(...classifyLaunchCommand(sub, depth + 1));
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
 * The block's reason — names the incident, the remedy that actually applies, and
 * the hatch.
 *
 * ⛔ THE REMEDY IS PER-RULE (review cycle 3, minor). For every Electron/Playwright
 * shape the fix is the two Chromium switches. For `open <path>.app` it is NOT:
 * `open` does not forward Chromium switches, and appending them to the `open`
 * argv made `faked` true and ALLOWED the launch while the app received nothing —
 * a remedy that inverts the gate. So that rule names only the escape hatch.
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
      `There is no fake-capture switch to add here: \`open\` does not forward Chromium switches,`,
      `so the only ways past this refusal are`,
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
    const lane = laneContract();
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
          cwd: process.cwd(),
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
