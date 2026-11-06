#!/usr/bin/env bash
# key-gate.sh — the LAST assertion before `pi` is spawned: the model credential its provider resolves
# must hold a value IN THE ENVIRONMENT THE LANE WILL ACTUALLY RUN WITH (agent-infra#3331).
#
# Callers source this and call ONE function:
#     . key-gate.sh
#     key_gate_assert "lane 42" "${HOME:-}"      # one verdict line (+ a warning line on one arm), 0 or KEY_GATE_REFUSED
#
# THE DEFECT THIS REFUSES — measured 2026-11-02 on two cloud cells. A lane runs with
# `HOME=/tmp/cell-home`, which is REQUIRED: the operational layer (`record-review.sh`, the gh shim, the
# extensions) lives under `$CELL_HOME/.pi/agent`. But the model credential lives in
# `/home/cmux/keys.env` — under the ACCOUNT home — and `lane-env.sh` sources `${ENV_FILE:-$HOME/keys.env}`,
# i.e. the redirected one. So the single setting that makes the operational layer work is the setting
# that hides the credential. `pi` started, found no key, and was gone:
#
#     No API key found for the selected model.
#
# ⛔ SCOPE — READ THIS BEFORE TREATING A GREEN GATE AS "THE LANE WILL RUN" (corrected against #3331's own
# measurement record, review cycle 1). The key was ONE of FOUR causes that record falsified: a lane with
# `keys.env` sourced and `api-key-errors=0` STILL died silently, and the cause it VALIDATED is a lane
# launched from a directory that is not a git repository (`fatal: not a git repository`). This gate
# closes the REPORTING half of that class — "No API key found" stops being a silent end — and it does
# not make a lane run. The launch-directory rule is `skills/cmux-cells/SKILL.md`.
#
# ⛔ THE MODEL IS HALF OF THE QUESTION, AND IT WAS NOT NAMED (agent-infra#3443, measured 2026-11-04 on
# cell-5). #3331's record says the remedy is "source `keys.env`"; the file on that cell holds ONLY
# `GH_TOKEN`, so the remedy cannot fix this and anybody following it repeats the failure. What worked on
# the same box was `pi -p --no-session --model deepseek/deepseek-flash` — i.e. the MODEL FLAG. (What the
# gate does NOT claim is why `pi` had no model available to it: the sentence it printed names no provider,
# which is what pi says only when nothing was, and this file does not reproduce its resolution path.)
# So this gate now names the model on every line, resolves the provider the
# model itself names when nothing else does, and reports the model a BARE `pi` would start on when that
# one is not verifiably provisioned (`key_gate_box_default_assert`) — the shape that produced
# `No API key found for the selected model.`
# ⛔ AND THE MECHANISM OF A STARTUP PIN THAT IS NOT PROVISIONED IS **SILENT SUBSTITUTION, NOT DEATH** — a
# correction, because this file's first cut of the box-default arm claimed the box would die and that is
# FALSE against the vendor source on this box (pi 1.2.0, `dist/core/model-resolver.js::findInitialModel`):
#     // 3. Try saved default from settings if auth is configured.
#     if (defaultProvider && defaultModelId) {
#         const found = modelRuntime.getModel(defaultProvider, defaultModelId);
#         if (found && modelRuntime.hasConfiguredAuth(found.provider)) { … return {model…}; }
#     }
#     // 4. Try first available model with valid API key
#     const availableModels = [...modelRuntime.getAvailableSnapshot()];
#     if (availableModels.length > 0) { … }
# So an unprovisioned pin makes `pi` run whatever model it DOES find — nobody pinned it, and it spends
# tokens on it: the #2208 class this repo already names. That is the fact the box-default line reports, and
# it is why `check=warn` there never refuses a LANE. (The recorded sentence `No API key found for the
# selected model.` is the symptom agent-infra#3443 measured on cell-5, on that box's pi build; this file
# does not claim to reproduce its exact resolution path, and says so rather than asserting a mechanism it
# has not read.)
# Naming the model is what makes either shape readable instead of anonymous.
#
# ⛔ AND NOTHING SAID SO — that is the real defect, and the reason this is category A rather than
# friction. The dispatcher's `nohup … &` had returned (so the dispatch record said "launched"), the log
# simply STOPPED (a print-mode `pi` buffers its output, so a silence reads exactly like "still
# working"), and a monitor using `pgrep -f "pi -p"` matched the DIAGNOSTIC's own command line. Three
# independent false-positive signals, stacked on one event.
#
# ⛔ WHY A PRE-FLIGHT GATE AND NOT A POLLER. A poller watches a broken instrument; it does not fix it,
# and it adds an unsupervised process of exactly the kind this repo has had to kill twice in one
# session. This is the same shape as the two refusals `lane.sh` already carries — `brief-gate.sh` (80)
# and `repo-target.sh` (72): cheap, deterministic, loud, and impossible to mistake for "still working".
# It refuses with its OWN code because its remedy is its own: not "re-author the brief" (80), not "fix
# the worktree's origin" (72), not "wait for load" (75) — put the credential in the environment the
# lane runs with, then re-dispatch.
#
# ⛔ POLARITY: IT REFUSES ONLY ON A POSITIVE READING. When the variable NAME cannot be determined — no
# `models.json`, a literal `apiKey`, an unparseable file, no python3, or a provider `pi` authenticates
# itself — the gate prints `check=skipped` and refuses NOTHING. Our own inability to read a datum must
# never become a refusal loop that stops the fleet; `worker-terminal.sh`'s credential gate states the
# same rule for the same reason (#2210), and this is that rule applied one layer down.
#
# ⛔ AND THE NAME IT RESOLVES IS THE SAME ONE `pi` RESOLVES. `models.json`'s `providers.<p>.apiKey` is a
# `${VAR}` template, `<p>` is `${PI_LANE_PROVIDER:-deepseek}` — the identical default `run_agent`
# (spawn-gate.sh) uses to build the `pi` argv, resolved in the SAME process after `lane-env.sh` has
# sourced the box's file. So the gate and the spawn cannot disagree about which provider is being checked.
# ⛔ THE SPLIT WITH `worker-terminal.sh` IS DELIBERATE AND IS NOW PINNED AS A SPLIT (review round 4, P2):
# worker-terminal runs BEFORE any source, so it reads the provider from the box's env FILE; this gate runs
# AFTER `lane-env.sh` has exported it, so it reads the ENVIRONMENT — which is the same question
# `run_agent` asks, because `run_agent` is what actually builds the argv. The two must therefore agree in
# the production shape (file exported into the env) and must NOT be expected to agree when the environment
# is silent — where the file names a provider, the launcher prepares that provider's credential while this
# gate correctly falls back to the same default `run_agent` will use. `key-gate.test.sh` pins BOTH halves
# (4a: identical answers over the shared rule; 4b/4c: the production shape agrees, and the silent-env case
# resolves `run_agent`'s own default), so a change to either side's provider SOURCE reddens something.
#
# ⛔ AND `pi` DOES NOT ALWAYS NEED THE ENVIRONMENT VARIABLE — `auth.json` COMES FIRST (review round 3,
# P1, measured). `pi`'s resolution is STORED CREDENTIAL (`$HOME/.pi/agent/auth.json`, what `pi /login`
# writes) → environment → the `models.json` template. So a box whose lane provider was logged in with
# `/login` runs fine with the variable unset, and a gate that refused on the variable alone refused a
# lane that WOULD have worked — the false-block direction, on a supported configuration (the provider
# is settable from `keys.env`, and the fleet's own `provider-credential.test.sh` documents the store).
# `key_gate_stored_credential` is therefore consulted BEFORE the refusal, and its answer is the third
# "cannot say" arm: it asserts nothing.

# The refusal carries its own status: 82 is unassigned elsewhere in this tree (70-81 are spawn-gate's,
# repo-target's and brief-gate's; 93-98 are the worker launch-line guards'), and a shared code would
# make two opposite remedies indistinguishable — the defect #2293 fixed for 73/74.
KEY_GATE_REFUSED=82

# Set by key_gate_assert, for the caller's terminal-line reason token. Initialised because every caller
# runs under `set -u`.
KEY_GATE_VAR=""
KEY_GATE_PROVIDER=""
KEY_GATE_REASON=""
KEY_GATE_MODELS_JSON=""
# ⛔ THE MODEL IS PART OF THE VERDICT, NOT DECORATION (agent-infra#3443). `provider=deepseek` alone does
# not tell an operator which model was asserted, and the measured failure names the model and nothing
# else ("No API key found for the selected model").
KEY_GATE_MODEL=""

# ── THE TEMPLATE GRAMMAR, MIRRORED FROM `pi` RATHER THAN RE-INVENTED (review cycle 1, P1+P2) ──
# `pi` does NOT treat an apiKey / a stored `key` as an opaque string: `dist/core/resolve-config-value.js`
# parses it into LITERAL and ENV parts (`$NAME`, `${NAME}`, with `$$`/`$!` as escapes), a leading `!`
# makes it a COMMAND, and `isConfigValueConfigured` answers "configured" only when EVERY referenced name
# resolves (env-map first, then process env). Three shapes were measured against the vendor module on
# 2026-11-04 with this gate's old readers:
#   models.json apiKey  "sk-${KEY}"      -> pi resolves it, the old `re.fullmatch` did NOT -> gate said
#                                          `cannot-resolve` and refused NOTHING while pi died silently
#   auth.json   key     "${NO_SUCH_VAR}" -> pi resolves it to undefined (no credential), the old
#                                          `nonblank()` said "holds a credential" -> gate went quiet and
#                                          pi died with the exact line #3331 exists to remove (FALSE PASS)
# So the two probes below implement pi's own two rules and nothing else:
#   MODE=var    print EVERY env name the models.json apiKey template references (one per line); a
#               literal apiKey prints nothing ("cannot say"), a `!command` prints nothing ("cannot say").
#   MODE=store  exit 0 = a credential that RESOLVES to a non-blank value, 1 = no credential (fall
#               through to the environment check), 3 = "cannot say" (`!command`, unreadable) — which the
#               caller reports as its OWN reason so it never claims a credential it did not verify.
# ⛔ POLARITY IS UNCHANGED: an unresolvable datum answers "cannot say" and refuses nothing (#2210).
# Separate script, same doctrine: argv = <agent-dir settings.json> <trust.json> <cwd>. Prints `trusted`,
# `untrusted` or NOTHING (cannot say — an unreadable-but-present trust.json, or a cwd that is not absolute).
_KEY_GATE_TRUST_PY='
import json, os, sys


def load(p):
    try:
        # R15: pi reads trust.json/settings.json through stripBom (trust-manager.js:77, settings-manager.js:269); a
        # BOM made this probe answer "cannot say" on a store pi reads, so the startup-pin check went silent on any
        # box whose operational layer writes one.
        with open(p, encoding="utf-8-sig") as fh:
            return json.load(fh)
    except FileNotFoundError:
        return None
    except Exception:
        raise SystemExit(0)   # present but unreadable: cannot say, never a guess


cfg = load(sys.argv[1])
cfg = cfg if isinstance(cfg, dict) else {}
tr = load(sys.argv[2])
if tr is not None and not isinstance(tr, dict):
    raise SystemExit(0)
# R15: pi validates EVERY entry and refuses the whole store on a non true/false/null value (trust-manager.js:87-90 -
# measured: `Error: Invalid trust store ...: value for "..." must be true, false, or null`), which is fatal at startup.
# Walking past such a value issued a verdict about a store pi does not have; the honest answer is cannot-say.
if isinstance(tr, dict):
    for _k, _v in tr.items():
        if _v is not None and _v is not True and _v is not False:
            raise SystemExit(0)
cwd = os.path.realpath(sys.argv[3])
dec = None
if isinstance(tr, dict):
    cur = cwd
    while True:
        v = tr.get(cur)
        if v is True or v is False:
            dec = v
            break
        up = os.path.dirname(cur)
        if up == cur:
            break
        cur = up
if dec is not None:
    print("trusted" if dec else "untrusted")
    raise SystemExit(0)
# No recorded decision: pi prompts, and a `-p` session has no UI — so only `always` grants trust. That is
# `project-trust.js:38-52` with `hasUI:false`, and `settings-defaults.js:28` (`ask`) is the absent case.
print("trusted" if cfg.get("defaultProjectTrust") == "always" else "untrusted")
'
_KEY_GATE_PY='
import json, os, re, sys


def strip_jsonc(txt):
    """R15: mirror pi exactly - dist/utils/json.js strips ONLY line comments and TRAILING COMMAS, leaving string
    literals untouched. It does NOT strip block comments (pi refuses such a file and discards models.json entirely),
    so doing it here made the gate certify a provider/credential from a file pi never loads: measured, pi fell back
    to the built-in provider while the gate refused 82 naming the file variable, and in the other direction printed
    a green check for a variable pi does not consult."""
    q = chr(34)
    STR = q + "(?:\\\\.|[^" + q + "\\\\])*" + q
    txt = re.sub(STR + "|//[^\\n]*",
                 lambda m: m.group(0) if m.group(0)[0] == q else "", txt)
    txt = re.sub(STR + "|,(\\s*[}\\]])",
                 lambda m: m.group(1) if m.group(1) else (m.group(0) if m.group(0)[0] == q else ""), txt)
    return txt


def _reject_constant(tok):
    # ⛔ THE THREE TOKENS `JSON.parse` REFUSES AND PYTHON ACCEPTS (round 23, P2, measured). Raising ValueError puts
    # them on the same path as any other parse failure, which is the answer pi gives: "discarded", not "valid".
    raise ValueError("non-JSON numeric constant: %s" % tok)


def read_json(path, jsonc=False):
    """R14: pi reads these files with stripBom (and stripJsonComments for models.json) - auth-storage.js:175,305,426,
    settings-manager.js:266, trust-manager.js, model-config.js:116. Python json.load rejects a BOM, so the same file pi
    consumed came back UNPARSEABLE here: for store that was a POSITIVE no-credential and a false 82 on a box pi runs
    (measured), and for models.json it made the gate INERT (check=skipped, rc 0) on a file pi uses."""
    # ⛔ EMPTY IS AN EMPTY STORE, NOT AN UNREADABLE ONE (round 24, P1, measured): `parseStorageData` starts with
    # `if (!content) { return {}; }` (`auth-storage.js:301-305`), and `settings-manager.js:262-267` does the same, so a
    # 0-byte `auth.json` (an interrupted atomic write, `touch`, `: > auth.json`) leaves pi running on the environment
    # while this reader raised - and the store arm mapped that to rc 6, REFUSING 82 a box pi runs. Measured: 0-byte
    # store + `DEEPSEEK_API_KEY` exported -> `pi -p` made the call (401 ****BBBB), the gate said
    # `reason=auth-store-unreadable`. For `models.json` the answer is the same by a different route: pi\x27s loader
    # `JSON.parse`s "" and discards the file, and `{}` is discarded too (the document requires `providers`).
    # ⛔ AND THE SAME FOR NON-UTF-8 BYTES (round 24, P1, measured): Node decodes with U+FFFD replacement and never
    # throws (`readFileSync(path, "utf-8")`, `auth-storage.js:175`), so a latin-1 `key` is an ordinary string to pi
    # while Python raised UnicodeDecodeError -> rc 6 -> a false 82. `errors="replace"` is exactly Node\x27s behaviour.
    # ⛔ EMPTINESS IS A PROPERTY OF THE BYTES, NOT OF THE DECODED TEXT (round 25, P1, measured): pi tests the RAW
    # string (`parseStorageData`\x27s `if (!content) { return {}; }`, `auth-storage.js:301-305`) and only strips the BOM
    # inside the `JSON.parse` call - so a file containing ONLY a BOM is NON-EMPTY and unparseable to pi
    # (`Unexpected end of JSON input`, fatal), while decoding it as `utf-8-sig` first turned it into "" and this rule
    # called it an empty store: gate `check=ok`, lane dead. Reading bytes first keeps the 0-byte answer (pi: `{}`) and
    # hands the BOM-only shape to the parser, which is the answer pi gives.
    with open(path, "rb") as f:
        raw = f.read()
    if not raw:
        return {}
    txt = raw.decode("utf-8-sig", errors="replace")
    if jsonc:
        txt = strip_jsonc(txt)
    # ⛔ JSON.parse REJECTS `Infinity`/`-Infinity`/`NaN`, PYTHON\x27S json.loads ACCEPTS THEM (round 23, P2, measured):
    # pi parses models.json/auth.json with a bare `JSON.parse` (`model-config.js:118-131`, `auth-storage.js:301-306`), so
    # a document carrying `"contextWindow": Infinity` is DISCARDED by pi while this reader returned a value
    # `_ok_num` graded admissible (`inf > 0`) - a `check=ok` naming a variable from a file pi never loaded, the exact
    # false-PASS class this file exists to prevent. `parse_constant` is the hook Python offers for precisely those
    # three tokens. ⛔ AND A NON-FINITE RESULT IS ITS OWN CASE (round 24, P2, measured): `1e999` parses on BOTH sides,
    # but pi\x27s validator then rejects the non-finite number and discards the document - `_number` refuses it too (the
    # earlier note here claimed both sides accepted it, which was wrong and would have talked the next reader out of
    # checking).
    return json.loads(txt, parse_constant=_reject_constant)

