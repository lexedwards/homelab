import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


# TODO: Remove this temporary suite and bubblewrap dependency after live first-boot/restart validation.
SERVICE = Path(__file__).resolve().parents[1]


class BootSequenceTests(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(shutil.which('bwrap'), 'Install bubblewrap to run isolated boot tests.')
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        for directory in ['etc/rancher/rke2', 'etc/modules-load.d', 'etc/sysctl.d',
                          'etc/yum.repos.d', 'etc/systemd/system/rke2-server.service.d',
                          'var/lib/rancher/rke2', 'commands']:
            (self.root / directory).mkdir(parents=True)
        (self.root / 'etc/os-release').write_text('ID=rocky\nVERSION_ID=10.2\n')
        (self.root / 'etc/fstab').write_text('/dev/test swap swap defaults 0 0\n')
        (self.root / 'etc/rancher/rke2/config.yaml').write_text('{"selinux":true}\n')
        self.command('getenforce', 'echo "${TEST_SELINUX:-Enforcing}"')
        self.command('uname', 'echo x86_64')
        self.command('python3', 'exit 1')
        self.command('dnf', '''
echo "dnf $*" >> /var/events
if [[ $* == *kernel* ]]; then
    [[ ${TEST_INSTALL_FAIL:-} != kernel ]]
    touch /var/new-kernel-installed
else
    [[ ${TEST_INSTALL_FAIL:-} != rke2 ]]
fi
''')
        self.command('curl', '''
while (( $# )); do
    if [[ $1 == -o ]]; then printf 'fixture key' > "$2"; exit; fi
    shift
done
exit 1
''')
        self.command('sha256sum', 'cat >/dev/null')
        self.command('rpm', '''
if [[ $* == *rke2-selinux ]]; then echo 0.24-1.el10
elif [[ $1 == -q ]]; then echo '1.36.6~rke2r1-0.el10'
fi
''')
        self.command('modprobe', '''
echo "modprobe $*" >> /var/events
[[ -f /var/rebooted && ${TEST_MODULE_FAIL:-0} != 1 ]]
''')
        self.command('sysctl', '''
echo "sysctl $*" >> /var/events
[[ -f /var/rebooted && ${TEST_SYSCTL_FAIL:-0} != 1 ]]
''')
        self.command('swapon', 'if [[ ${TEST_SWAP:-0} == 1 ]]; then echo /dev/test; fi')
        for name in ['swapoff', 'restorecon', 'nmcli', 'sshd', 'systemctl']:
            self.command(name, 'echo "' + name + ' $*" >> /var/events')

    def command(self, name, body):
        path = self.root / 'commands' / name
        path.write_text('#!/bin/bash\nset -euo pipefail\n' + body + '\n')
        path.chmod(0o755)

    def run_guest(self, script, *arguments, **environment):
        command = ['bwrap', '--unshare-all', '--die-with-parent', '--ro-bind', '/', '/',
                   '--bind', str(self.root / 'etc'), '/etc',
                   '--bind', str(self.root / 'var'), '/var', '--tmpfs', '/tmp',
                   '--proc', '/proc', '--dev', '/dev', '--uid', '0', '--gid', '0',
                   '--ro-bind', str(self.root / 'commands'), '/tmp/commands',
                   '--setenv', 'PATH', '/tmp/commands:/usr/bin:/bin']
        for name, value in environment.items():
            command.extend(['--setenv', name, value])
        return subprocess.run(command + ['/bin/bash', str(SERVICE / script), *arguments],
                              env={k: v for k, v in os.environ.items() if not k.startswith('TEST_')},
                              text=True, capture_output=True, timeout=30)

    def install(self, **environment):
        return self.run_guest('cloud-init/install-server.sh', '1.36.6~rke2r1-0.el10',
                              '0.24-1.el10', **environment)

    def preflight(self, **environment):
        return self.run_guest('config/node-preflight.sh', **environment)

    def events(self):
        path = self.root / 'var/events'
        return path.read_text().splitlines() if path.exists() else []

    def test_install_without_identity_data_then_activate_modules_after_reboot(self):
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.root / 'var/new-kernel-installed').exists())
        self.assertTrue((self.root / 'var/lib/kubernetes-server-installed').exists())
        self.assertFalse(any(e.startswith(('modprobe ', 'sysctl ')) for e in self.events()))
        self.assertIn('systemctl enable rke2-server', self.events())
        self.assertFalse(any('--now' in e or 'systemctl start' in e for e in self.events()))
        self.assertEqual((self.root / 'etc/modules-load.d/kubernetes.conf').read_text(),
                         'overlay\nbr_netfilter\nnf_conntrack\n')
        self.assertIn('net.bridge.bridge-nf-call-iptables=1',
                      (self.root / 'etc/sysctl.d/90-kubernetes.conf').read_text())
        self.assertEqual(json.loads((self.root / 'etc/rancher/rke2/config.yaml').read_text()),
                         {'selinux': True})
        self.assertNotEqual(self.preflight().returncode, 0)
        (self.root / 'var/rebooted').touch()
        for _ in range(2):
            result = self.preflight()
            self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.events()[-4:], ['modprobe overlay', 'modprobe br_netfilter',
                                            'modprobe nf_conntrack',
                                            'sysctl -p /etc/sysctl.d/90-kubernetes.conf'])

    def test_failed_install_does_not_enable_server_or_leave_success_marker(self):
        marker = self.root / 'var/lib/kubernetes-server-installed'
        for stage in ['kernel', 'rke2']:
            with self.subTest(stage=stage):
                marker.touch()
                result = self.install(TEST_INSTALL_FAIL=stage)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(marker.exists())
                self.assertNotIn('systemctl enable rke2-server', self.events())

    def test_existing_etcd_data_is_not_reprovisioned(self):
        (self.root / 'var/lib/rancher/rke2/server/db/etcd').mkdir(parents=True)
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.events(), [])

    def test_preflight_rejects_security_and_kernel_failures(self):
        (self.root / 'var/rebooted').touch()
        for environment in [{'TEST_SELINUX': 'Permissive'}, {'TEST_SWAP': '1'},
                            {'TEST_MODULE_FAIL': '1'}, {'TEST_SYSCTL_FAIL': '1'}]:
            with self.subTest(environment=environment):
                self.assertNotEqual(self.preflight(**environment).returncode, 0)


if __name__ == '__main__':
    unittest.main()
