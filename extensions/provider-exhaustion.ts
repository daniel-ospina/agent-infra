/**
 * provider-exhaustion — in-session exhaustion detection + hop for issue #476
 *
 * The interactive/child complement to the builtin-tools dispatch wiring
 * (Phase 2): the parent task-tool only sees exhaustion when a CHILD dies with
 * a marker. This extension provides the two session-side halves:
 *
 *   1. CHILD half (ctx.mode print/json — task-tool sub-agents): classify the
 *      failing turn's errorMessage at `message_end` (s2: the ONLY reliable
 *      402 signal — `after_provider_response` never fires on non-2xx for the
 *      SDK-backed openai-completions transport used by every agent-infra
 *      provider), remember the FIRST exhaustion/auth-block, and emit the
 *      sB1-contract `[provider-exhaustion]` marker as the FINAL stderr write
 *      from `session_shutdown` (fires on success AND error paths before
 *      process exit). The PARENT (builtin-tools runFailoverDecisionLoop) is
 *      the durable-latch writer + hopper — the child NEVER writes the latch
 *      (a double write would double-advance the chain) and NEVER calls
 *      setModel (CLI --model must stay authoritative in print — sC3).
 *      Marker emission requires TASK_HEARTBEAT=1 + TASK_HEARTBEAT_NONCE
 *      (the parent-injected per-dispatch nonce; the parent rejects markers
 *      without it — fail-closed).
 *
 *   2. INTERACTIVE half (ctx.mode tui ONLY — the durable half is allow-listed
 *      so an unknown future headless mode can never silently invert the
 *      child-never-writes-the-latch invariant): the session itself is the dispatch
 *      owner, so the extension does the durable latch (setExhausted w/ a
 *      notice), prints an operator-visible banner, and hops the NEXT turn
 *      onto the chain's next available leg (pi.setModel — applies from the
 *      next request onward per sC3). `session_start` hops a latched family
 *      before the first prompt (interactive-only; print children leave the
 *      CLI model untouched); `turn_start` returns to the family primary once
 *      the poller clears a latch that THIS session observed (verified
 *      positive balance — a never-latched hop leg chosen explicitly by the
 *      user is never yanked; see latchSeenFamilies). Interactive never emits
 *      markers (no nonce, no parent reader).
 *
 * Gating: the whole extension is inert under PROVIDER_FAILOVER_DISABLE=1
 * (matches the Phase-2 dispatch kill switch). Everything below is exported
 * pure for unit tests; the default export wires pi events.
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import * as fs from "node:fs";
import {
  classifyExhaustionText,
  readLatchState,
  setExhausted,
  markLegBlocked,
  resolveWithChain,
  familyOf,
  familyLegs,
  rootPrimaryOfFamily,
  isLatched,
  failoverDisabled,
  renderExhaustionMarker,
} from "./shared/provider-failover.js";
import type { ExhaustionMarker } from "./shared/provider-failover.js";

// ── Pure helpers (exported for unit tests) ─────────────────────────────

/** Mode classification: print/json children of the task tool vs tui. */
export function isChildMode(mode: string | undefined): boolean {
  return mode === "print" || mode === "json";
}

/** Marker emission is eligible only in a task-tool child: TASK_HEARTBEAT=1
 * (sub-agent identity) AND the parent-injected per-dispatch nonce. Without
 * the nonce there is no authenticating reader — never emit. */
export function childMarkerEligible(env: Record<string, string | undefined> = process.env): boolean {
  return env.TASK_HEARTBEAT === "1" && typeof env.TASK_HEARTBEAT_NONCE === "string" && env.TASK_HEARTBEAT_NONCE.length > 0;
}

/** Split a session model string into {provider, model} using the #154
 * rules: "provider/with/slashes" splits on the FIRST slash; bare ids default
 * claude→anthropic / else→deepseek (legacy). Pure. */
export function splitSessionModel(model: string | undefined): { provider: string; model: string } {
  const m = model || "";
  const slash = m.indexOf("/");
  if (slash > 0) return { provider: m.slice(0, slash), model: m.slice(slash + 1) };
  if (m.startsWith("claude")) return { provider: "anthropic", model: m };
  return { provider: "deepseek", model: m };
}

