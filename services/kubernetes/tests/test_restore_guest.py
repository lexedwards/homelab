import importlib.util
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[1] / 'restore-lab/guest-restore.py'


class RestoreGuestTests(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location('restore_guest', SCRIPT)
        self.guest = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.guest)

    def test_unknown_operation_cannot_run_a_command(self):
        with mock.patch.object(self.guest.subprocess, 'run') as command:
            with self.assertRaises(ValueError):
                self.guest.run({'operation': 'exec', 'command': 'arbitrary'})
            command.assert_not_called()

    def test_nonroot_cannot_enter_administrative_path(self):
        with mock.patch.object(self.guest.os, 'geteuid', return_value=1000), \
             mock.patch.object(self.guest.subprocess, 'run') as command:
            with self.assertRaises(ValueError):
                self.guest.run({'operation': 'prepare'})
            command.assert_not_called()

    def test_disabled_boolean_and_permissive_mode_fail_before_writes(self):
        for enforcement, boolean in [('Permissive', 'on'), ('Enforcing', 'off')]:
            def command(args, **kwargs):
                text = enforcement if args == ['getenforce'] else 'virt_qemu_ga_run_unconfined --> ' + boolean
                return SimpleNamespace(returncode=0, stdout=text)
            with self.subTest(enforcement=enforcement, boolean=boolean), \
                 mock.patch.object(self.guest.os, 'geteuid', return_value=0), \
                 mock.patch.object(self.guest.subprocess, 'run', side_effect=command), \
                 mock.patch.object(self.guest.os, 'open') as write:
                with self.assertRaises(ValueError):
                    self.guest.run({'operation': 'prepare'})
                write.assert_not_called()

    def test_wrong_execution_domain_fails_before_data_or_service_mutation(self):
        def command(args, **kwargs):
            text = 'Enforcing' if args == ['getenforce'] else 'virt_qemu_ga_run_unconfined --> on'
            return SimpleNamespace(returncode=0, stdout=text)
        with mock.patch.object(self.guest.os, 'geteuid', return_value=0), \
             mock.patch.object(self.guest.subprocess, 'run', side_effect=command) as process, \
             mock.patch.object(self.guest.Path, 'read_text', return_value='system_u:system_r:virt_qemu_ga_t:s0'), \
             mock.patch.object(self.guest.os, 'open') as write:
            with self.assertRaises(ValueError):
                self.guest.run({'operation': 'prepare'})
            write.assert_not_called()
            self.assertFalse(any(call.args[0][0] == 'systemctl' for call in process.call_args_list))

    def test_probe_checks_full_preparation_without_writes(self):
        def command(args, **kwargs):
            if args == ['getenforce']:
                text = 'Enforcing'
            elif args[0] == 'getsebool':
                text = 'virt_qemu_ga_run_unconfined --> on'
            elif args[0] == '/usr/bin/rke2':
                text = 'rke2 version v1.36.6+rke2r1 fixture'
            elif args[0] == 'rpm':
                text = '0.24-1.el10'
            elif args[:2] == ['systemctl', 'show']:
                text = 'inactive'
            elif args[:2] == ['systemctl', 'is-enabled']:
                return SimpleNamespace(returncode=1, stdout='disabled')
            else:
                self.fail('Probe attempted an unexpected command')
            return SimpleNamespace(returncode=0, stdout=text)
        def text(path, *args, **kwargs):
            return '1000.0 0.0' if str(path) == '/proc/uptime' else 'system_u:system_r:virt_qemu_ga_unconfined_t:s0'
        with mock.patch.object(self.guest.os, 'geteuid', return_value=0), \
             mock.patch.object(self.guest.subprocess, 'run', side_effect=command), \
             mock.patch.object(self.guest.socket, 'gethostname', return_value='k8s-restore-fixture'), \
             mock.patch.object(self.guest.time, 'time', return_value=2000), \
             mock.patch.object(self.guest.Path, 'read_text', text), \
             mock.patch.object(self.guest.Path, 'is_file', return_value=True), \
             mock.patch.object(self.guest.Path, 'stat', return_value=SimpleNamespace(st_mtime=500)), \
             mock.patch.object(self.guest.Path, 'exists', return_value=False), \
             mock.patch.object(self.guest.Path, 'open', mock.mock_open(read_data=b'fixture')), \
             mock.patch.object(self.guest.hashlib, 'file_digest', return_value=SimpleNamespace(hexdigest=lambda: '58c153e94944039fc05b8e23de9e8f489df049519e55dd33e5790bf5ae19a217')), \
             mock.patch.object(self.guest.os, 'open') as write:
            result = self.guest.run({'operation': 'probe', 'vm_name': 'k8s-restore-fixture'})
            self.assertTrue(result['successful'])
            self.assertTrue(result['stock_helper_transition_verified'])
            self.assertTrue(result['hostname_verified'])
            write.assert_not_called()


if __name__ == '__main__':
    unittest.main()
