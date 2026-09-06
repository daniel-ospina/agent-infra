#!/usr/bin/env python3
"""deepseek-balance-latch.py — latch-state mutations for the #476 balance
poller (deepseek-balance-watch.sh).

WHY THIS EXISTS: extensions/shared/provider-failover.ts is the latch
single-source-of-truth for pi sessions, but the poller runs under launchd
where tsx/strip-types are not reliably resolvable and python3 is the
established runtime (provider-latency-tripwire precedent, {{PYTHON_BIN}}).
This helper MIRRORS the TS module's durable-state contract byte-for-byte so
both writers interoperate on the same state file:

  - same file layout  ~/.pi/agent/state/provider-exhaustion.json (+ .lock)
  - same JSON shape   {version:1, epoch, updatedAt, primaries, blockedLegs}
  - same primary record shape {status, reason, source, latchedAt, expiresAt,
    families, notice} with ISO-8601 millisecond UTC timestamps
    (new Date().toISOString() equivalent)
  - same O_EXCL pidfile lock protocol (12s wait / 8s staleness: holder PID
    dead OR age — acquireLock mirror), atomic tmp+fsync+rename writes with
    readback CAS retry (≤3 attempts), corrupt-file rename-aside self-heal.
  - never throws; every failure degrades to a clear stderr + non-zero exit.

Contract parity is pinned by extensions/shared/provider-failover.poller.test.ts
which runs BOTH writers against identical starting states and asserts equal
durable JSON.

CLI:
  deepseek-balance-latch.py status
  deepseek-balance-latch.py set --primary deepseek [--reason low_balance|402]
                       [--source poller|manual] [--ttl-h 24] [--notice "t|b"]
  deepseek-balance-latch.py clear --primary deepseek [--reason poller|manual]
  deepseek-balance-latch.py block --provider qwen-tp --reason "401 auth"
  deepseek-balance-latch.py unblock --provider qwen-tp
  deepseek-balance-latch.py ledger --event poller-set --provider deepseek
                       [--detail "free text"]

Env:
  PI_CODING_AGENT_DIR   agent dir override (state lives under <dir>/state/)
  DBW_STATE_FILE        explicit state-file override (tests; highest priority)

Exit codes: 0 ok (or no-op), 2 usage, 3 state unreadable/other failure.
"""

import argparse
import json
import os
import sys
import time
from datetime import datetime, timedelta, timezone
from typing import Optional

EMPTY_STATE = {
    "version": 1,
    "epoch": 0,
    "updatedAt": "",
    "primaries": {},
    "blockedLegs": {},
}

LOCK_STALE_S = 8.0
LOCK_WAIT_S = 12.0
MAX_STATE_BYTES = 5 * 1024 * 1024
CAS_ATTEMPTS = 3


def iso_now() -> str:
    """JS new Date().toISOString() equivalent (ms precision, Z suffix)."""
    dt = datetime.now(timezone.utc)
    return dt.strftime("%Y-%m-%dT%H:%M:%S.") + f"{dt.microsecond // 1000:03d}Z"


def state_file() -> str:
    if os.environ.get("DBW_STATE_FILE"):
        return os.environ["DBW_STATE_FILE"]
    agent = os.environ.get("PI_CODING_AGENT_DIR") or os.path.join(
        os.path.expanduser("~"), ".pi", "agent"
    )
    return os.path.join(agent, "state", "provider-exhaustion.json")


def _read_state_raw(path: str):
    """Returns (state, error). Corrupt file → renamed aside + empty state
    (mirror of the TS module selfHealCorrupt). Never raises."""
    if not os.path.exists(path):
        return dict(EMPTY_STATE), None
    try:
        size = os.path.getsize(path)
        if size > MAX_STATE_BYTES:
            _rename_aside(path, "size")
            return dict(EMPTY_STATE), None
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
        if not isinstance(data, dict) or not isinstance(data.get("primaries"), dict):
            _rename_aside(path, "schema")
            return dict(EMPTY_STATE), None
        return _normalize(data), None
    except (ValueError, OSError):
        _rename_aside(path, "parse")
        return dict(EMPTY_STATE), None


def _normalize(data: dict) -> dict:
    epoch = data.get("epoch")
    primaries = data.get("primaries") or {}
    blocked = data.get("blockedLegs")
    return {
        "version": 1,
        "epoch": epoch if isinstance(epoch, int) and epoch >= 0 else 0,
        "updatedAt": data.get("updatedAt") if isinstance(data.get("updatedAt"), str) else "",
        "primaries": primaries,
        "blockedLegs": blocked if isinstance(blocked, dict) else {},
    }


def _rename_aside(path: str, why: str):
    backup = f"{path}.corrupt-{int(time.time() * 1000)}"
    try:
        os.replace(path, backup)
    except OSError:
        try:
            os.remove(path)
        except OSError:
            pass
    print(f"[deepseek-balance-latch] corrupt state moved to {backup} ({why})", file=sys.stderr)


