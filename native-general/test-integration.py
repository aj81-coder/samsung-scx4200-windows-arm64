# SPDX-License-Identifier: Apache-2.0
"""Baseline tray host + general engine regression, with device-free sender.

The new housekeeping host is separately covered by test-host.py and
test-housekeeping-host.py. This intentionally retains the earlier host fixture.
"""
from pathlib import Path
ROOT=Path(__file__).resolve().parent.parent
base=ROOT/'native-background/test-integration.py'
source=base.read_text()
source=source.replace("ROOT/'native-background/test-engine.py'", "ROOT/'native-general/test-engine.py'")
source=source.replace("ROOT/'build/background-tests/x64/SCX4200-Reliable-Bridge.exe'", "ROOT/'build/general-tests/x64/SCX4200-Reliable-Bridge.exe'")
source=source.replace("ROOT/'build/async/test-tools/SCX4200-Test-Sender.exe'", "ROOT/'build/general/test-tools/SCX4200-Test-Sender.exe'")
source=source.replace("shutil.copy2(ROOT/'build/background/x64'/name,app/name)", "shutil.copy2((ROOT/'build/background/x64' if name=='SCX4200-Printer.exe' else ROOT/'build/general/x64')/name,app/name)")
# Converted PGM is deliberately deleted immediately. Lock the retained generated
# QPDL instead to exercise the same completed-file cleanup failure boundary.
source=source.replace("first_dir/'page-01.pgm'", "first_dir/'page-01.qpdl'")
exec(compile(source,str(base),'exec'))
