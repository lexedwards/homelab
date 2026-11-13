import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
import urllib.error
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/service-credentials.py'
spec = importlib.util.spec_from_file_location('service_credentials', SCRIPT)
credentials = importlib.util.module_from_spec(spec)
spec.loader.exec_module(credentials)


class ServiceCredentialTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.work = Path(self.directory.name)
        self.enrollment = {'address': 'https://bao.example.invalid:8200', 'token_role': 'demo-deploy',
                           'deployment_policy': 'demo-deploy', 'secret_paths': ['apps/data/demo']}
        self.auth = {'client_token': 'synthetic-deployment', 'policies': ['demo-deploy'],
                     'renewable': False, 'lease_duration': 900}

    def private(self, name, content):
        path = self.work / name
        path.write_text(content)
        path.chmod(0o600)
        return path

    def test_issue_writes_only_a_private_new_file_and_requests_a_bounded_token(self):
        output = self.work / 'deployment-token'
        with patch.object(credentials, 'request', return_value={'auth': self.auth}) as request:
            credentials.issue(self.enrollment, 'synthetic-issuer', output)
        self.assertEqual(output.read_text(), 'synthetic-deployment\n')
        self.assertEqual(output.stat().st_mode & 0o777, 0o600)
        self.assertEqual(request.call_args.args[2], 'auth/token/create/demo-deploy')
        self.assertEqual(request.call_args.args[3], {'policies': ['demo-deploy'], 'ttl': '900s',
                                                   'renewable': False, 'no_default_policy': True})

    def test_existing_output_is_preserved_without_issuing_another_token(self):
        output = self.private('token', 'existing-private-input')
        with patch.object(credentials, 'request') as request:
            with self.assertRaises(FileExistsError):
                credentials.issue(self.enrollment, 'synthetic-issuer', output)
        request.assert_not_called()
        self.assertEqual(output.read_text(), 'existing-private-input')

    def test_unexpected_policy_is_rejected_and_new_token_revoked(self):
        output = self.work / 'token'
        with patch.object(credentials, 'request', side_effect=[{'auth': dict(self.auth, policies=['root'])}, None]) as request:
            with self.assertRaisesRegex(ValueError, 'contract'):
                credentials.issue(self.enrollment, 'synthetic-issuer', output)
        self.assertEqual(request.call_args.args[1:3], ('synthetic-deployment', 'auth/token/revoke-self'))
        self.assertFalse(output.exists())

    def test_empty_issued_token_is_not_saved_as_a_successful_enrollment(self):
        output = self.work / 'token'
        with patch.object(credentials, 'request', return_value={'auth': dict(self.auth, client_token='')}):
            with self.assertRaisesRegex(ValueError, 'contract'):
                credentials.issue(self.enrollment, 'synthetic-issuer', output)
        self.assertFalse(output.exists())

    def test_record_population_has_no_value_read_or_unowned_write(self):
        with patch.object(credentials, 'request') as request:
            credentials.write_record(self.enrollment, 'synthetic-deployment', 'apps/data/demo', io.StringIO('{"value":"synthetic"}'))
            self.assertEqual(request.call_count, 1)
            self.assertEqual(request.call_args.args[2:], ('apps/data/demo', {'data': {'value': 'synthetic'}}))
        with patch.object(credentials, 'request') as request:
            with self.assertRaisesRegex(ValueError, 'not declared'):
                credentials.write_record(self.enrollment, 'synthetic-deployment', 'apps/data/other', io.StringIO('{}'))
            request.assert_not_called()

    def test_public_or_symlinked_credential_inputs_are_rejected(self):
        source = self.private('token', 'synthetic')
        source.chmod(0o644)
        with self.assertRaisesRegex(ValueError, 'private'):
            credentials.read_private(source)
        source.chmod(0o600)
        link = self.work / 'link'
        link.symlink_to(source)
        with self.assertRaises(OSError):
            credentials.read_private(link)

    def test_plaintext_or_credential_bearing_endpoint_is_rejected(self):
        for endpoint in ['http://bao.example.invalid:8200', 'https://token@bao.example.invalid', 'https://bao.example.invalid/?token=x']:
            source = self.private('enrollment', json.dumps(dict(self.enrollment, address=endpoint)))
            with self.assertRaisesRegex(ValueError, 'HTTPS'):
                credentials.load_enrollment(source)

    def test_redirect_does_not_forward_the_credential(self):
        with self.assertRaisesRegex(ValueError, 'redirect'):
            credentials.NoRedirect().redirect_request(None, None, 302, '', {}, 'https://other.example.invalid')

    def test_malformed_value_input_does_not_appear_in_cli_errors(self):
        enrollment = self.private('enrollment', json.dumps(self.enrollment))
        token = self.private('token', 'synthetic-credential-marker')
        stdout, stderr = io.StringIO(), io.StringIO()
        arguments = ['service-credentials.py', '--enrollment', str(enrollment), '--token-file', str(token),
                     'write', '--secret-path', 'apps/data/demo']
        with patch('sys.argv', arguments), patch('sys.stdin', io.StringIO('synthetic-secret-marker invalid-json')):
            with patch('sys.stdout', stdout), patch('sys.stderr', stderr):
                with self.assertRaises(SystemExit) as raised:
                    credentials.main()
        self.assertEqual(raised.exception.code, 1)
        self.assertNotIn('synthetic-secret-marker', stdout.getvalue() + stderr.getvalue())
        self.assertNotIn('synthetic-credential-marker', stdout.getvalue() + stderr.getvalue())

    def test_http_error_bodies_are_not_exposed(self):
        error = urllib.error.HTTPError('https://bao.example.invalid', 403, 'Forbidden', {},
                                       io.BytesIO(b'synthetic-sensitive-response'))
        with patch.object(credentials.urllib.request, 'build_opener') as build:
            build.return_value.open.side_effect = error
            with self.assertRaisesRegex(ValueError, 'HTTP 403') as raised:
                credentials.request(self.enrollment, 'synthetic-token', 'apps/data/demo', {})
        self.assertNotIn('synthetic-sensitive-response', str(raised.exception))


if __name__ == '__main__':
    unittest.main()
