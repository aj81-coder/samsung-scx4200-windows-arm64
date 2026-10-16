# SPDX-License-Identifier: Apache-2.0
"""Exercise the production tray host against an isolated, device-free child."""
import ctypes
from ctypes import wintypes as W
import datetime
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time
import traceback

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/general/tray-icon' / ('host-lifecycle-' + datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f'))
OUT.mkdir(parents=True)
INSTALL = OUT / 'isolated app'; INSTALL.mkdir()
HOST = INSTALL / 'SCX4200-Printer.exe'
shutil.copy2(ROOT / 'build/general-host-preview/x64/SCX4200-Printer.exe', HOST)
# This adjacent control is a deliberately harmless fixture, not production recovery.
(INSTALL / 'controls.ps1').write_text("param([string]$DataDir,[string]$Action)\n[IO.File]::AppendAllText((Join-Path $DataDir 'fixture-controls.txt'),$Action+[Environment]::NewLine)\nwhile(Test-Path -LiteralPath (Join-Path $DataDir 'fixture-control-hold')){Start-Sleep -Milliseconds 50}\nif($Action -eq 'Recover' -and (Test-Path -LiteralPath (Join-Path $DataDir 'fixture-control-recover'))){Remove-Item -LiteralPath (Join-Path $DataDir 'SESSION-ACTIVE.lock')}\n")
# The helper fixture never removes user data or opens a device.
(INSTALL / 'housekeeping.ps1').write_text("""param([string]$DataDir)
[IO.File]::AppendAllText((Join-Path $DataDir 'fixture-housekeeping.txt'),"begin\n")
while(Test-Path -LiteralPath (Join-Path $DataDir 'fixture-housekeeping-hold')){Start-Sleep -Milliseconds 50}
[IO.File]::AppendAllText((Join-Path $DataDir 'fixture-housekeeping.txt'),"end\n")
if(Test-Path -LiteralPath (Join-Path $DataDir 'fixture-housekeeping-fail')){exit 7}
exit 0
""")

env = dict(os.environ, ZIG_GLOBAL_CACHE_DIR=str(ROOT / '.cache/zig-global'), ZIG_LOCAL_CACHE_DIR=str(ROOT / '.cache/zig-local'))
compiled = subprocess.run([str(ROOT / '.tools/zig-x86_64-windows-0.15.2/zig.exe'), 'cc', '-target', 'x86_64-windows-gnu', '-std=c11', '-O1', '-Wall', '-Wextra', '-Werror', str(ROOT / 'native-background/test-host-child.c'), '-o', str(INSTALL / 'SCX4200-Reliable-Bridge.exe')], env=env, capture_output=True, text=True)
(OUT / 'fixture-build.txt').write_text(compiled.stdout + compiled.stderr)
if compiled.returncode:
    raise SystemExit('Fixture compilation failed: ' + str(OUT / 'fixture-build.txt'))

u = ctypes.WinDLL('user32', use_last_error=True)
k = ctypes.WinDLL('kernel32', use_last_error=True)
CALLBACK = ctypes.WINFUNCTYPE(W.BOOL, W.HWND, W.LPARAM)
u.IsWindow.argtypes = [W.HWND]; u.IsWindow.restype = W.BOOL
u.EnumWindows.argtypes = [CALLBACK, W.LPARAM]
u.EnumChildWindows.argtypes = [W.HWND, CALLBACK, W.LPARAM]
u.GetWindowThreadProcessId.argtypes = [W.HWND, ctypes.POINTER(W.DWORD)]
u.GetClassNameW.argtypes = [W.HWND, W.LPWSTR, ctypes.c_int]
u.GetWindowTextW.argtypes = [W.HWND, W.LPWSTR, ctypes.c_int]
u.PostMessageW.argtypes = [W.HWND, W.UINT, W.WPARAM, W.LPARAM]
u.SendMessageTimeoutW.argtypes = [W.HWND, W.UINT, W.WPARAM, W.LPARAM, W.UINT, W.UINT, ctypes.POINTER(ctypes.c_size_t)]
u.SendMessageTimeoutW.restype = W.LPARAM
u.GetDlgItem.argtypes = [W.HWND, ctypes.c_int]; u.GetDlgItem.restype = W.HWND
k.OpenProcess.argtypes = [W.DWORD, W.BOOL, W.DWORD]; k.OpenProcess.restype = W.HANDLE
k.TerminateProcess.argtypes = [W.HANDLE, W.UINT]
k.CloseHandle.argtypes = [W.HANDLE]
k.WaitForSingleObject.argtypes = [W.HANDLE, W.DWORD]; k.WaitForSingleObject.restype = W.DWORD
k.QueryFullProcessImageNameW.argtypes = [W.HANDLE, W.DWORD, W.LPWSTR, ctypes.POINTER(W.DWORD)]
processes = []
child_pids = set()
results = []

