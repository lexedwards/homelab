#!/usr/bin/env python3
import argparse
from html.parser import HTMLParser
import ipaddress
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from urllib.parse import unquote, urlsplit

from markdown_it import MarkdownIt


MARKDOWN = MarkdownIt('commonmark', {'html': True})
MERMAID_VERSION = '12.2.0'
CONNECTION = re.compile(
    r'\b(?:\d{1,3}\.){3}\d{1,3}\b|'
    r'\b(?:[a-f\d]{2}:){5}[a-f\d]{2}\b|'
    r'\b(?:tcp|udp|ports?)[\s`/=:]*\d{1,5}\b|'
    r'\b(?:vlan|vlan_id)[\s`=:]*\d+\b|'
    r'--(?:port|publish)[=\s]+[\x27\x22]?\d+|'
    r':\d{4,5}\b|>:\d{1,5}\b', re.I,
)
IPV6 = re.compile(r'(?<!\w)(?:[a-f\d]{0,4}:){2,7}[a-f\d]{0,4}(?!\w)', re.I)
CREDENTIAL = re.compile(r'-----BEGIN (?:[A-Z]+ )?PRIVATE KEY-----|https?://[^\s/]+@', re.I)
URL = re.compile(r'https?://[^\s\x27\x22`<>]+', re.I)


class HTMLReferences(HTMLParser):
    def __init__(self):
        super().__init__()
        self.links = []
        self.anchors = set()

    def handle_starttag(self, tag, attrs):
        values = dict(attrs)
        for key in ('href', 'src'):
            if values.get(key):
                self.links.append(values[key])
        for key in ('id', 'name'):
            if values.get(key):
                self.anchors.add(values[key])


def privacy_errors(source):
    errors = []
    connection_lines = {source.count('\n', 0, match.start()) + 1
                        for match in CONNECTION.finditer(source)}
    for number, line in enumerate(source.splitlines(), 1):
        ipv6 = False
        for match in IPV6.finditer(line):
            candidate = match.group()
            if candidate == '::' and (line[max(0, match.start() - 1):match.start()] == '>'
                                      or line[match.end():match.end() + 1] == '<'):
                continue
            try:
                ipv6 = ipaddress.ip_address(candidate).version == 6
            except ValueError:
                continue
            if ipv6:
                break
        numeric_origin = False
        for value in URL.findall(line):
            try:
                numeric_origin |= urlsplit(value).port is not None
            except ValueError:
                continue
        if number in connection_lines or ipv6 or numeric_origin:
            errors.append((number, 'connection detail requires a private input'))
        if CREDENTIAL.search(line):
            errors.append((number, 'credential material must not appear in documentation'))
    return errors


def parse_markdown(source):
    frontmatter = re.match(r'\A---\r?\n.*?^---[ \t]*(?:\r?\n|$)', source, re.M | re.S)
    if frontmatter:
        source = '\n' * frontmatter.group().count('\n') + source[frontmatter.end():]
    tokens = MARKDOWN.parse(source)
    links, diagrams, anchors = [], [], set()
    for index, token in enumerate(tokens):
        number = token.map[0] + 1 if token.map else 1
        if token.type == 'heading_open':
            content = tokens[index + 1]
            text = ''.join(child.content for child in content.children or []
                           if child.type in ('text', 'code_inline'))
            base = re.sub(r'[^\w\- ]', '', text.lower()).replace(' ', '-')
            slug, suffix = base, 0
            while slug in anchors:
                suffix += 1
                slug = f'{base}-{suffix}'
            anchors.add(slug)
        if token.type == 'fence' and token.info.strip() == 'mermaid':
            diagrams.append((number, token.content))
        for child in token.children or []:
            if child.type in ('link_open', 'image'):
                links.append((number, child.attrGet('href' if child.type == 'link_open' else 'src')))
        html = HTMLReferences()
        for part in [token, *(token.children or [])]:
            if part.type in ('html_block', 'html_inline'):
                html.feed(part.content)
        links.extend((number, target) for target in html.links)
        anchors.update(html.anchors)
    return links, diagrams, anchors


