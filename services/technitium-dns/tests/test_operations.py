import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
import unittest


class StateSnapshotInstructionsTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        document = (Path(__file__).parents[1] / "operations.md").read_text()
        blocks = [block for block in re.findall(r"```bash\n(.*?)\n```", document, re.S)
                  if "SNAPSHOT_PARENT" in block]
        if len(blocks) != 1:
            raise ValueError("Expected one documented state snapshot command")
        cls.command = blocks[0]
        cls.state = {
            "version": 4,
            "lineage": "synthetic-snapshot-lineage",
            "serial": 7,
            "resources": [{"mode": "managed", "type": "technitium_record",
                           "name": "managed", "instances": []}],
        }

    def execute_snapshot(self, payload, export_exit=0):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            binaries = root / "bin"
            backups = root / "backups"
            binaries.mkdir()
            backups.mkdir()
            exporter = binaries / "tofu"
            exporter.write_text(
                f"#!{sys.executable}\n"
                "import sys\n"
                "if sys.argv[1:] != ['state', 'pull']:\n"
                "    raise SystemExit(2)\n"
                f"sys.stdout.write({payload!r})\n"
                f"raise SystemExit({export_exit})\n"
            )
            exporter.chmod(0o700)
            environment = {
                "PATH": str(binaries) + os.pathsep + os.environ["PATH"],
                "HOME": str(root),
                "SNAPSHOT_PARENT": str(backups),
                "PYTHONOPTIMIZE": "1",
            }
            result = subprocess.run(["bash"], input=self.command, cwd=root,
                                    env=environment, text=True, capture_output=True)
            snapshots = list(backups.glob("*/terraform.tfstate"))
            partials = list(backups.glob("*/terraform.tfstate.partial"))
            saved = [
                (path.read_text(), stat.S_IMODE(path.stat().st_mode),
                 stat.S_IMODE(path.parent.stat().st_mode))
                for path in snapshots
            ]
            partial_modes = [stat.S_IMODE(path.stat().st_mode) for path in partials]
            return result, saved, partial_modes

    def test_snapshot_command_has_valid_shell_syntax(self):
        subprocess.run(["bash", "-n"], input=self.command, text=True, check=True)

    def test_success_promotes_exact_state_with_private_permissions(self):
        result, snapshots, partials = self.execute_snapshot(json.dumps(self.state))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(snapshots), 1)
        content, file_mode, directory_mode = snapshots[0]
        self.assertEqual(json.loads(content), self.state)
        self.assertEqual(file_mode, 0o600)
        self.assertEqual(directory_mode, 0o700)
        self.assertEqual(partials, [])

    def test_failed_or_invalid_exports_never_promote_partial_state(self):
        cases = [
            ("export failure", json.dumps(self.state), 1),
            ("invalid JSON", "not JSON", 0),
            ("missing fields", "{}", 0),
            ("invalid serial", json.dumps(dict(self.state, serial=-1)), 0),
            ("empty resource inventory", json.dumps(dict(self.state, resources=[])), 0),
            ("missing resource identity", json.dumps(dict(self.state, resources=[{}])), 0),
            ("invalid instance inventory", json.dumps(dict(self.state, resources=[
                dict(self.state["resources"][0], instances=None)])), 0),
        ]
        for label, payload, export_exit in cases:
            with self.subTest(label=label):
                result, snapshots, partials = self.execute_snapshot(payload, export_exit)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(snapshots, [])
                self.assertEqual(partials, [0o600])


if __name__ == "__main__":
    unittest.main()
