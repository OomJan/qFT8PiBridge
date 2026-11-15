import threading
from unittest.mock import patch
import qft8_pages as pages

cases = [
    (1000, 0, 'CPU: 1000MHz OK'),
    (600, 0, 'CPU: 600MHz OK'),
    (600, 4, 'CPU: 600MHz THROTTLED!'),
    (600, 8, 'CPU: 600MHz TEMP LIMIT!'),
    (600, 2, 'CPU: 600MHz CAPPED!'),
    (1000, 0x40000, 'CPU: 1000MHz PAST LIMIT'),
    (1000, None, 'CPU: 1000MHz STATUS?'),
    (None, 4, 'CPU: ?MHz THROTTLED!'),
]
for mhz, flags, expected in cases:
    assert pages.cpu_frequency_line(mhz, flags) == expected

def collect(clock, throttle):
    collector = pages.SystemPages.__new__(pages.SystemPages)
    collector.interface = 'wlan0'
    collector.cpu = pages.CpuAverage()
    collector.lock = threading.Lock()
    def output(*args):
        if args == ('vcgencmd', 'measure_clock', 'arm'):
            return clock
        if args == ('vcgencmd', 'get_throttled'):
            return throttle
        raise OSError('No test network')
    with patch.object(pages, 'system_output', side_effect=output):
        collector.collect()
    return collector.lines(1)[3]

assert collect('frequency(48)=1000000000', 'throttled=0x0') == 'CPU: 1000MHz OK'
assert collect('frequency(48)=600000000', 'throttled=0x4') == 'CPU: 600MHz THROTTLED!'
assert collect('error', 'throttled=0x4') == 'CPU: ?MHz THROTTLED!'
assert collect('frequency(48)=1000000000', 'error') == 'CPU: 1000MHz STATUS?'
assert collect('frequency(48)=0', 'throttled=0x0') == 'CPU: ?MHz OK'
print('PASS: 8 display states and 5 collector cases, including low-frequency power saving and unavailable readings.')
