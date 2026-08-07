/**
 * session-affinity.test.ts — unit tests for loop-enforcer session routing functions.
 * Run: npx tsx extensions/loop-enforcer/session-affinity.test.ts
 */

import { shouldResumeLoop, readSessionContext } from "./index.js";
import { writeFileSync, mkdirSync, rmSync, existsSync, readFileSync, copyFileSync, unlinkSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";
import { randomUUID } from "node:crypto";

const SESSION_FILE = join(homedir(), ".pi", "agent", "slack-session.json");
const BACKUP_FILE = join(homedir(), ".pi", "agent", "slack-session.json.test-backup");

let passed = 0;
let failed = 0;

function assert(condition: boolean, msg: string): void {
  if (condition) {
    passed++;
  } else {
    failed++;
    console.error(`  ❌ FAIL: ${msg}`);
  }
}

function done(): void {
  console.log(`\n${passed} passed, ${failed} failed`);
  if (failed > 0) process.exit(1);
}

// ── save/restore real slack-session.json ────────────────────────
function saveSessionFile(): void {
  if (existsSync(SESSION_FILE)) {
    copyFileSync(SESSION_FILE, BACKUP_FILE);
  }
}
function restoreSessionFile(): void {
  if (existsSync(BACKUP_FILE)) {
    copyFileSync(BACKUP_FILE, SESSION_FILE);
    unlinkSync(BACKUP_FILE);
  } else {
    try { unlinkSync(SESSION_FILE); } catch { /* ok */ }
  }
}

// ─────────────────────────────────────────────────────────────────
// shouldResumeLoop tests
// ─────────────────────────────────────────────────────────────────

console.log("shouldResumeLoop:");

// Case 1: session affinity — same session_id
assert(
  shouldResumeLoop(
    { session_id: "abc" },
    { team: "eldato-app", role: "dev", sessionId: "abc" }
  ) === true,
  "Case 1: same session_id → true (session affinity)"
);

// Case 2: different session_id blocks
assert(
  shouldResumeLoop(
    { session_id: "abc", subject: { team: "eldato-app", role: "dev" } },
    { team: "eldato-app", role: "dev", sessionId: "xyz" }
  ) === false,
  "Case 2: different session_id → false (blocked by another active session)"
);

// Case 3: role fallback (no session_id, role matches)
assert(
  shouldResumeLoop(
    { subject: { team: "eldato-app", role: "dev" } },
    { team: "eldato-app", role: "dev", sessionId: "xyz" }
  ) === true,
  "Case 3: no session_id, role match → true (role fallback)"
);

// Case 4: team escalation (no session_id, no role match, team matches)
assert(
  shouldResumeLoop(
    { subject: { team: "eldato-app" } },
    { team: "eldato-app", role: "dev", sessionId: "xyz" }
  ) === true,
  "Case 4: no session_id, team match → true (team escalation)"
);

// Case 5: role mismatch, team match → falls to team step
assert(
  shouldResumeLoop(
    { subject: { team: "eldato-app", role: "designer" } },
    { team: "eldato-app", role: "dev", sessionId: "xyz" }
  ) === true,
  "Case 5: role mismatch but team match → true (team escalation after role skip)"
);

// Case 6: backward compat — both untagged
assert(
  shouldResumeLoop(
    {},
    { team: null, role: null, sessionId: null }
  ) === true,
  "Case 6: both untagged → true (backward compat)"
);

// Case 7: tagged session skips untagged manifest (#5817 guard)
assert(
  shouldResumeLoop(
    {},
    { team: "eldato-app", role: "dev", sessionId: "xyz" }
  ) === false,
  "Case 7: tagged session, untagged manifest → false (#5817 guard)"
);

// Case 8: null session_id treated same as undefined
assert(
  shouldResumeLoop(
    { session_id: null, subject: { role: "dev" } },
    { team: "eldato-app", role: "dev", sessionId: "xyz" }
  ) === true,
  "Case 8: null session_id → falls through to role match (same as undefined)"
);

// Case 9: session_id set but sessionCtx.sessionId is null → skip session check
assert(
  shouldResumeLoop(
    { session_id: "abc", subject: { role: "dev" } },
    { team: "eldato-app", role: "dev", sessionId: null }
  ) === false,
  "Case 9: session_id set but ctx.sessionId is null → blocked (step 2 catches it)"
);

// Case 10: untagged session, tagged manifest → should not leak
assert(
  shouldResumeLoop(
    { subject: { team: "eldato-app" } },
    { team: null, role: null, sessionId: null }
  ) === false,
  "Case 10: untagged session, tagged manifest → false (no match on step 5)"
);

// Case 11: completely mismatched team → false
assert(
  shouldResumeLoop(
    { subject: { team: "growth-team" } },
    { team: "eldato-app", role: "dev", sessionId: null }
  ) === false,
  "Case 11: mismatched team → false"
);

// ─────────────────────────────────────────────────────────────────
// readSessionContext tests
// ─────────────────────────────────────────────────────────────────

console.log("\nreadSessionContext:");

saveSessionFile();

// Case: valid session file
const testDir = join("/tmp", `loop-session-test-${randomUUID()}`);
mkdirSync(testDir, { recursive: true });

// Override SESSION_FILE for testing — we can't because it's const,
// but we can test by writing a real file temporarily.
const testSession = {
  active_session: {
    session_id: "test-123",
    thread_ts: "123.456",
    bridge_url: "http://localhost:4200",
    team: "organisation-design-team",
    role: "platform-architect",
  },
};
writeFileSync(SESSION_FILE, JSON.stringify(testSession, null, 2), "utf-8");

const ctx = readSessionContext();
assert(ctx.team === "organisation-design-team", "readSessionContext: team matches");
assert(ctx.role === "platform-architect", "readSessionContext: role matches");

// Case: missing session file
try { unlinkSync(SESSION_FILE); } catch { /* ok */ }
const ctx2 = readSessionContext();
assert(ctx2.team === null, "readSessionContext: missing file → team null");
assert(ctx2.role === null, "readSessionContext: missing file → role null");

// Case: empty file
writeFileSync(SESSION_FILE, "", "utf-8");
const ctx3 = readSessionContext();
assert(ctx3.team === null, "readSessionContext: empty file → team null");
assert(ctx3.role === null, "readSessionContext: empty file → role null");

// Case: session without role
const noRole = { active_session: { session_id: "x", thread_ts: "1", team: "eldato-app" } };
writeFileSync(SESSION_FILE, JSON.stringify(noRole, null, 2), "utf-8");
const ctx4 = readSessionContext();
assert(ctx4.team === "eldato-app", "readSessionContext: team-only session");
assert(ctx4.role === null, "readSessionContext: no role → null");

restoreSessionFile();

// ─────────────────────────────────────────────────────────────────
done();
