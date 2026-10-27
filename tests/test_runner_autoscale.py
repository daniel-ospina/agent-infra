"""Hermetic tests for scripts/orchestrator-harness/runner_autoscale.py.

No network, no real `gh`, no systemd, no sudo, no root: every external surface is a fixture
(`gh` fake, `systemctl` fake, `config.sh` fake, a meminfo-shaped file, a temp runner root).
The acceptance set is the five shapes the task names, plus the two source MUTATIONS that must
redden them:

  (a) label floor:  an empty-of-`ubuntu-latest` pool + a re-registration ⇒ the written label set
                    INCLUDES `ubuntu-latest`, and the log line says why.
  (b) handover:     fallback engaged ⇒ unchanged behaviour (exactly one `ubuntu-latest`, no
                    double-add, no floor line).
  (c) unread pool:  after a restart the pool read is retried (bounded) before `Unmeasurable`, and
                    the message CONTAINS the gh error text.
  (d) starvation:   `queued>0 ∧ busy==0 ∧ ≥1 online` ⇒ non-zero exit + the invariant named; the
                    three near-misses (`queued>0∧busy>0`, `queued==0`, all-offline) must NOT fire.
  (e) mutations:    removing the floor reddens (a); removing the retry reddens (c).
  (f) repair path:  `--replace` clears the local `.runner`/`.credentials` first, so a `config.sh`
                    that refuses with the exact "already configured" refusal succeeds.

The module under test is loaded BY PATH — the same file `scripts/orchestrator-harness/` would
ship, never a copy.
"""

from __future__ import annotations

import importlib.util
import json
import os
import stat
import subprocess
import textwrap
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
TOOL = REPO_ROOT / "scripts" / "orchestrator-harness" / "runner_autoscale.py"
REPO = "daniel-ospina/tortoise"

_spec = importlib.util.spec_from_file_location("runner_autoscale_canonical", TOOL)
if _spec is None or _spec.loader is None:  # pragma: no cover - environment failure
    raise ImportError(f"canonical runner_autoscale module is ABSENT at {TOOL}")
ra = importlib.util.module_from_spec(_spec)
import sys as _sys

_sys.modules[_spec.name] = ra
_spec.loader.exec_module(ra)


# ── fakes ─────────────────────────────────────────────────────────────────────────────────────
GH_FAKE = textwrap.dedent("""\
    #!/usr/bin/env bash
    # Fake `gh`. Routes: `-X POST` -> token; `runs?status=queued` -> $QUEUED_COUNT; `runners` -> $POOL_TSV.
    # POOL_FAIL_AFTER=N: the first N pool reads succeed, every later one FAILS with a 502 (the
    # "restart succeeded, then the API went away" window). A RESTART_MARKER flips that runner online.
    set -uo pipefail
    post=0
    path=""
    shift 2>/dev/null || true
    [ "${1:-}" = "api" ] && shift
    while [ $# -gt 0 ]; do
      case "$1" in
        -X) post=1 ;;
        --paginate) : ;;
        --jq) shift ;;
        *) path="$1" ;;
      esac
      shift
    done
    if [ "$post" = 1 ]; then printf 'TOKEN-FROM-FAKE-GH\\n'; exit 0; fi
    case "$path" in
      *"actions/runs?status=queued"*)
        printf '%s\\n' "${QUEUED_COUNT:-0}"
        exit 0 ;;
      *"actions/runners"*)
        if [ -n "${POOL_FAIL_AFTER:-}" ]; then
          n=0
          [ -f "${POOL_READ_COUNT:-/dev/null}" ] && n=$(cat "${POOL_READ_COUNT}" 2>/dev/null || echo 0)
          n=$(( n + 1 ))
          printf '%s' "$n" > "${POOL_READ_COUNT:-/dev/null}"
          if [ "$n" -gt "$POOL_FAIL_AFTER" ]; then
            echo 'gh: 502 Bad Gateway (server error)' >&2
            exit 1
          fi
        fi
        if [ -f "${RESTART_MARKER:-/nonexistent}" ]; then
          m="$(cat "${RESTART_MARKER}")"
          awk -v m="$m" 'BEGIN{FS="\\t"} { if (m == "*" || $1 == m) $2 = "online"; print $1"\\t"$2"\\t"$3"\\t"$4 }' "${POOL_TSV:-/dev/null}"
          exit 0
        fi
        cat "${POOL_TSV:-/dev/null}"
        exit 0 ;;
      *)
        echo "unexpected gh path: $path" >&2
        exit 1 ;;
    esac
""")

