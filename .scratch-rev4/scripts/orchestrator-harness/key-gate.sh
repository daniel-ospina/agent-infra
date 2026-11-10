#!/usr/bin/env bash
# key-gate.sh — the LAST assertion before `pi` is spawned: the model credential its provider resolves
# must hold a value IN THE ENVIRONMENT THE LANE WILL ACTUALLY RUN WITH (agent-infra#3331).
#
# Callers source this and call ONE function:
#     . key-gate.sh
#     key_gate_assert "lane 42" "${HOME:-}"      # one verdict line (+ a warning line on one arm), 0 or KEY_GATE_REFUSED
#
# THE DEFECT THIS REFUSES — measured 2026-11-02 on two cloud cells. A lane ran with
# `HOME=/tmp/cell-home` (the LEGACY volatile home: agent-infra#3453 has since unified every unit on the
# durable `/home/cmux`, and this file now DERIVES it rather than naming it), which redirected the
# operational layer (`record-review.sh`, the gh shim, the extensions) to `$CELL_HOME/.pi/agent`. But the
# model credential lived in `/home/cmux/keys.env` — under the ACCOUNT home — and `lane-env.sh` sources
# `${ENV_FILE:-$HOME/keys.env}`, i.e. the redirected one. So the single setting that made the operational
# layer work was the setting that hid the credential. `pi` started, found no key, and was gone:
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
# So this gate now names the model on every line, and it asserts a credential only for a provider that was
# NAMED (`--provider`, `$PI_LANE_PROVIDER`, or a box default). ⛔ A `provider/` PREFIX IS **NOT** A PROVIDER AND IS NOT
# INFERRED (round 18, P1, measured): pi matches a prefixed id across providers, so an inference here printed
# `check=ok var=AAA_KEY provider=aaa` over a lane pi ran on `bbb` - the false PASS this file exists to prevent. For a
# NAMED model with no provider the gate abstains (`check=skipped ... provider=<none>`) and says which form gets a
# verdict. It also reports the model a BARE `pi` would start on when that one is not verifiably provisioned
# (`key_gate_box_default_assert`) — the shape that produced `No API key found for the selected model.`
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

# ⛔ THE ONE HOME (agent-infra#3453): this used to default to the legacy `/tmp/cell-home`, so the
# candidate list this function builds pointed at a home no other cell unit agreed with — the split
# whose symptom is "the credential IS on the box and `git push` still answers 403". Derived by
# `scripts/lib/cell-home.sh` (`../lib/` from the harness dir: checkout, pinned worktree, flat farm).
# ⛔ THE SELF PATH COUNTS ONLY WHEN IT NAMES THIS FILE — see `lib/cell-home.sh` §CONSUMERS. A PIPED
# start (`bash -s`) has no `BASH_SOURCE` and its `$0` is LITERALLY `bash`, so `dirname "${BASH_SOURCE[0]:-$0}"`
# answers `.` and the candidate becomes `<parent-of-CWD>/lib/cell-home.sh`: this gate then SOURCES code
# out of a directory it does not own (measured here: a planted fixture sourced and ran, `cell_home_resolve`
# came back command-not-found and `CELL_HOME` stayed empty). Guarded, a piped start has no sibling to
# trust and takes the documented `$HOME` fallback below instead.
_SELF="${BASH_SOURCE[0]:-}"; [ -f "$_SELF" ] || _SELF=""
KG_SELF_DIR=""
if [ -n "$_SELF" ]; then KG_SELF_DIR="$(cd "$(dirname "$_SELF")/.." 2>/dev/null && pwd -P)"; fi
CELL_HOME_LIB=""
if [ -n "$KG_SELF_DIR" ] && [ -r "$KG_SELF_DIR/lib/cell-home.sh" ]; then CELL_HOME_LIB="$KG_SELF_DIR/lib/cell-home.sh"; fi
if [ -n "$CELL_HOME_LIB" ]; then . "$CELL_HOME_LIB"; CELL_HOME="$(cell_home_resolve)"; else CELL_HOME="${CELL_HOME:-${HOME:-}}"; fi

# The refusal carries its own status: 82 is unassigned elsewhere in this tree (70-83 are spawn-gate's,
# repo-target's and brief-gate's — 83 is the HARNESS/SKEW gate since agent-infra#3237; 93-98 are the
# worker launch-line guards'), and a shared code would
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

# \u26d4 AN UNENCODABLE CHARACTER MUST NEVER KILL THIS PAYLOAD (round 47, P1, measured). `models.json` is USER DATA and
# every token below interpolates some of it (`no-api:<id>`, `known:<provider>`, a template variable name), so ONE lone
# surrogate (`\ud800`, which python\x27s `json` ACCEPTS) or one ordinary non-ASCII id under `PYTHONIOENCODING=ascii` made a
# `print` raise `UnicodeEncodeError` \u2014 the interpreter died, the caller runs it with `2>/dev/null`, `drop` came back
# EMPTY, and the gate printed `check=ok` over a box pi cannot start: measured, a granted api-less fixture whose model id
# is `deepseek\ud800` answered `RC=82 models-json-bad-gateway` before the shape was routed here and `RC=0 check=ok`
# after. Guarding the two prints that failed would leave the same hole at the NEXT one that interpolates a document
# field, which is why this is ONE place: whatever this payload cannot encode is escaped rather than raised, so a
# diagnostic token can never become a verdict. ASCII-only output is unchanged.
try:
    sys.stdout.reconfigure(errors="backslashreplace")
except Exception:
    pass


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


def _js_str(v):
    """The result of JS `+` on a non-string: `true`/`false`, numbers, and the joining forms for arrays/objects.
    ⛔ A faithful-enough port for a CREDENTIAL STRING: pi only needs the concatenation to produce something, and every
    branch here is reachable from a fixture (round 27, P1)."""
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return repr(v) if isinstance(v, float) else str(v)
    if isinstance(v, list):
        return ",".join("" if x is None else _js_str(x) for x in v)
    if isinstance(v, dict):
        return "[object Object]"
    return str(v)


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
        # ⛔ JS `+` STRINGIFIES, PYTHON RAISES (round 27, P1, measured): `resolveEnvConfigValue` returns the RAW value
        # (`resolve-config-value.js:71-73`) and `resolveTemplate` does `resolved += envValue` (`:83-95`), so an `env` map
        # like `{"A": 5}` yields the key `sk-5` — measured: pi sent `sk-5` (401) for `{"deepseek":{"type":"api_key",
        # "key":"sk-${A}","env":{"A":5}}}` and the same for an array/object/`true`. `out += v` raised TypeError here,
        # the interpreter exited 1, and rc 1 is the POSITIVE "no credential for this provider" — so the gate refused a
        # box pi runs, and with the template variable exported it asserted "auth.json has NO entry for this provider"
        # about an entry that IS the source pi resolves. The four JS scalar renderings are reproduced exactly.
        out += _js_str(v)
    return ("ok", out) if out.strip() else ("missing", None)


# MODE=builtin — pi\x27s OWN built-in provider table, which is how a provider is provisioned when models.json declares
# nothing for it (`dist/env-api-keys.js` `getApiKeyEnvVars`, the same table `getEnvApiKey` and `findEnvKeys` read).
# ⛔ THIS IS THE NORMAL CELL SHAPE, AND IT WAS THE #3443 DEFECT: with no models.json there is no template to name a
# variable, so the gate answered `cannot-resolve-provider-credential` (rc 0, "nothing wrong") on a box where `pi -p`
# printed `No API key found for deepseek.` and exited — measured on the installed pi, both directions: with
# DEEPSEEK_API_KEY exported pi reaches the provider (401), without it pi says exactly that line and stops.
# A provider whose var is NOT sufficient on its own stays `uncertain` and refuses nothing — measured:
# CLOUDFLARE_API_KEY alone still answers `No API key found for cloudflare-workers-ai.`, and GOOGLE_CLOUD_API_KEY alone
# makes pi attempt the call (so ADC is an alternate path we cannot see), and AZURE_OPENAI_API_KEY alone dies on
# `Azure OpenAI base URL is required` — a different datum, not the credential.
BUILTIN_ENV = {
    "ant-ling": ["ANT_LING_API_KEY"],
    "qwen-token-plan": ["QWEN_TOKEN_PLAN_API_KEY"],
    "qwen-token-plan-cn": ["QWEN_TOKEN_PLAN_CN_API_KEY"],
    "qwen-token-plan-individual": ["QWEN_TOKEN_PLAN_API_KEY"],
    "openai": ["OPENAI_API_KEY"],
    "nvidia": ["NVIDIA_API_KEY"],
    "deepseek": ["DEEPSEEK_API_KEY"],
    "google": ["GEMINI_API_KEY"],
    "groq": ["GROQ_API_KEY"],
    "cerebras": ["CEREBRAS_API_KEY"],
    "xai": ["XAI_API_KEY"],
    "openrouter": ["OPENROUTER_API_KEY"],
    "vercel-ai-gateway": ["AI_GATEWAY_API_KEY"],
    "zai": ["ZAI_API_KEY"],
    "zai-coding-cn": ["ZAI_CODING_CN_API_KEY"],
    "mistral": ["MISTRAL_API_KEY"],
    "minimax": ["MINIMAX_API_KEY"],
    "minimax-cn": ["MINIMAX_CN_API_KEY"],
    "moonshotai": ["MOONSHOT_API_KEY"],
    "moonshotai-cn": ["MOONSHOT_API_KEY"],
    "huggingface": ["HF_TOKEN"],
    "fireworks": ["FIREWORKS_API_KEY"],
    "together": ["TOGETHER_API_KEY"],
    "baseten": ["BASETEN_API_KEY"],
    "opencode": ["OPENCODE_API_KEY"],
    "opencode-go": ["OPENCODE_API_KEY"],
    "kimi-coding": ["KIMI_API_KEY"],
    "meta": ["META_API_KEY"],
    "xiaomi": ["XIAOMI_API_KEY"],
    "xiaomi-token-plan-cn": ["XIAOMI_TOKEN_PLAN_CN_API_KEY"],
    "xiaomi-token-plan-ams": ["XIAOMI_TOKEN_PLAN_AMS_API_KEY"],
    "xiaomi-token-plan-sgp": ["XIAOMI_TOKEN_PLAN_SGP_API_KEY"],
    "anthropic": ["ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_OAUTH_TOKEN", "ANTHROPIC_API_KEY"],
    # ⛔ THESE THREE ARE DECIDABLE AND WERE NOT (round 29, P3, measured with ONLY the variable set): each answers
    # `pi auth check` ready, lists its models, and REACHES the provider (vertex 401 "API keys are not supported by this
    # API", copilot 400 bad Authorization header, radius 401 org-config) — so the variable alone is what provisions
    # them, which is all this gate claims. Keeping them `uncertain` forfeited every verdict on three providers the fleet
    # uses, and the doc then stated that forfeit as a fact.
    "github-copilot": ["COPILOT_GITHUB_TOKEN"],
    "radius": ["RADIUS_API_KEY"],
}
# ⛔ AND A PROVIDER WHOSE VARIABLE IS NOT THE WHOLE ANSWER STAYS HERE (measured, round 29): `pi --list-models` reports
# `not_ready` for cloudflare with only CLOUDFLARE_API_KEY, and azure dies on `Azure OpenAI base URL is required`. A
# refusal on either would be a false block, so the line names the variable and refuses nothing.
BUILTIN_UNCERTAIN = {
    # ⛔ THE VARIABLE IS ACCEPTED BY THE VENDOR AND REJECTED BY THE API (round 31, P2, measured): with
    # `GOOGLE_CLOUD_API_KEY` set, `pi -p --provider google-vertex --model gemini-2.5-pro` signs the call and Vertex
    # answers 401 `API keys are not supported by this API. Expected OAuth2 access token or other authentication
    # credentials that assert a principal`. So the key makes the gate\x27s own question ("does a credential exist")
    # true while the lane\x27s first model call fails — the false PASS this issue is about — and it is the same datum
    # that keeps `azure` uncertain. The ADC path is the one that yields `check=ok` (see BUILTIN_PATHS).
    "google-vertex": "GOOGLE_CLOUD_API_KEY:measured, the key alone is accepted by pi and REJECTED by the API (401 "
                     "\"API keys are not supported by this API\"); Application Default Credentials + a project + a "
                     "location DO provision it, and that path is checked separately",
    "typesafe": "TYPESAFE_API_KEY:measured, pi ships CLASSIFIER models only for it, so `pi -p` answers `Unknown provider`",
    "azure": "AZURE_OPENAI_API_KEY:measured, the key alone answers `Azure OpenAI base URL is required`",
    "cloudflare-workers-ai": "CLOUDFLARE_API_KEY:measured, the key alone still answers `No API key found`",
    "cloudflare-ai-gateway": "CLOUDFLARE_API_KEY:needs CLOUDFLARE_ACCOUNT_ID and CLOUDFLARE_GATEWAY_ID too",
}
# ⛔ PROVIDERS THE VENDOR SHIPS WITH NO API-KEY ENV VAR (round 29, P3, measured): `amazon-bedrock` authenticates
# through AWS credentials, so `getApiKeyEnvVars` has no entry for it and this table must not refuse it — but it IS a
# built-in, which matters for the composer (a model definition with no `api` is composed from the vendor model rather
# than deleting the provider). Printed as its own kind so the caller can tell "not a provider pi ships" apart.
# ⛔ THE PROVIDERS THAT SHIP AN OAUTH HANDLER, TRANSCRIBED FROM THE VENDOR TREE (round 32, P2, measured):
# `grep -l "oauth:" node_modules/@earendil-works/pi-ai/dist/providers/*.js` ->
#   anthropic github-copilot kimi-coding meta openai-codex openai openrouter radius xai
# It is a static list, so a store entry of type `oauth` for any OTHER provider is one pi cannot use at all — and
# because a stored entry shadows the environment, that box dies even with the provider key exported (measured).
OAUTH_PROVIDERS = ("anthropic", "github-copilot", "kimi-coding", "meta", "openai-codex", "openai", "openrouter",
                   "radius", "xai")
BUILTIN_NOENV = {
    # ⛔ MEASURED (round 29, P3): with nothing set, `pi -p --provider amazon-bedrock` answers `No API key found for
    # amazon-bedrock.`, and with `AWS_ACCESS_KEY_ID`+`AWS_SECRET_ACCESS_KEY`+`AWS_REGION` it SIGNS the request and
    # AWS answers `UnrecognizedClientException` — i.e. the credential comes from the AWS SDK chain, which is wider
    # than any one variable (a role, an SSO profile, `~/.aws`). Naming a single variable in a REFUSAL would be a
    # false block on every box that authenticates that way, so this is cannot-say, with the chain named.
    "amazon-bedrock": ("AWS_ACCESS_KEY_ID",
                       "measured, pi signs via the AWS SDK chain and reaches it with AWS_ACCESS_KEY_ID + "
                       "AWS_SECRET_ACCESS_KEY + AWS_REGION, so a role/SSO/~/.aws profile provisions it too and no "
                       "single variable is the whole credential"),
}
# ⛔ A BUILT-IN CAN BE PROVISIONED BY A PATH THAT IS NOT ONE OF ITS ENV VARIABLES, AND THEN A REFUSAL IS A FALSE BLOCK
# (round 30, P1, measured). The vendor code beside its own env table has TWO such paths, and this gate read the table
# only: `getEnvApiKey`\x27s `if (provider === "google-vertex")` branch accepts Application Default Credentials plus a
# project and a location (`dist/env-api-keys.js:136-142`, `hasVertexAdcCredentials` at `:39-64`), and anthropic\x27s
# provider `resolve` ends with a workload-identity-federation path that needs no api key at all
# (`dist/providers/anthropic.js:40-57`). Measured on a box with NO credential variable set: `pi -p --provider
# google-vertex` answered `invalid_client` (the ADC exchange ran) and `--provider anthropic` answered a federation
# token-exchange error - while this gate printed `result=REFUSED`. Each entry below is an ALTERNATIVE provisioning path,
# as a list of predicates that must ALL hold; `adc` is the vendor\x27s own two-step file test.
BUILTIN_PATHS = {
    "google-vertex": [
        ("vertex-adc",
         "a service-account/ADC json (GOOGLE_APPLICATION_CREDENTIALS, else "
         "~/.config/gcloud/application_default_credentials.json) + GOOGLE_CLOUD_PROJECT (or GCLOUD_PROJECT) + "
         "GOOGLE_CLOUD_LOCATION",
         [("envany", ["GOOGLE_CLOUD_PROJECT", "GCLOUD_PROJECT"]), ("env", ["GOOGLE_CLOUD_LOCATION"]), ("adc", [])]),
    ],
    "anthropic": [
        ("anthropic-federation",
         "workload-identity federation: ANTHROPIC_FEDERATION_RULE_ID + ANTHROPIC_ORGANIZATION_ID + an "
         "ANTHROPIC_IDENTITY_TOKEN_FILE that pi can actually OPEN",
         [("env", ["ANTHROPIC_FEDERATION_RULE_ID"]), ("env", ["ANTHROPIC_ORGANIZATION_ID"]),
          ("file", ["ANTHROPIC_IDENTITY_TOKEN_FILE"])]),
    ],
}


