#!/usr/bin/env python3
"""deny-event.py — append ONE audit event for a floor-gate refusal. Called by the gates; never wired itself.

  <refused command or path on stdin> | deny-event.py --gate <gate> --rule <rule-id> --tool <tool> --reason <text>

A refusal used to be a message to the model and nothing else, so the floor's decisions left no trail.

SHAPE: OCSF 1.9.0 `api_activity` (class 6003) with the `security_control` and `ai_operation` profiles, the
shape a tool-call audit trail can share, so a floor deny and any other deny join in one query. A floor
refusal is a POLICY gate, not an authorization check: action_id 2 Denied, disposition_id 2 Blocked,
status_id 2 Failure. A shell command or a file write is not a CRUD verb, so activity_id is 99 Other with
the verb as its name: a wrong CRUD class is worse than Other.

NEVER RECORDED: the refused text. A refused command is exactly the one most likely to hold a secret, so
only a 16-hex sha256 prefix of stdin goes in, and it arrives on stdin, not argv, so the text never sits in
the process table.

NEVER CHANGES A VERDICT. The gate refuses first and calls this after. Any failure here (no directory, an
unwritable log, bad input) exits 0 silently: the trail fails open, the decision does not.

WHERE IT GOES: $GOVERNANCE_DENY_LOG, default ~/.local/state/governance/deny.jsonl (directory 0700, file
0600, append-only). A machine's file is local. It counts toward a fleet view only where something ships
it, and whatever ships it should also report the machine alive on days with no denies, or a silent
machine reads as a clean one.
"""
import argparse
import getpass
import hashlib
import json
import os
import socket
import sys
import time
import uuid

GROK_TOOLS = {"run_terminal_command", "write", "search_replace"}
VERB = {"bash-safety-gate": "execute", "write-safety-gate": "write"}


def harness(tool):
    if os.environ.get("GOVERNANCE_HARNESS"):
        return os.environ["GOVERNANCE_HARNESS"]
    if tool in GROK_TOOLS:
        return "grok"
    return "claude-code" if tool else "unknown"


def event(gate, rule, tool, reason, digest):
    service = harness(tool)
    seat = os.environ.get("GOVERNANCE_SEAT") or ""
    host = socket.gethostname()
    return {
        "class_uid": 6003, "category_uid": 6,
        "activity_id": 99, "activity_name": VERB.get(gate, "other"), "type_uid": 6003 * 100 + 99,
        "time": int(time.time() * 1000),
        "severity_id": 2, "severity": "Low",
        "metadata": {
            "version": "1.9.0", "profiles": ["security_control", "ai_operation"],
            "product": {"name": "governance-floor", "vendor_name": "governance", "version": "1"},
            "log_name": "floor.deny", "event_code": "floor.deny", "uid": str(uuid.uuid4()),
        },
        "cloud": {"provider": "local"},
        "src_endpoint": {"hostname": host},
        "actor": {
            "user": {"name": getpass.getuser(), "type_id": 1},
            "authorizations": [{"decision": "denied",
                                "policy": {"name": gate, "uid": rule, "version": "1", "is_applied": True}}],
        },
        "ai_agent": {"uid": seat or service, "name": service, "type_id": 1},
        "api": {
            "operation": tool or "unknown",
            "service": {"name": service},
            "request": {"uid": str(uuid.uuid4()), "data": {"args_sha256_16": digest}},
        },
        "status_id": 2, "status": "Failure", "status_detail": reason,
        "action_id": 2, "action": "Denied", "disposition_id": 2, "disposition": "Blocked",
        "is_alert": False,
        "message": f"{gate} refused {tool or 'a call'} ({rule})",
    }


def main():
    ap = argparse.ArgumentParser(add_help=False)
    for flag in ("--gate", "--rule", "--tool", "--reason"):
        ap.add_argument(flag, default="")
    a, _ = ap.parse_known_args()
    data = sys.stdin.buffer.read() if not sys.stdin.isatty() else b""
    digest = hashlib.sha256(data).hexdigest()[:16]
    default_log = os.path.expanduser("~/.local/state/governance/deny.jsonl")
    path = os.path.expanduser(os.environ.get("GOVERNANCE_DENY_LOG") or default_log)
    dirpath = os.path.dirname(path) or "."
    # The mode given to makedirs is a no-op when the directory already exists (a POSIX mkdir() only
    # applies its mode argument at CREATION) — so a pre-existing, loosely permissioned directory would
    # silently keep that permission forever, however tightly this module asks to create it. chmod
    # explicitly to actually hold 0700 rather than only asking for it once — but ONLY a directory this
    # call just created, or governance's own default state directory. GOVERNANCE_DENY_LOG is a path an
    # operator chooses; pointed at a bare filename (no directory component, so dirpath becomes ".") or
    # into a directory shared with unrelated files, chmodding that PRE-EXISTING directory on every call
    # would silently re-permission something this hook does not own and was never asked to lock down —
    # the cwd, or another service's shared log directory. A directory we just made, or our own default
    # directory nothing else should be sharing, carries no such risk.
    existed_before = os.path.isdir(dirpath)
    os.makedirs(dirpath, mode=0o700, exist_ok=True)
    if not existed_before or path == default_log:
        try:
            os.chmod(dirpath, 0o700)
        except OSError:
            pass
    line = json.dumps(event(a.gate, a.rule, a.tool, a.reason, digest), separators=(",", ":")) + "\n"
    fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
    try:
        try:
            os.fchmod(fd, 0o600)
        except OSError:
            pass
        os.write(fd, line.encode())
    finally:
        os.close(fd)


if __name__ == "__main__":
    try:
        main()
    except BaseException:
        pass
    sys.exit(0)
