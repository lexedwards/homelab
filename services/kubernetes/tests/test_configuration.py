from pathlib import Path
import re
import unittest

import yaml


class InputExampleTests(unittest.TestCase):
    def test_example_documents_every_input_without_active_values(self):
        root = Path(__file__).resolve().parents[1]
        example = (root / 'terraform.tfvars.example').read_text()
        self.assertTrue(all(not line.strip() or line.lstrip().startswith('#') for line in example.splitlines()))
        declared = set(re.findall(r'^variable "([^"]+)"', (root / 'variables.tf').read_text(), re.M))
        documented = set(re.findall(r'^# ([a-z][a-z0-9_]*)\s*=', example, re.M))
        self.assertEqual(declared, documented)
        self.assertNotIn('proxmox_api_token', declared)


class KataRolloutTests(unittest.TestCase):
    def setUp(self):
        root = Path(__file__).resolve().parents[1]
        documents = yaml.safe_load_all((root / 'platform/kata.yaml').read_text())
        self.chart = next(document for document in documents if document['kind'] == 'HelmChart')

    def test_failed_helm_job_aborts_without_automatic_retries(self):
        for field, expected in [('failurePolicy', 'abort'), ('backOffLimit', 0)]:
            with self.subTest(field=field):
                self.assertEqual(self.chart['spec'].get(field), expected)

    def test_install_selection_keeps_the_full_worker_set(self):
        values = yaml.safe_load(self.chart['spec']['valuesContent'])
        self.assertEqual(values['nodeSelector'], {'homelab.io/role': 'worker', 'kubernetes.io/arch': 'amd64'})
        self.assertNotIn('nodes', values['job'])
        self.assertEqual(values['job']['parallelism'], 1)
