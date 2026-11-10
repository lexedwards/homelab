import pathlib
import subprocess
import sys
import tempfile
import time
import unittest


class ReadinessTests(unittest.TestCase):
    def run_check(self, mode):
        with tempfile.TemporaryDirectory() as directory:
            fake = pathlib.Path(directory) / 'kubectl'
            fake.write_text('#!' + sys.executable + '\n' + '''
import json, sys, time
assert '--insecure-skip-tls-verify=false' in sys.argv
mode = ''' + repr(mode) + '''
if mode == 'hung': time.sleep(3)
if mode == 'request_failure':
    print('PROTECTED-DETAIL-MUST-NOT-LEAK', file=sys.stderr)
    raise SystemExit(1)
if '--raw=/readyz' in sys.argv:
    print('ok')
elif 'nodes' in sys.argv:
    node = {'metadata': {'name': 'test-server', 'labels': {'node-role.kubernetes.io/control-plane': 'true'}}, 'spec': {'taints': [{'key': 'node-role.kubernetes.io/control-plane', 'effect': 'NoSchedule'}]}, 'status': {'conditions': [{'type': 'Ready', 'status': 'True'}], 'nodeInfo': {'kubeletVersion': 'v1.36.6+rke2r1'}}}
    if mode == 'missing_taint': node['spec']['taints'] = []
    print(json.dumps({'items': [node, node] if mode == 'extra_server' else [node]}))
elif 'daemonset' in sys.argv and 'cilium' in sys.argv and 'kube-system' in sys.argv:
    print(json.dumps({'metadata': {'generation': 2}, 'status': {'desiredNumberScheduled': 1, 'numberReady': 1, 'updatedNumberScheduled': 1, 'observedGeneration': 1 if mode == 'stale_cilium' else 2}}))
else:
    raise SystemExit(2)
''')
            fake.chmod(0o700)
            return subprocess.run([sys.executable, 'scripts/check-control-plane.py', '--node-name', 'test-server', '--expected-version', 'v1.36.6+rke2r1', '--api-server', 'https://api.example.invalid:6443', '--kubectl', str(fake), '--timeout', '0.5'], capture_output=True, text=True, timeout=5)

    def test_accepts_the_initial_ready_cluster(self):
        result = self.run_check('healthy')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('Verify etcd membership separately', result.stdout)

    def test_rejects_wrong_topology_missing_taint_and_stale_rollout(self):
        for mode in ['extra_server', 'missing_taint', 'stale_cilium']:
            with self.subTest(mode=mode):
                self.assertNotEqual(self.run_check(mode).returncode, 0)

    def test_does_not_echo_private_command_errors(self):
        result = self.run_check('request_failure')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('PROTECTED-DETAIL', result.stdout + result.stderr)

    def test_bounds_a_hung_request(self):
        started = time.monotonic()
        result = self.run_check('hung')
        self.assertNotEqual(result.returncode, 0)
        self.assertLess(time.monotonic() - started, 2)


if __name__ == '__main__':
    unittest.main()
