# SPDX-License-Identifier: Apache-2.0
param([string]$RecoveryScript=(Join-Path $PSScriptRoot 'recover-session.ps1'))
$ErrorActionPreference='Stop'
$RecoveryScript=(Resolve-Path -LiteralPath $RecoveryScript).Path
$root=Split-Path $PSScriptRoot -Parent
$out=Join-Path $root ('build/reliable/recovery-tests-'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
New-Item -ItemType Directory $out | Out-Null
$results=@()
foreach($case in @('inspect','active','port','queue','cancel','reset','race')){
 $dir=Join-Path $out $case;New-Item -ItemType Directory $dir | Out-Null
 Copy-Item -LiteralPath $RecoveryScript -Destination (Join-Path $dir 'recover-session.ps1')
 Set-Content (Join-Path $dir 'SESSION-ACTIVE.lock') 'Keep this exact original lock'
 $run=Join-Path $dir 'bridge-20261013-test';New-Item -ItemType Directory $run | Out-Null
 Set-Content (Join-Path $run 'session-result.json') '{"state":"SEND_FAILED_OR_UNCERTAIN_NO_RETRY","completed_jobs":0,"completed_pages":0,"blocked":true}'
 Set-Content (Join-Path $run 'evidence.txt') 'Keep original job evidence'
 $active=if($case -eq 'active'){1}else{0};$busy=if($case -eq 'port'){1}else{0};$queued=if($case -eq 'queue'){1}else{0};$race=if($case -eq 'race'){1}else{0}
 $answer=if($case -eq 'cancel'){'CANCEL'}else{'RESET'}
 $script="function Get-Process { if($active){[pscustomobject]@{Id=1}} }; function Get-NetTCPConnection { if($busy){[pscustomobject]@{LocalPort=8631}} }; `$script:qCalls=0; function Get-PrintJob { `$script:qCalls++; if($queued -or ($race -and `$script:qCalls -gt 1)){[pscustomobject]@{Id=8;JobStatus='Complete, Retained, Error'}} }; function Read-Host { '$answer' }; & `"$dir/recover-session.ps1`""
 if($case -eq 'inspect'){$script+=' -InspectOnly'}
 $script+='; if($LASTEXITCODE){exit $LASTEXITCODE}'
 [IO.File]::WriteAllText((Join-Path $dir 'mocks.ps1'),$script,[Text.Encoding]::UTF8)
 # Expected refusal cases write stderr; WinPS otherwise promotes that stream
 # to a terminating NativeCommandError before we can verify the exit code.
 try{
  $ErrorActionPreference='Continue'
  $messages=& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dir 'mocks.ps1') 2>&1
  $actualExit=$LASTEXITCODE
 }finally{$ErrorActionPreference='Stop'}
 $messages | Out-String | Set-Content (Join-Path $dir 'output.txt')
 $expected=if($case -in @('inspect','reset')){0}else{1}
 if($actualExit -ne $expected){throw "Unexpected recovery exit for $case"}
 if($case -eq 'queue'){
  $text=$messages | Out-String
  foreach($required in @('Job 8 | Complete, Retained, Error','do not mean the queue is empty','Wait for its row to disappear','No session lock was changed')){
   if(-not $text.Contains($required)){throw "Missing queue recovery guidance: $required"}
  }
 }
 if((Test-Path (Join-Path $dir 'SESSION-ACTIVE.lock')) -eq ($case -eq 'reset')){throw "Wrong lock state: $case"}
 if((Get-Content (Join-Path $run 'evidence.txt') -Raw).Trim() -ne 'Keep original job evidence'){throw 'Job evidence changed'}
 if($case -eq 'reset'){
  $lock=Get-ChildItem $dir -File -Filter 'SESSION-ACTIVE-recovered-*.lock'
  if($lock.Count -ne 1 -or (Get-Content $lock.FullName -Raw).Trim() -ne 'Keep this exact original lock'){throw 'Original lock not preserved'}
  $zip=Get-ChildItem $dir -File -Filter 'recovery-backup-*.zip'
  if($zip.Count -ne 1){throw 'Recovery backup missing'}
  Expand-Archive -LiteralPath $zip.FullName -DestinationPath (Join-Path $dir 'archive-check')
  if(-not (Test-Path (Join-Path $dir 'archive-check/SESSION-ACTIVE.lock')) -or -not (Test-Path (Join-Path $dir 'archive-check/bridge-20261013-test/evidence.txt'))){throw 'Backup missing evidence'}
 }
 $results+=@{name=$case;result='PASS'}
}
@{result='PASS';tests=$results;recovery_script_sha256=(Get-FileHash -LiteralPath $RecoveryScript -Algorithm SHA256).Hash;scope='Mocked process/queue/port reads; only isolated test files archived or renamed'} | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $out 'results.json')
Write-Host $out
