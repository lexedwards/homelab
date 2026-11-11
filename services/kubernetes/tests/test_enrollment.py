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
    def test_worker_preflight_accepts_its_short_or_fully_qualified_hostname_only(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            files = {
                '/var/lib/kubernetes-agent-installed': 'previous-boot',
                '/proc/sys/kernel/random/boot_id': 'current-boot',
                '/etc/rancher/rke2/config.yaml': json.dumps({
                    'node-name': 'test-worker', 'selinux': True,
                    'node-label': ['homelab.io/role=worker', 'topology.kubernetes.io/zone=compute'],
                    'server': 'https://api.example.invalid:9345',
                    'token-file': '/etc/rancher/rke2/join-token',
                }),
            }
            for name, content in files.items():
                path = root / name.lstrip('/')
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(content)
            interfaces = [{'ifname': name, 'addr_info': [{'family': 'inet', 'scope': 'global', 'local': address}]}
                          for name, address in [('ens18', '192.0.2.20'), ('ens19', '198.51.100.20')]]
            commands = {
                ('getenforce',): 'Enforcing',
                ('swapon', '--noheadings', '--show'): '',
                ('rpm', '-q', '--last', 'kernel-core'): 'kernel-core-test-kernel date',
                ('uname', '-r'): 'test-kernel',
                ('rke2', '--version'): 'rke2 version v1.36.6+rke2r1',
                ('ip', '-j', '-4', 'route', 'show', 'default'): '[{"dev":"ens18"}]',
                ('ip', '-j', '-6', 'route', 'show', 'default'): '[]',
                ('ip', '-j', 'address', 'show'): json.dumps(interfaces),
            }
            for interface in ['ens18', 'ens19']:
                commands[('nmcli', '-g', 'GENERAL.CON-UUID', 'device', 'show', interface)] = interface
                commands[('nmcli', '-g', 'ipv4.method', 'connection', 'show', 'uuid', interface)] = 'auto'
            commands[('nmcli', '-g', 'ipv4.never-default,ipv4.ignore-auto-dns,ipv4.ignore-auto-routes,ipv6.method',
                      'connection', 'show', 'uuid', 'ens19')] = 'yes\nyes\nyes\ndisabled'
            payload = {'name': 'test-worker', 'host': 'compute', 'version': 'v1.36.6+rke2r1',
                       'supervisor': 'https://api.example.invalid:9345', 'action': 'check'}
            for hostname in ['test-worker', 'test-worker.nodes.example.invalid', 'other-worker.nodes.example.invalid']:
                output = io.StringIO()
                with self.subTest(hostname=hostname), patch('socket.gethostname', return_value=hostname), \
                        patch('os.geteuid', return_value=0), \
                        patch('pathlib.Path', side_effect=lambda name: root / str(name).lstrip('/')), \
                        patch('subprocess.check_output', side_effect=lambda argv, **kwargs: commands[tuple(argv)]), \
                        patch('sys.stdin', io.StringIO(json.dumps(payload))), contextlib.redirect_stdout(output):
                    if hostname.startswith('other-worker'):
                        with self.assertRaisesRegex(RuntimeError, 'Unexpected worker identity'):
                            exec(enrollment.WORKER, {})
                    else:
                        exec(enrollment.WORKER, {})
                        self.assertEqual(json.loads(output.getvalue()), {'primary_ip': '192.0.2.20'})
            self.assertFalse((root / 'etc/rancher/rke2/join-token').exists())

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
