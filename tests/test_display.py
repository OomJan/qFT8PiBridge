import ast
from pathlib import Path
from unittest.mock import Mock
import types
import threading
from qft8_pages import IdleBrightness, format_uptime

assert format_uptime(0) == '00h00m'
assert format_uptime(3661.9) == '01h01m'
assert format_uptime(90061) == '1d01h'
brightness = IdleBrightness(60, 96, 8, 0)
assert brightness.level(59.9) == 96
assert brightness.level(60) == 8
assert brightness.touch(61) is True
assert brightness.level(61) == 96
assert brightness.touch(62) is False
assert brightness.level(121.9) == 96
assert brightness.level(122) == 8
disabled = IdleBrightness(0, 96, 8, 0)
assert disabled.level(9999) == 96 and disabled.touch(9999) is False

# Exercise the actual page-action code from the final controller, including wake-only.
tree = ast.parse(Path('controller.py').read_text())
main = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == 'main')
actions = next(n for n in ast.walk(main) if isinstance(n, ast.For) and ast.unparse(n.target) == 'action')
module = ast.Module(body=[actions], type_ignores=[])
display = Mock()
display.touch.side_effect = [True, False, False, False]
scope = dict(display=display, current_page=0, last_status=10)
for expected in [0, 1, 2, 0]:
    scope['actions'] = ['page']
    exec(compile(module, 'page-actions', 'exec'), scope)
    assert scope['current_page'] == expected

# Verify the screen wake method resets the idle timer and notifies the OLED worker.
oled = next(n for n in tree.body if isinstance(n, ast.ClassDef) and n.name == 'OledStatus')
touch = next(n for n in oled.body if isinstance(n, ast.FunctionDef) and n.name == 'touch')
scope = dict(time=types.SimpleNamespace(monotonic=lambda: 100))
exec(compile(ast.Module(body=[touch], type_ignores=[]), 'touch', 'exec'), scope)
obj = types.SimpleNamespace(lock=threading.Lock(), brightness=IdleBrightness(60,96,8,0), wake=threading.Event())
assert scope['touch'](obj) is True
assert obj.wake.is_set() and obj.brightness.level(100) == 96
print('PASS: uptime formatting, 60-second dimming, disabled dimming, wake-only first press, three-page cycling and OLED wake notification.')