def windows(pid, classname=None):
    found = []
    @CALLBACK
    def collect(hwnd, _):
        actual = W.DWORD(); u.GetWindowThreadProcessId(hwnd, ctypes.byref(actual))
        name = ctypes.create_unicode_buffer(256); u.GetClassNameW(hwnd, name, 256)
        if actual.value == pid and (classname is None or name.value == classname): found.append(hwnd)
        return True
    u.EnumWindows(collect, 0)
    return found

def until(predicate, description, seconds=8):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        value = predicate()
        if value: return value
        time.sleep(.05)
    raise AssertionError('Timed out: ' + description)

def dialog_text(hwnd):
    parts = []
    @CALLBACK
    def collect(child, _):
        text = ctypes.create_unicode_buffer(2048); u.GetWindowTextW(child, text, 2048)
        if text.value: parts.append(text.value)
        return True
    u.EnumChildWindows(hwnd, collect, 0)
    return '\n'.join(parts)

def dismiss(hwnd):
    button = u.GetDlgItem(hwnd, 1)
    if button: u.PostMessageW(button, 0xF5, 0, 0)  # BM_CLICK on this dialog's OK button
    else: u.PostMessageW(hwnd, 0x10, 0, 0)
    until(lambda: not u.IsWindow(hwnd), "dialog dismissed")

def status(process, hwnd, expected):
    time.sleep(.65)  # production status timer is 500 ms
    u.PostMessageW(hwnd, 0x111, 1001, 0)
    dialog = until(lambda: windows(process.pid, '#32770'), 'status dialog')[0]
    text = dialog_text(dialog)
    dismiss(dialog)
    until(lambda: not windows(process.pid, '#32770'), 'status dialog dismissed')
    assert expected in text, (expected, text)
    return text

def start(name, hold=False, fail=False):
    data = OUT / name; data.mkdir()
    if hold: (data / 'fixture-housekeeping-hold').touch()
    if fail: (data / 'fixture-housekeeping-fail').touch()
    process = subprocess.Popen([str(HOST), '--data-dir', str(data)], creationflags=subprocess.CREATE_NO_WINDOW)
    processes.append(process)
    hwnd = until(lambda: windows(process.pid, 'SCX4200.BackgroundHost.Window'), 'host window (exit=' + str(process.poll()) + ')')[0]
    if hold or fail: return process, hwnd, data
    launches = data / 'fixture-launches.txt'
    until(launches.exists, 'fake child launched')
    pid = int(launches.read_text().strip()); child_pids.add(pid)
    status(process, hwnd, 'ready for documents')
    return process, hwnd, data

def stop(process, hwnd):
    u.PostMessageW(hwnd, 0x10, 0, 0)
    assert process.wait(timeout=8) == 0

