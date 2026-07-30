/**
 * Write-Back Contracts + Wiki Bootstrap — P1
 * 
 * Contract execution engine. File learnings to domain wiki on loop completion.
 * Creates wiki directories on first use.
 */
import { writeFileSync, readFileSync, existsSync, mkdirSync, appendFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { homedir } from "node:os";

const DOCS_DIR = process.env.AGENT_DOCS_ROOT || "/Users/home/eldato/docs";

interface WriteBackContract {
  trigger: string;
  action: "file_learnings" | "kg_fact" | "escalation_log" | "adr_update" | "adr_draft";
  target: string;
  format?: string;
  condition?: string;
}


const DOMAIN_MAP: Record<string, string> = {
  code: "04_platform",
  content: "05_growth",
  research: "05_growth",
  strategy: "01_product",
  design: "04_platform",
  product_strategy: "01_product",
  user_feedback: "01_product",
  analytics: "05_growth",
  sales: "05_growth",
  marketing: "05_growth",
};

function resolveDomain(taskType: string): string {
  return DOMAIN_MAP[taskType] || "04_platform";
}

function ensureWikiDir(domain: string): string {
  const wikiDir = join(DOCS_DIR, domain, "wiki");
  mkdirSync(wikiDir, { recursive: true });
  return wikiDir;
}

function dedupLastLine(filePath: string, content: string): boolean {
  if (!existsSync(filePath)) return false;
  const existing = readFileSync(filePath, "utf-8");
  const lastLine = existing.trimEnd().split("\n").pop() || "";
  return lastLine === content.trimEnd();
}

export function executeWriteBack(
  manifest: Record<string, any>,
  contracts: WriteBackContract[],
): { executed: string[]; pending: string[]; errors: string[] } {
  const result = { executed: [] as string[], pending: [] as string[], errors: [] as string[] };

  for (const contract of contracts) {
    if (!evaluateCondition(contract.condition, manifest)) continue;

    try {
      switch (contract.action) {
        case "file_learnings":
          executeFileLearnings(manifest, contract, result);
          break;
        case "kg_fact":
          executeKgFact(manifest, contract, result);
          break;
        case "escalation_log":
          executeEscalationLog(manifest, contract, result);
          break;
        case "adr_update":
        case "adr_draft":
          executeAdr(manifest, contract, result);
          break;
      }
    } catch (e: any) {
      result.errors.push(`${contract.action}: ${e.message}`);
    }
  }

  return result;
}

function evaluateCondition(condition: string | undefined, manifest: Record<string, any>): boolean {
  if (!condition) return true;
  const exitReason = manifest.exit_reason || "clean";
  if (condition.startsWith("exit_reason in")) {
    const values = condition.match(/\(([^)]+)\)/)?.[1]?.split(",").map(s => s.trim().replace(/"/g, "")) || [];
    return values.includes(exitReason);
  }
  if (condition.startsWith("exit_reason !=")) {
    const val = condition.split("!=")[1]?.trim().replace(/"/g, "");
    return exitReason !== val;
  }
  if (condition.startsWith("loop_level >=")) {
    const vLevel = manifest.verification_level || "V1";
    const required = parseInt(condition.match(/\d+/)?.[0] || "1");
    const current = parseInt((vLevel as string).replace("V", ""));
    return current >= required;
  }
  if (condition.startsWith("loop_level ==")) {
    const vLevel = manifest.verification_level || "V1";
    const required = parseInt(condition.match(/\d+/)?.[0] || "1");
    const current = parseInt((vLevel as string).replace("V", ""));
    return current === required;
  }
  return false;
}

function executeFileLearnings(manifest: Record<string, any>, contract: WriteBackContract, result: any): void {
  const taskType = manifest.task_type || "code";
  const domain = resolveDomain(taskType);
  const wikiDir = ensureWikiDir(domain);
  const targetFile = join(wikiDir, "gotchas.md");
  const learning = `${manifest.task_type || "unknown"}: loop ${manifest.loop_id} completed with exit_reason=${manifest.exit_reason}`;
  
  if (dedupLastLine(targetFile, learning)) {
    result.executed.push(`file_learnings: skipped (duplicate)`);
    return;
  }
  
  appendFileSync(targetFile, learning + "\n", "utf-8");
  result.executed.push(`file_learnings: wrote to ${targetFile}`);
}

function executeKgFact(manifest: Record<string, any>, contract: WriteBackContract, result: any): void {
  // Queue to manifest for KG retry (KG facts written on next session_start)
  if (!manifest.pending_kg_facts) manifest.pending_kg_facts = [];
  manifest.pending_kg_facts.push({
    subject: manifest.loop_id,
    predicate: "verdict",
    object: manifest.exit_reason || "unknown",
    valid_from: new Date().toISOString(),
  });
  result.executed.push(`kg_fact: queued ${manifest.pending_kg_facts.length} pending KG facts`);
}

function executeEscalationLog(manifest: Record<string, any>, contract: WriteBackContract, result: any): void {
  if (!manifest.pending_kg_facts) manifest.pending_kg_facts = [];
  manifest.pending_kg_facts.push({
    subject: manifest.loop_id,
    predicate: "stalled",
    object: `cycle=${manifest.cycles?.length || 0}, exit_reason=${manifest.exit_reason}`,
    valid_from: new Date().toISOString(),
  });
  result.executed.push(`escalation_log: recorded stall event`);
}

function executeAdr(manifest: Record<string, any>, contract: WriteBackContract, result: any): void {
  const isDraft = contract.action === "adr_draft";
  const targetDir = isDraft
    ? join(DOCS_DIR, "08_architecture-decisions", "drafts")
    : join(DOCS_DIR, "08_architecture-decisions");
  
  mkdirSync(targetDir, { recursive: true });
  const adrFile = join(targetDir, `${manifest.loop_id}.md`);
  const content = `# ADR: ${manifest.goal || manifest.loop_id}\n\n**Status:** ${isDraft ? "Draft" : "Accepted"}\n**Loop:** ${manifest.loop_id}\n**Date:** ${new Date().toISOString()}\n\n## Decision\n\n[Generated from loop ${manifest.loop_id}]\n`;
  writeFileSync(adrFile, content, "utf-8");
  result.executed.push(`${contract.action}: wrote to ${adrFile}`);
}

export function retryPendingKgFacts(manifest: Record<string, any>): number {
  if (!manifest.pending_kg_facts || manifest.pending_kg_facts.length === 0) return 0;
  // In P1, KG facts are queued for manual or P2+ automated retry
  // Surface to human: "N pending KG facts need write"
  return manifest.pending_kg_facts.length;
}