def _pid_alive(pid: int) -> bool:
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def acquire_lock(lock_path: str):
    """O_EXCL pidfile lock mirroring the TS acquireLock: staleness = holder
    PID dead OR lock age > 8s; wait budget 12s. Returns a release callable or
    None (degraded — callers still write atomically with readback CAS).
    Hard failures (EACCES/EROFS on the open) exit 3 with a one-line stderr
    (never a traceback). Lock CONTENT is pid-only (single token, TS-compatible:
    the TS reader Number(trim)s the whole file)."""
    deadline = time.monotonic() + LOCK_WAIT_S
    while True:
        try:
            fd = os.open(lock_path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
            os.write(fd, f"{os.getpid()}\n".encode())
            os.close(fd)

            def release():
                # ownership check (TS-style): remove only if the lock still
                # holds THIS pid — a stale removal could delete a lock a
                # TS/third writer acquired after our hold lapsed.
                try:
                    with open(lock_path, "r", encoding="utf-8") as f:
                        holder = f.read().strip()
                    if holder == str(os.getpid()):
                        os.remove(lock_path)
                except OSError:
                    pass

            return release
        except FileExistsError:
            stale = False
            try:
                with open(lock_path, "r", encoding="utf-8") as f:
                    content = f.read().split()
                if content:
                    holder = int(content[0])
                    if not _pid_alive(holder):
                        stale = True
                age = time.time() - os.path.getmtime(lock_path)
                if age > LOCK_STALE_S:
                    stale = True
            except (OSError, ValueError):
                stale = True
            if stale:
                try:
                    os.remove(lock_path)
                except OSError:
                    pass
                continue
            if time.monotonic() >= deadline:
                return None
            time.sleep(0.015)
        except OSError as e:
            # EACCES/EROFS/etc — hard failure, clean degrade (never traceback)
            print(f"[deepseek-balance-latch] lock open failed: {e}", file=sys.stderr)
            sys.exit(3)


def mutate(mutator):
    """Read → mutate (fresh read per attempt) → atomic write with epoch bump +
    readback CAS retry. Mirrors updateLatchState + tryWriteLatchState. The
    mutator returns the next state dict (or None to signal no-op). Returns the
    durable state; exits 3 on persistent write failure."""
    path = state_file()
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)  # BEFORE the lock (O_EXCL open ENOENTs on a missing dir — first-write path)
    except OSError as e:
        print(f"[deepseek-balance-latch] state dir create failed: {e}", file=sys.stderr)
        sys.exit(3)
    lock = acquire_lock(path + ".lock")
    try:
        # sweep stale .tmp-* siblings older than 1h (module sweepStaleTmp)
        now = time.time()
        d = os.path.dirname(path)
        try:
            for f in os.listdir(d):
                if ".tmp-" in f:
                    fp = os.path.join(d, f)
                    if now - os.path.getmtime(fp) > 3600:
                        try:
                            os.remove(fp)
                        except OSError:
                            pass
        except OSError:
            pass
        for _ in range(CAS_ATTEMPTS):
            cur, err = _read_state_raw(path)
            if err:
                print(f"[deepseek-balance-latch] unreadable state: {err}", file=sys.stderr)
                sys.exit(3)
            nxt = mutator(cur)
            if nxt is None:
                return cur
            if nxt is cur:
                return cur
            nxt = dict(nxt)
            nxt["epoch"] = cur["epoch"] + 1
            nxt["updatedAt"] = iso_now()
            payload = json.dumps(nxt, indent=2, ensure_ascii=False) + "\n"
            tmp = f"{path}.tmp-{os.getpid()}-{int(time.time() * 1000)}"
            try:
                fd = os.open(tmp, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
                with os.fdopen(fd, "w", encoding="utf-8") as fh:
                    fh.write(payload)
                    fh.flush()
                    os.fsync(fh.fileno())
                os.replace(tmp, path)
            except OSError as e:
                try:
                    os.remove(tmp)
                except OSError:
                    pass
                print(f"[deepseek-balance-latch] write failed: {e}", file=sys.stderr)
                sys.exit(3)
            # readback verification (mirror tryWriteLatchState)
            try:
                with open(path, "r", encoding="utf-8") as f:
                    if f.read() != payload:
                        continue  # racing unlocked writer — re-read + re-apply
            except OSError:
                continue
            return _read_state_raw(path)[0]
        # CAS exhausted — return what is durable now
        return _read_state_raw(path)[0]
    finally:
        if lock is not None:
            lock()


# ── mutations (mirror the TS exported helpers) ──────────────────────────────

def op_set(primary: str, reason: str, source: str, ttl_hours: float, notice: Optional[str]):
    now_dt = datetime.now(timezone.utc)
    now = now_dt.strftime("%Y-%m-%dT%H:%M:%S.") + f"{now_dt.microsecond // 1000:03d}Z"
    exp_dt = now_dt + timedelta(hours=ttl_hours)
    expiry = exp_dt.strftime("%Y-%m-%dT%H:%M:%S.") + f"{exp_dt.microsecond // 1000:03d}Z"

    def mut(cur):
        existing = cur["primaries"].get(primary)
        if notice is not None:
            parts = notice.split("|", 1)
            rec_notice = (
                {"title": parts[0], "body": parts[1] if len(parts) > 1 else ""}
                if parts[0]
                else None
            )
        else:
            rec_notice = (existing or {}).get("notice") if existing else None
        primaries = dict(cur["primaries"])
        primaries[primary] = {
            "status": "exhausted",
            "reason": reason,
            "source": source,
            "latchedAt": now,
            "expiresAt": expiry,
            "families": dict((existing or {}).get("families", {})),
            "notice": rec_notice,
        }
        return {**cur, "primaries": primaries}

    return mutate(mut)


def op_clear(primary: str, reason: str):
    def mut(cur):
        if primary not in cur["primaries"]:
            return None  # no-op
        primaries = dict(cur["primaries"])
        del primaries[primary]
        # top-level blockedLegs always survives a balance-restore clear
        return {**cur, "primaries": primaries}

    return mutate(mut)


def op_block(provider: str, reason: str):
    now = iso_now()

    def mut(cur):
        blocked = cur.get("blockedLegs") or {}
        if provider in blocked:
            return None  # already recorded (markLegBlocked mirror)
        blocked = dict(blocked)
        blocked[provider] = {"reason": reason, "at": now}
        return {**cur, "blockedLegs": blocked}

    return mutate(mut)


def op_unblock(provider: str):
    def mut(cur):
        blocked = cur.get("blockedLegs") or {}
        if provider not in blocked:
            return None
        blocked = dict(blocked)
        del blocked[provider]
        return {**cur, "blockedLegs": blocked}

    return mutate(mut)


def op_ledger(event: str, provider: str, detail: str):
    """Durable JSONL audit append — mirrors appendLedger (audit never breaks
    the caller; failures logged to stderr, exit 0). The audit dir is DERIVED
    from the state-file path (default ~/.pi/agent/state/... →
    ~/.pi/agent/audit/... in production; a DBW_STATE_FILE test override → the
    sibling audit dir under the test tree), so tests never pollute the real
    ledger."""
    sf = state_file()
    base = os.path.dirname(os.path.dirname(sf))  # <agent|test-tree>/audit
    path = os.path.join(base, "audit", "provider-failover.jsonl")
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        entry = {
            "ts": iso_now(),
            "event": "provider-failover",
            "subevent": event,
            "provider": provider,
            "detail": detail,
            "writer": "poller",
        }
        with open(path, "a", encoding="utf-8") as f:
            f.write(json.dumps(entry, ensure_ascii=False) + "\n")
    except OSError as e:
        print(f"[deepseek-balance-latch] ledger append failed: {e}", file=sys.stderr)
    return None


def main(argv):
    ap = argparse.ArgumentParser(prog="deepseek-balance-latch.py")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("status")
    p_set = sub.add_parser("set")
    p_set.add_argument("--primary", required=True)
    p_set.add_argument("--reason", default="low_balance", choices=["low_balance", "402", "poller"])
    p_set.add_argument("--source", default="poller", choices=["poller", "manual", "interactive", "marker"])
    p_set.add_argument("--ttl-h", type=float, default=24.0)
    p_set.add_argument("--notice", default=None)
    p_clr = sub.add_parser("clear")
    p_clr.add_argument("--primary", required=True)
    p_clr.add_argument("--reason", default="poller", choices=["poller", "manual"])
    p_blk = sub.add_parser("block")
    p_blk.add_argument("--provider", required=True)
    p_blk.add_argument("--reason", required=True)
    p_ublk = sub.add_parser("unblock")
    p_ublk.add_argument("--provider", required=True)
    p_ldg = sub.add_parser("ledger")
    p_ldg.add_argument("--event", required=True)
    p_ldg.add_argument("--provider", required=True)
    p_ldg.add_argument("--detail", default="")
    args = ap.parse_args(argv)

    if args.cmd == "status":
        state, err = _read_state_raw(state_file())
        if err:
            sys.exit(3)
        print(json.dumps(state, indent=2, ensure_ascii=False))
        return 0
    if args.cmd == "set":
        op_set(args.primary, args.reason, args.source, args.ttl_h, args.notice)
        return 0
    if args.cmd == "clear":
        op_clear(args.primary, args.reason)
        return 0
    if args.cmd == "block":
        op_block(args.provider, args.reason)
        return 0
    if args.cmd == "unblock":
        op_unblock(args.provider)
        return 0
    if args.cmd == "ledger":
        op_ledger(args.event, args.provider, args.detail)
        return 0
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
