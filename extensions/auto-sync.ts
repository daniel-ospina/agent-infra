// auto-sync.ts — Level-1 machine sync for agent-infra (session_start)
//
// On session start, if AGENT_INFRA_PATH is set:
//   - fetch origin and compare HEAD vs origin/main
//   - behind → AGENT_SYNC_MODE=auto  : run sync.sh (pull --ff-only + refresh config)
//   - behind → AGENT_SYNC_MODE=warn  : print a hint to run `cd "$AGENT_INFRA_PATH" && ./sync.sh`
//   - ahead  → report unpushed commits + push hint (informational; never pushes)
//   - diverged → surface git status/log guidance + next step (ff blocked)
//   - current → silent
//
// Safety: only ever pulls (never pushes). sync.sh fails loudly on divergence.
// Secrets never sync: auth.json and env vars stay machine-local by design.

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { existsSync, readFileSync, rmSync } from "node:fs";
import { join } from "node:path";
import { execSync } from "node:child_process";
import { isPrintMode } from "./shared/print-mode.js";
import { repoKey, acquireRepoLock, releaseRepoLock } from "./shared/branch-ownership.mjs";

export function shortHead(repo: string, ref = "HEAD"): string {
  try {
    return execSync(`git -C "${repo}" rev-parse --short ${ref}`, { encoding: "utf-8" }).trim();
  } catch {
    return "?";
  }
}

/** Commits HEAD is ahead of origin/main (0 when undetermined). */
export function aheadCount(repo: string): number {
  try {
    const out = execSync(`git -C "${repo}" rev-list --count origin/main..HEAD`, { encoding: "utf-8" }).trim();
    const n = Number(out);
    return Number.isInteger(n) ? n : 0;
  } catch {
    return 0;
  }
}

/**
 * Sync state of the repo vs origin/main (call after `git fetch`):
 *   "current"   HEAD === origin/main
 *   "behind"    origin/main has commits HEAD lacks (ff pull possible)
 *   "ahead"     HEAD has unpushed commits origin/main lacks (ff pull is a no-op)
 *   "diverged"  neither side is an ancestor of the other (ff pull blocked)
 */
export function syncState(repo: string): "current" | "behind" | "ahead" | "diverged" {
  let head: string, remote: string;
  try {
    head = execSync(`git -C "${repo}" rev-parse HEAD`, { encoding: "utf-8" }).trim();
    remote = execSync(`git -C "${repo}" rev-parse origin/main`, { encoding: "utf-8" }).trim();
  } catch {
    return "current"; // can't determine — don't act
  }
  if (head === remote) return "current";
  // HEAD is an ancestor of origin/main → local is behind (equality excluded above).
  try {
    execSync(`git -C "${repo}" merge-base --is-ancestor HEAD origin/main`, { stdio: "ignore" });
    return "behind";
  } catch {
    /* not behind */
  }
  // origin/main is an ancestor of HEAD → local has unpushed commits.
  try {
    execSync(`git -C "${repo}" merge-base --is-ancestor origin/main HEAD`, { stdio: "ignore" });
    return "ahead";
  } catch {
    /* neither is an ancestor → true divergence */
  }
  return "diverged";
}

/**
 * #203: lossless recovery for a checkout stranded on a non-main branch.
 * Squash-merged PR work leaves a feature branch with commits that never land
 * on main (its tree is often byte-identical to origin/main) — the checkout
 * then reports "diverged" forever: ff-pull can't help, the main-worktree-guard
 * blocks agent-side resets, and auto-sync warns every session while main
 * drifts further ahead. Recovery is ONLY attempted when provably lossless:
 *   - the tracked working tree is byte-identical to origin/main
 *     (`git diff origin/main --quiet` exits 0), AND
 *   - every untracked file is absent from origin/main (→ abort: new work) or
 *     byte-identical to it (→ safe to remove; the branch switch restores it).
 * On success the checkout ends on `main` at origin/main (0 divergence) — the
 * stranded branch itself is left untouched (refs preserved). Never runs in
 * "ahead" state (unpushed commits are real work) and never when the tree
 * holds genuine uncommitted changes.
 *
 * #265: the repo lock serializes recovery-vs-recovery across concurrent pi
 * processes. When called from session_start the lock is ALREADY held (passed
 * via opts.lockHeld) — same-pid re-acquire is re-entrant so recovery never
 * self-skips; direct calls (tests) acquire internally. All lossless checks are
 * RE-VERIFIED under the lock immediately before any mutation (rmSync/checkout)
 * — no rmSync is ever based on pre-lock state.
 */
