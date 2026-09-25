"""ci_exemption.py — the rail's ONE module for #3756 (tortoise #3756).

THIS FILE IS TWO HALVES, DELIBERATELY, IN ONE MODULE. The FAILED-id parser (the
rail extractor, PR #1165) is the BASE; the rate/signature/decision engine (PR
#1147) is built ON TOP of that parser — **never beside it**. Everything that needs
to know which failures a run reported goes through :func:`parse_failed_ids`, so
the shell rail and the decision can never disagree about the id universe.

HALF 1 — THE CANONICAL FAILED-ID PARSER (``ids``)

Two defects motivated it:

* **DEFECT 1 — an unparseable token must not become a failure id.** The shell
  rail used to print whatever token followed a bare ``FAILED`` field, so English
  prose (``may``) entered the failure set as if it were a nodeid. A garbage id
  matches nothing on main: it can never be subtracted or verified, so it reads as
  "unique to this PR" on EVERY rail run for EVERY PR whose log contains that
  fragment — a permanent false refusal. A candidate that is not a test id is
  **DROPPED, COUNTED and REPORTED** as UNATTRIBUTABLE, never carried, never read
  as "no failures".
* **DEFECT 2 — a MOVING identity is not an attribution.** Within one concluded
  cycle the same head's failure ids can shift across the re-run boundary (one id
  replaced by another). :func:`detect_rotating_identity` names the class that was
  red across runs with a NON-CONSTANT id, so a decision sees UNATTRIBUTABLE
  rather than a PR-unique failure (or a silent exemption) it cannot justify.

HALF 1b — GUARD-STEP ATTRIBUTION (#4469)

The id universe was pytest nodeids ONLY, so a failing run whose failure lives in a
non-pytest **guard step** (an orphan-count assert, a packaging guard, a health
gate) yielded NO id. ``examined=1 / extracted=0`` then tripped the rail's
fail-closed refusal ("yielded NO parseable 'FAILED <nodeid>' line … This is a
refusal") and the merge could not proceed through the sanctioned path — even
though the failure was real, attributable, and often a flaky guard owned by
another lane. That class is the one most likely to be flaky, and the rail could
neither compare it against main nor certify it as new.

A GitHub Actions error ANNOTATION in a failing step therefore becomes an identity
in the set — keyed by the failing STEP plus the error shape — so it participates
in the PR-vs-main comparison exactly like a test nodeid. The fail-closed refusal
is PRESERVED, on THREE conditions that are the whole safety of this half:

* the annotation is only an identity when it comes from a step the RUNNER ITSELF
  marked failed (its non-zero ``Process completed with exit code <N>.``), because
  an annotation printed by a step that did not fail the run is not evidence of a
  failure — junk in the union is a zero-evidence pass;
* the run's ROOT failing step — the FIRST one the runner marked, keyed by
  **(job, step)** because matrix legs run same-NAMED steps — must YIELD an
  identity (a ``FAILED`` nodeid on its lines, or a substantive annotation);
  otherwise the run contributes NO guard identity even when a LATER step carries a
  perfectly good annotation; and
* a step that shows pytest's own failure output (``E   <exception>``) must yield a
  NODEID. An annotation is not that classification, so the run is refused — the
  cycle-3 ``ImportError: no module named y`` case, which prints ``E   ImportError``
  and no ``FAILED`` line, and which would otherwise be LAUNDERED by a sibling — or
  same-step — annotation, letting ``examined > extracted`` pass and ``decide``
  certify a run whose real failure was never classified.

A DECLARED RESIDUAL remains (agent-infra #1366): an unparseable failure that
leaves NO pytest-shaped line AND whose step is not the root — e.g. a guard root
attributed first, then a non-pytest step failing with bare prose. Closing it needs
per-step conclusions from the run metadata. See :func:`guard_step_failures` and
the measured capture this is grounded on.

HALF 2 — THE PRE-MERGE EXEMPTION DECISION (``signatures``, ``decide``)

The pre-merge classifier used to decide ownership of a failure by MEMBERSHIP IN A
SAMPLE OF MAIN::

    unique-to-PR = (PR failing ids) - (union of main-failing ids over last N runs)

That is unsound in BOTH directions, and both directions are a defect:

* **face 1 (over-block, fail-closed).** A non-deterministic main-side failure whose
  recent main runs happened to be green reads as novel -> a clean PR is blocked.
  Costs a cycle. A COST, not a bypass.
* **face 2 (fail-OPEN, category A).** Any id that appears even ONCE in main's window
  is subtracted forever, so a PR that genuinely BREAKS that id is EXCUSED and the
  gate reports green. Reachable today.

The invariant this module exists to enforce:

    A test that fails on ``origin/main`` WITHOUT the PR's diff is NEVER PR-unique --
    and a test must never be labelled PR-unique FROM A SINGLE SAMPLE.

The fix reasons about the EFFECT ("did this PR change the failure rate?") rather
than about the sample, which makes the decision **signature-scoped**, **rate-
compared** and **visible**:

* **signature-scoped** -- an exemption covers the failure that was measured on main,
  not the whole node id. A PR that holds the same RATE while breaking a DIFFERENT
  assertion inside the same test is NOT exempt: same id, different signature.
* **rate-compared** -- a declared ``K`` on BOTH trees; presence is never sufficient.
  ``main 1/8`` vs ``PR 8/8`` is an eight-fold regression and must block; a presence
  test ("it fails on main too") would excuse it.
* **visible** -- every exemption is RECORDED with both rates. An exemption that
  exists only as an absence is the fail-open defect itself.

And the parser is **fail-closed** (#3705's rule applied to the exemption parser):
the union IS an allowlist, so junk in it is a zero-evidence pass. An unparseable or
non-nodeid line must REFUSE the exemption and be COUNTED AND REPORTED -- never
silently swallowed, never read as "no failures". Since #4469 the failure-key
universe is a pytest nodeid OR an attributable guard-step annotation (HALF 1b);
a line that is NEITHER is still refused, counted and reported.

Pure functions only: no I/O, no network, no git — except :func:`_read`, the
``ids`` CLI and the ``signatures`` CLI, which read the caller's own capture file.
The caller supplies the observed numbers; this module decides, and explains.
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

# --------------------------------------------------------------------------
# Strict parsing — the union is an allowlist, so junk must not enter it
# --------------------------------------------------------------------------

#: A pytest nodeid: ``path/to/test_x.py::[Class::]name`` (params allowed).
#: Deliberately anchored and narrow — anything else is REJECTED, not guessed.
_NODEID_RE = re.compile(
    r"^(?P<path>[A-Za-z0-9_./\-]+\.py)"
    r"::(?P<rest>[A-Za-z0-9_\[\]\-.:]+)$"
)

#: The tokens that open a failure record. One list, so the shell can never
#: disagree with the module about which lines are records at all.
_FAILED_FIELDS = ("FAILED", "ERROR")


def _failed_candidate(line: str) -> str | None:
    """The token following the FIRST ``FAILED``/``ERROR`` whitespace field.

    This is the exact position the retired shell ``awk`` read
    (``if ($i == "FAILED") { print $(i+1) }``), so no real id is lost by
    routing through this module. The return is deliberately three-valued:

    * ``None`` — no such field on the line: it is NOT a failure record (raw logs
      are mostly prose), and it is NOT a rejection either;
    * ``''``  — the field was the last token: a truncated record, which IS a
      rejection;
    * ``<token>`` — the candidate, which the caller MUST shape-check before use.
    """
    fields = line.split()
    for index, token in enumerate(fields):
        if token in _FAILED_FIELDS:
            return fields[index + 1] if index + 1 < len(fields) else ""
    return None


@dataclass
class ParseResult:
    """Parsed failure ids plus the lines that were REJECTED, and why.

    ``rejected`` is not diagnostics — it is evidence. A non-zero count means the
    union was filtered, and the reader is entitled to see it next to ``K`` and the
    rates rather than take a silently-trimmed set on trust.
    """

    ids: list[str] = field(default_factory=list)
    rejected: list[str] = field(default_factory=list)
    #: The subset of ``ids`` derived from a non-pytest GUARD-STEP annotation
    #: (#4469). Recorded separately so the caller REPORTS the attribution instead
    #: of leaving it invisible among the nodeids.
    guard_steps: list[str] = field(default_factory=list)

    @property
    def ok(self) -> bool:
        """False when the input yielded NO usable id at all.

        Fail-closed: an unreadable failure set must never present as an empty one.
        "I could not read main's failures" must not become "main has no failures",
        because that would exempt every PR failure in the other direction and, used
        as a PR set, would block nothing.
        """
        return bool(self.ids)


def parse_failed_ids(lines: str, *, raw_log: bool = False) -> ParseResult:
    """Extract failure ids from a log — THE canonical id parser.

    Two input shapes, ONE candidate rule (:func:`_failed_candidate`) and ONE
    definition of "is this a test id" (``_NODEID_LOOSE_RE``), so the shell cannot
    keep a second, weaker notion of a failure id:

    * ``raw_log=False`` (default) — a file of ``FAILED <nodeid>`` / ``ERROR
      <nodeid>`` records. A non-blank line that carries no ``FAILED``/``ERROR``
      field is **rejected**: in an id file, prose IS a defect (nothing else
      belongs there). No guard-step pass runs here — an id file IS the set.
    * ``raw_log=True`` — a raw ``gh run view --log-failed`` capture. ANSI SGR
      escapes and the ``<job>\t<step>\t<ts>Z `` prefix are stripped, then the
      candidate after the first ``FAILED``/``ERROR`` field is shape-checked. A
      line with no such field is not a failure record and is skipped — a raw log
      is mostly prose, and rejecting every prose line would drown the signal.
      A second pass attributes non-pytest GUARD-STEP failures (#4469) from their
      GitHub Actions error annotations, so a failure main can also be red on is
      COMPARED rather than refused.

    In BOTH shapes a candidate that is not a failure id is **DROPPED, COUNTED and
    REPORTED** (``rejected``) and never enters ``ids``. This is the #3756 ``may``
    leak: an English word in the candidate position used to be emitted verbatim
    as a failure id, and a garbage id matches nothing on main — it cannot be
    subtracted or verified, so it reads as "unique to this PR" on EVERY rail run
    for EVERY PR whose log contains that fragment. A permanent false refusal.

    This is the fail-closed rule: unknown resolves to *"not exempt"*, never to
    *"exempt"*. Silent permissiveness here is a zero-evidence pass — and a
    silently-CARRIED token is the permanent false refusal above.
    """
    ids: list[str] = []
    rejected: list[str] = []
    for raw in lines.splitlines():
        if raw_log:
            line = _strip_log_prefix(_ANSI_RE.sub("", raw)).strip()
            if not line:
                continue
            candidate = _failed_candidate(line)
            if candidate is None:
                # Not a failure record. Skipped, NOT rejected.
                continue
            unit = candidate
        else:
            line = raw.strip()
            if not line:
                continue
            candidate = _failed_candidate(line)
            if candidate is None:
                rejected.append(line)
                continue
            unit = line
        if not _NODEID_LOOSE_RE.match(candidate):
            # The unit reported is the offending TOKEN in log mode (the line may
            # be a whole megabyte of prose prefixed by a stray `FAILED`), and the
            # offending LINE in id-file mode (where the line IS the record).
            rejected.append(unit)
            continue
        ids.append(candidate)
    guard_steps: list[str] = []
    if raw_log:
        # Pass 2 — GUARD-STEP failures (#4469). A non-pytest step announces its
        # failure with a GitHub Actions error ANNOTATION, which the FAILED-field
        # pass above cannot see. Those become ids too, so a guard-step failure is
        # COMPARED instead of refused. Deliberately not done for an id-file
        # (raw_log=False): there the file IS the id set already.
        guard_steps, _guard_signatures = guard_step_failures(lines)
        ids.extend(guard_steps)
    return ParseResult(
        ids=sorted(set(ids)), rejected=rejected, guard_steps=guard_steps
    )


# --------------------------------------------------------------------------
# The decision — signature-scoped, rate-compared, visible
# --------------------------------------------------------------------------


@dataclass(frozen=True)
class Rate:
    """Failures observed over ``runs`` runs on one tree (PR or main)."""

    failures: int
    runs: int

    @property
    def rate(self) -> float:
        return (self.failures / self.runs) if self.runs > 0 else 0.0

    def __str__(self) -> str:  # "4/8 (50%)"
        return f"{self.failures}/{self.runs} ({self.rate:.0%})"

    def __gt__(self, other: object) -> bool:
        """Compare by RATE, so a Rate is never silently compared by identity."""
        if isinstance(other, Rate):
            return self.rate > other.rate
        return NotImplemented


@dataclass(frozen=True)
class RatesResult:
    """The rate table read from ``ci-failure-set.sh --main-union-rates``."""

    rates: dict[str, Rate] = field(default_factory=dict)
    rejected: list[str] = field(default_factory=list)

    @property
    def runs(self) -> int:
        """The declared K, or 0 when nothing was usable."""
        return max((r.runs for r in self.rates.values()), default=0)


_RATES_RE = re.compile(
    r"^(?P<nodeid>\S+)\t(?P<failures>[0-9]+)\t(?P<runs>[0-9]+)$"
)


def parse_rates(lines: str) -> RatesResult:
    """Parse the ``<nodeid>\\t<failures>\\t<runs>`` rate table.

    Fail-closed, for the same reason as :func:`parse_failed_ids`: this table feeds
    the comparison that OVERRIDES a failure, so a line the reader does not fully
    understand must never become evidence of main-side unhealth. Anything not
    exactly three tab-separated fields -- a valid failure key (a pytest nodeid
    OR a guard-step identity, #4469), a non-negative failure count, and a
    **positive** run count -- is rejected, counted and reported.

    ``runs`` must be positive: ``X\\t0\\t0`` would give a ``0/0`` rate of ``0.0``
    and read as "main never fails this", which is the exemption-by-vacuity this
    module exists to prevent. A rejected line simply contributes no rate, and an
    id with no rate is **not exempt** (the existing default in :func:`decide`).
    """
    rates: dict[str, Rate] = {}
    rejected: list[str] = []
    for raw in lines.splitlines():
        line = raw.strip("\n")
        if not line.strip():
            continue
        m = _RATES_RE.match(line)
        if not m:
            rejected.append(line)
            continue
        nodeid = m.group("nodeid")
        failures = int(m.group("failures"))
        runs = int(m.group("runs"))
        if not is_failure_key(nodeid) or runs <= 0 or failures > runs:
            rejected.append(line)
            continue
        if nodeid in rates:
            # Duplicate rows (latent finding 2): "A 8 8" then "A 0 8" yielded
            # Rate(0,8) while the REVERSED order yielded Rate(8,8) — row order
            # decided whether the PR blocked, an order-dependence inside the
            # verdict-stability class. Reject rather than pick a winner: a table
            # that contradicts itself is not evidence, and fail-closed means the id
            # then has no rate at all (not exempt).
            rejected.append(line)
            rates.pop(nodeid, None)
            continue
        rates[nodeid] = Rate(failures=failures, runs=runs)
    return RatesResult(rates=rates, rejected=rejected)


@dataclass(frozen=True)
class Failure:
    """A PR-side failure: how often, and with which signatures."""

    rate: Rate
    signatures: frozenset[str] = frozenset()


@dataclass(frozen=True)
class Verdict:
    """One decision, with the reason stated so it can be audited."""

    nodeid: str
    blocked: bool
    reason: str

    @property
    def line(self) -> str:
        mark = "BLOCK " if self.blocked else "EXEMPT"
        return f"{mark}: {self.nodeid}  {self.reason}"


@dataclass
class Decision:
    blocked: list[Verdict] = field(default_factory=list)
    unattributable: list[Verdict] = field(default_factory=list)
    exempt: list[Verdict] = field(default_factory=list)
    notes: list[str] = field(default_factory=list)

    @property
    def any_blocked(self) -> bool:
        return bool(self.blocked)

    def visible_exemptions(self) -> list[str]:
        """The EXEMPT lines that MUST be recorded — never a silent exemption."""
        return [v.line for v in self.exempt]

    def report(self) -> str:
        out = [v.line for v in self.blocked] + self.visible_exemptions()
        out.extend(f"NOTE  : {n}" for n in self.notes)
        return "\n".join(out)



def class_key(nodeid: str) -> str:
    """The FILE/CLASS prefix — the unit that stays red while the IDENTITY moves."""
    parts = nodeid.split("::")
    return "::".join(parts[:2]) if len(parts) >= 2 else parts[0]


def detect_rotating_identity(runs: list[frozenset[str]]) -> dict[str, frozenset[str]]:
    """Keys whose failing IDENTITY changed between runs (required class E5).

    **An identity that changes across runs is NOT novel.** The baseline observed the
    CLASS; the id provably will not be the same next run. Measured on a real refusal
    (B6 on #3577): the rail reported ONE unique failure in a class that was red in
    three runs with THREE DIFFERENT ids inside it — run 1 two ids, runs 2-3 another.
    The class stayed red; the identity moved.

    The old re-run heuristic assumes a flake **passes** on retry and has no
    representation for "the failure moved", so the verdict became a function of which
    run you happened to sample. Both directions are in-surface:

    * **false-block** — a changed id is labelled "a NEW failure this PR introduces";
    * **false-PASS** — PR-minus-main compares SETS OF IDS from different samples, so an
      order-dependent flake can move OUT of the PR's set and INTO main's between runs
      and be exempted silently.

    Returns ``{class_key: union of ids seen red in that key}`` for every key that was
    red in >= 2 runs with a NON-CONSTANT id set. A class red in a single run is not
    reported (one sample cannot distinguish "moved" from "not yet moved").
    """
    per_key: dict[str, list[frozenset[str]]] = {}
    for r in runs:
        keys = {class_key(n) for n in r}
        for k in keys:
            per_key.setdefault(k, []).append(frozenset(n for n in r if class_key(n) == k))
    out: dict[str, frozenset[str]] = {}
    for k, sets in per_key.items():
        if len(sets) >= 2 and len({frozenset(x) for x in sets}) > 1:
            out[k] = frozenset().union(*sets)
    return out


def _signatures_overlap(pr: frozenset[str], main: frozenset[str]) -> bool:
    """True when the PR's failure matches a signature measured on main.

    When either side carries no signature information we cannot establish a match,
    and the fail-closed answer is to BLOCK rather than to exempt on an assumption.
    """
    if not pr or not main:
        return False
    # SUBSET, not intersection (review cycle 1, bypass 2). Intersection only asked
    # "do the two sets share ANY failure", so a PR that keeps main's assertion and
    # ADDS a new one was exempt — and the NEW failure, the one the PR introduced,
    # was exactly what got masked. Every signature the PR failed with must have
    # been measured on main; an extra one is a failure main never had.
    return pr <= main


def decide(
    pr_failures: dict[str, Failure],
    main_rates: dict[str, Rate],
    *,
    main_signatures: dict[str, frozenset[str]] | None = None,
    rotating: dict[str, frozenset[str]] | None = None,
    k_pr: int | None = None,

    # ⚠️ KNOWN, ACCEPTED, DOCUMENTED GAP — owner-authorized "Option B" on tortoise #3756.
    #
    # THIS IS A FAIL-OPEN IN THE EXEMPTION PATH. It is documented, not fixed, and the fix is
    # deferred BY THE OWNER — do not "fix" it here by surprise, and do not mistake it for an
    # undiscovered bug.
    #
    # THE FAILURE MODE (state it plainly — the next reader needs this, not the arithmetic):
    # the tolerance is MULTIPLICATIVE, so the band that counts as "rates equivalent" WIDENS in
    # absolute terms as main's rate rises. A PR that fails EVERY SINGLE RUN is therefore EXCUSED
    # once main is broken enough — A DETERMINISTIC TOTAL FAILURE TREATED AS A RATE FLUCTUATION.
    #
    # Concretely, with the default 1.5, THE RATE CONDITION for exemption is
    # `pr_rate <= mr.rate * 1.5` — and note that this is the NECESSARY rate test, not the whole
    # rule: FIVE earlier gates BLOCK first and are checked in order ahead of it — an empty PR
    # sample, a rotating/UNATTRIBUTABLE identity, an id absent from `main_rates`, non-overlapping
    # signatures, and `mr.runs < min_runs`. Only if all five pass does the rate test decide.
    # A PR failing every run has `pr_rate == 1.0`, so once `mr.rate >= 1/1.5` — ONCE MAIN IS
    # ABOUT TWO-THIRDS BROKEN (~0.667) — the rate test no longer stops it, and it is EXEMPTED
    # provided those earlier gates held. Past that point the gate reads a total, deterministic
    # failure as "no worse than main", and the more broken main gets, the wider this door opens.
    #
    # Note the asymmetry, which is why this is a fail-open and not a tuning complaint: the input
    # on the PR side is a TOTAL failure (every run failed) while the input on the main side is a
    # SAMPLE over a finite `k`. The comparison therefore weighs a stronger signal against a weaker
    # one, and the tolerance grows as the weaker side degrades. (`pr_rate` is still a rate over a
    # finite sample, so "total" here means "every observed run", not an infinite certainty — the
    # asymmetry is real but it is one of evidence strength, not of logical certainty.)
    #
    # DEFERRED FIX DIRECTION (owner-authorized as a follow-up, NOT to be applied here): a tolerance
    # that cannot excuse a TOTAL failure — e.g. an absolute floor, or refusing to exempt whenever
    # `pr_rate` is exactly 1.0 — since no rate comparison can make a 100% failure equivalent to
    # anything.
    rate_tolerance: float = 1.5,
    min_runs: int = 3,
) -> Decision:
    """Decide every PR failure: block it, or exempt it **visibly**.

    Rules, in order — each one closes a declared class:

    * id unknown to main's measurement -> **BLOCK** (no evidence of pre-existence).
    * signature disjoint from main's -> **BLOCK** (a DIFFERENT failure inside an id
      main also failed; same id is not same failure).
    * THIS id's main row measured over fewer than ``min_runs`` runs -> **BLOCK**
      (insufficient evidence; one observation cannot establish a rate). The floor is
      PER-ID and has no table-wide or caller-declared form: a ``k_main`` knob was
      removed because it was accepted and never read, which is the shape that
      produced this whole family of defects.
    * PR sample (``k_pr``) below ``min_runs`` -> the RATE dimension is
      **NOT-MEASURABLE** and is used NEITHER to exempt nor to block (#5250). The
      exemption then rests on the attribution question the gates above already
      answered — id measured red on main, overlapping signatures, main's own row
      >= ``min_runs`` — and the verdict SAYS the rate was not measurable.
    * PR rate materially above main's -> **BLOCK** (the PR made it worse).
    * otherwise -> **EXEMPT**, recorded with both rates.

    ``main_rates`` is a RATE per id, not a set of ids: presence alone is never
    sufficient, because presence is what excused ``main 1/8`` against ``PR 8/8``.

    ``main_signatures`` is explicit rather than global-by-accident: an EMPTY map
    means "no signature evidence", which makes every signature check fail CLOSED.
    """
    decision = Decision()
    sig_main = main_signatures or {}

    # The floor is PER-ID and has NO table-wide form (review cycle 2). A table-max
    # derivation has no legitimate use: the question is always "does THIS id's row
    # rest on enough runs?", and when the id has no row at all `mr` is None and the
    # decision already BLOCKS. Keeping it per-id makes the bug class — a healthy
    # NEIGHBOUR licensing a thin row's exemption — impossible to express at all,
    # rather than merely un-triggered by the current call sites.
    if k_pr is not None and k_pr < 1:
        decision.notes.append("pr sample empty — treating every failure as PR-side")

    for nodeid in sorted(pr_failures):
        pr = pr_failures[nodeid]
        mr = main_rates.get(nodeid)

        # PR-side validity (latent finding 1). `Failure(rate=Rate(3, 0))` has
        # `.rate == 0.0`, so it slipped past the comparison into EXEMPT while the
        # code emitted "pr sample empty — treating every failure as PR-side", which
        # claims the opposite. The runs>0 guard covered only the main-side parser.
        if pr.rate.runs <= 0:
            decision.notes.append(
                f"PR sample for {nodeid} is empty ({pr.rate}) — a PR failure with no "
                "measured sample cannot be exempted")
            decision.blocked.append(Verdict(
                nodeid, True,
                f"PR rate is unmeasurable ({pr.rate}) — NOT exempt"))
            continue

        # Required class E5 — ROTATING IDENTITY, checked FIRST. An id whose class was
        # red across runs with a MOVING id is UNATTRIBUTABLE: never "unique to this
        # PR", never exempt-and-silent. This must precede every other rule because
        # both of the other outcomes are attributions, and the evidence here supports
        # neither.
        if rotating and nodeid in rotating.get(class_key(nodeid), frozenset()):
            decision.unattributable.append(Verdict(
                nodeid, True,
                f"UNATTRIBUTABLE: {class_key(nodeid)} was red across runs with a "
                "DIFFERENT failing id each run — a changing identity is not novel "
                "and cannot be attributed to this PR"))
            continue

        if mr is None:
            decision.blocked.append(Verdict(
                nodeid, True,
                f"no main-side measurement (PR {pr.rate}) — NOT exempt"))
            continue

        if not _signatures_overlap(pr.signatures, sig_main.get(nodeid, frozenset())):
            decision.blocked.append(Verdict(
                nodeid, True,
                f"signature differs from main's ({pr.rate} vs {mr}) — same id, "
                "a DIFFERENT failure is not exempt"))
            continue

        if mr.runs < min_runs:
            # The NOTE is emitted alongside the block (review cycle 2): the reviewer's
            # required observation is `BLOCK, with the note`, and a per-id block that
            # left `notes` empty would report the refusal without the reason.
            decision.notes.append(
                f"insufficient evidence for {nodeid}: main {mr} rests on "
                f"{mr.runs} run(s) < min_runs={min_runs} — one observation cannot "
                "establish a rate"
            )
            decision.blocked.append(Verdict(
                nodeid, True,
                f"insufficient evidence (main {mr}, {mr.runs} run(s) < "
                f"min_runs={min_runs}) — one observation cannot establish a rate"))
            continue

        # THE PR-SIDE SAMPLE FLOOR (#5250). A PR gets ONE run per push, so its
        # rate is a single observation and `1/1` is `100%` BY CONSTRUCTION — the
        # comparison below then blocks unconditionally (`1.00 > 0.60 * 1.5`)
        # whenever main is red for a check the PR merely inherited, so the rail
        # was unusable exactly when it was most needed. `min_runs` is required on
        # BOTH sides: when the PR's sample is below it the RATE dimension is
        # NOT-MEASURABLE and is used NEITHER to exempt NOR to block. The
        # exemption that follows rests on the ATTRIBUTION evidence the gates
        # above already established (id measured red on main, overlapping
        # signatures, main's own row >= `min_runs`) and SAYS the rate was not
        # measurable — never a silent exemption.
        #
        # `k_pr is None` = the caller declared no PR sample size: in production
        # `_cmd_decide` always passes it, and it is `None` only when there are no
        # PR failures at all, so this preserves the historical rate comparison for
        # that caller. `mr.rate == 0` is not "measured red", so it falls through
        # to the rate comparison — which BLOCKS a PR failure main never had (the
        # zero-main-rate guard, bypass 1a) rather than exempting it.
        if k_pr is not None and k_pr < min_runs and mr.rate > 0:
            decision.exempt.append(Verdict(
                nodeid, False,
                f"PR rate NOT measurable ({k_pr} run(s) < min_runs={min_runs}) — "
                f"exempt on signature + main presence: main {mr} measured over "
                f"{mr.runs} run(s), k_pr={k_pr}"))
            continue

        # THE RATE COMPARISON — the heart of the fix. Compares the two RATES
        # (floats), never the two presences.
        #
        # No `mr.rate > 0` guard (review cycle 1, bypass 1a). Guarding on it SKIPPED
        # the comparison whenever main's rate was 0, so `main 0/8` vs `PR 8/8` — the
        # weakest possible main evidence — printed as "rates equivalent" and the
        # strongest exemption was bought with no evidence at all. A PR failure main
        # never had is a NEW failure, and `pr_rate > 0` against a zero main rate
        # blocks it.
        pr_rate = pr.rate.rate
        if pr_rate > mr.rate * rate_tolerance:
            decision.blocked.append(Verdict(
                nodeid, True,
                f"PR rate {pr.rate} materially higher than main {mr} "
                f"(>{rate_tolerance}x) — the PR made it worse"))
            continue

        decision.exempt.append(Verdict(
            nodeid, False,
            f"main {mr} vs PR {pr.rate} — rates equivalent, main measured over "
            f"{mr.runs} run(s) (min_runs={min_runs}), k_pr={k_pr}"))

    return decision


# ==========================================================================
# Step A (#3756) — the PR-side SIGNATURE producer
# ==========================================================================
#
# GROUNDED IN THE REAL ARTIFACT, not in an invented format. Measured on
# tortoise run 35223536174 (python-ci.yml, 2026-09-17) via
# ``gh run view <id> --log-failed``:
#
#   <job>\t<step>\t\ufeff2026-09-17T12:54:37.9171029Z ##[group]Run set +e
#   test (a)\tRun fast test suite\t2026-09-17T12:54:37.9171442Z ^[[36;1mset +e^[[0m
#   test (a)\tRun fast test suite\t2026-09-17T13:10:44.1728389Z ===== FAILURES =====
#   test (a)\tRun fast test suite\t2026-09-17T13:10:44.1728829Z ____ test_name ____
#   test (a)\tRun fast test suite\t2026-09-17T13:10:44.1735420Z E  +  where 200 = <Response [200 OK]>.status_code
#   test (a)\tRun fast test suite\t2026-09-17T13:10:44.1735758Z tests/test_oauth_token_fault.py:779: AssertionError
#   test (a)\tRun fast test suite\t2026-09-17T13:10:44.1763755Z FAILED tests/test_oauth_token_fault.py::test_capture... - assert (200 == 503)
#
# So the wire IS plain pytest text behind a GH Actions prefix. Two facts
# follow, and they are why this parser is shaped this way:
#
#   * the ``FAILED <nodeid> [- <detail>]`` short-summary line is the ONLY place
#     a nodeid appears in a failure record, and it already carries a one-line
#     assertion payload. It is also exactly the line ``extract_failed_tests``
#     consumes — so the id set cannot drift between the shell and this parser.
#   * the FULL failure text (the ``E`` lines and the
#     ``path.py:LINE: ExceptionType`` trailer) lives in the ``FAILURES`` block,
#     which is keyed by test NAME, not by nodeid. Attribution is therefore a
#     name join, and a name join can be ambiguous.
#
# Ambiguity is handled fail-closed: a block that joins to zero or to more than
# one id is REJECTED AND REPORTED (``unattributed``), and the id it would have
# described is left ``unsigned`` — which makes ``_signatures_overlap`` fail
# closed (BLOCK). It is never resolved by guessing.

# An ANSI SGR/CSI escape — the shell's own extractor strips these, so the
# producer must too or the two disagree on what a line says.
_ANSI_RE = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")

# ``<job>\t<step>\t\ufeff<ISO-8601>Z <content>`` — the gh ``--log-failed`` prefix.
# ``.*`` is greedy up to the LAST tab before the timestamp so a tab inside a job
# or step name cannot break the strip; a tab inside pytest CONTENT followed by a
# timestamp-shaped token would, which is vanishingly unlikely and fails closed
# (the content would not parse, so the id is unsigned).
_LOG_PREFIX_RE = re.compile(
    r"^.*\t\ufeff?\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z[ \t]"
)

# The short-summary line. Split on the FIRST `` - `` so a nodeid whose params
# contain a bare ``-`` (``[chromium-Claude Desktop]``) is not torn apart. The
# shell's ``-r`` short summary uses exactly this separator.
_SUMMARY_RE = re.compile(r"^(?:FAILED|ERROR)\s+(?P<nodeid>.+?)(?:\s+-\s+(?P<detail>.*))?$")

# A LOOSE nodeid: the file/class part stays strict, the ``::`` tail is allowed
# to carry spaces/brackets because pytest parameter ids legitimately do
# (``::test_x[chromium-Claude Desktop]``). ``_NODEID_RE`` stays narrow for the
# RATE/UNION parsers; widening it there would loosen their fail-closed check for
# no gain. Dropping a real id here would be fail-OPEN (an undecided id is an
# unblocked id), which is why this path is deliberately the permissive one.
_NODEID_LOOSE_RE = re.compile(r"^[A-Za-z0-9_./\-]+\.py::[^\t]+$")

# pytest's failure-block header: ``________ test_name[param] _________``.
_BLOCK_HEADER_RE = re.compile(r"^_{3,}\s*(?P<name>.+?)\s*_{3,}$")
# ``E       <assertion or exception>`` — the ``+  where …`` continuations are
# not the primary failure and are skipped.
_E_LINE_RE = re.compile(r"^E\s+(?P<rest>\S.*)$")
# ``path/to/test_x.py:779: AssertionError`` — the authoritative exception TYPE.
_TRAILER_RE = re.compile(
    r"^(?P<path>[^\s:][^\s]*\.py):(?P<line>\d+):\s*(?P<exc>[A-Za-z_][\w.]*)\s*$"
)
# A section boundary that ends the current failure block.
_BLOCK_END_RE = re.compile(r"^(?:={3,}|-{3,}|Captured\b).*$")

# Volatile substrate IDENTIFIERS, each one named by measured evidence. The mask
# list is deliberately CLOSED and documented: over-normalising is the fail-OPEN
# direction (two different failures collapsing into one signature would make a
# PR's signature set a subset of main's more easily), so nothing is masked that
# the evidence does not demand. Ids/addresses/tenants only — never data values.
_VOLATILE_NORMALIZERS: tuple[tuple[re.Pattern[str], str], ...] = (
    (re.compile(r"\b0x[0-9a-fA-F]+\b"), "<ADDR>"),
    (
        re.compile(
            r"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}"
            r"-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b"
        ),
        "<UUID>",
    ),
    # The declared class's ``_drill_..._416bf7c5``: an 8+ hex suffix is a
    # per-run subsystem id. ``(?<![0-9a-fA-F])`` (not ``\b``) so the underscore
    # boundary in ``_416bf7c5`` still matches, while ``assert 3 == 2`` (single
    # digits) is untouched.
    (re.compile(r"(?<![0-9a-zA-Z])[0-9a-f]{8,}(?![0-9a-zA-Z])"), "<HEX>"),
    # ``team-graph enumeration failed for team_x`` — the tenant name is the
    # declared interpolation; the stable part is its shape.
    (re.compile(r"\bteam_[A-Za-z0-9][A-Za-z0-9_]{0,63}\b"), "team_<X>"),
    (re.compile(r"\b(?:127\.0\.0\.1|localhost|0\.0\.0\.0):\d{2,5}\b"), "<HOSTPORT>"),
)


@dataclass
class SignatureParse:
    """Signature extraction for one raw ``gh run view --log-failed`` capture.

    ``unsigned`` and ``unattributed`` are EVIDENCE, not diagnostics: they are the
    rejections that make an exemption unavailable, and the swap must be able to
    see the count rather than take a silently-trimmed signature set on trust.
    """

    ids: list[str] = field(default_factory=list)
    signatures: dict[str, frozenset[str]] = field(default_factory=dict)
    rejected: list[str] = field(default_factory=list)
    unsigned: list[str] = field(default_factory=list)
    unattributed: list[str] = field(default_factory=list)
    #: The guard-step ids that entered ``ids`` (#4469) — REPORTED, never silent.
    guard_steps: list[str] = field(default_factory=list)

    @property
    def ok(self) -> bool:
        """False when no usable failure id was found — a capture that proves nothing."""
        return bool(self.ids)


def _strip_log_prefix(line: str) -> str:
    """Remove the gh ``--log-failed`` ``<job>\\t<step>\\t<ts>Z `` prefix, if present."""
    return _LOG_PREFIX_RE.sub("", line, count=1)


def normalize_signature(text: str | None) -> str:
    """Reduce raw failure text to the STABLE part, or ``''`` if nothing survives.

    Whitespace is collapsed first (the same assertion is rendered at different
    prefix widths between runs), then the closed volatile-identifier list above
    is masked. A result of ``''`` is a REJECTION — callers must never store it as
    a signature, because an empty signature makes the subset rule vacuous.
    """
    if not text:
        return ""
    out = " ".join(str(text).split())
    for pattern, replacement in _VOLATILE_NORMALIZERS:
        out = pattern.sub(replacement, out)
    return out.strip()


def _signature_from(e_line: str | None, exc: str | None) -> str:
    """``<ExceptionType>: <assertion>`` — the exception type is always present.

    The type is taken from pytest's ``path.py:LINE: ExceptionType`` trailer and
    prefixed only when the primary ``E`` line does not already name it, so a
    message that repeats the class (``AssertionError: family row drifted``) is
    not doubled.
    """
    core = normalize_signature(e_line)
    exc_n = normalize_signature(exc)
    if not core:
        return exc_n
    if exc_n and not core.startswith(exc_n):
        return f"{exc_n}: {core}"
    return core


# ==========================================================================
# HALF 1b (#4469) — GUARD-STEP ATTRIBUTION
# ==========================================================================
#
# THE DEFECT. The id universe was pytest nodeids ONLY, so a failing run whose
# failure lived in a non-pytest GUARD STEP (an orphan-count assert, a packaging
# guard, a health gate) yielded NO id. The rail then could not certify it:
# `examined=1 extracted=0` tripped the fail-closed refusal in admin-merge.sh
# ("yielded NO parseable 'FAILED <nodeid>' line … This is a refusal") and a green,
# review-clean PR became unmergeable through the sanctioned path — even though
# the failure was a real, attributable, and often FLAKY guard owned by another
# lane. A genuinely new guard-step regression could never be CERTIFIED as new,
# only refused.
#
# GROUNDED IN THE REAL CAPTURE, not an invented format. tortoise PR #4672, run
# 35785085760 (python-ci.yml, 2026-09-23), `gh run view --log-failed`:
#
#   test (b)\tAssert no redislite orphans (issue\t<ts>Z orphaned redislite servers after suite: 16 (pytest rc: 0, threshold: 12)
#   test (b)\tAssert no redislite orphans (issue\t<ts>Z ##[error]redislite server leak: 16 orphans after suite, threshold 12 (issue #1005 / epic #1647 E2E-7)
#   test (b)\tAssert no redislite orphans (issue\t<ts>Z ##[error]Process completed with exit code 1.
#   python-ci-gate\tAggregate matrix result\t<ts>Z ##[error]Process completed with exit code 1.
#
# Four facts from that capture shape this parser, and each is load-bearing:
#
#   * `pytest` exited rc 0; the failure is the POST-SUITE guard, not a test.
#   * ANNOTATIONS ARE ANCHORED. The log also ECHOES the script source
#     (line 40 of the capture: `echo "::error::redislite server leak: $COUNT …"`),
#     so a mid-line search would manufacture a second, `$COUNT`-bearing identity
#     for the SAME run and put a phantom failure in the set.
#   * THE RUNNER'S OWN EXIT ANNOTATION IS NOT AN IDENTITY. `##[error]Process
#     completed with exit code <N>.` is emitted for EVERY failing step — the
#     pytest step included, and the aggregate gate step too. Attributing it
#     would convert a genuinely unparseable run (log format moved; pytest rc≠0
#     with no FAILED line) into a "guard-step" id, i.e. exactly the fail-closed
#     refusal this change must PRESERVE. It is excluded, and a step carrying
#     ONLY it stays unattributable.
#   * THE IDENTITY IS (STEP, ERROR SHAPE) AND IS WHITESPACE-FREE. The main RATE
#     table is built with `uniq -c | awk` and is whitespace-delimited (the count
#     is field 1, the id field 2), so a key containing a space is mangled there;
#     and the comparison needs the same identity on both trees despite an orphan
#     COUNT that changes every run. So the step is slugged into the key and the
#     error SHAPE rides the key tail AND the signature column the decision
#     already carries.

#: The one prefix no pytest nodeid can produce, so a guard key cannot collide
#: with a test id.
_GUARD_KEY_PREFIX = "guard-step::"

#: The runner's OWN annotations for a failing step, emitted for EVERY failing
#: step. They name no failure, so they are never an identity (see above).
#: The RUNNER's and its container-hook's own WRAPPERS around a failed step — the
#: generic messages the harness emits for a step that failed, not the step's own
#: logic. They are emitted for EVERY failing step, so they name no failure: they
#: are NEVER an identity, and (where they carry an exit code) they are the positive
#: signal for "the runner marked this step failed". A closed, documented list
#: because each entry is a measured harness string — the runner's
#: `ScriptHandler.cs` form and the container hooks' `core.error` wrappers. A form
#: MISSING from this list costs BOTH roles at once (the step is not marked failed,
#: and its wrapper can become a phantom identity), so every form is pinned by a
#: test: `test_no_runner_or_hook_wrapper_is_ever_an_identity`.
_RUNNER_GENERIC_ANNOTATIONS = (
    re.compile(r"^Process completed with exit code '?-?\d+'?\.?$"),
    re.compile(r"^The process .+ failed with exit code '?-?\d+'?\.?$"),
    re.compile(r"^Bash exited with code '?-?\d+'?\.?$"),
    re.compile(r"^Docker failed with exit code '?-?\d+'?\.?$"),
    re.compile(r"^Failed to run container step:?\b.*$"),
    re.compile(r"^Failed to initialize containers,?\b.*$"),
    re.compile(r"^The action .+ has timed out after .+$"),
)

#: A GitHub Actions error annotation, ANCHORED at the start of the line content.
#: `gh run view` renders it as `##[error]<message>`; the workflow-command form is
#: `::error[ props]::<message>`. The anchor is what keeps the echoed script
#: source (`echo "::error::…"`) out of the id set.
_ANNOTATION_RE = re.compile(r"^(?:##\[error\]|::error(?: [^:]*)?::)(?P<msg>.*)$")

#: The `<job>\t<step>\t\ufeff<ISO>Z ` head, used to recover the STEP. Split on
#: tabs (never a greedy `.*`) so the step is the real second column, and require
#: the timestamp head so a content line that merely contains tabs is not mistaken
#: for a prefix.
_TS_HEAD_RE = re.compile(
    r"^\ufeff?\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z[ \t]"
)

#: The CLI's whitespace-free guard key — see the section header for WHY one token
#: is mandatory. The charset is exactly what :func:`_slug` emits.
_GUARD_KEY_RE = re.compile(r"^guard-step::[A-Za-z0-9_.\-]+::[A-Za-z0-9_.\-]+$")

#: An integer RUN — the run-varying quantity in a guard message (an orphan COUNT,
#: a measured value). Masked in the identity so the same guard on main and on the
#: PR compares despite a different number, exactly as a test signature masks a
#: per-run id. THE TRADE IS DECLARED: guard failures differing ONLY numerically
#: collapse into one identity, and the rate comparison (plus the per-id
#: `min_runs` floor) is the backstop that still has to hold for an exemption.
_GUARD_INT_RE = re.compile(r"\b\d+\b")


def is_failure_key(key: str) -> bool:
    """Is ``key`` in the universe the RATE table accepts (#4469)?

    A pytest nodeid AND a guard-step identity are both failure keys; the same
    predicate must gate :func:`parse_rates`, or main's rate row is dropped and
    every guard failure reads as PR-unique forever.
    """
    return bool(_NODEID_RE.match(key) or _GUARD_KEY_RE.match(key))


def is_failure_key_loose(key: str) -> bool:
    """The LOOSE (parameter-space-permitting) form of :func:`is_failure_key`."""
    return bool(_NODEID_LOOSE_RE.match(key) or _GUARD_KEY_RE.match(key))


def _split_log_line(line: str) -> tuple[str, str, str]:
    """``(job, step, content)`` from a gh ``--log-failed`` line.

    Returns ``('', '', line)`` when the line carries no ``<job>\t<step>\t<ts>Z ``
    head — the caller then has no step and must not invent one. The guard pass
    SKIPS such a line entirely (``guard_step_failures``), so a stripped capture
    cannot manufacture a step nor an attribution.

    A tab INSIDE the job or step name defeats the field split, so the same greedy
    prefix the nodeid pass uses (:data:`_LOG_PREFIX_RE`) is the fallback — the two
    passes must not disagree about one capture.
    """
    parts = line.split("\t", 2)
    if len(parts) == 3:
        head = _TS_HEAD_RE.match(parts[2])
        if head:
            return parts[0], parts[1], parts[2][head.end():]
    m = _LOG_PREFIX_RE.match(line)
    if m:
        fields = m.group(0).split("\t")
        if len(fields) >= 3:
            return fields[0], "\t".join(fields[1:-1]), line[m.end():]
    return "", "", line


def _slug(text: str) -> str:
    """A whitespace-free token for a guard key; never empty."""
    slug = re.sub(r"[^A-Za-z0-9_.\-]+", "-", text).strip("-")
    return slug or "unknown"


def normalize_guard_error(message: str) -> str:
    """The STABLE shape of a guard-step error message, or ``''``.

    Whitespace is collapsed and the SAME closed volatile-identifier list as
    :func:`normalize_signature` is applied, then integer runs are masked too (see
    ``_GUARD_INT_RE`` for the declared trade).
    """
    shape = normalize_signature(message)
    if not shape:
        return ""
    return _GUARD_INT_RE.sub("<N>", shape)


def guard_step_key(step: str, error_shape: str) -> str:
    """``guard-step::<step>::<error shape>`` — one whitespace-free identity."""
    return f"{_GUARD_KEY_PREFIX}{_slug(step)}::{_slug(error_shape)}"


def _attributable_annotation(content: str) -> str:
    """The guard failure message on ``content``, or ``''`` when there is none.

    The runner's generic exit annotations are deliberately NOT attribution — see
    the section header. A step carrying only them stays unattributable, which is
    what keeps the rail's refusal for a genuinely unparseable run.
    """
    m = _ANNOTATION_RE.match(content)
    if not m:
        return ""
    message = " ".join(m.group("msg").split())
    if not message:
        return ""
    if any(generic.match(message) for generic in _RUNNER_GENERIC_ANNOTATIONS):
        return ""
    return message


def _runner_step_failure(content: str) -> int | None:
    """The exit code in the runner's OWN step-failure annotation, else ``None``.

    gh renders ``##[error]Process completed with exit code <N>.`` as the LAST
    annotation of every step whose command failed. It names no failure — so it is
    never an identity — but it is the ONLY signal a ``--log-failed`` capture
    carries for *this step failed the run*, independent of what the step printed.
    """
    m = _ANNOTATION_RE.match(content)
    if not m:
        return None
    message = " ".join(m.group("msg").split())
    if not any(generic.match(message) for generic in _RUNNER_GENERIC_ANNOTATIONS):
        return None
    tail = re.search(r"(-?\d+)'?\.?$", message)
    return int(tail.group(1)) if tail else None


def guard_step_failures(text: str) -> tuple[list[str], dict[str, frozenset[str]]]:
    """``(keys, {key: signatures})`` for the guard-step failures in a capture.

    THREE conditions, ALL required — and it is their conjunction that keeps the
    rail's cycle-3 refusal intact while making a guard failure comparable:

    1. **A guard identity comes only from a step the RUNNER marked failed** — one
       that emitted its own non-zero ``Process completed with exit code <N>.``. An
       annotation printed by a step that did NOT fail the run says nothing about a
       failure, and ``_slug('')`` must never let a head-less line found one.
    2. **The run's ROOT failing step must itself yield an identity.** The root is
       the FIRST step the runner marked failed, keyed by **(job, step)** — a
       matrix leg runs steps with the SAME NAME as its siblings, so a step NAME
       alone would let leg ``b``'s annotation stand in for leg ``a``'s
       unparseable failure. The root is attributed only when its own lines carry a
       ``FAILED``/``ERROR`` nodeid or a substantive annotation. If it does not,
       the run contributes NO guard identity AT ALL — even when a LATER step
       carries a perfectly good annotation. This is what refuses the mixed run (an
       unparseable pytest failure PLUS a sibling guard annotation) that the
       refusal exists for; see the HALF 1b header.
    3. **A step that shows pytest failure output must yield a NODEID.** An
       ``E   <exception>`` line is pytest's own report of a failure, so a step
       carrying one has a pytest failure the parser did not classify. An
       ANNOTATION from that step is NOT that classification (it is a wrapper, at
       best), so the run is refused — the cycle-3 ``ImportError: no module named
       y`` case, which prints ``E   ImportError`` and no ``FAILED`` line.
       This clause is STEP-scoped: it refuses when the whole step yielded no
       nodeid. A pytest run that prints BOTH a classified nodeid and an
       unclassified block in one step (``--continue-on-collection-errors``) is a
       PRE-EXISTING gap in the per-run refusal — ``main``'s parser returns the
       same single nodeid — so it is filed (agent-infra #1372), not claimed here.

    A line with no ``<job>\t<step>\t<ts>Z `` head has NO step, so it can neither
    found the failing-step set nor be attributed: the step is never invented.

    DECLARED RESIDUAL (agent-infra #1366): clauses 2 and 3 are the strongest
    guarantee a ``--log-failed`` capture ALONE can give. What survives is an
    unparseable failure that leaves NO pytest-shaped line AND whose step is not
    the root — e.g. a guard root attributed first, then a non-pytest step failing
    with bare prose. A source line that ITSELF starts with the annotation marker
    (an echoed heredoc, not the ``echo "::error::…"`` form) is likewise
    indistinguishable from a real annotation. Both need data the capture does not
    carry; the measured capture places the guard before its aggregate gate, carries
    no ``E   `` line and no line-start marker, so the guard IS the root and IS
    attributed.
    """
    failing: list[tuple[str, str]] = []   # (job, step) pairs the runner failed
    evidence: set[tuple[str, str]] = set()  # pairs that yielded an identity
    nodeid_steps: set[tuple[str, str]] = set()  # pairs that yielded a NODEID
    e_line_steps: set[tuple[str, str]] = set()  # pairs showing pytest output
    candidates: list[tuple[tuple[str, str], str, str]] = []  # (unit, step, msg)
    for raw in text.splitlines():
        job, step, content = _split_log_line(_ANSI_RE.sub("", raw))
        if not step:
            continue
        # The unit is the RAW pair, not a slug of it: `_slug` is lossy, so
        # slugging both fields would let two DIFFERENT (job, step) pairs collapse
        # (`test (py 3.12)`/`test (py-3.12)`, `Run-tests`/`Run tests`) and one
        # leg's evidence attest another leg's unparseable failure. The slug is only
        # ever the WIRE key's step component.
        unit = (job, step)
        payload = content.strip()
        code = _runner_step_failure(payload)
        if code is not None:
            if code != 0 and unit not in failing:
                failing.append(unit)
            continue
        if _E_LINE_RE.match(payload):
            e_line_steps.add(unit)
        message = _attributable_annotation(payload)
        if message:
            candidates.append((unit, step, message))
            evidence.add(unit)
            continue
        candidate = _failed_candidate(payload)
        if candidate is not None and _NODEID_LOOSE_RE.match(candidate):
            evidence.add(unit)
            nodeid_steps.add(unit)

    if not failing or failing[0] not in evidence:
        # No step the runner failed, or the ROOT failing step carries nothing we
        # can attribute: the run is NOT attributed (fail-closed). An annotation
        # from a later step is NOT allowed to stand in for it.
        return [], {}
    if e_line_steps - nodeid_steps:
        # A step reported a pytest failure that produced no nodeid, so the run
        # carries an UNCLASSIFIED failure. An annotation elsewhere in the run — or
        # in that very step — does not classify it.
        return [], {}

    keys: list[str] = []
    signatures: dict[str, set[str]] = {}
    failing_set = set(failing)
    for unit, step, message in candidates:
        if unit not in failing_set:
            # Clause 1: printed by a step the runner did NOT fail — a same-NAMED
            # step in another leg is a different unit.
            continue
        shape = normalize_guard_error(message)
        if not shape:
            continue  # defensive: a future normalizer may void a message
        key = guard_step_key(step, shape)
        keys.append(key)
        signatures.setdefault(key, set()).add(shape)
    return sorted(set(keys)), {k: frozenset(v) for k, v in signatures.items()}


def parse_pr_failure_text(text: str) -> SignatureParse:
    """Extract ``{id: signature}`` from a raw ``--log-failed`` capture.

    Three passes over the same normalized lines:

    1. the ``FAILED <nodeid> [- <detail>]`` short-summary lines — the
       authoritative id set, the same lines ``extract_failed_tests`` reads;
    2. the ``FAILURES`` blocks — keyed by test NAME, joined to ids by the
       nodeid's final ``::`` segment.

    Per id the block-derived signature is preferred (it is the only source that
    carries the exception TYPE); the summary's inline detail is used ONLY when no
    block joined, so one id never contributes two competing forms. An id with
    neither is ``unsigned`` and produces NO signature entry — never a blank one.
    """
    lines = [_strip_log_prefix(_ANSI_RE.sub("", raw)) for raw in text.splitlines()]

    id_list: list[str] = []
    details: dict[str, set[str]] = {}
    rejected: list[str] = []
    for line in lines:
        stripped = line.strip()
        if not stripped:
            continue
        m = _SUMMARY_RE.match(stripped)
        if not m:
            continue
        nodeid = m.group("nodeid").strip()
        if not _NODEID_LOOSE_RE.match(nodeid):
            rejected.append(stripped)
            continue
        id_list.append(nodeid)
        detail = normalize_signature(m.group("detail"))
        if detail:
            details.setdefault(nodeid, set()).add(detail)

    # Pass 2 — FAILURES blocks. A block whose name is carried by exactly one id
    # is attributed; zero or several candidates is a rejection, never a guess.
    block_sigs: dict[str, set[str]] = {}
    cur_name: str | None = None
    cur_e: str | None = None
    cur_exc: str | None = None

    def _flush() -> None:
        nonlocal cur_name, cur_e, cur_exc
        if cur_name is not None:
            sig = _signature_from(cur_e, cur_exc)
            if sig:
                block_sigs.setdefault(cur_name, set()).add(sig)
        cur_name, cur_e, cur_exc = None, None, None

    for line in lines:
        stripped = line.strip()
        header = _BLOCK_HEADER_RE.match(stripped)
        if header:
            _flush()
            cur_name = header.group("name").strip()
            continue
        if cur_name is None:
            continue
        if _BLOCK_END_RE.match(stripped):
            _flush()
            continue
        trailer = _TRAILER_RE.match(stripped)
        if trailer:
            cur_exc = trailer.group("exc")
            continue
        e_line = _E_LINE_RE.match(line)
        if e_line and cur_e is None:
            rest = e_line.group("rest").strip()
            if not rest.startswith("+"):
                cur_e = rest
    _flush()

    by_name: dict[str, list[str]] = {}
    for nodeid in sorted(set(id_list)):
        by_name.setdefault(nodeid.split("::")[-1], []).append(nodeid)

    signatures: dict[str, frozenset[str]] = {}
    unsigned: list[str] = []
    unattributed: list[str] = []
    attributed: set[str] = set()
    for name in sorted(block_sigs):
        candidates = by_name.get(name, [])
        if len(candidates) == 1:
            attributed.add(candidates[0])
            continue
        unattributed.append(name)
    for nodeid in sorted(set(id_list)):
        if nodeid in attributed:
            signatures[nodeid] = frozenset(block_sigs[nodeid.split("::")[-1]])
        elif nodeid in details:
            signatures[nodeid] = frozenset(details[nodeid])
        else:
            unsigned.append(nodeid)

    # Pass 3 — GUARD-STEP failures (#4469). Their ids and signatures come from the
    # SAME helper the `ids` CLI uses, so the two doors cannot disagree about the
    # guard universe. Merged AFTER the nodeid attribution so a guard key can
    # never be pulled into the `by_name` join above.
    guard_keys, guard_signatures = guard_step_failures(text)
    for key, sigs in guard_signatures.items():
        signatures[key] = frozenset(sigs)
    id_list.extend(guard_keys)

    return SignatureParse(
        ids=sorted(set(id_list)),
        signatures=signatures,
        rejected=rejected,
        unsigned=unsigned,
        unattributed=unattributed,
        guard_steps=guard_keys,
    )


# ==========================================================================
# Step B (#3756) — the wire formats and the ``decide`` CLI
# ==========================================================================
#
# ``<nodeid>\t<failures>\t<runs>\t<signature>`` — the PR-set row. One row per
# (id, signature): an id that failed with two different signatures across runs
# contributes two rows and their signatures union. This is the SAME shape as
# ``--main-union-rates`` plus one column, so either side's producer can feed it.
_ROW_RE = re.compile(
    r"^(?P<nodeid>[^\t]+)\t(?P<failures>[0-9]+)\t(?P<runs>[0-9]+)\t(?P<sig>.*)$"
)
# ``<nodeid>\t<signature>`` — the main-side signature table. Kept separate from
# the 3-column rate table because ``parse_rates`` REJECTS a 4th column (a
# self-contradicting table is not evidence); main's rates and main's signatures
# are therefore two files.
_SIG_ROW_RE = re.compile(r"^(?P<nodeid>[^\t]+)\t(?P<sig>.*)$")


@dataclass
class FailureRowsResult:
    """The PR failure set, parsed from its wire rows."""

    failures: dict[str, Failure] = field(default_factory=dict)
    rejected: list[str] = field(default_factory=list)
    unsigned: list[str] = field(default_factory=list)

    @property
    def ok(self) -> bool:
        return bool(self.failures)


def parse_failure_rows(text: str) -> FailureRowsResult:
    """Parse ``<nodeid>\\t<failures>\\t<runs>\\t<signature>`` rows.

    Fail-closed at every corner:

    * a malformed row (bad id, non-numeric fields, ``runs <= 0``,
      ``failures > runs``) is rejected and contributes NOTHING;
    * a BLANK signature is DROPPED, COUNTED and the id listed in ``unsigned`` —
      the row's rate survives, and the id then has no signature, so
      ``_signatures_overlap`` fails closed. It is never stored as ``''``;
    * two rows for one id that agree on the rate union their signatures; two
      rows that CONTRADICT each other set the id's rate to ``0/0``. That rate is
      unmeasurable, so :func:`decide` BLOCKS it (``PR rate is unmeasurable``).
      Rejecting such a row without leaving the id behind would let the id vanish
      from ``pr_failures`` — and an id the decision never sees is an id the gate
      never blocks, which is the fail-OPEN direction.
    """
    failures: dict[str, Failure] = {}
    rejected: list[str] = []
    unsigned: set[str] = set()
    for raw in text.splitlines():
        line = raw.strip("\n")
        if not line.strip():
            continue
        m = _ROW_RE.match(line)
        if not m:
            rejected.append(line)
            continue
        nodeid = m.group("nodeid")
        failures_n = int(m.group("failures"))
        runs_n = int(m.group("runs"))
        if (
            not is_failure_key_loose(nodeid)
            or runs_n <= 0
            or failures_n > runs_n
        ):
            rejected.append(line)
            continue
        sig = normalize_signature(m.group("sig"))
        if not sig:
            unsigned.add(nodeid)
        existing = failures.get(nodeid)
        if existing is None:
            failures[nodeid] = Failure(
                rate=Rate(failures_n, runs_n),
                signatures=frozenset({sig}) if sig else frozenset(),
            )
            continue
        if existing.rate != Rate(failures_n, runs_n):
            # Contradictory evidence: keep the id (so it cannot vanish) but make
            # its rate unmeasurable, which is the existing BLOCK path.
            failures[nodeid] = Failure(rate=Rate(0, 0), signatures=frozenset())
            rejected.append(line)
            continue
        failures[nodeid] = Failure(
            rate=existing.rate,
            signatures=existing.signatures | (frozenset({sig}) if sig else frozenset()),
        )
    return FailureRowsResult(
        failures=failures, rejected=rejected, unsigned=sorted(unsigned)
    )


def parse_signature_rows(text: str) -> dict[str, frozenset[str]]:
    """Parse ``<nodeid>\\t<signature>`` rows, dropping blanks (counted by caller)."""
    out: dict[str, set[str]] = {}
    for raw in text.splitlines():
        line = raw.strip("\n")
        if not line.strip():
            continue
        m = _SIG_ROW_RE.match(line)
        if not m:
            continue
        nodeid = m.group("nodeid")
        sig = normalize_signature(m.group("sig"))
        if not sig or not is_failure_key_loose(nodeid):
            continue
        out.setdefault(nodeid, set()).add(sig)
    return {k: frozenset(v) for k, v in out.items()}


def parse_rotation_runs(text: str) -> list[frozenset[str]]:
    """Per-run id sets, one run per non-blank line, ids whitespace-separated."""
    runs: list[frozenset[str]] = []
    for raw in text.splitlines():
        if not raw.strip():
            continue
        runs.append(frozenset(raw.split()))
    return runs


def render_signature_table(signatures: dict[str, frozenset[str]]) -> str:
    """``<nodeid>\\t<signature>`` rows, sorted — the producer's stdout."""
    return "".join(
        f"{nodeid}\t{sig}\n"
        for nodeid in sorted(signatures)
        for sig in sorted(signatures[nodeid])
    )


def _read(path: str) -> str:
    return Path(path).read_text(encoding="utf-8", errors="replace")


def _cmd_ids(args: argparse.Namespace) -> int:
    """`ids --log <capture>` — the canonical FAILED-id extraction (the shell's door).

    stdout: the failure ids — pytest nodeids AND attributable guard-step
    identities (#4469) — sorted and unique, one per line (possibly empty).
    stderr: every rejected candidate, tagged UNATTRIBUTABLE, plus counts.

    Exits 0 whenever the capture was READ — an empty id set is a legitimate
    answer (the caller's `examined > extracted` gate owns "a failing run that
    yielded nothing"). A non-zero exit therefore means exactly one thing: the
    input could not be read. Reading that as "no failures" is the vacuous pass.
    """
    parsed = parse_failed_ids(_read(args.log), raw_log=True)
    for nodeid in parsed.ids:
        print(nodeid)
    for token in parsed.rejected:
        print(
            "ci-exemption: UNATTRIBUTABLE: FAILED token is not a test id and was "
            f"DROPPED (never in the failure set): {token}",
            file=sys.stderr,
        )
    print(
        f"ci-exemption: ids={len(parsed.ids)} "
        f"unattributable={len(parsed.rejected)} "
        f"guard-steps={len(parsed.guard_steps)}",
        file=sys.stderr,
    )
    for key in parsed.guard_steps:
        print(
            f"ci-exemption: guard-step failure ATTRIBUTED (no test nodeid): {key}",
            file=sys.stderr,
        )
    return 0


def _cmd_signatures(args: argparse.Namespace) -> int:
    parsed = parse_pr_failure_text(_read(args.log))
    sys.stdout.write(render_signature_table(parsed.signatures))
    for line in parsed.rejected:
        print(f"ci-exemption: rejected FAILED line: {line}", file=sys.stderr)
    for name in parsed.unattributed:
        print(
            f"ci-exemption: unattributed FAILURES block: {name} (no unique id "
            "match — its id is unsigned and will BLOCK)",
            file=sys.stderr,
        )
    for nodeid in parsed.unsigned:
        print(
            f"ci-exemption: unsigned failure (no stable signature): {nodeid} — "
            "the subset rule will fail closed and BLOCK it",
            file=sys.stderr,
        )
    print(
        f"ci-exemption: ids={len(parsed.ids)} signed={len(parsed.signatures)} "
        f"unsigned={len(parsed.unsigned)} rejected={len(parsed.rejected)} "
        f"unattributed={len(parsed.unattributed)} "
        f"guard-steps={len(parsed.guard_steps)}",
        file=sys.stderr,
    )
    return 0 if parsed.ok else 1


def _cmd_decide(args: argparse.Namespace) -> int:
    pr = parse_failure_rows(_read(args.pr_failures))
    main = parse_rates(_read(args.main_rates))
    main_sigs = (
        parse_signature_rows(_read(args.main_signatures))
        if args.main_signatures
        else {}
    )
    rotating = (
        detect_rotating_identity(parse_rotation_runs(_read(args.rotation)))
        if args.rotation
        else {}
    )

    decision = decide(
        pr.failures,
        main.rates,
        main_signatures=main_sigs,
        rotating=rotating,
        k_pr=max((f.rate.runs for f in pr.failures.values()), default=None),
        rate_tolerance=args.rate_tolerance,
        min_runs=args.min_runs,
    )

    lines = [v.line for v in decision.blocked]
    lines += [v.line for v in decision.unattributable]
    lines += decision.visible_exemptions()
    notes = list(decision.notes)
    if not args.main_signatures and any(f.signatures for f in pr.failures.values()):
        notes.append(
            "no --main-signatures supplied: every signature check fails CLOSED "
            "(BLOCK) — this is the safe-but-wrong state, not a green"
        )
    lines += [f"NOTE  : {n}" for n in notes]

    printed = list(lines)
    for line in pr.rejected:
        printed.append(f"NOTE  : rejected PR row: {line}")
    for nodeid in pr.unsigned:
        printed.append(f"NOTE  : unsigned PR failure (no signature): {nodeid}")
    for line in main.rejected:
        printed.append(f"NOTE  : rejected main rate row: {line}")
    sys.stdout.write("\n".join(printed) + ("\n" if printed else ""))

    gated = len(decision.blocked) + len(decision.unattributable)
    verdict = (
        f"VERDICT\t{'BLOCK' if gated else 'CLEAN'}"
        f"\tblocked={len(decision.blocked)}"
        f"\tunattributable={len(decision.unattributable)}"
        f"\texempt={len(decision.exempt)}"
        f"\trejected={len(pr.rejected) + len(main.rejected)}"
        f"\tunsigned={len(pr.unsigned)}"
    )
    print(verdict)

    if args.blocked_out:
        Path(args.blocked_out).write_text(
            "".join(f"{v.nodeid}\n" for v in decision.blocked), encoding="utf-8"
        )
    if args.unattributable_out:
        Path(args.unattributable_out).write_text(
            "".join(f"{v.nodeid}\n" for v in decision.unattributable),
            encoding="utf-8",
        )
    if args.exempt_out:
        Path(args.exempt_out).write_text(
            "".join(f"{line}\n" for line in decision.visible_exemptions()),
            encoding="utf-8",
        )
    if args.verdict_out:
        Path(args.verdict_out).write_text(verdict + "\n", encoding="utf-8")

    return 1 if gated else 0


def main(argv: list[str] | None = None) -> int:
    """``python3 ci_exemption.py <ids|signatures|decide> …`` — the shell's door."""
    parser = argparse.ArgumentParser(
        prog="python3 ci_exemption.py",
        description=(
            "The #3756 rail module: THE canonical FAILED-id parser (the id universe "
            "the rail and the exemption decision both read) plus the pre-merge "
            "exemption decision and its signature producer."
        ),
    )
    sub = parser.add_subparsers(dest="command", required=True)

    sig = sub.add_parser(
        "signatures",
        help="extract stable signatures from a raw `gh run view --log-failed` capture "
        "(pytest nodeids AND guard-step annotations, #4469)",
    )
    sig.add_argument("--log", required=True, help="raw --log-failed file")
    sig.set_defaults(func=_cmd_signatures)

    ids = sub.add_parser(
        "ids",
        help="THE canonical FAILED-id extraction from a raw `gh run view --log-failed` "
        "capture — pytest nodeids plus attributable guard-step failures (#4469)",
    )
    ids.add_argument("--log", required=True, help="raw --log-failed file")
    ids.set_defaults(func=_cmd_ids)

    dec = sub.add_parser("decide", help="run the exemption decision over files")
    dec.add_argument(
        "--pr-failures",
        required=True,
        help="PR set, `<nodeid>\\t<failures>\\t<runs>\\t<signature>` rows",
    )
    dec.add_argument(
        "--main-rates",
        required=True,
        help="main rate table, `<nodeid>\\t<failures>\\t<runs>` rows",
    )
    dec.add_argument(
        "--main-signatures",
        help="main signature table, `<nodeid>\\t<signature>` rows (absent => fail closed)",
    )
    dec.add_argument(
        "--rotation",
        help="per-run id sets, one run per line (feeds detect_rotating_identity)",
    )
    dec.add_argument("--rate-tolerance", type=float, default=1.5)
    dec.add_argument("--min-runs", type=int, default=3)
    dec.add_argument("--blocked-out", help="write blocked nodeids, one per line")
    dec.add_argument("--unattributable-out", help="write unattributable nodeids")
    dec.add_argument("--exempt-out", help="write the visible EXEMPT lines")
    dec.add_argument("--verdict-out", help="write the machine-readable verdict line")
    dec.set_defaults(func=_cmd_decide)

    args = parser.parse_args(argv)
    return int(args.func(args))


if __name__ == "__main__":  # pragma: no cover — exercised via main() in tests
    raise SystemExit(main())