NAME = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")


def template_parts(cfg):
    """-> (kind, [env names]) mirroring pi\x27s parseConfigValueTemplate."""
    if cfg.startswith("!"):
        return "cmd", []
    names, i, n = [], 0, len(cfg)
    while i < n:
        j = cfg.find("$", i)
        if j < 0:
            break
        nxt = cfg[j + 1:j + 2]
        if nxt in ("$", "!"):
            i = j + 2
            continue
        if nxt == "{":
            end = cfg.find("}", j + 2)
            if end < 0:
                i = j + 1
                continue
            nm = cfg[j + 2:end]
            if NAME.fullmatch(nm) and nm not in names:
                names.append(nm)
            i = end + 1
            continue
        m = NAME.match(cfg, j + 1)
        if m:
            if m.group(0) not in names:
                names.append(m.group(0))
            i = m.end()
            continue
        i = j + 1
    return "template", names


def resolve(cfg, env):
    """-> (status, value) with status in {ok, missing, cmd}; pi\x27s resolveConfigValue + truthiness."""
    kind, names = template_parts(cfg)
    if kind == "cmd":
        return "cmd", None
    if not names:
        return ("ok", cfg) if cfg.strip() else ("missing", None)
    out = ""
    for nm in names:
        v = None
        if isinstance(env, dict):
            v = env.get(nm) or None
        if v is None:
            v = os.environ.get(nm) or None
        if v is None:
            return "missing", None
        out += v
    return ("ok", out) if out.strip() else ("missing", None)


try:
    doc = read_json(sys.argv[1], jsonc=(sys.argv[2] == "var"))
except FileNotFoundError:
    # `var` and `default` are the two "print nothing = cannot say" modes, and for them an ABSENT file is a real
    # answer: no template to resolve, no pin to assert. Only `store` distinguishes absence (rc 1) from
    # unreadability, because only it asserts a positive "no credential".
    raise SystemExit(0 if sys.argv[2] in ("var", "default") else 1)
except Exception:
    # ⛔ A PRESENT-BUT-UNPARSEABLE `default` FILE IS NOT AN ABSENT PIN (fresh-context review round 4, P3,
    # measured): `default` mode reports an absence POSITIVELY (`no-default-model` = "this box pins nothing"), so
    # a corrupt settings.json must not be folded into it — rc 4 makes it `settings-unreadable`, which refuses
    # nothing and names the real remedy. `var` keeps the cannot-say answer (it prints nothing either way).
    # ⛔ rc 4 = CANNOT SAY, FOR `store` TOO (round 14, P1, measured): rc 1 is the POSITIVE "no credential", and a
    # store that failed to PARSE is not that — with a BOM the gate refused 82 a box pi runs, on a file pi read fine.
    # `var` stays 0 (it prints nothing either way); `default` and `store` say "cannot say".
    raise SystemExit(6 if sys.argv[2] == "store" else (4 if sys.argv[2] == "default" else 0))

if sys.argv[2] == "default":
    # MODE=default — the startup pair a BARE `pi` would use, per pi\x27s OWN settings.json (`docs/settings.md`:
    # `defaultProvider` / `defaultModel`, "Startup provider / model ID"). Prints "<provider>\t<model>" and
    # prints NOTHING when the file pins neither; EITHER HALF MAY BE EMPTY, and the caller decides — `pi`
    # merges settings PER KEY (round 3, F2/P2: `deepMergeSettings` → `deepMergeObjects`,
    # `settings-manager.js:95-99`), so a project file that pins only `defaultProvider` yields a REAL pair with
    # the OTHER half from the agent-dir file. Treating a half pin as "this file pins nothing" made the probe
    # fall back to the agent-dir pair and print `check=ok` for a pair `pi` never starts on.
    if not isinstance(doc, dict):
        raise SystemExit(0)
    # ⛔ EACH HALF CARRIES ITS OWN STATE, BECAUSE `pi` MERGES PER KEY (fresh-context review round 5, P3,
    # measured): `deepMergeObjects` treats `null` as a VALUE (`isMergeableObject(null) === false`), so a project
    # file pinning `"defaultProvider": null` OVERRIDES the agent-dir one and step 3 is not attempted. Mapping
    # a null/empty half to "this file pins nothing" fell back to the agent-dir half and printed `check=ok` for a
    # pair `pi` never starts on. `s` = set, `n` = present but cleared/empty (it OVERRIDES), `a` = absent (the
    # lower-priority file decides).
    # ⛔ `enabledModels` MAKES THE PIN A GUESS, SO IT IS A CANNOT-SAY (round 8, P2, verified against the vendor
    # source): `main.js:660` builds `scopedModels` from `parsed.models ?? settingsManager.getEnabledModels()` and
    # `main.js:389-403` runs BEFORE `findInitialModel` — when the pin is not among the scoped models it installs
    # `scopedModels[0]` as the startup model, with NO `hasConfiguredAuth` check at all. Resolving a pattern list to
    # model ids needs the model registry, which this gate does not have, so a box that sets the key gets the honest
    # `enabled-models-scoped` skip instead of a verdict from a pin `pi` may not use in either direction (a false 82
    # when the scoped model is the provisioned one, a false `check=ok` when it is not).
    _em = doc.get("enabledModels")
    # ⛔ THREE STATES, BECAUSE THE SCOPE IS REPLACED, NOT MERGED (round 10, P3, verified): `enabledModels` is an
    # ARRAY, and `deepMergeObjects` assigns arrays wholesale — so a trusted project `[]` CLEARS the agent-dir
    # list (`getEnabledModels() === []`, `modelPatterns.length > 0` false, the pin is used again). Collapsing
    # "present but empty" into "absent" made the project clear invisible and kept the agent-dir scope alive:
    # `n` = present-and-empty (REPLACES), `1` = present-and-non-empty, `` = absent.
    # ⛔ `null` IS A REPLACEMENT, NOT AN ABSENCE (round 12, P2, measured on the vendor dist): `deepMergeObjects`
    # treats `null` as a VALUE, so a trusted project `{"enabledModels": null}` replaces the agent-dir list with
    # `null` — `getEnabledModels()` returns null, `modelPatterns.length > 0` is false, and `findInitialModel`
    # step 3 uses the pin, exactly as with `[]`. Folding null into "key absent" kept the agent-dir scope alive and
    # answered `enabled-models-scoped` for a state pi treats as unscoped — two identical inputs with opposite
    # verdicts. Only a MISSING key is an absence.
    # ⛔ AND A NON-EMPTY STRING IS A SCOPE (round 14, P2, measured against the vendor resolver): `main.js:660`
    # passes `getEnabledModels()` straight to `resolveModelScope`, which does `for (const pattern of patterns)` — on a
    # string that iterates CHARACTERS, still resolving a scope (measured: `"deepseek/*"` resolved both models). The
    # three-state classifier treated every non-list as "empty", so a string scope printed a green `check=ok` for a
    # pin pi does not start on. Only `[]`, `null` and other lengths-0 values are "present and empty".
    if "enabledModels" not in doc:
        scoped = ""
    elif isinstance(_em, list) and len(_em) > 0:
        scoped = "1"
    elif isinstance(_em, str) and _em:
        scoped = "1"
    else:
        scoped = "n"

    def half(k):
        if k not in doc:
            return ("", "a")
        v = doc[k]
        # ⛔ NO `.strip()` (round 6, P2, measured): `pi` uses these two strings as EXACT keys —
        # `getModel(provider, id)` is `providers.get(provider)` plus `model.id === id` (`pi-ai/dist/models.js`) —
        # so a padded pin like `" deepseek "` matches NOTHING and pi substitutes, while a trimming gate reported
        # `check=ok` for it. The raw value is what gets asserted; a space-padded pin then shows up verbatim in the
        # skip line (pair cannot be resolved → nothing asserted, never a false PASS).
        if isinstance(v, str):
            return (v, "s") if v else ("", "n")
        return ("", "n")

    dp, dps = half("defaultProvider")
    dm, dms = half("defaultModel")
    if dps == "a" and dms == "a" and not scoped:
        raise SystemExit(0)
    # ⛔ NO `provider/model` SPLITTING HERE (fresh-context review round 2, P2, measured). That form is the
    # CLI\x27s rule (`resolveCliModel`), NOT the startup rule: `findInitialModel` step 3 reads
    # `if (defaultProvider && defaultModelId)` and calls `modelRuntime.getModel(dp, dm)` with the RAW strings
    # (`dist/core/model-resolver.js:502-503`, `settings-manager.js` never normalises `defaultModel`). A file
    # pinning only `defaultModel: "venice/venice-uncensored"` therefore matches NO step-3 pair, `pi` falls to
    # step 4, and a gate that split the prefix would have asserted venice\x27s credential for a model `pi`
    # would never start on — a false `check=ok` on the exact fact the line claims. Printing an empty provider
    # keeps the honest answer: the `default-model-provider-unknown` cannot-say arm.
    print("%s\t%s\t%s%s\t%s" % (dp, dm, dps, dms, scoped))
    raise SystemExit(0)

