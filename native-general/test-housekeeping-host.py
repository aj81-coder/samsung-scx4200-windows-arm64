# SPDX-License-Identifier: Apache-2.0
"""Production host plus actual housekeeping wrapper; isolated data and fake engine."""
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
OUT = ROOT / 'build/general' / ('housekeeping-host-' + datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f'))
OUT.mkdir(parents=True)
HOST = ROOT / 'build/general-host-preview/x64/SCX4200-Printer.exe'
FIXTURE = OUT / 'fixture-engine.exe'
env = dict(os.environ, ZIG_GLOBAL_CACHE_DIR=str(ROOT / '.cache/zig-global'), ZIG_LOCAL_CACHE_DIR=str(ROOT / '.cache/zig-local'))
build = subprocess.run([str(ROOT / '.tools/zig-x86_64-windows-0.15.2/zig.exe'), 'cc', '-target', 'x86_64-windows-gnu', '-std=c11', '-O1', '-Wall', '-Wextra', '-Werror', str(ROOT / 'native-background/test-host-child.c'), '-o', str(FIXTURE)], env=env, capture_output=True, text=True)
(OUT / 'fixture-build.txt').write_text(build.stdout + build.stderr)
if build.returncode: raise SystemExit('Fake engine compilation failed')
u = ctypes.WinDLL('user32', use_last_error=True)
CALLBACK = ctypes.WINFUNCTYPE(W.BOOL, W.HWND, W.LPARAM)
u.EnumWindows.argtypes = [CALLBACK, W.LPARAM]
u.EnumChildWindows.argtypes = [W.HWND, CALLBACK, W.LPARAM]
u.GetWindowThreadProcessId.argtypes = [W.HWND, ctypes.POINTER(W.DWORD)]
u.GetClassNameW.argtypes = [W.HWND, W.LPWSTR, ctypes.c_int]
u.GetWindowTextW.argtypes = [W.HWND, W.LPWSTR, ctypes.c_int]
u.GetDlgItem.argtypes = [W.HWND, ctypes.c_int]; u.GetDlgItem.restype = W.HWND
u.PostMessageW.argtypes = [W.HWND, W.UINT, W.WPARAM, W.LPARAM]
u.SendMessageTimeoutW.argtypes = [W.HWND, W.UINT, W.WPARAM, W.LPARAM, W.UINT, W.UINT, ctypes.POINTER(ctypes.c_size_t)]
u.SendMessageTimeoutW.restype = W.LPARAM
processes = []
results = []

def until(check, description, seconds=90):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        value = check()
        if value: return value
        time.sleep(.1)
    raise AssertionError('Timed out: ' + description)

def windows(pid, classname):
    found = []
    @CALLBACK
    def collect(hwnd, _):
        owner = W.DWORD(); u.GetWindowThreadProcessId(hwnd, ctypes.byref(owner))
        name = ctypes.create_unicode_buffer(256); u.GetClassNameW(hwnd, name, 256)
        if owner.value == pid and name.value == classname: found.append(hwnd)
        return True
    u.EnumWindows(collect, 0)
    return found

def text(hwnd):
    parts = []
    @CALLBACK
    def collect(child, _):
        value = ctypes.create_unicode_buffer(2048); u.GetWindowTextW(child, value, 2048)
        if value.value: parts.append(value.value)
        return True
    u.EnumChildWindows(hwnd, collect, 0)
    return '\n'.join(parts)

def dismiss(hwnd):
    button = u.GetDlgItem(hwnd, 1)
    u.PostMessageW(button if button else hwnd, 0xF5 if button else 0x10, 0, 0)

def start(name, receipt=True):
    base = OUT / name; app = base / 'app'; data = base / 'data'
    app.mkdir(parents=True); data.mkdir()
    shutil.copy2(HOST, app / HOST.name)
    shutil.copy2(FIXTURE, app / 'SCX4200-Reliable-Bridge.exe')
    for leaf in ('housekeeping.ps1', 'setup.ps1'):
        shutil.copy2(ROOT / 'native-general' / leaf, app / leaf)
    (app / 'controls.ps1').write_text('param([string]$DataDir,[string]$Action)\nexit 0\n')
    if receipt:
        (base / 'installation-complete.json').write_text(json.dumps({'schema_version': 1, 'state': 'Installed', 'data': str(data), 'app': str(app)}))
    sessions = []
    for index in range(12):
        stamp = (datetime.date(2026, 9, 1) + datetime.timedelta(days=index)).strftime('%Y%m%d')
        run = data / f'bridge-{stamp}-120000-000-{100 + index}'
        run.mkdir(); (run / 'spool').mkdir()
        (run / 'framework.log').write_text('isolated framework fixture\n')
        (run / 'session-result.json').write_text(json.dumps({'version': '0.12.0-general-dev', 'state': 'CLEAN_SHUTDOWN', 'mock_transport': False, 'accepted_jobs': 0, 'completed_jobs': 0, 'accepted_pages': 0, 'completed_pages': 0, 'blocked': False, 'automatic_retry': False}))
        sessions.append(run)
    process = subprocess.Popen([str(app / HOST.name), '--data-dir', str(data)], creationflags=subprocess.CREATE_NO_WINDOW)
    processes.append(process)
    hwnd = until(lambda: windows(process.pid, 'SCX4200.BackgroundHost.Window'), 'host window', 10)[0]
    reply = ctypes.c_size_t()
    assert u.SendMessageTimeoutW(hwnd, 0, 0, 0, 2, 1000, ctypes.byref(reply)), 'host UI unresponsive'
    return process, hwnd, data, sessions

failure = None
try:
    process, hwnd, data, sessions = start('real-cleanup')
    until(lambda: (data / 'fixture-launches.txt').exists(), 'real helper completes and fake engine starts', 120)
    report = json.loads((data / 'housekeeping-latest.json').read_text(encoding='utf-8-sig'))
    assert report['retained_clean_sessions'] == 10, report
    assert set(report['removed_sessions']) == {path.name for path in sessions[:2]}, report
    assert all(not path.exists() for path in sessions[:2])
    assert all(path.exists() for path in sessions[2:])
    assert not (data / 'CONTROL-ACTIVE.lock').exists()
    until(lambda: (data / 'SESSION-ACTIVE.lock').exists(), 'fake engine establishes session', 5)
    u.PostMessageW(hwnd, 0x10, 0, 0)
    assert process.wait(timeout=10) == 0
    assert not (data / 'SESSION-ACTIVE.lock').exists()
    results.append({'test': 'production host and real helper prune two of twelve sessions before fake engine starts; Quit clears fake lock', 'pass': True})
    process, hwnd, data, sessions = start('missing-receipt', receipt=False)
    # Native PowerShell startup can be delayed by a concurrent cross-build.
    # Observe completed host state rather than assuming a fixed startup delay.
    deadline = time.monotonic() + 45
    message = ''
    while time.monotonic() < deadline:
        u.PostMessageW(hwnd, 0x111, 1001, 0)
        dialog = until(lambda: windows(process.pid, '#32770'), 'failure status', 10)[0]
        message = text(dialog); dismiss(dialog)
        until(lambda: not windows(process.pid, '#32770'), 'status dialog closed', 5)
        if 'housekeeping refused' in message: break
        time.sleep(.5)
    assert 'housekeeping refused' in message, message
    assert not (data / 'fixture-launches.txt').exists()
    assert all(path.exists() for path in sessions)
    assert not (data / 'CONTROL-ACTIVE.lock').exists()
    u.PostMessageW(hwnd, 0x10, 0, 0)
    assert process.wait(timeout=10) == 0
    results.append({'test': 'missing installation receipt refuses real helper and engine start without touching session fixtures', 'pass': True})
except Exception:
    failure = traceback.format_exc()
finally:
    for process in processes:
        if process.poll() is None:
            for hwnd in windows(process.pid, '#32770'): dismiss(hwnd)
            for hwnd in windows(process.pid, 'SCX4200.BackgroundHost.Window'): u.PostMessageW(hwnd, 0x10, 0, 0)
            try: process.wait(timeout=10)
            except subprocess.TimeoutExpired: process.terminate(); process.wait(timeout=5)
    report = {'result': 'FAIL' if failure else 'PASS', 'failure': failure, 'tests': results, 'device_free': True,
              'host_sha256': hashlib.sha256(HOST.read_bytes()).hexdigest(),
              'housekeeping_sha256': hashlib.sha256((ROOT / 'native-general/housekeeping.ps1').read_bytes()).hexdigest(),
              'scope': 'Real installed helper with production read-only process/listener checks, isolated fixture directories, fake engine; no USB, queues, startup settings or actual logoff.'}
    (OUT / 'results.json').write_text(json.dumps(report, indent=2))
    print(json.dumps(report, indent=2)); print(OUT / 'results.json')
if failure: raise SystemExit(1)
