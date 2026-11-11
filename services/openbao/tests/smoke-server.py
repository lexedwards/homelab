import argparse
import json
import importlib.util
import os
from pathlib import Path
import shutil
import socket
import signal
import ssl
import subprocess
import tempfile
import time
from urllib.error import HTTPError, URLError
from urllib.request import HTTPSHandler, ProxyHandler, Request, build_opener
from tls_fixtures import create_ca, issue_certificate
from unittest.mock import patch


spec = importlib.util.spec_from_file_location("readiness", Path(__file__).resolve().parents[1] / "scripts/check-ready.py")
readiness = importlib.util.module_from_spec(spec)
spec.loader.exec_module(readiness)


def available_port():
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


def render_cloud_config(tofu, scratch):
    source = Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory(prefix="openbao-config-", dir=scratch) as directory:
        root = Path(directory)
        for name in [
            "main.tf", "variables.tf", "versions.tf", "records.tf", "record-variables.tf",
            ".terraform.lock.hcl", "config/openbao.hcl.tftpl", "cloud-init/user-data.tftpl",
            "scripts/install.sh", "scripts/check-ready.py",
            "scripts/deploy-certificate.sh", "config/certificate-expiry.service",
            "config/certificate-expiry.timer",
        ]:
            target = root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source / name, target)
        (root / ".terraform").mkdir()
        (root / ".terraform/providers").symlink_to(source / ".terraform/providers", target_is_directory=True)
        inputs = {
            "incus_remote": "test-remote", "incus_image": "images:debian/13/cloud/arm64",
            "instance_vlan_id": 100, "technitium_server_url": "https://dns.example.invalid",
            "dns_zone": "example.invalid", "dns_name": "bao.example.invalid",
        }
        environment = {
            key: value for key, value in os.environ.items()
            if not key.startswith("TF_")
        }
        rendered = subprocess.run(
            [tofu, "console", "-no-color", *[f"-var={key}={value}" for key, value in inputs.items()]],
            input="jsonencode(yamldecode(nonsensitive(local.user_data)))\n",
            env=environment, cwd=root, capture_output=True, text=True, check=True, timeout=30,
        )
        return json.loads(json.loads(rendered.stdout))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bao", required=True)
    parser.add_argument("--tofu", default="tofu")
    args = parser.parse_args()
    scratch = "/tmp/opencode" if Path("/tmp/opencode").is_dir() else None
    cloud = render_cloud_config(args.tofu, scratch)
    config = next(item["content"] for item in cloud["write_files"] if item["path"] == "/etc/openbao/openbao.hcl")
    with tempfile.TemporaryDirectory(prefix="openbao-smoke-", dir=scratch) as directory:
        root = Path(directory)
        data = root / "data"
        data.mkdir()
        ca = create_ca(root / "ca")
        first = issue_certificate(root / "first", ca)
        second = issue_certificate(root / "second", ca)
        current = root / "current"
        current.symlink_to(first, target_is_directory=True)
        context = ssl.create_default_context(cafile=ca / "ca.pem")
        opener = build_opener(ProxyHandler({}), HTTPSHandler(context=context))
        api_port, cluster_port = available_port(), available_port()
        while cluster_port == api_port:
            cluster_port = available_port()
        config = config.replace('"/opt/openbao/data"', json.dumps(str(data)))
        config = config.replace("0.0.0.0:8200", f"127.0.0.1:{api_port}")
        config = config.replace("127.0.0.1:8201", f"127.0.0.1:{cluster_port}")
        config = config.replace("/etc/openbao/tls/current", str(current))
        path = root / "openbao.hcl"
        path.write_text(config)
        for run in range(2):
            with (root / "server.log").open("w+") as log:
                process = subprocess.Popen(
                    [args.bao, "server", f"-config={path}"],
                    env={key: value for key, value in os.environ.items() if key in ("PATH", "LANG", "LC_ALL", "TZ")},
                    stdout=log, stderr=subprocess.STDOUT,
                )
                try:
                    for attempt in range(40):
                        if process.poll() is not None:
                            log.seek(0)
                            raise RuntimeError(f"Server exited: {log.read()}")
                        try:
                            response = opener.open(f"https://localhost:{api_port}/v1/sys/health", timeout=1)
                        except HTTPError as error:
                            response = error
                        except URLError as error:
                            last_error = str(error)
                            time.sleep(0.1)
                            continue
                        with response:
                            health = json.load(response)
                            expected_status = 501 if run == 0 else 503
                            if response.status != expected_status or health.get("initialized") is not (run == 1) or health.get("sealed") is not True:
                                raise RuntimeError("Expected sealed storage with initialization preserved across restart")
                        break
                    else:
                        log.flush()
                        log.seek(0)
                        raise RuntimeError(f"Server did not become available: {last_error}\n{log.read()}")
                    endpoint = f"https://localhost:{api_port}"
                    if readiness.check_certificate(endpoint, current / "fullchain.pem", context) < 28:
                        raise RuntimeError("Expected the long-lived disposable certificate")
                    try:
                        readiness.check_certificate(endpoint, current / "fullchain.pem")
                    except ssl.SSLCertVerificationError:
                        pass
                    else:
                        raise RuntimeError("Untrusted test CA was accepted by normal public trust")
                    with patch.object(readiness.time, "time", return_value=time.time() + 20 * 86400):
                        try:
                            readiness.check_certificate(endpoint, current / "fullchain.pem", context)
                        except RuntimeError:
                            pass
                        else:
                            raise RuntimeError("Certificate-expiry warning threshold was ignored")
                    if run == 0:
                        def request(path, body=None, token=None):
                            payload = None if body is None else json.dumps(body).encode()
                            headers = {"Content-Type": "application/json"}
                            if token is not None:
                                headers["X-Vault-Token"] = token
                            with opener.open(Request(f"https://localhost:{api_port}/v1/{path}", data=payload, headers=headers), timeout=20) as response:
                                content = response.read()
                                return json.loads(content) if content else None

                        initialized = request("sys/init", {"secret_shares": 1, "secret_threshold": 1})
                        request("sys/unseal", {"key": initialized["keys_base64"][0]})
                        token = initialized["root_token"]
                        request("cubbyhole/tls-reload-check", {"proof": "synthetic"}, token)
                        pid = process.pid
                        replacement = root / "next"
                        replacement.symlink_to(second, target_is_directory=True)
                        replacement.replace(current)
                        try:
                            readiness.check_certificate(endpoint, current / "fullchain.pem", context)
                        except RuntimeError:
                            pass
                        else:
                            raise RuntimeError("Served/deployed certificate mismatch was not detected")
                        process.send_signal(signal.SIGHUP)
                        for attempt in range(50):
                            with socket.create_connection(("127.0.0.1", api_port), timeout=2) as raw:
                                with context.wrap_socket(raw, server_hostname="localhost") as connection:
                                    peer = connection.getpeercert(binary_form=True)
                            expected = ssl.PEM_cert_to_DER_cert((second / "cert.pem").read_text())
                            if peer == expected:
                                break
                            time.sleep(0.1)
                        else:
                            raise RuntimeError("SIGHUP did not load the renewed certificate")
                        health = request("sys/health")
                        readiness.check_certificate(endpoint, current / "fullchain.pem", context)
                        if process.poll() is not None or process.pid != pid or health["sealed"]:
                            raise RuntimeError("Certificate reload restarted or sealed the server")
                        if request("cubbyhole/tls-reload-check", token=token)["data"] != {"proof": "synthetic"}:
                            raise RuntimeError("Synthetic authenticated access did not survive TLS reload")
                        try:
                            opener.open(f"https://127.0.0.1:{api_port}/v1/sys/health", timeout=2)
                        except URLError:
                            pass
                        else:
                            raise RuntimeError("Hostname verification was bypassed")
                        print("TLS rotation: new certificate served with the same process, unsealed state and synthetic access; wrong hostname rejected")
                finally:
                    process.terminate()
                    try:
                        process.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait(timeout=5)
            print(f"Local server start {run + 1}: verified HTTPS; only disposable test storage used")


if __name__ == "__main__":
    main()
