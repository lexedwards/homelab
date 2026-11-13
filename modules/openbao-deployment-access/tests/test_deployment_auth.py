import copy
import importlib.util
import io
import json
import os
import re
from pathlib import Path
import secrets
import socket
import subprocess
import tempfile
import time
import unittest
import urllib.error
import urllib.request
import zipfile


ROOT = Path(__file__).resolve().parents[1]
BINARY = os.environ.get('BAO_TEST_BINARY')


@unittest.skipUnless(BINARY, 'Set BAO_TEST_BINARY to a verified OpenBao 2.7.2 binary for isolated ACL integration tests')
class DeploymentAuthorizationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory(prefix='openbao-acl-')
        cls.addClassCleanup(cls.directory.cleanup)
        cls.work = Path(cls.directory.name)
        with socket.socket() as listener:
            listener.bind(('127.0.0.1', 0))
            port = listener.getsockname()[1]
        cls.address = f'http://127.0.0.1:{port}'
        cls.admin = secrets.token_hex(32)
        cls.env = {'PATH': os.environ['PATH'], 'HOME': str(cls.work), 'TF_IN_AUTOMATION': 'true'}
        server_env = dict(cls.env, BAO_DEV_ROOT_TOKEN_ID=cls.admin)
        cls.server = subprocess.Popen([BINARY, 'server', '-dev', f'-dev-listen-address=127.0.0.1:{port}'],
                                      env=server_env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        cls.addClassCleanup(cls.stop_server)
        for _ in range(100):
            try:
                cls.api('GET', 'sys/health', cls.admin)
                break
            except (OSError, urllib.error.URLError):
                time.sleep(0.05)
        else:
            raise RuntimeError('Isolated OpenBao did not become ready')
        version = cls.api('GET', 'sys/health', cls.admin)['version']
        if version != '2.7.2':
            raise RuntimeError('Use the pinned production version 2.7.2 for the ACL integration test')
        grant_source = str(ROOT)
        access = cls.work / 'workload-access'
        access.mkdir()
        owner_module = ROOT.parent / 'kubernetes-openbao-access'
        definitions = (owner_module / 'main.tf').read_text()
        blocks = re.findall(r'^resource "vault_[^"]+" "[^"]+" \{.*?^\}', definitions, re.M | re.S)
        if len(blocks) != 2:
            raise AssertionError('Expected the two real Vault resources from the owning access module')
        (access / 'main.tf').write_text('\n'.join(blocks))
        (access / 'variables.tf').write_text((owner_module / 'variables.tf').read_text())
        (access / 'versions.tf').write_text('terraform {\n required_providers {\n vault = { source = "hashicorp/vault" }\n }\n}\n')
        access_source = str(access)
        cls.configuration = '''terraform {
  required_version = ">= 1.11.0"
  required_providers { vault = { source = "hashicorp/vault", version = "= 5.13.0" } }
}
variable "admin_token" {
  type = string
  sensitive = true
  ephemeral = true
}
variable "deployment_token" {
  type = string
  sensitive = true
  ephemeral = true
  default = "disabled-no-credential"
}
variable "configure_workload" { default = false }
provider "vault" {
  address = ADDRESS
  token = var.admin_token
  skip_child_token = true
}
resource "vault_auth_backend" "kubernetes" {
  type = "kubernetes"
  path = "kubernetes-test"
}
module "grant" {
  source = GRANT_SOURCE
  name = "demo-reader"
  secret_paths = ["secret/data/demo"]
}
module "access" {
  count = var.configure_workload ? 1 : 0
  source = ACCESS_SOURCE
  name = "demo-reader"
  auth_mount = "kubernetes-test"
  namespace = "demo"
  service_account = "reader"
  api_audience = "api-test"
  openbao_endpoint = "https://bao.example.invalid:8200"
  provider_class = "files"
  token_review_role = "openbao-tokenreview"
  files = { value = { secret_path = "secret/data/demo", secret_key = "value" } }
  depends_on = [vault_auth_backend.kubernetes]
}
'''
        for name, value in [('ADDRESS', cls.address),
                            ('GRANT_SOURCE', grant_source), ('ACCESS_SOURCE', access_source)]:
            cls.configuration = cls.configuration.replace(name, json.dumps(value))
        (cls.work / 'main.tf').write_text(cls.configuration)
        cls.env['TF_VAR_admin_token'] = cls.admin
        cls.tofu('init', '-backend=false', '-input=false')
        cls.tofu('apply', '-auto-approve', '-input=false', '-no-color')
        cls.issuer = cls.api('POST', 'auth/token/create', cls.admin, {
            'policies': ['demo-reader-issuer'], 'no_default_policy': True, 'ttl': '900s', 'renewable': False,
        })['auth']['client_token']
        try:
            cls.deployment_response = cls.mint_deployment()
        except urllib.error.HTTPError as error:
            raise AssertionError(error.read().decode()) from None
        cls.deployment = cls.deployment_response['auth']['client_token']
        cls.env['TF_VAR_deployment_token'] = cls.deployment
        cls.tofu('apply', '-auto-approve', '-input=false', '-no-color', '-var=configure_workload=true')
        cls.contract = {
            'role': cls.api('GET', 'auth/kubernetes-test/role/demo-reader', cls.admin)['data'],
            'read_policy': cls.api('GET', 'sys/policies/acl/demo-reader', cls.admin)['data']['policy'],
        }
        cls.reader = cls.api('POST', 'auth/token/create', cls.admin, {
            'policies': ['demo-reader'], 'no_default_policy': True, 'ttl': '300s', 'renewable': False,
        })['auth']['client_token']

    @classmethod
    def stop_server(cls):
        cls.server.terminate()
        cls.server.wait(timeout=10)

    @classmethod
    def tofu(cls, *arguments):
        result = subprocess.run(['tofu', *arguments], cwd=cls.work, env=cls.env,
                                capture_output=True, text=True, timeout=120)
        if result.returncode:
            text = result.stdout + result.stderr
            for value in [cls.admin, getattr(cls, 'deployment', ''), getattr(cls, 'issuer', '')]:
                if value:
                    text = text.replace(value, '[redacted fixture credential]')
            raise AssertionError(text)
        return result.stdout

    @classmethod
    def api(cls, method, path, token, data=None):
        request = urllib.request.Request(cls.address + '/v1/' + path, method=method,
                                         data=None if data is None else json.dumps(data).encode(),
                                         headers={'X-Vault-Token': token, 'Content-Type': 'application/merge-patch+json' if method == 'PATCH' else 'application/json'})
        with urllib.request.urlopen(request, timeout=10) as response:
            body = response.read()
            return json.loads(body) if body else None

    @classmethod
    def mint_deployment(cls):
        return cls.api('POST', 'auth/token/create/demo-reader-deploy', cls.issuer, {
            'policies': ['demo-reader-deploy'], 'ttl': '900s', 'explicit_max_ttl': '900s', 'renewable': False, 'no_default_policy': True,
        })

    def denied(self, method, path, token, data=None):
        with self.assertRaises(urllib.error.HTTPError) as raised:
            self.api(method, path, token, data)
        code = raised.exception.code
        raised.exception.close()
        self.assertEqual(code, 403, f'{method} {path} must be forbidden, not merely invalid')

    def test_deployment_can_write_its_record_but_cannot_read_list_delete_patch_or_write_siblings(self):
        self.api('POST', 'secret/data/demo', self.deployment, {'data': {'value': 'synthetic-only'}})
        for method, path, data in [
            ('GET', 'secret/data/demo', None), ('GET', 'secret/metadata/demo', None),
            ('LIST', 'secret/metadata/', None), ('DELETE', 'secret/data/demo', None),
            ('PATCH', 'secret/data/demo', {'data': {'value': 'changed'}}),
            ('POST', 'secret/data/sibling', {'data': {'value': 'changed'}}),
            ('GET', 'sys/mounts', None),
        ]:
            with self.subTest(method=method, path=path):
                self.denied(method, path, self.deployment, data)

    def test_reader_can_read_but_cannot_write_or_reconfigure(self):
        self.api('POST', 'secret/data/demo', self.deployment, {'data': {'value': 'synthetic-only'}})
        self.assertEqual(self.api('GET', 'secret/data/demo', self.reader)['data']['data']['value'], 'synthetic-only')
        self.denied('POST', 'secret/data/demo', self.reader, {'data': {'value': 'changed'}})
        self.denied('POST', 'auth/kubernetes-test/role/demo-reader', self.reader, self.contract['role'])
        self.denied('POST', 'sys/policies/acl/demo-reader', self.reader, {'policy': self.contract['read_policy']})
        self.denied('GET', 'secret/data/sibling', self.reader)

    def test_deployment_cannot_broaden_the_policy_or_change_any_role_binding(self):
        self.denied('GET', 'sys/policies/acl/demo-reader', self.deployment)
        self.denied('GET', 'auth/kubernetes-test/role/demo-reader', self.deployment)
        self.denied('POST', 'sys/policies/acl/demo-reader', self.deployment,
                    {'policy': self.contract['read_policy']})
        self.denied('POST', 'auth/kubernetes-test/role/demo-reader', self.deployment, self.contract['role'])
        self.denied('POST', 'sys/policies/acl/demo-reader', self.deployment,
                    {'policy': 'path "*" { capabilities = ["sudo", "read", "update"] }'})
        mutations = {
            'token_policies': ['root'], 'bound_service_account_names': ['*'],
            'bound_service_account_namespaces': ['*'], 'audience': 'other',
            'bound_service_account_namespace_selector': '{"matchLabels":{"any":"true"}}',
            'token_no_default_policy': False, 'token_ttl': 3600, 'token_explicit_max_ttl': 0,
            'token_period': 3600, 'alias_name_source': 'serviceaccount_name', 'token_type': 'batch',
            'alias_metadata': {'unapproved': 'value'},
        }
        for key, value in mutations.items():
            body = copy.deepcopy(self.contract['role'])
            body[key] = value
            with self.subTest(parameter=key):
                self.denied('POST', 'auth/kubernetes-test/role/demo-reader', self.deployment, body)
        missing = copy.deepcopy(self.contract['role'])
        del missing['audience']
        self.denied('POST', 'auth/kubernetes-test/role/demo-reader', self.deployment, missing)
        self.denied('POST', 'auth/kubernetes-test/role/sibling', self.deployment, self.contract['role'])

    def test_administrator_can_detect_and_repair_role_configuration_drift(self):
        self.api('POST', 'auth/kubernetes-test/role/demo-reader', self.admin, {'token_ttl': 120})
        self.tofu('plan', '-input=false', '-no-color', '-var=configure_workload=true', '-out=drift.tfplan')
        plan = json.loads(self.tofu('show', '-json', 'drift.tfplan'))
        changes = [change for change in plan['resource_changes'] if change['change']['actions'] != ['no-op']]
        self.assertEqual(len(changes), 1)
        self.assertEqual(changes[0]['type'], 'vault_kubernetes_auth_backend_role')
        self.tofu('apply', '-input=false', '-no-color', 'drift.tfplan')
        self.assertEqual(self.api('GET', 'auth/kubernetes-test/role/demo-reader', self.admin)['data']['token_ttl'], 300)

    def test_deployment_cannot_mint_renew_or_alter_its_own_permissions(self):
        self.denied('POST', 'auth/token/create', self.deployment, {'policies': ['demo-reader']})
        self.denied('POST', 'auth/token/create/demo-reader-deploy', self.deployment, {})
        self.denied('POST', 'auth/token/renew-self', self.deployment, {})
        self.denied('POST', 'sys/policies/acl/demo-reader-deploy', self.deployment, {'policy': ''})
        self.denied('POST', 'auth/token/roles/demo-reader-deploy', self.deployment, {'allowed_policies': ['root']})
        auth = self.deployment_response['auth']
        self.assertFalse(auth['renewable'])
        self.assertLessEqual(auth['lease_duration'], 900)
        self.assertEqual(auth['policies'], ['demo-reader-deploy'])

    def test_issued_writer_has_an_actual_explicit_maximum_lifetime(self):
        data = self.api('GET', 'auth/token/lookup-self', self.deployment)['data']
        self.assertEqual(data['explicit_max_ttl'], 900)
        self.assertFalse(data['renewable'])
        self.assertFalse(data['orphan'])
        self.assertLessEqual(data['ttl'], 900)

    def test_issuer_cannot_mint_a_reader_admin_or_unbounded_token(self):
        body = {'policies': ['demo-reader-deploy'], 'ttl': '900s', 'explicit_max_ttl': '900s', 'renewable': False, 'no_default_policy': True}
        for key, value in [('policies', ['demo-reader']), ('policies', ['root']), ('policies', []), ('ttl', '24h'),
                            ('explicit_max_ttl', '3600s'), ('explicit_max_ttl', '0s'),
                            ('renewable', True), ('no_default_policy', False), ('orphan', True),
                           ('entity_alias', 'unapproved')]:
            with self.subTest(parameter=key, value=value):
                self.denied('POST', 'auth/token/create/demo-reader-deploy', self.issuer, dict(body, **{key: value}))
        for required in body:
            with self.subTest(missing=required):
                missing = dict(body)
                del missing[required]
                self.denied('POST', 'auth/token/create/demo-reader-deploy', self.issuer, missing)
        self.denied('POST', 'auth/token/create', self.issuer, body)
        self.denied('GET', 'secret/data/demo', self.issuer)

    def test_protected_helper_can_issue_populate_and_revoke_without_reading_values(self):
        spec = importlib.util.spec_from_file_location('service_credentials', ROOT / 'scripts/service-credentials.py')
        helper = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(helper)
        enrollment = {'address': self.address, 'token_role': 'demo-reader-deploy',
                      'deployment_policy': 'demo-reader-deploy', 'secret_paths': ['secret/data/demo']}
        output = self.work / 'private-helper-token'
        helper.issue(enrollment, self.issuer, output)
        token = helper.read_private(output).strip()
        helper.write_record(enrollment, token, 'secret/data/demo', io.StringIO('{"value":"synthetic-only"}'))
        self.denied('GET', 'secret/data/demo', token)
        helper.request(enrollment, token, 'auth/token/revoke-self', {})
        self.denied('GET', 'auth/token/lookup-self', token)

    def test_revoking_an_issuer_also_revokes_its_non_orphan_deployment_child(self):
        issuer = self.api('POST', 'auth/token/create', self.admin, {
            'policies': ['demo-reader-issuer'], 'no_default_policy': True, 'ttl': '900s', 'renewable': False,
        })['auth']['client_token']
        child = self.api('POST', 'auth/token/create/demo-reader-deploy', issuer, {
            'policies': ['demo-reader-deploy'], 'ttl': '900s', 'explicit_max_ttl': '900s', 'renewable': False, 'no_default_policy': True,
        })['auth']['client_token']
        self.api('POST', 'auth/token/revoke-self', issuer, {})
        self.denied('GET', 'auth/token/lookup-self', child)

    def test_configuration_refresh_is_clean_and_saved_plan_and_state_exclude_credentials(self):
        self.tofu('plan', '-input=false', '-no-color', '-var=configure_workload=true', '-out=fixture.tfplan')
        shown = self.tofu('show', '-json', 'fixture.tfplan')
        plan = json.loads(shown)
        self.assertTrue(all(change['change']['actions'] == ['no-op'] for change in plan.get('resource_changes', [])))
        state = (self.work / 'terraform.tfstate').read_text()
        with zipfile.ZipFile(self.work / 'fixture.tfplan') as archive:
            saved = b''.join(archive.read(name) for name in archive.namelist())
        for token in [self.admin, self.deployment, self.issuer, self.reader]:
            self.assertNotIn(token, shown)
            self.assertNotIn(token, state)
            self.assertNotIn(token.encode(), saved)


if __name__ == '__main__':
    unittest.main()
