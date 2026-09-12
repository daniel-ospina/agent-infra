/**
 * capture-gate.test.ts — unit tests for shared/capture-gate.ts (#803)
 *
 * Pins the hosted-capture EGRESS policy that fixes #803: the Tortoise API key is
 * a graph-connection credential (it is also the MCP Bearer header) and must NOT
 * enable full-transcript uploads on its own. `cloud: true` in the operator config
 * is the only enable; the repo file and the env flag may only DENY.
 *
 * Run: npx tsx extensions/shared/capture-gate.test.ts
 */

import { ok, equal } from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync, realpathSync } from "node:fs";
import { execSync } from "node:child_process";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  CLOUD_ENV_FLAG,
  captureStatusLine,
  envCaptureDisabled,
  projectCaptureOptOut,
  resolveCaptureGate,
  resolveMainRepoRoot,
  resolveProjectRoot,
} from "./capture-gate.js";

const dirs: string[] = [];
function tmpProject(label: string, config?: Record<string, unknown>): string {
  const dir = mkdtempSync(join(tmpdir(), `${label}-`));
  dirs.push(dir);
  if (config) {
    mkdirSync(join(dir, ".pi"), { recursive: true });
    writeFileSync(join(dir, ".pi", "tortoise-capture.json"), JSON.stringify(config), "utf-8");
  }
  return dir;
}

