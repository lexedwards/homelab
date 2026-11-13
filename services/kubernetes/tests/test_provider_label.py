import importlib.util
from pathlib import Path
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/label-secrets-provider.py'


class ProviderLabelTests(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location('provider_label', SCRIPT)
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name) / 'provider'
        self.calls = []
        self.mapping = ''

    def fake_run(self, args):
        self.calls.append(args)
        if args == ['semanage', 'fcontext', '-l', '-C']:
            return self.mapping
        if args[0] in ['stat', 'matchpathcon']:
            return 'system_u:object_r:container_file_t:s0'
        return ''

    def test_check_does_not_create_a_directory_or_mapping(self):
        with self.assertRaises(ValueError):
            self.module.configure_provider(self.path, self.fake_run, apply=False)
        self.assertFalse(self.path.exists())
        self.assertFalse(any(c[0] == 'restorecon' or '-a' in c for c in self.calls))

    def test_apply_adds_only_the_exact_persistent_mapping_and_restores_only_that_directory(self):
        self.module.configure_provider(self.path, self.fake_run, apply=True)
        self.assertTrue(self.path.is_dir())
        self.assertIn(['semanage', 'fcontext', '-a', '-t', 'container_file_t', '-r', 's0', str(self.path) + '(/.*)?'], self.calls)
        self.assertIn(['restorecon', '-RF', str(self.path)], self.calls)
        self.assertFalse(any('-m' in c or '-d' in c or c[0] == 'setenforce' for c in self.calls))

    def test_conflicting_exact_mapping_is_preserved_without_relabel(self):
        self.mapping = str(self.path) + '(/.*)?  all files  system_u:object_r:var_t:s0\n'
        with self.assertRaises(ValueError):
            self.module.configure_provider(self.path, self.fake_run, apply=True)
        self.assertFalse(self.path.exists())
        self.assertFalse(any(c[0] == 'restorecon' or '-a' in c for c in self.calls))

    def test_refuses_symlinks_and_unrelated_provider_contents(self):
        self.path.symlink_to(Path(self.directory.name), target_is_directory=True)
        with self.assertRaises(ValueError):
            self.module.configure_provider(self.path, self.fake_run, apply=True)
        self.assertEqual(self.calls, [])
        self.path.unlink()
        self.path.mkdir()
        marker = self.path / 'unrelated'
        marker.write_text('preserve')
        with self.assertRaises(ValueError):
            self.module.configure_provider(self.path, self.fake_run, apply=True)
        self.assertEqual(marker.read_text(), 'preserve')
        self.assertFalse(any(c[0] == 'restorecon' or '-a' in c for c in self.calls))


if __name__ == '__main__':
    unittest.main()
