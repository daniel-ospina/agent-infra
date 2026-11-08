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
 * ── DECLARED RESIDUALS (nothing here is silently "not a launch") ─────────────
 *   - `node script.js` that `require("electron")`s, a Swift/ObjC helper, a
 *     compiled `.app` started by name through a shell function, `xcodebuild
 *     test`, and `xcrun simctl` launches are NOT classified. argv cannot tell
 *     them apart from a plain `node` run; inventing a heuristic there would
 *     block correct work.
 *   - A GUI launch built by a shell variable (`APP=Electron; open -a "$APP"`) is
 *     not expanded: the token is `$APP` and the guard records it as an `open`
 *     launch with the unexpanded app name. Recording the SHAPE is still worth
 *     more than the exact string.
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
]);

/** The value-taking options of the prefixes above, per GNU/BSD's own grammars. */
const PREFIX_VALUE_FLAGS: Record<string, string[]> = {
  sudo: ["-u", "-g", "-p", "-C", "-D", "-h", "-r", "-t", "-U", "-R", "-T", "-c"],
  doas: ["-u", "-C"],
  nice: ["-n"],
  ionice: ["-c", "-n", "-p"],
  env: ["-u", "-C", "-S"],
  stdbuf: ["-i", "-o", "-e"],
};

/** `timeout`'s own duration (`30`, `2.5s`, `1m`), or its `-s`\/`-k` value. */
const TIMEOUT_DURATION = /^\d+(\.\d+)?[smhd]?$/;

/** Shell grouping / control-flow words sit where a command word would. */
const TRANSPARENT = new Set(["{", "}", "(", ")", "then", "do", "done", "fi", "else", "elif", "if", "while"]);

/** Package-runners whose first PACKAGE argument is the thing being launched. */
const RUNNERS = new Set(["npx", "npm", "pnpm", "yarn", "bunx"]);

/** A headed-browser signal: the run can present a real device picker. */
const HEADED_FLAGS = new Set(["--headed", "--ui", "--debug", "--pause"]);

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
 * Blank out heredoc BODIES before segmentation.
 *
 * A heredoc body is DATA, not shell: `git commit -F - <<'EOF'` whose message
 * mentions `electron .` used to yield a second segment reading `electron . is
 * what broke`, i.e. a launch — a false BLOCK on the fleet's own commit idiom.
 * A guard that refuses correct work is the category-B friction `AGENTS.md`
 * names, so the body is removed rather than tolerated.
 *
 * Deliberately simple and one-directional: an unrecognised heredoc leaves the
 * text in place, which can only make the guard MORE likely to fire (over-read),
 * never less.
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
    const re = /<<(-?)\s*(['"]?)([A-Za-z_][A-Za-z0-9_]*)\2/g;
    let m: RegExpExecArray | null;
    let delim: string | null = null;
    while ((m = re.exec(line)) !== null) {
      const idx = base + m.index;
      if (mask[idx] === false) continue; // quoted `<<` inside a string, not a redirect
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
function commandWordIndex(toks: string[]): number {
  let i = 0;
  while (i < toks.length) {
    const tok = toks[i];
    if (isAssignment(tok) || TRANSPARENT.has(tok)) {
      i++;
      continue;
    }
    if (PREFIXES.has(tok)) {
      const valueFlags = PREFIX_VALUE_FLAGS[tok] ?? [];
      i++;
      if (tok === "timeout" && i < toks.length) {
        // `timeout 30 electron .` / `timeout -s KILL 30 electron .`
        while (i < toks.length && (toks[i] === "-s" || toks[i] === "-k")) i += 2;
        if (i < toks.length && TIMEOUT_DURATION.test(toks[i])) i++;
        continue;
      }
      while (i < toks.length && valueFlags.includes(toks[i])) i += 2;
      continue;
    }
    return i;
  }
  return -1;
}

/** Strip a package-runner prefix, returning the package/command index. */
function afterRunner(toks: string[], start: number): { index: number; runner: string | null } {
  const word = basename(toks[start] ?? "");
  if (!RUNNERS.has(word)) return { index: start, runner: null };
  let i = start + 1;
  while (i < toks.length) {
    const tok = toks[i];
    if (tok === "exec" || tok === "dlx" || tok === "x") {
      i++;
      continue;
    }
    if (tok === "--") {
      i++;
      continue;
    }
    if (tok.startsWith("-")) {
      // `npm exec --yes electron` / `npx --package electron`: consume the flag's
      // value only for the two spellings that take one.
      if ((tok === "--package" || tok === "-p") && i + 1 < toks.length) i += 2;
      else i++;
      continue;
    }
    return { index: i, runner: word };
  }
  return { index: -1, runner: word };
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
export function classifyLaunchCommand(command: string): LaunchFinding[] {
  const findings: LaunchFinding[] = [];
  for (const segment of splitSegments(stripHeredocBodies(command))) {
    const toks = tokenize(segment);
    if (toks.length === 0) continue;
    const cwi = commandWordIndex(toks);
    if (cwi < 0) continue;

    const faked = toks.includes(FAKE_DEVICE_FLAG) && toks.includes(FAKE_UI_FLAG);
    const { index, runner } = afterRunner(toks, cwi);
    const head = index >= 0 ? basename(toks[index]) : basename(toks[cwi]);

    // R-electron: `electron .`, `npx electron .`, `npm exec electron -- .`,
    // or a binary inside an Electron bundle.
    const bundle = index >= 0 ? appBundleBinary(toks[index]) : null;
    if (bundle || head === "electron") {
      findings.push({
        rule: "electron",
        app: bundle ?? "Electron",
        argv: toks.join(" "),
        // An Electron app is a GUI app whose own code may request a capture
        // device at any moment — it is the exact shape of the #2249 incident.
        media: true,
        faked,
      });
      continue;
    }

    // R-open: `open -a <app>` / `open -b <bundle-id>` / `open Foo.app`.
    if (runner === null && (head === "open" || head === "xdg-open") && cwi >= 0) {
      const rest = toks.slice(cwi + 1);
      let app: string | null = null;
      for (let i = 0; i < rest.length; i++) {
        const tok = rest[i];
        if ((tok === "-a" || tok === "-b") && i + 1 < rest.length) {
          app = rest[i + 1];
          break;
        }
        if (tok.endsWith(".app")) {
          app = tok;
          break;
        }
      }
      if (app !== null) {
        findings.push({
          rule: "open",
          app,
          argv: toks.join(" "),
          // `open -a Safari` is not a media claim; it is a GUI app on the host
          // and is RECORDED, never blocked. Blocking it would refuse correct
          // work (a lane legitimately opening a doc/browser is not this bug).
          media: false,
          faked,
        });
      }
      continue;
    }

    // R-playwright: a HEADED run can present a real device picker. Headless is
    // recorded by neither rule — see the header's friction note.
    const isPlaywright = head === "playwright" || head === "puppeteer" || head === "playwright-core";
    if (isPlaywright) {
      const rest = toks.slice(Math.max(index, cwi) + 1);
      const headed = rest.some((t) => HEADED_FLAGS.has(t)) ||
        toks.some((t) => /^PWDEBUG=(?!0$|false$)/.test(t));
      if (headed) {
        findings.push({
          rule: "playwright",
          app: head,
          argv: toks.join(" "),
          media: true,
          faked,
        });
      }
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

/** The block's reason — names the incident, the flags, and the hatch. */
export function blockReason(finding: LaunchFinding, recordPath: string): string {
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
