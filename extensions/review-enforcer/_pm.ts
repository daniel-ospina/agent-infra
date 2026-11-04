import { isGitOp, maskHeredocData as M } from "./index";
const shapes: [string,string][] = [
 ["p0 double-mask", "cat > /tmp/f.md <<'EOF'\nprose\nEOF\ngit -C /wt push origin HEAD:main\ncd /tmp && cat > /tmp/g.md <<'EOF'\nprose2\nEOF"],
 ["p1 stripTabs decoy", "cat <<<'EOF' <<-'EOF'\nbody line\n\tEOF\ngit -C /wt push origin HEAD:main\nEOF"],
];
for (const [n,c] of shapes) console.log(n, "raw=", isGitOp(c), "gate=", isGitOp(M(c)));
for (const c of ['git "push" origin HEAD:main', "\\git push origin HEAD:main"]) console.log("verb", JSON.stringify(c), "raw=", isGitOp(c), "gate=", isGitOp(M(c)));
