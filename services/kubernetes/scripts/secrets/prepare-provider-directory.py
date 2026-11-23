#!/usr/bin/env python3
import argparse
import os
from pathlib import Path
import platform
import stat
import subprocess
import sys


PROVIDER_DIR = Path('/etc/kubernetes/secrets-store-csi-providers')


def require(condition):
    if not condition:
        raise ValueError('Worker or provider-directory ownership/label precondition failed')


def run(args):
    result = subprocess.run(args, capture_output=True, text=True, timeout=30)
    require(result.returncode == 0)
    return result.stdout.strip()


def require_worker():
    require(os.geteuid() == 0 and platform.machine() == 'x86_64')
    release = dict(line.split('=', 1) for line in Path('/etc/os-release').read_text().splitlines() if '=' in line)
    require(release.get('ID', '').strip('"') == 'rocky' and release.get('VERSION_ID', '').strip('"').split('.')[0] == '10')
    require(run(['getenforce']) == 'Enforcing')
    run(['systemctl', 'is-active', '--quiet', 'rke2-agent'])
    require(not Path('/var/lib/rancher/rke2/server/db/etcd').exists())
    require(Path('/var/lib/rancher/rke2/agent/client-kubelet.crt').is_file())
    require(subprocess.run(['systemctl', 'is-active', '--quiet', 'rke2-server'], capture_output=True, timeout=10).returncode != 0)


def configure_provider(path, command, apply):
    require(all(not p.is_symlink() for p in [path, *path.parents]))
    if path.exists():
        require(path.is_dir())
        require(all(p.name == 'openbao.sock' and stat.S_ISSOCK(p.lstat().st_mode) for p in path.iterdir()))
    expression = str(path) + '(/.*)?'
    local = command(['semanage', 'fcontext', '-l', '-C'])
    matches = [line.split()[-1] for line in local.splitlines() if line.split() and line.split()[0] == expression]
    require(not matches or len(matches) == 1 and matches[0].endswith(':container_file_t:s0'))
    if apply:
        if not matches:
            command(['semanage', 'fcontext', '-a', '-t', 'container_file_t', '-r', 's0', expression])
        path.mkdir(mode=0o755, parents=True, exist_ok=True)
        command(['restorecon', '-RF', str(path)])
    else:
        require(len(matches) == 1 and path.is_dir())
    for target in [path, *path.iterdir()]:
        expected = command(['matchpathcon', '-n', str(target)])
        actual = command(['stat', '-c', '%C', str(target)])
        require(expected == actual and actual.endswith(':container_file_t:s0'))


def main():
    parser = argparse.ArgumentParser(description='Check the exact approved OpenBao provider directory on an enrolled Rocky 10 worker; no policy broadening or package installation.')
    parser.add_argument('--apply', action='store_true', help='After explicit authorization, add the absent exact persistent mapping and restore labels only within that directory')
    args = parser.parse_args()
    require_worker()
    if PROVIDER_DIR.exists():
        require(PROVIDER_DIR.stat().st_uid == 0)
    configure_provider(PROVIDER_DIR, run, args.apply)
    print('Exact provider-directory persistent mapping and current labels verified under SELinux enforcing. No cluster labels or workloads changed.')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, subprocess.SubprocessError):
        print('Provider-directory check failed. Stop and inspect worker identity, tools, existing contents and SELinux labels; no broad relabel or policy workaround is permitted.', file=sys.stderr)
        sys.exit(1)
