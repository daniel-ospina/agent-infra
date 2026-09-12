// #708 — the entry-point guard silently no-ops through a symlinked path.
//
// The replaced idiom
//   process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url
// is symlink-SENSITIVE: `pathToFileURL` does no filesystem resolution, while
// Node's ESM loader realpaths `import.meta.url`. Any symlinked component of the
// invocation path made the two sides differ, the `if (isMain)` body never ran,
// and a fail-CLOSED gate printed NOTHING and exited 0 — byte-identical to a
// clean run. macOS (`mktemp -d` is under `/var` → `/private/var`) and every
// bootstrapped consumer repo (whose `scripts/` is a symlink into agent-infra,
// #387) hit this routinely.
//
// POSITIVE CONTROL, not just a helper unit test (issue #708, open decision 3):
// a helper-only unit test would NOT have caught this bug. Part B therefore
// spawns the REAL gates (scripts/check-skill-lint.mjs — the #254 fail-closed
// frontmatter gate — and scripts/load-gate.mjs) through a symlinked path and
// asserts they still run, comparing against the realpath control.
//
// Suites are discovered by the `extensions/*/test*.mjs` glob (ci-main.yml) and
// run per-PR by the ci.yml `verify` job. Plain `node`, zero deps.
//
// Run: node extensions/shared/test-is-main.mjs  (from any agent-infra checkout)

import { spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync, symlinkSync, rmSync } from 'node:fs';
import { readFileSync, readdirSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve, dirname, relative, basename } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import {
  classifyEntry,
  isMain,
  isVirtualEntryPath,
  realpathOrNull,
  selfPathFromUrl,
  ENTRY,
  IMPORTED,
  UNRESOLVED,
  WARN_PREFIX,
} from '../../scripts/is-main.mjs';

const PROJECT_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const HELPER = join(PROJECT_ROOT, 'scripts', 'is-main.mjs');
const SKILL_LINT = join(PROJECT_ROOT, 'scripts', 'check-skill-lint.mjs');
const LOAD_GATE = join(PROJECT_ROOT, 'scripts', 'load-gate.mjs');

let pass = 0;
let fail = 0;
function check(name, cond, detail = '') {
  console.log(`${cond ? '✅' : '❌'} ${name}${cond || !detail ? '' : ` — ${detail}`}`);
  cond ? pass++ : fail++;
}

const TMP_DIRS = [];
function tmpDir(name) {
  const dir = mkdtempSync(join(tmpdir(), `is-main-${name}-`));
  TMP_DIRS.push(dir);
  return dir;
}

function node(args, opts = {}) {
  const r = spawnSync(process.execPath, args, { encoding: 'utf8', ...opts });
  return { status: r.status, stdout: r.stdout ?? '', stderr: r.stderr ?? '' };
}

/** Capture process.stderr.write while `fn` runs. */
function captureStderr(fn) {
  const real = process.stderr.write;
  let out = '';
  process.stderr.write = (chunk) => {
    out += typeof chunk === 'string' ? chunk : String(chunk);
    return true;
  };
  try {
    fn();
  } finally {
    process.stderr.write = real;
  }
  return out;
}

const COUNT_LINE = /^(\d+) SKILL\.md files checked\. (\d+) issue\(s\)\.$/m;
const countOf = (stdout) => {
  const m = COUNT_LINE.exec(stdout);
  return m ? `${m[1]}|${m[2]}` : null;
};

// ═══════════════════════════════════════════════════════════════════════════
// PART A — classifyEntry: the symlink-insensitive decision table
// ═══════════════════════════════════════════════════════════════════════════
console.log('── Part A — classifyEntry / isMain (decision table) ──');

// A1 — literal match (the common, non-symlinked case).
{
  const info = classifyEntry(pathToFileURL(HELPER).href, HELPER);
  check('A1 literal argv[1] → ENTRY', info.verdict === ENTRY, JSON.stringify(info));
}

// A2 — symlinked ANCESTOR (macOS /var, CI workspaces, scratch trees).
{
  const tmp = tmpDir('ancestor');
  const link = join(tmp, 'link-to-scripts');
  symlinkSync(join(PROJECT_ROOT, 'scripts'), link, 'dir');
  const argv1 = join(link, 'is-main.mjs');
  const metaUrl = pathToFileURL(HELPER).href;
  const info = classifyEntry(metaUrl, argv1);
  check('A2 symlinked ancestor → ENTRY', info.verdict === ENTRY, JSON.stringify(info));
  // The bug, stated as an assertion: the replaced idiom says "not main" here.
  check(
    'A2-old the replaced pathToFileURL idiom returns FALSE for the symlinked path (the bug)',
    pathToFileURL(argv1).href !== metaUrl,
    'fixture would not exercise the symlink if these matched',
  );
}

// A3 — symlinked LEAF file (basename differs; only realpath catches it).
{
  const tmp = tmpDir('leaf');
  const link = join(tmp, 'is-main-link.mjs');
  symlinkSync(HELPER, link);
  const info = classifyEntry(pathToFileURL(HELPER).href, link);
  check('A3 symlinked leaf file → ENTRY', info.verdict === ENTRY, JSON.stringify(info));
}

// A4 — relative argv[1] resolves to the same file.
{
  const rel = relative(process.cwd(), HELPER);
  const info = classifyEntry(pathToFileURL(HELPER).href, rel);
  check('A4 relative argv[1] → ENTRY', info.verdict === ENTRY, JSON.stringify(info));
}

// A5 — a provably DIFFERENT file is the only quiet `false`.
{
  const info = classifyEntry(pathToFileURL(HELPER).href, join(PROJECT_ROOT, 'package.json'));
  check('A5 different existing file → IMPORTED', info.verdict === IMPORTED, JSON.stringify(info));
}