if sys.argv[2] == "var":
    # R16: pi DISCARDS the whole models.json on any schema violation and runs on its built-ins (`model-config.js:121-126`
    # + `schemas/models.schema.json`), so a gate that reads a credential out of the discarded file certifies a variable
    # pi never consults - and, in the other direction, REFUSES 82 a box whose lane would run on a built-in key. Measured
    # with one entry missing the required `id`. This is the step after the parse, and it is the same class as the block
    # comment: our reader must not be more permissive than pi about what the FILE IS. A structural check is enough here;
    # on anything doubtful the answer is cannot-say (print nothing), never a verdict.
    def _valid_models(d):
        # R18: mirror the TYPE of every key `schemas/models.schema.json` types, at the level it types it. pi validates
        # the whole document with a compiled typebox validator and DISCARDS models.json on any violation
        # (`model-config.js:73,116-126`), so an incomplete mirror answers a verdict about a file pi never loaded: R17
        # checked `models[].id/contextWindow/maxTokens` and measured both polarities on `"cost":"cheap"` - a STRING
        # where the schema wants an object - which pi rejects (so the built-in provider and its key are what actually
        # run, and the refusal was false 82) while the gate asserted the discarded file\x27s variable (`check=ok`).
        # Both docs use `patternProperties` and NO `additionalProperties: false`, so an UNKNOWN key is legal at any
        # type: only the keys listed here are checked, and a field pi ignores must never blind this gate.
        def _nonempty_str(v):
            return isinstance(v, str) and v != ""

        def _number(v):
            # ⛔ NON-FINITE IS NOT A NUMBER TO pi (round 24, P2, measured): `JSON.parse("1e999")` yields `Infinity`,
            # and pi\x27s validator answers `Invalid models.json schema: ... must be number` and DISCARDS the file, while
            # `inf > 0` made this gate answer "valid" and print `check=ok var=...` out of a document pi never loaded.
            return (not isinstance(v, bool) and isinstance(v, (int, float))
                    and v == v and v not in (float("inf"), float("-inf")))

        def _ok_num(v):          # {"type": "number", "exclusiveMinimum": 0}
            return _number(v) and v > 0

        def _ok_int(v):          # {"type": "integer", "minimum": 1}
            return _number(v) and int(v) == v and v >= 1

        def _str_map(v):         # {"type": "object", "patternProperties": {"^.*$": {"type": "string"}}}
            return isinstance(v, dict) and all(isinstance(x, str) for x in v.values())

        def _ok_input(v):        # {"type": "array", "items": {"enum": ["text", "image"]}}
            return isinstance(v, list) and all(x in ("text", "image") for x in v)

        LEVELS = ("off", "minimal", "low", "medium", "high", "xhigh", "max")

        def _ok_level_map(v):
            # `ThinkingLevelMap` types ONLY those seven keys ({"anyOf": [string, null]}) and has no
            # `additionalProperties: false`, so an unknown key is legal at ANY type: iterating every value made
            # the gate abstain on a file pi loads (round 19, P3, measured `{"turbo":{...}}` -> gate skipped,
            # pi LOADED), which is the #3331 silence on a box whose credential is real.
            return isinstance(v, dict) and all(
                v[k] is None or isinstance(v[k], str) for k in LEVELS if k in v)

        def _ok_cost(v):         # ModelCost: FOUR required numbers, plus optional tiers with five each
            if not isinstance(v, dict):
                return False
            for _k in ("input", "output", "cacheRead", "cacheWrite"):
                if not _number(v.get(_k)):
                    return False
            if "tiers" not in v:
                return True
            # ⛔ `"tiers": null` is PRESENT and pi DISCARDS the file for it (round 20, P1, measured); the old
            # `v.get("tiers") is None` folded null into absent - the same null-vs-absent mistake this PR fixes for
            # `defaultProvider`/`enabledModels`, one file over.
            tiers = v["tiers"]
            if not isinstance(tiers, list):
                return False
            for t in tiers:
                if not isinstance(t, dict):
                    return False
                for _k in ("inputTokensAbove", "input", "output", "cacheRead", "cacheWrite"):
                    if not _number(t.get(_k)):
                        return False
            return True

        def _ok_input_limits(v):
            # ModelInputLimits types its CHILDREN, not just the container (round 19, P1, measured): pi DISCARDED
            # `{"images":{"maxPerMessage":0}}` and `{"images":{"resize":{"maxWidth":"wide"}}}` while this helper
            # answered "dict, fine" - the same false-ok class one level deeper than R18.
            if not isinstance(v, dict):
                return False
            if "maxRequestBytes" in v and not _ok_int(v["maxRequestBytes"]):
                return False
            if "images" in v:
                im = v["images"]
                if not isinstance(im, dict):
                    return False
                for _k in ("maxPerMessage", "maxPerRequest"):
                    if _k in im and not _ok_int(im[_k]):
                        return False
                if "resize" in im:
                    rs = im["resize"]
                    if not isinstance(rs, dict):
                        return False
                    for _k in ("maxWidth", "maxHeight", "maxBytes"):
                        if _k in rs and not _ok_int(rs[_k]):
                            return False
                    if "jpegQuality" in rs:
                        q = rs["jpegQuality"]
                        if not (_ok_int(q) and q <= 100):
                            return False
            return True

        def _ok_prompt_cache(v):
            # `ModelPromptCache` types `short` and `long` as number > 0 and, again, allows unknown keys at any
            # type - so only those two are checked (round 19, P3, measured `{"weird":"x"}` -> pi LOADED).
            if not isinstance(v, dict):
                return False
            return all(_ok_num(v[k]) for k in ("short", "long") if k in v)

        # ProviderCompat (`schemas/models.schema.json` -> `$defs/ProviderCompat`) types ~40 leaves and is live config
        # (the box\x27s own models.json carries `compat` on three providers). pi DISCARDS the whole file on one wrong
        # leaf, so `isinstance(v, dict)` was one level too shallow - the R18/R19 class left in the largest typed
        # subtree (round 20, P1, measured: `supportsStore: "yes"` -> pi DISCARDED, gate asserted the credential).
        COMPAT_BOOLS = (
            "supportsStore", "supportsDeveloperRole", "supportsReasoningEffort", "supportsUsageInStreaming",
            "supportsFinishReason", "requiresToolResultName", "requiresAssistantAfterToolResult",
            "requiresThinkingAsText", "requiresReasoningContentOnAssistantMessages", "zaiToolStream",
            "supportsThinkingTokenBudget", "supportsOpenAIGrammarTools", "supportsMidConvoSystemMessages",
            "supportsMidConvoToolAdditions", "supportsStrictMode", "sendSessionAffinityHeaders",
            "supportsLongCacheRetention", "supportsAdditionalTools", "supportsToolSearch",
            "supportsExplicitPromptCacheMode", "supportsMaxOutputTokens", "supportsEagerToolInputStreaming",
            "supportsCacheControlOnTools", "supportsTemperature", "forceAdaptiveThinking", "allowEmptySignature",
            "supportsStrictTools", "supportsMidConvoEffort", "supportsMidConvoToolChanges",
        )
        TEMPLATE_VARS = ("thinking.enabled", "thinking.effort", "thinking.budget")
        COMPAT_CONSTS = {
            "maxTokensField": ("max_completion_tokens", "max_tokens"),
            "thinkingFormat": ("openai", "openrouter", "deepseek", "together", "baseten", "zai", "qwen",
                               "chat-template", "qwen-chat-template", "string-thinking", "ant-ling"),
            "thinkingTokenBudgetField": ("thinking_token_budget", "thinking_budget", "thinking_budget_tokens"),
            "sessionAffinityFormat": ("openai", "openai-nosession", "openrouter"),
            "cacheControlFormat": ("anthropic",),
        }

        def _ok_template_map(v):
            # chatTemplateKwargs/chatTemplateArgs: `patternProperties {"^.*$": string|number|boolean|null|{"$var":\u2026}}`
            if not isinstance(v, dict):
                return False
            for x in v.values():
                if x is None or isinstance(x, (str, bool)) or _number(x):
                    continue
                # `$var` is an ENUM (`thinking.enabled|thinking.effort|thinking.budget`, `required`), and
                # `omitWhenOff` is a boolean (round 21, P2, measured: pi DISCARDS
                # `{"$var":"bogus"}` while "is a non-empty string" accepted it).
                if (isinstance(x, dict) and x.get("$var") in TEMPLATE_VARS
                        and ("omitWhenOff" not in x or isinstance(x["omitWhenOff"], bool))):
                    continue
                return False
            return True

        # `openRouterRouting`/`vercelGatewayRouting` type their leaves PER KEY (round 22, P1, measured with a
        # differential over the whole schema: the leaf-kind test accepted `allow_fallbacks: "yes"`, `order: "x"`,
        # `max_price: {"prompt": null}` and `vercelGatewayRouting.only: "x"` - 30 mismatches, all here - while pi
        # DISCARDS the document and the provider disappears from `--list-models`, so the gate certified a variable
        # from a file pi never loaded).
        def _num_or_str(x):
            return isinstance(x, str) or _number(x)

        def _ok_price_map(v):
            # `max_price` types its NAMED leaves `number|string` and carries NO `additionalProperties: false`, so an
            # unknown key there is legal at any type (measured on the compiled schema: 0 occurrences). Iterating every
            # value instead made a legal `{"weird": true}` go cannot-say - the round-19 blindness class, on the very
            # file pi loads.
            if not isinstance(v, dict):
                return False
            return all(_num_or_str(v[k]) for k in ("prompt", "completion", "image", "audio", "request") if k in v)

        def _ok_percentiles(v):
            # throughput/latency -> `anyOf number | {p50,p75,p90,p99: number}`, same no-additionalProperties rule
            if _number(v):
                return True
            if not isinstance(v, dict):
                return False
            # ⛔ `_number`, NOT A LOCAL TUPLE CHECK (round 25, P2, measured): `preferred_min_throughput: 1e999` (and a
            # non-finite percentile) make pi discard the document; accepting them here certified the credential.
            return all(_number(v[k]) for k in ("p50", "p75", "p90", "p99") if k in v)

        def _ok_sort(v):
            # `anyOf string | {by: string, partition: string|null}`, neither key required
            if isinstance(v, str):
                return True
            if not isinstance(v, dict):
                return False
            if "by" in v and not isinstance(v["by"], str):
                return False
            return "partition" not in v or v["partition"] is None or isinstance(v["partition"], str)

        def _ok_str_list(v):
            return isinstance(v, list) and all(isinstance(x, str) for x in v)

        def _ok_or_routing(v):
            if not isinstance(v, dict):
                return False
            for _k in ("allow_fallbacks", "require_parameters", "zdr", "enforce_distillable_text"):
                if _k in v and not isinstance(v[_k], bool):
                    return False
            for _k in ("order", "only", "ignore", "quantizations"):
                if _k in v and not _ok_str_list(v[_k]):
                    return False
            if "data_collection" in v and v["data_collection"] not in ("deny", "allow"):
                return False
            if "sort" in v and not _ok_sort(v["sort"]):
                return False
            if "max_price" in v and not _ok_price_map(v["max_price"]):
                return False
            for _k in ("preferred_min_throughput", "preferred_max_latency"):
                if _k in v and not _ok_percentiles(v[_k]):
                    return False
            return True

        def _ok_vercel_routing(v):
            # only `only`/`order`, both `array of string`
            if not isinstance(v, dict):
                return False
            return all(_ok_str_list(v[k]) for k in ("only", "order") if k in v)

        def _ok_compat(v):
            if not isinstance(v, dict):
                return False
            for _k in COMPAT_BOOLS:
                if _k in v and not isinstance(v[_k], bool):
                    return False
            for _k, _allowed in COMPAT_CONSTS.items():
                if _k in v and v[_k] not in _allowed:
                    return False
            if "vllmPriority" in v and not _number(v["vllmPriority"]):
                return False
            for _k in ("chatTemplateKwargs", "chatTemplateArgs"):
                if _k in v and not _ok_template_map(v[_k]):
                    return False
            if "openRouterRouting" in v and not _ok_or_routing(v["openRouterRouting"]):
                return False
            if "vercelGatewayRouting" in v and not _ok_vercel_routing(v["vercelGatewayRouting"]):
                return False
            if "allowedFallbackModels" in v:
                af = v["allowedFallbackModels"]
                if not isinstance(af, list) or len(af) > 3:
                    return False
                for entry in af:
                    if not isinstance(entry, dict):
                        return False
                    for _k in ("provider", "model"):
                        if not _nonempty_str(entry.get(_k)):
                            return False
                    if not _ok_cost(entry.get("cost")):
                        return False
            return True

        def _ok_override(v):
            # `modelOverrides` is `patternProperties {"^.*$": <ModelOverride>}` and ModelOverride types its own
            # fields, so "is a dict" is one level too shallow (round 19, P1, measured: pi DISCARDED
            # `{"m":{"cost":"cheap"}}` while this gate answered `check=ok`). NOTE `cost` here is PARTIAL - the four
            # fields are optional - so `_ok_cost` (which requires them) must NOT be reused.
            if not isinstance(v, dict):
                return False
            for ov in v.values():
                if not isinstance(ov, dict):
                    return False
                # `ModelOverrideSchema` types `name` and the model-shaped fields below - but NOT `api`/`baseUrl`,
                # which are unknown keys there and legal at any type (round 20, P3, measured: pi LOADED
                # `{"api":123}` while this gate abstained). Missing `samplingParams`,
                # `samplingParamsByThinkingLevel`, `headers` and `compat` here was round 21\x27s P1: pi DISCARDS a
                # file whose override carries a bad leaf in any of them (`...modelOverrides.m1.compat.supportsStore:
                # must be boolean`) and removes the provider from `--list-models`, while this gate printed
                # `check=ok` naming that file\x27s variable.
                if "name" in ov and not _nonempty_str(ov["name"]):
                    return False
                if "samplingParams" in ov and not isinstance(ov["samplingParams"], dict):
                    return False
                if "samplingParamsByThinkingLevel" in ov and not _ok_sptl(ov["samplingParamsByThinkingLevel"]):
                    return False
                if "headers" in ov and not _str_map(ov["headers"]):
                    return False
                if "compat" in ov and not _ok_compat(ov["compat"]):
                    return False
                for _k in ("contextWindow", "maxTokens"):
                    if _k in ov and not _ok_num(ov[_k]):
                        return False
                if "reasoning" in ov and not isinstance(ov["reasoning"], bool):
                    return False
                if "input" in ov and not _ok_input(ov["input"]):
                    return False
                if "thinkingLevelMap" in ov and not _ok_level_map(ov["thinkingLevelMap"]):
                    return False
                if "inputLimits" in ov and not _ok_input_limits(ov["inputLimits"]):
                    return False
                if "promptCache" in ov and not _ok_prompt_cache(ov["promptCache"]):
                    return False
                if "cost" in ov:
                    co = ov["cost"]
                    if not isinstance(co, dict):
                        return False
                    for _k in ("input", "output", "cacheRead", "cacheWrite"):
                        if _k in co and not _number(co[_k]):
                            return False
                    # `cost.tiers` is typed on the override too, and `null` there is PRESENT (pi discards the
                    # file) - the same null-vs-absent rule as `_ok_cost` (round 20, P1, measured).
                    if "tiers" in co:
                        tiers = co["tiers"]
                        if not isinstance(tiers, list):
                            return False
                        for t in tiers:
                            if not isinstance(t, dict):
                                return False
                            for _k in ("inputTokensAbove", "input", "output", "cacheRead", "cacheWrite"):
                                if not _number(t.get(_k)):
                                    return False
            return True

        def _ok_sptl(v):
            # `samplingParamsByThinkingLevel` types each LEVEL as an object (round 19, P1, measured: pi DISCARDED
            # `{"off":"x"}` while this gate said ok).
            return isinstance(v, dict) and all(isinstance(v[k], dict) for k in LEVELS if k in v)

        MODEL_CHECKS = (
            ("name", _nonempty_str), ("api", _nonempty_str), ("baseUrl", _nonempty_str),
            ("reasoning", lambda v: isinstance(v, bool)), ("input", _ok_input),
            ("thinkingLevelMap", _ok_level_map), ("inputLimits", _ok_input_limits),
            ("cost", _ok_cost), ("promptCache", _ok_prompt_cache),
            ("contextWindow", _ok_num), ("maxTokens", _ok_num),
            ("samplingParams", lambda v: isinstance(v, dict)),
            ("samplingParamsByThinkingLevel", _ok_sptl),
            ("headers", _str_map), ("compat", _ok_compat),
        )
        PROVIDER_CHECKS = (
            ("name", _nonempty_str), ("baseUrl", _nonempty_str), ("api", _nonempty_str),
            ("apiKey", _nonempty_str), ("oauth", lambda v: v == "radius"),
            ("headers", _str_map), ("compat", _ok_compat),
            ("authHeader", lambda v: isinstance(v, bool)),
            ("modelOverrides", _ok_override),
        )
        if "$schema" in d and not isinstance(d["$schema"], str):
            return False
        if "providers" not in d:
            # `required: ["providers"]` - a document without it is DISCARDED by pi (round 19, P1 footnote, measured:
            # `{"$schema":"x"}` -> pi DISCARDED, gate cannot-say). `providers: {}` IS valid and loads.
            return False
        provs = d.get("providers")
        if not isinstance(provs, dict):
            return False
        for body in provs.values():
            if not isinstance(body, dict):
                return False
            for _k, _ok in PROVIDER_CHECKS:
                if _k in body and not _ok(body[_k]):
                    return False
            if "models" not in body:
                continue
            models = body["models"]
            if not isinstance(models, list):
                return False
            for m in models:
                if not isinstance(m, dict):
                    return False
                # `id` is REQUIRED (`"required": ["id"]`) and must be a non-empty string.
                if not _nonempty_str(m.get("id")):
                    return False
                for _k, _ok in MODEL_CHECKS:
                    if _k in m and not _ok(m[_k]):
                        return False
        return True

    if not _valid_models(doc):
        raise SystemExit(0)
    prov = (doc.get("providers") or {}).get(sys.argv[3]) or {}
    key = prov.get("apiKey")
    if not isinstance(key, str):
        raise SystemExit(0)
    kind, names = template_parts(key)
    for nm in names:
        print(nm)
    raise SystemExit(0)

# MODE=store
# ⛔ `null` IS NOT "NO STORED CREDENTIAL" (round 25, P1, measured): a whole-document `null` parses fine, and pi then
# evaluates `readState.data[provider]` on it - `Credential store read failed for <provider>: Cannot read properties of
# null (reading \x27<provider>\x27)`, exit 1, WITH the provider key exported. The old reader folded every non-dict into the
# POSITIVE "there is no credential here" (rc 1), so the gate fell through to the environment and printed `check=ok`
# - and the false fact "auth.json has NO entry for this provider" - over a lane that dies. The other non-dict shapes
# are genuinely safe and stay rc 1: `[]` reaches the provider (measured 401), because indexing an array yields
# `undefined`, not a throw.
if not isinstance(doc, dict):
    raise SystemExit(6 if doc is None else 1)
entry = doc.get(sys.argv[3])
# ⛔ rc 5 = THE STORE ENTRY IS INVALID, AND THAT IS ITS OWN ANSWER (round 19, P1, measured).
# An entry pi cannot take a key from SHADOWS the environment instead of falling back to it, and that is the
# mechanism this arm encodes - NOT a throw (round 20, P3, corrected against the vendor). `pi -p` builds its store
# with `AuthStorage.create` (`model-runtime.js:80`), whose `parseStorageData` is a bare `JSON.parse` with no
# per-entry validation (`auth-storage.js:306-312`); the strict `load()` that throws on a bad entry belongs to
# `ReadOnlyAuthStorage`, which the CLI constructs only for `pi auth ... --no-refresh`. What the lane path does is
# read the entry and hand it to `composeApiKeyAuth`, so an entry whose `type` is not `api_key` (or whose value
# resolves to nothing) means the provider has a credential that yields no key: measured with
# `{"deepseek":{"key":"sk-..."}}` (no `type`), with `{"deepseek":"sk-..."}`, with `{"type":"api_key","key":null}`
# and with an `oauth` entry missing `refresh`/`expires`, `pi -p` printed `No API key found for deepseek.` with
# nothing exported and `Provider is not configured: deepseek` with DEEPSEEK_API_KEY exported AND a models.json
# template naming it. An entry for ANOTHER provider is unaffected (measured: a valid deepseek entry plus an invalid
# `zzz` entry still produced a 401 from the deepseek key), which is why this checks the REQUESTED provider only.
# The old reader here scanned for any `key`-ish field, so it answered `reason=stored-credential` for a store pi
# cannot take a key from and suppressed the very refusal that would have named the missing variable. pi provably
# cannot run this provider, so the honest answer is the stronger one: refuse, naming the STORE.
# ⛔ pi\x27s "IS ANYTHING STORED?" TEST IS JS TRUTHINESS, NOT IDENTITY (round 26, P1, measured): `auth-storage.js:377-380`
# hands the raw entry back (`if (credential?.type !== "api_key") return credential;`) and `pi-ai/dist/auth/resolve.js:24`
# branches on `if (stored)`, so `null`, `false`, `0`/`0.0`/`-0` and `""` are all "nothing stored" and the AMBIENT env
# decides — measured `{"deepseek":false}` / `{"deepseek":0}` / `{"deepseek":""}` with `DEEPSEEK_API_KEY` exported: pi
# ran (401 from the env key). `entry is None` alone made the falsy scalars fall into the rc-5 arm, which REFUSES 82 a
# box pi runs, with the destructive remedy "repair .../auth.json" — a regression against the base, and the polarity this
# header forbids (refuse only on a positive reading).
# ⛔ AND THE OPPOSITE SHAPES STAY rc 5: `[]`, `true` and a non-empty string ARE stored values that pi then cannot turn
# into a key (measured `{"deepseek":[]}` -> `Provider is not configured`), so they remain a positive refusal.
if entry is None or entry is False or (not isinstance(entry, dict) and entry in (0, "")):
    # NO ENTRY for this provider: the positive "no stored credential", so the environment decides (measured: an
    # absent entry plus `DEEPSEEK_API_KEY` exported runs, and without it pi prints `No API key found`).
    raise SystemExit(1)
