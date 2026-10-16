# SPDX-License-Identifier: Apache-2.0
"""Real loopback bridge + device-free sender; invokes unmodified cancellation tool."""
from pathlib import Path
import importlib.util, subprocess, socket, time, threading, shutil, json, hashlib
ROOT=Path(__file__).resolve().parent.parent
spec=importlib.util.spec_from_file_location('ipp',ROOT/'native-ipp-capture/test-capture.py');ipp=importlib.util.module_from_spec(spec);spec.loader.exec_module(ipp)
DEST=ROOT/'build/reliable/direct-cancel-test'
DEST.mkdir(exist_ok=False)
for name in ['SCX4200-Reliable-Bridge.exe','cups.dll','SCX4200-Render.exe']:
 shutil.copy2(ROOT/'build/reliable-tests/x64'/name,DEST/name)
shutil.copy2(ROOT/'build/reliable/test-tools/SCX4200-Test-Sender.exe',DEST/'SCX4200-Test-Sender.exe')
shutil.copy2(Path(__file__).parent/'cancel-current-job.ps1',DEST/'cancel-current-job.ps1')
(DEST/'sender-test-mode.txt').write_text('wait')
header=(Path(__file__).parent/'test-header.bin').read_bytes();row=b'\xff'*2480
encoded=bytearray()
for i in range(0,2480,128):encoded+=bytes([min(128,2480-i)-1,255])
body=bytearray(header)
for y in range(0,3507,256):body+=bytes([min(256,3507-y)-1])+encoded
proc=subprocess.Popen([str(DEST/'SCX4200-Reliable-Bridge.exe')],cwd=DEST,stdin=subprocess.PIPE,stdout=(DEST/'stdout.log').open('wb'),stderr=(DEST/'stderr.log').open('wb'),creationflags=subprocess.CREATE_NO_WINDOW)
proc.stdin.write(b'ARM\n');proc.stdin.flush()
errors=[]
try:
 for _ in range(100):
  if proc.poll() is not None:raise ValueError('Bridge exited before listener')
  try:
   with socket.create_connection(('127.0.0.1',8631),.1):break
  except OSError:time.sleep(.1)
 else:raise ValueError('No listener')
 ep=ipp.Endpoint('http://127.0.0.1:8631/ipp/print');job=ep.request(5);jobid=job['attributes']['job-id'][0]
 def send():
  try:ipp.Endpoint('http://127.0.0.1:8631/ipp/print').request(6,ipp.attribute(0x21,'job-id',jobid)+ipp.attribute(0x22,'last-document',b'\x01')+ipp.attribute(0x49,'document-format','image/pwg-raster'),bytes(body))
  except Exception as exc:errors.append(str(exc))
 thread=threading.Thread(target=send);thread.start()
 for _ in range(400):
  if (DEST/'stub-waiting.txt').exists():break
  time.sleep(.05)
 else:raise ValueError('Sender not waiting')
 control=subprocess.run(['powershell.exe','-NoProfile','-ExecutionPolicy','Bypass','-File',str(DEST/'cancel-current-job.ps1')],capture_output=True,text=True,timeout=20)
 (DEST/'control-output.txt').write_text(control.stdout+control.stderr)
 if control.returncode:raise ValueError('Cancel tool failed: '+control.stdout+control.stderr)
 report=json.loads(next(DEST.glob('control-cancel-*.json')).read_text(encoding='utf-8-sig'))
 if report['outcome']!='CancelAccepted' or report['cancelled_job_id']!=jobid:raise ValueError('Wrong cancel report: '+str(report))
 thread.join(15)
 if thread.is_alive() or errors:raise ValueError('Send did not stop: '+str(errors))
 state=ep.request(9,ipp.attribute(0x21,'job-id',jobid))['attributes']['job-state'][0]
 if state not in (7,8):raise ValueError('Job not cancelled/aborted')
 sender=json.loads(next(DEST.glob('bridge-*/job-*/sender-report.json')).read_text())
 if (DEST/'stub-calls.txt').read_text().splitlines()!=['call']:raise ValueError('Sender replay')
 (DEST/'test-stop.request').write_text('stop')
 if proc.wait(75)!=1:raise ValueError('Expected blocked session exit')
 evidence=dict(outcome='PASS',device_free=True,job_state=state,control_report=report,sender_report=sender,bridge_sha256=hashlib.sha256((DEST/'SCX4200-Reliable-Bridge.exe').read_bytes()).hexdigest(),tool_sha256=hashlib.sha256((DEST/'cancel-current-job.ps1').read_bytes()).hexdigest())
 (DEST/'test-results.json').write_text(json.dumps(evidence,indent=2));print(json.dumps(evidence,indent=2))
finally:
 if proc.poll() is None:
  (DEST/'test-stop.request').write_text('stop')
  try:proc.wait(10)
  except subprocess.TimeoutExpired:proc.kill();proc.wait()