// A6 — no argv[1] at all: REPL / `node -e` / plain import. The `argv1`
// parameter DEFAULTS to `process.argv[1]`, so the branch is only reachable when
// that is absent — which is what the test process must simulate (review cycle 1:
// passing an explicit `undefined` while argv[1] is set exercises the default,
// not this branch, so the previous form of this case was vacuous).
{
  const saved = process.argv[1];
  try {
    process.argv[1] = undefined;
    for (const argv1 of [undefined, null, '']) {
      const info = classifyEntry(pathToFileURL(HELPER).href, argv1);
      check(
        `A6 argv[1]=${JSON.stringify(argv1)} → IMPORTED`,
        info.verdict === IMPORTED && info.reason === 'no-argv1',
        JSON.stringify(info),
      );
    }
    check('A6b the no-argv1 branch is the one exercised (not the default)', isMain(pathToFileURL(HELPER).href) === false);
  } finally {
    process.argv[1] = saved;
  }
  // With argv[1] SET, an omitted/undefined `argv1` argument follows the default
  // (documented) — it is not the no-argv1 branch.
  const info = classifyEntry(pathToFileURL(HELPER).href, undefined);
  check(
    'A6c explicit `undefined` argv1 follows the process.argv[1] default (documented)',
    info.reason !== 'no-argv1',
    JSON.stringify(info),
  );
}

// A7 — vanished leaf: realpath on both sides fails, but the symlinked ANCESTOR
// still resolves → dirname-realpath + basename (#675 P2-f's fallback chain).
{
  const tmp = tmpDir('vanish');
  const real = join(tmp, 'real');
  mkdirSync(real);
  symlinkSync(real, join(tmp, 'link'), 'dir');
  const ghost = 'ghost-entry.mjs'; // never created
  const metaUrl = pathToFileURL(join(real, ghost)).href;
  const info = classifyEntry(metaUrl, join(tmp, 'link', ghost));
  check('A7 vanished leaf + symlinked ancestor → ENTRY(dirname-realpath)', info.verdict === ENTRY, JSON.stringify(info));
  check(
    'A7 self leaf is genuinely unresolvable (the fixture is real)',
    realpathOrNull(join(real, ghost)) === null,
  );
}

// A8 — THE DESTROYED SYMLINKED LEAF. Review cycle 3 refuted the previous
// fixture here (`dirname-differ` → a quiet `IMPORTED`), exactly as cycle 2's
// `argv1-unresolvable-different` was refuted before it. `realpath(dirname(
// argv[1]))` reports the SYMLINK's own parent, not its target's, so a symlinked
// leaf whose target (this very file) was removed leaves BOTH sides unresolvable
// with DIFFERENT dirnames while still naming the same file. Answering `IMPORTED`
// there is the #708 bug: the #254 gate exits 0 with 0 bytes of output.
// A differing dirname is not proof — only an EQUAL one is (A7).
{
  const tmp = tmpDir('leaf-gone');
  const realdir = join(tmp, 'realdir');
  const otherdir = join(tmp, 'otherdir');
  mkdirSync(realdir);
  mkdirSync(otherdir);
  const realLeaf = join(realdir, 'gate.mjs');
  const linkLeaf = join(otherdir, 'gate.mjs');
  writeFileSync(realLeaf, '// fixture\n');
  symlinkSync(realLeaf, linkLeaf, 'file');

  // Sanity: with the target present this is a plain ENTRY via the realpath
  // compare, so the fixture really is the symlinked-leaf shape.
  const live = classifyEntry(pathToFileURL(realLeaf).href, linkLeaf);
  check('A8a live symlinked leaf → ENTRY(realpath) (the fixture is real)', live.verdict === ENTRY, JSON.stringify(live));

  rmSync(realLeaf, { force: true }); // dangling route: target removed after load
  check(
    'A8b fixture is genuinely destroyed (both sides unresolvable, dirs differ)',
    realpathOrNull(realLeaf) === null &&
      realpathOrNull(linkLeaf) === null &&
      realpathOrNull(dirname(realLeaf)) !== realpathOrNull(dirname(linkLeaf)),
  );
  const info = classifyEntry(pathToFileURL(realLeaf).href, linkLeaf);
  check(
    'A8c destroyed symlinked leaf → UNRESOLVED (NOT IMPORTED via dirname differences)',
    info.verdict === UNRESOLVED && info.reason === 'unresolvable-ambiguous',
    JSON.stringify(info),
  );
  let warn = '';
  let verdict;
  warn = captureStderr(() => {
    verdict = isMain(pathToFileURL(realLeaf).href, linkLeaf);
  });
  check(
    'A8d destroyed symlinked leaf FAILS CLOSED: isMain → true + loud',
    verdict === true && warn.includes(WARN_PREFIX) && warn.includes('FAIL-CLOSED'),
    JSON.stringify({ verdict, warn }),
  );

  // The ghost-file variant (nothing ever existed, different dirs, same basename).
  const ga = join(tmp, 'ghost-a');
  const gb = join(tmp, 'ghost-b');
  mkdirSync(ga);
  mkdirSync(gb);
  const ghost = classifyEntry(pathToFileURL(join(ga, 'ghost.mjs')).href, join(gb, 'ghost.mjs'));
  check(
    'A8e vanished leaf in another dir → UNRESOLVED (differing dirname is not proof)',
    ghost.verdict === UNRESOLVED,
    JSON.stringify(ghost),
  );
}

// A9 — UNRESOLVED leaves: cannot prove either way → never a silent false.
{
  const info = classifyEntry(
    pathToFileURL('/nonexistent-self-dir-708/ghost.mjs').href,
    '/nonexistent-argv-dir-708/ghost.mjs',
  );
  check('A9 unresolvable both sides, same basename → UNRESOLVED', info.verdict === UNRESOLVED, JSON.stringify(info));

  const info2 = classifyEntry(
    pathToFileURL('/nonexistent-self-dir-708/ghost.mjs').href,
    '/nonexistent-argv-dir-708/other.mjs',
  );
  check('A9b unresolvable, different basename → UNRESOLVED', info2.verdict === UNRESOLVED, JSON.stringify(info2));
}

