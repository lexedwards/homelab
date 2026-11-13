#!/usr/bin/env python3
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
from urllib.parse import urlsplit

import yaml


CHARTS = {
    'secrets-store-csi': ('driver_chart', '2658657164b156c7759772a84ba83013ae2495a0b2d2e92ea6b2ad0738f623c4'),
    'openbao-provider': ('provider_chart', 'fa4e6f3c1bbe936dc7ba079f1303ea56810af2f8600f046d8d5809860a4f980f'),
}
IMAGES = {
    'registry.k8s.io/csi-secrets-store/driver@sha256:939ef17f3840e0902fe5d6d16574bdc2e70636994ca0107f52bb3b9bc67df081',
    'registry.k8s.io/sig-storage/csi-node-driver-registrar@sha256:ab482308a4921e28a6df09a16ab99a457e9af9641ff44fb1be1a690d07ce8b70',
    'registry.k8s.io/sig-storage/livenessprobe@sha256:c4cc074199c045dd73ab85f28897e2a32f4d6f38ffdba4f3b13b8007ccbd3570',
    'quay.io/openbao/openbao-csi-provider:2.0.3@sha256:ad30d5f6223f30f62e8df6e444b84af5b05402a70c09712415dd1d7f139c027e',
}


def require(condition):
    if not condition:
        raise ValueError('Prepared CSI contract does not match the reviewed integration')


def enrollment_parameters(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd) as source:
        metadata = os.fstat(source.fileno())
        require(stat.S_ISREG(metadata.st_mode) and metadata.st_uid == os.getuid() and
                stat.S_IMODE(metadata.st_mode) in [0o400, 0o600] and metadata.st_size <= 1024 * 1024)
        documents = [d for d in yaml.safe_load_all(source) if d]
    classes = [d for d in documents if d['kind'] == 'SecretProviderClass']
    require(len(classes) == 1 and classes[0]['spec']['provider'] == 'openbao')
    require('secretObjects' not in classes[0]['spec'])
    parameters = classes[0]['spec']['parameters']
    require(set(parameters) == {'baoAddress', 'baoAuthMountPath', 'roleName', 'audience', 'objects'})
    audience = parameters['audience']
    require(isinstance(audience, str) and 0 < len(audience) <= 256 and not any(c.isspace() for c in audience))
    address = parameters['baoAddress']
    require(isinstance(address, str) and not any(c.isspace() for c in address))
    parsed = urlsplit(address)
    require(parsed.scheme == 'https' and parsed.hostname and parsed.username is None and parsed.password is None and
            parsed.path in ['', '/'] and not parsed.query and not parsed.fragment)
    require(parsed.port is None or 1 <= parsed.port <= 65535)
    return audience, address


def verify_rendered(driver_documents, provider_documents, audience, address):
    documents = driver_documents + provider_documents
    require(all(d['kind'] in ['CustomResourceDefinition', 'ServiceAccount', 'ClusterRole', 'ClusterRoleBinding',
                             'Role', 'RoleBinding', 'DaemonSet', 'CSIDriver'] for d in documents))
    drivers = [d for d in documents if d['kind'] == 'CSIDriver']
    require(len(drivers) == 1 and drivers[0]['metadata']['name'] == 'secrets-store.csi.k8s.io')
    spec = drivers[0]['spec']
    require(spec['volumeLifecycleModes'] == ['Ephemeral'] and spec['attachRequired'] is False and
            spec['podInfoOnMount'] is True and spec['requiresRepublish'] is True and spec['serviceAccountTokenInSecrets'] is True)
    require(spec['tokenRequests'] == [{'audience': audience, 'expirationSeconds': 600}])
    require({d['metadata']['name'] for d in documents if d['kind'] == 'CustomResourceDefinition'} == {
        'secretproviderclasses.secrets-store.csi.x-k8s.io', 'secretproviderclasspodstatuses.secrets-store.csi.x-k8s.io'})
    daemons = [d for d in documents if d['kind'] == 'DaemonSet']
    require(len(daemons) == 2)
    images = []
    for daemon in daemons:
        pod = daemon['spec']['template']['spec']
        require(pod['nodeSelector']['homelab.io/role'] == 'worker' and
                pod['nodeSelector']['homelab.node-restriction.kubernetes.io/secrets-ready'] == 'true')
        require(not pod.get('tolerations') and not pod.get('initContainers') and not pod.get('hostNetwork'))
        images.extend(c['image'] for c in pod['containers'])
    require(len(images) == 4 and set(images) == IMAGES)
    driver = next(d for d in daemons if any(c['name'] == 'secrets-store' for c in d['spec']['template']['spec']['containers']))
    pod = driver['spec']['template']['spec']
    plugin = next(c for c in pod['containers'] if c['name'] == 'secrets-store')
    require('--enable-secret-rotation=true' in plugin['args'] and '--rotation-poll-interval=2m' in plugin['args'])
    require(plugin['securityContext']['privileged'] is True)
    require(next(v for v in pod['volumes'] if v['name'] == 'mountpoint-dir')['hostPath']['path'] == '/var/lib/kubelet/pods')
    require(next(m for m in plugin['volumeMounts'] if m['name'] == 'mountpoint-dir')['mountPropagation'] == 'Bidirectional')
    for document in driver_documents:
        for rule in document.get('rules', []):
            require(not {'secrets', '*'}.intersection(rule.get('resources', [])))
    provider = next(d for d in provider_documents if d['kind'] == 'DaemonSet')['spec']['template']['spec']
    require(len(provider['containers']) == 1 and len(provider['volumes']) == 1)
    container = provider['containers'][0]
    security = container['securityContext']
    require(security['runAsUser'] == 0 and security['runAsGroup'] == 1000 and security['privileged'] is False and
            security['allowPrivilegeEscalation'] is False and security['readOnlyRootFilesystem'] is True and
            security['capabilities'] == {'drop': ['ALL']} and security['seccompProfile'] == {'type': 'RuntimeDefault'})
    require('--debug=false' in container['args'] and '-cache-size=0' in container['args'])
    require(container['env'] == [{'name': 'VAULT_ADDR', 'value': address}])
    require(provider['volumes'][0]['hostPath']['path'] == '/etc/kubernetes/secrets-store-csi-providers')
    cluster_roles = [d for d in provider_documents if d['kind'] == 'ClusterRole']
    require(len(cluster_roles) == 1 and cluster_roles[0]['rules'] == [
        {'apiGroups': [''], 'resources': ['serviceaccounts/token'], 'verbs': ['create']}])
    roles = [d for d in provider_documents if d['kind'] == 'Role']
    require(len(roles) == 1 and roles[0]['metadata']['namespace'] == 'secrets-system' and roles[0]['rules'] == [
        {'apiGroups': [''], 'resources': ['secrets'], 'verbs': ['get'], 'resourceNames': ['openbao-csi-provider-hmac-key']},
        {'apiGroups': [''], 'resources': ['secrets'], 'verbs': ['create']}])


