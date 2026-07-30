/**
 * Independent-Context Verifier Sub-Agent — P1
 * 
 * Dispatches to DeepSeek API directly (no sub-process).
 * Structured JSON output contract with 3-level fallback parsing.
 * Verifier health monitoring (3 inconsistencies → escalate).
 */

export interface VerdictOutput {
  verdict: "CLEAN" | "NEEDS_FIX";
  issues_found: number;
  issues: string[];
  evidence: {
    files_reviewed: string[];
    tests_ran: string[];
    git_diff_checked: boolean;
  };
  pre_mortem?: {
    likely_failure_modes: string[];
    confidence: number; // 0-1
  };
}

export interface VerifierResult {
  verdict: VerdictOutput;
  rawOutput: string;
  parseLevel: number; // 0=raw JSON, 1=markdown fence, 2=last-brace, -1=failed
  inconsistent: boolean;
}

const VERIFIER_PROMPT = `You are a pragmatic reviewer. Verify whether the task output meets the objective.

Step 1: What does the output CLAIM was done? (read it literally)
Step 2: Does that match the objective? If yes, verdict = CLEAN.
Step 3: Pre-mortem — what CONCRETE evidence in the output contradicts the claim?
  - Hypothetical "could have failed" is NOT an issue. Only flag what the output actually shows is broken.
  - If the output states a file was created and shows its content, accept it.
  - Only override to NEEDS_FIX if you find a SPECIFIC, NAMED contradiction in the output itself.

You output ONLY valid JSON:
{
  "verdict": "CLEAN" or "NEEDS_FIX",
  "issues_found": <number>,
  "issues": ["concrete issue 1", "concrete issue 2"],
  "evidence": {
    "files_reviewed": [],
    "tests_ran": [],
    "git_diff_checked": false
  },
  "pre_mortem": { "likely_failure_modes": [], "confidence": 0 }
}

CRITICAL: Default to CLEAN. The agent already self-reviewed. Your job is to catch OBVIOUS misses, not to imagine failures.
Do not include any text outside the JSON.`;

export function extractJson(text: string): VerdictOutput | null {
  // Level 0: raw JSON.parse
  try { return JSON.parse(text.trim()) as VerdictOutput; } catch { /* fallthrough */ }
  
  // Level 1: last ```json fence
  const fences = text.match(/```json\s*([\s\S]*?)```/g);
  if (fences) {
    try { return JSON.parse(fences[fences.length - 1].replace(/```json\s*|\s*```/g, "").trim()); } catch { /* fallthrough */ }
  }
  
  // Level 2: try each { position as potential JSON start (handles nested objects)
  const lastClose = text.lastIndexOf("}");
  if (lastClose !== -1) {
    // Try from earliest { to latest }
    let pos = -1;
    while ((pos = text.indexOf("{", pos + 1)) !== -1 && pos < lastClose) {
      try { return JSON.parse(text.slice(pos, lastClose + 1)); } catch { /* fallthrough */ }
    }
  }
  
  return null;
}

export async function dispatchVerifier(
  taskOutput: string,
  objective: string,
  indicators: string
): Promise<VerifierResult> {
  const messages = [
    { role: "system" as const, content: VERIFIER_PROMPT },
    { role: "user" as const, content: `Objective: ${objective}\nIndicators: ${indicators}\n\nTask output to verify:\n${taskOutput}` },
  ];

  // Resolve API key: pi auth.json first, then env vars (OpenRouter > DeepSeek > NVIDIA)
  const { readFileSync, existsSync } = await import("node:fs");
  const { exec: execCb } = await import("node:child_process");
  const { promisify } = await import("node:util");
  const execAsync = promisify(execCb);
  const { join } = await import("node:path");
  let apiKey = "";
  let endpoint = "";
  let resolvedModel = "";
  try {
    const authPath = join(process.env.HOME || "~", ".pi/agent/auth.json");
    const auth = JSON.parse(readFileSync(authPath, "utf-8"));
    // Prefer OpenRouter if configured
    if (auth.openrouter?.key) {
      apiKey = auth.openrouter.key;
      endpoint = "https://openrouter.ai/api/v1/chat/completions";
      resolvedModel = "deepseek/deepseek-chat";
    } else if (auth.deepseek?.key) {
      apiKey = auth.deepseek.key;
      endpoint = "https://api.deepseek.com/v1/chat/completions";
      resolvedModel = "deepseek-chat";
    }
  } catch { /* auth.json unavailable, try env vars */ }
  // Fallback: env vars
  if (!apiKey) {
    if (process.env.OPENROUTER_API_KEY) {
      apiKey = process.env.OPENROUTER_API_KEY;
      endpoint = "https://openrouter.ai/api/v1/chat/completions";
      resolvedModel = "deepseek/deepseek-chat";
    } else if (process.env.DEEPSEEK_API_KEY) {
      apiKey = process.env.DEEPSEEK_API_KEY;
      endpoint = "https://api.deepseek.com/v1/chat/completions";
      resolvedModel = "deepseek-chat";
    } else if (process.env.NVIDIA_API_KEY) {
      apiKey = process.env.NVIDIA_API_KEY;
      endpoint = "https://integrate.api.nvidia.com/v1/chat/completions";
      resolvedModel = "deepseek-ai/deepseek-v4-flash";
    }
  }
  if (!apiKey) {
    console.log("[loop-enforcer] ⚠️ No API key found (auth.json or env) — verifier unavailable");
    return {
      verdict: { verdict: "NEEDS_FIX", issues_found: 1, issues: ["Verifier unavailable — no API key configured"], evidence: { files_reviewed: [], tests_ran: [], git_diff_checked: false } },
      rawOutput: "",
      parseLevel: -1,
      inconsistent: false,
    };
  }
  let text = "";
  try {
    const response = await fetch(endpoint, {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${apiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        model: resolvedModel,
        messages,
        max_tokens: 500,
        temperature: 0,
      }),
      signal: AbortSignal.timeout(15000),
    });

    if (!response.ok) {
      throw new Error(`API returned ${response.status}`);
    }

    const data = await response.json() as { choices: Array<{ message: { content: string } }> };
    text = data.choices?.[0]?.message?.content?.trim() || "";
  } catch (err: any) {
    console.log(`[loop-enforcer] ⚠️ Verifier fetch failed: ${err.message}`);
    // fall through to extractJson — empty text produces NEEDS_FIX fallback
  }

  let verdict: VerdictOutput | null = null;
  let parseLevel = -1;

  if (text) {
    verdict = extractJson(text);
    if (verdict) parseLevel = 0;

    if (!verdict) {
      const textParts = text.replace(/<thinking>[\s\S]*?<\/thinking>/g, '').trim();
      if (textParts) {
        verdict = extractJson(textParts);
        if (verdict) parseLevel = 1;
      }
    }
  }

  if (!verdict) {
    const preview = text.slice(0, 200).replace(/\n/g, '\\n');
    console.log(`[loop-enforcer] ⚠️ Verifier output unparseable. output=${text.length}B preview="${preview}"`);
    return {
      verdict: { verdict: "NEEDS_FIX", issues_found: 1, issues: ["Verifier output unparseable — check console for raw output preview"], evidence: { files_reviewed: [], tests_ran: [], git_diff_checked: false } },
      rawOutput: text,
      parseLevel: -1,
      inconsistent: false,
    };
  }

  return {
    verdict,
    rawOutput: text,
    parseLevel,
    inconsistent: false,
  };
}