// A9c — THE DESTROYED-ROUTE REGRESSION (review cycle 2 refuted the previous
// fixture here). `self` resolving while `argv[1]` does not is NOT a proof that
// the paths differ: `realpathSync` throws for a DANGLING route exactly as it does
// for a path that never named this file. So a non-virtual unresolvable `argv[1]`
// must be UNRESOLVED (loud) — never a quiet `IMPORTED`, which would make a gate
// exit 0 with no output (the #708 bug).
{
  const info = classifyEntry(pathToFileURL(HELPER).href, '/nonexistent-argv-dir-708/other.mjs');
  check(
    'A9c self resolves + non-virtual unresolvable argv[1] → UNRESOLVED (not a quiet IMPORTED)',
    info.verdict === UNRESOLVED && info.reason === 'unresolvable-ambiguous',
    JSON.stringify(info),
  );
  let warn = '';
  let verdict;
  warn = captureStderr(() => {
    verdict = isMain(pathToFileURL(HELPER).href, '/nonexistent-argv-dir-708/other.mjs');
  });
  check(
    'A9c-b isMain → true + LOUD (the destroyed route FAILS CLOSED, visibly)',
    verdict === true && warn.includes(WARN_PREFIX) && warn.includes('FAIL-CLOSED'),
    JSON.stringify({ verdict, warn }),
  );

  // The ONLY quiet answer for an unresolvable entry: the repo's own virtual-entry
  // marker (a bun-compiled pi's `/$bunfs/root/…`, extensions/builtin-tools/index.ts:161).
  const bun = classifyEntry(pathToFileURL(HELPER).href, '/$bunfs/root/pi.ts');
  check('A9d bun virtual entry (/$bunfs/root/pi.ts) → IMPORTED, quiet', bun.verdict === IMPORTED && bun.reason === 'virtual-entry', JSON.stringify(bun));
  let bunWarn = '';
  let bunVerdict;
  bunWarn = captureStderr(() => {
    bunVerdict = isMain(pathToFileURL(HELPER).href, '/$bunfs/root/pi.ts');
  });
  check('A9d-b virtual entry is quiet (no per-session noise under bun pi)', bunVerdict === false && bunWarn === '', JSON.stringify({ bunVerdict, bunWarn }));

  // The marker is deliberately NARROW (review cycle 3: a broader `/$bunfs/`
  // prefix is satisfiable by a REAL path — a root-level `$bunfs` dir in a
  // root-owned container/CI — which would be a silent no-op), and it is paired
  // with a non-existence check in `classifyEntry`.
  check(
    'A9d-c virtual marker is exactly /$bunfs/root/ (never a broader prefix)',
    isVirtualEntryPath('/$bunfs/root/pi.ts') === true &&
      isVirtualEntryPath('/$bunfs/other/pi.ts') === false &&
      isVirtualEntryPath('/$bunfs/pi.ts') === false &&
      isVirtualEntryPath('/$BUNFS/root/pi.ts') === false &&
      isVirtualEntryPath('/$bunfsroot/pi.ts') === false,
    JSON.stringify({
      root: isVirtualEntryPath('/$bunfs/root/pi.ts'),
      other: isVirtualEntryPath('/$bunfs/other/pi.ts'),
    }),
  );
  // The existence half cannot be exercised here (it needs a root-level `$bunfs`
  // directory), so it is pinned statically — C6e does the same for the shipped
  // copy in provider-failover.ts.
  check(
    'A9d-d the canonical classifier requires BOTH the marker AND non-existence',
    /isVirtualEntryPath\(entry\)\s*&&\s*realpathOrNull\(entry\)\s*===\s*null/.test(
      stripComments(readFileSync(HELPER, 'utf8')),
    ),
  );
}

// A9e — the destroyed route, for real: a symlinked ANCESTOR that names this very
// module is removed after load, so `import.meta.url` still resolves while
// `argv[1]` does not — the exact shape review cycle 1 measured against the real
// gate (silent exit 0). It must be UNRESOLVED → loud + run.
{
  const tmp = tmpDir('destroyed-route');
  const tmp2 = tmpDir('destroyed-route-2');
  const real = join(tmp, 'real');
  mkdirSync(real);
  const link = join(tmp, 'link');
  symlinkSync(real, link, 'dir');
  // A copy of the helper beside a symlinked ROUTE whose basename matches.
  const selfCopy = join(real, 'is-main.mjs');
  writeFileSync(selfCopy, readFileSync(HELPER, 'utf8'));
  const argv1 = join(link, 'is-main.mjs');
  const metaUrl = pathToFileURL(selfCopy).href;
  check('A9e fixture: the route resolves before it is destroyed', classifyEntry(metaUrl, argv1).verdict === ENTRY);
  rmSync(link, { force: true }); // destroy the route, keep the file
  check('A9e fixture: the file still resolves, the route does not', realpathOrNull(selfCopy) !== null && realpathOrNull(argv1) === null);
  const info = classifyEntry(metaUrl, argv1);
  check(
    'A9e destroyed route that names THIS file → UNRESOLVED (never a silent IMPORTED)',
    info.verdict === UNRESOLVED,
    JSON.stringify(info),
  );
  let warn = '';
  let verdict;
  warn = captureStderr(() => {
    verdict = isMain(metaUrl, argv1);
  });
  check('A9e-b isMain → true + LOUD, so the no-op is not byte-identical to a clean run', verdict === true && warn.includes(WARN_PREFIX), JSON.stringify({ verdict, warn }));
  void tmp2;
}

// A10 — our OWN module root is unresolvable (`data:` URL) → UNRESOLVED.
{
  const info = classifyEntry('data:text/javascript,export default 1', '/tmp/whatever.mjs');
  check('A10 self unresolvable (non-file: URL) → UNRESOLVED', info.verdict === UNRESOLVED, JSON.stringify(info));
  check('A10b selfPathFromUrl(non-file:) is null', selfPathFromUrl('data:text/javascript,1') === null);
}