SYSTEMCTL_FAKE = textwrap.dedent("""\
    #!/usr/bin/env bash
    # Fake `systemctl`. restart/enable --now succeed (unless SYSTEMCTL_RC), and `restart <unit>`
    # writes the runner name into RESTART_MARKER so the next pool read flips it online.
    printf '%s\\n' "$*" >> "${SYSTEMCTL_LOG:-/dev/null}"
    case "$1" in
      restart)
        unit="${2:-}"
        unit="${unit#actions.runner.}"
        unit="${unit%.service}"
        name="${unit##*.}"
        printf '%s' "$name" > "${RESTART_MARKER:-/dev/null}"
        ;;
    esac
    exit "${SYSTEMCTL_RC:-0}"
""")

CONFIG_SH_FAKE = textwrap.dedent("""\
    #!/usr/bin/env bash
    # Fake `config.sh`. Records its argv. With CONFIG_REFUSE_IF_STALE=1 it refuses with the EXACT
    # refusal the real config.sh emits when the local registration state still exists in $CONFIG_DIR.
    if [ "${CONFIG_REFUSE_IF_STALE:-0}" = "1" ]; then
      d="${CONFIG_DIR:-.}"
      if [ -f "$d/.runner" ] || [ -f "$d/.credentials" ]; then
        echo "Cannot configure the runner because it is already configured. To reconfigure the runner, run './config.sh remove' first." >&2
        exit 1
      fi
    fi
    printf '%s\\n' "$*" >> "${CONFIG_ARGV_LOG:-/dev/null}"
    exit 0
""")

PROVISIONER_FAKE = textwrap.dedent("""\
    #!/usr/bin/env bash
    printf 'fake-provisioner\\n' >> "${PROVISIONER_LOG:-/dev/null}"
    exit 0
""")


