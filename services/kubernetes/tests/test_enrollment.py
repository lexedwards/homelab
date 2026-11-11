import importlib.util
import contextlib
import io
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location(
    'enrollment', Path(__file__).resolve().parents[1] / 'scripts/enroll-worker.py'
)
enrollment = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(enrollment)


class EnrollmentBoundaryTests(unittest.TestCase):
    def test_accepts_only_secure_bootstrap_tokens_not_server_credentials(self):
        token = 'K10' + 'a' * 64 + '::abcdef.0123456789abcdef'
        self.assertEqual(enrollment.bootstrap_id(token), 'abcdef')
        for value in ['abcdef.0123456789abcdef', 'K10' + 'a' * 64 + '::server:password', token + '\nextra']:
            with self.subTest(value=value), self.assertRaises(ValueError):
                enrollment.bootstrap_id(value)

    def test_requires_a_verified_https_api_identity_without_credentials(self):
        for value in ['http://api.example.invalid:6443', 'https://user:token@api.example.invalid:6443', 'https://api.example.invalid:6443/path']:
            with self.subTest(value=value), self.assertRaises(ValueError):
                enrollment.api_endpoint(value)
        self.assertEqual(enrollment.api_endpoint('https://api.example.invalid:6443'), 'https://api.example.invalid:6443')

    def test_transfer_uses_stdin_and_revokes_on_success_or_install_failure(self):
        token = 'K10' + 'a' * 64 + '::abcdef.0123456789abcdef'
        for fail_install in [False, True]:
            with self.subTest(fail_install=fail_install), tempfile.TemporaryDirectory() as directory:
                key = Path(directory) / 'identity'
                key.touch()
                actions = []

                def run(argv, *, input, **kwargs):
                    payload = json.loads(input)
                    actions.append(payload['action'])
                    self.assertNotIn(token, ' '.join(argv))
                    self.assertIn('StrictHostKeyChecking=yes', argv)
                    if payload['action'] == 'create':
                        return SimpleNamespace(returncode=0, stdout=token)
                    if payload['action'] == 'install':
                        self.assertEqual(payload['token'], token)
                        return SimpleNamespace(returncode=int(fail_install), stdout='{}')
                    output = {'ready': True} if payload['action'] == 'observe' else {'primary_ip': '192.0.2.20'}
                    return SimpleNamespace(returncode=0, stdout=json.dumps(output))

                args = ['--server-ssh', 'admin@server.example.invalid', '--worker-ssh', 'admin@worker.example.invalid',
                        '--identity-file', str(key), '--server-known-hosts', str(key), '--worker-known-hosts', str(key),
                        '--node-name', 'test-worker', '--host', 'compute', '--api-server', 'https://api.example.invalid:6443']
                output = io.StringIO()
                with patch.object(enrollment.subprocess, 'run', side_effect=run), contextlib.redirect_stdout(output):
                    if fail_install:
                        with self.assertRaises(RuntimeError):
                            enrollment.main(args)
                    else:
                        enrollment.main(args)
                self.assertEqual(actions[-1], 'delete')
                self.assertNotIn(token, output.getvalue())
