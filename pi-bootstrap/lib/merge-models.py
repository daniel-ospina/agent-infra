#!/usr/bin/env python3
"""merge-models.py — reconcile the shipped `pi-config/models.json` into a live
`~/.pi/agent/models.json` WITHOUT dropping entries that exist only live (#682).

WHY THIS FILE EXISTS (the defect, not just the code)
----------------------------------------------------
`setup.sh` used to merge with ONE per-provider dict replacement:

    merged["providers"] = {**dst["providers"], **src["providers"]}

Shipped (src) won per PROVIDER KEY, so the whole provider object was replaced —
including its `models[]` array. Any model id the live file carried and the shipped
file did not was deleted, silently, with a success message ("local providers
preserved") that was true only at provider-key granularity. Measured case
(2026-09-09): live carried `deepseek-v4.1-flash-expires-on-0910` with 1,733
recorded calls; one sync removed it, changing model resolution and cost accounting
with no error and no warning. `models.json.bak-bootstrap` is written only on the
FIRST bootstrap, so the loss was unrecoverable.

THE PRECEDENCE RULE (deliberately explicit)
-------------------------------------------
  * providers         — shipped wins per provider KEY; a provider that exists only
                        live is preserved untouched.
  * models[]          — shipped wins per model `id`. A live entry whose id shipped
                        does not declare is APPENDED after the shipped models, in
                        live order. A shipped entry wins WHOLESALE (never a field-
                        level merge): the shipped definition is a coherent unit and
                        is the thing a sync exists to refresh.
  * modelOverrides    — shipped wins per override KEY; a live-only key is preserved.
                        (The same per-provider replacement dropped these too.)
  * any other provider field — shipped wins.

PRESERVE, AND STILL FAIL CLOSED
-------------------------------
Preserving is the right default: sync runs on every session and a drop is
unrecoverable. But `lost_entries()` re-derives the invariant independently of the
merge — every provider, model id and override key present live must be present
after — and if it ever is not, this script writes NOTHING and exits 1 naming the
entries. So "preserved" is enforced, not merely printed.

Usage:  python3 merge-models.py <shipped.json> <live.json>
Exit:   0 = merged (the live path was written); 1 = refused (nothing written);
        2 = usage error.
"""

import json
import os
import shutil
import sys
import tempfile


def _str_id(entry):
    """The entry's `id` when it is a string, else None (malformed ids are kept, not matched)."""
    if not isinstance(entry, dict):
        return None
    mid = entry.get("id")
    return mid if isinstance(mid, str) else None


def _model_ids(models):
    """The set of string ids a `models[]` array declares (empty for anything else)."""
    if not isinstance(models, list):
        return set()
    return {mid for mid in (_str_id(m) for m in models) if mid is not None}


def _label(provider, entry):
    mid = _str_id(entry)
    return "%s:%s" % (provider, mid if mid is not None else "<no-id>")


