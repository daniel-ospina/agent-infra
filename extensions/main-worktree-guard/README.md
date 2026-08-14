# main-worktree-guard — Pi extension

Guards the **SHARED main checkout** of a project against two classes of
collision between parallel agents:

1. **write/edit tool calls** targeting the main checkout (parallel agents
   editing main could silently overwrite each other's uncommitted changes),
   and
2. **destructive/state-changing git commands** via the bash tool — `git reset
   --hard`, branch checkout/switch, pull/merge/rebase, clean, force-push,
   `branch -D`, restore, stash pop (incident 2026-08-06: a `git reset --hard
   origin/main` mid-PR yanked the working tree out from under another agent).

**Worktrees are ISOLATED** — none of this applies inside a linked worktree.
The guard blocks only in the shared main checkout, where branch-state changes
and hard resets silently destroy other agents' work.

There is **NO auto-bypass**: the guard blocks every time, so a rogue or
parallel agent cannot retry its way past it. Escapes are deliberate and
documented (env hatch below, escape marker below).

**Degradation (fail-safe):** if `classify-git.mjs` fails to load (jiti edge
case), the bash guard degrades to warn-only while the write/edit guard stays
fully enforced. The escape-marker check degrades to **inactive** (block) on
any failure — a failed import or stamp never silently allows.

## Environment variables

| Variable | Purpose | Required for |
|---|---|---|
| `AGENT_ALLOW_MAIN_EDITS=1` | Deliberate solo-session bypass — disables the guard for the whole session. Must be set before the session starts; cannot be set on a running process. | — |
| `ELDATO_ALLOW_MAIN_EDITS=1` | Legacy alias of the above (checked second). | — |

The env hatch is fixed at session start. For a **mid-session** escalation on a
running, guard-blocked session, use the escape marker below.

## Escape marker — deliberate mid-session escalation (#207)

A guard-blocked-but-functional session (alive, issuing tool calls, stranded in
the shared main checkout) opens a **sanctioned, bounded, audited,
session-scoped** window by touching a marker file. This upgrades the only
mid-session escape that existed before — an undocumented script-execution
backdoor (see below) — into a bounded hatch.

### The one-touch command

Run this as **its own bash tool call** inside a guard-loaded session:

```bash
touch ~/.pi/agent/.allow-main-edits  # recovery: <reason>
```

- The trailing `# recovery: <reason>` comment is optional but recommended —
  it is extracted into the marker content and the audit record.
- **The touch must be its own command.** A combined
  `touch ... && git checkout main` in ONE bash call does NOT work: the guard
  classifies the whole command before any stamping happens, so the git part
  is blocked and the touch never runs. Put the recovery git op in the
  **FOLLOW-UP** call:

```bash
# call 1 (allowed — opens the window)
touch ~/.pi/agent/.allow-main-edits  # recovery: stranded main
# call 2 (now allowed — the recovery op)
git checkout main && git pull --ff-only
```

### 15-minute expiry

The window is **mtime-based**: a marker is active only while its mtime is
younger than 15 minutes (`ALLOW_MAIN_EDITS_MARKER_TTL_MS` — a fixed constant,
deliberately NOT env-overridable). The guard re-reads the marker **on every
tool call** — it is never cached. Re-running the same `touch` refreshes the
window (mtime update; the guard re-stamps the content). A marker exactly
15 minutes old is expired — the same recovery op is blocked again until you
re-touch.

### Session scoping + stamping contract

The marker is **per-process-session-scoped**, not machine-wide:

- Only the guard's tool_call handler writes the stamp
  `{"session_id", "reason", "ts"}` — it stamps when it observes an allowed
  `touch` of the marker path, BEFORE allowing the command. `touch` then
  refreshes mtime and preserves the content (no ordering race).
- The window is active ⟺ mtime fresh AND content parses AND
  `session_id` matches the current session's id (`PI_SESSION_ID`, with the
  extension-context session manager as fallback).
