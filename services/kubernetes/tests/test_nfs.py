from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

import yaml


class NfsDriverTests(unittest.TestCase):
    def setUp(self):
        root = Path(__file__).resolve().parents[1]
        self.documents = list(yaml.safe_load_all((root / 'platform/nfs.yaml').read_text()))
        self.chart = next(d for d in self.documents if d['kind'] == 'HelmChart')
        self.values = yaml.safe_load(self.chart['spec']['valuesContent'])

    def test_native_chart_is_pinned_and_aborts_failed_installation(self):
        self.assertIn('/v4.13.6/', self.chart['spec']['chart'])
        self.assertTrue(self.chart['spec']['chart'].endswith('/csi-driver-nfs-4.13.6.tgz'))
        self.assertEqual(self.chart['metadata']['namespace'], 'kube-system')
        self.assertEqual(self.chart['spec']['targetNamespace'], 'nfs-system')
        self.assertEqual(self.chart['spec']['failurePolicy'], 'abort')
        self.assertEqual(self.chart['spec']['backOffLimit'], 0)

    def test_only_workers_mount_nfs_without_recursive_ownership_changes(self):
        for component in ['controller', 'node']:
            self.assertEqual(self.values[component]['nodeSelector'], {'homelab.io/role': 'worker'})
        self.assertEqual(self.values['controller']['replicas'], 1)
        self.assertFalse(self.values['controller']['runOnControlPlane'])
        self.assertFalse(self.values['controller']['runOnMaster'])
        self.assertEqual(self.values['driver']['mountPermissions'], 0)
        self.assertEqual(self.values['feature']['fsGroupPolicy'], 'None')
        self.assertEqual(self.values['controller']['defaultOnDeletePolicy'], 'retain')

    def test_no_implicit_default_storage_or_snapshot_stack(self):
        self.assertFalse(self.values['storageClass']['create'])
        self.assertFalse(self.values['controller']['enableSnapshotter'])
        self.assertFalse(self.values['externalSnapshotter']['enabled'])
        self.assertFalse(self.values['externalSnapshotter']['customResourceDefinitions']['enabled'])
        self.assertFalse(self.values['volumeSnapshotClass']['create'])
        self.assertFalse(self.values['feature']['enableInlineVolume'])

    def test_all_used_upstream_images_are_digest_pinned(self):
        for component in ['nfs', 'csiProvisioner', 'csiResizer', 'livenessProbe', 'nodeDriverRegistrar']:
            with self.subTest(component=component):
                image = self.values['image'][component]
                self.assertTrue(image['repository'].startswith('registry.k8s.io/sig-storage/'))
                self.assertRegex(image['tag'], r'^v[0-9.]+@sha256:[0-9a-f]{64}$')

    def test_unverified_chart_is_rejected_before_running_helm(self):
        root = Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            archive = directory / 'unverified.tgz'
            archive.write_bytes(b'not-the-reviewed-upstream-chart')
            marker = directory / 'helm-was-called'
            helm = directory / 'helm'
            helm.write_text('#!' + sys.executable + '\nfrom pathlib import Path\nPath(' + repr(str(marker)) + ').touch()\n')
            helm.chmod(0o700)
            result = subprocess.run([sys.executable, '-B', str(root / 'scripts/validate-nfs-chart.py'),
                                     '--chart', str(archive), '--helm', str(helm)], capture_output=True, text=True, timeout=10)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(marker.exists())