def merge(src, dst):
    """Merge shipped `src` over live `dst`.

    Returns `(merged, report)`, where `report` records what the merge did:
    `replaced` (shipped entries that overwrote a live entry of the same id),
    `added` (shipped entries with no live counterpart), `models` (labels of live-only
    models preserved) and `overrides` (labels of live-only modelOverrides keys preserved).
    """
    merged = {**dst, **src} if isinstance(dst, dict) else dict(src or {})
    report = {"replaced": 0, "added": 0, "models": [], "overrides": []}

    src_providers = src.get("providers") if isinstance(src, dict) else None
    dst_providers = dst.get("providers") if isinstance(dst, dict) else None
    if not isinstance(src_providers, dict) or not isinstance(dst_providers, dict):
        # No provider map to reconcile on one side. The top-level union above already
        # keeps every live provider when shipped declares none, and `lost_entries()`
        # re-checks the invariant regardless, so this is not a silent-drop path.
        return merged, report

    providers = {**dst_providers, **src_providers}
    for name, sp in src_providers.items():
        dp = dst_providers.get(name)
        if not isinstance(sp, dict) or not isinstance(dp, dict):
            continue
        # Shipped wins per provider KEY here — but a key shipped does not carry at all
        # (e.g. a live provider that ships only `modelOverrides`, or a `models[]`
        # array on such a provider) survives from `dp` and is reconciled below.
        prov = {**dp, **sp}

        shipped_models = sp.get("models")
        live_models = dp.get("models")
        live_list = live_models if isinstance(live_models, list) else []
        if isinstance(shipped_models, list):
            shipped_ids = _model_ids(shipped_models)
            live_ids = _model_ids(live_models)
            live_only = [m for m in live_list if isinstance(m, dict) and _str_id(m) not in shipped_ids]
            prov["models"] = list(shipped_models) + live_only
            report["replaced"] += len(shipped_ids & live_ids)
            report["added"] += len(shipped_ids - live_ids)
        else:
            # Shipped declares no `models[]` for this provider (openrouter and the
            # qwen-token-plan family are `modelOverrides`-only in the shipped file):
            # `prov` already carries the live array, so every live entry is preserved.
            live_only = [m for m in live_list if isinstance(m, dict)]
        report["models"].extend(_label(name, m) for m in live_only)

        shipped_mo = sp.get("modelOverrides")
        live_mo = dp.get("modelOverrides")
        if isinstance(shipped_mo, dict) and isinstance(live_mo, dict):
            prov["modelOverrides"] = {**live_mo, **shipped_mo}
            report["overrides"].extend("%s:%s" % (name, k) for k in live_mo if k not in shipped_mo)
        elif isinstance(live_mo, dict):
            report["overrides"].extend("%s:%s" % (name, k) for k in live_mo)
        providers[name] = prov

    # A provider that exists only live is preserved by the union above; name what it carries.
    for name, dp in dst_providers.items():
        if name in src_providers or not isinstance(dp, dict):
            continue
        for m in (dp.get("models") if isinstance(dp.get("models"), list) else []):
            if isinstance(m, dict):
                report["models"].append(_label(name, m))
        if isinstance(dp.get("modelOverrides"), dict):
            report["overrides"].extend("%s:%s" % (name, k) for k in dp["modelOverrides"])

    merged["providers"] = providers
    return merged, report


def lost_entries(dst, merged):
    """Live entries that did NOT survive the merge — the #682 defect. Must always be empty.

    Derived independently of `merge()`: it reads only the live file and the produced
    result, so a merge that is edited into dropping something is caught here even if its
    own bookkeeping says otherwise.
    """
    lost = []
    dst_providers = dst.get("providers") if isinstance(dst, dict) else None
    if not isinstance(dst_providers, dict):
        return lost
    merged_providers = merged.get("providers") if isinstance(merged, dict) else None
    if not isinstance(merged_providers, dict):
        return ["providers:<all>"]

    for name, dp in dst_providers.items():
        if not isinstance(dp, dict) or name not in merged_providers:
            lost.append("provider:%s" % name)
            continue
        mp = merged_providers[name]
        if not isinstance(mp, dict):
            lost.append("provider:%s" % name)
            continue

        merged_models = mp.get("models") if isinstance(mp.get("models"), list) else []
        have_ids = _model_ids(merged_models)
        for m in (dp.get("models") if isinstance(dp.get("models"), list) else []):
            mid = _str_id(m)
            if mid is None:
                if m not in merged_models:
                    lost.append(_label(name, m))
            elif mid not in have_ids:
                lost.append(_label(name, m))

        if isinstance(dp.get("modelOverrides"), dict):
            have_mo = mp.get("modelOverrides") if isinstance(mp.get("modelOverrides"), dict) else {}
            for k in dp["modelOverrides"]:
                if k not in have_mo:
                    lost.append("override:%s:%s" % (name, k))
    return lost


def _unpreservable_shapes(live):
    """Live provider `models` values this merge would DROP rather than extend.

    A non-list `models` (an old id->definition MAP, a string, a number) is not something the merge can
    extend, and coercing it to `[]` both drops it and hides the drop from `lost_entries`. Named
    explicitly so the refusal says what to fix.
    """
    out = []
    if not isinstance(live, dict):
        return out
    providers = live.get("providers")
    if not isinstance(providers, dict):
        return out
    for name, dp in providers.items():
        if not isinstance(dp, dict):
            continue
        if "models" in dp and dp["models"] is not None and not isinstance(dp["models"], list):
            out.append("provider:%s: models is %s, not an array" % (name, type(dp["models"]).__name__))
    return out


