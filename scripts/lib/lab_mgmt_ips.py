#!/usr/bin/env python3
"""AtlasLab - scripts/lib/lab_mgmt_ips.py

Reads `containerlab inspect -f json` output on stdin and prints
"<node> <mgmt-ip>" lines, one per deployed container whose name starts
with the given prefix (e.g. "clab-atlas-04-enterprise-").

A real file, not an inline heredoc, deliberately: this needs to read
piped JSON from stdin *and* take an argv prefix. `python3 - <<PYEOF`
can't do both - the heredoc redirect wins control of stdin over the
pipe, so the script itself parses fine but sys.stdin is already
exhausted by the time it tries to read the piped JSON. See
scripts/lib/common.sh's lab_mgmt_ips() for the caller.
"""
import json
import sys


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: lab_mgmt_ips.py <container-name-prefix>", file=sys.stderr)
        return 2
    prefix = sys.argv[1]

    try:
        data = json.load(sys.stdin)
    except Exception:
        return 0

    containers = []
    if isinstance(data, dict):
        for v in data.values():
            if isinstance(v, list):
                containers.extend(v)
    elif isinstance(data, list):
        containers = data

    for c in containers:
        name = c.get("name") or c.get("Name") or ""
        if not name.startswith(prefix):
            continue
        node = name[len(prefix):]
        ip = (c.get("ipv4_address") or c.get("mgmt_ipv4_address")
              or c.get("IPv4Address") or c.get("ipv4address") or "")
        ip = ip.split("/")[0] if ip else ""
        if node and ip:
            print(f"{node} {ip}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