def _env_set(name):
    # ⛔ TRIMMED, BECAUSE THE REQUEST PATH TRIMS — PINNING WHICH VENDOR HELPER IS THE AUTHORITY TOOK TWO ROUNDS
    # (round 32, P1, measured). There are two, and they disagree:
    #   `getApiKeyEnvVars`/`getProviderEnvValue` (env-api-keys.js, utils/provider-env.js) tests with JS truthiness, so
    #   `" "` is a value — but it is reached only from `dist/compat.js` (the listing/compat surface);
    #   `auth/context.js:21-26` — the context every provider\x27s `resolve` receives on a REQUEST — returns
    #   `typeof value === "string" && value.trim().length > 0 ? value : undefined`, so `" "` is ABSENT.
    # Round 31 followed the wrong one and shipped a FALSE PASS: measured, with an ADC file present and
    # `GOOGLE_CLOUD_PROJECT=" "`, `pi -p --provider google-vertex` prints `No API key found for google-vertex.` while this
    # gate printed `check=ok … path=vertex-adc`; the same holds for a federation variable at `anthropic`. A lane runs
    # `pi -p`, so the REQUEST path decides — and this now agrees with `key_gate_value_present` on every other variable.
    return bool((os.environ.get(name) or "").strip())


def _adc_file_present():
    # The vendor tests a `~` value TWICE AND DIFFERENTLY (round 33, P1, measured), which is why one test is not enough:
    #   `ctx.fileExists` (`auth/context.js:25-31`) EXPANDS a leading `~` to the home directory;
    #   the ADC loader then opens the value from the ENVIRONMENT, RAW (measured: `ENOENT ... open \x27<cwd>/~/config.json\x27`).
    # So `GOOGLE_APPLICATION_CREDENTIALS="~/config.json"` runs only where BOTH paths exist, and the previous cut — a raw
    # `os.path.exists` only — printed `check=ok path=vertex-adc` on a box where `pi -p` answers `Use /login to log into a
    # provider via OAuth or API key.` because `$HOME/config.json` was absent while `./~/config.json` happened to exist.
    # Absolute and relative values are unaffected: there the two tests are the same test.
    explicit = os.environ.get("GOOGLE_APPLICATION_CREDENTIALS") or ""
    if explicit:
        if not os.path.exists(explicit):
            return False
        if explicit.startswith("~"):
            # Node\x27s rule is `homedir() + path.slice(1)` — it does NOT resolve `~user`, so this must not either.
            expanded = os.path.join(os.path.expanduser("~"), explicit[1:].lstrip(os.sep))
            return os.path.exists(expanded)
        return True
    return os.path.exists(os.path.join(os.path.expanduser("~"), ".config", "gcloud",
                                       "application_default_credentials.json"))


def _path_holds(preds):
    for kind, names in preds:
        if kind == "env" and not _env_set(names[0]):
            return False
        if kind == "envany" and not any(_env_set(n) for n in names):
            return False
        if kind == "adc" and not _adc_file_present():
            return False
        # ⛔ A PATH MEMBER THAT NAMES A FILE MUST BE TESTED AS A FILE (round 34, P2, measured). `anthropic`\x27s
        # workload-identity triple ends in ANTHROPIC_IDENTITY_TOKEN_FILE, and the vendor OPENS it (`Failed to read
        # identity token file at <p>: ENOENT`); testing only that the VARIABLE is non-empty printed
        # `check=ok path=anthropic-federation` on a box `pi -p` dies on. The path is used RAW \u2014 the SDK opens it as given.
        if kind == "file" and not os.path.exists(os.environ.get(names[0]) or ""):
            return False
    return True


if sys.argv[2] == "builtin":
    _p = sys.argv[3] if len(sys.argv) > 3 else ""
    # ⛔ THE KIND LINE COMES FIRST, THE PATH LINES AFTER IT, FOR EVERY KIND (round 31, P2, measured): the caller
    # dispatches on the FIRST line (`case "$blt" in certain:*|uncertain:*|noenv:*`), and `google-vertex` is
    # `uncertain` while ALSO having an ADC path — the early `raise` for the uncertain kind meant its paths were never
    # emitted, so an ADC-provisioned vertex box answered `provider-credential-unverifiable` instead of `check=ok
    # path=vertex-adc`. Emitting the paths from one place keeps every kind able to use them.
    if _p in BUILTIN_NOENV:
        print("noenv:" + BUILTIN_NOENV[_p][0])
        print("why:" + BUILTIN_NOENV[_p][1])
    elif _p in BUILTIN_UNCERTAIN:
        print("uncertain:" + BUILTIN_UNCERTAIN[_p].split(":", 1)[0])
        print("why:" + BUILTIN_UNCERTAIN[_p].split(":", 1)[1].lstrip(":"))
    else:
        _v = BUILTIN_ENV.get(_p)
        if _v:
            print("certain:" + ",".join(_v))
        elif _p in OAUTH_PROVIDERS:
            # ⛔ "IN NO ENV TABLE" IS NOT "pi DOES NOT SHIP IT" (round 36 review, P1, measured). An OAUTH-ONLY
            # provider (`openai-codex`) has no `envApiKeys` entry at all, so every table above answers NOTHING for
            # it — the SAME empty stdout a provider pi does not ship produces. The empty answer was therefore
            # overloading two facts, and `key_gate_builtin_unshipped` (which refuses 82) read this one as "not a
            # provider pi ships": measured on a `{"providers":{"openai-codex":{...,"models":[{"id":"gpt-5-codex"}]}}}`
            # fixture, `origin/main` answered `check=warn` + `check=ok var=MYV` while this gate refused 82 with
            # "`openai-codex` is not a provider pi ships" — a NEW false block, in the same PR that fixed one.
            # A token keeps the two distinguishable: no caller\x27s `certain:`/`uncertain:`/`noenv:` arm matches it, so
            # every caller falls to its `*)` cannot-say arm, and `key_gate_builtin_unshipped` (EMPTY stdout) never
            # fires. A provider in NO table AND no oauth handler stays empty, which is the shape it exists for.
            print("known:" + _p)
            print("why:pi ships this provider with an OAuth handler and names no environment variable for it, so no"
                  " variable is the credential and nothing is asserted here")
    # Each alternative path is emitted with its own verdict, so the caller refuses only when EVERY one is closed AND
    # none of the env variables holds a value - and the refusal can name the paths it checked (round 30, P1).
    for _pid, _label, _preds in BUILTIN_PATHS.get(_p, []):
        print(("pathopen:" if _path_holds(_preds) else "pathclosed:") + _pid)
        print("pathwhy:%s:%s" % (_pid, _label))
    raise SystemExit(0)

try:
    doc = read_json(sys.argv[1], jsonc=(sys.argv[2] in ("var", "compose")))
except FileNotFoundError:
    # `var` and `default` are the two "print nothing = cannot say" modes, and for them an ABSENT file is a real
    # answer: no template to resolve, no pin to assert. Only `store` distinguishes absence (rc 1) from
    # unreadability, because only it asserts a positive "no credential".
    # ⛔ `var` DOES SAY WHICH (round 28): "no models.json" is the shape where pi falls back to the provider\x27s own
    # built-in variable, and "present but unparseable" is a datum this gate did not read — folding them into one
    # silent cannot-say is what left #3443\x27s scenario unanswerable.
    if sys.argv[2] == "var":
        print("__KG_ATTR__absent")
    raise SystemExit(0 if sys.argv[2] in ("var", "default") else 1)
except Exception:
    # ⛔ A PRESENT-BUT-UNPARSEABLE `default` FILE IS NOT AN ABSENT PIN (fresh-context review round 4, P3,
    # measured): `default` mode reports an absence POSITIVELY (`no-default-model` = "this box pins nothing"), so
    # a corrupt settings.json must not be folded into it — rc 4 makes it `settings-unreadable`, which refuses
    # nothing and names the real remedy. `var` keeps the cannot-say answer (it prints nothing either way).
    # ⛔ rc 4 = CANNOT SAY, FOR `store` TOO (round 14, P1, measured): rc 1 is the POSITIVE "no credential", and a
    # store that failed to PARSE is not that — with a BOM the gate refused 82 a box pi runs, on a file pi read fine.
    # `var` stays 0 (it prints nothing either way); `default` and `store` say "cannot say".
    if sys.argv[2] == "var":
        print("__KG_ATTR__unreadable")
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
        # The file parsed and names nothing for this provider, so pi falls back to the provider\x27s own variable
        # (`findEnvKeys`) exactly as if the file were absent — that is a `none`, not an unreadable datum.
        print("__KG_ATTR__none")
        raise SystemExit(0)
    kind, names = template_parts(key)
    # ⛔ THE KIND IS PART OF THE ANSWER (round 28, P2, measured): without it, "no variable names" was one undifferentiated
    # cannot-say, and three DIFFERENT facts about the box collapsed into it — pi provisions this provider from a LITERAL
    # in models.json (no variable applies at all), pi runs a `!command` (only pi can evaluate it), or the file names no
    # apiKey and pi falls back to the provider\x27s OWN built-in variable. Only the third one is a question this gate can
    # answer, and it is the NORMAL cell shape (no models.json), so folding them together left #3443\x27s own scenario
    # silent. Printed as a sentinel line so `key_gate_var`\x27s name output is unchanged.
    if kind == "cmd":
        print("__KG_ATTR__cmd")
        raise SystemExit(0)
    if not names:
        print("__KG_ATTR__literal" if key.strip() else "__KG_ATTR__none")
        raise SystemExit(0)
    print("__KG_ATTR__template")
    for nm in names:
        print(nm)
    raise SystemExit(0)

