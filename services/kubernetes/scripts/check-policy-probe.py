#!/usr/bin/env python3
import argparse
import datetime
import ipaddress
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
from urllib.parse import urlsplit


def endpoint(value):
    if not re.fullmatch(r'[a-z0-9]([-a-z0-9]*[a-z0-9])?/[a-z0-9]([-a-z0-9.]*[a-z0-9])?', value):
        raise argparse.ArgumentTypeError('Use namespace/pod for each endpoint')
    return value.split('/')


def api_endpoint(value):
    url = urlsplit(value)
    if url.scheme != 'https' or not url.hostname or url.username or url.password or url.path or url.query or url.fragment or url.port != 6443:
        raise argparse.ArgumentTypeError('Use the verified HTTPS cluster API identity on port 6443')
    return value


def ready(pod):
    return not pod['metadata'].get('deletionTimestamp') and any(
        c['type'] == 'Ready' and c['status'] == 'True' for c in pod['status'].get('conditions', []))


def policy_drop(event, source, destination, port):
    if event.get('type') != 'drop' or event.get('reason') != 'Policy denied':
        return False
    summary = event.get('summary', {})
    return (bool(summary.get('tcp')) and summary.get('l3') == {'src': source, 'dst': destination}
            and summary.get('l4', {}).get('dst') == str(port))