/** The family of a session model (undefined = not a chain member). */
export function sessionFamily(model: string | undefined): string | undefined {
  const { provider, model: id } = splitSessionModel(model);
  return familyOf(id, provider);
}

/** Session active-model accessor. In real pi, ctx.model is a Model OBJECT
 * ({id, provider, api, baseUrl, ...} — empirically verified, round-2 P0); an
 * id string is accepted defensively (legacy/harness). Returns the parts the
 * pure helpers consume. NEVER feed the raw ctx.model into string parsing: an
 * openrouter leg id is "deepseek/deepseek-v4-flash" (slash INSIDE the id) and
 * must not be split as provider/model. */
export function modelParts(ctxModel: unknown): { provider: string; model: string } {
  if (ctxModel && typeof ctxModel === "object") {
    const m = ctxModel as { id?: unknown; provider?: unknown };
    const provider = typeof m.provider === "string" ? m.provider : "";
    const id = typeof m.id === "string" ? m.id : "";
    if (provider) return { provider, model: id };
  }
  return splitSessionModel(typeof ctxModel === "string" ? ctxModel : undefined);
}

/** Classify ONE failing assistant turn (message_end payload). Returns the
 * exhaustion/auth signal or null. Anchors on errorMessage TEXT (s2 — there
 * is no status on the message); role/stopReason guards keep user/tool and
 * healthy assistant messages out. */
export interface TurnClassification {
  kind: "exhaustion" | "blocked" | null;
  reason: "402" | "low_balance" | "blocked" | null;
  matched: string | null;
}

export function classifySessionTurn(message: unknown): TurnClassification {
  const msg = message as { role?: string; stopReason?: string; errorMessage?: string } | null | undefined;
  if (!msg || msg.role !== "assistant") return { kind: null, reason: null, matched: null };
  if (msg.stopReason !== "error" && !msg.errorMessage) return { kind: null, reason: null, matched: null };
  const cls = classifyExhaustionText(msg.errorMessage ?? null);
  if (cls.kind === "exhaustion") return { kind: "exhaustion", reason: cls.reason, matched: cls.matched };
  if (cls.kind === "auth_permanent") return { kind: "blocked", reason: "blocked", matched: cls.matched };
  return { kind: null, reason: null, matched: null };
}

/** The marker the child should emit for a latched-in-session signal. hop is
 * self→self — the PARENT knows the from-leg it dispatched and computes the
 * real chain next leg (Phase 2 marker branch); marker.hop is display-only. */
export function buildChildMarker(input: {
  provider: string;
  model: string;
  reason: "402" | "low_balance" | "blocked";
  nonce: string;
}): ExhaustionMarker {
  return {
    kind: "provider-exhaustion",
    hop: `${input.provider}->${input.provider}`,
    model: input.model,
    reason: input.reason,
    provider: input.provider,
    nonce: input.nonce,
  };
}

/** Interactive hop target for a family given the current latch state.
 * Returns the leg the session should switch to (or null when the current
 * leg stays / nothing available). */
export function interactiveHopTarget(
  leg: { provider: string; model: string } | undefined,
  state: ReturnType<typeof readLatchState>,
  env: Record<string, string | undefined> = process.env,
): { provider: string; model: string } | null {
  const { provider, model: id } = leg ?? { provider: "deepseek", model: "" };
  const fam = familyOf(id, provider);
  if (!fam) return null;
  const outcome = resolveWithChain(fam, { provider, model: id }, state, { env });
  if (outcome.halted || !outcome.leg) return null;
  if (outcome.leg.provider === provider && outcome.leg.model === id) return null;
  return outcome.leg;
}

/** Return-to-primary target (interactive turn_start): when the session is on
 * a HOP leg of a family whose ROOT record is ABSENT — the balance poller
 * cleared the latch on verified positive balance (restore is poller-clear-
 * driven, NOT TTL-driven: a stale-but-present record keeps the hop until the
 * poller clears it; dispatch-level resolution self-heals after TTL, the
 * interactive session stays put) — switch back to the family root leg. */
