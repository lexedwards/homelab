from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

import yaml


class NamespacePolicyTests(unittest.TestCase):
    def test_baseline_denies_both_directions_without_selecting_other_namespaces(self):
        root = Path(__file__).resolve().parents[1]
        policy = yaml.safe_load((root / 'platform/network-policy/default-deny.yaml').read_text())
        self.assertNotIn('namespace', policy['metadata'])
        self.assertEqual(policy['spec'], {'podSelector': {}, 'policyTypes': ['Ingress', 'Egress'], 'ingress': [], 'egress': []})

    def test_dns_allowance_intersects_namespace_and_pod_selectors(self):
        root = Path(__file__).resolve().parents[1]
        policy = yaml.safe_load((root / 'platform/network-policy/allow-cluster-dns.yaml').read_text())
        self.assertEqual(policy['spec']['policyTypes'], ['Egress'])
        rules = policy['spec']['egress']
        self.assertEqual(len(rules), 1)
        self.assertEqual(rules[0]['to'], [{
            'namespaceSelector': {'matchLabels': {'kubernetes.io/metadata.name': 'kube-system'}},
            'podSelector': {'matchLabels': {'k8s-app': 'kube-dns'}},
        }])
        self.assertEqual(rules[0]['ports'], [{'protocol': 'UDP', 'port': 53}, {'protocol': 'TCP', 'port': 53}])


class PolicyProbeTests(unittest.TestCase):
    def probe(self, mode, expect='deny'):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fake = root / 'kubectl'
            fake.write_text('#!' + sys.executable + '\n' + '''
import json,pathlib,sys,time
args=sys.argv[1:]
assert '--insecure-skip-tls-verify=false' in args
mode=''' + repr(mode) + '''
if mode=='hung':time.sleep(30)
if 'get' in args and 'pod' in args:
    name=args[args.index('pod')+1]
    source=name=='client'
    pod={'metadata':{'name':name,'uid':name,'labels':{'homelab.io/policy-check':'true'}},
         'spec':{'nodeName':'worker-a' if source else 'worker-b'},
         'status':{'phase':'Running','podIP':'10.42.0.10' if source or mode=='same-ip' else '10.42.1.10',
                   'conditions':[{'type':'Ready','status':'False' if mode=='unready' else 'True'}]}}
    print(json.dumps(pod))
elif 'get' in args and 'pods' in args:
    print(json.dumps({'items':[{'metadata':{'name':'cilium-a'},'spec':{'nodeName':'worker-a'},'status':{'conditions':[{'type':'Ready','status':'True'}]}},
                               {'metadata':{'name':'cilium-b'},'spec':{'nodeName':'worker-b'},'status':{'conditions':[{'type':'Ready','status':'True'}]}}]}))
elif 'exec' in args and 'monitor' not in args:
    if mode=='exec-failure':
        print('PROTECTED-DETAIL-MUST-NOT-LEAK',file=sys.stderr)
        raise SystemExit(1)
    pathlib.Path(__file__).with_name('request-fired').touch()
    print('connected' if mode=='allowed' else 'not-connected')
elif 'monitor' in args:
    event={'type':'drop','reason':'Invalid source ip' if mode=='wrong-reason' else 'Policy denied',
           'summary':{'tcp':'TCP SYN','l3':{'src':'10.42.0.11' if mode=='wrong-source' else '10.42.0.10','dst':'10.42.1.10'},
                      'l4':{'src':'45000','dst':'9090' if mode=='wrong-port' else '8080'}}}
    if mode=='stale-flow':print(json.dumps(event),flush=True)
    print('Press Ctrl-C to quit',file=sys.stderr,flush=True)
    deadline=time.monotonic()+8
    while not pathlib.Path(__file__).with_name('request-fired').exists():
        if time.monotonic()>deadline:raise SystemExit(1)
        time.sleep(0.01)
    if mode not in ['missing-flow','stale-flow']:print(json.dumps(event),flush=True)
    raise SystemExit(124)
else:raise SystemExit(2)
''')
            fake.chmod(0o700)
            result = subprocess.run([
                sys.executable, '-B', 'scripts/check-policy-probe.py',
                '--source', 'policy-check/client', '--destination', 'policy-check/server',
                '--port', '8080', '--expect', expect, '--api-server', 'https://api.example.invalid:6443',
                '--kubectl', str(fake), '--evidence', str(root / 'probe.json'), '--timeout', '5' if mode=='hung' else '10',
            ], capture_output=True, text=True, timeout=15)
            evidence = root / 'probe.json'
            return result, evidence.read_text() if evidence.exists() else ''

    def test_allows_a_direct_peer_connection(self):
        result, evidence = self.probe('allowed', 'allow')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('"cross_worker": true', evidence)

    def test_denial_requires_a_fresh_matching_policy_drop(self):
        result, evidence = self.probe('denied')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('Policy denied', evidence)

    def test_rejects_missing_stale_or_unrelated_drop_evidence(self):
        for mode in ['missing-flow', 'stale-flow', 'wrong-port', 'wrong-source', 'wrong-reason', 'allowed']:
            with self.subTest(mode=mode):
                result, _ = self.probe(mode)
                self.assertNotEqual(result.returncode, 0)

    def test_api_exec_errors_and_unready_endpoints_are_not_policy_denials(self):
        for mode in ['exec-failure', 'unready', 'same-ip']:
            with self.subTest(mode=mode):
                result, _ = self.probe(mode)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn('PROTECTED-DETAIL', result.stdout + result.stderr)

    def test_bounds_a_hung_request(self):
        result, _ = self.probe('hung')
        self.assertNotEqual(result.returncode, 0)
