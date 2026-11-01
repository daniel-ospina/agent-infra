import { isGitOp as cur, withoutQuotedHeredocBodies as curW } from "./extensions/review-enforcer/index";
// @ts-ignore
import { isGitOp as base } from "/tmp/rev3161-base/extensions/review-enforcer/index";

const cases: [string, string][] = [
  // required-to-be-gated shapes (A)
  ["bare push", "git push"],
  ["-C push", "git -C /wt push"],
  ["-C push quoted path", 'git -C "/wt dir" push'],
  ["--no-pager push", "git --no-pager push"],
  ["-c k=v commit", "git -c user.email=a@b commit -m x"],
  ["-C /a -C /b commit", "git -C /a -C /b commit -m x"],
  ["status && push", "git status && git push"],
  ["heredoc write-then-run", "cat > /tmp/y.sh <<'EOF'\ngit -C /wt push\nEOF\nbash /tmp/y.sh"],
  ["heredoc && run same line", "cat > /tmp/y.sh <<'EOF'\ngit -C /wt push\nEOF"],
  ["push with pipe", "git -C /wt push 2>&1 | tail -2"],
  ["--no-pager push origin main", "git --no-pager push origin main"],
  ["-c quoted value commit", 'git -c "user.name=A B" commit -am x'],
  ["--git-dir push", "git --git-dir=/wt/.git push"],
  ["--work-tree push", "git --work-tree=/wt push"],
  ["-C a --no-pager push", "git -C /a --no-pager push"],
  // 14 working-tree verbs (B): must NOT gate
  ["add file", "git add CHANGELOG.md"],
  ["add -A", "git add -A"],
  ["-C add -A", "git -C /wt add -A"],
  ["checkout -b", "git checkout -b feat/x"],
  ["switch -c", "git switch -c feat/x"],
  ["clone", "git clone https://x/y.git /tmp/y"],
  ["init -q", "git init -q"],
  ["pull --ff-only", "git pull --ff-only"],
  ["update-index --refresh", "git update-index --refresh"],
  ["reset --hard", "git reset --hard origin/main"],
  ["rebase", "git rebase origin/main"],
  ["merge local", "git merge side"],
  ["cherry-pick", "git cherry-pick abc"],
  ["revert", "git revert abc"],
  ["restore", "git restore ."],
  ["clean -fd", "git clean -fd"],
  ["rm cached", "git rm --cached x"],
  ["mv", "git mv a b"],
  ["apply patch", "git apply p.patch"],
  ["am mailbox", "git am p.mbox"],
  ["filter-branch", "git filter-branch --tree-filter x"],
  ["update-ref", "git update-ref refs/heads/x HEAD"],
  ["tag", "git tag v1"],
  ["stash", "git stash"],
  ["worktree add", "git worktree add /tmp/wt"],
  ["read: status", "git status --porcelain"],
  ["read: log", "git log --oneline -3"],
  ["read: diff", "git diff --stat"],
  ["read: fetch", "git fetch origin main"],
  ["read: rev-parse", "git rev-parse HEAD"],
  ["read: show", "git show HEAD:README.md"],
  // spellings worth attacking
  ["semicolon after verb", "git push;"],
  ["semicolon then cmd", "git push;ls"],
  ["push then newline", "git push\nls"],
  ["subshell push", "(git -C /wt push)"],
  ["sh -c push", "sh -c 'git -C /wt push'"],
  ["$('git' push)", "$('git' push)"],
  ["alias push", "git -c alias.p=push p origin main"],
  ["gitword splice g''h", "git -C /wt \"\"push"],
  ["commit-tree", "git commit-tree abc"],
  ["push via exec", "exec git -C /wt push"],
  ["! prefix", "! git -C /wt push"],
  ["pipeline push", "echo x | git -C /wt push --stdin"],
  ["for loop push", "for r in a b; do git -C /wt push $r; done"],
];

let diffs = 0;
for (const [name, cmd] of cases) {
  const c = cur(cmd);
  const b = base(cmd);
  const flag = c === b ? "  " : "≠≠";
  if (c !== b) diffs++;
  console.log(`${flag} cur=${String(c).padEnd(5)} base=${String(b).padEnd(5)} ${name.padEnd(30)} ${JSON.stringify(cmd)}`);
}
console.log(`\n${diffs} behavioural differences vs origin/main`);
