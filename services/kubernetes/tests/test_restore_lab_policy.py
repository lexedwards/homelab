from pathlib import Path
import json
import os
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / 'restore-lab/prepare.sh'
FAKE = '''#!/usr/bin/python3
import json,os,sys
from pathlib import Path
name=Path(sys.argv[0]).name
with open(os.environ['TRACE'],'a') as f:f.write(json.dumps([name,*sys.argv[1:]])+'\\n')
state=Path(os.environ['STATE'])
if name=='getenforce':print(os.environ.get('MODE','Enforcing'))
elif name=='getsebool':
 if os.environ.get('SUPPORTED')!='true':sys.exit(1)
 print('virt_qemu_ga_run_unconfined --> '+('on' if state.exists() else 'off'))
elif name=='setsebool':
 if sys.argv[1:]!=['-P','virt_qemu_ga_run_unconfined','on']:sys.exit(95)
 if os.environ.get('SET_FAIL')=='true':sys.exit(1)
 state.write_text('on')
elif name=='systemctl':
 if sys.argv[1:]!=['restart','qemu-guest-agent']:sys.exit(96)
elif name in ['matchpathcon','stat']:print('system_u:object_r:'+os.environ['LABEL']+':s0')
elif name=='restorecon':pass
else:sys.exit(97)
'''


class LabAdminPolicyTests(unittest.TestCase):
    def run_policy(self, opt_in, supported=True, mode='Enforcing', set_fail=False,
                   label='virt_qemu_ga_unconfined_exec_t'):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fake = root / 'command'
            fake.write_text(FAKE)
            fake.chmod(0o755)
            for name in ['getenforce', 'getsebool', 'setsebool', 'systemctl', 'matchpathcon', 'restorecon', 'stat']:
                (root / name).symlink_to(fake)
            env = dict(os.environ, PATH=str(root) + ':/usr/bin:/bin', TRACE=str(root / 'trace'),
                       STATE=str(root / 'state'), SUPPORTED=str(supported).lower(), MODE=mode,
                       SET_FAIL=str(set_fail).lower(), LABEL=label)
            result = subprocess.run(['bash', '-c', 'source "$1"; configure_guest_admin "$2"',
                                     'policy-test', str(SCRIPT), opt_in],
                                    env=env, capture_output=True, text=True, timeout=10)
            trace = root / 'trace'
            calls = [json.loads(line) for line in trace.read_text().splitlines()] if trace.exists() else []
            return result.returncode, calls, (root / 'state').exists()

    def test_explicit_opt_in_enables_only_approved_supported_boolean(self):
        code, calls, enabled = self.run_policy('true')
        self.assertEqual(code, 0)
        self.assertTrue(enabled)
        self.assertEqual([v for v in calls if v[0] == 'setsebool'],
                         [['setsebool', '-P', 'virt_qemu_ga_run_unconfined', 'on']])
        self.assertEqual([v for v in calls if v[0] == 'systemctl'],
                         [['systemctl', 'restart', 'qemu-guest-agent']])
        self.assertEqual(calls[-1], ['getenforce'])
        self.assertEqual([v for v in calls if v[0] == 'restorecon'],
                         [['restorecon', '/usr/libexec/qemu-ga/fsfreeze-hook.d/homelab-restore']])

    def test_default_opt_out_does_not_change_policy_or_restart_agent(self):
        code, calls, enabled = self.run_policy('false')
        self.assertEqual(code, 0)
        self.assertFalse(enabled)
        self.assertFalse(any(v[0] in ['setsebool', 'systemctl'] for v in calls))

    def test_missing_boolean_fails_before_mutation(self):
        code, calls, enabled = self.run_policy('true', supported=False)
        self.assertNotEqual(code, 0)
        self.assertFalse(enabled)
        self.assertIn(['getsebool', 'virt_qemu_ga_run_unconfined'], calls)
        self.assertFalse(any(v[0] in ['setsebool', 'systemctl'] for v in calls))

    def test_permissive_mode_is_not_accepted_or_changed(self):
        code, calls, enabled = self.run_policy('true', mode='Permissive')
        self.assertNotEqual(code, 0)
        self.assertFalse(enabled)
        self.assertFalse(any(v[0] in ['setsebool', 'systemctl', 'setenforce'] for v in calls))

    def test_failed_policy_update_cannot_restart_agent(self):
        code, calls, enabled = self.run_policy('true', set_fail=True)
        self.assertNotEqual(code, 0)
        self.assertFalse(enabled)
        self.assertFalse(any(v[0] == 'systemctl' for v in calls))

    def test_missing_stock_label_mapping_cannot_relabel_or_enable(self):
        code, calls, enabled = self.run_policy('true', label='bin_t')
        self.assertNotEqual(code, 0)
        self.assertFalse(enabled)
        self.assertTrue(any(v[0] == 'matchpathcon' for v in calls))
        self.assertFalse(any(v[0] in ['restorecon', 'setsebool', 'systemctl'] for v in calls))


if __name__ == '__main__':
    unittest.main()
