#!/usr/bin/env python3
"""Validate fetched release packages and pin actual Porch image references."""
import re
import sys
from pathlib import Path

import yaml


def pin(directory, revision, porch_tag):
    if not re.fullmatch(r'v\d+\.\d+\.\d+', porch_tag):
        raise ValueError('Porch tag must be an explicit vX.Y.Z release')
    root = Path(directory)
    kptfile = yaml.safe_load((root / 'Kptfile').read_text())
    actual = kptfile.get('upstreamLock', {}).get('git', {}).get('commit')
    if actual != revision:
        raise ValueError(f'{root}: expected catalog commit {revision}, found {actual}')
    updates = []
    pattern = re.compile(
        r'(?m)^(\s*image:\s*[\"\x27]?(?:docker.io/)?nephio/'
        r'porch-(?:server|controllers|function-runner|wrapper-server)):[\w.-]+'
    )
    for path in sorted(root.rglob('*.yaml')):
        source = path.read_text()
        result = pattern.sub(lambda m: m[1] + ':' + porch_tag, source)
        for obj in yaml.safe_load_all(result):
            if not isinstance(obj, dict):
                continue
            if obj.get('kind') == 'Repository' and obj.get('apiVersion') == 'config.porch.kpt.dev/v1alpha1':
                if not obj.get('spec', {}).get('git', {}).get('repo'):
                    raise ValueError(f'{path}: Repository Git URL is empty')
            # A release package must not silently pull a moving Nephio image.
            for match in re.finditer(r'(?m)^\s*image:\s*[\"\x27]?((?:docker.io/)?nephio/(?:nephio-operator|porch-[\w-]+)(?::[^\s\"\x27]+)?)', result):
                if ':' not in match[1] or match[1].endswith(':latest'):
                    raise ValueError(f'{path}: unpinned Nephio image {match[1]}')
        if result != source:
            updates.append((path, result))
    for path, result in updates:
        path.write_text(result)
    print('updated' if updates else 'validated')


if __name__ == '__main__':
    try:
        pin(*sys.argv[1:])
    except (ValueError, OSError, yaml.YAMLError) as exc:
        sys.exit(str(exc))