if not isinstance(entry, dict):
    raise SystemExit(5)
_type = entry.get("type")
if _type == "api_key":
    # ⛔ NO SHAPE CHECK ON `env` (round 20, P2, measured): pi hands `env` straight to `resolveConfigValue`, which
    # IGNORES a non-object map and stringifies numeric values - `{"type":"api_key","key":"sk-${A}","env":"oops"}`
    # resolves from the process environment and `pi auth check` reports the provider `ready`, while this gate
    # refused it as store-invalid. Our reader already models that fallback in `resolve()`, so grading the entry is
    # possible and refusing it was a false block.
    _key = entry.get("key")
    if "key" in entry and _key is None:
        # ⛔ PRESENT-AND-NULL IS NOT ABSENT (round 20, P2, measured): `entry.get` cannot tell them apart, and pi
        # does - `{"type":"api_key"}` falls back to the provider\x27s own variable, but `{"type":"api_key","key":null}`
        # dies before any credential lookup with `Credential store read failed for <provider>: Cannot read
        # properties of null (reading \x27startsWith\x27)`, even with that variable exported.
        raise SystemExit(5)
    if _key is None or (isinstance(_key, str) and not _key.strip()):
        # `key` is OPTIONAL for pi, and a key-less entry does not hand the decision back to the ENVIRONMENT this
        # gate reads: measured, an `{"type":"api_key"}` entry with DEEPSEEK_API_KEY exported RAN on that BUILT-IN
        # variable - not on the models.json template the gate follows. Whether the entry redirects the effective
        # source is pi\x27s answer, so this is cannot-say (4), never "absent" (which would refuse 82 naming a
        # variable pi does not consult here).
        raise SystemExit(4)
    if not isinstance(_key, str):
        raise SystemExit(5)
elif _type == "oauth":
    # ⛔ GRADED ON WHAT `toAuth` NEEDS, NOT ON `ReadOnlyAuthStorage.load`\x27s SHAPE (round 21, P2, measured): pi -p
    # hands an oauth credential to `resolveStoredOAuth` → `oauth.toAuth(credential)` and only refreshes when
    # `Date.now()+300000 >= credential.expires`, so a MISSING `expires` means "never expires", a STRING compares
    # numerically, and a missing `refresh` is irrelevant while the token is live. Measured against `anthropic` (a
    # built-in WITH an oauth handler): `{access,refresh,expires:"9...9"}`, `{access,refresh}` and
    # `{access,expires}` all reached the provider (401 "OAuth access token is invalid"), while requiring all three
    # refused them 82 with the remedy "repair (or delete) auth.json" - a false block carrying a destructive remedy.
    _acc = entry.get("access")
    if not (isinstance(_acc, str) and _acc):
        raise SystemExit(5)
    if "expires" in entry and entry["expires"] is not None and not isinstance(
            entry["expires"], (int, float, str)):
        raise SystemExit(5)
    if "expires" in entry and entry["expires"] is None:
        # present-and-null sends pi into the refresh path it cannot satisfy (measured: `OAuth refresh failed`).
        raise SystemExit(5)
    # A usable oauth entry is a credential pi can only USE where the provider has an oauth handler, and which
    # providers have one is the vendor registry\x27s answer, not this gate\x27s - `pi-ai/dist/providers` ships handlers
    # for several BUILT-INS (anthropic, openai, openai-codex, github-copilot, openrouter, xai, meta, kimi-coding,
    # radius), so this arm must stay a cannot-say rather than a refusal (round 21, P3: the first version of this
    # comment claimed the built-ins have none, which the installed tree disproves).
    raise SystemExit(3)
else:
    raise SystemExit(5)
envmap = entry.get("env") if isinstance(entry.get("env"), dict) else None
cannot = False
# pi reads ONLY `key` on an `api_key` entry (`auth-storage.js:220-226`), so a legacy `access_token`/`token`
# field is inert there: scanning those synonyms asserted a credential pi never looks at.
status, _ = resolve(entry["key"], envmap)
if status == "ok":
    raise SystemExit(0)
if status == "cmd":
    cannot = True
# ⛔ rc 4 IS ITS OWN ANSWER, AND IT IS NOT rc 1 (review cycle 2, P1, measured). An entry that EXISTS for
# this provider but whose key resolves to nothing is NOT "no stored credential": pi hands the present
# credential to `composeApiKeyAuth.resolve`, which delegates to the inherited provider handler
# (`dist/core/provider-composer.js:283-294`) — that handler resolves the PROVIDER\x27s BUILT-IN env var
# and never the models.json template. So on that box `pi` can still run on, say, `DEEPSEEK_API_KEY` while
# the models.json template names something else entirely: answering rc 1 ("no credential, the
# environment decides") made this gate REFUSE 82 a lane pi would have run, and told the operator to fix a
# variable that was never consulted. The fallback chain is pi\x27s, not ours to model, so the honest
# answer is "cannot say" — which asserts nothing and therefore cannot be wrong in either direction.
raise SystemExit(3 if cannot else 4)
'

# key_gate_bounded <secs> <cmd...> — run a probe under a TIME BOUND (review round 4, P1, measured).
# ⛔ AN UNBOUNDED PROBE HERE IS WORSE THAN ELSEWHERE: the gate runs immediately before `run_agent`, which
# is where `lane-bound.sh` gets installed — so a hang here has no wall bound and no silence bound, and bash
# DEFERS traps while a foreground command runs, so a TERM could not even reach `lane_terminate` to write
# the terminal line. Measured with a `models.json` that blocks on `open` (a FIFO, or a hung automount): the
# lane sat in the probe, survived TERM, and wrote NO `outcome=` line at all — the exact silent end this
# change exists to remove, reintroduced by the check added to prevent it.
# Same shape as `worker-terminal.sh::wt_bounded` (perl `alarm`, then `timeout`), and the fallback is
# BOUNDED TOO rather than best-effort: a fired bound prints nothing, which is the gate's own "cannot say"
# answer, and blindness refuses nothing.
key_gate_bounded() { # <secs> <cmd...>
  local s="${1:-15}"; shift
  case "$s" in ''|*[!0-9]*) s=15 ;; esac
  [ "$s" -gt 0 ] 2>/dev/null || s=15
  if command -v perl >/dev/null 2>&1; then
    perl -e 'alarm shift; exec @ARGV' "$s" "$@"; return $?
  fi
  if command -v timeout >/dev/null 2>&1; then timeout "$s" "$@"; return $?; fi
  local out pid w rc
  out="$(mktemp "${TMPDIR:-/tmp}/key-gate.XXXXXX" 2>/dev/null)" || return 3
  # ⛔ THE PROGRAM MUST NOT COME FROM STDIN HERE (review round 5, P2, measured). In a non-interactive shell
  # bash redirects an ASYNC list's stdin from /dev/null unless the command carries its own redirect, so a
  # `python3 - <<'PY'` probe would be handed an EMPTY program: it exits 0 printing nothing, the gate reads
  # that as "cannot resolve" and goes INERT — silently, on exactly the hosts this fallback exists for (no
  # perl, no timeout). That is why both call sites pass their program with `-c "$VAR"` and never a heredoc;
  # arm 5d drives this path with perl AND timeout hidden from PATH.
  "$@" >"$out" 2>/dev/null & pid=$!
  ( sleep "$s"; kill -TERM "$pid" 2>/dev/null; sleep 1; kill -KILL "$pid" 2>/dev/null ) >/dev/null 2>&1 & w=$!
  wait "$pid" 2>/dev/null; rc=$?
  kill "$w" >/dev/null 2>&1; wait "$w" 2>/dev/null
  cat "$out" 2>/dev/null; rm -f "$out" 2>/dev/null
  return "$rc"
}