export function interactiveRestoreTarget(
  leg: { provider: string; model: string } | undefined,
  state: ReturnType<typeof readLatchState>,
  env: Record<string, string | undefined> = process.env,
): { provider: string; model: string } | null {
  const { provider, model: id } = leg ?? { provider: "deepseek", model: "" };
  const fam = familyOf(id, provider);
  if (!fam) return null;
  const root = familyLegs(fam)?.[0];
  if (!root || provider === root.provider) return null; // already on primary
  if (state.primaries?.[root.provider]) return null; // root still latched → stay
  // root record ABSENT (poller cleared the latch on verified balance) → return
  // to the family's primary leg (the chain table root).
  return root;
}

// ── Extension ───────────────────────────────────────────────────────────

/** Set when a child latched an in-session signal — emitted at shutdown. */
let pendingMarker: string | null = null;

/** Families this process observed an EXHAUSTION LATCH for (interactive only).
 * Added on (a) an interactive message_end setExhausted and (b) session_start
 * finding the session's family root latched. turn_start RESTORE is gated on
 * this set: a hop-leg session whose root record is absent is a poller-clear
 * ONLY when a latch existed in this session — when the root was never latched
 * (user EXPLICITLY chose the hop leg, e.g. `pi --provider openrouter --model
 * deepseek/deepseek-v4-pro`) an absent root means "no exhaustion history",
 * not "restored balance", and yanking the session back with a misleading
 * "Provider balance restored" banner would be wrong (deep-review P2). */
const latchSeenFamilies = new Set<string>();

/** Families where THIS session drained a HOP leg (not the root) while the
 * root was never latched / already stale — i.e. the hop provider's OWN
 * account ran out (e.g. the user explicitly chose openrouter and openrouter's
 * independent credits drained) rather than a root-exhaustion chain event.
 * Banner distinction only (deep-review P2-7): the next-turn restore to the
 * primary is correct in BOTH cases, but "the balance poller is the restore
 * path" / "Provider balance restored" are misleading for a hop-own drain —
 * the poller never monitors the hop leg's balance and the primary was never
 * low. Tracked so the terminal + restore banners say what actually happened. */
const hopDrainSeenFamilies = new Set<string>();

/** States already alerted in this session (terminal/blocked banners are shown
 * ONCE per state, not per failing turn — review round-1 P3-3). */
const alertedStates = new Set<string>();

/** stderr sink — swapped by tests to capture the writeSync bytes. */
let writeStderr = (line: string): void => {
  fs.writeSync(2, line);
};

export function _setMarkerSinkForTests(sink: (line: string) => void): void {
  writeStderr = sink;
}

export function _resetPendingMarkerForTests(): void {
  pendingMarker = null;
}

export function _resetLatchSeenFamiliesForTests(): void {
  latchSeenFamilies.clear();
  hopDrainSeenFamilies.clear();
}

export function _pendingMarkerForTests(): string | null {
  return pendingMarker;
}

const failoverEnvActive = (): boolean => !failoverDisabled();

