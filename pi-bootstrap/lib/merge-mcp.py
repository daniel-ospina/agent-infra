#!/usr/bin/env python3
"""merge-mcp.py — the ONE `.mcp.json` merge, shared by `pi-bootstrap/setup.sh` (laptop) and
`pi-bootstrap/cell-install.sh` (cell).

    merge-mcp.py <template.json> <dest.json> [--cell]

Why one implementation: the two callers used to merge inline, and they had already drifted — the
laptop merged `{**dst_servers, **src_servers}` (source wins) while the cell did too, so BOTH
silently repointed a self-hosted `tortoise` entry at the hosted endpoint on every re-sync. A
second, subtly-different merge is how a rule gets obeyed on one platform and not the other.

THE RULES, in order:

1. `exa` is dropped from the destination (owner ruling 2026-10-31: uninstalled, not configured).
   It is NOT a "local extra to carry forward" — it was a BASE server, and a source-wins merge
   leaves every already-provisioned machine still loading it. The pop IS the migration.

2. A server the destination declares that the TEMPLATE DOES NOT CARRY survives untouched — that
   is what "local extras preserved" has always meant. A server the template DOES carry is the
   template's: replacing it is how a base-config fix reaches an already-provisioned machine, and
   the `exa` removal above depends on exactly that direction. ⛔ Every such replacement is printed
   as a `NOTE:` naming the server, because a silent overwrite of a hand-customized base entry is
   indistinguishable from a merge that did nothing. `tortoise` is the ONE entry where the
   destination's version wins, and it follows rule 3.

3. `tortoise` — the graph server, and the only entry whose URL an operator is told to change
   (`templates/.mcp.base.json`'s `_comment`: self-host users point it at their own daemon):
   * the LEGACY stdio shape (a `command`) can never work on a cell and is REPLACED, silently
     correct because there is no configuration in it worth keeping;
   * a USABLE differing entry is PRESERVED and marked `_selfHosted: true`, so the caller and
     `--verify` can say out loud that this machine points somewhere other than the default instead
     of silently certifying it. Usable is URL-AWARE (`usable()`): a self-hosted daemon needs no
     key, so "no Authorization" is only a fault when the url IS the hosted endpoint. ⛔ "Differing"
     means a different AUTHORITY: a scheme-only change on the same host (`http://` for `https://`)
     is a typo, not a self-host, and is NOT preserved — marking it would hand `--verify` an
     exemption it honours while the live key crossed the wire in cleartext (`near_miss()`);
   * anything else (a hosted url with no key, a literal key, an explicit non-http transport) is
     REPLACED with the template's entry, because preserving it creates a config `--verify` must
     refuse in perpetuity — a cell no repair can fix.

4. `--cell` installs the graph server ONLY. The template's other base servers are wrong for a
   cell, not merely unnecessary: `seo-intelligence` spawns
   `${AGENT_INFRA_PATH}/mcp-servers/seo-intelligence/node_modules/.bin/tsx` and a cell ships
   `extensions/` only (manifest.json carries no `mcp-servers/`), so it cannot spawn;
   `brave-search`/`gemini` spawn without their keys; `playwright-browser` pulls an npx package
   onto a memory-constrained box. A catalog that advertises an unspawnable tool is worse than a
   short catalog.

Every decision is printed as a `NOTE:` line so the caller can surface it; nothing here is silent.
Exit 0 with the file written, 2 on bad usage, 3 when the template has no usable tortoise entry.
"""
from __future__ import annotations

import json
import os
import re
import sys

# The HOSTED endpoint's header must be the canonical shape: a `Bearer ` scheme plus one of the two
# variable names the resolver actually reads. The client sends headers VERBATIM, so a header without
# the scheme reaches the server as `Authorization: tt_…` (401), and a header naming a third variable
# expands to the EMPTY STRING while the credential check reports a working key — both were
# certifiable (and so PRESERVED, by install) before this was pinned.
HOSTED_AUTH = re.compile(r"^Bearer\s+\$\{TORTOISE_(API|MCP_API)_KEY(:-[^}]*)?\}$")

