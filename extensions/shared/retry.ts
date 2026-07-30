/**
 * shared/retry.ts — retry with exponential backoff + circuit breaker.
 *
 * Retry ONLY on process-level failures (zero output, spawn crash).
 * Never retry when the sub-agent produced any output.
 * ponytail: single file, no dependencies beyond Node.js built-ins.
 */

export type CircuitState = "closed" | "open" | "half-open";

export interface CircuitBreaker {
  state: CircuitState;
  failureCount: number;
  lastFailure: number;
  lastSuccess: number;
  threshold: number;
  cooldownMs: number;
}

export function createCircuitBreaker(opts?: { threshold?: number; cooldownMs?: number }): CircuitBreaker {
  return {
    state: "closed",
    failureCount: 0,
    lastFailure: 0,
    lastSuccess: 0,
    threshold: opts?.threshold ?? 3,
    cooldownMs: opts?.cooldownMs ?? 60_000,
  };
}

export function circuitAllows(cb: CircuitBreaker): boolean {
  if (cb.state === "closed") return true;
  if (cb.state === "open") {
    if (Date.now() - cb.lastFailure > cb.cooldownMs) {
      cb.state = "half-open";
      return true;
    }
    return false;
  }
  return true; // half-open
}

export function circuitRecordSuccess(cb: CircuitBreaker): void {
  cb.failureCount = 0;
  cb.lastSuccess = Date.now();
  cb.state = "closed";
}

export function circuitRecordFailure(cb: CircuitBreaker): void {
  cb.failureCount++;
  cb.lastFailure = Date.now();
  if (cb.state === "half-open" || cb.failureCount >= cb.threshold) {
    cb.state = "open";
  }
}

export interface RetryOptions {
  maxAttempts?: number;
  baseDelayMs?: number;
  maxDelayMs?: number;
  circuitBreaker?: CircuitBreaker;
  onRetry?: (attempt: number, delayMs: number) => void;
}

export interface RetryResult<T> {
  status: "success" | "timeout" | "failed" | "circuit_open";
  value?: T;
  retries: number;
  elapsedMs: number;
}

export async function retry<T>(
  fn: (attempt: number) => Promise<T | undefined>,
  opts: RetryOptions = {},
): Promise<RetryResult<T>> {
  const maxAttempts = opts.maxAttempts ?? 3;
  const baseDelayMs = opts.baseDelayMs ?? 1000;
  const maxDelayMs = opts.maxDelayMs ?? 16000;
  const cb = opts.circuitBreaker;
  const startedAt = Date.now();

  for (let attempt = 1; attempt <= maxAttempts; attempt++) {
    if (cb && !circuitAllows(cb)) {
      return { status: "circuit_open", retries: attempt - 1, elapsedMs: Date.now() - startedAt };
    }

    try {
      const result = await fn(attempt);
      if (result !== undefined) {
        if (cb) circuitRecordSuccess(cb);
        return { status: "success", value: result, retries: attempt - 1, elapsedMs: Date.now() - startedAt };
      }
      if (cb) circuitRecordFailure(cb);
    } catch {
      if (cb) circuitRecordFailure(cb);
    }

    if (attempt < maxAttempts) {
      const delay = Math.min(baseDelayMs * Math.pow(2, attempt - 1), maxDelayMs);
      const jitter = delay * 0.25 * (Math.random() * 2 - 1);
      const waitMs = Math.max(0, Math.round(delay + jitter));
      opts.onRetry?.(attempt, waitMs);
      await new Promise(r => setTimeout(r, waitMs));
    }
  }

  return { status: "failed", retries: maxAttempts, elapsedMs: Date.now() - startedAt };
}
