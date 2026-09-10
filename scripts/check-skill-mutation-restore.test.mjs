#!/usr/bin/env node
/**
 * check-skill-mutation-restore.test.mjs — fixture suite for the #664 guard.
 *
 * Proves the guard is NON-VACUOUS (a planted violation is RED for every discard
 * form and every scanned surface) and NOT over-eager (a `cp` restore, a
 * non-mutation `git restore`, branch ops, out-of-scope files, and the
 * reason-carrying `mutation-restore-ok` pragma are all GREEN). Also asserts the
 * LIVE TREE is GREEN.
 *
 * Run: node scripts/check-skill-mutation-restore.test.mjs
 *
 * Repo-convention harness: node:assert + custom test() with ✅/❌ markers,
 * process.exit(1) on failure.
 */

import { strict as assert } from "node:assert";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const CHECKER = path.join(REPO_ROOT, "scripts", "check-skill-mutation-restore.mjs");

let passed = 0;
let failed = 0;

function test(name, fn) {
  try {
    fn();
    passed++;
    console.log(`  ✅ ${name}`);
  } catch (err) {
    failed++;
    console.error(`  ❌ ${name}\n     ${err.message.split("\n").join("\n     ")}`);
  }
}

/** Run the checker against a fixture root. */
function run(root) {
  return spawnSync(process.execPath, [CHECKER, "--root", root], { encoding: "utf8" });
}

/** Create a temp tree from {relPath: content}, run fn(root), always clean up. */
function withTree(files, fn) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "msr-664-"));
  try {
    for (const [rel, content] of Object.entries(files)) {
      const abs = path.join(root, rel);
      fs.mkdirSync(path.dirname(abs), { recursive: true });
      fs.writeFileSync(abs, content);
    }
    return fn(root);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
}

/** A fenced mutation-test block whose restore line is `discard`, empty lines trimmed. */
function mutationBlock(discard, { pragma = null, markerLine = null } = {}) {
  const lines = [
    "## Verify the guard",
    "",
    "Prove the tripwire fires by deliberately mutating the rule, then restore:",
    "",
    "```sh",
    "perl -pi -e 's/a/b/' scripts/guard.mjs",
    "node scripts/guard.test.mjs   # confirm RED",
  ];
  if (pragma) lines.push(pragma);
  lines.push(discard + (markerLine === null ? "" : `   # ${markerLine}`));
  lines.push("```");
  lines.push("");
  return lines.join("\n");
}

const OK_PRAGMA = "<!-- mutation-restore-ok: naming the forbidden form in the rule text -->";
const EMPTY_PRAGMA = "<!-- mutation-restore-ok: -->";

// ── non-vacuity: every discard form is RED ─────────────────────────────────────

test("live tree is GREEN (0 violations)", () => {
  const r = run(REPO_ROOT);
  assert.equal(r.status, 0, `live tree must be GREEN; stderr:\n${r.stderr}`);
  assert.match(r.stdout, /0 violations/);
});

test("git checkout -- <path> in a mutation context → RED", () => {
  withTree({ "AGENTS.md": mutationBlock("git checkout -- scripts/guard.mjs") }, (root) => {
    const r = run(root);
    assert.equal(r.status, 1, "must fail");
    assert.match(r.stderr, /AGENTS\.md,line=8::/, `annotation with file:line expected:\n${r.stderr}`);
    assert.match(r.stderr, /git checkout -- <path>/);
  });
});

test("git restore <path> in a mutation context → RED", () => {
  withTree({ "AGENTS.md": mutationBlock("git restore scripts/guard.mjs") }, (root) => {
    const r = run(root);
    assert.equal(r.status, 1, "must fail");
    assert.match(r.stderr, /git restore <path>/);
  });
});

test("git checkout . in a mutation context → RED", () => {
  withTree({ "AGENTS.md": mutationBlock("git checkout .") }, (root) => {
    assert.equal(run(root).status, 1, "must fail");
  });
});

test("violation inside skills/**/*.md → RED", () => {
  withTree({ "skills/x/SKILL.md": mutationBlock("git restore scripts/guard.mjs") }, (root) => {
    const r = run(root);
    assert.equal(r.status, 1, "must fail");
    assert.match(r.stderr, /skills\/x\/SKILL\.md,line=8::/);
  });
});

test("violation inside templates/AGENTS.base.md → RED", () => {
  withTree(
    { "templates/AGENTS.base.md": mutationBlock("git checkout -- scripts/guard.mjs") },
    (root) => {
      assert.equal(run(root).status, 1, "must fail");
    }
  );
});

test("mutation marker on the SAME line as the discard → RED", () => {
  withTree(
    {
      "AGENTS.md": [
        "# Notes",
        "",
        "```sh",
        "git restore scripts/guard.mjs   # negative test restore after mutation",
        "```",
        "",
      ].join("\n"),
    },
    (root) => {
      assert.equal(run(root).status, 1, "same-line marker must count as context");
    }
  );
});