def main(argv=None):
    parser = argparse.ArgumentParser(description='Probe an owned synthetic peer directly; a denial requires correlated native Cilium drop-monitor evidence.')
    parser.add_argument('--source', type=endpoint, required=True)
    parser.add_argument('--destination', type=endpoint, required=True)
    parser.add_argument('--port', type=int, required=True)
    parser.add_argument('--expect', choices=['allow', 'deny'], required=True)
    parser.add_argument('--api-server', type=api_endpoint, required=True)
    parser.add_argument('--kubectl', default='kubectl')
    parser.add_argument('--kubeconfig', type=Path, default=Path('/etc/rancher/rke2/rke2.yaml'))
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--timeout', type=float, default=60)
    args = parser.parse_args(argv)
    if not 1 <= args.port <= 65535 or not 5 <= args.timeout <= 300 or args.source == args.destination:
        parser.error('Use distinct peers, a port from 1 through 65535 and a timeout from 5 through 300 seconds')
    deadline = time.monotonic() + args.timeout
    command = [args.kubectl, '--kubeconfig', str(args.kubeconfig), '--server', args.api_server,
               '--insecure-skip-tls-verify=false', '--request-timeout=10s']

    def call(arguments):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise RuntimeError('Probe observation deadline exceeded')
        result = subprocess.run(command + arguments, capture_output=True, text=True, timeout=min(20, remaining))
        if result.returncode:
            raise RuntimeError('API/exec/observer command failed; this is not policy-denial evidence')
        return result.stdout

    def pod(peer):
        item = json.loads(call(['-n', peer[0], 'get', 'pod', peer[1], '-o', 'json']))
        if item['metadata'].get('labels', {}).get('homelab.io/policy-check') != 'true' or not ready(item) or item['spec'].get('hostNetwork'):
            raise RuntimeError('Both endpoints must be Ready owned synthetic non-host-network pods')
        address = str(ipaddress.IPv4Address(item['status']['podIP']))
        return {'namespace': peer[0], 'pod': peer[1], 'uid': item['metadata']['uid'], 'ip': address,
                'node': item['spec']['nodeName'], 'runtime_class': item['spec'].get('runtimeClassName')}

    evidence = {'expected': args.expect, 'port': args.port, 'passed': False}
    fd = os.open(args.evidence, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'w') as output, tempfile.TemporaryDirectory(dir=args.evidence.parent) as temporary:
        monitors = []
        try:
            source, destination = pod(args.source), pod(args.destination)
            if source['uid'] == destination['uid'] or source['ip'] == destination['ip']:
                raise RuntimeError('A self-connection cannot prove peer policy')
            evidence.update(source=source, destination=destination, cross_worker=source['node'] != destination['node'])
            if args.expect == 'deny':
                agents = json.loads(call(['-n', 'kube-system', 'get', 'pods', '-l', 'k8s-app=cilium', '-o', 'json']))['items']
                relevant = [a for a in agents if a['spec'].get('nodeName') in {source['node'], destination['node']} and ready(a)]
                if {a['spec']['nodeName'] for a in relevant} != {source['node'], destination['node']}:
                    raise RuntimeError('Ready Cilium observers are required on both endpoint nodes')
                for index, agent in enumerate(relevant):
                    paths = [Path(temporary) / (str(index) + suffix) for suffix in ['.out', '.err']]
                    handles = [os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'w') for path in paths]
                    process = subprocess.Popen(command + ['-n', 'kube-system', 'exec', agent['metadata']['name'], '-c', 'cilium-agent', '--',
                                               'timeout', '10', 'cilium-dbg', 'monitor', '--type', 'drop', '--json'],
                                               stdout=handles[0], stderr=handles[1])
                    monitors.append({'process': process, 'paths': paths, 'handles': handles, 'node': agent['spec']['nodeName']})
                startup = min(deadline, time.monotonic() + 5)
                while time.monotonic() < startup:
                    if any(v['process'].poll() is not None for v in monitors):
                        raise RuntimeError('A native monitor exited before the probe')
                    if all('Press Ctrl-C to quit' in v['paths'][1].read_text() for v in monitors):
                        break
                    time.sleep(0.05)
                else:
                    raise RuntimeError('Native monitor startup was not observed')
                for monitor in monitors:
                    monitor['offset'] = monitor['paths'][0].stat().st_size
            started = datetime.datetime.now(datetime.timezone.utc)
            evidence['started_at'] = started.isoformat()
            script = 'command -v wget >/dev/null; if wget -q -O /dev/null -T 3 "$1" 2>/dev/null; then echo connected; else echo not-connected; fi'
            observed = call(['-n', source['namespace'], 'exec', source['pod'], '--', 'sh', '-ec', script,
                             'probe', 'http://' + destination['ip'] + ':' + str(args.port) + '/']).strip()
            if observed not in ['connected', 'not-connected']:
                raise RuntimeError('Unexpected probe response')
            if (observed == 'connected') != (args.expect == 'allow'):
                raise RuntimeError('Direct peer connectivity differs from the expected result')
            evidence['connection_result'] = observed
            if args.expect == 'deny':
                evidence['observations'] = []
                matched = False
                for monitor in monitors:
                    remaining = deadline - time.monotonic()
                    if remaining <= 0 or monitor['process'].wait(timeout=remaining) != 124:
                        raise RuntimeError('Native monitor failed instead of completing its bounded capture')
                    raw = monitor['paths'][0].read_bytes()[monitor['offset']:].decode()
                    events = [json.loads(line) for line in raw.splitlines() if line.lstrip().startswith('{')]
                    matching = [v for v in events if policy_drop(v, source['ip'], destination['ip'], args.port)]
                    evidence['observations'].append({'node': monitor['node'], 'matching_policy_drops': matching})
                    matched = matched or bool(matching)
                if not matched:
                    raise RuntimeError('Connection failure lacks a matching fresh Policy denied event; denial is unproven')
            if pod(args.source) != source or pod(args.destination) != destination:
                raise RuntimeError('An endpoint changed during the probe')
            evidence['passed'] = True
        finally:
            for monitor in monitors:
                if monitor['process'].poll() is None:
                    monitor['process'].kill()
                    monitor['process'].wait()
                for handle in monitor['handles']:
                    handle.close()
            json.dump(evidence, output, indent=2)
            output.write('\n')
    print('Direct peer probe passed with ' + ('correlated Cilium policy-denial evidence' if args.expect == 'deny' else 'successful connectivity'))


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError, RuntimeError, subprocess.SubprocessError):
        print('Probe failed or evidence is incomplete. Inspect the protected receipt; no policy pass is inferred from API errors or timeouts.', file=sys.stderr)
        sys.exit(1)
