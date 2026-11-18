#!/usr/bin/env python3
"""Best-effort audit writer shared by the SymbiOS host-side writers.

The audit trail is a single plain-text file on the encrypted data partition:
<data_root>/log/symbios-audit.log. Writing an event must never abort the
operation that triggered it, so all I/O errors are contained here.

Secrets never reach this module: callers pass action names and inventory
keys only, never values.
"""

import os
import sys
from datetime import datetime, timezone
from pathlib import Path


def audit_log_path():
    """Resolve the audit file, honoring an explicit test/dev override."""
    configured = os.environ.get("SYMBIOS_AUDIT_LOG")
    if configured:
        return Path(configured)
    # scripts/ lives at <data_root>/git/SymbiOS/scripts on the host.
    return Path(__file__).resolve().parents[3] / "log" / "symbios-audit.log"


def write_event(source, action, detail=""):
    """Append one single-line event; return False on any I/O failure."""
    try:
        path = audit_log_path()
        path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        clean_detail = " ".join(str(detail).split())[:1000]
        stamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        line = (
            f"{stamp} source={source} uid={os.getuid()} "
            f"action={action} {clean_detail}\n"
        )
        with path.open("a", encoding="utf-8") as handle:
            handle.write(line)
        os.chmod(path, 0o600)
        return True
    except (OSError, ValueError):
        return False


def usage():
    """Print the command-line contract."""
    print("Usage: symbios_audit.py event <source> <action> [detail]")
    print("       symbios_audit.py -h | --help")
    print("")
    print("Append a best-effort audit event to <data_root>/log/symbios-audit.log.")
    print("Use SYMBIOS_AUDIT_LOG to override the file path (tests only).")
    print("Exit codes: 0 event written, 1 write failed, 2 usage error.")


def main(argv):
    """Dispatch the tiny command-line interface."""
    if not argv or argv[0] in ("-h", "--help"):
        usage()
        return 0
    if argv[0] != "event" or len(argv) < 3:
        usage()
        return 2
    return 0 if write_event(argv[1], argv[2], " ".join(argv[3:])) else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