- **A human terminal `touch` produces an unscoped empty file → inert →
  blocked.** The touch must be a bash tool call inside a guard-loaded session
  for the guard to stamp it.
- **Headless / print-mode sessions with a null session id cannot escalate**
  (fail-safe block).

### Delegation caveat

The marker is per-process-session-scoped — a subagent does **NOT** inherit the
parent's `PI_SESSION_ID` (pi only writes it into bash-tool child envs; the
extension-host env of a subagent carries the subagent's OWN id). **Recovery
must run in the session that created the marker; delegating the touch to a
subagent re-scopes the marker to the subagent's id or fails-closed** (the
parent's read-side match fails → the parent stays blocked). A subagent
re-touching an active marker RE-SCOPES it to the subagent's id, revoking the
parent's window.

### One window, all repos

The marker is repo-agnostic: one active window covers every repo the session
touches (the hub and any worktrees). Accepted and documented — no per-repo
scoping.

### Audit location

Every stamp writes one JSONL line to `~/.pi/agent/audit/gate-events.jsonl`
via the shared audit facility:

```json
{"ts":"…","event":"gate_bypass","extension":"main-worktree-guard","reason":"main_edits_marker","session_id":"…","marker_path":"…","ttl_ms":900000,"expires_at":"…","marker_content":"{\"session_id\":…,\"reason\":…,\"ts\":…}"}
```

The marker content is logged, so even a bare `touch` (no reason comment)
records a timestamped creation with the session id. The session itself also
prints a one-line log at stamp time:

```
[main-worktree-guard] 🔓 Escape marker active for session <id> until <expires_at> (reason: <reason>)
```

### Fail-safe semantics

Absent / unreadable / expired / unparseable / unscoped / mismatched /
**symlinked** (the pinned `realpathSync(path) !== resolve(path)` check rejects
any symlink indirection) marker → treated as absent → **blocked**. A
`printf`/`echo`/redirect that writes the marker path is **out-of-contract**:
it clobbers the guard's stamp, the marker becomes unscoped, and the guard
blocks. The env hatch is unchanged — the marker is an additional OR branch,
never a replacement.

## The existing script backdoor (documented, not closed)

A guard-blocked session can still escape through the write tool + bash script
execution: it writes `/tmp/recover.sh` (the write tool classifies outside-
project paths as ALLOW) and runs `bash /tmp/recover.sh` (classifies
`allow-non-git`), executing arbitrary git ops unblocked. This is an
**undocumented, unbounded, unaudited** backdoor. It is deliberately **not
closed**: blocking script execution risks false positives on legitimate script
use. Closing it is a possible follow-up. The escape marker above is the
sanctioned, bounded, audited alternative.

## What it does NOT fix

**Hung processes.** A hung process cannot issue any tool call, so it can never
touch a marker. The hung-process class currently has **no owner** — #203 is
closed with a different scope (auto-sync non-main-branch recovery, not process
supervision). A process-supervision follow-up (new issue) is required. The
marker fixes **guard-blocked** sessions only.

## Manual verification checklist

Claims in this README are kept minimal and implementation-literal. From the
shared main checkout of a project with the guard active:

1. `git checkout main` → **blocked** (guard reason shown).
2. `touch ~/.pi/agent/.allow-main-edits  # recovery` as its **OWN** bash
   call → allowed; the session logs the 🔓 escape-marker line.
3. `git checkout main && git pull --ff-only` in the **FOLLOW-UP** call →
   succeeds.
4. `cat ~/.pi/agent/.allow-main-edits` → shows `session_id` + `reason` + `ts`.
5. `tail ~/.pi/agent/audit/gate-events.jsonl` → a `gate_bypass` /
   `main_edits_marker` line with session_id + marker content + expires_at.
6. Wait 15+ minutes → the same recovery op is **blocked again**.
7. Re-`touch` → immediately allowed again (refresh).
