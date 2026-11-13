import copy
import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

import yaml


SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/prepare-secrets-csi.py'


class SecretCSIPreparationTests(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location('csi_preparation', SCRIPT)
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.work = Path(self.directory.name)
        self.enrollment = self.work / 'service-enrollment.yaml'
        self.chart = self.work / 'wrong.tgz'
        self.chart.write_bytes(b'not the reviewed upstream archive')
        self.output = self.work / 'prepared'
        self.provider = {'apiVersion': 'secrets-store.csi.x-k8s.io/v1', 'kind': 'SecretProviderClass',
                         'metadata': {'name': 'files', 'namespace': 'demo'},
                         'spec': {'provider': 'openbao', 'parameters': {
                             'baoAddress': 'https://bao.example.invalid:8200', 'baoAuthMountPath': 'kubernetes-test',
                             'roleName': 'demo', 'audience': 'api-test', 'objects': '[]'}}}

    def prepare(self, provider=None, mode=0o600):
        self.enrollment.write_text(yaml.safe_dump(self.provider if provider is None else provider))
        self.enrollment.chmod(mode)
        return subprocess.run([sys.executable, '-B', str(SCRIPT), '--driver-chart', str(self.chart),
                               '--provider-chart', str(self.chart), '--enrollment', str(self.enrollment),
                               '--helm', '/must-not-run-helm-before-validation', '--output-dir', str(self.output)],
                              capture_output=True, text=True, timeout=10)

    def test_changed_chart_bytes_never_produce_a_deployable_installer(self):
        result = self.prepare()
        self.assertEqual(result.returncode, 1)
        self.assertFalse(self.output.exists())
        self.assertNotIn('bao.example.invalid', result.stdout + result.stderr)

    def test_refuses_secret_sync_insecure_parameters_and_unprotected_enrollment(self):
        changes = [
            lambda p: p['spec'].update(secretObjects=[]),
            lambda p: p['spec']['parameters'].update(baoSkipTLSVerify='true'),
            lambda p: p['spec']['parameters'].update(baoAddress='http://sensitive-marker.invalid'),
            lambda p: p['spec']['parameters'].update(audience='injected\nvalue'),
            lambda p: p['spec']['parameters'].update(baoAddress='https://user:sensitive-marker@bao.example.invalid'),
        ]
        for change in changes:
            with self.subTest(change=change):
                provider = copy.deepcopy(self.provider)
                change(provider)
                result = self.prepare(provider)
                self.assertEqual(result.returncode, 1)
                with self.assertRaises(ValueError):
                    self.module.enrollment_parameters(self.enrollment)
                self.assertFalse(self.output.exists())
                self.assertNotIn('sensitive-marker', result.stdout + result.stderr)
                self.assertNotIn('bao.example.invalid', result.stdout + result.stderr)
        self.assertEqual(self.prepare(mode=0o644).returncode, 1)
        with self.assertRaises(ValueError):
            self.module.enrollment_parameters(self.enrollment)
        self.assertFalse(self.output.exists())

    def test_reads_the_same_audience_and_https_origin_without_accepting_input_symlinks(self):
        self.prepare()
        self.assertEqual(self.module.enrollment_parameters(self.enrollment), ('api-test', 'https://bao.example.invalid:8200'))
        original = self.work / 'original.yaml'
        self.enrollment.rename(original)
        self.enrollment.symlink_to(original)
        with self.assertRaises(OSError):
            self.module.enrollment_parameters(self.enrollment)


if __name__ == '__main__':
    unittest.main()