export function tryLosslessRecover(repo: string, opts: { lockHeld?: boolean } = {}): { recovered: boolean; reason?: string } {
  const key = repoKey(repo);
  let lock: { held: boolean } | null = null;
  if (!opts.lockHeld) {
    lock = key ? acquireRepoLock(key, process.pid, { timeoutMs: 3000 }) : { held: false };
    if (!lock.held) {
      return { recovered: false, reason: "repo lock busy — recovery skipped" };
    }
  }
  try {
    return tryLosslessRecoverUnderLock(repo);
  } finally {
    if (lock && key) releaseRepoLock(key, process.pid);
  }
}

function tryLosslessRecoverUnderLock(repo: string): { recovered: boolean; reason?: string } {
  if (syncState(repo) !== "diverged") {
    return { recovered: false, reason: "not diverged — recovery not applicable" };
  }
  // 1. untracked files first — the tracked-diff below must exclude them (a
  //    file present in origin/main but untracked in the working tree reads as
  //    "deleted" in `git diff <commit>`, which would false-positive).
  let untracked: string[];
  try {
    untracked = execSync(`git -C "${repo}" ls-files --others --exclude-standard`, { encoding: "utf-8" })
      .split("\n").map(s => s.trim()).filter(Boolean);
  } catch {
    return { recovered: false, reason: "could not list untracked files" };
  }
  // 2. tracked working tree must match origin/main exactly (lossless).
  const excludeArgs = untracked.map(f => `':(exclude)${f}'`).join(" ");
  try {
    execSync(`git -C "${repo}" diff origin/main --quiet -- . ${excludeArgs}`, { stdio: "ignore", timeout: 30_000 });
  } catch {
    return { recovered: false, reason: "tracked tree differs from origin/main (real uncommitted work — keep)" };
  }
  // 3. untracked files must not collide with origin/main content — EACH file
  //    re-checked immediately before removal (never based on pre-lock state).
  for (const f of untracked) {
    let onMain = false;
    try { execSync(`git -C "${repo}" cat-file -e origin/main:${f}`, { stdio: "ignore" }); onMain = true; } catch { onMain = false; }
    if (!onMain) {
      return { recovered: false, reason: `untracked file "${f}" is not on origin/main (new work — keep)` };
    }
    try {
      const onMainContent = execSync(`git -C "${repo}" show origin/main:${f}`, { encoding: "utf-8" });
      if (onMainContent !== readFileSync(join(repo, f), "utf-8")) {
        return { recovered: false, reason: `untracked file "${f}" differs from origin/main — keep` };
      }
    } catch {
      return { recovered: false, reason: `could not compare untracked file "${f}"` };
    }
  }
  // 4. lossless — drop residue, switch to main, fast-forward to origin/main.
  try {
    for (const f of untracked) rmSync(join(repo, f), { force: true });
    execSync(`git -C "${repo}" checkout -f main`, { stdio: "ignore", timeout: 30_000 });
    execSync(`git -C "${repo}" merge --ff-only origin/main`, { stdio: "ignore", timeout: 30_000 });
    return { recovered: true };
  } catch (e: any) {
    return { recovered: false, reason: `switch failed: ${e?.message ?? e}` };
  }
}

