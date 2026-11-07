import argparse
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import time
from urllib.error import HTTPError, URLError
from urllib.request import ProxyHandler, build_opener


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
    opener = build_opener(ProxyHandler({}))
    with tempfile.TemporaryDirectory(prefix="openbao-smoke-", dir=scratch) as directory:
        root = Path(directory)
        data = root / "data"
        data.mkdir()
        api_port, cluster_port = available_port(), available_port()
        while cluster_port == api_port:
            cluster_port = available_port()
        config = config.replace('"/opt/openbao/data"', json.dumps(str(data)))
        config = config.replace("0.0.0.0:8200", f"127.0.0.1:{api_port}")
        config = config.replace("127.0.0.1:8201", f"127.0.0.1:{cluster_port}")
        path = root / "openbao.hcl"
        path.write_text(config)
        for run in range(2):
            with (root / "server.log").open("w+") as log:
                process = subprocess.Popen(
                    [args.bao, "server", f"-config={path}"],
                    env={key: value for key, value in os.environ.items() if not key.startswith(("BAO_", "VAULT_", "NOTIFY_"))},
                    stdout=log, stderr=subprocess.STDOUT,
                )
                try:
                    for attempt in range(40):
                        if process.poll() is not None:
                            log.seek(0)
                            raise RuntimeError(f"Server exited: {log.read()}")
                        try:
                            response = opener.open(f"http://127.0.0.1:{api_port}/v1/sys/health", timeout=1)
                        except HTTPError as error:
                            response = error
                        except URLError:
                            time.sleep(0.1)
                            continue
                        with response:
                            health = json.load(response)
                            if response.status != 501 or health.get("initialized") is not False or health.get("sealed") is not True:
                                raise RuntimeError("Expected uninitialized, sealed server mode")
                        break
                    else:
                        raise RuntimeError("Server did not become available")
                finally:
                    process.terminate()
                    try:
                        process.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait(timeout=5)
            print(f"Local server start {run + 1}: sealed and uninitialized; no secrets created")


if __name__ == "__main__":
    main()
