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
   * anything else (a hosted url with no key, a literal key, a `headers` that is not a mapping,
     an explicit non-http transport ON THE HOSTED URL) is REPLACED with the template's entry,
     because preserving it creates a config `--verify` must refuse in perpetuity — a cell no
     repair can fix. On a url the operator chose, a non-http `type` is their business and is
     preserved with the entry (the client never reads `type`; see `usable()`).

4. `--cell` installs the graph server ONLY. The template's other base servers are wrong for a
   cell, not merely unnecessary: `seo-intelligence` spawns
   `${AGENT_INFRA_PATH}/mcp-servers/seo-intelligence/node_modules/.bin/tsx` and a cell ships
   `extensions/` only (manifest.json carries no `mcp-servers/`), so it cannot spawn;
   `brave-search`/`gemini` spawn without their keys; `playwright-browser` pulls an npx package
   onto a memory-constrained box. A catalog that advertises an unspawnable tool is worse than a
   short catalog. ⛔ A base server the DESTINATION already declares is neither installed nor
   removed: it is KEPT (a merge never clobbers, rule 2) and printed as `already declares …
   KEPT`, because a NOTE that listed only the servers that were MISSING read as "the base
   catalog is not installed" while an unspawnable entry sat in the file, certified.

   * a NON-OBJECT `tortoise` (a hand-written list, a bare string) is REPLACED and NAMED, and the
     bytes are kept as `.bak`: it is operator content, the same class rules 3's container cases
     protect, and it was the one shape this file deleted without a `NOTE:` — a contract violation
     against the line below (#3374 review P2).

   ⛔ EVERY url this file PRESERVES must be an ABSOLUTE `http(s)` url, because that is the minimum
   `cell-install.sh --verify` will certify for the `_selfHosted` exemption it honours (`BADURL`).
   Preserving anything weaker makes the repair path non-convergent: `cloud-cell-bringup.sh` runs
   verify → install → verify, so an install that keeps a scheme-less url hands back a file the very
   next verify refuses, for ever (#3374 review P2, measured).

Every decision is printed as a `NOTE:` line so the caller can surface it; nothing here is silent.
Exit 0 with the file written, 2 on bad usage, 3 when the template cannot be read or has no usable
tortoise entry.
"""
from __future__ import annotations

import ipaddress
import json
import os
import re
import stat
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

# The ONE parse of a url's `host[:port]`, for the three predicates that must agree about it
# (`host_of`, `authority_of`, and — through `authority_of` — `near_miss`). Groups: 1 = host (an IPv6
# literal keeps its brackets and is therefore ONE token), 2 = port (None when absent, `""` when the
# url spells a bare `host:`).
_URL_PARTS = re.compile(
    r"^[a-z][a-z0-9+.\-]*://(?:[^/?#]*@)?(\[[^\]]*\]|[^/?#:]*)(?::(\d*))?", re.I
)


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


def host_of(url):
    """The HOST of `url` — scheme, port and any USERINFO removed.

    ⛔ USERINFO IS NOT THE HOST, and this is the same rule `_loopback` already applies below. Reading
    the authority verbatim made `https://api.premiselabs.co@evil.example/mcp/` — whose real host is
    **evil.example** — look like "a genuine self-host" to both `near_miss` and `host_typo`, so the
    merge PRESERVED it and marked it `_selfHosted`, `--verify` certified `SELFHOSTED:`, and the
    entry's `Bearer ${TORTOISE_MCP_API_KEY}` went to the attacker's host with this repo's blessing.
    Two predicates in one file disagreeing about what "the host" is, is the defect; this is the one
    definition (#3374 review P1).

    ⛔ AN IPv6 LITERAL IS ONE TOKEN: `[::1]` and `[::2]` must not both read as `[`, which is what a
    `[^/?#:]*` host class did — it stops at the first colon INSIDE the brackets, so every IPv6
    address collapsed to the same string and any comparison built on this would have called two
    distinct hosts equal (#3374 review P2).
    """
    m = _URL_PARTS.match(url or "")
    return m.group(1).lower() if m else ""


def authority_of(url):
    """`host[:port]` — RFC 3986's authority with the userinfo removed.

    ⛔ THIS IS THE COMPARAND `near_miss` NEEDS, AND `host_of` ALONE IS NOT IT. Dropping the port made
    `https://api.premiselabs.co:8443/mcp/` — an operator's OWN daemon on a non-default port — compare
    equal to the hosted default and get REPLACED as "a typo", which it is not: the port is part of the
    endpoint. A self-host differing only by port is preserved and named, exactly as it was before the
    userinfo fix (#3374 review P2 — a regression that fix introduced).
    """
    m = _URL_PARTS.match(url or "")
    if not m:
        return ""
    port = m.group(2)
    return (m.group(1) + (":" + port if port is not None else "")).lower()


# WHATWG URL's forbidden HOST code points. A host containing one is not "a spelling of a host" —
# the client's parser refuses it outright (`new URL(...)` -> ERR_INVALID_URL), so a predicate that
# calls it usable certifies an endpoint no request can be built from.
# ⛔ THIS LIST IS THE POINT, NOT A DETAIL: `all(lab and any(ch.isalnum() for ch in lab))` alone
# passes `api.premiselabs.co|evil.example` (every label has an alnum), and the marker printed
# `SELFHOSTED:` rc=0 for it — a false PASS on the certification gate, resurrecting the exact class
# the host predicate was added to close (#3374 review, round 2 P3).
_HOST_FORBIDDEN = set("\x00\t\n\r #/:<>?@[\\]^|")

try:                                          # IDNA2008/UTS46 — the standard the client applies
    import idna as _idna
except ImportError:                           # pragma: no cover — stdlib-only box
    _idna = None


def _label_ok(lab):
    """True when one DNS label is a name the client would accept.

    ASCII labels get the structural rule only (non-empty, at least one alnum) — deliberately NOT
    `idna.encode`, which is IDNA2008 and stricter than the client on ASCII (it refuses `-abc`, which
    `new URL` accepts; refusing a spelling that WORKS is the false block this gate exists to avoid).
    A non-ASCII label is the opposite case: the client applies UTS46, and only IDNA2008 agrees with
    it — `١.example` passes an "alnum" test and `new URL` throws (`IDNABidiError`), while
    `münchen.example` is accepted by both. So ask the library, and keep the residual visible: on a
    box with no `idna` the label is accepted on the forbidden-code-point check alone.
    """
    if not lab or not any(ch.isalnum() for ch in lab):
        return False
    if any(ch in _HOST_FORBIDDEN for ch in lab):
        return False
    if lab.isascii() or _idna is None:
        return True
    try:
        _idna.encode(lab, uts46=True)
    except Exception:
        return False
    return True


def authority_names_a_host(authority):
    """True when `authority` (`host[:port]`, userinfo already stripped) names an endpoint at all.

    ⛔ `_selfHosted` IS AN EXEMPTION, AND AN EXEMPTION MAY ONLY CERTIFY SOMETHING REACHABLE (#3374
    review P3). The exemption's floor was `^scheme://[^/?#]+` — ONE character after `//` was enough —
    so `https://:8443/mcp/` (no host), `https://my daemon:8000/mcp` (a space in the host) and
    `https://api.premiselabs.co:8443x/mcp/` (a non-numeric port) were all printed `SELFHOSTED:` and
    exited 0, i.e. LAYER VERIFIED over an entry that points at nothing. That is the same false green
    the scheme-less `BADURL:` arm exists to close; this arm is the rest of it.

    THE RULE IS THE CLIENT'S PARSER, NOT A GUESS. Each refusal below is a shape `new URL(u)` in the
    mcp-client THROWS on (measured: `ERR_INVALID_URL` for the empty host, the space, the non-numeric
    port, `:65536`, `:-1` and a percent-encoded host) — so refusing it cannot over-block a config
    that works, because no request can be constructed from it either. The shapes the client ACCEPTS
    are accepted here: a bare trailing `host:` (URL reads it as no port), a trailing root dot
    (`api.example.`), an underscore (`my_host`), an IDN (punycoded by URL), and `[<ipv6>]:port`.
    The empty-labeled and alnum-free forms the client parses but DNS cannot resolve (`.`, `-`,
    `a..b`) are refused too: they are typos, never an endpoint someone configured.

    ⛔ `cell-install.sh`'s marker carries the SAME predicate under the same name. Two predicates
    disagreeing about "a usable endpoint" is the defect class this whole change exists to close
    (#3374 P1), so a shape refused here must be refused there and vice versa.
    """
    a = (authority or "").strip()
    if not a or any(c.isspace() for c in a):
        return False
    if "@" in a:                                 # userinfo is NOT the host (refused elsewhere)
        a = a.rsplit("@", 1)[1]
    if a.startswith("["):                         # `[<ipv6>]`, optionally `:port`
        m = re.match(r"^\[([0-9A-Fa-f:.]+)\](?::(.*))?$", a)
        if not m or not _port_ok(m.group(2)):
            return False
        try:
            ipaddress.IPv6Address(m.group(1))
        except ValueError:
            return False
        return True
    if a.count(":") > 1:                          # an unbracketed IPv6 is not a legal authority
        return False
    host, sep, port = a.partition(":")
    if sep and port and not _port_ok(port):
        return False
    if not host or "%" in host:                    # empty, or pct-encoded (the client throws)
        return False
    labels = host[:-1].split(".") if host.endswith(".") else host.split(".")
    return all(_label_ok(lab) for lab in labels)


def _port_ok(port):
    """True when `port` is absent, or a decimal 1..65535 (`""` is the bare-`host:` spelling)."""
    if port is None or port == "":
        return True
    if not port.isdigit():
        return False
    return 1 <= int(port) <= 65535


def near_miss(url, want_url):
    """True when `url` is the DEFAULT endpoint spelled differently (SAME AUTHORITY).

    A self-host is a DIFFERENT HOST — that is what makes it a self-host. Same host with a different
    path (or a missing trailing slash) is a typo, or a copy that got mangled, and preserving it means
    the box points at an endpoint nobody meant to configure.

    ⛔ THE SCHEME IS PART OF THE SPELLING **AND IT IS DELIBERATELY NOT COMPARED** — the comparison
    below is on the AUTHORITY ALONE (`authority_of()` drops the scheme AND any userinfo, and KEEPS the
    port), so `http://host/mcp` and `https://host/mcp` are the SAME spelling: a near-miss of the
    default, which is REPLACED by it. That is what keeps a scheme-only typo OUT of the `_selfHosted`
    exemption — the exemption `--verify` honours, on an entry that carries a live
    `Bearer ${TORTOISE_MCP_API_KEY}`, so `http://api.premiselabs.co/mcp/` marked `_selfHosted` would go
    on to meet the verifier's own https floor with the key on a cleartext transport (`--verify` refuses
    it as INSECURE_URL, which is the second line of defence, not the first). ⛔ DO NOT "FIX" THIS BY
    COMPARING THE SCHEME: a scheme-sensitive comparison makes the cleartext spelling a DIFFERENT url,
    i.e. a self-host to preserve and mark — the exact direction this function exists to refuse.
    """
    if not url or not want_url or url == want_url:
        return False
    uh, wh = authority_of(url), authority_of(want_url)
    return bool(wh) and uh == wh


def _edit_distance(a, b, floor=3):
    """Levenshtein distance, cut off once it is provably >= `floor`.

    Hosts are short, so the table is tiny; the cut-off keeps a long, obviously-different host from
    costing O(len(a)*len(b)) when the answer is already "not a near-miss".
    """
    if abs(len(a) - len(b)) >= floor:
        return floor
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        if min(cur) >= floor:
            return floor
        prev = cur
    return min(prev[-1], floor)


def host_typo(url, want_url, floor=3):
    """True when `url`'s HOST is a lookalike of the default's — a one- or two-character typo.

    ⛔ THE HOLE THIS CLOSES IS NOT THE SAME-SPELLING ONE `near_miss` ALREADY CATCHES. `near_miss`
    matches on the AUTHORITY, so `api.premiselabs.co` vs `api.premiselab.co` (one letter) is a
    DIFFERENT host to it — i.e. "a genuine self-host", which the merge then preserved AND MARKED
    `_selfHosted`, the exemption `--verify` honours. So a repair install (cloud-cell-bringup.sh
    runs verify → install → verify) minted the exemption for the exact config the verifier had just
    refused, and the entry still carried `Bearer ${TORTOISE_MCP_API_KEY}` — the live tenant key was
    sent to a host nobody vetted (#3374 review P1).

    A DELIBERATE self-host is not one character away from the hosted endpoint (localhost, a LAN
    address, a company domain), so this does NOT override the recorded rule that "a genuine
    self-host is a different host and is preserved" — it only stops a LOOKALIKE from inheriting it.
    """
    uh, wh = host_of(url), host_of(want_url)
    if not uh or not wh or uh == wh:
        return False
    return _edit_distance(uh, wh, floor) < floor


def _loopback(authority):
    """⛔ MUST MATCH `cell-install.sh`'s `_loopback` — the verifier applies the same rule, and a
    disagreement here is the "install preserves what verify refuses" loop this file's docstring
    forbids. An IP-LITERAL test, never a prefix test: `127.attacker.example` is an ordinary DNS name
    its owner can point anywhere and `127.0.0.1@evil.example` is userinfo followed by an attacker's
    host — both passed a `startswith("127.")` exemption and were then certified `SELFHOSTED:` with
    the tenant key attached.
    """
    h = (authority or "").strip().lower()
    if "@" in h:                                  # userinfo is NOT the host
        h = h.rsplit("@", 1)[1]
    if h.startswith("["):                          # an IPv6 literal: `[<addr>]`, optionally `:port`
        end = h.find("]")
        if end < 0:
            return False
        rest = h[end + 1:]
        if rest and not rest.startswith(":"):
            return False
        # ⛔ ASK ipaddress, DO NOT STRING-MATCH `::1` — same rule as the IPv4 arm below: a string
        # match called `[0:0:0:0:0:0:0:1]` remote, so a legal spelling of the documented local
        # self-host was refused as INSECURE_URL (a false block). MUST MATCH cell-install.sh.
        try:
            return ipaddress.ip_address(h[1:end]).is_loopback
        except ValueError:
            return False
    host = h.rsplit(":", 1)[0] if h.count(":") == 1 else h
    if host == "localhost":
        return True
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return False                             # a DNS name is never loopback, whatever it says


def _keep_backup(path):
    """Copy `path` to `<path>.bak` before this merge REPLACES an unreadable container.

    The bytes a merge discards are not a config (that is why it is replacing them), but they may be
    hand-written work, and silently deleting operator content is exactly what this file's rules
    forbid. Best-effort and LOUD on failure: a backup that cannot be written must not turn the
    repair path back into the thing that cannot converge. The destination's mode is carried over, so
    a credential-adjacent file does not get WIDER by being backed up.
    ⛔ THE PORT IS PART OF THE ENDPOINT, AND THE MESSAGE MUST NAME THE FILE THAT EXISTS. `_keep_backup`
    writes beside the RESOLVED path (a dotfiles-SYMLINKED `.mcp.json` is the common case this branch
    exists for), so printing `<dst>.bak` sent the operator to a path with nothing in it while the
    bytes sat beside the symlink's target (#3374 review P2). The return value is where they went.
    """
    import shutil
    real = os.path.realpath(path)
    if not os.path.exists(real):
        return ""
    dst = real + ".bak"
    try:
        shutil.copy2(real, dst)
        if os.path.exists(real):
            os.chmod(dst, stat.S_IMODE(os.stat(real).st_mode))
    except OSError as exc:                        # pragma: no cover — environment-dependent
        sys.stderr.write("WARNING: could not back up %s (%s) — continuing the repair\n" % (path, exc))
        return ""
    return dst


def credential_in_the_clear(url):
    """True when a credential sent to this url would cross a network unencrypted.

    Same rule the verifier applies (`cell-install.sh` `INSECURE_URL`): `https`, or a LOOPBACK
    destination that cannot leave the box. A self-host that needs a key off-box must serve https.
    """
    m = re.match(r"^([a-z][a-z0-9+.\-]*)://([^/]+)", (url or "").strip(), re.I)
    if not m:
        return True                              # unparseable url: nothing certifiable
    return m.group(1).lower() != "https" and not _loopback(m.group(2))


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
    OTHER transport (`sse`/`stdio`) disqualifies the HOSTED default, where `http` is the contract —
    on the operator's OWN daemon (any non-default url) it is their business and is preserved: the
    client never reads `type`, so refusing it there would destroy a config that works.

    ⛔ `headers` MUST BE A MAPPING. A hand-edit (or a curl-style paste) can produce
    `"headers": "Bearer …"`; `.get` on a str/list raises BEFORE the write, so the merge would exit
    1 having changed nothing — and `--install` is the REPAIR path, so an entry in that shape could
    never be fixed by the installer at all (the "config nothing can repair" this file exists to
    prevent) while `--verify` reported an empty marker beside a traceback. It is unusable, so it is
    REPLACED. `cell-install.sh`'s marker refuses the same shape BY NAME (`BADDERS:`).
    """
    if not isinstance(entry, dict) or entry.get("command"):
        return False, "command"
    leak = token_path(entry)
    if leak:
        return False, "literal@%s" % leak
    # ⛔ SEE THE DOCSTRING: a `headers` that is not a mapping must be a REFUSAL (so the entry is
    # replaced), never an AttributeError raised before the write.
    headers = entry.get("headers")
    if headers is not None and not isinstance(headers, dict):
        return False, "headers"
    url = (entry.get("url") or "")
    # ⛔ TOTAL OVER ARBITRARY JSON: a non-STRING url made `.strip()`/`re.match` raise and a non-string
    # Authorization made `"${" not in auth` raise TypeError — both BEFORE the write, so the merge
    # exited 1 with the file unchanged and the repair path could never fix the entry. Refusals, so the
    # entry is replaced.
    if not isinstance(url, str) or not url.strip():
        return False, "url"
    url = url.strip()
    # ⛔ AN ABSOLUTE http(s) url IS THE FLOOR, BECAUSE IT IS THE VERIFIER'S (`BADURL:`). `--verify`
    # refuses the `_selfHosted` exemption on a scheme-less url — the client's `new URL()` reads
    # `localhost:8000/mcp` as protocol `localhost:` with no host, so the cell points at nothing —
    # and a merge that PRESERVED one handed back a file the next verify refuses. Measured on the
    # real repair path (`cloud-cell-bringup.sh`: verify → install → verify): it never converged.
    # A refusal here makes the repair REPLACE the entry, which is the only converging answer.
    if not re.match(r"^https?://[^/?#]+", url, re.I):
        return False, "badurl"
    # ⛔ USERINFO IN THE AUTHORITY MAKES THE OPERATOR'S INTENT UNREADABLE, AND IT IS THE SHAPE A
    # HOST-SPOOF TAKES: `https://api.premiselabs.co@evil.example/mcp/` resolves to **evil.example**
    # while its authority BEGINS with the hosted host. `near_miss`/`host_typo` now read the REAL
    # host (`host_of`, which strips userinfo exactly as `_loopback` already did), so such an entry
    # is not a TYPO of the default — but it is also not the DELIBERATE different endpoint those
    # rules exist to preserve, and preserving it minted `--verify`'s `SELFHOSTED:` certification on
    # an entry still carrying `Bearer ${TORTOISE_MCP_API_KEY}`: the tenant key to an attacker's host,
    # blessed by this repo (#3374 review P1). A credential belongs in `headers`, never in the
    # authority, so this shape is REPLACED with the hosted default rather than certified.
    if re.match(r"^[a-z][a-z0-9+.\-]*://[^/?#]*@", url, re.I):
        return False, "userinfo"
    # ⛔ THE SAME ARM AS THE VERIFIER'S `NOHOST:` — an authority that names no endpoint is not a
    # self-host to preserve, and preserving it hands back a file the next verify refuses, forever.
    _a = re.match(r"^[a-z][a-z0-9+.\-]*://([^/?#]*)", url, re.I)
    if not authority_names_a_host(_a.group(1) if _a else ""):
        return False, "nohost"
    # `type` is only disqualifying for the HOSTED default. The client's McpServerConfig has no
    # `type` field at all (it selects StreamableHTTP from `url` alone), so a self-hosted entry that
    # spells `type: "sse"` for its own daemon WORKS — replacing it would destroy the operator's
    # config and point them at an endpoint they have no key for.
    if (entry.get("url") or "").strip() == (want_url or "").strip() and entry.get("type") not in (None, "http"):
        return False, "type"
    auth = (headers or {}).get("Authorization") or ""
    if not isinstance(auth, str):
        return False, "auth"
    if auth and "${" not in auth:
        # a literal credential written into a shared config file is the leak, never the fix
        return False, "literal"
    if auth and credential_in_the_clear(url):
        # ⛔ THE VERIFIER'S https FLOOR, APPLIED HERE TOO. `--verify` refuses a credential sent to a
        # non-loopback non-https url; preserving such an entry would mint a config the verifier
        # refuses and `--install` then exits non-zero on — a bring-up that can never converge, which
        # is exactly the "config `--verify` must refuse in perpetuity" this function exists to stop.
        return False, "insecure"
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

    # ⛔ THE TEMPLATE IS THE ONE INPUT WHOSE FAILURE WAS A PYTHON TRACEBACK. Every other unreadable
    # shape in this file is a NAMED refusal with a documented exit code — while `json.load` on a
    # missing or corrupt template raised straight out of `main`, so a caller got `FileNotFoundError:`
    # / `JSONDecodeError:` on stderr and rc=1, a contract the docstring does not advertise (0/2/3).
    # It is reachable: `setup.sh` guards only `[ -f ]` before calling this under `set -e`, so a
    # CORRUPT template printed a traceback and aborted the sync there. Named here, at the one exit
    # code the docstring already reserves for a template this file cannot use (#3374 review P2).
    try:
        # ⛔ EXPLICIT utf-8, NOT THE LOCALE ENCODING. The shipped template carries non-ASCII (`—` in
        # `_comment`/`purpose`), and text-mode `open()` uses the locale's encoding — `PYTHONUTF8=0`
        # with a C/POSIX locale is `ascii`, and this read then dies on its own byte 503
        # (`UnicodeDecodeError`), reported here as a FATAL template the operator will not believe is
        # broken. Modern CPython coerces a C locale to UTF-8, so a default host does not bite; a
        # service unit or a pinned-off environment does. `cell-install.sh`'s
        # `merge_tortoise_is_hosted` already reads with an explicit encoding — this is the same rule
        # at the other 4 sites, so the two sides cannot disagree about a healthy file.
        tpl = json.load(open(tpl_path, encoding="utf-8"))
    except (OSError, ValueError) as exc:
        sys.stderr.write(
            "FATAL: cannot read the template %s (%s: %s)\n" % (tpl_path, type(exc).__name__, exc)
        )
        return 3
    # ⛔ UNPARSEABLE IS THE LAST CONTAINER SHAPE THAT COULD NOT BE REPAIRED. `json.load` raised
    # `JSONDecodeError` (a `ValueError`) BEFORE the write, so `--install` — the repair path
    # `cloud-cell-bringup.sh` runs on a verify failure — exited 1 having changed nothing, and the
    # bring-up died; `setup.sh` aborted too (it calls this under `set -e`), leaving agents,
    # extensions and farms uninstalled behind an unreadable config. And it is REACHABLE, not
    # theoretical: the pre-#3374 merge wrote `.mcp.json` with `json.dump(open(dst, "w"))` —
    # truncate-in-place, the very race the write below documents — so an interrupted legacy run left
    # a truncated file on an already-provisioned box. `--verify` already refuses this shape
    # (`NOTJSON:`), so the layer calls it invalid; the repair is a REPLACE, and the replaced bytes
    # are KEPT. Same rule as the two container shapes below, one level up: a file nothing can parse
    # is not a config, but it may be hand-written work someone wants back.
    dst = {}
    if os.path.exists(dst_path):
        try:
            dst = json.load(open(dst_path, encoding="utf-8"))
        except ValueError as exc:
            print(
                "NOTE: REPLACED an UNPARSEABLE .mcp.json (%s: %s); the previous file was saved as %s"
                % (type(exc).__name__, exc, _keep_backup(dst_path) or "(backup FAILED — see the WARNING above)")
            )
            dst = {}
    # ⛔ A TEMPLATE THAT PARSES BUT IS THE WRONG **SHAPE** WAS STILL A TRACEBACK. Guarding `json.load`
    # alone left `tpl.get` on a list (or `base.get` on a non-object `mcpServers`) raising straight out
    # of `main` — rc=1 and Python internals, the very contract the guard above declares closed. A
    # shape this file cannot read is the same answer as a file it cannot parse: NAMED, exit 3 (#3374
    # review P2).
    base = tpl.get("mcpServers") if isinstance(tpl, dict) else None
    if base is None:
        base = {}
    if not isinstance(tpl, dict) or not isinstance(base, dict):
        sys.stderr.write(
            "FATAL: the template %s is not a config this file can read (root is %s, `mcpServers` is %s "
            "— both must be JSON objects)\n"
            % (tpl_path, type(tpl).__name__, type(base).__name__)
        )
        return 3
    want = base.get("tortoise")
    if not isinstance(want, dict) or not want.get("url"):
        sys.stderr.write("FATAL: %s declares no usable tortoise entry\n" % tpl_path)
        return 3
    # ⛔ A TEMPLATE url THAT IS NOT A STRING WAS A TRACEBACK TOO, one predicate further in. The
    # guard above checks only that `url` is TRUTHY, so `"url": 123` (or an object) passed it and
    # died at `(want.get("url") or "").strip()` — `AttributeError: 'int' object has no attribute
    # 'strip'`, rc=1, the file unchanged, i.e. the repair path could not repair it AND the operator
    # got Python internals, which is the contract `main()`'s own template guard declares closed.
    # The verifier had the mirror of it: a non-string template url made `want_url` an int, so
    # `--verify` printed `URL_NOT_DEFAULT:` against the cell's CORRECT hosted entry — a sentence
    # asserting the right config was wrong (#3374 review, round 2 P3).
    if not isinstance(want.get("url"), str) or not want.get("url").strip():
        sys.stderr.write(
            "FATAL: %s declares a tortoise url of type %s, not a non-empty string — the merge and "
            "`--verify` both read it as the hosted endpoint, so nothing can be compared against it\n"
            % (tpl_path, type(want.get("url")).__name__)
        )
        return 3

    # ⛔ TOTAL OVER THE DESTINATION'S *STRUCTURE*, not only over its entries. `usable()` was made
    # total one level down (a `headers` that is a string, a non-string url/Authorization) and these
    # two containers were left assuming a mapping: a `.mcp.json` whose ROOT is `[]`/`"x"`/`5`, or
    # whose `mcpServers` is `5`/`"x"`/`[]`, raised BEFORE the write — merge rc=1 with the file
    # unchanged, and `--verify` raised on its own copy of the same two lines, so `--install` (the
    # REPAIR path, and `cloud-cell-bringup.sh` runs it on a verify failure) could never clear it and
    # EVERY bring-up died. The repair is a REPLACE, and the replaced bytes are kept: a container
    # nothing can parse is not a config, but it may be hand-written work someone wants back.
    if not isinstance(dst, dict):
        print(
            "NOTE: REPLACED a %s .mcp.json ROOT (not a JSON object); the previous file was saved as %s"
            % (type(dst).__name__, _keep_backup(dst_path) or "(backup FAILED — see the WARNING above)")
        )
        dst = {}
    servers = dst.get("mcpServers")
    if servers is None:
        servers = {}
    if not isinstance(servers, dict):
        print(
            "NOTE: REPLACED a %s `mcpServers` (not a JSON object); the previous file was saved as %s"
            % (type(servers).__name__, _keep_backup(dst_path) or "(backup FAILED — see the WARNING above)")
        )
        have = {}
    else:
        have = dict(servers)

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
        elif ok_entry and host_typo((cur.get("url") or "").strip(), (want.get("url") or "").strip()):
            # A LOOKALIKE HOST IS A TYPO TOO. `near_miss` only compares the authority, so one wrong
            # letter in the HOST read as "a genuine self-host" and was preserved AND marked — which
            # is how a repair install turned `--verify`'s refusal into a certification, with the live
            # key attached (#3374 review P1). A genuine self-host is never 1–2 characters from the
            # hosted endpoint, so the default wins here for the same reason it wins on a same-host
            # typo: the box must not be left pointing at an endpoint nobody meant to configure.
            print(
                "NOTE: replaced a LOOKALIKE of the hosted host (%s) with the default (%s) — a host "
                "one or two characters from %s is a typo, not a self-host, and marking such an entry "
                "_selfHosted would certify it with the tenant key attached. A genuine self-host is a "
                "different host; re-point it deliberately if this was one"
                % (cur.get("url"), want.get("url"), (want.get("url") or "").strip())
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
                cur_headers = cur.get("headers") if isinstance(cur.get("headers"), dict) else {}
                want_headers = dict(want.get("headers") or {})
                cur_auth = (cur_headers.get("Authorization") or "").strip()
                want_auth = (want_headers.get("Authorization") or "").strip()
                # ⛔ `entry = dict(want)` USED TO DISCARD EVERY OTHER HEADER THIS MACHINE DECLARED,
                # with no output at all — the file's own contract (line 54) is that every decision
                # is a `NOTE:` line and "nothing here is silent". A cell behind a gateway that
                # requires `X-Tenant`, or a proxy that needs `Accept` pinned, lost it on EVERY
                # install and could only notice by diffing the file by hand (#3374 review P2).
                # A header the template does not declare is the OPERATOR's, so it is KEPT; a header
                # both declare is the TEMPLATE's, and overriding one is a decision that is NAMED.
                extra = {
                    k: v
                    for k, v in cur_headers.items()
                    if k not in want_headers and k != "Authorization"
                }
                overridden = sorted(
                    k
                    for k, v in cur_headers.items()
                    if k in want_headers and k != "Authorization" and v != want_headers[k]
                )
                headers = dict(want_headers)
                headers.update(extra)
                if cur_auth and cur_auth != want_auth:
                    headers["Authorization"] = cur_auth
                if extra:
                    print(
                        "NOTE: kept this machine's own header(s) on the tortoise entry: %s"
                        % ", ".join(sorted(extra))
                    )
                if overridden:
                    print(
                        "NOTE: replaced this machine's own %s on the tortoise entry with the "
                        "template's — the hosted endpoint's shape is fixed, so a local override "
                        "there does not survive an install" % ", ".join(overridden)
                    )
                if cur_auth and cur_auth != want_auth:
                    print(
                        "NOTE: kept this entry's credential variable (%s) instead of the template's (%s)"
                        % (cur_auth, want_auth)
                    )
                if extra or overridden or (cur_auth and cur_auth != want_auth):
                    entry["headers"] = headers
                have["tortoise"] = entry
        else:
            print(
                "NOTE: REPLACED an unusable tortoise entry (reason: %s — the hosted endpoint needs an "
                "env-indirect Authorization, no entry may carry a literal key, a credential may not "
                "be sent to a non-loopback url over a non-https scheme, EVERY preserved url must "
                "be an absolute http(s) url, no url may carry USERINFO in its authority (that is "
                "what a host-spoof looks like), and no authority may name a host the client cannot "
                "build a request from (an empty host, a space, a bad port, a percent-encoded host, "
                "or a name DNS cannot resolve) — all of that is the minimum `--verify` will certify) "
                "with the hosted default; a preserved one could never be repaired" % why
            )
            have["tortoise"] = want
    else:
        if isinstance(cur, dict):
            print("NOTE: replaced the legacy stdio tortoise entry with the hosted http entry")
        elif cur is not None:
            # ⛔ A NON-OBJECT `tortoise` IS OPERATOR CONTENT, and this branch used to REPLACE it with
            # no `NOTE:` at all — against this file's own contract ("nothing here is silent") and
            # unlike every sibling container shape, which names the replacement AND keeps the bytes.
            # A hand-written `["/x/python3", "-m", "tortoise.mcp_server"]` vanished without a word,
            # and `--verify` then reported `NOENTRY:` over a file the installer had just rewritten
            # (#3374 review P2).
            print(
                "NOTE: REPLACED a %s tortoise entry (not a JSON object) with the hosted http entry; "
                "the previous file was saved as %s"
                % (type(cur).__name__, _keep_backup(dst_path) or "(backup FAILED — see the WARNING above)")
            )
        have["tortoise"] = want

    # 4. which of the template's other servers to install
    if cell:
        dropped = sorted(k for k in base if k != "tortoise" and k not in have)
        if dropped:
            print("NOTE: not installed on a cell (they cannot spawn there): %s" % ", ".join(dropped))
        # ⛔ KEPT, AND SAID OUT LOUD. A merge never clobbers (rule 2), so a base server this cell
        # ALREADY declares survives — including one that cannot spawn here (a hand-edit, or a
        # pre-`--cell` sync). Printing only the servers that were ABSENT made the log read as "the
        # base catalog is not installed" while such an entry sat in the file, certified by --verify.
        kept_off = sorted(k for k in base if k != "tortoise" and k in have)
        if kept_off:
            print(
                "NOTE: this cell's .mcp.json already declares %s — KEPT (a merge never clobbers), but "
                "none of them can spawn on a cell; remove the entry if you did not put it there"
                % ", ".join(kept_off)
            )
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

    # ⛔ A MERGE THAT PRESERVES A LEAK AND SAYS NOTHING is the same defect from the other side. The
    # token scan above only ever sees the TORTOISE entry, so a literal credential pasted into any
    # OTHER server was preserved silently: the merge printed `hosted tortoise entry installed`, rc=0,
    # and the layer then refused the very file it had just written — a bring-up that cannot converge
    # while the install log reads as success. It is NAMED here rather than refused: the bytes are
    # ALREADY in the destination (a merge never clobbers, and setup.sh merges on laptops where no
    # verifier runs), so refusing would turn a diagnostic into a new block without removing the
    # secret. What was missing is the sentence, not the exit code.
    for name, entry in sorted(have.items()):
        if name == "tortoise":
            continue                    # refused by `usable()`, and named by `--verify` already
        at = token_path(entry, name)
        if at:
            print(
                "NOTE: .mcp.json STILL carries a literal credential at %s — this merge preserved it, "
                "and `--verify` will refuse this file until it is removed. Make it env-indirect "
                '(e.g. "${YOUR_VAR}") or delete the entry' % at
            )

    merged = {**dst, "mcpServers": have}
    # ⛔ NEVER TRUNCATE IN PLACE. `json.dump(open(dst_path, "w"))` empties the file first and writes
    # it incrementally, so a concurrent reader — a live lane's mcp-client picking the first
    # `.mcp.json` it finds, or record-review.sh during an install — can read a half-written config
    # and see ZERO MCP servers: exactly the GRAPH-UNREACHABLE symptom this change exists to remove,
    # reintroduced as a race. `cell-install.sh`'s own `install_file` writes temp+`mv` for this reason;
    # `.mcp.json` is now a cell artifact too, so it gets the same treatment.
    # ⛔ AND IT MUST NOT WIDEN WHAT IT REPLACES: `os.replace` gives the destination the TEMP file's
    # mode, which on a credential-adjacent file is the wrong direction (measured: a 0600 destination
    # came back 0644), and a dotfiles-SYMLINKED `.mcp.json` would be silently replaced by a regular
    # file. So the mode is carried over, and the write follows a symlink to its target.
    dst_real = os.path.realpath(dst_path)
    tmp = "%s.tmp.%d" % (dst_real, os.getpid())
    try:
        with open(tmp, "w", encoding="utf-8") as fh:
            # ⛔ `ensure_ascii=False`: the default re-encodes every non-ASCII character as a `\uXXXX`
            # escape, so a machine whose `.mcp.json` carries a literal `—` (the shipped
            # `templates/.mcp.base.json` does) gets that line REWRITTEN on every sync — byte churn in
            # a line the merge has no opinion about, which reads as a content change in every diff.
            json.dump(merged, fh, indent=2, ensure_ascii=False)
        if os.path.exists(dst_real):
            os.chmod(tmp, stat.S_IMODE(os.stat(dst_real).st_mode))
        os.replace(tmp, dst_real)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
