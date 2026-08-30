#!/usr/bin/env bash
# check-vendor-drift.sh — verify the vendored swarm artifacts match the ledger.
#   default:  live drift vs $SWARM_ROOT (default $HOME/swarm) at the pinned base rev
#   --manifest: verify current files match the manifest — identical@base files
#               must equal their recorded sha256, and every patched file must
#               reverse-apply its ledger patch back to the swarm base byte-for-byte
# Exit 0 = in sync | 1 = drift | 2 = config error.
set -uo pipefail

SWARM_ROOT="${SWARM_ROOT:-$HOME/swarm}"
MANIFEST="${MANIFEST:-scripts/.vendor-manifest.json}"
export SWARM_ROOT MANIFEST

[ -d "$SWARM_ROOT/.git" ] || { echo "check-vendor-drift.sh: SWARM_ROOT '$SWARM_ROOT' is not a git repo (set SWARM_ROOT)" >&2; exit 2; }
[ -f "$MANIFEST" ] || { echo "check-vendor-drift.sh: manifest '$MANIFEST' not found" >&2; exit 2; }

python3 - "$@" <<'PY'
import hashlib, json, os, subprocess, sys, tempfile

def sha256(b):
    return hashlib.sha256(b).hexdigest()

def swarm_file(swarm, swarm_path, rev):
    r = subprocess.run(["git", "-C", swarm, "show", f"{rev}:{swarm_path}"],
                       capture_output=True)
    if r.returncode != 0:
        return None
    return r.stdout

swarm = os.environ["SWARM_ROOT"]
manifest = json.load(open(os.environ["MANIFEST"]))
base_rev = manifest["base_rev"]
repo_root = subprocess.run(["git", "rev-parse", "--show-toplevel"],
                           capture_output=True, text=True).stdout.strip()

# vendored file -> swarm path at the base rev
SWARM_PATHS = {
    "scripts/checkout_guard.sh": "operations/coordination/checkout_guard.sh",
    "scripts/parallel_work_check.sh": "operations/coordination/parallel_work_check.sh",
    "scripts/parallel_work_check.py": "operations/coordination/parallel_work_check.py",
    "scripts/test_parallel_work_check.py": "operations/coordination/test_parallel_work_check.py",
    "scripts/fake_supabase.py": "tests/fake_supabase.py",
    "connectors/__init__.py": "connectors/__init__.py",
    "connectors/supabase_swarm.py": "connectors/supabase_swarm.py",
    "connectors/supabase_org.py": "connectors/supabase_org.py",
    "connectors/hosted_tortoise.py": "connectors/hosted_tortoise.py",
}

mode = sys.argv[1] if len(sys.argv) > 1 else "live"
fails = 0

for rel, meta in manifest["files"].items():
    local = os.path.join(repo_root, rel)
    swarm_path = SWARM_PATHS.get(rel)
    if swarm_path is None:
        print(f"DRIFT: {rel} — no swarm path mapping in check-vendor-drift.sh")
        fails += 1
        continue
    base = swarm_file(swarm, swarm_path, base_rev)
    if base is None:
        print(f"DRIFT: {rel} — swarm {base_rev} has no {swarm_path}")
        fails += 1
        continue
    cur = open(local, "rb").read()

    if mode == "live":
        if cur != base:
            n = sum(1 for l in base.decode(errors="replace").splitlines()
                    if l not in cur.decode(errors="replace").splitlines())
            print(f"DRIFT: {rel} — differs from swarm @ {base_rev} ({n} base lines missing)")
            fails += 1
        else:
            print(f"OK: {rel}")
        continue

    # --manifest mode
    if meta.get("identical@base"):
        if sha256(cur) != meta["base_sha256"] or cur != base:
            print(f"DRIFT: {rel} — identical@base file changed without a ledger patch")
            fails += 1
        else:
            print(f"OK: {rel}")
    else:
        patch = os.path.join(repo_root, meta["patch"])
        with tempfile.TemporaryDirectory() as td:
            os.makedirs(os.path.join(td, "scripts"), exist_ok=True)
            tmp = os.path.join(td, "scripts", os.path.basename(rel))
            open(tmp, "wb").write(cur)
            r = subprocess.run(["patch", "-R", "-p1", "-d", td, "-i", patch],
                               capture_output=True)
            if r.returncode != 0:
                print(f"DRIFT: {rel} — ledger patch no longer reverse-applies "
                      f"({r.stderr.decode(errors='replace').strip()[:100]})")
                fails += 1
            elif open(tmp, "rb").read() != base:
                print(f"DRIFT: {rel} — patch-reverted file != swarm base @ {base_rev}")
                fails += 1
            else:
                print(f"OK: {rel}")

sys.exit(1 if fails else 0)
PY