def _read_json(path):
    with open(path) as fh:
        text = fh.read().strip()
    return json.loads(text) if text else {}


def main(argv):
    if len(argv) != 3:
        sys.stderr.write("usage: merge-models.py <shipped.json> <live.json>\n")
        return 2
    src_path, dst_path = argv[1], argv[2]
    src = _read_json(src_path)
    dst = _read_json(dst_path) if os.path.exists(dst_path) else {}
    merged, report = merge(src, dst)

    # ⛔ A live `models` that is not a list cannot be MERGED, only replaced — and both the merge and
    # `lost_entries` coerced it to `[]`, so the guard re-derived the invariant with the same coercion
    # the merge used and could never see the loss (#1878 review P2). Refuse the shape rather than
    # silently replace it: the docstring's contract is "every model id present live is present after",
    # and for this shape the honest answer is that the merge cannot honour it.
    unpreservable = _unpreservable_shapes(dst)
    if unpreservable:
        sys.stderr.write(
            "ERROR: refusing to write %s — the live file holds model entries this merge cannot preserve (#682):\n"
            % dst_path
        )
        for item in unpreservable:
            sys.stderr.write("  - %s\n" % item)
        sys.stderr.write(
            "       `models` is an ARRAY in pi's schema; this file has a different shape, so a merge\n"
            "       would replace it rather than extend it. Nothing was written; fix the live file.\n"
        )
        return 1

    lost = lost_entries(dst, merged)
    if lost:
        sys.stderr.write(
            "ERROR: refusing to write %s — this merge would DROP live-only entries (#682):\n" % dst_path
        )
        for item in lost:
            sys.stderr.write("  - %s\n" % item)
        sys.stderr.write("       Nothing was written; the live file is unchanged.\n")
        return 1

    # ⛔ ATOMIC, and this is the whole point of the guard above (#1878 review P0). `open(path, "w")`
    # TRUNCATES: the live file is the ONLY copy (the `.bak-bootstrap` snapshot is first-run-only), so a
    # write that dies part-way left it truncated and unparseable — after `lost_entries()` had already
    # approved the content. Two distinct losses followed, both unrecoverable: a truncated-but-nonempty
    # file makes every later setup.sh run abort inside `_read_json`, and a file truncated to ZERO makes
    # the NEXT run read `{}`, find nothing to preserve, and exit 0 having dropped the live state for
    # good. Serialise to a sibling temp, fsync, then `os.replace` — a rename is atomic within a
    # filesystem, so a reader sees the old file or the new one, never a prefix.
    payload = json.dumps(merged, indent=2)
    dst_dir = os.path.dirname(os.path.abspath(dst_path)) or "."
    tmp_path = None
    try:
        fd, tmp_path = tempfile.mkstemp(prefix=".models.json.", suffix=".tmp", dir=dst_dir)
        with os.fdopen(fd, "w") as fh:
            fh.write(payload)
            fh.flush()
            os.fsync(fh.fileno())
        # Keep the live file's permissions: mkstemp creates 0600, and a models.json that suddenly is
        # not group/world readable would break every consumer running as another user.
        try:
            shutil.copymode(dst_path, tmp_path)
        except OSError:
            pass
        os.replace(tmp_path, dst_path)
        tmp_path = None
    except OSError as exc:
        sys.stderr.write("ERROR: could not write %s (%s) — the live file is UNCHANGED.\n" % (dst_path, exc))
        return 1
    finally:
        if tmp_path:
            try:
                os.unlink(tmp_path)
            except OSError:
                pass

    print("    models.json merged (shipped wins per provider/model/override key; live-only entries preserved)")
    print(
        "    models.json: replaced %d model(s) with shipped definitions, added %d shipped-only model(s)"
        % (report["replaced"], report["added"])
    )
    models = sorted(report["models"])
    print(
        "    models.json: preserved %d live-only model(s)%s"
        % (len(models), ": " + ", ".join(models) if models else "")
    )
    overrides = sorted(report["overrides"])
    if overrides:
        print(
            "    models.json: preserved %d live-only modelOverrides key(s): %s"
            % (len(overrides), ", ".join(overrides))
        )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