// A11 — isMain() never returns a silent false on ambiguity; it warns + runs.
{
  const ambiguousMeta = pathToFileURL('/nonexistent-self-dir-708/ghost.mjs').href;
  const ambiguousArgv = '/nonexistent-argv-dir-708/other.mjs';
  let warned = '';
  let verdict;
  warned = captureStderr(() => {
    verdict = isMain(ambiguousMeta, ambiguousArgv);
  });
  check('A11 isMain(UNRESOLVED) === true (fail CLOSED, the gate runs)', verdict === true);
  check(
    'A11b isMain(UNRESOLVED) warns LOUDLY on stderr (never a silent no-op)',
    warned.includes(WARN_PREFIX) && warned.includes('FAIL-CLOSED'),
    JSON.stringify(warned),
  );

  let warn = '';
  let verdictNoWarn;
  // FRESH (reason, self, argv1) triple — the shared `warned` Set would otherwise
  // suppress the message regardless of `opts.warn`, making this assertion pass for
  // the wrong reason (review cycle 2 found exactly that in the previous version).
  const freshMeta = pathToFileURL('/nonexistent-self-dir-708b/ghost.mjs').href;
  warn = captureStderr(() => {
    verdictNoWarn = isMain(freshMeta, '/nonexistent-argv-dir-708b-other.mjs', { warn: false });
  });
  check(
    'A11c warn:false suppresses the message but NOT the fail-closed true',
    verdictNoWarn === true && warn === '',
    JSON.stringify({ verdictNoWarn, warn }),
  );
  // ... and the paired positive: the SAME fresh triple without `warn: false`
  // DOES emit, so the pair is falsifiable in both directions.
  let paired = '';
  let pairedVerdict;
  paired = captureStderr(() => {
    pairedVerdict = isMain(freshMeta, '/nonexistent-argv-dir-708b-other.mjs');
  });
  check(
    'A11c-b the same fresh triple WITHOUT warn:false emits the warning',
    pairedVerdict === true && paired.includes(WARN_PREFIX),
    JSON.stringify({ pairedVerdict, paired }),
  );

  // self-unresolvable is also loud.
  let selfVerdict;
  const selfWarn = captureStderr(() => {
    selfVerdict = isMain('data:text/javascript,1', '/tmp/x.mjs');
  });
  check(
    'A11d isMain(self-unresolvable) === true + loud (requirement: module root unknown)',
    selfVerdict === true && selfWarn.includes(WARN_PREFIX),
    JSON.stringify(selfWarn),
  );
}

// A12 — the happy paths are QUIET (no spurious FAIL-CLOSED noise in CI logs).
{
  const entryWarn = captureStderr(() => isMain(pathToFileURL(HELPER).href, HELPER));
  const importedWarn = captureStderr(() => isMain(pathToFileURL(HELPER).href, join(PROJECT_ROOT, 'package.json')));
  check('A12 ENTRY and IMPORTED emit no warning', entryWarn === '' && importedWarn === '', JSON.stringify({ entryWarn, importedWarn }));
}

// A13 — the metaUrl default footgun (review cycle 1): `isMain()` with the
// natural one-argument call must NOT silently return false (which would disable
// the caller's gate — the #708 class). It is loud + fail-closed instead.
{
  let warn = '';
  let verdict;
  warn = captureStderr(() => {
    verdict = isMain();
  });
  check(
    'A13 isMain() with metaUrl omitted → true + LOUD (never a silent false)',
    verdict === true && warn.includes(WARN_PREFIX),
    JSON.stringify({ verdict, warn }),
  );
  check('A13b classifyEntry(undefined, ...) is UNRESOLVED', classifyEntry(undefined, '/tmp/x.mjs').verdict === UNRESOLVED);
}

// ═══════════════════════════════════════════════════════════════════════════
// PART B — the REAL fail-closed gate through symlinked invocation paths
// ═══════════════════════════════════════════════════════════════════════════
console.log('── Part B — end-to-end positive control (real gates, symlinked paths) ──');

const fixture = tmpDir('e2e');
const real = join(fixture, 'real');
const link = join(fixture, 'link');
mkdirSync(real);
// A SYMLINKED scripts/ dir — exactly the shape every bootstrapped consumer repo
// has (#387), and exactly what defeated the old idiom.
symlinkSync(join(PROJECT_ROOT, 'scripts'), join(real, 'scripts'), 'dir');
mkdirSync(join(real, 'skills', 'bad'), { recursive: true });
writeFileSync(
  join(real, 'skills', 'bad', 'SKILL.md'),
  '---\nname: bad\ndescription: Build skills: with care\n---\n\nBody.\n',
);
// A SYMLINKED ancestor on top of that.
symlinkSync(real, link, 'dir');

const control = node([SKILL_LINT, '--skills-dir', join(real, 'skills')]);
const viaAncestor = node([join(real, 'scripts', 'check-skill-lint.mjs'), '--skills-dir', join(real, 'skills')]);
const viaLink = node([join(link, 'scripts', 'check-skill-lint.mjs'), '--skills-dir', join(link, 'skills')]);

check(
  'B1 control (realpath) — the #254 gate RUNS and finds the planted P0',
  control.status === 1 && countOf(control.stdout) !== null && control.stdout.includes('[P0]'),
  `status=${control.status} stdout=${JSON.stringify(control.stdout.slice(0, 200))}`,
);
check(
  'B2 symlinked path (script reached through a symlinked scripts/ dir) — exit 1, NOT a silent 0',
  viaAncestor.status === 1,
  `status=${viaAncestor.status} stdout=${JSON.stringify(viaAncestor.stdout)} stderr=${JSON.stringify(viaAncestor.stderr)}`,
);
check(
  'B2b symlinked path — same `N files checked. M issue(s).` line as the control',
  countOf(viaAncestor.stdout) !== null && countOf(viaAncestor.stdout) === countOf(control.stdout),
  `control=${countOf(control.stdout)} symlinked=${countOf(viaAncestor.stdout)}`,
);
check(
  'B3 symlinked ancestor (link → real) — exit 1, NOT a silent 0',
  viaLink.status === 1,
  `status=${viaLink.status} stdout=${JSON.stringify(viaLink.stdout)} stderr=${JSON.stringify(viaLink.stderr)}`,
);
check(
  'B3b symlinked ancestor — same count line as the control, and the P0 is reported',
  countOf(viaLink.stdout) === countOf(control.stdout) && viaLink.stdout.includes('[P0]'),
  `control=${countOf(control.stdout)} symlinked=${countOf(viaLink.stdout)}`,
);
check(
  'B4 symlinked runs resolved DEFINITIVELY — no [is-main] FAIL-CLOSED fallback was needed',
  !viaAncestor.stderr.includes(WARN_PREFIX) && !viaLink.stderr.includes(WARN_PREFIX),
  JSON.stringify({ ancestor: viaAncestor.stderr, link: viaLink.stderr }),
);

