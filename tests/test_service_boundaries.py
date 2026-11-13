import importlib.util
from pathlib import Path
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/check-service-boundaries.py'


class ServiceBoundaryTests(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location('boundaries', SCRIPT)
        self.boundaries = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.boundaries)
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)

    def check(self, path, source):
        return self.boundaries.check_file(self.root, self.root / path, source)

    def test_service_cannot_import_another_services_module(self):
        errors = self.check('services/app/runtime/main.tf', 'source = "../../bao/modules/access"')
        self.assertEqual(len(errors), 1)
        self.assertIn('services/bao', errors[0])

    def test_service_cannot_read_foreign_state_or_templates(self):
        for filename in ['terraform.tfstate', 'cloud-init/user-data.tftpl']:
            with self.subTest(filename=filename):
                errors = self.check('services/app/runtime/main.tf', f'path = "${{path.module}}/../../bao/{filename}"')
                self.assertEqual(len(errors), 1)

    def test_json_configuration_cannot_hide_a_cross_service_source(self):
        errors = self.check('services/app/main.tf.json', '{"module":{"bad":{"source":"../bao/modules/private"}}}')
        self.assertEqual(len(errors), 1)

    def test_service_can_use_private_code_and_shared_modules(self):
        source = 'source = "../modules/private"\nsource = "../../../modules/shared"'
        self.assertEqual(self.check('services/app/runtime/main.tf', source), [])

    def test_shared_module_cannot_depend_on_a_service(self):
        errors = self.check('modules/shared/main.tf', 'source = "../../services/bao/modules/private"')
        self.assertEqual(len(errors), 1)

    def test_test_module_sources_resolve_from_the_configuration_root(self):
        source = 'module { source = "../../../modules/shared" }'
        self.assertEqual(self.check('services/app/runtime/tests/access.tftest.hcl', source), [])

    def test_provider_addresses_and_same_service_state_are_not_cross_service_imports(self):
        source = 'source = "hashicorp/vault"\npath = "${path.module}/../terraform.tfstate"'
        self.assertEqual(self.check('services/app/runtime/main.tf', source), [])


if __name__ == '__main__':
    unittest.main()
