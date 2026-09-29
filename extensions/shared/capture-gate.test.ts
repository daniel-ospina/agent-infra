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
import { mkdtempSync, mkdirSync, writeFileSync, rmSync, realpathSync, chmodSync } from "node:fs";
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
  resolveProjectCaptureScope,
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

  // Review cycle 1 P1: the repo file must accept the SAME deny vocabulary as the
  // env flag (a repo author mirroring TORTOISE_CAPTURE_CLOUD=off used to be
  // silently ignored), and an unrecognised value must fail closed.
  for (const value of ["false", "off", "no", "n", "disable", "disabled", "never", "0", ""]) {
    const dir = tmpProject("gate-vocab", { cloud: value });
    equal(
      projectCaptureOptOut(dir),
      true,
      `repo file {cloud: ${JSON.stringify(value)}} is a deny`,
    );
  }
  const unrecognised = tmpProject("gate-unrecognised", { cloud: "banana" });
  equal(
    projectCaptureOptOut(unrecognised),
    true,
    "unrecognised repo cloud value fails closed",
  );
  equal(
    resolveCaptureGate({ cloud: true, apiKey: "tt_x", projectDir: unrecognised, env: {} }).reason,
    "repo-opt-out",
    "unrecognised repo cloud value yields repo-opt-out",
  );

  // Review cycle 1 P1: a file that EXISTS but cannot be read must deny, not
  // silently skip (ENOENT is the ONLY "absent"). `.pi` as a FILE forces ENOTDIR.
  const unreadable = tmpProject("gate-unreadable");
  writeFileSync(join(unreadable, ".pi"), "not a directory", "utf-8");
  equal(
    projectCaptureOptOut(unreadable),
    true,
    "opt-out path that cannot be read (ENOTDIR) denies (fail closed)",
  );

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

  // ── Review cycle 1 P0: a git FAILURE must (a) fail closed and (b) never be
  // memoized — one transient error may not disable the repo opt-out until the
  // process restarts.
  {
    const main2 = tmpProject("gate-fail-main", { cloud: false });
    execSync("git init -q .", { cwd: main2 });
    execSync("git -c user.email=t@t -c user.name=t commit --allow-empty -qm init", { cwd: main2 });
    const wt2 = join(main2, ".worktrees", "branch");
    execSync(`git worktree add --detach -q ${JSON.stringify(wt2)}`, { cwd: main2 });

    const shimDir = mkdtempSync(join(tmpdir(), "gate-git-shim-"));
    dirs.push(shimDir);
    writeFileSync(join(shimDir, "git"), "#!/bin/sh\nexit 1\n", "utf-8");
    chmodSync(join(shimDir, "git"), 0o755);

    const realPath = process.env.PATH;
    process.env.PATH = `${shimDir}:${realPath}`;
    let brokenResolved = true;
    let brokenReason = "enabled";
    try {
      brokenResolved = resolveProjectCaptureScope(resolveProjectRoot(wt2)).resolved;
      brokenReason = resolveCaptureGate({
        cloud: true,
        apiKey: "tt_x",
        projectDir: resolveProjectRoot(wt2),
        env: {},
      }).reason;
    } finally {
      process.env.PATH = realPath;
    }
    equal(brokenResolved, false, "git failure → the repo scope is not trustworthy");
    equal(
      brokenReason,
      "repo-root-unresolved",
      "git failure → the gate fails closed instead of silently enabling",
    );

    // The failure must NOT be memoized: once git recovers, the main-root deny applies.
    const recoveredRoot = resolveProjectRoot(wt2);
    equal(realpathSync(recoveredRoot), realpathSync(wt2), "worktree toplevel resolves after recovery");
    equal(
      resolveCaptureGate({ cloud: true, apiKey: "tt_x", projectDir: recoveredRoot, env: {} }).reason,
      "repo-opt-out",
      "after git recovers the main-root deny is honoured (failure was not memoized)",
    );
  }

  // ── Review cycle 1 P2: non-standard git layouts must resolve the CHECKOUT
  // root. `dirname(--git-common-dir)` alone is the PARENT of a
  // --separate-git-dir worktree, and `.git/modules` for a submodule.
  {
    const base = mkdtempSync(join(tmpdir(), "gate-layouts-"));
    dirs.push(base);

    // --separate-git-dir: worktree at <base>/ws, git dir at <base>/gitdir
    const ws = join(base, "ws");
    mkdirSync(join(ws, ".pi"), { recursive: true });
    writeFileSync(join(ws, ".pi", "tortoise-capture.json"), JSON.stringify({ cloud: false }), "utf-8");
    const pkg = join(ws, "pkg");
    mkdirSync(pkg, { recursive: true });
    execSync(`git init -q --separate-git-dir=${JSON.stringify(join(base, "gitdir"))} .`, { cwd: ws });
    equal(
      resolveMainRepoRoot(pkg),
      realpathSync(ws),
      "--separate-git-dir: main root is the checkout, not the git-dir parent",
    );
    equal(
      resolveCaptureGate({ cloud: true, apiKey: "tt_x", projectDir: resolveProjectRoot(pkg), env: {} }).reason,
      "repo-opt-out",
      "--separate-git-dir: the checkout's opt-out still applies from a subdir",
    );

    // submodule-shaped: worktree at <base>/super/sub, git dir at
    // <base>/super/.git/modules/sub (exactly what `git submodule add` creates).
    const superDir = join(base, "super");
    mkdirSync(join(superDir, ".git", "modules"), { recursive: true });
    execSync("git init -q .", { cwd: superDir });
    const sub = join(superDir, "sub");
    mkdirSync(join(sub, ".pi"), { recursive: true });
    writeFileSync(join(sub, ".pi", "tortoise-capture.json"), JSON.stringify({ cloud: false }), "utf-8");
    const subPkg = join(sub, "pkg");
    mkdirSync(subPkg, { recursive: true });
    execSync(
      `git init -q --separate-git-dir=${JSON.stringify(join(superDir, ".git", "modules", "sub"))} .`,
      { cwd: sub },
    );
    equal(
      resolveMainRepoRoot(subPkg),
      realpathSync(sub),
      "submodule layout: main root is the submodule checkout, not .git/modules",
    );
    equal(
      resolveCaptureGate({ cloud: true, apiKey: "tt_x", projectDir: resolveProjectRoot(subPkg), env: {} }).reason,
      "repo-opt-out",
      "submodule layout: the submodule's opt-out still applies from a subdir",
    );
  }

  // ── Env flag: may tighten, never loosen ──────────────────────────────────
  for (const value of ["0", "false", "off", "no", "n", "disable", "disabled", "never", "FALSE", ""]) {
    equal(envCaptureDisabled({ [CLOUD_ENV_FLAG]: value }), true, `${CLOUD_ENV_FLAG}=${JSON.stringify(value)} disables`);
  }
  equal(envCaptureDisabled({}), false, "unset env flag does not disable");
  equal(envCaptureDisabled({ [CLOUD_ENV_FLAG]: "1" }), false, `=1 is an enable ATTEMPT, ignored`);
  equal(envCaptureDisabled({ [CLOUD_ENV_FLAG]: "yes" }), false, `=yes is an enable ATTEMPT, ignored`);
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
    ["repo-root-unresolved", "could not resolve"],
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
