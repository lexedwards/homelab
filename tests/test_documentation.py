from pathlib import Path
import os
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/check-documentation.py'


class DocumentationTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        subprocess.run(['git', 'init', '-q', str(self.root)], check=True)

    def write(self, name, text):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        return path

    def check(self, *args, env=None):
        return subprocess.run(
            [sys.executable, str(SCRIPT), '--root', str(self.root), *args],
            capture_output=True, text=True, env=env,
        )

    def test_relative_reference_links_images_and_duplicate_headings(self):
        self.write('README.md', '[Guide][guide]\n\n[guide]: docs/guide.md#read-code-1\n\n![Image](image.svg)\n')
        self.write('docs/guide.md', '# Read `code`\n\n# Read `code`\n\n[Back](../README.md)\n')
        self.write('image.svg', '<svg/>')
        result = self.check()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('2 Markdown files', result.stdout)

    def test_missing_file_and_fragment_fail(self):
        for target in ['missing.md', 'README.md#missing']:
            with self.subTest(target=target):
                self.write('README.md', f'# Home\n\n[Link]({target})\n')
                result = self.check()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('README.md:3:', result.stderr)

    def test_reference_links_are_checked(self):
        self.write('README.md', '[Missing][target]\n\n[target]: missing.md\n')
        self.assertNotEqual(self.check().returncode, 0)

    def test_indented_fences_do_not_create_links(self):
        self.write('README.md', '- Example:\n\n    ```text\n    [example](missing.md)\n    ```\n')
        result = self.check()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_html_links_and_anchors_are_checked(self):
        self.write('README.md', '<a id="example"></a>\n\n<a href="#example">Example</a>\n')
        self.assertEqual(self.check().returncode, 0)
        self.write('README.md', '<a href="missing.md">Missing</a>\n')
        self.assertNotEqual(self.check().returncode, 0)

    def test_frontmatter_does_not_create_heading_anchors(self):
        self.write('README.md', '---\nname: Private metadata\n---\n\n[Invalid](#name-private-metadata)\n')
        result = self.check()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('heading is missing', result.stderr)

    def test_connection_values_fail_in_prose_code_and_diagrams_without_echoing_values(self):
        values = ['192.0.2.5', '2001:db8::5', 'TCP `8200`', 'TCP\n`8200`', 'https://example.invalid:53',
                  '--publish=3001:3001', 'aa:bb:cc:dd:ee:ff', 'VLAN 42']
        for value in values:
            for source in [value, f'```text\n{value}\n```', f'```mermaid\nflowchart LR\nA["{value}"]\n```']:
                with self.subTest(value=value, source=source):
                    self.write('README.md', source)
                    result = self.check()
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn('connection detail', result.stderr)
                    self.assertNotIn(value, result.stderr)

    def test_credentials_fail_without_echoing_values(self):
        for value in ['https://user:password@example.invalid', '-----BEGIN PRIVATE KEY-----']:
            with self.subTest(value=value):
                self.write('README.md', value)
                result = self.check()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('credential', result.stderr)
                self.assertNotIn(value, result.stderr)

    def test_versions_permissions_public_links_and_private_placeholders_are_allowed(self):
        self.write('README.md', 'Rocky 10, RKE2 v1.36.6+rke2r1, mode 0600.\n'
                   'The `:2` image tag; import `<zone>::<name>::<type>::<value>`.\n'
                   '[Public](https://example.org/guide)\n'
                   '```bash\ncurl "${PRIVATE_URL:?set privately}"\n'
                   'curl "http://$service_ip:${service_port:?set privately}/"\n```\n')
        result = self.check()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_ignored_markdown_is_not_read(self):
        self.write('.gitignore', 'private.md\n')
        self.write('private.md', '192.0.2.5')
        self.write('README.md', '# Home\n')
        result = self.check()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('1 Markdown files', result.stdout)

    def test_symlinked_markdown_and_link_targets_fail(self):
        self.write('actual.txt', '# External\n')
        (self.root / 'linked.md').symlink_to('actual.txt')
        self.write('README.md', '[Link](linked.md)\n')
        result = self.check()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('symlink', result.stderr)

    def test_links_cannot_escape_repository(self):
        self.write('README.md', '[Outside](../outside.md)\n')
        result = self.check()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('outside repository', result.stderr)

    def test_mermaid_source_files_are_checked_for_privacy(self):
        self.write('diagram.mmd', 'flowchart LR\nA["192.0.2.5"]\n')
        self.assertNotEqual(self.check().returncode, 0)

    def test_duplicate_adr_numbers_fail(self):
        self.write('docs/adrs/001-first.md', '# First decision\n')
        self.write('docs/adrs/001-second.md', '# Second decision\n')
        result = self.check()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('duplicate ADR number', result.stderr)

    def test_renderer_failure_fails_without_echoing_its_output(self):
        self.write('README.md', '```mermaid\nflowchart LR\nA-->B\n```\n')
        npm = self.write('bin/npm', '#!/bin/sh\ntouch "$NPM_CALLED"\necho "RAW_RENDERER_OUTPUT" >&2\nexit 1\n')
        npm.chmod(0o755)
        marker = self.root / 'renderer-called'
        env = dict(os.environ, PATH=f'{npm.parent}:{os.environ["PATH"]}', NPM_CALLED=str(marker))
        result = self.check('--render', env=env)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Mermaid render failed', result.stderr)
        self.assertNotIn('RAW_RENDERER_OUTPUT', result.stderr)
        self.assertTrue(marker.exists())
        marker.unlink()
        self.write('README.md', '```mermaid\nflowchart LR\nA["192.0.2.5"]\n```\n')
        result = self.check('--render', env=env)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('connection detail', result.stderr)
        self.assertFalse(marker.exists())


if __name__ == '__main__':
    unittest.main()
