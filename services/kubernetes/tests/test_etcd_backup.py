import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('etcd_backup', ROOT / 'scripts/etcd-backup.py')
backup = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(backup)
NOW = 1800000000
TARGET = {'endpoint': 'https://storage.example.invalid:9000', 'bucket': 'cluster-backup',
          'region': 'us-east-1', 'node_name': 'test-control', 'cluster_uid': '00000000-0000-0000-0000-000000000001'}
KEYS = {'access_key_id': 'synthetic-access', 'secret_access_key': 'synthetic-secret'}


def snapshot(timestamp, token_hash='a' * 12):
    return {
        'metadata': {'annotations': {'etcd.rke2.cattle.io/snapshot-token-hash': token_hash}},
        'spec': {'snapshotName': f'homelab-scheduled-test-control-{timestamp}.zip', 'nodeName': 'test-control',
                 's3': {'endpoint': 'storage.example.invalid:9000', 'bucket': 'cluster-backup',
                        'prefix': 'rke2/' + TARGET['cluster_uid'], 'region': 'us-east-1'}},
        'status': {'readyToUse': True},
    }


class NativeFixture:
    def __init__(self, items=(), fail=None, new_token='a' * 12):
        self.items = list(copy.deepcopy(items))
        self.calls = []
        self.fail = fail
        self.new_token = new_token

    def __call__(self, operation, names=()):
        self.calls.append((operation, tuple(names)))
        if self.fail == operation:
            raise ValueError('Native operation failed')
        if operation == 'ls':
            return {'items': copy.deepcopy(self.items)}
        if operation == 'save':
            self.items.append(snapshot(NOW, self.new_token))
        if operation == 'delete':
            self.items = [item for item in self.items if item['spec']['snapshotName'] not in names]


