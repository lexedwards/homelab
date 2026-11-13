#!/usr/bin/env python3
import re
from pathlib import Path
import subprocess
import sys


LOCAL_PATH = re.compile(r'"((?:\$\{path\.module\}/|\.\.?/)[^"\n]*)"')


def service_owner(root, path):
    try:
        parts = path.resolve().relative_to(root.resolve()).parts
    except ValueError:
        return None
    return parts[1] if len(parts) > 1 and parts[0] == 'services' else None


def check_file(root, path, source):
    owner = service_owner(root, path)
    base = path.parent.parent if path.name.endswith(('.tftest.hcl', '.tofutest.hcl')) and path.parent.name == 'tests' else path.parent
    errors = []
    for number, line in enumerate(source.splitlines(), 1):
        for match in LOCAL_PATH.finditer(line):
            reference = match.group(1).replace('${path.module}/', '', 1)
            target = base / reference.split('${', 1)[0]
            target_owner = service_owner(root, target)
            if target_owner is not None and target_owner != owner:
                errors.append(f'{path.relative_to(root)}:{number}: imports private services/{target_owner} implementation/state')
    return errors


def main():
    root = Path(__file__).resolve().parents[1]
    listed = subprocess.check_output(['git', 'ls-files', '-z', '--cached', '--others', '--exclude-standard',
                                      '*.tf', '*.tf.json', '*.tofu', '*.tofu.json', '*.tftest.hcl', '*.tofutest.hcl'], cwd=root).decode().split('\0')
    errors = []
    for name in sorted(set(filter(None, listed))):
        path = root / name
        if path.is_symlink():
            errors.append(f'{name}: symlinked configuration requires explicit ownership review')
            continue
        if path.is_file():
            errors.extend(check_file(root, path, path.read_text()))
    if errors:
        print('\n'.join(errors), file=sys.stderr)
        return 1
    print('Literal OpenTofu service-boundary checks passed; review dynamic references and script/test imports separately.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
