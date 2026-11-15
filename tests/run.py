"""Extract and test the actual embedded helpers without running the installer."""
from pathlib import Path
import os
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
script = (ROOT / 'install.sh').read_text(encoding='utf-8')
blocks = re.findall(r"cat > /usr/local/lib/qft8/([^ ]+) <<'PY'\n(.*?)\nPY", script, re.S)
assert len(blocks) == 6, 'Expected all six Python helpers'
with tempfile.TemporaryDirectory(prefix='qft8-tests-') as directory:
    for name, code in blocks:
        compile(code, name, 'exec')
        Path(directory, name).write_text(code, encoding='utf-8')
    env = dict(os.environ, PYTHONPATH=directory, PYTHONDONTWRITEBYTECODE='1')
    for test in sorted(Path(__file__).parent.glob('test_*.py')):
        print(f'Running {test.name}', flush=True)
        subprocess.run([sys.executable, '-B', str(test)], cwd=directory, env=env, check=True)
print('All embedded Python syntax and offline checks passed.')