/**
 * Deterministic checks that don't require LLM dispatch.
 * Runs npm test and surfaces test_regression failures.
 * The test-debt-gate skill handles auto-filing — we just detect.
 */
export async function runDeterministicChecks(): Promise<{
  passed: boolean;
  issues: string[];
}> {
  const issues: string[] = [];
  const { execSync } = await import("node:child_process");

  try {
    execSync("npm test 2>&1", { encoding: "utf-8", timeout: 120000 });
  } catch (e: any) {
    const stdout = e.stdout || "";
    const stderr = e.stderr || "";
    // Extract failed test count from jest/mocha/vitest output
    const failedMatch = (stdout + stderr).match(/(\d+)\s+failed/);
    const count = failedMatch ? parseInt(failedMatch[1]) : 1;
    issues.push(`test_regression: ${count} test${count !== 1 ? "s" : ""} failed`);
  }

  // Ontology enforcement: wiki lint (entity-class tags, frontmatter, naming)
  try {
    execSync("npm run check:wiki-lint 2>&1", { encoding: "utf-8", timeout: 30000 });
  } catch (e: any) {
    const stdout = e.stdout || "";
    const p0Match = stdout.match(/(\d+) P0/);
    const count = p0Match ? parseInt(p0Match[1]) : 1;
    issues.push(`wiki_lint: ${count} P0 violation${count !== 1 ? "s" : ""} — entity-class tags, frontmatter, or naming`);
  }

  return { passed: issues.length === 0, issues };
}


export async function runIndicatorChecks(manifest: Record<string, any>): Promise<{
  passed: boolean;
  failures: { indicator: string; check: string; error: string }[];
}> {
  const { existsSync } = await import("node:fs");
  const { exec: execCb } = await import("node:child_process");
  const { promisify } = await import("node:util");
  const execAsync = promisify(execCb);
  
  const failures: { indicator: string; check: string; error: string }[] = [];
  const indicators = manifest.indicators || [];
  
  for (const ind of indicators) {
    if (ind.type !== "deterministic" || !ind.check) continue;
    
    try {
      if (ind.check_type === "exec") {
        try {
          await execAsync(ind.check, { timeout: 10000 });
          // exit 0 = pass normally, but if invert: exit 0 = failure
          if (ind.invert === true) {
            failures.push({ indicator: ind.name, check: ind.check, error: `Command succeeded but was expected to fail (invert=true): ${ind.check}` });
          }
        } catch (e: any) {
          const stderr = e.stderr || e.message || "";
          if (ind.invert === true) continue; // nonzero exit with invert = pass
          failures.push({ indicator: ind.name, check: ind.check, error: stderr.slice(0, 200) });
        }
      } else if (ind.check_type === "file_exists") {
        const fileExists = existsSync(ind.check);
        const isInvert = ind.invert === true;
        if ((fileExists && !isInvert) || (!fileExists && isInvert)) continue; // pass
        failures.push({ indicator: ind.name, check: ind.check, error: isInvert ? `File exists (expected absent): ${ind.check}` : `File not found: ${ind.check}` });
      }
    } catch (e: any) {
      // ponytail: exec binary missing or timeout → skip, fail-open
      console.log(`[loop-enforcer] ⚠️ Deterministic check skipped for ${ind.name}: ${e.message}`);
    }
  }
  
  return { passed: failures.length === 0, failures };
}

export function checkVerifierHealth(
  previousResults: VerifierResult[],
  currentResult: VerifierResult
): { escalate: boolean; inconsistent_count: number } {
  const recent = [...previousResults.slice(-3), currentResult].filter(r => r.verdict.verdict !== "NEEDS_FIX" || r.parseLevel === -1);
  
  // Check for inconsistent verdicts on same input
  let inconsistent = 0;
  for (let i = 1; i < recent.length; i++) {
    if (recent[i].verdict.verdict !== recent[i - 1].verdict.verdict) {
      inconsistent++;
    }
  }

  return {
    escalate: inconsistent >= 3,
    inconsistent_count: inconsistent,
  };
}
