from pathlib import Path
import re
import unittest


class InputExampleTests(unittest.TestCase):
    def test_example_documents_every_input_without_active_values(self):
        root = Path(__file__).resolve().parents[1]
        example = (root / 'terraform.tfvars.example').read_text()
        self.assertTrue(all(not line.strip() or line.lstrip().startswith('#') for line in example.splitlines()))
        declared = set(re.findall(r'^variable "([^"]+)"', (root / 'variables.tf').read_text(), re.M))
        documented = set(re.findall(r'^# ([a-z][a-z0-9_]*)\s*=', example, re.M))
        self.assertEqual(declared, documented)
        self.assertNotIn('proxmox_api_token', declared)