# The SAME shape the verifier scans for. It is applied to the WHOLE candidate entry, not just its
# Authorization header: a token pasted into `env`, `_comment` or any other field is still a credential
# in a shared 0644 file, and `--verify` refuses that file — so an install that PRESERVED it would
# re-write a config it then refuses, forever, saying nothing.
TOKEN = re.compile(r"\b(t[tk])_[A-Za-z0-9]{10,}")


def token_path(node, trail=""):
    """Path of the first literal-looking credential inside `node`, or "" (mirrors the verifier)."""
    if isinstance(node, dict):
        for k, v in node.items():
            got = token_path(v, "%s.%s" % (trail, k) if trail else str(k))
            if got:
                return got
    elif isinstance(node, list):
        for i, v in enumerate(node):
            got = token_path(v, "%s[%d]" % (trail, i))
            if got:
                return got
    elif isinstance(node, str) and TOKEN.search(node):
        return trail
    return ""


def near_miss(url, want_url):
    """True when `url` is the DEFAULT endpoint spelled differently (SAME AUTHORITY).

    A self-host is a DIFFERENT HOST — that is what makes it a self-host. Same host with a different
    path (or a missing trailing slash) is a typo, or a copy that got mangled, and preserving it means
    the box points at an endpoint nobody meant to configure.

    ⛔ THE SCHEME IS PART OF THE SPELLING, and comparing it is what keeps a scheme-only typo OUT of
    the `_selfHosted` exemption. That exemption is what `--verify` honours, and the hosted entry
    carries a live `Bearer ${TORTOISE_MCP_API_KEY}`: `http://api.premiselabs.co/mcp/` marked
    `_selfHosted` is then certified rc=0 by the verifier, and the key crosses the wire in CLEARTEXT
    while the cell prints LAYER VERIFIED. `https`↔`http` on the SAME host is a typo, never a
    self-host, so the default wins here and `--verify` refuses a credential on a non-https url as
    a second line of defence.
    """
    def host(u):
        m = re.match(r"^[a-z][a-z0-9+.\-]*://([^/]+)", u or "", re.I)
        return m.group(1).lower() if m else ""
    if not url or not want_url or url == want_url:
        return False
    uh, wh = host(url), host(want_url)
    return bool(wh) and uh == wh


def usable(entry, want_url):
    """Can a lane actually use this entry? Returns (ok, reason-for-refusal).

    ⛔ WELL-FORMEDNESS IS URL-AWARE, and getting this wrong is the bug this file exists to avoid.
    The HOSTED endpoint with no `Authorization` is a guaranteed 401, so it is unusable. A
    SELF-HOSTED daemon needs no key at all — `tortoise`'s own `docs/quickstart-selfhosted.md`
    documents exactly `{"tortoise":{"type":"http","url":"http://localhost:8000/mcp"}}`
    ("no key here: a local daemon needs none"), and this repo's SETUP-NEW-MACHINE.md tells
    self-host users to do the same. Demanding an env-indirect header unconditionally would
    declare the DOCUMENTED self-host config "unusable" and repoint it at the hosted endpoint on
    every sync — the silent repoint, reproduced by the very rule meant to prevent it.

    `type` is optional: the client's `McpServerConfig` has no `type` field and selects the HTTP
    transport from `url` alone, so requiring it would refuse a config that works. An explicit
    OTHER transport (`sse`/`stdio`) is a different thing and is refused.
    """
    if not isinstance(entry, dict) or entry.get("command"):
        return False, "command"
    leak = token_path(entry)
    if leak:
        return False, "literal@%s" % leak
    url = (entry.get("url") or "").strip()
    if not url:
        return False, "url"
    # `type` is only disqualifying for the HOSTED default. The client's McpServerConfig has no
    # `type` field at all (it selects StreamableHTTP from `url` alone), so a self-hosted entry that
    # spells `type: "sse"` for its own daemon WORKS — replacing it would destroy the operator's
    # config and point them at an endpoint they have no key for.
    if (entry.get("url") or "").strip() == (want_url or "").strip() and entry.get("type") not in (None, "http"):
        return False, "type"
    auth = (entry.get("headers") or {}).get("Authorization") or ""
    if auth and "${" not in auth:
        # a literal credential written into a shared config file is the leak, never the fix
        return False, "literal"
    if url != want_url:
        # a self-hosted daemon may need no key at all (docs/quickstart-selfhosted.md), and its
        # header may legitimately name a different variable — it is the operator's daemon.
        return True, ""
    if not auth:
        return False, "nokey"
    if not HOSTED_AUTH.match(auth.strip()):
        return False, "scheme"
    return True, ""


