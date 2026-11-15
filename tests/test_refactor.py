import ast
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock

# Test the real status-query helper without importing GPIO or starting services.
tree = ast.parse(Path('controller.py').read_text())
function = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == 'network_status')
run = Mock()
scope = {'run': run, 'IF': 'wlan1'}
exec(compile(ast.Module(body=[function], type_ignores=[]), 'network_status', 'exec'), scope)
for output, expected in [
    ('qft8-maintenance\n192.168.1.2/24\n', ('qft8-maintenance', ['192.168.1.2/24'])),
    ('qft8-maintenance\n', ('qft8-maintenance', [])),
    ('qft8-hotspot\n192.168.50.1/24\n192.168.50.2/24\n',
     ('qft8-hotspot', ['192.168.50.1/24', '192.168.50.2/24'])),
    ('', ('', [])),
]:
    run.reset_mock()
    run.return_value = SimpleNamespace(returncode=0, stdout=output)
    assert scope['network_status']() == expected
    run.assert_called_once_with('nmcli', '-g', 'GENERAL.CONNECTION,IP4.ADDRESS', 'device', 'show', 'wlan1')
run.return_value = SimpleNamespace(returncode=10, stdout='partial output')
assert scope['network_status']() == ('', [])

# Exercise the transition decision from main: no update until client has an IP,
# exactly one request for each successful connection, then re-arm after AP mode.
main = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == 'main')
transition = next(n for n in ast.walk(main) if isinstance(n, ast.If) and ast.unparse(n.test) == 'wifi_mode != CLIENT')
scope = dict(CLIENT='qft8-maintenance', last_update_mode=None, request_update=Mock())
code = compile(ast.Module(body=[transition], type_ignores=[]), 'transition', 'exec')
for mode, ip in [('qft8-hotspot', ['ap']), ('qft8-maintenance', []),
                 ('qft8-maintenance', ['ip']), ('qft8-maintenance', ['ip']),
                 ('qft8-hotspot', ['ap']), ('qft8-maintenance', ['ip'])]:
    scope.update(wifi_mode=mode, ip=ip)
    exec(code, scope)
assert scope['request_update'].call_count == 2
print('PASS: combined network status and update transition handling.')