if sys.argv[2] == "compose":
    # ⛔ pi COMPOSES models.json a SECOND time, and that pass can DISCARD what this gate just read (round 28, P2,
    # measured on the installed pi). `applyModelsJson` throws, `composeProvider` catches and returns `base`, and
    # `recomposeProvider` then DELETES the provider when it is not built in — so the apiKey this gate read is gone.
    # Two shapes are decidable from the document and BOTH were measured:
    #   oauth without baseUrl -> throws for built-ins too, and the provider\x27s apiKey override is LOST with it:
    #     `{"deepseek":{"apiKey":"$MYK","oauth":"radius"}}` with MYK unset and DEEPSEEK_API_KEY exported -> pi RAN on
    #     its built-in key, so this gate\x27s `check=fail result=REFUSED var=MYK` was a FALSE 82 on a box pi runs.
    #   a model definition with no `api`/`baseUrl` -> throws only when the provider is NOT built in (pi resolves both
    #     from the built-in model it composes from: `findModelDefaults`, provider-composer.js:117-123), and a custom
    #     provider is then DELETED — measured: `pi -p --provider myprov --model m1` -> `Unknown provider "myprov"`.
    try:
        _d = read_json(sys.argv[1], jsonc=True)
    except Exception:
        raise SystemExit(0)
    if not isinstance(_d, dict):
        raise SystemExit(0)
    _provs = _d.get("providers")
    if not isinstance(_provs, dict):
        raise SystemExit(0)
    _body = _provs.get(sys.argv[3])
    if not isinstance(_body, dict):
        raise SystemExit(0)
    if _body.get("oauth") and not _body.get("baseUrl"):
        print("oauth-no-baseurl")
        raise SystemExit(0)
    # ⛔ AN `oauth` PROVIDER\x27S CATALOG IS REPLACED, SO "A BUILT-IN IS UNAFFECTED" DOES NOT HOLD FOR IT (round 29, P2,
    # measured): `configureRadiusProviders` swaps the built-in base for a gateway provider whose model list is EMPTY
    # until a network refresh, so `findModelDefaults` has nothing to compose from and the throw DELETES the config —
    # for a provider that IS built in. The `-oauth` marker says "the base this would have composed from is gone", which
    # is what lets the caller warn instead of assuming the vendor model is there.
    # ⛔ THE GRANT IS ANSWERED **BEFORE** THE MODEL-DEFINITION DIAGNOSIS, BUT STILL ON ITS OWN LINE (round 34, P1,
    # measured). `findModelDefaults` (`dist/core/provider-composer.js:117-123`) composes an `api`-less model definition from
    # the provider\x27s baseline catalog, and `radiusProvider` HAS one (`radius.js:21-24`, `RADIUS_MODELS` whenever the gateway
    # normalizes to the default). So `{"deepseek":{"oauth":"radius","baseUrl":"…","models":[{"id":"deepseek-flash"}]}}` does
    # NOT throw: measured, `pi -p` reaches the gateway on `RADIUS_API_KEY` (404) and answers `No API key found for
    # deepseek.` without it. The old order printed `no-api:<id>:oauth` first, which the caller read as a DISCARDED
    # provider, so `grant` stayed empty and the gate refused 82 telling the operator to export the provider\x27s own variable
    # — a false block on a box pi runs. The model-definition token is still emitted (second line) for the dropped-provider
    # warning a non-default gateway genuinely earns.
    _grant = _body.get("oauth") == "radius" and _body.get("baseUrl")
    if _grant:
        print("radius-grant")
    # `baselineModels` is `RADIUS_MODELS` only when the gateway normalizes to the default one (`radius.js:21-24`,
    # `normalizeRadiusGatewayUrl` = add a scheme, strip trailing slashes), and `findModelDefaults` composes an `api`-less
    # model definition from that baseline (`provider-composer.js:117-123`). So on the DEFAULT gateway such a definition is
    # NOT a dropped catalog — measured, `pi -p` reached the gateway (404) — while a custom gateway\x27s empty catalog makes
    # the throw real (`Unknown provider`). The warning must not fire on the first shape: it says "dropped".
    # \u26d4 THE VENDOR STRIPS A TRAILING `/v1` BEFORE IT NORMALIZES (round 35, P1, measured): `configureRadiusProviders`
    # passes `config.baseUrl.replace(/\/v1\/?$/u, "")` (`model-runtime.js:130`) and only then does `radiusProvider` decide
    # whether the baseline catalog applies. A gateway written `https://radius.pi.dev/v1` \u2014 the spelling every
    # OpenAI-compatible baseUrl uses \u2014 is therefore the DEFAULT one, and the earlier test called it custom: measured,
    # `pi -p` reached the gateway (401) while this gate refused 82 saying the provider was deleted.
    _gw = re.sub(r"/v1/?$", "", _body.get("baseUrl") or "")
    _suffix = ":oauth" if _body.get("oauth") else ""
    # \u26d4 THE TEST IS "WOULD `new URL()` THROW", NOT "DOES IT LOOK LIKE A URL" (round 39, P1, measured). The hand-rolled
    # `^https?://` test refused boxes pi RUNS: WHATWG `new URL` accepts `https:/host` (one slash), `https:host`, and
    # surrounding whitespace \u2014 `new URL("https:/gw.example/v1/messages")` and `new URL(" https://gw.example/v1/messages")`
    # both yield `https://gw.example/v1/messages` (node, measured), and `pi -p` on each REACHED the network (`fetch failed`)
    # while this gate refused 82 quoting a failure that box never printed. `new URL` throws for exactly one thing here:
    # no parseable scheme (or an empty host on a special scheme). So the discriminator is scheme PRESENCE plus a host for
    # http(s) \u2014 never a spelling.
    # \u26d4 THE AUTHORITY IS PART OF "WOULD `new URL()` THROW" (round 40, P1, measured): a scheme-presence test passed
    # two boxes pi REFUSES \u2014 `new URL("https://:8080/v1/messages")` and `new URL("https:// gw.example/v1/messages")` both
    # throw `ERR_INVALID_URL` (node, measured), and `pi -p` on each answers `Invalid URL`. So for http(s) the authority
    # must exist, must not carry whitespace, and must not be a bare port. \u26d4 IT IS READ AFTER THE SCHEME\x27S SLASHES,
    # NOT AS "THE TEXT UP TO THE FIRST `/`": `new URL("https:///gw.example/v1/messages")` PARSES (three slashes are
    # normalised, measured) and `pi -p` REACHED the network (`fetch failed`) \u2014 a text-up-to-the-first-slash rule
    # refuses that box, re-creating the false block the last round removed, and so does `urllib.parse.urlsplit`, which
    # reads `https:/gw.example/...` as having no host at all.
    # \u26d4 AND A VALUE THAT IS ONLY A SCHEME PLUS SLASHES IS **NOT** REFUSED (round 40, P1, measured): pi builds
    # `new URL(`${baseUrl.replace(/\/+$/u, "")}/messages`)` (`api/pi-messages.js:251`), so `https://` becomes
    # `https:/messages`, which PARSES against the literal host `messages` \u2014 `pi -p` answered `fetch failed`, i.e. it
    # SENT a request. That is a network failure, not the `Invalid URL` this refusal quotes, and a gate that claimed it
    # would be quoting a failure the box never printed. The check below therefore runs on the vendor\x27s own
    # strip-then-append, so every arm\x27s verdict agrees with what `pi -p` actually printed.
    def _port_ok(port):
        # \u26d4 THE PORT IS PART OF "WOULD `new URL()` THROW" (round 41, P1, measured). node THROWS `ERR_INVALID_URL`
        # for a port that is not all-decimal or is out of range \u2014 measured: `host:abc`, `host:+80`, `host:-1`,
        # `host:1e3`, `host:65536` and `host:80:90` all throw, while `host:`, `host:0`, `host:080` and `host:65535`
        # all parse. `pi-messages.js:251` builds `new URL(`${model.baseUrl.replace(/\/+$/u, "")}/messages`)`, so each
        # of those is `Invalid URL` before a request is sent \u2014 the failure `reason=models-json-bad-gateway` exists to
        # quote \u2014 and the earlier test (a BARE `:port` authority, and nothing else) passed them as usable.
        # `[0-9]` and not `\d`: python\x27s `\d` matches non-ASCII decimal digits, which `int()` would then accept while
        # the vendor\x27s parser refuses them.
        # \u26d4 AND THE CONVERSION IS BOUNDED, BECAUSE AN UNBOUNDED ONE IS A FALSE PASS (round 42, P2, measured):
        # `int()` raises `ValueError` above `sys.get_int_max_str_digits()` (4300 here), the exception kills this whole
        # compose payload, and `key_gate_compose` runs the interpreter with `2>/dev/null` \u2014 so the gate lost EVERY
        # compose-level refusal and printed `check=ok` on a box whose `new URL()` throws. \u26d4 LEADING ZEROS ARE STRIPPED
        # RATHER THAN THE STRING LENGTH BOUNDED DIRECTLY, because node PARSES the value: measured,
        # `host:` + 5000 zeros and `host:0000080` are both VALID (ports 0 and 80), while any value above 65535 throws.
        # A plain `len(port) <= 5` guard (the obvious fix) would refuse those two boxes `pi -p` runs \u2014 trading a false
        # PASS for a false BLOCK. After `lstrip`, at most 5 digits can reach `int()`, so the conversion cannot raise.
        if port == "":
            return True
        if re.fullmatch(r"[0-9]+", port) is None:
            return False
        digits = port.lstrip("0") or "0"
        return len(digits) <= 5 and int(digits) <= 65535
    def _authority_ok(auth):
        # \u26d4 THE AUTHORITY IS READ THE WAY THE PARSER READS IT, ON THE RULES THAT WERE MEASURED \u2014 AND THE SCOPE OF
        # THAT CLAIM IS NAMED HERE SO NOBODY READS IT AS A URL-PARSER EMULATION (round 43, P2, measured). What IS
        # mirrored, each against node on the installed vendor:
        #   * USERINFO IS SPLIT OFF FIRST: `https://user:pass@host/v1` PARSES, and a port test applied to the whole
        #     authority would read `pass@host` as the port and refuse a box `pi -p` runs (the false-block direction).
        #   * AN EMPTY HOST AFTER THE SPLIT THROWS: `user@`, `user@:8080`, `user@/`, `@/` are all `ERR_INVALID_URL`
        #     (measured) and were accepted here, which is the same false-PASS class as the port itself.
        #   * AN EMPTY OR UNCLOSED IPV6 LITERAL THROWS: `[]`, `[]:80`, `[::1` (measured).
        #   * THE HOST MUST NOT CARRY A CODE POINT OR A BAD `%` ESCAPE THE HOST PARSER REJECTS: measured, `ho st`,
        #     `ho\xa0st`, `ho\u2003st`, `ho<st`, `ho>st`, `ho^st`, `ho|st`, `h%zz` and `h%2` all throw, while `h%41`
        #     PARSES (as host `ha`).
        # \u26d4 WHAT IS DELIBERATELY **NOT** EMULATED, and why the refusal\x27s own comment and the README row are worded
        # to match: the IPV6 INTERIOR is not validated (`[zzz]`/`[:::]` throw in node and pass here), the WHATWG
        # host parser\x27s full code-point and punycode pipeline is not reproduced, the IPv4-NUMBER RULE is not
        # reproduced (`0000080` throws in node), and a NON-http(s) scheme is not inspected at all \u2014 `_buildable`
        # returns True for it before this function is reached (`ftp://[zzz]/v1` throws in node and passes here).
        # This is a refusal that must never
        # fire on a box `pi -p` runs, so an unemulated shape stays ACCEPTED rather than guessed at \u2014 the direction that
        # leaves a residual false PASS (pre-existing: no URL test at all existed before this PR) instead of inventing a
        # false BLOCK. Both halves are declared, and the arms pin the ones that are emulated.
        hostport = auth.rsplit("@", 1)[-1]
        if hostport.startswith("["):
            close = hostport.find("]")
            if close <= 1:
                return False  # `[]`, `[::1` \u2014 an EMPTY or unclosed literal throws (close==1 is `[]`)
            tail = hostport[close + 1:]
            if not tail:
                return True
            if not tail.startswith(":"):
                return False  # `[::1]x:80` \u2014 text after the literal throws
            return _port_ok(tail[1:])
        if ":" in hostport:
            host, port = hostport.rsplit(":", 1)
            if ":" in host:
                return False  # `host:80:90` \u2014 a second colon is not a port, and node throws it
        else:
            host, port = hostport, ""
        if not host:
            return False
        # \u26d4 THE HOST IS CHECKED ON ITS **DECODED** FORM, AND THAT ONE CLASS IS THE WHOLE TEST (round 43, P2,
        # measured). The `%` check above tests escape SYNTAX only, so `h%2Fost`, `h%00st`, `h%20st`, `h%25st`,
        # `h%3Aost`, `h%5Bost` and `h%40ost` were accepted while node throws `ERR_INVALID_URL` on every one \u2014 the
        # escape decodes to a code point the DOMAIN pipeline then rejects. Measured over all 256 `%XX` escapes: node
        # PARSES 81 (`! " $ & \x27 ( ) * + , - .` digits, `; =` A-Z `_` a-z `{ } ~`) and THROWS the other 175, whose
        # decoded forms are exactly the C0 range, space, `# % / : < > ? @ [ \\ ] ^ |` and DEL \u2014 so this class is the
        # measured THROW set, not a guess, and it cannot refuse a host the parser accepts.
        # \u26d4 IT IS APPLIED TO `decoded`, WHICH IS WHY THERE IS **ONE** CHECK HERE AND NO SEPARATE RAW CLASS OR
        # ESCAPE-SYNTAX TEST (measured by mutation, and both were deleted for it): when the host carries no VALID
        # escape, `decoded` IS the host, so a raw `\x00`/`\x7f`/`<`/`[` is caught here anyway \u2014 and a MALFORMED escape
        # (`%zz`, `%2`) is left UNREPLACED by the substitution, so the `%` it still carries is itself in this class. Two
        # overlapping checks meant a mutant removing one stayed GREEN, i.e. half the guard was unfalsifiable. One check,
        # one mutant, one red arm \u2014 and the `%` in the class is what makes the syntax test unnecessary.
        # \u26d4 NON-ASCII DECODED BYTES ARE DELIBERATELY LEFT ACCEPTED: `%C3%BC` decodes to a non-ASCII letter that the
        # punycode stage may well accept, and refusing non-ASCII would false-block a valid IDN host \u2014 the residual
        # stays a false PASS, which is the direction this gate may err in.
        # \u26d4 THE ESCAPES DECODE TO **BYTES**, THEN UTF-8 \u2014 NOT ONE CHARACTER PER BYTE (round 45, P1, measured):
        # `chr(int(g,16))` emits a LATIN-1 character per byte, so a multi-byte UTF-8 sequence is split and `\s` then
        # matched a CONTINUATION byte (0xA0, or 0x85 for NEL) out of a perfectly valid letter: measured,
        # `https://caf%C3%A0.example/v1` (\u00e0 = C3 A0) was REFUSED 82 while node PARSES it to `xn--caf-cla.example`, and
        # the SAME host written raw was accepted \u2014 one host, two verdicts, 599 of 692 percent-encoded IDN hosts the
        # parser accepts were refused. That is the false-BLOCK direction this file\x27s header forbids, introduced by
        # this very fix, so the decoding is the parser\x27s: collect BYTES (an escape is one byte, a literal character is
        # its UTF-8 encoding), then decode the buffer strictly. INVALID UTF-8 IS A THROW, not a pass \u2014 node refuses
        # `%80`, `%A0`, `%C2%41` and `%C0%AF` too (measured) \u2014 and so is a malformed escape, which the `int()` below
        # turns into `return False`. \u26d4 THE TWO MALFORMED SPELLINGS FAIL BY DIFFERENT MECHANISMS, AND SAYING BOTH "raise"
        # WAS WRONG (round 46, P3, measured): a MID-host `%zz`/`%4s` makes `int()` raise `ValueError` directly, while a
        # `%4` at the END of the host does NOT \u2014 `int("4", 16)` is `4`, so it appends byte `0x04` and it is the DECODED
        # class below that refuses it (measured: removing that class makes `https://h%4` ACCEPT). Same verdict, two paths.
        buf = bytearray()
        _i = 0
        while _i < len(host):
            _c = host[_i]
            if _c == "%":
                try:
                    buf.append(int(host[_i + 1:_i + 3], 16))
                except ValueError:
                    return False
                _i += 3
            else:
                # \u26d4 AN UNENCODABLE CODE POINT IS A THROW, NOT A CRASH (round 46, P1, measured): a LONE SURROGATE
                # (`\ud800`, which python\x27s `json` ACCEPTS inside a string) is not UTF-8-encodable, and this call used
                # to sit OUTSIDE any handler \u2014 the interpreter DIED, `key_gate_compose` runs it with `2>/dev/null`, and
                # the gate printed `check=ok var=DEEPSEEK_API_KEY` over a box node refuses (`ERR_INVALID_URL`) while the
                # PREVIOUS gate refused it 82. That is the same class the `int()` above is guarded for, and an
                # exception escaping this payload loses EVERY compose-level refusal, not just this one.
                try:
                    buf.extend(_c.encode("utf-8"))
                except UnicodeEncodeError:
                    return False
                _i += 1
        try:
            decoded = bytes(buf).decode("utf-8")
        except UnicodeDecodeError:
            return False
        if re.search(r"[\s\x00-\x1f\x7f#%/ :<>?@\[\]\\^|]", decoded):
            return False
        return _port_ok(port)
    def _buildable(v):
        # \u26d4 THE PARSER REMOVES ASCII TAB/NEWLINE AND TRIMS ONLY C0-CONTROL-OR-SPACE (round 43, P2, measured):
        # `new URL("https://ho\\tst/v1/messages")`, the same with `\n` or `\r`, all PARSE (host `host`), so refusing them
        # \u2014 which `re.search(r"\\s", auth)` did \u2014 quoted `Invalid URL` over a box `pi -p` SENDS a request from: a
        # false BLOCK this diff introduced, since no URL test existed before it. The trim is `[\x00-\x20]`, NOT
        # python\x27s `.strip()`, which also eats `\xa0`/`\u2003` \u2014 code points the vendor does NOT trim, so stripping
        # them turned `"\xa0https://host/v1"` into a buildable URL while node throws (a false PASS in the other
        # direction). `\\` is a PATH SEPARATOR for the special schemes (`https://ho\\st/v1` PARSES with host `ho`), so
        # it ends the authority exactly like `/`; leaving it in read `pass@host`-style text as a port.
        s = re.sub(r"[\t\n\r]", "", str(v))
        s = re.sub(r"^[\x00-\x20]+", "", s)
        # \u26d4 THE TRAILING TRIM IS **NOT** MIRRORED, AND MIRRORING IT WAS A FALSE PASS (round 45, P3, measured): the
        # vendor appends `/messages` to the baseUrl FIRST, then parses, and the parser trims only the ends of THAT
        # whole string \u2014 so a trailing space lands INSIDE THE HOST when the baseUrl has no path. Measured:
        # `https://gw.example ` and `https://gw.example:8080 ` both THROW `ERR_INVALID_URL`, while `https://gw.example/v1 `
        # PARSES (the space lands in the path) \u2014 and trimming the baseUrl before appending made the gate accept all
        # three. The LEADING trim stays, because there the parser does see the space at the start of the whole string.
        m = re.match(r"^([A-Za-z][A-Za-z0-9+.\-]*):(.*)$", s, re.S)
        if not m:
            return False
        if m.group(1).lower() in ("http", "https"):
            rest = (m.group(2).rstrip("/") + "/messages").lstrip("/\\")
            auth = re.split(r"[/?#\\]", rest, 1)[0]
            if not auth or re.fullmatch(r":[0-9]*", auth):
                return False
            return _authority_ok(auth)
        return True
    # \u26d4 THE NORMALISATION IS THE VENDOR\x27S, AND REWRITING A SCHEME IS A FALSE PASS (round 40, P2, measured).
    # `normalizeRadiusGatewayUrl` (`pi-ai/dist/providers/radius-config.js`) is: prefix `https://` ONLY when
    # `/^https?:\/\//iu` does NOT match, then strip trailing slashes \u2014 it NEVER rewrites a scheme it was given. So
    # `http://radius.pi.dev` stays http, `https:/radius.pi.dev` (one slash) does not match and becomes
    # `https://https:/radius.pi.dev`, and neither equals the default \u2014 `radiusProvider` then takes the EMPTY baseline
    # (`radius.js:21-24`), `findModelDefaults` finds nothing and `modelFromJson` throws, so `recomposeProvider` DELETES
    # the provider: measured, `pi -p` on `http://radius.pi.dev` + an api-less definition answers
    # `Error: Unknown provider "deepseek"` while the old normaliser collapsed the scheme and printed `check=ok` \u2014 a
    # false PASS on a box pi cannot resolve at all. The last round\x27s spelling tolerance is preserved where the vendor has
    # it (an added scheme for a scheme-LESS value, and any number of slashes) and dropped where it does not.
    # \u26d4 AND IT DOES **NOT** TRIM WHITESPACE, BECAUSE THE VENDOR DOES NOT (round 41, P1, measured).
    # `normalizeRadiusGatewayUrl` is `/^https?:\/\//iu.test(value) ? value : `https://${value}`` then
    # `.replace(/\/+$/u, "")` \u2014 there is no `.trim()` anywhere on that path, and `model-runtime.js:130` hands it
    # `config.baseUrl.replace(/\/v1\/?$/u, "")` with no trim either. So `" https://radius.pi.dev"` does NOT match the
    # scheme test, becomes `https:// https://radius.pi.dev`, and is NOT the default gateway: its baseline catalog is
    # empty, `modelFromJson` throws and `recomposeProvider` DELETES the provider \u2014 measured, `pi -p` on that shape
    # answers `Error: Unknown provider "deepseek"`. A `.strip()` here (which this line carried until round 41) made the
    # padded spelling equal the default, fired the `_grant_default` return, and printed `check=ok var=RADIUS_API_KEY` on
    # exactly that box. \u26d4 NOTE THE ASYMMETRY: `_buildable` above DOES strip, and that is correct \u2014 it answers
    # "would `new URL()` throw", and the WHATWG parser removes leading/trailing spaces itself. This test asks a
    # different question ("does the vendor call this THE DEFAULT gateway"), so the two must not be made to agree.
    _gw_norm = _gw if re.match(r"^https?://", _gw, re.I) else "https://" + _gw
    _gw_norm = re.sub(r"/+$", "", _gw_norm)
    _grant_default = bool(_grant and _gw_norm == "https://radius.pi.dev")
    # \u26d4 NO EARLY RETURN HERE (round 39, P1, measured): `definition.baseUrl` wins at `provider-composer.js:88` on the
    # DEFAULT gateway just as much as on a custom one, so a definition carrying its own scheme-less value is a certain
    # death there too \u2014 measured, `pi -p` \u2192 `Invalid URL` while this gate printed `check=ok`. The default-gateway return
    # now sits AFTER the per-definition own-`baseUrl` check below, and the first cut of this fix returned here, which made
    # that check dead code on exactly the boxes it was added for (caught by `3z15y38`/`39`, which reddened on the first
    # run of the arms rather than on the fix).
    # \u26d4 A SCHEME-LESS `baseUrl` IS A CERTAIN DEATH, AND ONLY AS ONE SPECIFIC SHAPE (round 36, P1 + round 37, P1/P2,
    # measured). The scheme fallback that used to stand above turned a refusal into a false PASS, but the first fix then
    # refused on the provider body alone \u2014 and that was a FALSE BLOCK, because pi only reaches the bad URL through
    # `modelFromJson`: `const baseUrl = definition.baseUrl ?? providerConfig.baseUrl ?? defaults?.baseUrl`
    # (`provider-composer.js:88`), whose consumer does `new URL(\`${model.baseUrl.replace(/\\/+$/u, "")}/messages\`)`
    # (`api/pi-messages.js:250`). Measured on the installed pi, six shapes, so the test is per DEFINITION and provider-
    # agnostic (a non-grant provider dies the same way, and `_grant` made that a false PASS):
    #   grant + scheme-less + NO `models` array ................. RAN (401 from Radius) — the gateway normalizes its own
    #                                                              config URL and no definition inherits the raw one
    #   grant + scheme-less + a definition WITH its own baseUrl .. RAN (404) — `definition.baseUrl` wins
    #   grant + scheme-less + definition WITHOUT one ............. `Invalid URL`
    #   same, definition ALSO without `api`, SHIPPED provider .... `Invalid URL` (composed api, inherited URL)
    #   same, UNSHIPPED provider ................................ `Error: Unknown provider` — the composer throws first
    #   non-grant SHIPPED provider + scheme-less ................ `Invalid URL`
    # Same for a MODEL-LEVEL scheme-less baseUrl (measured `Invalid URL`). So: a definition whose EFFECTIVE baseUrl
    # (its own, else the one on the provider body) has no scheme is a refusal, and the `-no-api` variant is split out because
    # the caller must pick the measured failure by whether pi ships the provider.
    # \u26d4 BUT "PER DEFINITION" WAS STILL TWO FALSE PASSES (round 39, P1, measured BOTH ways): the test sat INSIDE the
    # `models` loop and AFTER the default-gateway return, so two boxes where `pi -p` dies `Invalid URL` printed
    # `check=ok` \u2014 (a) a definition carrying its OWN scheme-less `baseUrl` on the DEFAULT gateway (:88 wins regardless of
    # the gateway, and `_grant_default` returned before the loop), and (b) a NON-radius provider body with a scheme-less
    # `baseUrl` and NO `models` array, where `config.baseUrl` is mapped onto every base model
    # (`config.oauth === "radius" ? model.baseUrl : (config.baseUrl ?? model.baseUrl)`, `provider-composer.js:168`).
    # Both are now tested: (a) before the default-gateway return, per definition, because its own value wins there;
    # (b) after the loop, and only for a non-radius provider \u2014 a GRANT with no `models` array is exempt, because that
    # shape was measured to RUN (401 from Radius).
    _raw_base = _body.get("baseUrl") or ""
    _models = [m for m in (_body.get("models") or []) if isinstance(m, dict)]
    # \u26d4 THE URL IS BUILT PER **REQUEST**, SO ONLY THE PINNED DEFINITION CAN BREAK IT (round 40, P3, measured).
    # pi builds `new URL(`${model.baseUrl...}/messages`)` (`api/pi-messages.js:251`) for the model it is about to use, and
    # `modelFromJson` (`provider-composer.js:83-116`) never parses a URL \u2014 so a SIBLING definition with an unbuildable
    # `baseUrl` composes fine and is never reached. Measured: pinned `deepseek-flash` beside
    # `{id:other, baseUrl:"broken.example/v1"}` \u2014 `pi -p` RAN (`fetch failed`) while this gate refused 82 naming the
    # healthy pin. The loops below therefore test the URL on the pinned definition only (all definitions when no pin
    # matches, which is the pre-existing answer). \u26d4 THE `api`/`baseUrl` STRUCTURAL TESTS STAY PER DOCUMENT, because those
    # are composer-level: `provider-composer.js:173-181` runs `modelFromJson` for EVERY definition and a throw discards
    # the whole models.json, so a sibling really does take the pinned model with it.
    _pin = str(sys.argv[4]) if len(sys.argv) > 4 else ""
    _pinned = [m for m in _models if str(m.get("id")) == _pin] if _pin else []
    _url_models = _pinned or _models
    def _bad_gw(m):
        print("bad-gateway" + ("-no-api" if not (m.get("api") or _body.get("api")) else ""))
        raise SystemExit(0)
    # \u26d4 THIS TEST SITS ABOVE THE DEFAULT-GATEWAY RETURN (round 40, P2, measured): with the VENDOR\x27S normaliser a
    # scheme-less gateway (`radius.pi.dev`) IS `https://radius.pi.dev`, so `_grant_default` now fires on it \u2014 and a
    # return here would skip the effective-`baseUrl` test on exactly the boxes that need it (a definition inheriting the
    # RAW, scheme-less value dies `Invalid URL` whatever the gateway is). Measured: the normaliser half alone reddened
    # `3z15y20/21/22`, `32/33`, `8z47/48`, `8z53/54`; the pair is green.
    for _m in _url_models:
        # \u26d4 A GRANT ON A NON-DEFAULT GATEWAY NEVER REACHES THE URL (round 46, P2, measured):
        # `configureRadiusProviders` (`model-runtime.js:119-132`) is called BEFORE any request, `radiusProvider` takes the
        # EMPTY baseline catalog when the gateway is not the default one (`radius.js:21-24`), `findModelDefaults` finds
        # nothing and `modelFromJson` THROWS on the `api`-less definition \u2014 so `recomposeProvider` DELETES the provider
        # and no URL is ever built. Measured on pi for a trailing-space gateway + an api-less definition
        # (`https://radius.pi.dev `): `Error: Unknown provider "deepseek". Use --list-models ...`, NOT `Invalid URL` \u2014
        # while the URL test says `_buildable` is false and quoted `Invalid URL`, a failure that box never prints. The
        # shape therefore falls THROUGH to the `no-api` branch below, whose caller answers `no-api:<id>:oauth` on a grant
        # as `models-json-provider-dropped` \u2014 the reason pi\x27s own sentence belongs to. The URL test still applies to
        # every definition that HAS an `api` (composed from a baseline that exists, or from the definition itself) and to
        # every non-grant provider.
        if _grant and not _grant_default and not (_m.get("api") or _body.get("api")):
            continue
        _eff = _m.get("baseUrl") or _raw_base
        if _eff and not _buildable(_eff):
            _bad_gw(_m)
    if _grant_default:
        raise SystemExit(0)
    for _m in _models:
        if not (_m.get("api") or _body.get("api")):
            print("no-api:" + str(_m.get("id")) + _suffix)
            raise SystemExit(0)
        if not (_m.get("baseUrl") or _body.get("baseUrl")):
            print("no-baseurl:" + str(_m.get("id")) + _suffix)
            raise SystemExit(0)
    if not _models and not _grant and _raw_base and not _buildable(_raw_base):
        print("bad-gateway")
        raise SystemExit(0)
    # ⛔ A `radius` GRANT REPLACES THE PROVIDER\x27S CATALOG AND ITS CREDENTIAL (round 33, P1, measured). The handler set is
    # NOT static after all: `configureRadiusProviders` (`dist/core/model-runtime.js:119-132`) swaps ANY provider whose
    # models.json sets `oauth: "radius"` AND a `baseUrl` for `builtinProviderCatalog.radiusProvider(...)`
    # (`pi-ai/dist/providers/radius.js:21-24`), which installs BOTH an oauth handler AND `envApiKeyAuth(["RADIUS_API_KEY"])`.
    # Measured on `{"deepseek":{"oauth":"radius","baseUrl":"https://radius.pi.dev"}}`: with `RADIUS_API_KEY` set and
    # `DEEPSEEK_API_KEY` unset, `pi -p` RAN (401 from Radius) while this gate refused 82 naming DEEPSEEK_API_KEY — a false
    # block; with `DEEPSEEK_API_KEY` set and `RADIUS_API_KEY` unset, pi answered `Use /login to log into a provider via
    # OAuth or API key.` while the gate printed `check=ok var=DEEPSEEK_API_KEY` — the false PASS this issue is about, on
    # the same box. So the grant answers both questions: the credential variable is RADIUS_API_KEY, and the provider HAS
    # an oauth handler.
    raise SystemExit(0)