class EtcdBackupTests(unittest.TestCase):
    def custody(self):
        return {'cluster_uid': TARGET['cluster_uid'], 'backup_credential_sha256': backup.credential_hash(KEYS),
                'server_token_hashes': ['a' * 12], 'independent_copies_confirmed': True}

    def test_new_verified_point_precedes_age_based_logical_retirement(self):
        old = snapshot(NOW - 15 * 86400)
        inside_window = snapshot(NOW - 14 * 86400 + 1)
        native = NativeFixture([old, inside_window])
        result = backup.run_backup(TARGET, KEYS, self.custody(), native, NOW)
        self.assertEqual(result['ready_snapshot_count'], 2)
        self.assertEqual(result['latest_recovery_point_age_seconds'], 0)
        self.assertEqual(result['logically_retired_count'], 1)
        self.assertEqual(native.calls, [('ls', ()), ('save', ()), ('ls', ()),
                                       ('delete', (old['spec']['snapshotName'],)), ('ls', ())])
        self.assertIn(inside_window, native.items)

    def test_upload_failure_never_retires_old_points(self):
        native = NativeFixture([snapshot(NOW - 20 * 86400)], fail='save')
        with self.assertRaises(ValueError):
            backup.run_backup(TARGET, KEYS, self.custody(), native, NOW)
        self.assertNotIn('delete', [operation for operation, _ in native.calls])

    def test_local_only_snapshot_is_not_off_node_success(self):
        class LocalOnly(NativeFixture):
            def __call__(self, operation, names=()):
                result = super().__call__(operation, names)
                if operation == 'save':
                    self.items[-1]['spec'].pop('s3')
                return result
        native = LocalOnly([snapshot(NOW - 20 * 86400)])
        with self.assertRaises(ValueError):
            backup.run_backup(TARGET, KEYS, self.custody(), native, NOW)
        self.assertNotIn('delete', [operation for operation, _ in native.calls])

    def test_logical_retirement_failure_is_not_success(self):
        native = NativeFixture([snapshot(NOW - 20 * 86400)], fail='delete')
        with self.assertRaises(ValueError):
            backup.run_backup(TARGET, KEYS, self.custody(), native, NOW)
        self.assertEqual(len(native.items), 2)

    def test_custody_must_be_explicitly_confirmed_before_any_native_access(self):
        native = NativeFixture()
        with self.assertRaises(ValueError):
            backup.run_backup(TARGET, KEYS, dict(self.custody(), independent_copies_confirmed=False), native, NOW)
        self.assertEqual(native.calls, [])

    def test_new_token_without_independent_custody_never_retires_old_points(self):
        native = NativeFixture([snapshot(NOW - 20 * 86400)], new_token='b' * 12)
        with self.assertRaises(ValueError):
            backup.run_backup(TARGET, KEYS, self.custody(), native, NOW)
        self.assertNotIn('delete', [operation for operation, _ in native.calls])

    def test_rotated_backup_key_requires_matching_custody_before_native_access(self):
        native = NativeFixture()
        with self.assertRaises(ValueError):
            backup.run_backup(TARGET, dict(KEYS, secret_access_key='rotated-secret'), self.custody(), native, NOW)
        self.assertEqual(native.calls, [])

    def test_fresh_inventory_is_not_recoverable_without_matching_token_custody(self):
        native = NativeFixture([snapshot(NOW, 'b' * 12)])
        with self.assertRaises(ValueError):
            backup.run_status(TARGET, KEYS, self.custody(), native, NOW)

    def test_native_argv_has_no_values_and_child_environment_has_no_fallback(self):
        captured = []
        def runner(args, **kwargs):
            captured.append((args, kwargs))
            return subprocess.CompletedProcess(args, 0, stdout='{"items":[]}', stderr='')
        native = backup.Native(TARGET, KEYS, runner)
        self.assertEqual(native('ls'), {'items': []})
        args, options = captured[0]
        self.assertNotIn(KEYS['secret_access_key'], ' '.join(args))
        self.assertNotIn(KEYS['access_key_id'], ' '.join(args))
        self.assertEqual(options['env']['AWS_ACCESS_KEY_ID'], KEYS['access_key_id'])
        self.assertEqual(options['env']['AWS_SECRET_ACCESS_KEY'], KEYS['secret_access_key'])
        self.assertNotIn('AWS_SESSION_TOKEN', options['env'])
        self.assertNotIn('AWS_PROFILE', options['env'])
        for expected in ['--s3-insecure=false', '--s3-skip-ssl-verify=false', '--config=/dev/null', '--debug=false', '--s3-retention=0']:
            self.assertIn(expected, args)

    def test_native_failure_never_surfaces_child_output(self):
        def runner(args, **kwargs):
            return subprocess.CompletedProcess(args, 1, stdout=KEYS['access_key_id'], stderr=KEYS['secret_access_key'])
        with self.assertRaisesRegex(ValueError, '^Native snapshot operation failed$'):
            backup.Native(TARGET, KEYS, runner)('save')

    def test_native_deletion_refuses_flag_like_or_foreign_positional_names(self):
        calls = []
        native = backup.Native(TARGET, KEYS, lambda *args, **kwargs: calls.append(args))
        for name in ['--help', 'on-demand-test-control-1800000000', '../homelab-scheduled-test-control-1800000000']:
            with self.assertRaises(ValueError):
                native('delete', [name])
        self.assertEqual(calls, [])

    def test_private_inputs_reject_symlinks_and_world_readable_credentials(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'input.json'
            path.write_text(json.dumps(KEYS))
            path.chmod(0o600)
            self.assertEqual(backup.private_json(path), KEYS)
            link = Path(directory) / 'link.json'
            link.symlink_to(path)
            with self.assertRaises(OSError):
                backup.private_json(link)
            path.chmod(0o644)
            with self.assertRaises(ValueError):
                backup.private_json(path)

    def test_plan_does_not_require_root_credentials_or_native_client(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'target.json'
            path.write_text(json.dumps(TARGET))
            path.chmod(0o600)
            result = subprocess.run(['python3', '-B', str(ROOT / 'scripts/etcd-backup.py'), 'backup', '--config', str(path)],
                                    capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('Plan only', result.stdout)
            self.assertNotIn(TARGET['endpoint'], result.stdout)

    def test_reports_keep_backup_and_inventory_separate_and_private(self):
        with tempfile.TemporaryDirectory() as directory:
            reports = Path(directory) / 'reports'
            with patch.object(backup, 'REPORTS', reports):
                backup.write_report('backup', {'successful': False})
                backup.write_report('status', {'ready_snapshot_count': 1})
            self.assertFalse(json.loads((reports / 'backup.json').read_text())['successful'])
            self.assertEqual((reports / 'backup.json').stat().st_mode & 0o777, 0o600)
            self.assertEqual(reports.stat().st_mode & 0o777, 0o700)

    def test_foreign_prefix_is_ignored_but_owned_wrong_target_fails_closed(self):
        foreign = snapshot(NOW)
        foreign['spec']['snapshotName'] = 'on-demand-test-control-1800000000'
        self.assertEqual(backup.inventory({'items': [foreign]}, TARGET, NOW), [])
        wrong = snapshot(NOW)
        wrong['spec']['s3']['bucket'] = 'another-bucket'
        with self.assertRaises(ValueError):
            backup.inventory({'items': [wrong]}, TARGET, NOW)

    def test_recent_extra_snapshots_do_not_shorten_fourteen_day_window(self):
        items = [snapshot(NOW - 600 * i) for i in range(1, 80)]
        native = NativeFixture(items)
        result = backup.run_backup(TARGET, KEYS, self.custody(), native, NOW)
        self.assertEqual(result['ready_snapshot_count'], 80)
        self.assertEqual(result['logically_retired_count'], 0)

    def test_retirement_batch_does_not_become_unbounded_or_purge_versions(self):
        native = NativeFixture([snapshot(NOW - (15 + i) * 86400) for i in range(10)])
        result = backup.run_backup(TARGET, KEYS, self.custody(), native, NOW)
        self.assertEqual(result['logically_retired_count'], 8)
        self.assertEqual(result['logical_expired_remaining'], 2)
        self.assertFalse(result['physical_version_cleanup_performed'])

    def test_clock_jump_does_not_authorize_deleting_the_new_verified_point(self):
        native = NativeFixture()
        ticks = iter([NOW, NOW, NOW, NOW + 20 * 86400])
        clock = lambda: next(ticks, NOW + 20 * 86400)
        result = backup.run_backup(TARGET, KEYS, self.custody(), native, clock)
        self.assertEqual(result['ready_snapshot_count'], 1)
        self.assertNotIn('delete', [operation for operation, _ in native.calls])

    def test_native_one_second_rounding_is_accepted_but_future_inventory_is_not(self):
        points = backup.inventory({'items': [snapshot(NOW + 1)]}, TARGET, NOW)
        self.assertEqual(backup.summary(points, NOW)['latest_recovery_point_age_seconds'], 0)
        with self.assertRaises(ValueError):
            backup.inventory({'items': [snapshot(NOW + 2)]}, TARGET, NOW)

    def test_invalid_target_rejects_plaintext_or_path_injection(self):
        for invalid in [dict(TARGET, endpoint='http://storage.example.invalid:9000'),
                        dict(TARGET, endpoint='https://storage.example.invalid/private'),
                        dict(TARGET, cluster_uid='../foreign'), dict(TARGET, node_name='node/other')]:
            with self.assertRaises(ValueError):
                backup.validate_target(invalid)

    def test_custody_fingerprints_normalize_secure_server_token_without_values(self):
        short = 'synthetic-server-password'
        secure = 'K10' + 'f' * 64 + '::server:' + short
        self.assertEqual(backup.server_token_hash(short), backup.server_token_hash(secure))
        self.assertEqual(len(backup.server_token_hash(secure)), 12)
        with self.assertRaises(ValueError):
            backup.server_token_hash('K10' + 'f' * 64 + '::node:' + short)

    def test_custody_cli_keeps_old_token_associations_without_printing_values(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name, value in [('target.json', TARGET), ('credentials.json', KEYS)]:
                (root / name).write_text(json.dumps(value))
                (root / name).chmod(0o600)
            token = root / 'independent-token'
            token.write_text('synthetic-independent-password')
            token.chmod(0o600)
            previous = root / 'previous.json'
            previous.write_text(json.dumps(self.custody()))
            previous.chmod(0o600)
            output = root / 'new.json'
            args = ['python3', '-B', str(ROOT / 'scripts/backup-recovery-custody.py'), '--config', str(root / 'target.json'),
                    '--credentials-file', str(root / 'credentials.json'), '--server-token-file', str(token),
                    '--previous', str(previous), '--output', str(output)]
            denied = subprocess.run(args, capture_output=True, text=True, timeout=10)
            self.assertNotEqual(denied.returncode, 0)
            self.assertFalse(output.exists())
            result = subprocess.run(args + ['--independent-copies-confirmed'], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            attestation = json.loads(output.read_text())
            self.assertEqual(set(attestation['server_token_hashes']), {'a' * 12, backup.server_token_hash(token.read_text())})
            self.assertEqual(attestation['backup_credential_sha256'], backup.credential_hash(KEYS))
            self.assertEqual(output.stat().st_mode & 0o777, 0o600)
            for value in [KEYS['secret_access_key'], token.read_text()]:
                self.assertNotIn(value, result.stdout + result.stderr + output.read_text())

    def test_timer_does_not_start_a_stopped_server_or_install_credentials_in_units(self):
        service = (ROOT / 'backup/homelab-etcd-backup.service').read_text()
        timer = (ROOT / 'backup/homelab-etcd-backup.timer').read_text()
        self.assertIn('Requisite=rke2-server.service', service)
        self.assertNotIn('Requires=rke2-server.service', service)
        self.assertIn('backup --execute', service)
        self.assertIn('UMask=0077', service)
        self.assertNotIn('Environment=', service)
        self.assertIn('OnCalendar=*-*-* 00,06,12,18:00:00 UTC', timer)
        self.assertIn('Persistent=true', timer)


if __name__ == '__main__':
    unittest.main()