try {
  // ── The #803 regression: a key alone is NOT consent ──────────────────────
  equal(
    resolveCaptureGate({ cloud: undefined, apiKey: "tt_graph_key", env: {} }).enabled,
    false,
    "key alone must not enable capture",
  );
  equal(
    resolveCaptureGate({ cloud: false, apiKey: "tt_graph_key", env: {} }).reason,
    "cloud-not-enabled",
    "key alone → cloud-not-enabled",
  );
  equal(
    resolveCaptureGate({ cloud: true, apiKey: "tt_x", env: {} }).enabled,
    true,
    "cloud:true + key → enabled",
  );
  equal(
    resolveCaptureGate({ cloud: true, apiKey: "  tt_x  ", env: {} }).enabled,
    true,
    "key is trimmed before the emptiness check",
  );
  equal(
    resolveCaptureGate({ cloud: true, apiKey: "", env: {} }).reason,
    "no-api-key",
    "cloud:true without a key → no-api-key",
  );
  equal(
    resolveCaptureGate({ cloud: "yes", apiKey: "tt_x", env: {} }).enabled,
    false,
    "only the literal boolean true opts in",
  );

  // ── Repo-scoped opt-out: deny-only, cannot grant itself egress ───────────
  const optedOut = tmpProject("gate-optout", { cloud: false });
  equal(projectCaptureOptOut(optedOut), true, "{cloud:false} project file is an opt-out");
  equal(
    resolveCaptureGate({ cloud: true, apiKey: "tt_x", projectDir: optedOut, env: {} }).reason,
    "repo-opt-out",
    "repo opt-out beats cloud:true + key",
  );
  equal(
    resolveCaptureGate({ cloud: true, apiKey: "tt_x", projectDir: optedOut, env: {} }).enabled,
    false,
    "repo opt-out disables capture",
  );
  const repoWantsIn = tmpProject("gate-repo-enable", { cloud: true });
  equal(projectCaptureOptOut(repoWantsIn), false, "{cloud:true} in a project file is not a deny");
  equal(
    resolveCaptureGate({ cloud: false, apiKey: "tt_x", projectDir: repoWantsIn, env: {} }).enabled,
    false,
    "a repo file must never ENABLE egress",
  );
  const noFile = tmpProject("gate-no-file");
  equal(projectCaptureOptOut(noFile), false, "missing project file is not a deny");
  equal(projectCaptureOptOut(undefined), false, "no projectDir is not a deny");
  const malformed = tmpProject("gate-malformed");
  mkdirSync(join(malformed, ".pi"), { recursive: true });
  writeFileSync(join(malformed, ".pi", "tortoise-capture.json"), "{not json", "utf-8");
  equal(projectCaptureOptOut(malformed), false, "malformed project file is not a deny (fail-open on deny)");

  // ── Linked worktrees: a deny at the MAIN root still applies ──────────────
  // Regression (review cycle 2 P1): --show-toplevel returns the worktree path,
  // so a main-root deny was bypassed whenever pi ran from `.worktrees/<branch>`.
  const main = tmpProject("gate-worktree", { cloud: false });
  const git = (cmd: string, cwd: string) =>
    execSync(cmd, { cwd, stdio: ["ignore", "pipe", "ignore"] });
  git("git init -q", main);
  git("git -c user.email=t@t -c user.name=t commit --allow-empty -qm init", main);
  const wt = join(main, ".worktrees", "branch");
  git(`git worktree add --detach -q ${JSON.stringify(wt)}`, main);
  const wtRoot = resolveProjectRoot(wt);
  equal(wtRoot, realpathSync(wt), "worktree toplevel is the worktree path, not the main root");
  equal(resolveMainRepoRoot(wtRoot), realpathSync(main), "main repo root resolves from the linked worktree");
  equal(projectCaptureOptOut(wtRoot), true, "main-root deny applies inside a linked worktree");
  equal(
    resolveCaptureGate({ cloud: true, apiKey: "tt_x", projectDir: wtRoot, env: {} }).reason,
    "repo-opt-out",
    "worktree gate honors the main-root deny",
  );

  // ── Env flag: may tighten, never loosen ──────────────────────────────────
  for (const value of ["0", "false", "off", "no", "FALSE", ""]) {
    equal(envCaptureDisabled({ [CLOUD_ENV_FLAG]: value }), true, `${CLOUD_ENV_FLAG}=${JSON.stringify(value)} disables`);
  }
  equal(envCaptureDisabled({}), false, "unset env flag does not disable");
  equal(envCaptureDisabled({ [CLOUD_ENV_FLAG]: "1" }), false, `=1 is an enable ATTEMPT, ignored`);
  equal(
    resolveCaptureGate({ cloud: true, apiKey: "tt_x", env: { [CLOUD_ENV_FLAG]: "0" } }).reason,
    "env-disabled",
    "env deny beats cloud:true + key",
  );
  equal(
    resolveCaptureGate({ cloud: false, apiKey: "tt_x", env: { [CLOUD_ENV_FLAG]: "1" } }).enabled,
    false,
    "env=1 cannot enable capture without the file opt-in",
  );

  // ── Startup disclosure: ON/OFF + destination ─────────────────────────────
  const on = captureStatusLine({
    gate: { enabled: true, reason: "enabled" },
    apiUrl: "https://api.premiselabs.co",
    fallbackDir: "/tmp/fallback",
    configPath: "/tmp/tortoise-config.json",
  });
  ok(on.includes("[reflect-hook] capture ON"), `ON line: ${on}`);
  ok(on.includes("https://api.premiselabs.co/v1/sessions"), `destination in ON line: ${on}`);

  for (const [reason, needle] of [
    ["cloud-not-enabled", "explicit opt-in"],
    ["no-api-key", "no TORTOISE_API_KEY"],
    ["repo-opt-out", "tortoise-capture.json"],
    ["env-disabled", CLOUD_ENV_FLAG],
  ] as const) {
    const line = captureStatusLine({
      gate: { enabled: false, reason },
      apiUrl: "https://api.premiselabs.co",
      fallbackDir: "/tmp/fallback",
      configPath: "/tmp/tortoise-config.json",
      projectDir: "/repo",
    });
    ok(line.includes("[reflect-hook] capture OFF"), `${reason} line says OFF: ${line}`);
    ok(line.includes(needle), `${reason} line names the cause (${needle}): ${line}`);
    ok(line.includes("/tmp/fallback"), `${reason} line names the local destination: ${line}`);
  }
  console.log("✅ capture-gate.test.ts — all #803 gate assertions passed");
} finally {
  for (const dir of dirs) rmSync(dir, { recursive: true, force: true });
}
