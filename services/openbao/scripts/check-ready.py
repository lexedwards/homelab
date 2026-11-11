#!/usr/bin/env python3
import argparse
import hashlib
import json
from pathlib import Path
import socket
import ssl
import subprocess
import sys
import time
from urllib.error import HTTPError, URLError
from urllib.request import ProxyHandler, build_opener
from urllib.parse import urlsplit


urlopen = build_opener(ProxyHandler({})).open
TLS_CERT = Path("/etc/openbao/tls/current/fullchain.pem")
TLS_KEY = Path("/etc/openbao/tls/current/privkey.pem")
DOMAIN = Path("/etc/openbao/acme-domain")


def endpoint(api_url):
    parsed = urlsplit(api_url)
    if (
        parsed.scheme != "https" or not parsed.hostname or parsed.username
        or parsed.password or parsed.query or parsed.fragment
        or parsed.path not in ("", "/")
    ):
        raise ValueError("A verified HTTPS API endpoint without credentials is required")
    return parsed.hostname, parsed.port or 443


def read_health(api_url):
    endpoint(api_url)
    try:
        response = urlopen(api_url.rstrip("/") + "/v1/sys/health", timeout=2)
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


def check_certificate(api_url, certificate=TLS_CERT, context=None):
    hostname, port = endpoint(api_url)
    context = context or ssl.create_default_context()
    if context.verify_mode != ssl.CERT_REQUIRED or not context.check_hostname:
        raise ValueError("Certificate-chain and hostname verification must remain enabled")
    with socket.create_connection((hostname, port), timeout=2) as connection:
        with context.wrap_socket(connection, server_hostname=hostname) as secure:
            metadata = secure.getpeercert()
            served = secure.getpeercert(binary_form=True)
    remaining = ssl.cert_time_to_seconds(metadata["notAfter"]) - time.time()
    if remaining <= 14 * 86400:
        raise RuntimeError("Served TLS certificate expires within fourteen days")
    pem = certificate.read_text().split("-----END CERTIFICATE-----", 1)[0] + "-----END CERTIFICATE-----\n"
    deployed = ssl.PEM_cert_to_DER_cert(pem)
    if hashlib.sha256(served).digest() != hashlib.sha256(deployed).digest():
        raise RuntimeError("Served TLS certificate differs from the deployed certificate; inspect reload logs")
    return int(remaining / 86400)


def check_pending_tls():
    if TLS_CERT.exists() or TLS_KEY.exists():
        raise RuntimeError("Incomplete or present TLS material cannot be treated as pending enrollment")
    properties = subprocess.check_output(
        ["systemctl", "show", "openbao", "--property=ActiveState,User,MemorySwapMax,ConditionResult,UnitFileState"],
        text=True, timeout=5,
    )
    unit = dict(line.split("=", 1) for line in properties.splitlines() if "=" in line)
    expected = {"ActiveState": "inactive", "User": "openbao", "MemorySwapMax": "0", "ConditionResult": "no", "UnitFileState": "enabled"}
    if any(unit.get(key) != value for key, value in expected.items()):
        raise RuntimeError("Pending enrollment requires an enabled, certificate-gated inactive service")


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


def main(argv=None):
    parser = argparse.ArgumentParser(description="Verify OpenBao TLS, health and swap hardening without authentication.")
    parser.add_argument("--api-url")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--certificate-only", action="store_true")
    mode.add_argument("--allow-pending-tls", action="store_true")
    args = parser.parse_args(argv)
    args.api_url = args.api_url or f"https://{DOMAIN.read_text().strip()}:8200"
    endpoint(args.api_url)
    if args.certificate_only:
        days = check_certificate(args.api_url)
        print(f"Verified served/deployed TLS certificate; expires in {days} days")
        return
    if args.allow_pending_tls and not TLS_CERT.exists() and not TLS_KEY.exists():
        check_pending_tls()
        print("OpenBao installed and certificate-gated; out-of-band TLS enrollment required; API is not ready")
        return
    check_hardening()
    for attempt in range(20):
        try:
            days = check_certificate(args.api_url)
            initialized, sealed = read_health(args.api_url)
            print(f"OpenBao running over verified HTTPS: initialized={initialized}, sealed={sealed}; swap disabled; certificate valid {days} days")
            if not initialized:
                print("Operator initialization and unseal required before secrets are usable")
            elif sealed:
                print("Manual unseal required before secrets are usable; do not reinitialize")
            return
        except (OSError, URLError, ValueError, RuntimeError, KeyError):
            if attempt == 19:
                raise RuntimeError("OpenBao health did not become available within the bounded startup check")
            time.sleep(2)


if __name__ == "__main__":
    try:
        main()
    except RuntimeError as error:
        print(f"OpenBao readiness failed: {error}", file=sys.stderr)
        sys.exit(1)
    except (OSError, ValueError, KeyError, subprocess.SubprocessError):
        print("OpenBao readiness failed; inspect protected local diagnostics", file=sys.stderr)
        sys.exit(1)
