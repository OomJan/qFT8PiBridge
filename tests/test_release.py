import io
from unittest.mock import patch
from qft8_release import select_release

digest = 'a' * 64
def asset(version, suffix='linux-arm64.tar.gz', checksum=True):
    name = f'qFT8-v{version}-{suffix}'
    return dict(name=name, browser_download_url=f'https://github.com/lquesada/qFT8/releases/download/main/{name}',
                digest='sha256:' + digest if checksum else None)

release = dict(assets=[asset('3.9'), asset('3.30'), asset('3.30.1'), asset('4.0-rc1'),
                       asset('9.0', 'linux-64bits.tar.gz')])
assert select_release(release)[0] == '3.30.1'
assert select_release(dict(assets=[asset('3.99'), asset('4.0')]))[0] == '4.0'

def fails(data):
    try:
        select_release(data)
    except ValueError:
        return
    raise AssertionError('Expected rejection')

fails(dict(assets=[]))
fails(dict(prerelease=True, assets=[asset('4.0')]))
fails(dict(assets=[asset('3.30'), asset('3.31', checksum=False)]))
bad = asset('3.31')
bad['browser_download_url'] = 'https://example.com/untrusted.tar.gz'
fails(dict(assets=[bad]))

class Response(io.BytesIO):
    def geturl(self):
        return 'https://release-assets.githubusercontent.com/checksum'

fallback = dict(assets=[asset('3.31', checksum=False), asset('3.31', 'SHA256SUMS.txt')])
with patch('urllib.request.urlopen', return_value=Response((digest + '  qFT8-v3.31-linux-arm64.tar.gz\n').encode())):
    assert select_release(fallback) == ('3.31', fallback['assets'][0]['browser_download_url'], digest)
with patch('urllib.request.urlopen', return_value=Response((digest + '  qFT8-v3.31-linux-64bits.tar.gz\n').encode())):
    fails(fallback)
print('PASS: numeric versions, architecture selection, prerelease exclusion, checksum fallback and failure cases.')