# MODE=store
# ⛔ AN UNEXPECTED EXCEPTION IN A POSITIVE ARM IS CANNOT-SAY, NOT THE POSITIVE ANSWER (round 27, P1, measured): rc 1 is
# the claim "this store holds NO credential for this provider", so a bug in this interpreter must never produce it —
# and a `TypeError` in `resolve()` did exactly that (exit 1 -> rc 1 -> the environment arm decides -> a false 82 on a box
# pi runs). Only the explicit `raise SystemExit(...)` arms may speak. Enforced at the CALLER rather than with a `try:`
# here: python exits 1 on an unhandled exception, and 1 is the code this mode uses for the POSITIVE "no credential", so
# `key_gate_stored_credential` keeps the stderr stream and treats rc 1 WITH output as cannot-say.
# ⛔ `null` IS NOT "NO STORED CREDENTIAL" (round 25, P1, measured): a whole-document `null` parses fine, and pi then
# evaluates `readState.data[provider]` on it - `Credential store read failed for <provider>: Cannot read properties of
# null (reading \x27<provider>\x27)`, exit 1, WITH the provider key exported. The old reader folded every non-dict into the
# POSITIVE "there is no credential here" (rc 1), so the gate fell through to the environment and printed `check=ok`
# - and the false fact "auth.json has NO entry for this provider" - over a lane that dies. The other non-dict shapes
# are genuinely safe and stay rc 1: `[]` reaches the provider (measured 401), because indexing an array yields
# `undefined`, not a throw.
if not isinstance(doc, dict):
    # ⛔ `null` IS NOT "DOES NOT PARSE" (round 29, P3, measured): it parses and pi then throws at READ time
    # (`Credential store read failed for <provider>: Cannot read properties of null`), so the rc-6 message\x27s "does not
    # PARSE ... repair the JSON" described a different failure than the one pi prints. Its own code, so its own reason
    # and its own sentence. `[]`/`"str"` stay rc 1: indexing them yields `undefined`, and pi reaches the provider.
    raise SystemExit(8 if doc is None else 1)
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
    # ⛔ AN OAUTH ENTRY FOR A PROVIDER WITH NO HANDLER IS A CERTAIN DEATH, NOT A CANNOT-SAY (round 32, P2, measured):
    # which providers carry a handler is a STATIC list in the vendor tree (`grep -l "oauth:" pi-ai/dist/providers/*.js`
    # -> the nine ids in OAUTH_PROVIDERS), so "only pi\x27s registry knows" was false. Measured with
    # `auth.json = {"deepseek":{"type":"oauth","access":"tok-aaa","refresh":"r","expires":9999999999999}}` AND
    # `DEEPSEEK_API_KEY` exported: `pi -p` answers `No API key found for deepseek.`, because a stored entry SHADOWS the
    # environment (`auth/resolve.js:31-37` returns `undefined` when the stored type has no matching handler). The old
    # answer here was `check=skipped reason=stored-credential-unresolvable` — a silent end over a lane that provably
    # cannot start, carrying a justification the vendor tree disproves.
    # ⛔ A `radius` GRANT GIVES THE PROVIDER A HANDLER (round 33, P1, measured): `configureRadiusProviders` installs
    # `radiusProvider` for any provider whose models.json sets `oauth: "radius"` with a `baseUrl`, and that provider carries
    # BOTH an oauth handler and `envApiKeyAuth(["RADIUS_API_KEY"])`. Measured: that box with a stored oauth entry RAN (401
    # from Radius) while this gate refused `auth-store-oauth-unusable` and told the operator to delete a credential pi was
    # using. The caller passes the grant as argv[4].
    _granted = len(sys.argv) > 4 and sys.argv[4] == "1"
    if sys.argv[3] not in OAUTH_PROVIDERS and not _granted:
        raise SystemExit(9)
    # For a provider that DOES have a handler the token may or may not be live, so this stays cannot-say.
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
_kind, _names = template_parts(entry["key"])
# ⛔ rc 7 IS NOT rc 4 (round 29, P3, measured): rc 4\x27s sentence says the entry has NO `key` at all, which is true of
# `{"type":"api_key"}` and FALSE of `{"key":"${NOT_IN_ENV}"}` — that entry has a key, and pi resolves it to nothing.
# Both are cannot-say (pi falls back to the provider\x27s own variable: measured, `DEEPSEEK_API_KEY` still runs the box),
# but the operator\x27s remedy differs, so the two causes get two codes and two sentences.
raise SystemExit(3 if cannot else (7 if _names else 4))

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
  # ⛔ THE KIND LINE IS FILTERED HERE (round 28): `var` mode now emits `__KG_ATTR__<kind>` first, so the answer to
  # "which variables does the template name" stays exactly what it was. `key_gate_apikind` below reads that line.
  # `|| return 0`: with only the sentinel line, `grep -v` exits 1 — a caller under `set -e` would abort on the
  # cannot-say answer, which is the one case that must never be fatal.
  key_gate_bounded "${KEY_GATE_BOUND:-15}" python3 -c "$_KEY_GATE_PY" "$mj" var "$prov" 2>/dev/null \
    | grep -v '^__KG_ATTR__' || return 0
}

# key_gate_apikind <home> [<provider>] [<cwd>] -> `template` | `literal` | `cmd` | `none` | (nothing = no file)
# ⛔ WHY THE KIND MATTERS (round 28, P2, measured): three different answers were folded into one cannot-say. pi
# provisions a provider from a LITERAL `apiKey` in models.json, so there is no environment variable to check and no
# refusal is possible; a `!command` is pi's to evaluate; and a file that names NOTHING leaves pi on the provider's
# built-in variable — the ONLY one of the three this gate can answer, and the normal cell shape (#3443).
key_gate_apikind() {
  local home="${1:-}" prov="${2:-}" cwd="${3:-${PWD:-}}" agent_dir mj
  agent_dir="$(key_gate_agent_dir "$home" "$cwd")"
  [ -n "$agent_dir" ] || return 0
  mj="$agent_dir/models.json"
  [ -n "$prov" ] || prov="${PI_LANE_PROVIDER:-deepseek}"
  command -v python3 >/dev/null 2>&1 || return 0
  key_gate_bounded "${KEY_GATE_BOUND:-15}" python3 -c "$_KEY_GATE_PY" "$mj" var "$prov" 2>/dev/null \
    | sed -n 's/^__KG_ATTR__//p' | head -1
}

# key_gate_builtin_probe <provider> -> the table answer, AND the READ STATUS: rc 0 = the read COMPLETED and is
# therefore an ANSWER; rc non-zero = it did not (no python3, a tripped `KEY_GATE_BOUND`, an interpreter error).
# Empty stdout WITH rc 0 is the ONLY shape that means "pi does not ship this provider".
# ⛔ THE READ STATUS IS PART OF THE ANSWER (round 35 review, P1, measured). `key_gate_builtin` prints nothing for
# BOTH "not shipped" and "I could not read the table", and four call sites added in this round read the SAME empty
# answer as a positive claim and refused 82. Measured: with a `python3` that exits 3 only in `builtin` mode, a
# shipped `deepseek` pin carrying an `api`-less model flipped `check=ok` -> `REFUSED … is not a provider pi ships`,
# on BOTH the pin and the lane path — the one polarity this file's header forbids ("a datum we cannot read is not a
# verdict"; "no python3 … refuses NOTHING"). The vendor prints nothing AND exits 0 only for a provider it does not
# ship, so the exit status is the discriminator — and reading it here costs no second bounded read.
key_gate_builtin_probe() {
  local prov="${1:-}" out rc
  [ -n "$prov" ] || return 1
  command -v python3 >/dev/null 2>&1 || return 1
  out="$(key_gate_bounded "${KEY_GATE_BOUND:-15}" python3 -c "$_KEY_GATE_PY" /dev/null builtin "$prov" 2>/dev/null)"; rc=$?
  # stdout is BYTE-IDENTICAL to the pre-diff function (nothing printed when the table said nothing), so every
  # pre-existing caller is untouched by this split.
  [ -n "$out" ] && printf '%s\n' "$out"
  return "$rc"
}

# key_gate_builtin <provider> -> `certain:VAR[,VAR...]` | `uncertain:VAR` + `why:` | `noenv:VAR` + `why:` |
# (nothing = pi does not ship this provider, OR the read failed — ask `key_gate_builtin_unshipped` which)
# pi's OWN table (`dist/env-api-keys.js`), so this is the vendor's answer and not this gate's guess.
# Every pre-existing caller treats an empty answer as CANNOT-SAY, which stays correct for both shapes.
key_gate_builtin() {
  key_gate_builtin_probe "${1:-}"
}

# key_gate_builtin_unshipped <provider> -> rc 0 IFF the read COMPLETED and pi's table has NO entry for it.
# This is the predicate for "the answer is a REFUSAL": a failed read must keep the pre-existing `warn`, never
# refuse. Refusing on an unread datum is the false block this file's header forbids.
# ⛔ AND "NO ENTRY IN THE ENV TABLE" IS NOT "UNSHIPPED" EITHER (round 36 review, P1, measured): an OAUTH-only
# provider (`openai-codex`) legitimately answers nothing from every env table, so the python emits a `known:` token
# for it. Only EMPTY stdout means "pi ships no such provider" — the two facts this predicate needs to separate.
key_gate_builtin_unshipped() {
  local out
  out="$(key_gate_builtin_probe "${1:-}")" || return 1
  [ -z "$out" ]
}

