#!/usr/bin/env python3
import json
from pathlib import Path
import subprocess
import sys
import time
from urllib.error import HTTPError, URLError
from urllib.request import ProxyHandler, build_opener


urlopen = build_opener(ProxyHandler({})).open


def read_health():
    try:
        response = urlopen("http://127.0.0.1:8200/v1/sys/health", timeout=2)
    except HTTPError as error:
        response = error
    with response:
        status = response.status
        body = json.load(response)
    expected = {200: (True, False), 429: (True, False), 501: (False, True), 503: (True, True)}
    if not isinstance(body, dict):
        raise RuntimeError("Unexpected health response")
    initialized, sealed = body.get("initialized"), body.get("sealed")
    if (
        type(initialized) is not bool or type(sealed) is not bool
        or status not in expected or (initialized, sealed) != expected[status]
    ):
        raise RuntimeError("Unexpected health response")
    return initialized, sealed


def check_hardening(cgroup_root=Path("/sys/fs/cgroup")):
    properties = subprocess.check_output(
        ["systemctl", "show", "openbao", "--property=ActiveState,User,MainPID,MemorySwapMax,ControlGroup"],
        text=True, timeout=5,
    )
    unit = dict(line.split("=", 1) for line in properties.splitlines() if "=" in line)
    if (
        unit.get("ActiveState") != "active" or unit.get("User") != "openbao"
        or int(unit.get("MainPID", "0")) <= 0 or unit.get("MemorySwapMax") != "0"
        or not unit.get("ControlGroup", "").startswith("/")
        or unit.get("ControlGroup") == "/"
    ):
        raise RuntimeError("OpenBao must be active as openbao with MemorySwapMax=0")
    swap_limit = cgroup_root / unit["ControlGroup"].lstrip("/") / "memory.swap.max"
    if swap_limit.read_text().strip() != "0":
        raise RuntimeError("Service cgroup does not enforce memory.swap.max=0")


def main():
    check_hardening()
    for attempt in range(20):
        try:
            initialized, sealed = read_health()
            print(f"OpenBao running: initialized={initialized}, sealed={sealed}; swap disabled")
            if not initialized:
                print("Operator initialization and unseal required before secrets are usable")
            elif sealed:
                print("Manual unseal required before secrets are usable; do not reinitialize")
            return
        except (OSError, URLError, ValueError, RuntimeError):
            if attempt == 19:
                raise RuntimeError("OpenBao health did not become available within the bounded startup check")
            time.sleep(2)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"OpenBao readiness failed: {error}", file=sys.stderr)
        sys.exit(1)
