#!/usr/bin/env python3
"""Read-only, bounded checks for the initial single-server cluster."""
import argparse
import json
import subprocess
import time
from urllib.parse import urlsplit


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--node-name', required=True)
    parser.add_argument('--expected-version', required=True)
    parser.add_argument('--api-server', required=True)
    parser.add_argument('--kubectl', default='/var/lib/rancher/rke2/bin/kubectl')
    parser.add_argument('--kubeconfig', default='/etc/rancher/rke2/rke2.yaml')
    parser.add_argument('--timeout', type=float, default=300)
    args = parser.parse_args()
    try:
        endpoint = urlsplit(args.api_server)
        endpoint.port
    except ValueError:
        parser.error('--api-server must be a valid HTTPS endpoint')
    if endpoint.scheme != 'https' or not endpoint.hostname or endpoint.username or endpoint.password or endpoint.query or endpoint.fragment:
        parser.error('--api-server must be an HTTPS endpoint without credentials or query parameters')
    if not 0 < args.timeout <= 900:
        parser.error('--timeout must be positive and at most 900 seconds')
    command = [args.kubectl, '--kubeconfig', args.kubeconfig, '--server', args.api_server, '--insecure-skip-tls-verify=false', '--request-timeout=10s']
    deadline = time.monotonic() + args.timeout
    reason = 'readiness checks did not complete'

    def request(*arguments):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError
        result = subprocess.run(command + list(arguments), capture_output=True, text=True, timeout=min(10, remaining), check=True)
        return result.stdout

    while time.monotonic() < deadline:
        try:
            if request('get', '--raw=/readyz').strip() != 'ok':
                raise ValueError('API is not ready')
            nodes = json.loads(request('get', 'nodes', '-o', 'json'))['items']
            servers = [n for n in nodes if 'node-role.kubernetes.io/control-plane' in n['metadata'].get('labels', {})]
            if len(servers) != 1 or servers[0]['metadata']['name'] != args.node_name:
                raise ValueError('expected exactly the initial control-plane node')
            node = servers[0]
            if node['status']['nodeInfo']['kubeletVersion'] != args.expected_version:
                raise ValueError('running Kubernetes version differs from the reviewed pin')
            if not any(c['type'] == 'Ready' and c['status'] == 'True' for c in node['status'].get('conditions', [])):
                raise ValueError('server node is not Ready')
            if not any(t['key'] == 'node-role.kubernetes.io/control-plane' and t['effect'] == 'NoSchedule' for t in node['spec'].get('taints', [])):
                raise ValueError('control-plane scheduling taint is missing')
            cilium = json.loads(request('-n', 'kube-system', 'get', 'daemonset', 'cilium', '-o', 'json'))
            status = cilium['status']
            if status.get('desiredNumberScheduled') != len(nodes) or status.get('numberReady') != len(nodes) or status.get('updatedNumberScheduled') != len(nodes) or status.get('observedGeneration', 0) < cilium['metadata']['generation']:
                raise ValueError('managed Cilium is not rolled out on all nodes')
            print('PASS: verified API endpoint, initial server identity/version/taint and Cilium readiness. Verify etcd membership separately.')
            return 0
        except ValueError as error:
            reason = str(error) if not isinstance(error, json.JSONDecodeError) else 'unexpected API response'
        except (subprocess.SubprocessError, OSError, TimeoutError, KeyError, TypeError):
            reason = 'command unavailable, API request failed, or unexpected response'
        time.sleep(min(2, max(0, deadline - time.monotonic())))
    print('FAIL: ' + reason + '; inspect protected guest logs locally.')
    return 1


if __name__ == '__main__':
    raise SystemExit(main())
