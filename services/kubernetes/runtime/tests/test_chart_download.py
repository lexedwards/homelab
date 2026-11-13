import base64
import hashlib
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch
import io


SCRIPT = Path(__file__).resolve().parents[2] / 'scripts/download-secret-chart.py'


class ChartDownloadTests(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location('download_chart', SCRIPT)
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)

    def download(self, body, digest):
        with patch.object(self.module.urllib.request, 'urlopen', return_value=io.BytesIO(body)):
            return self.module.download({'url': 'https://charts.example.invalid/chart-1.0.tgz', 'sha256': digest})

    def test_verified_binary_chart_is_returned_for_native_installer(self):
        body = b'\x1f\x8b\xff\x00binary-chart'
        result = self.download(body, hashlib.sha256(body).hexdigest())
        self.assertEqual(base64.b64decode(result['content']), body)

    def test_changed_upstream_bytes_are_rejected(self):
        with self.assertRaisesRegex(ValueError, 'checksum'):
            self.download(b'changed', hashlib.sha256(b'expected').hexdigest())

    def test_unavailable_source_fails_without_a_local_fallback(self):
        with patch.object(self.module.urllib.request, 'urlopen', side_effect=OSError('unavailable')):
            with self.assertRaisesRegex(OSError, 'unavailable'):
                self.module.download({'url': 'https://charts.example.invalid/chart.tgz', 'sha256': '0' * 64})

    def test_oversized_download_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'limit'):
            self.download(b'x' * (8 * 1024 * 1024 + 1), '0' * 64)


if __name__ == '__main__':
    unittest.main()
