import importlib.util
import json
from pathlib import Path
import stat
import tempfile
import unittest


spec = importlib.util.spec_from_file_location('configure_server', Path(__file__).resolve().parents[1] / 'config/configure-server.py')
bootstrap = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bootstrap)


class DHCPBootstrapTests(unittest.TestCase):
    def interfaces(self):
        return [
            {'ifname': 'lo', 'address': '00:00:00:00:00:00', 'addr_info': [{'family': 'inet', 'scope': 'host', 'local': '127.0.0.1'}]},
            {'ifname': 'ens18', 'address': '02:00:00:00:00:01', 'addr_info': [{'family': 'inet', 'scope': 'global', 'local': '192.0.2.10'}]},
            {'ifname': 'cilium_host', 'address': '02:00:00:00:00:02', 'addr_info': [{'family': 'inet', 'scope': 'global', 'local': '198.18.0.8'}]},
        ]

    def test_selects_the_primary_lease_not_loopback_or_cilium(self):
        identity = bootstrap.primary_identity([{'dst': 'default', 'dev': 'ens18'}], self.interfaces())
        self.assertEqual(identity, {'ipv4_address': '192.0.2.10', 'mac_address': '02:00:00:00:00:01'})

    def test_rejects_missing_or_ambiguous_routes_and_multiple_addresses(self):
        for routes in [[], [{'dev': 'ens18'}, {'dev': 'ens19'}]]:
            with self.subTest(routes=routes), self.assertRaises(ValueError):
                bootstrap.primary_identity(routes, self.interfaces())
        links = self.interfaces()
        links[1]['addr_info'].append({'family': 'inet', 'scope': 'global', 'local': '192.0.2.11'})
        with self.assertRaises(ValueError):
            bootstrap.primary_identity([{'dev': 'ens18'}], links)

    def test_restart_requires_the_same_ip_on_the_same_mac(self):
        identity = {'ipv4_address': '192.0.2.10', 'mac_address': '02:00:00:00:00:01'}
        bootstrap.check_identity(identity, self.interfaces())
        links = self.interfaces()
        links[1]['addr_info'][0]['local'] = '192.0.2.11'
        links[2]['addr_info'][0]['local'] = '192.0.2.10'
        with self.assertRaises(ValueError):
            bootstrap.check_identity(identity, links)

    def test_writes_consistent_private_configuration_or_rejects_before_writing(self):
        with tempfile.TemporaryDirectory() as directory:
            rke2, cilium, record = [Path(directory) / name for name in ['config.yaml', 'cilium.yaml', 'identity.json']]
            initial = {'cluster-cidr': '198.18.0.0/16', 'service-cidr': '198.19.0.0/16', 'tls-san': ['api.example.invalid'], 'selinux': True}
            rke2.write_text(json.dumps(initial))
            cilium.write_text(json.dumps({'spec': {'valuesContent': json.dumps({'socketLB': {'hostNamespaceOnly': True}})}}))
            identity = {'ipv4_address': '192.0.2.10', 'mac_address': '02:00:00:00:00:01'}
            for expected in [{'ipv4_address': '192.0.2.99'}, {'mac_address': '02:00:00:00:00:99'}]:
                with self.subTest(expected=expected), self.assertRaises(ValueError):
                    bootstrap.configure(rke2, cilium, record, identity, expected)
            self.assertEqual(json.loads(rke2.read_text()), initial)
            self.assertFalse(record.exists())
            with self.assertRaises(ValueError):
                bootstrap.configure(rke2, cilium, record, {'ipv4_address': '198.18.0.8', 'mac_address': identity['mac_address']}, {})
            self.assertEqual(json.loads(rke2.read_text()), initial)
            bootstrap.configure(rke2, cilium, record, identity, {'ipv4_address': None, 'mac_address': None})
            self.assertEqual(json.loads(rke2.read_text())['node-ip'], '192.0.2.10')
            self.assertEqual(json.loads(rke2.read_text())['tls-san'], ['api.example.invalid'])
            self.assertTrue(json.loads(rke2.read_text())['selinux'])
            values = json.loads(json.loads(cilium.read_text())['spec']['valuesContent'])
            self.assertEqual(values['k8sServiceHost'], '192.0.2.10')
            self.assertTrue(values['socketLB']['hostNamespaceOnly'])
            self.assertEqual(json.loads(record.read_text()), identity)
            for path in [rke2, cilium, record]:
                self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)


if __name__ == '__main__':
    unittest.main()