def _write_exec(path: Path, content: str) -> Path:
    path.write_text(content, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    return path


def _runner_config(name: str, repo: str = REPO) -> str:
    return json.dumps({"agentName": name, "gitHubUrl": f"https://github.com/{repo}"})


def _meminfo(mb: int) -> str:
    return f"MemTotal:       {mb * 1024} kB\nMemAvailable:   {mb * 1024} kB\n"


def _load_mutated(mutation: str, replacement: str):
    """Load a fresh copy of the module with one source mutation applied."""
    src = TOOL.read_text(encoding="utf-8")
    if mutation not in src:
        raise AssertionError(f"mutation anchor not found in source: {mutation!r}")
    mutated = src.replace(mutation, replacement, 1)
    import uuid

    modname = f"runner_autoscale_mut_{uuid.uuid4().hex}"
    mod = type(ra)(modname)
    mod.__dict__["__name__"] = modname
    mod.__dict__["__file__"] = str(TOOL)
    _sys.modules[modname] = mod
    exec(compile(mutated, str(TOOL), "exec"), mod.__dict__)  # noqa: S102 - test-only mutant
    return mod


# ── a reusable converged set of fixtures ──────────────────────────────────────────────────────
class Box:
    """One hermetic box: temp root, meminfo, and every fake wired up via env."""

    def __init__(self, monkeypatch: pytest.MonkeyPatch, tmp_path: Path):
        self.tmp = tmp_path
        self.root = tmp_path / "opt"
        self.root.mkdir()
        self.meminfo = tmp_path / "meminfo"
        self.meminfo.write_text(_meminfo(8192), encoding="utf-8")
        self.pool_tsv = tmp_path / "pool.tsv"
        self.pool_tsv.write_text("", encoding="utf-8")
        self.gh = _write_exec(tmp_path / "gh", GH_FAKE)
        self.systemctl = _write_exec(tmp_path / "systemctl", SYSTEMCTL_FAKE)
        self.config_sh = _write_exec(tmp_path / "config.sh", CONFIG_SH_FAKE)
        self.provisioner = _write_exec(tmp_path / "provision.sh", PROVISIONER_FAKE)
        self.alive_dirs = tmp_path / "alive.txt"
        self.alive_dirs.write_text("", encoding="utf-8")
        self.busy_dirs = tmp_path / "busy.txt"
        self.busy_dirs.write_text("", encoding="utf-8")
        self.argv_log = tmp_path / "config-argv.log"
        self.argv_log.write_text("", encoding="utf-8")
        self.provisioner_log = tmp_path / "provisioner.log"
        self.provisioner_log.write_text("", encoding="utf-8")
        self.systemctl_log = tmp_path / "systemctl.log"
        self.systemctl_log.write_text("", encoding="utf-8")
        self.pool_read_count = tmp_path / "pool-read-count"
        self.restart_marker = tmp_path / "restart-marker"

        monkeypatch.setenv("RUNNER_AUTOSCALE_GH", str(self.gh))
        monkeypatch.setenv("RUNNER_AUTOSCALE_SYSTEMCTL", str(self.systemctl))
        monkeypatch.setenv("RUNNER_AUTOSCALE_CONFIG_SH", str(self.config_sh))
        monkeypatch.setenv("RUNNER_AUTOSCALE_PROVISIONER", str(self.provisioner))
        monkeypatch.setenv("RUNNER_AUTOSCALE_ALIVE_DIRS", str(self.alive_dirs))
        monkeypatch.setenv("RUNNER_AUTOSCALE_BUSY_DIRS", str(self.busy_dirs))
        monkeypatch.setenv("RUNNER_AUTOSCALE_NO_SUDO", "1")
        monkeypatch.setenv("RUNNER_AUTOSCALE_STATE_DIR", str(tmp_path / "state"))
        monkeypatch.setenv("RUNNER_AUTOSCALE_ONLINE_WAIT_S", "2")
        monkeypatch.setenv("RUNNER_AUTOSCALE_POLL_S", "1")
        monkeypatch.setenv("CONFIG_ARGV_LOG", str(self.argv_log))
        monkeypatch.setenv("CONFIG_DIR", str(self.root))
        monkeypatch.setenv("PROVISIONER_LOG", str(self.provisioner_log))
        monkeypatch.setenv("SYSTEMCTL_LOG", str(self.systemctl_log))
        monkeypatch.setenv("POOL_TSV", str(self.pool_tsv))
        monkeypatch.setenv("POOL_READ_COUNT", str(self.pool_read_count))
        monkeypatch.setenv("RESTART_MARKER", str(self.restart_marker))

    def add_install(self, name: str, *, alive: bool = False) -> Path:
        d = self.root / f"gh-runner-{name}"
        d.mkdir()
        (d / ".runner").write_text(_runner_config(name), encoding="utf-8")
        if alive:
            self.alive_dirs.write_text(f"{d}\n", encoding="utf-8")
        return d

    def set_pool(self, *rows: str) -> None:
        self.pool_tsv.write_text("".join(rows), encoding="utf-8")

    def converge(self, **kw) -> dict:
        return ra.converge(REPO, root=str(self.root), machine="x86_64", **kw)

    def config_argv(self) -> str:
        return self.argv_log.read_text(encoding="utf-8")


def _row(name: str, status: str, busy: bool, labels: str = "") -> str:
    return f"{name}\t{status}\t{'true' if busy else 'false'}\t{labels}\n"


# ── (a) the label floor ───────────────────────────────────────────────────────────────────────
def test_label_floor_resolve_labels():
    """An empty-of-`ubuntu-latest` pool grants the fallback label on re-registration."""
    pool: dict[str, ra.PoolEntry] = {}
    labels = ra.resolve_labels(pool, "x86_64")
    assert "ubuntu-latest" in labels
    assert labels == "self-hosted-x64,ubuntu-latest"


def test_label_floor_registration_writes_it(monkeypatch, tmp_path, capsys):
    """A real ORPHANED re-registration writes the floor label and logs why."""
    box = Box(monkeypatch, tmp_path)
    box.add_install("x64")  # no .runner in pool -> ORPHANED
    box.set_pool()  # empty pool: nobody advertises ubuntu-latest
    monkeypatch.setenv("QUEUED_COUNT", "0")

    box.converge()

    argv = box.config_argv()
    assert "--labels self-hosted-x64,ubuntu-latest" in argv
    assert "label floor" in capsys.readouterr().out


# ── (b) the handover is unchanged ─────────────────────────────────────────────────────────────
def test_label_handover_no_double_add(monkeypatch, tmp_path, capsys):
    """Fallback engaged ⇒ gate-following, exactly one `ubuntu-latest`, no floor line."""
    pool = {
        "arm-1": ra.PoolEntry(name="arm-1", status="online", busy=False,
                              labels=["self-hosted-arm64", "ubuntu-latest"])
    }
    labels = ra.resolve_labels(pool, "x86_64")
    assert labels == "self-hosted-x64,ubuntu-latest"
    assert labels.count("ubuntu-latest") == 1
    assert "label floor" not in capsys.readouterr().out


# ── (c) unread pool AFTER a restart ───────────────────────────────────────────────────────────
def test_unread_pool_after_restart_retries_then_names_gh_error(monkeypatch, tmp_path):
    box = Box(monkeypatch, tmp_path)
    box.add_install("x64")  # DEAD: in the pool, offline
    box.set_pool(_row("x64", "offline", False))
    monkeypatch.setenv("QUEUED_COUNT", "0")
    monkeypatch.setenv("POOL_FAIL_AFTER", "1")  # first read ok (classification), then 502 forever

    record = box.converge()

    assert record["verdict"] == "unmeasurable"
    assert "502" in record.get("error", "")
    assert record.get("unverified_cause") == "pool-read-after-restart"
    # the retry actually happened: more than one pool read after the restart window opened
    reads = int(box.pool_read_count.read_text(encoding="utf-8").strip() or "0")
    assert reads >= 2, f"expected a bounded retry (>=2 pool reads), got {reads}"


# ── (d) the starvation invariant ──────────────────────────────────────────────────────────────
def _starvation_box(monkeypatch, tmp_path, *, queued: int, row: str):
    box = Box(monkeypatch, tmp_path)
    box.add_install("x64", alive=True)
    box.set_pool(row)
    monkeypatch.setenv("QUEUED_COUNT", str(queued))
    return box


def test_starvation_fires(monkeypatch, tmp_path):
    box = _starvation_box(monkeypatch, tmp_path, queued=5, row=_row("x64", "online", False))
    record = box.converge(nproc="1")
    assert record["verdict"] == "starved"
    assert "STARVED" in record["error"]
    assert "queued_runs=5" in record["error"]


def test_starvation_exit_code_nonzero(monkeypatch, tmp_path, capsys):
    box = _starvation_box(monkeypatch, tmp_path, queued=5, row=_row("x64", "online", False))
    rc = ra.main(["--status", "--json", "--repo", REPO, "--root", str(box.root)])
    assert rc == 6
    out = capsys.readouterr().out
    assert json.loads(out)["verdict"] == "starved"


def test_starvation_near_miss_busy(monkeypatch, tmp_path):
    box = _starvation_box(monkeypatch, tmp_path, queued=5, row=_row("x64", "online", True))
    record = box.converge(nproc="1")
    assert record["verdict"] != "starved"


def test_starvation_near_miss_no_queue(monkeypatch, tmp_path):
    box = _starvation_box(monkeypatch, tmp_path, queued=0, row=_row("x64", "online", False))
    record = box.converge(nproc="1")
    assert record["verdict"] != "starved"


def test_starvation_near_miss_all_offline(monkeypatch, tmp_path):
    box = _starvation_box(monkeypatch, tmp_path, queued=5, row=_row("x64", "offline", False))
    record = box.converge(nproc="1")
    assert record["verdict"] != "starved"


# ── (e) the two mutations ─────────────────────────────────────────────────────────────────────
def test_mutation_removing_the_floor_reddens_a():
    """Removing the floor reverts to handover-only: an empty pool grants NO `ubuntu-latest`."""
    mutant = _load_mutated(
        'return f"{arch},{FALLBACK_LABEL}" if (fallback_engaged(pool) or floor) else arch',
        'return f"{arch},{FALLBACK_LABEL}" if fallback_engaged(pool) else arch',
    )
    assert mutant.resolve_labels({}, "x86_64") == "self-hosted-x64"  # the floor is what (a) needs


def test_mutation_removing_the_retry_reddens_c(monkeypatch, tmp_path):
    """Removing the transient retry makes a post-restart 502 conclude on the FIRST read."""
    mutant = _load_mutated(
        "if _is_transient_gh_error(str(exc)):",
        "if False:  # MUTATION: retry removed",
    )
    box = Box(monkeypatch, tmp_path)
    box.set_pool(_row("x64", "offline", False))
    monkeypatch.setenv("POOL_FAIL_AFTER", "0")  # every pool read fails with a 502

    state, err = mutant.wait_online(REPO, "x64", timeout_s=2, poll_s=1)

    assert state == "unverified"
    assert "502" in err  # the error text still travels (that half of (c) survives)
    reads = int(box.pool_read_count.read_text(encoding="utf-8").strip() or "0")
    assert reads == 1, (
        f"mutant retried ({reads} reads) — the bounded retry is exactly what test (c) guards"
    )


# ── (f) the repair path clears local config before --replace ─────────────────────────────────
def test_register_clears_local_config_before_replace(monkeypatch, tmp_path):
    box = Box(monkeypatch, tmp_path)
    d = box.add_install("x64")
    (d / ".credentials").write_text("stale-credentials", encoding="utf-8")
    monkeypatch.setenv("CONFIG_REFUSE_IF_STALE", "1")
    monkeypatch.setenv("CONFIG_DIR", str(d))

    # With the fix: replace=True clears .runner/.credentials first, so config.sh succeeds.
    result = ra.register(d, "x64", REPO, "self-hosted-x64", replace=True)
    assert "registered" in result
    assert "--labels self-hosted-x64" in box.config_argv()


def test_register_without_replace_hits_the_refusal(monkeypatch, tmp_path):
    """The same stale config, WITHOUT --replace (no clear), hits the exact refusal → load-bearing."""
    box = Box(monkeypatch, tmp_path)
    d = box.add_install("x64")
    (d / ".credentials").write_text("stale-credentials", encoding="utf-8")
    monkeypatch.setenv("CONFIG_REFUSE_IF_STALE", "1")
    monkeypatch.setenv("CONFIG_DIR", str(d))

    with pytest.raises(ra.ActionFailed) as excinfo:
        ra.register(d, "x64", REPO, "self-hosted-x64", replace=False)
    assert "already configured" in str(excinfo.value)
