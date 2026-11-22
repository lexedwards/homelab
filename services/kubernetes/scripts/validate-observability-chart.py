#!/usr/bin/env python3
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

import yaml


def main():
    parser = argparse.ArgumentParser(description='Verify the pinned chart, render synthetic metrics values, and run native Alloy validation without cluster access.')
    parser.add_argument('--chart', type=Path, required=True)
    parser.add_argument('--helm', default='helm')
    parser.add_argument('--alloy', default='alloy')
    args = parser.parse_args()
    platform = Path(__file__).resolve().parents[1] / 'platform' / 'observability'
    pin = json.loads((platform / 'chart.json').read_text())
    if hashlib.sha256(args.chart.read_bytes()).hexdigest() != pin['sha256']:
        raise ValueError('Chart checksum differs from the reviewed pin')
    version = subprocess.run([args.alloy, '--version'], check=True, capture_output=True, text=True).stdout
    if f"v{pin['alloy_version']}" not in version.split():
        raise ValueError('Use the chart-matching Alloy binary recorded in chart.json')
    values = [
        '--values', str(platform / 'values.yaml'),
        '--set', 'cluster.name=validation',
        '--set', 'destinations.warehouse.url=http://warehouse.invalid:4318',
        '--set', 'destinations.warehouse.tls.insecure=true',
    ]
    subprocess.run([args.helm, 'lint', str(args.chart), '--kube-version', '1.36.6', *values], check=True, timeout=60)
    rendered = subprocess.run([
        args.helm, 'template', 'observability', str(args.chart),
        '--namespace', 'observability-system', '--kube-version', '1.36.6', *values,
    ], check=True, capture_output=True, text=True, timeout=60).stdout
    with tempfile.TemporaryDirectory(prefix='observability-validate-') as directory:
        validated = 0
        for document in yaml.safe_load_all(rendered):
            if not isinstance(document, dict) or document.get('kind') != 'ConfigMap':
                continue
            for name, content in document.get('data', {}).items():
                if name.endswith('.alloy'):
                    config = Path(directory) / 'config.alloy'
                    config.write_text(content)
                    subprocess.run([args.alloy, 'validate', str(config)], check=True, timeout=60)
                    validated += 1
                    print(f"Validated {document['metadata']['name']} with Alloy {pin['alloy_version']}")
        if not validated:
            raise ValueError('Chart rendered no Alloy configurations to validate')


if __name__ == '__main__':
    main()
