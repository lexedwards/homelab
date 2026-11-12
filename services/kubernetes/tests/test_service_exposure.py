from pathlib import Path
import unittest

import yaml


class ServiceExposureTests(unittest.TestCase):
    def test_both_pools_cover_both_real_fixture_runtimes_without_nodeports(self):
        root = Path(__file__).resolve().parents[1]
        fixtures = list(yaml.safe_load_all((root / 'examples/network-policy/workloads.yaml').read_text()))
        backends = {d['metadata']['name']: d['spec']['template'] for d in fixtures if d['kind'] == 'Deployment'}
        services = list(yaml.safe_load_all((root / 'examples/service-exposure.yaml').read_text()))
        coverage = set()
        for service in services:
            self.assertEqual(service['kind'], 'Service')
            self.assertEqual(service['metadata']['namespace'], 'policy-check')
            spec = service['spec']
            self.assertEqual(spec['type'], 'LoadBalancer')
            self.assertEqual(spec['loadBalancerClass'], 'io.cilium/l2-announcer')
            self.assertEqual(spec['externalTrafficPolicy'], 'Cluster')
            self.assertFalse(spec['allocateLoadBalancerNodePorts'])
            self.assertEqual(spec['ports'], [{'name': 'http', 'port': 8080, 'targetPort': 8080, 'protocol': 'TCP'}])
            app = spec['selector']['app']
            backend = backends[app]
            self.assertEqual(backend['metadata']['labels']['app'], app)
            self.assertEqual(backend['spec'].get('runtimeClassName'), 'kata-clh-runtime-rs' if app == 'server-isolated' else None)
            coverage.add((service['metadata']['labels']['homelab.io/service-pool'], app))
        self.assertEqual(len(services), 4)
        self.assertEqual(coverage, {
            ('primary', 'server-ordinary'), ('primary', 'server-isolated'),
            ('secondary', 'server-ordinary'), ('secondary', 'server-isolated'),
        })