# key_gate_compose <home> <provider> <model> [<cwd>] -> the reason pi's COMPOSER rejects this provider's
# models.json (`oauth-no-baseurl` | `no-api:<id>` | `no-baseurl:<id>`) or its pinned definition's URL
# (`bad-gateway` | `bad-gateway-no-api`), or nothing.
# ⛔ pi COMPOSES models.json A SECOND TIME and can DISCARD what this gate just read (round 28, P2, measured).
key_gate_compose() {
  local home="${1:-}" prov="${2:-}" model="${3:-}" cwd="${4:-${PWD:-}}" agent_dir mj
  agent_dir="$(key_gate_agent_dir "$home" "$cwd")"
  [ -n "$agent_dir" ] || return 0
  mj="$agent_dir/models.json"
  [ -n "$prov" ] || prov="${PI_LANE_PROVIDER:-deepseek}"
  command -v python3 >/dev/null 2>&1 || return 0
  # ⛔ NO `head -1`: the grant and the model-definition diagnosis are TWO facts from ONE bounded read (round 34, P1).
  # `radius-grant` comes first when a grant holds, and a `no-api:`/`no-baseurl:` line can follow it — so a caller that
  # kept only the first line could not see both, and a second read would spend the bound twice (measured: a blocking
  # models.json then answered outside it, arm 5c).
  # \u26d4 THE PIN IS FORWARDED (round 40, P3, measured): the reader used to take `$model` and drop it, so both loops
  # tested EVERY definition and a sibling\x27s unbuildable `baseUrl` refused a lane whose pinned model is fine. `$model` is
  # argv[4]; an EMPTY value keeps the pre-existing "every definition" answer.
  key_gate_bounded "${KEY_GATE_BOUND:-15}" python3 -c "$_KEY_GATE_PY" "$mj" compose "$prov" "$model" 2>/dev/null
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
  local home="${1:-}" prov="${2:-}" cwd="${3:-${PWD:-}}" grant="${4:-}"
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
  # ⛔ A CRASH AND A POSITIVE "NO CREDENTIAL" BOTH EXIT 1 (round 27, P1, measured): python exits 1 on an unhandled
  # exception, and 1 is this mode's POSITIVE "there is no entry for this provider" — so a `TypeError` in `resolve()` (an
  # `env` map holding a NUMBER, `{"A": 5}`) published a bug as that claim, the gate fell through to the environment, and
  # a box pi runs was refused 82. Keep the stderr stream: the explicit arms print nothing, a traceback does.
  local errf rc
  errf="$(mktemp "${TMPDIR:-/tmp}/key-gate-store.XXXXXX" 2>/dev/null)" || errf=""
  key_gate_bounded "${KEY_GATE_BOUND:-15}" python3 -c "$_KEY_GATE_PY" "$aj" store "$prov" "$grant" 2>"${errf:-/dev/null}"
  # rc 0 = a credential that RESOLVES; 3 = cannot say; anything else = no credential. The bound's own
  # kill status (143/124/…) lands in the "cannot say" bucket because it is not a positive "absent".
  rc=$?
  if [ "$rc" = "1" ] && [ -n "$errf" ] && [ -s "$errf" ]; then
    # CANNOT-SAY, NEVER "NO CREDENTIAL": this reader crashed, so it did not read the store.
    rc=3
  fi
  [ -n "$errf" ] && rm -f "$errf" 2>/dev/null
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
    # 4 = the entry is VALID but yields no value (an `api_key` entry with no `key`, or a template this environment
    # cannot resolve). It reached the cannot-say bucket through the wildcard until round 27 (P3, measured: the
    # call site's `= "4"` comparison could never be true); propagating it makes the distinction visible, and the
    # call sites now give it its own line — because the causes differ from a `!command`/`oauth` entry.
    4) return 4 ;;
    # ⛔ 7 AND 8 ARE THE SECOND CAUSE OF TWO CODES THAT USED TO MERGE THEM (round 29, P3, measured):
    #   7 = a key TEMPLATE that resolves to nothing (pi falls back to the provider's own variable, so cannot-say — but
    #       the rc-4 sentence says the entry has NO `key`, which is false for this shape);
    #   8 = a JSON `null` document, which PARSES and then kills pi at read time (the rc-6 sentence says "does not
    #       PARSE", which sends the operator after a syntax error that is not there).
    7) return 7 ;;
    8) return 8 ;;
    # 9 = an `oauth` entry for a provider pi ships NO handler for (round 32, P2, measured): the handler set is a static
    # nine-id list, and a stored entry SHADOWS the environment, so the box dies even with the provider key exported -
    # a certain death, not the cannot-say its rc-3 sibling earns.
    9) return 9 ;;
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
  cell="$CELL_HOME"
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
      if [ "${pmask:0:1}" != "a" ] || [ "${pmask:1:1}" != "a" ] || [ "$pscope" = 1 ] || [ "$prc" = 3 ] || [ -e "$pj" ]; then
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
  # ⛔ THE COMPOSER CAN TAKE THE TEMPLATE AWAY **HERE TOO** (fresh-context review round 29, P2, measured against a
  # rebased head — the divergence survived it): `key_gate_assert_main` has dropped a discarded `apiKey` since round 28,
  # and this arm never got it — so on ONE box, in ONE run, the lane path printed BOTH
  # `check=warn reason=box-default-not-provisioned … var=MYK` (this function) and
  # `check=warn reason=models-json-api-key-discarded why=oauth-no-baseurl … var=MYK` followed by
  # `check=ok var=DEEPSEEK_API_KEY … source=pi-builtin-env`: two lines disagreeing about which variable the pin resolves,
  # and the wrong one printed by the line an operator reads. `--probe --box-default` on that same box REFUSED 82 with the
  # remedy `export MYK` — a variable pi provably never consults (`oauth` with no `baseUrl` makes the composer THROW, the
  # provider apiKey is discarded with it, and with DEEPSEEK_API_KEY exported `pi -p` runs on the built-in key) — i.e. a
  # FALSE BLOCK on the documented verification path, carrying a remedy that cannot work. No arm drove
  # `--probe --box-default` on a discarded-template box, which is why the divergence survived round 28. The PINNED model is
  # what `key_gate_compose` needs, and dropping the names here sends the answer to the store/built-in arms that pi actually
  # resolves — exactly as the lane path does.
  local drop="" discarded=0 pgrant=""
  # ⛔ see the lane site: a Radius-granted provider's credential is RADIUS_API_KEY (round 33, P1, measured), and ONE
  # bounded read answers both questions (two would spend the bound twice). UNCONDITIONAL, because a grant needs no
  # `apiKey` template: when `names` is empty the old guard skipped the read entirely and the built-in arm then asserted the
  # provider's own variable - a false PASS on a granted box.
  pcomp="$(key_gate_compose "$home" "$prov" "$dm" "$cwd")"
  case "$pcomp" in *radius-grant*) pgrant=1 ;; esac
  drop="$(printf '%s\n' "$pcomp" | grep -v '^radius-grant$' | head -1)"
  # ⛔ see the lane site: a granted pin whose model definition cannot compose is a certain death (pi deletes the provider)
  # and NO credential answers it (round 34, P1, measured). Refused here too, because the pin path has its own code.
  # ⛔ AND THE PIN PATH NEEDS THE UNSHIPPED-PROVIDER RULE TOO (round 35, P1, measured): it ignored `no-api`/`no-baseurl`
  # entirely, so `--probe --box-default` printed `check=ok var=MYV` for a `myprov` pin whose bare `pi -p` answers
  # `Error: Unknown provider "myprov".` (a DELETED provider) or `No API key found for the selected model.` A provider pi
  # does not ship has no base to compose from, so the model definition takes it with it.
  # ⛔ A PROVIDER pi DOES NOT SHIP, which is a fact about the FILE — but ONLY when the table read COMPLETED (round 35
  # review, P1, measured): `key_gate_builtin` is empty for an unread table too, and refusing on that turned a healthy
  # box into `REFUSED … is not a provider pi ships` with a remedy that was not the reason it fired.
  # \u26d4 see the lane site: the URL level, and NOT gated on a Radius grant (round 37, P1/P2, measured).
  # ⛔ AND `warn` MODE STAYS SILENT, LIKE EVERY SIBLING ARM BELOW (round 38, P2). `warn` is the LANE path's
  # COMPANION line (`key_gate_assert` runs it before the verdict, so a lane log carries ONE refusal); refusing here
  # would print a second `result=REFUSED` line for the same box, which is the duplicate-noise class #3331 was filed
  # about. The lane's own verdict is unaffected: `key_gate_assert_main` refuses this shape itself, and
  # `--probe --box-default` drives this function in `refused` mode.
  if { [ "$drop" = "bad-gateway" ] || { [ "$drop" = "bad-gateway-no-api" ] && ! key_gate_builtin_unshipped "$prov"; }; } && [ "$quiet" != 1 ]; then
    printf '[key-gate] %s check=fail result=REFUSED reason=models-json-bad-gateway why=%s model=%s box_default=%s provider=%s settings_json=%s - the pinned model definition has no absolute URL in its effective `baseUrl` (its own, else the one on the provider body), and pi builds the request URL from that value. For `%s` the measured outcome is `Invalid URL` before anything is sent; a definition that ALSO declares no `api` may instead lose the provider entirely (`Error: Unknown provider`), because pi cannot compose one without a baseline catalog. Either way no credential answers it: write an absolute `https://` baseUrl (on the model definition, or on the provider body) and give the definition its own `api` if it has none, then re-run (agent-infra#3443)\n' \
      "$label" "$drop" "$dm" "$dm" "$prov" "$sj" "$prov"
    return "$KEY_GATE_REFUSED"
  fi
  # ⛔ AND THE `-no-api` VARIANT DOES NOT QUOTE A SINGLE FAILURE, BECAUSE THE COMPOSER'S IS NOT DECIDABLE HERE (round 39,
  # P2, measured both ways). With a definition that declares no `api` AND an unbuildable effective `baseUrl`, pi's outcome
  # depends on whether a baseline catalog survives, which this gate cannot read: a SHIPPED provider with a baseline
  # composes an api and then fails to build the URL (`Invalid URL`), while a `radius` grant on a CUSTOM gateway has an
  # empty baseline, so `modelFromJson` throws first and `recomposeProvider` DELETES the provider
  # (`Error: Unknown provider`) — measured: `{"oauth":"radius","baseUrl":"gw.example/v1",models:[{id}]}` answers
  # `Unknown provider "deepseek"` while the same shape on `radius.pi.dev` answers `Invalid URL`. So the refusal names BOTH
  # and gives a remedy that unblocks either, instead of quoting one and sending the operator to the wrong file field.
  if [ "$drop" = "bad-gateway-no-api" ] && key_gate_builtin_unshipped "$prov" && [ "$quiet" != 1 ]; then
    printf '[key-gate] %s check=fail result=REFUSED reason=models-json-provider-dropped why=no-api:%s model=%s box_default=%s provider=%s settings_json=%s - this provider is not one pi ships and the pinned model definition declares no `api`, so `recomposeProvider` DELETES the provider - measured, `pi -p --provider %s --model %s` answers `Error: Unknown provider "%s".` Give the definition its own `api` (and `baseUrl`), and re-run (agent-infra#3443)\n' \
      "$label" "$dm" "$dm" "$dm" "$prov" "$sj" "$prov" "$dm" "$prov"
    return "$KEY_GATE_REFUSED"
  fi
  if [ -n "$drop" ] && key_gate_builtin_unshipped "$prov" && [ "$drop" != "oauth-no-baseurl" ] && [ "$quiet" != 1 ]; then
    printf '[key-gate] %s check=fail result=REFUSED reason=models-json-provider-dropped why=%s model=%s box_default=%s provider=%s settings_json=%s - `%s` is not a provider pi ships, so the composer has no base model to fall back on: `modelFromJson` throws and `recomposeProvider` DELETES the provider - measured, `pi -p --provider %s --model %s` answers `Error: Unknown provider "%s"`, and a bare `pi -p` on this pin answers `No API key found for the selected model.` No credential answers that; give the model definition its own `api` (and `baseUrl`), or drop it (agent-infra#3443)\n' \
      "$label" "$drop" "$dm" "$dm" "$prov" "$sj" "$prov" "$prov" "$dm" "$prov"
    return "$KEY_GATE_REFUSED"
  fi
  if [ "$drop" = "oauth-no-baseurl" ] && key_gate_builtin_unshipped "$prov" && [ "$quiet" != 1 ]; then
    printf '[key-gate] %s check=fail result=REFUSED reason=models-json-provider-dropped why=oauth-no-baseurl model=%s box_default=%s provider=%s settings_json=%s - this provider sets `oauth` with no `baseUrl`, which makes the pi composer THROW, and `%s` is not a provider pi ships, so there is no built-in base to fall back on: `recomposeProvider` DELETES the provider (measured: `Error: Unknown provider "%s"`). Add a `baseUrl` to the provider body or drop it (agent-infra#3443)\n' \
      "$label" "$dm" "$dm" "$prov" "$sj" "$prov" "$prov"
    return "$KEY_GATE_REFUSED"
  fi
  if [ -n "$pgrant" ] && [ -n "$drop" ] && [ "$quiet" != 1 ]; then
    printf '[key-gate] %s check=fail result=REFUSED reason=models-json-provider-dropped why=%s model=%s box_default=%s provider=%s settings_json=%s - the pi composer cannot build this provider\x27s model definition (%s) and, because a Radius grant replaces the built-in catalog with a gateway one whose models arrive only after a refresh, `recomposeProvider` DELETES the provider: measured, `pi -p --provider %s --model %s` answers `Error: Unknown provider "%s".` No credential answers that, so the pin is unusable until the definition carries its own `api` (and `baseUrl`) (agent-infra#3443)\n' \
      "$label" "$drop" "$dm" "$dm" "$prov" "$sj" "$drop" "$prov" "$dm" "$prov"
    return "$KEY_GATE_REFUSED"
  fi
  if [ -n "$names" ]; then
    if [ "$drop" = "oauth-no-baseurl" ]; then
      # A warn line only in `refused` mode (the standalone probe): the LANE path prints its own copy of this diagnosis
      # from `key_gate_assert_main`, and a `warn`-mode companion repeating it would grow every lane log by a line nobody
      # asked for — the noise class #3331 was filed about.
      [ "$quiet" = 1 ] || printf '[key-gate] %s check=warn reason=models-json-api-key-discarded why=oauth-no-baseurl model=%s box_default=%s provider=%s var=%s models_json=%s — a models.json for this provider sets `oauth` with no `baseUrl`, and the pi composer THROWS on that (`provider-composer.js:154`), so the provider apiKey override is discarded and $%s is NOT the variable pi resolves for this pin; the answer below comes from the store and the provider built-in variable instead\n' \
        "$label" "$dm" "$dm" "$prov" "${names%%$'\n'*}" "${agent_dir:+$agent_dir/models.json}" "${names%%$'\n'*}"
      names=""; discarded=1
    fi
  fi
  # ⛔ THE STORE IS PROBED BEFORE THE TEMPLATE, AS pi READS IT (round 24, P2, measured) — THE SAME ORDERING THE LANE PATH
  # HAS HAD SINCE ROUND 21, which this arm never got: a `models.json` need not declare a built-in provider at all (the
  # NORMAL cell shape), and the early return below ran first, so on one box `--probe` refused `reason=store-invalid`
  # while `--probe --box-default` answered `reason=cannot-resolve-provider-credential` — the README advertises the
  # latter as refusing an unusable pin, and on the ordinary shape it structurally could not. The early return now sits
  # BELOW the store probe (it still applies when the store has no entry: then nothing names a variable to check).
  local store_rc=1
  key_gate_stored_credential "$home" "$prov" "$cwd" "$pgrant"; store_rc=$?
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
    4)
      # ⛔ see the lane-path arm: a key-less `api_key` entry is VALID, and pi falls back to the provider's own built-in
      # variable rather than to this template (round 27, P3, measured).
      [ "$quiet" = 1 ] && return 0
      printf '[key-gate] %s check=skipped reason=stored-credential-keyless model=%s box_default=%s provider=%s settings_json=%s — %s/auth.json has a VALID `api_key` entry for this provider with NO `key`, so pi falls back to the provider's own built-in variable rather than to the models.json template this gate follows; whether that yields a key is pi's answer alone, so nothing is asserted about this pin\n' \
        "$label" "$dm" "$dm" "$prov" "$sj" "${agent_dir:-<none>}"
      return 0 ;;
    7)
      [ "$quiet" = 1 ] && return 0
      printf '[key-gate] %s check=skipped reason=stored-credential-unresolved model=%s box_default=%s provider=%s settings_json=%s — %s/auth.json holds an `api_key` entry whose `key` is a TEMPLATE that resolves to nothing here, so pi treats the provider as unprovisioned and falls back to its own built-in variable; nothing is asserted about this pin\n' \
        "$label" "$dm" "$dm" "$prov" "$sj" "${agent_dir:-<none>}"
      return 0 ;;
    8)
      [ "$quiet" = 1 ] && return 0
      printf '[key-gate] %s check=fail result=REFUSED reason=auth-store-null model=%s box_default=%s provider=%s settings_json=%s — %s/auth.json is a JSON `null`, which parses and then kills pi at read time (`Credential store read failed for <provider>: Cannot read properties of null`); there is no pin credential to assert. Write `{}` (or delete the file) and re-run (agent-infra#3443)\n' \
        "$label" "$dm" "$dm" "$prov" "$sj" "${agent_dir:-<none>}"
      return "$KEY_GATE_REFUSED" ;;
    9)
      # ⛔ see the lane-path arm: an `oauth` entry on a provider with no handler is a certain death, and it shadows the
      # environment (round 32, P2, measured).
      [ "$quiet" = 1 ] && return 0
      printf '[key-gate] %s check=fail result=REFUSED reason=auth-store-oauth-unusable model=%s box_default=%s provider=%s settings_json=%s - %s/auth.json holds an `oauth` entry for a provider pi ships NO oauth handler for (anthropic github-copilot kimi-coding meta openai-codex openai openrouter radius xai), so it can never be turned into auth AND it shadows the environment; measured, `pi -p` answers `No API key found for <provider>.` even with the provider key exported. Repair or delete that entry and re-run (agent-infra#3443)\n' \
        "$label" "$dm" "$dm" "$prov" "$sj" "${agent_dir:-<none>}"
      return "$KEY_GATE_REFUSED" ;;
    1) : ;;
    *)
      [ "$quiet" = 1 ] && return 0
      printf '[key-gate] %s check=skipped reason=stored-credential-unresolvable model=%s box_default=%s provider=%s settings_json=%s — %s/auth.json holds an entry for this provider whose value this gate cannot resolve (a `!command`, an `oauth` credential on a provider that DOES have a handler - only pi\x27s registry knows whether that token is live - or a template whose variables are absent from both the entry env map and this environment), and pi reads that store BEFORE the environment; whether $%s is consulted at all is pi\x27s answer, so nothing is asserted about this pin\n' \
        "$label" "$dm" "$dm" "$prov" "$sj" "${agent_dir:-<none>}" "$(printf '%s\n' "$names" | paste -sd ',' - 2>/dev/null)"
      return 0 ;;
  esac
  # ⛔ THE TEMPLATE GATE NOW SITS HERE, AFTER THE STORE (round 24, P2 — see the ordering note above). With no entry in
  # the store there is nothing to assert FROM the template: an empty `names` would otherwise fall through to the
  # `check=ok` arm below with a blank `var=`, which is a pass line about nothing.
  if [ -z "$names" ]; then
    # ⛔ THE PIN OF A BUILT-IN PROVIDER IS DECIDABLE TOO (round 28, P2, measured — the same fact the LANE path now
    # uses): a box pinned to `deepseek` with no models.json is provisioned from pi's own table, so `--probe
    # --box-default` can answer instead of abstaining. The alternative was a documented verification that prints
    # "skipped" on the ordinary cell shape, which reads as "nothing wrong" on the very box #3443 measured.
    local pakind pblt pwhy pvar phit="" pb
    # ⛔ A DISCARDED template is not "the file names a template" any more (round 29): pi drops the apiKey with the config,
    # so the same built-in fallback applies as if the file named nothing for this provider — the rule
    # `key_gate_assert_main` already applies through its own `discarded` flag.
    if [ "$discarded" = "1" ]; then pakind="none"; else pakind="$(key_gate_apikind "$home" "$prov" "$cwd")"; fi
    case "$pakind" in
      literal)
        [ "$quiet" = 1 ] && return 0
        printf '[key-gate] %s check=skipped reason=literal-api-key-in-models-json model=%s box_default=%s provider=%s settings_json=%s — this provider has a LITERAL `apiKey` in models.json (no `$NAME` reference), which pi uses as the credential itself: no environment variable is the question, and the pin is NOT refused\n' \
          "$label" "$dm" "$dm" "$prov" "$sj"
        return 0 ;;
      absent|none) : ;;
      *)
        [ "$quiet" = 1 ] && return 0
        printf '[key-gate] %s check=skipped reason=cannot-resolve-provider-credential model=%s box_default=%s provider=%s settings_json=%s — the apiKey template for the STARTUP provider is not resolvable (an UNPARSEABLE models.json, a read the bound killed, a `!command`), so nothing is asserted here\n' \
          "$label" "$dm" "$dm" "$prov" "$sj"
        return 0 ;;
    esac
    if [ -n "$pgrant" ]; then pblt="certain:RADIUS_API_KEY"; else pblt="$(key_gate_builtin "$prov")"; fi
    # ⛔ `pblt` IS MULTI-LINE TOO (round 30), so the variable list comes from the first line alone — interpolating the
    # whole value splices the path prose into the message (measured on the lane site first).
    pbltv="$(printf '%s\n' "$pblt" | sed -n 's/^certain://p' | head -1)"
    case "$pblt" in
      certain:*)
        while read -r pb; do
          [ -n "$pb" ] || continue
          if key_gate_value_present "$pb"; then phit="$pb"; break; fi
        done <<< "$(printf '%s' "$pbltv" | tr ',' '\n')"
        if [ -n "$phit" ]; then
          [ "$quiet" = 1 ] && return 0
          printf '[key-gate] %s check=ok box_default=%s model=%s provider=%s var=%s settings_json=%s source=pi-builtin-env — the CREDENTIAL for the startup pair this box pins resolves from the pi provider table (%s), which holds a value here, and %s/auth.json has NO entry for this provider; no models.json template applies\n' \
            "$label" "$dm" "$dm" "$prov" "$phit" "$sj" "$pbltv" "${agent_dir:-<none>}"
          return 0
        fi
        pvar="$pbltv"; pvar="${pvar%%,*}"
        # ⛔ THE PATH ARMS COME BEFORE THE QUIET RETURN (round 31, P2, measured): with the order reversed, a VERTEX box
        # provisioned by ADC logged `check=warn reason=box-default-not-provisioned` in EVERY lane (warn mode) while
        # `--probe --box-default` on the same box answered `check=ok path=vertex-adc` — two answers, one box, and the
        # one in the log was false. The companion speaks on the positively-absent arm only, and here the credential is
        # positively present.
        popen="$(printf '%s\n' "$pblt" | sed -n 's/^pathopen://p' | head -1)"
        ppaths="$(printf '%s\n' "$pblt" | sed -n 's/^pathclosed://p' | paste -sd ',' - 2>/dev/null)"
        if [ -n "$popen" ]; then
          pwhy="$(printf '%s\n' "$pblt" | sed -n "s/^pathwhy:$popen://p" | head -1)"
          [ "$quiet" = 1 ] && return 0
          printf '[key-gate] %s check=ok box_default=%s model=%s provider=%s path=%s settings_json=%s source=pi-builtin-env — the CREDENTIAL for the startup pair this box pins comes from a NON-VARIABLE path (%s) that holds here, and %s/auth.json has NO entry for this provider (pi still has to know the model id %s; this line asserts the credential, not that the id exists)\n' \
            "$label" "$dm" "$dm" "$prov" "$popen" "$sj" "${pwhy:-$popen}" "${agent_dir:-<none>}" "$dm"
          return 0
        fi
        if [ "$quiet" = 1 ]; then
          printf '[key-gate] %s check=warn reason=box-default-not-provisioned box_default=%s model=%s provider=%s var=%s settings_json=%s source=pi-builtin-env — this box pins its STARTUP model to %s, and NONE of the pi variables for this provider (%s) holds a value here, so a `pi` launched with NO model flag will NOT start on %s: pi uses the saved default only when the provider is provisioned and otherwise falls through to step 4 of `findInitialModel` — the first model with a valid key — so it either runs a model nobody pinned and spends tokens on it (the #2208 class), or exits 1 with `No API key found for the selected model.` %s Pin a PROVISIONED defaultProvider/defaultModel, or launch with `--provider … --model …` (agent-infra#3443)\n' \
            "$label" "$dm" "$dm" "$prov" "$pvar" "$sj" "$dm" "$pbltv" "$dm" \
            "$( [ -n "$sel" ] && printf 'THIS LANE PINS provider=%s model=%s, so this line does not stop it — every bare `pi` on this box is affected.' "${sel%%$'\t'*}" "${sel#*$'\t'}" )"
          return 0
        fi
        cands="$(key_gate_candidates "$home" | paste -sd '|' - 2>/dev/null)"
        [ -n "$cands" ] || cands="<none-derivable>"
        # ⛔ THE PIN HAS THE SAME ALTERNATE PATHS, AND ITS OWN PRINTF (round 30, P1): the two call sites have separate
        # code, so a path arm at one of them says nothing about the other - the round-22 lesson, re-applied. The
        # computation lives ABOVE (round 31: it must precede the quiet return too), so only the refusal uses it here.
        pextra=""
        [ -n "$ppaths" ] && pextra=" paths=$ppaths"
        printf '[key-gate] %s check=fail result=REFUSED reason=box-default-not-provisioned model=%s box_default=%s provider=%s var=%s settings_json=%s models_json=%s candidates=%s source=pi-builtin-env%s\n' \
          "$label" "$dm" "$dm" "$prov" "$pvar" "$sj" "${agent_dir:+$agent_dir/models.json}" "$pbltv" "$pextra"
        if [ -n "$ppaths" ]; then
          printf '[key-gate] %s: the STARTUP model this box pins (%s under provider %s) takes its credential from the pi provider table for that provider (%s), OR from a NON-VARIABLE path this gate ALSO checked and found closed: %s. With neither, `pi -p --no-session --provider %s --model %s` answers "No API key found for %s." and exits. This is a verdict about the PIN, NOT a claim that the box cannot run an agent: export %s (or point ENV_FILE at a file that does), or provision that path, or pin a provisioned pair.\n' \
            "$label" "$dm" "$prov" "$pbltv" "$ppaths" "$prov" "$dm" "$prov" "$pvar"
          return "$KEY_GATE_REFUSED"
        fi
        printf '[key-gate] %s: the STARTUP model this box pins (%s under provider %s) takes its credential from the pi provider table for that provider (%s), and NONE of those variables holds a value here — measured: `pi -p --no-session --provider %s --model %s` answers "No API key found for %s." and exits. This is a verdict about the PIN, NOT a claim that the box cannot run an agent: export %s (or point ENV_FILE at a file that does), or pin a provisioned pair.\n' \
          "$label" "$dm" "$prov" "$pbltv" "$prov" "$dm" "$prov" "$pvar"
        return "$KEY_GATE_REFUSED" ;;
      uncertain:*)
        pvar="${pblt#uncertain:}"; pvar="${pvar%%$'\n'*}"
        pwhy="$(printf '%s\n' "$pblt" | sed -n 's/^why://p')"
        # ⛔ A PATH THAT IS OPEN IS A PASS HERE TOO (round 31, P2): `google-vertex` is `uncertain` because its api key
        # alone is rejected by the API, while ADC provisions it — so an ADC pin is provisioned, not unverifiable.
        popen="$(printf '%s\n' "$pblt" | sed -n 's/^pathopen://p' | head -1)"
        if [ -n "$popen" ]; then
          pwhy2="$(printf '%s\n' "$pblt" | sed -n "s/^pathwhy:$popen://p" | head -1)"
          [ "$quiet" = 1 ] && return 0
          printf '[key-gate] %s check=ok box_default=%s model=%s provider=%s path=%s settings_json=%s source=pi-builtin-env — the CREDENTIAL for the startup pair this box pins comes from a NON-VARIABLE path (%s) that holds here; the provider\x27s env variable is not sufficient on its own (the pi note: %s), and %s/auth.json has NO entry for this provider\n' \
            "$label" "$dm" "$dm" "$prov" "$popen" "$sj" "${pwhy2:-$popen}" "$pwhy" "${agent_dir:-<none>}"
          return 0
        fi
        [ "$quiet" = 1 ] && return 0
        ppaths="$(printf '%s\n' "$pblt" | sed -n 's/^pathclosed://p' | paste -sd ',' - 2>/dev/null)"
        pextra2=""
        [ -n "$ppaths" ] && pextra2=" paths=$ppaths"
        printf '[key-gate] %s check=warn reason=provider-credential-unverifiable provider=%s model=%s box_default=%s var=%s why=%s settings_json=%s source=pi-builtin-env%s — this pin names a provider pi ships whose credential needs more than that one variable (the pi note: %s), and %s so this gate cannot decide the pin from the environment alone; the pin is NOT refused\n' \
          "$label" "$prov" "$dm" "$dm" "$pvar" "${pwhy:-<none>}" "$sj" "$pextra2" "${pwhy:-<none>}" \
          "$( [ -n "$ppaths" ] && printf 'the non-variable path(s) %s were ALSO checked and are closed; ' "$ppaths" )"
        return 0 ;;
      noenv:*)
        # ⛔ A PROVIDER pi SHIPS WITH **NO** api-key VARIABLE IS A THIRD KIND (round 29, P3, measured): the credential
        # comes from an SDK chain this gate cannot read, so the honest verdict is cannot-say — refusing would block a
        # box provisioned by a role or a profile, and staying silent (the old behaviour) forfeited the pin entirely.
        pvar="${pblt#noenv:}"; pvar="${pvar%%$'\n'*}"
        pwhy="$(printf '%s\n' "$pblt" | sed -n 's/^why://p')"
        [ "$quiet" = 1 ] && return 0
        printf '[key-gate] %s check=warn reason=provider-credential-unverifiable provider=%s model=%s box_default=%s var=%s why=%s settings_json=%s — this pin names a provider pi ships whose credential comes from a chain rather than one variable (the pi note: %s), so this gate cannot decide the pin from the environment alone; the pin is NOT refused\n' \
          "$label" "$prov" "$dm" "$dm" "$pvar" "${pwhy:-<none>}" "$sj" "${pwhy:-<none>}"
        return 0 ;;
    esac
    [ "$quiet" = 1 ] && return 0
    printf '[key-gate] %s check=skipped reason=cannot-resolve-provider-credential model=%s box_default=%s provider=%s settings_json=%s — the apiKey template for the STARTUP provider is not resolvable, and the vendor built-in provider table names no environment variable for %s either, so nothing is asserted here\n' \
      "$label" "$dm" "$dm" "$prov" "$sj" "$prov"
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
  local store_rc=1 grant="" drop="" discarded=0 warn_drop=0 drop_why="" bkind="" bkind_rc=1
  # ⛔ THE RADIUS GRANT CHANGES THE CREDENTIAL QUESTION, SO IT IS READ BEFORE THE STORE (round 33, P1, measured): a
  # models.json provider with `oauth: "radius"` + a `baseUrl` is REPLACED by the gateway provider, whose auth is
  # `envApiKeyAuth(["RADIUS_API_KEY"])`, so `$DEEPSEEK_API_KEY` is neither what pi resolves nor proof that it runs.
  # Measured: RADIUS_API_KEY set + no DEEPSEEK_API_KEY -> pi RAN while this gate refused 82; the reverse -> pi answered
  # `Use /login to log into a provider via OAuth or API key.` while this gate printed `check=ok var=DEEPSEEK_API_KEY`.
  # ONE bounded read answers both the grant and the discarded-template question; two reads would spend the bound twice
  # (measured: a blocking models.json then answered outside it, 5c).
  comp="$(key_gate_compose "$home" "$KEY_GATE_PROVIDER" "$KEY_GATE_MODEL" "$cwd")"
  case "$comp" in *radius-grant*) grant=1 ;; esac
  # the MODEL-DEFINITION token, if the same read produced one (a granted provider can still have a dropped catalog)
  drop="$(printf '%s\n' "$comp" | grep -v '^radius-grant$' | head -1)"
  key_gate_stored_credential "$home" "$KEY_GATE_PROVIDER" "$cwd" "$grant"; store_rc=$?
  names="$(key_gate_var "$home" "$KEY_GATE_PROVIDER")"
  # ⛔ A GRANTED PROVIDER WHOSE MODEL DEFINITION CANNOT COMPOSE IS A REFUSAL, NOT A WARN (round 34, P1, measured): on a
  # non-default gateway `radiusProvider`'s baseline catalog is EMPTY, so `findModelDefaults` finds nothing, `modelFromJson`
  # throws and `recomposeProvider` DELETES the provider — measured, `pi -p --provider deepseek --model ZZDIFF` answers
  # `Error: Unknown provider "deepseek". Use --list-models to see available providers/models.` — while this gate printed
  # `check=ok var=RADIUS_API_KEY` (round 34's first cut, because the grant arm returns before the warn) or `check=ok
  # var=MYV` (round 29's warn-only policy). NO credential can rescue that box, so no credential answer is honest: the
  # verdict is about the FILE, with the model-level remedy. The default gateway is exempt (the baseline composes the
  # definition; measured `pi -p` reached the gateway), and the token names the model definition that failed.
  # \u26d4 THE URL LEVEL, NOT THE CREDENTIAL LEVEL (round 36 P1 + round 37 P1/P2, measured): a definition whose effective
  # baseUrl has no http(s) scheme makes pi build `new URL("<value>/messages")`, which throws `Invalid URL` before any
  # request — for a grant AND for an ordinary provider, so this is not gated on `grant`. The `-no-api` variant is the
  # shape where the definition also has no `api`: a SHIPPED provider still composes one and dies `Invalid URL`, while an
  # UNSHIPPED one has the composer throw first (`Error: Unknown provider`), so the message has to follow the provider.
  if [ "$drop" = "bad-gateway" ] || { [ "$drop" = "bad-gateway-no-api" ] && ! key_gate_builtin_unshipped "$KEY_GATE_PROVIDER"; }; then
    KEY_GATE_VAR="${names:-<none>}"; KEY_GATE_VAR="${KEY_GATE_VAR%%$'\n'*}"
    KEY_GATE_REASON="models-json-bad-gateway"
    printf '[key-gate] %s check=fail result=REFUSED reason=models-json-bad-gateway why=%s model=%s provider=%s var=%s models_json=%s - a model definition this lane can use has no absolute URL in its effective `baseUrl` (its own, else the one on the provider body), and pi builds the request from that value: measured `Invalid URL`, thrown before anything is sent. A definition that ALSO declares no `api` may instead lose the provider entirely (`Error: Unknown provider`), because pi cannot compose one without a baseline catalog. No credential answers that, so this is a verdict about the FILE: write an absolute `https://` baseUrl (on the model definition, or on the provider body) and give the definition its own `api` if it has none, then re-run (agent-infra#3443)\n' \
      "$label" "$drop" "$KEY_GATE_MODEL" "$KEY_GATE_PROVIDER" "$KEY_GATE_VAR" "${KEY_GATE_MODELS_JSON:-<none>}"
    return "$KEY_GATE_REFUSED"
  fi
  if [ "$drop" = "bad-gateway-no-api" ] && key_gate_builtin_unshipped "$KEY_GATE_PROVIDER"; then
    KEY_GATE_VAR="${names:-<none>}"; KEY_GATE_VAR="${KEY_GATE_VAR%%$'\n'*}"
    KEY_GATE_REASON="models-json-provider-dropped"
    printf '[key-gate] %s check=fail result=REFUSED reason=models-json-provider-dropped why=no-api:%s model=%s provider=%s var=%s models_json=%s - this provider is not one pi ships and a model definition here declares no `api`, so `modelFromJson` throws and `recomposeProvider` DELETES the provider - measured, `pi -p --provider %s --model %s` answers `Error: Unknown provider "%s".` NO credential can rescue it. Give the model definition its own `api` (and `baseUrl`), or drop it (agent-infra#3443)\n' \
      "$label" "$KEY_GATE_MODEL" "$KEY_GATE_MODEL" "$KEY_GATE_PROVIDER" "$KEY_GATE_VAR" "${KEY_GATE_MODELS_JSON:-<none>}" "$KEY_GATE_PROVIDER" "$KEY_GATE_MODEL" "$KEY_GATE_PROVIDER"
    return "$KEY_GATE_REFUSED"
  fi
  if [ "$grant" = "1" ] && [ -n "$drop" ]; then
    KEY_GATE_VAR="${names:-<none>}"; KEY_GATE_VAR="${KEY_GATE_VAR%%$'\n'*}"
    KEY_GATE_REASON="models-json-provider-dropped"
    printf '[key-gate] %s check=fail result=REFUSED reason=models-json-provider-dropped why=%s model=%s provider=%s var=%s models_json=%s - the pi composer cannot build this provider\x27s model definition (%s) and, because a Radius grant replaces the built-in catalog with a gateway one whose models arrive only after a refresh, `recomposeProvider` DELETES the provider: measured, `pi -p --provider %s --model %s` answers `Error: Unknown provider "%s".` NO credential can rescue it, so no environment variable is the question. Give the model definition its own `api` (and `baseUrl`), or drop it, and re-run (agent-infra#3443)\n' \
      "$label" "$drop" "$KEY_GATE_MODEL" "$KEY_GATE_PROVIDER" "$KEY_GATE_VAR" "${KEY_GATE_MODELS_JSON:-<none>}" "$drop" "$KEY_GATE_PROVIDER" "$KEY_GATE_MODEL" "$KEY_GATE_PROVIDER"
    return "$KEY_GATE_REFUSED"
  fi
  # ⛔ THE COMPOSER CAN TAKE THE TEMPLATE AWAY (round 28, P2, measured): `applyModelsJson` throws on `oauth` without a
  # provider-level `baseUrl`, `composeProvider` catches and returns the built-in base, and the provider's own `apiKey`
  # override is LOST with it — so the variable this template names is one pi never consults. Measured on the installed
  # pi: `{"deepseek":{"apiKey":"$MYK","oauth":"radius"}}` with MYK unset and DEEPSEEK_API_KEY exported -> pi RAN on its
  # built-in key (401 from deepseek), while this gate printed `check=fail result=REFUSED var=MYK`; the same box with MYK
  # exported and no DEEPSEEK_API_KEY answered `No API key found for deepseek.` — i.e. the template was inert BOTH ways.
  # So the names are dropped and the answer falls through to the store/built-in arms that pi actually resolves.
  # ⛔ AND THE GRANT DOES **NOT** DISCARD THE TEMPLATE (round 33, P1, measured — the first cut of this fix got it
  # backwards). Measured on the installed pi, all four shapes: a granted provider that declares an `apiKey` resolves THAT
  # template (`{"apiKey":"$KG","oauth":"radius","baseUrl":…}` + KG -> 401 from Radius, i.e. it RAN; the same box with
  # only RADIUS_API_KEY -> `No API key found`, both keys -> ran), and one that declares NO apiKey falls back to
  # RADIUS_API_KEY (grant + RADIUS_API_KEY -> 401; grant + DEEPSEEK_API_KEY -> `No API key found`). So the template keeps
  # its meaning when it exists, RADIUS_API_KEY answers when it does not (the built-in arm below), and the provider's OWN
  # variable is never the answer for a granted provider.
  # \u26d4 AND `oauth` WITHOUT A `baseUrl` DELETES AN UNSHIPPED PROVIDER TOO (round 35, P1, measured): the composer throws on
  # that shape, and with no built-in base to fall back on the provider is gone \u2014 measured `Error: Unknown provider` \u2014 so
  # the cannot-say the shipped-provider half earns is a false answer here.
  if [ "$drop" = "oauth-no-baseurl" ] && key_gate_builtin_unshipped "$KEY_GATE_PROVIDER"; then
    KEY_GATE_VAR="${names:-<none>}"; KEY_GATE_VAR="${KEY_GATE_VAR%%$'\n'*}"
    KEY_GATE_REASON="models-json-provider-dropped"
    printf '[key-gate] %s check=fail result=REFUSED reason=models-json-provider-dropped why=oauth-no-baseurl model=%s provider=%s var=%s models_json=%s - this provider sets `oauth` with no `baseUrl`, which makes the pi composer THROW, and `%s` is not a provider pi ships, so there is no built-in base to fall back on: `recomposeProvider` DELETES the provider - measured, `pi -p --provider %s` answers `Error: Unknown provider "%s".` No credential answers that; add a `baseUrl` to the provider body (and an `api`/`baseUrl` to each model) or drop the provider (agent-infra#3443)\n' \
      "$label" "$KEY_GATE_MODEL" "$KEY_GATE_PROVIDER" "$KEY_GATE_VAR" "${KEY_GATE_MODELS_JSON:-<none>}" "$KEY_GATE_PROVIDER" "$KEY_GATE_PROVIDER" "$KEY_GATE_PROVIDER"
    return "$KEY_GATE_REFUSED"
  fi
  if [ "$drop" = "oauth-no-baseurl" ] && [ -n "$names" ]; then
    printf '[key-gate] %s check=warn reason=models-json-api-key-discarded why=oauth-no-baseurl provider=%s model=%s var=%s home=%s agent_dir=%s — a models.json for this provider sets `oauth` with no `baseUrl`, and the pi composer THROWS on that (`provider-composer.js:154`), so the provider apiKey override is discarded and $%s is NOT the variable pi resolves here; the answer below comes from the store and the provider built-in variable instead
