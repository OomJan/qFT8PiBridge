import hashlib
import io
import json
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import types
import unittest
from unittest.mock import patch, Mock

# Hardware/systemd calls are mocked; file replacement and archive verification are real.
sys.modules['fcntl'] = types.SimpleNamespace(LOCK_EX=1, LOCK_NB=2, flock=lambda *a: None)
import qft8_update as update

def archive_bytes(payload=b'new native executable', symlink=False):
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode='w:gz') as bundle:
        info = tarfile.TarInfo('qFT8/qFT8')
        if symlink:
            info.type = tarfile.SYMTYPE
            info.linkname = '/etc/passwd'
            bundle.addfile(info)
        else:
            info.size = len(payload)
            bundle.addfile(info, io.BytesIO(payload))
    return output.getvalue()

class Response(io.BytesIO):
    def __init__(self, data):
        super().__init__(data)
        self.headers = {'Content-Length': str(len(data))}

class UpdateTests(unittest.TestCase):
    def setUp(self):
        work = Path.cwd().resolve()
        self.temp = tempfile.TemporaryDirectory(prefix='update-tests-', dir=work)
        self.root = Path(self.temp.name).resolve()
        assert self.root.is_relative_to(work)
        self.state = self.root / 'state'
        self.state.mkdir()
        (self.root / 'qFT8').write_bytes(b'old executable')
        (self.root / 'VERSION').write_text('3.30\n')
        self.payload = archive_bytes()
        self.patches = [patch.object(update, 'Path', side_effect=lambda p: self.root / 'history' if p == '/var/lib/qft8' else Path(p)), patch.object(update, 'ROOT', self.root), patch.object(update, 'STATE', self.state),
                        patch.object(update, 'require_client'), patch.object(update.time, 'sleep'),
                        patch.object(update.signal, 'signal'),
                        patch.object(update, 'latest', return_value=('3.31', 'https://example.invalid/test', hashlib.sha256(self.payload).hexdigest())),
                        patch.object(update, 'response', side_effect=lambda url: Response(self.payload))]
        for p in self.patches:
            p.start()
        self.calls = []
        self.command_patch = patch.object(update, 'command', side_effect=self.command)
        self.command_patch.start()
        self.fail_first_start = False

    def tearDown(self):
        self.command_patch.stop()
        for p in reversed(self.patches):
            p.stop()
        self.temp.cleanup()

    def command(self, *args, **kwargs):
        self.calls.append(args)
        if args[:2] == ('systemctl', 'start'):
            if self.fail_first_start:
                self.fail_first_start = False
                raise subprocess.CalledProcessError(1, args)
        return types.SimpleNamespace(stdout='stable-invocation\n', returncode=0)

    def status(self):
        return json.loads((self.state / 'status.json').read_text())

    def test_success(self):
        self.assertEqual(update.main(), 0)
        self.assertEqual((self.root / 'qFT8').read_bytes(), b'new native executable')
        self.assertEqual((self.root / 'VERSION').read_text(), '3.31\n')
        self.assertEqual(self.status()['lines'][0], 'Installed v3.31')
        self.assertTrue(self.status()['done'])

    def test_up_to_date_no_download_or_restart(self):
        with patch.object(update, 'latest', return_value=('3.30.0', 'url', 'hash')):
            self.assertEqual(update.main(), 0)
        update.response.assert_not_called()
        self.assertFalse(self.calls)
        self.assertIn('Already up to date', self.status()['lines'])

    def test_checksum_failure_keeps_old_running(self):
        with patch.object(update, 'latest', return_value=('3.31', 'url', '0' * 64)):
            self.assertEqual(update.main(), 1)
        self.assertFalse(self.calls)
        self.assertEqual((self.root / 'qFT8').read_bytes(), b'old executable')

    def test_start_failure_rolls_back(self):
        self.fail_first_start = True
        self.assertEqual(update.main(), 1)
        self.assertEqual((self.root / 'qFT8').read_bytes(), b'old executable')
        self.assertEqual((self.root / 'VERSION').read_text(), '3.30\n')
        self.assertEqual(sum(c[:2] == ('systemctl', 'start') for c in self.calls), 2)

    def test_client_loss_before_install(self):
        update.require_client.side_effect = RuntimeError('WLAN disconnected')
        self.assertEqual(update.main(), 1)
        self.assertFalse(self.calls)
        self.assertEqual((self.root / 'qFT8').read_bytes(), b'old executable')

    def test_archive_link_rejected(self):
        self.payload = archive_bytes(symlink=True)
        with patch.object(update, 'latest', return_value=('3.31', 'url', hashlib.sha256(self.payload).hexdigest())):
            self.assertEqual(update.main(), 1)
        self.assertFalse(self.calls)

    def test_progress_and_download_bytes(self):
        states = []
        with patch.object(update, 'progress', side_effect=lambda *lines, **kw: states.append(lines)):
            update.download('url', self.root / 'download', hashlib.sha256(self.payload).hexdigest(), '3.31')
        self.assertEqual((self.root / 'download').read_bytes(), self.payload)
        self.assertTrue(any('Downloading:' in ' '.join(x) for x in states))
        self.assertTrue(any('Verifying SHA-256' in x for x in states))


if __name__ == '__main__':
    unittest.main(verbosity=2)