test("pragma with an EMPTY reason → still RED", () => {
  withTree(
    { "AGENTS.md": mutationBlock("git checkout -- scripts/guard.mjs", { pragma: EMPTY_PRAGMA }) },
    (root) => {
      const r = run(root);
      assert.equal(r.status, 1, "an empty pragma must not silence the guard");
      assert.match(r.stderr, /empty reason/);
    }
  );
});

// ── false-positive bound: legitimate usage stays GREEN ────────────────────────

test("cp-backup restore in a mutation context → GREEN", () => {
  withTree(
    {
      "AGENTS.md": [
        "## Verify the guard",
        "",
        "Prove the tripwire fires by deliberately mutating the rule, then restore:",
        "",
        "```sh",
        "cp scripts/guard.mjs /tmp/guard.bak",
        "perl -pi -e 's/a/b/' scripts/guard.mjs",
        "node scripts/guard.test.mjs   # confirm RED",
        "cp /tmp/guard.bak scripts/guard.mjs",
        "```",
        "",
      ].join("\n"),
    },
    (root) => {
      const r = run(root);
      assert.equal(r.status, 0, `cp restore must be GREEN; stderr:\n${r.stderr}`);
    }
  );
});

test("git restore with NO mutation context → GREEN (operational prose)", () => {
  withTree(
    {
      "skills/using-git-worktrees/SKILL.md": [
        "# Worktrees",
        "",
        "The guard's M4 gate blocks `git restore .` and `git checkout` in a stranded hub.",
        "Untracked cleanup is plain `rm`.",
        "",
      ].join("\n"),
    },
    (root) => {
      assert.equal(run(root).status, 0, "the word alone must not be a violation");
    }
  );
});

test("branch ops in a mutation context → GREEN", () => {
  withTree(
    {
      "AGENTS.md": [
        "## Mutation testing notes",
        "",
        "```sh",
        "git checkout main",
        "git checkout -b probe",
        "git checkout --orphan scratch",
        "git checkout --detach",
        "```",
        "",
      ].join("\n"),
    },
    (root) => {
      assert.equal(run(root).status, 0, "branch ops are not working-tree discards");
    }
  );
});

test("reason-carrying pragma on the line ABOVE → GREEN", () => {
  withTree(
    { "AGENTS.md": mutationBlock("git checkout -- scripts/guard.mjs", { pragma: OK_PRAGMA }) },
    (root) => {
      assert.equal(run(root).status, 0, "a reasoned pragma is the auditable exception");
    }
  );
});

test("reason-carrying pragma on the SAME line → GREEN", () => {
  withTree(
    {
      "AGENTS.md": [
        "## Mutation testing notes",
        "",
        "The forbidden form is `git checkout -- <path>` " + OK_PRAGMA,
        "",
      ].join("\n"),
    },
    (root) => {
      assert.equal(run(root).status, 0, "same-line pragma is honored");
    }
  );
});

test("out-of-scope docs/ file → GREEN (scope bound)", () => {
  withTree({ "docs/plan.md": mutationBlock("git checkout -- scripts/guard.mjs") }, (root) => {
    assert.equal(run(root).status, 0, "docs/ is archival, not agent-facing instruction");
  });
});

test("non-.md file under skills/ → GREEN (scope bound)", () => {
  withTree({ "skills/x/notes.txt": mutationBlock("git checkout -- scripts/guard.mjs") }, (root) => {
    assert.equal(run(root).status, 0, "only *.md is scanned");
  });
});

test("mutation marker outside the ±3-line window / fence → GREEN", () => {
  withTree(
    {
      "AGENTS.md": [
        "Mutation testing is described somewhere far above this line.",
        "",
        "",
        "",
        "",
        "",
        "Separately, the guard block list includes `git restore .` for stranded hubs.",
        "",
      ].join("\n"),
    },
    (root) => {
      assert.equal(run(root).status, 0, "the context window must stay bounded");
    }
  );
});

// ── CLI contract ──────────────────────────────────────────────────────────────

test("unknown argument → usage error (exit 2)", () => {
  const r = spawnSync(process.execPath, [CHECKER, "--nope"], { encoding: "utf8" });
  assert.equal(r.status, 2);
});

test("missing --root dir → usage error (exit 2)", () => {
  const r = spawnSync(process.execPath, [CHECKER, "--root", path.join(os.tmpdir(), "msr-does-not-exist-664")], {
    encoding: "utf8",
  });
  assert.equal(r.status, 2);
});

test("clean tree prints a summary line (non-vacuous scan count)", () => {
  withTree({ "AGENTS.md": "# clean\n" }, (root) => {
    const r = run(root);
    assert.equal(r.status, 0);
    assert.match(r.stdout, /1 agent-facing file\(s\) scanned/);
  });
});

console.log(`\ncheck-skill-mutation-restore.test.mjs: ${passed} passed, ${failed} failed`);
if (failed > 0) {
  console.error("❌ SOME TESTS FAILED");
  process.exit(1);
}
console.log("✅ ALL TESTS PASSED");