' \
      "$label" "$KEY_GATE_PROVIDER" "$KEY_GATE_MODEL" "${names%%$'\n'*}" "${home:-<none>}" "${KEY_GATE_AGENT_DIR:-<none>}" "${names%%$'\n'*}"
    names=""; discarded=1
  fi
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
    # ⛔ NO `export $<none>` IN AN INSTRUCTION (round 29, P3, measured — the gate side of the class lane.sh fixed
    # in rounds 25/26): with no models.json template the variable is the sentinel `<none>`, and the sentence told the
    # operator to export a shell token that does not exist. Two whole clauses, not one clause with a hole.
    case "${KEY_GATE_VAR:-}" in
      ""|"<none>"|"unknown")
        printf '[key-gate] %s check=fail result=REFUSED reason=auth-store-unreadable model=%s provider=%s var=%s home=%s agent_dir=%s - %s/auth.json does not PARSE, and pi reads that file before anything else: measured, `pi -p` answers `Credential store read failed for <provider>: ...` and exits, with AND without the provider key exported. No entry is resolvable from it and no models.json template names a variable here, so there is nothing to export: repair %s/auth.json (or delete it) and re-run (agent-infra#3443)\n' \
          "$label" "$KEY_GATE_MODEL" "$KEY_GATE_PROVIDER" "$KEY_GATE_VAR" "${home:-<none>}" "${KEY_GATE_AGENT_DIR:-<none>}" "${KEY_GATE_AGENT_DIR:-<none>}" "${KEY_GATE_AGENT_DIR:-<none>}"
        return "$KEY_GATE_REFUSED" ;;
    esac
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
  if [ "$store_rc" = "4" ]; then
    # ⛔ A VALID ENTRY WITH NO VALUE IS NOT AN UNRESOLVABLE ONE (round 27, P3, measured): `{"type":"api_key"}` with no
    # `key` at all reached the "whose value this gate cannot resolve (a `!command`, an `oauth` credential …)" line, which
    # describes an entry that HAS a value the gate cannot use — and tells the operator to look at a file that is fine.
    # What pi does with a key-less entry is fall back to the PROVIDER'S OWN built-in variable (measured: with
    # `DEEPSEEK_API_KEY` exported, pi ran), which is not the `models.json` template this gate asserts.
    printf '[key-gate] %s check=skipped reason=stored-credential-keyless provider=%s model=%s home=%s agent_dir=%s — %s/auth.json has a VALID `api_key` entry for this provider with NO `key`, so pi falls back to the provider\x27s own built-in variable (e.g. `DEEPSEEK_API_KEY`), NOT to the models.json template this gate follows; whether that variable yields a key is pi\x27s answer alone, so NOTHING is asserted here
