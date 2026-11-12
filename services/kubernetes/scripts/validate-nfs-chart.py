#!/usr/bin/env python3
import argparse
import base64
import hashlib
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

import yaml


def require(condition, message):
    if not condition:
        raise ValueError(message)


def main():
    parser = argparse.ArgumentParser(description='Verify and render the pinned upstream NFS chart locally; no cluster or network access.')
    parser.add_argument('--chart', type=Path, required=True, help='Previously downloaded csi-driver-nfs 4.13.6 archive')
    parser.add_argument('--helm', default='helm', help='Helm executable (default: helm)')
    parser.add_argument('--output', type=Path, help='New mode-0600 native deployment manifest with the verified archive embedded')
    args = parser.parse_args()
    archive = args.chart.read_bytes()
    digest = hashlib.sha256(archive).hexdigest()
    require(digest == '4b471fb134bfea4fcaa3dc3342a67acd646431b746c673c978327353db5d22da', 'Chart archive does not match the reviewed 4.13.6 checksum')
    root = Path(__file__).resolve().parents[1]
    blueprint = (root / 'platform/nfs.yaml.tftpl').read_text()
    chart = next(d for d in yaml.safe_load_all(blueprint) if d['kind'] == 'HelmChart')
    require(chart['metadata']['annotations']['homelab.io/chart-sha256'] == digest, 'Blueprint checksum differs from verified archive')
    require('chart' not in chart['spec'] and 'repo' not in chart['spec'] and chart['spec']['chartContent'] == '${chart_content}', 'Installer must use only embedded reviewed bytes')
    with tempfile.TemporaryDirectory() as directory:
        verified_chart = Path(directory) / 'verified-chart.tgz'
        verified_chart.write_bytes(archive)
        values = Path(directory) / 'values.yaml'
        values.write_text(chart['spec']['valuesContent'])
        result = subprocess.run([args.helm, 'template', 'nfs-csi', str(verified_chart), '--namespace', 'nfs-system',
                                 '--kube-version', '1.36.6', '--include-crds', '-f', str(values)],
                                capture_output=True, text=True, timeout=60)
    require(result.returncode == 0, 'Helm rendering failed; no deployment was attempted')
    documents = [d for d in yaml.safe_load_all(result.stdout) if d]
    require(not any(d['kind'] in ['StorageClass', 'VolumeSnapshotClass', 'CustomResourceDefinition'] for d in documents), 'Chart renders unapproved storage or snapshot resources')
    controllers = [d for d in documents if d['kind'] == 'Deployment']
    nodes = [d for d in documents if d['kind'] == 'DaemonSet']
    require(len(controllers) == len(nodes) == 1, 'Expected one CSI controller Deployment and one node DaemonSet')
    require(controllers[0]['spec']['replicas'] == 1, 'Controller must retain one replica')
    for workload in controllers + nodes:
        spec = workload['spec']['template']['spec']
        require(spec['nodeSelector'].get('homelab.io/role') == 'worker', 'CSI components must select only workers')
        require(spec.get('hostNetwork') is True, 'Native NFS clients must retain the reviewed host-network path')
        require(spec['securityContext']['seccompProfile']['type'] == 'RuntimeDefault', 'CSI pod seccomp must remain RuntimeDefault')
        for container in spec['containers']:
            require(re.fullmatch(r'registry\.k8s\.io/sig-storage/[a-z0-9-]+:v[0-9.]+@sha256:[0-9a-f]{64}', container['image']), 'Rendered image is not digest-pinned upstream storage code')
            require(container['name'] != 'csi-snapshotter', 'Snapshot sidecar must stay disabled')
        plugin = next(c for c in spec['containers'] if c['name'] == 'nfs')
        require('--mount-permissions=0' in plugin['args'], 'Global mount-permissions fallback must remain zero')
        if workload['kind'] == 'Deployment':
            require('--default-ondelete-policy=retain' in plugin['args'], 'Controller deletion fallback must retain data')
    driver = next(d for d in documents if d['kind'] == 'CSIDriver')
    require(driver['metadata']['name'] == 'nfs.csi.k8s.io', 'Unexpected CSI driver identity')
    require(driver['spec']['fsGroupPolicy'] == 'None', 'Kubelet must not recursively chown root-squashed storage')
    require(driver['spec']['attachRequired'] is False and driver['spec']['volumeLifecycleModes'] == ['Persistent'], 'Unexpected attachment or inline-volume lifecycle')
    if args.output:
        require(blueprint.count('${chart_content}') == 1, 'Unexpected native manifest template')
        manifest = blueprint.replace('${chart_content}', base64.b64encode(archive).decode())
        fd = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, 'w') as output:
            output.write(manifest)
    print('Pinned NFS chart render passed: worker-only placement, digest-pinned images, retained deletion and no recursive ownership or implicit snapshot/storage stack.')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError, StopIteration, yaml.YAMLError, subprocess.SubprocessError):
        print('NFS chart validation failed. Check the archive checksum, Helm availability and rendered chart contract; no cluster operation was performed.', file=sys.stderr)
        sys.exit(1)
