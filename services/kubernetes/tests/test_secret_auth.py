import copy
import json
from pathlib import Path
import ssl
import stat
import subprocess
import sys
import tempfile
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'scripts/prepare-secret-auth.py'


class SecretAuthPreparationTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.work = Path(self.directory.name)
        self.source = self.work / 'auth.json'
        self.destination = self.work / 'prepared'
        certificate = ssl.create_default_context().get_ca_certs(binary_form=True)[0]
        self.config = {
            'openbao_address': 'https://bao.example.invalid:8200',
            'kubernetes_host': 'https://api.example.invalid:6443',
            'kubernetes_ca_cert': ssl.DER_cert_to_PEM_cert(certificate),
            'api_audience': 'https://kubernetes.default.svc.cluster.local',
            'auth_mount': 'kubernetes-test',
            'service': {
                'namespace': 'demo',
                'service_account': 'reader',
                'role': 'demo-reader',
                'policy': 'demo-reader',
                'provider_class': 'demo-files',
                'objects': [
                    {'file_name': 'password', 'secret_path': 'apps/data/demo', 'secret_key': 'password'},
                    {'file_name': 'username', 'secret_path': 'apps/data/demo', 'secret_key': 'username'},
                ],
            },
        }

    def prepare(self, config=None, mode=0o600):
        self.source.write_text(json.dumps(self.config if config is None else config))
        self.source.chmod(mode)
        return subprocess.run([sys.executable, '-B', str(SCRIPT), '--input', str(self.source),
                               '--output-dir', str(self.destination)], capture_output=True, text=True, timeout=10)

    def test_prepares_exact_auth_policy_and_reviewer_without_credentials_or_secret_sync(self):
        result = self.prepare()
        self.assertEqual(result.returncode, 0, result.stderr)
        auth = json.loads((self.destination / 'platform-auth-config.json').read_text())
        self.assertEqual(auth, {
            'kubernetes_host': 'https://api.example.invalid:6443',
            'kubernetes_ca_cert': self.config['kubernetes_ca_cert'],
            'token_reviewer_jwt': '',
            'disable_local_ca_jwt': True,
            'disable_iss_validation': True,
        })
        role = json.loads((self.destination / 'service-role.json').read_text())
        self.assertEqual(role['bound_service_account_names'], ['reader'])
        self.assertEqual(role['bound_service_account_namespaces'], ['demo'])
        self.assertEqual(role['audience'], self.config['api_audience'])
        self.assertEqual(role['token_policies'], ['demo-reader'])
        self.assertEqual(role['token_ttl'], 300)
        self.assertEqual(role['token_max_ttl'], 600)
        self.assertIs(role['token_no_default_policy'], True)
        self.assertEqual((self.destination / 'service-policy.hcl').read_text(),
                         'path "apps/data/demo" {\n  capabilities = ["read"]\n}\n')
        platform = yaml.safe_load((self.destination / 'platform-tokenreview-role.yaml').read_text())
        self.assertEqual(platform['rules'], [{'apiGroups': ['authentication.k8s.io'],
                                             'resources': ['tokenreviews'], 'verbs': ['create']}])
        documents = list(yaml.safe_load_all((self.destination / 'service-enrollment.yaml').read_text()))
        binding = next(d for d in documents if d['kind'] == 'ClusterRoleBinding')
        self.assertEqual(binding['subjects'], [{'kind': 'ServiceAccount', 'name': 'reader', 'namespace': 'demo'}])
        self.assertEqual(binding['roleRef']['name'], platform['metadata']['name'])
        provider = next(d for d in documents if d['kind'] == 'SecretProviderClass')
        self.assertNotIn('secretObjects', provider['spec'])
        self.assertEqual(provider['spec']['provider'], 'openbao')
        self.assertEqual(provider['metadata']['namespace'], 'demo')
        parameters = provider['spec']['parameters']
        self.assertEqual(parameters['audience'], role['audience'])
        self.assertEqual(parameters['baoAuthMountPath'], 'kubernetes-test')
        self.assertEqual(parameters['roleName'], 'demo-reader')
        self.assertEqual(parameters['baoAddress'], self.config['openbao_address'])
        self.assertEqual(yaml.safe_load(parameters['objects']), [
            {'objectName': 'password', 'secretPath': 'apps/data/demo', 'secretKey': 'password', 'filePermission': 292},
            {'objectName': 'username', 'secretPath': 'apps/data/demo', 'secretKey': 'username', 'filePermission': 292},
        ])
        self.assertEqual(stat.S_IMODE(self.destination.stat().st_mode), 0o700)
        for path in self.destination.iterdir():
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        self.assertNotIn('bao.example.invalid', result.stdout + result.stderr)

    def test_rejects_broad_or_ambiguous_scopes_before_creating_artifacts(self):
        changes = [
            ('namespace wildcard', lambda c: c['service'].update(namespace='*')),
            ('account list', lambda c: c['service'].update(service_account='reader,other')),
            ('policy wildcard', lambda c: c['service']['objects'][0].update(secret_path='apps/data/*')),
            ('policy prefix', lambda c: c['service']['objects'][0].update(secret_path='apps/data/demo+')),
            ('path traversal', lambda c: c['service']['objects'][0].update(secret_path='apps/data/../other')),
            ('path query', lambda c: c['service']['objects'][0].update(secret_path='apps/data/demo?version=1')),
            ('non-KV path', lambda c: c['service']['objects'][0].update(secret_path='sys/policies/acl/root')),
            ('filename traversal', lambda c: c['service']['objects'][0].update(file_name='../password')),
            ('duplicate file', lambda c: c['service']['objects'][1].update(file_name='password')),
            ('no objects', lambda c: c['service'].update(objects=[])),
            ('plaintext OpenBao', lambda c: c.update(openbao_address='http://bao.example.invalid')),
            ('plaintext API', lambda c: c.update(kubernetes_host='http://api.example.invalid')),
            ('URL credentials', lambda c: c.update(openbao_address='https://token@bao.example.invalid')),
            ('URL query', lambda c: c.update(openbao_address='https://bao.example.invalid?token=x')),
            ('invalid secret-like port', lambda c: c.update(openbao_address='https://bao.example.invalid:sensitive-marker')),
            ('invalid CA', lambda c: c.update(kubernetes_ca_cert='not a CA')),
            ('CA with private key', lambda c: c.update(kubernetes_ca_cert=c['kubernetes_ca_cert'] + '\n-----BEGIN PRIVATE KEY-----\nsensitive-marker\n-----END PRIVATE KEY-----\n')),
            ('missing audience', lambda c: c.update(api_audience='')),
            ('root credential', lambda c: c.update(token='sensitive-marker')),
            ('object secret', lambda c: c['service']['objects'][0].update(value='sensitive-marker')),
            ('role override', lambda c: c['service'].update(token_policies=['root'])),
        ]
        for name, change in changes:
            with self.subTest(name=name):
                config = copy.deepcopy(self.config)
                change(config)
                result = self.prepare(config)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.destination.exists())
                self.assertNotIn('sensitive-marker', result.stdout + result.stderr)
                self.assertNotIn('bao.example.invalid', result.stdout + result.stderr)

    def test_refuses_unprotected_input_and_symlinks(self):
        result = self.prepare(mode=0o644)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.destination.exists())
        original = self.work / 'original.json'
        self.source.rename(original)
        original.chmod(0o600)
        self.source.symlink_to(original)
        result = subprocess.run([sys.executable, '-B', str(SCRIPT), '--input', str(self.source),
                                 '--output-dir', str(self.destination)], capture_output=True, text=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.destination.exists())

    def test_never_overwrites_prepared_artifacts(self):
        self.destination.mkdir(mode=0o700)
        marker = self.destination / 'service-policy.hcl'
        marker.write_text('preserve existing work')
        result = self.prepare()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(marker.read_text(), 'preserve existing work')
        self.assertEqual(list(self.destination.iterdir()), [marker])

    def test_rejects_duplicate_json_fields(self):
        self.source.write_text('{"api_audience":"one","api_audience":"sensitive-marker"}')
        self.source.chmod(0o600)
        result = subprocess.run([sys.executable, '-B', str(SCRIPT), '--input', str(self.source),
                                 '--output-dir', str(self.destination)], capture_output=True, text=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('sensitive-marker', result.stdout + result.stderr)
        self.assertFalse(self.destination.exists())

    def test_different_namespace_account_pairs_have_distinct_binding_names(self):
        self.config['service'].update(namespace='one-two', service_account='three')
        self.assertEqual(self.prepare().returncode, 0)
        first = next(d['metadata']['name'] for d in yaml.safe_load_all(
            (self.destination / 'service-enrollment.yaml').read_text()) if d['kind'] == 'ClusterRoleBinding')
        self.destination = self.work / 'second'
        self.config['service'].update(namespace='one', service_account='two-three')
        self.assertEqual(self.prepare().returncode, 0)
        second = next(d['metadata']['name'] for d in yaml.safe_load_all(
            (self.destination / 'service-enrollment.yaml').read_text()) if d['kind'] == 'ClusterRoleBinding')
        self.assertNotEqual(first, second)

    def test_prepared_artifacts_cannot_be_written_inside_repository(self):
        self.destination = ROOT / 'private-test-must-not-exist'
        self.assertFalse(self.destination.exists())
        result = self.prepare()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.destination.exists())


if __name__ == '__main__':
    unittest.main()
