import { isGitOp as curOp, maskHeredocData as curMask } from "./index";
// @ts-ignore - cross-tree import for a review probe
import { isGitOp as baseOp, maskHeredocData as baseMask } from "/tmp/ai-main-baseline/extensions/review-enforcer/index";

const shapes: [string, string][] = [
  ["written-then-run, plain git push", "cat > /tmp/y.sh <<'EOF'\ngit push\nEOF\nbash /tmp/y.sh"],
  ["written-then-run, git -C push", "cat > /tmp/y.sh <<'EOF'\ngit -C /wt push\nEOF\nbash /tmp/y.sh"],
  ["written-then-run, gh pr merge", "cat > /tmp/y.sh <<'EOF'\ngh pr merge 999\nEOF\nbash /tmp/y.sh"],
  ["written-then-run via var", "d=/tmp; f=$d/y.sh\ncat > /tmp/y.sh <<'EOF'\ngit -C /wt push\nEOF\nbash $f"],
  ["bare git -C push", "git -C /wt push"],
  ["bare git push", "git push"],
];

for (const [name, raw] of shapes) {
  const cm = curMask(raw), bm = baseMask(raw);
  console.log("== " + name);
  console.log("   cur  mask:", JSON.stringify(cm));
  console.log("   cur  isGitOp(raw)=", curOp(raw), " isGitOp(masked)=", curOp(cm));
  console.log("   base mask:", JSON.stringify(bm));
  console.log("   base isGitOp(raw)=", baseOp(raw), " isGitOp(masked)=", baseOp(bm));
}
