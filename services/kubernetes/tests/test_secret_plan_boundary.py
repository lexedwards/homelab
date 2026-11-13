from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import threading
import unittest
import uuid
import zipfile


ROOT = Path(__file__).resolve().parents[1]


class ProviderFixture(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def do_GET(self):
        self.server.methods.append('GET')
        document = {'version': '2.7.2', 'initialized': True, 'sealed': False,
                    'data': {'id': 'synthetic', 'ttl': 3600, 'policies': ['synthetic-setup']}}
        if self.path.startswith('/v1/sys/policies/acl/'):
            document = {'data': {'policy': self.server.policy}}
        body = json.dumps(document).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        self.server.methods.append('POST')
        self.send_error(405)

    def do_PUT(self):
        self.server.methods.append('PUT')
        self.server.policy = json.loads(self.rfile.read(int(self.headers['Content-Length'])))['policy']
        self.send_response(204)
        self.end_headers()


class SecretPlanBoundaryTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.work = Path(self.directory.name)
        binaries = list((ROOT / '.terraform/providers').glob('*/hashicorp/vault/5.13.0/*/terraform-provider-vault*'))
        self.assertEqual(len(binaries), 1, 'Initialize the pinned root providers before make validate')
        self.cli = self.work / 'tofurc'
        self.cli.write_text('provider_installation {\n dev_overrides {\n "hashicorp/vault" = ' +
                            json.dumps(str(binaries[0].resolve().parent)) + '\n }\n direct {}\n}\n')
        self.server = ThreadingHTTPServer(('127.0.0.1', 0), ProviderFixture)
        self.server.methods = []
        self.server.policy = ''
        thread = threading.Thread(target=self.server.serve_forever, kwargs={'poll_interval': 0.01}, daemon=True)
        thread.start()
        self.addCleanup(thread.join, 2)
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)

    def create_plan(self, ephemeral=True):
        variables = (ROOT / 'secrets-variables.tf').read_text()
        token = re.search(r'variable "openbao_admin_token" \{.*?^\}', variables, re.S | re.M).group()
        provider = re.search(r'provider "vault" \{.*?^\}', (ROOT / 'secrets.tf').read_text(), re.S | re.M).group()
        if not ephemeral:
            token = re.sub(r'^\s*ephemeral\s*=\s*true\s*$', '', token, flags=re.M)
        fixture = '''terraform {
  required_version = ">= 1.11.0"
  required_providers {
    vault = { source = "hashicorp/vault", version = "= 5.13.0" }
  }
}
variable "secrets_platform" { default = { enabled = true } }
locals { openbao_endpoint = "http://127.0.0.1:PORT" }
resource "vault_policy" "definition" {
  name = "synthetic-read"
  allow_overwrite = false
  policy = <<-POLICY
  path "apps/data/synthetic" { capabilities = ["read"] }
  POLICY
}
'''.replace('PORT', str(self.server.server_port))
        (self.work / 'main.tf').write_text(fixture + '\n' + token + '\n' + provider + '\n')
        marker = 'synthetic-admin-' + uuid.uuid4().hex
        env = {'PATH': os.environ['PATH'], 'HOME': str(self.work), 'TF_CLI_CONFIG_FILE': str(self.cli),
               'TF_IN_AUTOMATION': 'true', 'TF_VAR_openbao_admin_token': marker}
        result = subprocess.run(['tofu', 'plan', '-input=false', '-no-color', '-out=fixture.tfplan'],
                                cwd=self.work, env=env, capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        shown = subprocess.run(['tofu', 'show', '-json', 'fixture.tfplan'], cwd=self.work, env=env,
                               capture_output=True, text=True, timeout=30)
        self.assertEqual(shown.returncode, 0, shown.stderr)
        with zipfile.ZipFile(self.work / 'fixture.tfplan') as plan:
            serialized = b''.join(plan.read(name) for name in plan.namelist())
        if ephemeral:
            applied = subprocess.run(['tofu', 'apply', '-input=false', '-no-color', 'fixture.tfplan'],
                                     cwd=self.work, env=env, capture_output=True, text=True, timeout=60)
            self.assertEqual(applied.returncode, 0, applied.stdout + applied.stderr)
            self.assertNotIn(marker, (self.work / 'terraform.tfstate').read_text())
        return marker, shown.stdout, serialized

    def test_actual_ephemeral_input_and_provider_configuration_exclude_token_from_saved_plan(self):
        marker, shown, serialized = self.create_plan()
        self.assertNotIn(marker, shown)
        self.assertNotIn(marker.encode(), serialized)
        self.assertIsNone(json.loads(shown).get('variables', {}).get('openbao_admin_token', {}).get('value'))
        self.assertNotIn('POST', self.server.methods)

    def test_probe_detects_the_leak_if_ephemeral_is_removed_in_an_isolated_fixture(self):
        marker, shown, serialized = self.create_plan(ephemeral=False)
        self.assertIn(marker, shown)
        self.assertIn(marker.encode(), serialized)


if __name__ == '__main__':
    unittest.main()