def main(argv):
    # ⛔ AN UNKNOWN FLAG IS A USAGE ERROR, NOT SOMETHING TO DROP. The old `--cell in argv` plus
    # `[a for a in argv if not a.startswith("--")]` swallowed every stray flag silently, so
    # `merge-mcp.py <tpl> <dst> --cel` exited 0 having installed the FULL base catalog — the exact
    # unspawnable set rule 4 exists to keep off a cell (`seo-intelligence` needs a `mcp-servers/`
    # tree a cell does not ship; `playwright-browser` pulls npx onto a small box). The flag that
    # decides a cell's whole MCP surface must not fail open on a typo, and a longer catalog reads as
    # richer, not wrong, so nothing downstream would report it.
    flags = [a for a in argv if a.startswith("--")]
    args = [a for a in argv if not a.startswith("--")]
    unknown = [f for f in flags if f != "--cell"]
    if unknown:
        sys.stderr.write("FATAL: unknown flag(s): %s\n" % " ".join(unknown))
        sys.stderr.write(__doc__ or "usage: merge-mcp.py <template> <dest> [--cell]\n")
        return 2
    cell = "--cell" in flags
    if len(args) != 2:
        sys.stderr.write(__doc__ or "usage: merge-mcp.py <template> <dest> [--cell]\n")
        return 2
    tpl_path, dst_path = args

    tpl = json.load(open(tpl_path))
    dst = json.load(open(dst_path)) if os.path.exists(dst_path) else {}
    base = tpl.get("mcpServers") or {}
    want = base.get("tortoise")
    if not isinstance(want, dict) or not want.get("url"):
        sys.stderr.write("FATAL: %s declares no usable tortoise entry\n" % tpl_path)
        return 3

    have = dict(dst.get("mcpServers") or {})

    # 1. the exa migration (owner ruling 2026-10-31)
    if have.pop("exa", None) is not None:
        print("NOTE: exa removed from .mcp.json (owner ruling 2026-10-31 — uninstalled, not configured)")

    # 2/3. tortoise
    cur = have.get("tortoise")
    if isinstance(cur, dict) and not cur.get("command"):
        ok_entry, why = usable(cur, (want.get("url") or "").strip())
        if ok_entry and near_miss((cur.get("url") or "").strip(), (want.get("url") or "").strip()):
            # ⛔ A TYPO IS NOT A SELF-HOST, AND THE INSTALLER MUST NOT BLESS ONE. Marking ANY
            # differing url `_selfHosted` let this file certify the exact config `--verify`'s
            # "unmarked non-default url" rule exists to catch: a repair install would mint the
            # exemption the verifier then honours (`cloud-cell-bringup.sh` runs verify, and on
            # failure runs install — so the refusal was being repaired into a certification).
            # Same host, different spelling (a trailing slash, a path typo, a copied-and-mangled
            # url) is a near-miss of the DEFAULT, so the default wins and the NOTE says why.
            print(
                "NOTE: replaced a near-miss of the hosted url (%s) with the default (%s) — a "
                "different spelling of the SAME host is a typo, not a self-host; a genuine self-host "
                "is a different host and is preserved"
                % (cur.get("url"), want.get("url"))
            )
            have["tortoise"] = want
        elif ok_entry:
            if (cur.get("url") or "").strip() != (want.get("url") or "").strip():
                if not cur.get("_selfHosted"):
                    cur["_selfHosted"] = True
                    print(
                        "NOTE: kept this machine's own tortoise url (%s) instead of the default (%s) and marked "
                        "it _selfHosted — re-point it deliberately if that is wrong"
                        % (cur.get("url"), want.get("url"))
                    )
                else:
                    print("NOTE: kept this machine's self-hosted tortoise url (%s)" % cur.get("url"))
                have["tortoise"] = cur
            else:
                # SAME ENDPOINT: take the template's fields (lazy/timeout/purpose…), but KEEP the
                # credential variable this entry already declares when it is one of the two names a
                # client can resolve. The template installs the STANDARD name
                # (`TORTOISE_MCP_API_KEY`); rewriting an existing `Bearer ${TORTOISE_API_KEY}` entry
                # to it on a LEGACY-only box turns a WORKING entry into an empty Bearer — the client
                # expands `process.env[NAME]` verbatim, with no alias mapping — and doing it silently
                # is the repoint class this file exists to stop.
                entry = dict(want)
                cur_auth = ((cur.get("headers") or {}).get("Authorization") or "").strip()
                want_auth = ((want.get("headers") or {}).get("Authorization") or "").strip()
                if cur_auth and cur_auth != want_auth:
                    entry["headers"] = dict(want.get("headers") or {}, Authorization=cur_auth)
                    print(
                        "NOTE: kept this entry's credential variable (%s) instead of the template's (%s)"
                        % (cur_auth, want_auth)
                    )
                have["tortoise"] = entry
        else:
            print(
                "NOTE: REPLACED an unusable tortoise entry (reason: %s — the hosted endpoint needs an "
                "env-indirect Authorization, and no entry can carry a literal key) with the hosted "
                "default; a preserved one could never be repaired" % why
            )
            have["tortoise"] = want
    else:
        if isinstance(cur, dict):
            print("NOTE: replaced the legacy stdio tortoise entry with the hosted http entry")
        have["tortoise"] = want

    # 4. which of the template's other servers to install
    if cell:
        dropped = sorted(k for k in base if k != "tortoise" and k not in have)
        if dropped:
            print("NOTE: not installed on a cell (they cannot spawn there): %s" % ", ".join(dropped))
    else:
        for name, entry in base.items():
            if name != "tortoise":
                was = have.get(name)
                if isinstance(was, dict) and was != entry:
                    # NOT SILENT (rule 2's second half). The template still wins — that is what makes
                    # a base-config fix reach a provisioned machine — but replacing a
                    # hand-customized entry is a decision the operator has to be able to see.
                    print(
                        "NOTE: replaced this machine's own %r with the template's (the base config is "
                        "the source for every server except tortoise; keep a local variant under a "
                        "different name if you need it)" % name
                    )
                have[name] = entry

    merged = {**dst, "mcpServers": have}
    # ⛔ NEVER TRUNCATE IN PLACE. `json.dump(open(dst_path, "w"))` empties the file first and writes
    # it incrementally, so a concurrent reader — a live lane's mcp-client picking the first
    # `.mcp.json` it finds, or record-review.sh during an install — can read a half-written config
    # and see ZERO MCP servers: exactly the GRAPH-UNREACHABLE symptom this change exists to remove,
    # reintroduced as a race. `cell-install.sh`'s own `install_file` writes temp+`mv` for this reason;
    # `.mcp.json` is now a cell artifact too, so it gets the same treatment.
    tmp = "%s.tmp.%d" % (dst_path, os.getpid())
    try:
        with open(tmp, "w") as fh:
            json.dump(merged, fh, indent=2)
        os.replace(tmp, dst_path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
