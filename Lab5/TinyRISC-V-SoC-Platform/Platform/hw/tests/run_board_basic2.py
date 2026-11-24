#!/usr/bin/env python3
"""Program and test the connected Digilent board using the current build."""
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import time
import serial

root = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('uploader', root / 'sw/upload.py')
uploader = importlib.util.module_from_spec(spec)
spec.loader.exec_module(uploader)
ports = sorted(Path('/dev/serial/by-id').glob('*if01*'))
if len(ports) != 1:
    raise SystemExit('Connect exactly one Digilent board UART (interface 01) first.')
with serial.Serial(str(ports[0]), 115200, timeout=.1, exclusive=True) as ser, \
        (root / 'build/basic2_board_uart.log').open('w') as uartlog:
    def until(marker, timeout):
        captured = ''
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            chunk = ser.read(max(1, ser.in_waiting)).decode('utf-8', 'replace')
            if chunk:
                captured += chunk
                uartlog.write(chunk)
                uartlog.flush()
                if marker in captured:
                    return captured
        raise TimeoutError(f'Waiting for {marker!r}: {captured[-700:]!r}')

    def select(key, prompt, timeout=300):
        ser.write(key.encode())
        ser.flush()
        return until(prompt, timeout)

    print('Programming FPGA...', flush=True)
    with (root / 'build/basic2_board_program.log').open('w') as log:
        subprocess.run(['vivado', '-mode', 'batch', '-source', str(root / 'hw/program.tcl'),
                        '-notrace', '-nolog', '-nojournal', '-tclargs', str(root / 'build/out.bit')],
                       cwd=root, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=180)
    until('SYNC', 60)
    uploader.start_vivado_server()
    if not uploader.do_upload(str(root / 'build/sw/main.bin')):
        raise RuntimeError('Software upload failed')
    ser.write(b'D')
    ser.flush()
    until('main> ', 120)
    select('l', 'lab> ')
    results = {}
    for key, name in [('s', 'gemv'), ('c', 'coherence'), ('l', 'logistic'), ('t', 'transpose')]:
        results[name] = select(key, 'lab> ')
        print(f'\n{name}:\n{results[name]}', flush=True)
    select('x', 'main> ')
    print('Running MobileViT...', flush=True)
    results['inference'] = select('t', 'main> ', 1800)
    print(results['inference'], flush=True)
    (root / 'build/basic2_board_sections.json').write_text(json.dumps(results, indent=2))
    expected = [-32, 114, -38, 52, 50, 127, -120, -128, -71, 80]
    actual = [int(x) for x in re.findall(r'^\d{2}:\s*(-?\d+)\s*$', results['inference'], re.M)]
    assert 'Pass 11 / 11' in results['gemv']
    assert '12/12 passed' in results['coherence']
    assert '4/4 passed' in results['logistic'] and '14/14 passed' in results['transpose']
    assert len(actual) == 10 and all(abs(a-b) <= 2 for a,b in zip(actual, expected))
    print('PASS all Basic2 board checks.', flush=True)
