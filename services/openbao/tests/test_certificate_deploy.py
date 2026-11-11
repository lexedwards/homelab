import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from tls_fixtures import create_ca, issue_certificate, openssl


SERVICE = Path(__file__).resolve().parents[1]


class CertificateDeploymentTests(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(shutil.which("bwrap"), "Install bubblewrap for isolated certificate deployment checks")
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        for name in ["etc/openbao/tls", "etc/letsencrypt/live/openbao", "etc/ssl/certs", "var", "commands"]:
            (self.root / name).mkdir(parents=True)
        (self.root / "etc/passwd").write_text("root:x:0:0:root:/root:/bin/sh\n")
        (self.root / "etc/group").write_text("root:x:0:\nopenbao:x:0:\n")
        (self.root / "etc/openbao/acme-domain").write_text("bao.example.invalid\n")
        self.ca = create_ca(self.root / "test-ca")
        shutil.copyfile(self.ca / "ca.pem", self.root / "etc/ssl/certs/test-ca.pem")
        openssl("rehash", self.root / "etc/ssl/certs")
        self.first = issue_certificate(self.root / "first", self.ca, "bao.example.invalid")
        self.second = issue_certificate(self.root / "second", self.ca, "bao.example.invalid")
        self.lineage = self.root / "etc/letsencrypt/live/openbao"
        self.copy_lineage(self.first)
        stub = self.root / "commands/systemctl"
        stub.write_text('''#!/bin/sh
set -eu
printf '%s\n' "$*" >> /var/events
case "$1" in
    is-active) test "${TEST_ACTIVE:-0}" = 1 ;;
    kill) test "${TEST_FAIL_RELOAD:-0}" = 0 ;;
    enable) exit 0 ;;
    *) exit 1 ;;
esac
''')
        stub.chmod(0o755)

    def copy_lineage(self, source):
        for name in ["cert.pem", "chain.pem", "fullchain.pem", "privkey.pem"]:
            shutil.copy2(source / name, self.lineage / name)

    def deploy(self, active=False, lineage="/etc/letsencrypt/live/openbao", fail_reload=False):
        args = ["bwrap", "--unshare-all", "--die-with-parent", "--ro-bind", "/", "/",
                "--bind", str(self.root / "etc"), "/etc", "--bind", str(self.root / "var"), "/var",
                "--proc", "/proc", "--dev", "/dev", "--tmpfs", "/run", "--dir", "/run/lock",
                "--tmpfs", "/tmp", "--ro-bind", str(self.root / "commands"), "/tmp/commands",
                "--uid", "0", "--gid", "0", "--setenv", "PATH", "/tmp/commands:/usr/bin:/bin",
                "--setenv", "RENEWED_LINEAGE", lineage, "--setenv", "TEST_ACTIVE", "1" if active else "0",
                "--setenv", "TEST_FAIL_RELOAD", "1" if fail_reload else "0",
                "/bin/sh", str(SERVICE / "scripts/deploy-certificate.sh")]
        return subprocess.run(args, env={key: value for key, value in os.environ.items() if key in ["PATH", "LANG"]},
                              text=True, capture_output=True, timeout=30)

    def events(self):
        path = self.root / "var/events"
        return path.read_text().splitlines() if path.exists() else []

    def test_initial_deployment_protects_key_without_starting_or_restarting_server(self):
        result = self.deploy()
        self.assertEqual(result.returncode, 0, result.stderr)
        current = self.root / "etc/openbao/tls/current"
        self.assertTrue(current.is_symlink())
        self.assertEqual((current / "fullchain.pem").read_bytes(), (self.first / "fullchain.pem").read_bytes())
        self.assertEqual((current / "privkey.pem").read_bytes(), (self.first / "privkey.pem").read_bytes())
        self.assertEqual(current.stat().st_mode & 0o777, 0o750)
        self.assertEqual((current / "privkey.pem").stat().st_mode & 0o777, 0o640)
        self.assertEqual(self.events(), ["is-active --quiet openbao", "enable --now openbao-certificate-expiry.timer"])
        self.assertNotIn("PRIVATE KEY", result.stdout + result.stderr)

    def test_renewal_publishes_a_complete_pair_and_signals_only_hup(self):
        self.assertEqual(self.deploy(active=True).returncode, 0)
        current = self.root / "etc/openbao/tls/current"
        previous = current.resolve()
        self.copy_lineage(self.second)
        result = self.deploy(active=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotEqual(current.resolve(), previous)
        self.assertEqual((current / "privkey.pem").read_bytes(), (self.second / "privkey.pem").read_bytes())
        self.assertEqual((current / "fullchain.pem").read_bytes(), (self.second / "fullchain.pem").read_bytes())
        self.assertTrue((previous / "privkey.pem").exists())
        self.assertIn("kill --kill-whom=main --signal=HUP openbao", self.events())
        self.assertFalse(any("restart" in e or e.startswith("start ") for e in self.events()))
        self.assertEqual(list((self.root / "etc/openbao/tls").glob(".current.*")), [])

    def test_mismatched_key_does_not_replace_previous_generation_or_signal(self):
        self.assertEqual(self.deploy(active=True).returncode, 0)
        current = self.root / "etc/openbao/tls/current"
        previous = current.resolve()
        events = self.events()
        shutil.copyfile(self.second / "privkey.pem", self.lineage / "privkey.pem")
        self.assertNotEqual(self.deploy(active=True).returncode, 0)
        self.assertEqual(current.resolve(), previous)
        self.assertEqual(self.events(), events)
        self.assertEqual(len(list((self.root / "etc/openbao/tls").glob("certificate.*"))), 1)

    def test_wrong_hostname_or_untrusted_chain_is_rejected_before_publication(self):
        wrong_name = issue_certificate(self.root / "wrong-name", self.ca, "other.example.invalid")
        untrusted_ca = create_ca(self.root / "untrusted-ca")
        untrusted = issue_certificate(self.root / "untrusted", untrusted_ca, "bao.example.invalid")
        for candidate in [wrong_name, untrusted]:
            with self.subTest(candidate=candidate.name):
                self.copy_lineage(candidate)
                self.assertNotEqual(self.deploy(active=True).returncode, 0)
                self.assertFalse((self.root / "etc/openbao/tls/current").exists())
                self.assertEqual(self.events(), [])

    def test_reload_failure_is_observable_and_another_lineage_is_ignored(self):
        self.assertEqual(self.deploy(lineage="/etc/letsencrypt/live/another-service").returncode, 0)
        self.assertEqual(self.events(), [])
        self.assertNotEqual(self.deploy(active=True, fail_reload=True).returncode, 0)


if __name__ == "__main__":
    unittest.main()
