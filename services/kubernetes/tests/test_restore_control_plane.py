from pathlib import Path
import copy
import importlib.util
import hashlib
import json
import os
import subprocess
import tempfile
import unittest
from unittest import mock
import yaml


SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/restore-control-plane.py'


def load():
    spec = importlib.util.spec_from_file_location('restore_control_plane', SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class RestoreBoundaryTests(unittest.TestCase):
    def setUp(self):
        self.restore = load()
        self.target = {
            'proxmox_endpoint': 'https://proxmox.example.invalid:8006/',
            'node': 'compute', 'vm_id': 199991, 'vm_name': 'k8s-restore-fixture',
            'production_vm_ids': [199981, 199982, 199983], 'template_vm_id': 199990,
            'bridge': 'fixture-bridge', 'vlan_id': 123,
            'cluster_uid': '11111111-2222-4333-8444-555555555555',
            'cluster_cidr': '10.70.0.0/16', 'service_cidr': '10.71.0.0/16',
            'scratch_address': '192.0.2.10', 'snapshot_sha256': 'a' * 64,
            'snapshot_timestamp': 1700000000,
            'server_token_hash': 'b' * 12,
            'namespace_uids': {'kube-system': '11111111-2222-4333-8444-555555555555'},
            'server_ca_sha256': 'c' * 64,
        }
        self.vm = {
            'name': 'k8s-restore-fixture', 'tags': 'iac;kubernetes-restore-lab',
            'template': 0, 'net0': 'virtio=02:00:00:00:00:01,bridge=fixture-bridge,tag=123,link_down=1',
        }

    def test_valid_fenced_scratch_vm_is_accepted(self):
        target = self.restore.validate_target(self.target)
        self.restore.verify_fence(target, self.vm)

    def test_connected_vm_is_rejected(self):
        self.vm['net0'] = self.vm['net0'].replace(',link_down=1', '')
        with self.assertRaises(ValueError):
            self.restore.verify_fence(self.target, self.vm)

    def test_second_network_device_is_rejected(self):
        self.vm['net1'] = 'virtio=02:00:00:00:00:02,bridge=fixture-bridge,link_down=1'
        with self.assertRaises(ValueError):
            self.restore.verify_fence(self.target, self.vm)

    def test_passthrough_and_custom_network_arguments_are_rejected(self):
        for addition in [{'hostpci0': 'synthetic-device'}, {'usb0': 'synthetic-device'}, {'args': '-netdev synthetic'}]:
            with self.subTest(addition=addition), self.assertRaises(ValueError):
                self.restore.verify_fence(self.target, dict(self.vm, **addition))

    def test_guest_poll_keeps_the_original_process_identity(self):
        api = self.restore.API(self.target, 'fixture@pam!test=synthetic-api-token')
        paths = []
        statuses = iter([{'exited': 0}, {'exited': 1, 'exitcode': 0, 'out-data': '{"successful":true}'}])

        def call(path, payload=None):
            paths.append(path)
            if path.endswith('/config?current=1'):
                return self.vm
            if path.endswith('/status/current'):
                return {'status': 'running'}
            if path.endswith('/agent/exec'):
                return {'pid': 1234}
            self.assertTrue(path.endswith('/exec-status?pid=1234'))
            return next(statuses)

        api.call = call
        with mock.patch.object(self.restore.time, 'sleep'):
            self.assertTrue(api.guest({'operation': 'prepare'})['successful'])
        self.assertEqual(sum(path.endswith('/exec-status?pid=1234') for path in paths), 2)

    def test_pending_only_fence_cannot_authorize_guest_execution(self):
        api = self.restore.API(self.target, 'fixture@pam!test=synthetic-api-token')
        connected = dict(self.vm, net0=self.vm['net0'].replace(',link_down=1', ''))
        paths = []

        def call(path, payload=None):
            paths.append(path)
            if path == api.path + '/config':
                return self.vm
            if path == api.path + '/config?current=1':
                return connected
            if path.endswith('/status/current'):
                return {'status': 'running'}
            if path.endswith('/agent/exec'):
                return {'pid': 1234}
            return {'exited': 1, 'exitcode': 0, 'out-data': '{"successful":true}'}

        api.call = call
        with self.assertRaises(ValueError):
            api.guest({'operation': 'prepare'})
        self.assertFalse(any(path.endswith('/agent/exec') for path in paths))

    def test_disabled_guest_execution_is_rejected_before_mutation(self):
        api = self.restore.API(self.target, 'fixture@pam!test=synthetic-api-token')
        for disabled in ['guest-exec', 'guest-exec-status']:
            commands = [{'name': name, 'enabled': name != disabled} for name in ['guest-exec', 'guest-exec-status']]
            api.call = mock.Mock(return_value={'result': {'supported_commands': commands}})
            with self.subTest(disabled=disabled), self.assertRaises(ValueError):
                api.require_exec_capability()

    def test_enabled_guest_execution_capabilities_are_accepted(self):
        api = self.restore.API(self.target, 'fixture@pam!test=synthetic-api-token')
        api.call = mock.Mock(return_value={'result': {'supported_commands': [
            {'name': 'guest-exec', 'enabled': True}, {'name': 'guest-exec-status', 'enabled': True},
            {'name': 'guest-file-open', 'enabled': False},
        ]}})
        api.require_exec_capability()
        api.call.assert_called_once_with(api.path + '/agent/info')

    def test_lab_enables_only_required_agent_rpcs_with_its_own_config(self):
        template = SCRIPT.parent.parent / 'restore-lab/user-data.tftpl'
        data = yaml.safe_load(template.read_text())
        files = {item['path']: item['content'] for item in data['write_files']}
        config = files['/etc/qemu/restore-lab.conf']
        allow = next(line.split('=', 1)[1] for line in config.splitlines() if line.startswith('allow-rpcs='))
        self.assertEqual(set(allow.split(',')), {
            'guest-sync', 'guest-sync-delimited', 'guest-ping', 'guest-info',
            'guest-network-get-interfaces', 'guest-get-osinfo', 'guest-get-host-name',
            'guest-fstrim', 'guest-shutdown', 'guest-exec', 'guest-exec-status',
        })
        unit = files['/etc/systemd/system/qemu-guest-agent.service.d/10-restore-lab.conf']
        self.assertIn('ExecStart=/usr/bin/qemu-ga --config=/etc/qemu/restore-lab.conf', unit)
        self.assertIn(['systemctl', 'daemon-reload'], data['runcmd'])
        self.assertIn(['systemctl', 'restart', 'qemu-guest-agent'], data['runcmd'])

    def test_mismatched_recovery_material_cannot_mutate_guest(self):
        snapshot = b'synthetic-snapshot'
        target = dict(self.target, snapshot_sha256=hashlib.sha256(snapshot).hexdigest(),
                      server_token_hash=hashlib.sha256(b'fixture-password').hexdigest()[:12])
        api = mock.Mock()
        for data, token in [(b'wrong-snapshot', 'fixture-password'), (snapshot, 'wrong-password')]:
            with self.subTest(token=token), self.assertRaises(ValueError):
                self.restore.execute(target, data, token, api)
        api.guest.assert_not_called()

    def test_restore_transfers_bounded_stdin_chunks_then_verifies(self):
        snapshot = b'owned-synthetic-snapshot' * 4000
        target = dict(self.target, snapshot_sha256=hashlib.sha256(snapshot).hexdigest(),
                      server_token_hash=hashlib.sha256(b'fixture-password').hexdigest()[:12])
        api = mock.Mock()
        api.guest.return_value = {'successful': True}
        result = self.restore.execute(target, snapshot, 'fixture-password', api)
        payloads = [call.args[0] for call in api.guest.call_args_list]
        self.assertEqual(payloads[0]['operation'], 'prepare')
        self.assertEqual([v['operation'] for v in payloads[-4:]], ['configure', 'reset', 'start', 'verify'])
        chunks = [v for v in payloads if v['operation'] == 'append']
        import base64
        decoded = [base64.b64decode(v['data']) for v in chunks]
        self.assertEqual(b''.join(decoded), snapshot)
        self.assertTrue(all(len(v) <= 32768 for v in decoded))
        self.assertEqual([v['offset'] for v in chunks], list(range(0, len(snapshot), 32768)))
        self.assertTrue(result['hypervisor_fence_verified'])
        self.assertTrue(result['duration_excludes_lab_provisioning_and_snapshot_download'])
        self.assertNotIn('fixture-password', json.dumps(result))
        api.require_exec_capability.assert_called_once()
        api.guard.assert_called_once()

    def test_failed_reset_cannot_start_server(self):
        snapshot = b'owned-synthetic-snapshot'
        target = dict(self.target, snapshot_sha256=hashlib.sha256(snapshot).hexdigest(),
                      server_token_hash=hashlib.sha256(b'fixture-password').hexdigest()[:12])
        api = mock.Mock()

        def guest(payload, **kwargs):
            if payload['operation'] == 'reset':
                raise ValueError('synthetic native reset failure')
            return {'successful': True}

        api.guest.side_effect = guest
        with self.assertRaises(ValueError):
            self.restore.execute(target, snapshot, 'fixture-password', api)
        self.assertNotIn('start', [call.args[0]['operation'] for call in api.guest.call_args_list])

    def test_guest_program_compiles_without_running_it(self):
        compile(self.restore.GUEST, 'isolated-restore-guest', 'exec')

    def test_foreign_vm_name_or_owner_is_rejected(self):
        for change in [{'name': 'useful-service'}, {'tags': 'iac;other-service'}, {'template': 1}]:
            with self.subTest(change=change), self.assertRaises(ValueError):
                self.restore.verify_fence(self.target, dict(self.vm, **change))

    def test_production_and_template_ids_cannot_be_targets(self):
        for identifier in [*self.target['production_vm_ids'], self.target['template_vm_id']]:
            with self.subTest(identifier=identifier), self.assertRaises(ValueError):
                self.restore.validate_target(dict(self.target, vm_id=identifier))

    def test_wrong_bridge_or_vlan_is_rejected(self):
        for value in ['fixture-bridge', 'tag=123']:
            vm = copy.deepcopy(self.vm)
            vm['net0'] = vm['net0'].replace(value, 'wrong')
            with self.subTest(value=value), self.assertRaises(ValueError):
                self.restore.verify_fence(self.target, vm)

    def test_default_cli_does_not_read_credentials_snapshot_or_contact_api(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'target.json'
            path.write_text(json.dumps(self.target))
            path.chmod(0o600)
            result = subprocess.run([
                'python3', '-B', str(SCRIPT), '--config', str(path),
                '--snapshot-file', '/unread/snapshot', '--server-token-file', '/unread/token',
                '--proxmox-token-file', '/unread/api-token',
            ], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(json.loads(result.stdout)['plan_only'])

    def test_unprotected_input_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'input'
            path.write_text('synthetic-token')
            path.chmod(0o644)
            with self.assertRaises(ValueError):
                self.restore.private_bytes(path)


if __name__ == '__main__':
    unittest.main()