export default function (pi: ExtensionAPI) {
  pi.on("session_start", async () => {
    const infraPath = process.env.AGENT_INFRA_PATH;
    if (!infraPath) return;          // not configured — silent
    if (!existsSync(infraPath)) return;
    if (isPrintMode()) return; // sub-agents: no pulls, no noise

    try {
      execSync(`git -C "${infraPath}" fetch origin --quiet`, { timeout: 30_000, stdio: "ignore" });
    } catch {
      return; // offline — silent
    }

    // #195 L3: warn-only orphan sweep — aborted dispatches leave worktrees/
    // branches recorded in the teardown manifest; surface them within a day
    // without ever auto-deleting (scan-orphans.sh --apply is the manual gate).
    try {
      const out = execSync(`bash "${infraPath}/scripts/scan-orphans.sh" --repo "${infraPath}" 2>&1`, {
        timeout: 30_000,
        encoding: "utf-8",
      });
      const lines = out.trim().split("\n").filter((l) => l.includes("⚠️") || l.includes("👻") || l.includes("🧹"));
      if (lines.length > 0) {
        console.log(`[auto-sync] 🧹 ${lines.length} orphaned worktree/branch record(s) — inspect:`);
        console.log(lines.slice(0, 5).map((l) => `    ${l.trim()}`).join("\n"));
        console.log(`    Cleanup: bash "${infraPath}/scripts/scan-orphans.sh" --apply`);
      }
    } catch {
      // scanner missing/offline — silent (warn-only by design)
    }

    const state = syncState(infraPath);
    const syncHint = `cd "${infraPath}" && ./sync.sh`;

    // ahead → nothing to fetch; report unpushed commits so they're not silently skipped.
    if (state === "ahead") {
      const n = aheadCount(infraPath);
      console.log(
        `[auto-sync] ℹ️  agent-infra is ahead of origin/main (local ${shortHead(infraPath)}) — ` +
        (n > 0 ? `${n} unpushed commit(s) on main` : "unpushed local commit(s)")
      );
      console.log(`    Push when ready: git -C "${infraPath}" push origin main`);
      return;
    }

    // #265: every MUTATION (lossless recovery, sync.sh run) is serialized by the
    // repo lock — concurrent pi processes never interleave force-switches or
    // ff-pulls. Clean acquire/release logs NOTHING (tests assert zero output on
    // the "current → silent" path); only foreign contention warns (skip —
    // recovery is convenience, never correctness-critical).
    const mutates = state === "diverged" ||
      (state === "behind" && (process.env.AGENT_SYNC_MODE || "warn") === "auto");
    if (mutates) {
      const key = repoKey(infraPath);
      const lock = key
        ? acquireRepoLock(key, process.pid, { timeoutMs: 3000, retryMs: 200 })
        : { held: false };
      if (!lock.held) {
        console.log(`[auto-sync] ⏭️ repo lock busy — another session is syncing; skipping this start`);
        return;
      }
      try {
        if (state === "diverged") {
          const rec = tryLosslessRecover(infraPath, { lockHeld: true });
          if (rec.recovered) {
            console.log(`[auto-sync] 🔁 stranded checkout recovered — now on main at ${shortHead(infraPath)} (tree matched origin/main losslessly)`);
            return;
          }
          console.log(`[auto-sync] ⚠️  agent-infra has diverged from origin/main — fast-forward sync blocked:`);
          console.log(`    Local : ${shortHead(infraPath)}`);
          console.log(`    Remote: ${shortHead(infraPath, "origin/main")}`);
          console.log(`    Inspect: git -C "${infraPath}" status`);
          console.log(`    History: git -C "${infraPath}" log --oneline --left-right HEAD...origin/main`);
          console.log(`    Next: stash or commit local work, then re-run sync:`);
          console.log(`        ${syncHint}`);
          if (rec.reason) console.log(`    (auto-recovery skipped: ${rec.reason})`);
          return;
        }
        // behind + AGENT_SYNC_MODE=auto → sync.sh under the lock
        try {
          const out = execSync(`bash "${infraPath}/sync.sh" 2>&1`, { timeout: 180_000, encoding: "utf-8" });
          console.log(`[auto-sync] ✅ agent-infra updated to ${shortHead(infraPath)} — config refreshed`);
          const lines = out.trim().split("\n").filter(l => l.includes("warning") || l.includes("⚠"));
          if (lines.length) console.log(lines.slice(0, 3).map(l => `    ${l}`).join("\n"));
        } catch (e: any) {
          const err = e as { stdout?: Buffer | string; message?: string };
          const detail = (err.stdout ? err.stdout.toString() : err.message || "unknown error")
            .split("\n").filter(Boolean).slice(0, 4).join("\n    ");
          console.log(`[auto-sync] ⚠️  update available but auto-sync failed:`);
          console.log(`    ${detail}`);
          console.log(`[auto-sync]    Run manually: ${syncHint}`);
        }
        return;
      } finally {
        releaseRepoLock(key, process.pid);
      }
    }

    if (state !== "behind") return; // current — silent

    console.log(`[auto-sync] ⚠️  agent-infra update available — run: ${syncHint}`);
  });
}