export default function (pi: ExtensionAPI) {
  if (!failoverEnvActive()) return;

  /** Best-effort operator-visible banner (interactive runs). */
  const notify = (title: string, body: string) => {
    try {
      console.error(`\n⚠️  ${title}\n    ${body}\n`);
    } catch {
      // never break the session on a banner failure
    }
  };
  /** Banner dedupe — one alert per state key per session (P3-3). */
  const notifyOnce = (key: string, title: string, body: string) => {
    if (alertedStates.has(key)) return;
    alertedStates.add(key);
    notify(title, body);
  };

  /** Best-effort model switch to a target leg (round-2 P0): ctx.modelRegistry
   * is the runner's ModelRegistry (find(provider, modelId) → Model object);
   * pi.setModel REQUIRES a Model object, not a bare id string. A registry
   * MISS (target provider/model not configured in models.json) reports
   * ok=false — the caller's no-hop notice fires and the session stays put.
   * NEVER fabricate a bare {id, provider} object: pi.setModel on an
   * unconfigured provider would break the very next request, and the hop
   * banner would lie (deep-review P2 — silent break on registry miss). */
  const switchModel = async (
    ctx: any,
    target: { provider: string; model: string },
    onResult: (ok: boolean) => void,
  ) => {
    let resolved: unknown = undefined;
    try {
      resolved = ctx?.modelRegistry?.find?.(target.provider, target.model);
    } catch {
      resolved = undefined;
    }
    if (!resolved) {
      onResult(false);
      return;
    }
    try {
      const ok = await pi.setModel(resolved);
      onResult(ok === false ? false : true);
    } catch {
      onResult(false);
    }
  };

  pi.on("message_end", async (event, ctx: any) => {
    if (!ctx || !ctx.model) return;
    const cls = classifySessionTurn((event as { message?: unknown })?.message);
    if (!cls.kind) return; // audit_only / healthy / quoted — never act
    if (isChildMode(ctx.mode)) {
      // CHILD (print/json = task-tool sub-agents): remember FIRST signal only;
      // never write the latch, never setModel (CLI --model authoritative in
      // print — sC3). The parent builtin-tools decision loop is the writer.
      if (pendingMarker === null && childMarkerEligible()) {
        const { provider, model } = modelParts(ctx.model);
        pendingMarker = renderExhaustionMarker(
          buildChildMarker({ provider, model, reason: cls.reason as "402" | "low_balance" | "blocked", nonce: process.env.TASK_HEARTBEAT_NONCE ?? "" }),
        );
      }
      return;
    }
    // Durable half: EXPLICIT ctx.mode === "tui" only (review round-1 P3-1) —
    // every non-print/json mode is NOT necessarily a task child, but the
    // "child never writes the latch" invariant must not silently invert for
    // an unknown future headless mode. Unknown modes stay inert.
    if (ctx.mode !== "tui") return;
    // INTERACTIVE (tui): durable latch + notice + hop next turn.
    const { provider, model } = modelParts(ctx.model);
    const fam = familyOf(model, provider);
    const detail =
      cls.kind === "blocked"
        ? `provider ${provider} reported a permanent auth block (${cls.matched ?? "401/403"}) — excluded from failover hop candidates`
        : `provider credit exhaustion (${cls.reason ?? "402"}${cls.matched ? ` — ${cls.matched}` : ""}). Message: ${String(((event as { message?: { errorMessage?: string } })?.message?.errorMessage) ?? "").slice(0, 300)}`;
    if (cls.kind === "blocked") {
      markLegBlocked(provider, `interactive:${cls.matched ?? "auth"}`, {});
      notifyOnce(`blocked:${provider}`, "Provider auth-blocked (failover)", detail);
      return;
    }
    const state = setExhausted({
      primaryProvider: provider,
      reason: cls.reason === "low_balance" ? "low_balance" : "402",
      source: "interactive",
      family: fam,
      fromLeg: { provider, model },
      notice: { title: "Provider credit exhausted", body: detail },
      env: process.env,
    });
    if (fam) latchSeenFamilies.add(fam); // this session IS on a drained family — restore gate (deep-review P2)
    notifyOnce(`exhausted:${fam ?? provider}`, "Provider credit exhausted — failover latch set", detail);
    // Banner context (deep-review P2-7): is this drain the HOP leg's OWN
    // account event (root never latched / not in-flight) — e.g. the user
    // explicitly chose openrouter and openrouter's credits drained — or a
    // continuation of a ROOT exhaustion (chain hop)? Both recover by moving
    // off the drained leg; the wording must not blame the poller/root.
    const root = fam ? rootPrimaryOfFamily(fam) : undefined;
    const rootRec = root ? state.primaries?.[root] : undefined;
    const rootFresh = rootRec !== undefined && isLatched(root, state);
    const hopOwnDrain = fam !== undefined && root !== undefined && provider !== root && !rootFresh;
    if (hopOwnDrain) hopDrainSeenFamilies.add(fam);
    // Hop the NEXT turn onto the chain's next available leg.
    const target = interactiveHopTarget({ provider, model }, state);
    if (target) {
      await switchModel(ctx, target, (ok) => {
        if (!ok) {
          notifyOnce(`nohop:${target.provider}/${target.model}`, "Failover model switch unavailable", `no configured auth for ${target.provider} — next turn continues on ${provider}/${model}`);
          return;
        }
        const banner = hopOwnDrain
          ? {
              title: "Auto-switching provider (hop account drained)",
              body: `${provider}/${model} (hop leg) drained its own credits → ${target.provider}/${target.model} (next turn)`,
            }
          : {
              title: "Auto-switching provider",
              body: `${provider}/${model} → ${target.provider}/${target.model} (next turn; the balance poller restores the primary on verified funds)`,
            };
        notifyOnce(`hop:${target.provider}/${target.model}`, banner.title, banner.body);
      });
    } else if (hopOwnDrain) {
      notifyOnce(`terminal:${fam ?? provider}`, "Hop provider drained — returning to the primary", `no other hop leg available for family ${fam ?? provider} — next turn returns to the primary ${root}/${(familyLegs(fam as string)?.[0])?.model ?? ""} (its account was never exhausted)`);
    } else {
      notifyOnce(`terminal:${fam ?? provider}`, "All failover legs unavailable", `family ${fam ?? provider} has no available hop leg — the balance poller is the restore path`);
    }
  });

  // session_shutdown — CHILD marker emission (sB1 SPEC): fires on success AND
  // error paths before process exit; the marker is the LAST stderr write via
  // writeSync so no async pipe write can be cut by an exit path.
  pi.on("session_shutdown", async () => {
    if (pendingMarker !== null) {
      try {
        writeStderr(pendingMarker);
      } catch {
        // stderr EPIPE to a dead parent — the latch simply isn't seen
      }
      pendingMarker = null;
    }
  });

  // session_start — INTERACTIVE only: hop a latched family before the first
  // prompt (print children: CLI --model is authoritative — sC3, no-op).
  pi.on("session_start", async (_event, ctx: any) => {
    if (!ctx || ctx.mode !== "tui") return; // print/json children: CLI authoritative (sC3)
    const parts = modelParts(ctx.model);
    const state = readLatchState();
    // RESTORE gate: record the family when its ROOT is observed latched at
    // session start — the session is on (or about to hop to) a hop leg in
    // response to a real exhaustion. An explicitly-chosen hop leg under a
    // HEALTHY root (no latch anywhere) stays unrecorded: when the poller
    // later "clears" nothing for it, turn_start must not yank it back with a
    // false "balance restored" banner (deep-review P2).
    const fam = familyOf(parts.model, parts.provider);
    if (fam) {
      const root = rootPrimaryOfFamily(fam);
      if (root && state.primaries?.[root] && isLatched(root, state)) latchSeenFamilies.add(fam);
    }
    const target = interactiveHopTarget(parts, state);
    if (target) {
      await switchModel(ctx, target, (ok) => {
        if (ok) {
          notifyOnce(`sessionstart:${target.provider}/${target.model}`, "Provider failover hop", `session model ${parts.provider}/${parts.model} is on an exhausted family — starting on ${target.provider}/${target.model} (poller restores on verified balance)`);
        }
      });
    }
  });

  // turn_start — INTERACTIVE only: when the poller cleared a latch that
  // existed THIS session, return to the family primary (restore path). Print
  // children never hop (no-op). Gated on latchSeenFamilies: an absent root
  // only means "poller cleared it" when the family was latched during this
  // process — an explicitly-chosen hop leg (root never latched) must NOT be
  // yanked back (deep-review P2).
  pi.on("turn_start", async (_event, ctx: any) => {
    if (!ctx || ctx.mode !== "tui") return;
    const parts = modelParts(ctx.model);
    const fam = familyOf(parts.model, parts.provider);
    if (!fam || !latchSeenFamilies.has(fam)) return; // no exhaustion history this session → stay put
    const state = readLatchState();
    const target = interactiveRestoreTarget(parts, state);
    if (target) {
      await switchModel(ctx, target, (ok) => {
        if (ok) {
          // Banner accuracy (deep-review P2-7): a hop-OWN drain (openrouter's
          // credits ran out under a healthy/never-latched root) is not a
          // poller-restored root — say what actually happened.
          const banner = hopDrainSeenFamilies.has(fam)
            ? {
                title: "Returning to the primary provider",
                body: `hop leg ${parts.provider}/${parts.model} drained its own credits — continuing on the primary ${target.provider}/${target.model}`,
              }
            : {
                title: "Provider balance restored",
                body: `returning to the primary ${target.provider}/${target.model}`,
              };
          notifyOnce(`restore:${target.provider}/${target.model}`, banner.title, banner.body);
        }
      });
    }
  });
}