def main():
    parser = argparse.ArgumentParser(description='Verify local pinned CSI/provider charts and prepare an embedded native installer; no network or deployment.')
    parser.add_argument('--driver-chart', type=Path, required=True)
    parser.add_argument('--provider-chart', type=Path, required=True)
    parser.add_argument('--enrollment', type=Path, required=True, help='Protected service-enrollment.yaml from prepare-secret-auth.py')
    parser.add_argument('--helm', default='helm')
    parser.add_argument('--output-dir', type=Path, help='New private directory outside this repository; omit for validation only')
    args = parser.parse_args()
    os.umask(0o077)
    audience, address = enrollment_parameters(args.enrollment)
    root = Path(__file__).resolve().parents[1]
    blueprint = (root / 'platform/secrets-csi.yaml.tftpl').read_text()
    for placeholder, value in [('api_audience', audience), ('bao_address', address)]:
        require(blueprint.count('${' + placeholder + '}') == 1)
        blueprint = blueprint.replace('${' + placeholder + '}', json.dumps(value))
    rendered = {}
    with tempfile.TemporaryDirectory() as directory:
        for name, path in [('secrets-store-csi', args.driver_chart), ('openbao-provider', args.provider_chart)]:
            placeholder, digest = CHARTS[name]
            archive = path.read_bytes()
            require(hashlib.sha256(archive).hexdigest() == digest)
            chart = next(d for d in yaml.safe_load_all(blueprint) if d['kind'] == 'HelmChart' and d['metadata']['name'] == name)
            require(chart['metadata']['annotations']['homelab.io/chart-sha256'] == digest)
            require('chart' not in chart['spec'] and 'repo' not in chart['spec'] and chart['spec']['chartContent'] == '${' + placeholder + '}')
            copied = Path(directory) / (name + '.tgz')
            copied.write_bytes(archive)
            values = Path(directory) / (name + '.yaml')
            values.write_text(chart['spec']['valuesContent'])
            result = subprocess.run([args.helm, 'template', name, str(copied), '--namespace', 'secrets-system',
                                     '--kube-version', '1.36.6', '--include-crds', '-f', str(values)],
                                    capture_output=True, text=True, timeout=60)
            require(result.returncode == 0)
            rendered[name] = [d for d in yaml.safe_load_all(result.stdout) if d]
            require(blueprint.count('${' + placeholder + '}') == 1)
            blueprint = blueprint.replace('${' + placeholder + '}', base64.b64encode(archive).decode())
    verify_rendered(rendered['secrets-store-csi'], rendered['openbao-provider'], audience, address)
    if args.output_dir:
        require(not args.output_dir.resolve().is_relative_to(root.parents[1]))
        args.output_dir.mkdir(mode=0o700)
        outputs = {'secrets-csi.yaml': blueprint, 'rendered.yaml': yaml.safe_dump_all(
            rendered['secrets-store-csi'] + rendered['openbao-provider'], sort_keys=False)}
        for name, content in outputs.items():
            fd = os.open(args.output_dir / name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            with os.fdopen(fd, 'w') as output:
                output.write(content)
    print('Pinned CSI/provider chart validation passed: worker-only placement, exact embedded bytes, scoped provider permissions and no workload-secret synchronization. No deployment performed.')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError, StopIteration, yaml.YAMLError, subprocess.SubprocessError):
        print('CSI/provider preparation failed. Check protected enrollment, pinned archives, Helm and the new output directory; no network operation was performed.', file=sys.stderr)
        sys.exit(1)