' \
      "$label" "$KEY_GATE_PROVIDER" "$KEY_GATE_MODEL" "${home:-<none>}" "${KEY_GATE_AGENT_DIR:-<none>}" "${KEY_GATE_AGENT_DIR:-<none>}"
    return 0
  fi
  if [ "$store_rc" = "7" ]; then
    # ⛔ A KEY TEMPLATE THAT RESOLVES TO NOTHING IS NOT "NO `key` FIELD" (round 29, P3, measured): this entry HAS a
    # key, and pi resolves it to `undefined` — so the provider is unprovisioned and pi falls back to its OWN variable
    # (measured: `DEEPSEEK_API_KEY` still runs that box). Cannot-say, with the remedy for THIS shape.
    printf '[key-gate] %s check=skipped reason=stored-credential-unresolved provider=%s model=%s home=%s agent_dir=%s — %s/auth.json holds an `api_key` entry whose `key` is a TEMPLATE that resolves to nothing here (its variables are absent from both the entry env map and this environment), so pi treats the provider as unprovisioned and falls back to its own built-in variable; whether that yields a key is pi\\x27s answer alone, so NOTHING is asserted here\n' \
      "$label" "$KEY_GATE_PROVIDER" "$KEY_GATE_MODEL" "${home:-<none>}" "${KEY_GATE_AGENT_DIR:-<none>}" "${KEY_GATE_AGENT_DIR:-<none>}"
    return 0
  fi
  if [ "$store_rc" = "8" ]; then
    # ⛔ `null` PARSES AND STILL KILLS pi (round 29, P3, measured): `auth.json` = `null` is valid JSON, and pi then
    # evaluates `readState.data[provider]` on it — `Credential store read failed for <provider>: Cannot read
    # properties of null (reading <provider>)`, WITH the key exported. The rc-6 sentence said "does not PARSE", which
    # sent the operator looking for a syntax error that is not there.
    KEY_GATE_VAR="${names:-<none>}"; KEY_GATE_VAR="${KEY_GATE_VAR%%$'\n'*}"
    KEY_GATE_REASON="auth-store-null"
    printf '[key-gate] %s check=fail result=REFUSED reason=auth-store-null model=%s provider=%s var=%s home=%s agent_dir=%s - %s/auth.json is a JSON `null`, which parses and then kills pi at read time: measured, `pi -p` answers `Credential store read failed for <provider>: Cannot read properties of null (reading <provider>)` and exits, with AND without the provider key exported. There is no entry to resolve, so no variable can rescue it: write `{}` (or delete the file) and re-run (agent-infra#3443)\n' \
      "$label" "$KEY_GATE_MODEL" "$KEY_GATE_PROVIDER" "$KEY_GATE_VAR" "${home:-<none>}" "${KEY_GATE_AGENT_DIR:-<none>}" "${KEY_GATE_AGENT_DIR:-<none>}"
    return "$KEY_GATE_REFUSED"
  fi
  if [ "$store_rc" = "9" ]; then
    # ⛔ AN `oauth` ENTRY ON A PROVIDER WITH NO OAUTH HANDLER IS A CERTAIN DEATH (round 32, P2, measured): the handler set
    # is a STATIC list in the vendor tree (`OAUTH_PROVIDERS`), and a stored entry SHADOWS the environment, so this box
    # fails with `No API key found for <provider>.` even with the provider key exported — measured with an `oauth` entry
    # for `deepseek` AND `DEEPSEEK_API_KEY` set. The old answer here folded it into rc 3 ("only pi's registry knows"),
    # which is a silent end over a lane that provably cannot start.
    KEY_GATE_VAR="${names:-<none>}"; KEY_GATE_VAR="${KEY_GATE_VAR%%$'\n'*}"
    KEY_GATE_REASON="auth-store-oauth-unusable"
    printf '[key-gate] %s check=fail result=REFUSED reason=auth-store-oauth-unusable model=%s provider=%s var=%s home=%s agent_dir=%s - %s/auth.json holds an `oauth` entry for a provider pi ships NO oauth handler for (its handlers cover: %s), so the stored credential can never be turned into auth AND it shadows the environment: measured, `pi -p` answers `No API key found for <provider>.` even with $%s exported. Repair or delete that entry (`pi /login` rewrites it), then re-run (agent-infra#3443)\n' \
      "$label" "$KEY_GATE_MODEL" "$KEY_GATE_PROVIDER" "$KEY_GATE_VAR" "${home:-<none>}" "${KEY_GATE_AGENT_DIR:-<none>}" "${KEY_GATE_AGENT_DIR:-<none>}" "anthropic github-copilot kimi-coding meta openai-codex openai openrouter radius xai" "${names:-<none>}"
    return "$KEY_GATE_REFUSED"
  fi
  if [ "$store_rc" = "3" ]; then
    # ⛔ A STORE ENTRY THIS GATE CANNOT RESOLVE IS NOT A CREDENTIAL AND IS NOT A REFUSAL (review cycle 1,
    # P2): `auth.json` holds a `!command` value, so only pi can say whether it yields a key. Saying
    # `holds a credential` here would be the same FALSE PASS the `env`-without-`key` arm was fixed for; a
    # refusal would be a false block on a box that works. The third answer is the honest one.
    printf '[key-gate] %s check=skipped reason=stored-credential-unresolvable provider=%s model=%s home=%s agent_dir=%s — %s/auth.json holds an entry for this provider whose value this gate cannot resolve (a `!command`, an `oauth` credential on a provider that DOES have a handler - only pi\x27s registry knows whether that token is live - or a template whose variables are absent from both the entry env map and this environment); whether that yields a key is pi\x27s answer alone, so NOTHING is asserted here\n' \
      "$label" "$KEY_GATE_PROVIDER" "$KEY_GATE_MODEL" "${home:-<none>}" "${KEY_GATE_AGENT_DIR:-<none>}" "${KEY_GATE_AGENT_DIR:-<none>}"
    return 0
  fi
  if [ -z "$names" ]; then
    # ⛔ THE KIND DECIDES WHICH CANNOT-SAY THIS IS (round 28, P2, measured). See `key_gate_apikind`.
    local akind blt bvar bwhy hit="" b
    # A DISCARDED template is not "the file names a template" any more (round 28): pi drops the apiKey with the config,
    # so the same built-in fallback applies as if the file named nothing for this provider.
    if [ "$discarded" = "1" ]; then akind="none"; else akind="$(key_gate_apikind "$home" "$KEY_GATE_PROVIDER" "$cwd")"; fi
    if [ "$akind" = "literal" ]; then
      # pi provisions the provider from the literal itself (`resolveConfigValue` returns it unchanged), so there is no
      # environment variable to assert AND no absence to refuse — a verdict here would be a false block on any box.
      printf '[key-gate] %s check=skipped reason=literal-api-key-in-models-json provider=%s model=%s home=%s models_json=%s — %s declares a LITERAL `apiKey` for this provider (no `$NAME` reference), which pi uses as the credential itself, so NO environment variable is the question and nothing is asserted here\n' \
        "$label" "$KEY_GATE_PROVIDER" "$KEY_GATE_MODEL" "${home:-<none>}" "${KEY_GATE_MODELS_JSON:-<none>}" "${KEY_GATE_MODELS_JSON:-models.json}"
      return 0
    fi
    # ⛔ ONLY `absent`/`none` REACH THE BUILT-IN ARM (round 28, P3, measured): an UNPARSEABLE models.json and a READ
    # THAT DID NOT FINISH are data this gate did not see, and pi may well read them at runtime — so they keep the
    # cannot-say answer. A `!command` is pi's to evaluate. Refusing on either would be the false block this file's
    # header forbids, and the suite's bound-fired arm caught exactly that.
    case "$akind" in absent|none) ;; *)
      printf '[key-gate] %s check=skipped reason=cannot-resolve-provider-credential model=%s provider=%s home=%s — the apiKey template for this provider is not resolvable from %s (absent, unparseable, a literal, no python3, a `!command` value, or a provider pi authenticates itself), so NOTHING is asserted here\n' \
        "$label" "$KEY_GATE_MODEL" "$KEY_GATE_PROVIDER" "${home:-<none>}" "${KEY_GATE_MODELS_JSON:-<none>}"
      return 0 ;;
    esac
    # ⛔ A BUILT-IN PROVIDER IS DECIDABLE WITHOUT models.json, AND THAT IS THE #3443 CELL SHAPE (round 28, P2,
    # measured both directions on the installed pi): with no models.json at all, `pi -p --provider deepseek --model
    # deepseek-flash` answers `No API key found for deepseek.` without DEEPSEEK_API_KEY and reaches the provider (401)
    # with it. The old cannot-say here was rc 0 on a box pi dies on — the silence #3331 exists to remove, and the
    # exact line the issue reports. pi's own table (`dist/env-api-keys.js` `getApiKeyEnvVars`) is the authority.
    if [ "$grant" = "1" ]; then blt="certain:RADIUS_API_KEY"; else blt="$(key_gate_builtin "$KEY_GATE_PROVIDER")"; fi
    # ⛔ `blt` IS MULTI-LINE NOW (round 30): the `certain:` line plus one `pathopen:`/`pathclosed:`/`pathwhy:` line per
    # alternate path. `${blt#certain:}` used to BE the variable list and is not any more — interpolated into a printf it
    # spliced the path prose into the middle of the message (measured). The variable list is its own value, from the
    # first line only, so a path line can never reach a formatted field.
    bltv="$(printf '%s\n' "$blt" | sed -n 's/^certain://p' | head -1)"
    case "$blt" in
      certain:*)
        while read -r b; do
          [ -n "$b" ] || continue
          if key_gate_value_present "$b"; then hit="$b"; break; fi
        done <<< "$(printf '%s' "$bltv" | tr ',' '\n')"
        if [ -n "$hit" ]; then
          printf '[key-gate] %s check=ok var=%s provider=%s model=%s home=%s source=pi-builtin-env — pi provisions this BUILT-IN provider from its own variable (%s), which holds a value in the environment this lane runs with, and %s/auth.json has NO entry for this provider; no models.json template applies here\n' \
            "$label" "$hit" "$KEY_GATE_PROVIDER" "$KEY_GATE_MODEL" "${home:-<none>}" "$bltv" "${KEY_GATE_AGENT_DIR:-<none>}"
          return 0
        fi
        # ⛔ EVERY DOCUMENTED PATH, NOT JUST THE VARIABLE (round 30, P1, measured): the vendor code beside its env
        # table accepts a NON-VARIABLE credential for two providers pi ships (vertex ADC, anthropic federation), so
        # refusing on the variable alone blocked a box where `pi -p` reaches the provider (`invalid_client` / a
        # federation token-exchange error, measured with no credential variable set at all). An OPEN path is a pass -
        # it is the credential pi will use - and the line says which path answered, because no variable was consulted.
        bopen="$(printf '%s\n' "$blt" | sed -n 's/^pathopen://p' | head -1)"
        bpaths="$(printf '%s\n' "$blt" | sed -n 's/^pathclosed://p' | paste -sd ',' - 2>/dev/null)"
        if [ -n "$bopen" ]; then
          bwhy="$(printf '%s\n' "$blt" | sed -n "s/^pathwhy:$bopen://p" | head -1)"
          printf '[key-gate] %s check=ok provider=%s model=%s home=%s path=%s source=pi-builtin-env — pi provisions this BUILT-IN provider from a NON-VARIABLE path (%s), which holds in the environment this lane runs with, and %s/auth.json has NO entry for this provider; no environment variable is the question here, and no models.json template applies\n' \
            "$label" "$KEY_GATE_PROVIDER" "$KEY_GATE_MODEL" "${home:-<none>}" "$bopen" "${bwhy:-$bopen}" "${KEY_GATE_AGENT_DIR:-<none>}"
          return 0
        fi
        bvar="$bltv"; bvar="${bvar%%,*}"
        KEY_GATE_VAR="$bvar"; KEY_GATE_REASON="credential-missing"
        # ⛔ `paths=` RIDES ON THE TOKEN LINE (round 30, P1): a fleet scan cuts fields off that line, so an
        # alternate path this gate checked and found closed belongs there as a field — not only in the prose, where
        # nothing that parses the refusal can see it.
        bextra=""
        [ -n "$bpaths" ] && bextra=" paths=$bpaths"
        printf '[key-gate] %s check=fail result=REFUSED reason=%s var=%s provider=%s model=%s agent_dir=%s models_json=%s candidates=%s source=pi-builtin-env%s\n' \
          "$label" "$KEY_GATE_REASON" "$bvar" "$KEY_GATE_PROVIDER" "$KEY_GATE_MODEL" "${KEY_GATE_AGENT_DIR:-<none>}" "${KEY_GATE_MODELS_JSON:-<none>}" "$bltv" "$bextra"
        if [ -n "$bpaths" ]; then
          # ⛔ THE REFUSAL NAMES THE ALTERNATIVE PATHS IT ALSO CLOSED (round 30, P1): an operator who HAS provisioned
          # one of them needs to see that the gate looked, or the refusal reads as "you have no credential" when what
          # it means is "neither the variable nor <these paths> is set here".
          printf '[key-gate] %s: pi resolves this BUILT-IN provider from %s (its own table, `dist/env-api-keys.js`), OR from a NON-VARIABLE path this gate ALSO checked and found closed: %s. Measured: with neither, `pi -p --no-session --provider %s --model %s` answers "No API key found for %s." and exits. ⛔ ON A CELL THE VARIABLE IS THE USUAL TRAP: HOME is redirected to the operational home (%s) so the operational layer is found, and the credential usually lives in the ACCOUNT home instead — export %s (or point ENV_FILE at a file that does) and re-dispatch. No models.json apiKey template is involved here (%s)\n' \
            "$label" "$bltv" "$bpaths" "$KEY_GATE_PROVIDER" "$KEY_GATE_MODEL" "$KEY_GATE_PROVIDER" "$CELL_HOME" "$bvar" "${KEY_GATE_MODELS_JSON:-<none>}"
          return "$KEY_GATE_REFUSED"
        fi
        printf '[key-gate] %s: pi resolves this BUILT-IN provider from %s alone (its own table, `dist/env-api-keys.js`), and NOTHING in the environment this lane would run with holds a value for any of them — measured: `pi -p --no-session --provider %s --model %s` answers "No API key found for %s." and exits having done nothing. ⛔ ON A CELL THIS IS THE TRAP: HOME is redirected to the operational home (%s) so the operational layer is found, and the credential usually lives in the ACCOUNT home instead — export %s (or point ENV_FILE at a file that does) and re-dispatch. No models.json apiKey template is involved here (%s)\n' \
          "$label" "$bltv" "$KEY_GATE_PROVIDER" "$KEY_GATE_MODEL" "$KEY_GATE_PROVIDER" "$CELL_HOME" "$bvar" "${KEY_GATE_MODELS_JSON:-<none>}"
        return "$KEY_GATE_REFUSED" ;;
      uncertain:*)
        # A built-in whose env var alone is NOT the whole answer refuses NOTHING (see the table measured notes):
        # the line names the variable to check so the operator has something to act on, and the polarity stays.
        # ⛔ \`candidates=\` STAYS ONE TOKEN (round 28, P3): the measured reason used to be spliced into it, which put
        # spaces in a field a scanner cuts — it is carried on its own \`why=\` field instead.
        bvar="${blt#uncertain:}"; bvar="${bvar%%$'\n'*}"
        bwhy="$(printf '%s\n' "$blt" | sed -n 's/^why://p')"
        # ⛔ AND A PATH THAT IS OPEN IS A PASS EVEN FOR AN UNCERTAIN PROVIDER (round 31, P2, measured): the variable
        # being insufficient says nothing about the NON-VARIABLE path, and it is the path that provisions the box
        # (`google-vertex` now sits here BECAUSE its api key is rejected by the API while ADC is not). Deciding
        # uncertain first would print `provider-credential-unverifiable` over a box pi runs — a cannot-say where the
        # answer is known, which is the #3443 report itself.
        bopen="$(printf '%s\n' "$blt" | sed -n 's/^pathopen://p' | head -1)"
        if [ -n "$bopen" ]; then
          bwhy2="$(printf '%s\n' "$blt" | sed -n "s/^pathwhy:$bopen://p" | head -1)"
          printf '[key-gate] %s check=ok provider=%s model=%s home=%s path=%s source=pi-builtin-env — pi provisions this BUILT-IN provider from a NON-VARIABLE path (%s), which holds in the environment this lane runs with; its env variable is not sufficient on its own (the pi note: %s), so the path is the credential, and %s/auth.json has NO entry for this provider\n' \
            "$label" "$KEY_GATE_PROVIDER" "$KEY_GATE_MODEL" "${home:-<none>}" "$bopen" "${bwhy2:-$bopen}" "$bwhy" "${KEY_GATE_AGENT_DIR:-<none>}"
          return 0
        fi
        # ⛔ AND IT NAMES THE NON-VARIABLE PATHS IT CHECKED (round 31, P2): `google-vertex` is uncertain BECAUSE its api
        # key is not sufficient — so the operator needs to see that ADC was evaluated and found closed, or the line reads
        # as "your variable is odd" when the actionable fact is "provision ADC". The field rides on the token line, where
        # a scanner cuts it, exactly like the refusal's.
        bpaths="$(printf '%s\n' "$blt" | sed -n 's/^pathclosed://p' | paste -sd ',' - 2>/dev/null)"
        bextra=""
        [ -n "$bpaths" ] && bextra=" paths=$bpaths"
        printf '[key-gate] %s check=warn reason=provider-credential-unverifiable provider=%s model=%s var=%s why=%s home=%s source=pi-builtin-env%s — this provider is one pi ships, but its credential needs more than that one variable (the pi note: %s), and %s so this gate cannot decide it from the environment alone; NOTHING is refused, and the variable above is the one to check\n' \
          "$label" "$KEY_GATE_PROVIDER" "$KEY_GATE_MODEL" "$bvar" "${bwhy:-<none>}" "${home:-<none>}" "$bextra" "${bwhy:-<none>}" \
          "$( [ -n "$bpaths" ] && printf 'the non-variable path(s) %s were ALSO checked and are closed; ' "$bpaths" )"
        return 0 ;;
      noenv:*)
        # ⛔ AND A PROVIDER pi SHIPS WITH NO api-key VARIABLE IS NOT "A PROVIDER pi DOES NOT SHIP" (round 29, P3,
        # measured): `amazon-bedrock` is a built-in whose credential is the AWS SDK chain, so the old fall-through
        # printed "the vendor built-in provider table names no environment variable for amazon-bedrock either" —
        # true but useless, and it described a built-in as if it were a custom provider.
        bvar="${blt#noenv:}"; bvar="${bvar%%$'\n'*}"
        bwhy="$(printf '%s\n' "$blt" | sed -n 's/^why://p')"
        printf '[key-gate] %s check=warn reason=provider-credential-unverifiable provider=%s model=%s var=%s why=%s home=%s — this provider is one pi ships and authenticates from a CHAIN rather than one variable (the pi note: %s), so this gate cannot decide it from the environment alone; NOTHING is refused, and the variable above is the one to start from\n' \
          "$label" "$KEY_GATE_PROVIDER" "$KEY_GATE_MODEL" "$bvar" "${bwhy:-<none>}" "${home:-<none>}" "${bwhy:-<none>}"
        return 0 ;;
    esac
    # Blindness is not a refusal (see the header's polarity rule). pi has no env-var entry for this provider either,
    # so this is the genuinely undecidable case (a provider pi authenticates through a registry this gate cannot read).
    printf '[key-gate] %s check=skipped reason=cannot-resolve-provider-credential model=%s provider=%s home=%s — the apiKey template for this provider is not resolvable from %s (absent, unparseable, a literal, no python3, a `!command` value, or a provider pi authenticates itself), and the vendor built-in provider table names no environment variable for %s either, so NOTHING is asserted here\n' \
      "$label" "$KEY_GATE_MODEL" "$KEY_GATE_PROVIDER" "${home:-<none>}" "${KEY_GATE_MODELS_JSON:-<none>}" "$KEY_GATE_PROVIDER"
    return 0
  fi
  # EVERY name a multi-reference template names must hold a value (review cycle 1, P2): pi refuses the
  # provider unless all of them resolve, so asserting only the first would pass a lane pi still kills.
  KEY_GATE_VAR="$(printf '%s\n' "$names" | paste -sd ',' - 2>/dev/null)"
  for n in $names; do
    key_gate_value_present "$n" || { missing="$n"; break; }
  done
  [ -n "$missing" ] && KEY_GATE_VAR="$missing"
  case "$drop" in
    no-api:*|no-baseurl:*)
      # ⛔ A MODEL DEFINITION pi CANNOT COMPOSE TAKES THE PROVIDER WITH IT WHEN THE PROVIDER IS NOT BUILT IN (round 28,
      # P3, measured): `modelFromJson` throws on a missing `api`/`baseUrl`, the catch returns `base` (undefined for a
      # custom provider) and `recomposeProvider` DELETES it — `pi -p --provider myprov --model m1` -> `Unknown provider
      # "myprov"`. A BUILT-IN provider composes both from its own model (`findModelDefaults`), so the config survives and
      # the assertion below stands. Warn-only: a provider this gate does not recognise must never block a lane.
      # ⛔ A VENDOR BUILT-IN IS ONLY "UNAFFECTED" WHEN ITS BASE MODEL IS STILL THERE (round 29, P2, measured): with
      # `oauth` set, `configureRadiusProviders` REPLACES the built-in base with a gateway provider whose catalog is
      # empty until a refresh, so the same throw deletes the config for a provider that IS built in (`pi -p` then
      # answers `Unknown provider "deepseek"`). The `:oauth` suffix on the reason says the base is gone, and it is
      # warned about unconditionally. And `known:` (a vendor provider with no env-var entry, `amazon-bedrock`) is a
      # provider pi ships, so its model IS composed and it must not be reported as dropped.
      # ⛔ the read STATUS comes with the token (round 35 review, P1): `bkind` is empty both when pi does not ship this
      # provider AND when the table could not be read, and only the FIRST of those is a refusal.
      bkind="$(key_gate_builtin_probe "$KEY_GATE_PROVIDER")"; bkind_rc=$?
      # the field-level diagnosis, shared by the warn and the refusal
      case "$drop" in
        no-api:*) drop_why='a model definition here declares neither `api` nor `baseUrl`, and the provider body declares neither either' ;;
        *) drop_why='a model definition here declares `api` but no `baseUrl`, and the provider body declares no `baseUrl` either' ;;
      esac
      case "$drop" in
        *:oauth) warn_drop=1 ;;
        # \u26d4 A PROVIDER pi DOES NOT SHIP IS DELETED, NOT WARNED ABOUT (round 35, P1, measured): the warn-only policy
        # assumed this gate cannot know what pi does with a provider it does not recognise, but it can \u2014 there is no
        # base to compose from, so `recomposeProvider` DELETES it. Measured on a `myprov` fixture: `pi -p --provider
        # myprov --model m1` answers `Error: Unknown provider "myprov".` while this gate printed the warning and then
        # `check=ok var=MYV`. No credential can rescue that box, so the answer is a refusal about the FILE.
        # ⛔ REFUSE ONLY ON A COMPLETED READ THAT SAID "NOT SHIPPED" (round 35 review, P1, measured): the round-35 fix
        # read the same empty `bkind` an unreadable table produces as a positive claim, so a box that is healthy was
        # refused 82 with a remedy that was not why it fired. `bkind_rc` separates the two; an unread table falls
        # through to the pre-existing `warn` below.
        *) if [ "$bkind_rc" -eq 0 ] && [ -z "$bkind" ]; then
             KEY_GATE_VAR="${KEY_GATE_VAR:-<none>}"
             KEY_GATE_REASON="models-json-provider-dropped"
             # ⛔ THE 11th ARGUMENT (round 35 review, P2, measured): the format has 11 `%s` and this list had 10, with
             # `drop_why` in the provider slot — it rendered "`<clause>` is not a provider pi ships, myprov", a
             # `--provider`/`--model` pair swapped, and `Unknown provider ""`. The sibling pin-path message carries
             # the same sentence in the right order.
             printf '[key-gate] %s check=fail result=REFUSED reason=models-json-provider-dropped why=%s model=%s provider=%s var=%s models_json=%s - `%s` is not a provider pi ships, %s, so there is no base model for the composer to fall back on: `modelFromJson` throws and `recomposeProvider` DELETES the provider - measured, `pi -p --provider %s --model %s` answers `Error: Unknown provider "%s".` NO credential can rescue it, so no environment variable is the question. Give this model definition its own `api` (and `baseUrl`), or drop it (agent-infra#3443)\n' \
               "$label" "$drop" "$KEY_GATE_MODEL" "$KEY_GATE_PROVIDER" "$KEY_GATE_VAR" "${KEY_GATE_MODELS_JSON:-<none>}" "$KEY_GATE_PROVIDER" "$drop_why" "$KEY_GATE_PROVIDER" "$KEY_GATE_MODEL" "$KEY_GATE_PROVIDER"
             return "$KEY_GATE_REFUSED"
           fi
           if [ -z "$bkind" ]; then warn_drop=1; else warn_drop=0; fi ;;
      esac
      if [ "$warn_drop" = "1" ]; then
        printf '[key-gate] %s check=warn reason=models-json-provider-dropped why=%s provider=%s model=%s var=%s models_json=%s — %s, which makes the pi composer THROW; when the provider is not one pi ships that DELETES the provider (measured: `pi -p --provider <custom> --model <id>` -> `Unknown provider`), so this credential assertion names a variable pi may never consult — check `pi --list-models`. A provider pi ships composes both from its own model instead, EXCEPT when `oauth` is set: pi then swaps the built-in catalog for a gateway provider whose models arrive only after a refresh, so the same throw deletes the config there too (measured: `Unknown provider "deepseek"`)\n' \
          "$label" "$drop" "$KEY_GATE_PROVIDER" "$KEY_GATE_MODEL" "${KEY_GATE_VAR:-<none>}" "${KEY_GATE_MODELS_JSON:-<none>}" "$drop_why"
      fi ;;
  esac
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
    "$label" "$KEY_GATE_VAR" "$CELL_HOME" "$KEY_GATE_VAR" "$KEY_GATE_PROVIDER" "$KEY_GATE_MODEL" "$KEY_GATE_PROVIDER" "$KEY_GATE_MODEL"
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
