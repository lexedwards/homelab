import importlib.util
import io
import json
from pathlib import Path
import tempfile
import ssl
import unittest
from unittest.mock import patch
from urllib.error import HTTPError, URLError


SPEC = importlib.util.spec_from_file_location(
    "readiness", Path(__file__).resolve().parents[1] / "scripts/check-ready.py"
)
readiness = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(readiness)


class ReadinessTests(unittest.TestCase):
    def test_rejects_plaintext_health_endpoint(self):
        with self.assertRaises(ValueError):
            readiness.read_health("http://bao.example.invalid:8200")

    def test_rejects_credentials_and_paths_in_api_endpoint(self):
        for url in ["https://user:token@bao.example.invalid", "https://bao.example.invalid/path", "https://bao.example.invalid/?token=value"]:
            with self.subTest(url=url), self.assertRaises(ValueError):
                readiness.endpoint(url)

    def test_rejects_disabled_certificate_verification(self):
        context = ssl._create_unverified_context()
        with self.assertRaises(ValueError):
            readiness.check_certificate("https://bao.example.invalid:8200", context=context)

    def test_pending_enrollment_is_not_a_ready_or_running_server(self):
        with tempfile.TemporaryDirectory() as directory:
            cert = Path(directory) / "fullchain.pem"
            key = Path(directory) / "privkey.pem"
            properties = "ActiveState=inactive\nUser=openbao\nMemorySwapMax=0\nConditionResult=no\nUnitFileState=enabled\n"
            with patch.object(readiness, "TLS_CERT", cert), patch.object(readiness, "TLS_KEY", key):
                with patch.object(readiness.subprocess, "check_output", return_value=properties), patch.object(readiness, "urlopen") as api:
                    readiness.main(["--api-url", "https://bao.example.invalid:8200", "--allow-pending-tls"])
                    api.assert_not_called()
                with patch.object(readiness.subprocess, "check_output", return_value=properties.replace("inactive", "active")):
                    with self.assertRaises(RuntimeError):
                        readiness.check_pending_tls()
                cert.touch()
                with self.assertRaises(RuntimeError):
                    readiness.check_pending_tls()

    def test_reports_sealed_and_uninitialized_without_claiming_secret_readiness(self):
        for status, initialized, sealed in [(501, False, True), (503, True, True)]:
            with self.subTest(status=status):
                body = io.BytesIO(json.dumps({
                    "initialized": initialized, "sealed": sealed,
                }).encode())
                response = HTTPError("http://localhost", status, "", {}, body)
                with patch.object(readiness, "urlopen", side_effect=response):
                    self.assertEqual(readiness.read_health("https://bao.example.invalid:8200"), (initialized, sealed))

    def test_accepts_unsealed_server(self):
        response = io.BytesIO(b'{"initialized":true,"sealed":false}')
        response.status = 200
        with patch.object(readiness, "urlopen", return_value=response):
            self.assertEqual(readiness.read_health("https://bao.example.invalid:8200"), (True, False))

    def test_rejects_unrelated_or_inconsistent_http_responses(self):
        for status, body in [
            (503, b'{"error":"unavailable"}'),
            (501, b'{"initialized":true,"sealed":false}'),
            (403, b'{"initialized":true,"sealed":false}'),
            (503, b'not json'),
        ]:
            with self.subTest(status=status, body=body):
                response = HTTPError("http://localhost", status, "", {}, io.BytesIO(body))
                with patch.object(readiness, "urlopen", side_effect=response):
                    with self.assertRaises((ValueError, RuntimeError)):
                        readiness.read_health("https://bao.example.invalid:8200")

    def test_unavailable_server_fails(self):
        with patch.object(readiness, "urlopen", side_effect=URLError("refused")):
            with self.assertRaises(URLError):
                readiness.read_health("https://bao.example.invalid:8200")

    def test_requires_both_effective_unit_limit_and_kernel_enforcement(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            group = root / "system.slice/openbao.service"
            group.mkdir(parents=True)
            properties = (
                "ActiveState=active\nUser=openbao\nMainPID=42\n"
                "MemorySwapMax=0\nControlGroup=/system.slice/openbao.service\n"
            )
            with patch.object(readiness.subprocess, "check_output", return_value=properties):
                with self.assertRaises(OSError):
                    readiness.check_hardening(root)
                (group / "memory.swap.max").write_text("max\n")
                with self.assertRaises(RuntimeError):
                    readiness.check_hardening(root)
                (group / "memory.swap.max").write_text("0\n")
                readiness.check_hardening(root)
            with patch.object(
                readiness.subprocess, "check_output",
                return_value=properties.replace("MemorySwapMax=0", "MemorySwapMax=infinity"),
            ):
                with self.assertRaises(RuntimeError):
                    readiness.check_hardening(root)


if __name__ == "__main__":
    unittest.main()
