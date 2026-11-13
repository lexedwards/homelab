import importlib.util
import json
from pathlib import Path
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request

import yaml


ROOT = Path(__file__).resolve().parents[1]


class SecretCSIContractTests(unittest.TestCase):
    def test_qualification_default_deny_uses_api_canonical_empty_rules(self):
        policy = next(document for document in yaml.safe_load_all((ROOT / 'examples/secrets-workloads.yaml').read_text())
                      if document['kind'] == 'NetworkPolicy')
        self.assertEqual(policy['spec'], {'podSelector': {}, 'policyTypes': ['Ingress', 'Egress']})

    def test_native_chart_fields_match_helm_controller_serialization(self):
        charts = [document for document in yaml.safe_load_all((ROOT / 'platform/secrets-csi.yaml.tftpl').read_text())
                  if document['kind'] == 'HelmChart']
        for chart in charts:
            with self.subTest(chart=chart['metadata']['name']):
                self.assertNotIn('createNamespace', chart['spec'])
                self.assertEqual(chart['spec']['timeout'], '10m0s')

    def test_native_charts_are_embedded_worker_only_without_secret_sync_or_agent(self):
        text = (ROOT / 'platform/secrets-csi.yaml.tftpl').read_text()
        charts = [d for d in yaml.safe_load_all(text) if d['kind'] == 'HelmChart']
        self.assertEqual(len(charts), 2)
        values = {d['metadata']['name']: yaml.safe_load(d['spec']['valuesContent']) for d in charts}
        for chart in charts:
            self.assertIn('chartContent', chart['spec'])
            self.assertNotIn('repo', chart['spec'])
            self.assertNotIn('chart', chart['spec'])
            self.assertEqual(chart['spec']['targetNamespace'], 'secrets-system')
            self.assertEqual(chart['spec']['failurePolicy'], 'abort')
        driver = values['secrets-store-csi']
        self.assertFalse(driver['syncSecret']['enabled'])
        self.assertFalse(driver['windows']['enabled'])
        self.assertFalse(driver['linux']['crds']['enabled'])
        self.assertTrue(driver['enableSecretRotation'])
        self.assertEqual(driver['rotationPollInterval'], '2m')
        self.assertEqual(driver['tokenRequests'][0]['expirationSeconds'], 600)
        provider = values['openbao-provider']
        for component in ['server', 'injector']:
            self.assertFalse(provider[component]['enabled'])
        self.assertFalse(provider['csi']['agent']['enabled'])
        self.assertFalse(provider['csi']['debug'])
        for selector in [driver['linux']['nodeSelector'], provider['csi']['pod']['nodeSelector']]:
            self.assertEqual(selector, {'homelab.io/role': 'worker',
                                       'homelab.node-restriction.kubernetes.io/secrets-ready': 'true'})
        security = provider['csi']['daemonSet']['securityContext']['container']
        self.assertFalse(security['privileged'])
        self.assertFalse(security['allowPrivilegeEscalation'])
        self.assertTrue(security['readOnlyRootFilesystem'])
        self.assertEqual(security['capabilities']['drop'], ['ALL'])
        self.assertEqual(security['seccompProfile']['type'], 'RuntimeDefault')

    def test_qualification_is_nonroot_readonly_and_spread_over_two_verified_workers(self):
        documents = list(yaml.safe_load_all((ROOT / 'examples/secrets-workloads.yaml').read_text()))
        deployments = [d for d in documents if d['kind'] == 'Deployment']
        self.assertEqual(len(deployments), 2)
        for deployment in deployments:
            spec = deployment['spec']['template']['spec']
            self.assertEqual(deployment['spec']['replicas'], 2)
            self.assertEqual(spec['serviceAccountName'], 'reader')
            self.assertFalse(spec['automountServiceAccountToken'])
            self.assertTrue(spec['securityContext']['runAsNonRoot'])
            self.assertGreater(spec['securityContext']['runAsUser'], 0)
            self.assertEqual(spec['nodeSelector']['homelab.node-restriction.kubernetes.io/secrets-ready'], 'true')
            self.assertEqual(spec['topologySpreadConstraints'][0]['minDomains'], 2)
            self.assertEqual(spec['topologySpreadConstraints'][0]['whenUnsatisfiable'], 'DoNotSchedule')
            mount = next(m for m in spec['containers'][0]['volumeMounts'] if m['name'] == 'secrets')
            self.assertTrue(mount['readOnly'])
            self.assertNotIn('subPath', mount)
            volume = next(v for v in spec['volumes'] if v['name'] == 'secrets')
            self.assertEqual(volume['csi'], {'driver': 'secrets-store.csi.k8s.io', 'readOnly': True,
                                            'volumeAttributes': {'secretProviderClass': 'qualification-files'}})
            if deployment['metadata']['name'] == 'isolated':
                self.assertEqual(spec['runtimeClassName'], 'kata-clh-runtime-rs')
            else:
                self.assertNotIn('runtimeClassName', spec)


class SecretReloadApplicationTests(unittest.TestCase):
    def setUp(self):
        path = ROOT / 'examples/secret-reload.py'
        spec = importlib.util.spec_from_file_location('secret_reload', path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.secret = Path(self.directory.name) / 'value'
        self.server = module.ReloadingServer(('127.0.0.1', 0), self.secret)
        thread = threading.Thread(target=self.server.serve_forever, kwargs={'poll_interval': 0.01}, daemon=True)
        thread.start()
        self.addCleanup(thread.join, 2)
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        self.url = 'http://127.0.0.1:' + str(self.server.server_port)

    def request(self, path, value=None):
        request = urllib.request.Request(self.url + path, data=value)
        with urllib.request.urlopen(request, timeout=2) as response:
            return json.loads(response.read())

    def wait_version(self, value):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            try:
                result = self.request('/verify', value)
                if result['matches']:
                    return result
            except urllib.error.HTTPError as error:
                self.assertEqual(error.code, 503)
                error.close()
            time.sleep(0.05)
        self.fail('Application did not load the new secret')

    def test_initial_load_and_atomic_file_rotation_change_actual_in_memory_application_state(self):
        with self.assertRaises(urllib.error.HTTPError) as missing:
            self.request('/ready')
        self.assertEqual(missing.exception.code, 503)
        missing.exception.close()
        self.secret.write_bytes(b'first-synthetic-value')
        first = self.wait_version(b'first-synthetic-value')
        replacement = self.secret.with_name('replacement')
        replacement.write_bytes(b'second-synthetic-value')
        replacement.replace(self.secret)
        second = self.wait_version(b'second-synthetic-value')
        self.assertGreater(second['reloads'], first['reloads'])
        self.assertFalse(self.request('/verify', b'first-synthetic-value')['matches'])
        self.assertEqual(self.request('/ready'), {'ready': True})
        self.assertEqual(set(second), {'matches', 'reloads'})
        self.assertEqual(self.secret.read_bytes(), b'second-synthetic-value')
        self.assertEqual(list(Path(self.directory.name).iterdir()), [self.secret])

    def test_existing_loaded_state_survives_a_missing_file_without_claiming_refresh(self):
        self.secret.write_bytes(b'available-before-outage')
        before = self.wait_version(b'available-before-outage')
        self.secret.unlink()
        time.sleep(1.2)
        after = self.request('/verify', b'available-before-outage')
        self.assertEqual(after, before)


if __name__ == '__main__':
    unittest.main()