// load-gate: before the fix a symlinked invocation printed NOTHING and exited 0,
// which reads as "load is fine, go" — a fail-open on the batch scheduler.
{
  const gated = node([join(link, 'scripts', 'load-gate.mjs'), 'check', '--json', '--force']);
  let parsed = null;
  try {
    parsed = JSON.parse(gated.stdout);
  } catch {
    parsed = null;
  }
  check(
    'B5 load-gate through a symlinked path emits a verdict instead of silence',
    gated.status === 0 && parsed !== null && parsed.verdict === 'go',
    `status=${gated.status} stdout=${JSON.stringify(gated.stdout)} stderr=${JSON.stringify(gated.stderr)}`,
  );
}

// Negative control: `IMPORTED` must stay quiet, so the fix does not turn every
// import of a gate module into a run of that gate.
{
  const imported = node([
    '--input-type=module',
    '-e',
    `await import(${JSON.stringify(pathToFileURL(SKILL_LINT).href)});`,
  ]);
  check(
    'B6 negative control — importing the gate module does NOT run it (quiet exit 0)',
    imported.status === 0 && imported.stdout === '' && imported.stderr === '',
    `status=${imported.status} stdout=${JSON.stringify(imported.stdout)} stderr=${JSON.stringify(imported.stderr)}`,
  );
}

// B6b — the shape that made cycle 1's direction wrong: an in-process IMPORT with
// an unresolvable `argv[1]`. For a RECOGNIZED virtual entry (a bun-compiled pi,
// `/$bunfs/root/…`) it must stay quiet and must NOT run the gate, or every such
// session gets a lint/usage spew. A NON-virtual unresolvable `argv[1]` is the
// destroyed-route case, which B7 pins as loud + running.
{
  const tmp = tmpDir('virtual-importer');
  const importer = join(tmp, 'importer.mjs');
  writeFileSync(
    importer,
    [
      `process.argv[1] = '/$bunfs/root/pi.ts';`,
      `await import(${JSON.stringify(pathToFileURL(SKILL_LINT).href)});`,
      `console.log('IMPORT-SURVIVED');`,
    ].join('\n'),
  );
  const virtualImport = node([importer]);
  check(
    'B6b bun-virtual entry import — gate does NOT run, quiet, importer survives',
    virtualImport.status === 0 && virtualImport.stdout.trim() === 'IMPORT-SURVIVED' && virtualImport.stderr === '',
    `status=${virtualImport.status} stdout=${JSON.stringify(virtualImport.stdout)} stderr=${JSON.stringify(virtualImport.stderr)}`,
  );
}

// B7 — the DESTROYED ROUTE at the process level (review cycle 2's P0, on the
// REAL gate). A driver invoked through a symlinked route deletes that route and
// only then imports the #254 gate, so at guard time `process.argv[1]` names a
// path that no longer resolves while the gate's `import.meta.url` does. An
// earlier revision read that as "a different file" and the gate exited 0 with 0
// bytes of stdout — byte-identical to a clean run. It must now RUN, loudly.
{
  const tmp = tmpDir('destroyed-route-e2e');
  const b7real = join(tmp, 'real');
  const route = join(tmp, 'route');
  mkdirSync(b7real);
  symlinkSync(b7real, route, 'dir');
  const driver = join(b7real, 'driver.mjs');
  writeFileSync(
    driver,
    [
      `import fs from 'node:fs';`,
      `const gate = ${JSON.stringify(pathToFileURL(SKILL_LINT).href)};`,
      // argv[1] is this driver, reached through the route: delete the route, then
      // hand over to the gate, whose guard sees an unresolvable argv[1].
      `fs.rmSync(${JSON.stringify(route)}, { recursive: true, force: true });`,
      `await import(gate);`,
      `console.log('DRIVER-SURVIVED');`,
    ].join('\n'),
  );
  // Point at the Part B fixture (planted P0) — its tree is NOT the route being deleted.
  const destroyed = node([join(route, 'driver.mjs'), '--skills-dir', join(real, 'skills')]);
  check(
    'B7 destroyed invocation route — the gate RUNS (count line + P0) instead of exiting 0 silently',
    countOf(destroyed.stdout) !== null && destroyed.stdout.includes('[P0]'),
    `status=${destroyed.status} stdout=${JSON.stringify(destroyed.stdout.slice(0, 200))} stderr=${JSON.stringify(destroyed.stderr.slice(0, 200))}`,
  );
  check(
    'B7b destroyed route — the ambiguity is VISIBLE on stderr (never byte-identical to a clean run)',
    destroyed.stderr.includes(WARN_PREFIX),
    JSON.stringify(destroyed.stderr.slice(0, 300)),
  );
}