def link_error(root, source, target, anchor_cache):
    try:
        url = urlsplit(target)
    except ValueError:
        return 'invalid link URL'
    if url.scheme or url.netloc:
        return None
    path = unquote(url.path)
    destination = (root / path.lstrip('/') if path.startswith('/') else source.parent / path) if path else source
    if not destination.resolve().is_relative_to(root):
        return 'link points outside repository'
    if any(parent.is_symlink() for parent in [destination, *destination.parents] if parent != root):
        return 'symlinked link target requires review'
    if not destination.exists():
        return 'local link target is missing'
    if url.fragment and destination.is_file() and destination.suffix == '.md':
        key = destination.resolve()
        if key not in anchor_cache:
            anchor_cache[key] = parse_markdown(destination.read_text())[2]
        if unquote(url.fragment) not in anchor_cache[key]:
            return 'local link heading is missing'
    return None


def render(diagrams):
    errors = []
    directory = '/tmp/opencode' if Path('/tmp/opencode').is_dir() else None
    with tempfile.TemporaryDirectory(prefix='homelab-docs-', dir=directory) as folder:
        for index, (name, number, content) in enumerate(diagrams):
            source = Path(folder) / f'diagram-{index}.mmd'
            output = source.with_suffix('.svg')
            source.write_text(content)
            try:
                result = subprocess.run(
                    ['npm', 'exec', '--yes', f'--package=@mermaid-js/mermaid-cli@{MERMAID_VERSION}',
                     '--', 'mmdc', '-i', str(source), '-o', str(output)],
                    capture_output=True, timeout=180,
                )
                if result.returncode or not output.is_file():
                    errors.append(f'{name}:{number}: Mermaid render failed; inspect locally')
            except (OSError, subprocess.TimeoutExpired):
                errors.append(f'{name}:{number}: Mermaid render failed; tooling unavailable or timed out')
    return errors


def main():
    parser = argparse.ArgumentParser(description='Check local documentation links and privacy patterns.')
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[1],
                        help='Git repository root; defaults to this repository')
    parser.add_argument('--render', action='store_true', help='Also render every Mermaid view locally using pinned npm tooling')
    args = parser.parse_args()
    root = args.root.resolve()
    try:
        listed = subprocess.check_output(
            ['git', 'ls-files', '-z', '--cached', '--others', '--exclude-standard', '--', '*.md', '*.mmd'],
            cwd=root, stderr=subprocess.DEVNULL,
        ).decode().split('\0')
        errors, diagrams, anchor_cache = [], [], {}
        adr_numbers = set()
        documents, links_checked = 0, 0
        for name in sorted(set(filter(None, listed))):
            path = root / name
            if any(parent.is_symlink() for parent in [path, *path.parents] if parent != root):
                errors.append(f'{name}:1: symlinked documentation requires review')
                continue
            if not path.is_file():
                continue
            source = path.read_text()
            if path.parent == root / 'docs/adrs' and re.match(r'^\d{3}-', path.name):
                number = path.name[:3]
                if number in adr_numbers:
                    errors.append(f'{name}:1: duplicate ADR number')
                adr_numbers.add(number)
            errors.extend(f'{name}:{number}: {message}' for number, message in privacy_errors(source))
            if path.suffix == '.mmd':
                diagrams.append((name, 1, source))
                continue
            documents += 1
            links, views, anchors = parse_markdown(source)
            anchor_cache[path.resolve()] = anchors
            diagrams.extend((name, number, content) for number, content in views)
            for number, target in links:
                error = link_error(root, path, target, anchor_cache)
                if error:
                    errors.append(f'{name}:{number}: {error}')
                if not urlsplit(target).scheme and not urlsplit(target).netloc:
                    links_checked += 1
        if not errors and args.render:
            errors.extend(render(diagrams))
    except (OSError, UnicodeError, subprocess.CalledProcessError, ValueError):
        print('Documentation check could not read the repository; inspect locally.', file=sys.stderr)
        return 1
    if errors:
        print('\n'.join(errors), file=sys.stderr)
        return 1
    print(f'Checked {documents} Markdown files, {links_checked} local links and {len(diagrams)} Mermaid views'
          f'{" (rendered)" if args.render else " (rendering not requested)"}.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