failure = None
try:
    process, hwnd, data = start('housekeeping-async', hold=True)
    until(lambda: (data / 'fixture-housekeeping.txt').exists(), 'helper begins')
    assert not (data / 'fixture-launches.txt').exists()
    status(process, hwnd, 'preparing recent history')
    u.PostMessageW(hwnd, 0x111, 1004, 0)
    dialog = until(lambda: windows(process.pid, '#32770'), 'start guarded while helper runs')[0]
    assert 'cannot start' in dialog_text(dialog); dismiss(dialog)
    (data / 'fixture-housekeeping-hold').unlink()
    until(lambda: (data / 'fixture-launches.txt').exists(), 'helper success starts engine')
    status(process, hwnd, 'ready for documents')
    assert (data / 'fixture-housekeeping.txt').read_text().splitlines() == ['begin', 'end']
    stop(process, hwnd)
    results.append({'test': 'asynchronous housekeeping gates startup and keeps UI responsive', 'pass': True})
    process, hwnd, data = start('housekeeping-refused', fail=True)
    until(lambda: (data / 'fixture-housekeeping.txt').exists() and 'end' in (data / 'fixture-housekeeping.txt').read_text(), 'refused helper completes')
    time.sleep(.7)
    status(process, hwnd, 'housekeeping refused')
    time.sleep(1.1)
    assert not (data / 'fixture-launches.txt').exists()
    assert (data / 'fixture-housekeeping.txt').read_text().splitlines() == ['begin', 'end']
    (data / 'fixture-housekeeping-fail').unlink()
    u.PostMessageW(hwnd, 0x111, 1004, 0)
    until(lambda: (data / 'fixture-launches.txt').exists(), 'explicit retry after helper refusal')
    stop(process, hwnd)
    results.append({'test': 'helper refusal stops without retry loop; explicit retry succeeds', 'pass': True})
    process, hwnd, data = start('housekeeping-quit', hold=True)
    until(lambda: (data / 'fixture-housekeeping.txt').exists(), 'helper begins before quit')
    u.PostMessageW(hwnd, 0x10, 0, 0)
    status(process, hwnd, 'finishing housekeeping before exit')
    assert process.poll() is None and not (data / 'fixture-launches.txt').exists()
    (data / 'fixture-housekeeping-hold').unlink()
    assert process.wait(timeout=8) == 0
    assert (data / 'fixture-housekeeping.txt').read_text().splitlines() == ['begin', 'end']
    assert not (data / 'fixture-launches.txt').exists()
    results.append({'test': 'Quit waits for helper completion without starting engine or killing cleanup', 'pass': True})
    process, hwnd, data = start('housekeeping-lock-race', hold=True)
    until(lambda: (data / 'fixture-housekeeping.txt').exists(), 'helper begins before competing lock')
    (data / 'SESSION-ACTIVE.lock').touch()
    (data / 'fixture-housekeeping-hold').unlink()
    status(process, hwnd, 'previous session needs recovery')
    assert not (data / 'fixture-launches.txt').exists()
    stop(process, hwnd)
    results.append({'test': 'session lock appearing during helper prevents engine launch', 'pass': True})
    process, hwnd, data = start('housekeeping-stop', hold=True)
    until(lambda: (data / 'fixture-housekeeping.txt').exists(), 'helper begins before stop')
    u.PostMessageW(hwnd, 0x111, 1005, 0)
    status(process, hwnd, 'finishing housekeeping; printing stopped')
    (data / 'fixture-housekeeping-hold').unlink()
    status(process, hwnd, 'choose Start printing')
    assert not (data / 'fixture-launches.txt').exists()
    stop(process, hwnd)
    results.append({'test': 'Stop during housekeeping cancels deferred engine launch', 'pass': True})
    process, hwnd, data = start('housekeeping-control-race', hold=True)
    until(lambda: (data / 'fixture-housekeeping.txt').exists(), 'helper begins before control lock')
    (data / 'CONTROL-ACTIVE.lock').touch()
    (data / 'fixture-housekeeping-hold').unlink()
    until(lambda: 'end' in (data / 'fixture-housekeeping.txt').read_text(), 'helper finishes with competing lock')
    time.sleep(.7)
    status(process, hwnd, 'could not start; check locks')
    assert not (data / 'fixture-launches.txt').exists()
    (data / 'CONTROL-ACTIVE.lock').unlink()
    stop(process, hwnd)
    results.append({'test': 'control lock appearing during helper prevents engine launch', 'pass': True})
    helper = INSTALL / 'housekeeping.ps1'
    helper.rename(INSTALL / 'housekeeping.fixture-disabled')
    try:
        process, hwnd, data = start('housekeeping-missing', fail=True)
        status(process, hwnd, 'could not start; check installation')
        assert not (data / 'fixture-launches.txt').exists()
        stop(process, hwnd)
    finally:
        (INSTALL / 'housekeeping.fixture-disabled').rename(helper)
    results.append({'test': 'missing helper refuses startup without launching engine', 'pass': True})
    process, hwnd, data = start('normal')
    results.append({'test': 'ready event and visible status', 'pass': True})
    (data / 'fixture-busy').touch()
    status(process, hwnd, 'working or needs attention')
    (data / 'fixture-busy').unlink()
    status(process, hwnd, 'ready for documents')
    results.append({'test': 'ready reset and restore status', 'pass': True})
    duplicate = subprocess.Popen([str(HOST), '--data-dir', str(data)], creationflags=subprocess.CREATE_NO_WINDOW)
    processes.append(duplicate)
    dialog = until(lambda: windows(duplicate.pid, '#32770'), 'duplicate refusal dialog')[0]
    assert 'already running' in dialog_text(dialog); dismiss(dialog)
    assert duplicate.wait(timeout=5) == 2
    assert len((data / 'fixture-launches.txt').read_text().splitlines()) == 1
    results.append({'test': 'duplicate host refused without extra child', 'pass': True})
    (data / 'fixture-control-hold').touch()
    u.PostMessageW(hwnd, 0x111, 1006, 0)
    until(lambda: (data / 'fixture-controls.txt').exists(), 'fake cancel control launched')
    assert (data / 'fixture-controls.txt').read_text().strip() == 'Cancel'
    u.PostMessageW(hwnd, 0x111, 1006, 0)
    dialog = until(lambda: windows(process.pid, '#32770'), 'duplicate control refused')[0]
    assert 'already active' in dialog_text(dialog); dismiss(dialog)
    u.PostMessageW(hwnd, 0x10, 0, 0)
    dialog = until(lambda: windows(process.pid, '#32770'), 'quit during control refused')[0]
    assert 'before quitting' in dialog_text(dialog); dismiss(dialog)
    assert process.poll() is None
    assert len((data / 'fixture-controls.txt').read_text().splitlines()) == 1
    (data / 'fixture-control-hold').unlink()
    time.sleep(1)
    results.append({'test': 'quoted isolated control launch, duplicate refusal and quit guard', 'pass': True})
    u.PostMessageW(hwnd, 0x111, 1005, 0)
    until(lambda: not (data / 'SESSION-ACTIVE.lock').exists(), 'manual stop finished')
    status(process, hwnd, 'stopped')
    assert process.poll() is None
    (data / 'CONTROL-ACTIVE.lock').touch()
    u.PostMessageW(hwnd, 0x111, 1004, 0)
    dialog = until(lambda: windows(process.pid, '#32770'), 'guard refusal')[0]
    assert 'cannot start' in dialog_text(dialog); dismiss(dialog)
    assert len((data / 'fixture-launches.txt').read_text().splitlines()) == 1
    (data / 'CONTROL-ACTIVE.lock').unlink()
    u.PostMessageW(hwnd, 0x111, 1004, 0)
    until(lambda: len((data / 'fixture-launches.txt').read_text().splitlines()) == 2, 'manual start launched')
    child_pids.update(map(int, (data / 'fixture-launches.txt').read_text().splitlines()))
    status(process, hwnd, 'ready for documents')
    results.append({'test': 'manual stop leaves host running; control lock guards start; explicit start succeeds', 'pass': True})
    u.PostMessageW(hwnd, 0x111, 1008, 0)
    until(lambda: 'Diagnostics' in (data / 'fixture-controls.txt').read_text(), 'fake diagnostic action launched')
    time.sleep(1)
    assert (data / 'fixture-controls.txt').read_text().splitlines() == ['Cancel', 'Diagnostics']
    results.append({'test': 'diagnostics action uses same isolated control lifecycle', 'pass': True})
    stop(process, hwnd)
    assert not (data / 'SESSION-ACTIVE.lock').exists()
    assert any('FIXTURE EXIT 0' in path.read_text() for path in data.glob('background-*.log'))
    results.append({'test': 'WM_CLOSE signals Stop and graceful child shutdown', 'pass': True})
    process, hwnd, data = start('failure')
    (data / 'fixture-fail').touch()
    status(process, hwnd, 'previous session needs recovery')
    time.sleep(1.1)
    assert (data / 'SESSION-ACTIVE.lock').exists()
    assert len((data / 'fixture-launches.txt').read_text().splitlines()) == 1
    u.PostMessageW(hwnd, 0x111, 1004, 0)
    dialog = until(lambda: windows(process.pid, '#32770'), 'session guard refusal')[0]
    assert 'cannot start' in dialog_text(dialog); dismiss(dialog)
    u.PostMessageW(hwnd, 0x111, 1007, 0)
    until(lambda: (data / 'fixture-controls.txt').exists(), 'fake recover control launched')
    assert (data / 'fixture-controls.txt').read_text().strip() == 'Recover'
    time.sleep(1)
    assert (data / 'SESSION-ACTIVE.lock').exists()
    (data / 'fixture-control-recover').touch()
    u.PostMessageW(hwnd, 0x111, 1007, 0)
    until(lambda: not (data / 'SESSION-ACTIVE.lock').exists(), 'fake recovery clears fixture lock')
    status(process, hwnd, 'choose Start printing')
    assert len((data / 'fixture-launches.txt').read_text().splitlines()) == 1
    stop(process, hwnd)
    results.append({'test': 'child failure retains lock without automatic restart', 'pass': True})
    # Simulate only the notification, never initiate a real Windows logoff.
    process, hwnd, data = start('logoff-notification')
    (data / 'fixture-stop-delay').touch()
    before = time.monotonic(); reply = ctypes.c_size_t()
    assert u.SendMessageTimeoutW(hwnd, 0x11, 0, 0, 2, 5000, ctypes.byref(reply))
    assert reply.value == 1 and .65 < time.monotonic() - before < 4.5
    assert not (data / 'SESSION-ACTIVE.lock').exists()
    until(lambda: not (data / 'SESSION-ACTIVE.lock').exists(), 'query-end-session stops child')
    stop(process, hwnd)
    results.append({'test': 'logoff notification signals graceful Stop', 'pass': True})
    process, hwnd, data = start('logoff-bounded-wait')
    (data / 'fixture-stop-long-delay').touch()
    before = time.monotonic(); reply = ctypes.c_size_t()
    assert u.SendMessageTimeoutW(hwnd, 0x11, 0, 0, 2, 5000, ctypes.byref(reply))
    elapsed = time.monotonic() - before
    assert reply.value == 1 and 2.8 < elapsed < 3.8, elapsed
    assert (data / 'SESSION-ACTIVE.lock').exists(), 'bounded wait must not clear an unfinished session'
    until(lambda: not (data / 'SESSION-ACTIVE.lock').exists(), 'delayed fake child finishes naturally')
    stop(process, hwnd)
    results.append({'test': 'logoff wait bounded at three seconds without forced clean claim', 'pass': True})
    process, hwnd, data = start('host-crash')
    fixture_pid = int((data / 'fixture-launches.txt').read_text().strip())
    fixture_handle = k.OpenProcess(0x100000, False, fixture_pid)
    assert fixture_handle, 'Unable to observe own fake child termination'
    try:
        # Deliberately bypass graceful shutdown of our isolated host. The job
        # must terminate its fake child and leave the durable session lock.
        process.terminate(); process.wait(timeout=5)
        assert k.WaitForSingleObject(fixture_handle, 5000) == 0
    finally:
        k.CloseHandle(fixture_handle)
    assert (data / 'SESSION-ACTIVE.lock').exists()
    assert len((data / 'fixture-launches.txt').read_text().splitlines()) == 1
    results.append({'test': 'host crash terminates owned child tree and retains lock', 'pass': True})
