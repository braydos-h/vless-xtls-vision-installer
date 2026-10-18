# SPDX-License-Identifier: GPL-3.0-only
"""Check local Markdown links and documented command names."""
import pathlib
import re
import subprocess
root = pathlib.Path(__file__).resolve().parents[1]
help_text = subprocess.check_output(['bash', str(root / 'xray_reality_bootstrap.sh'), '--help'], text=True)
for path in [root / 'README.md', *list((root / 'docs').glob('*.md'))]:
    content = path.read_text()
    for target in re.findall(r'\]\(([^)]+)\)', content):
        if '://' in target or target.startswith('#'):
            continue
        assert (path.parent / target.split('#')[0]).exists(), (path, target)
for command in ['add-client', 'remove-client', 'rotate-shortid', 'finalize-shortid', 'backup', 'restore', 'recover', 'preflight', 'harden-ssh', 'confirm-host', 'test-client']:
    assert command in help_text
    assert command in (root / 'README.md').read_text()
print('Documentation links and commands: PASS')
