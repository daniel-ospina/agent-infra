/**
 * shared/health.ts — extension health registry.
 *
 * Extensions call health.register("name") on successful init.
 * The health-check extension reads the registry at session start
 * and produces a startup report.
 *
 * ponytail: single shared Map, no dependencies.
 */

interface HealthEntry {
  name: string;
  loaded: boolean;
  error?: string;
  loadedAt: number;
}

const registry = new Map<string, HealthEntry>();

export function register(name: string, error?: string): void {
  registry.set(name, {
    name,
    loaded: !error,
    error,
    loadedAt: Date.now(),
  });
}

export function getReport(): { total: number; loaded: number; failed: number; extensions: HealthEntry[]; summary: string } {
  const extensions = Array.from(registry.values());
  const loaded = extensions.filter(e => e.loaded).length;
  const failed = extensions.length - loaded;

  let summary: string;
  if (failed === 0) {
    summary = `✅ ${loaded}/${extensions.length} extensions loaded`;
  } else {
    const failedNames = extensions.filter(e => !e.loaded).map(e => `${e.name}: ${e.error}`).join(", ");
    summary = `⚠️ ${loaded}/${extensions.length} extensions loaded — ${failedNames}`;
  }

  return { total: extensions.length, loaded, failed, extensions, summary };
}

// Register known extensions that didn't opt in yet — populated by health-check
export function registerExternal(name: string): void {
  if (!registry.has(name)) {
    registry.set(name, { name, loaded: true, loadedAt: Date.now() });
  }
}