except Exception as exc:
    failure = traceback.format_exc()
finally:
    for hold in OUT.glob('*/fixture-housekeeping-hold'):
        hold.rename(hold.with_suffix('.released'))
    for hold in OUT.glob("*/fixture-control-hold"):
        hold.rename(hold.with_suffix(".released"))
    for process in processes:
        if process.poll() is None:
            for hwnd in windows(process.pid, '#32770'): dismiss(hwnd)
            for hwnd in windows(process.pid, 'SCX4200.BackgroundHost.Window'): u.PostMessageW(hwnd, 0x10, 0, 0)
            try: process.wait(timeout=3)
            except subprocess.TimeoutExpired: process.terminate(); process.wait(timeout=3)
    # These PIDs came only from our compiled device-free fixture's own markers.
    for pid in child_pids:
        handle = k.OpenProcess(1 | 0x1000, False, pid)
        if handle:
            image = ctypes.create_unicode_buffer(32768); length = W.DWORD(32768)
            if k.QueryFullProcessImageNameW(handle, 0, image, ctypes.byref(length)) and Path(image.value) == INSTALL / 'SCX4200-Reliable-Bridge.exe':
                k.TerminateProcess(handle, 99)
            k.CloseHandle(handle)
    report = {'state': 'FAIL_OR_BLOCKED' if failure else 'PASS', 'failure': failure, 'device_free': True,
              'host_sha256': hashlib.sha256(HOST.read_bytes()).hexdigest(), 'tests': results,
              'scope': 'Own isolated host and fake child only; no USB, queue changes, registration or real logoff.'}
    (OUT / 'results.json').write_text(json.dumps(report, indent=2))
    print(json.dumps(report, indent=2)); print(OUT / 'results.json')
if failure: raise SystemExit(1)