// B7c — THE DESTROYED SYMLINKED LEAF at the process level (review cycle 3's P0),
// against a guard built on the REAL canonical module. Invoked through a symlinked
// LEAF whose target is removed before the guard runs, so `import.meta.url` no
// longer resolves, `process.argv[1]` (the dangling link) never did, and the two
// dirnames differ. An earlier revision called that `IMPORTED` and stayed silent.
{
  const tmp = tmpDir('leaf-gone-e2e');
  const realdir = join(tmp, 'realdir');
  const otherdir = join(tmp, 'otherdir');
  mkdirSync(realdir);
  mkdirSync(otherdir);
  const fixture = join(realdir, 'gate.mjs');
  const route = join(otherdir, 'gate.mjs');
  writeFileSync(
    fixture,
    [
      `import fs from 'node:fs';`,
      `import { fileURLToPath } from 'node:url';`,
      `import { isMain } from ${JSON.stringify(pathToFileURL(HELPER).href)};`,
      // Remove our OWN real path before the guard runs — the invocation route was
      // a symlinked leaf, and it is now dangling (the #675 P2-f shape, leaf flavour).
      `fs.rmSync(fileURLToPath(import.meta.url), { force: true });`,
      `if (isMain(import.meta.url, process.argv[1])) { console.log('GATE-RAN'); process.exitCode = 1; }`,
      `else { console.log('GATE-SKIPPED'); }`,
    ].join('\n'),
  );
  symlinkSync(fixture, route, 'file');
  const destroyedLeaf = node([route]);
  check(
    'B7c destroyed symlinked leaf — the guard RUNS (never a silent skip)',
    destroyedLeaf.stdout.includes('GATE-RAN') && destroyedLeaf.status === 1,
    `status=${destroyedLeaf.status} stdout=${JSON.stringify(destroyedLeaf.stdout)} stderr=${JSON.stringify(destroyedLeaf.stderr)}`,
  );
  check(
    'B7d destroyed symlinked leaf — the ambiguity is VISIBLE on stderr',
    destroyedLeaf.stderr.includes(WARN_PREFIX),
    JSON.stringify(destroyedLeaf.stderr.slice(0, 300)),
  );

  // Paired positive control on the SAME shape with the target intact: the guard
  // runs via the realpath fast path and stays QUIET (the live-leaf branch).
  const tmp2 = tmpDir('leaf-live-e2e');
  const liveGateDir = join(tmp2, 'realdir');
  mkdirSync(liveGateDir);
  const liveGate = join(liveGateDir, 'gate.mjs');
  const liveRoute = join(tmp2, 'gate.mjs');
  writeFileSync(
    liveGate,
    [
      `import { isMain } from ${JSON.stringify(pathToFileURL(HELPER).href)};`,
      `if (isMain(import.meta.url, process.argv[1])) { console.log('GATE-RAN'); }`,
      `else { console.log('GATE-SKIPPED'); }`,
    ].join('\n'),
  );
  symlinkSync(liveGate, liveRoute, 'file');
  const liveLeaf = node([liveRoute]);
  check(
    'B7e live symlinked leaf — the guard RUNS and is QUIET (fast path, no warning)',
    liveLeaf.stdout.includes('GATE-RAN') && !liveLeaf.stderr.includes(WARN_PREFIX),
    `status=${liveLeaf.status} stdout=${JSON.stringify(liveLeaf.stdout)} stderr=${JSON.stringify(liveLeaf.stderr)}`,
  );
}

// ═══════════════════════════════════════════════════════════════════════════
// PART C — static tripwire: no non-realpath'd entry-point comparison
// ═══════════════════════════════════════════════════════════════════════════
// HEURISTIC on purpose, and the heuristic's blind spots are PINNED as fixtures
// (C5) rather than claimed away. It catches the two idioms that shipped (a
// pathToFileURL/`path.resolve` path compared to `import.meta.url` without a
// realpath) in both the inline and the hoisted/aliased shape; it does not model
// control flow, and it is deliberately NOT an attempt to model shell/YAML
// execution semantics — see #666 for the evidence that re-modelling that domain
// does not converge.
console.log('── Part C — static tripwire (heuristic) ──');

const SELF_REL = relative(PROJECT_ROOT, fileURLToPath(import.meta.url));
const SCAN_ROOTS = ['scripts', 'extensions', 'bin'];
const SCAN_EXT = /\.(mjs|js|cjs|ts)$/;
const SKIP_DIRS = new Set(['node_modules', '.git', '.worktrees']);