# key_gate_agent_dir <home> -> the directory `pi` ITSELF would read, or nothing.
# ⛔ `PI_CODING_AGENT_DIR` IS NOT COSMETIC, AND HARDCODING `$home/.pi/agent` MADE THE GATE ANSWER A
# QUESTION pi DOES NOT ASK (review, P1, measured 2026-11-04). pi resolves its config dir as
# `${PI_CODING_AGENT_DIR:-~/.pi/agent}`, and THIS REPO ALREADY MIRRORS THAT RULE
# (`extensions/builtin-tools/index.ts:272-280`: "mirrors pi's own config resolution (PI_CODING_AGENT_DIR
# override, else ~/.pi/agent/models.json)"; `scripts/checkout-hygiene/deepseek-balance-latch.py:98`
# does the same). With the override set, the hardcode failed in BOTH directions:
#   • a box whose store under the override holds the key was REFUSED with 82 — a false block on a
#     supported configuration, i.e. the polarity the header forbids; a gate that refused on the
#     variable alone refused a lane that WOULD have worked;
#   • a box whose models.json lives ONLY under the override printed `check=skipped`, the gate went
#     blind, and `pi` died with "No API key found" — the silent end this whole change removes.
# ⛔ A RELATIVE OVERRIDE (AND `~user`) IS RESOLVED AGAINST THE CALLER'S cwd, BECAUSE THAT IS WHAT pi DOES
# (round 9, P3, measured live against the installed pi 1.2.0): the first cut of this function IGNORED a relative
# override and answered `$home/.pi/agent` — but `pi` only fails to EXPAND it, it does not ignore it.
# `getAgentDir()` returns the raw string (`dist/config.js:491-496`, `normalizePath` expands `~`/`~/` only) and
# `SettingsManager.create` resolves it with `resolvePath(agentDir)`, whose `baseDir` defaults to `process.cwd()`
# (`dist/utils/paths.js:83-86`). Measured: `cd /tmp/relx && PI_CODING_AGENT_DIR=relagent pi --list-models` reads
# `./relagent/models.json` (its provider error names the model from that file), and `PI_CODING_AGENT_DIR='~nobody/agent'`
# reads `./~nobody/agent/models.json`. So ignoring it made the gate read a DIFFERENT store than pi — the
# false-82-or-blind pair this header exists to forbid. `~user` is not expanded by pi either, so it resolves
# relative as well; only `~` and `~/` are locations.
key_gate_agent_dir() {
  local home="${1:-}" cwd="${2:-${PWD:-}}"
  # ⛔ THE `~`/`~/` LOCATION CASES COME FIRST: they are the only forms pi EXPANDS, so they are answers in
  # their own right (`normalizePath`'s `expandTilde` branch maps `~` to `homedir()` — `dist/utils/paths.js:70-77`).
  # Putting the relative branch ahead of them silently resolved `~/alt-agent` against the CWD instead — caught by
  # arm 2k7, which is exactly what it exists for.
  case "${PI_CODING_AGENT_DIR:-}" in
    '~')
      [ -n "$home" ] || return 0
      printf '%s\n' "$home"; return 0 ;;
    '~/'*)
      [ -n "$home" ] || return 0
      printf '%s\n' "$home/${PI_CODING_AGENT_DIR#'~/'}"; return 0 ;;
    /*)
      printf '%s\n' "$PI_CODING_AGENT_DIR"; return 0 ;;
    # ⛔ A `file://` OVERRIDE IS A PATH TO pi, CONVERTED BEFORE THE ABSOLUTE TEST (round 26, P2, measured):
    # `normalizePath` ends with "if the value matches file://, convert it with fileURLToPath"
    # (`dist/utils/paths.js:78-80`), and `getAgentDir()` runs the override through it. Joining the URL onto `cwd`
    # answered about a directory pi never reads - measured `PI_CODING_AGENT_DIR=file:///tmp/x/altagent`:
    # `pi --list-models` listed that directory's provider while the gate answered
    # `check=skipped ... not resolvable from <cwd>/file:///tmp/x/altagent/models.json` (blindness on a box pi runs, plus a
    # bogus settings path for the trust probe). Only the host-less absolute form is reproduced; `file://host/...` has no
    # local path, and a percent-escape needs `fileURLToPath`'s decoding, so both answer cannot-say rather than a path
    # that is wrong in a way no caller can detect.
    file://*)
      case "${PI_CODING_AGENT_DIR#file://}" in
        /*) case "${PI_CODING_AGENT_DIR#file://}" in
              *%*) return 0 ;;
              *) printf '%s\n' "${PI_CODING_AGENT_DIR#file://}"; return 0 ;;
            esac ;;
        *) return 0 ;;
      esac ;;
    '')
      : ;;
    *)
      # A RELATIVE override (including `~user`, which pi does not expand) is resolved against the CALLER'S cwd,
      # because that is the base `pi` itself uses (`resolvePath(agentDir)`, `baseDir ?? process.cwd()`).
      # ⛔ NO ANSWER when the cwd is not absolute: a relative base is the one case where no honest path can be
      # produced, and every caller turns an empty answer into a cannot-say — never into `$home/.pi/agent`, which
      # is a DIFFERENT file pi would not read.
      case "$cwd" in
        /*) printf '%s/%s\n' "$cwd" "$PI_CODING_AGENT_DIR"; return 0 ;;
        *) return 0 ;;
      esac
      ;;
  esac
  [ -n "$home" ] || return 0
  printf '%s\n' "$home/.pi/agent"
}

# key_gate_var <home> [<provider>] -> the env var name the lane provider's apiKey resolves from, or
# nothing when it cannot be said. An empty answer is the "do not refuse" answer.
key_gate_var() {
  local home="${1:-}" prov="${2:-}" cwd="${3:-${PWD:-}}"
  local agent_dir mj
  agent_dir="$(key_gate_agent_dir "$home" "$cwd")"
  [ -n "$agent_dir" ] || return 0
  mj="$agent_dir/models.json"
  # ⛔ NO `[ -r "$mj" ]` HERE (review round 5, P2, measured): that test is access(2)/stat(2) on the SAME
  # path, so on a hung automount it blocks BEFORE the bound is armed — the round-4 P1 surviving in the other
  # half of the same function. The read that can block is the `open`, and that one is inside the bound; an
  # absent or unreadable file simply makes it print nothing, which is the "cannot say" answer.
  [ -n "$prov" ] || prov="${PI_LANE_PROVIDER:-deepseek}"
  command -v python3 >/dev/null 2>&1 || return 0
  # A literal apiKey, a provider absent from the file, and an unparseable file all print NOTHING.
  # A TEMPLATE prints EVERY name it references (review cycle 1, P2): `sk-${A}${B}` is a shape pi fully
  # resolves and the old single-name `fullmatch` answered "cannot resolve" for — a gate that goes quiet
  # on a readable config. One name per line; empty output is still the "cannot say" answer.
  key_gate_bounded "${KEY_GATE_BOUND:-15}" python3 -c "$_KEY_GATE_PY" "$mj" var "$prov" 2>/dev/null
}

# key_gate_value_present <VARNAME> — 0 iff THIS environment holds a non-blank value.
# ⛔ A BLANK VALUE IS NOT A CREDENTIAL (`GH_TOKEN='   '` is the measured shape of that mistake in
# worker-terminal.sh), and the name is INDIRECT (it comes from the provider's config), so it is
# validated before it is expanded.
key_gate_value_present() {
  local v="${1:-}" val
  case "$v" in ''|*[!A-Za-z0-9_]*) return 1 ;; esac
  eval "val=\${$v:-}" 2>/dev/null || val=""
  case "$val" in *[![:space:]]*) return 0 ;; esac
  return 1
}

# key_gate_account_home — the ACCOUNT's home, which on a cell is NOT `$HOME` (HOME is redirected to the
# operational home). Best-effort and never fatal: an unreadable answer just drops one candidate from
# the refusal text. `getent` is Linux, `dscl` is macOS; both are local reads.
key_gate_account_home() {
  local h=""
  if command -v getent >/dev/null 2>&1; then
    h="$(getent passwd "$(id -un 2>/dev/null)" 2>/dev/null | awk -F: 'NR==1{print $6}')"
  fi
  if [ -z "$h" ] && command -v dscl >/dev/null 2>&1; then
    h="$(dscl . -read "/Users/$(id -un 2>/dev/null)" NFSHomeDirectory 2>/dev/null | sed -n 's/^NFSHomeDirectory: //p' | head -1)"
  fi
  case "$h" in /*) printf '%s\n' "$h" ;; *) printf '\n' ;; esac
}

# key_gate_stored_credential <home> <provider> — 0 iff `pi`'s OWN credential store holds an entry for
# this provider. ⛔ THIS ARM EXISTS SO THE GATE CANNOT REFUSE A LANE THAT WOULD HAVE RUN (review round 3,
# P1, measured): with `auth.json` carrying a `zai` api_key, `pi --list-models` lists the provider's models
# and the lane works, while the models.json template still names `$ZAI_API_KEY` — so a gate that looked
# only at the environment refused a working box with 82. The store is the FIRST source `pi` consults, so
# "the variable is unset" is not "the credential is missing".
# Anything unreadable here answers "cannot say" (rc 3) -> the caller states that it could not verify a
# credential it can SEE, and asserts nothing (a `!command` value is not ours to execute). rc 1 is a
# positive "no credential", the only answer that lets the caller fall through to the environment check.
key_gate_stored_credential() {
  local home="${1:-}" prov="${2:-}" cwd="${3:-${PWD:-}}"
  local agent_dir aj
  [ -n "$prov" ] || return 1
  agent_dir="$(key_gate_agent_dir "$home" "$cwd")"
  [ -n "$agent_dir" ] || return 1
  aj="$agent_dir/auth.json"
  # No `[ -r ]` pre-test, for the same reason as key_gate_var's (review round 5, P2): stat can block before
  # the bound arms. ⛔ AN ABSENT STORE IS A POSITIVE "no credential" (rc 1), NOT "cannot say" (review cycle
  # 2, P2 — this comment said the opposite of the code, and a later editor making the code match it would
  # print `stored-credential-unresolvable` for a file that does not exist and go inert fleet-wide). The
  # absent-file arm is the probe's `except` branch: `var` mode is silent, `store` mode is rc 1, because
  # "this box has no store" is a datum we DID read.
  command -v python3 >/dev/null 2>&1 || return 1
  key_gate_bounded "${KEY_GATE_BOUND:-15}" python3 -c "$_KEY_GATE_PY" "$aj" store "$prov" 2>/dev/null
  # rc 0 = a credential that RESOLVES; 3 = cannot say; anything else = no credential. The bound's own
  # kill status (143/124/…) lands in the "cannot say" bucket because it is not a positive "absent".
  local rc=$?
  # 0 = a credential that RESOLVES · 1 = no entry for this provider · 3/4 = cannot say · anything else
  # (a bound's 143/124/137, a crash) = cannot say too. ⛔ THE WILDCARD IS NOT rc 1 (review cycle 2, P2):
  # folding "the read did not finish" into "no credential" refuses a box whose credential is in the
  # store but whose store could not be read — the false-block direction this function's own header
  # exists to prevent. Pinned by key-gate.test.sh 2j11/2j12.
  case "$rc" in
    0|1) return "$rc" ;;
    # 5 = the ENTRY ITSELF is invalid by pi\x27s loader (round 19, P1, measured) - neither "has a credential" nor
    # "absent": pi throws on it and then cannot run that provider even with the key exported. It gets its own
    # refusal at both call sites rather than being folded into the cannot-say bucket.
    5) return 5 ;;
    # 6 = THE FILE DOES NOT PARSE (round 22, P2, measured): `parseStorageData` is a bare `JSON.parse`, so pi
    # answers `Credential store read failed for <provider>: Expected property name ...` and exits - with AND
    # without the provider key exported, for every provider. Reporting that as the cannot-say bucket printed
    # "holds an entry for this provider whose value this gate cannot resolve (a `!command`, an `oauth`
    # credential ...)" about a file that holds no entry at all, and let a certain death through as a skip.
    6) return 6 ;;
    *) return 3 ;;
  esac
}

# key_gate_candidates <home> — the files a box is known to carry credentials in, one per line, deduped
# in the order they matter. ⛔ THE REDIRECTED `$HOME` IS THE POINT: `${ENV_FILE:-$HOME/keys.env}` is
# what `lane-env.sh` actually sourced, `$CELL_HOME/keys.env` is what `cloud-cell-supervisor.sh` sources,
# and the ACCOUNT home's file is where the credential usually IS — naming all of them is what turns a
# silent death into a one-line fix.
key_gate_candidates() {
  local home="${1:-}" acct cell c
  acct="$(key_gate_account_home)"
  cell="${CELL_HOME:-/tmp/cell-home}"
  for c in "${ENV_FILE:-}" \
           "${home:+$home/keys.env}" \
           "${home:+$home/pi-keys.env}" \
           "${cell:+$cell/keys.env}" \
           "${acct:+$acct/keys.env}"; do
    [ -n "$c" ] || continue
    # Only an absolute path is a location; a relative one would be printed about the wrong directory.
    case "$c" in /*) printf '%s\n' "$c" ;; esac
  done | awk '!seen[$0]++'
}

# key_gate_assert <label> [<home>] [<provider>] [<model>]
#   prints ONE line (a second, human-facing line only on refusal) and returns 0, or KEY_GATE_REFUSED.
# ⛔ THE PASS ARM CLAIMS ONLY WHAT IT MEASURED (`check=ok`), never `result=` — `result=` is reserved for
# a line emitted once an OUTCOME is known. That rule is #2935's, measured: twelve lanes printed
# `result=OK` at pre-flight and none of them did anything, because the dispatcher read a check as a
# verdict. A lane's OUTCOME is the terminal line `lane.sh` writes (`outcome=…`), not this.
# key_gate_selected_model <model> <explicit-provider> -> "provider\tmodel" — the model a lane invocation
# will actually run, and the provider half resolved to the one whose credential the gate may assert.
# ⛔ PRECEDENCE, AND THE ORDER IS THE POINT: an EXPLICIT provider always wins, because that is what
# `spawn-gate.sh::run_agent` builds (`pi -p --provider "$lane_provider" --model "$lane_model"`) and a gate
# that second-guessed an explicit flag would answer a question pi does not ask. `$PI_LANE_PROVIDER` is the
# same half (it becomes `--provider`), so it wins next. With NOTHER named, the answer is `deepseek`.
# ⛔ A `provider/` PREFIX IS **NOT** A PROVIDER, AND THE GATE NO LONGER INFERS ONE (round 18, P1, measured).
# The rule this replaced asserted `<prefix>` whenever the model id contained a slash. pi does something far
# more conditional (`dist/core/model-resolver.js`): it infers the prefix ONLY when it matches a provider that
# HAS models (`providerMap` is built from `availableModels`), keeps the LOOKUP case-insensitive, then — when
# nothing under that provider matches — falls back to matching the WHOLE string as a model id across every
# provider (`:409-420`), and even a matched inference loses to a sole authenticated raw-id match (`:388-400`).
# Which of those wins depends on the AUTH STATE this gate is trying to measure. Measured: provider `aaa` had
# model `q` while provider `bbb` had a model whose id was literally `aaa/x`; `pi -p --model aaa/x` sent the
# request to `bbb` while this gate printed `check=ok var=AAA_KEY provider=aaa` — a green gate asserting a
# variable pi never consulted (and `--model AAA/x` went the other way, `cannot-resolve-provider-credential`
# for a provider pi lowercases and resolves). So the honest answer with no `--provider` is: nothing is
# asserted about a prefixed id. The registry-and-auth reasoning needed to do better is pi's, not ours.
key_gate_selected_model() { # <model> <explicit-provider>
  local m="${1:-}" p="${2:-}"
  [ -n "$m" ] || m="${PI_LANE_MODEL:-deepseek-flash}"
  # ⛔ `$PI_LANE_PROVIDER` OUTRANKS THE PREFIX, because `run_agent` PASSES IT AS `--provider` (round 3,
  # F5/P3, measured): the gate's precedence has to match the argv pi will actually receive. With
  # `PI_LANE_PROVIDER=deepseek` and a `venice/whatever` model the old order asserted venice (green) while
  # `spawn-gate.sh:2110` would have handed pi `--provider deepseek --model venice/whatever` — a green gate over
  # a lane that cannot start. Production is covered twice now (lane.sh passes both halves), but the probe and
  # any future 3-arg caller reach it.
  if [ -z "$p" ]; then
    if [ -n "${PI_LANE_PROVIDER:-}" ]; then
      p="$PI_LANE_PROVIDER"
    else
      # ⛔ AN INHERITED MODEL IS NOT A NAMED ONE (round 10, P3, kept): `run_agent` builds
      # `--provider "${PI_LANE_PROVIDER:-deepseek}"` ALWAYS, so a lane whose model comes from `$PI_LANE_MODEL` is
      # handed provider `deepseek` even when that model is spelled `venice/whatever` — consulting the slash there
      # asserted venice's credential for a lane pi starts on deepseek (measured `check=ok` over a dying lane).
      # ⛔ AND A *NAMED* PREFIXED MODEL NO LONGER NAMES A PROVIDER EITHER (round 18, P1, measured — see the block
      # above the function): the empty provider propagates as `cannot-resolve-provider-credential`, which asserts
      # nothing, instead of a green line about whichever provider the slash happened to spell.
      # ⛔ A *NAMED* MODEL WITH NO PROVIDER ASSERTS NOTHING, PREFIXED OR NOT (round 19, P2, measured): the
      # `*/*` half of this rule landed in round 18, and the unprefixed half kept the LANE justification below —
      # but this function cannot tell a lane from the documented `--probe` path, and the probe is exactly where an
      # operator asks "would THIS model start". Measured: `--probe t <home> "" gpt-4o` printed
      # `check=ok var=DEEPSEEK_API_KEY provider=deepseek model=gpt-4o` while `pi -p --model gpt-4o` answered
      # `Model "gpt-4o" is ambiguous across providers: azure/gpt-4o, cloudflare-ai-gateway/gpt-4o, openai/gpt-4o.
      # No matching provider is authenticated.` - a green gate over a model pi will not run. Resolving a bare id
      # needs the model registry and the auth state, so both named shapes abstain and `--provider` is the way to a
      # verdict. An INHERITED model keeps `deepseek`, because `run_agent` really does pass that as `--provider`.
      # ⛔ ⛔ AND WHERE THE `$PI_LANE_PROVIDER` BRANCH ABOVE IS ACTUALLY REACHED (round 23, P3, measured): `lane.sh` now passes
      # the pair POSITIONALLY (four arguments), so production never exercises it — only `--probe` and any future
      # 3-argument caller do. It is a probe convenience, and the arms that pin it (`7c*`/`7f*`) pin the FUNCTION, not
      # the branch; a lane does not depend on this precedence and cannot, since the provider it is handed is the one
      # `run_agent` will spawn with.
      case "${1:-}" in
        "") p="deepseek" ;;
        *) p="" ;;
      esac
    fi
  fi
  printf '%s\t%s\n' "$p" "$m"
}

