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
import sys


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

    lost = lost_entries(dst, merged)
    if lost:
        sys.stderr.write(
            "ERROR: refusing to write %s — this merge would DROP live-only entries (#682):\n" % dst_path
        )
        for item in lost:
            sys.stderr.write("  - %s\n" % item)
        sys.stderr.write("       Nothing was written; the live file is unchanged.\n")
        return 1

    with open(dst_path, "w") as fh:
        json.dump(merged, fh, indent=2)

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