function stripComments(src) {
  return src
    .replace(/\/\*[\s\S]*?\*\//g, ' ')
    .split('\n')
    .map((l) => l.replace(/(^|\s)\/\/.*$/, '$1'))
    .join('\n');
}


// The banned family compares a path derived from the INVOCATION argument to
// `import.meta.url`. Requiring the argv-ish argument is what keeps this from
// firing on unrelated `!==`/`fileURLToPath(import.meta.url)` statements
// (e.g. `check-pi-pin-lockstep.mjs`'s env check, `test-subtract-scope.mjs`'s
// self-exclusion filter) — measured, both were false positives before.
const ARGV_RESOLVE = /(pathToFileURL|path\.resolve)\s*\(\s*(process\.argv\[1\]|process\.argv\.at\(1\)|argv1|argv|entry)\s*\)/;
const COMPARISON = /(===|!==|==|!=)/;
const HAS_REALPATH = /realpath/i;

function scanSource(rel, src) {
  const findings = [];
  const body = stripComments(src);
  for (const stmt of body.split(';')) {
    const flat = stmt.replace(/\s+/g, ' ').trim();
    if (!flat.includes('import.meta.url')) continue;
    if (!ARGV_RESOLVE.test(flat)) continue;
    if (!COMPARISON.test(flat)) continue;
    if (HAS_REALPATH.test(flat)) continue;
    findings.push({ rel, stmt: flat, pattern: 'inline' });
  }
  return findings;
}

// ── S2: the HOISTED / ALIASED shape ────────────────────────────────────────
// Review cycle 1 PROVED S1 misses the shape that was actually shipped in
// provider-failover.ts — the provenance is split across statements:
//   const self = fileURLToPath(import.meta.url);
//   const resolved = path.resolve(entry);      // entry = process.argv[1]
//   if (resolved === self) return true;
// and it also misses arbitrary argv aliases (`const e = process.argv[1]`).
// So S2 is FILE-level: it collects every identifier derived from argv[1]
// (directly or through path.resolve/pathToFileURL) and every identifier derived
// from import.meta.url, then flags a comparison between the two families in a
// file that never mentions `realpath` — the realpath compare is precisely what
// makes the comparison symlink-safe.
//
// Cycle-3 hardening, after review cycle 2 PROVED three misses: an optional
// `path.resolve(` wrapper is tolerated on both sides, `String(...)` may appear
// inside the resolve helper, and the realpath exemption is applied per
// COMPARISON (a stray `fs.realpathSync` anywhere in the file used to buy the
// whole file a pass — `const rp = fs.realpathSync;` + the shipped bug → 0
// findings).
const ARGV_ALIAS = /(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*process\.argv\[1\]/g;
const RESOLVE_OF = /(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*(?:path\.resolve\s*\(\s*)?(?:String\s*\(\s*)?(?:pathToFileURL|path\.resolve)\s*\(\s*(?:String\s*\(\s*)?(process\.argv\[1\]|process\.argv\.at\(1\)|[A-Za-z_$][\w$]*)\s*\)?/g;
const SELF_ALIAS = /(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*(?:path\.resolve\s*\(\s*)?(?:pathToFileURL\s*\(\s*)?fileURLToPath\s*\(\s*import\.meta\.url\s*\)/g;
const ARGVISH = new Set(['process.argv[1]', 'argv1', 'argv', 'entry']);
const ARGV_NODERE = /process\.argv\[1\]|argv1|\barg\b|\bentry\b/;

function scanFileHoisted(rel, src) {
  const body = stripComments(src);
  if (!body.includes('import.meta.url')) return [];

  const argvNames = new Set();
  for (const m of body.matchAll(ARGV_ALIAS)) argvNames.add(m[1]);
  // Iterate: a resolve of an argv alias is itself argv-derived.
  for (let pass = 0; pass < 4; pass++) {
    let grew = false;
    for (const m of body.matchAll(RESOLVE_OF)) {
      const [name, arg] = [m[1], m[2]];
      if ((ARGVISH.has(arg) || argvNames.has(arg)) && !argvNames.has(name)) {
        argvNames.add(name);
        grew = true;
      }
    }
    if (!grew) break;
  }
  const selfNames = new Set();
  for (const m of body.matchAll(SELF_ALIAS)) selfNames.add(m[1]);
  if (argvNames.size === 0) return [];

  const ARGV_NAME = new RegExp(
    `\\b(?:${[...ARGVISH].map((s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('|')}|${[...argvNames].join('|')})\\b`,
  );
  const SELF_NAME = new RegExp(`(?:import\\.meta\\.url|\\b(?:${[...selfNames].join('|') || '\u0001'})\\b)`);

  // The realpath exemption is per FILE but must involve an argv-derived name —
  // review cycle 2 showed a stray `fs.realpathSync` anywhere in the file bought
  // the WHOLE file a pass (`const rp = fs.realpathSync;` + the shipped bug → 0
  // findings), while a per-STATEMENT rule false-positives on the idiomatic
  // literal fast path (`if (resolved === self) return true;`) that every real
  // guard has next to its realpath compare. So: exempt only when some statement
  // realpaths an argv-derived path.
  const hasRealpathOnArgv = body
    .split(';')
    .some((s) => HAS_REALPATH.test(s) && (ARGV_NODERE.test(s) || ARGV_NAME.test(s)));
  if (hasRealpathOnArgv) return [];

  for (const stmt of body.split(';')) {
    const flat = stmt.replace(/\s+/g, ' ').trim();
    if (!COMPARISON.test(flat)) continue;
    if (!ARGV_NODERE.test(flat) && !ARGV_NAME.test(flat)) continue;
    if (!SELF_NAME.test(flat)) continue;
    return [{ rel, stmt: flat, pattern: 'hoisted' }];
  }
  return [];
}

function walk(dir) {
  const out = [];
  let entries;
  try {
    entries = readdirSync(dir);
  } catch {
    return out;
  }
  for (const entry of entries) {
    if (SKIP_DIRS.has(entry)) continue;
    const full = join(dir, entry);
    let st;
    try {
      st = statSync(full);
    } catch {
      continue;
    }
    if (st.isDirectory()) out.push(...walk(full));
    else if (SCAN_EXT.test(entry)) out.push(full);
  }
  return out;
}

const scanned = [];
const findings = [];
for (const root of SCAN_ROOTS) {
  for (const file of walk(join(PROJECT_ROOT, root))) {
    const rel = relative(PROJECT_ROOT, file);
    if (rel === SELF_REL) continue; // this file necessarily names the banned idiom
    scanned.push(rel);
    let src;
    try {
      src = readFileSync(file, 'utf8');
    } catch {
      continue; // vanished between statSync and read — skip, do not abort the audit
    }
    findings.push(...scanSource(rel, src), ...scanFileHoisted(rel, src));
  }
}

for (const f of findings) console.log(`   ❌ ${f.rel} [${f.pattern}]: ${f.stmt.slice(0, 160)}`);
check(
  'C1 no symlink-sensitive entry-point comparison anywhere in scripts/, extensions/, bin/',
  findings.length === 0,
  `${findings.length} finding(s)`,
);
check(
  'C2 the tripwire actually scanned the repo (not a vacuous pass)',
  scanned.length > 100 && scanned.includes('scripts/check-skill-lint.mjs') && scanned.includes('extensions/shared/provider-failover.ts'),
  `scanned ${scanned.length} files`,
);
check(
  'C3 the tripwire is not a rubber stamp — it fires on the idiom it bans',
  scanSource('fixture.mjs', 'const isMain =\n  process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url;\n').length === 1 &&
    scanSource('fixture.mjs', 'const isMain = path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);\n').length === 1 &&
    scanSource('fixture.mjs', 'const isDirectEntry = path.resolve(entry) === fileURLToPath(import.meta.url);\n').length === 1,
);
check(
  'C4 the tripwire does NOT fire on the realpath forms or on unrelated comparisons',
  scanSource('fixture.mjs', 'const ok = sameRealPath(process.argv[1], fileURLToPath(import.meta.url));\n').length === 0 &&
    scanSource('fixture.mjs', 'const ok = fs.realpathSync(resolved) === fs.realpathSync(self);\n').length === 0 &&
    scanSource('fixture.mjs', 'if (process.env.X !== undefined) { const p = fileURLToPath(import.meta.url); }\n').length === 0 &&
    scanSource('fixture.mjs', '.filter((f) => f !== basename(fileURLToPath(import.meta.url)))\n').length === 0,
);

// C5 — the hoisted/aliased blind spot S1 provably had (review cycle 1). These
// are the HISTORICAL texts of the two shipped guards, so a regex regression here
// is caught rather than silently narrowing the net.
const S1_MISSES = [
  [
    'hoisted (the shape provider-failover.ts actually shipped)',
    'const self = fileURLToPath(import.meta.url);\nconst resolved = path.resolve(entry);\nif (resolved === self) return true;\n',
    'const entry = process.argv[1];\n',
  ],
  [
    'aliased argv',
    'const e = process.argv[1];\nconst p = pathToFileURL(e);\nif (p.href === import.meta.url) run();\n',
    '',
  ],
  [
    'split statement (url then compare)',
    'const u = pathToFileURL(process.argv[1]).href;\nconst isMain = u === import.meta.url;\n',
    '',
  ],
  // The three below were PROVEN misses in the cycle-2 scan (review cycle 2) and
  // are fixtures now, so the net cannot silently narrow again.
  [
    'wrapped self (path.resolve(fileURLToPath(import.meta.url)))',
    'const self = path.resolve(fileURLToPath(import.meta.url));\nconst other = path.resolve(process.argv[1]);\nif (self === other) run();\n',
    '',
  ],
  [
    'String() inside the resolve helper',
    'const u = pathToFileURL(String(process.argv[1])).href;\nconst m = u === import.meta.url;\n',
    '',
  ],
  [
    'a stray realpath elsewhere in the file must NOT exempt the file',
    'const rp = fs.realpathSync;\nconst entry = process.argv[1];\nconst resolved = path.resolve(entry);\nif (resolved === fileURLToPath(import.meta.url)) run();\n',
    '',
  ],
];
for (const [label, bad, prelude] of S1_MISSES) {
  const src = prelude + bad;
  check(
    `C5 hoisted/aliased form is caught (${label})`,
    scanFileHoisted('fixture.ts', src).length === 1,
    `scanFileHoisted found ${scanFileHoisted('fixture.ts', src).length}`,
  );
}
check(
  'C5b the FIXED shape (literal fast path + realpath compare on the argv path) is NOT flagged',
  scanFileHoisted(
    'fixture.ts',
    "const entry = process.argv[1];\nconst self = fileURLToPath(import.meta.url);\nconst resolved = path.resolve(entry);\nif (resolved === self) return true;\nreturn fs.realpathSync(resolved) === fs.realpathSync(self);\n",
  ).length === 0,
);

// C6 — the ONE site with no behavioural regression test (a plain-node `.mjs`
// suite cannot import a `.ts`) has its guard SHAPE pinned: a realpath compare
// must be present, and the CLI must never be launched on ambiguity (exactly one
// `return true`, the literal-match line). Review cycle 1 measured that a
// `return true` in this block wipes the exhaustion latch.
{
  const pf = readFileSync(join(PROJECT_ROOT, 'extensions/shared/provider-failover.ts'), 'utf8');
  const start = pf.indexOf('const isDirectEntry');
  const block = start === -1 ? '' : pf.slice(start, pf.indexOf('})();', start) + 5);
  check('C6 provider-failover.ts guard found', block.length > 0);
  check(
    'C6b the guard compares realpaths (symlink-insensitive)',
    /fs\.realpathSync\(resolved\)\s*===\s*fs\.realpathSync\(self\)/.test(block),
  );
  check(
    'C6c the guard NEVER launches the CLI on ambiguity (exactly one `return true`)',
    (block.match(/return true/g) || []).length === 1,
    `${(block.match(/return true/g) || []).length} occurrences`,
  );
  check('C6d no cross-layer import of scripts/ from the shipped extension', !/from\s+["'][^"']*\.\.\/\.\.\/scripts\//.test(pf));
  // C6e — the LOUD half. Tightened in review cycle 3: the first version asserted
  // only token PRESENCE, so reverting the branch to a `path.basename`-gated write
  // kept it green. It must be an UNCONDITIONAL write inside the catch, keyed on
  // the narrowed marker, with the existence half pinned.
  check(
    'C6e ambiguity branch warns UNCONDITIONALLY in the catch (no basename gate), /$bunfs/root/ + non-existence',
    block.includes("startsWith('/$bunfs/root/')") &&
      block.includes('!fs.existsSync(resolved)') &&
      /}\s*catch\s*{[^}]*process\.stderr\.write/.test(block) &&
      !/path\.basename/.test(block),
    JSON.stringify({
      marker: block.includes("startsWith('/$bunfs/root/')"),
      existsSync: block.includes('!fs.existsSync(resolved)'),
      unconditionalWrite: /}\s*catch\s*{[^}]*process\.stderr\.write/.test(block),
      basenameGate: /path\.basename/.test(block),
    }),
  );
}

// C7 — the "loudly" half of the contract: no production call site may pass a
// `warn` override (which would keep the fail-closed verdict but silence it).
{
  for (const rel of ['scripts/check-skill-lint.mjs', 'scripts/load-gate.mjs', 'scripts/probe-frontmatter-fixtures.mjs']) {
    const src = stripComments(readFileSync(join(PROJECT_ROOT, rel), 'utf8'));
    check(
      `C7 ${rel} calls isMain(import.meta.url, process.argv[1]) with no warn override`,
      /isMain\(import\.meta\.url,\s*process\.argv\[1\]\)/.test(src),
    );
  }
}

// ── Cleanup + summary ─────────────────────────────────────────────────────
// Registered on `exit` as well as at the end: a throw before the final loop
// (a symlink EPERM, ENOSPC in mkdtemp) must not leak temp trees.
let cleaned = false;
function cleanup() {
  if (cleaned) return;
  cleaned = true;
  for (const dir of TMP_DIRS) {
    try {
      rmSync(dir, { recursive: true, force: true });
    } catch {
      /* best-effort */
    }
  }
}
process.on('exit', cleanup);
cleanup();
console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail > 0 ? 1 : 0);
