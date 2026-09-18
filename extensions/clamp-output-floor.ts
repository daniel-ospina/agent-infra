// clamp-output-floor.ts — #1214(b): the REQUEST-SIDE half of the clamp-death fix, as an extension.
//
// WHY THIS EXISTS SEPARATELY FROM THE PATCH
// -----------------------------------------
// The defect is inside pi's own request path (`clampMaxTokensToContext` in pi-ai): once pi's
// context estimate passes `contextWindow - 4096` the output budget collapses, and pi asks the
// model for **one** token. The model returns `stopReason: "length"` with `output: 1`, the turn
// is accounted as a normal turn, and the session stays alive while never being able to reply
// again. Measured on this fleet: 188 such turns across 49 sessions, 4 of them permanent.
//
// `scripts/pi-patches/` carries the source fix, but a patch inside node_modules is reverted by
// the next install. THIS extension is the part that cannot evaporate: it hooks
// `before_provider_request` — the one place pi lets an extension REPLACE the outgoing payload —
// and raises an absurd output ceiling back to a usable floor before the request leaves.
//
// It is deliberately complementary, not a duplicate: when the source patch IS applied the clamp
// never produces an absurd ceiling, so this handler is a no-op and never fires. It is the
// fallback for the window between an upgrade and the re-apply — and for any session that starts
// before someone notices the patch is gone.
//
// WHY "RAISE IT" AND NOT "THROW"
// ------------------------------
// pi's ceiling (`contextWindow - reserve`) sits far below what providers serve — one route
// served a 988,202-token prompt while pi was asking for 1 token, and this fleet has run ~1M
// (12 sessions over 968k). So an absurd ceiling is NOT proof the request is too long; it is
// usually an estimator artefact. Refusing the request would fail a request the provider would
// have served. Raising the ceiling means: if the prompt really is over the provider's limit the
// provider rejects it — LOUD, and already handled by pi's overflow path — and otherwise the
// turn simply works. Overflow is better than death, because it is loud.
//
// SCOPE — deliberately tiny and provable:
//   • only a KNOWN output-ceiling field is touched;
//   • only a value in [0, 16] is touched — the measured clamp floors are 1 (most APIs) and 16
//     (openai-responses, OPENAI_RESPONSES_MIN_OUTPUT_TOKENS);
//   • anything above 16 is returned untouched (`undefined`), so a healthy turn is byte-identical;
//   • every repair is recorded durably (session entry + fleet log) and announced once per
//     session, so the repair can never be the silent thing it replaces.
//
// Gate: `CLAMP_OUTPUT_FLOOR=0` disables it. Default ON — the sessions that died were fleet
// sessions, so this must run in interactive and print modes alike (no TASK_HEARTBEAT gating).
import { appendFileSync, mkdirSync, readFileSync, realpathSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

/** The measured floors the clamp can produce: 1 on most APIs, 16 on openai-responses. */
export const ABSURD_CEILING_MAX = 16;

/** What we raise an absurd ceiling to. Matches `MIN_USABLE_MAX_TOKENS` in the source patch. */
export const OUTPUT_FLOOR_TOKENS = 1024;

export const CLAMP_OUTPUT_FLOOR_ENTRY_TYPE = "clamp-output-floor";
export const CLAMP_OUTPUT_FLOOR_LOG = "clamp-floor-repairs.log";

/** Test seam (#212 convention, mirroring compaction-watchdog.ts). */
export interface ClampOutputFloorHooks {
	appendFile: typeof appendFileSync;
	mkdir: typeof mkdirSync;
	homedir: typeof homedir;
}
const defaultHooks: ClampOutputFloorHooks = { appendFile: appendFileSync, mkdir: mkdirSync, homedir };
export const clampOutputFloorHooks: ClampOutputFloorHooks = { ...defaultHooks };
export function _setClampOutputFloorHooksForTest(overrides: Partial<ClampOutputFloorHooks>): ClampOutputFloorHooks {
	if (process.env.NODE_ENV !== "test") return clampOutputFloorHooks;
	const previous = { ...clampOutputFloorHooks };
	if (overrides.appendFile) clampOutputFloorHooks.appendFile = overrides.appendFile;
	if (overrides.mkdir) clampOutputFloorHooks.mkdir = overrides.mkdir;
	if (overrides.homedir) clampOutputFloorHooks.homedir = overrides.homedir;
	return previous;
}

export function clampOutputFloorActive(env: Record<string, string | undefined>): boolean {
	return env.CLAMP_OUTPUT_FLOOR !== "0";
}

/**
 * Output-ceiling fields, in the order pi's providers read them. First match wins, and the match
 * is by the field the provider will actually send, so a payload carrying both `max_tokens` and a
 * nested `inferenceConfig.maxTokens` (Bedrock) resolves to the one in play.
 */
export const CEILING_PATHS: ReadonlyArray<readonly [string, string | null]> = [
	["max_tokens", null],
	["max_completion_tokens", null],
	["max_output_tokens", null],
	["maxTokens", null],
	["maxOutputTokens", "generationConfig"],
	["maxTokens", "inferenceConfig"],
];

export interface CeilingLocation {
	field: string;
	parent: string | null;
	value: number;
}

/** Locate the outgoing output ceiling. `undefined` when no known field carries a number. */
export function findOutputCeiling(payload: unknown): CeilingLocation | undefined {
	if (!payload || typeof payload !== "object") return undefined;
	for (const [field, parent] of CEILING_PATHS) {
		const container = parent === null ? payload : (payload as Record<string, unknown>)[parent];
		if (!container || typeof container !== "object") continue;
		const value = (container as Record<string, unknown>)[field];
		if (typeof value === "number" && Number.isFinite(value)) return { field, parent, value };
	}
	return undefined;
}

export interface FloorRepair {
	field: string;
	parent: string | null;
	from: number;
	to: number;
	/** Context numbers, when the extension context can supply them. */
	contextTokens: number | null;
	contextWindow: number | null;
}

/**
 * The whole decision, pure and testable: given a payload, return the repair to make, or
 * `undefined` to leave the payload EXACTLY as it is.
 *
 * Returns undefined for every value above `ABSURD_CEILING_MAX` and for a missing/non-numeric
 * ceiling — that is the negative control that keeps a healthy turn untouched.
 */
export function planFloorRepair(payload: unknown, floor = OUTPUT_FLOOR_TOKENS): FloorRepair | undefined {
	const located = findOutputCeiling(payload);
	if (!located) return undefined;
	if (!(located.value >= 0 && located.value <= ABSURD_CEILING_MAX)) return undefined;
	// A caller cap BELOW the floor that is still usable is honoured; only a budget too small to
	// produce an answer is raised.
	if (located.value >= floor) return undefined;
	return {
		field: located.field,
		parent: located.parent,
		from: located.value,
		to: floor,
		contextTokens: null,
		contextWindow: null,
	};
}

/** Apply a repair without mutating the caller's payload object. */
export function applyFloorRepair(payload: unknown, repair: FloorRepair): unknown {
	const base = payload as Record<string, unknown>;
	if (repair.parent === null) return { ...base, [repair.field]: repair.to };
	const nested = base[repair.parent];
	if (!nested || typeof nested !== "object") return payload;
	return { ...base, [repair.parent]: { ...(nested as Record<string, unknown>), [repair.field]: repair.to } };
}

export interface ContextNumbers {
	contextTokens: number | null;
	contextWindow: number | null;
}

/** Best-effort context numbers for the record; never invents a value. */
export function readContextNumbers(ctx: unknown): ContextNumbers {
	let contextWindow: number | null = null;
	let contextTokens: number | null = null;
	try {
		const model = (ctx as { model?: Record<string, unknown> } | null | undefined)?.model;
		const cw = model?.contextWindow;
		if (typeof cw === "number" && Number.isFinite(cw) && cw > 0) contextWindow = cw;
	} catch {
		/* unused */
	}
	try {
		const usage = (ctx as { getContextUsage?: () => unknown } | null | undefined)?.getContextUsage?.();
		const tokens = (usage as { tokens?: unknown } | null | undefined)?.tokens;
		if (typeof tokens === "number" && Number.isFinite(tokens)) contextTokens = tokens;
	} catch {
		/* unused */
	}
	return { contextTokens, contextWindow };
}

export function repairMessage(repair: FloorRepair): string {
	const context =
		repair.contextTokens !== null && repair.contextWindow !== null
			? ` context=${repair.contextTokens}/${repair.contextWindow}`
			: "";
	return `output ceiling was about to go out as ${repair.from} (${repair.field}); raised to ${repair.to}${context}. The provider will reject the request if the prompt is genuinely too long — that is loud and recoverable; asking for ${repair.from} token(s) is not.`;
}

function errText(error: unknown): string {
	return error instanceof Error ? error.message : String(error);
}

/**
 * Is the SOURCE patch (`scripts/pi-patches/apply.sh`) in the running build?
 *
 * A patch inside node_modules evaporates at the next install, and the evaporation is silent —
 * which is the whole reason this extension exists. So the extension probes the clamp it would be
 * compensating for and says WHICH layer is holding the line. The check is SYNCHRONOUS: an async
 * probe can lose the race with process exit in `pi -p`, and a self-check that can be silent is
 * the failure mode being closed.
 *
 * The bundled chunk's content-hashed filename changes on every upgrade, so a miss there is the
 * version-drift signal (reported as "unknown" and warned about), never a silent success.
 */
export function detectSourcePatch(piRoot: string): boolean | "unknown" {
	// The BUNDLE is the authority: it is the code that actually makes the request. A patched
	// pi-ai ESM copy does not help a running CLI, so it is deliberately NOT accepted as a
	// substitute — reporting "present" on the strength of a file that never executes is exactly
	// the false-PASS this check exists to prevent.
	const bundled = join(piRoot, "dist", "bundle", "chunks", "chunk-AXIIZGTV.js");
	let text: string;
	try {
		text = readFileSync(bundled, "utf8");
	} catch {
		// Content-hashed filename moved (an upgrade, or a different bundle layout): cannot judge.
		return "unknown";
	}
	if (text.includes("available<MIN_USABLE_MAX_TOKENS?")) return true;
	return text.includes("function clampMaxTokensToContext") ? false : "unknown";
}

/**
 * The installed pi package root, derived from the entry script.
 *
 * `process.argv[1]` is the `pi` SHIM (`<prefix>/bin/pi`), not the bundle — so it must be
 * realpath'd before the `dist/bundle` segment is stripped. Verified against a live 0.85.1
 * install: argv[1] = `<prefix>/bin/pi` -> realpath `<pkg>/dist/bundle/cli.js`.
 */
export function resolvePiRoot(): string | undefined {
	const candidates: string[] = [];
	if (process.env.PI_ROOT) candidates.push(join(process.env.PI_ROOT, "dist", "bundle", "cli.js"));
	if (process.argv[1]) candidates.push(process.argv[1]);
	for (const raw of candidates) {
		let resolved = raw;
		try {
			resolved = realpathSync(raw);
		} catch {
			/* keep the raw path — it may still carry the marker */
		}
		const at = resolved.indexOf(join("dist", "bundle"));
		if (at > 0) return resolved.slice(0, at - 1);
	}
	return undefined;
}

let sourcePatchReported = false;


function sessionInfo(ctx: unknown): { sessionId: string | null; sessionFile: string | null } {
	let sessionId: string | null = null;
	let sessionFile: string | null = null;
	try {
		const sm = (ctx as { sessionManager?: Record<string, unknown> } | null | undefined)?.sessionManager;
		if (sm && typeof sm === "object") {
			const id = (sm as { getSessionId?: unknown }).getSessionId;
			if (typeof id === "function") {
				const value = (id as () => unknown).call(sm);
				if (typeof value === "string") sessionId = value;
			}
			const file = (sm as { getSessionFile?: unknown }).getSessionFile;
			if (typeof file === "function") {
				const value = (file as () => unknown).call(sm);
				if (typeof value === "string") sessionFile = value;
			}
		}
	} catch {
		/* unreadable identity — the record still fires with nulls, never invented values */
	}
	return { sessionId, sessionFile };
}

/** Sessions already announced; the repair is loud but must not spam every request in a loop. */
const announced = new Set<string>();
export function _resetClampOutputFloorAnnouncementsForTest(): void {
	if (process.env.NODE_ENV === "test") announced.clear();
}

export default function clampOutputFloor(pi: ExtensionAPI): void {
	if (!clampOutputFloorActive(process.env)) return;

	// The source-patch self-check runs at REGISTRATION, not on `session_start`: an extension that
	// only reports inside a lifecycle event can be silent in exactly the mode that needs it
	// (`pi -p`, `--no-session`, RPC). Registration is once per process and every mode reaches it.
	if (!sourcePatchReported) {
		sourcePatchReported = true;
		const piRoot = resolvePiRoot();
		if (piRoot) {
			const patched = detectSourcePatch(piRoot);
			if (patched === true) {
				console.error(
					"[clamp-output-floor] armed — pi-ai source patch PRESENT, so this extension is a no-op fallback",
				);
			} else {
				const detail = patched === "unknown" ? "could not be probed" : "is ABSENT";
				console.error(
					`[clamp-output-floor] ⚠ the pi-ai source patch ${detail} — THIS EXTENSION IS THE ONLY THING RAISING A COLLAPSED OUTPUT CEILING.\n` +
						"[clamp-output-floor]   re-arm it with: bash scripts/pi-patches/apply.sh   (re-derive the manifest if pi was upgraded)",
				);
			}
		}
	}

	pi.on("session_start", (event) => {
		const reason = (event as { reason?: unknown } | null | undefined)?.reason;
		if (reason === "reload") return;
		announced.clear();
	});

	pi.on("before_provider_request", (event, ctx) => {
		const payload = (event as { payload?: unknown } | null | undefined)?.payload;
		const repair = planFloorRepair(payload);
		if (!repair) return undefined;

		const numbers = readContextNumbers(ctx);
		const record = {
			kind: "output-floor-raised",
			...sessionInfo(ctx),
			ts: Date.now(),
			...numbers,
			field: repair.parent ? `${repair.parent}.${repair.field}` : repair.field,
			from: repair.from,
			to: repair.to,
		};

		// (a) durable session entry
		try {
			pi.appendEntry(CLAMP_OUTPUT_FLOOR_ENTRY_TYPE, record);
		} catch (error) {
			console.error(`[clamp-output-floor] appendEntry sink failed: ${errText(error)}`);
		}
		// (b) fleet log
		try {
			const dir = join(clampOutputFloorHooks.homedir(), ".pi", "agent", "state");
			clampOutputFloorHooks.mkdir(dir, { recursive: true });
			clampOutputFloorHooks.appendFile(join(dir, CLAMP_OUTPUT_FLOOR_LOG), `${JSON.stringify(record)}\n`);
		} catch (error) {
			console.error(`[clamp-output-floor] fleet-log sink failed: ${errText(error)}`);
		}
		// (c) loud once per session at the pane
		try {
			const { sessionId, sessionFile } = sessionInfo(ctx);
			const key = sessionId ?? sessionFile ?? "(unknown-session)";
			if (!announced.has(key)) {
				announced.add(key);
				const text = `[clamp-output-floor] ${repairMessage({ ...repair, ...numbers })}`;
				console.error(text);
				(ctx as { ui?: { notify?: (m: string, t?: string) => void } } | null | undefined)?.ui?.notify?.(
					text,
					"error",
				);
			}
		} catch (error) {
			console.error(`[clamp-output-floor] announce failed: ${errText(error)}`);
		}

		// The repair itself: replace the payload so the provider gets a usable budget.
		return applyFloorRepair(payload, repair);
	});
}