# key_gate_project_trusted <home> <cwd> -> prints `trusted` | `untrusted` | `unknown`.
# ⛔ A PROJECT settings FILE IS NOT READ UNLESS THE PROJECT IS TRUSTED (fresh-context review round 2, P2,
# verified in the vendor source): `SettingsManager.loadFromStorage` returns `{}` for scope `project` when
# `!projectTrusted` (`dist/core/settings-manager.js:257-259`), and `trust-manager.js:8-17` lists
# `settings.json` as a trust-REQUIRING project resource — so the file's mere presence triggers trust
# resolution. Under `pi -p` there is no UI (`main.js:621`), so `project-trust.js:38-52` resolves to FALSE
# unless a decision was recorded or `defaultProjectTrust` is `always`. Reading the project pin unconditionally
# reported a pair `pi` would never use: a FALSE 82 on a box whose agent-dir pin IS provisioned, i.e. the
# fail-closed polarity this file forbids. Three answers, like every other probe here.
key_gate_project_trusted() {
  local home="${1:-}" cwd="${2:-}" agent_dir
  case "$cwd" in /*) ;; *) printf 'unknown\n'; return 0 ;; esac
  agent_dir="$(key_gate_agent_dir "$home" "$cwd")"
  [ -n "$agent_dir" ] || { printf 'unknown\n'; return 0; }
  command -v python3 >/dev/null 2>&1 || { printf 'unknown\n'; return 0; }
  # ⛔ ONE LINE, ARGS INCLUDED: a continuation line that STARTS with an absolute path is read by the local
  # worktree guard as a directly-executed script with an expanded name, which blocks running this file at all.
  key_gate_bounded "${KEY_GATE_BOUND:-15}" python3 -c "$_KEY_GATE_TRUST_PY" "$agent_dir/settings.json" "$agent_dir/trust.json" "$cwd" 2>/dev/null || printf 'unknown\n'
}

# key_gate_settings_pair <file> -> "<provider>\t<model>" (EITHER HALF MAY BE EMPTY) on stdout, nothing when
# the file pins neither; returns 3 when the READ ITSELF failed (the bound fired, python died, no python3).
# ⛔ THE STATUS IS PART OF THE ANSWER (round 3, F3/P3, measured): a killed read used to be indistinguishable
# from an absent pin, so a FIFO `settings.json` under `KEY_GATE_BOUND` was reported as the positive claim "this
# box pins NO startup model". A read that did not complete is cannot-say, and the caller says so.
key_gate_settings_pair() { # <file>
  local f="${1:-}" out
  [ -n "$f" ] || return 3
  command -v python3 >/dev/null 2>&1 || return 3
  out="$(key_gate_bounded "${KEY_GATE_BOUND:-15}" python3 -c "$_KEY_GATE_PY" "$f" default 2>/dev/null)" || return 3
  [ -n "$out" ] || return 0
  printf '%s\n' "$out"
}

# key_gate_box_default <home> [<cwd>] -> ALWAYS one line: "<status>\t<provider>\t<model>\t<file>" where status
# is `pin`, `no-pin` or `unreadable` (and the other fields are empty unless status is `pin`). The pair is the
# startup pair a BARE `pi` would use; the file(s) name where it came from (`<project>+<agent>` when each
# contributed a half).
# ⛔ THE STATUS IS PRINTED, NOT RETURNED IN A GLOBAL (measured): every caller reads this through `$(…)`, so a
# variable set in here dies with the subshell — a global read one line later was always empty, and "unreadable"
# silently became "no pin". A status that survives a subshell has to be an exit status or a field, and a field
# keeps the `no-pin` and `unreadable` answers distinct in one round trip.
# ⛔ TWO FILES, MERGED PER KEY, IN pi's OWN ORDER (round 3, F2/P2). `pi` merges a PROJECT settings file over the
# agent-dir one per key (`deepMergeSettings` → `deepMergeObjects`), and a lane's cwd is its worktree — so a
# project file pinning ONLY `defaultProvider` still yields a real pair with the agent-dir's `defaultModel`, and
# a probe that fell back to the agent-dir pair instead reported a model `pi` does not start on (a false PASS
# on the exact defect this probe exists to find). The project half counts only when the project is TRUSTED:
# `loadFromStorage` returns {} for scope `project` under `!projectTrusted`, `settings.json` is itself
# trust-requiring, and a `-p` session has no UI. When trust cannot be determined, the answer is `unreadable`
# (blindness is not a verdict) rather than a guess either way.
key_gate_box_default() {
  local home="${1:-}" cwd="${2:-}" agent_dir sj="" pj="" out trust rest arc=0 prc=0 use_pj use_sj
  local ascope="" pscope=""
  # ⛔ NO MASK FOR THE AGENT HALF (round 23, P3, measured): `apmask`/`ammask` were declared and written and NEVER
  # read - the agent-dir file is the merge BASE, so only `pmask`/`pscope` decide (`key_gate_box_default`'s merge
  # below). They are gone rather than left as names that read as protection: "dead code in a gate is worse than a
  # missing arm".
  local ap="" am="" pp="" pm="" pmask="aa" dp dm src psrc msrc
  agent_dir="$(key_gate_agent_dir "$home" "$cwd")"
  [ -n "$agent_dir" ] || { printf 'unreadable\t\t\t%s\n' "<no-agent-dir>"; return 0; }
  sj="$agent_dir/settings.json"
  if out="$(key_gate_settings_pair "$sj")"; then
    if [ -n "$out" ]; then
      ap="${out%%$'\t'*}"; rest="${out#*$'\t'}"
      am="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"
      # the agent half needs no mask: it is the BASE the project half merges onto (round 23, P3)
      ascope="${rest#*$'\t'}"
    fi
  else
    arc=3
  fi
  case "$cwd" in
    /*)
      pj="$cwd/.pi/settings.json"
      if out="$(key_gate_settings_pair "$pj")"; then
        if [ -n "$out" ]; then
          pp="${out%%$'\t'*}"; rest="${out#*$'\t'}"
          pm="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"
          pmask="${rest%%$'\t'*}"; pscope="${rest#*$'\t'}"
        fi
      else
        prc=3
      fi
      # ⛔ THE TRUST PROBE MUST RUN WHEN THE PROJECT SETS ONLY `enabledModels` (round 9, P2, measured): the guard
      # used to test the two pin halves alone, so a project file that set ONLY the scope never had its trust
      # evaluated — and `pscope` then answered `scoped` about a file `pi` throws away entirely (`loadFromStorage`
      # returns `{}` for scope `project` under `!projectTrusted`, and `getEnabledModels()` reads the MERGED
      # settings). The result was a cannot-say — and, in a lane log, SILENCE — about the agent-dir pin pi really
      # uses, which is the fact #3443 item 3 asks this probe to report.
      # ⛔ THE `[ -e "$pj" ]` CLAUSE IS WHAT GUARANTEES THIS, AND IT SUBSUMES THE PER-STATE TESTS (round 17, P3,
      # measured): every state that needs a trust answer — a pin half, `pscope` 1 or `n` (the array-replacement
      # `enabledModels: []`), a read that failed — requires the file to EXIST, so the probe runs by construction.
      # Listing `pscope = n` and `prc = 3` beside it was dead code: deleting them left the suite green and the output
      # byte-identical, i.e. they read as protection nobody could exercise. The behaviour they were added for (round 11:
      # an UNTRUSTED project `[]` must not clear the agent-dir scope) is carried by this one clause; 8H4 and 8N pin it.
      if [ "${pmask:0:1}" != "a" ] || [ "${pmask:1:1}" != "a" ] || [ "$pscope" = 1 ] || [ -e "$pj" ]; then
        trust="$(key_gate_project_trusted "$home" "$cwd")"
        case "$trust" in
          trusted) : ;;
          # pi drops the project scope entirely — including a file it never opened, so `prc` goes too: a read that
          # failed on a file pi ignores is not a datum about this box.
          untrusted) pp=""; pm=""; pmask="aa"; pscope=""; prc=0 ;;
          # ⛔ AN EMPTY ANSWER IS CANNOT-SAY TOO (round 3, F1/P2, measured): the probe prints NOTHING when the
          # trust store exists but cannot be parsed, and a `case` that only matched the literals let that empty
          # answer FALL THROUGH to the agent-dir pin — an unread datum was silently promoted to a verdict, and
          # refused 82 on a box pi runs. `*)` catches unknown AND empty.
          *) printf 'unreadable\t\t\t%s\n' "$pj"; return 0 ;;
        esac
      fi
      ;;
    '')
      # no cwd given: nothing project-scoped to read
      ;;
    *)
      # ⛔ A NON-ABSOLUTE cwd IS CANNOT-SAY, NOT "NO PROJECT FILE" (round 5, P2, measured). Falling through to
      # the agent-dir pair answered about a pin `pi` may not use — a false 82 when the trusted project pin was
      # the provisioned one, and a false `check=ok` in the other direction. `key_gate_project_trusted` already
      # answers `unknown` for this datum; the pair probe must not silently answer instead.
      printf 'unreadable\t\t\t%s\n' "$cwd"; return 0 ;;
  esac
  # A HALF-READ CANNOT ESTABLISH A PIN: if the file that must supply the other half did not answer, the pair is
  # unknown rather than absent.
  # ⛔ BUT ONLY WHEN THE FILE WOULD BE READ AT ALL (round 12, P3, measured): `loadFromStorage` returns `{}` for
  # scope `project` under `!projectTrusted`, so an UNTRUSTED project file is never opened by pi — a FIFO there gave
  # `settings-unreadable` about a file pi ignores, while the same box with an ABSENT project file printed a green
  # verdict from the agent-dir pin. Two states pi treats identically had opposite readings, and the lost one was
  # the fact #3443 item 3 asks for. `prc` is cleared in the `untrusted)` arm above; the trust answer `unknown` still
  # answers `unreadable` there, which is why a trust store that did not resolve is not swallowed here.
  if [ "$prc" = 3 ]; then printf 'unreadable\t\t\t%s\n' "$pj"; return 0; fi
  # ⛔ AND A KILLED AGENT-DIR READ IS ALWAYS `unreadable`, WITH NO TOLERANT EXCEPTION (round 7, P3, measured):
  # there used to be a branch that continued when the project pin was complete — but trust resolution itself READS
  # the agent-dir settings file (`defaultProjectTrust`), so a file that cannot be read there makes the trust answer
  # `unknown` first and the tolerant branch was unreachable. Dead code in a gate is worse than a missing arm: it
  # reads as protection nobody can exercise.
  if [ "$arc" = 3 ]; then printf 'unreadable\t\t\t%s\n' "$sj"; return 0; fi
  # ⛔ A SCOPED STARTUP IS A CANNOT-SAY, AND IT IS ANSWERED BEFORE THE PAIR IS ASSERTED (round 8, P2): see the
  # `enabledModels` note in MODE=default. The project file only counts when it is TRUSTED, which the block above
  # has already established.
  # ⛔ MERGED AS pi MERGES IT: the project file decides when it is present at all — including `[]`, which CLEARS
  # the agent-dir list — and the agent file only when the project does not set the key (`ascope` alone). `pscope`
  # is already blanked when the project is untrusted, so a dropped project file cannot clear anything.
  if [ "$pscope" = 1 ] || { [ "$pscope" != "n" ] && [ "$ascope" = 1 ]; }; then
    if [ "$pscope" = 1 ]; then printf 'scoped\t\t\t%s\n' "$pj"; else printf 'scoped\t\t\t%s\n' "$sj"; fi
    return 0
  fi
  # ⛔ MERGE PER KEY, HONOURING AN EXPLICIT CLEAR (round 5, P3): a project half that is PRESENT but null/empty
  # overrides the agent-dir one (`deepMergeObjects` treats null as a value), so it must NOT fall back.
  psrc=""; msrc=""
  case "${pmask:0:1}" in
    s) dp="$pp"; psrc="$pj" ;;
    n) dp="" ; psrc="$pj" ;;
    *) dp="$ap"; [ -n "$ap" ] && psrc="$sj" ;;
  esac
  case "${pmask:1:1}" in
    s) dm="$pm"; msrc="$pj" ;;
    n) dm="" ; msrc="$pj" ;;
    *) dm="$am"; [ -n "$am" ] && msrc="$sj" ;;
  esac
  [ -n "$dp" ] || [ -n "$dm" ] || { printf 'no-pin\t\t\t%s\n' "${psrc:-$sj}"; return 0; }
  # ⛔ `src` CREDITS ONLY THE FILES THAT SUPPLIED A HALF (round 5, P3): appending the agent-dir file because it
  # merely PINS something sent an operator to a file with no relevant content.
  # ⛔ FILE-PRIORITY ORDER, NOT HALF ORDER (round 6, P3): `src` was built provider-file + model-file, so a
  # project file that supplied the MODEL printed `<agent>+<project>` — the reverse of what the docs promise.
  use_pj=0; use_sj=0
  [ "$psrc" = "$pj" ] && use_pj=1
  [ "$msrc" = "$pj" ] && use_pj=1
  [ "$psrc" = "$sj" ] && use_sj=1
  [ "$msrc" = "$sj" ] && use_sj=1
  src=""
  [ "$use_pj" = 1 ] && src="$pj"
  [ "$use_sj" = 1 ] && src="${src:+$src+}$sj"
  [ -n "$src" ] || src="$sj"
  printf 'pin\t%s\t%s\t%s\n' "$dp" "$dm" "$src"
  return 0
}

# key_gate_box_default_assert <label> [<home>] [<mode>] [<cwd>] — THE STARTUP PIN a bare `pi` uses, unless
# `enabledModels` scopes the startup to another model (which is a cannot-say here: see MODE=default)
# (agent-infra#3443, fix items 2 and 3). Prints its reading; returns 0, or KEY_GATE_REFUSED in `refused`
# mode.
# ⛔ WHAT THIS PROBE ANSWERS, EXACTLY, BECAUSE THE FIRST CUT OF IT WAS WRONG (fresh-context review, P1).
# It asked "CAN THIS BOX RUN A BARE `pi`?" and answered NO on a box that runs fine. The vendor source says
# otherwise: `findInitialModel` uses the saved default ONLY when it is provisioned —
#     if (found && modelRuntime.hasConfiguredAuth(found.provider)) { … }
# — and otherwise falls through to "first available model with a valid API key"
# (`dist/core/model-resolver.js:502-521`). So an unprovisioned pin does NOT kill a bare `pi`; it makes `pi`
# run a model nobody pinned, silently, spending tokens on it — the #2208 silent-substitution class — or, when
# NOTHING is provisioned at all, exit 1 with `No API key found for the selected model.` (step 4 requires
# `availableModels.length > 0`; with none, step 5 returns `model: undefined` — `model-resolver.js:519-521` — the
# agent core substitutes its `DEFAULT_MODEL`, whose provider is the literal `"unknown"`
# (`pi-agent-core/dist/agent.js:18-22,40`), and `formatNoApiKeyFoundMessage` renders that as "the selected
# model" — `auth-guidance.js:3,17-20`. That is the exact sentence measured on cell-5, agent-infra#3443.) That is
# the fact this line reports, and the wording must not say "dies".
# ⛔ SO THE QUESTION IS "IS THE PIN USABLE?", NOT "CAN THIS BOX RUN?". `refused` = the standalone probe
# (`key-gate.sh --probe --box-default`), where 82 answers THAT question for a provisioning script. It is not
# a gate over a lane, and it is not a claim that the box cannot run an agent.
# ⛔ `warn` = the companion line `key_gate_assert` prints. A LANE pins its own provider/model, so an
# unusable box pin does NOT stop it; refusing there would block a lane that would have run, the false-block
# polarity this file's header forbids. It still SPEAKS on the one interesting arm, because a green
# `check=ok provider=deepseek` alone is what let the cell-5 operator read a box whose startup model was
# never provisioned as healthy.
# ⛔ AND IN `warn` MODE IT SPEAKS ON EXACTLY ONE ARM: the positively-absent credential. Every cannot-say arm
# AND the ok arm print NOTHING there, on purpose: this line lands in every lane log, and a line per lane is
# the noise class #3331 was filed about ("skipped 1034 … paused 250" burying the one line that mattered).
# It also runs BEFORE `key_gate_assert_main`, so the verdict line is the last `check=` line in every arm
# (a green companion printed after a REFUSED verdict made `grep check=ok` count a refused lane as healthy —
# measured by the same review).
key_gate_box_default_assert() {
  local label="${1:-key-gate}" home="${2:-${HOME:-}}" mode="${3:-refused}" cwd="${4:-${PWD:-}}" sel="${5:-}" quiet=0
  local agent_dir sj pair dp dm prov names n missing="" cands settings_files psel pprov pmodel status
  # `warn` is the quiet mode: it speaks on ONE arm only (a positively-absent credential), so a lane log does
  # not grow a line per lane. See the header block above for why that restriction exists.
  [ "$mode" = "warn" ] && quiet=1
  agent_dir="$(key_gate_agent_dir "$home" "$cwd")"
  # ⛔ THE STATUS COMES BACK ON THE PIPE, NOT IN A GLOBAL (measured): this call is a command substitution, so a
  # variable the probe sets lives and dies in its SUBSHELL — a `KEY_GATE_BOX_READ` global read one line later
  # was always empty, and the unreadable arm fell through to the absent-pin diagnosis. First field of the one
  # line the probe always prints.
  pair="$(key_gate_box_default "$home" "$cwd")"
  status="${pair%%$'\t'*}"
  if [ "$status" != "pin" ]; then
    [ "$quiet" = 1 ] && return 0
    # ⛔ A READ THAT DID NOT FINISH IS NOT AN ABSENT PIN (round 3, F3/P3, measured): a FIFO `settings.json`
    # under `KEY_GATE_BOUND`, or a python3 that died, printed the confident claim "this box pins NO startup
    # model" — the one arm an operator reads to conclude the box pins nothing. The status now distinguishes
    # the two, and the unreadable form refuses NOTHING (a datum we did not read is not a verdict).
    if [ "$status" = "unreadable" ]; then
      printf '[key-gate] %s check=skipped reason=settings-unreadable agent_dir=%s cwd=%s — the startup-settings read did NOT complete (a read the bound killed, python3 absent, a `default` settings.json that does not parse, or a trust store this gate could not evaluate), so whether this box pins a startup pair is a datum this gate did not get; nothing is asserted here. Re-run `key-gate.sh --probe --box-default` with KEY_GATE_BOUND raised, or inspect the file directly (agent-infra#3443)\n' \
        "$label" "${agent_dir:-<none>}" "${cwd:-<none>}"
      return 0
    fi
    # ⛔ A SCOPED STARTUP IS NOT AN ABSENT PIN EITHER (round 8, P2, verified against `main.js:389-403`): when
    # `enabledModels` is set and the pin is outside it, `pi` starts on `scopedModels[0]` — a pin this gate read is
    # then irrelevant, and the absent-pin wording would be a positive claim about a box that does pin something.
    if [ "$status" = "scoped" ]; then
      printf '[key-gate] %s check=skipped reason=enabled-models-scoped settings_json=%s — those settings set `enabledModels`, and pi starts on the FIRST model of that scope — unless the pinned pair is itself inside the scope, in which case it starts on the pin (`main.js`: `savedInScope` is checked BEFORE `scopedModels[0]`) — and only when the scope resolves to at least one AUTHENTICATED model (`resolveModelScope` → `getAvailable`, which filters to providers with a credential); with an empty resolved scope pi falls back to the pin. Resolving patterns needs the model registry, which this gate does not have, so which model a bare `pi` starts on here is not a datum this gate can read. Nothing is asserted, and the pin is NOT refused — unset `enabledModels`, or launch with `--provider … --model …` (agent-infra#3443)\n' \
        "$label" "${pair##*$'\t'}"
      return 0
    fi
    printf '[key-gate] %s check=skipped reason=no-default-model agent_dir=%s cwd=%s — this box pins NO startup model, so a bare `pi` falls through to ITS OWN built-in default and that provider is not a name this gate can assert. Pin defaultProvider+defaultModel in settings.json to a PROVISIONED pair, or launch with `--provider … --model …` (agent-infra#3443)\n' \
      "$label" "${agent_dir:-<none>}" "${cwd:-<none>}"
    return 0
  fi
  # ⛔ `$'\t'`, NOT a `\t` ESCAPE INSIDE THE PATTERN. In a bash pattern (and inside double quotes) `\t` is an
  # escaped literal `t`, so `${pair%%\t*}` strips from the last `t` in the string — the first cut of this
  # change split `deepseek<TAB>deepseek-flash` at the wrong place and every arm of the suite went rc=0.
  # `$'\t'` is a REAL tab in bash 3.2 and later, which is the floor this harness runs on. The parse starts at
  # field 2, because field 1 is the status.
  pair="${pair#*$'\t'}"
  dp="${pair%%$'\t'*}"; local rest="${pair#*$'\t'}"
  dm="${rest%%$'\t'*}"; sj="${rest#*$'\t'}"
  if [ -z "$dm" ]; then
    [ "$quiet" = 1 ] && return 0
    printf '[key-gate] %s check=skipped reason=default-model-missing provider=%s box_default=%s settings_json=%s — the settings pin a startup PROVIDER but no `defaultModel`, and pi resolves its startup pair ONLY when BOTH are set (`findInitialModel` step 3: `if (defaultProvider && defaultModelId)`), so which model it starts on is not a name this gate can assert. Set `defaultModel` beside `defaultProvider` (agent-infra#3443)\n' \
      "$label" "$dp" "$dp" "$sj"
    return 0
  fi
  if [ -z "$dp" ]; then
    [ "$quiet" = 1 ] && return 0
    # ⛔ THE TRUE REASON, NOT "the id carries no provider/ prefix" (round 3, F4/P3): a pin of
    # `defaultModel: "venice/x"` DOES carry a prefix, and the prefix is irrelevant here — the settings path
    # never splits one (only the CLI does), so step 3 matches no pair. The old wording pointed an operator at
    # adding the very thing that is already there.
    printf '[key-gate] %s check=skipped reason=default-model-provider-unknown model=%s box_default=%s settings_json=%s — those settings pin a startup MODEL but no `defaultProvider`, and the settings path does NOT split a `provider/` prefix (only the CLI does: `findInitialModel` step 3 takes the raw strings), so this pin matches no startup pair and `pi` substitutes. Set `defaultProvider` and `defaultModel` as two separate keys (agent-infra#3443)\n' \
      "$label" "$dm" "$dm" "$sj"
    return 0
  fi
  prov="$dp"
  # ⛔ THE SAME cwd THE PAIR WAS READ FROM (round 10, P2, measured): `key_gate_var` resolves the agent dir
  # itself, and with a RELATIVE `PI_CODING_AGENT_DIR` that resolution is against the cwd it is given. The pair
  # above is read with `$cwd` (the probe's own), so passing nothing here fell back to `$PWD` — a DIFFERENT store
  # when the CLI is asked about another worktree (`--probe --box-default <label> <home> <cwd>`, the documented
  # form). Measured: the pin came from `<cwd>/rel/settings.json` and the credential was "verified" against
  # `<PWD>/rel/models.json`, printing `check=ok` for a variable the box's own store does not name — the
  # false-PASS polarity the header forbids.
  names="$(key_gate_var "$home" "$prov" "$cwd")"
  # ⛔ THE STORE IS PROBED BEFORE THE TEMPLATE, AS pi READS IT (round 24, P2, measured) — THE SAME ORDERING THE LANE PATH
  # HAS HAD SINCE ROUND 21, which this arm never got: a `models.json` need not declare a built-in provider at all (the
  # NORMAL cell shape), and the early return below ran first, so on one box `--probe` refused `reason=store-invalid`
  # while `--probe --box-default` answered `reason=cannot-resolve-provider-credential` — the README advertises the
  # latter as refusing an unusable pin, and on the ordinary shape it structurally could not. The early return now sits
  # BELOW the store probe (it still applies when the store has no entry: then nothing names a variable to check).
  local store_rc=1
  key_gate_stored_credential "$home" "$prov" "$cwd"; store_rc=$?
  # ⛔ AND THAT PROBE RUNS BEFORE THE ENVIRONMENT TOO (round 20, P1, measured): with the key exported AND a store
  # entry pi cannot use, the old order printed `check=ok box_default=…` for a pin pi then refuses, while the same box
  # with the variable unset was refused - one box, two opposite verdicts, and the exported one was the false pass.
  case "$store_rc" in
    5)
      # The pin cannot be asserted AND the lane about to be dispatched cannot start on this store either, so in
      # `refused` mode (the standalone probe) this is a verdict about the FILE. A lane\x27s own `key_gate_assert`
      # refuses through the arm above, and `warn` mode stays quiet so one lane log does not carry it twice.
      [ "$quiet" = 1 ] && return 0
      printf '[key-gate] %s check=fail result=REFUSED reason=store-invalid model=%s box_default=%s provider=%s home=%s agent_dir=%s - %s/auth.json holds an entry pi cannot resolve to a key (an object whose `type` is "api_key" with a non-null `key`, or "oauth" with a non-empty string `access` and an `expires` that is a number, a numeric string or absent); measured: with such a store `pi -p` never reaches the provider — it prints the no-credential guidance (`No API key found` / `Use /login to log into a provider via OAuth or API key.`, depending on how the CLI is invoked) EVEN with the key exported, so this is a verdict about the FILE, not about a missing variable. Repair or delete `%s/auth.json` (agent-infra#3443)\n' \
        "$label" "$dm" "$dm" "$prov" "${home:-<none>}" "${agent_dir:-<none>}" "${agent_dir:-<none>}" "${agent_dir:-<none>}"
      return "$KEY_GATE_REFUSED" ;;
    6)
      # ⛔ THE FILE DOES NOT PARSE, SO NO PIN CAN BE ASSERTED FROM THIS BOX (round 22, P2, measured): pi answers
      # `Credential store read failed for <provider>: ...` and exits, with AND without the provider key exported.
      # The cannot-say bucket said "holds an entry for this provider whose value this gate cannot resolve" about a
      # file that holds no entry at all, and let a certain death through as a skip.
      [ "$quiet" = 1 ] && return 0
      printf '[key-gate] %s check=fail result=REFUSED reason=auth-store-unreadable model=%s box_default=%s provider=%s settings_json=%s home=%s agent_dir=%s - %s/auth.json does not PARSE, and pi reads that file before anything else: measured, `pi -p` answers `Credential store read failed for <provider>: ...` and exits, with AND without the provider key exported, so this is a verdict about the FILE and the pin cannot be asserted from it. Repair %s/auth.json (or delete it) and re-run (agent-infra#3443)\n' \
        "$label" "$dm" "$dm" "$prov" "$sj" "${home:-<none>}" "${agent_dir:-<none>}" "${agent_dir:-<none>}" "${agent_dir:-<none>}"
      return "$KEY_GATE_REFUSED" ;;
    0)
      # ⛔ IT STILL SPEAKS IN `refused` MODE (round 7, P3, measured): returning silently printed ZERO bytes and
      # exited 0, so an operator or a provisioning script could not tell "usable via the stored credential" from
      # "the probe did nothing" — every other arm of this function prints exactly one `check=` line there.
      [ "$quiet" = 1 ] && return 0
      printf '[key-gate] %s check=skipped reason=stored-credential box_default=%s model=%s provider=%s settings_json=%s — the credential for this pin is a STORED one under %s/auth.json (what `pi /login` writes, and the FIRST source pi consults), so whether the environment has to supply $%s at all is pi\x27s answer; nothing is asserted here, and the pin is NOT refused\n' \
        "$label" "$dm" "$dm" "$prov" "$sj" "${agent_dir:-<none>}" "$(printf '%s\n' "$names" | paste -sd ',' - 2>/dev/null)"
      return 0 ;;
    1) : ;;
    *)
      [ "$quiet" = 1 ] && return 0
      printf '[key-gate] %s check=skipped reason=stored-credential-unresolvable model=%s box_default=%s provider=%s settings_json=%s — %s/auth.json holds an entry for this provider whose value this gate cannot resolve (a `!command`, an `oauth` credential - only pi\x27s handler registry knows whether this provider takes one - or a template whose variables are absent from both the entry env map and this environment), and pi reads that store BEFORE the environment; whether $%s is consulted at all is pi\x27s answer, so nothing is asserted about this pin\n' \
        "$label" "$dm" "$dm" "$prov" "$sj" "${agent_dir:-<none>}" "$(printf '%s\n' "$names" | paste -sd ',' - 2>/dev/null)"
      return 0 ;;
  esac
  # ⛔ THE TEMPLATE GATE NOW SITS HERE, AFTER THE STORE (round 24, P2 — see the ordering note above). With no entry in
  # the store there is nothing to assert FROM the template: an empty `names` would otherwise fall through to the
  # `check=ok` arm below with a blank `var=`, which is a pass line about nothing.
  if [ -z "$names" ]; then
    [ "$quiet" = 1 ] && return 0
    printf '[key-gate] %s check=skipped reason=cannot-resolve-provider-credential model=%s box_default=%s provider=%s settings_json=%s — the apiKey template for the STARTUP provider is not resolvable, so nothing is asserted here\n' \
      "$label" "$dm" "$dm" "$prov" "$sj"
    return 0
  fi
  for n in $names; do
    key_gate_value_present "$n" || { missing="$n"; break; }
  done
  if [ -z "$missing" ]; then
    [ "$quiet" = 1 ] && return 0
    # ⛔ WHAT THIS LINE ASSERTS AND WHAT IT DOES NOT (review round 2, P2): the CREDENTIAL for the pinned pair
    # resolves — pi additionally needs `modelRuntime.getModel(dp, dm)` to FIND that pair, which this gate
    # cannot read (the built-ins are not in any settings file). Saying "the model a BARE `pi` would start on"
    # claimed the finding too; the id is printed so an operator can check it.
    printf '[key-gate] %s check=ok box_default=%s model=%s provider=%s var=%s settings_json=%s — the CREDENTIAL for the startup pair this box pins resolves in this environment, and %s/auth.json has NO entry for this provider (pi still has to know the model id %s; this line asserts the key, not that the id exists)\n' \
      "$label" "$dm" "$dm" "$prov" "$(printf '%s\n' "$names" | paste -sd ',' - 2>/dev/null)" "$sj" "${agent_dir:-<none>}" "$dm"
    return 0
  fi
  cands="$(key_gate_candidates "$home" | paste -sd '|' - 2>/dev/null)"
  [ -n "$cands" ] || cands="<none-derivable>"
  if [ "$quiet" = 1 ]; then
    # ⛔ THE TRUE CONSEQUENCE, NOT A CONVENIENT ONE: pi SKIPS an unprovisioned pin and runs whatever model it
    # does find (`findInitialModel` step 3 → step 4), so the harm is a silent substitution, not a death.
    # ⛔ AND THE PAIR IT NAMES IS RESOLVED HERE, NOT READ FROM GLOBALS (review round 2, P2, measured): the
    # companion runs BEFORE `key_gate_assert_main`, which is the only place `KEY_GATE_PROVIDER`/`_MODEL` are
    # assigned — so reading them printed `provider= model=` (blank) in production, and a STALE pair when two
    # calls shared a process (lane 8 in a test got lane 7's model). The caller passes the resolved pair in.
    if [ -n "$sel" ]; then
      psel="$sel"; pprov="${psel%%$'\t'*}"; pmodel="${psel#*$'\t'}"
    else
      pprov=""; pmodel=""
    fi
    printf '[key-gate] %s check=warn reason=box-default-not-provisioned box_default=%s model=%s provider=%s var=%s settings_json=%s — this box pins its STARTUP model to %s, and $%s holds no value here, so a `pi` launched with NO model flag will NOT start on %s: pi uses the saved default only when the provider is provisioned and otherwise falls through to step 4 of `findInitialModel` — the first model with a valid key, preferring the known default model of that provider — so it either runs a model nobody pinned and spends tokens on it (the #2208 silent-substitution class), or, when NO provider is provisioned at all, exits 1 with `No API key found for the selected model.` %s Pin a PROVISIONED defaultProvider/defaultModel in settings.json, or launch with `--provider … --model …` (agent-infra#3443)\n' \
      "$label" "$dm" "$dm" "$prov" "$missing" "$sj" "$dm" "$missing" "$dm" \
      "$( [ -n "$pprov" ] && printf 'THIS LANE PINS provider=%s model=%s, so this line does not stop it — every bare `pi` on this box is affected.' "$pprov" "$pmodel" )"
    return 0
  fi
  printf '[key-gate] %s check=fail result=REFUSED reason=box-default-not-provisioned model=%s box_default=%s provider=%s var=%s settings_json=%s models_json=%s candidates=%s\n' \
    "$label" "$dm" "$dm" "$prov" "$missing" "$sj" "${agent_dir:+$agent_dir/models.json}" "$cands"
  printf '[key-gate] %s: the STARTUP model this box pins (%s under provider %s) resolves its credential from $%s, which holds no value here — so the pin is NOT USABLE and `pi` will not start on it: it uses a saved default only when the provider is provisioned and otherwise falls through to step 4 of `findInitialModel` — the first model with a valid key, preferring the known default model of that provider — a model nobody pinned, silently and at cost (the #2208 class) — or, if NOTHING is provisioned, exits 1 with `No API key found for the selected model.` This is a verdict about the PIN, NOT a claim that the box cannot run an agent. Pin a provisioned pair in settings.json (or export %s, or point ENV_FILE at a file that does). ⛔ AND NOTE THE OTHER HALF: sourcing a keys file is NOT the general remedy for this class — measured on cell-5 (agent-infra#3443) the keys file held only GH_TOKEN — no model key at all — and what actually worked was the MODEL FLAG `pi -p --no-session --provider %s --model %s` — but note it fixes the LANE\x27s invocation only: on THIS arm the printed pair is the one that has no credential, so export %s (or pin a provisioned pair) before running it.\n' \
    "$label" "$dm" "$prov" "$missing" "$missing" "$prov" "$dm" "$missing"
  return "$KEY_GATE_REFUSED"
}

# key_gate_assert <label> [<home>] [<provider>] [<model>]
#   prints ONE verdict line, PRECEDED by a `check=warn reason=box-default-not-provisioned` companion on that
#   one arm and FOLLOWED by a human-facing sentence on refusal — so the verdict is always the LAST `check=`
#   line, and a non-refused call can print two of them (round 17, P3: this sentence said the second line
#   appeared "only on refusal", which the companion's own warn arm falsifies). Returns 0, or KEY_GATE_REFUSED.
# ⛔ THE COMPANION IS A WRAPPER, NOT A BRANCH IN EVERY ARM (agent-infra#3443). `key_gate_assert_main` is
# five return points; adding the second reading to each is how one arm silently loses it. The body keeps
# one verdict; only the wrapper adds the box-default reading, so EVERY arm gets it.
# ⛔ AND THE COMPANION RUNS **FIRST** (fresh-context review, P2): printed after the verdict it put a green
# `check=ok box_default=…` after a `result=REFUSED` line, and `grep check=ok` over a lane log then counted a
# refused lane as healthy. The verdict is the last `check=` line in every arm, by construction.
key_gate_assert() {
  local rc sel
  sel="$(key_gate_selected_model "${4:-}" "${3:-}")"
  # ⛔ THE cwd IS FORWARDED EXPLICITLY, and it is the same value the probe would default to (`${PWD:-}`) — so a
  # mutant that drops the argument changes NOTHING (measured, round 7): the parameter default is `${4:-${PWD:-}}`,
  # where `:-` treats an empty or absent `$4` alike. It stays explicit so a future `cd` between the two lines
  # cannot silently change which worktree's `.pi/settings.json` the companion reports.
  key_gate_box_default_assert "${1:-key-gate}" "${2:-${HOME:-}}" warn "${PWD:-}" "$sel"
  key_gate_assert_main "$@"; rc=$?
  return "$rc"
}
key_gate_assert_main() {
  local label="${1:-key-gate}" home="${2:-${HOME:-}}" prov="${3:-}" model="${4:-}" sel cwd="${PWD:-}"
  sel="$(key_gate_selected_model "$model" "$prov")"
  KEY_GATE_PROVIDER="${sel%%$'\t'*}"; KEY_GATE_MODEL="${sel#*$'\t'}"
  KEY_GATE_VAR=""; KEY_GATE_REASON=""; KEY_GATE_MODELS_JSON=""; KEY_GATE_AGENT_DIR=""
  KEY_GATE_AGENT_DIR="$(key_gate_agent_dir "$home" "$cwd")"
  [ -n "$KEY_GATE_AGENT_DIR" ] && KEY_GATE_MODELS_JSON="$KEY_GATE_AGENT_DIR/models.json"
  local names n missing=""
  # ⛔ THE STORE IS PROBED BEFORE THE TEMPLATE, NOT JUST BEFORE THE ENVIRONMENT (round 21, P1, measured). pi reads
  # `auth.json` FIRST and a `models.json` need not declare a built-in provider at all - the normal cell shape - so
  # gating this probe behind `key_gate_var` left an unusable store entry reported as
  # `check=skipped reason=cannot-resolve-provider-credential` ("a provisioning detail") on a box where `pi -p`
  # prints `No API key found for deepseek.` and exits. Measured: `models.json` = `{}`, `auth.json` =
  # `{"deepseek":{"key":"sk-legacy-no-type"}}`, DEEPSEEK_API_KEY exported -> gate skipped, pi died.
  local store_rc=1
  key_gate_stored_credential "$home" "$KEY_GATE_PROVIDER" "$cwd"; store_rc=$?
  names="$(key_gate_var "$home" "$KEY_GATE_PROVIDER")"
  if [ "$store_rc" = "5" ]; then
    # The variable is unknown when the template is absent, so the line names the provider instead of pretending.
    KEY_GATE_VAR="${names:-<none>}"
    KEY_GATE_VAR="${KEY_GATE_VAR%%$'\n'*}"
    # ⛔ THE LANE TOKEN READS THIS (round 22, P2, measured): `lane.sh` writes
    # `key-gate:${KEY_GATE_REASON:-credential-missing}:${KEY_GATE_VAR}:${KEY_GATE_MODEL}`, so leaving it unset for
    # this arm made a store-invalid refusal publish `reason=key-gate:credential-missing:...` - the exact
    # misattribution this file's header forbids, and the value was already being set for the env-missing arm.
    KEY_GATE_REASON="store-invalid"
    printf '[key-gate] %s check=fail result=REFUSED reason=store-invalid model=%s provider=%s var=%s home=%s agent_dir=%s - the credential store is INVALID: %s/auth.json holds an entry for this provider that pi cannot resolve to a key (it must be an OBJECT whose `type` is "api_key" with a non-null `key`, or "oauth" with a non-empty string `access` and an `expires` that is a number, a numeric string or absent), and that entry SHADOWS the environment instead of falling back to it - measured: `pi -p` prints `No API key found for <provider>.` with nothing exported and `Provider is not configured: <provider>` even WITH the key exported and a models.json template naming it. So this is a verdict about the FILE, not about a missing variable: repair %s/auth.json (or delete it) and re-run (agent-infra#3443)\n' \
      "$label" "$KEY_GATE_MODEL" "$KEY_GATE_PROVIDER" "$KEY_GATE_VAR" "${home:-<none>}" "${KEY_GATE_AGENT_DIR:-<none>}" "${KEY_GATE_AGENT_DIR:-<none>}" "${KEY_GATE_AGENT_DIR:-<none>}"
    return "$KEY_GATE_REFUSED"
  fi
  if [ "$store_rc" = "6" ]; then
    # ⛔ A STORE THAT DOES NOT PARSE IS A REFUSAL, NOT A CANNOT-SAY (round 22, P2, measured): pi's
    # `parseStorageData` is a bare `JSON.parse`, so it answers `Credential store read failed for <provider>:
    # Expected property name ...` and exits - with AND without the provider key exported, for every provider.
    # The old rc-4 answer printed "holds an entry for this provider whose value this gate cannot resolve (a
    # `!command`, an `oauth` credential ...)" about a file that holds no entry at all, and let that death through.
    KEY_GATE_VAR="${names:-<none>}"
    KEY_GATE_VAR="${KEY_GATE_VAR%%$'\n'*}"
    KEY_GATE_REASON="auth-store-unreadable"
    printf '[key-gate] %s check=fail result=REFUSED reason=auth-store-unreadable model=%s provider=%s var=%s home=%s agent_dir=%s - %s/auth.json does not PARSE, and pi reads that file before anything else: measured, `pi -p` answers `Credential store read failed for <provider>: ...` and exits, with AND without the provider key exported. No entry is resolvable from it, so `export $%s` cannot help: repair %s/auth.json (or delete it) and re-run (agent-infra#3443)\n' \
      "$label" "$KEY_GATE_MODEL" "$KEY_GATE_PROVIDER" "$KEY_GATE_VAR" "${home:-<none>}" "${KEY_GATE_AGENT_DIR:-<none>}" "${KEY_GATE_AGENT_DIR:-<none>}" "$KEY_GATE_VAR" "${KEY_GATE_AGENT_DIR:-<none>}"
    return "$KEY_GATE_REFUSED"
  fi
  if [ -z "$KEY_GATE_PROVIDER" ]; then
    # ⛔ A NAMED MODEL WITH NO PROVIDER IS ITS OWN CANNOT-SAY (rounds 18-19, measured): pi's provider inference
    # needs the model registry AND the auth state this gate does not read, so any provider name chosen here would
    # be a guess. Nothing is asserted, and the line names the form that DOES get a verdict.
    printf '[key-gate] %s check=skipped reason=cannot-resolve-provider-credential model=%s provider=<none> home=%s — this model was NAMED and NOTHING named a provider (no `--provider`, no $PI_LANE_PROVIDER), so which provider pi resolves needs the model registry and the auth state THIS gate does not read: a `provider/` prefix counts only when it names a provider that HAS models, else the whole string is matched as a model id across every provider, and a sole authenticated raw-id match wins even over a matched inference (`dist/core/model-resolver.js:322-345,388-420`); a bare id can also be AMBIGUOUS across providers. Measured: with provider `aaa` declaring model `q` and provider `bbb` declaring the id `aaa/x`, `pi -p --model aaa/x` ran on bbb while an earlier cut of this gate asserted aaa\x27s variable, and `--model gpt-4o` was refused by pi as ambiguous while the gate called it ok. An INHERITED model ($PI_LANE_MODEL) is asserted under `deepseek`, because that is the `--provider` run_agent passes. Nothing is asserted for a named model here: pass --provider … --model … to get a verdict (agent-infra#3443)\n' \
      "$label" "$KEY_GATE_MODEL" "${home:-<none>}"
    return 0
  fi
  if [ "$store_rc" = "0" ]; then
    # The store is what `pi` reads FIRST, so an absent variable is not an absent credential. Nothing is
    # asserted — and the line says WHICH source answered, so an operator reading a green gate is not
    # misled into thinking the environment carries the key.
    # ⛔ THE TEMPLATE VARIABLE IS THE ONE `key_gate_var` ACTUALLY RETURNED (round 22, P3, measured: the round-21 cut
    # printed `$<none>` twice, asserting a false fact about a models.json that names a real variable).
    local tmpl_names
    tmpl_names="$(printf '%s\n' "${names:-<none>}" | paste -sd ',' - 2>/dev/null)"
    printf '[key-gate] %s check=skipped reason=stored-credential provider=%s model=%s home=%s agent_dir=%s — %s/auth.json holds a credential for this provider, and pi consults that store BEFORE the environment (and before the models.json template that names $%s), so whether $%s is exported here is not the question pi asks first; nothing is asserted here\n' \
      "$label" "$KEY_GATE_PROVIDER" "$KEY_GATE_MODEL" "${home:-<none>}" "${KEY_GATE_AGENT_DIR:-<none>}" "${KEY_GATE_AGENT_DIR:-<none>}" "${tmpl_names:-<none>}" "${tmpl_names:-<none>}"
    return 0
  fi
  if [ "$store_rc" = "3" ] || [ "$store_rc" = "4" ]; then
    # ⛔ A STORE ENTRY THIS GATE CANNOT RESOLVE IS NOT A CREDENTIAL AND IS NOT A REFUSAL (review cycle 1,
    # P2): `auth.json` holds a `!command` value, so only pi can say whether it yields a key. Saying
    # `holds a credential` here would be the same FALSE PASS the `env`-without-`key` arm was fixed for; a
    # refusal would be a false block on a box that works. The third answer is the honest one.
    printf '[key-gate] %s check=skipped reason=stored-credential-unresolvable provider=%s model=%s home=%s agent_dir=%s — %s/auth.json holds an entry for this provider whose value this gate cannot resolve (a `!command`, an `oauth` credential - only pi\x27s handler registry knows whether this provider takes one - or a template whose variables are absent from both the entry env map and this environment); whether that yields a key is pi\x27s answer alone, so NOTHING is asserted here\n' \
      "$label" "$KEY_GATE_PROVIDER" "$KEY_GATE_MODEL" "${home:-<none>}" "${KEY_GATE_AGENT_DIR:-<none>}" "${KEY_GATE_AGENT_DIR:-<none>}"
    return 0
  fi
  if [ -z "$names" ]; then
    # Blindness is not a refusal (see the header's polarity rule).
    printf '[key-gate] %s check=skipped reason=cannot-resolve-provider-credential model=%s provider=%s home=%s — the apiKey template for this provider is not resolvable from %s (absent, unparseable, a literal, no python3, a `!command` value, or a provider pi authenticates itself), so NOTHING is asserted here\n' \
      "$label" "$KEY_GATE_MODEL" "$KEY_GATE_PROVIDER" "${home:-<none>}" "${KEY_GATE_MODELS_JSON:-<none>}"
    return 0
  fi
  # EVERY name a multi-reference template names must hold a value (review cycle 1, P2): pi refuses the
  # provider unless all of them resolve, so asserting only the first would pass a lane pi still kills.
  KEY_GATE_VAR="$(printf '%s\n' "$names" | paste -sd ',' - 2>/dev/null)"
  for n in $names; do
    key_gate_value_present "$n" || { missing="$n"; break; }
  done
  [ -n "$missing" ] && KEY_GATE_VAR="$missing"
  if [ -z "$missing" ]; then
    printf '[key-gate] %s check=ok var=%s provider=%s model=%s home=%s — the credential holds a value in the environment this lane runs with, and %s/auth.json has NO entry for this provider (so the environment is the source pi resolves)\n' \
      "$label" "$KEY_GATE_VAR" "$KEY_GATE_PROVIDER" "$KEY_GATE_MODEL" "${home:-<none>}" "${KEY_GATE_AGENT_DIR:-<none>}"
    return 0
  fi
  KEY_GATE_REASON="credential-missing"
  # One token line (greppable) + one sentence (actionable). The candidate list is `|`-joined so the
  # token line stays a single field an operator or a scanner can cut.
  local cands
  cands="$(key_gate_candidates "$home" | paste -sd '|' - 2>/dev/null)"
  [ -n "$cands" ] || cands="<none-derivable>"
  printf '[key-gate] %s check=fail result=REFUSED reason=%s var=%s provider=%s model=%s agent_dir=%s models_json=%s candidates=%s\n' \
    "$label" "$KEY_GATE_REASON" "$KEY_GATE_VAR" "$KEY_GATE_PROVIDER" "$KEY_GATE_MODEL" "${KEY_GATE_AGENT_DIR:-<none>}" "${KEY_GATE_MODELS_JSON:-<none>}" "$cands"
  printf '[key-gate] %s: $%s holds no value in the environment this lane would run with, so `pi` would start, print "No API key found", and exit having done nothing. ⛔ ON A CELL THIS IS THE TRAP: HOME is redirected to the operational home (%s) so the operational layer is found, and the credential usually lives in the ACCOUNT home instead — check every candidate above, export $%s (or point ENV_FILE at a file that does), then re-dispatch. ⛔ THIS LANE RUNS provider=%s model=%s, and `pi -p --no-session --provider %s --model %s` is the invocation this verdict is about; a bare `pi` with no model flag asks a DIFFERENT question (see the box-default line above, when the companion speaks) — measured on cell-5, where the keys file held only GH_TOKEN and the MODEL FLAG was the fix (agent-infra#3443).\n' \
    "$label" "$KEY_GATE_VAR" "${CELL_HOME:-/tmp/cell-home}" "$KEY_GATE_VAR" "$KEY_GATE_PROVIDER" "$KEY_GATE_MODEL" "$KEY_GATE_PROVIDER" "$KEY_GATE_MODEL"
  return "$KEY_GATE_REFUSED"
}

# `key-gate.sh --probe <label> [<home>] [<provider>] [<model>]` — the human/CI entry point, so an operator
# can ask the question without running a lane (and the suite drives the shipped code, not a copy).
# `key-gate.sh --probe --box-default [<label>] [<home>] [<cwd>]` asks the OTHER question — IS THE PINNED
# STARTUP PAIR USABLE? — refusing 82 when the startup pair's credential is positively absent (agent-infra#3443).
# ⛔ NOT "can this box run a bare pi": an unprovisioned pin does not kill pi, it makes pi substitute a model
# (see `key_gate_box_default_assert`'s header); the verdict is about the PIN, and the refusal prose says so.
if [ "${BASH_SOURCE[0]:-}" = "${0:-}" ]; then
  if [ "${1:-}" = "--probe" ]; then
    shift
  elif [ $# -gt 0 ]; then
    printf 'usage: key-gate.sh --probe <label> [<home>] [<provider>] [<model>]\n       key-gate.sh --probe --box-default <label> [<home>] [<cwd>]\n' >&2
    exit 64
  fi
  if [ "${1:-}" = "--box-default" ]; then
    shift
    key_gate_box_default_assert "${1:-key-gate}" "${2:-${HOME:-}}" refused "${3:-${PWD:-}}"
    exit $?
  fi
  key_gate_assert "${1:-key-gate}" "${2:-${HOME:-}}" "${3:-}" "${4:-}"
  exit $?
fi
