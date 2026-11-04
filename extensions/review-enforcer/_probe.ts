import * as HEAD from "./index.ts";
import * as MAIN from "./_main_index.ts";

const M = 'gh pr m"erge" 5';
const W = (m: typeof HEAD, c: string) => m.isGitOp(m.maskHeredocData(c));

const rows: Array<[string, string]> = [
  // compound opener + cp-then-run (main REFUSES to mask a compound opener; head allows the prefix)
  ["X1 compound + cp then run", `gh pr comment 1 --body-file /tmp/x.md\ncd /wt && cat > /tmp/y.md <<'EOF'\n${M}\nEOF\ncp /tmp/y.md /tmp/z && bash /tmp/z`],
  ["X2 non-compound + cp then run", `gh pr comment 1 --body-file /tmp/x.md\ncat > /tmp/y.md <<'EOF'\n${M}\nEOF\ncp /tmp/y.md /tmp/z && bash /tmp/z`],
  ["X3 compound + mv then run", `gh pr comment 1 --body-file /tmp/x.md\ncd /wt && cat > /tmp/y.md <<'EOF'\n${M}\nEOF\nmv /tmp/y.md /tmp/z; bash /tmp/z`],
  ["X4 compound + cp, target as cp arg1", `gh pr comment 1 --body-file /tmp/x.md\ncd /wt && cat > /tmp/y.md <<'EOF'\n${M}\nEOF\ncp -f /tmp/y.md /tmp/z\nbash /tmp/z`],
  ["X5 compound + link then run", `gh pr comment 1 --body-file /tmp/x.md\ncd /wt && cat > /tmp/y.md <<'EOF'\n${M}\nEOF\nln -s /tmp/y.md /tmp/z\nbash /tmp/z`],
  ["X6 compound + tar extract", `gh pr comment 1 --body-file /tmp/x.md\ncd /wt && cat > /tmp/y.md <<'EOF'\n${M}\nEOF\ncat /tmp/y.md > /tmp/z\nbash /tmp/z`],
  ["X7 compound + dd copy", `gh pr comment 1 --body-file /tmp/x.md\ncd /wt && cat > /tmp/y.md <<'EOF'\n${M}\nEOF\ndd if=/tmp/y.md of=/tmp/z 2>/dev/null\nbash /tmp/z`],
  ["X8 compound + install", `gh pr comment 1 --body-file /tmp/x.md\ncd /wt && cat > /tmp/y.md <<'EOF'\n${M}\nEOF\ninstall -m 755 /tmp/y.md /tmp/z\n/tmp/z`],
  ["X9 compound + tr", `gh pr comment 1 --body-file /tmp/x.md\ncd /wt && cat > /tmp/y.md <<'EOF'\n${M}\nEOF\ntr a b < /tmp/y.md > /tmp/z\nbash /tmp/z`],
];

console.log("fixture".padEnd(36), "HEAD  main  delta");
for (const [n, c] of rows) {
  const h = W(HEAD, c), m = W(MAIN, c);
  const d = h === m ? "" : h ? "HEAD-ONLY-GATE" : "*** HEAD-ONLY-ALLOW ***";
  console.log(n.padEnd(36), (h ? "GATE" : "allow").padEnd(5), (m ? "GATE" : "allow").padEnd(5), d);
  console.log("   head masked:", JSON.stringify(HEAD.withoutQuotedHeredocBodies(c)));
}
